function Get-PCNetworkReport {
    <#
    .SYNOPSIS
        Builds a full network diagnostic report.

    .DESCRIPTION
        The module-side replacement for Net Diag's Run-QuickDiagnostics and
        Start-FullDiagnosticsWorker. Both of those ran on the UI thread; this
        returns data and leaves scheduling to the caller, which is what lets the
        GUI run it on a background runspace.

    .PARAMETER Full
        Also capture ipconfig /all, route print, netsh interface config, the
        WinHTTP proxy, firewall profiles and wireless interface state. Slower.

    .PARAMETER TimeoutSeconds
        Per-command timeout for the external tools in a full report.

    .EXAMPLE
        Get-PCNetworkReport -Full | Export-PCReport -Path ~\Desktop

    .OUTPUTS
        pscustomobject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$Full,

        [ValidateRange(5, 300)]
        [int]$TimeoutSeconds = 30
    )

    Write-PCLog -Level INFO -Message "Building $(if ($Full) { 'full' } else { 'quick' }) network report"

    $adapters = @(Get-PCNetworkAdapter)
    $tests = @(Test-PCConnectivity)

    $routes = @()
    try {
        $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
            Sort-Object RouteMetric |
            Select-Object -First 25 DestinationPrefix, NextHop, InterfaceAlias, RouteMetric)
    }
    catch {
        Write-PCLog -Level DEBUG -Message "Get-NetRoute failed: $($_.Exception.Message)"
    }

    $report = [pscustomobject]@{
        PSTypeName   = 'PCTools.NetworkReport'
        ComputerName = $env:COMPUTERNAME
        User         = "$env:USERDOMAIN\$env:USERNAME"
        IsAdmin      = Test-PCAdmin
        Timestamp    = Get-Date
        Adapters     = $adapters
        Routes       = $routes
        Tests        = $tests
        Verdict      = Get-PCConnectivityVerdict -TestResult $tests
        Full         = $null
    }

    if ($Full) {
        $commands = [ordered]@{
            IpconfigAll          = @{ File = 'ipconfig.exe'; Args = @('/all') }
            RoutePrint           = @{ File = 'route.exe';    Args = @('print') }
            NetshInterfaceConfig = @{ File = 'netsh.exe';    Args = @('interface', 'ip', 'show', 'config') }
            WinHttpProxy         = @{ File = 'netsh.exe';    Args = @('winhttp', 'show', 'proxy') }
            FirewallProfiles     = @{ File = 'netsh.exe';    Args = @('advfirewall', 'show', 'allprofiles') }
            WlanInterfaces       = @{ File = 'netsh.exe';    Args = @('wlan', 'show', 'interfaces') }
        }

        # Six read-only captures that do not depend on each other. Serially the
        # user waited for their sum; concurrently, for the slowest of them.
        Write-PCLog -Level INFO -Message "Capturing $($commands.Count) system views"

        $keys = @($commands.Keys)
        $descriptors = foreach ($key in $keys) {
            @{ Key = $key; File = $commands[$key].File; Args = $commands[$key].Args }
        }

        $captureBody = {
            param($Descriptor, $Timeout)
            $run = Invoke-PCProcess -FilePath $Descriptor.File -ArgumentList $Descriptor.Args -TimeoutSeconds $Timeout
            $run.Output
        }

        $completed = @(Invoke-PCParallel -InputObject @($descriptors) -ScriptBlock $captureBody `
            -ArgumentList @($TimeoutSeconds) `
            -InitScript (Get-PCFunctionSource -Name 'Invoke-PCProcess' -IncludeLogStub) `
            -ThrottleLimit 6 -TimeoutSeconds ([math]::Max(60, $TimeoutSeconds * 2)))

        $byIndex = @{}
        foreach ($item in $completed) { $byIndex[$item.Index] = $item }

        $extras = [ordered]@{}
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $value = '(not captured)'
            if ($byIndex.ContainsKey($i)) {
                if ($byIndex[$i].Output) { $value = [string]$byIndex[$i].Output }
                elseif ($byIndex[$i].Error) { $value = "Capture failed: $($byIndex[$i].Error)" }
            }
            $extras[$keys[$i]] = $value
        }

        $report.Full = [pscustomobject]$extras
    }

    $report
}
