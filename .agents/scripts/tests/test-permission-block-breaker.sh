#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#36033: isolated local metadata fixtures; no GitHub calls or real dossiers.
set -euo pipefail

SCRIPTS_DIR=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
# shellcheck source=../pulse-wrapper-dispatch-gates.sh
source "$SCRIPTS_DIR/pulse-wrapper-dispatch-gates.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT"
mkdir -p "$HOME/.aidevops/logs"
export LOGFILE="$HOME/.aidevops/logs/pulse.log"
BLOCKERS="$HOME/.aidevops/logs/worker-progress-blockers.jsonl"
STATS="$TEST_ROOT/stats"
NOW=100000
PASSED=0

date() {
	printf '%s\n' "$NOW"
	return 0
}

pulse_stats_increment() {
	local counter="$1"
	printf '%s\n' "$counter" >>"$STATS"
	return 0
}

reset_fixture() {
	rm -f "${BLOCKERS}.permission-breaker.state"
	: >"$BLOCKERS"
	: >"$LOGFILE"
	: >"$STATS"
	NOW=100000
	unset AIDEVOPS_PERMISSION_BLOCK_WINDOW_SECS AIDEVOPS_PERMISSION_BLOCK_WINDOW_MAX
	unset AIDEVOPS_SKIP_PERMISSION_BLOCK_BREAKER AIDEVOPS_WORKER_BLOCKER_LOG_FILE
	return 0
}

event() {
	local issue="$1" ts="${2:-100000}" repo="${3:-owner/repo}"
	local reason="${4:-permission_required}" kind="${5:-terminal_blocker_captured}"
	jq -nc --arg issue "$issue" --argjson ts "$ts" --arg repo "$repo" \
		--arg reason "$reason" --arg event "$kind" \
		'{issue_number:$issue, ts:$ts, repo_slug:$repo, reason:$reason, event:$event,
		 detail:"SENSITIVE_SENTINEL", dossier:"DO_NOT_OPEN"}' >>"$BLOCKERS"
	return 0
}

expect() {
	local expected="$1" label="$2" rc=0
	is_permission_block_rate_acceptable || rc=$?
	if [[ "$rc" != "$expected" ]]; then
		printf 'FAIL: %s (expected %s, got %s)\n' "$label" "$expected" "$rc" >&2
		exit 1
	fi
	PASSED=$((PASSED + 1))
	printf 'PASS: %s\n' "$label"
	return 0
}

reset_fixture
expect 0 'empty log'
event 1
event 2
expect 0 'two distinct issues do not trip'
event 3
expect 1 'three distinct issues trip'
[[ "$(wc -l <"$LOGFILE")" -eq 1 ]]
[[ "$(<"$STATS")" == pulse_dispatch_permission_block_breaker_tripped ]]
[[ "$(<"$LOGFILE")" == '[pulse-wrapper] permission_block breaker: count=3 max=3 window_secs=1800 pause_secs=3600' ]]
NOW=101801
expect 1 'pause survives events leaving current rolling window'
NOW=103599
expect 1 'pause lasts until latest counted event plus one hour'
NOW=103600
expect 0 'pause expires at one hour'

reset_fixture
event null
event 0
printf '%s\n' '{"event":"terminal_blocker_captured","reason":"permission_required","ts":100000,"issue_number":9,"repo_slug":""}' >>"$BLOCKERS"
printf '%s\n' '{"event":"terminal_blocker_captured","reason":"permission_required","ts":100000,"issue_number":null,"repo_slug":null}' >>"$BLOCKERS"
expect 0 'identifier-less events do not count'
event 1
event 2
expect 0 'identifier-less events do not inflate distinct count'
event 3
expect 1 'identifier-less events do not mask three valid distinct issues'

reset_fixture
event 1
event 2
event 3
printf '%s\n' '{"event":"terminal_blocker_captured","reason":"permission_required","ts":"invalid","issue_number":null}' >>"$BLOCKERS"
expect 0 'invalid timestamp fails open even without identifiers'
[[ "$(<"$LOGFILE")" == *'missing or malformed log; failing open'* ]]

reset_fixture
export AIDEVOPS_WORKER_BLOCKER_LOG_FILE="$TEST_ROOT/custom-blockers.jsonl"
default_blockers="$BLOCKERS"
BLOCKERS="$AIDEVOPS_WORKER_BLOCKER_LOG_FILE"
rm -f "${BLOCKERS}.permission-breaker.state"
event 1
event 2
event 3
expect 1 'configured blocker log trips while default log is empty'
# Simulate bounded rotation evicting all triggering events.
: >"$BLOCKERS"
event 4 100100 owner/repo unknown
NOW=103599
expect 1 'persisted trip survives rotation until full pause expires'
# A fresh shell must use the persisted trip, not process-local state.
rc=0
bash -c 'source "$1"; date() { printf "%s\n" 103599; return 0; }; is_permission_block_rate_acceptable' \
	_ "$SCRIPTS_DIR/pulse-wrapper-dispatch-gates.sh" || rc=$?
