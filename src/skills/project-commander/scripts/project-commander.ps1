[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ProjectPath,

    [switch]$ListProjects,

    [string]$NewProjectName,

    [string]$Message,

    [string]$CommanderName,

    [string]$AdoptThreadId,

    [string]$ContainerName,

    [ValidateSet("read-only", "workspace-write")]
    [string]$Sandbox = "workspace-write",

    [switch]$NoCreate
)

$ErrorActionPreference = "Stop"
$script:RequestId = 0
$script:CommanderToken = ([char]0x603B).ToString() + [char]0x6307 + [char]0x6325
$script:NameSeparator = [char]0xFF5C
$script:CodexHome = "/home/codex/.codex"
$script:ProjectRoot = "/workspace/Documents"

function Normalize-ContainerPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Trim().Replace("\", "/")
    if (-not $normalized.StartsWith("/")) {
        throw "ProjectPath must be an absolute container path: $Path"
    }
    if ($normalized.Length -gt 1) {
        $normalized = $normalized.TrimEnd("/")
    }
    return $normalized
}

function Get-ProjectName {
    param([Parameter(Mandatory = $true)][string]$Path)

    $parts = $Path.TrimEnd("/").Split("/")
    return $parts[$parts.Length - 1]
}

function Assert-ValidProjectName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $candidate = $Name.Trim()
    if (-not $candidate) {
        throw "NewProjectName cannot be empty."
    }
    if ($candidate -eq "." -or $candidate -eq "..") {
        throw "NewProjectName cannot be a traversal name: $candidate"
    }
    if ($candidate.Length -gt 120) {
        throw "NewProjectName is too long; use 120 characters or fewer."
    }
    if ($candidate -match '[<>:"/\\|?*\x00-\x1F]') {
        throw "NewProjectName contains a path separator or an invalid Windows filename character: $candidate"
    }
    if ($candidate.EndsWith(".") -or $candidate.EndsWith(" ")) {
        throw "NewProjectName cannot end with a dot or space: $candidate"
    }
    if ($candidate -match '(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$') {
        throw "NewProjectName is reserved by Windows: $candidate"
    }
    return $candidate
}

function Get-ShortHash {
    param([Parameter(Mandatory = $true)][string]$Value)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 8)
    }
    finally {
        $sha.Dispose()
    }
}

function Invoke-Docker {
    param(
        [Parameter(Mandatory = $true)][string]$DockerPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & $DockerPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "docker $($Arguments -join ' ') failed with exit code ${exitCode}: $($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output | ForEach-Object { $_.ToString() })
    }
}

function Invoke-ContainerScript {
    param(
        [Parameter(Mandatory = $true)][string]$DockerPath,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$Script
    )

    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    return Invoke-Docker -DockerPath $DockerPath -Arguments @(
        "exec", $Container, "bash", "-lc", "echo $encoded | base64 -d | bash"
    )
}

