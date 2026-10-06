#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TESTS_RUN=0
TESTS_FAILED=0
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d -t pulse-cycle-state.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s %s\n' "$name" "$detail"
	return 0
}

assert_health() {
	local name="$1"
	local filter="$2"
	if jq -e "$filter" "$PULSE_HEALTH_FILE" >/dev/null; then
		pass "$name"
	else
		fail "$name" "health=$(jq -c . "$PULSE_HEALTH_FILE" 2>/dev/null || printf malformed)"
	fi
	return 0
}

export HOME="${TMP_DIR}/home"
export SCRIPT_DIR="$SOURCE_DIR"
export AIDEVOPS_DISPATCH_LEDGER_DIR="$TMP_DIR"
export AIDEVOPS_DISPATCH_LEDGER_FILE="${TMP_DIR}/dispatch-ledger.jsonl"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/tmp"

PULSE_HEALTH_FILE="${HOME}/.aidevops/logs/pulse-health.json"
PULSE_CYCLE_INDEX_FILE="${HOME}/.aidevops/logs/pulse-cycle-index.jsonl"
PULSE_CYCLE_INDEX_MAX_LINES=100
LOGFILE="${HOME}/.aidevops/logs/pulse.log"
WRAPPER_LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
HEADLESS_RUNTIME_HELPER="${TMP_DIR}/missing-headless-runtime-helper"
_PULSE_HEALTH_PRS_MERGED=0
_PULSE_HEALTH_PRS_CLOSED_CONFLICTING=0
_PULSE_HEALTH_STALLED_KILLED=0
_PULSE_HEALTH_PREFETCH_ERRORS=0
_PULSE_HEALTH_IDLE_REPO_SKIPS=0
_PULSE_HEALTH_BATCH_SEARCH_CALLS=0
_PULSE_HEALTH_BATCH_CACHE_HITS=0
_PULSE_HEALTH_EVENTS_TICKLE_FRESH=0
_PULSE_HEALTH_EVENTS_TICKLE_STALE=0
_PULSE_HEALTH_CONDITIONAL_304=0
_PULSE_HEALTH_CONDITIONAL_REFRESHES=0
_PULSE_HEALTH_CONDITIONAL_MISSES=0
_PULSE_HEALTH_PREFETCH_THROTTLED=0
_PULSE_HEALTH_IDLE_CYCLE_SKIPPED=0

count_active_workers() {
	printf '0\n'
	return 0
}

get_max_workers_target() {
	printf '4\n'
	return 0
}

# shellcheck source=../pulse-logging.sh
source "${SOURCE_DIR}/pulse-logging.sh"
# shellcheck source=../pulse-wrapper-cycle-gates.sh
source "${SOURCE_DIR}/pulse-wrapper-cycle-gates.sh"

_LOCK_OWNED=false
acquire_instance_lock() {
	_LOCK_OWNED=true
	return 0
}
release_instance_lock() {
	_LOCK_OWNED=false
	return 0
}

_pulse_cycle_state_start
write_pulse_health_file
assert_health "real health writer emits additive running lifecycle state" '
	.timestamp != null
	and .workers_active == 0
	and .workers_max == 4
	and .prs_merged_this_cycle == 0
	and .cycle_state.schema == "aidevops.pulse-cycle-state/v1"
	and .cycle_state.phase == "admitted"
	and .cycle_state.outcome == "running"
	and .cycle_state.progress.last_at == null
	and .cycle_state.progress.consecutive_no_progress_cycles == 0
	and .cycle_state.blocker.kind == "none"
'

initial_heartbeat=$(jq -r '.cycle_state.heartbeat_at' "$PULSE_HEALTH_FILE")
initial_progress=$(jq -c '.cycle_state.progress' "$PULSE_HEALTH_FILE")
sleep 1
_pulse_cycle_state_publish preflight
if [[ "$(jq -c '.cycle_state.progress' "$PULSE_HEALTH_FILE")" == "$initial_progress" \
	&& "$(jq -r '.cycle_state.heartbeat_at' "$PULSE_HEALTH_FILE")" > "$initial_heartbeat" ]]; then
	pass "heartbeat-only transition advances liveness without changing progress"
