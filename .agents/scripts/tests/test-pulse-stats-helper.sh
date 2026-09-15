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

malformed_fixture="${TMP_DIR}/malformed-original"
printf '{"counters":{}}\n{"orphaned":[1,2]}\n' >"$PULSE_STATS_FILE"
command cp "$PULSE_STATS_FILE" "$malformed_fixture"
pulse_stats_increment recovered_increment

python3 - "$PULSE_STATS_FILE" <<'PY'
import json
import sys
import time

with open(sys.argv[1]) as fh:
    data = json.load(fh)
events = data['counters']['recovered_increment']
assert len(events) == 1
assert abs(time.time() - events[0]) < 10
PY
shopt -s nullglob
quarantines=("$PULSE_STATS_FILE".corrupt.*)
shopt -u nullglob
[[ ${#quarantines[@]} -eq 1 ]]
cmp "$malformed_fixture" "${quarantines[0]}"
quarantine_mode=$(stat -f '%Lp' "${quarantines[0]}" 2>/dev/null || stat -c '%a' "${quarantines[0]}")
[[ "$quarantine_mode" == "600" ]]

printf '{"counters":{}} trailing-invalid\n' >"$PULSE_STATS_FILE"
pulse_stats_set_gauge recovered_gauge 7
jq -e '.gauges.recovered_gauge.value == 7 and (.counters | type == "object")' "$PULSE_STATS_FILE" >/dev/null

printf '{"counters":{}} cannot-quarantine\n' >"$PULSE_STATS_FILE"
command cp "$PULSE_STATS_FILE" "${TMP_DIR}/unrecoverable-original"
recovery_error="${TMP_DIR}/recovery-error.txt"
fail_cp_bin="${TMP_DIR}/fail-cp-bin"
mkdir "$fail_cp_bin"
cat >"${fail_cp_bin}/cp" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "${fail_cp_bin}/cp"
_PULSE_STATS_RECOVERY_FAILURE_REPORTED=""
PATH="${fail_cp_bin}:${PATH}" pulse_stats_increment unrecoverable_increment 2>"$recovery_error"
cmp "${TMP_DIR}/unrecoverable-original" "$PULSE_STATS_FILE"
grep -q 'Pulse stats recovery failed (quarantine-copy)' "$recovery_error"

printf '{"counters":{"obsolete":[1]}} reset-trailing-data\n' >"$PULSE_STATS_FILE"
pulse_stats_reset obsolete >/dev/null
jq -e '. == {"counters":{}}' "$PULSE_STATS_FILE" >/dev/null

original_stats_file="$PULSE_STATS_FILE"
PULSE_STATS_FILE="${TMP_DIR}/fresh/nested/pulse-stats.json"
pulse_stats_increment first_write
jq -e '.counters.first_write | length == 1' "$PULSE_STATS_FILE" >/dev/null
PULSE_STATS_FILE="$original_stats_file"

mkdir "${PULSE_STATS_FILE}.lock"
printf 'truncated-owner\n' >"${PULSE_STATS_FILE}.lock/owner.pid"
pulse_stats_increment stale_lock_recovered
jq -e '.counters.stale_lock_recovered | length == 1' "$PULSE_STATS_FILE" >/dev/null

printf '{"counters":{}}\n' >"$PULSE_STATS_FILE"
for index in {1..20}; do
	"$HELPER" increment "concurrent_${index}" &
done
wait
jq -e '[.counters | to_entries[] | select(.key | startswith("concurrent_"))] | length == 20' "$PULSE_STATS_FILE" >/dev/null

python3 - "$PULSE_STATS_FILE" <<'PY'
import json
import sys

json.dump({'counters': {}, 'gauges': {}}, open(sys.argv[1], 'w'))
PY
FAKE_BIN="${TMP_DIR}/bin"
mkdir -p "$FAKE_BIN"
cat >"${FAKE_BIN}/jq" <<'SH'
#!/usr/bin/env bash
exit 42
SH
chmod +x "${FAKE_BIN}/jq"
PATH="${FAKE_BIN}:${PATH}" _pulse_stats_ensure_file
python3 - "$PULSE_STATS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    data = json.load(fh)
assert data == {'counters': {}, 'gauges': {}}
PY

printf 'PASS pulse-stats-helper\n'
