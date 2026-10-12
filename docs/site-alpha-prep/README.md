# Site Alpha: private prep kit (do NOT clone this onto their laptop)

Two folders, two purposes:

| Folder | What | Where it goes |
|---|---|---|
| `site-alpha-deploy/` | The engineering deliverable: Terraform, scripts, manifests, validator, neutral docs | Private GitHub repo → cloned at their office |
| `site-alpha-prep/` (this) | Your study kit: primers, talk tracks, Q&A drill, blind spots, prompts | Your machine / this Claude project only |

**The goal is not to memorise the repo.** It is to stand in the room and explain *why* every line exists,
change it live, and debug calmly when something breaks. The brief: *"If you can't explain the code, it's not your code."*

## The 4 sentences you should be able to say without notes

1. *"There is exactly one way in: SSH to a bastion, only from this site's IP. The database node has no public IP and only accepts SSH and the Kubernetes API from the bastion."*
2. *"I never open Postgres on the network. The bastion reaches it through the Kubernetes API, which is authenticated, RBAC-authorised and audited, and the connection itself is TLS 1.3 with certificate verification."*
3. *"The data layer is a CloudNativePG cluster: one primary and two streaming replicas with automated failover. On one node that protects against process failure. Node and zone failure is phase 2, and the design already has the hooks for it."*
4. *"The validator is the handover artifact. It proves what must work and what must NOT work, runs with a read-only 8-hour identity, and its report contains no secrets."*

## Study plan (≈14 hours, hard cap 16)

| # | Session | Read | Do | Hours |
|---|---|---|---|---|
| 1 | Foundations | [architecture](../site-alpha-deploy/docs/architecture.md), [GCP primer](02-gcp-primer.md) | Install tools ([12](12-tool-installation.md)). Create your own GCP project with billing and a **$10 budget alert** | 2 |
| 2 | Infra by hand | [Terraform](03-terraform-walkthrough.md), [SSH](04-ssh-and-bastion.md) | `00-preflight` → `plan` → `apply` in your project, SSH through the bastion, `destroy`. Then apply again from zero | 3 |
| 3 | Platform + data | [K3s](05-k3s.md), [CNPG](06-cnpg-and-postgres.md), [validator](../site-alpha-deploy/docs/validator.md) | Full chain to `READY FOR HANDOVER`, failover demo. Then **break things** with the [failure-injection tests](../site-alpha-deploy/docs/troubleshooting.md) | 3 |
| 4 | Talk track | [DB sizing](../site-alpha-deploy/docs/db-sizing.md), [Q&A](11-skeptical-client-qa.md) | Present the slides out loud 3 times with a timer. Answer the Q&A without looking | 2 |
| 5 | Dress rehearsal | [onsite plan](10-onsite-plan.md) | 90 minutes on the clock, **new project**, fresh clone, no shell history | 2.5 |
| 6 | Drills | [troubleshooting](../site-alpha-deploy/docs/troubleshooting.md), [blind spots](13-blind-spots.md) | 5 injected failures, diagnosed out loud in < 5 min each. 20-minute skeptical-client drill with an AI ([prompts](14-better-prompts.md)) | 1.5 |

**Checkpoint after session 3:** you've gone from an empty project to `READY FOR HANDOVER` once.
If not, cut scope rather than adding hours: architecture + Terraform + K3s + troubleshooting first.

## Rehearsing on your own GCP account

- **Cost:**
  - In me-west1, e2-standard-4 is about $0.15/h and e2-small about $0.02/h.
  - NAT and flow logs add cents.
  - About $0.25/h while running, a few dollars in total.
- **Always finish with `terraform -chdir=terraform destroy`.** Then check the console that nothing is left.
- **Budget alert:** Billing → Budgets & alerts → $10, with email at 50/90/100%.
- **Use a new project for the dress rehearsal.** It reproduces "brand-new project" problems (APIs disabled, nothing cached).
- **Rehearse IAP mode once** (`bastion_public_ip = false`) and the **by-hand K3s install** once (`k3s_bootstrap_via_startup_script = false`, then `20-bootstrap-bastion.sh --install-k3s`). They may ask you to show the SSH install.

## Memorise vs. read from the repo

| Memorise (you'll be asked) | Read from the repo (nobody expects recall) |
|---|---|
| The architecture story and the 4 sentences | Exact Terraform argument names |
| The 3 traps: no public IP = no internet (NAT); K3s CIDRs 10.42/10.43; Postgres is ClusterIP | Chart / image versions |
| Firewall logic: stateful, priority, tags, implied rules | CNPG field names |
| Debugging ladder: get → describe → events → logs → logs --previous | kubectl jsonpath |
| The sizing method | Postgres parameters beyond shared_buffers / work_mem |
| Validator: logic flow, failure points, security implications | |

## Using AI on the day (explicitly allowed)

- **Use it for speed:** syntax, flags, error lookups, small edits.
- **Before pasting anything,** say what it does and what could break it. That's what they're testing.
- **Phrase it like:** *"I'll let the assistant draft this loop; what I need is X; the failure mode I'm watching for is Y."*
- **Never let AI "fix" an error you haven't read yourself.**
