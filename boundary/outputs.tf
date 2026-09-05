# -----------------------------------------------------------------------------
# Outputs for Boundary Configuration
# -----------------------------------------------------------------------------

output "project_scope_id" {
  description = "Boundary project scope ID"
  value       = boundary_scope.project.id
}

output "oidc_auth_method_id" {
  description = "OIDC auth method the managed groups are attached to (existing, not managed here)"
  value       = var.okta_auth_method_id
}

output "target_ids" {
  description = "EKS API target IDs, one per tier"
  value       = { for k, t in boundary_target.tier : k => t.id }
}



# Managed group IDs
output "viewer_group_id" {
  description = "Managed group ID for viewers"
  value       = boundary_managed_group.viewers.id
}

output "operator_group_id" {
  description = "Managed group ID for operators"
  value       = boundary_managed_group.operators.id
}

output "admin_group_id" {
  description = "Managed group ID for admins"
  value       = boundary_managed_group.admins.id
}

# Connection information
output "connection_info" {
  description = "Information for connecting to EKS via Boundary"
  value       = <<-EOT
    # Connect to EKS. The tier you may authorize is decided by your Okta group.
    boundary connect -target-id ${boundary_target.tier["viewer"].id} -format=json

    # The session returns BOTH a local proxy port and a brokered 15-minute
    # ServiceAccount token from Vault - no vault command, no port-forward.
  EOT
}
