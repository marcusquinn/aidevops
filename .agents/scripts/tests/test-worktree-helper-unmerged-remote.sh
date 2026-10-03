#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-helper-unmerged-remote.sh — GH#33194 regression guard.
#
# `worktree-helper.sh add <branch>` used to create a NEW local branch from
# origin/<default> even when `origin/<branch>` already existed and was
# unmerged (e.g. an open PR head), silently diverging from the remote and
# only printing a warning. The fix checks out the unmerged remote ref
# directly (`git worktree add -b <branch> <path> origin/<branch>`) with
# upstream tracking set to it, unless an explicit --base REF overrides this.
# A merged or absent remote branch keeps the prior origin/<default> base.
#
# Assertions:
#   1. Unmerged remote branch: worktree HEAD equals origin/<branch>, no
#      divergence (ahead/behind), and upstream tracks origin/<branch>.
#   2. Merged remote branch: worktree still bases on origin/<default>
#      (unchanged behaviour) — HEAD equals the default branch tip, not the
#      (now-merged, since-advanced) remote branch tip.
#   3. Absent remote branch: worktree bases on origin/<default> (unchanged).
#   4. Explicit --base REF overrides the unmerged-remote checkout.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

git() {
	"$GIT_BIN" "$@"
	return $?
}

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
	return 0
}

# =============================================================================
# Sandbox setup — a bare "origin" plus a clone that drives the CLI.
# =============================================================================
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

ORIGIN_BARE="${TEST_ROOT}/origin.git"
git init -q --bare -b main "$ORIGIN_BARE"

SEED="${TEST_ROOT}/seed"
git clone -q "$ORIGIN_BARE" "$SEED"
git -C "$SEED" config user.email t@t
git -C "$SEED" config user.name t
echo "init" >"${SEED}/README.md"
git -C "$SEED" add .
git -C "$SEED" commit -q -m init
git -C "$SEED" push -q origin main

# Unmerged branch "x": one commit not on main, pushed to origin.
git -C "$SEED" checkout -q -b x
echo "x-change" >"${SEED}/x.txt"
git -C "$SEED" add .
git -C "$SEED" commit -q -m "x change"
git -C "$SEED" push -q origin x
UNMERGED_REMOTE_SHA=$(git -C "$SEED" rev-parse origin/x)
git -C "$SEED" checkout -q main

# Merged branch "y": commit merged into main then branch left pushed (stale,
# merged). Advance origin/y afterwards so a wrongly-checked-out worktree
# would NOT match main's tip, proving the merged path still bases on main.
git -C "$SEED" checkout -q -b y
echo "y-change" >"${SEED}/y.txt"
git -C "$SEED" add .
git -C "$SEED" commit -q -m "y change"
git -C "$SEED" push -q origin y
git -C "$SEED" checkout -q main
git -C "$SEED" merge -q --no-ff -m "merge y" y
git -C "$SEED" push -q origin main
MAIN_TIP_SHA=$(git -C "$SEED" rev-parse origin/main)
git -C "$SEED" branch -D y

# Second unmerged branch "w": used only for the explicit --base override
# test so it is never touched by a prior plain `add` call (which would
# create a local branch and make the override path a no-op for this test).
git -C "$SEED" checkout -q -b w
echo "w-change" >"${SEED}/w.txt"
git -C "$SEED" add .
git -C "$SEED" commit -q -m "w change"
git -C "$SEED" push -q origin w
git -C "$SEED" checkout -q main
git -C "$SEED" branch -D w

# Local clone used to drive the CLI (separate from SEED so registration/
# ownership metadata from add doesn't interfere with fixture setup above).
WORK_REPO="${TEST_ROOT}/work"
git clone -q "$ORIGIN_BARE" "$WORK_REPO"
git -C "$WORK_REPO" config user.email t@t
git -C "$WORK_REPO" config user.name t

WORKTREE_BASE="${TEST_ROOT}/worktrees"
mkdir -p "$WORKTREE_BASE"
export AIDEVOPS_WORKTREE_BASE_DIR="$WORKTREE_BASE"
export AIDEVOPS_SKIP_AUTO_CLAIM=1
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

