function Get-PCWindowsUpdate {
    <#
    .SYNOPSIS
        Lists the Windows updates that apply to this machine but are not
        installed.

    .DESCRIPTION
        Uses the Microsoft.Update.Session COM API directly rather than depending
        on the PSWindowsUpdate module from the Gallery. That is a deliberate
        trade: the COM API is more verbose to drive, but it is present on every
        Windows machine, needs no install, and adds no third-party code to a
        tool that runs elevated.

        Searching contacts Windows Update and can take a minute on a machine
        that has not checked in for a while. Nothing is downloaded or installed.

    .PARAMETER IncludeHidden
        Include updates a user has hidden. Hidden usually means deliberately
        declined, so they are excluded by default.

    .PARAMETER IncludeDriver
        Include driver updates. Windows Update drivers are frequently older than
        what the vendor ships, so they are excluded by default.

    .PARAMETER TimeoutSeconds
        Give up on the search after this long.

    .EXAMPLE
        Get-PCWindowsUpdate | Format-Table Title, SizeDisplay, RebootRequired

    .OUTPUTS
        PCTools.WindowsUpdate
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$IncludeHidden,

        [switch]$IncludeDriver,

        [ValidateRange(30, 1800)]
        [int]$TimeoutSeconds = 300
    )

    if (-not $script:IsWindowsPlatform) {
        Write-PCLog -Level WARN -Message 'Windows Update is only available on Windows.'
        return
    }

    Write-PCLog -Level INFO -Message 'Searching Windows Update'

    $session = $null
    try {
        $session = New-Object -ComObject 'Microsoft.Update.Session'
    }
    catch {
        Write-PCLog -Level WARN -Message "Could not create a Windows Update session: $($_.Exception.Message)"
        return
    }

    try {
        $searcher = $session.CreateUpdateSearcher()

        # IsInstalled=0 and IsHidden filter server-side, which is much faster
        # than pulling everything back and filtering here.
        $criteria = "IsInstalled=0 and IsHidden=$(if ($IncludeHidden) { '1' } else { '0' })"
        if (-not $IncludeDriver) { $criteria += " and Type='Software'" }

        $result = $searcher.Search($criteria)

        foreach ($update in $result.Updates) {
            $size = 0L
            try { $size = [long]$update.MaxDownloadSize } catch { }

            $categories = @()
            try { foreach ($category in $update.Categories) { $categories += $category.Name } } catch { }

            $knowledgeBase = @()
            try { foreach ($article in $update.KBArticleIDs) { $knowledgeBase += "KB$article" } } catch { }

            [pscustomobject]@{
                PSTypeName     = 'PCTools.WindowsUpdate'
                Title          = $update.Title
                UpdateId       = $update.Identity.UpdateID
                KB             = $knowledgeBase -join ', '
                Categories     = $categories
                Size           = $size
                SizeDisplay    = Format-PCByteSize -Bytes $size
                RebootRequired = [bool]$update.RebootRequired
                Mandatory      = [bool]$update.IsMandatory
                Description    = $update.Description
            }
        }
    }
    catch {
        Write-PCLog -Level WARN -Message "Windows Update search failed: $($_.Exception.Message)"
    }
    finally {
        if ($session) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($session) } catch { }
        }
    }
}
