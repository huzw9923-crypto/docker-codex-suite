$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class DockerCodexWindowInfo
{
    public IntPtr Handle { get; set; }
    public string Text { get; set; }
    public string ClassName { get; set; }
    public bool Enabled { get; set; }
    public bool Visible { get; set; }
    public int Left { get; set; }
    public int Top { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
}

public static class DockerCodexUiTestNative
{
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, string lParam);

    [DllImport("user32.dll", EntryPoint = "SendMessageW")]
    public static extern IntPtr SendMessageRaw(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageText(IntPtr window, uint message, IntPtr wParam, StringBuilder lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool SetWindowText(IntPtr window, string text);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsCallback callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern bool IsWindowEnabled(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr window, out Rect rect);

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static DockerCodexWindowInfo[] Enumerate(int processId)
    {
        List<DockerCodexWindowInfo> result = new List<DockerCodexWindowInfo>();
        EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            uint ownerProcessId;
            GetWindowThreadProcessId(window, out ownerProcessId);
            if (ownerProcessId != (uint)processId) return true;

            result.Add(ReadWindow(window));
            EnumChildWindows(window, delegate(IntPtr child, IntPtr childParameter)
            {
                result.Add(ReadWindow(child));
                return true;
            }, IntPtr.Zero);
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }

    private static DockerCodexWindowInfo ReadWindow(IntPtr window)
    {
        StringBuilder text = new StringBuilder(4096);
        StringBuilder className = new StringBuilder(256);
        GetWindowText(window, text, text.Capacity);
        int messageLength = (int)SendMessageRaw(window, 0x000E, IntPtr.Zero, IntPtr.Zero).ToInt64();
        if (messageLength > 0)
        {
            text = new StringBuilder(Math.Min(messageLength + 1, 16384));
            SendMessageText(window, 0x000D, new IntPtr(text.Capacity), text);
        }
        GetClassName(window, className, className.Capacity);
        Rect rect;
        GetWindowRect(window, out rect);
        return new DockerCodexWindowInfo
        {
            Handle = window,
            Text = text.ToString(),
            ClassName = className.ToString(),
            Enabled = IsWindowEnabled(window),
            Visible = IsWindowVisible(window),
            Left = rect.Left,
            Top = rect.Top,
            Width = rect.Right - rect.Left,
            Height = rect.Bottom - rect.Top
        };
    }
}
'@

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw "Assertion failed: $Message"
  }
}

function Get-ProcessElements {
  param([int]$ProcessId)

  return @([DockerCodexUiTestNative]::Enumerate($ProcessId))
}

function Find-Element {
  param(
    [int]$ProcessId,
    [string]$Name,
    [string]$ControlTypeName = ""
  )

  foreach ($element in @(Get-ProcessElements -ProcessId $ProcessId)) {
    if ($element.Text -ne $Name) {
      continue
    }
    if ($ControlTypeName -eq "ControlType.Window") {
      if (-not $element.ClassName.StartsWith("WindowsForms10.Window.", [System.StringComparison]::Ordinal)) {
        continue
      }
    }
    return $element
  }
  return $null
}

function Wait-Element {
  param(
    [int]$ProcessId,
    [string]$Name,
    [string]$ControlTypeName = "",
    [int]$TimeoutMs = 10000
  )

  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    $element = Find-Element -ProcessId $ProcessId -Name $Name -ControlTypeName $ControlTypeName
    if ($null -ne $element) {
      return $element
    }
    Start-Sleep -Milliseconds 100
  }
  $visibleText = Get-ProcessUiText -ProcessId $ProcessId
  if ($visibleText.Length -gt 1200) {
    $visibleText = $visibleText.Substring(0, 1200)
  }
  $matchingDetails = @()
  foreach ($candidate in @(Get-ProcessElements -ProcessId $ProcessId)) {
    if ($candidate.Text -eq $Name) {
      $matchingDetails += "class=$($candidate.ClassName),handle=$($candidate.Handle)"
    }
  }
  throw "Timed out waiting for UI element: $Name. Matches: $($matchingDetails -join '; '). Visible text: $visibleText"
}

