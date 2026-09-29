function Get-PCBatteryReport {
    <#
    .SYNOPSIS
        Reports battery wear: how much capacity the battery has actually lost.

    .DESCRIPTION
        "My laptop does not last as long as it used to" has a number behind it,
        and Windows knows it: the difference between the battery's design
        capacity and what it can hold today.

        Read from the ROOT\WMI battery classes rather than by shelling out to
        powercfg /batteryreport, which writes an HTML file to disk and would
        then have to be parsed back out of it.

        Returns nothing on a desktop, which is the correct answer there.

    .EXAMPLE
        Get-PCBatteryReport | Format-List

    .OUTPUTS
        PCTools.BatteryReport
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $statics = @()
    try {
        $statics = @(Get-CimInstance -Namespace 'ROOT\WMI' -ClassName BatteryStaticData -ErrorAction Stop)
    }
    catch {
        Write-PCLog -Level DEBUG -Message "No battery static data: $($_.Exception.Message)"
        return
    }

    if ($statics.Count -eq 0) { return }

    $fullCharge = @()
    try { $fullCharge = @(Get-CimInstance -Namespace 'ROOT\WMI' -ClassName BatteryFullChargedCapacity -ErrorAction Stop) } catch { }

    $status = $null
    try { $status = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop } catch { }

    foreach ($battery in $statics) {
        $design = [long]$battery.DesignedCapacity

        $current = 0L
        $match = $fullCharge | Where-Object { $_.InstanceName -eq $battery.InstanceName } | Select-Object -First 1
        if ($match) { $current = [long]$match.FullChargedCapacity }
        elseif ($fullCharge.Count -gt 0) { $current = [long]$fullCharge[0].FullChargedCapacity }

        $healthPercent = if ($design -gt 0 -and $current -gt 0) {
            [math]::Round(($current / $design) * 100, 1)
        }
        else { $null }

        $verdict = if ($null -eq $healthPercent) { 'Capacity could not be read.' }
                   elseif ($healthPercent -ge 80) { 'Healthy: the battery holds {0}% of its original capacity.' -f $healthPercent }
                   elseif ($healthPercent -ge 60) { 'Worn: the battery holds {0}% of its original capacity. Runtime will be noticeably shorter.' -f $healthPercent }
                   else { 'Badly worn: the battery holds only {0}% of its original capacity and is due for replacement.' -f $healthPercent }

        [pscustomobject]@{
            PSTypeName      = 'PCTools.BatteryReport'
            Name            = [string]$battery.DeviceName
            Manufacturer    = [string]$battery.ManufactureName
            Chemistry       = [string]$battery.Chemistry
            SerialNumber    = [string]$battery.SerialNumber
            DesignCapacity  = $design
            CurrentCapacity = $current
            HealthPercent   = $healthPercent
            ChargeRemaining = if ($status) { [int]$status.EstimatedChargeRemaining } else { $null }
            Verdict         = $verdict
        }
    }
}
