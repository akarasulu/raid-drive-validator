#!/usr/bin/env bash
set -euo pipefail

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/state"

cat > "$tmpdir/sdb_report.txt" <<'EOF'
2026-03-13 16:00:00 Starting destructive qualification for /dev/sdb
NAME  SIZE MODEL              SERIAL   VENDOR
sdb   3.6T ST4000DM000-1F2168 Z300APEH ATA
2026-03-13 16:10:00 SMART long self-test polling wait timed out; continuing in smoke-test mode
123456789 bytes copied, 1 s, 123 MB/s 2026-03-13 16:11:00 optional thermal/mechanical stress timed out; continuing in smoke-test mode
EOF

cat > "$tmpdir/sdb_summary.json" <<'EOF'
{
  "device": "/dev/sdb",
  "qualification_status": "incomplete",
  "temperature_c": "35",
  "reallocated": "0",
  "pending": "0",
  "uncorrectable": "0",
  "crc_errors": "0",
  "latency_mean_ms": "NA",
  "latency_p99_ms": "NA",
  "throughput_mib_s": "NA",
  "reliability_score": "69",
  "verdict": "REVIEW",
  "notes": "qualification incomplete due to timed out stages",
  "timed_out_steps": [
    "SMART long self-test polling wait",
    "optional thermal/mechanical stress"
  ]
}
EOF

cat > "$tmpdir/state/sdb.state" <<'EOF'
stage=complete
updated=2026-03-13 16:10:00
message=Testing complete
EOF

bash tools/generate_drive_markdown_report.sh --report-dir "$tmpdir" --device /dev/sdb
[[ -f "$tmpdir/markdown/drives/sdb.md" ]]
grep -q '# Drive Report: sdb' "$tmpdir/markdown/drives/sdb.md"
grep -q 'Qualification Status | incomplete' "$tmpdir/markdown/drives/sdb.md"
grep -q 'Timed Out Steps' "$tmpdir/markdown/drives/sdb.md"
grep -q -- '- SMART long self-test polling wait timed out; continuing in smoke-test mode' "$tmpdir/markdown/drives/sdb.md"
grep -q -- '- optional thermal/mechanical stress timed out; continuing in smoke-test mode' "$tmpdir/markdown/drives/sdb.md"
if grep -q '123 MB/s 2026-03-13' "$tmpdir/markdown/drives/sdb.md"; then
  exit 1
fi

bash tools/generate_batch_markdown_summary.sh --report-dir "$tmpdir"
[[ -f "$tmpdir/markdown/summary.md" ]]
grep -q '# Batch Drive Summary' "$tmpdir/markdown/summary.md"
grep -q "\`sdb\`" "$tmpdir/markdown/summary.md"
grep -F -q "| \`sdb\` | incomplete | **REVIEW** | 69 |" "$tmpdir/markdown/summary.md"
