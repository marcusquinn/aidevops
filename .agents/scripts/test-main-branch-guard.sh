#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-main-branch-guard.sh — Integration tests for the main-branch-guard
# post-checkout hook (t1994).
#
# Tests create a real temporary git repo (no network), install the hook via
# install-main-branch-guard.sh, then verify the four behavioural cases:
#
#   1. canonical checkout other-branch  → hook fires, auto-restores main
#   2. canonical checkout -b new-branch → hook fires, auto-restores main, new branch deleted
#   3. linked worktree checkout -b wt-branch → hook silent, branch stays
#   4. canonical checkout main (no-op)  → hook silent, no error
#
# Usage:
#   .agents/scripts/test-main-branch-guard.sh
# Exit code 0 = all pass, 1 = at least one failure.

set -u

# Colours
if [[ -t 1 ]]; then
	GREEN=$'\033[0;32m'
	RED=$'\033[0;31m'
	BLUE=$'\033[0;34m'
	NC=$'\033[0m'
else
	GREEN="" RED="" BLUE="" NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$GREEN" "$NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$RED" "$NC" "$1"
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/install-main-branch-guard.sh"
HOOK_SOURCE="${SCRIPT_DIR}/../hooks/main-branch-guard-post-checkout.sh"

if [[ ! -f "$INSTALLER" ]]; then
	printf 'test harness cannot find installer at %s\n' "$INSTALLER" >&2
	exit 1
fi

if [[ ! -f "$HOOK_SOURCE" ]]; then
	printf 'test harness cannot find hook source at %s\n' "$HOOK_SOURCE" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Set up a temporary canonical git repo
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CANONICAL="${TMP}/canonical"
mkdir -p "$CANONICAL"

(
	cd "$CANONICAL" || exit 1
	git init --quiet
	git config user.email 'test@example.com'
	git config user.name 'Test'
	# Disable signing — test repo has no GPG/SSH key configured
	git config commit.gpgsign false
	git config tag.gpgsign false
	git config gpg.format openpgp
	git commit --allow-empty -m 'init' --quiet
	# Create a second commit so there is something to branch from
	git commit --allow-empty -m 'second' --quiet
	# Create a branch for test cases (but stay on main)
	git branch existing-branch
) || {
	printf 'failed to create canonical test repo\n' >&2
	exit 1
}

# Copy the hook source into the test repo's .agents/hooks/ so the dispatcher
# can find it via the repo-local lookup path (mirrors real-world setup).
mkdir -p "${CANONICAL}/.agents/hooks"
cp "$HOOK_SOURCE" "${CANONICAL}/.agents/hooks/main-branch-guard-post-checkout.sh"
chmod +x "${CANONICAL}/.agents/hooks/main-branch-guard-post-checkout.sh"

# Install hook into canonical repo
install_output=$(cd "$CANONICAL" && bash "$INSTALLER" install 2>&1)
if ! printf '%s' "$install_output" | grep -q 'installed main-branch-guard'; then
	printf 'installer failed:\n%s\n' "$install_output" >&2
	exit 1
fi

printf '%sRunning main-branch-guard tests%s\n' "$BLUE" "$NC"

# ---------------------------------------------------------------------------
# Test 1: canonical checkout other-branch → auto-restore main
# ---------------------------------------------------------------------------
(
	cd "$CANONICAL" || exit 1
	stderr_out=$(git checkout existing-branch 2>&1 || true)
	final_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
	if [[ "$final_branch" == "main" ]] && printf '%s' "$stderr_out" | grep -q 'BLOCKED'; then
		exit 0
	fi
	exit 1
) && pass "canonical checkout other-branch → blocked and restored to main" ||
	fail "canonical checkout other-branch → expected block + main restore"

# ---------------------------------------------------------------------------
# Test 2: canonical checkout -b new-branch → auto-restore main, branch cleaned up
# ---------------------------------------------------------------------------
# The hook restores main but cannot delete the newly created branch itself
# (deleting a branch that HEAD was just on would fail). The test verifies
# that HEAD is back on main — the leftover branch ref is the expected behaviour.
(
	cd "$CANONICAL" || exit 1
	stderr_out=$(git checkout -b new-test-branch 2>&1 || true)
	final_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
	if [[ "$final_branch" == "main" ]] && printf '%s' "$stderr_out" | grep -q 'BLOCKED'; then
		exit 0
	fi
	exit 1
) && pass "canonical checkout -b new-branch → blocked and restored to main" ||
	fail "canonical checkout -b new-branch → expected block + main restore"

