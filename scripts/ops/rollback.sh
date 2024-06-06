#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# rollback.sh — return this node to the previously deployed release.
#
#   rollback.sh [--to VERSION] [--force]
#
# Reads the manifest deploy.sh wrote. Intentionally short: this runs when
# something is on fire, so it does the minimum and says clearly what it did.
#
# It does NOT revert database migrations. If the failed release migrated the
# schema, read docs/runbooks/deployment.md § "Rolling back through a migration"
# before running this.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

TARGET=""
FORCE=false
APP_BASE_DIR="${APP_BASE_DIR:-/opt/efp}"
APP_USER="${APP_USER:-efpsvc}"
APP_GROUP="${APP_GROUP:-efpsvc}"
SERVICES="${PLATFORM_SERVICES:-efp-core efp-reporting efp-integration}"
MANAGEMENT_PORTS="${PLATFORM_MANAGEMENT_PORTS:-9081 9082 9083}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)    TARGET="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

require_root
acquire_lock "deploy" 60      # same lock as deploy.sh: they must never overlap

MANIFEST="${APP_BASE_DIR}/etc/rollback.manifest"

if [[ -z "$TARGET" ]]; then
  [[ -r "$MANIFEST" ]] || die "No rollback manifest at ${MANIFEST}. Specify --to VERSION." 2
  # shellcheck source=/dev/null
  . "$MANIFEST"
  TARGET="${PREVIOUS_RELEASE:-}"
  [[ -n "$TARGET" && "$TARGET" != "none" ]] \
    || die "The manifest records no previous release. Specify --to VERSION." 2
  log_info "Manifest: rolling back from ${TARGET_RELEASE:-unknown} to ${TARGET}"
fi

TARGET_DIR="${APP_BASE_DIR}/releases/${TARGET}"
[[ -d "$TARGET_DIR" ]] || die "Release ${TARGET} is not on disk at ${TARGET_DIR}. Redeploy it instead." 1

CURRENT="$(basename "$(readlink -f "${APP_BASE_DIR}/current")" 2>/dev/null || echo none)"
[[ "$CURRENT" != "$TARGET" ]] || die "${TARGET} is already the current release. Nothing to do." 0

if [[ "$FORCE" == "false" ]]; then
  log_warn "About to roll back ${CURRENT} → ${TARGET} on $(hostname -f)"
  log_warn "Database migrations applied by ${CURRENT} will NOT be reverted."
  read -r -p "Type the target version to confirm: " confirm
  [[ "$confirm" == "$TARGET" ]] || die "Confirmation did not match. Aborting." 1
fi

read -ra SVC_ARRAY <<< "$SERVICES"
read -ra PORT_ARRAY <<< "$MANAGEMENT_PORTS"

log_info "Draining"
touch "${APP_BASE_DIR}/etc/drain"
sleep "${DRAIN_SECONDS:-30}"

for svc in "${SVC_ARRAY[@]}"; do
  log_info "Stopping ${svc}"
  systemctl stop "${svc}.service" || true
done

log_info "Pointing current at ${TARGET}"
ln -sfn "$TARGET_DIR" "${APP_BASE_DIR}/current"
chown -h "${APP_USER}:${APP_GROUP}" "${APP_BASE_DIR}/current"

for svc in "${SVC_ARRAY[@]}"; do
  log_info "Starting ${svc}"
  systemctl start "${svc}.service" || die "${svc} failed to start after rollback — escalate immediately" 1
done

for i in "${!SVC_ARRAY[@]}"; do
  port="${PORT_ARRAY[i]:-}"
  [[ -n "$port" ]] || continue
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    curl -fsS --max-time 5 "http://127.0.0.1:${port}/actuator/health/readiness" 2>/dev/null \
      | grep -q '"status":"UP"' && break
    sleep 5
  done
done

rm -f "${APP_BASE_DIR}/etc/drain"

printf 'ROLLED_BACK_FROM=%s\nROLLED_BACK_TO=%s\nROLLED_BACK_AT=%s\nROLLED_BACK_BY=%s\n' \
  "$CURRENT" "$TARGET" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SUDO_USER:-$(id -un)}" >> "$MANIFEST"

notify "Rollback completed on $(hostname -s)" \
  "Rolled back ${CURRENT} → ${TARGET} on $(hostname -f) at $(date -u +%Y-%m-%dT%H:%M:%SZ).

Outstanding: confirm whether ${CURRENT} applied database migrations that are now
ahead of the running code. See docs/runbooks/deployment.md." \
  critical

log_info "Rollback complete: ${CURRENT} → ${TARGET}"
log_warn "Check for schema migrations applied by ${CURRENT} that the rolled-back code does not expect."
