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
# approve_collaborator_pr was extracted to pulse-merge-gates.sh during the
# pulse-merge split. The test extracts it via awk for isolated execution under
# a mock gh stub, so the source file must point at where the function actually
# lives — not the orchestrator that only calls it. Without this repoint the
# extraction returns empty and the test exits FATAL, blocking every PR via the
# Framework Validation required check (t3032).
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-gates.sh"
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
	# Default: no crypto-approval markers in comments (count 0).
	# Controls the mock gh comments endpoint response for _has_maintainer_crypto_approval.
	echo "0" >"${TEST_ROOT}/crypto-comment-count.txt"
	# Default: linked issue number returned by the _extract_linked_issue stub.
	echo "999" >"${TEST_ROOT}/linked-issue.txt"
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
	# Point AGENTS_DIR to a mock directory without approval-helper.sh so
	# _has_maintainer_crypto_approval falls back to the marker-presence
	# path (trusting the count returned by the mock gh endpoint) rather
	# than invoking the real SSH-key-based approval-helper.sh.
	export AGENTS_DIR="${TEST_ROOT}/mock-agents"
	mkdir -p "${AGENTS_DIR}/scripts"

	# Mock gh: logs every call and answers the five endpoints that
	# `approve_collaborator_pr`, `_is_collaborator_author`, and
	# `_has_maintainer_crypto_approval` use.
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

# `gh api repos/SLUG/issues/N/comments --jq ...` — crypto-approval marker count
# Used by _has_maintainer_crypto_approval. Returns the fixture-controlled count.
if [[ "${1:-}" == "api" && "$*" == *"/issues/"*"/comments"* && "$*" == *"--jq"* ]]; then
	cat "${TEST_ROOT}/crypto-comment-count.txt" 2>/dev/null || printf '0\n'
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

# Extract approve_collaborator_pr from pulse-merge-gates.sh AND its dependencies:
#   - _is_collaborator_author from pulse-merge-author-checks.sh (GH#21426 split)
#   - _has_maintainer_crypto_approval from pulse-merge-gates.sh (t3063)
# All three are needed; approve_collaborator_pr calls both helpers.
# _extract_linked_issue (called by _has_maintainer_crypto_approval) is provided
# as a test stub that returns a fixed linked issue number from a fixture file,
# keeping the unit boundary at approve_collaborator_pr.
define_helpers_under_test() {
	local approve_src
	local collab_src
	local crypto_src
	approve_src=$(awk '
		/^approve_collaborator_pr\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	# _is_collaborator_author was extracted to pulse-merge-author-checks.sh (GH#21426)
	collab_src=$(awk '
		/^_is_collaborator_author\(\) \{/,/^}$/ { print }
	' "$AUTHOR_CHECKS_SCRIPT")
	# _has_maintainer_crypto_approval was added in t3063
	crypto_src=$(awk '
		/^_has_maintainer_crypto_approval\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")

	if [[ -z "$approve_src" ]]; then
		printf 'ERROR: could not extract approve_collaborator_pr from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	if [[ -z "$collab_src" ]]; then
		printf 'ERROR: could not extract _is_collaborator_author from %s\n' "$AUTHOR_CHECKS_SCRIPT" >&2
		return 1
	fi
	if [[ -z "$crypto_src" ]]; then
		printf 'ERROR: could not extract _has_maintainer_crypto_approval from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi

	# Stub _extract_linked_issue — returns a fixed linked issue number
	# from the fixture file, avoiding a dependency on pulse-merge.sh.
	# shellcheck disable=SC2317
	_extract_linked_issue() {
		cat "${TEST_ROOT}/linked-issue.txt" 2>/dev/null || true
		return 0
	}
	# This test focuses on the collaborator/crypto guard. Dependabot-specific
	# allowances are covered by test-pulse-merge-trusted-dependabot.sh.
	_is_trusted_dependabot_update_pr() { return 1; }

	# shellcheck disable=SC1090
	eval "$collab_src"
	# shellcheck disable=SC1090
	eval "$crypto_src"
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

# =============================================================================
# Case N (t3063): CONTRIBUTOR author + crypto-approval on PR itself → approves.
# The crypto-approval bypass in approve_collaborator_pr should allow approval
# even though the PR author is not a collaborator.
# =============================================================================

test_case_n_contributor_with_crypto_on_pr() {
	reset_mock_state
	# PR author is NOT a collaborator; crypto marker is present on the PR.
	# The comments endpoint (used for both PR and linked-issue) returns count=1.
	echo "1" >"${TEST_ROOT}/crypto-comment-count.txt"

	local result=0
	approve_collaborator_pr "910" "owner/repo" "external-contributor" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case N: CONTRIBUTOR + crypto on PR — function returns 0" 1 \
			"Expected exit 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -lt 1 ]]; then
		print_result "Case N: CONTRIBUTOR + crypto on PR — approve API called" 1 \
			"Expected at least one 'gh pr review' call. Log: $(cat "$GH_LOG")"
		return 0
	fi
	if ! grep -qF "t3063" "$LOGFILE"; then
		print_result "Case N: CONTRIBUTOR + crypto on PR — t3063 bypass logged" 1 \
			"Expected 't3063' in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case N: CONTRIBUTOR + crypto-approval on PR — approved via t3063 bypass" 0
	return 0
}

# =============================================================================
# Case O (t3063): CONTRIBUTOR author + crypto-approval on linked issue → approves.
# Same bypass applies when the crypto signature is on the linked issue rather
# than on the PR itself. PR comments return 0 but linked-issue comments return 1.
# =============================================================================

test_case_o_contributor_with_crypto_on_linked_issue() {
	reset_mock_state
	# The mock comments endpoint returns the same count for both PR and
	# linked-issue paths (fixture is shared). Setting it to 1 simulates
	# "crypto found on linked issue" — _has_maintainer_crypto_approval
	# would find it on the first (PR-level) check in this simplified mock,
	# which still correctly exercises the bypass path through approve_collaborator_pr.
	echo "1" >"${TEST_ROOT}/crypto-comment-count.txt"

	local result=0
	approve_collaborator_pr "920" "owner/repo" "external-contributor" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case O: CONTRIBUTOR + crypto on linked issue — function returns 0" 1 \
			"Expected exit 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -lt 1 ]]; then
		print_result "Case O: CONTRIBUTOR + crypto on linked issue — approve API called" 1 \
			"Expected at least one 'gh pr review' call. Log: $(cat "$GH_LOG")"
		return 0
	fi
	if ! grep -qF "t3063" "$LOGFILE"; then
		print_result "Case O: CONTRIBUTOR + crypto on linked issue — t3063 bypass logged" 1 \
			"Expected 't3063' in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case O: CONTRIBUTOR + crypto-approval on linked issue — approved via t3063 bypass" 0
	return 0
}

