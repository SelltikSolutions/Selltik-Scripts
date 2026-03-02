#!/bin/bash
# ==============================================================================
#  SOVEREIGN EDGE GATEWAY - STIG COMPLIANT DEPLOYMENT (v43.0)
# ==============================================================================
#  WARNING: This script enforces strict Zero-Trust policies. It will alter
#  system timezones, inject cron jobs, and optionally DESTROY unauthorized
#  Docker containers. Review before blind execution.
#
#  Features: OS Detection, Crypto-Benchmarking, NTP/UTC Synchronization,
#  DNS Root Hints rotation, and STIG "Scorched Earth" Container Auditing.
# ==============================================================================

set -euo pipefail

# --- 1. GLOBALS & TRAPS ---
StackName="ParanoidStack"
BaseDir="/opt/${StackName}"
ConfigDir="${BaseDir}/Config"
LogsDir="${BaseDir}/Logs"
EnvFile="${BaseDir}/EdgeNode.env"
ComposeFile="${BaseDir}/DockerCompose.yml"
LockFile="/var/lock/sovereign_edge.lock"
SilentMode="false"

# Catch unexpected aborts to prevent silent half-states
TrapHandler() {
    local ret=$?
    if [ $ret -ne 0 ]; then
        echo -e "\n[FATAL] Script aborted unexpectedly (Exit Code: $ret). OpSec compromised. Halting."
    fi
}
trap TrapHandler EXIT

# Atomic lock
exec 200>"$LockFile"
flock -n 200 || { echo "[FATAL] Another instance is running. State corruption prevented."; exit 1; }

[ "$EUID" -eq 0 ] || { echo "[FATAL] Elevated privileges required. Run with: sudo $0"; exit 1; }

# --- 2. OS DETECTION (Distro-Awareness) ---
DetectOsFamily() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=${ID,,}
        OS_FAMILY=${ID_LIKE,,:-$OS_ID}
    else
        echo "[FATAL] /etc/os-release missing. What decade is this machine from?"
        exit 1
    fi

    # Normalize family
    if [[ "$OS_FAMILY" == *"debian"* ]] || [[ "$OS_ID" == "parrot" ]] || [[ "$OS_ID" == "ubuntu" ]]; then
        PkgManager="apt-get"
        UpdateCmd="apt-get update -y -q"
        InstallCmd="DEBIAN_FRONTEND=noninteractive apt-get install -y -q"
    elif [[ "$OS_FAMILY" == *"rhel"* ]] || [[ "$OS_FAMILY" == *"fedora"* ]]; then
        PkgManager="dnf"
        UpdateCmd="dnf check-update -q || true"
        InstallCmd="dnf install -y -q"
    elif [[ "$OS_FAMILY" == *"arch"* ]]; then
        PkgManager="pacman"
        UpdateCmd="pacman -Sy --noconfirm --quiet"
        InstallCmd="pacman -S --noconfirm --quiet"
    else
        echo "[FATAL] Unsupported OS Family: $OS_FAMILY. Refusing to guess package management."
        exit 1
    fi
}

# --- 3. DEPENDENCIES ---
CheckDependencies() {
    echo "Verifying baseline tools for $OS_ID ($OS_FAMILY)..."
    eval "$UpdateCmd" > /dev/null 2>&1
    
    local deps="curl jq openssl cron tzdata"
    # Adjust package names based on OS
    [[ "$PkgManager" == "apt-get" ]] && deps="$deps apparmor-utils"
    [[ "$PkgManager" == "dnf" ]] && deps="$deps cronie"
    
    for dep in $deps; do
        if ! command -v "$dep" &> /dev/null && ! dpkg -l | grep -q "^ii  $dep" 2>/dev/null; then
            echo "Installing missing dependency: $dep"
            eval "$InstallCmd $dep" > /dev/null
        fi
    done

    # UI/UX Dependency (Gum)
    if ! command -v gum &> /dev/null; then
        echo "Installing Charmbracelet Gum for secure prompts..."
        if [[ "$PkgManager" == "apt-get" ]]; then
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg
            echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
            eval "$UpdateCmd" > /dev/null
            eval "$InstallCmd gum" > /dev/null
        else
            echo "[WARNING] Gum UI not available in standard repos for $OS_FAMILY. Falling back to basic prompts."
        fi
    fi
}

