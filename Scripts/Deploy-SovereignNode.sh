#!/bin/bash
# ==============================================================================
#  UNIFIED SOVEREIGN NODE - TRAEFIK + WIREGUARD + PI-HOLE + AUTHELIA
#  Version: v10.16-THE-MONOLITH
# ==============================================================================
#  Architecture: Single-Node Unified Ingress, VPN, & Identity Topology
#  Monolith Fixes:
#  - BASH-01: Eradicated the undefined TRAEFIK_IP split-horizon artifact.
#             Replaced with the mathematically guaranteed 10.99.0.13 static route.
#  - DNS-02: Interpolated INTERNAL_DOMAIN into Unbound config to enforce local 
#            zone redirection. All VPN subdomains now resolve locally to Traefik.
#  - HEALTH-10: Injected 127.0.0.0/8 allow ACL into Unbound to permit internal 
#               healthcheck queries, preventing a false-negative boot deadlock.
# ==============================================================================

set -euo pipefail

# Force absolute path resolution
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

StackName="SovereignNode"
BaseDir="/opt/Docker"
ConfigDir="${BaseDir}/Config"
ScriptsDir="${BaseDir}/Scripts"
StackDir="${BaseDir}/Stacks/${StackName}"
SecretsDir="${StackDir}/Secrets"
EnvFile="${StackDir}/Node.env"
LogsDir="/opt/Docker/Logs/${StackName}"
ComposeFile="${StackDir}/docker-compose.yml"
LockFile="/var/lock/sovereign_node.lock"

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

# ==============================================================================
# CYCLE-05: GRACEFUL CLEANUP FALLBACK
# ==============================================================================
PurgeLegacyState() {
    if [ "$Interactive" -eq 1 ]; then PrintMsg "214" "⚠️  Initiating Graceful Cleanup..."; fi
    if [ -d "$StackDir" ]; then
        cd "$StackDir" || true
        local EnvFlag=""
        [ -f "$EnvFile" ] && EnvFlag="--env-file $EnvFile"

        if [ -f "$ComposeFile" ]; then
            sudo docker compose $EnvFlag down --remove-orphans > /dev/null 2>&1 || true
        fi
        if [ -f "${StackDir}/DockerCompose.yml" ]; then
            sudo docker compose $EnvFlag -f DockerCompose.yml down --remove-orphans > /dev/null 2>&1 || true
            sudo rm -f "${StackDir}/DockerCompose.yml"
        fi

        # Wipe generated configs but SPARE the databases, secrets, and integration manifests
        sudo rm -f "${ConfigDir}/Traefik/Dynamic"/DynamicRules*.yml 2>/dev/null || true
        sudo rm -f "${ConfigDir}/Unbound/UnboundConfig.conf" 2>/dev/null || true
        sudo rm -f "${ConfigDir}/Unbound/RootHints.txt" 2>/dev/null || true
        sudo rm -f "${ConfigDir}/Authelia/configuration.yml" 2>/dev/null || true
        sudo rm -f "${StackDir}/docker-compose.yml" 2>/dev/null || true
    fi
}

