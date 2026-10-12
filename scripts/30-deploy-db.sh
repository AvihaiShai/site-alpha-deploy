#!/usr/bin/env bash
# BASTION. Deploys the data layer:
#   1. CloudNativePG operator via Helm (pinned chart -> operator 1.30.1)
#   2. Namespace with Pod Security labels
#   3. The Postgres cluster "airis-core" (3 instances, TLS-only)
#   4. A public copy of the cluster CA certificate (validator never needs the CA private key)
#   5. Least-privilege RBAC for the validator
# Idempotent: re-running converges to the same state.
set -euo pipefail
cd "$(dirname "$0")/.."

NS=airis
CLUSTER=airis-core
CHART_VERSION="${CHART_VERSION:-0.29.1}"   # cloudnative-pg chart 0.29.1 = operator 1.30.1

log() { printf '\033[1;34m[%s deploy]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

log "1/6 CNPG operator via Helm (chart ${CHART_VERSION})"
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update >/dev/null
helm repo update cnpg >/dev/null
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace \
  --version "${CHART_VERSION}" \
  --values helm/cnpg-operator-values.yaml \
  --wait --timeout 5m
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg --timeout=180s
kubectl wait --for=condition=Established crd/clusters.postgresql.cnpg.io --timeout=60s

log "2/6 Namespace '${NS}' (Pod Security: enforce baseline, warn/audit restricted)"
kubectl apply -f k8s/00-namespace.yaml

log "3/6 Postgres cluster '${CLUSTER}'"
# The operator's admission webhook can need a few seconds after the Deployment
# reports Ready - retry instead of failing on 'connection refused'.
for i in 1 2 3 4 5 6; do
  if kubectl apply -f k8s/10-airis-core-cluster.yaml; then break; fi
  [ "$i" -eq 6 ] && { echo "apply failed 6 times - check: kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg"; exit 1; }
  log "webhook not ready yet, retry ${i}/6 in 10s"; sleep 10
done

log "4/6 Waiting for the cluster to become Ready (image pull + initdb + 2 replicas, ~2-5 min)"
if ! kubectl -n "${NS}" wait "cluster/${CLUSTER}" --for=condition=Ready --timeout=10m; then
  echo "Not Ready in 10 minutes. Diagnose with:"
  echo "  kubectl -n ${NS} get pods,pvc ; kubectl -n ${NS} describe cluster ${CLUSTER}"
  echo "  ./scripts/collect-diagnostics.sh"
  exit 1
fi
kubectl -n "${NS}" get cluster "${CLUSTER}"
kubectl -n "${NS}" get pods -L cnpg.io/instanceRole -o wide

log "5/6 Publishing the CA *certificate* (not the key) for clients and the validator"
kubectl -n "${NS}" get secret "${CLUSTER}-ca" -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.crt
kubectl -n "${NS}" create configmap "${CLUSTER}-ca-public" --from-file=ca.crt=/tmp/ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/ca.crt

log "6/6 Validator identity (read-only + port-forward, namespace-scoped)"
kubectl apply -f k8s/30-validator-rbac.yaml

log "Done. Next: ./scripts/40-validator-kubeconfig.sh && .venv/bin/python validator/validate.py --kubeconfig ~/.kube/validator.kubeconfig"
