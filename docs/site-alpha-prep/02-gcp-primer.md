# 02 · GCP primer: only what this exercise needs, mapped to what you already know

You've configured Check Point / Fortinet / Juniper policies and run OpenShift on-prem. Most of GCP
networking maps onto that knowledge. The differences are listed explicitly below, because that's where people trip.

## 1. Where things live

| GCP concept | Think of it as | Notes |
|---|---|---|
| **Organization → Folders → Project** | Tenant → department → environment | Everything we create lives in **one project** the client gave us |
| **Project** | A billing + permissions + quota boundary | Has an ID (`sector9-airis-123`), used everywhere |
| **API (service)** | A feature switch per project | A new project has Compute **disabled**. First error you'll see: `403 SERVICE_DISABLED` |
| **IAM role** | RBAC role | Granted to a user/group/service account *on* a project/resource. "Limited access" = they gave you a narrow role |
| **Service account (SA)** | A machine identity | A VM with an SA can get OAuth tokens from the metadata server. We attach **none** |
| **Org policy** | A guardrail set by the client above your project | Can forbid external IPs, require OS Login, restrict regions. You can't override it |
| **Quota** | Per-region limits (CPUs, IPs) | New projects sometimes have low limits. `00-preflight.sh` prints them |
| **Region / zone** | Data-centre campus / building | `me-west1` = Tel Aviv, zones `-a/-b/-c`. Subnets are regional, VMs are zonal |

## 2. Networking: the differences that matter

| Topic | On-prem habit | GCP reality |
|---|---|---|
| Scope of a network | VLAN per site | **VPC is global**; **subnets are regional** |
| "Public subnet" | DMZ subnet with NAT/public routing | **There is no public subnet.** A VM is public only if it has an **external IP** (`access_config` in Terraform). Our "bastion subnet" is a logical boundary we chose |
| Default gateway | Router per VLAN | Implicit: every VPC has a route `0.0.0.0/0 → default-internet-gateway`. It only works for VMs **with** an external IP (or via Cloud NAT) |
| Firewall placement | Appliance between zones | **Distributed, enforced at every VM's vNIC.** Rules belong to the VPC, not to a subnet |
| Rule order | Top-down first match | **Priority 0-65535, lower wins.** Same priority: deny beats allow |
| Statefulness | Stateful firewall | Also **stateful**: allow the request and the reply is automatic |
| Default policy | Explicit cleanup rule | **Implied rules at 65535:** deny all ingress, allow all egress. **They don't log**, which is why we add our own logged deny at 65000 |
| Object groups | Address/host objects | **Network tags** (`airis-bastion`) or **service accounts** as source/target |
| SNAT for private hosts | NAT rule on the firewall | **Cloud NAT** (managed, needs a **Cloud Router**). Outbound only |
| Out-of-band | Console server | Serial console. We **disable** it (`serial-port-enable = FALSE`) |

**Tags vs service accounts as firewall targets:** anyone with `compute.instances.setTags` can add a tag to a VM.
Service-account-based rules are harder to spoof. We use tags because we attach no SA. Say this if asked:
*"In production I'd target by service account, and I'd check for org-level hierarchical firewall policies, which are evaluated before VPC rules."*

**Traffic that firewall rules never block:** the VM ↔ **metadata server `169.254.169.254`** (DNS, NTP, metadata, SA tokens).
That's why our K3s egress deny-all doesn't break DNS.

## 3. The services in this design

**Cloud Router + Cloud NAT** (`nat.tf`)
- Cloud Router is a control-plane object (BGP, and the anchor for NAT). No VM, nothing to patch.
- Cloud NAT translates outbound connections from VMs **without** external IPs. Connections can't be initiated from outside.
- We NAT only `snet-private`, plus the bastion subnet in IAP mode, when the bastion has no public IP.
- Logging set to `ERRORS_ONLY`: you'll see port-exhaustion problems.

**Private Google Access** (`private_ip_google_access = true`)
- Lets VMs without external IPs reach Google APIs (e.g. GCS for backups) over Google's network.

**IAP TCP forwarding** (the alternative to a public bastion)
- Google's Identity-Aware Proxy opens a TCP tunnel to port 22 after checking your Google identity and IAM.
- Firewall source must be `35.235.240.0/20`.
- You need the role `roles/iap.tunnelResourceAccessor`.
- `gcloud compute ssh airis-bastion --tunnel-through-iap` or our generated ProxyCommand.
- **Pros:** no public IP, identity-aware, logged. **Con:** depends on IAM setup.

**OS Login** (the alternative to metadata SSH keys)
- Linux accounts and SSH keys come from the user's Google identity.
- Roles: `roles/compute.osLogin` (user) / `roles/compute.osAdminLogin` (sudo).
- Revoke in IAM = access gone everywhere. Supports 2FA. Every login is attributable.
- **Metadata keys:** the guest agent creates the user (with passwordless sudo) from `ssh-keys` metadata. Simple, but the key is shared and not tied to IAM.
- We set `block-project-ssh-keys`, so keys added at project level are ignored.

**Shielded VM**
- Secure Boot + vTPM + integrity monitoring. Protects against boot-level rootkits.
- Free; default-on for most images.

**Metadata server and startup scripts**
- `metadata_startup_script` runs as root at **every boot**. Our script is idempotent.
- Logs: `sudo journalctl -u google-startup-scripts.service`.
- The script reads its settings (`k3s-version`) from the metadata server.

## 4. Org policies you may meet (preflight checks them)

| Constraint | Effect on us | Toggle |
|---|---|---|
| `compute.vmExternalIpAccess` | Bastion can't have a public IP | `bastion_public_ip = false` (IAP) |
| `compute.requireOsLogin` | Metadata SSH keys ignored | `enable_oslogin = true` |
| `gcp.resourceLocations` | Region must be allowed | change `region`/`zone` |
| `compute.requireShieldedVm` | Must be Shielded | already compliant |
| `iam.automaticIamGrantsForDefaultServiceAccounts` | Default SA has no Editor | irrelevant (we attach none) |

## 5. gcloud commands worth having in your fingers

```bash
gcloud auth login && gcloud auth application-default login   # user login + ADC for Terraform
gcloud config set project <PROJECT_ID>
gcloud services list --enabled | grep compute
gcloud services enable compute.googleapis.com

gcloud compute instances list
gcloud compute instances describe airis-k3s-01 --zone me-west1-a --format='yaml(networkInterfaces)'
gcloud compute instances get-serial-port-output airis-k3s-01 --zone me-west1-a | tail -50   # boot problems (read-only)
gcloud compute firewall-rules list --format='table(name,direction,priority,sourceRanges.list(),targetTags.list(),allowed[].map().firewall_rule().list(),denied[].map().firewall_rule().list())'
gcloud compute routers nats describe airis-nat --router airis-router --region me-west1
gcloud compute ssh airis-bastion --zone me-west1-a --tunnel-through-iap         # IAP mode

# Firewall log evidence (blocked attempts):
gcloud logging read 'logName:"compute.googleapis.com%2Ffirewall" AND jsonPayload.disposition="DENIED"' --limit 10 --freshness 1h
```
