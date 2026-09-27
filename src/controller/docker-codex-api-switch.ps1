param(
  [ValidateSet("Gui", "Status", "StatusGui", "Profiles", "UseHost", "UseDocker", "CaptureDocker", "Reconnect", "RepairProfile")]
  [string]$Action = "Gui",
  [Alias("SkipRestart")]
  [switch]$SkipRecreate
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$Script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Script:Utf8NoBom
$global:OutputEncoding = $Script:Utf8NoBom

$Script:InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:SettingsPath = Join-Path $Script:InstallDir "settings.json"
function Write-BootstrapLog {
  param([string]$Message)

  $line = "{0} [startup] {1}{2}" -f (Get-Date).ToString("s"), $Message, [Environment]::NewLine
  $candidates = @(
    (Join-Path $Script:InstallDir "data\switcher.log"),
    (Join-Path ([System.IO.Path]::GetTempPath()) "DockerCodexSuite-startup.log")
  )
  foreach ($candidate in $candidates) {
    try {
      $parent = Split-Path -Parent $candidate
      if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
      }
      [System.IO.File]::AppendAllText($candidate, $line, (New-Object System.Text.UTF8Encoding($false)))
      return
    }
    catch {
    }
  }
}

$Script:Settings = [pscustomobject]@{}
if (Test-Path -LiteralPath $Script:SettingsPath) {
  try {
    $loadedSettings = Get-Content -LiteralPath $Script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $loadedSettings) {
      $Script:Settings = $loadedSettings
    }
  }
  catch {
    Write-BootstrapLog ("Unable to read settings.json at {0}: {1}" -f $Script:SettingsPath, $_.Exception.Message)
  }
}

function Get-SuiteSetting {
  param(
    [string]$Name,
    $Fallback = $null
  )

  $property = $Script:Settings.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return $Fallback
  }
  return $property.Value
}

function Resolve-SuitePath {
  param(
    [string]$Value,
    [string]$Fallback
  )

  $candidate = if ([string]::IsNullOrWhiteSpace($Value)) { $Fallback } else { $Value }
  $candidate = [Environment]::ExpandEnvironmentVariables($candidate)
  if (-not [System.IO.Path]::IsPathRooted($candidate)) {
    $candidate = Join-Path $Script:InstallDir $candidate
  }
  try {
    return [System.IO.Path]::GetFullPath($candidate)
  }
  catch {
    Write-BootstrapLog ("Invalid configured path '{0}', using fallback '{1}': {2}" -f $Value, $Fallback, $_.Exception.Message)
    return [System.IO.Path]::GetFullPath($Fallback)
  }
}

$Script:UserProfile = [Environment]::GetFolderPath("UserProfile")
$Script:DataDir = Resolve-SuitePath ([string](Get-SuiteSetting "dataDir" "data")) (Join-Path $Script:InstallDir "data")
$Script:ComposeDir = Resolve-SuitePath ([string](Get-SuiteSetting "composeDir" "")) (Join-Path $Script:UserProfile "DockerCodex")
$Script:DockerConfigPath = Join-Path $Script:ComposeDir "codex-home\config.toml"
$Script:LocalTemplatePath = Join-Path $Script:ComposeDir "codex-home\config.local-mode.toml"
$Script:HostConfigPath = Resolve-SuitePath ([string](Get-SuiteSetting "hostConfigPath" "")) (Join-Path $Script:UserProfile ".codex\config.toml")
$Script:HostAuthPath = Resolve-SuitePath ([string](Get-SuiteSetting "hostAuthPath" "")) (Join-Path $Script:UserProfile ".codex\auth.json")
$Script:DockerAuthPath = Join-Path $Script:ComposeDir "codex-home\auth.json"
$Script:DockerEnvPath = Join-Path $Script:ComposeDir ".env"
$Script:StatePath = Resolve-SuitePath ([string](Get-SuiteSetting "statePath" "")) (Join-Path $Script:DataDir "switch-state.json")
$Script:ProfilesPath = Resolve-SuitePath ([string](Get-SuiteSetting "profilesPath" "")) (Join-Path $Script:DataDir "api-profiles.json")
$Script:LogPath = Join-Path $Script:DataDir "switcher.log"
$Script:CodexPlusPlusSettingsPath = Resolve-SuitePath ([string](Get-SuiteSetting "codexPlusPlusSettingsPath" "")) (Join-Path $Script:UserProfile ".codex-session-delete\settings.json")
$Script:ChatProxyConfigPath = Resolve-SuitePath ([string](Get-SuiteSetting "chatProxyConfigPath" "")) (Join-Path $Script:DataDir "chat-proxy.json")
$Script:ChatProxyPort = [int](Get-SuiteSetting "chatProxyPort" 38119)
$Script:ModelCatalogFileName = "model-catalog.docker-api.json"
$Script:ModelCatalogPath = Join-Path $Script:ComposeDir ("codex-home\" + $Script:ModelCatalogFileName)
$Script:ReconnectHelperPath = Join-Path $Script:InstallDir "docker-codex-app-reconnect.js"
$Script:ProviderDoctorPath = Join-Path $Script:InstallDir "docker-codex-provider-doctor.js"
$Script:NodeExecutablePath = Resolve-SuitePath ([string](Get-SuiteSetting "nodePath" "")) (Join-Path $Script:InstallDir "runtime\node.exe")
$Script:CodexRemoteHostId = [string](Get-SuiteSetting "remoteHostId" "remote-ssh-discovered:docker-codex-suite")
$Script:ServiceName = [string](Get-SuiteSetting "serviceName" "codex-dev")
$Script:ContainerName = [string](Get-SuiteSetting "containerName" "docker-codex")
$Script:SshPort = [int](Get-SuiteSetting "sshPort" 2223)
$Script:ApiEnvKey = [string](Get-SuiteSetting "apiEnvKey" "DOCKER_CODEX_API_KEY")
$Script:LastRestartMethod = "none"
$Script:LastReconnectStatus = "not-requested"
$Script:LastRestartDurationMs = 0

function Read-FileText {
  param([string]$Path)

  if (-not (Test-Path $Path)) {
    throw "Missing file: $Path"
  }

  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-FileText {
  param(
    [string]$Path,
    [string]$Text
  )

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, $Text, $Script:Utf8NoBom)
}

function Protect-SensitiveText {
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) {
    return ""
  }

  $protected = $Text -replace '(?i)Bearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer [redacted]'
  $protected = $protected -replace '(?i)sk-[A-Za-z0-9_-]{8,}', 'sk-[redacted]'
  $protected = $protected -replace '(?i)([?&](?:api[_-]?key|token|access[_-]?token)=)[^&\s]+', '$1[redacted]'
  return $protected
}

function Write-SuiteLog {
  param(
    [string]$Area,
    [string]$Message
  )

  try {
    if (-not (Test-Path -LiteralPath $Script:DataDir)) {
      New-Item -ItemType Directory -Path $Script:DataDir -Force | Out-Null
    }
    $line = "{0} [{1}] {2}{3}" -f (Get-Date).ToString("s"), $Area, (Protect-SensitiveText $Message), [Environment]::NewLine
    [System.IO.File]::AppendAllText($Script:LogPath, $line, $Script:Utf8NoBom)
  }
  catch {
  }
}

function Get-LineArray {
  param([string]$Text)

  return $Text -split "\r?\n", -1
}

function Trim-BlankEdges {
  param([string[]]$Lines)

  if (-not $Lines) {
    return @()
  }

  $start = 0
  $end = $Lines.Count - 1

  while ($start -le $end -and [string]::IsNullOrWhiteSpace($Lines[$start])) {
    $start += 1
  }

  while ($end -ge $start -and [string]::IsNullOrWhiteSpace($Lines[$end])) {
    $end -= 1
  }

  if ($start -gt $end) {
    return @()
  }

  return $Lines[$start..$end]
}

function Normalize-Lines {
  param([string[]]$Lines)

  $trimmed = Trim-BlankEdges $Lines
  if (-not $trimmed) {
    return @()
  }

  $result = @()
  $previousBlank = $false

  foreach ($line in $trimmed) {
    $isBlank = [string]::IsNullOrWhiteSpace($line)
    if ($isBlank) {
      if (-not $previousBlank) {
        $result += ""
      }
    }
    else {
      $result += $line
    }
    $previousBlank = $isBlank
  }

  return $result
}

function Split-TomlContent {
  param([string]$Text)

  $lines = Get-LineArray $Text
  $topLevel = @()
  $sections = @()
  $currentHeader = $null
  $currentLines = @()

  foreach ($line in $lines) {
    if ($line -match '^\s*\[[^\]]+\]\s*$') {
      if ($null -ne $currentHeader) {
        $sections += [pscustomobject]@{
          Header = $currentHeader
          Lines  = $currentLines
        }
      }

      $currentHeader = $line.Trim()
      $currentLines = @($line)
    }
    else {
      if ($null -eq $currentHeader) {
        $topLevel += $line
      }
      else {
        $currentLines += $line
      }
    }
  }

  if ($null -ne $currentHeader) {
    $sections += [pscustomobject]@{
      Header = $currentHeader
      Lines  = $currentLines
    }
  }

  return [pscustomobject]@{
    TopLevel = $topLevel
    Sections = $sections
  }
}

function Get-ProviderTopLevelLines {
  param([string[]]$Lines)

  $pattern = '^\s*(model_provider|model|model_reasoning_effort|model_catalog_json|openai_base_url|chatgpt_base_url)\s*='
  return @($Lines | Where-Object { $_ -match $pattern })
}

function Get-NonProviderTopLevelLines {
  param([string[]]$Lines)

  $pattern = '^\s*(model_provider|model|model_reasoning_effort|model_catalog_json|openai_base_url|chatgpt_base_url)\s*='
  return @($Lines | Where-Object { $_ -notmatch $pattern })
}

function Get-ProviderSections {
  param([object[]]$Sections)

  return @($Sections | Where-Object { $_.Header -match '^\[model_providers\.[^\]]+\]$' })
}

function Get-NonProviderSections {
  param([object[]]$Sections)

  return @($Sections | Where-Object { $_.Header -notmatch '^\[model_providers\.[^\]]+\]$' })
}

function Join-ConfigLines {
  param(
    [string[]]$TopLevelLines,
    [object[]]$Sections
  )

  $result = @()
  $normalizedTop = Normalize-Lines $TopLevelLines
  if ($normalizedTop.Count -gt 0) {
    $result += $normalizedTop
  }

  foreach ($section in $Sections) {
    $normalizedSection = Normalize-Lines $section.Lines
    if ($normalizedSection.Count -eq 0) {
      continue
    }

    if ($result.Count -gt 0 -and $result[-1] -ne "") {
      $result += ""
    }

    $result += $normalizedSection
  }

  return (($result -join "`r`n").TrimEnd() + "`r`n")
}

function Ensure-LocalTemplate {
  if (-not (Test-Path $Script:LocalTemplatePath)) {
    Copy-Item -LiteralPath $Script:DockerConfigPath -Destination $Script:LocalTemplatePath -Force
  }
}

function Build-HostModeConfig {
  $localTemplateText = Read-FileText $Script:LocalTemplatePath
  $hostConfigText = Read-FileText $Script:HostConfigPath

  $localParts = Split-TomlContent $localTemplateText
  $hostParts = Split-TomlContent $hostConfigText

  $hostTop = Get-ProviderTopLevelLines $hostParts.TopLevel
  $localTop = Get-NonProviderTopLevelLines $localParts.TopLevel
  $hostProviderSections = Get-ProviderSections $hostParts.Sections
  $localOtherSections = Get-NonProviderSections $localParts.Sections

  $mergedTop = @()
  $mergedTop += $hostTop
  if ($hostTop.Count -gt 0 -and $localTop.Count -gt 0) {
    $mergedTop += ""
  }
  $mergedTop += $localTop

  $mergedSections = @()
  $mergedSections += $hostProviderSections
  $mergedSections += $localOtherSections

  return Join-ConfigLines -TopLevelLines $mergedTop -Sections $mergedSections
}

function Get-HostAuthJsonRequired {
  param([string]$ConfigText)

  return $ConfigText -match '(?m)^\s*requires_openai_auth\s*=\s*true\s*$'
}

function Get-ParsedHostKey {
  if (-not (Test-Path $Script:HostAuthPath)) {
    return $null
  }

  $auth = Get-Content -LiteralPath $Script:HostAuthPath -Raw -Encoding UTF8 | ConvertFrom-Json
  return Get-ObjectPropertyValue -Object $auth -Name "OPENAI_API_KEY" -Fallback $null
}

function Get-DockerEnvKey {
  if (-not (Test-Path $Script:DockerEnvPath)) {
    return $null
  }

  $prefix = [regex]::Escape($Script:ApiEnvKey) + '='
  $line = Get-Content -LiteralPath $Script:DockerEnvPath -Encoding UTF8 | Where-Object { $_ -match ('^' + $prefix) } | Select-Object -First 1
  if (-not $line) {
    return $null
  }

  return ($line -replace ('^' + $prefix), '')
}

function Get-DockerAuthKey {
  if (-not (Test-Path $Script:DockerAuthPath)) {
    return $null
  }

  $auth = Get-Content -LiteralPath $Script:DockerAuthPath -Raw -Encoding UTF8 | ConvertFrom-Json
  return Get-ObjectPropertyValue -Object $auth -Name "OPENAI_API_KEY" -Fallback $null
}

function Get-ConfigValue {
  param(
    [string]$Text,
    [string]$Key
  )

  $pattern = "(?m)^\s*" + [regex]::Escape($Key) + '\s*=\s*"([^"]+)"\s*$'
  $match = [regex]::Match($Text, $pattern)
  if ($match.Success) {
    return $match.Groups[1].Value
  }

  return $null
}

