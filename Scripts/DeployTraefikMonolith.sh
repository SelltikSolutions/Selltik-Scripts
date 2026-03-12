#!/bin/bash
# ==============================================================================
#  SOVEREIGN TRAEFIK CORE - ZERO-TRUST REVERSE PROXY (v61.0-ENCAPSULATION)
# ==============================================================================
#  Architecture: Centralized /opt/Docker GitOps Topology
#  Encapsulation Fixes Applied:
#  - SEC-04: Pre-populated .gitignore injected into SecretsDir.
#  - SEC-05: Abstracted SecretsDir from ConfigDir to prevent GitOps tarball leakage.
#  Audit Fixes Applied:
#  - TRAEFIK-02: Restored v2.11 API determinism (prevent v3 1.24 downgrade panic).
#  - SAFETY-01: Scorched Earth protocol bolted with interactive confirmation switch.
#  - ACME-01: Let's Encrypt staging API trap removed; restoring production trust chain.
#  Drone Forge Protocol Applied:
#  - ROUTE-10: Monolith acts as C2, automatically generating a burned-in
#              PortableAssimilator.sh drone for remote NAS/Satellite deployment.
#  - ENV-02: INTERNAL_DOMAIN collection added to Monolith to seed the drone.
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

# SEC-05: Silent migration of legacy nested secrets to the encapsulated stack directory.
if [ -d "${ConfigDir}/Secrets" ] && [ ! -d "${SecretsDir}" ]; then
    sudo mv "${ConfigDir}/Secrets" "${SecretsDir}"
elif [ -d "${ConfigDir}/Secrets" ]; then
    sudo cp -a "${ConfigDir}/Secrets/"* "${SecretsDir}/" 2>/dev/null || true
    sudo rm -rf "${ConfigDir}/Secrets"
fi

sudo mkdir -p "$SecretsDir"
sudo chmod 700 "$SecretsDir"

# SEC-04: Pre-populate .gitignore to prevent catastrophic repository leaks.
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

