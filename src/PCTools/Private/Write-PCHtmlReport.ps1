function Write-PCHtmlReport {
    <#
    .SYNOPSIS
        Renders a report as a single self-contained HTML file.

    .DESCRIPTION
        The format to send somebody. Everything is inline - no stylesheet, no
        webfont, no script - so the file renders identically on a machine with
        no network, survives being emailed, and cannot phone anywhere.

        ConvertTo-Html is deliberately not used. It produces a table per object
        type with no styling and no summary, which is a worse artifact than the
        plain text export it would be replacing.

        Every value is HTML-escaped on the way in. Action detail strings carry
        file paths and error messages from the system, and one containing a
        stray angle bracket must not be able to break the document.

    .PARAMETER Payload
        The report payload assembled by Export-PCReport.

    .PARAMETER ActionResult
        The action results within it, already filtered.

    .PARAMETER Path
        Where to write the file.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        $Payload,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$ActionResult,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $escape = {
        param($Value)
        if ($null -eq $Value) { return '' }
        [System.Net.WebUtility]::HtmlEncode([string]$Value)
    }

    $summary = Get-PCResultSummary -Result $ActionResult

    $html = [System.Text.StringBuilder]::new()

    [void]$html.AppendLine('<!DOCTYPE html>')
    [void]$html.AppendLine('<html lang="en"><head><meta charset="utf-8">')
    [void]$html.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$html.AppendLine("<title>PC Tools report - $(& $escape $Payload.ComputerName)</title>")

    # Colours are defined for both schemes so the file reads correctly whether
    # the recipient's browser is in light or dark mode.
    [void]$html.AppendLine(@'
<style>
:root {
  --bg: #f6f7f9; --card: #ffffff; --text: #1c1c22; --muted: #5f606c;
  --border: #d9dbe2; --ok: #1c8a44; --warn: #a87610; --bad: #be3a3a; --accent: #1c6ac8;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #131316; --card: #1c1c21; --text: #e6e6eb; --muted: #9e9eaa;
    --border: #34343e; --ok: #58be78; --warn: #e2b24e; --bad: #e06c6c; --accent: #4084d6;
  }
}
* { box-sizing: border-box; }
body { margin: 0; padding: 32px 20px; background: var(--bg); color: var(--text);
       font: 14px/1.55 "Segoe UI", -apple-system, system-ui, sans-serif; }
.wrap { max-width: 1000px; margin: 0 auto; }
h1 { font-size: 22px; margin: 0 0 4px; }
h2 { font-size: 15px; margin: 28px 0 10px; text-transform: uppercase;
     letter-spacing: .07em; color: var(--muted); }
.sub { color: var(--muted); margin: 0 0 24px; }
.card { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
        padding: 18px 20px; margin-bottom: 16px; }
.summary { font-size: 17px; font-weight: 600; }
.meta { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 10px 24px; }
.meta div { display: flex; justify-content: space-between; gap: 12px;
            border-bottom: 1px solid var(--border); padding-bottom: 6px; }
.meta span:first-child { color: var(--muted); }
.scroll { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 13px; }
th, td { text-align: left; padding: 9px 12px; border-bottom: 1px solid var(--border);
         vertical-align: top; }
th { color: var(--muted); font-weight: 600; white-space: nowrap; }
td.num { text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
.pill { display: inline-block; padding: 1px 9px; border-radius: 999px; font-size: 12px;
        font-weight: 600; border: 1px solid currentColor; }
.Success { color: var(--ok); } .Warning { color: var(--warn); }
.Failed { color: var(--bad); } .Skipped { color: var(--muted); }
pre { background: var(--bg); border: 1px solid var(--border); border-radius: 8px;
      padding: 12px; overflow-x: auto; font-size: 12px; margin: 0; }
footer { color: var(--muted); font-size: 12px; margin-top: 28px;
         border-top: 1px solid var(--border); padding-top: 14px; }
</style></head><body><div class="wrap">
'@)

    [void]$html.AppendLine('<h1>PC Tools report</h1>')
    [void]$html.AppendLine("<p class=""sub"">$(& $escape $Payload.ComputerName) &middot; $(& $escape $Payload.Generated)</p>")

    if ($ActionResult.Count -gt 0) {
        [void]$html.AppendLine("<div class=""card""><div class=""summary"">$(& $escape $summary.Text)</div></div>")
    }

    [void]$html.AppendLine('<h2>Machine</h2><div class="card"><div class="meta">')
    foreach ($pair in @(
        @{ Label = 'Computer';  Value = $Payload.ComputerName }
        @{ Label = 'User';      Value = $Payload.User }
        @{ Label = 'Elevated';  Value = $Payload.IsAdmin }
        @{ Label = 'Generated'; Value = $Payload.Generated }
        @{ Label = 'PC Tools';  Value = $Payload.Version }
    )) {
        [void]$html.AppendLine("<div><span>$(& $escape $pair.Label)</span><span>$(& $escape $pair.Value)</span></div>")
    }
    [void]$html.AppendLine('</div></div>')

    if ($ActionResult.Count -gt 0) {
        [void]$html.AppendLine('<h2>Actions</h2><div class="card scroll"><table>')
        [void]$html.AppendLine('<thead><tr><th>Status</th><th>Action</th><th>Reclaimed</th><th>Took</th><th>Detail</th></tr></thead><tbody>')

        foreach ($result in $ActionResult) {
            $status = & $escape $result.Status
            $freed = if ($result.BytesFreed -gt 0) { & $escape $result.FreedDisplay } else { '' }
            $took = if ($result.Duration) { '{0:n1}s' -f $result.Duration.TotalSeconds } else { '' }

            # The whole -f expression needs its own parentheses. Inside a method
            # call, commas separate method arguments, so without them the format
            # operator receives only its first value and everything after it is
            # passed to AppendLine as extra arguments.
            $row = (
                ('<tr><td><span class="pill {0}">{0}</span></td><td>{1}</td>' +
                 '<td class="num">{2}</td><td class="num">{3}</td><td>{4}</td></tr>') -f
                $status, (& $escape $result.Action), $freed, (& $escape $took), (& $escape $result.Detail)
            )
            [void]$html.AppendLine($row)
        }

        [void]$html.AppendLine('</tbody></table></div>')
    }

    foreach ($report in @($Payload.Items | Where-Object { $_.PSObject.TypeNames -contains 'PCTools.NetworkReport' })) {
        [void]$html.AppendLine('<h2>Network</h2><div class="card">')
        [void]$html.AppendLine("<div class=""summary"">$(& $escape $report.Verdict.Verdict)</div>")
        [void]$html.AppendLine("<p class=""sub"" style=""margin:6px 0 0"">$(& $escape $report.Verdict.Advice)</p></div>")

        [void]$html.AppendLine('<div class="card scroll"><table>')
        [void]$html.AppendLine('<thead><tr><th>Layer</th><th>Target</th><th>Result</th><th>Latency</th><th>Detail</th></tr></thead><tbody>')

        foreach ($test in @($report.Tests)) {
            $state = if ($test.Success) { 'Success' } else { 'Failed' }
            $label = if ($test.Success) { 'OK' } else { 'Fail' }
            $latency = if ($null -ne $test.LatencyMs) { '{0} ms' -f $test.LatencyMs } else { '' }

            $row = (
                ('<tr><td>{0}</td><td>{1}</td><td><span class="pill {2}">{3}</span></td>' +
                 '<td class="num">{4}</td><td>{5}</td></tr>') -f
                (& $escape $test.Layer), (& $escape $test.Target), $state, $label,
                (& $escape $latency), (& $escape $test.Detail)
            )
            [void]$html.AppendLine($row)
        }

        [void]$html.AppendLine('</tbody></table></div>')

        if ($report.Full) {
            foreach ($property in $report.Full.PSObject.Properties) {
                [void]$html.AppendLine("<h2>$(& $escape $property.Name)</h2>")
                [void]$html.AppendLine("<div class=""card""><pre>$(& $escape $property.Value)</pre></div>")
            }
        }
    }

    [void]$html.AppendLine('<footer>Generated by PC Tools. No data left this machine to produce this file.</footer>')
    [void]$html.AppendLine('</div></body></html>')

    Set-Content -LiteralPath $Path -Value $html.ToString() -Encoding UTF8
}