function ConvertTo-TomlString {
  param([string]$Value)

  if ($null -eq $Value) {
    $Value = ""
  }

  return '"' + ([string]$Value).Replace("\", "\\").Replace('"', '\"') + '"'
}

function ConvertTo-AuthContents {
  param([string]$ApiKey)

  $payload = [pscustomobject]@{
    OPENAI_API_KEY = $ApiKey
  }

  return (($payload | ConvertTo-Json -Depth 3) + "`r`n")
}

function Get-ProfileApiKey {
  param([object]$Profile)

  if ($null -eq $Profile) {
    return ""
  }
  $rawProfile = Get-ProfileRawObject -Profile $Profile
  $apiKey = [string](Get-ObjectPropertyValue -Object $rawProfile -Name "ApiKey")
  if (-not [string]::IsNullOrWhiteSpace($apiKey)) {
    return $apiKey
  }

  $authContents = [string](Get-ObjectPropertyValue -Object $Profile -Name "AuthContents")
  if ([string]::IsNullOrWhiteSpace($authContents)) {
    $authContents = [string](Get-ObjectPropertyValue -Object $rawProfile -Name "AuthContents")
  }
  if (-not [string]::IsNullOrWhiteSpace($authContents)) {
    try {
      $auth = $authContents | ConvertFrom-Json
      return [string](Get-ObjectPropertyValue -Object $auth -Name "OPENAI_API_KEY")
    }
    catch {
    }
  }
  return ""
}

function Get-ProfileModelIds {
  param([object]$Profile)

  if ($null -eq $Profile) {
    return @()
  }

  $modelList = Get-ObjectPropertyValue -Object $Profile -Name "ModelList" -Fallback $null
  if ($null -eq $modelList) {
    $modelList = Get-ObjectPropertyValue -Object (Get-ProfileRawObject -Profile $Profile) -Name "ModelList" -Fallback $null
  }
  $items = if ($modelList -is [System.Array]) {
    @($modelList)
  }
  else {
    @(([string]$modelList) -split '[\r\n,]+')
  }
  return @($items | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function ConvertFrom-ModelWindowValue {
  param(
    $Value,
    [long]$Fallback = 272000
  )

  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $Fallback
  }
  $match = [regex]::Match($text, '^(?<number>\d+)\s*(?<unit>[KkMm]?)$')
  if (-not $match.Success) {
    return $Fallback
  }
  $number = [long]$match.Groups["number"].Value
  $multiplier = switch ($match.Groups["unit"].Value.ToLowerInvariant()) {
    "k" { 1000 }
    "m" { 1000000 }
    default { 1 }
  }
  $result = $number * $multiplier
  if ($result -le 0) {
    return $Fallback
  }
  return $result
}

function Get-ProfileModelCatalogSpec {
  param(
    [object]$Profile,
    [string]$RawModelId
  )

  $modelId = $RawModelId.Trim()
  $suffixWindow = $null
  $suffixMatch = [regex]::Match($modelId, '^(?<slug>.+?)\[(?<window>\d+\s*[KkMm]?)\]$')
  if ($suffixMatch.Success) {
    $modelId = $suffixMatch.Groups["slug"].Value.Trim()
    $suffixWindow = ConvertFrom-ModelWindowValue -Value $suffixMatch.Groups["window"].Value
  }

  $rawProfile = Get-ProfileRawObject -Profile $Profile
  $fallbackWindow = ConvertFrom-ModelWindowValue -Value (Get-ObjectPropertyValue -Object $rawProfile -Name "ContextWindow")
  $modelWindows = Get-ObjectPropertyValue -Object $rawProfile -Name "ModelWindows" -Fallback $null
  $configuredWindow = if ($null -eq $modelWindows) {
    $null
  }
  else {
    Get-ObjectPropertyValue -Object $modelWindows -Name $modelId -Fallback $null
  }
  $contextWindow = if ($null -ne $suffixWindow) {
    [long]$suffixWindow
  }
  elseif ($null -ne $configuredWindow -and -not [string]::IsNullOrWhiteSpace([string]$configuredWindow)) {
    ConvertFrom-ModelWindowValue -Value $configuredWindow -Fallback $fallbackWindow
  }
  else {
    $fallbackWindow
  }

  return [pscustomobject]@{
    Id            = $modelId
    ContextWindow = [long]$contextWindow
  }
}

function New-ProfileModelCatalogEntry {
  param(
    [string]$ModelId,
    [long]$ContextWindow,
    [int]$Priority,
    [bool]$SupportsImages
  )

  $reasoningLevels = @(
    [ordered]@{ effort = "low"; description = "Fast responses with lighter reasoning" }
    [ordered]@{ effort = "medium"; description = "Balanced reasoning for everyday tasks" }
    [ordered]@{ effort = "high"; description = "Deeper reasoning for complex tasks" }
    [ordered]@{ effort = "xhigh"; description = "Extra reasoning for difficult tasks" }
  )
  [string[]]$inputModalities = if ($SupportsImages) { @("text", "image") } else { @("text") }
  $baseInstructions = "You are Codex, an expert coding agent. Follow system, developer, and user instructions; inspect the workspace before editing; use the provided tools carefully; preserve unrelated changes; verify completed work; and report results clearly."

  return [ordered]@{
    slug                             = $ModelId
    display_name                     = $ModelId
    description                      = "Model from the active Docker Codex API profile."
    base_instructions                = $baseInstructions
    default_reasoning_level          = "medium"
    supported_reasoning_levels       = $reasoningLevels
    shell_type                       = "shell_command"
    visibility                       = "list"
    supported_in_api                 = $true
    priority                         = $Priority
    context_window                   = $ContextWindow
    max_context_window               = $ContextWindow
    effective_context_window_percent = 100
    auto_compact_token_limit         = $null
    input_modalities                 = $inputModalities
    supports_personality             = $false
    supports_reasoning_summaries     = $true
    default_reasoning_summary        = "auto"
    support_verbosity                = $true
    default_verbosity                = "medium"
    apply_patch_tool_type            = "freeform"
    web_search_tool_type             = "text"
    supports_parallel_tool_calls     = $true
    supports_search_tool             = $true
    additional_speed_tiers           = @()
    service_tiers                    = @()
    availability_nux                 = $null
    upgrade                          = $null
    experimental_supported_tools     = @()
    truncation_policy                = [ordered]@{ mode = "tokens"; limit = 10000 }
  }
}

function Set-ProfileModelCatalog {
  param(
    [object]$Profile,
    [string]$ConfigText
  )

  $rawProfile = Get-ProfileRawObject -Profile $Profile
  $defaultModel = [string](Get-ObjectPropertyValue -Object $Profile -Name "Model")
  if ([string]::IsNullOrWhiteSpace($defaultModel)) {
    $defaultModel = [string](Get-ObjectPropertyValue -Object $rawProfile -Name "Model")
  }
  if ([string]::IsNullOrWhiteSpace($defaultModel)) {
    $defaultModel = Get-ConfigValue -Text $ConfigText -Key "model"
  }

  $orderedIds = @()
  if (-not [string]::IsNullOrWhiteSpace($defaultModel)) {
    $orderedIds += $defaultModel
  }
  $orderedIds += @(Get-ProfileModelIds -Profile $Profile)

  $entries = @()
  $seen = @{}
  $supportsImages = [string](Get-ObjectPropertyValue -Object $Profile -Name "UpstreamProtocol") -ne "chat"
  foreach ($rawModelId in $orderedIds) {
    if ([string]::IsNullOrWhiteSpace([string]$rawModelId)) {
      continue
    }
    $spec = Get-ProfileModelCatalogSpec -Profile $Profile -RawModelId ([string]$rawModelId)
    if ([string]::IsNullOrWhiteSpace($spec.Id) -or $seen.ContainsKey($spec.Id)) {
      continue
    }
    $seen[$spec.Id] = $true
    $entries += New-ProfileModelCatalogEntry `
      -ModelId $spec.Id `
      -ContextWindow $spec.ContextWindow `
      -Priority (1000 + $entries.Count) `
      -SupportsImages $supportsImages
  }
  if ($entries.Count -eq 0) {
    throw "这个 API 配置没有可写入 Codex 模型目录的模型。"
  }

  $catalog = [ordered]@{ models = @($entries) }
  Write-FileText `
    -Path $Script:ModelCatalogPath `
    -Text (($catalog | ConvertTo-Json -Depth 12) + "`r`n")

  $parts = Split-TomlContent $ConfigText
  $topLevel = @($parts.TopLevel | Where-Object { $_ -notmatch '^\s*model_catalog_json\s*=' })
  $topLevel += ('model_catalog_json = {0}' -f (ConvertTo-TomlString $Script:ModelCatalogFileName))
  return Join-ConfigLines -TopLevelLines $topLevel -Sections $parts.Sections
}

function Start-ProviderDoctorProcess {
  param([object]$Request)

  if (-not (Test-Path -LiteralPath $Script:ProviderDoctorPath)) {
    throw "Provider Doctor 文件不存在：$($Script:ProviderDoctorPath)"
  }
  if (-not (Test-Path -LiteralPath $Script:NodeExecutablePath)) {
    throw "Node.js 运行时不存在：$($Script:NodeExecutablePath)"
  }

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $Script:NodeExecutablePath
  $startInfo.Arguments = '"' + $Script:ProviderDoctorPath.Replace('"', '\"') + '"'
  $startInfo.WorkingDirectory = $Script:InstallDir
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.StandardOutputEncoding = $Script:Utf8NoBom
  $startInfo.StandardErrorEncoding = $Script:Utf8NoBom

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    $process.Dispose()
    throw "Provider Doctor 进程启动失败。"
  }
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $requestJson = $Request | ConvertTo-Json -Depth 8 -Compress
  $process.StandardInput.Write($requestJson)
  $process.StandardInput.Close()

  return [pscustomobject]@{
    Process    = $process
    StdoutTask = $stdoutTask
    StderrTask = $stderrTask
  }
}

function Build-ProfileModeConfig {
  param([string]$ProfileConfigText)

  Ensure-LocalTemplate

  $ProfileConfigText = Convert-ConfigForDockerNetworking -ConfigText $ProfileConfigText
  $localTemplateText = Read-FileText $Script:LocalTemplatePath
  $localParts = Split-TomlContent $localTemplateText
  $profileParts = Split-TomlContent $ProfileConfigText

  $profileTop = Get-ProviderTopLevelLines $profileParts.TopLevel
  $localTop = Get-NonProviderTopLevelLines $localParts.TopLevel
  $profileProviderSections = Get-ProviderSections $profileParts.Sections
  $localOtherSections = Get-NonProviderSections $localParts.Sections

  $mergedTop = @()
  $mergedTop += $profileTop
  if ($profileTop.Count -gt 0 -and $localTop.Count -gt 0) {
    $mergedTop += ""
  }
  $mergedTop += $localTop

  $mergedSections = @()
  $mergedSections += $profileProviderSections
  $mergedSections += $localOtherSections

  return Join-ConfigLines -TopLevelLines $mergedTop -Sections $mergedSections
}

function Convert-ConfigForDockerNetworking {
  param([string]$ConfigText)

  return [regex]::Replace(
    $ConfigText,
    '(?m)^(\s*base_url\s*=\s*")http://(127\.0\.0\.1|localhost)(:\d+/[^"]*)(")\s*$',
    '$1http://host.docker.internal$3$4'
  )
}

function New-LocalProfileConfigText {
  param(
    [object]$Profile,
    [switch]$UseProxy
  )

  $model = Get-DisplayValue $Profile.Model "gpt-5.5"
  $upstreamProtocol = [string](Get-ObjectPropertyValue -Object $Profile -Name "UpstreamProtocol" -Fallback "responses")
  $baseUrl = if ($UseProxy) {
    "http://127.0.0.1:$($Script:ChatProxyPort)/v1"
  }
  else {
    Get-DisplayValue $Profile.BaseUrl "https://api.openai.com/v1"
  }
  $wireApi = Get-DisplayValue $Profile.WireApi "responses"

  $providerLines = @(
    'model_provider = "custom"'
    ('model = {0}' -f (ConvertTo-TomlString $model))
    'model_reasoning_effort = "xhigh"'
    ''
    '[model_providers.custom]'
    'name = "custom"'
    ('wire_api = {0}' -f (ConvertTo-TomlString $wireApi))
    ('base_url = {0}' -f (ConvertTo-TomlString $baseUrl))
  )

  if (-not [string]::IsNullOrWhiteSpace($Profile.ApiKey)) {
    $providerLines += 'requires_openai_auth = true'
  }
  else {
    $envKey = Get-DisplayValue $Profile.EnvKey $Script:ApiEnvKey
    $providerLines += ('env_key = {0}' -f (ConvertTo-TomlString $envKey))
  }

  return (($providerLines -join "`r`n") + "`r`n")
}

function Convert-ProfileConfigToProxy {
  param([string]$ConfigText)

  if ([string]::IsNullOrWhiteSpace($ConfigText)) {
    throw "Responses API 配置为空，无法接入兼容网关。"
  }
  $proxyUrl = "http://127.0.0.1:$($Script:ChatProxyPort)/v1"
  $converted = [regex]::Replace(
    $ConfigText,
    '(?m)^(\s*base_url\s*=\s*")[^"]*("\s*)$',
    ('$1' + $proxyUrl + '$2')
  )
  if ($converted -eq $ConfigText -and $converted -notmatch '(?m)^\s*base_url\s*=') {
    $converted = $converted.TrimEnd() + "`r`nbase_url = `"$proxyUrl`"`r`n"
  }
  return $converted
}

function Get-ChatProxyHealth {
  try {
    return Invoke-RestMethod `
      -Uri "http://127.0.0.1:$($Script:ChatProxyPort)/health" `
      -Method Get `
      -TimeoutSec 2 `
      -ErrorAction Stop
  }
  catch {
    return $null
  }
}

function Set-ApiProxyProfile {
  param(
    [object]$Profile,
    [ValidateSet("chat", "responses")][string]$Protocol,
    [switch]$SkipHealthCheck
  )

  $rawProfile = Get-ProfileRawObject -Profile $Profile
  $upstreamBaseUrl = [string](Get-ObjectPropertyValue -Object $rawProfile -Name "BaseUrl")
  if ([string]::IsNullOrWhiteSpace($upstreamBaseUrl)) {
    $upstreamBaseUrl = [string](Get-ObjectPropertyValue -Object $Profile -Name "BaseUrl")
  }
  $upstreamBaseUrl = $upstreamBaseUrl.Trim().TrimEnd("/")
  $uri = $null
  if (-not [Uri]::TryCreate($upstreamBaseUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @("http", "https")) {
    throw "$Protocol 配置的上游 Base URL 无效：$upstreamBaseUrl"
  }
  if ($uri.Host -in @("127.0.0.1", "localhost", "::1") -and $uri.Port -eq $Script:ChatProxyPort) {
    throw "$Protocol 配置的上游地址不能指向转换器自身。"
  }
  if ([string]::IsNullOrWhiteSpace((Get-ProfileApiKey -Profile $Profile))) {
    throw "$Protocol 配置缺少 API Key，无法安全转发到上游。"
  }

  $profileId = [string](Get-ObjectPropertyValue -Object $rawProfile -Name "Id")
  $payload = [ordered]@{
    version         = 1
    enabled         = $true
    profileId       = $profileId
    profileName     = [string](Get-ObjectPropertyValue -Object $rawProfile -Name "Name")
    protocol        = $Protocol
    upstreamBaseUrl = $upstreamBaseUrl
    updatedAt       = (Get-Date).ToUniversalTime().ToString("o")
  }
  $previousExists = Test-Path -LiteralPath $Script:ChatProxyConfigPath
  $previousText = if ($previousExists) { Read-FileText -Path $Script:ChatProxyConfigPath } else { "" }
  try {
    Write-FileText `
      -Path $Script:ChatProxyConfigPath `
      -Text (($payload | ConvertTo-Json -Depth 4) + "`r`n")
    if (-not $SkipHealthCheck) {
      $health = Get-ChatProxyHealth
      if ($null -eq $health -or [string]$health.service -ne "docker-codex-chat-proxy") {
        throw "内置 API 兼容网关没有运行。请重启 Docker Codex Suite Bridge 后重试。"
      }
      if ((-not [bool]$health.enabled) -or ([string]$health.profileId -ne $profileId) -or ([string]$health.protocol -ne $Protocol)) {
        throw "内置 API 兼容网关没有加载当前 $Protocol 配置。"
      }
    }
  }
  catch {
    if ($previousExists) {
      Write-FileText -Path $Script:ChatProxyConfigPath -Text $previousText
    }
    elseif (Test-Path -LiteralPath $Script:ChatProxyConfigPath) {
      Remove-Item -LiteralPath $Script:ChatProxyConfigPath -Force
    }
    throw
  }
}

function Set-ChatProxyProfile {
  param(
    [object]$Profile,
    [switch]$SkipHealthCheck
  )
  Set-ApiProxyProfile -Profile $Profile -Protocol "chat" -SkipHealthCheck:$SkipHealthCheck
}

function Set-ResponsesProxyProfile {
  param(
    [object]$Profile,
    [switch]$SkipHealthCheck
  )
  Set-ApiProxyProfile -Profile $Profile -Protocol "responses" -SkipHealthCheck:$SkipHealthCheck
}

function ConvertTo-CodexPlusPlusImportId {
  param([string]$SourceId)

  $safe = [regex]::Replace($SourceId.Trim().ToLowerInvariant(), '[^a-z0-9_-]+', '-')
  $safe = $safe.Trim('-')
  if ([string]::IsNullOrWhiteSpace($safe)) {
    $safe = [Guid]::NewGuid().ToString("N")
  }
  return "codexpp-$safe"
}

function Get-CodexPlusPlusProfileApiKey {
  param(
    [object]$Profile,
    [object]$Settings
  )

  $apiKey = [string](Get-ObjectPropertyValue -Object $Profile -Name "apiKey")
  if (-not [string]::IsNullOrWhiteSpace($apiKey)) {
    return $apiKey.Trim()
  }

  $authContents = [string](Get-ObjectPropertyValue -Object $Profile -Name "authContents")
  if (-not [string]::IsNullOrWhiteSpace($authContents)) {
    try {
      $auth = $authContents | ConvertFrom-Json
      foreach ($name in @("OPENAI_API_KEY", "apiKey", "api_key", "token")) {
        $value = [string](Get-ObjectPropertyValue -Object $auth -Name $name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
          return $value.Trim()
        }
      }
    }
    catch {
    }
  }

  $configContents = [string](Get-ObjectPropertyValue -Object $Profile -Name "configContents")
  $embeddedToken = Get-ConfigValue -Text $configContents -Key "experimental_bearer_token"
  if (-not [string]::IsNullOrWhiteSpace($embeddedToken)) {
    return $embeddedToken.Trim()
  }

  $sourceId = [string](Get-ObjectPropertyValue -Object $Profile -Name "id")
  if ($sourceId -eq [string](Get-ObjectPropertyValue -Object $Settings -Name "activeRelayId")) {
    $legacyKey = [string](Get-ObjectPropertyValue -Object $Settings -Name "relayApiKey")
    if (-not [string]::IsNullOrWhiteSpace($legacyKey)) {
      return $legacyKey.Trim()
    }
  }
  return ""
}

function ConvertFrom-CodexPlusPlusProfile {
  param(
    [object]$Profile,
    [object]$Settings,
    [string]$SourcePath
  )

  $sourceId = [string](Get-ObjectPropertyValue -Object $Profile -Name "id")
  $name = [string](Get-ObjectPropertyValue -Object $Profile -Name "name")
  if ([string]::IsNullOrWhiteSpace($sourceId)) {
    throw "配置 ID 为空，无法稳定地重复导入。"
  }
  if ([string]::IsNullOrWhiteSpace($name)) {
    throw "配置名称为空。"
  }
  $relayMode = [string](Get-ObjectPropertyValue -Object $Profile -Name "relayMode")
  if ($relayMode -eq "aggregate") {
    throw "聚合配置包含多个上游，不能作为单一 Docker API 配置导入。"
  }

  $sourceProtocol = [string](Get-ObjectPropertyValue -Object $Profile -Name "protocol")
  $upstreamProtocol = switch ($sourceProtocol.ToLowerInvariant()) {
    "chatcompletions" { "chat" }
    "chat" { "chat" }
    "responses" { "responses" }
    default { throw "不支持的协议：$sourceProtocol" }
  }
  $configContents = [string](Get-ObjectPropertyValue -Object $Profile -Name "configContents")
  $upstreamBaseUrl = [string](Get-ObjectPropertyValue -Object $Profile -Name "upstreamBaseUrl")
  if ([string]::IsNullOrWhiteSpace($upstreamBaseUrl)) {
    $upstreamBaseUrl = Get-ConfigValue -Text $configContents -Key "base_url"
    $candidateUri = $null
    if ([Uri]::TryCreate($upstreamBaseUrl, [UriKind]::Absolute, [ref]$candidateUri) -and
        $candidateUri.Host -in @("127.0.0.1", "localhost", "::1") -and
        $candidateUri.Port -eq 57321) {
      $upstreamBaseUrl = ""
    }
  }
  $upstreamBaseUrl = $upstreamBaseUrl.Trim().TrimEnd("/")
  $uri = $null
  if (-not [Uri]::TryCreate($upstreamBaseUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @("http", "https")) {
    throw "缺少有效的真实上游 Base URL。"
  }
  if ($uri.Host -in @("127.0.0.1", "localhost", "::1") -and $uri.Port -eq 57321) {
    throw "仅找到 Codex++ 本地转发地址，缺少可独立使用的真实上游 Base URL。"
  }

  $modelList = [string](Get-ObjectPropertyValue -Object $Profile -Name "modelList")
  $model = Get-ConfigValue -Text $configContents -Key "model"
  if ([string]::IsNullOrWhiteSpace($model)) {
    $model = [string](Get-ObjectPropertyValue -Object $Profile -Name "testModel")
  }
  if ([string]::IsNullOrWhiteSpace($model)) {
    $model = $modelList -split '[\r\n,]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
  }
  $model = [string]$model
  if ([string]::IsNullOrWhiteSpace($model)) {
    throw "缺少可用模型名称。"
  }

  $apiKey = Get-CodexPlusPlusProfileApiKey -Profile $Profile -Settings $Settings
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    throw "缺少可导出的 API Key。"
  }

  $now = (Get-Date).ToString("s")
  $result = [pscustomobject]@{
    Id               = ConvertTo-CodexPlusPlusImportId -SourceId $sourceId
    Name             = $name.Trim()
    BaseUrl          = $upstreamBaseUrl
    Model            = $model.Trim()
    ModelList        = $modelList
    UpstreamProtocol = $upstreamProtocol
    WireApi          = "responses"
    ApiKey           = $apiKey
    EnvKey           = $Script:ApiEnvKey
    ConfigContents   = ""
    AuthContents     = ConvertTo-AuthContents -ApiKey $apiKey
    ImportedFrom     = "codexplusplus"
    SourceProfileId  = $sourceId
    SourcePath       = $SourcePath
    SourceRelayMode  = $relayMode
    CreatedAt        = $now
    UpdatedAt        = $now
  }
  # Imported Chat profiles must describe the standalone local adapter in their
  # preview config. Native Responses profiles retain the real upstream here and
  # are redirected only when they are activated for Docker.
  $result.ConfigContents = if ($upstreamProtocol -eq "chat") {
    New-LocalProfileConfigText -Profile $result -UseProxy
  }
  else {
    New-LocalProfileConfigText -Profile $result
  }
  return $result
}

function Get-CodexPlusPlusImportCandidates {
  param([string]$Path = $Script:CodexPlusPlusSettingsPath)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "没有找到 Codex++ 配置文件：$Path"
  }
  try {
    $settings = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  }
  catch {
    throw "Codex++ 配置文件无法解析：$Path"
  }

  $activeRelayId = [string](Get-ObjectPropertyValue -Object $settings -Name "activeRelayId")
  $result = @()
  foreach ($sourceProfile in @(Get-ObjectPropertyValue -Object $settings -Name "relayProfiles")) {
    $sourceId = [string](Get-ObjectPropertyValue -Object $sourceProfile -Name "id")
    $name = Get-DisplayValue (Get-ObjectPropertyValue -Object $sourceProfile -Name "name") "未命名"
    try {
      $profile = ConvertFrom-CodexPlusPlusProfile -Profile $sourceProfile -Settings $settings -SourcePath $Path
      $protocolLabel = if ($profile.UpstreamProtocol -eq "chat") { "Chat → Responses" } else { "Responses" }
      $modelCount = @(Get-ProfileModelIds -Profile $profile).Count
      $result += [pscustomobject]@{
        DisplayName = "$name  |  $protocolLabel  |  $modelCount 个模型"
        Name        = $name
        CanImport   = $true
        Reason      = "可导入"
        IsActive    = $sourceId -eq $activeRelayId
        Profile     = $profile
      }
    }
    catch {
      $reason = Protect-SensitiveText $_.Exception.Message
      $result += [pscustomobject]@{
        DisplayName = "$name  |  不可导入：$reason"
        Name        = $name
        CanImport   = $false
        Reason      = $reason
        IsActive    = $sourceId -eq $activeRelayId
        Profile     = $null
      }
    }
  }
  return $result
}

function Import-CodexPlusPlusProfiles {
  param([object[]]$Candidates)

  $profiles = @(Read-LocalProfiles)
  $added = 0
  $updated = 0
  $skipped = 0
  $importedIds = @()
  foreach ($candidate in @($Candidates)) {
    if ($null -eq $candidate -or -not [bool]$candidate.CanImport -or $null -eq $candidate.Profile) {
      $skipped += 1
      continue
    }
    $profile = $candidate.Profile
    $sourceProfileId = [string]$profile.SourceProfileId
    $existingIndex = -1
    for ($index = 0; $index -lt $profiles.Count; $index += 1) {
      if ([string](Get-ObjectPropertyValue -Object $profiles[$index] -Name "ImportedFrom") -eq "codexplusplus" -and
          [string](Get-ObjectPropertyValue -Object $profiles[$index] -Name "SourceProfileId") -eq $sourceProfileId) {
        $existingIndex = $index
        break
      }
    }
    if ($existingIndex -ge 0) {
      $createdAt = [string](Get-ObjectPropertyValue -Object $profiles[$existingIndex] -Name "CreatedAt")
      if (-not [string]::IsNullOrWhiteSpace($createdAt)) {
        $profile.CreatedAt = $createdAt
      }
      $profile.UpdatedAt = (Get-Date).ToString("s")
      $profiles[$existingIndex] = $profile
      $updated += 1
    }
    else {
      $baseId = [string]$profile.Id
      $candidateId = $baseId
      $suffix = 2
      while (@($profiles | Where-Object { [string]$_.Id -eq $candidateId }).Count -gt 0) {
        $candidateId = "$baseId-$suffix"
        $suffix += 1
      }
      $profile.Id = $candidateId
      $profiles += $profile
      $added += 1
    }
    $importedIds += [string]$profile.Id
  }
  if ($added -gt 0 -or $updated -gt 0) {
    Save-LocalProfiles -Profiles $profiles
  }
  return [pscustomobject]@{
    Added       = $added
    Updated     = $updated
    Skipped     = $skipped
    ImportedIds = $importedIds
  }
}

function Read-LocalProfiles {
  if (-not (Test-Path $Script:ProfilesPath)) {
    return @()
  }

  try {
    $items = Get-Content -LiteralPath $Script:ProfilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($items | Where-Object { $null -ne $_ })
  }
  catch {
    return @()
  }
}

function Save-LocalProfiles {
  param([object[]]$Profiles)

  $json = ConvertTo-Json -InputObject @($Profiles) -Depth 8
  Write-FileText -Path $Script:ProfilesPath -Text ($json + "`r`n")
}

function Add-LocalProfile {
  param([object]$Profile)

  Save-LocalProfile -Profile $Profile
}

function Save-LocalProfile {
  param([object]$Profile)

  $profiles = @(Read-LocalProfiles)
  $updated = @()
  $replaced = $false
  foreach ($item in $profiles) {
    if ([string]$item.Id -eq [string]$Profile.Id) {
      $updated += $Profile
      $replaced = $true
    }
    else {
      $updated += $item
    }
  }
  if (-not $replaced) {
    $updated += $Profile
  }
  Save-LocalProfiles -Profiles $updated
}

function Remove-LocalProfile {
  param([string]$Id)

  $profiles = @(Read-LocalProfiles)
  $updated = @($profiles | Where-Object { [string]$_.Id -ne $Id })
  if ($updated.Count -eq $profiles.Count) {
    throw "没有找到要删除的本地 API 配置。"
  }
  Save-LocalProfiles -Profiles $updated
}

function Get-ProfileSummaryObject {
  param(
    [string]$Id,
    [string]$Source,
    [string]$Name,
    [string]$ConfigContents,
    [string]$AuthContents,
    $ModelList = "",
    [string]$UpstreamBaseUrl = "",
    [object]$RawProfile = $null
  )

  $model = Get-ConfigValue -Text $ConfigContents -Key "model"
  $provider = Get-ConfigValue -Text $ConfigContents -Key "model_provider"
  $wireApi = Get-ConfigValue -Text $ConfigContents -Key "wire_api"
  $baseUrl = Get-ConfigValue -Text $ConfigContents -Key "base_url"
  if ([string]::IsNullOrWhiteSpace($baseUrl)) {
    $baseUrl = $UpstreamBaseUrl
  }

  $authMode = if ($ConfigContents -match '(?m)^\s*requires_openai_auth\s*=\s*true\s*$') {
    "auth.json"
  }
  elseif ($ConfigContents -match '(?m)^\s*env_key\s*=\s*"([^"]+)"\s*$') {
    "env:$($Matches[1])"
  }
  elseif (-not [string]::IsNullOrWhiteSpace($AuthContents)) {
    "auth.json"
  }
  else {
    "unknown"
  }

  $upstreamProtocol = Get-ObjectPropertyValue -Object $RawProfile -Name "UpstreamProtocol"
  if ([string]::IsNullOrWhiteSpace([string]$upstreamProtocol)) {
    $upstreamProtocol = if ($wireApi -eq "chat") { "chat" } else { "responses" }
  }
  if ([string]$upstreamProtocol -eq "chat") {
    $rawBaseUrl = [string](Get-ObjectPropertyValue -Object $RawProfile -Name "BaseUrl")
    if (-not [string]::IsNullOrWhiteSpace($rawBaseUrl)) {
      $baseUrl = $rawBaseUrl
    }
  }

  $normalizedModelList = if ($ModelList -is [System.Array]) {
    (@($ModelList) | ForEach-Object { [string]$_ }) -join "`r`n"
  }
  else {
    [string]$ModelList
  }

  return [pscustomobject]@{
    Id             = $Id
    Source         = $Source
    Name           = $Name
    DisplayName    = "$Source：$Name"
    Model          = $model
    Provider       = $provider
    BaseUrl        = $baseUrl
    UpstreamProtocol = [string]$upstreamProtocol
    AuthMode       = $authMode
    ConfigContents = $ConfigContents
    AuthContents   = $AuthContents
    ModelList      = $normalizedModelList
    RawProfile     = $RawProfile
  }
}

function Get-LocalApiProfiles {
  $result = @()
  foreach ($profile in @(Read-LocalProfiles)) {
    $storedConfig = Get-ObjectPropertyValue -Object $profile -Name "ConfigContents"
    if (-not [string]::IsNullOrWhiteSpace($storedConfig)) {
      $configContents = $storedConfig
      $authContents = Get-ObjectPropertyValue -Object $profile -Name "AuthContents"
      $modelList = Get-ObjectPropertyValue -Object $profile -Name "ModelList"
      $upstreamBaseUrl = Get-ObjectPropertyValue -Object $profile -Name "UpstreamBaseUrl"
    }
    else {
      $configContents = New-LocalProfileConfigText -Profile $profile
      $apiKey = Get-ObjectPropertyValue -Object $profile -Name "ApiKey"
      $authContents = if ([string]::IsNullOrWhiteSpace($apiKey)) {
        ""
      }
      else {
        ConvertTo-AuthContents -ApiKey $apiKey
      }
      $modelList = Get-ObjectPropertyValue -Object $profile -Name "ModelList"
      if ($null -eq $modelList -or [string]::IsNullOrWhiteSpace([string]$modelList)) {
        $modelList = Get-ObjectPropertyValue -Object $profile -Name "Model"
      }
      $upstreamBaseUrl = Get-ObjectPropertyValue -Object $profile -Name "BaseUrl"
    }

    $source = if ([string](Get-ObjectPropertyValue -Object $profile -Name "ImportedFrom") -eq "codexplusplus") {
      "Codex++ 导入"
    }
    else {
      "本地"
    }
    $result += Get-ProfileSummaryObject `
      -Id ("local:" + $profile.Id) `
      -Source $source `
      -Name (Get-DisplayValue $profile.Name "未命名") `
      -ConfigContents $configContents `
      -AuthContents $authContents `
      -ModelList $modelList `
      -UpstreamBaseUrl $upstreamBaseUrl `
      -RawProfile $profile
  }

  return $result
}

function Get-ApiProfiles {
  return @(Get-LocalApiProfiles)
}

function Get-CurrentMode {
  $configText = Read-FileText $Script:DockerConfigPath

  if ($configText -match ('(?m)^\s*env_key\s*=\s*"' + [regex]::Escape($Script:ApiEnvKey) + '"\s*$')) {
    return "docker"
  }

  if (Test-Path $Script:StatePath) {
    try {
      $state = Get-Content -LiteralPath $Script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($state.mode -in @("host", "docker", "profile")) {
        return $state.mode
      }
    }
    catch {
      return "unknown"
    }
  }

  if ($configText -match '(?m)^\s*requires_openai_auth\s*=\s*true\s*$') {
    return "host"
  }

  return "unknown"
}

function Get-SwitchState {
  if (-not (Test-Path $Script:StatePath)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
  }
  catch {
    return $null
  }
}

function Get-ObjectPropertyValue {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Fallback = ""
  )

  if ($null -eq $Object) {
    return $Fallback
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $Fallback
  }

  if ($null -eq $property.Value) {
    return $Fallback
  }

  return $property.Value
}

function Get-ProfileRawObject {
  param([object]$Profile)

  if ($null -eq $Profile) {
    return $null
  }
  $property = $Profile.PSObject.Properties["RawProfile"]
  if ($null -ne $property -and $null -ne $property.Value) {
    if ($property.Value -isnot [string] -or -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
      return $property.Value
    }
  }
  return $Profile
}

function Save-State {
  param(
    [string]$Mode,
    [string]$Note,
    [string]$ProfileId = "",
    [string]$ProfileName = "",
    [string]$ProfileSource = ""
  )

  $payload = [pscustomobject]@{
    mode           = $Mode
    note           = $Note
    profile_id     = $ProfileId
    profile_name   = $ProfileName
    profile_source = $ProfileSource
    updated_at     = (Get-Date).ToString("s")
    config_path    = $Script:DockerConfigPath
    restart_method = $Script:LastRestartMethod
    reconnect_status = $Script:LastReconnectStatus
    restart_duration_ms = $Script:LastRestartDurationMs
    last_restart_at = if ($Script:LastRestartMethod -eq "none") { "" } else { (Get-Date).ToString("s") }
  }

  $json = $payload | ConvertTo-Json -Depth 4
  Write-FileText -Path $Script:StatePath -Text ($json + "`r`n")
}

function Save-RestartMetadata {
  $current = Get-SwitchState
  $payload = [ordered]@{}
  if ($null -ne $current) {
    foreach ($property in $current.PSObject.Properties) {
      $payload[$property.Name] = $property.Value
    }
  }

  if (-not $payload.Contains("mode")) {
    $payload["mode"] = Get-CurrentMode
  }
  $payload["restart_method"] = $Script:LastRestartMethod
  $payload["reconnect_status"] = $Script:LastReconnectStatus
  $payload["restart_duration_ms"] = $Script:LastRestartDurationMs
  $payload["last_restart_at"] = (Get-Date).ToString("s")

  $json = [pscustomobject]$payload | ConvertTo-Json -Depth 4
  Write-FileText -Path $Script:StatePath -Text ($json + "`r`n")
}

function Get-NodeExecutable {
  $candidates = @(
    $Script:NodeExecutablePath,
    (Join-Path $Script:UserProfile ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"),
    "C:\Program Files\nodejs\node.exe"
  )

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  $command = Get-Command "node.exe" -ErrorAction SilentlyContinue
  if ($null -ne $command) {
    return $command.Source
  }

  return $null
}

function Invoke-CodexNativeRestart {
  $nodePath = Get-NodeExecutable
  if ($null -eq $nodePath -or -not (Test-Path -LiteralPath $Script:ReconnectHelperPath)) {
    return [pscustomobject]@{
      Status     = "unavailable"
      Message    = "Codex 原生重连助手或 Node.js 不可用。"
      DurationMs = 0
    }
  }

  $output = & $nodePath `
    $Script:ReconnectHelperPath `
    "--host-id" $Script:CodexRemoteHostId `
    "--ssh-port" "$($Script:SshPort)" `
    "--timeout-ms" "90000" 2>&1
  $exitCode = $LASTEXITCODE
  $text = ($output | Out-String).Trim()
  $lastLine = @($text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1

  try {
    $result = $lastLine | ConvertFrom-Json
  }
  catch {
    return [pscustomobject]@{
      Status     = if ($exitCode -eq 2) { "unavailable" } else { "failed" }
      Message    = if ([string]::IsNullOrWhiteSpace($text)) { "Codex 原生重连没有返回结果。" } else { $text }
      DurationMs = 0
    }
  }

  return [pscustomobject]@{
    Status           = [string]$result.status
    Message          = Get-ObjectPropertyValue -Object $result -Name "message"
    DurationMs       = [int](Get-ObjectPropertyValue -Object $result -Name "durationMs" -Fallback "0")
    HostId           = Get-ObjectPropertyValue -Object $result -Name "hostId"
    HostResolution   = Get-ObjectPropertyValue -Object $result -Name "hostResolution"
  }
}

function Test-TcpPort {
  param(
    [string]$HostName,
    [int]$Port,
    [int]$TimeoutMs = 500
  )

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
    if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs)) {
      return $false
    }
    $client.EndConnect($asyncResult)
    return $true
  }
  catch {
    return $false
  }
  finally {
    $client.Close()
  }
}

function Wait-DockerCodexSsh {
  param([int]$TimeoutSeconds = 45)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if ((Get-ContainerStatus) -eq "running" -and (Test-TcpPort -HostName "127.0.0.1" -Port $Script:SshPort)) {
      return
    }
    Start-Sleep -Milliseconds 400
  }

  throw "$($Script:ContainerName) 已执行重启，但 SSH 端口 $($Script:SshPort) 在 $TimeoutSeconds 秒内没有恢复。"
}

function Restart-ContainerFallback {
  $containerStatus = Get-ContainerStatus
  if ($containerStatus -eq "not-found") {
    throw "$($Script:ContainerName) 不存在；为避免误建容器，切换器不会执行 docker compose up。请重新运行安装器检测。"
  }
  Assert-TargetCodexContainer
  & docker restart --time 1 $Script:ContainerName 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Docker Codex 容器重启失败，退出码：$LASTEXITCODE"
  }

  Wait-DockerCodexSsh
}

function Restart-DockerCodex {
  if ($SkipRecreate) {
    $Script:LastRestartMethod = "skipped"
    $Script:LastReconnectStatus = "skipped"
    return
  }

  Assert-TargetCodexContainer

  $startedAt = Get-Date
  if ((Get-ContainerStatus) -eq "running") {
    $nativeResult = Invoke-CodexNativeRestart
    if ($nativeResult.Status -eq "connected") {
      $Script:LastRestartMethod = "codex-native"
      $Script:LastReconnectStatus = "connected"
      $Script:LastRestartDurationMs = $nativeResult.DurationMs
      return
    }
    if ($nativeResult.Status -eq "failed") {
      throw "Codex 原生重启失败：$($nativeResult.Message)"
    }
  }

  Restart-ContainerFallback
  $nativeAfterContainerRestart = Invoke-CodexNativeRestart
  if ($nativeAfterContainerRestart.Status -eq "failed") {
    throw "容器已经恢复，但 Codex 原生重连失败：$($nativeAfterContainerRestart.Message)"
  }

  $Script:LastRestartMethod = if ($nativeAfterContainerRestart.Status -eq "connected") {
    "container-restart+codex-native"
  }
  else {
    "container-restart"
  }
  $Script:LastReconnectStatus = if ($nativeAfterContainerRestart.Status -eq "connected") { "connected" } else { "ssh-ready" }
  $Script:LastRestartDurationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
}

function Reconnect-DockerCodex {
  Assert-TargetCodexContainer
  if ((Get-ContainerStatus) -ne "running") {
    throw "$($Script:ContainerName) 当前没有运行，无法执行原生重连。"
  }

  $result = Invoke-CodexNativeRestart
  if ($result.Status -eq "unavailable") {
    throw "Codex 独立重连通道不可用：$($result.Message)"
  }
  if ($result.Status -ne "connected") {
    throw "Docker Codex 重连失败：$($result.Message)"
  }

  $Script:LastRestartMethod = "codex-native"
  $Script:LastReconnectStatus = "connected"
  $Script:LastRestartDurationMs = $result.DurationMs
  Save-RestartMetadata
}

function Use-HostMode {
  Ensure-LocalTemplate

  $sharedConfig = Build-HostModeConfig
  $requiresHostAuth = Get-HostAuthJsonRequired $sharedConfig
  $hostAuthExists = Test-Path $Script:HostAuthPath

  if ($requiresHostAuth -and -not $hostAuthExists) {
    throw "Host config requires OpenAI auth, but host auth.json is missing: $Script:HostAuthPath"
  }

  Write-FileText -Path $Script:DockerConfigPath -Text $sharedConfig

  if ($hostAuthExists) {
    Copy-Item -LiteralPath $Script:HostAuthPath -Destination $Script:DockerAuthPath -Force
  }
  elseif (Test-Path $Script:DockerAuthPath) {
    Remove-Item -LiteralPath $Script:DockerAuthPath -Force
  }

  Restart-DockerCodex
  Save-State -Mode "host" -Note "Docker config follows host API/auth settings; Codex app-server was restarted and reconnected."
}

function Use-DockerMode {
  Ensure-LocalTemplate

  Copy-Item -LiteralPath $Script:LocalTemplatePath -Destination $Script:DockerConfigPath -Force
  if (Test-Path $Script:DockerAuthPath) {
    Remove-Item -LiteralPath $Script:DockerAuthPath -Force
  }

  Restart-DockerCodex
  Save-State -Mode "docker" -Note "Docker config restored to local template mode; Codex app-server was restarted and reconnected."
}

function Capture-DockerModeTemplate {
  $mode = Get-CurrentMode
  if ($mode -ne "docker") {
    throw "Current Docker config is not in local env_key mode. Switch back to Docker mode before capturing the template."
  }

  Copy-Item -LiteralPath $Script:DockerConfigPath -Destination $Script:LocalTemplatePath -Force
  Save-State -Mode "docker" -Note "Refreshed local Docker template from current config."
}

function Write-ApiProfileConfig {
  param(
    [object]$Profile,
    [switch]$SkipProxyHealth
  )

  if ($null -eq $Profile) {
    throw "请先从列表里选择一个 API 配置。"
  }

  $rawProfile = Get-ProfileRawObject -Profile $Profile
  $profileConfig = if ([string]$Profile.UpstreamProtocol -eq "chat") {
    Set-ChatProxyProfile -Profile $Profile -SkipHealthCheck:$SkipProxyHealth
    New-LocalProfileConfigText -Profile $rawProfile -UseProxy
  }
  else {
    Set-ResponsesProxyProfile -Profile $Profile -SkipHealthCheck:$SkipProxyHealth
    $sourceConfig = [string]$Profile.ConfigContents
    if ([string]::IsNullOrWhiteSpace($sourceConfig)) {
      $sourceConfig = New-LocalProfileConfigText -Profile $rawProfile
    }
    Convert-ProfileConfigToProxy -ConfigText $sourceConfig
  }

  if ([string]::IsNullOrWhiteSpace($profileConfig)) {
    throw "这个 API 配置没有可用的 configContents。"
  }

  $profileConfig = Set-ProfileModelCatalog -Profile $Profile -ConfigText $profileConfig
  $mergedConfig = Build-ProfileModeConfig -ProfileConfigText $profileConfig
  $requiresAuth = Get-HostAuthJsonRequired $mergedConfig

  if ($requiresAuth -and [string]::IsNullOrWhiteSpace($Profile.AuthContents)) {
    throw "这个 API 配置需要 auth.json，但没有可用的密钥内容。请在本地新建配置时填写 API Key。"
  }

  Write-FileText -Path $Script:DockerConfigPath -Text $mergedConfig

  if ($requiresAuth) {
    Write-FileText -Path $Script:DockerAuthPath -Text $Profile.AuthContents
  }
  elseif (Test-Path $Script:DockerAuthPath) {
    Remove-Item -LiteralPath $Script:DockerAuthPath -Force
  }
}

function Repair-ActiveApiProfile {
  $state = Get-SwitchState
  if ($null -eq $state -or [string](Get-ObjectPropertyValue -Object $state -Name "mode") -ne "profile") {
    return [pscustomobject]@{ Status = "not-needed"; Changed = $false; ProfileId = "" }
  }

  $profileId = [string](Get-ObjectPropertyValue -Object $state -Name "profile_id")
  if ([string]::IsNullOrWhiteSpace($profileId)) {
    return [pscustomobject]@{ Status = "not-needed"; Changed = $false; ProfileId = "" }
  }

  $profile = Get-ApiProfiles | Where-Object { [string]$_.Id -eq $profileId } | Select-Object -First 1
  if ($null -eq $profile) {
    return [pscustomobject]@{ Status = "profile-missing"; Changed = $false; ProfileId = $profileId }
  }

  $before = if (Test-Path -LiteralPath $Script:DockerConfigPath) {
    Read-FileText $Script:DockerConfigPath
  }
  else {
    ""
  }
  Write-ApiProfileConfig -Profile $profile -SkipProxyHealth
  $after = Read-FileText $Script:DockerConfigPath
  return [pscustomobject]@{
    Status    = "repaired"
    Changed   = -not [string]::Equals($before, $after, [StringComparison]::Ordinal)
    ProfileId = $profileId
  }
}

function Apply-ApiProfile {
  param([object]$Profile)

  Write-ApiProfileConfig -Profile $Profile

  Restart-DockerCodex
  Save-State `
    -Mode "profile" `
    -Note "Docker config switched to API profile; Codex app-server was restarted and reconnected." `
    -ProfileId $Profile.Id `
    -ProfileName $Profile.Name `
    -ProfileSource $Profile.Source
}

function Get-ContainerStatus {
  try {
    $status = docker inspect -f "{{.State.Status}}" $Script:ContainerName 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($status)) {
      return "not-found"
    }

    return $status.Trim()
  }
  catch {
    return "unknown"
  }
}

function Test-TargetCodexContainer {
  $status = Get-ContainerStatus
  if ($status -eq "not-found" -or $status -eq "unknown") {
    return $false
  }

  try {
    $declared = docker inspect --format '{{ index .Config.Labels "io.docker-codex-suite.codex-cli" }}' $Script:ContainerName 2>$null
    if ($LASTEXITCODE -eq 0 -and "$declared".Trim().ToLowerInvariant() -eq "true") {
      return $true
    }
  }
  catch {
  }

  if ($status -eq "running") {
    try {
      & docker exec $Script:ContainerName sh -lc "command -v codex >/dev/null 2>&1" 2>$null
      return $LASTEXITCODE -eq 0
    }
    catch {
      return $false
    }
  }

  $probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("DockerCodexSuite-probe-" + [Guid]::NewGuid().ToString("N"))
  try {
    New-Item -ItemType Directory -Path $probeRoot | Out-Null
    $paths = @(
      "/usr/local/bin/codex",
      "/home/codex/.local/bin/codex",
      "/opt/codex/bin/codex"
    )
    for ($index = 0; $index -lt $paths.Count; $index++) {
      $source = $Script:ContainerName + ":" + $paths[$index]
      $target = Join-Path $probeRoot ("codex-" + $index)
      try {
        & docker cp $source $target 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
          return $true
        }
      }
      catch {
      }
    }
    return $false
  }
  finally {
    if (Test-Path -LiteralPath $probeRoot) {
      Remove-Item -LiteralPath $probeRoot -Recurse -Force
    }
  }
}

