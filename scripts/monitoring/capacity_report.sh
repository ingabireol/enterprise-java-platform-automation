#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# capacity_report.sh — monthly capacity and growth report.
#
#   capacity_report.sh [--days 30] [--format text|csv]
#
# Answers the question a capacity plan actually needs: not "how full is it now"
# but "when, at the current rate, will it be full". Uses a simple linear
# projection over the observed window, which is crude but honest — and far more
# useful than a snapshot.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

DAYS=30
FORMAT=text
HISTORY_FILE="${CAPACITY_HISTORY:-/var/lib/efp/capacity-history.csv}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)   DAYS="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

mkdir -p "$(dirname "$HISTORY_FILE")"
[[ -f "$HISTORY_FILE" ]] || echo "timestamp,metric,value" > "$HISTORY_FILE"

NOW="$(date +%s)"

# --- Record today's readings ------------------------------------------------
record_metric() { printf '%s,%s,%s\n' "$NOW" "$1" "$2" >> "$HISTORY_FILE"; }

while read -r fs _ used _ _ mount; do
  [[ "$fs" == "Filesystem" ]] && continue
  case "$mount" in
    /|/var|/opt|/backup) record_metric "disk_used_kb:${mount}" "$used" ;;
  esac
done < <(df -Pk)

if command -v psql >/dev/null 2>&1 && systemctl is-active --quiet 'postgresql-*' 2>/dev/null; then
  DB_SIZE="$(sudo -u postgres psql -tAc "SELECT pg_database_size(current_database())" 2>/dev/null || echo 0)"
  record_metric "db_size_bytes" "$DB_SIZE"
  TXN_RATE="$(sudo -u postgres psql -tAc "SELECT xact_commit FROM pg_stat_database WHERE datname = current_database()" 2>/dev/null || echo 0)"
  record_metric "db_commits_total" "$TXN_RATE"
fi

record_metric "memory_used_mb" "$(free -m | awk 'NR==2 {print $3}')"

# --- Project forward ---------------------------------------------------------
project() {
  local metric="$1" capacity="$2"
  local cutoff=$(( NOW - DAYS * 86400 ))

  mapfile -t rows < <(awk -F, -v m="$metric" -v c="$cutoff" '$2==m && $1>=c {print $1","$3}' "$HISTORY_FILE")
  (( ${#rows[@]} < 2 )) && { printf '%-28s %-14s %s\n' "$metric" "insufficient" "need at least 2 readings in the window"; return; }

  IFS=, read -r t_first v_first <<< "${rows[0]}"
  IFS=, read -r t_last  v_last  <<< "${rows[-1]}"

  local span=$(( t_last - t_first ))
  (( span <= 0 )) && return

  local growth_per_day
  growth_per_day="$(awk -v a="$v_first" -v b="$v_last" -v s="$span" 'BEGIN {printf "%.2f", (b-a)/(s/86400)}')"

  if [[ -n "$capacity" && "$capacity" != "0" ]]; then
    local remaining days_left
    remaining="$(awk -v c="$capacity" -v v="$v_last" 'BEGIN {print c-v}')"
    if awk -v g="$growth_per_day" 'BEGIN {exit !(g > 0)}'; then
      days_left="$(awk -v r="$remaining" -v g="$growth_per_day" 'BEGIN {printf "%d", r/g}')"
      printf '%-28s %-14s growth %s/day, full in ~%s day(s)\n' "$metric" "$(human_bytes "${v_last%.*}")" "$growth_per_day" "$days_left"
      if (( days_left < 90 )); then
        log_warn "${metric} projected to reach capacity in ${days_left} day(s)"
      fi
    else
      printf '%-28s %-14s stable or shrinking\n' "$metric" "$(human_bytes "${v_last%.*}")"
    fi
  else
    printf '%-28s %-14s growth %s/day\n' "$metric" "$v_last" "$growth_per_day"
  fi
}

printf '\nCapacity report — %s, %d-day window\n' "$(hostname -f)" "$DAYS"
printf '%s\n' "------------------------------------------------------------------"

while read -r fs size _ _ _ mount; do
  [[ "$fs" == "Filesystem" ]] && continue
  case "$mount" in
    /|/var|/opt|/backup) project "disk_used_kb:${mount}" "$size" ;;
  esac
done < <(df -Pk)

project "db_size_bytes" ""
project "memory_used_mb" "$(free -m | awk 'NR==2 {print $2}')"

printf '%s\n\n' "------------------------------------------------------------------"

# Keep the history bounded — a year of daily readings is plenty.
awk -F, -v c=$(( NOW - 400 * 86400 )) 'NR==1 || $1>=c' "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" \
  && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
