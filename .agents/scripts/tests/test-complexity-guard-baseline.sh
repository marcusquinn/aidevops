#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-complexity-guard-baseline.sh — GH#20045 regression guard.
#
# Verifies that _compute_baseline in complexity-regression-pre-push.sh
# resolves to the default remote branch (origin/HEAD / origin/main /
# origin/master) rather than @{u}, preventing spurious false-positives
# after a git rebase.
#
# Root cause (GH#20045): after `git rebase origin/main`, @{u} points at
# the feature branch's own remote (pre-rebase), not the merge target.
# So `git merge-base HEAD @{u}` returns an outdated ancestor that makes
# every commit since the (now-abandoned) rebase base look "new" to the
# complexity scanner.
#
# Tests:
#   1. origin/HEAD set → baseline resolved via origin/HEAD
#   2. origin/HEAD unset, origin/main present → fallback to origin/main
#   3. origin/HEAD unset, origin/master present → fallback to origin/master
#   4. All origin refs missing → @{u} fallback with warning
#   5. Post-rebase stale @{u}: _compute_baseline uses origin/main, not @{u}
#   6. Hook integration: COMPLEXITY_HELPER stub + _compute_baseline → no
#      spurious block when stale @{u} would have triggered one

set -uo pipefail

# Disable commit signing for all git operations in this test so no SSH
# passphrase is required when creating commits in temporary repos.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgSign
export GIT_CONFIG_VALUE_0=false

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HOOKS_DIR="$(cd "${SCRIPT_DIR_TEST}/../../hooks" && pwd)" || exit 1
HOOK="${HOOKS_DIR}/complexity-regression-pre-push.sh"

if [[ ! -f "$HOOK" ]]; then
	printf 'ERROR: hook not found at %s\n' "$HOOK" >&2
	exit 1
fi

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# =============================================================================
# Extract _compute_baseline from the hook for isolated unit testing.
# Uses awk to capture from the function declaration to its closing brace
# (brace at column 0). Any inner braces are on lines with leading whitespace
# so they won't trigger the end-of-range match.
# =============================================================================
GUARD_NAME="complexity-guard"

_load_compute_baseline() {
	local fn_src
	fn_src=$(awk '/^_compute_baseline\(\)/,/^\}$/' "$HOOK")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: _compute_baseline not found in %s\n' "$HOOK" >&2
		return 1
	fi
	eval "$fn_src"
	return 0
}

# Load once into the current shell (for tests that run in-process)
_load_compute_baseline || exit 1

