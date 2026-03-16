#!/usr/bin/env bash

# =========================================================================
# PHANTOMBYTE: TIER-3 BASHRC DEPLOYMENT ENGINE
# PHASE 1: HOST TRIAGE & DEPENDENCY PROVISIONING
# =========================================================================

set -euo pipefail
IFS=$'\n\t'

# --- 1. PRIVILEGE & OS VALIDATION ---
if [[ "${EUID}" -eq 0 && "${USER}" != "root" ]]; then
    echo "[!] FATAL: Sudo execution detected in user context. Sudo is a dangerous drug. Drop it. Run as the target user."
    exit 1
fi

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    HOST_OS="${ID:-unknown}"
else
    echo "[!] FATAL: /etc/os-release not found. Unknown host anatomy."
    exit 1
fi

ALLOWED_OS=("parrot" "ubuntu" "debian" "raspbian" "kali")
if [[ ! " ${ALLOWED_OS[*]} " =~ ${HOST_OS} ]]; then
    echo "[!] FATAL: Host OS '${HOST_OS}' is alien. This script enforces Debian-specific constraints. Aborting."
    exit 1
fi

echo "[*] PhantomByte Protocol Initiated on OS: ${HOST_OS}"

# --- 2. THE AIR-GAP OVERRIDE & SYSTEM UPDATE ---
echo ""
echo "    [ WARN ] This deployment engine requires external dependencies."
echo "    [ WARN ] Proceeding will violate the Clean Room air-gap protocol."
echo "    [ WARN ] It will dial out to upstream repositories."
echo ""
read -r -p "Do you authorize the network breach to fetch dependencies and updates? (y/N): " NET_AUTH

if [[ "${NET_AUTH}" =~ ^[Yy]$ ]]; then
    echo "[*] Air-gap override acknowledged. The drawbridge is lowering..."
    
    # We must elevate to root for package management, but only for this specific block.
    # We use explicit sudo commands, not a blanket script elevation.
    echo "[*] Checking for host CVEs and stale packages..."
    sudo apt-get update -y
    
    read -r -p "Do you want to apply all pending system upgrades now? (y/N): " UPGRADE_AUTH
    if [[ "${UPGRADE_AUTH}" =~ ^[Yy]$ ]]; then
        echo "[*] Applying patches. Pray the upstream maintainers haven't compromised the repos."
        sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    else
        echo "[*] Upgrades bypassed. You are choosing to operate a potentially vulnerable host."
    fi

    # --- 3. DEPENDENCY PROVISIONING ---
    REQUIRED_PKGS=("gum" "bsdutils" "sed" "coreutils") # bsdutils provides 'logger'
    
    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            echo "[*] Missing critical binary: $pkg. Attempting to summon it..."
            if [[ "$pkg" == "gum" ]]; then
                # Gum is not always in default Debian repos; we handle its specific installation
                echo "[*] Fetching Charmbracelet signing keys for 'gum'..."
                sudo mkdir -p /etc/apt/keyrings
                sudo curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
                echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
                sudo apt-get update -y && sudo apt-get install gum -y
            else
                sudo apt-get install "$pkg" -y
            fi
        fi
    done
else
    echo "[!] Network authorization denied. I expect 'gum' and 'logger' to be manually provisioned."
    # Fail-closed check
    for cmd in gum logger sed mktemp; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "[!] FATAL: $cmd is missing and network access was denied. Terminating."
            exit 1
        fi
    done
fi

gum style --border double --margin "1" --padding "1" --border-foreground 212 "Phase 1 Complete. Dependencies locked. Host triaged."

# =========================================================================
# PHASE 2: THE INTERROGATION (VERBOSE STIG CONFIGURATION)
# =========================================================================

gum style --border normal --margin "1" --padding "1" --border-foreground 196 "PHASE 2: ENVIRONMENTAL INTERROGATION"

