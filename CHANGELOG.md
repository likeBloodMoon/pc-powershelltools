# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [0.5.0] - 2026-09-02

One command to install and run, hot paths measured rather than assumed, and
roughly double the commands.

### Added

#### One command

- `install.ps1`: a bootstrapper pinned to a release tag. Prefers the signed
  PowerShell Gallery package; falls back to the release archive, which it
  verifies against the published `SHA256SUMS` and refuses to unpack on a
  mismatch. There is no switch to skip that check. Installs a `pctools` command
  into `%LOCALAPPDATA%\Microsoft\WindowsApps`, already on PATH on Windows 10
  and 11, so no PATH edit and no elevation.
- `Start-PCTools` (alias `pctools`) opens the window. The shell moved from
  `src/Shell` into the module, so `Install-Module PCTools` now delivers the GUI
  as well as the commands - previously the Gallery shipped the module only.
- `Invoke-PCTools`: a scriptable front door with exit codes (`0` success,
  `1` warnings, `2` failures, `3010` restart required), `-Json`, and
  `-Report Html|Json|Text|Csv`. What the `pctools` shim invokes.

#### Storage and startup

- `Get-PCDiskSpace`, with a free-space pressure grade rather than a bare number.
- `Get-PCDiskUsage`: largest folders and files, over `System.IO` enumeration.
- `Clear-PCDeliveryOptimization`, `Clear-PCWindowsOld`, `Clear-PCThumbnailCache`,
  `Clear-PCCrashDump`, `Clear-PCEventLog`.
- `Optimize-PCVolume`: reads the media type and picks TRIM for an SSD or
  defragmentation for an HDD. There is no switch to force the wrong one.
- `Get-PCStartupItem`: Run keys, Startup folders **and** logon scheduled tasks in
  one list - Task Manager omits the third, which is where most modern updater
  software lives. `Disable-PCStartupItem` / `Enable-PCStartupItem` write the same
  `StartupApproved` flag Task Manager writes, so nothing is deleted and either
  tool can undo the other.
- `Get-PCService` and `Set-PCServiceStartup`, the latter refusing a fixed list of
  services whose loss breaks a machine. No `-Force`.

#### Health and security

- `Get-PCSystemInfo`, `Get-PCDiskHealth` (SMART wear, reallocated sectors,
  temperature), `Get-PCBatteryReport` (capacity loss against design).
- `Get-PCBootPerformance`: boot time and, from the diagnostics log, the specific
  applications, services and drivers that lengthen it and by how many
  milliseconds.
- `Get-PCEventSummary`: errors and criticals grouped by source and event ID
  rather than listed, with bugchecks pulled out separately.
- `Get-PCSecurityStatus`: Defender, firewall, BitLocker, UAC, SmartScreen and
  pending updates. Read-only by design; there is no counterpart that changes
  them.
- `Get-PCHealthReport`: a graded score with the findings behind it, each naming
  the command that addresses it. The GUI dashboard renders this.

#### Software

- `Get-PCWindowsUpdate` and `Install-PCWindowsUpdate` over the
  `Microsoft.Update.Session` COM API - no third-party module dependency in a tool
  that runs elevated. Driver updates are excluded unless named explicitly.
- `Update-PCApplication`: `winget upgrade` with per-package results.
- `Get-PCDriverIssue`: problem devices with their Configuration Manager code
  decoded into what it actually means.
- `Get-PCAppxPackage` and `Remove-PCAppxPackage`, allowlist-only. The Store,
  App Installer, Photos, Calculator, Terminal and every framework package are
  deliberately absent from that list.

#### Automation and reporting

- `Register-PCScheduledMaintenance`, `Get-`, `Unregister-`. Unattended runs are
  limited to the profiles that cannot demand a restart.
- `Save-PCHistory` and `Get-PCHistory`, including `-Summary` for the trend across
  runs. The GUI records every non-preview run.
- `Register-PCExtension` / `Get-PCExtension`: drop-in `*.PCAction.ps1` actions
  usable in a profile like any built-in. An extension cannot replace a built-in
  command.
