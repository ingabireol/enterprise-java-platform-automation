#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# config_backup.sh — daily snapshot of system configuration.
#
# Ansible is the source of truth for configuration, so why snapshot it? Because
# the source of truth describes what the host *should* look like, and during an
# incident the useful question is what it *did* look like. This captures the
# second thing, and diffs it against yesterday so that unmanaged drift shows up
# in the log rather than in an outage.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

load_config "${BACKUP_CONFIG:-/opt/efp/etc/backup.conf}"
require_root

BACKUP_ROOT="${BACKUP_ROOT:-/backup/efp}"
TARGET_DIR="${BACKUP_ROOT}/config"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="${TARGET_DIR}/config-$(hostname -s)-${TIMESTAMP}.tar.zst"
LATEST_LINK="${TARGET_DIR}/config-$(hostname -s)-latest.tar.zst"

CONFIG_PATHS=(
  /etc/nginx
  /etc/systemd/system
  /etc/ssh/sshd_config
  /etc/sysctl.d
  /etc/audit/rules.d
  /etc/sysconfig/nftables.conf
  /etc/security/limits.d
  /etc/sudoers.d
  /etc/chrony.conf
  /opt/efp/etc
)

mkdir -p "$TARGET_DIR"
acquire_lock "config_backup" 0

log_info "Snapshotting system configuration"

# Capture live state that no file records.
STATE_DIR="$(mktemp -d)"
on_cleanup "rm -rf '$STATE_DIR'"

systemctl list-unit-files --state=enabled --no-legend > "${STATE_DIR}/enabled-units.txt" 2>/dev/null || true
systemctl list-units --state=failed --no-legend      > "${STATE_DIR}/failed-units.txt" 2>/dev/null || true
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' 2>/dev/null | sort > "${STATE_DIR}/packages.txt" || true
nft list ruleset                                     > "${STATE_DIR}/nftables-ruleset.txt" 2>/dev/null || true
ip -json addr show                                   > "${STATE_DIR}/ip-addresses.json" 2>/dev/null || true
ip -json route show                                  > "${STATE_DIR}/ip-routes.json" 2>/dev/null || true
getent passwd                                        > "${STATE_DIR}/passwd.txt"
getent group                                         > "${STATE_DIR}/group.txt"
sshd -T 2>/dev/null | sort                           > "${STATE_DIR}/sshd-effective.txt" || true
lsblk -J                                             > "${STATE_DIR}/block-devices.json" 2>/dev/null || true
df -hP                                               > "${STATE_DIR}/filesystems.txt"

EXISTING=()
for p in "${CONFIG_PATHS[@]}"; do
  [[ -e "$p" ]] && EXISTING+=("$p")
done

tar --create --zstd \
    --file="$ARCHIVE" \
    --absolute-names \
    --warning=no-file-changed \
    --exclude='*.key' --exclude='*.pem' --exclude='shadow*' \
    "${EXISTING[@]}" \
    -C "$STATE_DIR" . \
  || log_warn "tar reported non-fatal issues"

sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"

# Diff against yesterday so drift is visible without anyone going looking.
if [[ -L "$LATEST_LINK" && -e "$LATEST_LINK" ]]; then
  PREV_DIR="$(mktemp -d)"; NEW_DIR="$(mktemp -d)"
  on_cleanup "rm -rf '$PREV_DIR' '$NEW_DIR'"
  tar -xf "$LATEST_LINK" -C "$PREV_DIR" 2>/dev/null || true
  tar -xf "$ARCHIVE"     -C "$NEW_DIR"  2>/dev/null || true

  if DIFF="$(diff -rq "$PREV_DIR" "$NEW_DIR" 2>/dev/null)"; then
    log_info "No configuration drift since the previous snapshot"
    emit_metric "config_drift.prom" "platform_config_drift_files" "0" \
      "Number of configuration files that changed since the previous snapshot" "gauge"
  else
    CHANGED="$(printf '%s\n' "$DIFF" | wc -l)"
    log_warn "Configuration drift detected: ${CHANGED} difference(s)"
    printf '%s\n' "$DIFF" | while IFS= read -r l; do log_warn "  drift: ${l}"; done
    emit_metric "config_drift.prom" "platform_config_drift_files" "$CHANGED" \
      "Number of configuration files that changed since the previous snapshot" "gauge"
  fi
fi

ln -sf "$ARCHIVE" "$LATEST_LINK"

# Config snapshots are small; a longer tail costs almost nothing and is often
# what answers "when did this change?".
find "$TARGET_DIR" -name "config-$(hostname -s)-*.tar.zst" -mtime +90 -delete

log_info "Configuration snapshot written: ${ARCHIVE} ($(human_bytes "$(stat -c %s "$ARCHIVE")"))"
