## 0. Context
The CI/CD workflow (`ci-cd.yml`) would be the starting point — it is the backbone of the project (the project is literally named GoldenPipeline).  
It defines the sequence every other component must pass through.

From there, the natural order would follow the dependency chain:
- `ci-cd.yml` — defines the pipeline sequence and quality gate
- Packer template (`.pkr.hcl`) — defines the AMI build process that the pipeline will execute
- Hardening scripts — the scripts that the Packer template invokes
- Terraform modules — the test infrastructure for validating the baked AMI
- Tests — verify the hardening scripts achieved their intended effect

This mirrors the contract-first approach used in TerraDriftGuard, where the Step Functions ASL was written before any Lambda code.
The full architecture diagram is available at ![Architecture Diagram](docs/diagrams/goldenpipeline-architecture.svg).


## 1. Pipeline sequence
The pipeline sequence documented in section 4 of the design structure rationale covers the Terraform scanning and deployment steps.  
Yet a complete pipeline for GoldenPipeline also needs to include the Packer build and the CIS validation tests.  

### 1.1 Stage 1 — Static analysis (quality gate)
- `terraform fmt -check` on the `terraform/` directory
- `tflint` on the `terraform/` directory
- `checkov` on the `terraform/` directory
- `packer fmt -check` on the `packer/` directory
- `packer validate` on the `packer/` directory


### 1.2 Stage 2 — Build
`packer build` to bake the AMI.
The AMI ID is extracted from a Packer manifest file, which requires the Packer template (`.pkr.hcl`) to include a `manifest` post-processor.


### 1.3 Stage 3 — Deploy test infrastructure
`terraform plan` (consuming the AMI ID from Stage 2)
`terraform apply` (launches the test EC2 instance from the baked AMI)


### 1.4 Stage 4 — Validate
`pytest` runs CIS (Center for Internet Security) hardening checks against the running test instance via `SSM`.


### 1.5 Stage 5 — Teardown
- `terraform destroy` (cleanup after validation)
- Deregister the baked AMI
- Delete the associated EBS snapshot

Without AMI cleanup, baked images accumulate silently in the account.



## 2. Base operating system
The golden AMI requires a base operating system.  
Common choices include:
- Amazon Linux 2023
- Ubuntu

**Amazon Linux 2023**  
It is the best fit for this project:
- AWS-optimised, with the `SSM` agent pre-installed (no additional installation step)
- CIS Benchmark available
- Free (no licence cost on the AMI)
- Aligned with the AWS-native posture applied across the portfolio

**Ubuntu**  
It is a valid alternative but adds no benefit here.
Moreover, it would require verifying `SSM` agent availability on the chosen AMI.



## 3. Packer template
The Packer template (`.pkr.hcl`) defines the AMI build:
- Base AMI: latest Amazon Linux 2023 x86_64, selected via `source_ami_filter`
- Provisioners: the 6 hardening scripts, executed in order via `sudo`
- Execution order: `harden_updates.sh` first (package updates before any other hardening), `cleanup.sh` last (removes temporary files before snapshot)
- Post-processor: `manifest` output to `manifest.json`, consumed by `ci-cd.yml` in Stage 2

No values are hardcoded. The following are all defined as variables:
- region
- instance type
- AMI name prefix
- manifest path

Both the resulting AMI and the temporary build instance are tagged with `Project = "GoldenPipeline"` via the `tags` and `run_tags` blocks respectively.  
The EBS snapshot from the AMI bake is tagged via the `snapshot_tags` block.
The root EBS volume on the temporary build instance is tagged via the `run_volume_tags` block.
This ensures all Packer-created resources are visible in AWS Cost Explorer.  
On the Terraform side, the same tag is applied to every resource via the `default_tags` block in the provider configuration.



## 4. Hardening scripts
To harden a system means to reduce its attack surface by tightening its configuration:
    - disabling features that are not needed
    - restricting permissions
    - enforcing stricter settings. 
The goal is to make the system more resistant to compromise.

The hardening scripts are executed by the Packer template in the order listed below.
Each script targets a specific CIS Benchmark category for Amazon Linux 2023.
The execution order is deliberate:
- `harden_updates.sh` (runs first: package updates before any other hardening)
- `harden_ssh.sh`
- `harden_filesystem.sh`
- `harden_services.sh`
- `harden_audit.sh`
- `cleanup.sh` (runs last: removes temporary files before snapshot)


### 4.1 `harden_updates.sh`
`dnf-automatic` is the recommended mechanism for automatic security updates on Amazon Linux 2023.
The script:
- installs `dnf-automatic`
- configures it to apply security updates only (not all updates)
- enables and starts the `dnf-automatic.timer` systemd timer

Applying updates automatically is appropriate here because the golden AMI is a controlled baseline.
A new AMI is baked and tested through the pipeline each time, so that there is no risk of an untested update reaching production unvalidated.


### 4.2 `harden_ssh.sh`
The `SSH` daemon is hardened even though validation uses `SSM`, not `SSH`.
The AMI may eventually be used in environments where `SSH` is enabled, and CIS compliance requires the configuration to be secure regardless.

The script applies the following CIS Benchmark recommendations:
- disable root login
- disable password authentication (key pairs only)
- disable empty passwords
- disable X11 forwarding
- restrict maximum authentication attempts
- restrict permitted ciphers, MACs, and key exchange algorithms to approved sets
- set appropriate ownership and permissions on the SSH daemon configuration file

Notable decisions:
- In order to avoid duplicate entries, the `apply_setting` function handles 3 cases: 
    - the setting already exists
    - the setting is commented out
    - the setting is absent
- No `sshd restart` (`SSH` daemon restart) at the end. This is the background process that listens for and handles SSH connections. 
    It is the service that reads the configuration file (`/etc/ssh/sshd_config`) modified by the script.
    Normally, after changing SSH configuration on a running system, the daemon needs to be restarted (`systemctl restart sshd`) for the changes to take effect. 
    In this case, no restart is needed because Packer takes the snapshot after provisioning, and the configuration takes effect on first boot from the baked AMI.
- The approved ciphers, MACs, and key exchange algorithms follow the CIS Benchmark recommended sets, excluding any algorithms considered weak.



### 4.3 `harden_filesystem.sh`
CIS Benchmarks require restrictive permissions on sensitive system files to prevent unauthorised access or modification.
The script applies the following:
- set ownership and permissions on:
    - `/etc/passwd`
    - `/etc/shadow`
    - `/etc/group`
    - `/etc/gshadow`
- set ownership and permissions on the bootloader configuration
- ensure no world-writable files exist
- ensure no unowned or ungrouped files exist

The `PARTITIONS` variable is assigned once and reused in both loops.


### 4.4 `harden_services.sh`
CIS Benchmarks require that unused network services are disabled to reduce the attack surface.  
The script:
- disables and masks services that are not required on a hardened instance, including:
    - `rpcbind`
    - `avahi-daemon`
    - `cups`
    - `nfs-server`
    - `vsftpd`
    - `httpd`
    - `dovecot`
    - `smb`
    - `squid`
    - `snmpd`
- ensures time synchronisation is active via `chronyd`

The services are checked before stopping to avoid errors on services that are not installed. 
`mask` is applied regardless, as it prevents the service from being started even manually.
This is stronger than using `disable` alone.


### 4.5 `harden_audit.sh`
CIS Benchmarks require audit logging to be enabled and configured to capture security-relevant events.  
The script:
- installs and enables `auditd`
- configures audit rules to monitor:
    - changes to identity files:
        - `/etc/passwd`
        - `/etc/shadow`
        - `/etc/group`
        - `/etc/gshadow`
    - changes to the audit configuration itself
    - changes to login and logout events
    - changes to discretionary access controls (file permission modifications)
    - use of privileged commands (`sudo`)
- sets the audit log retention policy


### 4.6 `cleanup.sh`
This script runs last, immediately before Packer takes the AMI snapshot.
It removes temporary files and artefacts left behind by the provisioning process to ensure the baked image is clean.

The script:
- removes temporary files from:
    - `/tmp` 
    - `/var/tmp`
- clears the `dnf` cache
- removes shell history
- removes `SSH` host keys (regenerated on first boot of each new instance).
    Leaving the build instance's keys in the image would mean that every instance shares the same host keys.
    This would be a security risk.



## 5. Terraform modules
Following the contract-first approach, the sequence would be:
- root `main.tf` (the contract: defines module calls, wires inputs and outputs)
- root `variables.tf` (variables consumed by root `main.tf`, including the AMI ID)
- `modules/vpc/` (no dependencies on other modules)
- `modules/security_group/` (depends on VPC)
- `modules/iam/` (no module dependency, but logically follows)
- `modules/ec2/` (depends on all 3 above)
- `Root outputs.tf` (exposes values from modules)
- `terraform.tfvars.example` (example values for the variables)

Each module consists of:
- `main.tf`
- `variables.tf`
- `outputs.tf`


### 5.1 Provider configuration
The `default_tags` block in the `provider "aws"` configuration applies the `Project` tag to every resource created by Terraform.  
This ensures all resources are visible in AWS Cost Explorer without relying on individual modules to apply the tag.
The project name is defined as a variable and passed to each module for use in Name tags.


### 5.2 VPC module
The VPC contains a single private subnet.  
There is no internet gateway and no public IP assignment.  
`SSM` connectivity is provided by 3 interface VPC endpoints, as documented in section 6.

A dedicated security group restricts traffic to the VPC endpoints to HTTPS (port 443) from within the VPC CIDR only.  
This ensures that only the `SSM` agent's HTTPS traffic can reach the endpoints, and that no other protocol or destination is permitted from within the VPC.


