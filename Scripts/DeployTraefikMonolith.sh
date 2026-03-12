#!/bin/bash
# ==============================================================================
#  SOVEREIGN TRAEFIK CORE - ZERO-TRUST REVERSE PROXY (v62.7-LOCAL-ASSIMILATION)
# ==============================================================================
#  Architecture: Centralized /opt/Docker GitOps Topology
#  Assimilation Fixes Applied:
#  - ROUTE-12: Re-injected local Assimilation Protocol for co-located containers
#              (Gitea, Portainer) running alongside the Monolith.
#  Nomenclature Fixes Applied:
#  - DOCKER-02: Reverted Docker boundaries to strict snake_case/kebab-case.
#  - ENV-03: Unconditionally source the generated environment file into the active
#            shell to prevent 'unbound variable' suicides during YAML generation.
#  Scope Fixes Applied:
#  - BOOT-07: Encapsulated Scorched Earth protocol into a function to resolve
#             the fatal 'local' variable scope syntax error.
#  TTY Fixes Applied:
#  - BOOT-06: Interactive check shifted from stdout (-t 1) to stdin (-t 0).
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
# DOCKER-02: Native Docker execution defaults restored.
ComposeFile="${BaseDir}/docker-compose.yml"
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
fi

# ENV-03: Unconditionally extract state into current execution context to prevent 'unbound variable' crashes
set +u
source "$EnvFile"
set -u

sudo timedatectl set-timezone UTC
sudo rm -f /etc/localtime && sudo ln -s /usr/share/zoneinfo/UTC /etc/localtime
if systemctl is-active --quiet systemd-timesyncd; then
    sudo systemctl restart systemd-timesyncd
elif systemctl is-active --quiet chronyd; then
    sudo systemctl restart chronyd
fi

# BOOT-07: Encapsulated Scorched Earth protocol to prevent 'local' scope syntax errors
EnforceScorchedEarth() {
    if [ "$Interactive" -eq 1 ] && command -v docker &> /dev/null; then
        local AlienContainers
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
}

