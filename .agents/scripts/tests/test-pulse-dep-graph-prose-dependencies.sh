#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test (GH#33166): pulse-dep-graph.sh must read body dependencies
# only from structured fields, never from prose, inline code spans or fenced
# blocks that merely discuss the dependency syntax.
#
# shellcheck disable=SC2016  # literal markdown backticks are the format under test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEP_GRAPH="$REPO_ROOT/.agents/scripts/pulse-dep-graph.sh"

pass_count=0
fail_count=0

extract() {
	local body="$1"
	local tids nums
	tids=$(bash -c "source '$DEP_GRAPH' 2>/dev/null; _blocked_by_extract_tids \"\$1\" | tr '\n' ',' " _ "$body" | sed 's/,$//')
	nums=$(bash -c "source '$DEP_GRAPH' 2>/dev/null; _blocked_by_extract_nums \"\$1\" | tr '\n' ',' " _ "$body" | sed 's/,$//')
	printf '%s|%s' "$tids" "$nums"
	return 0
}

check() {
	local label="$1" body="$2" want="$3"
	local got
	got=$(extract "$body")
	if [[ "$got" == "$want" ]]; then
		printf 'PASS: %s\n' "$label"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL: %s\n  want=%q got=%q\n' "$label" "$want" "$got" >&2
		fail_count=$((fail_count + 1))
	fi
	return 0
}

# Negative: prose, code spans and fences yield no edges.
check 'prose mention' 'The parser treats blocked-by:t143 in a sentence as real.' '|'
check 'inline code span' 'Example: `blocked-by:t143,#18429` in text.' '|'
check 'code span at line start' '`blocked-by:t143` is the syntax' '|'
check 'blockquote' '> blocked-by:t143' '|'
check 'fenced block' "$(printf 'Intro\n```\nblocked-by:t143\n**Blocked by:** #18429\n```\nEnd')" '|'
check 'html comment' '<!-- blocked-by:t143 -->' '|'
check 'heading only' "$(printf '## Blocked-by\n\nSee t143 and #18429 for context.')" '|'

# Positive: structured fields still yield edges.
check 'bare todo field' 'blocked-by:t135,t145' 't135,t145|'
check 'bare todo issue field' 'blocked-by:#18429,#18430' '|18429,18430'
check 'bold field backticks' '**Blocked by:** `t143`, `t200`' 't143,t200|'
check 'bold field mixed' '**Blocked by:** `t143`, #18429' 't143|18429'
check 'list marker bold field' '- **Blocked by:** `t143`' 't143|'
check 'spaced case-insensitive' 'Blocked By: t143' 't143|'
check 'multiline body' "$(printf 'Why: quoting `blocked-by:t999`.\n\n**Blocked by:** `t143`\n\nMore.')" 't143|'

printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
