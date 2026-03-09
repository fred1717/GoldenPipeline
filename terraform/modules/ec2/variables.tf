variable "ami_id" {
  type        = string
  description = "AMI ID of the baked golden image"
}

variable "instance_type" {
  type        = string
  description = "Instance type for the test instance"
}

variable "subnet_id" {
  type        = string
  description = "ID of the private subnet"
}

variable "security_group_id" {
  type        = string
  description = "ID of the test instance security group"
}

variable "instance_profile_name" {
  type        = string
  description = "Name of the IAM instance profile"
}

variable "project_name" {
  type        = string
  description = "Project name used for resource naming"
}