- `Get-PCResultSummary`: the one-line "what just happened", shared by the GUI,
  the CLI and the HTML report so they cannot disagree.

#### Other

- `Test-PCThroughput` and `Test-PCDnsServer` - the speed test and resolver
  benchmark the roadmap has promised since v0.1.
- New profiles: `Storage`, `Health` (read-only) and `Weekly`.
- `Export-PCReport -Format Html`: a single self-contained file with no external
  stylesheet, font or script, so it renders identically offline.
- `build/Measure-Performance.ps1`, and `-Task Compile`, `-Task Docs` and
  `-Task Bench` in the build script.
- `docs/COMMANDS.md`, generated from the module's own help, and
  `docs/PERFORMANCE.md`.
- New test suites: `Parallel`, `Safety`, `Compile`, `Install`.

### Changed

- **The hot paths run concurrently.** `Test-PCConnectivity` ran nine probes in
  sequence, each waiting out its own timeout; `Test-PCRoute` walked up to twenty
  TTLs one at a time; `Test-PCMtu` made about eleven sequential probes;
  `Get-PCNetworkReport -Full` ran six external captures one after another. All
  now run at once behind a new `Invoke-PCParallel` helper. Output ordering is
  unchanged - it is the diagnostic value.
- **`Get-PCNetworkAdapter` makes three CIM queries instead of two per adapter.**
  A laptop with Wi-Fi, Ethernet, Bluetooth, Hyper-V and VPN adapters was paying
  twenty-odd round-trips to build one table.
- **`Clear-PCFolderContent` walks each tree once instead of twice.** It sized
  with `Get-ChildItem -Recurse` and then deleted with `Remove-Item -Recurse`;
  it now sizes and deletes in a single `System.IO` pass, with top-level entries
  cleared concurrently.
- **A locked file no longer costs its whole directory.** Deleting per file rather
  than per top-level entry means one held-open browser cache file leaves that
  file behind, not the directory containing it. `BytesFreed` is now counted after
  each successful delete, so it reports what was reclaimed rather than what was
  hoped for.
- **`Invoke-PCProcess` reads the pipes instead of two temp files.** It created
  two files with `GetTempFileName`, wrote output to disk and read it back, on
  every external command. It also now escapes arguments by the rules
  `CommandLineToArgvW` actually applies on Windows PowerShell 5.1; the previous
  quoting mangled any argument containing a quote.
- **The shipped module is compiled to one file.** `-Task Compile` merges the
  sources so an import parses one file rather than sixty, stamps the version
  instead of re-reading the manifest, and prepares the log file on first write
  instead of at import. Measured: about 520 ms to 400 ms. `tests/Compile.Tests.ps1`
  asserts the compiled and source modules export exactly the same surface.
- The GUI gained Dashboard, Storage, Health and Software pages, and opens on the
  dashboard. `Start-PCTools -Page` chooses another.
- The PSScriptAnalyzer warning budget rose from 146 to 210 for the new code. It
  is a ceiling to lower, not a target.

### Fixed

- `Get-PCResultSummary` and `Export-PCReport` no longer throw on an empty batch.
  `Measure-Object` emits nothing for an empty collection, so reading `.Sum` off
  it is a terminating error under `Set-StrictMode -Version Latest` - which a
  network-only report reaching the HTML writer would have hit.
- `Save-PCHistory` no longer overwrites an entry when two runs finish in the same
  second.
- `Test-PCMtu` no longer uses `GetNewClosure()`. It rebinds a scriptblock to a
  scope detached from the module's session state, so the probe could not see the
  private helper it needed and every call failed.
- `Start-PCTools` could not find the GUI in the module that actually ships. It
  resolved the shell as `$PSScriptRoot\..\Shell`, which is correct in the source
  tree - the function lives in `Public/` - and wrong in the compiled module,
  where `$PSScriptRoot` is already the module root. Every Gallery and archive
  install would have thrown "the shell is missing" on the command this release
  is named after.
