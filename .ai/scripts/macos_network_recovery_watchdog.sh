#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly STATE_SCRIPT="$SCRIPT_DIR/macos_flclash_state_snapshot.swift"
readonly PROXY_SCRIPT="$SCRIPT_DIR/macos_proxy_state_snapshot.swift"
readonly AX_SCRIPT="$SCRIPT_DIR/macos_flclash_ax_scan.swift"
readonly WINDOW_SCRIPT="$SCRIPT_DIR/macos_flclash_window.swift"
readonly CORE_SCRIPT="$SCRIPT_DIR/macos_core_control.rb"
readonly DEFAULT_APP_PATH='/Applications/FlClash.app'
readonly RUNTIME_ROOT="${FLCLASH_PHASE1_WATCHDOG_RUNTIME_ROOT:-${TMPDIR:-/tmp}/flclash-phase1-network-watchdog-${UID}}"

usage() {
  cat <<'EOF'
Usage:
  macos_network_recovery_watchdog.sh arm [--timeout SECONDS]
  macos_network_recovery_watchdog.sh verify-controller
  macos_network_recovery_watchdog.sh ready
  macos_network_recovery_watchdog.sh begin-risk
  macos_network_recovery_watchdog.sh set-tun true|false [--stack mixed|system|gvisor]
  macos_network_recovery_watchdog.sh toggle-tun true|false
  macos_network_recovery_watchdog.sh trigger-recovery
  macos_network_recovery_watchdog.sh recover
  macos_network_recovery_watchdog.sh disarm
  macos_network_recovery_watchdog.sh status
  macos_network_recovery_watchdog.sh log
  macos_network_recovery_watchdog.sh self-test

Safety protocol:
  1. Run arm before enabling FlClash's loopback external controller.
  2. Enable External controller in the ordinary Flutter window.
  3. Run verify-controller, then ready.
  4. Immediately before a TUN experiment, run begin-risk.
  5. Only a ready watchdog in risk mode may authorize a TUN PATCH.
  6. Run recover after the test, verify its log, then disarm.

Run `arm` in a dedicated terminal or persistent PTY: it intentionally remains
in the foreground until timeout recovery or disarm. Runtime state is mode 0700/0600
and contains only whitelisted booleans, enums, counts, PIDs, and safe log events.
It never stores a controller secret, user configuration, proxy address, bypass
domain, node, subscription URL, or account data.
EOF
}

ensure_runtime_root() {
  mkdir -p "$RUNTIME_ROOT"
  chmod 700 "$RUNTIME_ROOT"
}

log_line() {
  local message="$1"
  ensure_runtime_root
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$message" \
    >> "$RUNTIME_ROOT/watchdog.log"
  chmod 600 "$RUNTIME_ROOT/watchdog.log"
}

read_state() {
  local name="$1"
  local value=''
  if [[ -f "$RUNTIME_ROOT/$name" ]]; then
    IFS= read -r value < "$RUNTIME_ROOT/$name" || true
  fi
  printf '%s' "$value"
}

write_state() {
  local name="$1"
  local value="$2"
  ensure_runtime_root
  printf '%s\n' "$value" > "$RUNTIME_ROOT/$name"
  chmod 600 "$RUNTIME_ROOT/$name"
}

value_from_snapshot() {
  local snapshot="$1"
  local key="$2"
  printf '%s\n' "$snapshot" | /usr/bin/awk -F= -v wanted="$key" \
    '$1 == wanted { value = substr($0, index($0, "=") + 1) } END { print value }'
}

require_bool() {
  local name="$1"
  local value="$2"
  if [[ "$value" != 'true' && "$value" != 'false' ]]; then
    printf 'Invalid boolean state for %s.\n' "$name" >&2
    exit 1
  fi
}

require_stack() {
  local value="$1"
  if [[ "$value" != 'mixed' && "$value" != 'system' && "$value" != 'gvisor' ]]; then
    printf 'Invalid TUN stack state.\n' >&2
    exit 1
  fi
}

process_count() {
  (pgrep -x "$1" 2>/dev/null || true) | /usr/bin/awk 'END { print NR + 0 }'
}

single_process_pid() {
  local name="$1"
  local pids
  pids="$(pgrep -x "$name" 2>/dev/null || true)"
  if [[ "$(printf '%s\n' "$pids" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')" != '1' ]]; then
    printf 'Expected exactly one %s process.\n' "$name" >&2
    exit 1
  fi
  printf '%s' "$pids"
}

