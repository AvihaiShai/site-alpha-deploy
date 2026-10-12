#!/usr/bin/env bash
# LAPTOP. Run first, on site. Finds the environment problems BEFORE terraform does.
#
#   PROJECT_ID=<client-project> ./scripts/00-preflight.sh
#
# Checks: tools, gcloud login + ADC, project access, Compute API (enables it
# early - it takes 1-2 min), org policies that change our design, region quota,
# site egress IP, SSH key. Writes terraform/terraform.tfvars if it doesn't exist.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PROJECT_ID="${PROJECT_ID:-${1:-}}"
REGION="${REGION:-me-west1}"
KEY="${SSH_KEY:-$HOME/.ssh/airis_fde}"
[ -n "$PROJECT_ID" ] || die "usage: PROJECT_ID=<project> $0"

log "1/8 Tools"
for t in terraform gcloud ssh ssh-keygen curl tar; do need "$t"; done
ok "terraform $(terraform version | head -1 | awk '{print $2}'), $(gcloud version 2>/dev/null | head -1)"

log "2/8 gcloud identity"
ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
[ -n "$ACCOUNT" ] || die "not logged in: gcloud auth login"
ok "active account: $ACCOUNT"
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  ok "Application Default Credentials present (Terraform uses these)"
else
  die "Terraform needs ADC: gcloud auth application-default login"
fi

log "3/8 Project"
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1
gcloud auth application-default set-quota-project "$PROJECT_ID" >/dev/null 2>&1 \
  || warn "could not set the ADC quota project (Terraform may complain about a quota project)"
STATE="$(gcloud projects describe "$PROJECT_ID" --format='value(lifecycleState)' 2>/dev/null || true)"
[ "$STATE" = "ACTIVE" ] || die "cannot read project $PROJECT_ID (state='$STATE') - wrong ID or no permission"
ok "project $PROJECT_ID is ACTIVE"
if [ "$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null)" = "True" ]; then
  ok "billing enabled"
else
  warn "billing not enabled or not readable - VM creation fails without billing (ask the POC)"
fi

log "4/8 Compute API (enabling now saves 1-2 minutes later)"
if gcloud services list --enabled --project "$PROJECT_ID" --filter='config.name=compute.googleapis.com' \
     --format='value(config.name)' 2>/dev/null | grep -q compute; then
  ok "compute.googleapis.com already enabled"
else
  warn "compute.googleapis.com is disabled - enabling"
  gcloud services enable compute.googleapis.com --project "$PROJECT_ID" \
    && ok "enabled" || warn "could not enable (permission?). Ask the POC, or set enable_apis=false after they do."
fi

log "5/8 Org policies that change the design (needs orgpolicy viewer; skipped if denied)"
check_policy() {  # $1 constraint, $2 hint
  local out
  if out="$(gcloud resource-manager org-policies describe "$1" --project "$PROJECT_ID" --effective --format=json 2>/dev/null)"; then
    if echo "$out" | grep -qE '"enforced": true|"allValues": "DENY"|"deniedValues"|"allowedValues"'; then
      warn "$1 is restricted -> $2"
      echo "$out" | sed 's/^/        /' | head -15
    else
      ok "$1: not restricted"
    fi
  else
    warn "$1: cannot read (no permission) - ask the POC if unsure"
  fi
}
check_policy compute.vmExternalIpAccess "set bastion_public_ip = false (IAP mode)"
check_policy compute.requireOsLogin     "set enable_oslogin = true"
check_policy gcp.resourceLocations      "make sure region '$REGION' is allowed"
check_policy compute.requireShieldedVm  "already compliant (Shielded VM is on)"
check_policy compute.trustedImageProjects  "debian-cloud must be allowed, or set var.image to an allowed image"
check_policy compute.restrictCloudNATUsage "Cloud NAT blocked -> K3s cannot download (air-gap path needed)"
check_policy gcp.restrictNonCmekServices   "disks may require CMEK keys"
if gcloud compute networks describe default --project "$PROJECT_ID" >/dev/null 2>&1; then
  warn "a 'default' VPC exists (created with the Compute API; its default-allow-ssh rule is open to 0.0.0.0/0)."
  warn "  We don't use it. Recommend the client deletes it - do not delete it yourself without their approval."
fi

log "6/8 Regional CPU quota in $REGION (need ~6 vCPU)"
gcloud compute regions describe "$REGION" --project "$PROJECT_ID" \
  --format='table(quotas.metric,quotas.limit,quotas.usage)' --flatten=quotas 2>/dev/null \
  | grep -E 'METRIC|^CPUS |IN_USE_ADDRESSES|E2_CPUS' || warn "could not read quotas"

log "7/8 Site egress IP (the ONLY source allowed to SSH to the bastion)"
EGRESS_IP="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
if [ -n "$EGRESS_IP" ]; then ok "egress IP: $EGRESS_IP -> allowed_ssh_cidrs = [\"$EGRESS_IP/32\"]"
else warn "could not detect egress IP - ask the POC for the site's egress range"; fi

log "8/8 SSH key (ed25519, used only for this engagement)"
if [ -f "$KEY" ]; then ok "key exists: $KEY"
else
  ssh-keygen -t ed25519 -N "" -C "fde@site-alpha" -f "$KEY" >/dev/null
  chmod 600 "$KEY"; ok "created $KEY (delete it at the end: scripts/99-cleanup-laptop.sh)"
fi

TFVARS="${TF_DIR}/terraform.tfvars"
if [ ! -f "$TFVARS" ]; then
  cat > "$TFVARS" <<EOF
project_id          = "${PROJECT_ID}"
allowed_ssh_cidrs   = ["${EGRESS_IP:-CHANGE_ME}/32"]
region              = "${REGION}"
zone                = "${REGION}-a"
ssh_public_key_path = "${KEY}.pub"
bastion_public_ip   = true
enable_oslogin      = false
EOF
  ok "wrote $TFVARS - review it, then: terraform -chdir=terraform init && terraform -chdir=terraform apply"
else
  ok "$TFVARS already exists - not touching it"
fi
