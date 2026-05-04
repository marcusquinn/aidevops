#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#4012 / t2769 no_work false trips.
#
# A stale active label + assignee with no dispatch claim comment can be cleaned
# up by stale recovery, but it is not evidence that a worker ever started. That
# recovery must not record stale_timeout/no_work fast-fails, or pre-launch
# canary failures can trip the t2769 no_work circuit breaker without worker
# evidence.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

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
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '  %s\n' "$detail"
	return 0
}

TMP_DIR="$(mktemp -d -t stale-no-worker.XXXXXX)" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT

export LOGFILE="${TMP_DIR}/pulse.log"
SCRIPT_DIR="$TMP_DIR"
HELPER_PATH="${TMP_DIR}/dispatch-dedup-helper.sh"

cat >"$HELPER_PATH" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

cmd="${1:-}"
shift || true

if [[ "$cmd" == "is-assigned" ]]; then
	case "${TEST_STALE_MODE:-no_worker}" in
	no_worker)
		printf '%s\n' 'STALE_RECOVERED: issue #2905 in awardsapp/awardsapp - unassigned runner (no dispatch claim comment found, no recent activity (threshold=600s, interactive=false))'
		exit 1
		;;
	worker)
		printf '%s\n' 'STALE_RECOVERED: issue #2905 in awardsapp/awardsapp - unassigned runner (dispatch claim 900s old, last activity 900s old (threshold=600s, interactive=false))'
		exit 1
		;;
	*)
		printf '%s\n' 'ASSIGNED: issue #2905 in awardsapp/awardsapp is assigned to runner'
		exit 0
		;;
	esac
fi

if [[ "$cmd" == "classify-blocker" ]]; then
	printf 'assigned\n'
	exit 0
fi

exit 1
EOF
chmod +x "$HELPER_PATH"

# shellcheck source=../pulse-dispatch-dedup-layers.sh
source "${SCRIPTS_DIR}/pulse-dispatch-dedup-layers.sh"

FAST_FAIL_CALLS=0
LAST_FAST_FAIL=""
CLASSIFY_LOG="${TMP_DIR}/classify.log"

reset_observations() {
	FAST_FAIL_CALLS=0
	LAST_FAST_FAIL=""
	: >"$LOGFILE"
	: >"$CLASSIFY_LOG"
	return 0
}

fast_fail_record() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="$3"
	local provider="$4"
	local crash_type="$5"
	FAST_FAIL_CALLS=$((FAST_FAIL_CALLS + 1))
	LAST_FAST_FAIL="${issue_number}|${repo_slug}|${reason}|${provider}|${crash_type}"
	return 0
}

_classify_stale_recovery_crash_type() {
	local issue_number="$1"
	local repo_slug="$2"
	: "$issue_number" "$repo_slug"
	printf '%s|%s\n' "$issue_number" "$repo_slug" >>"$CLASSIFY_LOG"
	printf 'no_work'
	return 0
}

test_stale_recovery_without_claim_skips_fast_fail() {
	export TEST_STALE_MODE="no_worker"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "awardsapp/awardsapp" "runner" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		fail "no-worker stale recovery continues dispatch" "expected rc=1, got rc=${rc}"
		return 0
	fi
	if [[ "$FAST_FAIL_CALLS" -ne 0 ]]; then
		fail "no-worker stale recovery skips fast-fail" "fast_fail_record called ${FAST_FAIL_CALLS} time(s): ${LAST_FAST_FAIL}"
		return 0
	fi
	if [[ -s "$CLASSIFY_LOG" ]]; then
		fail "no-worker stale recovery skips classifier" "classifier log: $(tr '\n' ' ' <"$CLASSIFY_LOG")"
		return 0
	fi
	if ! grep -q 'without worker evidence' "$LOGFILE" 2>/dev/null; then
		fail "no-worker stale recovery logs skip reason" "log: $(tr '\n' ' ' <"$LOGFILE")"
		return 0
	fi
	pass "no-worker stale recovery skips no_work fast-fail"
	return 0
}

test_stale_recovery_with_dispatch_claim_records_fast_fail() {
	export TEST_STALE_MODE="worker"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "awardsapp/awardsapp" "runner" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		fail "worker stale recovery continues dispatch" "expected rc=1, got rc=${rc}"
		return 0
	fi
	if [[ "$(tr '\n' ' ' <"$CLASSIFY_LOG")" != "2905|awardsapp/awardsapp " ]]; then
		fail "worker stale recovery classifies crash type" "classifier log: $(tr '\n' ' ' <"$CLASSIFY_LOG")"
		return 0
	fi
	if [[ "$FAST_FAIL_CALLS" -ne 1 ]]; then
		fail "worker stale recovery records fast-fail" "fast_fail_record called ${FAST_FAIL_CALLS} time(s)"
		return 0
	fi
	if [[ "$LAST_FAST_FAIL" != "2905|awardsapp/awardsapp|stale_timeout||no_work" ]]; then
		fail "worker stale recovery fast-fail payload" "payload: ${LAST_FAST_FAIL}"
		return 0
	fi
	pass "worker stale recovery still records no_work fast-fail"
	return 0
}

test_stale_recovery_without_claim_skips_fast_fail
test_stale_recovery_with_dispatch_claim_records_fast_fail

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
