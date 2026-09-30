function Clear-PCDeliveryOptimization {
    <#
    .SYNOPSIS
        Removes the Delivery Optimization download cache.

    .DESCRIPTION
        Delivery Optimization keeps the update and Store payloads it has
        downloaded so it can serve them to other machines on the network. On a
        single-PC household that cache is pure cost, and it routinely reaches
        several gigabytes.

        Windows reclaims it eventually. "Eventually" is not much help to
        somebody who cannot install an update because the disk is full.

        Safe: this is a cache, and clearing it costs at most a re-download.

    .EXAMPLE
        Clear-PCDeliveryOptimization -WhatIf

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param()

    Invoke-PCAction -Name 'Clear-PCDeliveryOptimization' -Body {
        Assert-PCAdmin -Action 'Clearing the Delivery Optimization cache'

        $cachePath = Join-Path $env:SystemRoot 'SoftwareDistribution\DeliveryOptimization'
        $alternate = Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization'

        # The service holds its files open, so it stops first and starts again
        # afterwards whatever happens.
        $service = Get-Service -Name 'DoSvc' -ErrorAction SilentlyContinue
        $wasRunning = $service -and $service.Status -eq 'Running'

        if ($wasRunning -and $PSCmdlet.ShouldProcess('DoSvc', 'Stop the Delivery Optimization service')) {
            try { Stop-Service -Name 'DoSvc' -Force -ErrorAction Stop }
            catch { Write-PCLog -Level WARN -Message "Could not stop DoSvc: $($_.Exception.Message)" }
        }

        try {
            $totalBytes = 0L
            $totalRemoved = 0
            $cleaned = @()

            foreach ($path in @($cachePath, $alternate)) {
                if (-not (Test-Path -LiteralPath $path)) { continue }
                $outcome = Clear-PCFolderContent -Path $path
                if ($outcome.Missing) { continue }
                $totalBytes += $outcome.BytesFreed
                $totalRemoved += $outcome.ItemsRemoved
                $cleaned += $path
            }

            if ($cleaned.Count -eq 0) {
                return @{ Status = 'Warning'; Detail = 'No Delivery Optimization cache was found.' }
            }

            @{
                Detail     = '{0} freed from the Delivery Optimization cache' -f (Format-PCByteSize -Bytes $totalBytes)
                BytesFreed = $totalBytes
                Data       = @{ Paths = $cleaned; ItemsRemoved = $totalRemoved }
            }
        }
        finally {
            if ($wasRunning) {
                try { Start-Service -Name 'DoSvc' -ErrorAction Stop }
                catch { Write-PCLog -Level WARN -Message "Could not restart DoSvc: $($_.Exception.Message)" }
            }
        }
    }
}
