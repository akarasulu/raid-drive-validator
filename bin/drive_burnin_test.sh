#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091
# shellcheck source=../lib/scoring.sh
source "$ROOT_DIR/lib/scoring.sh"
DRIVE_REPORT_GENERATOR="$ROOT_DIR/tools/generate_drive_markdown_report.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --device /dev/sdX [options]

Options:
  --device DEV           Block device to test (required)
  --report-dir DIR       Directory for logs and reports (default: ./drive_test_reports)
  --stress               Enable optional thermal/mechanical stress pass
  --state-dir DIR        Directory for live state files (default: REPORT_DIR/state)
  --step-timeout-max SEC Stop any single step after SEC seconds for smoke testing
  --help                 Show this help

This script is destructive. It will overwrite the target device.
USAGE
}

DEVICE=""
REPORT_DIR="$PWD/drive_test_reports"
STATE_DIR=""
ENABLE_STRESS=0
STEP_TIMEOUT_MAX=0
STEP_DEADLINE_EPOCH=0
TIMED_OUT_STEPS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE=${2:?}; shift 2 ;;
    --report-dir) REPORT_DIR=${2:?}; shift 2 ;;
    --state-dir) STATE_DIR=${2:?}; shift 2 ;;
    --stress) ENABLE_STRESS=1; shift ;;
    --step-timeout-max) STEP_TIMEOUT_MAX=${2:?}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$DEVICE" ]] || { usage; exit 1; }
