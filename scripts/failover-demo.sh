#!/usr/bin/env bash
# BASTION. Unplanned-failover drill: kill the primary pod, measure how long until
# a replica is promoted and the cluster is fully healthy again (an RTO measurement).
#
# Honest scope: one node, so this proves PROCESS-level failover (Postgres crash,
# pod eviction), NOT node or zone failure. That is phase 2 (more nodes / zones).
set -euo pipefail
NS=airis
CLUSTER=airis-core
KC="${KUBECONFIG:-$HOME/.kube/config}"
k() { kubectl --kubeconfig "$KC" -n "$NS" "$@"; }

OLD="$(k get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}')"
echo "Current primary: ${OLD}"
k get pods -L cnpg.io/instanceRole

START=$(date +%s)
echo ">>> $(date +%T) deleting primary pod ${OLD}"
k delete pod "${OLD}" --wait=false

NEW="$OLD"
while [ "$NEW" = "$OLD" ] || [ -z "$NEW" ]; do
  sleep 1
  NEW="$(k get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || true)"
  [ $(( $(date +%s) - START )) -gt 180 ] && { echo "no promotion after 180s"; exit 1; }
done
PROMOTED=$(date +%s)
echo ">>> $(date +%T) new primary: ${NEW}  (promotion after $((PROMOTED-START))s)"

# Don't trust a Ready condition left over from before the failover: wait until all
# instances are ready AND the phase is healthy, polling the live status.
WANT="$(k get cluster "$CLUSTER" -o jsonpath='{.spec.instances}')"
while :; do
  READY="$(k get cluster "$CLUSTER" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo 0)"
  PHASE="$(k get cluster "$CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "${READY:-0}" = "$WANT" ] && echo "$PHASE" | grep -qi healthy && [ $(( $(date +%s) - PROMOTED )) -ge 3 ]; then
    break
  fi
  [ $(( $(date +%s) - START )) -gt 300 ] && { echo "not healthy after 300s: ready=${READY}/${WANT} phase='${PHASE}'"; exit 1; }
  sleep 2
done
DONE=$(date +%s)
echo ">>> $(date +%T) cluster Ready again, old primary rejoined as replica  (total $((DONE-START))s)"
k get pods -L cnpg.io/instanceRole
echo
echo "RTO (write availability) ~ $((PROMOTED-START))s. RPO: async replication -> up to the replication lag at crash time."
