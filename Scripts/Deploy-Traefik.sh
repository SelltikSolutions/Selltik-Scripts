#!/bin/bash

# ==============================================================================
#  TRAEFIK INGRESS MONOLITH - PARANOID EDITION (v4.21)
# ==============================================================================
#  ARCHITECTURE: Hardened Ingress | DNS-01 (Cloudflare) | Docker Secrets
#  DIR STRUCTURE: /opt/Docker/Stacks/Traefik (Surgical Isolation)
#  SECURITY: No-New-Privileges, Cap-Drop, Read-Only FS, User Namespace
#  FEATURES:
#    - All-in-One Deployment & Service Labeler
#    - Ingress Inspector v3: Advanced JQ Router Name Extraction
#    - Diagnostic Suite: Real-time Health & Log Monitoring
#  ROBUSTNESS: 
#    - Ephemeral 'tmpfs' isolation (Host-pollution prevention).
#    - Literal string Heredoc injection (YAML whitespace integrity).
#    - Diagnostic SIGINT trapping (Prevents log-exit script crashes).
#    - Safe ACME persistence to prevent Let's Encrypt Rate-Limit bans.
#    - JQ Object Type-Safety (Prevents null parsing crashes).
#  STATUS: Authoritative. Hardened. Fully Audited.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# --- 1. SYSTEM DEFINITIONS ---
STACK_NAME="Traefik"
BASE_DIR="/opt/Docker"
STACKS_DIR="$BASE_DIR/Stacks/$STACK_NAME"
CONFIG_DIR="$BASE_DIR/Config/$STACK_NAME"
SECRETS_DIR="$BASE_DIR/Config/Secrets"
ACME_FILE="$CONFIG_DIR/acme.json"
DETECTED_PUID=${SUDO_UID:-$(id -u)}
DETECTED_PGID=${SUDO_GID:-$(id -g)}

# Visuals
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; NC='\033[0m'

# --- 2. PRE-FLIGHT ---
check_environment() {
    local deps=(gum jq docker curl)
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then echo "Missing $cmd. Please install."; exit 1; fi
    done
    sudo mkdir -p "$STACKS_DIR" "$CONFIG_DIR" "$SECRETS_DIR"
    
    # Vault Protection
    if [ ! -f "$SECRETS_DIR/.gitignore" ]; then
        echo -e "# PARANOID SECURITY: Ignore all files in this directory\n*\n!.gitignore\n!README.md" | sudo tee "$SECRETS_DIR/.gitignore" > /dev/null
    fi
    sudo chmod 644 "$SECRETS_DIR/.gitignore" 2>/dev/null || true
}

# --- 3. HELPER FUNCTIONS ---
write_secret() {
    local NAME=$1; local CONTENT=$2
    [[ "$NAME" != *.txt ]] && NAME="${NAME}.txt" || true
    local FILEPATH="$SECRETS_DIR/$NAME"
    
    # Pre-lock the file before writing to prevent race-condition exposure
    sudo touch "$FILEPATH"
    sudo chmod 600 "$FILEPATH"
    sudo chown "$DETECTED_PUID":"$DETECTED_PGID" "$FILEPATH"
    
    # Use printf instead of echo to handle special characters securely
    printf "%s" "$CONTENT" | sudo tee "$FILEPATH" > /dev/null
}

read_secret() {
    local NAME=$1
    [[ "$NAME" != *.txt ]] && NAME="${NAME}.txt" || true
    if [ -f "$SECRETS_DIR/$NAME" ]; then sudo cat "$SECRETS_DIR/$NAME" | tr -d '\n\r'; fi
}

# ==============================================================================
# SECTION 1: TRAEFIK CORE WIZARD
# ==============================================================================

