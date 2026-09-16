variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "aws_profile" {
  description = "Local CLI profile. GitHub Actions overrides with -var aws_profile=\"\" and uses OIDC credentials."
  type        = string
  default     = "hc-lab"
}

variable "asg_name" {
  description = "Also the value of the asg tag on every worker and in the Datadog monitors"
  type        = string
  default     = "boundary-workers"
}

variable "worker_iam_role_name" {
  description = "Must equal ../brokers var.worker_iam_role_name - Vault trusts this exact ARN"
  type        = string
  default     = "boundary-asg-worker"
}

variable "ami_ssm_parameter" {
  description = "SSM parameter the ami-build workflow writes the newest AMI id to"
  type        = string
  default     = "/boundary-worker/ami_id"
}

variable "datadog_api_key_ssm_parameter" {
  description = "SecureString SSM parameter holding the Datadog API key. Created by hand once (step 3 in the README); read by the instance at boot."
  type        = string
  default     = "/boundary-worker/datadog_api_key"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "asg_min_size" {
  type    = number
  default = 1
}

variable "asg_max_size" {
  type    = number
  default = 6
}

variable "lifecycle_hook_name" {
  type    = string
  default = "boundary-worker-deregister"
}

variable "hcp_boundary_cluster_id" {
  type    = string
  default = "95390bdc-e040-47df-8638-7c996c0f98f7"
}

variable "boundary_addr" {
  type    = string
  default = "https://95390bdc-e040-47df-8638-7c996c0f98f7.boundary.hashicorp.cloud"
}

variable "vault_addr" {
  description = "Vault as reachable FROM THE VPC. In-cluster Vault: the internal NLB. HCP Vault: the private endpoint over the HVN peering."
  type        = string
  default     = "http://aa837cd050a9d43028df5e6987267f93-d3fb677640c1fdfb.elb.ap-southeast-1.amazonaws.com:8200"
}

variable "datadog_site" {
  type    = string
  default = "datadoghq.com"
}
