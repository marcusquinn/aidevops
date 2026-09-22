#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AGENTS_DOC="${REPO_ROOT}/.agents/AGENTS.md"
SESSION_MANAGER_DOC="${REPO_ROOT}/.agents/workflows/session-manager.md"
WORKTREE_DOC="${REPO_ROOT}/.agents/workflows/worktree.md"
SESSION_DOC="${REPO_ROOT}/.agents/reference/session.md"

require_literal() {
	local needle="$1"
	local file="$2"
	local description="$3"

	if ! grep -Fq -- "$needle" "$file"; then
		printf 'FAIL: %s\n' "$description" >&2
		return 1
	fi
	return 0
}

main() {
	require_literal 'continue through verification in the same session/worktree' \
		"$AGENTS_DOC" 'always-loaded guidance permits same-session continuation' || return 1
	require_literal 'Approaching a context limit is neither completion nor a blocker' \
		"$AGENTS_DOC" 'always-loaded guidance omits context-limit continuation' || return 1
	require_literal 'never infer one from the unchanged session root' \
		"$SESSION_MANAGER_DOC" 'session manager treats an unchanged root as a blocker' || return 1
	require_literal 'Context pressure is not a handoff or completion signal' \
		"$SESSION_MANAGER_DOC" 'session manager still permits context-limit handoff' || return 1
	require_literal '**Same-session default**' \
		"$WORKTREE_DOC" 'worktree workflow omits same-session continuation' || return 1
	require_literal 'the unchanged OpenCode session root is not a blocker' \
		"$SESSION_DOC" 'session reference omits path-aware continuation' || return 1
	require_literal 'Context pressure changes transport state, not task state' \
		"$SESSION_DOC" 'session reference omits context-pressure semantics' || return 1
	require_literal 'Continuation required: yes' \
		"$SESSION_DOC" 'session reference omits executable post-compaction handoff' || return 1

	if grep -Fq -- '### Worktree + New Session (Recommended)' "$SESSION_MANAGER_DOC"; then
		printf 'FAIL: session manager still recommends a new chat for ordinary worktree creation\n' >&2
		return 1
	fi

	printf 'PASS: active work continues in-session through its linked worktree\n'
	return 0
}

main "$@"
