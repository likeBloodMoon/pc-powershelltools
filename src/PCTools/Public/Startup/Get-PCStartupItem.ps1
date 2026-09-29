function Get-PCStartupItem {
    <#
    .SYNOPSIS
        Lists everything that starts with Windows, from every place it can hide.

    .DESCRIPTION
        Task Manager's Startup tab shows the Run keys and the Startup folders.
        It does not show logon-triggered scheduled tasks, which is where a good
        deal of modern updater and telemetry software actually lives. Somebody
        who disables everything in Task Manager and still has eleven things
        starting is usually looking at scheduled tasks.

        So all four sources are read into one list:

          - HKLM and HKCU Run and RunOnce keys, 32- and 64-bit views
          - the per-user and all-users Startup folders
          - scheduled tasks with a logon or boot trigger

        Enabled state comes from StartupApproved, which is where Task Manager
        records what the user has switched off; a Run key entry disabled in Task
        Manager is still present in the registry, and reporting it as enabled
        would be wrong.

    .PARAMETER IncludeDisabled
        Include items that are present but switched off. On by default, since
        "what did I disable" is half the reason to look.

    .PARAMETER Source
        Limit to Registry, Folder or ScheduledTask.

    .EXAMPLE
        Get-PCStartupItem | Format-Table Name, Source, Enabled, Publisher, Command

    .EXAMPLE
        Get-PCStartupItem | Where-Object Enabled | Measure-Object

    .OUTPUTS
        PCTools.StartupItem
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [bool]$IncludeDisabled = $true,

        [ValidateSet('Registry', 'Folder', 'ScheduledTask')]
        [string[]]$Source
    )

    $emit = {
        param($Name, $ItemSource, $Location, $Command, $Enabled, $Scope, $Id)
        [pscustomobject]@{
            PSTypeName = 'PCTools.StartupItem'
            Name       = $Name
            Source     = $ItemSource
            Scope      = $Scope
            Enabled    = $Enabled
            Command    = $Command
            Location   = $Location
            Id         = $Id
        }
    }

    $wanted = if ($Source) { $Source } else { 'Registry', 'Folder', 'ScheduledTask' }
    $items = [System.Collections.Generic.List[object]]::new()

    # StartupApproved records what Task Manager has switched off. The first byte
    # of the value carries the flag: an even value is enabled, odd is disabled.
    $approvedState = @{}
    $approvedKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    )

    foreach ($key in $approvedKeys) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        try {
            $properties = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($property in $properties.PSObject.Properties) {
                if ($property.Name -like 'PS*') { continue }
                $value = $property.Value
                if ($value -is [byte[]] -and $value.Length -gt 0) {
                    $approvedState[$property.Name] = (($value[0] % 2) -eq 0)
                }
            }
        }
        catch {
            Write-PCLog -Level DEBUG -Message "Could not read ${key}: $($_.Exception.Message)"
        }
    }

    if ($wanted -contains 'Registry') {
        $runKeys = @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';                        Scope = 'CurrentUser' }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce';                    Scope = 'CurrentUser' }
            @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';                        Scope = 'AllUsers' }
            @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce';                    Scope = 'AllUsers' }
            @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';            Scope = 'AllUsers (32-bit)' }
            @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce';        Scope = 'AllUsers (32-bit)' }
        )

        foreach ($runKey in $runKeys) {
            if (-not (Test-Path -LiteralPath $runKey.Path)) { continue }

            try {
                $properties = Get-ItemProperty -LiteralPath $runKey.Path -ErrorAction Stop
            }
            catch {
                Write-PCLog -Level DEBUG -Message "Could not read $($runKey.Path): $($_.Exception.Message)"
                continue
            }

            foreach ($property in $properties.PSObject.Properties) {
                if ($property.Name -like 'PS*') { continue }

                $enabled = $true
                if ($approvedState.ContainsKey($property.Name)) { $enabled = $approvedState[$property.Name] }

                $items.Add((& $emit $property.Name 'Registry' $runKey.Path ([string]$property.Value) $enabled $runKey.Scope $property.Name))
            }
        }
    }

    if ($wanted -contains 'Folder') {
        $startupFolders = @(
            @{ Path = [Environment]::GetFolderPath('Startup');       Scope = 'CurrentUser' }
            @{ Path = [Environment]::GetFolderPath('CommonStartup'); Scope = 'AllUsers' }
        )

        foreach ($folder in $startupFolders) {
            if (-not $folder.Path -or -not (Test-Path -LiteralPath $folder.Path)) { continue }

            foreach ($file in @(Get-ChildItem -LiteralPath $folder.Path -File -Force -ErrorAction SilentlyContinue)) {
                if ($file.Name -eq 'desktop.ini') { continue }

                $enabled = $true
                if ($approvedState.ContainsKey($file.Name)) { $enabled = $approvedState[$file.Name] }

                $items.Add((& $emit $file.BaseName 'Folder' $folder.Path $file.FullName $enabled $folder.Scope $file.Name))
            }
        }
    }

    if ($wanted -contains 'ScheduledTask') {
        try {
            foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
                $triggers = @($task.Triggers | Where-Object {
                    $_.CimClass.CimClassName -in 'MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger'
                })
                if ($triggers.Count -eq 0) { continue }

                # Microsoft's own maintenance tasks are not "startup software" in
                # the sense anybody means when they ask what starts with Windows,
                # and listing 200 of them buries the four that matter.
                if ($task.TaskPath -like '\Microsoft\Windows\*') { continue }

                $command = ''
                try {
                    $actions = @($task.Actions | Where-Object { $_.Execute })
                    if ($actions.Count -gt 0) {
                        $command = ($actions | ForEach-Object { ($_.Execute, $_.Arguments -join ' ').Trim() }) -join ' ; '
                    }
                }
                catch { }

                $items.Add((& $emit $task.TaskName 'ScheduledTask' $task.TaskPath $command `
                    ($task.State -ne 'Disabled') 'AllUsers' "$($task.TaskPath)$($task.TaskName)"))
            }
        }
        catch {
            Write-PCLog -Level DEBUG -Message "Could not enumerate scheduled tasks: $($_.Exception.Message)"
        }
    }

    $output = $items
    if (-not $IncludeDisabled) {
        $output = @($items | Where-Object Enabled)
    }

    $output | Sort-Object @{ Expression = 'Enabled'; Descending = $true }, Source, Name
}
