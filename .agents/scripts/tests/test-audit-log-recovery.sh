#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#28379: preserve broken audit segments byte-for-byte,
# establish a declared successor, and retain the historical verdict in summaries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
AUDIT_HELPER="${SCRIPT_DIR}/../audit-log-helper.sh"
SESSION_REVIEW_HELPER="${SCRIPT_DIR}/../session-review-helper.sh"
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

sha256_file() {
	local file="$1"
	if command -v shasum &>/dev/null; then
		shasum -a 256 "$file" | cut -d' ' -f1
		return $?
	fi
	sha256sum "$file" | cut -d' ' -f1
	return $?
}

create_broken_log() {
	local log_file="$1"
	local fixture_file="${log_file}.fixture"
	local index
	for index in 1 2 3; do
		AUDIT_LOG_FILE="$log_file" AUDIT_QUIET=true \
			"$AUDIT_HELPER" log operation.verify "fixture-${index}"
	done
	# Duplicate the second append byte-for-byte. Its stored prev_hash still points
	# at entry one, so the duplicate sequence deterministically breaks the chain.
	sed -n '1p;2p;2p;3p' "$log_file" >"$fixture_file"
	mv "$fixture_file" "$log_file"
	return 0
}

assert_chain_intact() {
	local description="$1"
	local log_file="$2"
	if AUDIT_LOG_FILE="$log_file" AUDIT_QUIET=true "$AUDIT_HELPER" verify --quiet; then
		pass "$description"
	else
		fail "$description"
	fi
	return 0
}

assert_chain_broken() {
	local description="$1"
	local log_file="$2"
	if AUDIT_LOG_FILE="$log_file" AUDIT_QUIET=true \
		"$AUDIT_HELPER" verify --quiet >/dev/null 2>&1; then
		fail "$description"
	else
		pass "$description"
	fi
	return 0
}

archive_count() {
	local log_file="$1"
	local count=0
	local candidate
	for candidate in "${log_file%.jsonl}".broken.*.jsonl; do
		[[ -f "$candidate" ]] || continue
		count=$((count + 1))
	done
	printf '%s\n' "$count"
	return 0
}

