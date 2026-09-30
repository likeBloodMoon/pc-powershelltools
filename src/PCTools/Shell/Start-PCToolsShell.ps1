#requires -Version 5.1
<#
.SYNOPSIS
    PC Tools - the unified GUI shell for pc-powershelltools.

.DESCRIPTION
    Promotes gui-framework.ps1 from a demo into the application shell, and
    replaces the two bespoke WinForms UIs in pc-cleanuptool.ps1 and
    pc-netdiag.ps1.

    The shell owns presentation only. Every action it runs comes from the
    PCTools module, on a background runspace, so the window stays responsive
    during a DISM run that the original tools would have frozen for half an
    hour.

    It now lives inside the module, so a PowerShell Gallery install carries the
    GUI as well as the commands. Start it with Start-PCTools rather than by
    path; running this file directly still works and is what the STA relaunch
    below does.

.PARAMETER Theme
    Dark or Light. Defaults to Dark.

.PARAMETER Page
    The page to open on. Defaults to the dashboard.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-PCToolsShell.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('Dark', 'Light')]
    [string]$Theme = 'Dark',

    [ValidateSet('Dashboard', 'Maintenance', 'Storage', 'Health', 'Network', 'Software', 'Preferences', 'Log')]
    [string]$Page = 'Dashboard'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Bootstrap

