function Get-PCService {
    <#
    .SYNOPSIS
        Lists services with their startup type and what they belong to.

    .DESCRIPTION
        Get-Service tells you a service is running. It does not tell you whether
        it starts automatically, what binary is behind it, or whether it is part
        of Windows - which are the three things anybody deciding what to switch
        off actually needs.

        Every row is graded: Critical services are on the refusal list that
        Set-PCServiceStartup will not touch, Windows services ship with the OS,
        and ThirdParty is everything else. The last group is where the wins are.

    .PARAMETER Name
        Limit to these service names.

    .PARAMETER StartupType
        Limit to services with this startup type.

    .PARAMETER ThirdPartyOnly
        Show only services that did not come with Windows.

    .EXAMPLE
        Get-PCService -ThirdPartyOnly | Where-Object StartupType -eq 'Automatic' |
            Format-Table Name, DisplayName, Status, Path

    .OUTPUTS
        PCTools.Service
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]]$Name,

        [ValidateSet('Automatic', 'AutomaticDelayedStart', 'Manual', 'Disabled')]
        [string[]]$StartupType,

        [switch]$ThirdPartyOnly
    )

    $services = @()
    try {
        $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
    }
    catch {
        Write-PCLog -Level WARN -Message "Could not read services: $($_.Exception.Message)"
        return
    }

    $critical = Get-PCCriticalServiceName

    foreach ($service in $services) {
        if ($Name -and $Name -notcontains $service.Name) { continue }

        # DelayedAutoStart is a separate flag; Win32_Service reports the mode as
        # 'Auto' either way, and the difference matters to boot time.
        $mode = switch ($service.StartMode) {
            'Auto'     { if ($service.DelayedAutoStart) { 'AutomaticDelayedStart' } else { 'Automatic' } }
            'Manual'   { 'Manual' }
            'Disabled' { 'Disabled' }
            default    { [string]$service.StartMode }
        }

        if ($StartupType -and $StartupType -notcontains $mode) { continue }

        $path = [string]$service.PathName

        # The binary's location is the most reliable signal available without
        # checking signatures: a service running out of System32 came with
        # Windows, one running out of Program Files did not.
        $category = if ($critical -contains $service.Name) { 'Critical' }
                    elseif ($path -match '(?i)\\Windows\\(System32|SysWOW64|servicing)\\') { 'Windows' }
                    else { 'ThirdParty' }

        if ($ThirdPartyOnly -and $category -ne 'ThirdParty') { continue }

        [pscustomobject]@{
            PSTypeName   = 'PCTools.Service'
            Name         = $service.Name
            DisplayName  = $service.DisplayName
            Status       = $service.State
            StartupType  = $mode
            Category     = $category
            Path         = $path
            Description  = $service.Description
            CanDisable   = $category -ne 'Critical'
        }
    }
}
