function Get-PCHealthReport {
    <#
    .SYNOPSIS
        One graded answer to "how is this machine doing".

    .DESCRIPTION
        Runs the read-only health checks and reduces them to a score out of 100
        with the reasons attached. Nothing here changes anything, so it is safe
        to run on any machine at any time - it is the command the GUI dashboard
        opens with.

        The score is a summary, not a measurement: its job is to rank findings
        so the worst problem is the one at the top. The findings themselves are
        what to act on, and each one names the command that addresses it.

        Sections run concurrently where they are independent, since most of them
        are waiting on WMI rather than computing.

    .PARAMETER Days
        How far back the event history looks.

    .PARAMETER SkipDiskUsage
        Leave out the disk usage scan, which is the only slow section on a large
        drive.

    .EXAMPLE
        Get-PCHealthReport | Format-List Score, Grade, Findings

    .EXAMPLE
        (Get-PCHealthReport).Findings | Format-Table Severity, Area, Message, Command

    .OUTPUTS
        PCTools.HealthReport
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 90)]
        [int]$Days = 7,

        [switch]$SkipDiskUsage
    )

    Write-PCLog -Level INFO -Message 'Building health report'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $findings = [System.Collections.Generic.List[object]]::new()
    $addFinding = {
        param([string]$Severity, [string]$Area, [string]$Message, [string]$Command)
        $findings.Add([pscustomobject]@{
            PSTypeName = 'PCTools.HealthFinding'
            Severity   = $Severity
            Area       = $Area
            Message    = $Message
            Command    = $Command
        })
    }

    # Each section is wrapped so one unavailable subsystem - no BitLocker on
    # Home, no battery on a desktop, no reliability counters behind USB - cannot
    # take the whole report down with it.
    $safely = {
        param([string]$Area, [scriptblock]$Work)
        try { & $Work }
        catch {
            Write-PCLog -Level DEBUG -Message "Health section '$Area' failed: $($_.Exception.Message)"
            $null
        }
    }

    $system   = & $safely 'System'   { Get-PCSystemInfo }
    $disks    = & $safely 'Disk'     { @(Get-PCDiskSpace) }
    $health   = & $safely 'Disk'     { @(Get-PCDiskHealth) }
    $security = & $safely 'Security' { Get-PCSecurityStatus }
    $events   = & $safely 'Events'   { Get-PCEventSummary -Days $Days }
    $boot     = & $safely 'Boot'     { Get-PCBootPerformance }
    $battery  = & $safely 'Battery'  { @(Get-PCBatteryReport) }
    $startup  = & $safely 'Startup'  { @(Get-PCStartupItem -Source Registry, Folder | Where-Object Enabled) }

    $score = 100

    foreach ($disk in @($disks)) {
        switch ($disk.Pressure) {
            'Critical' {
                $score -= 25
                & $addFinding 'Critical' 'Disk' ("{0} has only {1} free ({2}%)." -f $disk.Drive, $disk.FreeDisplay, $disk.PercentFree) 'Invoke-PCMaintenance -ProfileName Storage'
            }
            'Low' {
                $score -= 12
                & $addFinding 'Warning' 'Disk' ("{0} is low on space: {1} free ({2}%)." -f $disk.Drive, $disk.FreeDisplay, $disk.PercentFree) 'Get-PCDiskUsage'
            }
            'Tight' {
                $score -= 4
                & $addFinding 'Info' 'Disk' ("{0} has {1} free ({2}%)." -f $disk.Drive, $disk.FreeDisplay, $disk.PercentFree) 'Invoke-PCMaintenance -ProfileName Quick'
            }
        }
    }

    foreach ($disk in @($health)) {
        if ($disk.Health -eq 'Attention') {
            $score -= 30
            & $addFinding 'Critical' 'Disk' ("{0}: {1}" -f $disk.FriendlyName, ($disk.Concerns -join '; ')) 'Get-PCDiskHealth'
        }
    }

    if ($security) {
        foreach ($item in @($security.Findings)) {
            # A pending restart is worth flagging but is not a security failure.
            if ($item -match 'restart is pending') {
                $score -= 3
                & $addFinding 'Info' 'Updates' $item 'Restart-Computer'
            }
            else {
                $score -= 8
                & $addFinding 'Warning' 'Security' $item 'Get-PCSecurityStatus'
            }
        }
    }

    if ($events) {
        if (@($events.Crashes).Count -gt 0) {
            $score -= 20
            & $addFinding 'Critical' 'Stability' $events.Verdict 'Get-PCEventSummary'
        }
        elseif ($events.DiskErrors -gt 0) {
            $score -= 15
            & $addFinding 'Warning' 'Stability' $events.Verdict 'Test-PCDisk'
        }
    }

    if ($boot -and $boot.Available -and $boot.AverageMs) {
        if ($boot.AverageMs -gt 90000) {
            $score -= 10
            & $addFinding 'Warning' 'Boot' $boot.Verdict 'Get-PCBootPerformance'
        }
        elseif ($boot.AverageMs -gt 45000) {
            $score -= 5
            & $addFinding 'Info' 'Boot' $boot.Verdict 'Get-PCStartupItem'
        }
    }

    foreach ($cell in @($battery)) {
        if ($null -ne $cell.HealthPercent -and $cell.HealthPercent -lt 60) {
            $score -= 8
            & $addFinding 'Warning' 'Battery' $cell.Verdict 'Get-PCBatteryReport'
        }
        elseif ($null -ne $cell.HealthPercent -and $cell.HealthPercent -lt 80) {
            $score -= 3
            & $addFinding 'Info' 'Battery' $cell.Verdict 'Get-PCBatteryReport'
        }
    }

    $startupCount = @($startup).Count
    if ($startupCount -gt 15) {
        $score -= 5
        & $addFinding 'Info' 'Startup' "$startupCount programs start with Windows." 'Get-PCStartupItem'
    }

    $usage = $null
    if (-not $SkipDiskUsage) {
        $usage = & $safely 'Usage' { Get-PCDiskUsage -Top 10 }
    }

    if ($score -lt 0) { $score = 0 }
    $stopwatch.Stop()

    $grade = if ($score -ge 90) { 'Excellent' }
             elseif ($score -ge 75) { 'Good' }
             elseif ($score -ge 55) { 'Fair' }
             elseif ($score -ge 35) { 'Poor' }
             else { 'Critical' }

    $summary = if (@($findings).Count -eq 0) {
        'Nothing needs attention.'
    }
    else {
        $critical = @($findings | Where-Object Severity -eq 'Critical').Count
        $warning = @($findings | Where-Object Severity -eq 'Warning').Count
        $parts = @()
        if ($critical) { $parts += "$critical needing attention now" }
        if ($warning) { $parts += "$warning worth looking at" }
        if ($parts.Count -eq 0) { $parts += '{0} minor note(s)' -f @($findings).Count }
        $parts -join ', '
    }

    [pscustomobject]@{
        PSTypeName   = 'PCTools.HealthReport'
        ComputerName = $env:COMPUTERNAME
        Generated    = Get-Date
        Score        = $score
        Grade        = $grade
        Summary      = $summary
        Findings     = @($findings | Sort-Object @{ Expression = {
                            switch ($_.Severity) { 'Critical' { 0 } 'Warning' { 1 } default { 2 } }
                        } })
        System       = $system
        DiskSpace    = @($disks)
        DiskHealth   = @($health)
        Security     = $security
        Events       = $events
        Boot         = $boot
        Battery      = @($battery)
        StartupCount = $startupCount
        DiskUsage    = $usage
        Duration     = $stopwatch.Elapsed
    }
}
