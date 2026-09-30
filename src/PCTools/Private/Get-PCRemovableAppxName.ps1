function Get-PCRemovableAppxName {
    <#
    .SYNOPSIS
        The curated list of preinstalled apps this module will remove.

    .DESCRIPTION
        An allowlist, not a blocklist, and the distinction is the entire safety
        model. "Remove everything except a deny list" is how debloating scripts
        break the Store, Calculator, the photo viewer, or - reliably, on at
        least one popular script - the ability to open a JPEG.

        Every entry here is a preinstalled consumer application that nothing
        else depends on and that can be reinstalled from the Store afterwards.
        Deliberately absent, whatever the debloat lists say:

          - Microsoft.WindowsStore        removing it means nothing can be
                                          reinstalled, including itself
          - Microsoft.WindowsCalculator   people use it, and it costs nothing
          - Microsoft.Windows.Photos      leaves no default image viewer
          - Microsoft.WindowsTerminal     the shell this module runs in
          - Microsoft.DesktopAppInstaller winget lives in it, and two commands
                                          here depend on winget
          - Microsoft.SecHealthUI         the Windows Security interface
          - anything *Framework* or VCLibs, which are shared runtimes

        Kept as a function so it can explain itself and so the tests can assert
        that these exclusions stay excluded.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    @(
        # Entertainment and lifestyle preinstalls
        'Microsoft.BingNews'
        'Microsoft.BingWeather'
        'Microsoft.BingFinance'
        'Microsoft.BingSports'
        'Microsoft.BingTranslator'
        'Microsoft.ZuneMusic'
        'Microsoft.ZuneVideo'
        'Microsoft.MicrosoftSolitaireCollection'
        'Microsoft.MinecraftUWP'
        'Microsoft.MixedReality.Portal'
        'Microsoft.Microsoft3DViewer'
        'Microsoft.Print3D'
        'Microsoft.3DBuilder'
        'Microsoft.MSPaint'          # Paint 3D, not classic Paint
        'Microsoft.SkypeApp'
        'Microsoft.YourPhone'
        'Microsoft.People'
        'Microsoft.WindowsFeedbackHub'
        'Microsoft.GetHelp'
        'Microsoft.Getstarted'
        'Microsoft.WindowsMaps'
        'Microsoft.WindowsSoundRecorder'
        'Microsoft.Wallet'
        'Microsoft.OneConnect'
        'Microsoft.Office.OneNote'
        'Microsoft.MicrosoftOfficeHub'
        'Microsoft.MicrosoftStickyNotes'
        'Microsoft.Todos'
        'Microsoft.PowerAutomateDesktop'
        'MicrosoftTeams'
        'MSTeams'
        'Clipchamp.Clipchamp'
        'Microsoft.GamingApp'
        'Microsoft.Xbox.TCUI'
        'Microsoft.XboxGameOverlay'
        'Microsoft.XboxGamingOverlay'
        'Microsoft.XboxSpeechToTextOverlay'
        'Microsoft.XboxApp'
        'Microsoft.549981C3F5F10'    # Cortana

        # Common OEM preinstalls
        'king.com.CandyCrushSaga'
        'king.com.CandyCrushSodaSaga'
        'Facebook.Facebook'
        'SpotifyAB.SpotifyMusic'
        'Disney.37853FC22B2CE'
        'AmazonVideo.PrimeVideo'
        'BytedancePte.Ltd.TikTok'
    )
}
