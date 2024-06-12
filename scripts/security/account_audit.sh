#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# account_audit.sh — review local accounts, privileges and authentication state.
#
#   account_audit.sh [--json]
#
# Answers the questions an auditor asks and an attacker exploits: who can log in,
# who can become root, which accounts are dormant, which have no password ageing,
# and which authorised keys exist that nobody remembers adding.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

JSON=false
INACTIVE_DAYS=90

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=true; shift ;;
    --inactive-days) INACTIVE_DAYS="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

require_root
declare -a FINDINGS=()
finding() { FINDINGS+=("$1|$2"); }

section() { [[ "$JSON" == "false" ]] && printf '\n\033[1m── %s\033[0m\n' "$1"; }

[[ "$JSON" == "false" ]] && {
  printf '\nAccount audit — %s at %s\n' "$(hostname -f)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "=================================================================="
}

# --- 1. Accounts with a login shell ------------------------------------------
section "Accounts with an interactive shell"
while IFS=: read -r user _ uid _ _ home shell; do
  case "$shell" in */nologin|*/false|*/sync|*/shutdown|*/halt) continue ;; esac
  last="$(lastlog -u "$user" 2>/dev/null | awk 'NR==2 {if ($0 ~ /Never/) print "never"; else print $4, $5, $6, $9}')"
  [[ "$JSON" == "false" ]] && printf '  %-16s uid=%-6s shell=%-16s last=%s\n' "$user" "$uid" "$shell" "${last:-unknown}"

  # A system account (uid < 1000) with a real shell is almost always a mistake
  # or a leftover, and it is a well-worn path to persistence.
  if (( uid < 1000 )) && [[ "$user" != "root" ]]; then
    finding HIGH "System account ${user} (uid ${uid}) has an interactive shell: ${shell}"
  fi
done < /etc/passwd

# --- 2. UID 0 accounts --------------------------------------------------------
section "Accounts with UID 0"
UID0="$(awk -F: '$3 == 0 {print $1}' /etc/passwd)"
[[ "$JSON" == "false" ]] && printf '  %s\n' "$UID0"
[[ "$(printf '%s' "$UID0" | wc -w)" -gt 1 ]] && finding CRIT "More than one account has UID 0: $(echo "$UID0" | tr '\n' ' ')"

# --- 3. Empty passwords -------------------------------------------------------
section "Accounts with an empty password"
EMPTY="$(awk -F: '($2 == "") {print $1}' /etc/shadow)"
if [[ -n "$EMPTY" ]]; then
  [[ "$JSON" == "false" ]] && printf '  %s\n' "$EMPTY"
  finding CRIT "Account(s) with an empty password: $(echo "$EMPTY" | tr '\n' ' ')"
else
  [[ "$JSON" == "false" ]] && printf '  none\n'
fi

# --- 4. Sudo access -----------------------------------------------------------
section "Sudo access"
for f in /etc/sudoers /etc/sudoers.d/*; do
  [[ -f "$f" ]] || continue
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# || -z "${line// }" ]] && continue
    [[ "$line" =~ (ALL|NOPASSWD) ]] || continue
    [[ "$JSON" == "false" ]] && printf '  %-28s %s\n' "$(basename "$f")" "$line"
    # NOPASSWD: ALL is unrestricted root without re-authentication.
    [[ "$line" =~ NOPASSWD:[[:space:]]*ALL ]] && finding HIGH "Unrestricted NOPASSWD sudo in $(basename "$f"): ${line}"
  done < "$f"
done

# --- 5. Dormant accounts -------------------------------------------------------
section "Accounts dormant for more than ${INACTIVE_DAYS} days"
NOW_DAYS=$(( $(date +%s) / 86400 ))
while IFS=: read -r user _ uid _ _ _ shell; do
  (( uid < 1000 )) && continue
  case "$shell" in */nologin|*/false) continue ;; esac
  lastlog_epoch="$(lastlog -u "$user" 2>/dev/null | awk 'NR==2 && $0 !~ /Never/ {print $4, $5, $6, $9}')"
  if [[ -z "$lastlog_epoch" ]]; then
    [[ "$JSON" == "false" ]] && printf '  %-16s never logged in\n' "$user"
    finding MED "Account ${user} has never logged in and still has a shell"
  else
    days=$(( NOW_DAYS - $(date -d "$lastlog_epoch" +%s 2>/dev/null || echo 0) / 86400 ))
    if (( days > INACTIVE_DAYS )); then
      [[ "$JSON" == "false" ]] && printf '  %-16s last login %d days ago\n' "$user" "$days"
      finding MED "Account ${user} has been dormant for ${days} days"
    fi
  fi
