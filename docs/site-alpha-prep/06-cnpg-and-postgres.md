# 06 · CloudNativePG and PostgreSQL HA

## 1. The operator pattern (you already know it from OpenShift)

An **operator** = a **CRD** (a new Kubernetes object type) + a **controller** that reconciles it.
- You declare `kind: Cluster` with `instances: 3`.
- The controller runs a loop: *observe → compare to the spec → act*. It creates pods, volumes, certificates, users and services, and it performs failover.
- OpenShift itself is built from operators (OLM). CNPG works the same way, installed via Helm instead of OLM.

**CNPG specifics worth saying:**
- **No StatefulSet.** CNPG manages pods and PVCs directly, so it controls the order of operations exactly (replicas first, then switchover of the primary).
- **No external HA tool** (no Patroni, no etcd for leader election).
  - Each Postgres pod runs CNPG's **instance manager** as PID 1. It reports health on port 8000 and executes the operator's decisions.
  - From 1.30, a Kubernetes `Lease` gates primary promotion.
- **A CNCF project** (Sandbox). Version 1.30.1 here supports Kubernetes 1.34–1.36 and PostgreSQL 14–18.

## 2. What `kubectl apply -f k8s/10-airis-core-cluster.yaml` creates

| Object | Name | Purpose |
|---|---|---|
| Pods | `airis-core-1/-2/-3` | 1 primary + 2 replicas. Label `cnpg.io/instanceRole=primary\|replica` |
| PVCs | `airis-core-N` (data) + `airis-core-N-wal` | One data + one WAL volume per instance (local-path) |
| Service | `airis-core-rw` | → the **primary** (read/write). Moves automatically on failover |
| Service | `airis-core-ro` | → **replicas only** (read-only) |
| Service | `airis-core-r` | → any instance (read) |
| Secret | `airis-core-app` | App user `airis`: username, password, dbname, uri… |
| Secret | `airis-core-ca` | Cluster CA (cert **and private key**) |
| Secret | `airis-core-server`, `-replication` | Server cert; client cert used by replicas (**cert auth**, no password) |
| PodDisruptionBudgets | per role | Prevent a drain from evicting the primary carelessly |
| ConfigMap (ours) | `airis-core-ca-public` | CA **certificate only**, published by `30-deploy-db.sh` for clients |

**TLS is on by default:**
- Server certificates are signed by the cluster's own CA.
- `ssl_min_protocol_version = TLSv1.3` by default.
- Replication between instances uses **client certificates**.

## 3. PostgreSQL replication in 6 lines

1. Every change is first written to the **WAL** (write-ahead log). WAL is the source of truth for durability.
2. Replicas connect to the primary and **stream WAL** continuously (*streaming replication*), replaying it (*hot standby*, read-only).
3. **Async (our phase 1):** the primary confirms a commit when *its own* WAL is flushed. A replica may be a few ms behind.
   → **RPO > 0**: a primary crash can lose the last few ms of commits.
4. **Sync (phase 2):** the commit waits for ≥1 replica. RPO = 0 for committed data, at the cost of write latency.
   - If no replica is available: `dataDurability: required` blocks writes; `preferred` falls back to async.
5. **Failover:**
   - the primary fails;
   - the operator picks the **most advanced replica** (by received WAL position) and promotes it;
   - it moves `-rw` to it;
   - the old primary comes back **as a replica**, resynced with `pg_rewind` if needed.
   - **RTO** = seconds to tens of seconds. `failover-demo.sh` measures it.
6. **Split brain** (two primaries) is prevented because:
   - promotion only happens through the operator, gated by the Lease;
   - the old primary is fenced/demoted before it may accept writes again;
   - clients only ever reach the primary through the `-rw` Service, which the operator controls.

## 4. The manifest, line by line (`k8s/10-airis-core-cluster.yaml`)

