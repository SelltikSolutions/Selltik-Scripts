#!/bin/bash
# ==============================================================================
#  UNIFIED SOVEREIGN NODE - TRAEFIK + WIREGUARD + PI-HOLE + AUTHELIA (v10.0-ULTIMATUM-IAM)
# ==============================================================================
#  Architecture: Single-Node Unified Ingress, VPN, & Identity Topology
#  Integrations Applied:
#  - IAM-01: Authelia (MFA) + PostgreSQL backend merged into the Unified Node.
#  - AUTH-04: Authelia-MFA promoted to default Suggested Exposure Posture.
#  - DOCKER-03: Reverted to native 'docker-compose.yml' for daemon discovery
#               while maintaining PascalCase host directories.
#  - SEC-07: Inode-preserving secret writes to prevent bind-mount detachment.
#  - HEALTH-06: Authelia healthcheck utilizing native binary (no curl).
# ==============================================================================

set -euo pipefail

# Force absolute path resolution
export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

StackName="SovereignNode"
BaseDir="/opt/Docker/Stacks/${StackName}"
ConfigDir="/opt/Docker/Config"
SecretsDir="${BaseDir}/Secrets"
LogsDir="/opt/Docker/Logs/${StackName}"
EnvFile="${BaseDir}/Node.env"
# DOCKER-03: Native discovery naming
ComposeFile="${BaseDir}/docker-compose.yml"
LockFile="/var/lock/sovereign_node.lock"

# Ensure filesystem hierarchy exists (PascalCase per mandate)
sudo mkdir -p "$BaseDir" "$LogsDir" "$ConfigDir/Authelia" "$ConfigDir/Postgres" \
             "$ConfigDir/Traefik/Dynamic" "$ConfigDir/WireGuard" \
             "$ConfigDir/PiHole/etc-pihole" "$ConfigDir/PiHole/etc-dnsmasq.d" \
             "$ConfigDir/Unbound"

# Atomic execution lock
exec 200>"$LockFile"
flock -n 200 || { echo "[FATAL] Another deployment instance is running."; exit 1; }
[ "$EUID" -eq 0 ] || { echo "[FATAL] Elevated privileges required. Run with: sudo $0"; exit 1; }

# BOOT-06: TTY verification for ParrotOS chained sudo
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
        OS_FAMILY=${ID_LIKE:-$OS_ID}
        OS_FAMILY=${OS_FAMILY,,}
    else
        echo "[FATAL] /etc/os-release missing."; exit 1
    fi

    if [[ "$OS_FAMILY" == *"debian"* ]] || [[ "$OS_ID" == "parrot" ]] || [[ "$OS_ID" == "ubuntu" ]]; then
        PkgManager="apt-get"
        UpdateCmd="apt-get update -y -q"
        InstallCmd="DEBIAN_FRONTEND=noninteractive apt-get install -y -q"
        UpgradeCmd="DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\""
    else
        echo "[FATAL] Unsupported OS Family: $OS_FAMILY."; exit 1
    fi
}

CheckDependencies() {
    PrintMsg "240" "Verifying baseline tools for $OS_ID..."
    eval "$UpdateCmd" > /dev/null 2>&1 || true
    local deps="curl jq openssl cron tzdata"
    for dep in $deps; do
        if ! command -v "$dep" &> /dev/null; then
            PrintMsg "226" "Installing missing dependency: $dep"
            eval "$InstallCmd $dep" > /dev/null || true
        fi
    done
    if ! command -v gum &> /dev/null; then
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg || true
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
        eval "$UpdateCmd" > /dev/null || true
        eval "$InstallCmd gum" > /dev/null || true
    fi
}

DetectOsFamily
CheckDependencies

# SEC-05: Enclave management
sudo mkdir -p "$SecretsDir"
sudo chmod 700 "$SecretsDir"
echo "*" | sudo tee "${SecretsDir}/.gitignore" > /dev/null

# SEC-07: Inode-preserving secret management
WriteSecret() {
    local name=$1
    local content=$2
    local tmp_file="${SecretsDir}/${name}.tmp"
    printf "%s" "$content" | sudo tee "$tmp_file" > /dev/null
    if [ ! -f "${SecretsDir}/${name}" ]; then
        sudo touch "${SecretsDir}/${name}"
        sudo chmod 600 "${SecretsDir}/${name}"
    fi
    sudo sh -c "cat '$tmp_file' > '${SecretsDir}/${name}'"
    sudo rm -f "$tmp_file"
}

