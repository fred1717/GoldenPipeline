variable "aws_region" {
  type        = string
  description = "AWS region for the test infrastructure"
  default     = "us-east-1"
}

variable "project_name" {
  type        = string
  description = "Project name used for resource naming and tagging"
  default     = "GoldenPipeline"
}

variable "instance_type" {
  type        = string
  description = "Instance type for the test EC2 instance"
  default     = "t3.micro"
}