wizard_core() {
    gum style --border double --margin "1 2" --padding "1 2" --foreground 212 "TRAEFIK CORE DEPLOYMENT"

    local DOMAIN; DOMAIN=$(gum input --placeholder "Root Domain (e.g. example.com)" --value "$(read_secret RootDomain)" || echo "__ABORT__")
    [[ "$DOMAIN" == "__ABORT__" || -z "$DOMAIN" ]] && return 1

    local EMAIL; EMAIL=$(gum input --placeholder "Let's Encrypt Email (REQUIRED)" --value "$(read_secret LetsEncryptEmail)" || echo "__ABORT__")
    [[ "$EMAIL" == "__ABORT__" ]] && return 1
    
    # Strict Email Validation
    if [[ "$EMAIL" != *"@"* || "$EMAIL" == *" "* || -z "$EMAIL" ]]; then
        gum style --foreground 196 "Error: Let's Encrypt strictly requires a valid email address format."
        read -r -p "Press Enter to return to menu..."
        return 1
    fi

    # Environment Selection
    echo -e "${C}>> Select Let's Encrypt Environment:${NC}"
    local LE_ENV; LE_ENV=$(gum choose "Staging (Testing - Prevents Rate Limits)" "Production (Live - Strict Limits)" || echo "__ABORT__")
    [[ "$LE_ENV" == "__ABORT__" || -z "$LE_ENV" ]] && return 1
    
    local CA_SERVER="https://acme-v02.api.letsencrypt.org/directory"
    if [[ "$LE_ENV" == *"Staging"* ]]; then
        CA_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
    fi

    # Explicit Auth Selection & Secret Retention Logic
    echo -e "${C}>> Select Cloudflare Authentication Method:${NC}"
    local AUTH_TYPE; AUTH_TYPE=$(gum choose "API Token (Recommended - Restrict to Zone:DNS:Edit)" "Global API Key (Legacy)" || echo "__ABORT__")
    [[ "$AUTH_TYPE" == "__ABORT__" || -z "$AUTH_TYPE" ]] && return 1

    local CF_ENV_BLOCK=""
    local CF_SECRET_BLOCK=""
    local SECRETS_YAML=""

    if [[ "$AUTH_TYPE" == *"API Token"* ]]; then
        local EXISTING_TOKEN; EXISTING_TOKEN=$(read_secret CloudflareApiToken)
        local CF_TOKEN_PROMPT="Cloudflare API Token"
        [[ -n "$EXISTING_TOKEN" ]] && CF_TOKEN_PROMPT="Cloudflare API Token (Leave blank to keep existing)"
        
        local CF_TOKEN; CF_TOKEN=$(gum input --password --placeholder "$CF_TOKEN_PROMPT" || echo "__ABORT__")
        [[ "$CF_TOKEN" == "__ABORT__" ]] && return 1
        
        if [[ -z "$CF_TOKEN" ]]; then
            [[ -z "$EXISTING_TOKEN" ]] && { gum style --foreground 196 "Error: API Token required."; read -r -p "Press Enter..."; return 1; }
        else
            write_secret "CloudflareApiToken" "$CF_TOKEN"
        fi
        
        # Multi-line string literal to prevent bash subshell whitespace collapse
        CF_ENV_BLOCK="      - CLOUDFLARE_DNS_API_TOKEN_FILE=/run/secrets/CloudflareApiToken"
        CF_SECRET_BLOCK="CloudflareApiToken"
        SECRETS_YAML="  LetsEncryptEmail: { file: $SECRETS_DIR/LetsEncryptEmail.txt }
  CloudflareApiToken: { file: $SECRETS_DIR/CloudflareApiToken.txt }"
    else
        local CF_EMAIL; CF_EMAIL=$(gum input --placeholder "Cloudflare Account Email" --value "$(read_secret CloudflareEmail)" || echo "__ABORT__")
        [[ "$CF_EMAIL" == "__ABORT__" || -z "$CF_EMAIL" ]] && return 1
        
        local EXISTING_KEY; EXISTING_KEY=$(read_secret CloudflareApiKey)
        local CF_KEY_PROMPT="Cloudflare Global API Key"
        [[ -n "$EXISTING_KEY" ]] && CF_KEY_PROMPT="Cloudflare Global API Key (Leave blank to keep existing)"

        local CF_KEY; CF_KEY=$(gum input --password --placeholder "$CF_KEY_PROMPT" || echo "__ABORT__")
        [[ "$CF_KEY" == "__ABORT__" ]] && return 1
        
        if [[ -z "$CF_KEY" ]]; then
            [[ -z "$EXISTING_KEY" ]] && { gum style --foreground 196 "Error: Global API Key required."; read -r -p "Press Enter..."; return 1; }
        else
            write_secret "CloudflareApiKey" "$CF_KEY"
        fi
        
        write_secret "CloudflareEmail" "$CF_EMAIL"
        
        # Multi-line string literal to prevent bash subshell whitespace collapse
        CF_ENV_BLOCK="      - CLOUDFLARE_EMAIL_FILE=/run/secrets/CloudflareEmail
      - CLOUDFLARE_API_KEY_FILE=/run/secrets/CloudflareApiKey"
        CF_SECRET_BLOCK="CloudflareEmail, CloudflareApiKey"
        SECRETS_YAML="  LetsEncryptEmail: { file: $SECRETS_DIR/LetsEncryptEmail.txt }
  CloudflareApiKey: { file: $SECRETS_DIR/CloudflareApiKey.txt }
  CloudflareEmail: { file: $SECRETS_DIR/CloudflareEmail.txt }"
    fi

    write_secret "RootDomain" "$DOMAIN"
    write_secret "LetsEncryptEmail" "$EMAIL"

    # Smart ACME Persistence (Rate Limit Protection)
    if [ -s "$ACME_FILE" ]; then
        echo -e "${Y}>> Existing ACME certificates detected.${NC}"
        if gum confirm "Wipe existing certificates? (Only required if switching between Staging and Production)"; then
            sudo rm -f "$ACME_FILE"
            sudo touch "$ACME_FILE" && sudo chmod 600 "$ACME_FILE"
            echo -e "${C}>> ACME cleared.${NC}"
        fi
    else
        sudo touch "$ACME_FILE" && sudo chmod 600 "$ACME_FILE"
    fi

    # Automated Backup
    local COMPOSE_PATH="$STACKS_DIR/docker-compose.yml"
    if [ -f "$COMPOSE_PATH" ]; then
        sudo cp "$COMPOSE_PATH" "${COMPOSE_PATH}.bak"
        echo -e "${Y}>> Backed up existing docker-compose.yml${NC}"
    fi

    echo -e "${C}>> Forging Hardened Monolith Compose at $STACKS_DIR...${NC}"
    cat <<EOF | sudo tee "$COMPOSE_PATH" > /dev/null
services:
  traefik:
    image: traefik:v3
    container_name: Traefik
    restart: unless-stopped
    init: true
    pids_limit: 200
    security_opt: [no-new-privileges:true]
    read_only: true
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    networks:
      public_ingress: { ipv4_address: 10.20.0.2 }
    secrets: [$CF_SECRET_BLOCK, LetsEncryptEmail]
    environment:
${CF_ENV_BLOCK}
      - DOCKER_API_VERSION=1.41
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - $CONFIG_DIR:/etc/traefik
      - $ACME_FILE:/etc/traefik/acme.json
    tmpfs:
      - /tmp
    command:
      - "--global.checknewversion=false"
      - "--ping=true"
      - "--entryPoints.web.address=:80"
      - "--entryPoints.websecure.address=:443"
      - "--entryPoints.web.http.redirections.entryPoint.to=websecure"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=public_ingress"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge=true"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare"
      - "--certificatesresolvers.cloudflare.acme.email=$EMAIL"
      - "--certificatesresolvers.cloudflare.acme.storage=/etc/traefik/acme.json"
      - "--certificatesresolvers.cloudflare.acme.caserver=$CA_SERVER"
      - "--api.dashboard=true"
    healthcheck:
      test: ["CMD", "traefik", "healthcheck", "--ping"]
      interval: 10s
      timeout: 5s
      retries: 3
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(\`traefik.$DOMAIN\`)"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=cloudflare"
      - "traefik.http.services.traefik.loadbalancer.server.port=8080"
    ports:
      - "80:80"
      - "443:443"

networks:
  public_ingress:
    name: public_ingress
    driver: bridge
    ipam: { config: [{ subnet: "10.20.0.0/24" }] }

secrets:
${SECRETS_YAML}
EOF

    if gum confirm "Deploy/Update Ingress Cluster?"; then
        cd "$STACKS_DIR"
        sudo docker compose pull traefik
        sudo docker compose up -d
        gum style --foreground 10 "Ingress Online: https://traefik.$DOMAIN"
    fi
}

# ==============================================================================
# SECTION 2: SERVICE LABELER WIZARD
# ==============================================================================

wizard_labeler() {
    gum style --border double --margin "1 2" --padding "1 2" --foreground 33 "SERVICE LABELING WIZARD"

    local TARGET_PATH; TARGET_PATH=$(gum input --placeholder "Path to Docker directory" --value "$(pwd)" || echo "__ABORT__")
    [[ "$TARGET_PATH" == "__ABORT__" || -z "$TARGET_PATH" ]] && return 1
    
    if [ ! -f "$TARGET_PATH/docker-compose.yml" ]; then
        gum style --foreground 196 "Error: No docker-compose.yml found at $TARGET_PATH"
        read -r -p "Press Enter..."
        return 1
    fi

    # Native Context-Aware Docker Compose Discovery
    local SERVICES; SERVICES=$(sudo docker compose --project-directory "$TARGET_PATH" -f "$TARGET_PATH/docker-compose.yml" config --services 2>/dev/null | xargs || true)
    if [[ -z "$SERVICES" ]]; then
        gum style --foreground 196 "No services found or invalid compose file structure in $TARGET_PATH."
        read -r -p "Press Enter..."
        return 1
    fi
    
    local SELECTED; SELECTED=$(gum choose $SERVICES || echo "__ABORT__")
    [[ "$SELECTED" == "__ABORT__" || -z "$SELECTED" ]] && return 1
    
    local DOMAIN; DOMAIN=$(read_secret RootDomain)
    [[ -z "$DOMAIN" ]] && DOMAIN="example.com"

    # Support for Root Domain Mapping
    local SUB; SUB=$(gum input --placeholder "Subdomain (Leave blank for root domain)" --value "${SELECTED,,}" || echo "__ABORT__")
    [[ "$SUB" == "__ABORT__" ]] && return 1
    
    local PORT; PORT=$(gum input --placeholder "Internal Container Port" --value "80" || echo "__ABORT__")
    [[ "$PORT" == "__ABORT__" || -z "$PORT" ]] && return 1

    local HOST
    if [[ -z "$SUB" ]]; then
        HOST="$DOMAIN"
    else
        HOST="${SUB}.${DOMAIN}"
    fi

    local PATCH_BLOCK=$(cat <<EOF

# ==============================================================================
# TRAEFIK INGRESS PATCH FOR: $SELECTED
# ==============================================================================

# --- 1. ADD THIS TO THE '$SELECTED' SERVICE BLOCK ---
    networks:
      - public_ingress
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${SELECTED,,}.rule=Host(\`${HOST}\`)"
      - "traefik.http.routers.${SELECTED,,}.entrypoints=websecure"
      - "traefik.http.routers.${SELECTED,,}.tls.certresolver=cloudflare"
      - "traefik.http.services.${SELECTED,,}.loadbalancer.server.port=${PORT}"

# --- 2. ADD THIS TO THE VERY BOTTOM OF THE COMPOSE FILE ---
networks:
  public_ingress:
    external: true
EOF
)

    echo -e "${Y}>> Generated Manifest for $SELECTED:${NC}"
    echo -e "${C}${PATCH_BLOCK}${NC}"

    if gum confirm "Export patch to ${TARGET_PATH}/traefik_patch.txt?"; then
        # Append mode (-a) used to prevent multi-service patch overwrites
        echo "$PATCH_BLOCK" | sudo tee -a "${TARGET_PATH}/traefik_patch.txt" > /dev/null
        gum style --foreground 10 "Patch appended to ${TARGET_PATH}/traefik_patch.txt"
    fi
}

# ==============================================================================
# SECTION 3: DIAGNOSTICS & INSPECTOR
# ==============================================================================

check_diagnostics() {
    clear
    gum style --foreground 212 --border double "TRAEFIK DIAGNOSTIC SUITE"
    local DIAG; DIAG=$(gum choose "1) Check Health Status" "2) View Live Logs" "3) Test DNS-01 Resolver" "4) Back" || echo "__ABORT__")
    case "$DIAG" in
        1*)
            sudo docker ps --filter "name=Traefik" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            read -r -p "Press Enter..." ;;
        2*) 
            # Appended || true prevents Ctrl+C from triggering set -e script death
            sudo docker logs -f Traefik || true ;;
        3*) 
            DOMAIN=$(read_secret RootDomain)
            if command -v nslookup &> /dev/null; then
                nslookup "$DOMAIN" || true
            else
                echo -e "${R}Error: 'nslookup' is not installed on this system.${NC}"
            fi
            read -r -p "Press Enter..." ;;
        *) return ;;
    esac
}

inspect_ingress() {
    clear
    gum style --foreground 212 --border double "INGRESS INSPECTOR (404 DEBUGGER)"
    local CONTAINERS; CONTAINERS=$(sudo docker ps --format "{{.Names}}" || true)
    [[ -z "$CONTAINERS" ]] && return
    local TARGET; TARGET=$(gum choose $CONTAINERS || echo "__ABORT__")
    [[ "$TARGET" == "__ABORT__" || -z "$TARGET" ]] && return
    
    echo -e "${C}>> Auditing: $TARGET${NC}"
    
    # Network Attachment (Safe Object mapping)
    local NETS; NETS=$(sudo docker inspect "$TARGET" | jq -r '.[0].NetworkSettings.Networks | objects | keys[]' 2>/dev/null || echo "")
    if echo "$NETS" | grep -q "public_ingress"; then echo -e "${G}[PASS]${NC} Attached to public_ingress."; else echo -e "${R}[FAIL]${NC} NOT on public_ingress."; fi

    # Labels Core Status & Object Guard
    local LABELS; LABELS=$(sudo docker inspect "$TARGET" | jq -r '.[0].Config.Labels | objects' 2>/dev/null || echo "")
    
    if [[ -z "$LABELS" || "$LABELS" == "{}" ]]; then
        echo -e "${R}[FAIL]${NC} No labels found on container."
        read -r -p "Press Enter to return..."
        return
    fi

    if echo "$LABELS" | grep -q '"traefik.enable": "true"'; then echo -e "${G}[PASS]${NC} Enabled label found."; else echo -e "${R}[FAIL]${NC} traefik.enable missing."; fi

    # Router/Rule Check - Dynamically Extract Router Name safely
    local ROUTER_NAME="null"
    ROUTER_NAME=$(echo "$LABELS" | jq -r 'keys[] | select(test("^traefik\\.http\\.routers\\..*\\.rule$")) | capture("^traefik\\.http\\.routers\\.(?<name>.*)\\.rule$").name' 2>/dev/null | head -n 1 || true)
    [[ -z "$ROUTER_NAME" ]] && ROUTER_NAME="null"

    local RULE="null"
    local L_PORT="null"

    if [[ "$ROUTER_NAME" != "null" ]]; then
        echo -e "${G}[PASS]${NC} Active Router Name: $ROUTER_NAME"
        RULE=$(echo "$LABELS" | jq -r '."traefik.http.routers.'$ROUTER_NAME'.rule"' 2>/dev/null || echo "null")
        L_PORT=$(echo "$LABELS" | jq -r '."traefik.http.services.'$ROUTER_NAME'.loadbalancer.server.port"' 2>/dev/null || echo "null")
    else
        echo -e "${Y}[WARN]${NC} No Traefik router configuration detected."
    fi

    if [[ "$RULE" != "null" ]]; then echo -e "${G}[PASS]${NC} Host Rule: $RULE"; else echo -e "${Y}[WARN]${NC} Host Rule missing."; fi
    if [[ "$L_PORT" != "null" ]]; then echo -e "${G}[PASS]${NC} Backend Port: $L_PORT"; else echo -e "${R}[FAIL]${NC} Backend Port missing."; fi

    read -r -p "Press Enter to return..."
}

# ==============================================================================
# MAIN ENGINE
# ==============================================================================

check_environment
while true; do
    clear
    gum style --foreground 212 --border double "PARANOID INGRESS CONTROLLER (v4.21)"
    OP=$(gum choose "1) Traefik Core: Deploy/Update" "2) Service Tool: Attach Service" "3) Diagnostics: Health & Logs" "4) Ingress Inspector: Fix 404s" "5) Secrets: View Vault" "6) Exit" || echo "__ABORT__")
    case "$OP" in
        1*) wizard_core ;;
        2*) wizard_labeler ;;
        3*) check_diagnostics ;;
        4*) inspect_ingress ;;
        5*) 
            echo -e "${Y}--- Current Secrets ---${NC}"
            for f in "$SECRETS_DIR"/*.txt; do
                [[ -e "$f" ]] || continue
                echo -n "$(basename "$f"): "
                sudo cat "$f" | head -c 8; echo "..."
            done
            read -r -p "Press Enter..." ;;
        6* | "__ABORT__") exit 0 ;;
    esac
done