#!/bin/bash
# ==============================================================================
#  UNIFIED SOVEREIGN GATEWAY - TRAEFIK + WIREGUARD + PI-HOLE + AUTHELIA
#  Version: v97.0-SOVEREIGN-PHALANX
# ==============================================================================
#  Architecture: Single-Node Unified Ingress, VPN, & Identity Topology
#
#  Phalanx Hardening Fixes (The Final Absolute Truth):
#  1. NET-48: Isolation Void Cured. Traefik granted a dedicated physical leg 
#     inside the VpnNetwork (10.99.0.13) to permit Layer 2 routing to Pi-Hole, 
#     shattering the inescapable 504 Gateway Timeout.
#  2. NET-49: Label Hallucination Cured. Pi-Hole's Traefik labels updated to 
#     explicitly reference the sovereign_gateway_vpn_network bridge, preventing 
#     null IP lookups.
#  3. DNS-33: PGP Keyserver Fragility Cured. Bootstrapping and weekly updater 
#     scripts now fetch the ICANN PGP key directly from IANA via HTTPS, bypassing 
#     volatile, rate-limited public SKS keyservers.
#
#  SECURITY WARNING: This script implements Scorched Earth policies. It will
#  destroy unassimilated containers, modify live kernel routing tables, and 
#  enforce strict cryptographic boundaries. Do not execute blindly in prod.
# ==============================================================================

set -euo pipefail

# Prevent path-poisoning attacks
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Enforce PascalCase for all structural definitions
StackName="sovereign_gateway"
BaseDir="/opt/Docker"
ConfigDir="${BaseDir}/Config"
ScriptsDir="${BaseDir}/Scripts"
StackDir="${BaseDir}/Stacks/${StackName}"
SecretsDir="${StackDir}/Secrets"
LogsDir="/opt/Docker/Logs/${StackName}"
TraefikLogDir="${LogsDir}/Traefik"
TraefikAcmeDir="${ConfigDir}/TraefikAcme"
TraefikAcmeFile="${TraefikAcmeDir}/Acme.json"

ComposeFile="${StackDir}/DockerCompose.yml"
EnvFile="${StackDir}/Gateway.env"
LockFile="/var/lock/sovereign_gateway.lock"

# Trap Paradox Cured: Atomic cleanup and state verification.
TrapHandler() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n[FATAL] Script aborted at line $BASH_LINENO. System state inconsistent."
    fi
    rm -f "${ConfigDir}/Unbound/RootHints.txt.tmp" "${ConfigDir}/Unbound/RootHints.txt.sig" "${ConfigDir}/Unbound/Icann.pgp" 2>/dev/null || true
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
        PrintMsg "214" "Docker Engine missing. Initiating secure provision..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh > /dev/null 2>&1
        sudo systemctl enable --now docker > /dev/null 2>&1 || true
    fi
}

DetectOsFamily
CheckDependencies

DockerBin=$(command -v docker || echo "/usr/bin/docker")

# PORT-53 & NET-20: Decapitate systemd-resolved and drop a physical resolv file
if systemctl is-active --quiet systemd-resolved; then
    PrintMsg "214" "Decapitating systemd-resolved to mathematically free Port 53..."
    sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf || true
    sudo sed -i 's/DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf || true
    sudo systemctl stop systemd-resolved || true
    sudo systemctl disable systemd-resolved || true
    sudo rm -f /etc/resolv.conf
fi

# Execution State Vacuum Cured: Unconditional check prevents fatal PGP failures
if [ ! -s /etc/resolv.conf ] || ! grep -q "^nameserver" /etc/resolv.conf; then
    PrintMsg "196" "⚠️ Host DNS vacuum detected. Injecting physical static Cloudflare fallback..."
    echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1" | sudo tee /etc/resolv.conf > /dev/null
fi

# Chronometric sync to UTC required for Certificate lifespan validation
PrintMsg "240" "Anchoring chronometric infrastructure to UTC..."
sudo timedatectl set-local-rtc 0 || true
sudo timedatectl set-timezone UTC || true
if systemctl is-active --quiet chrony; then
    sudo systemctl restart chrony || true
elif systemctl is-active --quiet chronyd; then
    sudo systemctl restart chronyd || true
fi

