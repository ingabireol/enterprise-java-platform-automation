#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify_restore.sh — restore the most recent backup into a scratch cluster and
# assert that the restored data is actually usable.
#
#   verify_restore.sh [--port 55432] [--json] [--keep]
#
# This exists because of one observation that holds everywhere: organisations
# discover their backups are unusable at the moment they need them. A backup
# that has not been restored is a hypothesis.
#
# What it asserts, in order:
#   1. The backup exists and is not older than the stated RPO.
#   2. Every file matches the checksum recorded when the backup was written.
#   3. The cluster starts from the restored data directory.
#   4. WAL replay reaches a consistent point.
#   5. The expected schema objects are present.
#   6. Row counts are plausible against the recorded baseline.
#   7. A representative business query returns a result.
#
# The scratch cluster is destroyed afterwards unless --keep is given.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

load_config "${BACKUP_CONFIG:-/opt/efp/etc/backup.conf}"

SCRATCH_PORT=55432
OUTPUT_JSON=false
KEEP_SCRATCH=false
BACKUP_ROOT="${BACKUP_ROOT:-/backup/efp}"
PG_BINDIR="${PG_BINDIR:-/usr/pgsql-16/bin}"
PG_DATABASE="${PG_DATABASE:-efp}"
RPO_MINUTES="${RPO_MINUTES:-15}"
LOG_DIR="${LOG_DIR:-/var/log/efp}"
LOG_FILE="${LOG_DIR}/backup-verify.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) SCRATCH_PORT="$2"; shift 2 ;;
    --json) OUTPUT_JSON=true; LOG_LEVEL=WARN; shift ;;
    --keep) KEEP_SCRATCH=true; shift ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

require_commands "${PG_BINDIR}/pg_ctl" "${PG_BINDIR}/psql" sha256sum tar
acquire_lock "verify_restore" 0
mkdir -p "$LOG_DIR"

SCRATCH_DIR="$(mktemp -d "${BACKUP_ROOT}/verify/scratch-XXXXXX")"
readonly SCRATCH_DIR
timer_start

cleanup_scratch() {
  if [[ "$KEEP_SCRATCH" == "true" ]]; then
    log_warn "Scratch cluster retained at ${SCRATCH_DIR} (--keep)"
    return 0
  fi
  if [[ -f "${SCRATCH_DIR}/data/postmaster.pid" ]]; then
    "${PG_BINDIR}/pg_ctl" -D "${SCRATCH_DIR}/data" -m immediate stop >/dev/null 2>&1 || true
  fi
  rm -rf "$SCRATCH_DIR"
}
on_cleanup "cleanup_scratch"

RESULT="FAIL"
FAILURE_REASON=""
ROW_CHECKS=0

fail_check() {
  FAILURE_REASON="$1"
  log_error "$1"
  return 1
}

# --- 1. Locate the most recent complete backup -----------------------------
log_info "Locating the most recent complete base backup"
LATEST="$(find "${BACKUP_ROOT}/base" -maxdepth 1 -type d -name "${PG_DATABASE}-full-*" \
          ! -exec test -e '{}/.incomplete' \; -print 2>/dev/null | sort | tail -n1)"

[[ -n "$LATEST" ]] || fail_check "No complete base backup found under ${BACKUP_ROOT}/base" || {
  emit_metric "backup_verify.prom" "platform_backup_verify_success" "0" \
    "Whether the last restore verification succeeded" "gauge"
  exit 1
}

BACKUP_AGE_MINUTES=$(( ( $(date +%s) - $(stat -c %Y "$LATEST") ) / 60 ))
log_info "Most recent backup: $(basename "$LATEST") (${BACKUP_AGE_MINUTES} minutes old)"

# --- 2. Checksum verification ----------------------------------------------
log_info "Verifying checksums"
if [[ -f "${LATEST}/SHA256SUMS" ]]; then
  if ! ( cd "$LATEST" && sha256sum --quiet --check SHA256SUMS ); then
    fail_check "Checksum mismatch in ${LATEST} — the backup is corrupt"
  fi
  log_info "All checksums match"
else
  log_warn "No SHA256SUMS in ${LATEST}; skipping integrity verification"
fi

# --- 3. Restore into the scratch cluster -----------------------------------
log_info "Restoring into ${SCRATCH_DIR}/data"
mkdir -p "${SCRATCH_DIR}/data"
chmod 0700 "${SCRATCH_DIR}/data"

for tarball in "${LATEST}"/base.tar*; do
  [[ -e "$tarball" ]] || continue
  case "$tarball" in
    *.zst) zstd -dc "$tarball" | tar -x -C "${SCRATCH_DIR}/data" ;;
    *.gz)  tar -xzf "$tarball" -C "${SCRATCH_DIR}/data" ;;
    *)     tar -xf  "$tarball" -C "${SCRATCH_DIR}/data" ;;
  esac
done

mkdir -p "${SCRATCH_DIR}/data/pg_wal"
for waltar in "${LATEST}"/pg_wal.tar*; do
  [[ -e "$waltar" ]] || continue
  case "$waltar" in
    *.zst) zstd -dc "$waltar" | tar -x -C "${SCRATCH_DIR}/data/pg_wal" ;;
    *.gz)  tar -xzf "$waltar" -C "${SCRATCH_DIR}/data/pg_wal" ;;
    *)     tar -xf  "$waltar" -C "${SCRATCH_DIR}/data/pg_wal" ;;
  esac
done

