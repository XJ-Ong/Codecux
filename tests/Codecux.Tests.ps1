Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\src\Codecux.psm1'
Import-Module $modulePath -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message`nExpected: $Expected`nActual:   $Actual" }
}

function Assert-FileHasNoUtf8Bom {
    param([string]$Path, [string]$Message)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if ($hasBom) { throw $Message }
}

function New-TestJwtToken {
    param([string]$AccountId, [int64]$Exp = 1775000000)
    $headerJson = '{"alg":"none","typ":"JWT"}'
    $payloadJson = ([ordered]@{
        exp = $Exp
        'https://api.openai.com/auth' = [ordered]@{
            chatgpt_account_id = $AccountId
        }
    } | ConvertTo-Json -Depth 5 -Compress)
    $encode = {
        param([string]$Text)
        [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
    "$(& $encode $headerJson).$(& $encode $payloadJson).signature"
}

function New-TestAuthFile {
    param([string]$Path, [string]$AccountId, [string]$RefreshToken)
    $payload = [ordered]@{
        auth_mode    = 'chatgpt'
        last_refresh = '2026-03-19T00:00:00Z'
        tokens       = [ordered]@{
            access_token  = (New-TestJwtToken -AccountId $AccountId)
            account_id    = $AccountId
            id_token      = 'id-token'
            refresh_token = $RefreshToken
        }
    }
    $payload | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
}

function New-TestOpencodeAuthFile {
    param([string]$Path, [string]$AccountId, [string]$RefreshToken)
    $payload = [ordered]@{
        openai = [ordered]@{
            type      = 'oauth'
            access    = (New-TestJwtToken -AccountId $AccountId)
            refresh   = $RefreshToken
            expires   = 1775000000000
            accountId = $AccountId
        }
    }
    $payload | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
}

function New-TestCanonicalOAuthProfileFile {
    param([string]$Path, [string]$AccountId, [string]$RefreshToken, [string]$IdToken = '', [int64]$Expires = 1775000000000)
    $payload = [ordered]@{
        type      = 'oauth'
        access    = (New-TestJwtToken -AccountId $AccountId)
        refresh   = $RefreshToken
        expires   = $Expires
        accountId = $AccountId
    }
    if (-not [string]::IsNullOrWhiteSpace($IdToken)) {
        $payload.idToken = $IdToken
    }
    $payload | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
}

function New-TestCodexRateLimitResponse {
    param(
        [int]$UsedPercent = 43,
        [int64]$ResetsAt = 0,
        [int]$WindowDurationMins = 10080,
        [string]$LimitId = 'codex',
        [string]$PlanType = 'free'
    )

    $snapshot = [pscustomobject]@{
        limitId   = $LimitId
        limitName = 'Codex'
        planType  = $PlanType
        primary   = [pscustomobject]@{
            usedPercent        = $UsedPercent
            windowDurationMins = $WindowDurationMins
            resetsAt           = $ResetsAt
        }
        secondary = $null
        credits   = $null
    }

    [pscustomobject]@{
        rateLimits = $snapshot
        rateLimitsByLimitId = [pscustomobject]@{
            codex = $snapshot
        }
    }
}

function New-TestEnvironment {
    $base = Join-Path $env:TEMP ("codecux-tests-" + [guid]::NewGuid().ToString('N'))
    $cuxRoot = Join-Path $base '.cux'
    $codexRoot = Join-Path $base '.codex'
    $opencodeRoot = Join-Path $base '.local\share\opencode'
    New-Item -ItemType Directory -Force -Path $cuxRoot, $codexRoot, $opencodeRoot | Out-Null
    [pscustomobject]@{
        BasePath         = $base
        CuxRoot          = $cuxRoot
        CodexRoot        = $codexRoot
        AuthPath         = (Join-Path $codexRoot 'auth.json')
        OpencodeRoot     = $opencodeRoot
        OpencodeAuthPath = (Join-Path $opencodeRoot 'auth.json')
    }
}

function Remove-TestEnvironment {
    param($EnvInfo)
    if ($EnvInfo -and (Test-Path $EnvInfo.BasePath)) {
        Remove-Item -Path $EnvInfo.BasePath -Recurse -Force
    }
}

function Invoke-CliForTest {
    param([string[]]$Arguments)
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\bin\cux.ps1') @Arguments 2>&1 | Out-String
    }
    catch {
        $_ | Out-String
    }
}

function Get-CliModulePath {
    Join-Path $PSScriptRoot '..\src\Codecux.Cli.psm1'
}

function Get-ScriptLineMatchingPattern {
    param([string]$Path, [string]$Pattern)
    $match = Select-String -Path $Path -Pattern $Pattern
    if ($null -eq $match) {
        throw ("Could not find pattern '{0}' in {1}" -f $Pattern, $Path)
    }
    [string]$match.Line.Trim()
}

function Invoke-PowerShellSelectionLine {
    param(
        [string]$Line,
        [bool]$PwshAvailable,
        [string]$PwshSource = 'C:\Program Files\PowerShell\7\pwsh.exe'
    )

    & {
        param($Line, $PwshAvailable, $PwshSource)
        function Get-Command {
            param([string]$Name)
            if ($Name -eq 'pwsh' -and $PwshAvailable) {
                return [pscustomobject]@{ Source = $PwshSource }
            }
            $null
        }

        Invoke-Expression $Line
        $psExe
    } $Line $PwshAvailable $PwshSource
}

function Invoke-InstallScriptForTest {
    param([string]$HomePath, [string]$LocalAppDataPath)

    $installScript = Join-Path $PSScriptRoot '..\scripts\install.ps1'
    $originalHome = $env:HOME
    $originalUserProfile = $env:USERPROFILE
    $originalLocalAppData = $env:LOCALAPPDATA

    try {
        $env:HOME = $HomePath
        $env:USERPROFILE = $HomePath
        $env:LOCALAPPDATA = $LocalAppDataPath
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript | Out-Null
    }
    finally {
        $env:HOME = $originalHome
        $env:USERPROFILE = $originalUserProfile
        $env:LOCALAPPDATA = $originalLocalAppData
    }
}

function Invoke-UninstallScriptForTest {
    param([string]$HomePath, [string]$LocalAppDataPath, [switch]$RemoveStore)

    $uninstallScript = Join-Path $PSScriptRoot '..\scripts\uninstall.ps1'
    $originalHome = $env:HOME
    $originalUserProfile = $env:USERPROFILE
    $originalLocalAppData = $env:LOCALAPPDATA

    try {
        $env:HOME = $HomePath
        $env:USERPROFILE = $HomePath
        $env:LOCALAPPDATA = $LocalAppDataPath
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uninstallScript)
        if ($RemoveStore) { $arguments += '-RemoveStore' }
        & powershell @arguments | Out-Null
    }
    finally {
        $env:HOME = $originalHome
        $env:USERPROFILE = $originalUserProfile
        $env:LOCALAPPDATA = $originalLocalAppData
    }
}

function Invoke-CliForTestWithHome {
    param(
        [string[]]$Arguments,
        [string]$HomePath,
        [string]$LocalAppDataPath
    )

    $cliPath = Join-Path $PSScriptRoot '..\bin\cux.ps1'
    $originalHome = $env:HOME
    $originalUserProfile = $env:USERPROFILE
    $originalLocalAppData = $env:LOCALAPPDATA

    try {
        $env:HOME = $HomePath
        $env:USERPROFILE = $HomePath
        $env:LOCALAPPDATA = $LocalAppDataPath
        & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPath @Arguments 2>&1 | Out-String
    }
    finally {
        $env:HOME = $originalHome
        $env:USERPROFILE = $originalUserProfile
        $env:LOCALAPPDATA = $originalLocalAppData
    }
}

function Invoke-CuxCompletionForTest {
    param([string]$InputScript, [int]$CursorColumn)

    . (Join-Path $PSScriptRoot '..\scripts\cux-completion.ps1')
    TabExpansion2 -inputScript $InputScript -cursorColumn $CursorColumn
}

