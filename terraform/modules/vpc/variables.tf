variable "project_name" {
  type        = string
  description = "Project name used for resource naming"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/24"
}

variable "subnet_cidr" {
  type        = string
  description = "CIDR block for the private subnet"
  default     = "10.0.0.0/28"
}

variable "availability_zone" {
  type        = string
  description = "Availability zone for the private subnet"
  default     = "us-east-1a"
}
