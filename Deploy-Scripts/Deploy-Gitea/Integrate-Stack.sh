#!/bin/bash
# ==============================================================================
# File: Integrate-Stack.sh
# Description: Day-2 Integration Patcher & Healer (Rev 7 - SQL Override).
#              1. Syncs Gitea DB Password (CLI).
#              2. Clears Password Change Flag (Direct SQL).
#              3. Configures VS Code (Quiet Install).
#              4. Links VS Code to Gitea.
#              5. Creates AI Demo Repo.
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

# ------------------------------------------------------------------------------
# 1. Personalization Wizard
# ------------------------------------------------------------------------------
echo -e "${YELLOW}=== Stack Integration & Personalization ===${NC}"

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

# Check if user exists (CLI List usually works fine)
USER_CHECK=$(docker exec -u 1000 Gitea gitea admin user list -c /data/gitea/conf/app.ini 2>&1)

if echo "$USER_CHECK" | grep -q "$TARGET_USER"; then
    log_info "User '$TARGET_USER' exists. Starting Atomic Sync..."
    
    # 1. Update Password (CLI handles hashing correctly)
    CMD_OUT=$(docker exec -u 1000 Gitea gitea admin user change-password -c /data/gitea/conf/app.ini --username "$TARGET_USER" --password "$EXISTING_PASS" 2>&1)
    if [ $? -eq 0 ]; then
        log_succ "Password synced via CLI."
    else
        log_warn "Password sync issue: $CMD_OUT"
    fi
    
    # 2. SQL OVERRIDE: Clear 'Must Change Password' Flag & Set Email
    # Bypassing CLI 'modify' command which is proving unstable across versions
    log_info "Unlocking account via direct SQL..."
    
    # Update Email
    docker exec -u 1000 Gitea gitea db sql -c /data/gitea/conf/app.ini --query "UPDATE \"user\" SET email='$TARGET_EMAIL' WHERE name='$TARGET_USER';" >/dev/null 2>&1
    
    # Unlock Account
    docker exec -u 1000 Gitea gitea db sql -c /data/gitea/conf/app.ini --query "UPDATE \"user\" SET must_change_password=false, is_admin=true, is_active=true WHERE name='$TARGET_USER';" >/dev/null 2>&1
    
    log_succ "Account forced to: Active, Admin, Unlocked."

else
    log_info "Creating new Admin user '$TARGET_USER'..."
    # Creation usually works fine via CLI
    CMD_OUT=$(docker exec -u 1000 Gitea gitea admin user create -c /data/gitea/conf/app.ini --username "$TARGET_USER" --password "$EXISTING_PASS" --email "$TARGET_EMAIL" --admin --must-change-password=false 2>&1)
    if [ $? -eq 0 ]; then
        log_succ "User created."
    else
        log_err "User creation failed: $CMD_OUT"
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
        if docker exec Ollama-Worker ollama pull "$TARGET_MODEL"; then
            log_succ "Model pulled successfully."
        else
            log_err "Failed to pull model. Check network/storage."
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 4. VS Code Integration (Identity + Aider)
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
    
    # Pre-check keys
    EXISTING_KEYS=$(curl -s -u "${TARGET_USER}:${EXISTING_PASS}" "${GITEA_URL}/api/v1/user/keys")
    
    # Validate API Access (Did the SQL unlock work?)
    if echo "$EXISTING_KEYS" | grep -q "change_password"; then
         log_err "API Refused: Account still locked. SQL update may have failed."
         exit 1
    fi

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

    # --- AIDER INSTALLATION ---
    log_info "Injecting Aider (AI Partner) into VS Code..."
    
    # 1. Install Dependencies (Root) - QUIET MODE
    docker exec -u 0 -e DEBIAN_FRONTEND=noninteractive Code-Server bash -c "apt-get update -qq && apt-get install -y -qq python3-pip git > /dev/null"
    
    # 2. Install Aider (User)
    # Using --break-system-packages because this is an isolated container environment
    if docker exec -u abc -e DEBIAN_FRONTEND=noninteractive Code-Server pip3 install aider-chat --break-system-packages > /dev/null 2>&1; then
        log_succ "Aider installed successfully."
        
        # 3. Configure Shell Environment for Aider
        docker exec -u abc Code-Server sh -c "grep -q OLLAMA_API_BASE /config/.bashrc || echo 'export OLLAMA_API_BASE=http://ollama-worker:11434' >> /config/.bashrc"
        docker exec -u abc Code-Server sh -c "grep -q AIDER_MODEL /config/.bashrc || echo 'export AIDER_MODEL=ollama/${TARGET_MODEL}' >> /config/.bashrc"
        docker exec -u abc Code-Server sh -c "grep -q 'PATH.*local/bin' /config/.bashrc || echo 'export PATH=\$PATH:\$HOME/.local/bin' >> /config/.bashrc"
        
        log_info "Aider wired to http://ollama-worker:11434 using ${TARGET_MODEL}."
    else
        log_err "Aider installation failed."
    fi
else
    log_warn "Code-Server container not found. Skipping integration."
fi

# ------------------------------------------------------------------------------
# 5. AI Workflow Injection
# ------------------------------------------------------------------------------
log_info "Setting up Gitea Actions Integration..."

# Detect Network Name dynamically
NET_NAME=$(docker inspect Ollama-Worker --format '{{range $k, $v := .NetworkSettings.Networks}}{{printf "%s\n" $k}}{{end}}' | head -n 1)

REPO_NAME="ai-playground"
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
log_info "Generating CI/CD Workflow..."

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
      - name: Check Ollama Status
        run: curl -s http://ollama-worker:11434/api/tags
      - name: Request Review
        run: |
          curl -X POST http://ollama-worker:11434/api/generate -d '{
            "model": "${TARGET_MODEL}",
            "prompt": "You are a code reviewer. Review this commit.",
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
    log_succ "AI Workflow active."
elif echo "$FILE_RESP" | grep -q "exists"; then
    log_succ "Workflow already exists."
else
    log_warn "Workflow injection failed."
fi

echo "================================================"
echo "Integration Complete. To use Aider:"
echo "1. Open VS Code (Port 8443)"
echo "2. Open Terminal ('Ctrl+`')"
echo "3. Type: aider"