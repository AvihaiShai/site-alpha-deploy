#!/usr/bin/env bash
# K3S NODE (runs as root). Installs and hardens a single-server K3s.
#
# Two ways to run it (same script):
#   a) Automatically at first boot - Terraform passes it as the GCE startup script.
#      Log: sudo journalctl -u google-startup-scripts.service
#   b) By hand, through the bastion, from the laptop:
#      ssh -F .local/ssh_config airis-k3s 'sudo bash -s' < scripts/k3s-install.sh
#
# Idempotent: if K3s is already running it only prints status.
set -euo pipefail

MD="http://metadata.google.internal/computeMetadata/v1/instance"
md() { curl -fsS --max-time 3 -H 'Metadata-Flavor: Google' "${MD}/$1" 2>/dev/null || true; }

K3S_VERSION="${K3S_VERSION:-$(md attributes/k3s-version)}"
K3S_VERSION="${K3S_VERSION:-v1.35.7+k3s1}"
NODE_IP="${NODE_IP:-$(md network-interfaces/0/ip)}"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"

echo "[k3s-install] version=${K3S_VERSION} node_ip=${NODE_IP}"

# One run at a time (startup script at boot vs a manual run over SSH).
exec 9>/run/k3s-install.lock
flock -w 600 9

# Already installed (e.g. a reboot): just make sure it's started - never re-install,
# which would restart every pod on the node.
if [ -x /usr/local/bin/k3s ] && [ -f /etc/systemd/system/k3s.service ]; then
  systemctl start k3s
  echo "[k3s-install] already installed: $(k3s --version | head -1)"
  k3s kubectl get nodes -o wide 2>/dev/null || true
  exit 0
fi

# 1) Configuration as a file (survives upgrades, easy to review) ---------------
mkdir -p /etc/rancher/k3s
mkdir -p /var/lib/rancher/k3s/server/logs && chmod 700 /var/lib/rancher/k3s/server/logs

cat > /etc/rancher/k3s/config.yaml <<EOF
# Managed by scripts/k3s-install.sh
node-ip: ${NODE_IP}
tls-san:
  - ${NODE_IP}               # API cert valid for the private IP the bastion uses
write-kubeconfig-mode: "0600" # admin kubeconfig readable by root only
disable:
  - traefik                  # no ingress controller: nothing is published
  - servicelb                # no LoadBalancer implementation: nothing is published
secrets-encryption: true     # Kubernetes Secrets encrypted at rest in the datastore
kube-apiserver-arg:          # audit trail of every API call (who did what, when)
  - "audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log"
  - "audit-policy-file=/etc/rancher/k3s/audit-policy.yaml"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
EOF

cat > /etc/rancher/k3s/audit-policy.yaml <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: Metadata   # who/what/when for every request, never request bodies (no secret values)
EOF
chmod 600 /etc/rancher/k3s/config.yaml /etc/rancher/k3s/audit-policy.yaml

# 2) Wait for outbound HTTPS (Cloud NAT can take a minute after creation) ------
for i in $(seq 1 30); do
  if curl -fsS --max-time 5 -o /dev/null https://get.k3s.io; then break; fi
  echo "[k3s-install] waiting for egress via Cloud NAT (${i}/30)"; sleep 10
  [ "$i" -eq 30 ] && { echo "[k3s-install] no egress: check Cloud NAT and the egress firewall"; exit 1; }
done

# 3) Install the pinned version (the installer verifies the binary's sha256) ---
curl -fsSL https://get.k3s.io -o /tmp/k3s-install.sh
INSTALL_K3S_VERSION="${K3S_VERSION}" sh /tmp/k3s-install.sh server

# 4) Wait until the node is Ready ----------------------------------------------
for i in $(seq 1 60); do
  if k3s kubectl get node -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    echo "[k3s-install] node Ready"; break
  fi
  sleep 5
done
k3s kubectl get nodes -o wide
k3s kubectl get pods -A
