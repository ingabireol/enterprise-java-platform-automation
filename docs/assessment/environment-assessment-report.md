# Environment Assessment Report

**System:** Enterprise Java application platform (IFMIS/ERP-class workload)
**Scope:** Infrastructure, operating systems, middleware, runtime platforms, system administration practice
**Method:** Interviews, live inspection, configuration capture, log review, and a controlled restore test
**Status:** Reference document — fictional environment, real methodology

---

## 1. Why this document exists

Before anything in this repository is applied to an environment, the environment
has to be understood as it actually is. This is the template the assessment
follows and the shape the findings take. It is deliberately blunt: an assessment
that reads like a sales document is useless to the team that has to act on it.

The assessment answers five questions:

1. What is actually running, on what, and who knows?
2. Where is the platform one failure away from an outage?
3. What would recovery actually look like, tested rather than described?
4. What is the gap between the current state and the state the upgrade needs?
5. Which gaps are worth closing first?

---

## 2. Method

| Activity | Evidence produced |
| --- | --- |
| Configuration capture on every host | `scripts/backup/config_backup.sh` archive per host |
| Package and patch state inventory | `scripts/security/patch_report.sh --json` per host |
| Account and privilege review | `scripts/security/account_audit.sh --json` per host |
| Hardening baseline comparison | `ansible/playbooks/compliance-audit.yml` report |
| TLS posture review | `scripts/security/tls_audit.sh --json` per endpoint |
| Backup restore test | Controlled restore into an isolated cluster, timed |
| Log review | 30 days of application, database and system logs |
| Interviews | Platform team, DBAs, network team, service desk |

Nothing in the assessment relies on being told that something works. Where a
claim mattered, it was tested.

---

## 3. Current state

### 3.1 Topology

```
                        ┌──────────────────────┐
     Users ─── HTTPS ───▶│  Edge (2× nginx)     │  VIP via keepalived
                        └──────────┬───────────┘
                                   │
            ┌──────────────────────┼──────────────────────┐
            ▼                      ▼                      ▼
    ┌───────────────┐      ┌───────────────┐     ┌───────────────┐
    │ App node 1    │      │ App node 2    │     │ ZK/Tomcat tier│
    │ Spring Boot   │      │ Spring Boot   │     │ (UI)          │
    └───────┬───────┘      └───────┬───────┘     └───────┬───────┘
            └──────────────────────┼─────────────────────┘
                                   ▼
                        ┌──────────────────────┐
                        │ PostgreSQL primary   │
                        └──────────┬───────────┘
                                   │ streaming replication
                        ┌──────────▼───────────┐
                        │ Replica (same site)  │
                        └──────────┬───────────┘
                                   │ WAN
                        ┌──────────▼───────────┐
                        │ DR replica (site 2)  │
                        └──────────────────────┘
```

### 3.2 Inventory summary

| Tier | Nodes | OS | Runtime | Notes |
| --- | --- | --- | --- | --- |
| Edge | 2 | Rocky Linux 9 | nginx 1.24 | Active/passive VIP |
| Application | 3 | Rocky Linux 9 | JDK 21, Spring Boot 3.5 | systemd-managed JARs |
| UI (ZK) | 2 | Rocky Linux 9 | JDK 21, Tomcat 10.1 | Stateful sessions |
| Database | 2 + 1 DR | Rocky Linux 9 | PostgreSQL 16 | Streaming replication |
| Monitoring | 1 | Rocky Linux 9 | Prometheus, Grafana, Loki | |
| Backup | 1 + 1 DR | Rocky Linux 9 | — | Local vault + DR vault |

---

## 4. Findings

Findings are rated by the damage they enable, not by how hard they are to fix.

### F-01 — Manual configuration with no reproducible source of truth · **HIGH**

**Observed.** Hosts in the same tier differ in kernel parameters, open file
limits, JVM flags and log rotation policy. Three application nodes carry three
different `-Xmx` values. Nobody can say when or why they diverged.

**Why it matters.** Configuration drift is not itself an outage; it is the reason
an outage cannot be reasoned about. When one node behaves differently under load,
the investigation starts by discovering the difference rather than by diagnosing
the fault. It also makes every capacity calculation wrong.

