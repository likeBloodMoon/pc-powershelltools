#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
    The v0.5 commands that can do real damage, and the guards that stop them.

    Remove-PCAppxPackage and Set-PCServiceStartup are the sharpest edges added in
    this release: one uninstalls software, the other can leave a machine without
    a firewall or unable to boot. Both are allowlist-driven, and an allowlist is
    only worth anything if something checks what is on it.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/PCTools/PCTools.psd1') -Force
    $script:Module = Get-Module PCTools
}

AfterAll {
    Remove-Module PCTools -Force -ErrorAction SilentlyContinue
}

Describe 'Critical service list' {

    It 'protects the services that break a machine outright' {
        $critical = & $script:Module { Get-PCCriticalServiceName }

        # Each of these has a specific, well-known failure: no firewall, no
        # boot, no updates, no WMI, no restore points.
        foreach ($name in 'BFE', 'DcomLaunch', 'RpcSs', 'Winmgmt', 'CryptSvc',
                          'MpsSvc', 'TrustedInstaller', 'wuauserv', 'Schedule',
                          'ProfSvc', 'Volsnap', 'gpsvc') {
            $critical | Should -Contain $name
        }
    }

    It 'has no duplicates' {
        $critical = @(& $script:Module { Get-PCCriticalServiceName })
        ($critical | Sort-Object -Unique).Count | Should -Be $critical.Count
    }
}

Describe 'Removable app allowlist' {

    It 'never lists something the system or this module depends on' {
        $removable = & $script:Module { Get-PCRemovableAppxName }

        # The Store is how anything gets reinstalled, including itself.
        # DesktopAppInstaller carries winget, which two commands here need.
        # Photos and Calculator leave a user without a viewer or a calculator.
        # Terminal is often the shell this is running in.
        foreach ($name in 'Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller',
                          'Microsoft.Windows.Photos', 'Microsoft.WindowsCalculator',
                          'Microsoft.WindowsTerminal', 'Microsoft.SecHealthUI') {
            $removable | Should -Not -Contain $name
        }
    }

    It 'lists no framework or runtime package' {
        $removable = & $script:Module { Get-PCRemovableAppxName }

        foreach ($name in $removable) {
            $name | Should -Not -Match 'VCLibs|Framework|\.NET|Runtime'
        }
    }

    It 'has no duplicates' {
        $removable = @(& $script:Module { Get-PCRemovableAppxName })
        ($removable | Sort-Object -Unique).Count | Should -Be $removable.Count
    }
}

Describe 'New mutating commands are previewable' {

    BeforeDiscovery {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/PCTools/PCTools.psd1') -Force

        # Everything added in v0.5 that changes machine state. The contract is
        # the same one the module has had since v0.4: if it changes something,
        # you can see what it would change first.
        $script:NewMutating = @(
            'Clear-PCCrashDump', 'Clear-PCDeliveryOptimization', 'Clear-PCEventLog'
            'Clear-PCThumbnailCache', 'Clear-PCWindowsOld', 'Optimize-PCVolume'
            'Disable-PCStartupItem', 'Enable-PCStartupItem', 'Set-PCServiceStartup'
            'Install-PCWindowsUpdate', 'Update-PCApplication', 'Remove-PCAppxPackage'
            'Register-PCScheduledMaintenance', 'Unregister-PCScheduledMaintenance'
            'Register-PCExtension', 'Save-PCHistory', 'Invoke-PCTools'
        ) | ForEach-Object { @{ Name = $_ } }
    }

    It '<Name> supports ShouldProcess' -ForEach $script:NewMutating {
        $command = Get-Command -Name $Name -Module PCTools -ErrorAction Stop
        $command.Parameters.Keys | Should -Contain 'WhatIf'
        $command.Parameters.Keys | Should -Contain 'Confirm'
    }
}

Describe 'High-impact commands prompt by default' {

    BeforeDiscovery {
        # ConfirmImpact High means PowerShell prompts unless the caller says
        # otherwise. These are the ones where a silent run would be wrong.
        $script:HighImpact = @(
            'Clear-PCWindowsOld'      # gives up the rollback to the previous build
            'Clear-PCEventLog'        # discards an audit trail
            'Set-PCServiceStartup'    # can disable something load-bearing
            'Remove-PCAppxPackage'    # uninstalls software
            'Install-PCWindowsUpdate' # can demand a restart
            'Register-PCExtension'    # runs code from disk
        ) | ForEach-Object { @{ Name = $_ } }
    }

    It '<Name> declares ConfirmImpact High' -ForEach $script:HighImpact {
        $command = Get-Command -Name $Name -Module PCTools
        $metadata = [System.Management.Automation.CommandMetadata]::new($command)
        $metadata.ConfirmImpact | Should -Be 'High'
    }
}

Describe 'Read-only reporting commands change nothing' {

    BeforeDiscovery {
        # These exist to report. A ShouldProcess parameter on any of them would
        # mean somebody had given a reporting command the ability to act.
        $script:ReadOnly = @(
            'Get-PCSecurityStatus', 'Get-PCHealthReport', 'Get-PCSystemInfo'
            'Get-PCDiskHealth', 'Get-PCDiskSpace', 'Get-PCDiskUsage'
            'Get-PCEventSummary', 'Get-PCBootPerformance', 'Get-PCBatteryReport'
            'Get-PCStartupItem', 'Get-PCService', 'Get-PCAppxPackage'
            'Get-PCDriverIssue', 'Get-PCWindowsUpdate', 'Get-PCHistory'
            'Get-PCScheduledMaintenance', 'Get-PCExtension', 'Get-PCResultSummary'
        ) | ForEach-Object { @{ Name = $_ } }
    }

    It '<Name> takes no WhatIf, because it has nothing to preview' -ForEach $script:ReadOnly {
        $command = Get-Command -Name $Name -Module PCTools -ErrorAction Stop
        $command.Parameters.Keys | Should -Not -Contain 'WhatIf'
    }
}

Describe 'Get-PCResultSummary' {

    It 'handles an empty batch without throwing' {
        # Measure-Object emits nothing for an empty collection, and reading .Sum
        # off nothing is a terminating error under strict mode. A network-only
        # report reaches this path, so it is a normal case, not a corner one.
        $summary = Get-PCResultSummary -Result @()
        $summary.Total | Should -Be 0
        $summary.BytesFreed | Should -Be 0
        $summary.Text | Should -Be 'Nothing ran'
    }

    It 'totals and grades a mixed batch' {
        $results = & $script:Module {
            @(
                New-PCActionResult -Action 'A' -Status Success -BytesFreed 1073741824 -Duration ([timespan]::FromSeconds(2))
                New-PCActionResult -Action 'B' -Status Warning -BytesFreed 1048576
                New-PCActionResult -Action 'C' -Status Failed
                New-PCActionResult -Action 'D' -Status Success -RebootRequired
            )
        }

        $summary = Get-PCResultSummary -Result $results
        $summary.Total | Should -Be 4
        $summary.Succeeded | Should -Be 2
        $summary.Warnings | Should -Be 1
        $summary.Failed | Should -Be 1
        $summary.RebootRequired | Should -BeTrue
        $summary.BytesFreed | Should -Be 1074790400
        $summary.Text | Should -Match 'restart required'
    }

    It 'ignores objects that are not action results' {
        $summary = Get-PCResultSummary -Result @('a string', [pscustomobject]@{ Foo = 1 })
        $summary.Total | Should -Be 0
    }
}
