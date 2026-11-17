output "name" {
  value = module.cluster.name
}

output "location" {
  value = module.cluster.location
}

output "dns_endpoint" {
  description = "Control plane DNS endpoint. Access is controlled by IAM."
  value       = module.cluster.endpoint_dns
}

output "master_version" {
  value = module.cluster.master_version
}

output "workload_identity_pool" {
  value = module.cluster.identity_namespace
}

output "node_service_account" {
  value = module.cluster.service_account
}
