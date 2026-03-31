Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'Codecux.psm1'
Import-Module $modulePath -Force

function Show-CodecuxHelp {
    $lines = @(
        'Codecux (`cux`) commands:',
        '  cux add <name> [--api-key] [--api-key-value <key>] [--store-root <path>] [--codex-root <path>] [--opencode-root <path>]',
        '  cux list [--store-root <path>] [--codex-root <path>] [--opencode-root <path>]',
        '  cux use <name> [--store-root <path>] [--codex-root <path>] [--opencode-root <path>]',
        '  cux current [--store-root <path>] [--codex-root <path>] [--opencode-root <path>]',
        '  cux rename <old> <new> [--store-root <path>] [--codex-root <path>] [--opencode-root <path>]',
        '  cux remove <name> [--store-root <path>] [--codex-root <path>] [--opencode-root <path>]',
        '  cux status [--store-root <path>] [--codex-root <path>] [--opencode-root <path>]',
        '  cux doctor [--fix] [--store-root <path>] [--codex-root <path>] [--opencode-root <path>]',
        '  cux dashboard|dash [--store-root <path>] [--codex-root <path>] [--opencode-root <path>]',
        '  cux help'
    )
    $lines -join [Environment]::NewLine
}

function Get-CodecuxDashboardWidth {
    try {
        $windowWidth = [Math]::Max(72, ($Host.UI.RawUI.WindowSize.Width - 1))
        return [Math]::Min(110, $windowWidth)
    }
    catch {
        return 100
    }
}

function Write-CodecuxDashboardFrame {
    param(
        [Parameter(Mandatory = $true)][string]$Frame,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][ref]$PreviousLineCount
    )

    $lines = @($Frame -split "`r?`n")
    $blankCount = [Math]::Max(0, $PreviousLineCount.Value - $lines.Count)
    for ($i = 0; $i -lt $blankCount; $i++) {
        $lines += (' ' * $Width)
    }

    try {
        $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, 0
    }
    catch {
        Clear-Host
    }

    Write-Host (($lines -join [Environment]::NewLine)) -NoNewline
    $PreviousLineCount.Value = $lines.Count
}

function Get-CodecuxDashboardSnapshotForCli {
    param($Parsed)
    Get-CodecuxDashboardSnapshot -StoreRoot $Parsed.StoreRoot -CodexRoot $Parsed.CodexRoot -OpencodeRoot $Parsed.OpencodeRoot
}

function Get-CodecuxCurrentProfileNameForCli {
    param($Parsed)

    $current = Get-CodecuxCurrentProfile -StoreRoot $Parsed.StoreRoot -CodexRoot $Parsed.CodexRoot -OpencodeRoot $Parsed.OpencodeRoot
    if ($null -eq $current) { return '' }
    [string]$current.name
}

function Start-CodecuxDashboardRefreshWorker {
    param(
        [Parameter(Mandatory = $true)]$Parsed,
        [Parameter(Mandatory = $true)][ValidateSet('all', 'current')][string]$Mode,
        [string]$ProfileName
    )

    if ($Mode -eq 'current' -and [string]::IsNullOrWhiteSpace([string]$ProfileName)) {
        return $null
    }

    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($ModulePath, $Mode, $StoreRoot, $CodexRoot, $OpencodeRoot, $ProfileName)
        $ErrorActionPreference = 'Stop'
        Import-Module $ModulePath -Force

        if ($Mode -eq 'all') {
            [pscustomobject]@{
                Mode = 'all'
                ProbeResults = Get-CodecuxProfileRateLimitResults -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
            }
            return
        }

        [pscustomobject]@{
            Mode = 'current'
            ProfileName = $ProfileName
            ProbeResult = Get-CodecuxProfileRateLimitResult -Name $ProfileName -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
        }
    }).AddArgument($modulePath).AddArgument($Mode).AddArgument($Parsed.StoreRoot).AddArgument($Parsed.CodexRoot).AddArgument($Parsed.OpencodeRoot).AddArgument($ProfileName)

    [pscustomobject]@{
        PowerShell = $ps
        Handle     = $ps.BeginInvoke()
        Mode       = $Mode
    }
}

