"""Validate that the SSH hardening configuration
applied by harden_ssh.sh is active on the baked image."""


SSHD_CONFIG = "/etc/ssh/sshd_config"


def test_root_login_disabled(run_command):
    """Verify that SSH root login is disabled."""
    output = run_command(f"grep -E '^PermitRootLogin' {SSHD_CONFIG}")
    assert "no" in output.lower()


def test_password_authentication_disabled(run_command):
    """Verify that password authentication is disabled."""
    output = run_command(f"grep -E '^PasswordAuthentication' {SSHD_CONFIG}")
    assert "no" in output.lower()


def test_empty_passwords_disabled(run_command):
    """Verify that empty passwords are not permitted."""
    output = run_command(f"grep -E '^PermitEmptyPasswords' {SSHD_CONFIG}")
    assert "no" in output.lower()


def test_x11_forwarding_disabled(run_command):
    """Verify that X11 forwarding is disabled."""
    output = run_command(f"grep -E '^X11Forwarding' {SSHD_CONFIG}")
    assert "no" in output.lower()


def test_max_auth_tries_restricted(run_command):
    """Verify that the maximum authentication attempts are restricted."""
    output = run_command(f"grep -E '^MaxAuthTries' {SSHD_CONFIG}")
    value = int(output.split()[-1])
    assert value <= 4


def test_permitted_ciphers(run_command):
    """Verify that only approved ciphers are configured."""
    output = run_command(f"grep -E '^Ciphers' {SSHD_CONFIG}")
    assert "Ciphers" in output
    for weak_cipher in ["3des-cbc", "aes128-cbc", "aes192-cbc", "aes256-cbc"]:
        assert weak_cipher not in output


def test_permitted_macs(run_command):
    """Verify that only approved MACs are configured."""
    output = run_command(f"grep -E '^MACs' {SSHD_CONFIG}")
    assert "MACs" in output
    for weak_mac in ["hmac-md5", "hmac-sha1", "umac-64"]:
        assert weak_mac not in output


def test_permitted_kex_algorithms(run_command):
    """Verify that only approved key exchange algorithms are configured."""
    output = run_command(f"grep -E '^KexAlgorithms' {SSHD_CONFIG}")
    assert "KexAlgorithms" in output
    for weak_kex in ["diffie-hellman-group1-sha1", "diffie-hellman-group14-sha1"]:
        assert weak_kex not in output


def test_sshd_config_ownership(run_command):
    """Verify that the SSH daemon configuration file is owned by root."""
    output = run_command(f"stat -c '%U:%G' {SSHD_CONFIG}")
    assert output == "root:root"


def test_sshd_config_permissions(run_command):
    """Verify that the SSH daemon configuration file has restrictive permissions."""
    output = run_command(f"stat -c '%a' {SSHD_CONFIG}")
    assert output == "600"
