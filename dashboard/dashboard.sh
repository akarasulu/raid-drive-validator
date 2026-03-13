#!/usr/bin/env bash
set -Eeuo pipefail

REPORT_DIR=${1:-$PWD/drive_test_reports}
STATE_DIR="$REPORT_DIR/state"

while true; do
  clear
  echo "Drive Burn-in Dashboard"
  echo "Updated: $(date)"
  echo "Report directory: $REPORT_DIR"
  echo
  printf '%-8s %-10s %-10s %-10s %-8s %-18s %-24s\n' "Drive" "Temp(C)" "Realloc" "Pending" "CRC" "Stage" "Updated"
  printf '%0.s-' {1..96}
  echo
  if compgen -G "$STATE_DIR/*.state" >/dev/null; then
    for state in "$STATE_DIR"/*.state; do
      drive=$(basename "$state" .state)
      # shellcheck disable=SC1090
      source "$state"
      report="$REPORT_DIR/${drive}_report.txt"
      temp=$(grep -E 'Temperature_Celsius|Airflow_Temperature_Cel|Current_Drive_Temperature' "$report" 2>/dev/null | tail -1 | awk '{print $10}')
      realloc=$(grep 'Reallocated_Sector_Ct' "$report" 2>/dev/null | tail -1 | awk '{print $10}')
      pending=$(grep 'Current_Pending_Sector' "$report" 2>/dev/null | tail -1 | awk '{print $10}')
      crc=$(grep 'UDMA_CRC_Error_Count' "$report" 2>/dev/null | tail -1 | awk '{print $10}')
      printf '%-8s %-10s %-10s %-10s %-8s %-18s %-24s\n' "$drive" "${temp:-NA}" "${realloc:-NA}" "${pending:-NA}" "${crc:-NA}" "${stage:-unknown}" "${updated:-NA}"
    done | sort
  else
    echo "No state files yet. Waiting for workers to start..."
  fi
  sleep 5
done
