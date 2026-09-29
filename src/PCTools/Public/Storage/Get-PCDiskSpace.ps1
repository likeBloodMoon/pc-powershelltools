function Get-PCDiskSpace {
    <#
    .SYNOPSIS
        Reports free and used space per fixed drive.

    .DESCRIPTION
        The question every cleanup starts with and the module could not answer:
        how much room is there, and on which drive. Reported with a percentage
        and a plain-language pressure grade, because "48.2 GB free" means
        something very different on a 4 TB disk and a 128 GB one.

    .PARAMETER DriveLetter
        Limit to these drives. Defaults to every fixed drive.

    .PARAMETER IncludeRemovable
        Also report removable and network drives.

    .EXAMPLE
        Get-PCDiskSpace | Format-Table Drive, Label, FreeDisplay, SizeDisplay, PercentFree, Pressure

    .OUTPUTS
        PCTools.DiskSpace
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]]$DriveLetter,

        [switch]$IncludeRemovable
    )

    $volumes = @()
    try {
        # DriveType 3 is a local fixed disk; 2 removable, 4 network.
        $wanted = if ($IncludeRemovable) { 2, 3, 4 } else { @(3) }
        $volumes = @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop |
            Where-Object { $wanted -contains [int]$_.DriveType })
    }
    catch {
        Write-PCLog -Level WARN -Message "Could not read logical disks: $($_.Exception.Message)"
        return
    }

    foreach ($volume in $volumes) {
        $letter = ($volume.DeviceID -replace ':$', '')

        if ($DriveLetter) {
            $normalised = @($DriveLetter | ForEach-Object { $_.TrimEnd(':').ToUpperInvariant() })
            if ($normalised -notcontains $letter.ToUpperInvariant()) { continue }
        }

        $size = [long]$volume.Size
        $free = [long]$volume.FreeSpace
        $used = $size - $free

        # A share or an unreadable volume reports zero, and dividing by it
        # would be the only failure in an otherwise fine report.
        $percentFree = if ($size -gt 0) { [math]::Round(($free / $size) * 100, 1) } else { $null }

        $pressure = if ($null -eq $percentFree) { 'Unknown' }
                    elseif ($percentFree -lt 5)  { 'Critical' }
                    elseif ($percentFree -lt 10) { 'Low' }
                    elseif ($percentFree -lt 20) { 'Tight' }
                    else                         { 'Comfortable' }

        [pscustomobject]@{
            PSTypeName  = 'PCTools.DiskSpace'
            Drive       = "${letter}:"
            Label       = $volume.VolumeName
            FileSystem  = $volume.FileSystem
            Size        = $size
            SizeDisplay = Format-PCByteSize -Bytes $size
            Used        = $used
            UsedDisplay = Format-PCByteSize -Bytes $used
            Free        = $free
            FreeDisplay = Format-PCByteSize -Bytes $free
            PercentFree = $percentFree
            Pressure    = $pressure
        }
    }
}
