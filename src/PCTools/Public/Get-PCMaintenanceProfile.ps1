function Get-PCMaintenanceProfile {
    <#
    .SYNOPSIS
        Lists the built-in maintenance presets.

    .DESCRIPTION
        The "preset profiles" and "config file support" items from the roadmap.
        A profile is a name, a description, and an ordered list of actions with
        their parameters - so a preset is data, and a user-supplied JSON config
        is the same data loaded from disk.

        Note what is and is not in Recommended: Prefetch cleanup and the network
        stack reset are deliberately excluded, because both cost the user
        something and neither belongs in a preset someone runs without reading.
        The same reasoning keeps Clear-PCWindowsOld, Clear-PCEventLog and
        Remove-PCAppxPackage out of every profile here - each gives up something
        that cannot be got back, so each has to be asked for by name.

    .PARAMETER Name
        Return only this profile.

    .EXAMPLE
        Get-PCMaintenanceProfile | Format-Table Name, Description

    .OUTPUTS
        pscustomobject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Name
    )

    $profiles = @(
        [pscustomobject]@{
            PSTypeName  = 'PCTools.MaintenanceProfile'
            Name        = 'Quick'
            Description = 'Reclaim disk space. No repairs, no restart, a minute or two.'
            RestorePoint = $false
            Actions     = @(
                @{ Action = 'Clear-PCTempFile' }
                @{ Action = 'Clear-PCRecycleBin' }
                @{ Action = 'Clear-PCBrowserCache' }
                @{ Action = 'Clear-PCDnsCache' }
            )
        }
        [pscustomobject]@{
            PSTypeName  = 'PCTools.MaintenanceProfile'
            Name        = 'Recommended'
            Description = 'Quick, plus the Windows Update cache and a health scan. Takes a restore point first.'
            RestorePoint = $true
            Actions     = @(
                @{ Action = 'Clear-PCTempFile' }
                @{ Action = 'Clear-PCRecycleBin' }
                @{ Action = 'Clear-PCBrowserCache' }
                @{ Action = 'Clear-PCWindowsUpdateCache' }
                @{ Action = 'Clear-PCDnsCache' }
                @{ Action = 'Repair-PCSystemImage'; Parameters = @{ ScanOnly = $true } }
                @{ Action = 'Test-PCDisk' }
            )
        }
        [pscustomobject]@{
            PSTypeName  = 'PCTools.MaintenanceProfile'
            Name        = 'Full'
            Description = 'Everything including component store and system file repair. Can run for an hour; expect a restart.'
            RestorePoint = $true
            Actions     = @(
                @{ Action = 'Clear-PCTempFile' }
                @{ Action = 'Clear-PCRecycleBin' }
                @{ Action = 'Clear-PCBrowserCache' }
                @{ Action = 'Clear-PCWindowsUpdateCache' }
                @{ Action = 'Clear-PCDnsCache' }
                @{ Action = 'Repair-PCSystemImage' }
                @{ Action = 'Repair-PCSystemFile' }
                @{ Action = 'Test-PCDisk' }
            )
        }
        [pscustomobject]@{
            PSTypeName  = 'PCTools.MaintenanceProfile'
            Name        = 'Storage'
            Description = 'The deeper disk reclaims: update and delivery caches, crash dumps, thumbnails. No repairs.'
            RestorePoint = $false
            Actions     = @(
                @{ Action = 'Clear-PCTempFile' }
                @{ Action = 'Clear-PCRecycleBin' }
                @{ Action = 'Clear-PCBrowserCache' }
                @{ Action = 'Clear-PCWindowsUpdateCache' }
                @{ Action = 'Clear-PCDeliveryOptimization' }
                @{ Action = 'Clear-PCCrashDump' }
                @{ Action = 'Clear-PCThumbnailCache' }
            )
        }
        [pscustomobject]@{
            PSTypeName  = 'PCTools.MaintenanceProfile'
            Name        = 'Health'
            Description = 'Read-only. Reports how the machine is doing and changes nothing at all.'
            RestorePoint = $false
            Actions     = @(
                @{ Action = 'Test-PCDisk'; Parameters = @{ ScanOnly = $true } }
                @{ Action = 'Repair-PCSystemImage'; Parameters = @{ ScanOnly = $true } }
            )
        }
        [pscustomobject]@{
            PSTypeName  = 'PCTools.MaintenanceProfile'
            Name        = 'Weekly'
            Description = 'The sensible default for a schedule: reclaim space, refresh DNS, no restart.'
            RestorePoint = $false
            Actions     = @(
                @{ Action = 'Clear-PCTempFile' }
                @{ Action = 'Clear-PCRecycleBin' }
                @{ Action = 'Clear-PCBrowserCache' }
                @{ Action = 'Clear-PCDeliveryOptimization' }
                @{ Action = 'Clear-PCDnsCache' }
            )
        }
        [pscustomobject]@{
            PSTypeName  = 'PCTools.MaintenanceProfile'
            Name        = 'NetworkRepair'
            Description = 'Diagnose, then apply the standard network fixes. Requires a restart.'
            RestorePoint = $true
            Actions     = @(
                @{ Action = 'Clear-PCDnsCache' }
                @{ Action = 'Reset-PCNetworkStack' }
            )
        }
    )

    # Profiles loaded from a user's JSON config are first-class: they appear in
    # the list and run through the same orchestrator. A user profile with the
    # same name as a built-in wins, so a config file can override a preset.
    $imported = @($script:PCImportedProfile)
    if ($imported.Count -gt 0) {
        $overridden = $imported.Name
        $profiles = @($profiles | Where-Object { $overridden -notcontains $_.Name }) + $imported
    }

    if ($Name) {
        $match = @($profiles | Where-Object Name -eq $Name)
        if ($match.Count -eq 0) {
            throw "Unknown profile '$Name'. Available: $(($profiles.Name) -join ', ')."
        }
        return $match[0]
    }

    $profiles
}
