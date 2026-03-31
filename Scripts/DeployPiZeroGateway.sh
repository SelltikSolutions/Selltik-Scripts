#!/bin/bash
# ==============================================================================
#  SOVEREIGN GATEWAY - WIREGUARD + PI-HOLE + UNBOUND (NODE A)
#  Version: v79.2-SPLIT-HORIZON-ACTUAL
# ==============================================================================
#  Architecture: Dedicated Cryptographic Entry & DNS Sinkhole
#  Split-Horizon Fixes:
#  - ROUTE-01: Brutally amputated all Traefik labels from Pi-Hole. Traefik 
#              resides on Node B and cannot read Node A's docker socket.
#  - NET-02: Eradicated the phantom 'sovereign_node_proxy_network'. The Pi 
#            Zero operates strictly within the 'vpn_network' boundary.
#  - IAM-01: Excised Postgres, Authelia, and Traefik containers. Node A 
#            is now a dedicated, lightweight perimeter gateway.
# ==============================================================================

set -euo pipefail

# Ghost Directory Escape
cd /tmp || true
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

StackName="PiZeroGateway"
BaseDir="/opt/Docker"
ConfigDir="${BaseDir}/Config"
ScriptsDir="${BaseDir}/Scripts"
StackDir="${BaseDir}/Stacks/${StackName}"
SecretsDir="${StackDir}/Secrets"
LogsDir="/opt/Docker/Logs/${StackName}"

ComposeFile="${StackDir}/docker-compose.yml"
EnvFile="${StackDir}/.env"
LockFile="/var/lock/pizero_gateway.lock"

exec 200>"$LockFile"
flock -n 200 || { echo "[FATAL] Another deployment instance is running."; exit 1; }
[ "$EUID" -eq 0 ] || { echo "[FATAL] Elevated privileges required. Run with: sudo $0"; exit 1; }

Interactive=$([ -t 0 ] && echo 1 || echo 0)

