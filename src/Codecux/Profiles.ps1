function New-CodecuxApiKeyAuthObject {
    param([Parameter(Mandatory = $true)][string]$ApiKey)
    [ordered]@{
        type = 'api'
        key  = $ApiKey
    }
}

function Get-CodecuxActiveCodexAuthObject {
    param([string]$CodexRoot, [string]$StoreRoot, [string]$OpencodeRoot)
    $paths = Resolve-CodecuxPaths -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    if (-not (Test-Path $paths.CodexAuthPath)) { return $null }
    ConvertTo-CodecuxCanonicalAuthObject -RawAuthObject (Read-CodecuxJsonFile -Path $paths.CodexAuthPath)
}

function Get-CodecuxActiveOpencodeAuthObject {
    param([string]$CodexRoot, [string]$StoreRoot, [string]$OpencodeRoot)
    $paths = Resolve-CodecuxPaths -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    if (-not (Test-Path $paths.OpencodeAuthPath)) { return $null }
    $authMap = Read-CodecuxJsonFile -Path $paths.OpencodeAuthPath
    $openai = Get-CodecuxObjectPropertyValue -Object $authMap -Name 'openai'
    if ($null -eq $openai) { return $null }
    ConvertTo-CodecuxCanonicalAuthObject -RawAuthObject $openai
}

function Get-CodecuxLiveAuthObject {
    param([string]$CodexRoot, [string]$StoreRoot, [string]$OpencodeRoot)

    $codexAuth = Get-CodecuxActiveCodexAuthObject -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    $opencodeAuth = Get-CodecuxActiveOpencodeAuthObject -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot

    if ($null -eq $codexAuth -and $null -eq $opencodeAuth) {
        throw 'No active Codex CLI or OpenCode OpenAI auth was found. Log into one of them first or add an API-key profile.'
    }

    if ($null -eq $codexAuth -and $null -ne $opencodeAuth -and $opencodeAuth.type -eq 'oauth') {
        throw 'OpenCode OAuth alone is not enough to add a shared chatgpt profile because Codex CLI requires an id_token. Log in with codex login first, then run cux add.'
    }

    if ($null -ne $codexAuth) { return $codexAuth }
    $opencodeAuth
}

function Save-CodecuxProfileFromAuthObject {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$AuthObject,
        [string]$StoreRoot,
        [string]$CodexRoot,
        [string]$OpencodeRoot
    )

    Test-CodecuxProfileName -Name $Name
    $paths = Ensure-CodecuxStore -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    $profileDir = Get-CodecuxProfileDir -Name $Name -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    if (Test-Path $profileDir) { throw "Profile '$Name' already exists." }

    $canonicalAuth = ConvertTo-CodecuxCanonicalAuthObject -RawAuthObject $AuthObject
    $type = Get-CodecuxProfileType -AuthObject $canonicalAuth
    $fingerprint = Get-CodecuxAuthFingerprint -AuthObject $canonicalAuth
    $existing = Find-CodecuxProfileByFingerprint -Fingerprint $fingerprint -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    if ($null -ne $existing) { throw "This account is already saved as '$($existing.name)'." }

    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    Write-CodecuxUtf8File -Path (Join-Path $profileDir 'auth.json') -Content ($canonicalAuth | ConvertTo-Json -Depth 10)

    $manifest = ConvertTo-CodecuxProfileManifestRecord -Manifest ([ordered]@{
        schema_version = $script:CodecuxStoreSchemaVersion
        name        = $Name
        type        = $type
        fingerprint = $fingerprint
        saved_at    = (Get-Date).ToUniversalTime().ToString('o')
        display     = if ($type -eq 'apikey') { Get-CodecuxMaskedApiKey -ApiKey ([string]$canonicalAuth.key) } elseif (-not [string]::IsNullOrWhiteSpace([string]$canonicalAuth.accountId)) { [string]$canonicalAuth.accountId } else { $Name }
    })
    Write-CodecuxUtf8File -Path (Join-Path $profileDir 'profile.json') -Content ($manifest | ConvertTo-Json -Depth 10)
    [pscustomobject]$manifest
}

function Add-CodecuxProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$StoreRoot,
        [string]$CodexRoot,
        [string]$OpencodeRoot,
        [string]$ApiKey
    )

    $authObject = if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        Get-CodecuxLiveAuthObject -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    } else {
        New-CodecuxApiKeyAuthObject -ApiKey $ApiKey
    }

    Save-CodecuxProfileFromAuthObject -Name $Name -AuthObject $authObject -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
}

function Backup-CodecuxFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Label, [string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)
    $paths = Ensure-CodecuxStore -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    if (-not (Test-Path $Path)) { return $null }
    $backupPath = Join-Path $paths.BackupsRoot ("{0}-{1}.json" -f $Label, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Copy-Item -Path $Path -Destination $backupPath -Force
    $backupPath
}

