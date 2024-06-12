#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tls_audit.sh — audit the TLS posture of the platform endpoints.
#
#   tls_audit.sh [--host HOST] [--port 443] [--warn-days 30] [--json]
#
# Reports certificate expiry, key strength, signature algorithm, chain validity,
# negotiated protocol versions and whether any deprecated protocol still
# answers. Certificate expiry is the single most common cause of a
# self-inflicted outage in an otherwise well-run platform, so it is checked on a
# schedule rather than remembered.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/common.sh" 2>/dev/null || . "${SCRIPT_DIR}/../lib/common.sh"

HOST="127.0.0.1"
PORT=443
WARN_DAYS=30
CRIT_DAYS=14
JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --warn-days) WARN_DAYS="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

require_commands openssl

STATUS=OK
declare -a FINDINGS=()

finding() {
  local sev="$1" msg="$2"
  FINDINGS+=("${sev}|${msg}")
  case "$sev" in
    CRIT) STATUS=CRIT ;;
    WARN) [[ "$STATUS" == "OK" ]] && STATUS=WARN ;;
  esac
}

CERT="$(echo | openssl s_client -connect "${HOST}:${PORT}" -servername "$HOST" 2>/dev/null | openssl x509 2>/dev/null)"
[[ -n "$CERT" ]] || die "No certificate returned from ${HOST}:${PORT}" 1

SUBJECT="$(printf '%s' "$CERT" | openssl x509 -noout -subject | sed 's/^subject=//')"
ISSUER="$(printf '%s' "$CERT" | openssl x509 -noout -issuer | sed 's/^issuer=//')"
NOT_AFTER="$(printf '%s' "$CERT" | openssl x509 -noout -enddate | cut -d= -f2)"
SIG_ALG="$(printf '%s' "$CERT" | openssl x509 -noout -text | awk '/Signature Algorithm/ {print $3; exit}')"
KEY_BITS="$(printf '%s' "$CERT" | openssl x509 -noout -text | grep -oE '[0-9]+ bit' | head -1 | cut -d' ' -f1)"
SAN="$(printf '%s' "$CERT" | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -1 | tr -d ' ')"

DAYS_LEFT=$(( ( $(date -d "$NOT_AFTER" +%s) - $(date +%s) ) / 86400 ))

# --- Expiry ---------------------------------------------------------------
if   (( DAYS_LEFT < 0 ));          then finding CRIT "Certificate EXPIRED ${DAYS_LEFT#-} day(s) ago"
elif (( DAYS_LEFT < CRIT_DAYS ));  then finding CRIT "Certificate expires in ${DAYS_LEFT} day(s)"
elif (( DAYS_LEFT < WARN_DAYS ));  then finding WARN "Certificate expires in ${DAYS_LEFT} day(s)"
fi

# --- Key strength ----------------------------------------------------------
if [[ -n "$KEY_BITS" ]] && (( KEY_BITS < 2048 )); then
  finding CRIT "Public key is only ${KEY_BITS} bits"
fi

# --- Signature algorithm ---------------------------------------------------
case "$SIG_ALG" in
  *sha1*|*md5*) finding CRIT "Certificate signed with a broken algorithm: ${SIG_ALG}" ;;
esac

# --- Chain validity --------------------------------------------------------
if ! echo | openssl s_client -connect "${HOST}:${PORT}" -servername "$HOST" 2>/dev/null \
     | grep -q "Verify return code: 0"; then
  finding WARN "Certificate chain did not verify against the system trust store"
fi

# --- Protocol versions -----------------------------------------------------
for proto in ssl3 tls1 tls1_1; do
  if echo | timeout 5 openssl s_client -"${proto}" -connect "${HOST}:${PORT}" 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
    finding CRIT "Deprecated protocol ${proto} is still accepted"
  fi
done

TLS12=no; TLS13=no
echo | timeout 5 openssl s_client -tls1_2 -connect "${HOST}:${PORT}" 2>/dev/null | grep -q "BEGIN CERTIFICATE" && TLS12=yes
echo | timeout 5 openssl s_client -tls1_3 -connect "${HOST}:${PORT}" 2>/dev/null | grep -q "BEGIN CERTIFICATE" && TLS13=yes
[[ "$TLS13" == "no" ]] && finding WARN "TLS 1.3 is not offered"

# --- HSTS ------------------------------------------------------------------
if HEADERS="$(curl -sSIk --max-time 10 "https://${HOST}:${PORT}/" 2>/dev/null)"; then
  grep -qi 'strict-transport-security' <<< "$HEADERS" || finding WARN "No Strict-Transport-Security header"
  grep -qi 'x-content-type-options'    <<< "$HEADERS" || finding WARN "No X-Content-Type-Options header"
  grep -qi 'content-security-policy'   <<< "$HEADERS" || finding WARN "No Content-Security-Policy header"
  grep -qiE '^server: .+/[0-9]'        <<< "$HEADERS" && finding WARN "Server header discloses a version"
fi

# --- Output -----------------------------------------------------------------
if [[ "$JSON" == "true" ]]; then
  printf '{"endpoint":"%s:%s","status":"%s","days_until_expiry":%d,"not_after":"%s","key_bits":"%s","signature":"%s","tls12":"%s","tls13":"%s","findings":[' \
    "$HOST" "$PORT" "$STATUS" "$DAYS_LEFT" "$NOT_AFTER" "${KEY_BITS:-unknown}" "$SIG_ALG" "$TLS12" "$TLS13"
  first=true
  for f in "${FINDINGS[@]}"; do
    IFS='|' read -r sev msg <<< "$f"
    [[ "$first" == "true" ]] && first=false || printf ','
    printf '{"severity":"%s","message":"%s"}' "$sev" "$msg"
  done
  printf ']}\n'
else
  printf '\nTLS audit — %s:%s\n' "$HOST" "$PORT"
  printf '%s\n' "------------------------------------------------------------------"
  printf '  Subject       : %s\n' "$SUBJECT"
  printf '  Issuer        : %s\n' "$ISSUER"
  printf '  SAN           : %s\n' "${SAN:-none}"
  printf '  Expires       : %s (%d day(s))\n' "$NOT_AFTER" "$DAYS_LEFT"
  printf '  Key           : %s bits\n' "${KEY_BITS:-unknown}"
  printf '  Signature     : %s\n' "$SIG_ALG"
  printf '  TLS 1.2 / 1.3 : %s / %s\n' "$TLS12" "$TLS13"
  printf '%s\n' "------------------------------------------------------------------"
  if (( ${#FINDINGS[@]} == 0 )); then
    printf '  \033[32mNo findings.\033[0m\n\n'
  else
    for f in "${FINDINGS[@]}"; do
      IFS='|' read -r sev msg <<< "$f"
      case "$sev" in
        CRIT) printf '  \033[31m[CRIT]\033[0m %s\n' "$msg" ;;
        WARN) printf '  \033[33m[WARN]\033[0m %s\n' "$msg" ;;
      esac
    done
    printf '\n  Rotation procedure: docs/runbooks/tls-certificate-rotation.md\n\n'
  fi
fi

emit_metric "tls_audit.prom" "platform_tls_days_until_expiry" "$DAYS_LEFT" \
  "Days until the TLS certificate expires" "gauge" "endpoint=\"${HOST}:${PORT}\""

case "$STATUS" in OK) exit 0 ;; WARN) exit 1 ;; CRIT) exit 2 ;; esac
