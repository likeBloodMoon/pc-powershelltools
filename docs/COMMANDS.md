# PCTools command reference

Generated from the module's own help by `./build/Invoke-Build.ps1 -Task Docs`.
Do not edit by hand - edit the comment-based help on the command instead.

PCTools 0.5.0 exports 74 commands.

## Automation

| Command | What it does | Supports -WhatIf |
|---|---|---|
| `Get-PCExtension` | Lists extension actions, loaded and available. |  |
| `Get-PCHistory` | Reads past maintenance runs, and the trend across them. |  |
| `Get-PCScheduledMaintenance` | Shows the scheduled maintenance tasks this module has registered. |  |
| `Register-PCExtension` | Loads custom actions from disk so they can be used like built-in ones. | yes |
| `Register-PCScheduledMaintenance` | Schedules a maintenance profile to run on its own. | yes |
| `Save-PCHistory` | Records a maintenance run so it can be compared with later ones. | yes |
| `Unregister-PCScheduledMaintenance` | Removes a scheduled maintenance task. | yes |

## Cleanup

| Command | What it does | Supports -WhatIf |
|---|---|---|
| `Clear-PCBrowserCache` | Clears the HTTP cache of installed Chromium-based browsers and Firefox. | yes |
| `Clear-PCPrefetchCache` | Clears the Windows Prefetch folder. | yes |
| `Clear-PCRecycleBin` | Empties the Recycle Bin for all drives. | yes |
| `Clear-PCTempFile` | Removes temporary files for the current user and the machine. | yes |
| `Clear-PCWindowsUpdateCache` | Clears the Windows Update download cache. | yes |

## Entry points and orchestration

| Command | What it does | Supports -WhatIf |
|---|---|---|
| `Export-PCReport` | Writes action results or a network report to disk as HTML, JSON, text or CSV. | yes |
| `Format-PCByteSize` | Formats a byte count for display. |  |
| `Get-PCLogPath` | Returns the path of the current PCTools log file. |  |
| `Get-PCMaintenanceProfile` | Lists the built-in maintenance presets. |  |
| `Get-PCResultSummary` | Reduces a set of action results to the one line a person actually reads. |  |
| `Import-PCConfiguration` | Loads user-defined maintenance profiles from a JSON file. |  |
| `Invoke-PCMaintenance` | Runs a maintenance profile and returns one result per action. | yes |
| `Invoke-PCTools` | The command-line front door: run a profile, diagnose the network, or open the window. | yes |
| `Register-PCLogSink` | Routes PCTools log lines to a caller-supplied scriptblock. |  |
| `Start-PCTools` | Opens the PC Tools window. |  |
| `Test-PCAdmin` | Returns $true when the current session is elevated. |  |
| `Unregister-PCLogSink` | Removes a log sink registered with Register-PCLogSink. |  |

## Health

| Command | What it does | Supports -WhatIf |
|---|---|---|
| `Get-PCBatteryReport` | Reports battery wear: how much capacity the battery has actually lost. |  |
| `Get-PCBootPerformance` | How long this machine takes to start, and what is slowing it down. |  |
| `Get-PCDiskHealth` | Reads SMART-derived health and wear for every physical disk. |  |
| `Get-PCEventSummary` | Summarises what has been going wrong, grouped rather than listed. |  |
| `Get-PCHealthReport` | One graded answer to "how is this machine doing". |  |
| `Get-PCSecurityStatus` | Reports this machine's security posture. Reads only; changes nothing. |  |
| `Get-PCSystemInfo` | What this machine is. |  |

## Network

