function Disable-PCStartupItem {
    <#
    .SYNOPSIS
        Switches off a startup item, reversibly.

    .DESCRIPTION
        Reversibility is the whole design. Deleting a Run key entry is
        irreversible and loses the command line; this writes the same
        StartupApproved flag Task Manager writes, so the entry stays where it
        is and Enable-PCStartupItem puts it back. Scheduled tasks are disabled
        rather than unregistered for the same reason.

        Pass names from Get-PCStartupItem.

    .PARAMETER Name
        The startup item names to disable, as reported by Get-PCStartupItem.

    .PARAMETER InputObject
        Startup items straight from Get-PCStartupItem, so the two compose.

    .EXAMPLE
        Get-PCStartupItem | Where-Object Name -like 'Spotify*' | Disable-PCStartupItem -WhatIf

    .EXAMPLE
        Disable-PCStartupItem -Name 'OneDrive'

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Name')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Name')]
        [string[]]$Name,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'Object')]
        [object[]]$InputObject
    )

    begin {
        $targets = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Object') {
            foreach ($item in $InputObject) { $targets.Add($item) }
        }
    }

    end {
        Invoke-PCAction -Name 'Disable-PCStartupItem' -Body {
            # @() around the whole expression: an `if` that yields a
            # one-element array assigns a scalar, and .Count on it then throws
            # under strict mode. Disabling a single item is the usual case.
            $items = @(if ($targets.Count -gt 0) {
                @($targets)
            }
            else {
                $all = @(Get-PCStartupItem)
                @($all | Where-Object { $Name -contains $_.Name })
            })

            if ($items.Count -eq 0) {
                return @{
                    Status = 'Warning'
                    Detail = 'No matching startup item. Run Get-PCStartupItem to see the names.'
                }
            }

            $disabled = @()
            $failed = @()
            $already = @()

            foreach ($item in $items) {
                if (-not $item.Enabled) { $already += $item.Name; continue }
                if (-not $PSCmdlet.ShouldProcess($item.Name, "Disable ($($item.Source))")) { continue }

                try {
                    if ($item.Source -eq 'ScheduledTask') {
                        $path = Split-Path -Parent $item.Id
                        if (-not $path.EndsWith('\')) { $path = "$path\" }
                        Disable-ScheduledTask -TaskName $item.Name -TaskPath $path -ErrorAction Stop | Out-Null
                    }
                    else {
                        Set-PCStartupApproval -Name $item.Id -Source $item.Source -Scope $item.Scope -Enabled $false
                    }

                    $disabled += $item.Name
                    Write-PCLog -Level INFO -Message "Disabled startup item: $($item.Name)"
                }
                catch {
                    $failed += "$($item.Name) ($($_.Exception.Message))"
                }
            }

            $parts = @()
            if ($disabled.Count) { $parts += '{0} disabled: {1}' -f $disabled.Count, ($disabled -join ', ') }
            if ($already.Count) { $parts += '{0} already off' -f $already.Count }
            if ($failed.Count) { $parts += '{0} failed: {1}' -f $failed.Count, ($failed -join ', ') }

            @{
                Status = if ($failed.Count -eq 0 -and $disabled.Count -gt 0) { 'Success' }
                         elseif ($disabled.Count -gt 0) { 'Warning' }
                         elseif ($failed.Count -gt 0) { 'Failed' }
                         else { 'Skipped' }
                Detail = if ($parts.Count) { $parts -join '; ' } else { 'Nothing to do.' }
                Data   = @{ Disabled = $disabled; AlreadyDisabled = $already; Failed = $failed }
            }
        }
    }
}
