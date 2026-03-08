#!/usr/bin/env bash

# --- PHANTOMBYTE SOVEREIGN ENGINE (V2: ANTI-FRAGILE) ---
# ROLE: Tier-3 Cyber-Warfare Systems Architect
# TARGET: ParrotOS Security Edition / Hardened Debian
# -------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# --- CONSTANTS ---
LOG_FILE="/var/log/phantom_sovereign.log"
IO_SWITCH="/usr/local/bin/io-blackout"
SEAL_SCRIPT="/usr/local/bin/seal-system"
AUDIT_SCRIPT="/usr/local/bin/phantom-audit"

header() {
    echo -e "\n\033[0;33m=== $1 ===\033[0m"
}

log() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# --- ANTI-FRAGILE PACKAGE MANAGER ---
install_pkg() {
    log "Targeting packages: $*"
    set +e 
    apt-get update --fix-missing &>/dev/null
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
        log "[!] Standard install failed. Engaging aggressive --fix-missing fallback..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing "$@"; then
            echo -e "\033[0;31m[!] CRITICAL DEADLOCK: Upstream mirrors are broken beyond automated repair.\033[0m"
            echo -e "\033[0;31m[!] Failed to install: $*\033[0m"
            exit 1
        fi
    fi
    set -e 
    log "[+] Packages acquired and installed."
}

# --- 1. L2/L3 IDENTITY SCRAMBLING ---
scramble_identity() {
    header "L2/L3 IDENTITY ANONYMIZATION"
    install_pkg macchanger haveged rng-tools5
    systemctl enable --now haveged || true

    cat << 'EOF' > /usr/local/bin/phantom-hostname-gen
#!/usr/bin/env python3
import random, string, subprocess
new_name = 'host-' + ''.join(random.choices(string.ascii_lowercase + string.digits, k=6))
with open('/etc/hostname', 'w') as f: f.write(new_name + '\n')
with open('/etc/hosts', 'r') as f: lines = f.readlines()
with open('/etc/hosts', 'w') as f:
    for line in lines:
        if '127.0.1.1' in line: f.write(f"127.0.1.1\t{new_name}\n")
        else: f.write(line)
subprocess.run(['hostname', new_name])
EOF
    chmod +x /usr/local/bin/phantom-hostname-gen

    cat << EOF > /etc/systemd/system/phantom-hostname.service
[Unit]
Description=Randomize Hostname
Before=network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/phantom-hostname-gen
[Install]
WantedBy=multi-user.target
EOF
    systemctl enable phantom-hostname.service
}

# --- 2. KERNEL & HARDWARE HARDENING ---
harden_hardware() {
    header "KERNEL & CPU HARDENING"
    PARAMS="nosmt l1tf=full,force mds=full,nosmt spec_store_bypass_disable=on spectre_v2=on page_poison=1 slub_debug=P page_alloc.shuffle=1"
    if ! grep -q "page_poison=1" /etc/default/grub; then
        sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$PARAMS /" /etc/default/grub
        update-grub
    fi

    cat << EOF > /etc/sysctl.d/99-phantom.conf
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
kernel.kexec_load_disabled=1
kernel.unprivileged_bpf_disabled=1
net.core.bpf_jit_harden=2
kernel.randomize_va_space=2
kernel.sysrq=0
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
fs.protected_fifos=2
fs.protected_regular=2
kernel.perf_event_paranoid=3
EOF
    sysctl -p /etc/sysctl.d/99-phantom.conf
}

# --- 3. NETWORK STEALTH ---
network_stealth() {
    header "NETWORK PERIMETER"
    install_pkg ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw deny 22/tcp || true
    ufw --force enable

    cat << EOF > /etc/NetworkManager/conf.d/99-phantom-privacy.conf
[device]
wifi.scan-rand-mac-address=yes
[connection]
ipv6.addr-gen-mode=stable-privacy
ipv4.dhcp-client-id=mac
ethernet.cloned-mac-address=random
wifi.cloned-mac-address=random
EOF
    systemctl reload NetworkManager || true
}

# --- 4. SSH PORT OBFUSCATION ---
configure_ssh() {
    header "SSH PORT SCRAMBLING"
    echo "[1] Manual: Specify your own port"
    echo "[2] Deception: Random with '22' prefix (e.g., 22XXX)"
    echo "[3] Ghost: True Random Ephemeral (49152-65535)"
    read -p "[?] Select SSH Port Strategy [1-3]: " SSH_CHOICE

    local FINAL_PORT=2222
    case "$SSH_CHOICE" in
        1) read -p "[?] Enter desired SSH Port: " FINAL_PORT ;;
        2) FINAL_PORT=$((22000 + RANDOM % 1000)) ;;
        3) FINAL_PORT=$((49152 + RANDOM % 16383)) ;;
        *) log "Invalid choice. Defaulting to 2222." ; FINAL_PORT=2222 ;;
    esac

    log "Configuring SSH on port $FINAL_PORT..."
    sed -i "s/^#\?Port .*/Port $FINAL_PORT/" /etc/ssh/sshd_config
    ufw limit "$FINAL_PORT"/tcp comment 'Hardened SSH'
    systemctl restart ssh || true
}