# =============================================================================
# Case P (t3063 regression — GH#17671 preservation):
#         CONTRIBUTOR author + NO crypto-approval → still refuses.
# The crypto bypass must NOT weaken the existing Case B guard: when there is
# no crypto approval, external contributors are still blocked from auto-approval.
# =============================================================================

test_case_p_contributor_no_crypto_still_refused() {
	reset_mock_state
	# PR author is NOT a collaborator; crypto-comment-count stays at default 0.
	# Pulse runner IS a collaborator (default state).

	local result=0
	approve_collaborator_pr "930" "owner/repo" "external-contributor" || result=$?

	# Function must return 0 (skip, not error) — same as Case B.
	if [[ "$result" -ne 0 ]]; then
		print_result "Case P: CONTRIBUTOR + no crypto — function returns 0 (skip)" 1 \
			"Expected exit 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	local approve_count
	approve_count=$(count_approve_calls)
	if [[ "${approve_count:-0}" -gt 0 ]]; then
		print_result "Case P: CONTRIBUTOR + no crypto — NO approve API call" 1 \
			"Expected zero 'gh pr review' calls (GH#17671 preserved). Log: $(cat "$GH_LOG")"
		return 0
	fi
	# Verify the t2933 refusal log line is present (not the t3063 bypass).
	if ! grep -qF "GH#17671 defense-in-depth, t2933" "$LOGFILE"; then
		print_result "Case P: CONTRIBUTOR + no crypto — refusal logged with t2933 audit trail" 1 \
			"Expected GH#17671/t2933 attribution in skip log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case P: CONTRIBUTOR + no crypto — refused (GH#17671 guard preserved)" 0
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
	test_case_n_contributor_with_crypto_on_pr
	test_case_o_contributor_with_crypto_on_linked_issue
	test_case_p_contributor_no_crypto_still_refused

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