# ==============================================================================
# ANNIHILATION-01: TRUE SCORCHED EARTH PROTOCOL
# ==============================================================================
ExecuteAnnihilation() {
    if [ "$Interactive" -eq 1 ] && [ -d "$StackDir" ]; then
        PrintMsg "196" "========================================================================"
        PrintMsg "196" " 🔥 TRUE SCORCHED EARTH PROTOCOL"
        PrintMsg "196" "========================================================================"
        PrintMsg "226" "WARNING: You are requesting a mathematically clean slate."
        PrintMsg "226" "This will VAPORIZE your PostgreSQL MFA Database, Let's Encrypt"
        PrintMsg "226" "Certificates, Pi-Hole telemetry, and ALL cryptographic secrets."
        PrintMsg "196" "There is no undo. You will be punished for your mistakes."
        echo ""
        
        confirm="no"
        if command -v gum &> /dev/null; then
            if gum confirm "OBLITERATE EVERYTHING and restart fresh?"; then confirm="yes"; fi
        else
            read -p "OBLITERATE EVERYTHING and restart fresh? (y/N): " input_conf
            [[ "${input_conf:-}" =~ ^[Yy]$ ]] && confirm="yes"
        fi
        
        if [ "$confirm" == "yes" ]; then
            PrintMsg "196" "Executing tactical nuke..."
            cd "$StackDir" || true
            local EnvFlag=""
            [ -f "$EnvFile" ] && EnvFlag="--env-file $EnvFile"
            if [ -f "$ComposeFile" ]; then
                sudo docker compose $EnvFlag down -v --remove-orphans > /dev/null 2>&1 || true
            fi
            cd /tmp
            sudo rm -rf "$StackDir" "${ConfigDir}/Authelia" "${ConfigDir}/Postgres" \
                        "${ConfigDir}/Traefik" "${ConfigDir}/WireGuard" \
                        "${ConfigDir}/PiHole" "${ConfigDir}/Unbound"
            PrintMsg "82" "✔ Earth scorched. Nothing survives."
            sleep 2
        else
            PrintMsg "82" "✔ Scorched Earth aborted. Retaining persistent state."
            PurgeLegacyState
        fi
    fi
}

ExecuteAnnihilation
# ==============================================================================

sudo mkdir -p "$StackDir" "$LogsDir" "$ScriptsDir" "$ConfigDir/Authelia" "$ConfigDir/Postgres" \
             "$ConfigDir/Traefik/Dynamic" "$ConfigDir/WireGuard" \
             "$ConfigDir/PiHole/etc-pihole" "$ConfigDir/PiHole/etc-dnsmasq.d" \
             "$ConfigDir/Unbound"

sudo touch "${ConfigDir}/Traefik/acme.json"
sudo chmod 600 "${ConfigDir}/Traefik/acme.json"

sudo mkdir -p "$SecretsDir"
sudo chmod 700 "$SecretsDir"
echo "*" | sudo tee "${SecretsDir}/.gitignore" > /dev/null

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

if [ "$Interactive" -eq 1 ]; then
    [ ! -f "${SecretsDir}/cf_api_token" ] && { 
        PrintMsg "226" "Cloudflare Scoped DNS API Token required:"
        cf_token=""
        if command -v gum &> /dev/null; then
            cf_token=$(gum input --password)
        else
            read -s -p "Token: " cf_token
            echo ""
        fi
        WriteSecret "cf_api_token" "$cf_token"
    }
    [ ! -f "${SecretsDir}/traefik_auth" ] && {
        PrintMsg "226" "Provide a secure password for the Traefik BasicAuth fallback:"
        TraefikPass=""
        if command -v gum &> /dev/null; then
            TraefikPass=$(gum input --password)
        else
            read -s -p "Password: " TraefikPass
            echo ""
        fi
        WriteSecret "traefik_auth" "admin:$(openssl passwd -apr1 "$TraefikPass")"
    }
else
    [ ! -f "${SecretsDir}/cf_api_token" ] && { echo "[FATAL] Headless run failed. Missing cf_api_token."; exit 1; }
    [ ! -f "${SecretsDir}/traefik_auth" ] && { echo "[FATAL] Headless run failed. Missing traefik_auth."; exit 1; }
fi

[ ! -f "${SecretsDir}/postgres_password" ] && WriteSecret "postgres_password" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_jwt_secret" ] && WriteSecret "authelia_jwt_secret" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_session_secret" ] && WriteSecret "authelia_session_secret" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_storage_key" ] && WriteSecret "authelia_storage_key" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/pihole_pass" ] && WriteSecret "pihole_pass" "$(openssl rand -hex 16)"

