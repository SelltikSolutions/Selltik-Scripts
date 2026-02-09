#!/bin/bash

# ==============================================================================
#  DEPLOY_CREDS.SH - PANOPTICON ECOSYSTEM DASHBOARD (v74.0 - CORNER FIX)
# ==============================================================================
#  ARCHITECTURE: Nested UI Engine -> Dual-Root Discovery -> Strict Scoping
#  SECURITY: Sudo enforced. Memory-resident strings. Panic Wipe active.
#  LOGIC:
#    - Visual Repair: Fixed Stack Wrapper Top-Right Corner (╗) printing after
#      color reset, forcing it to inherit the border color correctly.
#    - Geometry: Retains pixel-perfect padding (4 spaces) and centering.
#    - Entropy Engine: "No-Repeat" random color generation active.
# ==============================================================================

if [[ $EUID -ne 0 ]]; then 
    echo -e "\033[0;31mOpSec Failure: Root privileges required for deep inspection.\033[0m"
    exit 1
fi

# --- CONFIGURATION ---
BASE_DIR="${DOCKER_ROOT:-/opt/Docker}"
STACKS_DIR="$BASE_DIR/Stacks"
GLOBAL_SECRETS_DIR="$BASE_DIR/Config/Secrets"
LAN_IP=$(hostname -I | awk '{print $1}')

# Smart IP Fallback
if [ -z "$LAN_IP" ]; then
    LAN_IP=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{print $7}')
fi
LAN_IP=${LAN_IP:-"127.0.0.1"}

RESERVED=("Config" "Data" "Scripts" "Secrets" "Backups" "Stacks")
REAL_USER="${SUDO_USER:-$(whoami)}"
USER_HOME=$([ "$REAL_USER" == "root" ] && echo "/root" || echo "/home/$REAL_USER")

GLOBAL_SEARCH_PATHS=( "$GLOBAL_SECRETS_DIR" "$USER_HOME/secrets" "$USER_HOME/Secrets" "$USER_HOME/.secrets" )
GENERIC_TERMS="server|proxy|agent|worker|socket|app|db|database|container|daemon|service|runner|cache|web|ssh|core|hub"
ENV_FILTER="PUID|PGID|TZ|SYS_TZ|DOCKER_MODS|UMASK|^#|^$|HOST_IP"

# --- VISUAL SCHEME ---
# Standard Octal Escapes for echo -e / printf %b
NC=$'\e[0m'; BOLD=$'\e[1m'

# Neon Palette (High Intensity)
R=$'\e[38;5;196m'; G=$'\e[38;5;46m'; Y=$'\e[38;5;226m'; B=$'\e[38;5;21m'
P=$'\e[38;5;201m'; C=$'\e[38;5;51m'; W=$'\e[38;5;255m'; DG=$'\e[38;5;240m'
# Extended Cool Tones for Borders
O=$'\e[38;5;208m'; V=$'\e[38;5;93m'; T=$'\e[38;5;50m'; M=$'\e[38;5;163m'

# Theming
LB=$'\e[38;5;45m'   # Sky Blue (Labels)
LG=$'\e[38;5;154m'  # Matrix Green (Latency)
CLR_LABEL=$LB
CLR_VAL=$W
CLR_LATENCY=$LG

# Stack Colors
CLR_STACK_BORDER=$P
CLR_STACK_TITLE=$C

