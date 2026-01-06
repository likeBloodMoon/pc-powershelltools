<# 
quickspeedboost.ps1 (fixed)
- Cleans temp files
- Flushes DNS
- Restarts Explorer + DWM
- Trims working sets
- Clears Standby List (advanced)
#>

# -----------------------------
# Admin check
# -----------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "ERROR: Run this as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "===============================" -ForegroundColor Green
Write-Host " Windows Quick Refresh (PS)     " -ForegroundColor Green
Write-Host "===============================" -ForegroundColor Green

# -----------------------------
# Helper: safe folder cleanup
# -----------------------------
function Clear-FolderContents {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    try {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    }
    catch {
        # ignore locked files
    }
}

# -----------------------------
# Add native APIs (FIXED)
# -----------------------------
if (-not ("Win32.NativeMethods" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Win32
{
    public static class NativeMethods
    {
        [DllImport("psapi.dll")]
        public static extern bool EmptyWorkingSet(IntPtr hProcess);

        [DllImport("kernel32.dll")]
        public static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

        [DllImport("kernel32.dll")]
        public static extern bool CloseHandle(IntPtr hObject);

        // NtSetSystemInformation for standby list purge
        [DllImport("ntdll.dll")]
        public static extern int NtSetSystemInformation(int SystemInformationClass, IntPtr SystemInformation, int SystemInformationLength);
    }
}
"@
}

# -----------------------------
# Step 1: Stop Explorer (reduces locks)
# -----------------------------
Write-Host "`n[1/7] Stopping Explorer..." -ForegroundColor Cyan
Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# -----------------------------
# Step 2: Restart DWM
# -----------------------------
Write-Host "[2/7] Restarting DWM..." -ForegroundColor Cyan
Get-Process dwm -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# -----------------------------
# Step 3: Clean TEMP
# -----------------------------
Write-Host "[3/7] Cleaning USER temp..." -ForegroundColor Cyan
Clear-FolderContents -Path $env:TEMP

Write-Host "[4/7] Cleaning SYSTEM temp..." -ForegroundColor Cyan
Clear-FolderContents -Path "C:\Windows\Temp"

Write-Host "[5/7] Cleaning Prefetch (optional)..." -ForegroundColor Cyan
Clear-FolderContents -Path "C:\Windows\Prefetch"

# -----------------------------
# Step 4: Flush DNS
# -----------------------------
Write-Host "[6/7] Flushing DNS cache..." -ForegroundColor Cyan
try { ipconfig /flushdns | Out-Null } catch {}

# -----------------------------
# Step 5: Trim working sets (safe)
# -----------------------------
Write-Host "[7/7] Trimming process working sets..." -ForegroundColor Cyan
# PROCESS_SET_QUOTA = 0x0100, PROCESS_QUERY_INFORMATION = 0x0400
$ACCESS = 0x0100 -bor 0x0400

Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $h = [Win32.NativeMethods]::OpenProcess($ACCESS, $false, $_.Id)
        if ($h -ne [IntPtr]::Zero) {
            [Win32.NativeMethods]::EmptyWorkingSet($h) | Out-Null
            [Win32.NativeMethods]::CloseHandle($h) | Out-Null
        }
    }
    catch { }
}

# -----------------------------
# Enable required privileges + Clear Standby List
# -----------------------------
if (-not ("Win32.Privilege" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Win32
{
    public static class Privilege
    {
        [StructLayout(LayoutKind.Sequential, Pack=1)]
        public struct LUID { public uint LowPart; public int HighPart; }

        [StructLayout(LayoutKind.Sequential, Pack=1)]
        public struct TOKEN_PRIVILEGES
        {
            public int PrivilegeCount;
            public LUID Luid;
            public int Attributes;
        }

        public const int SE_PRIVILEGE_ENABLED = 0x2;
        public const int TOKEN_ADJUST_PRIVILEGES = 0x20;
        public const int TOKEN_QUERY = 0x8;

        [DllImport("advapi32.dll", SetLastError=true)]
        public static extern bool OpenProcessToken(IntPtr ProcessHandle, int DesiredAccess, out IntPtr TokenHandle);

        [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

        [DllImport("advapi32.dll", SetLastError=true)]
        public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges,
            ref TOKEN_PRIVILEGES NewState, int BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool CloseHandle(IntPtr hObject);

        public static bool EnablePrivilege(string name)
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
                return false;

            LUID luid;
            if (!LookupPrivilegeValue(null, name, out luid))
            {
                CloseHandle(token);
                return false;
            }

            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Luid = luid;
            tp.Attributes = SE_PRIVILEGE_ENABLED;

            bool ok = AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            CloseHandle(token);
            return ok;
        }
    }
}
"@
}

Write-Host "Advanced: Clearing Standby Memory List..." -ForegroundColor Yellow

# Try enabling commonly-required privileges
$privs = @("SeProfileSingleProcessPrivilege", "SeIncreaseQuotaPrivilege", "SeSystemProfilePrivilege")
foreach ($p in $privs) {
    [Win32.Privilege]::EnablePrivilege($p) | Out-Null
}

try {
    $val = 4  # MemoryPurgeStandbyList
    $ptr = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
    [Runtime.InteropServices.Marshal]::WriteInt32($ptr, $val)
    $status = [Win32.NativeMethods]::NtSetSystemInformation(80, $ptr, 4)
    [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)

    if ($status -eq 0) {
        Write-Host "Standby list cleared successfully." -ForegroundColor Green
    }
    else {
        Write-Host "Standby purge returned NTSTATUS: 0x$("{0:X8}" -f $status)" -ForegroundColor DarkYellow
        Write-Host "Fallback: use ISLC or RAMMap to clear standby list (100% reliable)." -ForegroundColor DarkYellow
    }
}
catch {
    Write-Host "Standby purge failed. Fallback: ISLC or RAMMap." -ForegroundColor DarkYellow
}


# -----------------------------
# Restart Explorer
# -----------------------------
Write-Host "Restarting Explorer..." -ForegroundColor Cyan
Start-Process explorer.exe

Write-Host "`nDone. Windows refreshed." -ForegroundColor Green
Read-Host "Press Enter to close"
