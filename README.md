# Hermes Agent + Local Ollama Docker Installer for Ubuntu Desktop

An automated, idempotent installation and upgrade utility designed for **Ubuntu Desktop 26.04 LTS**. This repository deploys a fully self-hosted, offline-capable AI environment combining **Hermes Agent** (by Nous Research), an isolated **Docker** execution backend, and a local **Ollama** LLM backend pre-configured with the latest **Gemma 4 (12B)** model.

---

## Key Features

* **Dedicated `/storage` Partition Integration:** Maps all resource-heavy components (LLM model weights, Docker container layers, workspaces, and system configurations) directly onto `/storage` to prevent bloating your root system drive.
* **Isolated Docker Workspaces:** Configures Hermes' terminal and command execution engine to sandbox all agent workflows, code generation projects, and tools inside isolated Docker container runtimes.
* **Local Ollama Backend:** Automatically installs and binds Ollama to a custom storage path for model weights, downloading the optimized **Gemma 4 12B** model variant out-of-the-box.
* **Idempotent Update Safety:** Designed to run multiple times safely. Re-running the script updates existing installations without wiping your operational data, custom memory states, or workspaces.
* **Secure SSH Tunneling Access:** Binds the Hermes API Gateway securely to `127.0.0.1` and establishes a dedicated restricted system user (`hermes-remote`) with a secure SSH key pair. This enables encrypted local port-forwarding tunnels from remote client machines with zero exposure of raw HTTP ports to the public network.

---

## System Requirements

* **OS:** Ubuntu Desktop 26.04 LTS (also compatible with 24.04 LTS)
* **Privileges:** `sudo` / Root access (required for systemd service creation, partition mounting checks, and dependency management)
* **Storage:** A dedicated partition or mount point prepared at `/storage`

---

## Installation

Deploy the complete environment with a single terminal command on your Ubuntu machine. This downloads the script from your repository and pipes it securely into `bash`:

```bash
curl -fsSL https://raw.githubusercontent.com/gpocali/hermes-ollama-docker-install/main/install.sh | sudo bash

```

---

## Connecting Securely from a Windows Client

Once the installation completes, the script will output your secure API token and instructions. Follow these steps on your Windows machine to connect:

1. **Retrieve the Private Key:** Copy the contents of the generated private key file from the Ubuntu server (`/storage/hermes-remote/.ssh/id_ed25519_hermes`) and save it on your Windows machine at:
`C:\Users\<YourUsername>\.ssh\id_ed25519_hermes`
2. **Fix File Permissions (PowerShell):** Windows enforces strict permissions on SSH private keys. Run these commands in PowerShell:
```powershell
icacls "$HOME\.ssh\id_ed25519_hermes" /inheritance:r
icacls "$HOME\.ssh\id_ed25519_hermes" /grant:r "$($env:USERNAME):R"

```


3. **Configure Your SSH Config:** Open or create your client config file at `C:\Users\<YourUsername>\.ssh\config` and add the following entry:
```ssh
Host hermes-server
    HostName <server hostname>
    User hermes-remote
    IdentityFile C:/Users/<YourUsername>/.ssh/id_ed25519_hermes
    IdentitiesOnly yes

```


4. **Establish the Secure Tunnel:** Open a PowerShell terminal and run the local port-forwarding command:
```powershell
ssh -L 8642:127.0.0.1:8642 hermes-server

```


5. **Access Hermes:** Keep that terminal open, and access your Hermes Agent instance locally from your Windows client at:
* **URL:** `[http://127.0.0.1:8642](http://127.0.0.1:8642)`
* **Authentication:** Use the Bearer token generated during installation (displayed in your terminal summary).



---

## What the Script Does Step-by-Step

1. **Environment Checks:** Validates root permissions and OS compatibility.
2. **Storage Layout Setup:** Verifies or creates the `/storage` directory framework (`/storage/hermes`, `/storage/ollama/models`, and `/storage/docker`).
3. **Dependency Management:** Installs essential utilities (`curl`, `wget`, `jq`, `ufw`, `openssh-server`), sets up the official Docker Engine repository, and enables the daemon.
4. **Ollama & Gemma Configuration:** Installs Ollama, overrides its default storage path to point to `/storage/ollama/models`, binds it locally, and pulls the `gemma4:12b` model.
5. **Hermes Agent Deployment:** Installs Hermes Agent, writing a localized `config.yaml` targeting the local Ollama backend and enforcing Docker container terminal sandboxing alongside token authentication.
6. **SSH User & Daemons:** Creates the restricted `hermes-remote` user, generates the client key pair, locks down UFW firewall rules to allow only SSH traffic, and registers persistent `systemd` services.