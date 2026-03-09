output "security_group_id" {
  description = "ID of the test instance security group"
  value       = aws_security_group.this.id
}
