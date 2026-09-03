#!/bin/bash

# ============================================================
# CSA Phishing Awareness Demo — AWS x86_64 Setup
# Ubuntu 22.04/24.04 | Node 20 | Nginx | Certbot | PM2
#
# Target: AWS EC2 instances (x86_64) — t3.micro or larger
#
# Run as: sudo bash setup.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

if [ "$EUID" -ne 0 ]; then
  fail "Please run as root: sudo bash setup.sh"
fi

# Resolve the real user who invoked sudo (for npm/pm2 ownership)
REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
  # Running as root directly — npm install will run as root (fine for server use)
  REAL_USER="root"
  warn "No SUDO_USER detected — npm install will run as root."
fi

APP_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  CSA Phishing Awareness Demo — AWS x86_64 Server Setup  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""


# ── Pre-flight: System diagnostics ─────────────────────────
info "Running pre-flight checks..."
echo ""
PREFLIGHT_OK=true

# 1. Architecture
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
  log "Architecture: $ARCH (x86_64 OK)"
elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
  warn "Architecture: $ARCH — this script targets x86_64. Some steps may behave differently."
else
  warn "Architecture: $ARCH — untested. Some steps may behave differently."
fi

# 2. OS
OS_ID=$(. /etc/os-release && echo "$ID $VERSION_ID")
log "OS: $OS_ID"
if [[ "$OS_ID" != *"ubuntu"* ]]; then
  warn "Not Ubuntu — apt-get steps may fail on this distro."
fi

# 3. RAM
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
AVAIL_RAM_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
AVAIL_RAM_MB=$((AVAIL_RAM_KB / 1024))
if [ "$AVAIL_RAM_MB" -lt 400 ]; then
  warn "RAM: ${AVAIL_RAM_MB}MB available / ${TOTAL_RAM_MB}MB total — CRITICALLY LOW. npm WILL OOM."
  warn "  Stop other processes or reboot before continuing."
  PREFLIGHT_OK=false
elif [ "$AVAIL_RAM_MB" -lt 900 ]; then
  warn "RAM: ${AVAIL_RAM_MB}MB available / ${TOTAL_RAM_MB}MB total — low, swap will be needed."
else
  log "RAM: ${AVAIL_RAM_MB}MB available / ${TOTAL_RAM_MB}MB total (OK)"
fi

# 4. Swap
SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
SWAP_MB=$((SWAP_KB / 1024))
if [ "$SWAP_MB" -gt 0 ]; then
  log "Swap: ${SWAP_MB}MB already active"
else
  warn "Swap: not yet active (will be created in Step 3)"
fi

# 5. Disk space
DISK_AVAIL_KB=$(df --output=avail / | tail -1)
DISK_AVAIL_MB=$((DISK_AVAIL_KB / 1024))
if [ "$DISK_AVAIL_MB" -lt 1024 ]; then
  warn "Disk: only ${DISK_AVAIL_MB}MB free — need at least 1GB. Swap file creation may also fail."
  PREFLIGHT_OK=false
elif [ "$DISK_AVAIL_MB" -lt 2048 ]; then
  warn "Disk: ${DISK_AVAIL_MB}MB free — tight. Swap file may fail if under 2GB."
else
  log "Disk: ${DISK_AVAIL_MB}MB free on / (OK)"
fi

# 6. CPU cores
CPU_CORES=$(nproc)
log "CPU cores: $CPU_CORES"
if [ "$CPU_CORES" -lt 2 ]; then
  warn "Only 1 CPU core — builds will be slow."
fi

# 7. Outbound internet (npm registry)
if curl -sf --max-time 8 https://registry.npmjs.org/ > /dev/null 2>&1; then
  log "Internet: npm registry reachable (OK)"
else
  warn "Internet: cannot reach registry.npmjs.org"
  warn "  Check your AWS Security Group allows outbound TCP 443."
  PREFLIGHT_OK=false
