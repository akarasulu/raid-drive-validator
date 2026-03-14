#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") --report-dir DIR --devices /dev/sdb,/dev/sdc

Wait for all expected per-drive markdown reports, render a live batch summary,
then generate and print the final markdown summary.
USAGE
}

REPORT_DIR=""
DEVICE_CSV=""
LOG_FILE=""
REFRESH_INTERVAL=${REFRESH_INTERVAL:-5}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-dir) REPORT_DIR=${2:?}; shift 2 ;;
    --devices) DEVICE_CSV=${2:?}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[[ -n "$REPORT_DIR" && -n "$DEVICE_CSV" ]] || { usage >&2; exit 1; }

IFS=',' read -r -a DEVICES <<< "$DEVICE_CSV"
STATE_DIR="$REPORT_DIR/state"
MARKDOWN_DIR="$REPORT_DIR/markdown/drives"
SUMMARY_FILE="$REPORT_DIR/markdown/summary.md"
LOG_FILE="$REPORT_DIR/summary_watcher.log"
mkdir -p "$MARKDOWN_DIR"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

on_exit() {
  local rc=$1
  (( rc == 0 )) || log "summary watcher failed with exit code $rc"
  exit "$rc"
}

read_state_value() {
  local file=$1 key=$2
  awk -F= -v key="$key" '
    $1 == key {
      sub(/^[^=]*=/, "", $0)
      print
      exit
    }
  ' "$file" 2>/dev/null || true
}

read_summary_value() {
  local file=$1 key=$2
  python3 - "$file" "$key" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
if not path.exists():
    sys.exit(0)
data = json.loads(path.read_text())
value = data.get(key, "")
print(value)
PY
}

