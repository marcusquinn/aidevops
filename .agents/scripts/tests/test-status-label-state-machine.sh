#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-status-label-state-machine.sh — t2033 regression guard.
#
# Asserts the `set_issue_status` helper in shared-constants.sh:
#
#   1. Emits exactly one --add-label flag for the target status
#   2. Emits --remove-label flags for every sibling core status label
#   3. Passes extra arguments through verbatim (e.g., --add-assignee)
#   4. Handles the empty-status "clear only" case (7 removes, 0 adds)
#   5. Rejects invalid status strings with exit code 2
#   6. Rejects empty issue number or repo slug with exit code 2
#
# Failure history motivating this test: GH#18444, GH#18454, GH#18455 all
# accumulated both status:available and status:queued simultaneously because
# _dispatch_launch_worker at pulse-dispatch-core.sh:1062 added status:queued
# without removing status:available. The helper centralises the state-machine
# transition so no future call site can repeat the bug.
#
# NOTE: not using `set -e` — assertions rely on capturing non-zero exits.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
}

# Sandbox HOME so sourcing shared-constants.sh is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"
# Exported so the gh stub subprocess can reach it at runtime — the heredoc
# below is quoted ('STUBEOF') to avoid substitution at stub-write time.
export GH_CALLS_FILE="${TEST_ROOT}/gh_calls.log"

#######################################
# Write a gh stub that records every invocation's argv to GH_CALLS_FILE,
# one call per line. Used to verify set_issue_status constructs the correct
# --add-label / --remove-label / --add-assignee flag set.
#
# The stub always exits 0 so the helper's "$?" reflects argument validation
# and label-set construction logic, not simulated gh failures.
#######################################
write_stub_gh() {
	: >"$GH_CALLS_FILE"
	cat >"${STUB_DIR}/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Stub gh for test-status-label-state-machine.sh — records all calls.
printf '%s\n' "$*" >>"${GH_CALLS_FILE}"
exit 0
STUBEOF
	chmod +x "${STUB_DIR}/gh"
}

# Source the helper. Prepending STUB_DIR to PATH ensures the stub is picked up.
export PATH="${STUB_DIR}:${PATH}"
write_stub_gh

# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh"

# Reset per-test caches so each case starts clean
_reset_state() {
	_STATUS_LABELS_ENSURED=""
	: >"$GH_CALLS_FILE"
}

