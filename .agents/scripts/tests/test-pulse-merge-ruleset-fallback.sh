#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#23087: when GitHub rulesets reject the historical
# `gh pr merge --admin` path, deterministic merge retries a normal squash merge
# instead of recording another failed zero-progress cycle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""
_OW_LABEL_PAT=",origin:worker,"

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
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG

	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

if [[ "$1" == "pr" && "$2" == "merge" && "$*" == *"--admin"* ]]; then
	printf '%s\n' 'GraphQL: Repository rule violations found' >&2
	exit 1
fi

if [[ "$1" == "pr" && "$2" == "merge" ]]; then
	exit 0
fi

exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

define_function_under_test() {
	local src_process
	src_process=$(awk '
		/^_process_single_ready_pr\(\) \{/,/^\}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$src_process" ]]; then
		printf 'ERROR: could not extract _process_single_ready_pr from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src_process"
	return 0
}

_pmp_normalize_mergeable_state_into() {
	local __var_name="$1"
	local __value="$2"
	printf -v "$__var_name" '%s' "$__value"
	return 0
}

_resolve_pr_mergeable_status() { return 0; }
_extract_linked_issue() { printf '123'; return 0; }
_check_pr_merge_gates() { return 0; }
_pr_required_checks_pass() { return 0; }
approve_collaborator_pr() { return 0; }
_extract_merge_summary() { printf 'summary'; return 0; }
_retarget_stacked_children() { return 0; }
_pulse_merge_admin_safety_check() { return 0; }
_set_native_auto_merge_or_skip() { return 1; }
_handle_post_merge_actions() { return 0; }
gh_pr_view() { printf '{"labels":[]}'; return 0; }

test_ruleset_violation_retries_without_admin() {
	setup_test_env
	define_function_under_test || { teardown_test_env; return 0; }

	local pr_obj='{"number":77,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"test"}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "ruleset violation fallback returns merged" 1 "Expected 0, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'gh pr merge 77 --repo owner/repo --squash --admin' "$GH_LOG"; then
		print_result "ruleset violation fallback tries admin first" 1 "gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'gh pr merge 77 --repo owner/repo --squash$' "$GH_LOG"; then
		print_result "ruleset violation fallback retries without admin" 1 "gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'retrying without --admin.*GH#23087' "$LOGFILE"; then
		print_result "ruleset violation fallback writes audit log" 1 "pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "ruleset violation fallback retries without admin and succeeds" 0
	teardown_test_env
	return 0
}

test_draft_pr_without_origin_labels_skips_merge_write() {
	setup_test_env
	define_function_under_test || { teardown_test_env; return 0; }

	local pr_obj='{"number":88,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"draft test","labels":[],"isDraft":true}'
	local result=0
	_process_single_ready_pr "owner/repo" "$pr_obj" || result=$?

	if [[ "$result" -ne 1 ]]; then
		print_result "draft PR without origin labels skips merge" 1 "Expected 1, got ${result}; log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	if grep -qE 'gh pr merge 88' "$GH_LOG"; then
		print_result "draft PR without origin labels makes no merge write" 1 "gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'draft PR not eligible for auto-merge.*GH#23525' "$LOGFILE"; then
		print_result "draft PR without origin labels writes skip log" 1 "pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "draft PR without origin labels is blocked before gh pr merge" 0
	teardown_test_env
	return 0
}

main() {
	test_ruleset_violation_retries_without_admin
	test_draft_pr_without_origin_labels_skips_merge_write

	printf '\n=================================\n'
	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	printf '=================================\n'

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
