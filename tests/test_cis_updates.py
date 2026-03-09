"""Validate that the automatic security updates configuration
applied by harden_updates.sh is active on the baked image."""


def test_dnf_automatic_installed(run_command):
    """Verify that the dnf-automatic package is installed."""
    output = run_command("rpm -q dnf-automatic")
    assert "dnf-automatic" in output
    assert "is not installed" not in output


def test_dnf_automatic_timer_enabled(run_command):
    """Verify that the dnf-automatic.timer is enabled."""
    output = run_command("systemctl is-enabled dnf-automatic.timer")
    assert output == "enabled"


def test_dnf_automatic_timer_active(run_command):
    """Verify that the dnf-automatic.timer is active."""
    output = run_command("systemctl is-active dnf-automatic.timer")
    assert output == "active"


def test_dnf_automatic_security_only(run_command):
    """Verify that dnf-automatic is configured to apply
    security updates only, not all updates."""
    output = run_command("grep -E '^upgrade_type' /etc/dnf/automatic.conf")
    assert "security" in output
