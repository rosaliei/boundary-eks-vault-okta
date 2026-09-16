output "boundary_broker_user_ids" {
  description = "Boundary user ids of the two brokers"
  value       = { for k, u in boundary_user.broker : k => u.id }
}

output "vault_aws_auth_roles" {
  description = "Vault AWS-auth role names the EC2 scripts log in with"
  value       = { for k, r in vault_aws_auth_backend_role.broker : k => r.role }
}

output "vault_kv_paths" {
  description = "Where each broker's Boundary login lives in Vault"
  value       = { for k, s in vault_kv_secret_v2.broker : k => s.path }
}

output "trusted_iam_role_arn" {
  description = "IAM role ARN Vault trusts. ../terraform must create exactly this role."
  value       = "arn:aws:iam::${var.aws_account_id}:role/${var.worker_iam_role_name}"
}
