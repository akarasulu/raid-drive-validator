#!/usr/bin/env bash
set -Eeuo pipefail

: "${MAX_TEMP_C:=50}"
: "${WARN_TEMP_C:=45}"
: "${REVIEW_SCORE_MIN:=75}"
: "${PASS_SCORE_MIN:=90}"
: "${LATENCY_P99_WARN_MS:=80}"
: "${LATENCY_MEAN_WARN_MS:=10}"

safe_num() {
  case "$1" in
    ''|NA|null) printf '0\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

latency_p99_from_fio_json() {
  local file=$1
  python3 - "$file" <<'PY'
import json,sys
p=sys.argv[1]
try:
    data=json.load(open(p))
    job=data['jobs'][0]['read']
    ns=job.get('clat_ns') or job.get('lat_ns') or {}
    p99=ns.get('percentile',{}).get('99.000000')
    print('NA' if p99 is None else round(float(p99)/1_000_000,3))
except Exception:
    print('NA')
PY
}

latency_mean_from_fio_json() {
  local file=$1
  python3 - "$file" <<'PY'
import json,sys
p=sys.argv[1]
try:
    data=json.load(open(p))
    job=data['jobs'][0]['read']
    ns=(job.get('clat_ns') or job.get('lat_ns') or {}).get('mean')
    print('NA' if ns is None else round(float(ns)/1_000_000,3))
except Exception:
    print('NA')
PY
}

latency_bw_mib_from_fio_json() {
  local file=$1
  python3 - "$file" <<'PY'
import json,sys
p=sys.argv[1]
try:
    data=json.load(open(p))
    bw=data['jobs'][0]['read'].get('bw',None)
    print('NA' if bw is None else round(float(bw)/1024,2))
except Exception:
    print('NA')
PY
}

compute_reliability_score() {
  local realloc pending uncorr crc temp p99 mean score
  realloc=$(safe_num "$1")
  pending=$(safe_num "$2")
  uncorr=$(safe_num "$3")
  crc=$(safe_num "$4")
  temp=$(safe_num "$5")
  p99=$(safe_num "$6")
  mean=$(safe_num "$7")
  score=100
  (( realloc > 0 )) && score=$((score - 35))
  (( pending > 0 )) && score=$((score - 45))
  (( uncorr > 0 )) && score=$((score - 55))
  (( crc > 0 )) && score=$((score - 10))
  (( temp >= WARN_TEMP_C )) && score=$((score - 10))
  (( temp >= MAX_TEMP_C )) && score=$((score - 10))
  python3 - "$score" "$p99" "$mean" "$LATENCY_P99_WARN_MS" "$LATENCY_MEAN_WARN_MS" <<'PY'
import sys
score=float(sys.argv[1])
p99=float(sys.argv[2]) if sys.argv[2] not in ('NA','') else 0.0
mean=float(sys.argv[3]) if sys.argv[3] not in ('NA','') else 0.0
p99_warn=float(sys.argv[4])
mean_warn=float(sys.argv[5])
if p99 >= (p99_warn * 1.875): score -= 25
elif p99 >= p99_warn: score -= 15
elif p99 >= 40: score -= 8
if mean >= (mean_warn * 2): score -= 12
elif mean >= mean_warn: score -= 6
print(max(0, min(100, int(round(score)))))
PY
}

score_to_verdict() {
  local score=${1:-0}
  if (( score >= PASS_SCORE_MIN )); then echo PASS
  elif (( score >= REVIEW_SCORE_MIN )); then echo REVIEW
  else echo FAIL
  fi
}

score_to_reason_text() {
  local realloc pending uncorr crc temp p99 mean pyout
  realloc=$(safe_num "$1")
  pending=$(safe_num "$2")
  uncorr=$(safe_num "$3")
  crc=$(safe_num "$4")
  temp=$(safe_num "$5")
  p99=$(safe_num "$6")
  mean=$(safe_num "$7")
  local reasons=()
  (( realloc > 0 )) && reasons+=("reallocated sectors present")
  (( pending > 0 )) && reasons+=("pending sectors present")
  (( uncorr > 0 )) && reasons+=("offline uncorrectable sectors present")
  (( crc > 0 )) && reasons+=("CRC or bus errors observed")
  (( temp >= WARN_TEMP_C )) && reasons+=("drive temperature elevated")
  pyout=$(python3 - "$p99" "$mean" "$LATENCY_P99_WARN_MS" "$LATENCY_MEAN_WARN_MS" <<'PY'
import sys
p99=sys.argv[1]
mean=sys.argv[2]
p99_warn=float(sys.argv[3])
mean_warn=float(sys.argv[4])
out=[]
try:
    if p99 not in ('NA','') and float(p99) >= p99_warn: out.append('high p99 latency')
    if mean not in ('NA','') and float(mean) >= mean_warn: out.append('high average latency')
except Exception:
    pass
print('|'.join(out))
PY
)
  if [[ -n "$pyout" ]]; then
    local extra
    IFS='|' read -r -a extra <<< "$pyout"
    reasons+=("${extra[@]}")
  fi
  if [[ ${#reasons[@]} -eq 0 ]]; then
    echo "no significant reliability concerns detected"
  else
    printf '%s; ' "${reasons[@]}" | sed 's/; $//'
  fi
}