function Assert-TargetCodexContainer {
  if (-not (Test-TargetCodexContainer)) {
    throw "拒绝控制容器 $($Script:ContainerName)：无法确认其中安装了 Codex CLI。请重新运行安装器检测。"
  }
}

function Get-StatusObject {
  Ensure-LocalTemplate

  $currentConfigText = Read-FileText $Script:DockerConfigPath
  $hostConfigText = Read-FileText $Script:HostConfigPath
  $switchState = Get-SwitchState
  $hostKey = Get-ParsedHostKey
  $dockerEnvKey = Get-DockerEnvKey
  $dockerAuthKey = Get-DockerAuthKey

  $mode = Get-CurrentMode
  $authMode = if ($currentConfigText -match '(?m)^\s*requires_openai_auth\s*=\s*true\s*$') {
    "requires_openai_auth"
  }
  elseif ($currentConfigText -match '(?m)^\s*env_key\s*=\s*"([^"]+)"\s*$') {
    "env_key:$($Matches[1])"
  }
  else {
    "unknown"
  }

  return [pscustomobject]@{
    Mode                  = $mode
    ContainerStatus       = Get-ContainerStatus
    CurrentModel          = Get-ConfigValue -Text $currentConfigText -Key "model"
    CurrentProvider       = Get-ConfigValue -Text $currentConfigText -Key "model_provider"
    HostModel             = Get-ConfigValue -Text $hostConfigText -Key "model"
    HostProvider          = Get-ConfigValue -Text $hostConfigText -Key "model_provider"
    AuthMode              = $authMode
    LocalTemplateExists   = Test-Path $Script:LocalTemplatePath
    DockerAuthExists      = Test-Path $Script:DockerAuthPath
    DockerAuthMatchesHost = (($null -ne $dockerAuthKey) -and ($dockerAuthKey -eq $hostKey))
    DockerEnvMatchesHost  = (($null -ne $dockerEnvKey) -and ($dockerEnvKey -eq $hostKey))
    DockerConfigPath      = $Script:DockerConfigPath
    LocalTemplatePath     = $Script:LocalTemplatePath
    HostConfigPath        = $Script:HostConfigPath
    HostAuthPath          = $Script:HostAuthPath
    ProfileName           = Get-ObjectPropertyValue -Object $switchState -Name "profile_name"
    ProfileSource         = Get-ObjectPropertyValue -Object $switchState -Name "profile_source"
    LastUpdated           = Get-ObjectPropertyValue -Object $switchState -Name "updated_at"
    RestartMethod         = Get-ObjectPropertyValue -Object $switchState -Name "restart_method" -Fallback "未记录"
    ReconnectStatus       = Get-ObjectPropertyValue -Object $switchState -Name "reconnect_status" -Fallback "未记录"
    RestartDurationMs     = Get-ObjectPropertyValue -Object $switchState -Name "restart_duration_ms" -Fallback "0"
    LastRestartAt         = Get-ObjectPropertyValue -Object $switchState -Name "last_restart_at" -Fallback "暂无记录"
  }
}

