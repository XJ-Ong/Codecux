Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-CodecuxProfileParent {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)

    $profileDir = Split-Path -Parent $ProfilePath
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    }
}

function Set-CodecuxProfileBlock {
    param(
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$BlockName,
        [Parameter(Mandatory = $true)][string]$Body
    )

    Ensure-CodecuxProfileParent -ProfilePath $ProfilePath

    $startMarker = '# >>> Codecux {0} >>>' -f $BlockName
    $endMarker = '# <<< Codecux {0} <<<' -f $BlockName
    $block = @($startMarker, $Body, $endMarker) -join [Environment]::NewLine

    if (-not (Test-Path $ProfilePath)) {
        Set-Content -Path $ProfilePath -Value $block -Encoding UTF8
        return
    }

    $profileContent = Get-Content -Raw $ProfilePath
    $pattern = '(?s){0}.*?{1}' -f [regex]::Escape($startMarker), [regex]::Escape($endMarker)
    if ($profileContent -match $pattern) {
        $replacement = $block.Replace('$', '$$')
        $profileContent = [regex]::Replace($profileContent, $pattern, $replacement)
        Set-Content -Path $ProfilePath -Value $profileContent -Encoding UTF8
        return
    }

    $prefix = if ($profileContent.Length -gt 0 -and -not $profileContent.EndsWith([Environment]::NewLine)) { [Environment]::NewLine } else { '' }
    Add-Content -Path $ProfilePath -Value ($prefix + $block) -Encoding UTF8
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$entryScript = Join-Path $repoRoot 'bin\cux.ps1'
$completionScript = Join-Path $repoRoot 'scripts\cux-completion.ps1'
$targetDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
$targetPath = Join-Path $targetDir 'cux.cmd'

if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
}

$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
$cmdLines = @(
    '@echo off',
    'setlocal',
    ('set "CODECUX_PS_EXE={0}"' -f $psExe),
    ('set "CODECUX_ENTRY={0}"' -f $entryScript),
    'if /I "%~1"=="dash" goto :dashboard_handoff',
    'if /I "%~1"=="dashboard" goto :dashboard_handoff',
    '"%CODECUX_PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CODECUX_ENTRY%" %*',
    'exit /b %ERRORLEVEL%',
    ':dashboard_handoff',
    '"%CODECUX_PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CODECUX_ENTRY%" %*',
    'set "CODE=%ERRORLEVEL%"',
    'echo(%CMDCMDLINE%| findstr /I /C:" /c " >nul',
    'if errorlevel 1 exit %CODE%',
    'exit /b %CODE%'
) -join [Environment]::NewLine
Set-Content -Path $targetPath -Value $cmdLines -Encoding ASCII

$storeRoot = Join-Path $HOME '.cux'
foreach ($dir in @($storeRoot, (Join-Path $storeRoot 'profiles'), (Join-Path $storeRoot 'backups'))) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

$completionBlock = ('. "{0}"' -f $completionScript)
$wrapperBlock = @(
    'function cux {',
    '    param(',
    '        [Parameter(ValueFromRemainingArguments = $true)]',
    '        [string[]]$Arguments',
    '    )',
    '',
    ('    $codecuxShim = ''{0}''' -f $targetPath),
    '    & $codecuxShim @Arguments',
    '    $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }',
    '',
    '    if ($Arguments.Count -gt 0) {',
    '        $command = $Arguments[0].ToLowerInvariant()',
    '        if ($exitCode -eq 0 -and $command -in @(''dash'', ''dashboard'')) {',
    '            exit $exitCode',
    '        }',
    '    }',
    '}'
) -join [Environment]::NewLine

$profilePath = Join-Path $HOME 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
Set-CodecuxProfileBlock -ProfilePath $profilePath -BlockName 'wrapper' -Body $wrapperBlock
Set-CodecuxProfileBlock -ProfilePath $profilePath -BlockName 'completion' -Body $completionBlock

$ps7ProfilePath = Join-Path $HOME 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
if ($ps7ProfilePath -ne $profilePath) {
    Set-CodecuxProfileBlock -ProfilePath $ps7ProfilePath -BlockName 'wrapper' -Body $wrapperBlock
    Set-CodecuxProfileBlock -ProfilePath $ps7ProfilePath -BlockName 'completion' -Body $completionBlock

    Write-Host ("PowerShell 7 completion profile: {0}" -f $ps7ProfilePath)
}

. $completionScript

Write-Host ("Installed cux.cmd to {0}" -f $targetPath)
Write-Host ("Codecux store root: {0}" -f $storeRoot)
Write-Host ("PowerShell completion profile: {0}" -f $profilePath)
