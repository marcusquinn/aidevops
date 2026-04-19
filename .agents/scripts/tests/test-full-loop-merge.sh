#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-full-loop-merge.sh — Regression tests for _merge_execute admin fallback signaling (t2247)
#
# Verifies:
#   1. Admin fallback fires all three signaling artifacts (PR comment, audit log, label)
#   2. Explicit --admin caller does NOT trigger extra signaling (back-compat)
#   3. Non-branch-protection errors do NOT trigger fallback
#
# Strategy: stub gh, audit-log-helper.sh, and gh-signature-helper.sh in a temp
# directory prepended to PATH, then source the functions from full-loop-helper.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../full-loop-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

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
	mkdir -p "${TEST_ROOT}/logs"

	# Stub gh-signature-helper.sh
	cat >"${TEST_ROOT}/bin/gh-signature-helper.sh" <<'STUB'
#!/usr/bin/env bash
echo "---"
echo "test-signature-footer"
STUB
	chmod +x "${TEST_ROOT}/bin/gh-signature-helper.sh"

	# Stub audit-log-helper.sh — records invocations to a log file
	cat >"${TEST_ROOT}/bin/audit-log-helper.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${TEST_ROOT}/logs/audit-log-calls.txt"
STUB
	chmod +x "${TEST_ROOT}/bin/audit-log-helper.sh"

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Create a gh stub that simulates merge behavior.
# Args:
#   $1 = "fallback" — first merge fails with branch-protection error, --admin succeeds
#   $2 = "explicit-admin" — merge with --admin succeeds immediately (no fallback)
#   $3 = "other-error" — merge fails with non-branch-protection error
create_gh_stub() {
	local mode="$1"

	cat >"${TEST_ROOT}/bin/gh" <<GHSTUB
#!/usr/bin/env bash
# Log all gh calls
_gh_cmd="\$1"
_gh_sub="\$2"
echo "gh \$*" >> "${TEST_ROOT}/logs/gh-calls.txt"

if [[ "\$_gh_cmd" == "pr" && "\$_gh_sub" == "merge" ]]; then
	# Check if --admin flag is present
	_gh_has_admin=0
	for _gh_arg in "\$@"; do
		if [[ "\$_gh_arg" == "--admin" ]]; then
			_gh_has_admin=1
		fi
	done

	if [[ "$mode" == "fallback" ]]; then
		if [[ "\$_gh_has_admin" -eq 1 ]]; then
			echo "Merged PR"
			exit 0
		else
			echo "At least 1 approving review is required" >&2
			exit 1
		fi
	elif [[ "$mode" == "explicit-admin" ]]; then
		echo "Merged PR"
		exit 0
	elif [[ "$mode" == "other-error" ]]; then
		echo "Something completely different went wrong" >&2
		exit 1
	fi
fi

if [[ "\$_gh_cmd" == "pr" && "\$_gh_sub" == "comment" ]]; then
	echo "pr comment \$*" >> "${TEST_ROOT}/logs/pr-comments.txt"
	exit 0
fi

if [[ "\$_gh_cmd" == "pr" && "\$_gh_sub" == "edit" ]]; then
	echo "pr edit \$*" >> "${TEST_ROOT}/logs/pr-edits.txt"
	exit 0
fi

# Default: succeed silently
exit 0
GHSTUB
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# Run _merge_execute in an isolated subprocess.
# Sources full-loop-helper.sh with init lines stripped (SCRIPT_DIR assignment,
# shared-constants source, readonly SCRIPT_DIR, and main "$@" call) so we get
# all function definitions without side effects.
# Args: pr_number repo merge_method has_admin has_auto
run_merge_execute() {
	local pr_number="$1"
	local repo="$2"
	local merge_method="$3"
	local has_admin="$4"
	local has_auto="$5"

	local scripts_dir="${SCRIPT_DIR}/.."

	# Build a temporary script that sources the helper with init lines stripped.
	# Using a temp file avoids heredoc/process-substitution escaping issues with $.
	local tmp_runner=""
	tmp_runner=$(mktemp)
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
source '${scripts_dir}/shared-constants.sh'
# Strip: line 10 (SCRIPT_DIR=), line 11 (source shared-constants), line 13 (readonly SCRIPT_DIR), last line (main "\$@")
source <(sed -e '10d' -e '11d' -e '13d' -e '\$d' '${HELPER_SCRIPT}')
_merge_execute '$pr_number' '$repo' '$merge_method' '$has_admin' '$has_auto'
RUNNER_EOF
	chmod +x "$tmp_runner"

	# Run in a subprocess with our stubs on PATH
	local rc=0
	env PATH="${TEST_ROOT}/bin:${scripts_dir}:${PATH}" \
		AIDEVOPS_MODEL="test-model" \
		bash "$tmp_runner" 2>&1 || rc=$?
	rm -f "$tmp_runner"
	return $rc
}

# Test 1: Admin fallback fires and produces all three signaling artifacts
test_admin_fallback_signals() {
	# Clear logs
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "fallback"

	local output=""
	output=$(run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0") || true

	# (a) Check PR comment was posted
	local pr_comment_posted=0
	if [[ -f "${TEST_ROOT}/logs/pr-comments.txt" ]]; then
		if grep -q "pr comment" "${TEST_ROOT}/logs/pr-comments.txt"; then
			pr_comment_posted=1
		fi
	fi
	print_result "admin fallback: PR comment posted" "$((1 - pr_comment_posted))"

	# (b) Check audit log was called
	local audit_logged=0
	if [[ -f "${TEST_ROOT}/logs/audit-log-calls.txt" ]]; then
		if grep -q "merge-admin-fallback" "${TEST_ROOT}/logs/audit-log-calls.txt"; then
			audit_logged=1
		fi
	fi
	print_result "admin fallback: audit log entry written" "$((1 - audit_logged))"

	# (c) Check admin-merge label was applied
	local label_applied=0
	if [[ -f "${TEST_ROOT}/logs/pr-edits.txt" ]]; then
		if grep -q "admin-merge" "${TEST_ROOT}/logs/pr-edits.txt"; then
			label_applied=1
		fi
	fi
	print_result "admin fallback: admin-merge label applied" "$((1 - label_applied))"

	return 0
}

# Test 2: Explicit --admin caller does NOT trigger extra signaling
test_explicit_admin_no_signaling() {
	# Clear logs
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "explicit-admin"

	local output=""
	output=$(run_merge_execute "42" "testorg/testrepo" "--squash" "1" "0") || true

	# PR comment should NOT have been posted (explicit --admin is not a fallback)
	local pr_comment_posted=0
	if [[ -f "${TEST_ROOT}/logs/pr-comments.txt" ]]; then
		if grep -q "pr comment" "${TEST_ROOT}/logs/pr-comments.txt"; then
			pr_comment_posted=1
		fi
	fi
	print_result "explicit --admin: no extra PR comment" "$pr_comment_posted"

	# Audit log should NOT have been called
	local audit_logged=0
	if [[ -f "${TEST_ROOT}/logs/audit-log-calls.txt" ]]; then
		if grep -q "merge-admin-fallback" "${TEST_ROOT}/logs/audit-log-calls.txt"; then
			audit_logged=1
		fi
	fi
	print_result "explicit --admin: no extra audit log" "$audit_logged"

	# Label should NOT have been applied
	local label_applied=0
	if [[ -f "${TEST_ROOT}/logs/pr-edits.txt" ]]; then
		if grep -q "admin-merge" "${TEST_ROOT}/logs/pr-edits.txt"; then
			label_applied=1
		fi
	fi
	print_result "explicit --admin: no admin-merge label" "$label_applied"

	return 0
}

# Test 3: Non-branch-protection errors do NOT trigger fallback at all
test_other_error_no_fallback() {
	# Clear logs
	rm -f "${TEST_ROOT}/logs/"*.txt

	create_gh_stub "other-error"

	local exit_code=0
	run_merge_execute "42" "testorg/testrepo" "--squash" "0" "0" >/dev/null 2>&1 || exit_code=$?

	# Should have failed (exit code != 0)
	print_result "other error: merge fails without fallback" "$((exit_code == 0 ? 1 : 0))"

	# No signaling should have fired
	local any_signaling=0
	if [[ -f "${TEST_ROOT}/logs/pr-comments.txt" ]] ||
		[[ -f "${TEST_ROOT}/logs/audit-log-calls.txt" ]] ||
		[[ -f "${TEST_ROOT}/logs/pr-edits.txt" ]]; then
		any_signaling=1
	fi
	print_result "other error: no signaling artifacts" "$any_signaling"

	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	echo "=== Admin merge fallback signaling tests (t2247) ==="
	echo ""

	test_admin_fallback_signals
	test_explicit_admin_no_signaling
	test_other_error_no_fallback

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
