# ---------------------------------------------------------------------------
# Required
# ---------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project ID provisioned by the client (Sector-9)."
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "Source CIDRs allowed to SSH to the bastion. Use the site's egress IP as /32 (curl -4 ifconfig.me)."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.allowed_ssh_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"
    ])
    error_message = "Every entry must be a valid CIDR, and 0.0.0.0/0 is not allowed (Zero Trust: no world-open SSH)."
  }
}

# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------

variable "region" {
  description = "Region. me-west1 = Tel Aviv (data residency in Israel). Confirm with the client."
  type        = string
  default     = "me-west1"
}

variable "zone" {
  description = "Zone for both VMs (phase 1 is single-zone by design)."
  type        = string
  default     = "me-west1-a"
}

variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
  default     = "airis"
}

variable "environment" {
  description = "Environment label value."
  type        = string
  default     = "site-alpha"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
# K3s defaults: pods 10.42.0.0/16, services 10.43.0.0/16.
# The VPC ranges below deliberately avoid them, so routing is never ambiguous.

variable "bastion_subnet_cidr" {
  description = "Subnet for the bastion only (/28 = 16 addresses; GCP keeps 4)."
  type        = string
  default     = "10.10.0.0/28"
}

variable "private_subnet_cidr" {
  description = "Private subnet for the K3s node(s). /24 leaves room for phase-2 nodes."
  type        = string
  default     = "10.10.1.0/24"
}

variable "enable_flow_logs" {
  description = "VPC flow logs on both subnets (audit trail for the security team)."
  type        = bool
  default     = true
}

variable "restrict_k3s_egress" {
  description = "K3s node may only open outbound TCP/443 (via Cloud NAT). Everything else is denied and logged."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Access model (toggles for client org policies)
# ---------------------------------------------------------------------------

variable "bastion_public_ip" {
  description = "true = bastion gets a public IP, SSH allowed only from allowed_ssh_cidrs. false = no public IP at all; SSH via IAP TCP forwarding (use if org policy forbids external IPs)."
  type        = bool
  default     = true
}

variable "enable_oslogin" {
  description = "true = OS Login (SSH access tied to IAM, auditable, revocable). false = a single SSH key in instance metadata."
  type        = bool
  default     = false
}

variable "ssh_user" {
  description = "Linux user created from the metadata SSH key (ignored when OS Login is on)."
  type        = string
  default     = "fde"
}

variable "ssh_public_key_path" {
  description = "Public key to install on both VMs (ignored when OS Login is on)."
  type        = string
  default     = "~/.ssh/airis_fde.pub"
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

variable "image" {
  description = "Boot image for both VMs. In production: the client's hardened golden image."
  type        = string
  default     = "debian-cloud/debian-12"
}

variable "bastion_machine_type" {
  description = "Bastion runs SSH, kubectl, helm and the Python validator only."
  type        = string
  default     = "e2-small"
}

variable "k3s_machine_type" {
  description = "4 vCPU / 16 GB: K3s (~1 GB) + operator + 3 Postgres instances at 0.5 CPU / 1 GiB each, with headroom."
  type        = string
  default     = "e2-standard-4"
}

variable "k3s_disk_size_gb" {
  description = "Boot disk of the K3s node. Postgres data lives here (local-path storage)."
  type        = number
  default     = 50
}

variable "k3s_version" {
  description = "Pinned K3s release. Must be a Kubernetes minor supported by the CNPG version (CNPG 1.30: 1.34-1.36)."
  type        = string
  default     = "v1.35.7+k3s1"
}

variable "k3s_bootstrap_via_startup_script" {
  description = "true = K3s installs itself at first boot (fast path). false = install manually over SSH through the bastion."
  type        = bool
  default     = true
}

variable "enable_apis" {
  description = "Let Terraform enable the required Google APIs. Set false if you lack serviceusage permissions and an admin enabled them."
  type        = bool
  default     = true
}