# WinForms needs a single-threaded apartment. Windows PowerShell 5.1 gives us
# one by default; pwsh.exe does not, and the failure mode without this check is
# a window that opens and immediately deadlocks.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Warning 'This shell requires an STA host. Relaunching under Windows PowerShell...'
    $relaunch = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
        '-File', "`"$PSCommandPath`"", '-Theme', $Theme, '-Page', $Page
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunch
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Microsoft.VisualBasic supplies InputBox, which WinForms itself has no
# equivalent for and which beats hand-rolling a modal prompt form.
Add-Type -AssemblyName Microsoft.VisualBasic

# Per-monitor DPI awareness. Without it the fixed-pixel layouts in the original
# tools render blurry and clip their text at 150% scaling, which is the default
# on most laptops sold in the last five years.
if (-not ('PCTools.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace PCTools {
    public static class Native {
        public const int WM_NCLBUTTONDOWN = 0xA1;
        public const int HTCAPTION = 0x2;

        [DllImport("user32.dll")]
        public static extern bool ReleaseCapture();

        [DllImport("user32.dll")]
        public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, int wParam, int lParam);

        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();

        [DllImport("shcore.dll")]
        public static extern int SetProcessDpiAwareness(int value);

        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    }
}
'@
}

try {
    # PROCESS_PER_MONITOR_DPI_AWARE = 2. Falls back on Windows 7/8.
    [void][PCTools.Native]::SetProcessDpiAwareness(2)
}
catch {
    try { [void][PCTools.Native]::SetProcessDPIAware() } catch { }
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# Surface UI-thread exceptions instead of closing the window silently, which is
# what the original Cleanup Tool did on any unhandled error.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode(
    [System.Windows.Forms.UnhandledExceptionMode]::CatchException)

#endregion

#region Module import

$script:ShellRoot = $PSScriptRoot

# The shell lives inside the module (src/PCTools/Shell), so the manifest is one
# level up. Start-PCTools has already imported it; running this file directly
# has not, which is why both cases are handled.
$modulePath = Join-Path (Split-Path -Parent $script:ShellRoot) 'PCTools.psd1'

if (Get-Module -Name PCTools) {
    # Already loaded - do not re-import. -Force would tear down and rebuild the
    # module while Start-PCTools is executing out of it.
    # Prefer the manifest: the background runspaces import this path, and a
    # manifest import gives them the same export surface the UI thread has.
    $loaded = Get-Module -Name PCTools
    $loadedManifest = Join-Path $loaded.ModuleBase 'PCTools.psd1'
    $modulePath = if (Test-Path -LiteralPath $loadedManifest) { $loadedManifest } else { $loaded.Path }
}
elseif (Test-Path -LiteralPath $modulePath) {
    Import-Module $modulePath -Force -ErrorAction Stop
}
elseif (Get-Module -ListAvailable -Name PCTools) {
    Import-Module PCTools -Force -ErrorAction Stop
    $modulePath = (Get-Module PCTools).Path
}
else {
    [System.Windows.Forms.MessageBox]::Show(
        "The PCTools module could not be found.`r`n`r`nExpected at:`r`n$modulePath",
        'PC Tools', 'OK', 'Error') | Out-Null
    return
}

$script:ModulePath = $modulePath

#endregion

#region Application state

$script:App = [ordered]@{
    Name    = 'PC Tools'
    Version = (Get-Module PCTools).Version.ToString()
    Window  = @{ Width = 1120; Height = 760; MinWidth = 940; MinHeight = 620 }
    Async   = @{ MaxRunspaces = 3 }
}

# Everything the UI thread and the runspaces both touch lives here.
# Every control key is declared up front and set later during construction.
# Under Set-StrictMode -Version Latest, reading a key that does not yet exist
# is a terminating error - so a guard like `if ($sync.Controls.StatusLabel)`
# would throw instead of returning false. Declaring them removes that whole
# class of failure.
$controls = @{
    SubtitleLabel   = $null
    ElevateButton   = $null
    ContentHost     = $null
    StatusLabel     = $null
    SummaryLabel    = $null
    Progress        = $null
    RunButtons      = $null
    MaintenanceGrid = $null
    AdapterGrid     = $null
    VerdictLabel    = $null
    AdviceLabel     = $null
    NetworkGrid     = $null
    PreferenceGrid  = $null
    LogGrid         = $null
    HealthScore     = $null
    HealthSummary   = $null
    FindingGrid     = $null
    DiskGrid        = $null
    StorageGrid     = $null
    UsageGrid       = $null
    StartupGrid     = $null
    SoftwareGrid    = $null
    DashboardStatus = $null
    HealthText      = $null
}

$sync = [hashtable]::Synchronized(@{
    Form     = $null
    Controls = $controls
    Theme    = $Theme
    LogQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    Tasks    = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    Busy     = $false
})

$script:Sync = $sync

#endregion

#region Theme

$script:Themes = @{
    Dark = @{
        Back       = [System.Drawing.Color]::FromArgb(18, 18, 20)
        Panel      = [System.Drawing.Color]::FromArgb(24, 24, 28)
        Card       = [System.Drawing.Color]::FromArgb(30, 30, 36)
        Text       = [System.Drawing.Color]::FromArgb(230, 230, 235)
        Muted      = [System.Drawing.Color]::FromArgb(158, 158, 170)
        Border     = [System.Drawing.Color]::FromArgb(52, 52, 62)
        Button     = [System.Drawing.Color]::FromArgb(38, 38, 46)
        Accent     = [System.Drawing.Color]::FromArgb(64, 132, 214)
        AccentText = [System.Drawing.Color]::White
        Success    = [System.Drawing.Color]::FromArgb(88, 190, 120)
        Warning    = [System.Drawing.Color]::FromArgb(226, 178, 78)
        Danger     = [System.Drawing.Color]::FromArgb(224, 108, 108)
    }
    Light = @{
        Back       = [System.Drawing.Color]::FromArgb(244, 245, 248)
        Panel      = [System.Drawing.Color]::FromArgb(255, 255, 255)
        Card       = [System.Drawing.Color]::FromArgb(255, 255, 255)
        Text       = [System.Drawing.Color]::FromArgb(28, 28, 34)
        Muted      = [System.Drawing.Color]::FromArgb(96, 96, 108)
        Border     = [System.Drawing.Color]::FromArgb(212, 214, 222)
        Button     = [System.Drawing.Color]::FromArgb(238, 239, 243)
        Accent     = [System.Drawing.Color]::FromArgb(28, 106, 200)
        AccentText = [System.Drawing.Color]::White
        Success    = [System.Drawing.Color]::FromArgb(28, 138, 68)
        Warning    = [System.Drawing.Color]::FromArgb(168, 118, 16)
        Danger     = [System.Drawing.Color]::FromArgb(190, 58, 58)
    }
}

function Get-ThemeColor {
    param([Parameter(Mandatory)][string]$Name)
    $script:Themes[$script:Sync.Theme][$Name]
}

#endregion

#region Fonts

function New-ShellFont {
    param(
        [double]$Size = 9.5,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )

    $family = 'Segoe UI'
    try {
        $available = [System.Drawing.FontFamily]::Families | ForEach-Object Name
        if ($available -notcontains $family) { $family = 'Microsoft Sans Serif' }
    }
    catch { $family = 'Microsoft Sans Serif' }

    New-Object System.Drawing.Font($family, [single]$Size, $Style)
}

$script:FontBody   = New-ShellFont 9.5
$script:FontBold   = New-ShellFont 9.5 ([System.Drawing.FontStyle]::Bold)
$script:FontHeader = New-ShellFont 13 ([System.Drawing.FontStyle]::Bold)
$script:FontTitle  = New-ShellFont 11 ([System.Drawing.FontStyle]::Bold)
$script:FontMono   = New-Object System.Drawing.Font('Consolas', 9)

#endregion

#region UI marshalling

function Invoke-UI {
    <#
        Runs a scriptblock on the UI thread.

        Arguments are passed explicitly rather than captured from the calling
        scope. That distinction is not cosmetic: when the block is queued with
        BeginInvoke it executes after the calling function has returned, and a
        captured local is no longer resolvable by then - the block fails with
        "the expression after '&' produced an object that was not valid" rather
        than doing anything useful. The original framework got away with it only
        because its callers happened to already be on the UI thread, where
        InvokeRequired is false and the block runs synchronously.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [object[]]$Arguments = @()
    )

    $form = $script:Sync.Form
    if (-not $form -or $form.IsDisposed) { return }

    # Bind the arguments into a closure now, while the caller's values are
    # still live. GetNewClosure() copies them into a fresh scope that lives as
    # long as the scriptblock, so the block is self-contained by the time the
    # UI thread runs it - and this does not depend on how WinForms marshals a
    # delegate's parameter array.
    $bound = if ($Arguments.Count -gt 0) {
        $boundScript = $Script
        $boundArguments = $Arguments
        { & $boundScript @boundArguments }.GetNewClosure()
    }
    else {
        $Script
    }

    if ($form.InvokeRequired) {
        try { $null = $form.BeginInvoke($bound) } catch { }
    }
    else {
        & $bound
    }
}

function Write-ShellLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $script:Sync.LogQueue.Enqueue([pscustomobject]@{
        Timestamp = Get-Date -Format 'HH:mm:ss'
        Level     = $Level
        Message   = $Message
    })
}

#endregion

#region Async runspace pool

$script:Pool = [runspacefactory]::CreateRunspacePool(1, $script:App.Async.MaxRunspaces)
$script:Pool.ApartmentState = 'STA'
$script:Pool.ThreadOptions = 'ReuseThread'
$script:Pool.Open()

function Start-ShellTask {
    <#
        Runs work on a background runspace and calls back on the UI thread.

        The runspace imports PCTools itself - a runspace does not inherit the
        caller's modules - and registers a log sink that pushes the module's own
        log lines onto the shared queue, so the log pane shows progress from
        inside a long DISM run instead of nothing until it finishes.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script,
        [hashtable]$Arguments = @{},
        [scriptblock]$OnSuccess,
        [scriptblock]$OnError,
        [scriptblock]$OnFinally
    )

    if ($script:Sync.Busy) {
        Write-ShellLog -Level WARN -Message "Busy: '$Name' was not started."
        return
    }

    $script:Sync.Busy = $true
    Set-ShellStatus -Text $Name -Busy $true
    Write-ShellLog -Level INFO -Message "Started: $Name"

    $wrapper = {
        param($ModulePath, $Body, $BodyArguments, $SharedState)

        Import-Module $ModulePath -Force -ErrorAction Stop

        # Bridge module logging into the shell's log pane.
        $sinkId = Register-PCLogSink {
            param($entry)
            $SharedState.LogQueue.Enqueue([pscustomobject]@{
                Timestamp = ($entry.Timestamp -split ' ')[-1]
                Level     = $entry.Level
                Message   = $entry.Message
            })
        }.GetNewClosure()

        try {
            & $Body @BodyArguments
        }
        finally {
            Unregister-PCLogSink -Id $sinkId
        }
    }

    $shell = [powershell]::Create()
    $shell.RunspacePool = $script:Pool
    $null = $shell.AddScript($wrapper).
        AddArgument($script:ModulePath).
        AddArgument($Script).
        AddArgument($Arguments).
        AddArgument($script:Sync)

    $handle = $shell.BeginInvoke()

    [void]$script:Sync.Tasks.Add([pscustomobject]@{
        Name      = $Name
        Shell     = $shell
        Handle    = $handle
        OnSuccess = $OnSuccess
        OnError   = $OnError
        OnFinally = $OnFinally
    })
}

function Complete-ShellTask {
    param([Parameter(Mandatory)]$Task)

    try {
        $result = $Task.Shell.EndInvoke($Task.Handle)

        $errors = @($Task.Shell.Streams.Error)
        foreach ($record in $errors) {
            Write-ShellLog -Level WARN -Message $record.Exception.Message
        }

        Write-ShellLog -Level INFO -Message "Finished: $($Task.Name)"

        if ($Task.OnSuccess) {
            Invoke-UI -Script { param($Callback, $Value) & $Callback $Value } `
                      -Arguments @($Task.OnSuccess, $result)
        }
    }
    catch {
        $message = "$($Task.Name) failed: $($_.Exception.Message)"
        Write-ShellLog -Level ERROR -Message $message

        if ($Task.OnError) {
            Invoke-UI -Script { param($Callback, $Value) & $Callback $Value } `
                      -Arguments @($Task.OnError, $_)
        }
    }
    finally {
        try { $Task.Shell.Dispose() } catch { }

        if ($Task.OnFinally) {
            Invoke-UI -Script { param($Callback) & $Callback } -Arguments @($Task.OnFinally)
        }

        $script:Sync.Busy = $false
        Set-ShellStatus -Text 'Ready' -Busy $false
    }
}

#endregion

#region UI factory

function New-Card {
    param([string]$Title, [int]$Padding = 16)

    $card = New-Object System.Windows.Forms.Panel
    $card.Dock = 'Fill'
    $card.Padding = New-Object System.Windows.Forms.Padding($Padding)
    $card.BackColor = Get-ThemeColor Card
    $card.Tag = 'Card'

    if ($Title) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Title
        $label.Dock = 'Top'
        $label.Height = 30
        $label.Font = $script:FontTitle
        $label.ForeColor = Get-ThemeColor Text
        $label.Tag = 'Heading'
        $card.Controls.Add($label)
    }

    $card
}

function New-Button {
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$Width = 170,
        [int]$Height = 34,
        [switch]$Accent,
        [scriptblock]$OnClick
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = $Height
    $button.Font = $script:FontBody
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 1
    $button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8)
    $button.Cursor = 'Hand'
    $button.Tag = if ($Accent) { 'AccentButton' } else { 'Button' }

    if ($OnClick) { $button.Add_Click($OnClick) }

    $button
}

function New-CheckBox {
    param([Parameter(Mandatory)][string]$Text, [string]$Name, [bool]$Checked = $false)

    $box = New-Object System.Windows.Forms.CheckBox
    $box.Text = $Text
    $box.AutoSize = $true
    $box.Checked = $Checked
    $box.Font = $script:FontBody
    $box.ForeColor = Get-ThemeColor Text
    $box.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    $box.Tag = $Name
    $box
}

function New-ResultGrid {
    $grid = New-Object System.Windows.Forms.ListView
    $grid.Dock = 'Fill'
    $grid.View = 'Details'
    $grid.FullRowSelect = $true
    $grid.GridLines = $false
    $grid.HideSelection = $false
    $grid.Font = $script:FontBody
    $grid.BorderStyle = 'None'
    $grid.OwnerDraw = $false
    [void]$grid.Columns.Add('Status', 90)
    [void]$grid.Columns.Add('Action', 200)
    [void]$grid.Columns.Add('Freed', 90)
    [void]$grid.Columns.Add('Detail', 640)
    $grid
}

function Add-ResultRow {
    <#
        Renders one PCTools.ActionResult into a grid. The colour comes from the
        status, so a failure is visible without reading every row - the original
        log box printed everything in the same grey.
    #>
    param(
        [Parameter(Mandatory)]$Grid,
        [Parameter(Mandatory)]$Result
    )

    $item = New-Object System.Windows.Forms.ListViewItem($Result.Status)
    [void]$item.SubItems.Add([string]$Result.Action)
    [void]$item.SubItems.Add($(if ($Result.BytesFreed -gt 0) { $Result.FreedDisplay } else { '' }))
    [void]$item.SubItems.Add([string]$Result.Detail)

    $item.ForeColor = switch ($Result.Status) {
        'Success' { Get-ThemeColor Success }
        'Warning' { Get-ThemeColor Warning }
        'Failed'  { Get-ThemeColor Danger }
        default   { Get-ThemeColor Muted }
    }

    [void]$Grid.Items.Add($item)
    $Grid.EnsureVisible($Grid.Items.Count - 1)
}

function Show-Summary {
    <#
        The results summary the roadmap asked for: one line the user can read
        instead of interpreting a log.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Result)

    $label = $script:Sync.Controls.SummaryLabel
    if (-not $label) { return }

    if ($Result.Count -eq 0) {
        $label.Text = ''
        return
    }

    $succeeded = @($Result | Where-Object Status -eq 'Success').Count
    $failed = @($Result | Where-Object Status -eq 'Failed').Count
    $warned = @($Result | Where-Object Status -eq 'Warning').Count
    $freed = 0L
    $measured = $Result | Measure-Object -Property BytesFreed -Sum
    if ($measured -and $null -ne $measured.Sum) { $freed = [long]$measured.Sum }
    $reboot = @($Result | Where-Object RebootRequired).Count -gt 0

    $parts = @("$($Result.Count) action(s)", "$succeeded ok")
    if ($warned) { $parts += "$warned warning" }
    if ($failed) { $parts += "$failed failed" }
    if ($freed -gt 0) { $parts += "$(Format-PCByteSize -Bytes $freed) reclaimed" }
    if ($reboot) { $parts += 'restart required' }

    $label.Text = $parts -join '  -  '
    $label.ForeColor = if ($failed) { Get-ThemeColor Danger }
                       elseif ($warned -or $reboot) { Get-ThemeColor Warning }
                       else { Get-ThemeColor Success }
}

function Set-ShellStatus {
    param([string]$Text = 'Ready', [bool]$Busy = $false)

    Invoke-UI -Script {
        param($StatusText, $IsBusy)
        $controls = $script:Sync.Controls
        if ($controls.StatusLabel) { $controls.StatusLabel.Text = $StatusText }
        if ($controls.Progress) { $controls.Progress.Visible = $IsBusy }
        foreach ($button in @($controls.RunButtons)) {
            if ($button -and -not $button.IsDisposed) { $button.Enabled = -not $IsBusy }
        }
    } -Arguments @($Text, $Busy)
}

#endregion

#region Window chrome

$form = New-Object System.Windows.Forms.Form
$script:Sync.Form = $form
$form.Text = "$($script:App.Name) $($script:App.Version)"
$form.FormBorderStyle = 'Sizable'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size($script:App.Window.Width, $script:App.Window.Height)
$form.MinimumSize = New-Object System.Drawing.Size($script:App.Window.MinWidth, $script:App.Window.MinHeight)
$form.BackColor = Get-ThemeColor Back
$form.Font = $script:FontBody

$form.SuspendLayout()

# Root: a 2x2 grid - header spans the top, nav on the left, content on the
# right, status bar across the bottom. Everything docks, so the window resizes
# properly. The original Cleanup Tool used absolute Point/Size coordinates and
# had to disable its own maximize button as a result.
$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 2
$root.RowCount = 3
$root.Padding = New-Object System.Windows.Forms.Padding(12)
$root.BackColor = Get-ThemeColor Back
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 210)))
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 56)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
$form.Controls.Add($root)

# Header
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Fill'
$header.BackColor = Get-ThemeColor Back
$root.Controls.Add($header, 0, 0)
$root.SetColumnSpan($header, 2)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $script:App.Name
$titleLabel.Font = $script:FontHeader
$titleLabel.ForeColor = Get-ThemeColor Text
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(2, 2)
$header.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Font = $script:FontBody
$subtitleLabel.ForeColor = Get-ThemeColor Muted
$subtitleLabel.AutoSize = $true
$subtitleLabel.Location = New-Object System.Drawing.Point(3, 28)
$header.Controls.Add($subtitleLabel)
$script:Sync.Controls.SubtitleLabel = $subtitleLabel

$headerButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$headerButtons.Dock = 'Right'
$headerButtons.FlowDirection = 'RightToLeft'
$headerButtons.WrapContents = $false
$headerButtons.AutoSize = $true
$header.Controls.Add($headerButtons)

$themeButton = New-Button -Text 'Theme' -Width 80 -Height 28
$headerButtons.Controls.Add($themeButton)

$elevateButton = New-Button -Text 'Restart as admin' -Width 140 -Height 28
$headerButtons.Controls.Add($elevateButton)
$script:Sync.Controls.ElevateButton = $elevateButton

# Left navigation
$nav = New-Object System.Windows.Forms.FlowLayoutPanel
$nav.Dock = 'Fill'
$nav.FlowDirection = 'TopDown'
$nav.WrapContents = $false
$nav.Padding = New-Object System.Windows.Forms.Padding(0, 4, 12, 0)
$nav.BackColor = Get-ThemeColor Back
$root.Controls.Add($nav, 0, 1)

# Content host - one panel per page, only one visible at a time
$contentHost = New-Object System.Windows.Forms.Panel
$contentHost.Dock = 'Fill'
$contentHost.BackColor = Get-ThemeColor Back
$root.Controls.Add($contentHost, 1, 1)
$script:Sync.Controls.ContentHost = $contentHost

# Status bar
$statusBar = New-Object System.Windows.Forms.TableLayoutPanel
$statusBar.Dock = 'Fill'
$statusBar.ColumnCount = 3
$statusBar.BackColor = Get-ThemeColor Panel
$statusBar.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
[void]$statusBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 260)))
[void]$statusBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$statusBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 170)))
$root.Controls.Add($statusBar, 0, 2)
$root.SetColumnSpan($statusBar, 2)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Ready'
$statusLabel.AutoSize = $false
$statusLabel.Dock = 'Fill'
$statusLabel.TextAlign = 'MiddleLeft'
$statusLabel.ForeColor = Get-ThemeColor Muted
$statusBar.Controls.Add($statusLabel, 0, 0)
$script:Sync.Controls.StatusLabel = $statusLabel

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.AutoSize = $false
$summaryLabel.Dock = 'Fill'
$summaryLabel.TextAlign = 'MiddleLeft'
$summaryLabel.Font = $script:FontBold
$summaryLabel.ForeColor = Get-ThemeColor Muted
$statusBar.Controls.Add($summaryLabel, 1, 0)
$script:Sync.Controls.SummaryLabel = $summaryLabel

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Dock = 'Fill'
$progress.Style = 'Marquee'
$progress.MarqueeAnimationSpeed = 28
$progress.Visible = $false
$statusBar.Controls.Add($progress, 2, 0)
$script:Sync.Controls.Progress = $progress

#endregion

#region Page infrastructure

$script:LastResults = @()
$script:LastReport = $null
$script:Pages = [ordered]@{}
$script:NavButtons = @{}
$script:Sync.Controls.RunButtons = [System.Collections.ArrayList]::new()

function Register-Page {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Subtitle,
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Panel
    )

    $Panel.Dock = 'Fill'
    $Panel.Visible = $false
    $Panel.Tag = $Subtitle
    $script:Sync.Controls.ContentHost.Controls.Add($Panel)
    $script:Pages[$Name] = $Panel

    $navButton = New-Button -Text $Name -Width 186 -Height 38
    $navButton.TextAlign = 'MiddleLeft'
    $navButton.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    # No GetNewClosure() here: it would capture $this as it is now (null) and
    # shadow the sender WinForms supplies when the click actually happens.
    $navButton.Add_Click({ Show-Page -Name $this.Text })
    $nav.Controls.Add($navButton)
    $script:NavButtons[$Name] = $navButton
}

function Show-Page {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($key in $script:Pages.Keys) {
        $script:Pages[$key].Visible = ($key -eq $Name)
    }

    foreach ($key in $script:NavButtons.Keys) {
        $button = $script:NavButtons[$key]
        $button.Tag = if ($key -eq $Name) { 'AccentButton' } else { 'Button' }
    }

    $script:Sync.Controls.SubtitleLabel.Text = $script:Pages[$Name].Tag
    Update-ThemeColors
}

#endregion

#region Dashboard page

<#
    The landing page. It answers, without being asked, the three questions
    somebody opening a maintenance tool actually has: is anything wrong, how
    much disk is left, and when did this last get looked after.

    Everything here is read-only. Opening the window must never change the
    machine.
#>

$dashboardPage = New-Object System.Windows.Forms.TableLayoutPanel
$dashboardPage.ColumnCount = 1
$dashboardPage.RowCount = 2
[void]$dashboardPage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 190)))
[void]$dashboardPage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$dashboardTop = New-Card -Title 'How this machine is doing'
$dashboardPage.Controls.Add($dashboardTop, 0, 0)

$dashboardInner = New-Object System.Windows.Forms.TableLayoutPanel
$dashboardInner.Dock = 'Fill'
$dashboardInner.ColumnCount = 2
$dashboardInner.RowCount = 1
[void]$dashboardInner.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
[void]$dashboardInner.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$dashboardTop.Controls.Add($dashboardInner)
$dashboardInner.BringToFront()

$healthScore = New-Object System.Windows.Forms.Label
$healthScore.Text = '--'
$healthScore.Dock = 'Fill'
$healthScore.TextAlign = 'MiddleCenter'
$healthScore.Font = New-ShellFont 40 ([System.Drawing.FontStyle]::Bold)
$healthScore.ForeColor = Get-ThemeColor Muted
$dashboardInner.Controls.Add($healthScore, 0, 0)
$script:Sync.Controls.HealthScore = $healthScore

$dashboardRight = New-Object System.Windows.Forms.FlowLayoutPanel
$dashboardRight.Dock = 'Fill'
$dashboardRight.FlowDirection = 'TopDown'
$dashboardRight.WrapContents = $false
$dashboardInner.Controls.Add($dashboardRight, 1, 0)

$healthSummary = New-Object System.Windows.Forms.Label
$healthSummary.Text = 'Press Check this PC for a read-only health report.'
$healthSummary.AutoSize = $false
$healthSummary.Width = 700
$healthSummary.Height = 46
$healthSummary.Font = $script:FontBold
$healthSummary.ForeColor = Get-ThemeColor Text
$dashboardRight.Controls.Add($healthSummary)
$script:Sync.Controls.HealthSummary = $healthSummary

$dashboardStatus = New-Object System.Windows.Forms.Label
$dashboardStatus.Text = ''
$dashboardStatus.AutoSize = $false
$dashboardStatus.Width = 700
$dashboardStatus.Height = 40
$dashboardStatus.Font = $script:FontBody
$dashboardStatus.ForeColor = Get-ThemeColor Muted
$dashboardRight.Controls.Add($dashboardStatus)
$script:Sync.Controls.DashboardStatus = $dashboardStatus

function Update-HealthReport {
    <#
        Renders a PCTools.HealthReport. Called on the UI thread from the task
        callback, never from the runspace.
    #>
    param($Report)

    if (-not $Report) { return }

    $score = $script:Sync.Controls.HealthScore
    $score.Text = [string]$Report.Score
    $score.ForeColor = if ($Report.Score -ge 75) { Get-ThemeColor Success }
                       elseif ($Report.Score -ge 55) { Get-ThemeColor Warning }
                       else { Get-ThemeColor Danger }

    $script:Sync.Controls.HealthSummary.Text = "$($Report.Grade) - $($Report.Summary)"

    $grid = $script:Sync.Controls.FindingGrid
    $grid.BeginUpdate()
    try {
        $grid.Items.Clear()
        foreach ($finding in @($Report.Findings)) {
            $row = New-Object System.Windows.Forms.ListViewItem([string]$finding.Severity)
            [void]$row.SubItems.Add([string]$finding.Area)
            [void]$row.SubItems.Add([string]$finding.Message)
            [void]$row.SubItems.Add([string]$finding.Command)
            $row.ForeColor = switch ($finding.Severity) {
                'Critical' { Get-ThemeColor Danger }
                'Warning'  { Get-ThemeColor Warning }
                default    { Get-ThemeColor Muted }
            }
            [void]$grid.Items.Add($row)
        }

        if (@($Report.Findings).Count -eq 0) {
            $row = New-Object System.Windows.Forms.ListViewItem('OK')
            [void]$row.SubItems.Add('')
            [void]$row.SubItems.Add('Nothing needs attention.')
            [void]$row.SubItems.Add('')
            $row.ForeColor = Get-ThemeColor Success
            [void]$grid.Items.Add($row)
        }
    }
    finally {
        $grid.EndUpdate()
    }
}

function Start-HealthCheck {
    Start-ShellTask -Name 'Check this PC' -Script {
        # Skipped because the dashboard should come back in seconds; the
        # Storage page runs the full scan when it is asked to.
        Get-PCHealthReport -SkipDiskUsage
    } -OnSuccess {
        param($report)
        Update-HealthReport -Report $report
    }
}

function Update-DashboardStatus {
    param($Text)
    $script:Sync.Controls.DashboardStatus.Text = [string]$Text
}

$dashboardButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$dashboardButtons.Dock = 'Bottom'
$dashboardButtons.Height = 44
$dashboardButtons.WrapContents = $false
$dashboardTop.Controls.Add($dashboardButtons)

$checkButton = New-Button -Text 'Check this PC' -Width 170 -Accent -OnClick { Start-HealthCheck }
$dashboardButtons.Controls.Add($checkButton)
[void]$script:Sync.Controls.RunButtons.Add($checkButton)

$quickCleanButton = New-Button -Text 'Quick clean' -Width 150 -OnClick {
    Start-Maintenance -ProfileOverride 'Quick'
}
$dashboardButtons.Controls.Add($quickCleanButton)
[void]$script:Sync.Controls.RunButtons.Add($quickCleanButton)

$historyButton = New-Button -Text 'Show history' -Width 150 -OnClick {
    Start-ShellTask -Name 'Read history' -Script {
        Get-PCHistory -Summary
    } -OnSuccess {
        param($summary)
        Update-DashboardStatus -Text $summary.Text
    }
}
$dashboardButtons.Controls.Add($historyButton)
[void]$script:Sync.Controls.RunButtons.Add($historyButton)

$reportButton = New-Button -Text 'Save HTML report' -Width 170 -OnClick {
    Start-ShellTask -Name 'Write report' -Script {
        Get-PCHealthReport -SkipDiskUsage | Export-PCReport -Format Html, Json -Confirm:$false
    } -OnSuccess {
        param($written)
        if ($written -and $written.HtmlPath) {
            Update-DashboardStatus -Text "Report written to $($written.HtmlPath)"
            Write-ShellLog -Level INFO -Message "Report written to $($written.HtmlPath)"
        }
    }
}
$dashboardButtons.Controls.Add($reportButton)
[void]$script:Sync.Controls.RunButtons.Add($reportButton)

$findingCard = New-Card -Title 'What to look at'
$dashboardPage.Controls.Add($findingCard, 0, 1)

$findingGrid = New-Object System.Windows.Forms.ListView
$findingGrid.Dock = 'Fill'
$findingGrid.View = 'Details'
$findingGrid.FullRowSelect = $true
$findingGrid.HideSelection = $false
$findingGrid.Font = $script:FontBody
$findingGrid.BorderStyle = 'None'
[void]$findingGrid.Columns.Add('Severity', 90)
[void]$findingGrid.Columns.Add('Area', 100)
[void]$findingGrid.Columns.Add('Finding', 620)
[void]$findingGrid.Columns.Add('Command', 220)
$findingCard.Controls.Add($findingGrid)
$findingGrid.BringToFront()
$script:Sync.Controls.FindingGrid = $findingGrid

Register-Page -Name 'Dashboard' -Subtitle 'How this machine is doing, at a glance' -Panel $dashboardPage

#endregion

#region Maintenance page

$maintenancePage = New-Object System.Windows.Forms.TableLayoutPanel
$maintenancePage.ColumnCount = 1
$maintenancePage.RowCount = 2
[void]$maintenancePage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 250)))
[void]$maintenancePage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$maintenanceCard = New-Card -Title 'Maintenance'
$maintenancePage.Controls.Add($maintenanceCard, 0, 0)

$maintenanceBody = New-Object System.Windows.Forms.TableLayoutPanel
$maintenanceBody.Dock = 'Fill'
$maintenanceBody.ColumnCount = 2
$maintenanceBody.RowCount = 1
[void]$maintenanceBody.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 55)))
[void]$maintenanceBody.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 45)))
$maintenanceCard.Controls.Add($maintenanceBody)
$maintenanceBody.BringToFront()

# Profile picker
$profilePanel = New-Object System.Windows.Forms.FlowLayoutPanel
$profilePanel.Dock = 'Fill'
$profilePanel.FlowDirection = 'TopDown'
$profilePanel.WrapContents = $false
$profilePanel.AutoScroll = $true
$maintenanceBody.Controls.Add($profilePanel, 0, 0)

$profileHint = New-Object System.Windows.Forms.Label
$profileHint.Text = 'Choose a profile, then preview it before running.'
$profileHint.AutoSize = $true
$profileHint.ForeColor = Get-ThemeColor Muted
$profileHint.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 8)
$profilePanel.Controls.Add($profileHint)

$script:ProfileRadios = @{}
foreach ($item in Get-PCMaintenanceProfile) {
    $radio = New-Object System.Windows.Forms.RadioButton
    $radio.Text = "$($item.Name)  -  $($item.Description)"
    $radio.AutoSize = $false
    $radio.Width = 520
    $radio.Height = 38
    $radio.Font = $script:FontBody
    $radio.ForeColor = Get-ThemeColor Text
    $radio.Checked = ($item.Name -eq 'Quick')
    $radio.Tag = $item.Name
    $profilePanel.Controls.Add($radio)
    $script:ProfileRadios[$item.Name] = $radio
}

$skipRestoreBox = New-CheckBox -Text 'Skip the restore point (not recommended)' -Name 'SkipRestore'
$skipRestoreBox.Margin = New-Object System.Windows.Forms.Padding(0, 12, 0, 4)
$profilePanel.Controls.Add($skipRestoreBox)

# Action buttons
$maintenanceActions = New-Object System.Windows.Forms.FlowLayoutPanel
$maintenanceActions.Dock = 'Fill'
$maintenanceActions.FlowDirection = 'TopDown'
$maintenanceActions.WrapContents = $false
$maintenanceBody.Controls.Add($maintenanceActions, 1, 0)

function Get-SelectedProfileName {
    foreach ($name in $script:ProfileRadios.Keys) {
        if ($script:ProfileRadios[$name].Checked) { return $name }
    }
    'Quick'
}

function Start-Maintenance {
    <#
        Preview mode passes -WhatIf all the way down, so the plan the user sees
        is produced by the same code path that would perform the work. That is
        the point of building the module on ShouldProcess rather than writing a
        separate "what would happen" description that can drift.
    #>
    param(
        [switch]$Preview,

        # Lets another page run a named profile without first reaching into the
        # Maintenance page's radio buttons to change what is selected there.
        [string]$ProfileOverride
    )

    $profileName = if ($ProfileOverride) { $ProfileOverride } else { Get-SelectedProfileName }
    $skipRestore = $skipRestoreBox.Checked
    $grid = $script:Sync.Controls.MaintenanceGrid
    $grid.Items.Clear()
    Show-Summary -Result @()

    $label = if ($Preview) { "Preview: $profileName" } else { "Maintenance: $profileName" }

    Start-ShellTask -Name $label -Arguments @{
        ProfileName = $profileName
        SkipRestore = [bool]$skipRestore
        Preview     = [bool]$Preview
    } -Script {
        param($ProfileName, $SkipRestore, $Preview)

        $parameters = @{
            ProfileName       = $ProfileName
            SkipRestorePoint  = $SkipRestore
            Confirm           = $false
        }
        if ($Preview) { $parameters['WhatIf'] = $true }

        $results = Invoke-PCMaintenance @parameters

        # Recorded here, on the runspace, rather than from a callback: the task
        # guard is still set while OnSuccess/OnFinally run, so a nested
        # Start-ShellTask would be turned away as busy.
        # Previews are not recorded - they changed nothing, and counting them
        # would skew every trend the history exists to show.
        if (-not $Preview) {
            $results | Save-PCHistory -ProfileName $ProfileName -Confirm:$false | Out-Null
        }

        $results
    } -OnSuccess {
        param($results)

        $items = @($results | Where-Object { $_ })
        foreach ($result in $items) {
            Add-ResultRow -Grid $script:Sync.Controls.MaintenanceGrid -Result $result
        }
        Show-Summary -Result $items

        # Kept so Export-PCReport has the real objects, not the grid's strings.
        $script:LastResults = $items

        if ($items.Count -eq 0) {
            Write-ShellLog -Level INFO -Message 'Preview produced no actions to perform.'
        }
    }
}

$previewButton = New-Button -Text 'Preview (no changes)' -Width 210 -OnClick { Start-Maintenance -Preview }
$maintenanceActions.Controls.Add($previewButton)
[void]$script:Sync.Controls.RunButtons.Add($previewButton)

$runButton = New-Button -Text 'Run maintenance' -Width 210 -Accent -OnClick {
    $profileName = Get-SelectedProfileName
    $item = Get-PCMaintenanceProfile -Name $profileName

    $message = "Run the '$profileName' profile?`r`n`r`n$($item.Description)"
    if (-not $skipRestoreBox.Checked -and $item.RestorePoint) {
        $message += "`r`n`r`nA system restore point will be created first."
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        $message, 'PC Tools', 'YesNo', 'Question')

    if ($answer -eq 'Yes') { Start-Maintenance }
}
$maintenanceActions.Controls.Add($runButton)
[void]$script:Sync.Controls.RunButtons.Add($runButton)

$exportButton = New-Button -Text 'Export report' -Width 210 -OnClick {
    $grid = $script:Sync.Controls.MaintenanceGrid
    if ($grid.Items.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Run something first.', 'PC Tools', 'OK', 'Information') | Out-Null
        return
    }
    if ($script:LastResults) {
        $paths = $script:LastResults | Export-PCReport
        if ($paths) {
            Write-ShellLog -Level INFO -Message "Report written to $($paths.TextPath)"
            Start-Process -FilePath $paths.TextPath
        }
    }
}
$maintenanceActions.Controls.Add($exportButton)

$openLogButton = New-Button -Text 'Open log file' -Width 210 -OnClick {
    $path = Get-PCLogPath
    if ($path -and (Test-Path -LiteralPath $path)) { Start-Process -FilePath $path }
    else { Write-ShellLog -Level WARN -Message 'No log file is available.' }
}
$maintenanceActions.Controls.Add($openLogButton)

# Results
$resultsCard = New-Card -Title 'Results'
$maintenancePage.Controls.Add($resultsCard, 0, 1)

$maintenanceGrid = New-ResultGrid
$resultsCard.Controls.Add($maintenanceGrid)
$maintenanceGrid.BringToFront()
$script:Sync.Controls.MaintenanceGrid = $maintenanceGrid

Register-Page -Name 'Maintenance' -Subtitle 'Clean up, repair and verify Windows' -Panel $maintenancePage

#endregion

#region Storage page

<#
    Where the space went, and what can be got back. The two are separate
    questions: the reclaims at the top are safe and repeatable, the usage scan
    below finds the 40 GB of forgotten virtual machine images that no cleanup
    action will ever touch.
#>

$storagePage = New-Object System.Windows.Forms.TableLayoutPanel
$storagePage.ColumnCount = 1
$storagePage.RowCount = 3
[void]$storagePage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
[void]$storagePage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 190)))
[void]$storagePage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$diskCard = New-Card -Title 'Drives'
$storagePage.Controls.Add($diskCard, 0, 0)

$diskGrid = New-Object System.Windows.Forms.ListView
$diskGrid.Dock = 'Fill'
$diskGrid.View = 'Details'
$diskGrid.FullRowSelect = $true
$diskGrid.Font = $script:FontBody
$diskGrid.BorderStyle = 'None'
[void]$diskGrid.Columns.Add('Drive', 70)
[void]$diskGrid.Columns.Add('Label', 160)
[void]$diskGrid.Columns.Add('Free', 100)
[void]$diskGrid.Columns.Add('Size', 100)
[void]$diskGrid.Columns.Add('Free %', 80)
[void]$diskGrid.Columns.Add('Pressure', 120)
$diskCard.Controls.Add($diskGrid)
$diskGrid.BringToFront()
$script:Sync.Controls.DiskGrid = $diskGrid

function Update-DiskGrid {
    param([AllowEmptyCollection()][object[]]$Disk)

    $grid = $script:Sync.Controls.DiskGrid
    $grid.BeginUpdate()
    try {
        $grid.Items.Clear()
        foreach ($item in $Disk) {
            $row = New-Object System.Windows.Forms.ListViewItem([string]$item.Drive)
            [void]$row.SubItems.Add([string]$item.Label)
            [void]$row.SubItems.Add([string]$item.FreeDisplay)
            [void]$row.SubItems.Add([string]$item.SizeDisplay)
            [void]$row.SubItems.Add($(if ($null -ne $item.PercentFree) { "$($item.PercentFree)%" } else { '?' }))
            [void]$row.SubItems.Add([string]$item.Pressure)
            $row.ForeColor = switch ($item.Pressure) {
                'Critical' { Get-ThemeColor Danger }
                'Low'      { Get-ThemeColor Warning }
                'Tight'    { Get-ThemeColor Warning }
                default    { Get-ThemeColor Text }
            }
            [void]$grid.Items.Add($row)
        }
    }
    finally {
        $grid.EndUpdate()
    }
}

$storageActionCard = New-Card -Title 'Reclaim space'
$storagePage.Controls.Add($storageActionCard, 0, 1)

$storageActions = New-Object System.Windows.Forms.FlowLayoutPanel
$storageActions.Dock = 'Fill'
$storageActions.AutoScroll = $true
$storageActionCard.Controls.Add($storageActions)
$storageActions.BringToFront()

function Start-StorageAction {
    <#
        One wrapper for the storage buttons, so each of them is three lines
        rather than a copy of the task plumbing.
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Script,
        [hashtable]$Arguments = @{}
    )

    Start-ShellTask -Name $Label -Arguments $Arguments -Script $Script -OnSuccess {
        param($results)
        $items = @($results | Where-Object { $_ })
        foreach ($result in $items) {
            Add-ResultRow -Grid $script:Sync.Controls.StorageGrid -Result $result
        }
        Show-Summary -Result $items
    }
}

$storageActions.Controls.Add((New-Button -Text 'Refresh drives' -Width 160 -Accent -OnClick {
    Start-ShellTask -Name 'Read drives' -Script { Get-PCDiskSpace } -OnSuccess {
        param($disks)
        Update-DiskGrid -Disk @($disks)
    }
}))

$storageActions.Controls.Add((New-Button -Text 'Storage clean-up' -Width 170 -OnClick {
    Start-StorageAction -Label 'Storage profile' -Script {
        Invoke-PCMaintenance -ProfileName 'Storage' -Confirm:$false
    }
}))

$storageActions.Controls.Add((New-Button -Text 'Delivery Optimization' -Width 190 -OnClick {
    Start-StorageAction -Label 'Clear Delivery Optimization' -Script {
        Clear-PCDeliveryOptimization -Confirm:$false
    }
}))

$storageActions.Controls.Add((New-Button -Text 'Crash dumps' -Width 150 -OnClick {
    Start-StorageAction -Label 'Clear crash dumps' -Script { Clear-PCCrashDump -Confirm:$false }
}))

$storageActions.Controls.Add((New-Button -Text 'Thumbnail cache' -Width 170 -OnClick {
    Start-StorageAction -Label 'Clear thumbnail cache' -Script { Clear-PCThumbnailCache -Confirm:$false }
}))

$storageActions.Controls.Add((New-Button -Text 'Previous Windows' -Width 180 -OnClick {
    # The one irreversible reclaim on this page, so it asks first and says
    # exactly what is given up.
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Delete the previous Windows installation (C:\Windows.old)?`r`n`r`n" +
         "This usually reclaims 15-30 GB, and it permanently removes the ability to " +
         "roll back to the previous Windows build.`r`n`r`n" +
         "It is refused if the folder is still inside the 10-day rollback window."),
        'PC Tools', 'YesNo', 'Warning')

    if ($answer -eq 'Yes') {
        Start-StorageAction -Label 'Remove Windows.old' -Script { Clear-PCWindowsOld -Confirm:$false }
    }
}))

$storageActions.Controls.Add((New-Button -Text 'Find large folders' -Width 180 -OnClick {
    Start-ShellTask -Name 'Scan disk usage' -Script {
        Get-PCDiskUsage -Top 25
    } -OnSuccess {
        param($usage)
        Update-UsageGrid -Usage $usage
    }
}))

$storageBottom = New-Object System.Windows.Forms.TableLayoutPanel
$storageBottom.Dock = 'Fill'
$storageBottom.ColumnCount = 2
$storageBottom.RowCount = 1
[void]$storageBottom.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$storageBottom.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$storagePage.Controls.Add($storageBottom, 0, 2)

$usageCard = New-Card -Title 'Largest folders and files'
$storageBottom.Controls.Add($usageCard, 0, 0)

$usageGrid = New-Object System.Windows.Forms.ListView
$usageGrid.Dock = 'Fill'
$usageGrid.View = 'Details'
$usageGrid.FullRowSelect = $true
$usageGrid.Font = $script:FontBody
$usageGrid.BorderStyle = 'None'
[void]$usageGrid.Columns.Add('Size', 90)
[void]$usageGrid.Columns.Add('Path', 460)
$usageCard.Controls.Add($usageGrid)
$usageGrid.BringToFront()
$script:Sync.Controls.UsageGrid = $usageGrid

function Update-UsageGrid {
    param($Usage)

    $grid = $script:Sync.Controls.UsageGrid
    $grid.BeginUpdate()
    try {
        $grid.Items.Clear()
        if (-not $Usage) { return }

        foreach ($entry in @($Usage.LargestFolders)) {
            $row = New-Object System.Windows.Forms.ListViewItem([string]$entry.SizeDisplay)
            [void]$row.SubItems.Add([string]$entry.Path)
            $row.ForeColor = Get-ThemeColor Text
            [void]$grid.Items.Add($row)
        }
        foreach ($entry in @($Usage.LargestFiles)) {
            $row = New-Object System.Windows.Forms.ListViewItem([string]$entry.SizeDisplay)
            [void]$row.SubItems.Add([string]$entry.Path)
            $row.ForeColor = Get-ThemeColor Muted
            [void]$grid.Items.Add($row)
        }
    }
    finally {
        $grid.EndUpdate()
    }
}

$storageResultCard = New-Card -Title 'Results'
$storageBottom.Controls.Add($storageResultCard, 1, 0)

$storageGrid = New-ResultGrid
$storageResultCard.Controls.Add($storageGrid)
$storageGrid.BringToFront()
$script:Sync.Controls.StorageGrid = $storageGrid

Register-Page -Name 'Storage' -Subtitle 'Where the space went, and what can be reclaimed' -Panel $storagePage

#endregion

#region Health page

<#
    Read-only throughout. Everything here reports; nothing on this page changes
    the machine, which is what makes it safe to open on somebody else's PC.
#>

$healthPage = New-Object System.Windows.Forms.TableLayoutPanel
$healthPage.ColumnCount = 1
$healthPage.RowCount = 2
[void]$healthPage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
[void]$healthPage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$healthActionCard = New-Card -Title 'Reports'
$healthPage.Controls.Add($healthActionCard, 0, 0)

$healthActions = New-Object System.Windows.Forms.FlowLayoutPanel
$healthActions.Dock = 'Fill'
$healthActions.AutoScroll = $true
$healthActionCard.Controls.Add($healthActions)
$healthActions.BringToFront()

function Show-HealthText {
    <#
        The health reports are all differently shaped, so rather than a grid per
        report they render into one text pane. Read-only output; nothing here is
        an action result.
    #>
    param([string]$Text)

    $script:Sync.Controls.HealthText.Text = $Text
}

$healthActions.Controls.Add((New-Button -Text 'System info' -Width 150 -Accent -OnClick {
    Start-ShellTask -Name 'System info' -Script { Get-PCSystemInfo | Format-List | Out-String -Width 160 } -OnSuccess {
        param($text)
        Show-HealthText -Text ([string]$text)
    }
}))

$healthActions.Controls.Add((New-Button -Text 'Disk health' -Width 150 -OnClick {
    Start-ShellTask -Name 'Disk health' -Script {
        $disks = @(Get-PCDiskHealth)
        if ($disks.Count -eq 0) { 'No physical disk reported reliability data. This is normal for USB enclosures and some consumer drives.' }
        else { $disks | Format-List FriendlyName, MediaType, SizeDisplay, Health, Wear, PowerOnHours, Temperature, Concerns | Out-String -Width 160 }
    } -OnSuccess {
        param($text)
        Show-HealthText -Text ([string]$text)
    }
}))

$healthActions.Controls.Add((New-Button -Text 'Security posture' -Width 170 -OnClick {
    Start-ShellTask -Name 'Security status' -Script {
        $status = Get-PCSecurityStatus
        $lines = @("Grade: $($status.Grade)", '')
        if (@($status.Findings).Count -eq 0) { $lines += 'No findings.' }
        else { foreach ($finding in $status.Findings) { $lines += "  - $finding" } }
        $lines += ''
        $lines += ($status | Format-List Defender, Firewall, BitLocker, UacEnabled, SmartScreen, RebootPending | Out-String -Width 160)
        $lines -join [Environment]::NewLine
    } -OnSuccess {
        param($text)
        Show-HealthText -Text ([string]$text)
    }
}))

$healthActions.Controls.Add((New-Button -Text 'Recent errors' -Width 150 -OnClick {
    Start-ShellTask -Name 'Event summary' -Script {
        $summary = Get-PCEventSummary -Days 7
        $lines = @($summary.Verdict, '')
        $lines += ($summary.Groups | Format-Table Provider, EventId, Count, LastSeen, Message -AutoSize | Out-String -Width 200)
        $lines -join [Environment]::NewLine
    } -OnSuccess {
        param($text)
        Show-HealthText -Text ([string]$text)
    }
}))

$healthActions.Controls.Add((New-Button -Text 'Boot time' -Width 140 -OnClick {
    Start-ShellTask -Name 'Boot performance' -Script {
        $boot = Get-PCBootPerformance
        $lines = @($boot.Verdict, '')
        if (@($boot.Degradations).Count -gt 0) {
            $lines += ($boot.Degradations | Format-Table Name, Type, PenaltyMs -AutoSize | Out-String -Width 160)
        }
        $lines -join [Environment]::NewLine
    } -OnSuccess {
        param($text)
        Show-HealthText -Text ([string]$text)
    }
}))

$healthActions.Controls.Add((New-Button -Text 'Startup programs' -Width 170 -OnClick {
    Start-ShellTask -Name 'Startup items' -Script {
        Get-PCStartupItem | Format-Table Name, Source, Scope, Enabled, Command -AutoSize | Out-String -Width 220
    } -OnSuccess {
        param($text)
        Show-HealthText -Text ([string]$text)
    }
}))

$healthActions.Controls.Add((New-Button -Text 'Battery' -Width 130 -OnClick {
    Start-ShellTask -Name 'Battery report' -Script {
        $cells = @(Get-PCBatteryReport)
        if ($cells.Count -eq 0) { 'No battery detected - this looks like a desktop.' }
        else { $cells | Format-List Name, Manufacturer, HealthPercent, ChargeRemaining, Verdict | Out-String -Width 160 }
    } -OnSuccess {
        param($text)
        Show-HealthText -Text ([string]$text)
    }
}))

$healthTextCard = New-Card -Title 'Report'
$healthPage.Controls.Add($healthTextCard, 0, 1)

$healthText = New-Object System.Windows.Forms.TextBox
$healthText.Dock = 'Fill'
$healthText.Multiline = $true
$healthText.ReadOnly = $true
$healthText.ScrollBars = 'Both'
$healthText.WordWrap = $false
$healthText.Font = $script:FontMono
$healthText.BorderStyle = 'None'
$healthText.Text = 'Pick a report above. Everything on this page only reads; nothing here changes the machine.'
$healthTextCard.Controls.Add($healthText)
$healthText.BringToFront()
$script:Sync.Controls.HealthText = $healthText

Register-Page -Name 'Health' -Subtitle 'Read-only reports: hardware, security, stability' -Panel $healthPage

#endregion

#region Software page

$softwarePage = New-Object System.Windows.Forms.TableLayoutPanel
$softwarePage.ColumnCount = 1
$softwarePage.RowCount = 2
[void]$softwarePage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
[void]$softwarePage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$softwareActionCard = New-Card -Title 'Updates and applications'
$softwarePage.Controls.Add($softwareActionCard, 0, 0)

$softwareActions = New-Object System.Windows.Forms.FlowLayoutPanel
$softwareActions.Dock = 'Fill'
$softwareActions.AutoScroll = $true
$softwareActionCard.Controls.Add($softwareActions)
$softwareActions.BringToFront()

function Start-SoftwareAction {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Script
    )

    Start-ShellTask -Name $Label -Script $Script -OnSuccess {
        param($results)
        $items = @($results | Where-Object { $_ })
        foreach ($result in $items) {
            Add-ResultRow -Grid $script:Sync.Controls.SoftwareGrid -Result $result
        }
        Show-Summary -Result $items
    }
}

$softwareActions.Controls.Add((New-Button -Text 'Check for updates' -Width 180 -Accent -OnClick {
    Start-ShellTask -Name 'Check Windows Update' -Script {
        $updates = @(Get-PCWindowsUpdate)
        if ($updates.Count -eq 0) {
            @{ Text = 'Windows is up to date.' }
        }
        else {
            @{ Text = ($updates | Format-Table Title, KB, SizeDisplay, RebootRequired -AutoSize | Out-String -Width 200) }
        }
    } -OnSuccess {
        param($outcome)
        Write-ShellLog -Level INFO -Message ([string]$outcome.Text)
        Show-Page -Name 'Log'
    }
}))

$softwareActions.Controls.Add((New-Button -Text 'Install updates' -Width 160 -OnClick {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Download and install all pending Windows updates?`r`n`r`n" +
         "This can take a long time and may require a restart afterwards. " +
         "Nothing is restarted for you."),
        'PC Tools', 'YesNo', 'Warning')

    if ($answer -eq 'Yes') {
        Start-SoftwareAction -Label 'Install Windows updates' -Script {
            Install-PCWindowsUpdate -Confirm:$false
        }
    }
}))

$softwareActions.Controls.Add((New-Button -Text 'Out-of-date apps' -Width 170 -OnClick {
    Start-SoftwareAction -Label 'List app updates' -Script { Update-PCApplication -ListOnly -Confirm:$false }
}))

$softwareActions.Controls.Add((New-Button -Text 'Update all apps' -Width 170 -OnClick {
    Start-SoftwareAction -Label 'Upgrade applications' -Script { Update-PCApplication -Confirm:$false }
}))

$softwareActions.Controls.Add((New-Button -Text 'Device problems' -Width 170 -OnClick {
    Start-ShellTask -Name 'Driver issues' -Script {
        $issues = @(Get-PCDriverIssue)
        if ($issues.Count -eq 0) { 'Windows reports no device problems.' }
        else { $issues | Format-Table Name, ProblemCode, Problem -AutoSize | Out-String -Width 200 }
    } -OnSuccess {
        param($text)
        Write-ShellLog -Level INFO -Message ([string]$text)
        Show-Page -Name 'Log'
    }
}))

$softwareActions.Controls.Add((New-Button -Text 'Schedule maintenance' -Width 190 -OnClick {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Run the Weekly profile automatically, every Sunday at 03:00?`r`n`r`n" +
         "It reclaims disk space and refreshes DNS. It performs no repairs and " +
         "never restarts the machine. Remove it later with " +
         "Unregister-PCScheduledMaintenance."),
        'PC Tools', 'YesNo', 'Question')

    if ($answer -eq 'Yes') {
        Start-SoftwareAction -Label 'Schedule weekly maintenance' -Script {
            Register-PCScheduledMaintenance -ProfileName 'Weekly' -Frequency Weekly -Confirm:$false
        }
    }
}))

$softwareResultCard = New-Card -Title 'Results'
$softwarePage.Controls.Add($softwareResultCard, 0, 1)

$softwareGrid = New-ResultGrid
$softwareResultCard.Controls.Add($softwareGrid)
$softwareGrid.BringToFront()
$script:Sync.Controls.SoftwareGrid = $softwareGrid

Register-Page -Name 'Software' -Subtitle 'Windows updates, applications and drivers' -Panel $softwarePage

#endregion

#region Network page

$networkPage = New-Object System.Windows.Forms.TableLayoutPanel
$networkPage.ColumnCount = 1
$networkPage.RowCount = 3
[void]$networkPage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 92)))
[void]$networkPage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 210)))
[void]$networkPage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

# Verdict banner - the diagnosis, not a table of pass/fail rows
$verdictCard = New-Card -Title '' -Padding 14
$networkPage.Controls.Add($verdictCard, 0, 0)

$verdictLabel = New-Object System.Windows.Forms.Label
$verdictLabel.Text = 'Not tested yet'
$verdictLabel.Font = $script:FontTitle
$verdictLabel.Dock = 'Top'
$verdictLabel.Height = 26
$verdictLabel.ForeColor = Get-ThemeColor Muted
$verdictCard.Controls.Add($verdictLabel)
$script:Sync.Controls.VerdictLabel = $verdictLabel

$adviceLabel = New-Object System.Windows.Forms.Label
$adviceLabel.Text = 'Run a diagnostic to see where the problem is.'
$adviceLabel.Dock = 'Fill'
$adviceLabel.ForeColor = Get-ThemeColor Muted
$verdictCard.Controls.Add($adviceLabel)
$adviceLabel.BringToFront()
$script:Sync.Controls.AdviceLabel = $adviceLabel

# Adapters and actions
$networkMiddle = New-Object System.Windows.Forms.TableLayoutPanel
$networkMiddle.Dock = 'Fill'
$networkMiddle.ColumnCount = 2
[void]$networkMiddle.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 62)))
[void]$networkMiddle.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 38)))
$networkPage.Controls.Add($networkMiddle, 0, 1)

$adapterCard = New-Card -Title 'Adapters'
$networkMiddle.Controls.Add($adapterCard, 0, 0)

$adapterGrid = New-Object System.Windows.Forms.ListView
$adapterGrid.Dock = 'Fill'
$adapterGrid.View = 'Details'
$adapterGrid.FullRowSelect = $true
$adapterGrid.HideSelection = $false
$adapterGrid.BorderStyle = 'None'
$adapterGrid.Font = $script:FontBody
[void]$adapterGrid.Columns.Add('Adapter', 150)
[void]$adapterGrid.Columns.Add('Status', 70)
[void]$adapterGrid.Columns.Add('IPv4', 130)
[void]$adapterGrid.Columns.Add('Gateway', 130)
[void]$adapterGrid.Columns.Add('DNS', 180)
[void]$adapterGrid.Columns.Add('DHCP', 60)
$adapterCard.Controls.Add($adapterGrid)
$adapterGrid.BringToFront()
$script:Sync.Controls.AdapterGrid = $adapterGrid

$networkActions = New-Object System.Windows.Forms.FlowLayoutPanel
$networkActions.Dock = 'Fill'
$networkActions.FlowDirection = 'TopDown'
$networkActions.WrapContents = $false
$networkActions.AutoScroll = $true
$networkMiddle.Controls.Add($networkActions, 1, 0)

function Update-AdapterGrid {
    param([AllowEmptyCollection()][object[]]$Adapter)

    $grid = $script:Sync.Controls.AdapterGrid
    $grid.BeginUpdate()
    try {
        $grid.Items.Clear()
        foreach ($item in $Adapter) {
            $row = New-Object System.Windows.Forms.ListViewItem([string]$item.Name)
            [void]$row.SubItems.Add([string]$item.Status)
            [void]$row.SubItems.Add([string]$item.IPv4Address)
            [void]$row.SubItems.Add([string]$item.Gateway)
            [void]$row.SubItems.Add([string]$item.DnsServers)
            [void]$row.SubItems.Add($(if ($item.Dhcp) { 'Yes' } elseif ($null -eq $item.Dhcp) { '?' } else { 'No' }))
            $row.ForeColor = if ($item.Status -eq 'Up') { Get-ThemeColor Text } else { Get-ThemeColor Muted }
            $row.Tag = $item.Name
            [void]$grid.Items.Add($row)
        }
    }
    finally {
        $grid.EndUpdate()
    }
}

function Show-Verdict {
    param($Report)

    $verdict = $Report.Verdict
    $script:Sync.Controls.VerdictLabel.Text = $verdict.Verdict
    $script:Sync.Controls.AdviceLabel.Text = $verdict.Advice
    $script:Sync.Controls.VerdictLabel.ForeColor = if ($verdict.Healthy) {
        Get-ThemeColor Success
    }
    else {
        Get-ThemeColor Danger
    }

    $grid = $script:Sync.Controls.NetworkGrid
    $grid.Items.Clear()
    foreach ($test in $Report.Tests) {
        $row = New-Object System.Windows.Forms.ListViewItem($(if ($test.Success) { 'Pass' } else { 'Fail' }))
        [void]$row.SubItems.Add([string]$test.Layer)
        [void]$row.SubItems.Add($(if ($null -ne $test.LatencyMs) { "$($test.LatencyMs) ms" } else { '' }))
        [void]$row.SubItems.Add("$($test.Target) - $($test.Detail)")
        $row.ForeColor = if ($test.Success) { Get-ThemeColor Success } else { Get-ThemeColor Danger }
        [void]$grid.Items.Add($row)
    }

    $script:LastReport = $Report
}

function Start-NetworkDiagnostic {
    param([switch]$Full)

    Start-ShellTask -Name $(if ($Full) { 'Full network diagnostic' } else { 'Quick network diagnostic' }) `
        -Arguments @{ Full = [bool]$Full } -Script {
            param($Full)
            Get-PCNetworkReport -Full:$Full
        } -OnSuccess {
            param($report)
            if (-not $report) { return }
            Update-AdapterGrid -Adapter @($report.Adapters)
            Show-Verdict -Report $report
        }
}

function Start-NetworkAction {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Script,
        [hashtable]$Arguments = @{}
    )

    Start-ShellTask -Name $Label -Script $Script -Arguments $Arguments -OnSuccess {
        param($results)
        $items = @($results | Where-Object { $_ })
        foreach ($result in $items) {
            Add-ResultRow -Grid $script:Sync.Controls.NetworkGrid -Result $result
        }
        Show-Summary -Result $items
        $script:LastResults = $items
    }
}

