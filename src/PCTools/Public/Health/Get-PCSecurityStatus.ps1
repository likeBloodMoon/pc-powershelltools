function Get-PCSecurityStatus {
    <#
    .SYNOPSIS
        Reports this machine's security posture. Reads only; changes nothing.

    .DESCRIPTION
        Defender, firewall, BitLocker, UAC, SmartScreen and pending updates, in
        one place, because they are configured in six different places and
        nobody checks all six.

        This command deliberately has no counterpart that turns things on. A
        maintenance tool that silently reconfigures antivirus or drops the
        firewall is indistinguishable from malware, and a tool that turns
        protection *on* without being asked is a tool that breaks somebody's
        deliberate configuration. Each finding says what to do; doing it stays
        the user's decision, in the Windows UI that owns the setting.

    .EXAMPLE
        Get-PCSecurityStatus | Format-List

    .EXAMPLE
        (Get-PCSecurityStatus).Findings

    .OUTPUTS
        PCTools.SecurityStatus
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $findings = [System.Collections.Generic.List[string]]::new()

    # --- Defender -----------------------------------------------------------
    $defender = [ordered]@{
        Available            = $false
        RealTimeProtection   = $null
        AntivirusEnabled     = $null
        SignatureAge         = $null
        SignatureVersion     = ''
        LastQuickScan        = $null
    }

    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        $defender.Available = $true
        $defender.RealTimeProtection = [bool]$status.RealTimeProtectionEnabled
        $defender.AntivirusEnabled = [bool]$status.AntivirusEnabled
        $defender.SignatureAge = [int]$status.AntivirusSignatureAge
        $defender.SignatureVersion = [string]$status.AntivirusSignatureVersion
        $defender.LastQuickScan = $status.QuickScanEndTime

        if (-not $status.RealTimeProtectionEnabled) {
            $findings.Add('Defender real-time protection is off.')
        }
        if ([int]$status.AntivirusSignatureAge -gt 7) {
            $findings.Add("Defender signatures are $([int]$status.AntivirusSignatureAge) days old.")
        }
    }
    catch {
        # Absent on Server core installs, and replaced wholesale by third-party
        # suites - neither of which is a problem worth reporting as one.
        Write-PCLog -Level DEBUG -Message "Defender status unavailable: $($_.Exception.Message)"
    }

    # --- Third-party antivirus ---------------------------------------------
    $antivirusProducts = @()
    try {
        $antivirusProducts = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop |
            ForEach-Object { $_.displayName })
    }
    catch { }

    # --- Firewall -----------------------------------------------------------
    $firewall = @()
    try {
        foreach ($profileEntry in @(Get-NetFirewallProfile -ErrorAction Stop)) {
            $firewall += [pscustomobject]@{
                Name    = $profileEntry.Name
                Enabled = [bool]$profileEntry.Enabled
            }
            if (-not $profileEntry.Enabled) {
                $findings.Add("The $($profileEntry.Name) firewall profile is off.")
            }
        }
    }
    catch {
        Write-PCLog -Level DEBUG -Message "Firewall profiles unavailable: $($_.Exception.Message)"
    }

    # --- BitLocker ----------------------------------------------------------
    $bitlocker = @()
    try {
        foreach ($volume in @(Get-BitLockerVolume -ErrorAction Stop)) {
            $bitlocker += [pscustomobject]@{
                MountPoint       = $volume.MountPoint
                ProtectionStatus = [string]$volume.ProtectionStatus
                EncryptionMethod = [string]$volume.EncryptionMethod
            }
        }

        $systemVolume = $bitlocker | Where-Object { $_.MountPoint -eq $env:SystemDrive }
        if ($systemVolume -and $systemVolume.ProtectionStatus -ne 'On') {
            $findings.Add("$env:SystemDrive is not encrypted with BitLocker.")
        }
    }
    catch {
        # Home editions have no BitLocker cmdlets at all.
        Write-PCLog -Level DEBUG -Message "BitLocker status unavailable: $($_.Exception.Message)"
    }

    # --- UAC ----------------------------------------------------------------
    $uacEnabled = $null
    try {
        $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop
        $uacEnabled = [int]$policy.EnableLUA -eq 1
        if (-not $uacEnabled) {
            $findings.Add('User Account Control is disabled, so elevation prompts are suppressed.')
        }
    }
    catch { }

    # --- SmartScreen --------------------------------------------------------
    $smartScreen = ''
    try {
        $explorerPolicy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -ErrorAction SilentlyContinue
        if ($explorerPolicy -and $explorerPolicy.PSObject.Properties.Name -contains 'EnableSmartScreen') {
            $smartScreen = if ([int]$explorerPolicy.EnableSmartScreen -eq 1) { 'On (policy)' } else { 'Off (policy)' }
        }
        else {
            $shellPolicy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -ErrorAction SilentlyContinue
            if ($shellPolicy -and $shellPolicy.PSObject.Properties.Name -contains 'SmartScreenEnabled') {
                $smartScreen = [string]$shellPolicy.SmartScreenEnabled
            }
        }
    }
    catch { }

    if ($smartScreen -match '^(Off|Off \(policy\))$') {
        $findings.Add('SmartScreen application reputation checking is off.')
    }

    # --- Pending reboot -----------------------------------------------------
    $rebootPending = $false
    $rebootKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($key in $rebootKeys) {
        if (Test-Path -LiteralPath $key) { $rebootPending = $true; break }
    }
    if ($rebootPending) {
        $findings.Add('A restart is pending; updates are not fully applied until it happens.')
    }

    $grade = if ($findings.Count -eq 0) { 'Good' }
             elseif ($findings.Count -le 2) { 'Fair' }
             else { 'Needs attention' }

    [pscustomobject]@{
        PSTypeName        = 'PCTools.SecurityStatus'
        Grade             = $grade
        Defender          = [pscustomobject]$defender
        AntivirusProducts = $antivirusProducts
        Firewall          = $firewall
        BitLocker         = $bitlocker
        UacEnabled        = $uacEnabled
        SmartScreen       = $smartScreen
        RebootPending     = $rebootPending
        Findings          = @($findings)
    }
}
