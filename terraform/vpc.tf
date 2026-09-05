# -----------------------------------------------------------------------------
# VPC Configuration using terraform-aws-modules/vpc/aws
# Creates VPC with public/private subnets, NAT gateways, and proper tagging
# for EKS subnet discovery.
# -----------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  # NAT Gateway for private subnet internet access
  # Single NAT gateway is cost-effective for dev/test; use one_nat_gateway_per_az for prod
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  # DNS settings required for EKS and service discovery
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags required for EKS subnet discovery
  # Private subnets: for internal load balancers and worker nodes
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  # Public subnets: for external load balancers (if needed)
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  tags = {
    Terraform   = "true"
    Environment = var.environment
    Project     = var.project_name
  }
}
