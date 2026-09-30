function Register-PCScheduledMaintenance {
    <#
    .SYNOPSIS
        Schedules a maintenance profile to run on its own.

    .DESCRIPTION
        Maintenance that depends on somebody remembering to run it is
        maintenance that stops happening. This registers a Windows scheduled
        task that calls Invoke-PCTools with a profile, writes a JSON report and
        records the run in the history that Get-PCHistory reads.

        The task runs exactly the code an interactive run does. There is no
        separate unattended path to drift out of step, which also means -WhatIf
        here previews the real thing.

        Destructive profiles are refused. A scheduled task runs with nobody
        watching, and Full - which repairs the component store and can demand a
        restart - is not something to start unattended at 3am. Quick,
        Recommended, Health and Storage are allowed; anything else has to be
        run deliberately.

    .PARAMETER ProfileName
        The maintenance profile to run. Must be one of the profiles allowed for
        unattended use.

    .PARAMETER Frequency
        Daily, Weekly or Monthly.

    .PARAMETER At
        Time of day to run. Defaults to 03:00.

    .PARAMETER DayOfWeek
        For a weekly schedule. Defaults to Sunday.

    .PARAMETER TaskName
        The scheduled task name. Defaults to 'PCTools Maintenance'.

    .PARAMETER ReportPath
        Where reports are written. Defaults to %LOCALAPPDATA%\PCTools\reports.

    .PARAMETER RunWhenIdleOnly
        Only run when the machine is idle, and stop if it stops being idle.

    .EXAMPLE
        Register-PCScheduledMaintenance -ProfileName Quick -Frequency Weekly -WhatIf

    .EXAMPLE
        Register-PCScheduledMaintenance -ProfileName Recommended -Frequency Monthly -At 02:30

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string]$ProfileName = 'Quick',

        [ValidateSet('Daily', 'Weekly', 'Monthly')]
        [string]$Frequency = 'Weekly',

        [datetime]$At = ([datetime]'03:00'),

        [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
        [string]$DayOfWeek = 'Sunday',

        [string]$TaskName = 'PCTools Maintenance',

        [string]$ReportPath,

        [switch]$RunWhenIdleOnly
    )

    Invoke-PCAction -Name 'Register-PCScheduledMaintenance' -Body {
        Assert-PCAdmin -Action 'Registering a scheduled task'

        # Unattended means nobody is there to answer a prompt or to notice a
        # restart request, so the destructive profiles are not on offer.
        $allowed = @('Quick', 'Recommended', 'Health', 'Storage')
        if ($allowed -notcontains $ProfileName) {
            return @{
                Status = 'Failed'
                Detail = ("'{0}' is not allowed on a schedule. Unattended runs are limited to: {1}. " +
                          "Profiles that repair the component store or reset the network need somebody present.") -f
                         $ProfileName, ($allowed -join ', ')
            }
        }

        # Fail here rather than at 3am on a Sunday.
        $null = Get-PCMaintenanceProfile -Name $ProfileName

        if (-not $ReportPath) { $ReportPath = Join-Path $script:PCDataRoot 'reports' }

        # From the module's own base, not by walking up from $PSScriptRoot: in
        # the compiled module that this function ships in, $PSScriptRoot is
        # already the module root, so two parents pointed outside the versioned
        # module folder entirely. The task then fell back to Import-Module by
        # name and failed, because it runs as SYSTEM and a CurrentUser install
        # is not on SYSTEM's module path.
        $moduleBase = $ExecutionContext.SessionState.Module.ModuleBase
        if (-not $moduleBase) { $moduleBase = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

        $manifest = Join-Path $moduleBase 'PCTools.psd1'

        # Import by path rather than by name: the task runs as SYSTEM or as a
        # service account whose module path may not include a per-user install.
        $importExpression = if (Test-Path -LiteralPath $manifest) {
            "Import-Module '$manifest'"
        }
        else {
            'Import-Module PCTools'
        }

        $command = "$importExpression; Invoke-PCTools -ProfileName '$ProfileName' -Report Json -ReportPath '$ReportPath' -Quiet -Exit"

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$command`""

        $trigger = switch ($Frequency) {
            'Daily'   { New-ScheduledTaskTrigger -Daily -At $At }
            'Weekly'  { New-ScheduledTaskTrigger -Weekly -At $At -DaysOfWeek $DayOfWeek }
            'Monthly' {
                # New-ScheduledTaskTrigger has no monthly option, so a weekly
                # trigger is built and its interval widened through the CIM
                # object it produces.
                $weekly = New-ScheduledTaskTrigger -Weekly -At $At -DaysOfWeek $DayOfWeek -WeeksInterval 4
                $weekly
            }
        }

        $settingsParams = @{
            StartWhenAvailable        = $true
            DontStopOnIdleEnd         = $true
            ExecutionTimeLimit        = ([timespan]::FromHours(3))
            MultipleInstances         = 'IgnoreNew'
            AllowStartIfOnBatteries   = $false
            DontStopIfGoingOnBatteries = $false
        }
        if ($RunWhenIdleOnly) {
            $settingsParams['RunOnlyIfIdle'] = $true
            $settingsParams['IdleDuration'] = ([timespan]::FromMinutes(10))
            $settingsParams['IdleWaitTimeout'] = ([timespan]::FromHours(2))
        }

        $settings = New-ScheduledTaskSettingsSet @settingsParams

        # SYSTEM so the repair and cache actions have the rights they need
        # without storing anybody's password.
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

        $description = "PC Tools '$ProfileName' maintenance, $($Frequency.ToLower()) at $($At.ToString('HH:mm'))."

        if (-not $PSCmdlet.ShouldProcess($TaskName, "Register a $Frequency scheduled task running the $ProfileName profile")) {
            return @{
                Status = 'Skipped'
                Detail = "Would register '$TaskName': $description"
                Data   = @{ Command = $command }
            }
        }

        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Description $description -Force | Out-Null

        $next = $null
        try { $next = (Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop).NextRunTime } catch { }

        @{
            Detail = "'$TaskName' registered: $description$(if ($next) { " Next run $next." })"
            Data   = @{
                TaskName    = $TaskName
                ProfileName = $ProfileName
                Frequency   = $Frequency
                NextRunTime = $next
                ReportPath  = $ReportPath
                Replaced    = [bool]$existing
            }
        }
    }
}
