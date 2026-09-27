param(
  [ValidateSet("Check", "UpdateSuite", "UpdateCli")]
  [string]$Action = "Check"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$Script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Script:Utf8NoBom
$global:OutputEncoding = $Script:Utf8NoBom

$Script:UpdateDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:SettingsPath = Join-Path $Script:UpdateDir "settings.json"

$Script:SuiteApiDefault = "https://api.github.com/repos/huzw9923-crypto/docker-codex-suite/releases/latest"
$Script:CodexApiDefault = "https://api.github.com/repos/openai/codex/releases/latest"

function Get-UpdateSetting {
  param([string]$Name, $Fallback)
  if (-not (Test-Path -LiteralPath $Script:SettingsPath)) {
    return $Fallback
  }
  try {
    $settings = Get-Content -LiteralPath $Script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $property = $settings.PSObject.Properties[$Name]
    if ($null -ne $property -and $null -ne $property.Value) {
      return $property.Value
    }
  }
  catch {
  }
  return $Fallback
}

function Compare-Version {
  param([string]$A, [string]$B)

  $normalizedA = ("" + $A).Trim()
  $normalizedB = ("" + $B).Trim()
  if ($normalizedA.StartsWith("rust-", [StringComparison]::OrdinalIgnoreCase)) {
    $normalizedA = $normalizedA.Substring(5)
  }
  if ($normalizedB.StartsWith("rust-", [StringComparison]::OrdinalIgnoreCase)) {
    $normalizedB = $normalizedB.Substring(5)
  }
  if ($normalizedA.StartsWith("v", [StringComparison]::OrdinalIgnoreCase)) {
    $normalizedA = $normalizedA.Substring(1)
  }
  if ($normalizedB.StartsWith("v", [StringComparison]::OrdinalIgnoreCase)) {
    $normalizedB = $normalizedB.Substring(1)
  }

  $segmentsA = @($normalizedA.Split('.'))
  $segmentsB = @($normalizedB.Split('.'))
  $count = [Math]::Max($segmentsA.Count, $segmentsB.Count)
  for ($index = 0; $index -lt 3; $index += 1) {
    if ($index -ge $count) {
      break
    }
    $valueA = 0
    $valueB = 0
    if ($index -lt $segmentsA.Count) {
      [int]::TryParse(("" + $segmentsA[$index]).Trim(), [ref]$valueA) | Out-Null
    }
    if ($index -lt $segmentsB.Count) {
      [int]::TryParse(("" + $segmentsB[$index]).Trim(), [ref]$valueB) | Out-Null
    }
    if ($valueA -gt $valueB) {
      return 1
    }
    if ($valueA -lt $valueB) {
      return -1
    }
  }
  return 0
}

function Get-SuiteCurrentVersion {
  $version = [string](Get-UpdateSetting "version" "")
  if ([string]::IsNullOrWhiteSpace($version)) {
    $version = [string](Get-UpdateSetting "suiteVersion" "")
  }
  return $version
}

function Get-UpdateJson {
  param([string]$Url, [string]$Label)

  $headers = @{
    "User-Agent" = "DockerCodexSuite"
    "Accept"     = "application/vnd.github+json"
  }
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -Headers $headers -TimeoutSec 20
    return ConvertFrom-Json $response.Content
  }
  catch {
    throw "$Label 检查失败：$($_.Exception.Message)"
  }
}