function ConvertTo-AsciiJson {
    param([Parameter(Mandatory = $true)]$Value)

    $json = $Value | ConvertTo-Json -Compress -Depth 50
    $builder = New-Object Text.StringBuilder
    foreach ($character in $json.ToCharArray()) {
        $codePoint = [int]$character
        if ($codePoint -gt 127) {
            [void]$builder.AppendFormat("\u{0:x4}", $codePoint)
        }
        else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Resolve-CodexContainer {
    param(
        [Parameter(Mandatory = $true)][string]$DockerPath,
        [string]$RequestedName
    )

    $running = Invoke-Docker -DockerPath $DockerPath -Arguments @("ps", "--format", "{{.Names}}")
    $names = @($running.Output | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })

    if ($RequestedName) {
        if ($RequestedName -notmatch '^[A-Za-z0-9_.-]+$') {
            throw "Unsafe container name: $RequestedName"
        }
        if ($names -notcontains $RequestedName) {
            throw "Requested container is not running: $RequestedName"
        }
        $names = @($RequestedName)
    }

    $verified = @()
    foreach ($name in $names) {
        if ($name -notmatch '^[A-Za-z0-9_.-]+$') {
            continue
        }
        $check = Invoke-Docker -DockerPath $DockerPath -Arguments @(
            "exec", $name, "sh", "-lc",
            "command -v codex >/dev/null 2>&1 && test -d $script:ProjectRoot && test -d $script:CodexHome"
        ) -AllowFailure
        if ($check.ExitCode -eq 0) {
            $verified += $name
        }
    }

    if ($verified.Count -eq 0) {
        throw "No running container was verified as the Codex project container."
    }
    if ($verified.Count -gt 1) {
        throw "Multiple Codex containers were verified; specify -ContainerName: $($verified -join ', ')"
    }
    return $verified[0]
}

function Start-AppServerClient {
    param(
        [Parameter(Mandatory = $true)][string]$DockerPath,
        [Parameter(Mandatory = $true)][string]$Container
    )

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $DockerPath
    $psi.Arguments = "exec -i $Container env CODEX_HOME=$script:CodexHome codex app-server --listen stdio://"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) {
        throw "Failed to start Codex app-server through Docker."
    }

    $client = [pscustomobject]@{ Process = $process }
    $initialize = Send-AppRequest -Client $client -Method "initialize" -Params @{
        clientInfo = @{
            name = "project_commander_gateway"
            title = "Project Commander Gateway"
            version = "0.1.0"
        }
        capabilities = @{ experimentalApi = $true }
    }
    if (-not $initialize.codexHome) {
        Stop-AppServerClient -Client $client
        throw "Codex app-server initialized without a codexHome response."
    }

    $initialized = ConvertTo-AsciiJson @{ method = "initialized"; params = @{} }
    $process.StandardInput.WriteLine($initialized)
    $process.StandardInput.Flush()
    return $client
}

function Read-AppServerLine {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [int]$TimeoutMilliseconds = 30000
    )

    $task = $Client.Process.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($TimeoutMilliseconds)) {
        throw "Timed out waiting for Codex app-server."
    }
    return $task.Result
}

function Send-AppRequest {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Method,
        $Params = @{},
        [int]$TimeoutMilliseconds = 30000
    )

    $script:RequestId += 1
    $id = $script:RequestId
    $request = ConvertTo-AsciiJson @{
        method = $Method
        id = $id
        params = $Params
    }

    $Client.Process.StandardInput.WriteLine($request)
    $Client.Process.StandardInput.Flush()

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $line = Read-AppServerLine -Client $Client -TimeoutMilliseconds $remaining
        if ($null -eq $line) {
            $stderr = $Client.Process.StandardError.ReadToEnd()
            throw "Codex app-server closed before responding to $Method. $stderr"
        }
        if (-not $line.Trim()) {
            continue
        }
        try {
            $message = $line | ConvertFrom-Json
        }
        catch {
            continue
        }
        if ($message.id -eq $id) {
            if ($message.error) {
                throw "Codex app-server $Method failed: $($message.error | ConvertTo-Json -Compress -Depth 20)"
            }
            return $message.result
        }
    }
    throw "Timed out waiting for Codex app-server response to $Method."
}

function Stop-AppServerClient {
    param([Parameter(Mandatory = $true)]$Client)

    try { $Client.Process.StandardInput.Close() } catch {}
    try {
        if (-not $Client.Process.WaitForExit(2000)) {
            $Client.Process.Kill()
            $Client.Process.WaitForExit()
        }
    }
    catch {}
    $Client.Process.Dispose()
}

function Get-AllThreads {
    param([Parameter(Mandatory = $true)]$Client)

    $sourceKinds = @(
        "cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
        "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"
    )
    $result = @()
    foreach ($archived in @($false, $true)) {
        $page = Send-AppRequest -Client $Client -Method "thread/list" -Params @{
            limit = 1000
            sourceKinds = $sourceKinds
            archived = $archived
            sortKey = "updated_at"
            sortDirection = "desc"
        }
        foreach ($thread in @($page.data)) {
            $result += [pscustomobject]@{
                Thread = $thread
                Archived = [bool]$archived
            }
        }
    }
    return $result
}