# --- 1. DATA HEMORRHAGE (UMASK) ---
echo ""
gum style --foreground 214 "[*] TARGET: File Creation Mask (umask)"
echo "    THEORY: By default, Linux bleeds data. When you create a file, group members or"
echo "    other users on the system can often read it. This is how lateral movement succeeds."
echo "    STIG demands a minimum of 027. Paranoia demands 077."

UMASK_CHOICE=$(gum choose "077 (Paranoid - Absolute Isolation)" "027 (Compliant - Group Read)" "022 (Reckless - World Read)")
USER_UMASK=$(echo "$UMASK_CHOICE" | awk '{print $1}')

if [[ "$USER_UMASK" == "022" ]]; then
    gum style --foreground 196 "[!] WARNING: You chose 022. You are practically uploading your data to Pastebin. Proceeding under protest."
fi

# --- 2. SESSION NECROMANCY (TMOUT) ---
echo ""
gum style --foreground 214 "[*] TARGET: Session Timeout (TMOUT)"
echo "    THEORY: An unattended shell is a loaded gun left on a park bench."
echo "    If an operator walks away, the session must die. STIG maximum is 900 seconds."

TMOUT_CHOICE=$(gum choose "900 (STIG Max - 15 mins)" "600 (Strict - 10 mins)" "300 (Paranoid - 5 mins)" "Custom")
if [[ "$TMOUT_CHOICE" == "Custom" ]]; then
    USER_TMOUT=$(gum input --placeholder "Enter exact seconds (e.g., 120)" --prompt "Seconds > ")
    if ! [[ "$USER_TMOUT" =~ ^[0-9]+$ ]]; then
        gum style --foreground 196 "[!] FATAL: Non-integer timeout detected. I will not break the shell. Defaulting to 900."
        USER_TMOUT=900
    fi
else
    USER_TMOUT=$(echo "$TMOUT_CHOICE" | awk '{print $1}')
fi

# --- 3. MEMORY ARTIFACTS (CORE DUMPS) ---
echo ""
gum style --foreground 214 "[*] TARGET: Core Dumps (ulimit -c)"
echo "    THEORY: When a process crashes, the kernel dumps its memory to disk for debugging."
echo "    This file is a graveyard of forensic artifacts: cleartext passwords, decryption keys,"
echo "    and session tokens. "
echo "    DECISION: I am not giving you a choice. Core dumps will be annihilated (0)."
USER_COREDUMP=0
sleep 2

# --- 4. FORENSIC AUDIT TRAIL (HISTORY) ---
echo ""
gum style --foreground 214 "[*] TARGET: Shell History Management"
echo "    THEORY: We need an immutable forensic trail, but we don't need duplicate commands"
echo "    cluttering the buffer and causing memory exhaustion. How aggressive is our logging?"

HIST_CHOICE=$(gum choose "ignoreboth (Ignore dupes & space-prefixed commands)" "erasedups (Wipe ALL previous duplicate lines)" "paranoid (Log absolutely everything, 100k lines)")
if [[ "$HIST_CHOICE" == *"ignoreboth"* ]]; then
    USER_HISTCONTROL="ignoreboth"
    USER_HISTSIZE=10000
elif [[ "$HIST_CHOICE" == *"erasedups"* ]]; then
    USER_HISTCONTROL="erasedups"
    USER_HISTSIZE=10000
else
    USER_HISTCONTROL=""
    USER_HISTSIZE=100000
fi

# --- 5. THE VANITY FAIR (TACTICAL UI) ---
echo ""
gum style --border normal --margin "1" --padding "1" --border-foreground 213 "THE VANITY FAIR: TACTICAL AWARENESS UI"
echo "    THEORY: You demanded customized aesthetics for your visual sensors."
echo "    Select the structural delimiters for your prompt segments."

