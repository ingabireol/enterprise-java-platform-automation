# Enterprise Java Platform Automation

Infrastructure-as-code, hardening, backup/recovery, monitoring and disaster-recovery
automation for a **mission-critical enterprise Java application platform** —
the kind of environment that hosts an IFMIS / ERP / institutional service-delivery
system across **development, testing, production and disaster-recovery** tiers.

The reference workload is a modern Java estate:

| Layer            | Technology                                                   |
| ---------------- | ------------------------------------------------------------ |
| Runtime          | Eclipse Temurin **JDK 21** (LTS)                              |
| Services         | **Spring Boot 3.5** executable JARs, `systemd`-managed        |
| Legacy/UI tier   | **Apache Tomcat 10.1** hosting a **ZK 10** WAR                |
| Frontend         | **Angular** SPA served as static assets from Nginx            |
| Edge             | **Nginx** reverse proxy + TLS termination + load balancing    |
| Data             | **PostgreSQL 16** primary with streaming replica to the DR site|
| Observability    | Prometheus, Alertmanager, Grafana, Loki, Promtail             |
| OS               | Rocky Linux 9 / RHEL 9 (also validated on Ubuntu 22.04 LTS)   |

> This repository is **portfolio / reference** work. Every host name, IP address,
> certificate and credential in it is fictitious. Nothing here contains, reproduces
> or discloses any configuration of a real production system.

---



1. **Assess** the environment → [`docs/assessment/`](docs/assessment/)
2. **Build** it reproducibly → [`ansible/`](ansible/)
3. **Harden** it → [`ansible/roles/hardening/`](ansible/roles/hardening/), [`docs/security/`](docs/security/)
4. **Deploy** onto it safely → [`scripts/ops/`](scripts/ops/), [`docs/runbooks/deployment.md`](docs/runbooks/deployment.md)
5. **Watch** it → [`monitoring/`](monitoring/)
6. **Back it up and prove the backup works** → [`scripts/backup/`](scripts/backup/)
7. **Fail over to DR and fail back** → [`docs/runbooks/dr-failover.md`](docs/runbooks/dr-failover.md)
8. **Write it down so someone else can run it** → [`docs/runbooks/`](docs/runbooks/)

---

## Repository map

```
ansible/                    Infrastructure as code (the source of truth)
  inventories/{dev,test,prod,dr}/    One inventory per environment tier
  roles/common/                     Baseline: users, time, DNS, packages, logging
  roles/hardening/                  CIS-aligned OS hardening, SSH, auditd, nftables
  roles/java_runtime/               JDK 21 install, alternatives, JVM tuning defaults
  roles/app_server/                 Spring Boot services under systemd + Tomcat 10.1/ZK
  roles/nginx_lb/                   TLS termination, reverse proxy, HTTP hardening
  roles/postgresql/                 PostgreSQL 16, WAL archiving, streaming replication
  roles/backup/                     Backup agents, schedules, retention, restore drills
  roles/monitoring_agent/           node_exporter, promtail, JMX/Micrometer scraping
  playbooks/                        site, patching, deploy, dr-drill, compliance-audit

scripts/                    Day-2 operational tooling (POSIX shell, ShellCheck-clean)
  lib/common.sh                     Logging, locking, retry, notification helpers
  backup/                           pg_backup, restore verification, retention pruning
  ops/                              deploy, rollback, rolling restart, drain/undrain
  monitoring/                       health checks, capacity report, log triage
  security/                         patch report, TLS expiry audit, account audit

monitoring/                 Observability stack as code (Docker Compose, portable)
  prometheus/                       Scrape config + alert rules (platform, JVM, DB, DR)
  alertmanager/                     Routing, severities, escalation windows
  grafana/dashboards/               Platform overview, JVM, PostgreSQL, DR posture
  loki/ promtail/                   Log aggregation and shipping

docs/
  assessment/                       Environment assessment report + gap register
  runbooks/                         Deployment, patching, backup/restore, DR, incidents
  security/                         Hardening baseline, access control model
  adr/                              Architecture decision records (why, not just what)

tests/                      Molecule scenarios + bats tests for the shell tooling
.github/workflows/          Lint + test CI (ansible-lint, yamllint, shellcheck, bats)
```

---

## Quick start

Requirements: Ansible ≥ 2.15, Python ≥ 3.9, `make`, and SSH access to the targets.

```bash
# 0. Install collections/roles and pre-commit tooling
make deps

# 1. Lint everything before it touches a server
make lint

# 2. Check connectivity to an environment
make ping ENV=dev

# 3. Dry-run the full build of an environment (no changes made)
make check ENV=dev

# 4. Build it
make site ENV=dev

# 5. Compliance report against the hardening baseline
make audit ENV=prod
```

Every `make` target is a thin wrapper over an explicit `ansible-playbook`
invocation — run `make help` to see them, or read the [`Makefile`](Makefile) to
see exactly what is being executed.

---

## Environment tiers

| Tier   | Purpose                                       | Notable differences                                        |
| ------ | --------------------------------------------- | ---------------------------------------------------------- |
| `dev`  | Feature work, fast iteration                  | Single node, auto-deploy on merge, relaxed backup retention |
| `test` | UAT, integration, performance, migration dress-rehearsal | Prod-shaped topology, anonymised data restored from prod backups |
| `prod` | Live service                                  | HA app tier, hardened, change-controlled, full monitoring   |
| `dr`   | Warm standby in the secondary data centre     | Streaming replica, drill-tested failover, independent backup vault |

The same roles build all four. The differences live entirely in
`ansible/inventories/<env>/group_vars/` — which is the point: an environment is a
set of variables, not a set of snowflake servers.

---

## Operating principles applied here

- **Idempotence over instructions.** If a change cannot be expressed as code that
  can be re-run safely, it gets a runbook *and* a follow-up task to automate it.
- **A backup is a rumour until it has been restored.** `verify_restore.sh` restores
  the latest dump into a scratch instance and runs assertions against it on a
  schedule; the DR drill playbook does the same at environment scale.
- **Secrets never land in git.** Ansible Vault for structured secrets, and
  `.gitignore`/`git-secrets` patterns for the accidents. See [`docs/security/access-control.md`](docs/security/access-control.md).
- **Change is reversible.** Every deployment writes a rollback manifest before it
  touches the running service; `rollback.sh` consumes it.
- **Documentation is a deliverable, not an afterthought.** The runbooks are written
  for an engineer who has been paged at 02:00 and has not read this README.

---

## Related repository

Networking, Cisco device administration, segmentation and network monitoring for
the same platform live in a companion repository:
**[`enterprise-network-operations`](../enterprise-network-operations)**.

## Licence

[MIT](LICENSE) — reuse freely.
