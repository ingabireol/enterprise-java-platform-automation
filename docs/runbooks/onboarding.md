# Runbook: Onboarding a platform engineer

The aim of the first fortnight is not that someone knows everything. It is that
they can safely take a page, and know exactly where to look for what they do not
know.

---

## Day 1 — Access and orientation

- [ ] Individual account created, added to `sysadmins` or `platform-ops` — never
      a shared account. See [access-control.md](../security/access-control.md).
- [ ] SSH key (ed25519) added; jump host access confirmed.
- [ ] Read access to Grafana, Prometheus, Alertmanager.
- [ ] Ansible Vault password issued through the agreed channel.
- [ ] Added to the on-call rotation as a shadow, not yet primary.

Read, in this order:

1. The repository [README](../../README.md) — what exists and why.
2. [Environment assessment](../assessment/environment-assessment-report.md) —
   how the platform got to its current shape.
3. [incident-response.md](incident-response.md) — the one to know cold.

---

## Week 1 — Observe

- [ ] Shadow an on-call shift.
- [ ] Walk the architecture with someone at a whiteboard, following one request
      from browser to database and back.
- [ ] Run the read-only tooling against production. None of it changes anything:
  ```bash
  ssh app-prod-01 '/opt/efp/bin/health_check.sh'
  ssh app-prod-01 '/opt/efp/bin/log_triage.sh --since "2 hours ago"'
  make audit ENV=prod
  ```
- [ ] Build a development environment from scratch:
  ```bash
  make deps
  make check ENV=dev
  make site ENV=dev
  ```
  Building it yourself is the fastest way to understand what the roles do.

---

## Week 2 — Do, with supervision

- [ ] Deploy a release to `test`, then roll it back.
- [ ] Run a backup verification and read its output.
- [ ] Take a node out of the pool and put it back.
- [ ] Make a change to a role, run it in check mode against `test`, and read the
      diff before applying.

---

## Week 3–4 — Take responsibility

- [ ] Run a patch cycle on `test` end to end.
- [ ] Participate in a DR drill.
- [ ] Take a primary on-call shift with an experienced engineer as backup.
- [ ] Write or improve one runbook. Fresh eyes find the assumptions the authors
      stopped noticing years ago, and that contribution is more valuable than it
      sounds.

---

## Things worth knowing early

**The platform is code.** A manual change to a managed file will be reverted on
the next converge, possibly in the middle of an incident. If you need to change
something urgently, do it — then reconcile it into Ansible the same day.

**Check mode is free.** `--check --diff` on any playbook shows exactly what would
change. Use it every time; there is no reason not to.

**Draining is instant and reversible.** Taking a node out of the pool costs
nothing and is almost always the right first move before touching it.

**The backup is only real once it has been restored.** Treat a verification
failure with the same seriousness as an outage, because it is a future one.

**Evidence before restart.** A restart destroys the thread dump, the heap state
and often the log window that would have explained the fault. Ten seconds of
`jcmd` saves a week of recurrence.

---

## Escalation

| Situation | Who |
| --- | --- |
| Platform outage | Platform lead, then service owner |
| Data loss suspected | Platform lead **and** service owner, immediately |
| Security incident | Security team, immediately; do not remediate first |
| DR failover decision | Platform lead, or on-call with the service owner informed |
| Network or data centre | Infrastructure team — see the companion network repository |
