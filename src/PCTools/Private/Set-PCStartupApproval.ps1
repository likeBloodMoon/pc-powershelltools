function Set-PCStartupApproval {
    <#
    .SYNOPSIS
        Writes the StartupApproved flag that enables or disables a startup item.

    .DESCRIPTION
        Task Manager does not delete a Run key entry when you switch it off. It
        writes a 12-byte value under StartupApproved whose first byte carries
        the flag - even for enabled, odd for disabled - and leaves the entry
        alone. Following that convention rather than inventing one means a user
        can re-enable in Task Manager something disabled here, and the reverse,
        with neither surprising the other.

        The remaining bytes are a timestamp Windows writes and does not require
        from us; zeroes are accepted.

    .PARAMETER Name
        The Run key value name, or the Startup folder file name.

    .PARAMETER Source
        Registry or Folder - they use different StartupApproved subkeys.

    .PARAMETER Scope
        Which hive the item came from. Anything starting with 'AllUsers' means
        HKLM, which needs elevation.

    .PARAMETER Enabled
        The state to write.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('Registry', 'Folder')]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Scope,

        [Parameter(Mandatory)]
        [bool]$Enabled
    )

    $hive = if ($Scope -like 'AllUsers*') { 'HKLM:' } else { 'HKCU:' }
    $leaf = if ($Source -eq 'Folder') { 'StartupFolder' } else { 'Run' }
    $key = "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$leaf"

    if ($hive -eq 'HKLM:' -and -not (Test-PCAdmin)) {
        throw "Changing an all-users startup item requires an elevated session."
    }

    if (-not (Test-Path -LiteralPath $key)) {
        if (-not $PSCmdlet.ShouldProcess($key, 'Create')) { return }
        New-Item -Path $key -Force | Out-Null
    }

    # 02 = enabled, 03 = disabled. Windows writes 02/03 followed by a FILETIME;
    # it reads back only the first byte, so a zeroed tail is accepted.
    $flag = if ($Enabled) { [byte]2 } else { [byte]3 }
    $value = [byte[]]@($flag, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    if (-not $PSCmdlet.ShouldProcess("$key\$Name", $(if ($Enabled) { 'Enable' } else { 'Disable' }))) { return }

    Set-ItemProperty -LiteralPath $key -Name $Name -Value $value -Type Binary -Force
}
