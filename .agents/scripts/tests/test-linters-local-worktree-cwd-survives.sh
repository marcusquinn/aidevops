#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#22154 regression guard.
#
# Running linter/preflight gates from a linked worktree must not allow cleanup
# to remove the caller's current worktree. This recreates the unsafe shape: a
# clean linked worktree on a branch that is already merged into main, old enough
# to pass the grace-period check, with cleanup invoked from inside that worktree.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TEST_ROOT=$(mktemp -d)
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
	local message="$1"
	printf '%sFAIL%s %s\n' "$TEST_RED" "$TEST_RESET" "$message"
	exit 1
	return 1
}

pass() {
	local message="$1"
	printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$message"
	return 0
}

FAKE_REPO="${TEST_ROOT}/repo"
FAKE_WT="${TEST_ROOT}/linked-worktree"
mkdir -p "$FAKE_REPO"

git -C "$FAKE_REPO" init -q -b main || fail "init fake repo"
printf '#!/usr/bin/env bash\nprintf '\''ok\\n'\''\n' >"${FAKE_REPO}/ok.sh"
git -C "$FAKE_REPO" add ok.sh || fail "stage fake script"
git -C "$FAKE_REPO" -c user.email=t@t -c user.name=t commit -q -m init || fail "commit fake repo"

git -C "$FAKE_REPO" worktree add -q -b feature/gh22154-current "$FAKE_WT" main || fail "create linked worktree"

# Make the worktree old enough that the normal grace-period guard would not be
# the reason cleanup skips it. The current-worktree guard must be the protection.
touch -t 202001010000 "$FAKE_WT" || fail "age linked worktree"

cd "$FAKE_WT" || fail "enter linked worktree"

# Exercise the relevant shell-portability gate path from the linked worktree.
bash "${TEST_SCRIPTS_DIR}/lint-shell-portability.sh" --summary --no-exit-code >/dev/null || fail "run portability gate"

WORKTREE_CLEAN_GRACE_HOURS=1 AIDEVOPS_NO_NETWORK=1 bash "${TEST_SCRIPTS_DIR}/worktree-helper.sh" clean --auto >/dev/null 2>&1 || fail "run cleanup from linked worktree"

pwd >/dev/null 2>&1 || fail "current working directory still resolves"
[[ -e "$FAKE_WT" ]] || fail "linked worktree directory still exists"

if ! git -C "$FAKE_REPO" worktree list --porcelain | grep -Fxq "worktree $FAKE_WT"; then
	fail "linked worktree remains registered"
fi

pass "linked-worktree linter path preserves caller cwd"
exit 0