function Get-SuiteReleaseInfo {
  $base = $env:UPDATE_SUITE_API_BASE
  if ([string]::IsNullOrWhiteSpace($base)) {
    $base = $Script:SuiteApiDefault
  }
  $json = Get-UpdateJson -Url $base -Label "Suite 更新"

  $tag = [string]$json.tag_name
  $downloadUrl = ""
  foreach ($asset in @($json.assets)) {
    $name = [string]$asset.name
    if ($name -like "DockerCodexSuite-Setup-*-win-x64.exe") {
      $downloadUrl = [string]$asset.browser_download_url
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($tag)) {
    throw "Suite 更新：无法解析 GitHub Release 的版本标签。"
  }

  [pscustomobject]@{
    Tag         = $tag
    Version     = $tag.TrimStart("v")
    DownloadUrl = $downloadUrl
  }
}

function Get-CodexCliLatestVersion {
  $base = $env:UPDATE_CODEX_API_BASE
  if ([string]::IsNullOrWhiteSpace($base)) {
    $base = $Script:CodexApiDefault
  }
  $json = Get-UpdateJson -Url $base -Label "Codex CLI 更新"

  $tag = [string]$json.tag_name
  if ([string]::IsNullOrWhiteSpace($tag)) {
    throw "Codex CLI 更新：无法解析官方 Release 的版本标签。"
  }
  if ($tag.StartsWith("rust-", [StringComparison]::OrdinalIgnoreCase)) {
    $tag = $tag.Substring(5)
  }
  return $tag.TrimStart("v")
}

function Get-ContainerCodexVersion {
  param([string]$ContainerName)

  $fakeVersion = $env:UPDATE_FAKE_CLI_VERSION
  if (-not [string]::IsNullOrWhiteSpace($fakeVersion)) {
    return $fakeVersion.Trim().TrimStart("v")
  }

  if ([string]::IsNullOrWhiteSpace($ContainerName)) {
    $ContainerName = [string](Get-UpdateSetting "containerName" "")
  }
  if ([string]::IsNullOrWhiteSpace($ContainerName)) {
    throw "无法确定 Docker Codex 容器名，请先完成安装检测。"
  }

  $output = & docker exec -u codex $ContainerName sh -lc "codex --version" 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
    throw "无法读取容器内 Codex CLI 版本。"
  }
  $match = [regex]::Match(("" + $output), 'v?(\d+\.\d+\.\d+)')
  if (-not $match.Success) {
    throw "无法解析容器内 Codex CLI 版本输出：$output"
  }
  return $match.Groups[1].Value
}

function Get-CheckUpdateStatus {
  $suiteInfo = Get-SuiteReleaseInfo
  $suiteCurrent = Get-SuiteCurrentVersion
  $suiteUpdateAvailable = $false
  if (-not [string]::IsNullOrWhiteSpace($suiteCurrent)) {
    $suiteUpdateAvailable = (Compare-Version -A $suiteInfo.Version -B $suiteCurrent) -gt 0
  }

  $cliLatest = Get-CodexCliLatestVersion
  $cliCurrent = Get-ContainerCodexVersion
  $cliUpdateAvailable = (Compare-Version -A $cliLatest -B $cliCurrent) -gt 0

  [pscustomobject]@{
    SuiteCurrent        = $suiteCurrent
    SuiteLatest         = $suiteInfo.Version
    SuiteUpdateAvailable = $suiteUpdateAvailable
    SuiteDownloadUrl    = $suiteInfo.DownloadUrl
    CliCurrent          = $cliCurrent
    CliLatest           = $cliLatest
    CliUpdateAvailable  = $cliUpdateAvailable
  }
}

function Update-Suite {
  $suiteInfo = Get-SuiteReleaseInfo
  if ([string]::IsNullOrWhiteSpace($suiteInfo.DownloadUrl)) {
    throw "没有找到可下载的安装包资产。"
  }
  $targetPath = Join-Path $env:TEMP ("DockerCodexSuite-Setup-" + $suiteInfo.Version + "-win-x64.exe")

  Write-Host "正在下载 $($suiteInfo.Version) 安装包..."
  $headers = @{
    "User-Agent" = "DockerCodexSuite"
    "Accept"     = "application/octet-stream"
  }
  $downloadUrl = $suiteInfo.DownloadUrl
  $overrideBase = $env:UPDATE_DOWNLOAD_BASE
  if (-not [string]::IsNullOrWhiteSpace($overrideBase)) {
    $fileName = Split-Path -Leaf $suiteInfo.DownloadUrl
    $downloadUrl = $overrideBase.TrimEnd("/") + "/" + $fileName
  }
  try {
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -Headers $headers -OutFile $targetPath -TimeoutSec 300
  }
  catch {
    throw "下载安装包失败：$($_.Exception.Message)"
  }
  if (-not (Test-Path -LiteralPath $targetPath) -or (Get-Item -LiteralPath $targetPath).Length -le 0) {
    throw "下载的安装包为空或缺失。"
  }

  Write-Host "请求管理员权限执行静默升级..."
  $process = Start-Process -FilePath $targetPath -ArgumentList "--silent" -Verb RunAs -Wait -PassThru
  if ($null -eq $process -or $process.ExitCode -ne 0) {
    throw "安装器退出码异常（$($process.ExitCode)）。"
  }
  Write-Host "升级完成。请重新打开 Docker Codex Suite 切换器与菜单。"
}

