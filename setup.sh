#!/bin/bash

# ============================================================
# CSA Phishing Awareness Demo — Oracle Always Free ARM Setup
# Ubuntu 24.04 | Node 18+ | Nginx | Certbot | Cloudflared
#
# What it does:
#   1. Installs Node.js 20 via NodeSource (not outdated apt version)
#   2. Installs cloudflared for the correct architecture (arm64/amd64)
#   3. Configures Nginx reverse proxy with WebSocket support
#   4. Obtains SSL certificate via Certbot
#   5. Runs npm install for project dependencies
#   6. Opens ports 80 and 443 via iptables (Oracle-specific — no UFW)
#   7. Sets up PM2 for relay.js process management
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
REAL_USER="${SUDO_USER:-ubuntu}"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   CSA Phishing Awareness Demo — Oracle ARM Server Setup  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Collect configuration ──────────────────────────
info "Collecting configuration..."
echo ""
read -p "  Domain name (e.g. csatraining.mooo.com): " DOMAIN
read -p "  Relay WebSocket port [8765]: " WS_PORT
WS_PORT=${WS_PORT:-8765}
read -p "  Static file server port [8080]: " STATIC_PORT
STATIC_PORT=${STATIC_PORT:-8080}
read -p "  Your email for Certbot SSL [leave blank to skip]: " SSL_EMAIL

echo ""
log "Configuration collected."
echo ""

# ── Step 2: Swap file (CRITICAL on Oracle ARM) ──────────────
info "Setting up 2GB swap file (required for npm builds on ARM)..."
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  log "2GB swap file created and activated."
else
  warn "Swap file already exists, skipping."
fi

# ── Step 3: System update ───────────────────────────────────
info "Updating system packages..."
apt-get update -q && apt-get upgrade -y -q
log "System updated."

# ── Step 4: System dependencies ────────────────────────────
info "Installing system dependencies..."
apt-get install -y \
  curl git nginx certbot python3-certbot-nginx \
  build-essential ca-certificates gnupg lsb-release \
  netfilter-persistent iptables-persistent python3 2>&1 | tail -5
log "System dependencies installed."

# ── Step 5: Node.js 20 ─────────────────────────────────────
info "Installing Node.js 20 via NodeSource..."
if ! command -v node &>/dev/null || [[ "$(node -v)" != v20* ]]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
  log "Node.js $(node -v) installed."
else
  log "Node.js $(node -v) already installed."
fi

# ── Step 6: PM2 ────────────────────────────────────────────
info "Installing PM2 globally..."
npm install -g pm2 --quiet
log "PM2 $(pm2 -v) installed."

# ── Step 7: Cloudflared (architecture-aware) ───────────────
info "Installing cloudflared..."
if ! command -v cloudflared &>/dev/null; then
  ARCH=$(dpkg --print-architecture)
  curl -L -o /tmp/cloudflared.deb \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
  dpkg -i /tmp/cloudflared.deb
  rm /tmp/cloudflared.deb
  log "cloudflared $(cloudflared --version 2>&1 | head -1) installed."
else
  log "cloudflared already installed."
fi

# ── Step 8: Project npm install ────────────────────────────
info "Installing project dependencies..."
cd "${APP_DIR}"
sudo -u "${REAL_USER}" npm install
log "Dependencies installed."

# ── Step 9: Update WS_URL in phish.html and instructor.html ─
info "Patching WS_URL to wss://${DOMAIN}/ws..."
sed -i "s|ws://[^'\"]*|wss://${DOMAIN}/ws|g" "${APP_DIR}/phish.html" 2>/dev/null || true
sed -i "s|ws://[^'\"]*|wss://${DOMAIN}/ws|g" "${APP_DIR}/instructor.html" 2>/dev/null || true
sed -i "s|wss://[^'\"]*|wss://${DOMAIN}/ws|g" "${APP_DIR}/phish.html" 2>/dev/null || true
sed -i "s|wss://[^'\"]*|wss://${DOMAIN}/ws|g" "${APP_DIR}/instructor.html" 2>/dev/null || true
log "WS_URL patched in phish.html and instructor.html."

