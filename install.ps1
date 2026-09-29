#requires -Version 5.1
<#
.SYNOPSIS
    Installs PC Tools and opens it.

.DESCRIPTION
    The one-command install:

        irm https://raw.githubusercontent.com/likeBloodMoon/pc-powershelltools/v0.5.0/install.ps1 | iex

    Note the tag in that URL. It is not 'main' on purpose: pinning to a tag
    means the code you run is a specific reviewed release rather than whatever
    was pushed most recently.

    What this actually does, in order:

      1. Checks that this is Windows on PowerShell 5.1 or later.
      2. Installs PCTools from the PowerShell Gallery, which is the good path -
         the package is signed, PowerShellGet verifies it, and Update-Module
         works afterwards.
      3. If the Gallery is unreachable or PowerShellGet is missing, downloads
         the release archive from GitHub AND its SHA256SUMS, verifies the hash,
         and refuses to go any further if it does not match. That verification
         is not optional and there is no switch to skip it.
      4. Installs a `pctools` command into %LOCALAPPDATA%\Microsoft\WindowsApps,
         which is already on PATH on Windows 10 and 11, so no PATH edit and no
         elevation are needed.
      5. Opens the window.

    The honest limitation: step 1 runs code fetched over TLS from a pinned URL,
    which you are trusting on the strength of that TLS connection. Everything
    after it is signature- or hash-verified. If you would rather verify the
    first step too, the README documents the fully manual path - download,
    check the hash yourself, then run.

.PARAMETER Version
    The release to install, e.g. '0.5.0'. Defaults to the newest published.

.PARAMETER Scope
    CurrentUser (default) or AllUsers. AllUsers needs an elevated session.

.PARAMETER NoLaunch
    Install without opening the window.

.PARAMETER CliOnly
    Skip the `pctools` shim; install the module only.

.PARAMETER Force
    Reinstall even when the requested version is already present.

.EXAMPLE
    irm https://raw.githubusercontent.com/likeBloodMoon/pc-powershelltools/v0.5.0/install.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/likeBloodMoon/pc-powershelltools/v0.5.0/install.ps1))) -NoLaunch

    Passing arguments through a piped-to-iex script needs this form; `iex`
    itself has nowhere to put them.

.LINK
    https://github.com/likeBloodMoon/pc-powershelltools
