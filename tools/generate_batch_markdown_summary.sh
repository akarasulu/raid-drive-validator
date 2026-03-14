#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") --report-dir DIR

Generate a consolidated markdown summary across all completed drives.
USAGE
}

REPORT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-dir) REPORT_DIR=${2:?}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[[ -n "$REPORT_DIR" ]] || { usage >&2; exit 1; }

OUTPUT_DIR="$REPORT_DIR/markdown"
OUTPUT_FILE="$OUTPUT_DIR/summary.md"
mkdir -p "$OUTPUT_DIR"

python3 - "$REPORT_DIR" "$OUTPUT_FILE" <<'PY'
import json
import pathlib
import sys

report_dir = pathlib.Path(sys.argv[1])
output_file = pathlib.Path(sys.argv[2])
summary_files = sorted(report_dir.glob("*_summary.json"))

rows = []
counts = {"PASS": 0, "REVIEW": 0, "FAIL": 0, "OTHER": 0}

for path in summary_files:
    data = json.loads(path.read_text())
    verdict = data.get("verdict", "OTHER")
    counts[verdict if verdict in counts else "OTHER"] += 1
    dev = pathlib.Path(data.get("device", path.stem.replace("_summary", ""))).name
    rows.append({
        "device": dev,
        "qualification": data.get("qualification_status", "NA"),
        "verdict": verdict,
        "score": data.get("reliability_score", "NA"),
        "temp": data.get("temperature_c", "NA"),
        "temp_min": data.get("temperature_min_c", "NA"),
        "temp_max": data.get("temperature_max_c", "NA"),
        "temp_avg": data.get("temperature_avg_c", "NA"),
        "reallocated": data.get("reallocated", "NA"),
        "pending": data.get("pending", "NA"),
        "uncorrectable": data.get("uncorrectable", "NA"),
        "crc": data.get("crc_errors", "NA"),
        "notes": data.get("notes", ""),
        "report": f"drives/{dev}.md",
    })

rows.sort(key=lambda row: ({"FAIL": 0, "REVIEW": 1, "PASS": 2}.get(row["verdict"], 3), str(row["score"]), row["device"]))

lines = [
    "# Batch Drive Summary",
    "",
    "## Totals",
    "",
    "| Verdict | Count |",
    "| --- | --- |",
    f"| PASS | {counts['PASS']} |",
    f"| REVIEW | {counts['REVIEW']} |",
    f"| FAIL | {counts['FAIL']} |",
    "",
    "## Drives",
    "",
    "| Device | Qualification | Verdict | Score | Temp | Min | Max | Avg | Realloc | Pending | Uncorrectable | CRC | Report | Notes |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
]

for row in rows:
    lines.append(
        f"| `{row['device']}` | {row['qualification']} | **{row['verdict']}** | {row['score']} | {row['temp']} | "
        f"{row['temp_min']} | {row['temp_max']} | {row['temp_avg']} | "
        f"{row['reallocated']} | {row['pending']} | {row['uncorrectable']} | {row['crc']} | "
        f"[drive report]({row['report']}) | {row['notes']} |"
    )

output_file.write_text("\n".join(lines) + "\n")
PY
