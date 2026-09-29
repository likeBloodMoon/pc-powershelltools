function Get-PCEventSummary {
    <#
    .SYNOPSIS
        Summarises what has been going wrong, grouped rather than listed.

    .DESCRIPTION
        Event Viewer answers "what happened at 14:32". The more useful question
        for a machine that is misbehaving is "what keeps happening", and that
        one it answers badly: thousands of rows, no grouping, no ranking.

        This reads the error and critical entries from the last N days and
        groups them by source and event ID, so a machine with an intermittent
        fault shows it as one row with a count of 340 rather than 340 rows.

        Bugchecks (event 1001 from BugCheck, and 41 from Kernel-Power - the
        unexpected-shutdown one) are pulled out separately, because a machine
        that has blue-screened is a different conversation from one with a noisy
        driver.

    .PARAMETER Days
        How far back to look.

    .PARAMETER LogName
        Which logs to read. Defaults to System and Application.

    .PARAMETER Top
        How many grouped rows to return.

    .EXAMPLE
        Get-PCEventSummary -Days 14

    .EXAMPLE
        (Get-PCEventSummary).Crashes

    .OUTPUTS
        PCTools.EventSummary
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 365)]
        [int]$Days = 7,

        [string[]]$LogName = @('System', 'Application'),

        [ValidateRange(1, 100)]
        [int]$Top = 15
    )

    $since = (Get-Date).AddDays(-$Days)
    Write-PCLog -Level INFO -Message "Reading events since $since"

    $events = @()
    foreach ($log in $LogName) {
        try {
            # Level 1 is Critical, 2 is Error. Filtering in the XPath query
            # rather than with Where-Object matters here: the unfiltered System
            # log on a busy machine is hundreds of thousands of records, and
            # pulling them all into PowerShell to discard 98% of them is the
            # difference between one second and forty.
            $events += @(Get-WinEvent -FilterHashtable @{
                LogName   = $log
                Level     = 1, 2
                StartTime = $since
            } -ErrorAction Stop)
        }
        catch {
            # "No events were found" is a legitimate answer, not a failure.
            if ($_.Exception.Message -notmatch 'No events were found') {
                Write-PCLog -Level DEBUG -Message "Could not read ${log}: $($_.Exception.Message)"
            }
        }
    }

    $grouped = @($events |
        Group-Object -Property @{ Expression = { '{0}|{1}' -f $_.ProviderName, $_.Id } } |
        Sort-Object Count -Descending |
        Select-Object -First $Top |
        ForEach-Object {
            $sample = $_.Group[0]
            [pscustomobject]@{
                PSTypeName = 'PCTools.EventGroup'
                Provider   = $sample.ProviderName
                EventId    = $sample.Id
                Level      = $sample.LevelDisplayName
                Count      = $_.Count
                FirstSeen  = ($_.Group | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated
                LastSeen   = ($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
                Message    = ($sample.Message -split "`r?`n" | Where-Object { $_ }) | Select-Object -First 1
            }
        })

    $crashes = @($events |
        Where-Object {
            ($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41) -or
            ($_.ProviderName -eq 'BugCheck') -or
            ($_.ProviderName -eq 'Microsoft-Windows-WER-SystemErrorReporting')
        } |
        Sort-Object TimeCreated -Descending |
        Select-Object -First 10 |
        ForEach-Object {
            [pscustomobject]@{
                PSTypeName = 'PCTools.CrashEvent'
                Time       = $_.TimeCreated
                Provider   = $_.ProviderName
                EventId    = $_.Id
                Message    = ($_.Message -split "`r?`n" | Where-Object { $_ }) | Select-Object -First 1
            }
        })

    $diskErrors = @($events | Where-Object { $_.ProviderName -in 'disk', 'Ntfs', 'volmgr' }).Count

    $verdict = if ($crashes.Count -gt 0) {
        'This machine has crashed or lost power unexpectedly {0} time(s) in the last {1} day(s).' -f $crashes.Count, $Days
    }
    elseif ($diskErrors -gt 0) {
        '{0} disk or filesystem error(s) in the last {1} day(s). Run Get-PCDiskHealth and Test-PCDisk.' -f $diskErrors, $Days
    }
    elseif ($events.Count -eq 0) {
        'No errors or critical events in the last {0} day(s).' -f $Days
    }
    else {
        '{0} error/critical event(s) in the last {1} day(s), none of them crashes.' -f $events.Count, $Days
    }

    [pscustomobject]@{
        PSTypeName = 'PCTools.EventSummary'
        Since      = $since
        Days       = $Days
        Total      = $events.Count
        Crashes    = $crashes
        DiskErrors = $diskErrors
        Groups     = $grouped
        Verdict    = $verdict
    }
}
