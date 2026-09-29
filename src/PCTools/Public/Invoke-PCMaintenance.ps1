function Invoke-PCMaintenance {
    <#
    .SYNOPSIS
        Runs a maintenance profile and returns one result per action.

    .DESCRIPTION
        The orchestrator behind the Cleanup Tool's "Run selected" and "Run all"
        buttons, with three differences that matter.

        A failing action no longer stops the run. Every action reports its own
        result, so a batch that hits one problem still completes the rest and
        the user sees what happened everywhere.

        A restore point is taken first for any profile that declares one, and if
        it cannot be taken the run stops rather than continuing unprotected -
        the original made the restore point an unchecked checkbox next to the
        destructive actions.

        -WhatIf lists what would run without running any of it, which is the
        preflight the roadmap asked for.

    .PARAMETER ProfileName
        A built-in profile name. See Get-PCMaintenanceProfile.

    .PARAMETER Action
        Explicit action names, instead of a profile.

    .PARAMETER SkipRestorePoint
        Run without taking a restore point first. You are on your own.

    .PARAMETER ContinueOnFailure
        Keep going after a failed action. On by default; set to $false to stop
        at the first failure.

    .EXAMPLE
        Invoke-PCMaintenance -ProfileName Quick -WhatIf

        Shows the plan without changing anything.

    .EXAMPLE
        Invoke-PCMaintenance -ProfileName Recommended |
            Format-Table Action, Status, FreedDisplay, Detail

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Profile')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0, ParameterSetName = 'Profile')]
        [string]$ProfileName = 'Quick',

        [Parameter(Mandatory, ParameterSetName = 'Action')]
        [string[]]$Action,

        [switch]$SkipRestorePoint,

        [bool]$ContinueOnFailure = $true
    )

    $plan = if ($PSCmdlet.ParameterSetName -eq 'Action') {
        [pscustomobject]@{
            Name         = 'Custom'
            Description  = 'User-selected actions'
            RestorePoint = $true
            Actions      = @($Action | ForEach-Object { @{ Action = $_ } })
        }
    }
    else {
        Get-PCMaintenanceProfile -Name $ProfileName
    }

    Write-PCLog -Level INFO -Message "Maintenance profile '$($plan.Name)': $(@($plan.Actions).Count) action(s)"

    if ($plan.RestorePoint -and -not $SkipRestorePoint) {
        $checkpoint = New-PCRestorePoint -Description "PCTools - $($plan.Name) maintenance"
        $checkpoint

        if ($checkpoint.Status -eq 'Failed') {
            Write-PCLog -Level ERROR -Message 'Restore point failed; stopping before any destructive action.'
            New-PCActionResult -Action 'Invoke-PCMaintenance' -Status Failed `
                -Detail 'Stopped: no restore point could be created. Re-run with -SkipRestorePoint to proceed anyway.'
            return
        }
    }

    foreach ($step in $plan.Actions) {
        $name = $step.Action
        $parameters = if ($step.ContainsKey('Parameters')) { $step.Parameters.Clone() } else { @{} }

        $command = Get-Command -Name $name -Module $script:ModuleName -ErrorAction SilentlyContinue

        # An extension action is not an exported command - it is a scriptblock
        # held in the extension table - so it is looked up separately. Only a
        # name that was actually registered resolves this way, which keeps an
        # unregistered name a clear failure rather than something that quietly
        # picks up a function from the caller's session.
        $extension = $null
        if (-not $command -and $script:PCExtension.ContainsKey($name)) {
            $extension = $script:PCExtension[$name]
        }

        if (-not $command -and -not $extension) {
            $detail = if ($script:PCExtension.Count -gt 0) {
                "'$name' is neither a $script:ModuleName command nor a registered extension. Get-PCExtension lists the extensions."
            }
            else {
                "No such action in $script:ModuleName"
            }
            New-PCActionResult -Action $name -Status Failed -Detail $detail
            continue
        }

        # Pass -WhatIf and -Confirm through so a preflight really is a preflight.
        if ($command -and $command.Parameters.ContainsKey('WhatIf')) {
            $parameters['WhatIf'] = $WhatIfPreference
        }

        $result = if ($extension) { & $extension.Command @parameters } else { & $command @parameters }
        $result

        if ($result.Status -eq 'Failed' -and -not $ContinueOnFailure) {
            Write-PCLog -Level WARN -Message "Stopping after failed action: $name"
            break
        }
    }
}
