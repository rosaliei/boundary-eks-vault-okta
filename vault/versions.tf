# -----------------------------------------------------------------------------
# Provider and Terraform version constraints for Vault configuration
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# Provider configuration
# VAULT_ADDR and VAULT_TOKEN should be set via environment variables
provider "vault" {
  # address = var.vault_address  # Or use VAULT_ADDR env var
  # token   = var.vault_token    # Or use VAULT_TOKEN env var (recommended)
}
