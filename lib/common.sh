#!/usr/bin/env bash
set -Eeuo pipefail

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
