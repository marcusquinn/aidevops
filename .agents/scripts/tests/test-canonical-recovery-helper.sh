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
export AIDEVOPS_REPOS_CONFIG="${ROOT}/repos.json"
printf '{"initialized_repos":[{"path":"%s","pr_base_branch":"develop"}]}\n' "$REPO" >"$AIDEVOPS_REPOS_CONFIG"
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

if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" fast-forward-current --repo "$REPO" --branch develop --reason aidevops-update --confirm FAST_FORWARD_CANONICAL_BRANCH >/dev/null &&
	grep -q '"reason":"aidevops-update"' "$HOME/.aidevops/logs/canonical-recovery-audit.jsonl"; then
	printf 'PASS routine update fast-forward records an audited reason without an invented issue number\n'
else
	printf 'FAIL routine update fast-forward did not record its maintenance reason\n'
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

unset AIDEVOPS_REPOS_CONFIG
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

STALE_REPO="${ROOT}/stale-repo"
STALE_REMOTE="${ROOT}/stale-remote.git"
STALE_RECOVERY="${ROOT}/stale-recovery"
mkdir -p "$STALE_REPO"
/usr/bin/git init -q --bare "$STALE_REMOTE"
/usr/bin/git -C "$STALE_REPO" init -q -b main
/usr/bin/git -C "$STALE_REPO" config user.name Test
/usr/bin/git -C "$STALE_REPO" config user.email test@example.invalid
/usr/bin/git -C "$STALE_REPO" config commit.gpgsign false
printf 'stale seed\n' >"${STALE_REPO}/README.md"
/usr/bin/git -C "$STALE_REPO" add README.md
/usr/bin/git -C "$STALE_REPO" commit -q -m seed
/usr/bin/git -C "$STALE_REPO" remote add origin "$STALE_REMOTE"
/usr/bin/git -C "$STALE_REPO" push -q -u origin main
/usr/bin/git -C "$STALE_REMOTE" symbolic-ref HEAD refs/heads/main
/usr/bin/git -C "$STALE_REPO" remote set-head origin main
stale_tip=$(/usr/bin/git -C "$STALE_REPO" rev-parse HEAD)
/usr/bin/git -C "$STALE_REPO" switch -q --detach "$stale_tip"
stale_metadata="${STALE_REPO}/.git/rebase-merge"
mkdir "$stale_metadata"
printf 'refs/heads/main\n' >"${stale_metadata}/head-name"
printf '%s\n' "$stale_tip" >"${stale_metadata}/onto"
printf '%s\n' "$stale_tip" >"${stale_metadata}/orig-head"
: >"${stale_metadata}/git-rebase-todo"
printf 'pick %s seed\n' "$stale_tip" >"${stale_metadata}/done"
printf '1\n' >"${stale_metadata}/msgnum"
printf '1\n' >"${stale_metadata}/end"
stale_index_tree=$(/usr/bin/git -C "$STALE_REPO" write-tree)
stale_output=""
if stale_output=$(AIDEVOPS_CANONICAL_RECOVERY_ROOT="$STALE_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-stale-rebase --repo "$STALE_REPO" --issue 28503 \
	--confirm CLEAR_CONVERGED_STALE_REBASE) &&
	[[ "$stale_output" == *"CLEARED_CONVERGED_STALE_REBASE=true"* ]] &&
	[[ ! -e "$stale_metadata" ]] &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" rev-parse HEAD)" == "$stale_tip" ]] &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" rev-parse main)" == "$stale_tip" ]] &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" write-tree)" == "$stale_index_tree" ]] &&
	[[ -z "$(/usr/bin/git -C "$STALE_REPO" status --porcelain)" ]] &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" rev-parse "refs/aidevops/canonical-recovery/issue-28503/stale-rebase/${stale_tip}")" == "$stale_tip" ]] &&
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$HELPER" restore-default --repo "$STALE_REPO" --issue 28503 --confirm RESTORE_CANONICAL_DEFAULT >/dev/null &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" branch --show-current)" == "main" ]]; then
	printf 'PASS converged stale rebase is preserved, cleared without tree changes, and restore-default succeeds\n'
