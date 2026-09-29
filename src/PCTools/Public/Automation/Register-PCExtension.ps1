function Register-PCExtension {
    <#
    .SYNOPSIS
        Loads custom actions from disk so they can be used like built-in ones.

    .DESCRIPTION
        Everything in this module is a function returning a PCTools.ActionResult,
        and Invoke-PCMaintenance resolves actions by name. That makes a plugin
        model almost free: define a function of the same shape, drop it in
        %LOCALAPPDATA%\PCTools\extensions as a *.PCAction.ps1 file, and it can
        be named in a profile alongside Clear-PCTempFile.

        Understand what this is. An extension is a PowerShell script that runs
        in your session with whatever rights that session has - it is code you
        are choosing to run, exactly like any other script. This does not
        sandbox it and cannot. The checks it does make are about catching
        mistakes, not about containing hostile code:

          - the file must be under the extensions folder
          - it must parse
          - it must define at least one Verb-PCNoun function
          - a name that collides with a built-in is refused, so an extension
            cannot silently replace Clear-PCTempFile with its own version

        Only load extensions you wrote or would be willing to read.

        Where an extension action can be used: name it in a maintenance profile,
        or pass it to Invoke-PCMaintenance -Action. It is deliberately not
        exported as a top-level command - it is loaded into the module's scope so
        it can call Invoke-PCAction and the other private helpers, which is what
        makes its results the same shape as a built-in's, and a module cannot
        export a function after it has finished loading.

    .PARAMETER Path
        A specific extension file to load. Defaults to every *.PCAction.ps1 in
        the extensions folder.

    .PARAMETER PassThru
        Return the loaded actions.

    .EXAMPLE
        Register-PCExtension -PassThru

    .EXAMPLE
        Register-PCExtension
        Invoke-PCMaintenance -Action 'Invoke-PCMyBackup'

        Running one extension action directly.

    .EXAMPLE
        Get-PCExtension | Format-Table Name, File

    .OUTPUTS
        PCTools.Extension when -PassThru is given.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [string[]]$Path,

        [switch]$PassThru
    )

    $root = $script:PCExtensionDirectory

    # Wrapped in @(): assigning the result of an `if` unrolls a one-element
    # array to a scalar, and then .Count below is a strict-mode error rather
    # than 1. A single extension file is the common case, so this was not a
    # corner to worry about but the normal path.
    $files = @(if ($Path) {
        @($Path | ForEach-Object {
            if (-not (Test-Path -LiteralPath $_)) { throw "No such extension file: $_" }
            (Resolve-Path -LiteralPath $_).ProviderPath
        })
    }
    elseif (Test-Path -LiteralPath $root) {
        @(Get-ChildItem -LiteralPath $root -Filter '*.PCAction.ps1' -File -Recurse |
            ForEach-Object { $_.FullName })
    }
    else {
        @()
    })

    if ($files.Count -eq 0) {
        Write-PCLog -Level DEBUG -Message "No extensions found in $root"
        return
    }

    $builtIn = @((Get-Module $script:ModuleName).ExportedFunctions.Keys)
    $loaded = [System.Collections.Generic.List[object]]::new()

    foreach ($file in $files) {
        # Refuse anything outside the extensions folder unless it was named
        # explicitly, so a stray path in a config file cannot pull in a script
        # from somewhere unexpected.
        if (-not $Path) {
            $resolvedRoot = (Resolve-Path -LiteralPath $root).ProviderPath
            if (-not $file.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-PCLog -Level WARN -Message "Skipping extension outside the extensions folder: $file"
                continue
            }
        }

        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors)

        if ($parseErrors) {
            Write-PCLog -Level WARN -Message "Extension $file has $($parseErrors.Count) parse error(s) and was not loaded."
            continue
        }

        $definitions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $false) | Where-Object { $_.Name -match '^\w+-PC\w+$' })

        $functions = @($definitions | ForEach-Object { $_.Name })

        if ($functions.Count -eq 0) {
            Write-PCLog -Level WARN -Message "Extension $file defines no Verb-PCNoun function and was not loaded."
            continue
        }

        $collision = @($functions | Where-Object { $builtIn -contains $_ })
        if ($collision.Count -gt 0) {
            Write-PCLog -Level WARN -Message "Extension $file would replace built-in command(s): $($collision -join ', '). Not loaded."
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($file, "Load extension defining $($functions -join ', ')")) { continue }

        foreach ($definition in $definitions) {
            # The function's own body, as a scriptblock built here. Two reasons
            # rather than dot-sourcing the file:
            #
            # - Dot-sourcing from inside a function defines the function in that
            #   function's scope, which is gone the moment this returns. The
            #   extension appeared to load and was then uncallable.
            # - A scriptblock created here belongs to the module's session
            #   state, so an extension action can call Invoke-PCAction and the
            #   other private helpers. That is what makes its result the same
            #   shape as a built-in's.
            $command = $null
            try {
                $command = $definition.Body.GetScriptBlock()
            }
            catch {
                Write-PCLog -Level WARN -Message "Extension action $($definition.Name) could not be prepared: $($_.Exception.Message)"
                continue
            }

            $entry = [pscustomobject]@{
                PSTypeName = 'PCTools.Extension'
                Name       = $definition.Name
                File       = $file
                LoadedAt   = Get-Date
                Command    = $command
            }

            $script:PCExtension[$definition.Name] = $entry
            $loaded.Add($entry)
            Write-PCLog -Level INFO -Message "Extension action registered: $($definition.Name) (from $(Split-Path -Leaf $file))"
        }
    }

    if ($PassThru) { $loaded }
}
