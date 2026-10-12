# Troubleshooting playbook

**Method:**
1. Read the error in full.
2. State a hypothesis.
3. Confirm it with one command.
4. Fix, then re-run.

Timebox each problem (~8 minutes). Past that, take the documented fallback and record a follow-up.

## The Kubernetes debugging ladder (always in this order)

```bash
kubectl -n airis get pods -o wide                 # what state? which node? restarts?
kubectl -n airis describe pod <pod>               # Events at the bottom: scheduling, pulls, probes, OOM
kubectl -n airis get events --sort-by=.lastTimestamp | tail -20
kubectl -n airis logs <pod>                       # current container
kubectl -n airis logs <pod> --previous            # the crashed one (CrashLoopBackOff!)
kubectl -n airis get pvc                          # Pending volumes?
kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg | tail -50   # what the operator thinks
./scripts/collect-diagnostics.sh                  # everything above, into one bundle
```

## Pod states → meaning → first move

| State | Means | First move |
|---|---|---|
| `Pending` | Not scheduled | `describe` → `Insufficient cpu/memory` (smaller requests or bigger VM) or PVC `Pending` (storage class name) |
| `ContainerCreating` (long) | Pulling image / mounting volume | `describe` events: pull progress or mount error |
| `ImagePullBackOff` / `ErrImagePull` | Can't fetch the image | No egress (NAT/firewall), wrong tag, registry rate limit. On the node: `curl -sI https://ghcr.io` |
| `CrashLoopBackOff` | Starts then exits, repeatedly | `logs --previous` + `describe` → `Last State: Terminated, Reason: OOMKilled / Error, Exit Code` |
| `Running` but `0/1 READY` | Readiness probe failing | `describe` → probe message; CNPG: instance still recovering/catching up |
| `Init:Error` | Init container failed | `logs <pod> -c <init-container>` |

**CrashLoopBackOff, the CNPG-specific causes:**

