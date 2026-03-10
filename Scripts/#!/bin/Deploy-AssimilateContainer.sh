#!/bin/bash
# ==============================================================================
#  ALIEN CONTAINER ASSIMILATION UTILITY (v3.0-DISTRIBUTED-SATELLITE)
# ==============================================================================
#  Architecture: Decoupled Diagnostic & Manifest Generator
#  Purpose: Scans the Docker Socket for unassimilated containers and generates
#           Traefik Integration Manifests. 
#  Update: Now fully decoupled to support Remote Satellite Nodes (NAS, dedicated
#          compute servers) without requiring local gateway presence.
#  Prime Directive: Read-Only. Never modifies existing infrastructure.
# ==============================================================================

# Enforce strict error handling to prevent silent, catastrophic failures
set -euo pipefail

# Force absolute paths to prevent PATH poisoning attacks
export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

# Fail immediately if not running as root (required for Docker socket interrogation)
[ "$EUID" -eq 0 ] || { echo "[FATAL] Elevated privileges required. Run with: sudo $0"; exit 1; }

# Determine if we are running interactively or headless via cron/pipeline
Interactive=$([ -t 0 ] && echo 1 || echo 0)

# Formatter function for visual distinction in the terminal
PrintMsg() {
    local color=$1
    local msg=$2
    if command -v gum &> /dev/null; then
        gum style --foreground "$color" "$msg"
    else
        echo -e "\033[1;33m$msg\033[0m"
    fi
}

# --- 1. DYNAMIC ENVIRONMENT INTERROGATION ---
if [ "$Interactive" -eq 1 ]; then
    echo ""
    PrintMsg "212" "Select the target deployment architecture for assimilation:"
    if command -v gum &> /dev/null; then
        choice=$(gum choose "1) Unified Sovereign Node (Single-Node)" "2) Dedicated Traefik Monolith (Split-Horizon)" "3) Remote Satellite Node (NAS / Dedicated Service Host)")
        machine_choice=${choice:0:1}
    else
        echo "1) Unified Sovereign Node (Single-Node)"
        echo "2) Dedicated Traefik Monolith (Split-Horizon)"
        echo "3) Remote Satellite Node (NAS / Dedicated Service Host)"
        read -p "Select architecture (1-3): " machine_choice || echo ""
    fi

    case "$machine_choice" in
        1)
            StackName="SovereignNode"
            EnvFileName="Node.env"
            ProxyNetworkName="SovereignNode_ProxyNetwork"
            IsSatellite=0
            ;;
        2)
            StackName="TraefikMonolith"
            EnvFileName="Traefik.env"
            ProxyNetworkName="ProxyNetwork"
            IsSatellite=0
            ;;
        3)
            StackName="SatelliteNode"
            EnvFileName="Satellite.env"
            ProxyNetworkName="ProxyNetwork"
            IsSatellite=1
            ;;
        *)
            PrintMsg "196" "[FATAL] Invalid architecture selection. Aborting to prevent routing corruption."
            exit 1
            ;;
    esac
else
    PrintMsg "196" "[FATAL] Headless execution requires interactive machine selection. Aborting."
    exit 1
fi

BaseDir="/opt/Docker/Stacks/${StackName}"
EnvFile="${BaseDir}/${EnvFileName}"
ManifestDir="${BaseDir}/IntegrationManifests"

sudo mkdir -p "$BaseDir"

# SEC-01: Verify Sovereign Node State or Initialize Satellite State.
if [ ! -f "$EnvFile" ]; then
    if [ "$IsSatellite" -eq 1 ]; then
        PrintMsg "226" "[INFO] Initializing new Remote Satellite state at $EnvFile..."
        sudo touch "$EnvFile"
        sudo chmod 600 "$EnvFile"
    else
        PrintMsg "196" "[FATAL] Environment file not found at $EnvFile."
        PrintMsg "196" "The core perimeter must be deployed on this machine before assimilation can occur."
        exit 1
    fi
fi

# Source the environment variables safely (temporarily disable nounset for missing vars)
set +u
source "$EnvFile"
set -u

# Ensure INTERNAL_DOMAIN exists
if [ -z "${INTERNAL_DOMAIN:-}" ]; then
    PrintMsg "226" "[WARNING] INTERNAL_DOMAIN is missing from your active environment."
    if [ "$Interactive" -eq 1 ]; then
        if command -v gum &> /dev/null; then
            INTERNAL_DOMAIN=$(gum input --prompt "Enter Internal Routing Domain (e.g. lan.domain.com): " --placeholder "lan.domain.com")
        else
            read -p "Enter Internal Routing Domain [lan.domain.com]: " input_domain
            INTERNAL_DOMAIN=${input_domain:-lan.domain.com}
        fi
        # Append to EnvFile for future script executions
        echo "INTERNAL_DOMAIN=${INTERNAL_DOMAIN}" | sudo tee -a "$EnvFile" > /dev/null
    else
        PrintMsg "196" "[FATAL] INTERNAL_DOMAIN missing. Headless abort."
        exit 1
    fi
