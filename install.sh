#!/usr/bin/env bash
# ==============================================================================
# Hermes Agent, Network Ollama & Self-Signed LAN Dashboard Jump-Pad Installer
# Target OS: Ubuntu 26.04 LTS (Optimized for Dedicated AI Host Nodes)
# ==============================================================================
# 
# ARCHITECTURE & PERSISTENCE OVERVIEW:
# 1. Auto-Discovery & Persistence: Automatically discovers the machine hostname 
#    and active network IPs on first run. Saves them to /storage/installer.conf 
#    and supports legacy configuration keys for backward compatibility.
# 2. Self-Signed SSL (Multi-SAN): Generates a 10-year self-signed certificate 
#    containing all configured domains and IPs as Subject Alternative Names.
# 3. Ollama Backend (Port 11434): Bound to 0.0.0.0 with open CORS (*) for LAN clients.
# 4. Hermes Unified Dashboard (Port 9119): Proxied securely via Nginx over HTTPS, 
#    complete with dynamic WebSocket mapping and Host/Origin header overrides.
# 5. Native Custom Provider, Egress & Google Chrome Container: Configures custom 
#    Ollama provider, disables proxy blockages (`proxy.enabled: false`), pre-initializes 
#    skills hub, and builds a local Docker image (`hermes-browser-env`) using 
#    Google Chrome Stable (bypassing Ubuntu Snap restrictions) with Xvfb and Xauth.
# ==============================================================================

set -euo pipefail

INSTALLER_VERSION="2.8"
STORAGE_ROOT="/storage"
HERMES_HOME="${STORAGE_ROOT}/hermes"
OLLAMA_MODELS_DIR="${STORAGE_ROOT}/ollama/models"
DOCKER_DATA_DIR="${STORAGE_ROOT}/docker"
CERT_DIR="${STORAGE_ROOT}/certs"
CONFIG_FILE="${STORAGE_ROOT}/installer.conf"

DEFAULT_GEMMA_MODEL="gemma4:latest"
OLLAMA_PORT=11434
HERMES_DASHBOARD_PORT=9119

echo "===> [1/7] Verifying system privileges and checking configuration state (v$INSTALLER_VERSION)..."
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run with root privileges (e.g., sudo bash install.sh)" >&2
   exit 1
fi

if ! grep -qEi "ubuntu" /etc/os-release; then
    echo "Warning: This environment is not Ubuntu. Some package paths may vary."
fi

# ------------------------------------------------------------------------------
# Config Persistence & Auto-Discovery Logic (With Legacy Fallback)
# ------------------------------------------------------------------------------
SYSTEM_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
SYSTEM_IPS="$(hostname -I | xargs)"
DEFAULT_DOMAINS="$SYSTEM_HOSTNAME $SYSTEM_IPS"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "===> Loading existing configuration from $CONFIG_FILE..."
    source "$CONFIG_FILE"
    
    if [[ -z "${SERVER_DOMAINS:-}" ]] && [[ -n "${DOMAIN_NAME:-}" ]]; then
        SERVER_DOMAINS="$DOMAIN_NAME"
    fi

    if [[ -z "${SERVER_DOMAINS:-}" ]]; then
        SERVER_DOMAINS="$DEFAULT_DOMAINS"
    fi
else
    SERVER_DOMAINS="$DEFAULT_DOMAINS"
    mkdir -p "$STORAGE_ROOT"
    cat <<EOF > "$CONFIG_FILE"
# ==============================================================================
# Hermes Server Configuration File
# ==============================================================================
# SERVER_DOMAINS controls which hostnames and IPs are valid for Nginx server_name
# and included in the SSL certificate SANs. You can safely modify this list 
# manually; your changes will be preserved across script re-runs.
# ==============================================================================
SERVER_DOMAINS="$SERVER_DOMAINS"
EOF
    echo "Created persistent configuration at $CONFIG_FILE"
fi

echo "Active Server Domains/IPs for Dashboard: $SERVER_DOMAINS"

# ------------------------------------------------------------------------------
# 2. Storage Infrastructure Setup
# ------------------------------------------------------------------------------
echo "===> [2/7] Configuring high-capacity storage layout at $STORAGE_ROOT..."
mkdir -p "$STORAGE_ROOT"

