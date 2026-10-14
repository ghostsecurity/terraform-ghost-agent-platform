output "url" {
  description = "Public URL of the deployment. Open it, enter the claim_token, and create the first admin."
  value       = "https://${var.domain_name}"
}

output "claim_token" {
  description = "One-time claim token for the setup wizard. Inert once the first admin exists. Retrieve with `terraform output -raw claim_token`."
  value       = random_id.claim_token.hex
  sensitive   = true
}

output "load_balancer_hostname" {
  description = "DNS name of the load balancer. Point domain_name at it when route53_zone_id is empty. Empty when manage_release is false."
  value       = var.manage_release ? kubernetes_ingress_v1.this[0].status[0].load_balancer[0].ingress[0].hostname : ""
}

output "certificate_arn" {
  description = "ARN of the certificate for domain_name: acm_certificate_arn, or the one the module requested. Use it in your own Ingress when manage_release is false."
  value       = local.certificate_arn
}

output "namespace" {
  description = "Namespace the platform runs in."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "release_name" {
  description = "Helm release name."
  value       = var.release_name
}

output "helm_chart" {
  description = "Chart reference and version to install when manage_release is false."
  value = {
    repository = "oci://${var.image_registry}"
    chart      = "exo-helmchart"
    version    = local.chart_version
  }
}

output "helm_values" {
  description = "Helm values (YAML) that wire the release to what this module created: storage classes, secrets, fixed Service addresses, node placement, and email. The module installs with them; when manage_release is false, install the chart with them yourself, adding your own ingress values."
  value       = yamlencode(local.release_values)
}

output "credential_proxy_cluster_ip" {
  description = "Fixed cluster IP of the credential-proxy Service, the DNS server of worker pods."
  value       = local.credential_proxy_ip
}

output "gateway_cluster_ip" {
  description = "Fixed cluster IP of the gateway Service."
  value       = local.gateway_ip
}

output "ui_cluster_ip" {
  description = "Fixed cluster IP of the exo-ui Service, the destination of the Ghost support UI session."
  value       = local.ui_ip
}

output "encryption_key_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the credential encryption key."
  value       = aws_secretsmanager_secret.encryption_key.arn
}

output "efs_file_system_ids" {
  description = "IDs of the private (keys and certificates) and shared (artifacts, public certificates, runner identities) EFS file systems."
  value = {
    private = aws_efs_file_system.private.id
    shared  = aws_efs_file_system.shared.id
  }
}

output "database_snapshot_policy_arn" {
  description = "ARN of the Data Lifecycle Manager policy taking daily snapshots of the database volume. Empty when enable_database_snapshots is false."
  value       = var.enable_database_snapshots ? aws_dlm_lifecycle_policy.database[0].arn : ""
}

output "iam_role_arns" {
  description = "ARNs of the IAM roles the platform's pods assume through EKS Pod Identity. gateway is empty unless enable_ses_email is true."
  value = {
    updater = aws_iam_role.updater.arn
    gateway = var.enable_ses_email ? aws_iam_role.gateway[0].arn : ""
  }
}

output "ghost_support_role_arn" {
  description = "ARN of the role Ghost Security assumes for support. Empty when ghost_support_access_enabled is false."
  value       = local.ghost_support_enabled ? aws_iam_role.ghost_support[0].arn : ""
}

output "ghost_support_session_documents" {
  description = "Session Manager documents the support role may use: port forwarding to the UI and to the cluster's API endpoint. Empty names when ghost_support_access_enabled is false."
  value = {
    ui  = local.ghost_support_enabled ? aws_ssm_document.ghost_support_ui[0].name : ""
    api = local.ghost_support_enabled ? aws_ssm_document.ghost_support_api[0].name : ""
  }
}

output "port_forward_command" {
  description = "Reaches the UI at http://localhost:8080 without the load balancer, for example before DNS resolves."
  value       = "kubectl -n ${kubernetes_namespace_v1.this.metadata[0].name} port-forward svc/exo-ui 8080:8080"
}

output "helm_test_command" {
  description = "Runs the chart's tests: the platform's health, and that workers reach the internet only through the credential proxy."
  value       = "helm test ${var.release_name} -n ${kubernetes_namespace_v1.this.metadata[0].name}"
}