else
	printf 'FAIL converged stale rebase recovery did not preserve invariant state\n'
	exit 1
fi

cp -R "${STALE_RECOVERY}/28503/stale-rebase-${stale_tip}" "$stale_metadata"
printf 'pick %s still-active\n' "$stale_tip" >"${stale_metadata}/git-rebase-todo"
if AIDEVOPS_CANONICAL_RECOVERY_ROOT="$STALE_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-stale-rebase --repo "$STALE_REPO" --issue 28503 \
	--confirm CLEAR_CONVERGED_STALE_REBASE >/dev/null 2>&1; then
	printf 'FAIL stale rebase cleanup accepted active todo entries\n'
	exit 1
elif [[ -s "${stale_metadata}/git-rebase-todo" ]] &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" rev-parse HEAD)" == "$stale_tip" ]]; then
	printf 'PASS stale rebase cleanup rejects active state without mutation\n'
else
	printf 'FAIL active stale rebase refusal changed repository state\n'
	exit 1
fi
rm -rf "$stale_metadata"
cp -R "${STALE_RECOVERY}/28503/stale-rebase-${stale_tip}" "$stale_metadata"
stale_race_hook="${ROOT}/mutate-stale-rebase.sh"
# Generated hook expands its own positional argument.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "2\n" >"$2/msgnum"' >"$stale_race_hook"
chmod +x "$stale_race_hook"
if AIDEVOPS_CANONICAL_BEFORE_REBASE_CLEANUP_HOOK="$stale_race_hook" \
	AIDEVOPS_CANONICAL_RECOVERY_ROOT="$STALE_RECOVERY" AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	bash "$HELPER" clear-stale-rebase --repo "$STALE_REPO" --issue 28503 \
	--confirm CLEAR_CONVERGED_STALE_REBASE >/dev/null 2>&1; then
	printf 'FAIL stale rebase cleanup accepted concurrently changing metadata\n'
	exit 1
elif [[ -d "$stale_metadata" ]] && [[ "$(<"${stale_metadata}/msgnum")" == "2" ]] &&
	[[ "$(/usr/bin/git -C "$STALE_REPO" rev-parse HEAD)" == "$stale_tip" ]]; then
	printf 'PASS stale rebase cleanup rejects concurrent metadata changes without cleanup\n'
else
	printf 'FAIL concurrent stale rebase refusal removed or changed canonical state\n'
	exit 1
fi

SYNC_REPO="${ROOT}/sync-repo"
SYNC_REMOTE="${ROOT}/sync-remote.git"
SYNC_UPDATER="${ROOT}/sync-updater"
SYNC_BACKUPS="${ROOT}/sync-backups"
SYNC_REGISTRY_DIR="${ROOT}/sync-registry"
SYNC_REGISTRY_DB="${SYNC_REGISTRY_DIR}/worktree-registry.db"
DIRTY_HELPER="${SCRIPT_DIR}/dirty-worktree-backup-helper.sh"
mkdir -p "$SYNC_REPO" "$SYNC_REGISTRY_DIR"
/usr/bin/git init -q --bare "$SYNC_REMOTE"
/usr/bin/git -C "$SYNC_REPO" init -q -b develop
/usr/bin/git -C "$SYNC_REPO" config user.name Test
/usr/bin/git -C "$SYNC_REPO" config user.email test@example.invalid
/usr/bin/git -C "$SYNC_REPO" config commit.gpgsign false
printf 'sync seed\n' >"${SYNC_REPO}/README.md"
/usr/bin/git -C "$SYNC_REPO" add README.md
/usr/bin/git -C "$SYNC_REPO" commit -q -m seed
/usr/bin/git -C "$SYNC_REPO" remote add origin "$SYNC_REMOTE"
/usr/bin/git -C "$SYNC_REPO" push -q -u origin develop
/usr/bin/git -C "$SYNC_REMOTE" symbolic-ref HEAD refs/heads/develop
/usr/bin/git -C "$SYNC_REPO" remote set-head origin develop
/usr/bin/git clone -q "$SYNC_REMOTE" "$SYNC_UPDATER"
/usr/bin/git -C "$SYNC_UPDATER" config user.name Test
/usr/bin/git -C "$SYNC_UPDATER" config user.email test@example.invalid

