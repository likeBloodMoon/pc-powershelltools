function Test-PCConnectivity {
    <#
    .SYNOPSIS
        Runs layered connectivity tests: gateway, internet, DNS and TCP.

    .DESCRIPTION
        Consolidates Net Diag's Test-Ping, Test-DnsResolve and Test-TcpPort into
        one graded check, and orders the results so the first failure identifies
        the layer at fault: adapter, then gateway, then internet routing, then
        DNS resolution, then TCP reachability.

        That ordering is the whole point. "The internet is down" and "DNS is
        broken" produce very different first failures, and the original printed
        the results in whatever order the tests were written.

        The probes run concurrently and are then sorted back into layer order.
        Ordering the *output* is the diagnostic value; ordering the *execution*
        only ever cost time, and on a broken network it cost the most - nine
        probes each waiting out its own timeout, one after another. The wall
        clock is now the slowest single probe rather than the sum.

    .PARAMETER DnsName
        Names to resolve. Defaults to two well-known hosts.

    .PARAMETER TimeoutSeconds
        Per-test timeout.

    .EXAMPLE
        Test-PCConnectivity | Format-Table Layer, Target, Success, Detail

    .OUTPUTS
        pscustomobject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]]$DnsName = @('www.google.com', 'www.cloudflare.com'),

        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 5
    )

    $emit = {
        param($Layer, $Target, $Success, $Detail, $LatencyMs)
        [pscustomobject]@{
            PSTypeName = 'PCTools.ConnectivityTest'
            Layer      = $Layer
            Target     = $Target
            Success    = [bool]$Success
            Detail     = $Detail
            LatencyMs  = $LatencyMs
        }
    }

    # 1. Adapter. This one is not a probe and it decides what the gateway probe
    # aims at, so it stays sequential and first.
    $connected = @(Get-PCNetworkAdapter -ConnectedOnly)
    & $emit 'Adapter' 'Local adapters' ($connected.Count -gt 0) `
        $(if ($connected.Count -gt 0) { "$($connected.Count) adapter(s) up: $(($connected.Name) -join ', ')" }
          else { 'No adapter is up' }) $null

    $gateway = ($connected | Where-Object Gateway | Select-Object -First 1).Gateway
    if ($gateway) { $gateway = ($gateway -split ',')[0].Trim() }

    # Everything below is independent, so describe the probes as data and run
    # the lot at once. Layer is carried on each descriptor and used to restore
    # the diagnostic ordering afterwards.
    $probes = [System.Collections.Generic.List[object]]::new()

    if ($gateway) {
        $probes.Add(@{ Layer = 'Gateway'; Kind = 'Ping'; Target = $gateway })
    }

    # Internet routing is probed by IP so DNS cannot mask a routing failure.
    foreach ($target in @('1.1.1.1', '8.8.8.8')) {
        $probes.Add(@{ Layer = 'Internet'; Kind = 'Ping'; Target = $target })
    }

    foreach ($name in $DnsName) {
        $probes.Add(@{ Layer = 'DNS'; Kind = 'Dns'; Target = $name })
    }

    foreach ($endpoint in @(@{ Host = 'www.google.com'; Port = 443 }, @{ Host = '1.1.1.1'; Port = 53 })) {
        $probes.Add(@{ Layer = 'TCP'; Kind = 'Tcp'; Target = $endpoint.Host; Port = $endpoint.Port })
    }

    # The probe helpers travel into the runspaces as source rather than being
    # reimplemented here, so there is still exactly one ping implementation.
    $init = Get-PCFunctionSource -Name 'Test-PCPing', 'Test-PCTcpPort'

    $probeBody = {
        param($Probe, $Timeout)

        switch ($Probe.Kind) {
            'Ping' {
                $reply = Test-PCPing -Target $Probe.Target -TimeoutSeconds $Timeout
                @{ Success = $reply.Success; Detail = $reply.Detail; LatencyMs = $reply.LatencyMs }
            }
            'Tcp' {
                $result = Test-PCTcpPort -TargetHost $Probe.Target -Port $Probe.Port -TimeoutSeconds $Timeout
                @{ Success = $result.Success; Detail = $result.Detail; LatencyMs = $result.LatencyMs }
            }
            'Dns' {
                $resolved = $null
                try {
                    $records = Resolve-DnsName -Name $Probe.Target -Type A -DnsOnly -ErrorAction Stop |
                        Where-Object { $_.IPAddress }
                    $resolved = ($records.IPAddress) -join ', '
                }
                catch {
                    # Resolve-DnsName is Windows-only and can fail for reasons
                    # unrelated to DNS being broken. The framework resolver is
                    # the second opinion before calling resolution failed.
                    try {
                        $resolved = ([System.Net.Dns]::GetHostAddresses($Probe.Target) |
                            Where-Object AddressFamily -eq 'InterNetwork' |
                            ForEach-Object IPAddressToString) -join ', '
                    }
                    catch { $resolved = $null }
                }

                @{
                    Success   = [bool]$resolved
                    Detail    = if ($resolved) { "Resolved to $resolved" } else { 'Resolution failed' }
                    LatencyMs = $null
                }
            }
        }
    }

    # One timeout for the batch, with headroom: the probes overlap, so the batch
    # cannot legitimately need more than a single probe's budget plus startup.
    $batchTimeout = [math]::Max(30, $TimeoutSeconds * 4)

    $completed = @(Invoke-PCParallel -InputObject $probes.ToArray() -ScriptBlock $probeBody `
        -ArgumentList @($TimeoutSeconds) -InitScript $init `
        -ThrottleLimit 8 -TimeoutSeconds $batchTimeout)

    $byIndex = @{}
    foreach ($item in $completed) { $byIndex[$item.Index] = $item }

    # Emit in layer order - the whole diagnostic depends on it.
    $layerOrder = 'Gateway', 'Internet', 'DNS', 'TCP'

    foreach ($layer in $layerOrder) {
        # A missing gateway is a finding, and it belongs in the Gateway
        # position rather than tacked on after the TCP rows.
        if ($layer -eq 'Gateway' -and -not $gateway) {
            & $emit 'Gateway' '(none)' $false 'No default gateway is configured' $null
            continue
        }

        for ($i = 0; $i -lt $probes.Count; $i++) {
            $probe = $probes[$i]
            if ($probe.Layer -ne $layer) { continue }

            $label = if ($probe.Kind -eq 'Tcp') { "$($probe.Target):$($probe.Port)" } else { $probe.Target }

            $outcome = $null
            if ($byIndex.ContainsKey($i)) { $outcome = $byIndex[$i].Output }

            if (-not $outcome) {
                $reason = if ($byIndex.ContainsKey($i) -and $byIndex[$i].Error) { $byIndex[$i].Error } else { 'no result' }
                & $emit $layer $label $false "Probe did not complete ($reason)" $null
                continue
            }

            & $emit $layer $label $outcome.Success $outcome.Detail $outcome.LatencyMs
        }
    }
}
