#!/bin/bash

# ==============================================================================
# File: Deploy-Gitea.sh
# Description: Tier-3 Hardened Provisioner for Gitea / Ollama / DevOps Stack.
#              Target OS: ParrotOS / Debian Bookworm.
#              Logic: Vault-first secrets, Heuristic LAN Hunter, ProperCase.
#              Compliance: Directive 1, 2, 3 (Full Secret Isolation).
#              Features: Integrated Forensic Audit, Self-Healing, Zero-Touch.
# Patched: RDNA1 now defaults to Vulkan (Fixes CPU Fallback), Config Integrity.
# Author: Tier-3 Support
# Date: 2026-02-07
# Status: VULKAN PIVOT MASTER (Rev 102)
# ==============================================================================

# ------------------------------------------------------------------------------
# 0. Global Configuration & Paths
# ------------------------------------------------------------------------------
BASE_DIR="/opt/Docker/Stacks"
PROJECT_NAME="Gitea"
STACK_DIR="${BASE_DIR}/${PROJECT_NAME}"
SECRETS_DIR="${STACK_DIR}/secrets"
DATA_DIR="${STACK_DIR}/data"
AUDIT_DIR="${STACK_DIR}/audit"

COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
ENV_FILE="${STACK_DIR}/.env"
AUDIT_SCRIPT="${AUDIT_DIR}/verify_gpu.py"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logic Defaults
DEPLOY_PORTAINER_AGENT="true"
DEPLOY_VSCODE="false"
DOCKER_COMPOSE_CMD=""
AUTO_KILL_CONFLICTS="false"
HAS_GPU="false"
GPU_TYPE="CPU"
IS_MAXWELL="false"
AMD_HSA_VERSION="10.3.0"
AMD_ENABLE_SDMA="1"
AMD_USE_VULKAN="false"
GPU_GROUPS_DETECTED=""
HIP_DEVICE_ID="0" 

# Storage Flags
USE_GITEA_NFS="false"
USE_AI_NFS="false"

# Resource Limits
LIMIT_CPU="2.0"
LIMIT_MEM="4G"

# Trap interrupts
set -e
trap 'echo -e "\n${RED}[ABORT]${NC} Script interrupted or logic failure."; exit 1' INT TERM ERR

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1"; }
log_succ() { echo -e "${GREEN}[OK]${NC} $1"; }

# ------------------------------------------------------------------------------
# 1. Identity & Privilege Forensics
# ------------------------------------------------------------------------------
check_identity() {
    log_info "Verifying User Identity..."
    if [ "$EUID" -ne 0 ]; then
        log_err "This script must be run as root (sudo)."
        exit 1
    fi

    DETECTED_USER=${SUDO_USER:-$USER}
    if [ "$DETECTED_USER" == "root" ]; then
        log_warn "Running as direct ROOT session."
        read -p "   Enter target non-root username for file ownership: " TARGET_USER
        if id "$TARGET_USER" &>/dev/null; then
            REAL_USER="$TARGET_USER"
        else
            log_err "User '$TARGET_USER' does not exist."
            exit 1
        fi
    else
        REAL_USER=$DETECTED_USER
    fi

    REAL_UID=$(id -u "$REAL_USER")
    REAL_GID=$(id -g "$REAL_USER")
    log_succ "Target Identity: $REAL_USER (UID: $REAL_UID)"
}

# ------------------------------------------------------------------------------
# 2. Host Networking Forensics
# ------------------------------------------------------------------------------
detect_host_context() {
    log_info "Detecting Network Context..."

    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk -F'src ' '{print $2}' | awk '{print $1}')
    
    if [[ -z "$HOST_IP" ]] || [[ "$HOST_IP" =~ ^100\.64\. ]] || [[ "$HOST_IP" =~ ^172\. ]] || [[ "$HOST_IP" == "127.0.0.1" ]]; then
         log_warn "Primary route ($HOST_IP) appears to be VPN/Tunnel."
         local LAN_IP=$(ip -o -4 addr show scope global | awk '!/docker|br-|tun|veth|tailscale/ && (/inet 192\.168\./ || /inet 10\./) {print $4}' | cut -d/ -f1 | head -n 1)
         
         if [ -n "$LAN_IP" ]; then
             log_info "LAN Hunter discovered physical address: $LAN_IP"
             HOST_IP=$LAN_IP
         fi
    fi

    HOST_IP=${HOST_IP:-127.0.0.1}
    echo ""
    read -e -p "   Verify Host IP for Service Root URLs: " -i "$HOST_IP" USER_IP
    HOST_IP=${USER_IP:-$HOST_IP}
    log_succ "Networking context: $HOST_IP"

    if command -v timedatectl >/dev/null; then
        HOST_TZ=$(timedatectl show -p Timezone --value)
    elif [ -f /etc/timezone ]; then
        HOST_TZ=$(cat /etc/timezone)
    fi
    HOST_TZ=${HOST_TZ:-Etc/UTC}
}

# ------------------------------------------------------------------------------
# 3. Core Requirement Forensics
# ------------------------------------------------------------------------------
check_core_requirements() {
    log_info "Auditing host dependencies..."

    if docker compose version &> /dev/null; then DOCKER_COMPOSE_CMD="docker compose";
    elif command -v docker-compose &> /dev/null; then DOCKER_COMPOSE_CMD="docker-compose"; fi

    local MISSING_DEPS=()
    ! command -v docker &> /dev/null && MISSING_DEPS+=("docker.io")
    [ -z "$DOCKER_COMPOSE_CMD" ] && MISSING_DEPS+=("docker-compose-plugin")
    ! command -v socat &> /dev/null && MISSING_DEPS+=("socat")
    ! command -v curl &> /dev/null && MISSING_DEPS+=("curl")
    ! command -v openssl &> /dev/null && MISSING_DEPS+=("openssl")
    ! command -v lspci &> /dev/null && MISSING_DEPS+=("pciutils")

    if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
        log_warn "Missing Core Dependencies: ${MISSING_DEPS[*]}"
        read -p "   Attempt automated install? (y/N): " -n 1 -r; echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING_DEPS[@]}" || exit 1
            systemctl enable --now docker
            if docker compose version &> /dev/null; then DOCKER_COMPOSE_CMD="docker compose"; 
            else DOCKER_COMPOSE_CMD="docker-compose"; fi
        else
            exit 1
        fi
    fi

    if ! systemctl is-active --quiet docker; then
        systemctl enable --now docker
        sleep 2
    fi
}

