data "google_project" "this" {
  project_id = var.project_id
}

# ---------------------------------------------------------------------------
# Application-layer encryption of Kubernetes Secrets in etcd
# ---------------------------------------------------------------------------
resource "google_kms_key_ring" "gke" {
  project  = var.project_id
  name     = "${var.name}-gke"
  location = var.region
}

resource "google_kms_crypto_key" "secrets" {
  name            = "k8s-secrets"
  key_ring        = google_kms_key_ring.gke.id
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = false
  }
}

resource "google_kms_crypto_key_iam_member" "gke_agent" {
  crypto_key_id = google_kms_crypto_key.secrets.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.this.number}@container-engine-robot.iam.gserviceaccount.com"
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
module "cluster" {
  source  = "terraform-google-modules/kubernetes-engine/google//modules/private-cluster"
  version = "47.0.0"

  project_id = var.project_id
  name       = var.name
  regional   = true
  region     = var.region
  zones      = var.zones

  release_channel     = var.release_channel
  deletion_protection = var.deletion_protection

  # --- Network: VPC-native, private nodes, Dataplane V2 --------------------
  network           = var.network_name
  subnetwork        = var.subnet_name
  ip_range_pods     = var.pods_range_name
  ip_range_services = var.services_range_name

  enable_private_nodes = true
  datapath_provider    = "ADVANCED_DATAPATH" # Dataplane V2: eBPF, NetworkPolicy built in
  dns_cache            = true                # NodeLocal DNSCache
  gateway_api_channel  = "CHANNEL_STANDARD"

  # --- Control plane access: DNS endpoint with IAM, no IP endpoint ---------
  ip_endpoints_enabled       = false
  dns_allow_external_traffic = true
  master_authorized_networks = []

  # --- Security -------------------------------------------------------------
  enable_shielded_nodes                  = true
  enable_binary_authorization            = true
  enable_secret_manager_addon            = true
  insecure_kubelet_readonly_port_enabled = false
  security_posture_mode                  = "BASIC"
  security_posture_vulnerability_mode    = "VULNERABILITY_BASIC"

  database_encryption = [
    {
      state    = "ENCRYPTED"
      key_name = google_kms_crypto_key.secrets.id
    },
  ]

  # Dedicated node service account with minimum roles (not the Compute default).
  create_service_account = true
  grant_registry_access  = true

  # --- Observability ----------------------------------------------------------
  logging_enabled_components           = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  monitoring_enabled_components        = ["SYSTEM_COMPONENTS", "POD", "DEPLOYMENT", "KUBELET", "CADVISOR"]
  monitoring_enable_managed_prometheus = true
  enable_cost_allocation               = true

  # --- Scaling ----------------------------------------------------------------
  horizontal_pod_autoscaling      = true
  enable_vertical_pod_autoscaling = true

  # --- Upgrades: 02:00-06:00 Sydney time, Tuesday to Friday -----------------
  maintenance_start_time = "2026-01-05T15:00:00Z"
  maintenance_end_time   = "2026-01-05T19:00:00Z"
  maintenance_recurrence = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH"

  # --- Nodes ------------------------------------------------------------------
  remove_default_node_pool = true

  node_pools = [
    {
      name               = "system"
      machine_type       = var.system_pool.machine_type
      autoscaling        = true
      min_count          = var.system_pool.min_per_zone
      max_count          = var.system_pool.max_per_zone
      initial_node_count = var.system_pool.min_per_zone
      spot               = false
      image_type         = "COS_CONTAINERD"
      disk_type          = "pd-balanced"
      disk_size_gb       = 50
      auto_repair        = true
      auto_upgrade       = true
      enable_secure_boot = true
    },
    {
      # Spot nodes for interruptible batch jobs. Google can reclaim a Spot node
      # at any time with a short notice, so only Pods that tolerate the taint
      # below run here. The pool scales to 0 when no batch Pod is waiting.
      name               = "batch-spot"
      machine_type       = var.batch_spot_pool.machine_type
      autoscaling        = true
      min_count          = 0
      max_count          = var.batch_spot_pool.max_per_zone
      initial_node_count = 0
      spot               = true
      location_policy    = "ANY" # take capacity in any zone; best for Spot availability
      image_type         = "COS_CONTAINERD"
      disk_type          = "pd-balanced"
      disk_size_gb       = 50
      auto_repair        = true
      auto_upgrade       = true
      enable_secure_boot = true
    },
  ]

  node_pools_labels = {
    all        = {}
    system     = { role = "system" }
    batch-spot = { role = "batch" }
  }

  node_pools_taints = {
    all    = []
    system = []
    batch-spot = [
      {
        key    = "dedicated"
        value  = "batch"
        effect = "NO_SCHEDULE"
      },
    ]
  }

  depends_on = [google_kms_crypto_key_iam_member.gke_agent]
}