$quickDiagButton = New-Button -Text 'Quick diagnostic' -Width 200 -Accent -OnClick { Start-NetworkDiagnostic }
$networkActions.Controls.Add($quickDiagButton)
[void]$script:Sync.Controls.RunButtons.Add($quickDiagButton)

$fullDiagButton = New-Button -Text 'Full diagnostic' -Width 200 -OnClick { Start-NetworkDiagnostic -Full }
$networkActions.Controls.Add($fullDiagButton)
[void]$script:Sync.Controls.RunButtons.Add($fullDiagButton)

$flushDnsButton = New-Button -Text 'Flush DNS cache' -Width 200 -OnClick {
    Start-NetworkAction -Label 'Flush DNS cache' -Script { Clear-PCDnsCache -Confirm:$false }
}
$networkActions.Controls.Add($flushDnsButton)
[void]$script:Sync.Controls.RunButtons.Add($flushDnsButton)

$refreshAdaptersButton = New-Button -Text 'Refresh adapters' -Width 200 -OnClick {
    Start-ShellTask -Name 'Refresh adapters' -Script { Get-PCNetworkAdapter } -OnSuccess {
        param($adapters)
        Update-AdapterGrid -Adapter @($adapters)
    }
}
$networkActions.Controls.Add($refreshAdaptersButton)
[void]$script:Sync.Controls.RunButtons.Add($refreshAdaptersButton)

