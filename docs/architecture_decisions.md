## 0. GoldenPipeline: Project Summary

*To be written last, once the remaining sections are settled.*



## 1. Background: CI/CD Concepts

Continuous Integration means that every time code is pushed, an automated pipeline immediately:
- checks that the code is correctly formatted
- runs tests
- flags security or configuration issues

The point is catching problems:
- before they reach production
- automatically
- without relying on anyone remembering to run checks manually.

Continuous Deployment means that if those checks pass, the pipeline then:
- deploys the code to AWS automatically
- eliminates the need for:
    - manual `terraform apply` from a laptop
    - or manual Lambda uploads

In practice, every `git push` triggers a GitHub Actions workflow that runs the following tools in sequence:
- `terraform fmt`
- `tflint`
- `checkov`
- `packer fmt`
- `packer validate`
- `terraform plan`

If all checks pass, `terraform apply` fires automatically.
If any check fails, the pipeline stops and the deployment does not happen.

The pipeline acts as a quality gate: the code has to pass every check before it earns the right to be deployed.


### 1.1 Tool Definitions

**terraform fmt**
This is Terraform's built-in formatter:
- It automatically standardises the layout of `.tf` files (indentation, spacing).
- Running it as a check in a pipeline ensures all code is consistently formatted before merging.

**tflint**
A linter for Terraform: 
- It catches issues that Terraform itself would not flag until an actual deployment is attempted.
- It reads `.tf` files and flags:
    - mistakes
    - deprecated syntax
    - bad practices

**checkov**
A security scanner for infrastructure-as-code.
It reads Terraform code and flags risky configurations:
- an S3 bucket with public access
- a security group open to the world
- a Lambda with overly broad IAM permissions

**packer fmt**
Packer's built-in formatter, equivalent to `terraform fmt` for `.pkr.hcl` files.
It standardises the layout of Packer template files.
Running it as a check in the pipeline ensures consistent formatting across both Terraform and Packer code.

**packer validate**
Validates the Packer template syntax and configuration before a build is attempted.
It catches errors such as missing variables, invalid provisioner references, or malformed HCL — without launching any AWS resources.

None of these tools are complex to add to a pipeline.
They are all just commands that run in sequence inside a GitHub Actions workflow file.



## 2. Background: Golden AMIs and Packer


### 2.1 What is an AMI?

AMI stands for Amazon Machine Image — the template AWS uses to launch EC2 instances. 
It contains:
- the operating system
- configuration
- installed software
- security hardening


### 2.2 What does "baking" an AMI mean?

"Baking" an AMI means building a custom, pre-configured image automatically,
as opposed to launching a bare EC2 instance and configuring it manually after the fact.

The result is an image that can be reused to launch identical, pre-hardened instances instantly.


### 2.3 Packer

Packer (by HashiCorp, the same company as Terraform) is the standard tool for baking AMIs. It:
- launches a temporary EC2 instance
- runs a series of configuration steps on it:
    - install software
    - apply security settings
    - remove unnecessary services
- takes a snapshot of it as a new AMI
- terminates the temporary instance


### 2.4 CIS Benchmarks

CIS stands for Center for Internet Security.
It is a non-profit organisation that publishes security best practices for:
- operating systems
- cloud platforms
- software.

CIS Benchmarks are detailed, prescriptive configuration guidelines — essentially a checklist of security settings that a system should comply with.

For example, for an AWS EC2 Linux instance:
- SSH root login disabled
- password authentication disabled (key pairs only)
- unused services and ports disabled
- audit logging enabled
- file permissions tightened on sensitive system files
- automatic security updates enabled

Benchmarks exist for AWS itself and most common operating systems, like:
- Amazon Linux
- Ubuntu
- Windows



## 3. Portfolio Positioning


### 3.1 What gaps does this project fill?

The existing portfolio covers:
- serverless compute (Lambda)
- containers (Fargate, Docker)
- full-stack web development (Flask, PostgreSQL)
- NoSQL (DynamoDB)
- AI/ML services (Bedrock)
- event-driven orchestration (Step Functions)
- disaster recovery (Route53 failover, cross-region
  RDS replication)
- infrastructure as code (Terraform)

What it does not cover:
- OS-level security configuration (CIS hardening)
- image management (Packer, AMI lifecycle)
- a fully visible security-scanning CI/CD pipeline (`tflint`, `checkov`)