function Get-SessionMetadataById {
    param(
        [Parameter(Mandatory = $true)][string]$DockerPath,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$ThreadId
    )

    if ($ThreadId -notmatch '^[0-9a-fA-F-]{36}$') {
        return $null
    }

    $template = 'export CODEX_HOME=/home/codex/.codex; f=$(find "$CODEX_HOME/sessions" -type f -name "*{0}*.jsonl" -print -quit 2>/dev/null); archived=false; if [ -z "$f" ]; then f=$(find "$CODEX_HOME/archived_sessions" -type f -name "*{0}*.jsonl" -print -quit 2>/dev/null); archived=true; fi; if [ -n "$f" ]; then echo "$archived"; head -n 1 "$f" | base64 -w0; fi'
    $lookup = Invoke-ContainerScript -DockerPath $DockerPath -Container $Container -Script ($template -f $ThreadId)
    if ($lookup.Output.Count -lt 2) {
        return $null
    }

    try {
        $metadataText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($lookup.Output[1].Trim()))
        $metadata = $metadataText | ConvertFrom-Json
    }
    catch {
        return $null
    }
    if ($metadata.type -ne "session_meta" -or -not $metadata.payload.cwd) {
        return $null
    }
    return [pscustomobject]@{
        Id = [string]$metadata.payload.id
        Cwd = [string]$metadata.payload.cwd
        Archived = ($lookup.Output[0].Trim() -eq "true")
    }
}

function Get-IndexedCommanderThreads {
    param(
        [Parameter(Mandatory = $true)][string]$DockerPath,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$BaseName,
        [string]$ExplicitName
    )

    $indexRead = Invoke-Docker -DockerPath $DockerPath -Arguments @(
        "exec", $Container, "base64", "-w0", "$script:CodexHome/session_index.jsonl"
    ) -AllowFailure
    if ($indexRead.ExitCode -ne 0 -or $indexRead.Output.Count -eq 0) {
        return @()
    }

    try {
        $encodedIndex = ($indexRead.Output -join "").Trim()
        $indexText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedIndex))
    }
    catch {
        return @()
    }

    $records = @()
    foreach ($line in $indexText -split "`r?`n") {
        if (-not $line.Trim()) {
            continue
        }
        try {
            $record = $line | ConvertFrom-Json
        }
        catch {
            continue
        }
        $name = [string]$record.thread_name
        if (-not $name) {
            continue
        }
        if ($name -ceq $ExplicitName -or $name -ceq $BaseName -or
            $name.Contains($script:CommanderToken) -or $name -match '(?i)commander') {
            $records += $record
        }
    }

    $result = @()
    foreach ($record in $records) {
        $metadata = Get-SessionMetadataById -DockerPath $DockerPath -Container $Container -ThreadId ([string]$record.id)
        if (-not $metadata) {
            continue
        }
        $thread = [pscustomobject]@{
            id = [string]$record.id
            name = [string]$record.thread_name
            cwd = [string]$metadata.Cwd
            source = "sessionIndex"
            updatedAt = [string]$record.updated_at
        }
        $result += [pscustomobject]@{
            Thread = $thread
            Archived = [bool]$metadata.Archived
        }
    }
    return $result
}

function Merge-ThreadInventory {
    param(
        [Parameter(Mandatory = $true)][object[]]$Primary,
        [Parameter(Mandatory = $true)][object[]]$Fallback
    )

    $byId = @{}
    foreach ($item in @($Primary) + @($Fallback)) {
        $id = [string]$item.Thread.id
        if (-not $id) {
            continue
        }
        if (-not $byId.ContainsKey($id)) {
            $byId[$id] = $item
        }
        elseif (-not $byId[$id].Thread.name -and $item.Thread.name) {
            $byId[$id] = $item
        }
    }
    return @($byId.Values)
}

