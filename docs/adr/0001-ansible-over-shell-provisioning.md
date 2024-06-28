# ADR 0001 — Ansible as the configuration source of truth

**Status:** Accepted
**Date:** 2026-02-10

## Context

Hosts were provisioned by hand and maintained by a collection of shell scripts
kept in a shared directory. Three application nodes carried three different JVM
heap settings and nobody could say why. Investigating any incident began with
establishing what the hosts actually looked like.

## Decision

Ansible is the source of truth for host configuration. A host's intended state is
the roles and variables that apply to it, and a converge is expected to be
re-runnable at any time without breaking a running service.

## Options considered

**Shell scripts, tidied up.** Lowest migration cost and the team already knew
them. Rejected: shell provisioning is not idempotent without considerable extra
work, and the extra work is exactly what a configuration management tool already
does. It also has no concept of check mode, so there is no way to see what a
change would do before doing it.

**Puppet or Chef.** Both are capable. Rejected on operational cost: an agent, a
server, and a certificate authority to maintain, for an estate of fourteen hosts.
The agentless model fits better at this size.

**Terraform.** Wrong layer. Terraform manages infrastructure lifecycle; this
problem is the configuration inside hosts that already exist. The two are
complementary, not alternatives.

## Consequences

**Good.** Configuration is reviewable, diffable and reproducible. `--check --diff`
makes every change previewable. New environments are a variables file. Drift
becomes visible rather than being discovered during an incident.

**Bad.** A learning curve for the team. Some tasks are more verbose in YAML than
in shell. Ansible is slow on large estates, though not at this size.

**Accepted.** Manual changes to managed files will be reverted on the next
converge. This is the point, but it needs to be understood — the onboarding
runbook says so explicitly, and urgent manual changes must be reconciled into
Ansible the same day.