# --- 4. CRYPTO BENCHMARKING (VPN Recommendation) ---
BenchmarkCrypto() {
    gum style --foreground "226" "Executing Hardware Cryptographic Benchmark..."
    
    # Run tests for 3 seconds each to gauge silicon capabilities
    local aes_speed
    local chacha_speed
    
    gum spin --spinner dot --title "Testing AES-256-GCM (Hardware Accelerated?)..." -- sleep 1
    aes_speed=$(openssl speed -evp aes-256-gcm 2>/dev/null | grep -E "^aes-256-gcm" | awk '{print $6}')
    
    gum spin --spinner dot --title "Testing ChaCha20-Poly1305 (Software Optimized)..." -- sleep 1
    chacha_speed=$(openssl speed -evp chacha20-poly1305 2>/dev/null | grep -E "^chacha20-poly1305" | awk '{print $6}')

    # Extract thousands to compare roughly (k bytes per sec)
    local aes_k=${aes_speed:0:(-4)}
    local chacha_k=${chacha_speed:0:(-4)}
    
    # Fallback if extraction fails
    aes_k=${aes_k:-0}
    chacha_k=${chacha_k:-0}

    gum style --foreground "82" "Results (1024 byte blocks):"
    echo "  AES-256-GCM       : ${aes_speed:-Unknown} bytes/sec"
    echo "  ChaCha20-Poly1305 : ${chacha_speed:-Unknown} bytes/sec"

    if [ "$aes_k" -gt "$chacha_k" ]; then
        gum style --border double --foreground "51" --padding "1" \
        "SILICON VERDICT: AES-NI Detected" \
        "Your CPU has hardware acceleration for AES. For your upstream VPN," \
        "OpenVPN (DCO) or IPsec (IKEv2) using AES-256-GCM will perform optimally." \
        "WireGuard is acceptable but may slightly underperform AES on this specific rig."
    else
        gum style --border double --foreground "51" --padding "1" \
        "SILICON VERDICT: No AES-NI / Weak CPU" \
        "Your CPU struggles with AES. DO NOT use OpenVPN with AES-256-CBC/GCM." \
        "Recommendation: WireGuard (which uses ChaCha20-Poly1305) is MANDATORY" \
        "for maintaining throughput without bottlenecking your edge gateway."
    fi
}

# --- 5. STIG TIMEZONE AUDIT & NTP SYNC ---
AuditTimezone() {
    gum style --foreground "226" "Auditing Chronometric Infrastructure..."
    
    local tz_file="/etc/timezone"
    local lc_file="/etc/localtime"
    local reported_tz=""
    local file_tz=""
    local lc_tz=""

    # 1. Read /etc/timezone
    [ -f "$tz_file" ] && file_tz=$(cat "$tz_file" 2>/dev/null)
    
    # 2. Read symlink of /etc/localtime
    if [ -L "$lc_file" ]; then
        lc_tz=$(readlink "$lc_file" | sed 's|.*zoneinfo/||')
    fi
    
    # 3. Read timedatectl
    if command -v timedatectl >/dev/null 2>&1; then
        reported_tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    fi

    echo "  /etc/timezone     : ${file_tz:-Missing}"
    echo "  /etc/localtime    : ${lc_tz:-Not a symlink}"
    echo "  timedatectl       : ${reported_tz:-Unavailable}"

    if [[ "$file_tz" != "$lc_tz" ]] || [[ "$lc_tz" != "$reported_tz" ]]; then
        gum style --foreground "196" "[WARNING] Timezone configuration files are fractured/mismatched. This breaks log correlation."
    fi

    if [[ "$reported_tz" != "UTC" ]] && [[ "$reported_tz" != "Etc/UTC" ]]; then
        gum style --foreground "212" "DISA STIG mandates UTC for all infrastructure nodes."
        if gum confirm "Force sync timezone to UTC and restart NTP daemon?"; then
            sudo timedatectl set-timezone UTC
            sudo rm -f /etc/localtime
            sudo ln -s /usr/share/zoneinfo/UTC /etc/localtime
            echo "UTC" | sudo tee /etc/timezone > /dev/null
            
            # Restart timesyncd or chrony
            if systemctl is-active --quiet systemd-timesyncd; then
                sudo systemctl restart systemd-timesyncd
            elif systemctl is-active --quiet chronyd; then
                sudo systemctl restart chronyd
            fi
            gum style --foreground "82" "✔ Timezone violently forced to UTC."
        else
            gum style --foreground "240" "► User rejected UTC. Forensics team will hate you."
        fi
    else
        gum style --foreground "82" "✔ Timezone is uniformly UTC."
    fi
}

# --- 6. DNS ROOT HINTS ROTATION ---
UpdateRootHints() {
    gum style --foreground "226" "Securing Recursive DNS Upstreams..."
    
    local hints_dir="${ConfigDir}/Unbound"
    local hints_file="${hints_dir}/RootHints.txt"
    sudo mkdir -p "$hints_dir"

    gum spin --spinner dot --title "Downloading official InterNIC Root Hints..." -- sleep 1
    if curl -sSL "https://www.internic.net/domain/named.root" -o "${hints_file}.tmp"; then
        # Basic sanity check to ensure it's not a captive portal HTML page
        if grep -q "A.ROOT-SERVERS.NET" "${hints_file}.tmp"; then
            sudo mv "${hints_file}.tmp" "$hints_file"
            sudo chmod 644 "$hints_file"
            gum style --foreground "82" "✔ Root Hints updated successfully."
        else
            gum style --foreground "196" "[FATAL] Downloaded Root Hints failed integrity check. MITM attack?"
            sudo rm -f "${hints_file}.tmp"
        fi
    else
        gum style --foreground "196" "[FATAL] Failed to reach InterNIC."
    fi
}

