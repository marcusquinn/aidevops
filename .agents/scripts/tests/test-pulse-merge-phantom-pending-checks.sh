#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for t2922 / GH#21097: _check_required_checks_passing in pulse-merge.sh.
#
# Problem: non-required check contexts (CodeRabbit, qlty, linked-issue-check,
# url-allowlist, etc.) report null/pending status indefinitely and cause
# `gh pr checks --required` to fail-closed via an API quirk, blocking auto-merge
# of origin:worker PRs whose branch-protection-required checks all passed.
#
# Fix: _check_required_checks_passing fetches required contexts directly from
# the branch protection API (authoritative), then cross-references the PR
# statusCheckRollup. If all required-by-protection contexts pass, the function
# returns 0, allowing the origin:worker bypass path to proceed.
#
# Scenarios tested:
#   1. all_required_pass — all required contexts SUCCESS → return 0
#   2. phantom_pending_only — required pass + non-required null/pending → return 0
#   3. one_required_failing — one required FAILURE → return 1
#   4. required_context_absent — required context not in rollup (NOT_FOUND) → return 1
#   5. no_required_contexts — branch protection has empty contexts list → return 0
#   6. default_branch_api_error — can't get default branch → return 1 (fail-closed)
#   7. branch_protection_api_error — can't get branch protection → return 1 (fail-closed)
#   8. rollup_api_error — can't get statusCheckRollup → return 1 (fail-closed)
#
# Strategy: extract _check_required_checks_passing from pulse-merge.sh, eval it,
# and exercise against a mock `gh` stub keyed on MOCK_GH_MODE.
#
# The mock handles three gh invocations (in order of call):
#   1. gh api repos/SLUG               → default branch
#   2. gh api repos/SLUG/branches/...  → required_status_checks
#   3. gh pr view NUM --json statusCheckRollup → PR check states
#
# Mode variables:
#   MOCK_REPO_MODE   — controls gh api repos/<slug> response
#   MOCK_BP_MODE     — controls branch protection required_status_checks response
#   MOCK_ROLLUP_MODE — controls gh pr view statusCheckRollup response

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"

readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%sFAIL%s %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
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
	export GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="three_required"
	export MOCK_ROLLUP_MODE="all_required_pass"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"

	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh for test-pulse-merge-phantom-pending-checks.sh
# Records every invocation and returns canned responses for three call types:
#   1. gh api repos/SLUG                → default branch
#   2. gh api repos/SLUG/branches/...  → required_status_checks contexts
#   3. gh pr view NUM --json statusCheckRollup → PR check states
#
# Mode env vars:
#   MOCK_REPO_MODE   — ok | error
#   MOCK_BP_MODE     — three_required | no_required | error
#   MOCK_ROLLUP_MODE — all_required_pass | phantom_pending | one_required_failing |
#                      required_absent | error
printf '%s\n' "$*" >> "${GH_CALL_LOG}"

# Helper: apply --jq expression from args if present
apply_jq() {
	local json="$1"
	shift
	local jq_expr=""
	local prev=""
	for arg in "$@"; do
		if [[ "$prev" == "--jq" ]]; then
			jq_expr="$arg"
			break
		fi
		prev="$arg"
	done
	if [[ -n "$jq_expr" ]]; then
		printf '%s' "$json" | jq -r "$jq_expr"
		return 0
	fi
	printf '%s\n' "$json"
	return 0
}

