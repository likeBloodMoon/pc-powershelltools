function Export-PCReport {
    <#
    .SYNOPSIS
        Writes action results or a network report to disk as HTML, JSON, text or
        CSV.

    .DESCRIPTION
        Generalises Net Diag's Save-Report so every tool in the project can
        export, not just the network one - the roadmap's "export logs to file"
        item.

        Four formats, because the audiences differ. HTML is the one to send
        somebody - a single self-contained file with no external stylesheet, no
        fonts and no scripts, so it renders the same on a machine with no
        network as on one with. JSON is for machines and for attaching to a
        ticket. Text is for reading in Notepad. CSV is for a spreadsheet.

        By default JSON and text are written, which is what this command has
        always done; -Format selects otherwise.

    .PARAMETER InputObject
        PCTools.ActionResult objects, or a PCTools.NetworkReport.

    .PARAMETER Path
        The output folder. Defaults to the desktop.

    .PARAMETER BaseName
        The file name stem. A timestamp is always appended.

    .PARAMETER Format
        Which formats to write: Html, Json, Text, Csv. Defaults to Json and
        Text.

    .EXAMPLE
        Invoke-PCMaintenance -ProfileName Quick | Export-PCReport

    .EXAMPLE
        Get-PCNetworkReport -Full | Export-PCReport -Path C:\Temp

    .EXAMPLE
        Invoke-PCMaintenance -ProfileName Full | Export-PCReport -Format Html

    .OUTPUTS
        pscustomobject naming each file written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$InputObject,

        [string]$Path,

        [string]$BaseName = 'pctools-report',

        [ValidateSet('Html', 'Json', 'Text', 'Csv')]
        [string[]]$Format = @('Json', 'Text')
    )

    begin {
        $collected = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $InputObject) { $collected.Add($item) }
    }

    end {
        if ($collected.Count -eq 0) {
            Write-PCLog -Level WARN -Message 'Export-PCReport: nothing to export.'
            return
        }

        if (-not $Path) {
            $Path = [Environment]::GetFolderPath('Desktop')
            if (-not $Path) { $Path = $script:PCDataRoot }
        }
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $jsonPath = Join-Path $Path "$BaseName-$stamp.json"
        $textPath = Join-Path $Path "$BaseName-$stamp.txt"
        $htmlPath = Join-Path $Path "$BaseName-$stamp.html"
        $csvPath  = Join-Path $Path "$BaseName-$stamp.csv"

        $extensions = ($Format | ForEach-Object { $_.ToLowerInvariant() }) -join '|'
        if (-not $PSCmdlet.ShouldProcess($Path, "Write report as $BaseName-$stamp.[$extensions]")) {
            return
        }

        $payload = [pscustomobject]@{
            Tool         = $script:ModuleName
            Version      = $script:ModuleVersion
            ComputerName = $env:COMPUTERNAME
            User         = "$env:USERDOMAIN\$env:USERNAME"
            IsAdmin      = Test-PCAdmin
            Generated    = Get-Date
            Items        = @($collected)
        }

        if ($Format -contains 'Json') {
            # ErrorRecord does not serialise usefully and can be enormous.
            $payload | ConvertTo-Json -Depth 8 -WarningAction SilentlyContinue |
                Set-Content -LiteralPath $jsonPath -Encoding UTF8
        }

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("$($script:ModuleName) report")
        $lines.Add(('=' * 60))
        $lines.Add("Computer : $($payload.ComputerName)")
        $lines.Add("User     : $($payload.User)")
        $lines.Add("Elevated : $($payload.IsAdmin)")
        $lines.Add("Generated: $($payload.Generated)")
        $lines.Add('')

        $actionResults = @($collected | Where-Object { $_.PSObject.TypeNames -contains 'PCTools.ActionResult' })
        if ($actionResults.Count -gt 0) {
            $lines.Add('Actions')
            $lines.Add(('-' * 60))
            foreach ($result in $actionResults) {
                $lines.Add(('{0,-9} {1,-28} {2}' -f $result.Status, $result.Action, $result.Detail))
            }

            # Guarded for the same reason as Get-PCResultSummary: Measure-Object
            # returns nothing for an empty set, and .Sum on nothing throws under
            # strict mode.
            $totalFreed = 0L
            $measuredTotal = $actionResults | Measure-Object -Property BytesFreed -Sum
            if ($measuredTotal -and $null -ne $measuredTotal.Sum) { $totalFreed = [long]$measuredTotal.Sum }
            $lines.Add('')
            $lines.Add(('Summary: {0} action(s), {1} succeeded, {2} failed, {3} reclaimed' -f
                $actionResults.Count,
                @($actionResults | Where-Object Status -eq 'Success').Count,
                @($actionResults | Where-Object Status -eq 'Failed').Count,
                (Format-PCByteSize -Bytes $totalFreed)))
            if (@($actionResults | Where-Object RebootRequired).Count -gt 0) {
                $lines.Add('A restart is required to complete one or more actions.')
            }
            $lines.Add('')
        }

        foreach ($report in @($collected | Where-Object { $_.PSObject.TypeNames -contains 'PCTools.NetworkReport' })) {
            $lines.Add('Network report')
            $lines.Add(('-' * 60))
            $lines.Add("Verdict: $($report.Verdict.Verdict)")
            $lines.Add("Advice : $($report.Verdict.Advice)")
            $lines.Add('')
            $lines.Add('Adapters')
            $lines.Add(($report.Adapters | Format-Table -AutoSize | Out-String).TrimEnd())
            $lines.Add('')
            $lines.Add('Connectivity tests')
            $lines.Add(($report.Tests | Format-Table -AutoSize Layer, Target, Success, LatencyMs, Detail | Out-String).TrimEnd())
            $lines.Add('')
            $lines.Add('Routes')
            $lines.Add(($report.Routes | Format-Table -AutoSize | Out-String).TrimEnd())

            if ($report.Full) {
                foreach ($property in $report.Full.PSObject.Properties) {
                    $lines.Add('')
                    $lines.Add($property.Name)
                    $lines.Add(('-' * $property.Name.Length))
                    $lines.Add(($property.Value | Out-String).TrimEnd())
                }
            }
        }

        if ($Format -contains 'Text') {
            $lines | Set-Content -LiteralPath $textPath -Encoding UTF8
        }

        if ($Format -contains 'Csv') {
            # One flat row per action. A network report has no natural tabular
            # shape, so CSV covers the action results only and says nothing
            # rather than inventing columns.
            if ($actionResults.Count -gt 0) {
                $actionResults |
                    Select-Object Action, Status, Detail, BytesFreed, FreedDisplay,
                                  @{ Name = 'DurationSeconds'; Expression = { [math]::Round($_.Duration.TotalSeconds, 2) } },
                                  RebootRequired, Timestamp |
                    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
            }
            else {
                Write-PCLog -Level WARN -Message 'CSV export skipped: there are no action results to tabulate.'
            }
        }

        if ($Format -contains 'Html') {
            Write-PCHtmlReport -Payload $payload -ActionResult $actionResults -Path $htmlPath
        }

        $written = [ordered]@{}
        if ($Format -contains 'Json') { $written['JsonPath'] = $jsonPath }
        if ($Format -contains 'Text') { $written['TextPath'] = $textPath }
        if ($Format -contains 'Html') { $written['HtmlPath'] = $htmlPath }
        if ($Format -contains 'Csv' -and $actionResults.Count -gt 0) { $written['CsvPath'] = $csvPath }

        foreach ($value in $written.Values) {
            Write-PCLog -Level INFO -Message "Report written to $value"
        }

        [pscustomobject]$written
    }
}
