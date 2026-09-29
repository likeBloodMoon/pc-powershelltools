function Test-PCRoute {
    <#
    .SYNOPSIS
        Traces the path to a host, reporting per-hop latency.

    .DESCRIPTION
        New in the module. Net Diag could tell you the internet was unreachable
        but not where it stopped being reachable, which is the question that
        distinguishes "my router" from "my ISP".

        Implemented over System.Net.NetworkInformation.Ping with an increasing
        TTL rather than by shelling out to tracert.exe, so each hop honours the
        timeout and the results come back as objects.

    .PARAMETER Target
        The host or address to trace to.

    .PARAMETER MaxHops
        Stop after this many hops.

    .PARAMETER TimeoutSeconds
        Per-hop timeout.

    .EXAMPLE
        Test-PCRoute -Target 1.1.1.1 | Format-Table Hop, Address, LatencyMs, Status

    .OUTPUTS
        pscustomobject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string]$Target = '1.1.1.1',

        [ValidateRange(1, 64)]
        [int]$MaxHops = 20,

        [ValidateRange(1, 30)]
        [int]$TimeoutSeconds = 3
    )

    Write-PCLog -Level INFO -Message "Tracing route to $Target"

    # Every TTL is an independent probe, so send them all at once and sort the
    # replies afterwards. Serially this walked up to MaxHops timeouts one after
    # another - twenty hops at three seconds each is a minute of waiting to be
    # told the third hop is where it stops. This is what tracert itself does.
    $hopBody = {
        param($Ttl, $Destination, $Timeout)

        $ping = [System.Net.NetworkInformation.Ping]::new()
        $buffer = [byte[]]::new(32)
        $options = [System.Net.NetworkInformation.PingOptions]::new($Ttl, $true)

        try {
            $reply = $ping.Send($Destination, $Timeout * 1000, $buffer, $options)

            $address = '*'
            if ($reply.Address) { $address = $reply.Address.ToString() }

            $latency = $null
            if ($reply.Status -eq 'Success' -or $reply.Status -eq 'TtlExpired') {
                $latency = $reply.RoundtripTime
            }

            @{ Address = $address; LatencyMs = $latency; Status = $reply.Status.ToString() }
        }
        catch {
            @{ Address = '*'; LatencyMs = $null; Status = 'Error' }
        }
        finally {
            $ping.Dispose()
        }
    }

    $completed = @(Invoke-PCParallel -InputObject (1..$MaxHops) -ScriptBlock $hopBody `
        -ArgumentList @($Target, $TimeoutSeconds) `
        -ThrottleLimit ([math]::Min(16, $MaxHops)) `
        -TimeoutSeconds ([math]::Max(30, $TimeoutSeconds * 4)))

    $byTtl = @{}
    foreach ($item in $completed) {
        if ($item.Output) { $byTtl[[int]$item.Input] = $item.Output }
    }

    for ($ttl = 1; $ttl -le $MaxHops; $ttl++) {
        $hop = $null
        if ($byTtl.ContainsKey($ttl)) { $hop = $byTtl[$ttl] }

        if (-not $hop) {
            $hop = @{ Address = '*'; LatencyMs = $null; Status = 'Unknown' }
        }

        [pscustomobject]@{
            PSTypeName = 'PCTools.RouteHop'
            Hop        = $ttl
            Address    = $hop.Address
            LatencyMs  = $hop.LatencyMs
            Status     = $hop.Status
        }

        # Reaching the destination ends the trace; every TTL beyond it was
        # probed too, and reporting those would be noise.
        if ($hop.Status -eq 'Success') { break }
    }
}
