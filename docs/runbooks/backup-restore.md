# Runbook: Backup and restore

**Recovery point objective (RPO): 15 minutes. Recovery time objective (RTO): 2 hours.**

Those are the numbers the backup design is built to meet. Every procedure below
is written so that meeting them is possible under pressure.

---

## What exists, and what each thing is for

| Artefact | Frequency | Retention | Restores | Location |
| --- | --- | --- | --- | --- |
| Physical base backup (`pg_basebackup`) | Weekly, Sunday 01:00 | 35 days + 12 monthly | The whole cluster to a point in time | `/backup/efp/base/` |
| WAL archive | Continuous (5-min ceiling) | Bounded by oldest base backup | The minutes between base backups | `/backup/efp/wal/` |
| Logical dump (`pg_dump`, custom format) | Nightly | 35 days | Individual tables or schemas | `/backup/efp/logical/` |
| Configuration snapshot | Nightly | 90 days | A host's configuration, and drift history | `/backup/efp/config/` |
| Offsite copy | After each run | 90 days | Everything, if the primary site is lost | DR site vault |

**The base backup plus WAL archive is the real recovery capability.** The logical
dump exists for the cases where restoring an entire cluster is the wrong tool —
someone truncated one table, or test needs an anonymised refresh.

---

## Verifying that the backups work

This is the part most organisations skip, and it is the part that determines
whether any of the rest matters.

```bash
# On demand
make backup-verify ENV=prod

# Or directly on the database host
ssh db-prod-01 'sudo -u postgres /opt/efp/bin/verify_restore.sh --port 55432'
```

The verification restores the newest backup into a scratch cluster on port 55432,
replays WAL, and asserts that the schema is present and row counts are plausible
against the previous run. It runs weekly on a timer and exports its result to
Prometheus, so a verification that stops running alerts on staleness rather than
disappearing quietly.

### Verification failure

A failed verification means the backup set is unproven. Treat it as an incident,
not as a chore.

```bash
# Run it again, keeping the scratch cluster so you can look at it
ssh db-prod-01 'sudo -u postgres /opt/efp/bin/verify_restore.sh --port 55432 --keep'
ssh db-prod-01 'cat /backup/efp/verify/scratch-*/startup.log'
```

| Failure | Meaning | Action |
| --- | --- | --- |
| Checksum mismatch | The backup is corrupt on disk | Discard it, take a fresh base backup immediately, investigate the storage |
| Cluster will not start | The base backup is incomplete | Check whether `pg_basebackup` was interrupted; take a fresh one |
| WAL replay fails | A gap in the archive | Check `archive_command` failures in the PostgreSQL log; the archive is not continuous |
| Row counts far below baseline | Backup taken from the wrong source, or data loss upstream | Stop and investigate before trusting any backup in the set |

---

## Restore: full cluster to a point in time

Use this when the database is lost or corrupted and you need everything back as
of a specific moment.

**Before you start:** stop the application tier. A partially restored database
receiving writes is worse than a down one.

```bash
ansible -i ansible/inventories/prod/hosts.yml appservers -m systemd \
  -a "name={{ item }} state=stopped" -e 'item=efp-core'
```

### Step 1 — Choose the recovery target

```bash
ls -1t /backup/efp/base/
cat /backup/efp/base/efp-full-<timestamp>/backup.manifest
```

The manifest records the WAL position the backup starts from. You can recover to
any point **after** that position for which WAL exists.

### Step 2 — Preserve the current data directory

Do not delete it. Move it. If the restore goes wrong, the damaged original may
still hold data the backup does not.

```bash
ssh db-prod-01 'sudo systemctl stop postgresql-16'
ssh db-prod-01 'sudo mv /var/lib/pgsql/16/data /var/lib/pgsql/16/data.damaged-$(date +%s)'
ssh db-prod-01 'sudo -u postgres mkdir -m 0700 /var/lib/pgsql/16/data'
```

### Step 3 — Restore the base backup

```bash
BACKUP=/backup/efp/base/efp-full-<timestamp>

ssh db-prod-01 "cd /var/lib/pgsql/16/data && sudo -u postgres zstd -dc ${BACKUP}/base.tar.zst | sudo -u postgres tar -x"
ssh db-prod-01 "sudo -u postgres mkdir -p /var/lib/pgsql/16/data/pg_wal"
ssh db-prod-01 "cd /var/lib/pgsql/16/data/pg_wal && sudo -u postgres zstd -dc ${BACKUP}/pg_wal.tar.zst | sudo -u postgres tar -x"
```

