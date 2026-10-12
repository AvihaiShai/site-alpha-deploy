# 03 · Terraform: concepts, file-by-file walkthrough, failure handling

## 1. The mental model (5 ideas)

1. **Declarative:** you describe the end state (*"a VPC with these two subnets"*). Terraform computes the steps.
2. **Provider:** a plugin that translates resources into API calls. Here: `hashicorp/google`.
3. **State** (`terraform.tfstate`): Terraform's record of *what it created and the IDs*. On each `plan`:
   - it compares **config ↔ state ↔ real world (refresh)**;
   - then shows a diff: `+` create, `~` update in place, `-/+` replace, `-` destroy.
4. **Dependency graph:** references like `google_compute_network.vpc.id` create edges.
   - Terraform creates in dependency order, in parallel where it can.
   - `depends_on` adds an edge only where no reference exists (e.g. "API enabled before anything").
5. **Idempotent:** running `apply` twice changes nothing the second time. That's also how you **recover** from a failed apply: fix the cause, re-run, and Terraform continues from where it stopped.

## 2. The commands and what to say while they run

| Command | What it does | Say |
|---|---|---|
| `terraform init` | Downloads the provider version allowed by `versions.tf`, sets up the backend | "Pinned to google provider 7.x, so this behaves the same on any machine." |
| `terraform fmt -recursive` / `validate` | Formatting / static validation | "Catch typos before touching the cloud." |
| `terraform plan -out=tfplan` | Computes the diff, saves it | "I read the plan before applying. It's the change-review step. Expect 14 to add (1 API, VPC, 2 subnets, 1 address, router, NAT, 5 firewall rules, 2 VMs), 0 change, 0 destroy." |
| `terraform apply tfplan` | Applies **exactly** the saved plan | "Applying the reviewed plan, not a recomputed one." |
| `terraform output` | Prints outputs (IPs, names) | The scripts consume these |
| `terraform state list` / `state show <addr>` | Inspect what's tracked | Debugging |
| `terraform apply -replace=google_compute_instance.k3s` | Force re-create of one resource | E.g. startup script broke the VM |
| `terraform destroy` | Delete everything in state | **Only when the client asks** |

## 3. File-by-file walkthrough

### `versions.tf`
- `required_version >= 1.5`. Provider `~> 7.0` = any 7.x, never 8.0. That's the reproducibility argument.
- The commented `backend "gcs"` block is the production answer to *"where's your state?"*:
  - a GCS bucket with **versioning** (roll back a corrupted state);
  - **native locking**, so two people can't apply at the same time.

### `providers.tf`
- `project/region/zone` defaults for every resource.
- `default_labels` stamps `managed-by=terraform, environment, component` on everything that supports labels. Cheap governance: the client can find everything we created with one filter.

### `variables.tf`
**What to point out:**
- `allowed_ssh_cidrs` has a **validation block**: every entry must be a real CIDR and `0.0.0.0/0` is refused. *"The code itself won't let anyone open SSH to the world."*
- Ranges `10.10.0.0/28`, `10.10.1.0/24`: comment explains they avoid K3s's `10.42/16` and `10.43/16`.
- **Toggles for org policies:** `bastion_public_ip` (IAP mode), `enable_oslogin`, `restrict_k3s_egress`, `enable_apis`, `k3s_bootstrap_via_startup_script`. *"I designed for the client's constraints I couldn't know in advance."*

### `apis.tf`
- `google_project_service` with `for_each` over a set: compute always; IAP and OS Login APIs only if those modes are on.
- `disable_on_destroy = false`. Never switch off an API for the whole project on destroy, because other teams may depend on it.

### `network.tf`
- `auto_create_subnetworks = false`: custom mode, so only our two subnets exist.
- `depends_on = [google_project_service.apis]`: the API must be on before the first network call.
- `dynamic "log_config"`: a `dynamic` block emits a nested block 0..n times. Here, flow logs on/off by variable.
- `private_ip_google_access = true`: reach Google APIs without an external IP.
- `google_compute_address.k3s_internal`: `cidrhost("10.10.1.0/24", 10)` = `10.10.1.10`. A fixed internal IP, so the TLS SAN and kubeconfig stay valid if the VM is re-created.

### `nat.tf`
- `google_compute_router` (the anchor) + `google_compute_router_nat`.
- `LIST_OF_SUBNETWORKS`: NAT **only** the private subnet (plus the bastion subnet in IAP mode, via a `dynamic "subnetwork"` block).
- `AUTO_ONLY`: Google allocates the NAT IP(s). Production alternative: `MANUAL_ONLY` with reserved IPs, so the client can allowlist your egress at partners.