$dnsPresetLabel = New-Object System.Windows.Forms.Label
$dnsPresetLabel.Text = 'Set DNS on the selected adapter:'
$dnsPresetLabel.AutoSize = $true
$dnsPresetLabel.ForeColor = Get-ThemeColor Muted
$dnsPresetLabel.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 4)
$networkActions.Controls.Add($dnsPresetLabel)

function Get-SelectedAdapterName {
    $grid = $script:Sync.Controls.AdapterGrid
    if ($grid.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            'Select an adapter in the list first.', 'PC Tools', 'OK', 'Information') | Out-Null
        return $null
    }
    [string]$grid.SelectedItems[0].Tag
}

foreach ($preset in @('Cloudflare', 'Google', 'Quad9')) {
    $presetButton = New-Button -Text "DNS: $preset" -Width 200
    $presetButton.Tag = $preset
    $presetButton.Add_Click({
        $adapterName = Get-SelectedAdapterName
        if (-not $adapterName) { return }
        $chosen = [string]$this.Tag

        Start-NetworkAction -Label "Set DNS ($chosen)" -Arguments @{
            AdapterName = $adapterName
            Preset      = $chosen
        } -Script {
            param($AdapterName, $Preset)
            Set-PCDnsServer -Name $AdapterName -Preset $Preset -Confirm:$false
        }
    })
    $networkActions.Controls.Add($presetButton)
    [void]$script:Sync.Controls.RunButtons.Add($presetButton)
}