function Receive-CodecuxDashboardRefreshWorkerResult {
    param([Parameter(Mandatory = $true)]$Worker)

    try {
        $output = @($Worker.PowerShell.EndInvoke($Worker.Handle))
        $result = if ($output.Count -gt 0) { $output[-1] } else { $null }
        return [pscustomobject]@{
            Succeeded = $true
            Mode = if ($null -ne $result) { [string](Get-CodecuxObjectPropertyValue -Object $result -Name 'Mode') } else { '' }
            ProbeResults = if ($null -ne $result) { Get-CodecuxObjectPropertyValue -Object $result -Name 'ProbeResults' } else { $null }
            ProfileName = if ($null -ne $result) { [string](Get-CodecuxObjectPropertyValue -Object $result -Name 'ProfileName') } else { '' }
            ProbeResult = if ($null -ne $result) { Get-CodecuxObjectPropertyValue -Object $result -Name 'ProbeResult' } else { $null }
            Message = ''
        }
    }
    catch {
        $message = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace([string]$message)) { $message = 'Refresh failed.' }
        return [pscustomobject]@{
            Succeeded = $false
            Mode = ''
            ProbeResults = $null
            ProfileName = ''
            ProbeResult = $null
            Message = $message
        }
    }
    finally {
        try {
            $Worker.PowerShell.Dispose()
        }
        catch {
        }
    }
}

function Apply-CodecuxDashboardRefreshWorkerResult {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)]$Parsed,
        [Parameter(Mandatory = $true)]$Result
    )

    if (-not $Result.Succeeded) {
        return [pscustomobject]@{
            Snapshot = $Snapshot
            Message = [string]$Result.Message
        }
    }

    if ($Result.Mode -eq 'all') {
        $newSnapshot = Get-CodecuxDashboardSnapshot -StoreRoot $Parsed.StoreRoot -CodexRoot $Parsed.CodexRoot -OpencodeRoot $Parsed.OpencodeRoot -ProbeResults $Result.ProbeResults
        return [pscustomobject]@{
            Snapshot = $newSnapshot
            Message = 'refreshed all profiles'
        }
    }

    $currentName = Get-CodecuxCurrentProfileNameForCli -Parsed $Parsed
    [void](Set-CodecuxDashboardCurrentProfileName -Snapshot $Snapshot -CurrentProfileName $currentName)
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.ProfileName) -and $null -ne $Result.ProbeResult) {
        $Snapshot = Update-CodecuxDashboardSnapshotRow -Snapshot $Snapshot -ProfileName $Result.ProfileName -ProbeResult $Result.ProbeResult
    }

    $message = if ([string]::IsNullOrWhiteSpace([string]$Result.ProfileName)) {
        'updated current profile'
    }
    else {
        'updated ' + [string]$Result.ProfileName
    }

    [pscustomobject]@{
        Snapshot = $Snapshot
        Message = $message
    }
}

