# -----------------------------------------------------------------------------
# Variables for Vault Kubernetes Secrets Engine Configuration
# -----------------------------------------------------------------------------

variable "vault_address" {
  description = "Vault server address (can also use VAULT_ADDR env var)"
  type        = string
  default     = ""
}

variable "kubernetes_host" {
  description = "Kubernetes API server URL (from EKS output: cluster_endpoint)"
  type        = string
}

variable "kubernetes_ca_cert" {
  description = "Base64-decoded Kubernetes CA certificate (from EKS output: cluster_certificate_authority_data)"
  type        = string
  sensitive   = true
}

variable "vault_sa_jwt_token" {
  description = "Service account JWT token for Vault to authenticate to Kubernetes"
  type        = string
  sensitive   = true
}

variable "kubernetes_namespace" {
  description = "Kubernetes namespace where ServiceAccounts are created"
  type        = string
  default     = "demo-app"
}

# TTL Configuration
variable "default_ttl_seconds" {
  description = "Default TTL for generated credentials (in seconds)"
  type        = number
  default     = 900 # 15 minutes
}

variable "max_ttl_seconds" {
  description = "Maximum TTL for generated credentials (in seconds)"
  type        = number
  default     = 3600 # 1 hour
}
