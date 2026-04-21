#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-helper-nested-path-guard.sh — t2701 regression guard.
#
# `worktree-helper.sh add <branch> [path]` took a FILESYSTEM PATH as its
# second positional arg, while git's own `git worktree add -b <branch>
# <path> [<base>]` takes a base branch. Users who passed a base branch
# (e.g. `main`) to our helper silently created a worktree nested inside
# the canonical repo working tree ($CWD/main/), causing git-state
# confusion, pull/merge blast radius, and cleanup-script hazards.
#
# The fix (t2701) added `_cmd_add_assert_path_outside_repo` which refuses
# to create a worktree at a path that resolves inside the repo working
# tree, with a mentoring error that points users at the correct usage.
# An env override `AIDEVOPS_WORKTREE_ALLOW_NESTED=1` bypasses the guard
# for rare legitimate cases.
#
# Assertions:
#   Unit: _worktree_resolve_abs_path
#     1. Relative path resolves to CWD-relative absolute
#     2. Absolute path passes through
#     3. "." resolves to CWD
#     4. Non-existent parent falls back to naive join
#
#   Unit: _cmd_add_assert_path_outside_repo
#     5. Path === repo root is rejected (nested/shadow)
#     6. Path inside repo working tree is rejected
#     7. Sibling path outside repo is allowed
#     8. AIDEVOPS_WORKTREE_ALLOW_NESTED=1 bypasses guard even on nested
#     9. When not in a repo (get_repo_root empty), guard defers (returns 0)
#
#   Integration (end-to-end CLI):
#     10. `add feature/X main` aborts non-zero, does NOT create $CWD/main/
#     11. `add feature/X .` aborts non-zero
#     12. `AIDEVOPS_WORKTREE_ALLOW_NESTED=1 add feature/X some-nested-path`
#         is NOT blocked by the guard (may still fail later for unrelated
#         reasons like a missing base ref — we only assert the guard
#         doesn't emit its mentoring error)

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
	return 0
}

# =============================================================================
# Sandbox setup
# =============================================================================
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

# Fake repo with one commit so HEAD exists.
FAKE_REPO="${TEST_ROOT}/repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init -q -b main
git -C "$FAKE_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# =============================================================================
# Unit tests — source just the three functions we need, avoiding side
# effects of sourcing the whole helper.
# =============================================================================

# Colors may already be set by the caller's shell; guard them.
: "${RED:=$'\033[0;31m'}"
: "${NC:=$'\033[0m'}"

# Extract `get_repo_root`, `_worktree_resolve_abs_path`, and
# `_cmd_add_assert_path_outside_repo` from worktree-helper.sh.
HELPER_SRC="${TEST_SCRIPTS_DIR}/worktree-helper.sh"
eval "$(sed -n '/^get_repo_root()/,/^}/p' "$HELPER_SRC")"
eval "$(sed -n '/^_worktree_resolve_abs_path()/,/^}/p' "$HELPER_SRC")"
eval "$(sed -n '/^_cmd_add_assert_path_outside_repo()/,/^}/p' "$HELPER_SRC")"

# ---- _worktree_resolve_abs_path ---------------------------------------------
# Test 1: relative path resolves to CWD-absolute
rc=0
cd "$FAKE_REPO"
got="$(_worktree_resolve_abs_path "foo")"
expected_parent="$(cd "$FAKE_REPO" && pwd -P)"
expected="${expected_parent}/foo"
[[ "$got" == "$expected" ]] || rc=1
print_result "resolve_abs_path: relative path resolves to CWD-absolute" "$rc" "(got: '$got', expected: '$expected')"

# Test 2: absolute path passes through (when parent exists)
rc=0
got="$(_worktree_resolve_abs_path "$FAKE_REPO/bar")"
[[ "$got" == "${expected_parent}/bar" ]] || rc=1
print_result "resolve_abs_path: absolute path passes through" "$rc" "(got: '$got')"

# Test 3: "." resolves to CWD
rc=0
got="$(_worktree_resolve_abs_path ".")"
[[ "$got" == "$expected_parent" ]] || rc=1
print_result "resolve_abs_path: '.' resolves to CWD" "$rc" "(got: '$got', expected: '$expected_parent')"

# Test 4: non-existent parent falls back to naive join (best effort)
rc=0
got="$(_worktree_resolve_abs_path "/nonexistent/deep/path/leaf")"
[[ "$got" == "/nonexistent/deep/path/leaf" ]] || rc=1
print_result "resolve_abs_path: non-existent parent naive-joins" "$rc" "(got: '$got')"

