#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for t2104 / GH#19040: pulse-merge.sh _pr_required_checks_pass must
# query `gh pr checks --required --json bucket` (branch-protection-required
# checks only) rather than `gh pr view --json statusCheckRollup` (all checks
# attached to the PR head), so that:
#
#   1. Post-merge advisory failures (e.g. "Sync Issue Hygiene on PR Merge"
#      which is expected to fail under the t2029 protected-main limitation)
#      do NOT block the merge pass.
#   2. Non-required advisory checks are ignored.
#   3. Required failures still correctly block the merge.
#   4. Pending / skipping required checks still allow the merge (preserves
#      pre-t2104 semantics — --admin handles pending, skipping is not an error).
#   5. API errors fail-closed (a bubbling gh failure must never auto-merge).
#
# Regression root cause: PR #19023 (GH#18787) had all required checks green
# but statusCheckRollup contained a FAILURE entry from the post-merge
# "Sync Issue Hygiene on PR Merge" workflow — the deterministic merge pass
# skipped the PR and required manual maintainer intervention.
#
# Strategy: extract _pr_required_checks_pass from pulse-merge.sh, eval it,
# and exercise it against a mock `gh` stub that records every invocation
# and returns canned responses keyed on $MOCK_GH_MODE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# _pr_required_checks_pass was moved to pulse-merge-process.sh
# (GH#21595, t3030).
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"

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

# Prepare a mock `gh` on PATH that records every invocation and returns
# canned JSON keyed on $MOCK_GH_MODE:
#   all_pass        — [{bucket:"pass"},{bucket:"pass"}]
#   one_fail        — [{bucket:"pass"},{bucket:"fail"}]
#   one_cancel      — [{bucket:"pass"},{bucket:"cancel"}]
#   empty_required  — []
#   pending_only    — [{bucket:"pending"}]
#   skipping_only   — [{bucket:"skipping"}]
#   error           — exit 1 with no output
setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	export MOCK_GH_MODE="all_pass"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"

	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh for test-pulse-merge-required-checks-filter.sh
# Records every top-level invocation and returns canned responses for
# `gh pr checks <N> --repo <slug> --required --json bucket [--jq EXPR]`.
#
# Applies --jq via the real jq binary so the function under test sees the
# same filtered output it would see from the real gh CLI.
printf '%s\n' "$*" >>"${GH_CALL_LOG}"

# Only handle `gh pr checks ... --required --json bucket`
if [[ "$1" == "pr" && "$2" == "checks" && "$*" == *"--required"* && "$*" == *"--json bucket"* ]]; then
	# Resolve the canned JSON for the current mode
	local_json=""
	case "${MOCK_GH_MODE:-all_pass}" in
	all_pass) local_json='[{"bucket":"pass"},{"bucket":"pass"}]' ;;
	one_fail) local_json='[{"bucket":"pass"},{"bucket":"fail"}]' ;;
	one_cancel) local_json='[{"bucket":"pass"},{"bucket":"cancel"}]' ;;
	empty_required) local_json='[]' ;;
	pending_only) local_json='[{"bucket":"pending"}]' ;;
	skipping_only) local_json='[{"bucket":"skipping"}]' ;;
	error)
		printf 'gh: mock error\n' >&2
		exit 1
		;;
	*) local_json='[]' ;;
	esac

	# If --jq EXPR is present, apply it via the real jq binary.
	jq_expr=""
	prev=""
	for arg in "$@"; do
		if [[ "$prev" == "--jq" ]]; then
			jq_expr="$arg"
			break
		fi
		prev="$arg"
	done
	if [[ -n "$jq_expr" ]]; then
		printf '%s' "$local_json" | jq -r "$jq_expr"
		exit 0
	fi
	printf '%s\n' "$local_json"
	exit 0
fi

# Unhandled gh invocations: silent success (we don't care about them here)
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

