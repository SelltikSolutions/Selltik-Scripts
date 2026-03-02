#!/usr/bin/env bash

# --- PHANTOMBYTE CRYOGENIC SNAPSHOT ENGINE ---
# ROLE: Bare-Metal State Preservation
# ---------------------------------------------
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "[!] Run as root. The cryo-chamber requires absolute authority."
   exit 1
fi

BACKUP_DIR="/var/backups/phantom_cryo"
TIMESTAMP=$(date +'%Y%m%d_%H%M%S')
ARCHIVE_NAME="phantom_root_${TIMESTAMP}.tar.gz"
DESTINATION="${BACKUP_DIR}/${ARCHIVE_NAME}"

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
echo "[!] To resurrect from a Live USB:"
echo "    1. Mount broken root to /mnt"
echo "    2. rm -rf /mnt/*"
echo "    3. tar -xzvpf ${ARCHIVE_NAME} -C /mnt --numeric-owner"
echo "    4. Restore GRUB if necessary."