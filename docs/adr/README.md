# Architecture decision records

Short records of decisions that were genuinely contested, written at the time,
including the options that were rejected and why.

The purpose is not documentation for its own sake. It is so that in eighteen
months, when someone asks "why on earth is it done this way", the answer exists
and is honest — including the cases where the reasoning has since stopped
applying, which is exactly when it is most useful to know what the reasoning was.

| ADR | Decision |
| --- | --- |
| [0001](0001-ansible-over-shell-provisioning.md) | Ansible as the configuration source of truth |
| [0002](0002-systemd-over-container-runtime.md) | systemd units rather than containers for the application tier |
| [0003](0003-streaming-replication-for-dr.md) | Streaming replication with manual promotion for DR |
| [0004](0004-prometheus-loki-split.md) | Separate metrics and log pipelines |