# ---- _cmd_add_assert_path_outside_repo --------------------------------------
cd "$FAKE_REPO"

# Test 5: Path === repo root is rejected
unset AIDEVOPS_WORKTREE_ALLOW_NESTED
rc=0
if _cmd_add_assert_path_outside_repo "$FAKE_REPO" "feature/x" 2>/dev/null; then
	rc=1
fi
print_result "assert: path === repo root is rejected" "$rc"

# Test 6: Path inside repo working tree is rejected (the `main` footgun)
rc=0
if _cmd_add_assert_path_outside_repo "main" "feature/x" 2>/dev/null; then
	rc=1
fi
print_result "assert: 'main' (relative, nested) is rejected" "$rc"

# Test 6b: "." is rejected
rc=0
if _cmd_add_assert_path_outside_repo "." "feature/x" 2>/dev/null; then
	rc=1
fi
print_result "assert: '.' (CWD === repo root) is rejected" "$rc"

# Test 7: Sibling path outside the repo is allowed
rc=0
if ! _cmd_add_assert_path_outside_repo "${TEST_ROOT}/sibling-worktree" "feature/x" 2>/dev/null; then
	rc=1
fi
print_result "assert: sibling path outside repo is allowed" "$rc"

# Test 8: AIDEVOPS_WORKTREE_ALLOW_NESTED=1 bypasses guard on nested path
rc=0
if ! AIDEVOPS_WORKTREE_ALLOW_NESTED=1 _cmd_add_assert_path_outside_repo "main" "feature/x" 2>/dev/null; then
	rc=1
fi
print_result "assert: AIDEVOPS_WORKTREE_ALLOW_NESTED=1 bypasses guard" "$rc"
unset AIDEVOPS_WORKTREE_ALLOW_NESTED

# Test 9: When not in a repo (get_repo_root empty), guard defers
rc=0
cd "$TEST_ROOT"  # not inside a git repo
if ! _cmd_add_assert_path_outside_repo "anywhere" "feature/x" 2>/dev/null; then
	rc=1
fi
print_result "assert: defers when not in a repo" "$rc"

# =============================================================================
# Integration — invoke the actual helper CLI end-to-end
# =============================================================================
cd "$FAKE_REPO"
export AIDEVOPS_SKIP_AUTO_CLAIM=1      # skip interactive-session-helper side effects
export AIDEVOPS_NO_NETWORK=1            # defensive: some helpers honour this

# Test 10: `add feature/x main` aborts non-zero, leaves no nested worktree
rc=0
set +e
bash "$HELPER_SRC" add feature/t2701-testbranch main >/dev/null 2>&1
exit_code=$?
set -e
[[ "$exit_code" -ne 0 ]] || rc=1
[[ ! -e "${FAKE_REPO}/main" ]] || rc=1
print_result "cli: 'add feature/x main' aborts, no nested dir created" "$rc" "(exit=$exit_code, main_exists=$([[ -e "${FAKE_REPO}/main" ]] && echo yes || echo no))"

# Test 11: `add feature/x .` aborts non-zero
rc=0
set +e
bash "$HELPER_SRC" add feature/t2701-testbranch2 . >/dev/null 2>&1
exit_code=$?
set -e
[[ "$exit_code" -ne 0 ]] || rc=1
print_result "cli: 'add feature/x .' aborts" "$rc" "(exit=$exit_code)"

# Test 12: Bypass env var lets the guard pass (downstream may still fail for
# unrelated reasons like create-branch mechanics, but the t2701 mentoring
# error must NOT appear in stderr).
rc=0
set +e
stderr_out="$(AIDEVOPS_WORKTREE_ALLOW_NESTED=1 bash "$HELPER_SRC" add feature/t2701-testbranch3 nested-ok 2>&1 >/dev/null)"
set -e
# The mentoring error contains the word 'AIDEVOPS_WORKTREE_ALLOW_NESTED' only
# when the guard fires. If the guard was bypassed, that string must NOT appear.
case "$stderr_out" in
	*"AIDEVOPS_WORKTREE_ALLOW_NESTED=1 — use only"*) rc=1 ;;
esac
print_result "cli: AIDEVOPS_WORKTREE_ALLOW_NESTED=1 bypasses guard" "$rc"

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
