#!/usr/bin/env bash
set -euo pipefail

# Assert root execution
if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: Root privileges required for this level of system violence." >&2
    exit 1
fi

echo "[*] Initiating purge of rogue package management processes..."
# We send SIGKILL to the entire APT/DPKG bloodline. 
# We append || true so the script does not abort if the processes are already dead.
killall -9 apt apt-get dpkg debconf frontend 2>/dev/null || true

echo "[*] Eradicating orphaned lockfiles..."
# Since we assassinated the processes, these locks are now ghosts. 
# They protect nothing. We delete them.
rm -f /var/lib/dpkg/lock
rm -f /var/lib/dpkg/lock-frontend
rm -f /var/cache/apt/archives/lock

echo "[*] Purging corrupted dpkg update journals..."
# If dpkg was hung before spawning a child, it was likely stuck in an infinite 
# loop trying to read a malformed binary journal. We burn the journals.
rm -f /var/lib/dpkg/updates/*

echo "[*] Re-establishing database integrity..."
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

# Force the configuration state machine to resume.
# We pipe /dev/null to suffocate any stray interactive prompts.
dpkg --configure -a --force-confdef --force-confold < /dev/null

echo "[*] Resolving fractured dependency trees..."
# If our SIGKILL interrupted an unpack phase, we force APT to heal the wounds.
apt-get install -f -y --fix-broken

echo "[+] Operation complete. The undead are cleared."