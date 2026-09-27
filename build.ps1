param(
  [string]$Version = "1.0.0.beta1",
  [switch]$SkipSmokeTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildRoot = Join-Path $Root ("build\run-" + (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
$PayloadRoot = Join-Path $BuildRoot "payload"
$PayloadZip = Join-Path $BuildRoot "payload.zip"
$OutputDir = Join-Path $Root "dist"
$ControllerSource = Join-Path $Root "src\controller"
$DockerSource = Join-Path $Root "src\docker"
$DocsSource = Join-Path $Root "docs"
$InstallerSource = Join-Path $Root "installer\Installer.cs"
$AppManifest = Join-Path $Root "installer\app.manifest"
$Csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$BundledNode = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
$SetupName = "DockerCodexSuite-Setup-$Version-win-x64.exe"
$SetupPath = Join-Path $OutputDir $SetupName
$IconPng = Join-Path $BuildRoot "DockerCodexSuite-icon.png"
$IconIco = Join-Path $BuildRoot "DockerCodexSuite-icon.ico"
$SocialCover = Join-Path $BuildRoot "DockerCodexSuite-cover-1200x630.png"

function Assert-UnderRoot {
  param([string]$Path, [string]$ExpectedRoot)
  $resolvedPath = [System.IO.Path]::GetFullPath($Path)
  $resolvedRoot = [System.IO.Path]::GetFullPath($ExpectedRoot).TrimEnd("\") + "\"
  if (-not $resolvedPath.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to modify path outside build root: $resolvedPath"
  }
}

function Copy-DirectoryContents {
  param([string]$Source, [string]$Destination)
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Recurse -Force
  }
}

function Invoke-Csc {
  param([string[]]$Arguments)
  & $Csc @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "C# compiler failed with exit code $LASTEXITCODE."
  }
}

function Resolve-NodeRuntime {
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($null -ne $command -and (Test-Path -LiteralPath $command.Source)) {
    return $command.Source
  }
  if (Test-Path -LiteralPath $BundledNode) {
    return $BundledNode
  }
  throw "Node.js was not found; chat proxy regression tests cannot run."
}

function New-ProductIcon {
  param([string]$PngPath, [string]$IcoPath)

  Add-Type -AssemblyName System.Drawing
  $bitmap = New-Object System.Drawing.Bitmap 256, 256
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.Clear([System.Drawing.Color]::Transparent)

  $background = New-Object System.Drawing.Drawing2D.GraphicsPath
  $radius = 42
  $background.AddArc(8, 8, $radius, $radius, 180, 90)
  $background.AddArc(206, 8, $radius, $radius, 270, 90)
  $background.AddArc(206, 206, $radius, $radius, 0, 90)
  $background.AddArc(8, 206, $radius, $radius, 90, 90)
  $background.CloseFigure()
  $graphics.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(23, 58, 58))), $background)

  $orangePen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(232, 110, 61)), 12
  $orangePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $graphics.DrawRectangle($orangePen, 51, 58, 154, 91)
  $graphics.DrawLine($orangePen, 72, 174, 184, 174)
  $graphics.DrawLine($orangePen, 92, 199, 164, 199)

  $font = New-Object System.Drawing.Font "Consolas", 46, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $whiteBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(247, 245, 238))
  $graphics.DrawString(">_", $font, $whiteBrush, 72, 75)

  $dotBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(103, 190, 151))
  $graphics.FillEllipse($dotBrush, 183, 178, 28, 28)

  $pngStream = New-Object System.IO.MemoryStream
  $bitmap.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
  $pngBytes = $pngStream.ToArray()
  [System.IO.File]::WriteAllBytes($PngPath, $pngBytes)

  $icoStream = New-Object System.IO.MemoryStream
  $writer = New-Object System.IO.BinaryWriter $icoStream
  $writer.Write([uint16]0)
  $writer.Write([uint16]1)
  $writer.Write([uint16]1)
  $writer.Write([byte]0)
  $writer.Write([byte]0)
  $writer.Write([byte]0)
  $writer.Write([byte]0)
  $writer.Write([uint16]1)
  $writer.Write([uint16]32)
  $writer.Write([uint32]$pngBytes.Length)
  $writer.Write([uint32]22)
  $writer.Write($pngBytes)
  $writer.Flush()
  [System.IO.File]::WriteAllBytes($IcoPath, $icoStream.ToArray())

  $writer.Dispose()
  $icoStream.Dispose()
  $pngStream.Dispose()
  $dotBrush.Dispose()
  $whiteBrush.Dispose()
  $font.Dispose()
  $orangePen.Dispose()
  $background.Dispose()
  $graphics.Dispose()
  $bitmap.Dispose()
}