# --- 5. THE OUBLIETTE (CAGING) ---
access_control() {
    header "APPLICATION CAGING & GUARD"
    install_pkg firejail fapolicyd tripwire
    firecfg || true
    
    log "Fixing fapolicyd structural integrity..."
    mkdir -p /etc/fapolicyd/rules.d
    
    if [ -z "$(ls -A /etc/fapolicyd/rules.d/)" ]; then
        if [ -f /usr/share/fapolicyd/sample.rules ]; then
            cp /usr/share/fapolicyd/sample.rules /etc/fapolicyd/rules.d/10-default.rules
        else
            log "Generating emergency permissive ruleset..."
            echo "allow perm=any all : all" > /etc/fapolicyd/rules.d/99-fallback.rules
        fi
    fi

    if [ -f /etc/fapolicyd/fapolicyd.conf ]; then
        sed -i 's/^trust =.*/trust = file/' /etc/fapolicyd/fapolicyd.conf
    fi

    log "Compiling fapolicyd rules..."
    /usr/sbin/fagenrules --load || true
    systemctl daemon-reload
    systemctl enable --now fapolicyd || true
}

# --- 6. FORENSIC AMNESIA & TMPFS ---
amnesiac_protocols() {
    header "FORENSIC ERASURE & VOLATILE STORAGE"
    install_pkg secure-delete
    
    if ! grep -q "tmpfs /tmp" /etc/fstab; then
        echo "tmpfs /tmp tmpfs rw,nosuid,nodev,noexec,relatime,size=1G 0 0" >> /etc/fstab
    fi
    rm -rf /var/tmp && ln -s /tmp /var/tmp

    if ! grep -q "noatime" /etc/fstab; then
        sed -i 's/errors=remount-ro/errors=remount-ro,noatime,nodiratime/' /etc/fstab
    fi
    
    systemctl daemon-reload
    mount -o remount / || true
    if mountpoint -q /home; then mount -o remount /home || true; fi

    for PROFILE in "/etc/profile" "/etc/skel/.bashrc" "/root/.bashrc"; do
        if ! grep -q "HISTSIZE=0" "$PROFILE" 2>/dev/null; then
            echo -e "\nexport HISTFILE=/dev/null\nexport HISTSIZE=0\nexport HISTFILESIZE=0\nset +o history" >> "$PROFILE"
        fi
    done
    
    cat << 'EOF' > /usr/local/bin/ghost-sweep
#!/bin/bash
truncate -s 0 /var/log/wtmp /var/log/lastlog /var/log/btmp
find /home -name ".bash_history" -exec truncate -s 0 {} \; 2>/dev/null || true
rm -rf /home/*/.cache/* /root/.cache/* 2>/dev/null || true
EOF
    chmod +x /usr/local/bin/ghost-sweep

    cat << EOF > /etc/systemd/system/ghost-sweep.service
[Unit]
Description=Ghost Sweep
Before=shutdown.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ghost-sweep
[Install]
WantedBy=shutdown.target
EOF
    systemctl enable ghost-sweep.service
}

# --- 7. PHYSICAL I/O & SEALING ---
physical_security() {
    header "PHYSICAL SECURITY & SEALING"
    cat << 'EOF' > "$IO_SWITCH"
#!/bin/bash
case "$1" in
    off) modprobe -r uvcvideo; modprobe -r snd_hda_intel; echo "BLACKOUT ACTIVE";;
    on)  modprobe uvcvideo; modprobe snd_hda_intel; echo "I/O RESTORED";;
esac
EOF
    chmod +x "$IO_SWITCH"

    cat << EOF > "$SEAL_SCRIPT"
#!/bin/bash
echo "[*] Re-sealing the fortress..."
if systemctl is-active --quiet fapolicyd; then
    fagenrules --load
    fapolicyd-cli --update
else
    echo "[!] fapolicyd is not running. Update skipped."
fi
apt-get autoremove -y && apt-get clean
echo "[+] Done. System integrity database updated."
EOF
    chmod +x "$SEAL_SCRIPT"
}

# --- 8. POST-DEPLOYMENT AUDIT ---
deploy_audit() {
    cat << 'EOF' > "$AUDIT_SCRIPT"
#!/bin/bash
echo -e "\n--- PHANTOMBYTE INTEGRITY AUDIT ---"
check_val() {
  val=$(sysctl -n $1 2>/dev/null || echo "ERR")
  if [ "$val" == "$2" ]; then echo -e "[PASS] $1"; else echo -e "[FAIL] $1 (Got $val)"; fi
}
check_val kernel.sysrq 0
check_val kernel.perf_event_paranoid 3
check_val kernel.dmesg_restrict 1
if systemctl is-active --quiet fapolicyd; then echo "[PASS] fapolicyd active"; else echo "[FAIL] fapolicyd dead"; fi
if mount | grep -q "/tmp type tmpfs"; then echo "[PASS] Volatile /tmp"; else echo "[FAIL] Disk /tmp"; fi
EOF
    chmod +x "$AUDIT_SCRIPT"
}

# --- EXECUTION ---
main() {
    clear
    echo -e "\033[0;31m--- PHANTOMBYTE SOVEREIGN ENGINE: FINAL DEPLOYMENT ---\033[0m"
    if [[ $EUID -ne 0 ]]; then
       echo -e "\033[0;31mError: Run with sudo.\033[0m"
       exit 1
    fi
    scramble_identity
    harden_hardware
    network_stealth
    configure_ssh
    access_control
    amnesiac_protocols
    physical_security
    deploy_audit
    
    header "DEPLOYMENT SUCCESSFUL"
    log "System sealed. Identity ghosted."
    $AUDIT_SCRIPT
    echo -e "\033[0;32m[!] Reboot mandatory to apply GRUB/RAM-Disk mutations.\033[0m"
}
main