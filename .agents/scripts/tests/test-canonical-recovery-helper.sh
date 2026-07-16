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

/usr/bin/git -C "$REPO" switch -q -c develop
/usr/bin/git -C "$REPO" push -q -u origin develop
/usr/bin/git -C "$UPDATER" fetch -q origin develop
/usr/bin/git -C "$UPDATER" switch -q -c develop origin/develop
printf 'remote develop ahead\n' >>"${UPDATER}/README.md"
/usr/bin/git -C "$UPDATER" commit -q -am 'remote develop ahead'
/usr/bin/git -C "$UPDATER" push -q origin develop
develop_remote_tip=$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/develop)
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null &&
	[[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "develop" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$develop_remote_tip" ]] &&
	grep -q 'Canonical current-branch fast-forward authorized' "$HOME/.aidevops/logs/canonical-recovery-audit.jsonl"; then
	printf 'PASS audited fast-forward updates the current non-default branch without switching\n'
else
	printf 'FAIL audited fast-forward did not update the current non-default branch\n'
	exit 1
fi

develop_local_tip=$(/usr/bin/git -C "$REPO" rev-parse HEAD)
mkdir "${REPO}/.git/aidevops-canonical-recovery.lock"
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward ignored concurrent recovery lock\n'
	exit 1
fi
rmdir "${REPO}/.git/aidevops-canonical-recovery.lock"
if [[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$develop_local_tip" ]]; then
	printf 'PASS current-branch fast-forward refuses concurrent recovery\n'
else
	printf 'FAIL concurrent recovery refusal changed canonical state\n'
	exit 1
fi

printf 'remote develop race window\n' >>"${UPDATER}/README.md"
/usr/bin/git -C "$UPDATER" commit -q -am 'remote develop race window'
/usr/bin/git -C "$UPDATER" push -q origin develop
develop_remote_tip=$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/develop)
/usr/bin/git -C "$REPO" branch race-window "$develop_local_tip"
race_hook="${ROOT}/switch-canonical-branch.sh"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	"repo_path=\"\${1:-}\"" \
	"/usr/bin/git -C \"\$repo_path\" switch -q race-window" >"$race_hook"
chmod +x "$race_hook"
if AIDEVOPS_CANONICAL_BEFORE_REF_UPDATE_HOOK="$race_hook" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward ignored a concurrent branch switch\n'
	exit 1
elif [[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "race-window" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse develop)" == "$develop_local_tip" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse race-window)" == "$develop_local_tip" ]] &&
	[[ "$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/develop)" == "$develop_remote_tip" ]]; then
	printf 'PASS compare-and-swap refuses a concurrent branch switch without advancing either local branch\n'
else
	printf 'FAIL concurrent branch switch advanced or rewrote a local branch\n'
	exit 1
fi
/usr/bin/git -C "$REPO" switch -q develop
/usr/bin/git -C "$REPO" branch -d race-window >/dev/null
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$develop_remote_tip" ]]; then
	printf 'PASS audited fast-forward succeeds after a refused concurrent branch switch\n'
else
	printf 'FAIL audited fast-forward did not recover after the refused concurrent branch switch\n'
	exit 1
fi

develop_local_tip=$(/usr/bin/git -C "$REPO" rev-parse HEAD)
printf 'remote develop post-CAS race window\n' >>"${UPDATER}/README.md"
/usr/bin/git -C "$UPDATER" commit -q -am 'remote develop post-CAS race window'
/usr/bin/git -C "$UPDATER" push -q origin develop
develop_remote_tip=$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/develop)
/usr/bin/git -C "$REPO" branch race-window "$develop_local_tip"
if AIDEVOPS_CANONICAL_BEFORE_WORKTREE_UPDATE_HOOK="$race_hook" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward ignored a post-CAS branch switch\n'
	exit 1
elif [[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "race-window" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse develop)" == "$develop_local_tip" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse race-window)" == "$develop_local_tip" ]] &&
	[[ -z "$(/usr/bin/git -C "$REPO" status --porcelain)" ]] &&
	[[ "$(/usr/bin/git -C "$REMOTE" rev-parse refs/heads/develop)" == "$develop_remote_tip" ]]; then
	printf 'PASS post-CAS branch switch restores both the named ref and concurrent branch worktree\n'
else
	printf 'FAIL post-CAS branch switch left a local ref or worktree inconsistent\n'
	exit 1
fi
/usr/bin/git -C "$REPO" switch -q develop
/usr/bin/git -C "$REPO" branch -d race-window >/dev/null
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$develop_remote_tip" ]]; then
	printf 'PASS audited fast-forward succeeds after restoring a post-CAS branch switch\n'
else
	printf 'FAIL audited fast-forward did not recover after restoring a post-CAS branch switch\n'
	exit 1
fi

develop_local_tip=$(/usr/bin/git -C "$REPO" rev-parse HEAD)
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch main --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward ignored the expected branch mismatch\n'
	exit 1
elif [[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "develop" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$develop_local_tip" ]]; then
	printf 'PASS current-branch fast-forward refuses an expected branch mismatch\n'
else
	printf 'FAIL expected branch mismatch changed canonical state\n'
	exit 1
fi

printf 'dirty\n' >"${REPO}/DIRTY.md"
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward accepted a dirty canonical worktree\n'
	exit 1
fi
rm "${REPO}/DIRTY.md"
printf 'PASS current-branch fast-forward refuses a dirty canonical worktree\n'

/usr/bin/git -C "$REPO" switch -q --detach
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward accepted a detached canonical worktree\n'
	exit 1
fi
/usr/bin/git -C "$REPO" switch -q develop
printf 'PASS current-branch fast-forward refuses a detached canonical worktree\n'

printf 'local develop divergence\n' >>"${REPO}/README.md"
/usr/bin/git -C "$REPO" commit -q -am 'local develop divergence'
develop_local_tip=$(/usr/bin/git -C "$REPO" rev-parse HEAD)
printf 'remote develop divergence\n' >>"${UPDATER}/README.md"
/usr/bin/git -C "$UPDATER" commit -q -am 'remote develop divergence'
/usr/bin/git -C "$UPDATER" push -q origin develop
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --issue 28032 --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null 2>&1; then
	printf 'FAIL current-branch fast-forward accepted divergence\n'
	exit 1
elif [[ "$(/usr/bin/git -C "$REPO" branch --show-current)" == "develop" ]] &&
	[[ "$(/usr/bin/git -C "$REPO" rev-parse HEAD)" == "$develop_local_tip" ]]; then
	printf 'PASS current-branch fast-forward refuses divergence without changing refs\n'
else
	printf 'FAIL divergence refusal changed current branch or local tip\n'
	exit 1
fi
/usr/bin/git -C "$UPDATER" switch -q main

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
