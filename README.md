# pc-powershelltools

A collection of PowerShell GUI tools for Windows maintenance, optimization, and network diagnostics. Includes system cleanup, repair utilities, network troubleshooting, Windows tweaks, and more.

> **Disclaimer**  
> These tools are provided **as-is**. I am not liable for any system issues or damages resulting from their use.

---

## Tools Included

### PC Cleanup Tool (v0.1)
A one-click GUI for cleaning, optimizing, and configuring Windows.

#### Getting Started
1. Run this command in **PowerShell as Administrator**: 
`irm https://raw.githubusercontent.com/likeBloodMoon/pc-powershelltools/main/pc-cleanuptool.ps1 | iex`



#### Alternative
1. Download or clone the repository  
2. Open **PowerShell as Administrator**  
3. Run the script: .\pc-cleanuptool.ps1

#### Features
- **System Cleanup**: Clean temporary files, empty Recycle Bin, clear Windows Update cache, clear Prefetch cache, create automatic system restore points.  
- **System Repair Tools**: Run DISM (`/restorehealth`), SFC (`/scannow`), CHKDSK (online scan).  
- **Network Utilities**: Flush DNS cache, full network stack reset, set static IP/DNS/subnet mask/gateway, revert to DHCP, auto-detect active adapters.  
- **Windows Preferences**: Enable dark mode, disable Bing search integration, show hidden files and extensions, disable mouse acceleration, enable NumLock on startup.  
- **Optional Software Installer**: Installs common apps via **winget** (e.g., Google Chrome, 7-Zip, VLC, VS Code).

### Net Diag GUI (v0.2 - New Release!)
A GUI tool for network diagnostics and fixes, with a refreshed dark UI, improved layout, and controls.

#### Getting Started
1. Download or clone the repository  
2. Open **PowerShell as Administrator**  
3. Run the script: .\pc-netdiag.ps1  (or net-diag_v3.ps1 based on internal naming)

#### Features
- Run quick or full network diagnostics.  
- Apply common network fixes: Flush DNS, renew IP.  
- Manage adapter settings: Set static IP/DNS, revert to DHCP.  
- Asynchronous runs to keep UI responsive, with timeouts.  
- Log rotation, results summary, and elevation button.  
- Improved UI: Refreshed dark theme, better layout and controls.

---

## Releases
- **v0.2** (December 12, 2025): First release of Net Diag GUI. Introduces network diagnostics GUI with fixes and management tools. The PC Cleanup Tool remains unchanged.  
- **v0.1** (December 12, 2025): Initial release of PC Cleanup Tool.

## Roadmap

### Future Updates
- More Windows preference toggles (e.g., Taskbar/Start Menu tweaks, disable background features).  
- Network profiles (Home/Work presets).  
- Export logs to file and copy from GUI.  
- Safer confirmations for destructive actions.  
- Performance and stability improvements.  
- Preset profiles (Quick cleanup, Full maintenance).  
- Config file support (JSON).  
- Portable executable build.  
- Additional system diagnostics.

Suggestions and contributions are welcome.
