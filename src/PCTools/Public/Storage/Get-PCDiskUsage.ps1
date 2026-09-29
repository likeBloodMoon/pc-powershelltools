function Get-PCDiskUsage {
    <#
    .SYNOPSIS
        Finds what is actually using the space.

    .DESCRIPTION
        "Disk full" is rarely solved by a temp clean. It is solved by finding
        the 60 GB of old virtual machine images somebody forgot about. This
        walks a tree once and reports the largest folders and the largest
        individual files.

        The walk uses System.IO.Directory enumeration rather than
        Get-ChildItem -Recurse. On a home folder with a few hundred thousand
        files the provider overhead dominates, and this is meant to be run
        interactively while somebody waits.

        Unreadable subtrees are skipped rather than throwing: a scan of C:\
        will always meet folders the current user cannot enter, and reporting
        the 95% it could read is far more useful than failing.

    .PARAMETER Path
        Where to start. Defaults to the user profile, which is where the
        surprises usually are.

    .PARAMETER Top
        How many entries to report in each list.

    .PARAMETER Depth
        How deep to group folders. Depth 1 reports the immediate children of
        Path, which is normally the level at which a person makes a decision.

    .PARAMETER MinimumSize
        Ignore anything below this many bytes. Defaults to 10 MB.

    .EXAMPLE
        Get-PCDiskUsage -Path C:\ -Top 15

    .EXAMPLE
        (Get-PCDiskUsage).LargestFolders | Format-Table Path, SizeDisplay, FileCount

    .OUTPUTS
        PCTools.DiskUsage
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string]$Path,

        [ValidateRange(1, 200)]
        [int]$Top = 20,

        [ValidateRange(1, 4)]
        [int]$Depth = 1,

        [long]$MinimumSize = 10MB
    )

    if (-not $Path) {
        $Path = if ($env:USERPROFILE) { $env:USERPROFILE } else { [System.IO.Path]::GetTempPath() }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No such path: $Path"
    }

    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath
    Write-PCLog -Level INFO -Message "Scanning $Path for disk usage"

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $roots = @()
    try {
        $roots = @([System.IO.Directory]::EnumerateDirectories($Path))
    }
    catch {
        Write-PCLog -Level WARN -Message "Cannot enumerate ${Path}: $($_.Exception.Message)"
    }

    # One self-contained walk per top-level folder, run concurrently. The
    # measurement is read-only, so unlike deletion there is no ordering or
    # safety constraint to respect here.
    $measureBody = {
        param($Folder, $GroupDepth, $Root, $Threshold)

        $bytes = 0L
        $files = 0
        $largest = [System.Collections.Generic.List[object]]::new()
        $subtotals = @{}

        $enumerated = $null
        try {
            $enumerated = [System.IO.Directory]::EnumerateFiles(
                $Folder, '*', [System.IO.SearchOption]::AllDirectories)
        }
        catch {
            try { $enumerated = [System.IO.Directory]::EnumerateFiles($Folder) } catch { $enumerated = @() }
        }

        # A manual enumerator so an access denial part-way through a huge tree
        # stops that branch instead of discarding everything counted so far.
        $iterator = $enumerated.GetEnumerator()
        while ($true) {
            try {
                if (-not $iterator.MoveNext()) { break }
            }
            catch {
                break
            }

            $file = $iterator.Current
            try {
                $length = ([System.IO.FileInfo]$file).Length
                $bytes += $length
                $files++

                if ($length -ge $Threshold) {
                    $largest.Add(@{ Path = $file; Size = $length })
                }

                if ($GroupDepth -gt 1) {
                    $relative = $file.Substring($Root.Length).TrimStart('\', '/')
                    $parts = $relative -split '[\\/]'
                    if ($parts.Count -gt $GroupDepth) {
                        $key = ($parts[0..($GroupDepth - 1)]) -join [System.IO.Path]::DirectorySeparatorChar
                        if ($subtotals.ContainsKey($key)) { $subtotals[$key] += $length }
                        else { $subtotals[$key] = $length }
                    }
                }
            }
            catch {
                continue
            }
        }

        @{
            Folder    = $Folder
            Bytes     = $bytes
            FileCount = $files
            Largest   = $largest.ToArray()
            Subtotals = $subtotals
        }
    }

    $folders = [System.Collections.Generic.List[object]]::new()
    $largestFiles = [System.Collections.Generic.List[object]]::new()
    $totalBytes = 0L
    $totalFiles = 0

    if ($roots.Count -gt 0) {
        $completed = @(Invoke-PCParallel -InputObject $roots -ScriptBlock $measureBody `
            -ArgumentList @($Depth, $Path, $MinimumSize) -ThrottleLimit 6 -TimeoutSeconds 900)

        foreach ($item in $completed) {
            $outcome = $item.Output
            if (-not $outcome) { continue }

            $totalBytes += [long]$outcome.Bytes
            $totalFiles += [int]$outcome.FileCount

            if ([long]$outcome.Bytes -ge $MinimumSize) {
                $folders.Add([pscustomobject]@{
                    PSTypeName  = 'PCTools.DiskUsageEntry'
                    Path        = $outcome.Folder
                    Size        = [long]$outcome.Bytes
                    SizeDisplay = Format-PCByteSize -Bytes ([long]$outcome.Bytes)
                    FileCount   = [int]$outcome.FileCount
                })
            }

            foreach ($key in $outcome.Subtotals.Keys) {
                $size = [long]$outcome.Subtotals[$key]
                if ($size -lt $MinimumSize) { continue }
                $folders.Add([pscustomobject]@{
                    PSTypeName  = 'PCTools.DiskUsageEntry'
                    Path        = Join-Path $Path $key
                    Size        = $size
                    SizeDisplay = Format-PCByteSize -Bytes $size
                    FileCount   = $null
                })
            }

            foreach ($file in $outcome.Largest) {
                $largestFiles.Add([pscustomobject]@{
                    PSTypeName  = 'PCTools.DiskUsageEntry'
                    Path        = $file.Path
                    Size        = [long]$file.Size
                    SizeDisplay = Format-PCByteSize -Bytes ([long]$file.Size)
                    FileCount   = $null
                })
            }
        }
    }

    # Loose files directly under the root are easy to miss and occasionally the
    # whole answer - an ISO on the desktop, a forgotten database dump.
    try {
        foreach ($file in [System.IO.Directory]::EnumerateFiles($Path)) {
            try {
                $length = ([System.IO.FileInfo]$file).Length
                $totalBytes += $length
                $totalFiles++
                if ($length -ge $MinimumSize) {
                    $largestFiles.Add([pscustomobject]@{
                        PSTypeName  = 'PCTools.DiskUsageEntry'
                        Path        = $file
                        Size        = $length
                        SizeDisplay = Format-PCByteSize -Bytes $length
                        FileCount   = $null
                    })
                }
            }
            catch { continue }
        }
    }
    catch { }

    $stopwatch.Stop()

    [pscustomobject]@{
        PSTypeName     = 'PCTools.DiskUsage'
        Path           = $Path
        TotalSize      = $totalBytes
        TotalDisplay   = Format-PCByteSize -Bytes $totalBytes
        FileCount      = $totalFiles
        Duration       = $stopwatch.Elapsed
        LargestFolders = @($folders | Sort-Object Size -Descending | Select-Object -First $Top)
        LargestFiles   = @($largestFiles | Sort-Object Size -Descending | Select-Object -First $Top)
    }
}
