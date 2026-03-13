#!/usr/bin/env bash
set -euo pipefail

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

bash tools/host_preflight.sh --output-dir "$tmpdir"

[[ -f "$tmpdir/summary.txt" ]]
[[ -f "$tmpdir/lsblk.txt" ]]
[[ -f "$tmpdir/burnin_dry_run.txt" ]]

grep -q 'host preflight' "$tmpdir/summary.txt"
grep -q 'lsblk' "$tmpdir/lsblk.txt"
