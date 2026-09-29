#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
    Static analysis of the GUI shell.

    The shell cannot be exercised headlessly - it needs WinForms and a desktop -
    but its most damaging bugs are structural and visible in the AST. These
    tests cover the three that actually bit this codebase.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ShellPath = Join-Path $script:RepoRoot 'src/PCTools/Shell/Start-PCToolsShell.ps1'

    $script:ShellAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ShellPath, [ref]$null, [ref]$null)

    $script:ShellText = Get-Content -LiteralPath $script:ShellPath -Raw

    Import-Module (Join-Path $script:RepoRoot 'src/PCTools/PCTools.psd1') -Force
    $script:ExportedCommand = (Get-Module PCTools).ExportedFunctions.Keys
}

AfterAll {
    Remove-Module PCTools -Force -ErrorAction SilentlyContinue
}

Describe 'Shell structure' {

    It 'requires PowerShell 5.1, the runtime WinForms needs' {
        $script:ShellText | Should -Match '#requires -Version 5\.1'
    }

    It 'ships inside the module, so a Gallery install carries the GUI' {
        # The whole point of moving it: Install-Module PCTools then Start-PCTools,
        # with no separate archive download.
        $script:ShellPath | Should -Match '[\\/]src[\\/]PCTools[\\/]Shell[\\/]'
        $script:ExportedCommand | Should -Contain 'Start-PCTools'
    }

    It 'does not re-import the module it is running inside' {
        # Start-PCTools invokes this script from within PCTools. An
        # Import-Module -Force here would tear down and rebuild the module
        # mid-call.
        $script:ShellText | Should -Match 'if \(Get-Module -Name PCTools\)'
    }

    It 'declares every control key it later reads' {
        # Under Set-StrictMode -Version Latest, reading an undeclared hashtable
        # key is a terminating error, so an undeclared key is a crash waiting
        # for the right code path.
        $declaredBlock = [regex]::Match($script:ShellText, '(?s)\$controls = @\{(.*?)\n\}')
        $declaredBlock.Success | Should -BeTrue -Because 'the Controls initializer must exist'

        $declared = [regex]::Matches($declaredBlock.Groups[1].Value, '(?m)^\s*(\w+)\s*=') |
            ForEach-Object { $_.Groups[1].Value }

        $used = [regex]::Matches($script:ShellText, '\$(?:script:)?[Ss]ync\.Controls\.(\w+)') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique

        foreach ($key in $used) {
            $declared | Should -Contain $key -Because "Sync.Controls.$key is read somewhere in the shell"
        }
    }

    It 'never captures $this inside GetNewClosure' {
        # GetNewClosure() snapshots the current scope. Applied to an event
        # handler that uses $this, it captures $null and shadows the sender
        # WinForms supplies at click time.
        $closures = $script:ShellAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Member.Value -eq 'GetNewClosure'
        }, $true)

        foreach ($closure in $closures) {
            $closure.Expression.Extent.Text | Should -Not -Match '\$this' -Because 'GetNewClosure would capture $this as null'
        }
    }

    It 'calls only PCTools commands that the module exports' {
        # Catches a renamed or mistyped action before a user finds it by
        # clicking the button that no longer works.
        $commands = $script:ShellAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true)

        $pcCommands = $commands |
            ForEach-Object { $_.GetCommandName() } |
            Where-Object { $_ -and $_ -match '^\w+-PC\w+$' } |
            Sort-Object -Unique

        $pcCommands.Count | Should -BeGreaterThan 0 -Because 'the shell is supposed to drive the module'

        foreach ($name in $pcCommands) {
            $script:ExportedCommand | Should -Contain $name
        }
    }

    It 'runs every module action through the background runspace, not the UI thread' {
        # The whole point of the shell rewrite. A direct call to a long-running
        # action from a click handler is the freeze the original tools had.
        $handlers = [regex]::Matches(
            $script:ShellText,
            '(?s)Add_Click\(\{(.*?)\}\)')

        $longRunning = @(
            'Repair-PCSystemImage', 'Repair-PCSystemFile', 'Test-PCDisk',
            'Invoke-PCMaintenance', 'Get-PCNetworkReport', 'Reset-PCNetworkStack',
            'Install-PCApplication'
        )

        foreach ($handler in $handlers) {
            $body = $handler.Groups[1].Value
            foreach ($action in $longRunning) {
                if ($body -match "(?<!\w)$([regex]::Escape($action))(?!\w)") {
                    # Permitted only inside a Start-ShellTask/Start-NetworkAction
                    # -Script block, which runs on a runspace.
                    $body | Should -Match 'Start-ShellTask|Start-NetworkAction|Start-Maintenance|Start-NetworkDiagnostic' `
                        -Because "$action must not run on the UI thread"
                }
            }
        }
    }

    It 'binds Invoke-UI arguments into a closure rather than relying on scope capture' {
        # A block queued with BeginInvoke runs after its creating scope is gone.
        $script:ShellText | Should -Match 'GetNewClosure\(\)' -Because 'Invoke-UI must bind its arguments'
        $script:ShellText | Should -Match '\$boundScript @boundArguments'
    }

    It 'disposes the runspace pool when the window closes' {
        $script:ShellText | Should -Match '\$script:Pool\.Dispose\(\)'
    }

    It 'guards against closing while a task is still running' {
        $script:ShellText | Should -Match 'Add_FormClosing'
        $script:ShellText | Should -Match '\$closingArgs\.Cancel = \$true'
    }
}

Describe 'Shell safety prompts' {

    It 'confirms before resetting the network stack' {
        # Winsock reset removes third-party LSPs and needs a restart. It must
        # never be one unguarded click.
        $script:ShellText | Should -Match "(?s)Reset the TCP/IP and Winsock stack.*?MessageBox"
    }

    It 'offers a preview that passes -WhatIf through' {
        $script:ShellText | Should -Match "\`$parameters\['WhatIf'\] = \`$true"
    }
}
