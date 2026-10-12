#!/usr/bin/env bash
# LAPTOP. Prepares the bastion as the single operations point:
#   1. waits for K3s on the private node (or installs it by hand with --install-k3s)
#   2. copies k8s/, helm/, validator/ and the bastion scripts to bastion:~/airis
#   3. installs kubectl, helm, psql, Python venv on the bastion
#   4. moves the K3s admin kubeconfig node -> laptop pipe -> bastion
#      (never written to the laptop's disk; server address rewritten to the private IP)
#   5. proves: bastion -> Kubernetes API over the private network
set -euo pipefail
source "$(dirname "$0")/lib.sh"

INSTALL_K3S=false
[ "${1:-}" = "--install-k3s" ] && INSTALL_K3S=true

PREFIX="$(tf_out name_prefix)"
K3S_IP="$(tf_out k3s_internal_ip)"
[ -f "$(ssh_cfg)" ] || die "run scripts/10-ssh-config.sh first"

if $INSTALL_K3S; then
  log "Installing K3s by hand on ${PREFIX}-k3s (through the bastion)"
  on_k3s 'sudo bash -s' < "${REPO_ROOT}/scripts/k3s-install.sh"
fi

log "1/5 Waiting for K3s on the private node (first boot install takes ~1-3 min)"
for i in $(seq 1 40); do
  if on_k3s 'sudo systemctl is-active --quiet k3s && sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready"' 2>/dev/null; then
    ok "K3s is running and the node is Ready"; break
  fi
  if [ "$i" -eq 40 ]; then
    on_k3s true || true   # surfaces SSH errors (e.g. host key, auth) that the loop hid
    warn "K3s not ready. Last startup-script log lines:"
    on_k3s 'sudo journalctl -u google-startup-scripts.service --no-pager | tail -25' || true
    die "fix the cause, or run: $0 --install-k3s"
  fi
  sleep 8
done

log "2/5 Copying the operations kit to bastion:~/airis"
COPYFILE_DISABLE=1 tar -C "${REPO_ROOT}" -czf - k8s helm validator scripts/bastion-setup.sh scripts/30-deploy-db.sh \
    scripts/40-validator-kubeconfig.sh scripts/failover-demo.sh scripts/collect-diagnostics.sh \
  | on_bastion 'mkdir -p ~/airis && tar -xzf - -C ~/airis'
ok "copied"

log "3/5 Installing tools on the bastion (kubectl, helm, psql, python venv)"
on_bastion 'bash ~/airis/scripts/bastion-setup.sh'

log "4/5 Kubeconfig: node -> (pipe) -> bastion, server = https://${K3S_IP}:6443"
on_k3s 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed "s#https://127.0.0.1:6443#https://${K3S_IP}:6443#" \
  | on_bastion 'umask 077; mkdir -p ~/.kube; cat > ~/.kube/config.tmp && grep -q "server: https://" ~/.kube/config.tmp && mv ~/.kube/config.tmp ~/.kube/config && chmod 600 ~/.kube/config' \
  || die "kubeconfig copy failed (the previous ~/.kube/config on the bastion, if any, is untouched)"
ok "kubeconfig installed on the bastion (mode 600, cluster-admin - used for deployment only)"

log "5/5 Proving the path: bastion -> Kubernetes API (private network, TLS)"
on_bastion 'kubectl get nodes -o wide && kubectl get --raw /readyz && echo'
ok "bastion can manage the cluster"

echo
echo "Next:  ssh -F $(ssh_cfg) ${PREFIX}-bastion"
echo "       cd ~/airis && ./scripts/30-deploy-db.sh"
