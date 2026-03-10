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
# IAM Role (test EC2 instance)
# -------------------------------------------------

resource "aws_iam_role" "this" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ec2-role"
  }
}


# -------------------------------------------------
# SSM Managed Policy Attachment
# -------------------------------------------------

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}


# -------------------------------------------------
# Instance Profile
# -------------------------------------------------

resource "aws_iam_instance_profile" "this" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.this.name

  tags = {
    Name = "${var.project_name}-ec2-profile"
  }
}
