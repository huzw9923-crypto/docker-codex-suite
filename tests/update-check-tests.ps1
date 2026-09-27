$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True {
  param([bool]$Condition, [string]$Label)
  if (-not $Condition) {
    throw "Assertion failed: $Label"
  }
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Node = $env:UPDATE_TEST_NODE
if ([string]::IsNullOrWhiteSpace($Node) -or -not (Test-Path -LiteralPath $Node)) {
  $Node = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
}
if (-not (Test-Path -LiteralPath $Node)) {
  $command = Get-Command "node.exe" -ErrorAction SilentlyContinue
  if ($null -ne $command) {
    $Node = $command.Source
  }
  else {
    throw "Node.js was not found for update api mock server."
  }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("DockerCodexSuite-update-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$mockProcess = $null
$mockPort = ""
try {
  $portFile = Join-Path $work "mock-port.txt"
  $mockScript = Join-Path $Root "update-api-mock-server.js"
  $env:MOCK_SUITE_TAG = "v1.9.9"
  $env:MOCK_CODEX_TAG = "rust-v0.151.0"
  $env:MOCK_PORT_FILE = $portFile
  $mockProcess = Start-Process -FilePath $Node -ArgumentList ('"' + $mockScript + '"') -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $work "mock-out.txt") -RedirectStandardError (Join-Path $work "mock-err.txt")
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $portFile) {
      $mockPort = (Get-Content -LiteralPath $portFile -Raw).Trim()
      if ($mockPort.Length -gt 0) {
        break
      }
    }
    Start-Sleep -Milliseconds 200
  }
  Assert-True ($mockPort.Length -gt 0) "mock server reported its port"

  $fixture = Join-Path $work "docker-codex-update.ps1"
  Copy-Item (Join-Path $Root "..\src\controller\docker-codex-update.ps1") $fixture
  $settings = @{
    version       = "1.0.0"
    containerName = "codex-dev-d"
  }
  $settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $work "settings.json") -Encoding UTF8

  $env:UPDATE_SUITE_API_BASE = "http://127.0.0.1:$mockPort/suite/latest"
  $env:UPDATE_CODEX_API_BASE = "http://127.0.0.1:$mockPort/codex/latest"
  $env:UPDATE_FAKE_CLI_VERSION = "0.150.0"
  $env:UPDATE_DOWNLOAD_BASE = "http://127.0.0.1:$mockPort/download"

  . $fixture

  # 纯函数版本比较
  Assert-True ((Compare-Version -A "1.2.0" -B "1.2.0") -eq 0) "equal versions compare equal"
  Assert-True ((Compare-Version -A "v1.2.0" -B "1.2.0") -eq 0) "v-prefix stripped on A"
  Assert-True ((Compare-Version -A "rust-v0.53.0" -B "0.53.0") -eq 0) "rust-v prefix stripped on A"
  Assert-True ((Compare-Version -A "1.10.0" -B "1.9.9") -gt 0) "numeric segments compared as integers"
  Assert-True ((Compare-Version -A "1.2.0" -B "1.2.1") -lt 0) "patch segment ordering"

  # Suite Release 解析
  $suiteInfo = Get-SuiteReleaseInfo
  Assert-True ($suiteInfo.Version -eq "1.9.9") "suite latest version parsed from tag"
  Assert-True ($suiteInfo.DownloadUrl -like "*/download/setup.exe") "suite download url from assets"

  # CLI 最新版本解析
  $cliLatest = Get-CodexCliLatestVersion
  Assert-True ($cliLatest -eq "0.151.0") "codex cli latest stripped rust-v prefix"

  # 本地/容器版本
  $suiteCurrent = Get-SuiteCurrentVersion
  Assert-True ($suiteCurrent -eq "1.0.0") "suite current version from settings.json"
  $cliCurrent = Get-ContainerCodexVersion -ContainerName "codex-dev-d"
  Assert-True ($cliCurrent -eq "0.150.0") "container codex version from fake injection"

  # 汇总状态
  $status = Get-CheckUpdateStatus
  Assert-True ($status.SuiteUpdateAvailable) "suite update flagged when newer release exists"
  Assert-True ($status.CliUpdateAvailable) "cli update flagged when newer release exists"

  # 已最新分支
  $content = Get-Content -LiteralPath (Join-Path $work "settings.json") -Raw -Encoding UTF8
  $content -replace '"1\.0\.0"', '"9.9.9"' | Set-Content -LiteralPath (Join-Path $work "settings.json") -Encoding UTF8
  $statusCurrent = Get-CheckUpdateStatus
  Assert-True (-not $statusCurrent.SuiteUpdateAvailable) "suite already newest is not flagged"

  Write-Output "Update check tests: PASS"
}
finally {
  Remove-Item Env:\UPDATE_SUITE_API_BASE -ErrorAction SilentlyContinue
  Remove-Item Env:\UPDATE_CODEX_API_BASE -ErrorAction SilentlyContinue
  Remove-Item Env:\UPDATE_FAKE_CLI_VERSION -ErrorAction SilentlyContinue
  Remove-Item Env:\UPDATE_DOWNLOAD_BASE -ErrorAction SilentlyContinue
  Remove-Item Env:\MOCK_SUITE_TAG -ErrorAction SilentlyContinue
  Remove-Item Env:\MOCK_CODEX_TAG -ErrorAction SilentlyContinue
  Remove-Item Env:\MOCK_PORT_FILE -ErrorAction SilentlyContinue
  if ($null -ne $mockProcess -and -not $mockProcess.HasExited) {
    Stop-Process -Id $mockProcess.Id -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}