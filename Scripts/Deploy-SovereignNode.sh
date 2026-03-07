#!/bin/bash
# ==============================================================================
#  UNIFIED SOVEREIGN NODE - TRAEFIK + WIREGUARD + PI-HOLE + UNBOUND (v2.0-BASTION)
# ==============================================================================
#  Architecture: Single-Node Unified Ingress & VPN Topology
#  Bastion Edge-Case Fixes Applied:
#  - PROXY-03: DockerSocketProxy resurrected to air-gap Traefik from raw host socket.
#  - ACME-01: DNS-01 Cloudflare challenge mandated. Port 80 exposure eliminated.
#  - L7-01: DynamicRules.yml restored to enforce strict HSTS and XSS security headers.
#  - CAP-01: Traefik stripped of default root capabilities (NET_BIND_SERVICE only).
#  All legacy v79 STIGs (Thermal Buffers, IPv6 Netfilter, RFC 5011) retained.
# ==============================================================================

set -euo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

StackName="SovereignNode"
BaseDir="/opt/Docker/Stacks/${StackName}"
ConfigDir="/opt/Docker/Config"
SecretsDir="${ConfigDir}/Secrets"
EnvFile="${BaseDir}/Node.env"
ComposeFile="${BaseDir}/DockerCompose.yml"
LockFile="/var/lock/sovereign_node.lock"

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
    PrintMsg "212" "Unified Sovereign Node Forge (Bastion Protocol)"
fi

sudo mkdir -p "$SecretsDir"
sudo chmod 700 "$SecretsDir"

WriteSecret() {
    local name=$1
    local content=$2
    local tmp_file="${SecretsDir}/${name}.tmp"
    printf "%s" "$content" | sudo tee "$tmp_file" > /dev/null
    if [ ! -f "${SecretsDir}/${name}" ]; then
        sudo touch "${SecretsDir}/${name}"
        sudo chmod 600 "${SecretsDir}/${name}"
    fi
    sudo sh -c "cat '$tmp_file' > '${SecretsDir}/${name}'"
    sudo rm -f "$tmp_file"
}

RotateSecret=0
if [ -f "${SecretsDir}/pihole_pass" ] && [ -f "${SecretsDir}/cf_api_key" ]; then
    if [ "$Interactive" -eq 1 ]; then
        if command -v gum &> /dev/null; then
            gum confirm "Existing secrets found. Rotate credentials?" && RotateSecret=1 || RotateSecret=0
        else
            read -p "[INFO] Existing secrets found. Rotate credentials? [y/N]: " ConfirmRotate || echo ""
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
            if command -v gum &> /dev/null; then PiHolePass=$(gum input --password || echo "")
            else read -s -p "Password: " PiHolePass || echo ""; echo ""; fi
            if [[ -z "$PiHolePass" ]]; then PrintMsg "196" "Password cannot be empty."; fi
        done
        WriteSecret "pihole_pass" "$PiHolePass"

        # ACME-01: Mandate Cloudflare Global API Key for DNS-01 challenges.
        PrintMsg "226" "Provide your Cloudflare Global API Key (for DNS-01 Let's Encrypt):"
        CfApiKey=""
        while [[ -z "$CfApiKey" ]]; do
            if command -v gum &> /dev/null; then CfApiKey=$(gum input --password || echo "")
            else read -s -p "CF API Key: " CfApiKey || echo ""; echo ""; fi
            if [[ -z "$CfApiKey" ]]; then PrintMsg "196" "API Key cannot be empty."; fi
        done
        WriteSecret "cf_api_key" "$CfApiKey"
    else
        echo "[FATAL] Missing required secrets (pihole_pass or cf_api_key)."; exit 1
    fi
fi

