# pc-powershelltools

Windows maintenance, repair, storage analysis, health reporting and network
diagnostics. One PowerShell module, with a GUI on top and a scriptable CLI
underneath.

> **Disclaimer**
> These tools are provided **as-is**. I am not liable for any system issues or
> damages resulting from their use.

---

## Install and run, in one command

```powershell
irm https://raw.githubusercontent.com/likeBloodMoon/pc-powershelltools/v0.5.0/install.ps1 | iex
```

That installs PC Tools, adds a `pctools` command, and opens the window.

**Note the version in that URL.** It is not `main`, on purpose: pinning to a tag
means you run a specific, reviewed release rather than whatever was pushed most
recently.

What the installer actually does:

1. Installs `PCTools` from the PowerShell Gallery, where the package is signed
   and PowerShellGet verifies it.
2. If the Gallery is unreachable, downloads the release archive **and** its
   `SHA256SUMS`, verifies the hash, and refuses to continue on a mismatch. There
   is no switch to skip that check.
3. Drops a `pctools` command into `%LOCALAPPDATA%\Microsoft\WindowsApps`, which
   is already on `PATH` on Windows 10 and 11 - so no PATH edit and no elevation.
4. Opens the window.

**The honest limitation:** step 1 runs a script fetched over TLS from a pinned
URL, which you are trusting on the strength of that connection. Everything after
it is signature- or hash-verified. If you would rather verify the first step too,
use the manual path below.

### Without the bootstrapper

```powershell
Install-Module PCTools -Scope CurrentUser
Start-PCTools
```

The Gallery package now carries the GUI as well as the commands, so this is a
complete install. `Update-Module PCTools` keeps it current.

### Verifying everything yourself

```powershell
$version = 'v0.5.0'
$base    = "https://github.com/likeBloodMoon/pc-powershelltools/releases/download/$version"
Invoke-WebRequest "$base/pc-tools-$($version.TrimStart('v')).zip" -OutFile pc-tools.zip
Invoke-WebRequest "$base/SHA256SUMS" -OutFile SHA256SUMS

$actual   = (Get-FileHash pc-tools.zip -Algorithm SHA256).Hash.ToLower()
$expected = (Select-String -Path SHA256SUMS -Pattern 'pc-tools-.*\.zip').Line.Split(' ')[0]
if ($actual -ne $expected) { throw 'Checksum mismatch - do not run this file.' }

Expand-Archive pc-tools.zip -DestinationPath .\pc-tools
.\pc-tools\pc-tools.ps1
```

Or clone the repository and run `.\pc-tools.ps1`.

---

## Three ways to use it

```powershell
pctools                                  # the window
pctools -ProfileName Quick               # run and exit, with an exit code
Import-Module PCTools; Get-PCHealthReport # every action as an ordinary command
```

The module is the product. The GUI and the CLI are two faces on it, so anything
the window can do, a console session or a scheduled task can do too.

### The command line

`Invoke-PCTools` (aliased as `pctools`) is built for scripts and scheduled tasks:

```powershell
pctools -ProfileName Quick -Json           # JSON on stdout
pctools -ProfileName Recommended -Report Html -Quiet
pctools -Diagnose                          # network verdict
```

Exit codes, so it composes:

| Code | Meaning |
|---|---|
| `0` | every action succeeded |
| `1` | at least one warning, nothing failed |
| `2` | at least one action failed |
| `3010` | succeeded, but a restart is required |

---

## What it does

