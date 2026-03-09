"""Validate that the filesystem hardening configuration
applied by harden_filesystem.sh is active on the baked image."""


class TestFileOwnership:
    """Verify ownership of sensitive system files."""

    def test_passwd_ownership(self, run_command):
        output = run_command("stat -c '%U:%G' /etc/passwd")
        assert output == "root:root"

    def test_shadow_ownership(self, run_command):
        output = run_command("stat -c '%U:%G' /etc/shadow")
        assert output == "root:root"

    def test_group_ownership(self, run_command):
        output = run_command("stat -c '%U:%G' /etc/group")
        assert output == "root:root"

    def test_gshadow_ownership(self, run_command):
        output = run_command("stat -c '%U:%G' /etc/gshadow")
        assert output == "root:root"


class TestFilePermissions:
    """Verify permissions on sensitive system files."""

    def test_passwd_permissions(self, run_command):
        output = run_command("stat -c '%a' /etc/passwd")
        assert output == "644"

    def test_shadow_permissions(self, run_command):
        output = run_command("stat -c '%a' /etc/shadow")
        assert output == "000"

    def test_group_permissions(self, run_command):
        output = run_command("stat -c '%a' /etc/group")
        assert output == "644"

    def test_gshadow_permissions(self, run_command):
        output = run_command("stat -c '%a' /etc/gshadow")
        assert output == "000"


class TestBootloaderPermissions:
    """Verify ownership and permissions on bootloader configuration."""

    def test_grub_config_ownership(self, run_command):
        output = run_command(
            "stat -c '%U:%G' /boot/grub2/grub.cfg 2>/dev/null || echo 'absent'"
        )
        if output != "absent":
            assert output == "root:root"

    def test_grub_config_permissions(self, run_command):
        output = run_command(
            "stat -c '%a' /boot/grub2/grub.cfg 2>/dev/null || echo 'absent'"
        )
        if output != "absent":
            assert output == "600"


class TestWorldWritableFiles:
    """Verify that no world-writable files exist on the system."""

    def test_no_world_writable_files(self, run_command):
        partitions = run_command(
            "df --local -P | awk 'NR>1 {print $6}'"
        )
        for partition in partitions.splitlines():
            output = run_command(
                f"find {partition} -xdev -type f -perm -0002 2>/dev/null"
            )
            assert output == "", (
                f"World-writable files found on {partition}: {output}"
            )


class TestUnownedFiles:
    """Verify that no unowned or ungrouped files exist on the system."""

    def test_no_unowned_files(self, run_command):
        partitions = run_command(
            "df --local -P | awk 'NR>1 {print $6}'"
        )
        for partition in partitions.splitlines():
            output = run_command(
                f"find {partition} -xdev -nouser 2>/dev/null"
            )
            assert output == "", (
                f"Unowned files found on {partition}: {output}"
            )

    def test_no_ungrouped_files(self, run_command):
        partitions = run_command(
            "df --local -P | awk 'NR>1 {print $6}'"
        )
        for partition in partitions.splitlines():
            output = run_command(
                f"find {partition} -xdev -nogroup 2>/dev/null"
            )
            assert output == "", (
                f"Ungrouped files found on {partition}: {output}"
            )
