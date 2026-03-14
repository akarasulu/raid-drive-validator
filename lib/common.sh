#!/usr/bin/env bash
set -Eeuo pipefail

# Non-login SSH shells may omit sbin directories from PATH.
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"

timestamp() { date '+%F %T'; }
header() { printf '\n===== %s =====\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run as root'; }
require_tools() {
  local missing=()
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}"
  fi
}

load_runtime_config() {
  local config_path=""
  local candidate

  if [[ -n "${RAID_DRIVE_VALIDATOR_CONFIG:-}" ]]; then
    config_path=$RAID_DRIVE_VALIDATOR_CONFIG
  else
    for candidate in \
      /etc/raid-drive-validator/burnin.conf \
      "${ROOT_DIR:-}/config/burnin.conf"
    do
      [[ -n "$candidate" && -f "$candidate" ]] || continue
      config_path=$candidate
      break
    done
  fi

  [[ -n "$config_path" && -f "$config_path" ]] || return 0

  while IFS='=' read -r key value; do
    [[ -n "${key:-}" ]] || continue
    [[ $key =~ ^[A-Z0-9_]+$ ]] || continue
    [[ -n "${value:-}" ]] || continue
    [[ $value =~ ^[0-9]+$ ]] || continue

    case "$key" in
      MAX_TEMP_C|WARN_TEMP_C|REVIEW_SCORE_MIN|PASS_SCORE_MIN|LATENCY_P99_WARN_MS|LATENCY_MEAN_WARN_MS)
        printf -v "$key" '%s' "$value"
        export "$key=$value"
        ;;
    esac
  done < <(grep -E '^[A-Z0-9_]+=[0-9]+$' "$config_path")
}

load_runtime_config
