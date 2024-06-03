#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pg_backup.sh — PostgreSQL backup for the platform.
#
#   pg_backup.sh --mode full          Physical base backup + WAL archive sync
#   pg_backup.sh --mode incremental   WAL archive sync + logical dump
#   pg_backup.sh --mode logical       Logical dump only (pg_dump, custom format)
#
# Design notes:
#   * A backup that nobody notices failing is worse than no backup, so every run
#     writes a Prometheus metric with its outcome, duration and size, and the
#     alert rules in monitoring/prometheus/alerts/ fire on staleness, not just
#     on an explicit failure.
#   * Every archive is checksummed on write. verify_restore.sh re-checks the
#     checksum before restoring, so bit rot surfaces during a drill rather than
#     during a recovery.
#   * The script refuses to start if the previous run is still going, and it
#     refuses to start if there is not enough space to finish.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

load_config "${BACKUP_CONFIG:-/opt/efp/etc/backup.conf}"

# --- Defaults (overridden by backup.conf) ----------------------------------
MODE=""
BACKUP_ROOT="${BACKUP_ROOT:-/backup/efp}"
PG_BINDIR="${PG_BINDIR:-/usr/pgsql-16/bin}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
PG_DATABASE="${PG_DATABASE:-efp}"
PG_ARCHIVE_DIR="${PG_ARCHIVE_DIR:-/var/lib/pgsql/wal_archive}"
PG_REPLICATION_USER="${PG_REPLICATION_USER:-replicator}"
BACKUP_COMPRESSION="${BACKUP_COMPRESSION:-zstd}"
BACKUP_ENCRYPT="${BACKUP_ENCRYPT:-false}"
OFFSITE_ENABLED="${OFFSITE_ENABLED:-false}"
OFFSITE_TARGET="${OFFSITE_TARGET:-}"
LOG_DIR="${LOG_DIR:-/var/log/efp}"
LOG_FILE="${LOG_DIR}/backup.log"

usage() {
  sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- Argument parsing ------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)      MODE="$2"; shift 2 ;;
    --root)      BACKUP_ROOT="$2"; shift 2 ;;
    --no-offsite) OFFSITE_ENABLED=false; shift ;;
    --verbose)   LOG_LEVEL=DEBUG; shift ;;
    -h|--help)   usage 0 ;;
    *)           die "Unknown argument: $1. Try --help." 2 ;;
  esac
done

[[ -n "$MODE" ]] || die "--mode is required (full|incremental|logical)" 2
case "$MODE" in
  full|incremental|logical) ;;
  *) die "Invalid mode '${MODE}'. Expected full, incremental or logical." 2 ;;
esac

require_commands "${PG_BINDIR}/pg_basebackup" "${PG_BINDIR}/pg_dump" "${PG_BINDIR}/psql" sha256sum
mkdir -p "$LOG_DIR"
acquire_lock "pg_backup" 0

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LABEL="${PG_DATABASE}-${MODE}-${TIMESTAMP}"
readonly TIMESTAMP LABEL

log_info "Starting ${MODE} backup: ${LABEL}"
timer_start

# --- Compression selection -------------------------------------------------
case "$BACKUP_COMPRESSION" in
  zstd) COMPRESS_CMD="zstd -T0 -3 -q"; COMPRESS_EXT="zst" ;;
  gzip) COMPRESS_CMD="gzip -6";        COMPRESS_EXT="gz"  ;;
  none) COMPRESS_CMD="cat";            COMPRESS_EXT=""    ;;
  *)    die "Unsupported compression: ${BACKUP_COMPRESSION}" 2 ;;
esac

# --- Failure handling ------------------------------------------------------
# Whatever happens, the outcome reaches Prometheus. A silent failure here is the
# failure mode that actually loses data.
report_failure() {
  local rc=$?
  if (( rc != 0 )); then
    emit_metric "backup_status.prom" "platform_backup_success" "0" \
      "Whether the last backup run succeeded (1) or failed (0)" "gauge" \
      "mode=\"${MODE}\",database=\"${PG_DATABASE}\""
    append_metric "backup_status.prom" "platform_backup_last_attempt_timestamp_seconds" "$(date +%s)" \
      "mode=\"${MODE}\""
    notify "Backup FAILED: ${LABEL}" \
      "The ${MODE} backup of ${PG_DATABASE} on $(hostname -f) failed with exit code ${rc}.

Check ${LOG_FILE} and docs/runbooks/backup-restore.md." \
      critical
  fi
  return "$rc"
}
on_cleanup "report_failure"

