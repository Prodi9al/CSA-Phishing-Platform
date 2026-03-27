#!/usr/bin/env bash
# launch.sh — CSA Phishing Awareness Demo · Unified One-shot Launch
# ─────────────────────────────────────────────────────────────────────
# This script starts the unified relay server (WS + Static HTML)
# and a single Cloudflare tunnel to handle everything.
# ─────────────────────────────────────────────────────────────────────

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/.launch-logs"
mkdir -p "$LOG_DIR"

RELAY_LOG="$LOG_DIR/relay.log"
CF_LOG="$LOG_DIR/cf.log"

cleanup() {
  echo ""
  echo -e "${YELLOW}Shutting down services...${NC}"
  kill "$RELAY_PID" 2>/dev/null || true
  kill "$CF_PID" 2>/dev/null || true
  echo -e "${GREEN}All processes stopped.${NC}"
  exit 0
}
trap cleanup SIGINT SIGTERM

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  CSA Phishing Awareness — Unified Deployment             ║"
echo "╚══════════════════════════════════════════════════════════╝"

# 1. Start unified relay.js
echo -e "${YELLOW}➜ Starting Unified Relay (Port 8765)...${NC}"
node "$SCRIPT_DIR/relay.js" > "$RELAY_LOG" 2>&1 &
RELAY_PID=$!
sleep 2

# 2. Start single tunnel
echo -e "${YELLOW}➜ Opening Unified Tunnel (handling WS + HTML)...${NC}"
cloudflared tunnel --url http://localhost:8765 --no-autoupdate > "$CF_LOG" 2>&1 &
CF_PID=$!

# 3. Wait for URL
echo -e "${YELLOW}➜ Waiting for Cloudflare URL...${NC}"
attempts=0
TUNNEL_URL=""
while [ -z "$TUNNEL_URL" ] && [ $attempts -lt 30 ]; do
  # Extract URL correctly across different grep versions
  TUNNEL_URL=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$CF_LOG" 2>/dev/null | head -1)
  sleep 1
  attempts=$((attempts + 1))
done

if [ -z "$TUNNEL_URL" ]; then
  echo -e "${RED}✗ Could not get tunnel URL. Check $CF_LOG${NC}"
  cleanup
fi

echo ""
echo -e "╔══════════════════════════════════════════════════════════════╗"
echo -e "║  ${GREEN}DEPLOYMENT SUCCESSFUL${NC}                                       ║"
echo -e "╠══════════════════════════════════════════════════════════════╣"
echo -e "║                                                              ║"
echo -e "║  ${CYAN}1. VICTIM LINK (Share this):${NC}                                ║"
echo -e "║  ${GREEN}${TUNNEL_URL}/phish${NC}                                       ║"
echo -e "║                                                              ║"
echo -e "║  ${CYAN}2. INSTRUCTOR DASHBOARD:${NC}                                   ║"
echo -e "║  ${GREEN}${TUNNEL_URL}/instructor${NC}                                  ║"
echo -e "║                                                              ║"
echo -e "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Press Ctrl+C to stop services."
wait
