#!/usr/bin/env bash
# BASTION. Installs the operator toolbox. Idempotent - safe to re-run.
# Every download is pinned and checksum-verified (supply-chain hygiene).
set -euo pipefail

K8S_MINOR="${K8S_MINOR:-1.35}"        # kubectl within +/-1 minor of the API server
HELM_VERSION="${HELM_VERSION:-v4.3.0}"
CNPG_PLUGIN_VERSION="${CNPG_PLUGIN_VERSION:-v1.30.1}"   # match the operator
KIT="${HOME}/airis"
ARCH=amd64

log() { printf '\033[1;34m[bastion-setup]\033[0m %s\n' "$*"; }

log "OS packages: python3-venv, postgresql-client (psql), jq, netcat"
# First boot: unattended-upgrades may hold the apt lock - wait for it instead of failing.
for i in 1 2 3 4 5 6; do
  sudo apt-get -o DPkg::Lock::Timeout=120 update -qq && break
  log "apt busy, retry ${i}/6"; sleep 10
done
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq \
  python3-venv postgresql-client jq netcat-openbsd curl ca-certificates tar >/dev/null

if ! command -v kubectl >/dev/null 2>&1; then
  KVER="$(curl -fsSL "https://dl.k8s.io/release/stable-${K8S_MINOR}.txt")"
  log "kubectl ${KVER} (sha256-verified)"
  cd /tmp
  curl -fsSLO "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl"
  curl -fsSLO "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl.sha256"
  echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check --quiet
  sudo install -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl kubectl.sha256
fi

if ! command -v helm >/dev/null 2>&1; then
  log "helm ${HELM_VERSION} (sha256-verified)"
  cd /tmp
  TGZ="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  curl -fsSLO "https://get.helm.sh/${TGZ}"
  curl -fsSLO "https://get.helm.sh/${TGZ}.sha256sum"
  sha256sum --check --quiet "${TGZ}.sha256sum"
  tar -xzf "${TGZ}" "linux-${ARCH}/helm"
  sudo install -m 0755 "linux-${ARCH}/helm" /usr/local/bin/helm
  rm -rf "${TGZ}" "${TGZ}.sha256sum" "linux-${ARCH}"
fi

if ! command -v kubectl-cnpg >/dev/null 2>&1; then
  log "kubectl cnpg plugin ${CNPG_PLUGIN_VERSION} (optional - nice status view)"
  curl -fsSL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh \
    | sudo sh -s -- -b /usr/local/bin "${CNPG_PLUGIN_VERSION}" >/dev/null 2>&1 \
    || log "cnpg plugin not installed (optional) - kubectl get cluster works without it"
fi

# Python: Debian 12 blocks system-wide 'pip install' (PEP 668, "externally managed
# environment"). A virtualenv keeps the validator's dependencies isolated.
if [ ! -x "${KIT}/.venv/bin/python" ]; then
  log "Python venv for the validator"
  python3 -m venv "${KIT}/.venv"
fi
"${KIT}/.venv/bin/pip" install -q --upgrade pip
"${KIT}/.venv/bin/pip" install -q -r "${KIT}/validator/requirements.txt"

chmod +x "${KIT}"/scripts/*.sh 2>/dev/null || true

log "Versions:"
kubectl version --client 2>/dev/null | head -1
helm version --short
psql --version
"${KIT}/.venv/bin/python" -c 'import psycopg, sys; print("python", sys.version.split()[0], "psycopg", psycopg.__version__)'
