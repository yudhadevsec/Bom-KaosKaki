function Invoke-Decrypt {
    param(
        [string]$TargetDirectory = "$env:USERPROFILE"
    )

    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "   KAOSKAKI DECRYPTOR UTILITY" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "Scanning directory: $TargetDirectory"

    $encryptedFiles = Get-ChildItem -Path $TargetDirectory -Recurse -File -Filter "*.kaoskaki" -ErrorAction SilentlyContinue
    
    if (-not $encryptedFiles) {
        Write-Host "No .kaoskaki files found to decrypt." -ForegroundColor Yellow
        return
    }

    $count = 0
    foreach ($file in $encryptedFiles) {
        try {
            $originalPath = $file.FullName.Substring(0, $file.FullName.Length - 9) # Remove .kaoskaki
            
            Write-Host "Decrypting: $($file.Name) -> $(Split-Path $originalPath -Leaf)"
            
            $encryptedContent = [System.IO.File]::ReadAllBytes($file.FullName)
            
            # Decrypt by applying the exact same XOR operation (XOR is reversible)
            $decryptedContent = $encryptedContent | ForEach-Object { $_ -bxor 0xAB }
            
            [System.IO.File]::WriteAllBytes($originalPath, $decryptedContent)
            Remove-Item $file.FullName -Force
            
            $count++
        }
        catch {
            Write-Host "[!] Failed to decrypt: $($file.FullName) - Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host "=========================================" -ForegroundColor Green
    Write-Host "   DECRYPTION COMPLETE!" -ForegroundColor Green
    Write-Host "   Successfully restored $count files." -ForegroundColor Green
    Write-Host "=========================================" -ForegroundColor Green
}

Invoke-Decrypt
