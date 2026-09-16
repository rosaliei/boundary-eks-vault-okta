# -----------------------------------------------------------------------------
# Broker identities: Boundary (who may create / delete workers) and Vault
# (how an EC2 worker proves who it is and fetches the matching password).
#
# One root module on purpose: the passwords are generated here and written
# to Vault KV in the same apply. They never appear in a tfvars file or a
# terminal. Rotation is `terraform apply -replace=random_password.<x>`.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    boundary = {
      source  = "hashicorp/boundary"
      version = "~> 1.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "boundary" {
  addr                   = var.boundary_addr
  auth_method_id         = var.boundary_auth_method_id
  auth_method_login_name = var.boundary_admin_login_name
  auth_method_password   = var.boundary_admin_password
}

# VAULT_ADDR / VAULT_TOKEN from the environment, same as ../../vault.
# From a laptop that means `kubectl -n vault port-forward svc/vault 8200:8200`.
provider "vault" {}