function Test-AddProfileSavesManifestAndCanonicalAuth {
    $envInfo = New-TestEnvironment
    try {
        New-TestAuthFile -Path $envInfo.AuthPath -AccountId 'acct-01' -RefreshToken 'refresh-01'
        $result = Add-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot
        Assert-Equal $result.Name 'codex01' 'Profile name should be preserved.'
        Assert-Equal $result.Type 'chatgpt' 'Profile type should default to chatgpt.'
        $manifest = Get-Content -Raw (Join-Path $envInfo.CuxRoot 'profiles\codex01\profile.json') | ConvertFrom-Json
        Assert-Equal $manifest.fingerprint 'chatgpt:acct-01' 'ChatGPT fingerprint should use account_id when available.'
        $savedAuth = Get-Content -Raw (Join-Path $envInfo.CuxRoot 'profiles\codex01\auth.json') | ConvertFrom-Json
        Assert-Equal $savedAuth.type 'oauth' 'Profile auth.json should be canonical OAuth.'
        Assert-Equal $savedAuth.accountId 'acct-01' 'Canonical OAuth auth should preserve the account id.'
        Assert-True (-not [string]::IsNullOrWhiteSpace($savedAuth.idToken)) 'Canonical OAuth auth should preserve the Codex id token.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-AddProfileRejectsDuplicateFingerprint {
    $envInfo = New-TestEnvironment
    try {
        New-TestAuthFile -Path $envInfo.AuthPath -AccountId 'acct-dup' -RefreshToken 'refresh-01'
        Add-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        $failed = $false
        try {
            Add-CodecuxProfile -Name 'codex02' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        }
        catch {
            $failed = $true
            Assert-True ($_.Exception.Message -like '*codex01*') 'Duplicate rejection should mention the existing profile name.'
        }
        Assert-True $failed 'Duplicate auth should be rejected.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-UseProfileCopiesAuthToBothTargetsAndUpdatesCurrent {
    $envInfo = New-TestEnvironment
    try {
        New-TestAuthFile -Path $envInfo.AuthPath -AccountId 'acct-01' -RefreshToken 'refresh-01'
        Add-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        New-TestAuthFile -Path $envInfo.AuthPath -AccountId 'acct-02' -RefreshToken 'refresh-02'
        Add-CodecuxProfile -Name 'codex02' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        Use-CodecuxProfile -Name 'codex02' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        $active = Get-Content -Raw $envInfo.AuthPath | ConvertFrom-Json
        Assert-Equal $active.tokens.account_id 'acct-02' 'Using a profile should replace the active Codex auth.json.'
        Assert-True (-not [string]::IsNullOrWhiteSpace($active.tokens.id_token)) 'Using a profile should restore id_token for Codex.'
        $opencode = Get-Content -Raw $envInfo.OpencodeAuthPath | ConvertFrom-Json
        Assert-Equal $opencode.openai.accountId 'acct-02' 'Using a profile should also update OpenCode auth.'
        $state = Get-Content -Raw (Join-Path $envInfo.CuxRoot 'state.json') | ConvertFrom-Json
        Assert-Equal $state.current_profile 'codex02' 'Current profile should be updated.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-AddProfileWritesAuthWithoutUtf8Bom {
    $envInfo = New-TestEnvironment
    try {
        New-TestAuthFile -Path $envInfo.AuthPath -AccountId 'acct-01' -RefreshToken 'refresh-01'
        Add-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        Assert-FileHasNoUtf8Bom -Path (Join-Path $envInfo.CuxRoot 'profiles\codex01\auth.json') -Message 'Saved profile auth.json should be written without a UTF-8 BOM.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-UseProfileRewritesBothTargetsWithoutUtf8Bom {
    $envInfo = New-TestEnvironment
    try {
        $profileDir = Join-Path $envInfo.CuxRoot 'profiles\codex01'
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
        New-TestCanonicalOAuthProfileFile -Path (Join-Path $profileDir 'auth.json') -AccountId 'acct-01' -RefreshToken 'refresh-01' -IdToken 'id-token'
        ([ordered]@{
            name        = 'codex01'
            type        = 'chatgpt'
            fingerprint = 'chatgpt:acct-01'
            saved_at    = '2026-03-19T00:00:00Z'
            display     = 'acct-01'
        } | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $profileDir 'profile.json') -Encoding UTF8
        Use-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        Assert-FileHasNoUtf8Bom -Path $envInfo.AuthPath -Message 'Active Codex auth.json should be written without a UTF-8 BOM.'
        Assert-FileHasNoUtf8Bom -Path $envInfo.OpencodeAuthPath -Message 'Active OpenCode auth.json should be written without a UTF-8 BOM.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-AddProfileFailsWhenOnlyOpencodeOAuthExists {
    $envInfo = New-TestEnvironment
    try {
        New-TestOpencodeAuthFile -Path $envInfo.OpencodeAuthPath -AccountId 'acct-01' -RefreshToken 'refresh-01'
        $failed = $false
        try {
            Add-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        }
        catch {
            $failed = $true
            Assert-True ($_.Exception.Message -like '*Codex CLI*id_token*') 'Opencode-only OAuth add failure should explain the missing Codex id token.'
        }
        Assert-True $failed 'Adding a chatgpt profile from OpenCode-only OAuth should fail.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-AddProfilePrefersCodexWhenOpenCodeMismatches {
    $envInfo = New-TestEnvironment
    try {
        New-TestAuthFile -Path $envInfo.AuthPath -AccountId 'acct-codex' -RefreshToken 'refresh-codex'
        New-TestOpencodeAuthFile -Path $envInfo.OpencodeAuthPath -AccountId 'acct-opencode' -RefreshToken 'refresh-opencode'

        $result = Add-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot
        Assert-Equal $result.fingerprint 'chatgpt:acct-codex' 'When Codex and OpenCode differ, add should save the current Codex account.'

        $savedAuth = Get-Content -Raw (Join-Path $envInfo.CuxRoot 'profiles\codex01\auth.json') | ConvertFrom-Json
        Assert-Equal $savedAuth.accountId 'acct-codex' 'Saved profile auth should come from Codex, not the mismatched OpenCode login.'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$savedAuth.idToken)) 'Codex-first add should preserve the Codex id token.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-UseProfileFailsWhenCanonicalOAuthIsMissingIdToken {
    $envInfo = New-TestEnvironment
    try {
        $profileDir = Join-Path $envInfo.CuxRoot 'profiles\broken'
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
        New-TestCanonicalOAuthProfileFile -Path (Join-Path $profileDir 'auth.json') -AccountId 'acct-01' -RefreshToken 'refresh-01'
        ([ordered]@{
            name        = 'broken'
            type        = 'chatgpt'
            fingerprint = 'chatgpt:acct-01'
            saved_at    = '2026-03-20T00:00:00Z'
            display     = 'acct-01'
        } | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $profileDir 'profile.json') -Encoding UTF8

        $failed = $false
        try {
            Use-CodecuxProfile -Name 'broken' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        }
        catch {
            $failed = $true
            Assert-True ($_.Exception.Message -like '*id token*') 'Missing canonical idToken should fail with a clear Codex message.'
        }

        Assert-True $failed 'Using an OAuth profile without idToken should fail.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-UseProfileRollsBackWhenOpencodeWriteFails {
    $envInfo = New-TestEnvironment
    try {
        New-TestAuthFile -Path $envInfo.AuthPath -AccountId 'acct-live' -RefreshToken 'refresh-live'
        New-TestOpencodeAuthFile -Path $envInfo.OpencodeAuthPath -AccountId 'acct-live' -RefreshToken 'refresh-live-op'
        Add-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null

        New-TestAuthFile -Path $envInfo.AuthPath -AccountId 'acct-badtarget' -RefreshToken 'refresh-bad'
        'not-json' | Set-Content -Path $envInfo.OpencodeAuthPath -Encoding UTF8

        $failed = $false
        try {
            Use-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        }
        catch {
            $failed = $true
        }

        Assert-True $failed 'Use should fail when the OpenCode target cannot be updated.'
        $active = Get-Content -Raw $envInfo.AuthPath | ConvertFrom-Json
        Assert-Equal $active.tokens.account_id 'acct-badtarget' 'Codex auth should be rolled back on failure.'
        Assert-Equal (Get-Content -Raw $envInfo.OpencodeAuthPath) "not-json`r`n" 'OpenCode auth should be restored on failure.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-GetCurrentProfileDoesNotFallBackToStateWhenLiveAuthIsUnmatched {
    $envInfo = New-TestEnvironment
    try {
        New-TestAuthFile -Path $envInfo.AuthPath -AccountId 'acct-01' -RefreshToken 'refresh-01'
        Add-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        Use-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null

        New-TestAuthFile -Path $envInfo.AuthPath -AccountId 'acct-unsaved' -RefreshToken 'refresh-unsaved'
        if (Test-Path $envInfo.OpencodeAuthPath) {
            Remove-Item -Path $envInfo.OpencodeAuthPath -Force
        }

        $current = Get-CodecuxCurrentProfile -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot
        Assert-True ($null -eq $current) 'Unmatched live auth should not fall back to the last saved state current_profile.'

        $status = Get-CodecuxStatus -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot
        Assert-True ([string]::IsNullOrWhiteSpace([string]$status.CurrentProfile)) 'Status should not report a current profile when live auth does not match any saved profile.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-AddAndUseProfileDoNotCreateOpencodeRootWhenAbsent {
    $base = Join-Path $env:TEMP ("codecux-opencode-absent-" + [guid]::NewGuid().ToString('N'))
    $cuxRoot = Join-Path $base '.cux'
    $codexRoot = Join-Path $base '.codex'
    $opencodeRoot = Join-Path $base '.local\share\opencode'
    $authPath = Join-Path $codexRoot 'auth.json'
    $originalPath = $env:PATH

    try {
        $env:PATH = $codexRoot
        New-Item -ItemType Directory -Force -Path $codexRoot | Out-Null
        New-TestAuthFile -Path $authPath -AccountId 'acct-01' -RefreshToken 'refresh-01'

        Add-CodecuxProfile -Name 'codex01' -StoreRoot $cuxRoot -CodexRoot $codexRoot -OpencodeRoot $opencodeRoot | Out-Null
        Assert-True (-not (Test-Path $opencodeRoot)) 'Adding a profile should not create the OpenCode root when OpenCode is absent.'

        Use-CodecuxProfile -Name 'codex01' -StoreRoot $cuxRoot -CodexRoot $codexRoot -OpencodeRoot $opencodeRoot | Out-Null
        Assert-True (-not (Test-Path $opencodeRoot)) 'Using a profile should not create the OpenCode root when OpenCode is absent.'
        Assert-True (-not (Test-Path (Join-Path $opencodeRoot 'auth.json'))) 'Using a profile should not create OpenCode auth.json when OpenCode is absent.'
    }
    finally {
        $env:PATH = $originalPath
        if (Test-Path $base) {
            Remove-Item -Path $base -Recurse -Force
        }
    }
}

function Test-GetStateNormalizesLegacyStateFile {
    $envInfo = New-TestEnvironment
    try {
        $statePath = Join-Path $envInfo.CuxRoot 'state.json'
        ([ordered]@{
            current_profile = 'codex01'
            updated_at = '2026-03-31T00:00:00Z'
        } | ConvertTo-Json -Depth 5) | Set-Content -Path $statePath -Encoding UTF8

        $state = Get-CodecuxState -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot
        Assert-Equal $state.schema_version 1 'Legacy state should be normalized to schema version 1 in memory.'
        Assert-Equal $state.current_profile 'codex01' 'Legacy state should preserve the current profile value.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-GetProfileManifestNormalizesLegacyManifest {
    $envInfo = New-TestEnvironment
    try {
        $profileDir = Join-Path $envInfo.CuxRoot 'profiles\legacy'
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
        ([ordered]@{
            name = 'legacy'
            type = 'chatgpt'
            fingerprint = 'chatgpt:acct-legacy'
            saved_at = '2026-03-31T00:00:00Z'
            display = 'acct-legacy'
        } | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $profileDir 'profile.json') -Encoding UTF8

        $manifest = Get-CodecuxProfileManifest -Name 'legacy' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot
        Assert-Equal $manifest.schema_version 1 'Legacy profile manifests should be normalized to schema version 1 in memory.'
        Assert-Equal $manifest.name 'legacy' 'Legacy profile manifests should preserve the profile name.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-GetStateRejectsUnsupportedSchemaVersion {
    $envInfo = New-TestEnvironment
    try {
        $statePath = Join-Path $envInfo.CuxRoot 'state.json'
        ([ordered]@{
            schema_version = 99
            current_profile = 'codex01'
            updated_at = '2026-03-31T00:00:00Z'
        } | ConvertTo-Json -Depth 5) | Set-Content -Path $statePath -Encoding UTF8

        $failed = $false
        try {
            Get-CodecuxState -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        }
        catch {
            $failed = $true
            Assert-True ($_.Exception.Message -like '*schema version*') 'Unsupported state schema failures should mention the schema version.'
        }
        Assert-True $failed 'Unsupported state schema versions should be rejected.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-GetProfileManifestRejectsUnsupportedSchemaVersion {
    $envInfo = New-TestEnvironment
    try {
        $profileDir = Join-Path $envInfo.CuxRoot 'profiles\future'
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
        ([ordered]@{
            schema_version = 99
            name = 'future'
            type = 'chatgpt'
            fingerprint = 'chatgpt:acct-future'
            saved_at = '2026-03-31T00:00:00Z'
            display = 'acct-future'
        } | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $profileDir 'profile.json') -Encoding UTF8

        $failed = $false
        try {
            Get-CodecuxProfileManifest -Name 'future' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        }
        catch {
            $failed = $true
            Assert-True ($_.Exception.Message -like '*schema version*') 'Unsupported manifest schema failures should mention the schema version.'
        }
        Assert-True $failed 'Unsupported manifest schema versions should be rejected.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-UseProfileFailsWhenCanonicalOAuthIsMissingRefreshToken {
    $envInfo = New-TestEnvironment
    try {
        $profileDir = Join-Path $envInfo.CuxRoot 'profiles\broken'
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
        ([ordered]@{
            schema_version = 1
            name = 'broken'
            type = 'chatgpt'
            fingerprint = 'chatgpt:acct-broken'
            saved_at = '2026-03-31T00:00:00Z'
            display = 'acct-broken'
        } | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $profileDir 'profile.json') -Encoding UTF8
        ([ordered]@{
            type = 'oauth'
            access = (New-TestJwtToken -AccountId 'acct-broken')
            expires = 1775000000000
            accountId = 'acct-broken'
            idToken = 'id-token'
        } | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $profileDir 'auth.json') -Encoding UTF8

        $failed = $false
        try {
            Use-CodecuxProfile -Name 'broken' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        }
        catch {
            $failed = $true
            Assert-True ($_.Exception.Message -like '*refresh*') 'Malformed canonical OAuth auth should mention the missing refresh token.'
        }
        Assert-True $failed 'Using a profile with malformed canonical OAuth auth should fail.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-GetDashboardSnapshotHandlesCanonicalAuthValidationFailure {
    $envInfo = New-TestEnvironment
    try {
        $profileDir = Join-Path $envInfo.CuxRoot 'profiles\broken'
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
        ([ordered]@{
            schema_version = 1
            name = 'broken'
            type = 'chatgpt'
            fingerprint = 'chatgpt:acct-broken'
            saved_at = '2026-03-31T00:00:00Z'
            display = 'acct-broken'
        } | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $profileDir 'profile.json') -Encoding UTF8
        ([ordered]@{
            type = 'oauth'
            refresh = 'refresh-token'
            expires = 1775000000000
            accountId = 'acct-broken'
            idToken = 'id-token'
        } | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $profileDir 'auth.json') -Encoding UTF8

        $snapshot = Get-CodecuxDashboardSnapshot -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot
        $row = $snapshot.Rows | Where-Object Name -eq 'broken'
        Assert-Equal $row.RowStatus 'ERR' 'Canonical auth validation failures should degrade to an error row instead of crashing the dashboard.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-RenameProfileMovesDirectoryAndState {
    $envInfo = New-TestEnvironment
    try {
        New-TestAuthFile -Path $envInfo.AuthPath -AccountId 'acct-01' -RefreshToken 'refresh-01'
        Add-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        Use-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        Rename-CodecuxProfile -Name 'codex01' -NewName 'personal' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        Assert-True (Test-Path (Join-Path $envInfo.CuxRoot 'profiles\personal\profile.json')) 'Renamed profile directory should exist.'
        Assert-True (-not (Test-Path (Join-Path $envInfo.CuxRoot 'profiles\codex01'))) 'Old profile directory should be removed.'
        $state = Get-Content -Raw (Join-Path $envInfo.CuxRoot 'state.json') | ConvertFrom-Json
        Assert-Equal $state.current_profile 'personal' 'Renaming the current profile should update state.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-RemoveProfileDeletesFilesAndClearsCurrentWhenNeeded {
    $envInfo = New-TestEnvironment
    try {
        New-TestAuthFile -Path $envInfo.AuthPath -AccountId 'acct-01' -RefreshToken 'refresh-01'
        Add-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        Use-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        Remove-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        Assert-True (-not (Test-Path (Join-Path $envInfo.CuxRoot 'profiles\codex01'))) 'Removed profile directory should be deleted.'
        $state = Get-Content -Raw (Join-Path $envInfo.CuxRoot 'state.json') | ConvertFrom-Json
        Assert-True ([string]::IsNullOrWhiteSpace($state.current_profile)) 'Removing the current profile should clear current_profile.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-AddApiKeyProfileStoresMaskedMetadataAndGeneratedAuth {
    $envInfo = New-TestEnvironment
    try {
        $result = Add-CodecuxProfile -Name 'api01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot -ApiKey 'sk-test-123456'
        Assert-Equal $result.Type 'apikey' 'API-key profile type should be apikey.'
        $manifest = Get-Content -Raw (Join-Path $envInfo.CuxRoot 'profiles\api01\profile.json') | ConvertFrom-Json
        Assert-Equal $manifest.type 'apikey' 'Manifest type should be apikey.'
        Assert-True ($manifest.display -like 'sk-test*') 'Manifest should keep a masked display value.'
        Use-CodecuxProfile -Name 'api01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        $active = Get-Content -Raw $envInfo.AuthPath | ConvertFrom-Json
        Assert-Equal $active.OPENAI_API_KEY 'sk-test-123456' 'Using an API-key profile should write OPENAI_API_KEY into Codex auth.json.'
        $opencode = Get-Content -Raw $envInfo.OpencodeAuthPath | ConvertFrom-Json
        Assert-Equal $opencode.openai.type 'api' 'Using an API-key profile should write OpenCode API auth.'
        Assert-Equal $opencode.openai.key 'sk-test-123456' 'Using an API-key profile should write the OpenCode API key.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-ReadOnlyOperationsDoNotCreateStateFile {
    $envInfo = New-TestEnvironment
    try {
        Get-CodecuxDoctor -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        Get-CodecuxCurrentProfile -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        Assert-True (-not (Test-Path (Join-Path $envInfo.CuxRoot 'state.json'))) 'Read-only operations should not create state.json.'
    }
    finally { Remove-TestEnvironment $envInfo }
}


function Test-ConvertRateLimitResponseComputesLeftPercentAndResetDisplay {
    $resetAt = [DateTimeOffset]::Parse('2026-03-27T18:04:00+08:00').ToUnixTimeSeconds()
    $response = New-TestCodexRateLimitResponse -UsedPercent 43 -ResetsAt $resetAt -WindowDurationMins 10080

    $quota = ConvertTo-CodecuxRateLimitProbeResult -RateLimitResponse $response

    Assert-Equal $quota.Status 'OK' 'Normalized rate-limit result should be OK when a primary window exists.'
    Assert-Equal $quota.PercentLeft 57 'Percent left should be computed as 100 - usedPercent.'
    Assert-Equal $quota.PercentDisplay '57%' 'Percent display should render with a percent sign.'
    $expectedReset = ([DateTimeOffset]::FromUnixTimeSeconds($resetAt).ToLocalTime().ToString('dd MMM HH:mm'))
    Assert-Equal $quota.ResetDisplay $expectedReset 'Reset display should format the reset timestamp in local time.'
}

function Test-GetDashboardSnapshotUsesProbeResultsAndMarksCurrentProfile {
    $envInfo = New-TestEnvironment
    try {
        $profilesRoot = Join-Path $envInfo.CuxRoot 'profiles'
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

        $validDir = Join-Path $profilesRoot 'valid'
        New-Item -ItemType Directory -Force -Path $validDir | Out-Null
        New-TestCanonicalOAuthProfileFile -Path (Join-Path $validDir 'auth.json') -AccountId 'acct-valid' -RefreshToken 'refresh-valid' -IdToken 'id-valid' -Expires ($nowMs + 3600000)
        ([ordered]@{ name='valid'; type='chatgpt'; fingerprint='chatgpt:acct-valid'; saved_at='2026-03-20T00:00:00Z'; display='acct-valid' } | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $validDir 'profile.json') -Encoding UTF8

        $expiredDir = Join-Path $profilesRoot 'expired'
        New-Item -ItemType Directory -Force -Path $expiredDir | Out-Null
        New-TestCanonicalOAuthProfileFile -Path (Join-Path $expiredDir 'auth.json') -AccountId 'acct-expired' -RefreshToken 'refresh-expired' -IdToken 'id-expired' -Expires ($nowMs - 60000)
        ([ordered]@{ name='expired'; type='chatgpt'; fingerprint='chatgpt:acct-expired'; saved_at='2026-03-20T00:00:00Z'; display='acct-expired' } | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $expiredDir 'profile.json') -Encoding UTF8

        Use-CodecuxProfile -Name 'valid' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null

        $probeResults = @{
            valid = [pscustomobject]@{ Status='OK'; PercentLeft=57; PercentDisplay='57%'; ResetDisplay='27 Mar 18:04'; WindowLabel='weekly'; LastUpdatedAt='2026-03-21 03:00:00' }
            expired = [pscustomobject]@{ Status='AUTH'; PercentLeft=$null; PercentDisplay='--'; ResetDisplay='--'; WindowLabel=''; LastUpdatedAt='2026-03-21 03:00:00' }
        }

        $snapshot = Get-CodecuxDashboardSnapshot -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot -ProbeResults $probeResults
        $valid = $snapshot.Rows | Where-Object Name -eq 'valid'
        $expired = $snapshot.Rows | Where-Object Name -eq 'expired'

        Assert-Equal $valid.QuotaDisplay '57%' 'Dashboard snapshot should use injected quota displays for each row.'
        Assert-Equal $valid.RowStatus 'OK' 'Dashboard snapshot should surface the normalized row status.'
        Assert-True $valid.IsCurrent 'Current profile row should be marked current.'
        Assert-Equal $expired.RowStatus 'AUTH' 'Dashboard snapshot should preserve per-row auth failures.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-FormatDashboardRendersCurrentMarkerAndUnicodeQuotaBar {
    $snapshot = [pscustomobject]@{
        Title = 'Codecux Dashboard'
        CurrentProfile = 'valid'
        DriftDetected = $false
        TargetsInSync = $true
        LastRefreshDisplay = '2026-03-20 20:00:00'
        Rows = @(
            [pscustomobject]@{ Name='valid'; Type='chatgpt'; TargetStatus='SYNC'; QuotaDisplay='57%'; ResetDisplay='27 Mar 18:04'; RowStatus='OK'; IsCurrent=$true },
            [pscustomobject]@{ Name='expired'; Type='chatgpt'; TargetStatus='--'; QuotaDisplay='--'; ResetDisplay='--'; RowStatus='AUTH'; IsCurrent=$false }
        )
    }

    $rendered = Format-CodecuxDashboard -Snapshot $snapshot -SelectedIndex 1 -Width 112
    Assert-True ($rendered -like '*Codecux Dashboard*') 'Rendered dashboard should include the title.'
    Assert-True ($rendered -like '*Profile*Left*Reset*State*') 'Rendered dashboard should include the quota-oriented columns.'
    Assert-True ($rendered.Contains('┌')) 'Rendered dashboard should use Unicode box drawing.'
    Assert-True ($rendered -like '*● valid*▰▰▰▰▰▰▰*57%*OK*') 'Rendered dashboard should show a persistent active marker and a pill-style bar-first quota cell.'
    Assert-True ($rendered -like '*▶ expired*') 'Rendered dashboard should mark the selected row with a Unicode cursor.'
    Assert-True ($rendered -like '*Keys: ↑/↓ Select  U Use  R Refresh All  Q Quit*') 'Rendered dashboard should show Unicode arrow key hints.'
    Assert-True (-not $rendered.Contains('?')) 'Rendered dashboard should not contain placeholder question marks.'
}

function Test-SetDashboardCurrentProfileNameUpdatesMarkersWithoutClearingQuota {
    $snapshot = [pscustomobject]@{
        Title = 'Codecux Dashboard'
        CurrentProfile = 'valid'
        DriftDetected = $false
        TargetsInSync = $true
        LastRefreshDisplay = '2026-03-20 20:00:00'
        Rows = @(
            [pscustomobject]@{ Name='valid'; Type='chatgpt'; TargetStatus='SYNC'; QuotaDisplay='57%'; ResetDisplay='27 Mar 18:04'; RowStatus='OK'; LastUpdatedAt='2026-03-20 20:00:00'; IsCurrent=$true },
            [pscustomobject]@{ Name='expired'; Type='chatgpt'; TargetStatus='--'; QuotaDisplay='12%'; ResetDisplay='29 Mar 09:30'; RowStatus='AUTH'; LastUpdatedAt='2026-03-20 20:00:00'; IsCurrent=$false }
        )
    }

    $updated = Set-CodecuxDashboardCurrentProfileName -Snapshot $snapshot -CurrentProfileName 'expired'
    $valid = $updated.Rows | Where-Object Name -eq 'valid'
    $expired = $updated.Rows | Where-Object Name -eq 'expired'

    Assert-Equal $updated.CurrentProfile 'expired' 'Current profile name should update on the snapshot.'
    Assert-True (-not $valid.IsCurrent) 'Previous current row should be cleared.'
    Assert-True $expired.IsCurrent 'New current row should be marked current.'
    Assert-Equal $valid.QuotaDisplay '57%' 'Changing the current marker should preserve existing quota data.'
    Assert-Equal $expired.QuotaDisplay '12%' 'Changing the current marker should not clear other row data.'
}

function Test-SetDashboardCurrentProfileNameMovesSyncTargetStatus {
    $snapshot = [pscustomobject]@{
        Title = 'Codecux Dashboard'
        CurrentProfile = 'valid'
        DriftDetected = $false
        TargetsInSync = $true
        LastRefreshDisplay = '2026-03-20 20:00:00'
        Rows = @(
            [pscustomobject]@{ Name='valid'; Type='chatgpt'; TargetStatus='SYNC'; QuotaDisplay='57%'; ResetDisplay='27 Mar 18:04'; RowStatus='OK'; LastUpdatedAt='2026-03-20 20:00:00'; IsCurrent=$true },
            [pscustomobject]@{ Name='expired'; Type='chatgpt'; TargetStatus='--'; QuotaDisplay='12%'; ResetDisplay='29 Mar 09:30'; RowStatus='AUTH'; LastUpdatedAt='2026-03-20 20:00:00'; IsCurrent=$false }
        )
    }

    $updated = Set-CodecuxDashboardCurrentProfileName -Snapshot $snapshot -CurrentProfileName 'expired'
    $valid = $updated.Rows | Where-Object Name -eq 'valid'
    $expired = $updated.Rows | Where-Object Name -eq 'expired'

    Assert-Equal $valid.TargetStatus '--' 'The previous current row should lose the SYNC target marker.'
    Assert-Equal $expired.TargetStatus 'SYNC' 'The new current row should become the SYNC target.'
}

function Test-UpdateDashboardSnapshotRowPreservesOtherRows {
    $snapshot = [pscustomobject]@{
        Title = 'Codecux Dashboard'
        CurrentProfile = 'valid'
        DriftDetected = $false
        TargetsInSync = $true
        LastRefreshDisplay = '2026-03-20 20:00:00'
        Rows = @(
            [pscustomobject]@{ Name='valid'; Type='chatgpt'; TargetStatus='SYNC'; QuotaDisplay='57%'; ResetDisplay='27 Mar 18:04'; RowStatus='OK'; LastUpdatedAt='2026-03-20 20:00:00'; IsCurrent=$true },
            [pscustomobject]@{ Name='expired'; Type='chatgpt'; TargetStatus='--'; QuotaDisplay='12%'; ResetDisplay='29 Mar 09:30'; RowStatus='AUTH'; LastUpdatedAt='2026-03-20 20:00:00'; IsCurrent=$false }
        )
    }

    $probeResult = [pscustomobject]@{
        Status = 'OK'
        PercentDisplay = '68%'
        ResetDisplay = '30 Mar 10:45'
        LastUpdatedAt = '2026-03-21 10:45:00'
    }

    $updated = Update-CodecuxDashboardSnapshotRow -Snapshot $snapshot -ProfileName 'expired' -ProbeResult $probeResult
    $valid = $updated.Rows | Where-Object Name -eq 'valid'
    $expired = $updated.Rows | Where-Object Name -eq 'expired'

    Assert-Equal $valid.QuotaDisplay '57%' 'Updating one dashboard row should preserve quota data on other rows.'
    Assert-Equal $expired.QuotaDisplay '68%' 'The target row should receive the new quota value.'
    Assert-Equal $expired.ResetDisplay '30 Mar 10:45' 'The target row should receive the new reset display.'
    Assert-Equal $expired.RowStatus 'OK' 'The target row should receive the new row status.'
    Assert-Equal $expired.LastUpdatedAt '2026-03-21 10:45:00' 'The target row should receive the new updated timestamp.'
}

function Test-DashboardRefreshWorkerDefinesModulePath {
    $cliPath = Get-CliModulePath
    $cliContent = Get-Content -Raw $cliPath
    Assert-True ($cliContent -like '*Codecux.psm1*') 'CLI helper module should reference the Codecux module for background worker imports.'
}
function Test-ReadConsoleKeySafelyHandlesUnavailableConsole {
    $result = Read-CodecuxConsoleKeySafely -GetKeyAvailable { throw 'Cannot see if a key has been pressed' } -ReadKey { throw 'read should not be called' }
    Assert-True (-not $result.HasKey) 'Safe key polling should report no key when the console cannot be queried.'
    Assert-True ($result.Error -like '*Cannot see if a key has been pressed*') 'Safe key polling should preserve the console error for status reporting instead of crashing.'
}

function Test-DashboardRefreshWorkerResultUsesSafePropertyAccess {
    $nullResult = [pscustomobject]@{}
    $mode = Get-CodecuxObjectPropertyValue -Object $nullResult -Name 'Mode'
    Assert-True ($null -eq $mode) 'Safe property access should return null for missing properties.'
    $withMode = [pscustomobject]@{ Mode = 'all'; ProbeResults = @{} }
    $mode2 = Get-CodecuxObjectPropertyValue -Object $withMode -Name 'Mode'
    Assert-Equal $mode2 'all' 'Safe property access should return the value for existing properties.'
}


function Test-CliHelpShowsDashboardCommand {
    $output = Invoke-CliForTest -Arguments @('help')
    Assert-True ($output -like '*cux dashboard*') 'CLI help should show the dashboard command.'
}

function Test-CliListAndCurrentCommands {
    $envInfo = New-TestEnvironment
    try {
        New-TestAuthFile -Path $envInfo.AuthPath -AccountId 'acct-01' -RefreshToken 'refresh-01'
        Add-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        Use-CodecuxProfile -Name 'codex01' -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot | Out-Null
        $listOutput = Invoke-CliForTest -Arguments @('list', '--store-root', $envInfo.CuxRoot, '--codex-root', $envInfo.CodexRoot, '--opencode-root', $envInfo.OpencodeRoot)
        Assert-True ($listOutput -like '*codex01*') 'CLI list should show saved profiles.'
        $currentOutput = Invoke-CliForTest -Arguments @('current', '--store-root', $envInfo.CuxRoot, '--codex-root', $envInfo.CodexRoot, '--opencode-root', $envInfo.OpencodeRoot)
        Assert-True ($currentOutput -like '*codex01*') 'CLI current should show the active profile.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-InstallScriptConfiguresPowerShellCompletion {
    $installScript = Get-Content -Raw (Join-Path $PSScriptRoot '..\scripts\install.ps1')
    Assert-True ($installScript -like '*cux-completion.ps1*') 'Install script should reference the cux PowerShell completion script.'
    Assert-True ($installScript -like '*Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1*') 'Install script should target the real Windows PowerShell user profile path under HOME.'
    $completionScript = Get-Content -Raw (Join-Path $PSScriptRoot '..\scripts\cux-completion.ps1')
    Assert-True ($completionScript -like '*Register-ArgumentCompleter*') 'Completion script should register a PowerShell argument completer for cux.'
    Assert-True ($completionScript -like '*dashboard*') 'Completion script should include the dashboard command.'
}

function Test-ReadOnlyCommandsDoNotCreateDirectories {
    $base = Join-Path $env:TEMP ("codecux-ro-test-" + [guid]::NewGuid().ToString('N'))
    $cuxRoot = Join-Path $base '.cux'
    $codexRoot = Join-Path $base '.codex'
    $opencodeRoot = Join-Path $base '.local\share\opencode'
    # Do NOT pre-create directories — they should not exist before or after
    try {
        Get-CodecuxProfiles -StoreRoot $cuxRoot -CodexRoot $codexRoot -OpencodeRoot $opencodeRoot | Out-Null
        Get-CodecuxStatus -StoreRoot $cuxRoot -CodexRoot $codexRoot -OpencodeRoot $opencodeRoot | Out-Null
        Get-CodecuxDoctor -StoreRoot $cuxRoot -CodexRoot $codexRoot -OpencodeRoot $opencodeRoot | Out-Null
        Assert-True (-not (Test-Path $base)) 'Read-only commands should not create any directories when the store does not exist.'
    }
    finally {
        if (Test-Path $base) { Remove-Item -Path $base -Recurse -Force }
    }
}

function Test-CliDoesNotDuplicateModuleFunctions {
    $cliPath = Get-CliModulePath
    $cliContent = Get-Content -Raw $cliPath
    $dupePattern = 'function\s+Set-CodecuxDashboardCurrentProfileName'
    $matches = [regex]::Matches($cliContent, $dupePattern)
    Assert-Equal $matches.Count 0 'CLI helper module should not redefine Set-CodecuxDashboardCurrentProfileName — it is exported from the core module.'
    $dupePattern2 = 'function\s+Update-CodecuxDashboardSnapshotRow'
    $matches2 = [regex]::Matches($cliContent, $dupePattern2)
    Assert-Equal $matches2.Count 0 'CLI helper module should not redefine Update-CodecuxDashboardSnapshotRow — it is exported from the core module.'
}

function Test-ModuleUsesSplitSourceFiles {
    $modulePath = Join-Path $PSScriptRoot '..\src\Codecux.psm1'
    $moduleContent = Get-Content -Raw $modulePath
    Assert-True ($moduleContent -like '*src\Codecux\Core.ps1*') 'Root module should dot-source the shared core helpers.'
    Assert-True ($moduleContent -like '*src\Codecux\Auth.ps1*') 'Root module should dot-source the auth helpers.'
    Assert-True ($moduleContent -like '*src\Codecux\Store.ps1*') 'Root module should dot-source the store helpers.'
    Assert-True ($moduleContent -like '*src\Codecux\Profiles.ps1*') 'Root module should dot-source the profile helpers.'
    Assert-True ($moduleContent -like '*src\Codecux\Probe.ps1*') 'Root module should dot-source the probe helpers.'
    Assert-True ($moduleContent -like '*src\Codecux\Dashboard.ps1*') 'Root module should dot-source the dashboard helpers.'
    Assert-True ($moduleContent -like '*src\Codecux\Doctor.ps1*') 'Root module should dot-source the doctor helpers.'
}

function Test-CliDelegatesToModuleEntryPoint {
    $cliPath = Join-Path $PSScriptRoot '..\bin\cux.ps1'
    $cliContent = Get-Content -Raw $cliPath
    Assert-True ($cliContent -like '*Codecux.Cli.psm1*') 'CLI script should import the dedicated CLI helper module.'
    Assert-True ($cliContent -like '*Invoke-CodecuxCli*') 'CLI script should delegate command execution to a single module entrypoint.'
}

function Test-InstallShimDoesNotHardcodePowershellExe {
    $line = Get-ScriptLineMatchingPattern -Path (Join-Path $PSScriptRoot '..\scripts\install.ps1') -Pattern '^\$psExe = if \(Get-Command pwsh -ErrorAction SilentlyContinue\)'
    $withPwsh = Invoke-PowerShellSelectionLine -Line $line -PwshAvailable $true
    Assert-Equal $withPwsh 'pwsh' 'Install shim should prefer pwsh when it is available.'
    $withoutPwsh = Invoke-PowerShellSelectionLine -Line $line -PwshAvailable $false
    Assert-Equal $withoutPwsh 'powershell' 'Install shim should fall back to powershell when pwsh is unavailable.'
}

function Test-DashboardLauncherDoesNotHardcodePowershellExe {
    $line = Get-ScriptLineMatchingPattern -Path (Get-CliModulePath) -Pattern '^\s*\$psExe = if \(Get-Command pwsh -ErrorAction SilentlyContinue\)'
    $pwshSource = 'C:\Program Files\PowerShell\7\pwsh.exe'
    $withPwsh = Invoke-PowerShellSelectionLine -Line $line -PwshAvailable $true -PwshSource $pwshSource
    Assert-Equal $withPwsh $pwshSource 'Dashboard launcher should use the discovered pwsh executable when available.'
    $withoutPwsh = Invoke-PowerShellSelectionLine -Line $line -PwshAvailable $false
    Assert-Equal $withoutPwsh (Join-Path $PSHOME 'powershell.exe') 'Dashboard launcher should fall back to Windows PowerShell when pwsh is unavailable.'
}

function Test-DashboardLauncherOpensMaximizedWindow {
    $cliContent = Get-Content -Raw (Get-CliModulePath)
    Assert-True ($cliContent -like '*Start-Process*WindowStyle Maximized*') 'Dashboard launcher should open the dashboard in a maximized PowerShell window.'
}

function Test-InstallScriptTargetsBothPowerShellProfiles {
    $base = Join-Path $env:TEMP ("codecux-install-test-" + [guid]::NewGuid().ToString('N'))
    $homePath = Join-Path $base 'home'
    $localAppDataPath = Join-Path $base 'localappdata'
    $ps5Profile = Join-Path $homePath 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
    $ps7Profile = Join-Path $homePath 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
    $staleBlock = @(
        'prefix',
        '# >>> Codecux completion >>>',
        '. "old-path"',
        '# <<< Codecux completion <<<'
    ) -join [Environment]::NewLine

    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ps5Profile), (Split-Path -Parent $ps7Profile), $localAppDataPath | Out-Null
        Set-Content -Path $ps5Profile -Value $staleBlock -Encoding UTF8
        Set-Content -Path $ps7Profile -Value $staleBlock -Encoding UTF8

        Invoke-InstallScriptForTest -HomePath $homePath -LocalAppDataPath $localAppDataPath

        Assert-True (Test-Path $ps5Profile) 'Install script should create or update the Windows PowerShell profile.'
        Assert-True (Test-Path $ps7Profile) 'Install script should create or update the PowerShell 7 profile.'

        $ps5Content = Get-Content -Raw $ps5Profile
        $ps7Content = Get-Content -Raw $ps7Profile
        $expectedLine = '. "{0}"' -f [string](Resolve-Path (Join-Path $PSScriptRoot '..\scripts\cux-completion.ps1'))

        Assert-Equal ([regex]::Matches($ps5Content, '# >>> Codecux completion >>>').Count) 1 'Windows PowerShell profile should contain one completion block.'
        Assert-Equal ([regex]::Matches($ps7Content, '# >>> Codecux completion >>>').Count) 1 'PowerShell 7 profile should contain one completion block.'
        Assert-True ($ps5Content -like "*$expectedLine*") 'Windows PowerShell profile should reference the current completion script path.'
        Assert-True ($ps7Content -like "*$expectedLine*") 'PowerShell 7 profile should reference the current completion script path.'
    }
    finally {
        if (Test-Path $base) { Remove-Item -Path $base -Recurse -Force }
    }
}

function Test-InstallScriptAddsDashboardHandoffToShim {
    $base = Join-Path $env:TEMP ("codecux-shim-handoff-test-" + [guid]::NewGuid().ToString('N'))
    $homePath = Join-Path $base 'home'
    $localAppDataPath = Join-Path $base 'localappdata'
    $shimPath = Join-Path $localAppDataPath 'Microsoft\WindowsApps\cux.cmd'

    try {
        New-Item -ItemType Directory -Force -Path $homePath, $localAppDataPath | Out-Null
        Invoke-InstallScriptForTest -HomePath $homePath -LocalAppDataPath $localAppDataPath

        Assert-True (Test-Path $shimPath) 'Install script should generate cux.cmd for dashboard handoff.'
        $shim = Get-Content -Raw $shimPath
        Assert-True ($shim -like '*if /I "%~1"=="dash"*') 'Generated cux.cmd should special-case the dash alias.'
        Assert-True ($shim -like '*if /I "%~1"=="dashboard"*') 'Generated cux.cmd should special-case the dashboard command.'
        Assert-True ($shim -like '*exit %CODE%*') 'Generated cux.cmd should close the interactive cmd session after dashboard handoff.'
    }
    finally {
        if (Test-Path $base) { Remove-Item -Path $base -Recurse -Force }
    }
}

function Test-InstallScriptAddsDashboardHandoffWrapperToBothProfiles {
    $base = Join-Path $env:TEMP ("codecux-profile-handoff-test-" + [guid]::NewGuid().ToString('N'))
    $homePath = Join-Path $base 'home'
    $localAppDataPath = Join-Path $base 'localappdata'
    $ps5Profile = Join-Path $homePath 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
    $ps7Profile = Join-Path $homePath 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'

    try {
        New-Item -ItemType Directory -Force -Path $homePath, $localAppDataPath | Out-Null
        Invoke-InstallScriptForTest -HomePath $homePath -LocalAppDataPath $localAppDataPath

        foreach ($profilePath in @($ps5Profile, $ps7Profile)) {
            Assert-True (Test-Path $profilePath) 'Install script should create both PowerShell profiles before adding the dashboard wrapper.'
            $content = Get-Content -Raw $profilePath
            Assert-True ($content -like '*function cux*') 'Installed PowerShell profile should define a cux wrapper function.'
            Assert-True ($content -like '*dash*dashboard*') 'Installed PowerShell profile should special-case both dashboard commands.'
            Assert-True ($content -like '*cux.cmd*') 'Installed PowerShell profile should delegate to the generated cux.cmd shim.'
            Assert-True ($content -like '*exit $exitCode*') 'Installed PowerShell profile should exit the current shell only after a successful dashboard handoff.'
        }
    }
    finally {
        if (Test-Path $base) { Remove-Item -Path $base -Recurse -Force }
    }
}

function Test-DoctorReturnsStructuredChecks {
    $base = Join-Path $env:TEMP ("codecux-doctor-structure-" + [guid]::NewGuid().ToString('N'))
    $cuxRoot = Join-Path $base '.cux'
    $codexRoot = Join-Path $base '.codex'
    $opencodeRoot = Join-Path $base '.local\share\opencode'

    try {
        $doctor = Get-CodecuxDoctor -StoreRoot $cuxRoot -CodexRoot $codexRoot -OpencodeRoot $opencodeRoot
        Assert-True ($null -ne (Get-CodecuxObjectPropertyValue -Object $doctor -Name 'Summary')) 'Doctor should return a summary object.'
        $checks = @(Get-CodecuxObjectPropertyValue -Object $doctor -Name 'Checks')
        Assert-True ($checks.Count -gt 0) 'Doctor should return per-check details.'
        Assert-True ($null -ne (Get-CodecuxObjectPropertyValue -Object $checks[0] -Name 'Name')) 'Doctor checks should include a name.'
        Assert-True ($null -ne (Get-CodecuxObjectPropertyValue -Object $checks[0] -Name 'Status')) 'Doctor checks should include a status.'
        Assert-True ($null -ne (Get-CodecuxObjectPropertyValue -Object $checks[0] -Name 'Recommendation')) 'Doctor checks should include a recommendation.'
    }
    finally {
        if (Test-Path $base) { Remove-Item -Path $base -Recurse -Force }
    }
}

function Test-CliDoctorFixRepairsShimAndProfiles {
    $base = Join-Path $env:TEMP ("codecux-doctor-fix-test-" + [guid]::NewGuid().ToString('N'))
    $homePath = Join-Path $base 'home'
    $localAppDataPath = Join-Path $base 'localappdata'
    $shimPath = Join-Path $localAppDataPath 'Microsoft\WindowsApps\cux.cmd'
    $ps5Profile = Join-Path $homePath 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
    $ps7Profile = Join-Path $homePath 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'

    try {
        New-Item -ItemType Directory -Force -Path $homePath, $localAppDataPath | Out-Null
        $output = Invoke-CliForTestWithHome -Arguments @('doctor', '--fix') -HomePath $homePath -LocalAppDataPath $localAppDataPath
        Assert-True (Test-Path $shimPath) 'doctor --fix should create the cux shim when it is missing.'
        Assert-True (Test-Path $ps5Profile) 'doctor --fix should create the Windows PowerShell profile when it is missing.'
        Assert-True (Test-Path $ps7Profile) 'doctor --fix should create the PowerShell 7 profile when it is missing.'
        Assert-True ($output -like '*Codecux doctor*') 'doctor --fix should print the doctor summary after repair.'
    }
    finally {
        if (Test-Path $base) { Remove-Item -Path $base -Recurse -Force }
    }
}

function Test-UninstallScriptRemovesShimAndCodecuxProfileBlocks {
    $base = Join-Path $env:TEMP ("codecux-uninstall-test-" + [guid]::NewGuid().ToString('N'))
    $homePath = Join-Path $base 'home'
    $localAppDataPath = Join-Path $base 'localappdata'
    $shimPath = Join-Path $localAppDataPath 'Microsoft\WindowsApps\cux.cmd'
    $ps5Profile = Join-Path $homePath 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
    $ps7Profile = Join-Path $homePath 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'

    try {
        New-Item -ItemType Directory -Force -Path $homePath, $localAppDataPath | Out-Null
        Invoke-InstallScriptForTest -HomePath $homePath -LocalAppDataPath $localAppDataPath
        Add-Content -Path $ps5Profile -Value ([Environment]::NewLine + 'custom-line') -Encoding UTF8
        Add-Content -Path $ps7Profile -Value ([Environment]::NewLine + 'custom-line') -Encoding UTF8

        Invoke-UninstallScriptForTest -HomePath $homePath -LocalAppDataPath $localAppDataPath

        Assert-True (-not (Test-Path $shimPath)) 'Uninstall should remove the cux shim.'
        Assert-True ((Get-Content -Raw $ps5Profile) -notlike '*Codecux*') 'Uninstall should remove Codecux-managed blocks from the Windows PowerShell profile.'
        Assert-True ((Get-Content -Raw $ps7Profile) -notlike '*Codecux*') 'Uninstall should remove Codecux-managed blocks from the PowerShell 7 profile.'
        Assert-True ((Get-Content -Raw $ps5Profile) -like '*custom-line*') 'Uninstall should preserve unrelated profile content.'
        Assert-True ((Get-Content -Raw $ps7Profile) -like '*custom-line*') 'Uninstall should preserve unrelated profile content.'
    }
    finally {
        if (Test-Path $base) { Remove-Item -Path $base -Recurse -Force }
    }
}

function Test-CliRejectsUnknownFlags {
    $output = Invoke-CliForTest -Arguments @('list', '--store-rooot', 'fake')
    Assert-True ($output -like '*Unknown option*') 'CLI should reject unknown --* flags instead of silently treating them as positionals.'
}

function Test-CliWarnsOnApiKeyValueFlag {
    $cliContent = Get-Content -Raw (Get-CliModulePath)
    Assert-True ($cliContent -like '*WARNING*--api-key-value*') 'CLI should emit a warning when --api-key-value is used because it exposes the secret in shell history.'
}

function Test-CliUsesSecureReadHostForApiKey {
    $cliContent = Get-Content -Raw (Get-CliModulePath)
    Assert-True ($cliContent -like '*Read-Host*AsSecureString*') 'CLI should use Read-Host -AsSecureString for interactive API key entry.'
}

function Test-StoreDirectoryHasRestrictedAcl {
    $base = Join-Path $env:TEMP ("codecux-acl-test-" + [guid]::NewGuid().ToString('N'))
    $cuxRoot = Join-Path $base '.cux'
    $codexRoot = Join-Path $base '.codex'
    $opencodeRoot = Join-Path $base '.local\share\opencode'

    try {
        New-Item -ItemType Directory -Force -Path $codexRoot, $opencodeRoot | Out-Null
        New-TestAuthFile -Path (Join-Path $codexRoot 'auth.json') -AccountId 'acct-01' -RefreshToken 'refresh-01'
        Add-CodecuxProfile -Name 'codex01' -StoreRoot $cuxRoot -CodexRoot $codexRoot -OpencodeRoot $opencodeRoot | Out-Null
        $acl = Get-Acl $cuxRoot
        Assert-True ($acl.AreAccessRulesProtected) 'Store directory ACL should disable inherited permissions after Codecux creates the store.'
    }
    finally {
        if (Test-Path $base) { Remove-Item -Path $base -Recurse -Force }
    }
}

function Test-StopCodexAppServerProcessKillsChildProcessTree {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/d /c powershell -NoProfile -Command "Start-Sleep -Seconds 30"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $wrapper = $null
    $child = $null
    try {
        $wrapper = [System.Diagnostics.Process]::Start($psi)
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline -and $null -eq $child) {
            $child = Get-CimInstance Win32_Process -Filter ("ParentProcessId = {0}" -f $wrapper.Id) -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $child) {
                Start-Sleep -Milliseconds 100
            }
        }

        Assert-True ($null -ne $child) 'Test harness should spawn a child process under the wrapper.'

        $server = [pscustomobject]@{
            Process = $wrapper
            Port    = 0
        }

        & (Get-Module Codecux) {
            param($Server)
            Stop-CodecuxCodexAppServerProcess -Server $Server
        } $server

        Start-Sleep -Milliseconds 300
        Assert-True ($null -eq (Get-Process -Id $wrapper.Id -ErrorAction SilentlyContinue)) 'Stop helper should terminate the wrapper process.'
        Assert-True ($null -eq (Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue)) 'Stop helper should terminate the spawned child process tree.'
    }
    finally {
        if ($null -ne $wrapper) {
            Stop-Process -Id $wrapper.Id -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $child) {
            Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-DashboardSurvivesMalformedProfileAuth {
    $envInfo = New-TestEnvironment
    try {
        $profilesRoot = Join-Path $envInfo.CuxRoot 'profiles'

        $goodDir = Join-Path $profilesRoot 'good'
        New-Item -ItemType Directory -Force -Path $goodDir | Out-Null
        New-TestCanonicalOAuthProfileFile -Path (Join-Path $goodDir 'auth.json') -AccountId 'acct-good' -RefreshToken 'refresh-good' -IdToken 'id-good' -Expires ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 3600000)
        ([ordered]@{ name='good'; type='chatgpt'; fingerprint='chatgpt:acct-good'; saved_at='2026-03-23T00:00:00Z'; display='acct-good' } | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $goodDir 'profile.json') -Encoding UTF8

        $badDir = Join-Path $profilesRoot 'broken'
        New-Item -ItemType Directory -Force -Path $badDir | Out-Null
        'not-valid-json' | Set-Content -Path (Join-Path $badDir 'auth.json') -Encoding UTF8
        ([ordered]@{ name='broken'; type='chatgpt'; fingerprint='chatgpt:acct-broken'; saved_at='2026-03-23T00:00:00Z'; display='acct-broken' } | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $badDir 'profile.json') -Encoding UTF8

        $snapshot = Get-CodecuxDashboardSnapshot -StoreRoot $envInfo.CuxRoot -CodexRoot $envInfo.CodexRoot -OpencodeRoot $envInfo.OpencodeRoot
        Assert-Equal @($snapshot.Rows).Count 2 'Dashboard should include both rows even when one profile has bad auth.'
        $broken = $snapshot.Rows | Where-Object Name -eq 'broken'
        Assert-True ($broken.RowStatus -in @('ERR','AUTH','UNAVAIL')) 'Broken profile row should show an error status instead of crashing the dashboard.'
    }
    finally { Remove-TestEnvironment $envInfo }
}

function Test-CompletionIncludesDashAlias {
    $result = Invoke-CuxCompletionForTest -InputScript 'cux da' -CursorColumn 6
    $matches = @($result.CompletionMatches | Select-Object -ExpandProperty CompletionText)
    Assert-True ($matches -contains 'dash') 'Completion script should include the dash alias for the dashboard command.'
}

function Test-CompletionSuggestsProfileNamesForUse {
    $base = Join-Path $env:TEMP ("codecux-completion-test-" + [guid]::NewGuid().ToString('N'))
    $homePath = Join-Path $base 'home'
    $profilesRoot = Join-Path $homePath '.cux\profiles'
    $oldHome = $env:HOME

    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $profilesRoot 'codex01'), (Join-Path $profilesRoot 'codex02') | Out-Null
        $env:HOME = $homePath
        $result = Invoke-CuxCompletionForTest -InputScript 'cux use cod' -CursorColumn 11
        $matches = @($result.CompletionMatches | Select-Object -ExpandProperty CompletionText)
        Assert-True ($matches -contains 'codex01') 'Completion should suggest matching profile names for `cux use`.'
        Assert-True ($matches -contains 'codex02') 'Completion should include all matching profile names for `cux use`.'
    }
    finally {
        $env:HOME = $oldHome
        if (Test-Path $base) { Remove-Item -Path $base -Recurse -Force }
    }
}

function Test-DashboardStatusMessagesDoNotContainQuestionMark {
    $cliContent = Get-Content -Raw (Get-CliModulePath)
    $matches = [regex]::Matches($cliContent, '\?\s+refresh')
    Assert-Equal $matches.Count 0 'Dashboard status messages should not use ? as a separator.'
}

$tests = @(
    'Test-AddProfileSavesManifestAndCanonicalAuth',
    'Test-AddProfileRejectsDuplicateFingerprint',
    'Test-AddProfileFailsWhenOnlyOpencodeOAuthExists',
    'Test-AddProfilePrefersCodexWhenOpenCodeMismatches',
    'Test-UseProfileCopiesAuthToBothTargetsAndUpdatesCurrent',
    'Test-AddProfileWritesAuthWithoutUtf8Bom',
    'Test-UseProfileRewritesBothTargetsWithoutUtf8Bom',
    'Test-UseProfileFailsWhenCanonicalOAuthIsMissingIdToken',
    'Test-UseProfileRollsBackWhenOpencodeWriteFails',
    'Test-GetCurrentProfileDoesNotFallBackToStateWhenLiveAuthIsUnmatched',
    'Test-AddAndUseProfileDoNotCreateOpencodeRootWhenAbsent',
    'Test-GetStateNormalizesLegacyStateFile',
    'Test-GetProfileManifestNormalizesLegacyManifest',
    'Test-GetStateRejectsUnsupportedSchemaVersion',
    'Test-GetProfileManifestRejectsUnsupportedSchemaVersion',
    'Test-UseProfileFailsWhenCanonicalOAuthIsMissingRefreshToken',
    'Test-GetDashboardSnapshotHandlesCanonicalAuthValidationFailure',
    'Test-RenameProfileMovesDirectoryAndState',
    'Test-RemoveProfileDeletesFilesAndClearsCurrentWhenNeeded',
    'Test-AddApiKeyProfileStoresMaskedMetadataAndGeneratedAuth',
    'Test-ConvertRateLimitResponseComputesLeftPercentAndResetDisplay',
    'Test-GetDashboardSnapshotUsesProbeResultsAndMarksCurrentProfile',
    'Test-FormatDashboardRendersCurrentMarkerAndUnicodeQuotaBar',
    'Test-SetDashboardCurrentProfileNameUpdatesMarkersWithoutClearingQuota',
    'Test-SetDashboardCurrentProfileNameMovesSyncTargetStatus',
    'Test-UpdateDashboardSnapshotRowPreservesOtherRows',
    'Test-DashboardRefreshWorkerDefinesModulePath',
    'Test-ReadConsoleKeySafelyHandlesUnavailableConsole',
    'Test-DashboardRefreshWorkerResultUsesSafePropertyAccess',
    'Test-CliHelpShowsDashboardCommand',
    'Test-CliListAndCurrentCommands',
    'Test-InstallScriptConfiguresPowerShellCompletion',
    'Test-ReadOnlyOperationsDoNotCreateStateFile',
    'Test-ReadOnlyCommandsDoNotCreateDirectories',
    'Test-CliDoesNotDuplicateModuleFunctions',
    'Test-ModuleUsesSplitSourceFiles',
    'Test-CliDelegatesToModuleEntryPoint',
    'Test-InstallShimDoesNotHardcodePowershellExe',
    'Test-DashboardLauncherDoesNotHardcodePowershellExe',
    'Test-DashboardLauncherOpensMaximizedWindow',
    'Test-InstallScriptTargetsBothPowerShellProfiles',
    'Test-InstallScriptAddsDashboardHandoffToShim',
    'Test-InstallScriptAddsDashboardHandoffWrapperToBothProfiles',
    'Test-DoctorReturnsStructuredChecks',
    'Test-CliDoctorFixRepairsShimAndProfiles',
    'Test-UninstallScriptRemovesShimAndCodecuxProfileBlocks',
    'Test-CliRejectsUnknownFlags',
    'Test-CliWarnsOnApiKeyValueFlag',
    'Test-CliUsesSecureReadHostForApiKey',
    'Test-StoreDirectoryHasRestrictedAcl',
    'Test-StopCodexAppServerProcessKillsChildProcessTree',
    'Test-DashboardSurvivesMalformedProfileAuth',
    'Test-CompletionIncludesDashAlias',
    'Test-CompletionSuggestsProfileNamesForUse',
    'Test-DashboardStatusMessagesDoNotContainQuestionMark'
)

foreach ($test in $tests) {
    & $test
    Write-Host "PASS $test"
}