function Start-CodecuxDashboardWindow {
    param($Parsed, [Parameter(Mandatory = $true)][string]$EntryScriptPath)

    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $PSHOME 'powershell.exe' }
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $EntryScriptPath, 'dashboard-host')
    if (-not [string]::IsNullOrWhiteSpace($Parsed.StoreRoot)) {
        $args += @('--store-root', $Parsed.StoreRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($Parsed.CodexRoot)) {
        $args += @('--codex-root', $Parsed.CodexRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($Parsed.OpencodeRoot)) {
        $args += @('--opencode-root', $Parsed.OpencodeRoot)
    }

    Start-Process -FilePath $psExe -ArgumentList $args -WindowStyle Maximized | Out-Null
}

function Invoke-CodecuxDashboardHost {
    param($Parsed)

    try {
        $Host.UI.RawUI.WindowTitle = 'Codecux Dashboard'
    }
    catch {
    }

    $selectedIndex = 0
    $statusMessage = 'probing profiles'
    $snapshot = Get-CodecuxDashboardSnapshotForCli -Parsed $Parsed
    $previousLineCount = 0
    $currentRefreshDeadline = (Get-Date).AddSeconds(15)
    $fullRefreshDeadline = (Get-Date).AddMinutes(3)
    $refreshWorker = Start-CodecuxDashboardRefreshWorker -Parsed $Parsed -Mode 'all'
    $pendingManualFullRefresh = $false
    $pendingCurrentProfileName = ''

    try {
        [Console]::CursorVisible = $false
    }
    catch {
    }

    try {
        while ($true) {
            $rows = @($snapshot.Rows)
            if ($rows.Count -eq 0) {
                $selectedIndex = 0
            }
            elseif ($selectedIndex -ge $rows.Count) {
                $selectedIndex = $rows.Count - 1
            }

            $width = Get-CodecuxDashboardWidth
            $frame = Format-CodecuxDashboard -Snapshot $snapshot -SelectedIndex $selectedIndex -Width $width -StatusMessage $statusMessage
            Write-CodecuxDashboardFrame -Frame $frame -Width $width -PreviousLineCount ([ref]$previousLineCount)
            $statusMessage = ''

            while ($true) {
                if ($null -ne $refreshWorker -and $refreshWorker.Handle.IsCompleted) {
                    $result = Receive-CodecuxDashboardRefreshWorkerResult -Worker $refreshWorker
                    $refreshWorker = $null
                    $applied = Apply-CodecuxDashboardRefreshWorkerResult -Snapshot $snapshot -Parsed $Parsed -Result $result
                    $snapshot = $applied.Snapshot
                    $statusMessage = $applied.Message
                    if ($pendingManualFullRefresh) {
                        $refreshWorker = Start-CodecuxDashboardRefreshWorker -Parsed $Parsed -Mode 'all'
                        $pendingManualFullRefresh = $false
                        $pendingCurrentProfileName = ''
                        if ($null -ne $refreshWorker) {
                            $statusMessage = 'refreshing all profiles'
                        }
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace([string]$pendingCurrentProfileName)) {
                        $refreshWorker = Start-CodecuxDashboardRefreshWorker -Parsed $Parsed -Mode 'current' -ProfileName $pendingCurrentProfileName
                        $pendingCurrentProfileName = ''
                        if ($null -ne $refreshWorker) {
                            $statusMessage = 'refreshing current profile'
                        }
                    }
                    break
                }

                $keyPoll = Read-CodecuxConsoleKeySafely
                if (-not [string]::IsNullOrWhiteSpace([string]$keyPoll.Error)) {
                    if ([string]::IsNullOrWhiteSpace([string]$statusMessage)) {
                        $statusMessage = $keyPoll.Error
                    }
                    break
                }

                if ($keyPoll.HasKey) {
                    $key = $keyPoll.Key
                    switch ($key.Key) {
                        'Q' {
                            return
                        }
                        'UpArrow' {
                            if ($selectedIndex -gt 0) { $selectedIndex -= 1 }
                            break
                        }
                        'DownArrow' {
                            if ($selectedIndex -lt ($rows.Count - 1)) { $selectedIndex += 1 }
                            break
                        }
                        'R' {
                            if ($null -eq $refreshWorker) {
                                $refreshWorker = Start-CodecuxDashboardRefreshWorker -Parsed $Parsed -Mode 'all'
                                if ($null -ne $refreshWorker) {
                                    $statusMessage = 'refreshing all profiles'
                                }
                            }
                            else {
                                $pendingManualFullRefresh = $true
                                $statusMessage = 'queued full refresh'
                            }
                            $currentRefreshDeadline = (Get-Date).AddSeconds(15)
                            $fullRefreshDeadline = (Get-Date).AddMinutes(3)
                            break
                        }
                        'U' {
                            if ($rows.Count -gt 0) {
                                $name = $rows[$selectedIndex].Name
                                try {
                                    Use-CodecuxProfile -Name $name -StoreRoot $Parsed.StoreRoot -CodexRoot $Parsed.CodexRoot -OpencodeRoot $Parsed.OpencodeRoot | Out-Null
                                    [void](Set-CodecuxDashboardCurrentProfileName -Snapshot $snapshot -CurrentProfileName $name)
                                    $rows = @($snapshot.Rows)
                                    for ($i = 0; $i -lt $rows.Count; $i++) {
                                        if ($rows[$i].Name -eq $name) {
                                            $selectedIndex = $i
                                            break
                                        }
                                    }
                                    if ($null -eq $refreshWorker) {
                                        $refreshWorker = Start-CodecuxDashboardRefreshWorker -Parsed $Parsed -Mode 'current' -ProfileName $name
                                        $statusMessage = if ($null -ne $refreshWorker) { "switched to $name - refreshing" } else { "switched to $name" }
                                    }
                                    else {
                                        $pendingCurrentProfileName = $name
                                        $statusMessage = "switched to $name - refresh queued"
                                    }
                                }
                                catch {
                                    $statusMessage = $_.Exception.Message
                                }
                            }
                            $currentRefreshDeadline = (Get-Date).AddSeconds(15)
                            break
                        }
                        'Enter' {
                            if ($rows.Count -gt 0) {
                                $name = $rows[$selectedIndex].Name
                                try {
                                    Use-CodecuxProfile -Name $name -StoreRoot $Parsed.StoreRoot -CodexRoot $Parsed.CodexRoot -OpencodeRoot $Parsed.OpencodeRoot | Out-Null
                                    [void](Set-CodecuxDashboardCurrentProfileName -Snapshot $snapshot -CurrentProfileName $name)
                                    $rows = @($snapshot.Rows)
                                    for ($i = 0; $i -lt $rows.Count; $i++) {
                                        if ($rows[$i].Name -eq $name) {
                                            $selectedIndex = $i
                                            break
                                        }
                                    }
                                    if ($null -eq $refreshWorker) {
                                        $refreshWorker = Start-CodecuxDashboardRefreshWorker -Parsed $Parsed -Mode 'current' -ProfileName $name
                                        $statusMessage = if ($null -ne $refreshWorker) { "switched to $name - refreshing" } else { "switched to $name" }
                                    }
                                    else {
                                        $pendingCurrentProfileName = $name
                                        $statusMessage = "switched to $name - refresh queued"
                                    }
                                }
                                catch {
                                    $statusMessage = $_.Exception.Message
                                }
                            }
                            $currentRefreshDeadline = (Get-Date).AddSeconds(15)
                            break
                        }
                    }
                    break
                }

                if ((Get-Date) -ge $fullRefreshDeadline) {
                    if ($null -eq $refreshWorker) {
                        $refreshWorker = Start-CodecuxDashboardRefreshWorker -Parsed $Parsed -Mode 'all'
                        if ($null -ne $refreshWorker) {
                            $statusMessage = 'refreshing all profiles'
                        }
                    }
                    $fullRefreshDeadline = (Get-Date).AddMinutes(3)
                    break
                }

                if ((Get-Date) -ge $currentRefreshDeadline) {
                    $currentName = Get-CodecuxCurrentProfileNameForCli -Parsed $Parsed
                    if ($null -eq $refreshWorker -and -not [string]::IsNullOrWhiteSpace([string]$currentName)) {
                        $refreshWorker = Start-CodecuxDashboardRefreshWorker -Parsed $Parsed -Mode 'current' -ProfileName $currentName
                        if ($null -ne $refreshWorker) {
                            $statusMessage = ('refreshing {0}' -f $currentName)
                        }
                    }
                    $currentRefreshDeadline = (Get-Date).AddSeconds(15)
                    break
                }

                Start-Sleep -Milliseconds 35
            }
        }
    }
    finally {
        if ($null -ne $refreshWorker) {
            try {
                $refreshWorker.PowerShell.Stop()
            }
            catch {
            }
            try {
                $refreshWorker.PowerShell.Dispose()
            }
            catch {
            }
        }
        try {
            [Console]::CursorVisible = $true
        }
        catch {
        }
    }
}

function Parse-CodecuxArguments {
    param([string[]]$RawArgs)

    $options = [ordered]@{
        Command      = ''
        Positionals  = New-Object System.Collections.Generic.List[string]
        StoreRoot    = ''
        CodexRoot    = ''
        OpencodeRoot = ''
        Fix          = $false
        ApiKeyMode   = $false
        ApiKeyValue  = ''
    }

    if (-not $RawArgs -or $RawArgs.Count -eq 0) {
        return [pscustomobject]$options
    }

    $options.Command = $RawArgs[0].ToLowerInvariant()
    $index = 1
    while ($index -lt $RawArgs.Count) {
        $arg = $RawArgs[$index]
        switch ($arg) {
            '--store-root' {
                if ($index + 1 -ge $RawArgs.Count) { throw '--store-root requires a value.' }
                $options.StoreRoot = $RawArgs[$index + 1]
                $index += 2
                continue
            }
            '--codex-root' {
                if ($index + 1 -ge $RawArgs.Count) { throw '--codex-root requires a value.' }
                $options.CodexRoot = $RawArgs[$index + 1]
                $index += 2
                continue
            }
            '--opencode-root' {
                if ($index + 1 -ge $RawArgs.Count) { throw '--opencode-root requires a value.' }
                $options.OpencodeRoot = $RawArgs[$index + 1]
                $index += 2
                continue
            }
            '--api-key' {
                $options.ApiKeyMode = $true
                $index += 1
                continue
            }
            '--fix' {
                $options.Fix = $true
                $index += 1
                continue
            }
            '--api-key-value' {
                if ($index + 1 -ge $RawArgs.Count) { throw '--api-key-value requires a value.' }
                $options.ApiKeyValue = $RawArgs[$index + 1]
                $index += 2
                continue
            }
            default {
                if ($arg.StartsWith('--')) {
                    throw ("Unknown option '{0}'. Run 'cux help'." -f $arg)
                }
                $options.Positionals.Add($arg)
                $index += 1
                continue
            }
        }
    }

    [pscustomobject]$options
}

function Resolve-CodecuxApiKeyValue {
    param($Parsed)
    if (-not $Parsed.ApiKeyMode) { return '' }
    if (-not [string]::IsNullOrWhiteSpace($Parsed.ApiKeyValue)) {
        Write-Warning 'WARNING: --api-key-value exposes your API key in shell history and process listings. Prefer $env:OPENAI_API_KEY or interactive prompt.'
        return $Parsed.ApiKeyValue
    }
    if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) { return $env:OPENAI_API_KEY }
    $secure = Read-Host 'Enter OPENAI_API_KEY' -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ([string]::IsNullOrWhiteSpace($plain)) { throw 'API key cannot be empty.' }
    $plain
}

