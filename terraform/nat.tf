# A VM without an external IP has NO internet access - not even outbound.
# K3s must download its binary (github.com) and container images (ghcr.io,
# docker.io). Cloud NAT gives OUTBOUND-only access: nothing on the internet can
# open a connection back in.
#
# Phase-2 hardening: mirror images into a private Artifact Registry, use the
# K3s air-gap install, and remove NAT entirely.

resource "google_compute_router" "router" {
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  # Only the private subnet gets NAT ...
  subnetwork {
    name                    = google_compute_subnetwork.private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  # ... plus the bastion subnet when the bastion has no public IP (IAP mode),
  # so it can still install kubectl/helm/python packages.
  dynamic "subnetwork" {
    for_each = var.bastion_public_ip ? [] : [1]
    content {
      name                    = google_compute_subnetwork.bastion.id
      source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
    }
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