fi

# 8. OOM history since last boot
OOM_COUNT=$(dmesg 2>/dev/null | grep -c "Out of memory\|Killed process" 2>/dev/null)
OOM_COUNT="${OOM_COUNT//[^0-9]/}"  # strip any non-numeric chars (e.g. newlines, spaces)
OOM_COUNT="${OOM_COUNT:-0}"
if [ "$OOM_COUNT" -gt 0 ]; then
  warn "OOM kills in dmesg since last boot: $OOM_COUNT event(s)"
  warn "  This confirms previous npm runs were killed silently."
  warn "  The swap + NODE_OPTIONS heap cap in this script will address it."
else
  log "OOM history: none since last boot (clean)"
fi

# 9. Port conflicts
for PORT in 80 443; do
  if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
    PROC=$(ss -tlnp | grep ":${PORT} " | awk '{print $NF}' | head -1)
    if echo "$PROC" | grep -q "nginx"; then
      log "Port ${PORT}: nginx already running (will be reconfigured — OK)"
    else
      warn "Port ${PORT} bound by a non-nginx process: ${PROC}"
      warn "  This may block Nginx from starting. Stop that process first."
      PREFLIGHT_OK=false
    fi
  else
    log "Port ${PORT}: free"
  fi
done

# 10. Partial node_modules from a previous failed install
if [ -d "${APP_DIR}/node_modules" ]; then
  MOD_COUNT=$(find "${APP_DIR}/node_modules" -maxdepth 1 -mindepth 1 -type d | wc -l)
  warn "node_modules already exists with ${MOD_COUNT} packages — likely a partial failed install."
  read -rp "  Delete and reinstall clean? Strongly recommended [Y/n]: " DEL_MODS
  if [[ "${DEL_MODS,,}" != "n" ]]; then
    rm -rf "${APP_DIR}/node_modules"
    log "node_modules removed — will do a clean install."
  else
    warn "Keeping existing node_modules. If npm install fails, delete it manually and re-run."
  fi
else
  log "node_modules: not present (fresh install)"
fi

echo ""
if [ "$PREFLIGHT_OK" = true ]; then
  log "Pre-flight complete — no blocking issues found."
else
  echo -e "\033[0;31m[!] One or more blocking issues detected above.\033[0m"
  read -rp "  Continue anyway? [y/N]: " CONTINUE_ANYWAY
  [[ "${CONTINUE_ANYWAY,,}" != "y" ]] && { echo "Aborted."; exit 1; }
fi
echo ""

# ── Step 1: Collect configuration ──────────────────────────
info "Collecting configuration..."
echo ""
read -rp "  Domain name (e.g. csatraining.mooo.com): " DOMAIN
read -rp "  Email for SSL cert (leave blank to skip): " SSL_EMAIL
read -rp "  Relay WebSocket port [8765]: " WS_PORT
WS_PORT="${WS_PORT:-8765}"
read -rp "  Static file server port [8080] (unused — relay serves static): " STATIC_PORT
STATIC_PORT="${STATIC_PORT:-8080}"

# Validate required fields
[ -z "$DOMAIN" ] && fail "Domain name is required."

echo ""
log "Configuration collected."
echo ""

# ── Step 2: Relay.js existence check ───────────────────────
if [ ! -f "${APP_DIR}/relay.js" ]; then
  warn "relay.js not found in ${APP_DIR}."
  warn "PM2 will be configured but the process won't start until relay.js exists."
  warn "Copy relay.js into ${APP_DIR} then run: pm2 start ${APP_DIR}/ecosystem.config.js"
fi

# ── Step 3: Swap file ──────────────────────────────────────
info "Setting up 2GB swap file..."
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile 2>/dev/null \
    || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress 2>&1
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  log "2GB swap file created and activated."
else
  warn "Swap file already exists — skipping."
fi