first_archive() {
	local log_file="$1"
	local candidate
	for candidate in "${log_file%.jsonl}".broken.*.jsonl; do
		if [[ -f "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

TEST_ROOT="$(mktemp -d -t aidevops-audit-recovery-XXXXXX)"
HOME_ROOT="${TEST_ROOT}/home"
LOG_FILE="${HOME_ROOT}/.aidevops/.agent-workspace/observability/audit.jsonl"
REASON="duplicate historical append fixture"

create_broken_log "$LOG_FILE"
source_sha256="$(sha256_file "$LOG_FILE")"
terminal_hash="$(jq -r -s '.[-1].hash // empty' "$LOG_FILE")"
assert_chain_broken "duplicate sequence fixture breaks the previous-hash chain" "$LOG_FILE"

LOCK_DIR="${LOG_FILE}.lock.d"
mkdir "$LOCK_DIR"
printf '%s held-by-recovery-test\n' "$$" >"${LOCK_DIR}/owner"
locked_sha256="$(sha256_file "$LOG_FILE")"
locked_rc=0
locked_output=$(AUDIT_LOG_FILE="$LOG_FILE" AUDIT_QUIET=true AUDIT_LOCK_TIMEOUT_SECONDS=0 \
	"$AUDIT_HELPER" recover --reason "$REASON" 2>&1) || locked_rc=$?
rm -rf "$LOCK_DIR"
if [[ "$locked_rc" -ne 0 && "$(sha256_file "$LOG_FILE")" == "$locked_sha256" ]] &&
	[[ "$(archive_count "$LOG_FILE")" -eq 0 ]]; then
	pass "locked recovery fails closed without changing or archiving evidence"
else
	fail "locked recovery changed evidence or returned success"
fi
if [[ "$locked_output" == *"Could not acquire audit log lock after 0s"* ]]; then
	pass "locked recovery reports the bounded lock failure"
else
	fail "locked recovery omitted the lock failure"
fi

rotate_sha256="$(sha256_file "$LOG_FILE")"
rotate_rc=0
AUDIT_LOG_FILE="$LOG_FILE" AUDIT_QUIET=true \
	"$AUDIT_HELPER" rotate --max-size 0 >/dev/null 2>&1 || rotate_rc=$?
if [[ "$rotate_rc" -ne 0 && "$(sha256_file "$LOG_FILE")" == "$rotate_sha256" ]] &&
	[[ "$(archive_count "$LOG_FILE")" -eq 0 ]]; then
	pass "ordinary rotation refuses a broken chain without changing evidence"
else
	fail "ordinary rotation bypassed explicit broken-chain recovery"
fi

AUDIT_LOG_FILE="$LOG_FILE" AUDIT_QUIET=true \
	"$AUDIT_HELPER" recover --reason "$REASON"
assert_chain_intact "recovery activates a verifying successor" "$LOG_FILE"

archived_file="$(first_archive "$LOG_FILE")"
if [[ "$(archive_count "$LOG_FILE")" -eq 1 ]]; then
	pass "recovery creates exactly one forensic archive"
else
	fail "recovery did not create exactly one forensic archive"
fi
if [[ "$(sha256_file "$archived_file")" == "$source_sha256" ]]; then
	pass "forensic archive preserves every source byte"
else
	fail "forensic archive bytes differ from the broken source"
fi
if [[ ! -w "$archived_file" ]]; then
	pass "forensic archive is read-only"
else
	fail "forensic archive remains writable"
fi
assert_chain_broken "forensic archive retains its BROKEN verdict" "$archived_file"

archived_name="$(basename "$archived_file")"
if jq -e \
	--arg archived_name "$archived_name" \
	--arg archived_sha256 "$source_sha256" \
	--arg terminal_hash "$terminal_hash" \
	--arg reason "$REASON" \
	'length == 1 and
	 .[0].seq == 1 and
	 .[0].type == "system.recover" and
	 .[0].detail.recovery_schema == "1" and
	 .[0].detail.archived_segment == $archived_name and
	 .[0].detail.archived_sha256 == $archived_sha256 and
	 .[0].detail.archived_terminal_hash == $terminal_hash and
	 .[0].detail.archived_verification == "BROKEN" and
	 .[0].detail.historical_integrity == "BROKEN" and
	 .[0].detail.recovery_reason == $reason and
	 (.[0].detail.recovered_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' \
	--slurp "$LOG_FILE" >/dev/null; then
	pass "successor records explicit machine-readable historical integrity metadata"
else
	fail "successor recovery metadata is incomplete or contradictory"
fi

successor_sha256="$(sha256_file "$LOG_FILE")"
AUDIT_LOG_FILE="$LOG_FILE" AUDIT_QUIET=true \
	"$AUDIT_HELPER" recover --reason "idempotent retry"
if [[ "$(sha256_file "$LOG_FILE")" == "$successor_sha256" ]] &&
	[[ "$(archive_count "$LOG_FILE")" -eq 1 ]]; then
	pass "repeated recovery is idempotent"
else
	fail "repeated recovery created a contradictory successor or archive"
fi

AUDIT_LOG_FILE="$LOG_FILE" AUDIT_QUIET=true \
	"$AUDIT_HELPER" log operation.verify "after-recovery"
assert_chain_intact "serialized appends continue on the recovery successor" "$LOG_FILE"

summary_json="$(HOME="$HOME_ROOT" "$SESSION_REVIEW_HELPER" security --json)"
if printf '%s' "$summary_json" | jq -e '
	.audit.chain_intact == true and
	.audit.active_chain_intact == true and
	.audit.historical_integrity == "BROKEN" and
	.posture == "CRITICAL"
' >/dev/null; then
	pass "JSON summary separates healthy active state from broken history"
else
	fail "JSON summary loses active or historical audit integrity"
fi
summary_text="$(HOME="$HOME_ROOT" NO_COLOR=1 "$SESSION_REVIEW_HELPER" security)"
if [[ "$summary_text" == *"Active chain:         INTACT"* ]] &&
	[[ "$summary_text" == *"Historical integrity: BROKEN"* ]]; then
	pass "text summary separates active and historical audit integrity"
else
	fail "text summary loses active or historical audit integrity"
fi

AUDIT_LOG_FILE="$LOG_FILE" AUDIT_QUIET=true \
	"$AUDIT_HELPER" rotate --max-size 0
assert_chain_intact "ordinary rotation remains compatible after recovery" "$LOG_FILE"
rotated_summary_json="$(HOME="$HOME_ROOT" "$SESSION_REVIEW_HELPER" security --json)"
if printf '%s' "$rotated_summary_json" | jq -e '
	.audit.active_chain_intact == true and
	.audit.historical_integrity == "BROKEN" and
	.posture == "CRITICAL"
' >/dev/null; then
	pass "historical broken verdict survives later intact rotations"
else
	fail "later rotation erased the historical broken verdict"
fi

INTACT_LOG="${TEST_ROOT}/intact.jsonl"
AUDIT_LOG_FILE="$INTACT_LOG" AUDIT_QUIET=true \
	"$AUDIT_HELPER" log operation.verify "intact"
intact_sha256="$(sha256_file "$INTACT_LOG")"
intact_rc=0
AUDIT_LOG_FILE="$INTACT_LOG" AUDIT_QUIET=true \
	"$AUDIT_HELPER" recover --reason "must refuse" >/dev/null 2>&1 || intact_rc=$?
if [[ "$intact_rc" -ne 0 && "$(sha256_file "$INTACT_LOG")" == "$intact_sha256" ]] &&
	[[ "$(archive_count "$INTACT_LOG")" -eq 0 ]]; then
	pass "recovery refuses an intact chain without changing it"
else
	fail "recovery changed or accepted an intact chain"
fi

AMBIGUOUS_LOG="${TEST_ROOT}/ambiguous.jsonl"
printf '{"broken":true}\n' >"$AMBIGUOUS_LOG"
ambiguous_sha256="$(sha256_file "$AMBIGUOUS_LOG")"
ambiguous_rc=0
AUDIT_LOG_FILE="$AMBIGUOUS_LOG" AUDIT_QUIET=true \
	"$AUDIT_HELPER" recover --reason "must refuse" >/dev/null 2>&1 || ambiguous_rc=$?
if [[ "$ambiguous_rc" -ne 0 && "$(sha256_file "$AMBIGUOUS_LOG")" == "$ambiguous_sha256" ]] &&
	[[ "$(archive_count "$AMBIGUOUS_LOG")" -eq 0 ]]; then
	pass "recovery refuses ambiguous evidence without changing it"
else
	fail "recovery changed or accepted ambiguous evidence"
fi

CONCURRENT_LOG="${TEST_ROOT}/concurrent.jsonl"
create_broken_log "$CONCURRENT_LOG"
concurrent_initial_count="$(wc -l <"$CONCURRENT_LOG" | tr -d ' ')"
AUDIT_LOG_FILE="$CONCURRENT_LOG" AUDIT_QUIET=true AUDIT_LOCK_TIMEOUT_SECONDS=30 \
	"$AUDIT_HELPER" recover --reason "concurrent recovery one" &
recovery_one_pid=$!
AUDIT_LOG_FILE="$CONCURRENT_LOG" AUDIT_QUIET=true AUDIT_LOCK_TIMEOUT_SECONDS=30 \
	"$AUDIT_HELPER" recover --reason "concurrent recovery two" &
recovery_two_pid=$!
writer_pids=""
for index in $(seq 1 12); do
	AUDIT_LOG_FILE="$CONCURRENT_LOG" AUDIT_QUIET=true AUDIT_LOCK_TIMEOUT_SECONDS=30 \
		"$AUDIT_HELPER" log operation.verify "concurrent-${index}" &
	writer_pids="${writer_pids} $!"
done
concurrent_failed=false
if ! wait "$recovery_one_pid"; then
	concurrent_failed=true
fi
if ! wait "$recovery_two_pid"; then
	concurrent_failed=true
fi
for writer_pid in $writer_pids; do
	if ! wait "$writer_pid"; then
		concurrent_failed=true
	fi
done

concurrent_archive="$(first_archive "$CONCURRENT_LOG")"
concurrent_total=$(($(wc -l <"$CONCURRENT_LOG") + $(wc -l <"$concurrent_archive")))
expected_total=$((concurrent_initial_count + 12 + 1))
if [[ "$concurrent_failed" == "false" ]] &&
	[[ "$(archive_count "$CONCURRENT_LOG")" -eq 1 ]] &&
	[[ "$concurrent_total" -eq "$expected_total" ]]; then
	pass "concurrent recovery and append attempts serialize without data loss"
else
	fail "concurrent recovery and append attempts lost data or created multiple archives"
fi
assert_chain_intact "concurrent recovery leaves an intact successor" "$CONCURRENT_LOG"
assert_chain_broken "concurrent recovery preserves the invalid segment" "$concurrent_archive"

if [[ "$FAIL" -gt 0 ]]; then
	printf '%s audit recovery test(s) failed; %s passed\n' "$FAIL" "$PASS" >&2
	exit 1
fi
printf 'All %s audit recovery tests passed.\n' "$PASS"
exit 0
