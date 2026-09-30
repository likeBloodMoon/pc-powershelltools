function Get-PCExtension {
    <#
    .SYNOPSIS
        Lists extension actions, loaded and available.

    .DESCRIPTION
        Shows what Register-PCExtension has loaded into this session, and what
        is sitting in the extensions folder waiting to be loaded. The
        distinction matters: a file being present does not mean its actions are
        callable, and an action that a profile references but that was never
        loaded is the likeliest reason a custom profile fails.

    .PARAMETER IncludeAvailable
        Also list files present on disk that have not been loaded. On by
        default.

    .EXAMPLE
        Get-PCExtension | Format-Table Name, Loaded, File

    .OUTPUTS
        PCTools.Extension
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [bool]$IncludeAvailable = $true
    )

    foreach ($key in @($script:PCExtension.Keys | Sort-Object)) {
        $entry = $script:PCExtension[$key]
        [pscustomobject]@{
            PSTypeName = 'PCTools.Extension'
            Name       = $entry.Name
            Loaded     = $true
            File       = $entry.File
            LoadedAt   = $entry.LoadedAt
        }
    }

    if (-not $IncludeAvailable) { return }

    $root = $script:PCExtensionDirectory
    if (-not (Test-Path -LiteralPath $root)) { return }

    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.PCAction.ps1' -File -Recurse)) {
        $alreadyLoaded = @($script:PCExtension.Values | Where-Object { $_.File -eq $file.FullName })
        if ($alreadyLoaded.Count -gt 0) { continue }

        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)

        # @() around the whole expression: an `if` that yields a one-element
        # array assigns a scalar, and .Count on it below then throws under
        # strict mode. One action per file is the normal case.
        $functions = @(if ($parseErrors) {
            @()
        }
        else {
            @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $false) | ForEach-Object { $_.Name } | Where-Object { $_ -match '^\w+-PC\w+$' })
        })

        foreach ($name in $functions) {
            [pscustomobject]@{
                PSTypeName = 'PCTools.Extension'
                Name       = $name
                Loaded     = $false
                File       = $file.FullName
                LoadedAt   = $null
            }
        }

        if ($functions.Count -eq 0) {
            [pscustomobject]@{
                PSTypeName = 'PCTools.Extension'
                Name       = "($($file.Name): $(if ($parseErrors) { 'parse errors' } else { 'no PC actions' }))"
                Loaded     = $false
                File       = $file.FullName
                LoadedAt   = $null
            }
        }
    }
}
