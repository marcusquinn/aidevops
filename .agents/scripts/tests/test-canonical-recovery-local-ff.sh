#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Fixture test for canonical-recovery-helper.sh fast-forward-local (remote-less repos).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/canonical-recovery-helper.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export HOME="${ROOT}/home"
mkdir -p "$HOME"
LOCAL_REPO="${ROOT}/local-only"
LOCAL_WT="${ROOT}/local-only-wt"
LOCAL_BACKUPS="${ROOT}/local-backups"
GIT=/usr/bin/git

mkdir -p "$LOCAL_REPO"
"$GIT" -C "$LOCAL_REPO" init -q -b main
"$GIT" -C "$LOCAL_REPO" config user.name Test
"$GIT" -C "$LOCAL_REPO" config user.email test@example.invalid
"$GIT" -C "$LOCAL_REPO" config commit.gpgsign false
printf 'one\ntwo\nthree\n' >"${LOCAL_REPO}/doc.txt"
printf 'other\n' >"${LOCAL_REPO}/other.txt"
"$GIT" -C "$LOCAL_REPO" add -A
"$GIT" -C "$LOCAL_REPO" commit -q -m seed
"$GIT" -C "$LOCAL_REPO" worktree add -q -b feature/local-ff "$LOCAL_WT"
printf 'one\ntwo\nthree\nfour\n' >"${LOCAL_WT}/doc.txt"
"$GIT" -C "$LOCAL_WT" commit -q -am "feature change"
LOCAL_TIP=$("$GIT" -C "$LOCAL_WT" rev-parse HEAD)
"$GIT" -C "$LOCAL_REPO" branch no-worktree "$LOCAL_TIP"
printf 'user edit\n' >>"${LOCAL_REPO}/other.txt"
printf 'untracked\n' >"${LOCAL_REPO}/scratch.txt"

run_local_ff() {
	local branch="$1"
	AIDEVOPS_REAL_GIT_BIN=$GIT AIDEVOPS_DIRTY_BACKUP_ROOT="$LOCAL_BACKUPS" \
		bash "$HELPER" fast-forward-local --repo "$LOCAL_REPO" --from-branch "$branch" \
		--task t1 --confirm FAST_FORWARD_LOCAL_CANONICAL 2>&1 || return 1
	return 0
}

if run_local_ff no-worktree >/dev/null; then
	printf 'FAIL local fast-forward accepted a branch without a linked worktree\n'
	exit 1
fi
printf 'PASS local fast-forward refuses non-linked-worktree branch\n'

local_output=$(run_local_ff feature/local-ff) || {
	printf 'FAIL local fast-forward failed: %s\n' "$local_output"
	exit 1
}
if [[ "$local_output" == *"FAST_FORWARDED_LOCAL_CANONICAL=true"* ]] &&
	[[ "$("$GIT" -C "$LOCAL_REPO" rev-parse refs/heads/main)" == "$LOCAL_TIP" ]] &&
	[[ "$("$GIT" -C "$LOCAL_REPO" rev-parse HEAD)" == "$LOCAL_TIP" ]] &&
	[[ "$(<"${LOCAL_REPO}/other.txt")" == $'other\nuser edit' ]] &&
	[[ "$(<"${LOCAL_REPO}/scratch.txt")" == "untracked" ]] &&
	[[ "$local_output" == *"PRESERVED_BACKUP_ID="* ]] &&
	[[ -s "$HOME/.aidevops/logs/canonical-recovery-audit.jsonl" ]]; then
	printf 'PASS local fast-forward moves default ref, re-applies user edits, records backup and audit\n'
else
	printf 'FAIL local fast-forward result incorrect: %s\n' "$local_output"
	exit 1
fi

printf 'solo\n' >"${LOCAL_WT}/solo.txt"
"$GIT" -C "$LOCAL_WT" add solo.txt
"$GIT" -C "$LOCAL_WT" commit -q -m "feature solo"
printf 'main only\n' >"${LOCAL_REPO}/main-only.txt"
"$GIT" -C "$LOCAL_REPO" add main-only.txt
"$GIT" -C "$LOCAL_REPO" commit -q -m "main diverges"
if run_local_ff feature/local-ff >/dev/null; then
	printf 'FAIL local fast-forward accepted a non-fast-forward branch\n'
	exit 1
fi
printf 'PASS local fast-forward refuses non-fast-forward branch\n'

"$GIT" -C "$LOCAL_REPO" remote add origin "${ROOT}/remote.git"
remote_out=$(run_local_ff feature/local-ff) && {
	printf 'FAIL local fast-forward accepted a repository with a remote\n'
	exit 1
}
if [[ "$remote_out" != *"sync-mirror"* ]]; then
	printf 'FAIL remote refusal did not point to sync-mirror: %s\n' "$remote_out"
	exit 1
fi
printf 'PASS local fast-forward refuses repositories with a remote and points to sync-mirror\n'
