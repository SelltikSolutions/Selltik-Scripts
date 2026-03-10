#!/bin/bash
# ==============================================================================
#  UNIFIED SOVEREIGN NODE - TRAEFIK + WIREGUARD + PI-HOLE + UNBOUND (v9.2-VERBOSE-ASSIMILATION)
# ==============================================================================
#  Architecture: Single-Node Unified Ingress & VPN Topology
#  Verbose Assimilation Edge-Case Fixes Applied:
#  - ROUTE-09: Verbose STIG documentation injected directly into the CLI prompt for the 4-Tier Exposure Matrix to prevent accidental WAN exposure.
#  Dynamic Assimilation Edge-Case Fixes Applied:
#  - ROUTE-07: Docker socket interrogation added to detect existing label states on alien containers.
#  - ROUTE-08: Interactive 4-Tier Exposure Matrix (STIG VPN-Only, BasicAuth, Public, Internal).
#  Assimilation Edge-Case Fixes Applied:
#  - ROUTE-05: Local daemon scanning implemented to detect alien containers.
#  - ROUTE-06: Automated generation of custom Traefik Integration Manifests.
#  LTS Determinism Edge-Case Fixes Applied:
#  - TRAEFIK-01: Downgraded to v2.11 LTS to restore manual API version pinning.
#  - PROXY-09: Reverted to lscr.io socket proxy for architectural consistency.
#  Encapsulation Edge-Case Fixes Applied:
#  - SEC-04: Secrets encapsulated into Stack BaseDir. Pre-populated .gitignore.
#  - ROUTE-04: WhoamiTest baseline service injected as a Rosetta Stone.
#  Subnet Mask Fixes Applied:
#  - ROUTE-02: Appended /24 CIDR to INTERNAL_SUBNET.
#  Omnidirectional Bind Edge-Case Fixes Applied:
#  - BIND-01: Injected DNSMASQ_LISTENING and FTLCONF_dns_listeningMode.
#  FTL Stabilization Edge-Case Fixes Applied:
#  - CAP-05: SETFCAP, IPC_LOCK, SYS_RESOURCE injected.
#  - ENV-01: Hybrid v5/v6 Pi-Hole environment variables implemented.
#  S6-Overlay Override Edge-Case Fixes Applied:
#  - CAP-04: Restored DAC_OVERRIDE, FOWNER, and SYS_CHROOT.
#  - HEALTH-03: Hardened Pi-Hole healthcheck using native pi.hole internal record.
#  FTL Resuscitation Edge-Case Fixes Applied:
#  - CAP-03: Restored NET_ADMIN and SYS_NICE to Pi-Hole.
#  - SEC-03: Relaxed secret bind-mounts to 644.
#  DAG Restored Edge-Case Fixes Applied:
#  - DAG-01: Global Dependency Directed Acyclic Graph (DAG) enforced.
#  - BOOT-01: Healthcheck Gating injected.
#  Info Pinhole Edge-Case Fixes Applied:
#  - PROXY-07: INFO=1 added to Socket Proxy.
#  SDK Override Edge-Case Fixes Applied:
#  - PROXY-06: PING=1 added to Socket Proxy.
#  Final Edge-Case Fixes Applied:
#  - DOCKER-01: PascalCase constraint dropped for docker-compose.yml.
#  - VAR-01: Split-brain interpolation eradicated.
#  - CAP-02: SYS_MODULE & DAC_OVERRIDE restored to WireGuard.
#  - SEC-02: Decoupled secret rotation engine.
#  - AUTH-01: Cryptographic BasicAuth bolted to Traefik Dashboard.
#  - ZTRUST-03: ipAllowList constrained to a strict /32 pinhole.
# ==============================================================================

set -euo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

StackName="SovereignNode"
BaseDir="/opt/Docker/Stacks/${StackName}"
ConfigDir="/opt/Docker/Config"
SecretsDir="${BaseDir}/Secrets"
EnvFile="${BaseDir}/Node.env"
ComposeFile="${BaseDir}/docker-compose.yml"
LockFile="/var/lock/sovereign_node.lock"

