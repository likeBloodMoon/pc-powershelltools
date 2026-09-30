function Test-PCThroughput {
    <#
    .SYNOPSIS
        Measures download throughput against an HTTP endpoint.

    .DESCRIPTION
        The speed test the README has promised since v0.1. Be clear about what
        it measures: a single HTTP stream from one server. That is not the same
        number a multi-stream speed test site reports, and it will usually be
        lower - a single TCP connection is limited by latency and window size in
        a way that eight parallel ones are not.

        What it is good for is the comparison. Run it, change something, run it
        again. A link that manages 3 Mbit/s on a 200 Mbit/s connection has a
        problem worth finding, and that conclusion holds regardless of the
        single-stream caveat.

        Nothing is written to disk: the payload is counted and discarded as it
        arrives.

    .PARAMETER Url
        What to download. Defaults to a Cloudflare test endpoint.

    .PARAMETER Seconds
        How long to measure for.

    .PARAMETER TimeoutSeconds
        Give up if the endpoint does not respond.

    .EXAMPLE
        Test-PCThroughput

    .EXAMPLE
        Test-PCThroughput -Url 'https://speed.hetzner.de/100MB.bin' -Seconds 15

    .OUTPUTS
        PCTools.ThroughputResult
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Url = 'https://speed.cloudflare.com/__down?bytes=104857600',

        [ValidateRange(3, 60)]
        [int]$Seconds = 10,

        [ValidateRange(5, 120)]
        [int]$TimeoutSeconds = 30
    )

    Write-PCLog -Level INFO -Message "Measuring throughput from $Url"

    # TLS 1.2 is not the default on Windows PowerShell 5.1 and every endpoint
    # worth testing against requires it.
    try {
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    catch { }

    $client = $null
    $stream = $null
    $response = $null
    $bytes = 0L
    $stopwatch = $null
    $failure = ''

    try {
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [timespan]::FromSeconds($TimeoutSeconds)

        # ResponseHeadersRead so measurement starts when the first byte lands
        # rather than after the whole body has been buffered.
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
        $responseTask = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)

        if (-not $responseTask.Wait($TimeoutSeconds * 1000)) {
            throw "No response within $TimeoutSeconds seconds."
        }

        $response = $responseTask.Result
        if (-not $response.IsSuccessStatusCode) {
            throw "The server returned $([int]$response.StatusCode) $($response.ReasonPhrase)."
        }

        $streamTask = $response.Content.ReadAsStreamAsync()
        if (-not $streamTask.Wait($TimeoutSeconds * 1000)) {
            throw 'The response body did not start within the timeout.'
        }
        $stream = $streamTask.Result

        $buffer = [byte[]]::new(81920)
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $budget = [timespan]::FromSeconds($Seconds)

        while ($stopwatch.Elapsed -lt $budget) {
            $readTask = $stream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $readTask.Wait($TimeoutSeconds * 1000)) { break }

            $read = $readTask.Result
            if ($read -le 0) { break }
            $bytes += $read
        }

        $stopwatch.Stop()
    }
    catch {
        if ($stopwatch) { $stopwatch.Stop() }
        $failure = $_.Exception.Message
        if ($_.Exception.InnerException) { $failure = $_.Exception.InnerException.Message }
    }
    finally {
        if ($stream) { try { $stream.Dispose() } catch { } }
        if ($response) { try { $response.Dispose() } catch { } }
        if ($client) { try { $client.Dispose() } catch { } }
    }

    $elapsed = if ($stopwatch) { $stopwatch.Elapsed.TotalSeconds } else { 0 }
    $mbps = if ($elapsed -gt 0 -and $bytes -gt 0) { [math]::Round((($bytes * 8) / $elapsed) / 1MB, 2) } else { $null }

    $detail = if ($failure) {
        "Throughput could not be measured: $failure"
    }
    elseif (-not $mbps) {
        'No data was transferred.'
    }
    else {
        'Downloaded {0} in {1:n1} s: {2} Mbit/s on a single stream. A multi-stream speed test will usually report a higher figure.' -f
            (Format-PCByteSize -Bytes $bytes), $elapsed, $mbps
    }

    [pscustomobject]@{
        PSTypeName    = 'PCTools.ThroughputResult'
        Url           = $Url
        Success       = [bool]$mbps
        BytesReceived = $bytes
        BytesDisplay  = Format-PCByteSize -Bytes $bytes
        Seconds       = [math]::Round($elapsed, 2)
        Mbps          = $mbps
        Detail        = $detail
    }
}
