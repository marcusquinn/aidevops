#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#35659 fixture test for canonical-recovery-helper.sh: an incoming
# index-only migration (explicit root ignore rule plus
# `git rm --cached .aidevops.json`) must not silently delete the local project
# config. The helper reinstates it byte-identical as ignored local state, or
# refuses before anything changes.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/canonical-recovery-helper.sh"
# shellcheck source=.agents/scripts/portable-stat.sh
source "${SCRIPT_DIR}/portable-stat.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export HOME="${ROOT}/home"
GIT=/usr/bin/git
SYNC_REGISTRY_DIR="${ROOT}/sync-registry"
SYNC_REGISTRY_DB="${SYNC_REGISTRY_DIR}/worktree-registry.db"
mkdir -p "$HOME" "$SYNC_REGISTRY_DIR"
PCU_CONFIG=$'{\n  "version": "1",\n  "local_only": "kept"\n}\n'
PCU_EDITED='{"version": "1", "local_only": "edited"}'
PCU_ENTRIES=""
PCU_REMOTE=""
PCU_REPO=""
PCU_PEER=""
PCU_TIP=""
PCU_RC=0
PCU_OUTPUT=""
export AIDEVOPS_REPOS_CONFIG="${ROOT}/pcu-repos.json"

pcu_seed_repo() {
	local repo="$1"
	mkdir -p "$repo"
	"$GIT" -C "$repo" init -q -b main
	"$GIT" -C "$repo" config user.name Test
	"$GIT" -C "$repo" config user.email test@example.invalid
	"$GIT" -C "$repo" config commit.gpgsign false
	printf 'pcu seed\n' >"${repo}/README.md"
	printf '%s' "$PCU_CONFIG" >"${repo}/.aidevops.json"
	"$GIT" -C "$repo" add README.md .aidevops.json
	"$GIT" -C "$repo" commit -q -m seed
	return 0
}

# Git tracks only the executable bit, so a private mode and an old mtime keep
# the checkout clean while proving metadata survives reinstatement.
pcu_mark_config() {
	local repo="$1"
	chmod 640 "${repo}/.aidevops.json"
	touch -t 202401020304 "${repo}/.aidevops.json"
	return 0
}

# A registered GitHub-backed canonical checkout plus a peer clone.
pcu_fixture() {
	local name="$1"
	local url="ssh://git@github.com:22/Example/Pcu-${name}.git"
	PCU_REMOTE="${ROOT}/pcu-${name}.git"
	PCU_REPO="${ROOT}/pcu-${name}"
	PCU_PEER="${ROOT}/pcu-${name}-peer"
	"$GIT" init -q --bare "$PCU_REMOTE"
	pcu_seed_repo "$PCU_REPO"
	"$GIT" -C "$PCU_REPO" config "url.${PCU_REMOTE}.insteadOf" "$url"
	"$GIT" -C "$PCU_REPO" remote add origin "$url"
	"$GIT" -C "$PCU_REPO" push -q -u origin main
	"$GIT" -C "$PCU_REMOTE" symbolic-ref HEAD refs/heads/main
	"$GIT" -C "$PCU_REPO" remote set-head origin main
	"$GIT" clone -q "$PCU_REMOTE" "$PCU_PEER"
	"$GIT" -C "$PCU_PEER" config user.name Test
	"$GIT" -C "$PCU_PEER" config user.email test@example.invalid
	pcu_mark_config "$PCU_REPO"
	PCU_ENTRIES="${PCU_ENTRIES:+${PCU_ENTRIES},}{\"slug\":\"example/pcu-${name}\",\"path\":\"${PCU_REPO}\"}"
	printf '{"initialized_repos":[%s]}\n' "$PCU_ENTRIES" >"$AIDEVOPS_REPOS_CONFIG"
	return 0
}

# Commit the supported migration in a clone or linked worktree. With
# with_rule=false the same index-only removal has no ignore rule, which is an
# intentional deletion rather than a migration.
pcu_commit_migration() {
	local checkout="$1"
	local with_rule="$2"
	if [[ "$with_rule" == "true" ]]; then
		printf '/.aidevops.json\n' >>"${checkout}/.gitignore"
		"$GIT" -C "$checkout" add .gitignore
	fi
	"$GIT" -C "$checkout" rm -q --cached .aidevops.json
	"$GIT" -C "$checkout" commit -q -m 'untrack project config'
	return 0
}

pcu_migrate() {
	local with_rule="$1"
	pcu_commit_migration "$PCU_PEER" "$with_rule"
	"$GIT" -C "$PCU_PEER" push -q origin main
	PCU_TIP=$("$GIT" -C "$PCU_REMOTE" rev-parse refs/heads/main)
	return 0
}

