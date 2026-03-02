#!/bin/bash
# ==============================================================================
#  SOVEREIGN TRAEFIK CORE - ZERO-TRUST REVERSE PROXY (v57.0-GITEA-READY)
# ==============================================================================
#  Architecture: Centralized /opt/Docker GitOps Topology
#  Compliance: ACME atomic swap mounts, dynamic absolute volume pathing.
# ==============================================================================

set -euo pipefail

StackName="TraefikMonolith"
BaseDir="/opt/Docker/Stacks/${StackName}"
ConfigDir="/opt/Docker/Config"
SecretsDir="${ConfigDir}/Secrets"
LogsDir="/opt/Docker/Logs/${StackName}"
EnvFile="${BaseDir}/Traefik.env"
ComposeFile="${BaseDir}/DockerCompose.yml"
LockFile="/var/lock/traefik_core.lock"

sudo mkdir -p "$BaseDir" "$LogsDir"

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

sudo mkdir -p "$SecretsDir"
sudo chmod 700 "$SecretsDir"

WriteSecret() {
    local name=$1
    local content=$2
    local tmp_file="${SecretsDir}/${name}.tmp"
    printf "%s" "$content" | sudo tee "$tmp_file" > /dev/null
    sudo chmod 600 "$tmp_file"
    sudo mv "$tmp_file" "${SecretsDir}/${name}"
}

if [ ! -f "${SecretsDir}/cf_api_key" ]; then
    if [ "$Interactive" -eq 1 ]; then
        PrintMsg "226" "Provide Cloudflare Global API Key for DNS-01 ACME Challenges:"
        CfToken=$(gum input --password 2>/dev/null || read -s -p "API Key: " key && echo "$key")
        WriteSecret "cf_api_key" "$CfToken"
    else
        echo "[FATAL] Headless execution failed: Missing cf_api_key secret."
        exit 1
    fi
fi

