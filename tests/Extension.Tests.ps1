#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
    The extension model, which is the newest and least conventional part of the
    module: an action defined in a file on disk, loaded into the module's scope,
    and reachable from a maintenance profile.

    Every test here corresponds to something that was actually wrong during
    development. Loading appeared to succeed while leaving the action
    uncallable; a single extension file assigned as a scalar rather than an
    array; and the question of whether an extension could quietly replace a
    built-in command needed an answer that was checked rather than asserted.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot

    # A throwaway data root, so the test never reads or writes the real
    # %LOCALAPPDATA%\PCTools and never sees a developer's own extensions.
    $script:SandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pctools-ext-{0}" -f [guid]::NewGuid().ToString('N'))
    $script:OriginalLocalAppData = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $script:SandboxRoot

    $script:ExtensionDir = Join-Path $script:SandboxRoot 'PCTools\extensions'
    New-Item -ItemType Directory -Path $script:ExtensionDir -Force | Out-Null

    Import-Module (Join-Path $script:RepoRoot 'src/PCTools/PCTools.psd1') -Force
    $script:Module = Get-Module PCTools
}

AfterAll {
    Remove-Module PCTools -Force -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $script:OriginalLocalAppData
    Remove-Item -LiteralPath $script:SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Register-PCExtension' {

    It 'loads a single extension file' {
        # One file is the normal case, and the one that broke: assigning the
        # result of an `if` unrolled the one-element array to a scalar, and
        # .Count on a string is a strict-mode error.
        @'
function Invoke-PCExtensionAlpha {
    [CmdletBinding()]
    param([long]$Freed = 4096)
    Invoke-PCAction -Name 'Invoke-PCExtensionAlpha' -Body {
        @{ Status = 'Success'; Detail = 'alpha ran'; BytesFreed = $Freed }
    }
}
'@ | Set-Content -LiteralPath (Join-Path $script:ExtensionDir 'alpha.PCAction.ps1')

        $loaded = @(Register-PCExtension -PassThru -Confirm:$false)

        $loaded.Count | Should -Be 1
        $loaded[0].Name | Should -Be 'Invoke-PCExtensionAlpha'
    }

    It 'gives the extension access to the module private helpers' {
        # An extension action is only useful if it can call Invoke-PCAction, so
        # that its result has the same shape as a built-in's. That requires the
        # scriptblock to belong to the module's session state.
        $result = Invoke-PCMaintenance -Action 'Invoke-PCExtensionAlpha' -SkipRestorePoint -Confirm:$false

        $result.PSObject.TypeNames | Should -Contain 'PCTools.ActionResult'
        $result.Action | Should -Be 'Invoke-PCExtensionAlpha'
        $result.Status | Should -Be 'Success'
        $result.BytesFreed | Should -Be 4096
        $result.FreedDisplay | Should -Be '4.0 KB'
    }

    It 'is usable from a JSON profile, with parameters' {
        $configPath = Join-Path $script:SandboxRoot 'profile.json'
        @'
{
  "profiles": [
    {
      "name": "ExtensionProfile",
      "description": "Runs an extension action",
      "restorePoint": false,
      "actions": [ { "action": "Invoke-PCExtensionAlpha", "parameters": { "Freed": 8192 } } ]
    }
  ]
}
'@ | Set-Content -LiteralPath $configPath

        # Import must accept the extension name: validating only against
        # exported commands would reject a profile that works.
        { Import-PCConfiguration -Path $configPath } | Should -Not -Throw

        $results = @(Invoke-PCMaintenance -ProfileName 'ExtensionProfile' -SkipRestorePoint -Confirm:$false)
        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'Success'
        $results[0].BytesFreed | Should -Be 8192
    }

    It 'reports a registered extension through Get-PCExtension' {
        $listed = @(Get-PCExtension | Where-Object Name -eq 'Invoke-PCExtensionAlpha')
        $listed.Count | Should -Be 1
        $listed[0].Loaded | Should -BeTrue
    }

    It 'refuses an extension that would replace a built-in command' {
        @'
function Clear-PCTempFile {
    'hijacked'
}
'@ | Set-Content -LiteralPath (Join-Path $script:ExtensionDir 'hijack.PCAction.ps1')

        Register-PCExtension -Confirm:$false -WarningAction SilentlyContinue | Out-Null

        # The real command must still be the module's own.
        $command = Get-Command Clear-PCTempFile
        $command.Source | Should -Be 'PCTools'
        $command.Parameters.Keys | Should -Contain 'IncludeSystemTemp'

        Remove-Item -LiteralPath (Join-Path $script:ExtensionDir 'hijack.PCAction.ps1') -Force
    }

    It 'skips a file that does not parse, without failing the rest' {
        @'
function Invoke-PCExtensionBroken {
    param(
'@ | Set-Content -LiteralPath (Join-Path $script:ExtensionDir 'broken.PCAction.ps1')

        @'
function Invoke-PCExtensionBeta {
    [CmdletBinding()]
    param()
    Invoke-PCAction -Name 'Invoke-PCExtensionBeta' -Body { @{ Detail = 'beta ran' } }
}
'@ | Set-Content -LiteralPath (Join-Path $script:ExtensionDir 'beta.PCAction.ps1')

        Register-PCExtension -Confirm:$false -WarningAction SilentlyContinue | Out-Null

        # The good file next to the broken one still loaded.
        @(Get-PCExtension | Where-Object { $_.Name -eq 'Invoke-PCExtensionBeta' -and $_.Loaded }).Count |
            Should -Be 1
        @(Get-PCExtension | Where-Object { $_.Name -eq 'Invoke-PCExtensionBroken' -and $_.Loaded }).Count |
            Should -Be 0

        Remove-Item -LiteralPath (Join-Path $script:ExtensionDir 'broken.PCAction.ps1') -Force
    }

    It 'ignores a file defining no PC action' {
        @'
function Get-SomethingElse { 'not a PC action' }
'@ | Set-Content -LiteralPath (Join-Path $script:ExtensionDir 'notanaction.PCAction.ps1')

        Register-PCExtension -Confirm:$false -WarningAction SilentlyContinue | Out-Null
        @(Get-PCExtension | Where-Object { $_.Name -eq 'Get-SomethingElse' }).Count | Should -Be 0

        Remove-Item -LiteralPath (Join-Path $script:ExtensionDir 'notanaction.PCAction.ps1') -Force
    }

    It 'previews under -WhatIf without loading anything' {
        @'
function Invoke-PCExtensionGamma {
    [CmdletBinding()]
    param()
    Invoke-PCAction -Name 'Invoke-PCExtensionGamma' -Body { @{ Detail = 'gamma ran' } }
}
'@ | Set-Content -LiteralPath (Join-Path $script:ExtensionDir 'gamma.PCAction.ps1')

        Register-PCExtension -WhatIf | Out-Null
        @(Get-PCExtension | Where-Object { $_.Name -eq 'Invoke-PCExtensionGamma' -and $_.Loaded }).Count |
            Should -Be 0
    }

    It 'throws for a named file that does not exist' {
        { Register-PCExtension -Path (Join-Path $script:SandboxRoot 'nope.PCAction.ps1') -Confirm:$false } |
            Should -Throw
    }
}

Describe 'Unregistered action names' {

    It 'fail with a message naming the extension list' {
        $result = Invoke-PCMaintenance -Action 'Invoke-PCNeverRegistered' -SkipRestorePoint -Confirm:$false
        $result.Status | Should -Be 'Failed'
        $result.Detail | Should -Match 'Get-PCExtension'
    }

    It 'are rejected at config import rather than partway through a run' {
        $configPath = Join-Path $script:SandboxRoot 'bad-profile.json'
        @'
{
  "profiles": [
    { "name": "Bad", "restorePoint": false, "actions": [ { "action": "Invoke-PCNotAThing" } ] }
  ]
}
'@ | Set-Content -LiteralPath $configPath

        { Import-PCConfiguration -Path $configPath } | Should -Throw
    }
}
