# Database sizing method

Sizing is a method, not a number: collect the workload inputs, estimate storage, memory, CPU and I/O,
then validate the estimate with a load test and real telemetry.

## Step 0: inputs to collect from the client

| Question | Why it matters |
|---|---|
| What is stored: metadata/records, or media? | Video belongs in object storage; Postgres holds metadata. **Orders of magnitude** difference |
| Ingest rate (rows/s) at peak, and average row size? | Storage growth, WAL volume, write IOPS |
| Retention: how long is data kept? Any deletion/archival policy? | Total size; partitioning strategy |
| Read pattern: dashboards, ad-hoc analyst queries, APIs? Peak concurrent users? | Memory (working set), CPU, connections |
| RPO / RTO? | Sync vs async replication, backup frequency, number of replicas |
| Growth over 12 months? | Headroom; when to scale |

## Step 1: storage

```
raw_per_day  = rows_per_day × avg_row_bytes
with_indexes = raw_per_day × (1 + index_ratio)          # index_ratio 0.3–1.0 (more indexes → higher)
with_bloat   = with_indexes × 1.2–1.5                   # MVCC dead tuples, fillfactor, fragmentation
data_size    = with_bloat × retention_days
volume_size  = data_size × 1.3–1.5                      # headroom: vacuum, reindex, upgrades, growth
total_disk   = volume_size × instances                  # every replica holds a FULL copy
```

**WAL volume:**
- WAL generated ≈ 1-3× the data write rate (full-page writes after checkpoints).
- Size the WAL disk for WAL produced between archives/checkpoints, plus `wal_keep_size`, plus headroom for a lagging replica.
- That's why it's a **separate volume**: a WAL spike can't fill the data disk.

**Backups:** sized in object storage, not on the node. Base backups × retention + all WAL in the window.

## Step 2: memory

- **Working set:** the hot tables + indexes queried regularly should fit in RAM (shared_buffers + OS page cache).
  - Target **cache hit ratio > 99%** for OLTP.
- **`shared_buffers` ≈ 25% of the container memory limit.** The OS page cache uses most of the rest.
- **`effective_cache_size` ≈ 50–75%** of the limit. It's a planner hint, not an allocation.
- **`work_mem`** is per sort/hash *operation*, per connection.
  - Worst case ≈ `work_mem × operations_per_query × active_connections`.
  - Keep it modest and raise it per session for heavy reports.
- **Connections:** each backend costs ~5–10 MB+. Hundreds of connections → put **PgBouncer** in front (CNPG `Pooler` resource) instead of raising `max_connections`.

## Step 3: CPU

**Little's law:** concurrency = arrival rate × time in system.
```
active_queries ≈ peak_QPS × avg_query_seconds
vCPU            ≈ active_queries (CPU-bound) × 1.3–2  (headroom, autovacuum, replication, checkpoints)
```
Example: 400 QPS × 5 ms = **2 concurrent queries** → 2–4 vCPU is ample.
Analysts running 2-second queries: 10 users × 1 query each = **10 concurrent** → ~10+ vCPU, or a read replica for them.

## Step 4: disk performance (GCP specifics)

- Write rate drives WAL fsyncs and checkpoint I/O.
- On GCP, **Persistent Disk performance scales with disk size and the VM's vCPU count**. Sometimes you provision a *bigger* disk to get IOPS, not space.
- `pd-balanced` is the default; `pd-ssd` or Hyperdisk for heavy write loads.
- **Local SSD is ephemeral:** never use it for the only copy of data.

## Step 5: validate, don't guess

1. `pgbench` with a custom script resembling the real workload (read/write mix).
2. Watch:
   - `pg_stat_statements` (top queries);
   - cache hit ratio;
   - `pg_stat_replication` lag;
   - checkpoint frequency;
   - disk growth per day;
   - connection count.
3. Re-size after a week of real traffic. In Kubernetes:
   - CPU/memory = edit `resources` (rolling restart, replicas first);
   - storage = expand the PVC, if the storage class supports it.

## Worked example (illustrative numbers)

Assume 20 million records/day at ~500 bytes each:

- **Raw:** 10 GB/day.
- **With indexes and bloat (×1.5 × 1.3):** ~20 GB/day.
- **90-day retention:** ~1.8 TB live, ~2.4 TB per instance with headroom, ~7 TB across 3 instances.
- **At this volume:** partition by day, so retention is a `DROP PARTITION` instead of a slow `DELETE`.
- **Memory:** the hot set (last 2-3 days + indexes, ~60 GB) should fit in memory, so 64-128 GB RAM per instance.

Phase 1 uses 10 Gi data / 1 GiB RAM because it is a functional bring-up, not a production load.
The calculation is re-run with the client's real figures before go-live.

## How our phase-1 numbers were derived

| Setting | Value | Reasoning |
|---|---|---|
| Memory limit | 1 GiB / instance | Bring-up, not load; 3 instances fit with headroom on 16 GB |
| `shared_buffers` | 256 MB | 25% of 1 GiB |
| `effective_cache_size` | 768 MB | ~75% of 1 GiB |
| `work_mem` | 4 MB | Default-ish; 100 connections × a few ops stays well under 1 GiB |
| `max_connections` | 100 | Pooler beyond that |
| CPU | 0.5 vCPU (requests = limits) | Guaranteed QoS; 1.5 vCPU for 3 instances on a 4 vCPU node |
| Data / WAL volume | 10 Gi / 4 Gi | Placeholder; node disk is 50 GB; local-path doesn't enforce |
