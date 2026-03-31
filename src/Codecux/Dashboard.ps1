function Get-CodecuxDashboardAccessStatus {
    param([Parameter(Mandatory = $true)]$CanonicalAuth)

    $canonical = ConvertTo-CodecuxCanonicalAuthObject -RawAuthObject $CanonicalAuth
    if ($canonical.type -eq 'api') { return 'API' }
    if ([string]::IsNullOrWhiteSpace([string]$canonical.access) -or [string]::IsNullOrWhiteSpace([string]$canonical.refresh) -or $canonical.expires -le 0) {
        return 'MISSING'
    }
    if ([int64]$canonical.expires -le [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { return 'EXPIRED' }
    'VALID'
}

function Get-CodecuxDashboardTargetStatus {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)]$TargetSummary
    )

    $codexMatch = ($null -ne $TargetSummary.CodexProfile -and $TargetSummary.CodexProfile.name -eq $ProfileName)
    $opencodeMatch = ($null -ne $TargetSummary.OpencodeProfile -and $TargetSummary.OpencodeProfile.name -eq $ProfileName)

    if ($codexMatch -and $opencodeMatch) { return 'SYNC' }
    if ($codexMatch) { return 'CODX' }
    if ($opencodeMatch) { return 'OPEN' }
    '--'
}

function Get-CodecuxPrimaryRateLimitSnapshot {
    param([Parameter(Mandatory = $true)]$RateLimitResponse)

    $rateLimitsByLimitId = Get-CodecuxObjectPropertyValue -Object $RateLimitResponse -Name 'rateLimitsByLimitId'
    if ($null -ne $rateLimitsByLimitId) {
        $codex = Get-CodecuxObjectPropertyValue -Object $rateLimitsByLimitId -Name 'codex'
        if ($null -ne $codex) { return $codex }

        if ($rateLimitsByLimitId -is [System.Collections.IDictionary]) {
            foreach ($entry in $rateLimitsByLimitId.GetEnumerator()) {
                if ($null -ne $entry.Value) { return $entry.Value }
            }
        }
        elseif ($rateLimitsByLimitId.PSObject -and $rateLimitsByLimitId.PSObject.Properties.Count -gt 0) {
            foreach ($property in $rateLimitsByLimitId.PSObject.Properties) {
                if ($null -ne $property.Value) { return $property.Value }
            }
        }
    }

    Get-CodecuxObjectPropertyValue -Object $RateLimitResponse -Name 'rateLimits'
}

function Get-CodecuxRateLimitWindowLabel {
    param($WindowDurationMins)

    if ($null -eq $WindowDurationMins) { return '' }
    $minutes = [int]$WindowDurationMins
    if ($minutes -ge 10080) { return 'weekly' }
    if ($minutes -ge 1440) { return ('{0}d' -f [Math]::Floor($minutes / 1440)) }
    if ($minutes -ge 60) { return ('{0}h' -f [Math]::Floor($minutes / 60)) }
    ('{0}m' -f $minutes)
}

function Format-CodecuxRateLimitResetDisplay {
    param($ResetsAt)

    if ($null -eq $ResetsAt) { return '--' }
    $value = [int64]$ResetsAt
    if ($value -le 0) { return '--' }

    $moment = if ($value -ge 1000000000000) {
        [DateTimeOffset]::FromUnixTimeMilliseconds($value)
    }
    else {
        [DateTimeOffset]::FromUnixTimeSeconds($value)
    }

    $moment.ToLocalTime().ToString('dd MMM HH:mm')
}

