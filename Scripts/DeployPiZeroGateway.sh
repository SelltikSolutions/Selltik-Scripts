#!/bin/bash
# ==============================================================================
#  SOVEREIGN PI ZERO GATEWAY - WIREGUARD + PI-HOLE + UNBOUND (v79.1-ABSOLUTE)
# ==============================================================================
#  Architecture: Centralized /opt/Docker GitOps Topology
#  Absolute Edge-Case Fixes Applied:
#  - ARCH-01: Verbose ARMv6 architectural deprecation warning implemented.
#  - LOG-01: Strict 10m/3-file rotation bolted to all services to prevent SD card death.
#  - STATE-02: Cryptographic fallback insulated to prevent truncation of RFC 5011 keys.
#  - SYNC-01: Administrative lockout defused via conditional post-deployment daemon restart.
#  - BOOT-04: Insulated PPA curl pipeline prevents set -e suicide during Day Zero offline deploy.
#  - BOOT-05: Hardcoded Root Hint A-Record injected to prevent Unbound 0-byte syntax crash.
#  - CRON-06: UpdaterScript atomic swap (.tmp to mv) prevents bash pointer decapitation.
#  - APT-01: UpdateCmd insulated (|| true) to prevent 3rd-party PPA set -e suicide.
#  - LOCK-01: Thermal buffer and restart enveloped in strict flock to prevent human race conditions.
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

# Primary Deployment Lock
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

# ARCH-01: Explicitly define the architectural limitation. Refuse to deploy legacy CVEs.
Arch=$(uname -m)
if [[ "$Arch" == "armv6l" ]]; then
    PrintMsg "196" "========================================================================"
    PrintMsg "196" "[FATAL ARCHITECTURE ERROR] Broadcom BCM2835 (ARMv6) Detected."
    PrintMsg "196" "========================================================================"
    PrintMsg "196" "You are attempting to deploy a Tier-3 Hardened Gateway on an original"
    PrintMsg "196" "Raspberry Pi 1 or Pi Zero 1. The Docker ecosystem (Alpine, LinuxServer,"
    PrintMsg "196" "Pi-Hole) universally deprecated 32-bit ARMv6 support years ago."
    PrintMsg "196" ""
    PrintMsg "196" "If this block is bypassed, modern images will trigger an unrecoverable"
    PrintMsg "196" "kernel 'exec format error' and permanently crash the containers."
    PrintMsg "196" "Downgrading to unsupported 2021 legacy images introduces hundreds of"
    PrintMsg "196" "unpatched vulnerabilities, violating strict Zero-Trust mandates."
    PrintMsg "196" ""
    PrintMsg "226" "==> ACTION REQUIRED: Upgrade to a Raspberry Pi Zero 2 W (ARMv8/aarch64)"
    PrintMsg "226" "                     or a standard Raspberry Pi 4/5."
    PrintMsg "196" "========================================================================"
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

# BOOT-04: Insulated UI dependency pipeline. Prevents fatal pipeline crashes if DNS is missing on Day Zero.
if [ "$Interactive" -eq 1 ] && ! command -v gum &> /dev/null; then
    if [[ "$PkgManager" == "apt-get" ]]; then
        sudo mkdir -p /etc/apt/keyrings
        curl --connect-timeout 5 -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg || true
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
        eval "$UpdateCmd" > /dev/null || true
        eval "$InstallCmd gum" > /dev/null || true
    fi
fi

if [ "$Interactive" -eq 1 ]; then
    PrintMsg "212" "Sovereign Pi Zero Ingress Forge (Absolute Protocol)"
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

# SEC-01: Break administrative lock-in by safely prompting for credential rotation.
RotateSecret=0
if [ -f "${SecretsDir}/pihole_pass" ]; then
    if [ "$Interactive" -eq 1 ]; then
        if command -v gum &> /dev/null; then
            gum confirm "Existing Pi-Hole secret found. Rotate credentials?" && RotateSecret=1 || RotateSecret=0
        else
            read -p "[INFO] Existing Pi-Hole secret found. Rotate credentials? [y/N]: " ConfirmRotate || echo ""
            if [[ "${ConfirmRotate,,}" == "y" ]]; then RotateSecret=1; fi
        fi
    fi
else
    RotateSecret=1
fi