printf 'accidental local commit\n' >"${SYNC_REPO}/local-only.txt"
/usr/bin/git -C "$SYNC_REPO" add local-only.txt
/usr/bin/git -C "$SYNC_REPO" commit -q -m 'accidental local commit'
sync_local_tip=$(/usr/bin/git -C "$SYNC_REPO" rev-parse HEAD)
printf 'staged state\n' >"${SYNC_REPO}/staged.txt"
/usr/bin/git -C "$SYNC_REPO" add staged.txt
printf 'unstaged state\n' >>"${SYNC_REPO}/README.md"
mkdir -p "${SYNC_REPO}/todo/tasks"
printf 'untracked state\n' >"${SYNC_REPO}/todo/tasks/recovery.md"

printf 'remote divergence\n' >"${SYNC_UPDATER}/remote-only.txt"
/usr/bin/git -C "$SYNC_UPDATER" add remote-only.txt
/usr/bin/git -C "$SYNC_UPDATER" commit -q -m 'remote divergence'
/usr/bin/git -C "$SYNC_UPDATER" push -q origin develop
sync_remote_tip=$(/usr/bin/git -C "$SYNC_REMOTE" rev-parse refs/heads/develop)

sqlite3 "$SYNC_REGISTRY_DB" "
CREATE TABLE worktree_owners (
  worktree_path TEXT PRIMARY KEY,
  branch TEXT,
  owner_pid INTEGER,
  owner_session TEXT DEFAULT '',
  owner_batch TEXT DEFAULT '',
  task_id TEXT DEFAULT '',
  owner_comm TEXT DEFAULT '',
  owner_dead_seen_at TEXT DEFAULT '',
  created_at TEXT DEFAULT ''
);
INSERT INTO worktree_owners (worktree_path, branch, owner_pid, owner_session)
VALUES ('${SYNC_REPO}', 'develop', $$, 'invalid-canonical-owner');
"

sync_failure_hook="${ROOT}/fail-before-sync-ref-update.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$sync_failure_hook"
chmod +x "$sync_failure_hook"
sync_output=""
sync_rc=0
sync_output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	AIDEVOPS_DIRTY_BACKUP_ROOT="$SYNC_BACKUPS" \
	WORKTREE_REGISTRY_DIR="$SYNC_REGISTRY_DIR" \
	WORKTREE_REGISTRY_DB="$SYNC_REGISTRY_DB" \
	AIDEVOPS_CANONICAL_BEFORE_REF_UPDATE_HOOK="$sync_failure_hook" \
	bash "$HELPER" sync-mirror --repo "$SYNC_REPO" --issue 28065 \
	--confirm SYNCHRONIZE_CANONICAL_MIRROR 2>&1) || sync_rc=$?
sync_backup_id=""
while IFS= read -r sync_line; do
	case "$sync_line" in
	PRESERVED_BACKUP_ID=*) sync_backup_id="${sync_line#PRESERVED_BACKUP_ID=}" ;;
	esac
done <<<"$sync_output"
sync_preservation_ref="refs/aidevops/canonical-recovery/issue-28065/${sync_local_tip}"
if [[ "$sync_rc" -ne 0 ]] && [[ -n "$sync_backup_id" ]] &&
	[[ "$sync_output" == *"RESTORE_COMMAND="* ]] &&
	[[ -z "$(/usr/bin/git -C "$SYNC_REPO" status --porcelain=v1)" ]] &&
	[[ "$(/usr/bin/git -C "$SYNC_REPO" rev-parse HEAD)" == "$sync_local_tip" ]] &&
	[[ "$(/usr/bin/git -C "$SYNC_REPO" rev-parse "$sync_preservation_ref")" == "$sync_local_tip" ]]; then
	printf 'PASS interrupted synchronization leaves verified recovery evidence and a clean original tip\n'
