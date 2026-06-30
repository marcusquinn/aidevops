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

if [[ "${1:-} ${2:-}" == "run view" ]]; then
	case "${TEST_CHECK_SCENARIO:-terminal_failure}" in
	infra_timeout)
		printf '%s\n' 'Lint Run timed out after 10m'
		;;
	log_exit_143)
		printf '%s\n' 'Lint Run ##[error]Process completed with exit code 143.'
		;;
	*)
		printf '%s\n' 'Lint Run actual lint error in source file'
		;;
	esac
	exit 0
fi

	if [[ "${1:-} ${2:-}" == "pr checks" ]]; then
		_is_required=0
		[[ "$*" == *" --required "* || "$*" == *" --required"* ]] && _is_required=1
	if [[ "$*" == *"name,bucket,conclusion,link"* ]]; then
		case "${TEST_CHECK_SCENARIO:-terminal_failure}:${_is_required}" in
			terminal_failure:1 | log_exit_143:1)
				printf '%s\n' '[{"name":"Lint","bucket":"fail","conclusion":"failure","link":"https://github.com/owner/repo/actions/runs/123/job/456"}]'
				;;
			pending_only:*|mixed_pending_pass:*)
				printf '[]\n'
				;;
			infra_timeout:1)
				printf '%s\n' '[{"name":"Lint","bucket":"fail","conclusion":"failure","link":"https://github.com/owner/repo/actions/runs/123/job/456"}]'
				;;
			advisory_failure:0)
				printf '%s\n' '[{"name":"Docs","bucket":"fail","conclusion":"failure","link":"https://github.com/owner/repo/actions/runs/123/job/789"}]'
				;;
			advisory_failure:1)
				printf '[]\n'
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
	local fn_src="" review_gate_src=""
	review_gate_src=$(extract_function _handle_changes_requested_review_gate "$MERGE_SCRIPT")
	fn_src=$(extract_function _process_single_ready_pr "$MERGE_SCRIPT")
	[[ -n "$review_gate_src" && -n "$fn_src" ]] || return 1

	_OW_LABEL_PAT=",origin:worker,"
	PULSE_MERGE_CLOSE_CONFLICTING=false
	DRY_RUN=0
	GATE_CALLS=0
	GATE_REVIEW_ARG=""
	RESOLVE_CALLS=0
	ROUTE_CALLS=0
	ROUTE_ARGS=""
	ROUTE_LABELS=""
	DISMISS_CALLS=0
	PR_REQUIRED_CHECKS_RC=1
	REBASE_RETRY_RC=1
	REFRESHED_MERGEABLE="UNKNOWN"

	_resolve_pr_mergeable_status() { local pr_number="$1" repo_slug="$2" mergeable="$3"; [[ -n "$pr_number$repo_slug$mergeable" ]]; RESOLVE_CALLS=$((RESOLVE_CALLS + 1)); return 0; }
	_pmp_refresh_unknown_mergeable_state_into() { local dest_var="$1" pr_number="$2" repo_slug="$3" mergeable="$4"; [[ -n "$pr_number$repo_slug$mergeable" ]]; printf -v "$dest_var" '%s' "$REFRESHED_MERGEABLE"; return 0; }
	_extract_linked_issue() { local pr_number="$1" repo_slug="$2"; [[ -n "$pr_number$repo_slug" ]]; printf '42\n'; return 0; }
	_check_pr_merge_gates() { local pr_number="$1" repo_slug="$2" pr_author="$3" pr_review="$4" linked_issue="$5"; [[ -n "$pr_number$repo_slug$pr_author$pr_review$linked_issue" ]]; GATE_CALLS=$((GATE_CALLS + 1)); GATE_REVIEW_ARG="$pr_review"; return 0; }
	_pr_required_checks_pass() { local pr_number="$1" repo_slug="$2"; [[ -n "$pr_number$repo_slug" ]]; if [[ "$PR_REQUIRED_CHECKS_RC" -eq 0 ]]; then return 0; fi; return 1; }
	_check_required_checks_passing() { local repo_slug="$1" pr_number="$2"; [[ -n "$repo_slug$pr_number" ]]; return 1; }
	_is_trusted_dependabot_update_pr() { local pr_number="$1" repo_slug="$2" pr_author="$3"; [[ -n "$pr_number$repo_slug$pr_author" ]]; return 1; }
	_trusted_dependabot_non_review_checks_green() { local pr_number="$1" repo_slug="$2" pr_obj="$3"; [[ -n "$pr_number$repo_slug$pr_obj" ]]; return 1; }
	_attempt_pr_ci_rebase_retry() { local pr_number="$1" repo_slug="$2"; [[ -n "$pr_number$repo_slug" ]]; return "$REBASE_RETRY_RC"; }
	_route_pr_to_fix_worker() { local pr_number="$1" repo_slug="$2" linked_issue="$3" mode="$4" pr_labels="${5:-}"; ROUTE_CALLS=$((ROUTE_CALLS + 1)); ROUTE_ARGS="${pr_number}|${repo_slug}|${linked_issue}|${mode}"; ROUTE_LABELS="$pr_labels"; return 0; }
	_pulse_merge_dismiss_coderabbit_nits() { local pr_number="$1" repo_slug="$2"; [[ -n "$pr_number$repo_slug" ]]; DISMISS_CALLS=$((DISMISS_CALLS + 1)); if [[ "${DISMISS_NITS_RC:-0}" -eq 0 ]]; then return 0; fi; return 1; }
	_attempt_pr_update_branch() { return 1; }
	_close_conflicting_pr() { return 0; }
	_pmp_normalize_mergeable_state_into() { return 0; }
	printf -v PR_OBJECT '%s' '{"number":100,"mergeable":"MERGEABLE","reviewDecision":"","author":{"login":"worker-bot"},"title":"t1: fix"}'

	# shellcheck disable=SC1090
	eval "$review_gate_src"
	# shellcheck disable=SC1090
	eval "$fn_src"
	return 0
}