if [ "$RotateSecret" -eq 1 ]; then
    if [ "$Interactive" -eq 1 ]; then
        PrintMsg "226" "Provide a secure password for the Pi-Hole Web Admin UI:"
        PiHolePass=""
        while [[ -z "$PiHolePass" ]]; do
            # UI-01: Append || echo "" to safely absorb ESC inputs without aborting the script.
            if command -v gum &> /dev/null; then
                PiHolePass=$(gum input --password || echo "")
            else
                read -s -p "Password: " PiHolePass || echo ""
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
            TraefikIp=$(gum input --prompt "Dedicated Traefik Node IP: " --value "$PrevTraefikIp" --placeholder "10.0.0.50" || echo "")
        else
            read -p "Dedicated Traefik Node IP [$PrevTraefikIp]: " InputIp || echo ""
            TraefikIp=${InputIp:-$PrevTraefikIp}
        fi
        if [[ -z "$TraefikIp" ]]; then PrintMsg "196" "Node IP is required for internal routing."; fi
    done

    WgEndpoint=""
    while [[ -z "$WgEndpoint" ]]; do
        if command -v gum &> /dev/null; then
            WgEndpoint=$(gum input --prompt "WireGuard Public Endpoint (IP/DDNS): " --value "$PrevEndpoint" --placeholder "vpn.domain.com" || echo "")
        else
            read -p "WireGuard Public Endpoint [$PrevEndpoint]: " InputWg || echo ""
            WgEndpoint=${InputWg:-$PrevEndpoint}
        fi
        if [[ -z "$WgEndpoint" ]]; then PrintMsg "196" "Endpoint is required for client tunnels."; fi
    done

    InternalDomain=""
    while [[ -z "$InternalDomain" ]]; do
        if command -v gum &> /dev/null; then
            InternalDomain=$(gum input --prompt "Internal Routing Domain: " --value "$PrevDomain" --placeholder "lan.domain.com" || echo "")
        else
            read -p "Internal Routing Domain [$PrevDomain]: " InputDomain || echo ""
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

# CRON-06: Write to .tmp and use atomic swap to prevent bash in-place truncation decapitation.
sudo tee "${UpdaterScript}.tmp" > /dev/null << EOF
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

# APT-01: Insulate updates to prevent 3rd-party PPA failures from triggering set -e suicide.
${UpdateCmd} || true
${UpgradeCmd} || true

/opt/Docker/Scripts/Deploy${StackName}.sh

# LOCK-01: Encapsulate post-deployment buffer and restart inside the strict deployment lock.
(
    flock -w 60 200
    # CRON-04: Thermal buffer injection. Prevents single-core CPU socket exhaustion after stack evaluation.
    sleep 10
    # CRON-03: Hard restart Unbound to flush RAM cache and ingest updated Root Hints.
    cd /opt/Docker/Stacks/${StackName} && sudo docker compose restart UnboundDns
) 200>"/var/lock/pizero_gateway.lock"
EOF

sudo chmod 700 "${UpdaterScript}.tmp"
sudo mv "${UpdaterScript}.tmp" "${UpdaterScript}"

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

# KERNEL-01, KERNEL-02, KERNEL-03: Test module availability, exact unescaped variables, and persistently stage Netfilter.
if sudo modinfo wireguard >/dev/null 2>&1 || [ -d /sys/module/wireguard ]; then
    for mod in wireguard iptable_nat iptable_mangle ip_tables; do
        sudo modprobe "$mod" 2>/dev/null || true
    done
    sudo tee /etc/modules-load.d/wireguard.conf > /dev/null << MODEOF
wireguard
iptable_nat
iptable_mangle
ip_tables
MODEOF
elif sudo ip link add dev wg999 type wireguard 2>/dev/null; then
    sudo ip link del dev wg999 2>/dev/null || true
    if [ "$Interactive" -eq 1 ]; then PrintMsg "82" "[INFO] WireGuard is statically compiled. Bypassing modprobe."; fi
    for mod in iptable_nat iptable_mangle ip_tables; do
        sudo modprobe "$mod" 2>/dev/null || true
    done
    sudo tee /etc/modules-load.d/wireguard.conf > /dev/null << MODEOF
iptable_nat
iptable_mangle
ip_tables
MODEOF
else
    PrintMsg "196" "[FATAL] Host kernel lacks wireguard capability. Refusing userspace fallback."
    exit 1
