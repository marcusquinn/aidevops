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
	_OW_LABEL_PAT=",origin:worker,"
	unset AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST
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
	local src_repo_path="" src_dispatch="" src_maybe_dispatch="" src_enabled="" src_changes_gate=""
	src_repo_path=$(awk '
		/^_pulse_merge_repo_path_for_slug\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	src_dispatch=$(awk '
		/^_pulse_merge_dispatch_review_thread_remediation\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	src_maybe_dispatch=$(awk '
		/^_pulse_merge_maybe_dispatch_review_thread_remediation\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	src_enabled=$(awk '
		/^_pulse_merge_changes_requested_thread_remediation_first_enabled\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	src_changes_gate=$(awk '
		/^_handle_changes_requested_review_gate\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$src_repo_path" || -z "$src_dispatch" || -z "$src_maybe_dispatch" || -z "$src_enabled" || -z "$src_changes_gate" ]]; then
		printf 'ERROR: could not extract helpers from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src_repo_path"
	# shellcheck disable=SC1090
	eval "$src_dispatch"
	# shellcheck disable=SC1090
	eval "$src_maybe_dispatch"
	# shellcheck disable=SC1090
	eval "$src_enabled"
	# shellcheck disable=SC1090
	eval "$src_changes_gate"
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

test_changes_requested_routes_by_default() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		printf 'route %s %s\n' "$pr_number" "$repo_slug" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	if _handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker"; then
		print_result "CHANGES_REQUESTED routes by default" 1 \
			"Expected gate to skip merge after default routing"
	elif [[ ! -s "$SCANNER_LOG" ]] && grep -q 'route 77 owner/repo' "$route_log"; then
		print_result "CHANGES_REQUESTED routes by default" 0
	else
		print_result "CHANGES_REQUESTED routes by default" 1 \
			"scanner=$(tr '\n' ';' <"$SCANNER_LOG"), route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_opt_in_dispatches_remediation_without_routing() {
	setup_test_env
	export AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		printf 'route %s %s\n' "$pr_number" "$repo_slug" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	if _handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker"; then
		print_result "opt-in CHANGES_REQUESTED remediation keeps PR open before routing" 1 \
			"Expected gate to skip merge after queuing remediation"
	elif grep -q 'include_human=true args=dispatch-pr owner/repo' "$SCANNER_LOG" \
		&& grep -q ' 77$' "$SCANNER_LOG" \
		&& [[ ! -s "$route_log" ]] \
		&& grep -q 'review-thread remediation queued for PR #77 in owner/repo after CHANGES_REQUESTED review gate' "$LOGFILE"; then
		print_result "opt-in CHANGES_REQUESTED remediation keeps PR open before routing" 0
	else
		print_result "opt-in CHANGES_REQUESTED remediation keeps PR open before routing" 1 \
			"scanner=$(tr '\n' ';' <"$SCANNER_LOG"), route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_routes_when_remediation_unavailable() {
	setup_test_env
	export AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1
	chmod -x "${TEST_ROOT}/scripts/pr-review-thread-response-scanner.sh"
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		printf 'route %s %s\n' "$pr_number" "$repo_slug" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	if _handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker"; then
		print_result "CHANGES_REQUESTED falls back to routing when remediation unavailable" 1 \
			"Expected gate to skip merge after fallback routing"
	elif grep -q 'route 77 owner/repo' "$route_log" \
		&& grep -q 'review-thread remediation skipped for PR #77 in owner/repo: scanner missing or not executable' "$LOGFILE"; then
		print_result "CHANGES_REQUESTED falls back to routing when remediation unavailable" 0
	else
		print_result "CHANGES_REQUESTED falls back to routing when remediation unavailable" 1 \
			"route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_skips_remediation_for_external_contributor() {
	setup_test_env
	export AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		printf 'route %s %s\n' "$pr_number" "$repo_slug" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	if _handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker,external-contributor"; then
		print_result "external contributor CHANGES_REQUESTED skips remediation" 1 \
			"Expected gate to skip merge"
	elif [[ ! -s "$SCANNER_LOG" ]] && grep -q 'route 77 owner/repo' "$route_log"; then
		print_result "external contributor CHANGES_REQUESTED skips remediation" 0
	else
		print_result "external contributor CHANGES_REQUESTED skips remediation" 1 \
			"scanner=$(tr '\n' ';' <"$SCANNER_LOG"), route=$(tr '\n' ';' <"$route_log")"
	fi
	teardown_test_env
	return 0
}

main() {
	test_unresolved_conversation_dispatches_targeted_human_thread_remediation
	test_other_merge_failures_do_not_dispatch_review_thread_remediation
	test_changes_requested_routes_by_default
	test_changes_requested_opt_in_dispatches_remediation_without_routing
	test_changes_requested_routes_when_remediation_unavailable
	test_changes_requested_skips_remediation_for_external_contributor
	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