# --- COLOR ROTATION ENGINE ---
# Palette: Cyan, Magenta, Blue, Orange, Violet, Teal
BORDER_PALETTE=( "$C" "$P" "$B" "$O" "$V" "$T" )
PALETTE_LEN=${#BORDER_PALETTE[@]}
BOX_CTR=0
CURRENT_BORDER_COLOR="${BORDER_PALETTE[0]}"
LAST_IDX=999

# Options: "random", "cycle"
BORDER_MODE="random"

get_border_color() {
    if [ "$BORDER_MODE" == "random" ]; then
        local new_idx
        # Force a new color that isn't the same as the last one
        while :; do
            new_idx=$((RANDOM % PALETTE_LEN))
            if [ "$new_idx" -ne "$LAST_IDX" ]; then
                LAST_IDX=$new_idx
                echo "${BORDER_PALETTE[$new_idx]}"
                break
            fi
        done
    else
        echo "${BORDER_PALETTE[$((BOX_CTR % PALETTE_LEN))]}"
    fi
}

rotate_counter() {
    BOX_CTR=$((BOX_CTR + 1))
}

# --- GLOBAL STATE ---
UI_MODE="ASCII"
RENDER_BUFFER=""
BUFFER_TITLE=""
MAIN_WIDTH=90
BOX_WIDTH=80

# --- SECURITY ---
cleanup() { tput cnorm; clear; echo -e "${R}${BOLD}VAULT SECURED. SESSION WIPED.${NC}"; exit; }
trap cleanup SIGINT SIGTERM

# ==============================================================================
#  DEPENDENCY MANAGEMENT
# ==============================================================================
check_dependencies() {
    if command -v gum &> /dev/null; then UI_MODE="GUM"; else UI_MODE="ASCII"; fi
}

# ==============================================================================
#  RENDER ENGINE
# ==============================================================================

get_clean_len() {
    local input="$1"
    local clean=$(echo -e "$input" | sed "s/$(printf '\e')\[[0-9;]*m//g")
    echo ${#clean}
}

start_box() {
    BUFFER_TITLE="$1"
    RENDER_BUFFER=""
    CURRENT_BORDER_COLOR=$(get_border_color)
    rotate_counter
}

add_row() {
    local label="$1"; local value="$2"
    local max_val_len=$((BOX_WIDTH - 22))
    local safe_val=$(echo "$value" | tr -d '\n\r' | cut -c 1-$max_val_len)
    
    local val_len=$(get_clean_len "$safe_val")
    local pad_len=$(( max_val_len - val_len ))
    local padding=""; for ((i=0; i<pad_len; i++)); do padding="${padding} "; done
    
    local label_len=$(get_clean_len "$label")
    local label_pad=$(( 15 - label_len ))
    local l_space=""; for ((i=0; i<label_pad; i++)); do l_space="${l_space} "; done
    
    # Format: BORDER | LABEL (Sky Blue) | VALUE (White) | BORDER
    local line
    line=$(printf "%s%s│%s %s%s%s%s %s│%s %s%s%s%s %s│%s%s" \
        "${NC}" "${CURRENT_BORDER_COLOR}" "${NC}" \
        "${CLR_LABEL}" "${label}" "${NC}" "${l_space}" \
        "${CURRENT_BORDER_COLOR}" "${NC}" \
        "${CLR_VAL}" "${safe_val}" "${NC}" "${padding}" \
        "${CURRENT_BORDER_COLOR}" "${NC}")
    
    RENDER_BUFFER="${RENDER_BUFFER}${line}"$'\n'
}

draw_status_row() {
    local label="Status"
    local raw_status="$1"
    local status_plain="$2"
    local latency="$3"
    
    local max_val_len=$((BOX_WIDTH - 22))
    local full_plain="${status_plain} ${latency}"
    local visible_len=$(get_clean_len "$full_plain")
    local pad_len=$(( max_val_len - visible_len ))
    local padding=""; for ((i=0; i<pad_len; i++)); do padding="${padding} "; done
    
    local line
    line=$(printf "%s%s│%s %s%-15s%s %s│%s %s %s%s%s%s %s│%s%s" \
        "${NC}" "${CURRENT_BORDER_COLOR}" "${NC}" \
        "${CLR_LABEL}" "${label}" "${NC}" \
        "${CURRENT_BORDER_COLOR}" "${NC}" \
        "${raw_status}" "${CLR_LATENCY}" "${latency}" "${NC}" "${padding}" \
        "${CURRENT_BORDER_COLOR}" "${NC}")
        
    RENDER_BUFFER="${RENDER_BUFFER}${line}"$'\n'
}

add_sep() {
    local type=$1
    local line=""
    if [ "$type" == "sub" ]; then
        local dash_len=$((29))
        local dash_line=""; for ((i=0; i<dash_len; i++)); do dash_line="${dash_line} -"; done
        line=$(printf "%s%s│%s %-15s %s│%s %s%s%s %s│%s%s" \
            "${NC}" "${CURRENT_BORDER_COLOR}" "${NC}" \
            "" \
            "${CURRENT_BORDER_COLOR}" "${NC}" \
            "${DG}" "${dash_line}" "${NC}" \
            "${CURRENT_BORDER_COLOR}" "${NC}")
    else
        # Width 80: 1(L) + 17(LabelCol) + 1(Mid) + 60(ValCol) + 1(R)
        local right_len=$((BOX_WIDTH - 20)) # 60 chars
        local right_dash=""; for ((i=0; i<right_len; i++)); do right_dash="${right_dash}─"; done
        line=$(printf "%s%s├%s─────────────────%s┼%s%s%s┤%s%s" \
            "${NC}" "${CURRENT_BORDER_COLOR}" \
            "${CURRENT_BORDER_COLOR}" \
            "${CURRENT_BORDER_COLOR}" \
            "${CURRENT_BORDER_COLOR}" "${right_dash}" \
            "${CURRENT_BORDER_COLOR}" "${NC}")
    fi
    RENDER_BUFFER="${RENDER_BUFFER}${line}"$'\n'
}

draw_group_sep() {
    add_sep "sub"
}

render_box_to_string() {
    [ -z "$RENDER_BUFFER" ] && return
    
    local OUT=""
    local title_len=$(get_clean_len "$BUFFER_TITLE")
    local inner_width=$((BOX_WIDTH - 6)) # 80 - 2 corners - 4 brackets/spaces
    local pad=$(( (inner_width - title_len) / 2 ))
    local top_border=""; for ((i=0; i<pad; i++)); do top_border="${top_border}─"; done
    
    OUT+=$(printf "%s%s┌%s[ %s%s%s ]" "${NC}" "${CURRENT_BORDER_COLOR}" "${top_border}" "${BOLD}" "${BUFFER_TITLE}" "${NC}${CURRENT_BORDER_COLOR}")
    
    local cur=$(( pad + title_len + 4 ))
    local rem=$(( BOX_WIDTH - cur - 2 ))
    local right_border=""; for ((i=0; i<rem; i++)); do right_border="${right_border}─"; done
    OUT+=$(printf "%s%s┐%s" "${CURRENT_BORDER_COLOR}" "${right_border}" "${NC}")$'\n'

    # Grid Header
    local right_len=$((BOX_WIDTH - 20))
    local right_dash=""; for ((i=0; i<right_len; i++)); do right_dash="${right_dash}─"; done
    local grid_header=$(printf "%s%s├%s─────────────────%s┬%s%s%s┤%s%s" \
        "${NC}" "${CURRENT_BORDER_COLOR}" \
        "${CURRENT_BORDER_COLOR}" \
        "${CURRENT_BORDER_COLOR}" \
        "${CURRENT_BORDER_COLOR}" "${right_dash}" \
        "${CURRENT_BORDER_COLOR}" "${NC}")
    
    OUT+="${grid_header}"$'\n'
    OUT+="$RENDER_BUFFER"
    
    # Footer (Bottom T)
    local bot_left_len=17
    local bot_right_len=$((BOX_WIDTH - 20))
    local bl=""; for ((i=0; i<bot_left_len; i++)); do bl="${bl}─"; done
    local br=""; for ((i=0; i<bot_right_len; i++)); do br="${br}─"; done
    
    OUT+=$(printf "%s%s└%s┴%s┘%s" "${NC}" "${CURRENT_BORDER_COLOR}" "${bl}" "${br}" "${NC}")$'\n'
    
    echo -e "$OUT"
}

# --- STACK WRAPPER ---
draw_stack_wrapper() {
    local stack_title="$1"
    local content="$2"
    if [[ -z "${content//[[:space:]]/}" ]]; then return; fi
    
    # PADDING Math: (Main 90 - Box 80 - 2 Borders) / 2 = 4 spaces per side
    local PADDING_L="    " 
    local PADDING_R="    " 
    
    local title_len=$(get_clean_len "$stack_title")
    
    if [ $((title_len % 2)) -ne 0 ]; then
        stack_title="${stack_title} "
        title_len=$((title_len + 1))
    fi

    local t_pad=$(( (MAIN_WIDTH - 6 - title_len) / 2 ))
    local t_border=""; for ((i=0; i<t_pad; i++)); do t_border="${t_border}═"; done
    
    # COLOR FIX: Corner printed inside color scope
    printf "\n%s╔%s[ %s%s%s ]" "${CLR_STACK_BORDER}" "${t_border}" "${BOLD}${CLR_STACK_TITLE}" "${stack_title}" "${NC}${CLR_STACK_BORDER}"
    
    local used=$(( t_pad + title_len + 4 ))
    local rem=$(( MAIN_WIDTH - used - 2 )) 
    local r_border=""; for ((i=0; i<rem; i++)); do r_border="${r_border}═"; done
    
    # FIX: Corner '╗' printed BEFORE Reset ${NC}
    printf "%s╗%s\n" "${r_border}" "${NC}"
    
    while IFS= read -r line; do
         if [ -n "$line" ]; then
            printf "%s║%s%s%s%s%s║%s\n" "${CLR_STACK_BORDER}" "${NC}" "${PADDING_L}" "$line" "${PADDING_R}" "${CLR_STACK_BORDER}" "${NC}"
         fi
    done <<< "$content"
    
    local b_border=""; for ((i=0; i< (MAIN_WIDTH-2) ; i++)); do b_border="${b_border}═"; done
    printf "%s╚%s╝%s\n" "${CLR_STACK_BORDER}" "${b_border}" "${NC}"
}

draw_main_header() {
    local title="PARANOID STACK AUDITOR v74.0"
    local subtitle="[Corner Fix Edition]"
    local t_border=""; for ((i=0; i<$((MAIN_WIDTH-2)); i++)); do t_border="${t_border}═"; done
    
    printf "%s╔%s╗%s\n" "${CLR_STACK_BORDER}" "${t_border}" "${NC}"
    local row1_fmt="%s║%s %s%-40s%s %s%45s%s %s║%s\n"
    printf "$row1_fmt" "${CLR_STACK_BORDER}" "${NC}" "${BOLD}${CLR_STACK_TITLE}" "$title" "${NC}" "${DG}" "$subtitle" "${NC}" "${CLR_STACK_BORDER}" "${NC}"

    local time=$(date '+%H:%M:%S')
    local meta_str="Node: $LAN_IP   User: $REAL_USER   Time: $time"
    local meta_len=${#meta_str}
    local meta_pad=$(( MAIN_WIDTH - 4 - meta_len )) 
    local spacer=""; for ((i=0; i<meta_pad; i++)); do spacer="${spacer} "; done
    
    printf "%s║%s %s%s%s%s %s║%s\n" "${CLR_STACK_BORDER}" "${NC}" "${C}" "$meta_str" "${NC}" "$spacer" "${CLR_STACK_BORDER}" "${NC}"
    printf "%s╚%s╝%s\n" "${CLR_STACK_BORDER}" "${t_border}" "${NC}"
}

# ==============================================================================
#  DATA ANALYSIS FUNCTIONS
# ==============================================================================

get_status_colored() {
    local name=$1
    local status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "ghost")
    case "$status" in 
        running) echo -ne "${G}●${NC} ${G}ONLINE${NC}" ;; 
        exited) echo -ne "${R}●${NC} ${R}STOPPED${NC}" ;; 
        *) echo -ne "${Y}●${NC} ${Y}${status^^}${NC}" ;; 
    esac
}

