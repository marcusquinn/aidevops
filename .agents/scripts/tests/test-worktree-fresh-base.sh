#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../worktree-helper.sh"
REAL_GIT=$(command -v git)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

REMOTE="${ROOT}/remote.git"
CANONICAL="${ROOT}/canonical"
UPDATER="${ROOT}/updater"
WORKTREES="${ROOT}/worktrees"
HOME="${ROOT}/home"
export HOME AIDEVOPS_WORKTREE_BASE_DIR="$WORKTREES"

git init -q --bare "$REMOTE"
git clone -q "$REMOTE" "$CANONICAL"
git -C "$CANONICAL" switch -q -c main
git -C "$CANONICAL" config user.name Test
git -C "$CANONICAL" config user.email test@example.invalid
git -C "$CANONICAL" commit -q --allow-empty -m seed
git -C "$CANONICAL" push -q -u origin main
git -C "$CANONICAL" remote set-head origin main

git clone -q "$REMOTE" "$UPDATER"
git -C "$UPDATER" switch -q main
git -C "$UPDATER" config user.name Test
git -C "$UPDATER" config user.email test@example.invalid
printf 'remote tip\n' >"${UPDATER}/remote.txt"
git -C "$UPDATER" add remote.txt
git -C "$UPDATER" commit -q -m remote-tip
git -C "$UPDATER" push -q origin main
REMOTE_SHA=$(git -C "$UPDATER" rev-parse HEAD)

# Optional integration mode: prepend the repository Git shim after fixture
# setup so worktree creation exercises the canonical guard without blocking
# the fixture's intentional canonical branch/bootstrap mutations.
if [[ -n "${AIDEVOPS_TEST_GIT_SHIM:-}" ]]; then
	PATH="$(dirname "$AIDEVOPS_TEST_GIT_SHIM"):${PATH}"
	export PATH
fi

(cd "$CANONICAL" && "$HELPER" add test/fresh-base >/dev/null)
FRESH_PATH="${WORKTREES}/canonical-test-fresh-base"
[[ "$(git -C "$FRESH_PATH" rev-parse HEAD)" == "$REMOTE_SHA" ]] || {
	printf 'FAIL worktree did not start at freshly fetched origin/main\n'
	exit 1
}
printf 'PASS worktree starts at freshly fetched origin/main\n'
if compgen -G "${WORKTREES}/.canonical-fetch-*" >/dev/null; then
	printf 'FAIL temporary fetch worktree was not removed\n'
	exit 1
fi
printf 'PASS canonical-guard bootstrap fetch worktree is removed\n'

"$REAL_GIT" -C "$CANONICAL" remote set-url origin "${ROOT}/missing.git"
if (cd "$CANONICAL" && "$HELPER" add test/fetch-failure >/dev/null 2>&1); then
	printf 'FAIL worktree creation accepted an unrefreshable remote base\n'
	exit 1
fi
printf 'PASS worktree creation fails closed when origin/main cannot refresh\n'

PINNED_SHA=$(git -C "$CANONICAL" rev-parse main)
(cd "$CANONICAL" && "$HELPER" add test/pinned-base --base "$PINNED_SHA" >/dev/null)
PINNED_PATH="${WORKTREES}/canonical-test-pinned-base"
[[ "$(git -C "$PINNED_PATH" rev-parse HEAD)" == "$PINNED_SHA" ]] || {
	printf 'FAIL immutable explicit base was not preserved\n'
	exit 1
}
printf 'PASS immutable explicit base permits audited offline recovery\n'

exit 0
