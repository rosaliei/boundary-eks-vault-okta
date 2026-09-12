# -----------------------------------------------------------------------------
# Variables for AWS Infrastructure (VPC + EKS)
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "hc-eks-vault-boundary"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "dev"
}

# -----------------------------------------------------------------------------
# VPC Configuration
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to use (minimum 2 for EKS)"
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

# -----------------------------------------------------------------------------
# EKS Configuration
# -----------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "hc-eks-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster (must be in EKS standard support; 1.29/1.30 are end-of-life and rejected by CreateCluster)"
  type        = string
  default     = "1.35"
}

variable "node_instance_types" {
  description = "Instance types for EKS managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Desired number of nodes in the managed node group"
  type        = number
  default     = 1
}

variable "node_min_size" {
  description = "Minimum number of nodes in the managed node group"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of nodes in the managed node group"
  type        = number
  default     = 2
}

variable "node_capacity_type" {
  description = "Capacity type for nodes: ON_DEMAND or SPOT"
  type        = string
  default     = "SPOT"
}

# -----------------------------------------------------------------------------
# Access Entry Configuration (for initial admin access)
# -----------------------------------------------------------------------------

variable "admin_iam_role_arn" {
  description = "IAM role ARN to grant cluster admin access via access entries"
  type        = string
  default     = ""
}

variable "admin_iam_user_arn" {
  description = "IAM user ARN to grant cluster admin access via access entries"
  type        = string
  default     = ""
}

variable "admin_public_cidrs" {
  description = "CIDRs allowed to reach the EKS public endpoint (bootstrap/testing only; set to your current IP /32). Flip cluster_endpoint_public_access to false once Boundary + Vault are wired."
  type        = list(string)
  default     = ["92.98.212.193/32"]
}

# -----------------------------------------------------------------------------
# Boundary Self-Managed Worker
# -----------------------------------------------------------------------------

variable "boundary_cluster_id" {
  description = "HCP Boundary cluster UUID (the first label of the cluster hostname). The worker uses this to discover its upstream, so no initial_upstreams is needed."
  type        = string
  default     = "95390bdc-e040-47df-8638-7c996c0f98f7"
}

variable "boundary_worker_name" {
  description = "Name the worker registers under. Must match the egress_worker_filter on the eks-api target in ../boundary."
  type        = string
  default     = "kst-eks-ap-southeast-1-worker-01"
}

variable "boundary_worker_instance_type" {
  description = "Instance type for the Boundary worker. The worker is a lightweight TCP proxy; t3.micro is ample."
  type        = string
  default     = "t3.micro"
}

variable "boundary_version" {
  description = "Boundary Enterprise version installed on the self-managed worker. Must not exceed the HCP controller version - a newer worker fails node enrollment with 'tls: internal error' / 'empty nonce'. HCP self-managed workers require the +ent build. Installed from the release archive, not the RPM repo - see boundary-worker.tf for why."
  type        = string
  default     = "1.0.1+ent"
}

variable "boundary_sha256" {
  description = "SHA256 of boundary_<version>_linux_amd64.zip, from the published SHA256SUMS. Must be updated together with boundary_version."
  type        = string
  default     = "f74035e77cc4dab5c7f0f4c1fd886489ed6c8c6f928a456dea60f9424fec20bd"
}