else
	fail "heartbeat-only transition advances liveness without changing progress"
fi

dispatch_before=$(_pulse_capture_dispatch_total)
printf '%s\n' '{"lease_phase":"prelaunch","dispatched_at":"2026-01-01T00:00:00Z"}' \
	>"$AIDEVOPS_DISPATCH_LEDGER_FILE"
_pulse_record_cycle_outcome "$dispatch_before"
_pulse_cycle_state_write_terminal_if_current
assert_health "actual dispatch registration produces typed progress" '
	.cycle_state.phase == "completed"
	and .cycle_state.outcome == "progressed"
	and .cycle_state.progress.kinds == ["worker-dispatched"]
	and .cycle_state.progress.last_at != null
	and .cycle_state.progress.consecutive_no_progress_cycles == 0
	and .cycle_state.blocker.kind == "none"
'
# GH#33320: the cycle index counts registrations made this cycle, even when
# the launched worker has already exited (no live in-flight ledger entry).
_PULSE_CYCLE_DISPATCH_BEFORE="$dispatch_before"
append_cycle_index 5
if tail -n 1 "$PULSE_CYCLE_INDEX_FILE" | jq -e '.dispatched == 1 and .inflight == 0 and .duration_s == 5' >/dev/null; then
	pass "cycle index records the per-cycle dispatch delta, not the live gauge"
else
	fail "cycle index records the per-cycle dispatch delta, not the live gauge" "$(tail -n 1 "$PULSE_CYCLE_INDEX_FILE" 2>/dev/null)"
fi
if [[ "${_PULSE_LEGACY_CYCLE_OUTCOME_PENDING:-1}" -eq 0 ]]; then
	pass "current terminal publication commits the legacy outcome once"
else
	fail "current terminal publication commits the legacy outcome once"
fi
last_progress_at=$(jq -r '.cycle_state.progress.last_at' "$PULSE_HEALTH_FILE")

_pulse_cycle_state_start
write_pulse_health_file
_pulse_cycle_state_note_blocker review-gate owner/repo 7
_pulse_record_cycle_outcome 1
_pulse_cycle_state_write_terminal_if_current
assert_health "first typed blocker starts both no-progress streaks" '
	.cycle_state.outcome == "blocked"
	and .cycle_state.progress.consecutive_no_progress_cycles == 1
	and .cycle_state.blocker.kind == "review-gate"
	and .cycle_state.blocker.consecutive_same_cycles == 1
'
first_fingerprint=$(jq -r '.cycle_state.blocker.fingerprint' "$PULSE_HEALTH_FILE")
if [[ "$first_fingerprint" != *"owner/repo"* && "$first_fingerprint" != *"#7"* ]]; then
	pass "blocker fingerprint does not expose source coordinates"
else
	fail "blocker fingerprint does not expose source coordinates"
fi

_pulse_cycle_state_start
write_pulse_health_file
_pulse_cycle_state_note_blocker review-gate owner/repo 7
_pulse_record_cycle_outcome 1
_pulse_cycle_state_write_terminal_if_current
assert_health "repeated blocker increments stable streak without moving progress" "
	.cycle_state.progress.last_at == \"${last_progress_at}\"
	and .cycle_state.progress.consecutive_no_progress_cycles == 2
	and .cycle_state.blocker.consecutive_same_cycles == 2
"

_pulse_cycle_state_start
write_pulse_health_file
_pulse_cycle_state_note_blocker head-changed owner/repo 7
_pulse_record_cycle_outcome 1
_pulse_cycle_state_write_terminal_if_current
assert_health "changed blocker restarts only blocker streak" '
	.cycle_state.progress.consecutive_no_progress_cycles == 3
	and .cycle_state.blocker.kind == "head-changed"
	and .cycle_state.blocker.consecutive_same_cycles == 1
'