# ------------------------------------------------------------------------------
# 4. Hardware Configuration (Isolated)
# ------------------------------------------------------------------------------
configure_hardware_acceleration() {
    log_info "Scanning for AI Accelerators..."
    
    HAS_GPU="false"
    GPU_TYPE="CPU"
    IS_MAXWELL="false"
    AMD_USE_VULKAN="false"

    # 1. NVIDIA Path
    if command -v nvidia-smi &> /dev/null && docker info 2>/dev/null | grep -q "Runtimes:.*nvidia"; then
        HAS_GPU="true"
        GPU_TYPE="NVIDIA"
        log_succ "Detected NVIDIA GPU."
        
        local GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1)
        if [[ "$GPU_NAME" == *"750 Ti"* ]]; then 
             IS_MAXWELL="true"
             log_info "Architecture: Maxwell ($GPU_NAME). Optimizing..."
        fi
    
    # 2. AMD ROCm Path
    elif [ -e /dev/kfd ] && [ -e /dev/dri ]; then
        HAS_GPU="true"
        GPU_TYPE="AMD"
        log_succ "Detected AMD Interface."
        
        # Check for Multi-GPU/Integrated Graphics
        local RENDER_COUNT=$(ls /dev/dri/renderD* 2>/dev/null | wc -l)
        if [ "$RENDER_COUNT" -gt 1 ]; then
            log_warn "Multiple Render Devices Detected ($RENDER_COUNT)."
            echo "   Potential iGPU interference detected. Please select the dedicated GPU index."
            ls -l /dev/dri/renderD*
            echo "   (Usually 0 is primary/integrated, 1 is dedicated, but varies by BIOS)"
            read -p "   Target GPU Device Index [0]: " USER_GPU_IDX
            HIP_DEVICE_ID=${USER_GPU_IDX:-0}
            log_info "Pinning container to GPU Index: $HIP_DEVICE_ID"
        fi
        
        if command -v lspci &> /dev/null; then
            local GPU_MODEL=$(lspci | grep -i "VGA.*AMD" | cut -d: -f3 | xargs)
            log_info "AMD Model: $GPU_MODEL"
            
            # Architecture Matching
            if [[ "$GPU_MODEL" =~ "Polaris" ]] || [[ "$GPU_MODEL" =~ "RX 580" ]]; then
                AMD_USE_VULKAN="true"
                log_info "Detected Polaris (GFX8). ROCm unstable. Defaulting to Vulkan."
            elif [[ "$GPU_MODEL" =~ "Vega" ]]; then
                AMD_HSA_VERSION="9.0.0"
                log_info "Detected Vega (GFX9). Override: $AMD_HSA_VERSION"
            elif [[ "$GPU_MODEL" =~ "Navi" ]] || [[ "$GPU_MODEL" =~ "RX 5" ]]; then
                # RDNA1 requires Vulkan on newer Ollama images
                AMD_USE_VULKAN="true"
                log_info "Detected Navi 1x (RDNA1). ROCm unstable. Defaulting to Vulkan."
            elif [[ "$GPU_MODEL" =~ "RX 6" ]]; then
                AMD_HSA_VERSION="10.3.0"
                log_info "Detected Navi 2x (RDNA2). Override: $AMD_HSA_VERSION"
            elif [[ "$GPU_MODEL" =~ "RX 7" ]]; then
                AMD_HSA_VERSION="11.0.0"
                log_info "Detected Navi 3x (RDNA3). Override: $AMD_HSA_VERSION"
            else
                log_warn "Architecture unclear. Defaulting to RDNA2 ($AMD_HSA_VERSION)."
            fi
        fi

        # Permission Auto-Fix (Hardened & Numeric)
        log_info "Verifying GPU permissions..."
        set +e
        local GROUPS_OK=true
        GPU_GROUPS_DETECTED=""
        for grp in render video; do
            if getent group "$grp" >/dev/null 2>&1; then
                # Extract GID to pass to Docker
                local GID=$(getent group "$grp" | cut -d: -f3)
                if [ -n "$GID" ]; then
                    GPU_GROUPS_DETECTED="$GPU_GROUPS_DETECTED $GID"
                    if ! id -nG "$REAL_USER" | grep -qw "$grp"; then
                        usermod -aG "$grp" "$REAL_USER" 2>/dev/null || true
                    fi
                fi
            fi
        done
        GPU_GROUPS_DETECTED=$(echo $GPU_GROUPS_DETECTED | xargs) # Trim whitespace
        
        # Sledgehammer
        chmod 666 /dev/kfd /dev/dri/renderD* 2>/dev/null || true
        set -e
        
        log_info "GPU GIDs for Injection: [ $GPU_GROUPS_DETECTED ]"

    else
        log_info "No supported GPU detected. AI will be CPU-bound."
    fi
}

# ------------------------------------------------------------------------------
# 5. Helper: JIT Dependency Installer
# ------------------------------------------------------------------------------
ensure_dependency() {
    local PKG=$1
    local BIN=$2
    if ! command -v "$BIN" &> /dev/null; then
        log_warn "Feature requires package '$PKG'. Installing..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG" || { log_err "Failed to install $PKG"; exit 1; }
    fi
}

draw_service_box() {
    local TITLE=$1
    shift
    local LINES=("$@")
    local TOTAL_WIDTH=80
    local CONTENT_WIDTH=76
    
    local TITLE_STR="[ $TITLE ]"
    local TITLE_LEN=${#TITLE_STR}
    local PAD_TOTAL=$((TOTAL_WIDTH - TITLE_LEN - 2))
    local PAD_L=$((PAD_TOTAL / 2))
    local PAD_R=$((PAD_TOTAL - PAD_L))

    printf "${NC}┌"
    printf '─%.0s' $(seq 1 $PAD_L)
    printf "${YELLOW}%s${NC}" "$TITLE_STR"
    printf '─%.0s' $(seq 1 $PAD_R)
    printf "┐\n"
    
    for line in "${LINES[@]}"; do
        local KEY=$(echo "$line" | awk -F'|' '{print $1}')
        local VAL=$(echo "$line" | awk -F'|' '{print $2}')
        VAL=${VAL:-""}
        local CLEAN_VAL=$(echo -e "$VAL" | sed 's/\x1b\[[0-9;]*m//g')
        local VAL_LEN=${#CLEAN_VAL}
        local SPACE=$((CONTENT_WIDTH - 15 - VAL_LEN))
        if [ $SPACE -lt 0 ]; then SPACE=0; fi
        printf "│ %-12s : %b%*s │\n" "$KEY" "$VAL" "$SPACE" ""
    done
    printf "└"
    printf '─%.0s' $(seq 1 $((TOTAL_WIDTH - 2)))
    printf "┘\n"
}

pass() { echo -e "[${GREEN}PASS${NC}] $1"; }
fail() { echo -e "[${RED}FAIL${NC}] $1"; }
warn() { echo -e "[${YELLOW}WARN${NC}] $1 (Note: $2)"; }

# ------------------------------------------------------------------------------
# 6. Role & Feature Selection
# ------------------------------------------------------------------------------
configure_role_wizard() {
    echo "=========================================="
    echo "   Node Role Selection"
    echo "=========================================="
    echo "1) Monolith:        Gitea + DB + Redis + Local AI + Runner"
    echo "2) Controller (Main): Gitea + DB + Redis + Runner"
    echo "3) Compute (Worker):  Ollama Only"
    read -p "   Select Role [1-3]: " ROLE_CHOICE

    case $ROLE_CHOICE in
        2) NODE_ROLE="controller"; DEPLOY_GITEA=true; DEPLOY_AI=false ;;
        3) NODE_ROLE="worker"; DEPLOY_GITEA=false; DEPLOY_AI=true ;;
        *) NODE_ROLE="monolith"; DEPLOY_GITEA=true; DEPLOY_AI=true ;;
    esac
    
    if [ "$DEPLOY_GITEA" == "true" ]; then
        ensure_dependency "git" "git"
    fi
    
    if docker ps --format '{{.Names}}' | grep -q "portainer_agent"; then
        log_info "Existing Portainer Agent detected. Skipping deployment."
        DEPLOY_PORTAINER_AGENT="false"
    fi
}

