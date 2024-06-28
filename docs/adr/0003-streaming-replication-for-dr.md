# ADR 0003 — Streaming replication with manual promotion for disaster recovery

**Status:** Accepted
**Date:** 2026-03-02

## Context

The platform needs a disaster recovery capability with a 15-minute recovery point
objective and a 2-hour recovery time objective, across two data centres connected
by a WAN link.

## Decision

Asynchronous streaming replication to a warm standby at the secondary site.
Promotion is a human decision, executed by a documented procedure and exercised
quarterly.

## Options considered

**Synchronous replication.** Would give a zero-byte recovery point. Rejected: every
commit would wait for a WAN round trip, so write latency becomes a function of the
inter-site link, and a link problem becomes a total write outage at the primary
site. Trading availability for an RPO tighter than required is the wrong trade.

**Automatic failover (Patroni, repmgr).** Attractive on paper. Rejected for this
platform because automatic promotion across two sites requires a consensus layer
with a third location to break ties. Without one, a network partition between the
sites produces two primaries, and the resulting data divergence is considerably
worse than the outage the automation was meant to prevent. Reconsider when a third
site or a cloud witness is available.

**Backup-restore only.** Simplest. Rejected: restoring a multi-terabyte cluster
from backup exceeds the 2-hour RTO before anyone has looked at the application
tier.

**Storage-level replication.** Rejected: replicates corruption as faithfully as it
replicates data, and gives no application-level visibility into lag. Replication
lag as a queryable number is what makes the RPO measurable rather than assumed.

## Consequences

**Good.** RPO is a measured number, visible on a dashboard and alerted on. No
split-brain risk. The failover procedure is understood because it is exercised.
The standby is readable, so reporting can be offloaded to it.

**Bad.** Failover requires a human, which adds decision time to the RTO. Someone
has to be reachable. Quarterly drills cost a maintenance window each.

**Accepted.** Up to 15 minutes of data loss in a genuine site failure. This is the
stated objective and it is signed off by the service owner — recorded here so it
is a decision rather than a discovery.
