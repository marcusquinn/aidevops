#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#27973: concurrent audit writers must preserve
# unique sequence numbers and an intact hash chain without relying on flock.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../audit-log-helper.sh"
TEST_ROOT=""
PASS=0
FAIL=0

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	FAIL=$((FAIL + 1))
	return 0
}

assert_chain() {
	local description="$1"
	local log_file="$2"
	if AUDIT_LOG_FILE="$log_file" AUDIT_QUIET=true "$HELPER" verify --quiet; then
		pass "$description"
	else
		fail "$description"
	fi
	return 0
}

run_parallel_writers() {
	local log_file="$1"
	local count="$2"
	local prefix="$3"
	local index
	local -a pids=()

	for index in $(seq 1 "$count"); do
		AUDIT_LOG_FILE="$log_file" AUDIT_QUIET=true AUDIT_LOCK_TIMEOUT_SECONDS=30 \
			"$HELPER" log operation.verify "${prefix}-${index}" &
		pids+=("$!")
	done
	local pid
	for pid in "${pids[@]}"; do
		if ! wait "$pid"; then
			fail "parallel writer process $pid failed unexpectedly"
		fi
	done
	return 0
}

TEST_ROOT="$(mktemp -d -t aidevops-audit-lock-XXXXXX)"
LOG_FILE="${TEST_ROOT}/audit.jsonl"

run_parallel_writers "$LOG_FILE" 40 "concurrent"
line_count="$(wc -l <"$LOG_FILE" | tr -d ' ')"
if [[ "$line_count" == "40" ]]; then
	pass "all concurrent writers appended exactly once"
else
	fail "expected 40 concurrent entries, found $line_count"
fi

if jq -e 'length == 40 and ([.[].seq] | unique | length == 40) and ([.[].seq] | sort == [range(1; 41)])' \
	--slurp "$LOG_FILE" >/dev/null; then
	pass "concurrent sequence numbers are unique and monotonic"
else
	fail "concurrent sequence numbers are duplicated or non-monotonic"
fi
assert_chain "concurrent hash chain is intact" "$LOG_FILE"

LOCK_DIR="${LOG_FILE}.lock.d"
mkdir "$LOCK_DIR"
printf '%s held-by-test\n' "$$" >"${LOCK_DIR}/owner"
before_timeout_count="$(wc -l <"$LOG_FILE" | tr -d ' ')"
timeout_rc=0
timeout_output=$(AUDIT_LOG_FILE="$LOG_FILE" AUDIT_QUIET=true AUDIT_LOCK_TIMEOUT_SECONDS=1 \
	"$HELPER" log operation.verify "must-not-append" 2>&1) || timeout_rc=$?
after_timeout_count="$(wc -l <"$LOG_FILE" | tr -d ' ')"
rm -rf "$LOCK_DIR"
if [[ "$timeout_rc" -ne 0 && "$before_timeout_count" == "$after_timeout_count" ]]; then
	pass "lock timeout fails closed without appending"
else
	fail "lock timeout appended or returned success"
fi
if [[ "$timeout_output" == *"Could not acquire audit log lock after 1s"* ]]; then
	pass "lock timeout reports a bounded failure"
else
	fail "lock timeout did not report the expected error"
fi

mkdir "$LOCK_DIR"
printf '999999 stale-owner\n' >"${LOCK_DIR}/owner"
AUDIT_LOG_FILE="$LOG_FILE" AUDIT_QUIET=true "$HELPER" log operation.verify "after-stale-lock"
if [[ ! -d "$LOCK_DIR" ]]; then
	pass "dead-owner lock is reclaimed and released"
else
	fail "dead-owner lock remained after append"
fi
assert_chain "hash chain remains intact after stale-lock reclaim" "$LOG_FILE"

mkdir "$LOCK_DIR"
AUDIT_LOG_FILE="$LOG_FILE" AUDIT_QUIET=true AUDIT_LOCK_ORPHAN_AGE_SECONDS=0 \
	"$HELPER" log operation.verify "after-ownerless-lock"
if [[ ! -d "$LOCK_DIR" ]]; then
	pass "old ownerless lock is reclaimed and released"
else
	fail "ownerless lock remained after append"
