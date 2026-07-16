#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
: "${RED:=}"
: "${NC:=}"

# shellcheck source=../worktree-helper-add.sh
source "${SCRIPT_DIR}/worktree-helper-add.sh"

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message"
	return 1
}

emit_porcelain_fixture() {
	local i
	printf 'worktree /tmp/aidevops path with spaces\n'
	printf 'HEAD 1111111111111111111111111111111111111111\n'
	printf 'branch refs/heads/feature/exact\n\n'
	printf 'worktree /tmp/aidevops-prefix\n'
	printf 'HEAD 2222222222222222222222222222222222222222\n'
	printf 'branch refs/heads/feature/exact-extra\n\n'
	for ((i = 0; i < 20000; i++)); do
		printf 'worktree /tmp/aidevops-%s\n' "$i"
		printf 'HEAD 3333333333333333333333333333333333333333\n'
		printf 'branch refs/heads/feature/filler-%s\n\n' "$i"
	done
	return 0
}

git() {
	local command_name="${1:-}"
	local subcommand="${2:-}"
	local format="${3:-}"
	if [[ "$command_name" == "worktree" && "$subcommand" == "list" && "$format" == "--porcelain" ]]; then
		emit_porcelain_fixture || return 1
		return 0
	fi
	command git "$@" || return 1
	return 0
}

# Prove the fixture reproduces the original pipefail false negative: grep exits
# after the first match, the still-writing producer receives SIGPIPE, and the
# pipeline reports failure even though the branch exists.
if git worktree list --porcelain | grep -q 'branch refs/heads/feature/exact$'; then
	fail "legacy early-closing lookup unexpectedly survived the SIGPIPE fixture"
fi

resolved_path=$(get_worktree_path_for_branch "feature/exact") || fail "exact branch lookup failed"
[[ "$resolved_path" == "/tmp/aidevops path with spaces" ]] || fail "path with spaces was not preserved"

worktree_exists_for_branch "feature/exact" || fail "existing branch was reported missing"

if get_worktree_path_for_branch "feature/exact-extra-more" >/dev/null; then
	fail "branch lookup accepted a non-exact prefix match"
fi

if worktree_exists_for_branch "feature/missing"; then
	fail "missing branch was reported present"
fi

resolved_path=$(_remove_resolve_path "feature/exact") || fail "remove target did not resolve"
[[ "$resolved_path" == "/tmp/aidevops path with spaces" ]] || fail "remove target resolved the wrong path"

missing_error=""
if missing_error=$(_remove_resolve_path "feature/missing" 2>&1); then
	fail "missing remove target did not fail closed"
fi
[[ "$missing_error" == *"No worktree found"* ]] || fail "missing remove target omitted its error"

printf 'PASS worktree branch lookup is SIGPIPE-safe\n'