_pulse_cycle_state_start
write_pulse_health_file
_PULSE_HEALTH_PRS_MERGED=1
_pulse_record_cycle_outcome 1
_pulse_cycle_state_write_terminal_if_current
assert_health "meaningful progress resets blocker and no-progress streaks" '
	.cycle_state.outcome == "progressed"
	and .cycle_state.progress.kinds == ["pr-merged"]
	and .cycle_state.progress.consecutive_no_progress_cycles == 0
	and .cycle_state.blocker.kind == "none"
	and .cycle_state.blocker.consecutive_same_cycles == 0
'

cp "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-failed-write.json"
mv() {
	return 1
}
write_pulse_health_file
unset -f mv
if cmp -s "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-failed-write.json"; then
	pass "failed atomic rename preserves the last valid health record"
else
	fail "failed atomic rename preserves the last valid health record"
fi

consumer_output="${TMP_DIR}/consumer.json"
python3 "${SOURCE_DIR}/pulse-current-state.py" \
	"${HOME}/.aidevops/logs" "$PWD" 900 1 "$SOURCE_DIR" "${TMP_DIR}/review-state" \
	>"$consumer_output"
if jq -e '
	.cycle_state.availability == "available"
	and .cycle_state.schema == "aidevops.pulse-cycle-state/v1"
	and .cycle_state.outcome == "progressed"
	and .cycle_state.progress.kinds == ["pr-merged"]
' "$consumer_output" >/dev/null; then
	pass "production consumer accepts the real producer output"
else
	fail "production consumer accepts the real producer output"
fi

# Exercise the real budget producer through terminal publication and the reader.
# Statistics are intentionally absent: lifecycle evidence must not depend on them.
# shellcheck source=../pulse-budget-priority.sh
source "${SOURCE_DIR}/pulse-budget-priority.sh"
_PULSE_HEALTH_PRS_MERGED=0
_pulse_cycle_state_start
write_pulse_health_file
AIDEVOPS_PULSE_REST_CORE_BUDGET_CLASS=emergency
_pulse_defer_budget_priority_stage dispatch_max
_pulse_record_cycle_outcome 1
_pulse_cycle_state_write_terminal_if_current
assert_health "quota-deferred progress is blocked rather than idle" '
	.cycle_state.outcome == "blocked"
	and .cycle_state.blocker.kind == "rest-core-quota"
'
python3 "${SOURCE_DIR}/pulse-current-state.py" \
	"${HOME}/.aidevops/logs" "$PWD" 900 1 "$SOURCE_DIR" "${TMP_DIR}/review-state" \
	>"$consumer_output"
if jq -e '.cycle_state.availability == "available" and .cycle_state.blocker.kind == "rest-core-quota"' "$consumer_output" >/dev/null; then
	pass "production consumer accepts quota blocker"
else
	fail "production consumer accepts quota blocker"
fi

if [[ ! -e "${HOME}/.aidevops/logs/pulse-cycle-state.json" ]]; then
	pass "lifecycle state does not create a parallel runtime artifact"
else
	fail "lifecycle state does not create a parallel runtime artifact"
fi

_pulse_cycle_state_start
write_pulse_health_file
_pulse_cycle_state_finalize idle '[]'
_PULSE_LEGACY_CYCLE_OUTCOME_PENDING=1
cp "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-missing-lock-terminal.json"
unset -f acquire_instance_lock release_instance_lock
_pulse_cycle_state_write_terminal_if_current
if cmp -s "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-missing-lock-terminal.json" \
	&& [[ "$_PULSE_LEGACY_CYCLE_OUTCOME_PENDING" -eq 1 ]]; then
	pass "terminal publication fails closed when lock functions are unavailable"
else
	fail "terminal publication fails closed when lock functions are unavailable"
fi

