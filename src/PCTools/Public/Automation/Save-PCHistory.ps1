function Save-PCHistory {
    <#
    .SYNOPSIS
        Records a maintenance run so it can be compared with later ones.

    .DESCRIPTION
        A single run tells you it reclaimed 2 GB. Ten runs tell you this machine
        generates 2 GB of rubbish a week, which is a different and more useful
        fact - and the one that makes a schedule worth setting up.

        One JSON file per run under %LOCALAPPDATA%\PCTools\history. Files, not a
        database, because they can be read with anything, deleted individually,
        and never need a migration.

        Only the summary is kept, not the full results: the point is trends, and
        an unbounded store of every detail of every run is a liability rather
        than a feature. Old entries beyond -Keep are pruned on each write.

    .PARAMETER Result
        The action results to record.

    .PARAMETER ProfileName
        The profile that produced them.

    .PARAMETER Keep
        How many runs to retain.

    .EXAMPLE
        Invoke-PCMaintenance -ProfileName Quick | Save-PCHistory -ProfileName Quick

    .OUTPUTS
        pscustomobject describing the saved entry.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyCollection()]
        [object[]]$Result,

        [string]$ProfileName = 'Custom',

        [ValidateRange(1, 1000)]
        [int]$Keep = 100
    )

    begin {
        $collected = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $Result) { if ($null -ne $item) { $collected.Add($item) } }
    }

    end {
        $summary = Get-PCResultSummary -Result @($collected)
        if ($summary.Total -eq 0) { return }

        try {
            if (-not (Test-Path -LiteralPath $script:PCHistoryDirectory)) {
                New-Item -ItemType Directory -Path $script:PCHistoryDirectory -Force | Out-Null
            }
        }
        catch {
            Write-PCLog -Level WARN -Message "Could not create the history folder: $($_.Exception.Message)"
            return
        }

        $stamp = Get-Date
        $path = Join-Path $script:PCHistoryDirectory ('run-{0:yyyyMMdd-HHmmss}.json' -f $stamp)

        # Two runs finishing in the same second would otherwise share a name and
        # the second would silently replace the first. A short suffix keeps both,
        # and keeps the name sortable, which is what the pruning relies on.
        if (Test-Path -LiteralPath $path) {
            for ($suffix = 1; $suffix -le 99; $suffix++) {
                $candidate = Join-Path $script:PCHistoryDirectory ('run-{0:yyyyMMdd-HHmmss}-{1:d2}.json' -f $stamp, $suffix)
                if (-not (Test-Path -LiteralPath $candidate)) { $path = $candidate; break }
            }
        }

        if (-not $PSCmdlet.ShouldProcess($path, 'Record this run in the history')) { return }

        $entry = [pscustomobject]@{
            PSTypeName     = 'PCTools.HistoryEntry'
            Timestamp      = $stamp
            ProfileName    = $ProfileName
            ComputerName   = $env:COMPUTERNAME
            User           = $env:USERNAME
            Version        = $script:ModuleVersion
            Total          = $summary.Total
            Succeeded      = $summary.Succeeded
            Warnings       = $summary.Warnings
            Failed         = $summary.Failed
            BytesFreed     = $summary.BytesFreed
            RebootRequired = $summary.RebootRequired
            DurationSeconds = [math]::Round($summary.Duration.TotalSeconds, 1)
            Actions        = @($collected | ForEach-Object {
                [pscustomobject]@{
                    Action     = $_.Action
                    Status     = $_.Status
                    BytesFreed = $_.BytesFreed
                    Detail     = $_.Detail
                }
            })
        }

        try {
            $entry | ConvertTo-Json -Depth 5 -WarningAction SilentlyContinue |
                Set-Content -LiteralPath $path -Encoding UTF8
        }
        catch {
            Write-PCLog -Level WARN -Message "Could not write history: $($_.Exception.Message)"
            return
        }

        # Prune oldest-first so the store stays bounded without a separate
        # maintenance step of its own.
        try {
            Get-ChildItem -LiteralPath $script:PCHistoryDirectory -Filter 'run-*.json' -File |
                Sort-Object Name -Descending |
                Select-Object -Skip $Keep |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        catch { }

        Write-PCLog -Level INFO -Message "Run recorded: $path"
        $entry
    }
}