PrintMsg() {
    local color=$1
    local msg=$2
    echo -e "\033[1;33m$msg\033[0m"
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

    if [[ "$OS_FAMILY" == *"debian"* ]] || [[ "$OS_ID" == "parrot" ]] || [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_ID" == "raspbian" ]]; then
        PkgManager="apt-get"
        UpdateCmd="apt-get update -y -q"
        InstallCmd="DEBIAN_FRONTEND=noninteractive apt-get install -y -q"
    else
        echo "[FATAL] Unsupported OS Family for Pi Zero Gateway: $OS_FAMILY."; exit 1
    fi
}

CheckDependencies() {
    PrintMsg "240" "Verifying baseline tools for $OS_ID..."
    eval "$UpdateCmd" > /dev/null 2>&1 || true
    
    local pkgs_to_install=""
    for bin in curl jq openssl wget qrencode; do
        if ! command -v "$bin" &> /dev/null; then
            pkgs_to_install="$pkgs_to_install $bin"
        fi
    done

    if [ ! -d "/usr/share/zoneinfo" ]; then pkgs_to_install="$pkgs_to_install tzdata"; fi
    if ! command -v crontab &> /dev/null; then pkgs_to_install="$pkgs_to_install cron"; fi
    if ! command -v dig &> /dev/null; then pkgs_to_install="$pkgs_to_install dnsutils"; fi

    for pkg in $pkgs_to_install; do
        if [ -n "$pkg" ]; then
            PrintMsg "226" "Installing missing dependency: $pkg"
            eval "$InstallCmd $pkg" > /dev/null 2>&1 || { PrintMsg "196" "[FATAL] Failed: $pkg"; exit 1; }
        fi
    done

    if ! command -v docker &> /dev/null; then
        PrintMsg "214" "Docker Engine missing. Initiating provision..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh > /dev/null 2>&1
        rm -f get-docker.sh
    fi
}

DetectOsFamily
CheckDependencies

ExecuteAnnihilation() {
    if [ "$Interactive" -eq 1 ] && [ -d "$StackDir" ]; then
        PrintMsg "196" "========================================================================"
        PrintMsg "196" " 🔥 TRUE SCORCHED EARTH PROTOCOL (GATEWAY ONLY)"
        PrintMsg "196" "========================================================================"
        read -p "OBLITERATE EXISTING GATEWAY STATE? (y/N): " input_conf || true
        if [[ "${input_conf:-}" =~ ^[Yy]$ ]]; then
            PrintMsg "196" "Executing tactical nuke..."
            cd "$StackDir" || true
            if [ -f "$ComposeFile" ]; then sudo docker compose down -v --remove-orphans > /dev/null 2>&1 || true; fi
            sudo docker rm -f unbound_dns pihole_sinkhole wireguard_vpn >/dev/null 2>&1 || true
            cd /tmp
            sudo rm -rf "$StackDir" "${ConfigDir}/WireGuard" "${ConfigDir}/PiHole" "${ConfigDir}/Unbound"
            PrintMsg "82" "✔ Gateway scorched."
            sleep 2
        else
            PrintMsg "82" "✔ Scorched Earth aborted."
        fi
    fi
}

ExecuteAnnihilation

PrintMsg "240" "Forging STIG-compliant host kernel armor..."
sudo tee /etc/sysctl.d/99-PiZeroGateway.conf > /dev/null << 'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system > /dev/null 2>&1 || true

sudo mkdir -p "$StackDir" "$LogsDir" "$ScriptsDir" \
             "$ConfigDir/WireGuard" "$ConfigDir/PiHole/etc-pihole" \
             "$ConfigDir/PiHole/etc-dnsmasq.d" "$ConfigDir/Unbound"

for OrphanFile in "${ConfigDir}/Unbound/UnboundConfig.conf" "${ConfigDir}/Unbound/RootHints.txt" "$ComposeFile"; do
    if [ -d "$OrphanFile" ]; then sudo rm -rf "$OrphanFile"; fi
done

sudo mkdir -p "$SecretsDir"
sudo chmod 700 "$SecretsDir"
echo "*" | sudo tee "${SecretsDir}/.gitignore" > /dev/null

WriteSecret() {
    local name=$1
    local content=$2
    local tmp_file="${SecretsDir}/${name}.tmp"
    printf "%s" "$content" | sudo tee "$tmp_file" > /dev/null
    if [ ! -f "${SecretsDir}/${name}" ]; then sudo touch "${SecretsDir}/${name}"; fi
    sudo chmod 644 "${SecretsDir}/${name}"
    sudo sh -c "cat '$tmp_file' > '${SecretsDir}/${name}'"
    sudo rm -f "$tmp_file"
}

[ ! -f "${SecretsDir}/pihole_pass" ] && WriteSecret "pihole_pass" "$(openssl rand -hex 16)"

if [ "$Interactive" -eq 1 ]; then
    PrevEndpoint=$(grep "^WG_ENDPOINT=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevPort=$(grep "^WG_PORT=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "51820")
    PrevPeers=$(grep "^WG_PEERS=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "3")

    read -p "WireGuard Public Endpoint (IP/DDNS) [$PrevEndpoint]: " input_endpoint || true
    WgEndpoint="${input_endpoint:-$PrevEndpoint}"
    
    read -p "WireGuard UDP Listen Port [$PrevPort]: " input_port || true
    WgPort="${input_port:-$PrevPort}"
    
    read -p "WireGuard Peer Count [$PrevPeers]: " input_peers || true
    WgPeers="${input_peers:-$PrevPeers}"

    sudo tee "$EnvFile" > /dev/null << EOF
WG_ENDPOINT=${WgEndpoint}
WG_PORT=${WgPort}
WG_PEERS=${WgPeers}
TZ=UTC
EOF
    sudo chmod 600 "$EnvFile"
fi

if [ ! -f "$EnvFile" ]; then
    PrintMsg "196" "[FATAL] Execution state demands a sourced environment, but $EnvFile is missing. Halting."
    exit 1
fi

source "$EnvFile"

sudo curl -sS --connect-timeout 10 https://www.internic.net/domain/named.root -o "${ConfigDir}/Unbound/RootHints.txt.tmp" || true
if grep -q "A.ROOT-SERVERS.NET" "${ConfigDir}/Unbound/RootHints.txt.tmp" 2>/dev/null; then
    sudo mv "${ConfigDir}/Unbound/RootHints.txt.tmp" "${ConfigDir}/Unbound/RootHints.txt"
else
    sudo tee "${ConfigDir}/Unbound/RootHints.txt" > /dev/null << 'EOF'
.                        3600000      NS    A.ROOT-SERVERS.NET.
A.ROOT-SERVERS.NET.      3600000      A     198.41.0.4
EOF
    sudo rm -f "${ConfigDir}/Unbound/RootHints.txt.tmp"
fi

sudo tee "${ConfigDir}/Unbound/UnboundConfig.conf" > /dev/null << EOF
server:
  num-threads: 1
  interface: 0.0.0.0
  port: 53
  do-ip4: yes
  do-udp: yes
  do-tcp: yes
  root-hints: "/opt/unbound/etc/unbound/root.hints"
  auto-trust-anchor-file: "/opt/unbound/etc/unbound/keys/root.key"
  chroot: ""
  harden-glue: yes
  harden-dnssec-stripped: yes
  use-caps-for-id: no
  edns-buffer-size: 1232
  prefetch: yes
  num-queries-per-thread: 4096
  rrset-roundrobin: yes
  minimal-responses: yes
  hide-identity: yes
  hide-version: yes
  access-control: 127.0.0.0/8 allow
  access-control: 10.99.0.0/24 allow
EOF

ResolveImage() {
    local digest=$(sudo docker inspect --format='{{index .RepoDigests 0}}' "$1" 2>/dev/null || echo "")
    [[ -z "$digest" ]] && { sudo docker pull "$1" >/dev/null; sudo docker inspect --format='{{index .RepoDigests 0}}' "$1"; } || echo "$digest"
}

IMG_WG=$(ResolveImage "lscr.io/linuxserver/wireguard:latest")
IMG_PIHOLE=$(ResolveImage "pihole/pihole:latest")
IMG_UNBOUND=$(ResolveImage "mvance/unbound:latest")

sudo tee "$ComposeFile" > /dev/null << EOF
networks:
  vpn_network:
    name: pizerogateway_vpn_network
    ipam: { config: [{ subnet: 10.99.0.0/24 }] }

volumes:
  unbound_keys: {}

secrets:
  pihole_pass: { file: ${SecretsDir}/pihole_pass }

x-logging: &default-logging
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "3"

services:
  unbound_dns:
    image: ${IMG_UNBOUND}
    container_name: unbound_dns
    init: true
    networks:
      vpn_network: { ipv4_address: 10.99.0.11 }
    volumes:
      - ${ConfigDir}/Unbound/UnboundConfig.conf:/opt/unbound/etc/unbound/unbound.conf:ro
      - ${ConfigDir}/Unbound/RootHints.txt:/opt/unbound/etc/unbound/root.hints:ro
      - unbound_keys:/opt/unbound/etc/unbound/keys:rw
    entrypoint: ["/bin/sh", "-c", "unbound-anchor -a /opt/unbound/etc/unbound/keys/root.key || true; chown -R unbound:unbound /opt/unbound/etc/unbound/keys 2>/dev/null || true; exec /opt/unbound/sbin/unbound -d -c /opt/unbound/etc/unbound/unbound.conf"]
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE, SETGID, SETUID, CHOWN, DAC_OVERRIDE]
    security_opt: [no-new-privileges:true]
    logging: *default-logging
    restart: unless-stopped

  pihole_sinkhole:
    image: ${IMG_PIHOLE}
    container_name: pihole_sinkhole
    networks:
      vpn_network: { ipv4_address: 10.99.0.12 }
    ports:
      # ROUTE-01: Expose port 80 to the host so Node B (Traefik Monolith) can route to it over the physical LAN
      - "0.0.0.0:80:80/tcp"
    environment:
      - WEBPASSWORD_FILE=/run/secrets/pihole_pass
      - PIHOLE_DNS_=10.99.0.11#53
      - DNSMASQ_LISTENING=all
    secrets: [pihole_pass]
    volumes:
      - ${ConfigDir}/PiHole/etc-pihole:/etc/pihole
      - ${ConfigDir}/PiHole/etc-dnsmasq.d:/etc/dnsmasq.d
    depends_on:
      - unbound_dns
    cap_drop: [ALL]
    cap_add: [NET_ADMIN, NET_BIND_SERVICE, NET_RAW, CHOWN, SETUID, SETGID, DAC_OVERRIDE, SYS_CHROOT, SYS_NICE]
    logging: *default-logging
    restart: unless-stopped

  wireguard_vpn:
    image: ${IMG_WG}
    container_name: wireguard_vpn
    networks:
      vpn_network: { ipv4_address: 10.99.0.10 }
    environment:
      - SERVERURL=\${WG_ENDPOINT}
      - SERVERPORT=\${WG_PORT}
      - PEERS=\${WG_PEERS}
      - PEERDNS=10.99.0.12
      - INTERNAL_SUBNET=10.13.13.0/24
    volumes:
      - /lib/modules:/lib/modules:ro
      - ${ConfigDir}/WireGuard:/config
    ports: ["0.0.0.0:\${WG_PORT}:\${WG_PORT}/udp"]
    sysctls:
      net.ipv4.ip_forward: 1
      net.ipv4.conf.all.src_valid_mark: 1
    cap_drop: [ALL]
    cap_add: [NET_ADMIN, SYS_MODULE, NET_RAW, CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER]
    logging: *default-logging
    restart: unless-stopped
EOF

sudo chown -R 0:0 "$StackDir"
sudo chmod 600 "$ComposeFile" "$EnvFile"

if [ "$Interactive" -eq 1 ]; then PrintMsg "226" "Igniting Pi Zero Gateway..."; fi
cd "$StackDir" && sudo docker compose up -d --force-recreate --remove-orphans

if [ "$Interactive" -eq 1 ]; then
    echo ""
    PiholePass=$(sudo cat "${SecretsDir}/pihole_pass")
    PrintMsg "214" "========================================================================"
    PrintMsg "82"  " Pi-Hole Admin Password: $PiholePass"
    PrintMsg "196" " SAVE THIS NOW. IT WILL NOT BE DISPLAYED AGAIN."
    PrintMsg "214" "========================================================================"
    echo ""
    PrintMsg "196" " ⚠️  WIREGUARD ONBOARDING"
    PrintMsg "226" " Retrieve your cryptographic VPN payload natively by running:"
    PrintMsg "196" " sudo qrencode -t ansiutf8 < ${ConfigDir}/WireGuard/peer1/peer1.conf"
    PrintMsg "214" "========================================================================"
    echo ""
    PrintMsg "82" "✔ Pi Zero Gateway Online."
fi

exit 0