_pulse_cycle_state_start
write_pulse_health_file
_pulse_cycle_state_finalize idle '[]'
_PULSE_LEGACY_CYCLE_OUTCOME_PENDING=1
LOCK_ACQUIRE_CALLS=0
LOCK_RELEASE_CALLS=0
_LOCK_OWNED=false
acquire_instance_lock() {
	LOCK_ACQUIRE_CALLS=$((LOCK_ACQUIRE_CALLS + 1))
	_LOCK_OWNED=true
	return 0
}
release_instance_lock() {
	LOCK_RELEASE_CALLS=$((LOCK_RELEASE_CALLS + 1))
	_LOCK_OWNED=false
	return 0
}
jq '.cycle_state.cycle_id = "newer-cycle"' "$PULSE_HEALTH_FILE" >"${TMP_DIR}/newer-health.json"
mv "${TMP_DIR}/newer-health.json" "$PULSE_HEALTH_FILE"
cp "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-stale-terminal.json"
_pulse_cycle_state_write_terminal_if_current
if cmp -s "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-stale-terminal.json" \
	&& [[ "$LOCK_ACQUIRE_CALLS" -eq 1 && "$LOCK_RELEASE_CALLS" -eq 1 \
		&& "$_LOCK_OWNED" == "false" \
		&& "$_PULSE_LEGACY_CYCLE_OUTCOME_PENDING" -eq 1 ]]; then
	pass "older terminal publication cannot overwrite newer cycle health"
else
	fail "older terminal publication cannot overwrite newer cycle health"
fi

: >"$AIDEVOPS_DISPATCH_LEDGER_FILE"
_PULSE_HEALTH_PRS_MERGED=0
_pulse_cycle_state_start
write_pulse_health_file
child_cleanup_cycle_id="$_PULSE_CYCLE_ID"
cp "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-child-cleanup.json"
_LOCK_OWNED=true
(
	trap '_pulse_cycle_state_finish_interrupted' EXIT
)
if cmp -s "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-child-cleanup.json" \
	&& [[ "$_PULSE_CYCLE_STATE_TERMINAL" -eq 0 ]] \
	&& jq -e --arg cycle_id "$child_cleanup_cycle_id" '
		.cycle_state.cycle_id == $cycle_id
		and .cycle_state.phase == "admitted"
		and .cycle_state.outcome == "running"
	' "$PULSE_HEALTH_FILE" >/dev/null; then
	pass "child EXIT cleanup cannot publish terminal state for the live owner"
else
	fail "child EXIT cleanup cannot publish terminal state for the live owner"
fi

cp "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-child-terminal-write.json"
(
	_PULSE_CYCLE_STATE_TERMINAL=1
	_PULSE_CYCLE_PHASE="completed"
	_PULSE_CYCLE_OUTCOME="interrupted"
	write_pulse_health_file
)
if cmp -s "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-child-terminal-write.json"; then
	pass "child executor cannot directly publish inherited terminal health"
else
	fail "child executor cannot directly publish inherited terminal health"
fi

post_label_dispatch_before=$(_pulse_capture_dispatch_total)
printf '{"session_key":"post-label-test","status":"in-flight","pid":%s,"lease_phase":"prelaunch","dispatched_at":"2026-01-01T00:00:00Z"}\n' \
	"$$" >"$AIDEVOPS_DISPATCH_LEDGER_FILE"
_pulse_record_cycle_outcome "$post_label_dispatch_before"
_pulse_cycle_state_write_terminal_if_current
assert_health "owner finalization records successful post-label dispatch" '
	.issues_dispatched == 1
	and .cycle_state.phase == "completed"
	and .cycle_state.outcome == "progressed"
	and .cycle_state.progress.kinds == ["worker-dispatched"]
'

# Retention uses production functions in the sandbox HOME, never live ledgers.
# shellcheck source=../portable-stat.sh
source "${SOURCE_DIR}/portable-stat.sh"
PULSE_METRICS_ARCHIVE_DIR="${HOME}/.aidevops/logs/metrics-archive"
PULSE_LOG_ARCHIVE_DIR="${HOME}/.aidevops/logs/pulse-archive"
PULSE_METRICS_HOT_MAX_BYTES=1024
PULSE_METRICS_COLD_MAX_BYTES=524288000
PULSE_LOG_HOT_MAX_BYTES=52428800
PULSE_LOG_COLD_MAX_BYTES=1073741824
AIDEVOPS_HEADLESS_METRICS_FILE="${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl"
AIDEVOPS_RESOURCE_METRICS_FILE="${HOME}/.aidevops/logs/resource-metrics.jsonl"
for ((row = 1; row <= 200; row++)); do
	printf '{"row":%s}\n' "$row"
