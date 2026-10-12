# GCP VPC firewall basics:
#  - Rules belong to the VPC (not to a subnet) and are stateful: reply packets
#    of an allowed connection are allowed automatically.
#  - Lower priority number = evaluated first.
#  - Two implied rules exist at priority 65535: deny all ingress, allow all egress.
#    They do not log, so we add explicit, LOGGED deny rules at 65000.
#  - Rules target VMs by network tag.
#  - Traffic to the metadata server (169.254.169.254: DNS, NTP, metadata) is
#    always allowed and not subject to these rules.

locals {
  bastion_tag = "${var.name_prefix}-bastion"
  k3s_tag     = "${var.name_prefix}-k3s"

  # Google's IAP TCP-forwarding range: the only source when the bastion has no public IP.
  iap_range = "35.235.240.0/20"

  bastion_ssh_sources = var.bastion_public_ip ? var.allowed_ssh_cidrs : [local.iap_range]
}

# 1) The ONLY way in from outside: SSH (22) to the bastion, from the site only.
resource "google_compute_firewall" "bastion_ssh_ingress" {
  name        = "${var.name_prefix}-allow-ssh-to-bastion"
  network     = google_compute_network.vpc.name
  description = "SSH to the bastion from the approved site egress IP(s) (or IAP) only"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = local.bastion_ssh_sources
  target_tags   = [local.bastion_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }

  lifecycle {
    precondition {
      condition     = length(local.bastion_ssh_sources) > 0
      error_message = "allowed_ssh_cidrs is empty. Set it to the site's egress IP, e.g. [\"203.0.113.7/32\"]."
    }
  }
}

# 2) Bastion -> K3s node: SSH (admin) and the Kubernetes API (kubectl/helm/validator).
#    Postgres (5432) is NOT opened on the network: the bastion reaches the DB
#    only through the Kubernetes API (port-forward), which is authenticated,
#    authorised (RBAC) and audited.
resource "google_compute_firewall" "bastion_to_k3s" {
  name        = "${var.name_prefix}-allow-bastion-to-k3s"
  network     = google_compute_network.vpc.name
  description = "Bastion to K3s node: SSH and Kubernetes API only"
  direction   = "INGRESS"
  priority    = 1000

  source_tags = [local.bastion_tag]
  target_tags = [local.k3s_tag]

  allow {
    protocol = "tcp"
    ports    = ["22", "6443"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# 3) Everything else inbound: denied AND logged (the implied deny is silent).
resource "google_compute_firewall" "deny_all_ingress_logged" {
  name        = "${var.name_prefix}-deny-all-ingress"
  network     = google_compute_network.vpc.name
  description = "Explicit, logged default-deny for all inbound traffic"
  direction   = "INGRESS"
  priority    = 65000

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# 4) K3s node egress: HTTPS only (K3s binary, container images), via Cloud NAT.
resource "google_compute_firewall" "k3s_egress_https" {
  count = var.restrict_k3s_egress ? 1 : 0

  name               = "${var.name_prefix}-allow-k3s-egress-https"
  network            = google_compute_network.vpc.name
  description        = "K3s node may open outbound HTTPS only (registries, GitHub)"
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = ["0.0.0.0/0"]
  target_tags        = [local.k3s_tag]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "k3s_egress_deny_all" {
  count = var.restrict_k3s_egress ? 1 : 0

  name               = "${var.name_prefix}-deny-k3s-egress"
  network            = google_compute_network.vpc.name
  description        = "Everything else outbound from the K3s node is denied and logged"
  direction          = "EGRESS"
  priority           = 65000
  destination_ranges = ["0.0.0.0/0"]
  target_tags        = [local.k3s_tag]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
