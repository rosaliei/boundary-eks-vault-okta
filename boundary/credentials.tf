# -----------------------------------------------------------------------------
# Vault credential brokering
#
# Instead of the operator running `vault write kubernetes/creds/<role>` by hand
# (which today requires a port-forward, and therefore admin cluster access),
# Boundary fetches the credential itself when a session is authorized and hands
# it to the user alongside the session.
#
# Requires network reachability that a ClusterIP service cannot provide - see
# var.vault_address. Boundary reaches Vault through the self-managed worker
# rather than from the HCP control plane, which has no route into the VPC.
# -----------------------------------------------------------------------------

resource "boundary_credential_store_vault" "vault" {
  name        = "vault"
  description = "Vault kubernetes secrets engine, reached through the in-VPC worker"
  scope_id    = boundary_scope.project.id

  address = var.vault_address
  token   = var.vault_boundary_token

  # Vault is private. Without this the HCP controller tries to reach it directly
  # and the credential store fails to validate on create.
  worker_filter = var.boundary_worker_filter
}

# The Kubernetes secrets engine is written to, not read from, and it requires a
# namespace in the request body - hence POST with an explicit body rather than
# the default GET a credential library would otherwise issue.
resource "boundary_credential_library_vault" "tier" {
  for_each = toset(["viewer", "operator", "admin"])

  name                = "k8s-${each.key}"
  description         = "Short-lived ServiceAccount token for the ${each.key} tier"
  credential_store_id = boundary_credential_store_vault.vault.id

  path              = "kubernetes/creds/${each.key}"
  http_method       = "POST"
  http_request_body = jsonencode({ kubernetes_namespace = var.kubernetes_namespace })
}

# -----------------------------------------------------------------------------
# One target per tier
#
# The tier a user gets is decided by which target their role lets them
# authorize - not by anything they type. An eks-viewers member can only
# authorize eks-api-viewer, so they can only ever receive a viewer credential.
# This is the enforcement that is missing while credentials are fetched by hand.
# -----------------------------------------------------------------------------

resource "boundary_target" "tier" {
  for_each = toset(["viewer", "operator", "admin"])

  scope_id     = boundary_scope.project.id
  type         = "tcp"
  name         = "eks-api-${each.key}"
  description  = "EKS API with a brokered ${each.key} credential"
  default_port = 443

  egress_worker_filter = var.boundary_worker_filter
  host_source_ids      = [boundary_host_set_static.eks_api.id]

  brokered_credential_source_ids = [boundary_credential_library_vault.tier[each.key].id]

  session_max_seconds      = 28800
  session_connection_limit = -1
}
