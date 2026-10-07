#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Offline integration regression for GH#33864; all identities are synthetic.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home"
export GIT_AUTHOR_NAME='Synthetic Test' GIT_COMMITTER_NAME='Synthetic Test'
export GIT_AUTHOR_EMAIL='test@example.invalid' GIT_COMMITTER_EMAIL='test@example.invalid'
mkdir -p "$HOME/.config/aidevops" "$ROOT/source"
printf '{"initialized_repos":[]}\n' >"$HOME/.config/aidevops/repos.json"
git init -q "$ROOT/source"
git init -q --bare "$ROOT/repository.git"
git -C "$ROOT/source" remote add origin https://github.com/example/synthetic.git
git -C "$ROOT/repository.git" remote add origin https://github.com/example/synthetic.git
ln -s "$SCRIPT_DIR/../hooks/privacy-guard-pre-push.sh" "$ROOT/source/.git/hooks/pre-push"

# Only the visibility probe is substituted; scanners and Git objects are real.
gh() {
	printf 'false\n'
	return 0
}
export -f gh
# shellcheck source=../shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh"
# shellcheck source=../claim-task-id-counter.sh
source "$SCRIPT_DIR/claim-task-id-counter.sh"
CAS_SOURCE_REPO_PATH="$ROOT/source"
CAS_GIT_CONTEXT_PATH="$ROOT/repository.git"
_CLAIM_COUNTER_CONTEXT_ROOT="$ROOT"
REMOTE_NAME=origin
COUNTER_BRANCH=task-id-counter
COUNTER_FILE=.task-counter
CAS_GIT_CMD_TIMEOUT_S=5

# Build both tips exclusively in the isolated object store, as canonical CAS does.
counter_commit() {
	local value="$1" parent="${2:-}" blob tree
	blob=$(printf '%s\n' "$value" | _counter_git hash-object -w --stdin)
	tree=$(printf '100644 blob %s\t.task-counter\n' "$blob" | _counter_git mktree)
	if [[ -n "$parent" ]]; then
		_counter_git commit-tree "$tree" -p "$parent" -m 'synthetic counter'
	else
		_counter_git commit-tree "$tree" -m 'synthetic counter'
	fi
	return 0
}
parent=$(counter_commit 2)
head=$(counter_commit 3 "$parent")
if git -C "$ROOT/source" cat-file -e "$head" 2>/dev/null; then
	printf 'FAIL: isolated tip unexpectedly exists in source\n'
	exit 1
fi

# Before object integration, the guard must diagnose an error, not invent hits.
rc=0
git -C "$ROOT/source" rev-parse --git-path hooks/pre-push >/dev/null
(
	cd "$ROOT/source"
	bash "$SCRIPT_DIR/../hooks/privacy-guard-pre-push.sh" origin https://github.com/example/synthetic.git \
		<<<"$head $head refs/heads/task-id-counter $parent"
) >"$ROOT/output" 2>"$ROOT/error" || rc=$?
[[ "$rc" -eq 1 ]]
grep -q 'private-entity scan failed.*no verified findings' "$ROOT/error"
if grep -q '\[BLOCK\].*contains private references' "$ROOT/error"; then exit 1; fi
printf 'PASS: unavailable objects produce an explicit fail-closed scan error\n'

# Defined by the sourced library; the later override tests propagation only.
# shellcheck disable=SC2218
_cas_run_pre_push_hook "$head" "$parent"
printf 'PASS: isolated numeric counter diff passes the real privacy hook\n'

# A true finding in the same isolated context remains blocked and names the path.
bad=$(counter_commit '/ho''me/synthetic/private' "$parent")
rc=0
_cas_run_pre_push_hook "$bad" "$parent" 2>"$ROOT/error" || rc=$?
[[ "$rc" -eq 1 ]]
grep -q '.task-counter:1:' "$ROOT/error"
grep -q 'Pre-push hook privacy-guard-pre-push.sh failed' "$ROOT/error"
printf 'PASS: true private finding names its path and hook\n'

# Failure must escape both the CAS and online layers with the setup-error code.
_cas_run_pre_push_hook() {
	return 1
}
rc=0
_cas_build_and_push "$parent" 3 'synthetic hook rejection' 2>"$ROOT/error" || rc=$?
[[ "$rc" -eq "$CAS_PROTECTED_BRANCH_RC" ]]
grep -q 'setup_error detail=pre_push_hook_failed' "$ROOT/error"
_cas_fetch_and_pin() {
	printf '%s 2\n' "$parent"
	return 0
}
_cas_acquire_local_lock() {
	return 0
}
_cas_release_local_lock() {
	return 0
}
CAS_MAX_RETRIES=2
CAS_WALL_TIMEOUT_S=30
rc=0
_allocate_online_with_collision_check "$ROOT/source" 1 2>"$ROOT/error" || rc=$?
[[ "$rc" -eq "$CAS_PROTECTED_BRANCH_RC" ]]
printf 'PASS: hook rejection preserves non-reconcilable setup-error status\n'
