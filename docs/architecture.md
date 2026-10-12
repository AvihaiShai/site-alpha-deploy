# Architecture and decisions

## The picture in one paragraph

A new GCP project gets one custom VPC with two subnets:
- **Bastion subnet:** a small bastion VM with a public IP. It accepts SSH only, and only from the site's egress IP.
- **Private subnet:** one VM with **no public IP**, running K3s. It accepts SSH and the Kubernetes API (6443) **only from the bastion**. Its only outbound access is HTTPS through Cloud NAT, used to download K3s and container images.

Inside K3s, the CloudNativePG operator runs a 3-instance PostgreSQL cluster (1 primary, 2 replicas), TLS-only.
Nothing is published: there's no ingress controller, no LoadBalancer and no NodePort. The bastion reaches Postgres only by tunnelling through the authenticated Kubernetes API. A Python validator on the bastion proves the result and writes the handover report.

## The three traffic paths

**1. Management path:** how a human operates the system.
```
laptop (site IP) --SSH:22--> bastion --SSH:22--> k3s node            (admin shell)
laptop (site IP) --SSH:22--> bastion --TLS:6443--> K3s API server    (kubectl / helm)
```
- Firewall rule `allow-ssh-to-bastion` admits only the site's /32.
- Rule `allow-bastion-to-k3s` admits only sources tagged `airis-bastion`.
- SSH uses ProxyJump: the bastion relays bytes, and the private key never leaves the laptop.

**2. Data path:** how the validator (or an operator) reaches Postgres.
```
bastion: kubectl port-forward svc/airis-core-rw 127.0.0.1:<port>
   └─> rides inside the existing TLS connection to the API server (6443)
       └─> kubelet on the node enters the primary pod's network namespace
           └─> Postgres :5432  (TLS 1.3 again, end-to-end, server cert verified)
```
- Port 5432 is never opened in any firewall.
- To use this path you need a valid Kubernetes identity, RBAC permission `pods/portforward` in namespace `airis`, and an audit log entry is written.
- That's what makes the DB **reachable through approved paths only**.

**3. Egress path:** how the node gets software.
```
k3s node --TCP:443--> Cloud NAT --> github.com / get.k3s.io / ghcr.io / docker.io
```
- Outbound only: nothing on the internet can initiate a connection back.
- Firewall: allow egress 443 (priority 1000), deny and log everything else (priority 65000).
- Phase 2 removes it entirely (private registry + air-gapped install).

## Day 0 / Day 1 / Day 2

| | Meaning here | Where |
|---|---|---|
| Day 0 | Secure infrastructure + bring-up | `terraform/`, `k3s-install.sh`, `20-bootstrap-bastion.sh` |
| Day 1 | Validation, resilience proof, operational confidence | `30-deploy-db.sh`, `validate.py`, `failover-demo.sh` |
| Day 2 (out of scope for phase 1) | Backups/PITR, monitoring/alerting, upgrades, scaling, key rotation | Phase 2 roadmap below |

## Decision record

