function Clear-PCEventLog {
    <#
    .SYNOPSIS
        Clears Windows event logs.

    .DESCRIPTION
        Event logs are capped and roll over on their own, so this is not a space
        win worth chasing - a few hundred megabytes at most. It earns its place
        for the other reason: clearing the logs before reproducing a fault means
        Get-PCEventSummary afterwards shows only what the fault produced,
        instead of six months of history to read past.

        Which is also why this is not in any maintenance profile, and why the
        default is to clear only the noisy application logs rather than the
        security log, whose contents are an audit record somebody may be
        required to keep.

    .PARAMETER LogName
        Specific logs to clear. Defaults to Application, System and Setup.

    .PARAMETER IncludeSecurity
        Also clear the Security log. Off by default: that log is an audit trail
        and clearing it is itself an audited event.

    .PARAMETER All
        Clear every log with records in it. Verbose, slow, and rarely what you
        want.

    .EXAMPLE
        Clear-PCEventLog -WhatIf

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [string[]]$LogName = @('Application', 'System', 'Setup'),

        [switch]$IncludeSecurity,

        [switch]$All
    )

    Invoke-PCAction -Name 'Clear-PCEventLog' -Body {
        Assert-PCAdmin -Action 'Clearing event logs'

        $targets = @($LogName)

        if ($IncludeSecurity -and $targets -notcontains 'Security') { $targets += 'Security' }

        if ($All) {
            try {
                $targets = @(Get-WinEvent -ListLog * -ErrorAction Stop |
                    Where-Object { $_.RecordCount -gt 0 } |
                    ForEach-Object LogName)
            }
            catch {
                Write-PCLog -Level WARN -Message "Could not enumerate event logs: $($_.Exception.Message)"
            }
        }

        $cleared = @()
        $failed = @()
        $records = 0

        foreach ($name in $targets) {
            $count = 0
            try {
                $log = Get-WinEvent -ListLog $name -ErrorAction Stop
                $count = [int]$log.RecordCount
            }
            catch {
                $failed += "$name (not found)"
                continue
            }

            if ($count -eq 0) { continue }
            if (-not $PSCmdlet.ShouldProcess($name, "Clear $count record(s)")) { continue }

            # wevtutil is the only reliable way to clear a modern channel;
            # Clear-EventLog handles classic logs only.
            $run = Invoke-PCProcess -FilePath 'wevtutil.exe' -ArgumentList @('cl', $name) -TimeoutSeconds 60

            if ($run.ExitCode -eq 0 -and -not $run.TimedOut) {
                $cleared += $name
                $records += $count
            }
            else {
                $failed += "$name (exit $($run.ExitCode))"
            }
        }

        $parts = @()
        if ($cleared.Count) { $parts += '{0} log(s) cleared, {1} record(s)' -f $cleared.Count, $records }
        if ($failed.Count) { $parts += '{0} failed: {1}' -f $failed.Count, ($failed -join ', ') }

        @{
            Status = if ($failed.Count -eq 0 -and $cleared.Count -gt 0) { 'Success' }
                     elseif ($cleared.Count -gt 0) { 'Warning' }
                     elseif ($failed.Count -gt 0) { 'Failed' }
                     else { 'Skipped' }
            Detail = if ($parts.Count) { $parts -join '; ' } else { 'No logs had records to clear.' }
            Data   = @{ Cleared = $cleared; Failed = $failed; Records = $records }
        }
    }
}