| Area | Commands |
|---|---|
| **Clean up** | Temp files, Recycle Bin, browser caches, Windows Update cache, Delivery Optimization, crash dumps, thumbnails, Prefetch, `Windows.old` |
| **Analyse storage** | Free space per drive with a pressure grade, and a fast scan for the largest folders and files |
| **Repair** | DISM component store, SFC system files, CHKDSK, restore points |
| **Diagnose the network** | Layered connectivity verdict, traceroute, path MTU, Wi-Fi signal, throughput, DNS resolver benchmark |
| **Configure the network** | Static IP, DNS presets, DHCP, Winsock/TCP-IP reset, and Home/Work adapter profiles |
| **Report health** | System info, SMART disk health, battery wear, boot time and what slows it, crash and error history |
| **Check security posture** | Defender, firewall, BitLocker, UAC, SmartScreen, pending updates - read-only, always |
| **Control startup** | Every autostart from Run keys, Startup folders and logon tasks, reversibly disabled |
| **Manage services** | Startup types, with a hard refusal list for the ones that break a machine |
| **Update software** | Windows Update over the COM API, `winget upgrade`, problem-device detection |
| **Remove bloatware** | Preinstalled apps, from a curated allowlist only |
| **Automate** | Scheduled maintenance, run history and trends, HTML/JSON/text/CSV reports |
| **Extend** | Drop-in custom actions usable in your own profiles |

The full reference is in [docs/COMMANDS.md](docs/COMMANDS.md), generated from
the module's own help.

---

## Using the GUI

```powershell
Start-PCTools                       # dark theme, dashboard
Start-PCTools -Theme Light -Page Network
Start-PCTools -Elevate              # relaunch as administrator
```

- **Dashboard** - a health score out of 100 with the reasons behind it, disk
  space, what the last run reclaimed, and when the next scheduled one is due.
- **Maintenance** - pick a profile, press **Preview** to see exactly what would
  run without changing anything, then **Run maintenance**.
- **Storage** - drives with a free-space pressure grade, the reclaims, and a
  scan for the largest folders and files.
- **Health** - read-only reports. Nothing on this page changes the machine.
- **Network** - a verdict naming the failing layer ("DNS is not resolving")
  rather than a table of pass/fail rows to interpret yourself.
- **Software** - Windows updates, application updates, device problems, and
  one-click scheduled maintenance.
- **Preferences** - checkboxes that reflect what Windows currently has set.
  Clearing one restores the Windows default.
- **Log** - everything the session has done.

Long-running work happens on a background runspace, so the window stays
responsive during a DISM or SFC run.

---

## Using the module

```powershell
Import-Module PCTools
Get-Command -Module PCTools
Get-Help Invoke-PCMaintenance -Full
```

Preview before committing to anything:

```powershell
Invoke-PCMaintenance -ProfileName Recommended -WhatIf
```

Run it for real:

```powershell
Invoke-PCMaintenance -ProfileName Quick |
    Format-Table Action, Status, FreedDisplay, Detail
```

How is this machine doing:

```powershell
$health = Get-PCHealthReport
$health.Score       # 0-100
$health.Findings | Format-Table Severity, Area, Message, Command
```

Where did the disk space go:

```powershell
Get-PCDiskSpace | Format-Table Drive, FreeDisplay, PercentFree, Pressure
(Get-PCDiskUsage -Path C:\ -Top 20).LargestFolders | Format-Table SizeDisplay, Path
```

Diagnose a network problem:

```powershell
$report = Get-PCNetworkReport
$report.Verdict.Verdict   # e.g. 'DNS is not resolving'
$report.Verdict.Advice
$report | Export-PCReport -Format Html
```

What starts with Windows, and switch something off reversibly:

```powershell
Get-PCStartupItem | Where-Object Enabled | Format-Table Name, Source, Command
Disable-PCStartupItem -Name 'Spotify' -WhatIf
Enable-PCStartupItem -Name 'Spotify'      # back on
```

Keep it maintained without remembering to:

```powershell
Register-PCScheduledMaintenance -ProfileName Weekly -Frequency Weekly
Get-PCScheduledMaintenance | Format-Table TaskName, NextRunTime, LastResult
Get-PCHistory -Summary
```

### Maintenance profiles

