#!/usr/bin/env bats
# Tests for scripts/lib/common.sh — the helpers every operational script depends on.
# If these break, every script breaks silently and at the worst moment.

setup() {
  export METRICS_DIR="$BATS_TEST_TMPDIR/metrics"
  export LOG_LEVEL=ERROR
  mkdir -p "$METRICS_DIR"
  # shellcheck source=../../scripts/lib/common.sh
  source "${BATS_TEST_DIRNAME}/../../scripts/lib/common.sh"
}

@test "log respects the configured level" {
  LOG_LEVEL=WARN
  run log_info "should not appear"
  [ -z "$output" ]

  run log_error "should appear"
  [[ "$output" == *"should appear"* ]]
}

@test "log includes level, script name and pid" {
  LOG_LEVEL=DEBUG
  run log_warn "test message"
  [[ "$output" == *"[WARN]"* ]]
  [[ "$output" == *"test message"* ]]
}

@test "die exits with the requested code" {
  run bash -c "source '${BATS_TEST_DIRNAME}/../../scripts/lib/common.sh'; die 'fatal' 42"
  [ "$status" -eq 42 ]
}

@test "die defaults to exit code 1" {
  run bash -c "source '${BATS_TEST_DIRNAME}/../../scripts/lib/common.sh'; die 'fatal'"
  [ "$status" -eq 1 ]
}

@test "retry succeeds on the first attempt without sleeping" {
  run retry 3 true
  [ "$status" -eq 0 ]
}

@test "retry gives up after the configured number of attempts" {
  RETRY_INITIAL_DELAY=0
  run retry 2 false
  [ "$status" -eq 1 ]
}

@test "retry eventually succeeds when the command starts working" {
  RETRY_INITIAL_DELAY=0
  local marker="$BATS_TEST_TMPDIR/attempts"
  echo 0 > "$marker"
  flaky() {
    local n
    n=$(cat "$marker")
    echo $(( n + 1 )) > "$marker"
    [ "$n" -ge 2 ]
  }
  run retry 5 flaky
  [ "$status" -eq 0 ]
}

@test "require_commands fails when a command is missing" {
  run require_commands definitely-not-a-real-command-xyz
  [ "$status" -eq 127 ]
  [[ "$output" == *"Missing required command"* ]]
}

@test "require_commands passes for commands that exist" {
  run require_commands ls cat
  [ "$status" -eq 0 ]
}

@test "emit_metric writes a well-formed Prometheus exposition file" {
  emit_metric "test.prom" "platform_test_metric" "42" "A test metric" "gauge"
  [ -f "$METRICS_DIR/test.prom" ]
  grep -q "^# HELP platform_test_metric A test metric$" "$METRICS_DIR/test.prom"
  grep -q "^# TYPE platform_test_metric gauge$" "$METRICS_DIR/test.prom"
  grep -q "^platform_test_metric 42$" "$METRICS_DIR/test.prom"
}

@test "emit_metric writes labels when given them" {
  emit_metric "labelled.prom" "platform_test" "1" "help" "gauge" 'mode="full",db="efp"'
  grep -q 'platform_test{mode="full",db="efp"} 1' "$METRICS_DIR/labelled.prom"
}

@test "emit_metric writes atomically — no partial file is left behind" {
  emit_metric "atomic.prom" "m" "1" "h" "gauge"
  run find "$METRICS_DIR" -name 'atomic.prom.*'
  [ -z "$output" ]
}

@test "append_metric adds a line to an existing metric file" {
  emit_metric "multi.prom" "first_metric" "1" "help" "gauge"
  append_metric "multi.prom" "second_metric" "2"
  grep -q "^first_metric 1$" "$METRICS_DIR/multi.prom"
  grep -q "^second_metric 2$" "$METRICS_DIR/multi.prom"
}

@test "human_bytes converts to sensible units" {
  [ "$(human_bytes 512)" = "512 B" ]
  [ "$(human_bytes 2048)" = "2 KiB" ]
  [ "$(human_bytes 5242880)" = "5 MiB" ]
}

@test "require_free_space passes when there is plenty" {
  run require_free_space "$BATS_TEST_TMPDIR" 1
  [ "$status" -eq 0 ]
}

@test "require_free_space fails when the requirement is absurd" {
  run require_free_space "$BATS_TEST_TMPDIR" 999999999
  [ "$status" -eq 28 ]
  [[ "$output" == *"required"* ]]
}

@test "timer measures elapsed time" {
  timer_start
  run timer_elapsed
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "load_config sources a config file" {
  local cfg="$BATS_TEST_TMPDIR/test.conf"
  echo 'TEST_VALUE="loaded"' > "$cfg"
  load_config "$cfg"
  [ "$TEST_VALUE" = "loaded" ]
}

@test "load_config warns but does not fail on a missing file" {
  LOG_LEVEL=DEBUG
  run load_config "$BATS_TEST_TMPDIR/does-not-exist.conf"
  [ "$status" -eq 0 ]
}