GoldenPipeline fills all three in a single project.


### 3.2 Where does it sit in the portfolio?

GoldenPipeline is the fourth project in a series where each project introduces services and patterns not covered by the previous ones:

- **ManageEIPs** (three variants):
- EC2
- Lambda
- EventBridge
- SNS
- CLI
- SAM/CloudFormation
- Terraform

- **ITF Masters Tour**
- Fargate
- Docker
- RDS PostgreSQL
- Route53
- ALB
- VPC endpoints
- ACM
- cross-region replication

- **TerraDriftGuard**
- Step Functions
- Bedrock
- DynamoDB
- Config
- GitHub Actions
- Lambda

- **GoldenPipeline** 
- Packer
- CIS hardening
- `tflint`
- `checkov`

To sum it up, a full security-scanning CI/CD pipeline.


### 3.3 IaC discipline: lesson from TerraDriftGuard

In TerraDriftGuard, the security group and S3 bucket used to trigger drift events were created outside of Terraform.
They survived `terraform destroy` and had to be deleted manually — an IaC discipline failure documented in the README.

GoldenPipeline applies the lesson: 
every resource, including any test infrastructure used to validate the baked image, is managed by Terraform. 
No exceptions.



## 4. Cost Comparison


### 4.1 The three approaches to instance configuration

#### 4.1.1 Manual configuration

An engineer launches an instance and configures it by hand via SSH.

The cost is not in AWS spend; it is in engineer time.
Every new instance takes 15 to 30 minutes of manual work:
- the result is inconsistent
- there is no audit trail.

This is what most teams start with and what most teams eventually move away from.

#### 4.1.2 Bootstrapping at launch

The instance is configured at launch via:
- either user data scripts
- or a configuration management tool like `Ansible`.

The AWS cost is low, but there are drawbacks:
- a boot time penalty (10 to 15 minutes before the instance is production-ready)
- a dependency on package repositories being available at launch time
- a failure mode where a broken repository or network issue leaves a half-configured instance running in production

#### 4.1.3 The golden AMI

The instance launches from a pre-baked, pre-hardened image.
It is production-ready in under 2 minutes.

The AWS cost is essentially the same as bootstrapping (1 temporary instance during the Packer build).

The operational benefits come from:
- faster scaling
- consistent state across all instances
- reduced failure modes
- a smaller runtime attack surface


### 4.2 The NAT Gateway argument — and why it does not hold

A common justification for golden AMIs is the elimination of NAT Gateways. 
The reasoning goes: 
if instances no longer need to download packages at boot time, they no longer need outbound internet access, so the NAT Gateway can be removed.

This is technically true but misleading.
- VPC Endpoints provide private connectivity to AWS services without a NAT Gateway. 
- Bootstrapping via user data scripts that pull from S3 or AWS-hosted package repositories can work through VPC Endpoints at a fraction of the cost of a NAT Gateway.

The honest conclusion: 
- the golden AMI does not save significant money on AWS infrastructure. 
- What it saves is:
    - time
    - risk
    - operational complexity.
In a production environment, this translates to real cost, but not on the AWS bill.


### 4.3 Cost discipline for this project

GoldenPipeline is consistent with the previous projects in the portfolio (ITF Masters Tour at approximately $8, TerraDriftGuard at under $1).  
It is designed to be deployed briefly for demonstration and evidence collection, then destroyed.

The expected cost is minimal:
- 1 temporary EC2 instance during each Packer build (minutes, not hours)
- 1 test EC2 instance launched from the baked AMI for validation
- Terraform state stored locally (ephemeral deployment, single operator)

All resources are destroyed after evidence collection.



## 5. Packer Template Decisions
The `.pkr.hcl` file contains several choices that need design justification.

### 5.1 Base AMI: Amazon Linux 2023
The base AMI is Amazon Linux 2023, chosen over Ubuntu and Amazon Linux 2.  
Amazon Linux 2023 is the current generation of the AWS-native Linux distribution, with long-term support and tight integration with AWS services.

The selection is based on 4 factors:
- **CIS benchmark availability:**  
CIS publishes an official benchmark for Amazon Linux 2023.  
Ubuntu also has a well-established benchmark, but Amazon Linux 2 does not have a dedicated CIS benchmark for its latest releases.
It makes compliance verification less straightforward.

