# -----------------------------------------------------------------------------
# Worker ASG: launch template, IAM role Vault trusts, security group,
# lifecycle hook. Reads VPC/EKS facts from ../../terraform state.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "hc-eks-vault-boundary"
      Component = "boundary-worker-asg"
      ManagedBy = "terraform"
    }
  }
}

# The base stack's outputs (vpc_id, private_subnet_ids, vpc_cidr_block).
data "terraform_remote_state" "base" {
  backend = "local"
  config = {
    path = "${path.module}/../../aws/terraform.tfstate"
  }
}

data "aws_caller_identity" "current" {}