function Invoke-CodecuxDoctorRepair {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $installScript = Join-Path $repoRoot 'scripts\install.ps1'
    if (-not (Test-Path $installScript)) {
        throw "Codecux install script was not found at '$installScript'."
    }

    $psExe = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { Join-Path $PSHOME 'powershell.exe' }
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $installScript
}

function Write-CodecuxDoctorReport {
    param([Parameter(Mandatory = $true)]$Doctor)

    $summary = Get-CodecuxObjectPropertyValue -Object $Doctor -Name 'Summary'
    Write-Output ('Codecux doctor: {0} ({1} issue(s), {2} fixable)' -f $summary.Status, $summary.IssueCount, $summary.FixableCount)
    foreach ($check in @(Get-CodecuxObjectPropertyValue -Object $Doctor -Name 'Checks')) {
        Write-Output ('[{0}] {1}: {2}' -f $check.Status, $check.Name, $check.Details)
        if ($check.Status -ne 'OK' -and -not [string]::IsNullOrWhiteSpace([string]$check.Recommendation)) {
            Write-Output ('  Recommendation: {0}' -f $check.Recommendation)
        }
    }
}

function Invoke-CodecuxCli {
    param(
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$EntryScriptPath
    )
    try {
        $parsed = Parse-CodecuxArguments -RawArgs $Arguments
        switch ($parsed.Command) {
            '' {
                Write-Output (Show-CodecuxHelp)
                exit 0
            }
            'help' {
                Write-Output (Show-CodecuxHelp)
                exit 0
            }
            'add' {
                if ($parsed.Positionals.Count -lt 1) { throw 'add requires a profile name.' }
                $apiKey = Resolve-CodecuxApiKeyValue -Parsed $parsed
                $profile = Add-CodecuxProfile -Name $parsed.Positionals[0] -StoreRoot $parsed.StoreRoot -CodexRoot $parsed.CodexRoot -OpencodeRoot $parsed.OpencodeRoot -ApiKey $apiKey
                Write-Output ("Saved profile {0} ({1})." -f $profile.name, $profile.type)
            }
            'list' {
                $profiles = @(Get-CodecuxProfiles -StoreRoot $parsed.StoreRoot -CodexRoot $parsed.CodexRoot -OpencodeRoot $parsed.OpencodeRoot)
                $current = Get-CodecuxCurrentProfile -StoreRoot $parsed.StoreRoot -CodexRoot $parsed.CodexRoot -OpencodeRoot $parsed.OpencodeRoot
                if ($profiles.Count -eq 0) {
                    Write-Output 'No Codecux profiles saved.'
                }
                else {
                    foreach ($profile in $profiles) {
                        $marker = if ($null -ne $current -and $current.name -eq $profile.name) { '*' } else { ' ' }
                        Write-Output ("{0} {1} [{2}] {3}" -f $marker, $profile.name, $profile.type, $profile.display)
                    }
                }
            }
            'use' {
                if ($parsed.Positionals.Count -lt 1) { throw 'use requires a profile name.' }
                $result = Use-CodecuxProfile -Name $parsed.Positionals[0] -StoreRoot $parsed.StoreRoot -CodexRoot $parsed.CodexRoot -OpencodeRoot $parsed.OpencodeRoot
                Write-Output ("Switched active profile to {0} ({1}) for Codex CLI and OpenCode." -f $result.Name, $result.Type)
                if ($result.CodexBackupPath) { Write-Output ("Codex backup   : {0}" -f $result.CodexBackupPath) }
                if ($result.OpencodeBackupPath) { Write-Output ("OpenCode backup: {0}" -f $result.OpencodeBackupPath) }
            }
            'current' {
                $status = Get-CodecuxStatus -StoreRoot $parsed.StoreRoot -CodexRoot $parsed.CodexRoot -OpencodeRoot $parsed.OpencodeRoot
                if ($status.DriftDetected) {
                    Write-Output ("Profile drift detected: codex={0}, opencode={1}" -f ($(if ($status.CodexProfile) { $status.CodexProfile } else { '(none)' })), ($(if ($status.OpencodeProfile) { $status.OpencodeProfile } else { '(none)' })))
                }
                elseif ([string]::IsNullOrWhiteSpace($status.CurrentProfile)) {
                    Write-Output 'No saved Codecux profile is currently active.'
                }
                else {
                    Write-Output ("Current profile: {0}" -f $status.CurrentProfile)
                }
            }
            'rename' {
                if ($parsed.Positionals.Count -lt 2) { throw 'rename requires <old> and <new> names.' }
                $profile = Rename-CodecuxProfile -Name $parsed.Positionals[0] -NewName $parsed.Positionals[1] -StoreRoot $parsed.StoreRoot -CodexRoot $parsed.CodexRoot -OpencodeRoot $parsed.OpencodeRoot
                Write-Output ("Renamed profile to {0}." -f $profile.name)
            }
            'remove' {
                if ($parsed.Positionals.Count -lt 1) { throw 'remove requires a profile name.' }
                Remove-CodecuxProfile -Name $parsed.Positionals[0] -StoreRoot $parsed.StoreRoot -CodexRoot $parsed.CodexRoot -OpencodeRoot $parsed.OpencodeRoot | Out-Null
                Write-Output ("Removed profile {0}." -f $parsed.Positionals[0])
            }
            'status' {
                $status = Get-CodecuxStatus -StoreRoot $parsed.StoreRoot -CodexRoot $parsed.CodexRoot -OpencodeRoot $parsed.OpencodeRoot
                Write-Output ("Current profile   : {0}" -f ($(if ([string]::IsNullOrWhiteSpace($status.CurrentProfile)) { '(none)' } else { $status.CurrentProfile })))
                Write-Output ("Saved profiles    : {0}" -f $status.ProfileCount)
                Write-Output ("Codex installed   : {0}" -f $status.CodexInstalled)
                Write-Output ("OpenCode installed: {0}" -f $status.OpencodeInstalled)
                Write-Output ("Codex auth path   : {0}" -f $status.CodexAuthPath)
                Write-Output ("OpenCode auth path: {0}" -f $status.OpencodeAuthPath)
                Write-Output ("Targets in sync   : {0}" -f $status.TargetsInSync)
                Write-Output ("Drift detected    : {0}" -f $status.DriftDetected)
                Write-Output ("Codex profile     : {0}" -f ($(if ([string]::IsNullOrWhiteSpace($status.CodexProfile)) { '(none)' } else { $status.CodexProfile })))
                Write-Output ("OpenCode profile  : {0}" -f ($(if ([string]::IsNullOrWhiteSpace($status.OpencodeProfile)) { '(none)' } else { $status.OpencodeProfile })))
                Write-Output ("Store root        : {0}" -f $status.StoreRoot)
                $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
                if ($null -ne $codexCommand) {
                    Write-Output 'codex login status:'
                    & codex login status
                }
            }
            'doctor' {
                if ($parsed.Fix) {
                    Write-Output 'Repairing Codecux shell integration...'
                    Invoke-CodecuxDoctorRepair | ForEach-Object { Write-Output $_ }
                }
                $doctor = Get-CodecuxDoctor -StoreRoot $parsed.StoreRoot -CodexRoot $parsed.CodexRoot -OpencodeRoot $parsed.OpencodeRoot
                Write-CodecuxDoctorReport -Doctor $doctor
            }
            'dashboard' {
                Start-CodecuxDashboardWindow -Parsed $parsed -EntryScriptPath $EntryScriptPath
                Write-Output 'Opened Codecux dashboard.'
            }
            'dash' {
                Start-CodecuxDashboardWindow -Parsed $parsed -EntryScriptPath $EntryScriptPath
                Write-Output 'Opened Codecux dashboard.'
            }
            'dashboard-host' {
                Invoke-CodecuxDashboardHost -Parsed $parsed
            }
            default {
                throw ("Unknown command '{0}'. Run 'cux help'." -f $parsed.Command)
            }
        }
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

Export-ModuleMember -Function @('Invoke-CodecuxCli')