### 5.3 Security group module
The security group for the test EC2 instance has:
- no inbound rules (`SSM` does not require any, as documented in section 6)
- a single egress rule: HTTPS (port 443) to the VPC CIDR, for communication with the `SSM` VPC endpoints


### 5.4 IAM module
The IAM module creates:
- an IAM role with an EC2 `assume-role` trust policy
- a single managed policy attachment: `AmazonSSMManagedInstanceCore`
- an instance profile

No custom inline policies are used.


### 5.5 EC2 module
The test instance is launched from the baked AMI with `associate_public_ip_address = false`.  
The only output is the `instance_id`, consumed by the CI/CD pipeline to target `SSM` commands during the validation stage.


### 5.6 `terraform.tfvars.example`
The file contains example values for the root variables.
The `ami_id` entry has been removed because the AMI ID is resolved automatically at plan time via an `aws_ami` data source.
This is documented in [docs/architecture_decisions.md, section 6.3](docs/architecture_decisions.md#63-ami-reference-from-packer-manifest-to-terraform).



## 6. Tests
The test files map 1-to-1 to the hardening scripts, verifying that each script achieved its intended effect on the running test instance:
- `test_cis_updates.py` → `harden_updates.sh`
- `test_cis_ssh.py` → `harden_ssh.sh`
- `test_cis_filesystem.py` → `harden_filesystem.sh`
- `test_cis_services.py` → `harden_services.sh`
- `test_cis_audit.py` → `harden_audit.sh`

There is no test file for `cleanup.sh`.  
Cleanup removes temporary files and artefacts before the AMI snapshot.  
Its effects are not observable from the running instance in a way that validates correctness.

### 6.1 conftest.py
The shared fixtures provide the `SSM` connection used by all test files.  
The `run_command` fixture sends a shell command to the test instance via `ssm:SendCommand`, polls for completion, and returns the standard output.
The `instance_id` is resolved from terraform output at the start of the test session.  
This is a session-scoped fixture, meaning it is resolved once and reused across all tests.


### 6.2 Dependencies
Test dependencies are listed in `requirements-dev.txt`:
- `boto3`
- `pytest`

There is no production `requirements.txt` because the project has no Python application code.  
All Python in this project is test code.
Installation is performed from the repository root (`GoldenPipeline/`):
`pip install -r requirements-dev.txt`

The virtual environment interpreter path is `venv/bin/python3`.


### 6.3 pytest.ini
The `pytest.ini` file sets the test directory to `tests/`.  
This allows `pytest` to be invoked from the repository root without specifying a path.



## 7. Using `OIDC`
The pipeline needs AWS credentials to run:
- `packer build`
- `terraform plan`
- `terraform apply`
- `terraform destroy`

**Why not static IAM access keys**
Static access keys stored as GitHub secrets are long-lived credentials that must be rotated manually.
A leaked secret grants persistent access to the AWS account.

**Why OIDC**
- OpenID Connect (`OIDC`) is an authentication protocol.
- It eliminates long-lived credentials entirely.
- GitHub assumes an IAM role directly, with short-lived tokens scoped to the repository.
- The one-time setup cost is:
    - an IAM `OIDC` identity provider in AWS
    - a trust policy on the IAM role restricting access to the specific repository

The OIDC provider and pipeline IAM role are not managed by Terraform.
This is a deliberate exception to the IaC discipline principle documented in section 3.3 of `architecture_decisions.md`, 
see [docs/architecture_decisions.md, section 3.3](docs/architecture_decisions.md#33-iac-discipline:-lesson-from-terradriftguard).

These resources are bootstrap infrastructure.
They must exist before the pipeline can authenticate to AWS.

There is a circular dependency:
- The pipeline needs the OIDC role to obtain AWS credentials.
- If Terraform created the OIDC role, it would need AWS credentials to run.
- In CI/CD, those credentials come from the OIDC role that does not exist yet.

There are 2 possible approaches:
- Managing the OIDC resources in a separate Terraform module, run locally before the first pipeline execution.
- `terraform destroy` on the main project would not touch them.
- They would be cleaned up separately after the project is complete.
- Treating the OIDC setup as a one-time account-level prerequisite: 
    - created via the CLI
    - documented in the README
    - cleaned up manually after the project

The second approach is the industry standard for bootstrap resources that enable a pipeline.
GoldenPipeline follows this convention.
The cleanup steps are documented in section 11 (Teardown), see [section 11.](#11-teardown).


### 7.1 One-time setup
The trust policy file (`trust-policy.json`) is created first in the project root directory `GoldenPipeline/`.
It defines which entity is allowed to assume the IAM role.
The Federated field contains a placeholder `ACCOUNT_ID` instead of the actual account number.
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:fred1717/GoldenPipeline:*"
        }
      }
    }
  ]
}
```


### 7.2 Retrieving the account number dynamically
The account ID is then retrieved dynamically and substituted into the file.
It is done using `sed`, a command-line utility to find and replace text within a file.
This avoids hardcoding the account number anywhere in the repository.

**From the project root directory `GoldenPipeline`**
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

sed -i "s/ACCOUNT_ID/${ACCOUNT_ID}/" trust-policy.json
```
**Example output**
`trust-policy.json` has now been updated with the correct account number, retrieved dynamically.



### 7.3 Creating the IAM role, using the trust policy file `trust-policy.json`
**From the project root directory `GoldenPipeline`, containing the trust policy file**
```bash
aws iam create-role --role-name GoldenPipeline-GitHubActions --assume-role-policy-document file://trust-policy.json
```
**Example output (API response displayed in the terminal)**
The role itself is created in AWS IAM, not as a local file.
```json
{
    "Role": {
        "Path": "/",
        "RoleName": "GoldenPipeline-GitHubActions",
        "RoleId": "AROAST6S7NBOH43OZRFYM",
        "Arn": "arn:aws:iam::180294215772:role/GoldenPipeline-GitHubActions",
        "CreateDate": "2026-03-09T23:24:33+00:00",
        "AssumeRolePolicyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {
                        "Federated": "arn:aws:iam::180294215772:oidc-provider/token.actions.githubusercontent.com"
                    },
                    "Action": "sts:AssumeRoleWithWebIdentity",
                    "Condition": {
                        "StringEquals": {
                            "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                        },
                        "StringLike": {
                            "token.actions.githubusercontent.com:sub": "repo:fred1717/GoldenPipeline:*"
                        }
                    }
                }
            ]
        }
    }
}
```


### 7.4 Retrieving the role ARN dynamically and storing it as a GitHub Actions secret
The role ARN is stored as a GitHub Actions secret named `AWS_ROLE_ARN` in the repository settings.
A GitHub Actions secret is an encrypted value stored in the repository settings on GitHub.
Workflows can reference it (as `${{ secrets.AWS_ROLE_ARN }}` in `ci-cd.yml`), but the value is never visible in logs or in the code.
It is the standard mechanism for passing sensitive credentials to a pipeline without hardcoding them.