function Get-ProcessUiText {
  param([int]$ProcessId)

  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($element in @(Get-ProcessElements -ProcessId $ProcessId)) {
    if (-not [string]::IsNullOrWhiteSpace($element.Text)) {
      $parts.Add($element.Text)
    }
  }
  return ($parts -join "`n")
}

function Wait-UiText {
  param(
    [int]$ProcessId,
    [string]$Expected,
    [int]$TimeoutMs = 15000
  )

  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    $text = Get-ProcessUiText -ProcessId $ProcessId
    if ($text.Contains($Expected)) {
      return
    }
    Start-Sleep -Milliseconds 120
  }
  $visibleText = Get-ProcessUiText -ProcessId $ProcessId
  if ($visibleText.Length -gt 1800) {
    $visibleText = $visibleText.Substring(0, 1800)
  }
  throw "Timed out waiting for UI text: $Expected. Visible text: $visibleText"
}

function Click-Element {
  param(
    $Element,
    [switch]$Async
  )

  $handle = [IntPtr]$Element.Handle
  if ($handle -eq [IntPtr]::Zero) {
    throw "UI element has no native handle."
  }
  if ($Async) {
    [void][DockerCodexUiTestNative]::PostMessage($handle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
  }
  else {
    [void][DockerCodexUiTestNative]::SendMessageRaw($handle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
  }
}

function Set-ElementValue {
  param($Element, [string]$Value)

  $handle = [IntPtr]$Element.Handle
  if ($handle -eq [IntPtr]::Zero) {
    throw "UI element has no writable value pattern or native handle."
  }
  if (-not [DockerCodexUiTestNative]::SetWindowText($handle, $Value)) {
    throw "SetWindowText failed for handle $($handle.ToInt64())."
  }
  [void][DockerCodexUiTestNative]::SendMessage($handle, 0x000C, [IntPtr]::Zero, $Value)
}

function Get-OrderedEdits {
  param([int]$ProcessId)

  $rows = @()
  foreach ($element in @(Get-ProcessElements -ProcessId $ProcessId)) {
    $isEditControl = $element.ClassName.StartsWith("WindowsForms10.EDIT.", [System.StringComparison]::OrdinalIgnoreCase)
    if ($isEditControl -and
        $element.Enabled -and
        $element.Visible) {
      $rows += [pscustomobject]@{ Element = $element; Top = $element.Top; Left = $element.Left; Width = $element.Width }
    }
  }
  return @($rows | Sort-Object Top, Left)
}

function Wait-OrderedEdits {
  param(
    [int]$ProcessId,
    [int]$MinimumCount = 2,
    [int]$TimeoutMs = 5000
  )

  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    $edits = @(Get-OrderedEdits -ProcessId $ProcessId)
    if ($edits.Count -ge $MinimumCount) {
      return $edits
    }
    Start-Sleep -Milliseconds 100
  }
  throw "Timed out waiting for profile editor fields."
}

function Get-FirstControlByClass {
  param(
    [int]$ProcessId,
    [string]$ClassPrefix
  )

  return @(Get-ProcessElements -ProcessId $ProcessId |
      Where-Object { $_.Visible -and $_.ClassName.StartsWith($ClassPrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
      Sort-Object Top, Left |
      Select-Object -First 1)[0]
}

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$controllerDir = Join-Path $root "src\controller"
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
$nodePath = if ($null -eq $nodeCommand) { "" } else { $nodeCommand.Source }
if ([string]::IsNullOrWhiteSpace($nodePath)) {
  $nodePath = "C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
}
Assert-True (Test-Path -LiteralPath $nodePath) "Node.js runtime is required"

$unicodeTag = [string]([char]0x4e2d) + [string]([char]0x6587)
$tempRoot = Join-Path (Join-Path $root "test-installs") ("docker-codex-ui-smoke " + $unicodeTag + " " + [guid]::NewGuid().ToString("N"))
$runtimeDir = Join-Path $tempRoot "runtime"
$dataDir = Join-Path $runtimeDir "data"
$composeDir = Join-Path $runtimeDir "compose"
$codexHome = Join-Path $composeDir "codex-home"
$hostDir = Join-Path $runtimeDir "host"
$codexPlusPlusSettingsPath = Join-Path $runtimeDir "codexplusplus-settings.json"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$mockProcess = $null
$switcherProcess = $null

try {
  New-Item -ItemType Directory -Path $runtimeDir, $dataDir, $codexHome, $hostDir -Force | Out-Null
  $switcherScriptPath = Join-Path $runtimeDir "docker-codex-api-switch.ps1"
  Copy-Item -LiteralPath (Join-Path $controllerDir "docker-codex-api-switch.ps1") -Destination $switcherScriptPath -Force
  Copy-Item -LiteralPath (Join-Path $controllerDir "docker-codex-provider-doctor.js") -Destination $runtimeDir -Force
  $smokeMutexName = "Local\DockerCodexSuite.ApiSwitcher.UiSmoke." + [guid]::NewGuid().ToString("N")
  $switcherScriptText = [System.IO.File]::ReadAllText($switcherScriptPath)
  $switcherScriptText = $switcherScriptText.Replace("Local\DockerCodexSuite.ApiSwitcher", $smokeMutexName)
  [System.IO.File]::WriteAllText($switcherScriptPath, $switcherScriptText, $utf8Bom)

  $baseConfig = @'
model_provider = "fixture"
model = "fixture-model"

[model_providers.fixture]
name = "fixture"
wire_api = "responses"
base_url = "https://example.invalid/v1"
env_key = "DOCKER_CODEX_API_KEY"
'@
  [System.IO.File]::WriteAllText((Join-Path $codexHome "config.toml"), $baseConfig, $utf8NoBom)
  [System.IO.File]::WriteAllText((Join-Path $hostDir "config.toml"), $baseConfig, $utf8NoBom)
  [System.IO.File]::WriteAllText((Join-Path $hostDir "auth.json"), "{}`r`n", $utf8NoBom)
  [System.IO.File]::WriteAllText((Join-Path $composeDir ".env"), "DOCKER_CODEX_API_KEY=fixture`r`n", $utf8NoBom)

  $codexPlusPlusFixture = [ordered]@{
    activeRelayId = "relay-ui-import"
    relayProfiles = @(
      [ordered]@{
        id              = "relay-ui-import"
        name            = "Codex++ UI Import"
        protocol        = "responses"
        relayMode       = "pureApi"
        upstreamBaseUrl = "https://import.example.test/v1"
        modelList       = "import-model-a`r`nimport-model-b"
        configContents  = "model = `"import-model-a`"`r`nbase_url = `"https://import.example.test/v1`"`r`n"
        authContents    = (@{ OPENAI_API_KEY = "fixture-import-key" } | ConvertTo-Json -Compress)
      }
    )
  }
  [System.IO.File]::WriteAllText(
    $codexPlusPlusSettingsPath,
    ($codexPlusPlusFixture | ConvertTo-Json -Depth 8),
    $utf8NoBom
  )

  $settings = [ordered]@{
    dataDir       = $dataDir
    composeDir    = $composeDir
    hostConfigPath = (Join-Path $hostDir "config.toml")
    hostAuthPath  = (Join-Path $hostDir "auth.json")
    profilesPath = (Join-Path $dataDir "api-profiles.json")
    statePath    = (Join-Path $dataDir "switch-state.json")
    codexPlusPlusSettingsPath = $codexPlusPlusSettingsPath
    chatProxyPort = 38119
    nodePath     = $nodePath
    containerName = "docker-codex-ui-smoke-missing"
    serviceName  = "docker-codex-ui-smoke-missing"
    apiEnvKey    = "DOCKER_CODEX_API_KEY"
  }
  [System.IO.File]::WriteAllText(
    (Join-Path $runtimeDir "settings.json"),
    ($settings | ConvertTo-Json -Compress),
    $utf8NoBom
  )

  $mockInfo = New-Object System.Diagnostics.ProcessStartInfo
  $mockInfo.FileName = $nodePath
  $mockInfo.Arguments = '"' + (Join-Path $root "tests\provider-doctor-mock-server.js") + '"'
  $mockInfo.WorkingDirectory = $root
  $mockInfo.UseShellExecute = $false
  $mockInfo.CreateNoWindow = $true
  $mockInfo.RedirectStandardOutput = $true
  $mockInfo.RedirectStandardError = $true
  $mockProcess = New-Object System.Diagnostics.Process
  $mockProcess.StartInfo = $mockInfo
  Assert-True ($mockProcess.Start()) "mock provider server failed to start"
  $mockLine = $mockProcess.StandardOutput.ReadLine()
  Assert-True ($mockLine -match '^MOCK_BASE_URL=(.+)$') "mock provider server did not report its URL"
  $mockBaseUrl = $Matches[1]

  $switcherInfo = New-Object System.Diagnostics.ProcessStartInfo
  $switcherInfo.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $switcherInfo.Arguments = '-NoProfile -Sta -ExecutionPolicy Bypass -File "' + (Join-Path $runtimeDir "docker-codex-api-switch.ps1") + '" -Action Gui'
  $switcherInfo.WorkingDirectory = $runtimeDir
  $switcherInfo.UseShellExecute = $false
  $switcherInfo.CreateNoWindow = $true
  $switcherInfo.RedirectStandardOutput = $true
  $switcherInfo.RedirectStandardError = $true
  $switcherProcess = New-Object System.Diagnostics.Process
  $switcherProcess.StartInfo = $switcherInfo
  $previousTheme = [Environment]::GetEnvironmentVariable("DOCKER_CODEX_THEME", "Process")
  try {
    [Environment]::SetEnvironmentVariable("DOCKER_CODEX_THEME", "light", "Process")
    Assert-True ($switcherProcess.Start()) "switcher failed to start"
  }
  finally {
    [Environment]::SetEnvironmentVariable("DOCKER_CODEX_THEME", $previousTheme, "Process")
  }
  $switcherProcessId = $switcherProcess.Id
  Start-Sleep -Milliseconds 500
  if ($switcherProcess.HasExited) {
    $switcherOutput = $switcherProcess.StandardOutput.ReadToEnd().Trim()
    $switcherError = $switcherProcess.StandardError.ReadToEnd().Trim()
    throw "switcher exited before creating its window (code $($switcherProcess.ExitCode)); stdout=$switcherOutput; stderr=$switcherError"
  }

  try {
    [void](Wait-Element -ProcessId $switcherProcessId -Name "Docker Codex API 切换器" -TimeoutMs 15000)
  }
  catch {
    if (-not $switcherProcess.HasExited) {
      $switcherProcess.Kill()
      $switcherProcess.WaitForExit()
    }
    $switcherOutput = $switcherProcess.StandardOutput.ReadToEnd().Trim()
    $switcherError = $switcherProcess.StandardError.ReadToEnd().Trim()
    throw "$($_.Exception.Message); stdout=$switcherOutput; stderr=$switcherError"
  }
  $newMainButton = Wait-Element -ProcessId $switcherProcessId -Name "新建"
  $editMainButton = Wait-Element -ProcessId $switcherProcessId -Name "编辑"
  $deleteMainButton = Wait-Element -ProcessId $switcherProcessId -Name "删除"
  $reloadMainButton = Wait-Element -ProcessId $switcherProcessId -Name "刷新"
  $codexPlusPlusMainButton = Wait-Element -ProcessId $switcherProcessId -Name "从 Codex++ 导入配置"
  $compactButtons = @($newMainButton, $editMainButton, $deleteMainButton, $reloadMainButton)
  Assert-True (@($compactButtons | Where-Object { $_.Width -ne $newMainButton.Width -or $_.Height -ne $newMainButton.Height }).Count -eq 0) "profile action buttons must have equal sizes"
  Assert-True (@($compactButtons | Where-Object { $_.Top -ne $newMainButton.Top }).Count -eq 0) "profile action buttons must stay on one aligned row"
  Assert-True ($codexPlusPlusMainButton.Left -eq $newMainButton.Left -and $codexPlusPlusMainButton.Top -gt $newMainButton.Top) "Codex++ import must occupy its own row"
  Assert-True ($codexPlusPlusMainButton.Width -gt $newMainButton.Width) "Codex++ import button must span the profile action row"
  $newButton = Wait-Element -ProcessId $switcherProcessId -Name "新建"
  Click-Element -Element $newButton -Async
  [void](Wait-Element -ProcessId $switcherProcessId -Name "新建 Docker API 配置")

  $edits = @(Wait-OrderedEdits -ProcessId $switcherProcessId)
  Start-Sleep -Milliseconds 350
  Set-ElementValue -Element $edits[0].Element -Value "UI Smoke Chat"
  Set-ElementValue -Element $edits[1].Element -Value $mockBaseUrl
  Start-Sleep -Milliseconds 200
  $updatedControls = @([DockerCodexUiTestNative]::Enumerate($switcherProcessId))
  $updatedName = $updatedControls | Where-Object { $_.Handle -eq $edits[0].Element.Handle } | Select-Object -First 1
  $updatedBaseUrl = $updatedControls | Where-Object { $_.Handle -eq $edits[1].Element.Handle } | Select-Object -First 1
  $editDetails = @($edits | ForEach-Object { "top=$($_.Top),text=$($_.Element.Text),handle=$($_.Element.Handle)" }) -join "; "
  Assert-True ($null -ne $updatedName -and $updatedName.Text -eq "UI Smoke Chat") "profile name field did not accept text; actual=$($updatedName.Text); edits=$editDetails"
  Assert-True ($null -ne $updatedBaseUrl -and $updatedBaseUrl.Text -eq $mockBaseUrl) "Base URL field did not accept text; actual=$($updatedBaseUrl.Text); expected=$mockBaseUrl; edits=$editDetails"

  $fetchButton = Wait-Element -ProcessId $switcherProcessId -Name "从上游获取模型"
  Click-Element -Element $fetchButton
  Wait-UiText -ProcessId $switcherProcessId -Expected "已载入 2 个模型" -TimeoutMs 20000

  $modelCombo = Get-FirstControlByClass -ProcessId $switcherProcessId -ClassPrefix "WindowsForms10.COMBOBOX."
  Assert-True ($null -ne $modelCombo) "default model combo box was not found"
  $selectedModelIndex = [DockerCodexUiTestNative]::SendMessage([IntPtr]$modelCombo.Handle, 0x014D, [IntPtr](-1), "model-a")
  Assert-True ($selectedModelIndex.ToInt64() -ge 0) "fetched model could not be selected"

  $testButton = Wait-Element -ProcessId $switcherProcessId -Name "测试所选模型"
  Click-Element -Element $testButton
  Wait-UiText -ProcessId $switcherProcessId -Expected "模型请求成功" -TimeoutMs 20000
  Wait-UiText -ProcessId $switcherProcessId -Expected "/v1/responses" -TimeoutMs 20000

  $chatButton = Wait-Element -ProcessId $switcherProcessId -Name "Chat Completions"
  Click-Element -Element $chatButton
  Wait-UiText -ProcessId $switcherProcessId -Expected "Chat 上游会由内置转换器" -TimeoutMs 5000
  Click-Element -Element $testButton
  Wait-UiText -ProcessId $switcherProcessId -Expected "/v1/chat/completions" -TimeoutMs 20000

  $saveButton = Wait-Element -ProcessId $switcherProcessId -Name "保存"
  Click-Element -Element $saveButton -Async
  Wait-UiText -ProcessId $switcherProcessId -Expected "已保存本地 API 配置" -TimeoutMs 10000
  $closeButton = Wait-Element -ProcessId $switcherProcessId -Name "关闭"
  Click-Element -Element $closeButton
  Wait-UiText -ProcessId $switcherProcessId -Expected "1 项" -TimeoutMs 10000

  $applyButton = Wait-Element -ProcessId $switcherProcessId -Name "应用所选配置"
  Assert-True ($applyButton.Enabled) "Chat profile apply action must be enabled when the built-in adapter is available"

  $profilesPath = Join-Path $dataDir "api-profiles.json"
  $parsedProfiles = Get-Content -LiteralPath $profilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $storedProfiles = @($parsedProfiles)
  Assert-True ($storedProfiles.Count -eq 1) "UI save must persist one profile"
  Assert-True ($storedProfiles[0].UpstreamProtocol -eq "chat") "UI protocol selection must persist Chat"
  Assert-True ($storedProfiles[0].Model -eq "model-a") "UI model selection must persist"
  Assert-True ($storedProfiles[0].ModelList -match 'model-b') "fetched model list must persist"

  $codexPlusPlusMainButton = Wait-Element -ProcessId $switcherProcessId -Name "从 Codex++ 导入配置"
  Click-Element -Element $codexPlusPlusMainButton -Async
  $confirmImportButton = Wait-Element -ProcessId $switcherProcessId -Name "导入所选" -TimeoutMs 10000
  Wait-UiText -ProcessId $switcherProcessId -Expected "一次性复制所选配置" -TimeoutMs 10000
  Click-Element -Element $confirmImportButton -Async
  Wait-UiText -ProcessId $switcherProcessId -Expected "导入完成" -TimeoutMs 10000
  $importCloseButton = Wait-Element -ProcessId $switcherProcessId -Name "关闭" -TimeoutMs 10000
  Click-Element -Element $importCloseButton
  Wait-UiText -ProcessId $switcherProcessId -Expected "2 项" -TimeoutMs 10000

  $parsedProfiles = Get-Content -LiteralPath $profilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $storedProfiles = @($parsedProfiles)
  $storedProfileNames = @($storedProfiles | ForEach-Object { [string]$_.Name }) -join "|"
  Assert-True ($storedProfiles.Count -eq 2) "Codex++ UI import must add one independent profile; count=$($storedProfiles.Count), names=$storedProfileNames"
  $importedProfile = $storedProfiles | Where-Object { $_.SourceProfileId -eq "relay-ui-import" } | Select-Object -First 1
  Assert-True ($null -ne $importedProfile) "Codex++ UI import must preserve its stable source id"
  Assert-True ($importedProfile.ImportedFrom -eq "codexplusplus") "Codex++ UI import must persist independent import metadata"

  $secondProcess = [System.Diagnostics.Process]::Start($switcherInfo)
  Assert-True ($secondProcess.WaitForExit(5000)) "second switcher process must activate the existing window and exit"
  Assert-True ($secondProcess.ExitCode -eq 0) "single-instance activation must exit successfully"
  $secondProcess.Dispose()

  $mainWindow = Wait-Element -ProcessId $switcherProcessId -Name "Docker Codex API 切换器"
  [void][DockerCodexUiTestNative]::PostMessage([IntPtr]$mainWindow.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
  Assert-True ($switcherProcess.WaitForExit(5000)) "switcher did not close after the smoke test"

  Write-Output "Provider manager UI smoke: PASS"
}
finally {
  if ($null -ne $switcherProcess) {
    try {
      if (-not $switcherProcess.HasExited) {
        $switcherProcess.Kill()
        $switcherProcess.WaitForExit()
      }
    }
    catch {
    }
    $switcherProcess.Dispose()
  }
  if ($null -ne $mockProcess) {
    try {
      if (-not $mockProcess.HasExited) {
        $mockProcess.Kill()
        $mockProcess.WaitForExit()
      }
    }
    catch {
    }
    $mockProcess.Dispose()
  }
  if (Test-Path -LiteralPath $tempRoot) {
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
    $resolvedTestRoot = [System.IO.Path]::GetFullPath((Join-Path $root "test-installs")).TrimEnd("\") + "\"
    if (-not $resolvedTemp.StartsWith($resolvedTestRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove test path outside the workspace test directory: $resolvedTemp"
    }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
