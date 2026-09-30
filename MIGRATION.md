# Migrating from the single-file tools

`pc-cleanuptool.ps1` and `pc-netdiag.ps1` still work and are still shipped. They
are frozen: bug fixes only, no new features. Everything they do now lives in the
`PCTools` module, usually with more control and always with a way to preview it
first.

## Why bother

- `-WhatIf` on every action, so you can see the plan before committing to it.
- Actions return objects, so you can filter, total and export them.
- Failures are reported. The originals piped DISM, SFC, CHKDSK and winget to
  `Out-Null`, so a failed repair looked exactly like a successful one.
- Preferences can be read and reverted, not just applied.
- Nothing blocks the UI thread.

## Command mapping

### Cleanup

| Was | Now |
|---|---|
| `Clear-TempFiles` | `Clear-PCTempFile` |
| `Clear-RecycleBinSafe` | `Clear-PCRecycleBin` |
| `Clear-WindowsUpdateCache` | `Clear-PCWindowsUpdateCache` |
| `Clear-PrefetchCache` | `Clear-PCPrefetchCache` |
| — | `Clear-PCBrowserCache` (new) |

### Repair

| Was | Now |
|---|---|
| `Run-SystemHealthChecks` | `Repair-PCSystemImage` **and** `Repair-PCSystemFile` (split; DISM and SFC report separately) |
| `Run-ChkDskScan` | `Test-PCDisk` (takes a `-DriveLetter`; was hard-coded to `C:`) |
| `Create-SystemRestorePoint` | `New-PCRestorePoint` |

### Network

| Was | Now |
|---|---|
| `Flush-DnsCache` | `Clear-PCDnsCache` |
| `Reset-NetworkStack` | `Reset-PCNetworkStack` (add `-SkipWinsock` to keep VPN LSPs) |
| `Get-ActiveAdapters` | `Get-PCNetworkAdapter -ConnectedOnly` |
| `Set-StaticIP` | `Set-PCNetworkAddress` (takes `-PrefixLength` or `-SubnetMask`) |
| `Set-DnsServers` | `Set-PCDnsServer` (or `-Preset Cloudflare\|Google\|Quad9`) |
| `Set-DhcpMode` | `Set-PCDhcp` (now also resets DNS) |
| `Run-QuickDiagnostics` | `Get-PCNetworkReport` |
| `Start-FullDiagnosticsWorker` | `Get-PCNetworkReport -Full` |
| `Save-Report` | `Export-PCReport` (works for any results, not just network) |

### Preferences

The six one-way setters (`Set-DarkTheme`, `Disable-BingSearch`,
`Show-HiddenFiles`, `Show-FileExtensions`, `Disable-MouseAcceleration`,
`Enable-NumLock`) are replaced by two commands over a table of definitions:

```powershell
Get-PCPreference                                   # what is set right now
Set-PCPreference -Name DarkMode -Enabled $true     # apply
Set-PCPreference -Name DarkMode -Enabled $false    # restore the Windows default
```

Names: `DarkMode`, `DisableBingSearch`, `ShowHiddenFiles`, `ShowFileExtensions`,
`DisableMouseAcceleration`, `NumLockOnStartup`, `DisableStartMenuSuggestions`,
`ShowFullPathInTitleBar`, `LaunchExplorerToThisPC`.

### Software

| Was | Now |
|---|---|
| `Install-BasicApps` | `Install-PCApplication -Preset Essentials` (or `-Id <winget ids>`) |

## Behaviour changes worth knowing

- **`Run all` is now a profile.** `Invoke-PCMaintenance -ProfileName Full`. It
  takes a restore point first and stops if it cannot.
- **Prefetch is not in any profile.** Clearing it costs launch performance for a
  small disk saving. Call `Clear-PCPrefetchCache` explicitly if you want it.
- **The network stack reset is not in any general profile** and prompts by
  default (`ConfirmImpact = 'High'`).
- **A failed action no longer stops the batch.** Every action reports its own
  result; pass `-ContinueOnFailure $false` for the old behaviour.
- **Subnet masks are converted, not passed through.** `255.0.255.0` is rejected
  as invalid rather than handed to `netsh`.


## New in v0.5

The commands above all still work exactly as documented. v0.5 added areas the
single-file tools never covered at all:

| Question | Command |
|---|---|
| How is this machine doing? | `Get-PCHealthReport` |
| Where did my disk space go? | `Get-PCDiskSpace`, `Get-PCDiskUsage` |
| What starts with Windows? | `Get-PCStartupItem`, `Disable-PCStartupItem` |
| Is this disk failing? | `Get-PCDiskHealth` |
| Why is boot so slow? | `Get-PCBootPerformance` |
| What keeps crashing? | `Get-PCEventSummary` |
| Is this machine protected? | `Get-PCSecurityStatus` |
| What needs updating? | `Get-PCWindowsUpdate`, `Update-PCApplication` |
| Can this run on a schedule? | `Register-PCScheduledMaintenance` |
| How much have I reclaimed over time? | `Get-PCHistory -Summary` |

And the entry points changed shape:

| Was | Now |
|---|---|
| `.\pc-tools.ps1` | `Start-PCTools`, or `pctools` |
| `.\pc-tools.ps1 -NoGui` | `Import-Module PCTools` |
| (nothing) | `Invoke-PCTools -ProfileName Quick -Exit`, for scripts and scheduled tasks |

`.\pc-tools.ps1` still works from a clone or an extracted release archive.

## Running the old tools

Nothing was removed:

```powershell
.\pc-cleanuptool.ps1
.\pc-netdiag.ps1
```
