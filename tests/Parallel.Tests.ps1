#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
    Invoke-PCParallel is the piece the whole v0.5 performance story rests on,
    and it is the piece that can go wrong silently: a race that only shows up
    under load, results returned out of order so a traceroute reports hop 7 as
    hop 2, or an error swallowed so a failed probe reads as a passed one.

    It is also platform-independent, so these run everywhere including Linux CI.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/PCTools/PCTools.psd1') -Force
    $script:Module = Get-Module PCTools
}

AfterAll {
    Remove-Module PCTools -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-PCParallel' {

    It 'returns one result per input, in input order' {
        # Execution is concurrent; output order is not allowed to be. Every
        # caller in the module depends on this - Test-PCRoute maps results back
        # to hop numbers by index.
        $result = & $script:Module {
            Invoke-PCParallel -InputObject (1..12) -ScriptBlock {
                param($n)
                # Reverse the sleep so later items finish first if ordering is
                # accidental rather than enforced.
                Start-Sleep -Milliseconds (130 - ($n * 10))
                $n * 2
            } -ThrottleLimit 12
        }

        @($result).Count | Should -Be 12
        @($result | ForEach-Object { $_.Input }) | Should -Be (1..12)
        @($result | ForEach-Object { $_.Output }) | Should -Be (1..12 | ForEach-Object { $_ * 2 })
        @($result | ForEach-Object { $_.Index }) | Should -Be (0..11)
    }

    It 'actually runs concurrently' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $null = & $script:Module {
            Invoke-PCParallel -InputObject (1..6) -ScriptBlock {
                param($n) Start-Sleep -Milliseconds 300
            } -ThrottleLimit 6
        }
        $watch.Stop()

        # Serially this is 1800 ms. The bound is loose because runspace startup
        # on a loaded CI machine is not free, but it cannot reach serial time.
        $watch.Elapsed.TotalMilliseconds | Should -BeLessThan 1500
    }

    It 'passes the item as an argument and as $_' {
        $viaParam = & $script:Module {
            Invoke-PCParallel -InputObject @('a', 'b') -ScriptBlock { param($x) "p:$x" }
        }
        $viaUnderscore = & $script:Module {
            Invoke-PCParallel -InputObject @('a', 'b') -ScriptBlock { "u:$_" }
        }

        @($viaParam | ForEach-Object { $_.Output }) | Should -Be @('p:a', 'p:b')
        @($viaUnderscore | ForEach-Object { $_.Output }) | Should -Be @('u:a', 'u:b')
    }

    It 'captures a failure per item without losing the others' {
        $result = & $script:Module {
            Invoke-PCParallel -InputObject (1..4) -ScriptBlock {
                param($n)
                if ($n -eq 3) { throw 'deliberate' }
                "ok$n"
            }
        }

        @($result).Count | Should -Be 4
        $result[2].Error | Should -Not -BeNullOrEmpty
        $result[2].Output | Should -BeNullOrEmpty
        $result[0].Output | Should -Be 'ok1'
        $result[3].Output | Should -Be 'ok4'
    }

    It 'returns nothing for an empty collection' {
        $result = & $script:Module { Invoke-PCParallel -InputObject @() -ScriptBlock { 1 } }
        $result | Should -BeNullOrEmpty
    }

    It 'keeps the same output shape for a single item' {
        # One item skips the pool entirely. That fast path must not produce a
        # different shape, or every caller needs two code paths.
        $result = & $script:Module {
            Invoke-PCParallel -InputObject @(21) -ScriptBlock { param($n) $n * 2 }
        }

        @($result).Count | Should -Be 1
        $result.Index | Should -Be 0
        $result.Input | Should -Be 21
        $result.Output | Should -Be 42
    }

    It 'passes extra arguments after the item' {
        $result = & $script:Module {
            Invoke-PCParallel -InputObject @('x', 'y') -ScriptBlock {
                param($Item, $Suffix, $Count) "$Item-$Suffix-$Count"
            } -ArgumentList @('s', 7)
        }

        @($result | ForEach-Object { $_.Output }) | Should -Be @('x-s-7', 'y-s-7')
    }

    It 'respects the throttle limit' {
        $result = & $script:Module {
            Invoke-PCParallel -InputObject (1..8) -ScriptBlock {
                param($n)
                Start-Sleep -Milliseconds 150
                [System.Threading.Thread]::CurrentThread.ManagedThreadId
            } -ThrottleLimit 2
        }

        # Two runspaces reusing threads cannot produce eight distinct thread ids.
        $distinct = @($result | ForEach-Object { $_.Output } | Sort-Object -Unique)
        $distinct.Count | Should -BeLessOrEqual 2
    }

    It 'times out rather than hanging the caller' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = & $script:Module {
            Invoke-PCParallel -InputObject (1..2) -ScriptBlock {
                param($n) Start-Sleep -Seconds 30
            } -TimeoutSeconds 2
        }
        $watch.Stop()

        $watch.Elapsed.TotalSeconds | Should -BeLessThan 15
        @($result | Where-Object { $_.Error }).Count | Should -Be 2
    }

    It 'runs an init script in every runspace' {
        $result = & $script:Module {
            $init = [scriptblock]::Create('function Get-Answer { 42 }')
            Invoke-PCParallel -InputObject (1..3) -ScriptBlock {
                param($n) (Get-Answer) + $n
            } -InitScript $init
        }

        @($result | ForEach-Object { $_.Output }) | Should -Be @(43, 44, 45)
    }
}

Describe 'Get-PCFunctionSource' {

    It 'reproduces a module function so a parallel body can call it' {
        # This is what keeps one implementation of a ping rather than two.
        $result = & $script:Module {
            $init = Get-PCFunctionSource -Name 'Format-PCByteSize'
            Invoke-PCParallel -InputObject @(1024, 1048576) -ScriptBlock {
                param($bytes) Format-PCByteSize -Bytes $bytes
            } -InitScript $init
        }

        @($result | ForEach-Object { $_.Output }) | Should -Be @('1.0 KB', '1.0 MB')
    }

    It 'can supply a no-op log stub for helpers that log' {
        $text = & $script:Module { (Get-PCFunctionSource -Name 'Format-PCByteSize' -IncludeLogStub).ToString() }
        $text | Should -Match 'function Write-PCLog'
    }

    It 'throws for a function that does not exist' {
        { & $script:Module { Get-PCFunctionSource -Name 'No-SuchFunction' } } | Should -Throw
    }
}
