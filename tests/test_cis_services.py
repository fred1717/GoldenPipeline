"""Validate that the service hardening configuration
applied by harden_services.sh is active on the baked image."""


DISABLED_SERVICES = [
    "rpcbind",
    "avahi-daemon",
    "cups",
    "nfs-server",
    "vsftpd",
    "httpd",
    "dovecot",
    "smb",
    "squid",
    "snmpd",
]


class TestDisabledServices:
    """Verify that unused network services are disabled and masked."""

    def test_services_masked(self, run_command):
        """Verify that each service in the list is masked,
        preventing it from being started even manually."""
        for service in DISABLED_SERVICES:
            output = run_command(
                f"systemctl is-enabled {service} 2>/dev/null || echo 'not-installed'"
            )
            assert output in ("masked", "not-installed"), (
                f"Service {service} is not masked: {output}"
            )

    def test_services_not_active(self, run_command):
        """Verify that none of the disabled services are currently running."""
        for service in DISABLED_SERVICES:
            output = run_command(
                f"systemctl is-active {service} 2>/dev/null || echo 'inactive'"
            )
            assert output in ("inactive", "unknown"), (
                f"Service {service} is still active: {output}"
            )


class TestTimeSynchronisation:
    """Verify that time synchronisation is active via chronyd."""

    def test_chronyd_enabled(self, run_command):
        output = run_command("systemctl is-enabled chronyd")
        assert output == "enabled"

    def test_chronyd_active(self, run_command):
        output = run_command("systemctl is-active chronyd")
        assert output == "active"
