#!/bin/bash
# ==============================================================================
#  UNIFIED SOVEREIGN GATEWAY - TRAEFIK + WIREGUARD + PI-HOLE + AUTHELIA
#  Version: v28.0-SOVEREIGN-OBSIDIAN
# ==============================================================================
#  Architecture: Single-Node Unified Ingress, VPN, & Identity Topology
#  Obsidian Hardening Fixes (The Eternal Seal):
#  1. PROXY-03: Phantom Middleware Cured. Explicitly defined 'traefik-auth' in 
#     DynamicRules.yml and mapped the top-level secret into the Traefik container.
#  2. SEC-24: Naked Edge Router Armored. Traefik and Pi-Hole restricted with 
#     cap_drop: [ALL] and tight security_opt directives to seal kernel escapes.
#  3. IAM-05: Deprecated Hash Modernized. Replaced the legacy SHA-512 default 
#     admin hash with a mathematically valid Argon2id block to defeat ASICs.
#  4. LOG-05: Ghost Sweeper Purged. Amputated the host-level logrotate cron 
#     block, deferring entirely to Docker's native json-file engine.
#  Inherited Monolith/Singularity/Epilogue/Terminus Master Fixes:
#  - IAM-03 (644 Secrets), NET-06 (Edge Segmentation), IAM-04 (Session Cookies)
#  - UX-03 (Unicode Phantom), S6-02 (Init Overrides), IAM-02 (Root Vault)
#  - SYNTAX-03 (YAML Sed), S6-01 (SetUID), PROXY-02 (Tmpfs), DNS-15 (Unbound Caps)
#  - SEC-22 (Proxy Armor), SEC-23 (SHA-512 Auth), DNS-14 (Ephemeral Keyring)
#  - DEP-01 (Cron Purge), DNS-12 (MITM), SEC-21 (Unbound Drop), HEALTH-13 (Boot).
# ==============================================================================

set -euo pipefail

# Ghost Directory Escape (Prevent execution in volatile paths)
cd /tmp || true
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

StackName="sovereign_gateway"
BaseDir="/opt/Docker"
ConfigDir="${BaseDir}/Config"
ScriptsDir="${BaseDir}/Scripts"
StackDir="${BaseDir}/Stacks/${StackName}"
SecretsDir="${StackDir}/Secrets"
LogsDir="/opt/Docker/Logs/${StackName}"

# Native Engine Discovery
ComposeFile="${StackDir}/docker-compose.yml"
EnvFile="${StackDir}/.env"
LockFile="/var/lock/sovereign_gateway.lock"

# Atomic execution lock
exec 200>"$LockFile"
flock -n 200 || { echo "[FATAL] Another deployment instance is running."; exit 1; }
[ "$EUID" -eq 0 ] || { echo "[FATAL] Elevated privileges required. Run with: sudo $0"; exit 1; }

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
            if [[ "$bin" == "chronyd" ]]; then pkgs_to_install="$pkgs_to_install chrony";
            elif [[ "$bin" == "gpg" ]]; then pkgs_to_install="$pkgs_to_install gnupg";
            elif [[ "$bin" == "shred" ]]; then pkgs_to_install="$pkgs_to_install coreutils";
            else pkgs_to_install="$pkgs_to_install $bin"; fi
        fi
    done
    if ! command -v drill &> /dev/null; then
        if [[ "$PkgManager" == "apt-get" ]]; then pkgs_to_install="$pkgs_to_install ldnsutils"; else pkgs_to_install="$pkgs_to_install ldns"; fi
    fi
    if [ ! -d "/usr/share/zoneinfo" ]; then pkgs_to_install="$pkgs_to_install tzdata"; fi
    if ! command -v dig &> /dev/null; then pkgs_to_install="$pkgs_to_install dnsutils"; fi
    for pkg in $pkgs_to_install; do
        if [ -n "$pkg" ]; then
            PrintMsg "226" "Installing missing dependency: $pkg"
            eval "$InstallCmd $pkg" > /dev/null 2>&1 || { PrintMsg "196" "[FATAL] Failed: $pkg"; exit 1; }
        fi
    done
    if ! command -v docker &> /dev/null || ! docker compose version &> /dev/null; then
        PrintMsg "214" "Docker Engine missing. Initiating provision..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh > /dev/null 2>&1
        sudo systemctl enable --now docker > /dev/null 2>&1 || true
    fi

    # DEP-01: Amputate legacy cron dependency to minimize attack surface
    if systemctl is-active --quiet cron; then sudo systemctl disable --now cron >/dev/null 2>&1 || true; fi
    sudo apt-get purge -y cron >/dev/null 2>&1 || true
}

DetectOsFamily
CheckDependencies

# Dynamically map absolute path for Docker to survive Systemd sanitization
DockerBin=$(command -v docker || echo "/usr/bin/docker")

