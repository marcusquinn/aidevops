#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#35024: owned scratch worktrees are locked with an owner token, removed
# only while that token is intact and the tree is clean, and reclaimed after
# their owner dies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
HOME="${ROOT}/home"
AIDEVOPS_CLEANUP_LOG="${ROOT}/cleanup.log"
export HOME AIDEVOPS_CLEANUP_LOG
REPO="${ROOT}/repo"
BASE="${ROOT}/worktrees"
FAILURES=0

pass() {
	local message="$1"
	printf 'PASS %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message"
	FAILURES=$((FAILURES + 1))
	return 0
}

lock_reason_of() {
	local wt_path="$1"
	local git_dir=""
	git_dir=$(git -C "$wt_path" rev-parse --path-format=absolute --git-dir) || return 1
	cat "${git_dir}/locked"
	return 0
}

git init -q -b main "$REPO"
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" commit -q --allow-empty -m seed

# shellcheck source=../scratch-worktree-helper.sh
source "${SCRIPT_DIR}/../scratch-worktree-helper.sh"

# 1. Creation locks with this process's owner token; clean removal succeeds.
scratch_worktree_add "$REPO" "$BASE" fetch HEAD || fail "scratch worktree creation"
created="$SCRATCH_WORKTREE_PATH"
if [[ -d "$created" && "$(lock_reason_of "$created")" == "$SCRATCH_WORKTREE_REASON" ]] &&
	[[ "$SCRATCH_WORKTREE_REASON" == "aidevops-scratch/v1 label=fetch pid=$$ "* ]]; then
	pass "scratch worktree is locked with the owner token"
else
	fail "scratch worktree lock token"
fi
removed_ok=0
scratch_worktree_remove "$created" test && removed_ok=1
porcelain=$(git -C "$REPO" worktree list --porcelain)
if [[ "$removed_ok" -eq 1 && ! -e "$created" ]] &&
	! grep -qF -- "worktree ${created}" <<<"$porcelain"; then
	pass "owned clean scratch worktree is removed"
else
	fail "owned clean scratch worktree removal"
fi
grep -qF "worktree-removed: ${created} — scratch-owned" "$AIDEVOPS_CLEANUP_LOG" &&
	pass "removal is audited" || fail "removal audit line"

# 2. A changed lock (another owner) is never removed.
scratch_worktree_add "$REPO" "$BASE" fetch HEAD || fail "second creation"
foreign="$SCRATCH_WORKTREE_PATH"
git -C "$foreign" worktree unlock "$foreign"
git -C "$foreign" worktree lock --reason "operator hold" "$foreign"
if ! scratch_worktree_remove "$foreign" test && [[ -d "$foreign" ]]; then
	pass "changed lock preserves the worktree"
else
	fail "changed lock was removed"
fi
git -C "$foreign" worktree unlock "$foreign"
git -C "$foreign" worktree remove "$foreign"

# 3. Dirty state is preserved and the owner lock is restored.
scratch_worktree_add "$REPO" "$BASE" fetch HEAD || fail "third creation"
dirty="$SCRATCH_WORKTREE_PATH"
dirty_reason="$SCRATCH_WORKTREE_REASON"
printf 'work\n' >"${dirty}/untracked.txt"
if ! scratch_worktree_remove "$dirty" test && [[ -f "${dirty}/untracked.txt" ]] &&
	[[ "$(lock_reason_of "$dirty")" == "$dirty_reason" ]]; then
	pass "dirty scratch worktree is preserved and stays locked"
else
	fail "dirty scratch worktree handling"
fi

# 4. A path not created by this process is refused without inspection.
SCRATCH_WORKTREE_PATH=""
SCRATCH_WORKTREE_REASON=""
if ! scratch_worktree_remove "$dirty" test && [[ -d "$dirty" ]]; then
	pass "unowned path is refused"
else
	fail "unowned path was removed"
fi

# 5. Reaper: only dead-owner, idle, clean scratch worktrees are reclaimed.
# Bash 3.2 runs an inherited EXIT trap in a killed background child; clear it.
(
	trap - EXIT
	exec sleep 300
) &
dead_pid=$!
kill "$dead_pid" 2>/dev/null || true
wait "$dead_pid" 2>/dev/null || true
(
	trap - EXIT
	exec sleep 300
) &
live_pid=$!
make_stale() {
	local owner_pid="$1"
	local wt_path="$2"
	git -C "$REPO" worktree add -q --detach "$wt_path" HEAD
	git -C "$wt_path" worktree lock --reason "aidevops-scratch/v1 label=fetch pid=${owner_pid} started=unknown nonce=1" "$wt_path"
	touch -t 202001010000 "$wt_path"
	return 0
}
dead_stale="${BASE}/.repo-fetch-dead"
live_stale="${BASE}/.repo-fetch-live"
fresh_dead="${BASE}/.repo-fetch-fresh"
make_stale "$dead_pid" "$dead_stale"
make_stale "$live_pid" "$live_stale"
make_stale "$dead_pid" "$fresh_dead"
touch "$fresh_dead"
scratch_worktree_reap_stale "$REPO"
[[ ! -e "$dead_stale" ]] && pass "dead idle owner is reclaimed" || fail "dead idle owner not reclaimed"
[[ -d "$live_stale" ]] && pass "live owner is preserved" || fail "live owner was reclaimed"
[[ -d "$fresh_dead" ]] && pass "recently active scratch is preserved" || fail "recent scratch was reclaimed"
[[ -d "$dirty" ]] && pass "dirty locked scratch is preserved by the reaper" || fail "dirty scratch was reaped"
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true

if [[ "$FAILURES" -ne 0 ]]; then
	printf '%s failure(s)\n' "$FAILURES"
	exit 1
fi
printf 'All scratch-worktree-helper checks passed\n'
exit 0