fi
assert_chain "hash chain remains intact after ownerless-lock reclaim" "$LOG_FILE"

SIGNAL_LOCK_DIR="${TEST_ROOT}/signal.jsonl.lock.d"
SIGNAL_READY="${TEST_ROOT}/signal.ready"
(
	# Keep shared-constants from replacing this Bash 3.2 fixture process.
	export AIDEVOPS_BASH_REEXECED=1
	# Bash 3.2 does not define BASHPID; force that compatibility path even
	# when this regression test runs under a newer Bash.
	unset BASHPID
	# shellcheck disable=SC1090
	source "$HELPER"
	_audit_acquire_lock "$SIGNAL_LOCK_DIR"
	_audit_arm_lock_cleanup
	: >"$SIGNAL_READY"
	while true; do
		sleep 0.1
	done
) &
signal_pid=$!
for attempt in $(seq 1 50); do
	[[ -f "$SIGNAL_READY" ]] && break
	if ! kill -0 "$signal_pid" 2>/dev/null; then
		break
	fi
	sleep 0.1
done
if [[ -f "$SIGNAL_READY" && -d "$SIGNAL_LOCK_DIR" ]]; then
	IFS=' ' read -r signal_owner_pid _ <"${SIGNAL_LOCK_DIR}/owner"
	if [[ "$signal_owner_pid" == "$signal_pid" ]]; then
		pass "Bash 3.2 fallback records the lock-holding subshell PID"
	else
		fail "Bash 3.2 fallback recorded PID ${signal_owner_pid}, expected ${signal_pid}"
	fi
	kill -TERM "$signal_pid"
	signal_rc=0
	wait "$signal_pid" || signal_rc=$?
	if [[ "$signal_rc" -eq 143 && ! -d "$SIGNAL_LOCK_DIR" ]]; then
		pass "termination signal releases the owned lock"
	else
		fail "termination signal left the owned lock or returned an unexpected status"
	fi
else
	fail "signal cleanup fixture did not acquire its lock"
	kill -TERM "$signal_pid" 2>/dev/null || true
	wait "$signal_pid" 2>/dev/null || true
fi

ROTATE_LOG="${TEST_ROOT}/rotate.jsonl"
for index in $(seq 1 5); do
	AUDIT_LOG_FILE="$ROTATE_LOG" AUDIT_QUIET=true "$HELPER" log operation.verify "before-rotate-${index}"
done
run_parallel_writers "$ROTATE_LOG" 20 "during-rotate" &
writer_group_pid=$!
AUDIT_LOG_FILE="$ROTATE_LOG" AUDIT_QUIET=true "$HELPER" rotate --max-size 0
wait "$writer_group_pid"

rotated_file=""
for candidate in "${ROTATE_LOG%.jsonl}".*.jsonl; do
	if [[ -f "$candidate" ]]; then
		rotated_file="$candidate"
		break
	fi
done
if [[ -n "$rotated_file" ]]; then
	pass "rotation produced an immutable segment"
	assert_chain "rotated segment hash chain is intact" "$rotated_file"
	assert_chain "new segment hash chain is intact" "$ROTATE_LOG"
	rotated_last_hash="$(jq -r -s '.[-1].hash // empty' "$rotated_file")"
	handoff_hash="$(jq -r -s 'map(select(.type == "system.rotate"))[0].detail.prev_segment_hash // empty' "$ROTATE_LOG")"
	if [[ -n "$rotated_last_hash" && "$handoff_hash" == "$rotated_last_hash" ]]; then
		pass "rotation event links to the prior segment hash"
	else
		fail "rotation event does not link to the prior segment hash"
	fi
	combined_count=$(($(wc -l <"$rotated_file") + $(wc -l <"$ROTATE_LOG")))
	if [[ "$combined_count" -eq 26 ]]; then
		pass "rotation preserves every writer plus the handoff event"
	else
		fail "rotation expected 26 total entries, found $combined_count"
	fi
else
	fail "rotation did not produce a rotated segment"
fi

if [[ "$FAIL" -gt 0 ]]; then
	printf '%s audit concurrency test(s) failed; %s passed\n' "$FAIL" "$PASS" >&2
	exit 1
fi
printf 'All %s audit concurrency tests passed.\n' "$PASS"
exit 0
