# Runbook: Incident response

**Read this first when something is broken and you do not yet know what.**

---

## First five minutes

Do these in order. Do not skip to diagnosis.

```bash
# 1. Is the platform up from outside itself?
curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' https://efp.example.gov/healthz

# 2. What does the platform think of itself?
ssh app-prod-01 '/opt/efp/bin/health_check.sh'

# 3. What is already known?
#    Grafana → Platform Overview, last 6 hours. Look for the moment it changed.
#    Alertmanager → currently firing.

# 4. What changed recently?
ssh app-prod-01 'cat /opt/efp/etc/rollback.manifest'
#    A deployment in the last hour is the first hypothesis, always.
```

**Declare an incident** if users are affected or if you cannot answer "is this
getting worse?" within five minutes. Declaring early costs nothing; declaring
late costs the first hour.

---

## Triage: which layer?

Work from the outside in. The point is to stop looking at the wrong layer, which
is where most of the time in a bad incident goes.

| Symptom | Likely layer | Go to |
| --- | --- | --- |
| Nothing responds at all, connection refused | Edge / network | [Edge](#edge) |
| TLS error or certificate warning | Edge | [tls-certificate-rotation.md](tls-certificate-rotation.md) |
| 502 / 503 from nginx | Application tier down | [Service down](#service-down) |
| 500s from the application | Application or database | [Error rate](#error-rate) |
| Everything slow, no errors | JVM, database, or storage | [Latency](#latency) |
| One node bad, others fine | That node | [Host down](#host-down) |
| Slow then errors then recovery, cyclic | GC or connection pool | [JVM](#jvm) / [Connection pool](#connection-pool) |

Run the log triage script early — it does the first six commands you were going
to run anyway:

```bash
ssh app-prod-01 '/opt/efp/bin/log_triage.sh --since "1 hour ago"'
```

---

## Edge

The edge is nginx plus the VIP. If nothing responds at all, check in this order.

```bash
# Does the VIP exist, and where?
ansible -i ansible/inventories/prod/hosts.yml loadbalancers -m shell -a "ip addr show | grep 10.30.10.10"
# Exactly one node should hold it. Zero means keepalived gave up on both.
# Two means a split brain — check VRRP reachability between the peers.

ansible -i ansible/inventories/prod/hosts.yml loadbalancers -m shell -a "systemctl status nginx keepalived --no-pager"

# Is the on-disk config valid? A running nginx with a broken config fails on reload.
ansible -i ansible/inventories/prod/hosts.yml loadbalancers -m shell -a "nginx -t"

# Recent errors
ssh lb-prod-01 'tail -100 /var/log/nginx/error.log'
```

**Zero nodes hold the VIP.** Both keepalived health checks are failing, which
means neither node can reach any application server. That is an application-tier
problem wearing an edge costume — go to [Service down](#service-down).

**Both nodes hold the VIP.** The peers cannot see each other's VRRP
advertisements. Check connectivity between them and the firewall rules for
protocol 112.

---

## Service down

```bash
# Which instances are actually up?
ansible -i ansible/inventories/prod/hosts.yml appservers -m shell \
  -a "systemctl is-active efp-core efp-reporting efp-integration"

# Why did it stop?
ssh app-prod-02 'journalctl -u efp-core -n 200 --no-pager'
```

**Look for these specifically, in this order:**

1. **An OOM kill.** `journalctl -k | grep -i 'killed process'`. If the kernel
   killed the JVM, restarting it without changing anything will produce the same
   result. Check `MemoryMax` in the unit against `-Xmx` plus native memory.
2. **A start limit.** `systemctl status efp-core` showing "start request repeated
   too quickly" means systemd has given up after three failures in five minutes.
   The real error is in the earlier restart attempts, not the last one. Reset with
   `systemctl reset-failed efp-core` *after* you have read the logs.
3. **A failed deployment.** Compare `/opt/efp/current` against the rollback
   manifest. If the release changed in the last hour, roll back first and diagnose
   afterwards:
   ```bash
   ssh app-prod-02 'sudo /opt/efp/bin/rollback.sh'
   ```
4. **The database is unreachable.** The service will start and fail readiness.
   Go to [Database](#database).

**If all instances are down**, this is a full outage. Consider whether the cause
is site-level — if so, [dr-failover.md](dr-failover.md).

---

## Host down

```bash
ping -c 3 app-prod-02
ssh app-prod-02 uptime          # if this works, the host is up and something else is wrong
```

**Host is up but was recently rebooted** (`node_time_seconds - node_boot_time_seconds`
is small): check `last -x reboot` and the kernel log for a panic. An unplanned
reboot that nobody ordered is a hardware or hypervisor question.

**Host is unreachable:** confirm the load balancer has taken it out of the pool
(it should have, within 15 seconds), then escalate to the infrastructure team.
The platform should be serving on the remaining nodes — verify that before
spending time on the dead host.

---

## Error rate

Errors above the threshold with the service up.

```bash
# What is failing, and is it one endpoint or all of them?
ssh lb-prod-01 "awk '\$9 ~ /^5/ {print \$7, \$9}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20"

# What does the application say?
ssh app-prod-01 "grep -E 'ERROR|FATAL' /var/log/efp/efp-core.log | tail -50"

# Error classes, grouped
ssh app-prod-01 '/opt/efp/bin/log_triage.sh --since "30 minutes ago"'
```

**One endpoint failing, others fine** → an application bug or a downstream
integration. Check the integration service logs.

**All endpoints failing** → something shared: the database, the connection pool,
or a configuration change. Check the database first.

**Started at a deployment** → roll back. The Grafana annotation on the Platform
Overview dashboard marks deployments; if the error line starts at the annotation,
that is your answer and further diagnosis can happen after service is restored.

---

## Latency

Slow with no errors, or slow before errors.

Work down the stack. Each step rules out a layer:

```bash
# 1. Is the JVM spending its time in GC rather than serving?
#    Grafana → Platform Overview → GC overhead. Above 10% is your answer.

# 2. Are requests queueing for a database connection?
#    Grafana → Connection pool utilisation. Any sustained "pending" is your answer.

# 3. Is the database slow?
ssh db-prod-01 "sudo -u postgres psql -c \"
  SELECT pid, now()-query_start AS duration, state, left(query,100)
  FROM pg_stat_activity
  WHERE state != 'idle' AND now()-query_start > interval '5 seconds'
  ORDER BY duration DESC;\""

# 4. Is storage slow?
ssh db-prod-01 'iostat -xz 2 3'    # %util near 100 and high await = storage bound
```

The order matters: a slow database produces pool exhaustion produces high
latency, and fixing the pool would be treating the symptom.

---

## JVM

**Heap pressure with high GC overhead** — a real memory problem.

```bash
PID=$(systemctl show -p MainPID --value efp-core)

# Capture evidence BEFORE restarting. A restart destroys the only copy.
ssh app-prod-01 "sudo -u efpsvc jcmd $PID GC.heap_info"
ssh app-prod-01 "sudo -u efpsvc jcmd $PID Thread.print > /var/log/efp/threaddump-$(date +%s).txt"
ssh app-prod-01 "sudo -u efpsvc jcmd $PID GC.heap_dump /var/log/efp/heapdumps/manual-$(date +%s).hprof"
# A heap dump is roughly the size of the heap. Check disk space first.

# Then restart, one node at a time
ssh app-prod-01 'sudo /opt/efp/bin/rolling_restart.sh --service efp-core --reason "gc thrashing"'
```

**Heap pressure with normal GC overhead** — the heap is simply well used. Not an
incident. Review sizing at leisure.

**High thread count** — almost always an unbounded pool or threads blocked on
something. The thread dump will show a common stack; that stack is the answer.

---

## Connection pool

Threads waiting for a database connection.

```bash
# How many connections does the database actually have, and from whom?
ssh db-prod-01 "sudo -u postgres psql -c \"
  SELECT application_name, state, count(*)
  FROM pg_stat_activity GROUP BY 1,2 ORDER BY 3 DESC;\""
```

**Many sessions idle in transaction** — the application is opening transactions
and not closing them. Terminate the orphans to restore service, then find the code
path:

```bash
ssh db-prod-01 "sudo -u postgres psql -c \"
  SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE state = 'idle in transaction' AND now()-state_change > interval '10 minutes';\""
```

**Many sessions active and slow** — the pool is exhausted because the database is
slow. Enlarging the pool makes it worse; find the slow query.

---

## Database

```bash
ssh db-prod-01 'systemctl status postgresql-16 --no-pager'
ssh db-prod-01 'tail -100 /var/lib/pgsql/16/data/log/postgresql-$(date +%F).log'

# Replication health
ssh db-prod-01 "sudo -u postgres psql -c 'SELECT * FROM pg_stat_replication;'"
```

**Disk full** is the most common cause of a PostgreSQL that has stopped accepting
writes. `df -h /var/lib/pgsql`. If WAL has filled the filesystem, free space
elsewhere first — deleting WAL by hand destroys recoverability.

**Cannot start after a crash** → [backup-restore.md](backup-restore.md).

---

## Disk space

```bash
ansible -i ansible/inventories/prod/hosts.yml platform -m shell -a "df -hP | awk 'NR==1 || \$5+0>80'"

# What is actually using it?
ssh app-prod-01 'du -xh /var /opt 2>/dev/null | sort -rh | head -20'
```

Usual suspects, in order of likelihood: an unrotated log, a heap dump from an
earlier incident, old release directories, and a WAL archive that stopped being
pruned.

```bash
# Safe immediate reclaim
ssh app-prod-01 'sudo journalctl --vacuum-size=500M'
ssh app-prod-01 'sudo logrotate -f /etc/logrotate.d/efp'
ssh app-prod-01 'ls -1dt /opt/efp/releases/*/ | tail -n +6 | xargs -r sudo rm -rf'
```

Never delete from `/var/lib/pgsql/wal_archive` to free space during an incident.
That is the point-in-time recovery capability.

---

## Memory

Swap in use on a JVM host means heap plus native memory exceeds what the host
has. The immediate fix is to reduce `-Xmx`; the real fix is right-sizing the host
or the service.

```bash
ssh app-prod-01 'free -h; systemctl show -p MemoryMax efp-core'
```

---

## Closing an incident

Before you stand down:

1. **Confirm recovery from outside**, not just from the health endpoint.
2. **Preserve evidence** — thread dumps, heap dumps, and the relevant log window
   copied somewhere that does not rotate.
3. **Write what happened while it is fresh.** Timeline, what was tried, what
   worked. The version written the next morning is always worse.
4. **Check whether anything is still degraded** — a node left drained, a service
   running on a rolled-back version, a timer disabled during triage.

```bash
ansible -i ansible/inventories/prod/hosts.yml appservers -m shell -a "/opt/efp/bin/drain.sh --status"
ansible -i ansible/inventories/prod/hosts.yml platform -m shell -a "systemctl list-timers --no-pager | grep -E 'backup|verify'"
```

The review afterwards asks what made the incident hard to diagnose, not who
caused it. The first question produces improvements; the second produces silence.
