function Invoke-PCProcess {
    <#
    .SYNOPSIS
        Runs an external command with a timeout and bounded output.

    .DESCRIPTION
        Promoted from pc-netdiag.ps1's Invoke-ExternalWithTimeout, which was the
        only timeout-protected call site in the project. Every external command
        the module runs - dism, sfc, chkdsk, netsh, ipconfig, winget - goes
        through this, so a hung tool surfaces as a timeout instead of freezing
        the caller forever.

        stdout and stderr are read straight from the pipes rather than being
        redirected through two temp files. The old version created two files per
        call with GetTempFileName, wrote the output to disk, read it back and
        deleted them - a disk round-trip per external command, which a full
        network report paid six times over for output it only ever formats into
        a string.

    .PARAMETER FilePath
        The executable to run.

    .PARAMETER ArgumentList
        Arguments, as an array.

    .PARAMETER TimeoutSeconds
        How long to wait before killing the process. Repair tools legitimately
        run for a long time, so callers such as Repair-PCSystemImage pass a
        much larger value than the default.

    .PARAMETER MaxOutputChars
        Output beyond this is truncated, so a chatty tool cannot exhaust memory
        or make a report unreadable.

    .PARAMETER WorkingDirectory
        Directory to start the process in. Defaults to the current location.

    .OUTPUTS
        pscustomobject with ExitCode, Output, TimedOut and Duration.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string[]]$ArgumentList = @(),

        [int]$TimeoutSeconds = 60,

        [int]$MaxOutputChars = 100000,

        [string]$WorkingDirectory
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $exitCode = -1
    $stdout = ''
    $stderr = ''

    $process = [System.Diagnostics.Process]::new()
    $startInfo = $process.StartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    if ($ArgumentList.Count -gt 0) {
        if ($startInfo.PSObject.Properties.Name -contains 'ArgumentList') {
            # PowerShell 6+ / .NET Core: the runtime does the quoting, correctly.
            foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add([string]$argument) }
        }
        else {
            # Windows PowerShell 5.1 has only the single Arguments string, so the
            # quoting is ours to get right. Wrapping anything containing a space
            # in quotes is the obvious approach and it is wrong: an argument that
            # already contains a quote comes out mangled. These are the escaping
            # rules CommandLineToArgvW actually applies - double the run of
            # backslashes before a quote, escape the quote, and double a trailing
            # run before the closing quote.
            $startInfo.Arguments = ($ArgumentList | ForEach-Object {
                $argument = [string]$_

                if ($argument -eq '') {
                    '""'
                }
                elseif ($argument -notmatch '[\s"]') {
                    $argument
                }
                else {
                    $escaped = [regex]::Replace($argument, '(\\*)"', '$1$1\"')
                    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
                    '"' + $escaped + '"'
                }
            }) -join ' '
        }
    }

    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }

    try {
        try {
            [void]$process.Start()
        }
        catch {
            $stopwatch.Stop()
            return [pscustomobject]@{
                FilePath = $FilePath
                ExitCode = -1
                Output   = "Could not start ${FilePath}: $($_.Exception.Message)"
                TimedOut = $false
                Duration = $stopwatch.Elapsed
            }
        }

        # Both streams are drained concurrently by the framework. Reading one to
        # the end before the other is the classic redirect deadlock: a tool that
        # fills the stderr pipe blocks forever while we wait on stdout.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { if (-not $process.HasExited) { $process.Kill() } } catch { }
            Write-PCLog -Level WARN -Message "$FilePath timed out after $TimeoutSeconds seconds and was terminated."
        }
        else {
            # The parameterless overload waits for the redirected streams to
            # finish flushing; the timed one does not, and without it the tail
            # of a chatty tool's output is lost.
            try { $process.WaitForExit() } catch { }
            $exitCode = $process.ExitCode
        }

        # Killing the process closes the pipes, so these complete either way.
        # The bound is belt and braces against a grandchild process inheriting
        # the handles and holding them open.
        try { [void][System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000) } catch { }

        if ($stdoutTask.IsCompleted -and -not $stdoutTask.IsFaulted) { $stdout = [string]$stdoutTask.Result }
        if ($stderrTask.IsCompleted -and -not $stderrTask.IsFaulted) { $stderr = [string]$stderrTask.Result }

        $output = ($stdout, $stderr | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join [Environment]::NewLine
        $output = $output.Trim()

        if ($timedOut) {
            $output = "Timed out after $TimeoutSeconds seconds.$([Environment]::NewLine)$output".Trim()
        }
        if (-not $output) { $output = '(no output)' }
        if ($output.Length -gt $MaxOutputChars) {
            $output = $output.Substring(0, $MaxOutputChars) + [Environment]::NewLine + '... output truncated ...'
        }

        [pscustomobject]@{
            FilePath = $FilePath
            ExitCode = $exitCode
            Output   = $output
            TimedOut = $timedOut
            Duration = $stopwatch.Elapsed
        }
    }
    finally {
        $stopwatch.Stop()
        try { $process.Dispose() } catch { }
    }
}
