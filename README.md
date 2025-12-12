# pc-cleanuptool

A PowerShell GUI tool for cleaning, optimizing, and configuring Windows with one click.  
Includes system cleanup, network tools, Windows tweaks, and more.

> **Disclaimer**  
> This tool is provided **as-is**. I am not liable for any system issues or damages resulting from its use.

---

## Getting Started

1. Download or clone the repository  
2. Open **PowerShell as Administrator**  
3. Run the script: .\pc-cleanup.ps1


## Features

### System Cleanup
- Clean temporary files  
- Empty Recycle Bin  
- Clear Windows Update cache  
- Clear Prefetch cache  
- Create automatic system restore points  

### System Repair Tools
- Run DISM (`/restorehealth`)  
- Run SFC (`/scannow`)  
- Run CHKDSK (online scan)  

### Network Utilities
- Flush DNS cache  
- Full network stack reset  
- Set static IP, DNS, subnet mask, and gateway  
- Revert network adapter to DHCP  
- Auto-detect active network adapters  

### Windows Preferences
- Enable dark mode  
- Disable Bing search integration  
- Show hidden files and file extensions  
- Disable mouse acceleration  
- Enable NumLock on startup  

### Optional Software Installer
Installs common applications via **winget**:
- Google Chrome  
- 7-Zip  
- VLC Media Player  
- Visual Studio Code  



---

## Roadmap

### v0.2 (Planned)
- UI polish and layout improvements  
- More Windows preference toggles  
  - Taskbar and Start Menu tweaks  
  - Disable unnecessary background features  
- Network profiles (Home / Work presets)  
- Export logs to file and copy from GUI  
- Safer confirmations for destructive actions  
- Performance and stability improvements  

### Future Ideas
- Preset profiles (Quick cleanup, Full maintenance)  
- Config file support (JSON)  
- Portable executable build  
- Additional system diagnostics  

Suggestions and contributions are welcome.

