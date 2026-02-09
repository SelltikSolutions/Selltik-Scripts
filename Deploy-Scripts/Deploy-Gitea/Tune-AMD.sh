#!/bin/bash
# ==============================================================================
# File: Tune-AMD.sh
# Description: Hot-patcher for AMD ROCm Configurations.
#              Rapidly iterates HSA versions, Feature flags, and Device IDs.
# Usage: sudo ./Tune-AMD.sh
# ==============================================================================

ENV_FILE="/opt/Docker/Stacks/Gitea/.env"
COMPOSE_FILE="/opt/Docker/Stacks/Gitea/docker-compose.yml"
AUDIT_TOOL="/opt/Docker/Stacks/Gitea/audit/verify_gpu.py"
AUDIT_DIR="/opt/Docker/Stacks/Gitea/audit"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then echo "Root required."; exit 1; fi

echo -e "${YELLOW}=== AMD ROCm/Vulkan Tuner ===${NC}"

# 0. Topology Check
echo -e "\n${BLUE}[*] Host Render Devices:${NC}"
ls -l /dev/dri/renderD*
# Auto-detect primary index
RENDER_PATH=$(ls /dev/dri/renderD* | head -n 1)
if [[ "$RENDER_PATH" =~ renderD([0-9]+) ]]; then
    RENDER_NUM=${BASH_REMATCH[1]}
    HIP_INDEX=$((RENDER_NUM - 128))
else
    HIP_INDEX=0
fi

# 1. Architecture Selection
echo -e "\nSelect Hardware Strategy:"
echo "1) ROCm: 10.3.0 (RDNA 2 / Navi 1x Spoof) [Standard]"
echo "2) ROCm: 10.1.0 (RDNA 1 Native) [Legacy]"
echo "3) ROCm: 8.0.3  (Polaris)"
echo "4) ROCm: 9.0.0  (Vega)"
echo "5) VULKAN: Generic Compute [Resurrection Mode]"
read -p "Choice [1]: " HSA_OPT

VULKAN_MODE="0"
LIB_OVERRIDE="rocm"

case $HSA_OPT in
    2) HSA_VER="10.1.0" ;;
    3) HSA_VER="8.0.3" ;;
    4) HSA_VER="9.0.0" ;;
    5) 
        HSA_VER="10.3.0" # Placeholder, unused in Vulkan
        VULKAN_MODE="1"
        LIB_OVERRIDE="" # Clear override to allow Auto-Discovery to find Vulkan
        ;;
    *) HSA_VER="10.3.0" ;;
esac

# 2. Device Selection
echo -e "\nTarget GPU Index (HIP_VISIBLE_DEVICES):"
echo "Auto) Device $HIP_INDEX (Detected)"
echo "   X) UNFILTERED (See all devices - Recommended)"
read -p "Choice [Auto]: " DEV_OPT

if [[ "${DEV_OPT^^}" == "X" ]]; then
    DEV_VAL=""
    echo " -> Clearing Device Pinning (Unfiltered)"
else
    DEV_VAL=${DEV_OPT:-$HIP_INDEX}
    echo " -> Pinning to Device $DEV_VAL"
fi

# 3. Flash Attention (Not applicable to Vulkan, but kept for ROCm)
if [ "$VULKAN_MODE" == "0" ]; then
    echo -e "\nFlash Attention:"
    echo "0) Disabled [Safe - Default]"
    echo "1) Enabled [Risky]"
    read -p "Choice [0]: " ATTN_OPT
    ATTN_VAL=${ATTN_OPT:-0}
else
    ATTN_VAL="0"
fi

# 4. Patching .env
echo -e "\n${YELLOW}[*] Patching .env...${NC}"

# Helper to update or append
update_env() {
    local key=$1
    local val=$2
    if [ -z "$val" ]; then
        sed -i "/^$key=/d" "$ENV_FILE"
    elif grep -q "^$key=" "$ENV_FILE"; then
        sed -i "s|^$key=.*|$key=$val|" "$ENV_FILE"
    else
        echo "$key=$val" >> "$ENV_FILE"
    fi
}

