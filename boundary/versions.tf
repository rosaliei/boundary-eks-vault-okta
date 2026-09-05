# -----------------------------------------------------------------------------
# Provider and Terraform version constraints for Boundary configuration
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    boundary = {
      source  = "hashicorp/boundary"
      version = "~> 1.0"
    }
  }
}

# Provider configuration for HCP Boundary
# Uses the HCP Boundary cluster specified in the architecture
provider "boundary" {
  addr                   = var.boundary_addr
  auth_method_id         = var.boundary_auth_method_id
  auth_method_login_name = var.boundary_auth_method_login_name
  auth_method_password   = var.boundary_auth_method_password
}