# ── Step 10: PM2 ecosystem config ──────────────────────────
info "Creating PM2 ecosystem config..."
cat > "${APP_DIR}/ecosystem.config.js" << ECOF
module.exports = {
  apps: [{
    name: 'csa-relay',
    script: '${APP_DIR}/relay.js',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '512M',
    env: {
      NODE_ENV: 'production',
      PORT: ${WS_PORT}
    },
    error_file: '/var/log/csa-phishing/error.log',
    out_file: '/var/log/csa-phishing/out.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss'
  }]
};
ECOF

mkdir -p /var/log/csa-phishing
pm2 delete csa-relay 2>/dev/null || true
pm2 start "${APP_DIR}/ecosystem.config.js"
pm2 save

PM2_STARTUP=$(pm2 startup systemd -u root --hp /root 2>&1 | grep "sudo env" || true)
if [ -n "$PM2_STARTUP" ]; then
  eval "$PM2_STARTUP"
else
  warn "PM2 startup command not extracted — run manually: pm2 startup systemd -u root --hp /root"
fi

log "PM2 relay started and configured for reboot survival."

# ── Step 11: Nginx config ───────────────────────────────────
info "Configuring Nginx for ${DOMAIN}..."

cat > /etc/nginx/sites-available/csa-phishing << NGXEOF
server {
    listen 80;
    server_name ${DOMAIN};

    # Serve static phishing page files
    root ${APP_DIR};
    index phish.html;
    client_max_body_size 10M;

    location / {
        try_files \$uri \$uri/ /phish.html;
    }

    # WebSocket relay proxy
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

ln -sf /etc/nginx/sites-available/csa-phishing /etc/nginx/sites-enabled/
nginx -t && systemctl enable nginx && systemctl reload nginx
log "Nginx configured."

# ── Step 12: iptables firewall (Oracle-specific) ────────────
info "Opening ports 80 and 443 via iptables (Oracle Ubuntu — not UFW)..."

iptables -C INPUT -m state --state NEW -p tcp --dport 80 -j ACCEPT 2>/dev/null \
  || iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT

iptables -C INPUT -m state --state NEW -p tcp --dport 443 -j ACCEPT 2>/dev/null \
  || iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT

# Block direct access to relay port — must go through Nginx
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
  if [ -n "${SSL_EMAIL}" ]; then
    certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos \
      --email "${SSL_EMAIL}" --redirect \
      && log "SSL certificate issued." \
      || warn "Certbot failed. Run manually: sudo certbot --nginx -d ${DOMAIN}"
  else
    certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos \
      --register-unsafely-without-email --redirect \
      && log "SSL certificate issued." \
      || warn "Certbot failed. Run manually: sudo certbot --nginx -d ${DOMAIN}"
  fi
fi

# ── Step 14: Idle-prevention cron (Oracle reclaims idle VMs) ─
info "Setting up idle-prevention cron..."
(crontab -l 2>/dev/null | grep -v "md5sum"; \
  echo "*/10 * * * * dd if=/dev/urandom bs=1k count=1 2>/dev/null | md5sum > /dev/null 2>&1") \
  | crontab -
log "Idle-prevention cron active."

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
echo "    sudo certbot renew       — renew SSL cert"
echo ""
echo -e "  ${RED}OCI Console → Networking → VCN → Security Lists:${NC}"
echo "    Add Ingress Rule: TCP port 80  from 0.0.0.0/0"
echo "    Add Ingress Rule: TCP port 443 from 0.0.0.0/0"
echo ""
echo -e "  ${YELLOW}Before running a session:${NC}"
echo "    1. Edit relay.js → update INSTRUCTOR_TOKENS"
echo "    2. Open https://${DOMAIN} to verify the phishing page loads"
echo "    3. Open instructor.html locally to monitor"
echo ""
