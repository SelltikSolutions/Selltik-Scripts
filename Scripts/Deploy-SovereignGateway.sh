#!/bin/bash
# ==============================================================================
#  UNIFIED SOVEREIGN GATEWAY - TRAEFIK + WIREGUARD + PI-HOLE + AUTHELIA
#  Version: v15.0-SOVEREIGN-MASTER
# ==============================================================================
#  Architecture: Single-Node Unified Ingress, VPN, & Identity Topology
#  Master Hardening Fixes:
#  - CRON-102: Purged Semicolon Poisoning. Systemd unit files now use proper 
#              literal newlines (\n) to ensure the daemon can parse them.
#  - DNS-06: Restored DNSSEC Trust Anchor. Mounted the 'unbound_keys' volume 
#            as :rw to allow RFC 5011 automated key rollovers.
#  - HEALTH-11: Corrected Healthcheck Ghost. Replaced non-existent 'nc' with 
#               Alpine's native 'nslookup' for reliable resolution testing.
#  - SEC-14: Cryptographic Identity Mapped. Added PUID/PGID to WireGuard to 
#            ensure the s6-overlay drops root and preserves host file access.
#  Inherited STIG Fixes:
#  - SEC-08 (Shred), KRN-01 (Kernel Armor), TIME-01/02 (Chrony & Temporal Gate), 
#    LOG-05 (Native Rotation), PATH-09 (Absolute Paths), ENV-05 (set -a),
#    DNS-05 (Unified Trust Chain).
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

# DOCKER-01: Snake_case enforced for native engine discovery
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
}

DetectOsFamily
CheckDependencies

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

# KRN-01: Kernel Armor (Strict Path Filtering and Memory Blinding)
PrintMsg "240" "Forging STIG-compliant host kernel armor..."
sudo tee /etc/sysctl.d/99-SovereignNode.conf > /dev/null << 'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
net.core.bpf_jit_harden = 2
EOF
sudo sysctl --system > /dev/null 2>&1 || true

# TIME-02: Temporal Gate (Wait for Chrony NTP Sync)
PrintMsg "240" "Locking chronometric baseline..."
sudo timedatectl set-local-rtc 0 || true
if systemctl is-active --quiet chrony || systemctl is-active --quiet chronyd; then
    PrintMsg "226" "Waiting for NTP synchronization (Required for GPG)..."
    timeout 60 bash -c 'until chronyc tracking | grep -q "Leap status     : Normal"; do sleep 2; done' || PrintMsg "196" "WARNING: NTP sync timed out."
fi

# MEM-01: Extract state memory safely
PrevEndpoint=""; PrevDomain=""; PrevEmail=""; PrevPort="51820"; PrevPeers="3"; PrevLanIp="${HUNTER_IP:-}"; PrevAcme="https://acme-staging-v02.api.letsencrypt.org/directory"
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

ExecuteAnnihilation() {
    if [ "$Interactive" -eq 1 ] && [ -d "$StackDir" ]; then
        PrintMsg "196" "========================================================================"
        PrintMsg "196" " 🔥 TRUE SCORCHED EARTH PROTOCOL"
        PrintMsg "196" "========================================================================"
        read -p "OBLITERATE EVERYTHING and restart fresh? (y/N): " input_conf || true
        if [[ "${input_conf:-}" =~ ^[Yy]$ ]]; then
            PrintMsg "196" "Executing tactical nuke..."
            cd "$StackDir" && sudo docker compose down -v --remove-orphans > /dev/null 2>&1 || true
            sudo rm -rf "$StackDir" "${ConfigDir}/Authelia" "${ConfigDir}/Postgres" "${ConfigDir}/Traefik" "${ConfigDir}/WireGuard" "${ConfigDir}/PiHole" "${ConfigDir}/Unbound"
            PrintMsg "82" "✔ Earth scorched."
        fi
    fi
}
ExecuteAnnihilation