HELPER_CLI="${TEST_SCRIPTS_DIR}/worktree-helper.sh"

# =============================================================================
# Test 1: unmerged remote branch — worktree checks out origin/x directly
# =============================================================================
WT1="${WORKTREE_BASE}/wt-x"
rc=0
(cd "$WORK_REPO" && bash "$HELPER_CLI" add x "$WT1" </dev/null >/dev/null 2>&1) || rc=1
[[ "$rc" -eq 0 ]] || print_result "cli: add x (unmerged remote) succeeds" 1 "(exit=$rc)"
if [[ "$rc" -eq 0 ]]; then
	head_sha=$(git -C "$WT1" rev-parse HEAD 2>/dev/null || true)
	rc2=0
	[[ "$head_sha" == "$UNMERGED_REMOTE_SHA" ]] || rc2=1
	print_result "unmerged remote: worktree HEAD equals origin/x" "$rc2" "(got: $head_sha, expected: $UNMERGED_REMOTE_SHA)"

	statusb=$(git -C "$WT1" status -sb 2>/dev/null || true)
	rc3=0
	case "$statusb" in
	*"...origin/x"*) : ;;
	*) rc3=1 ;;
	esac
	case "$statusb" in
	*ahead* | *behind*) rc3=1 ;;
	esac
	print_result "unmerged remote: status -sb tracks origin/x with no divergence" "$rc3" "(got: '$statusb')"
fi

# =============================================================================
# Test 2: merged remote branch — still bases on origin/main (unchanged)
# =============================================================================
WT2="${WORKTREE_BASE}/wt-y"
rc=0
(cd "$WORK_REPO" && bash "$HELPER_CLI" add y "$WT2" </dev/null >/dev/null 2>&1) || rc=1
[[ "$rc" -eq 0 ]] || print_result "cli: add y (merged remote) succeeds" 1 "(exit=$rc)"
if [[ "$rc" -eq 0 ]]; then
	head_sha=$(git -C "$WT2" rev-parse HEAD 2>/dev/null || true)
	rc2=0
	[[ "$head_sha" == "$MAIN_TIP_SHA" ]] || rc2=1
	print_result "merged remote: worktree bases on origin/main (unchanged)" "$rc2" "(got: $head_sha, expected: $MAIN_TIP_SHA)"
fi

# =============================================================================
# Test 3: absent remote branch — bases on origin/main (unchanged)
# =============================================================================
WT3="${WORKTREE_BASE}/wt-z"
rc=0
(cd "$WORK_REPO" && bash "$HELPER_CLI" add feature/z-new "$WT3" </dev/null >/dev/null 2>&1) || rc=1
[[ "$rc" -eq 0 ]] || print_result "cli: add feature/z-new (absent remote) succeeds" 1 "(exit=$rc)"
if [[ "$rc" -eq 0 ]]; then
	head_sha=$(git -C "$WT3" rev-parse HEAD 2>/dev/null || true)
	rc2=0
	[[ "$head_sha" == "$MAIN_TIP_SHA" ]] || rc2=1
	print_result "absent remote: worktree bases on origin/main (unchanged)" "$rc2" "(got: $head_sha, expected: $MAIN_TIP_SHA)"
fi

# =============================================================================
# Test 4: explicit --base overrides the unmerged-remote checkout
# =============================================================================
WT4="${WORKTREE_BASE}/wt-w-based"
rc=0
(cd "$WORK_REPO" && bash "$HELPER_CLI" add w "$WT4" --base origin/main </dev/null >/dev/null 2>&1) || rc=1
[[ "$rc" -eq 0 ]] || print_result "cli: add w --base origin/main succeeds" 1 "(exit=$rc)"
if [[ "$rc" -eq 0 ]]; then
	head_sha=$(git -C "$WT4" rev-parse HEAD 2>/dev/null || true)
	rc2=0
	[[ "$head_sha" == "$MAIN_TIP_SHA" ]] || rc2=1
	print_result "explicit --base overrides unmerged-remote checkout" "$rc2" "(got: $head_sha, expected: $MAIN_TIP_SHA)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
