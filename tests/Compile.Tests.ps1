#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
    The shipped module is generated: build/Invoke-Build.ps1 -Task Compile merges
    the source files into one .psm1 so a release does not open and parse sixty
    files on every import.

    A generated artifact that differs from its source is the classic way to ship
    a module that behaves differently from the one the tests ran against. These
    tests exist so that cannot happen quietly.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:SourceManifest = Join-Path $script:RepoRoot 'src/PCTools/PCTools.psd1'
    $script:CompiledRoot = Join-Path $script:RepoRoot 'obj/PCTools'

    & (Join-Path $script:RepoRoot 'build/Invoke-Build.ps1') -Task Compile | Out-Null

    $script:CompiledManifest = Join-Path $script:CompiledRoot 'PCTools.psd1'
    $script:CompiledModuleText = Get-Content -LiteralPath (Join-Path $script:CompiledRoot 'PCTools.psm1') -Raw
}

Describe 'Compiled module' {

    It 'produces a manifest and a single module file' {
        Test-Path -LiteralPath $script:CompiledManifest | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:CompiledRoot 'PCTools.psm1') | Should -BeTrue
    }

    It 'ships the GUI shell with the module' {
        Test-Path -LiteralPath (Join-Path $script:CompiledRoot 'Shell/Start-PCToolsShell.ps1') | Should -BeTrue
    }

    It 'parses' {
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            $script:CompiledModuleText, [ref]$null, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
    }

    It 'stamps the version instead of reading the manifest at import' {
        # The whole point of the stamp: a shipped module should not parse its
        # own manifest every time somebody imports it.
        $script:CompiledModuleText | Should -Not -Match '\{\{MODULE_VERSION\}\}'

        $version = (Import-PowerShellDataFile -Path $script:CompiledManifest).ModuleVersion
        $script:CompiledModuleText | Should -Match ([regex]::Escape("`$script:ModuleVersion = '$version'"))
    }

    It 'does not dot-source at import' {
        # If the merge failed to inline something, the loader loop would still
        # be there and the file would be doing both.
        $script:CompiledModuleText | Should -Not -Match 'Dot-source Private first'
    }

    It 'exports exactly what the source module exports' {
        # The test that matters. Anything the merge drops, duplicates or fails
        # to export shows up here rather than in a release.
        Import-Module $script:SourceManifest -Force
        $fromSource = (Get-Module PCTools).ExportedFunctions.Keys | Sort-Object
        $sourceAliases = (Get-Module PCTools).ExportedAliases.Keys | Sort-Object
        Remove-Module PCTools -Force

        Import-Module $script:CompiledManifest -Force
        $fromCompiled = (Get-Module PCTools).ExportedFunctions.Keys | Sort-Object
        $compiledAliases = (Get-Module PCTools).ExportedAliases.Keys | Sort-Object
        Remove-Module PCTools -Force

        Compare-Object -ReferenceObject $fromSource -DifferenceObject $fromCompiled |
            Should -BeNullOrEmpty

        Compare-Object -ReferenceObject $sourceAliases -DifferenceObject $compiledAliases |
            Should -BeNullOrEmpty
    }

    It 'carries every private and public source file' {
        # Checked by the region marker the compiler emits per file rather than
        # by function name: not every private file defines a function of its own
        # name - PCPreferenceDefinition.ps1 holds the preference table - and a
        # test that assumed otherwise would fail on a correct build.
        foreach ($folder in 'Private', 'Public') {
            $names = Get-ChildItem -Path (Join-Path $script:RepoRoot "src/PCTools/$folder") -Recurse -Filter '*.ps1' -File |
                ForEach-Object BaseName

            foreach ($name in $names) {
                $script:CompiledModuleText | Should -Match ([regex]::Escape("#region $folder/$name"))
            }
        }
    }

    It 'keeps the private helpers private' {
        Import-Module $script:CompiledManifest -Force
        $exported = (Get-Module PCTools).ExportedFunctions.Keys

        $privateNames = Get-ChildItem -Path (Join-Path $script:RepoRoot 'src/PCTools/Private') -Recurse -Filter '*.ps1' -File |
            ForEach-Object BaseName

        foreach ($name in $privateNames) {
            $exported | Should -Not -Contain $name
        }

        Remove-Module PCTools -Force
    }
}