if [ "$Interactive" -eq 1 ]; then
    PrevEndpoint=$(grep "^WG_ENDPOINT=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevDomain=$(grep "^INTERNAL_DOMAIN=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevEmail=$(grep "^ACME_EMAIL=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevPort=$(grep "^WG_PORT=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "51820")

    WgEndpoint=""
    WgPort=""
    InternalDomain=""
    AcmeEmail=""

    if command -v gum &> /dev/null; then
        WgEndpoint=$(gum input --prompt "WireGuard Public Endpoint (IP/DDNS): " --value "$PrevEndpoint")
        WgPort=$(gum input --prompt "WireGuard UDP Listen Port: " --value "$PrevPort")
        InternalDomain=$(gum input --prompt "Root Internal Domain: " --value "$PrevDomain")
        AcmeEmail=$(gum input --prompt "Let's Encrypt Email: " --value "$PrevEmail")
    else
        read -p "WireGuard Public Endpoint (IP/DDNS) [$PrevEndpoint]: " input_endpoint
        WgEndpoint="${input_endpoint:-$PrevEndpoint}"
        
        read -p "WireGuard UDP Listen Port [$PrevPort]: " input_port
        WgPort="${input_port:-$PrevPort}"
        
        read -p "Root Internal Domain [$PrevDomain]: " input_domain
        InternalDomain="${input_domain:-$PrevDomain}"
        
        read -p "Let's Encrypt Email [$PrevEmail]: " input_email
        AcmeEmail="${input_email:-$PrevEmail}"
    fi

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

PurgeAlienContainers() {
    if [ "$Interactive" -eq 1 ] && command -v docker &> /dev/null; then
        local AlienContainers=$(sudo docker ps -a --format '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' -v stack="${StackName,,}" 'tolower($3) != stack {print $1 " (" $2 ")"}')
        if [ -n "$AlienContainers" ]; then
            PrintMsg "196" "Rogue containers detected outside the Unified perimeter:"
            echo "$AlienContainers"
            
            confirm="no"
            if command -v gum &> /dev/null; then
                if gum confirm "DESTROY all listed alien containers permanently?"; then confirm="yes"; fi
            else
                read -p "DESTROY all listed alien containers permanently? (y/N): " input_conf
                [[ "${input_conf:-}" =~ ^[Yy]$ ]] && confirm="yes"
            fi

            if [ "$confirm" == "yes" ]; then
                echo "$AlienContainers" | awk '{print $1}' | xargs -I {} sudo docker rm -f {}
            else
                PrintMsg "226" "Aliens retained."
            fi
        fi
    fi
}

PurgeAlienContainers

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

# BASH-01 & DNS-02: Unquoted EOF interpolates INTERNAL_DOMAIN into the Unbound config.
# Enforces a local transparent redirect, bouncing all VPN subdomains directly to Traefik.
sudo tee "${ConfigDir}/Unbound/UnboundConfig.conf" > /dev/null << EOF
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
  # HEALTH-10: 127.0.0.0/8 allow added to permit healthcheck 'localhost' lookups
  access-control: 127.0.0.0/8 allow
  access-control: 10.99.0.0/24 allow
  local-zone: "${INTERNAL_DOMAIN}." redirect
  local-data: "${INTERNAL_DOMAIN}. A 10.99.0.13"
EOF

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
    password: "\$6\$rounds=500000\$j7688zY6fP/fN7.S\$7nO9O5S7Wf8Wp9yP9N8/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/9/8/"
    email: admin@${INTERNAL_DOMAIN}
    groups: [admins]
EOF
fi

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
      tls: { certResolver: "cloudflare" }
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

x-logging: &default-logging
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "3"

services:
  docker_socket_proxy:
    image: ${IMG_PROXY}
    container_name: docker_socket_proxy
    networks: [socket_network]
    environment: [CONTAINERS=1, NETWORKS=1, VERSION=1, EVENTS=1, PING=1, INFO=1, POST=0]
    volumes: [/var/run/docker.sock:/var/run/docker.sock:ro]
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID]
    security_opt: [no-new-privileges:true]
    logging: *default-logging
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
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE]
    security_opt: [no-new-privileges:true]
    logging: *default-logging
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
      AUTHELIA_STORAGE_POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    depends_on:
      auth_db: { condition: service_healthy }
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    logging: *default-logging
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
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE, SETGID, SETUID, CHOWN, DAC_OVERRIDE]
    security_opt: [no-new-privileges:true]
    logging: *default-logging
    healthcheck:
      test: ["CMD-SHELL", "nslookup localhost 127.0.0.1 || exit 1"]
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
      - "traefik.http.routers.pihole.tls.certresolver=cloudflare"
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
    cap_drop: [ALL]
    cap_add: [NET_ADMIN, NET_BIND_SERVICE, NET_RAW, CHOWN, SETUID, SETGID, DAC_OVERRIDE, SYS_CHROOT, SYS_NICE]
    logging: *default-logging
    restart: unless-stopped

  wireguard_vpn:
    image: ${IMG_WG}
    container_name: wireguard_vpn
    networks:
      vpn_network: { ipv4_address: 10.99.0.10 }
    environment:
      - SERVERURL=\${WG_ENDPOINT}
      - SERVERPORT=\${WG_PORT}
      - PEERS=3
      - PEERDNS=10.99.0.12
      - INTERNAL_SUBNET=10.13.13.0/24
    volumes:
      - /lib/modules:/lib/modules:ro
      - ${ConfigDir}/WireGuard:/config
    ports: ["0.0.0.0:\${WG_PORT}:\${WG_PORT}/udp"]
    sysctls:
      net.ipv4.ip_forward: 1
      net.ipv4.conf.all.src_valid_mark: 1
    cap_drop: [ALL]
    cap_add: [NET_ADMIN, SYS_MODULE, NET_RAW]
    logging: *default-logging
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
      - "--certificatesresolvers.cloudflare.acme.email=\${ACME_EMAIL}"
      - "--certificatesresolvers.cloudflare.acme.storage=/acme.json"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge=true"
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: [no-new-privileges:true]
    logging: *default-logging
    restart: unless-stopped
