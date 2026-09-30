<#
.SYNOPSIS
    Build, test and release entry point for pc-powershelltools.

.DESCRIPTION
    One script that CI and a developer's machine both call, so "it passed
    locally" and "it passed in CI" mean the same thing.

.PARAMETER Task
    Test     - run the Pester suite (syntax, manifest, unit).
    Analyze  - run PSScriptAnalyzer against every script and module file.
    Compile  - merge the module sources into one .psm1 under obj/.
    Docs     - regenerate docs/COMMANDS.md from the module's own help.
    Release  - stage release artifacts into out/ and write SHA256SUMS.
    Bench    - measure the hot paths and write build/benchmark.json.
    All      - Test, then Analyze.

.EXAMPLE
    ./build/Invoke-Build.ps1 -Task All
#>
[CmdletBinding()]
param(
    [ValidateSet('Test', 'Analyze', 'Compile', 'Docs', 'Release', 'Checksum', 'Bench', 'All')]
    [string]$Task = 'All',

    [string]$Version,

    # Warnings above this fail the build, so the count can only go down.
    # Mostly PSUseShouldProcessForStateChangingFunctions firing on the shell's
    # internal UI helpers, where the rule does not apply but is worth keeping
    # enabled for the module's actual cmdlets, and PSAvoidUsingEmptyCatchBlock
    # on the deliberate best-effort cleanups. Lower it as findings are fixed;
    # raising it should be a deliberate, reviewed decision.
    [int]$MaxWarning = 210,

    # Release only. Stage from the obj/PCTools that is already there instead of
    # recompiling, so a release pipeline can compile, Authenticode-sign the
    # result, and then package the signed files. Recompiling at package time
    # would discard those signatures.
    [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-SourceFile {
    # obj/ holds the compiled module, which is generated from these same files.
    # Including it would mean every finding in module code was reported twice,
    # the second time against a file nobody edits.
    Get-ChildItem -Path $RepoRoot -Recurse -Include '*.ps1', '*.psm1', '*.psd1' -File |
        Where-Object { $_.FullName -notmatch '[\\/](out|obj|dist|\.git)[\\/]' }
}

function Invoke-TestTask {
    Write-Step 'Running Pester suite'

    $pester = Get-Module -ListAvailable Pester |
        Where-Object { $_.Version -ge [version]'5.5.0' } |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $pester) {
        throw 'Pester 5.5.0 or later is required. Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck'
    }

    Import-Module $pester.Path -Force

    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $RepoRoot 'tests'
    $config.Run.Throw = $true
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = Join-Path $RepoRoot 'testResults.xml'

    Invoke-Pester -Configuration $config
}

function Invoke-AnalyzeTask {
    Write-Step 'Running PSScriptAnalyzer'

    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        throw 'PSScriptAnalyzer is required. Install-Module PSScriptAnalyzer -Force'
    }
    Import-Module PSScriptAnalyzer -Force

    $settings = Join-Path $RepoRoot 'PSScriptAnalyzerSettings.psd1'

    # obj/ is excluded for the same reason as in Get-SourceFile: it is the
    # compiled module, generated from the sources already being analyzed. The
    # test suite builds it - Compile.Tests does - so on a machine that has run
    # the tests it exists and silently doubled the count of every finding in
    # module code. That is what pushed CI from 197 warnings to 275 and over
    # budget, against a tree whose sources had not changed.
    $results = Invoke-ScriptAnalyzer -Path $RepoRoot -Recurse -Settings $settings |
        Where-Object { $_.ScriptPath -notmatch '[\\/](out|obj|dist)[\\/]' }

    if (-not $results) {
        Write-Host 'PSScriptAnalyzer: clean.' -ForegroundColor Green
        return
    }

    # Summarise by rule first. A flat list of a thousand findings is unreadable,
    # and the useful question is always "which rule, and how often".
    Write-Host ''
    Write-Host 'Findings by rule:'
    $results | Group-Object RuleName | Sort-Object Count -Descending | ForEach-Object {
        Write-Host ('  {0,5}  {1}' -f $_.Count, $_.Name)
    }

    $errors = @($results | Where-Object Severity -eq 'Error')
    $warnings = @($results | Where-Object Severity -eq 'Warning')

    if ($errors.Count -gt 0) {
        Write-Host ''
        $errors | Format-Table -AutoSize -Property ScriptName, Line, RuleName, Message | Out-String | Write-Host
        throw "PSScriptAnalyzer reported $($errors.Count) error(s)."
    }

    if ($warnings.Count -gt 0) {
        Write-Host ''
        $warnings | Format-Table -AutoSize -Property ScriptName, Line, RuleName, Message | Out-String | Write-Host
    }

    # A warning budget keeps the analyzer honest. Errors always fail; warnings
    # fail once they exceed what the repository has agreed to carry, so the
    # count can only go down.
    if ($warnings.Count -gt $MaxWarning) {
        throw "PSScriptAnalyzer reported $($warnings.Count) warning(s), over the budget of $MaxWarning. Fix them, or raise -MaxWarning deliberately."
    }

    Write-Host ("PSScriptAnalyzer: {0} warning(s), no errors (budget {1})." -f $warnings.Count, $MaxWarning) -ForegroundColor Yellow
}

