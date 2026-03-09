#!/bin/bash
# harden_services.sh
# Disables unused network services and ensures time
# synchronisation is active per CIS Benchmarks
# for Amazon Linux 2023.

set -euo pipefail

# -------------------------------------------------
# Variables
# -------------------------------------------------

SERVICES_TO_DISABLE=(
    "rpcbind"
    "avahi-daemon"
    "cups"
    "nfs-server"
    "vsftpd"
    "httpd"
    "dovecot"
    "smb"
    "squid"
    "snmpd"
)

TIME_SYNC_SERVICE="chronyd"

# -------------------------------------------------
# Disable and mask unused services
# -------------------------------------------------

for SERVICE in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl is-enabled "${SERVICE}" 2>/dev/null | grep -q "enabled"; then
        systemctl stop "${SERVICE}"
        systemctl disable "${SERVICE}"
    fi
    systemctl mask "${SERVICE}"
done

# -------------------------------------------------
# Ensure time synchronisation is active
# -------------------------------------------------

systemctl enable "${TIME_SYNC_SERVICE}"
systemctl start "${TIME_SYNC_SERVICE}"
