#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly DEFAULT_OUTPUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/evidence/phase1/macos-cpu"
readonly STATE_SNAPSHOT_SCRIPT="$SCRIPT_DIR/macos_flclash_state_snapshot.swift"
readonly XCODE_16_DEVELOPER_DIR='/Applications/Xcode_16.4.app/Contents/Developer'

usage() {
  cat <<'EOF'
Usage:
  macos_cpu_capture.sh --scenario A1 [options]

Options:
  --repetitions N   Repetitions (default: 3)
  --warmup SEC      Warm-up before every repetition (default: 120)
  --duration SEC    CPU sampling duration (default: 300)
  --interval SEC    Sampling interval (default: 1)
  --output-dir DIR  Sanitized output directory
  --traffic-pid PID Require this traffic generator process to remain alive
  --skip-stack      Do not run the 10-second `sample` hot-symbol count
  --dry-run         Validate state and print the planned capture only

This script is read-only. It never toggles TUN, proxy, tray title, or windows.
Manually establish the TEST_MATRIX state and arm macos_recovery_watchdog.sh
before running a scenario that may interrupt connectivity.
EOF
}

require_integer() {
  local name="$1"
  local value="$2"
  local minimum="$3"
  local maximum="$4"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < minimum || value > maximum )); then
    printf '%s must be an integer between %s and %s.\n' "$name" "$minimum" "$maximum" >&2
    exit 2
  fi
}

first_pid() {
  pgrep -x "$1" | head -n 1
}

process_snapshot() {
  local pid="$1"
  local cpu
  local threads
  cpu="$(/bin/ps -p "$pid" -o %cpu= | awk 'NF >= 1 { print $1 }')"
  threads="$(/bin/ps -M -p "$pid" | awk 'NR > 1 { count += 1 } END { print count + 0 }')"
  if [[ -n "$cpu" && "$threads" -gt 0 ]]; then
    printf '%s,%s\n' "$cpu" "$threads"
  fi
}

capture_flclash_state() {
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    DEVELOPER_DIR="$XCODE_16_DEVELOPER_DIR" \
    HOME="$HOME" \
    /usr/bin/xcrun swift "$STATE_SNAPSHOT_SCRIPT" com.follow.clash
}

state_value() {
  local snapshot="$1"
  local name="$2"
  printf '%s\n' "$snapshot" | awk -F= -v target="$name" '$1 == target { print $2; exit }'
}

validate_scenario_state() {
  local snapshot="$1"
  local expected_tun='true'
  local expected_title='false'
  local visible_window_count

  [[ "$scenario" == 'A1' ]] && expected_tun='false'
  [[ "$scenario" == 'A3' ]] && expected_title='true'

  if [[ "$(state_value "$snapshot" tun_preference)" != "$expected_tun" ]]; then
    printf 'Scenario %s requires tun_preference=%s.\n' "$scenario" "$expected_tun" >&2
    return 1
  fi
  if [[ "$(state_value "$snapshot" show_tray_title)" != "$expected_title" ]]; then
    printf 'Scenario %s requires show_tray_title=%s.\n' "$scenario" "$expected_title" >&2
    return 1
  fi

  visible_window_count="$(state_value "$snapshot" visible_window_count)"
  if [[ "$scenario" == 'A4' ]]; then
    if [[ ! "$visible_window_count" =~ ^[1-9][0-9]*$ ]]; then
      printf 'Scenario A4 requires a visible FlClash window.\n' >&2
      return 1
    fi
  elif [[ "$visible_window_count" != '0' ]]; then
    printf 'Scenario %s requires the FlClash window to be hidden.\n' "$scenario" >&2
    return 1
  fi
}

