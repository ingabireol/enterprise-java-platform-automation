#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# common.sh — shared helpers for the platform operations scripts.
#
# Source it, do not execute it:
#     . "$(dirname "$0")/common.sh"
#
# Provides: structured logging, single-instance locking, retry with backoff,
# a trap-based cleanup stack, Prometheus textfile metric emission, and
# notification. Everything here is POSIX-ish bash 4+, no external dependencies
# beyond coreutils, because these scripts must work on a host that is having a
# bad day.
# ---------------------------------------------------------------------------

set -o errexit
set -o nounset
set -o pipefail

# --- Configuration ---------------------------------------------------------
readonly COMMON_SH_VERSION="1.4.0"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_FILE="${LOG_FILE:-}"
SCRIPT_NAME="$(basename "${BASH_SOURCE[1]:-$0}")"
readonly SCRIPT_NAME
METRICS_DIR="${METRICS_DIR:-/var/lib/node_exporter/textfile_collector}"

# --- Logging ---------------------------------------------------------------
# Levels: DEBUG < INFO < WARN < ERROR. Everything goes to stderr so that a
# script's stdout stays clean for machine consumption.

_log_level_num() {
  case "$1" in
    DEBUG) echo 10 ;;
    INFO)  echo 20 ;;
    WARN)  echo 30 ;;
    ERROR) echo 40 ;;
    *)     echo 20 ;;
  esac
}

log() {
  local level="$1"; shift
  local threshold current
  threshold="$(_log_level_num "$LOG_LEVEL")"
  current="$(_log_level_num "$level")"
  (( current < threshold )) && return 0

  local ts line
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  line="${ts} [${level}] ${SCRIPT_NAME}[$$]: $*"

  printf '%s\n' "$line" >&2
  [[ -n "$LOG_FILE" ]] && printf '%s\n' "$line" >> "$LOG_FILE"

  # Anything at WARN or above also reaches the journal, where promtail picks it
  # up and Loki makes it searchable alongside the application logs.
  if (( current >= 30 )); then
    command -v logger >/dev/null 2>&1 && logger -t "$SCRIPT_NAME" -p "user.${level,,}" "$*"
  fi
  return 0
}

log_debug() { log DEBUG "$@"; }
log_info()  { log INFO  "$@"; }
log_warn()  { log WARN  "$@"; }
log_error() { log ERROR "$@"; }

die() {
  local code="${2:-1}"
  log_error "$1"
  exit "$code"
}

# --- Cleanup stack ---------------------------------------------------------
# Register teardown actions as they become necessary; they run in reverse order
# on exit, whether the script succeeded, failed or was interrupted.

declare -a _CLEANUP_STACK=()

on_cleanup() {
  _CLEANUP_STACK+=("$*")
}

_run_cleanup() {
  local rc=$?
  local i
  for (( i=${#_CLEANUP_STACK[@]}-1 ; i>=0 ; i-- )); do
    log_debug "cleanup: ${_CLEANUP_STACK[i]}"
    eval "${_CLEANUP_STACK[i]}" || log_warn "cleanup step failed: ${_CLEANUP_STACK[i]}"
  done
  return "$rc"
}
trap _run_cleanup EXIT
trap 'die "Interrupted by signal" 130' INT TERM

# --- Locking ---------------------------------------------------------------
# Prevents a slow backup from overlapping the next scheduled run — the classic
# way a healthy system runs itself out of I/O at 01:00 on a Monday.

acquire_lock() {
  local name="${1:-$SCRIPT_NAME}"
  local lockfile="/var/lock/${name}.lock"
  local timeout="${2:-0}"

  exec {_LOCK_FD}>"$lockfile" || die "Cannot open lock file $lockfile"

  if (( timeout > 0 )); then
    if ! flock -w "$timeout" "$_LOCK_FD"; then
      die "Another instance of ${name} holds the lock (waited ${timeout}s)" 75
    fi
  else
    if ! flock -n "$_LOCK_FD"; then
      local holder
      holder="$(cat "$lockfile" 2>/dev/null || echo unknown)"
      die "Another instance of ${name} is already running (pid ${holder})" 75
    fi
  fi

  printf '%s\n' "$$" >&"$_LOCK_FD"
  log_debug "Acquired lock $lockfile"
  on_cleanup "rm -f '$lockfile'"
}

# --- Retry -----------------------------------------------------------------
# Exponential backoff with a cap. Used for anything that crosses the network.

retry() {
  local attempts="$1"; shift
  local delay="${RETRY_INITIAL_DELAY:-2}"
  local max_delay="${RETRY_MAX_DELAY:-60}"
  local attempt=1

  while true; do
    if "$@"; then
      (( attempt > 1 )) && log_info "Succeeded on attempt ${attempt}"
      return 0
    fi
    if (( attempt >= attempts )); then
      log_error "Failed after ${attempts} attempt(s): $*"
      return 1
    fi
    log_warn "Attempt ${attempt}/${attempts} failed; retrying in ${delay}s: $*"
    sleep "$delay"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
    (( delay > max_delay )) && delay="$max_delay"
  done
}

# --- Requirements ----------------------------------------------------------

require_commands() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} > 0 )) && die "Missing required command(s): ${missing[*]}" 127
  return 0
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "This script must run as root" 77
}

