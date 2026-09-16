# =============================================================================
# BOUNDARY - two broker identities, one verb each
#
# Workers are global-scope resources, so the users, accounts and roles all live
# in the global scope. Neither role can list targets, read sessions or see the
# other broker's password.
# =============================================================================

locals {
  brokers = {
    registrar = {
      description = "May only create controller-led workers. Used by an EC2 worker at boot."
      grants = [
        "type=worker;actions=create:controller-led",
      ]
    }
    deregistrar = {
      description = "May only delete workers. Used by an EC2 worker at ASG termination."
      grants = [
        "ids=*;type=worker;actions=delete",
      ]
    }
  }
}

resource "random_password" "broker" {
  for_each = local.brokers
  length   = 32
  special  = false
}

resource "boundary_account_password" "broker" {
  for_each       = local.brokers
  auth_method_id = var.boundary_auth_method_id
  login_name     = "worker-${each.key}"
  description    = each.value.description
  password       = random_password.broker[each.key].result
}

resource "boundary_user" "broker" {
  for_each    = local.brokers
  scope_id    = "global"
  name        = "worker-${each.key}"
  description = each.value.description
  account_ids = [boundary_account_password.broker[each.key].id]
}

resource "boundary_role" "broker" {
  for_each        = local.brokers
  scope_id        = "global"
  name            = "worker-${each.key}"
  description     = each.value.description
  principal_ids   = [boundary_user.broker[each.key].id]
  grant_scope_ids = ["this"]
  grant_strings   = each.value.grants
}

# =============================================================================
# VAULT - AWS IAM auth. An EC2 instance proves who it is by signing an STS
# GetCallerIdentity request with its instance-profile credentials. No secret is
# ever placed on the instance.
# =============================================================================

resource "vault_auth_backend" "aws" {
  type = "aws"
  path = var.vault_aws_auth_path
}

# resolve_aws_unique_ids=false means Vault compares the role ARN as a string
# and never needs iam:GetRole - so the in-cluster Vault needs no AWS
# credentials at all, and the role may be created after this apply.
resource "vault_aws_auth_backend_role" "broker" {
  for_each = local.brokers

  backend                  = vault_auth_backend.aws.path
  role                     = "boundary-worker-${each.key == "registrar" ? "register" : "deregister"}"
  auth_type                = "iam"
  bound_iam_principal_arns = ["arn:aws:iam::${var.aws_account_id}:role/${var.worker_iam_role_name}"]
  resolve_aws_unique_ids   = false

  token_policies = [vault_policy.broker[each.key].name]
  token_ttl      = var.vault_token_ttl_seconds
  token_max_ttl  = var.vault_token_ttl_seconds
}

resource "vault_policy" "broker" {
  for_each = local.brokers
  name     = "boundary-worker-${each.key}"

  policy = <<-EOT
    path "${var.vault_kv_mount}/data/boundary/${each.key}" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kv_secret_v2" "broker" {
  for_each = local.brokers
  mount    = var.vault_kv_mount
  name     = "boundary/${each.key}"

  data_json = jsonencode({
    boundary_addr  = var.boundary_addr
    auth_method_id = var.boundary_auth_method_id
    login_name     = boundary_account_password.broker[each.key].login_name
    password       = random_password.broker[each.key].result
  })
}