sudo mkdir -p "$StackDir" "$LogsDir" "$ScriptsDir" "$ConfigDir/Authelia" "$ConfigDir/Postgres" "$ConfigDir/Traefik/Dynamic" "$ConfigDir/WireGuard" "$ConfigDir/PiHole/etc-pihole" "$ConfigDir/PiHole/etc-dnsmasq.d" "$ConfigDir/Unbound"
sudo chown -R 70:70 "$ConfigDir/Postgres"
sudo touch "${ConfigDir}/Traefik/acme.json"; sudo chmod 600 "${ConfigDir}/Traefik/acme.json"
sudo mkdir -p "$SecretsDir"; sudo chmod 700 "$SecretsDir"

# SEC-08: Shred Wiping (Defeat Magnetic Persistence)
WriteSecret() {
    local name=$1; local content=$2; local tmp_file="${SecretsDir}/${name}.tmp"
    printf "%s" "$content" | sudo tee "$tmp_file" > /dev/null
    sudo touch "${SecretsDir}/${name}"; sudo chmod 644 "${SecretsDir}/${name}"
    sudo sh -c "cat '$tmp_file' > '${SecretsDir}/${name}'"
    sudo shred -u "$tmp_file"
}

# SEC-09: Gated Secret Generation (Prevent database lockout)
if [ "$Interactive" -eq 1 ]; then
    [ ! -f "${SecretsDir}/cf_api_token" ] && { read -s -p "Cloudflare DNS API Token: " cf_token; echo ""; WriteSecret "cf_api_token" "$cf_token"; }
    [ ! -f "${SecretsDir}/traefik_auth" ] && { read -s -p "Traefik BasicAuth Password: " TraefikPass; echo ""; WriteSecret "traefik_auth" "admin:$(openssl passwd -apr1 "$TraefikPass")"; }
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
    
    # Proper literal newline environment generation
    sudo tee "$EnvFile" > /dev/null << EOF
WG_ENDPOINT=${WgEndpoint}
INTERNAL_DOMAIN=${InternalDomain}
ACME_EMAIL=${AcmeEmail}
ACME_SERVER_URL=${AcmeServerUrl}
WG_PORT=${WgPort}
WG_PEERS=3
TRAEFIK_LAN_IP=${TraefikLanIp}
TZ=UTC
EOF
fi

# ENV-05: Enforce Export Persistence for child processes
set -a; source "$EnvFile"; set +a

# DNS-05: Unified Lifecycle Trust Logic (Standalone PGP Helper)
RootHintUtility="${ScriptsDir}/Verify-RootHints.sh"
sudo tee "$RootHintUtility" > /dev/null << 'EOF'
#!/bin/bash
set -euo pipefail
ConfigDir="/opt/Docker/Config"
curl -sS "https://www.internic.net/domain/named.root" -o "${ConfigDir}/Unbound/RootHints.txt.tmp"
curl -sS "https://www.internic.net/domain/named.root.sig" -o "${ConfigDir}/Unbound/RootHints.txt.sig"
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 0x0BD07395 >/dev/null 2>&1 || true
if gpg --verify "${ConfigDir}/Unbound/RootHints.txt.sig" "${ConfigDir}/Unbound/RootHints.txt.tmp" 2>/dev/null; then
    mv "${ConfigDir}/Unbound/RootHints.txt.tmp" "${ConfigDir}/Unbound/RootHints.txt"
    rm -f "${ConfigDir}/Unbound/RootHints.txt.sig"
    exit 0
else
    rm -f "${ConfigDir}/Unbound/RootHints.txt.tmp" "${ConfigDir}/Unbound/RootHints.txt.sig"
    exit 1
fi
EOF
sudo chmod 700 "$RootHintUtility"

PrintMsg "240" "Verifying DNS Root Hints via GPG..."
sudo "$RootHintUtility" || { PrintMsg "196" "[FATAL] GPG Signature Failure. Supply chain compromised."; exit 1; }

