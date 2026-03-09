#!/bin/bash
# harden_ssh.sh
# Hardens the SSH daemon configuration per CIS Benchmarks.
# The AMI is validated via SSM, not SSH, but CIS compliance
# requires a secure SSH configuration regardless.

set -euo pipefail

# -------------------------------------------------
# Variables
# -------------------------------------------------

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_OWNER="root"
SSHD_CONFIG_GROUP="root"
SSHD_CONFIG_PERMS="0600"

PERMIT_ROOT_LOGIN="no"
PASSWORD_AUTHENTICATION="no"
PERMIT_EMPTY_PASSWORDS="no"
X11_FORWARDING="no"
MAX_AUTH_TRIES="4"
CLIENT_ALIVE_INTERVAL="300"
CLIENT_ALIVE_COUNT_MAX="3"
LOGIN_GRACE_TIME="60"
MAX_SESSIONS="10"

APPROVED_CIPHERS="aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
APPROVED_MACS="hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256"
APPROVED_KEX="curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256"

# -------------------------------------------------
# Apply SSH daemon settings
# -------------------------------------------------

apply_setting() {
    local key="${1}"
    local value="${2}"
    local config="${3}"

    if grep -q "^${key}" "${config}"; then
        sed -i "s/^${key}.*/${key} ${value}/" "${config}"
    elif grep -q "^#${key}" "${config}"; then
        sed -i "s/^#${key}.*/${key} ${value}/" "${config}"
    else
        echo "${key} ${value}" >> "${config}"
    fi
}

apply_setting "PermitRootLogin" "${PERMIT_ROOT_LOGIN}" "${SSHD_CONFIG}"
apply_setting "PasswordAuthentication" "${PASSWORD_AUTHENTICATION}" "${SSHD_CONFIG}"
apply_setting "PermitEmptyPasswords" "${PERMIT_EMPTY_PASSWORDS}" "${SSHD_CONFIG}"
apply_setting "X11Forwarding" "${X11_FORWARDING}" "${SSHD_CONFIG}"
apply_setting "MaxAuthTries" "${MAX_AUTH_TRIES}" "${SSHD_CONFIG}"
apply_setting "ClientAliveInterval" "${CLIENT_ALIVE_INTERVAL}" "${SSHD_CONFIG}"
apply_setting "ClientAliveCountMax" "${CLIENT_ALIVE_COUNT_MAX}" "${SSHD_CONFIG}"
apply_setting "LoginGraceTime" "${LOGIN_GRACE_TIME}" "${SSHD_CONFIG}"
apply_setting "MaxSessions" "${MAX_SESSIONS}" "${SSHD_CONFIG}"
apply_setting "Ciphers" "${APPROVED_CIPHERS}" "${SSHD_CONFIG}"
apply_setting "MACs" "${APPROVED_MACS}" "${SSHD_CONFIG}"
apply_setting "KexAlgorithms" "${APPROVED_KEX}" "${SSHD_CONFIG}"

# -------------------------------------------------
# Set ownership and permissions on sshd_config
# -------------------------------------------------

chown "${SSHD_CONFIG_OWNER}:${SSHD_CONFIG_GROUP}" "${SSHD_CONFIG}"
chmod "${SSHD_CONFIG_PERMS}" "${SSHD_CONFIG}"
