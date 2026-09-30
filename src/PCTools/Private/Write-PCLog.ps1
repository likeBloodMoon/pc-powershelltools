function Write-PCLog {
    <#
    .SYNOPSIS
        Writes a log line to the module log file and to any registered sink.

    .DESCRIPTION
        Replaces the three separate logging implementations that previously lived
        in pc-cleanuptool.ps1, pc-netdiag.ps1 and gui-framework.ps1.

        The module never touches a UI control directly. A host (the GUI shell,
        a console script, a test) registers a sink with Register-PCLogSink and
        receives every line; the module stays UI-agnostic and therefore testable.

    .PARAMETER Message
        The text to log.

    .PARAMETER Level
        DEBUG, INFO, WARN or ERROR.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    if (-not $script:PCLogReady) { Initialize-PCLog }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message

    if ($script:PCLogPath) {
        try {
            Add-Content -LiteralPath $script:PCLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            # A failure to write the log must never take down the caller.
            Write-Debug "PCTools: could not write to log file: $($_.Exception.Message)"
        }
    }

    switch ($Level) {
        'ERROR' { Write-Error   -Message $Message -ErrorAction SilentlyContinue }
        'WARN'  { Write-Warning -Message $Message }
        'DEBUG' { Write-Debug   -Message $Message }
        default { Write-Verbose -Message $Message }
    }

    foreach ($sink in @($script:PCLogSinks)) {
        if (-not $sink) { continue }
        try {
            & $sink ([pscustomobject]@{
                Timestamp = $timestamp
                Level     = $Level
                Message   = $Message
                Line      = $line
            })
        }
        catch {
            Write-Debug "PCTools: log sink threw: $($_.Exception.Message)"
        }
    }
}
