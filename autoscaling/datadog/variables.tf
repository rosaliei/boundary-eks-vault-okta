variable "datadog_api_key" {
  type      = string
  sensitive = true
}

variable "datadog_app_key" {
  type      = string
  sensitive = true
}

variable "datadog_site" {
  type    = string
  default = "datadoghq.com"
}

variable "github_repo" {
  description = "owner/name of this repository - the webhook posts a repository_dispatch here"
  type        = string
}

variable "github_dispatch_token" {
  description = "Fine-grained GitHub token, this repo only, permission contents: write. Datadog stores it as a webhook header."
  type        = string
  sensitive   = true
}

variable "asg_name" {
  type    = string
  default = "boundary-workers"
}

variable "scale_out_sessions_per_worker" {
  description = "Average active sessions per worker that triggers +1"
  type        = number
  default     = 10
}

variable "scale_in_sessions_per_worker" {
  description = "Average active sessions per worker below which -1 fires. Keep well under scale_out to avoid flapping."
  type        = number
  default     = 3
}

variable "scale_out_window" {
  type    = string
  default = "last_5m"
}

variable "scale_in_window" {
  description = "The stabilization window"
  type        = string
  default     = "last_15m"
}

variable "notify_handle" {
  description = "Extra @-handle for the stale-worker monitor, e.g. @slack-ops or @you@example.com"
  type        = string
  default     = ""
}
