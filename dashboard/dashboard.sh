#!/usr/bin/env bash
set -Eeuo pipefail

REPORT_DIR=${1:-$PWD/drive_test_reports}
STATE_DIR="$REPORT_DIR/state"
DASHBOARD_INTERVAL=${DASHBOARD_INTERVAL:-5}
DASHBOARD_ONCE=${DASHBOARD_ONCE:-0}

trim_message() {
  local text=${1:-} max_len=${2:-70}
  if (( ${#text} <= max_len )); then
    printf '%s\n' "$text"
  else
    printf '%s...\n' "${text:0:max_len-3}"
  fi
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

read_smart_value_from_report() {
  local report=$1 pattern=$2
  local value
  value=$(
    grep -E "$pattern" "$report" 2>/dev/null | tail -1 | awk '{print $10}' || true
  )
  printf '%s\n' "$value"
}

collect_drive_metrics() {
  local drive=$1
  local summary_file="$REPORT_DIR/${drive}_summary.json"
  local report_file="$REPORT_DIR/${drive}_report.txt"
  local metrics_file="$REPORT_DIR/${drive}_live_metrics.env"
  local temp temp_min temp_max temp_avg realloc pending crc qualification verdict score

  if [[ -f "$metrics_file" ]]; then
    temp=$(read_state_value "$metrics_file" current_temp_c)
    temp_min=$(read_state_value "$metrics_file" min_temp_c)
    temp_max=$(read_state_value "$metrics_file" max_temp_c)
    temp_avg=$(read_state_value "$metrics_file" avg_temp_c)
  elif [[ -f "$summary_file" ]]; then
    temp=$(read_summary_value "$summary_file" temperature_c)
    temp_min=$(read_summary_value "$summary_file" temperature_min_c)
    temp_max=$(read_summary_value "$summary_file" temperature_max_c)
    temp_avg=$(read_summary_value "$summary_file" temperature_avg_c)
  else
    temp=$(read_smart_value_from_report "$report_file" 'Temperature_Celsius|Airflow_Temperature_Cel|Current_Drive_Temperature')
    temp_min="${temp:-NA}"
    temp_max="${temp:-NA}"
    temp_avg="${temp:-NA}"
  fi

  if [[ -f "$summary_file" ]]; then
    realloc=$(read_summary_value "$summary_file" reallocated)
    pending=$(read_summary_value "$summary_file" pending)
    crc=$(read_summary_value "$summary_file" crc_errors)
    qualification=$(read_summary_value "$summary_file" qualification_status)
    verdict=$(read_summary_value "$summary_file" verdict)
    score=$(read_summary_value "$summary_file" reliability_score)
  else
    realloc=$(read_smart_value_from_report "$report_file" 'Reallocated_Sector_Ct')
    pending=$(read_smart_value_from_report "$report_file" 'Current_Pending_Sector')
    crc=$(read_smart_value_from_report "$report_file" 'UDMA_CRC_Error_Count')
    qualification=""
    verdict=""
    score=""
  fi

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${temp:-NA}" \
    "${temp_min:-NA}" \
    "${temp_max:-NA}" \
    "${temp_avg:-NA}" \
    "${realloc:-NA}" \
    "${pending:-NA}" \
    "${crc:-NA}" \
    "${qualification:-NA}" \
    "${verdict:-NA}" \
    "${score:-NA}"
}

render_dashboard() {
  local state_count=0 running_count=0 complete_count=0 timeout_count=0
  local pass_count=0 review_count=0 fail_count=0
  local state drive stage updated message temp temp_min temp_max temp_avg realloc pending crc qualification verdict score message_short

  if [[ -t 1 && -n "${TERM:-}" ]]; then
    clear
  fi
  echo "Drive Burn-in Dashboard"
  echo "Updated: $(date)"
  echo "Report directory: $REPORT_DIR"
  echo

  if compgen -G "$STATE_DIR/*.state" >/dev/null; then
    while IFS= read -r state; do
      state_count=$((state_count + 1))
      stage=$(read_state_value "$state" stage)
      case "$stage" in
        complete) complete_count=$((complete_count + 1)) ;;
        timeout) timeout_count=$((timeout_count + 1)) ;;
        *) running_count=$((running_count + 1)) ;;
      esac
    done < <(printf '%s\n' "$STATE_DIR"/*.state | sort)
  fi

  while IFS= read -r summary_file; do
    verdict=$(read_summary_value "$summary_file" verdict)
    case "$verdict" in
      PASS) pass_count=$((pass_count + 1)) ;;
      REVIEW) review_count=$((review_count + 1)) ;;
      FAIL) fail_count=$((fail_count + 1)) ;;
    esac
  done < <(find "$REPORT_DIR" -maxdepth 1 -name '*_summary.json' | sort)

  printf 'Workers: %d  Running: %d  Complete: %d  Timeout-state: %d  PASS: %d  REVIEW: %d  FAIL: %d\n' \
    "$state_count" "$running_count" "$complete_count" "$timeout_count" "$pass_count" "$review_count" "$fail_count"
  echo
  printf '%-8s %-7s %-7s %-7s %-7s %-8s %-8s %-5s %-13s %-10s %-8s %-18s %-19s\n' \
    "Drive" "Temp" "Min" "Max" "Avg" "Realloc" "Pending" "CRC" "Qualification" "Verdict" "Score" "Stage" "Updated"
  printf '%0.s-' {1..148}
  echo

  if compgen -G "$STATE_DIR/*.state" >/dev/null; then
    while IFS= read -r state; do
      drive=$(basename "$state" .state)
      stage=$(read_state_value "$state" stage)
      updated=$(read_state_value "$state" updated)
      message=$(read_state_value "$state" message)
      IFS='|' read -r temp temp_min temp_max temp_avg realloc pending crc qualification verdict score < <(collect_drive_metrics "$drive")
      printf '%-8s %-7s %-7s %-7s %-7s %-8s %-8s %-5s %-13s %-10s %-8s %-18s %-19s\n' \
        "$drive" "${temp:-NA}" "${temp_min:-NA}" "${temp_max:-NA}" "${temp_avg:-NA}" "${realloc:-NA}" "${pending:-NA}" "${crc:-NA}" "${qualification:-NA}" "${verdict:-NA}" "${score:-NA}" "${stage:-unknown}" "${updated:-NA}"
      message_short=$(trim_message "${message:-no status message}" 100)
      printf '  status: %s\n' "$message_short"
    done < <(printf '%s\n' "$STATE_DIR"/*.state | sort)
  else
    echo "No state files yet. Waiting for workers to start..."
  fi
}

while true; do
  render_dashboard
  [[ "$DASHBOARD_ONCE" == "1" ]] && break
  sleep "$DASHBOARD_INTERVAL"
done
