#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
    Unit tests for the platform-independent logic inside PCTools.

    These run anywhere, including Linux CI, because the functions under test
    take data and return data rather than touching Windows. That separation is
    the point of the module extraction: none of this was testable while it
    lived inside a WinForms click handler.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/PCTools/PCTools.psd1') -Force
    $script:Module = Get-Module PCTools
}

AfterAll {
    Remove-Module PCTools -Force -ErrorAction SilentlyContinue
}

Describe 'Format-PCByteSize' {

    It 'formats <Bytes> as <Expected>' -ForEach @(
        @{ Bytes = 0L;          Expected = '0 B' }
        @{ Bytes = 512L;        Expected = '512 B' }
        @{ Bytes = 1023L;       Expected = '1023 B' }
        @{ Bytes = 1024L;       Expected = '1.0 KB' }
        @{ Bytes = 5242880L;    Expected = '5.0 MB' }
        @{ Bytes = 4509715660L; Expected = '4.2 GB' }
    ) {
        & $script:Module { param($b) Format-PCByteSize -Bytes $b } $Bytes | Should -Be $Expected
    }

    It 'returns a placeholder for null rather than throwing' {
        & $script:Module { Format-PCByteSize -Bytes $null } | Should -Be '-'
    }
}

Describe 'Subnet mask conversion' {

    It 'converts <Mask> to /<Prefix>' -ForEach @(
        @{ Mask = '255.0.0.0';       Prefix = 8 }
        @{ Mask = '255.255.0.0';     Prefix = 16 }
        @{ Mask = '255.255.255.0';   Prefix = 24 }
        @{ Mask = '255.255.255.252'; Prefix = 30 }
        @{ Mask = '0.0.0.0';         Prefix = 0 }
    ) {
        & $script:Module { param($m) ConvertTo-PCPrefixLength -SubnetMask $m } $Mask | Should -Be $Prefix
    }

    It 'round-trips /<Prefix> back to <Mask>' -ForEach @(
        @{ Mask = '255.0.0.0';       Prefix = 8 }
        @{ Mask = '255.255.255.0';   Prefix = 24 }
        @{ Mask = '255.255.255.252'; Prefix = 30 }
    ) {
        & $script:Module { param($p) ConvertFrom-PCPrefixLength -PrefixLength $p } $Prefix | Should -Be $Mask
    }

    It 'rejects a non-contiguous mask' {
        # 255.0.255.0 is not a valid mask. The original tool passed whatever the
        # user typed straight to netsh.
        { & $script:Module { ConvertTo-PCPrefixLength -SubnetMask '255.0.255.0' } } |
            Should -Throw -ExpectedMessage '*contiguous*'
    }
}

Describe 'Invoke-PCAction' {

    It 'produces a Success result from a body that returns detail' {
        $result = & $script:Module {
            Invoke-PCAction -Name 'Demo' -Body { @{ Detail = 'done'; BytesFreed = 2048 } }
        }

        $result.Action | Should -Be 'Demo'
        $result.Status | Should -Be 'Success'
        $result.Detail | Should -Be 'done'
        $result.BytesFreed | Should -Be 2048
        $result.FreedDisplay | Should -Be '2.0 KB'
    }

    It 'converts a thrown exception into a Failed result instead of terminating' {
        # This is what lets a batch of actions report all of its outcomes rather
        # than stopping at the first failure.
        $result = & $script:Module {
            Invoke-PCAction -Name 'Boom' -Body { throw 'kaboom' }
        }

        $result.Status | Should -Be 'Failed'
        $result.Detail | Should -Be 'kaboom'
        $result.ErrorRecord | Should -Not -BeNullOrEmpty
    }

    It 'records a duration' {
        $result = & $script:Module {
            Invoke-PCAction -Name 'Timed' -Body { Start-Sleep -Milliseconds 60; @{ Detail = 'ok' } }
        }

        $result.Duration.TotalMilliseconds | Should -BeGreaterThan 40
    }

    It 'carries RebootRequired through to the result' {
        $result = & $script:Module {
            Invoke-PCAction -Name 'NeedsReboot' -Body { @{ Detail = 'ok'; RebootRequired = $true } }
        }

        $result.RebootRequired | Should -BeTrue
    }
}

