#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deploy.sh — deploy a release to this node.
#
#   deploy.sh --version 2.4.1 [--service efp-core] [--skip-drain] [--dry-run]
#
# The Ansible playbook (ansible/playbooks/deploy.yml) is the normal path for a
# fleet-wide release. This script is what runs on the node itself, and what an
# operator uses when a single node has to be brought back in line by hand.
#
# It is written to be safe to interrupt: nothing is destroyed until the new
# release is on disk and verified, and the previous release stays in place.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

VERSION=""
SINGLE_SERVICE=""
SKIP_DRAIN=false
DRY_RUN=false

APP_BASE_DIR="${APP_BASE_DIR:-/opt/efp}"
APP_USER="${APP_USER:-efpsvc}"
APP_GROUP="${APP_GROUP:-efpsvc}"
ARTIFACT_REPO="${APP_ARTIFACT_REPO:-https://artifacts.example.gov/repository/releases}"
SERVICES="${PLATFORM_SERVICES:-efp-core efp-reporting efp-integration}"
MANAGEMENT_PORTS="${PLATFORM_MANAGEMENT_PORTS:-9081 9082 9083}"
DRAIN_SECONDS="${DRAIN_SECONDS:-60}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
RELEASES_KEEP="${RELEASES_KEEP:-5}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)    VERSION="$2"; shift 2 ;;
    --service)    SINGLE_SERVICE="$2"; shift 2 ;;
    --skip-drain) SKIP_DRAIN=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)    sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

require_root
[[ -n "$VERSION" ]] || die "--version is required" 2
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] \
  || die "Version '${VERSION}' is not a semantic version. Deployments must be reproducible." 2

require_commands curl systemctl sha256sum
acquire_lock "deploy" 300

RELEASE_DIR="${APP_BASE_DIR}/releases/${VERSION}"
CURRENT_LINK="${APP_BASE_DIR}/current"
DRAIN_MARKER="${APP_BASE_DIR}/etc/drain"

read -ra SVC_ARRAY <<< "$SERVICES"
read -ra PORT_ARRAY <<< "$MANAGEMENT_PORTS"

if [[ -n "$SINGLE_SERVICE" ]]; then
  idx=-1
  for i in "${!SVC_ARRAY[@]}"; do
    [[ "${SVC_ARRAY[i]}" == "$SINGLE_SERVICE" ]] && idx="$i"
  done
  (( idx >= 0 )) || die "Unknown service '${SINGLE_SERVICE}'. Known: ${SERVICES}" 2
  SVC_ARRAY=("$SINGLE_SERVICE")
  PORT_ARRAY=("${PORT_ARRAY[idx]}")
fi

PREVIOUS="none"
[[ -L "$CURRENT_LINK" ]] && PREVIOUS="$(basename "$(readlink -f "$CURRENT_LINK")")"

log_info "Deploying ${VERSION} to $(hostname -s) (currently ${PREVIOUS})"
[[ "$DRY_RUN" == "true" ]] && log_warn "DRY RUN — nothing will change"

# --- 1. Fetch and verify the artefacts BEFORE touching the running service ---
if [[ "$DRY_RUN" == "false" ]]; then
  mkdir -p "$RELEASE_DIR"
  chown "${APP_USER}:${APP_GROUP}" "$RELEASE_DIR"
  chmod 0750 "$RELEASE_DIR"
fi

for svc in "${SVC_ARRAY[@]}"; do
  url="${ARTIFACT_REPO}/${svc}/${VERSION}/${svc}-${VERSION}.jar"
  dest="${RELEASE_DIR}/${svc}.jar"

  log_info "Fetching ${svc} ${VERSION}"
  if [[ "$DRY_RUN" == "true" ]]; then
    retry 2 curl -fsSI --max-time 30 "$url" >/dev/null || die "Artefact not available: ${url}" 1
    continue
  fi

  retry 3 curl -fsS --max-time 600 -o "${dest}.part" "$url" || die "Failed to download ${url}" 1

  # Verify the checksum before the file is allowed to become a release artefact.
  if expected="$(curl -fsS --max-time 30 "${url}.sha256" 2>/dev/null | awk '{print $1}')"; then
    actual="$(sha256sum "${dest}.part" | awk '{print $1}')"
    [[ "$expected" == "$actual" ]] || die "Checksum mismatch for ${svc}: expected ${expected}, got ${actual}" 1
    log_info "Checksum verified for ${svc}"
  else
    log_warn "No published checksum for ${svc} — proceeding without integrity verification"
  fi

  mv "${dest}.part" "$dest"
  chown "${APP_USER}:${APP_GROUP}" "$dest"
  chmod 0640 "$dest"
