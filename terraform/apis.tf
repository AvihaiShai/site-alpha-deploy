# A brand-new project has almost every API switched off. Creating a VM before
# compute.googleapis.com is on fails with "403 ... SERVICE_DISABLED".
# Everything else in this module depends on this resource, so the API is on first.

locals {
  required_apis = toset(concat(
    ["compute.googleapis.com"],
    var.bastion_public_ip ? [] : ["iap.googleapis.com"],
    var.enable_oslogin ? ["oslogin.googleapis.com"] : [],
  ))
}

resource "google_project_service" "apis" {
  for_each = var.enable_apis ? local.required_apis : toset([])

  project = var.project_id
  service = each.value

  # Never switch an API off on destroy: other teams in the project may use it.
  disable_on_destroy         = false
  disable_dependent_services = false
}