update_env "HSA_OVERRIDE_GFX_VERSION" "$HSA_VER"
update_env "HIP_VISIBLE_DEVICES" "$DEV_VAL"
update_env "ROCR_VISIBLE_DEVICES" "$DEV_VAL"
update_env "OLLAMA_FLASH_ATTENTION" "$ATTN_VAL"
update_env "OLLAMA_VULKAN" "$VULKAN_MODE"
update_env "OLLAMA_LLM_LIBRARY" "$LIB_OVERRIDE"

# Stability Flags
update_env "HSA_ENABLE_SDMA" "0" 
update_env "HSA_ENABLE_INTERRUPT" "0"
update_env "DT_LOCAL_MEM_OBEY_NUMA" "1"

# Logging & Limits
update_env "OLLAMA_DEBUG" "1"
sed -i '/^OLLAMA_NUM_GPU=/d' "$ENV_FILE"

echo "Applied: VULKAN=$VULKAN_MODE | HSA=$HSA_VER | DEV=${DEV_VAL:-Unfiltered}"

# 5. Patching docker-compose (Permissions Sledgehammer)
if ! grep -q "privileged: true" "$COMPOSE_FILE"; then
    echo -e "${YELLOW}[*] Injecting Privileged Mode into Compose...${NC}"
    sed -i '/image: ollama\/ollama:latest/a \    privileged: true' "$COMPOSE_FILE"
fi

# 6. Regenerate Audit Tool
echo -e "${YELLOW}[*] Regenerating Audit Tool...${NC}"
mkdir -p "$AUDIT_DIR"
cat << 'EOF' > "$AUDIT_TOOL"
#!/usr/bin/env python3
import urllib.request
import json
import time
import sys

# Hardcoded for local verification
API_URL = "http://127.0.0.1:11434/api/generate"
PULL_URL = "http://127.0.0.1:11434/api/pull"
MODEL = "tinyllama"

def log(msg, level="INFO"): 
    colors = {"INFO": "\033[94m", "SUCCESS": "\033[92m", "ERROR": "\033[91m", "RESET": "\033[0m"}
    print(f"{colors.get(level,'')}[{level}] {msg}{colors['RESET']}")

def run_test():
    log(f"Probing Ollama API with model '{MODEL}'...", "INFO")
    
    # 1. Check/Pull Model
    pull_data = json.dumps({"name": MODEL}).encode("utf-8")
    try:
        req = urllib.request.Request(PULL_URL, data=pull_data, headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req) as r:
            for _ in r: pass
        log("Model check/pull complete.", "SUCCESS")
    except Exception as e:
        log(f"Model pull failed: {e}", "ERROR")
        return

    # 2. Inference
    data = json.dumps({"model": MODEL, "prompt": "GPU Check", "stream": False}).encode("utf-8")
    try:
        req = urllib.request.Request(API_URL, data=data, headers={'Content-Type': 'application/json'})
        start = time.time()
        with urllib.request.urlopen(req) as r:
            res = json.loads(r.read().decode())
            dur = time.time() - start
            log(f"Inference success: {dur:.2f}s", "SUCCESS")
    except Exception as e:
        log(f"Inference failed: {e}", "ERROR")

if __name__ == "__main__":
    run_test()
EOF
chmod +x "$AUDIT_TOOL"

# 7. Recreate & Verify
echo -e "${YELLOW}[*] Recreating Ollama Container...${NC}"
docker compose -f "$COMPOSE_FILE" up -d --force-recreate ollama-worker

echo -e "${YELLOW}[*] Waiting for API (15s)...${NC}"
for i in {1..15}; do printf "."; sleep 1; done
echo ""

echo -e "${YELLOW}[*] Running Inference Audit...${NC}"
python3 "$AUDIT_TOOL"

# 8. Forensic Log Dump
echo -e "\n${YELLOW}[*] Recent Logs (Compute Search):${NC}"
# Grep for Vulkan or ROCm success/failure
docker logs Ollama-Worker 2>&1 | grep -E "vulkan|rocm|kfd|driver|offload|compute|error|warning" | tail -n 20