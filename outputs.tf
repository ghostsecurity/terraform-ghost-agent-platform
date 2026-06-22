output "bringup_url" {
  description = "Public URL of the deployment. Open this in a browser to reach the UI."
  value       = "https://${local.bringup_domain}"
}

output "bringup_domain" {
  description = "Public hostname of the deployment (either var.domain_name or <dashed-eip>.nip.io)."
  value       = local.bringup_domain
}

output "elastic_ip" {
  description = "Elastic IP address. Useful for setting up a DNS A record out-of-band when var.route53_zone_id is left empty."
  value       = aws_eip.this.public_ip
}

output "ssh_command" {
  description = "Suggested SSH command — assumes ec2-user and a key matching var.ssh_key_name. Uses the Elastic IP directly so connectivity is independent of DNS state (nip.io propagation, Route 53 lag, etc.)."
  value       = "ssh ec2-user@${aws_eip.this.public_ip}"
}

output "ssm_session_command" {
  description = "AWS Systems Manager Session Manager command — alternative to SSH, works without an EC2 key pair (the instance role grants the necessary SSM permissions)."
  value       = "aws ssm start-session --region ${local.aws_region} --target ${aws_instance.vm.id}"
}

output "ssm_support_role_arn" {
  description = "ARN of the cross-account SSM support role Ghost Security assumes to open a Session Manager shell on the VM. Empty when ghost_support_access_enabled is false."
  value       = local.ghost_support_enabled ? aws_iam_role.ssm_support[0].arn : ""
}

output "instance_id" {
  description = "EC2 instance ID. Useful for ops commands (SSM, EBS attach/detach, console output retrieval)."
  value       = aws_instance.vm.id
}

output "data_volume_snapshot_policy_arn" {
  description = "ARN of the Data Lifecycle Manager policy taking scheduled snapshots of the data volume. Empty when enable_data_volume_snapshots is false."
  value       = var.enable_data_volume_snapshots ? aws_dlm_lifecycle_policy.data[0].arn : ""
}

output "secret_arns" {
  description = "ARNs of the Secrets Manager secrets created by this module. The seed admin password in particular is auto-generated — retrieve it via `aws secretsmanager get-secret-value --secret-id <arn>` for first login."
  value = {
    jwt_secret          = aws_secretsmanager_secret.jwt.arn
    encryption_key      = aws_secretsmanager_secret.encryption_key.arn
    seed_admin_password = aws_secretsmanager_secret.seed_admin_password.arn
    slack               = aws_secretsmanager_secret.slack.arn
  }
}