function Format-StatusText {
  param(
    [object]$Status = $null,
    [switch]$Compact
  )

  $status = if ($null -eq $Status) { Get-StatusObject } else { $Status }

  $modeLabel = switch ($status.Mode) {
    "host" { "主空间 API（跟随主空间配置）" }
    "docker" { "Docker API（使用 Docker 本地配置）" }
    "profile" { "API 配置列表：$(Get-DisplayValue $status.ProfileName)" }
    default { "未知或手动修改" }
  }

  $containerLabel = switch ($status.ContainerStatus) {
    "running" { "运行中" }
    "exited" { "已停止" }
    "not-found" { "未找到容器" }
    default { Get-DisplayValue $status.ContainerStatus }
  }

  $authModeLabel = if ($status.AuthMode -eq "requires_openai_auth") {
    "使用 auth.json / 主空间登录凭据"
  }
  elseif ($status.AuthMode -like "env_key:*") {
    "使用环境变量 $($status.AuthMode.Substring(8))"
  }
  else {
    Get-DisplayValue $status.AuthMode
  }
  $profileSourceLabel = Get-DisplayValue $status.ProfileSource "内置模式"
  $lastUpdatedLabel = Get-DisplayValue $status.LastUpdated "暂无记录"
  $restartMethodLabel = switch ($status.RestartMethod) {
    "codex-native" { "Codex 原生 app-server 重启" }
    "container-restart+codex-native" { "Docker 快速重启 + Codex 原生重连" }
    "container-restart" { "Docker 快速重启（等待 Codex 自动连接）" }
    "skipped" { "已跳过" }
    default { Get-DisplayValue $status.RestartMethod "未记录" }
  }
  $reconnectStatusLabel = switch ($status.ReconnectStatus) {
    "connected" { "已重新连接" }
    "ssh-ready" { "SSH 已恢复，等待 Codex 连接" }
    "skipped" { "已跳过" }
    default { Get-DisplayValue $status.ReconnectStatus "未记录" }
  }

  $summary = @(
    "Docker Codex API 状态"
    "更新时间：$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))"
    ""
    "当前模式"
    "  Docker 正在使用：$modeLabel"
    "  配置来源：$profileSourceLabel"
    "  上次切换：$lastUpdatedLabel"
    "  容器状态：$containerLabel"
    "  鉴权方式：$authModeLabel"
    "  上次重启：$(Get-DisplayValue $status.LastRestartAt "暂无记录")"
    "  重启方式：$restartMethodLabel"
    "  重连结果：$reconnectStatusLabel"
    "  重启耗时：$($status.RestartDurationMs) ms"
    ""
    "模型配置"
    "  Docker 模型：$(Get-DisplayValue $status.CurrentModel)"
    "  Docker Provider：$(Get-DisplayValue $status.CurrentProvider)"
    "  主空间模型：$(Get-DisplayValue $status.HostModel)"
    "  主空间 Provider：$(Get-DisplayValue $status.HostProvider)"
    ""
    "一致性检查"
    "  Docker .env 密钥是否等于主空间：$(Convert-BoolLabel $status.DockerEnvMatchesHost)"
    "  Docker auth.json 是否等于主空间：$(Convert-BoolLabel $status.DockerAuthMatchesHost)"
    "  Docker 本地模板是否存在：$(Convert-BoolLabel $status.LocalTemplateExists)"
    "  Docker auth.json 是否存在：$(Convert-BoolLabel $status.DockerAuthExists)"
  )

  if ($Compact) {
    return $summary -join "`r`n"
  }

  return @(
    $summary
    ""
    "文件位置"
    "  Docker 配置：$($status.DockerConfigPath)"
    "  Docker 本地模板：$($status.LocalTemplatePath)"
    "  主空间配置：$($status.HostConfigPath)"
    "  主空间 auth：$($status.HostAuthPath)"
  ) -join "`r`n"
}

function Get-DisplayValue {
  param(
    $Value,
    [string]$Fallback = "未设置"
  )

  if ($null -eq $Value) {
    return $Fallback
  }

  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $Fallback
  }

  return $text
}

function Convert-BoolLabel {
  param($Value)

  if ([bool]$Value) {
    return "是"
  }

  return "否"
}

function ConvertTo-CodexColor {
  param([string]$Hex)

  return [System.Drawing.ColorTranslator]::FromHtml($Hex)
}

function Get-CodexThemeMode {
  $override = [string]$env:DOCKER_CODEX_THEME
  if ($override -ieq "dark") {
    return "dark"
  }
  if ($override -ieq "light") {
    return "light"
  }

  try {
    $key = Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -ErrorAction Stop
    $property = $key.PSObject.Properties["AppsUseLightTheme"]
    if ($null -ne $property -and [int]$property.Value -eq 0) {
      return "dark"
    }
  }
  catch {
  }
  return "light"
}

function Get-CodexTheme {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  $mode = Get-CodexThemeMode
  if ($mode -eq "dark") {
    return [pscustomobject]@{
      Mode           = "dark"
      IsDark         = $true
      Window         = ConvertTo-CodexColor "#181818"
      Surface        = ConvertTo-CodexColor "#212121"
      SurfaceAlt     = ConvertTo-CodexColor "#303030"
      Input          = ConvertTo-CodexColor "#212121"
      Text           = ConvertTo-CodexColor "#ededed"
      Muted          = ConvertTo-CodexColor "#afafaf"
      Border         = ConvertTo-CodexColor "#343434"
      Primary        = ConvertTo-CodexColor "#ededed"
      PrimaryText    = ConvertTo-CodexColor "#0d0d0d"
      Success        = ConvertTo-CodexColor "#69c59e"
      Warning        = ConvertTo-CodexColor "#e7be7c"
      WarningSurface = ConvertTo-CodexColor "#2b251a"
    }
  }

  return [pscustomobject]@{
    Mode           = "light"
    IsDark         = $false
    Window         = ConvertTo-CodexColor "#f9f9f9"
    Surface        = ConvertTo-CodexColor "#ffffff"
    SurfaceAlt     = ConvertTo-CodexColor "#f3f3f3"
    Input          = ConvertTo-CodexColor "#ffffff"
    Text           = ConvertTo-CodexColor "#0d0d0d"
    Muted          = ConvertTo-CodexColor "#5d5d5d"
    Border         = ConvertTo-CodexColor "#e5e5e5"
    Primary        = ConvertTo-CodexColor "#0d0d0d"
    PrimaryText    = ConvertTo-CodexColor "#ffffff"
    Success        = ConvertTo-CodexColor "#237e5b"
    Warning        = ConvertTo-CodexColor "#7e5212"
    WarningSurface = ConvertTo-CodexColor "#fff7e8"
  }
}

function Initialize-CodexThemeNative {
  if ($null -ne ("DockerCodexSuiteTheme.NativeMethods" -as [type]) -and
      $null -ne ("DockerCodexSuiteTheme.CodexButton" -as [type])) {
    return
  }

  $formsAssembly = [System.Windows.Forms.Button].Assembly.Location
  $drawingAssembly = [System.Drawing.Color].Assembly.Location
  Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace DockerCodexSuiteTheme
{
    public static class NativeMethods
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string className, string windowName);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr window);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr window, int command);

        public static void SetDarkTitleBar(IntPtr window, bool dark)
        {
            int enabled = dark ? 1 : 0;
            try
            {
                if (DwmSetWindowAttribute(window, 20, ref enabled, sizeof(int)) != 0)
                {
                    DwmSetWindowAttribute(window, 19, ref enabled, sizeof(int));
                }
            }
            catch
            {
            }
        }

        public static void SetAppUserModelId(string appId)
        {
            try
            {
                SetCurrentProcessExplicitAppUserModelID(appId);
            }
            catch
            {
            }
        }

        public static void ActivateWindow(IntPtr window)
        {
            if (window == IntPtr.Zero) return;
            try
            {
                ShowWindow(window, 9);
                SetForegroundWindow(window);
            }
            catch
            {
            }
        }

        public static bool ActivateWindowByTitle(string title)
        {
            IntPtr window = FindWindow(null, title);
            if (window == IntPtr.Zero) return false;
            ActivateWindow(window);
            return true;
        }
    }

    public sealed class CodexButton : Button
    {
        private bool hovered;
        private bool pressed;

        public int CornerRadius { get; set; }
        public Color BorderColor { get; set; }
        public Color HoverBackColor { get; set; }
        public Color PressedBackColor { get; set; }
        public Color DisabledBackColor { get; set; }
        public Color DisabledForeColor { get; set; }
        public Color DisabledBorderColor { get; set; }

        public CodexButton()
        {
            CornerRadius = 6;
            BorderColor = Color.Black;
            HoverBackColor = Color.Gainsboro;
            PressedBackColor = Color.Silver;
            DisabledBackColor = Color.Gainsboro;
            DisabledForeColor = Color.Gray;
            DisabledBorderColor = Color.Silver;
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            UseVisualStyleBackColor = false;
            SetStyle(
                ControlStyles.UserPaint
                | ControlStyles.AllPaintingInWmPaint
                | ControlStyles.OptimizedDoubleBuffer
                | ControlStyles.ResizeRedraw,
                true);
        }

        protected override void OnPaint(PaintEventArgs eventArgs)
        {
            Graphics graphics = eventArgs.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.Clear(Parent == null ? BackColor : Parent.BackColor);

            Rectangle bounds = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
            Color fill = !Enabled
                ? DisabledBackColor
                : pressed
                    ? PressedBackColor
                    : hovered ? HoverBackColor : BackColor;
            Color border = Enabled ? BorderColor : DisabledBorderColor;
            Color text = Enabled ? ForeColor : DisabledForeColor;

            using (GraphicsPath path = CreateRoundedPath(bounds, CornerRadius))
            using (SolidBrush brush = new SolidBrush(fill))
            using (Pen pen = new Pen(border, 1F))
            {
                graphics.FillPath(brush, path);
                graphics.DrawPath(pen, path);
            }

            TextFormatFlags flags = TextFormatFlags.HorizontalCenter
                | TextFormatFlags.VerticalCenter
                | TextFormatFlags.SingleLine
                | TextFormatFlags.EndEllipsis
                | TextFormatFlags.NoPadding;
            if (!UseMnemonic) flags |= TextFormatFlags.NoPrefix;
            TextRenderer.DrawText(graphics, Text, Font, ClientRectangle, text, flags);

            if (Focused && ShowFocusCues && Width > 10 && Height > 10)
            {
                Rectangle focusBounds = new Rectangle(4, 4, Width - 9, Height - 9);
                using (GraphicsPath focusPath = CreateRoundedPath(focusBounds, Math.Max(2, CornerRadius - 2)))
                using (Pen focusPen = new Pen(text, 1F))
                {
                    focusPen.DashStyle = DashStyle.Dot;
                    graphics.DrawPath(focusPen, focusPath);
                }
            }
        }

        private static GraphicsPath CreateRoundedPath(Rectangle bounds, int radius)
        {
            GraphicsPath path = new GraphicsPath();
            int safeRadius = Math.Max(1, Math.Min(radius, Math.Min(bounds.Width, bounds.Height) / 2));
            int diameter = safeRadius * 2;
            Rectangle arc = new Rectangle(bounds.Location, new Size(diameter, diameter));
            path.AddArc(arc, 180F, 90F);
            arc.X = bounds.Right - diameter;
            path.AddArc(arc, 270F, 90F);
            arc.Y = bounds.Bottom - diameter;
            path.AddArc(arc, 0F, 90F);
            arc.X = bounds.Left;
            path.AddArc(arc, 90F, 90F);
            path.CloseFigure();
            return path;
        }

        protected override void OnMouseEnter(EventArgs eventArgs)
        {
            hovered = true;
            Invalidate();
            base.OnMouseEnter(eventArgs);
        }

        protected override void OnMouseLeave(EventArgs eventArgs)
        {
            hovered = false;
            pressed = false;
            Invalidate();
            base.OnMouseLeave(eventArgs);
        }

        protected override void OnMouseDown(MouseEventArgs eventArgs)
        {
            if (eventArgs.Button == MouseButtons.Left) pressed = true;
            Invalidate();
            base.OnMouseDown(eventArgs);
        }

        protected override void OnMouseUp(MouseEventArgs eventArgs)
        {
            pressed = false;
            Invalidate();
            base.OnMouseUp(eventArgs);
        }

        protected override void OnEnabledChanged(EventArgs eventArgs)
        {
            Invalidate();
            base.OnEnabledChanged(eventArgs);
        }
    }
}
'@ -ReferencedAssemblies @($formsAssembly, $drawingAssembly)
}

function Set-CodexTitleBar {
  param($Form, $Theme)

  Initialize-CodexThemeNative
  if ($Form.IsHandleCreated) {
    [DockerCodexSuiteTheme.NativeMethods]::SetDarkTitleBar($Form.Handle, [bool]$Theme.IsDark)
  }
}

function Set-DockerCodexWindowIdentity {
  param($Form)

  Initialize-CodexThemeNative
  [DockerCodexSuiteTheme.NativeMethods]::SetAppUserModelId("DockerCodexSuite.ApiSwitcher")

  $launcherPath = Join-Path $Script:InstallDir "DockerCodex.exe"
  if (-not (Test-Path -LiteralPath $launcherPath)) {
    return
  }

  try {
    $windowIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($launcherPath)
    if ($null -ne $windowIcon) {
      $Form.Icon = $windowIcon
      $Form.ShowIcon = $true
      $Form.Add_Disposed({
          $windowIcon.Dispose()
        }.GetNewClosure())
    }
  }
  catch {
  }
}

function New-CodexFont {
  param(
    [float]$Size = 9,
    $Style = [System.Drawing.FontStyle]::Regular
  )

  $font = New-Object System.Drawing.Font("Segoe UI Variable Text", $Size, $Style, [System.Drawing.GraphicsUnit]::Point)
  if ($font.Name -ieq "Segoe UI Variable Text") {
    return $font
  }
  $font.Dispose()
  return New-Object System.Drawing.Font("Segoe UI", $Size, $Style, [System.Drawing.GraphicsUnit]::Point)
}

