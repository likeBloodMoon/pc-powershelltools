<#
    PCTools - the shared engine behind the pc-powershelltools GUIs.

    Every action lives here rather than inside a WinForms event handler, which
    is what makes the same code usable from the GUI, from a console session and
    from a scheduled task, and testable without a UI.
#>

Set-StrictMode -Version Latest

$script:ModuleName = 'PCTools'

# The build stamps the version in when it compiles the shipping module, so a
# release does not re-read and re-parse its own manifest on every import. From
# a source checkout there is nothing to stamp, so fall back to the manifest.
$script:ModuleVersion = '{{MODULE_VERSION}}'

if ($script:ModuleVersion -like '{{*') {
    # Not stamped, so this is a source checkout rather than a built module.
    try {
        $script:ModuleVersion = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'PCTools.psd1')).ModuleVersion
    }
    catch {
        $script:ModuleVersion = '0.0.0'
    }
}

# $IsWindows exists in PowerShell 6+ only. On Windows PowerShell 5.1 the host
# is Windows by definition. This lets the module import on Linux CI so the
# platform-independent logic can be unit-tested there.
$script:IsWindowsPlatform = if ($null -eq (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) {
    $true
}
else {
    $IsWindows
}

# Log destination: %LOCALAPPDATA%\PCTools\logs, or the temp folder off-Windows.
$script:PCDataRoot = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'PCTools'
}
else {
    Join-Path ([System.IO.Path]::GetTempPath()) 'PCTools'
}

$script:PCLogDirectory = Join-Path $script:PCDataRoot 'logs'
$script:PCHistoryDirectory = Join-Path $script:PCDataRoot 'history'
$script:PCExtensionDirectory = Join-Path $script:PCDataRoot 'extensions'
$script:PCLogPath = $null
$script:PCLogSinkTable = @{}
$script:PCLogSinks = @()

# Set once the log file has been prepared. Preparing it costs a directory
# probe, a file stat and possibly a rotation, and importing the module is not
# the moment to spend that - a session that only calls Get-PCPreference never
# writes a log line at all. Initialize-PCLog does the work on first write.
$script:PCLogReady = $false

# Maintenance profiles loaded from a user's JSON config, if any.
$script:PCImportedProfile = @()

# Set by Invoke-PCTools so a caller can read the last computed exit code.
$script:PCLastExitCode = 0

# Extension actions loaded from disk by Register-PCExtension, keyed by name.
$script:PCExtension = @{}

# Dot-source Private first: Public functions depend on those helpers.
$script:PublicFunctionName = [System.Collections.Generic.List[string]]::new()

foreach ($folder in 'Private', 'Public') {
    $root = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path -LiteralPath $root)) { continue }

    $files = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File | Sort-Object FullName

    foreach ($file in $files) {
        try {
            . $file.FullName
        }
        catch {
            throw "PCTools: failed to load $($file.Name): $($_.Exception.Message)"
        }

        if ($folder -eq 'Public') {
            # One public function per file, named after the file. The manifest
            # lists the same names, so a file added without a manifest entry
            # fails the Manifest Pester test rather than leaking silently.
            $script:PublicFunctionName.Add($file.BaseName)
        }
    }
}

# Aliases declared with [Alias()] on a public function are exported too, so the
# manifest's AliasesToExport has something to find. Read from the functions
# actually loaded rather than a hand-kept list, which would drift.
$script:PublicAliasName = [System.Collections.Generic.List[string]]::new()

foreach ($name in $script:PublicFunctionName) {
    $command = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
    if (-not $command) { continue }

    foreach ($attribute in $command.ScriptBlock.Attributes) {
        if ($attribute -is [System.Management.Automation.AliasAttribute]) {
            foreach ($alias in $attribute.AliasNames) { $script:PublicAliasName.Add($alias) }
        }
    }
}

Export-ModuleMember -Function $script:PublicFunctionName -Alias $script:PublicAliasName
