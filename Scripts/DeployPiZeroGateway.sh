#!/bin/bash
# ==============================================================================
#  SOVEREIGN PI ZERO GATEWAY - WIREGUARD + PI-HOLE + UNBOUND (v71.0-VANGUARD)
# ==============================================================================
#  Architecture: Centralized /opt/Docker GitOps Topology
#  Vanguard Edge-Case Fixes Applied:
#  - HEALTH-01: Reverted to `drill` for Debian-slim compatibility; local query.
#  - ENV-01: Silent extraction of WG_PORT/WG_PEERS prevents operational wipe.
#  - CRON-03: Explicit Unbound restart added to Updater to force cache drop.
# ==============================================================================

set -euo pipefail

# CRON-01: Force absolute path resolution for automated execution environments
export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

StackName="PiZeroGateway"
BaseDir="/opt/Docker/Stacks/${StackName}"
ConfigDir="/opt/Docker/Config"
SecretsDir="${ConfigDir}/Secrets"
EnvFile="${BaseDir}/Gateway.env"
ComposeFile="${BaseDir}/DockerCompose.yml"
LockFile="/var/lock/pizero_gateway.lock"

sudo mkdir -p "$BaseDir"

exec 200>"$LockFile"
flock -n 200 || { echo "[FATAL] Another deployment instance is running."; exit 1; }
[ "$EUID" -eq 0 ] || { echo "[FATAL] Elevated privileges required. Run with: sudo $0"; exit 1; }

Interactive=$([ -t 1 ] && echo 1 || echo 0)

PrintMsg() {
    local color=$1
    local msg=$2
    if command -v gum &> /dev/null; then
        gum style --foreground "$color" "$msg"
    else
        echo -e "\033[1;33m$msg\033[0m"
    fi
}

Arch=$(uname -m)
if [[ "$Arch" == "armv6l" ]]; then
    echo "[FATAL] Original Pi Zero (ARMv6) detected. Modern images drop ARMv6."
    exit 1
fi

DetectOsFamily() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=${ID:-unknown}
        OS_ID=${OS_ID,,}
        RAW_ID_LIKE=${ID_LIKE:-$OS_ID}
        OS_FAMILY=${RAW_ID_LIKE,,}
    else
        echo "[FATAL] /etc/os-release missing."
        exit 1
    fi

    if [[ "$OS_FAMILY" == *"debian"* ]] || [[ "$OS_ID" == "parrot" ]] || [[ "$OS_ID" == "ubuntu" ]]; then
        PkgManager="apt-get"
        UpdateCmd="apt-get update -y -q"
        InstallCmd="DEBIAN_FRONTEND=noninteractive apt-get install -y -q"
        UpgradeCmd="DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\""
    elif [[ "$OS_FAMILY" == *"rhel"* ]] || [[ "$OS_FAMILY" == *"fedora"* ]]; then
        PkgManager="dnf"
        UpdateCmd="dnf check-update -q || true"
        InstallCmd="dnf install -y -q"
        UpgradeCmd="dnf upgrade -y -q"
    elif [[ "$OS_FAMILY" == *"arch"* ]]; then
        PkgManager="pacman"
        UpdateCmd="pacman -Sy --noconfirm --quiet"
        InstallCmd="pacman -S --noconfirm --quiet"
        UpgradeCmd="pacman -Syu --noconfirm --quiet"
    else
        echo "[FATAL] Unsupported OS Family: $OS_FAMILY."
        exit 1
    fi
}
DetectOsFamily

if [ "$Interactive" -eq 1 ] && ! command -v gum &> /dev/null; then
    if [[ "$PkgManager" == "apt-get" ]]; then
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
        eval "$UpdateCmd" > /dev/null
        eval "$InstallCmd gum" > /dev/null
    fi
fi

if [ "$Interactive" -eq 1 ]; then
    PrintMsg "212" "Sovereign Pi Zero Ingress Forge (Vanguard Protocol)"
fi

sudo mkdir -p "$SecretsDir"
sudo chmod 700 "$SecretsDir"

WriteSecret() {
    local name=$1
    local content=$2
    local tmp_file="${SecretsDir}/${name}.tmp"
    printf "%s" "$content" | sudo tee "$tmp_file" > /dev/null
    
    # INODE-02: Preserve secret inode to prevent Docker bind-mount detachment lockouts.
    if [ ! -f "${SecretsDir}/${name}" ]; then
        sudo touch "${SecretsDir}/${name}"
        sudo chmod 600 "${SecretsDir}/${name}"
    fi
    sudo sh -c "cat '$tmp_file' > '${SecretsDir}/${name}'"
    sudo rm -f "$tmp_file"
}

