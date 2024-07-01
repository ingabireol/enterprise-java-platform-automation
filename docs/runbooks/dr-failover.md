# Runbook: Disaster recovery failover

**Objectives: RPO 15 minutes, RTO 2 hours.**
**Most recent measured values: see `docs/assessment/dr-drills/`.**

This runbook covers three distinct things, and conflating them is how drills turn
into outages:

1. **[A drill](#drill)** — planned, announced, reversible.
2. **[A real failover](#real-failover)** — the primary site is gone.
3. **[Failback](#failback)** — returning to the primary site afterwards.

---

## Before anything: the decision

A failover is a one-way door in the short term. Promoting the DR database breaks
replication and makes returning to the primary site a rebuild, not a switch.

**Declare a failover only when:**

- The primary site is unavailable and the estimated repair time exceeds the RTO, **or**
- The primary database is unrecoverable and a restore would exceed the RTO, **or**
- A drill is scheduled and announced.

**Who decides:** the platform lead, or in their absence the on-call engineer with
the service owner informed. Write the decision and its time down before acting.

**What you lose:** whatever replication had not yet transmitted. Measure it
before you promote — the number goes in the incident record:

```bash
ssh db-dr-01 "sudo -u postgres psql -c \"
  SELECT
    pg_last_wal_receive_lsn(),
    pg_last_wal_replay_lsn(),
    EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) AS lag_seconds;\""
```

---

## Drill

Quarterly. Announced. Uses the same mechanism as a real failover, which is the
point — a drill that uses a special path proves nothing about the real one.

```bash
ansible-playbook -i ansible/inventories/dr/hosts.yml ansible/playbooks/dr-drill.yml \
  -e drill_confirm=I-UNDERSTAND-THIS-PROMOTES-THE-DR-DATABASE
```

The playbook measures the achieved RPO and RTO, writes an evidence file to
`docs/assessment/dr-drills/`, and leaves the DR site running as a promoted
primary. **It does not redirect user traffic.**

### Reverting a drill

The DR database is now a primary on its own timeline. It cannot simply resume
replication — it must be rebuilt.

```bash
# 1. Stop the DR application tier
ansible -i ansible/inventories/dr/hosts.yml appservers:tomcat_nodes \
  -m shell -a "systemctl stop 'efp-*' tomcat"

# 2. Remove the drill marker row
ssh db-dr-01 "sudo -u postgres psql -d efp -c 'DROP TABLE IF EXISTS dr_drill_marker;'"

# 3. Rebuild the standby from the production primary
ansible-playbook -i ansible/inventories/dr/hosts.yml ansible/playbooks/site.yml \
  --limit db-dr-01 --tags postgresql -e postgresql_force_rebuild=true

# 4. Confirm replication has resumed
ssh db-prod-01 "sudo -u postgres psql -c 'SELECT application_name, state, sync_state FROM pg_stat_replication;'"
```

**The drill is not complete until step 4 confirms replication.** A DR site left
un-rebuilt after a drill is worse than no DR site, because everyone believes it
is there.

---

## Real failover

### Phase 1 — Confirm and record (target: 10 minutes)

```bash
# Is the primary genuinely gone, or is this a network partition?
ping -c 3 db-prod-01 lb-prod-01 app-prod-01
curl -sS --max-time 5 https://efp.example.gov/healthz

# From a third location, if you have one. A partition looks identical to an
# outage from one vantage point, and failing over during a partition produces
# two live primaries.
```

Record: the time, who decided, the measured replication lag, and what was
observed. This is the incident record's most valuable content and it will not be
reconstructable later.

### Phase 2 — Promote the database (target: 10 minutes)

```bash
ssh db-dr-01 'sudo -u postgres /usr/pgsql-16/bin/pg_ctl promote -D /var/lib/pgsql/16/data'

# Confirm it has left recovery
ssh db-dr-01 "sudo -u postgres psql -c 'SELECT pg_is_in_recovery();'"   # expect: f

# Confirm it accepts writes
ssh db-dr-01 "sudo -u postgres psql -d efp -c 'CREATE TABLE failover_marker(t timestamptz default now()); INSERT INTO failover_marker DEFAULT VALUES;'"
```

### Phase 3 — Start the application tier (target: 20 minutes)

```bash
ansible -i ansible/inventories/dr/hosts.yml appservers \
  -m systemd -a "name=efp-core state=started"
ansible -i ansible/inventories/dr/hosts.yml appservers \
  -m systemd -a "name=efp-reporting state=started"
ansible -i ansible/inventories/dr/hosts.yml appservers \
  -m systemd -a "name=efp-integration state=started"
ansible -i ansible/inventories/dr/hosts.yml tomcat_nodes \
  -m systemd -a "name=tomcat state=started"

# Wait for readiness
ansible -i ansible/inventories/dr/hosts.yml appservers -m uri \
  -a "url=http://127.0.0.1:9081/actuator/health/readiness status_code=200"
```

### Phase 4 — Redirect traffic (target: 15 minutes, plus DNS propagation)

```bash
ansible -i ansible/inventories/dr/hosts.yml loadbalancers -m systemd \
  -a "name=nginx state=started"
ansible -i ansible/inventories/dr/hosts.yml loadbalancers -m systemd \
  -a "name=keepalived state=started"
```

Then update DNS or the global load balancer to point `efp.example.gov` at the DR
edge. **TTL is the thing that hurts here** — if the record's TTL is an hour, the
last users arrive an hour after you finish. Lowering TTLs in advance is part of DR
preparedness, not part of the failover.

### Phase 5 — Verify (target: 15 minutes)

```bash
curl -sS https://efp.example.gov/healthz
curl -sS https://efp.example.gov/api/core/actuator/health

ansible -i ansible/inventories/dr/hosts.yml appservers -m shell \
  -a "/opt/efp/bin/health_check.sh"
```

Have a service owner exercise a real business transaction end to end. A green
health check and a working platform are not the same claim.

### Phase 6 — Re-establish protection

The DR site is now production **with no disaster recovery of its own.** Until
that is fixed, a second failure is unrecoverable.

```bash
# Backups must run here now
ssh bkp-dr-01 'sudo systemctl enable --now pg-backup-full.timer pg-backup-incremental.timer'
ssh db-dr-01 'sudo -u postgres /opt/efp/bin/pg_backup.sh --mode full'

# And be verified
ssh db-dr-01 'sudo -u postgres /opt/efp/bin/verify_restore.sh --port 55432'
```

---

## Failback

Failing back is a planned migration, not an emergency. Schedule it.

1. **Rebuild the primary site** from the current production (which is DR). The
   old primary's data is stale and must not be reintroduced.
   ```bash
   ansible-playbook -i ansible/inventories/prod/hosts.yml ansible/playbooks/site.yml \
     --limit databases --tags postgresql
   ```
2. **Let it catch up.** Confirm replication lag is near zero and stable for at
   least an hour.
3. **Take a maintenance window.** Failback involves a brief write outage; there
   is no way around it and pretending otherwise produces split-brain.
4. **Stop writes at DR**, wait for the primary to catch up fully, promote the
   primary, repoint DNS.
5. **Rebuild DR as a standby** of the restored primary.
6. **Verify, then run a drill** within the following month — the failback has
   changed things, and the next drill is the only thing that will find out what.

---

## Replication lag

Lag is the recovery point objective made visible: it is exactly how much data a
failover would lose right now.

```bash
# From the primary
ssh db-prod-01 "sudo -u postgres psql -c \"
  SELECT application_name,
         pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)   AS pending_send,
         pg_wal_lsn_diff(sent_lsn, replay_lsn)             AS pending_replay,
         state, sync_state
  FROM pg_stat_replication;\""
```

| Pattern | Cause | Action |
| --- | --- | --- |
| `pending_send` growing | Network between sites is the bottleneck | Check WAN throughput and any traffic shaping |
| `pending_replay` growing | The replica cannot apply fast enough | Check replica I/O and whether a long read query is blocking replay |
| Both zero, not advancing | Replication has stopped | Check the WAL sender on the primary and the receiver on the replica |
| Sawtooth, peaks at 01:00 | A batch job generating WAL faster than it ships | Expected; confirm it drains before the next batch |