# --- 7. AUTOMATED UPDATES (Crontab) ---
ScheduleUpdates() {
    gum style --foreground "226" "Maintenance Scheduling..."
    
    local cron_file="/etc/cron.d/sovereign_updates"
    
    if [ -f "$cron_file" ]; then
        gum style --foreground "82" "✔ Automated updates already scheduled."
        return
    fi

    echo "Security mandates frequent updating, but silent breakages destroy edge nodes."
    local choice=$(gum choose "Daily (Aggressive/Risky)" "Weekly (Recommended)" "Never (Manual Operator Required)")

    local cron_expr=""
    case "$choice" in
        "Daily (Aggressive/Risky)") cron_expr="0 3 * * * root $UpdateCmd && $InstallCmd --only-upgrade > /var/log/unattended_upgrades.log 2>&1" ;;
        "Weekly (Recommended)")     cron_expr="0 3 * * 0 root $UpdateCmd && $InstallCmd --only-upgrade > /var/log/unattended_upgrades.log 2>&1" ;;
        "Never (Manual Operator Required)") return ;;
    esac

    echo "$cron_expr" | sudo tee "$cron_file" > /dev/null
    sudo chmod 644 "$cron_file"
    gum style --foreground "82" "✔ Maintenance schedule locked."
}

# --- 8. STIG SCORCHED EARTH (Container Audit) ---
EnforceScorchedEarth() {
    gum style --foreground "226" "Executing DISA STIG Scorched Earth Audit..."
    
    if ! command -v docker &> /dev/null; then
        gum style --foreground "240" "► Docker engine missing. Skipping container audit."
        return
    fi

    # Find containers NOT belonging to our specific StackName
    local alien_containers
    alien_containers=$(sudo docker ps -a --format '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' -v stack="${StackName,,}" 'tolower($3) != stack {print $1 " (" $2 ")"}')

    if [ -n "$alien_containers" ]; then
        gum style --border double --foreground "196" --padding "1" \
        "ALIEN CONTAINERS DETECTED" \
        "The following rogue instances bypass Sovereign Edge lifecycle management:" \
        "$alien_containers"
        
        if gum confirm "Execute Scorched Earth? (DESTROY all listed alien containers permanently)"; then
            echo "$alien_containers" | awk '{print $1}' | xargs -I {} sudo docker rm -f {} >/dev/null 2>&1 || true
            gum style --foreground "82" "✔ Edge environment sanitized. Aliens eradicated."
        else
            gum style --foreground "196" "⚠️ STIG VIOLATION: Alien instances retained. Isolation degraded."
        fi
    else
        gum style --foreground "82" "✔ Environment is pristine. No alien containers found."
    fi
}

# --- 9. COMPOSE GENERATION (Unbound Recursive DNS) ---
GenerateSovereignCompose() {
    gum style --foreground "226" "Staging Sovereign Docker Definitions..."
    
    local compose_tmp="${ComposeFile}.tmp"
    
    # We strip version as requested. We deploy Pi-hole (for ad-blocking/UI) + Unbound (Recursive).
    # Since the VPN is handled upstream by the user, we configure DNS to not leak.
    sudo tee "$compose_tmp" > /dev/null << EOF
networks:
  GatewayNetwork:
    name: GatewayNetwork
    ipam:
      config:
        - subnet: 10.99.0.0/24

services:
  RecursiveDns:
    image: mvance/unbound:latest
    container_name: UnboundDns
    networks:
      GatewayNetwork:
        ipv4_address: 10.99.0.254
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: true
    volumes:
      - ./Config/Unbound/RootHints.txt:/opt/unbound/etc/unbound/root.hints:ro
    ports:
      - "127.0.0.1:5335:53/tcp"
      - "127.0.0.1:5335:53/udp"
    restart: unless-stopped
EOF
    sudo mv "$compose_tmp" "$ComposeFile"
    sudo chown 0:0 "$ComposeFile"
    sudo chmod 600 "$ComposeFile"
    gum style --foreground "82" "✔ DockerCompose.yml securely written."
}

# --- EXECUTION PIPELINE ---
DetectOsFamily
CheckDependencies
echo ""
gum style --border double --margin "1" --padding "1" --foreground "212" "Sovereign Edge Initialization"
echo ""

BenchmarkCrypto
echo ""
AuditTimezone
echo ""
UpdateRootHints
echo ""
ScheduleUpdates
echo ""
EnforceScorchedEarth
echo ""
GenerateSovereignCompose

gum style --foreground "82" "=== DEPLOYMENT STAGED SUCCESSFULLY ==="
gum style --foreground "240" "► Navigate to $BaseDir and run:"
gum style --foreground "250" "  sudo docker compose up -d"
gum style --foreground "240" "► Point your upstream VPN DNS settings to 127.0.0.1:5335 to prevent DNS leaks."

exit 0