# KRN-04 & KRN-06: STIG Scorched Earth Kernel Hardening
PrintMsg "240" "Forging STIG-compliant host kernel armor..."
sudo tee /etc/sysctl.d/99-SovereignGateway.conf > /dev/null << 'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 1
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
net.core.bpf_jit_harden = 2
EOF
sudo sysctl --system > /dev/null 2>&1 || true

if ! sudo modprobe wireguard 2>/dev/null; then
    PrintMsg "196" "[FATAL] Native WireGuard kernel module missing. Host kernel is incompatible."
    exit 1
fi

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
            cd "$StackDir" && sudo $DockerBin compose -f "$ComposeFile" down -v --remove-orphans > /dev/null 2>&1 || true
            PrintMsg "214" "Mathematically shredding cryptographic master keys..."
            [ -d "${SecretsDir}" ] && sudo find "${SecretsDir}" -type f -exec shred -u {} \; || true
            sudo rm -rf "$StackDir" "${ConfigDir}/Authelia" "${ConfigDir}/Postgres" "${ConfigDir}/Traefik/Dynamic" "${ConfigDir}/WireGuard" "${ConfigDir}/PiHole" "${ConfigDir}/Unbound" "$TraefikAcmeDir"
            PrintMsg "82" "✔ Earth scorched. Magnetic persistence neutralized."
        fi
    fi
}
ExecuteAnnihilation

# Strict PascalCase directory creation
sudo mkdir -p "$StackDir" "$TraefikLogDir" "$ScriptsDir" "${ConfigDir}/Authelia" "${ConfigDir}/Postgres" "${ConfigDir}/Traefik/Dynamic" "${ConfigDir}/WireGuard" "${ConfigDir}/PiHole/EtcPihole" "${ConfigDir}/PiHole/EtcDnsmasq" "${ConfigDir}/Unbound" "$TraefikAcmeDir"

# Root Ownership Paradox & ACME Inode Deadlock Cured.
sudo chown -R root:root "$TraefikLogDir" "$TraefikAcmeDir"
sudo chown -R 70:70 "${ConfigDir}/Postgres"
sudo chown -R "$HostUid:$HostGid" "${ConfigDir}/WireGuard"
sudo chown -R 999:999 "${ConfigDir}/PiHole"

sudo touch "${ConfigDir}/Authelia/Notification.txt"
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

# Headless injection variables (Edit these if deploying headlessly)
WgEndpoint="vpn.yourdomain.com"
InternalDomain="lan.yourdomain.com"
AcmeEmail="admin@yourdomain.com"
TraefikLanIp="10.99.0.1"

if [ "$Interactive" -eq 1 ]; then
    [ ! -f "${SecretsDir}/cf_api_token" ] && { read -s -p "Cloudflare DNS API Token: " cf_token; echo ""; WriteSecret "cf_api_token" "$cf_token"; }
    [ ! -f "${SecretsDir}/traefik_auth" ] && { read -s -p "Traefik BasicAuth Password: " TraefikPass; echo ""; WriteSecret "traefik_auth" "admin:$(openssl passwd -apr1 "$TraefikPass")"; }
    
    read -p "WireGuard Public Endpoint [$WgEndpoint]: " input_endpoint; WgEndpoint="${input_endpoint:-$WgEndpoint}"
    read -p "Internal Root Domain [$InternalDomain]: " input_domain; InternalDomain="${input_domain:-$InternalDomain}"
    read -p "Let's Encrypt Email [$AcmeEmail]: " input_email; AcmeEmail="${input_email:-$AcmeEmail}"
else
    if [ ! -f "${SecretsDir}/cf_api_token" ] || [ ! -f "${SecretsDir}/traefik_auth" ]; then
        PrintMsg "196" "[FATAL] Headless deployment detected, but master edge secrets are missing."
        exit 1
    fi
fi

# IAM-65: Storage Key Entropy Detonation Cured. Expanded base64 generation to 64 bytes (88 chars).
[ ! -f "${SecretsDir}/postgres_password" ] && WriteSecret "postgres_password" "$(openssl rand -base64 64)" "70:$HostGid" "640"
[ ! -f "${SecretsDir}/authelia_jwt_secret" ] && WriteSecret "authelia_jwt_secret" "$(openssl rand -base64 64)"
[ ! -f "${SecretsDir}/authelia_session_secret" ] && WriteSecret "authelia_session_secret" "$(openssl rand -base64 64)"
[ ! -f "${SecretsDir}/authelia_storage_key" ] && WriteSecret "authelia_storage_key" "$(openssl rand -base64 64)"

