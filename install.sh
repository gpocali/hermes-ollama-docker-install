#!/usr/bin/env bash
# ==============================================================================
# Hermes Agent & Network-Accessible Ollama Server Jump-Pad Installer
# Target OS: Ubuntu 26.04 LTS (Optimized for Dedicated AI Host Nodes)
# ==============================================================================
# 
# ARCHITECTURE OVERVIEW FOR NEWCOMERS:
# 1. Ollama Backend (Port 11434): Handles local LLM inference (Gemma 4). Bound to 
#    0.0.0.0 so network clients can query models directly, with CORS enabled (*).
# 2. Hermes Agent Gateway (Port 8642): Acts as the local automation layer, tool 
#    dispatcher, and API router.
# 3. Secure SSH Tunnel Layer: Provisions a dedicated restricted user ('hermes-remote') 
#    and generates an Ed25519 key pair, allowing remote Windows/Linux clients to 
#    connect securely without exposing raw APIs to the public internet.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Configuration Constants & Paths
# ------------------------------------------------------------------------------
STORAGE_ROOT="/storage"
HERMES_HOME="${STORAGE_ROOT}/hermes"
OLLAMA_MODELS_DIR="${STORAGE_ROOT}/ollama/models"
DOCKER_DATA_DIR="${STORAGE_ROOT}/docker"
DEFAULT_GEMMA_MODEL="gemma4:latest"
OLLAMA_PORT=11434
HERMES_API_PORT=8642

# Secure Remote Client User
SSH_USER="hermes-remote"
SSH_USER_HOME="/storage/hermes-remote"

# ------------------------------------------------------------------------------
# 2. Privileges & Environment Validation
# ------------------------------------------------------------------------------
echo "===> [1/7] Verifying system privileges and OS environment..."
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run with root privileges (e.g., sudo bash install.sh)" >&2
   exit 1
fi

if ! grep -qEi "ubuntu" /etc/os-release; then
    echo "Warning: This environment is not Ubuntu. Some package paths may vary."
fi

# ------------------------------------------------------------------------------
# 3. Storage Infrastructure Setup
# ------------------------------------------------------------------------------
echo "===> [2/7] Configuring high-capacity storage layout at $STORAGE_ROOT..."
# AI models and agent workspaces require substantial disk space. We centralize
# everything under /storage so it can easily map to a dedicated mount/partition.
mkdir -p "$STORAGE_ROOT"

if ! mountpoint -q "$STORAGE_ROOT"; then
    echo "Notice: $STORAGE_ROOT is currently operating on the root system volume."
    echo "Tip: If using a dedicated secondary drive, format it and add its UUID to /etc/fstab."
fi

mkdir -p "$HERMES_HOME" "$OLLAMA_MODELS_DIR" "$DOCKER_DATA_DIR"

# ------------------------------------------------------------------------------
# 4. System Dependencies & Container Runtime
# ------------------------------------------------------------------------------
echo "===> [3/7] Installing required system tools and Docker engine..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git jq ufw apt-transport-https ca-certificates gnupg lsb-release pipx openssh-server openssl

if ! command -v docker &> /dev/null; then
    echo "Installing Docker Engine for sandboxed agent terminal execution..."
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
# 5. Local Ollama Backend Configuration (Network Accessible)
# ------------------------------------------------------------------------------
echo "===> [4/7] Deploying Ollama LLM backend with network accessibility..."
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
# and permit cross-origin requests (*) for external clients.
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
# 6. Hermes Agent Core & Gateway Configuration
# ------------------------------------------------------------------------------
echo "===> [5/7] Installing Hermes Agent and writing routing config..."
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

# Write core configuration mapping local Ollama endpoints
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

# ------------------------------------------------------------------------------
# 7. Secure Remote SSH User & Tunnel Provisioning
# ------------------------------------------------------------------------------
echo "===> [6/7] Setting up dedicated remote SSH management user..."
if ! id "$SSH_USER" &>/dev/null; then
    useradd -m -d "$SSH_USER_HOME" -s /bin/bash "$SSH_USER"
else
    if [[ "$(getent passwd "$SSH_USER" | cut -d: -f6)" != "$SSH_USER_HOME" ]]; then
        usermod -d "$SSH_USER_HOME" "$SSH_USER"
    fi
fi

SSH_DIR="$SSH_USER_HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

SERVER_KEY_PRIV="$SSH_DIR/id_ed25519_hermes"
SERVER_KEY_PUB="$SSH_DIR/id_ed25519_hermes.pub"

if [[ ! -f "$SERVER_KEY_PRIV" ]]; then
    ssh-keygen -t ed25519 -N "" -f "$SERVER_KEY_PRIV" -C "hermes-secure-remote"
    cat "$SERVER_KEY_PUB" >> "$SSH_DIR/authorized_keys"
fi

chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$SSH_USER:$SSH_USER" "$SSH_USER_HOME"

ln -sfn "$HERMES_HOME" "$SSH_USER_HOME/hermes_data"
ln -sfn "$STORAGE_ROOT/workspaces" "$SSH_USER_HOME/workspaces"
chown -h "$SSH_USER:$SSH_USER" "$SSH_USER_HOME/hermes_data" "$SSH_USER_HOME/workspaces"

rm -f /etc/ssh/sshd_config.d/post-quantum.conf
systemctl restart ssh

if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 22/tcp comment "SSH Secure Access"
    ufw allow "$OLLAMA_PORT/tcp" comment "Ollama Network API Access"
    ufw reload
fi

# ------------------------------------------------------------------------------
# 8. Systemd Service Deployment for Hermes Gateway
# ------------------------------------------------------------------------------
echo "===> [7/7] Configuring systemd service for Hermes Agent Gateway..."
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

SERVER_FQDN="$(hostname -f 2>/dev/null || hostname)"
SERVER_IP="$(hostname -I | awk '{print $1}')"

echo "========================================================================"
echo "                   INSTALLATION COMPLETE SUCCESSFULLY!                  "
echo "========================================================================"
echo " Storage Path Map    : $STORAGE_ROOT"
echo " Ollama API (LAN)    : http://$SERVER_IP:$OLLAMA_PORT"
echo " Default Model       : $DEFAULT_GEMMA_MODEL"
echo " Dedicated SSH User  : $SSH_USER"
echo " Server Private Key  : $SERVER_KEY_PRIV"
echo "------------------------------------------------------------------------"
echo " ONBOARDING INSTRUCTIONS FOR REMOTE CLIENTS:"
echo " 1. Copy the private key content from: $SERVER_KEY_PRIV"
echo " 2. Save it on your client workstation at: ~/.ssh/id_ed25519_hermes"
echo " 3. Connect to your server using user '$SSH_USER' at host '$SERVER_IP'"
echo " 4. Point your client model provider directly to:"
echo "    http://$SERVER_IP:$OLLAMA_PORT/v1"
echo "========================================================================"