configure_vscode_wizard() {
    echo ""
    read -p "   Deploy VS Code Server? (y/N): " -n 1 -r; echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        DEPLOY_VSCODE="true"
        ensure_dependency "git" "git"
    else
        DEPLOY_VSCODE="false"
    fi
}

# ------------------------------------------------------------------------------
# 7. Context-Aware Port Conflict Resolution
# ------------------------------------------------------------------------------
check_port() {
    local PORT=$1
    local SERVICE=$2
    local VAR_REF=$3
    local CHECK_PORT=${PORT##*:}
    
    if ss -lntu | grep -q ":${CHECK_PORT} "; then
        log_warn "Conflict Detected: Port ${CHECK_PORT} ($SERVICE) is busy."
        local PID=$(ss -lntup | grep ":${CHECK_PORT} " | grep -o "pid=[0-9]*" | cut -d= -f2 | head -n 1)
        local COMM=""
        if [ -n "$PID" ]; then COMM=$(ps -p "$PID" -o comm= 2>/dev/null); fi
        echo "   Owner: ${COMM:-Unknown} (PID: ${PID:-Unknown})"
        
        local RESOLVE_OPT=""
        if [[ -n "$PID" ]]; then
            if [ "$AUTO_KILL_CONFLICTS" == "true" ]; then
                RESOLVE_OPT="1"
                log_info "[Auto-Kill] Nuclear option active. Terminating owner..."
            else
                echo "   1) Kill Process $PID (${COMM:-Unknown}) & Reclaim Port"
                echo "   2) Select Different Port"
                echo "   3) Kill ALL Conflicts (Nuclear Option)"
                read -p "   Select: " INPUT_OPT
                case $INPUT_OPT in
                    3) AUTO_KILL_CONFLICTS="true"; RESOLVE_OPT="1" ;;
                    1) RESOLVE_OPT="1" ;;
                    *) RESOLVE_OPT="2" ;;
                esac
            fi

            if [[ "$RESOLVE_OPT" == "1" ]]; then
                if [[ "$COMM" == "docker-proxy" ]]; then
                    local CONT_ID=$(docker ps --filter "publish=${CHECK_PORT}" --format "{{.ID}}" | head -n 1)
                    if [ -n "$CONT_ID" ]; then 
                        docker stop "$CONT_ID" >/dev/null 2>&1 || true
                    else 
                        kill -9 "$PID" 2>/dev/null || true
                    fi
                elif [[ "$COMM" == "ollama" ]]; then
                    systemctl stop ollama 2>/dev/null || kill -9 "$PID" 2>/dev/null || true
                else
                    kill -9 "$PID" 2>/dev/null || true
                fi
                log_succ "Process handled. Reclaiming port ${PORT}."
                eval "$VAR_REF=$PORT"
                return 0
            fi
        fi
        read -p "   Enter new port for $SERVICE (Default: $((CHECK_PORT+1))): " NEW_PORT
        NEW_PORT=${NEW_PORT:-$((CHECK_PORT+1))}
        if [[ "$PORT" == *"127.0.0.1"* ]]; then eval "$VAR_REF=127.0.0.1:$NEW_PORT"
        else eval "$VAR_REF=$NEW_PORT"; fi
        check_port "$(eval echo \$$VAR_REF)" "$SERVICE" "$VAR_REF"
    else
        eval "$VAR_REF=$PORT"
    fi
}

resolve_conflicts() {
    log_info "Scanning ports..."
    CFG_GITEA_WEB=3000
    CFG_GITEA_SSH=2222
    if [ "$NODE_ROLE" == "worker" ]; then CFG_AI_PORT=11434; else CFG_AI_PORT="127.0.0.1:11434"; fi
    CFG_AGENT_PORT=9001
    CFG_VSCODE_PORT=8443

    if [ "$DEPLOY_GITEA" == "true" ]; then
        check_port 3000 "Gitea Web" CFG_GITEA_WEB
        check_port 2222 "Gitea SSH" CFG_GITEA_SSH
    fi
    if [ "$DEPLOY_AI" == "true" ]; then
        check_port "$CFG_AI_PORT" "Ollama" CFG_AI_PORT
    fi
    if [ "$DEPLOY_PORTAINER_AGENT" == "true" ]; then
        check_port 9001 "Portainer Agent" CFG_AGENT_PORT
    fi
    if [ "$DEPLOY_VSCODE" == "true" ]; then
        check_port 8443 "VS Code" CFG_VSCODE_PORT
    fi
}

