function New-CodecuxDoctorCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Details,
        [Parameter(Mandatory = $true)][string]$Recommendation,
        [bool]$Fixable = $false
    )

    [pscustomobject]@{
        Name = $Name
        Status = $Status
        Details = $Details
        Recommendation = $Recommendation
        Fixable = $Fixable
    }
}

function Get-CodecuxDoctorProfileCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ProfilePath
    )

    if (-not (Test-Path $ProfilePath)) {
        return (New-CodecuxDoctorCheck -Name $Name -Status 'WARN' -Details ('Profile file is missing: {0}' -f $ProfilePath) -Recommendation 'Run cux doctor --fix to recreate the Codecux profile block.' -Fixable $true)
    }

    $content = Get-Content -Raw $ProfilePath
    if ($content -like '*# >>> Codecux wrapper >>>*' -and $content -like '*# >>> Codecux completion >>>*') {
        return (New-CodecuxDoctorCheck -Name $Name -Status 'OK' -Details ('Codecux wrapper and completion blocks are installed in {0}' -f $ProfilePath) -Recommendation 'No action needed.')
    }

    New-CodecuxDoctorCheck -Name $Name -Status 'WARN' -Details ('Codecux blocks are missing or incomplete in {0}' -f $ProfilePath) -Recommendation 'Run cux doctor --fix to repair the profile block.' -Fixable $true
}

function Get-CodecuxDoctor {
    [CmdletBinding()]
    param([string]$StoreRoot, [string]$CodexRoot, [string]$OpencodeRoot)

    $paths = Resolve-CodecuxPaths -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    $shimPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\cux.cmd'
    $ps5Profile = Join-Path $HOME 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
    $ps7Profile = Join-Path $HOME 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
    $codexInstalled = ($null -ne (Get-Command codex -ErrorAction SilentlyContinue))
    $opencodeInstalled = ($null -ne (Get-Command opencode -ErrorAction SilentlyContinue))

    $checks = @(
        (New-CodecuxDoctorCheck -Name 'Store Root' -Status $(if (Test-Path $paths.StoreRoot) { 'OK' } else { 'WARN' }) -Details $(if (Test-Path $paths.StoreRoot) { 'Codecux store root exists.' } else { 'Codecux store root has not been created yet.' }) -Recommendation $(if (Test-Path $paths.StoreRoot) { 'No action needed.' } else { 'Run cux doctor --fix to create the local store.' }) -Fixable (-not (Test-Path $paths.StoreRoot))),
        (New-CodecuxDoctorCheck -Name 'Profiles Root' -Status $(if (Test-Path $paths.ProfilesRoot) { 'OK' } else { 'WARN' }) -Details $(if (Test-Path $paths.ProfilesRoot) { 'Profiles directory exists.' } else { 'Profiles directory is missing.' }) -Recommendation $(if (Test-Path $paths.ProfilesRoot) { 'No action needed.' } else { 'Run cux doctor --fix to create the profiles directory.' }) -Fixable (-not (Test-Path $paths.ProfilesRoot))),
        (New-CodecuxDoctorCheck -Name 'Codex Command' -Status $(if ($codexInstalled) { 'OK' } else { 'WARN' }) -Details $(if ($codexInstalled) { 'codex command is available on PATH.' } else { 'codex command is not available on PATH.' }) -Recommendation $(if ($codexInstalled) { 'No action needed.' } else { 'Install Codex CLI and confirm `codex` works before using Codecux.' })),
        (New-CodecuxDoctorCheck -Name 'Codex Auth' -Status $(if (Test-Path $paths.CodexAuthPath) { 'OK' } else { 'WARN' }) -Details $(if (Test-Path $paths.CodexAuthPath) { 'Codex auth.json exists.' } else { 'Codex auth.json is missing.' }) -Recommendation $(if (Test-Path $paths.CodexAuthPath) { 'No action needed.' } else { 'Run `codex login` to establish a live Codex login.' })),
        (New-CodecuxDoctorCheck -Name 'OpenCode' -Status $(if ($opencodeInstalled) { 'OK' } else { 'OK' }) -Details $(if ($opencodeInstalled) { 'opencode command is available on PATH.' } else { 'OpenCode is not installed. This is optional.' }) -Recommendation $(if ($opencodeInstalled) { 'No action needed.' } else { 'Install OpenCode only if you want Codecux to keep it in sync.' })),
        (New-CodecuxDoctorCheck -Name 'Shim' -Status $(if (Test-Path $shimPath) { 'OK' } else { 'WARN' }) -Details $(if (Test-Path $shimPath) { 'cux.cmd shim exists in WindowsApps.' } else { 'cux.cmd shim is missing from WindowsApps.' }) -Recommendation $(if (Test-Path $shimPath) { 'No action needed.' } else { 'Run cux doctor --fix to reinstall the shim.' }) -Fixable (-not (Test-Path $shimPath))),
        (Get-CodecuxDoctorProfileCheck -Name 'PowerShell 5 Profile' -ProfilePath $ps5Profile),
        (Get-CodecuxDoctorProfileCheck -Name 'PowerShell 7 Profile' -ProfilePath $ps7Profile)
    )

    $issueChecks = @($checks | Where-Object { $_.Status -ne 'OK' })
    $fixableChecks = @($checks | Where-Object { $_.Fixable })
    $summaryStatus = if ($issueChecks.Count -eq 0) { 'OK' } else { 'WARN' }

    [pscustomobject]@{
        Summary = [pscustomobject]@{
            Status = $summaryStatus
            IssueCount = $issueChecks.Count
            FixableCount = $fixableChecks.Count
        }
        Checks = $checks
    }
}
