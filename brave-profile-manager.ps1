# brave-profile-manager.ps1
#
# Add or remove fully independent Brave browser profiles as Start menu and
# Desktop launchers on Windows. Each profile lives in its own Brave data
# folder (--user-data-dir), so it behaves like a completely separate browser
# install with its own bookmarks, logins, extensions and cache.
#
# Each launcher:
#   - appears in the Start menu app list and on the Desktop
#   - uses its own taskbar icon and taskbar group. Each shortcut and running
#     window share one explicit taskbar identity, so pinning stays grouped.
#   - is registered as its own browser, so it shows up in
#     Settings > Apps > Default apps and can be set as the default browser
#   - supports the same protocols and file types as Brave, and appears in
#     "Open with" menus; links and files open in this profile
#   - has its own uninstall entry, backed by a self-contained uninstaller
#     generated for that profile, so removing one never affects the others
#
# MENU:
#   [1] Add / create new profile(s) : asks how many, then a name and color for
#                                      each; the data folder comes from the name
#   [2] Remove existing profile(s)  : lists them, you pick which to remove
#
# Everything is stored under your own user account, so no admin rights are needed.
#
# Run:  powershell -ExecutionPolicy Bypass -File .\brave-profile-manager.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$Marker      = 'Brave Profile Manager'
$InstallDir  = Join-Path $env:LOCALAPPDATA 'BraveProfileManager'
$IconsDir    = Join-Path $InstallDir 'icons'
$UninstallersDir = Join-Path $InstallDir 'uninstallers'
# Separate data folders live outside $InstallDir, so launchers stay independent
# of the shared support files.
$DataRoot    = Join-Path $env:LOCALAPPDATA 'BraveProfiles'
$ClientsKey  = 'HKCU:\Software\Clients\StartMenuInternet'
$IdPrefix    = 'BraveProfileManager.'
# The shortcut gets the AUMID Brave itself assigns to this data folder. Using
# Brave's own ID (instead of inventing one) keeps new windows opened inside
# Brave grouped with the pin, not just the first window we launch.

$BravePaths = @(
    "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe",
    "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
    "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Ask([string]$prompt, [string]$default) {
    $a = Read-Host ("{0} [{1}]" -f $prompt, $default)
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a.Trim()
}

function Get-Slug([string]$s) {
    $x = $s.ToLower() -replace '[ _]+', '-' -replace '[^a-z0-9-]', '' -replace '-+', '-'
    return $x.Trim('-')
}

# Slugs are lowercase, so "Twin", "twin" and "TWIN" all count as the same name.
function Test-SlugInUse([string]$slug, $items) {
    if ($items | Where-Object { $_.Slug -eq $slug }) { return $true }
    if (Get-Launchers | Where-Object { $_.Slug -eq $slug }) { return $true }
    if (Test-Path -LiteralPath (Join-Path $DataRoot $slug)) { return $true }
    if (Test-Path -LiteralPath (Join-Path $UninstallersDir $slug)) { return $true }
    return $false
}

function Set-RegDefault([string]$path, [string]$value) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name '(default)' -Value $value
}

function Send-AssocChanged {
    try {
        Add-Type -Namespace BraveProfile -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll")]
public static extern void SHChangeNotify(int wEventId, uint uFlags, System.IntPtr dwItem1, System.IntPtr dwItem2);
'@ -ErrorAction Stop
        [BraveProfile.Native]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch { }
}

# Mirror the protocols and file types Brave itself advertises. The fallback is
# Brave's current list, used when Brave has not registered itself yet.
function Get-BraveAssociations {
    $schemes = @('http', 'https', 'irc', 'mailto', 'mms', 'news', 'nntp',
                 'sms', 'smsto', 'snews', 'tel', 'urn', 'webcal', 'brave-browser')
    $exts    = @('.htm', '.html', '.mhtml', '.shtml', '.svg', '.xht', '.xhtml',
                 '.webp', '.pdf')
    $roots = @('HKCU:\Software\Clients\StartMenuInternet',
               'HKLM:\SOFTWARE\Clients\StartMenuInternet',
               'HKLM:\SOFTWARE\WOW6432Node\Clients\StartMenuInternet')
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $clients = Get-ChildItem -Path $root -ErrorAction SilentlyContinue |
                   Where-Object { $_.PSChildName -like 'Brave.*' }
        foreach ($c in $clients) {
            foreach ($part in @('URLAssociations', 'FileAssociations')) {
                $p = Join-Path (Join-Path $root $c.PSChildName) $part
                if (-not (Test-Path $p)) { continue }
                $names = @(Get-Item -Path $p).GetValueNames() | Where-Object { $_ }
                if ($part -eq 'URLAssociations') { $schemes += $names } else { $exts += $names }
            }
        }
    }
    [pscustomobject]@{
        Schemes    = @($schemes | Sort-Object -Unique)
        Extensions = @($exts | Where-Object { $_ -like '.*' } | Sort-Object -Unique)
    }
}