$dhcpButton = New-Button -Text 'Revert to DHCP' -Width 200 -OnClick {
    $adapterName = Get-SelectedAdapterName
    if (-not $adapterName) { return }

    Start-NetworkAction -Label 'Revert to DHCP' -Arguments @{ AdapterName = $adapterName } -Script {
        param($AdapterName)
        Set-PCDhcp -Name $AdapterName -Confirm:$false
    }
}
$networkActions.Controls.Add($dhcpButton)
[void]$script:Sync.Controls.RunButtons.Add($dhcpButton)

$resetStackButton = New-Button -Text 'Reset network stack' -Width 200 -OnClick {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Reset the TCP/IP and Winsock stack?`r`n`r`n" +
         "This requires a restart, and resetting Winsock removes third-party " +
         "layered service providers - some VPN clients stop working until they " +
         "are reinstalled.`r`n`r`nTry the other fixes first."),
        'PC Tools', 'YesNo', 'Warning')

    if ($answer -ne 'Yes') { return }

    Start-NetworkAction -Label 'Reset network stack' -Script {
        Reset-PCNetworkStack -Confirm:$false
    }
}
$networkActions.Controls.Add($resetStackButton)
[void]$script:Sync.Controls.RunButtons.Add($resetStackButton)

$traceButton = New-Button -Text 'Trace route' -Width 200 -OnClick {
    $script:Sync.Controls.NetworkGrid.Items.Clear()

    Start-ShellTask -Name 'Trace route' -Script {
        Test-PCRoute -Target '1.1.1.1' -MaxHops 20 -TimeoutSeconds 2
    } -OnSuccess {
        param($hops)
        $grid = $script:Sync.Controls.NetworkGrid
        foreach ($hop in @($hops)) {
            $row = New-Object System.Windows.Forms.ListViewItem("Hop $($hop.Hop)")
            [void]$row.SubItems.Add('Route')
            [void]$row.SubItems.Add($(if ($null -ne $hop.LatencyMs) { "$($hop.LatencyMs) ms" } else { '' }))
            [void]$row.SubItems.Add("$($hop.Address) - $($hop.Status)")
            $row.ForeColor = if ($hop.Status -eq 'TimedOut') { Get-ThemeColor Muted } else { Get-ThemeColor Text }
            [void]$grid.Items.Add($row)
        }
    }
}
$networkActions.Controls.Add($traceButton)
[void]$script:Sync.Controls.RunButtons.Add($traceButton)