define_feedback_helpers() {
	local fns=(
		_build_ci_feedback_section
		_ci_check_url_has_infra_timeout_log
		_ci_actionable_failed_checks_markdown
		_ci_terminal_failed_check_results
		_append_feedback_to_issue
		_transition_issue_for_redispatch
		_close_and_label_feedback_pr
		_dispatch_ci_fix_worker
	)
	local fn fn_src
	gh_issue_edit_safe() { gh issue edit "$@"; return $?; }
	_emit_ci_failure_guidance_blocks() { return 0; }
	_classify_ci_failures_by_pattern() { local failing_names="$1"; printf '%s' "$failing_names" >"${TEST_ROOT}/classified-names.txt"; return 0; }
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

test_rebase_success_defers_ci_repair_route() {
	setup_test_env
	define_process_helper || { print_result "defines process helper for rebase deferral" 1 "could not extract _process_single_ready_pr"; teardown_test_env; return 0; }

	local rc=0
	REBASE_RETRY_RC=0
	_process_single_ready_pr "owner/repo" "$PR_OBJECT" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		print_result "successful CI-drift rebase defers CI repair routing" 1 "Expected skip return 1, got ${rc}"
	elif [[ "$GATE_CALLS" -ne 1 ]]; then
		print_result "successful CI-drift rebase defers CI repair routing" 1 "gate_calls=${GATE_CALLS}"
	elif [[ "$ROUTE_CALLS" -ne 0 ]]; then
		print_result "successful CI-drift rebase defers CI repair routing" 1 "route_calls=${ROUTE_CALLS}, route_args=${ROUTE_ARGS}"
	else
		print_result "successful CI-drift rebase defers CI repair routing" 0
	fi
	teardown_test_env
	return 0
}

test_changes_requested_unknown_routes_before_mergeable_skip() {
	setup_test_env
	define_process_helper || { print_result "defines process helper for review routing" 1 "could not extract _process_single_ready_pr or review gate"; teardown_test_env; return 0; }

	local pr_object rc=0
	printf -v pr_object '%s' '{"number":554,"mergeable":"UNKNOWN","reviewDecision":"CHANGES_REQUESTED","author":{"login":"worker-bot"},"title":"GH#500: fix","updatedAt":"2026-06-21T00:00:00Z","headRefOid":"sha554","headRefName":"fix/review","baseRefName":"main","labels":[{"name":"origin:worker"},{"name":"status:in-review"}],"isDraft":false}'
	_process_single_ready_pr "owner/repo" "$pr_object" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		print_result "CHANGES_REQUESTED+UNKNOWN routes before mergeability skip" 1 "Expected skip return 1, got ${rc}"
	elif [[ "$ROUTE_CALLS" -ne 1 || "$ROUTE_ARGS" != "554|owner/repo|42|review" ]]; then
		print_result "CHANGES_REQUESTED+UNKNOWN routes before mergeability skip" 1 "route_calls=${ROUTE_CALLS}, route_args=${ROUTE_ARGS}"
	elif [[ "$RESOLVE_CALLS" -ne 0 || "$GATE_CALLS" -ne 0 ]]; then
		print_result "CHANGES_REQUESTED+UNKNOWN routes before mergeability skip" 1 "resolve_calls=${RESOLVE_CALLS}, gate_calls=${GATE_CALLS}"
	else
		print_result "CHANGES_REQUESTED+UNKNOWN routes before mergeability skip" 0
	fi
	teardown_test_env
	return 0
}

test_coderabbit_nits_ok_dismissed_once_before_late_gate() {
	setup_test_env
	define_process_helper || { print_result "defines process helper for coderabbit review routing" 1 "could not extract _process_single_ready_pr or review gate"; teardown_test_env; return 0; }

	local pr_object rc=0
	DRY_RUN=1
	PR_REQUIRED_CHECKS_RC=0
	printf -v pr_object '%s' '{"number":555,"mergeable":"UNKNOWN","reviewDecision":"CHANGES_REQUESTED","author":{"login":"worker-bot"},"title":"GH#501: fix","updatedAt":"2026-06-21T00:00:00Z","headRefOid":"sha555","headRefName":"fix/nits","baseRefName":"main","labels":[{"name":"origin:worker"},{"name":"status:in-review"},{"name":"coderabbit-nits-ok"}],"isDraft":false}'
	_process_single_ready_pr "owner/repo" "$pr_object" || rc=$?

	if [[ "$rc" -ne 0 ]]; then
		print_result "coderabbit-nits-ok dismissal is not reprocessed by late gate" 1 "Expected dry-run success return 0, got ${rc}"
	elif [[ "$DISMISS_CALLS" -ne 1 ]]; then
		print_result "coderabbit-nits-ok dismissal is not reprocessed by late gate" 1 "dismiss_calls=${DISMISS_CALLS}"
	elif [[ "$GATE_CALLS" -ne 1 || "$GATE_REVIEW_ARG" != "NONE" ]]; then
		print_result "coderabbit-nits-ok dismissal is not reprocessed by late gate" 1 "gate_calls=${GATE_CALLS}, gate_review=${GATE_REVIEW_ARG}"
	elif [[ "$ROUTE_CALLS" -ne 0 ]]; then
		print_result "coderabbit-nits-ok dismissal is not reprocessed by late gate" 1 "route_calls=${ROUTE_CALLS}"
	else
		print_result "coderabbit-nits-ok dismissal is not reprocessed by late gate" 0
	fi
	teardown_test_env
	return 0
}

test_changes_requested_explicit_empty_labels_skip_refetch() {
	setup_test_env
	define_process_helper || { print_result "defines process helper for explicit empty labels" 1 "could not extract review gate"; teardown_test_env; return 0; }

	: >"$GH_LOG"
	_handle_changes_requested_review_gate "556" "owner/repo" "CHANGES_REQUESTED" "42" "" || true

	local label_fetch_count=0
	label_fetch_count=$(grep -c -- '--json labels' "$GH_LOG" || true)
	[[ "$label_fetch_count" =~ ^[0-9]+$ ]] || label_fetch_count=0
	if [[ "$label_fetch_count" -ne 0 ]]; then
		print_result "explicit empty PR labels do not refetch labels" 1 "label_fetch_count=${label_fetch_count}"
	elif [[ "$ROUTE_CALLS" -ne 1 || "$ROUTE_ARGS" != "556|owner/repo|42|review" ]]; then
		print_result "explicit empty PR labels do not refetch labels" 1 "route_calls=${ROUTE_CALLS}, route_args=${ROUTE_ARGS}"
	else
		print_result "explicit empty PR labels do not refetch labels" 0
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
	elif ! grep -qF 'no actionable failed checks with URLs' "$LOGFILE"; then
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

	if ! grep -qF '**Lint**: failure — [check URL](https://github.com/owner/repo/actions/runs/123/job/456)' "${TEST_ROOT}/issue-body.txt"; then
		print_result "terminal failure emits conclusion and check URL" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	else
		print_result "terminal failure emits conclusion and check URL" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_skips_infra_timeout_checks() {
	setup_test_env
	TEST_CHECK_SCENARIO="infra_timeout"
	define_feedback_helpers || { print_result "defines feedback helpers for infra timeout" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	if grep -qF 'CI Repair Feedback' "${TEST_ROOT}/issue-body.txt"; then
		print_result "infra timeout checks do not emit CI repair feedback" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	else
		print_result "infra timeout checks do not emit CI repair feedback" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_skips_failed_check_with_exit_143_log() {
	setup_test_env
	TEST_CHECK_SCENARIO="log_exit_143"
	define_feedback_helpers || { print_result "defines feedback helpers for log exit 143" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	if grep -qF 'CI Repair Feedback' "${TEST_ROOT}/issue-body.txt"; then
		print_result "failed check with exit 143 log does not emit CI repair feedback" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	elif ! grep -qF 'classified as infra-timeout' "$LOGFILE"; then
		print_result "failed check with exit 143 log records infra-timeout classification" 1 "Log: $(cat "$LOGFILE")"
	else
		print_result "failed check with exit 143 log does not emit CI repair feedback" 0
	fi
	teardown_test_env
	return 0
}

test_ci_feedback_emits_advisory_failure_when_required_clean() {
	setup_test_env
	TEST_CHECK_SCENARIO="advisory_failure"
	define_feedback_helpers || { print_result "defines feedback helpers for advisory failure" 1 "could not extract feedback helpers"; teardown_test_env; return 0; }

	_dispatch_ci_fix_worker "100" "owner/repo" "42"

	if ! grep -qF '**Docs**: failure — [check URL](https://github.com/owner/repo/actions/runs/123/job/789)' "${TEST_ROOT}/issue-body.txt"; then
		print_result "advisory-only failure emits CI repair feedback" 1 "Body: $(cat "${TEST_ROOT}/issue-body.txt")"
	elif ! grep -qF 'Docs' "${TEST_ROOT}/classified-names.txt"; then
		print_result "advisory-only failure populates classification names" 1 "Names: $(cat "${TEST_ROOT}/classified-names.txt" 2>/dev/null || true)"
	else
		print_result "advisory-only failure emits CI repair feedback with classification names" 0
	fi
	teardown_test_env
	return 0
}

main() {
	test_red_pr_passes_gates_before_repair_route
	test_rebase_success_defers_ci_repair_route
	test_changes_requested_unknown_routes_before_mergeable_skip
	test_coderabbit_nits_ok_dismissed_once_before_late_gate
	test_changes_requested_explicit_empty_labels_skip_refetch
	test_ci_feedback_dedupes_by_pr_head_sha
	test_ci_feedback_skips_pending_only_checks
	test_ci_feedback_skips_mixed_pending_pass_checks
	test_ci_feedback_emits_terminal_failure_with_conclusion_and_url
	test_ci_feedback_skips_infra_timeout_checks
	test_ci_feedback_skips_failed_check_with_exit_143_log
	test_ci_feedback_emits_advisory_failure_when_required_clean

	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
