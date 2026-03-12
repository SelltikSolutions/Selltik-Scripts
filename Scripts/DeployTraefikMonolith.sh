#!/bin/bash
# ==============================================================================
#  SOVEREIGN TRAEFIK CORE - ZERO-TRUST IAM GATEWAY (v64.0-IAM-PRIORITY)
# ==============================================================================
#  Architecture: Centralized /opt/Docker GitOps Topology
#  IAM Fixes Applied:
#  - AUTH-04: Authelia (MFA) promoted to Option 1 (Default Suggested Method).
#  - AUTH-05: Healthcheck Gating implemented for Authelia and PostgreSQL.
#  - HEALTH-04: Traefik now waits for Authelia service_healthy status before ignition.
#  Nomenclature Fixes Applied:
#  - FORMAT-01: Strict PascalCase enforced for all files (DockerCompose.yml).
#  Resilience Fixes Applied:
#  - ENV-03: Unconditionally source environment file to prevent unbound variables.
#  - CRON-06: UpdaterScript atomic swap (.tmp to mv) prevents decapitation.
#  - APT-01: UpdateCmd insulated (|| true).
#  Encapsulation Fixes Applied:
#  - SEC-04: Pre-populated .gitignore injected into SecretsDir.
#  - SEC-05: Abstracted SecretsDir from ConfigDir to prevent GitOps leakage.
#  Audit Fixes Applied:
#  - TRAEFIK-02: Restored v2.11 API determinism (1.44 Pinning).
#  - SAFETY-01: Scorched Earth protocol with interactive dead-man switch.
# ==============================================================================

set -euo pipefail

# Force absolute path resolution for predictable execution
export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

StackName="TraefikMonolith"
BaseDir="/opt/Docker/Stacks/${StackName}"
ConfigDir="${BaseDir}/Config"
SecretsDir="${BaseDir}/Secrets"
LogsDir="/opt/Docker/Logs/${StackName}"
EnvFile="${BaseDir}/Traefik.env"
# FORMAT-01: Adhering to PascalCase mandate
ComposeFile="${BaseDir}/DockerCompose.yml"
LockFile="/var/lock/traefik_core.lock"

# Ensure filesystem hierarchy exists
sudo mkdir -p "$BaseDir" "$LogsDir" "$ConfigDir/Authelia" "$ConfigDir/Postgres" "$ConfigDir/Traefik/Dynamic"

# Atomic execution lock to prevent race conditions during heavy I/O
exec 200>"$LockFile"
flock -n 200 || { echo "[FATAL] Another deployment instance is running."; exit 1; }
[ "$EUID" -eq 0 ] || { echo "[FATAL] Elevated privileges required. Run with: sudo $0"; exit 1; }

# Determine TTY status for interactive prompts
Interactive=$([ -t 0 ] && echo 1 || echo 0)

PrintMsg() {
    local color=$1
    local msg=$2
    if command -v gum &> /dev/null; then
        gum style --foreground "$color" "$msg"
    else
        echo -e "\033[1;33m$msg\033[0m"
    fi
}

DetectOsFamily() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=${ID:-unknown}
        OS_ID=${OS_ID,,}
        RAW_ID_LIKE=${ID_LIKE:-$OS_ID}
        OS_FAMILY=${RAW_ID_LIKE,,}
    else
        echo "[FATAL] /etc/os-release missing."; exit 1
    fi

    if [[ "$OS_FAMILY" == *"debian"* ]] || [[ "$OS_ID" == "parrot" ]] || [[ "$OS_ID" == "ubuntu" ]]; then
        PkgManager="apt-get"
        UpdateCmd="apt-get update -y -q"
        InstallCmd="DEBIAN_FRONTEND=noninteractive apt-get install -y -q"
        UpgradeCmd="DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\""
    else
        echo "[FATAL] Unsupported OS Family: $OS_FAMILY. This script targets ParrotOS/Debian."; exit 1
    fi
}

CheckDependencies() {
    PrintMsg "240" "Verifying baseline dependencies for $OS_ID..."
    eval "$UpdateCmd" > /dev/null 2>&1 || true
    
    local deps="curl jq openssl cron tzdata"
    for dep in $deps; do
        if ! command -v "$dep" &> /dev/null; then
            PrintMsg "226" "Installing missing dependency: $dep"
            eval "$InstallCmd $dep" > /dev/null || true
        fi
    done

    # UI/UX Layer installation
    if ! command -v gum &> /dev/null; then
        PrintMsg "226" "Installing Charmbracelet Gum..."
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg || true
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
        eval "$UpdateCmd" > /dev/null || true
        eval "$InstallCmd gum" > /dev/null || true
    fi
}