| Field | Value | Why / what to say |
|---|---|---|
| `instances` | 3 | Primary + 2 replicas: survives one instance failure and still has a replica to promote |
| `imageName` | `…postgresql:18.6-system-trixie` | PostgreSQL 18.6, the operator's default image, **pinned**. Production: pin by digest / ImageCatalog |
| `primaryUpdateStrategy` | unsupervised | Upgrades: replicas first, then automatic switchover. `supervised` = a human triggers the switchover |
| `enableSuperuserAccess` | false | No remote `postgres` password exists. Admin = `kubectl exec` (audited) |
| `bootstrap.initdb` | db `airis`, owner `airis`, `dataChecksums: true` | App DB + user created at init; checksums detect silent disk corruption |
| `postgresql.parameters` | shared_buffers 256MB… | Sized for a 1 GiB container (see [07](../site-alpha-deploy/docs/db-sizing.md)) |
| `pg_hba` | `hostnossl all all all reject` + `hostssl … scram-sha-256` | **TLS-only.** CNPG inserts our lines before its default `host all all all scram-sha-256`, which would otherwise accept non-TLS. Match `all` addresses: port-forward traffic arrives from 127.0.0.1 inside the pod |
| `storage` / `walStorage` | local-path 10Gi / 4Gi | Separate WAL volume: a WAL spike can't fill the data volume. **local-path doesn't enforce sizes**: watch node disk |
| `resources` | requests = limits (500m, 1Gi) | **Guaranteed QoS**: last to be evicted. Memory limit = the hard ceiling Postgres must fit in |
| `affinity` | anti-affinity `preferred` | One node → all 3 may co-locate. Phase 2: `required` + 3 nodes |
| (monitoring) | none | No Prometheus Operator yet. Metrics are already exposed on :9187; phase 2 adds a PodMonitor (the `enablePodMonitor` field is deprecated in 1.30) |
| commented `synchronous`, `plugins` | phase 2 | Quorum sync replication; Barman Cloud plugin backups |

## 5. Honest HA statement (say exactly this)

> *"Three instances on one node give me process-level resilience. A Postgres crash, OOM or pod
> eviction fails over in seconds, and I'll demonstrate it. They do **not** protect against losing the VM or
> its disk: all three copies are on the same disk. Phase 2 is three nodes across three zones with
> network-attached volumes and backups to GCS. The manifest only needs `podAntiAffinityType: required`
> and a different storage class."*

## 6. Backups and PITR (phase 2, be able to explain)

- **Barman Cloud plugin**. The in-tree `barmanObjectStore` is deprecated and removed in CNPG 1.31.
  - Install the plugin; define an `ObjectStore` pointing to a GCS bucket.
  - Set `plugins: [{name: barman-cloud.cloudnative-pg.io, isWALArchiver: true}]`.
- **Base backups:** `ScheduledBackup`, e.g. daily. **WAL archiving:** continuous.
  → **Point-in-time recovery** to any second within retention, by bootstrapping a *new* cluster from the backup with `recoveryTarget`.
- **Bucket:** versioning + retention lock, a dedicated SA with access to that bucket only, Workload Identity rather than keys.
- **A backup you haven't restored is a hope, not a backup.** Schedule restore tests.

## 7. Failure modes and what happens

| Failure | Behaviour | Our evidence |
|---|---|---|
| Primary Postgres crashes / pod deleted | Replica promoted, `-rw` moves, old primary rejoins | `failover-demo.sh` |
| A replica dies | Primary unaffected; `-ro` serves from the remaining replica; replica rebuilt | validator `db.replication` |
| OOMKilled (memory limit too low vs settings) | Restarts → CrashLoopBackOff | `kubectl describe pod` → `Last State: OOMKilled` |
| WAL volume full | Postgres stops accepting writes | separate WAL volume + monitoring |
| Node disk full | Everything on the node suffers | local-path ignores sizes → monitor `df` |
| Node/VM lost | **Full outage**, data only as good as backups (phase 2) | stated honestly |
| Operator down | Running databases keep running; no failover/reconcile until it's back | `k8s.operator` check |
| Bad parameter in the CR | Webhook rejects it at apply time (1.30 validates parameter names) | apply error message |

## 8. Commands (on the bastion)

```bash
kubectl -n airis get cluster airis-core                  # PHASE, READY, PRIMARY
kubectl -n airis get pods -L cnpg.io/instanceRole -o wide
kubectl cnpg status airis-core -n airis                  # plugin: replication, lag, WAL, certs
kubectl cnpg promote airis-core airis-core-2 -n airis    # planned switchover
kubectl cnpg psql airis-core -n airis                    # psql as postgres via exec (audited)
kubectl -n airis logs airis-core-1 | tail                # JSON logs from the instance manager
kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg | tail
kubectl -n airis describe cluster airis-core             # Conditions + Events
```

SQL worth knowing:
```sql
SELECT pg_is_in_recovery();                              -- false on primary, true on replica
SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication;  -- needs pg_monitor/superuser for details
SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid();
SELECT pg_size_pretty(pg_database_size('airis'));
SELECT sum(blks_hit)*100.0/nullif(sum(blks_hit+blks_read),0) AS cache_hit_pct FROM pg_stat_database;
```
