#!/usr/bin/env bash
set -euo pipefail

if rg -n -- '--(time_based|group_reporting)(=| )1\b' \
  bin/drive_burnin_test.sh tools/stress_zpool.sh >/dev/null; then
  echo "forbidden fio boolean flag usage found"
  exit 1
fi

echo "fio boolean flag usage tests passed"