get_status_plain() {
    local name=$1; local status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "GHOST")
    case "$status" in running) echo "● ONLINE" ;; exited) echo "● STOPPED" ;; *) echo "● ${status^^}" ;; esac
}

get_latency() {
    local name=$1
    local status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "ghost")
    if [ "$status" != "running" ]; then echo ""; return; fi
    local ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" | head -n 1)
    if [ -z "$ip" ]; then
        if docker inspect -f '{{.HostConfig.NetworkMode}}' "$name" 2>/dev/null | grep -q "host"; then echo "(host)"; return; fi
        echo "(n/a)"; return
    fi
    local ping_res=$(ping -c 3 -i 0.2 -W 1 -q "$ip" 2>/dev/null | awk -F'/' 'END{ print (/^rtt/? "("$5"ms)" : "(unreachable)") }')
    echo "${ping_res:-(timeout)}"
}

detect_service_meta() {
    local name=$1
    local image=$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || echo "")
    local proto="http"; local platform="Service"
    case "${image,,}" in
        *postgres*) proto="postgres"; platform="PostgreSQL" ;;
        *mysql*|*mariadb*) proto="mysql"; platform="MySQL/MariaDB" ;;
        *redis*|*valkey*) proto="redis"; platform="Redis Cache" ;;
        *mongo*) proto="mongodb"; platform="MongoDB" ;;
        *socket-proxy*) proto="tcp"; platform="Docker Socket Proxy" ;;
        *portainer/agent*) proto="tcp"; platform="Portainer Agent" ;;
        *ollama*) proto="http"; platform="AI/LLM Engine" ;;
        *gitea/gitea*) proto="http"; platform="Git Server" ;;
        *code-server*) proto="http"; platform="VS Code" ;;
        *wordpress*) proto="http"; platform="WordPress" ;;
    esac
    echo "$proto|$platform"
}

