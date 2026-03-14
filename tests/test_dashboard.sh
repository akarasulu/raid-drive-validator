#!/usr/bin/env bash
set -euo pipefail

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/state"

cat > "$tmpdir/state/sdb.state" <<'EOF'
stage=smart_long
updated=2026-03-13 20:46:57
message=SMART long self-test 10% complete
EOF

cat > "$tmpdir/state/sdc.state" <<'EOF'
stage=complete
updated=2026-03-13 20:48:08
message=Testing complete
EOF

cat > "$tmpdir/sdb_summary.json" <<'EOF'
{
  "device": "/dev/sdb",
  "qualification_status": "incomplete",
  "temperature_c": "36",
  "temperature_min_c": "31",
  "temperature_max_c": "42",
  "temperature_avg_c": "36.5",
  "reallocated": "0",
  "pending": "0",
  "uncorrectable": "0",
  "crc_errors": "0",
  "reliability_score": "69",
  "verdict": "REVIEW",
  "notes": "qualification incomplete due to timed out stages"
}
EOF

cat > "$tmpdir/sdc_summary.json" <<'EOF'
{
  "device": "/dev/sdc",
  "qualification_status": "complete",
  "temperature_c": "35",
  "temperature_min_c": "32",
  "temperature_max_c": "40",
  "temperature_avg_c": "35.2",
  "reallocated": "0",
  "pending": "0",
  "uncorrectable": "0",
  "crc_errors": "1",
  "reliability_score": "90",
  "verdict": "PASS",
  "notes": "CRC or bus errors observed"
}
EOF

output=$(DASHBOARD_ONCE=1 DASHBOARD_INTERVAL=0 bash dashboard/dashboard.sh "$tmpdir")

grep -q 'Drive Burn-in Dashboard' <<<"$output"
grep -q 'Workers: 2  Running: 1  Complete: 1' <<<"$output"
grep -q 'sdb' <<<"$output"
grep -q 'sdc' <<<"$output"
grep -q 'SMART long self-test 10% complete' <<<"$output"
grep -q 'Testing complete' <<<"$output"
grep -q 'incomplete' <<<"$output"
grep -q '31' <<<"$output"
grep -q '42' <<<"$output"
grep -q '36.5' <<<"$output"

cat > "$tmpdir/sdb_live_metrics.env" <<'EOF'
current_temp_c=37
min_temp_c=30
max_temp_c=44
avg_temp_c=36.8
sample_count=5
last_updated=2026-03-13 20:47:00
poll_interval_s=30
EOF

output=$(DASHBOARD_ONCE=1 DASHBOARD_INTERVAL=0 bash dashboard/dashboard.sh "$tmpdir")
grep -q '44' <<<"$output"
grep -q '36.8' <<<"$output"

cat > "$tmpdir/state/sde.state" <<'EOF'
stage=smart_health
updated=2026-03-13 20:49:00
message=Running SMART overall health check
EOF

cat > "$tmpdir/sde_report.txt" <<'EOF'
2026-03-13 20:49:00 Starting destructive qualification for /dev/sde
EOF

output=$(DASHBOARD_ONCE=1 DASHBOARD_INTERVAL=0 bash dashboard/dashboard.sh "$tmpdir")
grep -q 'sde' <<<"$output"
grep -q 'Running SMART overall health check' <<<"$output"
