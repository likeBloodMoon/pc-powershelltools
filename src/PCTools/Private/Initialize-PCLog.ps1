function Initialize-PCLog {
    <#
    .SYNOPSIS
        Prepares the log file, once, on first use.

    .DESCRIPTION
        This used to run at import: create the log directory, stat the log file,
        rotate it if it had grown past 2 MB, and prune the old archives. Every
        import paid for it, including the ones that never logged anything -
        Get-PCPreference, Format-PCByteSize, a tab-completion probe.

        Doing it on the first Write-PCLog instead costs the same for a session
        that logs and nothing for a session that does not.

        Failure here is not fatal. Logging to a file is a convenience; the
        module still works with it disabled, and the sinks a host registers are
        unaffected.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    # Set first: a failure below must not make every subsequent log line retry
    # the same broken path.
    $script:PCLogReady = $true

    try {
        if (-not (Test-Path -LiteralPath $script:PCLogDirectory)) {
            New-Item -ItemType Directory -Path $script:PCLogDirectory -Force | Out-Null
        }

        $path = Join-Path $script:PCLogDirectory 'pctools.log'

        # Rotate at 2 MB, keeping the five most recent archives, so a machine
        # where these tools run weekly does not accumulate an unbounded log.
        if (Test-Path -LiteralPath $path) {
            $existing = Get-Item -LiteralPath $path
            if ($existing.Length -gt 2MB) {
                $archive = Join-Path $script:PCLogDirectory ('pctools-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
                Move-Item -LiteralPath $path -Destination $archive -Force

                Get-ChildItem -LiteralPath $script:PCLogDirectory -Filter 'pctools-*.log' |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -Skip 5 |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }

        $script:PCLogPath = $path
    }
    catch {
        $script:PCLogPath = $null
        Write-Warning "PCTools: file logging disabled ($($_.Exception.Message))."
    }
}
