#!/bin/bash
# harden_audit.sh
# Enables and configures audit logging per CIS Benchmarks
# for Amazon Linux 2023.

set -euo pipefail

# -------------------------------------------------
# Variables
# -------------------------------------------------

AUDITD_PACKAGE="audit"
AUDITD_SERVICE="auditd"
AUDIT_RULES_FILE="/etc/audit/rules.d/cis.rules"

PASSWD_FILE="/etc/passwd"
SHADOW_FILE="/etc/shadow"
GROUP_FILE="/etc/group"
GSHADOW_FILE="/etc/gshadow"
AUDIT_CONF="/etc/audit/auditd.conf"

MAX_LOG_FILE="8"
MAX_LOG_FILE_ACTION="keep_logs"
SPACE_LEFT_ACTION="email"
ACTION_MAIL_ACCT="root"
ADMIN_SPACE_LEFT_ACTION="halt"

# -------------------------------------------------
# Install and enable auditd
# -------------------------------------------------

dnf install -y "${AUDITD_PACKAGE}"
systemctl enable "${AUDITD_SERVICE}"

# -------------------------------------------------
# Configure audit log retention
# -------------------------------------------------

sed -i "s/^max_log_file .*/max_log_file = ${MAX_LOG_FILE}/" "${AUDIT_CONF}"
sed -i "s/^max_log_file_action.*/max_log_file_action = ${MAX_LOG_FILE_ACTION}/" "${AUDIT_CONF}"
sed -i "s/^space_left_action.*/space_left_action = ${SPACE_LEFT_ACTION}/" "${AUDIT_CONF}"
sed -i "s/^action_mail_acct.*/action_mail_acct = ${ACTION_MAIL_ACCT}/" "${AUDIT_CONF}"
sed -i "s/^admin_space_left_action.*/admin_space_left_action = ${ADMIN_SPACE_LEFT_ACTION}/" "${AUDIT_CONF}"

# -------------------------------------------------
# Write audit rules
# -------------------------------------------------

cat > "${AUDIT_RULES_FILE}" << EOF
# Identity file changes
-w ${PASSWD_FILE} -p wa -k identity
-w ${SHADOW_FILE} -p wa -k identity
-w ${GROUP_FILE} -p wa -k identity
-w ${GSHADOW_FILE} -p wa -k identity

# Audit configuration changes
-w /etc/audit/ -p wa -k auditconfig
-w /etc/audisp/ -p wa -k auditconfig

# Login and logout events
-w /var/log/lastlog -p wa -k logins
-w /var/log/wtmp -p wa -k logins
-w /var/log/btmp -p wa -k logins

# Discretionary access control changes
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b64 -S chown,fchown,fchownat,lchown -F auid>=1000 -F auid!=unset -k perm_mod

# Privileged commands
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k privileged
EOF
