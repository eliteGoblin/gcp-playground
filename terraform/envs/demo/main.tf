module "network" {
  source = "../../modules/network"

  project_id    = var.project_id
  name          = var.name
  region        = var.region
  nodes_cidr    = "10.10.0.0/20"
  pods_cidr     = "10.20.0.0/16"
  services_cidr = "10.30.0.0/20"
}

module "gke" {
  source = "../../modules/gke"

  project_id          = var.project_id
  name                = var.name
  region              = var.region
  zones               = var.zones
  network_name        = module.network.network_name
  subnet_name         = module.network.subnet_name
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
}

resource "google_artifact_registry_repository" "apps" {
  #checkov:skip=CKV_GCP_84:Google-managed encryption at rest is used. Customer-managed keys are an enterprise option (docs/enterprise-upgrades.md).
  project       = var.project_id
  location      = var.region
  repository_id = "apps"
  format        = "DOCKER"
  description   = "Application images built by GitHub Actions."

  vulnerability_scanning_config {
    enablement_config = "INHERITED"
  }
}