function ConvertTo-CodecuxRateLimitProbeResult {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$RateLimitResponse)

    $snapshot = Get-CodecuxPrimaryRateLimitSnapshot -RateLimitResponse $RateLimitResponse
    if ($null -eq $snapshot) {
        return [pscustomobject]@{
            Status         = 'UNAVAIL'
            PercentLeft    = $null
            PercentDisplay = '--'
            ResetDisplay   = '--'
            WindowLabel    = ''
            LastUpdatedAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
    }

    $primary = Get-CodecuxObjectPropertyValue -Object $snapshot -Name 'primary'
    if ($null -eq $primary) {
        return [pscustomobject]@{
            Status         = 'UNAVAIL'
            PercentLeft    = $null
            PercentDisplay = '--'
            ResetDisplay   = '--'
            WindowLabel    = ''
            LastUpdatedAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
    }

    $usedPercent = [int](Get-CodecuxObjectPropertyValue -Object $primary -Name 'usedPercent')
    $percentLeft = [Math]::Max(0, [Math]::Min(100, 100 - $usedPercent))
    $windowDurationMins = Get-CodecuxObjectPropertyValue -Object $primary -Name 'windowDurationMins'
    $resetsAt = Get-CodecuxObjectPropertyValue -Object $primary -Name 'resetsAt'

    [pscustomobject]@{
        Status         = 'OK'
        PercentLeft    = $percentLeft
        PercentDisplay = ('{0}%%' -f $percentLeft).Replace('%%','%')
        ResetDisplay   = Format-CodecuxRateLimitResetDisplay -ResetsAt $resetsAt
        WindowLabel    = Get-CodecuxRateLimitWindowLabel -WindowDurationMins $windowDurationMins
        LastUpdatedAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
}

function New-CodecuxRateLimitResult {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$PercentDisplay = '--',
        $PercentLeft = $null,
        [string]$ResetDisplay = '--',
        [string]$WindowLabel = '',
        [string]$ErrorMessage = ''
    )

    [pscustomobject]@{
        Status         = $Status
        PercentLeft    = $PercentLeft
        PercentDisplay = $PercentDisplay
        ResetDisplay   = $ResetDisplay
        WindowLabel    = $WindowLabel
        LastUpdatedAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        ErrorMessage   = $ErrorMessage
    }
}

function Get-CodecuxRateLimitProbeFailureResult {
    param([Parameter(Mandatory = $true)][string]$Message)

    $status = if ($Message -match '(?i)auth|login|required|unauthorized|forbidden|token') { 'AUTH' } else { 'ERR' }
    New-CodecuxRateLimitResult -Status $status -ErrorMessage $Message
}

function Get-CodecuxDefaultProbeResult {
    param([Parameter(Mandatory = $true)]$CanonicalAuth)

    $accessStatus = Get-CodecuxDashboardAccessStatus -CanonicalAuth $CanonicalAuth
    $status = if ($accessStatus -eq 'MISSING') { 'AUTH' } else { 'UNAVAIL' }

    [pscustomobject]@{
        Status         = $status
        PercentLeft    = $null
        PercentDisplay = '--'
        ResetDisplay   = '--'
        WindowLabel    = ''
        LastUpdatedAt  = ''
    }
}

function Set-CodecuxDashboardCurrentProfileName {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [string]$CurrentProfileName,
        [ValidateSet('', 'SYNC', 'CODX', 'OPEN')][string]$CurrentTargetStatus = 'SYNC'
    )

    foreach ($row in @($Snapshot.Rows)) {
        $row.IsCurrent = (-not [string]::IsNullOrWhiteSpace([string]$CurrentProfileName) -and $row.Name -eq $CurrentProfileName)
        if ($row.IsCurrent) {
            $row.TargetStatus = $CurrentTargetStatus
            continue
        }

        if ($row.TargetStatus -in @('SYNC', 'CODX', 'OPEN')) {
            $row.TargetStatus = '--'
        }
    }
    $Snapshot.CurrentProfile = if ([string]::IsNullOrWhiteSpace([string]$CurrentProfileName)) { '' } else { $CurrentProfileName }
    $Snapshot
}

function Update-CodecuxDashboardSnapshotRow {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)]$ProbeResult
    )

    foreach ($row in @($Snapshot.Rows)) {
        if ($row.Name -eq $ProfileName) {
            $row.QuotaDisplay = [string]$ProbeResult.PercentDisplay
            $row.ResetDisplay = [string]$ProbeResult.ResetDisplay
            $row.RowStatus = [string]$ProbeResult.Status
            $row.LastUpdatedAt = [string]$ProbeResult.LastUpdatedAt
        }
    }
    $Snapshot.LastRefreshDisplay = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $Snapshot
}