sudo mkdir -p "$BaseDir"

# SEC-04: Silent migration of legacy global secrets to the encapsulated stack directory.
if [ -d "/opt/Docker/Config/Secrets" ] && [ ! -d "${SecretsDir}" ]; then
    sudo mv /opt/Docker/Config/Secrets "${SecretsDir}"
fi

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
    else
        echo "[FATAL] /etc/os-release missing."; exit 1
    fi

    if [[ "$OS_FAMILY" == *"debian"* ]] || [[ "$OS_ID" == "parrot" ]] || [[ "$OS_ID" == "ubuntu" ]]; then
        PkgManager="apt-get"
        UpdateCmd="apt-get update -y -q"
        InstallCmd="DEBIAN_FRONTEND=noninteractive apt-get install -y -q"
        UpgradeCmd="DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\""
    else
        echo "[FATAL] Unsupported OS Family."; exit 1
    fi
}
DetectOsFamily

if [ "$Interactive" -eq 1 ] && ! command -v gum &> /dev/null; then
    sudo mkdir -p /etc/apt/keyrings
    curl --connect-timeout 5 -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg || true
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
    eval "$UpdateCmd" > /dev/null || true
    eval "$InstallCmd gum" > /dev/null || true
fi

if [ "$Interactive" -eq 1 ]; then
    PrintMsg "212" "Unified Sovereign Node Forge (Verbose Assimilation Protocol)"
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
    if [ ! -f "${SecretsDir}/${name}" ]; then
        sudo touch "${SecretsDir}/${name}"
        sudo chmod 644 "${SecretsDir}/${name}"
    fi
    sudo sh -c "cat '$tmp_file' > '${SecretsDir}/${name}'"
    sudo chmod 644 "${SecretsDir}/${name}"
    sudo rm -f "$tmp_file"
}

RotateSecret=0
if [ -f "${SecretsDir}/pihole_pass" ] || [ -f "${SecretsDir}/cf_api_token" ] || [ -f "${SecretsDir}/traefik_auth" ]; then
    if [ "$Interactive" -eq 1 ]; then
        if command -v gum &> /dev/null; then
            gum confirm "Existing secrets found. Force rotate ALL credentials?" && RotateSecret=1 || RotateSecret=0
        else
            read -p "[INFO] Existing secrets found. Force rotate ALL credentials? [y/N]: " ConfirmRotate || echo ""
            if [[ "${ConfirmRotate,,}" == "y" ]]; then RotateSecret=1; fi
        fi
    fi
fi

sudo chmod 644 "${SecretsDir}/"* 2>/dev/null || true

if [ ! -f "${SecretsDir}/pihole_pass" ] || [ "$RotateSecret" -eq 1 ]; then
    if [ "$Interactive" -eq 1 ]; then
        PrintMsg "226" "Provide a secure password for the Pi-Hole Web Admin UI:"
        PiHolePass=""
        while [[ -z "$PiHolePass" ]]; do
            if command -v gum &> /dev/null; then PiHolePass=$(gum input --password || echo "")
            else read -s -p "Password: " PiHolePass || echo ""; echo ""; fi
            if [[ -z "$PiHolePass" ]]; then PrintMsg "196" "Password cannot be empty."; fi
        done
        WriteSecret "pihole_pass" "$PiHolePass"
    else
        PrintMsg "196" "[WARNING] Headless Mode: Auto-generating secure Pi-Hole password."
        PiHolePass=$(openssl rand -base64 24)
        WriteSecret "pihole_pass" "$PiHolePass"
    fi
fi

if [ ! -f "${SecretsDir}/cf_api_token" ] || [ "$RotateSecret" -eq 1 ]; then
    if [ "$Interactive" -eq 1 ]; then
        PrintMsg "226" "Provide your Scoped Cloudflare DNS API Token:"
        CfApiToken=""
        while [[ -z "$CfApiToken" ]]; do
            if command -v gum &> /dev/null; then CfApiToken=$(gum input --password || echo "")
            else read -s -p "CF Scoped Token: " CfApiToken || echo ""; echo ""; fi
            if [[ -z "$CfApiToken" ]]; then PrintMsg "196" "API Token cannot be empty."; fi
        done
        WriteSecret "cf_api_token" "$CfApiToken"
    else
        echo "[FATAL] Headless execution failed. cf_api_token is missing and cannot be auto-generated."
        exit 1
    fi
