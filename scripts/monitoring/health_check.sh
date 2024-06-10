#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# health_check.sh — end-to-end platform health probe.
#
#   health_check.sh                       Human-readable report
#   health_check.sh --quiet --metrics F   Write Prometheus metrics to F
#   health_check.sh --json                Machine-readable report
#   health_check.sh --exit-on-fail        Non-zero exit if anything is unhealthy
#
# Checks, in dependency order, so that a failure report points at the cause
# rather than at the symptom: host resources → runtime → services → database →
# edge → end-to-end request.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

QUIET=false
JSON=false
METRICS_FILE=""
EXIT_ON_FAIL=false

DISK_WARN_PCT=80
DISK_CRIT_PCT=90
MEM_WARN_PCT=85
LOAD_WARN_MULTIPLIER=2

APP_BASE_DIR="${APP_BASE_DIR:-/opt/efp}"
SERVICES="${PLATFORM_SERVICES:-efp-core efp-reporting efp-integration}"
MANAGEMENT_PORTS="${PLATFORM_MANAGEMENT_PORTS:-9081 9082 9083}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)   QUIET=true; LOG_LEVEL=ERROR; shift ;;
    --json)    JSON=true; LOG_LEVEL=ERROR; shift ;;
    --metrics) METRICS_FILE="$2"; shift 2 ;;
    --exit-on-fail) EXIT_ON_FAIL=true; shift ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

declare -a CHECKS=()
OVERALL=0

record() {
  local name="$1" status="$2" detail="$3"
  CHECKS+=("${name}|${status}|${detail}")
  case "$status" in
    OK)   [[ "$QUIET" == "false" && "$JSON" == "false" ]] && printf '  \033[32m✓\033[0m %-28s %s\n' "$name" "$detail" ;;
    WARN) [[ "$QUIET" == "false" && "$JSON" == "false" ]] && printf '  \033[33m!\033[0m %-28s %s\n' "$name" "$detail"
          (( OVERALL < 1 )) && OVERALL=1 ;;
    FAIL) [[ "$QUIET" == "false" && "$JSON" == "false" ]] && printf '  \033[31m✗\033[0m %-28s %s\n' "$name" "$detail"
          OVERALL=2 ;;
  esac
  return 0
}

[[ "$QUIET" == "false" && "$JSON" == "false" ]] && {
  printf '\nPlatform health — %s at %s\n' "$(hostname -f)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "------------------------------------------------------------------"
}

# --- 1. Host resources ------------------------------------------------------
while read -r fs size used avail pct mount; do
  [[ "$fs" == "Filesystem" ]] && continue
  pct_num="${pct%\%}"
  case "$mount" in
    /|/var|/opt|/backup|"${APP_BASE_DIR}")
      if   (( pct_num >= DISK_CRIT_PCT )); then record "disk:${mount}" FAIL "${pct} used, ${avail} free"
      elif (( pct_num >= DISK_WARN_PCT )); then record "disk:${mount}" WARN "${pct} used, ${avail} free"
      else record "disk:${mount}" OK "${pct} used, ${avail} free"
      fi ;;
  esac
done < <(df -hP)

read -r _ mem_total mem_used _ _ _ mem_avail < <(free -m | awk 'NR==2')
mem_pct=$(( mem_used * 100 / mem_total ))
if (( mem_pct >= MEM_WARN_PCT )); then
  record "memory" WARN "${mem_pct}% used, ${mem_avail} MiB available"
else
  record "memory" OK "${mem_pct}% used, ${mem_avail} MiB available"
fi

CPU_COUNT="$(nproc)"
LOAD1="$(awk '{print $1}' /proc/loadavg)"
LOAD_THRESHOLD=$(( CPU_COUNT * LOAD_WARN_MULTIPLIER ))
if (( $(printf '%.0f' "$LOAD1") > LOAD_THRESHOLD )); then
  record "load" WARN "${LOAD1} over ${CPU_COUNT} CPU(s)"
else
  record "load" OK "${LOAD1} over ${CPU_COUNT} CPU(s)"
fi

# Swap activity is a better early warning than memory percentage: a JVM that has
# started swapping is already in trouble even though free memory looks fine.
SWAP_USED="$(free -m | awk 'NR==3 {print $3}')"
if (( SWAP_USED > 512 )); then
  record "swap" WARN "${SWAP_USED} MiB in use — the JVM heap may be oversized for this host"
else
  record "swap" OK "${SWAP_USED} MiB in use"
fi

# --- 2. Time synchronisation -------------------------------------------------
if command -v chronyc >/dev/null 2>&1; then
  if OFFSET="$(chronyc tracking 2>/dev/null | awk -F': *' '/System time/ {print $2}')"; then
    record "time-sync" OK "${OFFSET}"
  else
    record "time-sync" FAIL "chronyd is not tracking a time source"
  fi
