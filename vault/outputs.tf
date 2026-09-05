# -----------------------------------------------------------------------------
# Outputs for Vault Kubernetes Secrets Engine
# -----------------------------------------------------------------------------

output "kubernetes_secrets_engine_path" {
  description = "Path where the Kubernetes secrets engine is mounted"
  value       = vault_mount.kubernetes.path
}

output "viewer_role_path" {
  description = "Full path to request viewer credentials"
  value       = "${vault_mount.kubernetes.path}/creds/viewer"
}

output "operator_role_path" {
  description = "Full path to request operator credentials"
  value       = "${vault_mount.kubernetes.path}/creds/operator"
}

output "admin_role_path" {
  description = "Full path to request admin credentials"
  value       = "${vault_mount.kubernetes.path}/creds/admin"
}

# Usage hints
output "usage_example" {
  description = "Example commands to retrieve credentials"
  value       = <<-EOT
    # Retrieve viewer credentials:
    vault read kubernetes/creds/viewer kubernetes_namespace=demo-app

    # Retrieve operator credentials:
    vault read kubernetes/creds/operator kubernetes_namespace=demo-app

    # Retrieve admin credentials:
    vault read kubernetes/creds/admin kubernetes_namespace=demo-app
  EOT
}