- **Package manager:**  
Amazon Linux 2023 uses `dnf`, which is the modern standard for RPM-based distributions.  
Amazon Linux 2 uses `yum`, which is functional but increasingly legacy.

- **AWS-native optimisation:** 
Amazon Linux 2023 is built and tested by AWS specifically for EC2.  
The following components are tuned for AWS infrastructure:
- the kernel
- default packages
- the boot process
Ubuntu runs well on EC2 but is a general-purpose distribution, not AWS-specific.

- **Long-term support:**  
Amazon Linux 2 reaches end of standard support in June 2025.  
Amazon Linux 2023 has support through 2028.  
Choosing a distribution approaching end of life for a new project would be a poor signal in a portfolio context.


### 5.2 Instance type: t3.micro
The `t3.micro` instance type is selected for the temporary Packer build instance.  
The reasoning is that Packer only needs enough compute to run shell scripts.  
The AMI itself is not tied to the instance type it was built on.


### 5.3 Region: us-east-1
The choice of us-east-1 reflects both cost (it is generally the cheapest AWS region) and portfolio consistency.
Indeed, all previous projects used the same region.


### 5.4 Manifest post-processor
The manifest post-processor is included in the Packer template to generate a JSON file containing the AMI ID after each build.  
It captures the AMI ID programmatically as an audit trail and evidence artifact.  
It ties directly to the IaC discipline principle from subsection 3.3.


### 5.5 Tagging strategy
The `Project = GoldenPipeline` tag is applied to every billable resource created by both Packer and Terraform.  
This connects to cost tracking via Cost Explorer.

The tag is applied at every level where AWS generates a billable resource:
- AMI (`tags` block)
- temporary build instance (`run_tags` block)
- EBS snapshot from AMI bake (`snapshot_tags` block)
- root EBS volume on the temporary build instance (`run_volume_tags` block)

On the Terraform side, the `default_tags` block in the provider configuration applies the tag to every resource.
The root EBS volume on the test EC2 instance requires explicit tags in the `root_block_device` block, as `default_tags` does not propagate to attached volumes.

However, Cost Explorer cannot filter by a tag until it is activated as a cost allocation tag in the AWS Billing console.
Activation takes up to 24 hours to propagate.
This must be completed before any deployment begins.


### 5.6 Provisioner execution order
The hardening scripts are ordered in a deliberate sequence:  
- updates first
- cleanup last

**Updates first:**  
Updates run first because package updates can overwrite configuration files.
If hardening scripts ran before updates, a subsequent package update could reset settings that were just tightened.

**Cleanup last:**  
Cleanup runs last because every preceding script generates:
- temporary files
- caches
- logs

Running cleanup at any earlier point would leave artefacts from later scripts in the final AMI.

**Scripts in between:**
The scripts in between are independent of each other and could run in any order:
- `harden_ssh.sh`
- `harden_filesystem.sh`
- `harden_services.sh`
- `harden_audit.sh`



## 6. Terraform Module Structure

### 6.1 Module boundaries
The Terraform configuration is split into 4 modules rather than a flat configuration:
- vpc/
- security_group/
- ec2/
- iam/

The reasoning is based on 3 principles:
- separation of concerns
- reusability
- readability of terraform state list output


### 6.2 Dependency chain
The order in which modules must be wired is the following: 
- VPC
- security group
- IAM
- EC2

Each module consumes outputs from the previous one.  
This mirrors the TerraDriftGuard pattern but is simpler (no circular dependency to work around).


### 6.3 AMI reference: from Packer manifest to Terraform
The baked AMI ID must flow from the Packer build output into the EC2 module.

This is the integration point between the two tools and a key design decision: 
data source lookup vs. variable injection vs. manifest parsing.

Indeed, the AMI ID produced by Packer needs to reach Terraform, so the EC2 module can launch an instance from it.  

There are 3 ways to achieve this:
- **Data source lookup:**  
    Terraform queries the AWS API at plan time using an `aws_ami` data source with filters (name prefix, tags).  
    It finds the most recent matching AMI automatically.  
    No manual step is required between Packer and Terraform.

- **Variable injection:**  
    The AMI ID is passed manually as a Terraform variable via `terraform.tfvars` or the command line.  
    This requires someone to copy the AMI ID from the Packer output and paste it into the Terraform configuration.

