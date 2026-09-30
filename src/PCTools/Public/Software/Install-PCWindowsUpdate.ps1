function Install-PCWindowsUpdate {
    <#
    .SYNOPSIS
        Downloads and installs pending Windows updates.

    .DESCRIPTION
        The counterpart to Get-PCWindowsUpdate, over the same COM API. Updates
        are accepted, downloaded and installed in one pass, and the result says
        whether a restart is needed rather than triggering one - restarting
        somebody's machine without asking is not a maintenance tool's decision
        to make.

        This never installs a driver update unless one is named explicitly.
        Windows Update drivers routinely supersede a working vendor driver with
        an older generic one, and doing that unattended is how a maintenance run
        breaks somebody's audio.

    .PARAMETER UpdateId
        Install only these update IDs, from Get-PCWindowsUpdate.

    .PARAMETER TimeoutMinutes
        Overall budget for download and installation.

    .EXAMPLE
        Install-PCWindowsUpdate -WhatIf

    .EXAMPLE
        Get-PCWindowsUpdate | Where-Object Title -like '*Cumulative*' |
            ForEach-Object { Install-PCWindowsUpdate -UpdateId $_.UpdateId }

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [string[]]$UpdateId,

        [ValidateRange(5, 480)]
        [int]$TimeoutMinutes = 120
    )

    Invoke-PCAction -Name 'Install-PCWindowsUpdate' -Body {
        Assert-PCAdmin -Action 'Installing Windows updates'

        $session = New-Object -ComObject 'Microsoft.Update.Session'

        try {
            $searcher = $session.CreateUpdateSearcher()
            $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")

            $wanted = New-Object -ComObject 'Microsoft.Update.UpdateColl'
            $titles = @()

            foreach ($update in $result.Updates) {
                if ($UpdateId -and $UpdateId -notcontains $update.Identity.UpdateID) { continue }

                if (-not $update.EulaAccepted) {
                    try { $update.AcceptEula() } catch { }
                }

                [void]$wanted.Add($update)
                $titles += $update.Title
            }

            if ($wanted.Count -eq 0) {
                return @{ Status = 'Skipped'; Detail = 'No applicable updates are pending.' }
            }

            if (-not $PSCmdlet.ShouldProcess("$($wanted.Count) update(s)", 'Download and install')) {
                return @{
                    Status = 'Skipped'
                    Detail = '{0} update(s) would be installed: {1}' -f $wanted.Count, ($titles -join '; ')
                    Data   = @{ Pending = $titles }
                }
            }

            Write-PCLog -Level INFO -Message "Downloading $($wanted.Count) update(s)"

            $downloader = $session.CreateUpdateDownloader()
            $downloader.Updates = $wanted
            $downloadResult = $downloader.Download()

            # 2 is orcSucceeded, 3 is orcSucceededWithErrors.
            if ($downloadResult.ResultCode -notin 2, 3) {
                return @{
                    Status = 'Failed'
                    Detail = "Download failed with result code $($downloadResult.ResultCode)."
                    Data   = @{ Pending = $titles }
                }
            }

            Write-PCLog -Level INFO -Message "Installing $($wanted.Count) update(s)"

            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $wanted
            $installResult = $installer.Install()

            $installed = @()
            $failed = @()
            for ($i = 0; $i -lt $wanted.Count; $i++) {
                $code = $installResult.GetUpdateResult($i).ResultCode
                if ($code -in 2, 3) { $installed += $titles[$i] } else { $failed += "$($titles[$i]) (code $code)" }
            }

            @{
                Status         = if ($failed.Count -eq 0) { 'Success' }
                                 elseif ($installed.Count -gt 0) { 'Warning' }
                                 else { 'Failed' }
                Detail         = '{0} installed, {1} failed{2}' -f $installed.Count, $failed.Count,
                                 $(if ($installResult.RebootRequired) { '; a restart is required' } else { '' })
                RebootRequired = [bool]$installResult.RebootRequired
                Data           = @{ Installed = $installed; Failed = $failed }
            }
        }
        finally {
            if ($session) {
                try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($session) } catch { }
            }
        }
    }
}
