terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}


# -------------------------------------------------
# Security Group (test EC2 instance)
# -------------------------------------------------

resource "aws_security_group" "this" {
  # checkov:skip=CKV2_AWS_5:False positive — SG is attached to EC2 instance via cross-module reference
  name        = "${var.project_name}-ec2-sg"
  description = "Security group for the test EC2 instance - no inbound, HTTPS to VPC only"
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS to VPC for SSM endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.project_name}-ec2-sg"
  }
}
