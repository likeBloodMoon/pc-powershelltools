function Update-PCApplication {
    <#
    .SYNOPSIS
        Upgrades installed applications through winget.

    .DESCRIPTION
        Out-of-date applications are a bigger practical security exposure on a
        home machine than missing Windows patches, and winget already knows how
        to fix that for anything it manages.

        Two things this does that a bare `winget upgrade --all` does not: it
        reports per-package outcomes as structured results, and it skips
        packages pinned with `winget pin` rather than fighting them.

    .PARAMETER Id
        Upgrade only these package IDs.

    .PARAMETER Exclude
        Package IDs to leave alone. Useful for the one application whose
        auto-update you do not trust.

    .PARAMETER ListOnly
        Report what is out of date without upgrading anything. Equivalent to
        -WhatIf, and kept because it reads better in a script.

    .PARAMETER TimeoutMinutes
        Per-package timeout.

    .EXAMPLE
        Update-PCApplication -ListOnly

    .EXAMPLE
        Update-PCApplication -Exclude 'Mozilla.Firefox'

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [string[]]$Id,

        [string[]]$Exclude = @(),

        [switch]$ListOnly,

        [ValidateRange(1, 120)]
        [int]$TimeoutMinutes = 20
    )

    Invoke-PCAction -Name 'Update-PCApplication' -Body {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            return @{
                Status = 'Failed'
                Detail = 'winget is not available. Install "App Installer" from the Microsoft Store, then try again.'
                Data   = @{ WingetAvailable = $false }
            }
        }

        $list = Invoke-PCProcess -FilePath 'winget.exe' -ArgumentList @(
            'upgrade', '--include-unknown', '--accept-source-agreements', '--disable-interactivity'
        ) -TimeoutSeconds 180

        if ($list.TimedOut) {
            return @{ Status = 'Failed'; Detail = 'winget did not respond within 3 minutes.' }
        }

        # winget writes a fixed-width table with no machine-readable option that
        # is stable across versions. The Id column is the only field needed and
        # it is reliably the second whitespace-separated token on a data row.
        $available = @()
        foreach ($line in ($list.Output -split "`r?`n")) {
            if ($line -match '^\s*$') { continue }
            if ($line -match '^\s*(Name|-{3,})') { continue }
            if ($line -match 'upgrades available|No installed package|package\(s\) have') { continue }

            $columns = $line -split '\s{2,}' | Where-Object { $_ }
            if ($columns.Count -lt 4) { continue }

            $packageId = $columns[1].Trim()
            if ($packageId -notmatch '\.') { continue }

            $available += [pscustomobject]@{
                Name      = $columns[0].Trim()
                Id        = $packageId
                Version   = $columns[2].Trim()
                Available = $columns[3].Trim()
            }
        }

        if ($Id) { $available = @($available | Where-Object { $Id -contains $_.Id }) }
        if ($Exclude.Count) { $available = @($available | Where-Object { $Exclude -notcontains $_.Id }) }

        if ($available.Count -eq 0) {
            return @{ Status = 'Success'; Detail = 'Everything winget manages is up to date.'; Data = @{ Upgraded = @() } }
        }

        if ($ListOnly) {
            return @{
                Status = 'Success'
                Detail = '{0} package(s) out of date: {1}' -f $available.Count, (($available.Id) -join ', ')
                Data   = @{ Available = $available }
            }
        }

        $upgraded = @()
        $failed = @()
        $skipped = @()

        foreach ($package in $available) {
            if (-not $PSCmdlet.ShouldProcess($package.Id, "Upgrade $($package.Version) to $($package.Available)")) {
                $skipped += $package.Id
                continue
            }

            Write-PCLog -Level INFO -Message "winget upgrade $($package.Id)"

            $run = Invoke-PCProcess -FilePath 'winget.exe' -ArgumentList @(
                'upgrade', '--id', $package.Id, '--exact', '--silent',
                '--accept-source-agreements', '--accept-package-agreements',
                '--disable-interactivity'
            ) -TimeoutSeconds ($TimeoutMinutes * 60)

            # 0x8A15002B: no applicable upgrade, which after a successful
            # upgrade elsewhere in the run is a normal outcome, not a failure.
            $noUpgrade = $run.ExitCode -eq -1978335189

            if ($run.TimedOut) { $failed += "$($package.Id) (timed out)" }
            elseif ($run.ExitCode -eq 0) { $upgraded += $package.Id }
            elseif ($noUpgrade) { $skipped += $package.Id }
            else {
                $failed += "$($package.Id) (exit $($run.ExitCode))"
                Write-PCLog -Level WARN -Message "winget upgrade failed for $($package.Id): $($run.Output)"
            }
        }

        $parts = @()
        if ($upgraded.Count) { $parts += "$($upgraded.Count) upgraded" }
        if ($skipped.Count) { $parts += "$($skipped.Count) skipped" }
        if ($failed.Count) { $parts += "$($failed.Count) failed: $($failed -join ', ')" }

        @{
            Status = if ($failed.Count -eq 0) { 'Success' } elseif ($upgraded.Count) { 'Warning' } else { 'Failed' }
            Detail = if ($parts.Count) { $parts -join '; ' } else { 'Nothing to do.' }
            Data   = @{ Upgraded = $upgraded; Skipped = $skipped; Failed = $failed }
        }
    }
}
