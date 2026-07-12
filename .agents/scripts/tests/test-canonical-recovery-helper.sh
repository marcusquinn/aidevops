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
REMOTE="${ROOT}/remote.git"
UPDATER="${ROOT}/updater"
OCCUPIED="${ROOT}/main-worktree"
mkdir -p "$HOME" "$REPO"
/usr/bin/git init -q --bare "$REMOTE"
/usr/bin/git -C "$REPO" init -q -b main
/usr/bin/git -C "$REPO" config user.name Test
/usr/bin/git -C "$REPO" config user.email test@example.invalid
/usr/bin/git -C "$REPO" config commit.gpgsign false
printf 'seed\n' >"${REPO}/README.md"
/usr/bin/git -C "$REPO" add README.md
/usr/bin/git -C "$REPO" commit -q -m seed
/usr/bin/git -C "$REPO" remote add origin "$REMOTE"
/usr/bin/git -C "$REPO" push -q -u origin main
/usr/bin/git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
/usr/bin/git -C "$REPO" remote set-head origin main
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

/usr/bin/git -C "$REPO" switch -q safety/test
/usr/bin/git clone -q "$REMOTE" "$UPDATER"
/usr/bin/git -C "$UPDATER" config user.name Test
/usr/bin/git -C "$UPDATER" config user.email test@example.invalid
printf 'remote ahead\n' >>"${UPDATER}/README.md"
/usr/bin/git -C "$UPDATER" commit -q -am 'remote ahead'
/usr/bin/git -C "$UPDATER" push -q origin main
remote_tip=$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/main)
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" restore-default --repo "$REPO" --issue 27014 --confirm RESTORE_CANONICAL_DEFAULT >/dev/null &&
	[[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "main" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$remote_tip" ]]; then
	printf 'PASS audited recovery fast-forwards to exact origin default tip\n'
else
	printf 'FAIL audited recovery did not reach exact origin default tip\n'
	exit 1
fi

/usr/bin/git -C "$REPO" switch -q safety/test
/usr/bin/git -C "$REPO" worktree add -q "$OCCUPIED" main
printf 'local divergence\n' >>"${OCCUPIED}/README.md"
/usr/bin/git -C "$OCCUPIED" commit -q -am 'local divergence'
/usr/bin/git -C "$REPO" worktree remove "$OCCUPIED"
local_tip=$(/usr/bin/git -C "$REPO" rev-parse main)
printf 'remote divergence\n' >>"${UPDATER}/README.md"
/usr/bin/git -C "$UPDATER" commit -q -am 'remote divergence'
/usr/bin/git -C "$UPDATER" push -q origin main
preservation_ref="refs/aidevops/canonical-recovery/issue-27014/${local_tip}"
remote_tip=$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/main)
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" restore-default --repo "$REPO" --issue 27014 --confirm RESTORE_CANONICAL_DEFAULT >/dev/null &&
	[[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "main" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse main)" == "$remote_tip" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse "$preservation_ref")" == "$local_tip" ]] &&
	/usr/bin/git -C "$REPO" merge-base --is-ancestor "$local_tip" "$preservation_ref"; then
	printf 'PASS recovery preserves divergent tip and restores exact origin default\n'
else
	printf 'FAIL divergent recovery did not preserve local tip or restore origin\n'
	exit 1
fi