BRACKET_CHOICE=$(gum choose "Ghost: 〖 〗" "Classic: [ ]" "Math: ⟨ ⟩" "Minimal: | |")
case "$BRACKET_CHOICE" in
    *Ghost*)   BRACKET_L="〖"; BRACKET_R="〗" ;;
    *Classic*) BRACKET_L="[";  BRACKET_R="]"  ;;
    *Math*)    BRACKET_L="⟨";  BRACKET_R="⟩"  ;;
    *Minimal*) BRACKET_L="|";  BRACKET_R="|"  ;;
esac

echo ""
echo "    Select your Privilege Escalation / Root Indicator."
ROOT_IND_CHOICE=$(gum choose "Arrow: ⭆" "Skull: ☠" "Hash: #" "Radioactive: ☢")
ROOT_IND=$(echo "$ROOT_IND_CHOICE" | awk '{print $2}')

# Summary Array for confirmation
gum style --foreground 70 "Interrogation Complete. Staging payload variables..."
echo "- Umask: $USER_UMASK"
echo "- Timeout: $USER_TMOUT"
echo "- Core Dumps: Locked (0)"
echo "- History Control: ${USER_HISTCONTROL:-NONE}"
echo "- Aesthetics: $BRACKET_L Segment $BRACKET_R | Indicator: $ROOT_IND"
echo ""

if ! gum confirm "Does this configuration meet your threat model?"; then
    gum style --foreground 196 "[*] Configuration rejected by operator. Initiating abort sequence."
    exit 0
fi

# =========================================================================
# PHASE 3: THE ASSEMBLY (ATOMIC OVERWRITE)
# =========================================================================

gum style --border normal --margin "1" --padding "1" --border-foreground 70 "PHASE 3: FORGING THE EXECUTION VECTOR"

TARGET_USER_DIR="${HOME}"
TARGET_RC="${TARGET_USER_DIR}/.bashrc"
BACKUP_DIR="${TARGET_USER_DIR}/.bashrc_backups"

# --- 1. THE QUARANTINE BACKUP ---
mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

if [[ -f "${TARGET_RC}" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="${BACKUP_DIR}/bashrc_backup_${TIMESTAMP}"
    cp -a "${TARGET_RC}" "${BACKUP_FILE}"
    chmod 600 "${BACKUP_FILE}"
    gum style --foreground 214 "[*] Legacy configuration archived at: ${BACKUP_FILE}"
fi

# --- 2. CLEAN ROOM STAGING ---
TMP_RC=$(mktemp /tmp/bashrc_staged.XXXXXX)
chmod 600 "${TMP_RC}"

# Trap ensures temporary file destruction upon sudden termination
trap 'rm -f "${TMP_RC}"; echo "[!] Script aborted. Cleared temporary staging file."' EXIT

echo "[*] Compiling the payload..."

# --- 3. PAYLOAD INJECTION ---
# Notice: This HEREDOC is UNQUOTED (EOF_PROMPT). 
# We MUST escape runtime variables (like \$?) with backslashes so they are written literally, 
# while allowing our deployment variables (like $USER_UMASK, $BRACKET_L) to expand immediately.

cat << EOF_PROMPT > "${TMP_RC}"
# =========================================================================
# HARDENED .bashrc - AUTOGENERATED VIA PHANTOMBYTE PROTOCOL
# OS FINGERPRINT: ${HOST_OS} | DEPLOYED: $(date)
# =========================================================================

# Interactive shell check
case \$- in
    *i*) ;;
      *) return;;
esac

# --- DISA STIG / HARDENING SETTINGS ---
umask ${USER_UMASK}
ulimit -c 0

TMOUT=${USER_TMOUT}
readonly TMOUT
export TMOUT

HISTSIZE=${USER_HISTSIZE}
HISTFILESIZE=${USER_HISTSIZE}
HISTCONTROL=${USER_HISTCONTROL}
HISTTIMEFORMAT="%F %T "
shopt -s histappend