function Get-CodecuxDashboardSnapshot {
    [CmdletBinding()]
    param(
        [string]$StoreRoot,
        [string]$CodexRoot,
        [string]$OpencodeRoot,
        [hashtable]$ProbeResults
    )

    $paths = Resolve-CodecuxPaths -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    $profiles = @(Get-CodecuxProfiles -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot)
    $status = Get-CodecuxStatus -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    $targetSummary = Get-CodecuxCurrentTargetSummary -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot

    $rows = foreach ($profile in $profiles) {
        $probeResult = $null
        try {
            $authPath = Get-CodecuxProfileAuthPath -Name $profile.name -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
            $canonicalAuth = ConvertTo-CodecuxCanonicalAuthObject -RawAuthObject (Read-CodecuxJsonFile -Path $authPath)
            $probeResult = if ($null -ne $ProbeResults -and $ProbeResults.ContainsKey($profile.name)) {
                $ProbeResults[$profile.name]
            }
            else {
                Get-CodecuxDefaultProbeResult -CanonicalAuth $canonicalAuth
            }
        }
        catch {
            $probeResult = New-CodecuxRateLimitResult -Status 'ERR' -ErrorMessage $_.Exception.Message
        }

        [pscustomobject]@{
            Name           = $profile.name
            Type           = $profile.type
            Display        = $profile.display
            TargetStatus   = Get-CodecuxDashboardTargetStatus -ProfileName $profile.name -TargetSummary $targetSummary
            QuotaDisplay   = [string](Get-CodecuxObjectPropertyValue -Object $probeResult -Name 'PercentDisplay')
            ResetDisplay   = [string](Get-CodecuxObjectPropertyValue -Object $probeResult -Name 'ResetDisplay')
            RowStatus      = [string](Get-CodecuxObjectPropertyValue -Object $probeResult -Name 'Status')
            LastUpdatedAt  = [string](Get-CodecuxObjectPropertyValue -Object $probeResult -Name 'LastUpdatedAt')
            IsCurrent      = (-not [string]::IsNullOrWhiteSpace([string]$status.CurrentProfile) -and $status.CurrentProfile -eq $profile.name)
        }
    }

    [pscustomobject]@{
        Title              = 'Codecux Dashboard'
        CurrentProfile     = $status.CurrentProfile
        DriftDetected      = $status.DriftDetected
        TargetsInSync      = $status.TargetsInSync
        LastRefreshDisplay = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Rows               = @($rows)
    }
}

function New-CodecuxDashboardContentLine {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][int]$Width)
    $contentWidth = [Math]::Max(1, $Width - 4)
    $safeText = $Text
    if ($safeText.Length -gt $contentWidth) {
        $safeText = $safeText.Substring(0, $contentWidth)
    }
    $border = [string][char]0x2502
    $border + ' ' + $safeText.PadRight($contentWidth) + ' ' + $border
}

function Get-CodecuxDashboardBar {
    param(
        [string]$QuotaDisplay,
        [int]$Width = 12
    )

    $emptyGlyph = [string][char]0x25B1
    $filledGlyph = [string][char]0x25B0
    $emptyBar = ($emptyGlyph * $Width)
    if ([string]::IsNullOrWhiteSpace([string]$QuotaDisplay) -or $QuotaDisplay -eq '--') {
        return $emptyBar
    }

    $match = [regex]::Match([string]$QuotaDisplay, '^(\d{1,3})%$')
    if (-not $match.Success) {
        return $emptyBar
    }

    $percent = [int]$match.Groups[1].Value
    $percent = [Math]::Max(0, [Math]::Min(100, $percent))
    $filled = [int][Math]::Round(($percent / 100.0) * $Width, [System.MidpointRounding]::AwayFromZero)
    $filled = [Math]::Max(0, [Math]::Min($Width, $filled))
    ($filledGlyph * $filled) + ($emptyGlyph * ($Width - $filled))
}

function Get-CodecuxDashboardIndicator {
    param(
        [bool]$IsSelected,
        [bool]$IsCurrent
    )

    $selected = [string][char]0x25B6
    $current = [string][char]0x25CF
    if ($IsSelected -and $IsCurrent) { return $selected + $current }
    if ($IsSelected) { return $selected + ' ' }
    if ($IsCurrent) { return $current + ' ' }
    '  '
}

function Read-CodecuxConsoleKeySafely {
    [CmdletBinding()]
    param(
        [scriptblock]$GetKeyAvailable = { [Console]::KeyAvailable },
        [scriptblock]$ReadKey = { [Console]::ReadKey($true) }
    )

    try {
        $hasKey = [bool](& $GetKeyAvailable)
    }
    catch {
        return [pscustomobject]@{
            HasKey = $false
            Key    = $null
            Error  = $_.Exception.Message
        }
    }

    if (-not $hasKey) {
        return [pscustomobject]@{
            HasKey = $false
            Key    = $null
            Error  = ''
        }
    }

    try {
        $key = & $ReadKey
        return [pscustomobject]@{
            HasKey = $true
            Key    = $key
            Error  = ''
        }
    }
    catch {
        return [pscustomobject]@{
            HasKey = $false
            Key    = $null
            Error  = $_.Exception.Message
        }
    }
}

function New-CodecuxDashboardBorder {
    param([Parameter(Mandatory = $true)][int]$Width, [Parameter(Mandatory = $true)][string]$Kind)
    $inner = [Math]::Max(1, $Width - 2)
    $horizontal = [string][char]0x2500
    switch ($Kind) {
        'top' { return ([string][char]0x250C) + ($horizontal * $inner) + ([string][char]0x2510) }
        'middle' { return ([string][char]0x251C) + ($horizontal * $inner) + ([string][char]0x2524) }
        'bottom' { return ([string][char]0x2514) + ($horizontal * $inner) + ([string][char]0x2518) }
        default { throw "Unknown dashboard border kind '$Kind'." }
    }
}

