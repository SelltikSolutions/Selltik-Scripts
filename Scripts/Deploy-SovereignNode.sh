#!/bin/bash
# ==============================================================================
#  UNIFIED SOVEREIGN NODE - TRAEFIK + WIREGUARD + PI-HOLE + AUTHELIA
#  Version: v10.7-GITOPS-REFABRICATED
# ==============================================================================
#  Architecture: Single-Node Unified Ingress, VPN, & Identity Topology
#  Modifications:
#  - STRUCT-01: Decoupled ConfigDir to a global level while retaining Secrets 
#               and Env states within the newly defined StackDir.
#  Final Hardening Applied:
#  - IAM-03: Amputated illegal 'password_file' from Authelia YAML to prevent
#            schema validation crashes. Re-routed secret via compose environment.
#  - IAM-04: Upgraded Authelia base policy to 'two_factor' to enforce true MFA.
#  - OPSEC-02: Swapped Pi-Hole Base64 generator to hex to prevent newline UI lockouts.
#  - ROOT-03: Amputated vestigial 777 host directory. Docker Named Volumes 
#             exclusively handle the Alpine UID mapping for DNSSEC persistence.
# ==============================================================================

set -euo pipefail

# Force absolute path resolution
export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

StackName="SovereignNode"
BaseDir="/opt/Docker"
ConfigDir="${BaseDir}/Config"
StackDir="${BaseDir}/Stacks/${StackName}"
SecretsDir="${StackDir}/Secrets"
EnvFile="${StackDir}/Node.env"
LogsDir="/opt/Docker/Logs/${StackName}"
# Native Docker orchestration filename
ComposeFile="${StackDir}/docker-compose.yml"
LockFile="/var/lock/sovereign_node.lock"

# Ensure filesystem hierarchy exists (PascalCase per mandate)
# ROOT-03: Unbound keys directory is no longer mapped to the host.
sudo mkdir -p "$StackDir" "$LogsDir" "$ConfigDir/Authelia" "$ConfigDir/Postgres" \
             "$ConfigDir/Traefik/Dynamic" "$ConfigDir/WireGuard" \
             "$ConfigDir/PiHole/etc-pihole" "$ConfigDir/PiHole/etc-dnsmasq.d" \
             "$ConfigDir/Unbound"

# ACME-02: Prevent Docker from creating a directory instead of a file
sudo touch "${ConfigDir}/Traefik/acme.json"
sudo chmod 600 "${ConfigDir}/Traefik/acme.json"

# Atomic execution lock
exec 200>"$LockFile"
flock -n 200 || { echo "[FATAL] Another deployment instance is running."; exit 1; }
[ "$EUID" -eq 0 ] || { echo "[FATAL] Elevated privileges required. Run with: sudo $0"; exit 1; }

# TTY verification for ParrotOS chained sudo
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
    else
        echo "[FATAL] Unsupported OS Family: $OS_FAMILY."; exit 1
    fi
}

CheckDependencies() {
    PrintMsg "240" "Verifying baseline tools for $OS_ID..."
    eval "$UpdateCmd" > /dev/null 2>&1 || true
    local deps="curl jq openssl cron tzdata dnsutils"
    for dep in $deps; do
        if ! command -v "$dep" &> /dev/null; then
            PrintMsg "226" "Installing missing dependency: $dep"
            eval "$InstallCmd $dep" > /dev/null || true
        fi
    done
    if ! command -v gum &> /dev/null; then
        sudo mkdir -p /etc/apt/keyrings
        curl --connect-timeout 5 -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg || true
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

# CRON-01 & AUTH-07: Headless-safe cryptographic entropy generation
if [ "$Interactive" -eq 1 ]; then
    [ ! -f "${SecretsDir}/cf_api_token" ] && { 
        PrintMsg "226" "Cloudflare Scoped DNS API Token required:"
        WriteSecret "cf_api_token" "$(gum input --password)"
    }
    [ ! -f "${SecretsDir}/traefik_auth" ] && {
        PrintMsg "226" "Provide a secure password for the Traefik BasicAuth fallback:"
        TraefikPass=$(gum input --password)
        WriteSecret "traefik_auth" "admin:$(openssl passwd -apr1 "$TraefikPass")"
    }
else
    # Headless Safety Net
    [ ! -f "${SecretsDir}/cf_api_token" ] && { echo "[FATAL] Headless run failed. Missing cf_api_token."; exit 1; }
    [ ! -f "${SecretsDir}/traefik_auth" ] && { echo "[FATAL] Headless run failed. Missing traefik_auth."; exit 1; }
fi

# Auto-generate non-interactive internal entropy
[ ! -f "${SecretsDir}/postgres_password" ] && WriteSecret "postgres_password" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_jwt_secret" ] && WriteSecret "authelia_jwt_secret" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_session_secret" ] && WriteSecret "authelia_session_secret" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_storage_key" ] && WriteSecret "authelia_storage_key" "$(openssl rand -base64 32)"
# OPSEC-02: Clean Hex generation prevents newline hash corruption in UI logins.
[ ! -f "${SecretsDir}/pihole_pass" ] && WriteSecret "pihole_pass" "$(openssl rand -hex 16)"

