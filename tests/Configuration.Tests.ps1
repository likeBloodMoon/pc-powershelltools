#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
    Tests for user-supplied JSON configuration and the profile lookup it feeds.

    A config file is the one place a user's own text becomes executable
    behaviour, so every rejection path is covered: a bad action name must fail
    at import, not halfway through a maintenance run.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/PCTools/PCTools.psd1') -Force

    $script:ConfigDir = Join-Path ([System.IO.Path]::GetTempPath()) "pctools-tests-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null

    function New-ConfigFile {
        param([string]$Name, [string]$Content)
        $path = Join-Path $script:ConfigDir $Name
        Set-Content -LiteralPath $path -Value $Content -Encoding UTF8
        $path
    }
}

AfterAll {
    Remove-Item $script:ConfigDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Module PCTools -Force -ErrorAction SilentlyContinue
}

Describe 'Import-PCConfiguration' {

    It 'loads profiles and parses their parameters' {
        $path = New-ConfigFile 'good.json' @'
{
  "profiles": [
    {
      "name": "Weekly",
      "description": "Friday routine",
      "restorePoint": false,
      "actions": [
        { "action": "Clear-PCTempFile" },
        { "action": "Clear-PCBrowserCache", "parameters": { "Browser": ["Chrome", "Edge"] } }
      ]
    }
  ]
}
'@
        $loaded = @(Import-PCConfiguration -Path $path)

        $loaded.Count | Should -Be 1
        $loaded[0].Name | Should -Be 'Weekly'
        $loaded[0].RestorePoint | Should -BeFalse
        $loaded[0].Actions[1].Parameters.Browser | Should -Be @('Chrome', 'Edge')
    }

    It 'defaults restorePoint to true when the file omits it' {
        # The safe default has to be the implicit one.
        $path = New-ConfigFile 'default.json' '{ "profiles": [ { "name": "D", "actions": [ { "action": "Clear-PCDnsCache" } ] } ] }'
        (Import-PCConfiguration -Path $path).RestorePoint | Should -BeTrue
    }

    It 'rejects an action the module does not export' {
        $path = New-ConfigFile 'typo.json' '{ "profiles": [ { "name": "Bad", "actions": [ { "action": "Clear-PCTypo" } ] } ] }'
        { Import-PCConfiguration -Path $path } | Should -Throw -ExpectedMessage '*Clear-PCTypo*neither a PCTools command nor a registered extension*'
    }

    It 'rejects a profile with no actions' {
        $path = New-ConfigFile 'empty.json' '{ "profiles": [ { "name": "Empty" } ] }'
        { Import-PCConfiguration -Path $path } | Should -Throw -ExpectedMessage '*no actions*'
    }

    It 'rejects a profile with no name' {
        $path = New-ConfigFile 'noname.json' '{ "profiles": [ { "actions": [ { "action": "Clear-PCDnsCache" } ] } ] }'
        { Import-PCConfiguration -Path $path } | Should -Throw -ExpectedMessage '*no name*'
    }

    It 'rejects a file that is not JSON' {
        $path = New-ConfigFile 'broken.json' 'this is not json'
        { Import-PCConfiguration -Path $path } | Should -Throw -ExpectedMessage '*not valid JSON*'
    }

    It 'rejects JSON with no profiles array' {
        $path = New-ConfigFile 'noprofiles.json' '{ "something": 1 }'
        { Import-PCConfiguration -Path $path } | Should -Throw -ExpectedMessage "*no 'profiles' array*"
    }

    It 'rejects a missing file' {
        { Import-PCConfiguration -Path (Join-Path $script:ConfigDir 'nope.json') } |
            Should -Throw -ExpectedMessage '*No configuration file*'
    }
}

Describe 'Imported profiles and Get-PCMaintenanceProfile' {

    AfterEach {
        # Clear imported state so each test starts from the built-ins.
        $empty = New-ConfigFile 'reset.json' '{ "profiles": [ { "name": "Reset", "actions": [ { "action": "Clear-PCDnsCache" } ] } ] }'
        Import-PCConfiguration -Path $empty | Out-Null
        & (Get-Module PCTools) { $script:PCImportedProfile = @() }
    }

    It 'lists imported profiles alongside the built-ins' {
        $path = New-ConfigFile 'extra.json' '{ "profiles": [ { "name": "Weekly", "actions": [ { "action": "Clear-PCTempFile" } ] } ] }'
        Import-PCConfiguration -Path $path | Out-Null

        $names = (Get-PCMaintenanceProfile).Name
        $names | Should -Contain 'Weekly'
        $names | Should -Contain 'Full'
    }

    It 'lets a user profile override a built-in of the same name' {
        $path = New-ConfigFile 'override.json' '{ "profiles": [ { "name": "Quick", "description": "Mine", "actions": [ { "action": "Clear-PCDnsCache" } ] } ] }'
        Import-PCConfiguration -Path $path | Out-Null

        (Get-PCMaintenanceProfile -Name Quick).Description | Should -Be 'Mine'
        @((Get-PCMaintenanceProfile) | Where-Object Name -eq 'Quick').Count | Should -Be 1
    }

    It 'replaces the previous import rather than accumulating' {
        $first = New-ConfigFile 'first.json' '{ "profiles": [ { "name": "First", "actions": [ { "action": "Clear-PCTempFile" } ] } ] }'
        Import-PCConfiguration -Path $first | Out-Null

        $second = New-ConfigFile 'second.json' '{ "profiles": [ { "name": "Second", "actions": [ { "action": "Clear-PCDnsCache" } ] } ] }'
        Import-PCConfiguration -Path $second | Out-Null

        $names = (Get-PCMaintenanceProfile).Name
        $names | Should -Not -Contain 'First'
        $names | Should -Contain 'Second'
    }
}

Describe 'New network diagnostics' {

    It 'Test-PCRoute numbers hops from 1 and stops at MaxHops' {
        $hops = @(Test-PCRoute -Target '203.0.113.1' -MaxHops 3 -TimeoutSeconds 1)

        $hops.Count | Should -BeLessOrEqual 3
        if ($hops.Count -gt 0) {
            $hops[0].Hop | Should -Be 1
            $hops[0].PSObject.TypeNames | Should -Contain 'PCTools.RouteHop'
        }
    }

    It 'Test-PCMtu reports rather than throws when the target ignores ICMP' {
        # 203.0.113.0/24 is TEST-NET-3 and is guaranteed not to answer.
        $probe = Test-PCMtu -Target '203.0.113.1' -TimeoutSeconds 1

        $probe | Should -Not -BeNullOrEmpty
        $probe.PSObject.TypeNames | Should -Contain 'PCTools.MtuProbe'
        $probe.Detail | Should -Not -BeNullOrEmpty
    }
}
