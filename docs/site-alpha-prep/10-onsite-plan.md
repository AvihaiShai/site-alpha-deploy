# 10 · Onsite runbook: minute by minute

## The day before

- [ ] Final dress rehearsal done (`READY FOR HANDOVER` at least twice, once from a **new** project).
- [ ] Repo access works from **someone else's machine**: read-only token or public neutral mirror (see [13](13-blind-spots.md)).
- [ ] Slides exported to **PDF**, on a USB stick **and** in your email.
- [ ] **Printed:** one page with the 4 sentences ([00](README.md)), the 3 traps, the debugging ladder, the 10 commands below.
- [ ] Charged laptop + charger (in case you may use yours), USB-C/HDMI adapter.
- [ ] Ask Ziv (if not answered yet): laptop OS + preinstalled tools, internet, AI access, GCP role, office egress IP, bringing a repo.

## Arrival (before the clock starts): 3 clarifying questions, asked as the FDE

Ask them as the "client" questions. They show FDE thinking and they change the design:
1. *"Is outbound internet from the private subnet acceptable via NAT for phase 1, or do you require air-gapped?"*
2. *"What's in this database: metadata only, with media in object storage? Rough volume and retention?"*
3. *"Are there org policies I should know about: external IPs, OS Login, allowed regions?"*

## 0-5 min: architecture (the slides)

One slide per minute; finish with assumptions + phase 2. Don't read the slides. Tell the story of the three traffic paths.

## 5-12 min: environment + preflight

```bash
git clone <repo> && cd site-alpha-deploy
gcloud auth login && gcloud auth application-default login
PROJECT_ID=<id> ./scripts/00-preflight.sh          # enables Compute API early, checks org policies, egress IP
cat terraform/terraform.tfvars                      # read it aloud: "SSH only from <ip>/32"
```
**While it runs, say:** *"I check org policies and quotas first, because a brand-new project fails in predictable ways. Enabling the Compute API takes a minute or two, so I start it now."*

## 12-25 min: Terraform

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan -out=tfplan        # walk the plan: 14 to add
terraform -chdir=terraform apply tfplan
```
**While it applies (~2-3 min), open `firewall.tf` and walk rules 1-4.**
Then `nat.tf`: *"No public IP means no internet at all, so NAT is outbound-only and the egress rule allows 443 only."*

## 25-35 min: SSH through the bastion + K3s

```bash
./scripts/10-ssh-config.sh                          # tests laptop→bastion and laptop→bastion→node
cat .local/ssh_config                               # explain ProxyJump vs agent forwarding
ssh -F .local/ssh_config airis-k3s 'sudo cat /etc/rancher/k3s/config.yaml; sudo k3s kubectl get nodes'
./scripts/20-bootstrap-bastion.sh
```
**Say:** *"K3s installed itself at first boot from the same script I could run by hand. The config file disables anything that could publish a service, encrypts Secrets at rest and writes an API audit log."*

## 35-55 min: CNPG + Postgres

```bash
ssh -F .local/ssh_config airis-bastion
cd ~/airis && ./scripts/30-deploy-db.sh
kubectl -n airis get pods -L cnpg.io/instanceRole -w     # Ctrl-C when 3/3 Running
```
**While images pull, open `k8s/10-airis-core-cluster.yaml`:**
- TLS-only pg_hba (and the 127.0.0.1 port-forward subtlety);
- Guaranteed QoS;
- `preferred` anti-affinity on one node;
- WAL on its own volume;
- the honest HA statement ([06 §5](06-cnpg-and-postgres.md#5-honest-ha-statement-say-exactly-this)).

**Sizing question will likely come here** → [07](../site-alpha-deploy/docs/db-sizing.md), worked example.

## 55-75 min: validation (the handover artifact)

```bash
./scripts/40-validator-kubeconfig.sh                     # show 'auth can-i --list': read-only
.venv/bin/python validator/validate.py --kubeconfig ~/.kube/validator.kubeconfig
```
Walk the output section by section: path → health → exposure (**negatives**) → database (TLS, plaintext rejected, replication, round trip).
Then the AI-policy three: logic flow, failure points, security implications ([08](../site-alpha-deploy/docs/validator.md)).

## 75-85 min: resilience demo

```bash
./scripts/failover-demo.sh                               # prints promotion time (RTO)
.venv/bin/python validator/validate.py --read-only       # green again, new primary
```
**Say:** *"That's process-level failover. Node or zone failure is phase 2."*

## 85-90 min: wrap-up (say all four)

1. *What's done:* "Day 0 and Day 1 complete; here is the report file."
2. *What I'd do next:* the phase-2 list (backups/PITR, multi-zone, IAP + OS Login, air-gap, monitoring, GitOps).
3. *Risks I'm handing over:* local Terraform state, admin kubeconfig on the bastion, single node.
4. *Teardown?* "Do you want me to destroy, or hand over the state?"

## Fallback rules (decide in advance, not under stress)

| If… | Then… |
|---|---|
| Their laptop can't run bash | Google **Cloud Shell** (terraform/gcloud/kubectl/helm preinstalled). Add Cloud Shell's egress IP to `allowed_ssh_cidrs`, **or** use IAP mode |
| GitHub is blocked / can't authenticate | USB copy, or the zip in your email, or re-type from the printout (Terraform is ~300 lines; prioritise `firewall.tf`, `nat.tf`, `compute.tf`) |
| Terraform blocked > 8 min on permissions | Show the plan, explain the missing permission, ask the POC. That's the real-world move |
| Org policy forbids external IP | `bastion_public_ip = false` → IAP mode (rehearsed) |
| K3s egress problem > 8 min | `restrict_k3s_egress = false` to isolate the cause, then explain |
| CNPG image tag fails | Remove `imageName` (operator default) |
| VM too small / quota | `instances: 2` and/or `e2-standard-2`, and say why |
| Time is running out | Skip NetworkPolicy and the least-privilege token; **never skip the validator** (run `--read-only` if needed) |

## The 10 commands to print

```bash
terraform -chdir=terraform plan -out=tfplan && terraform -chdir=terraform apply tfplan
ssh -F .local/ssh_config airis-bastion | airis-k3s
sudo journalctl -u google-startup-scripts.service --no-pager | tail -40
sudo journalctl -u k3s --no-pager | tail -60
kubectl -n airis get cluster,pods,pvc -o wide
kubectl -n airis describe pod <pod>      # Events!
kubectl -n airis logs <pod> --previous
kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg | tail -50
kubectl cnpg status airis-core -n airis
.venv/bin/python validator/validate.py --kubeconfig ~/.kube/validator.kubeconfig
```
