#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#22176 regression guard.
#
# setup.sh --non-interactive runs cleanup_worktree_entries_in_repos_json during
# deployment. When invoked from a linked implementation worktree, that migration
# must not remove the current worktree's repos.json entry, while still pruning
# other linked-worktree registrations that were incorrectly auto-discovered.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
MIGRATIONS_MODULE="${REPO_ROOT}/setup-modules/migrations.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

fail() {
	local message="$1"
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$message"
	exit 1
	return 1
}

pass() {
	local message="$1"
	printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$message"
	return 0
}

print_info() {
	local message="$1"
	printf '[INFO] %s\n' "$message" >/dev/null
	return 0
}

print_warning() {
	local message="$1"
	printf '[WARNING] %s\n' "$message" >/dev/null
	return 0
}

print_error() {
	local message="$1"
	printf '[ERROR] %s\n' "$message" >&2
	return 0
}

REGISTERED_WORKTREE=""
REGISTERED_BRANCH=""

register_worktree() {
	local wt_path="$1"
	local branch="$2"
	REGISTERED_WORKTREE="$wt_path"
	REGISTERED_BRANCH="$branch"
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.config/aidevops" "${HOME}/.aidevops/logs"

MAIN_REPO="${TEST_ROOT}/repo"
CURRENT_WT="${TEST_ROOT}/current-worktree"
STALE_WT="${TEST_ROOT}/stale-worktree"
CURRENT_SUBDIR="${CURRENT_WT}/nested"
REPOS_JSON="${HOME}/.config/aidevops/repos.json"

mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q -b main || fail "init fake repo"
git -C "$MAIN_REPO" config user.email "test@test.local"
git -C "$MAIN_REPO" config user.name "Test"
printf 'ok\n' >"${MAIN_REPO}/README.md"
git -C "$MAIN_REPO" add README.md || fail "stage README"
git -C "$MAIN_REPO" commit -q -m init || fail "commit fake repo"

git -C "$MAIN_REPO" worktree add -q -b feature/current "$CURRENT_WT" main || fail "create current worktree"
git -C "$MAIN_REPO" worktree add -q -b feature/stale "$STALE_WT" main || fail "create stale worktree"
mkdir -p "$CURRENT_SUBDIR"

jq -n \
	--arg main "$MAIN_REPO" \
	--arg current "$CURRENT_WT" \
	--arg stale "$STALE_WT" \
	'{initialized_repos:[{path:$main,slug:"owner/repo"},{path:$current,slug:"owner/repo-current"},{path:$stale,slug:"owner/repo-stale"}]}' \
	>"$REPOS_JSON"

# shellcheck source=/dev/null
source "$MIGRATIONS_MODULE" >/dev/null 2>&1

cd "$CURRENT_SUBDIR" || fail "enter current worktree subdir"
INSTALL_DIR="$CURRENT_SUBDIR" protect_current_setup_worktree || fail "protect current setup worktree"


CURRENT_WT_PHYSICAL=$(cd "$CURRENT_WT" && pwd -P)
if [[ "$REGISTERED_WORKTREE" != "$CURRENT_WT_PHYSICAL" ]]; then
	fail "current setup worktree ownership is registered"
fi
if [[ "$REGISTERED_BRANCH" != "feature/current" ]]; then
	fail "current setup worktree branch is registered"
fi

cleanup_worktree_entries_in_repos_json || fail "run worktree repos cleanup"

if [[ ! -d "$CURRENT_WT" ]]; then
	fail "current worktree directory still exists"
fi
if [[ ! -d "$CURRENT_SUBDIR" ]]; then
	fail "current worktree subdir still exists"
fi
pwd >/dev/null 2>&1 || fail "current working directory still resolves"
git status --short >/dev/null || fail "git status still works in current worktree"

jq -e --arg current "$CURRENT_WT" 'any(.initialized_repos[]; .path == $current)' "$REPOS_JSON" >/dev/null \
	|| fail "current worktree repos.json entry is preserved"
jq -e --arg main "$MAIN_REPO" 'any(.initialized_repos[]; .path == $main)' "$REPOS_JSON" >/dev/null \
	|| fail "main repo repos.json entry is preserved"
if jq -e --arg stale "$STALE_WT" 'any(.initialized_repos[]; .path == $stale)' "$REPOS_JSON" >/dev/null; then
	fail "stale linked-worktree repos.json entry is removed"
fi

pass "setup worktree repos.json cleanup preserves current cwd"
exit 0
