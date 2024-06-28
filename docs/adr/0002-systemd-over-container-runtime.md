# ADR 0002 — systemd units rather than containers for the application tier

**Status:** Accepted
**Date:** 2026-02-14
**Revisit:** When the service decomposition produces more than roughly ten services

## Context

The application tier is three Spring Boot services and a Tomcat instance. The
industry default would be containers, probably on Kubernetes. The question is
whether that default earns its cost here.

## Decision

Run the services as `systemd` units directly on the host. Revisit if the service
count grows substantially or if the deployment cadence increases to the point
where orchestration pays for itself.

## Options considered

**Kubernetes.** Excellent at what it is for: many services, frequent deployment,
elastic scaling, multiple teams shipping independently. None of those describe
this platform today — four services, monthly releases, fixed capacity, one team.
Adopting it would mean a control plane to run, patch and recover, a networking
model to understand, and a new class of incident, in exchange for capabilities
that would not be used. Rejected as cost without benefit **at the current scale**,
not as a bad technology.

**Podman or Docker Compose on the host.** Containers without orchestration. Some
real benefits — dependency isolation, reproducible runtime. Rejected because the
main benefit, isolating conflicting dependencies, does not apply: there is one
JDK and it is managed by Ansible. It would add an image build and registry to
maintain for isolation that `systemd` sandboxing already provides most of.

**systemd units.** Chosen. The sandboxing directives (`ProtectSystem=strict`,
`PrivateTmp`, `NoNewPrivileges`, `SystemCallFilter`) provide a substantial part of
what container isolation gives, with no new runtime. Resource limits come from
cgroups either way. Logs go to the journal, which is already collected.

## Consequences

**Good.** No orchestration layer to operate. One fewer thing to patch and recover.
Debugging is direct — `journalctl`, `jcmd`, `ss` — with no exec into a container
first. The whole estate is understandable by someone who knows Linux.

**Bad.** Deployment is our own code rather than a platform feature. No automatic
rescheduling if a host is lost — capacity is provisioned for it instead. Scaling
out means provisioning a host, not changing a replica count.

**Revisit trigger.** Recorded deliberately, so the decision gets reconsidered on
evidence rather than on fashion: more than ~10 services, or weekly-or-faster
deployment, or a genuine need for elastic scaling.