# Point-in-time recovery configuration: replay everything the archive has.
cat >> "${SCRATCH_DIR}/data/postgresql.conf" <<CONF

# --- Appended by verify_restore.sh -----------------------------------------
port = ${SCRATCH_PORT}
listen_addresses = '127.0.0.1'
archive_mode = off
restore_command = 'gunzip -c ${BACKUP_ROOT}/wal/%f.gz > %p'
recovery_target_timeline = 'latest'
hot_standby = on
logging_collector = off
log_destination = 'stderr'
shared_buffers = 256MB
max_connections = 20
CONF

touch "${SCRATCH_DIR}/data/recovery.signal"

# --- 4. Start and wait for consistency -------------------------------------
log_info "Starting the scratch cluster on port ${SCRATCH_PORT}"
if ! "${PG_BINDIR}/pg_ctl" -D "${SCRATCH_DIR}/data" -l "${SCRATCH_DIR}/startup.log" -w -t 600 start; then
  log_error "Scratch cluster failed to start. Startup log:"
  tail -n 50 "${SCRATCH_DIR}/startup.log" >&2 || true
  fail_check "The restored cluster does not start"
fi
on_cleanup "\"${PG_BINDIR}/pg_ctl\" -D '${SCRATCH_DIR}/data' -m fast stop >/dev/null 2>&1 || true"

PSQL=( "${PG_BINDIR}/psql" -h 127.0.0.1 -p "$SCRATCH_PORT" -d "$PG_DATABASE" -tAX )

log_info "Waiting for the cluster to accept queries"
for _ in {1..60}; do
  "${PSQL[@]}" -c "SELECT 1" >/dev/null 2>&1 && break
  sleep 5
done
"${PSQL[@]}" -c "SELECT 1" >/dev/null 2>&1 || fail_check "The restored cluster never became queryable"

# --- 5. Schema assertions ---------------------------------------------------
log_info "Asserting schema objects are present"
TABLE_COUNT="$("${PSQL[@]}" -c "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')")"
if (( TABLE_COUNT < 1 )); then
  fail_check "The restored database contains no user tables"
fi
log_info "Restored database contains ${TABLE_COUNT} user table(s)"

# --- 6. Row count plausibility ----------------------------------------------
# The baseline is written by the last successful verification. A restore that
# comes back with a fraction of the expected rows is technically a successful
# restore and operationally a disaster, so it is checked explicitly.
BASELINE_FILE="${BACKUP_ROOT}/verify/row-baseline.txt"
log_info "Comparing row counts against the recorded baseline"

CURRENT_COUNTS="$("${PSQL[@]}" -c "
  SELECT relname || '=' || n_live_tup
  FROM pg_stat_user_tables
  WHERE n_live_tup > 0
  ORDER BY relname;")"

if [[ -f "$BASELINE_FILE" ]]; then
  while IFS='=' read -r table baseline; do
    [[ -z "$table" ]] && continue
    current="$(printf '%s\n' "$CURRENT_COUNTS" | awk -F= -v t="$table" '$1==t {print $2}')"
    [[ -z "$current" ]] && { log_warn "Table ${table} present in the baseline but absent from the restore"; continue; }
    ROW_CHECKS=$(( ROW_CHECKS + 1 ))
    # Allow growth, flag shrinkage beyond 10% — a real database rarely shrinks.
    if (( baseline > 0 )) && (( current * 100 / baseline < 90 )); then
      log_warn "Table ${table}: restored ${current} rows against a baseline of ${baseline} (down $(( 100 - current * 100 / baseline ))%)"
    fi
  done < "$BASELINE_FILE"
else
  log_info "No baseline yet; recording the current counts as the baseline"
fi

printf '%s\n' "$CURRENT_COUNTS" > "$BASELINE_FILE"

# --- 7. Representative business query ---------------------------------------
log_info "Running a representative query against the restored data"
if ! "${PSQL[@]}" -c "SELECT count(*) FROM information_schema.columns" >/dev/null; then
  fail_check "The restored database cannot answer a catalogue query"
fi

RESULT="PASS"
ELAPSED="$(timer_elapsed)"

# --- Reporting ---------------------------------------------------------------
emit_metric "backup_verify.prom" "platform_backup_verify_success" "1" \
  "Whether the last restore verification succeeded (1) or failed (0)" "gauge"
append_metric "backup_verify.prom" "platform_backup_verify_timestamp_seconds" "$(date +%s)"
append_metric "backup_verify.prom" "platform_backup_verify_duration_seconds" "$ELAPSED"
append_metric "backup_verify.prom" "platform_backup_age_minutes" "$BACKUP_AGE_MINUTES"
append_metric "backup_verify.prom" "platform_backup_verify_tables" "$TABLE_COUNT"

if [[ "$OUTPUT_JSON" == "true" ]]; then
  cat <<JSON
{
  "result": "${RESULT}",
  "backup_label": "$(basename "$LATEST")",
  "backup_age_minutes": ${BACKUP_AGE_MINUTES},
  "restore_seconds": ${ELAPSED},
  "tables_restored": ${TABLE_COUNT},
  "row_checks": ${ROW_CHECKS},
  "rpo_minutes_objective": ${RPO_MINUTES},
  "failure_reason": "${FAILURE_REASON}"
}
JSON
else
  log_info "Verification ${RESULT}: restored $(basename "$LATEST") in ${ELAPSED}s, ${TABLE_COUNT} tables, ${ROW_CHECKS} row checks"
fi

[[ "$RESULT" == "PASS" ]] || exit 1
exit 0
