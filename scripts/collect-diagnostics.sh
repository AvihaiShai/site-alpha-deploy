#!/usr/bin/env bash
# BASTION. One command that gathers everything needed to debug the data layer
# into a timestamped folder (a "support bundle"). No secret values are collected.
set -uo pipefail
NS=airis
CLUSTER=airis-core
OUT="${HOME}/diag-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
run() { local f="$1"; shift; echo "\$ $*" > "$OUT/$f"; "$@" >> "$OUT/$f" 2>&1; }

run 00-nodes.txt            kubectl get nodes -o wide
run 01-all-pods.txt         kubectl get pods -A -o wide
run 02-events-airis.txt     kubectl -n $NS get events --sort-by=.lastTimestamp
run 03-cluster.yaml         kubectl -n $NS get cluster $CLUSTER -o yaml
run 04-describe-cluster.txt kubectl -n $NS describe cluster $CLUSTER
run 05-pods-pvc-svc.txt     kubectl -n $NS get pods,pvc,svc,endpoints -o wide
run 06-describe-pods.txt    kubectl -n $NS describe pods -l cnpg.io/cluster=$CLUSTER
for p in $(kubectl -n $NS get pods -l cnpg.io/cluster=$CLUSTER -o name 2>/dev/null); do
  n="${p#pod/}"
  run "10-log-$n.txt"          kubectl -n $NS logs "$n" --tail=300
  run "11-log-previous-$n.txt" kubectl -n $NS logs "$n" --previous --tail=300
done
run 20-operator-log.txt     kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg --tail=500
run 21-operator-events.txt  kubectl -n cnpg-system get events --sort-by=.lastTimestamp
run 22-storageclass.txt     kubectl get storageclass
command -v kubectl-cnpg >/dev/null && run 30-cnpg-status.txt kubectl cnpg status $CLUSTER -n $NS --verbose

tar -czf "${OUT}.tgz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo "Support bundle: ${OUT}.tgz"
echo "Quick look:  grep -iE 'error|fail|oom|denied|backoff' -r $OUT | head -40"
