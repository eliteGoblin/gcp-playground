output "tfstate_bucket" {
  value = google_storage_bucket.tfstate.name
}

output "workload_identity_provider" {
  description = "Value for google-github-actions/auth `workload_identity_provider`."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "tf_plan_service_account" {
  value = google_service_account.tf_plan.email
}

output "tf_apply_service_account" {
  value = google_service_account.tf_apply.email
}