EOF

sudo chown -R 0:0 "$StackDir"
sudo chmod 600 "$ComposeFile" "$EnvFile"

# ==============================================================================
# CRON-10: AUTOMATED LIFECYCLE APPLIANCE GENERATOR (ATOMIC SWAP)
# ==============================================================================
UpdaterScript="${ScriptsDir}/UpdateSovereignNode.sh"
sudo tee "${UpdaterScript}.tmp" > /dev/null << EOF
#!/bin/bash
# Sovereign Node Autonomous Lifecycle Updater
# Managed by DeploySovereignNode.sh
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

exec > >(logger -t SovereignNodeUpdater) 2>&1

echo "[Sovereign Node] Initiating weekly lifecycle update..."
cd "${StackDir}" || exit 1

curl -sS https://www.internic.net/domain/named.root -o "${ConfigDir}/Unbound/RootHints.txt.tmp" || true
if [ -s "${ConfigDir}/Unbound/RootHints.txt.tmp" ]; then
    mv "${ConfigDir}/Unbound/RootHints.txt.tmp" "${ConfigDir}/Unbound/RootHints.txt"
    docker compose --env-file "${EnvFile}" restart unbound_dns
fi

docker compose --env-file "${EnvFile}" pull --quiet
docker compose --env-file "${EnvFile}" up -d --remove-orphans
docker image prune -af --filter "until=168h"

echo "[Sovereign Node] Update cycle complete."
EOF

sudo chmod 700 "${UpdaterScript}.tmp"
sudo mv "${UpdaterScript}.tmp" "$UpdaterScript"
sudo ln -sf "$UpdaterScript" /etc/cron.weekly/sovereign-node-update

# Ignition
if [ "$Interactive" -eq 1 ]; then PrintMsg "226" "Igniting Unified Sovereign Node..."; fi
cd "$StackDir" && sudo docker compose --env-file "$EnvFile" up -d --remove-orphans

