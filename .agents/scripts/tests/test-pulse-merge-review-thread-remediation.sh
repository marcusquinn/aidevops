#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT="$(mktemp -d -t pulse-review-remediation.XXXXXX)"
	mkdir -p "${TEST_ROOT}/scripts" "${TEST_ROOT}/repo" "${TEST_ROOT}/config"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export SCANNER_LOG="${TEST_ROOT}/scanner.log"
	export AIDEVOPS_REPOS_JSON="${TEST_ROOT}/config/repos.json"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"%s"}]}\n' "${TEST_ROOT}/repo" >"$AIDEVOPS_REPOS_JSON"
	cat >"${TEST_ROOT}/scripts/pr-review-thread-response-scanner.sh" <<'SCANNER'
#!/usr/bin/env bash
printf 'include_human=%s args=%s\n' "${PR_REVIEW_THREAD_RESPONSE_INCLUDE_HUMAN:-false}" "$*" >>"${SCANNER_LOG:?}"
exit 0
SCANNER
	chmod +x "${TEST_ROOT}/scripts/pr-review-thread-response-scanner.sh"
	: >"$LOGFILE"
	: >"$SCANNER_LOG"
	_PULSE_MERGE_DIR="${TEST_ROOT}/scripts"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	return 0
}

define_helpers_under_test() {
	local src_repo_path="" src_dispatch=""
	src_repo_path=$(awk '
		/^_pulse_merge_repo_path_for_slug\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	src_dispatch=$(awk '
		/^_pulse_merge_maybe_dispatch_review_thread_remediation\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$src_repo_path" || -z "$src_dispatch" ]]; then
		printf 'ERROR: could not extract helpers from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src_repo_path"
	# shellcheck disable=SC1090
	eval "$src_dispatch"
	return 0
}

test_unresolved_conversation_dispatches_targeted_human_thread_remediation() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	_pulse_merge_maybe_dispatch_review_thread_remediation 77 owner/repo 'GraphQL: A conversation must be resolved before merging'

	if grep -q 'include_human=true args=dispatch-pr owner/repo' "$SCANNER_LOG" \
		&& grep -q ' 77$' "$SCANNER_LOG" \
		&& grep -q 'review-thread remediation queued for PR #77 in owner/repo' "$LOGFILE"; then
		print_result "unresolved conversation queues targeted human-thread remediation" 0
	else
		print_result "unresolved conversation queues targeted human-thread remediation" 1 \
			"scanner=$(tr '\n' ';' <"$SCANNER_LOG"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_other_merge_failures_do_not_dispatch_review_thread_remediation() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	_pulse_merge_maybe_dispatch_review_thread_remediation 77 owner/repo 'GraphQL: required status check is expected'

	if [[ ! -s "$SCANNER_LOG" ]]; then
		print_result "non-conversation merge failures do not dispatch remediation" 0
	else
		print_result "non-conversation merge failures do not dispatch remediation" 1 "scanner=$(tr '\n' ';' <"$SCANNER_LOG")"
	fi
	teardown_test_env
	return 0
}

main() {
	test_unresolved_conversation_dispatches_targeted_human_thread_remediation
	test_other_merge_failures_do_not_dispatch_review_thread_remediation
	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