| `logs --previous` / `describe` shows | Cause | Fix |
|---|---|---|
| `OOMKilled`, exit 137 | Memory limit too small for `shared_buffers` + connections | Raise `resources.limits.memory`, or lower `shared_buffers` |
| `invalid value for parameter` | Bad `postgresql.parameters` (1.30's webhook catches many at apply time) | Fix the value, re-apply |
| `No space left on device` | WAL or data volume / node disk full | `df -h` on the node; expand; find the WAL cause (stuck replica slot, archiving failure) |
| `could not open file ... Permission denied` | Volume permissions | local-path is fine by default; check custom storage |
| `pg_hba.conf rejects connection` in **replica** logs | A pg_hba rule broke replication | Our rules keep CNPG's fixed `hostssl replication streaming_replica` lines first, so this shouldn't happen. Check the custom lines |

## Phase by phase

### Preflight / gcloud
| Symptom | Fix |
|---|---|
| `gcloud: command not found` | [12](tool-installation.md), or use **Cloud Shell** (see the egress-IP caveat below) |
| `Reauthentication required` / `invalid_grant` | `gcloud auth login` and `gcloud auth application-default login` |
| Terraform: `could not find default credentials` | ADC missing: `gcloud auth application-default login` |
| Project not found | Wrong ID (`gcloud projects list`) or no permission |

### Terraform

A failed `apply` is recoverable. Resources that succeeded are recorded in state, so after fixing the cause, `plan` + `apply` continues from there without duplicating anything.

| Error contains | Cause | Fix |
|---|---|---|
| `SERVICE_DISABLED` / `has not been used in project` | Compute API off, or just enabled (1-2 min to propagate) | `gcloud services enable compute.googleapis.com`, wait, re-apply |
| `403 Required 'compute.xxx' permission` | Role too narrow | Identify the missing permission; request it from the project owner, or disable the feature (e.g. `enable_apis=false`) |
| `Constraint constraints/compute.vmExternalIpAccess violated` | Org policy | `bastion_public_ip=false` → IAP mode |
| `Quota 'CPUS' exceeded` / `ZONE_RESOURCE_POOL_EXHAUSTED` | Quota / capacity | Smaller machine type (`e2-standard-2` + 2 instances) or another zone (`me-west1-b`) |
| `The resource ... already exists` | Name clash with an earlier attempt | `terraform import <addr> <id>`, or change `name_prefix` |
| `Invalid value for field ... ipCidrRange` / overlap | CIDR typo or overlap | Fix the variable |
| `no such file` for the SSH key | Key path | `ls ~/.ssh/airis_fde.pub`, fix `ssh_public_key_path` |
| Image not found | Image family name | `gcloud compute images list --filter=family~debian` |
| Plan shows `-/+` (replace) on `google_compute_instance.k3s` | An attribute that forces re-creation changed | **Stop:** replacing the node destroys local Postgres data. Find the forcing attribute in the plan output |

### SSH

| Message | Meaning | Fix |
|---|---|---|
| `Connection timed out` | Firewall drop: source IP ≠ `allowed_ssh_cidrs` (**Cloud Shell's egress IP differs from the office's**), VM down, or **the site blocks outbound TCP 22** (common in corporate networks; a web proxy can also make `curl` show a different IP than SSH uses) | `curl -4 ifconfig.me` vs `terraform.tfvars`; `gcloud compute instances list`; if the site blocks 22 → IAP mode (`bastion_public_ip=false`, tunnel over 443) |
| `Permission denied (publickey)` | Wrong user/key, key not yet on the VM, or OS Login enforced | Check `User`/`IdentityFile`; wait ~30 s after creation; `enable-oslogin` metadata |
| `Connection refused` | VM up, sshd not listening yet | Wait; check serial output |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | VM re-created (new host key), or MITM | If re-created: `rm .local/known_hosts`; otherwise investigate |
| `UNPROTECTED PRIVATE KEY FILE` | Key permissions | `chmod 600 ~/.ssh/airis_fde` |
| `administratively prohibited` | sshd forbids TCP forwarding on the bastion | `AllowTcpForwarding yes` |

### K3s install
| Symptom | Check | Fix |
|---|---|---|
| `20-bootstrap-bastion.sh` waits forever | `on node: journalctl -u google-startup-scripts` | Read the last lines |
| `waiting for egress via Cloud NAT` loops | `gcloud compute routers nats describe ...`, egress rules | NAT config, or `restrict_k3s_egress=false` to rule out the egress firewall |
| `k3s.service` failed | `journalctl -u k3s` | YAML error in `/etc/rancher/k3s/config.yaml`, audit policy path |
| kubectl on bastion: `x509 ... not 10.10.1.10` | `tls-san` missing | Fix config, `systemctl restart k3s` |
| kubectl on bastion: `i/o timeout` | Firewall rule 2 / wrong IP in kubeconfig | `nc -vz 10.10.1.10 6443` from the bastion |
| kubectl: `Unauthorized` | Wrong/expired kubeconfig | Re-copy (`20-bootstrap-bastion.sh` step 4) |

### CNPG deploy
| Symptom | Fix |
|---|---|
| `helm`: `failed to download` | Bastion has no internet (IAP mode → NAT must include bastion subnet) |
| `apply`: `failed calling webhook ... connection refused` | Operator not ready yet: the script retries; else check operator logs |
| `no matches for kind "Cluster"` | CRDs not installed: Helm install failed. Re-run step 1 |
| Cluster stuck `Setting up primary` | `kubectl -n airis get pods` → the `initdb` job pod's logs; image pull? |
| `ImagePullBackOff` on `postgresql:18.6-system-trixie` | Tag issue: **delete the `imageName` line** (operator default) and re-apply |
| Pods `Pending`, `Insufficient cpu` | VM smaller than planned: `instances: 2`, or lower requests |
| PVC `Pending` | `kubectl get sc`: must be `local-path` |

### Validator
See the failure-points table in [08](validator.md#failure-points-and-what-youd-see).

## Failure-injection tests (run in a sandbox project to verify detection and recovery)

| # | Inject | Expected symptom |
|---|---|---|
| 1 | `allowed_ssh_cidrs = ["1.2.3.4/32"]` → apply | SSH timeout to bastion |
| 2 | Comment out the `google_compute_router_nat` resource → apply (new VM) | K3s install waits for egress forever |
| 3 | `chmod 644 ~/.ssh/airis_fde` | `UNPROTECTED PRIVATE KEY FILE` |
| 4 | Cluster `resources.limits.memory: 300Mi` with `shared_buffers: 256MB` | OOMKilled → CrashLoopBackOff |
| 5 | `storageClass: standard` | PVC Pending |
| 6 | Cluster `imageName: …:99.9` | ImagePullBackOff |
| 7 | Remove the `hostnossl … reject` line | validator `db.no_plaintext FAIL` |
| 8 | `kubectl -n airis delete pod <primary>` | failover; validator green again |