$mtuButton = New-Button -Text 'Check path MTU' -Width 200 -OnClick {
    Start-ShellTask -Name 'Check path MTU' -Script {
        Test-PCMtu -Target '1.1.1.1' -TimeoutSeconds 3
    } -OnSuccess {
        param($probe)
        if (-not $probe) { return }
        $grid = $script:Sync.Controls.NetworkGrid
        $row = New-Object System.Windows.Forms.ListViewItem($(if ($probe.Standard) { 'Pass' } else { 'Check' }))
        [void]$row.SubItems.Add('MTU')
        [void]$row.SubItems.Add($(if ($probe.Mtu) { "$($probe.Mtu)" } else { '' }))
        [void]$row.SubItems.Add($probe.Detail)
        $row.ForeColor = if ($probe.Standard) { Get-ThemeColor Success } else { Get-ThemeColor Warning }
        [void]$grid.Items.Add($row)
    }
}
$networkActions.Controls.Add($mtuButton)
[void]$script:Sync.Controls.RunButtons.Add($mtuButton)

$wirelessButton = New-Button -Text 'Wi-Fi signal' -Width 200 -OnClick {
    Start-ShellTask -Name 'Wi-Fi signal' -Script { Get-PCWirelessStatus } -OnSuccess {
        param($status)
        if (-not $status) { return }
        $grid = $script:Sync.Controls.NetworkGrid
        $row = New-Object System.Windows.Forms.ListViewItem($(if ($status.Connected) { 'Info' } else { 'Fail' }))
        [void]$row.SubItems.Add('Wi-Fi')
        [void]$row.SubItems.Add($(if ($status.Connected) { "$($status.SignalPercent)%" } else { '' }))
        [void]$row.SubItems.Add($(if ($status.Connected) { "$($status.Ssid) - $($status.Detail)" } else { $status.Detail }))
        $row.ForeColor = if (-not $status.Connected) { Get-ThemeColor Muted }
                         elseif ($status.SignalGrade -eq 'Poor') { Get-ThemeColor Danger }
                         elseif ($status.SignalGrade -eq 'Fair') { Get-ThemeColor Warning }
                         else { Get-ThemeColor Success }
        [void]$grid.Items.Add($row)
    }
}
$networkActions.Controls.Add($wirelessButton)
[void]$script:Sync.Controls.RunButtons.Add($wirelessButton)