**Recommendation.** Bring every host under Ansible with per-tier variables, then
run a converge in check mode and treat every reported change as a finding to be
understood before it is applied. `ansible/` in this repository is that structure.

---

### F-02 — Backups are taken but have never been restored · **CRITICAL**

**Observed.** A nightly `pg_dump` runs and completes. No restore has been
performed from it in the lifetime of the system. WAL archiving is not enabled, so
recovery granularity is one day.

**Why it matters.** This is the single most consequential finding in most
assessments. An untested backup is a hypothesis, and the hypothesis is tested for
the first time on the worst day. Without WAL archiving, the recovery point
objective is not the fifteen minutes the service owner assumes — it is up to
twenty-four hours, and the difference will only be discovered during a recovery.

**Recommendation.** Enable WAL archiving immediately; it is a configuration change
and a directory. Then schedule an automated restore verification that restores the
newest backup into a scratch cluster and asserts against it — `scripts/backup/verify_restore.sh`
and the weekly timer in `ansible/roles/backup/`. Until a restore has succeeded, the
recovery capability is unproven and should be reported as such.

---

### F-03 — Disaster recovery site exists but has never been exercised · **CRITICAL**

**Observed.** A DR replica receives streaming replication. There is a written
failover procedure. No drill has been performed. The DR application tier is two
minor versions behind production and its TLS certificate expired four months ago.

**Why it matters.** Drift between production and DR is the normal reason a
failover fails, and it accumulates silently because nothing exercises it. The
expired certificate alone would turn a two-hour recovery into an all-day one, at
the exact moment nobody has spare attention.

**Recommendation.** Treat DR as production: same converge, same patch cycle, same
certificate rotation. Then schedule quarterly drills that measure rather than
assert — `ansible/playbooks/dr-drill.yml` records the achieved RPO and RTO
against the stated objectives and writes an evidence file.

---

### F-04 — No monitoring of the things that fail · **HIGH**

**Observed.** Host-level CPU and disk are graphed. There is no JVM heap or GC
instrumentation, no connection pool metrics, no replication lag metric, no backup
success metric, and no alerting on any of them. Incidents are detected by users.

**Why it matters.** The gap is not "no monitoring" — it is monitoring of the
layer that rarely causes incidents, and none of the layers that usually do. Heap
exhaustion, connection pool starvation and replication stall are the three most
common causes of an outage on a platform of this shape, and none of them were
observable.

**Recommendation.** Expose Micrometer metrics from every service, add
`postgres_exporter` and `node_exporter`, and alert on the conditions in
`monitoring/prometheus/alerts/`. Every alert should carry the action to take;
an alert without one trains people to ignore alerts.

---

### F-05 — Deployments are manual and irreversible · **HIGH**

**Observed.** Releases are deployed by copying a JAR over the existing one and
restarting the service. The previous artefact is overwritten. Rollback means
rebuilding from source. Deployments cause a visible outage and are therefore done
late at night, by one person, from memory.

**Why it matters.** Irreversibility makes every release a high-stakes event, which
makes releases rare, which makes each one larger and riskier. The overnight
schedule guarantees they are performed by someone tired and alone.

**Recommendation.** Deploy to a versioned release directory and switch a symlink;
keep the previous releases on disk; write a rollback manifest before changing
anything. Drain each node from the load balancer, deploy, wait for readiness, then
return it — `scripts/ops/deploy.sh` and `ansible/playbooks/deploy.yml`.

---

### F-06 — Shared administrative credentials · **HIGH**

**Observed.** Password authentication is enabled for SSH. A shared `admin` account
with `NOPASSWD: ALL` is used by four people. Root login over SSH is permitted. The
database superuser password is in a spreadsheet.

**Why it matters.** Shared credentials remove attribution: after an incident it is
impossible to establish who did what. They also mean an offboarding never
completes, since there is no individual credential to revoke.

**Recommendation.** Individual accounts, key-only authentication, group-based sudo
scoped to what each role actually needs, and no direct root login. The model is in
`docs/security/access-control.md` and implemented in `ansible/roles/common` and
`ansible/roles/hardening`.

---

### F-07 — Hosts significantly behind on patches · **HIGH**

