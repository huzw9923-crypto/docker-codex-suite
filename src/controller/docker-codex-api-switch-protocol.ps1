param(
  [string]$Uri = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$Script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Script:Utf8NoBom
$global:OutputEncoding = $Script:Utf8NoBom

$Script:BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:SwitcherPath = Join-Path $Script:BaseDir "docker-codex-api-switch.ps1"
$Script:DataDir = Join-Path $Script:BaseDir "data"
$Script:LogPath = Join-Path $Script:DataDir "protocol.log"
$Script:PowerShellPath = Join-Path ([Environment]::GetFolderPath("System")) "WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $Script:PowerShellPath)) {
  $Script:PowerShellPath = "powershell.exe"
}

function Write-ProtocolLog {
  param([string]$Text)

  try {
    if (-not (Test-Path -LiteralPath $Script:DataDir)) {
      New-Item -ItemType Directory -Path $Script:DataDir -Force | Out-Null
    }
    $line = "{0} {1}" -f (Get-Date).ToString("s"), $Text
    Add-Content -LiteralPath $Script:LogPath -Value $line -Encoding UTF8
  }
  catch {
  }
}

function Show-Message {
  param(
    [string]$Text,
    [string]$Title = "Docker Codex API"
  )

  Add-Type -AssemblyName System.Windows.Forms
  $owner = New-Object System.Windows.Forms.Form
  $owner.TopMost = $true
  $owner.ShowInTaskbar = $false
  $owner.StartPosition = "CenterScreen"
  $owner.Width = 1
  $owner.Height = 1
  $owner.Opacity = 0

  try {
    [void]$owner.Show()
    [void]$owner.Activate()
    [void][System.Windows.Forms.MessageBox]::Show($owner, $Text, $Title)
  }
  finally {
    $owner.Dispose()
  }
}

function Get-QueryMap {
  param([string]$Query)

  $map = @{}
  if ([string]::IsNullOrWhiteSpace($Query)) {
    return $map
  }

  $raw = $Query.TrimStart("?")
  foreach ($pair in ($raw -split "&")) {
    if ([string]::IsNullOrWhiteSpace($pair)) {
      continue
    }

    $parts = $pair -split "=", 2
    $key = [System.Uri]::UnescapeDataString($parts[0])
    $value = if ($parts.Count -gt 1) { [System.Uri]::UnescapeDataString($parts[1]) } else { "" }
    $map[$key] = $value
  }

  return $map
}

function Start-SwitcherProcess {
  param([string]$Action)

  # Use ProcessStartInfo instead of Start-Process. The latter rebuilds the
  # environment into a case-insensitive dictionary and can fail when a host
  # exposes both Path and PATH. Keep the script path quoted because the suite
  # supports custom install directories containing spaces or non-ASCII text.
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $Script:PowerShellPath
  $startInfo.Arguments = '-NoProfile -NoLogo -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $Script:SwitcherPath + '" -Action "' + $Action + '"'
  $startInfo.WorkingDirectory = $Script:BaseDir
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    $process.Dispose()
    throw "Unable to start the API switcher process."
  }
  try {
    Write-ProtocolLog ("Started {0} child process PID={1}" -f $Action, $process.Id)
    Start-Sleep -Milliseconds 120
    $process.Refresh()
    if ($process.HasExited) {
      Write-ProtocolLog ("Child process PID={0} exited immediately with code={1}" -f $process.Id, $process.ExitCode)
      if ($process.ExitCode -ne 0) {
        throw "API switcher process exited immediately with code $($process.ExitCode). See $Script:LogPath"
      }
    }
  }
  finally {
    $process.Dispose()
  }
}

function Resolve-Invocation {
  param([string]$RawUri)

  $result = [ordered]@{
    Action = "Gui"
    SkipRecreate = $false
  }

  if ([string]::IsNullOrWhiteSpace($RawUri)) {
    return $result
  }

  try {
    $parsed = [System.Uri]$RawUri
  }
  catch {
    return $result
  }

  $token = ""
  if (-not [string]::IsNullOrWhiteSpace($parsed.Host)) {
    $token = $parsed.Host
  }
  else {
    $token = $parsed.AbsolutePath.Trim("/")
  }

  switch ($token.ToLowerInvariant()) {
    "gui" { $result.Action = "Gui" }
    "open" { $result.Action = "Gui" }
    "use-host" { $result.Action = "UseHost" }
    "host" { $result.Action = "UseHost" }
    "use-docker" { $result.Action = "UseDocker" }
    "docker" { $result.Action = "UseDocker" }
    "reconnect" { $result.Action = "Reconnect" }
    "status" { $result.Action = "Status" }
    "capture-docker" { $result.Action = "CaptureDocker" }
  }

  $query = Get-QueryMap $parsed.Query
  if ($query.Contains("skipRecreate")) {
    $result.SkipRecreate = $query["skipRecreate"] -in @("1", "true", "yes")
  }

  return $result
}

if (-not (Test-Path -LiteralPath $Script:SwitcherPath)) {
  Show-Message "Missing switcher script: $Script:SwitcherPath"
  exit 1
}

$invocation = Resolve-Invocation -RawUri $Uri
Write-ProtocolLog ("Uri={0} Action={1} SkipRecreate={2}" -f $Uri, $invocation.Action, $invocation.SkipRecreate)

try {
  if ($invocation.Action -eq "Gui") {
    Start-SwitcherProcess -Action Gui
    Write-ProtocolLog "Started Gui child process"
    exit 0
  }

  if ($invocation.Action -eq "Status") {
    Start-SwitcherProcess -Action StatusGui
    Write-ProtocolLog "Started StatusGui child process"
    exit 0
  }

  $params = @{
    Action = $invocation.Action
  }
  if ($invocation.SkipRecreate) {
    $params["SkipRecreate"] = $true
  }

  $output = & $Script:SwitcherPath @params 2>&1 | Out-String
  $text = $output.Trim()
  if ([string]::IsNullOrWhiteSpace($text)) {
    $text = "Action completed: $($invocation.Action)"
  }
  Show-Message $text
}
catch {
  Show-Message $_.Exception.Message
  exit 1
}
