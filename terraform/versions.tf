# Pin the tools so the same code gives the same result on any laptop.
# "~> 7.0" = any 7.x provider (bug fixes OK), never an untested 8.0.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # Phase 1: local state (single operator, on-site, short-lived).
  # Production: remote state in a GCS bucket with object versioning; the
  # gcs backend locks the state natively so two engineers can't apply at once.
  # backend "gcs" {
  #   bucket = "<client>-tfstate"
  #   prefix = "site-alpha/airis-core"
  # }
}
