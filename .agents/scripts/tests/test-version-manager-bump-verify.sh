#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-version-manager-bump-verify.sh — t2437/GH#20073 regression guard.
#
# Asserts that version-manager.sh refuses to create a release tag on a
# non-bump commit. The failure history that motivated this test:
#
#   - PR #20066 (t2427) merged 2026-04-20T02:22:21Z.
#   - `version-manager.sh release patch` ran moments later; pulse claim
#     commits were pushed in between, triggering a rebase-and-retag
#     inside push_changes.
#   - The rebase silently dropped the bump commit (HEAD became
#     origin/main = a pulse claim commit), and the retag placed the
#     v3.8.82 tag on that claim commit.
#   - VERSION and CHANGELOG never received the 3.8.82 bump entry on
#     main; tag and GitHub release pointed at the wrong commit.
#
# The fix adds `_verify_bump_commit_at_ref` and wires it in at three
# gates: after commit_version_changes, after the rebase inside
# push_changes, and as a final guard inside create_git_tag. This test
# exercises the helper directly (no git network ops, no fixture
# release) so it runs fast and deterministically in CI.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# NOT readonly — version-manager.sh defines its own RED/GREEN constants
# under `readonly`, and a collision under set -e silently kills the
# test shell. Use plain vars (same pattern as test-parent-task-guard.sh).
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

# Sandbox HOME and working dir
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

# Build a tiny git repo with two commits: a legitimate bump commit for
# 9.9.1 and a sibling non-bump commit (simulating the pulse claim
# commit that the rebase would have dropped our bump commit onto).
REPO_DIR="${TEST_ROOT}/repo"
mkdir -p "$REPO_DIR"
cd "$REPO_DIR" || exit 1

git init -q -b main
git config user.email 'test@example.com'
git config user.name 'Test Runner'
git config commit.gpgsign false

echo 'initial' >README.md
git add README.md
git commit -q -m 'initial commit'

# Bump commit (legitimate)
echo '9.9.1' >VERSION
git add VERSION
git commit -q -m 'chore(release): bump version to 9.9.1'
BUMP_SHA=$(git rev-parse HEAD)

# Non-bump commit on top (simulates the pulse claim commit scenario)
echo 'unrelated' >other.txt
git add other.txt
git commit -q -m 'chore: claim t9999 [test-fixture]'
CLAIM_SHA=$(git rev-parse HEAD)

# Source version-manager.sh in library mode. The file ends with a
# `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi` guard, so
# sourcing it directly as a file (NOT via <(...) process substitution)
# skips the main-dispatch path.
#
# Why direct `source <path>` instead of `source <(cat <path>)`:
# version-manager.sh line 14 computes `SCRIPT_DIR` from `BASH_SOURCE[0]`
# and then sources shared-constants.sh relative to it. Under process
# substitution BASH_SOURCE[0] resolves to `/dev/fd/N`, which breaks the
# dirname+cd chain and takes down the test with it. Plain file sourcing
# gives BASH_SOURCE[0] the real path and everything initialises normally
# (t2437: documented here because future maintainers WILL try to "clean
# up" by switching to process substitution).
#
# version-manager.sh has `set -euo pipefail` at the top, which propagates
# to the outer shell on source. We turn -e back off immediately so the
# `|| rc=$?` rc-capture pattern below works as expected.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/version-manager.sh"
set +e

# =============================================================================
# Test 1: _bump_commit_subject produces the canonical subject
# =============================================================================
expected_subj='chore(release): bump version to 9.9.1'
actual_subj=$(_bump_commit_subject '9.9.1')
if [[ "$actual_subj" == "$expected_subj" ]]; then
	print_result '_bump_commit_subject: canonical format for 9.9.1' 0
else
	print_result '_bump_commit_subject: canonical format for 9.9.1' 1 \
		"expected [$expected_subj], got [$actual_subj]"
fi

# =============================================================================
# Test 2: verification PASSES on the legitimate bump commit
# =============================================================================
rc=0
_verify_bump_commit_at_ref "$BUMP_SHA" '9.9.1' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result '_verify_bump_commit_at_ref: passes for legitimate bump commit' 0
else
	print_result '_verify_bump_commit_at_ref: passes for legitimate bump commit' 1 \
		"expected rc=0, got rc=$rc"
fi

# =============================================================================
# Test 3: verification FAILS on a non-bump commit (GH#20073 symptom)
# =============================================================================
# This is the core regression: the rebase scenario that broke v3.8.82
# left HEAD at a claim commit and retagged it. Under the fix, the
# verifier must reject this.
rc=0
_verify_bump_commit_at_ref "$CLAIM_SHA" '9.9.1' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result '_verify_bump_commit_at_ref: rejects non-bump commit (GH#20073 case)' 0
else
	print_result '_verify_bump_commit_at_ref: rejects non-bump commit (GH#20073 case)' 1 \
		"expected non-zero rc, got rc=0"
fi

# =============================================================================
# Test 4: verification FAILS on version mismatch (right shape, wrong version)
# =============================================================================
# A bump commit exists but for a different version — the subject is
# structurally valid but does not match $version. Must still reject.
rc=0
_verify_bump_commit_at_ref "$BUMP_SHA" '9.9.2' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result '_verify_bump_commit_at_ref: rejects version mismatch' 0
else
	print_result '_verify_bump_commit_at_ref: rejects version mismatch' 1 \
		"expected non-zero rc, got rc=0"
fi

# =============================================================================
# Test 5: verification FAILS on an invalid ref
# =============================================================================
rc=0
_verify_bump_commit_at_ref 'does-not-exist' '9.9.1' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result '_verify_bump_commit_at_ref: rejects non-existent ref' 0
else
	print_result '_verify_bump_commit_at_ref: rejects non-existent ref' 1 \
		"expected non-zero rc, got rc=0"
fi

# =============================================================================
# Test 6: VERSION_MANAGER_NO_CHANGES_EXIT is distinct from success
# =============================================================================
# The t2437 fix widens commit_version_changes' contract: 0 = commit
# made, 1 = commit failed, 2 = nothing staged. Callers must treat 2
# as fatal for a release run (see _release_execute).
if [[ "${VERSION_MANAGER_NO_CHANGES_EXIT:-0}" == "2" ]]; then
	print_result 'VERSION_MANAGER_NO_CHANGES_EXIT: defined as 2 (distinct from success)' 0
else
	print_result 'VERSION_MANAGER_NO_CHANGES_EXIT: defined as 2 (distinct from success)' 1 \
		"expected 2, got [${VERSION_MANAGER_NO_CHANGES_EXIT:-<unset>}]"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
printf 'Tests run:    %d\n' "$TESTS_RUN"
printf 'Tests failed: %d\n' "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
