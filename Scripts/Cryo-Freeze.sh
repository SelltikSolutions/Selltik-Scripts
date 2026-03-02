#!/usr/bin/env bash

# --- PHANTOMBYTE CRYOGENIC SNAPSHOT & UPDATE ENGINE ---
# ROLE: Bare-Metal State Preservation & Maintenance Ritual
# --------------------------------------------------------
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "[!] Run as root. The cryo-chamber requires absolute authority."
   exit 1
fi

BACKUP_DIR="/var/backups/phantom_cryo"
TIMESTAMP=$(date +'%Y%m%d_%H%M%S')
ARCHIVE_NAME="phantom_root_${TIMESTAMP}.tar.gz"
DESTINATION="${BACKUP_DIR}/${ARCHIVE_NAME}"

# --- PHASE 1: CRYOGENIC FREEZE ---
echo "================================================================"
echo " PHASE 1: CRYOGENIC FREEZE"
echo "================================================================"
# Ensure backup directory exists and is secured
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

echo "[*] INITIATING CRYOGENIC FREEZE OF ROOT FILESYSTEM..."
echo "[!] Destination: ${DESTINATION}"

# We exclude volatile, virtual, and external mounts.
# If /home is a separate partition and you want to back it up, remove it from the exclude list.
tar --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/var/backups/phantom_cryo/*"} \
    -czpvf "$DESTINATION" /

echo -e "\n[+] CRYOGENIC FREEZE COMPLETE."
echo "[+] Archive Size: $(du -h "$DESTINATION" | awk '{print $1}')"

# --- PHASE 2: MAINTENANCE RITUAL ---
echo -e "\n================================================================"
echo " PHASE 2: MAINTENANCE & MUTATION RITUAL"
echo "================================================================"
echo "[!] The system state is saved. You may now perform surgery."
read -p "[?] Proceed with the perilous system upgrade? [y/N]: " PROCEED

if [[ ! "$PROCEED" =~ ^[Yy]$ ]]; then
    echo "[*] Upgrade aborted. Cryogenic snapshot remains at $DESTINATION."
    exit 0
fi

echo -e "\n[*] 1. Sedating the execution guard (fapolicyd)..."
systemctl stop fapolicyd

echo "[*] 2. Injecting upstream mutations (apt full-upgrade)..."
# Temporarily disable exit on error for apt in case of minor repo warnings
set +e
apt-get update && apt-get full-upgrade -y
set -e

echo "[*] 3. Incinerating obsolete corpses (autoremove/clean)..."
apt-get autoremove -y && apt-get clean

echo "[*] 4. Rebuilding the trust database..."
fapolicyd-cli --update

echo "[*] 5. Waking the execution guard..."
systemctl start fapolicyd

echo "[*] 6. Initiating Tripwire cryptoseal... (PREPARE YOUR SITE KEY)"
# Tripwire exits with a non-zero code if it finds violations (which an update will cause).
# We catch it so the script completes gracefully.
set +e
tripwire --check --interactive
set -e

echo -e "\n================================================================"
echo " RITUAL COMPLETE. THE FORTRESS IS SEALED."
echo "================================================================"
echo "[!] If the system breaks on reboot, use a Live USB:"
echo "    1. Mount broken root to /mnt"
echo "    2. rm -rf /mnt/*"
echo "    3. tar -xzvpf ${DESTINATION} -C /mnt --numeric-owner"