is_watchdog_alive() {
  local watchdog_pid
  local command
  watchdog_pid="$(read_state watchdog.pid)"
  if [[ ! "$watchdog_pid" =~ ^[0-9]+$ ]] \
    || ! kill -0 "$watchdog_pid" >/dev/null 2>&1; then
    return 1
  fi
  command="$(/bin/ps -p "$watchdog_pid" -o command= 2>/dev/null || true)"
  [[ "$command" == *"$SCRIPT_PATH _watch"* ]]
}

set_enhanced() {
  local value="$1"
  /usr/bin/swift "$AX_SCRIPT" set-enhanced "$value" >/dev/null
}

press_label_pair() {
  local primary="$1"
  local fallback="$2"
  if /usr/bin/swift "$AX_SCRIPT" press-label "$primary" >/dev/null 2>&1; then
    return 0
  fi
  if /usr/bin/swift "$AX_SCRIPT" press-label "$fallback" >/dev/null 2>&1; then
    return 0
  fi
  set_enhanced true
  if /usr/bin/swift "$AX_SCRIPT" press-label "$primary" >/dev/null 2>&1; then
    return 0
  fi
  /usr/bin/swift "$AX_SCRIPT" press-label "$fallback" >/dev/null
}

press_system_proxy() {
  if FLCLASH_PHASE1_ALLOW_PROXY_AX=1 \
    /usr/bin/swift "$AX_SCRIPT" press-label '系统代理' >/dev/null 2>&1; then
    return 0
  fi
  if FLCLASH_PHASE1_ALLOW_PROXY_AX=1 \
    /usr/bin/swift "$AX_SCRIPT" press-label 'System proxy' >/dev/null 2>&1; then
    return 0
  fi
  set_enhanced true
  if FLCLASH_PHASE1_ALLOW_PROXY_AX=1 \
    /usr/bin/swift "$AX_SCRIPT" press-label '系统代理' >/dev/null 2>&1; then
    return 0
  fi
  FLCLASH_PHASE1_ALLOW_PROXY_AX=1 \
    /usr/bin/swift "$AX_SCRIPT" press-label 'System proxy' >/dev/null
}

press_tun() {
  if FLCLASH_PHASE1_ALLOW_TUN_AX=1 \
    /usr/bin/swift "$AX_SCRIPT" press-label '虚拟网卡' >/dev/null 2>&1; then
    return 0
  fi
  if FLCLASH_PHASE1_ALLOW_TUN_AX=1 \
    /usr/bin/swift "$AX_SCRIPT" press-label 'TUN' >/dev/null 2>&1; then
    return 0
  fi
  set_enhanced true
  if FLCLASH_PHASE1_ALLOW_TUN_AX=1 \
    /usr/bin/swift "$AX_SCRIPT" press-label '虚拟网卡' >/dev/null 2>&1; then
    return 0
  fi
  FLCLASH_PHASE1_ALLOW_TUN_AX=1 \
    /usr/bin/swift "$AX_SCRIPT" press-label 'TUN' >/dev/null
}