$saveProfileButton = New-Button -Text 'Save adapter profile' -Width 200 -OnClick {
    $adapterName = Get-SelectedAdapterName
    if (-not $adapterName) { return }

    $profileName = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Name for this configuration (for example: Office, Home)', 'Save network profile', $adapterName)
    if (-not $profileName) { return }

    Start-NetworkAction -Label "Save profile '$profileName'" -Arguments @{
        AdapterName = $adapterName
        ProfileName = $profileName
    } -Script {
        param($AdapterName, $ProfileName)
        Export-PCNetworkProfile -Name $AdapterName -ProfileName $ProfileName -Confirm:$false
    }
}
$networkActions.Controls.Add($saveProfileButton)
[void]$script:Sync.Controls.RunButtons.Add($saveProfileButton)

$applyProfileButton = New-Button -Text 'Apply adapter profile' -Width 200 -OnClick {
    $saved = @(Get-PCNetworkProfile)
    if ($saved.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            'No network profiles have been saved yet. Select an adapter and use "Save adapter profile" first.',
            'PC Tools', 'OK', 'Information') | Out-Null
        return
    }

    $choice = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Which profile?`r`n`r`nSaved: $(($saved.ProfileName) -join ', ')",
        'Apply network profile', $saved[0].ProfileName)
    if (-not $choice) { return }

    $adapterName = Get-SelectedAdapterName
    if (-not $adapterName) { return }

    Start-NetworkAction -Label "Apply profile '$choice'" -Arguments @{
        ProfileName = $choice
        AdapterName = $adapterName
    } -Script {
        param($ProfileName, $AdapterName)
        Import-PCNetworkProfile -ProfileName $ProfileName -Name $AdapterName -Confirm:$false
    }
}
$networkActions.Controls.Add($applyProfileButton)
[void]$script:Sync.Controls.RunButtons.Add($applyProfileButton)

$exportNetworkButton = New-Button -Text 'Export report' -Width 200 -OnClick {
    if (-not $script:LastReport) {
        [System.Windows.Forms.MessageBox]::Show('Run a diagnostic first.', 'PC Tools', 'OK', 'Information') | Out-Null
        return
    }
    $paths = $script:LastReport | Export-PCReport -BaseName 'pctools-network'
    if ($paths) {
        Write-ShellLog -Level INFO -Message "Report written to $($paths.TextPath)"
        Start-Process -FilePath $paths.TextPath
    }
}
$networkActions.Controls.Add($exportNetworkButton)

# Test results
$networkResultsCard = New-Card -Title 'Test results'
$networkPage.Controls.Add($networkResultsCard, 0, 2)

$networkGrid = New-ResultGrid
$networkGrid.Columns[0].Text = 'Result'
$networkGrid.Columns[1].Text = 'Layer'
$networkGrid.Columns[2].Text = 'Latency'
$networkResultsCard.Controls.Add($networkGrid)
$networkGrid.BringToFront()
$script:Sync.Controls.NetworkGrid = $networkGrid

Register-Page -Name 'Network' -Subtitle 'Diagnose and repair network problems' -Panel $networkPage

#endregion

#region Preferences page

$preferencesPage = New-Object System.Windows.Forms.TableLayoutPanel
$preferencesPage.ColumnCount = 1
$preferencesPage.RowCount = 2
[void]$preferencesPage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$preferencesPage.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 190)))

$preferencesCard = New-Card -Title 'Windows preferences'
$preferencesPage.Controls.Add($preferencesCard, 0, 0)

$preferencesBody = New-Object System.Windows.Forms.TableLayoutPanel
$preferencesBody.Dock = 'Fill'
$preferencesBody.ColumnCount = 2
[void]$preferencesBody.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 70)))
[void]$preferencesBody.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 30)))
$preferencesCard.Controls.Add($preferencesBody)
$preferencesBody.BringToFront()

$preferencesList = New-Object System.Windows.Forms.FlowLayoutPanel
$preferencesList.Dock = 'Fill'
$preferencesList.FlowDirection = 'TopDown'
$preferencesList.WrapContents = $false
$preferencesList.AutoScroll = $true
$preferencesList.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$preferencesBody.Controls.Add($preferencesList, 0, 0)

$script:PreferenceBoxes = @{}

function Update-PreferenceState {
    <#
        Reflects what Windows actually has set right now.

        The original tool could not do this: it had no way to read a preference,
        so every checkbox rendered unticked regardless of the machine's state,
        and the user had no way to know what was already applied.
    #>
    param([AllowEmptyCollection()][object[]]$Preference)

    foreach ($item in $Preference) {
        $box = $script:PreferenceBoxes[$item.Name]
        if (-not $box) { continue }

        $box.Checked = $item.Enabled
        $box.Text = if ($item.State -eq 'Partial') {
            "$($item.Description)   (partially applied)"
        }
        else {
            $item.Description
        }
        $box.ForeColor = if ($item.State -eq 'Partial') { Get-ThemeColor Warning } else { Get-ThemeColor Text }
        $box.Tag = $item.Name
    }
}

function Start-PreferenceRefresh {
    Start-ShellTask -Name 'Read Windows preferences' -Script { Get-PCPreference } -OnSuccess {
        param($preferences)
        Update-PreferenceState -Preference @($preferences)
    }
}

foreach ($definition in Get-PCPreference) {
    $box = New-CheckBox -Text $definition.Description -Name $definition.Name -Checked $definition.Enabled
    $box.Width = 560
    $box.AutoSize = $false
    $box.Height = 26
    $preferencesList.Controls.Add($box)
    $script:PreferenceBoxes[$definition.Name] = $box
}

$preferenceActions = New-Object System.Windows.Forms.FlowLayoutPanel
$preferenceActions.Dock = 'Fill'
$preferenceActions.FlowDirection = 'TopDown'
$preferenceActions.WrapContents = $false
$preferencesBody.Controls.Add($preferenceActions, 1, 0)

$applyPreferencesButton = New-Button -Text 'Apply changes' -Width 190 -Accent -OnClick {
    $enable = @()
    $disable = @()

    foreach ($name in $script:PreferenceBoxes.Keys) {
        if ($script:PreferenceBoxes[$name].Checked) { $enable += $name } else { $disable += $name }
    }

    Start-ShellTask -Name 'Apply Windows preferences' -Arguments @{
        Enable  = $enable
        Disable = $disable
    } -Script {
        param($Enable, $Disable)

        # Both directions run: a cleared box restores the Windows default,
        # which the original tool had no way to express.
        if ($Enable.Count) { Set-PCPreference -Name $Enable -Enabled $true -NoRestartExplorer -Confirm:$false }
        if ($Disable.Count) { Set-PCPreference -Name $Disable -Enabled $false -NoRestartExplorer -Confirm:$false }
    } -OnSuccess {
        param($results)
        $items = @($results | Where-Object { $_ })
        foreach ($result in $items) {
            Add-ResultRow -Grid $script:Sync.Controls.PreferenceGrid -Result $result
        }
        Show-Summary -Result $items
        $script:LastResults = $items
        Start-PreferenceRefresh
    }
}
$preferenceActions.Controls.Add($applyPreferencesButton)
[void]$script:Sync.Controls.RunButtons.Add($applyPreferencesButton)

