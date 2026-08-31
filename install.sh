#!/usr/bin/env bash
# ==============================================================================
# Hermes Agent & Local Ollama Automated Installer / Upgrader for Ubuntu 26.04 LTS
# ==============================================================================
set -euo pipefail

# Configuration Defaults
STORAGE_ROOT="/storage"
HERMES_HOME="${STORAGE_ROOT}/hermes"
OLLAMA_MODELS_DIR="${STORAGE_ROOT}/ollama/models"
DOCKER_DATA_DIR="${STORAGE_ROOT}/docker"
DEFAULT_GEMMA_MODEL="gemma4:12b"
OLLAMA_PORT=11434
HERMES_API_PORT=8642
ENABLE_HTTPS_PROXY="${ENABLE_HTTPS_PROXY:-false}" # Set to true to automatically setup Nginx + SSL
SSL_CERT_DIR="/etc/nginx/ssl"

echo "===> [1/7] Verifying system privileges and OS environment..."
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (e.g., sudo bash install.sh)" >&2
   exit 1
fi

if ! grep -qEi "ubuntu" /etc/os-release; then
    echo "Warning: This script is optimized for Ubuntu Desktop Linux."
fi

echo "===> [2/7] Configuring /storage partition mount point..."
if [[ ! -d "$STORAGE_ROOT" ]]; then
    mkdir -p "$STORAGE_ROOT"
fi

if ! mountpoint -q "$STORAGE_ROOT"; then
    echo "Notice: $STORAGE_ROOT is currently a standard directory on the system drive."
    echo "To map a separate partition, ensure it is formatted and add its UUID to /etc/fstab targeting $STORAGE_ROOT."
fi

mkdir -p "$HERMES_HOME" "$OLLAMA_MODELS_DIR" "$DOCKER_DATA_DIR"

echo "===> [3/7] Ensuring dependencies (Docker, curl, ufw, jq, pipx, nginx)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git jq ufw apt-transport-https ca-certificates gnupg lsb-release pipx nginx openssl

if ! command -v docker &> /dev/null; then
    echo "Installing Docker Engine..."
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

echo "===> [4/7] Setting up Local Ollama Backend ( bound to /storage )..."
if systemctl is-active --quiet ollama; then
    systemctl stop ollama
fi

if ! command -v ollama &> /dev/null; then
    echo "Installing Ollama binary..."
    curl -fsSL https://ollama.com/install.sh | sh
fi

mkdir -p /etc/systemd/system/ollama.service.d
cat <<EOF > /etc/systemd/system/ollama.service.d/override.service
[Service]
Environment="OLLAMA_MODELS=$OLLAMA_MODELS_DIR"
Environment="OLLAMA_HOST=127.0.0.1:$OLLAMA_PORT"
EOF

systemctl daemon-reload
systemctl enable --now ollama

echo "Waiting for Ollama service to become responsive..."
until curl -s "http://127.0.0.1:$OLLAMA_PORT/api/tags" > /dev/null 2>&1; do
    sleep 2
done

echo "Pulling Gemma 4 model ($DEFAULT_GEMMA_MODEL)..."
ollama pull "$DEFAULT_GEMMA_MODEL"

echo "===> [5/7] Deploying/Updating Hermes Agent environment & Generating API Token..."
export HERMES_CONFIG_DIR="$HERMES_HOME/config"
mkdir -p "$HERMES_CONFIG_DIR"

ENV_FILE="$STORAGE_ROOT/hermes/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    HERMES_API_TOKEN="hermes_$(openssl rand -hex 24)"
    echo "HERMES_API_TOKEN=$HERMES_API_TOKEN" > "$ENV_FILE"
else
    source "$ENV_FILE"
    if [[ -z "${HERMES_API_TOKEN:-}" ]]; then
        HERMES_API_TOKEN="hermes_$(openssl rand -hex 24)"
        echo "HERMES_API_TOKEN=$HERMES_API_TOKEN" >> "$ENV_FILE"
    fi
fi

