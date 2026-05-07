#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for CI repair routing from the deterministic merge pass.
# A red/pending trusted PR must pass the normal merge gates first, then route
# exactly one repair action for the same PR/head SHA instead of silently
# accumulating in the open PR backlog.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
FEEDBACK_SCRIPT="${SCRIPT_DIR}/../pulse-merge-feedback.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

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
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG
	export TEST_CHECK_SCENARIO="terminal_failure"
	printf 'Original issue body.\n' >"${TEST_ROOT}/issue-body.txt"
	write_gh_mock
	return 0
}


write_gh_mock() {
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

if [[ "${1:-} ${2:-}" == "pr view" ]]; then
	if [[ "$*" == *"--json labels"* ]]; then
		printf 'origin:worker\n'
		exit 0
	fi
	if [[ "$*" == *"--json headRefOid"* ]]; then
		printf 'abc123\n'
		exit 0
	fi
	exit 0
fi

if [[ "${1:-} ${2:-}" == "pr checks" ]]; then
	_is_required=0
	[[ "$*" == *" --required "* || "$*" == *" --required"* ]] && _is_required=1
	if [[ "$*" == *"| .name]"* ]]; then
		case "${TEST_CHECK_SCENARIO:-terminal_failure}:${_is_required}" in
		terminal_failure:1)
			printf 'Lint\n'
			;;
		esac
		exit 0
	fi
	if [[ "$*" == *"name,bucket,conclusion,link"* ]]; then
		case "${TEST_CHECK_SCENARIO:-terminal_failure}:${_is_required}" in
		terminal_failure:1)
			printf '%s\n' '- **Lint**: failure — [check URL](https://example.invalid/check)'
			;;
		pending_only:*|mixed_pending_pass:*)
			: ;;
		advisory_failure:0)
			printf '%s\n' '- **Docs** (advisory, not merge-blocking): failure — [check URL](https://example.invalid/advisory)'
			;;
		esac
		exit 0
	fi
	exit 0
fi

if [[ "${1:-} ${2:-}" == "issue view" ]]; then
	if [[ "$*" == *"--json body"* ]]; then
		cat "${TEST_ROOT}/issue-body.txt"
		exit 0
	fi
	if [[ "$*" == *"--json assignees"* ]]; then
		exit 0
	fi
	exit 0
fi