# NET-04: Global Docker Daemon DNS Override
PrintMsg "240" "Enforcing internal container DNS resolution..."
sudo mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
    echo '{"dns": ["10.99.0.12", "1.1.1.1"]}' | sudo tee /etc/docker/daemon.json > /dev/null
    sudo systemctl restart docker || true
else
    if command -v jq &> /dev/null && ! grep -q "10.99.0.12" /etc/docker/daemon.json; then
        jq '.dns = ["10.99.0.12", "1.1.1.1"]' /etc/docker/daemon.json > /tmp/daemon.json && sudo mv /tmp/daemon.json /etc/docker/daemon.json
        sudo systemctl restart docker || true
    fi
fi

HuntPhysicalNetwork() {
    if ! command -v nmcli &> /dev/null; then return; fi
    local ActivePhysConn=$(nmcli -t -f NAME,TYPE,STATE connection show --active | grep -E ':(802-3-ethernet|802-11-wireless):activated' | head -n 1 | cut -d: -f1 || true)
    if [ -n "$ActivePhysConn" ]; then
        local PhysDev=$(nmcli -t -f DEVICE,NAME connection show --active | grep ":$ActivePhysConn$" | cut -d: -f1)
        local PhysIp=$(ip -4 addr show "$PhysDev" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
        local CidrPrefix=$(ip -4 addr show "$PhysDev" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | cut -d/ -f2 || true)
        local GatewayIp=$(ip route show dev "$PhysDev" | awk '/default/ {print $3}' | head -n 1 || true)
        if [ -n "$PhysIp" ]; then
            export HUNTER_IP="$PhysIp"
            local CurrentMethod=$(nmcli -t -f ipv4.method connection show "$ActivePhysConn" | cut -d: -f2 || true)
            if [ "$Interactive" -eq 1 ] && [ "$CurrentMethod" == "auto" ]; then
                echo ""
                PrintMsg "214" "🕵️ PHYSICAL LAN HUNTER ENGAGED"
                PrintMsg "226" "Detected physical interface [$PhysDev]. Fixed lease: $PhysIp"
                read -p "Freeze $PhysIp as a permanent Static IP? (Y/n): " input_static || true
                if [[ ! "${input_static:-Y}" =~ ^[Nn]$ ]]; then
                    sudo nmcli connection modify "$ActivePhysConn" ipv4.addresses "$PhysIp/$CidrPrefix" ipv4.gateway "$GatewayIp" ipv4.dns "1.1.1.1 1.0.0.1" ipv4.method manual
                    sudo nmcli connection up "$ActivePhysConn" > /dev/null 2>&1 || true
                    PrintMsg "82" "✔ Static IP Locked."
                fi
            fi
        fi
    fi
}
HuntPhysicalNetwork

if systemctl is-active --quiet systemd-resolved; then
    PrintMsg "214" "Decapitating systemd-resolved to free Port 53..."
    sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf || true
    sudo sed -i 's/DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf || true
    sudo systemctl restart systemd-resolved || true
    sudo chattr -i /etc/resolv.conf 2>/dev/null || true
    sudo rm -f /etc/resolv.conf
    echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1" | sudo tee /etc/resolv.conf > /dev/null
    sudo chattr +i /etc/resolv.conf || true
fi

# KRN-01 & NET-05: Kernel Armor and IPv6 Shadow-Routing Elimination
PrintMsg "240" "Forging STIG-compliant host kernel armor..."
sudo tee /etc/sysctl.d/99-SovereignNode.conf > /dev/null << 'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
net.core.bpf_jit_harden = 2
EOF
sudo sysctl --system > /dev/null 2>&1 || true

# TIME-02: Temporal Gate
PrintMsg "240" "Locking chronometric baseline..."
sudo timedatectl set-local-rtc 0 || true
if systemctl is-active --quiet chrony || systemctl is-active --quiet chronyd; then
    PrintMsg "226" "Waiting for NTP synchronization (Required for GPG)..."
    timeout 60 bash -c 'until chronyc tracking | grep -q "Leap status     : Normal"; do sleep 2; done' || PrintMsg "196" "WARNING: NTP sync timed out."
fi

# Capture Host UID for Container Privilege Dropping
HostUid="${SUDO_UID:-1000}"
HostGid="${SUDO_GID:-1000}"

PrevEndpoint=""; PrevDomain=""; PrevEmail=""; PrevPort="51820"; PrevLanIp="${HUNTER_IP:-}"; PrevAcme="https://acme-staging-v02.api.letsencrypt.org/directory"
if [ -f "$EnvFile" ]; then
    PrevEndpoint=$(grep "^WG_ENDPOINT=" "$EnvFile" | cut -d= -f2 || echo "")
    PrevDomain=$(grep "^INTERNAL_DOMAIN=" "$EnvFile" | cut -d= -f2 || echo "")
    PrevEmail=$(grep "^ACME_EMAIL=" "$EnvFile" | cut -d= -f2 || echo "")
    PrevPort=$(grep "^WG_PORT=" "$EnvFile" | cut -d= -f2 || echo "51820")
    env_lan=$(grep "^TRAEFIK_LAN_IP=" "$EnvFile" | cut -d= -f2 || echo "")
    [ -n "$env_lan" ] && PrevLanIp="$env_lan"
    env_acme=$(grep "^ACME_SERVER_URL=" "$EnvFile" | cut -d= -f2 || echo "")
    [ -n "$env_acme" ] && PrevAcme="$env_acme"
fi

# SEC-20: TOCTOU Teardown Sealed
ExecuteAnnihilation() {
    if [ "$Interactive" -eq 1 ] && [ -d "$StackDir" ]; then
        PrintMsg "196" "========================================================================"
        PrintMsg "196" " 🔥 TRUE SCORCHED EARTH PROTOCOL"
        PrintMsg "196" "========================================================================"
        read -p "OBLITERATE EVERYTHING and restart fresh? (y/N): " input_conf || true
        if [[ "${input_conf:-}" =~ ^[Yy]$ ]]; then
            PrintMsg "196" "Executing tactical nuke..."
            cd "$StackDir" && sudo $DockerBin compose down -v --remove-orphans > /dev/null 2>&1 || true
            PrintMsg "214" "Mathematically shredding cryptographic master keys..."
            [ -d "${SecretsDir}" ] && sudo find "${SecretsDir}" -type f -exec shred -u {} \; || true
            sudo rm -rf "$StackDir" "${ConfigDir}/Authelia" "${ConfigDir}/Postgres" "${ConfigDir}/Traefik" "${ConfigDir}/WireGuard" "${ConfigDir}/PiHole" "${ConfigDir}/Unbound"
            PrintMsg "82" "✔ Earth scorched. Magnetic persistence neutralized."
        fi
    fi
}
ExecuteAnnihilation

sudo mkdir -p "$StackDir" "$LogsDir" "$ScriptsDir" "$ConfigDir/Authelia" "$ConfigDir/Postgres" "$ConfigDir/Traefik/Dynamic" "$ConfigDir/WireGuard" "$ConfigDir/PiHole/etc-pihole" "$ConfigDir/PiHole/etc-dnsmasq.d" "$ConfigDir/Unbound"
sudo chown -R 70:70 "$ConfigDir/Postgres"

# IAM-04: Schema Detonation Cured. Rebuilt heredoc mapped to v4.38+ arrays.
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
    - domain: "*.${PrevDomain:-sovereign.local}"
      policy: two_factor
session:
  name: authelia_session
  secret_file: /run/secrets/authelia_session_secret
  expiration: 3600
  inactivity: 300
  cookies:
    - domain: "${PrevDomain:-sovereign.local}"
      authelia_url: "https://auth.${PrevDomain:-sovereign.local}"
regulation:
  max_retries: 3
  find_time: 120
  ban_time: 300
notifier:
  filesystem: { filename: /config/notification.txt }
EOF

# IAM-05: Argon2id Hardening defeats basic SHA-512 hardware cracking
if [ ! -f "${ConfigDir}/Authelia/users_database.yml" ]; then
    sudo tee "${ConfigDir}/Authelia/users_database.yml" > /dev/null << EOF
users:
  admin:
    displayname: "Sovereign Administrator"
    password: "\$argon2id\$v=19\$m=65536,t=3,p=4\$wD4pD5lT8vG6sE8jO7mCQA\$2QOqU5vY3K5zN9yE4mT7qO1pB6uR4sF3jM5vA8nG4X8"
    email: admin@${PrevDomain:-sovereign.local}
    groups: [admins]
EOF
fi

# Host-level directory ownership ensures containers drop privileges successfully
sudo chown -R "$HostUid:$HostGid" "$ConfigDir/WireGuard" "$ConfigDir/Authelia"

sudo touch "${ConfigDir}/Traefik/acme.json"; sudo chmod 600 "${ConfigDir}/Traefik/acme.json"
sudo mkdir -p "$SecretsDir"; sudo chmod 700 "$SecretsDir"

# IAM-03: Containment Paradox Cured. Rolled back to 644 inside 700 vault.
WriteSecret() {
    local name=$1; local content=$2; local tmp_file="${SecretsDir}/${name}.tmp"
    printf "%s" "$content" | sudo tee "$tmp_file" > /dev/null
    sudo touch "${SecretsDir}/${name}"; sudo chmod 644 "${SecretsDir}/${name}"
    sudo sh -c "cat '$tmp_file' > '${SecretsDir}/${name}'"
    sudo shred -u "$tmp_file"
}

if [ "$Interactive" -eq 1 ]; then
    [ ! -f "${SecretsDir}/cf_api_token" ] && { read -s -p "Cloudflare DNS API Token: " cf_token; echo ""; WriteSecret "cf_api_token" "$cf_token"; }
    # SEC-23: Upgraded Traefik's BasicAuth to SHA-512 crypt hashing (-6)
    [ ! -f "${SecretsDir}/traefik_auth" ] && { read -s -p "Traefik BasicAuth Password: " TraefikPass; echo ""; WriteSecret "traefik_auth" "admin:$(openssl passwd -6 "$TraefikPass")"; }
fi
[ ! -f "${SecretsDir}/postgres_password" ] && WriteSecret "postgres_password" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_jwt_secret" ] && WriteSecret "authelia_jwt_secret" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_session_secret" ] && WriteSecret "authelia_session_secret" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_storage_key" ] && WriteSecret "authelia_storage_key" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/pihole_pass" ] && WriteSecret "pihole_pass" "$(openssl rand -hex 16)"

