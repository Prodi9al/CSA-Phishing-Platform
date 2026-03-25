# update.ps1 — CSA Phishing Platform Updater (Windows)

Write-Host "=== CSA Phishing Platform — Updating ===" -ForegroundColor Cyan

# 1. Pull latest code
if (Test-Path .git) {
    Write-Host "[+] Pulling latest changes from GitHub..." -ForegroundColor Yellow
    git pull origin master
} else {
    Write-Host "[!] Not a git repository. Skip pull." -ForegroundColor Red
}

# 2. Update dependencies
Write-Host "[+] Updating dependencies (npm install)..." -ForegroundColor Yellow
npm install

Write-Host "✅ Update complete! Run node relay.js to start." -ForegroundColor Green
