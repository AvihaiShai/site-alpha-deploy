#!/usr/bin/env bash
# Shared helpers for the laptop-side scripts. Source it, don't run it.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
LOCAL_DIR="${REPO_ROOT}/.local"   # git-ignored: ssh config, known_hosts, reports

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFAIL\033[0m  %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1 (see docs/tool-installation.md)"; }

# terraform output -raw <name>, from the terraform/ directory
tf_out() { terraform -chdir="${TF_DIR}" output -raw "$1" 2>/dev/null; }

ssh_cfg() { echo "${LOCAL_DIR}/ssh_config"; }

# Run a command on the bastion / k3s node through the generated SSH config
on_bastion() { ssh -F "$(ssh_cfg)" "$(tf_out name_prefix)-bastion" "$@"; }
on_k3s()     { ssh -F "$(ssh_cfg)" "$(tf_out name_prefix)-k3s" "$@"; }