fi

# If Satellite, allow custom proxy network name override
if [ "$IsSatellite" -eq 1 ] && [ -z "${SATELLITE_PROXY_NET:-}" ]; then
    if [ "$Interactive" -eq 1 ]; then
        if command -v gum &> /dev/null; then
            SATELLITE_PROXY_NET=$(gum input --prompt "Enter target proxy network name on this node: " --value "$ProxyNetworkName")
        else
            read -p "Enter target proxy network name on this node [$ProxyNetworkName]: " input_net
            SATELLITE_PROXY_NET=${input_net:-$ProxyNetworkName}
        fi
        echo "SATELLITE_PROXY_NET=${SATELLITE_PROXY_NET}" | sudo tee -a "$EnvFile" > /dev/null
        ProxyNetworkName="$SATELLITE_PROXY_NET"
    fi
elif [ "$IsSatellite" -eq 1 ] && [ -n "${SATELLITE_PROXY_NET:-}" ]; then
    ProxyNetworkName="$SATELLITE_PROXY_NET"
fi

# Ensure the output directory exists
sudo mkdir -p "$ManifestDir"

ScanForeignContainers() {
    if ! command -v docker &> /dev/null; then 
        PrintMsg "196" "[FATAL] Docker daemon not found. Is the engine running?"
        exit 1
    fi

    # Interrogate the socket for containers outside the active project label
    local foreign_containers
    foreign_containers=$(sudo docker ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' | awk -F'|' -v stack="${StackName,,}" 'tolower($2) != stack && $1 != "" {print $1}')

    if [ -z "$foreign_containers" ]; then
        PrintMsg "82" "✔ Perimeter secure. No alien containers detected on the host."
        exit 0
    fi

    echo ""
    PrintMsg "214" "========================================================================"
    PrintMsg "214" "ALIEN CONTAINERS DETECTED"
    PrintMsg "214" "Found containers operating outside the ${StackName} perimeter."
    PrintMsg "214" "========================================================================"
    echo ""
    
    for container in $foreign_containers; do
        # Sanitize container names to prevent shell injection in our generated YAML
        local clean_name=$(echo "$container" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
        local manifest_file="${ManifestDir}/${clean_name}_Integration.yml"
        
        # Read existing state memory from the Docker daemon
        local has_traefik=$(sudo docker inspect --format='{{index .Config.Labels "traefik.enable"}}' "$container" 2>/dev/null || echo "")
        local current_middlewares=$(sudo docker inspect --format='{{index .Config.Labels "traefik.http.routers.'$clean_name'.middlewares"}}' "$container" 2>/dev/null || echo "")
        
        local needs_update=1
        
        # Determine if the container is already properly armored
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

        # Generate the blueprint if authorized
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
                echo ""
                PrintMsg "226" " [2] BasicAuth (Password Wall)"
                PrintMsg "240" "     Middlewares: secure-headers@file, traefik-auth@file"
                PrintMsg "240" "     Behavior:    Accessible publicly, but enforces cryptographic authentication."
                echo ""
                PrintMsg "196" " [3] Fully Public (NO ARMOR - EXTREME DANGER)"
                PrintMsg "240" "     Middlewares: secure-headers@file"
                PrintMsg "240" "     Behavior:    Bare-metal exposure to the public internet."
                echo ""
                PrintMsg "244" " [4] Internal Backend (Completely Ignored)"
                PrintMsg "240" "     Behavior:    Container is hidden from Traefik. For internal DBs."
                PrintMsg "214" "------------------------------------------------------------------------"
                echo ""

                if command -v gum &> /dev/null; then
                    local choice=$(gum choose "1) VPN-Only" "2) BasicAuth" "3) Fully Public" "4) Internal Backend")
                    posture_choice=${choice:0:1}
                else
                    read -p "Select posture for [$container] (1-4): " posture_choice || echo ""
                fi
            fi
            
            # Map choice to exact middleware strings
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
            
            # Write the deterministic YAML block to the disk
            sudo tee "$manifest_file" > /dev/null << MANIFEST_EOF
# ==============================================================================
# TRAEFIK INTEGRATION MANIFEST FOR: $container
# TARGET ARCHITECTURE: $StackName
# ==============================================================================
# POSTURE: Option $posture_choice
# MIDDLEWARES: $mw_string
# ==============================================================================
# INSTRUCTIONS:
# 1. Open the original docker-compose.yml file where '$container' is defined.
# 2. Add '$ProxyNetworkName' to your bottom networks block.
# 3. Paste the networks and labels sections below into your service definition.
# 4. Replace <PORT> with the actual internal listening port of your application.
# 5. Re-run 'docker compose up -d' on your original stack.
# 
# SATELLITE NODE WARNING:
# If this is running on a remote NAS or server, Traefik will NOT see these labels 
# unless Traefik is configured to connect to this machine's Docker Socket via 
# a remote provider array in its core configuration.
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