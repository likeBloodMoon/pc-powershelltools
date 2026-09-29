function Clear-PCWindowsOld {
    <#
    .SYNOPSIS
        Removes the previous Windows installation left behind by a feature update.

    .DESCRIPTION
        C:\Windows.old is the rollback copy a feature update leaves behind, and
        it is routinely 15 to 30 GB. Windows removes it automatically after ten
        days.

        This is the one cleanup here that genuinely costs something: deleting it
        gives up the ability to roll back to the previous Windows build. The
        confirmation is High for that reason, and the age of the folder is
        reported so the decision is an informed one - inside the rollback window
        it is worth keeping, outside it is dead weight.

        Ownership is taken first. The folder is owned by TrustedInstaller and a
        plain recursive delete fails partway through, leaving a mess that is
        harder to clear than what it started with.

    .PARAMETER MinimumAgeDays
        Refuse to delete a Windows.old younger than this. Defaults to 10, which
        is the rollback window Windows itself uses. Set to 0 to delete
        regardless.

    .EXAMPLE
        Clear-PCWindowsOld -WhatIf

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(0, 365)]
        [int]$MinimumAgeDays = 10
    )

    Invoke-PCAction -Name 'Clear-PCWindowsOld' -Body {
        Assert-PCAdmin -Action 'Removing the previous Windows installation'

        $systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
        $path = Join-Path $systemDrive 'Windows.old'

        if (-not (Test-Path -LiteralPath $path)) {
            return @{
                Status = 'Skipped'
                Detail = 'No previous Windows installation is present; nothing to remove.'
            }
        }

        $folder = Get-Item -LiteralPath $path -Force
        $ageDays = [int]((Get-Date) - $folder.CreationTime).TotalDays

        if ($MinimumAgeDays -gt 0 -and $ageDays -lt $MinimumAgeDays) {
            return @{
                Status = 'Skipped'
                Detail = ('Windows.old is {0} day(s) old and rollback to the previous build is still possible. ' +
                          'It will be removed automatically at {1} days, or pass -MinimumAgeDays 0 to remove it now.') -f
                         $ageDays, $MinimumAgeDays
                Data   = @{ AgeDays = $ageDays }
            }
        }

        if (-not $PSCmdlet.ShouldProcess($path, 'Delete the previous Windows installation')) {
            return @{ Status = 'Skipped'; Detail = 'Not confirmed.' }
        }

        # TrustedInstaller owns most of this tree. Without taking ownership and
        # granting rights the delete fails halfway through.
        Write-PCLog -Level INFO -Message 'Taking ownership of Windows.old'
        $takeown = Invoke-PCProcess -FilePath 'takeown.exe' -ArgumentList @('/F', $path, '/R', '/A', '/D', 'Y') -TimeoutSeconds 600
        if ($takeown.TimedOut) {
            return @{ Status = 'Failed'; Detail = 'Taking ownership timed out; nothing was deleted.' }
        }

        $icacls = Invoke-PCProcess -FilePath 'icacls.exe' -ArgumentList @($path, '/grant', 'Administrators:F', '/T', '/C') -TimeoutSeconds 600
        if ($icacls.TimedOut) {
            return @{ Status = 'Failed'; Detail = 'Granting rights timed out; nothing was deleted.' }
        }

        $outcome = Clear-PCFolderContent -Path $path

        $remaining = Test-Path -LiteralPath $path
        if ($remaining) {
            try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
            catch { Write-PCLog -Level WARN -Message "Windows.old could not be fully removed: $($_.Exception.Message)" }
            $remaining = Test-Path -LiteralPath $path
        }

        @{
            Status     = if ($remaining) { 'Warning' } else { 'Success' }
            Detail     = if ($remaining) {
                             '{0} freed, but part of Windows.old could not be removed. Disk Cleanup with "Previous Windows installation(s)" ticked will finish the job.' -f
                             (Format-PCByteSize -Bytes $outcome.BytesFreed)
                         }
                         else {
                             '{0} freed; rollback to the previous Windows build is no longer possible' -f
                             (Format-PCByteSize -Bytes $outcome.BytesFreed)
                         }
            BytesFreed = $outcome.BytesFreed
            Data       = @{ AgeDays = $ageDays; FullyRemoved = -not $remaining }
        }
    }
}
