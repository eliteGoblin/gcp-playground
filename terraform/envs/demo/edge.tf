# Public edge: DNS zone, wildcard certificate, load balancer address, Cloud Armor.
# Everything here is created only when var.domain is set.
#
# Request path:
#   user -> Cloud DNS -> global external Application Load Balancer (this address,
#   this certificate map, this Cloud Armor policy) -> Gateway API -> Pod

locals {
  edge_enabled = var.domain != null
  edge_count   = local.edge_enabled ? 1 : 0
}

# --- DNS -------------------------------------------------------------------------
module "dns_zone" {
  source  = "terraform-google-modules/cloud-dns/google"
  version = "7.2.1"
  count   = local.edge_count

  project_id = var.project_id
  type       = "public"
  name       = replace(var.domain, ".", "-")
  domain     = "${var.domain}."

  dnssec_config = {
    state = "on"
  }
}

# --- Certificate: Google-managed, wildcard, DNS authorization --------------------
# DNS authorization issues the certificate before the load balancer exists and
# supports a wildcard. Google renews it automatically.
resource "google_certificate_manager_dns_authorization" "this" {
  count = local.edge_count

  project = var.project_id
  name    = "${var.name}-dns-auth"
  domain  = var.domain
}

# Certificate Manager proves domain ownership through this CNAME record.
resource "google_dns_record_set" "cert_validation" {
  count = local.edge_count

  project      = var.project_id
  managed_zone = module.dns_zone[0].name
  name         = google_certificate_manager_dns_authorization.this[0].dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.this[0].dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.this[0].dns_resource_record[0].data]
}

resource "google_certificate_manager_certificate" "wildcard" {
  count = local.edge_count

  project = var.project_id
  name    = "${var.name}-wildcard"

  managed {
    domains            = [var.domain, "*.${var.domain}"]
    dns_authorizations = [google_certificate_manager_dns_authorization.this[0].id]
  }
}

resource "google_certificate_manager_certificate_map" "this" {
  count = local.edge_count

  project = var.project_id
  name    = "${var.name}-certmap" # the Gateway refers to this name
}

resource "google_certificate_manager_certificate_map_entry" "this" {
  for_each = local.edge_enabled ? { apex = var.domain, wildcard = "*.${var.domain}" } : {}

  project      = var.project_id
  name         = "${var.name}-${each.key}"
  map          = google_certificate_manager_certificate_map.this[0].name
  hostname     = each.value
  certificates = [google_certificate_manager_certificate.wildcard[0].id]
}

# --- Load balancer address ---------------------------------------------------------
resource "google_compute_global_address" "gateway" {
  count = local.edge_count

  project = var.project_id
  name    = "${var.name}-gateway" # the Gateway refers to this name
}

# --- Cloud Armor: basic edge protection --------------------------------------------
resource "google_compute_security_policy" "edge" {
  count = local.edge_count

  project     = var.project_id
  name        = "${var.name}-edge" # GCPBackendPolicy objects refer to this name
  description = "Rate limit per client IP and a preconfigured WAF rule."

  rule {
    description = "Block known exploit patterns, including Log4Shell (CVE-2021-44228)"
    priority    = 900
    action      = "deny(403)"
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('cve-canary')"
      }
    }
  }

  rule {
    description = "Block common SQL injection patterns (OWASP rule set, low sensitivity)"
    priority    = 1000
    action      = "deny(403)"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})"
      }
    }
  }

  rule {
    description = "Rate limit: 300 requests per minute per client IP"
    priority    = 2000
    action      = "throttle"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 300
        interval_sec = 60
      }
    }
  }

  rule {
    description = "Default rule"
    priority    = 2147483647
    action      = "allow"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

# --- external-dns: writes DNS records for Gateway routes ---------------------------
# Scoped to DNS only. Enterprise option: a custom role limited to this one zone.
resource "google_project_iam_member" "external_dns" {
  count = local.edge_count

  project = var.project_id
  role    = "roles/dns.admin"
  member  = "${local.ksa_principal_prefix}/external-dns/sa/external-dns"
}
