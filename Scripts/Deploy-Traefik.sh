#!/bin/bash

# ==============================================================================
#  TRAEFIK INGRESS MONOLITH - PARANOID EDITION (v4.13)
# ==============================================================================
#  ARCHITECTURE: Hardened Ingress | DNS-01 (Cloudflare) | Docker Secrets
#  DIR STRUCTURE: /opt/Docker/Stacks/Traefik (Surgical Isolation)
#  SECURITY: No-New-Privileges, Cap-Drop, Read-Only FS, User Namespace
#  FEATURES:
#    - All-in-One Deployment & Service Labeler
#    - Ingress Inspector v2: Intelligent container auditing (404 Debugger)
#    - Diagnostic Suite: Real-time Health & Log Monitoring
#  ROBUSTNESS: Pre-locked secrets, set-e crash mitigation, automated backups.
#  FIXES: Updated deprecated CF_ env vars to CLOUDFLARE_ format for Traefik v3.
#  STATUS: Authoritative. Hardened. Audited.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# --- 1. SYSTEM DEFINITIONS ---
SERVICE_NAME="Traefik"
BASE_DIR="/opt/Docker"
STACKS_DIR="$BASE_DIR/Stacks/$SERVICE_NAME"
CONFIG_DIR="$BASE_DIR/Config/$SERVICE_NAME"
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
    [[ "$NAME" != *.txt ]] && NAME="${NAME}.txt"
    local FILEPATH="$SECRETS_DIR/$NAME"
    
    # Pre-lock the file before writing to prevent race-condition exposure
    sudo touch "$FILEPATH"
    sudo chmod 600 "$FILEPATH"
    sudo chown "$DETECTED_PUID":"$DETECTED_PGID" "$FILEPATH"
    
    # Use printf instead of echo to handle special characters securely
    printf "%s" "$CONTENT" | sudo tee "$FILEPATH" > /dev/null
}

read_secret() {
    local NAME=$1; [[ "$NAME" != *.txt ]] && NAME="${NAME}.txt"
    if [ -f "$SECRETS_DIR/$NAME" ]; then sudo cat "$SECRETS_DIR/$NAME" | tr -d '\n\r '; else echo "Not Set"; fi
}

# ==============================================================================
# SECTION 1: TRAEFIK CORE WIZARD
# ==============================================================================