else
	printf 'FAIL interrupted synchronization lost evidence or changed canonical state\n'
	exit 1
fi

if [[ "$(sqlite3 "$SYNC_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners WHERE worktree_path = '${SYNC_REPO}';")" == "0" ]] &&
	kill -0 $$ 2>/dev/null; then
	printf 'PASS invalid canonical ownership row is removed without signalling its live PID\n'
else
	printf 'FAIL canonical ownership cleanup retained the row or harmed its live PID\n'
	exit 1
fi

sync_output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	AIDEVOPS_DIRTY_BACKUP_ROOT="$SYNC_BACKUPS" \
	WORKTREE_REGISTRY_DIR="$SYNC_REGISTRY_DIR" \
	WORKTREE_REGISTRY_DB="$SYNC_REGISTRY_DB" \
	bash "$HELPER" sync-mirror --repo "$SYNC_REPO" --issue 28065 \
	--confirm SYNCHRONIZE_CANONICAL_MIRROR 2>&1)
if [[ "$sync_output" == *"SYNCHRONIZED_CANONICAL_MIRROR=true"* ]] &&
	[[ "$(/usr/bin/git -C "$SYNC_REPO" rev-parse HEAD)" == "$sync_remote_tip" ]] &&
	[[ -z "$(/usr/bin/git -C "$SYNC_REPO" status --porcelain=v1)" ]]; then
	printf 'PASS safe retry converges the canonical mirror to the exact resolved remote tip\n'
else
	printf 'FAIL safe retry did not converge to the exact remote tip\n'
	exit 1
fi

AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$SYNC_BACKUPS" \
	bash "$DIRTY_HELPER" restore --repo "$SYNC_REPO" --backup "$sync_backup_id" \
	--confirm RESTORE_DIRTY_WORKTREE_BACKUP >/dev/null
if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$SYNC_BACKUPS" \
	bash "$DIRTY_HELPER" matches --repo "$SYNC_REPO" --backup "$sync_backup_id" >/dev/null &&
	[[ "$(/usr/bin/git -C "$SYNC_REPO" rev-parse HEAD)" == "$sync_local_tip" ]]; then
	printf 'PASS emitted backup ID restores byte-identical content and index state\n'
else
	printf 'FAIL backup restore did not reconstruct the original canonical state\n'
	exit 1
fi

sync_retry_output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git \
	AIDEVOPS_DIRTY_BACKUP_ROOT="$SYNC_BACKUPS" \
	WORKTREE_REGISTRY_DIR="$SYNC_REGISTRY_DIR" \
	WORKTREE_REGISTRY_DB="$SYNC_REGISTRY_DB" \
	bash "$HELPER" sync-mirror --repo "$SYNC_REPO" --issue 28065 \
	--confirm SYNCHRONIZE_CANONICAL_MIRROR 2>&1)
backup_count=0
for backup_path in "$SYNC_BACKUPS"/*; do
	[[ -d "$backup_path" ]] || continue
	backup_count=$((backup_count + 1))
done
if [[ "$sync_retry_output" == *"PRESERVED_BACKUP_ID=${sync_backup_id}"* ]] &&
	[[ "$backup_count" -eq 1 ]] &&
	[[ "$(/usr/bin/git -C "$SYNC_REPO" rev-parse HEAD)" == "$sync_remote_tip" ]] &&
	grep -q 'Canonical mirror synchronization authorized' "$HOME/.aidevops/logs/canonical-recovery-audit.jsonl"; then
	printf 'PASS repeated synchronization reuses durable evidence and remains auditable\n'
else
	printf 'FAIL repeated synchronization duplicated evidence or lost auditability\n'
	exit 1
fi
