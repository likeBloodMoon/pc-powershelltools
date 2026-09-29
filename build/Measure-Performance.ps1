<#
.SYNOPSIS
    Measures the module's hot paths so performance claims have numbers behind
    them.

.DESCRIPTION
    Nothing in this project was ever measured before v0.5, which is how it
    ended up with a traceroute that waited out twenty timeouts in a row. This
    is the arbiter: a change that does not move a number here does not get
    described as an optimization.

    Each scenario runs -Iterations times and the median is reported, not the
    mean. One outlier from a background virus scan should not decide the
    result.

    Scenarios that need Windows are skipped elsewhere with a reason rather than
    failing, so the harness still runs on Linux CI for the parts that are
    platform-independent.

.PARAMETER Iterations
    How many times to run each scenario.

.PARAMETER OutputPath
    Where to write the JSON result.

.PARAMETER Baseline
    A previous result file to compare against. The comparison is printed as a
    percentage change per scenario.

.PARAMETER Scenario
    Run only the named scenarios.

.EXAMPLE
    ./build/Measure-Performance.ps1

.EXAMPLE
    ./build/Measure-Performance.ps1 -Baseline ./build/benchmark.json
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 50)]
    [int]$Iterations = 5,

    [string]$OutputPath,

    [string]$Baseline,

    [string[]]$Scenario
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ModulePath = Join-Path $RepoRoot 'src/PCTools/PCTools.psd1'

