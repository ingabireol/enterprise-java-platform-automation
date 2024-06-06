#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# drain.sh — take this node out of, or return it to, the load balancer pool.
#
#   drain.sh --out [--wait]     Stop receiving new requests
#   drain.sh --in               Start receiving requests again
#   drain.sh --status           Report the current state
#
# The load balancer's health check reads the marker file this script manages, so
# draining is instant and reversible without touching nginx configuration on the
# edge nodes.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

APP_BASE_DIR="${APP_BASE_DIR:-/opt/efp}"
MARKER="${APP_BASE_DIR}/etc/drain"
ACTION=""
WAIT=false
DRAIN_SECONDS="${DRAIN_SECONDS:-60}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)    ACTION=out; shift ;;
    --in)     ACTION=in; shift ;;
    --status) ACTION=status; shift ;;
    --wait)   WAIT=true; shift ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

[[ -n "$ACTION" ]] || die "One of --out, --in or --status is required" 2

case "$ACTION" in
  out)
    require_root
    touch "$MARKER"
    printf 'drained_by=%s\ndrained_at=%s\n' "${SUDO_USER:-$(id -un)}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
    log_info "$(hostname -s) marked as draining"
    if [[ "$WAIT" == "true" ]]; then
      log_info "Waiting ${DRAIN_SECONDS}s for in-flight requests to complete"
      sleep "$DRAIN_SECONDS"
      # Report what is still open so the operator can decide whether to wait.
      open="$(ss -Hnt state established '( sport = :8081 or sport = :8082 or sport = :8083 or sport = :8080 )' 2>/dev/null | wc -l)"
      log_info "${open} established connection(s) remain"
    fi
    ;;
  in)
    require_root
    rm -f "$MARKER"
    log_info "$(hostname -s) returned to the pool"
    ;;
  status)
    if [[ -f "$MARKER" ]]; then
      printf 'DRAINED\n'
      cat "$MARKER"
      exit 1
    else
      printf 'IN SERVICE\n'
      exit 0
    fi
    ;;
esac