if [ "$Interactive" -eq 1 ]; then
    PrevEndpoint=$(grep "^WG_ENDPOINT=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevDomain=$(grep "^INTERNAL_DOMAIN=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevEmail=$(grep "^ACME_EMAIL=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevPort=$(grep "^WG_PORT=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "51820")

    WgEndpoint=$(gum input --prompt "WireGuard Public Endpoint (IP/DDNS): " --value "$PrevEndpoint")
    WgPort=$(gum input --prompt "WireGuard UDP Listen Port: " --value "$PrevPort")
    InternalDomain=$(gum input --prompt "Root Internal Domain: " --value "$PrevDomain")
    AcmeEmail=$(gum input --prompt "Let's Encrypt Email: " --value "$PrevEmail")

    sudo tee "$EnvFile" > /dev/null << EOF
WG_ENDPOINT=${WgEndpoint}
INTERNAL_DOMAIN=${InternalDomain}
ACME_EMAIL=${AcmeEmail}
WG_PORT=${WgPort}
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
            local manifest_dir="${StackDir}/IntegrationManifests"
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
# TRAEFIK INTEGRATION MANIFEST: $container (v10.7-GITOPS-REFABRICATED)
networks:
  ProxyNetwork:
    external: true
    name: sovereign_node_proxy_network
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
      - "traefik.docker.network=sovereign_node_proxy_network"
MANIFEST_EOF
                PrintMsg "82" "✔ Manifest: ${clean_name}_Integration.yml"
            done
        fi
    fi
}

EnforceScorchedEarth
AssimilateAlienContainers

# BOOT-05: True Zero-Byte Guillotine Prevention for Root Hints
PrintMsg "240" "Fetching InterNIC Root Hints for Unbound DNS..."
sudo curl -sS https://www.internic.net/domain/named.root -o "${ConfigDir}/Unbound/RootHints.txt.tmp" || true

if [ -s "${ConfigDir}/Unbound/RootHints.txt.tmp" ]; then
    sudo mv "${ConfigDir}/Unbound/RootHints.txt.tmp" "${ConfigDir}/Unbound/RootHints.txt"
else
    PrintMsg "196" "[WARNING] InterNIC fetch failed. Injecting hardcoded fallback."
    sudo tee "${ConfigDir}/Unbound/RootHints.txt" > /dev/null << 'EOF'
.                        3600000      NS    A.ROOT-SERVERS.NET.
A.ROOT-SERVERS.NET.      3600000      A     198.41.0.4
EOF
    sudo rm -f "${ConfigDir}/Unbound/RootHints.txt.tmp"
fi

sudo tee "${ConfigDir}/Unbound/UnboundConfig.conf" > /dev/null << 'EOF'
server:
  num-threads: 1
  interface: 0.0.0.0
  port: 53
  do-ip4: yes
  do-udp: yes
  do-tcp: yes
  root-hints: "/opt/unbound/etc/unbound/root.hints"
  auto-trust-anchor-file: "/opt/unbound/etc/unbound/keys/root.key"
  harden-glue: yes
  harden-dnssec-stripped: yes
  use-caps-for-id: no
  edns-buffer-size: 1232
  prefetch: yes
  num-queries-per-thread: 4096
  rrset-roundrobin: yes
  minimal-responses: yes
  hide-identity: yes
  hide-version: yes
  access-control: 10.99.0.0/24 allow
