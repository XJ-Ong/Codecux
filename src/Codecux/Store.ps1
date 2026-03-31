function Test-CodecuxProfileName {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Invalid profile name '$Name'. Use letters, digits, dot, underscore, or hyphen."
    }
}

function Get-CodecuxProfileDir {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)
    $paths = Resolve-CodecuxPaths -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    Join-Path $paths.ProfilesRoot $Name
}

function Get-CodecuxProfileManifestPath {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)
    Join-Path (Get-CodecuxProfileDir -Name $Name -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot) 'profile.json'
}

function Get-CodecuxProfileAuthPath {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)
    Join-Path (Get-CodecuxProfileDir -Name $Name -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot) 'auth.json'
}

function ConvertTo-CodecuxSchemaVersion {
    param(
        $SchemaVersion,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($null -eq $SchemaVersion -or [string]::IsNullOrWhiteSpace([string]$SchemaVersion)) {
        return [int]$script:CodecuxStoreSchemaVersion
    }

    try {
        $parsed = [int]$SchemaVersion
    }
    catch {
        throw "$Label schema version '$SchemaVersion' is invalid."
    }

    if ($parsed -ne $script:CodecuxStoreSchemaVersion) {
        throw "$Label schema version '$parsed' is not supported."
    }

    $parsed
}

function ConvertTo-CodecuxStateRecord {
    param([Parameter(Mandatory = $true)]$State)

    [pscustomobject]@{
        schema_version = (ConvertTo-CodecuxSchemaVersion -SchemaVersion (Get-CodecuxObjectPropertyValue -Object $State -Name 'schema_version') -Label 'Codecux state')
        current_profile = [string](Get-CodecuxObjectPropertyValue -Object $State -Name 'current_profile')
        updated_at = Get-CodecuxObjectPropertyValue -Object $State -Name 'updated_at'
        codex_backup = Get-CodecuxObjectPropertyValue -Object $State -Name 'codex_backup'
        opencode_backup = Get-CodecuxObjectPropertyValue -Object $State -Name 'opencode_backup'
    }
}

function ConvertTo-CodecuxProfileManifestRecord {
    param([Parameter(Mandatory = $true)]$Manifest)

    $name = [string](Get-CodecuxObjectPropertyValue -Object $Manifest -Name 'name')
    $type = [string](Get-CodecuxObjectPropertyValue -Object $Manifest -Name 'type')
    $fingerprint = [string](Get-CodecuxObjectPropertyValue -Object $Manifest -Name 'fingerprint')
    $savedAt = Get-CodecuxObjectPropertyValue -Object $Manifest -Name 'saved_at'
    $display = [string](Get-CodecuxObjectPropertyValue -Object $Manifest -Name 'display')

    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Codecux profile manifest is missing the profile name.' }
    if ([string]::IsNullOrWhiteSpace($type)) { throw "Codecux profile manifest for '$name' is missing the profile type." }
    if ([string]::IsNullOrWhiteSpace($fingerprint)) { throw "Codecux profile manifest for '$name' is missing the fingerprint." }
    if ([string]::IsNullOrWhiteSpace([string]$display)) { $display = $name }

    [pscustomobject]@{
        schema_version = (ConvertTo-CodecuxSchemaVersion -SchemaVersion (Get-CodecuxObjectPropertyValue -Object $Manifest -Name 'schema_version') -Label "Codecux profile manifest for '$name'")
        name = $name
        type = $type
        fingerprint = $fingerprint
        saved_at = $savedAt
        display = $display
    }
}

function Get-CodecuxState {
    param([string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)
    $paths = Resolve-CodecuxPaths -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    if (-not (Test-Path $paths.StatePath)) {
        return (ConvertTo-CodecuxStateRecord -State ([ordered]@{
            schema_version = $script:CodecuxStoreSchemaVersion
            current_profile = ''
            updated_at = $null
            codex_backup = $null
            opencode_backup = $null
        }))
    }
    ConvertTo-CodecuxStateRecord -State (Read-CodecuxJsonFile -Path $paths.StatePath)
}

function Save-CodecuxState {
    param([Parameter(Mandatory = $true)]$State, [string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)
    $paths = Ensure-CodecuxStore -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    $normalized = ConvertTo-CodecuxStateRecord -State $State
    Write-CodecuxUtf8File -Path $paths.StatePath -Content ($normalized | ConvertTo-Json -Depth 8)
}

function Get-CodecuxProfileManifest {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)
    $manifestPath = Get-CodecuxProfileManifestPath -Name $Name -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    if (-not (Test-Path $manifestPath)) { throw "Profile '$Name' was not found." }
    ConvertTo-CodecuxProfileManifestRecord -Manifest (Read-CodecuxJsonFile -Path $manifestPath)
}

function Get-CodecuxProfiles {
    param([string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)
    $paths = Resolve-CodecuxPaths -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    if (-not (Test-Path $paths.ProfilesRoot)) { return @() }
    $results = @()
    foreach ($dir in (Get-ChildItem -Path $paths.ProfilesRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $manifestPath = Join-Path $dir.FullName 'profile.json'
        if (Test-Path $manifestPath) {
            $results += (ConvertTo-CodecuxProfileManifestRecord -Manifest (Read-CodecuxJsonFile -Path $manifestPath))
        }
    }
    $results
}

function Find-CodecuxProfileByFingerprint {
    param([Parameter(Mandatory = $true)][string]$Fingerprint, [string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)
    foreach ($profile in (Get-CodecuxProfiles -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot)) {
        if ($profile.fingerprint -eq $Fingerprint) { return $profile }
    }
    $null
}
