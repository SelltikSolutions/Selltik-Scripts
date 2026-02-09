#!/bin/bash
# ==============================================================================
# File: Integrate-Stack.sh
# Description: Day-2 Integration Patcher & Healer (Rev 4 - Personalization).
#              1. Interactive Identity & Model Wizard.
#              2. Deep Credential Sync (Vault + DB + Flag Clearing).
#              3. Workflow Injection with Dynamic Network Binding.
# Author: Tier-3 Support
# ==============================================================================

STACK_DIR="/opt/Docker/Stacks/Gitea"
SECRETS_DIR="${STACK_DIR}/secrets"
ENV_FILE="${STACK_DIR}/.env"

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
    log_err "Root required."
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Personalization Wizard
# ------------------------------------------------------------------------------
echo -e "${YELLOW}=== Stack Personalization ===${NC}"

# Load existing defaults
EXISTING_USER=$(cat "${SECRETS_DIR}/gitea_admin_username.txt" 2>/dev/null || echo "gitea_admin")
EXISTING_PASS=$(cat "${SECRETS_DIR}/gitea_admin_password.txt" 2>/dev/null)

read -p "Gitea Username [$EXISTING_USER]: " INPUT_USER
TARGET_USER=${INPUT_USER:-$EXISTING_USER}

read -p "Gitea Email [${TARGET_USER}@local.lan]: " INPUT_EMAIL
TARGET_EMAIL=${INPUT_EMAIL:-"${TARGET_USER}@local.lan"}

# Check if we need to update the vault
if [ "$TARGET_USER" != "$EXISTING_USER" ]; then
    log_info "Updating Vault with new username..."
    echo -n "$TARGET_USER" > "${SECRETS_DIR}/gitea_admin_username.txt"
fi

# Model Selection
DEFAULT_MODEL="qwen2.5-coder:14b"
read -p "AI Model to use [$DEFAULT_MODEL]: " INPUT_MODEL
TARGET_MODEL=${INPUT_MODEL:-$DEFAULT_MODEL}

# ------------------------------------------------------------------------------
# 2. Database Synchronization
# ------------------------------------------------------------------------------
log_info "Synchronizing User Database..."
GITEA_URL="http://127.0.0.1:3000"

# Check if user exists
USER_CHECK=$(docker exec -u 1000 Gitea gitea admin user list -c /data/gitea/conf/app.ini 2>&1)

if echo "$USER_CHECK" | grep -q "$TARGET_USER"; then
    log_info "User '$TARGET_USER' exists. Ensuring Admin privileges and Password sync..."
    
    # 1. Update Password
    docker exec -u 1000 Gitea gitea admin user change-password -c /data/gitea/conf/app.ini --username "$TARGET_USER" --password "$EXISTING_PASS" >/dev/null 2>&1
    
    # 2. CLEAR THE 'MUST CHANGE PASSWORD' FLAG (The Fix)
    docker exec -u 1000 Gitea gitea admin user modify -c /data/gitea/conf/app.ini --username "$TARGET_USER" --must-change-password=false --admin --email "$TARGET_EMAIL" >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        log_succ "User '$TARGET_USER' synchronized and unlocked."
    else
        log_err "Failed to modify user flags. API might fail."
    fi
else
    log_info "Creating new Admin user '$TARGET_USER'..."
    docker exec -u 1000 Gitea gitea admin user create -c /data/gitea/conf/app.ini --username "$TARGET_USER" --password "$EXISTING_PASS" --email "$TARGET_EMAIL" --admin --must-change-password=false >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_succ "User created."
    else
        log_err "User creation failed."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 3. Model Provisioning
