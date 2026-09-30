#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_POLICY="${REPO_DIR}/.agents/reference/session.md"
CORE_POLICY="${REPO_DIR}/.agents/AGENTS.md"

require_phrase() {
	local file="$1"
	local phrase="$2"
	local label="$3"
	if ! grep -Fq -- "$phrase" "$file"; then
		printf 'FAIL: missing %s policy in %s\n' "$label" "$file" >&2
		return 1
	fi
	return 0
}

require_phrase "$SESSION_POLICY" \
	'Session-owned modified, staged, or untracked files are uncaptured' \
	'uncaptured Git state'
require_phrase "$SESSION_POLICY" \
	'ask for that approval under **Needed from you**' \
	'missing commit approval'
require_phrase "$SESSION_POLICY" \
	'name the exact worktree and changes' \
	'exact worktree evidence'
require_phrase "$SESSION_POLICY" \
	'no session-owned repository changes remain uncommitted' \
	'ready-to-close Git gate'
require_phrase "$SESSION_POLICY" \
	'Do not rely on an earlier status snapshot.' \
	'live status requirement'
require_phrase "$CORE_POLICY" \
	'Uncommitted session-owned changes are **Left to capture**' \
	'core prompt Git capture rule'

printf 'PASS: What next policy cannot hide session-owned uncommitted work\n'