[[ "$rc" -eq 1 ]]
NOW=103600
expect 0 'rotated log does not extend the persisted pause'
rm "$BLOCKERS" "${BLOCKERS}.permission-breaker.state"
BLOCKERS="$default_blockers"
unset AIDEVOPS_WORKER_BLOCKER_LOG_FILE

reset_fixture
event 1 99000
event 1 99500
event 1
expect 0 'repeated same issue does not trip'
event 2 100000 owner/repo unknown
event 3 100000 owner/repo runner_capability_unmet
event 4 100000 owner/repo files_scope_excluded
event 5 100000 owner/repo permission_required progress_blocked
expect 0 'other reasons and non-terminal events do not count'
event 1 100000 other/repo
event 1 100000 third/repo
expect 1 'same number in different repositories counts distinctly'

AIDEVOPS_PERMISSION_BLOCK_WINDOW_MAX=0
expect 0 'zero threshold disables'
unset AIDEVOPS_PERMISSION_BLOCK_WINDOW_MAX
AIDEVOPS_SKIP_PERMISSION_BLOCK_BREAKER=1
expect 0 'emergency bypass disables'
unset AIDEVOPS_SKIP_PERMISSION_BLOCK_BREAKER

reset_fixture
event 1 98000
event 2 99999
event 3
expect 0 'events must share a rolling window'
AIDEVOPS_PERMISSION_BLOCK_WINDOW_SECS=2000
expect 1 'window override includes boundary'
unset AIDEVOPS_PERMISSION_BLOCK_WINDOW_SECS
AIDEVOPS_PERMISSION_BLOCK_WINDOW_MAX=2
expect 1 'threshold override'

reset_fixture
event 1 100001
event 2 100001
event 3 100001
expect 0 'future events ignored'
rm "$BLOCKERS"
expect 0 'missing log fails open'
[[ "$(<"$LOGFILE")" == *'missing or malformed log; failing open'* ]]
printf '%s\n' '{invalid SENSITIVE_SENTINEL' >"$BLOCKERS"
expect 0 'malformed JSON fails open without parser text'
event 1
expect 0 'valid event does not hide malformed line'
[[ "$(<"$LOGFILE")" != *SENSITIVE_SENTINEL* ]]
reset_fixture
printf '%s\n' '{"event":"terminal_blocker_captured","reason":"permission_required","ts":"invalid"}' >"$BLOCKERS"
expect 0 'malformed metadata fails open'
AIDEVOPS_PERMISSION_BLOCK_WINDOW_SECS=invalid
expect 0 'invalid configuration fails open'

# Exercise the sourced no_work breaker too: its older extraction-based test can
# skip this function after the dispatch-gates module split.
reset_fixture
export AIDEVOPS_NO_WORK_WINDOW_MAX=3
printf '%s\n' 'crash_type=no_work' 'crash_type=no_work' 'crash_type=no_work' >"$LOGFILE"
rc=0
is_no_work_rate_acceptable || rc=$?
[[ "$rc" -eq 1 ]]

# Event refill must retain the trigger rather than dispatch through the pause.
# shellcheck source=../pulse-event-refill.sh
source "$SCRIPTS_DIR/pulse-event-refill.sh"
pulse_event_refill_github_available() { return 0; }
unset AIDEVOPS_NO_WORK_WINDOW_MAX
reset_fixture
event 1
event 2
event 3
rc=0
_pulse_event_refill_dispatch_gate || rc=$?
[[ "$rc" -eq 1 ]]

# Run the production reporter against synthetic local stats, without network.
unset -f date
now=$(date +%s)
jq -nc --argjson now "$now" \
	'{counters:{pulse_dispatch_permission_block_breaker_tripped:[$now]}}' \
	>"$HOME/.aidevops/logs/pulse-stats.json"
bash "$SCRIPTS_DIR/worker-activity-helper.sh" summary --since 6h --json |
	jq -e '.pulse_stats.pulse_dispatch_permission_block_breaker_tripped == 1' >/dev/null
bash "$SCRIPTS_DIR/worker-activity-helper.sh" summary --since 6h |
	grep 'pulse_dispatch_permission_block_breaker_tripped: 1' >/dev/null
grep -q 'unclassifiable_shell_read or classification_unavailable' "$SCRIPTS_DIR/headless-runtime-lib.sh"
grep -q 'protected_read, classification_mutation, and owner-signed SSH or network grant denials remain permission_required' "$SCRIPTS_DIR/headless-runtime-lib.sh"
printf '%s breaker cases passed; no_work, refill, reporter and guidance checks passed\n' "$PASSED"
