#!/usr/bin/env bash
# ==============================================================================
# Hermes Agent, Local Ollama & Open WebUI Automated Installer for Ubuntu 26.04 LTS
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
WEBUI_PORT=3000

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

echo "===> [3/7] Ensuring dependencies (Docker, curl, ufw, jq, pipx, openssl)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git jq ufw apt-transport-https ca-certificates gnupg lsb-release pipx openssl

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

echo "===> [5/7] Deploying/Updating Hermes Agent environment & Config..."
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

# Fully preconfigured config.yaml routing inference directly to local Ollama with /v1 endpoint suffix
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

echo "===> [6/7] Deploying Open WebUI Frontend via Docker..."
if docker ps -a --format '{{.Names}}' | grep -q "^open-webui$"; then
    echo "Removing existing Open WebUI container to apply updates..."
    docker stop open-webui >/dev/null 2>&1 || true
    docker rm open-webui >/dev/null 2>&1 || true
fi

docker run -d \
  -p "$WEBUI_PORT:8080" \
  -e OPENAI_API_BASE_URL="http://host.docker.internal:$HERMES_API_PORT/v1" \
  -e OPENAI_API_KEY="local-hermes-bypass" \
  -e ENABLE_OLLAMA_API=false \
  --add-host=host.docker.internal:host-gateway \
  -v open-webui:/app/backend/data \
  --name open-webui \
  --restart always \
  ghcr.io/open-webui/open-webui:main

echo "===> [7/7] Configuring Systemd Service for Hermes Agent API..."
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
    ufw allow "$WEBUI_PORT/tcp" comment "Open WebUI Local Access"
    ufw reload
fi

echo "===> Installation and Setup Complete Successfully!"
echo "--------------------------------------------------------"
echo " Storage Path Map   : $STORAGE_ROOT"
echo " Local Ollama Port  : $OLLAMA_PORT"
echo " Hermes API Port    : $HERMES_API_PORT"
echo " Open WebUI URL     : http://localhost:$WEBUI_PORT"
echo "--------------------------------------------------------"
echo " Open your Ubuntu desktop browser and navigate to:"
echo " http://localhost:$WEBUI_PORT to start chatting instantly!"
echo "--------------------------------------------------------"