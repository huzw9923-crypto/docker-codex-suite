param(
  [Parameter(Mandatory = $true)]
  [string]$SetupPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class DockerCodexUninstallTestNative
{
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    public static IntPtr FindForProcess(int processId, string titlePart)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != (uint)processId) return true;

            StringBuilder title = new StringBuilder(512);
            GetWindowText(window, title, title.Capacity);
            if (title.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) >= 0)
            {
                found = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw "Assertion failed: $Message"
  }
}

$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root "test-installs"
$id = [Guid]::NewGuid().ToString("N")
$target = Join-Path $testRoot ("uninstall completion target " + $id)
$helperPath = Join-Path $testRoot ("uninstall completion helper " + $id + ".exe")
$process = $null

try {
  New-Item -ItemType Directory -Path $target -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $target "marker.txt"), "test")
  Copy-Item -LiteralPath $SetupPath -Destination $helperPath -Force

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $helperPath
  $startInfo.Arguments = '--uninstall-complete "' + $target + '"'
  $startInfo.WorkingDirectory = $testRoot
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  Assert-True ($process.Start()) "uninstall completion helper did not start"

  $deadline = (Get-Date).AddSeconds(25)
  $dialogClosed = $false
  while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
    $dialog = [DockerCodexUninstallTestNative]::FindForProcess($process.Id, "Docker Codex Suite")
    if ($dialog -ne [IntPtr]::Zero) {
      [void][DockerCodexUninstallTestNative]::PostMessage($dialog, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
      $dialogClosed = $true
      break
    }
    Start-Sleep -Milliseconds 100
  }

  Assert-True $dialogClosed "uninstall completion dialog was not shown"
  Assert-True ($process.WaitForExit(10000)) "uninstall completion helper did not exit"
  Assert-True ($process.ExitCode -eq 0) "uninstall completion helper exited with code $($process.ExitCode)"
  Assert-True (-not (Test-Path -LiteralPath $target)) "uninstall target directory still exists"
  Write-Output "Uninstall completion tests: PASS"
}
finally {
  if ($null -ne $process) {
    try {
      if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit()
      }
    }
    catch {
    }
    $process.Dispose()
  }
  if (Test-Path -LiteralPath $target) {
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $helperPath) {
    Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue
  }
}
