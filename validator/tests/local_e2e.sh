#!/usr/bin/env bash
# End-to-end test of validate.py WITHOUT Kubernetes or GCP.
#
# Builds a real PostgreSQL primary + streaming replica on 127.0.0.1 with the same
# security posture as the CNPG cluster (TLS 1.3 only, SCRAM, hostnossl reject,
# certificate SANs = the CNPG service names), then runs the validator through
# fake_kubectl.py in several scenarios and asserts the exit codes.
#
# Needs: PostgreSQL server binaries (initdb, pg_ctl, pg_basebackup), openssl, python3.
# Run as a NON-root user (Postgres refuses to run as root), e.g.:
#   sudo -u postgres bash validator/tests/local_e2e.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VALIDATOR="${HERE}/../validate.py"
FAKE="${HERE}/fake_kubectl.py"
WORK="${WORK:-/tmp/airis-e2e}"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
export PATH="${PGBIN}:${PATH}"
PRIMARY_PORT=5433
REPLICA_PORT=5434     # replica 1 (behind the fake -ro service)
REPLICA2_PORT=5435    # replica 2 (3 instances in total, like the CNPG cluster)
NODE_IP=127.0.0.3
APP_PW="$(openssl rand -hex 16)"
REPL_PW="$(openssl rand -hex 16)"

cleanup() {
  pg_ctl -D "${WORK}/replica2" -m fast stop >/dev/null 2>&1 || true
  pg_ctl -D "${WORK}/replica" -m fast stop >/dev/null 2>&1 || true
  pg_ctl -D "${WORK}/primary" -m fast stop >/dev/null 2>&1 || true
  [ -n "${LISTENER_PID:-}" ] && kill "${LISTENER_PID}" 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "${WORK}"; mkdir -p "${WORK}"; cd "${WORK}"

echo "== Python venv with the validator's single dependency"
python3 -m venv venv >/dev/null
venv/bin/pip install -q -r "${HERE}/../requirements.txt"

echo "== Test PKI: CA + server cert with the CNPG service names as SANs"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=airis-core-ca" \
  -keyout ca.key -out ca.crt 2>/dev/null
SAN=""
for s in rw ro r; do
  SAN="${SAN}DNS:airis-core-${s},DNS:airis-core-${s}.airis,DNS:airis-core-${s}.airis.svc,"
done
openssl req -newkey rsa:2048 -nodes -subj "/CN=airis-core-rw" -keyout server.key -out server.csr 2>/dev/null
printf 'subjectAltName=%s\n' "${SAN%,}" > san.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 \
  -extfile san.ext -out server.crt 2>/dev/null
chmod 600 server.key

echo "== Primary on :${PRIMARY_PORT}"
initdb -D primary -U postgres --auth-local=trust --data-checksums --encoding=UTF8 --locale=C >/dev/null
cat >> primary/postgresql.conf <<EOF
port = ${PRIMARY_PORT}
listen_addresses = '127.0.0.1'
unix_socket_directories = '${WORK}'
ssl = on
ssl_cert_file = '${WORK}/server.crt'
ssl_key_file = '${WORK}/server.key'
ssl_min_protocol_version = 'TLSv1.3'
wal_level = replica
max_wal_senders = 5
hot_standby = on
EOF
cat > primary/pg_hba.conf <<EOF
local     all          all                      trust
hostssl   replication  replicator  127.0.0.1/32 scram-sha-256
hostnossl all          all         all          reject
hostssl   all          all         all          scram-sha-256
EOF
pg_ctl -D primary -l primary.log -w start >/dev/null
psql -h "${WORK}" -p ${PRIMARY_PORT} -U postgres -qAt <<EOF
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '${REPL_PW}';
CREATE ROLE airis WITH LOGIN PASSWORD '${APP_PW}';
CREATE DATABASE airis OWNER airis;
EOF

for spec in "replica:${REPLICA_PORT}" "replica2:${REPLICA2_PORT}"; do
  dir="${spec%%:*}"; port="${spec##*:}"
  echo "== ${dir} on :${port} (pg_basebackup over TLS, streaming)"
  PGPASSWORD="${REPL_PW}" PGSSLMODE=require pg_basebackup -h 127.0.0.1 -p ${PRIMARY_PORT} \
    -U replicator -D "${dir}" -R -X stream >/dev/null
  echo "port = ${port}" >> "${dir}/postgresql.conf"
  pg_ctl -D "${dir}" -l "${dir}.log" -w start >/dev/null
done
sleep 2
echo "   replicas streaming: $(psql -h "${WORK}" -p ${PRIMARY_PORT} -U postgres -qAt -c \
  "select count(*) from pg_stat_replication where state='streaming'")"

echo "== Fake K8s API listener on ${NODE_IP}:6443 (the 'approved path' port)"
python3 -c "
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('${NODE_IP}',6443)); s.listen(5)
while True:
    c,_=s.accept(); c.close()
" & LISTENER_PID=$!
sleep 1

export FAKE_PRIMARY_PORT=${PRIMARY_PORT} FAKE_REPLICA_PORT=${REPLICA_PORT} \
       FAKE_CA_FILE="${WORK}/ca.crt" FAKE_APP_PASSWORD="${APP_PW}" FAKE_NODE_IP=${NODE_IP}

run_case() {  # $1 name, $2 expected exit code, $3 scenario, rest = extra validator args
  local name="$1" expect="$2" scenario="$3"; shift 3
  echo
  echo "################ CASE: ${name} (scenario=${scenario}, expect exit ${expect})"
  set +e
  FAKE_SCENARIO="${scenario}" venv/bin/python "${VALIDATOR}" --kubectl "${FAKE}" --kubeconfig /dev/null \
    --probe-timeout 1 --report "${WORK}/report-${name}.json" "$@"
  local rc=$?
  set -e
  if [ "${rc}" -eq "${expect}" ]; then echo ">>> CASE ${name}: OK (exit ${rc})"
  else echo ">>> CASE ${name}: UNEXPECTED exit ${rc} (wanted ${expect})"; FAILED=1; fi
}

FAILED=0
run_case happy              0 happy
run_case nodeport-exposed   1 nodeport
run_case ca-fallback        0 no-cm
run_case least-privilege    0 forbidden-operator
run_case degraded-cluster   1 degraded
run_case hostname-mismatch  0 happy --namespace other-ns

echo
echo "== Case: CNPG's default rule only ('host all all all scram-sha-256', no TLS-only rule) -> must FAIL"
sed -i 's/^hostnossl.*/host all all all scram-sha-256/' primary/pg_hba.conf
pg_ctl -D primary reload >/dev/null; sleep 1
run_case plaintext-accepted 1 happy --read-only

echo
echo "== Case: a replica goes down -> replication check must FAIL"
sed -i 's/^host all all all scram-sha-256/hostnossl all all all reject/' primary/pg_hba.conf
pg_ctl -D primary reload >/dev/null
pg_ctl -D replica2 -m fast stop >/dev/null; sleep 2
run_case replica-down 1 happy

echo
if [ "${FAILED}" -eq 0 ]; then echo "ALL CASES BEHAVED AS EXPECTED"; else echo "SOME CASES FAILED"; exit 1; fi
