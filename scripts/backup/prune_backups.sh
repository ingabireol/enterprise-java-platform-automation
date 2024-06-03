#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# prune_backups.sh — enforce the retention policy.
#
#   prune_backups.sh [--dry-run] [--retention-days N]
#
# Retention rules, in the order they are applied:
#   1. Never delete the most recent complete full backup, whatever its age.
#   2. Never delete a full backup that the WAL archive still depends on.
#   3. Keep every backup within the retention window.
#   4. Keep one full backup per month beyond the window, up to 12 months.
#   5. Delete everything else.
#
# Rule 1 exists because a retention policy that can delete your only backup is
# not a retention policy. Rule 2 exists because deleting a base backup orphans
# every WAL segment after it, which silently destroys point-in-time recovery.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

load_config "${BACKUP_CONFIG:-/opt/efp/etc/backup.conf}"

DRY_RUN=false
BACKUP_ROOT="${BACKUP_ROOT:-/backup/efp}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-35}"
MONTHLY_KEEP=12
PG_DATABASE="${PG_DATABASE:-efp}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --retention-days) RETENTION_DAYS="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

acquire_lock "prune_backups" 0
log_info "Pruning backups older than ${RETENTION_DAYS} days under ${BACKUP_ROOT}"
[[ "$DRY_RUN" == "true" ]] && log_warn "DRY RUN — nothing will be deleted"

remove() {
  local path="$1" reason="$2"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "WOULD DELETE ${path} (${reason})"
  else
    log_info "Deleting ${path} (${reason})"
    rm -rf "$path"
  fi
}

# --- Full backups -----------------------------------------------------------
mapfile -t FULL_BACKUPS < <(find "${BACKUP_ROOT}/base" -maxdepth 1 -type d -name "${PG_DATABASE}-full-*" | sort)

if (( ${#FULL_BACKUPS[@]} == 0 )); then
  log_warn "No full backups found — nothing to prune"
  exit 0
fi

NEWEST="${FULL_BACKUPS[-1]}"
log_info "Protecting the most recent full backup: $(basename "$NEWEST")"

CUTOFF_EPOCH=$(( $(date +%s) - RETENTION_DAYS * 86400 ))
declare -A MONTHLY_KEPT=()
KEPT=0
DELETED=0
FREED_BYTES=0

# Walk newest first so that the monthly retention keeps the newest backup in
# each month rather than the oldest.
for (( i=${#FULL_BACKUPS[@]}-1 ; i>=0 ; i-- )); do
  backup="${FULL_BACKUPS[i]}"
  name="$(basename "$backup")"
  mtime="$(stat -c %Y "$backup")"
  size="$(du -sb "$backup" | cut -f1)"
  month="$(date -d "@${mtime}" +%Y-%m)"

  # Rule 1
  if [[ "$backup" == "$NEWEST" ]]; then
    KEPT=$(( KEPT + 1 )); continue
  fi

  # Rule 3
  if (( mtime > CUTOFF_EPOCH )); then
    log_debug "Keeping ${name}: within the ${RETENTION_DAYS}-day window"
    KEPT=$(( KEPT + 1 )); continue
  fi

  # Rule 4
  if (( ${#MONTHLY_KEPT[@]} < MONTHLY_KEEP )) && [[ -z "${MONTHLY_KEPT[$month]:-}" ]]; then
    MONTHLY_KEPT[$month]=1
    log_debug "Keeping ${name}: monthly retention for ${month}"
    KEPT=$(( KEPT + 1 )); continue
  fi

  # Rule 5
  remove "$backup" "older than ${RETENTION_DAYS} days and not a monthly keeper"
  DELETED=$(( DELETED + 1 ))
  FREED_BYTES=$(( FREED_BYTES + size ))
done

# --- WAL segments -----------------------------------------------------------
# Rule 2: the oldest retained base backup defines how far back the WAL archive
# must reach. Segments older than that backup's start point are unreachable and
# safe to remove; anything newer is load-bearing.
OLDEST_KEPT=""
for backup in "${FULL_BACKUPS[@]}"; do
  [[ -d "$backup" ]] || continue
  OLDEST_KEPT="$backup"; break
done

if [[ -n "$OLDEST_KEPT" && -f "${OLDEST_KEPT}/backup.manifest" ]]; then
  OLDEST_EPOCH="$(stat -c %Y "$OLDEST_KEPT")"
  log_info "Oldest retained base backup: $(basename "$OLDEST_KEPT"); WAL before it is unreachable"

  while IFS= read -r wal; do
    wal_mtime="$(stat -c %Y "$wal")"
    if (( wal_mtime < OLDEST_EPOCH )); then
      size="$(stat -c %s "$wal")"
      remove "$wal" "predates the oldest retained base backup"
      FREED_BYTES=$(( FREED_BYTES + size ))
    fi
  done < <(find "${BACKUP_ROOT}/wal" -type f -name '*.gz')
else
  log_warn "Could not determine the oldest retained base backup; WAL archive left untouched"
fi

# --- Logical dumps ----------------------------------------------------------
while IFS= read -r dump; do
  mtime="$(stat -c %Y "$dump")"
  if (( mtime < CUTOFF_EPOCH )); then
    size="$(stat -c %s "$dump")"
    remove "$dump" "logical dump older than ${RETENTION_DAYS} days"
    rm -f "${dump}.sha256" "${dump}.toc" 2>/dev/null || true
    FREED_BYTES=$(( FREED_BYTES + size ))
  fi
done < <(find "${BACKUP_ROOT}/logical" -type f -name '*.dump')

log_info "Pruning complete: ${KEPT} full backup(s) retained, ${DELETED} removed, $(human_bytes "$FREED_BYTES") reclaimed"

emit_metric "backup_retention.prom" "platform_backup_retained_count" "$KEPT" \
  "Number of full backups retained after pruning" "gauge"
append_metric "backup_retention.prom" "platform_backup_pruned_bytes" "$FREED_BYTES"
append_metric "backup_retention.prom" "platform_backup_prune_timestamp_seconds" "$(date +%s)"