fi

UnboundDir="${ConfigDir}/Unbound"
UnboundKeysDir="${UnboundDir}/Keys"
sudo mkdir -p "${UnboundDir}" "${UnboundKeysDir}"
sudo chmod 755 "${UnboundKeysDir}"

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

# BOOT-05: Check if file is 0-bytes or missing. Inject hardcoded fallback to prevent fatal syntax crash.
if [ ! -s "${UnboundDir}/RootHints.txt" ]; then
    sudo tee "${UnboundDir}/RootHints.txt" > /dev/null << EOF
. 3600000 IN NS A.ROOT-SERVERS.NET.
A.ROOT-SERVERS.NET. 3600000 A 198.41.0.4
EOF
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
      # PROXY-01: Explicitly pin to IPv4 to prevent docker-proxy EAFNOSUPPORT crash on GRUB-hardened hosts.
      - "0.0.0.0:\${WG_PORT}:51820/udp"
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    # LOG-01: Clamped JSON logging to prevent SD card exhaustion and NAND flash burn-in.
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
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
      # CPU-01: Redundant validation disabled. Unbound acts as the singular cryptographic perimeter.
      - DNSSEC=false
      - DNS_BOGUS_PRIV=true
      - DNS_FQDN_REQUIRED=true
      - REV_SERVER=false
      - QUERY_LOGGING=false
      - PRIVACY_LEVEL=3
      # ROUTE-01: Bridge WG client subnets (10.13.13.0/24) to Pi-Hole so FTL engine doesn't drop requests.
      - DNSMASQ_LISTENING=all
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
    # LOG-01: Clamped JSON logging to prevent SD card exhaustion and NAND flash burn-in.
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
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
    volumes:
      - ${ConfigDir}/Unbound/RootHints.txt:/opt/unbound/etc/unbound/root.hints:ro
      - ${ConfigDir}/Unbound/UnboundConfig.conf:/opt/unbound/etc/unbound/unbound.conf:ro
      # STATE-01: Persistently bound to host. Survives weekly cron restarts to fulfill RFC 5011 rollovers.
      - ${ConfigDir}/Unbound/Keys:/opt/unbound/etc/unbound/keys:rw
    # STATE-02/BOOT-03: Hardcoded IANA DS string fallback safely checks for file size before overwriting RFC 5011 state.
    entrypoint: ["/bin/sh", "-c", "unbound-anchor -a /opt/unbound/etc/unbound/keys/root.key || if [ ! -s /opt/unbound/etc/unbound/keys/root.key ]; then echo '. IN DS 20326 8 2 e06d44b80b8f1d39a95c0b0d7c65d08458e880409bbc683457104237c7f8ec8d' > /opt/unbound/etc/unbound/keys/root.key; fi; chown -R _unbound:_unbound /opt/unbound/etc/unbound/keys /opt/unbound/var/run 2>/dev/null || chown -R unbound:unbound /opt/unbound/etc/unbound/keys /opt/unbound/var/run 2>/dev/null || true; exec /opt/unbound/sbin/unbound -d -c /opt/unbound/etc/unbound/unbound.conf"]
    healthcheck:
      test: ["CMD-SHELL", "drill \${INTERNAL_DOMAIN} @127.0.0.1 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s
    # LOG-01: Clamped JSON logging to prevent SD card exhaustion and NAND flash burn-in.
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped
EOF

sudo chown 0:0 "$ComposeFile"
sudo chmod 600 "$ComposeFile"

# SYNC-01: Handle Daemon Lifecycle Synchronization Post-Deployment
if [ "$Interactive" -eq 0 ]; then
    cd "$BaseDir" && sudo docker compose --env-file Gateway.env up -d --remove-orphans
    if [ "$RotateSecret" -eq 1 ]; then
        sudo docker compose restart DnsSinkhole
    fi
elif [ "$Interactive" -eq 1 ]; then
    PrintMsg "82" "✔ Perimeter Staged."
    if [ "$RotateSecret" -eq 1 ]; then
        PrintMsg "196" "[WARNING] Cryptographic hash rotated. To flush the Pi-Hole state engine, execute:"
        PrintMsg "196" "cd ${BaseDir} && sudo docker compose restart DnsSinkhole"
    fi
fi
exit 0