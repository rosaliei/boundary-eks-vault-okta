# -----------------------------------------------------------------------------
# Vault Kubernetes Secrets Engine Configuration
#
# This configuration enables the Kubernetes secrets engine and creates roles
# that map 1:1 to the ServiceAccounts defined in k8s/rbac.yaml.
#
# When users request credentials from these roles, Vault will generate
# short-lived ServiceAccount tokens (default 15 min, max 1 hour).
# -----------------------------------------------------------------------------

# =============================================================================
# KUBERNETES SECRETS ENGINE
# =============================================================================

# Enable the Kubernetes secrets engine at path "kubernetes/"
resource "vault_mount" "kubernetes" {
  path        = "kubernetes"
  type        = "kubernetes"
  description = "Kubernetes secrets engine for dynamic EKS credentials"

  default_lease_ttl_seconds = var.default_ttl_seconds
  max_lease_ttl_seconds     = var.max_ttl_seconds
}

# Configure the secrets engine with Kubernetes API access
resource "vault_kubernetes_secret_backend" "config" {
  path                 = vault_mount.kubernetes.path
  kubernetes_host      = var.kubernetes_host
  kubernetes_ca_cert   = var.kubernetes_ca_cert
  service_account_jwt  = var.vault_sa_jwt_token
  disable_local_ca_jwt = true
}

# =============================================================================
# VAULT ROLES - Map to Kubernetes ServiceAccounts
# =============================================================================

# -----------------------------------------------------------------------------
# Viewer Role
# Grants read-only access to demo-app namespace
# -----------------------------------------------------------------------------
resource "vault_kubernetes_secret_backend_role" "viewer" {
  backend                       = vault_mount.kubernetes.path
  name                          = "viewer"
  allowed_kubernetes_namespaces = [var.kubernetes_namespace]

  # Use existing ServiceAccount (created by k8s/rbac.yaml)
  service_account_name = "vault-viewer"

  # Token TTL configuration
  token_default_ttl = var.default_ttl_seconds
  token_max_ttl     = var.max_ttl_seconds

  depends_on = [vault_kubernetes_secret_backend.config]
}

# -----------------------------------------------------------------------------
# Operator Role
# Grants standard operational access to demo-app namespace
# -----------------------------------------------------------------------------
resource "vault_kubernetes_secret_backend_role" "operator" {
  backend                       = vault_mount.kubernetes.path
  name                          = "operator"
  allowed_kubernetes_namespaces = [var.kubernetes_namespace]

  # Use existing ServiceAccount (created by k8s/rbac.yaml)
  service_account_name = "vault-operator"

  # Token TTL configuration
  token_default_ttl = var.default_ttl_seconds
  token_max_ttl     = var.max_ttl_seconds

  depends_on = [vault_kubernetes_secret_backend.config]
}

# -----------------------------------------------------------------------------
# Admin Role
# Grants full administrative access to demo-app namespace
# -----------------------------------------------------------------------------
resource "vault_kubernetes_secret_backend_role" "admin" {
  backend                       = vault_mount.kubernetes.path
  name                          = "admin"
  allowed_kubernetes_namespaces = [var.kubernetes_namespace]

  # Use existing ServiceAccount (created by k8s/rbac.yaml)
  service_account_name = "vault-admin"

  # Token TTL configuration
  token_default_ttl = var.default_ttl_seconds
  token_max_ttl     = var.max_ttl_seconds

  depends_on = [vault_kubernetes_secret_backend.config]
}
