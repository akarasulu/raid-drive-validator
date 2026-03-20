#!/usr/bin/env bash
set -euo pipefail

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

plan_output=$(
  bash tools/stress_zpool.sh \
    --pool-name backup \
    --dataset backup/test-stress \
    --report-dir "$tmpdir/report" \
    --file-size 2G \
    --runtime-sec 60 \
    --jobs 2 \
    --seq-write-timeout-sec 600 \
    --seq-read-timeout-sec 900 \
    --scrub
)

[[ "$plan_output" == *'zpool status backup'* ]]
[[ "$plan_output" == *'zfs create -o compression=off -o atime=off backup/test-stress'* ]]
[[ "$plan_output" == *'timeout 600s fio --name seq_write'* ]]
[[ "$plan_output" == *'fio --name randrw'* ]]
[[ "$plan_output" == *'--time_based --runtime 60'* ]]
[[ "$plan_output" != *'--time_based 1'* ]]
[[ "$plan_output" == *'--group_reporting --output-format json'* ]]
[[ "$plan_output" != *'--group_reporting 1'* ]]
[[ "$plan_output" == *'timeout 900s fio --name seq_read'* ]]
[[ "$plan_output" == *'zpool scrub backup'* ]]
[[ -f "$tmpdir/report/summary.txt" ]]
grep -q 'pool: backup' "$tmpdir/report/summary.txt"
grep -q 'seq_write_timeout_sec: 600' "$tmpdir/report/summary.txt"
grep -q 'seq_read_timeout_sec: 900' "$tmpdir/report/summary.txt"

plan_no_timeout=$(
  bash tools/stress_zpool.sh \
    --pool-name backup \
    --dataset backup/test-stress-2 \
    --report-dir "$tmpdir/report2" \
    --file-size 2G \
    --runtime-sec 60 \
    --jobs 2 \
    --seq-write-timeout-sec 0 \
    --seq-read-timeout-sec 0
)

[[ "$plan_no_timeout" != *'timeout 0s fio --name seq_write'* ]]
[[ "$plan_no_timeout" == *'fio --name seq_write --directory \<mountpoint\>'* ]]
[[ "$plan_no_timeout" != *'timeout 0s fio --name seq_read'* ]]

if bash tools/stress_zpool.sh --pool-name backup --runtime-sec 0 >/dev/null 2>&1; then
  echo "expected runtime validation failure"
  exit 1
fi

echo "zpool stress helper tests passed"