# ── Step 4: System update ───────────────────────────────────
info "Updating system packages..."
apt-get update -q && apt-get upgrade -y -q 2>&1 | tail -3
log "System updated."

# ── Step 5: System dependencies ────────────────────────────
info "Installing system dependencies..."
# DEBIAN_FRONTEND=noninteractive is REQUIRED — iptables-persistent pops a
# debconf prompt ("Save IPv4 rules?") that otherwise hangs the step with no TTY.
export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v4 boolean true"
debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v6 boolean true"

apt-get install -y \
  curl git nginx certbot python3-certbot-nginx \
  build-essential ca-certificates gnupg lsb-release \
  netfilter-persistent iptables-persistent python3 2>&1 | tail -5
unset DEBIAN_FRONTEND
log "System dependencies installed."

# ── Step 6: Node.js 20 ─────────────────────────────────────
info "Installing Node.js 20 via NodeSource..."
CURRENT_NODE_VER=$(node -v 2>/dev/null || echo "none")
if [[ "$CURRENT_NODE_VER" == v20* ]]; then
  log "Node.js $CURRENT_NODE_VER already installed (NodeSource OK)."
else
  # Remove any apt-managed nodejs first — it shadows the NodeSource install
  # and is almost always an older version (v18 on Ubuntu 24.04)
  if command -v node &>/dev/null; then
    warn "Found Node $CURRENT_NODE_VER (not v20) — removing apt version before NodeSource install..."
    DEBIAN_FRONTEND=noninteractive apt-get remove -y nodejs npm 2>&1 | tail -2
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>&1 | tail -2
    rm -f /etc/apt/sources.list.d/nodesource.list
    log "Old Node removed."
  fi
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>&1 | tail -3
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs 2>&1 | tail -3
  INSTALLED_VER=$(node -v 2>/dev/null || echo "unknown")
  if [[ "$INSTALLED_VER" != v20* ]]; then
    fail "Node.js install failed — got $INSTALLED_VER, expected v20.x. Check NodeSource connectivity."
  fi
  log "Node.js $INSTALLED_VER installed."
fi

# ── Step 7: PM2 ────────────────────────────────────────────
info "Installing PM2 globally (this downloads + links PM2)..."
if npm install -g pm2 > /tmp/pm2-install.log 2>&1; then
  log "PM2 $(pm2 -v) installed."
else
  echo -e "${RED}[✗] PM2 install failed — last output:${NC}"
  tail -15 /tmp/pm2-install.log
  fail "npm install -g pm2 failed. See /tmp/pm2-install.log for details."
fi

# ── Step 8: Project npm install ────────────────────────────
info "Installing project dependencies..."
cd "${APP_DIR}" || fail "Cannot cd to ${APP_DIR}"

# Confirm swap is active before npm
SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
if [ "${SWAP_KB:-0}" -lt 1000000 ]; then
  warn "Swap does not appear active (${SWAP_KB}kB). npm install may OOM on low-RAM instances."
  warn "If it hangs or dies, reboot and re-run the script — swap persists via /etc/fstab."
else
  log "Swap confirmed active: $((SWAP_KB / 1024))MB"
fi

# better-sqlite3 is a native module and MUST run its install script (builds the
# binding against node-gyp). Removing --ignore-scripts is required or the relay
# will crash at startup with 'Cannot find module .../build/Release/better_sqlite3.node'.
#
# Progress visibility: full npm output goes to a rotating install log AND the
# last few lines are live-tailed so you can see what stage it's in rather than
# staring at a blank screen while better-sqlite3 compiles.
INSTALL_LOG="${APP_DIR}/.npm-install.log"
: > "$INSTALL_LOG"

echo -e "${YELLOW}  ↳ npm install — this can take 1–3 min on a t3.small."
echo -e "  ↳ 'prebuild-install' → 'node-gyp rebuild' lines mean better-sqlite3 is"
echo -e "    compiling its native binding. A long pause here is normal."
echo -e "  ↳ Full log: $INSTALL_LOG (tail it in another shell if unsure)${NC}"

