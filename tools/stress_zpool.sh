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
Usage: $(basename "$0") --pool-name NAME [options]

Run a bounded performance/stress exercise against an existing ZFS pool by
creating a temporary dataset, writing test files into it with fio, capturing
pool telemetry, and then cleaning up.

Options:
  --pool-name NAME         Required zpool name
  --dataset NAME           Test dataset name (default: POOL/raid-drive-validator-stress-TIMESTAMP)
  --report-dir DIR         Output directory (default: ./zpool_stress_reports/POOL-TIMESTAMP)
  --file-size SIZE         fio file size per sequential phase (default: 8G)
  --runtime-sec SEC        Runtime for timed phases (default: 300)
  --jobs N                 fio numjobs for timed random phase (default: 4)
  --seq-write-timeout-sec SEC
                           Timeout for the sequential write phase (default: runtime-sec + 300)
                           Use 0 to disable the timeout.
  --seq-read-timeout-sec SEC
                           Timeout for the sequential read phase (default: runtime-sec + 300)
                           Use 0 to disable the timeout.
  --keep-dataset           Leave the temporary dataset in place after the run
  --scrub                  Start a scrub after fio completes
  --scrub-wait-sec SEC     Maximum time to wait for the scrub (default: 600)
  --execute                Run the test instead of only printing the plan
  --help                   Show this help

Notes:
  - The default behavior is a dry-run plan; pass --execute to run it.
  - The script writes only inside a temporary child dataset of the target pool.
USAGE
}

POOL_NAME=""
DATASET_NAME=""
REPORT_DIR=""
FILE_SIZE=8G
RUNTIME_SEC=300
NUMJOBS=4
SEQ_WRITE_TIMEOUT_SEC=""
SEQ_READ_TIMEOUT_SEC=""
KEEP_DATASET=0
RUN_SCRUB=0
SCRUB_WAIT_SEC=600
EXECUTE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool-name) POOL_NAME=${2:?}; shift 2 ;;
    --dataset) DATASET_NAME=${2:?}; shift 2 ;;
    --report-dir) REPORT_DIR=${2:?}; shift 2 ;;
    --file-size) FILE_SIZE=${2:?}; shift 2 ;;
    --runtime-sec) RUNTIME_SEC=${2:?}; shift 2 ;;
    --jobs) NUMJOBS=${2:?}; shift 2 ;;
    --seq-write-timeout-sec) SEQ_WRITE_TIMEOUT_SEC=${2:?}; shift 2 ;;
    --seq-read-timeout-sec) SEQ_READ_TIMEOUT_SEC=${2:?}; shift 2 ;;
    --keep-dataset) KEEP_DATASET=1; shift ;;
    --scrub) RUN_SCRUB=1; shift ;;
    --scrub-wait-sec) SCRUB_WAIT_SEC=${2:?}; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --wwn) die '--wwn is not supported by this script' ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$POOL_NAME" ]] || die '--pool-name is required'
[[ $RUNTIME_SEC =~ ^[0-9]+$ ]] || die '--runtime-sec must be an integer'
[[ $NUMJOBS =~ ^[0-9]+$ ]] || die '--jobs must be an integer'
[[ -z "$SEQ_WRITE_TIMEOUT_SEC" || $SEQ_WRITE_TIMEOUT_SEC =~ ^[0-9]+$ ]] || die '--seq-write-timeout-sec must be an integer'
[[ -z "$SEQ_READ_TIMEOUT_SEC" || $SEQ_READ_TIMEOUT_SEC =~ ^[0-9]+$ ]] || die '--seq-read-timeout-sec must be an integer'
[[ $SCRUB_WAIT_SEC =~ ^[0-9]+$ ]] || die '--scrub-wait-sec must be an integer'
(( RUNTIME_SEC > 0 )) || die '--runtime-sec must be greater than zero'
(( NUMJOBS > 0 )) || die '--jobs must be greater than zero'

TIMESTAMP_VALUE=$(date '+%Y%m%d-%H%M%S')
DATASET_NAME=${DATASET_NAME:-"$POOL_NAME/raid-drive-validator-stress-$TIMESTAMP_VALUE"}
REPORT_DIR=${REPORT_DIR:-"$PWD/zpool_stress_reports/${POOL_NAME}-${TIMESTAMP_VALUE}"}
SEQ_WRITE_TIMEOUT_SEC=${SEQ_WRITE_TIMEOUT_SEC:-$((RUNTIME_SEC + 300))}
SEQ_READ_TIMEOUT_SEC=${SEQ_READ_TIMEOUT_SEC:-$((RUNTIME_SEC + 300))}

