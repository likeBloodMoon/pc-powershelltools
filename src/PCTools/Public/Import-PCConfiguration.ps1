function Import-PCConfiguration {
    <#
    .SYNOPSIS
        Loads user-defined maintenance profiles from a JSON file.

    .DESCRIPTION
        The "config file support (JSON)" item from the roadmap.

        A profile is already just data - a name, a description, whether to take a
        restore point, and an ordered list of actions - so a user-supplied config
        is the same data loaded from disk. Imported profiles are returned
        alongside the built-in ones by Get-PCMaintenanceProfile and can be run by
        Invoke-PCMaintenance without any further plumbing.

        Every action name is validated against the module's exported commands at
        import time, so a typo is caught here rather than halfway through a run.

    .PARAMETER Path
        The JSON file to load. Defaults to profiles.json in the profile store.

    .EXAMPLE
        Import-PCConfiguration -Path .\my-profiles.json
        Invoke-PCMaintenance -ProfileName 'Weekly' -WhatIf

    .EXAMPLE
        Format of the file:

        {
          "profiles": [
            {
              "name": "Weekly",
              "description": "What I actually run on Fridays",
              "restorePoint": false,
              "actions": [
                { "action": "Clear-PCTempFile" },
                { "action": "Clear-PCBrowserCache", "parameters": { "Browser": ["Chrome"] } }
              ]
            }
          ]
        }

    .OUTPUTS
        pscustomobject - the profiles that were loaded.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Path
    )

    if (-not $Path) { $Path = Join-Path (Get-PCProfileStore) 'profiles.json' }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No configuration file at '$Path'."
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    try {
        $config = $raw | ConvertFrom-Json
    }
    catch {
        throw "'$Path' is not valid JSON: $($_.Exception.Message)"
    }

    if (-not $config.PSObject.Properties['profiles']) {
        throw "'$Path' has no 'profiles' array."
    }

    # Extension actions are valid in a profile even though they are not
    # exported - Invoke-PCMaintenance resolves them through the extension table.
    # Validating against exports alone would reject a profile that works.
    $exported = @((Get-Module PCTools).ExportedFunctions.Keys) + @($script:PCExtension.Keys)
    $loaded = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in @($config.profiles)) {
        # Reading an absent property is a terminating error under StrictMode,
        # so every field from user JSON is probed before it is read.
        if (-not $entry.PSObject.Properties['name'] -or -not $entry.name) {
            throw "A profile in '$Path' has no name."
        }

        # Guard before touching the property: under StrictMode, reading an
        # absent property is a terminating error, and the raw error is far less
        # useful than saying which profile is malformed.
        if (-not $entry.PSObject.Properties['actions'] -or -not @($entry.actions).Count) {
            throw "Profile '$($entry.name)' has no actions."
        }

        $actions = foreach ($step in @($entry.actions)) {
            if (-not $step.PSObject.Properties['action'] -or -not $step.action) {
                throw "Profile '$($entry.name)' has an action with no 'action' name."
            }
            if ($exported -notcontains $step.action) {
                throw ("Profile '{0}' references '{1}', which is neither a PCTools command nor a registered extension. " +
                       "Run Get-Command -Module PCTools for the commands, and Get-PCExtension for the extensions." -f
                       $entry.name, $step.action)
            }

            $parameters = @{}
            if ($step.PSObject.Properties['parameters'] -and $step.parameters) {
                foreach ($property in $step.parameters.PSObject.Properties) {
                    $parameters[$property.Name] = $property.Value
                }
            }

            @{ Action = $step.action; Parameters = $parameters }
        }

        if (-not $actions) {
            throw "Profile '$($entry.name)' produced no usable actions."
        }

        $loaded.Add([pscustomobject]@{
            PSTypeName   = 'PCTools.MaintenanceProfile'
            Name         = $entry.name
            Description  = if ($entry.PSObject.Properties['description']) { $entry.description } else { 'User-defined profile' }
            RestorePoint = if ($entry.PSObject.Properties['restorePoint']) { [bool]$entry.restorePoint } else { $true }
            Actions      = @($actions)
            Source       = $Path
        })
    }

    # Replace rather than append, so re-importing an edited file does not leave
    # the previous version shadowing it.
    $script:PCImportedProfile = $loaded
    Write-PCLog -Level INFO -Message "Loaded $($loaded.Count) profile(s) from $Path"

    $loaded
}
