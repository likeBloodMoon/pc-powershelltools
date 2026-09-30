function Remove-PCAppxPackage {
    <#
    .SYNOPSIS
        Removes preinstalled apps from the curated removable list. Nothing else.

    .DESCRIPTION
        Every package named is checked against Get-PCRemovableAppxName and
        refused if it is not on it. There is no -Force to override that, on
        purpose: the failure mode of debloating scripts is removing something
        load-bearing, and an escape hatch here would be used by exactly the
        people who should not use it. Remove-AppxPackage is still available for
        anyone who genuinely means it.

        Removal is per-user by default. -AllUsers also removes the provisioned
        copy, so new accounts on the machine do not get the app back - which is
        usually what somebody actually wants and almost never what they get.

    .PARAMETER Name
        Package names to remove, from Get-PCAppxPackage.

    .PARAMETER All
        Remove everything on the curated list that is currently installed.

    .PARAMETER AllUsers
        Also remove the provisioned package, so new user accounts do not receive
        it. Needs elevation.

    .EXAMPLE
        Get-PCAppxPackage -RemovableOnly | Format-Table DisplayName, SizeDisplay
        Remove-PCAppxPackage -Name 'Microsoft.BingWeather' -WhatIf

    .EXAMPLE
        Remove-PCAppxPackage -All -WhatIf

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Name')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Name')]
        [string[]]$Name,

        [Parameter(Mandatory, ParameterSetName = 'All')]
        [switch]$All,

        [switch]$AllUsers
    )

    Invoke-PCAction -Name 'Remove-PCAppxPackage' -Body {
        if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
            return @{ Status = 'Failed'; Detail = 'Appx cmdlets are not available on this system.' }
        }

        if ($AllUsers) { Assert-PCAdmin -Action 'Removing a provisioned package' }

        $allowed = Get-PCRemovableAppxName
        $installed = @(Get-PCAppxPackage -RemovableOnly)

        # @() around the whole expression: an `if` that yields a one-element
        # array assigns a scalar, and .Count on it then throws under strict
        # mode. Removing one named package is the normal case.
        $targets = @(if ($All) {
            $installed
        }
        else {
            @($installed | Where-Object { $Name -contains $_.Name })
        })

        # Anything asked for by name that is not on the allowlist is refused
        # loudly rather than silently ignored - the user needs to know their
        # instruction was not carried out, and why.
        $refused = @()
        if ($Name) {
            foreach ($requested in $Name) {
                if ($allowed -notcontains $requested) { $refused += $requested }
            }
        }

        if ($targets.Count -eq 0 -and $refused.Count -eq 0) {
            return @{ Status = 'Skipped'; Detail = 'No matching removable package is installed.' }
        }

        $removed = @()
        $failed = @()
        $bytes = 0L

        foreach ($package in $targets) {
            if (-not $PSCmdlet.ShouldProcess($package.DisplayName, 'Remove app')) { continue }

            try {
                Get-AppxPackage -Name $package.Name -ErrorAction Stop |
                    Remove-AppxPackage -ErrorAction Stop

                $removed += $package.DisplayName
                $bytes += [long]$package.Size
                Write-PCLog -Level INFO -Message "Removed app: $($package.Name)"
            }
            catch {
                $failed += "$($package.Name) ($($_.Exception.Message))"
                continue
            }

            if ($AllUsers) {
                try {
                    Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                        Where-Object { $_.DisplayName -eq $package.Name } |
                        ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null }
                }
                catch {
                    Write-PCLog -Level WARN -Message "Removed for this user, but the provisioned copy of $($package.Name) remains: $($_.Exception.Message)"
                }
            }
        }

        $parts = @()
        if ($removed.Count) { $parts += '{0} removed: {1}' -f $removed.Count, ($removed -join ', ') }
        if ($refused.Count) {
            $parts += 'refused as not on the removable list: {0}' -f ($refused -join ', ')
        }
        if ($failed.Count) { $parts += '{0} failed: {1}' -f $failed.Count, ($failed -join ', ') }

        @{
            Status     = if ($failed.Count -eq 0 -and $refused.Count -eq 0 -and $removed.Count -gt 0) { 'Success' }
                         elseif ($removed.Count -gt 0) { 'Warning' }
                         elseif ($refused.Count -gt 0 -or $failed.Count -gt 0) { 'Failed' }
                         else { 'Skipped' }
            Detail     = if ($parts.Count) { $parts -join '; ' } else { 'Nothing to do.' }
            BytesFreed = $bytes
            Data       = @{ Removed = $removed; Refused = $refused; Failed = $failed }
        }
    }
}