if ! mountpoint -q "$STORAGE_ROOT"; then
    echo "Notice: $STORAGE_ROOT is currently operating on the root system volume."
fi

mkdir -p "$HERMES_HOME" "$OLLAMA_MODELS_DIR" "$DOCKER_DATA_DIR" "$CERT_DIR"

# ------------------------------------------------------------------------------
# 3. System Dependencies, Browser Docker Image (Google Chrome) & Nginx Setup
# ------------------------------------------------------------------------------
echo "===> [3/7] Installing system tools, Nginx, Docker engine, and building Chrome browser container..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git jq ufw apt-transport-https ca-certificates gnupg lsb-release pipx openssl nginx xvfb xauth

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

# Build local sandboxed browser container using Google Chrome Stable (Bypassing Ubuntu Snap)
BUILD_DIR="$STORAGE_ROOT/docker/browser-build"
mkdir -p "$BUILD_DIR"
cat <<EOF > "$BUILD_DIR/Dockerfile"
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y wget curl gnupg xvfb xauth libgtk-3-dev libnss3 libasound2t64 libxss1 libxtst6 xdg-utils && \
    wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && \
    apt-get install -y ./google-chrome-stable_current_amd64.deb || apt-get -f install -y && \
    rm google-chrome-stable_current_amd64.deb && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY <<'ENTRY' /usr/local/bin/browser-entry.sh
#!/usr/bin/env bash
exec xvfb-run --auto-servernum --server-args="-screen 0 1280x800x24" \
    google-chrome --no-sandbox --disable-dev-shm-usage --disable-gpu "\$@"
ENTRY
RUN chmod +x /usr/local/bin/browser-entry.sh

ENTRYPOINT ["/usr/local/bin/browser-entry.sh"]
EOF

echo "Building local Docker image 'hermes-browser-env' with Google Chrome..."
docker build -t hermes-browser-env "$BUILD_DIR"

# ------------------------------------------------------------------------------
# 4. Local Ollama Backend Configuration (Network Accessible)
# ------------------------------------------------------------------------------
echo "===> [4/7] Deploying Ollama LLM backend with network accessibility..."
if systemctl is-active --quiet ollama; then
    echo "Restarting Ollama service..."
    systemctl restart ollama
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
# 5. Hermes Agent Core, Config & Skills Hub Initialization
# ------------------------------------------------------------------------------
echo "===> [5/7] Installing Hermes Agent, writing routing config, and initializing Skills Hub..."
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
model:
  default: "$DEFAULT_GEMMA_MODEL"
  provider: custom
  base_url: "http://127.0.0.1:$OLLAMA_PORT/v1"
  api_key: \${HERMES_CUSTOM_127_0_0_1_11434_API_KEY}
agent:
  max_turns: 150
terminal:
  backend: docker
web:
  backend: ddgs
browser:
  cloud_provider: local
  image: hermes-browser-env
  headless: true
  no_sandbox: true
display:
  tool_progress: all
computer_use:
  backend: cua
proxy:
  enabled: false
_config_version: 39
session_reset:
  mode: none
custom_providers:
  - name: "Local (127.0.0.1:$OLLAMA_PORT)"
    base_url: "http://127.0.0.1:$OLLAMA_PORT/v1"
    key_env: "HERMES_CUSTOM_127_0_0_1_11434_API_KEY"
    model: "$DEFAULT_GEMMA_MODEL"
dashboard:
  host: "127.0.0.1"
  port: $HERMES_DASHBOARD_PORT
EOF

mkdir -p "$HERMES_HOME/skills"
export HOME="$STORAGE_ROOT"
hermes skills list --config-dir "$HERMES_CONFIG_DIR" >/dev/null 2>&1 || true

if systemctl is-active --quiet hermes-agent.service 2>/dev/null || systemctl is-enabled --quiet hermes-agent.service 2>/dev/null; then
    systemctl stop hermes-agent.service || true
    systemctl disable hermes-agent.service || true
    rm -f /etc/systemd/system/hermes-agent.service
fi

# ------------------------------------------------------------------------------
# 6. Dynamic Multi-SAN SSL Certificate Generation & Nginx Setup
# ------------------------------------------------------------------------------
echo "===> [6/7] Generating multi-SAN SSL certificates and configuring Nginx..."