### Step 4 — Set the recovery target

```bash
sudo -u postgres tee -a /var/lib/pgsql/16/data/postgresql.conf <<'CONF'
restore_command = 'gunzip -c /backup/efp/wal/%f.gz > %p'
recovery_target_time = '2026-09-25 14:30:00+02'   # the moment you want back
recovery_target_action = 'promote'
CONF

sudo -u postgres touch /var/lib/pgsql/16/data/recovery.signal
```

To recover everything available rather than to a specific moment, omit
`recovery_target_time` and set `recovery_target_timeline = 'latest'`.

### Step 5 — Start and watch the replay

```bash
sudo systemctl start postgresql-16
sudo tail -f /var/lib/pgsql/16/data/log/postgresql-$(date +%F).log
```

Look for `consistent recovery state reached`, then `archive recovery complete`.
A replay that stalls is usually a missing WAL segment — the log names it.

### Step 6 — Verify before releasing to users

```bash
sudo -u postgres psql -d efp -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
sudo -u postgres psql -d efp -c "SELECT max(created_at) FROM <a busy table>;"   # confirms how far the recovery reached
```

Confirm the last transaction timestamp matches what you expected to recover to.
Only then start the application tier.

### Step 7 — Rebuild the replicas

The replicas are now following a timeline that no longer exists. They must be
rebuilt from the restored primary:

```bash
ansible-playbook -i ansible/inventories/prod/hosts.yml ansible/playbooks/site.yml \
  --limit db_replica --tags postgresql
```

---

## Restore: a single table

When someone truncated one table and everything else is fine, restoring the whole
cluster is the wrong instrument.

```bash
DUMP=/backup/efp/logical/efp-incremental-<timestamp>.dump

# What is in it?
pg_restore --list "$DUMP" | grep -i '<table name>'

# Restore into a scratch schema first — never straight over the live table
sudo -u postgres psql -d efp -c "CREATE SCHEMA restore_scratch;"
sudo -u postgres pg_restore --dbname=efp --table='<table>' --schema=public \
     --no-owner --data-only --superuser=postgres "$DUMP"
```

Restoring data-only over an existing table will conflict on primary keys. The
usual sequence is: restore into a scratch schema, inspect, then merge with an
explicit `INSERT ... SELECT ... ON CONFLICT` that you have read carefully.

---

## Backup job failures

```bash
ssh db-prod-01 'systemctl status pg-backup-full.service --no-pager'
ssh db-prod-01 'tail -100 /var/log/efp/backup.log'
ssh db-prod-01 'systemctl list-timers "pg-backup*" --no-pager'
```

| Symptom | Cause | Fix |
| --- | --- | --- |
| Exit 75, "already running" | Previous run still going | The window is too tight or the backup has grown; check duration trend on the DR dashboard |
| Exit 28, insufficient space | Backup volume full | Run `prune_backups.sh --dry-run` and review retention |
| Exit 69, cannot reach PostgreSQL | Database down or `pg_hba` refusing the backup host | Check the database first |
| Timer not listed | Timer disabled, probably during an earlier incident | `systemctl enable --now pg-backup-full.timer` |
| Runs succeed, alert says stale | Clock skew, or the metric file is not being scraped | Check `chronyc tracking` and the textfile collector directory |

Run a backup manually after fixing:

```bash
ssh db-prod-01 'sudo -u postgres /opt/efp/bin/pg_backup.sh --mode full --verbose'
```

---

## Retention

`prune_backups.sh` runs daily. Its rules, in order:

1. Never delete the most recent complete full backup, whatever its age.
2. Never delete a full backup the WAL archive still depends on.
3. Keep everything within 35 days.
4. Keep one full backup per month beyond that, up to 12 months.
5. Delete the rest.

Rule 1 exists because a retention policy that can delete your only backup is not
a retention policy. Rule 2 exists because deleting a base backup orphans every
WAL segment after it, which destroys point-in-time recovery without any error
message.

Always dry-run before changing retention:

```bash
ssh db-prod-01 'sudo /opt/efp/bin/prune_backups.sh --dry-run --retention-days 21'
```