### `firewall.tf`
Read it with the rule numbers:
1. **Ingress 22 → bastion tag**, from `allowed_ssh_cidrs` (or the IAP range). Logged. It has a `lifecycle.precondition`: plan fails with a clear message if the list is empty.
2. **Ingress 22 + 6443**, source tag bastion → target tag k3s. *"5432 is not here, on purpose."*
3. **Deny all ingress at 65000, logged**: makes the silent implied deny visible.
4. **Egress:** allow TCP 443 from the k3s tag at 1000; deny all at 65000, logged.

### `compute.tf`
- `locals.ssh_keys_value`: `user:key` when using metadata keys, empty when OS Login is on.
- `metadata` map on both VMs:
  - `block-project-ssh-keys`: ignore keys others add at project level;
  - `serial-port-enable = FALSE`: no interactive serial console;
  - `enable-oslogin`: TRUE or FALSE, by variable;
  - `ssh-keys`: the one engagement key.
- **Bastion:**
  - `dynamic "access_config"` gives it a public IP only in public-bastion mode;
  - `shielded_instance_config` is on;
  - **no `service_account` block**, so no identity is attached.
- **K3s VM:**
  - `network_interface` has **no `access_config`**, so it has no external IP;
  - `network_ip` is pinned;
  - `metadata_startup_script = file("../scripts/k3s-install.sh")` when bootstrapping automatically;
  - `depends_on = [google_compute_router_nat.nat]`, because the script needs the internet at first boot.
  - `lifecycle { ignore_changes = [metadata_startup_script] }`: editing the script must NOT re-create the node, because that would wipe the local Postgres data. Script changes after creation are applied by hand with `20-bootstrap-bastion.sh --install-k3s`.
- `#checkov:skip=…` lines: accepted findings from the security scanner, each with its reason written in the code.

### `outputs.tf`
- IPs, names, mode flags, and a `next_steps` text.
- `try(...access_config[0].nat_ip, "")` returns an empty string in IAP mode instead of failing.

## 4. When `apply` fails (it will, at least once, in a brand-new project)

**Method:**
1. Read the error out loud: resource address + HTTP code + reason.
2. Hypothesis.
3. Fix the cause.
4. Re-run `plan`, then `apply`.

Resources created before the failure are already in state, so nothing is duplicated.

| Error contains | Cause | Fix |
|---|---|---|
| `SERVICE_DISABLED` / `has not been used in project` | Compute API off or just enabled (it takes 1-2 min to propagate) | `gcloud services enable compute.googleapis.com`, wait, re-apply |
| `403 Required 'compute.xxx' permission` | Your role is too narrow | Read which permission is missing, then ask the POC (that *is* the FDE move) or drop the feature (e.g. `enable_apis=false`) |
| `Constraint constraints/compute.vmExternalIpAccess violated` | Org policy | `bastion_public_ip=false` → IAP mode |
| `Quota 'CPUS' exceeded` / `ZONE_RESOURCE_POOL_EXHAUSTED` | Quota / capacity | Smaller type (`e2-standard-2` + 2 instances) or another zone (`me-west1-b`) |
| `The resource ... already exists` | Name clash (an earlier attempt, or someone else's) | `terraform import <addr> <id>`, or change `name_prefix` |
| `Invalid value for field ... ipCidrRange` / overlaps | CIDR typo or overlap | Fix the variable |
| `no such file` for the SSH key | Key path wrong | `ls ~/.ssh/airis_fde.pub`, fix `ssh_public_key_path` |
| Image not found | Image family name | `gcloud compute images list --filter=family~debian` |
| `Error acquiring the state lock` | (remote backend) another run, or a crashed one | Wait / `terraform force-unlock <id>` only if you're sure |

**Partial apply:** say *"State recorded everything that succeeded; I fix the cause and re-apply. Terraform converges, it doesn't duplicate."*

## 5. Questions you'll get about Terraform at scale (answers in [11](11-skeptical-client-qa.md))

**"How would you deploy this for 20 customers with different versions?"**
Use a reusable **module** (this repo's `terraform/` becomes `modules/site`), plus:
- one **root configuration + one state per customer**, in GCS;
- versions pinned per customer via a module version tag;
- a CI pipeline running `plan` on every change and `apply` with approval;
- drift detection on a schedule (`plan` must show no changes);
- the honest part: customer-specific *versions* are a release-management problem, so I'd reduce variance with a supported-versions matrix.

**"Workspaces?"**
Fine for identical environments. For customers with different inputs and lifecycles, separate state per customer is clearer and safer.

**"Is the state sensitive?"**
Yes. It contains IPs, resource IDs and sometimes secrets. Store it encrypted with restricted IAM. Never commit it: it's in `.gitignore`.