trim_message() {
  local text=${1:-} max_len=${2:-80}
  if (( ${#text} <= max_len )); then
    printf '%s\n' "$text"
  else
    printf '%s...\n' "${text:0:max_len-3}"
  fi
}

render_live_summary() {
  local total=${#DEVICES[@]} complete=0 final_json=0 running=0
  local pass=0 review=0 fail=0
  local dev name state_file summary_file md_file metrics_file stage updated message verdict score temp temp_min temp_max temp_avg crc md_status qualification

  if [[ -t 1 && -n "${TERM:-}" ]]; then
    clear
  fi

  echo "Batch Summary Watcher"
  echo "Updated: $(date)"
  echo "Report directory: $REPORT_DIR"
  echo "Devices: $DEVICE_CSV"
  echo

  for dev in "${DEVICES[@]}"; do
    name=$(basename -- "$dev")
    summary_file="$REPORT_DIR/${name}_summary.json"
    md_file="$MARKDOWN_DIR/${name}.md"
    [[ -f "$summary_file" ]] && final_json=$((final_json + 1))
    [[ -f "$md_file" ]] && complete=$((complete + 1))
  done

  printf 'Markdown complete: %d/%d  JSON complete: %d/%d\n' "$complete" "$total" "$final_json" "$total"
  echo
  printf '%-8s %-18s %-19s %-7s %-7s %-7s %-7s %-5s %-13s %-10s %-8s %-10s\n' \
    "Drive" "Stage" "Updated" "Temp" "Min" "Max" "Avg" "CRC" "Qualification" "Verdict" "Score" "Markdown"
  printf '%0.s-' {1..138}
  echo

  for dev in "${DEVICES[@]}"; do
    name=$(basename -- "$dev")
    state_file="$STATE_DIR/${name}.state"
    summary_file="$REPORT_DIR/${name}_summary.json"
    metrics_file="$REPORT_DIR/${name}_live_metrics.env"
    md_file="$MARKDOWN_DIR/${name}.md"
    stage=$(read_state_value "$state_file" stage)
    updated=$(read_state_value "$state_file" updated)
    message=$(read_state_value "$state_file" message)
    verdict=$(read_summary_value "$summary_file" verdict)
    qualification=$(read_summary_value "$summary_file" qualification_status)
    score=$(read_summary_value "$summary_file" reliability_score)
    if [[ -f "$metrics_file" ]]; then
      temp=$(read_state_value "$metrics_file" current_temp_c)
      temp_min=$(read_state_value "$metrics_file" min_temp_c)
      temp_max=$(read_state_value "$metrics_file" max_temp_c)
      temp_avg=$(read_state_value "$metrics_file" avg_temp_c)
    else
      temp=$(read_summary_value "$summary_file" temperature_c)
      temp_min=$(read_summary_value "$summary_file" temperature_min_c)
      temp_max=$(read_summary_value "$summary_file" temperature_max_c)
      temp_avg=$(read_summary_value "$summary_file" temperature_avg_c)
    fi
    crc=$(read_summary_value "$summary_file" crc_errors)
    md_status=$([[ -f "$md_file" ]] && echo ready || echo pending)

    [[ -n "$stage" && "$stage" != "complete" ]] && running=$((running + 1))
    case "$verdict" in
      PASS) pass=$((pass + 1)) ;;
      REVIEW) review=$((review + 1)) ;;
      FAIL) fail=$((fail + 1)) ;;
    esac

    printf '%-8s %-18s %-19s %-7s %-7s %-7s %-7s %-5s %-13s %-10s %-8s %-10s\n' \
      "$name" "${stage:-waiting}" "${updated:-NA}" "${temp:-NA}" "${temp_min:-NA}" "${temp_max:-NA}" "${temp_avg:-NA}" "${crc:-NA}" "${qualification:-NA}" "${verdict:-NA}" "${score:-NA}" "$md_status"
    printf '  status: %s\n' "$(trim_message "${message:-waiting for worker output}" 100)"
  done

  echo
  printf 'Verdicts: PASS=%d  REVIEW=%d  FAIL=%d  Active=%d\n' "$pass" "$review" "$fail" "$running"
  echo
  echo "Summary window behavior:"
  echo "  waiting for all per-drive markdown reports before generating final batch markdown"
}

render_final_summary() {
  local pass=0 review=0 fail=0
  local dev name summary_file verdict score temp temp_min temp_max temp_avg crc qualification

  if [[ -t 1 && -n "${TERM:-}" ]]; then
    clear
  fi

  echo "Batch Summary Complete"
  echo "Updated: $(date)"
  echo "Report directory: $REPORT_DIR"
  echo

  for dev in "${DEVICES[@]}"; do
    name=$(basename -- "$dev")
    summary_file="$REPORT_DIR/${name}_summary.json"
    verdict=$(read_summary_value "$summary_file" verdict)
    case "$verdict" in
      PASS) pass=$((pass + 1)) ;;
      REVIEW) review=$((review + 1)) ;;
      FAIL) fail=$((fail + 1)) ;;
    esac
  done

  printf 'Final verdict totals: PASS=%d  REVIEW=%d  FAIL=%d\n' "$pass" "$review" "$fail"
  echo
  printf '%-8s %-13s %-10s %-8s %-7s %-7s %-7s %-7s %-5s %-10s\n' "Drive" "Qualification" "Verdict" "Score" "Temp" "Min" "Max" "Avg" "CRC" "Markdown"
  printf '%0.s-' {1..100}
  echo

  for dev in "${DEVICES[@]}"; do
    name=$(basename -- "$dev")
    summary_file="$REPORT_DIR/${name}_summary.json"
    verdict=$(read_summary_value "$summary_file" verdict)
    qualification=$(read_summary_value "$summary_file" qualification_status)
    score=$(read_summary_value "$summary_file" reliability_score)
    temp=$(read_summary_value "$summary_file" temperature_c)
    temp_min=$(read_summary_value "$summary_file" temperature_min_c)
    temp_max=$(read_summary_value "$summary_file" temperature_max_c)
    temp_avg=$(read_summary_value "$summary_file" temperature_avg_c)
    crc=$(read_summary_value "$summary_file" crc_errors)
    printf '%-8s %-13s %-10s %-8s %-7s %-7s %-7s %-7s %-5s %-10s\n' \
      "$name" "${qualification:-NA}" "${verdict:-NA}" "${score:-NA}" "${temp:-NA}" "${temp_min:-NA}" "${temp_max:-NA}" "${temp_avg:-NA}" "${crc:-NA}" "ready"
  done

  echo
  echo "Final batch markdown summary:"
  echo
  cat "$SUMMARY_FILE"
}

trap 'on_exit $?' EXIT

log "summary watcher started for devices: $DEVICE_CSV"

while true; do
  render_live_summary

  complete_count=0
  for dev in "${DEVICES[@]}"; do
    name=$(basename -- "$dev")
    [[ -f "$MARKDOWN_DIR/${name}.md" ]] && complete_count=$((complete_count + 1))
  done

  if (( complete_count == ${#DEVICES[@]} )); then
    log "all per-drive markdown reports detected"
    break
  fi

  log "waiting for per-drive markdown reports ($complete_count/${#DEVICES[@]})"
  sleep "$REFRESH_INTERVAL"
done

bash "$(dirname "$0")/generate_batch_markdown_summary.sh" --report-dir "$REPORT_DIR"
log "batch markdown summary generated"

while true; do
  render_final_summary
  sleep "$REFRESH_INTERVAL"
done