Describe 'Get-PCConnectivityVerdict' {

    BeforeAll {
        $script:MakeTests = {
            param([hashtable]$LayerState)
            $LayerState.GetEnumerator() | ForEach-Object {
                [pscustomobject]@{ Layer = $_.Key; Target = 'x'; Success = $_.Value; Detail = ''; LatencyMs = $null }
            }
        }
    }

    It 'reports Healthy when every layer passes' {
        $tests = & $script:MakeTests @{ Adapter = $true; Gateway = $true; Internet = $true; DNS = $true; TCP = $true }
        $verdict = & $script:Module { param($t) Get-PCConnectivityVerdict -TestResult $t } $tests

        $verdict.Verdict | Should -Be 'Healthy'
        $verdict.Healthy | Should -BeTrue
    }

    It 'blames DNS when routing works but resolution fails' {
        $tests = & $script:MakeTests @{ Adapter = $true; Gateway = $true; Internet = $true; DNS = $false; TCP = $false }
        $verdict = & $script:Module { param($t) Get-PCConnectivityVerdict -TestResult $t } $tests

        $verdict.Verdict | Should -Be 'DNS is not resolving'
        $verdict.Healthy | Should -BeFalse
    }

    It 'blames the router when the gateway does not reply' {
        # The first failing layer is the diagnosis, so a dead gateway must not
        # be reported as "no internet".
        $tests = & $script:MakeTests @{ Adapter = $true; Gateway = $false; Internet = $false; DNS = $false; TCP = $false }
        $verdict = & $script:Module { param($t) Get-PCConnectivityVerdict -TestResult $t } $tests

        $verdict.Verdict | Should -Be 'No route to the router'
    }

    It 'blames the adapter when nothing is up' {
        $tests = & $script:MakeTests @{ Adapter = $false; Gateway = $false; Internet = $false; DNS = $false; TCP = $false }
        $verdict = & $script:Module { param($t) Get-PCConnectivityVerdict -TestResult $t } $tests

        $verdict.Verdict | Should -Be 'No network adapter'
    }

    It 'blames filtering when DNS resolves but TCP fails' {
        $tests = & $script:MakeTests @{ Adapter = $true; Gateway = $true; Internet = $true; DNS = $true; TCP = $false }
        $verdict = & $script:Module { param($t) Get-PCConnectivityVerdict -TestResult $t } $tests

        $verdict.Verdict | Should -Be 'Traffic is being blocked'
    }

    It 'counts passed and failed tests' {
        $tests = & $script:MakeTests @{ Adapter = $true; Gateway = $true; Internet = $false; DNS = $false; TCP = $false }
        $verdict = & $script:Module { param($t) Get-PCConnectivityVerdict -TestResult $t } $tests

        $verdict.Passed | Should -Be 2
        $verdict.Failed | Should -Be 3
        $verdict.FailedTests.Count | Should -Be 3
    }
}

