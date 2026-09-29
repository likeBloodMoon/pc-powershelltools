function Clear-PCCrashDump {
    <#
    .SYNOPSIS
        Removes crash dumps and Windows Error Reporting queues.

    .DESCRIPTION
        A single kernel memory dump can be as large as installed RAM - 32 GB on
        a machine with 32 GB of it - and Windows keeps one from every bugcheck
        alongside a minidump each. The WER queues add up too, quietly.

        Read Get-PCEventSummary before running this on a machine that is
        actually crashing: the dumps are the evidence. On a machine that is
        working fine, they are 30 GB of nothing.

    .PARAMETER IncludeMemoryDump
        Also delete the full MEMORY.DMP, which is where most of the space is.
        On by default.

    .PARAMETER IncludeMinidump
        Also delete the per-crash minidumps. Small, and the only record of what
        crashed; off by default for that reason.

    .EXAMPLE
        Clear-PCCrashDump -WhatIf

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [bool]$IncludeMemoryDump = $true,

        [switch]$IncludeMinidump
    )

    Invoke-PCAction -Name 'Clear-PCCrashDump' -Body {
        Assert-PCAdmin -Action 'Clearing crash dumps'

        $bytes = 0L
        $removed = 0
        $cleared = @()

        if ($IncludeMemoryDump) {
            $memoryDump = Join-Path $env:SystemRoot 'MEMORY.DMP'
            if (Test-Path -LiteralPath $memoryDump) {
                if ($PSCmdlet.ShouldProcess($memoryDump, 'Remove')) {
                    try {
                        $size = (Get-Item -LiteralPath $memoryDump -Force).Length
                        Remove-Item -LiteralPath $memoryDump -Force -ErrorAction Stop
                        $bytes += $size
                        $removed++
                        $cleared += 'MEMORY.DMP'
                    }
                    catch {
                        Write-PCLog -Level WARN -Message "MEMORY.DMP could not be removed: $($_.Exception.Message)"
                    }
                }
            }
        }

        if ($IncludeMinidump) {
            $minidumpDir = Join-Path $env:SystemRoot 'Minidump'
            if (Test-Path -LiteralPath $minidumpDir) {
                $outcome = Clear-PCFolderContent -Path $minidumpDir
                if (-not $outcome.Missing -and $outcome.ItemsRemoved -gt 0) {
                    $bytes += $outcome.BytesFreed
                    $removed += $outcome.ItemsRemoved
                    $cleared += 'Minidump'
                }
            }
        }

        # WER report queues: everything crashed applications left behind.
        $werPaths = @(
            (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')
            (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue')
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive')
            (Join-Path $env:LOCALAPPDATA 'CrashDumps')
        )

        foreach ($path in $werPaths) {
            if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
            $outcome = Clear-PCFolderContent -Path $path
            if ($outcome.Missing) { continue }
            $bytes += $outcome.BytesFreed
            $removed += $outcome.ItemsRemoved
            if ($outcome.ItemsRemoved -gt 0) { $cleared += (Split-Path -Leaf $path) }
        }

        @{
            Status     = if ($removed -eq 0) { 'Skipped' } else { 'Success' }
            Detail     = if ($removed -eq 0) {
                             'No crash dumps or error reports were found.'
                         }
                         else {
                             '{0} item(s) removed from {1}, {2} freed' -f
                             $removed, (($cleared | Select-Object -Unique) -join ', '), (Format-PCByteSize -Bytes $bytes)
                         }
            BytesFreed = $bytes
            Data       = @{ Cleared = @($cleared | Select-Object -Unique); ItemsRemoved = $removed }
        }
    }
}
