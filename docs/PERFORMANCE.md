# Performance

Nothing in this project was measured before v0.5. That is how it ended up with a
traceroute that waited out twenty timeouts one after another, and a temp cleanup
that walked every directory tree twice.

This document is the method and the findings. The rule for the work was: measure,
change, measure. A change that does not move a number here is not described as an
optimization.

## Running the benchmark

```powershell
./build/Measure-Performance.ps1
./build/Measure-Performance.ps1 -Iterations 10 -OutputPath before.json
./build/Measure-Performance.ps1 -Baseline before.json
```

Each scenario runs several times and the **median** is reported. Median rather
than mean because one outlier - a virus scan waking up mid-run - would otherwise
decide the result. Scenarios needing Windows are skipped elsewhere with a
reason, so the harness still runs on Linux CI for the platform-independent
parts.

CI runs it on every push and uploads the JSON as an artifact. Only module import
time is a hard gate, with a deliberately generous budget: a flaky performance
test is worse than none.

## What was slow, and why

Every one of these was the same mistake in a different place - independent I/O
performed one item at a time.

| Where | Before | After |
|---|---|---|
| `Get-PCNetworkAdapter` | `Get-NetIPConfiguration` **and** `Get-NetIPInterface` per adapter | Three bulk CIM queries, joined in memory on `ifIndex` |
| `Test-PCConnectivity` | Nine probes strictly in sequence, each waiting out its own timeout | All nine concurrent, sorted back into layer order |
| `Test-PCRoute` | TTL 1..20, one `Ping.Send` at a time | Every TTL at once, sorted by hop, truncated at the destination |
| `Test-PCMtu` | ~11 sequential probes, binary search | A parallel bracket, then a 3-probe-per-round search |
| `Clear-PCFolderContent` | `Get-ChildItem -Recurse` to size, then `Remove-Item -Recurse` to delete | One `System.IO` walk that sizes and deletes together, top-level entries concurrent |
| `Get-PCNetworkReport -Full` | Six external captures one after another | Six concurrent |
| `Invoke-PCProcess` | Two `GetTempFileName()` files per call, written and read back | Both pipes read asynchronously in memory |
| Module import | 51 files dot-sourced, plus parsing its own manifest, plus log setup | One compiled file, version stamped at build, log prepared on first write |

### The measured effect

Two figures worth stating precisely, because they were measured rather than
reasoned about. Both are medians of seven runs on PowerShell 7 on a Linux CI
container - the absolute numbers move with machine load, the ratio much less so:

- **`Invoke-PCParallel`**: eight 200 ms operations complete in ~265 ms. Serially
  that is 1600 ms, so roughly 6x, which is about what eight concurrent waits on
  a throttle of eight should give.
- **Module import**: 335 ms from the source tree, 224 ms from the compiled
  module - about a third faster. Smaller than "60 files became 1" suggests,
  because opening and parsing files is only part of the cost of an import.

Measure your own rather than trusting these: `./build/Measure-Performance.ps1`.

The Windows-only network figures depend entirely on the network the machine is
attached to, which is exactly why they are not quoted here as a fixed number.
The structural claim is the honest one: `Test-PCRoute` was bounded by
`MaxHops x TimeoutSeconds` and is now bounded by roughly one timeout. On a
healthy network both are fast; the difference shows up precisely when something
is broken, which is when somebody is running a traceroute.

`Test-PCMtu` is the one that can be stated exactly, because the search is
arithmetic rather than network-dependent: it converges on the correct payload
size for every value from 0 to 1472 in at most 6 rounds, against about 11
sequential probes before. Each round is one wall-clock timeout instead of one
probe, so the worst case roughly halves and the common case - a standard 1500
byte path - is a single round.

## The parallel helper

`Invoke-PCParallel` (private) is one runspace pool implementation used on both
Windows PowerShell 5.1 and PowerShell 7.

The plan was to use `ForEach-Object -Parallel` on 7. That does not work for a
general-purpose helper: PowerShell 7 refuses to pass a scriptblock into a
parallel block - *"a ForEach-Object -Parallel using variable cannot be a script
block ... can result in undefined behavior"* - which is exactly what a helper
taking a `-ScriptBlock` parameter must do. One implementation that behaves
identically everywhere beats two where one of them is documented as undefined.

Two constraints fell out of building it, both learned the hard way:

**The body crosses into the pool as text and is recompiled there.** A live
scriptblock carries the session state of the runspace that created it, so
invoking one from a pool thread runs it against the caller's session state from
another thread. During development this corrupted that state: `Get-Date` stopped
resolving on the main thread mid-run.

**A parallel body must be self-contained.** A fresh runspace has no modules
loaded, and importing PCTools into each one would cost more than the parallelism
saves. Bodies use .NET types and built-in cmdlets only. Where a module helper is
genuinely needed - `Test-PCPing`, `Test-PCTcpPort`, `Invoke-PCProcess` -
`Get-PCFunctionSource` ships that function's own source into the runspace, so
there is still exactly one implementation of a ping rather than a sequential one
and a parallel one that can drift apart.

## Reproducibility

The compiled module is byte-identical between builds of the same source: the
merge walks the files in sorted order and embeds no timestamp. Confirm it with:

```powershell
./build/Invoke-Build.ps1 -Task Compile
(Get-FileHash ./obj/PCTools/PCTools.psm1).Hash
./build/Invoke-Build.ps1 -Task Compile
(Get-FileHash ./obj/PCTools/PCTools.psm1).Hash    # the same
```

## What was not done, and why

**Deleting files in parallel *within* a directory.** Top-level entries are
cleared concurrently; the files inside one entry are not. Per-file metadata
operations do overlap well on an SSD, but the added complexity sits in the one
code path that permanently destroys data, and the measured gain did not justify
it.

**A faster `Get-PCDiskUsage` for the whole of `C:\`.** It is bounded by reading
the MFT through ordinary filesystem APIs. Reading the MFT directly would be
dramatically faster and requires elevation, raw volume access, and NTFS-specific
parsing that breaks on ReFS - a large amount of fragile code for a command
people run occasionally.

**Caching CIM results between calls.** Tempting, and wrong for a diagnostic
tool: the entire point of re-running `Get-PCNetworkAdapter` after changing an
adapter is to see the change.