$refreshPreferencesButton = New-Button -Text 'Reload from Windows' -Width 190 -OnClick { Start-PreferenceRefresh }
$preferenceActions.Controls.Add($refreshPreferencesButton)
[void]$script:Sync.Controls.RunButtons.Add($refreshPreferencesButton)

$restartExplorerButton = New-Button -Text 'Restart Explorer' -Width 190 -OnClick {
    Start-ShellTask -Name 'Restart Explorer' -Script { Restart-PCExplorer -Confirm:$false } -OnSuccess {
        param($result)
        if ($result) { Add-ResultRow -Grid $script:Sync.Controls.PreferenceGrid -Result $result }
    }
}
$preferenceActions.Controls.Add($restartExplorerButton)
[void]$script:Sync.Controls.RunButtons.Add($restartExplorerButton)

$preferenceHint = New-Object System.Windows.Forms.Label
$preferenceHint.Text = "Clearing a box restores the Windows default. Explorer restarts only when you ask it to, so nothing disappears mid-click."
$preferenceHint.AutoSize = $false
$preferenceHint.Width = 190
$preferenceHint.Height = 90
$preferenceHint.ForeColor = Get-ThemeColor Muted
$preferenceHint.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
$preferenceActions.Controls.Add($preferenceHint)

$preferenceResultsCard = New-Card -Title 'Results'
$preferencesPage.Controls.Add($preferenceResultsCard, 0, 1)

$preferenceGrid = New-ResultGrid
$preferenceResultsCard.Controls.Add($preferenceGrid)
$preferenceGrid.BringToFront()
$script:Sync.Controls.PreferenceGrid = $preferenceGrid

Register-Page -Name 'Preferences' -Subtitle 'Read and change Windows settings, both directions' -Panel $preferencesPage

#endregion

#region Log page

$logPage = New-Object System.Windows.Forms.Panel
$logCard = New-Card -Title 'Activity log'
$logPage.Controls.Add($logCard)

$logGrid = New-Object System.Windows.Forms.ListView
$logGrid.Dock = 'Fill'
$logGrid.View = 'Details'
$logGrid.FullRowSelect = $true
$logGrid.BorderStyle = 'None'
$logGrid.Font = $script:FontMono
[void]$logGrid.Columns.Add('Time', 90)
[void]$logGrid.Columns.Add('Level', 70)
[void]$logGrid.Columns.Add('Message', 900)
$logCard.Controls.Add($logGrid)
$logGrid.BringToFront()
$script:Sync.Controls.LogGrid = $logGrid

Register-Page -Name 'Log' -Subtitle 'Everything the tools have done this session' -Panel $logPage

#endregion

#region Theming

function Update-ThemeColors {
    <#
        Walks the control tree and repaints from the active palette.

        Controls carry their role in .Tag ('Card', 'Heading', 'AccentButton'),
        so a new control gets themed by tagging it rather than by being added to
        a hand-maintained list - which is what the original framework used, and
        why its theme toggle silently missed any control added later.
    #>
    $theme = $script:Themes[$script:Sync.Theme]

    $apply = {
        param($Control)

        switch -Regex ([string]$Control.Tag) {
            '^Card$' {
                $Control.BackColor = $theme.Card
                break
            }
            '^AccentButton$' {
                $Control.BackColor = $theme.Accent
                $Control.ForeColor = $theme.AccentText
                $Control.FlatAppearance.BorderColor = $theme.Accent
                break
            }
            '^Button$' {
                $Control.BackColor = $theme.Button
                $Control.ForeColor = $theme.Text
                $Control.FlatAppearance.BorderColor = $theme.Border
                break
            }
            '^Heading$' {
                $Control.ForeColor = $theme.Text
                break
            }
        }

        if ($Control -is [System.Windows.Forms.ListView]) {
            $Control.BackColor = $theme.Card
            $Control.ForeColor = $theme.Text
        }
        elseif ($Control -is [System.Windows.Forms.CheckBox] -or
                $Control -is [System.Windows.Forms.RadioButton]) {
            $Control.ForeColor = $theme.Text
        }
        elseif ($Control -is [System.Windows.Forms.TableLayoutPanel] -or
                $Control -is [System.Windows.Forms.FlowLayoutPanel]) {
            # Layout panels inside a card must not paint over it.
            if ($Control.Parent -and [string]$Control.Parent.Tag -eq 'Card') {
                $Control.BackColor = $theme.Card
            }
        }

        foreach ($child in $Control.Controls) { & $apply $child }
    }

    $script:Sync.Form.BackColor = $theme.Back
    foreach ($child in $script:Sync.Form.Controls) { & $apply $child }

    $script:Sync.Controls.StatusLabel.ForeColor = $theme.Muted
    $script:Sync.Controls.SubtitleLabel.ForeColor = $theme.Muted
}

$themeButton.Add_Click({
    $script:Sync.Theme = if ($script:Sync.Theme -eq 'Dark') { 'Light' } else { 'Dark' }
    Update-ThemeColors
    Write-ShellLog -Level INFO -Message "Theme switched to $($script:Sync.Theme)."
})

#endregion

#region Elevation

function Update-ElevationState {
    $isAdmin = Test-PCAdmin
    $button = $script:Sync.Controls.ElevateButton
    $button.Visible = -not $isAdmin

    $suffix = if ($isAdmin) { 'Administrator' } else { 'Standard user - some actions are unavailable' }
    $script:Sync.Form.Text = "$($script:App.Name) $($script:App.Version)  -  $suffix"
}

$elevateButton.Add_Click({
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
        '-File', "`"$PSCommandPath`"", '-Theme', $script:Sync.Theme
    )

    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs
        $script:Sync.Form.Close()
    }
    catch {
        # The user declining the UAC prompt is a normal outcome, not an error.
        Write-ShellLog -Level WARN -Message 'Elevation was cancelled.'
    }
})

#endregion

#region Timers

# Drains the log queue onto the UI thread. Batched, because appending one
# ListView item per tick made the original framework's log pane crawl under a
# chatty task.
$logTimer = New-Object System.Windows.Forms.Timer
$logTimer.Interval = 160
$logTimer.Add_Tick({
    $grid = $script:Sync.Controls.LogGrid
    if (-not $grid -or $grid.IsDisposed) { return }

    $batch = [System.Collections.Generic.List[object]]::new()
    $entry = $null
    while ($batch.Count -lt 100 -and $script:Sync.LogQueue.TryDequeue([ref]$entry)) {
        if ($entry) { $batch.Add($entry) }
    }
    if ($batch.Count -eq 0) { return }

    $grid.BeginUpdate()
    try {
        foreach ($item in $batch) {
            $row = New-Object System.Windows.Forms.ListViewItem([string]$item.Timestamp)
            [void]$row.SubItems.Add([string]$item.Level)
            [void]$row.SubItems.Add([string]$item.Message)
            $row.ForeColor = switch ([string]$item.Level) {
                'ERROR' { Get-ThemeColor Danger }
                'WARN'  { Get-ThemeColor Warning }
                'DEBUG' { Get-ThemeColor Muted }
                default { Get-ThemeColor Text }
            }
            [void]$grid.Items.Add($row)
        }

        # Keep the pane bounded; the file log is the complete record.
        while ($grid.Items.Count -gt 2000) { $grid.Items.RemoveAt(0) }

        $grid.EnsureVisible($grid.Items.Count - 1)
    }
    finally {
        $grid.EndUpdate()
    }
})

# Reaps finished runspace tasks.
$taskTimer = New-Object System.Windows.Forms.Timer
$taskTimer.Interval = 150
$taskTimer.Add_Tick({
    $finished = @($script:Sync.Tasks | Where-Object { $_.Handle -and $_.Handle.IsCompleted })
    foreach ($task in $finished) {
        $script:Sync.Tasks.Remove($task)
        Complete-ShellTask -Task $task
    }
})

#endregion

#region Startup and shutdown

$form.Add_Shown({
    Update-ThemeColors
    Update-ElevationState
    Show-Page -Name $Page

    $logTimer.Start()
    $taskTimer.Start()

    Write-ShellLog -Level INFO -Message "$($script:App.Name) $($script:App.Version) started."
    Write-ShellLog -Level INFO -Message "Log file: $(Get-PCLogPath)"

    if (-not (Test-PCAdmin)) {
        Write-ShellLog -Level WARN -Message 'Running without elevation. Repair and network actions will fail until you restart as administrator.'
    }

    # Fill the dashboard without blocking the window's first paint. One task,
    # not three: Start-ShellTask serialises on the busy flag, so queuing several
    # here would mean all but the first were turned away.
    Start-ShellTask -Name 'Read this PC' -Script {
        [pscustomobject]@{
            Adapters = @(Get-PCNetworkAdapter)
            Disks    = @(Get-PCDiskSpace)
            History  = Get-PCHistory -Summary
            Schedule = @(Get-PCScheduledMaintenance)
        }
    } -OnSuccess {
        param($state)

        Update-AdapterGrid -Adapter @($state.Adapters)
        Update-DiskGrid -Disk @($state.Disks)

        $parts = @()
        if ($state.History) { $parts += $state.History.Text }

        $scheduled = @($state.Schedule)
        if ($scheduled.Count -gt 0) {
            $next = $scheduled[0]
            $parts += "Scheduled: $($next.ProfileName) - next run $($next.NextRunTime), last result $($next.LastResult)."
        }
        else {
            $parts += 'No maintenance is scheduled. The Software page can set one up.'
        }

        Update-DashboardStatus -Text ($parts -join '  ')
    }
})

$form.Add_FormClosing({
    # These parameters are deliberately not named after the WinForms
    # convention: PowerShell reserves those names as automatic variables, and
    # shadowing an automatic variable in a param block invites a confusing bug.
    param($closingSender, $closingArgs)

    if ($script:Sync.Busy) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "A task is still running.`r`n`r`nClosing now may leave it half-finished. Close anyway?",
            'PC Tools', 'YesNo', 'Warning')

        if ($answer -ne 'Yes') {
            $closingArgs.Cancel = $true
            return
        }
    }

    try { $logTimer.Stop(); $logTimer.Dispose() } catch { }
    try { $taskTimer.Stop(); $taskTimer.Dispose() } catch { }

    foreach ($task in @($script:Sync.Tasks)) {
        try { $task.Shell.Stop(); $task.Shell.Dispose() } catch { }
    }

    try { $script:Pool.Close(); $script:Pool.Dispose() } catch { }
})

[void]$form.ResumeLayout($true)
[void]$form.ShowDialog()
$form.Dispose()

#endregion