done >"${TMP_DIR}/expected-metrics.jsonl"
cp "${TMP_DIR}/expected-metrics.jsonl" "$AIDEVOPS_HEADLESS_METRICS_FILE"
cp "${TMP_DIR}/expected-metrics.jsonl" "$AIDEVOPS_RESOURCE_METRICS_FILE"
rotate_pulse_log
if [[ ! -e "$AIDEVOPS_HEADLESS_METRICS_FILE" && ! -e "$AIDEVOPS_RESOURCE_METRICS_FILE" ]] &&
	gzip -dc "${PULSE_METRICS_ARCHIVE_DIR}"/headless-runtime-metrics-*.jsonl.gz | cmp -s - "${TMP_DIR}/expected-metrics.jsonl" &&
	gzip -dc "${PULSE_METRICS_ARCHIVE_DIR}"/resource-metrics-*.jsonl.gz | cmp -s - "${TMP_DIR}/expected-metrics.jsonl"; then
	pass "rotate_pulse_log preserves every byte in both oversized metrics ledgers"
else
	fail "rotate_pulse_log preserves every byte in both oversized metrics ledgers"
fi
printf '{"row":"new-hot"}\n' >>"$AIDEVOPS_HEADLESS_METRICS_FILE"
staged_metric="${HOME}/.aidevops/logs/.headless-runtime-metrics-rotating-20260101-000000-123"
cp "${TMP_DIR}/expected-metrics.jsonl" "$staged_metric"
_rotate_metrics_jsonl "$AIDEVOPS_HEADLESS_METRICS_FILE" "headless-runtime-metrics"
if [[ ! -e "$staged_metric" ]] &&
	gzip -dc "${PULSE_METRICS_ARCHIVE_DIR}/headless-runtime-metrics-20260101-000000.jsonl.gz" | cmp -s - "${TMP_DIR}/expected-metrics.jsonl" &&
	jq -e '.row == "new-hot"' "$AIDEVOPS_HEADLESS_METRICS_FILE" >/dev/null; then
	pass "crash-left staged segment is recovered without rotating a small hot file"
else
	fail "crash-left staged segment is recovered without rotating a small hot file"
fi
# Repeat the same timestamp: the first archive must not be overwritten.
cp "${TMP_DIR}/expected-metrics.jsonl" "$staged_metric"
_rotate_metrics_jsonl "$AIDEVOPS_HEADLESS_METRICS_FILE" "headless-runtime-metrics"
collision_archives=("${PULSE_METRICS_ARCHIVE_DIR}"/headless-runtime-metrics-20260101-000000*.jsonl.gz)
if [[ "${#collision_archives[@]}" -eq 2 ]]; then
	pass "same-timestamp archives retain separate segments"
else
	fail "same-timestamp archives retain separate segments"
fi

for ((row = 1; row <= 600; row++)); do
	printf '{"row":%s}\n' "$row"
done >"$PULSE_CYCLE_INDEX_FILE"
_prune_cycle_index
if [[ "$(wc -l <"$PULSE_CYCLE_INDEX_FILE")" -eq 600 ]]; then
	pass "cycle-index hysteresis avoids tiny per-cycle archives"
else
	fail "cycle-index hysteresis avoids tiny per-cycle archives"
fi
printf '{"row":601}\n' >>"$PULSE_CYCLE_INDEX_FILE"
cp "$PULSE_CYCLE_INDEX_FILE" "${TMP_DIR}/expected-cycle.jsonl"
_prune_cycle_index
gzip -dc "${PULSE_METRICS_ARCHIVE_DIR}"/pulse-cycle-index-*.jsonl.gz >"${TMP_DIR}/reassembled-cycle.jsonl"
cat "$PULSE_CYCLE_INDEX_FILE" >>"${TMP_DIR}/reassembled-cycle.jsonl"
if [[ "$(wc -l <"$PULSE_CYCLE_INDEX_FILE")" -eq 100 ]] &&
	cmp -s "${TMP_DIR}/reassembled-cycle.jsonl" "${TMP_DIR}/expected-cycle.jsonl"; then
	pass "cycle-index archived head and hot tail reconstruct all original rows"