function New-SocialCover {
  param([string]$IconPath, [string]$OutputPath)

  Add-Type -AssemblyName System.Drawing
  $bitmap = New-Object System.Drawing.Bitmap 1200, 630
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $graphics.Clear([System.Drawing.Color]::FromArgb(244, 241, 232))

  $teal = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(23, 58, 58))
  $orange = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(232, 110, 61))
  $cream = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(247, 245, 238))
  $muted = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(193, 218, 208))
  $ink = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(35, 46, 44))

  $graphics.FillRectangle($teal, 0, 0, 1200, 430)
  $graphics.FillRectangle($orange, 0, 430, 1200, 12)

  $icon = [System.Drawing.Image]::FromFile($IconPath)
  $graphics.DrawImage($icon, 74, 86, 220, 220)

  $titleFont = New-Object System.Drawing.Font "Segoe UI", 53, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $subtitleFont = New-Object System.Drawing.Font "Segoe UI", 27, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
  $badgeFont = New-Object System.Drawing.Font "Segoe UI", 18, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $featureFont = New-Object System.Drawing.Font "Segoe UI", 23, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $smallFont = New-Object System.Drawing.Font "Segoe UI", 17, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)

  $graphics.DrawString("Docker Codex Suite", $titleFont, $cream, 340, 102)
  $graphics.DrawString("Codex Desktop + Docker, one clean install", $subtitleFont, $muted, 344, 187)
  $graphics.DrawString("WINDOWS X64", $badgeFont, $cream, 345, 262)
  $graphics.DrawString("LOCAL FIRST", $badgeFont, $cream, 515, 262)
  $graphics.DrawString("COMMUNITY", $badgeFont, $cream, 670, 262)

  $graphics.DrawString("API profiles", $featureFont, $ink, 75, 485)
  $graphics.DrawString("Switch and keep Docker isolated", $smallFont, $ink, 75, 526)
  $graphics.DrawString("Active reconnect", $featureFont, $ink, 440, 485)
  $graphics.DrawString("Restart app-server, restore the link", $smallFont, $ink, 440, 526)
  $graphics.DrawString("Container safety", $featureFont, $ink, 835, 485)
  $graphics.DrawString("Reuse only a verified Codex container", $smallFont, $ink, 835, 526)

  $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)

  $smallFont.Dispose()
  $featureFont.Dispose()
  $badgeFont.Dispose()
  $subtitleFont.Dispose()
  $titleFont.Dispose()
  $icon.Dispose()
  $ink.Dispose()
  $muted.Dispose()
  $cream.Dispose()
  $orange.Dispose()
  $teal.Dispose()
  $graphics.Dispose()
  $bitmap.Dispose()
}

if (-not (Test-Path -LiteralPath $Csc)) {
  throw "C# compiler was not found: $Csc"
}

$installerVersionPattern = 'internal const string ProductVersion = "' + [regex]::Escape($Version) + '";'
if (-not (Select-String -LiteralPath $InstallerSource -Pattern $installerVersionPattern -Quiet)) {
  throw "Installer ProductVersion does not match build version $Version."
}

