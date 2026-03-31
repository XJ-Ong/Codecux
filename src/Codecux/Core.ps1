function Get-CodecuxDefaultStoreRoot {
    Join-Path $HOME '.cux'
}

function Get-CodecuxDefaultCodexRoot {
    Join-Path $HOME '.codex'
}

function Get-CodecuxDefaultOpencodeRoot {
    Join-Path $HOME '.local\share\opencode'
}

function Write-CodecuxUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Read-CodecuxJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    Get-Content -Raw $Path | ConvertFrom-Json
}

function Resolve-CodecuxPaths {
    param([string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)

    if ([string]::IsNullOrWhiteSpace($StoreRoot)) { $StoreRoot = Get-CodecuxDefaultStoreRoot }
    if ([string]::IsNullOrWhiteSpace($CodexRoot)) { $CodexRoot = Get-CodecuxDefaultCodexRoot }
    if ([string]::IsNullOrWhiteSpace($OpencodeRoot)) { $OpencodeRoot = Get-CodecuxDefaultOpencodeRoot }

    [pscustomobject]@{
        StoreRoot        = $StoreRoot
        ProfilesRoot     = Join-Path $StoreRoot 'profiles'
        BackupsRoot      = Join-Path $StoreRoot 'backups'
        StatePath        = Join-Path $StoreRoot 'state.json'
        CodexRoot        = $CodexRoot
        CodexAuthPath    = Join-Path $CodexRoot 'auth.json'
        OpencodeRoot     = $OpencodeRoot
        OpencodeAuthPath = Join-Path $OpencodeRoot 'auth.json'
    }
}

function Set-CodecuxDirectoryAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $acl = Get-Acl $Path
        $acl.SetAccessRuleProtection($true, $false)

        foreach ($identity in @(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'SYSTEM',
            'Administrators'
        )) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $identity,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            [void]$acl.SetAccessRule($rule)
        }

        Set-Acl -Path $Path -AclObject $acl
    }
    catch {
        # Best-effort hardening only; keep store creation non-fatal if ACL updates fail.
    }
}

function Ensure-CodecuxStore {
    param([string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)

    $paths = Resolve-CodecuxPaths -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    foreach ($path in @($paths.StoreRoot, $paths.ProfilesRoot, $paths.BackupsRoot, $paths.CodexRoot)) {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Force -Path $path | Out-Null
            if ($path -eq $paths.StoreRoot) {
                Set-CodecuxDirectoryAcl -Path $path
            }
        }
    }

    $paths
}

function Get-CodecuxObjectPropertyValue {
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Name)

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-CodecuxSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        ([BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant())
    }
    finally {
        $sha.Dispose()
    }
}

$script:CodecuxStoreSchemaVersion = 1
