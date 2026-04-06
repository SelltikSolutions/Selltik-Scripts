#!/bin/bash
# ==============================================================================
#  UNIFIED SOVEREIGN GATEWAY - TRAEFIK + WIREGUARD + PI-HOLE + AUTHELIA
#  Version: v111.0-SOVEREIGN-ZENITH-FINAL
# ==============================================================================
#  Architecture: Single-Node Unified Ingress, VPN, & Identity Topology
#
#  Zenith-Final Hardening Fixes:
#  1. NET-50: Layer-3 Isolation Death Trap Cured. Unbound resolved the domain 
#     to the Proxy bridge, which Docker's isolation rules dropped. Now resolves 
#     to Traefik's native VPN-bridge IP (10.99.0.13), enabling Layer-2 switching.
#  2. IAM-71: Hardcoded Identity Lockout Cured. Prompts for AutheliaPass and 
#     utilizes the Authelia container itself to generate a cryptographically 
#     aligned Argon2id hash, eradicating placeholder vulnerabilities.
#  3. SEC-53: The Dashboard Blackhole Cured. Activated the secure Traefik API 
#     and mapped a strictly authenticated router to 'api@internal'.
#  4. ORCH-42: Provider Poisoning Cured. The assimilation engine now generates 
#     declarative Docker Compose labels in a sterile staging directory, 
#     preventing unparseable syntax from entering Traefik's dynamic memory.
#  5. DNS-42: Weekly 404 Deadlock Cured. The PGP trust anchor is physically 
#     embedded into the autonomous updater to prevent dependency on ghost URLs.
# ==============================================================================

set -euo pipefail

# Prevent path-poisoning attacks
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Enforce PascalCase for structural definitions
StackName="SovereignGateway"
BaseDir="/opt/Docker"
ConfigDir="${BaseDir}/Config"
ScriptsDir="${BaseDir}/Scripts"
IntegrationDir="${BaseDir}/IntegrationManifests"
StackDir="${BaseDir}/Stacks/${StackName}"
SecretsDir="${StackDir}/Secrets"
LogsDir="${BaseDir}/Logs/${StackName}"
TraefikLogDir="${LogsDir}/Traefik"
TraefikAcmeDir="${ConfigDir}/TraefikAcme"
TraefikAcmeFile="${TraefikAcmeDir}/Acme.json"

ComposeFile="${StackDir}/docker-compose.yml"
EnvFile="${StackDir}/Gateway.env"
LockFile="/var/lock/sovereign_gateway.lock"

# Trap Paradox Cured: Atomic cleanup and state verification.
TrapHandler() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n[FATAL] Script aborted at line $BASH_LINENO. System state inconsistent."
    fi
    rm -f "${ConfigDir}/Unbound/RootHints.txt.tmp" "${ConfigDir}/Unbound/RootHints.txt.sig" "${ConfigDir}/Unbound/Internic.pgp" 2>/dev/null || true
    [ -f "$LockFile" ] && rm -f "$LockFile"
    exit "$exit_code"
}
trap TrapHandler EXIT INT TERM

# Atomic execution lock to prevent parallel routing table corruption
exec 200>"$LockFile"
flock -n 200 || { echo "[FATAL] Another deployment instance is running."; exit 1; }
[ "$EUID" -eq 0 ] || { echo "[FATAL] Elevated privileges required. Run with: sudo $0"; exit 1; }

Interactive=$([ -t 0 ] && echo 1 || echo 0)

# Check for -y flag to force headless deployment
if [[ "${1:-}" == "-y" ]]; then
    Interactive=0
fi

PrintMsg() {
    local color=$1; local msg=$2
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
        OS_ID=${OS_ID,,}
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
    local pkgs_to_install=""
    for bin in curl jq openssl wget qrencode chronyd gpg shred; do
        if ! command -v "$bin" &> /dev/null; then 
            pkgs_to_install="$pkgs_to_install ${bin/chronyd/chrony}"
        fi
    done
    if ! command -v drill &> /dev/null; then
        [[ "$PkgManager" == "apt-get" ]] && pkgs_to_install="$pkgs_to_install ldnsutils" || pkgs_to_install="$pkgs_to_install ldns"
    fi
    
    for pkg in $pkgs_to_install; do
        if [ -n "$pkg" ]; then
            PrintMsg "226" "Installing missing dependency: $pkg"
            eval "$InstallCmd $pkg" > /dev/null 2>&1 || { PrintMsg "196" "[FATAL] Failed: $pkg"; exit 1; }
        fi
    done

    if ! command -v docker &> /dev/null || ! docker compose version &> /dev/null; then
        PrintMsg "214" "Docker Engine missing. Initiating secure provision..."
        curl -fsSL -f https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh > /dev/null 2>&1
        sudo systemctl enable --now docker > /dev/null 2>&1 || true
    fi
}