if [ "$Interactive" -eq 1 ]; then
    read -p "WireGuard Public Endpoint [$PrevEndpoint]: " input_endpoint; WgEndpoint="${input_endpoint:-$PrevEndpoint}"
    read -p "WireGuard UDP Port [$PrevPort]: " input_port; WgPort="${input_port:-$PrevPort}"
    read -p "Internal Root Domain [$PrevDomain]: " input_domain; InternalDomain="${input_domain:-$PrevDomain}"
    read -p "Let's Encrypt Email [$PrevEmail]: " input_email; AcmeEmail="${input_email:-$PrevEmail}"
    read -p "Monolith LAN IP [$PrevLanIp]: " input_lan; TraefikLanIp="${input_lan:-$PrevLanIp}"
    read -p "Enable PRODUCTION Let's Encrypt? (y/N): " input_prod
    [[ "${input_prod:-N}" =~ ^[Yy]$ ]] && AcmeServerUrl="https://acme-v02.api.letsencrypt.org/directory" || AcmeServerUrl="https://acme-staging-v02.api.letsencrypt.org/directory"
    
    sudo tee "$EnvFile" > /dev/null << EOF
WG_ENDPOINT=${WgEndpoint}
INTERNAL_DOMAIN=${InternalDomain}
ACME_EMAIL=${AcmeEmail}
ACME_SERVER_URL=${AcmeServerUrl}
WG_PORT=${WgPort}
WG_PEERS=3
TRAEFIK_LAN_IP=${TraefikLanIp}
HOST_UID=${HostUid}
HOST_GID=${HostGid}
TZ=UTC
EOF

    # SYNTAX-03 & IAM-04: YAML Bounded Substitution matching strict array paths.
    sudo sed -i "s/\*\.[^\"]*/\*\.${InternalDomain}/" "${ConfigDir}/Authelia/configuration.yml"
    sudo sed -i "s/domain: .*/domain: \"${InternalDomain}\"/" "${ConfigDir}/Authelia/configuration.yml"
    sudo sed -i "s|authelia_url: .*|authelia_url: \"https://auth.${InternalDomain}\"|" "${ConfigDir}/Authelia/configuration.yml"
    sudo sed -i "s/admin@.*/admin@${InternalDomain}/" "${ConfigDir}/Authelia/users_database.yml"
