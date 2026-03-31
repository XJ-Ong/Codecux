function Assert-CodecuxCanonicalAuthObject {
    param([Parameter(Mandatory = $true)]$CanonicalAuth)

    $type = [string](Get-CodecuxObjectPropertyValue -Object $CanonicalAuth -Name 'type')
    switch ($type) {
        'api' {
            $key = [string](Get-CodecuxObjectPropertyValue -Object $CanonicalAuth -Name 'key')
            if ([string]::IsNullOrWhiteSpace($key)) {
                throw 'API auth is missing the API key.'
            }
            return
        }
        'oauth' {
            $access = [string](Get-CodecuxObjectPropertyValue -Object $CanonicalAuth -Name 'access')
            $refresh = [string](Get-CodecuxObjectPropertyValue -Object $CanonicalAuth -Name 'refresh')
            $expires = Get-CodecuxObjectPropertyValue -Object $CanonicalAuth -Name 'expires'

            if ([string]::IsNullOrWhiteSpace($access)) {
                throw 'OAuth auth is missing the access token.'
            }
            if ([string]::IsNullOrWhiteSpace($refresh)) {
                throw 'OAuth auth is missing the refresh token.'
            }
            if ($null -eq $expires -or [int64]$expires -le 0) {
                throw 'OAuth auth is missing the expiry timestamp.'
            }
            return
        }
        default {
            throw "Unsupported canonical auth type '$type'."
        }
    }
}