function Set-CodexButtonTheme {
  param(
    $Button,
    $Theme,
    [string]$Role = "secondary"
  )

  $isPrimary = $Role -eq "primary"
  $isSelected = $Role -eq "selected"
  $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $Button.UseVisualStyleBackColor = $false
  $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
  $Button.FlatAppearance.BorderSize = 0
  $Button.FlatAppearance.BorderColor = if ($isPrimary) { $Theme.Primary } else { $Theme.Text }
  $Button.FlatAppearance.MouseOverBackColor = if ($isPrimary) { $Theme.Muted } else { $Theme.SurfaceAlt }
  $Button.FlatAppearance.MouseDownBackColor = $Theme.Border
  $Button.BackColor = if ($isPrimary) { $Theme.Primary } elseif ($isSelected) { $Theme.SurfaceAlt } else { $Theme.Surface }
  $Button.ForeColor = if ($isPrimary) { $Theme.PrimaryText } else { $Theme.Text }

  if ($null -ne $Button.PSObject.Properties["CornerRadius"]) {
    $Button.CornerRadius = 6
    $Button.BorderColor = if ($isPrimary) { $Theme.Primary } else { $Theme.Text }
    $Button.HoverBackColor = if ($isPrimary) { $Theme.Muted } else { $Theme.SurfaceAlt }
    $Button.PressedBackColor = if ($isPrimary) { $Theme.Primary } else { $Theme.Border }
    $Button.DisabledBackColor = $Theme.SurfaceAlt
    $Button.DisabledForeColor = $Theme.Muted
    $Button.DisabledBorderColor = $Theme.Border
    $Button.Invalidate()
  }
}

function Set-CodexControlTheme {
  param($Control, $Theme)

  $role = if ($null -eq $Control.Tag) { "" } else { [string]$Control.Tag }
  $Control.ForeColor = $Theme.Text

  if ($Control -is [System.Windows.Forms.Form]) {
    $Control.BackColor = $Theme.Window
  }
  elseif ($Control -is [System.Windows.Forms.SplitContainer]) {
    $Control.BackColor = $Theme.Border
  }
  elseif ($Control -is [System.Windows.Forms.Panel] -or $Control -is [System.Windows.Forms.TableLayoutPanel]) {
    $Control.BackColor = switch ($role) {
      "surface" { $Theme.Surface }
      "surface-alt" { $Theme.SurfaceAlt }
      "warning" { $Theme.WarningSurface }
      "frame" { $Theme.Border }
      "separator" { $Theme.Border }
      default { $Theme.Window }
    }
  }
  elseif ($Control -is [System.Windows.Forms.Button]) {
    Set-CodexButtonTheme -Button $Control -Theme $Theme -Role $role
  }
  elseif ($Control -is [System.Windows.Forms.RichTextBox]) {
    $Control.BackColor = if ($role -eq "read-only") { $Theme.Surface } else { $Theme.Input }
    $Control.ForeColor = $Theme.Text
    $Control.BorderStyle = [System.Windows.Forms.BorderStyle]::None
  }
  elseif ($Control -is [System.Windows.Forms.TextBox]) {
    $Control.BackColor = if ($role -eq "read-only") { $Theme.Surface } else { $Theme.Input }
    $Control.ForeColor = $Theme.Text
    $Control.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  }
  elseif ($Control -is [System.Windows.Forms.ListBox]) {
    $Control.BackColor = $Theme.Surface
    $Control.ForeColor = $Theme.Text
    $Control.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  }
  elseif ($Control -is [System.Windows.Forms.NumericUpDown]) {
    $Control.BackColor = $Theme.Input
    $Control.ForeColor = $Theme.Text
  }
  elseif ($Control -is [System.Windows.Forms.CheckBox]) {
    $Control.BackColor = $Control.Parent.BackColor
  }
  elseif ($Control -is [System.Windows.Forms.Label]) {
    $Control.BackColor = [System.Drawing.Color]::Transparent
    if ($role -eq "muted") {
      $Control.ForeColor = $Theme.Muted
    }
    elseif ($role -eq "warning") {
      $Control.ForeColor = $Theme.Warning
    }
    elseif ($role -eq "success") {
      $Control.ForeColor = $Theme.Success
    }
  }

  foreach ($child in $Control.Controls) {
    Set-CodexControlTheme -Control $child -Theme $Theme
  }
}

function Set-CodexRichText {
  param(
    $Box,
    [string]$Text,
    $Theme
  )

  $Box.Text = $Text
  $Box.SelectAll()
  $Box.SelectionColor = $Theme.Text
  $Box.SelectionFont = $Box.Font

  $headingFont = New-CodexFont -Size 10 -Style ([System.Drawing.FontStyle]::Bold)
  $titleFont = New-CodexFont -Size 13 -Style ([System.Drawing.FontStyle]::Bold)
  try {
    $headings = @("当前模式", "模型配置", "一致性检查", "文件位置", "模型列表：")
    foreach ($heading in $headings) {
      $start = $Text.IndexOf($heading, [System.StringComparison]::Ordinal)
      if ($start -ge 0) {
        $Box.Select($start, $heading.Length)
        $Box.SelectionFont = $headingFont
        $Box.SelectionColor = $Theme.Text
      }
    }

    if ($Text.StartsWith("Docker Codex API 状态", [System.StringComparison]::Ordinal)) {
      $title = "Docker Codex API 状态"
      $Box.Select(0, $title.Length)
      $Box.SelectionFont = $titleFont
    }
  }
  finally {
    $headingFont.Dispose()
    $titleFont.Dispose()
  }

  $Box.Select(0, 0)
  $Box.ScrollToCaret()
}

function Enable-CodexThemeRefresh {
  param(
    $Form,
    [scriptblock]$ApplyTheme
  )

  if ($env:DOCKER_CODEX_THEME -in @("light", "dark")) {
    return
  }

  $state = [pscustomobject]@{ Mode = (Get-CodexThemeMode) }
  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 1500
  $timer.Add_Tick({
      $nextTheme = Get-CodexTheme
      if ($nextTheme.Mode -ne $state.Mode) {
        $state.Mode = $nextTheme.Mode
        & $ApplyTheme $nextTheme
      }
    }.GetNewClosure())
  $Form.Add_FormClosed({
      $timer.Stop()
      $timer.Dispose()
    }.GetNewClosure())
  $timer.Start()
}

function Show-Message {
  param(
    [string]$Text,
    [string]$Title = "Docker Codex API",
    $Owner = $null
  )

  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  Initialize-CodexThemeNative

  $lineCount = @($Text -split "`r?`n").Count
  $isLong = $Text.Length -gt 380 -or $lineCount -gt 7
  $theme = Get-CodexTheme

  $form = New-Object System.Windows.Forms.Form
  $form.Text = $Title
  Set-DockerCodexWindowIdentity -Form $form
  $form.StartPosition = if ($null -eq $Owner) { "CenterScreen" } else { "CenterParent" }
  $form.ClientSize = if ($isLong) { New-Object System.Drawing.Size(840, 600) } else { New-Object System.Drawing.Size(600, 240) }
  $form.MinimumSize = if ($isLong) { New-Object System.Drawing.Size(740, 500) } else { New-Object System.Drawing.Size(520, 220) }
  $form.Font = New-CodexFont -Size 9
  $form.TopMost = $null -eq $Owner
  $form.ShowInTaskbar = $null -eq $Owner
  $form.WindowState = "Normal"

  $rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
  $rootLayout.Dock = "Fill"
  $rootLayout.ColumnCount = 1
  $rootLayout.RowCount = 3
  [void]$rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 70))
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 62))
  $form.Controls.Add($rootLayout)

  $header = New-Object System.Windows.Forms.Panel
  $header.Dock = "Fill"
  $header.Margin = New-Object System.Windows.Forms.Padding(0)
  $rootLayout.Controls.Add($header, 0, 0)

  $titleLabel = New-Object System.Windows.Forms.Label
  $titleLabel.Text = $Title
  $titleLabel.Font = New-CodexFont -Size 16 -Style ([System.Drawing.FontStyle]::Bold)
  $titleLabel.AutoSize = $true
  $titleLabel.Location = New-Object System.Drawing.Point(20, 20)
  $header.Controls.Add($titleLabel)

  $footer = New-Object System.Windows.Forms.Panel
  $footer.Tag = "surface"
  $footer.Dock = "Fill"
  $footer.Margin = New-Object System.Windows.Forms.Padding(0)
  $rootLayout.Controls.Add($footer, 0, 2)

  $separator = New-Object System.Windows.Forms.Panel
  $separator.Tag = "separator"
  $separator.Dock = "Top"
  $separator.Height = 1
  $footer.Controls.Add($separator)

  $body = New-Object System.Windows.Forms.Panel
  $body.Dock = "Fill"
  $body.Padding = New-Object System.Windows.Forms.Padding(20, 4, 20, 18)
  $body.Margin = New-Object System.Windows.Forms.Padding(0)
  $rootLayout.Controls.Add($body, 0, 1)

  $textFrame = New-Object System.Windows.Forms.Panel
  $textFrame.Tag = "frame"
  $textFrame.Dock = "Fill"
  $textFrame.Padding = New-Object System.Windows.Forms.Padding(1)
  $body.Controls.Add($textFrame)

  $textBox = New-Object System.Windows.Forms.RichTextBox
  $textBox.Tag = "read-only"
  $textBox.Dock = "Fill"
  $textBox.ReadOnly = $true
  $textBox.ScrollBars = "Vertical"
  $textBox.WordWrap = $true
  $textBox.Font = New-CodexFont -Size $(if ($isLong) { 9.5 } else { 10 })
  $textBox.DetectUrls = $false
  $textFrame.Controls.Add($textBox)

  $copyButton = New-Object DockerCodexSuiteTheme.CodexButton
  $copyButton.Text = "复制状态"
  $copyButton.Tag = "secondary"
  $copyButton.Size = New-Object System.Drawing.Size(116, 36)
  $copyButton.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 268), 14)
  $copyButton.Anchor = "Bottom,Right"
  $copyButton.Visible = $isLong
  $copyButton.Add_Click({
      [System.Windows.Forms.Clipboard]::SetText($textBox.Text)
    })
  $footer.Controls.Add($copyButton)

  $closeButton = New-Object DockerCodexSuiteTheme.CodexButton
  $closeButton.Text = "关闭"
  $closeButton.Tag = "primary"
  $closeButton.Size = New-Object System.Drawing.Size(116, 36)
  $closeButton.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 136), 14)
  $closeButton.Anchor = "Bottom,Right"
  $closeButton.Add_Click({ $form.Close() })
  $form.AcceptButton = $closeButton
  $form.CancelButton = $closeButton
  $footer.Controls.Add($closeButton)

  $applyTheme = {
    param($nextTheme)
    $theme = $nextTheme
    Set-CodexControlTheme -Control $form -Theme $theme
    Set-CodexRichText -Box $textBox -Text $Text -Theme $theme
    Set-CodexTitleBar -Form $form -Theme $theme
  }.GetNewClosure()
  & $applyTheme $theme
  Enable-CodexThemeRefresh -Form $form -ApplyTheme $applyTheme

  $form.Add_Shown({
      $form.WindowState = "Normal"
      $form.TopMost = $null -eq $Owner
      Set-CodexTitleBar -Form $form -Theme (Get-CodexTheme)
      [void]$form.Activate()
      $form.BringToFront()
    })
  if ($null -eq $Owner) {
    [void]$form.ShowDialog()
  }
  else {
    [void]$form.ShowDialog($Owner)
  }
}

function Format-ProfileText {
  param([object]$Profile)

  if ($null -eq $Profile) {
    return "请选择左侧列表中的 API 配置。"
  }

  $baseUrl = Get-DisplayValue $Profile.BaseUrl
  $dockerBaseUrl = if ([string]$Profile.UpstreamProtocol -eq "chat") {
    "http://host.docker.internal:$($Script:ChatProxyPort)/v1"
  }
  else {
    [regex]::Replace(
      $baseUrl,
      '^http://(127\.0\.0\.1|localhost)(:\d+/.*)$',
      'http://host.docker.internal$2'
    )
  }
  $dockerUrlLine = if ($dockerBaseUrl -ne $baseUrl) {
    "Docker 内部 URL：$dockerBaseUrl"
  }
  else {
    "Docker 内部 URL：同 Base URL"
  }

  $modelList = Get-DisplayValue $Profile.ModelList "未提供"
  if ($modelList.Length -gt 220) {
    $modelList = $modelList.Substring(0, 220) + " ..."
  }

  $protocolLabel = if ([string]$Profile.UpstreamProtocol -eq "chat") {
    "Chat Completions（内置转换为 Responses）"
  }
  else {
    "Responses API"
  }

  return @(
    "名称：$(Get-DisplayValue $Profile.Name)"
    "来源：$(Get-DisplayValue $Profile.Source)"
    "模型：$(Get-DisplayValue $Profile.Model)"
    "Provider：$(Get-DisplayValue $Profile.Provider)"
    "上游协议：$protocolLabel"
    "Base URL：$baseUrl"
    $dockerUrlLine
    "鉴权：$(Get-DisplayValue $Profile.AuthMode)"
    ""
    "模型列表："
    $modelList
  ) -join "`r`n"
}