- `Register-PCScheduledMaintenance` registered a task that imported PCTools by
  name rather than by path, for the same reason: two parents up from
  `$PSScriptRoot` landed outside the versioned module folder. A scheduled task
  runs as SYSTEM, whose module path does not include a CurrentUser install, so
  every task registered from a normal install would have failed before running
  its profile. Both now resolve from
  `$ExecutionContext.SessionState.Module.ModuleBase`, correct in either layout.
- `Invoke-PCParallel` discarded results that had already completed once the
  batch deadline passed. The tasks run concurrently, so one slow item early in
  the list could exhaust the budget while every later item had finished - and
  those finished results were then reported as timeouts. Completion is now
  checked before the budget.
- `docs/COMMANDS.md` was generated with a BOM on Windows PowerShell 5.1 and
  without one on PowerShell 7, so the CI freshness check called it stale
  depending only on which host generated it. It is now written as UTF-8 without
  a BOM, with LF endings, on every host.
- The release notes named `pc-tools-v0.5.0.zip`; the build stages the archive
  without the tag's leading `v`, so the documented verification step named a
  file that is not attached.
- `Import-PCConfiguration`'s error for an unknown action printed literal `{0}`
  and `{1}` instead of the profile and action names. The format operator binds
  tighter than string concatenation, so `"a {0} " + "b {1}" -f $x, $y` formats
  only the second string; the concatenation needs its own parentheses.

## [0.4.0] - 2026-01-15

### Added
- `PCTools` module (`src/PCTools`): 29 public functions covering cleanup,
  repair, network, preferences and software installation. Every action returns a
  structured `PCTools.ActionResult` and every mutating action supports `-WhatIf`
  and `-Confirm`.
- `Invoke-PCMaintenance` and built-in maintenance profiles (Quick, Recommended,
  Full, NetworkRepair), replacing the "Run selected"/"Run all" buttons.
- `Export-PCReport`: JSON and text export for any results, generalised from Net
  Diag's network-only `Save-Report`.
- `Get-PCPreference`: reads the current state of every managed Windows
  preference. `Set-PCPreference` applies **and reverts** them.
- `Clear-PCBrowserCache` for Chrome, Edge, Brave, Firefox and Vivaldi.
- PC Tools shell (`src/Shell`), replacing both bespoke GUIs. Runs every action
  on a background runspace, adds a `-WhatIf` preview, a per-run results summary
  and a network verdict banner naming the failing layer.
- `pc-tools.ps1` entry point, with `-NoGui` to load the module into a console
  session.
- `MIGRATION.md` mapping every old function to its replacement.
- Release workflow: builds from a tag, verifies the manifest version matches,
  runs the full suite, publishes checksummed artifacts, and Authenticode-signs
  them when a signing certificate is configured.
- `Format-PCByteSize` is public, so hosts can format a total without reaching
  into module internals.
- Network profiles: `Export-PCNetworkProfile`, `Import-PCNetworkProfile` and
  `Get-PCNetworkProfile` save and restore an adapter's full configuration
  (DHCP or static address, prefix, gateway, DNS) as JSON, giving the Home/Work
  presets the roadmap asked for.
- `Import-PCConfiguration`: user-defined maintenance profiles from a JSON file.
  Imported profiles appear in `Get-PCMaintenanceProfile` and run through
  `Invoke-PCMaintenance` unchanged; one with the same name as a built-in
  overrides it. Every action name is validated at import, so a typo fails there
  rather than partway through a run.
- `Test-PCRoute`: per-hop traceroute, answering where connectivity stops rather
  than only that it has.
- `Test-PCMtu`: path MTU probe, the diagnostic for the case where DNS resolves
  and small requests work but large transfers and TLS handshakes stall.
- `Get-PCWirelessStatus`: parses and grades the Wi-Fi association instead of
  dumping `netsh wlan show interfaces` as raw text.
- The shell's Network page gained Trace route, Check path MTU, Wi-Fi signal, and
  save/apply adapter profile.