if [ ! -f "${SecretsDir}/pihole_pass" ]; then
    if [ "$Interactive" -eq 1 ]; then
        PrintMsg "226" "Provide a secure password for the Pi-Hole Web Admin UI:"
        PiHolePass=""
        while [[ -z "$PiHolePass" ]]; do
            if command -v gum &> /dev/null; then
                PiHolePass=$(gum input --password)
            else
                read -s -p "Password: " PiHolePass
                echo ""
            fi
            if [[ -z "$PiHolePass" ]]; then PrintMsg "196" "Password cannot be empty."; fi
        done
        WriteSecret "pihole_pass" "$PiHolePass"
    else
        echo "[FATAL] Headless execution failed: Missing pihole_pass secret."
        exit 1
    fi
fi

if [ "$Interactive" -eq 1 ]; then
    PrevTraefikIp=$(grep "^TRAEFIK_IP=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevEndpoint=$(grep "^WG_ENDPOINT=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevDomain=$(grep "^INTERNAL_DOMAIN=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    
    # ENV-01: Silently extract and preserve operational VPN state to prevent wipe.
    PrevWgPort=$(grep "^WG_PORT=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "51820")
    PrevWgPeers=$(grep "^WG_PEERS=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "3")

    TraefikIp=""
    while [[ -z "$TraefikIp" ]]; do
        if command -v gum &> /dev/null; then
            TraefikIp=$(gum input --prompt "Dedicated Traefik Node IP: " --value "$PrevTraefikIp" --placeholder "10.0.0.50")
        else
            read -p "Dedicated Traefik Node IP [$PrevTraefikIp]: " InputIp
            TraefikIp=${InputIp:-$PrevTraefikIp}
        fi
        if [[ -z "$TraefikIp" ]]; then PrintMsg "196" "Node IP is required for internal routing."; fi
    done

    WgEndpoint=""
    while [[ -z "$WgEndpoint" ]]; do
        if command -v gum &> /dev/null; then
            WgEndpoint=$(gum input --prompt "WireGuard Public Endpoint (IP/DDNS): " --value "$PrevEndpoint" --placeholder "vpn.domain.com")
        else
            read -p "WireGuard Public Endpoint [$PrevEndpoint]: " InputWg
            WgEndpoint=${InputWg:-$PrevEndpoint}
        fi
        if [[ -z "$WgEndpoint" ]]; then PrintMsg "196" "Endpoint is required for client tunnels."; fi
    done

    InternalDomain=""
    while [[ -z "$InternalDomain" ]]; do
        if command -v gum &> /dev/null; then
            InternalDomain=$(gum input --prompt "Internal Routing Domain: " --value "$PrevDomain" --placeholder "lan.domain.com")
        else
            read -p "Internal Routing Domain [$PrevDomain]: " InputDomain
            InternalDomain=${InputDomain:-$PrevDomain}
        fi
        if [[ -z "$InternalDomain" ]]; then PrintMsg "196" "Internal Domain is required."; fi
    done

    sudo tee "$EnvFile" > /dev/null << EOF
TRAEFIK_IP=${TraefikIp}
WG_ENDPOINT=${WgEndpoint}
INTERNAL_DOMAIN=${InternalDomain}
WG_PORT=${PrevWgPort}
WG_PEERS=${PrevWgPeers}
TZ=UTC
EOF
    sudo chmod 600 "$EnvFile"
fi

source "$EnvFile"

sudo timedatectl set-timezone UTC
sudo rm -f /etc/localtime && sudo ln -s /usr/share/zoneinfo/UTC /etc/localtime
if systemctl is-active --quiet systemd-timesyncd; then
    sudo systemctl restart systemd-timesyncd
elif systemctl is-active --quiet chronyd; then
    sudo systemctl restart chronyd
fi

if [ "$Interactive" -eq 1 ] && command -v docker &> /dev/null; then
    AlienContainers=$(sudo docker ps -a --format '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' -v stack="${StackName,,}" 'tolower($3) != stack {print $1 " (" $2 ")"}')
    if [ -n "$AlienContainers" ]; then
        PrintMsg "196" "Executing Scorched Earth on rogue containers."
        echo "$AlienContainers" | awk '{print $1}' | xargs -I {} sudo docker rm -f {} >/dev/null 2>&1 || true
    fi
fi

UpdaterScript="/opt/Docker/Scripts/Update${StackName}.sh"
sudo tee "$UpdaterScript" > /dev/null << EOF
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"
${UpdateCmd}
${UpgradeCmd}
/opt/Docker/Scripts/Deploy${StackName}.sh
# CRON-03: Hard restart Unbound to flush RAM cache and ingest updated Root Hints
cd /opt/Docker/Stacks/${StackName} && sudo docker compose restart UnboundDns
EOF
sudo chmod 700 "$UpdaterScript"

CronFile="/etc/cron.d/sovereign_updates"
sudo tee "$CronFile" > /dev/null << EOF
0 3 * * 0 root $UpdaterScript > /var/log/sovereign_updates.log 2>&1
EOF
sudo chmod 644 "$CronFile"

SysctlConf="/etc/sysctl.d/99-vpn-gateway.conf"
sudo tee "$SysctlConf" > /dev/null << EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sudo sysctl -p "$SysctlConf" > /dev/null 2>&1 || true

# KERNEL-01: Safely test for dynamic module OR statically compiled capability.
if sudo modinfo wireguard >/dev/null 2>&1 || [ -d /sys/module/wireguard ]; then
    sudo modprobe wireguard 2>/dev/null || true
    echo "wireguard" | sudo tee /etc/modules-load.d/wireguard.conf > /dev/null
elif sudo ip link add dev wg999 type wireguard 2>/dev/null; then
    sudo ip link del dev wg999 2>/dev/null || true
    if [ "$Interactive" -eq 1 ]; then PrintMsg "82" "[INFO] WireGuard is statically compiled. Bypassing modprobe."; fi
else
    PrintMsg "196" "[FATAL] Host kernel lacks wireguard capability. Refusing userspace fallback."
    exit 1
fi

UnboundDir="${ConfigDir}/Unbound"
sudo mkdir -p "${UnboundDir}"

# CRON-02: Soft fail logic to preserve cached root hints if WAN drops during 3AM cron run.
if curl --connect-timeout 10 -sSL "https://www.internic.net/domain/named.root" -o "${UnboundDir}/RootHints.tmp"; then
    if grep -q "A.ROOT-SERVERS.NET" "${UnboundDir}/RootHints.tmp"; then
        sudo touch "${UnboundDir}/RootHints.txt"
        sudo sh -c "cat '${UnboundDir}/RootHints.tmp' > '${UnboundDir}/RootHints.txt'"
        sudo rm -f "${UnboundDir}/RootHints.tmp"
    else
        PrintMsg "196" "[WARNING] Root hints integrity check failed. Retaining cached file."
        sudo rm -f "${UnboundDir}/RootHints.tmp"
    fi
else
    PrintMsg "196" "[WARNING] Failed to download root hints. Network offline? Retaining cached file."
    sudo rm -f "${UnboundDir}/RootHints.tmp" || true
fi

if [ ! -f "${UnboundDir}/RootHints.txt" ]; then
    sudo touch "${UnboundDir}/RootHints.txt"
fi

sudo tee "${UnboundDir}/UnboundConfig.conf" > /dev/null << EOF
server:
    verbosity: 0
    interface: 0.0.0.0
    port: 53
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: no
    chroot: ""
    pidfile: "/opt/unbound/var/run/unbound.pid"
    root-hints: "/opt/unbound/etc/unbound/root.hints"
    auto-trust-anchor-file: "/opt/unbound/etc/unbound/keys/root.key"
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    edns-buffer-size: 1232
    prefetch: yes
    num-threads: 1
    hide-identity: yes
    hide-version: yes
    access-control: 127.0.0.0/8 allow
    access-control: 10.99.0.0/24 allow
    local-zone: "${INTERNAL_DOMAIN}" redirect
    local-data: "${INTERNAL_DOMAIN} A ${TRAEFIK_IP}"
EOF

ResolveImage() {
    local img=$1
    sudo docker pull "$img" >/dev/null 2>&1
    local digest=$(sudo docker inspect --format='{{index .RepoDigests 0}}' "$img" 2>/dev/null || echo "")
    if [[ -z "$digest" ]]; then echo "[FATAL] Failed to resolve SHA256 for $img."; exit 1; fi
    echo "$digest"
}

IMG_WG=$(ResolveImage "lscr.io/linuxserver/wireguard:latest")
IMG_PIHOLE=$(ResolveImage "pihole/pihole:latest")
IMG_UNBOUND=$(ResolveImage "mvance/unbound:latest")

sudo mkdir -p "${ConfigDir}/WireGuard" "${ConfigDir}/PiHole/etc-pihole" "${ConfigDir}/PiHole/etc-dnsmasq.d"

sudo tee "$ComposeFile" > /dev/null << EOF
networks:
  VpnNetwork:
    name: VpnNetwork
    ipam:
      config:
        - subnet: 10.99.0.0/24

services:
  WireGuard:
    image: ${IMG_WG}
    container_name: WireGuard
    networks:
      VpnNetwork:
        ipv4_address: 10.99.0.10
    cap_drop:
      - ALL
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - CHOWN
      - SETUID
      - SETGID
      - KILL
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
      - SERVERURL=\${WG_ENDPOINT}
      - SERVERPORT=\${WG_PORT}
      - PEERS=\${WG_PEERS}
      - PEERDNS=10.99.0.12
      - INTERNAL_SUBNET=10.13.13.0
      - ALLOWEDIPS=0.0.0.0/0
      - LOG_CONFS=false
    volumes:
      - ${ConfigDir}/WireGuard:/config
      - /lib/modules:/lib/modules:ro
    ports:
      - "0.0.0.0:\${WG_PORT}:51820/udp"
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped

  DnsSinkhole:
    image: ${IMG_PIHOLE}
    container_name: PiHole
    networks:
      VpnNetwork:
        ipv4_address: 10.99.0.12
    environment:
      - TZ=UTC
      - WEBPASSWORD_FILE=/run/secrets/pihole_pass
      - PIHOLE_DNS_=10.99.0.11#53
      - DNSSEC=true
      - DNS_BOGUS_PRIV=true
      - DNS_FQDN_REQUIRED=true
      - REV_SERVER=false
      - QUERY_LOGGING=false
      - PRIVACY_LEVEL=3
    volumes:
      - ${SecretsDir}/pihole_pass:/run/secrets/pihole_pass:ro
      - ${ConfigDir}/PiHole/etc-pihole:/etc/pihole
      - ${ConfigDir}/PiHole/etc-dnsmasq.d:/etc/dnsmasq.d
    ports:
      - "127.0.0.1:8080:80/tcp"
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - NET_RAW
      - CHOWN
      - SETUID
      - SETGID
      - KILL
    depends_on:
      RecursiveDns:
        condition: service_healthy
    restart: unless-stopped

  RecursiveDns:
    image: ${IMG_UNBOUND}
    container_name: UnboundDns
    networks:
      VpnNetwork:
        ipv4_address: 10.99.0.11
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - SETUID
      - SETGID
      - CHOWN
      - KILL
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /opt/unbound/var/run
      - /opt/unbound/etc/unbound/keys
    volumes:
      - ${ConfigDir}/Unbound/RootHints.txt:/opt/unbound/etc/unbound/root.hints:ro
      - ${ConfigDir}/Unbound/UnboundConfig.conf:/opt/unbound/etc/unbound/unbound.conf:ro
    entrypoint: ["/bin/sh", "-c", "unbound-anchor -a /opt/unbound/etc/unbound/keys/root.key || touch /opt/unbound/etc/unbound/keys/root.key; chown -R _unbound:_unbound /opt/unbound/etc/unbound/keys /opt/unbound/var/run 2>/dev/null || chown -R unbound:unbound /opt/unbound/etc/unbound/keys /opt/unbound/var/run 2>/dev/null || true; exec /opt/unbound/sbin/unbound -d -c /opt/unbound/etc/unbound/unbound.conf"]
    healthcheck:
      # HEALTH-01: Corrected to `drill` with valid `@` nameserver syntax to survive slim-image tooling.
      test: ["CMD-SHELL", "drill \${INTERNAL_DOMAIN} @127.0.0.1 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s
    restart: unless-stopped
EOF

sudo chown 0:0 "$ComposeFile"
sudo chmod 600 "$ComposeFile"

if [ "$Interactive" -eq 0 ]; then
    cd "$BaseDir" && sudo docker compose --env-file Gateway.env up -d --remove-orphans
elif [ "$Interactive" -eq 1 ]; then
    PrintMsg "82" "✔ Perimeter Staged."
fi
exit 0