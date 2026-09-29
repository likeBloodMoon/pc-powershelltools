# pc-powershelltools - Roadmap

Where this is going, and what it deliberately will not do.

---

## Where the project stands

v0.5.0. The module is the product: 74 commands covering cleanup, storage
analysis, repair, network diagnostics and configuration, health and security
reporting, startup and service control, updates, and automation. The GUI ships
inside it. `Invoke-PCTools` gives the same actions a scriptable front door with
a meaningful exit code.

Installation is one command, pinned to a tag and verified.

### History

| Version | What landed |
|---|---|
| v0.1 - v0.2 | Four standalone scripts: a cleanup GUI, a network diagnostics GUI, an unused GUI framework, and a console "speed boost". |
| v0.3 | **Phases 0-3.** Repo foundation, CI, and the `PCTools` module extraction - every action became a function returning a structured result and supporting `-WhatIf`. The GUI framework was promoted to the application shell and both bespoke UIs retired. Restore-point gating, preflight preview and a result summary. Releases pinned and checksummed. |
| v0.4 | **Phases 4-5.** Network profiles, JSON config, traceroute, MTU probe, Wi-Fi status, nine reversible preference toggles. PowerShell Gallery publishing wired into the release workflow. |
| v0.5 | **One command, measured performance, and roughly double the commands.** See below. |

### What v0.5 changed

**One command.** The shell moved inside the module, so a Gallery install carries
the GUI; `install.ps1` prefers the signed Gallery package, falls back to a
hash-verified release archive, and installs a `pctools` command onto a PATH
directory that already exists.

**Measured performance.** Nothing here had ever been measured. The hot paths
were all the same shape - independent I/O done one item at a time - and are now
concurrent behind a single `Invoke-PCParallel` helper. The shipped module is
compiled to one file. Numbers and method: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

**Thirty-five new commands** across storage analysis, startup and service
control, health and security reporting, updates and drivers, bloatware removal,
scheduling, history and extensions.

---

## v0.6 - Trust

The theme is making the install defensible to somebody who is not already
inclined to trust it.

- **A real code-signing certificate.** The release workflow already signs when
  one is configured; nothing is configured. Signed scripts mean the Gallery
  package verifies, SmartScreen calms down, and the `irm | iex` bootstrapper
  stops being the weakest link in the chain.
- **A winget manifest**, once releases are signed. `winget install PCTools`
  is the install command people already know, and it verifies the hash itself.
- **Verifiable builds.** The compiled module is already byte-reproducible for a
  given commit - the merge is ordered and embeds no timestamp - so what remains
  is publishing that fact: a documented command a third party can run to confirm
  the released artifact matches the source it claims to come from.
- **A tray agent**, optional and off by default: run the Weekly profile when the
  machine is idle and say so afterwards, rather than needing a scheduled task
  somebody has to know about.

## v0.7 - Fit

Making it pleasant for the second and third use, not just the first.

- **A command palette** in the shell (Ctrl+K), because seven pages of buttons is
  already the point where searching beats hunting.
- **Per-machine policy.** A JSON file an administrator can drop next to the
  module that removes commands from the UI, forces `-WhatIf`, or pins the
  profiles on offer. The extension model already proves the loading path.
- **Localisation.** Every user-facing string currently lives inline. Moving them
  to a resource table is unglamorous and gets steadily harder the longer it is
  left.
- **Better disk visualisation.** `Get-PCDiskUsage` returns the right data; the
  GUI renders it as a list. A treemap would make the answer obvious rather than
  merely available.
- **Scheduled health reporting.** The pieces exist - `Get-PCHealthReport`,
  `Export-PCReport -Format Html`, `Register-PCScheduledMaintenance`. Wiring a
  weekly HTML report into a folder is small and useful for anybody looking after
  a relative's PC.

## v1.0 - Stability

- **A stable command surface.** After 1.0, a breaking change to an exported
  command's parameters or output shape means a major version. That promise is
  worth making only once the surface has settled, which is why it is not being
  made now.
- **Complete help.** Every command has a synopsis and examples; not every one has
  `.NOTES` explaining when *not* to use it, which for a tool that runs elevated
  is the part that matters.
- **A test machine matrix.** The suite runs on Windows Server images in CI.
  Windows 10, Windows 11 and a Home edition - which has no BitLocker cmdlets and
  a different Appx set - are where the users are, and where the untested code
  paths are.

---

## Permanent non-goals

These are not "not yet". They are decisions.

- **No telemetry.** Not anonymised, not opt-in, not "just crash reports".
  Nothing here reports home, and no future version will. The only network
  traffic is what a diagnostic explicitly probes and what an update command
  downloads.
- **No registry "tweaks" whose benefit cannot be explained.** Every preference
  in `Set-PCPreference` says what it changes and can be reverted. Anything that
  amounts to folklore does not get added, however popular.
- **No `ps2exe` bundle.** Its output is unsigned and reliably trips SmartScreen
  and antivirus heuristics, which is worse for trust than a script. A signed
  module plus a checksummed archive is the better answer.
- **No memory "optimisation".** `EmptyWorkingSet` on every process forces those
  pages straight back off disk, and purging the standby list throws away the
  cache Windows built to make things fast. `quickspeedboost.ps1` remains in the
  repository as a record of what not to do, documented as such.
- **No "disable these 40 services" list.** `Set-PCServiceStartup` refuses the
  services that break a machine, and this project will not ship a preset that
  disables things wholesale. Which services a machine needs depends on what that
  machine does.
- **No forced restarts.** Commands report that a restart is required. Deciding
  when is the user's.
- **No silent changes to security settings.** `Get-PCSecurityStatus` reports
  that the firewall is off. It will never turn it on: a maintenance tool that
  reconfigures antivirus or firewall settings without being asked is
  indistinguishable from malware, and one that turns protection on unasked
  overrides somebody's deliberate configuration.