require_user() {
  [[ "$(id -un)" == "$1" ]] || die "This script must run as $1 (currently $(id -un))" 77
}

# --- Free space guard ------------------------------------------------------
# Refuses to start an operation that would plausibly fill a filesystem. Cheaper
# than recovering from a full /var at 02:00.

require_free_space() {
  local path="$1" required_mb="$2" available_mb
  available_mb="$(df -Pm "$path" | awk 'NR==2 {print $4}')"
  if (( available_mb < required_mb )); then
    die "Only ${available_mb} MiB free on ${path}; ${required_mb} MiB required" 28
  fi
  log_debug "Free space check passed on ${path}: ${available_mb} MiB available"
}

# --- Prometheus textfile metrics ------------------------------------------
# Written atomically: node_exporter reads this directory continuously and a
# half-written file produces a parse error and a gap in the graph.

emit_metric() {
  local file="$1" name="$2" value="$3" help="${4:-}" type="${5:-gauge}"
  shift 5 2>/dev/null || shift $#
  local labels="${1:-}"

  mkdir -p "$METRICS_DIR"
  local target="${METRICS_DIR}/${file}"
  local tmp="${target}.$$"

  {
    [[ -n "$help" ]] && printf '# HELP %s %s\n' "$name" "$help"
    printf '# TYPE %s %s\n' "$name" "$type"
    if [[ -n "$labels" ]]; then
      printf '%s{%s} %s\n' "$name" "$labels" "$value"
    else
      printf '%s %s\n' "$name" "$value"
    fi
  } > "$tmp"

  mv -f "$tmp" "$target"
  chmod 0644 "$target"
  log_debug "Emitted ${name}=${value} to ${target}"
}

# Append to an existing metric file within the same run (first call should use
# emit_metric to create it).
append_metric() {
  local file="$1" name="$2" value="$3" labels="${4:-}"
  local target="${METRICS_DIR}/${file}"
  if [[ -n "$labels" ]]; then
    printf '%s{%s} %s\n' "$name" "$labels" "$value" >> "$target"
  else
    printf '%s %s\n' "$name" "$value" >> "$target"
  fi
}

# --- Notification ----------------------------------------------------------

notify() {
  local subject="$1" body="$2" severity="${3:-warning}"
  local to="${ALERT_EMAIL:-root}"

  log_info "Notification [${severity}]: ${subject}"

  if command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "[${severity^^}] [$(hostname -s)] ${subject}" "$to" \
      || log_warn "Failed to send notification email to ${to}"
  else
    log_warn "mail(1) is not available; notification not sent: ${subject}"
  fi
}

# --- Timing ----------------------------------------------------------------

timer_start() { _TIMER_START="$(date +%s)"; }
timer_elapsed() { echo $(( $(date +%s) - ${_TIMER_START:-$(date +%s)} )); }

# --- Human-readable sizes --------------------------------------------------

human_bytes() {
  local bytes="$1"
  local units=(B KiB MiB GiB TiB)
  local i=0
  while (( bytes > 1024 && i < 4 )); do
    bytes=$(( bytes / 1024 ))
    i=$(( i + 1 ))
  done
  printf '%s %s' "$bytes" "${units[i]}"
}

# --- Configuration loading -------------------------------------------------

load_config() {
  local config="${1:-/opt/efp/etc/backup.conf}"
  if [[ -r "$config" ]]; then
    # shellcheck source=/dev/null
    . "$config"
    log_debug "Loaded configuration from ${config}"
  else
    log_warn "Configuration file ${config} not readable; relying on defaults and environment"
  fi
}

log_debug "common.sh ${COMMON_SH_VERSION} loaded"
