param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$cliModulePath = Join-Path $PSScriptRoot '..\src\Codecux.Cli.psm1'
Import-Module $cliModulePath -Force
Invoke-CodecuxCli -Arguments $Arguments -EntryScriptPath $PSCommandPath