# ROUTE-12: Local Assimilation Engine for Co-Located Services
AssimilateAlienContainers() {
    if [ "$Interactive" -eq 1 ] && command -v docker &> /dev/null; then
        # Re-scan. If Scorched Earth executed, this list will be empty and the function exits cleanly.
        local foreign_containers
        foreign_containers=$(sudo docker ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' -v stack="${StackName,,}" 'tolower($2) != stack && $1 != "" {print $1}')

        if [ -n "$foreign_containers" ]; then
            echo ""
            PrintMsg "214" "========================================================================"
            PrintMsg "214" "LOCAL ASSIMILATION PROTOCOL INITIATED"
            PrintMsg "214" "Generating Traefik Integration Manifests for retained local containers."
            PrintMsg "214" "========================================================================"
            echo ""

            local manifest_dir="${BaseDir}/IntegrationManifests"
            sudo mkdir -p "$manifest_dir"

            for container in $foreign_containers; do
                local clean_name=$(echo "$container" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
                local manifest_file="${manifest_dir}/${clean_name}_integration.yml"

                local has_traefik=$(sudo docker inspect --format='{{index .Config.Labels "traefik.enable"}}' "$container" 2>/dev/null || echo "")
                local current_middlewares=$(sudo docker inspect --format='{{index .Config.Labels "traefik.http.routers.'$clean_name'.middlewares"}}' "$container" 2>/dev/null || echo "")

                local needs_update=1

                if [ "$has_traefik" == "true" ]; then
                    if [[ "$current_middlewares" == *"vpn-whitelist"* ]] || [[ "$current_middlewares" == *"static-auth"* ]]; then
                        PrintMsg "82" "[$container] -> Verified. Monolith armor is active. Skipping."
                        needs_update=0
                    else
                        PrintMsg "196" "[$container] -> WARNING: Legacy or insecure Traefik labels detected."
                        if command -v gum &> /dev/null; then
                            gum confirm "Generate updated Integration Manifest for $container?" && needs_update=1 || needs_update=0
                        else
                            read -p "Update labels for $container? [y/N]: " conf || echo ""
                            [[ "${conf,,}" == "y" ]] && needs_update=1 || needs_update=0
                        fi
                    fi
                else
                    PrintMsg "226" "[$container] -> Unassimilated. No Traefik routing found."
                    if command -v gum &> /dev/null; then
                        gum confirm "Assimilate $container into the Traefik Monolith?" && needs_update=1 || needs_update=0
                    else
                        read -p "Assimilate $container? [y/N]: " conf || echo ""
                        [[ "${conf,,}" == "y" ]] && needs_update=1 || needs_update=0
                    fi
                fi

                if [ "$needs_update" -eq 1 ]; then
                    local posture_choice="1"
                    local mw_string=""

                    echo ""
                    PrintMsg "214" "------------------------------------------------------------------------"
                    PrintMsg "214" " EXPOSURE POSTURE MATRIX FOR: [$container]"
                    PrintMsg "214" "------------------------------------------------------------------------"
                    PrintMsg "118" " [1] VPN-Only (Absolute Air-Gap) [STIG DEFAULT]"
                    PrintMsg "240" "     Middlewares: secure-headers@file, vpn-whitelist@file"
                    echo ""
                    PrintMsg "226" " [2] BasicAuth (Password Wall)"
                    PrintMsg "240" "     Middlewares: secure-headers@file, static-auth@file"
                    echo ""
                    PrintMsg "196" " [3] Fully Public (NO ARMOR - EXTREME DANGER)"
                    PrintMsg "240" "     Middlewares: secure-headers@file"
                    echo ""
                    PrintMsg "244" " [4] Internal Backend (Completely Ignored)"
                    PrintMsg "240" "     Behavior: Container is hidden from Traefik. For internal DBs."
                    PrintMsg "214" "------------------------------------------------------------------------"
                    echo ""

                    if command -v gum &> /dev/null; then
                        local choice=$(gum choose "1) VPN-Only" "2) BasicAuth" "3) Fully Public" "4) Internal Backend")
                        posture_choice=${choice:0:1}
                    else
                        read -p "Select posture for [$container] (1-4): " posture_choice || echo ""
                    fi

                    case "$posture_choice" in
                        1) mw_string="secure-headers@file,vpn-whitelist@file" ;;
                        2) mw_string="secure-headers@file,static-auth@file" ;;
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
# TARGET ARCHITECTURE: TraefikMonolith (Local Instance)
# ==============================================================================
# POSTURE: Option $posture_choice
# MIDDLEWARES: $mw_string
# ==============================================================================
# INSTRUCTIONS:
# 1. Open the original docker-compose.yml file where '$container' is defined.
# 2. Add 'proxy_network' to your bottom networks block.
# 3. Paste the networks and labels sections below into your service definition.
# 4. Replace <PORT> with the actual internal listening port of your application.
# 5. Re-run 'docker compose up -d' on your original stack.
# ==============================================================================

networks:
  proxy_network:
    external: true

services:
  $container:
    # ... existing image/volumes ...
    networks:
      - proxy_network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${clean_name}.rule=Host(\`${clean_name}.${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.${clean_name}.entrypoints=websecure"
      - "traefik.http.routers.${clean_name}.tls.certresolver=letsencrypt"
      - "traefik.http.services.${clean_name}.loadbalancer.server.port=<PORT>"
      - "traefik.http.routers.${clean_name}.middlewares=${mw_string}"
      - "traefik.docker.network=proxy_network"
MANIFEST_EOF
                    PrintMsg "82" "✔ Manifest generated: ${manifest_dir}/${clean_name}_integration.yml"
                fi
            done
        fi
    fi
}

EnforceScorchedEarth
AssimilateAlienContainers

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

# DOCKER-02: Enforcing strict snake_case for all Docker daemon objects
sudo tee "$ComposeFile" > /dev/null << EOF
networks:
  proxy_network:
    name: proxy_network
    attachable: true
    ipam:
      config:
        - subnet: 10.50.0.0/24
  socket_network:
    name: socket_network
    internal: true

secrets:
  cf_api_key:
    file: ${SecretsDir}/cf_api_key
  traefik_auth:
    file: ${SecretsDir}/traefik_auth

services:
  docker_socket_proxy:
    image: ${IMG_SOCKET}
    container_name: docker_socket_proxy
    networks:
      - socket_network
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

  traefik_core:
    image: ${IMG_TRAEFIK}
    container_name: traefik_core
    networks:
      - proxy_network
      - socket_network
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
      - "--providers.docker.endpoint=tcp://docker_socket_proxy:2375"
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
      - docker_socket_proxy
    restart: unless-stopped
EOF

sudo chown 0:0 "$ComposeFile"
sudo chmod 600 "$ComposeFile"

# CYCLE-01: Stateful matrix teardown to prevent stale network bridge collisions.
CycleExistingMatrix() {
    # DOCKER-02 Transition: Prevent orphaning by destroying the legacy PascalCase stack first.
    if [ -f "${BaseDir}/DockerCompose.yml" ]; then
        cd "$BaseDir"
        local legacy_active
        legacy_active=$(sudo docker compose -f DockerCompose.yml --env-file Traefik.env ps -q 2>/dev/null || echo "")
        if [ -n "$legacy_active" ]; then
            if [ "$Interactive" -eq 1 ]; then PrintMsg "214" "⚠️  Legacy PascalCase Matrix detected. Tearing down..."; fi
            sudo docker compose -f DockerCompose.yml --env-file Traefik.env down --remove-orphans > /dev/null 2>&1 || true
            sleep 3
        fi
        sudo rm -f "${BaseDir}/DockerCompose.yml"
    fi

    if [ -f "$ComposeFile" ]; then
        cd "$BaseDir"
        local active_containers
        # DOCKER-02: Native docker-compose.yml detection active. Explicit -f amputated.
        active_containers=$(sudo docker compose --env-file Traefik.env ps -q 2>/dev/null || echo "")
        
        if [ -n "$active_containers" ]; then
            if [ "$Interactive" -eq 1 ]; then
                echo ""
                PrintMsg "214" "⚠️  Existing Traefik Matrix detected."
                if command -v gum &> /dev/null; then
                    gum spin --spinner dot --title "Executing controlled teardown and flushing network bridges..." -- sudo docker compose --env-file Traefik.env down --remove-orphans
                else
                    PrintMsg "240" "Executing controlled teardown..."
                    sudo docker compose --env-file Traefik.env down --remove-orphans > /dev/null 2>&1
                fi
                # Mandatory kernel buffer to ensure veth interfaces drop completely
                sleep 3
            else
                sudo docker compose --env-file Traefik.env down --remove-orphans > /dev/null 2>&1 || true
                sleep 5
            fi
        fi
    fi
}

CycleExistingMatrix

# BOOT-08: Unlocked container ignition sequence for interactive deployments.
if [ "$Interactive" -eq 1 ]; then
    echo ""
    PrintMsg "226" "Igniting the Traefik Matrix..."
fi

# DOCKER-02: Native docker-compose.yml detection active. Explicit -f amputated.
cd "$BaseDir" && sudo docker compose --env-file Traefik.env up -d --remove-orphans

if [ "$Interactive" -eq 1 ]; then
    echo ""
    PrintMsg "82" "✔ Traefik Core Online (STATIC ROUTING ACTIVE)."
    echo ""
fi
exit 0