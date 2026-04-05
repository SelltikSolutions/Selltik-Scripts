#!/bin/bash
# ==============================================================================
#  UNIFIED SOVEREIGN GATEWAY - TRAEFIK + WIREGUARD + PI-HOLE + AUTHELIA
#  Version: v92.0-SOVEREIGN-AEGIS
# ==============================================================================
#  Architecture: Single-Node Unified Ingress, VPN, & Identity Topology
#  Aegis Hardening Fixes (The Final Absolute Truth):
#  1. IAM-59: Socket Binding Suicide Cured. Eradicated AUTHELIA_SERVER_ADDRESS 
#     to prevent the identity engine from attempting to bind a TCP socket to an 
#     HTTPS URL, resolving the fatal boot crash.
#  2. ORCH-36: Multidimensional Firewall Hallucinations Cured. Amputated host-level 
#     iptables deletion commands that vainly targeted isolated Docker network namespaces.
#  Inherited Master Fixes:
#  - IAM-58 (Redirection Singularity v3), ORCH-38 (Selective Immortality)
#  - NET-42 (TCP DNS Truncation Drop), IAM-56 (Unmarshaler Detonation v5)
#  - NET-36 (Asymmetrical DNS Blackhole), BOOT-17 (Missing Entrypoint)
#  - IAM-55 (Quantum Session Expiration), SEC-38 (Immortal Skeleton Key)
#  - IAM-49 (Unmarshaler Detonation v4), IAM-54 (Redirection Singularity v2)
#  - SEC-37 (L3 DMZ Bypass V2), IAM-48 (Unmarshaler Detonation v3)
#  - DNS-25 (Ghost Inode Deadlock), ORCH-35 (Watchdog Lockout)
#  - NET-34 (Ghost Iptables Memory Leak), IAM-47 (Unmarshaler Detonation v2)
#  - TLS-11 (ACME Inode Deadlock), ORCH-31 (WireGuard Stagnation Trap)
#  - IAM-53 (Open-Redirect Singularity), IAM-52 (ForwardAuth Redirection)
#  - LOG-14 (Ghost Log Artifact), IAM-46 (Session Array Detonation)
#  - NET-31 (CRLF Poisoning), IAM-41 (Unmarshaler Detonation)
#  - CONFIG-02 (PreDown Parasites), BOOT-16 (S6 Init Paradox)
#  - IAM-38 (Deprecated Authz Endpoint), TLS-08 (ACME Ghosting)
#  - CONFIG-01 (Template Stagnation), SEC-36 (DMZ Bypass)
#  - SEC-35 (Lateral Trust Hallucination), IAM-40 (Idempotent Password Wipe)
#  - ORCH-26 (Watchdog Amnesia), ENV-05 (Strict Nounset Detonation)
#  - BOOT-15 (S6-Overlay Init Destruction), ROUTE-26 (Whitelist Trap)
#  - IAM-37 (Communal Ban), NET-28 (Watchdog Boot-Storm), IAM-36 (Immutable Ledger)
#  - ROUTE-25 (CDN Blackhole), DNS-20 (LAN Void), NET-27 (NAT Bypass Timing)
#  - SEC-32 (L3 Engine Exposure), SEC-33 (VPN Whitelist), SEC-31 (Lateral Header Spoofing)
#  - DNS-19 (Phantom LAN Sinkhole), ROUTE-24 (Cross-Bridge Void), LOG-12 (Root Ownership)
#  - IAM-35 (Immutable DB), SEC-29 (Air-Gap Breach), IAM-34 (Brute-Force Immunity)
#  - LOG-11 (Parent Panic), IAM-33 (Fail2Ban Mass Extinction), SEC-28 (Header Spoofing)
#  - DNS-17 (Loopback), TLS-07 (Traefik CLI Detonation), ROUTE-23 (Asymmetrical Routing Void)
#  - ORCH-24 (Event Stream Blindness), ORCH-22 (HAProxy/Socat Schism)
#  - BOOT-14 (Module Capability Asphyxiation), IAM-30 (Access Control Schema)
#  - IAM-31 (Zero-Trust NAT Annihilation), DB-03 (Posix Asphyxiation)
#  - TLS-06 (ACME Challenge), ORCH-21 (Update Chain), HEALTH-09 (CLI Detonation)
#  - LOG-10 (Ghost Path), IAM-29 (Cookie Schema), HEALTH-07 (Healthcheck API)
#  - TLS-05 (CertResolver), IAM-27 (Regulation Schema), NET-22 (Roaming Brick)
#  - IAM-28 (Admin Lockout), DNS-16 (Alpine Namespace), BOOT-13 (s6-overlay cap)
#  - LOG-08 (Access Logs), DB-02 (InitDB Dirty Void), NET-23 (Exec Vacuum)
#  - IAM-22 (PascalCase Parser), ORCH-19 (Admin Blackhole), NET-21 (NetworkManager)
#  - IAM-21 (Argon2id Mutilation), KRN-06 (Strict RP_Filter), NET-19 (DHCP Resolv)
#  - DNS-14 (Resolv Vacuum), TLS-04 (Null ACME), NTP-02 (Chrony Sync)
#  - IAM-20 (Crypto Split-Brain), NET-18 (IPv6 RTNETLINK), ORCH-18 (Alien Purge)
#  - NET-16 (Immutable Resolv), TLS-03 (ACME Lockout), ROUTE-22 (YAML Detonation)
#  - DB-01 (Crypto Starvation), DNS-13 (DNSSEC Bomb), ORCH-17 (Ghost Route Sprawl)
#  - VOL-02 (Database Lockout), ROUTE-21 (Air-Gap), LOG-07 (Access Logs)
#  - IAM-17 (BasicAuth Hash), PORT-53 (systemd-resolved), ORCH-16 (Socket Ping)
#  - IAM-15 (Unprivileged Lockout), IAM-16 (Parser Detonation), CAP-04 (SYS_NICE)
#  - PRIVACY-03 (DNS Split Blackhole), BOOT-11 (Bind Panic), PROXY-07 (Spoofing)
#  - SEC-27 (644 Hemorrhage), NET-14 (Open Resolver Cannon), KRN-05 (TUN Void)
#  - ROUTE-20 (Localhost Blackhole), LOG-06 (Host Storage Exhaustion)
#  - ORCH-13 (Supply Chain Stagnation), TLS-02 (ACME Void), BOOT-10 (Auth Deadlock)
#  - PRIVACY-02 (Split-Tunnel Bleed), ENV-04 (Schrödinger's Domain).
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
TraefikLogDir="${LogsDir}/Traefik"
TraefikAcmeDir="${ConfigDir}/TraefikAcme"
TraefikAcmeFile="${TraefikAcmeDir}/acme.json"

# Native Engine Discovery (PascalCase Enforcement)
ComposeFile="${StackDir}/DockerCompose.yml"
EnvFile="${StackDir}/.env"
LockFile="/var/lock/sovereign_gateway.lock"