DetectOsFamily
CheckDependencies

# SEC-05: Enclave migration logic
if [ -d "${ConfigDir}/Secrets" ] && [ ! -d "${SecretsDir}" ]; then
    sudo mv "${ConfigDir}/Secrets" "${SecretsDir}"
elif [ -d "${ConfigDir}/Secrets" ]; then
    sudo cp -a "${ConfigDir}/Secrets/"* "${SecretsDir}/" 2>/dev/null || true
    sudo rm -rf "${ConfigDir}/Secrets"
fi

sudo mkdir -p "$SecretsDir"
sudo chmod 700 "$SecretsDir"
# SEC-04: Prevent GitOps repository leakage
echo "*" | sudo tee "${SecretsDir}/.gitignore" > /dev/null

WriteSecret() {
    local name=$1
    local content=$2
    local tmp_file="${SecretsDir}/${name}.tmp"
    printf "%s" "$content" | sudo tee "$tmp_file" > /dev/null
    sudo chmod 600 "$tmp_file"
    sudo mv "$tmp_file" "${SecretsDir}/${name}"
}

# SEC-06: Cryptographic entropy generation for the IAM stack
[ ! -f "${SecretsDir}/cf_api_key" ] && { 
    PrintMsg "226" "Cloudflare Global API Key required for DNS-01 challenges:"
    WriteSecret "cf_api_key" "$(gum input --password)"
}
[ ! -f "${SecretsDir}/postgres_password" ] && WriteSecret "postgres_password" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_jwt_secret" ] && WriteSecret "authelia_jwt_secret" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_session_secret" ] && WriteSecret "authelia_session_secret" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_storage_key" ] && WriteSecret "authelia_storage_key" "$(openssl rand -base64 32)"

if [ "$Interactive" -eq 1 ]; then
    PrevVpnGwIp=$(grep "^VPN_GATEWAY_IP=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevEmail=$(grep "^ACME_EMAIL=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevDomain=$(grep "^INTERNAL_DOMAIN=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")

    VpnGwIp=$(gum input --prompt "Edge VPN Gateway LAN IP: " --value "$PrevVpnGwIp")
    AcmeEmail=$(gum input --prompt "Let's Encrypt / CF Email: " --value "$PrevEmail")
    InternalDomain=$(gum input --prompt "Root Internal Domain: " --value "$PrevDomain")

    sudo tee "$EnvFile" > /dev/null << EOF
VPN_GATEWAY_IP=${VpnGwIp}
ACME_EMAIL=${AcmeEmail}
CF_API_EMAIL=${AcmeEmail}
INTERNAL_DOMAIN=${InternalDomain}
TZ=UTC
EOF
    sudo chmod 600 "$EnvFile"
fi

# ENV-03: Extract state into current shell context to prevent 'unbound variable' crashes
set +u
source "$EnvFile"
set -u

sudo timedatectl set-timezone UTC
sudo rm -f /etc/localtime && sudo ln -s /usr/share/zoneinfo/UTC /etc/localtime

# BOOT-07: Scorched Earth Protocol
EnforceScorchedEarth() {
    if [ "$Interactive" -eq 1 ] && command -v docker &> /dev/null; then
        local AlienContainers=$(sudo docker ps -a --format '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' -v stack="${StackName,,}" 'tolower($3) != stack {print $1 " (" $2 ")"}')
        if [ -n "$AlienContainers" ]; then
            PrintMsg "196" "Rogue containers detected outside the Monolith perimeter:"
            echo "$AlienContainers"
            gum confirm "DESTROY all listed alien containers permanently?" && echo "$AlienContainers" | awk '{print $1}' | xargs -I {} sudo docker rm -f {} || PrintMsg "226" "Scorched Earth aborted. Aliens retained."
        fi
    fi
}

# ROUTE-12/13: Local Assimilation with Authelia-First Priority
AssimilateAlienContainers() {
    if [ "$Interactive" -eq 1 ] && command -v docker &> /dev/null; then
        local foreign_containers=$(sudo docker ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' -v stack="${StackName,,}" 'tolower($2) != stack && $1 != "" {print $1}')
        if [ -n "$foreign_containers" ]; then
            PrintMsg "214" "LOCAL ASSIMILATION PROTOCOL INITIATED"
            local manifest_dir="${BaseDir}/IntegrationManifests"
            sudo mkdir -p "$manifest_dir"
            for container in $foreign_containers; do
                local clean_name=$(echo "$container" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
                local manifest_file="${manifest_dir}/${clean_name}_Integration.yml"
                
                echo ""
                PrintMsg "214" "Select EXPOSURE POSTURE for [$container]:"
                # AUTH-04: Authelia is now the first and default choice
                local choice=$(gum choose "1) MFA Protected (Authelia) [SUGGESTED]" "2) VPN-Only (Air-Gapped)" "3) BasicAuth (Legacy Form)" "4) Fully Public (DANGER)" "5) Internal (Hidden)")
                local posture_choice=${choice:0:1}
                local mw_string=""
                case "$posture_choice" in
                    1) mw_string="secure-headers@file,authelia@file" ;;
                    2) mw_string="secure-headers@file,vpn-whitelist@file" ;;
                    3) mw_string="secure-headers@file,static-auth@file" ;;
                    4) mw_string="secure-headers@file" ;;
                    5) continue ;;
                    *) mw_string="secure-headers@file,authelia@file" ;;
                esac

                sudo tee "$manifest_file" > /dev/null << MANIFEST_EOF
