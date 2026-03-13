#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=../lib/disk_discovery.sh
source "$ROOT_DIR/lib/disk_discovery.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Drive selection:
  --devices /dev/sdc,/dev/sdd   Explicit comma-separated devices
  --model STRING                Auto-discover drives whose model/vendor contains STRING
  --size SIZE                   Auto-discover drives whose lsblk SIZE contains SIZE (example: 3.7T)

Execution:
  --stress                      Enable optional stress phase
  --dry-run                     Show plan and exit
  --session NAME                tmux session name (default: drive-burnin)
  --report-dir DIR              Report directory (default: ./drive_test_reports)
  --no-dashboard                Do not launch the dashboard window
  --help                        Show this help

Examples:
  sudo $(basename "$0") --model ST4000 --size 3.7T --dry-run
  sudo $(basename "$0") --devices /dev/sdc,/dev/sdd --stress
USAGE
}

MODEL_FILTER=""
SIZE_FILTER=""
DEVICE_CSV=""
ENABLE_STRESS=0
DRY_RUN=0
SESSION="drive-burnin"
REPORT_DIR="$PWD/drive_test_reports"
USE_DASHBOARD=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --devices) DEVICE_CSV=${2:?}; shift 2 ;;
    --model) MODEL_FILTER=${2:?}; shift 2 ;;
    --size) SIZE_FILTER=${2:?}; shift 2 ;;
    --stress) ENABLE_STRESS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --session) SESSION=${2:?}; shift 2 ;;
    --report-dir) REPORT_DIR=${2:?}; shift 2 ;;
    --no-dashboard) USE_DASHBOARD=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

build_device_list() {
  local -a out=()
  if [[ -n "$DEVICE_CSV" ]]; then
    IFS=',' read -r -a out <<< "$DEVICE_CSV"
  else
    mapfile -t out < <(discover_matching_drives "$MODEL_FILTER" "$SIZE_FILTER")
  fi
  printf '%s\n' "${out[@]}" | awk 'NF' | sort -u
}

mapfile -t DRIVES < <(build_device_list)
[[ ${#DRIVES[@]} -gt 0 ]] || die 'No matching drives found'

printf 'Detected drives:\n'
for dev in "${DRIVES[@]}"; do
  lsblk -d -o NAME,SIZE,MODEL,VENDOR "$dev"
done

echo
printf 'Plan:\n'
printf '  report dir: %s\n' "$REPORT_DIR"
printf '  tmux session: %s\n' "$SESSION"
printf '  dashboard: %s\n' "$([[ $USE_DASHBOARD -eq 1 ]] && echo enabled || echo disabled)"
printf '  stress phase: %s\n' "$([[ $ENABLE_STRESS -eq 1 ]] && echo enabled || echo disabled)"
printf '  destructive surface test: enabled\n'
printf '  latency variance detection: enabled\n'
printf '  SMART short/long tests: enabled\n'

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  echo 'Dry run only. No tests started.'
  exit 0
fi

require_root
require_tools tmux lsblk
mkdir -p "$REPORT_DIR/state"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  die "tmux session '$SESSION' already exists"
fi

tmux new-session -d -s "$SESSION"
idx=0
if [[ $USE_DASHBOARD -eq 1 ]]; then
  tmux rename-window -t "$SESSION:0" dashboard
  tmux send-keys -t "$SESSION:0" "$ROOT_DIR/dashboard/dashboard.sh '$REPORT_DIR'" C-m
  idx=1
else
  tmux rename-window -t "$SESSION:0" "$(basename "${DRIVES[0]}")"
fi

for i in "${!DRIVES[@]}"; do
  dev=${DRIVES[$i]}
  name=$(basename -- "$dev")
  if [[ $USE_DASHBOARD -eq 0 && $i -eq 0 ]]; then
    target="$SESSION:0"
  else
    tmux new-window -t "$SESSION" -n "$name"
    target="$SESSION:$idx"
    idx=$((idx + 1))
  fi
  cmd=("$ROOT_DIR/bin/drive_burnin_test.sh" --device "$dev" --report-dir "$REPORT_DIR" --state-dir "$REPORT_DIR/state")
  [[ $ENABLE_STRESS -eq 1 ]] && cmd+=(--stress)
  tmux send-keys -t "$target" "$(printf '%q ' "${cmd[@]}")" C-m
done

echo
printf 'Started %d drive worker(s).\n' "${#DRIVES[@]}"
printf 'Attach with: tmux attach -t %s\n' "$SESSION"
printf 'Reports will land in: %s\n' "$REPORT_DIR"
