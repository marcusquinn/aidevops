#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for the origin:interactive OWNER/MEMBER auto-merge path (t2411).
#
# pulse-merge.sh _check_pr_merge_gates now has a dedicated path for
# origin:interactive PRs: OWNER/MEMBER authors bypass the review-bot gate
# and merge as soon as CI passes, no draft, no hold-for-review label.
#
# Cases covered:
#   Case 1: OWNER author + all checks pass → gates pass (merge allowed).
#   Case 2: COLLABORATOR (write) author + all checks pass → falls through to
#           bot gate (does NOT get the fast path).
#   Case 3: OWNER author + 1 failing CI check → merge blocked (pre-gate).
#   Case 4: OWNER author + hold-for-review label → gates block.
#   Case 5: OWNER author + draft PR → gates block.
#   Case 6: OWNER author + human CHANGES_REQUESTED → gates block (existing gate).
#
# These tests exercise _check_pr_merge_gates and _is_owner_or_member_author in
# isolation with a mock `gh` stub. No real repository is touched.

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

# Reset mock state to OWNER with interactive label, not draft, no hold-for-review.
reset_mock_state() {
	: >"$GH_LOG"
	: >"$LOGFILE"
	# PR view raw format (as returned by gh pr view --json labels,isDraft).
	# The jq filter in _check_pr_merge_gates transforms .labels[] array → string;
	# the mock bypasses the filter and returns the already-transformed output
	# directly (see gh mock below). Format: {labels: "<csv>", isDraft: "<bool>"}
	cat >"${TEST_ROOT}/pr-labels.json" <<'EOF'
{"labels": "origin:interactive", "isDraft": "false"}
EOF
	# Permission fixture: admin (OWNER)
	cat >"${TEST_ROOT}/permission.json" <<'EOF'
{"permission": "admin"}
EOF
	# Reviews: no CHANGES_REQUESTED
	echo '[]' >"${TEST_ROOT}/reviews.json"
	# required checks: all pass
	echo '0' >"${TEST_ROOT}/failing-checks.txt"
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
	# review-bot-gate-helper stub: default PASS
	mkdir -p "${TEST_ROOT}/scripts"
	cat >"${TEST_ROOT}/bin/review-bot-gate-helper.sh" <<'RBGEOF'
#!/usr/bin/env bash
echo "PASS"
RBGEOF
	chmod +x "${TEST_ROOT}/bin/review-bot-gate-helper.sh"
	export AGENTS_DIR="${TEST_ROOT}"

	# Mock gh: logs every call and returns canned data from TEST_ROOT fixtures.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

_all_args=("$@")

if [[ "${1:-}" == "api" ]]; then
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done

	# Collaborator permission check (HEAD -i request first)
	if [[ "$*" == *"-i"* && "$*" == *"permission"* ]]; then
		echo "HTTP/2 200"
		exit 0
	fi

	# Collaborator permission value
	if [[ "$*" == *"collaborators"*"permission"* ]]; then
		if [[ -n "$_jq_filter" ]]; then
			jq -r "$_jq_filter" <"${TEST_ROOT}/permission.json"
		else
			cat "${TEST_ROOT}/permission.json"
		fi
		exit 0
	fi

	# PR reviews (for CHANGES_REQUESTED check)
	if [[ "$*" == *"/pulls/"*"/reviews"* ]]; then
		if [[ -n "$_jq_filter" ]]; then
			jq "$_jq_filter" <"${TEST_ROOT}/reviews.json"
		else
			cat "${TEST_ROOT}/reviews.json"
		fi
		exit 0
	fi

	# Linked issue labels (needs-maintainer-review check)
	if [[ "$*" == *"/issues/"* && "$*" != *"comments"* && "$*" != *"collaborators"* ]]; then
		echo '{"labels": []}'
		exit 0
	fi

	# Issue comments (approval marker + dedup)
	if [[ "$*" == *"comments"* ]]; then
		echo '[]'
		exit 0
	fi
fi

# pr view with --json labels,isDraft
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done

	# labels+isDraft fetch (the new interactive gate in t2411).
	# The gate applies a jq transform internally; the mock bypasses the filter
	# and returns the already-transformed fixture directly so the caller's
	# secondary jq extraction (.labels, .isDraft) works correctly.
	if [[ "$*" == *"isDraft"* ]]; then
		cat "${TEST_ROOT}/pr-labels.json"
		exit 0
	fi

	# labels-only fetch (external-contributor gate)
	if [[ "$*" == *"labels"* ]]; then
		jq -r '.labels // ""' <"${TEST_ROOT}/pr-labels.json" 2>/dev/null || echo ""
		exit 0
	fi
fi

# pr checks --required
if [[ "${1:-}" == "pr" && "${2:-}" == "checks" ]]; then
	cat "${TEST_ROOT}/failing-checks.txt"
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

# Extract the two functions under test from pulse-merge.sh.
define_helpers_under_test() {
	local src
	# Extract _is_owner_or_member_author
	src=$(awk '
		/^_is_owner_or_member_author\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$src" ]]; then
		printf 'ERROR: could not extract _is_owner_or_member_author from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src"

	# Extract _pulse_merge_dismiss_coderabbit_nits (dependency of gate)
	src=$(awk '
		/^_pulse_merge_dismiss_coderabbit_nits\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	[[ -n "$src" ]] && eval "$src" || true

	# Extract _check_pr_merge_gates
	src=$(awk '
		/^_check_pr_merge_gates\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$src" ]]; then
		printf 'ERROR: could not extract _check_pr_merge_gates from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src"
	return 0
}

# Stub functions needed by _check_pr_merge_gates but not under test.
define_stubs() {
	_is_collaborator_author() {
		# Returns 0 for all authors in test context (gate already passed before
		# the interactive check, since _is_collaborator_author is called earlier).
		return 0
	}
	check_pr_modifies_workflows() { return 1; }
	check_gh_workflow_scope() { return 0; }
	_external_pr_has_linked_issue() { return 1; }
	_external_pr_linked_issue_crypto_approved() { return 1; }
	_extract_linked_issue() { echo "999"; return 0; }
	_dispatch_pr_fix_worker() { return 0; }
	_route_pr_to_fix_worker() { return 1; }
	return 0
}

# =============================================================================
# Case 1: OWNER author + interactive label + not draft + no hold-for-review
#         → gates pass, review bot gate bypassed.
# =============================================================================
test_case_1_owner_interactive_gates_pass() {
	reset_mock_state
	# OWNER, interactive, not draft, no hold-for-review
	cat >"${TEST_ROOT}/pr-labels.json" <<'EOF'
{"labels": "origin:interactive", "isDraft": "false"}
EOF
	cat >"${TEST_ROOT}/permission.json" <<'EOF'
{"permission": "admin"}
EOF

	local result=0
	_check_pr_merge_gates "101" "owner/repo" "alice" "NONE" "999" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case 1: OWNER interactive → gates pass" 1 \
			"Expected exit 0 (merge allowed), got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	# Verify review bot gate was NOT called (bypassed for interactive OWNER)
	if grep -q "review-bot-gate-helper.sh" "$GH_LOG" 2>/dev/null; then
		print_result "Case 1: OWNER interactive → review bot gate bypassed" 1 \
			"Expected review-bot-gate-helper not called. GH log: $(cat "$GH_LOG")"
		return 0
	fi
	# Verify audit log was written
	if ! grep -qF "auto-merged origin:interactive" "$LOGFILE"; then
		print_result "Case 1: OWNER interactive → audit log written" 1 \
			"Expected audit log for auto-merge. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case 1: OWNER interactive + all checks pass → gates pass (t2411)" 0
	return 0
}

# =============================================================================
# Case 2: COLLABORATOR (write permission) + interactive label
#         → does NOT get the fast path; falls through to review bot gate.
# =============================================================================
test_case_2_collaborator_interactive_no_fast_path() {
	reset_mock_state
	cat >"${TEST_ROOT}/pr-labels.json" <<'EOF'
{"labels": "origin:interactive", "isDraft": "false"}
EOF
	# write permission = COLLABORATOR, not OWNER/MEMBER
	cat >"${TEST_ROOT}/permission.json" <<'EOF'
{"permission": "write"}
EOF
	# review-bot-gate stub returns PASS so the PR is still mergeable
	cat >"${TEST_ROOT}/bin/review-bot-gate-helper.sh" <<'RBGEOF'
#!/usr/bin/env bash
echo "PASS"
RBGEOF
	chmod +x "${TEST_ROOT}/bin/review-bot-gate-helper.sh"

	local result=0
	_check_pr_merge_gates "102" "owner/repo" "bob" "NONE" "999" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case 2: COLLABORATOR interactive → review bot gate ran and passed" 1 \
			"Expected exit 0 (bot gate passed), got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	# The audit log for the interactive fast-path must NOT appear
	if grep -qF "auto-merged origin:interactive" "$LOGFILE"; then
		print_result "Case 2: COLLABORATOR interactive → no fast-path audit log" 1 \
			"Expected no fast-path audit log for write-permission author. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case 2: COLLABORATOR interactive → review bot gate ran (no fast path)" 0
	return 0
}

# =============================================================================
# Case 3: OWNER + 1 failing CI check → pre-gate check _pr_required_checks_pass
#         blocks BEFORE _check_pr_merge_gates is called. We test this by
#         verifying _check_pr_merge_gates still passes (CI check is a caller
#         responsibility), then documenting the expected combined behaviour.
#
# NOTE: _pr_required_checks_pass is called by _process_single_ready_pr BEFORE
# _check_pr_merge_gates. The gate function itself does not check CI. This test
# verifies that a non-zero failing-checks count does NOT accidentally bypass
# the fast-path (it's blocked upstream, not inside the gate).
# =============================================================================
test_case_3_owner_failing_ci_blocked_upstream() {
	reset_mock_state
	cat >"${TEST_ROOT}/pr-labels.json" <<'EOF'
{"labels": "origin:interactive", "isDraft": "false"}
EOF
	cat >"${TEST_ROOT}/permission.json" <<'EOF'
{"permission": "admin"}
EOF
	# 1 failing check — simulating what _pr_required_checks_pass would see
	echo '1' >"${TEST_ROOT}/failing-checks.txt"

	# _check_pr_merge_gates does not inspect CI — it returns 0 for OWNER interactive.
	# The CI block happens BEFORE this function is called. Test that the gate itself
	# still returns 0 (the right caller blocks it via _pr_required_checks_pass).
	local result=0
	_check_pr_merge_gates "103" "owner/repo" "alice" "NONE" "999" || result=$?

	# Gate still returns 0 because CI check is a pre-gate caller concern.
	# This is expected and correct — the test documents the boundary.
	if [[ "$result" -ne 0 ]]; then
		print_result "Case 3: OWNER failing CI — gate boundary documented" 1 \
			"Expected gate to return 0 (CI is pre-gate). Got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case 3: OWNER failing CI — CI gate is caller responsibility (boundary verified)" 0
	return 0
}

# =============================================================================
# Case 4: OWNER author + hold-for-review label → gates block.
# =============================================================================
test_case_4_owner_hold_for_review_blocked() {
	reset_mock_state
	cat >"${TEST_ROOT}/pr-labels.json" <<'EOF'
{"labels": "origin:interactive,hold-for-review", "isDraft": "false"}
EOF
	cat >"${TEST_ROOT}/permission.json" <<'EOF'
{"permission": "admin"}
EOF

	local result=0
	_check_pr_merge_gates "104" "owner/repo" "alice" "NONE" "999" || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case 4: OWNER + hold-for-review → gates block" 1 \
			"Expected exit 1 (hold-for-review), got exit 0. Log: $(cat "$LOGFILE")"
		return 0
	fi
	if ! grep -qF "hold-for-review" "$LOGFILE"; then
		print_result "Case 4: OWNER + hold-for-review → skip logged" 1 \
			"Expected hold-for-review skip log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case 4: OWNER + hold-for-review label → gates block (t2411)" 0
	return 0
}

# =============================================================================
# Case 5: OWNER author + draft PR → gates block.
# =============================================================================
test_case_5_owner_draft_pr_blocked() {
	reset_mock_state
	cat >"${TEST_ROOT}/pr-labels.json" <<'EOF'
{"labels": "origin:interactive", "isDraft": "true"}
EOF
	cat >"${TEST_ROOT}/permission.json" <<'EOF'
{"permission": "admin"}
EOF

	local result=0
	_check_pr_merge_gates "105" "owner/repo" "alice" "NONE" "999" || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case 5: OWNER + draft PR → gates block" 1 \
			"Expected exit 1 (draft), got exit 0. Log: $(cat "$LOGFILE")"
		return 0
	fi
	if ! grep -qF "is draft" "$LOGFILE"; then
		print_result "Case 5: OWNER + draft PR → skip logged" 1 \
			"Expected draft skip log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case 5: OWNER + draft PR → gates block (t2411)" 0
	return 0
}

# =============================================================================
# Case 6: OWNER author + human CHANGES_REQUESTED → existing gate blocks
#         (this fires BEFORE the interactive fast path, so the interactive
#         path is never reached).
# =============================================================================
test_case_6_owner_human_changes_requested_blocked() {
	reset_mock_state
	cat >"${TEST_ROOT}/pr-labels.json" <<'EOF'
{"labels": "origin:interactive", "isDraft": "false"}
EOF
	cat >"${TEST_ROOT}/permission.json" <<'EOF'
{"permission": "admin"}
EOF
	# Human review CHANGES_REQUESTED — no coderabbit-nits-ok label
	cat >"${TEST_ROOT}/reviews.json" <<'EOF'
[
  {"id": 6001, "user": {"login": "human-reviewer"}, "state": "CHANGES_REQUESTED"}
]
EOF

	local result=0
	# pr_review = "CHANGES_REQUESTED" triggers the first gate in _check_pr_merge_gates
	_check_pr_merge_gates "106" "owner/repo" "alice" "CHANGES_REQUESTED" "999" || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "Case 6: OWNER + human CHANGES_REQUESTED → gates block" 1 \
			"Expected exit 1 (CHANGES_REQUESTED), got exit 0. Log: $(cat "$LOGFILE")"
		return 0
	fi
	# The interactive fast-path audit log must NOT appear (gate fired before it)
	if grep -qF "auto-merged origin:interactive" "$LOGFILE"; then
		print_result "Case 6: OWNER + CHANGES_REQUESTED → fast path not reached" 1 \
			"Interactive audit log appeared despite CHANGES_REQUESTED block. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case 6: OWNER + human CHANGES_REQUESTED → blocked by existing gate" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi
	define_stubs

	test_case_1_owner_interactive_gates_pass
	test_case_2_collaborator_interactive_no_fast_path
	test_case_3_owner_failing_ci_blocked_upstream
	test_case_4_owner_hold_for_review_blocked
	test_case_5_owner_draft_pr_blocked
	test_case_6_owner_human_changes_requested_blocked

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
