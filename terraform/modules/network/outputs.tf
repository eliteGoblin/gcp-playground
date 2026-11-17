output "network_name" {
  value = module.vpc.network_name
}

output "network_id" {
  value = module.vpc.network_id
}

output "subnet_name" {
  value = local.subnet_name
}

output "pods_range_name" {
  value = local.pods_range
}

output "services_range_name" {
  value = local.service_range
}
