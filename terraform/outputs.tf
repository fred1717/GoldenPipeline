output "instance_id" {
  description = "ID of the test EC2 instance, used by the CI/CD pipeline to run SSM validation commands"
  value       = module.ec2.instance_id
}
