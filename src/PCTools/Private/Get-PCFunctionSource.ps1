function Get-PCFunctionSource {
    <#
    .SYNOPSIS
        Returns the source of named module functions as a scriptblock that
        redefines them.

    .DESCRIPTION
        A runspace started by Invoke-PCParallel has no modules loaded, so a
        parallel body cannot call a PCTools helper. The obvious workaround -
        reimplementing the helper inline in the body - creates two copies of the
        same logic that drift apart, and the probe helpers here (Test-PCPing,
        Test-PCTcpPort) are exactly the code that must not quietly differ
        between the sequential and parallel paths.

        So the definition itself is shipped into the runspace. There is one
        implementation of a ping; the parallel path runs that one.

        Only helpers that are already self-contained can travel this way. Ones
        that log get a no-op Write-PCLog alongside them, since a background
        runspace has no log file handle and its Write-Verbose output is
        discarded anyway.

    .PARAMETER Name
        The functions to include, in dependency order.

    .PARAMETER IncludeLogStub
        Also define a no-op Write-PCLog, for helpers that call it.

    .OUTPUTS
        scriptblock
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Name,

        [switch]$IncludeLogStub
    )

    $builder = [System.Text.StringBuilder]::new()

    if ($IncludeLogStub) {
        [void]$builder.AppendLine('function Write-PCLog { param([string]$Message, [string]$Level = ''INFO'') }')
    }

    foreach ($functionName in $Name) {
        $command = Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue
        if (-not $command) {
            throw "Get-PCFunctionSource: no such function '$functionName'."
        }

        [void]$builder.AppendLine("function $functionName {")
        [void]$builder.AppendLine($command.Definition)
        [void]$builder.AppendLine('}')
    }

    [scriptblock]::Create($builder.ToString())
}
