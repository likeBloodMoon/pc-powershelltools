function Enable-PCStartupItem {
    <#
    .SYNOPSIS
        Switches a startup item back on.

    .DESCRIPTION
        The other half of Disable-PCStartupItem. Because disabling never removed
        anything, this is a flag flip rather than a reinstall.

    .PARAMETER Name
        The startup item names to enable, as reported by Get-PCStartupItem.

    .PARAMETER InputObject
        Startup items straight from Get-PCStartupItem.

    .EXAMPLE
        Enable-PCStartupItem -Name 'OneDrive'

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low', DefaultParameterSetName = 'Name')]
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
        Invoke-PCAction -Name 'Enable-PCStartupItem' -Body {
            # See Disable-PCStartupItem: @() around the whole expression so a
            # single match stays an array.
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

            $enabled = @()
            $failed = @()
            $already = @()

            foreach ($item in $items) {
                if ($item.Enabled) { $already += $item.Name; continue }
                if (-not $PSCmdlet.ShouldProcess($item.Name, "Enable ($($item.Source))")) { continue }

                try {
                    if ($item.Source -eq 'ScheduledTask') {
                        $path = Split-Path -Parent $item.Id
                        if (-not $path.EndsWith('\')) { $path = "$path\" }
                        Enable-ScheduledTask -TaskName $item.Name -TaskPath $path -ErrorAction Stop | Out-Null
                    }
                    else {
                        Set-PCStartupApproval -Name $item.Id -Source $item.Source -Scope $item.Scope -Enabled $true
                    }

                    $enabled += $item.Name
                    Write-PCLog -Level INFO -Message "Enabled startup item: $($item.Name)"
                }
                catch {
                    $failed += "$($item.Name) ($($_.Exception.Message))"
                }
            }

            $parts = @()
            if ($enabled.Count) { $parts += '{0} enabled: {1}' -f $enabled.Count, ($enabled -join ', ') }
            if ($already.Count) { $parts += '{0} already on' -f $already.Count }
            if ($failed.Count) { $parts += '{0} failed: {1}' -f $failed.Count, ($failed -join ', ') }

            @{
                Status = if ($failed.Count -eq 0 -and $enabled.Count -gt 0) { 'Success' }
                         elseif ($enabled.Count -gt 0) { 'Warning' }
                         elseif ($failed.Count -gt 0) { 'Failed' }
                         else { 'Skipped' }
                Detail = if ($parts.Count) { $parts -join '; ' } else { 'Nothing to do.' }
                Data   = @{ Enabled = $enabled; AlreadyEnabled = $already; Failed = $failed }
            }
        }
    }
}
