#!/bin/bash
# harden_updates.sh
# Configures automatic security updates via dnf-automatic.
# CIS Benchmark: Ensure updates, patches, and additional
# security software are installed.

set -euo pipefail

# -------------------------------------------------
# Variables
# -------------------------------------------------

DNF_AUTOMATIC_PACKAGE="dnf-automatic"
DNF_AUTOMATIC_CONF="/etc/dnf/automatic.conf"
DNF_AUTOMATIC_TIMER="dnf-automatic.timer"
UPGRADE_TYPE="security"
APPLY_UPDATES="yes"

# -------------------------------------------------
# Install dnf-automatic
# -------------------------------------------------

dnf install -y "${DNF_AUTOMATIC_PACKAGE}"

# -------------------------------------------------
# Configure: apply security updates only
# -------------------------------------------------

sed -i "s/^upgrade_type.*/upgrade_type = ${UPGRADE_TYPE}/" "${DNF_AUTOMATIC_CONF}"
sed -i "s/^apply_updates.*/apply_updates = ${APPLY_UPDATES}/" "${DNF_AUTOMATIC_CONF}"

# -------------------------------------------------
# Enable and start the timer
# -------------------------------------------------

systemctl enable "${DNF_AUTOMATIC_TIMER}"
systemctl start "${DNF_AUTOMATIC_TIMER}"