function Format-CodecuxDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [int]$SelectedIndex = 0,
        [int]$Width = 100,
        [string]$StatusMessage = ''
    )

    $title = Get-CodecuxObjectPropertyValue -Object $Snapshot -Name 'Title'
    $currentProfile = Get-CodecuxObjectPropertyValue -Object $Snapshot -Name 'CurrentProfile'
    $driftDetected = [bool](Get-CodecuxObjectPropertyValue -Object $Snapshot -Name 'DriftDetected')
    $targetsInSyncValue = Get-CodecuxObjectPropertyValue -Object $Snapshot -Name 'TargetsInSync'
    $targetsInSync = if ($null -eq $targetsInSyncValue) { $false } else { [bool]$targetsInSyncValue }
    $lastRefreshDisplay = Get-CodecuxObjectPropertyValue -Object $Snapshot -Name 'LastRefreshDisplay'

    $width = [Math]::Max(92, $Width)
    $rows = @(Get-CodecuxObjectPropertyValue -Object $Snapshot -Name 'Rows')
    if ($rows.Count -gt 0) {
        $SelectedIndex = [Math]::Max(0, [Math]::Min($SelectedIndex, $rows.Count - 1))
    }
    else {
        $SelectedIndex = 0
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((New-CodecuxDashboardBorder -Width $width -Kind 'top'))
    $lines.Add((New-CodecuxDashboardContentLine -Width $width -Text ([string]$title)))

    $activeLabel = if ([string]::IsNullOrWhiteSpace([string]$currentProfile)) { '(none)' } else { [string]$currentProfile }
    $syncLabel = if ($driftDetected) { 'DRIFT' } elseif ($targetsInSync) { 'OK' } else { 'PARTIAL' }
    $bullet = [string][char]0x2022
    $summaryText = ('Active: {0} {1} Sync: {2} {1} Profiles: {3}' -f $activeLabel, $bullet, $syncLabel, @($rows).Count)
    $lines.Add((New-CodecuxDashboardContentLine -Width $width -Text $summaryText))
    $lines.Add((New-CodecuxDashboardBorder -Width $width -Kind 'middle'))
    $lines.Add((New-CodecuxDashboardContentLine -Width $width -Text ('  {0,-18} {1,-6} {2,-20} {3,-12} {4,-7}' -f 'Profile', 'Tgt', 'Left', 'Reset', 'State')))
    $lines.Add((New-CodecuxDashboardBorder -Width $width -Kind 'middle'))

    if ($rows.Count -eq 0) {
        $lines.Add((New-CodecuxDashboardContentLine -Width $width -Text 'No Codecux profiles saved.'))
    }
    else {
        for ($index = 0; $index -lt $rows.Count; $index++) {
            $row = $rows[$index]
            $indicator = Get-CodecuxDashboardIndicator -IsSelected ($index -eq $SelectedIndex) -IsCurrent ([bool]$row.IsCurrent)
            $target = [string]$row.TargetStatus
            $bar = Get-CodecuxDashboardBar -QuotaDisplay ([string]$row.QuotaDisplay) -Width 12
            $leftCell = ('{0} {1,4}' -f $bar, [string]$row.QuotaDisplay)
            $rowText = ('{0}{1,-18} {2,-6} {3,-20} {4,-12} {5,-7}' -f $indicator, $row.Name, $target, $leftCell, $row.ResetDisplay, $row.RowStatus)
            $lines.Add((New-CodecuxDashboardContentLine -Width $width -Text $rowText))
        }
    }

    $lines.Add((New-CodecuxDashboardBorder -Width $width -Kind 'middle'))
    $statusLine = if ([string]::IsNullOrWhiteSpace([string]$StatusMessage)) { 'Status: ready' } else { 'Status: ' + $StatusMessage }
    $upArrow = [string][char]0x2191
    $downArrow = [string][char]0x2193
    $lines.Add((New-CodecuxDashboardContentLine -Width $width -Text ('Refreshed: {0} {1} Auto: 03:00 {1} {2}' -f [string]$lastRefreshDisplay, $bullet, $statusLine)))
    $lines.Add((New-CodecuxDashboardContentLine -Width $width -Text ('Keys: {0}/{1} Select  U Use  R Refresh All  Q Quit' -f $upArrow, $downArrow)))
    $lines.Add((New-CodecuxDashboardBorder -Width $width -Kind 'bottom'))
    $lines -join [Environment]::NewLine
}