| # | Decision | Why | Alternative | When I'd change it |
|---|---|---|---|---|
| 1 | Region `me-west1` (Tel Aviv) | Data residency for an Israeli client; lowest latency from site | Any region | Client's org policy `gcp.resourceLocations` or contract says otherwise |
| 2 | Custom VPC, 2 subnets `10.10.0.0/28`, `10.10.1.0/24` | Explicit, minimal; ranges avoid K3s pod/service CIDRs `10.42/16`, `10.43/16`, so routing is never ambiguous | Auto-mode VPC (a subnet in every region, too broad) | Client already has an IP plan / shared VPC |
| 3 | Public bastion restricted to site `/32` | Required: a single, controlled public entry point; simple and fast | **IAP TCP forwarding**: no public IP at all, identity-aware (toggle `bastion_public_ip=false`) | Org policy forbids external IPs, or the client prefers IAP. IAP is recommended for production |
| 4 | One metadata SSH key, `block-project-ssh-keys` | Works with minimal permissions on a new project | **OS Login**: SSH tied to IAM, revocable, audited (toggle) | Production: OS Login + 2FA. Org policy `requireOsLogin` |
| 5 | No service account on either VM | Nothing in phase 1 needs GCP APIs; a stolen VM token is worth nothing | Default compute SA (often has Editor - dangerous) | Phase 2 backups: one SA with access to one GCS bucket |
| 6 | Cloud NAT + egress firewall (443 only) | The node needs images; NAT is outbound-only | Air-gapped: K3s airgap tarball + private Artifact Registry | Production for a Zero Trust client - remove NAT |
| 7 | Explicit **logged** deny-all (in and out) + VPC flow logs | The implied deny is silent; the security team needs evidence of blocked attempts | Implied rules only | Log volume/cost concerns at scale → sampling |
| 8 | Fixed internal IP `10.10.1.10` for the node | kubeconfig, TLS SAN and validator refer to it; survives VM re-create | Ephemeral internal IP | - |
| 9 | **K3s** single server | Real conformant Kubernetes in 1 binary, starts in ~30s, small footprint, works on-prem/air-gapped too | GKE (managed, but more GCP surface, slower, needs more permissions); kubeadm (slow to bootstrap) | Client standardises on GKE, or needs managed upgrades at scale |
| 10 | K3s hardening: no Traefik/ServiceLB, secrets encryption, API audit log, kubeconfig 0600 | Nothing can be published by accident; Secrets encrypted at rest; who-did-what trail | Defaults | - |
| 11 | K3s installed by the VM's startup script (by-hand fallback) | Saves ~10 minutes; same script either way | Ansible / manual | Fleet of nodes → config management or image baking |
| 12 | K8s API reachable from bastion on 6443 | kubectl/helm/validator work natively; still private, still TLS + RBAC | SSH-tunnel 6443 only (one less open port) | Stricter client: tunnel only |
| 13 | DB access via `kubectl port-forward` | No new open port; access governed by K8s identity, RBAC, audit | NodePort + firewall (exposes 5432 on the node); SSH `-L` to ClusterIP | Many app clients outside the cluster → internal LB with firewall |
| 14 | **CloudNativePG** operator | Postgres-native HA (streaming replication, automated failover), TLS, backups, declarative; CNCF project | Plain StatefulSet (you write the failover), Cloud SQL (managed, but outside the cluster/air-gap story), Zalando/Crunchy operators | Client mandates managed DB → Cloud SQL with private IP |
| 15 | 3 instances on 1 node, anti-affinity `preferred` | Demonstrates replication + failover now; same manifest scales to 3 nodes by switching to `required` | 1 instance (no HA story) | Phase 2: ≥3 nodes across zones, `required` anti-affinity |
| 16 | `local-path` storage (K3s built-in) | Zero setup, fast local disk | GCP PD CSI driver (volumes survive node loss, snapshots) | Phase 2 multi-node: PD CSI or replicated storage |
| 17 | TLS-only `pg_hba` (`hostnossl … reject`) + client `verify-full` | Encryption in transit enforced by the server, not left to clients; protects against impersonation | Default CNPG rules (allow non-TLS with password) | - |
| 18 | `enableSuperuserAccess: false` | No remote superuser password exists to leak; admin = `kubectl exec` (audited) | Superuser secret | Break-glass procedure required by the client |
| 19 | Validator: namespace-scoped read-only token (8h), public CA copy in a ConfigMap | Least privilege; the CA private key never leaves its Secret | Run as cluster-admin | - |
| 20 | Local Terraform state | One operator, one session, no bucket exists yet | GCS backend with versioning (native locking) | Immediately after phase 1 - state describes the client's infra |
| 21 | Pinned versions + checksum-verified downloads | Reproducible, supply-chain hygiene | `latest` | Pin images by digest in production |
| 22 | Helm for the operator, plain manifest for the cluster | Operator = third-party software (Helm's strength); cluster = our config, reviewable YAML in Git | Helm `cluster` chart, or GitOps (Argo CD) | Phase 2: Argo CD syncs `k8s/` from Git |

## Assumptions and open questions for the client

| Assumption | Open question |
|---|---|
| The DB stores metadata/intelligence records, not raw video | "Is video stored in object storage and only metadata in Postgres?" (changes sizing by orders of magnitude) |
| Phase 1 can tolerate node loss = restore from backup | "What RPO and RTO do you need?" |
| Data must stay in Israel | "Any data-residency or region constraints?" |
| Internet egress for images is acceptable in phase 1 | "Is outbound internet allowed from the private subnet, even via NAT?" |
| One engineer, one session | "Who operates this after handover? Do you want OS Login / IAP for your team?" |

## Findings to report to the client's security team

- **A `default` VPC exists in a new project.** Enabling the Compute API creates it unless the org policy `compute.skipDefaultNetworkCreation` is set. Its `default-allow-ssh` rule is open to `0.0.0.0/0`. This deployment doesn't use it. Recommendation: the client deletes it. It is not deleted here without their approval. `00-preflight.sh` reports it.
- **Org- or folder-level firewall policies are evaluated before VPC rules** and may change the effective policy. Ask the client for them.

## Phase 2 roadmap

1. **Resilience:** 3 K3s nodes across 3 zones (embedded etcd HA), `required` anti-affinity, PD CSI storage, synchronous quorum replication (RPO 0).
2. **Backups:** Barman Cloud plugin → GCS bucket (versioned, retention lock), scheduled base backups + continuous WAL archiving → point-in-time recovery; **tested restores**.
3. **Zero Trust++:** IAP instead of a public bastion, OS Login + 2FA, private Artifact Registry + air-gapped installs (no NAT), CMEK if mandated.
4. **Operations:** Prometheus + Grafana (CNPG exports metrics on :9187), alerts on replication lag / disk / failover; GitOps (Argo CD) for `k8s/`; Terraform remote state + CI plan/apply.
5. **Scale:** PgBouncer `Pooler`, table partitioning by time for high-volume records, read traffic to `-ro`.
