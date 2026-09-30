function Test-PCDnsServer {
    <#
    .SYNOPSIS
        Benchmarks DNS resolvers and says which one to use.

    .DESCRIPTION
        DNS latency is paid on nearly every request and is invisible until
        somebody measures it. A router forwarding to an overloaded ISP resolver
        can add 80 ms to the start of every connection, which reads to the user
        as "the internet is slow" and shows up in no speed test.

        Each candidate resolver is queried for several names and the median
        response time reported. Median rather than mean on purpose: one 2-second
        timeout would dominate an average and misrepresent an otherwise fine
        resolver.

        The currently configured resolver is included in the comparison, since
        the only question worth answering is whether changing would help.

    .PARAMETER Server
        Resolvers to test. Defaults to the configured one plus Cloudflare,
        Google and Quad9.

    .PARAMETER Name
        Names to resolve for the measurement.

    .PARAMETER TimeoutSeconds
        Per-query timeout.

    .EXAMPLE
        Test-PCDnsServer | Format-Table Server, Provider, MedianMs, Success, Recommendation

    .OUTPUTS
        PCTools.DnsBenchmark
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]]$Server,

        [string[]]$Name = @('www.microsoft.com', 'www.wikipedia.org', 'www.github.com', 'www.bbc.co.uk'),

        [ValidateRange(1, 30)]
        [int]$TimeoutSeconds = 3
    )

    $providers = @{
        '1.1.1.1'         = 'Cloudflare'
        '1.0.0.1'         = 'Cloudflare'
        '8.8.8.8'         = 'Google'
        '8.8.4.4'         = 'Google'
        '9.9.9.9'         = 'Quad9'
        '149.112.112.112' = 'Quad9'
        '208.67.222.222'  = 'OpenDNS'
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    $configured = @()

    if ($Server) {
        foreach ($item in $Server) { $candidates.Add($item) }
    }
    else {
        # Whatever this machine is actually using, so the comparison answers
        # "would changing help" rather than just ranking public resolvers.
        try {
            $configured = @(Get-PCNetworkAdapter -ConnectedOnly |
                Where-Object DnsServers |
                ForEach-Object { $_.DnsServers -split ',' } |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and $_ -notmatch ':' } |
                Select-Object -Unique)
        }
        catch { }

        foreach ($item in $configured) { $candidates.Add($item) }
        foreach ($item in '1.1.1.1', '8.8.8.8', '9.9.9.9') {
            if ($candidates -notcontains $item) { $candidates.Add($item) }
        }
    }

    if ($candidates.Count -eq 0) {
        Write-PCLog -Level WARN -Message 'No DNS servers to test.'
        return
    }

    Write-PCLog -Level INFO -Message "Benchmarking $($candidates.Count) DNS server(s)"

    $benchBody = {
        param($DnsServer, $Names, $Timeout)

        $latencies = [System.Collections.Generic.List[double]]::new()
        $failures = 0

        foreach ($target in $Names) {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                # -DnsOnly and -NoHostsFile keep the cache and the hosts file
                # out of the measurement; without them a warm cache reports
                # sub-millisecond times for every server equally.
                $answer = Resolve-DnsName -Name $target -Server $DnsServer -Type A `
                    -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop
                $watch.Stop()

                if ($answer) { $latencies.Add($watch.Elapsed.TotalMilliseconds) }
                else { $failures++ }
            }
            catch {
                $watch.Stop()
                $failures++
            }
        }

        @{
            Latencies = $latencies.ToArray()
            Failures  = $failures
        }
    }

    $completed = @(Invoke-PCParallel -InputObject $candidates.ToArray() -ScriptBlock $benchBody `
        -ArgumentList @($Name, $TimeoutSeconds) -ThrottleLimit 6 `
        -TimeoutSeconds ([math]::Max(30, $TimeoutSeconds * $Name.Count + 10)))

    $results = foreach ($item in $completed) {
        $dnsServer = [string]$item.Input
        $outcome = $item.Output

        $latencies = @()
        $failures = $Name.Count
        if ($outcome) {
            $latencies = @($outcome.Latencies)
            $failures = [int]$outcome.Failures
        }

        $median = $null
        if ($latencies.Count -gt 0) {
            $sorted = @($latencies | Sort-Object)
            $median = if ($sorted.Count % 2 -eq 1) {
                $sorted[[int]([math]::Floor($sorted.Count / 2))]
            }
            else {
                ($sorted[($sorted.Count / 2) - 1] + $sorted[$sorted.Count / 2]) / 2
            }
            $median = [math]::Round($median, 1)
        }

        [pscustomobject]@{
            PSTypeName = 'PCTools.DnsBenchmark'
            Server     = $dnsServer
            Provider   = if ($providers.ContainsKey($dnsServer)) { $providers[$dnsServer] }
                         elseif ($configured -contains $dnsServer) { 'Currently configured' }
                         else { 'Unknown' }
            InUse      = $configured -contains $dnsServer
            Success    = $latencies.Count
            Failures   = $failures
            MedianMs   = $median
        }
    }

    $ranked = @($results | Where-Object { $null -ne $_.MedianMs } | Sort-Object MedianMs)
    $best = $ranked | Select-Object -First 1
    $current = $ranked | Where-Object InUse | Select-Object -First 1

    foreach ($result in $results) {
        $recommendation = if (-not $best) { '' }
            elseif ($result.Server -eq $best.Server -and $current -and $current.Server -eq $best.Server) {
                'Fastest, and already in use.'
            }
            elseif ($result.Server -eq $best.Server -and $current) {
                'Fastest. {0:n0} ms faster than the configured resolver: Set-PCDnsServer -Name <adapter> -Server {1}' -f
                    ($current.MedianMs - $best.MedianMs), $result.Server
            }
            elseif ($result.Server -eq $best.Server) {
                'Fastest of those tested.'
            }
            else { '' }

        $result | Add-Member -NotePropertyName Recommendation -NotePropertyValue $recommendation -PassThru
    }
}