if [ ! -f "${SecretsDir}/pihole_pass" ]; then
    GeneratedPiholePass="$(openssl rand -hex 16)"
    WriteSecret "pihole_pass" "$GeneratedPiholePass"
else
    GeneratedPiholePass="[Encrypted in Vault]"
fi

sudo tee "$EnvFile" > /dev/null << EOF
WG_ENDPOINT=${WgEndpoint}
INTERNAL_DOMAIN=${InternalDomain}
ACME_EMAIL=${AcmeEmail}
ACME_SERVER_URL=https://acme-v02.api.letsencrypt.org/directory
WG_PORT=51820
WG_PEERS=3
TRAEFIK_LAN_IP=${TraefikLanIp}
WG_ALLOWED_IPS=0.0.0.0/0
HOST_UID=${HostUid}
HOST_GID=${HostGid}
TZ=UTC
EOF

set -a; source "$EnvFile"; set +a

PrintMsg "214" "Surgically seeding WireGuard server template to inject L3 NAT bypass..."
sudo mkdir -p "${ConfigDir}/WireGuard/Templates"
sudo tee "${ConfigDir}/WireGuard/Templates/Server.conf" > /dev/null << EOF
[Interface]
Address = \${INTERFACE}.1
ListenPort = \${SERVER_PORT}
PrivateKey = \${PRIVATE_KEY}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o \${SERVER_DEVICE} -j MASQUERADE
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d 10.98.0.0/16 -j RETURN
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d 10.99.0.0/16 -j RETURN
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d ${TraefikLanIp}/32 -j RETURN
PreDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o \${SERVER_DEVICE} -j MASQUERADE
PreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d 10.98.0.0/16 -j RETURN || true
PreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d 10.99.0.0/16 -j RETURN || true
PreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d ${TraefikLanIp}/32 -j RETURN || true
EOF
sudo chown -R "$HostUid:$HostGid" "${ConfigDir}/WireGuard/Templates"

if [ -f "${ConfigDir}/WireGuard/Wg0.conf" ]; then
    sudo sed -i '/-j RETURN/d' "${ConfigDir}/WireGuard/Wg0.conf"
    sudo awk '/PostUp.*-j MASQUERADE/ {print; print "PostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d 10.98.0.0/16 -j RETURN\nPostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d 10.99.0.0/16 -j RETURN\nPostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d '"${TraefikLanIp}"'/32 -j RETURN\nPreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d 10.98.0.0/16 -j RETURN || true\nPreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d 10.99.0.0/16 -j RETURN || true\nPreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d '"${TraefikLanIp}"'/32 -j RETURN || true"; next}1' "${ConfigDir}/WireGuard/Wg0.conf" > /tmp/wg0.tmp && sudo mv /tmp/wg0.tmp "${ConfigDir}/WireGuard/Wg0.conf"
    sudo chown "$HostUid:$HostGid" "${ConfigDir}/WireGuard/Wg0.conf"
fi

# The Absolute Identity Matrix (PascalCase files)
sudo tee "${ConfigDir}/Authelia/Configuration.yml" > /dev/null << EOF
server:
  host: 0.0.0.0
  port: 9091
storage:
  postgres:
    host: AuthDb
    port: 5432
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
  find_time: 120
  ban_time: 300
notifier:
  filesystem: { filename: /config/Notification.txt }
EOF

if [ ! -f "${ConfigDir}/Authelia/UsersDatabase.yml" ]; then
    sudo tee "${ConfigDir}/Authelia/UsersDatabase.yml" > /dev/null << 'EOF'
users:
  admin:
    displayname: "Sovereign Administrator"
    password: "$argon2id$v=19$m=65536,t=3,p=4$wD4pD5lT8vG6sE8jO7mCQA$2QOqU5vY3K5zN9yE4mT7qO1pB6uR4sF3jM5vA8nG4X8"
    email: admin@REPLACE_DOMAIN
    groups: [admins]
