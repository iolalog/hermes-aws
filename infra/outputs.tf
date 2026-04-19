output "aws_region" {
  description = "AWS region of the deployment"
  value       = var.aws_region
}

output "public_ip" {
  description = "Static public IP address of the EC2 instance"
  value       = aws_eip.hermes.public_ip
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.hermes.id
}

output "instance_role_arn" {
  description = "ARN of the EC2 instance role"
  value       = aws_iam_role.hermes.arn
}

# Connect via SSM Session Manager (no SSH needed):
# aws ssm start-session --target <instance_id>
