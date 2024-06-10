#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# log_triage.sh — first-pass log analysis for an incident.
#
#   log_triage.sh [--since '30 minutes ago'] [--service NAME]
#
# The first ten minutes of an incident are usually spent running the same six
# commands. This runs them, in a sensible order, and prints the result compactly
# enough to paste into an incident channel.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

SINCE="30 minutes ago"
SERVICE=""
APP_LOG_DIR="${APP_LOG_DIR:-/var/log/efp}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)   SINCE="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

section() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

printf '\nLog triage — %s, since %s\n' "$(hostname -f)" "$SINCE"
printf '%s\n' "=================================================================="

section "Failed systemd units"
systemctl list-units --state=failed --no-legend || echo "  none"

section "Kernel messages (OOM, I/O, hardware)"
journalctl -k --since "$SINCE" --no-pager 2>/dev/null \
  | grep -iE 'oom|killed process|I/O error|ext4-fs error|xfs.*error|hardware error|segfault' \
  | tail -20 || echo "  none"

section "Out-of-memory kills"
# An OOM kill explains a service that "just disappeared" with no stack trace.
journalctl --since "$SINCE" --no-pager 2>/dev/null \
  | grep -iE 'out of memory|oom-killer|killed process' | tail -10 || echo "  none"

section "Service restarts"
journalctl --since "$SINCE" --no-pager -u 'efp-*' -u tomcat -u nginx -u 'postgresql*' 2>/dev/null \
  | grep -iE 'started|stopped|failed|scheduled restart' | tail -25 || echo "  none"

section "Application errors by class"
if [[ -d "$APP_LOG_DIR" ]]; then
  find "$APP_LOG_DIR" -name '*.log' -newermt "$SINCE" -print0 2>/dev/null \
    | xargs -0 -r grep -hE '\b(ERROR|FATAL)\b' 2>/dev/null \
    | grep -oE '[A-Za-z.]+(Exception|Error)' \
    | sort | uniq -c | sort -rn | head -15 || echo "  none"
else
  echo "  ${APP_LOG_DIR} not present"
fi

section "Most frequent error messages"
if [[ -d "$APP_LOG_DIR" ]]; then
  find "$APP_LOG_DIR" -name '*.log' -newermt "$SINCE" -print0 2>/dev/null \
    | xargs -0 -r grep -hE '\b(ERROR|FATAL)\b' 2>/dev/null \
    | sed -E 's/^[0-9T:.+-]+ +//; s/\[[^]]*\]//g; s/[0-9a-f]{8}-[0-9a-f-]{27}/UUID/g; s/[0-9]+/N/g' \
    | sort | uniq -c | sort -rn | head -10 || echo "  none"
fi

section "HTTP 5xx from nginx"
if [[ -f /var/log/nginx/access.log ]]; then
  awk -v since="$(date -d "$SINCE" '+%d/%b/%Y:%H:%M:%S')" '
    $9 ~ /^5/ {print $7, $9}' /var/log/nginx/access.log 2>/dev/null \
    | sort | uniq -c | sort -rn | head -15 || echo "  none"
else
  echo "  no nginx access log on this host"
fi

section "Slowest requests (nginx, rt=)"
if [[ -f /var/log/nginx/access.log ]]; then
  grep -oE 'rt=[0-9.]+ .*"(GET|POST|PUT|DELETE) [^"]*"' /var/log/nginx/access.log 2>/dev/null \
    | tail -2000 | sort -t= -k2 -rn | head -10 || echo "  none"
fi

section "PostgreSQL errors and slow queries"
PG_LOG="$(find /var/lib/pgsql -name 'postgresql-*.log' -newermt "$SINCE" 2>/dev/null | head -1)"
if [[ -n "$PG_LOG" ]]; then
  grep -E 'ERROR|FATAL|PANIC|deadlock|duration: [0-9]{4,}' "$PG_LOG" | tail -20 || echo "  none"
else
  echo "  no recent PostgreSQL log on this host"
fi

section "Authentication failures"
journalctl --since "$SINCE" --no-pager -t sshd 2>/dev/null \
  | grep -iE 'failed|invalid user|refused' | tail -15 || echo "  none"

section "Current resource state"
printf '  load: %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
free -h | awk 'NR<=2 {printf "  %s\n", $0}'
df -hP | awk 'NR==1 || $5+0 > 70 {printf "  %s\n", $0}'

printf '\n%s\n' "=================================================================="
printf 'Next: docs/runbooks/incident-response.md\n\n'
