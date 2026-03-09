variable "vpc_id" {
  type        = string
  description = "ID of the VPC"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block of the VPC, used to restrict egress to SSM endpoints"
}

variable "project_name" {
  type        = string
  description = "Project name used for resource naming"
}
