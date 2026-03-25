$ErrorActionPreference = "Stop"

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  CSA Phishing Awareness Demo - Windows Setup" -ForegroundColor Cyan
Write-Host "==========================================================`n" -ForegroundColor Cyan

# 1. Check Node.js
try {
    $nodeVer = (node -v 2>&1)
    Write-Host "[OK] Node.js is installed ($nodeVer)" -ForegroundColor Green
} catch {
    Write-Host "[X] Node.js is NOT installed." -ForegroundColor Red
    Write-Host "    Download it from: https://nodejs.org"
    Write-Host "    Install it, restart your terminal, and run .\setup.ps1 again.`n"
    exit
}

# 2. Check Cloudflared
try {
    $cfVer = (cloudflared --version 2>&1)
    Write-Host "[OK] Cloudflared is installed" -ForegroundColor Green
} catch {
    Write-Host "[!] Cloudflared is NOT installed." -ForegroundColor Yellow
    Write-Host "    Attempting to install via winget... Please wait..."
    try {
        winget install --id Cloudflare.cloudflared -e --accept-package-agreements --accept-source-agreements
        Write-Host "[OK] Cloudflared installed successfully." -ForegroundColor Green
    } catch {
        Write-Host "[X] Failed to install Cloudflared automatically." -ForegroundColor Red
        Write-Host "    Please download it manually from: https://github.com/cloudflare/cloudflared/releases"
    }
}

# 3. NPM Install
Write-Host "`n[ ] Installing dependencies (ws, better-sqlite3)..." -ForegroundColor Yellow
npm install
Write-Host "[OK] Dependencies installed successfully.`n" -ForegroundColor Green

# 4. Next Steps
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Setup complete! Next Steps:"
Write-Host " 1. Edit relay.js to change INSTRUCTOR_TOKENS if deploying live."
Write-Host " 2. Start the relay:            node relay.js"
Write-Host " 3. Serve the phish page:       python -m http.server 8080"
Write-Host " 4. Open instructor.html directly in a browser to monitor."
Write-Host " 5. Port forward for victims (requires HTTPS):"
Write-Host "    Terminal A: cloudflared tunnel --url http://127.0.0.1:8080"
Write-Host "    Terminal B: cloudflared tunnel --url http://127.0.0.1:8765"
Write-Host "==========================================================`n" -ForegroundColor Cyan