function Select-CommanderThread {
    param(
        [Parameter(Mandatory = $true)][object[]]$Threads,
        [Parameter(Mandatory = $true)][string]$NormalizedProjectPath,
        [Parameter(Mandatory = $true)][string]$ExpectedName,
        [string]$ExplicitName,
        [string]$PreferredThreadId
    )

    $projectThreads = @($Threads | Where-Object {
        (Normalize-ContainerPath $_.Thread.cwd) -eq $NormalizedProjectPath
    })

    if ($PreferredThreadId) {
        $preferred = @($projectThreads | Where-Object { $_.Thread.id -eq $PreferredThreadId })
        if ($preferred.Count -ne 1) {
            throw "AdoptThreadId does not resolve to exactly one thread in this project: $PreferredThreadId"
        }
        return [pscustomobject]@{ Match = $preferred[0]; Adopt = $true }
    }

    if ($ExplicitName) {
        $exact = @($projectThreads | Where-Object { $_.Thread.name -ceq $ExplicitName })
        if ($exact.Count -gt 1) {
            throw "Multiple threads in the project have commander name '$ExplicitName': $($exact.Thread.id -join ', ')"
        }
        if ($exact.Count -eq 1) {
            return [pscustomobject]@{ Match = $exact[0]; Adopt = $false }
        }
        return $null
    }

    $preferredName = @($projectThreads | Where-Object { $_.Thread.name -ceq $ExpectedName })
    if ($preferredName.Count -eq 1) {
        return [pscustomobject]@{ Match = $preferredName[0]; Adopt = $false }
    }
    if ($preferredName.Count -gt 1) {
        throw "Multiple threads use expected commander name '$ExpectedName': $($preferredName.Thread.id -join ', ')"
    }

    $commanderCandidates = @($projectThreads | Where-Object {
        $name = [string]$_.Thread.name
        $name -and ($name.Contains($script:CommanderToken) -or $name -match '(?i)commander')
    })
    if ($commanderCandidates.Count -eq 1) {
        return [pscustomobject]@{ Match = $commanderCandidates[0]; Adopt = $false }
    }
    if ($commanderCandidates.Count -gt 1) {
        $labels = $commanderCandidates | ForEach-Object { "$($_.Thread.name) [$($_.Thread.id)]" }
        throw "Multiple commander candidates match this project: $($labels -join ', ')"
    }
    return $null
}

function Get-UniqueCommanderName {
    param(
        [Parameter(Mandatory = $true)][object[]]$Threads,
        [Parameter(Mandatory = $true)][string]$NormalizedProjectPath,
        [Parameter(Mandatory = $true)][string]$BaseName
    )

    $collision = @($Threads | Where-Object {
        $_.Thread.name -ceq $BaseName -and
        (Normalize-ContainerPath $_.Thread.cwd) -ne $NormalizedProjectPath
    })
    if ($collision.Count -eq 0) {
        return $BaseName
    }
    return "$BaseName$script:NameSeparator$(Get-ShortHash -Value $NormalizedProjectPath)"
}

function Invoke-CommanderTurn {
    param(
        [Parameter(Mandatory = $true)][string]$DockerPath,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][ValidateSet("read-only", "workspace-write")][string]$TurnSandbox
    )

    $promptBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Prompt))
    $projectBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Project))
    $threadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ThreadId))
    $innerTemplate = 'export CODEX_HOME={0}; PROJECT=$(echo {1} | base64 -d); THREAD=$(echo {2} | base64 -d); echo {3} | base64 -d | codex exec --sandbox {4} --cd "$PROJECT" --skip-git-repo-check --json resume "$THREAD" -'
    $inner = $innerTemplate -f $script:CodexHome, $projectBase64, $threadBase64, $promptBase64, $TurnSandbox
    $innerBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($inner))

    $run = Invoke-Docker -DockerPath $DockerPath -Arguments @(
        "exec", $Container, "bash", "-lc", "echo $innerBase64 | base64 -d | bash"
    )

    $threadIds = @()
    $agentMessages = @()
    foreach ($line in $run.Output) {
        try {
            $event = $line | ConvertFrom-Json
        }
        catch {
            continue
        }
        if ($event.type -eq "thread.started" -and $event.thread_id) {
            $threadIds += [string]$event.thread_id
        }
        if ($event.type -eq "item.completed" -and $event.item.type -eq "agent_message") {
            $agentMessages += [string]$event.item.text
        }
        if ($event.type -eq "turn.failed" -or $event.type -eq "error") {
            throw "Commander turn failed: $line"
        }
    }

    if ($threadIds.Count -eq 0 -or $threadIds[-1] -ne $ThreadId) {
        throw "Commander resume did not confirm the expected thread ID: $ThreadId"
    }
    if ($agentMessages.Count -eq 0) {
        throw "Commander turn completed without an agent message."
    }
    return $agentMessages[-1]
}