fi

# --- 3. Systemd ---------------------------------------------------------------
FAILED_UNITS="$(systemctl list-units --state=failed --no-legend 2>/dev/null | wc -l)"
if (( FAILED_UNITS > 0 )); then
  record "systemd" FAIL "${FAILED_UNITS} failed unit(s): $(systemctl list-units --state=failed --no-legend | awk '{print $1}' | tr '\n' ' ')"
else
  record "systemd" OK "no failed units"
fi

# --- 4. Application services --------------------------------------------------
read -ra SVC_ARRAY <<< "$SERVICES"
read -ra PORT_ARRAY <<< "$MANAGEMENT_PORTS"

for i in "${!SVC_ARRAY[@]}"; do
  svc="${SVC_ARRAY[i]}"
  port="${PORT_ARRAY[i]:-}"

  systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 || continue

  if ! systemctl is-active --quiet "${svc}.service"; then
    record "service:${svc}" FAIL "not running"
    continue
  fi

  if [[ -n "$port" ]]; then
    if HEALTH="$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/actuator/health/readiness" 2>/dev/null)"; then
      status="$(printf '%s' "$HEALTH" | grep -o '"status":"[A-Z]*"' | head -1 | cut -d'"' -f4)"
      if [[ "$status" == "UP" ]]; then
        # Uptime and heap pressure turn "it is running" into something useful.
        uptime_s="$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/actuator/metrics/process.uptime" 2>/dev/null \
                    | grep -o '"value":[0-9.]*' | head -1 | cut -d: -f2 | cut -d. -f1)"
        record "service:${svc}" OK "UP, uptime ${uptime_s:-?}s"
      else
        record "service:${svc}" FAIL "readiness reports ${status:-unknown}"
      fi
    else
      record "service:${svc}" FAIL "running but the readiness endpoint is unreachable"
    fi
  else
    record "service:${svc}" OK "running"
  fi
done

# --- 5. JVM heap pressure -----------------------------------------------------
for i in "${!SVC_ARRAY[@]}"; do
  port="${PORT_ARRAY[i]:-}"
  [[ -n "$port" ]] || continue
  curl -fsS --max-time 5 "http://127.0.0.1:${port}/actuator/health" >/dev/null 2>&1 || continue

  used="$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/actuator/metrics/jvm.memory.used?tag=area:heap" 2>/dev/null \
          | grep -o '"value":[0-9.E]*' | head -1 | cut -d: -f2)"
  max="$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/actuator/metrics/jvm.memory.max?tag=area:heap" 2>/dev/null \
         | grep -o '"value":[0-9.E]*' | head -1 | cut -d: -f2)"

  if [[ -n "$used" && -n "$max" && "$max" != "0" ]]; then
    pct="$(awk -v u="$used" -v m="$max" 'BEGIN {printf "%d", u/m*100}')"
    if   (( pct >= 90 )); then record "heap:${SVC_ARRAY[i]}" WARN "${pct}% of max heap in use"
    else record "heap:${SVC_ARRAY[i]}" OK "${pct}% of max heap in use"
    fi
  fi
done

# --- 6. Tomcat ----------------------------------------------------------------
if systemctl list-unit-files tomcat.service >/dev/null 2>&1; then
  if systemctl is-active --quiet tomcat; then
    if curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${TOMCAT_HTTP_PORT:-8080}/"; then
      record "service:tomcat" OK "connector responding"
    else
      record "service:tomcat" WARN "running but the HTTP connector did not respond"
    fi
  else
    record "service:tomcat" FAIL "not running"
  fi
fi

# --- 7. PostgreSQL ------------------------------------------------------------
if systemctl list-unit-files 'postgresql-*.service' --no-legend 2>/dev/null | grep -q postgresql; then
  PG_UNIT="$(systemctl list-unit-files 'postgresql-*.service' --no-legend | awk '{print $1}' | head -1)"
  if systemctl is-active --quiet "$PG_UNIT"; then
    if CONN="$(sudo -u postgres psql -tAc "SELECT count(*) FROM pg_stat_activity" 2>/dev/null)"; then
      MAXCONN="$(sudo -u postgres psql -tAc "SHOW max_connections" 2>/dev/null)"
      pct=$(( CONN * 100 / MAXCONN ))
      if (( pct >= 80 )); then
        record "postgresql" WARN "${CONN}/${MAXCONN} connections (${pct}%)"
      else
        record "postgresql" OK "${CONN}/${MAXCONN} connections (${pct}%)"
      fi

      # Replication lag, where this node has replicas.
      if LAG="$(sudo -u postgres psql -tAc \
          "SELECT COALESCE(max(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)),0) FROM pg_stat_replication" 2>/dev/null)"; then
        if [[ "$LAG" != "0" ]]; then
          if (( LAG > 134217728 )); then
            record "replication" WARN "$(human_bytes "$LAG") behind"
          else
            record "replication" OK "$(human_bytes "$LAG") behind"
          fi
        fi
      fi

      # Long-running transactions hold locks and block vacuum.
      IDLE_TX="$(sudo -u postgres psql -tAc \
        "SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction' AND now() - state_change > interval '5 minutes'" 2>/dev/null)"
      if (( IDLE_TX > 0 )); then
        record "pg:idle-in-tx" WARN "${IDLE_TX} session(s) idle in transaction for over 5 minutes"
      fi
    else
      record "postgresql" FAIL "running but not accepting queries"
    fi
  else
    record "postgresql" FAIL "not running"
  fi
