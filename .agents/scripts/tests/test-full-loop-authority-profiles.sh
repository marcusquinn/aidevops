#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#28112: external full loops stop at a ready PR while
# maintained-app loops merge and synchronize the verified PR base branch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW_DOC="${REPO_ROOT}/.agents/workflows/full-loop.md"
COMMAND_DOC="${REPO_ROOT}/.agents/scripts/commands/full-loop.md"
AGENTS_DOC="${REPO_ROOT}/.agents/AGENTS.md"
GIT_WORKFLOW_DOC="${REPO_ROOT}/.agents/workflows/git-workflow.md"
PR_LOOP_DOC="${REPO_ROOT}/.agents/workflows/pr-loop.md"

require_text() {
	local file="$1"
	local text="$2"
	local description="$3"

	if ! grep -Fq "$text" "$file"; then
		printf 'FAIL: %s\n' "$description" >&2
		return 1
	fi
	return 0
}

main() {
	local doc=""
	for doc in "$WORKFLOW_DOC" "$COMMAND_DOC"; do
		require_text "$doc" 'Repository Authority Profiles (MANDATORY)' \
			"$(basename "$doc") lacks the authority gate" || return 1
		require_text "$doc" '**Maintained app/repo**' \
			"$(basename "$doc") lacks the maintained path" || return 1
		require_text "$doc" '**External upstream contribution**' \
			"$(basename "$doc") lacks the external path" || return 1
		require_text "$doc" 'External sessions MUST NOT invoke either merge path' \
			"$(basename "$doc") does not prohibit external merges" || return 1
		require_text "$doc" "verified \`baseRefName\`" \
			"$(basename "$doc") does not resolve sync from the PR base" || return 1
	done

	require_text "$AGENTS_DOC" 'external contributions stop after a verified ready PR/review loop' \
		'AGENTS.md lacks the concise authority-aware rule' || return 1
	require_text "$GIT_WORKFLOW_DOC" 'full-loop request for a maintained non-aidevops repository explicitly requests synchronization' \
		'git workflow does not authorize guarded post-merge synchronization' || return 1
	require_text "$PR_LOOP_DOC" 'External loops never merge' \
		'PR loop does not stop external contributions before merge' || return 1
	require_text "$PR_LOOP_DOC" '<promise>PR_READY_EXTERNAL</promise>' \
		'PR loop lacks an external hand-off completion signal' || return 1

	printf 'PASS: full-loop authority profiles remain explicit and aligned\n'
	return 0
}

main "$@"
