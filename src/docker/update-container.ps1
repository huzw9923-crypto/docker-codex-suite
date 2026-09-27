param([switch]$UseCache)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $root
try {
  $arguments = @("compose", "build")
  if (-not $UseCache) {
    $arguments += "--no-cache"
  }
  $arguments += "codex-dev"
  & docker @arguments
  if ($LASTEXITCODE -ne 0) { throw "Docker image build failed." }

  & docker compose up -d --force-recreate codex-dev
  if ($LASTEXITCODE -ne 0) { throw "Docker container recreation failed." }
}
finally {
  Pop-Location
}

Write-Host "Docker Codex container updated."