# ------------------------------------------------------------------------------
if docker ps | grep -q "Ollama-Worker"; then
    log_info "Verifying AI Model '$TARGET_MODEL'..."
    AVAILABLE=$(docker exec Ollama-Worker ollama list)
    if echo "$AVAILABLE" | grep -q "$TARGET_MODEL"; then
        log_succ "Model '$TARGET_MODEL' is already available."
    else
        log_info "Pulling '$TARGET_MODEL' (This may take time)..."
        # Run pull in background? No, we need it for the test.
        if docker exec Ollama-Worker ollama pull "$TARGET_MODEL"; then
            log_succ "Model pulled successfully."
        else
            log_err "Failed to pull model. Check network/storage."
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 4. VS Code Integration
# ------------------------------------------------------------------------------
if docker ps | grep -q "Code-Server"; then
    log_info "Configuring VS Code Identity..."
    docker exec -u abc Code-Server git config --global user.name "$TARGET_USER"
    docker exec -u abc Code-Server git config --global user.email "$TARGET_EMAIL"
    docker exec -u abc Code-Server git config --global init.defaultBranch main
    
    # Generate Key
    if ! docker exec -u abc Code-Server test -f /config/.ssh/id_ed25519; then
        docker exec -u abc Code-Server ssh-keygen -t ed25519 -C "${TARGET_EMAIL}" -f /config/.ssh/id_ed25519 -N "" >/dev/null 2>&1
    fi
    PUB_KEY=$(docker exec -u abc Code-Server cat /config/.ssh/id_ed25519.pub)

    # API Upload
    log_info "Linking VS Code to Gitea..."
    sleep 2
    
    # Pre-check keys to avoid duplicates error
    EXISTING_KEYS=$(curl -s -u "${TARGET_USER}:${EXISTING_PASS}" "${GITEA_URL}/api/v1/user/keys")
    
    if echo "$EXISTING_KEYS" | grep -q "Code-Server-Key"; then
        log_succ "SSH Key already linked."
    else
        RESPONSE=$(curl -s -X POST "${GITEA_URL}/api/v1/user/keys" \
            -H "Content-Type: application/json" \
            -u "${TARGET_USER}:${EXISTING_PASS}" \
            -d "{\"title\": \"Code-Server-Key\", \"key\": \"$PUB_KEY\", \"read_only\": false}")
            
        if echo "$RESPONSE" | grep -q "\"id\":"; then
            log_succ "VS Code linked successfully."
        else
            log_warn "Key registration failed. Response: $RESPONSE"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 5. AI Workflow Injection
# ------------------------------------------------------------------------------
log_info "Setting up AI Integration..."

# Detect Network Name dynamically
NET_NAME=$(docker inspect Ollama-Worker --format '{{range $k, $v := .NetworkSettings.Networks}}{{printf "%s\n" $k}}{{end}}' | head -n 1)
log_info "Detected Network: $NET_NAME"

REPO_NAME="ai-playground"
# Check if Repo Exists
REPO_CHECK=$(curl -s -u "${TARGET_USER}:${EXISTING_PASS}" "${GITEA_URL}/api/v1/repos/${TARGET_USER}/${REPO_NAME}")

if ! echo "$REPO_CHECK" | grep -q "\"id\":"; then
    # Create Repo
    CREATE_RESP=$(curl -s -X POST "${GITEA_URL}/api/v1/user/repos" \
        -H "Content-Type: application/json" \
        -u "${TARGET_USER}:${EXISTING_PASS}" \
        -d "{\"name\": \"$REPO_NAME\", \"auto_init\": true, \"private\": false}")
        
    if ! echo "$CREATE_RESP" | grep -q "\"id\":"; then
        log_err "Failed to create repository."
        echo "Response: $CREATE_RESP"
        exit 1
    fi
    log_succ "Repository created."
fi

# Inject Workflow
log_info "Generating Workflow..."

# Note: We inject the 'container' options to attach the job to the stack's network
WORKFLOW_CONTENT=$(cat <<EOF
name: AI Analysis
on: [push]
jobs:
  code-review:
    runs-on: ubuntu-latest
    container:
      image: curlimages/curl:latest
      options: --network ${NET_NAME}
    steps:
      - name: Probe AI
        run: |
          echo "Connecting to Ollama on ${NET_NAME}..."
          curl -s -f http://ollama-worker:11434/api/tags
      - name: Request Review
        run: |
          curl -X POST http://ollama-worker:11434/api/generate -d '{
            "model": "${TARGET_MODEL}",
            "prompt": "Review this code commit: Empty Init.",
            "stream": false
          }'
EOF
)

B64_CONTENT=$(echo "$WORKFLOW_CONTENT" | base64 -w 0)

FILE_RESP=$(curl -s -X POST "${GITEA_URL}/api/v1/repos/${TARGET_USER}/${REPO_NAME}/contents/.gitea/workflows/ai-review.yaml" \
    -H "Content-Type: application/json" \
    -u "${TARGET_USER}:${EXISTING_PASS}" \
    -d "{\"content\": \"$B64_CONTENT\", \"message\": \"Enable AI Review\", \"branch\": \"main\"}")

if echo "$FILE_RESP" | grep -q "content"; then
    log_succ "AI Workflow active using model '$TARGET_MODEL'."
elif echo "$FILE_RESP" | grep -q "exists"; then
    log_succ "Workflow already exists."
else
    log_warn "Workflow injection failed (Is the repo empty?)."
fi

echo "================================================"
echo "Setup Complete."