#>
[CmdletBinding()]
param(
    [string]$Version,

    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'CurrentUser',

    [switch]$NoLaunch,

    [switch]$CliOnly,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$script:Repository = 'likeBloodMoon/pc-powershelltools'
$script:ModuleName = 'PCTools'

function Write-Step {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Cyan
}

function Write-Done {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Green
}

function Test-Windows {
    # $IsWindows only exists on PowerShell 6+. On 5.1 the host is Windows.
    if ($null -eq (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) { return $true }
    return $IsWindows
}

function Install-FromGallery {
    <#
        The preferred path. Returns $true when the module is installed and
        importable, $false when the Gallery could not be used at all - a
        missing PowerShellGet, no network, a blocked feed. A genuine install
        failure is not swallowed: it throws.
    #>
    param([string]$RequestedVersion, [string]$InstallScope, [switch]$Reinstall)

    if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
        Write-Step 'PowerShellGet is not available; using the release archive instead.'
        return $false
    }

    try {
        # TLS 1.2 is not the default on Windows PowerShell 5.1 and the Gallery
        # has required it for years. Without this the call fails with an
        # unhelpful "underlying connection was closed".
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    catch { }

    $findParams = @{ Name = $script:ModuleName; ErrorAction = 'Stop' }
    if ($RequestedVersion) { $findParams['RequiredVersion'] = $RequestedVersion }

    try {
        $available = Find-Module @findParams
    }
    catch {
        Write-Step "The PowerShell Gallery is not reachable ($($_.Exception.Message.Trim()))."
        return $false
    }

    $installed = Get-Module -ListAvailable -Name $script:ModuleName |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($installed -and $installed.Version -ge $available.Version -and -not $Reinstall) {
        Write-Done "$($script:ModuleName) $($installed.Version) is already installed."
        return $true
    }

    Write-Step "Installing $($script:ModuleName) $($available.Version) from the PowerShell Gallery..."

    $installParams = @{
        Name          = $script:ModuleName
        Scope         = $InstallScope
        Force         = $true
        AllowClobber  = $true
        ErrorAction   = 'Stop'
    }
    if ($RequestedVersion) { $installParams['RequiredVersion'] = $RequestedVersion }

    Install-Module @installParams
    Write-Done "Installed $($script:ModuleName) $($available.Version)."
    return $true
}

function Install-FromRelease {
    <#
        The fallback. Downloads the release archive and SHA256SUMS from the
        GitHub release, verifies the archive against the published hash, and
        only then extracts it. A mismatch is fatal - that is the entire point
        of this function.
    #>
    param([string]$RequestedVersion)

    $tag = if ($RequestedVersion) { "v$($RequestedVersion.TrimStart('v'))" } else { 'latest' }
    $base = if ($tag -eq 'latest') {
        "https://github.com/$script:Repository/releases/latest/download"
    }
    else {
        "https://github.com/$script:Repository/releases/download/$tag"
    }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("pctools-install-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    try {
        Write-Step "Downloading the release archive from $base ..."

        $sumsPath = Join-Path $work 'SHA256SUMS'
        Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile $sumsPath -UseBasicParsing -ErrorAction Stop

        # The archive name carries the version, which for 'latest' we do not
        # know until we read the checksum list.
        $line = Get-Content -LiteralPath $sumsPath |
            Where-Object { $_ -match '\s(PCTools-[\d\.]+\.zip)\s*$' } |
            Select-Object -First 1

        if (-not $line) {
            throw "SHA256SUMS does not list a PCTools module archive. Nothing here can be verified, so nothing will be installed."
        }

        $expected = ($line -split '\s+')[0].ToLowerInvariant()
        $archiveName = ($line -split '\s+')[-1]

        $archivePath = Join-Path $work $archiveName
        Invoke-WebRequest -Uri "$base/$archiveName" -OutFile $archivePath -UseBasicParsing -ErrorAction Stop

        $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($actual -ne $expected) {
            throw @"
Checksum mismatch. Nothing was installed.

  file     : $archiveName
  expected : $expected
  actual   : $actual

Do not run this download. Report it at https://github.com/$script:Repository/issues
"@
        }

        Write-Done "Verified $archiveName against the published SHA256."

        $moduleRoot = if ($Scope -eq 'AllUsers') {
            Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'
        }
        else {
            Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
        }

        $extract = Join-Path $work 'extract'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extract -Force

        # The archive holds a PCTools folder; find the manifest rather than
        # assuming a layout that a future release might change.
        $manifest = Get-ChildItem -Path $extract -Recurse -Filter 'PCTools.psd1' -File |
            Select-Object -First 1
        if (-not $manifest) { throw 'The archive does not contain PCTools.psd1.' }

        $version = (Import-PowerShellDataFile -Path $manifest.FullName).ModuleVersion
        $destination = Join-Path (Join-Path $moduleRoot $script:ModuleName) $version

        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Recurse -Force
        }
        New-Item -ItemType Directory -Path $destination -Force | Out-Null

        Copy-Item -Path (Join-Path $manifest.DirectoryName '*') -Destination $destination -Recurse -Force

        Write-Done "Installed $script:ModuleName $version to $destination."
        return $true
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-Shim {
    <#
        %LOCALAPPDATA%\Microsoft\WindowsApps is on PATH by default on Windows 10
        and 11 for the current user. Dropping a .cmd there gives `pctools` in
        any new terminal without touching PATH and without elevation.
    #>
    $shimDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'

    if (-not (Test-Path -LiteralPath $shimDir)) {
        # Not a Windows 10/11 layout. Fall back to the module's own folder and
        # say so, rather than silently editing PATH.
        $shimDir = Join-Path $env:LOCALAPPDATA 'PCTools\bin'
        New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
        Write-Step "Installed the shim to $shimDir - add it to PATH to use 'pctools' directly."
    }

    $shimPath = Join-Path $shimDir 'pctools.cmd'

    # -STA because the GUI is WinForms. %* forwards every argument to
    # Invoke-PCTools, and -Exit makes the process exit code the run's result.
    $shim = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -Command "Import-Module PCTools -ErrorAction Stop; Invoke-PCTools -Exit %*"
'@

    Set-Content -LiteralPath $shimPath -Value $shim -Encoding ASCII
    Write-Done "The 'pctools' command is available in a new terminal."
}

Write-Host ''
Write-Host '  PC Tools installer' -ForegroundColor White
Write-Host '  https://github.com/likeBloodMoon/pc-powershelltools'
Write-Host ''

if (-not (Test-Windows)) {
    throw 'PC Tools maintains Windows. This installer only runs on Windows.'
}

if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    throw "PowerShell 5.1 or later is required; this session is $($PSVersionTable.PSVersion)."
}

if ($Scope -eq 'AllUsers') {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '-Scope AllUsers needs an elevated session. Re-run as Administrator, or use the default -Scope CurrentUser.'
    }
}

$installed = Install-FromGallery -RequestedVersion $Version -InstallScope $Scope -Reinstall:$Force

if (-not $installed) {
    $installed = Install-FromRelease -RequestedVersion $Version
}

if (-not $installed) {
    throw 'PC Tools could not be installed from either the PowerShell Gallery or a GitHub release.'
}

Import-Module $script:ModuleName -Force -ErrorAction Stop
$module = Get-Module $script:ModuleName

if (-not $CliOnly) {
    Install-Shim
}

Write-Host ''
Write-Host "  PC Tools $($module.Version) is installed." -ForegroundColor Green
Write-Host ''
Write-Host '    pctools                              open the window'
Write-Host '    pctools -ProfileName Quick           reclaim disk space and exit'
Write-Host '    pctools -Diagnose                    diagnose the network'
Write-Host '    Get-Command -Module PCTools          every command'
Write-Host '    Invoke-PCMaintenance -WhatIf         preview without changing anything'
Write-Host ''

if (-not $NoLaunch) {
    Start-PCTools
}