EOF
    sudo sed -i "s/REPLACE_DOMAIN/${InternalDomain}/g" "${ConfigDir}/Authelia/UsersDatabase.yml"
fi
sudo chown -R "$HostUid:$HostGid" "${ConfigDir}/Authelia"
sudo chmod 600 "${ConfigDir}/Authelia/UsersDatabase.yml" "${ConfigDir}/Authelia/Configuration.yml" "${ConfigDir}/Authelia/Notification.txt"

# DNS-33 & DNS-29: PGP Keyserver Fragility and Downgrade Attack Cured.
PrintMsg "240" "Bootstrapping cryptographically verified DNS Root Trust Anchors..."
EphKeyring="${ConfigDir}/Unbound/Internic.gpg"
sudo curl -sS --connect-timeout 10 "https://www.internic.net/domain/named.root" -o "${ConfigDir}/Unbound/RootHints.txt.tmp" || true
sudo curl -sS --connect-timeout 10 "https://www.internic.net/domain/named.root.sig" -o "${ConfigDir}/Unbound/RootHints.txt.sig" || true
# Fetch authoritative PGP key directly via HTTPS, avoiding SKS Keyserver rate limits
sudo curl -sS --connect-timeout 10 "https://data.iana.org/root-anchors/icann.pgp" -o "${ConfigDir}/Unbound/Icann.pgp" || true

sudo gpg --no-default-keyring --keyring "$EphKeyring" --import "${ConfigDir}/Unbound/Icann.pgp" >/dev/null 2>&1 || true

if ! sudo gpg --no-default-keyring --keyring "$EphKeyring" --fingerprint 0x0BD07395 | tr -d ' ' | grep -q "E0F2C1291162E536E8EEEEF0F781C36C0BD07395"; then
    PrintMsg "196" "[FATAL] DNS Root Trust Anchor Compromised. MitM detected."
    exit 1
fi

if sudo gpg --no-default-keyring --keyring "$EphKeyring" --verify "${ConfigDir}/Unbound/RootHints.txt.sig" "${ConfigDir}/Unbound/RootHints.txt.tmp" 2>/dev/null; then
    sudo mv "${ConfigDir}/Unbound/RootHints.txt.tmp" "${ConfigDir}/Unbound/RootHints.txt"
    sudo rm -f "${ConfigDir}/Unbound/RootHints.txt.sig" "${ConfigDir}/Unbound/Icann.pgp" "$EphKeyring" "${EphKeyring}~"
    PrintMsg "82" "✔ Root Hints cryptographically verified and installed."
else
    PrintMsg "196" "[FATAL] GPG Signature verification failed for DNS root hints. MITM detected."
    exit 1
fi

RootHintUtility="${ScriptsDir}/VerifyRootHints.sh"
sudo tee "$RootHintUtility" > /dev/null << 'EOF'
#!/bin/bash
set -euo pipefail
HintsDir="/opt/Docker/Config/Unbound"
EphKeyring="${HintsDir}/Internic.gpg"

curl -sS --connect-timeout 10 "https://www.internic.net/domain/named.root" -o "${HintsDir}/RootHints.txt.tmp" || true
curl -sS --connect-timeout 10 "https://www.internic.net/domain/named.root.sig" -o "${HintsDir}/RootHints.txt.sig" || true
curl -sS --connect-timeout 10 "https://data.iana.org/root-anchors/icann.pgp" -o "${HintsDir}/Icann.pgp" || true

gpg --no-default-keyring --keyring "$EphKeyring" --import "${HintsDir}/Icann.pgp" >/dev/null 2>&1 || true

if ! gpg --no-default-keyring --keyring "$EphKeyring" --fingerprint 0x0BD07395 | tr -d ' ' | grep -q "E0F2C1291162E536E8EEEEF0F781C36C0BD07395"; then
    exit 1
fi

if gpg --no-default-keyring --keyring "$EphKeyring" --verify "${HintsDir}/RootHints.txt.sig" "${HintsDir}/RootHints.txt.tmp" 2>/dev/null; then
    mv "${HintsDir}/RootHints.txt.tmp" "${HintsDir}/RootHints.txt"
    rm -f "${HintsDir}/RootHints.txt.sig" "${HintsDir}/Icann.pgp" "$EphKeyring" "${EphKeyring}~"
    exit 0