[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device"
[[ $STEP_TIMEOUT_MAX =~ ^[0-9]+$ ]] || die '--step-timeout-max must be an integer number of seconds'
require_root
require_tools smartctl badblocks fio lsblk awk grep sed dmesg dd blockdev timeout

mkdir -p "$REPORT_DIR"
STATE_DIR=${STATE_DIR:-$REPORT_DIR/state}
mkdir -p "$STATE_DIR"

DEVICE_BASENAME=$(basename -- "$DEVICE")
REPORT_FILE="$REPORT_DIR/${DEVICE_BASENAME}_report.txt"
JSON_FILE="$REPORT_DIR/${DEVICE_BASENAME}_summary.json"
STATE_FILE="$STATE_DIR/${DEVICE_BASENAME}.state"
DMESG_FILE="$REPORT_DIR/${DEVICE_BASENAME}_dmesg.txt"
LAT_FILE="$REPORT_DIR/${DEVICE_BASENAME}_latency.log"
BADBLOCKS_FILE="$REPORT_DIR/${DEVICE_BASENAME}_badblocks.log"
DMESG_BEFORE_FILE=""
DMESG_AFTER_FILE=""
SELFTEST_LOG_BASELINE_FILE=""

report() { printf '%s %s\n' "$(timestamp)" "$*" | tee -a "$REPORT_FILE"; }
set_state() {
  local stage=$1 message=${2:-}
  printf 'stage=%s\nupdated=%s\nmessage=%s\n' "$stage" "$(timestamp)" "$message" > "$STATE_FILE"
}

record_timed_out_step() {
  local stage=$1
  TIMED_OUT_STEPS+=("$stage")
  set_state timeout "${stage} timed out; continuing in smoke-test mode"
  report "${stage} timed out; continuing in smoke-test mode"
}

log_timeout_notice() {
  printf '%s %s\n' "$(timestamp)" "$*" | tee -a "$REPORT_FILE" >&2
}

smartctl_exit_is_fatal() {
  local rc=$1
  (( rc == 124 )) && return 0
  (( (rc & 0x07) != 0 ))
}

remaining_step_budget() {
  local now remaining

  if (( STEP_DEADLINE_EPOCH == 0 )); then
    printf '0\n'
    return 0
  fi

  now=$(date +%s)
  remaining=$((STEP_DEADLINE_EPOCH - now))
  if (( remaining > 0 )); then
    printf '%s\n' "$remaining"
  else
    printf '0\n'
  fi
}

start_step_budget() {
  if (( STEP_TIMEOUT_MAX > 0 )); then
    STEP_DEADLINE_EPOCH=$(( $(date +%s) + STEP_TIMEOUT_MAX ))
  else
    STEP_DEADLINE_EPOCH=0
  fi
}

clear_step_budget() {
  STEP_DEADLINE_EPOCH=0
}

run_with_step_timeout() {
  local stage=$1
  shift
  local remaining

  if (( STEP_TIMEOUT_MAX == 0 )); then
    "$@"
    return 0
  fi

  if (( STEP_DEADLINE_EPOCH > 0 )); then
    remaining=$(remaining_step_budget)
  else
    remaining=$STEP_TIMEOUT_MAX
  fi

  if (( remaining <= 0 )); then
    log_timeout_notice "Per-step timeout reached before ${stage}"
    return 124
  fi

  log_timeout_notice "Per-step timeout before ${stage}: ${remaining}s"
  timeout --foreground "${remaining}s" "$@"
}

run_with_step_timeout_capture() {
  local stage=$1
  shift
  local remaining

  if (( STEP_TIMEOUT_MAX == 0 )); then
    "$@"
    return 0
  fi

  if (( STEP_DEADLINE_EPOCH > 0 )); then
    remaining=$(remaining_step_budget)
  else
    remaining=$STEP_TIMEOUT_MAX
  fi

  if (( remaining <= 0 )); then
    log_timeout_notice "Per-step timeout reached before ${stage}"
    return 124
  fi

  timeout --foreground "${remaining}s" "$@"
}

run_with_step_timeout_capture_quiet() {
  local stage=$1
  shift
  local remaining

  if (( STEP_TIMEOUT_MAX == 0 )); then
    "$@"
    return 0
  fi

  if (( STEP_DEADLINE_EPOCH > 0 )); then
    remaining=$(remaining_step_budget)
  else
    remaining=$STEP_TIMEOUT_MAX
  fi

  if (( remaining <= 0 )); then
    return 124
  fi

  timeout --foreground "${remaining}s" "$@"
}

log_step_budget_notice() {
  local stage=$1
  local remaining

  if (( STEP_TIMEOUT_MAX == 0 )); then
    return 0
  fi

  if (( STEP_DEADLINE_EPOCH > 0 )); then
    remaining=$(remaining_step_budget)
  else
    remaining=$STEP_TIMEOUT_MAX
  fi

  if (( remaining <= 0 )); then
    log_timeout_notice "Per-step timeout reached before ${stage}"
  else
    log_timeout_notice "Per-step timeout before ${stage}: ${remaining}s"
  fi
}

run_smartctl_info() {
  local stage=$1
  shift
  local output rc

  log_step_budget_notice "$stage"
  output=$(run_with_step_timeout_capture "$stage" smartctl "$@" "$DEVICE" 2>&1)
  rc=$?
  printf '%s\n' "$output" | tee -a "$REPORT_FILE"

  if (( rc == 124 )); then
    return 124
  fi
  if smartctl_exit_is_fatal "$rc"; then
    return "$rc"
  fi
  return 0
}

capture_smartctl_info() {
  local stage=$1
  shift
  local output rc

  log_step_budget_notice "$stage"
  output=$(run_with_step_timeout_capture "$stage" smartctl "$@" "$DEVICE" 2>&1)
  rc=$?

  if (( rc == 124 )); then
    return 124
  fi
  if smartctl_exit_is_fatal "$rc"; then
    return "$rc"
  fi

  printf '%s\n' "$output"
}

capture_smartctl_info_quiet() {
  local stage=$1
  shift
  local output rc

  output=$(run_with_step_timeout_capture_quiet "$stage" smartctl "$@" "$DEVICE" 2>&1)
  rc=$?

  if (( rc == 124 )); then
    return 124
  fi
  if smartctl_exit_is_fatal "$rc"; then
    return "$rc"
  fi

  printf '%s\n' "$output"
}

collect_smart_value() {
  local attr=$1
  smartctl -A "$DEVICE" 2>/dev/null | awk -v a="$attr" '$0 ~ a {print $10; found=1} END{if(!found) print "NA"}'
}

collect_temperature() {
  local t
  t=$(smartctl -A "$DEVICE" 2>/dev/null | awk '/Temperature_Celsius|Airflow_Temperature_Cel|Current_Drive_Temperature/ {print $10; exit}')
  [[ -n "$t" ]] && printf '%s\n' "$t" || printf 'NA\n'
}

smart_health() {
  header "SMART health" | tee -a "$REPORT_FILE"
  set_state smart_health "Running SMART overall health check"
  run_smartctl_info "SMART health" -H
}

smart_attributes() {
  local label=${1:-SMART attributes}
  header "$label" | tee -a "$REPORT_FILE"
  set_state smart_attributes "$label"
  run_smartctl_info "$label" -A
}

smart_selftest_status_snapshot() {
  capture_smartctl_info_quiet "SMART self-test status query" -c
}

smart_selftest_log_snapshot() {
  capture_smartctl_info_quiet "SMART self-test log query" -l selftest
}

snapshot_selftest_log() {
  local target=$1
  smart_selftest_log_snapshot > "$target" 2>/dev/null || : > "$target"
}

report_new_selftest_log_entries() {
  local label=$1 before=$2 after=$3
  local delta
  delta=$(python3 - "$before" "$after" <<'PY'
import pathlib
import re
import sys

before = pathlib.Path(sys.argv[1]).read_text()
after = pathlib.Path(sys.argv[2]).read_text()

entry_re = re.compile(r'^#\s*\d+.*$', re.M)
before_entries = entry_re.findall(before)
after_entries = entry_re.findall(after)

def normalize(entry: str) -> str:
    return re.sub(r'^#\s*\d+\s+', '', entry).strip()

if not after_entries:
    raise SystemExit(0)

if before_entries:
    before_set = {normalize(entry) for entry in before_entries}
    new_entries = []
    for entry in after_entries:
        if normalize(entry) in before_set:
            break
        new_entries.append(entry)
else:
    new_entries = after_entries

if new_entries:
    print("\n".join(new_entries))
PY
)

  header "SMART ${label} self-test new log entries" | tee -a "$REPORT_FILE"
  if [[ -n "$delta" ]]; then
    printf '%s\n' "$delta" | tee -a "$REPORT_FILE"
  else
    echo "No new SMART self-test log entries captured for this phase." | tee -a "$REPORT_FILE"
  fi
}

finalize_selftest_phase_log() {
  local kind=$1
  local selftest_log_after

  selftest_log_after=$(mktemp)
  snapshot_selftest_log "$selftest_log_after"
  report_new_selftest_log_entries "$kind" "$SELFTEST_LOG_BASELINE_FILE" "$selftest_log_after"
  cp "$selftest_log_after" "$SELFTEST_LOG_BASELINE_FILE"
  rm -f -- "$selftest_log_after"
}

selftest_in_progress() {
  grep -qiE 'self-test routine in progress|in progress' <<< "$1"
}

selftest_remaining_percent() {
  sed -nE 's/.* ([0-9]+)% of test remaining.*/\1/p' <<< "$1" | head -n 1
}

selftest_log_remaining_percent() {
  awk '
    /^# 1 / {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+%$/) {
          gsub(/%/, "", $i)
          print $i
          exit
        }
      }
    }
  ' <<< "$1"
}