fi

if [ ! -f "${SecretsDir}/traefik_auth" ] || [ "$RotateSecret" -eq 1 ]; then
    if [ "$Interactive" -eq 1 ]; then
        PrintMsg "226" "Provide a secure password for the Traefik Admin Dashboard:"
        TraefikPass=""
        while [[ -z "$TraefikPass" ]]; do
            if command -v gum &> /dev/null; then TraefikPass=$(gum input --password || echo "")
            else read -s -p "Traefik Password: " TraefikPass || echo ""; echo ""; fi
            if [[ -z "$TraefikPass" ]]; then PrintMsg "196" "Password cannot be empty."; fi
        done
        TraefikHash="admin:$(openssl passwd -apr1 "$TraefikPass")"
        WriteSecret "traefik_auth" "$TraefikHash"
    else
        PrintMsg "196" "[WARNING] Headless Mode: Auto-generating Traefik BasicAuth password."
        TraefikPass=$(openssl rand -base64 24)
        TraefikHash="admin:$(openssl passwd -apr1 "$TraefikPass")"
        WriteSecret "traefik_auth" "$TraefikHash"
        PrintMsg "226" "Traefik Auto-Password: $TraefikPass"
        PrintMsg "196" "^^^ SAVE THIS IMMEDIATELY. IT WILL NOT BE LOGGED. ^^^"
    fi
fi