$dockerCommand = Get-Command docker -ErrorAction Stop
$dockerPath = $dockerCommand.Source
$projectCreated = $false

if ($NewProjectName) {
    if ($ListProjects -or $ProjectPath -or $AdoptThreadId -or $CommanderName -or $NoCreate) {
        throw "-NewProjectName cannot be combined with ListProjects, ProjectPath, AdoptThreadId, CommanderName, or NoCreate."
    }

    $newName = Assert-ValidProjectName $NewProjectName
    $newPath = "$script:ProjectRoot/$newName"
    $container = Resolve-CodexContainer -DockerPath $dockerPath -RequestedName $ContainerName
    $alreadyExists = Invoke-Docker -DockerPath $dockerPath -Arguments @("exec", $container, "test", "-e", $newPath) -AllowFailure
    if ($alreadyExists.ExitCode -eq 0) {
        throw "The workspace folder already exists. Use /project to connect instead of /new: $newPath"
    }

    if (-not $PSCmdlet.ShouldProcess($newPath, "Create project folder, initialize Git, and create its commander")) {
        [pscustomobject]@{
            status = "planned"
            action = "new-project"
            container = $container
            project_name = $newName
            project_path = $newPath
            steps = @("mkdir", "git init", "create commander")
        } | ConvertTo-Json -Depth 20
        return
    }

    Invoke-Docker -DockerPath $dockerPath -Arguments @("exec", $container, "mkdir", "--", $newPath) | Out-Null
    $folderCheck = Invoke-Docker -DockerPath $dockerPath -Arguments @("exec", $container, "test", "-d", $newPath) -AllowFailure
    if ($folderCheck.ExitCode -ne 0) {
        throw "Project folder creation did not produce the expected directory: $newPath"
    }

    $gitInit = Invoke-Docker -DockerPath $dockerPath -Arguments @("exec", $container, "git", "-C", $newPath, "init", "-b", "main") -AllowFailure
    if ($gitInit.ExitCode -ne 0) {
        $gitInit = Invoke-Docker -DockerPath $dockerPath -Arguments @("exec", $container, "git", "-C", $newPath, "init") -AllowFailure
    }
    if ($gitInit.ExitCode -ne 0) {
        throw "The project folder was created, but Git initialization failed: $newPath"
    }
    $gitCheck = Invoke-Docker -DockerPath $dockerPath -Arguments @("exec", $container, "test", "-d", "$newPath/.git") -AllowFailure
    if ($gitCheck.ExitCode -ne 0) {
        throw "Git initialization did not create .git in the new project folder: $newPath"
    }

    $ProjectPath = $newPath
    $ContainerName = $container
    $projectCreated = $true
}