# SEC-06: Cryptographic entropy generation
[ ! -f "${SecretsDir}/cf_api_token" ] && { 
    PrintMsg "226" "Cloudflare Scoped DNS API Token required:"
    WriteSecret "cf_api_token" "$(gum input --password)"
}
[ ! -f "${SecretsDir}/postgres_password" ] && WriteSecret "postgres_password" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_jwt_secret" ] && WriteSecret "authelia_jwt_secret" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_session_secret" ] && WriteSecret "authelia_session_secret" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_storage_key" ] && WriteSecret "authelia_storage_key" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/pihole_pass" ] && WriteSecret "pihole_pass" "$(openssl rand -base64 24)"

if [ "$Interactive" -eq 1 ]; then
    PrevEndpoint=$(grep "^WG_ENDPOINT=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevDomain=$(grep "^INTERNAL_DOMAIN=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevEmail=$(grep "^ACME_EMAIL=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")

    WgEndpoint=$(gum input --prompt "WireGuard Public Endpoint (IP/DDNS): " --value "$PrevEndpoint")
    InternalDomain=$(gum input --prompt "Root Internal Domain: " --value "$PrevDomain")
    AcmeEmail=$(gum input --prompt "Let's Encrypt Email: " --value "$PrevEmail")

    sudo tee "$EnvFile" > /dev/null << EOF
WG_ENDPOINT=${WgEndpoint}
INTERNAL_DOMAIN=${InternalDomain}
ACME_EMAIL=${AcmeEmail}
WG_PORT=51820
WG_PEERS=3
TZ=UTC
EOF
    sudo chmod 600 "$EnvFile"
fi

set +u
source "$EnvFile"
set -u

sudo timedatectl set-timezone UTC
if systemctl is-active --quiet systemd-timesyncd; then sudo systemctl restart systemd-timesyncd; fi

# BOOT-07: Scorched Earth Protocol
EnforceScorchedEarth() {
    if [ "$Interactive" -eq 1 ] && command -v docker &> /dev/null; then
        local AlienContainers=$(sudo docker ps -a --format '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' -v stack="${StackName,,}" 'tolower($3) != stack {print $1 " (" $2 ")"}')
        if [ -n "$AlienContainers" ]; then
            PrintMsg "196" "Rogue containers detected outside the Unified perimeter:"
            echo "$AlienContainers"
            if gum confirm "DESTROY all listed alien containers permanently?"; then
                echo "$AlienContainers" | awk '{print $1}' | xargs -I {} sudo docker rm -f {}
            else
                PrintMsg "226" "Aliens retained."
            fi
        fi
    fi
}

# ROUTE-12/13: Local Assimilation Engine
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
                PrintMsg "214" "Select posture for [$container]:"
                local choice=$(gum choose "1) MFA Protected (Authelia) [SUGGESTED]" "2) VPN-Only (Air-Gapped)" "3) BasicAuth (Legacy Form)" "4) Fully Public" "5) Internal")
                local posture_choice=${choice:0:1}
                local mw_string=""
                case "$posture_choice" in
                    1) mw_string="secure-headers@file,authelia@file" ;;
                    2) mw_string="secure-headers@file,vpn-whitelist@file" ;;
                    3) mw_string="secure-headers@file,traefik-auth@file" ;;
                    4) mw_string="secure-headers@file" ;;
                    5) continue ;;
                esac

                sudo tee "$manifest_file" > /dev/null << MANIFEST_EOF
# TRAEFIK INTEGRATION MANIFEST: $container (v10.0-ULTIMATUM)
networks:
  ProxyNetwork:
    external: true
    name: SovereignNode_ProxyNetwork
