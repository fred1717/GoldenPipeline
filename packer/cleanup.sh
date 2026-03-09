#!/bin/bash
# cleanup.sh
# Runs last in the Packer provisioning sequence.
# Removes temporary files and artefacts before the
# AMI snapshot is taken.

set -euo pipefail

# -------------------------------------------------
# Variables
# -------------------------------------------------

TMP_DIRS=(
    "/tmp"
    "/var/tmp"
)

HISTORY_FILES=(
    "/root/.bash_history"
    "/home/ec2-user/.bash_history"
)

SSH_HOST_KEYS_DIR="/etc/ssh"
SSH_HOST_KEYS_PATTERN="ssh_host_*_key*"

# -------------------------------------------------
# Remove temporary files
# -------------------------------------------------

for DIR in "${TMP_DIRS[@]}"; do
    find "${DIR}" -mindepth 1 -delete 2>/dev/null || true
done

# -------------------------------------------------
# Clear dnf cache
# -------------------------------------------------

dnf clean all

# -------------------------------------------------
# Remove shell history
# -------------------------------------------------

for HISTORY_FILE in "${HISTORY_FILES[@]}"; do
    rm -f "${HISTORY_FILE}"
done

# -------------------------------------------------
# Remove SSH host keys
# -------------------------------------------------

find "${SSH_HOST_KEYS_DIR}" -name "${SSH_HOST_KEYS_PATTERN}" -delete
