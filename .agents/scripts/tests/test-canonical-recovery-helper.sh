#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/canonical-recovery-helper.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export HOME="${ROOT}/home"
REPO="${ROOT}/repo"
OCCUPIED="${ROOT}/main-worktree"
mkdir -p "$HOME" "$REPO"
/usr/bin/git -C "$REPO" init -q -b main
/usr/bin/git -C "$REPO" config user.name Test
/usr/bin/git -C "$REPO" config user.email test@example.invalid
/usr/bin/git -C "$REPO" config commit.gpgsign false
printf 'seed\n' >"${REPO}/README.md"
/usr/bin/git -C "$REPO" add README.md
/usr/bin/git -C "$REPO" commit -q -m seed
/usr/bin/git -C "$REPO" remote add origin "$REPO"
/usr/bin/git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
/usr/bin/git -C "$REPO" switch -q -c safety/test
/usr/bin/git -C "$REPO" worktree add -q "$OCCUPIED" main

if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" restore-default --repo "$REPO" --issue 27014 --confirm RESTORE_CANONICAL_DEFAULT >/dev/null 2>&1; then
	printf 'FAIL recovery ignored occupied default branch\n'
	exit 1
fi
printf 'PASS recovery refuses occupied default branch\n'

/usr/bin/git -C "$REPO" worktree remove "$OCCUPIED"
printf 'invalid global audit chain\n' >"${ROOT}/broken-global-audit.jsonl"
if AUDIT_LOG_FILE="${ROOT}/broken-global-audit.jsonl" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" restore-default --repo "$REPO" --issue 27014 --confirm RESTORE_CANONICAL_DEFAULT >/dev/null &&
	[[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "main" ]] &&
	[[ -s "$HOME/.aidevops/logs/canonical-recovery-audit.jsonl" ]]; then
	printf 'PASS audited recovery restores only default branch\n'
else
	printf 'FAIL audited recovery did not restore default branch\n'
	exit 1
fi
