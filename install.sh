#!/usr/bin/env bash
# ==============================================================================
# Hermes Agent, Network Ollama & Secure Web Dashboard Jump-Pad Installer
# Target OS: Ubuntu 26.04 LTS (Optimized for Dedicated AI Host Nodes)
# ==============================================================================
# 
# ARCHITECTURE OVERVIEW FOR NEWCOMERS:
# 1. Ollama Backend (Port 11434): Handles local LLM inference (Gemma 4). Bound to 
#    0.0.0.0 with open CORS (*) so local network clients can query models.
# 2. Hermes Dashboard (Port 9119): Built-in browser control panel for managing 
#    sessions, models, environment variables, and agent settings. Bound to 
#    localhost (127.0.0.1) for security.
# 3. Nginx Reverse Proxy & SSL: Terminates external traffic securely over HTTPS, 
#    handles WebSocket upgrades for live chat streaming, and proxies requests 
#    cleanly to the local Hermes Dashboard.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Configuration Constants & User Prompts (With Validation Loops)
# ------------------------------------------------------------------------------
STORAGE_ROOT="/storage"
HERMES_HOME="${STORAGE_ROOT}/hermes"
OLLAMA_MODELS_DIR="${STORAGE_ROOT}/ollama/models"
DOCKER_DATA_DIR="${STORAGE_ROOT}/docker"
DEFAULT_GEMMA_MODEL="gemma4:latest"
OLLAMA_PORT=11434
HERMES_DASHBOARD_PORT=9119

echo "===> [1/8] Verifying system privileges and gathering parameters..."
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run with root privileges (e.g., sudo bash install.sh)" >&2
   exit 1
fi

if ! grep -qEi "ubuntu" /etc/os-release; then
    echo "Warning: This environment is not Ubuntu. Some package paths may vary."
fi

# Loop until a valid domain name is provided
DOMAIN_NAME=""
while [[ -z "$DOMAIN_NAME" ]]; do
    read -p "Enter the domain or subdomain for your Hermes Dashboard (e.g., hermes.yourdomain.com): " DOMAIN_NAME
    if [[ -z "$DOMAIN_NAME" ]]; then
        echo "Notice: Domain name cannot be empty for SSL setup. Please try again."
    fi
done

# Loop until a valid email is provided
SSL_EMAIL=""
while [[ -z "$SSL_EMAIL" ]]; do
    read -p "Enter your email address for Let's Encrypt SSL registration: " SSL_EMAIL
    if [[ -z "$SSL_EMAIL" ]]; then
        echo "Notice: Email address cannot be empty for SSL registration. Please try again."
    fi
done

# ------------------------------------------------------------------------------
# 2. Storage Infrastructure Setup
# ------------------------------------------------------------------------------
echo "===> [2/8] Configuring high-capacity storage layout at $STORAGE_ROOT..."
mkdir -p "$STORAGE_ROOT"

if ! mountpoint -q "$STORAGE_ROOT"; then
    echo "Notice: $STORAGE_ROOT is currently operating on the root system volume."
    echo "Tip: If using a dedicated secondary drive, format it and add its UUID to /etc/fstab."
fi

mkdir -p "$HERMES_HOME" "$OLLAMA_MODELS_DIR" "$DOCKER_DATA_DIR"

# ------------------------------------------------------------------------------
# 3. System Dependencies & Nginx / Certbot Setup
# ------------------------------------------------------------------------------
echo "===> [3/8] Installing system tools, Nginx, Certbot, and Docker engine..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git jq ufw apt-transport-https ca-certificates gnupg lsb-release pipx openssl nginx certbot python3-certbot-nginx

if ! command -v docker &> /dev/null; then
    echo "Installing Docker Engine for sandboxed agent execution..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "$SUDO_USER"
fi

# ------------------------------------------------------------------------------
# 4. Local Ollama Backend Configuration (Network Accessible)
# ------------------------------------------------------------------------------
echo "===> [4/8] Deploying Ollama LLM backend with network accessibility..."
if systemctl is-active --quiet ollama; then
    systemctl stop ollama
fi

if ! command -v ollama &> /dev/null; then
    echo "Installing Ollama binary package..."
    curl -fsSL https://ollama.com/install.sh | sh
fi

# Ensure the system 'ollama' user exists and owns the storage directory
id -u ollama &>/dev/null || useradd -r -s /bin/false ollama
mkdir -p /storage/ollama
chown -R ollama:ollama /storage/ollama

# Configure systemd override to bind Ollama to all network interfaces (0.0.0.0)
mkdir -p /etc/systemd/system/ollama.service.d
cat <<EOF > /etc/systemd/system/ollama.service.d/override.conf
[Service]
Environment="OLLAMA_MODELS=$OLLAMA_MODELS_DIR"
Environment="OLLAMA_HOST=0.0.0.0:$OLLAMA_PORT"
Environment="OLLAMA_ORIGINS=*"
EOF

systemctl daemon-reload
systemctl enable --now ollama

echo "Waiting for Ollama API endpoint to become responsive..."
until curl -s "http://127.0.0.1:$OLLAMA_PORT/api/tags" > /dev/null 2>&1; do
    sleep 2
done