if [ "$Interactive" -eq 1 ]; then
    PrevPiZeroIp=$(grep "^PI_ZERO_IP=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevEmail=$(grep "^ACME_EMAIL=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevDomain=$(grep "^INTERNAL_DOMAIN=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")

    PiZeroIp=""
    while [[ -z "$PiZeroIp" ]]; do
        if command -v gum &> /dev/null; then
            PiZeroIp=$(gum input --prompt "Pi Zero (VPN Gateway) LAN IP: " --value "$PrevPiZeroIp" --placeholder "10.0.0.40")
        else
            read -p "Pi Zero (VPN Gateway) LAN IP [$PrevPiZeroIp]: " InputIp
            PiZeroIp=${InputIp:-$PrevPiZeroIp}
        fi
        if [[ -z "$PiZeroIp" ]]; then PrintMsg "196" "[FATAL] Pi Zero IP is required. Leaving this blank will crash Traefik."; fi
    done

    AcmeEmail=""
    while [[ -z "$AcmeEmail" ]]; do
        if command -v gum &> /dev/null; then
            AcmeEmail=$(gum input --prompt "Let's Encrypt Email: " --value "$PrevEmail" --placeholder "admin@domain.com")
        else
            read -p "Let's Encrypt Email [$PrevEmail]: " InputEmail
            AcmeEmail=${InputEmail:-$PrevEmail}
        fi
        if [[ -z "$AcmeEmail" ]]; then PrintMsg "196" "[FATAL] Let's Encrypt requires a valid notification email."; fi
    done

    InternalDomain=""
    while [[ -z "$InternalDomain" ]]; do
        if command -v gum &> /dev/null; then
            InternalDomain=$(gum input --prompt "Internal Routing Domain: " --value "$PrevDomain" --placeholder "lan.domain.com")
        else
            read -p "Internal Routing Domain [$PrevDomain]: " InputDomain
            InternalDomain=${InputDomain:-$PrevDomain}
        fi
        if [[ -z "$InternalDomain" ]]; then PrintMsg "196" "[FATAL] Domain required to forge the assimilation drone."; fi
    done

    sudo tee "$EnvFile" > /dev/null << EOF
PI_ZERO_IP=${PiZeroIp}
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

# SAFETY-01: Interactive confirmation switch implemented for the Scorched Earth protocol
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
# TRAEFIK-02: Surgically pinned Traefik back to LTS v2.11 to restore API version determinism
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
      # TRAEFIK-02: Hardcoded 1.44 API version bypasses the HAProxy header stripping panic
      - "--providers.docker.version=1.44"
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
      # ACME-01: Staging API removed. Traefik will default to Let's Encrypt production endpoints.
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

# ROUTE-10: C2 Payload Generation. Forge the portable assimilation drone for remote deployment.
GeneratePortableDrone() {
    PrintMsg "226" "Forging Portable Assimilation Drone..."
    local DronePath="/opt/Docker/Scripts/PortableAssimilator.sh"
    
    # We use a completely quoted Here-Doc (<< 'DRONE_EOF') so the Monolith's bash parser
    # completely ignores all variables inside. It drops a raw script.
    sudo tee "$DronePath" > /dev/null << 'DRONE_EOF'
#!/bin/bash
# ==============================================================================
#  PORTABLE ALIEN ASSIMILATION DRONE (v4.0-BURNED-IN)
#  Architecture: Autonomous Zero-Touch Payload
# ==============================================================================
#  This script was dynamically generated by the Traefik Monolith.
#  It contains hardcoded cryptographic routing variables.
#  It can be securely copied (SCP) to any NAS or remote server.
# ==============================================================================

set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

[ "$EUID" -eq 0 ] || { echo "[FATAL] Elevated privileges required. Run with: sudo $0"; exit 1; }

# BURNED-IN C2 VARIABLES
INTERNAL_DOMAIN="TARGET_DOMAIN_INJECTION"
ManifestDir="/opt/Docker/IntegrationManifests"
ProxyNetworkName="ProxyNetwork"

sudo mkdir -p "$ManifestDir"

PrintMsg() {
    local color=$1
    local msg=$2
    if command -v gum &> /dev/null; then
        gum style --foreground "$color" "$msg"
    else
        echo -e "\033[1;33m$msg\033[0m"
    fi
}

Interactive=$([ -t 0 ] && echo 1 || echo 0)

ScanForeignContainers() {
    if ! command -v docker &> /dev/null; then 
        PrintMsg "196" "[FATAL] Docker daemon not found. Is the engine running?"
        exit 1
    fi

    # Interrogate local socket. Excludes TraefikMonolith containers.
    local foreign_containers
    foreign_containers=$(sudo docker ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' 'tolower($2) != "traefikmonolith" && $1 != "" {print $1}')

    if [ -z "$foreign_containers" ]; then
        PrintMsg "82" "✔ Perimeter secure. No alien containers detected on this node."
        exit 0
    fi

    echo ""
    PrintMsg "214" "========================================================================"
    PrintMsg "214" "ALIEN CONTAINERS DETECTED"
    PrintMsg "214" "Found containers operating outside the Traefik Matrix boundary."
    PrintMsg "214" "========================================================================"
    echo ""
    
    for container in $foreign_containers; do
        local clean_name=$(echo "$container" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
        local manifest_file="${ManifestDir}/${clean_name}_Integration.yml"
        
        local has_traefik=$(sudo docker inspect --format='{{index .Config.Labels "traefik.enable"}}' "$container" 2>/dev/null || echo "")
        local current_middlewares=$(sudo docker inspect --format='{{index .Config.Labels "traefik.http.routers.'$clean_name'.middlewares"}}' "$container" 2>/dev/null || echo "")
        
        local needs_update=1
        
        if [ "$has_traefik" == "true" ]; then
            if [[ "$current_middlewares" == *"vpn-whitelist"* ]] || [[ "$current_middlewares" == *"traefik-auth"* ]]; then
                PrintMsg "82" "[$container] -> Verified. Sovereign Node armor is active. Skipping."
                needs_update=0
            else
                PrintMsg "196" "[$container] -> WARNING: Legacy or insecure Traefik labels detected."
                if [ "$Interactive" -eq 1 ]; then
                    if command -v gum &> /dev/null; then
                        gum confirm "Generate updated Integration Manifest for $container?" && needs_update=1 || needs_update=0
                    else
                        read -p "Update labels for $container? [y/N]: " conf || echo ""
                        [[ "${conf,,}" == "y" ]] && needs_update=1 || needs_update=0
                    fi
                fi
            fi
        else
            PrintMsg "226" "[$container] -> Unassimilated. No Traefik routing found."
            if [ "$Interactive" -eq 1 ]; then
                if command -v gum &> /dev/null; then
                    gum confirm "Assimilate $container into the Traefik Matrix?" && needs_update=1 || needs_update=0
                else
                    read -p "Assimilate $container? [y/N]: " conf || echo ""
                    [[ "${conf,,}" == "y" ]] && needs_update=1 || needs_update=0
                fi
            fi
        fi

        if [ "$needs_update" -eq 1 ]; then
            local posture_choice="1"
            local mw_string=""
            
            if [ "$Interactive" -eq 1 ]; then
                echo ""
                PrintMsg "214" "------------------------------------------------------------------------"
                PrintMsg "214" " EXPOSURE POSTURE MATRIX FOR: [$container]"
                PrintMsg "214" "------------------------------------------------------------------------"
                PrintMsg "118" " [1] VPN-Only (Absolute Air-Gap) [STIG DEFAULT]"
                PrintMsg "240" "     Middlewares: secure-headers@file, vpn-whitelist@file"
                PrintMsg "226" " [2] BasicAuth (Password Wall)"
                PrintMsg "240" "     Middlewares: secure-headers@file, traefik-auth@file"
                PrintMsg "196" " [3] Fully Public (NO ARMOR - EXTREME DANGER)"
                PrintMsg "240" "     Middlewares: secure-headers@file"
                PrintMsg "244" " [4] Internal Backend (Completely Ignored)"
                PrintMsg "214" "------------------------------------------------------------------------"
                echo ""

                if command -v gum &> /dev/null; then
                    local choice=$(gum choose "1) VPN-Only" "2) BasicAuth" "3) Fully Public" "4) Internal Backend")
                    posture_choice=${choice:0:1}
                else
                    read -p "Select posture for [$container] (1-4): " posture_choice || echo ""
                fi
            fi
            
            case "$posture_choice" in
                1) mw_string="secure-headers@file,vpn-whitelist@file" ;;
                2) mw_string="secure-headers@file,traefik-auth@file" ;;
                3) mw_string="secure-headers@file" ;;
                4) 
                    PrintMsg "240" "[$container] -> Marked as internal. No manifest generated."
                    continue 
                    ;;
                *) mw_string="secure-headers@file,vpn-whitelist@file" ;;
            esac
            
            sudo tee "$manifest_file" > /dev/null << MANIFEST_EOF