Describe 'Maintenance profiles' {

    It 'defines the built-in profiles, in order' {
        # Order is part of the contract: the GUI's profile list and the README
        # table both present them least to most invasive.
        (Get-PCMaintenanceProfile).Name |
            Should -Be @('Quick', 'Recommended', 'Full', 'Storage', 'Health', 'Weekly', 'NetworkRepair')
    }

    It 'keeps the irreversible actions out of every built-in profile' {
        # Removing the previous Windows installation, clearing the event log and
        # uninstalling apps all give up something that cannot be got back. Each
        # has to be asked for by name; none may arrive as part of a preset.
        $irreversible = @('Clear-PCWindowsOld', 'Clear-PCEventLog', 'Remove-PCAppxPackage', 'Set-PCServiceStartup')

        foreach ($profileEntry in (Get-PCMaintenanceProfile)) {
            foreach ($step in $profileEntry.Actions) {
                $irreversible | Should -Not -Contain $step.Action `
                    -Because "profile $($profileEntry.Name) must not include an irreversible action"
            }
        }
    }

    It 'offers a read-only Health profile that changes nothing' {
        $health = Get-PCMaintenanceProfile -Name 'Health'
        $health.RestorePoint | Should -BeFalse

        foreach ($step in $health.Actions) {
            # Every action in Health either only reads, or is explicitly told to
            # scan rather than repair.
            $isScanOnly = $step.ContainsKey('Parameters') -and $step.Parameters.ContainsKey('ScanOnly')
            $isScanOnly | Should -BeTrue -Because "$($step.Action) must be scan-only in the Health profile"
        }
    }

    It 'throws a helpful error for an unknown profile' {
        { Get-PCMaintenanceProfile -Name 'Nonexistent' } |
            Should -Throw -ExpectedMessage '*Available: Quick, Recommended, Full, Storage, Health, Weekly, NetworkRepair*'
    }

    It 'keeps Prefetch cleanup out of every built-in profile' {
        # Clearing Prefetch costs launch performance for a small disk saving. It
        # stays available, but nobody should get it by picking a preset.
        $allActions = (Get-PCMaintenanceProfile).Actions.Action
        $allActions | Should -Not -Contain 'Clear-PCPrefetchCache'
    }

    It 'keeps the network stack reset out of the general-purpose profiles' {
        $general = Get-PCMaintenanceProfile | Where-Object Name -in 'Quick', 'Recommended', 'Full'
        $general.Actions.Action | Should -Not -Contain 'Reset-PCNetworkStack'
    }

    It 'requires a restore point for every profile that repairs or resets' {
        $risky = Get-PCMaintenanceProfile | Where-Object Name -in 'Recommended', 'Full', 'NetworkRepair'
        foreach ($item in $risky) {
            $item.RestorePoint | Should -BeTrue -Because "$($item.Name) changes system state"
        }
    }

    It 'names only actions the module actually exports' {
        $exported = (Get-Module PCTools).ExportedFunctions.Keys
        foreach ($item in Get-PCMaintenanceProfile) {
            foreach ($step in $item.Actions) {
                $exported | Should -Contain $step.Action -Because "profile $($item.Name) references it"
            }
        }
    }
}

Describe 'Preference definitions' {

    It 'gives every preference at least one registry value' {
        foreach ($definition in & $script:Module { Get-PCPreferenceDefinition }) {
            @($definition.Values).Count | Should -BeGreaterThan 0
        }
    }

    It 'gives every registry value a default to revert to' {
        # This is what makes preferences reversible. The original tool could
        # only apply them.
        foreach ($definition in & $script:Module { Get-PCPreferenceDefinition }) {
            foreach ($value in $definition.Values) {
                $value.ContainsKey('Default') | Should -BeTrue -Because "$($definition.Name)/$($value.Property) must be revertible"
                $value.Default | Should -Not -BeNullOrEmpty -Because 'a default of 0 should be written as its string form'
            }
        }
    }

    It 'never sets a value equal to its default' {
        foreach ($definition in & $script:Module { Get-PCPreferenceDefinition }) {
            foreach ($value in $definition.Values) {
                [string]$value.Enabled | Should -Not -Be ([string]$value.Default) -Because "$($definition.Name)/$($value.Property) would be a no-op"
            }
        }
    }

    It 'uses unique preference names' {
        $names = (& $script:Module { Get-PCPreferenceDefinition }).Name
        ($names | Sort-Object -Unique).Count | Should -Be $names.Count
    }
}

Describe 'Log sinks' {

    It 'delivers log lines to a registered sink' {
        $captured = [System.Collections.Generic.List[object]]::new()
        $id = Register-PCLogSink { param($entry) $captured.Add($entry) }

        try {
            & $script:Module { Write-PCLog -Level WARN -Message 'sink test' }
        }
        finally {
            Unregister-PCLogSink -Id $id
        }

        $captured.Count | Should -BeGreaterThan 0
        $captured[-1].Message | Should -Be 'sink test'
        $captured[-1].Level | Should -Be 'WARN'
    }

    It 'stops delivering after the sink is unregistered' {
        $captured = [System.Collections.Generic.List[object]]::new()
        $id = Register-PCLogSink { param($entry) $captured.Add($entry) }
        Unregister-PCLogSink -Id $id

        & $script:Module { Write-PCLog -Message 'after unregister' }

        $captured.Count | Should -Be 0
    }

    It 'survives a sink that throws' {
        # A broken UI callback must not take down the action that logged.
        $id = Register-PCLogSink { throw 'sink is broken' }

        try {
            { & $script:Module { Write-PCLog -Message 'still fine' } } | Should -Not -Throw
        }
        finally {
            Unregister-PCLogSink -Id $id
        }
    }
}
