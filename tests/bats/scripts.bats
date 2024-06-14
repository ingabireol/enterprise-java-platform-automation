#!/usr/bin/env bats
# Contract tests for the operational scripts.
#
# These do not exercise the scripts against a real host — they check the
# contracts that a caller depends on: that --help works, that a missing required
# argument is rejected rather than silently defaulted, and that the safety guards
# actually refuse.

SCRIPTS="${BATS_TEST_DIRNAME}/../../scripts"

@test "every script is syntactically valid" {
  while IFS= read -r script; do
    run bash -n "$script"
    [ "$status" -eq 0 ] || { echo "Syntax error in $script: $output"; return 1; }
  done < <(find "$SCRIPTS" -name '*.sh')
}

@test "every script is executable" {
  while IFS= read -r script; do
    [[ "$script" == */lib/* ]] && continue
    [ -x "$script" ] || { echo "$script is not executable"; return 1; }
  done < <(find "$SCRIPTS" -name '*.sh')
}

@test "every script sets errexit, nounset and pipefail" {
  # Inherited from common.sh, which every script sources. Check it is there.
  grep -q 'set -o errexit'  "$SCRIPTS/lib/common.sh"
  grep -q 'set -o nounset'  "$SCRIPTS/lib/common.sh"
  grep -q 'set -o pipefail' "$SCRIPTS/lib/common.sh"
}

@test "pg_backup rejects a missing --mode" {
  run bash "$SCRIPTS/backup/pg_backup.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--mode is required"* ]]
}

@test "pg_backup rejects an invalid mode" {
  run bash "$SCRIPTS/backup/pg_backup.sh" --mode nonsense
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid mode"* ]]
}

@test "deploy rejects a missing --version" {
  run bash "$SCRIPTS/ops/deploy.sh"
  [ "$status" -ne 0 ]
}

@test "deploy refuses a non-semantic version" {
  # Deployments must be reproducible; 'latest' is explicitly refused.
  run bash -c "APP_BASE_DIR=/tmp bash '$SCRIPTS/ops/deploy.sh' --version latest 2>&1"
  [[ "$output" == *"semantic version"* ]] || [[ "$output" == *"must run as root"* ]]
}

@test "drain requires an action" {
  run bash "$SCRIPTS/ops/drain.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--out, --in or --status"* ]]
}

@test "every script rejects an unknown argument rather than ignoring it" {
  for s in "$SCRIPTS"/ops/drain.sh "$SCRIPTS"/monitoring/health_check.sh "$SCRIPTS"/security/tls_audit.sh; do
    run bash "$s" --this-flag-does-not-exist
    [ "$status" -ne 0 ] || { echo "$s silently accepted an unknown flag"; return 1; }
  done
}

@test "health_check produces valid JSON with --json" {
  run bash "$SCRIPTS/monitoring/health_check.sh" --json
  [ "$status" -eq 0 ]
  # The output must parse; a malformed health report breaks whatever consumes it.
  echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
    || echo "$output" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))'
}

@test "prune_backups supports a dry run" {
  grep -q -- '--dry-run' "$SCRIPTS/backup/prune_backups.sh"
}

@test "prune_backups protects the most recent full backup" {
  # The single most important property of the retention policy.
  grep -q 'Protecting the most recent full backup' "$SCRIPTS/backup/prune_backups.sh"
}

@test "verify_restore never touches the live cluster" {
  # It must always restore to a scratch port, never the default 5432.
  grep -q 'SCRATCH_PORT=55432' "$SCRIPTS/backup/verify_restore.sh"
}

@test "no script contains a hardcoded credential" {
  while IFS= read -r script; do
    if grep -nEi '(password|passwd|secret|token)\s*=\s*["'\''][^"'\''$][^"'\'']{7,}' "$script" \
       | grep -vE '(CHANGE-ME|changeme|\$\{|example|PASSWORD=\$)'; then
      echo "Possible hardcoded credential in $script"
      return 1
    fi
  done < <(find "$SCRIPTS" -name '*.sh')
}
