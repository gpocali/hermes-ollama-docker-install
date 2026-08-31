#!/usr/bin/env bash
# ==============================================================================
# Hermes Agent & Network-Accessible Ollama Automated Installer for Ubuntu 26.04 LTS
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

echo "===> [1/6] Verifying system privileges and OS environment..."
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (e.g., sudo bash install.sh)" >&2
   exit 1
fi

if ! grep -qEi "ubuntu" /etc/os-release; then
    echo "Warning: This script is optimized for Ubuntu Desktop Linux."
fi

echo "===> [2/6] Configuring /storage partition mount point..."
if [[ ! -d "$STORAGE_ROOT" ]]; then
    mkdir -p "$STORAGE_ROOT"
fi

if ! mountpoint -q "$STORAGE_ROOT"; then
    echo "Notice: $STORAGE_ROOT is currently a standard directory on the system drive."
    echo "To map a separate partition, ensure it is formatted and add its UUID to /etc/fstab targeting $STORAGE_ROOT."
fi

mkdir -p "$HERMES_HOME" "$OLLAMA_MODELS_DIR" "$DOCKER_DATA_DIR"

echo "===> [3/6] Ensuring dependencies (Docker, curl, ufw, jq, pipx, openssl)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git jq ufw apt-transport-https ca-certificates gnupg lsb-release pipx openssl

if ! command -v docker &> /dev/null; then
    echo "Installing Docker Engine..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | symbol --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
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

echo "===> [4/6] Setting up Network-Accessible Ollama Backend ( bound to 0.0.0.0 )..."
if systemctl is-active --quiet ollama; then
    systemctl stop ollama
fi

if ! command -v ollama &> /dev/null; then
    echo "Installing Ollama binary..."
    curl -fsSL https://ollama.com/install.sh | sh
fi

# Configure Ollama to listen on all network interfaces via OLLAMA_HOST=0.0.0.0
mkdir -p /etc/systemd/system/ollama.service.d
cat <<EOF > /etc/systemd/system/ollama.service.d/override.service
[Service]
Environment="OLLAMA_MODELS=$OLLAMA_MODELS_DIR"
Environment="OLLAMA_HOST=0.0.0.0:$OLLAMA_PORT"
Environment="OLLAMA_ORIGINS=*"
EOF

systemctl daemon-reload
systemctl enable --now ollama

echo "Waiting for Ollama service to become responsive..."
until curl -s "http://127.0.0.1:$OLLAMA_PORT/api/tags" > /dev/null 2>&1; do
    sleep 2
done

echo "Pulling Gemma 4 model ($DEFAULT_GEMMA_MODEL)..."
ollama pull "$DEFAULT_GEMMA_MODEL"

echo "===> [5/6] Deploying/Updating Hermes Agent environment & Config..."
export HERMES_CONFIG_DIR="$HERMES_HOME/config"
mkdir -p "$HERMES_CONFIG_DIR"

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
api_server:
  enabled: true
  host: "127.0.0.1"
  port: $HERMES_API_PORT
EOF

echo "===> [6/6] Configuring Systemd Service for Hermes Agent API..."
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
Environment="HERMES_PROVIDER=ollama"
Environment="HERMES_MODEL=$DEFAULT_GEMMA_MODEL"
Environment="OPENAI_API_BASE=http://127.0.0.1:$OLLAMA_PORT/v1"
ExecStart=/usr/local/bin/hermes serve
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart ollama
systemctl restart hermes-agent.service

if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "$OLLAMA_PORT/tcp" comment "Ollama Open API Access"
    ufw reload
fi

echo "===> Installation and Setup Complete Successfully!"
echo "--------------------------------------------------------"
echo " Storage Path Map   : $STORAGE_ROOT"
echo " Ollama API (LAN)   : http://<server-ip>:$OLLAMA_PORT"
echo " Hermes Local Port  : $HERMES_API_PORT"
echo "--------------------------------------------------------"