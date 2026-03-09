output "instance_id" {
  description = "ID of the test EC2 instance, used by SSM to run validation commands"
  value       = aws_instance.this.id
}
