#!/usr/bin/env bash
# ==============================================================================
# Hermes Agent, Network Ollama & Self-Signed LAN Dashboard Jump-Pad Installer
# Target OS: Ubuntu 26.04 LTS (Optimized for Dedicated AI Host Nodes)
# ==============================================================================
# 
# ARCHITECTURE & PERSISTENCE OVERVIEW:
# 1. Config Persistence: Saves user input (domain/IP) to /storage/installer.conf 
#    so subsequent runs skip prompts automatically.
# 2. Self-Signed SSL: Generates a 10-year self-signed certificate stored at 
#    /storage/certs/ for local LAN HTTPS access without requiring Let's Encrypt.
# 3. Ollama Backend (Port 11434): Bound to 0.0.0.0 with open CORS (*) for LAN clients.
# 4. Hermes Dashboard (Port 9119): Proxied securely via Nginx over HTTPS.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Configuration Constants & Persistent Settings Check
# ------------------------------------------------------------------------------
STORAGE_ROOT="/storage"
HERMES_HOME="${STORAGE_ROOT}/hermes"
OLLAMA_MODELS_DIR="${STORAGE_ROOT}/ollama/models"
DOCKER_DATA_DIR="${STORAGE_ROOT}/docker"
CERT_DIR="${STORAGE_ROOT}/certs"
CONFIG_FILE="${STORAGE_ROOT}/installer.conf"

DEFAULT_GEMMA_MODEL="gemma4:latest"
OLLAMA_PORT=11434
HERMES_DASHBOARD_PORT=9119

echo "===> [1/8] Verifying system privileges and checking configuration state..."
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run with root privileges (e.g., sudo bash install.sh)" >&2
   exit 1
fi

if ! grep -qEi "ubuntu" /etc/os-release; then
    echo "Warning: This environment is not Ubuntu. Some package paths may vary."
fi

# Load previous configuration if it exists to avoid re-prompting
if [[ -f "$CONFIG_FILE" ]]; then
    echo "===> Loading existing configuration from $CONFIG_FILE..."
    source "$CONFIG_FILE"
fi

# Prompt and save domain/IP if not already configured
if [[ -z "${DOMAIN_NAME:-}" ]]; then
    while [[ -z "$DOMAIN_NAME" ]]; do
        read -p "Enter your local domain name or server IP for the dashboard (e.g., hermes.local or 192.168.1.50): " DOMAIN_NAME
        DOMAIN_NAME=$(echo "$DOMAIN_NAME" | tr -d '\r' | xargs)
        if [[ -z "$DOMAIN_NAME" ]]; then
            echo "Notice: Domain/IP cannot be empty. Please try again."
        fi
    done

    # Save to config file for future runs
    mkdir -p "$STORAGE_ROOT"
    echo "DOMAIN_NAME=\"$DOMAIN_NAME\"" > "$CONFIG_FILE"
    echo "Saved configuration to $CONFIG_FILE"
else
    echo "Using configured Domain/IP: $DOMAIN_NAME"
fi

# ------------------------------------------------------------------------------
# 2. Storage Infrastructure Setup
# ------------------------------------------------------------------------------
echo "===> [2/8] Configuring high-capacity storage layout at $STORAGE_ROOT..."
mkdir -p "$STORAGE_ROOT"

if ! mountpoint -q "$STORAGE_ROOT"; then
    echo "Notice: $STORAGE_ROOT is currently operating on the root system volume."
    echo "Tip: If using a dedicated secondary drive, format it and add its UUID to /etc/fstab."
fi

mkdir -p "$HERMES_HOME" "$OLLAMA_MODELS_DIR" "$DOCKER_DATA_DIR" "$CERT_DIR"

# ------------------------------------------------------------------------------
# 3. System Dependencies & Nginx Setup
# ------------------------------------------------------------------------------
echo "===> [3/8] Installing system tools, Nginx, and Docker engine..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git jq ufw apt-transport-https ca-certificates gnupg lsb-release pipx openssl nginx

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

id -u ollama &>/dev/null || useradd -r -s /bin/false ollama
mkdir -p /storage/ollama
chown -R ollama:ollama /storage/ollama

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
# 6. Self-Signed SSL Certificate Generation & Nginx Reverse Proxy Setup
# ------------------------------------------------------------------------------
echo "===> [6/8] Generating self-signed SSL certificates and configuring Nginx..."

# Generate self-signed certificate valid for 10 years if not already present
if [[ ! -f "$CERT_DIR/server.crt" ]] || [[ ! -f "$CERT_DIR/server.key" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.crt" \
        -subj "/CN=$DOMAIN_NAME/O=HermesLocal/C=US" \
        -addext "subjectAltName=DNS:$DOMAIN_NAME,IP:$DOMAIN_NAME" 2>/dev/null || \
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.crt" \
        -subj "/CN=$DOMAIN_NAME/O=HermesLocal/C=US"
    echo "Self-signed SSL certificate generated successfully."
else
    echo "Existing SSL certificates found in $CERT_DIR. Skipping generation."
fi

# Write Nginx configuration for self-signed HTTPS proxying
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

    ssl_certificate $CERT_DIR/server.crt;
    ssl_certificate_key $CERT_DIR/server.key;
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

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
EOF

ln -sfn /etc/nginx/sites-available/hermes /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
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
    ufw allow 80/tcp comment "HTTP (Redirect to HTTPS)"
    ufw allow 443/tcp comment "HTTPS (Hermes Web UI)"
    ufw allow "$OLLAMA_PORT/tcp" comment "Ollama Network API Access"
    ufw reload
fi

SERVER_IP="$(hostname -I | awk '{print $1}')"

echo "========================================================================"
echo "                   INSTALLATION COMPLETE SUCCESSFULLY!                  "
echo "========================================================================"
echo " Storage Path Map       : $STORAGE_ROOT"
echo " Config Persistence     : $CONFIG_FILE"
echo " SSL Certificate Path   : $CERT_DIR/server.crt"
echo " SSL Private Key Path   : $CERT_DIR/server.key"
echo " Ollama API (LAN)       : http://$SERVER_IP:$OLLAMA_PORT"
echo " Hermes Dashboard (LAN) : https://$DOMAIN_NAME (or https://$SERVER_IP)"
echo "------------------------------------------------------------------------"
echo " NOTE ON SELF-SIGNED CERTIFICATES:"
echo " Your browser will show a security warning because the SSL certificate is"
echo " self-signed. You can safely bypass this warning, or replace 'server.crt'"
echo " and 'server.key' in $CERT_DIR with your own custom/enterprise certificates."
echo "========================================================================"