function Show-NewProfileDialog {
  param(
    $Owner = $null,
    $Profile = $null
  )

  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  Initialize-CodexThemeNative
  $theme = Get-CodexTheme

  $dialog = New-Object System.Windows.Forms.Form
  $isEditing = $null -ne $Profile
  $dialog.Text = if ($isEditing) { "编辑 Docker API 配置" } else { "新建 Docker API 配置" }
  Set-DockerCodexWindowIdentity -Form $dialog
  $dialog.StartPosition = if ($null -eq $Owner) { "CenterScreen" } else { "CenterParent" }
  $dialog.ClientSize = New-Object System.Drawing.Size(760, 700)
  $dialog.MinimumSize = New-Object System.Drawing.Size(780, 660)
  $dialog.Font = New-CodexFont -Size 9
  $dialog.ShowInTaskbar = $null -eq $Owner
  if ($Owner -is [System.Windows.Forms.Form]) {
    $dialog.Owner = $Owner
  }

  $rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
  $rootLayout.Dock = "Fill"
  $rootLayout.ColumnCount = 1
  $rootLayout.RowCount = 3
  [void]$rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 76))
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 70))
  $dialog.Controls.Add($rootLayout)

  $header = New-Object System.Windows.Forms.Panel
  $header.Dock = "Fill"
  $header.Margin = New-Object System.Windows.Forms.Padding(0)
  $rootLayout.Controls.Add($header, 0, 0)

  $titleLabel = New-Object System.Windows.Forms.Label
  $titleLabel.Text = if ($isEditing) { "编辑 API 配置" } else { "新建 API 配置" }
  $titleLabel.Font = New-CodexFont -Size 17 -Style ([System.Drawing.FontStyle]::Bold)
  $titleLabel.AutoSize = $true
  $titleLabel.Location = New-Object System.Drawing.Point(22, 16)
  $header.Controls.Add($titleLabel)

  $subtitleLabel = New-Object System.Windows.Forms.Label
  $subtitleLabel.Text = "配置仅保存在本机"
  $subtitleLabel.Tag = "muted"
  $subtitleLabel.AutoSize = $true
  $subtitleLabel.Location = New-Object System.Drawing.Point(24, 49)
  $header.Controls.Add($subtitleLabel)

  $footer = New-Object System.Windows.Forms.Panel
  $footer.Tag = "surface"
  $footer.Dock = "Fill"
  $footer.Margin = New-Object System.Windows.Forms.Padding(0)
  $rootLayout.Controls.Add($footer, 0, 2)

  $separator = New-Object System.Windows.Forms.Panel
  $separator.Tag = "separator"
  $separator.Dock = "Top"
  $separator.Height = 1
  $footer.Controls.Add($separator)

  $content = New-Object System.Windows.Forms.Panel
  $content.Dock = "Fill"
  $content.Margin = New-Object System.Windows.Forms.Padding(0)
  $content.AutoScroll = $true
  $rootLayout.Controls.Add($content, 0, 1)

  $labels = @("名称", "Base URL", "默认模型", "API Key（可选）")
  $boxes = @()
  for ($i = 0; $i -lt $labels.Count; $i += 1) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $labels[$i]
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(22, (8 + $i * 64))
    $content.Controls.Add($label)

    $box = if ($i -eq 2) {
      $combo = New-Object System.Windows.Forms.ComboBox
      $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
      $combo.IntegralHeight = $false
      $combo.MaxDropDownItems = 12
      $combo
    }
    else {
      New-Object System.Windows.Forms.TextBox
    }
    $box.Location = New-Object System.Drawing.Point(22, (31 + $i * 64))
    $box.Size = if ($i -eq 3) { New-Object System.Drawing.Size(580, 28) } else { New-Object System.Drawing.Size(716, 28) }
    $box.Anchor = "Top,Left,Right"
    $content.Controls.Add($box)
    $boxes += $box
  }

  $nameBox = $boxes[0]
  $baseUrlBox = $boxes[1]
  $modelBox = $boxes[2]
  $apiKeyBox = $boxes[3]
  $rawProfile = if ($isEditing) { Get-ProfileRawObject -Profile $Profile } else { $null }
  $initialProtocol = if ($isEditing) { [string](Get-ObjectPropertyValue -Object $Profile -Name "UpstreamProtocol") } else { "responses" }
  if ($initialProtocol -notin @("responses", "chat")) {
    $initialProtocol = "responses"
  }
  $nameBox.Text = if ($isEditing) { [string](Get-ObjectPropertyValue -Object $Profile -Name "Name") } else { "" }
  $baseUrlBox.Text = if ($isEditing) { [string](Get-ObjectPropertyValue -Object $Profile -Name "BaseUrl") } else { "https://api.openai.com/v1" }
  $modelBox.Text = if ($isEditing) { [string](Get-ObjectPropertyValue -Object $Profile -Name "Model") } else { "gpt-5.5" }
  $apiKeyBox.Text = if ($isEditing) { Get-ProfileApiKey -Profile $Profile } else { "" }
  foreach ($modelId in @(Get-ProfileModelIds -Profile $Profile)) {
    [void]$modelBox.Items.Add($modelId)
  }
  $apiKeyBox.UseSystemPasswordChar = $true

  $showKeyButton = New-Object DockerCodexSuiteTheme.CodexButton
  $showKeyButton.Text = "显示"
  $showKeyButton.Tag = "secondary"
  $showKeyButton.Location = New-Object System.Drawing.Point(612, 223)
  $showKeyButton.Size = New-Object System.Drawing.Size(126, 31)
  $showKeyButton.Anchor = "Top,Right"
  $showKeyButton.Add_Click({
      $apiKeyBox.UseSystemPasswordChar = -not $apiKeyBox.UseSystemPasswordChar
      $showKeyButton.Text = if ($apiKeyBox.UseSystemPasswordChar) { "显示" } else { "隐藏" }
    })
  $content.Controls.Add($showKeyButton)

  $protocolState = [pscustomobject]@{ Value = $initialProtocol }
  $profileApiEnvKey = $Script:ApiEnvKey

  $protocolLabel = New-Object System.Windows.Forms.Label
  $protocolLabel.Text = "上游协议"
  $protocolLabel.AutoSize = $true
  $protocolLabel.Location = New-Object System.Drawing.Point(22, 270)
  $content.Controls.Add($protocolLabel)

  $responsesProtocolButton = New-Object DockerCodexSuiteTheme.CodexButton
  $responsesProtocolButton.Text = "Responses API"
  $responsesProtocolButton.Location = New-Object System.Drawing.Point(22, 293)
  $responsesProtocolButton.Size = New-Object System.Drawing.Size(348, 38)
  $responsesProtocolButton.Anchor = "Top,Left"
  $content.Controls.Add($responsesProtocolButton)

  $chatProtocolButton = New-Object DockerCodexSuiteTheme.CodexButton
  $chatProtocolButton.Text = "Chat Completions"
  $chatProtocolButton.Location = New-Object System.Drawing.Point(390, 293)
  $chatProtocolButton.Size = New-Object System.Drawing.Size(348, 38)
  $chatProtocolButton.Anchor = "Top,Right"
  $content.Controls.Add($chatProtocolButton)

  $protocolHint = New-Object System.Windows.Forms.Label
  $protocolHint.Tag = "muted"
  $protocolHint.AutoSize = $false
  $protocolHint.Location = New-Object System.Drawing.Point(22, 340)
  $protocolHint.Size = New-Object System.Drawing.Size(716, 38)
  $protocolHint.Anchor = "Top,Left,Right"
  $content.Controls.Add($protocolHint)

  $fetchModelsButton = New-Object DockerCodexSuiteTheme.CodexButton
  $fetchModelsButton.Text = "从上游获取模型"
  $fetchModelsButton.Tag = "secondary"
  $fetchModelsButton.Location = New-Object System.Drawing.Point(22, 386)
  $fetchModelsButton.Size = New-Object System.Drawing.Size(166, 38)
  $content.Controls.Add($fetchModelsButton)

  $testModelButton = New-Object DockerCodexSuiteTheme.CodexButton
  $testModelButton.Text = "测试所选模型"
  $testModelButton.Tag = "secondary"
  $testModelButton.Location = New-Object System.Drawing.Point(202, 386)
  $testModelButton.Size = New-Object System.Drawing.Size(150, 38)
  $content.Controls.Add($testModelButton)

  $doctorStatusLabel = New-Object System.Windows.Forms.Label
  $doctorStatusLabel.Text = "连通性诊断"
  $doctorStatusLabel.AutoSize = $true
  $doctorStatusLabel.Font = New-CodexFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
  $doctorStatusLabel.Location = New-Object System.Drawing.Point(22, 438)
  $content.Controls.Add($doctorStatusLabel)

  $doctorStatus = New-Object System.Windows.Forms.RichTextBox
  $doctorStatus.Tag = "read-only"
  $doctorStatus.ReadOnly = $true
  $doctorStatus.DetectUrls = $false
  $doctorStatus.ScrollBars = "Vertical"
  $doctorStatus.WordWrap = $true
  $doctorStatus.Location = New-Object System.Drawing.Point(22, 462)
  $doctorStatus.Size = New-Object System.Drawing.Size(716, 72)
  $doctorStatus.Anchor = "Top,Left,Right"
  $content.Controls.Add($doctorStatus)

  $errorLabel = New-Object System.Windows.Forms.Label
  $errorLabel.Tag = "warning"
  $errorLabel.AutoSize = $false
  $errorLabel.Location = New-Object System.Drawing.Point(22, 12)
  $errorLabel.Size = New-Object System.Drawing.Size(450, 46)
  $errorLabel.Anchor = "Top,Left,Right"
  $footer.Controls.Add($errorLabel)

  $okButton = New-Object DockerCodexSuiteTheme.CodexButton
  $okButton.Text = "保存"
  $okButton.Tag = "primary"
  $okButton.Location = New-Object System.Drawing.Point(626, 17)
  $okButton.Size = New-Object System.Drawing.Size(112, 36)
  $okButton.Anchor = "Top,Right"
  $footer.Controls.Add($okButton)

  $cancelButton = New-Object DockerCodexSuiteTheme.CodexButton
  $cancelButton.Text = "取消"
  $cancelButton.Tag = "secondary"
  $cancelButton.Location = New-Object System.Drawing.Point(498, 17)
  $cancelButton.Size = New-Object System.Drawing.Size(112, 36)
  $cancelButton.Anchor = "Top,Right"
  $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $footer.Controls.Add($cancelButton)

  $refreshProtocolUi = {
    $responsesProtocolButton.Tag = if ($protocolState.Value -eq "responses") { "selected" } else { "secondary" }
    $chatProtocolButton.Tag = if ($protocolState.Value -eq "chat") { "selected" } else { "secondary" }
    $currentTheme = Get-CodexTheme
    Set-CodexButtonTheme -Button $responsesProtocolButton -Theme $currentTheme -Role ([string]$responsesProtocolButton.Tag)
    Set-CodexButtonTheme -Button $chatProtocolButton -Theme $currentTheme -Role ([string]$chatProtocolButton.Tag)
    $protocolHint.Text = if ($protocolState.Value -eq "chat") {
      "Chat 上游会由内置转换器适配为 Responses；保存后可直接应用到 Docker Codex。"
    }
    else {
      "Responses 上游可直接应用。API Key 留空时使用容器环境变量 $profileApiEnvKey。"
    }
  }.GetNewClosure()
  $responsesProtocolButton.Add_Click({
      $protocolState.Value = "responses"
      & $refreshProtocolUi
    })
  $chatProtocolButton.Add_Click({
      $protocolState.Value = "chat"
      & $refreshProtocolUi
    })
  & $refreshProtocolUi

  $doctorState = [pscustomobject]@{
    Active     = $false
    Operation  = ""
    Process    = $null
    StdoutTask = $null
    StderrTask = $null
  }
  $doctorTimer = New-Object System.Windows.Forms.Timer
  $doctorTimer.Interval = 120

  $setDoctorBusy = {
    param([bool]$Busy)
    $fetchModelsButton.Enabled = -not $Busy
    $testModelButton.Enabled = -not $Busy
    $responsesProtocolButton.Enabled = -not $Busy
    $chatProtocolButton.Enabled = -not $Busy
    $okButton.Enabled = -not $Busy
    $dialog.UseWaitCursor = $Busy
  }.GetNewClosure()

  $setDoctorText = {
    param([string]$Text)
    Set-CodexRichText -Box $doctorStatus -Text $Text -Theme (Get-CodexTheme)
  }.GetNewClosure()

  $doctorTimer.Add_Tick({
      if (-not $doctorState.Active -or $null -eq $doctorState.Process) {
        $doctorTimer.Stop()
        return
      }
      $doctorState.Process.Refresh()
      if (-not $doctorState.Process.HasExited) {
        return
      }

      $doctorTimer.Stop()
      try {
        $stdout = [string]$doctorState.StdoutTask.GetAwaiter().GetResult()
        $stderr = [string]$doctorState.StderrTask.GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($stdout)) {
          throw (Get-DisplayValue $stderr "Provider Doctor 没有返回结果。")
        }
        $result = $stdout | ConvertFrom-Json
        $resultAttempts = [int](Get-ObjectPropertyValue -Object $result -Name "attempts" -Fallback "1")
        $attemptSuffix = if ($resultAttempts -gt 1) { "  |  尝试：$resultAttempts 次" } else { "" }
        $resultTransport = [string](Get-ObjectPropertyValue -Object $result -Name "transport")
        $resultProxyAddress = [string](Get-ObjectPropertyValue -Object $result -Name "proxyAddress")
        $resultResolvedAddress = [string](Get-ObjectPropertyValue -Object $result -Name "resolvedAddress")
        $resultNetworkLines = @()
        if ($resultTransport -eq "local-proxy-fallback") {
          $resultNetworkLines += "网络路径：现有本机代理回退（未修改 Clash）"
          if (-not [string]::IsNullOrWhiteSpace($resultProxyAddress)) {
            $resultNetworkLines += "代理入口：$resultProxyAddress"
          }
          $resultNetworkLines += "测试范围：仅验证上游 API；未改变 Docker 运行时网络。"
        }
        elseif ($resultTransport -eq "public-dns-fallback") {
          $resultNetworkLines += "网络路径：公共 DNS 回退（未修改 Clash）"
          if (-not [string]::IsNullOrWhiteSpace($resultResolvedAddress)) {
            $resultNetworkLines += "解析地址：$resultResolvedAddress"
          }
          $resultNetworkLines += "测试范围：仅验证上游 API；未改变 Docker 运行时网络。"
        }
        if (-not [bool]$result.ok) {
          $resultEndpoint = Get-ObjectPropertyValue -Object $result -Name "endpoint"
          $resultError = Get-ObjectPropertyValue -Object $result -Name "error"
          $resultHttpStatus = Get-ObjectPropertyValue -Object $result -Name "httpStatus"
          $resultNetworkCode = Get-ObjectPropertyValue -Object $result -Name "networkCode"
          $resultPreview = Get-ObjectPropertyValue -Object $result -Name "preview"
          $lines = @(
            "诊断失败"
            "端点：$(Get-DisplayValue $resultEndpoint "未生成")"
            "原因：$(Get-DisplayValue $resultError "未知错误")"
          )
          $lines += $resultNetworkLines
          if (-not [string]::IsNullOrWhiteSpace([string]$resultNetworkCode)) {
            $lines += "网络代码：$resultNetworkCode"
          }
          if (-not [string]::IsNullOrWhiteSpace([string]$resultHttpStatus)) {
            $lines += "HTTP：$resultHttpStatus"
          }
          if ($resultAttempts -gt 1) {
            $lines += "尝试：$resultAttempts 次"
          }
          if (-not [string]::IsNullOrWhiteSpace([string]$resultPreview)) {
            $lines += "上游响应：$resultPreview"
          }
          Write-SuiteLog -Area "provider.doctor" -Message "endpoint=$resultEndpoint; error=$resultError; networkCode=$resultNetworkCode; http=$resultHttpStatus; transport=$resultTransport; proxyAddress=$resultProxyAddress; resolvedAddress=$resultResolvedAddress"
          & $setDoctorText ($lines -join "`r`n")
        }
        elseif ($doctorState.Operation -eq "models") {
          $currentModel = $modelBox.Text.Trim()
          $modelBox.Items.Clear()
          foreach ($modelId in @($result.models)) {
            [void]$modelBox.Items.Add([string]$modelId)
          }
          if (-not [string]::IsNullOrWhiteSpace($currentModel)) {
            $modelBox.Text = $currentModel
          }
          elseif ($modelBox.Items.Count -gt 0) {
            $modelBox.SelectedIndex = 0
          }
          $lines = @(
              "模型列表可访问"
              "端点：$($result.endpoint)"
              "HTTP：$($result.httpStatus)  |  用时：$($result.durationMs) ms$attemptSuffix"
            )
          $lines += $resultNetworkLines
          $lines += "已载入 $($result.modelCount) 个模型。"
          & $setDoctorText ($lines -join "`r`n")
        }
        else {
          $lines = @(
              "模型请求成功"
              "协议：$(if ($protocolState.Value -eq 'chat') { 'Chat Completions' } else { 'Responses API' })"
              "端点：$($result.endpoint)"
              "HTTP：$($result.httpStatus)  |  用时：$($result.durationMs) ms$attemptSuffix"
            )
          $lines += $resultNetworkLines
          $lines += "响应：$(Get-DisplayValue $result.preview "已返回有效响应")"
          & $setDoctorText ($lines -join "`r`n")
        }
      }
      catch {
        & $setDoctorText "诊断失败`r`n原因：$($_.Exception.Message)"
      }
      finally {
        if ($null -ne $doctorState.Process) {
          $doctorState.Process.Dispose()
        }
        $doctorState.Active = $false
        $doctorState.Operation = ""
        $doctorState.Process = $null
        $doctorState.StdoutTask = $null
        $doctorState.StderrTask = $null
        & $setDoctorBusy $false
      }
    }.GetNewClosure())

  $startDoctor = {
    param([string]$Operation)
    if ($doctorState.Active) {
      return
    }
    $apiKeyBox.UseSystemPasswordChar = $true
    $showKeyButton.Text = "显示"
    $errorLabel.Text = ""
    if ([string]::IsNullOrWhiteSpace($baseUrlBox.Text)) {
      $errorLabel.Text = "请先填写 Base URL。"
      [void]$baseUrlBox.Focus()
      return
    }
    if ($Operation -eq "test" -and [string]::IsNullOrWhiteSpace($modelBox.Text)) {
      $errorLabel.Text = "测试前请选择或输入模型。"
      [void]$modelBox.Focus()
      return
    }

    try {
      $request = [pscustomobject]@{
        action    = $Operation
        protocol  = $protocolState.Value
        baseUrl   = $baseUrlBox.Text.Trim()
        apiKey    = $apiKeyBox.Text.Trim()
        model     = $modelBox.Text.Trim()
        timeoutMs = 20000
      }
      $job = Start-ProviderDoctorProcess -Request $request
      $doctorState.Active = $true
      $doctorState.Operation = $Operation
      $doctorState.Process = $job.Process
      $doctorState.StdoutTask = $job.StdoutTask
      $doctorState.StderrTask = $job.StderrTask
      & $setDoctorBusy $true
      $doctorMessage = if ($Operation -eq "models") { "正在从上游读取模型列表..." } else { "正在发送一次真实模型请求..." }
      & $setDoctorText $doctorMessage
      $doctorTimer.Start()
    }
    catch {
      & $setDoctorText "诊断无法启动`r`n原因：$($_.Exception.Message)"
      & $setDoctorBusy $false
    }
  }.GetNewClosure()

  $fetchModelsButton.Add_Click({ & $startDoctor "models" })
  $testModelButton.Add_Click({ & $startDoctor "test" })
  & $setDoctorText "尚未测试。"

  $okButton.Add_Click({
      $apiKeyBox.UseSystemPasswordChar = $true
      $showKeyButton.Text = "显示"
      $errorLabel.Text = ""
      if ([string]::IsNullOrWhiteSpace($nameBox.Text)) {
        $errorLabel.Text = "请输入配置名称。"
        [void]$nameBox.Focus()
        return
      }
      if ([string]::IsNullOrWhiteSpace($baseUrlBox.Text)) {
        $errorLabel.Text = "请输入 Base URL。"
        [void]$baseUrlBox.Focus()
        return
      }
      $parsedBaseUrl = $null
      if (-not [System.Uri]::TryCreate($baseUrlBox.Text.Trim(), [System.UriKind]::Absolute, [ref]$parsedBaseUrl) -or
          $parsedBaseUrl.Scheme -notin @("http", "https")) {
        $errorLabel.Text = "Base URL 必须是有效的 http 或 https 地址。"
        [void]$baseUrlBox.Focus()
        return
      }
      if ([string]::IsNullOrWhiteSpace($modelBox.Text)) {
        $errorLabel.Text = "请输入默认模型。"
        [void]$modelBox.Focus()
        return
      }
      $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
      $dialog.Close()
    })

  $dialog.AcceptButton = $okButton
  $dialog.CancelButton = $cancelButton

  $applyTheme = {
    param($nextTheme)
    $theme = $nextTheme
    Set-CodexControlTheme -Control $dialog -Theme $theme
    & $refreshProtocolUi
    Set-CodexTitleBar -Form $dialog -Theme $theme
  }.GetNewClosure()
  & $applyTheme $theme
  Enable-CodexThemeRefresh -Form $dialog -ApplyTheme $applyTheme

  $dialog.Add_Shown({
      Set-CodexTitleBar -Form $dialog -Theme (Get-CodexTheme)
      $dialog.TopMost = $true
      [void]$nameBox.Focus()
      [void]$dialog.Activate()
      $dialog.BringToFront()
      [DockerCodexSuiteTheme.NativeMethods]::ActivateWindow($dialog.Handle)
    })
  $dialog.Add_FormClosed({
      $doctorTimer.Stop()
      if ($doctorState.Active -and $null -ne $doctorState.Process) {
        try {
          if (-not $doctorState.Process.HasExited) {
            $doctorState.Process.Kill()
          }
        }
        catch {
        }
        $doctorState.Process.Dispose()
      }
      $doctorTimer.Dispose()
    }.GetNewClosure())

  $result = if ($null -eq $Owner) { $dialog.ShowDialog() } else { $dialog.ShowDialog($Owner) }
  if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    return $null
  }

  $name = $nameBox.Text.Trim()
  $baseUrl = $baseUrlBox.Text.Trim()
  $model = $modelBox.Text.Trim()
  $apiKey = $apiKeyBox.Text.Trim()
  $modelIds = @($model)
  for ($i = 0; $i -lt $modelBox.Items.Count; $i += 1) {
    $candidateModel = ([string]$modelBox.Items[$i]).Trim()
    if (-not [string]::IsNullOrWhiteSpace($candidateModel) -and $candidateModel -notin $modelIds) {
      $modelIds += $candidateModel
    }
  }
  $existingId = if ($isEditing) { [string](Get-ObjectPropertyValue -Object $rawProfile -Name "Id") } else { "" }
  $existingCreatedAt = if ($isEditing) { [string](Get-ObjectPropertyValue -Object $rawProfile -Name "CreatedAt") } else { "" }
  $now = (Get-Date).ToString("s")

  return [pscustomobject]@{
    Id               = if ([string]::IsNullOrWhiteSpace($existingId)) { [guid]::NewGuid().ToString("N") } else { $existingId }
    Name             = $name
    BaseUrl          = $baseUrl
    Model            = $model
    ModelList        = ($modelIds -join "`r`n")
    UpstreamProtocol = $protocolState.Value
    WireApi          = "responses"
    ApiKey           = $apiKey
    EnvKey           = $Script:ApiEnvKey
    ImportedFrom     = if ($isEditing) { [string](Get-ObjectPropertyValue -Object $rawProfile -Name "ImportedFrom") } else { "" }
    SourceProfileId  = if ($isEditing) { [string](Get-ObjectPropertyValue -Object $rawProfile -Name "SourceProfileId") } else { "" }
    SourcePath       = if ($isEditing) { [string](Get-ObjectPropertyValue -Object $rawProfile -Name "SourcePath") } else { "" }
    SourceRelayMode  = if ($isEditing) { [string](Get-ObjectPropertyValue -Object $rawProfile -Name "SourceRelayMode") } else { "" }
    CreatedAt        = if ([string]::IsNullOrWhiteSpace($existingCreatedAt)) { $now } else { $existingCreatedAt }
    UpdatedAt        = $now
  }
}