function Update-CodexCli {
  param([string]$ContainerName)

  if ([string]::IsNullOrWhiteSpace($ContainerName)) {
    $ContainerName = [string](Get-UpdateSetting "containerName" "")
  }
  if ([string]::IsNullOrWhiteSpace($ContainerName)) {
    throw "无法确定 Docker Codex 容器名，请先完成安装检测。"
  }

  $previous = Get-ContainerCodexVersion -ContainerName $ContainerName
  $latest = Get-CodexCliLatestVersion
  if ((Compare-Version -A $latest -B $previous) -le 0) {
    Write-Host "容器内 Codex CLI 已是最新（$previous）。"
    return
  }

  Write-Host "正在更新容器内 Codex CLI：$previous -> $latest（可能需要几分钟）..."
  $installCommand = @(
    "curl -fsSL https://chatgpt.com/codex/install.sh |",
    "CODEX_HOME=/home/codex/.codex CODEX_NON_INTERACTIVE=1 CODEX_INSTALL_DIR=/home/codex/.local/bin sh"
  ) -join " "

  $updateJob = Start-Job -ScriptBlock {
    param([string]$C, [string]$K)
    $result = & docker exec -u codex $C sh -lc $K 2>&1
    $result | ForEach-Object { Write-Output $_ }
    Write-Output ("__DOCKER_CODEX_UPDATE_EXIT__=" + $LASTEXITCODE)
  } -ArgumentList $ContainerName, $installCommand

  $null = Wait-Job -Job $updateJob -Timeout 300
  if ($updateJob.State -ne "Completed") {
    Stop-Job -Job $updateJob -ErrorAction SilentlyContinue
    Remove-Job -Job $updateJob -Force -ErrorAction SilentlyContinue
    throw "Codex CLI 更新超时（5 分钟）。请检查容器网络后重试。"
  }
  $jobOutput = Receive-Job -Job $updateJob | Out-String
  $jobExitCode = 0
  $exitMatch = [regex]::Match($jobOutput, '__DOCKER_CODEX_UPDATE_EXIT__=(\d+)')
  if ($exitMatch.Success) {
    $jobExitCode = [int]$exitMatch.Groups[1].Value
  }
  Remove-Job -Job $updateJob -Force -ErrorAction SilentlyContinue
  if ($jobExitCode -ne 0) {
    Write-Host $jobOutput
    throw "容器内 Codex CLI 安装失败（退出码 $jobExitCode）。"
  }

  $installed = Get-ContainerCodexVersion -ContainerName $ContainerName
  if ((Compare-Version -A $installed -B $previous) -le 0) {
    Write-Host $jobOutput
    throw "Codex CLI 更新后版本未变化（仍为 $previous），请检查容器内安装输出。"
  }
  Write-Host "容器内 Codex CLI 已更新到 $installed。"
}

if ($MyInvocation.InvocationName -ne ".") {
  if ($Action -eq "Check") {
    try {
      Get-CheckUpdateStatus | ConvertTo-Json -Depth 4
      exit 0
    }
    catch {
      Write-Output ('{"error":"' + ($_.Exception.Message -replace '"', "'") + '"}')
      exit 1
    }
  }

  if ($Action -eq "UpdateSuite") {
    Update-Suite
    exit $LASTEXITCODE
  }

  if ($Action -eq "UpdateCli") {
    try {
      Update-CodexCli -ContainerName (Get-UpdateSetting "containerName" "")
      exit 0
    }
    catch {
      Write-Output ("更新失败：" + $_.Exception.Message)
      exit 1
    }
  }
}