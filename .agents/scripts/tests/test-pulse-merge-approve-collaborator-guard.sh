#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for approve_collaborator_pr() defense-in-depth author guard (t2933).
#
# Background — GH#17671 supply-chain incident
# -------------------------------------------
# In April 2025 an external contributor (non-collaborator) opened PR #17671 against
# this repo. The PR added a workflow file that invoked an attacker-controlled
# action. `approve_collaborator_pr` was invoked anyway because the upstream
# gate at the time only inspected linked-issue labels, not the PR author. The
# PR shipped an "Auto-approved by pulse — collaborator PR" body even though
# the author was not a collaborator. Subsequent hardening (PR #17868 added
# Check 0 to maintainer-gate; PR #17877 protected the NMR label;
# `_check_pr_merge_gates` line ~1060 added an upstream `_is_collaborator_author`
# check on the PR author) closed the live exploit.
#
# What this test guards
# ---------------------
# The function `approve_collaborator_pr` itself trusts its `$pr_author`
# argument unless self-protected. A future refactor of `_check_pr_merge_gates`
# could quietly remove the upstream collaborator check; the function would
# then re-introduce the GH#17671 supply-chain hole as soon as a single
# caller passed a non-collaborator author through. The defense-in-depth
# guard added in t2933 makes the function refuse to approve in that case
# REGARDLESS of what its callers do. These tests pin that contract so the
# guard can never silently regress.
#
# These tests exercise the helper in isolation with a mock `gh` stub. No
# real repository is touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
# _is_collaborator_author was extracted to pulse-merge-author-checks.sh (GH#21426)
AUTHOR_CHECKS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-author-checks.sh"

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
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Reset state between cases.
reset_mock_state() {
	: >"$GH_LOG"
	: >"$LOGFILE"
	# Default: collaborators set contains "pulse-runner" only.
	cat >"${TEST_ROOT}/collaborators.txt" <<'EOF'
pulse-runner
EOF
	# Default authenticated user is the pulse runner.
	echo "pulse-runner" >"${TEST_ROOT}/current-user.txt"
	# Default: no prior reviews (count 0).
	echo "0" >"${TEST_ROOT}/existing-approval-count.txt"
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

	# Mock gh: logs every call and answers the four endpoints
	# `approve_collaborator_pr` and `_is_collaborator_author` use.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

# `gh api user --jq '.login'` — return current user fixture
if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
	cat "${TEST_ROOT}/current-user.txt"
	exit 0
fi

# `gh api -i repos/SLUG/collaborators/USER/permission` — return 200/404 line
# Used by _is_collaborator_author for the membership probe (head -1).
if [[ "${1:-}" == "api" && "${2:-}" == "-i" && "$*" == *"/collaborators/"*"/permission" ]]; then
	# Extract the username segment between /collaborators/ and /permission.
	_user="${3#*/collaborators/}"
	_user="${_user%/permission}"
	if grep -Fxq "$_user" "${TEST_ROOT}/collaborators.txt"; then
		printf 'HTTP/2.0 200 OK\n'
	else
		printf 'HTTP/2.0 404 Not Found\n'
	fi
	exit 0
fi

# `gh api repos/SLUG/collaborators/USER/permission --jq '.permission'`
if [[ "${1:-}" == "api" && "$*" == *"/collaborators/"*"/permission"* && "$*" == *"--jq"* ]]; then
	_user="${2#*/collaborators/}"
	_user="${_user%/permission}"
	if grep -Fxq "$_user" "${TEST_ROOT}/collaborators.txt"; then
		printf 'admin\n'
	else
		printf '\n'
	fi
	exit 0
fi

# `gh api repos/SLUG/pulls/N/reviews --jq ...` — existing-approval count
if [[ "${1:-}" == "api" && "$*" == *"/pulls/"*"/reviews"* ]]; then
	cat "${TEST_ROOT}/existing-approval-count.txt"
	exit 0
fi

# `gh pr review N --repo SLUG --approve --body "..."`
if [[ "${1:-}" == "pr" && "${2:-}" == "review" ]]; then
	# Already logged via the line at top of mock — exit 0 to claim approval.
	exit 0
fi

# Anything else: log and exit 0 so unrelated calls don't fail the test.
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

# Extract approve_collaborator_pr from pulse-merge.sh AND its dependency
# _is_collaborator_author from pulse-merge-author-checks.sh (GH#21426 split).
# Both are needed; the guard calls the helper.
define_helpers_under_test() {
	local approve_src
	local collab_src
	approve_src=$(awk '
		/^approve_collaborator_pr\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	# _is_collaborator_author was extracted to pulse-merge-author-checks.sh (GH#21426)
	collab_src=$(awk '
		/^_is_collaborator_author\(\) \{/,/^}$/ { print }
	' "$AUTHOR_CHECKS_SCRIPT")

	if [[ -z "$approve_src" ]]; then
		printf 'ERROR: could not extract approve_collaborator_pr from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	if [[ -z "$collab_src" ]]; then
		printf 'ERROR: could not extract _is_collaborator_author from %s\n' "$AUTHOR_CHECKS_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$collab_src"
	# shellcheck disable=SC1090
	eval "$approve_src"
	return 0
}

# Helper: count "gh pr review ... --approve" calls in the log.
count_approve_calls() {
	grep -cF "pr review" "$GH_LOG" 2>/dev/null || true
}

# =============================================================================
# Case A: PR author IS collaborator, runner IS collaborator, runner != author
#         → approval SHOULD fire.
# =============================================================================

test_case_a_collaborator_author_approves() {
	reset_mock_state
	# Add the PR author as a collaborator alongside the pulse runner.
	cat >"${TEST_ROOT}/collaborators.txt" <<'EOF'
pulse-runner
trusted-contributor
EOF

	local result=0
	approve_collaborator_pr "100" "owner/repo" "trusted-contributor" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case A: collaborator author — approval succeeds" 1 \
			"Expected exit 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	# Verify gh pr review --approve was called.
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -lt 1 ]]; then
		print_result "Case A: collaborator author — approve API called" 1 \
			"Expected at least one 'gh pr review' call. Log: $(cat "$GH_LOG")"
		return 0
	fi
	# Verify approval body names the actual checks performed (t2933 fix to
	# the misleading "collaborator PR" body that shipped for years).
	if ! grep -qF "confirmed collaborator" "$GH_LOG"; then
		print_result "Case A: collaborator author — approval body accurate" 1 \
			"Expected 'confirmed collaborator' in approval body. Log: $(cat "$GH_LOG")"
		return 0
	fi
	print_result "Case A: collaborator author — approves PR with accurate body" 0
	return 0
}

# =============================================================================
# Case B (PRIMARY REGRESSION CASE — GH#17671):
#         PR author NOT a collaborator, runner IS collaborator
#         → guard MUST refuse approval.
# =============================================================================

test_case_b_non_collaborator_author_refused() {
	reset_mock_state
	# Pulse runner is the only collaborator; PR author is external.
	cat >"${TEST_ROOT}/collaborators.txt" <<'EOF'
pulse-runner
EOF

	local result=0
	approve_collaborator_pr "200" "owner/repo" "external-contributor" || result=$?

	# Function returns 0 (skip is not failure) but MUST NOT call gh pr review.
	if [[ "$result" -ne 0 ]]; then
		print_result "Case B: non-collaborator author — function returns 0 (skip)" 1 \
			"Expected exit 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -gt 0 ]]; then
		print_result "Case B: non-collaborator author — NO approve API call" 1 \
			"Expected zero 'gh pr review' calls (GH#17671 defense-in-depth). Log: $(cat "$GH_LOG")"
		return 0
	fi
	# Verify the t2933 refusal log line is present so future debugging can
	# attribute the skip to the correct guard.
	if ! grep -qF "GH#17671 defense-in-depth, t2933" "$LOGFILE"; then
		print_result "Case B: non-collaborator author — refusal logged with audit trail" 1 \
			"Expected GH#17671/t2933 attribution in skip log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case B: non-collaborator author — refused with audit-trail log" 0
	return 0
}

# =============================================================================
# Case C: Self-authored PR (runner == author) → skip; --admin merge handles it.
# =============================================================================

test_case_c_self_authored_skipped() {
	reset_mock_state
	echo "pulse-runner" >"${TEST_ROOT}/current-user.txt"

	local result=0
	approve_collaborator_pr "300" "owner/repo" "pulse-runner" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case C: self-authored — function returns 0" 1 \
			"Expected exit 0, got ${result}"
		return 0
	fi
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -gt 0 ]]; then
		print_result "Case C: self-authored — NO approve API call" 1 \
			"Expected zero approve calls (--admin handles it). Log: $(cat "$GH_LOG")"
		return 0
	fi
	if ! grep -qF "self-authored" "$LOGFILE"; then
		print_result "Case C: self-authored — skip logged" 1 \
			"Expected 'self-authored' in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case C: self-authored — skipped (--admin handles it)" 0
	return 0
}

