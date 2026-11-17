# Cloud resources and IAM for workloads that run in the cluster.
#
# IAM is granted directly to the Kubernetes service account as a principal
# (Workload Identity Federation for GKE). There is no Google service account
# to impersonate and no key.

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  ksa_principal_prefix = "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns"

  # "<namespace>/<service account>" => project roles
  workload_project_roles = {
    "keda/keda-operator" = ["roles/monitoring.viewer"] # reads Pub/Sub backlog metrics
    # Kyverno reads cosign signatures from Artifact Registry to verify images.
    "kyverno/kyverno-admission-controller"  = ["roles/artifactregistry.reader"]
    "kyverno/kyverno-background-controller" = ["roles/artifactregistry.reader"]
    "kyverno/kyverno-reports-controller"    = ["roles/artifactregistry.reader"]
    "observability/otel-collector"          = ["roles/cloudtrace.agent"]
    "observability/gmp-frontend"            = ["roles/monitoring.viewer"] # Grafana queries Managed Prometheus through this proxy
  }

  workload_project_bindings = merge([
    for ksa, roles in local.workload_project_roles : {
      for role in roles : "${ksa}:${role}" => {
        member = "${local.ksa_principal_prefix}/${split("/", ksa)[0]}/sa/${split("/", ksa)[1]}"
        role   = role
      }
    }
  ]...)
}

resource "google_project_iam_member" "workload" {
  for_each = local.workload_project_bindings

  project = var.project_id
  role    = each.value.role
  member  = each.value.member
}

# --- Demo app: orders ---------------------------------------------------------
resource "google_pubsub_topic" "orders" {
  #checkov:skip=CKV_GCP_83:Google-managed encryption at rest is used. Customer-managed keys are an enterprise option (docs/enterprise-upgrades.md).
  project = var.project_id
  name    = "orders"
}

resource "google_pubsub_topic" "orders_dead_letter" {
  #checkov:skip=CKV_GCP_83:Google-managed encryption at rest is used. Customer-managed keys are an enterprise option (docs/enterprise-upgrades.md).
  project = var.project_id
  name    = "orders-dead-letter"
}

resource "google_pubsub_subscription" "orders_worker" {
  project = var.project_id
  name    = "orders-worker"
  topic   = google_pubsub_topic.orders.id

  ack_deadline_seconds = 30

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.orders_dead_letter.id
    max_delivery_attempts = 5
  }
}

resource "google_pubsub_topic_iam_member" "orders_api_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.orders.name
  role    = "roles/pubsub.publisher"
  member  = "${local.ksa_principal_prefix}/orders/sa/orders-api"
}

resource "google_pubsub_subscription_iam_member" "orders_worker_subscriber" {
  project      = var.project_id
  subscription = google_pubsub_subscription.orders_worker.name
  role         = "roles/pubsub.subscriber"
  member       = "${local.ksa_principal_prefix}/orders/sa/orders-worker"
}

# The Pub/Sub service agent moves failed messages to the dead-letter topic.
resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.orders_dead_letter.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_subscription_iam_member" "dead_letter_subscriber" {
  project      = var.project_id
  subscription = google_pubsub_subscription.orders_worker.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