SUMMARY_FILE="$REPORT_DIR/summary.txt"
STATUS_BEFORE="$REPORT_DIR/zpool_status_before.txt"
STATUS_AFTER="$REPORT_DIR/zpool_status_after.txt"
IOSTAT_BEFORE="$REPORT_DIR/zpool_iostat_before.txt"
IOSTAT_AFTER="$REPORT_DIR/zpool_iostat_after.txt"
SCRUB_STATUS_FILE="$REPORT_DIR/zpool_scrub_status.txt"
SEQ_WRITE_JSON="$REPORT_DIR/fio_seq_write.json"
RANDRW_JSON="$REPORT_DIR/fio_randrw.json"
SEQ_READ_JSON="$REPORT_DIR/fio_seq_read.json"

TEST_DATASET_CREATED=0
TEST_MOUNTPOINT=""
TEST_FILE=""

note() {
  printf '%s\n' "$*" | tee -a "$SUMMARY_FILE"
}

print_cmd() {
  printf '$'
  printf ' %q' "$@"
  printf '\n'
}

run_logged() {
  local outfile=$1
  shift
  {
    print_cmd "$@"
    "$@"
  } >"$outfile" 2>&1
}

run_timeout_logged() {
  local outfile=$1
  local timeout_sec=$2
  shift 2
  {
    print_cmd "$@"
    if command -v timeout >/dev/null 2>&1; then
      timeout "${timeout_sec}s" "$@"
    else
      "$@"
    fi
  } >"$outfile" 2>&1
}

run_maybe_timeout_logged() {
  local outfile=$1
  local timeout_sec=$2
  shift 2
  if (( timeout_sec == 0 )); then
    run_logged "$outfile" "$@"
  else
    run_timeout_logged "$outfile" "$timeout_sec" "$@"
  fi
}

cleanup_dataset() {
  if (( TEST_DATASET_CREATED == 1 && KEEP_DATASET == 0 )); then
    note "Cleaning up temporary dataset: $DATASET_NAME"
    zfs destroy -r "$DATASET_NAME" >>"$SUMMARY_FILE" 2>&1 || note "WARNING: failed to destroy $DATASET_NAME"
  fi
}

wait_for_scrub() {
  local deadline=$((SECONDS + SCRUB_WAIT_SEC))
  local status

  : >"$SCRUB_STATUS_FILE"
  while (( SECONDS < deadline )); do
    status=$(zpool status "$POOL_NAME" 2>/dev/null || true)
    printf '%s\n' "$status" >"$SCRUB_STATUS_FILE"
    if [[ $status != *"scan: scrub in progress"* ]]; then
      return 0
    fi
    sleep 10
  done
  return 1
}

mkdir -p "$REPORT_DIR"
{
  printf 'raid-drive-validator zpool stress\n'
  printf 'generated: %s\n' "$(timestamp)"
  printf 'pool: %s\n' "$POOL_NAME"
  printf 'dataset: %s\n' "$DATASET_NAME"
  printf 'report_dir: %s\n' "$REPORT_DIR"
  printf 'file_size: %s\n' "$FILE_SIZE"
  printf 'runtime_sec: %s\n' "$RUNTIME_SEC"
  printf 'jobs: %s\n' "$NUMJOBS"
  printf 'seq_write_timeout_sec: %s\n' "$SEQ_WRITE_TIMEOUT_SEC"
  printf 'seq_read_timeout_sec: %s\n' "$SEQ_READ_TIMEOUT_SEC"
  printf 'keep_dataset: %s\n' "$KEEP_DATASET"
  printf 'scrub: %s\n' "$RUN_SCRUB"
} >"$SUMMARY_FILE"

note
note 'Planned phases:'
note "1. capture zpool status/iostat for $POOL_NAME"
note "2. create temporary dataset $DATASET_NAME"
note "3. sequential write fio phase into a temporary file (timeout: $([[ $SEQ_WRITE_TIMEOUT_SEC -eq 0 ]] && echo unlimited || printf '%ss' "$SEQ_WRITE_TIMEOUT_SEC"))"
note "4. timed random read/write fio phase"
note "5. sequential read fio phase (timeout: $([[ $SEQ_READ_TIMEOUT_SEC -eq 0 ]] && echo unlimited || printf '%ss' "$SEQ_READ_TIMEOUT_SEC"))"
if (( RUN_SCRUB == 1 )); then
  note "6. start a scrub and wait up to ${SCRUB_WAIT_SEC}s"
fi
if (( KEEP_DATASET == 0 )); then
  note "cleanup: destroy $DATASET_NAME"
else
  note "cleanup: keep $DATASET_NAME"
fi
note

