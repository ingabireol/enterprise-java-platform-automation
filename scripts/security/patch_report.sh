#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch_report.sh — report outstanding security updates and their severity.
#
#   patch_report.sh [--json] [--fail-on-critical]
#
# Run before a patch window to size it, and after to prove it did what it was
# supposed to. The exit code is usable as a gate in CI or in a change record.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

JSON=false
FAIL_ON_CRITICAL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=true; shift ;;
    --fail-on-critical) FAIL_ON_CRITICAL=true; shift ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

command -v dnf >/dev/null 2>&1 || die "This report currently supports dnf-based systems only" 1

CRITICAL=0; IMPORTANT=0; MODERATE=0; LOW=0; BUGFIX=0

while read -r _ severity _; do
  case "$severity" in
    Critical/Sec.*|critical) CRITICAL=$(( CRITICAL + 1 )) ;;
    Important/Sec.*|important) IMPORTANT=$(( IMPORTANT + 1 )) ;;
    Moderate/Sec.*|moderate) MODERATE=$(( MODERATE + 1 )) ;;
    Low/Sec.*|low) LOW=$(( LOW + 1 )) ;;
    bugfix) BUGFIX=$(( BUGFIX + 1 )) ;;
  esac
done < <(dnf updateinfo list --security 2>/dev/null | grep -vE '^(Last metadata|Updating|$)')

TOTAL=$(( CRITICAL + IMPORTANT + MODERATE + LOW ))

# A running kernel older than the newest installed one means a reboot is owed.
RUNNING_KERNEL="$(uname -r)"
LATEST_KERNEL="$(rpm -q --last kernel 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^kernel-//')"
REBOOT_REQUIRED=false
[[ -n "$LATEST_KERNEL" && "$LATEST_KERNEL" != "$RUNNING_KERNEL" ]] && REBOOT_REQUIRED=true
needs-restarting -r >/dev/null 2>&1 || REBOOT_REQUIRED=true

if [[ "$JSON" == "true" ]]; then
  cat <<JSONOUT
{
  "host": "$(hostname -f)",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "security_updates": {
    "critical": ${CRITICAL},
    "important": ${IMPORTANT},
    "moderate": ${MODERATE},
    "low": ${LOW},
    "total": ${TOTAL}
  },
  "running_kernel": "${RUNNING_KERNEL}",
  "latest_installed_kernel": "${LATEST_KERNEL:-unknown}",
  "reboot_required": ${REBOOT_REQUIRED}
}
JSONOUT
else
  printf '\nPatch report — %s at %s\n' "$(hostname -f)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "------------------------------------------------------------------"
  printf '  Critical      : %d\n' "$CRITICAL"
  printf '  Important     : %d\n' "$IMPORTANT"
  printf '  Moderate      : %d\n' "$MODERATE"
  printf '  Low           : %d\n' "$LOW"
  printf '  Total security: %d\n' "$TOTAL"
  printf '%s\n' "------------------------------------------------------------------"
  printf '  Running kernel: %s\n' "$RUNNING_KERNEL"
  printf '  Latest kernel : %s\n' "${LATEST_KERNEL:-unknown}"
  printf '  Reboot owed   : %s\n' "$REBOOT_REQUIRED"
  printf '%s\n' "------------------------------------------------------------------"
  if (( CRITICAL > 0 )); then
    printf '  \033[31m%d critical update(s) outstanding — patch outside the normal cycle.\033[0m\n' "$CRITICAL"
    printf '  Procedure: docs/runbooks/patching.md § "Out-of-cycle patching"\n'
  elif (( TOTAL > 0 )); then
    printf '  %d security update(s) for the next scheduled window.\n' "$TOTAL"
  else
    printf '  \033[32mFully patched.\033[0m\n'
  fi
  printf '\n'
fi

emit_metric "patch_status.prom" "platform_security_updates_pending" "$TOTAL" \
  "Outstanding security updates" "gauge"
append_metric "patch_status.prom" "platform_security_updates_critical" "$CRITICAL"
append_metric "patch_status.prom" "platform_reboot_required" "$([[ "$REBOOT_REQUIRED" == "true" ]] && echo 1 || echo 0)"

[[ "$FAIL_ON_CRITICAL" == "true" && "$CRITICAL" -gt 0 ]] && exit 2
exit 0