if ! command -v hermes &> /dev/null; then
    echo "Installing Hermes Agent via official installer..."
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
    
    if [[ -f "$HOME/.local/bin/hermes" ]] && [[ ! -f "/usr/local/bin/hermes" ]]; then
        ln -s "$HOME/.local/bin/hermes" /usr/local/bin/hermes
    elif [[ -f "$STORAGE_ROOT/.local/bin/hermes" ]] && [[ ! -f "/usr/local/bin/hermes" ]]; then
        ln -s "$STORAGE_ROOT/.local/bin/hermes" /usr/local/bin/hermes
    fi
else
    echo "Hermes Agent already present. Refreshing runtime config..."
fi

cat <<EOF > "$HERMES_CONFIG_DIR/config.yaml"
version: "1.0"
backend: local
ollama:
  base_url: "http://127.0.0.1:$OLLAMA_PORT"
  default_model: "$DEFAULT_GEMMA_MODEL"
terminal:
  backend: docker
workspaces:
  root_dir: "$STORAGE_ROOT/workspaces"
api_server:
  enabled: true
  host: "127.0.0.1"
  port: $HERMES_API_PORT
  api_key: "$HERMES_API_TOKEN"
EOF

if [[ "$ENABLE_HTTPS_PROXY" == "true" ]]; then
    echo "Configuring Nginx HTTPS Reverse Proxy with SSL Certificates..."
    mkdir -p "$SSL_CERT_DIR"
    
    # Generate self-signed certificate if none exist
    if [[ ! -f "$SSL_CERT_DIR/hermes.crt" ]] || [[ ! -f "$SSL_CERT_DIR/hermes.key" ]]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$SSL_CERT_DIR/hermes.key" \
            -out "$SSL_CERT_DIR/hermes.crt" \
            -subj "/C=US/ST=NewYork/L=NewYork/O=Hermes/CN=$(hostname)"
    fi

    cat <<EOF > /etc/nginx/sites-available/hermes-ssl
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate $SSL_CERT_DIR/hermes.crt;
    ssl_certificate_key $SSL_CERT_DIR/hermes.key;

    location / {
        proxy_pass http://127.0.0.1:$HERMES_API_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    ln -sf /etc/nginx/sites-available/hermes-ssl /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    systemctl restart nginx
fi

echo "===> [6/7] Configuring Firewall Ports & System Boot Daemons..."
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 22/tcp comment "SSH"
    if [[ "$ENABLE_HTTPS_PROXY" == "true" ]]; then
        ufw allow 443/tcp comment "HTTPS Hermes Secure Gateway"
    else
        ufw allow "$HERMES_API_PORT/tcp" comment "Hermes Agent API Gateway"
    fi
    ufw reload
fi

cat <<EOF > /etc/systemd/system/hermes-agent.service
[Unit]
Description=Hermes Agent API Gateway & Automation Service
After=network.target docker.service ollama.service
Wants=docker.service ollama.service

[Service]
Type=simple
User=root
Environment="HOME=$STORAGE_ROOT"
Environment="HERMES_CONFIG_DIR=$HERMES_CONFIG_DIR"
ExecStart=/usr/local/bin/hermes gateway --host 127.0.0.1 --port $HERMES_API_PORT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hermes-agent.service

echo "===> [7/7] Installation and Update Complete Successfully!"
echo "--------------------------------------------------------"
echo " Storage Path Map : $STORAGE_ROOT"
echo " API Token (Save!): $HERMES_API_TOKEN"
echo " Token File Path  : $ENV_FILE"
echo " Hermes Gateway   : http://127.0.0.1:$HERMES_API_PORT (Secured via Token)"
if [[ "$ENABLE_HTTPS_PROXY" == "true" ]]; then
echo " HTTPS Proxy      : https://<your-ubuntu-ip>/"
echo " SSL Certificate  : $SSL_CERT_DIR/hermes.crt"
echo " SSL Private Key  : $SSL_CERT_DIR/hermes.key"
echo "   (Replace certificate files above and run 'sudo systemctl restart nginx')"
fi
echo "--------------------------------------------------------"