else
	fail "cycle-index archived head and hot tail reconstruct all original rows"
fi

# Inject a compression failure only in a subshell; production failure paths
# must keep the full index and preserve a rotated metric as raw evidence.
cp "${TMP_DIR}/expected-cycle.jsonl" "$PULSE_CYCLE_INDEX_FILE"
cp "${TMP_DIR}/expected-metrics.jsonl" "$AIDEVOPS_RESOURCE_METRICS_FILE"
(
	gzip() { return 1; }
	_prune_cycle_index
	_rotate_metrics_jsonl "$AIDEVOPS_RESOURCE_METRICS_FILE" "resource-metrics"
)
raw_archives=("${PULSE_METRICS_ARCHIVE_DIR}"/resource-metrics-*.jsonl)
if cmp -s "$PULSE_CYCLE_INDEX_FILE" "${TMP_DIR}/expected-cycle.jsonl" &&
	[[ "${#raw_archives[@]}" -eq 1 ]] && cmp -s "${raw_archives[0]}" "${TMP_DIR}/expected-metrics.jsonl"; then
	pass "compression failure skips index pruning and retains raw metric evidence"
else
	fail "compression failure skips index pruning and retains raw metric evidence"
fi

(
	PULSE_METRICS_COLD_MAX_BYTES=0
	tail() { return 1; }
	_prune_cycle_index
)
if cmp -s "$PULSE_CYCLE_INDEX_FILE" "${TMP_DIR}/expected-cycle.jsonl" &&
	cmp -s "${raw_archives[0]}" "${TMP_DIR}/expected-metrics.jsonl"; then
	pass "failed index swap preserves hot rows and skips cold pruning"
else
	fail "failed index swap preserves hot rows and skips cold pruning"
fi
printf 'incomplete' >"${PULSE_METRICS_ARCHIVE_DIR}/.metrics-archive-orphan"
printf 'incomplete' >"${PULSE_METRICS_ARCHIVE_DIR}/.cycle-archive-orphan"
_cleanup_metrics_archive_temps
if [[ ! -e "${PULSE_METRICS_ARCHIVE_DIR}/.metrics-archive-orphan" &&
! -e "${PULSE_METRICS_ARCHIVE_DIR}/.cycle-archive-orphan" ]] &&
	cmp -s "${raw_archives[0]}" "${TMP_DIR}/expected-metrics.jsonl"; then
	pass "restart cleanup removes partial temporary archives, not published evidence"
else
	fail "restart cleanup removes partial temporary archives, not published evidence"
fi

# A separate archive sandbox proves timestamp ordering across basenames and
# counting of uncompressed fallbacks, without deleting the evidence above.
PULSE_METRICS_ARCHIVE_DIR="${TMP_DIR}/prune-archive"
mkdir -p "$PULSE_METRICS_ARCHIVE_DIR"
printf 'old' >"${PULSE_METRICS_ARCHIVE_DIR}/resource-metrics-20260101-000000.jsonl"
printf 'mid' >"${PULSE_METRICS_ARCHIVE_DIR}/pulse-cycle-index-20260201-000000.jsonl.gz"
printf 'new' >"${PULSE_METRICS_ARCHIVE_DIR}/headless-runtime-metrics-20260301-000000.jsonl.gz"
PULSE_METRICS_COLD_MAX_BYTES=3
_prune_metrics_archive
remaining_archives=("${PULSE_METRICS_ARCHIVE_DIR}"/*.jsonl*)
if [[ "${#remaining_archives[@]}" -eq 1 && "${remaining_archives[0]##*/}" == "headless-runtime-metrics-20260301-000000.jsonl.gz" ]]; then
	pass "combined archive cap prunes by timestamp rather than basename"
else
	fail "combined archive cap prunes by timestamp rather than basename"
fi

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