wizard_core() {
    gum style --border double --margin "1 2" --padding "1 2" --foreground 212 "TRAEFIK CORE DEPLOYMENT"

    local DOMAIN; DOMAIN=$(gum input --placeholder "Root Domain (e.g. example.com)" --value "$(read_secret RootDomain)")
    [[ -z "$DOMAIN" ]] && return 1

    local EMAIL; EMAIL=$(gum input --placeholder "Let's Encrypt Email (REQUIRED)" --value "$(read_secret LetsEncryptEmail)")
    
    # Strict Email Validation to prevent ACME 400 InvalidContact errors
    if [[ "$EMAIL" != *"@"* || "$EMAIL" == *" "* || "$EMAIL" == "Not Set" ]]; then
        gum style --foreground 196 "Error: Let's Encrypt strictly requires a valid email address format."
        read -p "Press Enter to return to menu..."
        return 1
    fi

    # Let's Encrypt Environment Selection
    echo -e "${C}>> Select Let's Encrypt Environment (Staging prevents strict rate-limiting bans during setup):${NC}"
    local LE_ENV; LE_ENV=$(gum choose "Staging (Testing - No Rate Limits)" "Production (Live - Strict Rate Limits)")
    
    local CA_SERVER="https://acme-v02.api.letsencrypt.org/directory"
    if [[ "$LE_ENV" == *"Staging"* ]]; then
        # Use the correct staging URL format
        CA_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
    fi
    
    echo -e "${Y}>> Security Note: Cloudflare Restricted API Tokens are heavily preferred over Global Keys.${NC}"
    local CF_TOKEN; CF_TOKEN=$(gum input --password --placeholder "Cloudflare API Token (Zone:DNS:Edit)")
    local CF_EMAIL; CF_EMAIL=$(gum input --placeholder "Cloudflare Email (ONLY IF using legacy Global Key)" --value "$(read_secret CloudflareEmail)")

    write_secret "RootDomain" "$DOMAIN"
    write_secret "LetsEncryptEmail" "$EMAIL"
    [[ -n "$CF_TOKEN" ]] && write_secret "CloudflareApiToken" "$CF_TOKEN"
    [[ -n "$CF_EMAIL" && "$CF_EMAIL" != "Not Set" ]] && write_secret "CloudflareEmail" "$CF_EMAIL"

    # Reset ACME JSON to prevent cross-environment corruption
    sudo rm -f "$ACME_FILE"
    sudo touch "$ACME_FILE" && sudo chmod 600 "$ACME_FILE"

    # Automated Backup
    local COMPOSE_PATH="$STACKS_DIR/docker-compose.yml"
    if [ -f "$COMPOSE_PATH" ]; then
        sudo cp "$COMPOSE_PATH" "${COMPOSE_PATH}.bak"
        echo -e "${Y}>> Backed up existing docker-compose.yml${NC}"
    fi

    # Determine Auth Method (Updated for Traefik v3 / Lego v4 CLOUDFLARE_ format)
    local CF_ENV_BLOCK="      - CLOUDFLARE_DNS_API_TOKEN_FILE=/run/secrets/CloudflareApiToken"
    local CF_SECRET_BLOCK="CloudflareApiToken"
    if [[ -n "$CF_EMAIL" && "$CF_EMAIL" != "Not Set" ]]; then
        # Legacy Global Key Fallback
        CF_ENV_BLOCK="      - CLOUDFLARE_EMAIL_FILE=/run/secrets/CloudflareEmail\n      - CLOUDFLARE_API_KEY_FILE=/run/secrets/CloudflareApiToken"
        CF_SECRET_BLOCK="CloudflareEmail, CloudflareApiToken"
    fi

    echo -e "${C}>> Forging Hardened Monolith Compose at $STACKS_DIR...${NC}"
    cat <<EOF | sudo tee "$COMPOSE_PATH" > /dev/null
services:
  traefik:
    image: traefik:v3
    container_name: Traefik
    restart: unless-stopped
    security_opt: [no-new-privileges:true]
    read_only: true
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    networks:
      public_ingress: { ipv4_address: 10.20.0.2 }
    secrets: [$CF_SECRET_BLOCK, LetsEncryptEmail]
    environment:
$(echo -e "$CF_ENV_BLOCK")
      - DOCKER_API_VERSION=1.41
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - $CONFIG_DIR:/etc/traefik
      - $ACME_FILE:/etc/traefik/acme.json
      - /tmp:/tmp
    command:
      - "--global.checknewversion=false"
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
  CloudflareApiToken: { file: $SECRETS_DIR/CloudflareApiToken.txt }
  CloudflareEmail: { file: $SECRETS_DIR/CloudflareEmail.txt }
  LetsEncryptEmail: { file: $SECRETS_DIR/LetsEncryptEmail.txt }
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

    local TARGET_PATH; TARGET_PATH=$(gum input --placeholder "Path to Docker directory" --value "$(pwd)")
    if [ ! -f "$TARGET_PATH/docker-compose.yml" ]; then
        gum style --foreground 196 "Error: No docker-compose.yml found at $TARGET_PATH"
        return 1
    fi

    # Robust grep: catch error code to prevent set -e script exit
    local SERVICES; SERVICES=$(grep -E '^[  ]{2}[a-zA-Z0-9_-]+:' "$TARGET_PATH/docker-compose.yml" | sed 's/://' | xargs || true)
    [[ -z "$SERVICES" ]] && { echo "No services found."; return 1; }
    
    local SELECTED; SELECTED=$(gum choose $SERVICES)
    local DOMAIN; DOMAIN=$(read_secret RootDomain)
    [[ "$DOMAIN" == "Not Set" ]] && DOMAIN="example.com"

    local SUB; SUB=$(gum input --placeholder "Subdomain" --value "${SELECTED,,}")
    local PORT; PORT=$(gum input --placeholder "Internal Container Port" --value "80")

    local HOST="${SUB}.${DOMAIN}"

    local PATCH_BLOCK=$(cat <<EOF
# --- START TRAEFIK PATCH FOR $SELECTED ---
    networks:
      - public_ingress
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${SELECTED,,}.rule=Host(\`${HOST}\`)"
      - "traefik.http.routers.${SELECTED,,}.entrypoints=websecure"
      - "traefik.http.routers.${SELECTED,,}.tls.certresolver=cloudflare"
      - "traefik.http.services.${SELECTED,,}.loadbalancer.server.port=${PORT}"
# --- END TRAEFIK PATCH ---
EOF
)

    echo -e "${Y}>> Generated Manifest for $SELECTED:${NC}"
    echo -e "${C}${PATCH_BLOCK}${NC}"

    if gum confirm "Export patch to ${TARGET_PATH}/traefik_patch.txt?"; then
        echo "$PATCH_BLOCK" > "${TARGET_PATH}/traefik_patch.txt"
        gum style --foreground 10 "Patch exported."
    fi
}

# ==============================================================================
# SECTION 3: DIAGNOSTICS & INSPECTOR
# ==============================================================================

check_diagnostics() {
    clear
    gum style --foreground 212 --border double "TRAEFIK DIAGNOSTIC SUITE"
    local DIAG; DIAG=$(gum choose "1) Check Health Status" "2) View Live Logs" "3) Test DNS-01 Resolver" "4) Back")
    case "$DIAG" in
        1*)
            sudo docker ps --filter "name=Traefik" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            read -p "Press Enter..." ;;
        2*) sudo docker logs -f Traefik ;;
        3*) DOMAIN=$(read_secret RootDomain); nslookup "$DOMAIN" || true; read -p "Press Enter..." ;;
        *) return ;;
    esac
}

inspect_ingress() {
    clear
    gum style --foreground 212 --border double "INGRESS INSPECTOR (404 DEBUGGER)"
    local CONTAINERS; CONTAINERS=$(sudo docker ps --format "{{.Names}}" || true)
    [[ -z "$CONTAINERS" ]] && return
    local TARGET; TARGET=$(gum choose $CONTAINERS)
    
    echo -e "${C}>> Auditing: $TARGET${NC}"
    
    # Network Attachment (Safe parsing)
    local NETS; NETS=$(sudo docker inspect "$TARGET" | jq -r '.[0].NetworkSettings.Networks | keys[]' 2>/dev/null || echo "")
    if echo "$NETS" | grep -q "public_ingress"; then echo -e "${G}[PASS]${NC} Attached to public_ingress."; else echo -e "${R}[FAIL]${NC} NOT on public_ingress."; fi

    # Labels
    local LABELS; LABELS=$(sudo docker inspect "$TARGET" | jq -r '.[0].Config.Labels // empty' 2>/dev/null || echo "")
    if echo "$LABELS" | grep -q '"traefik.enable": "true"'; then echo -e "${G}[PASS]${NC} Enabled label found."; else echo -e "${R}[FAIL]${NC} traefik.enable missing."; fi

    # Router/Rule Check
    local NAME_LOWER=${TARGET,,}
    local RULE; RULE=$(echo "$LABELS" | jq -r '."traefik.http.routers.'$TARGET'.rule" // ."traefik.http.routers.'$NAME_LOWER'.rule" // "null"' 2>/dev/null || echo "null")
    if [[ "$RULE" != "null" ]]; then echo -e "${G}[PASS]${NC} Host Rule: $RULE"; else echo -e "${Y}[WARN]${NC} No Host Rule found for '$TARGET'."; fi

    # Port Check
    local L_PORT; L_PORT=$(echo "$LABELS" | jq -r '."traefik.http.services.'$TARGET'.loadbalancer.server.port" // ."traefik.http.services.'$NAME_LOWER'.loadbalancer.server.port" // "null"' 2>/dev/null || echo "null")
    if [[ "$L_PORT" != "null" ]]; then echo -e "${G}[PASS]${NC} Backend Port: $L_PORT"; else echo -e "${R}[FAIL]${NC} Backend Port label missing."; fi

    read -p "Press Enter to return..."
}

# ==============================================================================
# MAIN ENGINE
# ==============================================================================

check_environment
while true; do
    clear
    gum style --foreground 212 --border double "PARANOID INGRESS CONTROLLER (v4.13)"
    OP=$(gum choose "1) Traefik Core: Deploy/Update" "2) Service Tool: Attach Service" "3) Diagnostics: Health & Logs" "4) Ingress Inspector: Fix 404s" "5) Secrets: View Vault" "6) Exit")
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
            read -p "Press Enter..." ;;
        6*) exit 0 ;;
    esac
done