fi

# Export Persistence
set -a; source "$EnvFile"; set +a

# DNS-12 & DNS-14: Bootstrapping MITM Cured, Ephemeral Keyring Isolation
RootHintUtility="${ScriptsDir}/Verify-RootHints.sh"
sudo tee "$RootHintUtility" > /dev/null << 'EOF'
#!/bin/bash
set -euo pipefail
ConfigDir="/opt/Docker/Config"
EphKeyring="${ConfigDir}/Unbound/icann.gpg"

curl -sS "https://www.internic.net/domain/named.root" -o "${ConfigDir}/Unbound/RootHints.txt.tmp"
curl -sS "https://www.internic.net/domain/named.root.sig" -o "${ConfigDir}/Unbound/RootHints.txt.sig"
curl -sS "https://data.iana.org/root-anchors/icann.pgp" -o "${ConfigDir}/Unbound/icann.pgp"

gpg --no-default-keyring --keyring "$EphKeyring" --import "${ConfigDir}/Unbound/icann.pgp" >/dev/null 2>&1 || true

if ! gpg --no-default-keyring --keyring "$EphKeyring" --fingerprint 0x0BD07395 | tr -d ' ' | grep -q "E0F2C1291162E536E8EEEEF0F781C36C0BD07395"; then
    echo "[FATAL] ICANN PGP Fingerprint mismatch. MitM detected."
    rm -f "${ConfigDir}/Unbound/RootHints.txt.tmp" "${ConfigDir}/Unbound/RootHints.txt.sig" "${ConfigDir}/Unbound/icann.pgp" "$EphKeyring" "${EphKeyring}~"
    exit 1
fi

if gpg --no-default-keyring --keyring "$EphKeyring" --verify "${ConfigDir}/Unbound/RootHints.txt.sig" "${ConfigDir}/Unbound/RootHints.txt.tmp" 2>/dev/null; then
    cat "${ConfigDir}/Unbound/RootHints.txt.tmp" > "${ConfigDir}/Unbound/RootHints.txt"
    rm -f "${ConfigDir}/Unbound/RootHints.txt.tmp" "${ConfigDir}/Unbound/RootHints.txt.sig" "${ConfigDir}/Unbound/icann.pgp" "$EphKeyring" "${EphKeyring}~"
    exit 0
