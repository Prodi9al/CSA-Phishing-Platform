# launch.ps1 — CSA Phishing Awareness Demo · Windows Launch Script
# ─────────────────────────────────────────────────────────────────────
# This script starts the unified relay server (WS + Static HTML)
# and a single Cloudflare tunnel to handle everything on Windows.
# ─────────────────────────────────────────────────────────────────────

$ErrorActionPreference = "Stop"

# Colors for output
$Green = "Green"
$Yellow = "Yellow"
$Cyan = "Cyan"
$Red = "Red"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectDir = Split-Path -Parent $ScriptDir
$LogDir = Join-Path $ScriptDir ".launch-logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

$RelayLog = Join-Path $LogDir "relay.log"
$CfLog = Join-Path $LogDir "cf.log"
$RelayFile = Join-Path $ProjectDir "relay.js"

# Function to clean up on exit
function Cleanup {
    Write-Host ""
    Write-Host "Shutting down services..." -ForegroundColor $Yellow
    if ($RelayJob) { Stop-Job $RelayJob; Remove-Job $RelayJob }
    if ($CfJob) { Stop-Job $CfJob; Remove-Job $CfJob }
    Write-Host "All processes stopped." -ForegroundColor $Green
    exit
}

# Trap Ctrl+C
$Host.UI.RawUI.FlushInputBuffer()
# In PowerShell, we can use a try/finally block or Register-ObjectEvent for clean termination
# But for simplicity in a script, we'll use a while(true) loop and wait for input or Ctrl+C.

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor $Cyan
Write-Host "║  CSA Phishing Awareness — Windows Unified Deployment      ║" -ForegroundColor $Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor $Cyan

# 1. Start unified relay.js
Write-Host "➜ Starting Unified Relay (Port 8765)..." -ForegroundColor $Yellow
$RelayJob = Start-Job -ScriptBlock {
    param($ProjectDir, $RelayFile, $Log)
    Set-Location $ProjectDir
    node $RelayFile > $Log 2>&1
} -ArgumentList $ProjectDir, $RelayFile, $RelayLog

Start-Sleep -Seconds 2

# 2. Start single tunnel
Write-Host "➜ Opening Unified Tunnel (handling WS + HTML)..." -ForegroundColor $Yellow
$CfJob = Start-Job -ScriptBlock {
    param($Log)
    cloudflared tunnel --url http://localhost:8765 --no-autoupdate > $Log 2>&1
} -ArgumentList $CfLog

# 3. Wait for URL
Write-Host "➜ Waiting for Cloudflare URL..." -ForegroundColor $Yellow
$Attempts = 0
$TunnelUrl = $null

while (-not $TunnelUrl -and $Attempts -lt 30) {
    if (Test-Path $CfLog) {
        $Content = Get-Content $CfLog
        if ($Content -match 'https://[a-zA-Z0-9\-]+\.trycloudflare\.com') {
            $TunnelUrl = $Matches[0]
        }
    }
    Start-Sleep -Seconds 1
    $Attempts++
}

if (-not $TunnelUrl) {
    Write-Host "✗ Could not get tunnel URL. Check $CfLog" -ForegroundColor $Red
    Cleanup
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor $Green
Write-Host "║  DEPLOYMENT SUCCESSFUL                                       ║" -ForegroundColor $Green
Write-Host "╠══════════════════════════════════════════════════════════════╣"
Write-Host "║                                                              ║"
Write-Host "║  1. VICTIM LINK (Share this):                                ║" -ForegroundColor $Cyan
Write-Host "║  $TunnelUrl/phish                                       ║" -ForegroundColor $Green
Write-Host "║                                                              ║"
Write-Host "║  2. INSTRUCTOR DASHBOARD:                                   ║" -ForegroundColor $Cyan
Write-Host "║  $TunnelUrl/instructor                                  ║" -ForegroundColor $Green
Write-Host "║                                                              ║"
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor $Green
Write-Host ""
Write-Host "Press Ctrl+C or close this window to stop services."

try {
    while ($true) {
        if ($RelayJob.State -ne "Running" -or $CfJob.State -ne "Running") {
            Write-Host "Warning: One of the background processes has stopped." -ForegroundColor $Red
            break
        }
        Start-Sleep -Seconds 2
    }
} finally {
    Cleanup
}
