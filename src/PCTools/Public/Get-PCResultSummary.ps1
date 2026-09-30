function Get-PCResultSummary {
    <#
    .SYNOPSIS
        Reduces a set of action results to the one line a person actually reads.

    .DESCRIPTION
        "Freed 4.2 GB - 6 actions ok - 1 warning - restart required" is the
        answer to "what just happened". Every host wants it and none of them
        should compute it themselves: the GUI's summary bar, the CLI's closing
        line and the HTML report all call this, so they cannot disagree.

    .PARAMETER Result
        The PCTools.ActionResult objects to summarise. Anything else in the
        pipeline is ignored, so a mixed batch of results and reports can be
        piped straight in.

    .EXAMPLE
        Invoke-PCMaintenance -ProfileName Quick | Get-PCResultSummary

    .EXAMPLE
        (Get-PCResultSummary -Result $results).Text
        6 action(s)  -  5 ok  -  1 warning  -  4.2 GB reclaimed

    .OUTPUTS
        PCTools.ResultSummary
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyCollection()]
        [object[]]$Result
    )

    begin {
        $collected = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $Result) {
            if ($null -eq $item) { continue }
            if ($item.PSObject.TypeNames -contains 'PCTools.ActionResult') { $collected.Add($item) }
        }
    }

    end {
        $all = @($collected)

        $succeeded = @($all | Where-Object Status -eq 'Success').Count
        $warned    = @($all | Where-Object Status -eq 'Warning').Count
        $failed    = @($all | Where-Object Status -eq 'Failed').Count
        $skipped   = @($all | Where-Object Status -eq 'Skipped').Count
        # Measure-Object emits nothing at all for an empty collection, so under
        # Set-StrictMode -Version Latest reading .Sum off it is a terminating
        # error rather than $null. An empty batch is a normal case here - a
        # network-only report has no action results - so it is guarded, not
        # assumed away.
        $freed = 0L
        if ($all.Count -gt 0) {
            $measured = $all | Measure-Object -Property BytesFreed -Sum
            if ($measured -and $null -ne $measured.Sum) { $freed = [long]$measured.Sum }
        }
        $reboot    = @($all | Where-Object RebootRequired).Count -gt 0

        $elapsed = [timespan]::Zero
        foreach ($item in $all) {
            if ($item.Duration -is [timespan]) { $elapsed += $item.Duration }
        }

        $parts = @()
        if ($all.Count -eq 0) {
            $parts += 'Nothing ran'
        }
        else {
            $parts += '{0} action(s)' -f $all.Count
            $parts += '{0} ok' -f $succeeded
            if ($warned)  { $parts += '{0} warning' -f $warned }
            if ($failed)  { $parts += '{0} failed' -f $failed }
            if ($skipped) { $parts += '{0} skipped' -f $skipped }
            if ($freed -gt 0) { $parts += '{0} reclaimed' -f (Format-PCByteSize -Bytes $freed) }
            if ($reboot) { $parts += 'restart required' }
        }

        [pscustomobject]@{
            PSTypeName     = 'PCTools.ResultSummary'
            Total          = $all.Count
            Succeeded      = $succeeded
            Warnings       = $warned
            Failed         = $failed
            Skipped        = $skipped
            BytesFreed     = [long]$freed
            FreedDisplay   = Format-PCByteSize -Bytes $freed
            RebootRequired = $reboot
            Duration       = $elapsed
            Text           = $parts -join '  -  '
        }
    }
}
