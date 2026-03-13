#!/usr/bin/env bash
set -Eeuo pipefail

any_term_matches() {
  local haystack=$1
  shift || true
  local needle
  for needle in "$@"; do
    [[ -n "$needle" ]] || continue
    [[ $haystack == *"$needle"* ]] && return 0
  done
  return 1
}

discover_matching_drives() {
  local model_filters=${1:-}
  local size_filters=${2:-}
  local -a model_terms=()
  local -a size_terms=()
  local model_text

  [[ -n "$model_filters" ]] && IFS=$'\n' read -r -d '' -a model_terms < <(printf '%s\0' "$model_filters")
  [[ -n "$size_filters" ]] && IFS=$'\n' read -r -d '' -a size_terms < <(printf '%s\0' "$size_filters")

  while read -r line; do
    eval "$line"
    [[ ${TYPE:-} == disk ]] || continue
    if [[ ${#model_terms[@]} -gt 0 ]]; then
      model_text="${MODEL:-} ${VENDOR:-}"
      any_term_matches "$model_text" "${model_terms[@]}" || continue
    fi
    if [[ ${#size_terms[@]} -gt 0 ]]; then
      any_term_matches "${SIZE:-}" "${size_terms[@]}" || continue
    fi
    printf '/dev/%s\n' "$NAME"
  done < <(lsblk -d -P -o NAME,SIZE,MODEL,VENDOR,TYPE)
}
