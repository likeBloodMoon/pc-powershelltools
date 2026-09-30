function Get-PCNetworkAdapter {
    <#
    .SYNOPSIS
        Lists network adapters with their IP configuration.

    .DESCRIPTION
        Merges the adapter list and its IP configuration into one object, which
        is what both GUIs were assembling separately - the Cleanup Tool listed
        adapters without addresses, and Net Diag listed addresses in a second
        table the user had to correlate by hand.

        Three CIM queries, not two per adapter. The first version called
        Get-NetIPConfiguration and Get-NetIPInterface inside the loop, so a
        laptop carrying Wi-Fi, Ethernet, Bluetooth, a Hyper-V switch and a VPN
        adapter paid twenty-odd round-trips to WMI to build one table. Asking
        for everything once and joining on ifIndex in memory gives the same
        objects for a fixed three.

    .PARAMETER ConnectedOnly
        Return only adapters whose status is Up.

    .EXAMPLE
        Get-PCNetworkAdapter -ConnectedOnly | Format-Table Name, IPv4Address, Gateway, DnsServers

    .OUTPUTS
        pscustomobject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$ConnectedOnly
    )

    $adapters = @()
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop)
    }
    catch {
        Write-PCLog -Level WARN -Message "Get-NetAdapter failed: $($_.Exception.Message)"
        return
    }

    if ($ConnectedOnly) {
        $adapters = @($adapters | Where-Object { $_.Status -eq 'Up' })
    }

    if ($adapters.Count -eq 0) { return }

    # Ask once, index by interface, join in memory.
    $configByIndex = @{}
    try {
        foreach ($item in @(Get-NetIPConfiguration -All -ErrorAction Stop)) {
            $configByIndex[[int]$item.InterfaceIndex] = $item
        }
    }
    catch {
        Write-PCLog -Level DEBUG -Message "Get-NetIPConfiguration failed: $($_.Exception.Message)"
    }

    $dhcpByIndex = @{}
    try {
        foreach ($item in @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop)) {
            $dhcpByIndex[[int]$item.InterfaceIndex] = ($item.Dhcp -eq 'Enabled')
        }
    }
    catch {
        Write-PCLog -Level DEBUG -Message "Get-NetIPInterface failed: $($_.Exception.Message)"
    }

    foreach ($adapter in $adapters) {
        $index = [int]$adapter.ifIndex

        $config = $null
        if ($configByIndex.ContainsKey($index)) { $config = $configByIndex[$index] }

        $isDhcp = $null
        if ($dhcpByIndex.ContainsKey($index)) { $isDhcp = $dhcpByIndex[$index] }

        [pscustomobject]@{
            PSTypeName           = 'PCTools.NetworkAdapter'
            Name                 = $adapter.Name
            InterfaceIndex       = $adapter.ifIndex
            InterfaceDescription = $adapter.InterfaceDescription
            Status               = $adapter.Status
            LinkSpeed            = $adapter.LinkSpeed
            MacAddress           = $adapter.MacAddress
            IPv4Address          = if ($config) { ($config.IPv4Address.IPAddress) -join ', ' } else { '' }
            IPv6Address          = if ($config) { ($config.IPv6Address.IPAddress) -join ', ' } else { '' }
            PrefixLength         = if ($config -and $config.IPv4Address) { @($config.IPv4Address)[0].PrefixLength } else { $null }
            Gateway              = if ($config) { ($config.IPv4DefaultGateway.NextHop) -join ', ' } else { '' }
            DnsServers           = if ($config) { ($config.DnsServer | Where-Object AddressFamily -eq 2 | ForEach-Object ServerAddresses) -join ', ' } else { '' }
            Dhcp                 = $isDhcp
        }
    }
}