function Restore-CodecuxFile {
    param([Parameter(Mandatory = $true)][string]$TargetPath, [string]$BackupPath)
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        if (Test-Path $TargetPath) { Remove-Item -Path $TargetPath -Force }
        return
    }
    Copy-Item -Path $BackupPath -Destination $TargetPath -Force
}

function Set-CodecuxCodexAuth {
    param([Parameter(Mandatory = $true)]$CanonicalAuth, [Parameter(Mandatory = $true)]$Paths)
    $codexAuth = ConvertTo-CodecuxCodexAuthObject -CanonicalAuth $CanonicalAuth
    Write-CodecuxUtf8File -Path $Paths.CodexAuthPath -Content ($codexAuth | ConvertTo-Json -Depth 10)
}

function Set-CodecuxOpencodeAuth {
    param([Parameter(Mandatory = $true)]$CanonicalAuth, [Parameter(Mandatory = $true)]$Paths)

    $opencodeDir = Split-Path -Parent $Paths.OpencodeAuthPath
    if (-not (Test-Path $opencodeDir)) {
        New-Item -ItemType Directory -Force -Path $opencodeDir | Out-Null
    }

    $authMap = [ordered]@{}
    if (Test-Path $Paths.OpencodeAuthPath) {
        $existing = Read-CodecuxJsonFile -Path $Paths.OpencodeAuthPath
        foreach ($property in $existing.PSObject.Properties) {
            $authMap[$property.Name] = $property.Value
        }
    }
    $authMap['openai'] = ConvertTo-CodecuxOpencodeProviderAuthObject -CanonicalAuth $CanonicalAuth
    Write-CodecuxUtf8File -Path $Paths.OpencodeAuthPath -Content ($authMap | ConvertTo-Json -Depth 10)
}

function Test-CodecuxShouldSyncOpencode {
    param([Parameter(Mandatory = $true)]$Paths)

    if (Test-Path $Paths.OpencodeAuthPath) { return $true }
    if (Test-Path $Paths.OpencodeRoot) { return $true }
    ($null -ne (Get-Command opencode -ErrorAction SilentlyContinue))
}

function Use-CodecuxProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$StoreRoot,
        [string]$CodexRoot,
        [string]$OpencodeRoot
    )

    $paths = Ensure-CodecuxStore -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    $manifest = Get-CodecuxProfileManifest -Name $Name -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    $profileAuthPath = Get-CodecuxProfileAuthPath -Name $Name -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    if (-not (Test-Path $profileAuthPath)) { throw "Profile '$Name' is missing its auth.json payload." }

    $canonicalAuth = ConvertTo-CodecuxCanonicalAuthObject -RawAuthObject (Read-CodecuxJsonFile -Path $profileAuthPath)
    $codexBackup = Backup-CodecuxFile -Path $paths.CodexAuthPath -Label 'codex-auth' -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    $shouldSyncOpencode = Test-CodecuxShouldSyncOpencode -Paths $paths
    $opencodeBackup = if ($shouldSyncOpencode) {
        Backup-CodecuxFile -Path $paths.OpencodeAuthPath -Label 'opencode-auth' -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    }
    else {
        $null
    }

    try {
        Set-CodecuxCodexAuth -CanonicalAuth $canonicalAuth -Paths $paths
        if ($shouldSyncOpencode) {
            Set-CodecuxOpencodeAuth -CanonicalAuth $canonicalAuth -Paths $paths
        }
    }
    catch {
        Restore-CodecuxFile -TargetPath $paths.CodexAuthPath -BackupPath $codexBackup
        if ($shouldSyncOpencode) {
            Restore-CodecuxFile -TargetPath $paths.OpencodeAuthPath -BackupPath $opencodeBackup
        }
        throw
    }

    Save-CodecuxState -State ([ordered]@{
        current_profile  = $manifest.name
        updated_at       = (Get-Date).ToUniversalTime().ToString('o')
        codex_backup     = $codexBackup
        opencode_backup  = $opencodeBackup
    }) -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot

    [pscustomobject]@{
        Name              = $manifest.name
        Type              = $manifest.type
        CodexBackupPath   = $codexBackup
        OpencodeBackupPath = $opencodeBackup
    }
}

function Rename-CodecuxProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$NewName,
        [string]$StoreRoot,
        [string]$CodexRoot,
        [string]$OpencodeRoot
    )

    Test-CodecuxProfileName -Name $Name
    Test-CodecuxProfileName -Name $NewName
    $paths = Ensure-CodecuxStore -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    $sourceDir = Get-CodecuxProfileDir -Name $Name -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    $targetDir = Get-CodecuxProfileDir -Name $NewName -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    if (-not (Test-Path $sourceDir)) { throw "Profile '$Name' was not found." }
    if (Test-Path $targetDir) { throw "Profile '$NewName' already exists." }

    Move-Item -Path $sourceDir -Destination $targetDir
    $manifestPath = Join-Path $targetDir 'profile.json'
    $manifest = ConvertTo-CodecuxProfileManifestRecord -Manifest (Read-CodecuxJsonFile -Path $manifestPath)
    $manifest.name = $NewName
    $manifest.schema_version = $script:CodecuxStoreSchemaVersion
    Write-CodecuxUtf8File -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 10)

    $state = Get-CodecuxState -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    if ($state.current_profile -eq $Name) {
        $state.current_profile = $NewName
        $state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
        Save-CodecuxState -State $state -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    }

    $manifest
}