# OpenWithProgids is what makes an app appear in the right-click "Open with"
# list. It does not change the user's default app for the file type.
function Set-OpenWithProgId([string]$ext, [string]$progId, [switch]$Remove) {
    $key = "HKCU:\Software\Classes\$ext\OpenWithProgids"
    if ($Remove) {
        Remove-ItemProperty -Path $key -Name $progId -ErrorAction SilentlyContinue
        return
    }
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name $progId -Value '' -PropertyType String -Force | Out-Null
}

function Remove-OpenWithProgIdEverywhere([string]$progId) {
    $root = 'HKCU:\Software\Classes'
    if (-not (Test-Path $root)) { return }
    foreach ($ext in (Get-ChildItem -Path $root -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '.*' })) {
        $key = Join-Path $ext.PSPath 'OpenWithProgids'
        if (Test-Path $key) { Remove-ItemProperty -Path $key -Name $progId -ErrorAction SilentlyContinue }
    }
}

# Windows keeps a separate UserChoice when someone makes this launcher the
# default for a file type or protocol. Only delete choices that point at us.
function Remove-UserChoiceForProgId([string]$progId) {
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts',
        'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($assoc in (Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $choice = Join-Path $assoc.PSPath 'UserChoice'
            if (-not (Test-Path $choice)) { continue }
            if ((Get-Item -Path $choice).GetValue('ProgId') -eq $progId) {
                Remove-Item -Path $choice -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# Read/write the AppUserModelID stored inside a .lnk file, and read the one
# Brave assigns to its own windows. The shortcut gets Brave's natural ID so a
# pin and every window of that launcher group together.
$aumidTypeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace BraveProfileAumid {
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    interface IShellLinkW {
        uint GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cchMaxPath, ref WIN32_FIND_DATAW pfd, uint fFlags);
        uint GetIDList(out IntPtr ppidl);
        uint SetIDList(IntPtr pidl);
        uint GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cchMaxName);
        uint SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        uint GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cchMaxPath);
        uint SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        uint GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cchMaxPath);
        uint SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        uint GetHotKey(out ushort pwHotkey);
        uint SetHotKey(ushort wHotKey);
        uint GetShowCmd(out int piShowCmd);
        uint SetShowCmd(int iShowCmd);
        uint GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cchIconPath, out int piIcon);
        uint SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        uint SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        uint Resolve(IntPtr hwnd, uint fFlags);
        uint SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }
    [ComImport, ClassInterface(ClassInterfaceType.None), Guid("00021401-0000-0000-C000-000000000046")]
    class CShellLink { }
    [StructLayout(LayoutKind.Sequential, Pack = 4, CharSet = CharSet.Unicode)]
    struct WIN32_FIND_DATAW {
        public uint dwFileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime, ftLastAccessTime, ftLastWriteTime;
        public uint nFileSizeHigh, nFileSizeLow, dwReserved0, dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string cAlternateFileName;
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        uint GetCount(out uint cProps);
        uint GetAt(uint iProp, out PROPERTYKEY pkey);
        uint GetValue(ref PROPERTYKEY key, PropVariant pv);
        uint SetValue(ref PROPERTYKEY key, PropVariant pv);
        uint Commit();
    }
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PROPERTYKEY { public Guid fmtid; public int pid; public PROPERTYKEY(Guid g, int p) { fmtid = g; pid = p; } }
    [StructLayout(LayoutKind.Explicit)]
    sealed class PropVariant : IDisposable {
        [FieldOffset(0)] ushort vt;
        [FieldOffset(8)] IntPtr ptr;
        public PropVariant() { }
        public PropVariant(string s) { vt = 31; ptr = Marshal.StringToCoTaskMemUni(s); }
        public string Value { get { return (vt == 31 && ptr != IntPtr.Zero) ? Marshal.PtrToStringUni(ptr) : ""; } }
        public void Dispose() { PropVariantClear(this); GC.SuppressFinalize(this); }
        [DllImport("Ole32.dll", PreserveSig = false)] static extern void PropVariantClear(PropVariant p);
    }
    public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    static class Native {
        static PROPERTYKEY AumidKey = new PROPERTYKEY(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);
        [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, out IPropertyStore ps);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc f, IntPtr l);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int c);
        static void Check(uint h) { if (h > 1) throw new InvalidOperationException(string.Format("HRESULT 0x{0:X}", h)); }
        public static void Write(string path, string id) {
            var link = (IShellLinkW)new CShellLink();
            try {
                ((IPersistFile)link).Load(path, 2);
                var store = (IPropertyStore)link;
                using (var pv = new PropVariant(id)) { Check(store.SetValue(ref AumidKey, pv)); Check(store.Commit()); }
                ((IPersistFile)link).Save(path, true);
            } finally { Marshal.FinalReleaseComObject(link); }
        }
        public static string ReadWindow(IntPtr hwnd) {
            Guid iid = typeof(IPropertyStore).GUID; IPropertyStore store;
            if (SHGetPropertyStoreForWindow(hwnd, ref iid, out store) != 0) { return ""; }
            try {
                using (var pv = new PropVariant()) { Check(store.GetValue(ref AumidKey, pv)); return pv.Value; }
            } finally { Marshal.ReleaseComObject(store); }
        }
        public static IntPtr FindWindowByPid(uint wanted) {
            IntPtr found = IntPtr.Zero;
            EnumWindows(delegate(IntPtr h, IntPtr l) {
                uint pid; GetWindowThreadProcessId(h, out pid);
                if (pid == wanted && IsWindowVisible(h)) {
                    StringBuilder title = new StringBuilder(300); GetWindowText(h, title, title.Capacity);
                    if (title.Length > 0) { found = h; return false; }
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }
    }
    public static class Api {
        public static void Write(string path, string id) { Native.Write(path, id); }
        public static string ReadWindow(IntPtr hwnd) { return Native.ReadWindow(hwnd); }
        public static IntPtr FindWindowByPid(uint pid) { return Native.FindWindowByPid(pid); }
    }
}
'@
if (-not ('BraveProfileAumid.Api' -as [type])) { Add-Type -TypeDefinition $aumidTypeSource -ErrorAction Stop }

function Set-LauncherAumid([string]$Path, [string]$Id) {
    [BraveProfileAumid.Api]::Write($Path, $Id)
}

function Get-BrowserAumid([string]$brave, [string]$dataDir) {
    # Brave assigns its own AUMID per user-data-dir. Using that exact ID on the
    # shortcut keeps every window of this launcher grouped with its pin, and
    # new windows opened from Brave's UI inherit it automatically.
    $needle  = '--user-data-dir="' + $dataDir + '"'
    $needle2 = '--user-data-dir=' + $dataDir
    $matches = @(Get-CimInstance Win32_Process -Filter "Name = 'brave.exe'" | Where-Object {
        $cl = $_.CommandLine
        $cl -and $cl -notmatch '--type=' -and
        (($cl.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
         ($cl.IndexOf($needle2, [System.StringComparison]::OrdinalIgnoreCase) -ge 0))
    })

    $started = $false
    if ($matches.Count -eq 0) {
        Start-Process -FilePath $brave -ArgumentList @(
            ('--user-data-dir="{0}"' -f $dataDir), '--no-first-run', '--no-default-browser-check'
        )
        $started = $true
    }

    $aumid = ''
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline -and -not $aumid) {
        $matches = @(Get-CimInstance Win32_Process -Filter "Name = 'brave.exe'" | Where-Object {
            $cl = $_.CommandLine
            $cl -and $cl -notmatch '--type=' -and
            (($cl.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
             ($cl.IndexOf($needle2, [System.StringComparison]::OrdinalIgnoreCase) -ge 0))
        })
        foreach ($p in $matches) {
            $h = [BraveProfileAumid.Api]::FindWindowByPid([uint32]$p.ProcessId)
            if ($h -ne [IntPtr]::Zero) {
                $aumid = [BraveProfileAumid.Api]::ReadWindow($h)
                if ($aumid) { break }
            }
        }
        if (-not $aumid) { Start-Sleep -Milliseconds 300 }
    }

    if ($started) {
        foreach ($p in $matches) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    if (-not $aumid) {
        throw ('Could not determine Brave''s taskbar ID for {0}' -f $dataDir)
    }
    return $aumid
}

function Get-DotColor([string]$c) {
    if ($c -match '^#?([0-9a-fA-F]{6})$') { return [System.Drawing.ColorTranslator]::FromHtml('#' + $Matches[1]) }
    $col = [System.Drawing.Color]::FromName($c)
    if ($col.IsKnownColor) { return $col }
    return $null
}

function New-LauncherIcon([string]$brave, [System.Drawing.Color]$color, [string]$outPath) {
    # Brave's own icon with a colored dot in the top-right corner, saved as .ico
    $base = [System.Drawing.Icon]::ExtractAssociatedIcon($brave).ToBitmap()
    $w = $base.Width; $h = $base.Height
    $bmp = [System.Drawing.Bitmap]::new($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.DrawImage($base, 0, 0, $w, $h)

    $d     = [int]($w * 0.4)
    $inset = [Math]::Max(1, [int]($w * 0.04))
    $x = $w - $d - $inset; $y = $inset
    $brush = [System.Drawing.SolidBrush]::new($color)
    $pen   = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(153, 0, 0, 0), 1)
    $g.FillEllipse($brush, $x, $y, $d, $d)
    $g.DrawEllipse($pen, $x, $y, $d - 1, $d - 1)

    $ms = [System.IO.MemoryStream]::new()
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $ms.ToArray()
    $g.Dispose(); $bmp.Dispose(); $base.Dispose(); $brush.Dispose(); $pen.Dispose(); $ms.Dispose()

    # ICO container holding one PNG image
    $fs = [System.IO.File]::Create($outPath)
    $bw = [System.IO.BinaryWriter]::new($fs)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)
    $bw.Write([byte]($w % 256)); $bw.Write([byte]($h % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$png.Length); $bw.Write([uint32]22)
    $bw.Write($png)
    $bw.Dispose(); $fs.Dispose()
}

function Initialize-ProfileIcon([string]$dataDir, [string]$iconPath) {
    # Brave uses <data dir>\Default\Google Profile.ico as this profile's
    # taskbar "relaunch icon". Keep our custom icon there and mark the profile
    # icon as current so Brave does not overwrite it on startup.
    $profileDir = Join-Path $dataDir 'Default'
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    Copy-Item -LiteralPath $iconPath -Destination (Join-Path $profileDir 'Google Profile.ico') -Force

    $prefPath = Join-Path $profileDir 'Preferences'
    $prefs = [ordered]@{}
    if (Test-Path -LiteralPath $prefPath) {
        try { $prefs = Get-Content -LiteralPath $prefPath -Raw | ConvertFrom-Json } catch { $prefs = [ordered]@{} }
    }
    if (-not $prefs.PSObject.Properties['profile']) {
        $prefs | Add-Member -NotePropertyName 'profile' -NotePropertyValue ([ordered]@{}) -Force
    }
    $prefs.profile | Add-Member -NotePropertyName 'icon_version' -NotePropertyValue 10 -Force
    $prefs.profile | Add-Member -NotePropertyName 'icon_win11_format' -NotePropertyValue $true -Force

    $json = $prefs | ConvertTo-Json -Depth 100 -Compress
    [System.IO.File]::WriteAllText($prefPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-LauncherShortcuts {
    # All .lnk files in the Start menu and Desktop created by this script.
    $ws   = New-Object -ComObject WScript.Shell
    $dirs = @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop')) |
            Where-Object { $_ -and (Test-Path $_) }
    foreach ($d in $dirs) {
        Get-ChildItem -Path $d -Filter '*.lnk' -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $desc = $ws.CreateShortcut($_.FullName).Description
                if ($desc -like "$Marker*") {
                    [pscustomobject]@{ Path = $_.FullName; Description = $desc }
                }
            } catch { }
        }
    }
}

function Get-Launchers {
    if (-not (Test-Path $ClientsKey)) { return }
    Get-ChildItem -Path $ClientsKey | Where-Object { $_.PSChildName -like "$IdPrefix*" } | ForEach-Object {
        [pscustomobject]@{
            Slug    = $_.PSChildName.Substring($IdPrefix.Length)
            Name    = $_.GetValue('')
            DataDir = $_.GetValue('DataDir')
            Aumid   = $_.GetValue('Aumid')
        }
    }
}

function Get-Status {
    [pscustomobject]@{
        Profiles = @(Get-Launchers).Count
    }
}

# ---------------------------------------------------------------------------
# Registering a launcher as a browser (Settings > Apps > Default apps)
# ---------------------------------------------------------------------------

# Each profile gets its own self-contained uninstaller. It is generated at
# creation time and never overwritten by later script versions, so a profile is
# always removed by the same version that created it. Only the tiny cmd wrapper
# below is shared, and it does nothing except pick PowerShell 5.1 or 7.
function Register-UninstallEntry([string]$slug, [string]$name, [string]$icon, [string]$dataDir) {
    $id = "$IdPrefix$slug"
    $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$id"

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $wrapper = Join-Path $InstallDir 'uninstall.cmd'
    $batch = @'
@echo off
setlocal
set "PS=powershell.exe"
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PS=%ProgramFiles%\PowerShell\7\pwsh.exe"
if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" set "PS=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
where pwsh.exe >nul 2>nul && for /f "delims=" %%P in ('where pwsh.exe') do set "PS=%%P"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~1" %~2
exit /b %ERRORLEVEL%
'@
    Set-Content -Path $wrapper -Value $batch -Encoding ASCII

    $uninstallerDir = Join-Path $UninstallersDir $slug
    if (Test-Path -LiteralPath $uninstallerDir) {
        Remove-Item -LiteralPath $uninstallerDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $uninstallerDir -Force | Out-Null
    $uninstaller = Join-Path $uninstallerDir 'uninstall.ps1'

    $script = @'
param([switch]$KeepData, [switch]$NoPause)

# Generated by Brave Profile Manager on __GENERATED__.
# Profile: __NAME__
# Slug:    __SLUG__
# Data:    __DATA_DIR__
# This file is self-contained: later versions of the manager never rewrite it.

$ErrorActionPreference = 'Stop'
$id             = '__ID__'
$slug           = '__SLUG__'
$name           = '__NAME__'
$dataDir        = '__DATA_DIR__'
$marker         = '__MARKER__'
$uninstallerDir = '__UNINSTALLER_DIR__'

function Send-AssocChanged {
    try {
        $def = '[System.Runtime.InteropServices.DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, uint uFlags, System.IntPtr dwItem1, System.IntPtr dwItem2);'
        Add-Type -Namespace BraveProfileUninstall -Name Native -MemberDefinition $def -ErrorAction Stop
        [BraveProfileUninstall.Native]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch { }
}

function Remove-OpenWithProgIdEverywhere([string]$progId) {
    $root = 'HKCU:\Software\Classes'
    if (-not (Test-Path $root)) { return }
    foreach ($ext in (Get-ChildItem -Path $root -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '.*' })) {
        $key = Join-Path $ext.PSPath 'OpenWithProgids'
        if (Test-Path $key) { Remove-ItemProperty -Path $key -Name $progId -ErrorAction SilentlyContinue }
    }
}

function Remove-UserChoiceForProgId([string]$progId) {
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts',
        'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($assoc in (Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $choice = Join-Path $assoc.PSPath 'UserChoice'
            if (-not (Test-Path $choice)) { continue }
            if ((Get-Item -Path $choice).GetValue('ProgId') -eq $progId) {
                Remove-Item -Path $choice -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-LauncherShortcuts {
    $ws = New-Object -ComObject WScript.Shell
    $dirs = @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop')) |
            Where-Object { $_ -and (Test-Path $_) }
    foreach ($d in $dirs) {
        Get-ChildItem -Path $d -Filter '*.lnk' -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($ws.CreateShortcut($_.FullName).Description -eq "$marker [$slug]") {
                    $_.FullName
                }
            } catch { }
        }
    }
}

foreach ($lnk in @(Get-LauncherShortcuts)) {
    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
    Write-Host "  removed shortcut: $lnk"
}

$legacyVbs = Join-Path $env:LOCALAPPDATA "BraveProfileManager\$slug.vbs"
if (Test-Path -LiteralPath $legacyVbs) {
    Remove-Item -LiteralPath $legacyVbs -Force -ErrorAction SilentlyContinue
    Write-Host "  removed legacy launcher: $legacyVbs"
}
$iconPath = Join-Path $env:LOCALAPPDATA "BraveProfileManager\icons\$slug.ico"
if (Test-Path -LiteralPath $iconPath) {
    Remove-Item -LiteralPath $iconPath -Force -ErrorAction SilentlyContinue
    Write-Host "  removed icon: $iconPath"
}

Remove-OpenWithProgIdEverywhere $id
Remove-UserChoiceForProgId $id
Write-Host "  cleared file/protocol choices for $id"
Remove-Item -Path "HKCU:\Software\Classes\$id" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  removed browser registration: $id"
Remove-Item -Path "HKCU:\Software\Clients\StartMenuInternet\$id" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  removed browser entry: $id"
Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$id" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  removed uninstall entry: $id"
Remove-ItemProperty -Path 'HKCU:\Software\RegisteredApplications' -Name $id -ErrorAction SilentlyContinue
Write-Host "  removed RegisteredApplications value: $id"

if ($dataDir -and (Test-Path -LiteralPath $dataDir) -and
    ($dataDir -like ((Join-Path $env:LOCALAPPDATA 'BraveProfiles\*')))) {
    if ($KeepData) {
        Write-Host "  Kept $dataDir (quiet uninstall)"
    } else {
        Write-Host ''
        Write-Host "Profile data for '$name' still exists at: $dataDir" -ForegroundColor Yellow
        $confirm = (Read-Host "  Delete this browsing data too? This is permanent. Type 'yes' to delete, anything else to keep").Trim().ToLower()
        if ($confirm -eq 'yes') {
            Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  deleted $dataDir" -ForegroundColor Green
        } else {
            Write-Host "  Kept $dataDir"
        }
    }
}

Send-AssocChanged
Write-Host "Removed profile: $name" -ForegroundColor Green
Remove-Item -LiteralPath $uninstallerDir -Recurse -Force -ErrorAction SilentlyContinue
if (-not $NoPause) {
    Write-Host 'Press Enter to continue'
    try { Read-Host | Out-Null } catch { }
}
'@
    $script = $script.Replace('__GENERATED__', (Get-Date -Format o).Replace("'", "''"))
    $script = $script.Replace('__NAME__', $name.Replace("'", "''"))
    $script = $script.Replace('__SLUG__', $slug.Replace("'", "''"))
    $script = $script.Replace('__DATA_DIR__', $dataDir.Replace("'", "''"))
    $script = $script.Replace('__ID__', $id.Replace("'", "''"))
    $script = $script.Replace('__MARKER__', $Marker.Replace("'", "''"))
    $script = $script.Replace('__UNINSTALLER_DIR__', $uninstallerDir.Replace("'", "''"))
    [System.IO.File]::WriteAllText($uninstaller, $script, (New-Object System.Text.UTF8Encoding($true)))

    $shell = $env:ComSpec
    if ($shell -match ' ') { $shell = '"' + $shell + '"' }
    $cmd   = '{0} /c ""{1}" "{2}""' -f $shell, $wrapper, $uninstaller
    $quiet = '{0} /c ""{1}" "{2}" -KeepData"' -f $shell, $wrapper, $uninstaller

    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name 'DisplayName'           -Value $name
    Set-ItemProperty -Path $key -Name 'DisplayVersion'        -Value '1.0'
    Set-ItemProperty -Path $key -Name 'Publisher'             -Value 'Brave Profile Manager'
    Set-ItemProperty -Path $key -Name 'DisplayIcon'           -Value "$icon,0"
    Set-ItemProperty -Path $key -Name 'InstallLocation'       -Value $dataDir
    Set-ItemProperty -Path $key -Name 'UninstallString'       -Value $cmd
    Set-ItemProperty -Path $key -Name 'QuietUninstallString'  -Value $quiet
    Set-ItemProperty -Path $key -Name 'NoModify'              -Value 1
    Set-ItemProperty -Path $key -Name 'NoRepair'              -Value 1
}

function Register-Browser([string]$slug, [string]$name, [string]$brave, [string]$dataDir, [string]$iconPath, [string]$aumid) {
    $id        = "$IdPrefix$slug"
    $icon      = $iconPath
    $desc      = 'Brave browser profile with its own data folder, icon and taskbar group.'
    $cls       = "HKCU:\Software\Classes\$id"
    $cli       = "$ClientsKey\$id"
    $cap       = "$cli\Capabilities"
    $assoc     = Get-BraveAssociations
    # --single-argument must stay last: everything after it is treated as the
    # one shell-supplied URL/file argument, matching Brave's own registration.
    $openCmd   = ('"{0}" --user-data-dir="{1}" --single-argument %1' -f $brave, $dataDir)
    $launchCmd = ('"{0}" --user-data-dir="{1}"' -f $brave, $dataDir)

    # Start clean so stale values from an earlier run never linger.
    foreach ($k in @($cls, $cli)) {
        if (Test-Path $k) { Remove-Item -Path $k -Recurse -Force }
    }

    # ProgId that Windows uses to open links and files with this launcher.
    Set-RegDefault $cls $name
    Set-ItemProperty -Path $cls -Name 'AppUserModelId' -Value $aumid
    Set-RegDefault "$cls\Application" ''
    Set-ItemProperty -Path "$cls\Application" -Name 'ApplicationName'        -Value $name
    Set-ItemProperty -Path "$cls\Application" -Name 'ApplicationDescription' -Value $desc
    Set-ItemProperty -Path "$cls\Application" -Name 'ApplicationIcon'        -Value $icon
    Set-RegDefault "$cls\DefaultIcon" $icon
    Set-RegDefault "$cls\shell\open\command" $openCmd

    # The browser entry itself.
    Set-RegDefault $cli $name
    Set-ItemProperty -Path $cli -Name 'DataDir' -Value $dataDir
    Set-ItemProperty -Path $cli -Name 'Aumid' -Value $aumid
    Set-RegDefault "$cli\DefaultIcon" $icon
    Set-RegDefault "$cli\shell\open\command" $launchCmd

    Set-RegDefault $cap ''
    Set-ItemProperty -Path $cap -Name 'ApplicationName'        -Value $name
    Set-ItemProperty -Path $cap -Name 'ApplicationDescription' -Value $desc
    Set-ItemProperty -Path $cap -Name 'ApplicationIcon'        -Value $icon

    Set-RegDefault "$cap\URLAssociations" ''
    foreach ($proto in $assoc.Schemes) {
        Set-ItemProperty -Path "$cap\URLAssociations" -Name $proto -Value $id
    }
    Set-RegDefault "$cap\FileAssociations" ''
    foreach ($ext in $assoc.Extensions) {
        Set-ItemProperty -Path "$cap\FileAssociations" -Name $ext -Value $id
        Set-OpenWithProgId $ext $id
    }
    Set-RegDefault "$cap\StartMenu" ''
    Set-ItemProperty -Path "$cap\StartMenu" -Name 'StartMenuInternet' -Value $id

    $ra = 'HKCU:\Software\RegisteredApplications'
    if (-not (Test-Path $ra)) { New-Item -Path $ra -Force | Out-Null }
    Set-ItemProperty -Path $ra -Name $id -Value "Software\Clients\StartMenuInternet\$id\Capabilities"

    Register-UninstallEntry $slug $name $iconPath $dataDir
}

# ---------------------------------------------------------------------------
# Add
# ---------------------------------------------------------------------------

function Install-Launchers {
    $brave = $BravePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $brave) {
        Write-Host 'Could not find brave.exe in the usual locations. Nothing was changed.' -ForegroundColor Yellow
        return
    }
    Write-Host "Found Brave: $brave"
    Write-Host 'Tip: each profile starts with an empty data folder, so you sign in to sites again there.'
    Write-Host ''

    # How many?
    while ($true) {
        $n = Ask 'How many profiles do you want to create?' '1'
        if ($n -match '^\d+$' -and [int]$n -ge 1) { $count = [int]$n; break }
        Write-Host 'Enter a positive whole number.' -ForegroundColor Yellow
    }

    # Every profile gets its own data folder, so it is fully independent.
    Write-Host ''
    Write-Host ('Each profile gets its own data folder under {0}' -f $DataRoot)
    Write-Host 'Its bookmarks, logins, extensions and cache stay separate from your main Brave.'

    # Details for each
    $items = @()
    for ($i = 1; $i -le $count; $i++) {
        Write-Host ''
        Write-Host "Profile $i of $count" -ForegroundColor Cyan
        $defName = if ($i -eq 1) { 'Brave profile' } else { "Brave profile $i" }

        while ($true) {
            $name = Ask '  Name (exactly as you want it to appear)' $defName

            $safe = ($name -replace '[\\/:*?"<>|]', '').Trim()
            if (-not $safe) { $safe = $defName }
            $slug = Get-Slug $name
            if (-not $slug) { $slug = "profile-$i" }

            if (-not (Test-SlugInUse $slug $items)) { break }
            Write-Host "  '$slug' is already used by a profile or data folder. Choose a different name (capital letters don't make it different)." -ForegroundColor Yellow
        }

        # The data folder is derived from the name; it is not asked separately.
        $folder = $slug
        $dataDir = Join-Path $DataRoot $folder

        while ($true) {
            $colorIn = Ask '  Dot color on the icon (e.g. red, dodgerblue or #ff5500)' 'red'
            $color = Get-DotColor $colorIn
            if ($null -ne $color) { break }
            Write-Host 'Unknown color, try again.' -ForegroundColor Yellow
        }

        $items += [pscustomobject]@{ Name = $name; Safe = $safe; Slug = $slug
            DataDir = $dataDir; Color = $color }
    }

    Write-Host ''
    Write-Host 'A shortcut will also be placed on the Desktop.'

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    New-Item -ItemType Directory -Path $IconsDir -Force | Out-Null

    # Per profile: Start menu and Desktop shortcuts that launch Brave directly
    # with this profile's data folder, carrying Brave's own taskbar identity,
    # plus browser registration. No helper process is involved.
    $ws = New-Object -ComObject WScript.Shell
    foreach ($it in $items) {
        $aumid    = Get-BrowserAumid $brave $it.DataDir
        $iconPath = Join-Path $IconsDir ($it.Slug + '.ico')
        New-LauncherIcon $brave $it.Color $iconPath
        Initialize-ProfileIcon $it.DataDir $iconPath

        $targets = @(
            (Join-Path ([Environment]::GetFolderPath('Programs')) ($it.Safe + '.lnk')),
            (Join-Path ([Environment]::GetFolderPath('Desktop')) ($it.Safe + '.lnk'))
        )
        foreach ($t in $targets) {
            $lnk = $ws.CreateShortcut($t)
            $lnk.TargetPath       = $brave
            $lnk.Arguments        = ('--user-data-dir="{0}"' -f $it.DataDir)
            $lnk.WorkingDirectory = Split-Path $brave
            $lnk.IconLocation     = $iconPath
            $lnk.Description      = ('{0} [{1}]' -f $Marker, $it.Slug)
            $lnk.Save()
            Set-LauncherAumid $t $aumid
        }

        Register-Browser $it.Slug $it.Name $brave $it.DataDir $iconPath $aumid
        Write-Host ("Created profile: {0}  (data folder: {1})" -f $it.Name, $it.DataDir) -ForegroundColor Green
    }

    Send-AssocChanged

    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Green
    Write-Host '  - Open a profile from the Start menu (search for the exact name you gave it).'
    Write-Host '  - Pin it from its Start menu/Desktop shortcut. If you replace or recreate a'
    Write-Host '    profile, unpin the old taskbar button first: Windows caches the pin''s identity.'
    Write-Host '  - To make one the default browser: Settings > Apps > Default apps, find it by name,'
    Write-Host '    and click "Set default". Windows does not allow a script to do that step for you.'
    Write-Host '    If it is not listed yet, close and reopen Settings.'
}

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------

function Remove-OneLauncher($c) {
    # Prefer the uninstaller saved when this profile was created. It prints
    # exactly what it clears and matches the version that created the profile.
    $uninstaller = Join-Path $UninstallersDir ($c.Slug + '\uninstall.ps1')
    if (Test-Path -LiteralPath $uninstaller) {
        Write-Host ("Removing '{0}' with its saved uninstaller..." -f $c.Name) -ForegroundColor Cyan
        & $uninstaller -NoPause
        return
    }

    # Fallback for older profiles that never got a saved uninstaller.
    $desc = '{0} [{1}]' -f $Marker, $c.Slug
    foreach ($l in @(Get-LauncherShortcuts | Where-Object { $_.Description -eq $desc })) {
        Remove-Item -Path $l.Path -Force
        Write-Host "  removed shortcut: $($l.Path)"
    }
    $legacyVbs = Join-Path $InstallDir ($c.Slug + '.vbs')
    if (Test-Path -LiteralPath $legacyVbs) {
        Remove-Item -LiteralPath $legacyVbs -Force -ErrorAction SilentlyContinue
        Write-Host "  removed legacy launcher: $legacyVbs"
    }
    $iconPath = Join-Path $IconsDir ($c.Slug + '.ico')
    if (Test-Path -LiteralPath $iconPath) {
        Remove-Item -LiteralPath $iconPath -Force -ErrorAction SilentlyContinue
        Write-Host "  removed icon: $iconPath"
    }

    $id = "$IdPrefix$($c.Slug)"
    Remove-OpenWithProgIdEverywhere $id
    Remove-UserChoiceForProgId $id
    Write-Host "  cleared file/protocol choices for $id"
    Remove-Item -Path "HKCU:\Software\Classes\$id" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  removed browser registration: $id"
    Remove-Item -Path "$ClientsKey\$id" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  removed browser entry: $id"
    Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$id" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  removed uninstall entry: $id"
    Remove-ItemProperty -Path 'HKCU:\Software\RegisteredApplications' -Name $id -ErrorAction SilentlyContinue
    Write-Host "  removed RegisteredApplications value: $id"
    Remove-Item -LiteralPath (Join-Path $UninstallersDir $c.Slug) -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed profile: $($c.Name)" -ForegroundColor Green

    # Ask before deleting browsing data, like the Linux script does. The guard
    # keeps this to folders this script creates, never an arbitrary path.
    if ($c.DataDir -and (Test-Path $c.DataDir) -and
        ($c.DataDir -like ((Join-Path $DataRoot '*')))) {
        Write-Host ''
        Write-Host "Profile data for '$($c.Name)' still exists at: $($c.DataDir)" -ForegroundColor Yellow
        $confirm = (Read-Host "  Delete this browsing data too? This is permanent. Type 'yes' to delete, anything else to keep").Trim().ToLower()
        if ($confirm -eq 'yes') {
            Remove-Item -Path $c.DataDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  deleted $($c.DataDir)" -ForegroundColor Green
        } else {
            Write-Host "  Kept $($c.DataDir)"
        }
    }
}

function Uninstall-Launchers {
    $list = @(Get-Launchers)
    if ($list.Count -eq 0) {
        Write-Host 'No Brave profile launchers found. Nothing to remove.'
        return
    }

    Write-Host ''
    Write-Host ('Found {0} Brave profile launcher(s):' -f $list.Count)
    for ($i = 0; $i -lt $list.Count; $i++) {
        $where = if ($list[$i].DataDir) { 'data: ' + $list[$i].DataDir } else { 'data: none' }
        Write-Host ('  {0,2}) {1}   ({2})' -f ($i + 1), $list[$i].Name, $where)
    }
    Write-Host ''
    $sel = (Read-Host "Which ones to remove? (comma-separated numbers, 'all', or 'q' to quit)").Trim().ToLower()
    if ($sel -eq 'q' -or $sel -eq '') { Write-Host 'Nothing removed.'; return }

    $chosen = @()
    if ($sel -eq 'all') {
        $chosen = $list
    } else {
        foreach ($n in ($sel -split ',')) {
            $n = $n.Trim()
            if ($n -match '^\d+$') {
                $idx = [int]$n - 1
                if ($idx -ge 0 -and $idx -lt $list.Count) { $chosen += $list[$idx] }
            }
        }
    }
    if ($chosen.Count -eq 0) { Write-Host 'Nothing selected, nothing removed.'; return }
    foreach ($c in $chosen) { Remove-OneLauncher $c }

    # When the last profile is gone, remove the shared files too.
    if (@(Get-Launchers).Count -eq 0) {
        if (Test-Path $InstallDir) { Remove-Item -Path $InstallDir -Recurse -Force }
    }

    Send-AssocChanged
    Write-Host ''
    Write-Host 'If a removed profile was your default browser, Windows will ask you to pick another one.'
    Write-Host 'If you pinned a profile to the taskbar, unpin it manually (right-click > Unpin).'
    Write-Host 'Pin the replacement shortcut again so Windows stores its new taskbar identity.'
    Write-Host 'Profile data folders are only deleted when you confirm with yes.'
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------

while ($true) {
    $s = Get-Status
    Write-Host ''
    Write-Host '=== Brave profile manager ===' -ForegroundColor Cyan
    Write-Host ('Status: profiles = {0}' -f $s.Profiles)
    Write-Host ''
    Write-Host '  [1] Add / create new profile(s)'
    Write-Host '  [2] Remove existing profile(s)  (undo; cleans up when the last one is gone)'
    Write-Host '  [Q] Quit'
    Write-Host ''
    $choice = (Read-Host 'Choose 1, 2 or Q').Trim().ToUpper()

    try {
        switch ($choice) {
            '1' { Install-Launchers;   Read-Host 'Press Enter to continue' | Out-Null }
            '2' { Uninstall-Launchers; Read-Host 'Press Enter to continue' | Out-Null }
            'Q' { return }
            default { Write-Host 'Please type 1, 2 or Q.' -ForegroundColor Yellow }
        }
    } catch {
        Write-Host ('Something went wrong: ' + $_.Exception.Message) -ForegroundColor Red
        Read-Host 'Press Enter to continue' | Out-Null
    }
}
