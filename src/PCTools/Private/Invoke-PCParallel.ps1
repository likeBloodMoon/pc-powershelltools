function Invoke-PCParallel {
    <#
    .SYNOPSIS
        Runs a scriptblock against many inputs concurrently.

    .DESCRIPTION
        The module's hot paths are all the same shape: a handful of independent
        I/O-bound probes run one after another, so the wall-clock cost is their
        sum when it could be their maximum. A traceroute waits out twenty
        timeouts in sequence; a connectivity check waits out nine. This runs
        them at once.

        A runspace pool is used on both Windows PowerShell 5.1 and PowerShell 7
        rather than switching to ForEach-Object -Parallel on 7. That was the
        intent, but PowerShell 7 refuses to pass a scriptblock into a parallel
        block ("a ForEach-Object -Parallel using variable cannot be a script
        block ... can result in undefined behavior"), which is exactly what a
        general-purpose helper like this one has to do. Two code paths where one
        of them is documented as undefined is worse than one that behaves
        identically everywhere.

        The body crosses into the pool as *text* and is rebuilt there with
        [scriptblock]::Create. That is not ceremony. A live scriptblock carries
        the session state of the runspace that created it, so invoking one from
        a pool thread runs it against the caller's session state from another
        thread - which corrupts it: during development this made Get-Date stop
        resolving on the main thread mid-run. Marshalling the text and
        recompiling gives each runspace its own block, which is also precisely
        why the next paragraph holds.

        IMPORTANT - what a body may contain. A fresh runspace has no modules
        loaded, and importing PCTools into each one would cost far more than the
        parallelism saves. A body passed here must be self-contained: .NET types
        (Ping, TcpClient, Dns, Directory, FileInfo) and built-in cmdlets only,
        never another PCTools function, and never a variable captured from the
        caller - pass those through -ArgumentList. Every caller in this module
        satisfies that; keep it that way.

    .PARAMETER InputObject
        The items to process. Each is passed to the body both as the first
        argument and as $_, so a body can be written either way.

    .PARAMETER ScriptBlock
        The work. Must be self-contained - see above.

    .PARAMETER ThrottleLimit
        Maximum concurrent runspaces. The default suits I/O-bound probes, where
        the threads spend their time waiting rather than computing.

    .PARAMETER TimeoutSeconds
        An upper bound on the whole batch. A body that hangs cannot hang the
        caller; incomplete work is abandoned and what finished is returned.

    .PARAMETER ArgumentList
        Extra arguments appended after the item, for values every body needs.

    .PARAMETER InitScript
        Runs once in each runspace before the body. This is how a body reaches a
        module helper without an Import-Module: pass the helper's own source,
        via Get-PCFunctionSource, so the parallel copy and the sequential
        original cannot drift apart.

    .OUTPUTS
        One pscustomobject per input, in input order, with the body's output in
        Output and any terminating error in Error. Order is preserved even
        though execution is not, because every caller here reports results in a
        meaningful order.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyCollection()]
        [object[]]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [scriptblock]$ScriptBlock,

        [ValidateRange(1, 64)]
        [int]$ThrottleLimit = 8,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 120,

        [object[]]$ArgumentList = @(),

        [scriptblock]$InitScript
    )

    $items = @($InputObject)
    if ($items.Count -eq 0) { return }

    # One item is not worth a pool. Run it here and keep the output shape.
    if ($items.Count -eq 1) {
        $output = $null
        $failure = $null
        try {
            $current = $items[0]
            $output = & {
                if ($InitScript) { . $InitScript }
                $_ = $current
                & $ScriptBlock $current @ArgumentList
            }
        }
        catch {
            $failure = $_
        }

        return [pscustomobject]@{
            Index  = 0
            Input  = $items[0]
            Output = $output
            Error  = $failure
        }
    }

    $throttle = [math]::Min($ThrottleLimit, $items.Count)

    $pool = [runspacefactory]::CreateRunspacePool(1, $throttle)
    $pool.ThreadOptions = 'ReuseThread'
    $pool.Open()

    # The body arrives as text and is recompiled inside the runspace - see the
    # description. $_ is set around the call so a body may use either $_ or a
    # param block.
    $bodyText = $ScriptBlock.ToString()
    $initText = if ($InitScript) { $InitScript.ToString() } else { '' }

    $wrapper = {
        param($Item, $BodyText, $Extra, $InitText)
        if ($InitText) { . ([scriptblock]::Create($InitText)) }
        $body = [scriptblock]::Create($BodyText)
        $_ = $Item
        & $body $Item @Extra
    }

    $running = [System.Collections.Generic.List[object]]::new()

    try {
        for ($i = 0; $i -lt $items.Count; $i++) {
            $shell = [powershell]::Create()
            $shell.RunspacePool = $pool
            $null = $shell.AddScript($wrapper).
                AddArgument($items[$i]).
                AddArgument($bodyText).
                AddArgument($ArgumentList).
                AddArgument($initText)

            $running.Add([pscustomobject]@{
                Index  = $i
                Input  = $items[$i]
                Shell  = $shell
                Handle = $shell.BeginInvoke()
            })
        }

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($task in $running) {
            $output = $null
            $failure = $null

            $remaining = [int]([math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds))

            if ($remaining -le 0 -or -not $task.Handle.AsyncWaitHandle.WaitOne($remaining)) {
                try { $task.Shell.Stop() } catch { }
                $failure = "Timed out after $TimeoutSeconds seconds."
            }
            else {
                try {
                    $output = $task.Shell.EndInvoke($task.Handle)

                    $streamErrors = @($task.Shell.Streams.Error)
                    if ($streamErrors.Count -gt 0 -and $null -eq $output) {
                        $failure = $streamErrors[0]
                    }
                }
                catch {
                    $failure = $_
                }
            }

            $results.Add([pscustomobject]@{
                Index  = $task.Index
                Input  = $task.Input
                Output = $output
                Error  = $failure
            })
        }

        $results
    }
    finally {
        foreach ($task in $running) {
            try { $task.Shell.Dispose() } catch { }
        }
        try { $pool.Close(); $pool.Dispose() } catch { }
    }
}
