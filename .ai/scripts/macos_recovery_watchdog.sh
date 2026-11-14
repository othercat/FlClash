#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
readonly DEFAULT_APP_PATH='/Applications/FlClash.app'
readonly RUNTIME_ROOT="${FLCLASH_WATCHDOG_RUNTIME_ROOT:-${TMPDIR:-/tmp}/flclash-phase1-watchdog-${UID}}"

usage() {
  cat <<'EOF'
Usage:
  macos_recovery_watchdog.sh arm [--timeout SECONDS] [--app-path PATH]
  macos_recovery_watchdog.sh disarm
  macos_recovery_watchdog.sh status
  macos_recovery_watchdog.sh recover
  macos_recovery_watchdog.sh self-test

The watchdog never changes TUN or proxy settings itself. If it is not disarmed
before the timeout, it returns to the pre-test process state:

  - FlClash was running: terminate the current instance and reopen APP_PATH.
  - FlClash was not running: terminate any test instance and leave it stopped.

Run `arm` before a risky manual test and `disarm` after connectivity is verified.
Runtime files are private (mode 0700) and contain no profile, proxy, or account data.
EOF
}

log_line() {
  local message="$1"
  mkdir -p "$RUNTIME_ROOT"
  chmod 700 "$RUNTIME_ROOT"
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$message" >> "$RUNTIME_ROOT/watchdog.log"
}

is_running() {
  pgrep -x "$1" >/dev/null 2>&1
}

read_state_value() {
  local name="$1"
  local value=''
  if [[ -f "$RUNTIME_ROOT/$name" ]]; then
    IFS= read -r value < "$RUNTIME_ROOT/$name" || true
  fi
  printf '%s' "$value"
}

