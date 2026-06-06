function Invoke-Decrypt {
    param(
        [string]$TargetDirectory = "$env:USERPROFILE",
        [string]$AESKeyBase64,
        [string]$HMACKeyBase64
    )

    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "   BOM KAOS KAKI DECRYPTOR UTILITY" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan
    
    if (-not $AESKeyBase64 -or -not $HMACKeyBase64) {
        Write-Host "ERROR: Missing AES Key or HMAC Key!" -ForegroundColor Red
        Write-Host "Usage: .\decryptor.ps1 -TargetDirectory 'C:\Path' -AESKeyBase64 '...' -HMACKeyBase64 '...'"
        return
    }

    Write-Host "Scanning directory: $TargetDirectory"

    $Extension = ".bomkaos"
    $NoteFile = "README_BOMKAOS.html"
    
    $encryptedFiles = Get-ChildItem -Path $TargetDirectory -Recurse -File -Filter "*$Extension" -ErrorAction SilentlyContinue
    
    if (-not $encryptedFiles) {
        Write-Host "No $Extension files found to decrypt." -ForegroundColor Yellow
        return
    }

    $count = 0
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
            
            if (-not $valid) { Write-Host "[!] HMAC mismatch: $($ef.FullName)" -ForegroundColor Red; continue }
            
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
            $origPath = $ef.FullName -replace [regex]::Escape($Extension), ''
            [System.IO.File]::WriteAllBytes($origPath, $plaintext)
            
            # Delete encrypted file
            [System.IO.File]::Delete($ef.FullName)
            
            Write-Host "[OK] Decrypted: $(Split-Path $origPath -Leaf)" -ForegroundColor Green
            $count++
        }
        catch {
            Write-Host "[!] Failed to decrypt: $($ef.FullName) - Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    # Remove ransom note
    $notePath = [System.IO.Path]::Combine($TargetDirectory, $NoteFile)
    if (Test-Path $notePath) { Remove-Item $notePath -Force }

    Write-Host "=========================================" -ForegroundColor Green
    Write-Host "   DECRYPTION COMPLETE!" -ForegroundColor Green
    Write-Host "   Successfully restored $count files." -ForegroundColor Green
    Write-Host "=========================================" -ForegroundColor Green
}
