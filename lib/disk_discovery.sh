#!/usr/bin/env bash
set -Eeuo pipefail

discover_matching_drives() {
  local model_filter=${1:-}
  local size_filter=${2:-}
  while read -r line; do
    eval "$line"
    [[ ${TYPE:-} == disk ]] || continue
    if [[ -n "$model_filter" ]]; then
      [[ ${MODEL:-} == *"$model_filter"* || ${VENDOR:-} == *"$model_filter"* ]] || continue
    fi
    if [[ -n "$size_filter" ]]; then
      [[ ${SIZE:-} == *"$size_filter"* ]] || continue
    fi
    printf '/dev/%s\n' "$NAME"
  done < <(lsblk -d -P -o NAME,SIZE,MODEL,VENDOR,TYPE)
}