done < /etc/passwd

# --- 6. Password ageing --------------------------------------------------------
section "Accounts without password ageing"
while IFS=: read -r user _ uid _ _ _ shell; do
  (( uid < 1000 )) && continue
  case "$shell" in */nologin|*/false) continue ;; esac
  maxdays="$(chage -l "$user" 2>/dev/null | awk -F': *' '/Maximum number/ {print $2}')"
  if [[ "$maxdays" == "never" || "$maxdays" == "99999" ]]; then
    [[ "$JSON" == "false" ]] && printf '  %-16s password never expires\n' "$user"
    finding MED "Password for ${user} never expires"
  fi
done < /etc/passwd

# --- 7. Authorised keys ---------------------------------------------------------
section "SSH authorised keys"
while IFS=: read -r user _ uid _ _ home _; do
  akf="${home}/.ssh/authorized_keys"
  [[ -r "$akf" ]] || continue
  count="$(grep -cvE '^\s*(#|$)' "$akf" 2>/dev/null || echo 0)"
  (( count == 0 )) && continue
  [[ "$JSON" == "false" ]] && printf '  %-16s %d key(s)\n' "$user" "$count"

  while IFS= read -r key; do
    [[ "$key" =~ ^\s*(#|$) ]] && continue
    keytype="$(awk '{print $1}' <<< "$key")"
    comment="$(awk '{print $3}' <<< "$key")"
    [[ "$JSON" == "false" ]] && printf '    %-22s %s\n' "$keytype" "${comment:-<no comment>}"
    # DSA and short RSA keys are no longer acceptable.
    [[ "$keytype" == "ssh-dss" ]] && finding HIGH "${user} has a DSA authorised key (${comment:-no comment})"
    [[ "$keytype" == "ssh-rsa" ]] && finding MED  "${user} has an RSA key; prefer ed25519 (${comment:-no comment})"
  done < "$akf"

  # Permissions on authorized_keys are load-bearing: sshd refuses the file if a
  # group or other can write it, which fails as a lockout rather than a warning.
  perms="$(stat -c %a "$akf")"
  [[ "$perms" == "600" ]] || finding MED "${akf} has mode ${perms}; expected 600"
done < /etc/passwd

# --- 8. Locked vs unlocked ------------------------------------------------------
section "Locked accounts"
awk -F: '($2 ~ /^[!*]/) {print "  " $1}' /etc/shadow | head -20

# --- Findings -------------------------------------------------------------------
if [[ "$JSON" == "true" ]]; then
  printf '{"host":"%s","timestamp":"%s","findings":[' "$(hostname -f)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  first=true
  for f in "${FINDINGS[@]}"; do
    IFS='|' read -r sev msg <<< "$f"
    [[ "$first" == "true" ]] && first=false || printf ','
    printf '{"severity":"%s","message":"%s"}' "$sev" "$msg"
  done
  printf ']}\n'
else
  printf '\n%s\n' "=================================================================="
  if (( ${#FINDINGS[@]} == 0 )); then
    printf '  \033[32mNo findings.\033[0m\n\n'
  else
    printf '  %d finding(s):\n\n' "${#FINDINGS[@]}"
    for sev in CRIT HIGH MED; do
      for f in "${FINDINGS[@]}"; do
        IFS='|' read -r s msg <<< "$f"
        [[ "$s" == "$sev" ]] || continue
        case "$sev" in
          CRIT) printf '  \033[31m[CRIT]\033[0m %s\n' "$msg" ;;
          HIGH) printf '  \033[31m[HIGH]\033[0m %s\n' "$msg" ;;
          MED)  printf '  \033[33m[MED ]\033[0m %s\n' "$msg" ;;
        esac
      done
    done
    printf '\n  Access control model: docs/security/access-control.md\n\n'
  fi
fi

emit_metric "account_audit.prom" "platform_account_audit_findings" "${#FINDINGS[@]}" \
  "Number of findings from the last account audit" "gauge"
