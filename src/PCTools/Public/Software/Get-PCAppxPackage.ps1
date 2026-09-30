function Get-PCAppxPackage {
    <#
    .SYNOPSIS
        Lists installed Store-style apps and grades what is safe to remove.

    .DESCRIPTION
        Get-AppxPackage returns 200 packages of which about 190 are framework
        libraries, runtime components and things the shell needs to function.
        This grades them:

          Removable  - on the curated list of preinstalled consumer apps
          Framework  - a shared runtime; removing it breaks whatever uses it
          System     - part of the shell or a system surface
          Other      - installed by the user, so their business rather than ours

        Only Removable is offered to Remove-PCAppxPackage. Nothing on the list
        was included because a blog post said so; each one is a preinstalled
        consumer application whose removal has no effect on anything else.

    .PARAMETER RemovableOnly
        Return only packages on the curated removable list.

    .PARAMETER AllUsers
        Report packages for every user. Needs elevation.

    .EXAMPLE
        Get-PCAppxPackage -RemovableOnly | Format-Table DisplayName, Name, SizeDisplay

    .OUTPUTS
        PCTools.AppxPackage
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$RemovableOnly,

        [switch]$AllUsers
    )

    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        Write-PCLog -Level WARN -Message 'Get-AppxPackage is not available on this system.'
        return
    }

    $removable = Get-PCRemovableAppxName

    $packages = @()
    try {
        $packages = if ($AllUsers) {
            Assert-PCAdmin -Action 'Listing packages for all users'
            @(Get-AppxPackage -AllUsers -ErrorAction Stop)
        }
        else {
            @(Get-AppxPackage -ErrorAction Stop)
        }
    }
    catch {
        Write-PCLog -Level WARN -Message "Could not enumerate packages: $($_.Exception.Message)"
        return
    }

    foreach ($package in $packages) {
        $category = if ($package.IsFramework) { 'Framework' }
                    elseif ($removable -contains $package.Name) { 'Removable' }
                    elseif ($package.SignatureKind -eq 'System' -or $package.NonRemovable) { 'System' }
                    else { 'Other' }

        if ($RemovableOnly -and $category -ne 'Removable') { continue }

        $size = 0L
        try {
            if ($package.InstallLocation -and (Test-Path -LiteralPath $package.InstallLocation)) {
                foreach ($file in [System.IO.Directory]::EnumerateFiles(
                    $package.InstallLocation, '*', [System.IO.SearchOption]::AllDirectories)) {
                    try { $size += ([System.IO.FileInfo]$file).Length } catch { continue }
                }
            }
        }
        catch { }

        [pscustomobject]@{
            PSTypeName      = 'PCTools.AppxPackage'
            Name            = $package.Name
            DisplayName     = if ($package.DisplayName) { $package.DisplayName } else { $package.Name }
            Publisher       = $package.Publisher
            Version         = [string]$package.Version
            Category        = $category
            CanRemove       = $category -eq 'Removable'
            InstallLocation = $package.InstallLocation
            Size            = $size
            SizeDisplay     = Format-PCByteSize -Bytes $size
        }
    }
}
