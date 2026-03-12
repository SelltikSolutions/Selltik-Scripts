#!/bin/bash
# ==============================================================================
#  SOVEREIGN TRAEFIK CORE - ZERO-TRUST REVERSE PROXY (v62.2-TTY-REMEDIATION)
# ==============================================================================
#  Architecture: Centralized /opt/Docker GitOps Topology
#  TTY Fixes Applied:
#  - BOOT-06: Interactive check shifted from stdout (-t 1) to stdin (-t 0) to 
#             prevent false headless aborts during chained sudo executions.
#  Routing Protocol Applied:
#  - ROUTE-11: Drone C2 telemetry amputated in favor of explicit Static File 
#              Providers. This prevents the Docker Subnet LAN gap paradox.
#  - AUTH-02: Cryptographic BasicAuth secret injected for satellite node protection.
#  Dependency Fixes Applied:
#  - DEP-01: CheckDependencies function injected.
#  Resilience Fixes Applied:
#  - CRON-06: UpdaterScript atomic swap (.tmp to mv) prevents bash decapitation.
#  - APT-01: UpdateCmd insulated (|| true).
#  Encapsulation Fixes Applied:
#  - SEC-04: Pre-populated .gitignore injected into SecretsDir.
#  - SEC-05: Abstracted SecretsDir from ConfigDir to prevent GitOps leakage.
#  Audit Fixes Applied:
#  - TRAEFIK-02: Restored v2.11 API determinism.
#  - SAFETY-01: Scorched Earth protocol bolted with interactive confirmation.
#  - ACME-01: Let's Encrypt staging API trap removed.
# ==============================================================================

set -euo pipefail

StackName="TraefikMonolith"
BaseDir="/opt/Docker/Stacks/${StackName}"
ConfigDir="${BaseDir}/Config"
SecretsDir="${BaseDir}/Secrets"
LogsDir="/opt/Docker/Logs/${StackName}"
EnvFile="${BaseDir}/Traefik.env"
ComposeFile="${BaseDir}/DockerCompose.yml"
LockFile="/var/lock/traefik_core.lock"

sudo mkdir -p "$BaseDir" "$LogsDir"

exec 200>"$LockFile"
flock -n 200 || { echo "[FATAL] Another deployment instance is running."; exit 1; }
[ "$EUID" -eq 0 ] || { echo "[FATAL] Elevated privileges required. Run with: sudo $0"; exit 1; }

# BOOT-06: Check Standard Input (0) for an active terminal, not Output (1).
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

CheckDependencies() {
    PrintMsg "240" "Verifying baseline dependencies for $OS_ID ($OS_FAMILY)..."
    eval "$UpdateCmd" > /dev/null 2>&1 || true
    
    local deps="curl jq openssl cron tzdata"
    [[ "$PkgManager" == "apt-get" ]] && deps="$deps apparmor-utils"
    [[ "$PkgManager" == "dnf" ]] && deps="$deps cronie"
    
    for dep in $deps; do
        if ! command -v "$dep" &> /dev/null && ! dpkg -l | grep -q "^ii  $dep" 2>/dev/null && ! rpm -q "$dep" &>/dev/null; then
            PrintMsg "226" "Installing missing dependency: $dep"
            eval "$InstallCmd $dep" > /dev/null || true
        fi
    done

    if ! command -v gum &> /dev/null; then
        PrintMsg "226" "Installing Charmbracelet Gum for secure prompts..."
        if [[ "$PkgManager" == "apt-get" ]]; then
            sudo mkdir -p /etc/apt/keyrings
            curl --connect-timeout 5 -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg || true
            echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
            eval "$UpdateCmd" > /dev/null || true
            eval "$InstallCmd gum" > /dev/null || true
        elif [[ "$PkgManager" == "dnf" ]]; then
            echo '[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo > /dev/null
            eval "$InstallCmd gum" > /dev/null || true
        else
            PrintMsg "196" "[WARNING] Gum UI not available. Falling back to basic prompts."
        fi
    fi
}

DetectOsFamily
CheckDependencies

if [ -d "${ConfigDir}/Secrets" ] && [ ! -d "${SecretsDir}" ]; then
    sudo mv "${ConfigDir}/Secrets" "${SecretsDir}"
elif [ -d "${ConfigDir}/Secrets" ]; then
    sudo cp -a "${ConfigDir}/Secrets/"* "${SecretsDir}/" 2>/dev/null || true
    sudo rm -rf "${ConfigDir}/Secrets"
fi

sudo mkdir -p "$SecretsDir"
sudo chmod 700 "$SecretsDir"

