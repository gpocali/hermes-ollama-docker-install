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

# SSH Tunnel / Secure Client User Configuration
SSH_USER="hermes-remote"
SSH_USER_HOME="/storage/hermes-remote"

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

echo "===> [3/7] Ensuring dependencies (Docker, curl, ufw, jq, pipx, openssh-server)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git jq ufw apt-transport-https ca-certificates gnupg lsb-release pipx openssh-server openssl

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

echo "===> [5/7] Deploying/Updating Hermes Agent environment & API Token..."
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

echo "===> [6/7] Configuring Dedicated SSH User & Key Pair..."
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
    ufw delete allow 443/tcp 2>/dev/null || true
    ufw delete allow "$HERMES_API_PORT/tcp" 2>/dev/null || true
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

SERVER_FQDN="$(hostname -f 2>/dev/null || hostname)"

echo "===> [7/7] Installation and Update Complete Successfully!"
echo "--------------------------------------------------------"
echo " Storage Path Map   : $STORAGE_ROOT"
echo " API Token (Save!)  : $HERMES_API_TOKEN"
echo " Token File Path    : $ENV_FILE"
echo " Dedicated SSH User : $SSH_USER"
echo " Server Private Key : $SERVER_KEY_PRIV"
echo "--------------------------------------------------------"
echo " HOW TO CONNECT FROM A WINDOWS CLIENT:"
echo " 1. Copy the private key content from the file above ($SERVER_KEY_PRIV)"
echo "    and save it on your Windows machine at: C:\Users\<YourUser>\.ssh\id_ed25519_hermes"
echo " 2. Fix the file permissions in PowerShell (Windows requires strict ownership):"
echo "    icacls \"\$HOME\\.ssh\\id_ed25519_hermes\" /inheritance:r"
echo "    icacls \"\$HOME\\.ssh\\id_ed25519_hermes\" /grant:r \"\$(\$env:USERNAME):R\""
echo " 3. Add this entry to your Windows SSH config file (C:\Users\<YourUser>\.ssh\config):"
echo "    Host hermes-server"
echo "        HostName $SERVER_FQDN"
echo "        User $SSH_USER"
echo "        IdentityFile C:/Users/<YourUser>/.ssh/id_ed25519_hermes"
echo "        IdentitiesOnly yes"
echo " 4. Open a PowerShell terminal and start your secure local port-forwarding tunnel:"
echo "    ssh -L 8642:127.0.0.1:$HERMES_API_PORT hermes-server"
echo " 5. Access Hermes locally on your Windows client at http://127.0.0.1:8642"
echo "    using Bearer token authentication: $HERMES_API_TOKEN"
echo "--------------------------------------------------------"