get_exposed_ports() {
    local name=$1
    docker port "$name" 2>/dev/null | awk -F':' '{print $2}' | cut -d' ' -f1 | sort -u | tr '\n' ' '
}

get_internal_ports() {
    docker inspect --format='{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}' "$1" 2>/dev/null
}

map_label() {
    local fn=$1
    case "${fn,,}" in
        *admin_user*|*admin_name*) echo "Admin User" ;; *admin_pass*) echo "Admin Pass" ;;
        *db_user*) echo "DB User" ;; *db_pass*|*database_pass*) echo "DB Pass" ;;
        *api_key*|*token*) echo "API / Token" ;; *redis_pass*) echo "Redis Pass" ;;
        *vscode_pass*) echo "VSCode Pass" ;; *) echo "Credential" ;;
    esac
}

# --- SEARCH LOGIC ---
search_standard() {
    local target_dir=$1; local svc_name=$2
    [ ! -d "$target_dir" ] && return
    local svc_snake=$(echo "$svc_name" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
    find "$target_dir" -maxdepth 1 -type f \( -name "${svc_snake}_*.txt" -o -name "${svc_snake}_*.secret" -o -name "${svc_snake}_*.key" \) 2>/dev/null
}

search_heuristic() {
    local target_dir=$1; local svc_name=$2; local stack_name=${3:-""}
    [ ! -d "$target_dir" ] && return
    local results=""; local search_term="$svc_name"
    if [[ "${svc_name,,}" != "${stack_name,,}" ]]; then
        results=$(find "$target_dir" -maxdepth 1 -type f -iname "*${svc_name}*" 2>/dev/null)
    fi
    if [[ -n "$stack_name" ]] && [[ "${svc_name,,}" == "${stack_name,,}"* ]] && [[ "${svc_name,,}" != "${stack_name,,}" ]]; then
        search_term=$(echo "$svc_name" | sed "s/^${stack_name}[-_]//I")
    fi
    IFS='-_' read -ra TOKENS <<< "$search_term"
    for token in "${TOKENS[@]}"; do
        if [[ "${token,,}" == "cache" ]]; then results=$(printf "%s\n%s" "$results" "$(find "$target_dir" -maxdepth 1 -type f -iname "*redis*" 2>/dev/null)"); fi
        if [[ "${GENERIC_TERMS}" =~ "${token,,}" ]] || [ ${#token} -lt 3 ]; then continue; fi
        if [[ -n "$stack_name" ]] && [[ "${token,,}" == "${stack_name,,}" ]]; then continue; fi
        results=$(printf "%s\n%s" "$results" "$(find "$target_dir" -maxdepth 1 -type f -iname "*${token}*" 2>/dev/null)")
    done
    if [[ -n "$stack_name" ]] && [[ "${svc_name,,}" == "${stack_name,,}" ]]; then
        local stack_res=$(find "$target_dir" -maxdepth 1 -type f -iname "*${stack_name}*" 2>/dev/null)
        stack_res=$(echo "$stack_res" | grep -viE "db|database|redis|cache|postgres|mysql|mongo|runner|proxy|agent")
        results=$(printf "%s\n%s" "$results" "$stack_res")
    fi
    echo "$results"
}

scrape_env_vars() {
    local svc_name=$1; local env_file=$2
    [ ! -f "$env_file" ] && return
    grep "^${svc_name^^}_" "$env_file" | grep -vE "$ENV_FILTER" || true
    if [[ "${svc_name,,}" =~ (db|database|postgres|mysql|mongo) ]]; then grep -E "^(DB_|POSTGRES_|MYSQL_|MONGO_)" "$env_file" | grep -vE "$ENV_FILTER" || true; fi
    if [[ "${svc_name,,}" =~ (redis|cache|memcached) ]]; then grep -E "^(REDIS_|CACHE_|MEMCACHED_)" "$env_file" | grep -vE "$ENV_FILTER" || true; fi
}

render_secrets() {
    local raw_list=$1; [ -z "$raw_list" ] && return
    mapfile -t ALL_FILES <<< "$raw_list"
    local CONTEXTS=("admin" "db" "redis" "runner" "vscode" "api" "token")
    local PROCESSED=(); local first_group=1
    for ctx in "${CONTEXTS[@]}"; do
        local group_files=(); for f in "${ALL_FILES[@]}"; do if [[ "${f,,}" == *"${ctx}"* ]]; then local skip=0; for p in "${PROCESSED[@]}"; do [[ "$p" == "$f" ]] && skip=1; done; [[ $skip -eq 0 ]] && group_files+=("$f"); fi; done
        if [ ${#group_files[@]} -gt 0 ]; then
            local u_files=(); local p_files=(); local o_files=()
            for gf in "${group_files[@]}"; do
                if [[ "${gf,,}" == *"user"* ]] || [[ "${gf,,}" == *"name"* ]]; then u_files+=("$gf"); elif [[ "${gf,,}" == *"pass"* ]]; then p_files+=("$gf"); else o_files+=("$gf"); fi; PROCESSED+=("$gf")
            done
            if [ $first_group -eq 0 ]; then draw_group_sep; fi; first_group=0
            for f in "${u_files[@]}"; do VAL=$(cat "$f" | tr -d '\n\r'); LABEL=$(map_label "$(basename "$f")"); add_row "$LABEL" "$VAL"; SEEN_SECRET_FILENAMES+=("$(basename "$f")"); done
            for f in "${p_files[@]}"; do VAL=$(cat "$f" | tr -d '\n\r'); LABEL=$(map_label "$(basename "$f")"); add_row "$LABEL" "$VAL"; SEEN_SECRET_FILENAMES+=("$(basename "$f")"); done
            for f in "${o_files[@]}"; do VAL=$(cat "$f" | tr -d '\n\r'); LABEL=$(map_label "$(basename "$f")"); add_row "$LABEL" "$VAL"; SEEN_SECRET_FILENAMES+=("$(basename "$f")"); done
        fi
    done
    local orphans=(); for f in "${ALL_FILES[@]}"; do local skip=0; for p in "${PROCESSED[@]}"; do [[ "$p" == "$f" ]] && skip=1; done; [[ $skip -eq 0 ]] && orphans+=("$f"); done
    if [ ${#orphans[@]} -gt 0 ]; then
        if [ $first_group -eq 0 ]; then draw_group_sep; fi
        for f in "${orphans[@]}"; do VAL=$(cat "$f" | tr -d '\n\r'); LABEL=$(map_label "$(basename "$f")"); add_row "$LABEL" "$VAL"; SEEN_SECRET_FILENAMES+=("$(basename "$f")"); done
    fi
}

# ==============================================================================
#  MAIN EXECUTION
# ==============================================================================
check_dependencies
clear
draw_main_header

SEEN_FILES=(); SEEN_CONTAINERS=(); SEEN_SECRET_FILENAMES=()
SCAN_ROOTS=("$STACKS_DIR" "$BASE_DIR")

# --- PHASE 1: MANAGED STACKS ---
for ROOT_DIR in "${SCAN_ROOTS[@]}"; do
    if [ -d "$ROOT_DIR" ]; then
        for STACK_PATH in "$ROOT_DIR"/*; do
            [ -d "$STACK_PATH" ] || continue
            STACK_NAME=$(basename "$STACK_PATH")
            is_res=0; for r in "${RESERVED[@]}"; do [[ "$STACK_NAME" == "$r" ]] && is_res=1; done; [[ $is_res -eq 1 ]] && continue
            ENV_FILE="$STACK_PATH/.env"; COMPOSE_FILE="$STACK_PATH/docker-compose.yml"
            [ ! -f "$COMPOSE_FILE" ] && [ ! -f "$ENV_FILE" ] && continue
            is_seen=0; for s in "${SEEN_FILES[@]}"; do [[ "$STACK_PATH" == "$s" ]] && is_seen=1; done; [[ $is_seen -eq 1 ]] && continue
            SEEN_FILES+=("$STACK_PATH")

            STACK_CONTENT=""
            SERVICES=$(grep -E 'container_name:|PORT_' "$COMPOSE_FILE" "$ENV_FILE" 2>/dev/null | awk -F':|_' '{print $NF}' | tr -d ' "' | sort | uniq | grep -vE '^.{0,2}$' || echo "$STACK_NAME")

            for SVC in $SERVICES; do
                if [ -n "$SVC" ]; then SEEN_CONTAINERS+=("${SVC^^}"); else continue; fi
                
                MATCHES_RAW=""; PORT=$(grep "^PORT_${SVC^^}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || true)
                STATUS_COL=$(get_status_colored "$SVC"); STATUS_PLN=$(get_status_plain "$SVC")
                LATENCY=$(get_latency "$SVC")
                
                META_RAW=$(detect_service_meta "$SVC"); PROTO=${META_RAW%|*}; PLATFORM=${META_RAW#*|}
                INT_PORTS=$(get_internal_ports "$SVC"); LIVE_PORTS=$(get_exposed_ports "$SVC")

                LOCAL_VAULT="$STACK_PATH/secrets"
                L_STD=$(search_standard "$LOCAL_VAULT" "$SVC"); L_HEUR=$(search_heuristic "$LOCAL_VAULT" "$SVC" "$STACK_NAME")
                MATCHES_RAW=$(printf "%s\n%s\n%s" "$MATCHES_RAW" "$L_STD" "$L_HEUR")
                for G_PATH in "${GLOBAL_SEARCH_PATHS[@]}"; do
                    G_STD=$(search_standard "$G_PATH" "$SVC"); G_HEUR=$(search_heuristic "$G_PATH" "$SVC" "$STACK_NAME")
                    MATCHES_RAW=$(printf "%s\n%s\n%s" "$MATCHES_RAW" "$G_STD" "$G_HEUR")
                done
                MATCHES=$(echo "$MATCHES_RAW" | sort -u | grep -v "^$" || true)
                if [[ -n "$STACK_NAME" ]] && [[ "${SVC,,}" == "${STACK_NAME,,}" ]]; then MATCHES=$(echo "$MATCHES" | grep -viE "db|database|redis|cache|postgres|mysql|mongo|runner|proxy|agent"); fi

                [[ "$STATUS_PLN" == *"GHOST"* ]] && [ -z "$MATCHES" ] && [ -z "$PORT" ] && [ -z "$LIVE_PORTS" ] && continue

                start_box "${SVC^^}"
                draw_status_row "$STATUS_COL" "$STATUS_PLN" "$LATENCY"
                add_sep
                add_row "Platform" "$PLATFORM"
                if [ -n "$LIVE_PORTS" ]; then
                    for p in $LIVE_PORTS; do
                        add_row "LAN URL" "${PROTO}://${LAN_IP}:${p}"
                        add_row "Local URL" "${PROTO}://127.0.0.1:${p}"
                    done
                elif [ -n "$PORT" ]; then add_row "Config URL" "${PROTO}://${LAN_IP}:${PORT}"; fi
                if [ -n "$INT_PORTS" ]; then for ip in $INT_PORTS; do CLN_P=${ip%%/*}; add_row "Docker URL" "${PROTO}://${SVC}:${CLN_P}"; done; fi

                if [ -f "$ENV_FILE" ]; then
                    ENV_MATCHES=$(scrape_env_vars "$SVC" "$ENV_FILE")
                    if [ -n "$ENV_MATCHES" ]; then
                        add_sep
                        while IFS= read -r line; do
                            [ -z "$line" ] && continue
                            K=$(echo "$line" | cut -d'=' -f1 | sed "s/^${SVC^^}_//" | sed "s/^POSTGRES_//")
                            V=$(echo "$line" | cut -d'=' -f2-)
                            add_row "$K" "$V"
                        done <<< "$ENV_MATCHES"
                    fi
                fi
                if [ -n "$MATCHES" ]; then add_sep; render_secrets "$MATCHES"; fi
                
                BOX_OUT=$(render_box_to_string)
                STACK_CONTENT+="${BOX_OUT}"$'\n'
            done
            
            draw_stack_wrapper "${STACK_NAME} (${ROOT_DIR##*/})" "$STACK_CONTENT"
        done
    fi
done

# --- PHASE 2: UNMANAGED ---
STACK_CONTENT=""
ALL_RUNNING=$(docker ps -a --format '{{.Names}}')
for CONTAINER in $ALL_RUNNING; do
    is_seen=0
    for seen in "${SEEN_CONTAINERS[@]}"; do if [[ "${CONTAINER^^}" == *"${seen}"* ]] || [[ "${seen}" == *"${CONTAINER^^}"* ]]; then is_seen=1; break; fi; done; [[ $is_seen -eq 1 ]] && continue

    STATUS_COL=$(get_status_colored "$CONTAINER"); STATUS_PLN=$(get_status_plain "$CONTAINER")
    LATENCY=$(get_latency "$CONTAINER")
    LIVE_PORTS=$(get_exposed_ports "$CONTAINER"); MATCHES_RAW=""
    META_RAW=$(detect_service_meta "$CONTAINER"); PROTO=${META_RAW%|*}; PLATFORM=${META_RAW#*|}
    INT_PORTS=$(get_internal_ports "$CONTAINER")

    for G_PATH in "${GLOBAL_SEARCH_PATHS[@]}"; do
        G_STD=$(search_standard "$G_PATH" "$CONTAINER"); G_HEUR=$(search_heuristic "$G_PATH" "$CONTAINER" "")
        MATCHES_RAW=$(printf "%s\n%s\n%s" "$MATCHES_RAW" "$G_STD" "$G_HEUR")
    done
    MATCHES=$(echo "$MATCHES_RAW" | sort -u | grep -v "^$" || true)

    start_box "${CONTAINER^^}"
    draw_status_row "$STATUS_COL" "$STATUS_PLN" "$LATENCY"
    add_sep
    add_row "Platform" "$PLATFORM"
    if [ -n "$LIVE_PORTS" ]; then 
        for p in $LIVE_PORTS; do 
            add_row "LAN URL" "${PROTO}://${LAN_IP}:${p}"
            add_row "Local URL" "${PROTO}://127.0.0.1:${p}"
        done
    fi
    if [ -n "$INT_PORTS" ]; then for ip in $INT_PORTS; do CLN_P=${ip%%/*}; add_row "Docker URL" "${PROTO}://${CONTAINER}:${CLN_P}"; done; fi

    if [ -n "$MATCHES" ]; then add_sep; render_secrets "$MATCHES"; fi
    
    BOX_OUT=$(render_box_to_string)
    STACK_CONTENT+="${BOX_OUT}"$'\n'
done
if [ -n "$STACK_CONTENT" ]; then draw_stack_wrapper "UNMANAGED WORKLOADS" "$STACK_CONTENT"; fi

# --- PHASE 3: GLOBAL ---
STACK_CONTENT=""
ORPHAN_FOUND=0
LEFTOVERS_LIST=""
for SEARCH_PATH in "${GLOBAL_SEARCH_PATHS[@]}"; do
    if [ -d "$SEARCH_PATH" ]; then
        while read -r f; do
            [ ! -f "$f" ] && continue; F_NAME=$(basename "$f"); [[ "$F_NAME" == ".env" ]] && continue
            is_seen=0; for seen in "${SEEN_SECRET_FILENAMES[@]}"; do [[ "$F_NAME" == "$seen" ]] && is_seen=1 && break; done
            if [[ $is_seen -eq 0 ]]; then LEFTOVERS_LIST=$(printf "%s\n%s" "$LEFTOVERS_LIST" "$f"); ORPHAN_FOUND=1; fi
        done < <(find "$SEARCH_PATH" -maxdepth 1 -type f)
    fi
done

if [ -n "$LEFTOVERS_LIST" ]; then
    start_box "GLOBAL SECRETS"
    render_secrets "$LEFTOVERS_LIST"
    BOX_OUT=$(render_box_to_string)
    STACK_CONTENT+="${BOX_OUT}"
fi
if [ -n "$STACK_CONTENT" ]; then draw_stack_wrapper "INFRASTRUCTURE VAULT" "$STACK_CONTENT"; fi

echo -e "\n${BOLD}${R}Audit Complete.${NC} ${R}Press 'q' to Purge and Exit.${NC}"; read -n 1 -s -r -p ""; cleanup