selftest_wait_minutes() {
  sed -nE 's/Please wait ([0-9]+) minutes? for test to complete\./\1/p' <<< "$1" | head -n 1
}

selftest_completion_eta() {
  sed -nE 's/Test will complete after (.*)/\1/p' <<< "$1" | head -n 1
}

selftest_poll_interval() {
  local wait_minutes=${1:-0}
  if (( wait_minutes <= 2 )); then
    printf '5\n'
  elif (( wait_minutes <= 15 )); then
    printf '15\n'
  elif (( wait_minutes <= 60 )); then
    printf '30\n'
  else
    printf '60\n'
  fi
}

render_progress_bar() {
  local percent_complete=$1 width=24 filled empty
  (( percent_complete < 0 )) && percent_complete=0
  (( percent_complete > 100 )) && percent_complete=100
  filled=$((percent_complete * width / 100))
  empty=$((width - filled))
  printf '['
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' "$empty" '' | tr ' ' '.'
  printf ']'
}

show_progress_update() {
  local label=$1 percent_complete=$2 remaining_percent=$3 eta=$4
  local bar line
  bar=$(render_progress_bar "$percent_complete")
  line="${label} ${bar} ${percent_complete}%% complete"
  [[ -n "$remaining_percent" ]] && line="${line} (${remaining_percent}%% remaining)"
  [[ -n "$eta" ]] && line="${line} ETA ${eta}"

  if [[ -t 1 ]]; then
    printf '\r\033[2K%s' "$line"
  else
    report "$line"
  fi
}

finish_progress_line() {
  if [[ -t 1 ]]; then
    printf '\r\033[2K'
  fi
}

