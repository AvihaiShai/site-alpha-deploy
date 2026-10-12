# 12 · Installing the tools

## What runs where

| Machine | Tools | Installed by |
|---|---|---|
| **Laptop** (yours for rehearsal, theirs on the day) | `git`, `terraform` ≥ 1.5, `gcloud`, `ssh`/`ssh-keygen`, `curl`, `bash` | You (below) |
| **Bastion** | `kubectl` 1.35.x, `helm` 4.3.0, `psql`, Python venv + `psycopg`, `kubectl cnpg` | `scripts/bastion-setup.sh` (automatic, checksum-verified) |
| **K3s node** | K3s v1.35.7+k3s1 (bundles kubectl, crictl, containerd) | `scripts/k3s-install.sh` (automatic) |

You do **not** need kubectl or helm on the laptop. All cluster work happens from the bastion. That's the point of the design.

## macOS

```bash
brew install git
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
brew install --cask google-cloud-sdk        # then open a new terminal
```

## Linux (Debian/Ubuntu)

```bash
# Terraform from HashiCorp's apt repo
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# gcloud from Google's apt repo
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
sudo apt-get update && sudo apt-get install -y google-cloud-cli
```

## Windows

The scripts are bash. Pick one:
1. **WSL2 (Ubuntu)** → follow the Linux steps inside WSL. Best option on your own machine.
2. **Git Bash** + `winget install Hashicorp.Terraform Google.CloudSDK`. Works for Terraform and SSH; scripts mostly work.
3. **Google Cloud Shell** (browser) → below. Zero install.

## Plan B on any locked-down laptop: Google Cloud Shell

- **How:** Cloud Console → `>_` icon.
- **What you get:** a small Linux VM with `terraform`, `gcloud` (already authenticated as you), `kubectl`, `helm`, `git` and `python3` preinstalled, plus 5 GB home.
- **Caveat 1:** Cloud Shell's **egress IP is Google's, not the office's.**
  - So `allowed_ssh_cidrs` must include Cloud Shell's current IP (`curl -4 ifconfig.me` inside it).
  - Or use IAP mode (`bastion_public_ip = false`).
  - Say this out loud; it's exactly the kind of CIDR reasoning they test.
- **Caveat 2:** Cloud Shell can be disabled by org policy. Check early.
- **Caveat 3:** ADC exists in Cloud Shell; `gcloud auth application-default login` may still be needed for Terraform.

## Verify

```bash
terraform version          # >= 1.5
gcloud version
ssh -V
gcloud auth list
gcloud auth application-default print-access-token >/dev/null && echo ADC-ok
```

## Your own GCP project for rehearsal

```bash
gcloud projects create avihai-site-alpha-rehearsal-<random>     # or in the console
gcloud beta billing projects link <PROJECT_ID> --billing-account <BILLING_ID>
# Console: Billing → Budgets & alerts → $10, email at 50/90/100%
PROJECT_ID=<PROJECT_ID> ./scripts/00-preflight.sh
```
Destroy after every session: `terraform -chdir=terraform destroy`.
