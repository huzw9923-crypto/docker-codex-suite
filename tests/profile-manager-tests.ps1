$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw "Assertion failed: $Message"
  }
}

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$sourceScript = Join-Path $root "src\controller\docker-codex-api-switch.ps1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("docker-codex-profile-tests-" + [guid]::NewGuid().ToString("N"))
$fixtureScript = Join-Path $tempRoot "docker-codex-api-switch.ps1"
$dataDir = Join-Path $tempRoot "data"
$composeDir = Join-Path $tempRoot "compose"
$codexHome = Join-Path $composeDir "codex-home"
$codexPlusPlusSettingsPath = Join-Path $tempRoot "codexplusplus-settings.json"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
  New-Item -ItemType Directory -Path $dataDir, $codexHome -Force | Out-Null
  Copy-Item -LiteralPath $sourceScript -Destination $fixtureScript -Force

  $settings = [ordered]@{
    dataDir       = $dataDir
    composeDir    = $composeDir
    profilesPath = (Join-Path $dataDir "api-profiles.json")
    statePath    = (Join-Path $dataDir "switch-state.json")
    apiEnvKey    = "DOCKER_CODEX_API_KEY"
    codexPlusPlusSettingsPath = $codexPlusPlusSettingsPath
    chatProxyPort = 38119
  }
  [System.IO.File]::WriteAllText(
    (Join-Path $tempRoot "settings.json"),
    ($settings | ConvertTo-Json -Compress),
    $utf8NoBom
  )
  [System.IO.File]::WriteAllText(
    (Join-Path $codexHome "config.toml"),
    "sandbox_mode = `"workspace-write`"`r`n",
    $utf8NoBom
  )

  . $fixtureScript -Action Profiles | Out-Null

  $inner = [pscustomobject]@{ Id = "inner" }
  $outer = [pscustomobject]@{ RawProfile = $inner }
  $rawValue = Get-ObjectPropertyValue -Object $outer -Name "RawProfile"
  Assert-True ([object]::ReferenceEquals($inner, $rawValue)) "object-valued properties must not be converted to strings"
  Assert-True (@(Get-ProfileModelIds -Profile $null).Count -eq 0) "a new profile must start with an empty model list"

  $createdAt = "2026-07-14T12:00:00"
  $profile = [pscustomobject]@{
    Id               = "profile-a"
    Name             = "Responses Provider"
    BaseUrl          = "https://example.test/v1"
    Model            = "model-a"
    ModelList        = "model-a`r`nmodel-b"
    UpstreamProtocol = "responses"
    WireApi          = "responses"
    ApiKey           = "test-secret-value"
    EnvKey           = "DOCKER_CODEX_API_KEY"
    CreatedAt        = $createdAt
    UpdatedAt        = $createdAt
  }
  Save-LocalProfile -Profile $profile

  $profiles = @(Get-ApiProfiles)
  Assert-True ($profiles.Count -eq 1) "create must add exactly one profile"
  Assert-True ($profiles[0].Id -eq "local:profile-a") "summary id must preserve the stored id"
  Assert-True ($profiles[0].UpstreamProtocol -eq "responses") "Responses protocol must round-trip"
  Assert-True ((Get-ProfileApiKey -Profile $profiles[0]) -eq "test-secret-value") "API key must remain editable after reload"
  $modelIds = @(Get-ProfileModelIds -Profile $profiles[0])
  Assert-True ($modelIds.Count -eq 2) "fetched model ids must round-trip; got: $($modelIds -join '|')"

  $edited = [pscustomobject]@{
    Id               = "profile-a"
    Name             = "Chat Provider"
    BaseUrl          = "https://chat.example.test/v1"
    Model            = "chat-model"
    ModelList        = "chat-model"
    UpstreamProtocol = "chat"
    WireApi          = "responses"
    ApiKey           = "test-secret-value"
    EnvKey           = "DOCKER_CODEX_API_KEY"
    CreatedAt        = $createdAt
    UpdatedAt        = "2026-07-14T12:05:00"
  }
  Save-LocalProfile -Profile $edited

  $stored = @(Read-LocalProfiles)
  $profiles = @(Get-ApiProfiles)
  Assert-True ($stored.Count -eq 1) "editing must replace the existing profile instead of duplicating it"
  Assert-True ($stored[0].CreatedAt -eq $createdAt) "editing must preserve CreatedAt"
  Assert-True ($profiles[0].Name -eq "Chat Provider") "edited name must be visible"
  Assert-True ($profiles[0].UpstreamProtocol -eq "chat") "Chat protocol must round-trip"
  Assert-True ($profiles[0].ConfigContents -match 'wire_api\s*=\s*"responses"') "Chat profiles must not emit removed wire_api=chat config"

  $protected = Protect-SensitiveText "Bearer private-token sk-abcdefghijk?api_key=plain-secret"
  Assert-True ($protected -notmatch 'private-token|abcdefghijk|plain-secret') "logs must redact common credential formats"

  Remove-LocalProfile -Id "profile-a"
  $remainingProfiles = @(Read-LocalProfiles)
  $rawProfileJson = [System.IO.File]::ReadAllText((Join-Path $dataDir "api-profiles.json"))
  $remainingIds = @($remainingProfiles | ForEach-Object { [string]$_.Id }) -join "|"
  Assert-True ($remainingProfiles.Count -eq 0) "delete must remove the selected profile; got count=$($remainingProfiles.Count), ids=$remainingIds, json=$rawProfileJson"

  $responsesAuth = [ordered]@{ OPENAI_API_KEY = "fixture-responses-key" } | ConvertTo-Json -Compress
  $deepSeekAuth = [ordered]@{ OPENAI_API_KEY = "fixture-deepseek-key" } | ConvertTo-Json -Compress
  $codexPlusPlusSettings = [ordered]@{
    activeRelayId = "relay-deepseek"
    relayApiKey   = ""
    relayProfiles = @(
      [ordered]@{
        id              = "relay-responses"
        name            = "Responses Fixture"
        protocol        = "responses"
        relayMode       = "pureApi"
        upstreamBaseUrl = "https://responses.example.test/v1"
        modelList       = "response-model-a`r`nresponse-model-b"
        configContents  = "model = `"response-model-a`"`r`nbase_url = `"https://responses.example.test/v1`"`r`n"
        authContents    = $responsesAuth
      }
      [ordered]@{
        id              = "relay-deepseek"
        name            = "DeepSeek"
        protocol        = "chatCompletions"
        relayMode       = "pureApi"
        upstreamBaseUrl = "https://api.deepseek.com"
        testModel       = "deepseek-v4-flash"
        modelList       = "deepseek-v4-pro`r`ndeepseek-v4-flash"
        configContents  = "model = `"deepseek-v4-pro`"`r`nbase_url = `"http://127.0.0.1:57321/v1`"`r`n"
        authContents    = $deepSeekAuth
      }
      [ordered]@{
        id              = "relay-aggregate"
        name            = "Aggregate Fixture"
        protocol        = "responses"
        relayMode       = "aggregate"
        upstreamBaseUrl = "https://aggregate.example.test/v1"
        modelList       = "aggregate-model"
        configContents  = "model = `"aggregate-model`"`r`n"
        authContents    = $responsesAuth
      }
      [ordered]@{
        id              = "relay-missing-key"
        name            = "Missing Key Fixture"
        protocol        = "responses"
        relayMode       = "pureApi"
        upstreamBaseUrl = "https://missing-key.example.test/v1"
        modelList       = "missing-key-model"
        configContents  = "model = `"missing-key-model`"`r`n"
        authContents    = ""
      }
      [ordered]@{
        id              = "relay-local-only"
        name            = "Local Proxy Fixture"
        protocol        = "chatCompletions"
        relayMode       = "pureApi"
        upstreamBaseUrl = "http://127.0.0.1:57321/v1"
        modelList       = "local-model"
        configContents  = "model = `"local-model`"`r`nbase_url = `"http://127.0.0.1:57321/v1`"`r`n"
        authContents    = $deepSeekAuth
      }
    )
  }
  [System.IO.File]::WriteAllText(
    $codexPlusPlusSettingsPath,
    ($codexPlusPlusSettings | ConvertTo-Json -Depth 8),
    $utf8NoBom
  )

  $importCandidates = @(Get-CodexPlusPlusImportCandidates)
  Assert-True ($importCandidates.Count -eq 5) "all Codex++ profiles must appear in the preview"
  $importableCandidates = @($importCandidates | Where-Object { [bool]$_.CanImport })
  Assert-True ($importableCandidates.Count -eq 2) "only valid Responses and DeepSeek profiles must be importable"

  $deepSeekCandidate = $importCandidates | Where-Object { $_.Name -eq "DeepSeek" } | Select-Object -First 1
  Assert-True ([bool]$deepSeekCandidate.CanImport) "DeepSeek ChatCompletions profile must be importable"
  Assert-True ($deepSeekCandidate.Profile.UpstreamProtocol -eq "chat") "DeepSeek must use the Chat adapter"
  Assert-True ($deepSeekCandidate.Profile.BaseUrl -eq "https://api.deepseek.com") "DeepSeek must retain the real upstream instead of the Codex++ local proxy"
  Assert-True ($deepSeekCandidate.Profile.ApiKey -eq "fixture-deepseek-key") "API key must be extracted from authContents"
  Assert-True ($deepSeekCandidate.Profile.ConfigContents -match 'base_url\s*=\s*"http://127\.0\.0\.1:38119/v1"') "Chat profile config must target the independent local adapter"
  Assert-True ($deepSeekCandidate.Profile.ConfigContents -notmatch '57321') "imported Chat config must not depend on the Codex++ relay port"
  $dockerChatConfig = Convert-ConfigForDockerNetworking -ConfigText $deepSeekCandidate.Profile.ConfigContents
  Assert-True ($dockerChatConfig -match 'base_url\s*=\s*"http://host\.docker\.internal:38119/v1"') "Docker Chat config must route to the host adapter"

  $catalogConfig = Set-ProfileModelCatalog -Profile $deepSeekCandidate.Profile -ConfigText $deepSeekCandidate.Profile.ConfigContents
  Assert-True ($catalogConfig -match 'model_catalog_json\s*=\s*"model-catalog\.docker-api\.json"') "profile config must reference the generated native Codex model catalog"
  $catalogPath = Join-Path $codexHome "model-catalog.docker-api.json"
  Assert-True (Test-Path -LiteralPath $catalogPath) "profile activation must generate the native Codex model catalog"
  $catalogJson = [System.IO.File]::ReadAllText($catalogPath)
  Assert-True ($catalogJson -match '"input_modalities"\s*:\s*\[\s*"text"\s*\]') "Chat catalog input_modalities must remain a JSON array"
  $catalog = $catalogJson | ConvertFrom-Json
  $catalogModels = @($catalog.models)
  Assert-True ($catalogModels.Count -eq 2) "DeepSeek catalog must contain both imported model ids"
  Assert-True ($catalogModels[0].slug -eq "deepseek-v4-pro") "the selected/default model must be first in the catalog"
  Assert-True ($catalogModels[1].slug -eq "deepseek-v4-flash") "the second imported model must remain available"
  Assert-True (@($catalogModels | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.base_instructions) }).Count -eq 0) "every native catalog entry must include base_instructions"

  [System.IO.File]::WriteAllText(
    $Script:LocalTemplatePath,
    "model_catalog_json = `"stale-local-catalog.json`"`r`nsandbox_mode = `"workspace-write`"`r`n",
    $utf8NoBom
  )
  $mergedCatalogConfig = Build-ProfileModeConfig -ProfileConfigText $catalogConfig
  Assert-True ($mergedCatalogConfig -notmatch 'stale-local-catalog\.json') "the local template must not override the active profile catalog"
  Assert-True (@([regex]::Matches($mergedCatalogConfig, '(?m)^\s*model_catalog_json\s*=')).Count -eq 1) "merged config must contain exactly one model catalog setting"

  $aggregateCandidate = $importCandidates | Where-Object { $_.Name -eq "Aggregate Fixture" } | Select-Object -First 1
  Assert-True (-not [bool]$aggregateCandidate.CanImport) "aggregate profiles must be rejected"
  $missingKeyCandidate = $importCandidates | Where-Object { $_.Name -eq "Missing Key Fixture" } | Select-Object -First 1
  Assert-True (-not [bool]$missingKeyCandidate.CanImport) "profiles without exportable credentials must be rejected"
  $localProxyCandidate = $importCandidates | Where-Object { $_.Name -eq "Local Proxy Fixture" } | Select-Object -First 1
  Assert-True (-not [bool]$localProxyCandidate.CanImport) "Codex++ relay-only profiles must be rejected"

  $firstImport = Import-CodexPlusPlusProfiles -Candidates $importableCandidates
  Assert-True ($firstImport.Added -eq 2 -and $firstImport.Updated -eq 0) "first import must add both valid profiles"
  $firstStoredImport = @(Read-LocalProfiles)
  Assert-True ($firstStoredImport.Count -eq 2) "first import must persist exactly two profiles"
  $firstIds = @($firstStoredImport | Sort-Object SourceProfileId | ForEach-Object { [string]$_.Id }) -join "|"

  $secondImport = Import-CodexPlusPlusProfiles -Candidates $importableCandidates
  Assert-True ($secondImport.Added -eq 0 -and $secondImport.Updated -eq 2) "re-import must update by Codex++ profile id"
  $secondStoredImport = @(Read-LocalProfiles)
  $secondIds = @($secondStoredImport | Sort-Object SourceProfileId | ForEach-Object { [string]$_.Id }) -join "|"
  Assert-True ($secondStoredImport.Count -eq 2) "re-import must not create duplicates"
  Assert-True ($secondIds -eq $firstIds) "re-import must preserve stable local ids"
  $summaries = @(Get-ApiProfiles)
  $summarySources = @($summaries | ForEach-Object { [string]$_.Source }) -join "|"
  $importedSummaryCount = @($summaries | Where-Object { ([string]$_.Source).StartsWith("Codex++", [System.StringComparison]::Ordinal) }).Count
  Assert-True ($importedSummaryCount -eq 2) "imported profiles must be labeled without becoming runtime-dependent; count=$importedSummaryCount, sources=$summarySources"

  $responsesProfile = $summaries | Where-Object { $_.Name -eq "Responses Fixture" } | Select-Object -First 1
  Assert-True ($responsesProfile.UpstreamProtocol -eq "responses") "Responses profile must retain its native upstream protocol"
  Assert-True ($responsesProfile.ConfigContents -match 'base_url\s*=\s*"https://responses\.example\.test/v1"') "Responses profile must retain its real upstream config"

  # Profile activation must be reversible: switching protocols changes only the
  # generated Docker config and gateway state, not the stored profile source.
  Write-ApiProfileConfig -Profile $deepSeekCandidate.Profile -SkipProxyHealth
  $chatActivatedConfig = [System.IO.File]::ReadAllText($Script:DockerConfigPath)
  $chatProxyState = [System.IO.File]::ReadAllText($Script:ChatProxyConfigPath) | ConvertFrom-Json
  Assert-True ($chatProxyState.protocol -eq "chat") "activating DeepSeek must select the Chat adapter"
  Assert-True ($chatProxyState.upstreamBaseUrl -eq "https://api.deepseek.com") "Chat adapter must retain the DeepSeek upstream"
  Assert-True ($chatActivatedConfig -match 'wire_api\s*=\s*"responses"') "Docker must keep the Responses wire API while using the Chat adapter"
  Assert-True ($chatActivatedConfig -match 'base_url\s*=\s*"http://host\.docker\.internal:38119/v1"') "Docker Chat config must route through the host adapter"
  Assert-True ($chatActivatedConfig -match 'model\s*=\s*"deepseek-v4-pro"') "switching to DeepSeek must update the active model"

  Write-ApiProfileConfig -Profile $responsesProfile -SkipProxyHealth
  $responsesActivatedConfig = [System.IO.File]::ReadAllText($Script:DockerConfigPath)
  $responsesProxyState = [System.IO.File]::ReadAllText($Script:ChatProxyConfigPath) | ConvertFrom-Json
  Assert-True ($responsesProxyState.protocol -eq "responses") "switching back must select the native Responses adapter"
  Assert-True ($responsesProxyState.upstreamBaseUrl -eq "https://responses.example.test/v1") "Responses adapter must retain its real upstream"
  Assert-True ($responsesActivatedConfig -match 'wire_api\s*=\s*"responses"') "Responses activation must keep the Responses wire API"
  Assert-True ($responsesActivatedConfig -match 'base_url\s*=\s*"http://host\.docker\.internal:38119/v1"') "Responses activation must route through the host adapter"
  Assert-True ($responsesActivatedConfig -match 'model\s*=\s*"response-model-a"') "switching back must restore the Responses model"
  Assert-True ($responsesProfile.ConfigContents -match 'base_url\s*=\s*"https://responses\.example\.test/v1"') "switching must not mutate the stored Responses profile"

  [System.IO.File]::WriteAllText(
    $Script:DockerConfigPath,
    "model_provider = `"custom`"`r`nmodel = `"response-model-a`"`r`n",
    $utf8NoBom
  )
  [System.IO.File]::WriteAllText(
    $Script:StatePath,
    ([ordered]@{ mode = "profile"; profile_id = $responsesProfile.Id } | ConvertTo-Json -Compress),
    $utf8NoBom
  )
  $repair = Repair-ActiveApiProfile
  $repairedConfig = [System.IO.File]::ReadAllText($Script:DockerConfigPath)
  Assert-True ($repair.Status -eq "repaired" -and [bool]$repair.Changed) "upgrade repair must rewrite an active profile that lost its catalog reference"
  Assert-True ($repairedConfig -match 'model_catalog_json\s*=\s*"model-catalog\.docker-api\.json"') "upgrade repair must restore the active model catalog reference"

  Write-Output "Profile manager tests: PASS"
}
finally {
  if (Test-Path -LiteralPath $tempRoot) {
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
    $resolvedSystemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd("\") + "\"
    if (-not $resolvedTemp.StartsWith($resolvedSystemTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove test path outside the system temp directory: $resolvedTemp"
    }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