Write-Host "[1/8] Running Chat proxy regression tests..."
$Node = Resolve-NodeRuntime
& $Node (Join-Path $Root "tests\chat-proxy-tests.js")
if ($LASTEXITCODE -ne 0) {
  throw "Chat proxy tests failed with exit code $LASTEXITCODE."
}
& $Node --test (Join-Path $Root "tests\chat-proxy-tool-search-tests.js")
if ($LASTEXITCODE -ne 0) {
  throw "Chat proxy tool_search tests failed with exit code $LASTEXITCODE."
}
& $Node --test (Join-Path $Root "tests\responses-proxy-tests.js")
if ($LASTEXITCODE -ne 0) {
  throw "Responses proxy tests failed with exit code $LASTEXITCODE."
}
& $Node (Join-Path $Root "tests\app-reconnect-tests.js")
if ($LASTEXITCODE -ne 0) {
  throw "App reconnect tests failed with exit code $LASTEXITCODE."
}
& $Node (Join-Path $Root "tests\bridge-menu-tests.js")
if ($LASTEXITCODE -ne 0) {
  throw "Bridge menu injection tests failed with exit code $LASTEXITCODE."
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "tests\profile-manager-tests.ps1")
if ($LASTEXITCODE -ne 0) {
  throw "Profile manager tests failed with exit code $LASTEXITCODE."
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "tests\protocol-path-tests.ps1")
if ($LASTEXITCODE -ne 0) {
  throw "Protocol custom-path tests failed with exit code $LASTEXITCODE."
}
if (-not $SkipSmokeTest) {
  Write-Host "Running WinForms custom-path UI smoke test..."
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "tests\provider-manager-ui-smoke.ps1")
  if ($LASTEXITCODE -ne 0) {
    throw "Provider manager UI smoke test failed with exit code $LASTEXITCODE."
  }
}

New-Item -ItemType Directory -Path $BuildRoot -Force | Out-Null
Write-Host "[2/8] Running installer and custom-path regression tests..."
$DetectorTestOutput = Join-Path $BuildRoot "EnvironmentDetectorTests.exe"
Invoke-Csc @(
  "/nologo",
  "/target:exe",
  "/platform:x64",
  "/codepage:65001",
  "/optimize+",
  "/main:DockerCodexSuiteInstaller.EnvironmentDetectorTests",
  "/out:$DetectorTestOutput",
  "/reference:System.dll",
  "/reference:System.Core.dll",
  "/reference:System.Windows.Forms.dll",
  "/reference:System.Drawing.dll",
  "/reference:System.IO.Compression.dll",
  "/reference:System.IO.Compression.FileSystem.dll",
  "/reference:System.Web.Extensions.dll",
  "/reference:Microsoft.CSharp.dll",
  (Join-Path $Root "installer\Installer.cs"),
  (Join-Path $Root "tests\EnvironmentDetectorTests.cs")
)
$DetectorTestData = Join-Path $BuildRoot "environment-detector-test-data"
& $DetectorTestOutput $DetectorTestData
if ($LASTEXITCODE -ne 0) {
  throw "Installer/environment regression tests failed with exit code $LASTEXITCODE."
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
New-Item -ItemType Directory -Path $PayloadRoot -Force | Out-Null
New-ProductIcon -PngPath $IconPng -IcoPath $IconIco
New-SocialCover -IconPath $IconPng -OutputPath $SocialCover

Write-Host "[3/8] Compiling installed launcher..."
$launcherSource = Join-Path $ControllerSource "DockerCodexLauncher.cs"
$launcherOutput = Join-Path $PayloadRoot "DockerCodex.exe"
Invoke-Csc @(
  "/nologo",
  "/target:winexe",
  "/platform:x64",
  "/codepage:65001",
  "/optimize+",
  "/win32icon:$IconIco",
  "/win32manifest:$AppManifest",
  "/out:$launcherOutput",
  "/reference:System.dll",
  "/reference:System.Windows.Forms.dll",
  "/reference:System.Drawing.dll",
  $launcherSource
)

Write-Host "[4/8] Assembling sanitized payload..."
foreach ($item in Get-ChildItem -LiteralPath $ControllerSource -File -Force) {
  if ($item.Extension -in @(".ps1", ".js")) {
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $PayloadRoot $item.Name) -Force
  }
}
Copy-DirectoryContents -Source $DockerSource -Destination (Join-Path $PayloadRoot "docker-template")
Copy-DirectoryContents -Source $DocsSource -Destination (Join-Path $PayloadRoot "docs")
New-Item -ItemType Directory -Path (Join-Path $PayloadRoot "assets") -Force | Out-Null
Copy-Item -LiteralPath $IconPng -Destination (Join-Path $PayloadRoot "assets\icon.png") -Force
[System.IO.File]::WriteAllText(
  (Join-Path $PayloadRoot "VERSION"),
  $Version + "`r`n",
  (New-Object System.Text.UTF8Encoding($false))
)

