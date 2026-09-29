#requires -Version 5.1
<#
.SYNOPSIS
    Launches PC Tools from a cloned repository or an extracted release archive.

.DESCRIPTION
    A thin launcher, kept so existing links and the release archive layout keep
    working. It imports the PCTools module sitting next to it and calls
    Start-PCTools.

    If PCTools is installed - Install-Module PCTools, or install.ps1 - you do
    not need this file at all:

        pctools
        Start-PCTools

.PARAMETER Theme
    Dark or Light. Defaults to Dark.

.PARAMETER Page
    The page to open on. Defaults to the dashboard.

.PARAMETER NoGui
    Import the PCTools module into the current session and exit, instead of
    opening the window. Use this to drive the actions from the console.

.EXAMPLE
    .\pc-tools.ps1

.EXAMPLE
    .\pc-tools.ps1 -NoGui
    Invoke-PCMaintenance -ProfileName Quick -WhatIf

.LINK
    https://github.com/likeBloodMoon/pc-powershelltools
#>
[CmdletBinding()]
param(
    [ValidateSet('Dark', 'Light')]
    [string]$Theme = 'Dark',

    [ValidateSet('Dashboard', 'Maintenance', 'Storage', 'Health', 'Network', 'Software', 'Preferences', 'Log')]
    [string]$Page = 'Dashboard',

    [switch]$NoGui
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

if (-not $root) {
    throw @'
PC Tools cannot locate its own folder.

This usually means the script was piped into iex from the network. Use the
installer instead - it handles that case, verifies what it downloads, and gives
you a `pctools` command:

    irm https://raw.githubusercontent.com/likeBloodMoon/pc-powershelltools/v0.5.0/install.ps1 | iex
'@
}

$modulePath = Join-Path $root 'src\PCTools\PCTools.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "The PCTools module is missing. Expected it at: $modulePath"
}

Import-Module $modulePath -Force

if ($NoGui) {
    Write-Host ''
    Write-Host "PCTools $((Get-Module PCTools).Version) loaded." -ForegroundColor Green
    Write-Host ''
    Write-Host '  Get-Command -Module PCTools          list every action'
    Write-Host '  Get-PCMaintenanceProfile             show the built-in profiles'
    Write-Host '  Invoke-PCMaintenance -WhatIf         preview without changing anything'
    Write-Host '  Get-PCHealthReport                   how is this machine doing'
    Write-Host '  Get-PCNetworkReport | Format-List    diagnose the network'
    Write-Host ''
    if (-not (Test-PCAdmin)) {
        Write-Warning 'This session is not elevated. Repair and network actions will fail.'
    }
    return
}

Start-PCTools -Theme $Theme -Page $Page
