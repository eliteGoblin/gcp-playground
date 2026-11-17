output "cluster_name" {
  value = module.gke.name
}

output "cluster_location" {
  value = module.gke.location
}

output "cluster_dns_endpoint" {
  value = module.gke.dns_endpoint
}

output "cluster_version" {
  value = module.gke.master_version
}

output "get_credentials" {
  description = "Command that configures kubectl through the DNS endpoint."
  value       = "gcloud container clusters get-credentials ${module.gke.name} --location ${module.gke.location} --project ${var.project_id} --dns-endpoint"
}

output "artifact_registry" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.apps.repository_id}"
}

output "name_servers" {
  description = "Set these name servers at the domain registrar."
  value       = local.edge_enabled ? module.dns_zone[0].name_servers : []
}

output "gateway_address" {
  value = local.edge_enabled ? google_compute_global_address.gateway[0].address : null
}