**Observed.** Application nodes are between 90 and 210 days behind on security
updates. Two hosts are running a kernel older than the newest installed one — they
were patched but never rebooted. There is no patch cycle.

**Why it matters.** A host patched but not rebooted is still exposed; the fix is
installed and inert. The absence of a cycle is the deeper problem: patching
becomes an event requiring justification rather than a routine that needs no
decision.

**Recommendation.** A monthly rolling patch cycle with health gates between
batches, and an out-of-cycle path for critical severity — `ansible/playbooks/patching.yml`
and `docs/runbooks/patching.md`.

---

### F-08 — No host-level network controls · **MEDIUM**

**Observed.** `firewalld` is disabled on every host. All ports are reachable from
anywhere inside the corporate network, including the PostgreSQL port and the
Spring Boot actuator endpoints.

**Why it matters.** The design assumes the network perimeter holds. Once anything
inside the network is compromised, the database is directly reachable from it, and
the actuator endpoints expose configuration and heap dumps.

**Recommendation.** Default-deny `nftables` on every host, with ports opened only
for the roles the host carries — `ansible/roles/hardening/templates/nftables.conf.j2`.

---

### F-09 — Log retention too short to investigate · **MEDIUM**

**Observed.** Application logs rotate daily and are kept for three days. There is
no central aggregation. During an incident the relevant logs had already rotated
away on two of the three nodes.

**Recommendation.** Ship logs centrally with promtail to Loki, keep 90 days, and
keep local rotation only as a disk guard.

---

### F-10 — Undocumented operational knowledge · **MEDIUM**

**Observed.** Two people can perform a failover, and neither procedure is written
down beyond a one-page outline. Both were unavailable during the most recent
incident.

**Recommendation.** Runbooks written for someone woken at 02:00 who has not read
them before — `docs/runbooks/`. A runbook that assumes context is not a runbook.

---

## 5. Gap register

| ID | Finding | Severity | Effort | Sequence |
| --- | --- | --- | --- | --- |
| F-02 | Backups never restored | Critical | Low | 1 |
| F-03 | DR never exercised | Critical | Medium | 3 |
| F-06 | Shared credentials | High | Low | 2 |
| F-07 | Patch backlog | High | Medium | 4 |
| F-04 | Monitoring gaps | High | Medium | 2 |
| F-01 | Configuration drift | High | High | 5 |
| F-05 | Manual deployments | High | Medium | 4 |
| F-08 | No host firewall | Medium | Low | 3 |
| F-09 | Log retention | Medium | Low | 3 |
| F-10 | Undocumented procedures | Medium | Medium | continuous |

Sequencing is chosen so that each step makes the next one safer. Monitoring comes
before configuration management, because converging an estate you cannot observe
is how a remediation becomes an incident. Backup verification comes first
regardless of effort, because everything else is riskier without it.

---

## 6. Recommended sequence

**Phase 1 — Prove recovery (weeks 1–2).** Enable WAL archiving. Perform a restore
test and record the result. Fix whatever it reveals. This is first because until
recovery is proven, every subsequent change carries unbounded risk.

**Phase 2 — See and control (weeks 2–6).** Deploy monitoring agents and alerting.
Replace shared credentials with individual accounts and key-only authentication.
Both are low-risk and immediately reduce the cost of everything after them.

**Phase 3 — Make it reproducible (weeks 4–10).** Bring hosts under configuration
management, one tier at a time, starting with the least user-visible. Run in check
mode first and treat each reported change as a finding.

**Phase 4 — Make change routine (weeks 8–14).** Automated deployment with
rollback. Monthly patch cycle. Both depend on Phase 2 being in place, because
neither is safe without the ability to see the result.

**Phase 5 — Prove continuity (weeks 12–16).** Bring DR into line with production
and run a measured drill. Repeat quarterly.

---

## 7. What this assessment does not cover

Stated explicitly, because an assessment that implies completeness it does not
have is worse than a narrower one:

- Application source code quality and the service-decomposition work itself
- Database schema design, indexing and query performance
- Network device configuration and segmentation — covered in the companion
  [`enterprise-network-operations`](../../../enterprise-network-operations) repository
- Business continuity beyond the technical platform
- Licensing and commercial arrangements
