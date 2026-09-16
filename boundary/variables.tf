# -----------------------------------------------------------------------------
# Variables for Boundary Configuration
# -----------------------------------------------------------------------------

# =============================================================================
# BOUNDARY CONNECTION
# =============================================================================

variable "boundary_addr" {
  description = "HCP Boundary cluster address"
  type        = string
  default     = "https://95390bdc-e040-47df-8638-7c996c0f98f7.boundary.hashicorp.cloud"
}

variable "boundary_auth_method_id" {
  description = "Boundary auth method ID for Terraform provider authentication"
  type        = string
}

variable "boundary_auth_method_login_name" {
  description = "Username for Boundary provider authentication"
  type        = string
}

variable "boundary_auth_method_password" {
  description = "Password for Boundary provider authentication"
  type        = string
  sensitive   = true
}

# =============================================================================
# OKTA OIDC AUTH METHOD (existing - not managed here)
# =============================================================================

variable "okta_auth_method_id" {
  description = "ID of an existing Okta OIDC auth method in the org scope. Managed groups are created against it. The auth method itself stays hand-managed because Boundary never returns the Okta client secret."
  type        = string
  default     = "amoidc_eY8ldrT0GG" # "HC Okta Test", primary for the org
}

# =============================================================================
# ORGANIZATION STRUCTURE
# =============================================================================

variable "org_scope_id" {
  description = "Boundary organization scope ID (global scope child)"
  type        = string
}

variable "project_name" {
  description = "Name for the Boundary project"
  type        = string
  default     = "eks-access"
}

variable "project_description" {
  description = "Description for the Boundary project"
  type        = string
  default     = "EKS cluster access via Boundary and Vault dynamic credentials"
}

# =============================================================================
# EKS TARGET CONFIGURATION
# =============================================================================

variable "eks_api_endpoint" {
  description = "Private EKS API endpoint (from terraform output: cluster_endpoint)"
  type        = string
}

variable "boundary_worker_filter" {
  # A tag filter, not a name filter. Autoscaled workers (../autoscaling) register
  # under generated names (worker-i-0abc...), so pinning a name would leave
  # every new worker unused. Every worker - the original single instance and
  # the ASG ones - carries type=eks in its worker.hcl tags.
  description = "Worker filter that selects any in-VPC worker tagged type=eks"
  type        = string
  default     = "\"eks\" in \"/tags/type\""
}

# =============================================================================
# OKTA GROUP NAMES
# These should match the groups configured in Okta
# =============================================================================

variable "okta_viewer_group" {
  description = "Okta group name for viewer access"
  type        = string
  default     = "eks-viewers"
}

variable "okta_operator_group" {
  description = "Okta group name for operator access"
  type        = string
  default     = "eks-operators"
}

variable "okta_admin_group" {
  description = "Okta group name for admin access"
  type        = string
  default     = "eks-admins"
}

variable "okta_groups_claim" {
  description = "Name of the ID-token claim carrying Okta group names. On Okta's ORG authorization server this is \"groups\", a reserved scope the client must request (see claims_scopes on the auth method). A custom authorization server would instead need a non-reserved name plus a matching custom scope."
  type        = string
  default     = "groups"
}

variable "viewer_emails" {
  description = "Email claims granted the viewer role directly, bypassing Okta group resolution. Empty this list once the groups claim works."
  type        = list(string)
  default     = [] # empty: Okta group membership is the only path
}

# =============================================================================
# VAULT CREDENTIAL BROKERING
# =============================================================================

variable "vault_address" {
  # The NLB hostname changes every time the Service is recreated. Read it with
  #   kubectl -n vault get svc vault -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  # and pass -var vault_address=... rather than trusting this default.
  description = "Vault API address reachable from the Boundary worker inside the VPC. A ClusterIP will not work - this is the internal NLB created by the Helm chart's service.type=LoadBalancer."
  type        = string
  default     = "http://aa837cd050a9d43028df5e6987267f93-d3fb677640c1fdfb.elb.ap-southeast-1.amazonaws.com:8200"
}

variable "vault_boundary_token" {
  description = "Periodic, orphan, renewable Vault token carrying the boundary-broker policy. Created outside Terraform so it never lands in state as a literal."
  type        = string
  sensitive   = true
  default     = ""
}

variable "kubernetes_namespace" {
  description = "Namespace the brokered ServiceAccount tokens are scoped to"
  type        = string
  default     = "demo-app"
}
