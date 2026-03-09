packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}


# -------------------------------------------------
# Variables
# -------------------------------------------------

variable "aws_region" {
  type        = string
  description = "AWS region for the AMI build"
  default     = "us-east-1"
}

variable "instance_type" {
  type        = string
  description = "Instance type for the temporary build instance"
  default     = "t3.micro"
}

variable "ami_name_prefix" {
  type        = string
  description = "Prefix for the resulting AMI name"
  default     = "goldenpipeline-cis"
}

variable "manifest_output" {
  type        = string
  description = "Path to the Packer manifest file"
  default     = "manifest.json"
}


# -------------------------------------------------
# Source
# -------------------------------------------------

source "amazon-ebs" "golden_ami" {
  region        = var.aws_region
  instance_type = var.instance_type

  source_ami_filter {
    filters = {
      name                = "al2023-ami-*-x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  ssh_username = "ec2-user"

  ami_name = "${var.ami_name_prefix}-{{timestamp}}"

  tags = {
    Name    = "${var.ami_name_prefix}-{{timestamp}}"
    Project = "GoldenPipeline"
  }
  run_tags = {
    Name    = "${var.ami_name_prefix}-build"
    Project = "GoldenPipeline"
  }
  snapshot_tags = {
    Name    = "${var.ami_name_prefix}-{{timestamp}}"
    Project = "GoldenPipeline"
  }
  run_volume_tags = {
    Name    = "${var.ami_name_prefix}-build"
    Project = "GoldenPipeline"
  }
}


# -------------------------------------------------
# Build
# -------------------------------------------------

build {
  sources = ["source.amazon-ebs.golden_ami"]

  provisioner "shell" {
    scripts = [
      "harden_updates.sh",
      "harden_ssh.sh",
      "harden_filesystem.sh",
      "harden_services.sh",
      "harden_audit.sh",
      "cleanup.sh"
    ]
    execute_command = "sudo -S sh -c '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = var.manifest_output
    strip_path = true
  }
}
