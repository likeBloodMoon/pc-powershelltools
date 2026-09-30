function Invoke-PCTools {
    <#
    .SYNOPSIS
        The command-line front door: run a profile, diagnose the network, or open
        the window.

    .DESCRIPTION
        One entry point that behaves sensibly however it is called. With no
        arguments it opens the GUI, which is what someone typing `pctools` in a
        terminal means. With a profile it runs that profile and returns, which is
        what a scheduled task or a CI step means.

        It adds no orchestration of its own - the work is Invoke-PCMaintenance
        and Get-PCNetworkReport, unchanged - only argument handling, output
        formatting and an exit code.

    .PARAMETER ProfileName
        The maintenance profile to run. See Get-PCMaintenanceProfile.

    .PARAMETER Action
        Explicit action names instead of a profile.

    .PARAMETER Diagnose
        Run a network diagnostic instead of maintenance and print the verdict.

    .PARAMETER Gui
        Open the window. This is the default when nothing else is asked for.

    .PARAMETER Json
        Emit the results as JSON on stdout instead of formatted text, so the
        output can be piped into anything that reads JSON.

    .PARAMETER Report
        Also write a report file. Html, Json, Text or Csv; see Export-PCReport.

    .PARAMETER ReportPath
        Where to write the report. Defaults to the desktop.

    .PARAMETER Quiet
        Suppress the human-readable summary. Results still go to the pipeline
        and the exit code is still set.

    .PARAMETER SkipRestorePoint
        Run without taking a restore point first.

    .PARAMETER Exit
        Terminate the host with the computed exit code when the run finishes.
        This is what the `pctools` shim passes; do not pass it interactively
        unless closing the session is what you want.

        Exit codes:
          0     every action succeeded
          1     at least one warning, nothing failed
          2     at least one action failed
          3010  everything succeeded but a restart is required

    .EXAMPLE
        Invoke-PCTools

        Opens the window.

    .EXAMPLE
        Invoke-PCTools -ProfileName Quick -Json

    .EXAMPLE
        Invoke-PCTools -ProfileName Recommended -Report Html -Quiet

    .EXAMPLE
        Invoke-PCTools -Diagnose

    .OUTPUTS
        PCTools.ActionResult, or PCTools.NetworkReport with -Diagnose.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Gui')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0, ParameterSetName = 'Profile')]
        [Alias('Profile')]
        [string]$ProfileName,

        [Parameter(Mandatory, ParameterSetName = 'Action')]
        [string[]]$Action,

        [Parameter(Mandatory, ParameterSetName = 'Diagnose')]
        [switch]$Diagnose,

        [Parameter(ParameterSetName = 'Diagnose')]
        [switch]$Full,

        [Parameter(ParameterSetName = 'Gui')]
        [switch]$Gui,

        [Parameter(ParameterSetName = 'Gui')]
        [ValidateSet('Dark', 'Light')]
        [string]$Theme = 'Dark',

        [Parameter(ParameterSetName = 'Profile')]
        [Parameter(ParameterSetName = 'Action')]
        [switch]$SkipRestorePoint,

        [switch]$Json,

        [ValidateSet('Html', 'Json', 'Text', 'Csv')]
        [string]$Report,

        [string]$ReportPath,

        [switch]$Quiet,

        [switch]$Exit
    )

    if ($PSCmdlet.ParameterSetName -eq 'Gui') {
        Start-PCTools -Theme $Theme
        return
    }

    $results = switch ($PSCmdlet.ParameterSetName) {
        'Diagnose' {
            $report = Get-PCNetworkReport -Full:$Full

            if (-not $Quiet -and -not $Json) {
                Write-Host ''
                Write-Host "  $($report.Verdict.Verdict)" -ForegroundColor $(
                    if ($report.Verdict.Healthy) { 'Green' } else { 'Yellow' })
                Write-Host "  $($report.Verdict.Advice)"
                Write-Host ''
                $report.Tests | Format-Table Layer, Target, Success, LatencyMs, Detail -AutoSize |
                    Out-String | Write-Host
            }

            $report
        }
        'Action' {
            Invoke-PCMaintenance -Action $Action -SkipRestorePoint:$SkipRestorePoint
        }
        default {
            $name = if ($ProfileName) { $ProfileName } else { 'Quick' }
            Invoke-PCMaintenance -ProfileName $name -SkipRestorePoint:$SkipRestorePoint
        }
    }

    $results = @($results)

    if ($Report) {
        $exportParams = @{ Format = $Report }
        if ($ReportPath) { $exportParams['Path'] = $ReportPath }
        $written = $results | Export-PCReport @exportParams

        if (-not $Quiet -and $written) {
            foreach ($path in $written.PSObject.Properties.Value) {
                if ($path) { Write-Host "Report: $path" }
            }
        }
    }

    $actionResults = @($results | Where-Object { $_.PSObject.TypeNames -contains 'PCTools.ActionResult' })

    if (-not $Quiet -and -not $Json -and $actionResults.Count -gt 0) {
        Write-Host ''
        $actionResults | Format-Table Action, Status, FreedDisplay, Detail -AutoSize |
            Out-String | Write-Host
        Write-Host (Get-PCResultSummary -Result $actionResults).Text
        Write-Host ''
    }

    if ($Json) {
        # ErrorRecord does not serialise usefully and can be enormous.
        $results |
            Select-Object -Property * -ExcludeProperty ErrorRecord |
            ConvertTo-Json -Depth 8 -WarningAction SilentlyContinue
    }
    else {
        $results
    }

    $code = 0
    if ($actionResults.Count -gt 0) {
        if (@($actionResults | Where-Object Status -eq 'Failed').Count -gt 0) { $code = 2 }
        elseif (@($actionResults | Where-Object Status -eq 'Warning').Count -gt 0) { $code = 1 }
        elseif (@($actionResults | Where-Object RebootRequired).Count -gt 0) { $code = 3010 }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Diagnose') {
        $code = if ($results[0].Verdict.Healthy) { 0 } else { 2 }
    }

    $script:PCLastExitCode = $code

    if ($Exit) {
        # Deliberate: this terminates the host. Only the pctools shim passes it.
        exit $code
    }
}