| Profile | What it does |
|---|---|
| `Quick` | Reclaim disk space. No repairs, no restart. |
| `Recommended` | Quick, plus the Windows Update cache and a health scan. Restore point first. |
| `Full` | Adds component-store and system-file repair. Can run for an hour; expect a restart. |
| `Storage` | The deeper reclaims: update and delivery caches, crash dumps, thumbnails. |
| `Health` | Read-only. Reports, changes nothing. |
| `Weekly` | The sensible default for a schedule. No restart. |
| `NetworkRepair` | Diagnose, then apply the standard network fixes. Requires a restart. |

Prefetch cleanup, the network stack reset, removing `Windows.old`, clearing
event logs and uninstalling apps are deliberately **not** in any profile. Each
gives up something that cannot be got back, so each has to be asked for by name.

### Your own profiles

```json
{
  "profiles": [
    {
      "name": "Friday",
      "description": "What I actually run on Fridays",
      "restorePoint": false,
      "actions": [
        { "action": "Clear-PCTempFile" },
        { "action": "Clear-PCBrowserCache", "parameters": { "Browser": ["Chrome"] } }
      ]
    }
  ]
}
```

```powershell
Import-PCConfiguration -Path .\my-profiles.json
Invoke-PCMaintenance -ProfileName Friday -WhatIf
```

Action names are validated at import, so a typo fails there rather than partway
through a run.

### Your own actions

Write a function that returns a `PCTools.ActionResult`, save it as
`*.PCAction.ps1` under `%LOCALAPPDATA%\PCTools\extensions`, and it can be named
in a profile like any built-in:

```powershell
# %LOCALAPPDATA%\PCTools\extensions\backup.PCAction.ps1
function Invoke-PCMyBackup {
    [CmdletBinding()]
    param([string]$Destination = 'D:\Backups')
    Invoke-PCAction -Name 'Invoke-PCMyBackup' -Body {
        # Invoke-PCAction handles the timing, logging and failure shape.
        @{ Detail = "copied to $Destination" }
    }
}
```

```powershell
Register-PCExtension -PassThru
Get-PCExtension | Format-Table Name, Loaded, File

Invoke-PCMaintenance -Action 'Invoke-PCMyBackup'   # or name it in a profile
```

Extension actions run through `Invoke-PCMaintenance` and profiles, not as
top-level commands. They are loaded into the module's scope so they can use
`Invoke-PCAction` and the other internals - which is what makes their results the
same shape as a built-in's - and a module cannot export a function after it has
finished loading.

An extension is ordinary PowerShell running with your rights. Nothing sandboxes
it. It cannot silently replace a built-in command - that is refused - and a file
that does not parse is skipped rather than taking the others down with it. But
load only extensions you wrote or would be willing to read.

---

## Safety

- **Every mutating action supports `-WhatIf`.** The GUI's Preview button is the
  same code path that performs the work, so the plan cannot drift from the
  action.
- **Restore point as a gate.** Profiles that repair or reset take a checkpoint
  first, and abort if one cannot be created. Override with `-SkipRestorePoint`.
- **Allowlists, not blocklists, for the destructive commands.**
  `Set-PCServiceStartup` refuses a fixed list of services that break a machine.
  `Remove-PCAppxPackage` will only remove preinstalled apps on a curated list.
  Neither has a `-Force` to talk it round; `Set-Service` and `Remove-AppxPackage`
  are still there if you genuinely mean it.
- **Security settings are reported, never changed.** `Get-PCSecurityStatus` tells
  you the firewall is off. It will not turn it on: a maintenance tool that
  reconfigures your antivirus is indistinguishable from malware.
- **`Reset-PCNetworkStack` is high impact and says so.** Resetting Winsock
  removes third-party layered service providers, which is what breaks some VPN
  clients until they are reinstalled. Use `-SkipWinsock` to avoid that.
- **Failures are reported, not swallowed.** DISM, SFC, CHKDSK and winget exit
  codes are interpreted; a failed repair does not look like a successful one.
