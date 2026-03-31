param(
    [switch]$RemoveStore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Remove-CodecuxProfileBlock {
    param(
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$BlockName
    )

    if (-not (Test-Path $ProfilePath)) { return }

    $startMarker = '# >>> Codecux {0} >>>' -f $BlockName
    $endMarker = '# <<< Codecux {0} <<<' -f $BlockName
    $content = Get-Content -Raw $ProfilePath
    $pattern = '(?ms)\r?\n?{0}.*?{1}\r?\n?' -f [regex]::Escape($startMarker), [regex]::Escape($endMarker)
    $updated = [regex]::Replace($content, $pattern, [string]::Empty)
    Set-Content -Path $ProfilePath -Value $updated.TrimEnd() -Encoding UTF8
}

$shimPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\cux.cmd'
if (Test-Path $shimPath) {
    Remove-Item -Path $shimPath -Force
    Write-Host ("Removed cux shim: {0}" -f $shimPath)
}
else {
    Write-Host ("cux shim already absent: {0}" -f $shimPath)
}

$profilePaths = @(
    (Join-Path $HOME 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $HOME 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')
)

foreach ($profilePath in $profilePaths) {
    if (Test-Path $profilePath) {
        Remove-CodecuxProfileBlock -ProfilePath $profilePath -BlockName 'wrapper'
        Remove-CodecuxProfileBlock -ProfilePath $profilePath -BlockName 'completion'
        Write-Host ("Removed Codecux profile blocks from: {0}" -f $profilePath)
    }
}

if ($RemoveStore) {
    $storeRoot = Join-Path $HOME '.cux'
    if (Test-Path $storeRoot) {
        Remove-Item -Path $storeRoot -Recurse -Force
        Write-Host ("Removed Codecux store root: {0}" -f $storeRoot)
    }
}
