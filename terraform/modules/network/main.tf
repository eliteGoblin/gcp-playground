locals {
  subnet_name   = "${var.name}-nodes"
  pods_range    = "${var.name}-pods"
  service_range = "${var.name}-services"
}

module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "18.3.1"

  project_id   = var.project_id
  network_name = var.name
  routing_mode = "REGIONAL"

  subnets = [
    {
      subnet_name           = local.subnet_name
      subnet_ip             = var.nodes_cidr
      subnet_region         = var.region
      subnet_private_access = "true" # nodes reach Google APIs without a public IP
      subnet_flow_logs      = "true"
    },
  ]

  secondary_ranges = {
    (local.subnet_name) = [
      { range_name = local.pods_range, ip_cidr_range = var.pods_cidr },
      { range_name = local.service_range, ip_cidr_range = var.services_cidr },
    ]
  }
}

# Private nodes have no public IP. Cloud NAT gives them outbound internet access
# (image pulls from registries outside Google, calls to external APIs).
module "router" {
  source  = "terraform-google-modules/cloud-router/google"
  version = "9.1.0"

  project_id = var.project_id
  name       = "${var.name}-router"
  network    = module.vpc.network_name
  region     = var.region

  nats = [
    {
      name                               = "${var.name}-nat"
      nat_ip_allocate_option             = "AUTO_ONLY"
      source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
      log_config = {
        enable = true
        filter = "ERRORS_ONLY"
      }
    },
  ]
}
