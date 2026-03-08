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

header() {
    echo -e "\n\033[0;33m=== $1 ===\033[0m"
}

log() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# --- ANTI-FRAGILE PACKAGE MANAGER ---
install_pkg() {
    local PKGS="$*"
    log "Targeting packages: $PKGS"
    
    # Temporarily drop strict mode to handle 404 mirror errors gracefully
    set +e 
    apt-get update --fix-missing &>/dev/null
    
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS; then
        log "[!] Standard install failed. Engaging aggressive --fix-missing fallback..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing $PKGS; then
            echo -e "\033[0;31m[!] CRITICAL DEADLOCK: Upstream mirrors are broken beyond automated repair.\033[0m"
            echo -e "\033[0;31m[!] Failed to install: $PKGS\033[0m"
            echo "[!] Fix /etc/apt/sources.list.d/parrot.list and re-run."
            exit 1
        fi
    fi
    set -e # Re-engage strict mode
    log "[+] Packages acquired and installed."
}

# --- 1. L2/L3 IDENTITY SCRAMBLING ---
scramble_identity() {
    header "L2/L3 IDENTITY ANONYMIZATION"
    install_pkg "macchanger haveged rng-tools5"
    
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
    log "L3 Randomizer written to disk."
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
    log "Kernel parameters sealed."
}

# --- 3. NETWORK STEALTH ---
network_stealth() {
    header "NETWORK PERIMETER"
    install_pkg "ufw"

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

# --- 4. THE OUBLIETTE (CAGING) ---
access_control() {
    header "APPLICATION CAGING & GUARD"
    install_pkg "firejail fapolicyd tripwire"
    
    firecfg || true
    systemctl enable --now fapolicyd || true
}

# --- 5. FORENSIC AMNESIA & TMPFS ---
amnesiac_protocols() {
    header "FORENSIC ERASURE & VOLATILE STORAGE"
    install_pkg "secure-delete"
    
    if ! grep -q "tmpfs /tmp" /etc/fstab; then
        echo "tmpfs /tmp tmpfs rw,nosuid,nodev,noexec,relatime,size=1G 0 0" >> /etc/fstab
    fi
    rm -rf /var/tmp && ln -s /tmp /var/tmp

    if ! grep -q "noatime" /etc/fstab; then
        sed -i 's/errors=remount-ro/errors=remount-ro,noatime,nodiratime/' /etc/fstab
    fi
    mount -a -o remount || true

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

# --- 6. PHYSICAL I/O & SEALING ---
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
fapolicyd-cli --update
apt-get autoremove -y && apt-get clean
echo "[+] Done. System integrity database updated."
EOF
    chmod +x "$SEAL_SCRIPT"
}

# --- EXECUTION ---
main() {
    clear
    echo -e "\033[0;31m--- PHANTOMBYTE SOVEREIGN ENGINE: ANTI-FRAGILE DEPLOYMENT ---\033[0m"
    
    if [[ $EUID -ne 0 ]]; then
       echo -e "\033[0;31mError: Run with sudo.\033[0m"
       exit 1
    fi

    scramble_identity
    harden_hardware
    network_stealth
    access_control
    amnesiac_protocols
    physical_security

    header "DEPLOYMENT SUCCESSFUL"
    log "System sealed. The copy-paste warrior survives another day."
    echo -e "\033[0;32m[!] Reboot mandatory to apply GRUB/RAM-Disk mutations.\033[0m"
}

main