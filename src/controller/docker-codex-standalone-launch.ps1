param(
  [ValidateSet("Launch", "BridgeOnly", "RestartBridge", "StopBridge", "Status", "ActivationCheck")]
  [string]$Action = "Launch",
  [switch]$AllowSuiteMigration
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$Script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Script:Utf8NoBom
$global:OutputEncoding = $Script:Utf8NoBom

$Script:BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:SettingsPath = Join-Path $Script:BaseDir "settings.json"
$Script:LauncherLogPath = Join-Path $Script:BaseDir "data\launcher.log"
$Script:Settings = [pscustomobject]@{}
if (Test-Path -LiteralPath $Script:SettingsPath) {
  try {
    $loadedSettings = Get-Content -LiteralPath $Script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $loadedSettings) {
      $Script:Settings = $loadedSettings
    }
  }
  catch {
    try {
      $fallbackLog = Join-Path ([System.IO.Path]::GetTempPath()) "DockerCodexSuite-startup.log"
      Add-Content -LiteralPath $fallbackLog -Value ("{0} [bridge-startup] settings.json: {1}" -f (Get-Date).ToString("s"), $_.Exception.Message) -Encoding UTF8
    }
    catch {
    }
  }
}

function Write-LauncherLog {
  param([string]$Message)
  try {
    $directory = Split-Path -Parent $Script:LauncherLogPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Add-Content -LiteralPath $Script:LauncherLogPath -Value (
      "{0} {1}" -f (Get-Date).ToString("s"), $Message) -Encoding UTF8
  }
  catch {
  }
}

function Get-SuiteSetting {
  param([string]$Name, $Fallback)
  $property = $Script:Settings.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return $Fallback
  }
  return $property.Value
}

function Resolve-SuitePath {
  param([string]$Value, [string]$Fallback)
  $candidate = if ([string]::IsNullOrWhiteSpace($Value)) { $Fallback } else { $Value }
  $candidate = [Environment]::ExpandEnvironmentVariables($candidate)
  if (-not [System.IO.Path]::IsPathRooted($candidate)) {
    $candidate = Join-Path $Script:BaseDir $candidate
  }
  try {
    return [System.IO.Path]::GetFullPath($candidate)
  }
  catch {
    return [System.IO.Path]::GetFullPath($Fallback)
  }
}

$Script:BridgePath = Join-Path $Script:BaseDir "docker-codex-standalone-bridge.js"
$Script:NodePath = Resolve-SuitePath ([string](Get-SuiteSetting "nodePath" "runtime\node.exe")) (Join-Path $Script:BaseDir "runtime\node.exe")
$Script:DebugPort = [int](Get-SuiteSetting "debugPort" 9229)
$Script:BridgePort = [int](Get-SuiteSetting "bridgePort" 38118)
$Script:CodexAppUserModelId = [string](Get-SuiteSetting "codexAppUserModelId" "OpenAI.Codex_2p2nqsd0c76g0!App")

function Get-NodeExecutable {
  $candidates = @(
    $Script:NodePath,
    (Join-Path ([Environment]::GetFolderPath("UserProfile")) ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"),
    "C:\Program Files\nodejs\node.exe"
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($null -ne $command) {
    return $command.Source
  }
  throw "Node.js was not found; the standalone bridge cannot start."
}

function Start-HiddenProcess {
  param(
    [string]$FilePath,
    [string]$Arguments = "",
    [string]$WorkingDirectory = $Script:BaseDir
  )

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = $Arguments
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    $process.Dispose()
    throw "Unable to start process: $FilePath"
  }
  return $process
}

function Test-TcpPort {
  param([int]$Port, [int]$TimeoutMs = 400)
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $result = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
    if (-not $result.AsyncWaitHandle.WaitOne($TimeoutMs)) {
      return $false
    }
    $client.EndConnect($result)
    return $true
  }
  catch {
    return $false
  }
  finally {
    $client.Close()
  }
}

function Get-BridgeHealth {
  try {
    return Invoke-RestMethod -Uri "http://127.0.0.1:$($Script:BridgePort)/health" -TimeoutSec 2
  }
  catch {
    return $null
  }
}

