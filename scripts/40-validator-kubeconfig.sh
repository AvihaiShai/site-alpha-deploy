#!/usr/bin/env bash
# BASTION. Builds ~/.kube/validator.kubeconfig: a SHORT-LIVED token for the
# airis-validator ServiceAccount (read-only + port-forward in namespace airis).
# The handover script then runs with least privilege, not as cluster-admin.
set -euo pipefail

NS=airis
SA=airis-validator
DURATION="${DURATION:-8h}"
OUT="${HOME}/.kube/validator.kubeconfig"

TOKEN="$(kubectl -n "${NS}" create token "${SA}" --duration="${DURATION}")"
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

umask 077
cat > "${OUT}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: airis
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA_DATA}
users:
- name: ${SA}
  user:
    token: ${TOKEN}
contexts:
- name: ${SA}@airis
  context:
    cluster: airis
    user: ${SA}
    namespace: ${NS}
current-context: ${SA}@airis
EOF

echo "wrote ${OUT} (token valid ${DURATION})"
echo "What this identity can do:"
kubectl --kubeconfig "${OUT}" auth can-i --list -n "${NS}" | head -20
echo "Can it read secrets cluster-wide? $(kubectl --kubeconfig "${OUT}" auth can-i list secrets -A 2>/dev/null || true)"