echo "Pulling foundation model ($DEFAULT_GEMMA_MODEL)..."
ollama pull "$DEFAULT_GEMMA_MODEL"

# ------------------------------------------------------------------------------
# 5. Hermes Agent Core & Dashboard Configuration
# ------------------------------------------------------------------------------
echo "===> [5/8] Installing Hermes Agent and configuring dashboard bindings..."
export HERMES_CONFIG_DIR="$HERMES_HOME/config"
mkdir -p "$HERMES_CONFIG_DIR"

if ! command -v hermes &> /dev/null; then
    echo "Downloading and installing Hermes Agent..."
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
    
    if [[ -f "$HOME/.local/bin/hermes" ]] && [[ ! -f "/usr/local/bin/hermes" ]]; then
        ln -s "$HOME/.local/bin/hermes" /usr/local/bin/hermes
    elif [[ -f "$STORAGE_ROOT/.local/bin/hermes" ]] && [[ ! -f "/usr/local/bin/hermes" ]]; then
        ln -s "$STORAGE_ROOT/.local/bin/hermes" /usr/local/bin/hermes
    fi
fi

# Write core routing config matching local Ollama endpoints
cat <<EOF > "$HERMES_CONFIG_DIR/config.yaml"
version: "1.0"
backend: local
default_provider: ollama
models:
  default: "$DEFAULT_GEMMA_MODEL"
  providers:
    ollama:
      base_url: "http://127.0.0.1:$OLLAMA_PORT/v1"
      model: "$DEFAULT_GEMMA_MODEL"
ollama:
  base_url: "http://127.0.0.1:$OLLAMA_PORT/v1"
  default_model: "$DEFAULT_GEMMA_MODEL"
terminal:
  backend: docker
workspaces:
  root_dir: "$STORAGE_ROOT/workspaces"
dashboard:
  host: "127.0.0.1"
  port: $HERMES_DASHBOARD_PORT
EOF

# ------------------------------------------------------------------------------
# 6. Nginx Reverse Proxy Setup with SSL (Let's Encrypt)
# ------------------------------------------------------------------------------
echo "===> [6/8] Configuring Nginx reverse proxy and SSL for Hermes Dashboard..."
mkdir -p /var/www/letsencrypt

# Write initial HTTP configuration for Let's Encrypt validation challenge
cat <<EOF > /etc/nginx/sites-available/hermes
upstream hermes_dashboard {
    server 127.0.0.1:$HERMES_DASHBOARD_PORT;
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;

    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

ln -sfn /etc/nginx/sites-available/hermes /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

echo "Obtaining SSL certificate via Certbot for $DOMAIN_NAME..."
certbot certonly --webroot \
    -w /var/www/letsencrypt \
    -d "$DOMAIN_NAME" \
    --email "$SSL_EMAIL" \
    --agree-tos \
    --non-interactive

# Update Nginx config with full SSL termination, WebSockets, and proxy optimizations
cat <<EOF > /etc/nginx/sites-available/hermes
upstream hermes_dashboard {
    server 127.0.0.1:$HERMES_DASHBOARD_PORT;
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN_NAME;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://hermes_dashboard;
        proxy_http_version 1.1;
        
        # WebSocket support for real-time session streaming
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Timeouts and streaming buffering adjustments for long-running AI generation
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
EOF

nginx -t
systemctl reload nginx

# ------------------------------------------------------------------------------
# 7. Systemd Service Deployment for Hermes Dashboard Gateway
# ------------------------------------------------------------------------------
echo "===> [7/8] Configuring systemd service for Hermes Dashboard..."
cat <<EOF > /etc/systemd/system/hermes-dashboard.service
[Unit]
Description=Hermes Agent Web Dashboard Service
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
User=root
Environment="HOME=$STORAGE_ROOT"
Environment="HERMES_CONFIG_DIR=$HERMES_CONFIG_DIR"
ExecStart=/usr/local/bin/hermes dashboard --host 127.0.0.1 --port $HERMES_DASHBOARD_PORT --no-open
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hermes-dashboard.service

# ------------------------------------------------------------------------------
# 8. Firewall Configuration & Summary
# ------------------------------------------------------------------------------
echo "===> [8/8] Securing firewall rules..."
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp comment "HTTP (Let's Encrypt)"
    ufw allow 443/tcp comment "HTTPS (Hermes Web UI)"
    ufw allow "$OLLAMA_PORT/tcp" comment "Ollama Network API Access"
    ufw reload
fi

SERVER_IP="$(hostname -I | awk '{print $1}')"

echo "========================================================================"
echo "                   INSTALLATION COMPLETE SUCCESSFULLY!                  "
echo "========================================================================"
echo " Storage Path Map    : $STORAGE_ROOT"
echo " Ollama API (LAN)    : http://$SERVER_IP:$OLLAMA_PORT"
echo " Hermes Dashboard    : https://$DOMAIN_NAME"
echo " Default Model       : $DEFAULT_GEMMA_MODEL"
echo "------------------------------------------------------------------------"
echo " ACCESS YOUR WEB DASHBOARD:"
echo " Open your web browser and go to: https://$DOMAIN_NAME"
echo " All chat panels, tool calls, logs, and settings will stream securely via SSL!"
echo "========================================================================"