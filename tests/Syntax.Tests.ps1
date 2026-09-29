#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
    Parses every PowerShell file in the repository without executing it.

    This is the cheapest possible guard against the failure mode that hurts
    this project most: a syntax break reaching a user who runs
    `irm .../pc-cleanuptool.ps1 | iex` as Administrator.
#>

BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot

    # obj/ excluded too: it is the generated module, and whether it exists
    # depends on whether a build has run - which made the number of tests
    # discovered differ between a fresh checkout and a working tree.
    $script:SourceFiles = Get-ChildItem -Path $repoRoot -Recurse -Include '*.ps1', '*.psm1' -File |
        Where-Object { $_.FullName -notmatch '[\\/](out|obj|dist|\.git)[\\/]' } |
        ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } }
}

Describe 'PowerShell syntax' {

    It '<Name> parses without errors' -ForEach $script:SourceFiles {
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$null, [ref]$parseErrors)

        if ($parseErrors) {
            $detail = ($parseErrors | ForEach-Object {
                'Line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Message
            }) -join [Environment]::NewLine
            throw "Parse errors in ${Name}:$([Environment]::NewLine)$detail"
        }

        $parseErrors | Should -BeNullOrEmpty
    }

    It '<Name> has no BOM-less encoding surprises in string literals' -ForEach $script:SourceFiles {
        # Non-ASCII characters in a script that ships without a BOM are read as
        # mojibake by Windows PowerShell 5.1. Catch them before a user does.
        $content = Get-Content -Path $Path -Raw -Encoding UTF8
        $firstBytes = [System.IO.File]::ReadAllBytes($Path) | Select-Object -First 3
        $hasBom = $firstBytes.Count -ge 3 -and
                  $firstBytes[0] -eq 0xEF -and $firstBytes[1] -eq 0xBB -and $firstBytes[2] -eq 0xBF

        $nonAscii = [regex]::Matches($content, '[^\x00-\x7F]')

        if ($nonAscii.Count -gt 0 -and -not $hasBom) {
            $sample = ($nonAscii | Select-Object -First 5 | ForEach-Object { $_.Value }) -join ' '
            throw "$Name contains non-ASCII characters ($sample) but has no UTF-8 BOM; Windows PowerShell 5.1 will mangle them."
        }
    }
}