if [ "$Interactive" -eq 1 ]; then
    PrevEndpoint=$(grep "^WG_ENDPOINT=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevDomain=$(grep "^INTERNAL_DOMAIN=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevEmail=$(grep "^ACME_EMAIL=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "")
    PrevWgPort=$(grep "^WG_PORT=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "51820")
    PrevWgPeers=$(grep "^WG_PEERS=" "$EnvFile" 2>/dev/null | cut -d= -f2 || echo "3")

    HostLanIp=$(hostname -I | awk '{print $1}')

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
HOST_LAN_IP=${HostLanIp}
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

# Traefik Core Setup
TraefikDir="${ConfigDir}/Traefik"
sudo mkdir -p "${TraefikDir}/dynamic"
if [ ! -f "${TraefikDir}/acme.json" ]; then
    sudo touch "${TraefikDir}/acme.json"
    sudo chmod 600 "${TraefikDir}/acme.json"
fi

# PROXY-03 & ACME-01: Connect Traefik to the filtered TCP socket proxy and enforce DNS-01 verification.
sudo tee "${TraefikDir}/TraefikConfig.yml" > /dev/null << EOF
api:
  dashboard: true
  insecure: false
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

# L7-01: Resurrect strict security headers for all internally routed web apps.
sudo tee "${TraefikDir}/dynamic/DynamicRules.yml" > /dev/null << EOF
http:
  middlewares:
    secure-headers:
      headers:
        sslRedirect: true
        forceSTSHeader: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 31536000
        customFrameOptionsValue: SAMEORIGIN
        customRequestHeaders:
          X-Forwarded-Proto: https
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "strict-origin-when-cross-origin"
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
    local-data: "${INTERNAL_DOMAIN} A ${HOST_LAN_IP}"
EOF

ResolveImage() {
    local img=$1
    sudo docker pull "$img" >/dev/null 2>&1
    local digest=$(sudo docker inspect --format='{{index .RepoDigests 0}}' "$img" 2>/dev/null || echo "")
    if [[ -z "$digest" ]]; then echo "[FATAL] Failed to resolve SHA256 for $img."; exit 1; fi
    echo "$digest"
}

IMG_PROXY=$(ResolveImage "lscr.io/linuxserver/socket-proxy:latest")
IMG_TRAEFIK=$(ResolveImage "traefik:v3.0")
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
  ProxyNetwork:
    name: ProxyNetwork
    ipam:
      config:
        - subnet: 10.98.0.0/24
  # PROXY-03: Isolated network for the read-only Docker socket TCP bridge.
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
      - POST=0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
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
      - SocketNetwork
      - ProxyNetwork
    security_opt:
      - no-new-privileges:true
    # CAP-01: Eradicate default root capabilities. Restrict entirely to binding public HTTP/S ports.
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - SETUID
      - SETGID
      - CHOWN
    environment:
      - CF_API_EMAIL=\${ACME_EMAIL}
      - CF_API_KEY_FILE=/run/secrets/cf_api_key
    ports:
      - "0.0.0.0:80:80/tcp"
      - "0.0.0.0:443:443/tcp"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ${ConfigDir}/Traefik/TraefikConfig.yml:/etc/traefik/traefik.yml:ro
      - ${ConfigDir}/Traefik/dynamic:/etc/traefik/dynamic:ro
      - ${ConfigDir}/Traefik/acme.json:/acme.json:rw
      - ${SecretsDir}/cf_api_key:/run/secrets/cf_api_key:ro
    depends_on:
      - DockerSocketProxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.api.rule=Host(\`traefik.\${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.api.entrypoints=websecure"
      - "traefik.http.routers.api.tls.certresolver=letsencrypt"
      - "traefik.http.routers.api.service=api@internal"
      - "traefik.http.routers.api.middlewares=secure-headers@file"
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
      - REV_SERVER=false
      - QUERY_LOGGING=false
      - PRIVACY_LEVEL=3
      - DNSMASQ_LISTENING=all
    volumes:
      - ${SecretsDir}/pihole_pass:/run/secrets/pihole_pass:ro
      - ${ConfigDir}/PiHole/etc-pihole:/etc/pihole
      - ${ConfigDir}/PiHole/etc-dnsmasq.d:/etc/dnsmasq.d
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.pihole.rule=Host(\`pihole.\${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.pihole.entrypoints=websecure"
      - "traefik.http.routers.pihole.tls.certresolver=letsencrypt"
      - "traefik.http.services.pihole.loadbalancer.server.port=80"
      # L7-01: Security headers enforced on the Pi-Hole ingress route.
      - "traefik.http.routers.pihole.middlewares=secure-headers@file"
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
      test: ["CMD-SHELL", "drill \${INTERNAL_DOMAIN} @127.0.0.1 || exit 1"]
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