For that to happen, the repository must already exist at this point (see section 13.1): [section 13.1](#131-repository-creation)

**From the project root directory `GoldenPipeline`**
```bash
ROLE_ARN=$(aws iam get-role --role-name GoldenPipeline-GitHubActions --query Role.Arn --output text)

gh secret set AWS_ROLE_ARN --body "${ROLE_ARN}"
```
**Example output**
```text
Set Actions secret AWS_ROLE_ARN for fred1717/GoldenPipeline
```
**Explanations**
The secret is stored on GitHub in the GoldenPipeline repository, following this path::
Settings > Security section > Secrets and variables > Actions: there is a new "repository secret" called `AWS_ROLE_ARN`.
It is not visible on the main repository page.


### 7.5 Getting the permissions to run the pipeline
The pipeline role follows the least-privilege principle applied throughout the portfolio.
Each permission is scoped to the exact actions the pipeline needs to execute.
No `FullAccess` managed policies are used.
Instead, a custom policy is created in `pipeline-permissions-policy.json`.
It grants only the permissions required by the 5 pipeline stages:
- Stage 1 (static analysis) requires no AWS permissions
- Stage 2 (Packer build) requires:
    - EC2 instance management
    - AMI creation
- Stage 3 (Terraform deploy) requires:
    - VPC
    - EC2
    - IAM
    - SSM endpoint provisioning
- Stage 4 (validation) requires `SSM` command execution
- Stage 5 (teardown) requires:
    - the same provisioning permissions
    - AMI deregistration
    - snapshot deletion


**Creating a custom IAM policy in the AWS account from the JSON file (command run from `GoldenPipeline`):**
The policy exists in IAM but is not attached to any role yet.
```bash
ROLE_NAME="GoldenPipeline-GitHubActions"

aws iam create-policy --policy-name GoldenPipeline-CICD --policy-document file://pipeline-permissions-policy.json
```
**Example output**
```json
{
    "Policy": {
        "PolicyName": "GoldenPipeline-CICD",
        "PolicyId": "ANPAST6S7NBOLUTC7BBTI",
        "Arn": "arn:aws:iam::180294215772:policy/GoldenPipeline-CICD",
        "Path": "/",
        "DefaultVersionId": "v1",
        "AttachmentCount": 0,
        "PermissionsBoundaryUsageCount": 0,
        "IsAttachable": true,
        "CreateDate": "2026-03-10T00:42:15+00:00",
        "UpdateDate": "2026-03-10T00:42:15+00:00"
    }
}
```

**Retrieving the ARN of the newly created policy dynamically (from `GoldenPipeline`)**
The ARN is needed to attach the policy to the role, and hardcoding it would violate best-practice policy.
```bash
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='GoldenPipeline-CICD'].Arn" --output text)
```

**Attaching the policy to the pipeline role**
Only after this step does the role have the permissions defined in the JSON file.
```bash
aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${POLICY_ARN}"
```

**Verifying with:**
```bash
aws iam list-attached-role-policies --role-name GoldenPipeline-GitHubActions
```
**Expected output**
```json
{
    "AttachedPolicies": [
        {
            "PolicyName": "GoldenPipeline-CICD",
            "PolicyArn": "arn:aws:iam::180294215772:policy/GoldenPipeline-CICD"
        }
    ]
}
```
**Explanation**
The custom policy has been successfully attached to the role.

This is consistent with the AWS-native security posture applied elsewhere in the portfolio:
- Bedrock over direct API keys in TerraDriftGuard
- `SSM` over `SSH` in GoldenPipeline



## 8. Using `SSM`
**Why not `SSH`**
- Using `SSH` to validate the instance means:
    - opening port 22 in the security group
    - managing key pairs
    - adding attack surface.

This contradicts the very CIS hardening the project is applying.

**Why SSM**
The best practice alternative is AWS Systems Manager (`SSM`) Session Manager.  
It runs commands on the instance:
- without opening any inbound port
- without any SSH key
- without any security group rule for `SSH` 
- Authentication is handled entirely through IAM

The `SSM` agent is pre-installed on Amazon Linux and recent Ubuntu AMIs.
This has consequences across several components:
- Security group module — no inbound rule for port 22 needed at all
- IAM module — the instance profile needs the `AmazonSSMManagedInstanceCore` managed policy
- Test fixtures (`conftest.py`) — would use `boto3` with `ssm:SendCommand` instead of an SSH library like `paramiko`
- Hardening scripts — `harden_ssh.sh` still applies (the AMI should still have SSH hardened for any eventual use), but the validation mechanism itself does not rely on SSH
- CI/CD workflow — no ephemeral key pair generation needed; the `OIDC` role just needs `SSM` permissions

This also keeps everything within the AWS trust boundary, consistent with the Bedrock decision in TerraDriftGuard.

The test instance runs in a private subnet with no public IP and no internet gateway.  
`SSM` connectivity is provided by 3 interface VPC endpoints:
- com.amazonaws.<region>.ssm
- com.amazonaws.<region>.ssmmessages
- com.amazonaws.<region>.ec2messages

The region component of each endpoint service name is derived from the provider configuration. 
A dedicated security group restricts traffic to the VPC endpoints to HTTPS (port 443) from within the VPC CIDR only.  
This eliminates all public internet exposure from the test infrastructure, consistent with the VPC endpoints approach used in ITF Masters Tour.



## 9. Single job
The pipeline runs as a single GitHub Actions job rather than separate jobs per stage:
- The Terraform state file is stored locally (see [docs/architecture_decisions.md, section 4.3](docs/architecture_decisions.md#43-cost-discipline-for-this-project)).
- Splitting stages into separate jobs would require passing the state file between runners via artifacts.
- A failed artifact upload would prevent teardown and leave resources stranded in the AWS account.
- A single job keeps state on disk across all stages and guarantees that the teardown step can always reach it.



## 10. Deployment — infrastructure deployment, evidence capture
### 10.1 Pre-deployment checks
The following are verified before any deployment begins:
- AWS credentials return the correct account
- the region is `us-east-1`
- the OIDC identity provider exists in the account
- the `Project` cost allocation tag has been activated at least 24 hours before deployment
    The CLI command to activate it (from any directory) is:
    ```bash
    aws ce update-cost-allocation-tags-status --cost-allocation-tags-status TagKey=Project,Status=Active
    ```
    **Example output**
    ```json
    {
    "Errors": []
    }
    ```
    **Explanation**
    The command was successful:  
    - an empty Errors array means the activation succeeded. 
    - The 24-hour propagation clock has started.

#### 10.1.1 Verifying that the activation has propagated

**The following command needs to be run from any directory**
```bash
aws ce list-cost-allocation-tags --tag-keys Project --status Active
```
**Example output**
```json
aws ce list-cost-allocation-tags --tag-keys Project --status Active
{
    "CostAllocationTags": [
        {
            "TagKey": "Project",
            "Type": "UserDefined",
            "Status": "Active",
            "LastUpdatedDate": "2026-03-04T14:55:32Z",
            "LastUsedDate": "2026-03-01T00:00:00Z"
        }
    ]
}
```
**Explanation**
If the tag appears with `Status: Active`, it has propagated.  
That is the case and actually, has been the case for the last 5 days.

#### 10.1.2 Verifying AWS credentials

**The following command needs to be run from any directory**
```bash
    aws sts get-caller-identity
```
**Example output**
```json
    {
        "UserId": "AIDAST6S7NBOL4K6MNLDK",
        "Account": "1802********",
        "Arn": "arn:aws:iam::1802********:user/Malik"
    }
```

#### 10.1.3 Verifying the region

**The following command needs to be run from any directory**
```bash
    aws configure get region
```
**Example output**
```text
    us-east-1
```


### 10.2 Packer build
The following steps are performed from the `packer/` directory:
- execution of `packer init` and `packer build`.
- The AMI ID is captured from the manifest output.
- The AMI is verified in the AWS Console with the correct tags.

#### 10.2.1 Installing Packer

**Installing Packer from HashiCorp's official repository (from any directory)**
The `snap` package is outdated (version 1.0.0) and does not support HCL2 templates or the `init` command.
```bash
packer version
```
**Example output**
```text
Packer v1.15.0
```

**From the `packer/` directory:**
```bash
packer init .
```
**Example output**
```text
Installed plugin github.com/hashicorp/amazon v1.8.0
```
```bash
packer build .
```
**Example output (last line)**
```text
us-east-1: ami-0538467753044ac7c
```

#### 10.2.12 Verifying the AMI with correct tags

**from any directory**
```bash
aws ec2 describe-images --owners self --filters "Name=tag:Project,Values=GoldenPipeline" --query "Images[*].[Name,ImageId,Tags]" --output json
```
**Example output**
```json
[
    [
        "goldenpipeline-cis-1773222667",
        "ami-0538467753044ac7c",
        [
            {
                "Key": "Name",
                "Value": "goldenpipeline-cis-1773222667"
            },
            {
                "Key": "Project",
                "Value": "GoldenPipeline"
            }
        ]
    ]
]
```


### 10.3 Terraform deployment
- The following commands are run from the `terraform/` directory:
    - `terraform init`
    - `terraform plan`
    - `terraform apply`  

- The test instance is verified as launched from the baked AMI.

- The `terraform state` list output is captured for resource count.


#### 10.3.1 Initialising (from the `terraform/` directory)
```bash
terraform init
```
**Example output**
```text
Terraform has been successfully initialized!
```

#### 10.3.2 Saving the generated plan to a binary file called `tfplan` (from the `terraform/` directory)
```bash
terraform plan -out=tfplan
```

#### 10.3.3 Guaranteeing that the plan reviewed is exactly what gets applied (from the `terraform/` directory)
```bash
terraform apply tfplan
```
**Example output**
```text
Apply complete! Resources: 11 added, 0 changed, 0 destroyed.
Outputs:
instance_id = "i-04ce214d77adbe278"
```

#### 10.3.4 Verifying the resource count (from the `terraform/` directory)
```bash
terraform state list
```
```text
data.aws_ami.golden
module.ec2.aws_instance.this
module.iam.aws_iam_instance_profile.this
module.iam.aws_iam_role.this
module.iam.aws_iam_role_policy_attachment.ssm
module.security_group.aws_security_group.this
module.vpc.data.aws_region.current
module.vpc.aws_security_group.vpce
module.vpc.aws_subnet.this
module.vpc.aws_vpc.this
module.vpc.aws_vpc_endpoint.ec2messages
module.vpc.aws_vpc_endpoint.ssm
module.vpc.aws_vpc_endpoint.ssmmessages
```

#### 10.3.5 Verifying that the test instance was launched from the baked AMI (from the `terraform/` directory)
```bash
INSTANCE_ID=$(terraform output -raw instance_id)

aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query "Reservations[0].Instances[0].[Tags[?Key=='Name']|[0].Value,ImageId,State.Name]" --output text
```
**Example output**
```text
GoldenPipeline-test-instance    ami-0538467753044ac7c   running
```


### 10.4 `SSM` connectivity
The test instance is verified as reachable via `SSM` Session Manager.
This confirms that the following are wired correctly:
- VPC endpoints
- security group
- IAM role

**Verifying SSM readiness (from the `terraform/` directory):**
```bash
INSTANCE_ID=$(terraform output -raw instance_id)

aws ssm describe-instance-information --filters "Key=InstanceIds,Values=${INSTANCE_ID}" --query "InstanceInformationList[0].PingStatus" --output text
```
**Example output**
```text
Online
```
The instance is reachable via SSM Session Manager.


### 10.5 CIS validation
The validation stage consists of the following steps:
- `pytest` is run against the running instance from the repository root.
- Test results are captured as evidence.

**Running the full CIS validation test suite against the running test instance (from the project root folder `GoldenPipeline)`**
```bash
pytest tests/ -v
```
**Example output**
```text
configfile: pytest.ini
collected 39 items                                                                                                                                                                

tests/test_cis_audit.py::TestAuditdService::test_auditd_installed PASSED                                                                                                    [  2%]
tests/test_cis_audit.py::TestAuditdService::test_auditd_enabled PASSED                                                                                                      [  5%]
tests/test_cis_audit.py::TestAuditdService::test_auditd_active PASSED                                                                                                       [  7%]
tests/test_cis_audit.py::TestIdentityFileRules::test_identity_files_monitored PASSED                                                                                        [ 10%]
tests/test_cis_audit.py::TestAuditConfigRules::test_audit_config_monitored PASSED                                                                                           [ 12%]
tests/test_cis_audit.py::TestLoginLogoutRules::test_login_events_monitored PASSED                                                                                           [ 15%]
tests/test_cis_audit.py::TestAccessControlRules::test_permission_changes_monitored PASSED                                                                                   [ 17%]
tests/test_cis_audit.py::TestPrivilegedCommandRules::test_sudo_monitored PASSED                                                                                             [ 20%]
tests/test_cis_filesystem.py::TestFileOwnership::test_passwd_ownership PASSED                                                                                               [ 23%]
tests/test_cis_filesystem.py::TestFileOwnership::test_shadow_ownership PASSED                                                                                               [ 25%]
tests/test_cis_filesystem.py::TestFileOwnership::test_group_ownership PASSED                                                                                                [ 28%]
tests/test_cis_filesystem.py::TestFileOwnership::test_gshadow_ownership PASSED                                                                                              [ 30%]
tests/test_cis_filesystem.py::TestFilePermissions::test_passwd_permissions PASSED                                                                                           [ 33%]
tests/test_cis_filesystem.py::TestFilePermissions::test_shadow_permissions PASSED                                                                                           [ 35%]
tests/test_cis_filesystem.py::TestFilePermissions::test_group_permissions PASSED                                                                                            [ 38%]
tests/test_cis_filesystem.py::TestFilePermissions::test_gshadow_permissions PASSED                                                                                          [ 41%]
tests/test_cis_filesystem.py::TestBootloaderPermissions::test_grub_config_ownership PASSED                                                                                  [ 43%]
tests/test_cis_filesystem.py::TestBootloaderPermissions::test_grub_config_permissions PASSED                                                                                [ 46%]
tests/test_cis_filesystem.py::TestWorldWritableFiles::test_no_world_writable_files PASSED                                                                                   [ 48%]
tests/test_cis_filesystem.py::TestUnownedFiles::test_no_unowned_files PASSED                                                                                                [ 51%]
tests/test_cis_filesystem.py::TestUnownedFiles::test_no_ungrouped_files PASSED                                                                                              [ 53%]
tests/test_cis_services.py::TestDisabledServices::test_services_masked PASSED                                                                                               [ 56%]
tests/test_cis_services.py::TestDisabledServices::test_services_not_active PASSED                                                                                           [ 58%]
tests/test_cis_services.py::TestTimeSynchronisation::test_chronyd_enabled PASSED                                                                                            [ 61%]
tests/test_cis_services.py::TestTimeSynchronisation::test_chronyd_active PASSED                                                                                             [ 64%]
tests/test_cis_ssh.py::test_root_login_disabled PASSED                                                                                                                      [ 66%]
tests/test_cis_ssh.py::test_password_authentication_disabled PASSED                                                                                                         [ 69%]
tests/test_cis_ssh.py::test_empty_passwords_disabled PASSED                                                                                                                 [ 71%]
tests/test_cis_ssh.py::test_x11_forwarding_disabled PASSED                                                                                                                  [ 74%]
tests/test_cis_ssh.py::test_max_auth_tries_restricted PASSED                                                                                                                [ 76%]
tests/test_cis_ssh.py::test_permitted_ciphers PASSED                                                                                                                        [ 79%]
tests/test_cis_ssh.py::test_permitted_macs PASSED                                                                                                                           [ 82%]
tests/test_cis_ssh.py::test_permitted_kex_algorithms PASSED                                                                                                                 [ 84%]
tests/test_cis_ssh.py::test_sshd_config_ownership PASSED                                                                                                                    [ 87%]
tests/test_cis_ssh.py::test_sshd_config_permissions PASSED                                                                                                                  [ 89%]
tests/test_cis_updates.py::test_dnf_automatic_installed PASSED                                                                                                              [ 92%]
tests/test_cis_updates.py::test_dnf_automatic_timer_enabled PASSED                                                                                                          [ 94%]
tests/test_cis_updates.py::test_dnf_automatic_timer_active PASSED                                                                                                           [ 97%]
tests/test_cis_updates.py::test_dnf_automatic_security_only PASSED                                                                                                          [100%]

========================================================================= 39 passed in 234.55s (0:03:54) ==========================================================================
```
**Explanation**
Each test sends a shell command to the instance via `SSM` to verify that the hardening configuration was applied correctly.
The `-v` flag produces verbose output, showing each individual test result.
All 39 tests passed and the full output is already captured as evidence.


### 10.6 Evidence capture
The evidence was captured inline throughout the deployment sections:

#### 10.6.1 Evidence collected in subsection 10.2 (Packer build)
See in [section 10.2](#102-packer-build).
The evidence consists of:
 - AMI ID
 - Packer build output
 - AMI tag verification

#### 10.6.2 Evidence collected in subsection 10.3 (Terraform deployment)
See in [section 10.3](#103-terraform-deployment).
The evidence consists of:
 - `terraform apply` output
 - resource count
 - instance verification

#### 10.6.3 Evidence collected in subsection 10.4 (SSM connectivity)
See in [section 10.4](#104-ssm-connectivity).
The evidence consists of:
`SSM` connectivity confirmation

#### 10.6.4 Evidence collected in subsection 10.5 (CIS validation)
See in [section 10.5](#105-cis-validation).
The evidence consists of:
The full `pytest` output with 39 passed tests

All evidence is CLI output, which is verifiable and reproducible.



## 11. Teardown
This consists of:
- `terraform destroy`
- AMI deregistration
- EBS snapshot deletion

### 11.1 Terraform destroy
The teardown stage consists of the following steps:
- `terraform destroy` is run from the terraform/ directory.
- The output is captured as evidence.
- The resource count is verified against the count from section 10.3.

**From the `terraform/` directory:**
```bash
terraform destroy -auto-approve
```
**Example output**
```text
Destroy complete! Resources: 11 destroyed.
```
**Explanation**
The 11 resources destroyed matches the 11 created in section 10.3.


### 11.2 AMI deregistration
The baked AMI is deregistered via the AWS CLI.
Without this step, baked images would accumulate silently in the account.

**Deregistering the AMI (from any directory)**
```bash
AMI_ID=$(aws ec2 describe-images --owners self --filters "Name=tag:Project,Values=GoldenPipeline" --query "Images[0].ImageId" --output text)

aws ec2 deregister-image --image-id "${AMI_ID}"
```
**Example output**
```json
{
    "Return": true,
    "DeleteSnapshotResults": []
}
```
**Explanation**
The AMI is deregistered but the snapshot was not deleted (empty `DeleteSnapshotResults`).


### 11.3 EBS snapshot deletion
The EBS snapshot associated with the deregistered AMI is deleted via the AWS CLI.
Indeed, deregistering an AMI does not automatically delete its underlying snapshot.

**Deleting the EBS snapshot (from any directory)**
```bash
SNAPSHOT_ID=$(aws ec2 describe-snapshots --owner-ids self --filters "Name=tag:Project,Values=GoldenPipeline" --query "Snapshots[0].SnapshotId" --output text)

aws ec2 delete-snapshot --snapshot-id "${SNAPSHOT_ID}"
```

**Checking snapshot deletion (from any directory)**
```bash
aws ec2 describe-snapshots --owner-ids self --filters "Name=tag:Project,Values=GoldenPipeline" --query "Snapshots[*].[SnapshotId,State]" --output text
```
**Expected output**
Nothing, which proves the EBS snapshot has been deleted.




### 11.4 Verification
The following are confirmed empty or absent after teardown:
- no EC2 instances tagged with `Project = GoldenPipeline`
- no AMIs tagged with `Project = GoldenPipeline`
- no orphaned EBS snapshots
- no VPC or subnet remnants

This verification step enforces the IaC discipline principle from `architecture_decisions.md`, section 3.3:
[docs/architecture_decisions.md, section 3.3](docs/architecture_decisions.md#33-iac-discipline:-lesson-from-terradriftguard)

The last remaining checks are:
**Checking for any remaining EC2 instances tagged with `Project = GoldenPipeline` (from any directory)**
```bash
aws ec2 describe-instances --filters "Name=tag:Project,Values=GoldenPipeline" "Name=instance-state-name,Values=running,stopped" --query "Reservations[*].Instances[*].[Tags[?Key=='Name']|[0].Value,InstanceId,State.Name]" --output text
```
**Example output**
Nothing, which proves that all remaining EC2 instances tagged with `Project = GoldenPipeline` have been deleted.

**Checking for any remaining VPCs tagged with `Project = GoldenPipeline` (from any directory)**
```bash
aws ec2 describe-vpcs --filters "Name=tag:Project,Values=GoldenPipeline" --query "Vpcs[*].[Tags[?Key=='Name']|[0].Value,VpcId]" --output text
```
**Example output**
Nothing, which proves that all remaining VPCs tagged with `Project = GoldenPipeline` have been deleted.



## 12. Cost — actual cost from Cost Explorer after teardown
### 12.1 Cost Explorer
The actual cost is retrieved from AWS Cost Explorer after teardown.
The `Project = GoldenPipeline` tag is used to filter all charges attributable to the project.
The results are grouped by AWS service to identify the cost contribution of each component.

**Retrieving the cost breakdown by service (from any directory)**
```bash
aws ce get-cost-and-usage --time-period Start=2026-03-10,End=2026-03-12 --granularity DAILY --filter '{"Tags":{"Key":"Project","Values":["GoldenPipeline"]}}' --metrics BlendedCost --group-by Type=DIMENSION,Key=SERVICE
```
**Example output**
```json
{
    "GroupDefinitions": [
        {
            "Type": "DIMENSION",
            "Key": "SERVICE"
        }
    ],
    "ResultsByTime": [
        {
            "TimePeriod": {
                "Start": "2026-03-10",
                "End": "2026-03-11"
            },
            "Total": {},
            "Groups": [
                {
                    "Keys": [
                        "EC2 - Other"
                    ],
                    "Metrics": {
                        "BlendedCost": {
                            "Amount": "0.0071155119",
                            "Unit": "USD"
                        }
                    }
                },
                {
                    "Keys": [
                        "Amazon Elastic Compute Cloud - Compute"
                    ],
                    "Metrics": {
                        "BlendedCost": {
                            "Amount": "0.0147564456",
                            "Unit": "USD"
                        }
                    }
                },
                {
                    "Keys": [
                        "Amazon Virtual Private Cloud"
                    ],
                    "Metrics": {
                        "BlendedCost": {
                            "Amount": "0.0021501476",
                            "Unit": "USD"
                        }
                    }
                }
            ],
            "Estimated": true
        },
        {
            "TimePeriod": {
                "Start": "2026-03-11",
                "End": "2026-03-12"
            },
            "Total": {},
            "Groups": [
                {
                    "Keys": [
                        "EC2 - Other"
                    ],
                    "Metrics": {
                        "BlendedCost": {
                            "Amount": "0",
                            "Unit": "USD"
                        }
                    }
                },
                {
                    "Keys": [
                        "Amazon Elastic Compute Cloud - Compute"
                    ],
                    "Metrics": {
                        "BlendedCost": {
                            "Amount": "0.0027329016",
                            "Unit": "USD"
                        }
                    }
                },
                {
                    "Keys": [
                        "Amazon Virtual Private Cloud"
                    ],
                    "Metrics": {
                        "BlendedCost": {
                            "Amount": "0.0004006274",
                            "Unit": "USD"
                        }
                    }
                }
            ],
            "Estimated": true
        }
    ],
    "DimensionValueAttributes": []
}
```

### 12.2 Cost breakdown
The cost is broken down by service.
Each line item is compared against the estimate from `architecture_decisions.md`, section 4.3:
[docs/architecture_decisions.md, section 4.3](docs/architecture_decisions.md#43-cost-discipline-for-this-project)

**Breakdown by service, day by day, see 12.1, JSON output above**
*March 10 (deployment day):*
- Amazon Elastic Compute Cloud - Compute: $0.0148
    This covers the instance hours for both the temporary Packer build instance and the test EC2 instance.
    Multiple pipeline runs occurred on this day (pushes 1 through 15), so this includes instances from failed runs as well.
- EC2 - Other: $0.0071
    This covers EBS volumes (root volumes on the instances) and the EBS snapshot created during AMI baking.
- Amazon Virtual Private Cloud: $0.0022
    This covers the 3 interface VPC endpoints:
    - `ssm`
    - `ssmmessages`
    - `ec2messages`
    Interface endpoints are billed per hour per availability zone.
Day total: $0.0241

*March 11:*
- Amazon Elastic Compute Cloud - Compute: $0.0027
    Residual billing from the later pipeline runs on March 10 (the 14th and 15th pushes were close to midnight).
- EC2 - Other: $0.0000
    All EBS volumes and snapshots had been deleted by this point.
- Amazon Virtual Private Cloud: $0.0004
    Residual VPC endpoint billing from the same late runs.
Day total: $0.0031

*Totals by service:*
- EC2 Compute: $0.0175
- EC2 - Other: $0.0071
- VPC: $0.0026
Grand total: approximately $0.03


### 12.3 Portfolio comparison
The final cost is compared against the previous projects:
- ITF Masters Tour (approximately $8)
- TerraDriftGuard (under $1)
- GoldenPipeline ($0.03)



## 13. GitHub — repository setup, commit history

### 13.1 Repository creation
It is using the `gh repo create` command to create a new repository called `GoldenPipeline`, and adding a description for it.

**From the project root directory, `GoldenPipeline/`:**
```bash
gh repo create fred1717/GoldenPipeline --public --description "CIS-hardened golden AMI pipeline: Packer, Terraform, pytest validation via SSM, security-scanning CI/CD with tflint and checkov."
```

The description is kept concise and front-loads the key differentiators visible in a GitHub search result:
- CIS hardening
- golden AMI
- Packer
- security-scanning CI/CD


### 13.2 Initial commit - `git init`, remote setup, first push.
The initialisation of the local project folder and its connection to the remote repository must happen before running `terraform destroy`.
This way, the code will remain safely in GitHub before the whole infrastructure is torn down.

#### 13.2.1 Git commands
**From the project root directory `GoldenPipeline/`:**
```bash
git init
git remote add origin https://github.com/fred1717/GoldenPipeline.git
git branch -M main
```

##### 13.2.1.1 First push
**All files will then be staged, committed, and pushed (run from the project root directory `Goldenpipeline`):**
```bash
git add .
git commit -m "Initial commit: GoldenPipeline project structure"
git push -u origin main
```

This step must also be completed before running `terraform destroy`.
Once the code is safely in GitHub, nothing is lost when the infrastructure is torn down.

##### 13.2.1.2 Second push
**After the OIDC setup and custom policy creation are complete, the changes are committed and pushed, see in 13.2.2.1 (from the project root directory `Goldenpipeline`):**
```bash
git add .
git commit -m "OIDC setup: trust policy, pipeline permissions policy, .gitignore updated"
git push
```

##### 13.2.1.3 Third push
**Third push after `tflint` error message, see in 13.2.2.2 (from root project folder)**
All `main.tf` were missing the block indicating the Terraform version.
The root `main.tf` also needed the `required_providers` block inside it.
```bash
git add .
git commit -m "Fix tflint: add required_version and required_providers"
git push
```

##### 13.2.1.4 Fourth push
**Fourth push after renewed `tflint` error message, see in 13.2.2.3 (from root project folder)**
After inserting the `required_providers` block at the top of each module `main.tf`:
```bash
git add .
git commit -m "Fix tflint: adding the 'required_providers' block at the top of each module 'main.tf'"
git push
```

##### 13.2.1.5 Fifth push
**Fifth push after "fixing" `checkov` error messages, see in 13.2.2.4 (from root project folder)**
After amending a few module `main.tf`, see in 13.2.2:
```bash
git add .
git commit -m "Fix checkov: enforce IMDSv2, EBS optimisation, suppress justified checks"
git push
```

##### 13.2.1.6 Sixth push
**Sixth push after creating a default VPC, see in 13.2.2.5 (from root project folder)**
```bash
git add .
git commit -m "Add default VPC as Packer build prerequisite"
git push
```

##### 13.2.1.7 Seventh push
**Seventh push after updating `pipeline-permissions-policy.json`, see in 13.2.2.6 (from root project folder)**
```bash
git add .
git commit -m "Fix: replace em dash in SG description, also add RevokeSecurityGroupEgress to pipeline policy"
git push
```

##### 13.2.1.8 Eighth push
**Eighth push after updating again `pipeline-permissions-policy.json`, see in 13.2.2.7 (from root project folder)**
```bash
git add .
git commit -m "Fix: add AuthorizeSecurityGroupEgress to pipeline policy"
git push
```

##### 13.2.1.9 Ninth push
**Ninth push after updating `packer/harden_filesystem.sh`, see in 13.2.2.8 (from root project folder)**
```bash
git add .
git commit -m "Fix: handle inaccessible paths in harden_filesystem.sh find commands"
git push
```

##### 13.2.1.10 Tenth push after updating again `pipeline-permissions-policy.json` by adding the `ec2:DescribeInstanceTypes` permission, see in 13.2.9 (from root project folder)**
**Tenth push after updating `packer/harden_filesystem.sh`, see in 13.2.2.9 (from root project folder)**
```bash
git add .
git commit -m "Fix: add DescribeInstanceTypes to pipeline policy"
git push
```

##### 13.2.1.11 Eleventh push after updating again cleaning up stranded resources, see in 13.2.10 (from root project folder)**
**Eleventh push after updating `packer/harden_filesystem.sh`, see in 13.2.2.10 (from root project folder)**
```bash
git add .
git commit -m "Clean stranded IAM resources from failed teardown"
git push
```

##### 13.2.1.12 twelfth push after updating again cleaning up stranded resources, see in 13.2.11 (from root project folder)**
**Twelfth push after updating `packer/harden_filesystem.sh`, see in 13.2.2.11 (from root project folder)**
```bash
git add .
git commit -m "Fix: add DescribeInstanceTypes to pipeline policy (forgotten before) and clean up stranded resources from failed teardown"
git push
```

##### 13.2.1.13 thirteenth push after updating `pipeline-permissions-policy.json` and cleaning up stranded resources, see in 13.2.12 (from root project folder)**
**`pipeline-permissions-policy.json` , see in 13.2.2.12 (from root project folder)**
```bash
git add .
git commit -m "Fix: replace individual ec2:Describe actions with ec2:Describe* wildcard and clean up stranded resources from failed teardown"
git push
```

##### 13.2.1.14 fourteenth push after updating `.github/workflows/ci-cd.yml` and cleaning up stranded resources, see in 13.2.13 (from root project folder)**
```bash
git add .
git commit -m "Add SSM readiness wait step between terraform apply and pytest."
git push
```

##### 13.2.1.15 fifteenth push after updating `test_cis_filesystem.py` and `test_cis_filesystem.py`, see in 13.2.14 (from root project folder)**
```bash
git add .
git commit -m "Fix: stat output comparison and multi-line systemctl output handling in tests"
git push
```

#### 13.2.2 Debugging steps
##### 13.2.2.1 First pipeline run
**Initial commit, see in 13.2.1.1**
The first push triggered the pipeline.
It failed at the "Configure AWS credentials via OIDC" step.
This was expected: the OIDC provider and IAM role did not exist yet at that point.

##### 13.2.2.2 Second pipeline run
**OIDC setup commit, see in 13.2.1.2**
The second push triggered the pipeline after the OIDC setup was complete.
The OIDC authentication succeeded.
The pipeline progressed to Stage 1 (static analysis) and failed at `tflint`.
`tflint` flagged 10 issues across 5 files.
All 10 were the same 2 violations:
- missing `required_version` attribute in the terraform block
- missing `required_providers` with a version constraint for the AWS provider

The `root main.tf` was amended with a terraform block containing both attributes.
Each module `main.tf` was amended with a terraform block containing `required_version` only.
The `required_providers` block is only needed at the root level.
That was at least the conclusion drawn here, which unfortunately proved to be wrong (see next debugging step).

##### 13.2.2.3 Debugging steps after third push (see in 13.2.1.3)
Listing the most recent pipeline run and returning 4 fields:
- the run ID
- whether it succeeded or failed
- the workflow name
- when it was triggered

**`tflint` fix (from root project folder)**
```bash
gh run list --limit 1 --json databaseId,conclusion,name,createdAt
```
**Example output**
```json
[
  {
    "conclusion": "failure",
    "createdAt": "2026-03-10T14:34:51Z",
    "databaseId": 22907781148,
    "name": "GoldenPipeline CI/CD"
  }
]
```
**Retrieving the log output of the failed step only (from root project folder)**
```bash
gh run view 22907781148 --log-failed
```
**Explanation of log error messages (around 100 lines, all pointing to the same error)**
The verdict is that the earlier conclusion was wrong: 
`tflint` requires `required_providers` in each module as well, not only at the root level.
That means inserting the same block as in the root `main.tf` at the top of each module `main.tf`.
```json
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

##### 13.2.2.4 Debugging steps after the fourth push
After running the same debugging commands, the verdict was the following:
`tflint` passed but `checkov` flagged 6 issues.

The 6 issues fall into 2 categories:
**Issues to fix (genuine security best practice):**
- **CKV_AWS_79** — Instance Metadata Service v1 is not disabled.
    `IMDSv1` is a known attack vector:
        The Instance Metadata Service exposes sensitive information (IAM credentials, instance identity) at a fixed URL (http://169.254.169.254).
        In version 1, any process on the instance can query it with a simple HTTP GET request.
        An attacker could gain access to a web application running on the instance (for example, via `SSRF` - Server-Side Request Forgery).
        In that case, they would retrieve the IAM role credentials from the metadata endpoint.
    On the other hand, `IMDSv2` requires a session token obtained via a PUT request first, which blocks most `SSRF` attacks.
        A `metadata_options` block is added to the EC2 module to enforce `IMDSv2`.
- **CKV_AWS_135** — EBS optimisation is not explicitly set.
    `t3.micro` is EBS optimised by default, but `checkov` requires the explicit attribute `ebs_optimized = true`.

**Issues suppressed with justification (not appropriate for ephemeral test infrastructure):**
- **CKV_AWS_126** — Detailed monitoring not enabled.
    This enables 1-minute CloudWatch metrics at additional cost.
    The test instance lives for minutes during validation.
    Not justified for this use case.
- **CKV2_AWS_11** — VPC flow logging not enabled.
    This adds cost and a CloudWatch Log Group.
    The VPC is ephemeral test infrastructure destroyed after validation.
    Not justified.
- **CKV2_AWS_12** — Default security group does not restrict all traffic.
    This requires managing the default security group explicitly.
    The test instance uses a custom security group with no inbound rules and restricted egress.
    No security benefit for this use case.
- **CKV2_AWS_5** — Security group not attached to a resource.
    This is a false positive, a problem that does not actually exist.
    The security group is attached to the EC2 instance via a cross-module reference that `checkov` cannot resolve.

Suppressions are applied as inline skip comments in the relevant Terraform resource definitions.
The justification is visible to anyone reading the code.
The comments go in:
- `modules/ec2/main.tf`
- `modules/vpc/main.tf`
- `modules/security_group/main.tf`.
They are placed directly above the resource block that triggers the check.
For example, in `modules/ec2/main.tf`:
```text
# checkov:skip=CKV_AWS_126:Detailed monitoring not justified for ephemeral test instance
```

##### 13.2.2.5 Debugging steps after the fifth push
**Checking the fifth push after renewed error messages, see in 13.2.1.5 (same command as before, from the root project folder)**
```bash
gh run list --limit 1 --json databaseId,conclusion,name,createdAt
```
**Example output**
```json
[
  {
    "conclusion": "failure",
    "createdAt": "2026-03-10T16:49:44Z",
    "databaseId": 22913904305,
    "name": "GoldenPipeline CI/CD"
  }
]
```
**Again, retrieving the log output of the failed step only (from root project folder)**
```bash
gh run view 22913904305 --log-failed
```
**Explanation of log error messages (around 1000 lines)**
Stage 1 passed entirely. 
The pipeline progressed to Stage 2 (Packer build) and failed.
The error is: "No default VPC for this user".
Packer tries to create a temporary security group in the default VPC when no `vpc_id` is specified in the template. 
The account has no default VPC in `us-east-1`.

There are 2 options:
- Create a default VPC in `us-east-1`:
    This is an account-level resource that Packer expects to exist. 
    It is also the standard approach for Packer builds. 
    It falls into the same category as the OIDC setup, which is bootstrap infrastructure.
- Add `vpc_id` and `subnet_id` to the Packer template:
    The build instance is then launched in a specific VPC. 
    However, that VPC must have internet access as the hardening scripts run `dnf install`.
    Therefore, it cannot be the Terraform-managed private VPC.

For these reasons the first option is preferable.
**From any directory:**
```bash
aws ec2 create-default-vpc
```
**Example output**
```json
{
    "Vpc": {
        "OwnerId": "180294215772",
        "InstanceTenancy": "default",
        "Ipv6CidrBlockAssociationSet": [],
        "CidrBlockAssociationSet": [
            {
                "AssociationId": "vpc-cidr-assoc-0a5cd84e698224b24",
                "CidrBlock": "172.31.0.0/16",
                "CidrBlockState": {
                    "State": "associated"
                }
            }
        ],
        "IsDefault": true,
        "Tags": [],
        "VpcId": "vpc-05f6c7d401bf376b4",
        "State": "pending",
        "CidrBlock": "172.31.0.0/16",
        "DhcpOptionsId": "dopt-088ca909502fe7db0"
    }
}
```
**The default VPC is then tagged for visibility:**
```bash
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)

aws ec2 create-tags --resources "${VPC_ID}" --tags Key=Name,Value=default-vpc-us-east-1
```
This is not project infrastructure.
It is an account-level prerequisite, in the same category as the OIDC provider.
It is not managed by Terraform and is not destroyed with the project.

##### 13.2.2.6 Debugging steps after the sixth push
**Checking the sixth push after several minutes, see in 13.2.1.6 (from the project root folder)**
```bash
gh run list --limit 1 --json databaseId,conclusion,name,createdAt
```
**Example output**
```json
[
  {
    "conclusion": "failure",
    "createdAt": "2026-03-10T17:38:55Z",
    "databaseId": 22916010167,
    "name": "GoldenPipeline CI/CD"
  }
]
```
**For the sixth time, retrieving the log output of the failed step only (from root project folder)**
```bash
gh run view 22916010167 --log-failed
```
**Verdict**
Stage 1 and Stage 2 both passed. 
The Packer build succeeded. 
The pipeline failed at Stage 3 (`Terraform apply`) with 2 errors:
- Error 1: Non-ASCII character in security group description.
    The description in `modules/security_group/main.tf` contains an em dash (—):
    "Security group for the test EC2 instance — no inbound, HTTPS to VPC only"
    AWS rejects non-ASCII characters in security group descriptions.
    The em dash needs replacing with a regular dash (-).
- Error 2: Missing IAM permission.
    The pipeline role is missing `ec2:RevokeSecurityGroupEgress`.
    Terraform automatically revokes the default egress rule on security groups before applying custom rules.
    This action was not included in `pipeline-permissions-policy.json`.

**Fixing both errors**
The em dash in `modules/security_group/main.tf` is replaced with a regular dash.
The missing `ec2:RevokeSecurityGroupEgress` action is added to `pipeline-permissions-policy.json` under the `PackerTemporarySecurityGroup` statement.

**The updated policy is applied from any directory:**
```bash
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='GoldenPipeline-CICD'].Arn" --output text)

aws iam create-policy-version --policy-arn "${POLICY_ARN}" --policy-document file://pipeline-permissions-policy.json --set-as-default
```
**Example output**
```bash
{
    "PolicyVersion": {
        "VersionId": "v2",
        "IsDefaultVersion": true,
        "CreateDate": "2026-03-10T19:09:07+00:00"
    }
}
```

##### 13.2.2.7 Debugging steps after the seventh push
**Checking the seventh push after several minutes, see in 13.2.1.7 (from root project folder)**
```bash
gh run list --limit 1 --json databaseId,conclusion,name,createdAt
```
```json
[
  {
    "conclusion": "",
    "createdAt": "2026-03-10T19:11:40Z",
    "databaseId": 22919851370,
    "name": "GoldenPipeline CI/CD"
  }
]
```
**For the seventh time, retrieving the log output of the failed step only (from root project folder)**
```bash
gh run view 22919851370 --log-failed
```
**Verdict**
A permission is missing:  
`ec2:RevokeSecurityGroupEgress` passed but `ec2:AuthorizeSecurityGroupEgress` is blocked.
Terraform first revokes the default egress rule, then authorises the custom egress rule. 
Both actions need permission.
In `pipeline-permissions-policy.json`, inside the `TerraformVPC statement`, after `ec2:RevokeSecurityGroupEgress`:
 **Insertion of `ec2:AuthorizeSecurityGroupEgress`**

 **Updating again the policy**
```bash
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='GoldenPipeline-CICD'].Arn" --output text)

aws iam create-policy-version --policy-arn "${POLICY_ARN}" --policy-document file://pipeline-permissions-policy.json --set-as-default
```
**Example output**
```bash
{
    "PolicyVersion": {
        "VersionId": "v3",
        "IsDefaultVersion": true,
        "CreateDate": "2026-03-10T19:33:19+00:00"
    }
}
```

##### 13.2.2.8 Debugging steps after the eighth push
**Checking the eighth push after several minutes, see in 13.2.1.8 (from root project folder)**
```bash
gh run list --limit 1 --json databaseId,conclusion,name,createdAt
```
```json
[
  {
    "conclusion": "failure",
    "createdAt": "2026-03-10T19:41:43Z",
    "databaseId": 22921048691,
    "name": "GoldenPipeline CI/CD"
  }
]
```
**For the eighth time, retrieving the log output of the failed step only (from root project folder)**
```bash
gh run view 22921048691 --log-failed
```
**Verdict**
The failure is in `harden_filesystem.sh`, during the world-writable files or unowned files scan.  
The `find` command encounters a Docker overlay2 directory that no longer exists (a transient mount point). 
As the script uses `set -euo pipefail`, the non-zero exit from `find` aborts the entire script.
The base Amazon Linux 2023 AMI includes Docker, and its overlay filesystem creates ephemeral paths that `find` cannot traverse.
The fix is in `harden_filesystem.sh`. 
The `find` commands that scan partitions need `|| true` appended to prevent `set -e` from aborting when `find` encounters an inaccessible path.
There are 4 `find` commands inside the partition loops. 
Each one needs `|| true` at the end:

##### 13.2.2.9 Debugging steps after the ninth push
**Checking the ninth push after several minutes, see in 13.2.1.9 (from root project folder)**
```bash
gh run list --limit 1 --json databaseId,conclusion,name,createdAt
```
```json
[
  {
    "conclusion": "failure",
    "createdAt": "2026-03-10T20:09:39Z",
    "databaseId": 22922119091,
    "name": "GoldenPipeline CI/CD"
  }
]
```
**For the ninth time, retrieving the log output of the failed step only (from root project folder)**
```bash
gh run view 22922119091 --log-failed
```
**Verdict**
There are some good news: Stages 1 through 4 all passed. 
The pipeline failed only at Stage 5 (teardown).

There is still one permission missing: `ec2:DescribeInstanceTypes`. 
**Amending `pipeline-permissions-policy.json`**
Inside the `PackerBuildEC2` statement, after `ec2:DescribeDhcpOptions`:
```json
"ec2:DescribeInstanceTypes"
```
 **Updating again the policy**
```bash
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='GoldenPipeline-CICD'].Arn" --output text)

aws iam create-policy-version --policy-arn "${POLICY_ARN}" --policy-document file://pipeline-permissions-policy.json --set-as-default
```
**Example output**
```bash
{
    "PolicyVersion": {
        "VersionId": "v4",
        "IsDefaultVersion": true,
        "CreateDate": "2026-03-10T21:30:59+00:00"
    }
}
```

##### 13.2.2.10 Debugging steps after the tenth push
**Checking the tenth push after several minutes, see in 13.2.1.10 (from root project folder)**
```bash
gh run list --limit 1 --json databaseId,conclusion,name,createdAt
```
```json
[
  {
    "conclusion": "failure",
    "createdAt": "2026-03-10T20:36:22Z",
    "databaseId": 22923146667,
    "name": "GoldenPipeline CI/CD"
  }
]
```
**For the tenth time, retrieving the log output of the failed step only (from root project folder)**
```bash
gh run view 22923146667 --log-failed
```
**Verdict**
The error is that `GoldenPipeline-ec2-role` already exists in the AWS account from a previous pipeline run where teardown failed.  
It is a stranded IAM resource that was not cleaned up earlier alongside:
- the VPC
- security groups
- endpoints

The stranded IAM resources need deleting before the next push. 
There are 3 components to clean up:
- the IAM role
- its policy attachment
- the instance profile

**Checking whether there still is a stranded AMI from the successful Packer build**
```bash
aws ec2 describe-images --owners self --filters "Name=tag:Project,Values=GoldenPipeline" --query "Images[*].[Name,ImageId,State]" --output text
```
**Example output**
Nothing, so there is no stranded AMI left.

**Cleaning up the stranded IAM resources (from any directory):**
```bash
aws iam remove-role-from-instance-profile --instance-profile-name GoldenPipeline-ec2-profile --role-name GoldenPipeline-ec2-role
aws iam delete-instance-profile --instance-profile-name GoldenPipeline-ec2-profile
aws iam detach-role-policy --role-name GoldenPipeline-ec2-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name GoldenPipeline-ec2-role
```

##### 13.2.2.11 Debugging steps after the eleventh push
**Checking the eleventh push after several minutes, see in 13.2.1.11 (from root project folder)**
```bash
gh run list --limit 1 --json databaseId,conclusion,name,createdAt
```
```json

```
**For the eleventh time, retrieving the log output of the failed step only (from root project folder)**
```bash
gh run view 22924574322 --log-failed
```
**Verdict**
It was a case of forgetting to attach the policy in step 10:
 **Updating again the policy**
```bash
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='GoldenPipeline-CICD'].Arn" --output text)

aws iam create-policy-version --policy-arn "${POLICY_ARN}" --policy-document file://pipeline-permissions-policy.json --set-as-default
```
**Example output**
```bash
{
    "PolicyVersion": {
        "VersionId": "v4",
        "IsDefaultVersion": true,
        "CreateDate": "2026-03-10T21:30:59+00:00"
    }
}
```

But now, a new cleanup is necessary to avoid new stranded resources.
**Cleanup**
**Check for running instances and delete them**
```bash
for INSTANCE_ID in $(aws ec2 describe-instances --filters "Name=tag:Project,Values=GoldenPipeline" "Name=instance-state-name,Values=running,stopped" --query "Reservations[*].Instances[*].InstanceId" --output text);
do
  aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}"
done
```

**Check for stranded VPC endpoints and delete them**
```bash
aws ec2 describe-vpc-endpoints --filters "Name=tag:Project,Values=GoldenPipeline" --query "VpcEndpoints[*].[Tags[?Key=='Name']|[0].Value,VpcEndpointId,State]" --output text
ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints --filters "Name=tag:Project,Values=GoldenPipeline" --query "VpcEndpoints[*].VpcEndpointId" --output text)
aws ec2 delete-vpc-endpoints --vpc-endpoint-ids ${ENDPOINT_IDS}
```

**Check and delete Security Groups**
```bash
aws ec2 describe-security-groups --filters "Name=tag:Project,Values=GoldenPipeline" --query "SecurityGroups[*].[Tags[?Key=='Name']|[0].Value,GroupId]" --output text
for SG_ID in $(aws ec2 describe-security-groups --filters "Name=tag:Project,Values=GoldenPipeline" --query "SecurityGroups[*].GroupId" --output text); 
    do aws ec2 delete-security-group --group-id "${SG_ID}"
done
```

**Check VPC and subnet, then delete them**
```bash
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=GoldenPipeline" --query "Vpcs[0].VpcId" --output text)

for SUBNET_ID in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query "Subnets[*].SubnetId" --output text);
  do aws ec2 delete-subnet --subnet-id "${SUBNET_ID}"
done

aws ec2 delete-vpc --vpc-id "${VPC_ID}"
```

**Check for stranded IAM resources and clean them up, as in 13.2.2.10**
```bash
aws iam get-instance-profile --instance-profile-name GoldenPipeline-ec2-profile --query "InstanceProfile.InstanceProfileName" --output text 2>&1
aws iam remove-role-from-instance-profile --instance-profile-name GoldenPipeline-ec2-profile --role-name GoldenPipeline-ec2-role
aws iam delete-instance-profile --instance-profile-name GoldenPipeline-ec2-profile
aws iam detach-role-policy --role-name GoldenPipeline-ec2-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name GoldenPipeline-ec2-role
```

**Checking the cleanup was complete, for each resource type**
**EC2 instance tagged with `Project = GoldenPipeline`**
```bash
aws ec2 describe-instances --filters "Name=tag:Project,Values=GoldenPipeline" "Name=instance-state-name,Values=running,stopped" --query "Reservations[*].Instances[*].[Tags[?Key=='Name']|[0].Value,InstanceId,State.Name]" --output text
```
**Checking VPC endpoints, Security Groups, VPCs**
```bash
aws ec2 describe-vpc-endpoints --filters "Name=tag:Project,Values=GoldenPipeline" --query "VpcEndpoints[*].[Tags[?Key=='Name']|[0].Value,VpcEndpointId,State]" --output text
aws ec2 describe-security-groups --filters "Name=tag:Project,Values=GoldenPipeline" --query "SecurityGroups[*].[Tags[?Key=='Name']|[0].Value,GroupId]" --output text
aws ec2 describe-vpcs --filters "Name=tag:Project,Values=GoldenPipeline" --query "Vpcs[*].[Tags[?Key=='Name']|[0].Value,VpcId]" --output text
```
**Checking for any stranded AMIs created by Packer builds that were not deregistered during failed teardowns**
```bash
aws ec2 describe-images --owners self --filters "Name=tag:Project,Values=GoldenPipeline" --query "Images[*].[Name,ImageId,State]" --output text
```
**Expected output**
Nothing, which means that the cleanup was successful.

##### 13.2.2.12 Debugging steps after the twelfth push
**Checking the twelfth push after several minutes, see in 13.2.1.12 (from root project folder)**
```bash
gh run list --limit 1 --json databaseId,conclusion,name,createdAt
```
```json
[
  {
    "conclusion": "failure",
    "createdAt": "2026-03-10T22:02:16Z",
    "databaseId": 22926297331,
    "name": "GoldenPipeline CI/CD"
  }
]
```
**For the twelfth time, retrieving the log output of the failed step only (from root project folder)**
```bash
gh run view 22926297331 --log-failed
```
**Verdict**
The incremental approach to permissions is not working.  
Every push uncovers another missing `Describe*` action at teardown.
The root cause: 
- Terraform reads multiple instance attributes during `destroy` that are not needed during `apply`. 
- Adding them one at a time will continue to fail.

The proper fix is to replace the individual `ec2:Describe*` actions in the `PackerBuildEC2` statement with a single wildcard:
```json
"ec2:Describe*"
```

This covers all EC2 read-only operations.  
It is still least privilege because `Describe*` actions are read-only and cannot modify any resource.  
AWS documentation explicitly considers `Describe*` safe for read-only roles.
This replaces all the individual `ec2:Describe*` entries in the `PackerBuildEC2` statement (`pipeline-permissions-policy.json`):
- `ec2:DescribeInstances`
- `ec2:DescribeInstanceStatus`
- `ec2:DescribeImages`
- and all others

**The `PackerBuildEC2` statement in `pipeline-permissions-policy.json` becomes:**
```json
{
  "Sid": "PackerBuildEC2",
  "Effect": "Allow",
  "Action": [
    "ec2:RunInstances",
    "ec2:TerminateInstances",
    "ec2:StopInstances",
    "ec2:StartInstances",
    "ec2:Describe*"
  ],
```

 **Updating again the policy**
```bash
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='GoldenPipeline-CICD'].Arn" --output text)

aws iam create-policy-version --policy-arn "${POLICY_ARN}" --policy-document file://pipeline-permissions-policy.json --set-as-default
```
**Example output**
```bash
{
    "PolicyVersion": {
        "VersionId": "v5",
        "IsDefaultVersion": true,
        "CreateDate": "2026-03-10T22:29:53+00:00"
    }
}
```

Once again, a cleanup is necessary to avoid stranded resources after failed teardown.
**Going through the same cleanup steps as in 13.2.2.11**
**Expected output**
Once again, there was no output, which means that the cleanup was successful.

##### 13.2.2.13 Debugging steps after the thirteenth push
**Checking the thirteenth push after several minutes, see in 13.2.1.13 (from root project folder)**
```bash
gh run list --limit 1 --json databaseId,conclusion,name,createdAt
```
```json
[
  {
    "conclusion": "failure",
    "createdAt": "2026-03-10T23:13:09Z",
    "databaseId": 22928513644,
    "name": "GoldenPipeline CI/CD"
  }
]
```
**For the thirteenth time, retrieving the log output of the failed step only (from root project folder)**
```bash
gh run view 22928513644 --log-failed
```
**Verdict**
Stages 1, 2, and 3 all passed.  
The failure is at Stage 4.  
All 39 tests failed with the same error: "Instances not in a valid state for account."
The instance exists and is running. 
The problem is that the `SSM` agent has not yet registered with `SSM` when the tests start.  
The pipeline moves from `terraform apply` to `pytest` immediately, with no wait for `SSM` readiness.
The fix is to add a wait step in `ci-cd.yml` between Stage 3 and Stage 4 that polls until the instance is registered with `SSM`.

There is now a timeout of 300 seconds (5 minutes), this is not a fixed wait.
The step checks every 10 seconds. 
As soon as `SSM` reports "Online", the step exits and Stage 4 starts immediately.  
Typically this takes 30 to 60 seconds.
If `SSM` has not registered after 300 seconds, the step fails with exit 1 and the pipeline stops.  
The tests will never run against an unregistered instance.

**Going through the same cleanup steps as in 13.2.2.11**
**Expected output**
This time, there was nothing to clean up.

##### 13.2.2.14 Debugging steps after the fourteenth push
**Checking the fourteenth push after several minutes (18 minutes this time!), see in 13.2.1.14 (from root project folder)**
```bash
gh run list --limit 1 --json databaseId,conclusion,name,createdAt
```
```json
[
  {
    "conclusion": "failed",
    "createdAt": "2026-03-11T00:11:17Z",
    "databaseId": 22930177649,
    "name": "GoldenPipeline CI/CD"
  }
]
```
**For the fourteenth time, retrieving the log output of the failed step only (from root project folder)**
```bash
gh run view 22930177649 --log-failed
```
**Verdict**
35 out of 39 tests passed.  
The `SSM` readiness fix worked.  
Only 4 test bugs remain, and the hardening itself is correct in all 4 cases.

**Failures 1 and 2**  
file permissions:
- `stat -c '%a'` returns 0 instead of 000 for mode 0000.
- The test asserts `output == "000"` but `stat` outputs the minimal representation.
The fix is in `test_cis_filesystem.py`: both assertions must be changed to compare against "0" instead of "000"

**Failures 3 and 4** 
service masking:
- `rpcbind` has both a service unit and a socket unit:
    - `rpcbind.service`
    - `rpcbind.socket`
- `systemctl is-enabled rpcbind` returns 2 lines:  
    - `masked`  
    - `not-installed`
- The test expects a single-line output and compares the whole string.
The fix is in `test_cis_services.py`: split the output by newline and check that each line is in the accepted values.

**Going through the same cleanup steps as in 13.2.2.11**
**Expected output**
There was nothing to clean up.
This is because in `ci-cd.yml`, both Stage 5 steps have `if: always() && github.event_name == 'push'`.  
This means Stage 5 runs even when a previous stage fails.  
Therefore, teardown has already succeeded this time.

##### 13.2.2.15 Debugging steps after the fifteenth push
**Checking the fifteenth push (23 minutes to get the result this time), see in 13.2.1.15 (from root project folder)**
```bash
gh run list --limit 1 --json databaseId,conclusion,name,createdAt
```
```json
[
  {
    "conclusion": "success",
    "createdAt": "2026-03-11T00:55:57Z",
    "databaseId": 22931413118,
    "name": "GoldenPipeline CI/CD"
  }
]
```
**Verdict**
All 5 stages passed. 
The pipeline is fully operational, AT LAST!!!
Resources were created and destroyed within this single pipeline run.  
- Stage 2 baked the AMI
- Stage 3 deployed the test infrastructure
- Stage 4 ran the tests
- Stage 5 tore everything down.



### 13.3 Post-deployment commits

#### 13.3.1 Sixteenth push
The following changes were committed after the pipeline succeeded (see 13.2.2.15).

**Changes included:**
- `tfplan` added to `.gitignore`.
  This file is generated by `terraform plan -out=tfplan` during deployment (see 10.3.2).
  It is environment-specific, not human-readable, and can contain sensitive resource attributes.
  The plan-then-apply discipline is already documented in sections 10.3.2 and 10.3.3.
- `repository_structure.md` updated to reflect the current state of the project
- unused `SENSITIVE_FILES` dictionary removed from `test_cis_filesystem.py`
- README sections 10 and 11 written, covering deployment evidence and teardown procedure
- minor typos corrected

**From the project root directory `GoldenPipeline/`:**
```bash
git add .
git commit -m "Post-deployment: gitignore tfplan, remove unused SENSITIVE_FILES, add README sections 10-11, fix typos"
git push origin main
```

#### 13.3.2 Seventeenth push
The architecture diagram has been added.

**From the project root directory `GoldenPipeline/`:**
```bash
git add docs/diagrams/goldenpipeline-architecture.svg
git commit -m "Add architecture diagram"
git push origin main
```

#### 13.3.3 Eighteenth push
Section 0 of `architecture_decisions.md` has been drafted.

**From the project root directory `GoldenPipeline/`:**
```bash
git add docs/architecture_decisions.md
git commit -m "Draft section 0 of architecture_decisions.md"
git push origin main
```

#### 13.3.4 Nineteenth push
Section 12 of the README has been drafted, covering actual cost from Cost Explorer after teardown.

**From the project root directory `GoldenPipeline/`:**
```bash
git add README.md
git commit -m "Draft README section 12: cost breakdown from Cost Explorer"
git push origin main
```


### 13.4 Release - The `gh release create` command.
Content depends on the final state of the project.