else
    rm -f "${ConfigDir}/Unbound/RootHints.txt.tmp" "${ConfigDir}/Unbound/RootHints.txt.sig" "${ConfigDir}/Unbound/icann.pgp" "$EphKeyring" "${EphKeyring}~"
    exit 1
fi
EOF
sudo chmod 700 "$RootHintUtility"

PrintMsg "240" "Verifying DNS Root Hints via PGP Pinning..."
sudo touch "${ConfigDir}/Unbound/RootHints.txt"
sudo "$RootHintUtility" || { PrintMsg "196" "[FATAL] GPG Signature Failure. Supply chain compromised."; exit 1; }

sudo tee "${ConfigDir}/Unbound/UnboundConfig.conf" > /dev/null << EOF
server:
  interface: 0.0.0.0
  port: 53
  do-ip4: yes
  username: "unbound"
  root-hints: "/opt/unbound/etc/unbound/root.hints"
  auto-trust-anchor-file: "/opt/unbound/etc/unbound/keys/root.key"
  chroot: ""
  access-control: 127.0.0.0/8 allow
  access-control: 10.0.0.0/8 allow
  access-control: 192.168.0.0/16 allow
  access-control: 172.16.0.0/12 allow
  local-zone: "${INTERNAL_DOMAIN}." redirect
  local-data: "${INTERNAL_DOMAIN}. A ${TRAEFIK_LAN_IP}"
EOF

# PROXY-03: Phantom Middleware Cured. `traefik-auth` block injected.
sudo tee "${ConfigDir}/Traefik/Dynamic/DynamicRules.yml" > /dev/null << EOF
http:
  middlewares:
    secure-headers:
      headers:
        stsSeconds: 31536000
        customResponseHeaders:
          X-Frame-Options: "SAMEORIGIN"
          X-XSS-Protection: "1; mode=block"
    vpn-whitelist:
      ipAllowList:
        sourceRange: ["10.13.13.0/24", "10.98.0.0/24", "10.99.0.0/24"]
    authelia:
      forwardAuth:
        address: "http://authelia:9091/api/verify?rd=https://auth.${INTERNAL_DOMAIN}/"
        trustForwardHeader: true
        authResponseHeaders: ["Remote-User", "Remote-Groups"]
    traefik-auth:
      basicAuth:
        usersFile: "/run/secrets/traefik_auth"
  routers:
    auth-router:
      rule: "Host(\`auth.${INTERNAL_DOMAIN}\`)"
      entryPoints: ["websecure"]
      middlewares: ["secure-headers"]
      service: "authelia-service"
      tls: { certResolver: "cloudflare" }
  services:
    authelia-service:
      loadBalancer:
        servers: [{ url: "http://authelia:9091" }]
EOF

sudo tee "$ComposeFile" > /dev/null << EOF
x-logging: &default-logging
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "5"

networks:
  vpn_network:
    name: sovereign_gateway_vpn_network
    ipam: { config: [{ subnet: 10.99.0.0/24 }] }
  proxy_network:
    name: sovereign_gateway_proxy_network
    ipam: { config: [{ subnet: 10.98.0.0/24 }] }
  auth_network: { internal: true }
  socket_network: { internal: true }

volumes:
  unbound_keys: {}

# PROXY-03: traefik_auth secret correctly exposed to the top-level
secrets:
  cf_api_token: { file: ${SecretsDir}/cf_api_token }
  postgres_password: { file: ${SecretsDir}/postgres_password }
  authelia_jwt_secret: { file: ${SecretsDir}/authelia_jwt_secret }
  authelia_session_secret: { file: ${SecretsDir}/authelia_session_secret }
  authelia_storage_key: { file: ${SecretsDir}/authelia_storage_key }
  pihole_pass: { file: ${SecretsDir}/pihole_pass }
  traefik_auth: { file: ${SecretsDir}/traefik_auth }