append_stack_counts() {
  local pid="$1"
  local output_file="$2"
  local raw_file="$3"

  if ! sample "$pid" 10 -file "$raw_file" >/dev/null 2>&1; then
    printf '%s\n' '- stack_sample: failed' >> "$output_file"
    return 0
  fi

  printf '%s\n' '- stack_sample: completed' >> "$output_file"
  local symbol
  for symbol in \
    '_updateReplicants' \
    '_redrawReplicantSnapshot' \
    'NSStatusItem' \
    'MethodChannel' \
    'PlatformDispatcher'; do
    local count
    count="$(LC_ALL=C grep -c "$symbol" "$raw_file" 2>/dev/null || true)"
    printf '  - %s: %s\n' "$symbol" "$count" >> "$output_file"
  done

  rm -f "$raw_file"
}

scenario=''
repetitions='3'
warmup_seconds='120'
duration_seconds='300'
interval_seconds='1'
output_dir="$DEFAULT_OUTPUT_DIR"
skip_stack='0'
dry_run='0'
traffic_pid=''

while (( $# > 0 )); do
  case "$1" in
    --scenario)
      scenario="${2:-}"
      shift 2
      ;;
    --repetitions)
      repetitions="${2:-}"
      shift 2
      ;;
    --warmup)
      warmup_seconds="${2:-}"
      shift 2
      ;;
    --duration)
      duration_seconds="${2:-}"
      shift 2
      ;;
    --interval)
      interval_seconds="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --traffic-pid)
      traffic_pid="${2:-}"
      shift 2
      ;;
    --skip-stack)
      skip_stack='1'
      shift
      ;;
    --dry-run)
      dry_run='1'
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$scenario" =~ ^A[1-7]$ ]]; then
  printf 'Scenario must be one of A1 through A7.\n' >&2
  exit 2
fi

require_integer repetitions "$repetitions" 1 10
require_integer warmup "$warmup_seconds" 0 3600
require_integer duration "$duration_seconds" 5 3600
require_integer interval "$interval_seconds" 1 60
if [[ -n "$traffic_pid" ]]; then
  require_integer traffic-pid "$traffic_pid" 1 2147483647
  if ! kill -0 "$traffic_pid" >/dev/null 2>&1; then
    printf 'Required traffic generator process is not running.\n' >&2
    exit 1
  fi
fi

main_pid="$(first_pid FlClash || true)"
core_pid="$(first_pid FlClashCore || true)"
if [[ -z "$main_pid" || -z "$core_pid" ]]; then
  printf 'FlClash and FlClashCore must both be running before capture.\n' >&2
  exit 1
fi

state_before="$(capture_flclash_state)"
validate_scenario_state "$state_before"

if [[ "$dry_run" == '1' ]]; then
  printf 'dry-run scenario=%s repetitions=%s warmup=%ss duration=%ss interval=%ss main=running core=running traffic_required=%s\n' \
    "$scenario" "$repetitions" "$warmup_seconds" "$duration_seconds" "$interval_seconds" "$([[ -n "$traffic_pid" ]] && printf true || printf false)"
  exit 0
fi

mkdir -p "$output_dir"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
prefix="$output_dir/${scenario}-${timestamp}"
csv_file="${prefix}.csv"
summary_file="${prefix}.md"
runtime_dir="${TMPDIR:-/tmp}/flclash-cpu-capture-${UID}-$$"
mkdir -p "$runtime_dir"
chmod 700 "$runtime_dir"
trap 'rm -f "$runtime_dir"/* 2>/dev/null || true; rmdir "$runtime_dir" 2>/dev/null || true' EXIT

printf '%s\n' 'repetition,second,main_cpu,main_threads,core_cpu,core_threads' > "$csv_file"
cat > "$summary_file" <<EOF
# macOS CPU capture: $scenario

- captured_at_utc: $timestamp
- os_version: $(sw_vers -productVersion)
- os_build: $(sw_vers -buildVersion)
- architecture: $(uname -m)
- repetitions: $repetitions
- warmup_seconds: $warmup_seconds
- duration_seconds: $duration_seconds
- interval_seconds: $interval_seconds
- traffic_process_required: $([[ -n "$traffic_pid" ]] && printf true || printf false)
- state_control: validated before capture; this script made no network or UI changes
- state_before:
$(printf '%s\n' "$state_before" | sed 's/^/  - /')