# Match: gh api repos/SLUG  (repo info — default branch)
# Detected by: $1 == api, $2 starts with "repos/", no "/branches/" in args
if [[ "$1" == "api" && "$2" == repos/* && "$*" != *"/branches/"* \
	&& "$*" != *"/issues/"* && "$*" != *"/pulls/"* ]]; then
	case "${MOCK_REPO_MODE:-ok}" in
	ok)
		apply_jq '{"default_branch":"main"}' "$@"
		exit 0
		;;
	error)
		printf 'gh: mock repo API error\n' >&2
		exit 1
		;;
	esac
fi

# Match: gh api repos/SLUG/branches/BRANCH/protection/required_status_checks
if [[ "$1" == "api" && "$*" == *"protection/required_status_checks"* ]]; then
	local_json=""
	case "${MOCK_BP_MODE:-three_required}" in
	three_required)
		local_json='{"contexts":["review-bot-gate","Maintainer Review & Assignee Gate","Complexity Analysis"]}'
		;;
	no_required)
		local_json='{"contexts":[]}'
		;;
	error)
		printf 'gh: mock branch-protection API error\n' >&2
		exit 1
		;;
	esac
	apply_jq "$local_json" "$@"
	exit 0
fi

# Match: gh pr view NUM --json statusCheckRollup
if [[ "$1" == "pr" && "$2" == "view" && "$*" == *"statusCheckRollup"* ]]; then
	local_json=""
	case "${MOCK_ROLLUP_MODE:-all_required_pass}" in
	all_required_pass)
		# All three required checks pass; no non-required checks.
		local_json='{"statusCheckRollup":[
			{"name":"review-bot-gate","state":"SUCCESS"},
			{"name":"Maintainer Review & Assignee Gate","conclusion":"SUCCESS","status":"COMPLETED"},
			{"name":"Complexity Analysis","conclusion":"SUCCESS","status":"COMPLETED"}
		]}'
		;;
	phantom_pending)
		# Required checks pass; non-required checks report null/pending.
		local_json='{"statusCheckRollup":[
			{"name":"review-bot-gate","state":"SUCCESS"},
			{"name":"Maintainer Review & Assignee Gate","conclusion":"SUCCESS","status":"COMPLETED"},
			{"name":"Complexity Analysis","conclusion":"SUCCESS","status":"COMPLETED"},
			{"name":"coderabbit-review","state":null},
			{"name":"qlty-check","conclusion":null,"status":"QUEUED"},
			{"name":"linked-issue-check","state":null},
			{"name":"url-allowlist","conclusion":null,"status":"IN_PROGRESS"}
		]}'
		;;
	one_required_failing)
		# review-bot-gate is FAILURE; other required checks pass.
		local_json='{"statusCheckRollup":[
			{"name":"review-bot-gate","state":"FAILURE"},
			{"name":"Maintainer Review & Assignee Gate","conclusion":"SUCCESS","status":"COMPLETED"},
			{"name":"Complexity Analysis","conclusion":"SUCCESS","status":"COMPLETED"}
		]}'
		;;
	required_absent)
		# review-bot-gate is missing from rollup; other required checks pass.
		local_json='{"statusCheckRollup":[
			{"name":"Maintainer Review & Assignee Gate","conclusion":"SUCCESS","status":"COMPLETED"},
			{"name":"Complexity Analysis","conclusion":"SUCCESS","status":"COMPLETED"}
		]}'
		;;
	error)
		printf 'gh: mock statusCheckRollup error\n' >&2
		exit 1
		;;
	esac
	apply_jq "$local_json" "$@"
	exit 0
fi

# Unhandled gh invocations: silent success
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Extract _check_required_checks_passing from pulse-merge.sh and eval it.
define_function_under_test() {
	local fn_src
	fn_src=$(awk '
		/^_check_required_checks_passing\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract _check_required_checks_passing from %s\n' \
			"$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$fn_src"
	return 0
}

assert_returns() {
	local expected_rc="$1"
	local label="$2"
	local actual_rc=0
	_check_required_checks_passing "marcusquinn/aidevops" "21097" || actual_rc=$?
	if [[ "$actual_rc" -eq "$expected_rc" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected rc=$expected_rc, got rc=$actual_rc"
	fi
	return 0
}

assert_log_contains() {
	local pattern="$1"
	local label="$2"
	if grep -q -- "$pattern" "$LOGFILE" 2>/dev/null; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected log line matching: $pattern"
	fi
	return 0
}

reset_logs() {
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"
	return 0
}

# ── Test cases ──────────────────────────────────────────────────────────────

test_all_required_pass() {
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="three_required"
	export MOCK_ROLLUP_MODE="all_required_pass"
	assert_returns 0 "all required checks SUCCESS → allowed"
	assert_log_contains "all required contexts passing" \
		"all_required_pass: pass message logged"
	assert_log_contains "t2922" "all_required_pass: log tagged t2922"
	return 0
}

test_phantom_pending_non_required() {
	# The key scenario from GH#21097: non-required checks (CodeRabbit, qlty,
	# linked-issue-check, url-allowlist) report null/pending indefinitely.
	# Required checks all pass — function should return 0 to unblock the merge.
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="three_required"
	export MOCK_ROLLUP_MODE="phantom_pending"
	assert_returns 0 "required pass + non-required null/pending → allowed (GH#21097)"
	assert_log_contains "all required contexts passing" \
		"phantom_pending: pass message logged"
	return 0
}

test_one_required_failing() {
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="three_required"
	export MOCK_ROLLUP_MODE="one_required_failing"
	assert_returns 1 "one required context FAILURE → blocked"
	assert_log_contains "required context(s) not passing" \
		"one_required_failing: block message logged"
	assert_log_contains "t2922" "one_required_failing: log tagged t2922"
	return 0
}

test_required_context_absent_from_rollup() {
	# A required context that hasn't reported at all is treated as non-passing.
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="three_required"
	export MOCK_ROLLUP_MODE="required_absent"
	assert_returns 1 "required context absent from rollup → blocked"
	assert_log_contains "required context(s) not passing" \
		"required_absent: block message logged"
	return 0
}

test_no_required_contexts() {
	# Repo has no required checks in branch protection — nothing can be failing.
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="no_required"
	export MOCK_ROLLUP_MODE="all_required_pass"
	assert_returns 0 "no required contexts in branch protection → allowed"
	assert_log_contains "no required contexts" \
		"no_required: pass message logged"
	return 0
}

test_default_branch_api_error() {
	reset_logs
	export MOCK_REPO_MODE="error"
	export MOCK_BP_MODE="three_required"
	export MOCK_ROLLUP_MODE="all_required_pass"
	assert_returns 1 "default branch API error → blocked (fail-closed)"
	assert_log_contains "failed to resolve default branch" \
		"db_error: fail-closed message logged"
	return 0
}

test_branch_protection_api_error() {
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="error"
	export MOCK_ROLLUP_MODE="all_required_pass"
	assert_returns 1 "branch protection API error → blocked (fail-closed)"
	assert_log_contains "branch protection API failed" \
		"bp_error: fail-closed message logged"
	return 0
}

test_rollup_api_error() {
	reset_logs
	export MOCK_REPO_MODE="ok"
	export MOCK_BP_MODE="three_required"
	export MOCK_ROLLUP_MODE="error"
	assert_returns 1 "statusCheckRollup API error → blocked (fail-closed)"
	assert_log_contains "statusCheckRollup fetch failed" \
		"rollup_error: fail-closed message logged"
	return 0
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_function_under_test; then
		printf 'FATAL: function extraction failed\n' >&2
		return 1
	fi

	test_all_required_pass
	test_phantom_pending_non_required
	test_one_required_failing
	test_required_context_absent_from_rollup
	test_no_required_contexts
	test_default_branch_api_error
	test_branch_protection_api_error
	test_rollup_api_error

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
