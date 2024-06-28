# ADR 0004 — Separate pipelines for metrics and logs

**Status:** Accepted
**Date:** 2026-03-20

## Context

The platform needs both numerical time series (for alerting, trends and capacity)
and searchable logs (for diagnosis). These could be one system or two.

## Decision

Prometheus for metrics, Loki for logs, joined at query time in Grafana.

## Options considered

**One system — Elasticsearch/OpenSearch for both.** Store logs, derive metrics
from them. Rejected: computing a 30-day availability figure by aggregating log
lines is expensive and slow, and the retention needed for logs is different from
the retention needed for metrics. The cluster also becomes a significant operational
commitment of its own — heap tuning, shard management, and a recovery story.

**One system — a commercial observability platform.** Would work well. Rejected
for this context: the data is government financial information and the deployment
is on-premises, so a managed external service is not available. The self-hosted
tiers of those products are not materially simpler than Prometheus plus Loki.

**Metrics only.** Rejected: an alert tells you something is wrong; the log line
tells you what. Without logs, every incident escalates to whoever can read the
code.

**Prometheus + Loki.** Chosen. Loki indexes labels rather than content, which
makes it cheap to run at this volume, and it uses the same label model as
Prometheus — so the same query dimensions work in both, and Grafana can pivot from
a metric spike to the log lines underneath it.

## Consequences

**Good.** Each store does what it is good at. Metrics aggregate cheaply over long
windows; logs search cheaply over short ones. Shared label vocabulary makes the
pivot between them natural. Both are operationally modest at this scale.

**Bad.** Two systems to run, back up and upgrade. Correlation is by convention —
the label sets must be kept consistent, which is a discipline rather than a
guarantee.

**Risk.** Loki's cost model punishes high-cardinality labels severely. A promtail
pipeline that turns a request id into a label would make the system unusable
within days. Guarded by explicit limits in `loki.yml` and by keeping the label
extraction in `promtail.yml.j2` deliberately minimal — the comment there says so,
because this is the mistake that gets made.
