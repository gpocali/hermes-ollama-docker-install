# Hermes Agent + Local Ollama Docker Installer for Ubuntu Desktop

An automated, idempotent installation and upgrade utility designed for **Ubuntu Desktop 26.04 LTS**. This repository deploys a fully self-hosted, offline-capable AI environment combining **Hermes Agent** (by Nous Research), an isolated **Docker** execution backend, and a local **Ollama** LLM backend pre-configured with the latest **Gemma** model.

---

## Key Features

* **Dedicated `/storage` Partition Integration:** Maps all resource-heavy components (LLM model weights, Docker container layers, workspaces, and system configurations) directly onto `/storage` to prevent bloating your root system drive.
* **Isolated Docker Workspaces:** Configures Hermes' terminal and command execution engine to sandbox all agent workflows, code generation projects, and tools inside isolated Docker container runtimes.
* **Local Ollama Backend:** Automatically installs and binds Ollama to a custom storage path for model weights, downloading the latest **Gemma** model variant out-of-the-box.
* **Idempotent Update Safety:** Designed to run multiple times safely. Re-running the script updates existing installations (`pipx`, Docker images, and configuration maps) without wiping your operational data, custom memory states, or workspaces.
* **LAN Accessibility & Daemons:** Automatically handles UFW firewall rules for the local network (ports `11434` for Ollama and `8642` for the Hermes API Gateway) and registers native `systemd` services to guarantee zero-touch persistence across system reboots.

---

## System Requirements

* **OS:** Ubuntu Desktop 26.04 LTS (also compatible with 24.04 LTS)
* **Privileges:** `sudo` / Root access (required for systemd service creation, partition mounting checks, and dependency management)
* **Storage:** A dedicated partition or mount point prepared at `/storage`

---

## Installation

You can deploy the complete environment with a single terminal command. This downloads the script from your repository and pipes it securely into `bash`:

```bash
curl -fsSL https://raw.githubusercontent.com/gpocali/hermes-ollama-docker-install/main/install.sh | sudo bash

```

---

## What the Script Does Step-by-Step

1. **Environment Checks:** Validates root permissions and OS compatibility.
2. **Storage Layout Setup:** Verifies or creates the `/storage` directory framework (`/storage/hermes`, `/storage/ollama/models`, and `/storage/docker`).
3. **Dependency Management:** Installs essential utilities (`curl`, `wget`, `jq`, `ufw`), sets up the official Docker Engine repository, and enables the Docker daemon.
4. **Ollama & Gemma Configuration:** Installs Ollama, overrides its default storage path to point to `/storage/ollama/models`, binds it to `0.0.0.0:11434`, and pulls the latest `gemma3:latest` model.
5. **Hermes Agent Deployment:** Installs Python `pipx` and Hermes Agent, writing a localized `config.yaml` targeting the local Ollama backend and enforcing Docker container terminal sandboxing.
6. **Firewall & Services:** Opens necessary TCP ports (`11434` and `8642`) via UFW and registers a robust `systemd` service (`hermes-agent.service`) to keep the gateway running persistently on boot.

---

## Accessing Your Services

Once the script completes, your local AI infrastructure is accessible at the following endpoints:

* **Ollama LLM API:** `http://<your-ubuntu-ip>:11434`
* **Hermes Agent API Gateway:** `http://<your-ubuntu-ip>:8642`
* **Isolated Workspaces:** Located inside `/storage/hermes/workspaces`

---

## Updating Your Installation

To fetch updates or push configuration adjustments later, simply re-run the exact same command:

```bash
curl -fsSL https://raw.githubusercontent.com/gpocali/hermes-ollama-docker-install/main/install.sh | sudo bash

```

The installer will detect existing components, upgrade dependencies seamlessly, and preserve your stored models and configurations.