run_stage_with_progress_cleanup() {
  local stage=$1
  shift
  finish_progress_line
  run_stage "$stage" "$@"
}

handle_stage_result() {
  local stage=$1 rc=$2
  if (( rc == 124 )) && (( STEP_TIMEOUT_MAX > 0 )); then
    record_timed_out_step "$stage"
    return 0
  fi
  return "$rc"
}

abort_running_selftest_if_any() {
  local snapshot
  snapshot=$(smart_selftest_status_snapshot || true)
  if selftest_in_progress "$snapshot"; then
    report "Aborting pre-existing SMART self-test before starting a new one"
    printf '%s\n' "$snapshot" | tee -a "$REPORT_FILE"
    run_smartctl_info "SMART self-test abort" -X
  fi
}

run_selftest() {
  local kind=$1
  local start_output wait_minutes eta poll_interval status_output status_rc remaining_percent percent_complete log_output
  header "SMART ${kind} self-test" | tee -a "$REPORT_FILE"
  start_step_budget
  abort_running_selftest_if_any
  set_state "smart_${kind}" "Starting SMART ${kind} self-test"
  start_output=$(capture_smartctl_info "SMART ${kind} self-test start" -t "$kind") || {
    rc=$?
    clear_step_budget
    return "$rc"
  }
  printf '%s\n' "$start_output" | tee -a "$REPORT_FILE"

  if grep -qi "Can't start self-test without aborting current test" <<< "$start_output"; then
    report "SMART reported an in-progress test during start; aborting and retrying once"
    run_smartctl_info "SMART self-test abort" -X
    start_output=$(capture_smartctl_info "SMART ${kind} self-test restart" -t "$kind") || {
      rc=$?
      clear_step_budget
      return "$rc"
    }
    printf '%s\n' "$start_output" | tee -a "$REPORT_FILE"
  fi

  wait_minutes=$(selftest_wait_minutes "$start_output")
  eta=$(selftest_completion_eta "$start_output")
  poll_interval=$(selftest_poll_interval "${wait_minutes:-0}")
  [[ -n "$wait_minutes" ]] && report "SMART ${kind} self-test estimated duration: ${wait_minutes} minute(s)"
  [[ -n "$eta" ]] && report "SMART ${kind} self-test expected completion: ${eta}"
  report "Polling SMART ${kind} self-test status every ${poll_interval}s"

  while true; do
    status_output=$(smart_selftest_status_snapshot 2>&1)
    status_rc=$?
    if (( status_rc != 0 )); then
      finish_progress_line
      clear_step_budget
      handle_stage_result "SMART ${kind} self-test status query" "$status_rc"
      return $?
    fi
    if selftest_in_progress "$status_output"; then
      remaining_percent=$(selftest_remaining_percent "$status_output")
      if [[ -z "$remaining_percent" ]]; then
        log_output=$(smart_selftest_log_snapshot || true)
        remaining_percent=$(selftest_log_remaining_percent "$log_output")
      fi
      if [[ -n "$remaining_percent" ]]; then
        percent_complete=$((100 - remaining_percent))
        set_state "smart_${kind}" "SMART ${kind} self-test ${percent_complete}% complete"
        show_progress_update "SMART ${kind}" "$percent_complete" "$remaining_percent" "$eta"
      else
        set_state "smart_${kind}" "SMART ${kind} self-test still in progress"
        report "SMART ${kind} self-test still in progress"
      fi
    else
      break
    fi
    run_with_step_timeout "SMART ${kind} self-test polling wait" sleep "$poll_interval"
    rc=$?
    if (( rc != 0 )); then
      finish_progress_line
      clear_step_budget
      finalize_selftest_phase_log "$kind"
      handle_stage_result "SMART ${kind} self-test polling wait" "$rc"
      return $?
    fi
  done
  finish_progress_line
  clear_step_budget
  finalize_selftest_phase_log "$kind"
  handle_stage_result "SMART ${kind} self-test log" 0
}

smart_selftests() {
  local kind
  for kind in short long; do
    run_selftest "$kind" || return $?
  done
}

run_stage() {
  local stage=$1
  shift
  "$@"
  rc=$?
  handle_stage_result "$stage" "$rc"
}