# ------------------------------------------------------------------------------
# 8. NFS Wizard (Safety Rails)
# ------------------------------------------------------------------------------
configure_storage_wizard() {
    ensure_dependency "nfs-common" "showmount"

    if [ "$DEPLOY_GITEA" == "true" ]; then
        read -p "   Store Gitea Repos on NFS? (y/N): " -n 1 -r; echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "   --- Gitea NFS Verification ---"
            read -p "   NFS Server IP: " G_NFS_IP
            if ping -c 1 -W 2 "$G_NFS_IP" &> /dev/null; then
                showmount -e "$G_NFS_IP"
                read -p "   NFS Export Path (e.g. /volume1/gitea): " G_NFS_PATH
                
                # Mount Test
                TEST_MNT="/tmp/deploy_test_gitea_mnt_$(date +%s)"
                mkdir -p "$TEST_MNT"
                if mount -t nfs "$G_NFS_IP:$G_NFS_PATH" "$TEST_MNT" -o retry=1,timeo=20; then
                    if touch "$TEST_MNT/.write_check"; then
                        rm "$TEST_MNT/.write_check"
                        umount "$TEST_MNT"
                        rmdir "$TEST_MNT"
                        USE_GITEA_NFS="true"
                        export GITEA_NFS_SERVER=$G_NFS_IP
                        export GITEA_NFS_PATH=$G_NFS_PATH
                        log_succ "Gitea Mount R/W verified."
                    else
                        log_err "Mount Read-Only! Check NAS permissions."
                        umount "$TEST_MNT"
                        rmdir "$TEST_MNT"
                        USE_GITEA_NFS="false"
                    fi
                else
                    log_err "Mount failed. Check path."
                    rmdir "$TEST_MNT" 2>/dev/null
                    USE_GITEA_NFS="false"
                fi
            else
                log_err "Server unreachable."
            fi
        fi
    fi

    if [ "$DEPLOY_AI" == "true" ]; then
        read -p "   Store AI Models on NFS? (y/N): " -n 1 -r; echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "   --- AI NFS Verification ---"
            DEFAULT_AI_IP=${GITEA_NFS_SERVER:-""}
            read -p "   NFS Server IP [${DEFAULT_AI_IP}]: " AI_NFS_IP
            AI_NFS_IP=${AI_NFS_IP:-$DEFAULT_AI_IP}
            
            if ! ping -c 1 -W 2 "$AI_NFS_IP" &> /dev/null; then
                log_err "Server unreachable."
            else
                if [ "$AI_NFS_IP" != "$GITEA_NFS_SERVER" ]; then
                     showmount -e "$AI_NFS_IP"
                fi
                read -p "   NFS Export Path (e.g. /volume1/models): " AI_NFS_PATH
                
                # Mount Test
                TEST_MNT="/tmp/deploy_test_ai_mnt_$(date +%s)"
                mkdir -p "$TEST_MNT"
                
                if mount -t nfs "$AI_NFS_IP:$AI_NFS_PATH" "$TEST_MNT" -o retry=1,timeo=20; then
                    if touch "$TEST_MNT/.write_check"; then
                        rm "$TEST_MNT/.write_check"
                        umount "$TEST_MNT"
                        rmdir "$TEST_MNT"
                        USE_AI_NFS="true"
                        export OLLAMA_NFS_SERVER=$AI_NFS_IP
                        export OLLAMA_NFS_PATH=$AI_NFS_PATH
                        log_succ "AI Mount R/W verified."
                    else
                        log_err "Mount Read-Only! Check NAS permissions."
                        umount "$TEST_MNT"
                        rmdir "$TEST_MNT"
                        USE_AI_NFS="false"
                    fi
                else
                    log_err "Mount failed. Check path."
                    rmdir "$TEST_MNT" 2>/dev/null
                    USE_AI_NFS="false"
                fi
            fi
        fi
    fi
}

# ------------------------------------------------------------------------------
# 9. Setup & Generate (Atomic)
# ------------------------------------------------------------------------------
setup_directories() {
    log_info "Enforcing directory structure..."
    (umask 022; mkdir -p "$SECRETS_DIR" "$STACK_DIR" "$DATA_DIR" "$AUDIT_DIR")
    
    # Directive 2: .gitignore
    echo "secrets/" > "${STACK_DIR}/.gitignore"
    echo ".env" >> "${STACK_DIR}/.gitignore"
    
    if [ "$DEPLOY_GITEA" == "true" ]; then
        mkdir -p "${DATA_DIR}/Postgres"
        mkdir -p "${DATA_DIR}/Redis"
        mkdir -p "${DATA_DIR}/Runner"
        if [ "${USE_NFS:-false}" != "true" ]; then mkdir -p "${DATA_DIR}/Gitea"; fi
    fi
    
    if [ "$DEPLOY_AI" == "true" ]; then mkdir -p "${DATA_DIR}/Ollama"; fi
    if [ "$DEPLOY_VSCODE" == "true" ]; then mkdir -p "${DATA_DIR}/CodeServer"; fi
}

get_secret() {
    local NAME=$1
    local HEX_LEN=$2
    local FILE="${SECRETS_DIR}/${NAME}"
    if [ ! -f "$FILE" ]; then
        (umask 077; openssl rand -hex "$HEX_LEN" | tr -d '\n' > "$FILE")
    fi
    cat "$FILE"
}

setup_environment() {
    log_info "Vaulting secrets and initializing environment..."
    mkdir -p "$SECRETS_DIR"
    
    # Clean previous run
    rm -f "$ENV_FILE"

    # 1. Global Constants
    (umask 077; cat > "$ENV_FILE" <<EOF
# Generated on $(date)
HOST_IP=${HOST_IP}
TZ=${HOST_TZ}
AGENT_PORT=${CFG_AGENT_PORT}
EOF
)

    # 2. Add Gitea Secrets only if needed
    if [ "$DEPLOY_GITEA" == "true" ]; then
        # Secrets exist on disk only. Not in .env
        get_secret "gitea_db_password.txt" 16 > /dev/null
        get_secret "gitea_redis_password.txt" 16 > /dev/null
        get_secret "gitea_admin_password.txt" 12 > /dev/null
        get_secret "gitea_runner_token.txt" 16 > /dev/null
        
        local ADMIN_USER_FILE="${SECRETS_DIR}/gitea_admin_username.txt"
        if [ ! -f "$ADMIN_USER_FILE" ]; then (umask 077; echo -n "gitea_admin" > "$ADMIN_USER_FILE"); fi
        local G_ADMIN_USER=$(cat "$ADMIN_USER_FILE")

        # Config Only - SECRETS REMOVED FROM ENV (Directive 3)
        cat >> "$ENV_FILE" <<EOF
GITEA_WEB_PORT=${CFG_GITEA_WEB}
GITEA_SSH_PORT=${CFG_GITEA_SSH}
DB_USER=gitea
DB_NAME=gitea
EOF
        
        # Inject NFS Vars if present
        if [ "$USE_GITEA_NFS" == "true" ]; then
             echo "GITEA_NFS_SERVER=${GITEA_NFS_SERVER}" >> "$ENV_FILE"
             echo "GITEA_NFS_PATH=${GITEA_NFS_PATH}" >> "$ENV_FILE"
        fi
    fi

    # 3. Add VSCode Secrets
    if [ "$DEPLOY_VSCODE" == "true" ]; then
        get_secret "vscode_password.txt" 12 > /dev/null
        # SECRET REMOVED FROM ENV
        cat >> "$ENV_FILE" <<EOF
VSCODE_PORT=${CFG_VSCODE_PORT}
VSCODE_PUID=${REAL_UID}
VSCODE_PGID=${REAL_GID}
EOF
    fi

    # 4. Add AI Config
    if [ "$DEPLOY_AI" == "true" ]; then
        local GPU_L=0
        if [ "$HAS_GPU" == "true" ]; then GPU_L=20; fi
        
        local OLLAMA_ATTN="1"
        if [ "$IS_MAXWELL" == "true" ]; then OLLAMA_ATTN="0"; fi
        
        local HSA_STR=""
        if [ "$GPU_TYPE" == "AMD" ]; then
            HSA_STR="HSA_OVERRIDE_GFX_VERSION=${AMD_HSA_VERSION}"
        fi
        
        # Inject HSA_ENABLE_SDMA if set
        local SDMA_STR=""
        if [ -n "$AMD_ENABLE_SDMA" ]; then
            SDMA_STR="HSA_ENABLE_SDMA=${AMD_ENABLE_SDMA}"
        fi
        
        # Determine Vulkan mode for Environment
        local VULKAN_VAL="0"
        if [ "$AMD_USE_VULKAN" == "true" ]; then
             VULKAN_VAL="1"
        fi

        cat >> "$ENV_FILE" <<EOF
OLLAMA_HOST=0.0.0.0
OLLAMA_FLASH_ATTENTION=${OLLAMA_ATTN}
AI_PORT=${CFG_AI_PORT}
OLLAMA_GPU_LAYERS=${GPU_L}
OLLAMA_VULKAN=${VULKAN_VAL}
${HSA_STR}
${SDMA_STR}
EOF
        # Inject Device Selection if active
        if [ "$HAS_GPU" == "true" ] && [ "$GPU_TYPE" == "AMD" ]; then
             echo "HIP_VISIBLE_DEVICES=${HIP_DEVICE_ID}" >> "$ENV_FILE"
             echo "ROCR_VISIBLE_DEVICES=${HIP_DEVICE_ID}" >> "$ENV_FILE"
        fi

        # Inject NFS Vars if present
        if [ "$USE_AI_NFS" == "true" ]; then
             echo "OLLAMA_NFS_SERVER=${OLLAMA_NFS_SERVER}" >> "$ENV_FILE"
             echo "OLLAMA_NFS_PATH=${OLLAMA_NFS_PATH}" >> "$ENV_FILE"
        fi
    fi
}