if ($ListProjects) {
    if ($Message -or $ProjectPath -or $AdoptThreadId -or $NewProjectName) {
        throw "-ListProjects cannot be combined with ProjectPath, Message, AdoptThreadId, or NewProjectName."
    }

    $container = Resolve-CodexContainer -DockerPath $dockerPath -RequestedName $ContainerName
    $listScript = 'find /workspace/Documents -mindepth 2 -maxdepth 2 -type d -name .git -print0 | while IFS= read -r -d "" gitdir; do project=${gitdir%/.git}; printf "%s" "$project" | base64 -w0; printf "\n"; done'
    $projectRead = Invoke-ContainerScript -DockerPath $dockerPath -Container $container -Script $listScript
    $projectPaths = @()
    foreach ($encodedPath in $projectRead.Output) {
        if (-not $encodedPath.Trim()) {
            continue
        }
        try {
            $decodedPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedPath.Trim()))
            $projectPaths += Normalize-ContainerPath $decodedPath
        }
        catch {
            continue
        }
    }

    $client = $null
    try {
        $client = Start-AppServerClient -DockerPath $dockerPath -Container $container
        $appServerThreads = @(Get-AllThreads -Client $client)
        $indexedThreads = @(Get-IndexedCommanderThreads -DockerPath $dockerPath -Container $container -BaseName $script:CommanderToken)
        $threads = @(Merge-ThreadInventory -Primary $appServerThreads -Fallback $indexedThreads)
    }
    finally {
        if ($client) {
            Stop-AppServerClient -Client $client
        }
    }

    $projects = @()
    foreach ($path in @($projectPaths | Sort-Object -Unique)) {
        $candidates = @($threads | Where-Object {
            (Normalize-ContainerPath $_.Thread.cwd) -eq $path -and
            $_.Thread.name -and
            ($_.Thread.name.Contains($script:CommanderToken) -or $_.Thread.name -match '(?i)commander')
        })
        $state = if ($candidates.Count -eq 0) { "missing" } elseif ($candidates.Count -eq 1) { if ($candidates[0].Archived) { "archived" } else { "ready" } } else { "ambiguous" }
        $projects += [pscustomobject]@{
            project_name = Get-ProjectName $path
            project_path = $path
            commander_status = $state
            commander_name = if ($candidates.Count -eq 1) { [string]$candidates[0].Thread.name } else { $null }
            thread_id = if ($candidates.Count -eq 1) { [string]$candidates[0].Thread.id } else { $null }
            candidate_count = $candidates.Count
        }
    }

    [pscustomobject]@{
        status = "ok"
        action = "list"
        container = $container
        project_count = $projects.Count
        projects = $projects
    } | ConvertTo-Json -Depth 20
    return
}

if (-not $ProjectPath) {
    throw "ProjectPath is required unless -ListProjects is used."
}

$project = Normalize-ContainerPath $ProjectPath
if (-not ($project -eq $script:ProjectRoot -or $project.StartsWith("$script:ProjectRoot/"))) {
    throw "ProjectPath must be within $script:ProjectRoot: $project"
}