function Normalize-InstallDirectory {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ""
  }
  try {
    return [System.IO.Path]::GetFullPath($Value).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
  }
  catch {
    return ""
  }
}

function Test-SameInstallDirectory {
  param([string]$Left, [string]$Right)
  $normalizedLeft = Normalize-InstallDirectory $Left
  $normalizedRight = Normalize-InstallDirectory $Right
  return $normalizedLeft.Length -gt 0 -and $normalizedRight.Length -gt 0 `
    -and [string]::Equals($normalizedLeft, $normalizedRight, [StringComparison]::OrdinalIgnoreCase)
}

function Start-StandaloneBridge {
  $health = Get-BridgeHealth
  if ($null -ne $health -and $health.service -eq "docker-codex-standalone") {
    if (Test-SameInstallDirectory ([string]$health.installDir) $Script:BaseDir) {
      return $health
    }
    throw "Port $($Script:BridgePort) is occupied by another Docker Codex Suite installation: $($health.installDir)"
  }
  if (-not (Test-Path -LiteralPath $Script:BridgePath)) {
    throw "Standalone bridge file is missing: $($Script:BridgePath)"
  }

  $node = Get-NodeExecutable
  $bridgeProcess = Start-HiddenProcess `
    -FilePath $node `
    -Arguments ('"' + $Script:BridgePath + '"') `
    -WorkingDirectory $Script:BaseDir
  $bridgeProcess.Dispose()

  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    $health = Get-BridgeHealth
    if ($null -ne $health -and $health.service -eq "docker-codex-standalone" `
      -and (Test-SameInstallDirectory ([string]$health.installDir) $Script:BaseDir)) {
      return $health
    }
  }
  throw "The standalone bridge did not start within 10 seconds."
}

function Stop-StandaloneBridge {
  $health = Get-BridgeHealth
  if ($null -eq $health) {
    return
  }
  if ($health.service -ne "docker-codex-standalone") {
    throw "Port $($Script:BridgePort) is occupied by another service."
  }
  $sameInstall = Test-SameInstallDirectory ([string]$health.installDir) $Script:BaseDir
  if (-not $sameInstall -and -not $AllowSuiteMigration) {
    throw "The running Docker Codex bridge belongs to another installation: $($health.installDir)"
  }

  $bridgePid = [int]$health.pid
  if (-not $sameInstall) {
    $foreignInstallDir = Normalize-InstallDirectory ([string]$health.installDir)
    $foreignLauncher = if ($foreignInstallDir.Length -gt 0) {
      Join-Path $foreignInstallDir "DockerCodex.exe"
    }
    else {
      ""
    }
    if (-not [string]::IsNullOrWhiteSpace($foreignLauncher) -and (Test-Path -LiteralPath $foreignLauncher)) {
      try {
        $stopProcess = Start-HiddenProcess `
          -FilePath $foreignLauncher `
          -Arguments "--bridge-stop" `
          -WorkingDirectory $foreignInstallDir
        [void]$stopProcess.WaitForExit(10000)
        $stopProcess.Dispose()
      }
      catch {
      }
      if (-not (Test-TcpPort -Port $Script:BridgePort)) {
        return
      }
    }
    $foreignProcess = Get-Process -Id $bridgePid -ErrorAction SilentlyContinue
    if ($null -eq $foreignProcess -or $foreignProcess.ProcessName -notin @("node", "nodejs")) {
      throw "Refusing to stop an unverified process while changing the Docker Codex installation directory."
    }
  }
  if ($bridgePid -gt 0) {
    Stop-Process -Id $bridgePid -Force -ErrorAction SilentlyContinue
  }
  $deadline = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $deadline -and (Test-TcpPort -Port $Script:BridgePort)) {
    Start-Sleep -Milliseconds 150
  }
  if (Test-TcpPort -Port $Script:BridgePort) {
    throw "The previous Docker Codex bridge did not stop."
  }
}