# =============================================================================
# Case D: Pulse runner lacks write access → skip approval (no-op).
#         Earlier guard, predates the t2933 author check; still must hold.
# =============================================================================

test_case_d_runner_lacks_write_access_skipped() {
	reset_mock_state
	# Runner is NOT in the collaborators file — pretend pulse runs as a
	# token whose user has no write access on this repo.
	cat >"${TEST_ROOT}/collaborators.txt" <<'EOF'
trusted-contributor
EOF
	echo "low-priv-user" >"${TEST_ROOT}/current-user.txt"

	local result=0
	approve_collaborator_pr "400" "owner/repo" "trusted-contributor" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case D: runner lacks write — function returns 0" 1 \
			"Expected exit 0, got ${result}"
		return 0
	fi
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -gt 0 ]]; then
		print_result "Case D: runner lacks write — NO approve API call" 1 \
			"Expected zero approve calls. Log: $(cat "$GH_LOG")"
		return 0
	fi
	if ! grep -qF "lacks write access" "$LOGFILE"; then
		print_result "Case D: runner lacks write — skip logged" 1 \
			"Expected 'lacks write access' in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case D: runner lacks write access — skipped" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_case_a_collaborator_author_approves
	test_case_b_non_collaborator_author_refused
	test_case_c_self_authored_skipped
	test_case_d_runner_lacks_write_access_skipped

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
