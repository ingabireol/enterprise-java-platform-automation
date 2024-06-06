#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# rolling_restart.sh — restart the services on this node without dropping requests.
#
#   rolling_restart.sh [--service NAME] [--reason "..."]
#
# Restarting a JVM is routine; doing it without users noticing is the part that
# needs a script. The sequence is drain → wait for in-flight work → restart →
# wait for readiness → undrain, with a hard stop if readiness does not return.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

SINGLE=""
REASON="unspecified"
APP_BASE_DIR="${APP_BASE_DIR:-/opt/efp}"
SERVICES="${PLATFORM_SERVICES:-efp-core efp-reporting efp-integration}"
MANAGEMENT_PORTS="${PLATFORM_MANAGEMENT_PORTS:-9081 9082 9083}"
DRAIN_SECONDS="${DRAIN_SECONDS:-60}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SINGLE="$2"; shift 2 ;;
    --reason)  REASON="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

require_root
acquire_lock "rolling_restart" 120

read -ra SVC_ARRAY <<< "$SERVICES"
read -ra PORT_ARRAY <<< "$MANAGEMENT_PORTS"

log_info "Rolling restart on $(hostname -s). Reason: ${REASON}"

log_info "Draining (${DRAIN_SECONDS}s)"
touch "${APP_BASE_DIR}/etc/drain"
on_cleanup "rm -f '${APP_BASE_DIR}/etc/drain'"
sleep "$DRAIN_SECONDS"

for i in "${!SVC_ARRAY[@]}"; do
  svc="${SVC_ARRAY[i]}"
  port="${PORT_ARRAY[i]:-}"
  [[ -n "$SINGLE" && "$svc" != "$SINGLE" ]] && continue

  log_info "Restarting ${svc}"

  # Capture a thread dump first: a service being restarted because it is stuck
  # takes its evidence with it otherwise.
  if [[ "$REASON" == *stuck* || "$REASON" == *hang* || "$REASON" == *slow* ]]; then
    pid="$(systemctl show -p MainPID --value "${svc}.service")"
    if [[ -n "$pid" && "$pid" != "0" ]]; then
      dump="/var/log/efp/threaddump-${svc}-$(date -u +%Y%m%dT%H%M%SZ).txt"
      jcmd "$pid" Thread.print > "$dump" 2>/dev/null \
        && log_info "Thread dump captured: ${dump}" \
        || log_warn "Could not capture a thread dump for ${svc}"
    fi
  fi

  systemctl restart "${svc}.service" || die "${svc} failed to restart" 1

  [[ -n "$port" ]] || continue
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  ready=false
  while (( $(date +%s) < deadline )); do
    if curl -fsS --max-time 5 "http://127.0.0.1:${port}/actuator/health/readiness" 2>/dev/null | grep -q '"status":"UP"'; then
      ready=true; break
    fi
    sleep 5
  done
  [[ "$ready" == "true" ]] || die "${svc} did not become ready within ${HEALTH_TIMEOUT}s — node left drained deliberately" 1
  log_info "${svc} is ready"
done

rm -f "${APP_BASE_DIR}/etc/drain"
log_info "Rolling restart complete; node returned to the pool"
