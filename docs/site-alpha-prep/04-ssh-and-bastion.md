# 04 · SSH and the bastion pattern

## Why a bastion at all

A bastion (jump host) gives the network **one door**. That door is small, hardened, logged, and
the only thing the internet can reach. Everything valuable sits behind it with no public address.
If the client wants to cut access, they stop one VM or remove one firewall rule.

## Keys: the 60-second refresher

- `ssh-keygen -t ed25519 -f ~/.ssh/airis_fde -C fde@site-alpha` creates two files.
  - The **private key** stays on the laptop (mode `600`, or ssh refuses it: *"UNPROTECTED PRIVATE KEY FILE"*).
  - The `.pub` goes into VM metadata. The guest agent writes it to `~fde/.ssh/authorized_keys` and grants sudo.
- **ed25519:** modern, short, fast. RSA ≥ 3072 is also fine.
- **One key per engagement.** Delete it afterwards (`99-cleanup-laptop.sh`).
- **Host keys:** the *server* proves its identity too.
  - `StrictHostKeyChecking accept-new` trusts the first connection and **refuses if the key ever changes** (possible MITM, or a re-created VM).
  - We use a separate `known_hosts` file under `.local/`, so we never pollute the borrowed laptop.

## The three ways to "hop", and why we pick one

| Pattern | How | Risk |
|---|---|---|
| **ProxyJump / `ssh -W`** (ours) | Laptop opens SSH to bastion, asks it to relay a TCP stream to `10.10.1.10:22`, then runs a **second, end-to-end SSH session** inside it | Bastion sees only encrypted bytes. **Private key never leaves the laptop.** |
| Agent forwarding (`ssh -A`) | Bastion can ask your laptop's agent to sign | Anyone with root on the bastion can use your agent while you're connected. **Avoid** (`ForwardAgent no`) |
| Copy the private key to the bastion | Two separate sessions | Key now lives on a shared, internet-facing box. **Never** |

Our generated config (`.local/ssh_config`):

```
Host airis-bastion
  HostName <public IP>
  User fde
  IdentityFile ~/.ssh/airis_fde
  IdentitiesOnly yes           # offer only this key (not every key in your agent)
  ForwardAgent no
  StrictHostKeyChecking accept-new
  UserKnownHostsFile <repo>/.local/known_hosts

Host airis-k3s
  HostName 10.10.1.10
  ProxyCommand ssh -F <repo>/.local/ssh_config -W %h:%p airis-bastion   # = ProxyJump
  ...
```

One-liners without the config file:
```bash
ssh -i ~/.ssh/airis_fde -J fde@<bastion-ip> fde@10.10.1.10
```

## Tunnels (know all three, use the first two)

| Flag | Meaning | Example here |
|---|---|---|
| `-L local:target:port` | **Local forward**: a port on *my* machine reaches `target:port` *from the remote side* | `ssh -F .local/ssh_config -L 6443:10.10.1.10:6443 airis-bastion` → kubectl on the laptop against `https://127.0.0.1:6443`. (We don't need it: kubectl runs on the bastion.) |
| `-L` to a ClusterIP | Reach a Kubernetes Service from outside without opening anything | From the bastion: `ssh -L 15432:<airis-core-rw ClusterIP>:5432 airis-k3s` works because the **node** can reach ClusterIPs. That's the "SSH alternative" to port-forward |
| `-R remote:target:port` | **Remote forward**: expose something of mine on the remote side | Rarely appropriate; **mention as a risk** (it can punch holes outward) |
| `-D 1080` | Dynamic SOCKS proxy | Browsing internal UIs; not needed |

Add `-N` (no remote command) and `-f` (background) for tunnels: `ssh -fN -L ...`.

## IAP mode (no public IP on the bastion)

```bash
gcloud compute ssh airis-bastion --zone me-west1-a --tunnel-through-iap
```
- Our config uses `ProxyCommand gcloud compute start-iap-tunnel airis-bastion 22 --listen-on-stdin ...`, so `ssh -F .local/ssh_config airis-k3s` works unchanged.
- Firewall source becomes `35.235.240.0/20`.
- **Required role:** `roles/iap.tunnelResourceAccessor`.

## OS Login mode

- `10-ssh-config.sh` runs `gcloud compute os-login ssh-keys add --key-file ~/.ssh/airis_fde.pub --ttl 8h`. The key **expires by itself**.
- Username comes from `gcloud compute os-login describe-profile`, usually something like `name_domain_com`.
- `sudo` needs `roles/compute.osAdminLogin`. Without it, `20-bootstrap-bastion.sh` can't read the kubeconfig.

## Errors you may see, and what they mean

| Message | Meaning | Fix |
|---|---|---|
| `Permission denied (publickey)` | Wrong user, wrong key, key not (yet) on the VM, or OS Login on | Check `User`, `IdentityFile`, `enable-oslogin` metadata. Wait 30s after VM creation for the guest agent |
| `Connection timed out` | Firewall drop: your IP ≠ `allowed_ssh_cidrs`, or the VM is down | `curl -4 ifconfig.me` vs tfvars; `gcloud compute instances list` |
| `Connection refused` | VM up, sshd not (yet) listening | Wait, or check the serial output |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | VM was re-created (new host key), or MITM | If you re-created it: `rm .local/known_hosts`. Otherwise stop and investigate |
| `UNPROTECTED PRIVATE KEY FILE` | Key readable by others | `chmod 600 ~/.ssh/airis_fde` |
| `channel 0: open failed: administratively prohibited` | Bastion's sshd forbids TCP forwarding | `AllowTcpForwarding yes` (Debian default is yes) |
| `kex_exchange_identification: Connection closed` | Middlebox / IAP permission | IAP role, or retry |

## What to say about hardening the bastion further (phase 2)

- IAP instead of a public IP; OS Login + 2FA.
- `sshd_config`: `PasswordAuthentication no`, `PermitRootLogin no`, `AllowTcpForwarding local`.
- Short session recording/auditing; auto-shutdown outside working hours; CIS-hardened image.
- **The bastion holds the admin kubeconfig.** So: short-lived credentials, or no kubeconfig at rest (fetch on demand).