- **Manifest parsing:**  
    Packer writes the AMI ID to a JSON manifest file.  
    Terraform reads that file directly.  
    This avoids both the manual copy-paste and the API query, but creates a file dependency between the two tools.

GoldenPipeline uses the **data source lookup**.
The Packer template already tags the AMI with `Project = GoldenPipeline` and uses a consistent name prefix (`goldenpipeline-cis-`).
A Terraform `aws_ami` data source with `most_recent = true` is filtered on those values.
It resolves the correct AMI automatically at plan time.  
The manifest post-processor remains in the Packer template.
It serves as an audit trail and evidence artifact, not as a mechanism for Terraform to consume.


### 6.4 Local state
The Terraform state file is stored locally rather than in S3 because the deployment is ephemeral and operated by a single person.

Remote state in S3 solves 2 problems:
- **State locking**, which consists of preventing 2 people from running `terraform apply` simultaneously and corrupting the state file.  
- **Shared access**, which allows multiple team members to read and write the same state file

When only 1 person operates the infrastructure, neither problem exists.
Therefore, adding an S3 backend and a DynamoDB lock table would introduce unnecessary resources for a problem that does not apply.

The justification already exists in section 4.3:
- ephemeral deployment
- single operator


## 7. Testing Strategy

### 7.1 Why pytest
It is the standard Python testing framework.  
It runs the same way locally and in CI.  
There is no AWS-specific testing framework needed.


### 7.2 1-to-1 mapping between hardening scripts and test files
Each `harden_*.sh` has a corresponding `test_cis_*.py`.  
This makes coverage visible and gaps obvious.  
A failing test points directly to the script that produced the misconfiguration.


### 7.3 Validation method: `SSM` vs. `SSH`
Tests reach the running instance through `SSM` Session Manager to verify that hardening was applied.  
`SSM` Session Manager avoids opening `SSH` ports on the test instance as this would contradict the security hardening the project is demonstrating.  
This is a best-practice decision, not a convenience choice.


### 7.4 conftest.py and shared fixtures
The `SSM` connection is defined as a shared fixture in `conftest.py` because every test file needs the same connection to the running instance.
Duplicating it in each file would create a maintenance risk if the connection parameters changed.  
Standard `pytest` pattern for resource reuse.



## 8. CI/CD Pipeline Design

### 8.1 Workflow trigger
This documents which events trigger the pipeline:
- push to main
- pull request

The reasoning is as follows:
- A push to main triggers the full pipeline, including deployment.  
    Code that reaches main is considered ready for production.
- A pull request triggers only the validation steps without `terraform apply`.  
    The code is still under review at that stage.


### 8.2 Tool sequence and rationale
The tools run in this specific order for the following reasons:
- `terraform fmt` and `packer fmt` first (formatting before logic)
- `tflint` and `checkov` next (static analysis before deployment)
- `packer validate` (template validation before build)
- `terraform plan` (preview before apply)
- `terraform apply` last (deployment only after all gates pass)

The sequence is not arbitrary: each step acts as a gate for the next.


### 8.3 Failure behaviour
The pipeline stops at the first failure.  
There are no partial deployments.  
This is the core value proposition of the CI/CD pipeline as a quality gate (see section 1).


### 8.4 AWS credentials in CI
The pipeline requires authentication to AWS.

There are 2 approaches:
- GitHub Actions OIDC
- stored secrets

The choice between them is a security decision.
GoldenPipeline uses GitHub Actions OIDC:
- It is the AWS-recommended approach for GitHub Actions authentication
- It also aligns with the least-privilege principle applied throughout the project


### 8.5 Packer build in CI
The pipeline could either include `packer build` as an automated step or leave it as a separate manual step.
This is a deliberate choice with cost implications.
Running `packer build` on every push would launch a temporary EC2 instance each time.

Best practice is to include `packer build` in the pipeline, but with a path filter:
- The workflow only triggers the `Packer build` step when files inside the `packer/` directory have changed.
- A commit that only modifies Terraform code or documentation skips the AMI bake entirely.
- This achieves full automation without unnecessary EC2 cost.
- It is the standard approach in production pipelines that combine Packer and Terraform.

GoldenPipeline applies this pattern.