main() {
  : > "$REPORT_FILE"
  report "Starting destructive qualification for $DEVICE"
  if (( STEP_TIMEOUT_MAX > 0 )); then
    report "Per-step timeout enabled: ${STEP_TIMEOUT_MAX}s"
  fi
  lsblk -d -o NAME,SIZE,MODEL,SERIAL,VENDOR "$DEVICE" | tee -a "$REPORT_FILE"
  DMESG_BEFORE_FILE=$(mktemp)
  DMESG_AFTER_FILE=$(mktemp)
  SELFTEST_LOG_BASELINE_FILE=$(mktemp)
  trap cleanup_temp_files EXIT
  snapshot_dmesg "$DMESG_BEFORE_FILE"
  snapshot_selftest_log "$SELFTEST_LOG_BASELINE_FILE"
  run_stage_with_progress_cleanup "SMART health" smart_health || return $?
  run_stage_with_progress_cleanup "SMART attributes before testing" smart_attributes "SMART attributes before testing" || return $?
  run_stage_with_progress_cleanup "SMART self-tests" smart_selftests || return $?
  run_stage_with_progress_cleanup "destructive surface test" surface_test || return $?
  run_stage_with_progress_cleanup "latency variance detection" latency_test || return $?
  if [[ $ENABLE_STRESS -eq 1 ]]; then
    run_stage_with_progress_cleanup "optional thermal/mechanical stress" stress_test || return $?
  fi
  run_stage_with_progress_cleanup "SMART attributes after testing" smart_attributes "SMART attributes after testing" || return $?
  snapshot_dmesg "$DMESG_AFTER_FILE"
  cp "$DMESG_AFTER_FILE" "$DMESG_FILE"
  kernel_error_check "$DMESG_BEFORE_FILE" "$DMESG_AFTER_FILE"
  evaluate
  if [[ ${#TIMED_OUT_STEPS[@]} -gt 0 ]]; then
    report "Timed out steps: ${TIMED_OUT_STEPS[*]}"
  fi
  set_state complete "Testing complete"
  generate_drive_markdown_report
  report "Completed destructive qualification for $DEVICE"
}

snapshot_dmesg() {
  dmesg -T > "$1" || true
}

cleanup_temp_files() {
  local path
  for path in "$DMESG_BEFORE_FILE" "$DMESG_AFTER_FILE" "$SELFTEST_LOG_BASELINE_FILE"; do
    [[ -n "$path" ]] || continue
    rm -f -- "$path"
  done
}

kernel_error_check() {
  local before=$1 after=$2
  header "Kernel log delta" | tee -a "$REPORT_FILE"
  set_state kernel_logs "Inspecting kernel log delta"
  if command -v diff >/dev/null 2>&1; then
    diff -u "$before" "$after" | grep -Ei 'error|reset|timeout|fail|I/O|exception|crc|abort|medium' | tee -a "$REPORT_FILE" || true
  else
    grep -Ei 'error|reset|timeout|fail|I/O|exception|crc|abort|medium' "$after" | tee -a "$REPORT_FILE" || true
  fi
}

surface_test() {
  header "Destructive surface test" | tee -a "$REPORT_FILE"
  set_state badblocks "Running destructive badblocks burn-in"
  run_with_step_timeout "destructive surface test" badblocks -b 4096 -wsv "$DEVICE" 2>&1 | tee "$BADBLOCKS_FILE" | tee -a "$REPORT_FILE"
}

latency_test() {
  header "Latency variance detection" | tee -a "$REPORT_FILE"
  set_state latency "Running fio random-read latency test"
  run_with_step_timeout "latency variance detection" fio \
    --name="latency-${DEVICE_BASENAME}" \
    --filename="$DEVICE" \
    --direct=1 \
    --rw=randread \
    --bs=4k \
    --iodepth=16 \
    --runtime=120 \
    --time_based=1 \
    --ioengine=libaio \
    --group_reporting=1 \
    --output-format=json \
    --output="$LAT_FILE"
  cat "$LAT_FILE" >> "$REPORT_FILE"
}

stress_test() {
  header "Optional thermal/mechanical stress" | tee -a "$REPORT_FILE"
  set_state stress "Streaming read/write/read stress passes"
  run_with_step_timeout "stress read pass 1" dd if="$DEVICE" of=/dev/null bs=16M iflag=direct status=progress 2>&1 | tee -a "$REPORT_FILE"
  run_with_step_timeout "stress write pass" dd if=/dev/zero of="$DEVICE" bs=16M oflag=direct status=progress 2>&1 | tee -a "$REPORT_FILE"
  run_with_step_timeout "stress read pass 2" dd if="$DEVICE" of=/dev/null bs=16M iflag=direct status=progress 2>&1 | tee -a "$REPORT_FILE"
}

evaluate() {
  header "Evaluation" | tee -a "$REPORT_FILE"
  set_state evaluate "Computing reliability score"

  local realloc pending uncorr crc temp score verdict reasons latency_p99_ms latency_mean_ms throughput_mib
  local qualification_status smoke_note timed_out_steps_json
  realloc=$(collect_smart_value 'Reallocated_Sector_Ct')
  pending=$(collect_smart_value 'Current_Pending_Sector')
  uncorr=$(collect_smart_value 'Offline_Uncorrectable')
  crc=$(collect_smart_value 'UDMA_CRC_Error_Count')
  temp=$(collect_temperature)

  latency_p99_ms=$(latency_p99_from_fio_json "$LAT_FILE")
  latency_mean_ms=$(latency_mean_from_fio_json "$LAT_FILE")
  throughput_mib=$(latency_bw_mib_from_fio_json "$LAT_FILE")

  score=$(compute_reliability_score \
    "$realloc" "$pending" "$uncorr" "$crc" "$temp" "$latency_p99_ms" "$latency_mean_ms")
  verdict=$(score_to_verdict "$score")
  reasons=$(score_to_reason_text \
    "$realloc" "$pending" "$uncorr" "$crc" "$temp" "$latency_p99_ms" "$latency_mean_ms")

  qualification_status=complete
  smoke_note=""
  timed_out_steps_json="[]"
  if [[ ${#TIMED_OUT_STEPS[@]} -gt 0 ]]; then
    qualification_status=incomplete
    (( score > 69 )) && score=69
    verdict=REVIEW
    smoke_note="qualification incomplete due to timed out stages"
    if [[ "$reasons" == "no significant reliability concerns detected" ]]; then
      reasons="$smoke_note"
    else
      reasons="$reasons; $smoke_note"
    fi
    timed_out_steps_json=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "${TIMED_OUT_STEPS[@]}")
  fi

  {
    printf 'device: %s\n' "$DEVICE"
    printf 'qualification_status: %s\n' "$qualification_status"
    printf 'temperature_c: %s\n' "$temp"
    printf 'reallocated: %s\n' "$realloc"
    printf 'pending: %s\n' "$pending"
    printf 'uncorrectable: %s\n' "$uncorr"
    printf 'crc_errors: %s\n' "$crc"
    printf 'latency_mean_ms: %s\n' "$latency_mean_ms"
    printf 'latency_p99_ms: %s\n' "$latency_p99_ms"
    printf 'throughput_mib_s: %s\n' "$throughput_mib"
    printf 'reliability_score: %s\n' "$score"
    printf 'verdict: %s\n' "$verdict"
    printf 'notes: %s\n' "$reasons"
  } | tee -a "$REPORT_FILE"

  cat > "$JSON_FILE" <<JSON
{
  "device": "${DEVICE}",
  "qualification_status": "${qualification_status}",
  "temperature_c": "${temp}",
  "reallocated": "${realloc}",
  "pending": "${pending}",
  "uncorrectable": "${uncorr}",
  "crc_errors": "${crc}",
  "latency_mean_ms": "${latency_mean_ms}",
  "latency_p99_ms": "${latency_p99_ms}",
  "throughput_mib_s": "${throughput_mib}",
  "reliability_score": "${score}",
  "verdict": "${verdict}",
  "notes": "$(printf '%s' "$reasons" | sed 's/"/\\"/g')",
  "timed_out_steps": ${timed_out_steps_json}
}
JSON
}

generate_drive_markdown_report() {
  if [[ -x "$DRIVE_REPORT_GENERATOR" ]]; then
    "$DRIVE_REPORT_GENERATOR" --report-dir "$REPORT_DIR" --device "$DEVICE" || \
      report "Drive markdown report generation failed for $DEVICE"
  fi
}

if ! main; then
  rc=$?
  if (( rc == 124 )); then
    report "Run stopped after exceeding the configured per-step timeout"
  fi
  exit "$rc"
fi