function Remove-CodecuxProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)

    $paths = Ensure-CodecuxStore -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    $profileDir = Get-CodecuxProfileDir -Name $Name -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    if (-not (Test-Path $profileDir)) { throw "Profile '$Name' was not found." }
    Remove-Item -Path $profileDir -Recurse -Force

    $state = Get-CodecuxState -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    if ($state.current_profile -eq $Name) {
        $state.current_profile = ''
        $state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
        Save-CodecuxState -State $state -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    }

    [pscustomobject]@{ name = $Name; removed = $true }
}

function Get-CodecuxCurrentTargetSummary {
    param([string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)

    $paths = Resolve-CodecuxPaths -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    $codexAuth = Get-CodecuxActiveCodexAuthObject -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    $opencodeAuth = Get-CodecuxActiveOpencodeAuthObject -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot

    $codexFingerprint = if ($null -ne $codexAuth) { Get-CodecuxAuthFingerprint -AuthObject $codexAuth } else { $null }
    $opencodeFingerprint = if ($null -ne $opencodeAuth) { Get-CodecuxAuthFingerprint -AuthObject $opencodeAuth } else { $null }

    [pscustomobject]@{
        CodexFingerprint    = $codexFingerprint
        OpencodeFingerprint = $opencodeFingerprint
        CodexProfile        = if ($null -ne $codexFingerprint) { Find-CodecuxProfileByFingerprint -Fingerprint $codexFingerprint -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot } else { $null }
        OpencodeProfile     = if ($null -ne $opencodeFingerprint) { Find-CodecuxProfileByFingerprint -Fingerprint $opencodeFingerprint -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot } else { $null }
        TargetsInSync       = ($null -ne $codexFingerprint -and $codexFingerprint -eq $opencodeFingerprint)
        DriftDetected       = ($null -ne $codexFingerprint -and $null -ne $opencodeFingerprint -and $codexFingerprint -ne $opencodeFingerprint)
    }
}

function Get-CodecuxCurrentProfile {
    [CmdletBinding()]
    param([string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)

    $summary = Get-CodecuxCurrentTargetSummary -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    if ($summary.DriftDetected) { return $null }
    if ($summary.TargetsInSync -and $null -ne $summary.CodexProfile) { return $summary.CodexProfile }
    if ($null -ne $summary.CodexProfile) { return $summary.CodexProfile }
    if ($null -ne $summary.OpencodeProfile) { return $summary.OpencodeProfile }
    if ($null -ne $summary.CodexFingerprint -or $null -ne $summary.OpencodeFingerprint) { return $null }

    $paths = Resolve-CodecuxPaths -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    $state = Get-CodecuxState -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    if (-not [string]::IsNullOrWhiteSpace([string]$state.current_profile)) {
        $profileDir = Get-CodecuxProfileDir -Name ([string]$state.current_profile) -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
        if (Test-Path $profileDir) {
            return (Get-CodecuxProfileManifest -Name ([string]$state.current_profile) -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot)
        }
    }

    $null
}

function Get-CodecuxStatus {
    [CmdletBinding()]
    param([string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)
    $paths = Resolve-CodecuxPaths -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    $current = Get-CodecuxCurrentProfile -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    $profiles = Get-CodecuxProfiles -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    $summary = Get-CodecuxCurrentTargetSummary -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    [pscustomobject]@{
        CurrentProfile    = if ($null -ne $current) { $current.name } else { '' }
        ProfileCount      = @($profiles).Count
        CodexInstalled    = ($null -ne (Get-Command codex -ErrorAction SilentlyContinue))
        OpencodeInstalled = ($null -ne (Get-Command opencode -ErrorAction SilentlyContinue))
        CodexAuthPath     = $paths.CodexAuthPath
        OpencodeAuthPath  = $paths.OpencodeAuthPath
        StoreRoot         = $paths.StoreRoot
        TargetsInSync     = $summary.TargetsInSync
        DriftDetected     = $summary.DriftDetected
        CodexProfile      = if ($null -ne $summary.CodexProfile) { $summary.CodexProfile.name } else { '' }
        OpencodeProfile   = if ($null -ne $summary.OpencodeProfile) { $summary.OpencodeProfile.name } else { '' }
    }
}
