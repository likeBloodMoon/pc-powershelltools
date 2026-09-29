function Clear-PCThumbnailCache {
    <#
    .SYNOPSIS
        Clears the Explorer thumbnail and icon caches.

    .DESCRIPTION
        Worth doing for two different reasons. It reclaims a few hundred
        megabytes on a machine with a large photo library, and it is the
        standard fix for Explorer showing wrong, stale or blank thumbnails and
        icons - a cosmetic fault with no other obvious cure.

        Explorer holds the cache files open, so it is restarted. Restart-PCExplorer
        waits for the shell to come back rather than sleeping and hoping, which
        is what stops this leaving somebody with no taskbar.

        Safe: Windows rebuilds both caches on demand.

    .PARAMETER SkipExplorerRestart
        Leave Explorer running. The locked cache files will not be reclaimed
        until the next sign-in.

    .EXAMPLE
        Clear-PCThumbnailCache

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [switch]$SkipExplorerRestart
    )

    Invoke-PCAction -Name 'Clear-PCThumbnailCache' -Body {
        $cacheDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'

        if (-not (Test-Path -LiteralPath $cacheDir)) {
            return @{ Status = 'Warning'; Detail = "Explorer cache folder not found: $cacheDir" }
        }

        $restarted = $false
        if (-not $SkipExplorerRestart) {
            if ($PSCmdlet.ShouldProcess('explorer.exe', 'Restart to release the cache files')) {
                $restart = Restart-PCExplorer
                $restarted = $restart.Status -eq 'Success'
            }
        }

        $bytes = 0L
        $removed = 0
        $locked = 0

        foreach ($file in @(Get-ChildItem -LiteralPath $cacheDir -Filter '*.db' -File -Force -ErrorAction SilentlyContinue)) {
            if ($file.Name -notlike 'thumbcache_*' -and $file.Name -notlike 'iconcache_*') { continue }
            if (-not $PSCmdlet.ShouldProcess($file.FullName, 'Remove')) { continue }

            try {
                $size = $file.Length
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $bytes += $size
                $removed++
            }
            catch {
                $locked++
            }
        }

        $detail = '{0} cache file(s) removed, {1} freed' -f $removed, (Format-PCByteSize -Bytes $bytes)
        if ($locked -gt 0) {
            $detail += "; $locked still in use and will be rebuilt at the next sign-in"
        }

        @{
            Status     = if ($removed -eq 0 -and $locked -gt 0) { 'Warning' } else { 'Success' }
            Detail     = $detail
            BytesFreed = $bytes
            Data       = @{ Removed = $removed; Locked = $locked; ExplorerRestarted = $restarted }
        }
    }
}