wait_for_preference() {
  local key="$1"
  local expected="$2"
  local attempt
  local snapshot
  local actual
  for attempt in $(seq 1 20); do
    snapshot="$(/usr/bin/swift "$STATE_SCRIPT")"
    actual="$(value_from_snapshot "$snapshot" "$key")"
    if [[ "$actual" == "$expected" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

proxy_state_matches_original() {
  local snapshot
  local key
  snapshot="$(/usr/bin/swift "$PROXY_SCRIPT")"
  for key in http_enable https_enable socks_enable pac_enable; do
    if [[ "$(value_from_snapshot "$snapshot" "$key")" != "$(read_state "proxy_$key")" ]]; then
      return 1
    fi
  done
}

normalize_dashboard() {
  set_enhanced true
  press_label_pair '仪表盘' 'Dashboard'
  sleep 1
  set_enhanced false
}

capture_pretest_state() {
  local app_pid
  local core_pid
  local state_snapshot
  local proxy_snapshot
  local ax_snapshot
  local value
  local visible_count

  app_pid="$(single_process_pid FlClash)"
  core_pid="$(single_process_pid FlClashCore)"
  normalize_dashboard

  state_snapshot="$(/usr/bin/swift "$STATE_SCRIPT")"
  proxy_snapshot="$(/usr/bin/swift "$PROXY_SCRIPT")"
  ax_snapshot="$(/usr/bin/swift "$AX_SCRIPT" scan)"

  for value in \
    system_proxy_preference \
    tun_preference \
    external_controller_preference; do
    require_bool "$value" "$(value_from_snapshot "$state_snapshot" "$value")"
  done
  for value in \
    http_enable \
    https_enable \
    socks_enable \
    pac_enable \
    enabled_hosts_are_loopback \
    enabled_ports_match; do
    require_bool "$value" "$(value_from_snapshot "$proxy_snapshot" "$value")"
  done
  require_bool \
    enhanced_user_interface \
    "$(value_from_snapshot "$ax_snapshot" enhanced_user_interface)"

  visible_count="$(value_from_snapshot "$state_snapshot" visible_window_count)"
  if [[ ! "$visible_count" =~ ^[0-9]+$ ]] || (( visible_count < 1 )); then
    printf 'Phase 1 watchdog requires a visible FlClash window.\n' >&2
    exit 1
  fi
  if [[ "$(value_from_snapshot "$ax_snapshot" enhanced_user_interface)" != 'false' ]]; then
    printf 'Phase 1 watchdog requires AXEnhancedUserInterface=false initially.\n' >&2
    exit 1
  fi

  local proxy_preference
  proxy_preference="$(value_from_snapshot "$state_snapshot" system_proxy_preference)"
  if [[ "$proxy_preference" == 'true' ]]; then
    if [[ "$(value_from_snapshot "$proxy_snapshot" http_enable)" != 'true' \
       || "$(value_from_snapshot "$proxy_snapshot" https_enable)" != 'true' \
       || "$(value_from_snapshot "$proxy_snapshot" socks_enable)" != 'true' \
       || "$(value_from_snapshot "$proxy_snapshot" pac_enable)" != 'false' \
       || "$(value_from_snapshot "$proxy_snapshot" enabled_hosts_are_loopback)" != 'true' \
       || "$(value_from_snapshot "$proxy_snapshot" enabled_ports_match)" != 'true' ]]; then
      printf 'System proxy is not in the expected FlClash-managed state.\n' >&2
      exit 1
    fi
  else
    if [[ "$(value_from_snapshot "$proxy_snapshot" http_enable)" != 'false' \
       || "$(value_from_snapshot "$proxy_snapshot" https_enable)" != 'false' \
       || "$(value_from_snapshot "$proxy_snapshot" socks_enable)" != 'false' \
       || "$(value_from_snapshot "$proxy_snapshot" pac_enable)" != 'false' ]]; then
      printf 'Disabled FlClash proxy preference does not match system state.\n' >&2
      exit 1
    fi
  fi

  local tun_stack
  tun_stack="$(value_from_snapshot "$state_snapshot" tun_stack)"
  require_stack "$tun_stack"

  write_state app.pid "$app_pid"
  write_state core.pid "$core_pid"
  write_state app_was_running true
  write_state core_was_running true
  write_state original_page dashboard
  write_state window_was_visible true
  write_state enhanced_original false
  write_state tun_enable "$(value_from_snapshot "$state_snapshot" tun_preference)"
  write_state tun_stack "$tun_stack"
  write_state external_controller_original \
    "$(value_from_snapshot "$state_snapshot" external_controller_preference)"
  write_state system_proxy_preference "$proxy_preference"
  for value in http_enable https_enable socks_enable pac_enable; do
    write_state "proxy_$value" "$(value_from_snapshot "$proxy_snapshot" "$value")"
  done
  write_state proxy_managed_by_flclash true
  write_state controller_verified false
  write_state risk_started false
}

arm_watchdog() {
  local timeout_seconds='300'
  while (( $# > 0 )); do
    case "$1" in
      --timeout)
        timeout_seconds="${2:-}"
        shift 2
        ;;
      *)
        printf 'Unknown arm option: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done
  if [[ ! "$timeout_seconds" =~ ^[0-9]+$ ]] \
    || (( timeout_seconds < 30 || timeout_seconds > 7200 )); then
    printf 'Timeout must be an integer between 30 and 7200 seconds.\n' >&2
    exit 2
  fi
  if is_watchdog_alive; then
    printf 'A Phase 1 network watchdog is already armed.\n' >&2
    exit 2
  fi

  ensure_runtime_root
  rm -f "$RUNTIME_ROOT/disarmed" \
    "$RUNTIME_ROOT/recovery_complete" \
    "$RUNTIME_ROOT/recovery_requested" \
    "$RUNTIME_ROOT/recovery_started" \
    "$RUNTIME_ROOT/controller_verified" \
    "$RUNTIME_ROOT/watchdog.pid"
  rmdir "$RUNTIME_ROOT/recovery.lock" >/dev/null 2>&1 || true
  rmdir "$RUNTIME_ROOT/operation.lock" >/dev/null 2>&1 || true
  capture_pretest_state
  write_state timeout_seconds "$timeout_seconds"
  write_state recovery_requested false
  write_state recovery_started false
  log_line "watchdog armed timeout=${timeout_seconds}s"
  printf 'arming=true timeout=%s backend=persistent_pty\n' "$timeout_seconds"
  exec /usr/bin/env \
    "FLCLASH_PHASE1_WATCHDOG_RUNTIME_ROOT=$RUNTIME_ROOT" \
    "$SCRIPT_PATH" _watch "$timeout_seconds"
}

verify_controller() {
  if ! is_watchdog_alive; then
    printf 'The Phase 1 network watchdog is not armed.\n' >&2
    exit 1
  fi
  if [[ "$(read_state recovery_started)" == 'true' \
     || -d "$RUNTIME_ROOT/recovery.lock" ]]; then
    printf 'Watchdog recovery has already started.\n' >&2
    exit 1
  fi

  local controller_snapshot
  local live_enable
  local live_stack
  controller_snapshot="$(FLCLASH_PHASE1_ALLOW_DEFAULT_CONTROLLER=1 \
    "$CORE_SCRIPT" snapshot)"
  live_enable="$(value_from_snapshot "$controller_snapshot" tun_enable)"
  live_stack="$(value_from_snapshot "$controller_snapshot" tun_stack)"
  require_bool tun_enable "$live_enable"
  require_stack "$live_stack"

  if [[ "$live_enable" != "$(read_state tun_enable)" \
     || "$live_stack" != "$(read_state tun_stack)" ]]; then
    log_line 'controller verification rejected: live TUN differs from the pre-test state'
    printf 'Controller is reachable, but live TUN does not match the pre-test state.\n' >&2
    exit 1
  fi

  write_state controller_verified true
  log_line 'controller verified: loopback GET matches pre-test TUN state'
  printf 'controller_verified=true\n'
  printf 'tun_state_matches_pretest=true\n'
}

require_ready() {
  if ! is_watchdog_alive \
    || [[ "$(read_state controller_verified)" != 'true' ]] \
    || [[ "$(read_state recovery_requested)" == 'true' ]] \
    || [[ "$(read_state recovery_started)" == 'true' ]] \
    || [[ -d "$RUNTIME_ROOT/recovery.lock" ]] \
    || [[ -f "$RUNTIME_ROOT/disarmed" ]]; then
    printf 'ready=false\n'
    return 1
  fi
  printf 'ready=true\n'
}

begin_risk() {
  require_ready >/dev/null
  write_state risk_started true
  log_line 'risk window opened: TUN PATCH gate enabled'
  printf 'risk_started=true\n'
}

request_recovery() {
  if ! is_watchdog_alive; then
    printf 'The Phase 1 network watchdog is not armed.\n' >&2
    exit 1
  fi
  if [[ "$(read_state recovery_requested)" == 'true' \
     || "$(read_state recovery_started)" == 'true' \
     || -d "$RUNTIME_ROOT/recovery.lock" ]]; then
    printf 'Watchdog recovery has already been requested or started.\n' >&2
    exit 1
  fi
  write_state recovery_requested true
  log_line 'recovery requested by controlling session'
  printf 'recovery_requested=true\n'
}

controlled_set_tun() {
  require_ready >/dev/null
  if [[ "$(read_state risk_started)" != 'true' ]]; then
    printf 'Risk window is not open. Run begin-risk first.\n' >&2
    exit 1
  fi
  if ! mkdir "$RUNTIME_ROOT/operation.lock" >/dev/null 2>&1; then
    printf 'Another watchdog-controlled operation is active.\n' >&2
    exit 1
  fi
  local operation_status=0
  if ! require_ready >/dev/null; then
    operation_status=1
  elif FLCLASH_PHASE1_ALLOW_DEFAULT_CONTROLLER=1 \
    FLCLASH_PHASE1_WATCHDOG_RUNTIME_ROOT="$RUNTIME_ROOT" \
    "$CORE_SCRIPT" set-tun "$@"; then
    :
  else
    operation_status=$?
  fi
  rmdir "$RUNTIME_ROOT/operation.lock"
  return "$operation_status"
}

controller_tun_matches() {
  local expected_enable="$1"
  local expected_stack="$2"
  local snapshot
  snapshot="$(FLCLASH_PHASE1_ALLOW_DEFAULT_CONTROLLER=1 \
    "$CORE_SCRIPT" snapshot)"
  [[ "$(value_from_snapshot "$snapshot" tun_enable)" == "$expected_enable" \
     && "$(value_from_snapshot "$snapshot" tun_stack)" == "$expected_stack" ]]
}

controlled_toggle_tun() {
  local desired="${1:-}"
  require_bool tun_preference "$desired"
  require_ready >/dev/null
  if [[ "$(read_state risk_started)" != 'true' ]]; then
    printf 'Risk window is not open. Run begin-risk first.\n' >&2
    exit 1
  fi
  if ! mkdir "$RUNTIME_ROOT/operation.lock" >/dev/null 2>&1; then
    printf 'Another watchdog-controlled operation is active.\n' >&2
    exit 1
  fi

  local operation_status=0
  if ! require_ready >/dev/null; then
    rmdir "$RUNTIME_ROOT/operation.lock"
    return 1
  fi

  local snapshot
  local current
  snapshot="$(/usr/bin/swift "$STATE_SCRIPT")"
  current="$(value_from_snapshot "$snapshot" tun_preference)"
  require_bool tun_preference "$current"
  if [[ "$current" != "$desired" ]]; then
    set_enhanced true || operation_status=$?
    if [[ "$operation_status" == '0' ]]; then
      press_label_pair '仪表盘' 'Dashboard' || operation_status=$?
    fi
    sleep 1
    if [[ "$operation_status" == '0' ]]; then
      press_tun || operation_status=$?
    fi
    if [[ "$operation_status" == '0' ]]; then
      wait_for_preference tun_preference "$desired" || operation_status=$?
    fi
    sleep 3
    set_enhanced false || operation_status=$?
  fi
  if [[ "$operation_status" == '0' ]]; then
    if controller_tun_matches "$desired" "$(read_state tun_stack)"; then
      :
    else
      operation_status=$?
    fi
  fi
  rmdir "$RUNTIME_ROOT/operation.lock"
  if [[ "$operation_status" != '0' ]]; then
    return "$operation_status"
  fi
  printf 'tun_preference=%s\n' "$desired"
  printf 'live_tun_matches_preference=true\n'
}

restore_tun() {
  if [[ "$(read_state risk_started)" != 'true' ]]; then
    log_line 'TUN restore skipped: no risk window was opened'
    return 0
  fi
  if [[ "$(read_state controller_verified)" != 'true' ]]; then
    log_line 'TUN restore skipped: controller was never verified'
    return 1
  fi
  if ! FLCLASH_PHASE1_ALLOW_DEFAULT_CONTROLLER=1 \
    FLCLASH_PHASE1_WATCHDOG_RUNTIME_ROOT="$RUNTIME_ROOT" \
    FLCLASH_PHASE1_WATCHDOG_RECOVERY=true \
    "$CORE_SCRIPT" set-tun "$(read_state tun_enable)" \
      --stack "$(read_state tun_stack)" >/dev/null; then
    return 1
  fi
  log_line 'live TUN restored and verified'
}

restore_tun_preference() {
  local desired
  local snapshot
  local current
  desired="$(read_state tun_enable)"
  snapshot="$(/usr/bin/swift "$STATE_SCRIPT")"
  current="$(value_from_snapshot "$snapshot" tun_preference)"
  require_bool tun_preference "$current"
  if [[ "$current" == "$desired" ]]; then
    log_line 'TUN preference already matches pre-test state'
    return 0
  fi

  set_enhanced true || return 1
  press_label_pair '仪表盘' 'Dashboard' || return 1
  sleep 1
  press_tun || return 1
  wait_for_preference tun_preference "$desired" || return 1
  sleep 3
  restore_tun || return 1
  log_line 'TUN preference restored and live state reverified'
}

restore_system_proxy() {
  local desired
  local snapshot
  local current
  desired="$(read_state system_proxy_preference)"
  snapshot="$(/usr/bin/swift "$STATE_SCRIPT")"
  current="$(value_from_snapshot "$snapshot" system_proxy_preference)"
  require_bool system_proxy_preference "$current"

  press_label_pair '仪表盘' 'Dashboard' || return 1
  sleep 1
  if [[ "$current" != "$desired" ]]; then
    press_system_proxy || return 1
    wait_for_preference system_proxy_preference "$desired" || return 1
    sleep 2
  fi

  if proxy_state_matches_original; then
    log_line 'system proxy preference and enable flags restored'
    return 0
  fi

  if [[ "$desired" == 'true' ]]; then
    snapshot="$(/usr/bin/swift "$STATE_SCRIPT")"
    current="$(value_from_snapshot "$snapshot" system_proxy_preference)"
    if [[ "$current" == 'true' ]]; then
      press_system_proxy || return 1
      wait_for_preference system_proxy_preference false || return 1
      sleep 2
    fi
    press_system_proxy || return 1
    wait_for_preference system_proxy_preference true || return 1
    sleep 3
  else
    return 1
  fi

  proxy_state_matches_original || return 1
  log_line 'system proxy preference and enable flags restored'
}

restore_external_controller() {
  local desired
  local snapshot
  local current
  desired="$(read_state external_controller_original)"
  snapshot="$(/usr/bin/swift "$STATE_SCRIPT")"
  current="$(value_from_snapshot "$snapshot" external_controller_preference)"
  require_bool external_controller_preference "$current"
  if [[ "$current" == "$desired" ]]; then
    log_line 'external controller preference already matches pre-test state'
    return 0
  fi

  set_enhanced true || return 1
  press_label_pair '工具' 'Tools' || return 1
  sleep 1
  if ! press_label_pair '外部控制器' 'External controller'; then
    press_label_pair '基本配置' 'Basic configuration' || return 1
    sleep 1
    press_label_pair '外部控制器' 'External controller' || return 1
  fi
  wait_for_preference external_controller_preference "$desired" || return 1
  sleep 2
  log_line 'external controller preference restored'
}

restore_ui_state() {
  /usr/bin/swift "$WINDOW_SCRIPT" show >/dev/null || return 1
  set_enhanced true || return 1
  restore_tun_preference || return 1
  restore_system_proxy || return 1
  restore_external_controller || return 1
  press_label_pair '仪表盘' 'Dashboard' || return 1
  sleep 1
  set_enhanced false || return 1
  /usr/bin/swift "$WINDOW_SCRIPT" show >/dev/null || return 1
  log_line 'window, page, and AX enhanced state restored'
}

clear_flclash_managed_proxies() {
  local service
  while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    [[ "$service" == \** ]] && continue
    [[ "$service" == 'An asterisk '* ]] && continue
    /usr/sbin/networksetup -setautoproxystate "$service" off >/dev/null 2>&1 || true
    /usr/sbin/networksetup -setwebproxystate "$service" off >/dev/null 2>&1 || true
    /usr/sbin/networksetup -setsecurewebproxystate "$service" off >/dev/null 2>&1 || true
    /usr/sbin/networksetup -setsocksfirewallproxystate "$service" off >/dev/null 2>&1 || true
  done < <(/usr/sbin/networksetup -listallnetworkservices 2>/dev/null)
  log_line 'fallback cleared FlClash-managed proxy enable flags'
}

terminate_exact_processes() {
  pkill -TERM -x FlClash >/dev/null 2>&1 || true
  pkill -TERM -x FlClashCore >/dev/null 2>&1 || true
  local attempt
  for attempt in $(seq 1 10); do
    if [[ "$(process_count FlClash)" == '0' \
       && "$(process_count FlClashCore)" == '0' ]]; then
      return 0
    fi
    sleep 0.5
  done
  pkill -KILL -x FlClash >/dev/null 2>&1 || true
  pkill -KILL -x FlClashCore >/dev/null 2>&1 || true
}

fallback_recovery() {
  terminate_exact_processes
  if [[ "$(read_state proxy_managed_by_flclash)" == 'true' ]]; then
    clear_flclash_managed_proxies
  fi
  if [[ "$(read_state app_was_running)" != 'true' ]]; then
    log_line 'recovery incomplete: pre-test app state was stopped; test processes remain stopped'
    return 1
  fi

  if [[ ! -d "$DEFAULT_APP_PATH" ]]; then
    log_line 'recovery incomplete: recorded app was running but the fixed app path is unavailable'
    return 1
  fi
  if ! /usr/bin/open -n "$DEFAULT_APP_PATH"; then
    log_line 'recovery incomplete: failed to reopen the recorded FlClash app'
    return 1
  fi

  local attempt
  for attempt in $(seq 1 120); do
    if [[ "$(process_count FlClash)" == '1' \
       && "$(process_count FlClashCore)" == '1' ]]; then
      break
    fi
    sleep 0.5
  done
  if [[ "$(process_count FlClash)" != '1' \
     || "$(process_count FlClashCore)" != '1' ]]; then
    log_line 'recovery incomplete: FlClash app reopened but app/core did not both become ready'
    return 1
  fi
  log_line 'fallback reopened FlClash app and core after clearing stale proxies'
  sleep 5

  local precise=true
  if [[ "$(read_state risk_started)" == 'true' ]] && ! restore_tun; then
    precise=false
    log_line 'fallback restart could not reverify live TUN'
  fi
  if [[ "$precise" == 'true' ]] && ! restore_ui_state; then
    precise=false
    log_line 'fallback restart could not restore UI or system proxy state'
  fi
  if [[ "$precise" == 'true' ]] && ! verify_recovery_state; then
    precise=false
    log_line 'fallback restart whitelist verification failed'
  fi
  if [[ "$precise" == 'true' ]]; then
    sleep 5
    if ! verify_recovery_state; then
      precise=false
      log_line 'fallback restart stability verification failed'
    fi
  fi
  if [[ "$precise" == 'true' ]]; then
    write_state recovery_complete true
    log_line 'recovery completed after restart: exact whitelist state restored; process identity changed'
    return 0
  fi

  log_line 'recovery incomplete after restart: app/core are running; manual state verification is required'
  return 1
}

leave_running_with_incomplete_cleanup() {
  set_enhanced false >/dev/null 2>&1 || true
  /usr/bin/swift "$WINDOW_SCRIPT" show >/dev/null 2>&1 || true
  write_state recovery_complete false
  log_line 'recovery incomplete: live TUN and proxy enable state are safe; app/core left running; UI cleanup requires manual verification'
  return 1
}

verify_recovery_state() {
  local state_snapshot
  local ax_snapshot
  state_snapshot="$(/usr/bin/swift "$STATE_SCRIPT")"
  ax_snapshot="$(/usr/bin/swift "$AX_SCRIPT" scan)"
  [[ "$(value_from_snapshot "$state_snapshot" tun_preference)" == "$(read_state tun_enable)" ]] \
    || return 1
  [[ "$(value_from_snapshot "$state_snapshot" tun_stack)" == "$(read_state tun_stack)" ]] \
    || return 1
  [[ "$(value_from_snapshot "$state_snapshot" external_controller_preference)" \
      == "$(read_state external_controller_original)" ]] || return 1
  [[ "$(value_from_snapshot "$state_snapshot" system_proxy_preference)" \
      == "$(read_state system_proxy_preference)" ]] || return 1
  [[ "$(value_from_snapshot "$state_snapshot" visible_window_count)" =~ ^[1-9][0-9]*$ ]] \
    || return 1
  [[ "$(value_from_snapshot "$ax_snapshot" enhanced_user_interface)" == 'false' ]] \
    || return 1
  proxy_state_matches_original || return 1
}

recover_now() {
  local dry_run="${1:-false}"
  if [[ ! -f "$RUNTIME_ROOT/tun_enable" ]]; then
    printf 'No armed Phase 1 network watchdog state found.\n' >&2
    exit 2
  fi
  if ! mkdir "$RUNTIME_ROOT/recovery.lock" >/dev/null 2>&1; then
    log_line 'recovery already in progress'
    return 0
  fi
  write_state recovery_requested true
  write_state recovery_started true

  local attempt
  for attempt in $(seq 1 60); do
    [[ ! -d "$RUNTIME_ROOT/operation.lock" ]] && break
    sleep 0.5
  done
  if [[ -d "$RUNTIME_ROOT/operation.lock" ]]; then
    log_line 'recovery operation lock did not clear within 30 seconds'
    write_state recovery_complete false
    fallback_recovery
    return 1
  fi

  if [[ "$dry_run" == 'true' ]]; then
    log_line 'dry-run recovery: would restore TUN, proxy, controller, window, and AX state'
    write_state recovery_complete dry_run
    return 0
  fi

  log_line 'recovery started'
  local network_safe=true
  local precise=true
  if ! restore_tun; then
    network_safe=false
    precise=false
    log_line 'live TUN restoration failed'
  fi
  if [[ "$network_safe" == 'true' ]] && ! restore_ui_state; then
    precise=false
    log_line 'UI or system proxy restoration failed'
    if ! proxy_state_matches_original; then
      network_safe=false
      log_line 'system proxy enable state is not safe after UI restoration failure'
    fi
  fi
  if [[ "$precise" == 'true' ]] && ! verify_recovery_state; then
    precise=false
    log_line 'post-recovery whitelist verification failed'
    if ! proxy_state_matches_original; then
      network_safe=false
      log_line 'system proxy enable state failed post-recovery verification'
    fi
  fi
  if [[ "$precise" == 'true' ]]; then
    sleep 5
    if ! verify_recovery_state; then
      precise=false
      log_line 'post-recovery stability verification failed'
      if ! proxy_state_matches_original; then
        network_safe=false
        log_line 'system proxy enable state failed stability verification'
      fi
    fi
  fi

  if [[ "$precise" == 'true' ]]; then
    write_state recovery_complete true
    log_line 'recovery completed: exact Phase 1 whitelist state restored'
    return 0
  fi

  if [[ "$network_safe" == 'true' ]]; then
    leave_running_with_incomplete_cleanup
    return 1
  fi

  write_state recovery_complete false
  if fallback_recovery; then
    return 0
  fi
  return 1
}

watch_loop() {
  local timeout_seconds="$1"
  local elapsed=0
  write_state watchdog.pid "$$"
  log_line 'persistent PTY worker started'
  printf 'armed=true pid=%s timeout=%s controller_verified=false\n' \
    "$$" "$timeout_seconds"
  while (( elapsed < timeout_seconds )); do
    if [[ -f "$RUNTIME_ROOT/disarmed" ]]; then
      log_line 'watchdog disarmed before timeout'
      return 0
    fi
    if [[ "$(read_state recovery_requested)" == 'true' ]]; then
      log_line 'worker accepted recovery request'
      local requested_status=0
      recover_now "${FLCLASH_PHASE1_DRY_RECOVERY:-false}" \
        || requested_status=$?
      return "$requested_status"
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  if [[ -f "$RUNTIME_ROOT/disarmed" ]]; then
    log_line 'watchdog disarmed at timeout boundary'
    return 0
  fi
  log_line 'timeout reached'
  local recovery_status=0
  recover_now "${FLCLASH_PHASE1_DRY_RECOVERY:-false}" || recovery_status=$?
  return "$recovery_status"
}

disarm_watchdog() {
  if [[ "$(read_state recovery_complete)" != 'true' ]]; then
    printf 'Refusing to disarm before exact recovery completes.\n' >&2
    exit 1
  fi
  write_state disarmed true
  log_line 'disarm requested after exact recovery'
  printf 'disarmed=true\n'
}

show_status() {
  if is_watchdog_alive; then
    printf 'armed=true pid=%s timeout=%s controller_verified=%s recovery_complete=%s\n' \
      "$(read_state watchdog.pid)" \
      "$(read_state timeout_seconds)" \
      "$(read_state controller_verified)" \
      "$(read_state recovery_complete)"
  else
    printf 'armed=false controller_verified=%s recovery_complete=%s\n' \
      "$(read_state controller_verified)" \
      "$(read_state recovery_complete)"
  fi
}

show_log() {
  if [[ ! -f "$RUNTIME_ROOT/watchdog.log" ]]; then
    printf 'No watchdog log is available.\n'
    return 0
  fi
  /usr/bin/sed -n '1,240p' "$RUNTIME_ROOT/watchdog.log"
}

self_test() {
  local self_test_root
  self_test_root="$(mktemp -d "${TMPDIR:-/tmp}/flclash-phase1-network-watchdog-test.XXXXXX")"
  chmod 700 "$self_test_root"
  printf '%s\n' true > "$self_test_root/tun_enable"
  chmod 600 "$self_test_root/tun_enable"
  FLCLASH_PHASE1_WATCHDOG_RUNTIME_ROOT="$self_test_root" \
    FLCLASH_PHASE1_DRY_RECOVERY=true \
    "$SCRIPT_PATH" _watch 1
  /usr/bin/grep -q 'timeout reached' "$self_test_root/watchdog.log"
  /usr/bin/grep -q 'dry-run recovery' "$self_test_root/watchdog.log"
  [[ "$(/usr/bin/stat -f '%Lp' "$self_test_root")" == '700' ]]
  [[ "$(/usr/bin/stat -f '%Lp' "$self_test_root/watchdog.log")" == '600' ]]
  rm -f "$self_test_root/tun_enable" \
    "$self_test_root/watchdog.log" \
    "$self_test_root/recovery_complete" \
    "$self_test_root/recovery_requested" \
    "$self_test_root/recovery_started" \
    "$self_test_root/watchdog.pid"
  rmdir "$self_test_root/recovery.lock"
  rmdir "$self_test_root"
  printf 'self_test=true timeout_path=true dry_recovery=true private_modes=true\n'
}

main() {
  local command="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$command" in
    arm)
      arm_watchdog "$@"
      ;;
    verify-controller)
      verify_controller
      ;;
    ready)
      require_ready
      ;;
    begin-risk)
      begin_risk
      ;;
    set-tun)
      controlled_set_tun "$@"
      ;;
    toggle-tun)
      controlled_toggle_tun "$@"
      ;;
    trigger-recovery)
      request_recovery
      ;;
    recover)
      request_recovery
      ;;
    disarm)
      disarm_watchdog
      ;;
    status)
      show_status
      ;;
    log)
      show_log
      ;;
    self-test)
      self_test
      ;;
    _watch)
      watch_loop "${1:?missing timeout}"
      ;;
    help|-h|--help|'')
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
