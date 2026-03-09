"""Shared fixtures for CIS hardening validation tests."""

import json
import subprocess
import time

import boto3
import pytest

TERRAFORM_DIR = "terraform"
SSM_DOCUMENT = "AWS-RunShellScript"
SSM_TIMEOUT = 60
SSM_POLL_INTERVAL = 2


def _get_instance_id():
    """Extract the instance ID from Terraform output."""
    result = subprocess.run(
        ["terraform", "output", "-json", "instance_id"],
        cwd=TERRAFORM_DIR,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


@pytest.fixture(scope="session")
def instance_id():
    """Provide the test instance ID from Terraform output."""
    return _get_instance_id()


@pytest.fixture(scope="session")
def ssm_client():
    """Provide a boto3 SSM client."""
    return boto3.client("ssm")


@pytest.fixture(scope="session")
def run_command(ssm_client, instance_id):
    """Provide a function that executes a shell command on the test
    instance via SSM and returns the standard output as a string."""

    def _run(command):
        response = ssm_client.send_command(
            InstanceIds=[instance_id],
            DocumentName=SSM_DOCUMENT,
            Parameters={"commands": [command]},
        )

        command_id = response["Command"]["CommandId"]

        elapsed = 0
        while elapsed < SSM_TIMEOUT:
            time.sleep(SSM_POLL_INTERVAL)
            elapsed += SSM_POLL_INTERVAL

            invocation = ssm_client.get_command_invocation(
                CommandId=command_id,
                InstanceId=instance_id,
            )

            status = invocation["Status"]

            if status == "Success":
                return invocation["StandardOutputContent"].strip()

            if status in ("Failed", "TimedOut", "Cancelled"):
                error_output = invocation["StandardErrorContent"].strip()
                raise RuntimeError(
                    f"SSM command failed with status '{status}': {error_output}"
                )

        raise TimeoutError(
            f"SSM command did not complete within {SSM_TIMEOUT} seconds"
        )

    return _run
