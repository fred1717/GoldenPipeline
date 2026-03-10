#!/bin/bash
# harden_filesystem.sh
# Hardens file permissions on sensitive system files
# per CIS Benchmarks for Amazon Linux 2023.

set -euo pipefail

# -------------------------------------------------
# Variables
# -------------------------------------------------

PASSWD_FILE="/etc/passwd"
SHADOW_FILE="/etc/shadow"
GROUP_FILE="/etc/group"
GSHADOW_FILE="/etc/gshadow"
GRUB_CONFIG="/boot/grub2/grub.cfg"

ROOT_OWNER="root"
ROOT_GROUP="root"
SHADOW_GROUP="root"

PASSWD_PERMS="0644"
SHADOW_PERMS="0000"
GROUP_PERMS="0644"
GSHADOW_PERMS="0000"
GRUB_PERMS="0600"

# -------------------------------------------------
# Set ownership and permissions on identity files
# -------------------------------------------------

chown "${ROOT_OWNER}:${ROOT_GROUP}" "${PASSWD_FILE}"
chmod "${PASSWD_PERMS}" "${PASSWD_FILE}"

chown "${ROOT_OWNER}:${SHADOW_GROUP}" "${SHADOW_FILE}"
chmod "${SHADOW_PERMS}" "${SHADOW_FILE}"

chown "${ROOT_OWNER}:${ROOT_GROUP}" "${GROUP_FILE}"
chmod "${GROUP_PERMS}" "${GROUP_FILE}"

chown "${ROOT_OWNER}:${SHADOW_GROUP}" "${GSHADOW_FILE}"
chmod "${GSHADOW_PERMS}" "${GSHADOW_FILE}"

# -------------------------------------------------
# Set ownership and permissions on bootloader
# -------------------------------------------------

if [ -f "${GRUB_CONFIG}" ]; then
    chown "${ROOT_OWNER}:${ROOT_GROUP}" "${GRUB_CONFIG}"
    chmod "${GRUB_PERMS}" "${GRUB_CONFIG}"
fi

# -------------------------------------------------
# Remove world-writable permissions
# -------------------------------------------------

PARTITIONS=$(df --local -P | awk 'NR!=1 {print $6}')

for PARTITION in ${PARTITIONS}; do
    find "${PARTITION}" -xdev -type f -perm -0002 -exec chmod o-w {} + || true
done

# -------------------------------------------------
# Find and fix unowned or ungrouped files
# -------------------------------------------------

for PARTITION in ${PARTITIONS}; do
    find "${PARTITION}" -xdev -nouser -exec chown "${ROOT_OWNER}" {} + || true
    find "${PARTITION}" -xdev -nogroup -exec chgrp "${ROOT_GROUP}" {} + || true
done