# --- Connectivity ----------------------------------------------------------
retry 3 "${PG_BINDIR}/psql" -h "$PG_HOST" -p "$PG_PORT" -d "$PG_DATABASE" -tAc "SELECT 1" >/dev/null \
  || die "Cannot reach PostgreSQL at ${PG_HOST}:${PG_PORT}" 69

DB_SIZE_BYTES="$("${PG_BINDIR}/psql" -h "$PG_HOST" -p "$PG_PORT" -d "$PG_DATABASE" -tAc \
  "SELECT pg_database_size('${PG_DATABASE}')")"
log_info "Database size: $(human_bytes "$DB_SIZE_BYTES")"

# Require 1.3x the database size — compression usually does better, but a backup
# that fails at 95% because the filesystem filled is the worst possible outcome.
REQUIRED_MB=$(( DB_SIZE_BYTES / 1024 / 1024 * 13 / 10 ))
require_free_space "$BACKUP_ROOT" "$REQUIRED_MB"

# ===========================================================================
# Full: physical base backup
# ===========================================================================
do_full_backup() {
  local target="${BACKUP_ROOT}/base/${LABEL}"
  mkdir -p "$target"
  on_cleanup "[[ -f '${target}/.incomplete' ]] && rm -rf '${target}'"
  touch "${target}/.incomplete"

  log_info "Taking base backup into ${target}"

  # --checkpoint=fast forces an immediate checkpoint rather than waiting for the
  # next scheduled one; on a busy cluster that wait can be 15 minutes of nothing
  # happening, which looks like a hung backup.
  "${PG_BINDIR}/pg_basebackup" \
    --host="$PG_HOST" \
    --port="$PG_PORT" \
    --username="$PG_REPLICATION_USER" \
    --pgdata="$target" \
    --format=tar \
    --wal-method=stream \
    --checkpoint=fast \
    --compress="${BACKUP_COMPRESSION}:3" \
    --progress \
    --verbose \
    --label="$LABEL" \
    2>&1 | while IFS= read -r line; do log_debug "pg_basebackup: ${line}"; done

  log_info "Computing checksums"
  ( cd "$target" && find . -type f ! -name '.incomplete' ! -name 'SHA256SUMS' \
      -exec sha256sum {} + > SHA256SUMS )

  # The manifest is what a restore reads first. It is plain text on purpose:
  # whoever needs it will be reading it under pressure.
  cat > "${target}/backup.manifest" <<MANIFEST
label=${LABEL}
mode=full
database=${PG_DATABASE}
source_host=${PG_HOST}:${PG_PORT}
started_utc=${TIMESTAMP}
finished_utc=$(date -u +%Y%m%dT%H%M%SZ)
database_size_bytes=${DB_SIZE_BYTES}
backup_size_bytes=$(du -sb "$target" | cut -f1)
postgresql_version=$("${PG_BINDIR}/psql" -h "$PG_HOST" -p "$PG_PORT" -tAc "SHOW server_version")
wal_start=$("${PG_BINDIR}/psql" -h "$PG_HOST" -p "$PG_PORT" -tAc "SELECT pg_current_wal_lsn()")
compression=${BACKUP_COMPRESSION}
checksum_file=SHA256SUMS
restore_procedure=docs/runbooks/backup-restore.md
MANIFEST

  rm -f "${target}/.incomplete"
  log_info "Base backup complete: $(human_bytes "$(du -sb "$target" | cut -f1)")"
  printf '%s' "$target"
}