function Ensure-ActivationType {
  if ($null -ne ("DockerCodex.ApplicationActivator" -as [type])) {
    return
  }

  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace DockerCodex
{
    [Flags]
    public enum ActivateOptions
    {
        None = 0x00000000
    }

    [ComImport]
    [Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    internal class ApplicationActivationManager
    {
    }

    [ComImport]
    [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IApplicationActivationManager
    {
        [PreserveSig]
        int ActivateApplication(
            [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments,
            ActivateOptions options,
            out uint processId);
    }

    public static class ApplicationActivator
    {
        public static uint Activate(string appUserModelId, string arguments)
        {
            var manager = (IApplicationActivationManager)new ApplicationActivationManager();
            uint processId;
            int result = manager.ActivateApplication(
                appUserModelId,
                arguments,
                ActivateOptions.None,
                out processId);
            Marshal.ThrowExceptionForHR(result);
            return processId;
        }
    }
}
'@
}

function Activate-CodexDesktop {
  Ensure-ActivationType
  return [DockerCodex.ApplicationActivator]::Activate($Script:CodexAppUserModelId, "")
}

function Show-LaunchError {
  param([string]$Message)
  Add-Type -AssemblyName System.Windows.Forms
  [void][System.Windows.Forms.MessageBox]::Show(
    $Message,
    "Docker Codex Standalone Launcher",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Warning
  )
}

function Wait-StandaloneReady {
  param([int]$TimeoutSeconds = 60)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $health = Get-BridgeHealth
    if ($null -ne $health -and $health.cdp -eq "connected" -and $health.menu -in @("installed", "ready")) {
      return $health
    }
    Start-Sleep -Milliseconds 500
  }
  return Get-BridgeHealth
}

if ($Action -eq "Status") {
  $health = Get-BridgeHealth
  if ($null -eq $health) {
    Write-Output '{"status":"stopped"}'
  }
  else {
    $health | ConvertTo-Json -Depth 4
  }
  exit 0
}

if ($Action -eq "ActivationCheck") {
  Ensure-ActivationType
  Write-Output "ACTIVATION_TYPE_OK"
  exit 0
}

if ($Action -eq "BridgeOnly") {
  Start-StandaloneBridge | ConvertTo-Json -Depth 4
  exit 0
}

if ($Action -eq "RestartBridge") {
  Stop-StandaloneBridge
  Start-StandaloneBridge | ConvertTo-Json -Depth 4
  exit 0
}

if ($Action -eq "StopBridge") {
  Stop-StandaloneBridge
  exit 0
}

try {
  Start-StandaloneBridge | Out-Null

  Write-LauncherLog "Launch requested."
  $debugChannelAvailable = Test-TcpPort -Port $Script:DebugPort
  if (-not $debugChannelAvailable) {
    $runningCodex = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)
    if ($runningCodex.Count -gt 0) {
      throw "Codex is already running without the standalone debug channel. Exit all Codex windows, then launch Docker Codex Standalone."
    }

    Ensure-ActivationType
    $arguments = "--remote-debugging-port=$($Script:DebugPort) --remote-allow-origins=http://127.0.0.1:$($Script:DebugPort)"
    $activatedPid = [DockerCodex.ApplicationActivator]::Activate($Script:CodexAppUserModelId, $arguments)
    Write-LauncherLog ("Codex activation requested with debug arguments; pid=" + $activatedPid)
  }
  else {
    Write-LauncherLog "Existing Codex debug channel detected; activating the existing Codex window."
    $activatedPid = Activate-CodexDesktop
    Write-LauncherLog ("Existing Codex activation requested; pid=" + $activatedPid)
  }

  $health = Wait-StandaloneReady
  if ($null -eq $health -or $health.cdp -ne "connected" -or $health.menu -notin @("installed", "ready")) {
    $detail = if ($null -eq $health) { "bridge unavailable" } else { [string]$health.lastError }
    throw "Codex started, but Docker API menu injection failed: $detail"
  }
  Write-LauncherLog "Launch completed; Codex and the Docker API menu are ready."
}
catch {
  Write-LauncherLog ("Launch failed: " + $_.Exception.Message)
  Show-LaunchError -Message $_.Exception.Message
  exit 1
}