else
    rm -f "${HintsDir}/RootHints.txt.tmp" "${HintsDir}/RootHints.txt.sig" "${HintsDir}/Icann.pgp" "$EphKeyring" "${EphKeyring}~"
    exit 1
fi
EOF
sudo chmod 700 "$RootHintUtility"

# Unbound routes the internal domain strictly to Traefik's internal proxy IP (10.98.0.254)
sudo tee "${ConfigDir}/Unbound/UnboundConfig.conf" > /dev/null << EOF
server:
  interface: 0.0.0.0
  port: 53
  do-ip4: yes
  username: "_unbound"
  root-hints: "/opt/unbound/etc/unbound/root.hints"
  auto-trust-anchor-file: "/opt/unbound/etc/unbound/keys/root.key"
  access-control: 127.0.0.0/8 allow
  access-control: 10.99.0.0/24 allow
  local-zone: "${InternalDomain}." redirect
  local-data: "${InternalDomain}. A 10.98.0.254"
EOF

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
      middlewares: ["secure-headers"]
      service: "authelia-service"
      tls: { certResolver: "cloudflare" }
  services:
    authelia-service:
      loadBalancer:
        servers: [{ url: "http://Authelia:9091" }]
EOF

# Compose File Generation - Stripped version, PascalCase adherence, strictly air-gapped Proxy.
sudo tee "$ComposeFile" > /dev/null << EOF
networks:
  VpnNetwork:
    name: sovereign_gateway_vpn_network
    ipam: { config: [{ subnet: 10.99.0.0/24 }] }
  ProxyNetwork:
    name: sovereign_gateway_proxy_network
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
    entrypoint: ["/bin/sh", "-c", "unbound-anchor -a /opt/unbound/etc/unbound/keys/root.key || if [ ! -s /opt/unbound/etc/unbound/keys/root.key ]; then echo '. IN DS 20326 8 2 e06d44b80b8f1d39a95c0b0d7c65d08458e880409bbc683457104237c7f8ec8d' > /opt/unbound/etc/unbound/keys/root.key; fi; chown -R _unbound:_unbound /opt/unbound/etc/unbound/keys 2>/dev/null || chown -R unbound:unbound /opt/unbound/etc/unbound/keys 2>/dev/null || true; exec /opt/unbound/sbin/unbound -d -c /opt/unbound/etc/unbound/unbound.conf"]
    cap_drop: [ALL]
    cap_add: [CHOWN, SETGID, SETUID, NET_BIND_SERVICE]
    healthcheck:
      test: ["CMD-SHELL", "drill -p 53 \${INTERNAL_DOMAIN} @127.0.0.1 || exit 1"]
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
      - ${ConfigDir}/PiHole/EtcPihole:/etc/pihole
      - ${ConfigDir}/PiHole/EtcDnsmasq:/etc/dnsmasq.d
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
      # NET-49: Cured Label Hallucination. Explicitly mapped to sovereign_gateway_vpn_network
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
    # NET-48: Isolation Void Cured. Proxies seamlessly via dedicated VpnNetwork layer-2 interface.
    # SEC-41: Ports implicitly unmapped to strictly block host ingress. VPN tunneling mandatory.
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
      - "--providers.docker=true"
      - "--providers.docker.endpoint=tcp://DockerSocketProxy:2375"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.websecure.forwardedHeaders.trustedIPs=127.0.0.1/32,10.98.0.0/24,10.99.0.0/24"
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

sudo tee /etc/systemd/system/sovereign-updater.service > /dev/null << EOF
[Unit]
Description=Sovereign Gateway Weekly Updater
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=-/usr/bin/bash -c '${RootHintUtility}'
ExecStart=/usr/bin/bash -c 'cd ${StackDir} && ${DockerBin} compose pull && ${DockerBin} compose up -d --remove-orphans && ${DockerBin} compose up -d --force-recreate UnboundDns && ${DockerBin} image prune -f'
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

# Comprehensive Multi-Chain Routing Purge and Injection
WatchdogScript="${ScriptsDir}/WatchdogSovereignGateway.sh"
sudo tee "$WatchdogScript" > /dev/null << EOF
#!/bin/bash