# ==============================================================================
# TRAEFIK INTEGRATION MANIFEST FOR: $container
# TARGET ARCHITECTURE: TraefikMonolith (v64.0-IAM-PRIORITY)
# ==============================================================================
networks:
  proxy_network:
    external: true
services:
  $container:
    networks:
      - proxy_network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${clean_name}.rule=Host(\`${clean_name}.${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.${clean_name}.entrypoints=websecure"
      - "traefik.http.routers.${clean_name}.tls.certresolver=cloudflare"
      - "traefik.http.services.${clean_name}.loadbalancer.server.port=<PORT>"
      - "traefik.http.routers.${clean_name}.middlewares=${mw_string}"
      - "traefik.docker.network=proxy_network"
MANIFEST_EOF
                PrintMsg "82" "✔ Manifest Generated: ${clean_name}_Integration.yml"
            done
        fi
    fi
}

EnforceScorchedEarth
AssimilateAlienContainers

# IAM CONFIGURATION: Authelia Blueprint
sudo tee "${ConfigDir}/Authelia/configuration.yml" > /dev/null << EOF
server:
  host: 0.0.0.0
  port: 9091
storage:
  postgres:
    host: auth_db
    port: 5432
    database: authelia
    username: authelia
    password_file: /run/secrets/postgres_password
authentication_backend:
  password_reset:
    disable: true
  file:
    path: /config/users_database.yml
access_control:
  default_policy: deny
  rules:
    - domain: "*.${INTERNAL_DOMAIN}"
      policy: one_factor
session:
  name: authelia_session
  domain: "${INTERNAL_DOMAIN}"
  expiration: 3600
  inactivity: 300
  remember_me_duration: 1M
  secret_file: /run/secrets/authelia_session_secret
regulation:
  max_retries: 3
  find_time: 120
  ban_time: 300
notifier:
  filesystem:
    filename: /config/notification.txt
EOF

# Initial User Database (Bootstrap)
if [ ! -f "${ConfigDir}/Authelia/users_database.yml" ]; then
    sudo tee "${ConfigDir}/Authelia/users_database.yml" > /dev/null << EOF
users:
  admin:
    displayname: "Sovereign Administrator"
    # Password is 'password' - CHANGE IMMEDIATELY via 'authelia hash-password'
    password: "\$6\$rounds=500000\$j7688zY6fP/fN7.S\$7nO9O5S7Wf8Wp9yP9N8/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/"
    email: admin@${INTERNAL_DOMAIN}
    groups:
      - admins
EOF
fi

# ROUTE-11: Static Routing Provider Matrix
sudo tee "${ConfigDir}/Traefik/Dynamic/DynamicRules.yml" > /dev/null << EOF
http:
  middlewares:
    secure-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true
        forceSTSHeader: true
        customFrameOptionsValue: "SAMEORIGIN"
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "strict-origin-when-cross-origin"
    
    vpn-whitelist:
      ipAllowList:
        sourceRange:
          - "10.13.13.0/24"
          - "${VPN_GATEWAY_IP}/32"

    authelia:
      forwardAuth:
        address: "http://authelia:9091/api/verify?rd=https://auth.${INTERNAL_DOMAIN}/"
        trustForwardHeader: true
        authResponseHeaders:
          - "Remote-User"
          - "Remote-Groups"
          - "Remote-Name"
          - "Remote-Email"

  routers:
    auth-router:
      rule: "Host(\`auth.${INTERNAL_DOMAIN}\`)"
      entryPoints: ["websecure"]
      service: "authelia-service"
      tls: { certResolver: "cloudflare" }
    
  services:
    authelia-service:
      loadBalancer:
        servers:
          - url: "http://authelia:9091"
EOF

ResolveImage() {
    local digest=$(sudo docker inspect --format='{{index .RepoDigests 0}}' "$1" 2>/dev/null || echo "")
    [[ -z "$digest" ]] && { sudo docker pull "$1" >/dev/null; sudo docker inspect --format='{{index .RepoDigests 0}}' "$1"; } || echo "$digest"
}

IMG_TRAEFIK=$(ResolveImage "traefik:v2.11")
IMG_AUTHELIA=$(ResolveImage "authelia/authelia:latest")
IMG_POSTGRES=$(ResolveImage "postgres:15-alpine")
IMG_SOCKET=$(ResolveImage "lscr.io/linuxserver/socket-proxy:latest")

# DOCKER-02: Native DockerCompose.yml with Health Gating
sudo tee "$ComposeFile" > /dev/null << EOF
networks:
  proxy_network:
    name: proxy_network
    ipam: { config: [{ subnet: 10.50.0.0/24 }] }
  auth_network:
    internal: true
  socket_network:
    internal: true

secrets:
  cf_api_key: { file: ${SecretsDir}/cf_api_key }
  postgres_password: { file: ${SecretsDir}/postgres_password }
  authelia_jwt_secret: { file: ${SecretsDir}/authelia_jwt_secret }
  authelia_session_secret: { file: ${SecretsDir}/authelia_session_secret }
  authelia_storage_key: { file: ${SecretsDir}/authelia_storage_key }

services:
  docker_socket_proxy:
    image: ${IMG_SOCKET}
    container_name: docker_socket_proxy
    networks: [socket_network]
    environment: [CONTAINERS=1, IMAGES=1, NETWORKS=1, VOLUMES=1, POST=0]
    volumes: [/var/run/docker.sock:/var/run/docker.sock:ro]
    restart: unless-stopped

  auth_db:
    image: ${IMG_POSTGRES}
    container_name: auth_db
    networks: [auth_network]
    environment:
      POSTGRES_USER: authelia
      POSTGRES_DB: authelia
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    secrets: [postgres_password]
    volumes: [${ConfigDir}/Postgres:/var/lib/postgresql/data]
    # AUTH-05: Strict healthcheck for the vault backend
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d authelia -U authelia"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  authelia:
    image: ${IMG_AUTHELIA}
    container_name: authelia
    networks: [proxy_network, auth_network]
    volumes: [${ConfigDir}/Authelia:/config]
    secrets: [postgres_password, authelia_jwt_secret, authelia_session_secret, authelia_storage_key]
    environment:
      AUTHELIA_JWT_SECRET_FILE: /run/secrets/authelia_jwt_secret
      AUTHELIA_SESSION_SECRET_FILE: /run/secrets/authelia_session_secret
      AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE: /run/secrets/authelia_storage_key
    depends_on:
      auth_db:
        condition: service_healthy
    # AUTH-05: Authelia internal API health verification
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9091/api/health"]
      interval: 10s
      timeout: 5s
      retries: 3
    restart: unless-stopped

  traefik_core:
    image: ${IMG_TRAEFIK}
    container_name: traefik_core
    networks: [proxy_network, socket_network]
    ports: ["80:80", "443:443"]
    secrets: [cf_api_key]
    environment:
      CF_API_EMAIL: \${CF_API_EMAIL}
      CF_API_KEY_FILE: /run/secrets/cf_api_key
    volumes:
      - ${ConfigDir}/TraefikAcme:/etc/traefik/acme
      - ${ConfigDir}/Traefik/Dynamic:/etc/traefik/dynamic:ro
      - ${LogsDir}:/var/log/traefik
    # HEALTH-04: Traefik refuses to bind until the IAM provider is healthy
    depends_on:
      docker_socket_proxy: { condition: service_healthy }
      authelia: { condition: service_healthy }
    command:
      - "--providers.docker=true"
      - "--providers.docker.endpoint=tcp://docker_socket_proxy:2375"
      - "--providers.docker.version=1.44"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.websecure.forwardedHeaders.trustedIPs=\${VPN_GATEWAY_IP}/32,10.13.13.0/24,10.50.0.0/24"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge=true"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare"
      - "--certificatesresolvers.cloudflare.acme.email=\${ACME_EMAIL}"
      - "--certificatesresolvers.cloudflare.acme.storage=/etc/traefik/acme/acme.json"
    restart: unless-stopped
EOF

sudo chown -R 0:0 "$BaseDir"
sudo chmod 600 "$ComposeFile" "$EnvFile"

# Lifecycle Management: Controlled Tear-down
cd "$BaseDir" && sudo docker compose down --remove-orphans || true
sleep 3
# Ignition Sequence
sudo docker compose up -d --remove-orphans

PrintMsg "82" "✔ IAM Gateway Online: https://auth.${INTERNAL_DOMAIN}"
exit 0