function Get-PCSystemInfo {
    <#
    .SYNOPSIS
        What this machine is.

    .DESCRIPTION
        The first question in any support conversation, answered in one object:
        model, CPU, memory, Windows build, uptime, firmware mode and Secure Boot
        state.

        The Windows build number matters more than the version name - "Windows
        11" spans several builds with materially different behaviour - so it is
        reported in full alongside the display version.

    .EXAMPLE
        Get-PCSystemInfo | Format-List

    .OUTPUTS
        PCTools.SystemInfo
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $computer = $null
    $os = $null
    $cpu = $null
    $bios = $null

    try { $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }
    try { $cpu = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)[0] } catch { }
    try { $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop } catch { }

    $uptime = $null
    $lastBoot = $null
    if ($os -and $os.LastBootUpTime) {
        $lastBoot = $os.LastBootUpTime
        $uptime = (Get-Date) - $lastBoot
    }

    # The display version (23H2 and so on) is only in the registry.
    $displayVersion = ''
    try {
        $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $displayVersion = if ($currentVersion.PSObject.Properties.Name -contains 'DisplayVersion') {
            [string]$currentVersion.DisplayVersion
        }
        elseif ($currentVersion.PSObject.Properties.Name -contains 'ReleaseId') {
            [string]$currentVersion.ReleaseId
        }
        else { '' }
    }
    catch { }

    $secureBoot = $null
    try { $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop }
    catch {
        # Throws rather than returning false on a legacy BIOS machine, which is
        # itself the answer.
        $secureBoot = $false
    }

    $firmware = 'Unknown'
    try {
        $firmware = if ($env:firmware_type) { $env:firmware_type }
                    elseif ($secureBoot) { 'UEFI' }
                    else { 'Unknown' }
    }
    catch { }

    $memoryBytes = if ($computer) { [long]$computer.TotalPhysicalMemory } else { 0L }

    [pscustomobject]@{
        PSTypeName      = 'PCTools.SystemInfo'
        ComputerName    = $env:COMPUTERNAME
        User            = "$env:USERDOMAIN\$env:USERNAME"
        Manufacturer    = if ($computer) { $computer.Manufacturer } else { '' }
        Model           = if ($computer) { $computer.Model } else { '' }
        SerialNumber    = if ($bios) { $bios.SerialNumber } else { '' }
        BiosVersion     = if ($bios) { ($bios.SMBIOSBIOSVersion) } else { '' }
        Firmware        = $firmware
        SecureBoot      = $secureBoot
        OperatingSystem = if ($os) { $os.Caption } else { '' }
        DisplayVersion  = $displayVersion
        Build           = if ($os) { "$($os.Version) (build $($os.BuildNumber))" } else { '' }
        Architecture    = if ($os) { $os.OSArchitecture } else { '' }
        InstalledOn     = if ($os) { $os.InstallDate } else { $null }
        Processor       = if ($cpu) { $cpu.Name } else { '' }
        Cores           = if ($cpu) { [int]$cpu.NumberOfCores } else { $null }
        LogicalCores    = if ($cpu) { [int]$cpu.NumberOfLogicalProcessors } else { $null }
        Memory          = $memoryBytes
        MemoryDisplay   = Format-PCByteSize -Bytes $memoryBytes
        LastBoot        = $lastBoot
        Uptime          = $uptime
        UptimeDisplay   = if ($uptime) { '{0}d {1}h {2}m' -f $uptime.Days, $uptime.Hours, $uptime.Minutes } else { '' }
        IsAdmin         = Test-PCAdmin
        PSVersion       = $PSVersionTable.PSVersion.ToString()
    }
}
