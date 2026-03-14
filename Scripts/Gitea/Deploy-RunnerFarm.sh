#!/bin/bash
# ==============================================================================
# File: DeployRunnerFarm.sh
# Description: Provisions an isolated, scalable farm of Gitea Actions Runners.
#              Connects to existing Gitea-Socket-Proxy.
#              Reads from existing Tier-3 Vault.
#              Pre-configured for Google Gemini API and GCloud execution.
# Security:    Treats all runners as ephemeral execution contexts.
# Author: Tier-3 Support
# ==============================================================================

set -e

# ------------------------------------------------------------------------------
# 1. Path Definition (PascalCase Enforced)
# ------------------------------------------------------------------------------
FARM_DIR="/opt/Docker/Stacks/RunnerFarm"
DATA_DIR="${FARM_DIR}/Data"
COMPOSE_FILE="${FARM_DIR}/DockerCompose.yml"
VAULT_TOKEN="/opt/Docker/Stacks/Gitea/secrets/gitea_runner_token.txt"

# ANSI Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}[INFO]${NC} Initializing Runner Farm Deployment..."

# ------------------------------------------------------------------------------
# 2. Dependency & Security Checks
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERR]${NC} Root privileges required to bind to Vault."
    exit 1
fi

if [ ! -f "$VAULT_TOKEN" ]; then
    echo -e "${RED}[ERR]${NC} Vault Token not found at ${VAULT_TOKEN}."
    echo "       Has the Gitea Monolith been fully deployed?"
    exit 1
fi

# Dynamically discover the Gitea internal bridge network
# This prevents hardcoding the compose project prefix (e.g., gitea-monolith vs gitea-controller)
GITEA_NET=$(docker network ls --format '{{.Name}}' | grep "gitea-net" | head -n 1)

if [ -z "$GITEA_NET" ]; then
    echo -e "${RED}[ERR]${NC} Could not locate the Gitea bridge network."
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Found upstream network: ${GITEA_NET}"

# ------------------------------------------------------------------------------
# 3. Directory Provisioning
# ------------------------------------------------------------------------------
mkdir -p "${DATA_DIR}/GeminiWorker"
mkdir -p "${DATA_DIR}/GCloudWorker"
mkdir -p "${DATA_DIR}/GenericWorker"

# Secure the data directories
chown -R 1000:1000 "${DATA_DIR}"
chmod 700 "${DATA_DIR}"

# ------------------------------------------------------------------------------
# 4. Compose Generation
# ------------------------------------------------------------------------------
# Security Warning: We map the Docker host to the Socket Proxy, NEVER the raw 
# /var/run/docker.sock. The labels define the ephemeral containers spawned.

cat > "$COMPOSE_FILE" <<EOF
name: runner-farm

secrets:
  gitea_runner_token:
    file: ${VAULT_TOKEN}

networks:
  gitea-core:
    external: true
    name: ${GITEA_NET}

services:
  # --------------------------------------------------------------------------
  # Worker 1: Google Gemini AI Integrations
  # --------------------------------------------------------------------------
  runner-gemini:
    image: gitea/act_runner:latest
    container_name: Runner-Gemini
    restart: unless-stopped
    environment:
      - GITEA_INSTANCE_URL=http://Gitea:3000
      - GITEA_RUNNER_REGISTRATION_TOKEN_FILE=/run/secrets/gitea_runner_token
      - GITEA_RUNNER_NAME=Worker-Gemini-Integration
      - DOCKER_HOST=tcp://Gitea-Socket-Proxy:2375
      # Routes Python/Node AI workflows to isolated images
      - GITEA_RUNNER_LABELS=gemini-python:docker://python:3.11-bookworm,gemini-node:docker://node:20-bookworm
    secrets:
      - gitea_runner_token
    volumes:
      - ${DATA_DIR}/GeminiWorker:/data
    networks:
      - gitea-core

  # --------------------------------------------------------------------------
  # Worker 2: Google Cloud Deployment Specialist
  # --------------------------------------------------------------------------
  runner-gcloud:
    image: gitea/act_runner:latest
    container_name: Runner-GCloud
    restart: unless-stopped
    environment:
      - GITEA_INSTANCE_URL=http://Gitea:3000
      - GITEA_RUNNER_REGISTRATION_TOKEN_FILE=/run/secrets/gitea_runner_token
      - GITEA_RUNNER_NAME=Worker-GCloud-Deploy
      - DOCKER_HOST=tcp://Gitea-Socket-Proxy:2375
      # Routes CI/CD deployments to Google Cloud SDK slim image
      - GITEA_RUNNER_LABELS=google-sdk:docker://google/cloud-sdk:slim
    secrets:
      - gitea_runner_token
    volumes:
      - ${DATA_DIR}/GCloudWorker:/data
    networks:
      - gitea-core

  # --------------------------------------------------------------------------
  # Worker 3: Generic Build Node
  # --------------------------------------------------------------------------
  runner-generic:
    image: gitea/act_runner:latest
    container_name: Runner-Generic
    restart: unless-stopped
    environment:
      - GITEA_INSTANCE_URL=http://Gitea:3000
      - GITEA_RUNNER_REGISTRATION_TOKEN_FILE=/run/secrets/gitea_runner_token
      - GITEA_RUNNER_NAME=Worker-Generic-Alpha
      - DOCKER_HOST=tcp://Gitea-Socket-Proxy:2375
      - GITEA_RUNNER_LABELS=ubuntu-latest:docker://node:18-bullseye,ubuntu-22.04:docker://ubuntu:22.04
    secrets:
      - gitea_runner_token
    volumes:
      - ${DATA_DIR}/GenericWorker:/data
    networks:
      - gitea-core
EOF

chmod 600 "$COMPOSE_FILE"

# ------------------------------------------------------------------------------
# 5. Execution
# ------------------------------------------------------------------------------
echo -e "${GREEN}[INFO]${NC} Spinning up Runner Farm..."
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans

echo -e "${GREEN}[OK]${NC} Runner Farm deployed. Awaiting Gitea handshake."