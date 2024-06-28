# Architecture

How the platform is put together, and the reasoning behind the parts that were
genuine choices rather than defaults.

---

## Request path

```
                              Internet / corporate network
                                          │
                                    DNS / GSLB
                                          │
                              ┌───────────▼───────────┐
                              │  VIP  10.30.10.10     │  keepalived (VRRP)
                              └───────────┬───────────┘
                         ┌────────────────┴────────────────┐
                    ┌────▼────┐                       ┌────▼────┐
                    │ nginx 1 │  MASTER               │ nginx 2 │  BACKUP
                    └────┬────┘                       └────┬────┘
                         │   TLS terminates here           │
                         └────────────────┬────────────────┘
                                          │
              ┌───────────────────────────┼───────────────────────────┐
              │                           │                           │
    ┌─────────▼─────────┐     ┌───────────▼───────────┐   ┌───────────▼──────────┐
    │  Angular SPA      │     │  Spring Boot services │   │  ZK 10 on Tomcat     │
    │  (static, nginx)  │     │  least_conn balanced  │   │  ip_hash balanced    │
    └───────────────────┘     └───────────┬───────────┘   └───────────┬──────────┘
                                          │                           │
                                          └─────────────┬─────────────┘
                                                        │  TLS, scram-sha-256
                                          ┌─────────────▼─────────────┐
                                          │   PostgreSQL 16 primary   │
                                          └─────────────┬─────────────┘
                                   streaming replication │
                          ┌───────────────────────────────┴──────────┐
                ┌─────────▼──────────┐                     ┌─────────▼──────────┐
                │ Replica (site 1)   │                     │ Replica (site 2)   │
                │ read scaling, HA   │                     │ disaster recovery  │
                └────────────────────┘                     └────────────────────┘
```

---

## The choices that were actually choices

### TLS terminates at the edge, not at the JVM

The application servers speak plain HTTP on an internal segment reachable only
from the edge nodes. One place to rotate certificates, one place to configure
cipher suites, and no per-service TLS configuration to drift.

The cost is that traffic between edge and application is unencrypted on the wire.
That is accepted because the segment is dedicated, firewalled to those hosts, and
under the same administrative control. In an environment where that is not true,
this decision reverses.

### Least-connection for APIs, IP hash for the UI

The Spring Boot services are stateless, so `least_conn` distributes by actual
load — better than round-robin when request cost varies, which it does when one
endpoint generates a report and another returns a lookup.

The ZK tier keeps desktop state server-side. A request that lands on a different
node loses the user's working context, so `ip_hash` pins a user to a node for the
session. This is a constraint of the UI framework, not a preference.

### `min == max` heap

`-Xms` equal to `-Xmx` in production. A JVM that resizes its heap does so with a
full collection, which shows up as a latency spike with no application-level
cause. Giving up the memory saving buys predictable pause behaviour.

### `systemd` units carry the operational policy

Restart behaviour, resource limits, sandboxing and log destinations live in the
unit file, not in a wrapper script and not in the application. The JAR stays a
plain artefact with no knowledge of the host it runs on, which is what makes the
same artefact deployable to all four environments.

`StartLimitBurst=3` within five minutes: recover from a crash, but stop flapping,
so that a genuinely broken release surfaces as an alert instead of an endless
restart loop that looks healthy in a process listing.

### Versioned releases with a symlink

Deployment writes to `releases/<version>/` and moves `current`. The switch is
atomic, the previous release stays on disk, and rollback is moving the symlink
back. The alternative — copying over the running artefact — makes rollback a
rebuild.

### WAL archiving before anything else

The base backup plus the WAL archive is the recovery capability; the nightly
logical dump is a convenience for restoring one table. Archiving is enabled
before the first byte of application data is written, because retrofitting it
means the window before it was enabled is permanently unrecoverable.

### DR is configured identically to production

Same roles, same variables except where the standby role demands otherwise, same
patch cycle, same certificate rotation. Drift between production and DR is the
normal reason a failover fails, and it accumulates silently, so it is treated as
a defect rather than as an acceptable difference.

### Metrics and logs are separate pipelines

Prometheus for numbers, Loki for words. Deliberately not one system: metrics need
to be cheap to aggregate over long windows, logs need to be cheap to search over
short ones. Joining them at query time in Grafana gives most of the benefit of a
single store without either side compromising.

---

## Environments

| | dev | test | prod | dr |
| --- | --- | --- | --- | --- |
| Topology | Single collapsed node | Production-shaped | Full HA | Mirrors production |
| Hardening | `baseline` | `strict` | `strict` | `strict` |
| SELinux | permissive | enforcing | enforcing | enforcing |
| Data | Synthetic | Anonymised from production | Live | Replicated |
| Backup retention | 7 days | 14 days | 35 days + 12 monthly | 90 days |
| Backup verification | — | Weekly | Weekly | Weekly |
| Change control | None | Required | Required | Required |
| Services running | Yes | Yes | Yes | **No** — enabled but stopped |

`test` runs the production hardening profile on purpose. A test environment
configured more loosely than production tests something that does not exist.

---

## Failure modes and what handles them

| Failure | Detection | Response | Impact |
| --- | --- | --- | --- |
| One application node | Load balancer health check, ~15s | Removed from pool automatically | None |
| One edge node | keepalived health script, ~6s | VIP moves to the peer | Brief connection reset |
| Database primary | Monitoring, manual confirmation | Promote the local replica | Minutes of write unavailability |
| Both database nodes | Monitoring | DR failover | Up to 2 hours (RTO), up to 15 minutes of data (RPO) |
| Entire primary site | Monitoring, external probe | DR failover | As above |
| Data corruption | Application errors, integrity checks | Point-in-time recovery | Depends on detection latency |
| Bad release | Error rate alert, deployment annotation | Rollback | Minutes |
| Certificate expiry | Alert at 30 and 14 days | Rotation | None if the alert is acted on |

The automatic responses are the first two rows. Everything below them is a human
decision, deliberately: promoting a database and failing over a site are choices
with consequences that no health check has the context to make.

---

## Capacity

Sized for 2,000 concurrent users and 500 requests per second at peak, with
headroom for a node to be lost without degradation.

| Resource | Basis |
| --- | --- |
| Application nodes | 3 × (8 vCPU, 16 GiB). Two carry peak; the third is the headroom. |
| JVM heap | 6 GiB per service, `min == max`. Sized from steady-state live set after a full collection, plus 100% headroom. |
| Database connections | 400 maximum. Pool sizing per service is derived from this in `application-env.yml.j2` so the pools cannot sum to more than the database allows. |
| `shared_buffers` | 25% of database host RAM |
| `effective_cache_size` | 75% of database host RAM |
| Backup storage | 3× database size for base backups plus 35 days of WAL |

Pool sizing is computed in the template rather than written by hand because the
arithmetic — services × nodes × pool size < `max_connections` — is exactly the
kind that gets out of date after someone adds a node.

---

## Related

- [Environment assessment](assessment/environment-assessment-report.md)
- [Hardening baseline](security/hardening-baseline.md)
- [Access control model](security/access-control.md)
- [Runbooks](runbooks/)
- Network architecture: the companion
  [`enterprise-network-operations`](../../enterprise-network-operations) repository