services:
  docker_socket_proxy:
    image: lscr.io/linuxserver/socket-proxy:latest
    container_name: docker_socket_proxy
    networks: [socket_network]
    environment: [CONTAINERS=1, NETWORKS=1, VERSION=1, EVENTS=1]
    volumes: [/var/run/docker.sock:/var/run/docker.sock:ro]
    cap_drop: ["ALL"]
    security_opt: ["no-new-privileges:true"]
    read_only: true
    tmpfs:
      - /run
      - /tmp
    logging: *default-logging
    restart: unless-stopped
  
  auth_db:
    image: postgres:15-alpine
    container_name: auth_db
    networks: [auth_network]
    secrets: [postgres_password]
    environment:
      POSTGRES_USER: authelia
      POSTGRES_DB: authelia
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    volumes: [${ConfigDir}/Postgres:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d authelia -U authelia"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging: *default-logging
    restart: unless-stopped
  
  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    networks: [proxy_network, auth_network]
    user: "\${HOST_UID:-1000}:\${HOST_GID:-1000}"
    volumes: [${ConfigDir}/Authelia:/config]
    secrets: [postgres_password, authelia_jwt_secret, authelia_session_secret, authelia_storage_key]
    environment:
      AUTHELIA_JWT_SECRET_FILE: /run/secrets/authelia_jwt_secret
      AUTHELIA_SESSION_SECRET_FILE: /run/secrets/authelia_session_secret
      AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE: /run/secrets/authelia_storage_key
      AUTHELIA_STORAGE_POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    depends_on:
      auth_db:
        condition: service_healthy
    logging: *default-logging
    restart: unless-stopped
  
  unbound_dns:
    image: mvance/unbound:latest
    container_name: unbound_dns
    networks:
      vpn_network: { ipv4_address: 10.99.0.11 }
    user: "0:0"
    dns: ["127.0.0.1", "1.1.1.1"]
    volumes:
      - ${ConfigDir}/Unbound/UnboundConfig.conf:/opt/unbound/etc/unbound/unbound.conf:ro
      - ${ConfigDir}/Unbound/RootHints.txt:/opt/unbound/etc/unbound/root.hints:ro
      - unbound_keys:/opt/unbound/etc/unbound/keys:rw
    entrypoint: ["/bin/sh", "-c", "unbound-anchor -a /opt/unbound/etc/unbound/keys/root.key || if [ ! -s /opt/unbound/etc/unbound/keys/root.key ]; then echo '. IN DS 20326 8 2 e06d44b80b8f1d39a95c0b0d7c65d08458e880409bbc683457104237c7f8ec8d' > /opt/unbound/etc/unbound/keys/root.key; fi; chown -R _unbound:_unbound /opt/unbound/etc/unbound/keys 2>/dev/null || chown -R unbound:unbound /opt/unbound/etc/unbound/keys 2>/dev/null || true; exec /opt/unbound/sbin/unbound -d -c /opt/unbound/etc/unbound/unbound.conf"]
    cap_drop: ["ALL"]
    cap_add: ["CHOWN", "SETGID", "SETUID", "NET_BIND_SERVICE"]
    security_opt: ["no-new-privileges:true"]
    healthcheck:
      test: ["CMD-SHELL", "nslookup \${INTERNAL_DOMAIN} 127.0.0.1 >/dev/null || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    logging: *default-logging
    restart: unless-stopped
  
  pihole_sinkhole:
    image: pihole/pihole:latest
    container_name: pihole_sinkhole
    networks:
      vpn_network: { ipv4_address: 10.99.0.12 }
      proxy_network: {}
    dns: ["127.0.0.1", "1.1.1.1"]
    ports: ["0.0.0.0:53:53/tcp", "0.0.0.0:53:53/udp"]
    # SEC-24: Naked Edge Router Armored (Pi-Hole STIG bindings)
    cap_drop: ["ALL"]
    cap_add: ["NET_ADMIN", "NET_RAW", "NET_BIND_SERVICE", "CHOWN", "SETUID", "SETGID", "DAC_OVERRIDE", "FOWNER", "SYS_NICE", "SYS_CHROOT"]
    security_opt: ["no-new-privileges:true"]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.pihole.rule=Host(\`pihole.\${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.pihole.entrypoints=websecure"
      - "traefik.http.routers.pihole.tls.certresolver=cloudflare"
      - "traefik.http.services.pihole.loadbalancer.server.port=80"
      - "traefik.http.middlewares.pihole-redirect.redirectregex.regex=^https://pihole\.\${INTERNAL_DOMAIN}/\\$\\$"
      - "traefik.http.middlewares.pihole-redirect.redirectregex.replacement=https://pihole.\${INTERNAL_DOMAIN}/admin/"
      - "traefik.http.routers.pihole.middlewares=secure-headers@file,authelia@file,pihole-redirect"
      - "traefik.docker.network=sovereign_gateway_proxy_network"
    secrets: [pihole_pass]
    environment:
      WEBPASSWORD_FILE: /run/secrets/pihole_pass
      PIHOLE_DNS_: 10.99.0.11#53
      DNSMASQ_LISTENING: all
    depends_on:
      unbound_dns:
        condition: service_healthy
    logging: *default-logging
    restart: unless-stopped
  
  wireguard_vpn:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: wireguard_vpn
    networks:
      vpn_network: { ipv4_address: 10.99.0.10 }
    cap_drop: ["ALL"]
    cap_add: ["NET_ADMIN", "NET_RAW", "CHOWN", "SETUID", "SETGID", "DAC_OVERRIDE", "FOWNER"]
    environment:
      PUID: "\${HOST_UID}"
      PGID: "\${HOST_GID}"
      SERVERURL: \${WG_ENDPOINT}
      SERVERPORT: \${WG_PORT}
      PEERS: 3
      PEERDNS: 10.99.0.12
      INTERNAL_SUBNET: 10.13.13.0/24
    volumes:
      - /lib/modules:/lib/modules:ro
      - ${ConfigDir}/WireGuard:/config
    devices: [/dev/net/tun:/dev/net/tun]
    ports: ["0.0.0.0:\${WG_PORT}:\${WG_PORT}/udp"]
    logging: *default-logging
    restart: unless-stopped
  
  traefik_proxy:
    image: traefik:v2.11
    container_name: traefik_proxy
    networks: [socket_network, proxy_network]
    ports: ["0.0.0.0:80:80", "0.0.0.0:443:443"]
    volumes:
      - ${ConfigDir}/Traefik/Dynamic:/etc/traefik/dynamic:ro
      - ${ConfigDir}/Traefik/acme.json:/acme.json:rw
    secrets: [cf_api_token, traefik_auth]
    environment:
      CF_DNS_API_TOKEN_FILE: /run/secrets/cf_api_token
    # SEC-24: Naked Edge Router Armored (Traefik STIG bindings)
    cap_drop: ["ALL"]
    cap_add: ["NET_BIND_SERVICE"]
    security_opt: ["no-new-privileges:true"]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-dashboard.rule=Host(\`proxy.\${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.traefik-dashboard.entrypoints=websecure"
      - "traefik.http.routers.traefik-dashboard.tls.certresolver=cloudflare"
      - "traefik.http.routers.traefik-dashboard.service=api@internal"
      - "traefik.http.routers.traefik-dashboard.middlewares=secure-headers@file,authelia@file"
      - "traefik.docker.network=sovereign_gateway_proxy_network"
    command:
      - "--api.dashboard=true"
      - "--api.insecure=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.websecure.forwardedHeaders.trustedIPs=127.0.0.1/32,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,10.98.0.0/24,10.99.0.0/24,\${TRAEFIK_LAN_IP}/32"
      - "--providers.docker=true"
      - "--providers.docker.endpoint=tcp://docker_socket_proxy:2375"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--certificatesresolvers.cloudflare.acme.caserver=\${ACME_SERVER_URL}"
      - "--certificatesresolvers.cloudflare.acme.email=\${ACME_EMAIL}"
      - "--certificatesresolvers.cloudflare.acme.storage=/acme.json"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare"
    logging: *default-logging
    restart: unless-stopped
EOF

sudo tee /etc/systemd/system/sovereign-updater.service > /dev/null << EOF
[Unit]
Description=Sovereign Gateway Weekly Updater
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c '${RootHintUtility} && cd ${StackDir} && ${DockerBin} compose pull && ${DockerBin} compose up -d && ${DockerBin} image prune -f && ${DockerBin} compose restart unbound_dns'
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/sovereign-updater.timer > /dev/null << EOF
[Unit]
Description=Weekly Timer for Sovereign Updater

[Timer]
OnCalendar=weekly
RandomizedDelaySec=12h
Persistent=true

[Install]
WantedBy=timers.target
EOF

WatchdogScript="${ScriptsDir}/WatchdogSovereignGateway.sh"
sudo tee "$WatchdogScript" > /dev/null << EOF
#!/bin/bash
for manifest in "${ConfigDir}/Traefik/Dynamic/"*_assimilation.yml; do
    [ -e "\$manifest" ] || continue
    alien=\$(grep "^# ALIEN_CONTAINER: " "\$manifest" | cut -d' ' -f3 || true)
    [ -z "\$alien" ] && continue
    if ${DockerBin} ps --format '{{.Names}}' | grep -q "^\${alien}\$"; then
        if ! ${DockerBin} inspect "\$alien" --format '{{json .NetworkSettings.Networks}}' | grep -q "sovereign_gateway_proxy_network"; then
            ${DockerBin} network connect sovereign_gateway_proxy_network "\$alien" || true
        fi
    fi
done
EOF
sudo chmod 700 "$WatchdogScript"

sudo tee /etc/systemd/system/sovereign-watchdog.service > /dev/null << EOF
[Unit]
Description=Sovereign Gateway Hourly Watchdog
After=docker.service

[Service]
Type=oneshot
ExecStart=$WatchdogScript
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/sovereign-watchdog.timer > /dev/null << EOF
[Unit]
Description=Hourly Timer for Sovereign Watchdog

[Timer]
OnCalendar=hourly
RandomizedDelaySec=5m
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now sovereign-updater.timer sovereign-watchdog.timer

if [ "$Interactive" -eq 1 ]; then PrintMsg "226" "Igniting Sovereign Matrix..."; fi
cd "$StackDir" && sudo $DockerBin compose up -d --force-recreate --remove-orphans

AssimilateAlienContainers() {
    if [ "$Interactive" -eq 1 ] && command -v docker &> /dev/null; then
        local foreign_containers=$(sudo $DockerBin ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' -v stack="${StackName,,}" 'tolower($2) != stack && $1 != "" {print $1}')
        if [ -n "$foreign_containers" ]; then
            local found_new=0
            for container in $foreign_containers; do
                local clean_name=$(echo "$container" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
                local manifest_file="${ConfigDir}/Traefik/Dynamic/${clean_name}_assimilation.yml"
                if [ -f "$manifest_file" ]; then
                    sudo $DockerBin network connect sovereign_gateway_proxy_network "$container" >/dev/null 2>&1 || true
                    continue
                fi
                if [ $found_new -eq 0 ]; then
                    echo ""
                    PrintMsg "214" "========================================================================"
                    PrintMsg "214" " 🛸 ALIEN ASSIMILATION PROTOCOL INITIATED"
                    PrintMsg "214" "========================================================================"
                    found_new=1
                fi
                echo ""
                PrintMsg "214" "Select ingress posture for unassimilated container [$container]:"
                local posture_choice=""
                if command -v gum &> /dev/null; then
                    local choice=$(gum choose "1) MFA Protected (Authelia) [SUGGESTED]" "2) VPN-Only (Air-Gapped)" "3) BasicAuth (Legacy Form)" "4) Fully Public" "5) Internal (Skip)" || true)
                    [ -z "$choice" ] && continue
                    posture_choice=${choice:0:1}
                else
                    echo "1) MFA Protected (Authelia) [SUGGESTED]"
                    echo "2) VPN-Only (Air-Gapped)"
                    echo "3) BasicAuth (Legacy Form)"
                    echo "4) Fully Public"
                    echo "5) Internal (Skip)"
                    read -p "Select posture (1-5) [1]: " posture_choice || true
                    posture_choice=${posture_choice:-1}
                fi
                if [ "$posture_choice" -eq 5 ]; then continue; fi
                local TargetPort=""
                if command -v gum &> /dev/null; then
                    TargetPort=$(gum input --prompt "Internal listening port for $container (e.g. 80, 8080): " || true)
                else
                    read -p "Internal listening port for $container (e.g. 80, 8080): " TargetPort || true
                fi
                if [ -z "$TargetPort" ]; then continue; fi
                local mw_string=""
                case "$posture_choice" in
                    1) mw_string="secure-headers@file,authelia@file" ;;
                    2) mw_string="secure-headers@file,vpn-whitelist@file" ;;
                    3) mw_string="secure-headers@file,traefik-auth@file" ;;
                    4) mw_string="secure-headers@file" ;;
                esac
                PrintMsg "226" "Bridging $container to Zero-Trust perimeter..."
                sudo $DockerBin network connect sovereign_gateway_proxy_network "$container" >/dev/null 2>&1 || true
                sudo tee "$manifest_file" > /dev/null << MANIFEST_EOF
# ALIEN_CONTAINER: $container
http:
  routers:
    ${clean_name}-router:
      rule: "Host(\`${clean_name}.\${INTERNAL_DOMAIN}\`)"
      entryPoints: ["websecure"]
      middlewares: [${mw_string}]
      service: "${clean_name}-service"
      tls: { certResolver: "cloudflare" }
  services:
    ${clean_name}-service:
      loadBalancer:
        servers: [{ url: "http://${container}:${TargetPort}" }]
MANIFEST_EOF
                PrintMsg "82" "✔ Assimilated: https://${clean_name}.${InternalDomain}"
            done
        fi
    fi
}
AssimilateAlienContainers

if [ "$Interactive" -eq 1 ]; then
    PrintMsg "240" "Waiting for s6-overlay to forge cryptographic identity..."
    wg_timeout=0
    while [ ! -f "${ConfigDir}/WireGuard/peer1/peer1.conf" ] && [ $wg_timeout -lt 30 ]; do
        sleep 1
        wg_timeout=$((wg_timeout + 1))
    done

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
    PrintMsg "226" " Your first login attempt at https://pihole.${INTERNAL_DOMAIN}"
    PrintMsg "226" " will trigger an email to register your biometric/2FA device."
    PrintMsg "82"  " Retrieve your registration link by running:"
    PrintMsg "196" " sudo cat ${ConfigDir}/Authelia/notification.txt"
    PrintMsg "214" "========================================================================"
    
    if [ -f "${ConfigDir}/WireGuard/peer1/peer1.conf" ]; then
        echo ""
        PrintMsg "196" " ⚠️  WIREGUARD ONBOARDING"
        PrintMsg "226" " Retrieve your cryptographic VPN payload natively by running:"
        PrintMsg "196" " sudo qrencode -t ansiutf8 < ${ConfigDir}/WireGuard/peer1/peer1.conf"
        PrintMsg "214" "========================================================================"
    else
        PrintMsg "196" "WARNING: Cryptographic forging is taking longer than expected. Check the directory manually."
    fi

    echo ""
    PrintMsg "82" "✔ Unified Matrix Online. Turn the key."
fi

exit 0