pcu_run() {
	PCU_RC=0
	PCU_OUTPUT=$(AIDEVOPS_REAL_GIT_BIN="$GIT" AIDEVOPS_DIRTY_BACKUP_ROOT="${ROOT}/pcu-backups" \
		AIDEVOPS_CANONICAL_RECOVERY_ROOT="${ROOT}/pcu-recovery" \
		WORKTREE_REGISTRY_DIR="$SYNC_REGISTRY_DIR" WORKTREE_REGISTRY_DB="$SYNC_REGISTRY_DB" \
		bash "$HELPER" "$@" 2>&1) || PCU_RC=$?
	return 0
}

pcu_config_is() {
	local repo="$1"
	local expected="$2"
	[[ "$(
		cat "${repo}/.aidevops.json"
		printf x
	)" == "${expected}x" ]] || return 1
	return 0
}

pcu_ignored_config() {
	local repo="$1"
	[[ "$("$GIT" -C "$repo" status --porcelain=v1 --ignored -- .aidevops.json)" == "!! .aidevops.json" ]] || return 1
	[[ -z "$("$GIT" -C "$repo" status --porcelain=v1)" ]] || return 1
	return 0
}

pcu_pass() {
	printf 'PASS %s\n' "$1"
	return 0
}

pcu_fail() {
	printf 'FAIL %s\n%s\n' "$1" "$PCU_OUTPUT"
	exit 1
}

# 1. fast-forward-current: a clean config survives with exact bytes, mode, mtime.
pcu_fixture ffcurrent
pcu_mtime_before=$(_file_mtime_epoch "${PCU_REPO}/.aidevops.json")
pcu_migrate true
pcu_run fast-forward-current --repo "$PCU_REPO" --branch main --issue 35659 \
	--confirm FAST_FORWARD_CANONICAL_BRANCH
if [[ "$PCU_RC" -eq 0 ]] &&
	[[ "$("$GIT" -C "$PCU_REPO" rev-parse HEAD)" == "$PCU_TIP" ]] &&
	pcu_config_is "$PCU_REPO" "$PCU_CONFIG" &&
	[[ "$(_file_perms "${PCU_REPO}/.aidevops.json")" == "640" ]] &&
	[[ "$(_file_mtime_epoch "${PCU_REPO}/.aidevops.json")" == "$pcu_mtime_before" ]] &&
	[[ "$PCU_OUTPUT" == *"PROJECT_CONFIG_REINSTATED=.aidevops.json"* ]] &&
	pcu_ignored_config "$PCU_REPO"; then
	pcu_pass 'fast-forward-current reinstates a clean untracked project config byte-identical and ignored'
else
	pcu_fail 'fast-forward-current lost or altered a clean untracked project config'
fi
if rg -q '"project_config_preservation":"[^"]*/project-config-' \
	"${HOME}/.aidevops/logs/canonical-recovery-audit.jsonl"; then
	pcu_pass 'the authorized operation audit records the project config preservation'
else
	pcu_fail 'the operation audit does not record the project config preservation'
fi

# 2. Without the ignore rule the removal is intentional: nothing is preserved.
pcu_fixture norule
pcu_migrate false
pcu_run fast-forward-current --repo "$PCU_REPO" --branch main --issue 35659 \
	--confirm FAST_FORWARD_CANONICAL_BRANCH
if [[ "$PCU_RC" -eq 0 ]] &&
	[[ "$("$GIT" -C "$PCU_REPO" rev-parse HEAD)" == "$PCU_TIP" ]] &&
	[[ ! -e "${PCU_REPO}/.aidevops.json" ]] &&
	[[ "$PCU_OUTPUT" != *"PROJECT_CONFIG_PRESERVED_DIR="* ]]; then
	pcu_pass 'a tracked config deletion without an explicit ignore rule is not reinstated'
else
	pcu_fail 'an intentional config deletion was reinstated or blocked'
fi

# 3. A negated ignore rule is not a migration either.
pcu_fixture negated
printf '/.aidevops.json\n!/.aidevops.json\n' >"${PCU_PEER}/.gitignore"
"$GIT" -C "$PCU_PEER" add .gitignore
pcu_migrate false
pcu_run fast-forward-current --repo "$PCU_REPO" --branch main --issue 35659 \
	--confirm FAST_FORWARD_CANONICAL_BRANCH
if [[ "$PCU_RC" -eq 0 ]] &&
	[[ ! -e "${PCU_REPO}/.aidevops.json" ]] &&
	[[ "$PCU_OUTPUT" != *"PROJECT_CONFIG_PRESERVED_DIR="* ]]; then
	pcu_pass 'a negated ignore rule is treated as an intentional deletion'
else
	pcu_fail 'a negated ignore rule was treated as a migration'
fi

# 4. sync-mirror keeps a locally modified config: those edits are the
# machine-local state the migration exists to keep.
pcu_fixture modified
printf '%s\n' "$PCU_EDITED" >"${PCU_REPO}/.aidevops.json"
pcu_migrate true
pcu_run sync-mirror --repo "$PCU_REPO" --issue 35659 --confirm SYNCHRONIZE_CANONICAL_MIRROR
if [[ "$PCU_RC" -eq 0 ]] &&
	[[ "$("$GIT" -C "$PCU_REPO" rev-parse HEAD)" == "$PCU_TIP" ]] &&
	[[ "$(<"${PCU_REPO}/.aidevops.json")" == "$PCU_EDITED" ]] &&
	[[ "$PCU_OUTPUT" == *"PROJECT_CONFIG_REINSTATED=.aidevops.json"* ]] &&
	pcu_ignored_config "$PCU_REPO"; then
	pcu_pass 'sync-mirror reinstates a locally modified project config as ignored local state'
else
	pcu_fail 'sync-mirror lost a locally modified project config'
fi

# 5. A config already absent locally stays absent; nothing is invented.
pcu_fixture absent
rm "${PCU_REPO}/.aidevops.json"
pcu_migrate true
pcu_run sync-mirror --repo "$PCU_REPO" --issue 35659 --confirm SYNCHRONIZE_CANONICAL_MIRROR
if [[ "$PCU_RC" -eq 0 ]] &&
	[[ "$("$GIT" -C "$PCU_REPO" rev-parse HEAD)" == "$PCU_TIP" ]] &&
	[[ ! -e "${PCU_REPO}/.aidevops.json" ]] &&
	[[ "$PCU_OUTPUT" != *"PROJECT_CONFIG_PRESERVED_DIR="* ]]; then
	pcu_pass 'sync-mirror leaves an already-absent project config absent'
else
	pcu_fail 'sync-mirror invented or blocked on an absent project config'
fi

# 6. A symlinked config is refused before any backup, clean, or ref change.
pcu_fixture symlink
pcu_before=$("$GIT" -C "$PCU_REPO" rev-parse HEAD)
rm "${PCU_REPO}/.aidevops.json"
ln -s README.md "${PCU_REPO}/.aidevops.json"
pcu_migrate true
pcu_run sync-mirror --repo "$PCU_REPO" --issue 35659 --confirm SYNCHRONIZE_CANONICAL_MIRROR
if [[ "$PCU_RC" -ne 0 ]] &&
	[[ "$PCU_OUTPUT" == *"BLOCKED: incoming commit untracks .aidevops.json but the local copy is a symlink"* ]] &&
	[[ "$PCU_OUTPUT" != *"PRESERVED_BACKUP_ID="* ]] &&
	[[ "$("$GIT" -C "$PCU_REPO" rev-parse HEAD)" == "$pcu_before" ]] &&
	[[ -L "${PCU_REPO}/.aidevops.json" ]]; then
	pcu_pass 'sync-mirror refuses a symlinked project config before changing anything'
else
	pcu_fail 'sync-mirror did not refuse a symlinked project config safely'
fi

# 7. A ref change before the update blocks the run with the tracked config intact.
pcu_fixture refdrift
pcu_before=$("$GIT" -C "$PCU_REPO" rev-parse HEAD)
pcu_migrate true
pcu_drift_hook="${ROOT}/pcu-drift-hook.sh"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	"/usr/bin/git -C \"\${1:-}\" update-ref refs/remotes/origin/main \"\${3:-}\"" >"$pcu_drift_hook"
chmod +x "$pcu_drift_hook"
PCU_RC=0
PCU_OUTPUT=$(AIDEVOPS_CANONICAL_BEFORE_REF_UPDATE_HOOK="$pcu_drift_hook" AIDEVOPS_REAL_GIT_BIN="$GIT" \
	AIDEVOPS_CANONICAL_RECOVERY_ROOT="${ROOT}/pcu-recovery" \
	bash "$HELPER" fast-forward-current --repo "$PCU_REPO" --branch main --issue 35659 \
	--confirm FAST_FORWARD_CANONICAL_BRANCH 2>&1) || PCU_RC=$?
if [[ "$PCU_RC" -ne 0 ]] &&
	[[ "$PCU_OUTPUT" == *"ref changed during fast-forward"* ]] &&
	[[ "$("$GIT" -C "$PCU_REPO" rev-parse HEAD)" == "$pcu_before" ]] &&
	pcu_config_is "$PCU_REPO" "$PCU_CONFIG" &&
	[[ -z "$("$GIT" -C "$PCU_REPO" status --porcelain=v1)" ]]; then
	pcu_pass 'a ref change before the update blocks with the tracked project config intact'
else
	pcu_fail 'a ref change during an untracking migration altered canonical state'
fi

# 8. restore-default from another branch reinstates the clean config too.
pcu_fixture restore
"$GIT" -C "$PCU_REPO" switch -q -c safety/pcu
pcu_migrate true
pcu_run restore-default --repo "$PCU_REPO" --issue 35659 --confirm RESTORE_CANONICAL_DEFAULT
if [[ "$PCU_RC" -eq 0 ]] &&
	[[ "$("$GIT" -C "$PCU_REPO" branch --show-current)" == "main" ]] &&
	[[ "$("$GIT" -C "$PCU_REPO" rev-parse HEAD)" == "$PCU_TIP" ]] &&
	pcu_config_is "$PCU_REPO" "$PCU_CONFIG" &&
	pcu_ignored_config "$PCU_REPO"; then
	pcu_pass 'restore-default reinstates a clean untracked project config'
else
	pcu_fail 'restore-default lost a clean untracked project config'
fi

# 9. fast-forward-local (remote-less): a clean config is reinstated.
LOCAL_REPO="${ROOT}/pcu-local"
LOCAL_WT="${ROOT}/pcu-local-wt"
pcu_seed_repo "$LOCAL_REPO"
"$GIT" -C "$LOCAL_REPO" worktree add -q -b feature/untrack "$LOCAL_WT"
pcu_commit_migration "$LOCAL_WT" true
pcu_mark_config "$LOCAL_REPO"
local_tip=$("$GIT" -C "$LOCAL_WT" rev-parse HEAD)
pcu_run fast-forward-local --repo "$LOCAL_REPO" --from-branch feature/untrack \
	--task t35659 --confirm FAST_FORWARD_LOCAL_CANONICAL
if [[ "$PCU_RC" -eq 0 ]] &&
	[[ "$("$GIT" -C "$LOCAL_REPO" rev-parse HEAD)" == "$local_tip" ]] &&
	pcu_config_is "$LOCAL_REPO" "$PCU_CONFIG" &&
	[[ "$(_file_perms "${LOCAL_REPO}/.aidevops.json")" == "640" ]] &&
	pcu_ignored_config "$LOCAL_REPO"; then
	pcu_pass 'fast-forward-local reinstates a clean untracked project config'
else
	pcu_fail 'fast-forward-local lost a clean untracked project config'
fi

# 10. fast-forward-local refuses local edits its three-way re-apply cannot keep.
LOCAL_EDIT_REPO="${ROOT}/pcu-local-edit"
LOCAL_EDIT_WT="${ROOT}/pcu-local-edit-wt"
pcu_seed_repo "$LOCAL_EDIT_REPO"
"$GIT" -C "$LOCAL_EDIT_REPO" worktree add -q -b feature/untrack "$LOCAL_EDIT_WT"
pcu_commit_migration "$LOCAL_EDIT_WT" true
printf '%s\n' "$PCU_EDITED" >"${LOCAL_EDIT_REPO}/.aidevops.json"
local_before=$("$GIT" -C "$LOCAL_EDIT_REPO" rev-parse HEAD)
pcu_run fast-forward-local --repo "$LOCAL_EDIT_REPO" --from-branch feature/untrack \
	--task t35659 --confirm FAST_FORWARD_LOCAL_CANONICAL
if [[ "$PCU_RC" -ne 0 ]] &&
	[[ "$PCU_OUTPUT" == *"BLOCKED: incoming commit untracks .aidevops.json but the local copy has edits"* ]] &&
	[[ "$PCU_OUTPUT" != *"PRESERVED_BACKUP_ID="* ]] &&
	[[ "$("$GIT" -C "$LOCAL_EDIT_REPO" rev-parse HEAD)" == "$local_before" ]] &&
	[[ "$(<"${LOCAL_EDIT_REPO}/.aidevops.json")" == "$PCU_EDITED" ]]; then
	pcu_pass 'fast-forward-local refuses an edited project config before changing anything'
else
	pcu_fail 'fast-forward-local did not refuse an edited project config safely'
fi
