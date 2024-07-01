# Runbook: Deployment

**Principle: a deployment that cannot be reversed in under ten minutes is not
finished being designed.**

---

## Before the window

- [ ] Release version is a specific semantic version, not `latest`.
- [ ] Artefacts and their `.sha256` files are published and reachable.
- [ ] The release has been deployed to `test` and exercised there.
- [ ] Any database migration in this release has been reviewed for backward
      compatibility — see [Migrations](#migrations).
- [ ] Change record approved (production and DR only).
- [ ] Someone other than the deployer is available.

---

## Deploying

```bash
# Dry run first: confirms every artefact exists and checksums before touching a server
ansible-playbook -i ansible/inventories/prod/hosts.yml ansible/playbooks/deploy.yml \
  -e app_version=2.4.1 --check

# Deploy
make deploy ENV=prod VERSION=2.4.1
```

The playbook does this per node, one node at a time, stopping the whole rollout
if any node fails:

1. Write a rollback manifest recording the current release.
2. Drain the node from the load balancer and wait for in-flight requests.
3. Download and checksum-verify the artefacts into a versioned release directory.
4. Stop the services, repoint `current`, start them.
5. Wait for the readiness endpoint, then confirm `/actuator/info` reports the
   expected version.
6. Return the node to the pool and pause before starting the next.

**If it fails on node 1**, the other nodes are still serving the old version.
That is by design: stop, diagnose, and only then decide whether to continue or
roll back the one node.

### Deploying a single node by hand

```bash
ssh app-prod-02 'sudo /opt/efp/bin/deploy.sh --version 2.4.1'
```

---

## After the deployment

Watch for thirty minutes before declaring success. The Grafana annotation marks
the deployment; if the error line or the latency line steps up at the annotation,
that is causation until proven otherwise.

- Error rate — Platform Overview → Error rate by service
- p99 latency — Platform Overview → Latency percentiles
- Heap and GC — a new leak shows here before it shows as an outage
- Connection pool pending — a migration that added a slow query shows here first

---

## Rolling back

```bash
# Fleet-wide
ansible-playbook -i ansible/inventories/prod/hosts.yml ansible/playbooks/rollback.yml

# Single node
ssh app-prod-02 'sudo /opt/efp/bin/rollback.sh'

# To a specific earlier release
ssh app-prod-02 'sudo /opt/efp/bin/rollback.sh --to 2.3.7'
```

The rollback reads the manifest written before the deployment. It restores the
application code. **It does not revert database migrations.**

---

## Migrations

This is where deployments actually go wrong.

**The rule: every migration must be backward compatible with the previous
release.** Not "compatible enough" — compatible. That constraint is what makes
rollback possible at all, and it costs one extra release to satisfy.

The expand/contract pattern, across three releases:

| Release | Schema change | Code change |
| --- | --- | --- |
| N | Add the new column, nullable. Backfill. | Write to both old and new; read from old. |
| N+1 | None. | Read from new; still write to both. |
| N+2 | Drop the old column. | Write to new only. |

Any release can be rolled back to its predecessor, because the schema at each
step supports both code versions.

### When a migration has already been applied and the code must go back

1. **Check what was applied.**
   ```bash
   ssh db-prod-01 "sudo -u postgres psql -d efp -c \
     'SELECT version, description, installed_on FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 5;'"
   ```
2. **If the migration is additive** (new nullable column, new table, new index),
   the old code ignores it. Roll back the application and leave the schema.
3. **If the migration is destructive** (dropped or renamed column, changed type,
   `NOT NULL` added), the old code will fail against it. You have two options and
   both are unpleasant:
   - Fix forward. Usually faster and usually correct.
   - Restore the database to the pre-migration point and lose the transactions
     since — [backup-restore.md](backup-restore.md). Only if fixing forward is
     genuinely not possible.

The third option — writing a down-migration under pressure — is how a bad
deployment becomes a bad week.

---

## Deploying the ZK/Tomcat tier

The UI tier holds session state, so a restart logs users out. Deploy it outside
working hours where possible, and always one node at a time.

```bash
ssh zk-prod-01 'sudo /opt/efp/bin/drain.sh --out --wait'
ssh zk-prod-01 'sudo systemctl stop tomcat'
ssh zk-prod-01 'sudo -u tomcat cp /tmp/efp-ui-2.4.1.war /opt/tomcat/webapps/efp-ui.war'
ssh zk-prod-01 'sudo systemctl start tomcat'
ssh zk-prod-01 'sudo /opt/efp/bin/drain.sh --in'
```

Nginx uses `ip_hash` for this tier, so an individual user stays on one node for
the duration of their session. Draining lets existing sessions finish on the node
while new ones go elsewhere.

---

## Deploying the Angular frontend

Static assets, so this is the easy one — but the cache headers matter.

```bash
ansible -i ansible/inventories/prod/hosts.yml loadbalancers -m unarchive \
  -a "src=/tmp/efp-frontend-2.4.1.tar.gz dest=/var/www/efp owner=nginx group=nginx"
```

Build assets are fingerprinted and cached for a year; `index.html` is never
cached. That combination is what makes a frontend deployment atomic from the
browser's point of view: the new `index.html` references new asset filenames, and
a user mid-session keeps the old ones until they reload.

---

## Deployment troubleshooting

| Symptom | Cause | Action |
| --- | --- | --- |
| Checksum mismatch | Corrupt download or wrong artefact published | Re-download; verify the published checksum is for the right build |
| Service starts then exits 143 | systemd stopped it — usually `MemoryMax` | Compare `-Xmx` plus native memory against the unit's `MemoryMax` |
| Readiness never returns UP | Database unreachable, or a migration is still running | `journalctl -u efp-core -f`; check `pg_stat_activity` for the migration |
| "start request repeated too quickly" | Three failures in five minutes; systemd gave up | Read the *earlier* attempts' logs, fix, then `systemctl reset-failed` |
| Version in `/actuator/info` is wrong | The symlink did not move, or the build metadata is stale | `ls -l /opt/efp/current` |
| Node never returns to the pool | Drain marker left in place | `sudo /opt/efp/bin/drain.sh --in` |