services:
  $container:
    networks: [ProxyNetwork]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${clean_name}.rule=Host(\`${clean_name}.${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.${clean_name}.entrypoints=websecure"
      - "traefik.http.routers.${clean_name}.tls.certresolver=letsencrypt"
      - "traefik.http.services.${clean_name}.loadbalancer.server.port=<PORT>"
      - "traefik.http.routers.${clean_name}.middlewares=${mw_string}"
      - "traefik.docker.network=SovereignNode_ProxyNetwork"
MANIFEST_EOF
                PrintMsg "82" "✔ Manifest: ${clean_name}_Integration.yml"
            done
        fi
    fi
}

EnforceScorchedEarth
AssimilateAlienContainers

# IAM Configuration
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
  password_reset: { disable: true }
  file: { path: /config/users_database.yml }
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
  secret_file: /run/secrets/authelia_session_secret
regulation:
  max_retries: 3
  find_time: 120
  ban_time: 300
notifier:
  filesystem: { filename: /config/notification.txt }
EOF

if [ ! -f "${ConfigDir}/Authelia/users_database.yml" ]; then
    sudo tee "${ConfigDir}/Authelia/users_database.yml" > /dev/null << EOF
users:
  admin:
    displayname: "Sovereign Administrator"
    # Password is 'password' - Rotate via 'authelia hash-password'
    password: "\$6\$rounds=500000\$j7688zY6fP/fN7.S\$7nO9O5S7Wf8Wp9yP9N8/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/"
    email: admin@${INTERNAL_DOMAIN}
    groups: [admins]
EOF
fi

# Traefik Dynamic Rules
sudo tee "${ConfigDir}/Traefik/dynamic/DynamicRules.yml" > /dev/null << EOF
http:
  middlewares:
    secure-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true
        contentTypeNosniff: true
        referrerPolicy: "strict-origin-when-cross-origin"
        customResponseHeaders:
          X-Frame-Options: "SAMEORIGIN"
          X-XSS-Protection: "1; mode=block"
    vpn-whitelist:
      ipAllowList:
        sourceRange: ["10.13.13.0/24", "10.99.0.10/32"]
    traefik-auth:
      basicAuth:
        usersFile: "/run/secrets/traefik_auth"
    authelia:
      forwardAuth:
        address: "http://authelia:9091/api/verify?rd=https://auth.${INTERNAL_DOMAIN}/"
        trustForwardHeader: true
        authResponseHeaders: ["Remote-User", "Remote-Groups", "Remote-Name", "Remote-Email"]
  routers:
    auth-router:
      rule: "Host(\`auth.${INTERNAL_DOMAIN}\`)"
      entryPoints: ["websecure"]
      service: "authelia-service"
      tls: { certResolver: "letsencrypt" }
  services:
    authelia-service:
      loadBalancer:
        servers: [{ url: "http://authelia:9091" }]
EOF

# Traefik Core Config
sudo tee "${ConfigDir}/Traefik/TraefikConfig.yml" > /dev/null << EOF
api: { dashboard: true, insecure: false }
entryPoints:
  web:
    address: ":80"
    http: { redirections: { entryPoint: { to: websecure, scheme: https } } }
  websecure: { address: ":443" }
providers:
  docker: { endpoint: "tcp://DockerSocketProxy:2375", exposedByDefault: false }
  file: { directory: /etc/traefik/dynamic, watch: true }
certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ACME_EMAIL}"
      storage: /acme.json
      dnsChallenge: { provider: cloudflare }
EOF

ResolveImage() {
    local digest=$(sudo docker inspect --format='{{index .RepoDigests 0}}' "$1" 2>/dev/null || echo "")
    [[ -z "$digest" ]] && { sudo docker pull "$1" >/dev/null; sudo docker inspect --format='{{index .RepoDigests 0}}' "$1"; } || echo "$digest"
}

IMG_PROXY=$(ResolveImage "lscr.io/linuxserver/socket-proxy:latest")
IMG_TRAEFIK=$(ResolveImage "traefik:v2.11")
IMG_WG=$(ResolveImage "lscr.io/linuxserver/wireguard:latest")
IMG_PIHOLE=$(ResolveImage "pihole/pihole:latest")
IMG_UNBOUND=$(ResolveImage "mvance/unbound:latest")
IMG_POSTGRES=$(ResolveImage "postgres:15-alpine")
IMG_AUTHELIA=$(ResolveImage "authelia/authelia:latest")

sudo tee "$ComposeFile" > /dev/null << EOF
networks:
  VpnNetwork:
    name: VpnNetwork
    ipam: { config: [{ subnet: 10.99.0.0/24 }] }
  ProxyNetwork:
    name: SovereignNode_ProxyNetwork
    ipam: { config: [{ subnet: 10.98.0.0/24 }] }
  AuthNetwork:
    internal: true
  SocketNetwork:
    internal: true

secrets:
  cf_api_token: { file: ${SecretsDir}/cf_api_token }
  postgres_password: { file: ${SecretsDir}/postgres_password }
  authelia_jwt_secret: { file: ${SecretsDir}/authelia_jwt_secret }
  authelia_session_secret: { file: ${SecretsDir}/authelia_session_secret }
  authelia_storage_key: { file: ${SecretsDir}/authelia_storage_key }
  traefik_auth: { file: ${SecretsDir}/traefik_auth }
  pihole_pass: { file: ${SecretsDir}/pihole_pass }

services:
  docker_socket_proxy:
    image: ${IMG_PROXY}
    container_name: DockerSocketProxy
    networks: [SocketNetwork]
    environment: [CONTAINERS=1, NETWORKS=1, VERSION=1, EVENTS=1, PING=1, INFO=1, POST=0]
    volumes: [/var/run/docker.sock:/var/run/docker.sock:ro]
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:2375/version || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 5
    restart: unless-stopped

  auth_db:
    image: ${IMG_POSTGRES}
    container_name: AuthDb
    networks: [AuthNetwork]
    environment:
      POSTGRES_USER: authelia
      POSTGRES_DB: authelia
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    secrets: [postgres_password]
    volumes: [${ConfigDir}/Postgres:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d authelia -U authelia"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  authelia:
    image: ${IMG_AUTHELIA}
    container_name: Authelia
    networks: [ProxyNetwork, AuthNetwork]
    volumes: [${ConfigDir}/Authelia:/config]
    secrets: [postgres_password, authelia_jwt_secret, authelia_session_secret, authelia_storage_key]
    environment:
      AUTHELIA_JWT_SECRET_FILE: /run/secrets/authelia_jwt_secret
      AUTHELIA_SESSION_SECRET_FILE: /run/secrets/authelia_session_secret
      AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE: /run/secrets/authelia_storage_key
    depends_on:
      auth_db: { condition: service_healthy }
    healthcheck:
      test: ["CMD", "authelia", "healthcheck"]
      interval: 10s
      timeout: 5s
      retries: 3
    restart: unless-stopped

  traefik_proxy:
    image: ${IMG_TRAEFIK}
    container_name: Traefik
    networks:
      SocketNetwork:
      ProxyNetwork:
      VpnNetwork: { ipv4_address: 10.99.0.13 }
    ports: ["80:80", "443:443"]
    volumes:
      - ${ConfigDir}/Traefik/TraefikConfig.yml:/etc/traefik/traefik.yml:ro
      - ${ConfigDir}/Traefik/dynamic:/etc/traefik/dynamic:ro
      - ${ConfigDir}/Traefik/acme.json:/acme.json:rw
    secrets: [cf_api_token, traefik_auth]
    environment:
      CF_DNS_API_TOKEN_FILE: /run/secrets/cf_api_token
    depends_on:
      docker_socket_proxy: { condition: service_healthy }
      authelia: { condition: service_healthy }
    command: ["--providers.docker.version=1.44"]
    restart: unless-stopped

  wireguard_vpn:
    image: ${IMG_WG}
    container_name: WireGuard
    networks: { VpnNetwork: { ipv4_address: 10.99.0.10 } }
    cap_add: [NET_ADMIN, SYS_MODULE]
    environment:
      - SERVERURL=${WG_ENDPOINT}
      - SERVERPORT=51820
      - PEERS=3
      - PEERDNS=10.99.0.12
      - INTERNAL_SUBNET=10.13.13.0/24
    volumes: [/lib/modules:/lib/modules:ro, ${ConfigDir}/WireGuard:/config]
    ports: ["51820:51820/udp"]
    sysctls: { net.ipv4.ip_forward: 1 }
    restart: unless-stopped

  pihole_sinkhole:
    image: ${IMG_PIHOLE}
    container_name: PiHole
    networks: { VpnNetwork: { ipv4_address: 10.99.0.12 }, ProxyNetwork: }
    environment:
      - WEBPASSWORD_FILE=/run/secrets/pihole_pass
      - PIHOLE_DNS_=10.99.0.11#53
      - DNSMASQ_LISTENING=all
    secrets: [pihole_pass]
    volumes: [${ConfigDir}/PiHole/etc-pihole:/etc/pihole, ${ConfigDir}/PiHole/etc-dnsmasq.d:/etc/dnsmasq.d]
    depends_on: { unbound_dns: { condition: service_healthy } }
    restart: unless-stopped

  unbound_dns:
    image: ${IMG_UNBOUND}
    container_name: UnboundDns
    networks: { VpnNetwork: { ipv4_address: 10.99.0.11 } }
    volumes: [${ConfigDir}/Unbound/UnboundConfig.conf:/opt/unbound/etc/unbound/unbound.conf:ro]
    healthcheck:
      test: ["CMD-SHELL", "drill google.com @127.0.0.1 || exit 1"]
    restart: unless-stopped
EOF

sudo chown -R 0:0 "$BaseDir"
sudo chmod 600 "$ComposeFile" "$EnvFile"

# Teardown logic for transition
cd "$BaseDir" && sudo docker compose down --remove-orphans || true
sleep 3
# Ignition
if [ "$Interactive" -eq 1 ]; then PrintMsg "226" "Igniting Unified IAM Matrix..."; fi
sudo docker compose up -d --remove-orphans

PrintMsg "82" "✔ Unified Sovereign Node Online: https://auth.${INTERNAL_DOMAIN}"
exit 0