if [ "$REAL_USER" = "root" ]; then
  NODE_OPTIONS="--max-old-space-size=1024" npm install \
    --unsafe-perm --omit=dev --prefer-offline --no-audit --no-fund \
    >> "$INSTALL_LOG" 2>&1 &
else
  sudo -u "${REAL_USER}" \
    env NODE_OPTIONS="--max-old-space-size=1024" \
    npm install --omit=dev --prefer-offline --no-audit --no-fund \
    >> "$INSTALL_LOG" 2>&1 &
fi
NPM_PID=$!

# Live-tails npm so the user isn't left wondering if it's stuck
while kill -0 "$NPM_PID" 2>/dev/null; do
  tail -n 3 "$INSTALL_LOG" 2>/dev/null | sed 's/^/    /'
  sleep 2
done
wait "$NPM_PID"
NPM_EXIT=$?

# Detect stage keywords in the log to explain what actually happened
if grep -qi "prebuild-install\|node-gyp rebuild\|gyp ERR\|CXX(" "$INSTALL_LOG"; then
  echo -e "${YELLOW}  ↳ Native module (better-sqlite3) build detected in output above.${NC}"
fi

# Catch silent OOM kill (npm exits non-zero but prints nothing)
if [ "$NPM_EXIT" -ne 0 ]; then
  echo -e "${RED}[✗] npm install failed — last 15 lines:${NC}"
  tail -15 "$INSTALL_LOG"
  fail "npm install failed. Check dmesg for OOM kills: sudo dmesg | grep -i 'killed process' (full log: $INSTALL_LOG)"
fi
rm -f "$INSTALL_LOG"
log "Dependencies installed."

# ── Step 9: Patch WS_URL in phish.html and instructor.html ──
info "Patching WS_URL to wss://${DOMAIN}/ws..."
# Single-pass: replace any ws:// or wss:// URL with the correct one
for f in "${APP_DIR}/phish.html" "${APP_DIR}/instructor.html"; do
  if [ -f "$f" ]; then
    sed -i "s|const WS_URL = .*|const WS_URL = 'wss://${DOMAIN}/ws';|g" "$f"
    log "Patched: $f"
  else
    warn "Not found (skipping): $f"
  fi
done

# ── Step 10: PM2 ecosystem config ───────────────────────────
info "Creating PM2 ecosystem config..."
mkdir -p /var/log/csa-phishing

cat > "${APP_DIR}/ecosystem.config.js" << ECOF
module.exports = {
  apps: [{
    name: 'csa-relay',
    script: '${APP_DIR}/relay.js',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '800M',
    env: {
      NODE_ENV: 'production',
      PORT: ${WS_PORT}
    },
    error_file: '/var/log/csa-phishing/error.log',
    out_file:   '/var/log/csa-phishing/out.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss'
  }]
};
ECOF

pm2 delete csa-relay 2>/dev/null || true

if [ -f "${APP_DIR}/relay.js" ]; then
  pm2 start "${APP_DIR}/ecosystem.config.js"
  pm2 save
  log "PM2 relay started."
else
  warn "Skipping PM2 start — relay.js not found. Run 'pm2 start ${APP_DIR}/ecosystem.config.js' after copying relay.js."
fi

# PM2 startup — run directly (more reliable than grep+eval on Ubuntu 24.04)
pm2 startup systemd -u root --hp /root 2>&1 | grep -v "^\[PM2\]" | tail -3
systemctl enable pm2-root 2>/dev/null || true
log "PM2 configured for reboot survival."

# ── Step 11: Nginx config ───────────────────────────────────
info "Configuring Nginx for ${DOMAIN}..."