# Extract _pr_required_checks_pass from pulse-merge.sh and eval it into
# the current shell so we can invoke it directly.
define_function_under_test() {
	local fn_src
	fn_src=$(awk '
		/^_pr_required_checks_pass\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract _pr_required_checks_pass from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$fn_src"
	return 0
}

assert_function_returns() {
	local expected_rc="$1"
	local label="$2"
	local actual_rc=0
	_pr_required_checks_pass "19023" "marcusquinn/aidevops" || actual_rc=$?
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

assert_log_empty() {
	local label="$1"
	if [[ ! -s "$LOGFILE" ]]; then
		print_result "$label" 0
	else
		local contents
		contents=$(cat "$LOGFILE")
		print_result "$label" 1 "Expected empty log, got: $contents"
	fi
	return 0
}

assert_gh_call_uses_required_flag() {
	local label="$1"
	if grep -q -- "--required" "$GH_CALL_LOG" 2>/dev/null; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected 'gh pr checks ... --required' invocation"
	fi
	return 0
}

test_all_pass_allows_merge() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="all_pass"
	assert_function_returns 0 "all required checks passing → merge allowed"
	assert_gh_call_uses_required_flag "all_pass: gh pr checks called with --required"
	assert_log_empty "all_pass: no skip log emitted"
	return 0
}

test_post_merge_advisory_failure_ignored() {
	# Simulates the GH#18787 regression: statusCheckRollup would have
	# flagged "Sync Issue Hygiene on PR Merge" as FAILURE, but
	# `gh pr checks --required` only returns branch-protection-required
	# checks so the post-merge advisory workflow is invisible here.
	# all_pass mock represents that state: two required checks, both pass.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="all_pass"
	assert_function_returns 0 "post-merge advisory failure (outside required set) → merge allowed (GH#18787 regression)"
	return 0
}

test_required_failure_blocks_merge() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="one_fail"
	assert_function_returns 1 "one required check in bucket=fail → merge blocked"
	assert_log_contains "1 required status check(s) failing" \
		"one_fail: skip reason logged"
	assert_log_contains "t2104" "one_fail: log tagged with t2104"
	return 0
}

test_required_cancel_blocks_merge() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="one_cancel"
	assert_function_returns 1 "required check in bucket=cancel → merge blocked"
	assert_log_contains "1 required status check(s) failing" \
		"one_cancel: skip reason logged"
	return 0
}

test_empty_required_set_allows_merge() {
	# Repo has no required checks defined in branch protection — nothing
	# is failing, so the gate must allow the merge.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="empty_required"
	assert_function_returns 0 "empty required-checks set → merge allowed"
	assert_log_empty "empty_required: no skip log emitted"
	return 0
}

test_pending_required_allows_merge() {
	# Pre-t2104 semantics: pending required checks are not counted as
	# failures. --admin merges past them. The gate preserves this.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="pending_only"
	assert_function_returns 0 "pending required check → merge allowed (pre-t2104 semantics)"
	return 0
}

test_skipping_required_allows_merge() {
	# Skipping = the required check didn't run (conditional job skipped).
	# Not a failure, not counted.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="skipping_only"
	assert_function_returns 0 "skipping required check → merge allowed"
	return 0
}

test_gh_api_error_fails_closed() {
	# gh exits 1 → the function MUST return 1 (fail-closed). A bubbling
	# gh error must never auto-merge when --admin would bypass branch
	# protection.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="error"
	assert_function_returns 1 "gh pr checks error → merge blocked (fail-closed)"
	assert_log_contains "required checks fetch failed" \
		"error: skip reason logged"
	assert_log_contains "t2104" "error: log tagged with t2104"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_function_under_test; then
		printf 'FATAL: function extraction failed\n' >&2
		return 1
	fi

	test_all_pass_allows_merge
	test_post_merge_advisory_failure_ignored
	test_required_failure_blocks_merge
	test_required_cancel_blocks_merge
	test_empty_required_set_allows_merge
	test_pending_required_allows_merge
	test_skipping_required_allows_merge
	test_gh_api_error_fails_closed

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
