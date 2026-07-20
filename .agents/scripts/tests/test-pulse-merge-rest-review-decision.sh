#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for the pulse merge REST reviewDecision fallback.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_PROCESS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
TIMEOUT_LOG=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	[[ -n "$message" ]] && printf '       %s\n' "$message"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	TIMEOUT_LOG="${TEST_ROOT}/timeout.log"
	export TIMEOUT_LOG
	: >"$TIMEOUT_LOG"
	unset TEST_TIMEOUT_FAIL
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	write_gh_mock
	# shellcheck source=/dev/null
	source "$MERGE_PROCESS_SCRIPT"
	return 0
}

_gh_with_timeout() {
	local operation="$1"
	shift
	printf '%s %s\n' "$operation" "$*" >>"$TIMEOUT_LOG"
	if [[ "${TEST_TIMEOUT_FAIL:-false}" == "true" ]]; then
		return 124
	fi
	"$@"
	return $?
}

gh_pr_view() {
	printf ''
	return 0
}

write_gh_mock() {
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "api --paginate" && "${3:-}" == "repos/owner/repo/pulls/123/reviews" ]]; then
	cat <<'JSON'
[
  {"user":{"login":"reviewer"},"state":"CHANGES_REQUESTED","submitted_at":"2026-07-01T10:00:00Z"},
  {"user":{"login":"reviewer"},"state":"COMMENTED","submitted_at":"2026-07-01T11:00:00Z"},
  {"user":{"login":"other"},"state":"APPROVED","submitted_at":"2026-07-01T12:00:00Z"}
]
JSON
	exit 0
fi

if [[ "${1:-} ${2:-}" == "api --paginate" && "${3:-}" == "repos/owner/repo/pulls/124/reviews" ]]; then
	cat <<'JSON'
[
  {"user":{"login":"reviewer"},"state":"CHANGES_REQUESTED","submitted_at":"2026-07-01T10:00:00Z"},
  {"user":{"login":"reviewer"},"state":"DISMISSED","submitted_at":"2026-07-01T11:00:00Z"},
  {"user":{"login":"other"},"state":"COMMENTED","submitted_at":"2026-07-01T12:00:00Z"}
]
JSON
	exit 0
fi

printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

cleanup_test_env() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

assert_review_decision() {
	local test_name="$1"
	local pr_number="$2"
	local expected_decision="$3"
	local actual_decision=""

	actual_decision=$(_pmp_rest_review_decision_from_reviews "$pr_number" "owner/repo")
	if [[ "$actual_decision" == "$expected_decision" ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "expected ${expected_decision}, got ${actual_decision}"
	return 0
}

test_review_fetch_uses_bounded_read() {
	: >"$TIMEOUT_LOG"
	assert_review_decision "REST fallback still derives active review state" "123" "CHANGES_REQUESTED"
	if grep -Fqx 'read gh api --paginate repos/owner/repo/pulls/123/reviews' "$TIMEOUT_LOG"; then
		print_result "REST fallback wraps paginated reviews in a bounded read" 0
	else
		print_result "REST fallback wraps paginated reviews in a bounded read" 1 \
			"timeout calls=$(tr '\n' ';' <"$TIMEOUT_LOG")"
	fi
	return 0
}

test_timeout_failure_preserves_unknown_decision() {
	: >"$TIMEOUT_LOG"
	export TEST_TIMEOUT_FAIL="true"
	local decision=""
	_pmp_refresh_unknown_review_decision_into decision "125" "owner/repo" "UNKNOWN"
	unset TEST_TIMEOUT_FAIL
	if [[ "$decision" == "UNKNOWN" ]] &&
		grep -Fqx 'read gh api --paginate repos/owner/repo/pulls/125/reviews' "$TIMEOUT_LOG"; then
		print_result "timed-out REST review fetch returns UNKNOWN without blocking" 0
	else
		print_result "timed-out REST review fetch returns UNKNOWN without blocking" 1 \
			"decision=${decision}, timeout calls=$(tr '\n' ';' <"$TIMEOUT_LOG")"
	fi
	return 0
}

main() {
	setup_test_env
	trap cleanup_test_env EXIT

	test_review_fetch_uses_bounded_read
	assert_review_decision "DISMISSED review clears prior changes requested" "124" "NONE"
	test_timeout_failure_preserves_unknown_decision

	printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
