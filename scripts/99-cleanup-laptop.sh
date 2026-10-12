#!/usr/bin/env bash
# LAPTOP. Leave no credentials behind on a laptop that isn't yours.
# Run AFTER the session (and after 'terraform destroy' if the client asked for teardown).
set -uo pipefail
source "$(dirname "$0")/lib.sh"

KEY="${SSH_KEY:-$HOME/.ssh/airis_fde}"
log "Removing generated SSH config / known_hosts / reports (.local/)"
rm -rf "${LOCAL_DIR}"
log "Removing the engagement SSH key pair"
rm -f "${KEY}" "${KEY}.pub"
log "Revoking gcloud Application Default Credentials and user login"
gcloud auth application-default revoke --quiet 2>/dev/null || true
gcloud auth revoke --all --quiet 2>/dev/null || true
warn "terraform.tfstate is still in terraform/ - it describes the client's infrastructure."
warn "Hand it over (or move it to their GCS backend) and then delete it - ask the client which."
ok "laptop cleaned"
