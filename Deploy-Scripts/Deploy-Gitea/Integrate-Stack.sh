#!/bin/bash
# ==============================================================================
# File: Integrate-Stack.sh
# Description: Day-2 Integration Patcher & Healer.
#              1. Syncs Gitea DB Password to Vault (Fixes Auth Failures).
#              2. Configures VS Code (SSH Keys/Git User).
#              3. Links VS Code to Gitea (API Key Upload).
#              4. Creates an AI-Workflow Demo Repo.
# Author: Tier-3 Support
# ==============================================================================

STACK_DIR="/opt/Docker/Stacks/Gitea"
SECRETS_DIR="${STACK_DIR}/secrets"

# ANSI Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_succ() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    log_err "Root required (to access secrets/docker)."
    exit 1
fi

# 1. Load & Sanitize Credentials
log_info "Loading Credentials from Vault..."
if [ ! -d "$SECRETS_DIR" ]; then
    log_err "Secrets directory not found."
    exit 1
fi

# Use tr -d '\n' to strip hidden newlines that break Basic Auth headers
ADMIN_USER=$(cat "${SECRETS_DIR}/gitea_admin_username.txt" | tr -d '\n')
ADMIN_PASS=$(cat "${SECRETS_DIR}/gitea_admin_password.txt" | tr -d '\n')
GITEA_URL="http://127.0.0.1:3000"

if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
    log_err "Credentials missing in vault."
    exit 1
fi

# 2. Force Credential Sync (The Fix for 'invalid username/password')
log_info "Synchronizing Database with Vault..."
if docker exec -u 1000 Gitea gitea admin user change-password --username "$ADMIN_USER" --password "$ADMIN_PASS" >/dev/null 2>&1; then
    log_succ "Admin password forcibly synced to Vault value."
else
    log_warn "Failed to sync password via CLI. API might fail if secrets are desynchronized."
fi

# 3. Configure Code-Server (VS Code)
if docker ps | grep -q "Code-Server"; then
    log_info "Configuring Code-Server Identity..."
    
    # Set Git Config (Global)
    docker exec -u abc Code-Server git config --global user.name "$ADMIN_USER"
    docker exec -u abc Code-Server git config --global user.email "${ADMIN_USER}@local.lan"
    docker exec -u abc Code-Server git config --global init.defaultBranch main
    log_succ "Git Global Config set."

    # Generate SSH Key (Idempotent)
    if ! docker exec -u abc Code-Server test -f /config/.ssh/id_ed25519; then
        log_info "Generating SSH Keypair..."
        docker exec -u abc Code-Server ssh-keygen -t ed25519 -C "${ADMIN_USER}@code-server" -f /config/.ssh/id_ed25519 -N "" >/dev/null 2>&1
        log_succ "SSH Key Generated."
    else
        log_info "SSH Key already exists."
    fi

    # Extract Public Key
    PUB_KEY=$(docker exec -u abc Code-Server cat /config/.ssh/id_ed25519.pub)
    
    # 4. Link to Gitea via API
    log_info "Registering SSH Key with Gitea..."
    
    # Wait for API availability
    sleep 2
    
    # Check if key exists (basic check)
    KEY_CHECK=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" "${GITEA_URL}/api/v1/user/keys")
    
    # Validate API Access first
    if echo "$KEY_CHECK" | grep -q "Unauthorized"; then
         log_err "API Authentication failed despite sync. Check server logs."
         exit 1
    fi

    if echo "$KEY_CHECK" | grep -q "Code-Server-Key"; then
        log_warn "SSH Key 'Code-Server-Key' already registered."
    else
        # Post Key
        RESPONSE=$(curl -s -X POST "${GITEA_URL}/api/v1/user/keys" \
            -H "Content-Type: application/json" \
            -u "${ADMIN_USER}:${ADMIN_PASS}" \
            -d "{\"title\": \"Code-Server-Key\", \"key\": \"$PUB_KEY\", \"read_only\": false}")
            
        if echo "$RESPONSE" | grep -q "\"id\":"; then
            log_succ "SSH Key successfully registered to Gitea user '$ADMIN_USER'."
        else
            log_err "Failed to register key. API Response: $RESPONSE"
        fi
    fi
else
    log_warn "Code-Server container not found. Skipping integration."
fi

# 5. Create AI Demo Repository
log_info "Creating AI-Enabled Demo Repository..."

REPO_NAME="ai-playground"
REPO_CHECK=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" "${GITEA_URL}/api/v1/repos/${ADMIN_USER}/${REPO_NAME}")

if echo "$REPO_CHECK" | grep -q "\"id\":"; then
    log_warn "Repository '$REPO_NAME' already exists."
else
    # Create Repo
    CREATE_RESP=$(curl -s -X POST "${GITEA_URL}/api/v1/user/repos" \
        -H "Content-Type: application/json" \
        -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -d "{\"name\": \"$REPO_NAME\", \"auto_init\": true, \"private\": false}")
        
    if echo "$CREATE_RESP" | grep -q "\"id\":"; then
        log_succ "Repository '$REPO_NAME' created."
        
        # 6. Inject AI Workflow
        log_info "Injecting Ollama Workflow..."
        
        # We assume the internal hostname 'ollama-worker' and port 11434
        # We use a very simple curl to prove connectivity in the pipeline
        WORKFLOW_CONTENT=$(cat <<EOF
name: AI Code Review
on: [push]
jobs:
  ai-review:
    runs-on: ubuntu-latest
    steps:
      - name: Check Ollama Status
        run: curl -s http://ollama-worker:11434/api/tags
      - name: Ask AI to Review
        run: |
          curl -X POST http://ollama-worker:11434/api/generate -d '{
            "model": "tinyllama",
            "prompt": "You are a code reviewer. Say 'Code looks good' if you receive this.",
            "stream": false
          }'
EOF
)
        # Base64 encode content for API
        B64_CONTENT=$(echo "$WORKFLOW_CONTENT" | base64 -w 0)
        
        # Commit File via API
        FILE_RESP=$(curl -s -X POST "${GITEA_URL}/api/v1/repos/${ADMIN_USER}/${REPO_NAME}/contents/.gitea/workflows/ai-test.yaml" \
            -H "Content-Type: application/json" \
            -u "${ADMIN_USER}:${ADMIN_PASS}" \
            -d "{\"content\": \"$B64_CONTENT\", \"message\": \"Add AI Workflow\", \"branch\": \"main\"}")
            
        if echo "$FILE_RESP" | grep -q "\"content\":"; then
            log_succ "Workflow injected. Check the 'Actions' tab in Gitea!"
        else
            log_err "Failed to inject workflow. Response: $FILE_RESP"
        fi
    else
        log_err "Failed to create repository. Response: $CREATE_RESP"
    fi
fi

echo "================================================"
echo "Integration Patch Complete."