$lockName = "Local\CodexProjectCommander-$(Get-ShortHash -Value $project)"
$projectLock = New-Object Threading.Mutex($false, $lockName)
$lockTaken = $false
try {
    try {
        $lockTaken = $projectLock.WaitOne([TimeSpan]::FromMinutes(10))
    }
    catch [Threading.AbandonedMutexException] {
        $lockTaken = $true
    }
    if (-not $lockTaken) {
        throw "Timed out waiting for the project commander lock: $project"
    }

$container = Resolve-CodexContainer -DockerPath $dockerPath -RequestedName $ContainerName

$projectCheck = Invoke-Docker -DockerPath $dockerPath -Arguments @("exec", $container, "test", "-d", $project) -AllowFailure
if ($projectCheck.ExitCode -ne 0) {
    throw "Project directory does not exist in container '$container': $project"
}

$projectName = Get-ProjectName $project
$baseName = "$script:CommanderToken$script:NameSeparator$projectName"
$client = $null
$selected = $null
$action = "linked"
$reactivated = $false

try {
    $client = Start-AppServerClient -DockerPath $dockerPath -Container $container
    $appServerThreads = @(Get-AllThreads -Client $client)
    $indexedThreads = @(Get-IndexedCommanderThreads -DockerPath $dockerPath -Container $container -BaseName $baseName -ExplicitName $CommanderName)
    $threads = @(Merge-ThreadInventory -Primary $appServerThreads -Fallback $indexedThreads)
    Write-Verbose "App-server returned $($threads.Count) active and archived threads."
    foreach ($inventoryItem in $threads) {
        if ($inventoryItem.Thread.name -and
            ($inventoryItem.Thread.name.Contains($script:CommanderToken) -or $inventoryItem.Thread.name -match '(?i)commander')) {
            Write-Verbose "Commander candidate inventory: name='$($inventoryItem.Thread.name)' id='$($inventoryItem.Thread.id)' cwd='$($inventoryItem.Thread.cwd)' archived='$($inventoryItem.Archived)'"
        }
    }
    $expectedName = if ($CommanderName) { $CommanderName } else { Get-UniqueCommanderName -Threads $threads -NormalizedProjectPath $project -BaseName $baseName }
    $selection = Select-CommanderThread -Threads $threads -NormalizedProjectPath $project -ExpectedName $expectedName -ExplicitName $CommanderName -PreferredThreadId $AdoptThreadId

    if (-not $selection -and $CommanderName) {
        $foreignNameMatches = @($threads | Where-Object {
            $_.Thread.name -ceq $CommanderName -and
            (Normalize-ContainerPath $_.Thread.cwd) -ne $project
        })
        if ($foreignNameMatches.Count -gt 0) {
            $owners = $foreignNameMatches | ForEach-Object { "$($_.Thread.cwd) [$($_.Thread.id)]" }
            throw "Commander name '$CommanderName' already belongs to another project: $($owners -join ', ')"
        }
    }

    if ($selection) {
        $selected = $selection.Match
        if ($selected.Archived) {
            Send-AppRequest -Client $client -Method "thread/unarchive" -Params @{ threadId = $selected.Thread.id } | Out-Null
            $reactivated = $true
        }
        if ($selection.Adopt) {
            $nameToSet = if ($CommanderName) { $CommanderName } else { $expectedName }
            if ($selected.Thread.name -cne $nameToSet) {
                Send-AppRequest -Client $client -Method "thread/name/set" -Params @{
                    threadId = $selected.Thread.id
                    name = $nameToSet
                } | Out-Null
                $selected.Thread.name = $nameToSet
            }
            $action = "adopted"
        }
        elseif ($reactivated) {
            $action = "reactivated"
        }
    }
    else {
        if ($NoCreate) {
            throw "No commander exists for project '$project'. Creation was disabled by -NoCreate."
        }
        $created = Send-AppRequest -Client $client -Method "thread/start" -Params @{
            cwd = $project
            sandbox = "read-only"
            approvalPolicy = "never"
            ephemeral = $false
            developerInstructions = "You are the sole project commander. Maintain project context and act as the only external Codex window for this project. Receive tasks from an upstream Codex, coordinate inspection, implementation, tests, and final reporting. Do not act without a user task."
        }
        $newName = if ($CommanderName) { $CommanderName } else { $expectedName }
        Send-AppRequest -Client $client -Method "thread/name/set" -Params @{
            threadId = $created.thread.id
            name = $newName
        } | Out-Null
        $created.thread.name = $newName
        $selected = [pscustomobject]@{ Thread = $created.thread; Archived = $false }
        $action = "created"
    }
}
finally {
    if ($client) {
        Stop-AppServerClient -Client $client
    }
}

$response = $null
if ($Message) {
    $response = Invoke-CommanderTurn -DockerPath $dockerPath -Container $container -ThreadId $selected.Thread.id -Project $project -Prompt $Message -TurnSandbox $Sandbox
}
elseif ($action -eq "created") {
    $initialPrompt = "Confirm that you are the sole commander for project '$project'. Do not run commands or modify files. Reply with COMMANDER_READY, the project path, and your thread role."
    $response = Invoke-CommanderTurn -DockerPath $dockerPath -Container $container -ThreadId $selected.Thread.id -Project $project -Prompt $initialPrompt -TurnSandbox "read-only"
}

[pscustomobject]@{
    status = "ok"
    action = $action
    container = $container
    project_path = $project
    commander_name = [string]$selected.Thread.name
    thread_id = [string]$selected.Thread.id
    project_created = $projectCreated
    reactivated = $reactivated
    response = $response
} | ConvertTo-Json -Depth 20
}
finally {
    if ($lockTaken) {
        try { $projectLock.ReleaseMutex() } catch {}
    }
    $projectLock.Dispose()
}