function Invoke-ReleaseTask {
    Write-Step 'Staging release artifacts'

    if (-not $Version) {
        $manifestPath = Join-Path $RepoRoot 'src/PCTools/PCTools.psd1'
        $Version = (Import-PowerShellDataFile $manifestPath).ModuleVersion
    }
    Write-Host "Version: $Version"

    $outDir = Join-Path $RepoRoot 'out'
    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    # The legacy single-file tools, which existing README links point at and
    # which people still pipe into iex. Shipped loose so those URLs keep working.
    Get-ChildItem -Path $RepoRoot -Filter '*.ps1' -File |
        Copy-Item -Destination $outDir

    # The compiled module is what ships: one file to parse instead of sixty.
    $compiled = if ($SkipCompile) {
        $existing = Join-Path $RepoRoot 'obj/PCTools'
        if (-not (Test-Path (Join-Path $existing 'PCTools.psm1'))) {
            throw "-SkipCompile was given but there is no compiled module at $existing. Run -Task Compile first."
        }
        Write-Host "Using the already-compiled module at $existing" -ForegroundColor Yellow
        $existing
    }
    else {
        Invoke-CompileTask
    }

    # The current toolkit. pc-tools.ps1 expects src/PCTools beside it, so the
    # compiled module is staged at that path rather than as loose sources.
    $stage = Join-Path $RepoRoot 'obj/pc-tools'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path (Join-Path $stage 'src') -Force | Out-Null

    Copy-Item (Join-Path $RepoRoot 'pc-tools.ps1') -Destination $stage
    Copy-Item (Join-Path $RepoRoot 'install.ps1') -Destination $stage -ErrorAction SilentlyContinue
    Copy-Item $compiled -Destination (Join-Path $stage 'src') -Recurse

    foreach ($doc in 'README.md', 'CHANGELOG.md', 'LICENSE') {
        $path = Join-Path $RepoRoot $doc
        if (Test-Path $path) { Copy-Item $path -Destination $stage }
    }
    $docsDir = Join-Path $RepoRoot 'docs'
    if (Test-Path $docsDir) { Copy-Item $docsDir -Destination $stage -Recurse }

    Compress-Archive -Path (Join-Path $stage '*') `
        -DestinationPath (Join-Path $outDir "pc-tools-$Version.zip") -Force

    # The module on its own, for people who only want the commands, and the
    # archive install.ps1 verifies and unpacks.
    Compress-Archive -Path $compiled -DestinationPath (Join-Path $outDir "PCTools-$Version.zip") -Force

    Remove-Item $stage -Recurse -Force

    Invoke-ChecksumTask

    Write-Host "Artifacts staged in $outDir" -ForegroundColor Green
}

function Invoke-ChecksumTask {
    <#
        Kept separate from Release because Authenticode signing rewrites the
        files it signs. Checksums generated before signing would not match what
        the user downloads, which is worse than publishing none at all.
    #>
    Write-Step 'Writing SHA256SUMS'

    $outDir = Join-Path $RepoRoot 'out'
    if (-not (Test-Path $outDir)) {
        throw "No staged artifacts found in $outDir. Run -Task Release first."
    }

    $sumsPath = Join-Path $outDir 'SHA256SUMS'
    if (Test-Path $sumsPath) { Remove-Item $sumsPath -Force }

    $sums = Get-ChildItem -Path $outDir -File | Sort-Object Name | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name
    }
    $sums | Set-Content -Path $sumsPath -Encoding UTF8

    Write-Host ''
    $sums | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
}

function Invoke-CompileTask {
    <#
        Merges Private/ then Public/ into a single .psm1.

        The source module dot-sources 60-odd files at import, which is right for
        development - edit one file, re-import, done - and wrong for a shipped
        module, where it means 60 file opens and 60 parses on every import,
        including every time the GUI starts.

        The merged module is what ships. The source tree keeps dot-sourcing, and
        tests/Compile.Tests.ps1 asserts the two export exactly the same surface
        so they cannot drift apart.
    #>
    param([string]$OutputRoot)

    Write-Step 'Compiling the module into a single file'

    $source = Join-Path $RepoRoot 'src/PCTools'
    if (-not $OutputRoot) { $OutputRoot = Join-Path $RepoRoot 'obj/PCTools' }

    if (Test-Path $OutputRoot) { Remove-Item $OutputRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

    $manifestPath = Join-Path $source 'PCTools.psd1'
    $version = (Import-PowerShellDataFile $manifestPath).ModuleVersion

    $loader = Get-Content -LiteralPath (Join-Path $source 'PCTools.psm1') -Raw

    # Everything from the dot-sourcing loop to the end is replaced by the merged
    # function bodies; the prologue above it (strict mode, paths, module state)
    # is kept exactly as written.
    $marker = '# Dot-source Private first: Public functions depend on those helpers.'
    $index = $loader.IndexOf($marker)
    if ($index -lt 0) { throw "The module loader has changed shape: '$marker' was not found in PCTools.psm1." }

    $prologue = $loader.Substring(0, $index)

    # Stamp the version so the shipped module does not re-read its own manifest
    # on every import.
    $prologue = $prologue.Replace("'{{MODULE_VERSION}}'", "'$version'")
    if ($prologue -match '\{\{MODULE_VERSION\}\}') {
        throw 'The version placeholder was not replaced; check the loader prologue.'
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine($prologue.TrimEnd())
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('# ---------------------------------------------------------------------')
    [void]$builder.AppendLine('# Generated by build/Invoke-Build.ps1 -Task Compile. Do not edit:')
    [void]$builder.AppendLine('# change the files under src/PCTools/Private and src/PCTools/Public.')
    [void]$builder.AppendLine('# ---------------------------------------------------------------------')
    [void]$builder.AppendLine()

    $publicNames = [System.Collections.Generic.List[string]]::new()

    foreach ($folder in 'Private', 'Public') {
        $folderPath = Join-Path $source $folder
        if (-not (Test-Path $folderPath)) { continue }

        foreach ($file in (Get-ChildItem -LiteralPath $folderPath -Recurse -Filter '*.ps1' -File | Sort-Object FullName)) {
            [void]$builder.AppendLine("#region $folder/$($file.BaseName)")
            [void]$builder.AppendLine((Get-Content -LiteralPath $file.FullName -Raw).TrimEnd())
            [void]$builder.AppendLine('#endregion')
            [void]$builder.AppendLine()

            if ($folder -eq 'Public') { $publicNames.Add($file.BaseName) }
        }
    }

    [void]$builder.AppendLine('$script:PublicFunctionName = @(')
    foreach ($name in $publicNames) { [void]$builder.AppendLine("    '$name'") }
    [void]$builder.AppendLine(')')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('$script:PublicAliasName = [System.Collections.Generic.List[string]]::new()')
    [void]$builder.AppendLine('foreach ($name in $script:PublicFunctionName) {')
    [void]$builder.AppendLine('    $command = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue')
    [void]$builder.AppendLine('    if (-not $command) { continue }')
    [void]$builder.AppendLine('    foreach ($attribute in $command.ScriptBlock.Attributes) {')
    [void]$builder.AppendLine('        if ($attribute -is [System.Management.Automation.AliasAttribute]) {')
    [void]$builder.AppendLine('            foreach ($alias in $attribute.AliasNames) { $script:PublicAliasName.Add($alias) }')
    [void]$builder.AppendLine('        }')
    [void]$builder.AppendLine('    }')
    [void]$builder.AppendLine('}')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('Export-ModuleMember -Function $script:PublicFunctionName -Alias $script:PublicAliasName')

    $merged = $builder.ToString()

    # A merged file that does not parse would ship a module nobody can import.
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($merged, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        $detail = ($parseErrors | Select-Object -First 5 | ForEach-Object {
            'Line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Message
        }) -join [Environment]::NewLine
        throw "The compiled module does not parse:$([Environment]::NewLine)$detail"
    }

    # UTF-8 with a BOM: Windows PowerShell 5.1 reads a BOM-less file as ANSI.
    $encoding = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText((Join-Path $OutputRoot 'PCTools.psm1'), $merged, $encoding)

    Copy-Item $manifestPath -Destination $OutputRoot

    # The GUI ships inside the module, so it comes along.
    $shell = Join-Path $source 'Shell'
    if (Test-Path $shell) { Copy-Item $shell -Destination $OutputRoot -Recurse }

    Write-Host ("Compiled {0} function(s) into {1}" -f $publicNames.Count, (Join-Path $OutputRoot 'PCTools.psm1')) -ForegroundColor Green
    $OutputRoot
}

function Invoke-DocsTask {
    <#
        Regenerates docs/COMMANDS.md from the module's own help, so the command
        reference cannot describe a command that no longer exists or miss one
        that was just added.
    #>
    Write-Step 'Generating the command reference'

    Import-Module (Join-Path $RepoRoot 'src/PCTools/PCTools.psd1') -Force

    $module = Get-Module PCTools
    $commands = $module.ExportedFunctions.Keys | Sort-Object

    $source = Join-Path $RepoRoot 'src/PCTools/Public'
    $folderOf = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $source -Recurse -Filter '*.ps1' -File)) {
        $folder = Split-Path -Leaf $file.DirectoryName
        $folderOf[$file.BaseName] = $(if ($folder -eq 'Public') { 'Entry points and orchestration' } else { $folder })
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# PCTools command reference')
    $lines.Add('')
    $lines.Add("Generated from the module's own help by ``./build/Invoke-Build.ps1 -Task Docs``.")
    $lines.Add("Do not edit by hand - edit the comment-based help on the command instead.")
    $lines.Add('')
    $lines.Add("PCTools $($module.Version) exports $($commands.Count) commands.")
    $lines.Add('')

    foreach ($group in ($commands | Group-Object { $folderOf[$_] } | Sort-Object Name)) {
        $lines.Add("## $($group.Name)")
        $lines.Add('')
        $lines.Add('| Command | What it does | Supports -WhatIf |')
        $lines.Add('|---|---|---|')

        foreach ($name in ($group.Group | Sort-Object)) {
            $help = Get-Help $name -ErrorAction SilentlyContinue
            $synopsis = if ($help -and $help.Synopsis) { ($help.Synopsis -replace '\s+', ' ').Trim() } else { '' }
            $synopsis = $synopsis -replace '\|', '\|'

            $command = Get-Command $name
            $supportsWhatIf = if ($command.Parameters.ContainsKey('WhatIf')) { 'yes' } else { '' }

            $lines.Add("| ``$name`` | $synopsis | $supportsWhatIf |")
        }
        $lines.Add('')
    }

    $docsDir = Join-Path $RepoRoot 'docs'
    if (-not (Test-Path $docsDir)) { New-Item -ItemType Directory -Path $docsDir -Force | Out-Null }

    $path = Join-Path $docsDir 'COMMANDS.md'

    # UTF-8 without a BOM, and LF endings, written the same way on every host.
    # Set-Content -Encoding UTF8 writes a BOM on Windows PowerShell 5.1 and none
    # on PowerShell 7, so the generated file differed by three bytes depending
    # on who ran the task - which is exactly what the CI freshness check then
    # reported as "out of date".
    $text = ($lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))

    Write-Host "Wrote $path ($($commands.Count) commands)" -ForegroundColor Green
}

function Invoke-BenchTask {
    Write-Step 'Measuring'
    & (Join-Path $PSScriptRoot 'Measure-Performance.ps1') -OutputPath (Join-Path $PSScriptRoot 'benchmark.json')
}

switch ($Task) {
    'Test'     { Invoke-TestTask }
    'Analyze'  { Invoke-AnalyzeTask }
    'Compile'  { $null = Invoke-CompileTask }
    'Docs'     { Invoke-DocsTask }
    'Release'  { Invoke-ReleaseTask }
    'Checksum' { Invoke-ChecksumTask }
    'Bench'    { Invoke-BenchTask }
    'All'      { Invoke-TestTask; Invoke-AnalyzeTask }
}

Write-Host ''
Write-Host "Build task '$Task' completed." -ForegroundColor Green