function Get-CodecuxJwtPayload {
    param([Parameter(Mandatory = $true)][string]$Token)

    $parts = $Token -split '\.'
    if ($parts.Length -lt 2) { throw 'Token is not a valid JWT.' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
    }
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

function Get-CodecuxJwtExpiryMs {
    param([Parameter(Mandatory = $true)][string]$AccessToken)
    $claims = Get-CodecuxJwtPayload -Token $AccessToken
    if ($null -eq $claims.exp) { throw 'Access token is missing an exp claim.' }
    [int64]$claims.exp * 1000
}

function Get-CodecuxAccountIdFromJwt {
    param([Parameter(Mandatory = $true)][string]$AccessToken)
    $claims = Get-CodecuxJwtPayload -Token $AccessToken
    $authClaims = Get-CodecuxObjectPropertyValue -Object $claims -Name 'https://api.openai.com/auth'
    if ($null -eq $authClaims) { return $null }
    $accountId = Get-CodecuxObjectPropertyValue -Object $authClaims -Name 'chatgpt_account_id'
    if ([string]::IsNullOrWhiteSpace([string]$accountId)) { return $null }
    [string]$accountId
}

function ConvertTo-CodecuxCanonicalAuthObject {
    param([Parameter(Mandatory = $true)]$RawAuthObject)

    $directType = Get-CodecuxObjectPropertyValue -Object $RawAuthObject -Name 'type'
    if ($directType -eq 'oauth') {
        $access = [string](Get-CodecuxObjectPropertyValue -Object $RawAuthObject -Name 'access')
        $refresh = [string](Get-CodecuxObjectPropertyValue -Object $RawAuthObject -Name 'refresh')
        $expiresValue = Get-CodecuxObjectPropertyValue -Object $RawAuthObject -Name 'expires'
        $expires = if ($null -eq $expiresValue -or [string]::IsNullOrWhiteSpace([string]$expiresValue)) { 0 } else { [int64]$expiresValue }
        $accountId = Get-CodecuxObjectPropertyValue -Object $RawAuthObject -Name 'accountId'
        $idToken = Get-CodecuxObjectPropertyValue -Object $RawAuthObject -Name 'idToken'
        $canonical = [ordered]@{
            type      = 'oauth'
            access    = $access
            refresh   = $refresh
            expires   = $expires
            accountId = if ([string]::IsNullOrWhiteSpace([string]$accountId)) { $null } else { [string]$accountId }
            idToken   = if ([string]::IsNullOrWhiteSpace([string]$idToken)) { $null } else { [string]$idToken }
        }
        Assert-CodecuxCanonicalAuthObject -CanonicalAuth $canonical
        return $canonical
    }

    if ($directType -eq 'api') {
        $canonical = [ordered]@{
            type = 'api'
            key  = [string](Get-CodecuxObjectPropertyValue -Object $RawAuthObject -Name 'key')
        }
        Assert-CodecuxCanonicalAuthObject -CanonicalAuth $canonical
        return $canonical
    }

    $apiKey = Get-CodecuxObjectPropertyValue -Object $RawAuthObject -Name 'OPENAI_API_KEY'
    if (-not [string]::IsNullOrWhiteSpace([string]$apiKey)) {
        $canonical = [ordered]@{
            type = 'api'
            key  = [string]$apiKey
        }
        Assert-CodecuxCanonicalAuthObject -CanonicalAuth $canonical
        return $canonical
    }

    $rawTokens = Get-CodecuxObjectPropertyValue -Object $RawAuthObject -Name 'tokens'
    if ($null -ne $rawTokens) {
        $access = [string](Get-CodecuxObjectPropertyValue -Object $rawTokens -Name 'access_token')
        $idToken = Get-CodecuxObjectPropertyValue -Object $rawTokens -Name 'id_token'
        $refresh = [string](Get-CodecuxObjectPropertyValue -Object $rawTokens -Name 'refresh_token')
        $accountId = Get-CodecuxObjectPropertyValue -Object $rawTokens -Name 'account_id'
        if ([string]::IsNullOrWhiteSpace([string]$accountId)) {
            $accountId = Get-CodecuxObjectPropertyValue -Object $RawAuthObject -Name 'account_id'
        }
        if ([string]::IsNullOrWhiteSpace([string]$accountId) -and -not [string]::IsNullOrWhiteSpace($access)) {
            $accountId = Get-CodecuxAccountIdFromJwt -AccessToken $access
        }
        $canonical = [ordered]@{
            type      = 'oauth'
            access    = $access
            refresh   = $refresh
            expires   = if ([string]::IsNullOrWhiteSpace($access)) { 0 } else { (Get-CodecuxJwtExpiryMs -AccessToken $access) }
            accountId = if ([string]::IsNullOrWhiteSpace([string]$accountId)) { $null } else { [string]$accountId }
            idToken   = if ([string]::IsNullOrWhiteSpace([string]$idToken)) { $null } else { [string]$idToken }
        }
        Assert-CodecuxCanonicalAuthObject -CanonicalAuth $canonical
        return $canonical
    }

    throw 'The auth payload is not a supported Codex or OpenCode auth shape.'
}

function ConvertTo-CodecuxCodexAuthObject {
    param([Parameter(Mandatory = $true)]$CanonicalAuth)

    $canonical = ConvertTo-CodecuxCanonicalAuthObject -RawAuthObject $CanonicalAuth
    if ($canonical.type -eq 'api') {
        return [ordered]@{
            auth_mode      = 'api_key'
            last_refresh   = (Get-Date).ToUniversalTime().ToString('o')
            OPENAI_API_KEY = $canonical.key
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$canonical.idToken)) {
        throw 'Cannot activate this OAuth profile for Codex CLI because the id token is missing. Re-add the profile from codex login.'
    }

    return [ordered]@{
        auth_mode    = 'chatgpt'
        last_refresh = (Get-Date).ToUniversalTime().ToString('o')
        tokens       = [ordered]@{
            access_token  = $canonical.access
            id_token      = $canonical.idToken
            account_id    = $canonical.accountId
            refresh_token = $canonical.refresh
        }
    }
}

function ConvertTo-CodecuxOpencodeProviderAuthObject {
    param([Parameter(Mandatory = $true)]$CanonicalAuth)

    $canonical = ConvertTo-CodecuxCanonicalAuthObject -RawAuthObject $CanonicalAuth
    if ($canonical.type -eq 'api') {
        return [ordered]@{
            type = 'api'
            key  = $canonical.key
        }
    }

    return [ordered]@{
        type      = 'oauth'
        access    = $canonical.access
        refresh   = $canonical.refresh
        expires   = [int64]$canonical.expires
        accountId = $canonical.accountId
    }
}

function Get-CodecuxProfileType {
    param([Parameter(Mandatory = $true)]$AuthObject)
    $canonical = ConvertTo-CodecuxCanonicalAuthObject -RawAuthObject $AuthObject
    if ($canonical.type -eq 'api') { return 'apikey' }
    'chatgpt'
}

function Get-CodecuxAuthFingerprint {
    param([Parameter(Mandatory = $true)]$AuthObject)

    $canonical = ConvertTo-CodecuxCanonicalAuthObject -RawAuthObject $AuthObject
    if ($canonical.type -eq 'api') {
        return 'apikey:' + (ConvertTo-CodecuxSha256 -Text ([string]$canonical.key))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$canonical.accountId)) {
        return 'chatgpt:' + [string]$canonical.accountId
    }

    $normalized = $canonical | ConvertTo-Json -Depth 10 -Compress
    'chatgpt:sha256:' + (ConvertTo-CodecuxSha256 -Text $normalized)
}

function Get-CodecuxMaskedApiKey {
    param([Parameter(Mandatory = $true)][string]$ApiKey)
    if ($ApiKey.Length -le 6) { return ('*' * $ApiKey.Length) }
    $ApiKey.Substring(0, [Math]::Min(7, $ApiKey.Length)) + '***'
}