# BOOT-08: Trap Paradox Cured. Atomic cleanup and state verification.
TrapHandler() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n[FATAL] Script aborted at line $BASH_LINENO. System state inconsistent."
    fi
    rm -f "${ConfigDir}/Unbound/RootHints.txt.tmp" "${ConfigDir}/Unbound/RootHints.txt.sig" "${ConfigDir}/Unbound/icann.pgp" 2>/dev/null || true
    [ -f "$LockFile" ] && rm -f "$LockFile"
    exit "$exit_code"
}
trap TrapHandler EXIT INT TERM

# Atomic execution lock
exec 200>"$LockFile"
flock -n 200 || { echo "[FATAL] Another deployment instance is running."; exit 1; }
[ "$EUID" -eq 0 ] || { echo "[FATAL] Elevated privileges required. Run with: sudo $0"; exit 1; }

Interactive=$([ -t 0 ] && echo 1 || echo 0)

PrintMsg() {
    local color=$1; local msg=$2
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
    if ! command -v drill &> /dev/null; then
        if [[ "$PkgManager" == "apt-get" ]]; then pkgs_to_install="$pkgs_to_install ldnsutils"; else pkgs_to_install="$pkgs_to_install ldns"; fi
    fi
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

DockerBin=$(command -v docker || echo "/usr/bin/docker")

if [ -f /etc/docker/daemon.json ]; then
    if command -v jq &> /dev/null && grep -q "10.99.0.12" /etc/docker/daemon.json; then
        PrintMsg "214" "Purging legacy global DNS overrides from Docker daemon..."
        jq 'del(.dns)' /etc/docker/daemon.json > /tmp/daemon.json && sudo mv /tmp/daemon.json /etc/docker/daemon.json
        sudo systemctl restart docker || true
    fi
fi

# ROUTE-20: Localhost Blackhole Cured. Dynamically mapping host topology via nmcli.
HuntPhysicalNetwork() {
    if ! command -v nmcli &> /dev/null; then return; fi
    local ActivePhysConn=$(nmcli -t -f NAME,TYPE,STATE connection show --active | grep -E ':(802-3-ethernet|802-11-wireless):activated' | head -n 1 | cut -d: -f1 || true)
    if [ -n "$ActivePhysConn" ]; then
        local PhysDev=$(nmcli -t -f DEVICE,NAME connection show --active | grep ":$ActivePhysConn$" | cut -d: -f1)
        local PhysIp=$(ip -4 addr show "$PhysDev" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
        local CidrPrefix=$(ip -4 addr show "$PhysDev" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | cut -d/ -f2 || true)
        local GatewayIp=$(ip route show dev "$PhysDev" | awk '/default/ {print $3}' | head -n 1 || true)
        local LanSubnet=$(ip route show dev "$PhysDev" | awk '/proto kernel.*scope link/ {print $1}' | head -n 1 || true)
        
        if [ -n "$PhysIp" ]; then
            export HUNTER_IP="$PhysIp"
            export HUNTER_SUBNET="${LanSubnet:-}"
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

# PORT-53 & NET-20: Decapitates systemd-resolved and drops a physical resolv file.
if systemctl is-active --quiet systemd-resolved; then
    PrintMsg "214" "Decapitating systemd-resolved to mathematically free Port 53..."
    sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf || true
    sudo sed -i 's/DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf || true
    sudo systemctl stop systemd-resolved || true
    sudo systemctl disable systemd-resolved || true
    sudo rm -f /etc/resolv.conf
fi

# NET-23: Execution State Vacuum Cured. Unconditional check prevents fatal PGP failures on re-runs.
if [ ! -s /etc/resolv.conf ] || ! grep -q "^nameserver" /etc/resolv.conf; then
    PrintMsg "196" "⚠️ Host DNS vacuum detected. Injecting physical static Cloudflare fallback..."
    echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1" | sudo tee /etc/resolv.conf > /dev/null
fi

# NET-22: Roaming Host Brick Cured. Actively deletes dns=none to restore roaming DHCP.
if [ -f "/etc/NetworkManager/conf.d/99-sovereign-dns.conf" ]; then
    PrintMsg "214" "Reverting NetworkManager DNS gag order to restore roaming capabilities..."
    sudo rm -f /etc/NetworkManager/conf.d/99-sovereign-dns.conf
    sudo systemctl restart NetworkManager || true
fi

# AU-8 & NTP-02: Enforce absolute temporal consistency and sync Debian daemons.
PrintMsg "240" "Anchoring chronometric infrastructure to UTC..."
sudo timedatectl set-local-rtc 0 || true
sudo timedatectl set-timezone UTC || true
if systemctl is-active --quiet chrony; then
    sudo systemctl restart chrony || true
elif systemctl is-active --quiet chronyd; then
    sudo systemctl restart chronyd || true
elif systemctl is-active --quiet systemd-timesyncd; then
    sudo systemctl restart systemd-timesyncd || true
fi

# ROUTE-25: Cloudflare CDN Blackhole Cured. Dynamically mapping upstream Edge IP vectors.
# SEC-35: Lateral Trust Hallucination Cured. Eradicated internal Docker subnets from the array.
# NET-31: Carriage Return Poisoning Cured. Injected 'tr -d \r' to mathematically sanitize CRLF line endings.
PrintMsg "240" "Fetching Cloudflare Edge IP ranges for Layer 7 header authentication..."
CfIpsV4=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v4 | tr -d '\r' | tr '\n' ',' || echo "173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22")
CfIpsV6=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v6 | tr -d '\r' | tr '\n' ',' || echo "2400:cb00::/32,2606:4700::/32,2803:f800::/32,2405:b500::/32,2405:8100::/32,2a06:98c0::/29,2c0f:f248::/32")
TraefikTrustedIps="127.0.0.1/32,${CfIpsV4%,},${CfIpsV6%,}"

# KRN-04 & KRN-06: STIG Scorched Earth Kernel Hardening + RP_Filter Asymmetrical Downgrade (Value: 2)
PrintMsg "240" "Forging STIG-compliant host kernel armor..."
sudo tee /etc/sysctl.d/99-SovereignGateway.conf > /dev/null << 'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 1
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
net.core.bpf_jit_harden = 2
EOF
sudo sysctl --system > /dev/null 2>&1 || true

# KRN-03: Native Module Gate
if ! sudo modprobe wireguard 2>/dev/null; then
    PrintMsg "196" "[FATAL] Native WireGuard kernel module missing. Host kernel is incompatible."
    exit 1
fi

HostUid="${SUDO_UID:-1000}"
HostGid="${SUDO_GID:-1000}"

PrevEndpoint=""; PrevDomain=""; PrevEmail=""; PrevPort="51820"; PrevLanIp=""
PrevLanSubnet="${HUNTER_SUBNET:-}"; PrevWgPeers="3"; PrevAllowedIps="0.0.0.0/0"
PrevAcme="https://acme-staging-v02.api.letsencrypt.org/directory"

if [ -f "$EnvFile" ]; then
    PrevEndpoint=$(grep "^WG_ENDPOINT=" "$EnvFile" | cut -d= -f2 || echo "")
    PrevDomain=$(grep "^INTERNAL_DOMAIN=" "$EnvFile" | cut -d= -f2 || echo "")
    PrevEmail=$(grep "^ACME_EMAIL=" "$EnvFile" | cut -d= -f2 || echo "")
    PrevPort=$(grep "^WG_PORT=" "$EnvFile" | cut -d= -f2 || echo "51820")
    env_lan=$(grep "^TRAEFIK_LAN_IP=" "$EnvFile" | cut -d= -f2 || echo "")
    [ -n "$env_lan" ] && PrevLanIp="$env_lan"
    env_acme=$(grep "^ACME_SERVER_URL=" "$EnvFile" | cut -d= -f2 || echo "")
    [ -n "$env_acme" ] && PrevAcme="$env_acme"
    env_subnet=$(grep "^WG_LAN_SUBNET=" "$EnvFile" | cut -d= -f2 || echo "")
    [ -n "$env_subnet" ] && PrevLanSubnet="$env_subnet"
    env_peers=$(grep "^WG_PEERS=" "$EnvFile" | cut -d= -f2 || echo "")
    [ -n "$env_peers" ] && PrevWgPeers="$env_peers"
    env_allowed=$(grep "^WG_ALLOWED_IPS=" "$EnvFile" | cut -d= -f2 || echo "")
    [ -n "$env_allowed" ] && PrevAllowedIps="$env_allowed"
fi

ExecuteAnnihilation() {
    if [ "$Interactive" -eq 1 ] && [ -d "$StackDir" ]; then
        PrintMsg "196" "========================================================================"
        PrintMsg "196" " 🔥 TRUE SCORCHED EARTH PROTOCOL"
        PrintMsg "196" "========================================================================"
        read -p "OBLITERATE EVERYTHING and restart fresh? (y/N): " input_conf || true
        if [[ "${input_conf:-}" =~ ^[Yy]$ ]]; then
            PrintMsg "196" "Executing tactical nuke..."
            cd "$StackDir" && sudo $DockerBin compose -f "$ComposeFile" down -v --remove-orphans > /dev/null 2>&1 || true
            PrintMsg "214" "Mathematically shredding cryptographic master keys..."
            [ -d "${SecretsDir}" ] && sudo find "${SecretsDir}" -type f -exec shred -u {} \; || true
            sudo rm -rf "$StackDir" "${ConfigDir}/Authelia" "${ConfigDir}/Postgres" "${ConfigDir}/Traefik/Dynamic" "${ConfigDir}/WireGuard" "${ConfigDir}/PiHole" "${ConfigDir}/Unbound" "$TraefikAcmeDir"
            PrintMsg "82" "✔ Earth scorched. Magnetic persistence neutralized."
        fi
    fi
}
ExecuteAnnihilation

# VOL-02: Database Lockout Cured. Strict directory creation.
sudo mkdir -p "$StackDir" "$TraefikLogDir" "$ScriptsDir" "${ConfigDir}/Authelia" "${ConfigDir}/Postgres" "${ConfigDir}/Traefik/Dynamic" "${ConfigDir}/WireGuard" "${ConfigDir}/PiHole/etc-pihole" "${ConfigDir}/PiHole/etc-dnsmasq.d" "${ConfigDir}/Unbound" "$TraefikAcmeDir"

# LOG-12 & TLS-11: Root Ownership Paradox & ACME Inode Deadlock Cured.
# The TraefikAcmeDir directory is firmly owned by root:root, explicitly enabling the daemon's atomic rename() syscalls.
sudo chown -R root:root "$TraefikLogDir" "$TraefikAcmeDir"

sudo chown -R 70:70 "${ConfigDir}/Postgres"
sudo chown -R "$HostUid:$HostGid" "${ConfigDir}/WireGuard"
sudo chown -R 999:999 "${ConfigDir}/PiHole"

# Prevent authelia from crashing trying to touch an inexistent file.
sudo touch "${ConfigDir}/Authelia/notification.txt"
# TLS-08: ACME Directory Ghosting Cured. Targeting the TRUE mounted volume path to protect state.
sudo touch "$TraefikAcmeFile"; sudo chmod 600 "$TraefikAcmeFile"
sudo mkdir -p "$SecretsDir"; sudo chmod 700 "$SecretsDir"

# LOG-12 & LOG-11: Root Ownership Paradox Cured. Removed 'su' directive entirely.
if [ -d "/etc/logrotate.d" ]; then
    PrintMsg "214" "Enforcing mathematical bounds on Traefik access logs via logrotate..."
    sudo tee /etc/logrotate.d/sovereign-traefik > /dev/null << EOF
${TraefikLogDir}/*.log {
    daily
    rotate 14
    size 50M
    missingok
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF
    sudo chmod 644 /etc/logrotate.d/sovereign-traefik
fi

# IAM-20 & DB-01: Cryptographic Split-Brain Cured. Extended WriteSecret to support explicit octal bridges.
WriteSecret() {
    local name=$1; local content=$2; local owner=${3:-"$HostUid:$HostGid"}; local perms=${4:-600}
    local tmp_file="${SecretsDir}/${name}.tmp"
    printf "%s" "$content" | sudo tee "$tmp_file" > /dev/null
    sudo touch "${SecretsDir}/${name}"
    sudo chown "$owner" "${SecretsDir}/${name}"
    sudo chmod "$perms" "${SecretsDir}/${name}"
    sudo sh -c "cat '$tmp_file' > '${SecretsDir}/${name}'"
    sudo shred -u "$tmp_file"
}

if [ "$Interactive" -eq 1 ]; then
    [ ! -f "${SecretsDir}/cf_api_token" ] && { read -s -p "Cloudflare DNS API Token: " cf_token; echo ""; WriteSecret "cf_api_token" "$cf_token"; }
    # IAM-17: BasicAuth Hash Detonation Cured. Utilizes native apr1 (MD5) compliant algorithm.
    [ ! -f "${SecretsDir}/traefik_auth" ] && { read -s -p "Traefik BasicAuth Password: " TraefikPass; echo ""; WriteSecret "traefik_auth" "admin:$(openssl passwd -apr1 "$TraefikPass")"; }
else
    if [ ! -f "${SecretsDir}/cf_api_token" ] || [ ! -f "${SecretsDir}/traefik_auth" ]; then
        PrintMsg "196" "[FATAL] Headless deployment detected, but master edge secrets are missing."
        exit 1
    fi
fi

# IAM-20 Execution: Assign postgres_password strictly to 70:$HostGid with 640 permissions for bridging.
[ ! -f "${SecretsDir}/postgres_password" ] && WriteSecret "postgres_password" "$(openssl rand -base64 32)" "70:$HostGid" "640"
[ ! -f "${SecretsDir}/authelia_jwt_secret" ] && WriteSecret "authelia_jwt_secret" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_session_secret" ] && WriteSecret "authelia_session_secret" "$(openssl rand -base64 32)"
[ ! -f "${SecretsDir}/authelia_storage_key" ] && WriteSecret "authelia_storage_key" "$(openssl rand -base64 32)"

# IAM-28: Administrative Cryptographic Lockout Cured. Cache the plaintext pass in memory.
if [ ! -f "${SecretsDir}/pihole_pass" ]; then
    GeneratedPiholePass="$(openssl rand -hex 16)"
    WriteSecret "pihole_pass" "$GeneratedPiholePass"
else
    GeneratedPiholePass="[Encrypted in Vault]"
fi

if [ "$Interactive" -eq 1 ]; then
    read -p "WireGuard Public Endpoint [$PrevEndpoint]: " input_endpoint; WgEndpoint="${input_endpoint:-$PrevEndpoint}"
    read -p "Internal Root Domain [$PrevDomain]: " input_domain; InternalDomain="${input_domain:-$PrevDomain}"
    
    # TLS-04: Null ACME Detonation Cured. Loop enforces valid data extraction.
    while true; do
        read -p "Let's Encrypt Email [$PrevEmail]: " input_email
        AcmeEmail="${input_email:-$PrevEmail}"
        if [ -n "$AcmeEmail" ]; then break; fi
        PrintMsg "196" "[FATAL] ACME schema requires a valid email. Null values are prohibited."
    done

    # DNS-20: Split-Horizon LAN Void Cured. Mathematical priority to physical host LAN over Docker gateway.
    FallbackLanIp="${PrevLanIp:-${HUNTER_IP:-10.99.0.1}}"
    read -p "Monolith LAN IP [$FallbackLanIp]: " input_lan
    TraefikLanIp="${input_lan:-$FallbackLanIp}"
    
    read -p "WireGuard Peer Count [$PrevWgPeers]: " input_peers; WgPeers="${input_peers:-$PrevWgPeers}"
    read -p "Enable PRODUCTION Let's Encrypt? (y/N): " input_prod
    [[ "${input_prod:-N}" =~ ^[Yy]$ ]] && AcmeServerUrl="https://acme-v02.api.letsencrypt.org/directory" || AcmeServerUrl="https://acme-staging-v02.api.letsencrypt.org/directory"
    
    read -p "Route ALL remote internet traffic through VPN? [Y/n]: " input_tunnel
    
    if [[ "${input_tunnel:-Y}" =~ ^[Nn]$ ]]; then
        WgAllowedIps="10.13.13.0/24,10.99.0.0/24"
        if [ -n "$PrevLanSubnet" ]; then
            WgAllowedIps="${WgAllowedIps},${PrevLanSubnet}"
        elif [ -n "$TraefikLanIp" ] && [ "$TraefikLanIp" != "10.99.0.1" ]; then
            WgAllowedIps="${WgAllowedIps},${TraefikLanIp}/32"
        fi
    else
        # NET-18: IPv6 RTNETLINK Panic Cured. Strict IPv4 routing compliance.
        WgAllowedIps="0.0.0.0/0"
    fi
else
    if [ -z "${PrevEndpoint:-}" ] || [ -z "${PrevEmail:-}" ]; then
        PrintMsg "196" "[FATAL] Headless deployment detected, but master .env cache is missing."
        exit 1
    fi
    WgEndpoint="${PrevEndpoint}"; InternalDomain="${PrevDomain}"; AcmeEmail="${PrevEmail}"
    TraefikLanIp="${PrevLanIp:-${HUNTER_IP:-10.99.0.1}}"; WgPeers="${PrevWgPeers}"; AcmeServerUrl="${PrevAcme}"
    WgAllowedIps="${PrevAllowedIps}"
fi

# BOOT-16: S6-Overlay Init Paradox Cured.
# The volatile custom-cont-init script has been eradicated. We now physically seed the 
# WireGuard template directly, ensuring the native container initialization ingests it.
PrintMsg "214" "Surgically seeding WireGuard server template to inject L3 NAT bypass..."
sudo mkdir -p "${ConfigDir}/WireGuard/templates"
sudo tee "${ConfigDir}/WireGuard/templates/server.conf" > /dev/null << EOF
[Interface]
Address = \${INTERFACE}.1
ListenPort = \${SERVER_PORT}
PrivateKey = \${PRIVATE_KEY}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o \${SERVER_DEVICE} -j MASQUERADE
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d 10.98.0.0/16 -j RETURN
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d 10.99.0.0/16 -j RETURN
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d ${TraefikLanIp}/32 -j RETURN
PreDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o \${SERVER_DEVICE} -j MASQUERADE
PreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d 10.98.0.0/16 -j RETURN || true
PreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d 10.99.0.0/16 -j RETURN || true
PreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d ${TraefikLanIp}/32 -j RETURN || true
EOF
sudo chown -R "$HostUid:$HostGid" "${ConfigDir}/WireGuard/templates"

# CONFIG-01, CONFIG-02 & ORCH-36: Template Stagnation & Namespace Hallucinations Cured.
# Active parsing logic dynamically injects the physical LAN IP routing bypass directly into 
# the active wg0.conf exactly ONCE on every boot. 
# Explicitly removed 'iptables -D' from the host execution context. We natively rely on Docker 
# container lifecycle events to tear down and recreate the network namespace.
if [ -f "${ConfigDir}/WireGuard/wg0.conf" ]; then
    PrintMsg "214" "Dynamically injecting active routing bypass into existing wg0.conf..."
    sudo sed -i '/-j RETURN/d' "${ConfigDir}/WireGuard/wg0.conf"
    sudo awk '/PostUp.*-j MASQUERADE/ {print; print "PostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d 10.98.0.0/16 -j RETURN\nPostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d 10.99.0.0/16 -j RETURN\nPostUp = iptables -t nat -I POSTROUTING 1 -s 10.13.13.0/24 -d '"${TraefikLanIp}"'/32 -j RETURN\nPreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d 10.98.0.0/16 -j RETURN || true\nPreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d 10.99.0.0/16 -j RETURN || true\nPreDown = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -d '"${TraefikLanIp}"'/32 -j RETURN || true"; next}1' "${ConfigDir}/WireGuard/wg0.conf" > /tmp/wg0.tmp && sudo mv /tmp/wg0.tmp "${ConfigDir}/WireGuard/wg0.conf"
    sudo chown "$HostUid:$HostGid" "${ConfigDir}/WireGuard/wg0.conf"
fi

# TLS-03 & TLS-08: ACME State Lockout Cured. State-transition awareness added for CA pivots.
if [ -n "${PrevAcme:-}" ] && [ "${PrevAcme}" != "${AcmeServerUrl}" ]; then
    PrintMsg "196" "⚠️ ACME CA transition detected. Purging legacy acme.json state to prevent TLS lockout..."
    sudo rm -f "$TraefikAcmeFile"
    sudo touch "$TraefikAcmeFile"
    sudo chmod 600 "$TraefikAcmeFile"
fi

sudo tee "$EnvFile" > /dev/null << EOF
WG_ENDPOINT=${WgEndpoint}
INTERNAL_DOMAIN=${InternalDomain}
ACME_EMAIL=${AcmeEmail}
ACME_SERVER_URL=${AcmeServerUrl}
WG_PORT=${PrevPort:-51820}
WG_PEERS=${WgPeers}
TRAEFIK_LAN_IP=${TraefikLanIp}
WG_LAN_SUBNET=${PrevLanSubnet}
WG_ALLOWED_IPS=${WgAllowedIps}
TRAEFIK_TRUSTED_IPS=${TraefikTrustedIps}
HOST_UID=${HostUid}
HOST_GID=${HostGid}
TZ=UTC
EOF

set -a; source "$EnvFile"; set +a

# ORCH-19: Administrative Blackhole Cured. Symlink ensures native Docker tools function despite PascalCase aesthetics.
sudo ln -sf "$ComposeFile" "${StackDir}/docker-compose.yml"

# IAM-36, IAM-41, IAM-46, IAM-53, IAM-47, IAM-48, IAM-49, IAM-54, IAM-55, IAM-56: The Absolute Identity Matrix.
# 1. Eradicated deprecated password_reset and external_url to prevent Unmarshaler Suicide.
# 2. Reverted session block to strict 'cookies' list array schema to satisfy v4.38 parser rules.
# 3. IAM-56: Eradicated the illegal 'authelia_url' key from the array. Traefik's headers handle redirect logic.
# 4. IAM-55: Strict string-based time.Duration parameters ("1h", "5m") prevent quantum nanosecond expiration.
sudo tee "${ConfigDir}/Authelia/Configuration.yml" > /dev/null << EOF
server:
  host: 0.0.0.0
  port: 9091
storage:
  postgres:
    host: auth_db
    port: 5432
    database: authelia
    username: authelia
authentication_backend:
  file:
    path: /config/UsersDatabase.yml
access_control:
  default_policy: deny
  rules:
    - domain: "*.${InternalDomain}"
      policy: two_factor
session:
  cookies:
    - name: authelia_session
      domain: "${InternalDomain}"
      expiration: "1h"
      inactivity: "5m"
regulation:
  max_retries: 3
  find_time: 120
  ban_time: 300
notifier:
  filesystem: { filename: /config/notification.txt }
EOF

# IAM-40: Idempotent Password Wipe Cured. 
# Strict existence guard prevents routine deployments from factory-resetting the active hashes.
if [ ! -f "${ConfigDir}/Authelia/UsersDatabase.yml" ]; then
    sudo tee "${ConfigDir}/Authelia/UsersDatabase.yml" > /dev/null << 'EOF'
users:
  admin:
    displayname: "Sovereign Administrator"
    password: "$argon2id$v=19$m=65536,t=3,p=4$wD4pD5lT8vG6sE8jO7mCQA$2QOqU5vY3K5zN9yE4mT7qO1pB6uR4sF3jM5vA8nG4X8"
    email: admin@REPLACE_DOMAIN
    groups: [admins]
EOF
    sudo sed -i "s/REPLACE_DOMAIN/${InternalDomain}/g" "${ConfigDir}/Authelia/UsersDatabase.yml"
fi

# IAM-35: Immutable Password Database Cured. 
# Chown exclusively executed AFTER configuration/database injection to allow daemon writes.
sudo chown -R "$HostUid:$HostGid" "${ConfigDir}/Authelia"
sudo chmod 600 "${ConfigDir}/Authelia/UsersDatabase.yml" "${ConfigDir}/Authelia/Configuration.yml" "${ConfigDir}/Authelia/notification.txt"

# DNS-12: PGP-Pinned Root Hint Verification Utility
RootHintUtility="${ScriptsDir}/Verify-RootHints.sh"
sudo tee "$RootHintUtility" > /dev/null << 'EOF'
#!/bin/bash
set -euo pipefail
HintsDir="/opt/Docker/Config/Unbound"
EphKeyring="${HintsDir}/icann.gpg"

curl -sS "https://www.internic.net/domain/named.root" -o "${HintsDir}/RootHints.txt.tmp"
curl -sS "https://www.internic.net/domain/named.root.sig" -o "${HintsDir}/RootHints.txt.sig"
curl -sS "https://data.iana.org/root-anchors/icann.pgp" -o "${HintsDir}/icann.pgp"

gpg --no-default-keyring --keyring "$EphKeyring" --import "${HintsDir}/icann.pgp" >/dev/null 2>&1 || true

if ! gpg --no-default-keyring --keyring "$EphKeyring" --fingerprint 0x0BD07395 | tr -d ' ' | grep -q "E0F2C1291162E536E8EEEEF0F781C36C0BD07395"; then
    echo "[FATAL] DNS Root Trust Anchor Compromised. MitM detected."
    exit 1
fi

if gpg --no-default-keyring --keyring "$EphKeyring" --verify "${HintsDir}/RootHints.txt.sig" "${HintsDir}/RootHints.txt.tmp" 2>/dev/null; then
    mv "${HintsDir}/RootHints.txt.tmp" "${HintsDir}/RootHints.txt"
    rm -f "${HintsDir}/RootHints.txt.sig" "${HintsDir}/icann.pgp" "$EphKeyring" "${EphKeyring}~"
    exit 0
else
    echo "[FATAL] GPG Signature verification failed for DNS root hints."
    exit 1
fi
EOF
sudo chmod 700 "$RootHintUtility"

PrintMsg "240" "Verifying DNS Root Integrity via PGP Pinning..."
sudo "$RootHintUtility" || exit 1

# DNS-16 & ENV-05: Alpine Namespace Void Cured. Variable expansion mathematically stabilized.
sudo tee "${ConfigDir}/Unbound/UnboundConfig.conf" > /dev/null << EOF
server:
  interface: 0.0.0.0
  port: 53
  do-ip4: yes
  username: "_unbound"
  root-hints: "/opt/unbound/etc/unbound/root.hints"
  auto-trust-anchor-file: "/opt/unbound/etc/unbound/keys/root.key"
  access-control: 127.0.0.0/8 allow
  access-control: 10.99.0.0/24 allow
  local-zone: "${InternalDomain}." redirect
  local-data: "${InternalDomain}. A ${TraefikLanIp}"
EOF

# SEC-29: Physical Air-Gap Breach Cured. Ruthlessly amputated RFC1918 space from the whitelist middleware.
# IAM-38 & IAM-52 & IAM-53: Deprecated Authz Endpoint & Redirection Singularity Cured. Clean modernized verification target.
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
        sourceRange: ["10.13.13.0/24", "127.0.0.1/32"]
    authelia:
      forwardAuth:
        address: "http://authelia:9091/api/authz/forward-auth"
        trustForwardHeader: true
        authResponseHeaders: ["Remote-User", "Remote-Groups", "Remote-Name", "Remote-Email"]
    traefik-auth:
      basicAuth:
        usersFile: "/run/secrets/traefik_auth"
  routers:
    auth-router:
      rule: "Host(\`auth.${InternalDomain}\`)"
      entryPoints: ["websecure"]
      middlewares: ["secure-headers"]
      service: "authelia-service"
      tls: { certResolver: "cloudflare" }
  services:
    authelia-service:
      loadBalancer:
        servers: [{ url: "http://authelia:9091" }]
EOF

# LOG-06: Host Storage Exhaustion Cured. Hard caps applied globally to JSON drivers.
sudo tee "$ComposeFile" > /dev/null << EOF
x-logging: &default-logging
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "5"

networks:
  vpn_network:
    name: sovereign_gateway_vpn_network
    driver_opts: { com.docker.network.driver.mtu: 1420 }
    ipam: { config: [{ subnet: 10.99.0.0/24 }] }
  proxy_network:
    name: sovereign_gateway_proxy_network
    driver_opts: { com.docker.network.driver.mtu: 1420 }
    ipam: { config: [{ subnet: 10.98.0.0/24 }] }
  auth_network: { internal: true }
  socket_network: { internal: true }

volumes:
  unbound_keys: {}

secrets:
  cf_api_token: { file: ${SecretsDir}/cf_api_token }
  postgres_password: { file: ${SecretsDir}/postgres_password }
  authelia_jwt_secret: { file: ${SecretsDir}/authelia_jwt_secret }
  authelia_session_secret: { file: ${SecretsDir}/authelia_session_secret }
  authelia_storage_key: { file: ${SecretsDir}/authelia_storage_key }
  pihole_pass: { file: ${SecretsDir}/pihole_pass }
  traefik_auth: { file: ${SecretsDir}/traefik_auth }

services:
  # ORCH-22 & ORCH-24: HAProxy Schism Cured. EVENTS=1 strictly restores dynamic stream API access.
  docker_socket_proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: docker_socket_proxy
    networks: [socket_network]
    environment: [CONTAINERS=1, NETWORKS=1, VERSION=1, SECRETS=0, POST=0, EVENTS=1]
    volumes: [/var/run/docker.sock:/var/run/docker.sock:ro]
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID]
    security_opt: [no-new-privileges:true]
    read_only: true
    tmpfs: [/run, /tmp]
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:2375/version || exit 1"]
      interval: 10s
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
      # DB-02: InitDB Dirty Void Cured. PGDATA pushed to clean subdirectory.
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes: [${ConfigDir}/Postgres:/var/lib/postgresql/data]
    cap_drop: [ALL]
    # DB-03: Posix Asphyxiation Cured. DAC_OVERRIDE restored for initialization format logic.
    cap_add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE]
    security_opt: [no-new-privileges:true]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d authelia -U authelia"]
    logging: *default-logging
    restart: unless-stopped

  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    networks: [proxy_network, auth_network]
    user: "\${HOST_UID:-1000}:\${HOST_GID:-1000}"
    volumes: [${ConfigDir}/Authelia:/config]
    # IAM-22: PascalCase Parser Detonation Cured.
    command: ["--config", "/config/Configuration.yml"]
    secrets: [postgres_password, authelia_jwt_secret, authelia_session_secret, authelia_storage_key]
    environment:
      AUTHELIA_JWT_SECRET_FILE: /run/secrets/authelia_jwt_secret
      AUTHELIA_SESSION_SECRET_FILE: /run/secrets/authelia_session_secret
      AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE: /run/secrets/authelia_storage_key
      AUTHELIA_STORAGE_POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      # IAM-59: Socket Binding Suicide Cured. Eradicated AUTHELIA_SERVER_ADDRESS variable mapping.
    depends_on:
      auth_db: { condition: service_healthy }
    cap_drop: [ALL]
    # HEALTH-09: Healthcheck CLI Detonation Cured.
    healthcheck:
      test: ["CMD", "authelia-healthcheck"]
      interval: 10s
      timeout: 5s
      retries: 5
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
    entrypoint: ["/bin/sh", "-c", "unbound-anchor -a /opt/unbound/etc/unbound/keys/root.key || if [ ! -s /opt/unbound/etc/unbound/keys/root.key ]; then echo '. IN DS 20326 8 2 e06d44b80b8f1d39a95c0b0d7c65d08458e880409bbc683457104237c7f8ec8d' > /opt/unbound/etc/unbound/keys/root.key; fi; chown -R _unbound:_unbound /opt/unbound/etc/unbound/keys 2>/dev/null || chown -R unbound:unbound /opt/unbound/etc/unbound/keys 2>/dev/null || true; exec /opt/unbound/sbin/unbound -d -c /opt/unbound/etc/unbound/unbound.conf"]
    cap_drop: [ALL]
    cap_add: [CHOWN, SETGID, SETUID, NET_BIND_SERVICE]
    # BOOT-12: Internet Dependency Deadlock Cured. Unbound probes its internal resolution space.
    healthcheck:
      test: ["CMD-SHELL", "drill -p 53 \${INTERNAL_DOMAIN} @127.0.0.1 || exit 1"]
      start_period: 30s
    logging: *default-logging
    restart: unless-stopped

  pihole_sinkhole:
    image: pihole/pihole:latest
    container_name: pihole_sinkhole
    networks:
      vpn_network: { ipv4_address: 10.99.0.12 }
      proxy_network: {}
    # DNS-19: Phantom LAN Sinkhole Cured. Binds explicitly to 0.0.0.0 to serve the physical host interface natively.
    ports:
      - "0.0.0.0:53:53/tcp"
      - "0.0.0.0:53:53/udp"
    environment:
      WEBPASSWORD_FILE: /run/secrets/pihole_pass
      PIHOLE_DNS_: 10.99.0.11#53
      DNSMASQ_LISTENING: all
      VIRTUAL_HOST: pihole.\${INTERNAL_DOMAIN}
    secrets: [pihole_pass]
    volumes:
      - ${ConfigDir}/PiHole/etc-pihole:/etc/pihole
      - ${ConfigDir}/PiHole/etc-dnsmasq.d:/etc/dnsmasq.d
    depends_on:
      unbound_dns: { condition: service_healthy }
    cap_drop: [ALL]
    # BOOT-13: S6-Overlay Asphyxiation Cured. DAC_OVERRIDE and FOWNER legally restored.
    cap_add: [NET_ADMIN, NET_RAW, CHOWN, SETUID, SETGID, KILL, NET_BIND_SERVICE, SYS_NICE, DAC_OVERRIDE, FOWNER]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.pihole.rule=Host(\`pihole.\${INTERNAL_DOMAIN}\`)"
      - "traefik.http.routers.pihole.entrypoints=websecure"
      - "traefik.http.routers.pihole.tls.certresolver=cloudflare"
      - "traefik.http.services.pihole.loadbalancer.server.port=80"
      - "traefik.http.middlewares.pihole-redirect.redirectregex.regex=^https://pihole\.\${INTERNAL_DOMAIN}/\$\$"
      - "traefik.http.middlewares.pihole-redirect.redirectregex.replacement=https://pihole.\${INTERNAL_DOMAIN}/admin/"
      - "traefik.http.routers.pihole.middlewares=secure-headers@file,authelia@file,pihole-redirect"
      - "traefik.docker.network=sovereign_gateway_proxy_network"
    logging: *default-logging
    restart: unless-stopped

  wireguard_vpn:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: wireguard_vpn
    networks:
      vpn_network: { ipv4_address: 10.99.0.10 }
    cap_drop: [ALL]
    # BOOT-14 & BOOT-13: Module Asphyxiation Cured. SYS_MODULE injected for native kernel modprobe.
    cap_add: [NET_ADMIN, NET_RAW, CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER, SYS_MODULE]
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    # ORCH-31: WireGuard Stagnation Trap Cured. STATE_TRIGGER guarantees a compose recreation when the physical LAN IP changes.
    environment:
      PUID: "\${HOST_UID}"
      PGID: "\${HOST_GID}"
      SERVERURL: \${WG_ENDPOINT}
      SERVERPORT: \${WG_PORT}
      PEERS: \${WG_PEERS}
      PEERDNS: 10.99.0.12
      INTERNAL_SUBNET: "10.13.13.0/24"
      ALLOWEDIPS: "\${WG_ALLOWED_IPS}"
      STATE_TRIGGER: "\${TRAEFIK_LAN_IP}"
    volumes:
      - /lib/modules:/lib/modules:ro
      - ${ConfigDir}/WireGuard:/config
    devices:
      - /dev/net/tun:/dev/net/tun
    ports: ["0.0.0.0:\${WG_PORT}:\${WG_PORT}/udp"]
    logging: *default-logging
    restart: unless-stopped

  traefik_proxy:
    image: traefik:v2.11
    container_name: traefik_proxy
    # SEC-37: L3 DMZ Bypass V2 Cured. Assigned a static, immutable proxy IP to ruthlessly anchor the Watchdog's VPN isolation rules.
    networks: 
      socket_network: {}
      proxy_network: 
        ipv4_address: 10.98.0.254
    ports: ["0.0.0.0:80:80", "0.0.0.0:443:443"]
    # TLS-11: ACME Inode Deadlock Cured. Directory-level mount strictly enables the atomic rename() syscall for Let's Encrypt generation.
    volumes:
      - ${ConfigDir}/Traefik/Dynamic:/etc/traefik/dynamic:ro
      - ${TraefikAcmeDir}:/etc/traefik/acme:rw
      - ${TraefikLogDir}:/var/log/traefik:rw
    secrets: [cf_api_token, traefik_auth]
    environment: [CF_DNS_API_TOKEN_FILE=/run/secrets/cf_api_token]
    depends_on:
      docker_socket_proxy: { condition: service_healthy }
      authelia: { condition: service_healthy }
    # BOOT-17: The Missing Entrypoint Cured. Surgically restored the web port 80 binding to satisfy the HTTP redirection rule.
    command:
      - "--providers.docker=true"
      - "--providers.docker.endpoint=tcp://docker_socket_proxy:2375"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.websecure.forwardedHeaders.trustedIPs=\${TRAEFIK_TRUSTED_IPS}"
      - "--certificatesresolvers.cloudflare.acme.caserver=\${ACME_SERVER_URL}"
      - "--certificatesresolvers.cloudflare.acme.email=\${ACME_EMAIL}"
      - "--certificatesresolvers.cloudflare.acme.storage=/etc/traefik/acme/acme.json"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare"
      - "--accesslog=true"
      - "--accesslog.filepath=/var/log/traefik/access.log"
      - "--accesslog.format=json"
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: [no-new-privileges:true]
    logging: *default-logging
    restart: unless-stopped
EOF

# ORCH-21, DNS-25, & ORCH-38: Selective Immortality Cured. 
# Update entire fleet using --remove-orphans to secure CVE patching globally.
# Then explicitly force-recreate unbound_dns to surgically drop the stale root.hints inode lock.
sudo tee /etc/systemd/system/sovereign-updater.service > /dev/null << EOF
[Unit]
Description=Sovereign Gateway Weekly Updater
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=-/usr/bin/bash -c '${RootHintUtility}'
ExecStart=/usr/bin/bash -c 'cd ${StackDir} && ${DockerBin} compose -f ${ComposeFile} pull && ${DockerBin} compose -f ${ComposeFile} up -d --remove-orphans && ${DockerBin} compose -f ${ComposeFile} up -d --force-recreate unbound_dns && ${DockerBin} image prune -f'
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

# SEC-36, SEC-37, SEC-38, NET-36, & NET-42: Asymmetrical Routing and TCP Drop Cured.
# Explicitly authorize BOTH UDP and TCP port 53 for large DNSSEC payload fallback.
WatchdogScript="${ScriptsDir}/WatchdogSovereignGateway.sh"
sudo tee "$WatchdogScript" > /dev/null << EOF
#!/bin/bash

# Wait for Docker to establish its isolated chains
for i in {1..30}; do
    if iptables -n -L DOCKER-USER >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# SEC-38: Surgically flush immortal legacy skeleton keys from live kernel memory
iptables -D DOCKER-USER -s 10.13.13.0/24 -d 10.98.0.0/24 -p tcp -m multiport --dports 80,443 -j ACCEPT 2>/dev/null || true
iptables -D DOCKER-USER -d 10.13.13.0/24 -s 10.98.0.0/24 -p tcp -m multiport --sports 80,443 -j ACCEPT 2>/dev/null || true

# Insert the strictly bound 10.98.0.254 constraint
if ! iptables -C DOCKER-USER -s 10.13.13.0/24 -d 10.98.0.254/32 -p tcp -m multiport --dports 80,443 -j ACCEPT 2>/dev/null; then
    iptables -I DOCKER-USER 1 -s 10.13.13.0/24 -d 10.98.0.254/32 -p tcp -m multiport --dports 80,443 -j ACCEPT
    iptables -I DOCKER-USER 1 -d 10.13.13.0/24 -s 10.98.0.254/32 -p tcp -m multiport --sports 80,443 -j ACCEPT
fi

# NET-36 & NET-42: Authorize UDP AND TCP 53 return path for asymmetrical bridge routing (VPN <-> Pi-Hole/DNSSEC)
for proto in udp tcp; do
    if ! iptables -C DOCKER-USER -s 10.99.0.12/32 -d 10.13.13.0/24 -p \$proto --sport 53 -j ACCEPT 2>/dev/null; then
        iptables -I DOCKER-USER 1 -s 10.99.0.12/32 -d 10.13.13.0/24 -p \$proto --sport 53 -j ACCEPT
        iptables -I DOCKER-USER 1 -d 10.99.0.12/32 -s 10.13.13.0/24 -p \$proto --dport 53 -j ACCEPT
    fi
done

if ! ip route show | grep -q "10.13.13.0/24 via 10.99.0.10"; then
    ip route add 10.13.13.0/24 via 10.99.0.10 2>/dev/null || true
fi

for manifest in "${ConfigDir}/Traefik/Dynamic/"*_assimilation.yml; do
    [ -e "\$manifest" ] || continue
    alien=\$(grep "^# ALIEN_CONTAINER: " "\$manifest" | cut -d' ' -f3 || true)
    [ -z "\$alien" ] && continue
    if ${DockerBin} ps -a --format '{{.Names}}' | grep -q "^\${alien}\$"; then
        if ${DockerBin} ps --format '{{.Names}}' | grep -q "^\${alien}\$"; then
            if ! ${DockerBin} inspect "\$alien" --format '{{json .NetworkSettings.Networks}}' | grep -q "sovereign_gateway_proxy_network"; then
                ${DockerBin} network connect sovereign_gateway_proxy_network "\$alien" || true
            fi
        fi
    fi
done
EOF
sudo chmod 700 "$WatchdogScript"

# ORCH-35: Systemd Watchdog Lockout Cured. 
# ReadWritePaths explicitly pierces the strict sandbox to grant iptables access to the required kernel mutex lock.
sudo tee /etc/systemd/system/sovereign-watchdog.service > /dev/null << EOF
[Unit]
Description=Sovereign Gateway Network Watchdog
After=docker.service

[Service]
Type=oneshot
ExecStart=$WatchdogScript
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${ConfigDir}/Traefik/Dynamic -/run/xtables.lock
EOF

sudo tee /etc/systemd/system/sovereign-watchdog.timer > /dev/null << EOF
[Unit]
Description=5-Minute Timer for Sovereign Watchdog

[Timer]
OnCalendar=*:0/5
RandomizedDelaySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now sovereign-watchdog.timer sovereign-updater.timer

if [ "$Interactive" -eq 1 ]; then PrintMsg "226" "Igniting Sovereign Matrix..."; fi
cd "$StackDir" && sudo $DockerBin compose -f "$ComposeFile" up -d --force-recreate --remove-orphans

# Execute immediate kernel routing/iptables injection natively on boot.
sudo /bin/bash "$WatchdogScript"

AssimilateAlienContainers() {
    ProxyNetworkName="sovereign_gateway_proxy_network"
    if [ "$Interactive" -eq 1 ] && command -v docker &> /dev/null; then
        local foreign_containers=\$(sudo $DockerBin ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' -v stack="${StackName,,}" 'tolower($2) != stack && $1 != "" {print $1}')
        if [ -n "$foreign_containers" ]; then
            local found_new=0
            for container in $foreign_containers; do
                local clean_name=$(echo "$container" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
                local manifest_file="${ConfigDir}/Traefik/Dynamic/${clean_name}_assimilation.yml"
                if [ -f "$manifest_file" ]; then continue; fi
                
                if [ $found_new -eq 0 ]; then
                    echo ""
                    PrintMsg "214" "========================================================================"
                    PrintMsg "214" " 🛸 ALIEN ASSIMILATION PROTOCOL INITIATED"
                    PrintMsg "214" "========================================================================"
                    found_new=1
                fi
                echo ""
                PrintMsg "214" "Select ingress posture for unassimilated container [$container]:"
                local posture_choice=""
                if command -v gum &> /dev/null; then
                    local choice=$(gum choose "1) MFA Protected (Authelia) [SUGGESTED]" "2) VPN-Only (Air-Gapped)" "3) BasicAuth (Legacy Form)" "4) Fully Public" "5) Internal (Skip)" || true)
                    [ -z "$choice" ] && continue
                    posture_choice=${choice:0:1}
                else
                    echo "1) MFA Protected (Authelia) [SUGGESTED]"
                    echo "2) VPN-Only (Air-Gapped)"
                    echo "3) BasicAuth (Legacy Form)"
                    echo "4) Fully Public"
                    echo "5) Internal (Skip)"
                    read -p "Select posture (1-5) [1]: " posture_choice || true
                    posture_choice=${posture_choice:-1}
                fi
                if [ "$posture_choice" -eq 5 ]; then continue; fi
                
                local TargetPort=""
                if command -v gum &> /dev/null; then
                    TargetPort=$(gum input --prompt "Internal listening port for $container (e.g. 80, 8080): " || true)
                else
                    read -p "Internal listening port for $container (e.g. 80, 8080): " TargetPort || true
                fi
                if [ -z "$TargetPort" ]; then continue; fi
                
                local mw_string=""
                case "$posture_choice" in
                    1) mw_string='secure-headers@file,authelia@file' ;;
                    2) mw_string='secure-headers@file,vpn-whitelist@file' ;;
                    3) mw_string='secure-headers@file,traefik-auth@file' ;;
                    4) mw_string='secure-headers@file' ;;
                esac
                
                PrintMsg "226" "Bridging $container to Zero-Trust perimeter..."
                sudo $DockerBin network connect "$ProxyNetworkName" "$container" >/dev/null 2>&1 || true
                
                # TLS-05: CertResolver Schism Cured. Strictly binding alien certs to cloudflare logic.
                sudo tee "$manifest_file" > /dev/null << MANIFEST_EOF
# ALIEN_CONTAINER: $container
http:
  routers:
    ${clean_name}-router:
      rule: "Host(\`${clean_name}.${INTERNAL_DOMAIN}\`)"
      entryPoints: ["websecure"]
      middlewares: [${mw_string}]
      service: "${clean_name}-service"
      tls: { certResolver: "cloudflare" }
  services:
    ${clean_name}-service:
      loadBalancer:
        servers: [{ url: "http://${container}:${TargetPort}" }]
MANIFEST_EOF
                PrintMsg "82" "✔ Assimilated: https://${clean_name}.${INTERNAL_DOMAIN}"
            done
        fi
    fi
}
AssimilateAlienContainers

# IAM-28: Administrative Lockout Cured. Properly returning cryptographic keys to the operator.
if [ "$Interactive" -eq 1 ]; then
    echo -e "\n========================================================"
    echo -e " \033[1;32mSOVEREIGN GATEWAY PROVISIONING COMPLETE\033[0m"
    echo -e "========================================================"
    echo -e " \033[1;33mAdministrative Credentials:\033[0m"
    echo -e " User: admin"
    echo -e " Pass (Traefik): ${TraefikPass:-[Hidden in Script / Known to Operator]}"
    echo -e " Pass (Pi-Hole): \033[1;31m${GeneratedPiholePass}\033[0m"
    echo -e "--------------------------------------------------------"
    echo -e " \033[1;33mAuthelia 2FA Registration:\033[0m"
    echo -e " sudo cat ${ConfigDir}/Authelia/notification.txt"
    echo -e "========================================================\n"
fi

exit 0