# ==============================================================================
# TRAEFIK INTEGRATION MANIFEST FOR: $container
# TARGET NETWORK: $INTERNAL_DOMAIN
# ==============================================================================
# INSTRUCTIONS FOR THIS SATELLITE NODE:
# 1. Open the original docker-compose.yml file where '$container' is defined.
# 2. Add '$ProxyNetworkName' to your bottom networks block.
# 3. Paste the networks and labels sections below into your service definition.
# 4. Replace <PORT> with the actual internal listening port of your application.
# 5. Re-run 'docker compose up -d' on your original stack.
# 
# REMOTE ROUTING REMINDER:
# The core Traefik Monolith must have this node's Docker Socket mapped in its
# configuration for these labels to be ingested across the network.
# ==============================================================================

networks:
  $ProxyNetworkName:
    external: true

services:
  $container:
    networks:
      - $ProxyNetworkName
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${clean_name}.rule=Host(\`${clean_name}.${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.${clean_name}.entrypoints=websecure"
      - "traefik.http.routers.${clean_name}.tls.certresolver=letsencrypt"
      - "traefik.http.services.${clean_name}.loadbalancer.server.port=<PORT>"
      - "traefik.http.routers.${clean_name}.middlewares=${mw_string}"
      - "traefik.docker.network=${ProxyNetworkName}"
MANIFEST_EOF
            PrintMsg "82" "✔ Manifest generated: ${ManifestDir}/${clean_name}_Integration.yml"
        fi
    done
}

ScanForeignContainers
exit 0
DRONE_EOF

    # SED Injection: Mathematically replace the placeholder with the Monolith's actual state variable.
    sudo sed -i "s/TARGET_DOMAIN_INJECTION/${INTERNAL_DOMAIN}/g" "$DronePath"
    sudo chmod +x "$DronePath"
}

if [ "$Interactive" -eq 0 ]; then
    cd "$BaseDir" && sudo docker compose --env-file Traefik.env up -d --remove-orphans
    GeneratePortableDrone
elif [ "$Interactive" -eq 1 ]; then
    GeneratePortableDrone
    echo ""
    PrintMsg "82" "✔ Traefik Core Staged (PRODUCTION API ACTIVE)."
    PrintMsg "226" "► The Portable Assimilation Drone has been forged."
    PrintMsg "240" "  Use SCP or SFTP to copy this payload to your NAS or remote servers:"
    PrintMsg "250" "  /opt/Docker/Scripts/PortableAssimilator.sh"
    echo ""
fi
exit 0