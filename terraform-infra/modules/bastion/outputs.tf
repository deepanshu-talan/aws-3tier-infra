output "bastion_instance_id" {
  description = "ID of the bastion host instance"
  value       = var.enable_bastion ? aws_instance.bastion[0].id : null
}

output "bastion_public_ip" {
  description = "Public IP of the bastion host"
  value       = var.enable_bastion ? aws_eip.bastion[0].public_ip : null
}

output "bastion_private_ip" {
  description = "Private IP of the bastion host"
  value       = var.enable_bastion ? aws_instance.bastion[0].private_ip : null
}
