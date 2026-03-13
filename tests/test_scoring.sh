#!/usr/bin/env bash
set -euo pipefail
source ./lib/scoring.sh
score=$(compute_reliability_score 0 0 0 0 35 5 2)
[[ "$score" -ge 90 ]]
echo "score smoke test passed: $score"
