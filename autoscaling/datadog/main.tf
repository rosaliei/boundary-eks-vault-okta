locals {
  metric = "avg:boundary.worker.active_sessions{asg:${var.asg_name}}"
}

# =============================================================================
# Webhooks -> GitHub repository_dispatch. One per direction so the workflow
# needs no parsing beyond client_payload.direction.
# =============================================================================

resource "datadog_webhook" "scale" {
  for_each = toset(["out", "in"])

  name = "gha-scale-${each.key}"
  url  = "https://api.github.com/repos/${var.github_repo}/dispatches"

  custom_headers = jsonencode({
    Accept               = "application/vnd.github+json"
    Authorization        = "Bearer ${var.github_dispatch_token}"
    X-GitHub-Api-Version = "2022-11-28"
  })

  payload = jsonencode({
    event_type = "scale"
    client_payload = {
      direction = each.key
      monitor   = "$ALERT_TITLE"
      value     = "$ALERT_METRIC"
      asg       = var.asg_name
    }
  })
}

# =============================================================================
# Monitors
# =============================================================================

resource "datadog_monitor" "scale_out" {
  name    = "[boundary] scale OUT - ${var.asg_name}"
  type    = "metric alert"
  query   = "avg(${var.scale_out_window}):${local.metric} > ${var.scale_out_sessions_per_worker}"
  message = <<-EOT
    Average sessions per worker above ${var.scale_out_sessions_per_worker} for ${var.scale_out_window}.
    Adding one worker. @webhook-gha-scale-out
  EOT

  monitor_thresholds {
    critical = var.scale_out_sessions_per_worker
  }

  notify_no_data    = false
  renotify_interval = 10 # re-fire every 10 min while still above -> +1 again, up to max
  renotify_statuses = ["alert"]
  include_tags      = false
  tags              = ["service:boundary-worker", "asg:${var.asg_name}"]
}

resource "datadog_monitor" "scale_in" {
  name    = "[boundary] scale IN - ${var.asg_name}"
  type    = "metric alert"
  query   = "avg(${var.scale_in_window}):${local.metric} < ${var.scale_in_sessions_per_worker}"
  message = <<-EOT
    Average sessions per worker below ${var.scale_in_sessions_per_worker} for ${var.scale_in_window}.
    Removing one worker. @webhook-gha-scale-in
  EOT

  monitor_thresholds {
    critical = var.scale_in_sessions_per_worker
  }

  notify_no_data    = false
  renotify_interval = 20 # slower than scale-out on purpose
  renotify_statuses = ["alert"]
  include_tags      = false
  tags              = ["service:boundary-worker", "asg:${var.asg_name}"]
}

# The check that deregistration works: a worker host that stopped reporting
# is either mid-termination (fine, clears in minutes) or a leak.
resource "datadog_monitor" "worker_stale" {
  name    = "[boundary] worker stopped reporting - ${var.asg_name}"
  type    = "service check"
  query   = "\"boundary.worker.health\".over(\"asg:${var.asg_name}\").by(\"host\").last(6).count_by_status()"
  message = <<-EOT
    A worker in ${var.asg_name} has not reported for ~10 minutes. If it is still in
    `boundary workers list`, deregistration failed - check journalctl -u boundary-lifecycle on it. ${var.notify_handle}
  EOT

  monitor_thresholds {
    critical = 4
    warning  = 2
    ok       = 1
  }

  notify_no_data    = true
  no_data_timeframe = 10
  tags              = ["service:boundary-worker", "asg:${var.asg_name}"]
}

# =============================================================================
# Dashboard
# =============================================================================

resource "datadog_dashboard_json" "boundary" {
  dashboard = templatefile("${path.module}/dashboard.json.tpl", {
    asg           = var.asg_name
    scale_out_id  = datadog_monitor.scale_out.id
    scale_in_id   = datadog_monitor.scale_in.id
    stale_id      = datadog_monitor.worker_stale.id
    out_threshold = var.scale_out_sessions_per_worker
    in_threshold  = var.scale_in_sessions_per_worker
  })
}

output "dashboard_url" {
  value = "https://app.${var.datadog_site}${datadog_dashboard_json.boundary.url}"
}
