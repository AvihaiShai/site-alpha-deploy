output "project_id" {
  value = var.project_id
}

output "zone" {
  value = var.zone
}

output "name_prefix" {
  value = var.name_prefix
}

output "bastion_name" {
  value = google_compute_instance.bastion.name
}

output "bastion_public_ip" {
  description = "Empty in IAP mode."
  value       = try(google_compute_instance.bastion.network_interface[0].access_config[0].nat_ip, "")
}

output "bastion_internal_ip" {
  value = google_compute_instance.bastion.network_interface[0].network_ip
}

output "k3s_name" {
  value = google_compute_instance.k3s.name
}

output "k3s_internal_ip" {
  value = google_compute_address.k3s_internal.address
}

output "enable_oslogin" {
  value = var.enable_oslogin
}

output "ssh_user" {
  description = "Metadata-key user (with OS Login the username comes from your Google identity)."
  value       = var.ssh_user
}

output "next_steps" {
  value = <<-EOT
    1) ./scripts/10-ssh-config.sh        # writes .local/ssh_config from these outputs
    2) ./scripts/20-bootstrap-bastion.sh # tools on bastion + kubeconfig (via bastion only)
    3) ssh -F .local/ssh_config ${var.name_prefix}-bastion
       cd ~/airis && ./scripts/30-deploy-db.sh && .venv/bin/python validator/validate.py
  EOT
}
