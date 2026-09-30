function Start-PCTools {
    <#
    .SYNOPSIS
        Opens the PC Tools window.

    .DESCRIPTION
        The GUI ships inside the module, so this works from a PowerShell Gallery
        install with nothing else downloaded:

            Install-Module PCTools -Scope CurrentUser
            Start-PCTools

        WinForms needs a single-threaded apartment. The shell relaunches itself
        under one when the host does not provide it, which is what makes this
        callable from pwsh.exe as well as powershell.exe.

    .PARAMETER Theme
        Dark or Light. Defaults to Dark.

    .PARAMETER Page
        The page to open on. Defaults to the dashboard.

    .PARAMETER Elevate
        Relaunch elevated. Repair, network and system-cache actions need
        administrator rights; the window runs happily without them and tells you
        which actions are unavailable.

    .EXAMPLE
        Start-PCTools

    .EXAMPLE
        Start-PCTools -Theme Light -Page Network

    .EXAMPLE
        pctools

        The alias, for when the window is all you want.
    #>
    [CmdletBinding()]
    [Alias('pctools')]
    [OutputType([void])]
    param(
        [ValidateSet('Dark', 'Light')]
        [string]$Theme = 'Dark',

        [ValidateSet('Dashboard', 'Maintenance', 'Storage', 'Health', 'Network', 'Software', 'Preferences', 'Log')]
        [string]$Page = 'Dashboard',

        [switch]$Elevate
    )

    # Resolved from the module's own base, never by walking up from
    # $PSScriptRoot. The two layouts do not agree: in the source tree this
    # function lives in Public/ and the shell is one level up, but the shipped
    # module is compiled into a single PCTools.psm1 at the module root, where
    # '..\Shell' points at a sibling of the module folder that does not exist.
    # That version of this line meant Start-PCTools threw "shell is missing" on
    # every Gallery and archive install - which is to say, on every install.
    $moduleBase = $ExecutionContext.SessionState.Module.ModuleBase
    if (-not $moduleBase) { $moduleBase = Split-Path -Parent $PSScriptRoot }

    $shellPath = [System.IO.Path]::GetFullPath((Join-Path $moduleBase 'Shell\Start-PCToolsShell.ps1'))

    if (-not (Test-Path -LiteralPath $shellPath)) {
        throw "The PC Tools shell is missing from the module. Expected it at: $shellPath"
    }

    if (-not $script:IsWindowsPlatform) {
        throw 'The PC Tools window needs Windows and WinForms. The commands themselves run anywhere the actions make sense; see Get-Command -Module PCTools.'
    }

    if ($Elevate -and -not (Test-PCAdmin)) {
        Write-PCLog -Level INFO -Message 'Relaunching PC Tools elevated.'

        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
            '-File', ('"{0}"' -f $shellPath),
            '-Theme', $Theme, '-Page', $Page
        )

        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -ErrorAction Stop
        }
        catch {
            # A declined UAC prompt is a choice, not a failure worth a stack trace.
            Write-Warning "Elevation was declined or failed: $($_.Exception.Message)"
        }
        return
    }

    # Run in a child scope. The shell defines several dozen UI helpers and holds
    # the form for the lifetime of the window; dot-sourcing it would leave all
    # of that behind in the module scope after the window closed.
    & $shellPath -Theme $Theme -Page $Page
}
