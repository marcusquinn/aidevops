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

# GH#33881: one value grammar, pinned on both the bash path and the production
# jq reducer. Outputs are sorted so the two paths compare directly.
REDUCE_FILTER="$REPO_ROOT/.agents/scripts/pulse-dep-graph-reduce.jq"

extract_sorted_bash() {
	local body="$1"
	local tids nums
	tids=$(bash -c "source '$DEP_GRAPH' 2>/dev/null; _blocked_by_extract_tids \"\$1\"" _ "$body" | sort -u | paste -sd, -)
	nums=$(bash -c "source '$DEP_GRAPH' 2>/dev/null; _blocked_by_extract_nums \"\$1\"" _ "$body" | sort -u | paste -sd, -)
	printf '%s|%s' "$tids" "$nums"
	return 0
}

extract_sorted_jq() {
	local body="$1"
	jq -n --arg body "$body" '[{number: 900, title: "t900: subject", body: $body, labels: [], state: "OPEN"}]' |
		jq -r -f "$REDUCE_FILTER" |
		jq -r '(.blocked_by["900"] // {task_ids: [], issue_nums: []})
			| "\(.task_ids | sort | join(","))|\(.issue_nums | sort | join(","))"'
	return 0
}

check_grammar() {
	local label="$1" body="$2" want="$3"
	local got_bash got_jq
	got_bash=$(extract_sorted_bash "$body")
	got_jq=$(extract_sorted_jq "$body")
	if [[ "$got_bash" == "$want" && "$got_jq" == "$want" ]]; then
		printf 'PASS: %s\n' "$label"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL: %s\n  want=%q bash=%q jq=%q\n' "$label" "$want" "$got_bash" "$got_jq" >&2
		fail_count=$((fail_count + 1))
	fi
	return 0
}

check_grammar 'negation nothing with range' '- **Blocked by:** nothing. The 11 template tasks (t139–t149) are independent and may run in parallel.' '|'
check_grammar 'negation none with merged tasks' '- **Blocked by:** none (t136 and t138 merged).' '|'
check_grammar 'negation none with prose' '- **Blocked by:** none (independent; touches the same function as #31001, so expect a trivial rebase)' '|'
check_grammar 'negation n/a' 'blocked-by: N/A, see #12' '|'
check_grammar 'negation em dash' '**Blocked by:** — (t5 shipped)' '|'
check_grammar 'list stops at trailing prose' '**Blocked by:** `t143`, #18429 (schema lands first; see t999 and #7)' 't143|18429'
check_grammar 'backticked compact list' '**Blocked by:** `t18467,t18458`' 't18458,t18467|'
check_grammar 'slash alias with GH ref' '- **Blocked by:** t18414 / GH#31459' 't18414|31459'
check_grammar 'repository references' '**Blocked by:** owner/repo#12 and owner/repo #13' '|12,13'
check_grammar 'bold value' 'Blocked by: **#10**' '|10'
check_grammar 'prose-led value fails closed' '- **Blocked by:** native relationship to t18418 / #31685' 't18418|31685'
check_grammar 'malformed list token fails closed' 'blocked-by:t143,t001' '__malformed__|'
check_grammar 'unchanged bare list' 'blocked-by:t1,t2' 't1,t2|'

printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
