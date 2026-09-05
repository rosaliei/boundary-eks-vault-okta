# -----------------------------------------------------------------------------
# Boundary Configuration for EKS Access
#
# This configuration creates:
# - Managed groups on an EXISTING Okta OIDC auth method (var.okta_auth_method_id)
#   The auth method itself is managed by hand: Boundary never returns the Okta
#   client secret, so Terraform cannot own that resource without it being pasted in.
# - Roles with appropriate grants for viewer/operator/admin
# - Host catalog, host set, and target for EKS API access
#
# The target uses a worker_filter to route traffic through the self-managed
# Boundary worker deployed in the EKS VPC (required for private endpoint).
# -----------------------------------------------------------------------------

# =============================================================================
# PROJECT SCOPE
# =============================================================================

resource "boundary_scope" "project" {
  scope_id                 = var.org_scope_id
  name                     = var.project_name
  description              = var.project_description
  auto_create_admin_role   = true
  auto_create_default_role = false
}

# =============================================================================
# MANAGED GROUPS (Based on Okta Groups Claim)
# =============================================================================

# Viewer group - maps to Okta group for read-only access
resource "boundary_managed_group" "viewers" {
  auth_method_id = var.okta_auth_method_id
  name           = "viewers"
  description    = "Users with viewer access to EKS"

  # Filter matches users with the viewer group in their groups claim
  filter = "\"${var.okta_viewer_group}\" in \"/token/${var.okta_groups_claim}\" or \"${var.okta_viewer_group}\" in \"/userinfo/${var.okta_groups_claim}\""
}

# Operator group - maps to Okta group for operational access
resource "boundary_managed_group" "operators" {
  auth_method_id = var.okta_auth_method_id
  name           = "operators"
  description    = "Users with operator access to EKS"

  filter = "\"${var.okta_operator_group}\" in \"/token/${var.okta_groups_claim}\" or \"${var.okta_operator_group}\" in \"/userinfo/${var.okta_groups_claim}\""
}

# Admin group - maps to Okta group for full administrative access
resource "boundary_managed_group" "admins" {
  auth_method_id = var.okta_auth_method_id
  name           = "admins"
  description    = "Users with admin access to EKS"

  filter = "\"${var.okta_admin_group}\" in \"/token/${var.okta_groups_claim}\" or \"${var.okta_admin_group}\" in \"/userinfo/${var.okta_groups_claim}\""
}

# Fallback: match on the email claim instead of groups.
#
# Okta's org authorization server has not been emitting a groups claim for this
# app, so the group-based managed groups above resolve to nobody. Email is a
# claim it does send reliably. This keeps access identity-driven rather than
# pinning a Boundary user id, and can be dropped once groups arrive - the
# group-based managed group stays wired up in parallel.
resource "boundary_managed_group" "viewers_by_email" {
  auth_method_id = var.okta_auth_method_id
  name           = "viewers-by-email"
  description    = "Fallback for viewer access while the Okta groups claim is unavailable"

  filter = join(" or ", [for e in var.viewer_emails : "\"/token/email\" == \"${e}\""])
}

# =============================================================================
# ROLES AND GRANTS
# =============================================================================

# Viewer Role - can list and authorize sessions to targets
resource "boundary_role" "viewer" {
  scope_id      = boundary_scope.project.id
  name          = "viewer"
  description   = "Read-only access - can connect to EKS target"
  principal_ids = [boundary_managed_group.viewers.id]

  # Grants allow listing and authorizing sessions
  grant_strings = [
    # Only this tier's target. A wildcard here would let a viewer authorize
    # eks-api-admin and be handed an admin-tier Vault credential.
    "ids=${boundary_target.tier["viewer"].id};type=target;actions=list,no-op,authorize-session",
    "ids=*;type=session;actions=list,read:self,cancel:self",
  ]
}

# Operator Role - viewer permissions plus session management
resource "boundary_role" "operator" {
  scope_id      = boundary_scope.project.id
  name          = "operator"
  description   = "Operational access - can connect and manage own sessions"
  principal_ids = [boundary_managed_group.operators.id]

  grant_strings = [
    "ids=${boundary_target.tier["operator"].id};type=target;actions=list,no-op,read,authorize-session",
    "ids=*;type=session;actions=list,read:self,cancel:self",
    "ids=*;type=host-catalog;actions=list,no-op",
    "ids=*;type=host-set;actions=list,no-op",
    "ids=*;type=host;actions=list,no-op",
  ]
}

# Admin Role - full access to project resources
resource "boundary_role" "admin" {
  scope_id      = boundary_scope.project.id
  name          = "admin"
  description   = "Full administrative access to EKS project"
  principal_ids = [boundary_managed_group.admins.id]

  # Full access to all resources in the project scope
  grant_strings = [
    # Full target management
    "ids=*;type=target;actions=*",
    # Full session management
    "ids=*;type=session;actions=*",
    # Full host catalog management
    "ids=*;type=host-catalog;actions=*",
    "ids=*;type=host-set;actions=*",
    "ids=*;type=host;actions=*",
    # Credential management (for future expansion)
    "ids=*;type=credential-store;actions=*",
    "ids=*;type=credential-library;actions=*",
  ]
}

# =============================================================================
# HOST CATALOG AND TARGET
# =============================================================================

# Static host catalog for EKS API endpoint
resource "boundary_host_catalog_static" "eks" {
  scope_id    = boundary_scope.project.id
  name        = "eks-hosts"
  description = "EKS API endpoint host catalog"
}

# Host representing the EKS API endpoint
resource "boundary_host_static" "eks_api" {
  host_catalog_id = boundary_host_catalog_static.eks.id
  name            = "eks-api"
  description     = "EKS Kubernetes API endpoint"

  # Extract host from the full endpoint URL (removes https://)
  address = replace(replace(var.eks_api_endpoint, "https://", ""), "/", "")
}

# Host set containing the EKS API host
resource "boundary_host_set_static" "eks_api" {
  host_catalog_id = boundary_host_catalog_static.eks.id
  name            = "eks-api-hosts"
  description     = "Host set for EKS API access"
  host_ids        = [boundary_host_static.eks_api.id]
}

