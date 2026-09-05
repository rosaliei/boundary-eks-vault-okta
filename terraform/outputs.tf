# -----------------------------------------------------------------------------
# Outputs for downstream configurations (Vault, Boundary, kubectl)
# -----------------------------------------------------------------------------

# VPC Outputs
output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "IDs of private subnets (for Boundary worker deployment)"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = module.vpc.public_subnets
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs"
  value       = module.vpc.natgw_ids
}

# EKS Outputs
output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint (private)"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded CA certificate for the cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID attached to EKS worker nodes"
  value       = module.eks.node_security_group_id
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for the cluster (for Vault k8s auth)"
  value       = module.eks.cluster_oidc_issuer_url
}

output "cluster_oidc_provider_arn" {
  description = "ARN of the OIDC provider (for IAM roles for service accounts)"
  value       = module.eks.oidc_provider_arn
}

# Outputs for Boundary worker deployment
output "boundary_worker_subnet_id" {
  description = "Recommended subnet for Boundary worker (first private subnet)"
  value       = module.vpc.private_subnets[0]
}

output "boundary_worker_security_group_recommendation" {
  description = "Security group that allows access to EKS API"
  value       = "Create a security group allowing egress to ${module.eks.cluster_endpoint} on port 443"
}

# Helper output for kubeconfig generation
output "kubeconfig_command" {
  description = "AWS CLI command to update kubeconfig (requires VPC access)"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name} --profile pegb"
}

# -----------------------------------------------------------------------------
# Boundary Self-Managed Worker
# -----------------------------------------------------------------------------

output "boundary_worker_instance_id" {
  description = "Instance ID of the self-managed Boundary worker"
  value       = aws_instance.boundary_worker.id
}

output "boundary_worker_private_ip" {
  description = "Private IP of the self-managed Boundary worker"
  value       = aws_instance.boundary_worker.private_ip
}

output "boundary_worker_registration" {
  description = "Worker-led registration steps to run after apply"
  value       = <<-EOT
    # 1. Open a shell on the worker (private subnet, SSM only):
    aws ssm start-session --target ${aws_instance.boundary_worker.id} --region ${var.aws_region} --profile pegb

    # 2. On the instance, read the auth request token:
    sudo /usr/local/bin/worker-auth-token

    # 3. Back on your laptop, activate it against HCP Boundary:
    export BOUNDARY_ADDR=https://${var.boundary_cluster_id}.boundary.hashicorp.cloud
    # The name must be set here, not in worker.hcl - it is what the eks-api
    # target's egress_worker_filter matches on.
    boundary workers create worker-led \
      -name=${var.boundary_worker_name} \
      -description="Self-managed worker with line of sight to the private EKS endpoint" \
      -worker-generated-auth-token=<TOKEN>

    # 4. Confirm it is active:
    boundary workers list -format=json | jq '.items[] | {name, active_connection_count, release_version}'
  EOT
}
