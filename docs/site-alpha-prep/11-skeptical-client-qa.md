# 11 · The skeptical client: questions and answers

Answer shape: **claim → reason → trade-off or limit**. Two or three sentences. If you don't know, say what you'd check and how.
When they ask about your experience, use **"I operated / I troubleshot / I implemented"** precisely. In the role-play, own the decisions.

## Network and access

**Why is there a public IP at all? Isn't that the opposite of Zero Trust?**
The brief asked for a publicly reachable bastion. So it's the single door: port 22 only, only from this site's /32, logged. For production I'd remove it and use IAP TCP forwarding. That's one variable here (`bastion_public_ip=false`), and I've rehearsed it.

**What stops someone at the site from reaching the database?**
Three layers. They must SSH to the bastion with the engagement key. From there, only 22 and 6443 to the node are open, not 5432. And to get a Postgres session they need a Kubernetes identity with `pods/portforward` in that namespace plus the DB credentials, over TLS. Each layer is logged: firewall logs, SSH auth log, K8s audit log.

**Why open 6443 to the bastion instead of tunnelling it over SSH?**
Simplicity for kubectl, Helm and the validator. It's still private, TLS, RBAC and audited. A stricter variant tunnels 6443 over SSH so only port 22 is open. It's a 1-line firewall change, and I'd do it if you prefer.

**Why can the private node reach the internet?**
It needs the K3s binary and container images. Cloud NAT is outbound-only, and the egress firewall allows only TCP/443; everything else is denied and logged. For production I'd mirror images to a private registry and use K3s's air-gapped install, then remove NAT entirely.

**Firewall rules by network tag: can't anyone add a tag?**
Anyone with `compute.instances.setTags` can, yes. Service-account-based rules are stronger. I didn't attach service accounts to the VMs, to keep them identity-less, so tags were the pragmatic choice. In production: dedicated SAs and SA-based rules, plus a check for org-level firewall policies.

**What if the bastion is compromised?**
- An attacker gets a shell with the admin kubeconfig. That's the biggest residual risk, and I'm naming it.
- They don't get a GCP identity (no SA), they don't get my private key (ProxyJump, no agent forwarding), and their actions are audited.
- Mitigations: short-lived kubeconfigs or none at rest, OS Login + 2FA, IAP, auto-shutdown.

## Kubernetes

**Why K3s and not GKE?**
- K3s is conformant Kubernetes in one binary, up in under a minute on a single VM. The same install runs on-prem and air-gapped, which matters for customer sites.
- GKE is the right choice when you want Google to run the control plane and upgrades at scale. It also brings more GCP surface and permissions.

**Is a single K3s node production-ready?**
No, and I wouldn't call it that. It's phase 1: functional, secure, validated. Phase 2 is three servers across three zones with embedded etcd, network-attached storage and backups.

**How do you know nothing is exposed?**
- There's no ingress controller (Traefik disabled) and no LoadBalancer implementation (ServiceLB disabled).
- Pod Security `baseline` blocks hostNetwork/hostPort.
- The validator proves it from the outside: services are ClusterIP only, 5432 is closed on the node IP, and the pod network isn't routable from the bastion.

**Are Kubernetes Secrets safe here?**
Encrypted at rest in the datastore (`secrets-encryption`), readable only through RBAC, with every access in the audit log. The validator can read exactly one Secret. In production I'd consider an external secrets manager.

## Database

**Why an operator? Why not a StatefulSet?**
- A StatefulSet gives you stable pods and volumes, but nothing knows Postgres. You'd write failover, replica bootstrap, TLS and backups yourself.
- CloudNativePG does that declaratively: it promotes the most advanced replica, moves the `-rw` service, and rejoins the old primary as a replica.

**Three instances on one node is fake HA, isn't it?**
It's real HA for process-level failures (crash, OOM, eviction), and I'll demonstrate it. It's not protection against losing the VM or disk; I say that explicitly. Moving to real node/zone HA needs more nodes, required anti-affinity and network storage. The manifest is already shaped for it.

**What's your RPO and RTO?**
- **RTO:** measured in the failover demo, seconds to tens of seconds for a process failure.
- **RPO:** replication is asynchronous in phase 1, so a primary crash can lose the last few milliseconds of commits. With three nodes I'd enable quorum synchronous replication for RPO 0 on committed data.
- **Node loss:** RPO/RTO depend on backups, which are phase 2. I'd want your target numbers before go-live.

**How is data encrypted?**
- **In transit:** TLS 1.3, enforced by the server (`hostnossl … reject`); the validator proves a plaintext login is refused; replication uses certificate authentication.
- **At rest:** Google encrypts persistent disks by default; CMEK if you require your own keys.

**Who can log in as superuser?**
Nobody over the network: superuser access is disabled. Admin work goes through `kubectl exec` with RBAC and audit, e.g. `kubectl cnpg psql`.

**How did you size it? / How would you size it for us?**
Phase 1 is sized for bring-up. For production: rows/day × row size × index and bloat factors × retention, ×instances, plus WAL. Memory from the working set, CPU from Little's law, then validate with pgbench. Worked example in [07](../site-alpha-deploy/docs/db-sizing.md).

**What about backups?**
- Not in phase 1, and I'd block go-live on them.
- **Plan:** Barman Cloud plugin to a versioned GCS bucket, daily base backups + continuous WAL archiving → point-in-time recovery, and a scheduled restore test.

**How do you upgrade Postgres or the operator?**
- **Minor versions:** change `imageName`. CNPG rolls the replicas, then switches over the primary.
- **Operator:** `helm upgrade` with a pinned chart, after reading the release notes.
- **Major Postgres versions:** CNPG supports declarative in-place major upgrades in recent versions, or logical-replication migration to a new cluster. Either way I'd rehearse on a clone first.

## Terraform and operations

**Where is the Terraform state?**
On this laptop, for a one-session bring-up, and that's a risk I'm handing over. Next step: a GCS backend with versioning and locking, restricted IAM. Then delete the local copy.

**How would you run this for 20 customers?**
- A versioned module plus one root config and state per customer.
- CI running `plan` on every change and `apply` with approval; scheduled drift detection.
- A supported-versions matrix to stop customer-specific versions from multiplying. That's the real maintenance cost.

**A plan shows `-/+` on the K3s VM. What do you do?**
Stop. Replace means the VM and its local Postgres data get destroyed. Find which attribute forces replacement (Terraform marks it), avoid it or plan a migration. In production, `prevent_destroy` on stateful resources.

**Your apply failed halfway. Now what?**
Read the error, fix the cause, re-run. Everything that succeeded is in state; Terraform converges rather than duplicating.

## About AI and your code

**You used AI for this. How do I know you understand it?**
Pick any line. Each file has comments explaining why. The validator's logic flow, failure points and security implications are written up, and I tested it against a real primary/replica setup in eight scenarios, including ones that must fail.

**What would make this script fail?**
Expired token, missing RBAC for port-forward, the CA ConfigMap missing, the cert lacking the service name (it then downgrades to verify-ca and *says so*), a lagging replica, or running it from the wrong host. It reports every one of these distinctly.