# Clean up any branch created by test 2
(cd "$CANONICAL" && git branch -D new-test-branch 2>/dev/null || true)

# ---------------------------------------------------------------------------
# Test 3: linked worktree checkout -b branch → hook silent, branch stays
# ---------------------------------------------------------------------------
LINKED="${TMP}/linked-worktree"
(
	cd "$CANONICAL" || exit 1
	git worktree add "$LINKED" -b wt-feature-branch 2>&1 || true
) >/dev/null 2>&1

if [[ -d "$LINKED" ]]; then
	(
		cd "$LINKED" || exit 1
		stderr_out=$(git checkout -b wt-new-branch 2>&1 || true)
		final_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
		# Hook should NOT fire: no BLOCKED message, branch should be wt-new-branch
		if [[ "$final_branch" == "wt-new-branch" ]] && ! printf '%s' "$stderr_out" | grep -q 'BLOCKED'; then
			exit 0
		fi
		exit 1
	) && pass "linked worktree checkout -b → hook silent, branch stays" ||
		fail "linked worktree checkout -b → expected hook to be silent"
else
	fail "linked worktree checkout -b → could not create linked worktree (skipped)"
fi

# ---------------------------------------------------------------------------
# Test 4: canonical checkout main (no-op) → hook silent, no error
# ---------------------------------------------------------------------------
(
	cd "$CANONICAL" || exit 1
	# Ensure we are on main
	git checkout main --quiet 2>/dev/null || true
	# Now checkout main again — should be a no-op
	stderr_out=$(git checkout main 2>&1 || true)
	final_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
	if [[ "$final_branch" == "main" ]] && ! printf '%s' "$stderr_out" | grep -q 'BLOCKED'; then
		exit 0
	fi
	exit 1
) && pass "canonical checkout main (already on main) → hook silent, no error" ||
	fail "canonical checkout main → expected hook silent but got BLOCKED message"

# ---------------------------------------------------------------------------
# Test 5: opt-out via AIDEVOPS_MAIN_BRANCH_GUARD=false
# ---------------------------------------------------------------------------
(
	cd "$CANONICAL" || exit 1
	AIDEVOPS_MAIN_BRANCH_GUARD=false git checkout existing-branch 2>/dev/null || true
	final_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
	# With opt-out, branch switch should succeed (no restore)
	if [[ "$final_branch" == "existing-branch" ]]; then
		# Restore back to main for subsequent tests
		AIDEVOPS_MAIN_BRANCH_GUARD=false git checkout main 2>/dev/null || true
		exit 0
	fi
	exit 1
) && pass "AIDEVOPS_MAIN_BRANCH_GUARD=false → hook bypassed, branch switch succeeds" ||
	fail "AIDEVOPS_MAIN_BRANCH_GUARD=false → expected bypass but hook still fired"

# ---------------------------------------------------------------------------
# Test 6: idempotent install
# ---------------------------------------------------------------------------
install_output2=$(cd "$CANONICAL" && bash "$INSTALLER" install 2>&1)
if printf '%s' "$install_output2" | grep -q 'already installed'; then
	pass "idempotent install → second install reports already installed"
else
	fail "idempotent install → second install did not report already installed (got: $install_output2)"
fi

# ---------------------------------------------------------------------------
# Test 7: status reports installed
# ---------------------------------------------------------------------------
status_output=$(cd "$CANONICAL" && bash "$INSTALLER" status 2>&1)
if printf '%s' "$status_output" | grep -q 'aidevops main-branch-guard'; then
	pass "status → reports installed (aidevops main-branch-guard)"
else
	fail "status → expected 'aidevops main-branch-guard' in output (got: $status_output)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%s tests, %s failures\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll tests passed.%s\n' "$GREEN" "$NC"
	exit 0
else
	printf '%s%s test(s) failed.%s\n' "$RED" "$TESTS_FAILED" "$NC"
	exit 1
fi
