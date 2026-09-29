function Get-PCHistory {
    <#
    .SYNOPSIS
        Reads past maintenance runs, and the trend across them.

    .DESCRIPTION
        Reads what Save-PCHistory recorded. With -Summary it reduces the runs to
        a trend instead of listing them: how much has been reclaimed in total,
        how much a typical run reclaims, and whether anything has been failing.

        A corrupt or partly written entry is skipped rather than throwing. The
        history is a convenience and one bad file should not cost the rest of
        it.

    .PARAMETER Last
        How many runs to return, newest first.

    .PARAMETER ProfileName
        Only runs of this profile.

    .PARAMETER Since
        Only runs after this time.

    .PARAMETER Summary
        Return the trend rather than the individual runs.

    .EXAMPLE
        Get-PCHistory -Last 10 | Format-Table Timestamp, ProfileName, Succeeded, Failed, BytesFreed

    .EXAMPLE
        Get-PCHistory -Summary

    .OUTPUTS
        PCTools.HistoryEntry, or PCTools.HistorySummary with -Summary.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 1000)]
        [int]$Last = 25,

        [string]$ProfileName,

        [datetime]$Since,

        [switch]$Summary
    )

    $entries = [System.Collections.Generic.List[object]]::new()

    if (Test-Path -LiteralPath $script:PCHistoryDirectory) {
        $files = Get-ChildItem -LiteralPath $script:PCHistoryDirectory -Filter 'run-*.json' -File |
            Sort-Object Name -Descending

        foreach ($file in $files) {
            if (-not $Summary -and $entries.Count -ge $Last) { break }

            try {
                $entry = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            }
            catch {
                Write-PCLog -Level DEBUG -Message "Skipping unreadable history entry $($file.Name): $($_.Exception.Message)"
                continue
            }

            if ($ProfileName -and $entry.ProfileName -ne $ProfileName) { continue }
            if ($PSBoundParameters.ContainsKey('Since') -and [datetime]$entry.Timestamp -lt $Since) { continue }

            $entries.Add($entry)
        }
    }

    if (-not $Summary) {
        return @($entries | Select-Object -First $Last)
    }

    $all = @($entries)

    if ($all.Count -eq 0) {
        return [pscustomobject]@{
            PSTypeName    = 'PCTools.HistorySummary'
            Runs          = 0
            FirstRun      = $null
            LastRun       = $null
            TotalFreed    = 0L
            TotalDisplay  = Format-PCByteSize -Bytes 0
            AverageFreed  = 0L
            AverageDisplay = Format-PCByteSize -Bytes 0
            FailedRuns    = 0
            Text          = 'No maintenance runs have been recorded yet.'
        }
    }

    $totalFreed = 0L
    foreach ($entry in $all) { $totalFreed += [long]$entry.BytesFreed }

    $average = [long]($totalFreed / $all.Count)
    $failedRuns = @($all | Where-Object { [int]$_.Failed -gt 0 }).Count

    $first = ($all | Sort-Object { [datetime]$_.Timestamp } | Select-Object -First 1)
    $lastRun = ($all | Sort-Object { [datetime]$_.Timestamp } -Descending | Select-Object -First 1)

    $text = '{0} run(s) recorded, {1} reclaimed in total, {2} on a typical run.' -f
        $all.Count, (Format-PCByteSize -Bytes $totalFreed), (Format-PCByteSize -Bytes $average)
    if ($failedRuns -gt 0) {
        $text += ' {0} run(s) had a failed action.' -f $failedRuns
    }

    [pscustomobject]@{
        PSTypeName     = 'PCTools.HistorySummary'
        Runs           = $all.Count
        FirstRun       = [datetime]$first.Timestamp
        LastRun        = [datetime]$lastRun.Timestamp
        TotalFreed     = $totalFreed
        TotalDisplay   = Format-PCByteSize -Bytes $totalFreed
        AverageFreed   = $average
        AverageDisplay = Format-PCByteSize -Bytes $average
        FailedRuns     = $failedRuns
        Text           = $text
    }
}