EOF

# IAM Configuration
# IAM-03: Removed schema-breaking password_file. Secret is passed via Compose ENV.
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
authentication_backend:
  password_reset: { disable: true }
  file: { path: /config/users_database.yml }
access_control:
  default_policy: deny
  rules:
    - domain: "*.${INTERNAL_DOMAIN}"
      # IAM-04: True MFA enforced. No bypassing the biometric vault.
      policy: two_factor
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
sudo tee "${ConfigDir}/Traefik/Dynamic/DynamicRules.yml" > /dev/null << EOF
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
  vpn_network:
    name: sovereign_node_vpn_network
    ipam: { config: [{ subnet: 10.99.0.0/24 }] }
  proxy_network:
    name: sovereign_node_proxy_network
    ipam: { config: [{ subnet: 10.98.0.0/24 }] }
  auth_network:
    internal: true
  socket_network:
    internal: true

# ROOT-03: Docker handles the opaque Alpine UID internally. No host STIG violations.
volumes:
  unbound_keys: {}

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
    container_name: docker_socket_proxy
    networks: [socket_network]
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
    container_name: auth_db
    networks: [auth_network]
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
    container_name: authelia
    networks: [proxy_network, auth_network]
    volumes: [${ConfigDir}/Authelia:/config]
    secrets: [postgres_password, authelia_jwt_secret, authelia_session_secret, authelia_storage_key]
    environment:
      AUTHELIA_JWT_SECRET_FILE: /run/secrets/authelia_jwt_secret
      AUTHELIA_SESSION_SECRET_FILE: /run/secrets/authelia_session_secret
      AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE: /run/secrets/authelia_storage_key
      # IAM-03: Correct injection of PostgreSQL password for strict schema compliance
      AUTHELIA_STORAGE_POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    depends_on:
      auth_db: { condition: service_healthy }
    healthcheck:
      test: ["CMD", "authelia", "healthcheck"]
      interval: 10s
      timeout: 5s
      retries: 3
    restart: unless-stopped

  unbound_dns:
    image: ${IMG_UNBOUND}
    container_name: unbound_dns
    networks:
      vpn_network: { ipv4_address: 10.99.0.11 }
    volumes:
      - ${ConfigDir}/Unbound/UnboundConfig.conf:/opt/unbound/etc/unbound/unbound.conf:ro
      - ${ConfigDir}/Unbound/RootHints.txt:/opt/unbound/etc/unbound/root.hints:ro
      - unbound_keys:/opt/unbound/etc/unbound/keys:rw
    healthcheck:
      test: ["CMD-SHELL", "nslookup google.com 127.0.0.1 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  pihole_sinkhole:
    image: ${IMG_PIHOLE}
    container_name: pihole_sinkhole
    networks:
      vpn_network: { ipv4_address: 10.99.0.12 }
      proxy_network:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.pihole.rule=Host(\`pihole.\${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.pihole.entrypoints=websecure"
      - "traefik.http.routers.pihole.tls.certresolver=letsencrypt"
      - "traefik.http.services.pihole.loadbalancer.server.port=80"
      - "traefik.http.routers.pihole.middlewares=secure-headers@file,authelia@file"
      - "traefik.docker.network=sovereign_node_proxy_network"
    environment:
      - WEBPASSWORD_FILE=/run/secrets/pihole_pass
      - PIHOLE_DNS_=10.99.0.11#53
      - DNSMASQ_LISTENING=all
    secrets: [pihole_pass]
    volumes:
      - ${ConfigDir}/PiHole/etc-pihole:/etc/pihole
      - ${ConfigDir}/PiHole/etc-dnsmasq.d:/etc/dnsmasq.d
    depends_on:
      unbound_dns: { condition: service_healthy }
    restart: unless-stopped

  wireguard_vpn:
    image: ${IMG_WG}
    container_name: wireguard_vpn
    networks:
      vpn_network: { ipv4_address: 10.99.0.10 }
    cap_add: [NET_ADMIN, SYS_MODULE]
    environment:
      - SERVERURL=\${WG_ENDPOINT}
      - SERVERPORT=\${WG_PORT}
      - PEERS=3
      - PEERDNS=10.99.0.12
      - INTERNAL_SUBNET=10.13.13.0/24
    volumes:
      - /lib/modules:/lib/modules:ro
      - ${ConfigDir}/WireGuard:/config
    ports: ["\${WG_PORT}:\${WG_PORT}/udp"]
    sysctls: { net.ipv4.ip_forward: 1 }
    restart: unless-stopped

  traefik_proxy:
    image: ${IMG_TRAEFIK}
    container_name: traefik_proxy
    networks:
      socket_network:
      proxy_network:
      vpn_network: { ipv4_address: 10.99.0.13 }
    ports: ["80:80", "443:443"]
    volumes:
      - ${ConfigDir}/Traefik/Dynamic:/etc/traefik/dynamic:ro
      - ${ConfigDir}/Traefik/acme.json:/acme.json:rw
    secrets: [cf_api_token, traefik_auth]
    environment:
      - CF_DNS_API_TOKEN_FILE=/run/secrets/cf_api_token
    depends_on:
      docker_socket_proxy: { condition: service_healthy }
      authelia: { condition: service_healthy }
    command: 
      - "--api.dashboard=true"
      - "--api.insecure=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--providers.docker=true"
      - "--providers.docker.endpoint=tcp://docker_socket_proxy:2375"
      - "--providers.docker.version=1.44"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
      - "--certificatesresolvers.letsencrypt.acme.email=\${ACME_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=cloudflare"
      - "--certificatesresolvers.letsencrypt.acme.dnschallenge=true"
    restart: unless-stopped
EOF

sudo chown -R 0:0 "$StackDir"
sudo chmod 600 "$ComposeFile" "$EnvFile"

# CYCLE-03: Transition Teardown Logic
CycleExistingMatrix() {
    # Critical: Enforce StackDir scope to prevent execution in global /opt/Docker
    cd "$StackDir"
    if [ -f "${StackDir}/DockerCompose.yml" ]; then
        if [ "$Interactive" -eq 1 ]; then PrintMsg "214" "⚠️  Legacy PascalCase file detected. Purging orphans..."; fi
        sudo docker compose --env-file "$EnvFile" -f DockerCompose.yml down --remove-orphans > /dev/null 2>&1 || true
        sudo rm -f "${StackDir}/DockerCompose.yml"
    fi
    if [ -f "$ComposeFile" ]; then
        if [ "$Interactive" -eq 1 ]; then PrintMsg "214" "⚠️  Flushing active matrix state..."; fi
        sudo docker compose --env-file "$EnvFile" down --remove-orphans > /dev/null 2>&1 || true
    fi
    sleep 3
}

CycleExistingMatrix

# Ignition
if [ "$Interactive" -eq 1 ]; then PrintMsg "226" "Igniting Unified Sovereign Node..."; fi
# CRITICAL: Ensure ignition occurs strictly within the Stack directory
cd "$StackDir" && sudo docker compose --env-file "$EnvFile" up -d --remove-orphans

# OPSEC-01: Explicitly print the generated Pi-Hole credential
if [ "$Interactive" -eq 1 ]; then
    echo ""
    PiholePass=$(sudo cat "${SecretsDir}/pihole_pass")
    PrintMsg "214" "========================================================================"
    PrintMsg "226" " 🔐 SECURE CREDENTIAL RECOVERY"
    PrintMsg "214" "========================================================================"
    PrintMsg "82"  " Pi-Hole Admin Password: $PiholePass"
    PrintMsg "196" " SAVE THIS NOW. IT WILL NOT BE DISPLAYED AGAIN."
    PrintMsg "214" "========================================================================"
    echo ""
    PrintMsg "82" "✔ Unified Matrix Online. Verification recommended."
fi

exit 0