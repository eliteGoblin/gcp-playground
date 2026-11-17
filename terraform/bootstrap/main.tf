locals {
  services = [
    "artifactregistry.googleapis.com",
    "binaryauthorization.googleapis.com",
    "certificatemanager.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudtrace.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "containeranalysis.googleapis.com",
    "containerscanning.googleapis.com",
    "containersecurity.googleapis.com",
    "dns.googleapis.com",
    "domains.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "sts.googleapis.com",
  ]

  # Roles for the apply identity. Each role is an admin role for one service
  # that this repository manages. No roles/owner and no roles/editor.
  apply_roles = [
    "roles/artifactregistry.admin",
    "roles/binaryauthorization.policyEditor",
    "roles/certificatemanager.owner",
    "roles/cloudkms.admin",
    "roles/compute.admin",
    "roles/container.admin",
    "roles/dns.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/logging.admin",
    "roles/monitoring.admin",
    "roles/pubsub.admin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
  ]

  # Roles for the plan identity: read-only.
  plan_roles = [
    "roles/viewer",
    "roles/iam.securityReviewer",
  ]
}

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_project_service" "this" {
  for_each = toset(local.services)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Terraform state
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "tfstate" {
  name     = "${var.project_id}-tfstate"
  project  = var.project_id
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 20
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }
}

# ---------------------------------------------------------------------------
# GitHub Actions identity: Workload Identity Federation, no keys
# ---------------------------------------------------------------------------
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Tokens from any other repository are rejected at the provider.
  attribute_condition = "assertion.repository == \"${var.github_repo}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

locals {
  wif_principal_prefix = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}"
}

# Plan identity: any branch or pull request of the repository, read-only.
resource "google_service_account" "tf_plan" {
  project      = var.project_id
  account_id   = "tf-plan"
  display_name = "Terraform plan (read-only, pull requests)"
}

resource "google_service_account_iam_member" "tf_plan_wif" {
  service_account_id = google_service_account.tf_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.wif_principal_prefix}/attribute.repository/${var.github_repo}"
}

resource "google_project_iam_member" "tf_plan" {
  for_each = toset(local.plan_roles)

  project = var.project_id
  role    = each.value
  member  = google_service_account.tf_plan.member
}

# Apply identity: only the main branch.
resource "google_service_account" "tf_apply" {
  project      = var.project_id
  account_id   = "tf-apply"
  display_name = "Terraform apply (main branch only)"
}

resource "google_service_account_iam_member" "tf_apply_wif" {
  service_account_id = google_service_account.tf_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.wif_principal_prefix}/attribute.ref/refs/heads/main"
}

resource "google_project_iam_member" "tf_apply" {
  for_each = toset(local.apply_roles)

  project = var.project_id
  role    = each.value
  member  = google_service_account.tf_apply.member
}

# State bucket access. Plan needs write access for the state lock object.
resource "google_storage_bucket_iam_member" "tfstate" {
  for_each = {
    plan  = google_service_account.tf_plan.member
    apply = google_service_account.tf_apply.member
  }

  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectUser"
  member = each.value
}
