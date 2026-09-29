function Set-PCServiceStartup {
    <#
    .SYNOPSIS
        Changes a service's startup type, refusing the ones that matter.

    .DESCRIPTION
        Set-Service will happily disable the Base Filtering Engine and leave you
        with a machine that has no firewall and no VPN. This will not: the
        services on Get-PCCriticalServiceName are refused outright, and there is
        no -Force to talk it round. If you genuinely need to disable one of
        them, Set-Service is still right there - but it should be a deliberate
        act, not something a maintenance tool does on your behalf.

        The previous startup type is returned in the result, so a change can be
        undone without having recorded it first.

        This is not in any maintenance profile and it never will be. Which
        services a given machine needs depends on what that machine does.

    .PARAMETER Name
        The service to change.

    .PARAMETER StartupType
        Automatic, AutomaticDelayedStart, Manual or Disabled.

    .PARAMETER StopNow
        Also stop the service if it is running and the new type is Disabled.

    .EXAMPLE
        Set-PCServiceStartup -Name 'Fax' -StartupType Disabled -WhatIf

    .EXAMPLE
        Set-PCServiceStartup -Name 'SysMain' -StartupType Manual

    .OUTPUTS
        PCTools.ActionResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Name,

        [Parameter(Mandatory, Position = 1)]
        [ValidateSet('Automatic', 'AutomaticDelayedStart', 'Manual', 'Disabled')]
        [string]$StartupType,

        [switch]$StopNow
    )

    Invoke-PCAction -Name 'Set-PCServiceStartup' -Body {
        Assert-PCAdmin -Action 'Changing a service startup type'

        $critical = Get-PCCriticalServiceName
        $changed = @()
        $refused = @()
        $failed = @()
        $previous = @{}

        foreach ($serviceName in $Name) {
            if ($critical -contains $serviceName) {
                $refused += $serviceName
                Write-PCLog -Level WARN -Message "Refusing to reconfigure $serviceName - it is on the critical list."
                continue
            }

            $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
            if (-not $service) {
                $failed += "$serviceName (no such service)"
                continue
            }

            $was = if ($service.StartMode -eq 'Auto' -and $service.DelayedAutoStart) { 'AutomaticDelayedStart' }
                   elseif ($service.StartMode -eq 'Auto') { 'Automatic' }
                   else { [string]$service.StartMode }

            $previous[$serviceName] = $was

            if ($was -eq $StartupType) { continue }

            if (-not $PSCmdlet.ShouldProcess($serviceName, "Set startup type from $was to $StartupType")) { continue }

            try {
                # Set-Service gained AutomaticDelayedStart only in PowerShell 6,
                # and this module runs on 5.1, so sc.exe covers that one case.
                if ($StartupType -eq 'AutomaticDelayedStart') {
                    $run = Invoke-PCProcess -FilePath 'sc.exe' -ArgumentList @('config', $serviceName, 'start=', 'delayed-auto') -TimeoutSeconds 30
                    if ($run.ExitCode -ne 0) { throw "sc.exe config failed with exit code $($run.ExitCode): $($run.Output)" }
                }
                else {
                    Set-Service -Name $serviceName -StartupType $StartupType -ErrorAction Stop
                }

                if ($StopNow -and $StartupType -eq 'Disabled' -and $service.State -eq 'Running') {
                    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
                }

                $changed += "$serviceName ($was -> $StartupType)"
                Write-PCLog -Level INFO -Message "Service $serviceName startup type changed from $was to $StartupType"
            }
            catch {
                $failed += "$serviceName ($($_.Exception.Message))"
            }
        }

        $parts = @()
        if ($changed.Count) { $parts += '{0} changed: {1}' -f $changed.Count, ($changed -join ', ') }
        if ($refused.Count) { $parts += 'refused as critical: {0}' -f ($refused -join ', ') }
        if ($failed.Count) { $parts += '{0} failed: {1}' -f $failed.Count, ($failed -join ', ') }

        @{
            Status = if ($failed.Count -eq 0 -and $refused.Count -eq 0 -and $changed.Count -gt 0) { 'Success' }
                     elseif ($changed.Count -gt 0) { 'Warning' }
                     elseif ($failed.Count -gt 0 -or $refused.Count -gt 0) { 'Failed' }
                     else { 'Skipped' }
            Detail = if ($parts.Count) { $parts -join '; ' } else { 'Nothing to change.' }
            Data   = @{ Changed = $changed; Refused = $refused; Failed = $failed; PreviousStartupType = $previous }
        }
    }
}
