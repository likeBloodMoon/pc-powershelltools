function Clear-PCFolderContent {
    <#
    .SYNOPSIS
        Deletes the contents of a folder and reports how much was reclaimed.

    .DESCRIPTION
        The shared implementation behind every cleanup action. The originals in
        pc-cleanuptool.ps1 and quickspeedboost.ps1 differed in three ways that
        all mattered:

        - The Cleanup Tool piped Get-ChildItem -Recurse into Remove-Item -Recurse,
          walking every tree twice for no benefit.
        - Neither measured anything, so the user was never told what they gained.
        - Neither used -LiteralPath, so a path containing [ or ] was silently
          skipped as an unmatched wildcard.

        This version walks each tree exactly once, through System.IO rather than
        the PowerShell provider, summing sizes and deleting as it goes. On a
        temp folder holding tens of thousands of small files the provider
        overhead per item was most of the cost, and the second walk was pure
        waste.

        Two behaviours changed with the rewrite, both for the better:

        - A locked file no longer costs its whole directory. Deleting per file
          instead of per top-level entry means one held-open Chrome cache file
          leaves that one file behind, not the 400 MB directory containing it.
        - Bytes are counted after each successful delete rather than sized up
          front, so the reported figure is what was actually reclaimed rather
          than what was hoped for.

        Files locked by a running process remain expected and are counted as
        skipped, not as failures.

    .PARAMETER Path
        The folder whose contents are removed. The folder itself is kept.

    .PARAMETER ExcludeName
        Top-level entry names to leave alone.

    .PARAMETER ThrottleLimit
        How many top-level entries to clear at once. Deleting many small files
        is dominated by per-file metadata operations, which overlap well. The
        ShouldProcess decision is always made on the calling thread first; only
        the deletion of already-approved entries is concurrent.

    .OUTPUTS
        pscustomobject with BytesFreed, ItemsRemoved, ItemsLocked and Missing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string[]]$ExcludeName = @(),

        [ValidateRange(1, 16)]
        [int]$ThrottleLimit = 4
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-PCLog -Level WARN -Message "Path does not exist, skipping: $Path"
        return [pscustomobject]@{
            BytesFreed = 0L; ItemsRemoved = 0; ItemsLocked = 0
            FilesRemoved = 0; FilesLocked = 0; Missing = $true
        }
    }

    $entries = @()
    try {
        $entries = @([System.IO.Directory]::EnumerateFileSystemEntries($Path))
    }
    catch {
        Write-PCLog -Level WARN -Message "Cannot enumerate ${Path}: $($_.Exception.Message)"
        return [pscustomobject]@{
            BytesFreed = 0L; ItemsRemoved = 0; ItemsLocked = 0
            FilesRemoved = 0; FilesLocked = 0; Missing = $false
        }
    }

    # ShouldProcess must run on this thread - $PSCmdlet does not exist in a
    # background runspace - so approval happens first, in full, and only the
    # approved list is handed to the workers. Under -WhatIf nothing is approved
    # and nothing is deleted.
    $approved = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $entries) {
        $name = [System.IO.Path]::GetFileName($entry)
        if ($ExcludeName -contains $name) { continue }
        if (-not $PSCmdlet.ShouldProcess($entry, 'Remove')) { continue }
        $approved.Add($entry)
    }

    if ($approved.Count -eq 0) {
        return [pscustomobject]@{
            BytesFreed = 0L; ItemsRemoved = 0; ItemsLocked = 0
            FilesRemoved = 0; FilesLocked = 0; Missing = $false
        }
    }

    # Self-contained by construction: System.IO only, no module functions, no
    # captured variables. See Invoke-PCParallel.
    $clearBody = {
        param($Entry)

        $bytes = 0L
        $filesRemoved = 0
        $filesLocked = 0

        try {
            if ([System.IO.Directory]::Exists($Entry)) {
                # One walk: size and delete each file as it is reached.
                $files = @()
                try {
                    $files = [System.IO.Directory]::EnumerateFiles(
                        $Entry, '*', [System.IO.SearchOption]::AllDirectories)
                }
                catch {
                    # A reparse point or a permission wall part-way down. Take
                    # what the top level gives rather than abandoning the entry.
                    try { $files = [System.IO.Directory]::EnumerateFiles($Entry) } catch { $files = @() }
                }

                foreach ($file in $files) {
                    try {
                        $length = ([System.IO.FileInfo]$file).Length

                        # Read-only files are common in browser caches and are
                        # not a reason to leave the space occupied.
                        $info = [System.IO.FileInfo]$file
                        if ($info.IsReadOnly) { $info.IsReadOnly = $false }

                        [System.IO.File]::Delete($file)
                        $bytes += $length
                        $filesRemoved++
                    }
                    catch {
                        $filesLocked++
                    }
                }

                # Now empty, unless something was locked. Recursive because the
                # walk above left the directory skeleton behind.
                try { [System.IO.Directory]::Delete($Entry, $true) } catch { }
            }
            else {
                $info = [System.IO.FileInfo]$Entry
                $length = $info.Length
                if ($info.IsReadOnly) { $info.IsReadOnly = $false }
                [System.IO.File]::Delete($Entry)
                $bytes += $length
                $filesRemoved++
            }
        }
        catch {
            $filesLocked++
        }

        $gone = -not ([System.IO.Directory]::Exists($Entry) -or [System.IO.File]::Exists($Entry))

        @{
            BytesFreed   = $bytes
            FilesRemoved = $filesRemoved
            FilesLocked  = $filesLocked
            Removed      = $gone
        }
    }

    $completed = @(Invoke-PCParallel -InputObject $approved.ToArray() -ScriptBlock $clearBody `
        -ThrottleLimit $ThrottleLimit -TimeoutSeconds 900)

    $bytesFreed = 0L
    $removed = 0
    $locked = 0
    $filesRemoved = 0
    $filesLocked = 0

    foreach ($item in $completed) {
        $outcome = $item.Output
        if (-not $outcome) {
            $locked++
            Write-PCLog -Level DEBUG -Message "Could not clear: $($item.Input)"
            continue
        }

        $bytesFreed += [long]$outcome.BytesFreed
        $filesRemoved += [int]$outcome.FilesRemoved
        $filesLocked += [int]$outcome.FilesLocked

        if ($outcome.Removed) { $removed++ } else { $locked++ }
    }

    if ($filesLocked -gt 0) {
        # In-use files are the normal case in TEMP, not an error worth raising.
        Write-PCLog -Level DEBUG -Message "$filesLocked file(s) under $Path were in use and left in place."
    }

    [pscustomobject]@{
        BytesFreed   = $bytesFreed
        ItemsRemoved = $removed
        ItemsLocked  = $locked
        FilesRemoved = $filesRemoved
        FilesLocked  = $filesLocked
        Missing      = $false
    }
}
