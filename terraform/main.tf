# -------------------------------------------------
# Provider
# -------------------------------------------------

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = var.project_name
    }
  }
}


# -------------------------------------------------
# Data Source: resolve the most recent baked AMI
# -------------------------------------------------

data "aws_ami" "golden" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = ["goldenpipeline-cis-*"]
  }

  filter {
    name   = "tag:Project"
    values = ["GoldenPipeline"]
  }
}


# -------------------------------------------------
# Modules
# -------------------------------------------------

module "vpc" {
  source = "./modules/vpc"

  project_name = var.project_name
}

module "security_group" {
  source = "./modules/security_group"

  vpc_id       = module.vpc.vpc_id
  vpc_cidr     = module.vpc.vpc_cidr
  project_name = var.project_name
}

module "iam" {
  source = "./modules/iam"

  project_name = var.project_name
}

module "ec2" {
  source = "./modules/ec2"

  ami_id                = data.aws_ami.golden.id
  instance_type         = var.instance_type
  subnet_id             = module.vpc.subnet_id
  security_group_id     = module.security_group.security_group_id
  instance_profile_name = module.iam.instance_profile_name
  project_name          = var.project_name
}
