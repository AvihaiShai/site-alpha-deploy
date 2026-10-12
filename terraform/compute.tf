locals {
  # Either OS Login (IAM-managed SSH) or one metadata key - never project-wide keys.
  # (Terraform evaluates both branches of a conditional but only reports errors from the
  # chosen one, so a missing key file is harmless when OS Login is on.)
  ssh_public_key = var.enable_oslogin ? "" : trimspace(file(pathexpand(var.ssh_public_key_path)))
  ssh_keys_value = var.enable_oslogin ? "" : "${var.ssh_user}:${local.ssh_public_key}"
}

# ---------------------------------------------------------------------------
# Bastion (jump host): the single entry point.
# ---------------------------------------------------------------------------
resource "google_compute_instance" "bastion" {
  #checkov:skip=CKV_GCP_40:Public IP is required by the brief (single entry point). Mitigated: SSH only, source = site /32, no other port; IAP mode (bastion_public_ip=false) removes it.
  #checkov:skip=CKV_GCP_38:Disks are encrypted at rest by Google-managed keys. CSEK/CMEK only if the client mandates it (phase 2, Cloud KMS).
  name                      = "${var.name_prefix}-bastion"
  machine_type              = var.bastion_machine_type
  zone                      = var.zone
  tags                      = [local.bastion_tag]
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = var.image
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.bastion.id

    # A public IP only in public-bastion mode. Reachable only from
    # allowed_ssh_cidrs on port 22 (see firewall.tf).
    dynamic "access_config" {
      for_each = var.bastion_public_ip ? [1] : []
      content {
        network_tier = "PREMIUM"
      }
    }
  }

  metadata = {
    "block-project-ssh-keys" = "TRUE"  # ignore project-wide keys someone else may add
    "serial-port-enable"     = "FALSE" # no interactive serial console
    "enable-oslogin"         = var.enable_oslogin ? "TRUE" : "FALSE"
    "ssh-keys"               = local.ssh_keys_value # empty when OS Login is on
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # No service_account block = no service account attached. Even a fully
  # compromised bastion cannot call GCP APIs with a VM identity.
}

# ---------------------------------------------------------------------------
# K3s node: private, no public IP, reachable only from the bastion.
# ---------------------------------------------------------------------------
resource "google_compute_instance" "k3s" {
  #checkov:skip=CKV_GCP_38:Disks are encrypted at rest by Google-managed keys. CSEK/CMEK only if the client mandates it (phase 2, Cloud KMS).
  name                      = "${var.name_prefix}-k3s-01"
  machine_type              = var.k3s_machine_type
  zone                      = var.zone
  tags                      = [local.k3s_tag]
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = var.image
      size  = var.k3s_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    network_ip = google_compute_address.k3s_internal.address
    # No access_config block => no external IP. Outbound internet only via Cloud NAT.
  }

  metadata = {
    "block-project-ssh-keys" = "TRUE"
    "serial-port-enable"     = "FALSE"
    "enable-oslogin"         = var.enable_oslogin ? "TRUE" : "FALSE"
    "ssh-keys"               = local.ssh_keys_value
    "k3s-version"            = var.k3s_version # read by scripts/k3s-install.sh from the metadata server
  }

  # Fast path: K3s installs itself at first boot. The same script can be run by
  # hand over SSH (k3s_bootstrap_via_startup_script = false).
  # Logs on the node: sudo journalctl -u google-startup-scripts.service
  metadata_startup_script = var.k3s_bootstrap_via_startup_script ? file("${path.module}/../scripts/k3s-install.sh") : null

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # No service account: the node needs no GCP API access in phase 1.
  # (Phase 2 with GCS backups: a dedicated SA with storage.objectAdmin on ONE bucket.)

  # The node needs Cloud NAT to download K3s at first boot.
  depends_on = [google_compute_router_nat.nat]

  lifecycle {
    # Changing metadata_startup_script would RE-CREATE this VM (and wipe the local
    # Postgres data). After creation, script changes are applied by hand:
    #   ./scripts/20-bootstrap-bastion.sh --install-k3s
    ignore_changes = [metadata_startup_script]
  }
}