$entrypoint = Join-Path $PayloadRoot "docker-template\docker-entrypoint.sh"
$entrypointText = [System.IO.File]::ReadAllText($entrypoint) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($entrypoint, $entrypointText, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "[5/8] Scanning payload for local secrets and machine-specific paths..."
$forbiddenNames = @(".env", "auth.json", "api-profiles.json", ".docker-codex-suite-managed.json")
$badFiles = @(Get-ChildItem -LiteralPath $PayloadRoot -Recurse -File -Force | Where-Object {
  $_.Name -in $forbiddenNames -or $_.Extension -in @(".log", ".sqlite", ".key")
})
if ($badFiles.Count -gt 0) {
  throw "Forbidden files entered payload: $($badFiles.FullName -join ', ')"
}

$textExtensions = @(".ps1", ".js", ".cs", ".md", ".txt", ".toml", ".yml", ".yaml", ".sh", ".example")
$textFiles = @(Get-ChildItem -LiteralPath $PayloadRoot -Recurse -File -Force | Where-Object {
  $_.Extension -in $textExtensions -or $_.Name -eq "Dockerfile" -or $_.Name -eq "VERSION"
})
$forbiddenPatterns = @(
  'C:\\Users\\Administrator',
  'D:\\docker',
  'api\.ikuncode',
  'IKUNCODE_API_KEY',
  'AAAAC3NzaC1lZDI1NTE5AAAAIBafiPmSz'
)
foreach ($pattern in $forbiddenPatterns) {
  $match = $textFiles | Select-String -Pattern $pattern -CaseSensitive:$false | Select-Object -First 1
  if ($null -ne $match) {
    throw "Forbidden content matched '$pattern' in $($match.Path):$($match.LineNumber)"
  }
}

Write-Host "[6/8] Compressing payload..."
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
  $PayloadRoot,
  $PayloadZip,
  [System.IO.Compression.CompressionLevel]::Optimal,
  $false
)

Write-Host "[7/8] Compiling single-file setup..."
Invoke-Csc @(
  "/nologo",
  "/target:winexe",
  "/platform:x64",
  "/codepage:65001",
  "/optimize+",
  "/win32icon:$IconIco",
  "/win32manifest:$AppManifest",
  "/out:$SetupPath",
  "/resource:$PayloadZip,DockerCodex.Payload",
  "/reference:System.dll",
  "/reference:System.Core.dll",
  "/reference:System.Windows.Forms.dll",
  "/reference:System.Drawing.dll",
  "/reference:System.IO.Compression.dll",
  "/reference:System.IO.Compression.FileSystem.dll",
  "/reference:System.Web.Extensions.dll",
  "/reference:Microsoft.CSharp.dll",
  $InstallerSource
)

