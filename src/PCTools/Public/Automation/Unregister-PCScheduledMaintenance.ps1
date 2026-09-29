function Unregister-PCScheduledMaintenance {
    <#
    .SYNOPSIS
        Removes a scheduled maintenance task.

    .DESCRIPTION
        Refuses to remove a task this module did not register. Passing the wrong
        name to Unregister-ScheduledTask deletes whatever is there; this checks
        the task actually invokes Invoke-PCTools first.

    .PARAMETER TaskName
        The task to remove. Defaults to 'PCTools Maintenance'.

    .EXAMPLE
        Unregister-PCScheduledMaintenance -WhatIf

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string]$TaskName = 'PCTools Maintenance'
    )

    Invoke-PCAction -Name 'Unregister-PCScheduledMaintenance' -Body {
        Assert-PCAdmin -Action 'Removing a scheduled task'

        $task = @(Get-PCScheduledMaintenance -TaskName $TaskName)

        if ($task.Count -eq 0) {
            return @{
                Status = 'Skipped'
                Detail = "No PC Tools scheduled task named '$TaskName'. Get-PCScheduledMaintenance lists the ones there are."
            }
        }

        if (-not $PSCmdlet.ShouldProcess($TaskName, 'Unregister the scheduled task')) {
            return @{ Status = 'Skipped'; Detail = "Would remove '$TaskName'." }
        }

        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $task[0].TaskPath -Confirm:$false -ErrorAction Stop

        @{
            Detail = "'$TaskName' removed; the $($task[0].ProfileName) profile will no longer run on a schedule."
            Data   = @{ TaskName = $TaskName; ProfileName = $task[0].ProfileName }
        }
    }
}
