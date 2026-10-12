# Deployment runbook

Sequence, expected durations and checkpoints for a full bring-up from an empty GCP project.
Machine time ≈ 25 minutes. Allow 60-75 minutes end to end for reviews and checks.

## Inputs

| Input | Source | Used in |
|---|---|---|
| GCP project ID | client | `PROJECT_ID`, `terraform.tfvars` |
| Operator identity with Compute admin rights on the project | client | `gcloud auth login`, ADC |
| Site egress IP | `curl -4 ifconfig.me` (preflight) | `allowed_ssh_cidrs` |
| Org-policy constraints (external IP, OS Login, locations) | preflight / client | `bastion_public_ip`, `enable_oslogin`, `region` |
| Is egress via NAT allowed? | client | `restrict_k3s_egress`; air-gap path if not |

## 1. Preflight (laptop, ~3 min)

```bash
gcloud auth login && gcloud auth application-default login
PROJECT_ID=<id> ./scripts/00-preflight.sh
```
**Checkpoint:**
- all 8 steps show OK, or WARN with a known toggle;
- `terraform/terraform.tfvars` exists;
- the SSH CIDR equals the site's /32.

## 2. Infrastructure (laptop, ~3 min apply)

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan -out=tfplan      # expect: 14 to add, 0 to change, 0 to destroy
terraform -chdir=terraform apply tfplan
terraform -chdir=terraform output
```
**Checkpoint:** outputs show `bastion_public_ip` (or empty in IAP mode) and `k3s_internal_ip = 10.10.1.10`.

## 3. Access path (laptop, ~1 min)

```bash
./scripts/10-ssh-config.sh
```
**Checkpoint:** "bastion reachable" and "k3s node reachable through the bastion".

## 4. K3s + bastion toolbox (laptop, ~4 min)

```bash
./scripts/20-bootstrap-bastion.sh            # add --install-k3s if k3s_bootstrap_via_startup_script = false
```
**Checkpoint:**
- the node shows `Ready` in `kubectl get nodes` **run on the bastion**;
- `/readyz` returns `ok`.

## 5. Data layer (bastion, ~4 min)

```bash
ssh -F .local/ssh_config airis-bastion
cd ~/airis && ./scripts/30-deploy-db.sh
```
**Checkpoint:**
- `kubectl -n airis get cluster airis-core` shows `Cluster in healthy state` and READY `3`;
- one pod has `cnpg.io/instanceRole=primary`.

## 6. Validation and handover report (bastion, ~1 min)

```bash
./scripts/40-validator-kubeconfig.sh
.venv/bin/python validator/validate.py --kubeconfig ~/.kube/validator.kubeconfig
```
**Checkpoint:** `READY FOR HANDOVER`, exit code 0, report written to `~/airis/reports/`.

## 7. Resilience proof (bastion, ~2 min)

```bash
./scripts/failover-demo.sh
.venv/bin/python validator/validate.py --read-only
```
**Checkpoint:**
- a new primary is promoted (promotion time printed);
- the cluster returns to `Ready`;
- the validator is green again.

## 8. Optional hardening (bastion)

```bash
kubectl apply -f k8s/optional/20-networkpolicy.yaml
kubectl -n airis get pods -w                   # all must stay 1/1 READY
.venv/bin/python validator/validate.py --read-only
# rollback: kubectl delete -f k8s/optional/20-networkpolicy.yaml
```

## Fallbacks

| Situation | Action |
|---|---|
| No bash on the operator laptop | Google Cloud Shell; add its egress IP to `allowed_ssh_cidrs`, or use IAP mode |
| Org policy forbids external IPs | `bastion_public_ip = false` (IAP); needs `roles/iap.tunnelResourceAccessor` |
| Org policy requires OS Login | `enable_oslogin = true`; sudo needs `roles/compute.osAdminLogin` |
| Missing permission for API enablement | Owner enables `compute.googleapis.com`; set `enable_apis = false` |
| K3s egress blocked | Verify NAT; temporarily `restrict_k3s_egress = false` to isolate the cause |
| No internet egress allowed at all | Air-gap path: K3s binary + airgap images and container images staged via a private Artifact Registry / GCS (phase 2 work) |
| Quota / capacity | `k3s_machine_type = "e2-standard-2"`, `instances: 2`, or another zone |
| PostgreSQL image tag unavailable | Remove `imageName` from the Cluster manifest (operator default image) |

## Teardown and handover

1. Agree with the client: keep the environment (hand over the Terraform state, ideally into a GCS backend) or `terraform -chdir=terraform destroy`.
2. Hand over the validation report from `~/airis/reports/`.
3. Remove operator credentials from the laptop: `./scripts/99-cleanup-laptop.sh`.
