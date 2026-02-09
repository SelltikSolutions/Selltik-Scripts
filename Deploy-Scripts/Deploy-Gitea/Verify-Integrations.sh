#!/bin/bash
# ==============================================================================
# File: Verify-Integrations.sh
# Description: Day-2 Forensic Integration Audit.
#              Validates internal container networking and dependency wiring.
#              Rev 2: Fixed Portainer Agent check (Switched to Docker Inspect).
# Author: Tier-3 Support
# ==============================================================================

# Configuration
STACK_DIR="/opt/Docker/Stacks/Gitea"
SECRETS_DIR="${STACK_DIR}/secrets"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_pass() { echo -e "[${GREEN}PASS${NC}] $1"; }
log_fail() { echo -e "[${RED}FAIL${NC}] $1"; }
log_info() { echo -e "[${BLUE}INFO${NC}] $1"; }

echo "================================================"
echo "   Forensic Integration Audit (East-West Traffic)"
echo "================================================"

# 1. Gitea -> Database (Postgres)
# ------------------------------------------------------------------------------
log_info "Verifying Gitea -> Database link..."
# Verify config points to postgres
DB_TYPE=$(docker exec Gitea grep "DB_TYPE" /data/gitea/conf/app.ini 2>/dev/null | awk '{print $3}')
if [ "$DB_TYPE" == "postgres" ]; then
    # Test TCP connectivity from INSIDE Gitea container to Gitea-DB container
    if docker exec Gitea sh -c 'nc -z gitea-db 5432' 2>/dev/null; then
        log_pass "Configured for Postgres and socket is reachable (Port 5432)."
    else
        log_fail "Configured for Postgres, but TCP connection to 'gitea-db:5432' failed."
    fi
else
    log_fail "Gitea is NOT configured for Postgres (Current: $DB_TYPE)."
fi

# 2. Gitea -> Cache/Queue (Redis)
# ------------------------------------------------------------------------------
log_info "Verifying Gitea -> Redis link..."
# Verify config points to redis
CACHE_ADAPTER=$(docker exec Gitea grep "ADAPTER" /data/gitea/conf/app.ini 2>/dev/null | grep redis)
if [ -n "$CACHE_ADAPTER" ]; then
    # Test TCP connectivity
    if docker exec Gitea sh -c 'nc -z gitea-cache 6379' 2>/dev/null; then
        log_pass "Configured for Redis and socket is reachable (Port 6379)."
    else
        log_fail "Configured for Redis, but TCP connection to 'gitea-cache:6379' failed."
    fi
else
    log_fail "Gitea is NOT configured for Redis adapter."
fi

# 3. Runner -> Socket Proxy
# ------------------------------------------------------------------------------
log_info "Verifying Runner -> Socket Proxy link..."
# The runner needs to talk to the Docker Socket to spawn build jobs.
# We test if the Runner container can hit the Proxy API.
if docker exec Gitea-Runner wget -q -O - http://gitea-socket-proxy:2375/version >/dev/null 2>&1; then
    log_pass "Runner successfully authenticated with Socket Proxy (Port 2375)."
else
    log_fail "Runner CANNOT talk to Socket Proxy. CI/CD jobs will fail."
fi

# 4. Agent -> Socket (Standalone)
# ------------------------------------------------------------------------------
log_info "Verifying Agent -> Docker Socket link..."
# PATCH: Use 'docker inspect' on the host instead of 'mount' inside the container.
# The Portainer Agent image is minimal and lacks shell tools.
AGENT_MOUNTS=$(docker inspect Portainer-Agent --format '{{json .Mounts}}' 2>/dev/null)

if echo "$AGENT_MOUNTS" | grep -q "docker.sock"; then
    log_pass "Docker Socket is mounted (Verified via Docker Daemon)."
else
    log_fail "Docker Socket NOT mounted in Agent. Portainer will show 'Down'."
fi

# 5. Ollama -> Hardware (Vulkan/ROCm)
# ------------------------------------------------------------------------------
if docker ps | grep -q "Ollama-Worker"; then
    log_info "Verifying Ollama -> Hardware link..."
    
    # Check if the render device is visible inside
    # Ollama container usually has 'ls'
    if docker exec Ollama-Worker ls -l /dev/dri 2>/dev/null | grep -q "render"; then
        log_pass "Render devices are visible inside Ollama container."
    else
        log_fail "No Render devices found inside Ollama. CPU Fallback likely."
    fi
    
    # Check if Vulkan is enabled if applicable
    if docker exec Ollama-Worker env | grep -q "OLLAMA_VULKAN=1"; then
        log_pass "Vulkan Override is ACTIVE."
    fi
fi

echo "================================================"