if [[ "${1:-} ${2:-}" == "issue edit" ]]; then
	while [[ $# -gt 0 ]]; do
		if [[ "$1" == "--body" ]]; then
			shift
			printf '%s' "$1" >"${TEST_ROOT}/issue-body.txt"
			exit 0
		fi
		shift
	done
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

extract_function() {
	local fn_name="$1"
	local source_file="$2"
	awk -v name="$fn_name" '
		$0 ~ "^" name "\\(\\) \\{" { capture = 1 }
		capture { print }
		capture && /^}$/ { capture = 0; exit }
	' "$source_file"
	return 0
}

define_process_helper() {
	local fn_src=""
	fn_src=$(extract_function _process_single_ready_pr "$MERGE_SCRIPT")
	[[ -n "$fn_src" ]] || return 1

	_OW_LABEL_PAT=",origin:worker,"
	PULSE_MERGE_CLOSE_CONFLICTING=false
	DRY_RUN=0
	GATE_CALLS=0
	ROUTE_CALLS=0
	ROUTE_ARGS=""

	_resolve_pr_mergeable_status() { local pr_number="$1" repo_slug="$2" mergeable="$3"; [[ -n "$pr_number$repo_slug$mergeable" ]]; return 0; }
	_extract_linked_issue() { local pr_number="$1" repo_slug="$2"; [[ -n "$pr_number$repo_slug" ]]; printf '42\n'; return 0; }
	_check_pr_merge_gates() { local pr_number="$1" repo_slug="$2" pr_author="$3" pr_review="$4" linked_issue="$5"; [[ -n "$pr_number$repo_slug$pr_author$pr_review$linked_issue" ]]; GATE_CALLS=$((GATE_CALLS + 1)); return 0; }
	_pr_required_checks_pass() { local pr_number="$1" repo_slug="$2"; [[ -n "$pr_number$repo_slug" ]]; return 1; }
	_check_required_checks_passing() { local repo_slug="$1" pr_number="$2"; [[ -n "$repo_slug$pr_number" ]]; return 1; }
	_attempt_pr_ci_rebase_retry() { local pr_number="$1" repo_slug="$2"; [[ -n "$pr_number$repo_slug" ]]; return 1; }
	_route_pr_to_fix_worker() { local pr_number="$1" repo_slug="$2" linked_issue="$3" mode="$4"; ROUTE_CALLS=$((ROUTE_CALLS + 1)); ROUTE_ARGS="${pr_number}|${repo_slug}|${linked_issue}|${mode}"; return 0; }
	_attempt_pr_update_branch() { return 1; }
	_close_conflicting_pr() { return 0; }
	printf -v PR_OBJECT '%s' '{"number":100,"mergeable":"MERGEABLE","reviewDecision":"","author":{"login":"worker-bot"},"title":"t1: fix"}'

	# shellcheck disable=SC1090
	eval "$fn_src"
	return 0
}

define_feedback_helpers() {
	local fns=(
		_build_ci_feedback_section
		_append_feedback_to_issue
		_transition_issue_for_redispatch
		_close_and_label_feedback_pr
		_dispatch_ci_fix_worker
	)
	local fn fn_src
	gh_issue_edit_safe() { gh issue edit "$@"; return $?; }
	_emit_ci_failure_guidance_blocks() { return 0; }
	_classify_ci_failures_by_pattern() { return 0; }
	for fn in "${fns[@]}"; do
		fn_src=$(extract_function "$fn" "$FEEDBACK_SCRIPT")
		[[ -n "$fn_src" ]] || return 1
		# shellcheck disable=SC1090
		eval "$fn_src"
	done
	return 0
}

test_red_pr_passes_gates_before_repair_route() {
	setup_test_env
	define_process_helper || { print_result "defines process helper" 1 "could not extract _process_single_ready_pr"; teardown_test_env; return 0; }

	_process_single_ready_pr "owner/repo" "$PR_OBJECT" || true

	if [[ "$GATE_CALLS" -ne 1 ]]; then
		print_result "red PR runs merge gates before CI repair routing" 1 "Expected 1 gate call, got ${GATE_CALLS}"
	elif [[ "$ROUTE_CALLS" -ne 1 || "$ROUTE_ARGS" != "100|owner/repo|42|ci" ]]; then
		print_result "red PR routes one CI repair after gates pass" 1 "route_calls=${ROUTE_CALLS}, route_args=${ROUTE_ARGS}"
	else
		print_result "red PR passes gates then routes exactly one CI repair" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_dedupes_by_pr_head_sha() {
	setup_test_env
	define_feedback_helpers || { print_result "defines feedback helpers" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	local edit_count marker_count
	edit_count=$(grep -c 'gh issue edit .*--body' "$GH_LOG" || true)
	[[ "$edit_count" =~ ^[0-9]+$ ]] || edit_count=0
	marker_count=$(grep -c '<!-- ci-feedback:PR100:SHAabc123 -->' "${TEST_ROOT}/issue-body.txt" || true)
	[[ "$marker_count" =~ ^[0-9]+$ ]] || marker_count=0

	if [[ "$edit_count" -ne 1 || "$marker_count" -ne 1 ]]; then
		print_result "CI feedback dedupes per PR/head SHA" 1 "issue_edit_count=${edit_count}, marker_count=${marker_count}"
	else
		print_result "CI feedback dedupes per PR/head SHA" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_skips_pending_only_checks() {
	setup_test_env
	TEST_CHECK_SCENARIO="pending_only"
	define_feedback_helpers || { print_result "defines feedback helpers for pending-only" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	if grep -qF 'CI Repair Feedback' "${TEST_ROOT}/issue-body.txt"; then
		print_result "pending-only checks do not emit CI repair feedback" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	elif ! grep -qF 'no terminal failed checks with URLs' "$LOGFILE"; then
		print_result "pending-only checks log terminal-failure skip" 1 "Log: $(cat "$LOGFILE")"
	else
		print_result "pending-only checks do not emit CI repair feedback" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_skips_mixed_pending_pass_checks() {
	setup_test_env
	TEST_CHECK_SCENARIO="mixed_pending_pass"
	define_feedback_helpers || { print_result "defines feedback helpers for mixed pending/pass" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	if grep -qF 'CI Repair Feedback' "${TEST_ROOT}/issue-body.txt"; then
		print_result "mixed pending/pass checks do not emit CI repair feedback" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	else
		print_result "mixed pending/pass checks do not emit CI repair feedback" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_emits_terminal_failure_with_conclusion_and_url() {
	setup_test_env
	TEST_CHECK_SCENARIO="terminal_failure"
	define_feedback_helpers || { print_result "defines feedback helpers for terminal failure" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	if ! grep -qF '**Lint**: failure — [check URL](https://example.invalid/check)' "${TEST_ROOT}/issue-body.txt"; then
		print_result "terminal failure emits conclusion and check URL" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	else
		print_result "terminal failure emits conclusion and check URL" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_labels_advisory_failure_when_not_required() {
	setup_test_env
	TEST_CHECK_SCENARIO="advisory_failure"
	define_feedback_helpers || { print_result "defines feedback helpers for advisory failure" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	if ! grep -qF '**Docs** (advisory, not merge-blocking): failure — [check URL](https://example.invalid/advisory)' "${TEST_ROOT}/issue-body.txt"; then
		print_result "advisory failure is labeled not merge-blocking" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	else
		print_result "advisory failure is labeled not merge-blocking" 0
	fi
	teardown_test_env
	return 0
}

main() {
	test_red_pr_passes_gates_before_repair_route
	test_ci_feedback_dedupes_by_pr_head_sha
	test_ci_feedback_skips_pending_only_checks
	test_ci_feedback_skips_mixed_pending_pass_checks
	test_ci_feedback_emits_terminal_failure_with_conclusion_and_url
	test_ci_feedback_labels_advisory_failure_when_not_required

	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
