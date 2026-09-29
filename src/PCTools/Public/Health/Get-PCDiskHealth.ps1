function Get-PCDiskHealth {
    <#
    .SYNOPSIS
        Reads SMART-derived health and wear for every physical disk.

    .DESCRIPTION
        The one diagnostic in this module that can tell somebody to buy a drive
        before it takes their data with it. Storage Spaces exposes the useful
        SMART fields through Get-StorageReliabilityCounter without needing a
        vendor tool: reallocated sectors, read and write error counts, power-on
        hours and, on SSDs, the wear percentage.

        Every field is optional in practice. Plenty of consumer drives, and most
        USB enclosures, report nothing at all - a blank column here means the
        drive did not answer, not that the drive is fine. The Health column
        distinguishes the two.

    .EXAMPLE
        Get-PCDiskHealth | Format-Table FriendlyName, MediaType, Health, Wear, PowerOnHours, Temperature

    .OUTPUTS
        PCTools.DiskHealth
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $disks = @()
    try {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop)
    }
    catch {
        Write-PCLog -Level WARN -Message "Could not enumerate physical disks: $($_.Exception.Message)"
        return
    }

    foreach ($disk in $disks) {
        $counter = $null
        try {
            # Needs elevation on most systems, and simply returns nothing on
            # drives behind a USB bridge.
            $counter = $disk | Get-StorageReliabilityCounter -ErrorAction Stop
        }
        catch {
            Write-PCLog -Level DEBUG -Message "No reliability counters for $($disk.FriendlyName): $($_.Exception.Message)"
        }

        $wear = $null
        if ($counter -and $null -ne $counter.Wear) { $wear = [int]$counter.Wear }

        $reallocated = $null
        if ($counter -and $null -ne $counter.ReadErrorsUncorrected) { $reallocated = [int]$counter.ReadErrorsUncorrected }

        # HealthStatus is the operating system's own verdict and is the most
        # trustworthy single field; the counters refine it.
        $health = [string]$disk.HealthStatus
        $concern = @()

        if ($health -and $health -ne 'Healthy') { $concern += "Windows reports the disk as $health" }
        if ($null -ne $wear -and $wear -ge 80) { $concern += "$wear% of rated write endurance used" }
        if ($null -ne $reallocated -and $reallocated -gt 0) { $concern += "$reallocated uncorrected read error(s)" }

        $verdict = if ($concern.Count -gt 0) { 'Attention' }
                   elseif ($health -eq 'Healthy') { 'Healthy' }
                   else { 'Unknown' }

        [pscustomobject]@{
            PSTypeName       = 'PCTools.DiskHealth'
            FriendlyName     = $disk.FriendlyName
            SerialNumber     = $disk.SerialNumber
            MediaType        = [string]$disk.MediaType
            BusType          = [string]$disk.BusType
            Size             = [long]$disk.Size
            SizeDisplay      = Format-PCByteSize -Bytes ([long]$disk.Size)
            HealthStatus     = $health
            Health           = $verdict
            Wear             = $wear
            PowerOnHours     = if ($counter) { $counter.PowerOnHours } else { $null }
            Temperature      = if ($counter) { $counter.Temperature } else { $null }
            ReadErrors       = if ($counter) { $counter.ReadErrorsTotal } else { $null }
            WriteErrors      = if ($counter) { $counter.WriteErrorsTotal } else { $null }
            CountersReadable = [bool]$counter
            Concerns         = $concern
        }
    }
}