- **No telemetry, ever.** Nothing here reports home. The only network traffic is
  what a diagnostic explicitly probes and what an update command downloads.
- **Everything is logged** to `%LOCALAPPDATA%\PCTools\logs`, rotated at 2 MB.

---

## Speed

v0.5 measured the hot paths for the first time and fixed what the numbers
showed - mostly independent I/O that was being done one item at a time. Module
import is about a third faster, eight concurrent probes take the time of one
rather than eight, and a path-MTU probe converges in at most six rounds instead
of eleven sequential ones. The method and the figures are in
[docs/PERFORMANCE.md](docs/PERFORMANCE.md); reproduce them with:

```powershell
./build/Measure-Performance.ps1
./build/Measure-Performance.ps1 -Baseline ./build/benchmark.json
```

---

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (the GUI uses WinForms). The module also loads under
  PowerShell 7.
- Administrator rights for repair, network and system-cache actions. The shell
  runs without them and offers a **Restart as admin** button; actions that need
  elevation fail with a clear message rather than a cascade of access-denied
  errors.

---

## Development

```powershell
./build/Invoke-Build.ps1 -Task All       # Pester suite, then PSScriptAnalyzer
./build/Invoke-Build.ps1 -Task Test
./build/Invoke-Build.ps1 -Task Compile   # merge the module into one .psm1
./build/Invoke-Build.ps1 -Task Docs      # regenerate docs/COMMANDS.md
./build/Invoke-Build.ps1 -Task Release   # stage out/ and write SHA256SUMS
./build/Measure-Performance.ps1          # benchmark the hot paths
```

CI runs the suite on both Windows PowerShell 5.1 and PowerShell 7. Releases are
built from a tag, checksummed, and Authenticode-signed when a signing
certificate is configured.

Layout:

```
install.ps1       the one-command bootstrapper
src/PCTools/      the module - Public/ by domain, Private/ for helpers, Shell/ for the GUI
tests/            Pester: syntax, module contract, unit, parallel, safety, compile, shell
build/            Test/Analyze/Compile/Docs/Release, and the benchmark harness
docs/             generated command reference and performance notes
```

The shipped module is compiled: `-Task Compile` merges the sources into a single
`.psm1` so an import parses one file instead of sixty. `tests/Compile.Tests.ps1`
asserts the compiled module exports exactly what the source does, so the two
cannot drift.

---

## The older tools

`pc-cleanuptool.ps1`, `pc-netdiag.ps1` and `gui-framework.ps1` are the original
single-file tools. They still work and are still shipped, but they are frozen:
bug fixes only. [MIGRATION.md](MIGRATION.md) maps every old function to its
replacement.

`quickspeedboost.ps1` is kept for reference, but most of what it does is
counterproductive: `EmptyWorkingSet` on every process forces those pages straight
back off disk, and purging the standby list discards the cache Windows built to
make things fast. Killing `dwm.exe` is the sharpest edge in the repository. The
parts worth having - temp cleanup, DNS flush, a safe Explorer restart - are in
the module as `Clear-PCTempFile`, `Clear-PCDnsCache` and `Restart-PCExplorer`.

### A note on `irm | iex`

Earlier versions told you to pipe a script straight from the `main` branch into
`iex` as Administrator. Those commands still work and are kept so existing links
do not break, but `main` is whatever was pushed to it most recently. If you use
them, pin to a tag:

```powershell
irm https://raw.githubusercontent.com/likeBloodMoon/pc-powershelltools/v0.5.0/pc-cleanuptool.ps1 | iex
irm https://raw.githubusercontent.com/likeBloodMoon/pc-powershelltools/v0.5.0/pc-netdiag.ps1 | iex
```

The installer at the top of this file is the recommended path: it is pinned,
and it verifies what it downloads.

---

## Roadmap

See [ROADMAP.md](ROADMAP.md).

Suggestions and contributions are welcome.

## License

MIT. See [LICENSE](LICENSE).