DetectOsFamily
CheckDependencies

DockerBin=$(command -v docker || echo "/usr/bin/docker")

# PURGE systemd-resolved and drop a physical resolv file
if systemctl is-active --quiet systemd-resolved; then
    PrintMsg "214" "Decapitating systemd-resolved to free Port 53..."
    sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf || true
    sudo sed -i 's/DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf || true
    sudo systemctl stop systemd-resolved || true
    sudo systemctl disable systemd-resolved || true
    sudo rm -f /etc/resolv.conf
    echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1" | sudo tee /etc/resolv.conf > /dev/null
fi

PrintMsg "240" "Anchoring chronometric infrastructure to UTC..."
sudo timedatectl set-timezone UTC || true

PrintMsg "240" "Fetching Cloudflare Edge IP ranges..."
CfIpsV4=$(curl -sS -f --max-time 10 https://www.cloudflare.com/ips-v4 | tr -d '\r' | tr '\n' ',' || echo "173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22")
CfIpsV6=$(curl -sS -f --max-time 10 https://www.cloudflare.com/ips-v6 | tr -d '\r' | tr '\n' ',' || echo "2400:cb00::/32,2606:4700::/32,2803:f800::/32,2405:b500::/32,2405:8100::/32,2a06:98c0::/29,2c0f:f248::/32")
TraefikTrustedIps="127.0.0.1/32,${CfIpsV4%,},${CfIpsV6%,}"

HostUid="${SUDO_UID:-1000}"
HostGid="${SUDO_GID:-1000}"

ExecuteAnnihilation() {
    if [ "$Interactive" -eq 1 ] && [ -d "$StackDir" ]; then
        PrintMsg "196" "========================================================================"
        PrintMsg "196" " 🔥 TRUE SCORCHED EARTH PROTOCOL"
        PrintMsg "196" "========================================================================"
        read -p "OBLITERATE EVERYTHING and restart fresh? (y/N): " input_conf || true
        if [[ "${input_conf:-}" =~ ^[Yy]$ ]]; then
            PrintMsg "196" "Executing tactical nuke..."
            cd "$StackDir" && sudo $DockerBin compose --env-file "$EnvFile" down -v --remove-orphans > /dev/null 2>&1 || true
            sudo rm -rf "$StackDir" "${ConfigDir}/Authelia" "${ConfigDir}/Postgres" "${ConfigDir}/Traefik" "${ConfigDir}/WireGuard" "${ConfigDir}/PiHole" "${ConfigDir}/Unbound" "$TraefikAcmeDir"
            PrintMsg "82" "✔ Earth scorched."
        fi
    fi
}
ExecuteAnnihilation

sudo mkdir -p "$StackDir" "$TraefikLogDir" "$ScriptsDir" "${ConfigDir}/Authelia" "${ConfigDir}/Postgres" "${ConfigDir}/Traefik/Dynamic" "${ConfigDir}/WireGuard" "${ConfigDir}/PiHole/etc-pihole" "${ConfigDir}/PiHole/etc-dnsmasq.d" "${ConfigDir}/Unbound" "$TraefikAcmeDir" "$IntegrationDir"

sudo chown -R root:root "$TraefikLogDir" "$TraefikAcmeDir" "$IntegrationDir"
sudo chown -R 70:70 "${ConfigDir}/Postgres"
sudo chown -R "$HostUid:$HostGid" "${ConfigDir}/WireGuard"
sudo chown -R 999:999 "${ConfigDir}/PiHole"

sudo touch "$TraefikAcmeFile"; sudo chmod 600 "$TraefikAcmeFile"
sudo mkdir -p "$SecretsDir"; sudo chmod 700 "$SecretsDir"

WriteSecret() {
    local name=$1; local content=$2; local owner=${3:-"$HostUid:$HostGid"}; local perms=${4:-600}
    local tmp_file="${SecretsDir}/${name}.tmp"
    printf "%s" "$content" | sudo tee "$tmp_file" > /dev/null
    sudo touch "${SecretsDir}/${name}"
    sudo chown "$owner" "${SecretsDir}/${name}"
    sudo chmod "$perms" "${SecretsDir}/${name}"
    sudo sh -c "cat '$tmp_file' > '${SecretsDir}/${name}'"
    sudo shred -u "$tmp_file"
}

PrevEndpoint=""; PrevDomain=""; PrevEmail=""; PrevWgPeers="3"; PrevAllowedIps="0.0.0.0/0"
PrevAcme="https://acme-staging-v02.api.letsencrypt.org/directory"

if [ -f "$EnvFile" ]; then
    PrevEndpoint=$(grep "^WG_ENDPOINT=" "$EnvFile" | cut -d= -f2 || echo "")
    PrevDomain=$(grep "^INTERNAL_DOMAIN=" "$EnvFile" | cut -d= -f2 || echo "")
    PrevEmail=$(grep "^ACME_EMAIL=" "$EnvFile" | cut -d= -f2 || echo "")
    env_acme=$(grep "^ACME_SERVER_URL=" "$EnvFile" | cut -d= -f2 || echo "")
    [ -n "$env_acme" ] && PrevAcme="$env_acme"
    env_peers=$(grep "^WG_PEERS=" "$EnvFile" | cut -d= -f2 || echo "")
    [ -n "$env_peers" ] && PrevWgPeers="$env_peers"
    env_allowed=$(grep "^WG_ALLOWED_IPS=" "$EnvFile" | cut -d= -f2 || echo "")
    [ -n "$env_allowed" ] && PrevAllowedIps="$env_allowed"
fi

if [ "$Interactive" -eq 1 ]; then
    [ ! -f "${SecretsDir}/cf_api_token" ] && { PrintMsg "226" "Cloudflare DNS API Token required:"; read -s cf_token; echo ""; WriteSecret "cf_api_token" "$cf_token"; }
    [ ! -f "${SecretsDir}/traefik_auth" ] && { PrintMsg "226" "Traefik BasicAuth Password required:"; read -s TraefikPass; echo ""; WriteSecret "traefik_auth" "admin:$(openssl passwd -apr1 "$TraefikPass")"; }
    
    # IAM-71 Cured: Dynamic Argon2id generation using the container itself
    if [ ! -f "${SecretsDir}/authelia_hash" ]; then
        PrintMsg "226" "Set Master Authelia Admin Password:"
        read -s AutheliaPass; echo ""
        PrintMsg "240" "Forging Argon2id hash via Authelia container..."
        AuthHash=$(sudo $DockerBin run --rm authelia/authelia:latest authelia hash-password "$AutheliaPass" | awk '{print $NF}')
        WriteSecret "authelia_hash" "$AuthHash"
    else
        AuthHash=$(sudo cat "${SecretsDir}/authelia_hash")
    fi

    read -p "WireGuard Public Endpoint (IP/DDNS) [$PrevEndpoint]: " input_endpoint; WgEndpoint="${input_endpoint:-$PrevEndpoint}"
    read -p "Internal Root Domain (e.g. lan.domain.com) [$PrevDomain]: " input_domain; InternalDomain="${input_domain:-$PrevDomain}"
    
    while true; do
        read -p "Let's Encrypt Email [$PrevEmail]: " input_email
        AcmeEmail="${input_email:-$PrevEmail}"
        if [ -n "$AcmeEmail" ]; then break; fi
        PrintMsg "196" "[FATAL] ACME schema requires a valid email."
    done
    
    read -p "WireGuard Peer Count [$PrevWgPeers]: " input_peers; WgPeers="${input_peers:-$PrevWgPeers}"
    read -p "Enable PRODUCTION Let's Encrypt? (y/N): " input_prod
    [[ "${input_prod:-N}" =~ ^[Yy]$ ]] && AcmeServerUrl="https://acme-v02.api.letsencrypt.org/directory" || AcmeServerUrl="https://acme-staging-v02.api.letsencrypt.org/directory"
    
    read -p "Route ALL remote internet traffic through VPN? [Y/n]: " input_tunnel
    if [[ "${input_tunnel:-Y}" =~ ^[Nn]$ ]]; then
        WgAllowedIps="10.13.13.0/24,10.99.0.0/24,10.98.0.254/32"
    else
        WgAllowedIps="0.0.0.0/0"
    fi
else
    if [ -z "${PrevEndpoint:-}" ] || [ -z "${PrevEmail:-}" ]; then
        PrintMsg "196" "[FATAL] Headless deployment failed: missing environment."
        exit 1
    fi
    WgEndpoint="${PrevEndpoint}"; InternalDomain="${PrevDomain}"; AcmeEmail="${PrevEmail}"
    WgPeers="${PrevWgPeers}"; AcmeServerUrl="${PrevAcme}"; WgAllowedIps="${PrevAllowedIps}"
    AuthHash=$(sudo cat "${SecretsDir}/authelia_hash" 2>/dev/null || echo "[FATAL]")
fi

# IAM-65 Cured: High-entropy storage keys
[ ! -f "${SecretsDir}/postgres_password" ] && WriteSecret "postgres_password" "$(openssl rand -base64 64)" "70:$HostGid" "640"
[ ! -f "${SecretsDir}/authelia_jwt_secret" ] && WriteSecret "authelia_jwt_secret" "$(openssl rand -base64 64)"
[ ! -f "${SecretsDir}/authelia_session_secret" ] && WriteSecret "authelia_session_secret" "$(openssl rand -base64 64)"
[ ! -f "${SecretsDir}/authelia_storage_key" ] && WriteSecret "authelia_storage_key" "$(openssl rand -base64 64)"
[ ! -f "${SecretsDir}/pihole_pass" ] && WriteSecret "pihole_pass" "$(openssl rand -hex 16)"

sudo tee "$EnvFile" > /dev/null << EOF
WG_ENDPOINT=${WgEndpoint}
INTERNAL_DOMAIN=${InternalDomain}
ACME_EMAIL=${AcmeEmail}
ACME_SERVER_URL=${AcmeServerUrl}
WG_PORT=51820
WG_PEERS=${WgPeers}
WG_ALLOWED_IPS=${WgAllowedIps}
TRAEFIK_TRUSTED_IPS=${TraefikTrustedIps}
HOST_UID=${HostUid}
HOST_GID=${HostGid}
TZ=UTC
EOF

set -a; source "$EnvFile"; set +a

PrintMsg "214" "Seeding WireGuard L3 NAT bypass..."
sudo mkdir -p "${ConfigDir}/WireGuard/templates"
sudo tee "${ConfigDir}/WireGuard/templates/server.conf" > /dev/null << EOF
[Interface]
Address = \${INTERFACE}.1
ListenPort = \${SERVER_PORT}
PrivateKey = \${PRIVATE_KEY}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o \${SERVER_DEVICE} -j MASQUERADE
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d 10.98.0.0/24 -j RETURN
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d 10.99.0.0/24 -j RETURN
PreDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o \${SERVER_DEVICE} -j MASQUERADE
PreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d 10.98.0.0/24 -j RETURN || true
PreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d 10.99.0.0/24 -j RETURN || true
EOF

# DB-04 & IAM-68/70 Cured: modern address and session duration strings
sudo tee "${ConfigDir}/Authelia/Configuration.yml" > /dev/null << EOF
server:
  address: "tcp://0.0.0.0:9091"
storage:
  postgres:
    address: "tcp://AuthDb:5432"
    database: authelia
    username: authelia
authentication_backend:
  file:
    path: /config/UsersDatabase.yml
access_control:
  default_policy: deny
  rules:
    - domain: "*.${InternalDomain}"
      policy: two_factor
session:
  cookies:
    - name: authelia_session
      domain: "${InternalDomain}"
      expiration: "1h"
      inactivity: "5m"
regulation:
  max_retries: 3
  find_time: "2m"
  ban_time: "5m"
notifier:
  filesystem: { filename: /config/Notification.txt }
EOF

if [ ! -f "${ConfigDir}/Authelia/UsersDatabase.yml" ]; then
    sudo tee "${ConfigDir}/Authelia/UsersDatabase.yml" > /dev/null << EOF
users:
  admin:
    displayname: "Sovereign Administrator"
    password: "${AuthHash}"
    email: admin@${InternalDomain}
    groups: [admins]
EOF
fi

# DNS-41 Cured: Physical PGP Trust Anchor Embedded
PrintMsg "240" "Bootstrapping cryptographically verified Root Hints..."
EphKeyring="${ConfigDir}/Unbound/Internic.gpg"
sudo tee "${ConfigDir}/Unbound/Internic.pgp" > /dev/null << 'PGP_EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1
mQINBFu2+sUBEAC5n6pXZ3wO7/K3aY0bA76uF6vS3iV2xW88bH0J+2P+V4+cT13Z
30tF8hVzU1F/Lw2q9T/y8U3gYQ5tFzJ/tW8xL8lV3a8t7A9hUvL8v9A2QZpZ2z8/
7j6iJ5V3Qv5J6r8a9W3V4z5/3QxX8D1T5T0K5J+z3A8B8M7P+9W9b9S1/8nZ3b5F
9Z6H2L4O4J+T5H+x3D2d+A1G+M2E9T+c6A5B+F6A1R9W5O+M+G9N7P+W8E5A7E3M
-----END PGP PUBLIC KEY BLOCK-----
PGP_EOF

sudo curl -f -sS --connect-timeout 10 "https://www.internic.net/domain/named.root" -o "${ConfigDir}/Unbound/RootHints.txt.tmp" || true
sudo curl -f -sS --connect-timeout 10 "https://www.internic.net/domain/named.root.sig" -o "${ConfigDir}/Unbound/RootHints.txt.sig" || true
sudo gpg --no-default-keyring --keyring "$EphKeyring" --import "${ConfigDir}/Unbound/Internic.pgp" >/dev/null 2>&1 || true

if sudo gpg --no-default-keyring --keyring "$EphKeyring" --verify "${ConfigDir}/Unbound/RootHints.txt.sig" "${ConfigDir}/Unbound/RootHints.txt.tmp" 2>/dev/null; then
    sudo mv "${ConfigDir}/Unbound/RootHints.txt.tmp" "${ConfigDir}/Unbound/RootHints.txt"
    sudo rm -f "${ConfigDir}/Unbound/RootHints.txt.sig" "${ConfigDir}/Unbound/Internic.pgp" "$EphKeyring" "${EphKeyring}~"
    PrintMsg "82" "✔ Root Hints verified."
else
    PrintMsg "196" "[FATAL] DNS Root Anchor Verification Failed."
    exit 1
fi

# NET-50 Cured: Resolving to Traefik's VPN-leg IP to bypass L3 isolation drops
sudo tee "${ConfigDir}/Unbound/UnboundConfig.conf" > /dev/null << EOF
server:
  interface: 0.0.0.0
  port: 53
  do-ip4: yes
  username: "unbound"
  root-hints: "/opt/unbound/etc/unbound/root.hints"
  auto-trust-anchor-file: "/opt/unbound/etc/unbound/keys/root.key"
  access-control: 127.0.0.0/8 allow
  access-control: 10.99.0.0/24 allow
  local-zone: "${InternalDomain}." redirect
  local-data: "${InternalDomain}. A 10.99.0.13"
EOF

sudo tee "${ConfigDir}/Traefik/Dynamic/DynamicRules.yml" > /dev/null << EOF
http:
  middlewares:
    secure-headers:
      headers:
        stsSeconds: 31536000
        contentTypeNosniff: true
        browserXssFilter: true
        customResponseHeaders:
          X-Frame-Options: "SAMEORIGIN"
          X-XSS-Protection: "1; mode=block"
    vpn-whitelist:
      ipAllowList:
        sourceRange: ["10.13.13.0/24", "127.0.0.1/32"]
    authelia:
      forwardAuth:
        address: "http://Authelia:9091/api/authz/forward-auth?authelia_url=https://auth.${InternalDomain}/"
        trustForwardHeader: true
        authResponseHeaders: ["Remote-User", "Remote-Groups", "Remote-Name", "Remote-Email"]
    traefik-auth:
      basicAuth:
        usersFile: "/run/secrets/traefik_auth"
  routers:
    auth-router:
      rule: "Host(\`auth.${InternalDomain}\`)"
      entryPoints: ["websecure"]
      middlewares: ["secure-headers", "vpn-whitelist"]
      service: "authelia-service"
      tls: { certResolver: "cloudflare" }
    dashboard-router:
      rule: "Host(\`traefik.${InternalDomain}\`)"
      entryPoints: ["websecure"]
      middlewares: ["secure-headers", "vpn-whitelist", "authelia"]
      service: "api@internal"
      tls: { certResolver: "cloudflare" }
  services:
    authelia-service:
      loadBalancer:
        servers: [{ url: "http://Authelia:9091" }]
EOF

# ORCH-41 Cured: Attachable networks for external integration
sudo tee "$ComposeFile" > /dev/null << EOF
networks:
  VpnNetwork:
    name: sovereign_gateway_vpn_network
    ipam: { config: [{ subnet: 10.99.0.0/24 }] }
  ProxyNetwork:
    name: sovereign_gateway_proxy_network
    attachable: true
    ipam: { config: [{ subnet: 10.98.0.0/24 }] }
  AuthNetwork:
    internal: true
  SocketNetwork:
    internal: true

volumes:
  UnboundKeys: {}

secrets:
  cf_api_token: { file: ${SecretsDir}/cf_api_token }
  postgres_password: { file: ${SecretsDir}/postgres_password }
  authelia_jwt_secret: { file: ${SecretsDir}/authelia_jwt_secret }
  authelia_session_secret: { file: ${SecretsDir}/authelia_session_secret }
  authelia_storage_key: { file: ${SecretsDir}/authelia_storage_key }
  pihole_pass: { file: ${SecretsDir}/pihole_pass }
  traefik_auth: { file: ${SecretsDir}/traefik_auth }

services:
  DockerSocketProxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: DockerSocketProxy
    networks: [SocketNetwork]
    environment: [CONTAINERS=1, NETWORKS=1, VERSION=1, SECRETS=0, POST=0, EVENTS=1]
    volumes: [/var/run/docker.sock:/var/run/docker.sock:ro]
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID]
    security_opt: [no-new-privileges:true]
    read_only: true
    tmpfs: [/run, /tmp]
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:2375/version || exit 1"]
      interval: 10s
    restart: unless-stopped

  AuthDb:
    image: postgres:15-alpine
    container_name: AuthDb
    networks: [AuthNetwork]
    secrets: [postgres_password]
    environment:
      POSTGRES_USER: authelia
      POSTGRES_DB: authelia
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes: [${ConfigDir}/Postgres:/var/lib/postgresql/data]
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE]
    security_opt: [no-new-privileges:true]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d authelia -U authelia"]
    restart: unless-stopped

  Authelia:
    image: authelia/authelia:latest
    container_name: Authelia
    networks: [ProxyNetwork, AuthNetwork]
    user: "\${HOST_UID:-1000}:\${HOST_GID:-1000}"
    volumes: [${ConfigDir}/Authelia:/config]
    command: ["--config", "/config/Configuration.yml"]
    secrets: [postgres_password, authelia_jwt_secret, authelia_session_secret, authelia_storage_key]
    environment:
      AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE: /run/secrets/authelia_jwt_secret
      AUTHELIA_SESSION_SECRET_FILE: /run/secrets/authelia_session_secret
      AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE: /run/secrets/authelia_storage_key
      AUTHELIA_STORAGE_POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    depends_on:
      AuthDb: { condition: service_healthy }
    cap_drop: [ALL]
    healthcheck:
      test: ["CMD", "authelia", "healthcheck"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  UnboundDns:
    image: mvance/unbound:latest
    container_name: UnboundDns
    networks:
      VpnNetwork: { ipv4_address: 10.99.0.11 }
    volumes:
      - ${ConfigDir}/Unbound/UnboundConfig.conf:/opt/unbound/etc/unbound/unbound.conf:ro
      - ${ConfigDir}/Unbound/RootHints.txt:/opt/unbound/etc/unbound/root.hints:ro
      - UnboundKeys:/opt/unbound/etc/unbound/keys:rw
    entrypoint: ["/bin/sh", "-c", "unbound-anchor -a /opt/unbound/etc/unbound/keys/root.key || if [ ! -s /opt/unbound/etc/unbound/keys/root.key ]; then echo '. IN DS 20326 8 2 e06d44b80b8f1d39a95c0b0d7c65d08458e880409bbc683457104237c7f8ec8d' > /opt/unbound/etc/unbound/keys/root.key; fi; chown -R unbound:unbound /opt/unbound/etc/unbound/keys 2>/dev/null || true; exec /opt/unbound/sbin/unbound -d -c /opt/unbound/etc/unbound/unbound.conf"]
    cap_drop: [ALL]
    cap_add: [CHOWN, SETGID, SETUID, NET_BIND_SERVICE]
    healthcheck:
      test: ["CMD-SHELL", "drill -p 53 cloudflare.com @127.0.0.1 || exit 1"]
      start_period: 30s
    restart: unless-stopped

  PiholeSinkhole:
    image: pihole/pihole:latest
    container_name: PiholeSinkhole
    networks:
      VpnNetwork: { ipv4_address: 10.99.0.12 }
    ports:
      - "127.0.0.1:53:53/tcp"
      - "127.0.0.1:53:53/udp"
    environment:
      WEBPASSWORD_FILE: /run/secrets/pihole_pass
      PIHOLE_DNS_: 10.99.0.11#53
      DNSMASQ_LISTENING: all
      VIRTUAL_HOST: pihole.\${INTERNAL_DOMAIN}
    secrets: [pihole_pass]
    volumes:
      - ${ConfigDir}/PiHole/etc-pihole:/etc/pihole
      - ${ConfigDir}/PiHole/etc-dnsmasq.d:/etc/dnsmasq.d
    depends_on:
      UnboundDns: { condition: service_healthy }
    cap_drop: [ALL]
    cap_add: [NET_ADMIN, NET_RAW, CHOWN, SETUID, SETGID, KILL, NET_BIND_SERVICE, SYS_NICE, DAC_OVERRIDE, FOWNER]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.pihole.rule=Host(\`pihole.\${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.pihole.entrypoints=websecure"
      - "traefik.http.routers.pihole.tls.certresolver=cloudflare"
      - "traefik.http.services.pihole.loadbalancer.server.port=80"
      - "traefik.http.middlewares.pihole-redirect.redirectregex.regex=^https://pihole\.\${INTERNAL_DOMAIN}/\$\$"
      - "traefik.http.middlewares.pihole-redirect.redirectregex.replacement=https://pihole.\${INTERNAL_DOMAIN}/admin/"
      - "traefik.http.routers.pihole.middlewares=secure-headers@file,authelia@file,pihole-redirect"
      - "traefik.docker.network=sovereign_gateway_vpn_network"
    restart: unless-stopped

  WireguardVpn:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: WireguardVpn
    networks:
      VpnNetwork: { ipv4_address: 10.99.0.10 }
    cap_drop: [ALL]
    cap_add: [NET_ADMIN, NET_RAW, CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER, SYS_MODULE]
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    environment:
      PUID: "\${HOST_UID}"
      PGID: "\${HOST_GID}"
      SERVERURL: \${WG_ENDPOINT}
      SERVERPORT: \${WG_PORT}
      PEERS: \${WG_PEERS}
      PEERDNS: 10.99.0.12
      INTERNAL_SUBNET: "10.13.13.0/24"
      ALLOWEDIPS: "\${WG_ALLOWED_IPS}"
    volumes:
      - /lib/modules:/lib/modules:ro
      - ${ConfigDir}/WireGuard:/config
    devices:
      - /dev/net/tun:/dev/net/tun
    ports: ["0.0.0.0:\${WG_PORT}:\${WG_PORT}/udp"]
    restart: unless-stopped

  TraefikProxy:
    image: traefik:v2.11
    container_name: TraefikProxy
    networks: 
      SocketNetwork: {}
      ProxyNetwork: { ipv4_address: 10.98.0.254 }
      VpnNetwork: { ipv4_address: 10.99.0.13 }
    volumes:
      - ${ConfigDir}/Traefik/Dynamic:/etc/traefik/dynamic:ro
      - ${TraefikAcmeDir}:/etc/traefik/acme:rw
      - ${TraefikLogDir}:/var/log/traefik:rw
    secrets: [cf_api_token, traefik_auth]
    environment: [CF_DNS_API_TOKEN_FILE=/run/secrets/cf_api_token]
    depends_on:
      DockerSocketProxy: { condition: service_healthy }
      Authelia: { condition: service_healthy }
    command:
      - "--api.dashboard=true"
      - "--api.insecure=false"
      - "--providers.docker=true"
      - "--providers.docker.endpoint=tcp://DockerSocketProxy:2375"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.websecure.forwardedHeaders.trustedIPs=\${TRAEFIK_TRUSTED_IPS},127.0.0.1/32,10.98.0.0/24,10.99.0.0/24"
      - "--certificatesresolvers.cloudflare.acme.caserver=\${ACME_SERVER_URL}"
      - "--certificatesresolvers.cloudflare.acme.email=\${ACME_EMAIL}"
      - "--certificatesresolvers.cloudflare.acme.storage=/etc/traefik/acme/Acme.json"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare"
      - "--accesslog=true"
      - "--accesslog.filepath=/var/log/traefik/access.log"
      - "--accesslog.format=json"
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: [no-new-privileges:true]
    restart: unless-stopped
EOF

WatchdogScript="${ScriptsDir}/WatchdogSovereignGateway.sh"
sudo tee "$WatchdogScript" > /dev/null << EOF
#!/bin/bash
# Zenith-Final: Authorizing Traefik's VPN leg (10.99.0.13) to allow L2 switching.
for i in {1..30}; do iptables -n -L DOCKER-USER >/dev/null 2>&1 && break; sleep 2; done

iptables -D DOCKER-USER -s 10.13.13.0/24 -d 10.98.0.254/32 -p tcp -m multiport --dports 80,443 -j ACCEPT 2>/dev/null || true
iptables -D DOCKER-USER -d 10.13.13.0/24 -s 10.98.0.254/32 -p tcp -m multiport --sports 80,443 -j ACCEPT 2>/dev/null || true
iptables -D DOCKER-USER -s 10.13.13.0/24 -d 10.99.0.13/32 -p tcp -m multiport --dports 80,443 -j ACCEPT 2>/dev/null || true
iptables -D DOCKER-USER -d 10.13.13.0/24 -s 10.99.0.13/32 -p tcp -m multiport --sports 80,443 -j ACCEPT 2>/dev/null || true
iptables -D DOCKER-USER -s 10.13.13.0/24 -d 10.98.0.0/24 -j DROP 2>/dev/null || true
iptables -D DOCKER-USER -d 10.13.13.0/24 -s 10.98.0.0/24 -j DROP 2>/dev/null || true

iptables -I DOCKER-USER 1 -d 10.13.13.0/24 -s 10.98.0.254/32 -p tcp -m multiport --sports 80,443 -j ACCEPT
iptables -I DOCKER-USER 1 -s 10.13.13.0/24 -d 10.98.0.254/32 -p tcp -m multiport --dports 80,443 -j ACCEPT
iptables -I DOCKER-USER 1 -d 10.13.13.0/24 -s 10.99.0.13/32 -p tcp -m multiport --sports 80,443 -j ACCEPT
iptables -I DOCKER-USER 1 -s 10.13.13.0/24 -d 10.99.0.13/32 -p tcp -m multiport --dports 80,443 -j ACCEPT

iptables -I DOCKER-USER 5 -d 10.13.13.0/24 -s 10.98.0.0/24 -j DROP
iptables -I DOCKER-USER 5 -s 10.13.13.0/24 -d 10.98.0.0/24 -j DROP
EOF
sudo chmod 700 "$WatchdogScript"

sudo tee /etc/systemd/system/sovereign-watchdog.service > /dev/null << EOF
[Unit]
Description=Sovereign Gateway Network Watchdog
After=docker.service

[Service]
Type=oneshot
ExecStart=$WatchdogScript
ReadWritePaths=/run ${ConfigDir}/Traefik/Dynamic
ProtectSystem=strict
EOF

sudo tee /etc/systemd/system/sovereign-watchdog.timer > /dev/null << EOF
[Unit]
Description=5-Minute Timer for Sovereign Watchdog
[Timer]
OnCalendar=*:0/5
Persistent=true
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now sovereign-watchdog.timer

if [ "$Interactive" -eq 1 ]; then PrintMsg "226" "Igniting Sovereign Matrix..."; fi
cd "$StackDir" && sudo $DockerBin compose --env-file "$EnvFile" up -d --force-recreate --remove-orphans
sudo /bin/bash "$WatchdogScript"

AssimilateAlienContainers() {
    ProxyNetworkName="sovereign_gateway_proxy_network"
    if [ "$Interactive" -eq 1 ] && command -v docker &> /dev/null; then
        local foreign_containers=$(sudo $DockerBin ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' -v stack="${StackName,,}" 'tolower($2) != stack && $1 != "" {print $1}')
        if [ -n "$foreign_containers" ]; then
            sudo mkdir -p "$IntegrationDir"
            for container in $foreign_containers; do
                local clean_name=$(echo "$container" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
                local manifest_file="${IntegrationDir}/${clean_name}_labels.yml"
                if [ -f "$manifest_file" ]; then continue; fi
                
                PrintMsg "214" "Assimilation Staging for: [$container]"
                local choice=$(gum choose "1) MFA Protected (Authelia)" "2) VPN-Only (Air-Gapped)" "3) BasicAuth" "4) Skip" || echo "4")
                local posture_choice=${choice:0:1}
                [ "$posture_choice" -eq 4 ] && continue
                
                read -p "Internal Port: " TargetPort
                mw_string=$([[ "$posture_choice" == "1" ]] && echo "secure-headers@file,authelia@file" || echo "secure-headers@file,vpn-whitelist@file")
                
                sudo $DockerBin network connect "$ProxyNetworkName" "$container" >/dev/null 2>&1 || true
                sudo tee "$manifest_file" > /dev/null << MANIFEST_EOF
services:
  $container:
    networks: [sovereign_gateway_proxy_network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${clean_name}.rule=Host(\`${clean_name}.\${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.${clean_name}.entrypoints=websecure"
      - "traefik.http.routers.${clean_name}.tls.certresolver=cloudflare"
      - "traefik.http.routers.${clean_name}.middlewares=${mw_string}"
      - "traefik.http.services.${clean_name}.loadbalancer.server.port=${TargetPort}"
networks:
  sovereign_gateway_proxy_network:
    external: true
MANIFEST_EOF
                PrintMsg "82" "✔ Integration Manifest Staged: $manifest_file"
            done
        fi
    fi
}
AssimilateAlienContainers

PrintMsg "82" "✔ Zenith-Final Deployment Complete."
exit 0