validate_app_path() {
  local app_path="$1"
  if [[ "$app_path" != /* || "$app_path" == '/' || "${app_path##*.}" != 'app' ]]; then
    printf 'Invalid app path: expected an absolute .app path.\n' >&2
    exit 2
  fi
  if [[ ! -d "$app_path" ]]; then
    printf 'App not found: %s\n' "$app_path" >&2
    exit 2
  fi
}

write_state() {
  local app_path="$1"
  local timeout_seconds="$2"
  local app_was_running='0'
  local core_was_running='0'

  is_running FlClash && app_was_running='1'
  is_running FlClashCore && core_was_running='1'

  mkdir -p "$RUNTIME_ROOT"
  chmod 700 "$RUNTIME_ROOT"
  printf '%s\n' "$app_path" > "$RUNTIME_ROOT/app_path"
  printf '%s\n' "$timeout_seconds" > "$RUNTIME_ROOT/timeout_seconds"
  printf '%s\n' "$app_was_running" > "$RUNTIME_ROOT/app_was_running"
  printf '%s\n' "$core_was_running" > "$RUNTIME_ROOT/core_was_running"
  chmod 600 "$RUNTIME_ROOT"/*
}

terminate_flclash() {
  if is_running FlClash; then
    pkill -TERM -x FlClash >/dev/null 2>&1 || true
  fi
  if is_running FlClashCore; then
    pkill -TERM -x FlClashCore >/dev/null 2>&1 || true
  fi

  local attempt
  for attempt in 1 2 3 4 5; do
    if ! is_running FlClash && ! is_running FlClashCore; then
      return 0
    fi
    sleep 1
  done

  # Escalation is limited to the two exact FlClash process names.
  pkill -KILL -x FlClash >/dev/null 2>&1 || true
  pkill -KILL -x FlClashCore >/dev/null 2>&1 || true
}

recover_now() {
  local dry_run="${1:-0}"
  local app_path
  local app_was_running
  app_path="$(read_state_value app_path)"
  app_was_running="$(read_state_value app_was_running)"

  if [[ -z "$app_path" || -z "$app_was_running" ]]; then
    printf 'No armed watchdog state found.\n' >&2
    exit 2
  fi

  if [[ "$dry_run" == '1' ]]; then
    if [[ "$app_was_running" == '1' ]]; then
      log_line 'dry-run: would terminate exact FlClash processes and reopen the recorded app'
    else
      log_line 'dry-run: would terminate exact FlClash processes and leave the app stopped'
    fi
    return 0
  fi

  log_line 'recovery started'
  terminate_flclash

  if [[ "$app_was_running" == '1' ]]; then
    validate_app_path "$app_path"
    /usr/bin/open -n "$app_path"

    local attempt
    for attempt in $(seq 1 30); do
      if is_running FlClash && is_running FlClashCore; then
        log_line 'recovery completed: app and core are running'
        return 0
      fi
      sleep 1
    done
    log_line 'recovery incomplete: app/core did not both appear within 30 seconds'
    return 1
  fi

  log_line 'recovery completed: pre-test state was stopped'
}

watch_loop() {
  local timeout_seconds="$1"
  local elapsed='0'

  while (( elapsed < timeout_seconds )); do
    if [[ -f "$RUNTIME_ROOT/disarmed" ]]; then
      log_line 'watchdog disarmed before timeout'
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if [[ -f "$RUNTIME_ROOT/disarmed" ]]; then
    log_line 'watchdog disarmed at timeout boundary'
    return 0
  fi

  log_line 'timeout reached'
  recover_now "${FLCLASH_WATCHDOG_DRY_RECOVERY:-0}"
}

arm_watchdog() {
  local timeout_seconds='900'
  local app_path="$DEFAULT_APP_PATH"

  while (( $# > 0 )); do
    case "$1" in
      --timeout)
        timeout_seconds="${2:-}"
        shift 2
        ;;
      --app-path)
        app_path="${2:-}"
        shift 2
        ;;
      *)
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if [[ ! "$timeout_seconds" =~ ^[0-9]+$ ]] || (( timeout_seconds < 30 || timeout_seconds > 7200 )); then
    printf 'Timeout must be an integer between 30 and 7200 seconds.\n' >&2
    exit 2
  fi
  validate_app_path "$app_path"

  if [[ -f "$RUNTIME_ROOT/watchdog.pid" ]]; then
    local existing_pid
    existing_pid="$(read_state_value watchdog.pid)"
    if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" >/dev/null 2>&1; then
      printf 'A watchdog is already armed (PID %s).\n' "$existing_pid" >&2
      exit 2
    fi
  fi

  rm -f "$RUNTIME_ROOT/disarmed"
  write_state "$app_path" "$timeout_seconds"
  log_line "watchdog armed for ${timeout_seconds}s"

  nohup "$SCRIPT_PATH" _watch "$timeout_seconds" >/dev/null 2>&1 &
  local watchdog_pid=$!
  printf '%s\n' "$watchdog_pid" > "$RUNTIME_ROOT/watchdog.pid"
  chmod 600 "$RUNTIME_ROOT/watchdog.pid"

  printf 'Watchdog armed: PID %s, timeout %ss.\n' "$watchdog_pid" "$timeout_seconds"
  printf 'Disarm after recovery is confirmed: %s disarm\n' "$SCRIPT_PATH"
}

disarm_watchdog() {
  mkdir -p "$RUNTIME_ROOT"
  chmod 700 "$RUNTIME_ROOT"
  : > "$RUNTIME_ROOT/disarmed"
  chmod 600 "$RUNTIME_ROOT/disarmed"
  log_line 'disarm requested'
  printf 'Watchdog disarm marker written.\n'
}

show_status() {
  local watchdog_pid
  watchdog_pid="$(read_state_value watchdog.pid)"
  if [[ "$watchdog_pid" =~ ^[0-9]+$ ]] && kill -0 "$watchdog_pid" >/dev/null 2>&1; then
    printf 'armed pid=%s timeout=%ss app_was_running=%s core_was_running=%s\n' \
      "$watchdog_pid" \
      "$(read_state_value timeout_seconds)" \
      "$(read_state_value app_was_running)" \
      "$(read_state_value core_was_running)"
    return 0
  fi
  printf 'not armed\n'
}

self_test() {
  local self_test_root="${TMPDIR:-/tmp}/flclash-phase1-watchdog-self-test-${UID}-$$"
  mkdir -p "$self_test_root"
  chmod 700 "$self_test_root"

  printf '%s\n' '/Applications/FlClash.app' > "$self_test_root/app_path"
  printf '%s\n' '1' > "$self_test_root/app_was_running"
  FLCLASH_WATCHDOG_RUNTIME_ROOT="$self_test_root" \
    FLCLASH_WATCHDOG_DRY_RECOVERY='1' \
    "$SCRIPT_PATH" _watch 1
  grep -q 'timeout reached' "$self_test_root/watchdog.log"
  grep -q 'dry-run: would terminate exact FlClash processes' "$self_test_root/watchdog.log"

  rm -f "$self_test_root/app_path" \
    "$self_test_root/app_was_running" \
    "$self_test_root/watchdog.log"
  rmdir "$self_test_root"
  printf 'self-test passed: timeout path reached dry recovery; no FlClash process was touched\n'
}

main() {
  local command="${1:-}"
  [[ $# -gt 0 ]] && shift

  case "$command" in
    arm)
      arm_watchdog "$@"
      ;;
    disarm)
      disarm_watchdog
      ;;
    status)
      show_status
      ;;
    recover)
      recover_now 0
      ;;
    self-test)
      self_test
      ;;
    _watch)
      watch_loop "${1:?missing timeout}"
      ;;
    -h|--help|help|'')
      usage
      ;;
    *)
      printf 'Unknown command: %s\n' "$command" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