| Command | What it does | Supports -WhatIf |
|---|---|---|
| `Clear-PCDnsCache` | Flushes the DNS resolver cache. | yes |
| `Export-PCNetworkProfile` | Saves an adapter's full IP configuration as a named profile. | yes |
| `Get-PCNetworkAdapter` | Lists network adapters with their IP configuration. |  |
| `Get-PCNetworkProfile` | Lists saved network profiles. |  |
| `Get-PCNetworkReport` | Builds a full network diagnostic report. |  |
| `Get-PCWirelessStatus` | Reports the current Wi-Fi association: SSID, signal, band and rate. |  |
| `Import-PCNetworkProfile` | Applies a saved network profile to an adapter. | yes |
| `Reset-PCNetworkStack` | Resets the Windows TCP/IP and Winsock stack. | yes |
| `Set-PCDhcp` | Returns an adapter to DHCP for both address and DNS. | yes |
| `Set-PCDnsServer` | Sets the DNS servers for an adapter. | yes |
| `Set-PCNetworkAddress` | Assigns a static IPv4 address, prefix and gateway to an adapter. | yes |
| `Test-PCConnectivity` | Runs layered connectivity tests: gateway, internet, DNS and TCP. |  |
| `Test-PCDnsServer` | Benchmarks DNS resolvers and says which one to use. |  |
| `Test-PCMtu` | Finds the largest packet that reaches a host without fragmenting. |  |
| `Test-PCRoute` | Traces the path to a host, reporting per-hop latency. |  |
| `Test-PCThroughput` | Measures download throughput against an HTTP endpoint. |  |

## Preferences

| Command | What it does | Supports -WhatIf |
|---|---|---|
| `Get-PCPreference` | Reads the current state of the Windows preferences the module manages. |  |
| `Restart-PCExplorer` | Restarts Windows Explorer. | yes |
| `Set-PCPreference` | Enables or disables a Windows preference. | yes |

## Repair

| Command | What it does | Supports -WhatIf |
|---|---|---|
| `New-PCRestorePoint` | Creates a System Restore checkpoint. | yes |
| `Repair-PCSystemFile` | Verifies and repairs protected system files with SFC. | yes |
| `Repair-PCSystemImage` | Repairs the Windows component store with DISM. | yes |
| `Test-PCDisk` | Runs an online CHKDSK scan of a volume. | yes |

## Software

| Command | What it does | Supports -WhatIf |
|---|---|---|
| `Get-PCAppxPackage` | Lists installed Store-style apps and grades what is safe to remove. |  |
| `Get-PCDriverIssue` | Finds devices Windows is reporting a problem with. |  |
| `Get-PCWindowsUpdate` | Lists the Windows updates that apply to this machine but are not installed. |  |
| `Install-PCApplication` | Installs applications with winget. | yes |
| `Install-PCWindowsUpdate` | Downloads and installs pending Windows updates. | yes |
| `Remove-PCAppxPackage` | Removes preinstalled apps from the curated removable list. Nothing else. | yes |
| `Update-PCApplication` | Upgrades installed applications through winget. | yes |

## Startup

| Command | What it does | Supports -WhatIf |
|---|---|---|
| `Disable-PCStartupItem` | Switches off a startup item, reversibly. | yes |
| `Enable-PCStartupItem` | Switches a startup item back on. | yes |
| `Get-PCService` | Lists services with their startup type and what they belong to. |  |
| `Get-PCStartupItem` | Lists everything that starts with Windows, from every place it can hide. |  |
| `Set-PCServiceStartup` | Changes a service's startup type, refusing the ones that matter. | yes |

## Storage

| Command | What it does | Supports -WhatIf |
|---|---|---|
| `Clear-PCCrashDump` | Removes crash dumps and Windows Error Reporting queues. | yes |
| `Clear-PCDeliveryOptimization` | Removes the Delivery Optimization download cache. | yes |
| `Clear-PCEventLog` | Clears Windows event logs. | yes |
| `Clear-PCThumbnailCache` | Clears the Explorer thumbnail and icon caches. | yes |
| `Clear-PCWindowsOld` | Removes the previous Windows installation left behind by a feature update. | yes |
| `Get-PCDiskSpace` | Reports free and used space per fixed drive. |  |
| `Get-PCDiskUsage` | Finds what is actually using the space. |  |
| `Optimize-PCVolume` | Optimizes a drive the way that drive should be optimized. | yes |

