#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Collect a read-only host inventory before running destructive drive tests.

Options:
  --output-dir DIR       Directory for the preflight report bundle
                         (default: ./preflight_reports/HOST-TIMESTAMP)
  --devices CSV          Optional comma-separated device list for burn-in dry-run
  --model STRING         Optional model/vendor filter for burn-in dry-run; repeat for OR matching
  --size SIZE            Optional size filter for burn-in dry-run; repeat for OR matching
  --help                 Show this help

This script is read-only with respect to disks. It writes report files only.
USAGE
}

HOSTNAME_VALUE=$(hostname -s 2>/dev/null || hostname)
TIMESTAMP_VALUE=$(date '+%Y%m%d-%H%M%S')
OUTPUT_DIR="$PWD/preflight_reports/${HOSTNAME_VALUE}-${TIMESTAMP_VALUE}"
DEVICE_CSV=""
declare -a MODEL_FILTERS=()
declare -a SIZE_FILTERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR=${2:?}; shift 2 ;;
    --devices) DEVICE_CSV=${2:?}; shift 2 ;;
    --model) MODEL_FILTERS+=("${2:?}"); shift 2 ;;
    --size) SIZE_FILTERS+=("${2:?}"); shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

mkdir -p "$OUTPUT_DIR"

SUMMARY_FILE="$OUTPUT_DIR/summary.txt"

note() {
  printf '%s\n' "$*" | tee -a "$SUMMARY_FILE"
}

run_capture() {
  local name=$1
  shift
  local outfile="$OUTPUT_DIR/${name}.txt"
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    if command -v timeout >/dev/null 2>&1; then
      timeout 15s "$@"
    else
      "$@"
    fi
  } >"$outfile" 2>&1 || true
}

run_optional_capture() {
  local name=$1
  shift
  local cmd=${1:?}
  if command -v "$cmd" >/dev/null 2>&1; then
    run_capture "$name" "$@"
  else
    printf 'command not found: %s\n' "$cmd" > "$OUTPUT_DIR/${name}.txt"
  fi
}

run_burnin_dry_run() {
  local outfile="$OUTPUT_DIR/burnin_dry_run.txt"
  local -a cmd=("$ROOT_DIR/bin/drive_burnin_tmux.sh" --dry-run)

  if [[ -n "$DEVICE_CSV" ]]; then
    cmd+=(--devices "$DEVICE_CSV")
  else
    local model_filter
    local size_filter
    for model_filter in "${MODEL_FILTERS[@]}"; do
      cmd+=(--model "$model_filter")
    done
    for size_filter in "${SIZE_FILTERS[@]}"; do
      cmd+=(--size "$size_filter")
    done
  fi

  {
    printf '$'
    printf ' %q' "${cmd[@]}"
    printf '\n'
    "${cmd[@]}"
  } >"$outfile" 2>&1 || true
}

capture_dmesg_tail() {
  local outfile="$OUTPUT_DIR/dmesg_tail.txt"
  if command -v dmesg >/dev/null 2>&1; then
    {
      printf '$ dmesg -T | tail -n 200\n'
      dmesg -T | tail -n 200
    } >"$outfile" 2>&1 || true
  else
    printf 'command not found: dmesg\n' > "$outfile"
  fi
}

{
  printf 'raid-drive-validator host preflight\n'
  printf 'generated: %s\n' "$(timestamp)"
  printf 'host: %s\n' "$HOSTNAME_VALUE"
  printf 'output_dir: %s\n' "$OUTPUT_DIR"
  printf 'effective_uid: %s\n' "${EUID:-$(id -u)}"
} > "$SUMMARY_FILE"

note
note 'Inventory collection started.'
note 'This bundle is disk read-only except for writing these report files.'
note

run_capture meta printf 'date=%s\nuser=%s\nuid=%s\ncwd=%s\n' \
  "$(date --iso-8601=seconds)" \
  "$(id -un)" \
  "$(id -u)" \
  "$PWD"
run_capture os_release cat /etc/os-release
run_capture uname uname -a
run_optional_capture hostnamectl hostnamectl
run_capture lsblk lsblk -e7 -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,VENDOR,ROTA,TRAN
run_optional_capture findmnt findmnt -A
run_optional_capture blkid blkid
run_optional_capture smartctl_scan smartctl --scan-open
run_optional_capture ip_addr ip -br addr
run_optional_capture ip_link ip -br link
run_optional_capture lspci lspci -nn
run_optional_capture lsusb lsusb
run_optional_capture zpool_status zpool status
run_optional_capture zpool_import zpool import
run_optional_capture zfs_list zfs list
capture_dmesg_tail

if [[ -n "$DEVICE_CSV" || ${#MODEL_FILTERS[@]} -gt 0 || ${#SIZE_FILTERS[@]} -gt 0 ]]; then
  note 'Burn-in dry-run requested; see burnin_dry_run.txt.'
  run_burnin_dry_run
else
  printf 'No burn-in dry-run requested.\n' > "$OUTPUT_DIR/burnin_dry_run.txt"
fi

note "Preflight bundle written to: $OUTPUT_DIR"