SAN_EXT="subjectAltName=DNS:localhost,IP:127.0.0.1"
for entry in $SERVER_DOMAINS; do
    if [[ "$entry" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$entry" =~ : ]]; then
        SAN_EXT="${SAN_EXT},IP:$entry"
    else
        SAN_EXT="${SAN_EXT},DNS:$entry"
    fi
done

PRIMARY_NAME="$(echo "$SERVER_DOMAINS" | awk '{print $1}')"

if [[ ! -f "$CERT_DIR/server.crt" ]] || [[ ! -f "$CERT_DIR/server.key" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.crt" \
        -subj "/CN=$PRIMARY_NAME/O=HermesLocal/C=US" \
        -addext "$SAN_EXT" 2>/dev/null || \
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.crt" \
        -subj "/CN=$PRIMARY_NAME/O=HermesLocal/C=US"
    echo "Multi-SAN self-signed SSL certificate generated successfully."
else
    echo "Existing SSL certificates found in $CERT_DIR. Skipping generation."
fi

cat <<EOF > /etc/nginx/sites-available/hermes
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream hermes_dashboard {
    server 127.0.0.1:$HERMES_DASHBOARD_PORT;
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_DOMAINS localhost 127.0.0.1;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $SERVER_DOMAINS localhost 127.0.0.1;

    ssl_certificate $CERT_DIR/server.crt;
    ssl_certificate_key $CERT_DIR/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://hermes_dashboard;
        proxy_http_version 1.1;
        
        # Dynamic WebSocket support for live chat streaming
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        
        # Satisfy Hermes strict internal host and origin validation
        proxy_set_header Host 127.0.0.1:$HERMES_DASHBOARD_PORT;
        proxy_set_header Origin http://127.0.0.1:$HERMES_DASHBOARD_PORT;
        
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
# 7. Systemd Service Deployment & Restart
# ------------------------------------------------------------------------------
echo "===> [7/7] Configuring and restarting systemd service for Hermes Unified Dashboard..."
cat <<EOF > /etc/systemd/system/hermes-dashboard.service
[Unit]
Description=Hermes Agent Unified Web Dashboard Service
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
User=root
Environment="HOME=$STORAGE_ROOT"
Environment="HERMES_CONFIG_DIR=$HERMES_CONFIG_DIR"
Environment="HERMES_CUSTOM_127_0_0_1_11434_API_KEY=ollama"
Environment="OPENAI_API_BASE=http://127.0.0.1:$OLLAMA_PORT/v1"
ExecStart=/usr/local/bin/hermes dashboard --host 127.0.0.1 --port $HERMES_DASHBOARD_PORT --no-open
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hermes-dashboard.service
systemctl restart hermes-dashboard.service

if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp comment "HTTP (Redirect to HTTPS)"
    ufw allow 443/tcp comment "HTTPS (Hermes Web UI)"
    ufw allow "$OLLAMA_PORT/tcp" comment "Ollama Network API Access"
    ufw reload
fi

PRIMARY_IP="$(echo "$SYSTEM_IPS" | awk '{print $1}')"

echo "========================================================================"
echo "                   INSTALLATION COMPLETE SUCCESSFULLY!                  "
echo "========================================================================"
echo " Installer Version      : v$INSTALLER_VERSION"
echo " Storage Path Map       : $STORAGE_ROOT"
echo " Config Persistence     : $CONFIG_FILE"
echo " Allowed Domains/IPs    : $SERVER_DOMAINS"
echo " SSL Certificate Path   : $CERT_DIR/server.crt"
echo " Browser Container Image: hermes-browser-env (Google Chrome Stable)"
echo " Ollama API (LAN)       : http://$PRIMARY_IP:$OLLAMA_PORT"
echo " Hermes Dashboard (LAN) : https://$PRIMARY_NAME or https://$PRIMARY_IP"
echo "------------------------------------------------------------------------"
echo " CONFIGURATION NOTE:"
echo " You can edit '$CONFIG_FILE' at any time to add custom DNS names"
echo " or additional IPs. Re-running this script will preserve your customizations."
echo "========================================================================"