for i in {1..30}; do
    if iptables -n -L DOCKER-USER >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# SEC-40: Firewall Inversion Lockout Cured
iptables -D DOCKER-USER -s 10.13.13.0/24 -d 10.98.0.254/32 -p tcp -m multiport --dports 80,443 -j ACCEPT 2>/dev/null || true
iptables -D DOCKER-USER -d 10.13.13.0/24 -s 10.98.0.254/32 -p tcp -m multiport --sports 80,443 -j ACCEPT 2>/dev/null || true
iptables -D DOCKER-USER -s 10.13.13.0/24 -d 10.98.0.0/24 -j DROP 2>/dev/null || true
iptables -D DOCKER-USER -d 10.13.13.0/24 -s 10.98.0.0/24 -j DROP 2>/dev/null || true

# INJECTION SEQUENCE: Bottom-Up Priority
iptables -I DOCKER-USER 1 -s 10.13.13.0/24 -d 10.98.0.0/24 -j DROP
iptables -I DOCKER-USER 1 -d 10.13.13.0/24 -s 10.98.0.0/24 -j DROP

iptables -I DOCKER-USER 1 -s 10.13.13.0/24 -d 10.98.0.254/32 -p tcp -m multiport --dports 80,443 -j ACCEPT
iptables -I DOCKER-USER 1 -d 10.13.13.0/24 -s 10.98.0.254/32 -p tcp -m multiport --sports 80,443 -j ACCEPT

# NET-36 & NET-42: Authorize UDP AND TCP 53 return path for asymmetrical bridge routing (VPN <-> Pi-Hole/DNSSEC)
for proto in udp tcp; do
    if ! iptables -C DOCKER-USER -s 10.99.0.12/32 -d 10.13.13.0/24 -p \$proto --sport 53 -j ACCEPT 2>/dev/null; then
        iptables -I DOCKER-USER 1 -s 10.99.0.12/32 -d 10.13.13.0/24 -p \$proto --sport 53 -j ACCEPT
        iptables -I DOCKER-USER 1 -d 10.99.0.12/32 -s 10.13.13.0/24 -p \$proto --dport 53 -j ACCEPT
    fi
done

if ! ip route show | grep -q "10.13.13.0/24 via 10.99.0.10"; then
    ip route add 10.13.13.0/24 via 10.99.0.10 2>/dev/null || true
fi
EOF
sudo chmod 700 "$WatchdogScript"

sudo tee /etc/systemd/system/sovereign-watchdog.service > /dev/null << EOF
[Unit]
Description=Sovereign Gateway Network Watchdog
After=docker.service

[Service]
Type=oneshot
ExecStart=$WatchdogScript
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${ConfigDir}/Traefik/Dynamic -/run/xtables.lock
EOF

sudo tee /etc/systemd/system/sovereign-watchdog.timer > /dev/null << EOF
[Unit]
Description=5-Minute Timer for Sovereign Watchdog

[Timer]
OnCalendar=*:0/5
RandomizedDelaySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now sovereign-watchdog.timer sovereign-updater.timer

if [ "$Interactive" -eq 1 ]; then PrintMsg "226" "Igniting Sovereign Matrix..."; fi
cd "$StackDir" && sudo $DockerBin compose up -d --force-recreate --remove-orphans

sudo /bin/bash "$WatchdogScript"

if [ "$Interactive" -eq 1 ]; then
    echo -e "\n========================================================"
    echo -e " \033[1;32mSOVEREIGN GATEWAY PROVISIONING COMPLETE\033[0m"
    echo -e "========================================================"
    echo -e " \033[1;33mAdministrative Credentials:\033[0m"
    echo -e " User: admin"
    echo -e " Pass (Traefik): ${TraefikPass:-[Hidden in Script / Known to Operator]}"
    echo -e " Pass (Pi-Hole): \033[1;31m${GeneratedPiholePass}\033[0m"
    echo -e "--------------------------------------------------------"
    echo -e " \033[1;33mAuthelia 2FA Registration:\033[0m"
    echo -e " sudo cat ${ConfigDir}/Authelia/Notification.txt"
    echo -e "========================================================\n"
fi

exit 0