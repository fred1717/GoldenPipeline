"""Validate that the audit logging configuration
applied by harden_audit.sh is active on the baked image."""


MONITORED_FILES = [
    "/etc/passwd",
    "/etc/shadow",
    "/etc/group",
    "/etc/gshadow",
]


class TestAuditdService:
    """Verify that the audit daemon is installed, enabled, and active."""

    def test_auditd_installed(self, run_command):
        output = run_command("rpm -q audit")
        assert "audit" in output
        assert "is not installed" not in output

    def test_auditd_enabled(self, run_command):
        output = run_command("systemctl is-enabled auditd")
        assert output == "enabled"

    def test_auditd_active(self, run_command):
        output = run_command("systemctl is-active auditd")
        assert output == "active"


class TestIdentityFileRules:
    """Verify that audit rules monitor changes to identity files."""

    def test_identity_files_monitored(self, run_command):
        """Verify that each identity file has a corresponding audit rule."""
        output = run_command("auditctl -l")
        for path in MONITORED_FILES:
            assert path in output, (
                f"No audit rule found for {path}"
            )


class TestAuditConfigRules:
    """Verify that audit rules monitor changes to the audit
    configuration itself."""

    def test_audit_config_monitored(self, run_command):
        output = run_command("auditctl -l")
        assert "/etc/audit" in output


class TestLoginLogoutRules:
    """Verify that audit rules monitor login and logout events."""

    def test_login_events_monitored(self, run_command):
        output = run_command("auditctl -l")
        login_paths = ["/var/log/lastlog", "/var/run/faillock"]
        monitored = any(path in output for path in login_paths)
        assert monitored, "No audit rule found for login/logout events"


class TestAccessControlRules:
    """Verify that audit rules monitor discretionary access
    control changes (file permission modifications)."""

    def test_permission_changes_monitored(self, run_command):
        output = run_command("auditctl -l")
        syscalls = ["chmod", "fchmod", "chown", "fchown"]
        monitored = any(syscall in output for syscall in syscalls)
        assert monitored, (
            "No audit rule found for discretionary access control changes"
        )


class TestPrivilegedCommandRules:
    """Verify that audit rules monitor the use of privileged commands."""

    def test_sudo_monitored(self, run_command):
        output = run_command("auditctl -l")
        assert "privileged" in output, "No audit rule found for privileged command usage"
