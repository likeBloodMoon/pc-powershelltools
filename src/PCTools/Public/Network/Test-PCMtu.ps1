function Test-PCMtu {
    <#
    .SYNOPSIS
        Finds the largest packet that reaches a host without fragmenting.

    .DESCRIPTION
        New in the module, and the diagnostic for a specific and confusing
        failure: a connection where DNS resolves, small requests succeed, and
        large transfers or HTTPS handshakes hang. That is a path MTU problem,
        usually a PPPoE or VPN link, and no amount of DNS flushing fixes it.

        Binary-searches the payload size with the don't-fragment flag set. The
        reported MTU adds the 28-byte IPv4 and ICMP header overhead back on.

    .PARAMETER Target
        The host to probe.

    .PARAMETER TimeoutSeconds
        Per-probe timeout.

    .EXAMPLE
        Test-PCMtu -Target 1.1.1.1

    .OUTPUTS
        pscustomobject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string]$Target = '1.1.1.1',

        [ValidateRange(1, 30)]
        [int]$TimeoutSeconds = 3
    )

    Write-PCLog -Level INFO -Message "Probing path MTU to $Target"

    # A payload probe is one don't-fragment ping. Probes at different sizes are
    # independent, so a round of them costs one timeout rather than one each -
    # which is what turns an eleven-step serial binary search into two rounds.
    $probeBody = {
        param($PayloadSize, $Destination, $Timeout)

        $ping = [System.Net.NetworkInformation.Ping]::new()
        $options = [System.Net.NetworkInformation.PingOptions]::new(64, $true)

        try {
            $buffer = [byte[]]::new($PayloadSize)
            $reply = $ping.Send($Destination, $Timeout * 1000, $buffer, $options)
            return ($reply.Status -eq 'Success')
        }
        catch {
            return $false
        }
        finally {
            $ping.Dispose()
        }
    }

    $extra = @($Target, $TimeoutSeconds)
    $batchTimeout = [math]::Max(30, $TimeoutSeconds * 4)

    # Deliberately not a closure. GetNewClosure() rebinds a scriptblock to a
    # fresh scope that is no longer attached to the module's session state, so a
    # closure here could not see Invoke-PCParallel - a private module function -
    # and every probe failed with "the term is not recognized". A plain block
    # invoked from this same scope resolves both the helper and the variables
    # below it by ordinary scoping.
    $probeMany = {
        param($Sizes)

        $answers = @{}
        $completed = @(Invoke-PCParallel -InputObject $Sizes -ScriptBlock $probeBody `
            -ArgumentList $extra -ThrottleLimit 8 -TimeoutSeconds $batchTimeout)

        foreach ($item in $completed) {
            $answers[[int]$item.Input] = [bool]$item.Output
        }
        $answers
    }

    # 1472 = 1500 - 28, the largest payload that fits a standard Ethernet MTU.
    # The bracket is probed in one round: it answers "is the path standard",
    # "does it answer ICMP at all", and "roughly where does it break" together.
    $bracket = @(1472, 1400, 1280, 1024, 576, 0)
    $answers = & $probeMany $bracket

    if ($answers[1472]) {
        return [pscustomobject]@{
            PSTypeName  = 'PCTools.MtuProbe'
            Target      = $Target
            PayloadSize = 1472
            Mtu         = 1500
            Standard    = $true
            Detail      = 'Full 1500-byte MTU path; no fragmentation issue.'
        }
    }

    if (-not $answers[0]) {
        return [pscustomobject]@{
            PSTypeName  = 'PCTools.MtuProbe'
            Target      = $Target
            PayloadSize = $null
            Mtu         = $null
            Standard    = $false
            Detail      = "$Target does not answer ICMP at all, so the MTU cannot be probed this way."
        }
    }

    # Narrow to the pair the bracket straddles, then binary-search inside it.
    # Sorted ascending, $low is the largest size that got through and $high the
    # smallest that did not.
    $sorted = $bracket | Sort-Object
    $low = 0
    $high = 1472

    foreach ($size in $sorted) {
        if ($answers[$size]) { $low = $size }
        else { $high = $size; break }
    }

    while ($high - $low -gt 1) {
        # Three probes per round instead of one: the search space shrinks by a
        # factor of four per round for the same wall-clock cost as one probe.
        $step = [int](($high - $low) / 4)
        if ($step -lt 1) { $step = 1 }

        $candidates = @()
        foreach ($multiplier in 1, 2, 3) {
            $candidate = $low + ($step * $multiplier)
            if ($candidate -gt $low -and $candidate -lt $high -and $candidates -notcontains $candidate) {
                $candidates += $candidate
            }
        }

        if ($candidates.Count -eq 0) { break }

        $round = & $probeMany $candidates

        $movedLow = $low
        $movedHigh = $high
        foreach ($candidate in ($candidates | Sort-Object)) {
            if ($round[$candidate]) { $movedLow = $candidate }
            elseif ($movedHigh -eq $high -or $candidate -lt $movedHigh) { $movedHigh = $candidate; break }
        }

        if ($movedLow -eq $low -and $movedHigh -eq $high) { break }
        $low = $movedLow
        $high = $movedHigh
    }

    $mtu = $low + 28

    [pscustomobject]@{
        PSTypeName  = 'PCTools.MtuProbe'
        Target      = $Target
        PayloadSize = $low
        Mtu         = $mtu
        Standard    = $false
        Detail      = "Path MTU is $mtu, below the standard 1500. Large transfers and TLS handshakes can stall on a path like this; a PPPoE or VPN link is the usual cause."
    }
}
