#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
GUARD="${SCRIPT_DIR}/canonical-git-command-guard.py"
SHIM="${SCRIPT_DIR}/git"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
REPO="${TEST_ROOT}/repo"
LINKED="${TEST_ROOT}/linked"
TESTS=0
FAILURES=0

# Fixture setup must bypass the guard under test; policy assertions invoke the
# shim explicitly below.
git() { /usr/bin/git "$@"; return $?; }

pass() { TESTS=$((TESTS + 1)); printf 'PASS %s\n' "$1"; return 0; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); printf 'FAIL %s\n' "$1"; return 0; }

mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config commit.gpgsign false
printf 'seed\n' >"${REPO}/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m seed
INITIAL_HEAD=$(git -C "$REPO" rev-parse HEAD)

assert_blocked() {
	local name="$1"
	local command="$2"
	local output=""
	output=$(python3 "$GUARD" --cwd "$REPO" --command "$command" 2>&1)
	local rc=$?
	if [[ "$rc" -eq 42 && "$output" == *"BLOCKED by canonical Git guard"* ]]; then
		pass "$name"
	else
		fail "$name (rc=$rc output=$output)"
	fi
	return 0
}

assert_allowed() {
	local name="$1"
	local cwd="$2"
	local command="$3"
	if python3 "$GUARD" --cwd "$cwd" --command "$command" >/dev/null 2>&1; then
		pass "$name"
	else
		fail "$name"
	fi
	return 0
}

assert_blocked "blocks canonical detached switch" "git switch --detach main"
assert_blocked "blocks canonical branch rename" "git branch -m main safety/example"
assert_blocked "blocks canonical branch creation with reflog flag" "git branch -l feature/new"
assert_blocked "blocks canonical non-default switch" "git switch safety/example"
assert_blocked "blocks git -C canonical reset" "git -C '$REPO' reset --hard HEAD"
assert_blocked "blocks relative git -C canonical reset" "cd '$TEST_ROOT' && git -C repo reset --hard HEAD"
# shellcheck disable=SC2016
assert_blocked "blocks variable-derived git -C target" '/usr/bin/git -C "$REPO" switch --detach main'
# shellcheck disable=SC2016
assert_blocked "blocks command-substitution git -C target" '/usr/bin/git -C "$(pwd)" branch -M renamed'
# shellcheck disable=SC2016
assert_blocked "blocks attached variable git-dir target" '/usr/bin/git --git-dir="$REPO/.git" --work-tree="$REPO" switch --detach main'
# shellcheck disable=SC2016
assert_blocked "blocks environment variable Git target" 'env GIT_DIR="$REPO/.git" GIT_WORK_TREE="$REPO" /usr/bin/git switch --detach main'
assert_blocked "blocks literal environment Git target" "env GIT_DIR='$REPO/.git' GIT_WORK_TREE='$REPO' /usr/bin/git switch --detach main"
# shellcheck disable=SC2016
assert_blocked "blocks quoted environment assignment name" 'env '\''GIT_DIR='\''"$REPO/.git" '\''GIT_WORK_TREE='\''"$REPO" /usr/bin/git switch --detach main'
assert_blocked "blocks tilde git -C target" '/usr/bin/git -C ~/repo switch --detach main'
assert_blocked "blocks wrapped canonical switch" "env TEST=1 command git switch feature/example"
assert_blocked "blocks nested absolute Git bypass" "bash -c '/usr/bin/git switch --detach main'"
assert_blocked "blocks chained canonical mutation" "git status && git branch -M renamed"
assert_blocked "blocks canonical update-ref plumbing" "/usr/bin/git update-ref refs/heads/main HEAD"
assert_blocked "blocks destructive clean with exclude containing n" "git clean --force --exclude=nope"
assert_blocked "blocks interactive clean" "git clean --interactive"

if [[ "$(git -C "$REPO" symbolic-ref --short HEAD)" == "main" ]] &&
	[[ "$(git -C "$REPO" rev-parse HEAD)" == "$INITIAL_HEAD" ]] &&
	! git -C "$REPO" show-ref --verify --quiet refs/heads/safety/example; then
	pass "blocked sequence leaves canonical refs unchanged"
else
	fail "blocked sequence leaves canonical refs unchanged"
fi

assert_allowed "allows canonical status" "$REPO" "git status --short"
assert_allowed "allows canonical branch listing" "$REPO" "git branch -vv --no-abbrev"
assert_allowed "allows canonical branch pattern listing" "$REPO" "git branch --list 'feature/*'"
assert_allowed "allows canonical branch containment query" "$REPO" "git branch --contains main"
assert_allowed "allows canonical worktree creation" "$REPO" "git worktree add '$LINKED' -b feature/example"
git -C "$REPO" worktree add -q -b feature/example "$LINKED"
assert_allowed "allows normal Git mutation in linked worktree" "$LINKED" "git switch -c feature/linked-child"

if (cd "$REPO" && PATH="${SCRIPT_DIR}:$PATH" "$SHIM" switch --detach main >/dev/null 2>&1); then
	fail "PATH shim blocks canonical detached switch"
else
	[[ "$(git -C "$REPO" branch --show-current)" == "main" ]] && pass "PATH shim blocks canonical detached switch before execution" || fail "PATH shim changed canonical HEAD"
fi
if (cd "$LINKED" && PATH="${SCRIPT_DIR}:$PATH" "$SHIM" switch -q -c feature/linked-child); then
	pass "PATH shim allows linked-worktree branch mutation"
else
	fail "PATH shim allows linked-worktree branch mutation"
fi

SHIM_BIN="${TEST_ROOT}/bin"
mkdir -p "$SHIM_BIN"
ln -s "$SHIM" "${SHIM_BIN}/git"
if (cd "$REPO" && env PATH="${SHIM_BIN}:/usr/bin:/bin" git status --short >/dev/null); then
	pass "deployed symlink shim resolves policy engine"
else
	fail "deployed symlink shim resolves policy engine"
fi
if (cd "$REPO" && env PATH="${SHIM_BIN}:/usr/bin:/bin" git switch --detach main >/dev/null 2>&1); then
	fail "deployed symlink shim blocks canonical mutation"
else
	[[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "main" ]] && pass "deployed symlink shim blocks canonical mutation" || fail "symlink shim changed canonical HEAD"
fi

RUNTIME_A="${TEST_ROOT}/runtime-a/agents/scripts"
RUNTIME_B="${TEST_ROOT}/runtime-b/agents/scripts"
mkdir -p "$RUNTIME_A" "$RUNTIME_B"
ln -s "$SHIM" "${RUNTIME_A}/git"
ln -s "$SHIM" "${RUNTIME_B}/git"
if (cd "$REPO" && env PATH="${RUNTIME_A}:${RUNTIME_B}:/usr/bin:/bin" "${RUNTIME_A}/git" status --short >/dev/null); then
	pass "runtime bundle shim skips other runtime bundle wrappers"
else
	fail "runtime bundle shim skips other runtime bundle wrappers"
fi

LITERAL_REPO="${TEST_ROOT}/repo[1]"
mkdir -p "$LITERAL_REPO"
/usr/bin/git -C "$LITERAL_REPO" init -q -b main
if (cd "$LITERAL_REPO" && env PATH="${SHIM_BIN}:/usr/bin:/bin" git status --short >/dev/null); then
	pass "shim accepts already-expanded literal metacharacter path"
else
	fail "shim accepts already-expanded literal metacharacter path"
fi

printf '\nTests: %d, Failures: %d\n' "$TESTS" "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
