function Get-PCDriverIssue {
    <#
    .SYNOPSIS
        Finds devices Windows is reporting a problem with.

    .DESCRIPTION
        Device Manager marks a faulty device with a yellow triangle and hides
        the reason behind two clicks and a numeric code. The code is the useful
        part - "code 28" and "code 43" are entirely different problems with
        entirely different fixes - so it is decoded here.

        Also reports drivers dated more than three years ago, which is a weak
        signal on its own (a stable driver may be legitimately old) and so is
        reported separately from actual faults rather than mixed in with them.

    .PARAMETER IncludeOldDrivers
        Also list drivers older than the age threshold.

    .PARAMETER OldDriverYears
        How old a driver must be to be listed. Defaults to 3.

    .EXAMPLE
        Get-PCDriverIssue | Format-Table Name, Status, ProblemCode, Problem

    .OUTPUTS
        PCTools.DriverIssue
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$IncludeOldDrivers,

        [ValidateRange(1, 20)]
        [int]$OldDriverYears = 3
    )

    # The Configuration Manager error codes that actually turn up on a consumer
    # machine, with what each one means in practice.
    $problemText = @{
        1  = 'Not configured correctly. Reinstall the driver.'
        3  = 'The driver may be corrupted, or the system is low on memory.'
        10 = 'The device cannot start. Usually a driver or firmware fault.'
        12 = 'Not enough free resources. Two devices are contending for the same ones.'
        14 = 'The device needs a restart to work.'
        16 = 'Windows cannot identify all the resources this device uses.'
        18 = 'Reinstall the drivers for this device.'
        19 = 'The registry entry for this device is incomplete or damaged.'
        21 = 'Windows is removing this device.'
        22 = 'This device is disabled.'
        24 = 'The device is not present, is not working properly, or does not have all its drivers installed.'
        28 = 'The drivers for this device are not installed.'
        29 = 'Disabled because the firmware did not give it the resources it needs.'
        31 = 'This device is not working properly because Windows cannot load the required drivers.'
        32 = 'A driver for this device has been disabled. An alternate driver may be providing the function.'
        33 = 'Windows cannot determine which resources are required for this device.'
        34 = 'Windows cannot determine the settings for this device. Configure it in the firmware.'
        35 = 'The firmware does not include enough information to configure and use this device properly.'
        36 = 'This device is requesting a PCI interrupt but is configured for an ISA interrupt.'
        37 = 'Windows cannot initialize the device driver for this hardware.'
        38 = 'A previous instance of the driver is still in memory. Restart to clear it.'
        39 = 'The driver is corrupted, or missing.'
        40 = 'The service key information in the registry is missing or recorded incorrectly.'
        41 = 'Windows loaded the driver but cannot find the hardware.'
        42 = 'A duplicate device is already running.'
        43 = 'Windows stopped this device because it reported problems.'
        44 = 'An application or service shut this device down.'
        45 = 'This device is not connected.'
        47 = 'The device is prepared for safe removal but has not been removed.'
        48 = 'The software for this device is blocked from starting because it is known to have problems.'
        49 = 'Windows cannot start new hardware devices because the system hive is too large.'
        52 = 'Windows cannot verify the digital signature for the drivers required by this device.'
    }

    try {
        $devices = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.ConfigManagerErrorCode -and [int]$_.ConfigManagerErrorCode -ne 0 })
    }
    catch {
        Write-PCLog -Level WARN -Message "Could not enumerate devices: $($_.Exception.Message)"
        return
    }

    foreach ($device in $devices) {
        $code = [int]$device.ConfigManagerErrorCode

        [pscustomobject]@{
            PSTypeName   = 'PCTools.DriverIssue'
            Name         = $device.Name
            DeviceId     = $device.DeviceID
            Manufacturer = $device.Manufacturer
            Status       = 'Problem'
            ProblemCode  = $code
            Problem      = if ($problemText.ContainsKey($code)) { $problemText[$code] } else { "Configuration Manager error code $code." }
            DriverDate   = $null
            DriverVersion = ''
        }
    }

    if (-not $IncludeOldDrivers) { return }

    $cutoff = (Get-Date).AddYears(-$OldDriverYears)

    try {
        foreach ($driver in @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)) {
            if (-not $driver.DriverDate) { continue }
            if ($driver.DriverDate -ge $cutoff) { continue }

            # Microsoft's own inbox drivers are old by design and being old is
            # not a fault in them, so they would be pure noise here.
            if ($driver.DriverProviderName -eq 'Microsoft') { continue }
            if (-not $driver.DeviceName) { continue }

            [pscustomobject]@{
                PSTypeName    = 'PCTools.DriverIssue'
                Name          = $driver.DeviceName
                DeviceId      = $driver.DeviceID
                Manufacturer  = $driver.DriverProviderName
                Status        = 'Old'
                ProblemCode   = $null
                Problem       = 'Driver dates from {0:yyyy-MM-dd}. Old is not the same as broken; check the vendor only if this device misbehaves.' -f $driver.DriverDate
                DriverDate    = $driver.DriverDate
                DriverVersion = $driver.DriverVersion
            }
        }
    }
    catch {
        Write-PCLog -Level DEBUG -Message "Could not enumerate signed drivers: $($_.Exception.Message)"
    }
}
