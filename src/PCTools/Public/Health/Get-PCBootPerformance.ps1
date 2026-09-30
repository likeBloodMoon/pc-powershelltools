function Get-PCBootPerformance {
    <#
    .SYNOPSIS
        How long this machine takes to start, and what is slowing it down.

    .DESCRIPTION
        Windows measures its own boot and writes the result to
        Microsoft-Windows-Diagnostics-Performance/Operational. Event 100 carries
        the total boot time and its breakdown; events 101 to 110 name the
        specific application, service or driver that degraded it and by how many
        milliseconds.

        That second part is the useful bit and almost nobody knows it exists. It
        turns "my PC is slow to start" into "this updater costs you 9 seconds
        every boot", which is a decision somebody can act on with
        Disable-PCStartupItem.

        The log is disabled on some systems and on Windows Server; there the
        result is empty rather than an error.

    .PARAMETER Last
        How many boots to report.

    .EXAMPLE
        Get-PCBootPerformance | Format-List

    .EXAMPLE
        (Get-PCBootPerformance).Degradations | Format-Table Name, Type, PenaltyMs

    .OUTPUTS
        PCTools.BootPerformance
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 50)]
        [int]$Last = 10
    )

    $logName = 'Microsoft-Windows-Diagnostics-Performance/Operational'

    $bootEvents = @()
    try {
        $bootEvents = @(Get-WinEvent -FilterHashtable @{ LogName = $logName; Id = 100 } -MaxEvents $Last -ErrorAction Stop)
    }
    catch {
        Write-PCLog -Level DEBUG -Message "Boot performance log unavailable: $($_.Exception.Message)"
        return [pscustomobject]@{
            PSTypeName    = 'PCTools.BootPerformance'
            Available     = $false
            Boots         = @()
            AverageMs     = $null
            LastMs        = $null
            Degradations  = @()
            Verdict       = 'Windows boot performance logging is not available on this machine, so boot time cannot be measured.'
        }
    }

    $boots = @($bootEvents | ForEach-Object {
        # The interesting numbers live in the event's named XML properties
        # rather than the rendered message, which is localised prose.
        $xml = $null
        try { $xml = ([xml]$_.ToXml()).Event.EventData.Data } catch { }

        $value = {
            param($DataName)
            if (-not $xml) { return $null }
            $node = $xml | Where-Object { $_.Name -eq $DataName }
            if ($node) { [long]$node.'#text' } else { $null }
        }

        [pscustomobject]@{
            PSTypeName   = 'PCTools.BootRecord'
            Time         = $_.TimeCreated
            TotalMs      = & $value 'BootTime'
            MainPathMs   = & $value 'MainPathBootTime'
            PostBootMs   = & $value 'BootPostBootTime'
            DegradationMs = & $value 'BootDegradationTime'
        }
    })

    $degradations = @()
    try {
        # 101 application, 102 driver, 103 service, 106 background, 109 device.
        foreach ($event in @(Get-WinEvent -FilterHashtable @{
            LogName = $logName
            Id      = 101, 102, 103, 106, 109
        } -MaxEvents 100 -ErrorAction Stop)) {

            $xml = $null
            try { $xml = ([xml]$event.ToXml()).Event.EventData.Data } catch { continue }
            if (-not $xml) { continue }

            $named = @{}
            foreach ($node in $xml) { $named[$node.Name] = $node.'#text' }

            $penalty = 0
            foreach ($key in 'TotalTime', 'Time', 'DegradationTime') {
                if ($named.ContainsKey($key) -and $named[$key]) { $penalty = [long]$named[$key]; break }
            }
            if ($penalty -le 0) { continue }

            $name = ''
            foreach ($key in 'Name', 'FriendlyName', 'FileName', 'ServiceName') {
                if ($named.ContainsKey($key) -and $named[$key]) { $name = [string]$named[$key]; break }
            }
            if (-not $name) { continue }

            $degradations += [pscustomobject]@{
                PSTypeName = 'PCTools.BootDegradation'
                Name       = $name
                Type       = switch ($event.Id) {
                    101 { 'Application' }
                    102 { 'Driver' }
                    103 { 'Service' }
                    106 { 'Background task' }
                    109 { 'Device' }
                    default { 'Other' }
                }
                PenaltyMs  = $penalty
                Time       = $event.TimeCreated
            }
        }
    }
    catch {
        Write-PCLog -Level DEBUG -Message "Could not read boot degradation events: $($_.Exception.Message)"
    }

    # The same offender appears once per boot; report its worst showing.
    $worst = @($degradations |
        Group-Object Name |
        ForEach-Object { $_.Group | Sort-Object PenaltyMs -Descending | Select-Object -First 1 } |
        Sort-Object PenaltyMs -Descending |
        Select-Object -First 15)

    $measured = @($boots | Where-Object { $_.TotalMs })
    $average = if ($measured.Count -gt 0) { [int](($measured.TotalMs | Measure-Object -Average).Average) } else { $null }
    $last = if ($measured.Count -gt 0) { [int]$measured[0].TotalMs } else { $null }

    $verdict = if (-not $average) {
        'No completed boot measurements are recorded yet.'
    }
    elseif ($average -gt 90000) {
        'Boot takes {0:n1} seconds on average, which is very slow.' -f ($average / 1000)
    }
    elseif ($average -gt 45000) {
        'Boot takes {0:n1} seconds on average, which is slower than it should be.' -f ($average / 1000)
    }
    else {
        'Boot takes {0:n1} seconds on average.' -f ($average / 1000)
    }

    if ($worst.Count -gt 0) {
        $verdict += ' The largest single cost is {0} at {1:n1} seconds.' -f $worst[0].Name, ($worst[0].PenaltyMs / 1000)
    }

    [pscustomobject]@{
        PSTypeName   = 'PCTools.BootPerformance'
        Available    = $true
        Boots        = $boots
        AverageMs    = $average
        LastMs       = $last
        Degradations = $worst
        Verdict      = $verdict
    }
}