# --- ALIAS PROTECTIONS ---
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# --- DEFAULT PATH SANITIZATION ---
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- VISUAL AWARENESS & AUDIT HOOK ---
__phantom_prompt_and_audit() {
    local EXIT_CODE=\$?
    
    # 1. THE SYSLOG PANOPTICON
    local LAST_CMD
    LAST_CMD=\$(history 1 | sed -e "s/^[ ]*[0-9]*[ ]*//g")
    
    if [[ -n "\${LAST_CMD}" && "\${LAST_CMD}" != "\${__PHANTOM_LAST_LOGGED_CMD:-}" ]]; then
        logger -p user.notice -t "phantom-audit[\$\$]" "USER:\${USER} EUID:\${EUID} PWD:\${PWD} CMD:\${LAST_CMD} EXIT:\${EXIT_CODE}"
        export __PHANTOM_LAST_LOGGED_CMD="\${LAST_CMD}"
    fi

    # 2. THE TACTICAL PROMPT
    local C_BLUE='\[\e[38;5;39m\]'
    local C_PINK='\[\e[38;5;213m\]'
    local C_GREY='\[\e[38;2;128;128;128m\]'
    local C_WHITE='\[\e[97m\]' 
    local C_RESET='\[\e[0m\]'
    
    local C_B
    local SYMB
    local C_PRIV
    
    # Exit Code State Engine
    if [[ \${EXIT_CODE} -eq 0 ]]; then
        C_B='\[\e[38;5;46m\]' # Green (Clean)
        SYMB="✓"
    elif [[ \${EXIT_CODE} -eq 130 ]]; then
        C_B='\[\e[38;5;226m\]' # Yellow (SIGINT)
        SYMB="✗ INT"
    else
        C_B='\[\e[38;5;196m\]' # Red (Fatal)
        SYMB="✗ \${EXIT_CODE}"
    fi
    
    # Privilege Escalation Sensor
    if [[ "\${EUID}" -eq 0 ]]; then
        C_PRIV='\[\e[38;5;208m\]' # Toxic Amber (Root)
    else
        C_PRIV='\[\e[38;5;136m\]' # Tarnished Bronze (Standard User)
    fi

    # Assembly (Injecting operator-chosen aesthetics statically, runtime variables dynamically)
    PS1="\${C_BLUE}╔\${C_B}${BRACKET_L}\${C_RESET}\${C_B}\${SYMB}\${C_B}${BRACKET_R}\${C_BLUE}═\${C_B}${BRACKET_L}\${C_PINK}\u@\h\${C_B}${BRACKET_R}\${C_BLUE}═\${C_B}${BRACKET_L}\${C_PINK}\D{%m/%d/%y} \D{%H:%M}\${C_B}${BRACKET_R}\${C_BLUE}═\${C_B}${BRACKET_L}\${C_GREY}\D{%s}\${C_B}${BRACKET_R}\${C_RESET}\n\${C_BLUE}╚══\${C_PRIV}${ROOT_IND} \${C_RESET}\\\$ \${C_WHITE}"
}

if [[ -z "\${PROMPT_COMMAND:-}" ]]; then
    PROMPT_COMMAND="__phantom_prompt_and_audit"
else
    PROMPT_COMMAND="__phantom_prompt_and_audit; \${PROMPT_COMMAND}"
fi

# --- ALIAS QUARANTINE (USER OVERRIDES) ---
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi
EOF_PROMPT

# --- 4. THE ATOMIC SWAP ---
echo "[*] Committing payload to disk..."
mv "${TMP_RC}" "${TARGET_RC}"

# Disarm the trap; the execution succeeded
trap - EXIT

# Lock permissions down permanently
chmod 640 "${TARGET_RC}"
chown "${USER}":"$(id -gn "${USER}")" "${TARGET_RC}"

gum style --foreground 46 --border double --padding "1" "[+] DEPLOYMENT COMPLETE. Source ~/.bashrc to enforce the new reality."