done

[[ "$DRY_RUN" == "true" ]] && { log_info "Dry run complete — all artefacts are available"; exit 0; }

# --- 2. Write the rollback manifest -----------------------------------------
cat > "${APP_BASE_DIR}/etc/rollback.manifest" <<MANIFEST
PREVIOUS_RELEASE=${PREVIOUS}
TARGET_RELEASE=${VERSION}
DEPLOYED_BY=${SUDO_USER:-$(id -un)}
DEPLOYED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOST=$(hostname -f)
MANIFEST
chmod 0640 "${APP_BASE_DIR}/etc/rollback.manifest"

# --- 3. Drain --------------------------------------------------------------
if [[ "$SKIP_DRAIN" == "false" ]]; then
  log_info "Draining this node from the load balancer (${DRAIN_SECONDS}s)"
  touch "$DRAIN_MARKER"
  on_cleanup "rm -f '$DRAIN_MARKER'"
  sleep "$DRAIN_SECONDS"
fi

# --- 4. Stop, swap, start ---------------------------------------------------
for svc in "${SVC_ARRAY[@]}"; do
  log_info "Stopping ${svc}"
  systemctl stop "${svc}.service" || log_warn "${svc} was not running"
done

log_info "Pointing current at ${VERSION}"
ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"
chown -h "${APP_USER}:${APP_GROUP}" "$CURRENT_LINK"

for svc in "${SVC_ARRAY[@]}"; do
  log_info "Starting ${svc}"
  systemctl start "${svc}.service" || die "${svc} failed to start — run: journalctl -u ${svc} -n 100" 1
done

# --- 5. Wait for readiness ---------------------------------------------------
for i in "${!SVC_ARRAY[@]}"; do
  svc="${SVC_ARRAY[i]}"
  port="${PORT_ARRAY[i]:-}"
  [[ -n "$port" ]] || continue

  log_info "Waiting for ${svc} to report ready"
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  ready=false
  while (( $(date +%s) < deadline )); do
    if curl -fsS --max-time 5 "http://127.0.0.1:${port}/actuator/health/readiness" 2>/dev/null | grep -q '"status":"UP"'; then
      ready=true; break
    fi
    sleep 5
  done

  if [[ "$ready" == "false" ]]; then
    log_error "${svc} did not become ready within ${HEALTH_TIMEOUT}s"
    log_error "Last 40 log lines:"
    journalctl -u "${svc}.service" -n 40 --no-pager >&2 || true
    die "Deployment failed. Roll back with: ${SCRIPT_DIR}/rollback.sh" 1
  fi
  log_info "${svc} is ready"

  # Confirm the running service reports the version we intended to deploy.
  if info="$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/actuator/info" 2>/dev/null)"; then
    if ! printf '%s' "$info" | grep -q "$VERSION"; then
      log_warn "${svc} is healthy but /actuator/info does not report ${VERSION} — check the build metadata"
    fi
  fi
done

# --- 6. Undrain ------------------------------------------------------------
rm -f "$DRAIN_MARKER"
log_info "Node returned to the load balancer pool"

# --- 7. Prune old releases ---------------------------------------------------
( cd "${APP_BASE_DIR}/releases" && ls -1dt ./*/ 2>/dev/null | tail -n +$(( RELEASES_KEEP + 1 )) | xargs -r rm -rf )

emit_metric "deployment.prom" "platform_deployment_timestamp_seconds" "$(date +%s)" \
  "When the last deployment completed" "gauge" "version=\"${VERSION}\""

log_info "Deployment of ${VERSION} complete (previous: ${PREVIOUS})"
log_info "Watch error rate and p99 latency for the next 30 minutes before declaring success."
