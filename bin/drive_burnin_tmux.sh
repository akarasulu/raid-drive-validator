#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091
# shellcheck source=../lib/disk_discovery.sh
source "$ROOT_DIR/lib/disk_discovery.sh"
SUMMARY_WATCHER="$ROOT_DIR/tools/wait_and_generate_batch_summary.sh"
TMUX_RUNNER=(tmux)

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Drive selection:
  --devices /dev/sdc,/dev/sdd   Explicit comma-separated devices
  --model STRING                Match STRING in model/vendor; repeat for OR matching
  --size SIZE                   Match SIZE substring in lsblk SIZE; repeat for OR matching

Execution:
  --stress                      Enable optional stress phase
  --dry-run                     Show plan and exit
  --step-timeout-max SEC        Stop any single worker step after SEC seconds
  --session NAME                tmux session name (default: drive-burnin)
  --report-dir DIR              Parent directory for timestamped run output
                                (default: ./drive_test_reports)
  --no-dashboard                Do not launch the dashboard window
  --help                        Show this help

Examples:
  sudo $(basename "$0") --model ST4000 --model HGST --size 3.6T --dry-run
  sudo $(basename "$0") --devices /dev/sdc,/dev/sdd --stress
USAGE
}

declare -a MODEL_FILTERS=()
declare -a SIZE_FILTERS=()
DEVICE_CSV=""
ENABLE_STRESS=0
DRY_RUN=0
STEP_TIMEOUT_MAX=0
SESSION="drive-burnin"
REPORT_ROOT="$PWD/drive_test_reports"
REPORT_DIR=""
USE_DASHBOARD=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --devices) DEVICE_CSV=${2:?}; shift 2 ;;
    --model) MODEL_FILTERS+=("${2:?}"); shift 2 ;;
    --size) SIZE_FILTERS+=("${2:?}"); shift 2 ;;
    --stress) ENABLE_STRESS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --step-timeout-max) STEP_TIMEOUT_MAX=${2:?}; shift 2 ;;
    --session) SESSION=${2:?}; shift 2 ;;
    --report-dir) REPORT_ROOT=${2:?}; shift 2 ;;
    --no-dashboard) USE_DASHBOARD=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ $STEP_TIMEOUT_MAX =~ ^[0-9]+$ ]] || die '--step-timeout-max must be an integer number of seconds'

RUN_TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
REPORT_DIR="$REPORT_ROOT/$RUN_TIMESTAMP"

build_device_list() {
  local -a out=()
  if [[ -n "$DEVICE_CSV" ]]; then
    IFS=',' read -r -a out <<< "$DEVICE_CSV"
  else
    mapfile -t out < <(discover_matching_drives \
      "$(printf '%s\n' "${MODEL_FILTERS[@]}")" \
      "$(printf '%s\n' "${SIZE_FILTERS[@]}")")
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
printf '  run timestamp: %s\n' "$RUN_TIMESTAMP"
printf '  report root: %s\n' "$REPORT_ROOT"
printf '  report dir: %s\n' "$REPORT_DIR"
printf '  tmux session: %s\n' "$SESSION"
printf '  dashboard: %s\n' "$([[ $USE_DASHBOARD -eq 1 ]] && echo enabled || echo disabled)"
printf '  stress phase: %s\n' "$([[ $ENABLE_STRESS -eq 1 ]] && echo enabled || echo disabled)"
printf '  step timeout max: %s\n' "$([[ $STEP_TIMEOUT_MAX -gt 0 ]] && printf '%ss' "$STEP_TIMEOUT_MAX" || echo unlimited)"
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
[[ -x "$SUMMARY_WATCHER" ]] || die "Missing executable summary watcher: $SUMMARY_WATCHER"

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  TMUX_RUNNER=(sudo -u "$SUDO_USER" tmux)
fi

if "${TMUX_RUNNER[@]}" has-session -t "$SESSION" 2>/dev/null; then
  die "tmux session '$SESSION' already exists"
fi

"${TMUX_RUNNER[@]}" new-session -d -s "$SESSION"
"${TMUX_RUNNER[@]}" set-option -t "$SESSION" remain-on-exit on >/dev/null
idx=0
if [[ $USE_DASHBOARD -eq 1 ]]; then
  "${TMUX_RUNNER[@]}" rename-window -t "$SESSION:0" dashboard
  "${TMUX_RUNNER[@]}" send-keys -t "$SESSION:0" "bash '$ROOT_DIR/dashboard/dashboard.sh' '$REPORT_DIR'" C-m
  idx=1
else
  "${TMUX_RUNNER[@]}" rename-window -t "$SESSION:0" "$(basename "${DRIVES[0]}")"
fi

for i in "${!DRIVES[@]}"; do
  dev=${DRIVES[$i]}
  name=$(basename -- "$dev")
  if [[ $USE_DASHBOARD -eq 0 && $i -eq 0 ]]; then
    target="$SESSION:0"
  else
    "${TMUX_RUNNER[@]}" new-window -t "$SESSION" -n "$name"
    target="$SESSION:$idx"
    idx=$((idx + 1))
  fi
  cmd=(sudo "$ROOT_DIR/bin/drive_burnin_test.sh" --device "$dev" --report-dir "$REPORT_DIR" --state-dir "$REPORT_DIR/state")
  [[ $ENABLE_STRESS -eq 1 ]] && cmd+=(--stress)
  [[ $STEP_TIMEOUT_MAX -gt 0 ]] && cmd+=(--step-timeout-max "$STEP_TIMEOUT_MAX")
  "${TMUX_RUNNER[@]}" send-keys -t "$target" "$(printf '%q ' "${cmd[@]}")" C-m
done

if [[ -x "$SUMMARY_WATCHER" ]]; then
  "${TMUX_RUNNER[@]}" new-window -t "$SESSION" -n summary
  "${TMUX_RUNNER[@]}" send-keys -t "$SESSION:$idx" \
    "sudo $SUMMARY_WATCHER --report-dir '$REPORT_DIR' --devices '$(IFS=,; printf '%s' "${DRIVES[*]}")'" C-m
fi

echo
printf 'Started %d drive worker(s).\n' "${#DRIVES[@]}"
printf 'Attach with: tmux attach -t %s\n' "$SESSION"
printf 'Reports will land in: %s\n' "$REPORT_DIR"
