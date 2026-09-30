function Optimize-PCVolume {
    <#
    .SYNOPSIS
        Optimizes a drive the way that drive should be optimized.

    .DESCRIPTION
        The reason this exists rather than a "defragment" button: defragmenting
        an SSD is actively harmful. It writes the whole drive to rearrange data
        whose physical location the controller abstracts away anyway, spending
        write endurance for no gain. An SSD wants TRIM - tell the controller
        which blocks are free - and an HDD wants defragmentation.

        So the media type is read first and the correct operation is chosen.
        There is no switch to force the wrong one.

    .PARAMETER DriveLetter
        Drives to optimize. Defaults to every fixed drive.

    .PARAMETER Analyze
        Report what would be done and the current fragmentation, without
        changing anything.

    .PARAMETER TimeoutMinutes
        Per-drive timeout. A full defragmentation of a large, badly fragmented
        HDD legitimately runs for hours.

    .EXAMPLE
        Optimize-PCVolume -Analyze

    .EXAMPLE
        Optimize-PCVolume -DriveLetter C

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [string[]]$DriveLetter,

        [switch]$Analyze,

        [ValidateRange(1, 480)]
        [int]$TimeoutMinutes = 120
    )

    Invoke-PCAction -Name 'Optimize-PCVolume' -Body {
        Assert-PCAdmin -Action 'Optimizing a volume'

        $volumes = @()
        try {
            $volumes = @(Get-Volume -ErrorAction Stop |
                Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' })
        }
        catch {
            return @{ Status = 'Failed'; Detail = "Could not enumerate volumes: $($_.Exception.Message)" }
        }

        if ($DriveLetter) {
            $wanted = @($DriveLetter | ForEach-Object { $_.TrimEnd(':').ToUpperInvariant() })
            $volumes = @($volumes | Where-Object { $wanted -contains ([string]$_.DriveLetter).ToUpperInvariant() })
        }

        if ($volumes.Count -eq 0) {
            return @{ Status = 'Warning'; Detail = 'No fixed volume matched.' }
        }

        # Media type lives on the physical disk, not the volume, so the two have
        # to be correlated through the partition.
        $mediaByLetter = @{}
        try {
            foreach ($disk in @(Get-PhysicalDisk -ErrorAction Stop)) {
                $partitions = @(Get-Partition -ErrorAction SilentlyContinue |
                    Where-Object { $_.DiskNumber -eq $disk.DeviceId -and $_.DriveLetter })
                foreach ($partition in $partitions) {
                    $mediaByLetter[[string]$partition.DriveLetter] = $disk.MediaType
                }
            }
        }
        catch {
            Write-PCLog -Level DEBUG -Message "Could not read physical disk media types: $($_.Exception.Message)"
        }

        $done = @()
        $failed = @()
        $reboot = $false

        foreach ($volume in $volumes) {
            $letter = [string]$volume.DriveLetter
            $media = if ($mediaByLetter.ContainsKey($letter)) { [string]$mediaByLetter[$letter] } else { 'Unspecified' }

            # SSD and unknown both get ReTrim. Trimming an HDD is a harmless
            # no-op; defragmenting an SSD is not, so unknown media takes the
            # safe branch.
            $isRotational = $media -eq 'HDD'
            $operation = if ($isRotational) { 'Defrag' } else { 'ReTrim' }

            if ($Analyze) {
                try {
                    $analysis = Optimize-Volume -DriveLetter $letter -Analyze -Verbose:$false -ErrorAction Stop 4>&1
                    $done += "{0}: {1} would be run ({2}){3}" -f $letter, $operation, $media,
                             $(if ($analysis) { " - $(($analysis | Out-String).Trim() -replace '\s+', ' ')" } else { '' })
                }
                catch {
                    $failed += "$letter ($($_.Exception.Message))"
                }
                continue
            }

            if (-not $PSCmdlet.ShouldProcess("${letter}:", "$operation ($media)")) { continue }

            Write-PCLog -Level INFO -Message "Optimizing ${letter}: with $operation (media: $media)"

            # defrag.exe rather than Optimize-Volume so the run is bounded by
            # Invoke-PCProcess's timeout. A stuck defrag on a failing disk would
            # otherwise hang the caller indefinitely.
            $arguments = if ($isRotational) { @("${letter}:", '/O') } else { @("${letter}:", '/L') }
            $run = Invoke-PCProcess -FilePath 'defrag.exe' -ArgumentList $arguments -TimeoutSeconds ($TimeoutMinutes * 60)

            if ($run.TimedOut) {
                $failed += "$letter (timed out after $TimeoutMinutes minutes)"
            }
            elseif ($run.ExitCode -eq 0) {
                $done += "${letter}: $operation"
            }
            else {
                $failed += "$letter (exit $($run.ExitCode))"
                Write-PCLog -Level WARN -Message "defrag ${letter}: $($run.Output)"
            }
        }

        $parts = @()
        if ($done.Count) { $parts += $done -join '; ' }
        if ($failed.Count) { $parts += 'failed: ' + ($failed -join ', ') }

        @{
            Status         = if ($failed.Count -eq 0 -and $done.Count -gt 0) { 'Success' }
                             elseif ($done.Count -gt 0) { 'Warning' }
                             elseif ($failed.Count -gt 0) { 'Failed' }
                             else { 'Skipped' }
            Detail         = if ($parts.Count) { $parts -join ' | ' } else { 'Nothing to do.' }
            RebootRequired = $reboot
            Data           = @{ Optimized = $done; Failed = $failed }
        }
    }
}