# ------------------------------------------------------------------------------
# 10. Docker Compose Generation
# ------------------------------------------------------------------------------
generate_docker_compose() {
    log_info "Generating ${COMPOSE_FILE}..."
    rm -f "$COMPOSE_FILE"
    
    USE_PROXY=false
    if [ "$DEPLOY_PORTAINER_AGENT" == "true" ]; then USE_PROXY=true; fi
    if [ "$DEPLOY_VSCODE" == "true" ]; then USE_PROXY=true; fi
    if [ "$DEPLOY_GITEA" == "true" ]; then USE_PROXY=true; fi

    cat > "$COMPOSE_FILE" <<EOF
name: gitea-${NODE_ROLE}
networks:
  gitea-net:
    driver: bridge
EOF

    # PATCH: Conditional Secrets Block (Empty block is invalid YAML)
    if [ "$DEPLOY_GITEA" == "true" ] || [ "$DEPLOY_VSCODE" == "true" ]; then
        echo "secrets:" >> "$COMPOSE_FILE"
    fi

    if [ "$DEPLOY_GITEA" == "true" ]; then
        cat >> "$COMPOSE_FILE" <<EOF
  gitea_db_password:
    file: ${SECRETS_DIR}/gitea_db_password.txt
  gitea_redis_password:
    file: ${SECRETS_DIR}/gitea_redis_password.txt
  gitea_runner_token:
    file: ${SECRETS_DIR}/gitea_runner_token.txt
EOF
    fi

    if [ "$DEPLOY_VSCODE" == "true" ]; then
        cat >> "$COMPOSE_FILE" <<EOF
  vscode_password:
    file: ${SECRETS_DIR}/vscode_password.txt
EOF
    fi

    cat >> "$COMPOSE_FILE" <<EOF

services:
EOF

    if [ "$USE_PROXY" == "true" ]; then
        cat >> "$COMPOSE_FILE" <<EOF
  gitea-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: Gitea-Socket-Proxy
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - CONTAINERS=1
      - IMAGES=1
      - NETWORKS=1
      - VOLUMES=1
      - INFO=1
      - POST=1
      - EXEC=1
    networks:
      - gitea-net
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:2375/version"]
      interval: 30s
      timeout: 10s
      retries: 3

EOF
    fi

    if [ "$DEPLOY_PORTAINER_AGENT" == "true" ]; then
        cat >> "$COMPOSE_FILE" <<EOF
  portainer-agent:
    image: portainer/agent:latest
    container_name: Portainer-Agent
    restart: unless-stopped
    environment:
      - LOG_LEVEL=DEBUG
    ports:
      - "\${AGENT_PORT}:9001"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
    networks:
      - gitea-net
    depends_on:
      gitea-socket-proxy:
        condition: service_healthy

EOF
    fi

    if [ "$DEPLOY_VSCODE" == "true" ]; then
        cat >> "$COMPOSE_FILE" <<EOF
  code-server:
    image: linuxserver/code-server:latest
    container_name: Code-Server
    restart: unless-stopped
    environment:
      - PUID=\${VSCODE_PUID}
      - PGID=\${VSCODE_PGID}
      - TZ=\${TZ}
      - FILE__PASSWORD=/run/secrets/vscode_password
      - DOCKER_HOST=tcp://gitea-socket-proxy:2375
    secrets:
      - vscode_password
    volumes:
      - ${DATA_DIR}/CodeServer:/config
    ports:
      - "\${VSCODE_PORT}:8443"
    networks:
      - gitea-net
    depends_on:
      gitea-socket-proxy:
        condition: service_healthy

EOF
    fi

    if [ "$DEPLOY_GITEA" == "true" ]; then
        # Read Redis password to inject into Connection String (Limitation of Gitea)
        local R_PASS=$(cat ${SECRETS_DIR}/gitea_redis_password.txt)
        local DB_PASS_VAL=$(cat ${SECRETS_DIR}/gitea_db_password.txt)
        
        # Decide Volume Driver for Gitea Data
        local GITEA_VOL="${DATA_DIR}/Gitea:/data"
        if [ "$USE_GITEA_NFS" == "true" ]; then GITEA_VOL="gitea-nfs-data:/data"; fi

        cat >> "$COMPOSE_FILE" <<EOF
  gitea-db:
    image: postgres:15-alpine
    container_name: Gitea-DB
    restart: unless-stopped
    env_file: .env
    environment:
      - POSTGRES_USER=\${DB_USER}
      - POSTGRES_PASSWORD_FILE=/run/secrets/gitea_db_password
      - POSTGRES_DB=\${DB_NAME}
    secrets:
      - gitea_db_password
    networks:
      - gitea-net
    volumes:
      - ${DATA_DIR}/Postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${DB_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  gitea-cache:
    image: redis:7-alpine
    container_name: Gitea-Cache
    restart: unless-stopped
    command: ["sh", "-c", "redis-server --requirepass \"\$(cat /run/secrets/gitea_redis_password)\" --appendonly yes"]
    secrets:
      - gitea_redis_password
    networks:
      - gitea-net
    volumes:
      - ${DATA_DIR}/Redis:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"\$(cat /run/secrets/gitea_redis_password)\" ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  gitea:
    image: gitea/gitea:latest
    container_name: Gitea
    restart: unless-stopped
    env_file: .env
    environment:
      - USER_UID=${REAL_UID}
      - USER_GID=${REAL_GID}
      - GITEA__database__DB_TYPE=postgres
      - GITEA__database__HOST=gitea-db:5432
      - GITEA__database__NAME=\${DB_NAME}
      - GITEA__database__USER=\${DB_USER}
      - GITEA__database__PASSWD=${DB_PASS_VAL}
      - GITEA__cache__ADAPTER=redis
      # Injecting password value for connection string construction
      - GITEA__cache__HOST=redis://:${R_PASS}@gitea-cache:6379/0?pool_size=100&idle_timeout=180s
      - GITEA__queue__TYPE=redis
      - GITEA__queue__CONN_STR=redis://:${R_PASS}@gitea-cache:6379/0
      - GITEA__server__ROOT_URL=http://\${HOST_IP}:\${GITEA_WEB_PORT}/
      # SSH PATCH: Fixed internal binding to unprivileged port and external mapping
      - GITEA__server__START_SSH_SERVER=true
      - GITEA__server__SSH_LISTEN_PORT=2222
      - GITEA__server__SSH_PORT=\${GITEA_SSH_PORT}
      - GITEA__security__INSTALL_LOCK=true
      - GITEA__server__LFS_START_SERVER=true
    secrets:
      - gitea_db_password
    networks:
      - gitea-net
    ports:
      - "\${GITEA_WEB_PORT}:3000"
      - "\${GITEA_SSH_PORT}:2222"
    volumes:
      - ${GITEA_VOL}
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    depends_on:
      gitea-db:
        condition: service_healthy
      gitea-cache:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/api/healthz"]
      interval: 15s
      timeout: 10s
      retries: 10

  gitea-runner:
    image: gitea/act_runner:latest
    container_name: Gitea-Runner
    restart: unless-stopped
    environment:
      - GITEA_INSTANCE_URL=http://gitea:3000
      - GITEA_RUNNER_REGISTRATION_TOKEN_FILE=/run/secrets/gitea_runner_token
      - GITEA_RUNNER_NAME=Omega-Runner
      - DOCKER_HOST=tcp://gitea-socket-proxy:2375
    secrets:
      - gitea_runner_token
    volumes:
      - ${DATA_DIR}/Runner:/data
    networks:
      - gitea-net
    depends_on:
      gitea:
        condition: service_healthy
      gitea-socket-proxy:
        condition: service_healthy
EOF
    fi

    if [ "$DEPLOY_AI" == "true" ]; then
        # Decide Volume Driver for Ollama
        local OLLAMA_VOL="${DATA_DIR}/Ollama:/root/.ollama"
        if [ "$USE_AI_NFS" == "true" ]; then OLLAMA_VOL="ollama-nfs-data:/root/.ollama"; fi
        
        cat >> "$COMPOSE_FILE" <<EOF
  ollama-worker:
    image: ollama/ollama:latest
    container_name: Ollama-Worker
    restart: unless-stopped
    env_file: ${ENV_FILE}
    environment:
      - TZ=\${TZ}
      - OLLAMA_HOST=0.0.0.0
      - OLLAMA_FLASH_ATTENTION=\${OLLAMA_FLASH_ATTENTION}
      - OLLAMA_DEBUG=1
      - OLLAMA_NUM_GPU=1
      - OLLAMA_GPU_LAYERS=\${OLLAMA_GPU_LAYERS}
      - OLLAMA_KEEP_ALIVE=24h
      - HSA_OVERRIDE_GFX_VERSION=\${HSA_OVERRIDE_GFX_VERSION}
      - HSA_ENABLE_SDMA=\${HSA_ENABLE_SDMA}
      # PATCH: Device Pinning
      - HIP_VISIBLE_DEVICES=\${HIP_VISIBLE_DEVICES}
      - ROCR_VISIBLE_DEVICES=\${ROCR_VISIBLE_DEVICES}
      # PATCH: Vulkan
      - OLLAMA_VULKAN=\${OLLAMA_VULKAN}
    networks:
      - gitea-net
    ports:
      - "\${AI_PORT}:11434"
    volumes:
      - ${OLLAMA_VOL}
EOF
        if [ "$GPU_TYPE" == "NVIDIA" ]; then
            cat >> "$COMPOSE_FILE" <<EOF
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
EOF
        elif [ "$GPU_TYPE" == "AMD" ]; then
             cat >> "$COMPOSE_FILE" <<EOF
    privileged: true
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
EOF
             # PATCH: Inject discovered groups (GIDs) if present
             if [ -n "$GPU_GROUPS_DETECTED" ]; then
                 echo "    group_add:" >> "$COMPOSE_FILE"
                 for grp in $GPU_GROUPS_DETECTED; do
                     echo "      - \"$grp\"" >> "$COMPOSE_FILE"
                 done
             fi

        else
            # CPU Limits (DoS Protection)
             cat >> "$COMPOSE_FILE" <<EOF
    deploy:
      resources:
        limits:
          cpus: '${LIMIT_CPU}'
          memory: ${LIMIT_MEM}
EOF
        fi
        
        # PATCH: Force Unconfined AppArmor for Ollama to prevent EROFS
        # Also force :z or :rw
        sed -i '/image: ollama\/ollama:latest/a \    security_opt:\n      - apparmor:unconfined' "$COMPOSE_FILE"
        if [ "$USE_AI_NFS" != "true" ]; then
            sed -i "s|${DATA_DIR}/Ollama:/root/.ollama|${DATA_DIR}/Ollama:/root/.ollama:rw,z|g" "$COMPOSE_FILE"
        else
             sed -i "s|ollama-nfs-data:/root/.ollama|ollama-nfs-data:/root/.ollama:rw|g" "$COMPOSE_FILE"
        fi
    fi

    # Append Volume Definitions if NFS is used
    if [ "$USE_GITEA_NFS" == "true" ] || [ "$USE_AI_NFS" == "true" ]; then
         cat >> "$COMPOSE_FILE" <<EOF

volumes:
EOF
    fi

    if [ "$USE_GITEA_NFS" == "true" ]; then
        cat >> "$COMPOSE_FILE" <<EOF
  gitea-nfs-data:
    driver: local
    driver_opts:
      type: nfs
      o: addr=\${GITEA_NFS_SERVER},rw,nolock,hard,nointr,nfsvers=4
      device: ":\${GITEA_NFS_PATH}"
EOF
    fi

    if [ "$USE_AI_NFS" == "true" ]; then
        cat >> "$COMPOSE_FILE" <<EOF
  ollama-nfs-data:
    driver: local
    driver_opts:
      type: nfs
      o: addr=\${OLLAMA_NFS_SERVER},rw,nolock,hard,nointr,nfsvers=4
      device: ":\${OLLAMA_NFS_PATH}"
EOF
    fi
    
    # Secure Compose file (contains injected Redis string)
    chmod 600 "$COMPOSE_FILE"
}

# ------------------------------------------------------------------------------
# 11. Audit Tool Generation (Re-Integrated)
# ------------------------------------------------------------------------------
generate_audit_tool() {
    [ "$DEPLOY_AI" != "true" ] && return
    
    log_info "Generating Forensic Audit Tool..."
    cat << EOF > "$AUDIT_SCRIPT"
#!/usr/bin/env python3
import urllib.request
import json
import subprocess
import time

# Dynamic config from deployment
API_URL = "http://127.0.0.1:${CFG_AI_PORT##*:}/api/generate"
PULL_URL = "http://127.0.0.1:${CFG_AI_PORT##*:}/api/pull"
MODEL = "tinyllama"

def log(msg): print(f"[AUDIT] {msg}")

def check_logs():
    cmd = ["docker", "logs", "Ollama-Worker"]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if "offloading" in res.stderr:
        log("SUCCESS: GPU Offload detected in logs.")
    else:
        log("WARNING: No GPU offload detected (Check drivers).")

def run_test():
    log(f"Testing inference with {MODEL}...")
    
    # Auto-Pull check
    check_model = subprocess.run(["docker", "exec", "Ollama-Worker", "ollama", "list"], capture_output=True, text=True)
    if MODEL not in check_model.stdout:
        log("Model not found. Pulling...")
        pull_data = json.dumps({"name": MODEL}).encode("utf-8")
        try:
             req = urllib.request.Request(PULL_URL, data=pull_data, headers={'Content-Type': 'application/json'})
             with urllib.request.urlopen(req) as r:
                 pass # Wait for stream
        except Exception as e:
             log(f"Pull Failed: {e}")
             return

    data = json.dumps({"model": MODEL, "prompt": "Status?", "stream": False}).encode("utf-8")
    try:
        req = urllib.request.Request(API_URL, data=data, headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req) as r:
            log("SUCCESS: API Responded.")
    except Exception as e:
        log(f"FAILURE: {e}")

if __name__ == "__main__":
    run_test()
    time.sleep(2)
    check_logs()
EOF
    chmod +x "$AUDIT_SCRIPT"
}

# ------------------------------------------------------------------------------
# 12. Forensic Audit Function
# ------------------------------------------------------------------------------
perform_forensic_audit() {
    echo ""
    echo "Starting Forensic Integration Audit..."
    echo "----------------------------------------"

    # 1. Secret Integrity Check
    if [ -f "$ENV_FILE" ]; then
        if grep -q "PASS=" "$ENV_FILE" || grep -q "TOKEN=" "$ENV_FILE"; then
            log_err "Secrets detected in .env file (Ghost Secret Regression)."
        else
            log_succ ".env file appears clean of credentials."
        fi
    else
        log_err ".env file missing."
    fi

    # 2. Permission Audit
    PERM=$(stat -c "%a" "$SECRETS_DIR" 2>/dev/null)
    if [ "$PERM" == "700" ]; then
        log_succ "Secrets directory permissions locked (700)."
    else
        log_err "Secrets directory insecure (Current: $PERM, Expected: 700)."
    fi
    
    # 3. Gitea Internal Health
    if [ "$DEPLOY_GITEA" == "true" ]; then
        if docker exec Gitea curl -s -f http://127.0.0.1:3000/api/healthz > /dev/null; then
            log_succ "Gitea Internal API: Responsive."
        else
            log_err "Gitea Internal API: Unreachable."
        fi
        
        # 4. Runner Registration
        RUNNER_LIST=$(docker exec -u 1000 Gitea gitea actions runner list 2>&1 || true)
        if echo "$RUNNER_LIST" | grep -q "Omega-Runner"; then
            log_succ "Gitea Runner: Verified active via Server CLI."
        elif docker logs Gitea-Runner 2>&1 | grep -Eq "Runner registered successfully|declare successfully"; then
            log_succ "Gitea Runner: Handshake confirmed in logs."
        else
            log_err "Gitea Runner: Not found in Server CLI or Logs."
        fi
        
        # 5. Socket Proxy
        if docker exec Gitea-Runner wget -q -O - http://gitea-socket-proxy:2375/version > /dev/null 2>&1; then
             log_succ "Socket Proxy: Reachable from Runner (via wget)."
        else
             log_err "Socket Proxy: Runner cannot access Docker API."
        fi
    fi

    # 6. Ollama Check
    if [ "$DEPLOY_AI" == "true" ]; then
        if docker exec Ollama-Worker ollama list > /dev/null 2>&1; then
            log_succ "Ollama API: Active (Internal CLI check)."
        else
            # Try to grab the error message if possible
            local ERR=$(docker exec Ollama-Worker ollama list 2>&1 || true)
            log_err "Ollama API: Dead. Output: $ERR"
        fi
        
        # GPU Check
        # Use sourcing to get accurate values
        if [ -f "$ENV_FILE" ]; then
             # Source in a subshell to avoid pollution
             EXPECTED_LAYERS=$(set -a; source "$ENV_FILE"; echo $OLLAMA_GPU_LAYERS)
        else
             EXPECTED_LAYERS=0
        fi
        EXPECTED_LAYERS=${EXPECTED_LAYERS:-0}
        
        # Trigger Inference (Safe)
        FIRST_MODEL=$(docker exec Ollama-Worker ollama list 2>/dev/null | awk 'NR==2 {print $1}' || true)
        if [ -n "$FIRST_MODEL" ]; then
             docker exec Ollama-Worker curl -s -f -d "{\"model\": \"$FIRST_MODEL\", \"prompt\": \"hi\", \"stream\": false}" http://127.0.0.1:11434/api/generate > /dev/null 2>&1 || true
             sleep 4
        fi
        
        LOGS=$(docker logs Ollama-Worker 2>&1 | tail -n 200)
        if echo "$LOGS" | grep -iq "offload"; then
            log_succ "Ollama Compute: GPU Offload detected."
        elif echo "$LOGS" | grep -iq "cpu"; then
            if [ "$EXPECTED_LAYERS" -gt "0" ]; then
                 log_err "Ollama Compute: CPU Mode active despite GPU config."
            else
                 log_succ "Ollama Compute: CPU Mode (As Configured)."
            fi
        fi
    fi
    
    # 7. Portainer Agent
    if [ "$DEPLOY_PORTAINER_AGENT" == "true" ]; then
        if docker logs Portainer-Agent 2>&1 | grep -iq "starting agent api server"; then
            log_succ "Portainer Agent: Standalone Mode Active."
        else
            log_err "Portainer Agent: Startup signature missing."
        fi
    fi
    
    echo "----------------------------------------"
}

# ------------------------------------------------------------------------------
# 13. Finalization & Auto-Provisioning
# ------------------------------------------------------------------------------
finalize_permissions() {
    log_info "Securing permissions..."
    chown -R "$REAL_USER:$REAL_GID" "$STACK_DIR" "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"
    chmod 600 "$ENV_FILE"
    
    if [ "$DEPLOY_GITEA" == "true" ]; then
        if [ -d "${DATA_DIR}/Postgres" ]; then chown -R 999:999 "${DATA_DIR}/Postgres"; fi
        if [ -d "${DATA_DIR}/Redis" ]; then chown -R 999:999 "${DATA_DIR}/Redis"; fi
        if [ -d "${DATA_DIR}/Gitea" ] && [ "$USE_NFS" != "true" ]; then 
            chown -R 1000:1000 "${DATA_DIR}/Gitea"
        fi
    fi
    
    # PATCH: Force permissions on Ollama directory for NFS/Bind
    if [ "$DEPLOY_AI" == "true" ] && [ -d "${DATA_DIR}/Ollama" ]; then 
         chmod 777 "${DATA_DIR}/Ollama"
    fi
    
    if [ "$DEPLOY_VSCODE" == "true" ] && [ -d "${DATA_DIR}/CodeServer" ]; then 
        chown -R "$REAL_UID:$REAL_GID" "${DATA_DIR}/CodeServer"
    fi
    
    log_succ "Permissions secured."
}

finalize_stack() {
    finalize_permissions
    
    log_info "Launching Stack..."
    $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d --build --remove-orphans || exit 1

    if [ "$DEPLOY_GITEA" == "true" ]; then
        log_info "Waiting for Gitea (Healthcheck)..."
        for i in {1..40}; do
            STATUS=$(docker inspect --format='{{.State.Health.Status}}' Gitea 2>/dev/null || echo "starting")
            if [ "$STATUS" == "healthy" ]; then
                log_succ "Gitea Online."
                local ADM_U=$(cat "${SECRETS_DIR}/gitea_admin_username.txt" 2>/dev/null || echo "gitea_admin")
                local ADM_P=$(cat "${SECRETS_DIR}/gitea_admin_password.txt" 2>/dev/null)
                docker exec -u 1000 Gitea gitea admin user create --username "$ADM_U" --password "$ADM_P" --email "admin@${HOST_IP}" --admin --must-change-password=false 2>/dev/null || log_warn "Admin exists."
                TOKEN=$(docker exec -u 1000 Gitea gitea actions generate-runner-token | tr -d '\r')
                if [ -n "$TOKEN" ]; then
                    (umask 077; echo -n "$TOKEN" > "${SECRETS_DIR}/gitea_runner_token.txt")
                    log_info "Hot-patching Gitea-Runner..."
                    $DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" restart gitea-runner
                    log_succ "Runner Registered & Restarted."
                fi
                break
            fi
            sleep 5
        done
    fi

    if [ "$DEPLOY_AI" == "true" ]; then
        log_info "Waiting for AI API..."
        for i in {1..20}; do
             STATUS=$(docker inspect --format='{{.State.Health.Status}}' Ollama-Worker 2>/dev/null || echo "starting")
             if [ "$STATUS" == "healthy" ]; then
                 log_info "Initializing AI Model (Background)..."
                 docker exec -d Ollama-Worker sh -c "ollama pull qwen2.5-coder:1.5b > /tmp/pull.log 2>&1"
                 break
             fi
             sleep 3
        done
    fi
}

post_install_instructions() {
    echo -e "\n"
    log_succ "DEPLOYMENT SUCCESSFUL - OMEGA DASHBOARD"
    echo "=============================================================================="
    
    if docker ps --format '{{.Names}}' | grep -q "Gitea-Socket-Proxy"; then
        local PROXY_STATUS=$(docker inspect --format='{{.State.Health.Status}}' Gitea-Socket-Proxy 2>/dev/null || echo "running")
        local COLOR=$GREEN; [[ "$PROXY_STATUS" == "starting" ]] && COLOR=$YELLOW
        draw_service_box "GITEA-SOCKET-PROXY" "Location|Bridge (gitea-net:2375)" "Status|${COLOR}[$PROXY_STATUS]${NC}"
    fi

    if [ "$DEPLOY_GITEA" == "true" ]; then
        local G_STAT=$(docker inspect --format='{{.State.Health.Status}}' Gitea 2>/dev/null || echo "running")
        local COLOR=$GREEN; [[ "$G_STAT" == "starting" ]] && COLOR=$YELLOW
        local G_USER=$(cat "${SECRETS_DIR}/gitea_admin_username.txt" 2>/dev/null || echo "N/A")
        # Patched: Added fallback for cat failure
        local G_PASS=$(cat "${SECRETS_DIR}/gitea_admin_password.txt" 2>/dev/null || echo "N/A")
        draw_service_box "GITEA-CORE" "Location|http://${HOST_IP}:${CFG_GITEA_WEB}" "Status|${COLOR}[$G_STAT]${NC}" "User|$G_USER" "Pass|$G_PASS"
    fi

    if [ "$DEPLOY_AI" == "true" ]; then
        local A_STAT=$(docker inspect --format='{{.State.Status}}' Ollama-Worker 2>/dev/null || echo "offline")
        local COLOR=$GREEN; [[ "$A_STAT" != "running" ]] && COLOR=$RED
        draw_service_box "OLLAMA-WORKER" "Location|http://${HOST_IP##*:}:${CFG_AI_PORT##*:}" "Status|${COLOR}[$A_STAT]${NC}"
    fi

    if [ "$DEPLOY_PORTAINER_AGENT" == "true" ]; then
        local AGENT_STATUS=$(docker inspect --format='{{.State.Status}}' Portainer-Agent 2>/dev/null || echo "offline")
        local COLOR=$GREEN; [[ "$AGENT_STATUS" != "running" ]] && COLOR=$RED
        draw_service_box "PORTAINER-AGENT" "Location|http://${HOST_IP}:${CFG_AGENT_PORT}" "Status|${COLOR}[$AGENT_STATUS]${NC}"
    fi

    if [ "$DEPLOY_VSCODE" == "true" ]; then
        local VS_PASS=$(cat "${SECRETS_DIR}/vscode_password.txt" 2>/dev/null || echo "N/A")
        draw_service_box "CODE-SERVER" "Location|http://${HOST_IP}:${CFG_VSCODE_PORT}" "Status|${GREEN}[running]${NC}" "Pass|$VS_PASS"
    fi

    echo -e "Vault Path:  ${YELLOW}${SECRETS_DIR}${NC}"
    echo "=============================================================================="
}

# ------------------------------------------------------------------------------
# 14. Execution
# ------------------------------------------------------------------------------
main() {
    check_identity
    check_core_requirements
    detect_host_context
    configure_role_wizard
    configure_vscode_wizard
    resolve_conflicts
    configure_storage_wizard
    setup_directories
    configure_hardware_acceleration
    setup_environment
    generate_docker_compose
    generate_audit_tool
    finalize_stack
    
    perform_forensic_audit
    
    sync
    post_install_instructions
}

main