#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
    Static checks on install.ps1.

    The installer cannot be run here - it would install a module and open a
    window - but it is the one file in this repository that users are invited to
    pipe straight into iex, so the properties that make that defensible need to
    be asserted rather than assumed.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:InstallPath = Join-Path $script:RepoRoot 'install.ps1'
    $script:InstallText = Get-Content -LiteralPath $script:InstallPath -Raw
    $script:InstallAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:InstallPath, [ref]$null, [ref]$null)
}

Describe 'install.ps1' {

    It 'exists at the repository root, where the pinned URL points' {
        Test-Path -LiteralPath $script:InstallPath | Should -BeTrue
    }

    It 'parses' {
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:InstallPath, [ref]$null, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
    }

    It 'runs on Windows PowerShell 5.1, which is what a stock machine has' {
        # Requiring PowerShell 7 would mean asking somebody to install a
        # prerequisite before they can install anything.
        $script:InstallText | Should -Match '#requires -Version 5\.1'
    }

    It 'verifies a downloaded archive against the published checksum' {
        $script:InstallText | Should -Match 'Get-FileHash'
        $script:InstallText | Should -Match 'SHA256SUMS'
        $script:InstallText | Should -Match 'Checksum mismatch'
    }

    It 'has no way to skip verification' {
        # A -SkipHashCheck switch would be used by exactly the people who should
        # not use it, so it does not exist.
        $parameters = $script:InstallAst.ParamBlock.Parameters |
            ForEach-Object { $_.Name.VariablePath.UserPath }

        foreach ($name in $parameters) {
            $name | Should -Not -Match '(?i)skip.*(hash|verif|check)|insecure|noverify'
        }
    }

    It 'prefers the PowerShell Gallery, where packages are signed' {
        $script:InstallText | Should -Match 'Install-Module'
        $script:InstallText | Should -Match 'Find-Module'
    }

    It 'enables TLS 1.2, which Windows PowerShell 5.1 does not do by default' {
        $script:InstallText | Should -Match 'Tls12'
    }

    It 'documents the trade it asks the user to make' {
        # The README and this file both have to be straight about the fact that
        # the first step is trusted on TLS alone.
        $script:InstallText | Should -Match 'honest limitation'
    }

    It 'installs the shim somewhere already on PATH rather than editing PATH' {
        $script:InstallText | Should -Match 'WindowsApps'
        $script:InstallText | Should -Not -Match "SetEnvironmentVariable\('PATH'"
    }

    It 'points $script:Repository at this project' {
        # The download URLs are built from this one variable, so it is the thing
        # worth pinning down.
        $script:InstallText | Should -Match "\`$script:Repository = 'likeBloodMoon/pc-powershelltools'"
    }

    It 'downloads only from the project repository' {
        # Every URL in the installer must point at this project, either
        # literally or through $script:Repository. A fetch from anywhere else in
        # a script people are invited to pipe into iex would be indefensible.
        $urls = @([regex]::Matches($script:InstallText, 'https?://[^\s''")]+') |
            ForEach-Object { $_.Value })

        $urls.Count | Should -BeGreaterThan 0

        foreach ($url in $urls) {
            $url | Should -Match '^https://(github\.com|raw\.githubusercontent\.com)/(likeBloodMoon/pc-powershelltools|\$script:Repository)'
        }
    }

    It 'never uses http for a download' {
        $script:InstallText | Should -Not -Match 'Invoke-WebRequest[^\r\n]*http://'
    }
}

Describe 'The pinned install command' {

    It 'is pinned to a tag in the README, never to main' {
        $readme = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'README.md') -Raw

        # @() for the same reason the module code needs it: a single match
        # assigns a scalar, and .Count on a string throws under strict mode.
        $installLines = @([regex]::Matches($readme, '(?m)^.*install\.ps1.*$') |
            ForEach-Object { $_.Value })

        $installLines.Count | Should -BeGreaterThan 0

        foreach ($line in $installLines) {
            if ($line -notmatch 'raw\.githubusercontent\.com') { continue }
            $line | Should -Not -Match '/main/'
            $line | Should -Match '/v\d+\.\d+\.\d+/'
        }
    }

    It 'matches the version in the module manifest' {
        # A README pointing at a tag that was never cut is a broken install
        # command, and nobody notices until somebody tries it.
        $manifest = Import-PowerShellDataFile -Path (Join-Path $script:RepoRoot 'src/PCTools/PCTools.psd1')
        $readme = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'README.md') -Raw

        # One distinct tag is the expected case, and Sort-Object -Unique then
        # returns a bare string rather than an array - so this needs @() too.
        $tags = @([regex]::Matches($readme, 'pc-powershelltools/v(\d+\.\d+\.\d+)/install\.ps1') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique)

        $tags.Count | Should -BeGreaterThan 0
        foreach ($tag in $tags) {
            $tag | Should -Be $manifest.ModuleVersion
        }
    }
}