function Show-CodexPlusPlusImportDialog {
  param(
    $Owner = $null,
    [object[]]$Candidates,
    [string]$SourcePath
  )

  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  Initialize-CodexThemeNative
  $theme = Get-CodexTheme
  $availableCount = @($Candidates | Where-Object { $null -ne $_ -and [bool]$_.CanImport }).Count
  $state = [pscustomobject]@{ Selected = $null }

  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = "从 Codex++ 导入配置"
  Set-DockerCodexWindowIdentity -Form $dialog
  $dialog.StartPosition = if ($null -eq $Owner) { "CenterScreen" } else { "CenterParent" }
  $dialog.ClientSize = New-Object System.Drawing.Size(800, 590)
  $dialog.MinimumSize = New-Object System.Drawing.Size(720, 520)
  $dialog.Font = New-CodexFont -Size 9
  $dialog.ShowInTaskbar = $null -eq $Owner
  if ($Owner -is [System.Windows.Forms.Form]) {
    $dialog.Owner = $Owner
  }

  $rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
  $rootLayout.Dock = "Fill"
  $rootLayout.ColumnCount = 1
  $rootLayout.RowCount = 3
  [void]$rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 82))
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 70))
  $dialog.Controls.Add($rootLayout)

  $header = New-Object System.Windows.Forms.Panel
  $header.Dock = "Fill"
  $header.Margin = New-Object System.Windows.Forms.Padding(0)
  $rootLayout.Controls.Add($header, 0, 0)

  $titleLabel = New-Object System.Windows.Forms.Label
  $titleLabel.Text = "从 Codex++ 导入配置"
  $titleLabel.Font = New-CodexFont -Size 17 -Style ([System.Drawing.FontStyle]::Bold)
  $titleLabel.AutoSize = $true
  $titleLabel.Location = New-Object System.Drawing.Point(22, 14)
  $header.Controls.Add($titleLabel)

  $subtitleLabel = New-Object System.Windows.Forms.Label
  $subtitleLabel.Text = "一次性复制所选配置，导入后不依赖 Codex++，也不会自动切换或重启 Docker Codex。"
  $subtitleLabel.Tag = "muted"
  $subtitleLabel.AutoSize = $true
  $subtitleLabel.Location = New-Object System.Drawing.Point(24, 49)
  $header.Controls.Add($subtitleLabel)

  $body = New-Object System.Windows.Forms.TableLayoutPanel
  $body.Dock = "Fill"
  $body.Padding = New-Object System.Windows.Forms.Padding(22, 0, 22, 16)
  $body.Margin = New-Object System.Windows.Forms.Padding(0)
  $body.ColumnCount = 1
  $body.RowCount = 4
  [void]$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
  [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 34))
  [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 58))
  [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 34))
  [void]$body.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 42))
  $rootLayout.Controls.Add($body, 0, 1)

  $sourceLabel = New-Object System.Windows.Forms.Label
  $sourceLabel.Text = "检测位置：$SourcePath"
  $sourceLabel.Tag = "muted"
  $sourceLabel.AutoSize = $false
  $sourceLabel.AutoEllipsis = $true
  $sourceLabel.TextAlign = "MiddleLeft"
  $sourceLabel.Dock = "Fill"
  $body.Controls.Add($sourceLabel, 0, 0)

  $listFrame = New-Object System.Windows.Forms.Panel
  $listFrame.Tag = "frame"
  $listFrame.Dock = "Fill"
  $listFrame.Padding = New-Object System.Windows.Forms.Padding(1)
  $listFrame.Margin = New-Object System.Windows.Forms.Padding(0)
  $body.Controls.Add($listFrame, 0, 1)

  $candidateList = New-Object System.Windows.Forms.CheckedListBox
  $candidateList.DisplayMember = "DisplayName"
  $candidateList.CheckOnClick = $true
  $candidateList.IntegralHeight = $false
  $candidateList.Dock = "Fill"
  $candidateList.Font = New-CodexFont -Size 9.5
  $listFrame.Controls.Add($candidateList)
  foreach ($candidate in @($Candidates)) {
    if ($null -ne $candidate) {
      [void]$candidateList.Items.Add($candidate, [bool]$candidate.CanImport)
    }
  }

  $detailsTitle = New-Object System.Windows.Forms.Label
  $detailsTitle.Text = "导入预览"
  $detailsTitle.Font = New-CodexFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
  $detailsTitle.AutoSize = $true
  $detailsTitle.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
  $body.Controls.Add($detailsTitle, 0, 2)

  $detailsFrame = New-Object System.Windows.Forms.Panel
  $detailsFrame.Tag = "frame"
  $detailsFrame.Dock = "Fill"
  $detailsFrame.Padding = New-Object System.Windows.Forms.Padding(1)
  $detailsFrame.Margin = New-Object System.Windows.Forms.Padding(0)
  $body.Controls.Add($detailsFrame, 0, 3)

  $detailsBox = New-Object System.Windows.Forms.RichTextBox
  $detailsBox.Tag = "read-only"
  $detailsBox.Dock = "Fill"
  $detailsBox.ReadOnly = $true
  $detailsBox.ScrollBars = "Vertical"
  $detailsBox.WordWrap = $true
  $detailsBox.DetectUrls = $false
  $detailsBox.Font = New-CodexFont -Size 9
  $detailsFrame.Controls.Add($detailsBox)

  $footer = New-Object System.Windows.Forms.Panel
  $footer.Tag = "surface"
  $footer.Dock = "Fill"
  $footer.Margin = New-Object System.Windows.Forms.Padding(0)
  $rootLayout.Controls.Add($footer, 0, 2)

  $separator = New-Object System.Windows.Forms.Panel
  $separator.Tag = "separator"
  $separator.Dock = "Top"
  $separator.Height = 1
  $footer.Controls.Add($separator)

  $selectionLabel = New-Object System.Windows.Forms.Label
  $selectionLabel.Tag = "muted"
  $selectionLabel.AutoSize = $false
  $selectionLabel.Location = New-Object System.Drawing.Point(22, 14)
  $selectionLabel.Size = New-Object System.Drawing.Size(460, 42)
  $selectionLabel.TextAlign = "MiddleLeft"
  $selectionLabel.Anchor = "Top,Left,Right"
  $footer.Controls.Add($selectionLabel)

  $cancelButton = New-Object DockerCodexSuiteTheme.CodexButton
  $cancelButton.Text = "取消"
  $cancelButton.Tag = "secondary"
  $cancelButton.Location = New-Object System.Drawing.Point(538, 17)
  $cancelButton.Size = New-Object System.Drawing.Size(112, 36)
  $cancelButton.Anchor = "Top,Right"
  $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $footer.Controls.Add($cancelButton)

  $importButton = New-Object DockerCodexSuiteTheme.CodexButton
  $importButton.Text = "导入所选"
  $importButton.Tag = "primary"
  $importButton.Location = New-Object System.Drawing.Point(666, 17)
  $importButton.Size = New-Object System.Drawing.Size(112, 36)
  $importButton.Anchor = "Top,Right"
  $importButton.Enabled = $availableCount -gt 0
  $footer.Controls.Add($importButton)

  $formatCandidate = {
    param($Candidate)

    if ($null -eq $Candidate) {
      return "请选择上方的一项查看详情。"
    }
    $activeLine = if ([bool]$Candidate.IsActive) { "Codex++ 当前配置：是" } else { "Codex++ 当前配置：否" }
    if (-not [bool]$Candidate.CanImport -or $null -eq $Candidate.Profile) {
      return @(
        "名称：$(Get-DisplayValue $Candidate.Name)"
        "状态：不可导入"
        "原因：$(Get-DisplayValue $Candidate.Reason)"
        $activeLine
      ) -join "`r`n"
    }

    $profile = $Candidate.Profile
    $protocolLabel = if ([string]$profile.UpstreamProtocol -eq "chat") { "Chat Completions → Responses" } else { "Responses API" }
    $modelIds = @(Get-ProfileModelIds -Profile $profile)
    $modelPreview = ($modelIds | Select-Object -First 6) -join "、"
    if ($modelIds.Count -gt 6) {
      $modelPreview += " 等 $($modelIds.Count) 个"
    }
    return @(
      "名称：$(Get-DisplayValue $profile.Name)"
      "协议：$protocolLabel"
      "真实上游：$(Get-DisplayValue $profile.BaseUrl)"
      "默认模型：$(Get-DisplayValue $profile.Model)"
      "模型：$(Get-DisplayValue $modelPreview '未提供')"
      "API Key：已检测到（此窗口不会显示）"
      $activeLine
    ) -join "`r`n"
  }.GetNewClosure()

  $updateDetails = {
    $text = & $formatCandidate $candidateList.SelectedItem
    Set-CodexRichText -Box $detailsBox -Text $text -Theme (Get-CodexTheme)
  }.GetNewClosure()

  $setSelectionText = {
    param([int]$Count)
    $selectionLabel.Text = "已选择 $Count 项，可导入 $availableCount 项。导入只保存配置，不会立即应用。"
  }.GetNewClosure()

  $candidateList.Add_SelectedIndexChanged({ & $updateDetails }.GetNewClosure())
  $candidateList.Add_ItemCheck({
      $eventArgs = $_
      $candidate = $candidateList.Items[$eventArgs.Index]
      if (-not [bool]$candidate.CanImport) {
        $eventArgs.NewValue = [System.Windows.Forms.CheckState]::Unchecked
      }
      $nextCount = $candidateList.CheckedItems.Count
      if ($eventArgs.CurrentValue -eq [System.Windows.Forms.CheckState]::Unchecked -and
          $eventArgs.NewValue -eq [System.Windows.Forms.CheckState]::Checked) {
        $nextCount += 1
      }
      elseif ($eventArgs.CurrentValue -eq [System.Windows.Forms.CheckState]::Checked -and
              $eventArgs.NewValue -eq [System.Windows.Forms.CheckState]::Unchecked) {
        $nextCount -= 1
      }
      & $setSelectionText $nextCount
    }.GetNewClosure())

  $importButton.Add_Click({
      $selected = @()
      foreach ($candidate in @($candidateList.CheckedItems)) {
        if ($null -ne $candidate -and [bool]$candidate.CanImport) {
          $selected += $candidate
        }
      }
      if ($selected.Count -eq 0) {
        $selectionLabel.Tag = "warning"
        $selectionLabel.Text = "请至少勾选一个可导入配置。"
        Set-CodexControlTheme -Control $selectionLabel -Theme (Get-CodexTheme)
        return
      }
      $state.Selected = $selected
      $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
      $dialog.Close()
    }.GetNewClosure())

  $dialog.AcceptButton = $importButton
  $dialog.CancelButton = $cancelButton

  $applyTheme = {
    param($nextTheme)
    $theme = $nextTheme
    Set-CodexControlTheme -Control $dialog -Theme $theme
    & $updateDetails
    Set-CodexTitleBar -Form $dialog -Theme $theme
  }.GetNewClosure()
  & $applyTheme $theme
  Enable-CodexThemeRefresh -Form $dialog -ApplyTheme $applyTheme
  & $setSelectionText $candidateList.CheckedItems.Count
  if ($candidateList.Items.Count -gt 0) {
    $candidateList.SelectedIndex = 0
  }
  else {
    & $updateDetails
  }

  $dialog.Add_Shown({
      Set-CodexTitleBar -Form $dialog -Theme (Get-CodexTheme)
      [void]$dialog.Activate()
      $dialog.BringToFront()
      [DockerCodexSuiteTheme.NativeMethods]::ActivateWindow($dialog.Handle)
    }.GetNewClosure())

  $result = if ($null -eq $Owner) { $dialog.ShowDialog() } else { $dialog.ShowDialog($Owner) }
  if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    return $null
  }
  return @($state.Selected)
}

