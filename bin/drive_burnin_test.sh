#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=../lib/scoring.sh
source "$ROOT_DIR/lib/scoring.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --device /dev/sdX [options]

Options:
  --device DEV           Block device to test (required)
  --report-dir DIR       Directory for logs and reports (default: ./drive_test_reports)
  --stress               Enable optional thermal/mechanical stress pass
  --state-dir DIR        Directory for live state files (default: REPORT_DIR/state)
  --help                 Show this help

This script is destructive. It will overwrite the target device.
USAGE
}

DEVICE=""
REPORT_DIR="$PWD/drive_test_reports"
STATE_DIR=""
ENABLE_STRESS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE=${2:?}; shift 2 ;;
    --report-dir) REPORT_DIR=${2:?}; shift 2 ;;
    --state-dir) STATE_DIR=${2:?}; shift 2 ;;
    --stress) ENABLE_STRESS=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$DEVICE" ]] || { usage; exit 1; }
[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device"
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

report() { printf '%s %s\n' "$(timestamp)" "$*" | tee -a "$REPORT_FILE"; }
set_state() {
  local stage=$1 message=${2:-}
  printf 'stage=%s\nupdated=%s\nmessage=%s\n' "$stage" "$(timestamp)" "$message" > "$STATE_FILE"
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
  smartctl -H "$DEVICE" | tee -a "$REPORT_FILE"
}

smart_attributes() {
  local label=${1:-SMART attributes}
  header "$label" | tee -a "$REPORT_FILE"
  set_state smart_attributes "$label"
  smartctl -A "$DEVICE" | tee -a "$REPORT_FILE"
}

run_selftest() {
  local kind=$1 sleep_hint=$2
  header "SMART ${kind} self-test" | tee -a "$REPORT_FILE"
  set_state "smart_${kind}" "Starting SMART ${kind} self-test"
  smartctl -t "$kind" "$DEVICE" | tee -a "$REPORT_FILE"
  report "Sleeping ${sleep_hint}s before polling SMART self-test log"
  sleep "$sleep_hint"
  while smartctl -l selftest "$DEVICE" | grep -qi 'in progress'; do
    set_state "smart_${kind}" "SMART ${kind} self-test still in progress"
    report "SMART ${kind} self-test still running"
    sleep 60
  done
  smartctl -l selftest "$DEVICE" | tee -a "$REPORT_FILE"
}

snapshot_dmesg() {
  dmesg -T > "$1" || true
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
  badblocks -b 4096 -wsv "$DEVICE" 2>&1 | tee "$BADBLOCKS_FILE" | tee -a "$REPORT_FILE"
}

latency_test() {
  header "Latency variance detection" | tee -a "$REPORT_FILE"
  set_state latency "Running fio random-read latency test"
  fio \
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
  dd if="$DEVICE" of=/dev/null bs=16M iflag=direct status=progress 2>&1 | tee -a "$REPORT_FILE"
  dd if=/dev/zero of="$DEVICE" bs=16M oflag=direct status=progress 2>&1 | tee -a "$REPORT_FILE"
  dd if="$DEVICE" of=/dev/null bs=16M iflag=direct status=progress 2>&1 | tee -a "$REPORT_FILE"
}

evaluate() {
  header "Evaluation" | tee -a "$REPORT_FILE"
  set_state evaluate "Computing reliability score"

  local realloc pending uncorr crc temp score verdict reasons latency_p99_ms latency_mean_ms throughput_mib
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

  {
    printf 'device: %s\n' "$DEVICE"
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
  "notes": "$(printf '%s' "$reasons" | sed 's/"/\\"/g')"
}
JSON
}

main() {
  : > "$REPORT_FILE"
  report "Starting destructive qualification for $DEVICE"
  lsblk -d -o NAME,SIZE,MODEL,SERIAL,VENDOR "$DEVICE" | tee -a "$REPORT_FILE"
  local dmesg_before dmesg_after
  dmesg_before=$(mktemp)
  dmesg_after=$(mktemp)
  trap 'rm -f "$dmesg_before" "$dmesg_after"' EXIT
  snapshot_dmesg "$dmesg_before"
  smart_health
  smart_attributes "SMART attributes before testing"
  run_selftest short 120
  run_selftest long 300
  surface_test
  latency_test
  if [[ $ENABLE_STRESS -eq 1 ]]; then
    stress_test
  fi
  smart_attributes "SMART attributes after testing"
  snapshot_dmesg "$dmesg_after"
  kernel_error_check "$dmesg_before" "$dmesg_after"
  evaluate
  set_state complete "Testing complete"
  report "Completed destructive qualification for $DEVICE"
}

main
