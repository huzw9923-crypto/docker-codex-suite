param(
  [string]$SourceRoot = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$sourceRoot = if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
  Split-Path -Parent $PSScriptRoot
}
else {
  [System.IO.Path]::GetFullPath($SourceRoot)
}
$controllerRoot = if (Test-Path -LiteralPath (Join-Path $sourceRoot "src\controller")) {
  Join-Path $sourceRoot "src\controller"
}
else {
  $sourceRoot
}
$protocolSource = Join-Path $controllerRoot "docker-codex-api-switch-protocol.ps1"
$switcherSource = Join-Path $controllerRoot "docker-codex-api-switch.ps1"
$unicodeTag = [string]([char]0x4e2d) + [string]([char]0x6587)
$testRoot = Join-Path (Join-Path $sourceRoot "test-installs") ("Docker Codex Suite " + $unicodeTag + " protocol path test " + [Guid]::NewGuid().ToString("N"))
$protocol = Join-Path $testRoot "docker-codex-api-switch-protocol.ps1"
$switcher = Join-Path $testRoot "docker-codex-api-switch.ps1"
$marker = Join-Path $testRoot "child-action.txt"

try {
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
  Copy-Item -LiteralPath $protocolSource -Destination $protocol -Force

  $fakeSwitcher = @'
param(
  [string]$Action = "Gui"
)
[System.IO.File]::WriteAllText(
  (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "child-action.txt"),
  $Action,
  (New-Object System.Text.UTF8Encoding($false))
)
'@
  [System.IO.File]::WriteAllText($switcher, $fakeSwitcher, (New-Object System.Text.UTF8Encoding($false)))

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = "powershell.exe"
  $startInfo.Arguments = '-NoProfile -Sta -ExecutionPolicy Bypass -File "' + $protocol + '" -Uri "docker-codex-switch://gui"'
  $startInfo.WorkingDirectory = $testRoot
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw "Unable to start protocol process."
  }
  $process.WaitForExit()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  if ($process.ExitCode -ne 0) {
    $protocolLog = Join-Path $testRoot "data\protocol.log"
    $details = if (Test-Path -LiteralPath $protocolLog) {
      Get-Content -LiteralPath $protocolLog -Raw
    }
    else {
      "protocol.log was not created"
    }
    throw "Protocol process exited with code $($process.ExitCode).`n$details`nSTDOUT:`n$stdout`nSTDERR:`n$stderr"
  }

  $deadline = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $marker)) {
    Start-Sleep -Milliseconds 100
  }
  if (-not (Test-Path -LiteralPath $marker)) {
    throw "GUI child process did not create its marker in a path containing spaces."
  }
  if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne "Gui") {
    throw "GUI child process received an unexpected action."
  }

  $guiSource = Get-Content -LiteralPath $switcherSource -Raw
  if ($guiSource -notmatch 'mutexName') {
    throw "GUI mutex is not scoped to the installation directory."
  }
  Write-Output "Protocol custom-path tests: PASS"
}
finally {
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
