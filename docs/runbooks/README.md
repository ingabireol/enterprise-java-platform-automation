# Runbooks

Written for an engineer who has been paged at 02:00, has not read this before,
and is not the person who built the system.

That constraint drives the format. Every runbook starts with what the symptom
looks like and what to do in the first five minutes, before any explanation.
Commands are copy-pasteable. Nothing assumes context that the reader has to go
and acquire first.

| Runbook | When you need it |
| --- | --- |
| [incident-response.md](incident-response.md) | Something is broken and you do not yet know what |
| [deployment.md](deployment.md) | Releasing a version, or recovering from a release |
| [patching.md](patching.md) | Monthly cycle, or an out-of-cycle critical |
| [backup-restore.md](backup-restore.md) | Restoring data, or a backup job has failed |
| [dr-failover.md](dr-failover.md) | The primary site is gone, or a quarterly drill |
| [tls-certificate-rotation.md](tls-certificate-rotation.md) | A certificate is expiring or has expired |
| [onboarding.md](onboarding.md) | New engineer joining the platform team |
