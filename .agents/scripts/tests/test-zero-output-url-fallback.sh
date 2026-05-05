#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$1"
	[[ -n "${2:-}" ]] && printf '     %s\n' "$2"
	return 0
}

TMP=$(mktemp -d -t zero-output-url-fallback.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/pulse.log"
FAST_FAIL_STATE_FILE="${TMP}/fast-fail-counter.json"
export LOGFILE FAST_FAIL_STATE_FILE

gh() {
	printf '%s\n' "$*" >>"${TMP}/gh-calls.log"
	return 0
}
export -f gh

# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh" >/dev/null 2>&1 || {
	printf 'FATAL Could not source pulse-dispatch-worker-launch.sh\n'
	exit 1
}

write_state() {
	local count="$1"
	local reason="${2:-worker_noop_zero_output}"
	local crash_type="${3:-}"
	printf '{"owner/repo/123":{"count":%s,"ts":1,"reason":"%s","retry_after":0,"backoff_secs":600,"crash_type":"%s"}}\n' \
		"$count" "$reason" "$crash_type" >"$FAST_FAIL_STATE_FILE"
	return 0
}

write_state 2
fallback_prompt=$(_dlw_prepare_prompt_for_launch 123 owner/repo "Test issue" "FULL EMBEDDED BRIEF")
if printf '%s' "$fallback_prompt" | grep -q 'gh issue view 123 --repo owner/repo' \
	&& ! printf '%s' "$fallback_prompt" | grep -q 'FULL EMBEDDED BRIEF'; then
	pass "repeated zero-output launches switch to URL-only bootstrap prompt"
else
	fail "repeated zero-output launches switch to URL-only bootstrap prompt" "$fallback_prompt"
fi

write_state 1
normal_prompt=$(_dlw_prepare_prompt_for_launch 123 owner/repo "Test issue" "FULL EMBEDDED BRIEF")
if [[ "$normal_prompt" == "FULL EMBEDDED BRIEF" ]]; then
	pass "below fallback threshold keeps embedded prompt"
else
	fail "below fallback threshold keeps embedded prompt" "$normal_prompt"
fi

: >"${TMP}/gh-calls.log"
write_state 4
_dlw_hold_repeated_zero_output 123 owner/repo
hold_rc=$?
gh_calls=$(tr '\n' ' ' <"${TMP}/gh-calls.log" 2>/dev/null || true)
if [[ "$hold_rc" -eq 0 ]] \
	&& printf '%s' "$gh_calls" | grep -q 'needs-brief-rewrite' \
	&& printf '%s' "$gh_calls" | grep -q 'needs-maintainer-review'; then
	pass "continued zero-output launches hold dispatch for brief rewrite"
else
	fail "continued zero-output launches hold dispatch for brief rewrite" \
		"rc=${hold_rc}; gh_calls=${gh_calls}"
fi

write_state 4 runtime partial
non_zero_count=$(_dlw_zero_output_failure_count 123 owner/repo)
if [[ "$non_zero_count" == "0" ]]; then
	pass "non-zero-output failure reasons do not trigger URL-only fallback"
else
	fail "non-zero-output failure reasons do not trigger URL-only fallback" \
		"count=${non_zero_count}"
fi

echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%d / %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
