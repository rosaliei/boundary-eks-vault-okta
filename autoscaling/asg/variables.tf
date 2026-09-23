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
  # NOT t3.micro. 1 GiB is not enough for the Boundary worker (~470 MiB RSS plus
  # two plugin processes) alongside the Datadog agent (agent + trace-loader +
  # agent-data-plane + system-probe). The kernel OOM-kills `boundary`, systemd
  # restarts it every 5 s, and that loop burns the burst credits until the SSM
  # agent is starved too - so the box also stops being reachable for debugging.
  # Measured 2026-09-23; see notes/Issues.md.
  type    = string
  default = "t3.small"
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

variable "client_cidrs" {
  description = <<-DESC
    CIDRs allowed to reach the worker's proxy port 9202 directly. This is what
    makes a worker an INGRESS worker: without direct client reachability the
    session takes the multi-hop reverse connection, which Boundary does not
    instrument, so active_session_count stays 0 and nothing can autoscale.
    Keep it tight - it is the only thing between the internet and the proxy.
  DESC
  type        = list(string)
  default     = ["217.165.139.151/32", "92.98.212.193/32"]
}
