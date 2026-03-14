#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") --report-dir DIR --device /dev/sdX

Generate a markdown report for one completed drive run.
USAGE
}

REPORT_DIR=""
DEVICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-dir) REPORT_DIR=${2:?}; shift 2 ;;
    --device) DEVICE=${2:?}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[[ -n "$REPORT_DIR" && -n "$DEVICE" ]] || { usage >&2; exit 1; }

DEVICE_BASENAME=$(basename -- "$DEVICE")
REPORT_FILE="$REPORT_DIR/${DEVICE_BASENAME}_report.txt"
JSON_FILE="$REPORT_DIR/${DEVICE_BASENAME}_summary.json"
STATE_FILE="$REPORT_DIR/state/${DEVICE_BASENAME}.state"
OUTPUT_DIR="$REPORT_DIR/markdown/drives"
OUTPUT_FILE="$OUTPUT_DIR/${DEVICE_BASENAME}.md"

[[ -f "$REPORT_FILE" ]] || { printf 'Missing report file: %s\n' "$REPORT_FILE" >&2; exit 1; }
[[ -f "$JSON_FILE" ]] || { printf 'Missing summary json: %s\n' "$JSON_FILE" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"

python3 - "$DEVICE" "$REPORT_FILE" "$JSON_FILE" "$STATE_FILE" "$OUTPUT_FILE" <<'PY'
import json
import pathlib
import re
import sys

device, report_path, json_path, state_path, output_path = sys.argv[1:]
report_text = pathlib.Path(report_path).read_text()
summary = json.loads(pathlib.Path(json_path).read_text())
state_text = pathlib.Path(state_path).read_text() if pathlib.Path(state_path).exists() else ""

def state_value(name: str) -> str:
    match = re.search(rf"^{re.escape(name)}=(.*)$", state_text, re.M)
    return match.group(1).strip() if match else "NA"

timed_out_steps = []
for match in re.finditer(
    r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} (.+? timed out; continuing in smoke-test mode)",
    report_text,
):
    timed_out_steps.append(match.group(1).strip())

device_table_match = re.search(r"^NAME\s+SIZE\s+MODEL\s+SERIAL\s+VENDOR\s*\n(.+)$", report_text, re.M)
device_table = device_table_match.group(0).strip() if device_table_match else "Unavailable"

latency_log_name = pathlib.Path(report_path).stem.replace("_report", "_latency") + ".log"
lines = [
    f"# Drive Report: {pathlib.Path(device).name}",
    "",
    "## Outcome",
    "",
    "| Field | Value |",
    "| --- | --- |",
    f"| Device | `{summary.get('device', device)}` |",
    f"| Qualification Status | {summary.get('qualification_status', 'NA')} |",
    f"| Verdict | **{summary.get('verdict', 'NA')}** |",
    f"| Reliability Score | {summary.get('reliability_score', 'NA')} |",
    f"| Current Temperature (C) | {summary.get('temperature_c', 'NA')} |",
    f"| Minimum Temperature (C) | {summary.get('temperature_min_c', 'NA')} |",
    f"| Maximum Temperature (C) | {summary.get('temperature_max_c', 'NA')} |",
    f"| Average Temperature (C) | {summary.get('temperature_avg_c', 'NA')} |",
    f"| Reallocated Sectors | {summary.get('reallocated', 'NA')} |",
    f"| Pending Sectors | {summary.get('pending', 'NA')} |",
    f"| Offline Uncorrectable | {summary.get('uncorrectable', 'NA')} |",
    f"| CRC Errors | {summary.get('crc_errors', 'NA')} |",
    f"| Mean Latency (ms) | {summary.get('latency_mean_ms', 'NA')} |",
    f"| P99 Latency (ms) | {summary.get('latency_p99_ms', 'NA')} |",
    f"| Throughput (MiB/s) | {summary.get('throughput_mib_s', 'NA')} |",
    f"| Final State | {state_value('stage')} |",
    "",
    "## Notes",
    "",
    summary.get("notes", "No notes captured."),
    "",
    "## Device Snapshot",
    "",
    "```text",
    device_table,
    "```",
    "",
]

timed_out_steps = summary.get("timed_out_steps") or timed_out_steps
timed_out_steps = [
    step if "timed out; continuing in smoke-test mode" in step
    else f"{step} timed out; continuing in smoke-test mode"
    for step in timed_out_steps
]
if timed_out_steps:
    lines.extend([
        "## Timed Out Steps",
        "",
        *[f"- {step}" for step in timed_out_steps],
        "",
    ])

lines.extend([
    "## Artifacts",
    "",
    f"- Raw report: `{pathlib.Path(report_path).name}`",
    f"- JSON summary: `{pathlib.Path(json_path).name}`",
    f"- Latency log: `{latency_log_name}`",
])

pathlib.Path(output_path).write_text("\n".join(lines) + "\n")
PY