echo "*" | sudo tee "${SecretsDir}/.gitignore" > /dev/null
sudo chmod 600 "${SecretsDir}/.gitignore"

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
        CfToken=""
        while [[ -z "$CfToken" ]]; do
            if command -v gum &> /dev/null; then
                CfToken=$(gum input --password)
            else
                read -s -p "API Key: " CfToken
                echo ""
            fi
            if [[ -z "$CfToken" ]]; then PrintMsg "196" "API Key cannot be empty."; fi
        done
        WriteSecret "cf_api_key" "$CfToken"
    else
        echo "[FATAL] Headless execution failed: Missing cf_api_key secret."
        exit 1
    fi
fi

# AUTH-02: Generate Cryptographic Password for Remote Satellite services
if [ ! -f "${SecretsDir}/traefik_auth" ]; then
    if [ "$Interactive" -eq 1 ]; then
        PrintMsg "226" "Provide a secure password for the Satellite Auth Wall:"
        TraefikPass=""
        while [[ -z "$TraefikPass" ]]; do
            if command -v gum &> /dev/null; then
                TraefikPass=$(gum input --password)
            else
                read -s -p "Satellite Auth Password: " TraefikPass
                echo ""
            fi
            if [[ -z "$TraefikPass" ]]; then PrintMsg "196" "Password cannot be empty."; fi
        done
        TraefikHash="admin:$(openssl passwd -apr1 "$TraefikPass")"
        WriteSecret "traefik_auth" "$TraefikHash"
    else
        echo "[FATAL] Headless execution failed: Missing traefik_auth secret."
        exit 1
    fi
fi

