#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../pulse-stats-helper.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export PULSE_STATS_FILE="${TMP_DIR}/pulse-stats.json"

python3 - "$PULSE_STATS_FILE" <<'PY'
import json
import sys

json.dump({
    'counters': {'pulse_merge_branchprotect_404_skips': [1, 2]},
    'gauges': {
        'pulse_merge_zero_progress_cycles': {'value': 0, 'ts': 123},
        'pulse_merge_eligible_stuck_pr_count': {'value': 4, 'ts': 124},
    },
}, open(sys.argv[1], 'w'))
PY

gauge_value="$("$HELPER" get-gauge pulse_merge_zero_progress_cycles)"
[[ "$gauge_value" == "0" ]]

missing_gauge_value="$("$HELPER" get-gauge missing_gauge)"
[[ "$missing_gauge_value" == "0" ]]

status_output="${TMP_DIR}/status.txt"
"$HELPER" status >"$status_output"
grep -q 'Pulse Gauges:' "$status_output"
grep -q 'pulse_merge_zero_progress_cycles' "$status_output"
grep -q 'pulse_merge_eligible_stuck_pr_count' "$status_output"

help_output="${TMP_DIR}/help.txt"
"$HELPER" help >"$help_output"
grep -q 'get-gauge <gauge>' "$help_output"

printf '' >"$PULSE_STATS_FILE"
# shellcheck disable=SC1090
source "$HELPER"
pulse_stats_set_gauge pulse_merge_zero_progress_cycles 0
gauge_value="$("$HELPER" get-gauge pulse_merge_zero_progress_cycles)"
[[ "$gauge_value" == "0" ]]

printf 'PASS pulse-stats-helper\n'