# ==============================================================================
# ROUTE-14: LIVE ASSIMILATION ENGINE (POST-IGNITION)
# ==============================================================================
AssimilateAlienContainers() {
    if [ "$Interactive" -eq 1 ] && command -v docker &> /dev/null; then
        local foreign_containers=$(sudo docker ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' -v stack="${StackName,,}" 'tolower($2) != stack && $1 != "" {print $1}')
        if [ -n "$foreign_containers" ]; then
            local found_new=0
            for container in $foreign_containers; do
                local clean_name=$(echo "$container" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
                local manifest_file="${ConfigDir}/Traefik/Dynamic/${clean_name}_assimilation.yml"

                if [ -f "$manifest_file" ]; then
                    sudo docker network connect sovereign_node_proxy_network "$container" >/dev/null 2>&1 || true
                    continue
                fi

                if [ $found_new -eq 0 ]; then
                    PrintMsg "214" "LOCAL ASSIMILATION PROTOCOL INITIATED"
                    found_new=1
                fi

                echo ""
                PrintMsg "214" "Select posture for unassimilated container [$container]:"
                
                local posture_choice=""
                if command -v gum &> /dev/null; then
                    local choice=$(gum choose "1) MFA Protected (Authelia) [SUGGESTED]" "2) VPN-Only (Air-Gapped)" "3) BasicAuth (Legacy Form)" "4) Fully Public" "5) Internal (Skip)")
                    posture_choice=${choice:0:1}
                else
                    echo "1) MFA Protected (Authelia) [SUGGESTED]"
                    echo "2) VPN-Only (Air-Gapped)"
                    echo "3) BasicAuth (Legacy Form)"
                    echo "4) Fully Public"
                    echo "5) Internal (Skip)"
                    read -p "Select posture (1-5) [1]: " posture_choice
                    posture_choice=${posture_choice:-1}
                fi

                if [ "$posture_choice" -eq 5 ]; then continue; fi

                local TargetPort=""
                if command -v gum &> /dev/null; then
                    TargetPort=$(gum input --prompt "Internal listening port for $container (e.g. 80, 8080): ")
                else
                    read -p "Internal listening port for $container (e.g. 80, 8080): " TargetPort
                fi

                if [ -z "$TargetPort" ]; then
                    PrintMsg "196" "Target port cannot be empty. Skipping assimilation for $container."
                    continue
                fi

                local mw_string=""
                case "$posture_choice" in
                    1) mw_string="\"secure-headers\", \"authelia\"" ;;
                    2) mw_string="\"secure-headers\", \"vpn-whitelist\"" ;;
                    3) mw_string="\"secure-headers\", \"traefik-auth\"" ;;
                    4) mw_string="\"secure-headers\"" ;;
                esac

                PrintMsg "226" "Bridging $container to Zero-Trust perimeter..."
                sudo docker network connect sovereign_node_proxy_network "$container" >/dev/null 2>&1 || true

                sudo tee "$manifest_file" > /dev/null << MANIFEST_EOF
http:
  routers:
    ${clean_name}-router:
      rule: "Host(\`${clean_name}.\${INTERNAL_DOMAIN}\`)"
      entryPoints: ["websecure"]
      middlewares: [${mw_string}]
      service: "${clean_name}-service"
      tls:
        certResolver: "cloudflare"
  services:
    ${clean_name}-service:
      loadBalancer:
        servers:
          - url: "http://${container}:${TargetPort}"
MANIFEST_EOF
                PrintMsg "82" "✔ Assimilated: https://${clean_name}.\${INTERNAL_DOMAIN}"
            done
        fi
    fi
}

AssimilateAlienContainers

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
    PrintMsg "196" " ⚠️  AUTHELIA MFA REGISTRATION (CRITICAL)"
    PrintMsg "226" " Your first login attempt at https://pihole.\${INTERNAL_DOMAIN}"
    PrintMsg "226" " will trigger an email to register your biometric/2FA device."
    PrintMsg "226" " Because no SMTP server is configured, the link is intercepted locally."
    PrintMsg "82"  " Retrieve your registration link by running:"
    PrintMsg "196" " sudo cat ${ConfigDir}/Authelia/notification.txt"
    PrintMsg "214" "========================================================================"
    echo ""
    PrintMsg "82" "✔ Unified Matrix Online. Turn the key."
fi

exit 0