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

usage() {
  cat <<USAGE
Usage: $(basename "$0") --pool-name NAME [options]

Build a RAIDZ2 zpool command from explicitly listed devices or from the same
model/size discovery rules used by the burn-in tooling.

Options:
  --pool-name NAME       Required zpool name
  --devices CSV          Comma-separated device list; bypasses discovery
  --model STRING         Model/vendor substring filter; repeat for OR matching
  --size SIZE            Size substring filter; repeat for OR matching
  --drive-count N        RAIDZ2 member count (default: 8)
  --spare-count N        Hot spare count (default: 1)
  --wwn                  Prefer wwn-* links instead of device-name links
  --ashift N             zpool ashift value (default: 12)
  --mountpoint PATH      Set the root dataset mountpoint via -O mountpoint=...
  --altroot PATH         Pass -R PATH to zpool create
  --force                Pass -f to zpool create
  --execute              Run zpool create instead of only printing the command
  --help                 Show this help

Environment:
  DISK_BY_ID_DIR         Override /dev/disk/by-id (mainly useful for tests)

Examples:
  $(basename "$0") --pool-name backup --model ST4000 --model HGST --size 3.6T
  $(basename "$0") --pool-name backup --devices /dev/sdb,/dev/sdc,/dev/sdd,/dev/sde,/dev/sdf --drive-count 4 --spare-count 1 --execute
USAGE
}

POOL_NAME=""
DEVICE_CSV=""
DRIVE_COUNT=8
SPARE_COUNT=1
ASHIFT=12
MOUNTPOINT=""
ALTROOT=""
FORCE=0
EXECUTE=0
PREFER_WWN=0
DISK_BY_ID_DIR=${DISK_BY_ID_DIR:-/dev/disk/by-id}
declare -a MODEL_FILTERS=()
declare -a SIZE_FILTERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool-name) POOL_NAME=${2:?}; shift 2 ;;
    --devices) DEVICE_CSV=${2:?}; shift 2 ;;
    --model) MODEL_FILTERS+=("${2:?}"); shift 2 ;;
    --size) SIZE_FILTERS+=("${2:?}"); shift 2 ;;
    --drive-count) DRIVE_COUNT=${2:?}; shift 2 ;;
    --spare-count) SPARE_COUNT=${2:?}; shift 2 ;;
    --wwn) PREFER_WWN=1; shift ;;
    --ashift) ASHIFT=${2:?}; shift 2 ;;
    --mountpoint) MOUNTPOINT=${2:?}; shift 2 ;;
    --altroot) ALTROOT=${2:?}; shift 2 ;;
    --force) FORCE=1; shift ;;
    --execute) EXECUTE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$POOL_NAME" ]] || die '--pool-name is required'
[[ $DRIVE_COUNT =~ ^[0-9]+$ ]] || die '--drive-count must be an integer'
[[ $SPARE_COUNT =~ ^[0-9]+$ ]] || die '--spare-count must be an integer'
[[ $ASHIFT =~ ^[0-9]+$ ]] || die '--ashift must be an integer'
(( DRIVE_COUNT >= 4 )) || die 'RAIDZ2 requires at least 4 drives'

