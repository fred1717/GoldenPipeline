output "instance_profile_name" {
  description = "Name of the IAM instance profile for the test instance"
  value       = aws_iam_instance_profile.this.name
}
