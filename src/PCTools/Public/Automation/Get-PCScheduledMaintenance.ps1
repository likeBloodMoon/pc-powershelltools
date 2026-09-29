function Get-PCScheduledMaintenance {
    <#
    .SYNOPSIS
        Shows the scheduled maintenance tasks this module has registered.

    .DESCRIPTION
        Answers the question the dashboard asks on startup: is anything
        scheduled, when does it next run, and did the last run work.

        Only tasks registered by Register-PCScheduledMaintenance are reported -
        matched on the action actually invoking Invoke-PCTools, so a task
        someone renamed is still found and an unrelated task that happens to
        share a name is not.

    .PARAMETER TaskName
        Limit to a specific task name.

    .EXAMPLE
        Get-PCScheduledMaintenance | Format-Table TaskName, ProfileName, NextRunTime, LastResult

    .OUTPUTS
        PCTools.ScheduledMaintenance
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$TaskName
    )

    $tasks = @()
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop)
    }
    catch {
        Write-PCLog -Level DEBUG -Message "Could not enumerate scheduled tasks: $($_.Exception.Message)"
        return
    }

    foreach ($task in $tasks) {
        if ($TaskName -and $task.TaskName -ne $TaskName) { continue }

        $arguments = ''
        try {
            $arguments = (@($task.Actions | ForEach-Object { $_.Arguments }) -join ' ')
        }
        catch { continue }

        if ($arguments -notmatch 'Invoke-PCTools') { continue }

        $profileName = ''
        if ($arguments -match "-ProfileName\s+'([^']+)'") { $profileName = $Matches[1] }

        $info = $null
        try { $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop } catch { }

        # 267011 is "task has not yet run", which is not a failure.
        $lastResult = if ($info) { [int]$info.LastTaskResult } else { $null }
        $resultText = switch ($lastResult) {
            $null   { 'Unknown' }
            0       { 'Succeeded' }
            1       { 'Completed with warnings' }
            2       { 'An action failed' }
            3010    { 'Succeeded; restart required' }
            267011  { 'Has not run yet' }
            default { "Exit code $lastResult" }
        }

        [pscustomobject]@{
            PSTypeName   = 'PCTools.ScheduledMaintenance'
            TaskName     = $task.TaskName
            TaskPath     = $task.TaskPath
            ProfileName  = $profileName
            State        = [string]$task.State
            Description  = $task.Description
            NextRunTime  = if ($info) { $info.NextRunTime } else { $null }
            LastRunTime  = if ($info) { $info.LastRunTime } else { $null }
            LastResult   = $resultText
            LastExitCode = $lastResult
        }
    }
}