Write-Host "[8/8] Creating manifest and smoke test..."
$hash = Get-FileHash -LiteralPath $SetupPath -Algorithm SHA256
$manifest = [ordered]@{
  product = "Docker Codex Suite"
  version = $Version
  artifact = $SetupName
  architecture = "win-x64"
  sha256 = $hash.Hash.ToLowerInvariant()
  size_bytes = (Get-Item -LiteralPath $SetupPath).Length
  signed = $false
  built_at = (Get-Date).ToUniversalTime().ToString("o")
  prerequisites = @("Windows 10/11 x64", "Docker Desktop", "OpenAI Codex Desktop", "Windows OpenSSH Client")
}
$manifestPath = Join-Path $OutputDir "release-manifest.json"
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
($hash.Hash.ToLowerInvariant() + "  " + $SetupName) | Set-Content -LiteralPath (Join-Path $OutputDir "SHA256SUMS.txt") -Encoding ASCII
Copy-Item -LiteralPath $IconPng -Destination (Join-Path $OutputDir "DockerCodexSuite-icon.png") -Force
Copy-Item -LiteralPath $SocialCover -Destination (Join-Path $OutputDir "DockerCodexSuite-cover-1200x630.png") -Force
Copy-Item -LiteralPath (Join-Path $Root "docs\RELEASE_NOTES.md") -Destination (Join-Path $OutputDir "RELEASE_NOTES.md") -Force
Copy-Item -LiteralPath (Join-Path $Root "release-assets\SOCIAL_POST.zh-CN.md") -Destination (Join-Path $OutputDir "SOCIAL_POST.zh-CN.md") -Force

if (-not $SkipSmokeTest) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "tests\uninstall-completion-tests.ps1") -SetupPath $SetupPath
  if ($LASTEXITCODE -ne 0) {
    throw "Uninstall completion smoke test failed with exit code $LASTEXITCODE."
  }
  $smokeLabel = "smoke-" + [char]0x4e2d + [char]0x6587
  $extractDir = Join-Path $BuildRoot ("smoke-extract " + $smokeLabel)
  $smoke = Start-Process `
    -FilePath $SetupPath `
    -ArgumentList ('--extract-only "' + $extractDir + '"') `
    -Wait `
    -PassThru
  if ($smoke.ExitCode -ne 0) {
    throw "Setup extract-only smoke test failed with exit code $($smoke.ExitCode)."
  }
  foreach ($required in @("DockerCodex.exe", "docker-codex-api-switch.ps1", "docker-codex-chat-proxy.js", "docker-codex-renderer-model-compat.js", "docker-template\compose.template.yml", "docs\README.md")) {
    if (-not (Test-Path -LiteralPath (Join-Path $extractDir $required))) {
      throw "Smoke test missing payload file: $required"
    }
  }
  if (Test-Path -LiteralPath (Join-Path $extractDir "skills")) {
    throw "Smoke test found a skills directory in the package payload."
  }
  $packagedProtocol = Get-Content -LiteralPath (Join-Path $extractDir "docker-codex-api-switch-protocol.ps1") -Raw
  if ($packagedProtocol -notmatch "ProcessStartInfo" -or $packagedProtocol -notmatch 'Test-Path -LiteralPath \$Script:SwitcherPath') {
    throw "Smoke test found an outdated protocol path launcher in the package payload."
  }
  $packagedSwitcher = Get-Content -LiteralPath (Join-Path $extractDir "docker-codex-api-switch.ps1") -Raw
  if ($packagedSwitcher -notmatch "mutexName") {
    throw "Smoke test found an outdated GUI mutex implementation in the package payload."
  }
  $packagedBridgeLauncher = Get-Content -LiteralPath (Join-Path $extractDir "docker-codex-standalone-launch.ps1") -Raw
  $bridgeLauncherOutdated = $packagedBridgeLauncher -notmatch "Start-HiddenProcess" -or `
    $packagedBridgeLauncher -notmatch "Activate-CodexDesktop" -or `
    $packagedBridgeLauncher -notmatch "Existing Codex debug channel detected"
  if ($bridgeLauncherOutdated) {
    throw "Smoke test found an outdated bridge launcher in the package payload."
  }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "tests\protocol-path-tests.ps1") -SourceRoot $extractDir
  if ($LASTEXITCODE -ne 0) {
    throw "Packaged protocol custom-path smoke test failed with exit code $LASTEXITCODE."
  }
}

Write-Host ""
Write-Host "Built: $SetupPath"
Write-Host "SHA256: $($hash.Hash.ToLowerInvariant())"
