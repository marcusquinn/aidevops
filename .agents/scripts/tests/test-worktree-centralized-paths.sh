#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
mkdir -p "$HOME/.config/aidevops" "$TEST_ROOT/Git"

# shellcheck source=../worktree-paths.sh
source "${TEST_SCRIPTS_DIR}/worktree-paths.sh"

REPOS_JSON="$HOME/.config/aidevops/repos.json"
export AIDEVOPS_REPOS_JSON="$REPOS_JSON"

rc=0
aidevops_migrate_repos_json_worktree_base_dir "$REPOS_JSON" "~"'/Git/_worktrees' || rc=1
[[ -f "$REPOS_JSON" ]] || rc=1
if command -v jq >/dev/null 2>&1; then
	got=$(jq -r '.worktree_base_dir // empty' "$REPOS_JSON" 2>/dev/null || true)
	[[ "$got" == "~"'/Git/_worktrees' ]] || rc=1
fi
print_result "repos.json migration creates worktree_base_dir" "$rc"

rc=0
base_dir=$(aidevops_worktree_base_dir) || rc=1
[[ "$base_dir" == "$HOME/Git/_worktrees" ]] || rc=1
[[ -d "$base_dir" ]] || rc=1
print_result "default worktree base expands and creates ~/Git/_worktrees" "$rc" "(got: ${base_dir:-})"

REPO="$TEST_ROOT/Git/example-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

rc=0
path=$(aidevops_generate_worktree_path "$REPO" "feature/Great-Thing") || rc=1
expected="$HOME/Git/_worktrees/example-repo-feature-great-thing"
[[ "$path" == "$expected" ]] || rc=1
print_result "generated path is centralized and flat" "$rc" "(got: ${path:-}, expected: $expected)"

rc=0
custom="$TEST_ROOT/custom-worktrees"
export AIDEVOPS_WORKTREE_BASE_DIR="$custom"
path=$(aidevops_generate_worktree_path "$REPO" "bugfix/Login") || rc=1
unset AIDEVOPS_WORKTREE_BASE_DIR
[[ "$path" == "$custom/example-repo-bugfix-login" ]] || rc=1
[[ -d "$custom" ]] || rc=1
print_result "env override controls worktree base" "$rc" "(got: ${path:-})"

echo ""
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
fi
printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
exit 1
