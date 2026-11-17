# Service level objective for the orders API, with burn-rate alerts.
#
# SLI:  share of POST /orders requests that do not return a 5xx status.
#       Source: the app metric http_requests_total, collected by Managed Prometheus.
# SLO:  99.5 % over a rolling 28 days. Error budget = 0.5 % of requests.
# Alert: on how fast the error budget is used (burn rate), not on single errors.
#   fast burn: rate 14.4 over 1 hour  = 2 % of the 28-day budget in 1 hour  -> act now
#   slow burn: rate 6 over 6 hours    = 5 % of the budget in 6 hours        -> act today

locals {
  orders_requests_filter = join(" ", [
    "metric.type=\"prometheus.googleapis.com/http_requests_total/counter\"",
    "resource.type=\"prometheus_target\"",
    "resource.label.namespace=\"orders\"",
    "metric.label.path=\"/orders\"",
  ])
}

resource "google_monitoring_custom_service" "orders_api" {
  project      = var.project_id
  service_id   = "orders-api"
  display_name = "orders-api"
}

resource "google_monitoring_slo" "orders_availability" {
  project      = var.project_id
  service      = google_monitoring_custom_service.orders_api.service_id
  slo_id       = "orders-availability"
  display_name = "99.5% of POST /orders requests succeed (28 days)"

  goal                = 0.995
  rolling_period_days = 28

  request_based_sli {
    good_total_ratio {
      total_service_filter = local.orders_requests_filter
      good_service_filter  = "${local.orders_requests_filter} metric.label.status!=monitoring.regex.full_match(\"5..\")"
    }
  }
}

variable "alert_email" {
  description = "Email address for alerts. Null = alerts open an incident in Cloud Monitoring only. Set it outside Git (TF_VAR_alert_email)."
  type        = string
  default     = null
}

resource "google_monitoring_notification_channel" "email" {
  count = var.alert_email == null ? 0 : 1

  project      = var.project_id
  display_name = "Platform on-call email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}

resource "google_monitoring_alert_policy" "orders_burn_rate" {
  project      = var.project_id
  display_name = "orders-api: error budget burn"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Fast burn: 14.4x over 1 hour"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.orders_availability.name}\", \"3600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 14.4
      duration        = "0s"
    }
  }

  conditions {
    display_name = "Slow burn: 6x over 6 hours"
    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.orders_availability.name}\", \"21600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 6
      duration        = "0s"
    }
  }

  notification_channels = google_monitoring_notification_channel.email[*].id

  documentation {
    mime_type = "text/markdown"
    subject   = "orders-api is using its error budget too fast"
    content   = <<-EOT
      The orders API returns 5xx errors at a rate that will use the 28-day error budget early.

      1. Check for a recent release: `kubectl argo rollouts get rollout orders-api -n orders`. If a canary is in progress, abort it.
      2. Check Pods and events: `scripts/cluster_report.py --namespace orders`.
      3. Check Pub/Sub publish errors in the API logs (Logs Explorer, namespace `orders`).
      4. Roll back by reverting the digest commit in `gitops/apps/orders/kustomization.yaml`.
    EOT
  }
}
