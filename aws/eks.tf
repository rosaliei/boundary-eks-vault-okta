# -----------------------------------------------------------------------------
# EKS Cluster using terraform-aws-modules/eks/aws v20+
#
# Key design decisions:
# - Private endpoint always on; public endpoint locked to admin IP (bootstrap/testing)
# - API authentication mode (access entries, not aws-auth configmap)
# - Spot instances for cost optimization in dev/test
# - Self-managed Boundary worker will be deployed in this VPC for access
# -----------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # VPC Configuration
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Private endpoint only. Flipped false on 2026-09-23, which is the point of
  # the whole build: with a public endpoint reachable, HCP's own managed workers
  # can serve sessions directly and the self-managed pool is bypassed - its
  # proxy counters stay at 0, so `boundary.worker.active_sessions` never moves
  # and the autoscaling loop has no input. Private-only forces every session
  # through a worker inside the VPC.
  #
  # Re-enable with the AWS API (never needs cluster access, so this cannot lock
  # you out):
  #   aws eks update-cluster-config --name hc-eks-cluster \
  #     --resources-vpc-config publicAccessCidrs=<ip>/32,endpointPublicAccess=true,endpointPrivateAccess=true
  cluster_endpoint_public_access       = false
  cluster_endpoint_public_access_cidrs = var.admin_public_cidrs
  cluster_endpoint_private_access      = true

  # Authentication mode: API-based access entries (modern approach)
  # This replaces the legacy aws-auth ConfigMap method
  authentication_mode = "API"

  # Enable cluster creator admin permissions
  # This allows the IAM entity running Terraform to manage the cluster
  enable_cluster_creator_admin_permissions = true

  # Cluster addons - essential components
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  # Managed node group configuration
  eks_managed_node_groups = {
    primary = {
      name           = "${var.cluster_name}-primary-ng"
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      # Amazon Linux 2 AMIs are gone from EKS 1.33+; AL2023 is the current standard
      ami_type = "AL2023_x86_64_STANDARD"

      # The module derives the node IAM role from name_prefix "<name>-eks-node-group-",
      # which exceeds the 38-char name_prefix limit. Pin an explicit short role name.
      iam_role_name            = "${var.cluster_name}-primary-ng"
      iam_role_use_name_prefix = false

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Use private subnets for worker nodes
      subnet_ids = module.vpc.private_subnets

      # Labels for workload scheduling
      labels = {
        Environment = var.environment
        NodeGroup   = "primary"
      }

      tags = {
        Environment = var.environment
        NodeGroup   = "primary"
      }
    }
  }

  # Cluster security group additional rules
  # Allow inbound from Boundary worker (will be in same VPC)
  cluster_security_group_additional_rules = {
    ingress_boundary_worker = {
      description = "Allow HTTPS from VPC CIDR (for Boundary worker)"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}
