# Enterprise Java Platform Automation — operator entry points.
# Every target is a thin, readable wrapper over an explicit command.

ENV      ?= dev
INV      := ansible/inventories/$(ENV)
PLAYBOOK := ansible-playbook -i $(INV)/hosts.yml
LIMIT    ?=
TAGS     ?=

EXTRA :=
ifneq ($(LIMIT),)
EXTRA += --limit $(LIMIT)
endif
ifneq ($(TAGS),)
EXTRA += --tags $(TAGS)
endif

.DEFAULT_GOAL := help
.PHONY: help deps lint yamllint ansiblelint shellcheck test ping check site \
        harden deploy patch audit backup-verify dr-drill monitoring-up monitoring-down clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Variables: ENV=dev|test|prod|dr   LIMIT=<host pattern>   TAGS=<tags>"

deps: ## Install Ansible collections/roles and Python tooling
	ansible-galaxy install -r ansible/requirements.yml
	python3 -m pip install --quiet --upgrade ansible-lint yamllint

lint: yamllint ansiblelint shellcheck ## Run every linter

yamllint: ## Lint YAML
	yamllint -c .yamllint.yml ansible monitoring .github

ansiblelint: ## Lint Ansible content
	ansible-lint -p ansible/

shellcheck: ## Lint shell scripts
	@find scripts -type f -name '*.sh' -print0 | xargs -0 shellcheck -x -S style

test: ## Run bats unit tests for the shell tooling
	bats tests/bats

ping: ## Verify connectivity and privilege escalation for ENV
	ansible -i $(INV)/hosts.yml all -m ping $(EXTRA)

check: ## Dry-run the full build of ENV (--check --diff, no changes)
	$(PLAYBOOK) ansible/playbooks/site.yml --check --diff $(EXTRA)

site: ## Build/converge ENV end to end
	$(PLAYBOOK) ansible/playbooks/site.yml $(EXTRA)

harden: ## Apply only the OS/security hardening baseline to ENV
	$(PLAYBOOK) ansible/playbooks/site.yml --tags hardening $(EXTRA)

deploy: ## Deploy an application release to ENV (requires VERSION=x.y.z)
	@test -n "$(VERSION)" || { echo "VERSION=x.y.z is required"; exit 2; }
	$(PLAYBOOK) ansible/playbooks/deploy.yml -e "app_version=$(VERSION)" $(EXTRA)

patch: ## Rolling OS patch cycle for ENV with health gates between batches
	$(PLAYBOOK) ansible/playbooks/patching.yml $(EXTRA)

audit: ## Report ENV compliance against the hardening baseline (read-only)
	$(PLAYBOOK) ansible/playbooks/compliance-audit.yml $(EXTRA)

backup-verify: ## Restore the latest backup into a scratch instance and assert on it
	$(PLAYBOOK) ansible/playbooks/backup-verify.yml $(EXTRA)

dr-drill: ## Execute a controlled disaster-recovery drill against the DR tier
	$(PLAYBOOK) ansible/playbooks/dr-drill.yml -i ansible/inventories/dr/hosts.yml $(EXTRA)

monitoring-up: ## Start the local observability stack (Prometheus/Grafana/Loki)
	docker compose -f monitoring/docker-compose.yml up -d

monitoring-down: ## Stop the local observability stack
	docker compose -f monitoring/docker-compose.yml down

clean: ## Remove local artefacts
	rm -rf .ansible retry/ *.retry /tmp/ejpa-*
