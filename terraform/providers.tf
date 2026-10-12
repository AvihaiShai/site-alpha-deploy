provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  # Every resource that supports labels gets these. Cheap governance:
  # the client's security team can find everything we created with one filter.
  default_labels = {
    managed-by  = "terraform"
    environment = var.environment
    component   = "airis-core"
  }
}
