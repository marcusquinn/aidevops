#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HOOK="${SCRIPT_DIR}/../hooks/canonical-on-main-guard.sh"
INSTALLER="${SCRIPT_DIR}/install-canonical-guard.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
REPO="${ROOT}/repo"
LINKED="${ROOT}/linked"
TESTS=0
FAILURES=0

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
git -C "$REPO" remote add origin "$REPO"
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

if (cd "$REPO" && bash "$HOOK" HEAD HEAD 1 >/dev/null 2>&1); then
	pass "canonical default branch satisfies invariant"
else
	fail "canonical default branch satisfies invariant"
fi

git -C "$REPO" switch -q -c feature/test
if (cd "$REPO" && bash "$HOOK" HEAD HEAD 1 >/dev/null 2>&1); then
	fail "canonical off-default branch is detected"
else
	[[ "$(git -C "$REPO" branch --show-current)" == "feature/test" ]] && pass "canonical off-default branch is detected without repair" || fail "canonical detector mutated branch"
fi

git -C "$REPO" switch -q --detach main
if (cd "$REPO" && bash "$HOOK" HEAD HEAD 1 >/dev/null 2>&1); then
	fail "canonical detached HEAD is detected"
else
	[[ -z "$(git -C "$REPO" branch --show-current)" ]] && pass "canonical detached HEAD is detected without repair" || fail "detached detector mutated HEAD"
fi

git -C "$REPO" switch -q main
git -C "$REPO" worktree add -q -b feature/linked "$LINKED"
if (cd "$LINKED" && bash "$HOOK" HEAD HEAD 1 >/dev/null 2>&1); then
	pass "linked worktree branch is allowed"
else
	fail "linked worktree branch is allowed"
fi

git -C "$REPO" config core.hooksPath .custom-hooks
if (cd "$REPO" && bash "$INSTALLER" install >/dev/null 2>&1) && [[ -x "${REPO}/.custom-hooks/post-checkout" ]]; then
	pass "installer uses effective core.hooksPath"
else
	fail "installer uses effective core.hooksPath"
fi
if [[ ! -e "${REPO}/.git/hooks/post-checkout" ]]; then
	pass "installer does not report inactive default hook path"
else
	fail "installer wrote inactive default hook path"
fi

printf '\nTests: %d, Failures: %d\n' "$TESTS" "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