sudo tee "${ConfigDir}/Unbound/UnboundConfig.conf" > /dev/null << EOF
server:
  interface: 0.0.0.0
  port: 53
  do-ip4: yes
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

# LOG-04: Host-Level Logrotate Manifest
sudo tee /etc/logrotate.d/sovereign-gateway > /dev/null << EOF
${LogsDir}/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

# Compose Manifest: Corrected Healthchecks, Native JSON Logging, Absolute Paths
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
  # DNS-06: Restored Volume for DNSSEC Key Persistence
  unbound_keys: {}

secrets:
  cf_api_token: { file: ${SecretsDir}/cf_api_token }
  postgres_password: { file: ${SecretsDir}/postgres_password }
  authelia_jwt_secret: { file: ${SecretsDir}/authelia_jwt_secret }
  authelia_session_secret: { file: ${SecretsDir}/authelia_session_secret }
  authelia_storage_key: { file: ${SecretsDir}/authelia_storage_key }
  pihole_pass: { file: ${SecretsDir}/pihole_pass }

services:
  docker_socket_proxy:
    image: lscr.io/linuxserver/socket-proxy:latest
    container_name: docker_socket_proxy
    networks: [socket_network]
    environment: [CONTAINERS=1, NETWORKS=1, VERSION=1]
    volumes: [/var/run/docker.sock:/var/run/docker.sock:ro]
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
    volumes:
      - ${ConfigDir}/Unbound/UnboundConfig.conf:/opt/unbound/etc/unbound/unbound.conf:ro
      - ${ConfigDir}/Unbound/RootHints.txt:/opt/unbound/etc/unbound/root.hints:ro
      - unbound_keys:/opt/unbound/etc/unbound/keys:rw
    healthcheck:
      # HEALTH-11: Alpine's native busybox nslookup avoids the nc/unbound-control binary voids
      test: ["CMD-SHELL", "nslookup internic.net 127.0.0.1 >/dev/null || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging: *default-logging
    restart: unless-stopped
  
  pihole_sinkhole:
    image: pihole/pihole:latest
    container_name: pihole_sinkhole
    networks:
      vpn_network: { ipv4_address: 10.99.0.12 }
      proxy_network: {}
    ports: ["0.0.0.0:53:53/tcp", "0.0.0.0:53:53/udp"]
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
    environment:
      # SEC-14: Cryptographic Identity (PUID/PGID) ensures host can read generated keys
      PUID: "1000"
      PGID: "1000"
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
    networks: [socket_network, proxy_network, vpn_network]
    ports: ["0.0.0.0:80:80", "0.0.0.0:443:443"]
    volumes:
      - ${ConfigDir}/Traefik/Dynamic:/etc/traefik/dynamic:ro
      - ${ConfigDir}/Traefik/acme.json:/acme.json:rw
    secrets: [cf_api_token]
    environment:
      CF_DNS_API_TOKEN_FILE: /run/secrets/cf_api_token
    command:
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
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

# CRON-102: Systemd Automation (Literal Newlines Restored)
sudo tee /etc/systemd/system/sovereign-updater.service > /dev/null << EOF
[Unit]
Description=Sovereign Gateway Weekly Updater
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c '${RootHintUtility} && cd ${StackDir} && docker compose pull && docker compose up -d && docker image prune -af'
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
    if docker ps --format '{{.Names}}' | grep -q "^\${alien}\$"; then
        if ! docker inspect "\$alien" --format '{{json .NetworkSettings.Networks}}' | grep -q "sovereign_gateway_proxy_network"; then
            docker network connect sovereign_gateway_proxy_network "\$alien" || true
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
cd "$StackDir" && sudo docker compose up -d --force-recreate --remove-orphans

PrintMsg "82" "✔ Matrix Online. Pi-Hole Admin: $(sudo cat ${SecretsDir}/pihole_pass)"