# =============================================================================
# Git sandbox helpers
# =============================================================================
TMP=$(mktemp -d -t gh20045.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

_git_setup_bare_origin() {
	local dir="$1"
	mkdir -p "$dir"
	git -C "$dir" init --bare --quiet
	# Set default branch to main (macOS git may default to master)
	git -C "$dir" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
	return 0
}

_git_setup_clone() {
	local origin="$1"
	local clone_dir="$2"
	git clone --quiet "$origin" "$clone_dir" 2>/dev/null
	git -C "$clone_dir" config user.email "test@test.com"
	git -C "$clone_dir" config user.name "Test"
	return 0
}

_git_initial_commit() {
	local dir="$1"
	printf 'initial\n' > "${dir}/file.txt"
	git -C "$dir" add . >/dev/null
	git -C "$dir" commit --quiet -m "initial commit"
	# Normalize branch name to main (macOS git may default to master)
	git -C "$dir" branch -M main 2>/dev/null || true
	return 0
}

# Push HEAD to main on the given remote and update origin/HEAD tracking.
# Uses HEAD:main to push regardless of local branch name.
_git_push_main() {
	local dir="$1"
	git -C "$dir" push --quiet origin "HEAD:main" 2>/dev/null
	git -C "$dir" remote set-head origin main 2>/dev/null || true
	return 0
}

printf '%sRunning _compute_baseline baseline tests (GH#20045)%s\n' \
	"$TEST_BLUE" "$TEST_NC"
printf '\n'

# =============================================================================
# Test 1 — origin/HEAD set → baseline resolved via origin/HEAD
# A fresh clone from a local bare origin always has origin/HEAD set.
# =============================================================================
{
	ORIGIN="${TMP}/t1_origin"
	CLONE="${TMP}/t1_clone"
	_git_setup_bare_origin "$ORIGIN"
	_git_setup_clone "$ORIGIN" "$CLONE"
	_git_initial_commit "$CLONE"
	_git_push_main "$CLONE"  # pushes HEAD:main + sets origin/HEAD

	actual=$(cd "$CLONE" && _compute_baseline 2>/dev/null)
	if [[ -n "$actual" ]]; then
		pass "origin/HEAD set → _compute_baseline returns non-empty SHA"
	else
		fail "origin/HEAD set → _compute_baseline returns non-empty SHA" \
			"got empty output; origin/HEAD=$(git -C "$CLONE" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || echo unset)"
	fi
}

# =============================================================================
# Test 2 — origin/HEAD unset, origin/main present → fallback to origin/main
# =============================================================================
{
	ORIGIN="${TMP}/t2_origin"
	CLONE="${TMP}/t2_clone"
	_git_setup_bare_origin "$ORIGIN"
	_git_setup_clone "$ORIGIN" "$CLONE"
	_git_initial_commit "$CLONE"
	_git_push_main "$CLONE"

	# Remove origin/HEAD to force the fallback path
	git -C "$CLONE" remote set-head origin --delete 2>/dev/null || true

	actual=$(cd "$CLONE" && _compute_baseline 2>/dev/null)
	expected=$(git -C "$CLONE" merge-base HEAD origin/main 2>/dev/null)

	if [[ -n "$actual" && "$actual" == "$expected" ]]; then
		pass "origin/HEAD unset, origin/main present → fallback to origin/main"
	else
		fail "origin/HEAD unset, origin/main present → fallback to origin/main" \
			"actual='${actual:0:10}' expected='${expected:0:10}'"
	fi
}

# =============================================================================
# Test 3 — origin/HEAD unset, origin/master present → fallback to origin/master
# =============================================================================
{
	ORIGIN="${TMP}/t3_origin"
	CLONE="${TMP}/t3_clone"
	_git_setup_bare_origin "$ORIGIN"
	_git_setup_clone "$ORIGIN" "$CLONE"
	_git_initial_commit "$CLONE"
	# Push to master (legacy default)
	git -C "$CLONE" push --quiet origin "HEAD:master" 2>/dev/null

	# Remove origin/HEAD and origin/main refs to force origin/master fallback
	git -C "$CLONE" remote set-head origin --delete 2>/dev/null || true
	git -C "$CLONE" update-ref -d refs/remotes/origin/main 2>/dev/null || true

	actual=$(cd "$CLONE" && _compute_baseline 2>/dev/null)
	expected=$(git -C "$CLONE" merge-base HEAD origin/master 2>/dev/null)

	if [[ -n "$actual" && "$actual" == "$expected" ]]; then
		pass "origin/HEAD unset, origin/master present → fallback to origin/master"
	else
		fail "origin/HEAD unset, origin/master present → fallback to origin/master" \
			"actual='${actual:0:10}' expected='${expected:0:10}'"
	fi
}

# =============================================================================
# Test 4 — All origin refs missing → @{u} fallback with warning on stderr
# =============================================================================
{
	ORIGIN="${TMP}/t4_origin"
	CLONE="${TMP}/t4_clone"
	_git_setup_bare_origin "$ORIGIN"
	_git_setup_clone "$ORIGIN" "$CLONE"
	_git_initial_commit "$CLONE"
	_git_push_main "$CLONE"
	git -C "$CLONE" branch --set-upstream-to=origin/main main 2>/dev/null || true

	# Remove all origin refs to force @{u} fallback
	git -C "$CLONE" remote set-head origin --delete 2>/dev/null || true
	git -C "$CLONE" update-ref -d refs/remotes/origin/main 2>/dev/null || true
	git -C "$CLONE" update-ref -d refs/remotes/origin/master 2>/dev/null || true

	# With @{u} pointing at origin/main (now deleted), git merge-base fails → empty output
	# We only check that the warning is emitted; baseline may be empty (fail-open path).
	warning_output=$(cd "$CLONE" && _compute_baseline 2>&1 >/dev/null)

	if printf '%s' "$warning_output" | grep -q "falling back to @{u}"; then
		pass "all origin refs missing → @{u} fallback warning emitted"
	else
		fail "all origin refs missing → @{u} fallback warning emitted" \
			"stderr did not contain '@{u}' warning; got: '$warning_output'"
	fi
}

# =============================================================================
# Test 5 — Post-rebase stale @{u}: _compute_baseline uses origin/main, not @{u}
#
# Scenario:
#   - Origin has main at commit A.
#   - Feature branch is created at A, commit B added, pushed → @{u} = origin/feature at B.
#   - Main advances to commit C (added via a second worker clone).
#   - Feature is rebased onto new main → HEAD is now B' (rebase of B on C).
#   - @{u} is still origin/feature at B (stale).
#   - merge-base(HEAD, @{u}) = A (the initial commit — too far back)
#   - merge-base(HEAD, origin/main) = C (correct — only shows changes from C to B')
# =============================================================================
{
	ORIGIN="${TMP}/t5_origin"
	CLONE="${TMP}/t5_clone"
	WORKER="${TMP}/t5_worker"

	# Bare origin
	_git_setup_bare_origin "$ORIGIN"

	# Initial clone → commit A on main
	_git_setup_clone "$ORIGIN" "$CLONE"
	_git_initial_commit "$CLONE"
	_git_push_main "$CLONE"

	# Create feature branch from A, add commit B, push → sets @{u}
	git -C "$CLONE" checkout -b feature/t5 --quiet 2>/dev/null
	printf 'feature\n' > "${CLONE}/feature.txt"
	git -C "$CLONE" add . >/dev/null
	git -C "$CLONE" commit --quiet -m "feature commit B"
	git -C "$CLONE" push --quiet --set-upstream origin feature/t5 2>/dev/null

	# Advance origin/main via a worker clone (commit C)
	_git_setup_clone "$ORIGIN" "$WORKER"
	printf 'main advance\n' > "${WORKER}/main_advance.txt"
	git -C "$WORKER" add . >/dev/null
	git -C "$WORKER" commit --quiet -m "main advance C"
	git -C "$WORKER" push --quiet origin "HEAD:main" 2>/dev/null

	# Fetch in clone and rebase feature onto new main
	git -C "$CLONE" fetch --quiet origin 2>/dev/null
	git -C "$CLONE" rebase --quiet origin/main 2>/dev/null

	# Confirm stale @{u} state: @{u} should point to old feature SHA (pre-rebase)
	upstream_sha=$(git -C "$CLONE" rev-parse "@{u}" 2>/dev/null || echo "")
	head_sha=$(git -C "$CLONE" rev-parse HEAD 2>/dev/null)
	stale_baseline=$(git -C "$CLONE" merge-base HEAD "@{u}" 2>/dev/null || echo "")
	correct_baseline=$(git -C "$CLONE" merge-base HEAD origin/main 2>/dev/null)

	actual=$(cd "$CLONE" && _compute_baseline 2>/dev/null)

	if [[ -z "$correct_baseline" ]]; then
		fail "stale @{u} post-rebase: setup failed (could not compute correct baseline)" \
			"origin/main SHA=$(git -C "$CLONE" rev-parse origin/main 2>/dev/null || echo unset)"
	elif [[ "$actual" == "$correct_baseline" ]]; then
		if [[ -n "$stale_baseline" && "$stale_baseline" != "$correct_baseline" ]]; then
			pass "stale @{u} post-rebase: _compute_baseline uses origin/main (not stale @{u})"
		else
			pass "stale @{u} post-rebase: _compute_baseline returns correct baseline"
		fi
	else
		fail "stale @{u} post-rebase: _compute_baseline uses origin/main (not stale @{u})" \
			"actual='${actual:0:10}' correct='${correct_baseline:0:10}' stale='${stale_baseline:0:10}'"
	fi
}

# =============================================================================
# Test 6 — Hook integration: stub helper returns 0 for all metrics;
# the hook exits 0 (push allowed) even when @{u} is stale.
# =============================================================================
{
	ORIGIN="${TMP}/t6_origin"
	CLONE="${TMP}/t6_clone"
	WORKER="${TMP}/t6_worker"

	# Replicate the stale-@{u} setup from Test 5
	_git_setup_bare_origin "$ORIGIN"
	_git_setup_clone "$ORIGIN" "$CLONE"
	_git_initial_commit "$CLONE"
	_git_push_main "$CLONE"

	git -C "$CLONE" checkout -b feature/t6 --quiet 2>/dev/null
	printf 'feature6\n' > "${CLONE}/feature6.txt"
	git -C "$CLONE" add . >/dev/null
	git -C "$CLONE" commit --quiet -m "feature commit"
	git -C "$CLONE" push --quiet --set-upstream origin feature/t6 2>/dev/null

	_git_setup_clone "$ORIGIN" "$WORKER"
	printf 'main advance6\n' > "${WORKER}/main6.txt"
	git -C "$WORKER" add . >/dev/null
	git -C "$WORKER" commit --quiet -m "main advance"
	git -C "$WORKER" push --quiet origin "HEAD:main" 2>/dev/null

	git -C "$CLONE" fetch --quiet origin 2>/dev/null
	git -C "$CLONE" rebase --quiet origin/main 2>/dev/null

	# Stub helper: always exits 0 (no violations)
	STUB_HELPER="${TMP}/stub_helper.sh"
	printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_HELPER"
	chmod +x "$STUB_HELPER"

	hook_rc=0
	# Run the hook from within the clone repo; inject stub helper
	(
		cd "$CLONE" || exit 1
		COMPLEXITY_HELPER="$STUB_HELPER" \
		COMPLEXITY_GUARD_DEBUG=0 \
		bash "$HOOK" origin "file://$ORIGIN" </dev/null
	) 2>/dev/null
	hook_rc=$?

	if [[ "$hook_rc" -eq 0 ]]; then
		pass "hook integration: stub helper + stale @{u} → push allowed (exit 0)"
	else
		fail "hook integration: stub helper + stale @{u} → push allowed (exit 0)" \
			"hook exited $hook_rc — expected 0 (no violations when helper reports clean)"
	fi
}

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
