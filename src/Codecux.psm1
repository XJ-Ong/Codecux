Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceFiles = @(
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Codecux\Core.ps1')
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Codecux\Auth.ps1')
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Codecux\Store.ps1')
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Codecux\Profiles.ps1')
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Codecux\Probe.ps1')
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Codecux\Dashboard.ps1')
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Codecux\Doctor.ps1')
)
foreach ($sourceFile in $sourceFiles) {
    . $sourceFile
}

Export-ModuleMember -Function @(
    'Add-CodecuxProfile',
    'Get-CodecuxObjectPropertyValue',
    'Get-CodecuxCurrentProfile',
    'Get-CodecuxDefaultCodexRoot',
    'Get-CodecuxDefaultOpencodeRoot',
    'Get-CodecuxDefaultStoreRoot',
    'ConvertTo-CodecuxRateLimitProbeResult',
    'Format-CodecuxDashboard',
    'Get-CodecuxProfileRateLimitResult',
    'Get-CodecuxProfileRateLimitResults',
    'Get-CodecuxDashboardSnapshot',
    'Get-CodecuxDoctor',
    'Read-CodecuxConsoleKeySafely',
    'Set-CodecuxDashboardCurrentProfileName',
    'Update-CodecuxDashboardSnapshotRow',
    'Get-CodecuxProfileManifest',
    'Get-CodecuxProfiles',
    'Get-CodecuxState',
    'Get-CodecuxStatus',
    'Remove-CodecuxProfile',
    'Rename-CodecuxProfile',
    'Use-CodecuxProfile'
)