if [ "$Interactive" -eq 1 ]; then
    PrevVpnGwIp=$(grep "^VPN_GATEWAY_IP=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevEmail=$(grep "^ACME_EMAIL=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevDomain=$(grep "^INTERNAL_DOMAIN=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")

    VpnGwIp=""
    while [[ -z "$VpnGwIp" ]]; do
        if command -v gum &> /dev/null; then
            VpnGwIp=$(gum input --prompt "Edge VPN Gateway LAN IP: " --value "$PrevVpnGwIp" --placeholder "10.0.0.40")
        else
            read -p "Edge VPN Gateway LAN IP [$PrevVpnGwIp]: " InputIp
            VpnGwIp=${InputIp:-$PrevVpnGwIp}
        fi
        if [[ -z "$VpnGwIp" ]]; then PrintMsg "196" "[FATAL] VPN Gateway IP is required. Leaving this blank will crash Traefik."; fi
    done

    AcmeEmail=""
    while [[ -z "$AcmeEmail" ]]; do
        if command -v gum &> /dev/null; then
            AcmeEmail=$(gum input --prompt "Let's Encrypt Email: " --value "$PrevEmail" --placeholder "admin@domain.com")
        else
            read -p "Let's Encrypt Email [$PrevEmail]: " InputEmail
            AcmeEmail=${InputEmail:-$PrevEmail}
        fi
        if [[ -z "$AcmeEmail" ]]; then PrintMsg "196" "[FATAL] Notification email required."; fi
    done

    InternalDomain=""
    while [[ -z "$InternalDomain" ]]; do
        if command -v gum &> /dev/null; then
            InternalDomain=$(gum input --prompt "Internal Routing Domain: " --value "$PrevDomain" --placeholder "lan.domain.com")
        else
            read -p "Internal Routing Domain [$PrevDomain]: " InputDomain
            InternalDomain=${InputDomain:-$PrevDomain}
        fi
        if [[ -z "$InternalDomain" ]]; then PrintMsg "196" "[FATAL] Domain required for static routing."; fi
    done

    sudo tee "$EnvFile" > /dev/null << EOF
VPN_GATEWAY_IP=${VpnGwIp}
ACME_EMAIL=${AcmeEmail}
CF_API_EMAIL=${AcmeEmail}
INTERNAL_DOMAIN=${InternalDomain}
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
        PrintMsg "196" "Rogue containers detected outside the Monolith perimeter:"
        echo "$AlienContainers"
        local do_nuke=0
        if command -v gum &> /dev/null; then
            gum confirm "Execute Scorched Earth? (DESTROY all listed alien containers permanently)" && do_nuke=1 || do_nuke=0
        else
            read -p "Execute Scorched Earth? [y/N]: " conf || echo ""
            [[ "${conf,,}" == "y" ]] && do_nuke=1 || do_nuke=0
        fi

        if [ "$do_nuke" -eq 1 ]; then
            PrintMsg "196" "Executing Scorched Earth."
            echo "$AlienContainers" | awk '{print $1}' | xargs -I {} sudo docker rm -f {} >/dev/null 2>&1 || true
        else
            PrintMsg "226" "Scorched Earth aborted. Alien containers retained."
        fi
    fi
fi

UpdaterScript="/opt/Docker/Scripts/Update${StackName}.sh"

sudo tee "${UpdaterScript}.tmp" > /dev/null << EOF
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

${UpdateCmd} || true
${UpgradeCmd} || true

/opt/Docker/Scripts/Deploy${StackName}.sh
EOF

sudo chmod 700 "${UpdaterScript}.tmp"
sudo mv "${UpdaterScript}.tmp" "${UpdaterScript}"

CronFile="/etc/cron.d/sovereign_updates"
sudo tee "$CronFile" > /dev/null << EOF
0 3 * * 0 root $UpdaterScript > /var/log/sovereign_updates.log 2>&1
EOF
sudo chmod 644 "$CronFile"

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

# ROUTE-11: Static Routing Provider Matrix
# This file is actively monitored by Traefik. Edits take effect instantly.
sudo tee "${TraefikDir}/DynamicRules.yml" > /dev/null << EOF
http:
  middlewares:
    # GLOBAL ARMOR
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
    
    # AIR-GAP GUILLOTINE
    vpn-whitelist:
      ipAllowList:
        sourceRange:
          - "10.13.13.0/24"    # Remote WireGuard Client Subnet
          - "${VPN_GATEWAY_IP}/32" # The VPN Gateway Interface

    # SATELLITE PASSWORD WALL
    static-auth:
      basicAuth:
        usersFile: "/run/secrets/traefik_auth"

  # ==============================================================================
  # SATELLITE ROUTING LEDGER (NAS / PROXMOX / REMOTE VMs)
  # ==============================================================================
  routers:
    # --------------------------------------------------
    # SECURE SATELLITE APP EXAMPLE (Protected by Password Wall)
    # --------------------------------------------------
    secure-satellite-app:
      rule: "Host(\`secure.${INTERNAL_DOMAIN}\`)"
      entryPoints:
        - "websecure"
      middlewares:
        - "secure-headers"
        - "static-auth"
        # Uncomment the line below to FORCE users to be connected to the VPN to see this page.
        # - "vpn-whitelist" 
      service: "secure-satellite-service"
      tls:
        certResolver: "cloudflare"

    # --------------------------------------------------
    # PUBLIC SATELLITE APP EXAMPLE (No Password - e.g., Plex, Web Server)
    # --------------------------------------------------
    public-satellite-app:
      rule: "Host(\`public.${INTERNAL_DOMAIN}\`)"
      entryPoints:
        - "websecure"
      middlewares:
        - "secure-headers"
      service: "public-satellite-service"
      tls:
        certResolver: "cloudflare"

  # ==============================================================================
  # SATELLITE PHYSICAL ADDRESS MAPPING
  # ==============================================================================
  services:
    secure-satellite-service:
      loadBalancer:
        servers:
          - url: "http://192.168.167.2:5001" # <-- REPLACE WITH REMOTE IP & ADMIN PORT

    public-satellite-service:
      loadBalancer:
        servers:
          - url: "http://192.168.167.10:8080" # <-- REPLACE WITH REMOTE IP & PORT
EOF

ResolveImage() {
    local img=$1
    sudo docker pull "$img" >/dev/null 2>&1
    local digest=$(sudo docker inspect --format='{{index .RepoDigests 0}}' "$img" 2>/dev/null || echo "")
    if [[ -z "$digest" ]]; then echo "[FATAL] Failed to resolve SHA256 for $img."; exit 1; fi
    echo "$digest"
}

IMG_SOCKET=$(ResolveImage "lscr.io/linuxserver/socket-proxy:latest")
IMG_TRAEFIK=$(ResolveImage "traefik:v2.11")

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
  traefik_auth:
    file: ${SecretsDir}/traefik_auth

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
      - traefik_auth
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
      - "--providers.docker.version=1.44"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.file.filename=/etc/traefik/dynamic_rules.yml"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.middlewares=secure-headers@file"
      - "--entrypoints.websecure.http.middlewares=secure-headers@file"
      - "--entrypoints.websecure.forwardedHeaders.trustedIPs=\${VPN_GATEWAY_IP}/32,10.13.13.0/24,10.50.0.0/24"
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
    echo ""
    PrintMsg "82" "✔ Traefik Core Staged (STATIC ROUTING ACTIVE)."
    echo ""
fi
exit 0