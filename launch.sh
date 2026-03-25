#!/usr/bin/env bash
# launch.sh — CSA Phishing Awareness Demo · One-shot Launch
# ──────────────────────────────────────────────────────────
# Usage:
#   chmod +x launch.sh
#   ./launch.sh
#
# What it does:
#   1. Starts relay.js (WebSocket server on :8765)
#   2. Starts python3 HTTP server (phish page on :8080)
#   3. Opens two cloudflared tunnels and captures URLs
#   4. Patches WS_URL in phish.html and instructor.html
#   5. Prints the final share link and opens instructor.html
#
# Press Ctrl+C to shut everything down cleanly.

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
HTTP_LOG="$LOG_DIR/http.log"
CF_HTTP_LOG="$LOG_DIR/cf-http.log"
CF_WS_LOG="$LOG_DIR/cf-ws.log"

# ── Cleanup on exit ───────────────────────────────────────
cleanup() {
  echo ""
  echo -e "${YELLOW}Shutting down...${NC}"
  kill "$RELAY_PID"   2>/dev/null || true
  kill "$HTTP_PID"    2>/dev/null || true
  kill "$CF_HTTP_PID" 2>/dev/null || true
  kill "$CF_WS_PID"   2>/dev/null || true
  echo -e "${GREEN}All processes stopped.${NC}"
  exit 0
}
trap cleanup SIGINT SIGTERM

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  CSA Phishing Awareness Demo — Launch                    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Start relay.js ─────────────────────────────────────
echo -e "${YELLOW}➜ Starting relay server (ws://localhost:8765)...${NC}"
node "$SCRIPT_DIR/relay.js" > "$RELAY_LOG" 2>&1 &
RELAY_PID=$!
sleep 2
if ! kill -0 "$RELAY_PID" 2>/dev/null; then
  echo -e "${RED}✗ relay.js failed to start. Check $RELAY_LOG${NC}"
  exit 1
fi
echo -e "${GREEN}✓ relay.js running (PID $RELAY_PID)${NC}"

# ── 2. Start HTTP server ──────────────────────────────────
echo -e "${YELLOW}➜ Starting HTTP server (http://localhost:8080)...${NC}"
python3 -m http.server 8080 --directory "$SCRIPT_DIR" > "$HTTP_LOG" 2>&1 &
HTTP_PID=$!
sleep 1
echo -e "${GREEN}✓ HTTP server running (PID $HTTP_PID)${NC}"

# ── 3. Start cloudflared tunnel for HTTP (phish page) ─────
echo -e "${YELLOW}➜ Opening tunnel for phish page (:8080)...${NC}"
cloudflared tunnel --url http://localhost:8080 --no-autoupdate > "$CF_HTTP_LOG" 2>&1 &
CF_HTTP_PID=$!

# ── 4. Start cloudflared tunnel for WebSocket ─────────────
echo -e "${YELLOW}➜ Opening tunnel for WebSocket relay (:8765)...${NC}"
cloudflared tunnel --url http://localhost:8765 --no-autoupdate > "$CF_WS_LOG" 2>&1 &
CF_WS_PID=$!

# ── 5. Wait for tunnel URLs to appear in logs ─────────────
echo -e "${YELLOW}➜ Waiting for tunnel URLs...${NC}"

extract_url() {
  local logfile="$1"
  local url=""
  local attempts=0
  while [ -z "$url" ] && [ $attempts -lt 30 ]; do
    url=$(grep -oP 'https://[a-zA-Z0-9\-]+\.trycloudflare\.com' "$logfile" 2>/dev/null | head -1)
    sleep 1
    attempts=$((attempts + 1))
  done
  echo "$url"
}

HTTP_URL=$(extract_url "$CF_HTTP_LOG")
WS_URL=$(extract_url "$CF_WS_LOG")

if [ -z "$HTTP_URL" ] || [ -z "$WS_URL" ]; then
  echo -e "${RED}✗ Could not get tunnel URLs. Check $CF_HTTP_LOG and $CF_WS_LOG${NC}"
  cleanup
  exit 1
fi

echo -e "${GREEN}✓ Phish page tunnel : $HTTP_URL${NC}"
echo -e "${GREEN}✓ WebSocket tunnel  : $WS_URL${NC}"

# ── 6. Patch WS_URL in phish.html and instructor.html ─────
echo -e "${YELLOW}➜ Patching WS_URL in HTML files...${NC}"

patch_ws_url() {
  local file="$1"
  local new_url="$2"
  # Replace any existing ws:// or wss:// WS_URL assignment
  sed -i "s|const WS_URL = '[^']*'|const WS_URL = 'wss://${new_url#https://}'|g" "$file"
}

patch_ws_url "$SCRIPT_DIR/phish.html"      "$WS_URL"
patch_ws_url "$SCRIPT_DIR/instructor.html" "$WS_URL"

echo -e "${GREEN}✓ WS_URL patched in both HTML files${NC}"

# ── 7. Print summary ──────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Everything is live!                                         ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                              ║"
echo -e "║  ${CYAN}Share this link with participants:${NC}                        ║"
echo -e "║  ${GREEN}$HTTP_URL/phish.html${NC}"
echo "║                                                              ║"
echo -e "║  ${CYAN}Open your instructor dashboard:${NC}                           ║"
echo -e "║  ${GREEN}$SCRIPT_DIR/instructor.html${NC}"
echo "║                                                              ║"
echo "║  Press Ctrl+C to stop everything.                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── 8. Open instructor dashboard ──────────────────────────
if command -v xdg-open &>/dev/null; then
  xdg-open "$SCRIPT_DIR/instructor.html" 2>/dev/null || true
fi

# ── Keep alive ────────────────────────────────────────────
wait
