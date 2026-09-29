@{
    RootModule        = 'PCTools.psm1'
    ModuleVersion     = '0.5.0'
    GUID              = '6f3c0a58-1d2e-4a7b-9c34-8e5f2b7d41a9'
    Author            = 'likeBloodMoon'
    CompanyName       = 'likeBloodMoon'
    Copyright         = '(c) 2025 likeBloodMoon. Released under the MIT License.'

    Description       = 'Windows maintenance, repair, storage analysis, health reporting and network diagnostics - as commands and as a GUI, in one module. Every action supports -WhatIf and returns a structured result. Run Start-PCTools for the window, or Invoke-PCTools for a scriptable run with an exit code.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        # Cleanup
        'Clear-PCBrowserCache'
        'Clear-PCPrefetchCache'
        'Clear-PCRecycleBin'
        'Clear-PCTempFile'
        'Clear-PCWindowsUpdateCache'

        # Storage and disk analysis
        'Clear-PCCrashDump'
        'Clear-PCDeliveryOptimization'
        'Clear-PCEventLog'
        'Clear-PCThumbnailCache'
        'Clear-PCWindowsOld'
        'Get-PCDiskSpace'
        'Get-PCDiskUsage'
        'Optimize-PCVolume'

        # Startup and services
        'Disable-PCStartupItem'
        'Enable-PCStartupItem'
        'Get-PCService'
        'Get-PCStartupItem'
        'Set-PCServiceStartup'

        # Repair
        'New-PCRestorePoint'
        'Repair-PCSystemFile'
        'Repair-PCSystemImage'
        'Test-PCDisk'

        # Health and security reporting
        'Get-PCBatteryReport'
        'Get-PCBootPerformance'
        'Get-PCDiskHealth'
        'Get-PCEventSummary'
        'Get-PCHealthReport'
        'Get-PCSecurityStatus'
        'Get-PCSystemInfo'

        # Network
        'Clear-PCDnsCache'
        'Export-PCNetworkProfile'
        'Get-PCNetworkAdapter'
        'Get-PCNetworkProfile'
        'Get-PCNetworkReport'
        'Get-PCWirelessStatus'
        'Import-PCNetworkProfile'
        'Reset-PCNetworkStack'
        'Set-PCDhcp'
        'Set-PCDnsServer'
        'Set-PCNetworkAddress'
        'Test-PCConnectivity'
        'Test-PCDnsServer'
        'Test-PCMtu'
        'Test-PCRoute'
        'Test-PCThroughput'

        # Preferences
        'Get-PCPreference'
        'Restart-PCExplorer'
        'Set-PCPreference'

        # Software, updates and drivers
        'Get-PCAppxPackage'
        'Get-PCDriverIssue'
        'Get-PCWindowsUpdate'
        'Install-PCApplication'
        'Install-PCWindowsUpdate'
        'Remove-PCAppxPackage'
        'Update-PCApplication'

        # Automation, history and extensions
        'Get-PCExtension'
        'Get-PCHistory'
        'Get-PCScheduledMaintenance'
        'Register-PCExtension'
        'Register-PCScheduledMaintenance'
        'Save-PCHistory'
        'Unregister-PCScheduledMaintenance'

        # Entry points, orchestration and reporting
        'Export-PCReport'
        'Format-PCByteSize'
        'Get-PCLogPath'
        'Get-PCMaintenanceProfile'
        'Get-PCResultSummary'
        'Import-PCConfiguration'
        'Invoke-PCMaintenance'
        'Invoke-PCTools'
        'Register-PCLogSink'
        'Start-PCTools'
        'Test-PCAdmin'
        'Unregister-PCLogSink'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('pctools')

    # Windows-only: the GUI needs WinForms, and the actions call Windows-only
    # cmdlets. Declaring it keeps the module out of Linux and macOS search
    # results on the Gallery rather than failing at import for those users.
    CompatiblePSEditions = @('Desktop', 'Core')

    PrivateData = @{
        PSData = @{
            Tags         = @(
                'Windows', 'Maintenance', 'Cleanup', 'Network', 'Diagnostics',
                'Optimization', 'Repair', 'DISM', 'SFC', 'GUI', 'Health',
                'Storage', 'Startup', 'Security', 'WindowsUpdate', 'winget',
                'PSEdition_Desktop', 'PSEdition_Core'
            )
            LicenseUri   = 'https://github.com/likeBloodMoon/pc-powershelltools/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/likeBloodMoon/pc-powershelltools'
            ReleaseNotes = @'
0.5.0 - one command, faster, and a great deal more of it.

- The GUI now ships inside the module: Install-Module PCTools; Start-PCTools.
- Invoke-PCTools gives a scriptable run with a meaningful exit code.
- 35 new commands: storage analysis, startup and service control, health and
  security reporting, Windows Update and winget, scheduled maintenance, run
  history, HTML reports and a drop-in extension model.
- The network and cleanup hot paths run concurrently instead of serially.

Every action still supports -WhatIf and returns a structured result.

See the full changelog:
https://github.com/likeBloodMoon/pc-powershelltools/blob/main/CHANGELOG.md
'@
            RequireLicenseAcceptance = $false
        }
    }
}