cat > /etc/nginx/sites-available/csa-phishing << NGXEOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${APP_DIR};
    index phish.html;
    client_max_body_size 10M;

    location / {
        try_files \$uri \$uri/ /phish.html;
    }

    location /ws {
        proxy_pass http://127.0.0.1:${WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGXEOF

ln -sf /etc/nginx/sites-available/csa-phishing /etc/nginx/sites-enabled/csa-phishing
rm -f /etc/nginx/sites-enabled/default  # Remove default site to avoid conflicts

nginx -t || fail "Nginx config test failed — check /etc/nginx/sites-available/csa-phishing"
systemctl enable nginx
systemctl reload nginx
log "Nginx configured."

# ── Step 12: iptables firewall ─────────────────────────────
info "Opening ports 80 and 443 via iptables..."

iptables -C INPUT -m state --state NEW -p tcp --dport 80 -j ACCEPT 2>/dev/null \
  || iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT

iptables -C INPUT -m state --state NEW -p tcp --dport 443 -j ACCEPT 2>/dev/null \
  || iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT

# Block direct access to relay port — all traffic must go through Nginx
iptables -C INPUT -m state --state NEW -p tcp --dport "${WS_PORT}" -j DROP 2>/dev/null \
  || iptables -I INPUT 6 -m state --state NEW -p tcp --dport "${WS_PORT}" -j DROP

netfilter-persistent save
log "iptables rules saved."

# ── Step 13: SSL via Certbot ────────────────────────────────
echo ""
if [[ "${DOMAIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  warn "IP address provided — Certbot requires a real domain name."
  warn "After DNS propagates run: sudo certbot --nginx -d ${DOMAIN}"
else
  info "Requesting SSL certificate for ${DOMAIN}..."

  CERTBOT_FLAGS=(--nginx -d "${DOMAIN}" --non-interactive --agree-tos --redirect)

  if [ -n "$SSL_EMAIL" ]; then
    CERTBOT_FLAGS+=(--email "${SSL_EMAIL}")
  else
    # --register-unsafely-without-email was removed in Certbot 2.x
    # Try it; if it fails, prompt user to re-run with an email
    CERTBOT_FLAGS+=(--register-unsafely-without-email)
    warn "No email provided. If Certbot fails, re-run with an email address."
  fi

  if certbot "${CERTBOT_FLAGS[@]}"; then
    log "SSL certificate issued."
    # Add automatic renewal cron if not already present
    (crontab -l 2>/dev/null | grep -q "certbot renew") \
      || (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") \
      | crontab -
    log "Certbot auto-renewal cron added."
  else
    warn "Certbot failed. Run manually: sudo certbot --nginx -d ${DOMAIN} --email you@example.com"
  fi
fi

# ── Summary ─────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              Setup Complete!                             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo -e "  ${GREEN}Phishing page:${NC}    https://${DOMAIN}"
echo -e "  ${GREEN}Instructor panel:${NC} Open instructor.html in your browser"
echo -e "  ${GREEN}Relay (PM2):${NC}      pm2 status"
echo -e "  ${GREEN}App dir:${NC}          ${APP_DIR}"
echo -e "  ${GREEN}Logs:${NC}             /var/log/csa-phishing/"
echo ""
echo -e "  ${YELLOW}Useful commands:${NC}"
echo "    pm2 status               — relay process status"
echo "    pm2 logs csa-relay       — live relay logs"
echo "    pm2 restart csa-relay    — restart relay"
echo "    sudo certbot renew       — renew SSL cert manually"
echo ""
echo -e "  ${RED}AWS EC2 Console → Security Groups:${NC}"
echo "    Add Inbound Rule: TCP port 80  from 0.0.0.0/0"
echo "    Add Inbound Rule: TCP port 443 from 0.0.0.0/0"
echo ""
echo -e "  ${YELLOW}Before running a session:${NC}"
echo "    1. Edit relay.js → update INSTRUCTOR_TOKENS"
echo "    2. Open https://${DOMAIN} to verify the phishing page loads"
echo "    3. Open instructor.html locally to monitor"
echo ""