#######################################
# assert_edit_call_has_flags: verify the LAST `gh issue edit` call in
# GH_CALLS_FILE contains every required flag token (space-separated match).
#
# Args:
#   $1 — descriptive test name
#   $@ — required substrings (each must appear in the edit-call line)
#######################################
assert_last_edit_has() {
	local name="$1"
	shift
	local last_edit
	last_edit=$(grep 'issue edit' "$GH_CALLS_FILE" | tail -1 || true)
	if [[ -z "$last_edit" ]]; then
		print_result "$name" 1 "(no 'issue edit' call recorded)"
		return 0
	fi
	local missing=()
	local needle
	for needle in "$@"; do
		if ! printf '%s' "$last_edit" | grep -qF -- "$needle"; then
			missing+=("$needle")
		fi
	done
	if [[ ${#missing[@]} -eq 0 ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "(missing: ${missing[*]} | got: ${last_edit})"
	fi
}

#######################################
# assert_last_edit_lacks: verify the LAST `gh issue edit` call does NOT
# contain any of the forbidden substrings.
#######################################
assert_last_edit_lacks() {
	local name="$1"
	shift
	local last_edit
	last_edit=$(grep 'issue edit' "$GH_CALLS_FILE" | tail -1 || true)
	if [[ -z "$last_edit" ]]; then
		print_result "$name" 1 "(no 'issue edit' call recorded)"
		return 0
	fi
	local present=()
	local needle
	for needle in "$@"; do
		if printf '%s' "$last_edit" | grep -qF -- "$needle"; then
			present+=("$needle")
		fi
	done
	if [[ ${#present[@]} -eq 0 ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "(forbidden present: ${present[*]} | got: ${last_edit})"
	fi
}

#######################################
# TEST 1: Transition to status:queued produces 1 add + 6 removes
#######################################
test_queued_transition() {
	_reset_state
	set_issue_status 1 "owner/repo" "queued" || {
		print_result "queued transition returns 0" 1 "(exit=$?)"
		return 0
	}
	print_result "queued transition returns 0" 0
	assert_last_edit_has "queued: adds status:queued" \
		"--add-label status:queued"
	assert_last_edit_has "queued: removes 6 siblings" \
		"--remove-label status:available" \
		"--remove-label status:claimed" \
		"--remove-label status:in-progress" \
		"--remove-label status:in-review" \
		"--remove-label status:done" \
		"--remove-label status:blocked"
	assert_last_edit_lacks "queued: does NOT remove the target" \
		"--remove-label status:queued"
}

#######################################
# TEST 2: Transition to status:available with --remove-assignee passthrough
#######################################
test_available_with_extra_flags() {
	_reset_state
	set_issue_status 42 "owner/repo" "available" \
		--remove-assignee "stale-worker" || {
		print_result "available+extra returns 0" 1 "(exit=$?)"
		return 0
	}
	print_result "available+extra returns 0" 0
	assert_last_edit_has "available+extra: adds status:available" \
		"--add-label status:available"
	assert_last_edit_has "available+extra: passes through --remove-assignee" \
		"--remove-assignee stale-worker"
	assert_last_edit_has "available+extra: removes sibling status:queued" \
		"--remove-label status:queued"
}

#######################################
# TEST 3: Empty status (clear only) with --add-label passthrough
# Used by stale-recovery escalation: clear core statuses, add needs-maintainer-review
#######################################
test_empty_status_clear_only() {
	_reset_state
	set_issue_status 99 "owner/repo" "" \
		--add-label "needs-maintainer-review" || {
		print_result "empty status returns 0" 1 "(exit=$?)"
		return 0
	}
	print_result "empty status returns 0" 0
	assert_last_edit_has "clear-only: passes through --add-label" \
		"--add-label needs-maintainer-review"
	assert_last_edit_has "clear-only: removes status:available" \
		"--remove-label status:available"
	assert_last_edit_has "clear-only: removes status:blocked" \
		"--remove-label status:blocked"
	assert_last_edit_lacks "clear-only: does NOT add any core status:*" \
		"--add-label status:available" \
		"--add-label status:queued" \
		"--add-label status:claimed" \
		"--add-label status:in-progress" \
		"--add-label status:in-review" \
		"--add-label status:done" \
		"--add-label status:blocked"
}

#######################################
# TEST 4: Transition to in-progress removes status:claimed (t1996 normalization)
#######################################
test_in_progress_removes_claimed() {
	_reset_state
	set_issue_status 7 "owner/repo" "in-progress" || {
		print_result "in-progress transition returns 0" 1 "(exit=$?)"
		return 0
	}
	print_result "in-progress transition returns 0" 0
	assert_last_edit_has "in-progress: adds status:in-progress" \
		"--add-label status:in-progress"
	assert_last_edit_has "in-progress: removes status:claimed" \
		"--remove-label status:claimed"
}

#######################################
# TEST 5: Invalid status string returns exit 2, no gh call
#######################################
test_invalid_status_rejected() {
	_reset_state
	set_issue_status 1 "owner/repo" "nonsense" 2>/dev/null
	local rc=$?
	if [[ "$rc" -eq 2 ]]; then
		print_result "invalid status returns exit 2" 0
	else
		print_result "invalid status returns exit 2" 1 "(got rc=${rc})"
	fi
	# No gh issue edit should have been recorded
	if ! grep -q 'issue edit' "$GH_CALLS_FILE" 2>/dev/null; then
		print_result "invalid status: no gh issue edit call" 0
	else
		print_result "invalid status: no gh issue edit call" 1 \
			"(unexpected: $(cat "$GH_CALLS_FILE"))"
	fi
}

#######################################
# TEST 6: Missing issue_num or repo_slug returns exit 2
#######################################
test_missing_args_rejected() {
	_reset_state
	set_issue_status "" "owner/repo" "queued" 2>/dev/null
	local rc1=$?
	if [[ "$rc1" -eq 2 ]]; then
		print_result "empty issue_num returns exit 2" 0
	else
		print_result "empty issue_num returns exit 2" 1 "(got rc=${rc1})"
	fi

	_reset_state
	set_issue_status 1 "" "queued" 2>/dev/null
	local rc2=$?
	if [[ "$rc2" -eq 2 ]]; then
		print_result "empty repo_slug returns exit 2" 0
	else
		print_result "empty repo_slug returns exit 2" 1 "(got rc=${rc2})"
	fi
}

#######################################
# TEST 7: ISSUE_STATUS_LABELS array has exactly the expected 7 elements
#######################################
test_canonical_label_list() {
	local expected=("available" "queued" "claimed" "in-progress" "in-review" "done" "blocked")
	if [[ "${#ISSUE_STATUS_LABELS[@]}" -ne "${#expected[@]}" ]]; then
		print_result "ISSUE_STATUS_LABELS has 7 elements" 1 \
			"(got ${#ISSUE_STATUS_LABELS[@]}: ${ISSUE_STATUS_LABELS[*]})"
		return 0
	fi
	local i
	for i in "${!expected[@]}"; do
		if [[ "${ISSUE_STATUS_LABELS[i]}" != "${expected[i]}" ]]; then
			print_result "ISSUE_STATUS_LABELS matches expected order" 1 \
				"(pos ${i}: expected ${expected[i]}, got ${ISSUE_STATUS_LABELS[i]})"
			return 0
		fi
	done
	print_result "ISSUE_STATUS_LABELS matches expected order" 0
}

#######################################
# TEST 8: Dispatch-realistic pattern — queued + add-assignee + add-label +
# remove-assignee (the exact shape _dispatch_launch_worker uses). This is
# the bug site from t2033: #18444 accumulated status:available + status:queued
# because the old code didn't remove siblings.
#######################################
test_dispatch_realistic_pattern() {
	_reset_state
	# Simulate the real call from pulse-dispatch-core.sh after t2033 migration
	set_issue_status 18444 "marcusquinn/aidevops" "queued" \
		--add-assignee "runner-a" \
		--add-label "origin:worker" \
		--remove-assignee "runner-b" || {
		print_result "dispatch pattern returns 0" 1 "(exit=$?)"
		return 0
	}
	print_result "dispatch pattern returns 0" 0
	assert_last_edit_has "dispatch: adds status:queued" \
		"--add-label status:queued"
	assert_last_edit_has "dispatch: removes status:available (the t2033 bug fix)" \
		"--remove-label status:available"
	assert_last_edit_has "dispatch: passes through --add-assignee" \
		"--add-assignee runner-a"
	assert_last_edit_has "dispatch: passes through --add-label origin:worker" \
		"--add-label origin:worker"
	assert_last_edit_has "dispatch: passes through --remove-assignee" \
		"--remove-assignee runner-b"
}

# =============================================================================
# Run tests
# =============================================================================
main() {
	test_queued_transition
	test_available_with_extra_flags
	test_empty_status_clear_only
	test_in_progress_removes_claimed
	test_invalid_status_rejected
	test_missing_args_rejected
	test_canonical_label_list
	test_dispatch_realistic_pattern

	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