function Show-Gui {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  Initialize-CodexThemeNative

  $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
  try {
    $installHash = [BitConverter]::ToString(
      $hashAlgorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Script:InstallDir))
    ).Replace("-", "").Substring(0, 16)
  }
  finally {
    $hashAlgorithm.Dispose()
  }
  $mutexName = "Local\DockerCodexSuite.ApiSwitcher.$installHash"
  $switcherMutex = New-Object System.Threading.Mutex($false, $mutexName)
  $ownsSwitcherMutex = $false
  try {
    $ownsSwitcherMutex = $switcherMutex.WaitOne(0, $false)
  }
  catch [System.Threading.AbandonedMutexException] {
    $ownsSwitcherMutex = $true
  }
  if (-not $ownsSwitcherMutex) {
    $activated = [DockerCodexSuiteTheme.NativeMethods]::ActivateWindowByTitle("Docker Codex API 切换器")
    if ($activated) {
      $switcherMutex.Dispose()
      return
    }
    Write-SuiteLog -Area "gui" -Message "Switcher mutex was occupied but no existing window was found; continuing with a new window. mutex=$mutexName"
  }

  $theme = Get-CodexTheme

  $form = New-Object System.Windows.Forms.Form
  $form.Text = "Docker Codex API 切换器"
  Set-DockerCodexWindowIdentity -Form $form
  $form.StartPosition = "CenterScreen"
  $form.ClientSize = New-Object System.Drawing.Size(1100, 740)
  $form.MinimumSize = New-Object System.Drawing.Size(960, 640)
  $form.Font = New-CodexFont -Size 9
  $form.TopMost = $true
  $form.ShowInTaskbar = $true
  $form.WindowState = "Normal"

  $rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
  $rootLayout.Dock = "Fill"
  $rootLayout.ColumnCount = 1
  $rootLayout.RowCount = 3
  [void]$rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 84))
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 118))
  $form.Controls.Add($rootLayout)

  $header = New-Object System.Windows.Forms.Panel
  $header.Dock = "Fill"
  $header.Margin = New-Object System.Windows.Forms.Padding(0)
  $rootLayout.Controls.Add($header, 0, 0)

  $titleLabel = New-Object System.Windows.Forms.Label
  $titleLabel.Text = "Docker Codex API 切换器"
  $titleLabel.Font = New-CodexFont -Size 18 -Style ([System.Drawing.FontStyle]::Bold)
  $titleLabel.AutoSize = $true
  $titleLabel.Location = New-Object System.Drawing.Point(20, 17)
  $header.Controls.Add($titleLabel)

  $statusSummaryLabel = New-Object System.Windows.Forms.Label
  $statusSummaryLabel.Tag = "muted"
  $statusSummaryLabel.AutoSize = $false
  $statusSummaryLabel.TextAlign = "MiddleRight"
  $statusSummaryLabel.Location = New-Object System.Drawing.Point(520, 16)
  $statusSummaryLabel.Size = New-Object System.Drawing.Size(550, 28)
  $statusSummaryLabel.Anchor = "Top,Left,Right"
  $header.Controls.Add($statusSummaryLabel)

  $updatedLabel = New-Object System.Windows.Forms.Label
  $updatedLabel.Tag = "muted"
  $updatedLabel.AutoSize = $false
  $updatedLabel.TextAlign = "MiddleRight"
  $updatedLabel.Location = New-Object System.Drawing.Point(520, 44)
  $updatedLabel.Size = New-Object System.Drawing.Size(550, 22)
  $updatedLabel.Anchor = "Top,Left,Right"
  $header.Controls.Add($updatedLabel)

  $commandPanel = New-Object System.Windows.Forms.Panel
  $commandPanel.Tag = "surface"
  $commandPanel.Dock = "Fill"
  $commandPanel.Margin = New-Object System.Windows.Forms.Padding(0)
  $rootLayout.Controls.Add($commandPanel, 0, 2)

  $commandSeparator = New-Object System.Windows.Forms.Panel
  $commandSeparator.Tag = "separator"
  $commandSeparator.Dock = "Top"
  $commandSeparator.Height = 1
  $commandPanel.Controls.Add($commandSeparator)

  $split = New-Object System.Windows.Forms.SplitContainer
  $split.Size = New-Object System.Drawing.Size(1100, 538)
  $split.Dock = "Fill"
  $split.FixedPanel = "Panel1"
  $split.SplitterDistance = 360
  $split.SplitterWidth = 1
  $split.Panel1MinSize = 310
  $split.Panel2MinSize = 450
  $split.BorderStyle = "None"
  $split.Margin = New-Object System.Windows.Forms.Padding(0)
  $rootLayout.Controls.Add($split, 0, 1)

  $leftLayout = New-Object System.Windows.Forms.TableLayoutPanel
  $leftLayout.Dock = "Fill"
  $leftLayout.Padding = New-Object System.Windows.Forms.Padding(18, 0, 18, 0)
  $leftLayout.ColumnCount = 1
  $leftLayout.RowCount = 5
  [void]$leftLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
  [void]$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 44))
  [void]$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 220))
  [void]$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 38))
  [void]$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
  [void]$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 102))
  $split.Panel1.Controls.Add($leftLayout)

  $profileHeader = New-Object System.Windows.Forms.Panel
  $profileHeader.Dock = "Fill"
  $leftLayout.Controls.Add($profileHeader, 0, 0)

  $profileTitle = New-Object System.Windows.Forms.Label
  $profileTitle.Text = "API 配置"
  $profileTitle.Font = New-CodexFont -Size 11 -Style ([System.Drawing.FontStyle]::Bold)
  $profileTitle.AutoSize = $true
  $profileTitle.Location = New-Object System.Drawing.Point(0, 14)
  $profileHeader.Controls.Add($profileTitle)

  $profileCountLabel = New-Object System.Windows.Forms.Label
  $profileCountLabel.Tag = "muted"
  $profileCountLabel.AutoSize = $false
  $profileCountLabel.TextAlign = "MiddleRight"
  $profileCountLabel.Location = New-Object System.Drawing.Point(210, 10)
  $profileCountLabel.Size = New-Object System.Drawing.Size(114, 26)
  $profileCountLabel.Anchor = "Top,Right"
  $profileHeader.Controls.Add($profileCountLabel)

  $profileListFrame = New-Object System.Windows.Forms.Panel
  $profileListFrame.Tag = "frame"
  $profileListFrame.Dock = "Fill"
  $profileListFrame.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
  $profileListFrame.Padding = New-Object System.Windows.Forms.Padding(1)
  $leftLayout.Controls.Add($profileListFrame, 0, 1)

  $profileList = New-Object System.Windows.Forms.ListBox
  $profileList.DisplayMember = "DisplayName"
  $profileList.Dock = "Fill"
  $profileList.IntegralHeight = $false
  $profileList.Font = New-CodexFont -Size 9.5
  $profileListFrame.Controls.Add($profileList)

  $profileDetailsHeader = New-Object System.Windows.Forms.Panel
  $profileDetailsHeader.Dock = "Fill"
  $leftLayout.Controls.Add($profileDetailsHeader, 0, 2)

  $profileDetailsTitle = New-Object System.Windows.Forms.Label
  $profileDetailsTitle.Text = "配置详情"
  $profileDetailsTitle.Font = New-CodexFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
  $profileDetailsTitle.AutoSize = $true
  $profileDetailsTitle.Location = New-Object System.Drawing.Point(0, 11)
  $profileDetailsHeader.Controls.Add($profileDetailsTitle)

  $profileDetailsFrame = New-Object System.Windows.Forms.Panel
  $profileDetailsFrame.Tag = "frame"
  $profileDetailsFrame.Dock = "Fill"
  $profileDetailsFrame.Padding = New-Object System.Windows.Forms.Padding(1)
  $leftLayout.Controls.Add($profileDetailsFrame, 0, 3)

  $profileDetails = New-Object System.Windows.Forms.RichTextBox
  $profileDetails.Tag = "read-only"
  $profileDetails.Dock = "Fill"
  $profileDetails.ReadOnly = $true
  $profileDetails.ScrollBars = "Vertical"
  $profileDetails.WordWrap = $true
  $profileDetails.Font = New-CodexFont -Size 9
  $profileDetails.DetectUrls = $false
  $profileDetailsFrame.Controls.Add($profileDetails)

  $profileActions = New-Object System.Windows.Forms.Panel
  $profileActions.Dock = "Fill"
  $leftLayout.Controls.Add($profileActions, 0, 4)

  $newProfileButton = New-Object DockerCodexSuiteTheme.CodexButton
  $newProfileButton.Text = "新建"
  $newProfileButton.Tag = "secondary"
  $newProfileButton.Location = New-Object System.Drawing.Point(0, 12)
  $newProfileButton.Size = New-Object System.Drawing.Size(76, 34)
  $profileActions.Controls.Add($newProfileButton)

  $editProfileButton = New-Object DockerCodexSuiteTheme.CodexButton
  $editProfileButton.Text = "编辑"
  $editProfileButton.Tag = "secondary"
  $editProfileButton.Location = New-Object System.Drawing.Point(82, 12)
  $editProfileButton.Size = New-Object System.Drawing.Size(76, 34)
  $editProfileButton.Enabled = $false
  $profileActions.Controls.Add($editProfileButton)

  $deleteProfileButton = New-Object DockerCodexSuiteTheme.CodexButton
  $deleteProfileButton.Text = "删除"
  $deleteProfileButton.Tag = "secondary"
  $deleteProfileButton.Location = New-Object System.Drawing.Point(164, 12)
  $deleteProfileButton.Size = New-Object System.Drawing.Size(76, 34)
  $deleteProfileButton.Enabled = $false
  $profileActions.Controls.Add($deleteProfileButton)

  $reloadProfilesButton = New-Object DockerCodexSuiteTheme.CodexButton
  $reloadProfilesButton.Text = "刷新"
  $reloadProfilesButton.Tag = "secondary"
  $reloadProfilesButton.Location = New-Object System.Drawing.Point(246, 12)
  $reloadProfilesButton.Size = New-Object System.Drawing.Size(76, 34)
  $profileActions.Controls.Add($reloadProfilesButton)

  $importCodexPlusPlusButton = New-Object DockerCodexSuiteTheme.CodexButton
  $importCodexPlusPlusButton.Text = "从 Codex++ 导入配置"
  $importCodexPlusPlusButton.Tag = "secondary"
  $importCodexPlusPlusButton.Location = New-Object System.Drawing.Point(0, 56)
  $importCodexPlusPlusButton.Size = New-Object System.Drawing.Size(322, 34)
  $importCodexPlusPlusButton.Anchor = "Top,Left,Right"
  $profileActions.Controls.Add($importCodexPlusPlusButton)

  $rightLayout = New-Object System.Windows.Forms.TableLayoutPanel
  $rightLayout.Dock = "Fill"
  $rightLayout.Padding = New-Object System.Windows.Forms.Padding(18, 0, 18, 18)
  $rightLayout.ColumnCount = 1
  $rightLayout.RowCount = 2
  [void]$rightLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
  [void]$rightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 44))
  [void]$rightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100))
  $split.Panel2.Controls.Add($rightLayout)

  $statusHeader = New-Object System.Windows.Forms.Panel
  $statusHeader.Dock = "Fill"
  $rightLayout.Controls.Add($statusHeader, 0, 0)

  $statusTitle = New-Object System.Windows.Forms.Label
  $statusTitle.Text = "连接状态"
  $statusTitle.Font = New-CodexFont -Size 11 -Style ([System.Drawing.FontStyle]::Bold)
  $statusTitle.AutoSize = $true
  $statusTitle.Location = New-Object System.Drawing.Point(0, 14)
  $statusHeader.Controls.Add($statusTitle)

  $statusFrame = New-Object System.Windows.Forms.Panel
  $statusFrame.Tag = "frame"
  $statusFrame.Dock = "Fill"
  $statusFrame.Padding = New-Object System.Windows.Forms.Padding(1)
  $rightLayout.Controls.Add($statusFrame, 0, 1)

  $statusBox = New-Object System.Windows.Forms.RichTextBox
  $statusBox.Tag = "read-only"
  $statusBox.Dock = "Fill"
  $statusBox.ReadOnly = $true
  $statusBox.ScrollBars = "Vertical"
  $statusBox.WordWrap = $true
  $statusBox.Font = New-CodexFont -Size 9.5
  $statusBox.DetectUrls = $false
  $statusFrame.Controls.Add($statusBox)

  $commandButtonWidth = 144
  $commandButtonHeight = 38
  $commandButtonGap = 14
  $commandButtonLeft = 20
  $commandButtonTop = 16
  $commandButtonRowTop = 68
  $commandButtonStep = $commandButtonWidth + $commandButtonGap

  $applyProfileButton = New-Object DockerCodexSuiteTheme.CodexButton
  $applyProfileButton.Text = "应用所选配置"
  $applyProfileButton.Tag = "primary"
  $applyProfileButton.Location = New-Object System.Drawing.Point($commandButtonLeft, $commandButtonTop)
  $applyProfileButton.Size = New-Object System.Drawing.Size($commandButtonWidth, $commandButtonHeight)
  $commandPanel.Controls.Add($applyProfileButton)

  $reconnectButton = New-Object DockerCodexSuiteTheme.CodexButton
  $reconnectButton.Text = "重新连接"
  $reconnectButton.Tag = "secondary"
  $reconnectButton.Location = New-Object System.Drawing.Point(($commandButtonLeft + (3 * $commandButtonStep)), $commandButtonTop)
  $reconnectButton.Size = New-Object System.Drawing.Size($commandButtonWidth, $commandButtonHeight)
  $commandPanel.Controls.Add($reconnectButton)

  $refreshButton = New-Object DockerCodexSuiteTheme.CodexButton
  $refreshButton.Text = "刷新状态"
  $refreshButton.Tag = "secondary"
  $refreshButton.Location = New-Object System.Drawing.Point(($commandButtonLeft + (4 * $commandButtonStep)), $commandButtonTop)
  $refreshButton.Size = New-Object System.Drawing.Size($commandButtonWidth, $commandButtonHeight)
  $commandPanel.Controls.Add($refreshButton)

  $useHostButton = New-Object DockerCodexSuiteTheme.CodexButton
  $useHostButton.Text = "跟随主空间"
  $useHostButton.Tag = "secondary"
  $useHostButton.Location = New-Object System.Drawing.Point(($commandButtonLeft + $commandButtonStep), $commandButtonTop)
  $useHostButton.Size = New-Object System.Drawing.Size($commandButtonWidth, $commandButtonHeight)
  $commandPanel.Controls.Add($useHostButton)

  $useDockerButton = New-Object DockerCodexSuiteTheme.CodexButton
  $useDockerButton.Text = "Docker 本地"
  $useDockerButton.Tag = "secondary"
  $useDockerButton.Location = New-Object System.Drawing.Point(($commandButtonLeft + (2 * $commandButtonStep)), $commandButtonTop)
  $useDockerButton.Size = New-Object System.Drawing.Size($commandButtonWidth, $commandButtonHeight)
  $commandPanel.Controls.Add($useDockerButton)

  $captureButton = New-Object DockerCodexSuiteTheme.CodexButton
  $captureButton.Text = "保存本地模板"
  $captureButton.Tag = "secondary"
  $captureButton.Location = New-Object System.Drawing.Point($commandButtonLeft, $commandButtonRowTop)
  $captureButton.Size = New-Object System.Drawing.Size($commandButtonWidth, $commandButtonHeight)
  $commandPanel.Controls.Add($captureButton)

  $openDirButton = New-Object DockerCodexSuiteTheme.CodexButton
  $openDirButton.Text = "打开配置目录"
  $openDirButton.Tag = "secondary"
  $openDirButton.Location = New-Object System.Drawing.Point(($commandButtonLeft + $commandButtonStep), $commandButtonRowTop)
  $openDirButton.Size = New-Object System.Drawing.Size($commandButtonWidth, $commandButtonHeight)
  $commandPanel.Controls.Add($openDirButton)

  $refreshStatus = {
    $status = Get-StatusObject
    $statusText = Format-StatusText -Status $status -Compact
    $currentTheme = Get-CodexTheme
    Set-CodexRichText -Box $statusBox -Text $statusText -Theme $currentTheme

    $modeLabel = switch ($status.Mode) {
      "host" { "主空间 API" }
      "docker" { "Docker 本地 API" }
      "profile" { "配置：$(Get-DisplayValue $status.ProfileName)" }
      default { "手动配置" }
    }
    $containerLabel = switch ($status.ContainerStatus) {
      "running" { "容器运行中" }
      "exited" { "容器已停止" }
      "not-found" { "未找到容器" }
      default { "容器：$(Get-DisplayValue $status.ContainerStatus)" }
    }
    $statusSummaryLabel.Text = "$modeLabel  |  $containerLabel"
    $updatedLabel.Text = "状态更新于 $((Get-Date).ToString("HH:mm:ss"))"

    $useHostButton.Tag = if ($status.Mode -eq "host") { "selected" } else { "secondary" }
    $useDockerButton.Tag = if ($status.Mode -eq "docker") { "selected" } else { "secondary" }
    Set-CodexButtonTheme -Button $useHostButton -Theme $currentTheme -Role ([string]$useHostButton.Tag)
    Set-CodexButtonTheme -Button $useDockerButton -Theme $currentTheme -Role ([string]$useDockerButton.Tag)
  }

  $loadProfiles = {
    param([string]$SelectId = "")

    $profileList.Items.Clear()
    $profiles = @(Get-ApiProfiles)
    foreach ($profile in $profiles) {
      [void]$profileList.Items.Add($profile)
    }
    $profileCountLabel.Text = "$($profiles.Count) 项"

    if (-not [string]::IsNullOrWhiteSpace($SelectId)) {
      for ($i = 0; $i -lt $profileList.Items.Count; $i += 1) {
        if ($profileList.Items[$i].Id -eq $SelectId) {
          $profileList.SelectedIndex = $i
          break
        }
      }
    }

    if ($profileList.Items.Count -gt 0 -and $profileList.SelectedIndex -lt 0) {
      $profileList.SelectedIndex = 0
    }

    if ($profileList.Items.Count -eq 0) {
      Set-CodexRichText -Box $profileDetails -Text "没有读取到 API 配置。" -Theme (Get-CodexTheme)
    }
    & $updateProfileSelection
  }

  $runAction = {
    param(
      [scriptblock]$Body,
      [string]$SuccessMessage
    )

    $form.UseWaitCursor = $true
    $commandPanel.Enabled = $false
    $form.Refresh()
    try {
      & $Body
      & $refreshStatus
      Show-Message -Text $SuccessMessage -Title "Docker Codex API 切换器" -Owner $form
    }
    catch {
      Show-Message -Text $_.Exception.Message -Title "Docker Codex API 切换器" -Owner $form
    }
    finally {
      $commandPanel.Enabled = $true
      $form.UseWaitCursor = $false
    }
  }

  $profileEditorState = [pscustomobject]@{ Active = $false }

  $updateProfileSelection = {
    $selectedProfile = $profileList.SelectedItem
    Set-CodexRichText -Box $profileDetails -Text (Format-ProfileText $selectedProfile) -Theme (Get-CodexTheme)
    $hasEditableProfile = $null -ne $selectedProfile -and $null -ne $selectedProfile.RawProfile
    $editProfileButton.Enabled = $hasEditableProfile
    $deleteProfileButton.Enabled = $hasEditableProfile
    $applyProfileButton.Enabled = $null -ne $selectedProfile
  }.GetNewClosure()

  $profileList.Add_SelectedIndexChanged({ & $updateProfileSelection })

  $applyProfileButton.Add_Click({
      $selectedProfile = $profileList.SelectedItem
      if ($null -eq $selectedProfile) {
        Show-Message -Text "请先从左侧列表选择一个 API 配置。" -Title "Docker Codex API 切换器" -Owner $form
        return
      }

      & $runAction { Apply-ApiProfile -Profile $selectedProfile } "已切换到 API 配置：$($selectedProfile.DisplayName)。Docker Codex 已重启并重新连接。"
    })

  $newProfileButton.Add_Click({
      if ($profileEditorState.Active) {
        [DockerCodexSuiteTheme.NativeMethods]::ActivateWindow($form.Handle)
        return
      }
      $profileEditorState.Active = $true
      try {
        $profile = Show-NewProfileDialog -Owner $form
        if ($null -eq $profile) {
          return
        }

        Save-LocalProfile -Profile $profile
        & $loadProfiles ("local:" + $profile.Id)
        Show-Message -Text "已保存本地 API 配置：$($profile.Name)。" -Title "Docker Codex API 切换器" -Owner $form
      }
      catch {
        Write-SuiteLog -Area "profile.new" -Message $_.Exception.ToString()
        Show-Message -Text (Protect-SensitiveText $_.Exception.Message) -Title "Docker Codex API 切换器" -Owner $form
      }
      finally {
        $profileEditorState.Active = $false
        [void]$form.Activate()
        $form.BringToFront()
      }
    })

  $editProfileButton.Add_Click({
      if ($profileEditorState.Active) {
        [DockerCodexSuiteTheme.NativeMethods]::ActivateWindow($form.Handle)
        return
      }
      $profileEditorState.Active = $true
      try {
        $selectedProfile = $profileList.SelectedItem
        if ($null -eq $selectedProfile -or $null -eq $selectedProfile.RawProfile) {
          Show-Message -Text "请先选择一个可编辑的 API 配置。" -Title "Docker Codex API 切换器" -Owner $form
          return
        }
        $profile = Show-NewProfileDialog -Owner $form -Profile $selectedProfile
        if ($null -eq $profile) {
          return
        }
        Save-LocalProfile -Profile $profile
        & $loadProfiles ("local:" + $profile.Id)
        Show-Message -Text "已更新本地 API 配置：$($profile.Name)。" -Title "Docker Codex API 切换器" -Owner $form
      }
      catch {
        Write-SuiteLog -Area "profile.edit" -Message $_.Exception.ToString()
        Show-Message -Text (Protect-SensitiveText $_.Exception.Message) -Title "Docker Codex API 切换器" -Owner $form
      }
      finally {
        $profileEditorState.Active = $false
        [void]$form.Activate()
        $form.BringToFront()
      }
    })

  $deleteProfileButton.Add_Click({
      try {
        $selectedProfile = $profileList.SelectedItem
        if ($null -eq $selectedProfile -or $null -eq $selectedProfile.RawProfile) {
          return
        }
        $answer = [System.Windows.Forms.MessageBox]::Show(
          $form,
          "删除配置 $($selectedProfile.Name)？已经写入 Docker 的当前配置不会立即改变。",
          "删除 API 配置",
          [System.Windows.Forms.MessageBoxButtons]::YesNo,
          [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
          return
        }
        $rawId = [string](Get-ObjectPropertyValue -Object $selectedProfile.RawProfile -Name "Id")
        Remove-LocalProfile -Id $rawId
        & $loadProfiles
      }
      catch {
        Write-SuiteLog -Area "profile.delete" -Message $_.Exception.ToString()
        Show-Message -Text (Protect-SensitiveText $_.Exception.Message) -Title "Docker Codex API 切换器" -Owner $form
      }
    })

  $reloadProfilesButton.Add_Click({
      & $loadProfiles
    })

  $importCodexPlusPlusButton.Add_Click({
      if ($profileEditorState.Active) {
        [DockerCodexSuiteTheme.NativeMethods]::ActivateWindow($form.Handle)
        return
      }
      $profileEditorState.Active = $true
      try {
        $candidates = @(Get-CodexPlusPlusImportCandidates)
        if ($candidates.Count -eq 0) {
          Show-Message -Text "Codex++ 配置文件中没有可识别的 API 配置。`r`n检测位置：$Script:CodexPlusPlusSettingsPath" -Title "从 Codex++ 导入配置" -Owner $form
          return
        }
        $selectedCandidates = @(Show-CodexPlusPlusImportDialog -Owner $form -Candidates $candidates -SourcePath $Script:CodexPlusPlusSettingsPath)
        if ($selectedCandidates.Count -eq 0) {
          return
        }

        $importResult = Import-CodexPlusPlusProfiles -Candidates $selectedCandidates
        $selectId = if ($importResult.ImportedIds.Count -gt 0) { "local:" + [string]$importResult.ImportedIds[0] } else { "" }
        & $loadProfiles $selectId
        Show-Message `
          -Text "导入完成：新增 $($importResult.Added) 项，更新 $($importResult.Updated) 项。`r`n`r`n配置已独立保存，不依赖 Codex++。本次导入没有自动切换 API，也没有重启 Docker Codex；确认配置后请点击“应用所选配置”。" `
          -Title "从 Codex++ 导入配置" `
          -Owner $form
      }
      catch {
        Write-SuiteLog -Area "profile.import.codexplusplus" -Message (Protect-SensitiveText $_.Exception.ToString())
        Show-Message -Text (Protect-SensitiveText $_.Exception.Message) -Title "从 Codex++ 导入配置" -Owner $form
      }
      finally {
        $profileEditorState.Active = $false
        [void]$form.Activate()
        $form.BringToFront()
      }
    })

  $reconnectButton.Add_Click({
      & $runAction { Reconnect-DockerCodex } "Docker Codex 已通过原生入口重启并重新连接。"
    })

  $refreshButton.Add_Click({
      try {
        & $refreshStatus
      }
      catch {
        Show-Message -Text $_.Exception.Message -Title "Docker Codex API 切换器" -Owner $form
      }
    })

  $useHostButton.Add_Click({
      & $runAction { Use-HostMode } "已切换为主空间 API 模式，Docker Codex 已重新连接。"
    })

  $useDockerButton.Add_Click({
      & $runAction { Use-DockerMode } "已切换回 Docker API 模式，Docker Codex 已重新连接。"
    })

  $captureButton.Add_Click({
      & $runAction { Capture-DockerModeTemplate } "已更新 Docker 本地模板。"
    })

  $openDirButton.Add_Click({
      Start-Process explorer.exe $Script:ComposeDir
    })

  $applyTheme = {
    param($nextTheme)
    $theme = $nextTheme
    Set-CodexControlTheme -Control $form -Theme $theme
    $split.BackColor = $theme.Border
    if (-not [string]::IsNullOrWhiteSpace($profileDetails.Text)) {
      Set-CodexRichText -Box $profileDetails -Text $profileDetails.Text -Theme $theme
    }
    if (-not [string]::IsNullOrWhiteSpace($statusBox.Text)) {
      Set-CodexRichText -Box $statusBox -Text $statusBox.Text -Theme $theme
    }
    Set-CodexTitleBar -Form $form -Theme $theme
  }.GetNewClosure()

  # Show the shell first. Docker inspection and profile loading can be slow on
  # a fresh install or while Docker Desktop is reconnecting; doing that work
  # before ShowDialog makes a healthy GUI look like it never started.
  $commandPanel.Enabled = $false
  $profileCountLabel.Text = "正在加载..."
  $statusSummaryLabel.Text = "正在读取 Docker/Codex 状态..."
  $updatedLabel.Text = "窗口已打开，正在加载配置"
  $profileDetails.Text = "正在读取 API 配置..."
  $statusBox.Text = "正在读取 Docker/Codex 状态..."
  & $applyTheme $theme
  Enable-CodexThemeRefresh -Form $form -ApplyTheme $applyTheme

  $initializationTimer = New-Object System.Windows.Forms.Timer
  $initializationTimer.Interval = 1
  $initializationState = [pscustomobject]@{ Disposed = $false }
  $initializationTimer.Add_Tick({
      $initializationTimer.Stop()
      try {
        Write-SuiteLog -Area "gui" -Message "Switcher window shown; loading profiles and status."
        & $loadProfiles
        & $refreshStatus
        Write-SuiteLog -Area "gui" -Message "Switcher initial load completed."
      }
      catch {
        $message = Protect-SensitiveText $_.Exception.Message
        Write-SuiteLog -Area "gui.initial-load" -Message $_.Exception.ToString()
        $statusSummaryLabel.Text = "加载失败"
        $updatedLabel.Text = "请查看切换器日志"
        $statusBox.Text = $message
        Set-CodexRichText -Box $statusBox -Text $message -Theme (Get-CodexTheme)
      }
      finally {
        $commandPanel.Enabled = $true
      }
    }.GetNewClosure())
  $form.Add_FormClosed({
      if (-not $initializationState.Disposed) {
        if ($initializationTimer.Enabled) {
          $initializationTimer.Stop()
        }
        $initializationTimer.Dispose()
        $initializationState.Disposed = $true
      }
    }.GetNewClosure())
  $form.Add_Shown({
      $form.WindowState = "Normal"
      $form.TopMost = $true
      Set-CodexTitleBar -Form $form -Theme (Get-CodexTheme)
      [void]$form.Activate()
      $form.BringToFront()
      [void]$form.BeginInvoke([System.Action]{ $form.TopMost = $false })
      $initializationTimer.Start()
    }.GetNewClosure())
  try {
    [void]$form.ShowDialog()
  }
  finally {
    if ($ownsSwitcherMutex) {
      $switcherMutex.ReleaseMutex()
    }
    $switcherMutex.Dispose()
  }
}

switch ($Action) {
  "Status" {
    Write-Output (Format-StatusText)
  }
  "Profiles" {
    Get-ApiProfiles |
      Select-Object Id, Source, Name, Model, Provider, BaseUrl, UpstreamProtocol, AuthMode, ModelList |
      ConvertTo-Json -Depth 4
  }
  "StatusGui" {
    Show-Message -Text (Format-StatusText) -Title "Docker Codex API 状态"
  }
  "UseHost" {
    Use-HostMode
    Write-Output (Format-StatusText)
  }
  "UseDocker" {
    Use-DockerMode
    Write-Output (Format-StatusText)
  }
  "CaptureDocker" {
    Capture-DockerModeTemplate
    Write-Output (Format-StatusText)
  }
  "Reconnect" {
    Reconnect-DockerCodex
    Write-Output (Format-StatusText)
  }
  "RepairProfile" {
    Repair-ActiveApiProfile | ConvertTo-Json -Depth 4
  }
  "Gui" {
    try {
      Show-Gui
    }
    catch {
      Write-SuiteLog -Area "gui" -Message $_.Exception.ToString()
      Add-Type -AssemblyName System.Windows.Forms
      [void][System.Windows.Forms.MessageBox]::Show(
        (Protect-SensitiveText $_.Exception.Message),
        "Docker Codex API 切换器",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
      )
    }
  }
}