fi

# --- 8. Nginx and end-to-end --------------------------------------------------
if systemctl list-unit-files nginx.service >/dev/null 2>&1; then
  if systemctl is-active --quiet nginx; then
    if nginx -t >/dev/null 2>&1; then
      record "nginx" OK "running, configuration valid"
    else
      record "nginx" WARN "running, but the on-disk configuration is invalid — a reload would fail"
    fi

    if curl -fsSk --max-time 10 -o /dev/null -w '%{http_code}' "https://127.0.0.1/healthz" | grep -qE '^(200|401|403)$'; then
      record "end-to-end" OK "HTTPS endpoint responding"
    else
      record "end-to-end" FAIL "HTTPS endpoint did not respond as expected"
    fi
  else
    record "nginx" FAIL "not running"
  fi
fi

# --- 9. TLS certificate expiry ------------------------------------------------
for cert in /etc/pki/tls/certs/*.crt; do
  [[ -e "$cert" ]] || continue
  [[ "$cert" == *chain* ]] && continue
  if EXPIRY="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)"; then
    days=$(( ( $(date -d "$EXPIRY" +%s) - $(date +%s) ) / 86400 ))
    if   (( days < 14 )); then record "tls:$(basename "$cert")" FAIL "expires in ${days} day(s)"
    elif (( days < 30 )); then record "tls:$(basename "$cert")" WARN "expires in ${days} day(s)"
    else record "tls:$(basename "$cert")" OK "expires in ${days} day(s)"
    fi
  fi
done

# --- Output -------------------------------------------------------------------
if [[ -n "$METRICS_FILE" ]]; then
  tmp="${METRICS_FILE}.$$"
  {
    printf '# HELP platform_health_check_status Health check result (0=OK, 1=WARN, 2=FAIL)\n'
    printf '# TYPE platform_health_check_status gauge\n'
    for entry in "${CHECKS[@]}"; do
      IFS='|' read -r name status _ <<< "$entry"
      case "$status" in OK) v=0 ;; WARN) v=1 ;; FAIL) v=2 ;; *) v=3 ;; esac
      printf 'platform_health_check_status{check="%s"} %d\n' "$name" "$v"
    done
    printf '# HELP platform_health_overall Overall health (0=OK, 1=WARN, 2=FAIL)\n'
    printf '# TYPE platform_health_overall gauge\n'
    printf 'platform_health_overall %d\n' "$OVERALL"
    printf '# HELP platform_health_last_run_timestamp_seconds When the health check last ran\n'
    printf '# TYPE platform_health_last_run_timestamp_seconds gauge\n'
    printf 'platform_health_last_run_timestamp_seconds %d\n' "$(date +%s)"
  } > "$tmp"
  mv -f "$tmp" "$METRICS_FILE"
  chmod 0644 "$METRICS_FILE"
fi

if [[ "$JSON" == "true" ]]; then
  printf '{"host":"%s","timestamp":"%s","overall":%d,"checks":[' \
    "$(hostname -f)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OVERALL"
  first=true
  for entry in "${CHECKS[@]}"; do
    IFS='|' read -r name status detail <<< "$entry"
    [[ "$first" == "true" ]] && first=false || printf ','
    printf '{"check":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$detail"
  done
  printf ']}\n'
elif [[ "$QUIET" == "false" ]]; then
  printf '%s\n' "------------------------------------------------------------------"
  case "$OVERALL" in
    0) printf '  Overall: \033[32mHEALTHY\033[0m (%d checks)\n\n' "${#CHECKS[@]}" ;;
    1) printf '  Overall: \033[33mDEGRADED\033[0m (%d checks)\n\n' "${#CHECKS[@]}" ;;
    *) printf '  Overall: \033[31mUNHEALTHY\033[0m (%d checks) — see docs/runbooks/incident-response.md\n\n' "${#CHECKS[@]}" ;;
  esac
fi

[[ "$EXIT_ON_FAIL" == "true" ]] && exit "$OVERALL"
exit 0