if [ "$Interactive" -eq 1 ]; then
    PrevEndpoint=$(grep "^WG_ENDPOINT=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevDomain=$(grep "^INTERNAL_DOMAIN=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevEmail=$(grep "^ACME_EMAIL=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevWgPort=$(grep "^WG_PORT=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "51820")
    PrevWgPeers=$(grep "^WG_PEERS=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "3")

    WgEndpoint=""
    while [[ -z "$WgEndpoint" ]]; do
        if command -v gum &> /dev/null; then WgEndpoint=$(gum input --prompt "WireGuard Public Endpoint (IP/DDNS): " --value "$PrevEndpoint" || echo "")
        else read -p "WireGuard Public Endpoint [$PrevEndpoint]: " InputWg || echo ""; WgEndpoint=${InputWg:-$PrevEndpoint}; fi
    done

    InternalDomain=""
    while [[ -z "$InternalDomain" ]]; do
        if command -v gum &> /dev/null; then InternalDomain=$(gum input --prompt "Internal Routing Domain (e.g. lan.domain.com): " --value "$PrevDomain" || echo "")
        else read -p "Internal Routing Domain [$PrevDomain]: " InputDomain || echo ""; InternalDomain=${InputDomain:-$PrevDomain}; fi
    done

    AcmeEmail=""
    while [[ -z "$AcmeEmail" ]]; do
        if command -v gum &> /dev/null; then AcmeEmail=$(gum input --prompt "Let's Encrypt Email: " --value "$PrevEmail" || echo "")
        else read -p "Let's Encrypt Email [$PrevEmail]: " InputEmail || echo ""; AcmeEmail=${InputEmail:-$PrevEmail}; fi
    done

    sudo tee "$EnvFile" > /dev/null << EOF
WG_ENDPOINT=${WgEndpoint}
INTERNAL_DOMAIN=${InternalDomain}
ACME_EMAIL=${AcmeEmail}
WG_PORT=${PrevWgPort}
WG_PEERS=${PrevWgPeers}
TZ=UTC
EOF
    sudo chmod 600 "$EnvFile"
fi

source "$EnvFile"

sudo timedatectl set-timezone UTC
if systemctl is-active --quiet systemd-timesyncd; then sudo systemctl restart systemd-timesyncd; fi

UpdaterScript="/opt/Docker/Scripts/Update${StackName}.sh"
sudo tee "${UpdaterScript}.tmp" > /dev/null << EOF
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"
${UpdateCmd} || true
${UpgradeCmd} || true
/opt/Docker/Scripts/Deploy${StackName}.sh
(
    flock -w 60 200
    sleep 10
    cd /opt/Docker/Stacks/${StackName} && sudo docker compose restart UnboundDns
) 200>"$LockFile"
EOF
sudo chmod 700 "${UpdaterScript}.tmp"
sudo mv "${UpdaterScript}.tmp" "${UpdaterScript}"

CronFile="/etc/cron.d/sovereign_updates"
sudo tee "$CronFile" > /dev/null << EOF
0 3 * * 0 root $UpdaterScript > /var/log/sovereign_updates.log 2>&1
EOF
sudo chmod 644 "$CronFile"

SysctlConf="/etc/sysctl.d/99-sovereign-node.conf"
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

if sudo modinfo wireguard >/dev/null 2>&1 || [ -d /sys/module/wireguard ]; then
    for mod in wireguard iptable_nat iptable_mangle ip_tables; do sudo modprobe "$mod" 2>/dev/null || true; done
    sudo tee /etc/modules-load.d/wireguard.conf > /dev/null << MODEOF
wireguard
iptable_nat
iptable_mangle
ip_tables
MODEOF
elif sudo ip link add dev wg999 type wireguard 2>/dev/null; then
    sudo ip link del dev wg999 2>/dev/null || true
    for mod in iptable_nat iptable_mangle ip_tables; do sudo modprobe "$mod" 2>/dev/null || true; done
    sudo tee /etc/modules-load.d/wireguard.conf > /dev/null << MODEOF
iptable_nat
iptable_mangle
ip_tables
MODEOF
else
    PrintMsg "196" "[FATAL] Host kernel lacks wireguard capability."; exit 1
fi

TraefikDir="${ConfigDir}/Traefik"
sudo mkdir -p "${TraefikDir}/dynamic"
if [ ! -f "${TraefikDir}/acme.json" ]; then
    sudo touch "${TraefikDir}/acme.json"
    sudo chmod 600 "${TraefikDir}/acme.json"
fi

sudo tee "${TraefikDir}/TraefikConfig.yml" > /dev/null << EOF
api:
  dashboard: true
  insecure: false
ping: {}
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
providers:
  docker:
    endpoint: "tcp://DockerSocketProxy:2375"
    exposedByDefault: false
  file:
    directory: /etc/traefik/dynamic
    watch: true
certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ACME_EMAIL}"
      storage: /acme.json
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "1.0.0.1:53"
EOF

sudo tee "${TraefikDir}/dynamic/DynamicRules.yml" > /dev/null << EOF
http:
  middlewares:
    secure-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true
        contentTypeNosniff: true
        referrerPolicy: "strict-origin-when-cross-origin"
        customResponseHeaders:
          X-Frame-Options: "SAMEORIGIN"
          X-XSS-Protection: "1; mode=block"
    vpn-whitelist:
      ipAllowList:
        sourceRange:
          - "10.13.13.0/24"
          - "10.99.0.10/32"
    traefik-auth:
      basicAuth:
        usersFile: "/run/secrets/traefik_auth"
EOF

UnboundDir="${ConfigDir}/Unbound"
UnboundKeysDir="${UnboundDir}/Keys"
sudo mkdir -p "${UnboundDir}" "${UnboundKeysDir}"
sudo chmod 755 "${UnboundKeysDir}"

if curl --connect-timeout 10 -sSL "https://www.internic.net/domain/named.root" -o "${UnboundDir}/RootHints.tmp"; then
    if grep -q "A.ROOT-SERVERS.NET" "${UnboundDir}/RootHints.tmp"; then
        sudo touch "${UnboundDir}/RootHints.txt"
        sudo sh -c "cat '${UnboundDir}/RootHints.tmp' > '${UnboundDir}/RootHints.txt'"
        sudo rm -f "${UnboundDir}/RootHints.tmp"
    else
        sudo rm -f "${UnboundDir}/RootHints.tmp"
    fi
else
    sudo rm -f "${UnboundDir}/RootHints.tmp" || true
fi

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
    local-data: "${INTERNAL_DOMAIN} A 10.99.0.13"
EOF

ResolveImage() {
    local img=$1
    sudo docker pull "$img" >/dev/null 2>&1
    local digest=$(sudo docker inspect --format='{{index .RepoDigests 0}}' "$img" 2>/dev/null || echo "")
    if [[ -z "$digest" ]]; then echo "[FATAL] Failed to resolve SHA256 for $img."; exit 1; fi
    echo "$digest"
}

IMG_PROXY=$(ResolveImage "lscr.io/linuxserver/socket-proxy:latest")
IMG_TRAEFIK=$(ResolveImage "traefik:v2.11")
IMG_WG=$(ResolveImage "lscr.io/linuxserver/wireguard:latest")
IMG_PIHOLE=$(ResolveImage "pihole/pihole:latest")
IMG_UNBOUND=$(ResolveImage "mvance/unbound:latest")

sudo mkdir -p "${ConfigDir}/WireGuard" "${ConfigDir}/PiHole/etc-pihole" "${ConfigDir}/PiHole/etc-dnsmasq.d"

# ROUTE-07/08/09: Dynamic Assimilation Engine with Verbose STIG Explanations.
ScanForeignContainers() {
    if ! command -v docker &> /dev/null; then return; fi

    local foreign_containers
    foreign_containers=$(sudo docker ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' -v stack="${StackName,,}" 'tolower($2) != stack && $1 != "" {print $1}')

    if [ -n "$foreign_containers" ]; then
        PrintMsg "214" "========================================================================"
        PrintMsg "214" "ALIEN CONTAINERS DETECTED"
        PrintMsg "214" "Found containers operating outside the Sovereign Node perimeter."
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
                        gum confirm "Assimilate $container into the Sovereign Node?" && needs_update=1 || needs_update=0
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
                    PrintMsg "240" "     Behavior:    Traffic MUST originate from the WireGuard tunnel."
                    PrintMsg "240" "                  Instantly drops all public internet WAN traffic with a 403 Forbidden."
                    echo ""
                    PrintMsg "226" " [2] BasicAuth (Password Wall)"
                    PrintMsg "240" "     Middlewares: secure-headers@file, traefik-auth@file"
                    PrintMsg "240" "     Behavior:    Accessible from the public internet (if port 443 is forwarded),"
                    PrintMsg "240" "                  but strictly enforces your cryptographic HTTP Basic Authentication."
                    echo ""
                    PrintMsg "196" " [3] Fully Public (NO ARMOR - EXTREME DANGER)"
                    PrintMsg "240" "     Middlewares: secure-headers@file"
                    PrintMsg "240" "     Behavior:    Bare-metal exposure to the public internet. No IP whitelisting."
                    PrintMsg "240" "                  No passwords. Bots and scanners will hit this immediately."
                    echo ""
                    PrintMsg "244" " [4] Internal Backend (Completely Ignored)"
                    PrintMsg "240" "     Behavior:    Container is completely hidden from Traefik. Perfect for internal"
                    PrintMsg "240" "                  backend databases (Postgres, Redis) that do not need a domain."
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
# ==============================================================================
# POSTURE: Option $posture_choice
# MIDDLEWARES: $mw_string
# ==============================================================================
# INSTRUCTIONS:
# 1. Open the original docker-compose.yml file where '$container' is defined.
# 2. Add 'ProxyNetwork' to your bottom networks block.
# 3. Paste the networks and labels sections below into your service definition.
# 4. Replace <PORT> with the actual internal listening port of your application.
# 5. Re-run 'docker compose up -d' on your original stack.
# ==============================================================================

networks:
  ProxyNetwork:
    external: true
    name: SovereignNode_ProxyNetwork

services:
  $container:
    # ... existing image/volumes ...
    networks:
      - ProxyNetwork
      # - your_existing_internal_network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${clean_name}.rule=Host(\`${clean_name}.${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.${clean_name}.entrypoints=websecure"
      - "traefik.http.routers.${clean_name}.tls.certresolver=letsencrypt"
      - "traefik.http.services.${clean_name}.loadbalancer.server.port=<PORT>"
      - "traefik.http.routers.${clean_name}.middlewares=${mw_string}"
      - "traefik.docker.network=SovereignNode_ProxyNetwork"
MANIFEST_EOF
                PrintMsg "82" "✔ Manifest generated: ${manifest_dir}/${clean_name}_integration.yml"
            fi
        done
    fi
}

ScanForeignContainers

sudo tee "$ComposeFile" > /dev/null << EOF
networks:
  VpnNetwork:
    name: VpnNetwork
    ipam:
      config:
        - subnet: 10.99.0.0/24
  ProxyNetwork:
    name: SovereignNode_ProxyNetwork
    ipam:
      config:
        - subnet: 10.98.0.0/24
  SocketNetwork:
    name: SocketNetwork
    internal: true
    ipam:
      config:
        - subnet: 10.97.0.0/24

services:
  DockerSocketProxy:
    image: ${IMG_PROXY}
    container_name: DockerSocketProxy
    networks:
      - SocketNetwork
    environment:
      - TZ=UTC
      - CONTAINERS=1
      - NETWORKS=1
      - VERSION=1
      - EVENTS=1
      - PING=1
      - INFO=1
      - POST=0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:2375/version || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 2s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped

  TraefikProxy:
    image: ${IMG_TRAEFIK}
    container_name: Traefik
    networks:
      SocketNetwork:
      ProxyNetwork:
      VpnNetwork:
        ipv4_address: 10.99.0.13
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - SETUID
      - SETGID
      - CHOWN
    environment:
      - CF_DNS_API_TOKEN_FILE=/run/secrets/cf_api_token
    ports:
      - "0.0.0.0:80:80/tcp"
      - "0.0.0.0:443:443/tcp"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ${ConfigDir}/Traefik/TraefikConfig.yml:/etc/traefik/traefik.yml:ro
      - ${ConfigDir}/Traefik/dynamic:/etc/traefik/dynamic:ro
      - ${ConfigDir}/Traefik/acme.json:/acme.json:rw
      - ./Secrets/cf_api_token:/run/secrets/cf_api_token:ro
      - ./Secrets/traefik_auth:/run/secrets/traefik_auth:ro
    command:
      - "--providers.docker.version=1.44"
    depends_on:
      DockerSocketProxy:
        condition: service_healthy
      DnsSinkhole:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "traefik", "healthcheck", "--ping"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.api.rule=Host(\`traefik.${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.api.entrypoints=websecure"
      - "traefik.http.routers.api.tls.certresolver=letsencrypt"
      - "traefik.http.routers.api.service=api@internal"
      - "traefik.http.routers.api.middlewares=secure-headers@file,vpn-whitelist@file,traefik-auth@file"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped

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
      - SYS_MODULE
      - DAC_OVERRIDE
      - FOWNER
      - CHOWN
      - SETUID
      - SETGID
      - KILL
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
      - SERVERURL=${WG_ENDPOINT}
      - SERVERPORT=${WG_PORT}
      - PEERS=${WG_PEERS}
      - PEERDNS=10.99.0.12
      - INTERNAL_SUBNET=10.13.13.0/24
      - ALLOWEDIPS=0.0.0.0/0
      - LOG_CONFS=false
    volumes:
      - ${ConfigDir}/WireGuard:/config
      - /lib/modules:/lib/modules:ro
    ports:
      - "0.0.0.0:${WG_PORT}:51820/udp"
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    depends_on:
      DnsSinkhole:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wg", "show", "wg0"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
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
      ProxyNetwork:
    environment:
      - TZ=UTC
      - WEBPASSWORD_FILE=/run/secrets/pihole_pass
      - PIHOLE_DNS_=10.99.0.11#53
      - DNSSEC=false
      - DNS_BOGUS_PRIV=true
      - DNS_FQDN_REQUIRED=true
      - DNSMASQ_LISTENING=all
      - FTLCONF_webserver_api_password_FILE=/run/secrets/pihole_pass
      - FTLCONF_dns_upstreams=10.99.0.11#53
      - FTLCONF_dns_dnssec=false
      - FTLCONF_dns_bogusPriv=true
      - FTLCONF_dns_fqdnRequired=true
      - FTLCONF_webserver_domain=pihole.${INTERNAL_DOMAIN}
      - FTLCONF_dns_listeningMode=ALL
    volumes:
      - ./Secrets/pihole_pass:/run/secrets/pihole_pass:ro
      - ${ConfigDir}/PiHole/etc-pihole:/etc/pihole
      - ${ConfigDir}/PiHole/etc-dnsmasq.d:/etc/dnsmasq.d
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.pihole.rule=Host(\`pihole.${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.pihole.entrypoints=websecure"
      - "traefik.http.routers.pihole.tls.certresolver=letsencrypt"
      - "traefik.http.services.pihole.loadbalancer.server.port=80"
      - "traefik.docker.network=SovereignNode_ProxyNetwork"
      - "traefik.http.routers.pihole.middlewares=secure-headers@file,vpn-whitelist@file"
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - NET_RAW
      - NET_ADMIN
      - SYS_NICE
      - DAC_OVERRIDE
      - FOWNER
      - SYS_CHROOT
      - CHOWN
      - SETUID
      - SETGID
      - SETFCAP
      - IPC_LOCK
      - SYS_RESOURCE
      - AUDIT_WRITE
      - KILL
    depends_on:
      RecursiveDns:
        condition: service_healthy
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
      - ${ConfigDir}/Unbound/Keys:/opt/unbound/etc/unbound/keys:rw
    entrypoint: ["/bin/sh", "-c", "unbound-anchor -a /opt/unbound/etc/unbound/keys/root.key || if [ ! -s /opt/unbound/etc/unbound/keys/root.key ]; then echo '. IN DS 20326 8 2 e06d44b80b8f1d39a95c0b0d7c65d08458e880409bbc683457104237c7f8ec8d' > /opt/unbound/etc/unbound/keys/root.key; fi; chown -R _unbound:_unbound /opt/unbound/etc/unbound/keys /opt/unbound/var/run 2>/dev/null || chown -R unbound:unbound /opt/unbound/etc/unbound/keys /opt/unbound/var/run 2>/dev/null || true; exec /opt/unbound/sbin/unbound -d -c /opt/unbound/etc/unbound/unbound.conf"]
    healthcheck:
      test: ["CMD-SHELL", "drill ${INTERNAL_DOMAIN} @127.0.0.1 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped

  WhoamiTest:
    image: traefik/whoami:latest
    container_name: WhoamiTest
    networks:
      - ProxyNetwork
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.whoami.rule=Host(\`whoami.${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.whoami.entrypoints=websecure"
      - "traefik.http.routers.whoami.tls.certresolver=letsencrypt"
      - "traefik.http.routers.whoami.middlewares=secure-headers@file,traefik-auth@file"
    restart: unless-stopped
EOF

sudo chown 0:0 "$ComposeFile"
sudo chmod 600 "$ComposeFile"

if [ "$Interactive" -eq 0 ]; then
    cd "$BaseDir" && sudo docker compose --env-file Node.env up -d --remove-orphans
    if [ "$RotateSecret" -eq 1 ]; then sudo docker compose restart DnsSinkhole TraefikProxy; fi
elif [ "$Interactive" -eq 1 ]; then
    PrintMsg "82" "✔ Perimeter Staged."
    if [ "$RotateSecret" -eq 1 ]; then
        PrintMsg "196" "[WARNING] Cryptographic secrets rotated. Execute to flush daemons:"
        PrintMsg "196" "cd ${BaseDir} && sudo docker compose restart DnsSinkhole TraefikProxy"
    fi
fi
exit 0