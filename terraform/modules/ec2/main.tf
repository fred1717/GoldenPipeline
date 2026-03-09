# -------------------------------------------------
# Test EC2 Instance (launched from the baked AMI)
# -------------------------------------------------

resource "aws_instance" "this" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = var.instance_profile_name

  associate_public_ip_address = false

  # Tag the root EBS volume for Cost Explorer visibility
  root_block_device {
    tags = {
      Name    = "${var.project_name}-test-instance-root"
      Project = var.project_name
    }
  }

  # Instance tags
  tags = {
    Name = "${var.project_name}-test-instance"
  }
}