if [ "$Interactive" -eq 1 ]; then
    PrevPiZeroIp=$(grep "^PI_ZERO_IP=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevEmail=$(grep "^ACME_EMAIL=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")

    if command -v gum &> /dev/null; then
        PiZeroIp=$(gum input --prompt "Pi Zero (VPN Gateway) LAN IP: " --value "$PrevPiZeroIp" --placeholder "10.0.0.40")
        AcmeEmail=$(gum input --prompt "Let's Encrypt Email: " --value "$PrevEmail" --placeholder "admin@domain.com")
    else
        read -p "Pi Zero (VPN Gateway) LAN IP [$PrevPiZeroIp]: " PiZeroIp
        PiZeroIp=${PiZeroIp:-$PrevPiZeroIp}
        read -p "Let's Encrypt Email [$PrevEmail]: " AcmeEmail
        AcmeEmail=${AcmeEmail:-$PrevEmail}
    fi

    sudo tee "$EnvFile" > /dev/null << EOF
PI_ZERO_IP=${PiZeroIp}
ACME_EMAIL=${AcmeEmail}
CF_API_EMAIL=${AcmeEmail}
TZ=UTC
EOF
    sudo chmod 600 "$EnvFile"
else
    source "$EnvFile"
fi

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

CronFile="/etc/cron.d/sovereign_updates"
if [ ! -f "$CronFile" ]; then
    CronExpr="0 3 * * 0 root $UpdateCmd && $UpgradeCmd && /opt/Docker/Scripts/Deploy${StackName}.sh > /var/log/sovereign_updates.log 2>&1"
    echo "$CronExpr" | sudo tee "$CronFile" > /dev/null
    sudo chmod 644 "$CronFile"
fi

SysctlConf="/etc/sysctl.d/99-traefik-core.conf"
sudo tee "$SysctlConf" > /dev/null << EOF
net.core.default_qdisc = fq
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.tcp_syncookies = 1
fs.file-max = 2097152
EOF

if lsmod | grep -q "tcp_bbr" || sudo modprobe tcp_bbr 2>/dev/null; then
    echo "net.ipv4.tcp_congestion_control = bbr" | sudo tee -a "$SysctlConf" > /dev/null
else
    PrintMsg "196" "[WARNING] tcp_bbr module missing. BBR routing bypassed."
fi
sudo sysctl -p "$SysctlConf" > /dev/null 2>&1 || true

TraefikDir="${ConfigDir}/Traefik"
TraefikAcmeDir="${ConfigDir}/TraefikAcme"
sudo mkdir -p "${TraefikDir}" "${TraefikAcmeDir}"
sudo touch "${LogsDir}/access.log"

sudo chmod 700 "${TraefikAcmeDir}"

sudo tee "${TraefikDir}/DynamicRules.yml" > /dev/null << EOF
http:
  middlewares:
    secure-headers:
      headers:
        accessControlAllowMethods: ["GET", "OPTIONS", "PUT"]
        accessControlMaxAge: 100
        hostsProxyHeaders: ["X-Forwarded-Host"]
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true
        forceSTSHeader: true
        customFrameOptionsValue: "SAMEORIGIN"
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "strict-origin-when-cross-origin"
EOF

ResolveImage() {
    local img=$1
    sudo docker pull "$img" >/dev/null 2>&1
    local digest=$(sudo docker inspect --format='{{index .RepoDigests 0}}' "$img" 2>/dev/null || echo "")
    if [[ -z "$digest" ]]; then echo "[FATAL] Failed to resolve SHA256 for $img."; exit 1; fi
    echo "$digest"
}

IMG_SOCKET=$(ResolveImage "lscr.io/linuxserver/socket-proxy:latest")
IMG_TRAEFIK=$(ResolveImage "traefik:latest")

sudo tee "$ComposeFile" > /dev/null << EOF
networks:
  ProxyNetwork:
    name: ProxyNetwork
    attachable: true
    ipam:
      config:
        - subnet: 10.50.0.0/24
  SocketNetwork:
    name: SocketNetwork
    internal: true

secrets:
  cf_api_key:
    file: ${SecretsDir}/cf_api_key

services:
  DockerSocketProxy:
    image: ${IMG_SOCKET}
    container_name: DockerSocketProxy
    networks:
      - SocketNetwork
    environment:
      - CONTAINERS=1
      - IMAGES=1
      - NETWORKS=1
      - VOLUMES=1
      - POST=0
      - DELETE=0
      - AUTH=0
      - SECRETS=0
      - EXEC=0
      - TZ=UTC
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    tmpfs:
      - /run
      - /tmp
    read_only: true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped

  TraefikCore:
    image: ${IMG_TRAEFIK}
    container_name: TraefikCore
    networks:
      - ProxyNetwork
      - SocketNetwork
    ports:
      - "80:80/tcp"
      - "443:443/tcp"
    environment:
      - CF_API_EMAIL=\${CF_API_EMAIL}
      - CF_API_KEY_FILE=/run/secrets/cf_api_key
      - TZ=UTC
    secrets:
      - cf_api_key
    volumes:
      - ${ConfigDir}/TraefikAcme:/etc/traefik/acme
      - ${ConfigDir}/Traefik/DynamicRules.yml:/etc/traefik/dynamic_rules.yml:ro
      - ${LogsDir}:/var/log/traefik
    tmpfs:
      - /tmp
    command:
      - "--global.checkNewVersion=false"
      - "--global.sendAnonymousUsage=false"
      - "--api.dashboard=false"
      - "--providers.docker=true"
      - "--providers.docker.endpoint=tcp://DockerSocketProxy:2375"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.file.filename=/etc/traefik/dynamic_rules.yml"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.middlewares=secure-headers@file"
      - "--entrypoints.websecure.http.middlewares=secure-headers@file"
      - "--entrypoints.websecure.forwardedHeaders.trustedIPs=\${PI_ZERO_IP}/32,10.13.13.0/24,10.50.0.0/24"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge=true"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare"
      - "--certificatesresolvers.cloudflare.acme.email=\${ACME_EMAIL}"
      - "--certificatesresolvers.cloudflare.acme.storage=/etc/traefik/acme/acme.json"
      - "--accesslog=true"
      - "--accesslog.filepath=/var/log/traefik/access.log"
      - "--accesslog.format=json"
    read_only: true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    security_opt:
      - no-new-privileges:true
    depends_on:
      - DockerSocketProxy
    restart: unless-stopped
EOF

sudo chown 0:0 "$ComposeFile"
sudo chmod 600 "$ComposeFile"

if [ "$Interactive" -eq 0 ]; then
    cd "$BaseDir" && sudo docker compose --env-file Traefik.env up -d --remove-orphans
elif [ "$Interactive" -eq 1 ]; then
    PrintMsg "82" "✔ Traefik Core Staged."
fi
exit 0