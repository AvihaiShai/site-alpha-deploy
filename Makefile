# Convenience wrappers for the LAPTOP side. Every target is a plain script/command
# you can also run by hand (Windows without make: run the scripts from WSL or Cloud Shell).
#   make preflight PROJECT_ID=<id>   then   make up   then   make ssh-bastion
SHELL := /bin/bash
TF    := terraform -chdir=terraform
SSHF  := ssh -F .local/ssh_config
PFX    = $$($(TF) output -raw name_prefix)

.PHONY: preflight init plan apply ssh-config bastion up ssh-bastion ssh-k3s deploy validate failover diag destroy clean-laptop test-validator

preflight:            ## check tools, login, project, org policies, egress IP; write tfvars
	PROJECT_ID=$(PROJECT_ID) ./scripts/00-preflight.sh

init:
	$(TF) init

plan: init
	$(TF) plan -out=tfplan

apply:
	$(TF) apply tfplan

ssh-config:           ## write .local/ssh_config and test both hops
	./scripts/10-ssh-config.sh

bastion:              ## tools + kubeconfig on the bastion
	./scripts/20-bootstrap-bastion.sh

up: plan apply ssh-config bastion   ## infra -> ssh -> bastion ready

ssh-bastion:
	$(SSHF) $(PFX)-bastion

ssh-k3s:
	$(SSHF) $(PFX)-k3s

deploy:               ## operator + Postgres cluster (runs ON the bastion)
	$(SSHF) $(PFX)-bastion 'cd ~/airis && ./scripts/30-deploy-db.sh && ./scripts/40-validator-kubeconfig.sh'

validate:             ## handover validation with the least-privilege identity (runs ON the bastion)
	$(SSHF) $(PFX)-bastion 'cd ~/airis && .venv/bin/python validator/validate.py --kubeconfig ~/.kube/validator.kubeconfig'

failover:             ## kill the primary, measure promotion time (runs ON the bastion)
	$(SSHF) $(PFX)-bastion 'cd ~/airis && ./scripts/failover-demo.sh'

diag:                 ## support bundle (runs ON the bastion)
	$(SSHF) $(PFX)-bastion 'cd ~/airis && ./scripts/collect-diagnostics.sh'

destroy:              ## ONLY when the client asks for teardown
	$(TF) destroy

clean-laptop:         ## remove keys, ssh config, gcloud credentials from this laptop
	./scripts/99-cleanup-laptop.sh

test-validator:       ## local e2e test of the validator (needs PostgreSQL server binaries; run as non-root)
	bash validator/tests/local_e2e.sh