$isWindowsHost = if ($null -eq (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) { $true } else { $IsWindows }

function Get-Median {
    param([double[]]$Value)
    if ($Value.Count -eq 0) { return $null }
    $sorted = @($Value | Sort-Object)
    if ($sorted.Count % 2 -eq 1) { return $sorted[[int][math]::Floor($sorted.Count / 2)] }
    ($sorted[($sorted.Count / 2) - 1] + $sorted[$sorted.Count / 2]) / 2
}

function New-TempFixture {
    <#
        A deterministic tree to clean, so the filesystem scenario measures the
        code rather than whatever happened to be in the user's TEMP folder.
    #>
    param([int]$Directories = 12, [int]$FilesEach = 40, [int]$Bytes = 8192)

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("pcbench-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    $payload = [byte[]]::new($Bytes)
    for ($d = 0; $d -lt $Directories; $d++) {
        $dir = Join-Path $root "dir$d\nested"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        for ($f = 0; $f -lt $FilesEach; $f++) {
            [System.IO.File]::WriteAllBytes((Join-Path $dir "file$f.bin"), $payload)
        }
    }
    $root
}

$scenarios = @(
    @{
        Name    = 'Import-Module'
        Windows = $false
        Note    = 'Paid on every GUI launch and every console session.'
        # Measured in a child process: a module already loaded in this one
        # would report the cost of a no-op re-import.
        Measure = {
            $command = "`$s=[Diagnostics.Stopwatch]::StartNew(); Import-Module '$ModulePath'; `$s.Elapsed.TotalMilliseconds"
            $host_ = if ($isWindowsHost) { 'powershell.exe' } else { 'pwsh' }
            [double](& $host_ -NoProfile -Command $command)
        }
    }
    @{
        Name    = 'Clear-PCFolderContent'
        Windows = $false
        Note    = '12 directories, 480 files. Was a size walk plus a delete walk.'
        Measure = {
            $fixture = New-TempFixture
            try {
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                & (Get-Module PCTools) { param($p) Clear-PCFolderContent -Path $p } $fixture | Out-Null
                $watch.Stop()
                $watch.Elapsed.TotalMilliseconds
            }
            finally {
                Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    @{
        Name    = 'Invoke-PCParallel'
        Windows = $false
        Note    = 'Eight 200 ms sleeps. Serially this is 1600 ms.'
        Measure = {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            & (Get-Module PCTools) {
                Invoke-PCParallel -InputObject (1..8) -ScriptBlock {
                    param($n) Start-Sleep -Milliseconds 200; $n
                } -ThrottleLimit 8
            } | Out-Null
            $watch.Stop()
            $watch.Elapsed.TotalMilliseconds
        }
    }
    @{
        Name    = 'Get-PCNetworkAdapter'
        Windows = $true
        Note    = 'Was two CIM round-trips per adapter; now three in total.'
        Measure = {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            Get-PCNetworkAdapter | Out-Null
            $watch.Stop()
            $watch.Elapsed.TotalMilliseconds
        }
    }
    @{
        Name    = 'Test-PCConnectivity'
        Windows = $true
        Note    = 'Nine probes. Was strictly sequential.'
        Measure = {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            Test-PCConnectivity | Out-Null
            $watch.Stop()
            $watch.Elapsed.TotalMilliseconds
        }
    }
    @{
        Name    = 'Get-PCNetworkReport-Full'
        Windows = $true
        Note    = 'Six external captures. Were run one after another.'
        Measure = {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            Get-PCNetworkReport -Full | Out-Null
            $watch.Stop()
            $watch.Elapsed.TotalMilliseconds
        }
    }
    @{
        Name    = 'Test-PCRoute'
        Windows = $true
        Note    = 'Was one TTL at a time, up to MaxHops timeouts.'
        Measure = {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            Test-PCRoute -Target '1.1.1.1' -MaxHops 12 -TimeoutSeconds 2 | Out-Null
            $watch.Stop()
            $watch.Elapsed.TotalMilliseconds
        }
    }
    @{
        Name    = 'Test-PCMtu'
        Windows = $true
        Note    = 'Was eleven sequential probes; now a bracket plus a search.'
        Measure = {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            Test-PCMtu -Target '1.1.1.1' -TimeoutSeconds 2 | Out-Null
            $watch.Stop()
            $watch.Elapsed.TotalMilliseconds
        }
    }
    @{
        Name    = 'Get-PCDiskSpace'
        Windows = $true
        Note    = 'One CIM query.'
        Measure = { $w = [System.Diagnostics.Stopwatch]::StartNew(); Get-PCDiskSpace | Out-Null; $w.Stop(); $w.Elapsed.TotalMilliseconds }
    }
)

Import-Module $ModulePath -Force

Write-Host ''
Write-Host "PCTools $((Get-Module PCTools).Version) benchmark" -ForegroundColor Cyan
Write-Host "  host       : $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
Write-Host "  iterations : $Iterations"
Write-Host ''

$results = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $scenarios) {
    if ($Scenario -and $Scenario -notcontains $entry.Name) { continue }

    if ($entry.Windows -and -not $isWindowsHost) {
        Write-Host ('  {0,-26} skipped (needs Windows)' -f $entry.Name) -ForegroundColor DarkGray
        $results.Add([pscustomobject]@{
            Scenario = $entry.Name; Skipped = $true; Reason = 'Needs Windows'
            MedianMs = $null; MinMs = $null; MaxMs = $null; Note = $entry.Note
        })
        continue
    }

    $samples = [System.Collections.Generic.List[double]]::new()
    $failure = ''

    for ($i = 0; $i -lt $Iterations; $i++) {
        try {
            $samples.Add([double](& $entry.Measure))
        }
        catch {
            $failure = $_.Exception.Message
            break
        }
    }

    if ($failure -or $samples.Count -eq 0) {
        Write-Host ('  {0,-26} failed: {1}' -f $entry.Name, $failure) -ForegroundColor Yellow
        $results.Add([pscustomobject]@{
            Scenario = $entry.Name; Skipped = $true; Reason = $failure
            MedianMs = $null; MinMs = $null; MaxMs = $null; Note = $entry.Note
        })
        continue
    }

    $median = [math]::Round((Get-Median -Value $samples.ToArray()), 1)
    $min = [math]::Round(($samples | Measure-Object -Minimum).Minimum, 1)
    $max = [math]::Round(($samples | Measure-Object -Maximum).Maximum, 1)

    Write-Host ('  {0,-26} {1,9:n1} ms   (min {2:n1}, max {3:n1})' -f $entry.Name, $median, $min, $max)

    $results.Add([pscustomobject]@{
        Scenario = $entry.Name; Skipped = $false; Reason = ''
        MedianMs = $median; MinMs = $min; MaxMs = $max; Note = $entry.Note
    })
}

$report = [pscustomobject]@{
    Tool       = 'PCTools'
    Version    = (Get-Module PCTools).Version.ToString()
    Generated  = Get-Date
    Host       = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
    Platform   = if ($isWindowsHost) { 'Windows' } else { 'Non-Windows' }
    Iterations = $Iterations
    Results    = @($results)
}

if ($Baseline) {
    if (-not (Test-Path -LiteralPath $Baseline)) {
        Write-Warning "No baseline at $Baseline; nothing to compare."
    }
    else {
        $previous = Get-Content -LiteralPath $Baseline -Raw | ConvertFrom-Json
        $previousByName = @{}
        foreach ($item in $previous.Results) { $previousByName[$item.Scenario] = $item }

        Write-Host ''
        Write-Host "Against $Baseline ($($previous.Version), $($previous.Generated)):" -ForegroundColor Cyan

        foreach ($current in $results) {
            if ($current.Skipped) { continue }
            if (-not $previousByName.ContainsKey($current.Scenario)) { continue }

            $was = $previousByName[$current.Scenario]
            if ($was.Skipped -or -not $was.MedianMs) { continue }

            $change = (($current.MedianMs - $was.MedianMs) / $was.MedianMs) * 100
            $colour = if ($change -le -5) { 'Green' } elseif ($change -ge 5) { 'Red' } else { 'Gray' }

            Write-Host ('  {0,-26} {1,9:n1} -> {2,9:n1} ms  {3,+7:n1}%' -f
                $current.Scenario, $was.MedianMs, $current.MedianMs, $change) -ForegroundColor $colour
        }
    }
}

if ($OutputPath) {
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host ''
    Write-Host "Written to $OutputPath" -ForegroundColor Green
}

Write-Host ''
$report
