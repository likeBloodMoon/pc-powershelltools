function Get-PCCriticalServiceName {
    <#
    .SYNOPSIS
        The services this module refuses to reconfigure.

    .DESCRIPTION
        The internet is full of "services you can safely disable" lists, and
        following one is a reliable way to produce a machine that will not boot,
        will not reach the network, or cannot install updates. This list is the
        opposite: the services no amount of user insistence will get
        Set-PCServiceStartup to touch.

        It is deliberately short. It is not a list of services that are useful -
        it is the list where getting it wrong means an unbootable machine or a
        support call, and where the space or CPU saved would be negligible
        anyway.

        Kept as a function rather than a variable so it has somewhere to explain
        itself and so the tests can assert against it.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    @(
        # Boot and session
        'BFE'              # Base Filtering Engine - the firewall stops working
        'CoreMessagingRegistrar'
        'DcomLaunch'       # taking this out does not let the machine boot
        'LSM'
        'PlugPlay'
        'Power'
        'ProfSvc'          # user profiles do not load
        'RpcSs'
        'RpcEptMapper'
        'SamSs'
        'Schedule'         # every scheduled task, including this module's own
        'SystemEventsBroker'
        'UserManager'
        'Winmgmt'          # WMI: half of this module stops working

        # Storage and filesystem
        'PartMgr'
        'Volsnap'          # no shadow copies means no restore points

        # Network
        'Dhcp'
        'Dnscache'
        'NlaSvc'
        'nsi'
        'Netman'
        'WinHttpAutoProxySvc'

        # Security and servicing
        'CryptSvc'         # signature verification, and therefore updates
        'EventLog'
        'MpsSvc'           # Windows Firewall
        'TrustedInstaller' # DISM and SFC repair
        'wuauserv'         # Windows Update
        'BITS'             # how updates actually download
        'gpsvc'            # group policy; disabling this can lock you out
    )
}
