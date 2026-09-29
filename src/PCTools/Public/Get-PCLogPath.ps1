function Get-PCLogPath {
    <#
    .SYNOPSIS
        Returns the path of the current PCTools log file.

    .DESCRIPTION
        The log lives under %LOCALAPPDATA%\PCTools\logs and is rotated when it
        exceeds 2 MB, so it never grows without bound on a machine where the
        tools are used regularly.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # The log file is prepared on first use rather than at import, so a caller
    # asking where it is counts as first use.
    if (-not $script:PCLogReady) { Initialize-PCLog }

    $script:PCLogPath
}