### Changed
- PowerShell Gallery publishing wired into the release workflow, gated on a
  `PSGALLERY_API_KEY` secret and refusing to republish an existing version.
- Module manifest carries Gallery metadata: `CompatiblePSEditions`, edition
  tags and inline release notes.
- Install instructions are pinned to a release tag and hash-verified. The
  previous `irm .../main/... | iex` commands are documented with their trade-off
  rather than recommended.
- `Repair-PCSystemImage` and `Repair-PCSystemFile` are separate commands; the
  original `Run-SystemHealthChecks` ran DISM and SFC together and reported
  neither.
- `Test-PCDisk` takes a drive letter instead of always scanning `C:`.
- Prefetch cleanup and the network stack reset are excluded from every
  general-purpose profile.

### Fixed
- Every external command runs through a timeout wrapper. Previously only Net
  Diag's full scan was protected; a stuck DISM could hang the Cleanup Tool
  indefinitely.
- DISM, SFC, CHKDSK and winget exit codes are interpreted instead of discarded,
  so a failed repair no longer looks identical to a successful one.
- `Set-PCNetworkAddress` removes the existing address and route first. The
  original failed with an "instance already exists" error on any adapter that
  already had an address.
- `Set-PCDhcp` also resets DNS servers, which the original left static.
- `Clear-PCWindowsUpdateCache` restarts `wuauserv` in a `finally` block, so a
  mid-run failure no longer leaves Windows Update stopped, and waits for the
  service to stop before deleting.
- `New-PCRestorePoint` detects Windows silently throttling the 24-hour limit
  instead of reporting success when no checkpoint was created.
- Folder cleanup enumerates once instead of recursing twice, uses `-LiteralPath`
  so paths containing brackets are not skipped, and reports bytes reclaimed.
- Subnet mask conversion rejects non-contiguous masks and handles `/0`.
- `Restart-PCExplorer` waits for the shell to return instead of sleeping a fixed
  interval, which could leave the user with no taskbar.

- `ROADMAP.md` describing the phased plan for the project.
- MIT `LICENSE`.
- `.gitignore` for logs, reports and release output.
- GitHub Actions CI (`.github/workflows/ci.yml`) running PSScriptAnalyzer and
  the Pester suite on both Windows PowerShell 5.1 and PowerShell 7.
- `build/Invoke-Build.ps1` - a single Test/Analyze/Release entry point shared by
  CI and local development.
- `tests/` Pester suite: every script must parse, and no file may contain
  non-ASCII characters without a UTF-8 BOM.
- `PSScriptAnalyzerSettings.psd1` pinning the analyzer to the 5.1 target.

### Fixed
- Non-ASCII characters in `pc-cleanuptool.ps1` and `pc-netdiag.ps1` were stored
  without a UTF-8 BOM, so Windows PowerShell 5.1 decoded them as ANSI. Net Diag's
  minimize button rendered as `â€"` instead of a dash, and the Cleanup Tool's
  elevation prompt showed `â†'` instead of an arrow. Replaced with ASCII
  equivalents.

## [0.2.0] - 2025-12-12

### Added
- Net Diag GUI (`pc-netdiag.ps1`): quick and full network diagnostics, common
  fixes, adapter management, log rotation, JSON/TXT report export, refreshed
  dark UI.

## [0.1.0] - 2025-12-12

### Added
- PC Cleanup Tool (`pc-cleanuptool.ps1`): temp/Recycle Bin/Windows Update/
  Prefetch cleanup, DISM + SFC + CHKDSK, network stack reset, adapter IP/DNS
  configuration, Windows preference toggles, winget app installation.

[Unreleased]: https://github.com/likeBloodMoon/pc-powershelltools/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/likeBloodMoon/pc-powershelltools/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/likeBloodMoon/pc-powershelltools/compare/v0.2.0...v0.4.0
[0.2.0]: https://github.com/likeBloodMoon/pc-powershelltools/releases/tag/v0.2.0
[0.1.0]: https://github.com/likeBloodMoon/pc-powershelltools/releases/tag/v0.1.0
