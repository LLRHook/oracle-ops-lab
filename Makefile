# oracle-ops-lab — entry points. Run `make help` for the list.
SHELL := /bin/bash
.DEFAULT_GOAL := help

VM        := oracle-ops-lab
LIMA_CFG  := lima/oracle-ops-lab.yaml
ANSIBLE   := cd ansible && ../.venv/bin/ansible-playbook
PROM_IMG  := prom/prometheus:v3.15.1
DISKS     := ol-oradata:20GiB ol-redo:4GiB ol-fra:20GiB

.PHONY: help bootstrap vm deploy backup drill patch test lint stop start destroy ssh evidence status

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Install controller tooling: Lima (brew), Ansible via uv, collections, secrets
	@command -v limactl >/dev/null || brew install lima
	uv sync
	cd ansible && ../.venv/bin/ansible-galaxy collection install -r requirements.yml -p collections
	./scripts/gen-secrets.sh

vm: ## Create the extra disks (if missing) and start the Lima VM
	@for d in $(DISKS); do n=$${d%%:*}; s=$${d##*:}; \
	  limactl disk list -q 2>/dev/null | grep -qx "$$n" || limactl disk create "$$n" --size "$$s"; done
	@if limactl list -q | grep -qx $(VM); then limactl start $(VM); \
	 else limactl start --name $(VM) --tty=false $(LIMA_CFG); fi
	@limactl list $(VM)

deploy: ## Converge the VM end to end with site.yml (idempotent)
	$(ANSIBLE) site.yml $(ARGS)

backup: ## Run an RMAN backup now (LEVEL=level0|level1|archivelog, default level0)
	$(ANSIBLE) playbooks/backup.yml -e "backup_level=$(or $(LEVEL),level0)"

drill: ## Restore drill: RESTORE VALIDATE + destructive lost-datafile recovery with RTO timing
	$(ANSIBLE) playbooks/restore-drill.yml

patch: ## Patch the OS with pre/post checks; reboots only if needed (SECURITY=1 for security-only)
	$(ANSIBLE) playbooks/patch.yml -e "patch_security_only=$(if $(SECURITY),true,false)"

test: ## promtool check + unit tests for alert rules, then live assertions against the VM
	docker run --rm -v "$(CURDIR)/monitoring/prometheus:/work:ro" -w /work --entrypoint promtool $(PROM_IMG) check rules alerts.yml
	docker run --rm -v "$(CURDIR)/monitoring/prometheus:/work:ro" -w /work --entrypoint promtool $(PROM_IMG) test rules tests/alerts_test.yml
	$(ANSIBLE) playbooks/verify.yml

lint: ## yamllint + ansible-lint (production profile)
	.venv/bin/yamllint -s .
	ANSIBLE_COLLECTIONS_PATH=ansible/collections .venv/bin/ansible-lint --offline

evidence: ## Collect runtime evidence from the VM into evidence/raw/
	./scripts/collect-evidence.sh

ssh: ## Shell into the VM
	limactl shell $(VM)

status: ## Show VM and database status
	@limactl list $(VM)
	@limactl shell $(VM) -- sudo /etc/init.d/oracle-free-26ai status 2>/dev/null || true

stop: ## Stop the VM (keeps disks)
	limactl stop $(VM)

start: ## Start an existing VM
	limactl start $(VM)

destroy: ## Delete the VM and its extra disks (irreversible)
	-limactl stop $(VM)
	-limactl delete $(VM)
	@for d in $(DISKS); do limactl disk delete "$${d%%:*}" || true; done