if [[ -n "$DEVICE_CSV" && ( ${#MODEL_FILTERS[@]} -gt 0 || ${#SIZE_FILTERS[@]} -gt 0 ) ]]; then
  die 'Use either --devices or discovery filters, not both'
fi

if [[ -z "$DEVICE_CSV" && ${#MODEL_FILTERS[@]} -eq 0 && ${#SIZE_FILTERS[@]} -eq 0 ]]; then
  die 'Specify --devices or at least one discovery filter'
fi

split_csv_devices() {
  local csv=$1
  local -a parsed=()
  IFS=',' read -r -a parsed <<< "$csv"
  printf '%s\n' "${parsed[@]}"
}

select_best_by_id() {
  local device=$1
  local canonical
  local candidate
  local target
  local base
  local priority
  local -a ranked=()

  canonical=$(readlink -f -- "$device") || die "Unable to resolve device: $device"

  shopt -s nullglob
  for candidate in "$DISK_BY_ID_DIR"/*; do
    [[ -L "$candidate" ]] || continue
    base=${candidate##*/}
    [[ $base == *-part* ]] && continue
    target=$(readlink -f -- "$candidate" 2>/dev/null || true)
    [[ -n "$target" && $target == "$canonical" ]] || continue
    if (( PREFER_WWN == 1 )); then
      case "$base" in
        wwn-*) priority=0 ;;
        ata-*) priority=1 ;;
        scsi-*) priority=2 ;;
        nvme-*) priority=3 ;;
        *) priority=9 ;;
      esac
    else
      case "$base" in
        ata-*) priority=0 ;;
        scsi-*) priority=1 ;;
        nvme-*) priority=2 ;;
        wwn-*) priority=3 ;;
        *) priority=9 ;;
      esac
    fi
    ranked+=("${priority}:${candidate}")
  done
  shopt -u nullglob

  [[ ${#ranked[@]} -gt 0 ]] || die "No /dev/disk/by-id entry found for $device"

  printf '%s\n' "${ranked[@]}" | sort | head -n 1 | cut -d: -f2-
}

require_unique_devices() {
  local label=$1
  shift
  local value
  declare -A seen=()
  for value in "$@"; do
    [[ -n "$value" ]] || continue
    if [[ -n ${seen["$value"]+x} ]]; then
      die "Duplicate $label detected: $value"
    fi
    seen["$value"]=1
  done
}

declare -a MATCHED_DEVICES=()
declare -a MATCHED_BY_ID=()
declare -a RAIDZ2_BY_ID=()
declare -a SPARE_BY_ID=()
EXPECTED_TOTAL=$((DRIVE_COUNT + SPARE_COUNT))

if [[ -n "$DEVICE_CSV" ]]; then
  mapfile -t MATCHED_DEVICES < <(split_csv_devices "$DEVICE_CSV")
else
  mapfile -t MATCHED_DEVICES < <(discover_matching_drives \
    "$(printf '%s\n' "${MODEL_FILTERS[@]}")" \
    "$(printf '%s\n' "${SIZE_FILTERS[@]}")")
fi

[[ ${#MATCHED_DEVICES[@]} -gt 0 ]] || die 'No matching drives found'
require_unique_devices devices "${MATCHED_DEVICES[@]}"

if [[ ${#MATCHED_DEVICES[@]} -ne $EXPECTED_TOTAL ]]; then
  {
    printf 'Matched drives (%s) did not equal required total (%s raidz2 + %s spare = %s):\n' \
      "${#MATCHED_DEVICES[@]}" "$DRIVE_COUNT" "$SPARE_COUNT" "$EXPECTED_TOTAL"
    printf '  %s\n' "${MATCHED_DEVICES[@]}"
  } >&2
  exit 1
fi

for device in "${MATCHED_DEVICES[@]}"; do
  MATCHED_BY_ID+=("$(select_best_by_id "$device")")
done

require_unique_devices "by-id paths" "${MATCHED_BY_ID[@]}"

RAIDZ2_BY_ID=("${MATCHED_BY_ID[@]:0:DRIVE_COUNT}")
if (( SPARE_COUNT > 0 )); then
  SPARE_BY_ID=("${MATCHED_BY_ID[@]:DRIVE_COUNT:SPARE_COUNT}")
fi

declare -a CMD=(zpool create -o "ashift=$ASHIFT")
(( FORCE == 1 )) && CMD+=(-f)
[[ -n "$ALTROOT" ]] && CMD+=(-R "$ALTROOT")
[[ -n "$MOUNTPOINT" ]] && CMD+=(-O "mountpoint=$MOUNTPOINT")
CMD+=("$POOL_NAME" raidz2 "${RAIDZ2_BY_ID[@]}")
if (( SPARE_COUNT > 0 )); then
  CMD+=(spare "${SPARE_BY_ID[@]}")
fi

{
  printf 'Selected RAIDZ2 members:\n'
  for ((idx = 0; idx < DRIVE_COUNT; idx++)); do
    printf '  %s -> %s\n' "${MATCHED_DEVICES[$idx]}" "${MATCHED_BY_ID[$idx]}"
  done
  if (( SPARE_COUNT > 0 )); then
    printf 'Selected hot spares:\n'
    for ((idx = DRIVE_COUNT; idx < EXPECTED_TOTAL; idx++)); do
      printf '  %s -> %s\n' "${MATCHED_DEVICES[$idx]}" "${MATCHED_BY_ID[$idx]}"
    done
  fi
  printf '\n'
} >&2

if (( EXECUTE == 1 )); then
  require_root
  require_tools zpool lsblk readlink sort
  "${CMD[@]}"
else
  printf '%q' "${CMD[0]}"
  for ((i = 1; i < ${#CMD[@]}; i++)); do
    printf ' %q' "${CMD[$i]}"
  done
  printf '\n'
fi
