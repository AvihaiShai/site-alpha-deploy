# Custom-mode VPC: no auto-created subnets in every region. We create exactly
# two subnets, so the network contains only what we can explain.

resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "Airis Core phase 1 - Zero Trust data layer"

  depends_on = [google_project_service.apis]
}

# Bastion subnet: the only place where a public IP may exist.
resource "google_compute_subnetwork" "bastion" {
  name          = "${var.name_prefix}-snet-bastion"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.bastion_subnet_cidr

  private_ip_google_access = true

  dynamic "log_config" {
    for_each = var.enable_flow_logs ? [1] : []
    content {
      aggregation_interval = "INTERVAL_5_SEC"
      flow_sampling        = 1.0
      metadata             = "INCLUDE_ALL_METADATA"
    }
  }
}

# Private subnet: K3s node(s). No VM here ever gets a public IP.
resource "google_compute_subnetwork" "private" {
  name          = "${var.name_prefix}-snet-private"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.private_subnet_cidr

  # Reach Google APIs (e.g. a GCS backup bucket in phase 2) over Google's
  # network, without an external IP.
  private_ip_google_access = true

  dynamic "log_config" {
    for_each = var.enable_flow_logs ? [1] : []
    content {
      aggregation_interval = "INTERVAL_5_SEC"
      flow_sampling        = 1.0
      metadata             = "INCLUDE_ALL_METADATA"
    }
  }
}

# Fixed internal IP for the K3s node: the kubeconfig, the TLS SAN and the
# validator all refer to it, so it must survive a VM re-create.
resource "google_compute_address" "k3s_internal" {
  name         = "${var.name_prefix}-k3s-01-ip"
  region       = var.region
  subnetwork   = google_compute_subnetwork.private.id
  address_type = "INTERNAL"
  address      = cidrhost(var.private_subnet_cidr, 10)
}