if (( EXECUTE == 0 )); then
  print_cmd zpool status "$POOL_NAME"
  print_cmd zpool iostat -v "$POOL_NAME" 1 2
  print_cmd zfs create -o compression=off -o atime=off "$DATASET_NAME"
  if (( SEQ_WRITE_TIMEOUT_SEC == 0 )); then
    print_cmd fio --name seq_write --directory "<mountpoint>" --filename zpool-stress.bin --rw write --bs 1M --iodepth 16 --direct 1 --size "$FILE_SIZE" --ioengine libaio --output-format json
  else
    print_cmd timeout "${SEQ_WRITE_TIMEOUT_SEC}s" fio --name seq_write --directory "<mountpoint>" --filename zpool-stress.bin --rw write --bs 1M --iodepth 16 --direct 1 --size "$FILE_SIZE" --ioengine libaio --output-format json
  fi
  print_cmd fio --name randrw --directory "<mountpoint>" --filename zpool-stress.bin --rw randrw --rwmixread 70 --bs 128k --iodepth 32 --direct 1 --ioengine libaio --time_based --runtime "$RUNTIME_SEC" --numjobs "$NUMJOBS" --group_reporting --output-format json
  if (( SEQ_READ_TIMEOUT_SEC == 0 )); then
    print_cmd fio --name seq_read --directory "<mountpoint>" --filename zpool-stress.bin --rw read --bs 1M --iodepth 16 --direct 1 --size "$FILE_SIZE" --ioengine libaio --output-format json
  else
    print_cmd timeout "${SEQ_READ_TIMEOUT_SEC}s" fio --name seq_read --directory "<mountpoint>" --filename zpool-stress.bin --rw read --bs 1M --iodepth 16 --direct 1 --size "$FILE_SIZE" --ioengine libaio --output-format json
  fi
  (( RUN_SCRUB == 1 )) && print_cmd zpool scrub "$POOL_NAME"
  (( KEEP_DATASET == 0 )) && print_cmd zfs destroy -r "$DATASET_NAME"
  exit 0
fi

require_root
require_tools zpool zfs fio awk sed grep

trap cleanup_dataset EXIT

note 'Capturing initial pool state.'
run_logged "$STATUS_BEFORE" zpool status "$POOL_NAME"
run_logged "$IOSTAT_BEFORE" zpool iostat -v "$POOL_NAME" 1 2

note "Creating temporary dataset: $DATASET_NAME"
zfs list -H -o name "$DATASET_NAME" >/dev/null 2>&1 && die "Dataset already exists: $DATASET_NAME"
zfs create -o compression=off -o atime=off "$DATASET_NAME"
TEST_DATASET_CREATED=1

TEST_MOUNTPOINT=$(zfs get -H -o value mountpoint "$DATASET_NAME")
[[ -n "$TEST_MOUNTPOINT" && -d "$TEST_MOUNTPOINT" ]] || die "Unable to determine mountpoint for $DATASET_NAME"
TEST_FILE="$TEST_MOUNTPOINT/zpool-stress.bin"

note "Running sequential write fio phase at $TEST_FILE"
run_maybe_timeout_logged "$SEQ_WRITE_JSON" "$SEQ_WRITE_TIMEOUT_SEC" \
  fio \
  --name seq_write \
  --directory "$TEST_MOUNTPOINT" \
  --filename zpool-stress.bin \
  --rw write \
  --bs 1M \
  --iodepth 16 \
  --direct 1 \
  --size "$FILE_SIZE" \
  --ioengine libaio \
  --output-format json

note "Running timed random read/write fio phase for ${RUNTIME_SEC}s"
run_timeout_logged "$RANDRW_JSON" $((RUNTIME_SEC + 120)) \
  fio \
  --name randrw \
  --directory "$TEST_MOUNTPOINT" \
  --filename zpool-stress.bin \
  --rw randrw \
  --rwmixread 70 \
  --bs 128k \
  --iodepth 32 \
  --direct 1 \
  --ioengine libaio \
  --time_based \
  --runtime "$RUNTIME_SEC" \
  --numjobs "$NUMJOBS" \
  --group_reporting \
  --output-format json

note "Running sequential read fio phase at $TEST_FILE"
run_maybe_timeout_logged "$SEQ_READ_JSON" "$SEQ_READ_TIMEOUT_SEC" \
  fio \
  --name seq_read \
  --directory "$TEST_MOUNTPOINT" \
  --filename zpool-stress.bin \
  --rw read \
  --bs 1M \
  --iodepth 16 \
  --direct 1 \
  --size "$FILE_SIZE" \
  --ioengine libaio \
  --output-format json

if (( RUN_SCRUB == 1 )); then
  note "Starting scrub on $POOL_NAME"
  zpool scrub "$POOL_NAME"
  if wait_for_scrub; then
    note 'Scrub completed or pool returned to a non-scrubbing state.'
  else
    note "Scrub still running after ${SCRUB_WAIT_SEC}s; leaving it in progress."
  fi
fi

note 'Capturing final pool state.'
run_logged "$STATUS_AFTER" zpool status "$POOL_NAME"
run_logged "$IOSTAT_AFTER" zpool iostat -v "$POOL_NAME" 1 2

note "Stress run complete. Reports written to: $REPORT_DIR"
