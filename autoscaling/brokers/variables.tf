variable "boundary_addr" {
  description = "HCP Boundary cluster address"
  type        = string
  default     = "https://95390bdc-e040-47df-8638-7c996c0f98f7.boundary.hashicorp.cloud"
}

variable "boundary_auth_method_id" {
  description = "Global-scope password auth method. Both the admin used to apply this and the two broker accounts live on it."
  type        = string
}

variable "boundary_admin_login_name" {
  description = "Admin login used only to apply this module"
  type        = string
  sensitive   = true
}

variable "boundary_admin_password" {
  description = "Admin password used only to apply this module"
  type        = string
  sensitive   = true
}

variable "aws_account_id" {
  description = "Account that owns the worker ASG. Used to build the IAM role ARN Vault will trust - the role itself is created later in ../terraform, and with resolve_aws_unique_ids=false Vault matches on the ARN string, so it need not exist yet."
  type        = string
}

variable "worker_iam_role_name" {
  description = "IAM role name the ASG workers run as. Must match ../terraform var.worker_iam_role_name."
  type        = string
  default     = "boundary-asg-worker"
}

variable "vault_aws_auth_path" {
  description = "Mount path for the AWS auth method"
  type        = string
  default     = "aws"
}

variable "vault_kv_mount" {
  description = "Existing KV v2 mount. Dev-mode Vault ships 'secret/' already enabled; this module does not create the mount."
  type        = string
  default     = "secret"
}

variable "vault_token_ttl_seconds" {
  description = "TTL of the Vault token an EC2 worker gets. It is used for one KV read and discarded."
  type        = number
  default     = 300
}