# ===========================================================================
# WAL archive synchronisation — this is what makes point-in-time recovery work
# ===========================================================================
sync_wal_archive() {
  local target="${BACKUP_ROOT}/wal"
  mkdir -p "$target"

  if [[ ! -d "$PG_ARCHIVE_DIR" ]]; then
    log_warn "WAL archive directory ${PG_ARCHIVE_DIR} does not exist; skipping WAL sync"
    return 0
  fi

  log_info "Synchronising WAL archive"
  rsync --archive --delete-delay --partial --human-readable \
        --exclude='*.partial' \
        "${PG_ARCHIVE_DIR}/" "${target}/" \
    || die "WAL archive synchronisation failed" 1

  local wal_count wal_bytes
  wal_count="$(find "$target" -type f -name '*.gz' | wc -l)"
  wal_bytes="$(du -sb "$target" | cut -f1)"
  log_info "WAL archive: ${wal_count} segment(s), $(human_bytes "$wal_bytes")"

  append_metric "backup_status.prom" "platform_wal_archive_segments" "$wal_count"
  append_metric "backup_status.prom" "platform_wal_archive_bytes" "$wal_bytes"
}

# ===========================================================================
# Logical dump — for selective restores and for the anonymised test refresh
# ===========================================================================
do_logical_backup() {
  local target="${BACKUP_ROOT}/logical/${LABEL}.dump"
  mkdir -p "$(dirname "$target")"

  log_info "Taking logical dump into ${target}"

  # Custom format: restorable selectively with pg_restore -t/-n, and compressed
  # by pg_dump itself so the whole thing stays a single verifiable file.
  "${PG_BINDIR}/pg_dump" \
    --host="$PG_HOST" \
    --port="$PG_PORT" \
    --dbname="$PG_DATABASE" \
    --format=custom \
    --compress=6 \
    --no-owner \
    --no-privileges \
    --verbose \
    --file="$target" \
    2>&1 | while IFS= read -r line; do log_debug "pg_dump: ${line}"; done

  sha256sum "$target" > "${target}.sha256"

  # Verify the dump is readable before we claim it as a backup.
  "${PG_BINDIR}/pg_restore" --list "$target" > "${target}.toc" \
    || die "The logical dump is unreadable — treating this run as failed" 1

  local size
  size="$(stat -c %s "$target")"
  log_info "Logical dump complete: $(human_bytes "$size"), $(wc -l < "${target}.toc") object(s)"
  printf '%s' "$target"
}

# ===========================================================================
# Offsite copy
# ===========================================================================
copy_offsite() {
  local source="$1"
  [[ "$OFFSITE_ENABLED" == "true" ]] || { log_debug "Offsite copy disabled"; return 0; }
  [[ -n "$OFFSITE_TARGET" ]] || { log_warn "Offsite enabled but no target configured"; return 0; }

  log_info "Copying ${source} offsite to ${OFFSITE_TARGET}"
  retry 3 rsync --archive --compress --partial --human-readable \
        --bwlimit="${OFFSITE_BWLIMIT:-50000}" \
        "$source" "${OFFSITE_TARGET}/" \
    || { log_error "Offsite copy failed — the local backup is intact but not replicated"; return 1; }

  log_info "Offsite copy complete"
}

# ===========================================================================
# Main
# ===========================================================================
ARTIFACT=""
case "$MODE" in
  full)
    ARTIFACT="$(do_full_backup)"
    sync_wal_archive
    ;;
  incremental)
    sync_wal_archive
    ARTIFACT="$(do_logical_backup)"
    ;;
  logical)
    ARTIFACT="$(do_logical_backup)"
    ;;
esac

copy_offsite "$ARTIFACT" || log_warn "Continuing despite offsite failure"

ELAPSED="$(timer_elapsed)"
SIZE_BYTES="$(du -sb "$ARTIFACT" | cut -f1)"

emit_metric "backup_status.prom" "platform_backup_success" "1" \
  "Whether the last backup run succeeded (1) or failed (0)" "gauge" \
  "mode=\"${MODE}\",database=\"${PG_DATABASE}\""
append_metric "backup_status.prom" "platform_backup_last_success_timestamp_seconds" "$(date +%s)" \
  "mode=\"${MODE}\""
append_metric "backup_status.prom" "platform_backup_duration_seconds" "$ELAPSED" \
  "mode=\"${MODE}\""
append_metric "backup_status.prom" "platform_backup_size_bytes" "$SIZE_BYTES" \
  "mode=\"${MODE}\""

log_info "Backup ${LABEL} completed in ${ELAPSED}s, $(human_bytes "$SIZE_BYTES")"
exit 0
