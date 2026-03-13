#!/usr/bin/env bash
set -Eeuo pipefail

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
  (( temp >= 50 )) && score=$((score - 10))
  (( temp >= 55 )) && score=$((score - 10))
  python3 - "$score" "$p99" "$mean" <<'PY'
import sys
score=float(sys.argv[1])
p99=float(sys.argv[2]) if sys.argv[2] not in ('NA','') else 0.0
mean=float(sys.argv[3]) if sys.argv[3] not in ('NA','') else 0.0
if p99 >= 150: score -= 25
elif p99 >= 80: score -= 15
elif p99 >= 40: score -= 8
if mean >= 20: score -= 12
elif mean >= 10: score -= 6
print(max(0, min(100, int(round(score)))))
PY
}

score_to_verdict() {
  local score=${1:-0}
  if (( score >= 90 )); then echo PASS
  elif (( score >= 75 )); then echo REVIEW
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
  (( temp >= 50 )) && reasons+=("drive temperature elevated")
  pyout=$(python3 - "$p99" "$mean" <<'PY'
import sys
p99=sys.argv[1]
mean=sys.argv[2]
out=[]
try:
    if p99 not in ('NA','') and float(p99) >= 80: out.append('high p99 latency')
    if mean not in ('NA','') and float(mean) >= 10: out.append('high average latency')
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