EOF

rep='1'
while (( rep <= repetitions )); do
  printf 'Scenario %s repetition %s/%s: warm-up %ss.\n' "$scenario" "$rep" "$repetitions" "$warmup_seconds"
  if (( warmup_seconds > 0 )); then
    sleep "$warmup_seconds"
  fi

  current_main_pid="$(first_pid FlClash || true)"
  current_core_pid="$(first_pid FlClashCore || true)"
  if [[ "$current_main_pid" != "$main_pid" || "$current_core_pid" != "$core_pid" ]]; then
    printf 'Process identity changed before repetition %s; aborting capture.\n' "$rep" >&2
    exit 1
  fi
  if [[ -n "$traffic_pid" ]] && ! kill -0 "$traffic_pid" >/dev/null 2>&1; then
    printf 'Traffic generator exited before repetition %s; aborting capture.\n' "$rep" >&2
    exit 1
  fi
  validate_scenario_state "$(capture_flclash_state)"

  second='0'
  while (( second < duration_seconds )); do
    if ! kill -0 "$main_pid" >/dev/null 2>&1 || ! kill -0 "$core_pid" >/dev/null 2>&1; then
      printf 'FlClash process exited during repetition %s.\n' "$rep" >&2
      exit 1
    fi
    if [[ -n "$traffic_pid" ]] && ! kill -0 "$traffic_pid" >/dev/null 2>&1; then
      printf 'Traffic generator exited during repetition %s.\n' "$rep" >&2
      exit 1
    fi

    main_values="$(process_snapshot "$main_pid")"
    core_values="$(process_snapshot "$core_pid")"
    if [[ -z "$main_values" || -z "$core_values" ]]; then
      printf 'Could not read process CPU during repetition %s.\n' "$rep" >&2
      exit 1
    fi
    printf '%s,%s,%s,%s\n' "$rep" "$second" "$main_values" "$core_values" >> "$csv_file"
    sleep "$interval_seconds"
    second=$((second + interval_seconds))
  done

  printf '## Repetition %s\n\n' "$rep" >> "$summary_file"
  awk -F, -v target="$rep" '
    NR > 1 && $1 == target {
      main_sum += $3; core_sum += $5; count += 1;
      if ($3 > main_max) main_max = $3;
      if ($5 > core_max) core_max = $5;
    }
    END {
      if (count > 0) {
        printf "- main_cpu_mean: %.3f\n", main_sum / count;
        printf "- main_cpu_max: %.3f\n", main_max;
        printf "- core_cpu_mean: %.3f\n", core_sum / count;
        printf "- core_cpu_max: %.3f\n", core_max;
      }
    }
  ' "$csv_file" >> "$summary_file"

  if [[ "$skip_stack" == '0' ]]; then
    append_stack_counts "$main_pid" "$summary_file" "$runtime_dir/main-${rep}.sample"
  else
    printf '%s\n' '- stack_sample: skipped' >> "$summary_file"
  fi
  printf '\n' >> "$summary_file"

  rep=$((rep + 1))
done

state_after="$(capture_flclash_state)"
validate_scenario_state "$state_after"

cat >> "$summary_file" <<EOF
## Overall

$(awk -F, '
  NR > 1 {
    main_sum += $3; core_sum += $5; count += 1;
    if ($3 > main_max) main_max = $3;
    if ($5 > core_max) core_max = $5;
  }
  END {
    if (count > 0) {
      printf "- main_cpu_mean: %.3f\n", main_sum / count;
      printf "- main_cpu_max: %.3f\n", main_max;
      printf "- core_cpu_mean: %.3f\n", core_sum / count;
      printf "- core_cpu_max: %.3f\n", core_max;
    }
  }
' "$csv_file")

## State after

$(printf '%s\n' "$state_after" | sed 's/^/- /')
EOF

printf 'Capture complete:\n  %s\n  %s\n' "$csv_file" "$summary_file"
