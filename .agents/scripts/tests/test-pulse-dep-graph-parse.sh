#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for pulse-dep-graph.sh blocked-by body-text parser.
# Exercises every format combination shipped by the framework to prevent
# format drift from silently re-breaking the dep graph (t2015 / GH#18429).
#
# The parser under test lives at pulse-dep-graph.sh:123-138. We replicate
# the exact shell pipeline here rather than sourcing the file (the helper
# defines the parser inside a function body with repo iteration state).
# The in-test copy MUST stay byte-identical to the helper — if you change
# one, change the other, and this test will catch the regression.
#
# Usage: bash test-pulse-dep-graph-parse.sh

# Test bodies below contain LITERAL markdown backticks inside single quotes.
# The backticks are part of the format under test (emitted by
# brief-template.md:172). SC2016 triggers on "expressions don't expand in
# single quotes" — that is the intent. File-level disable is correct here.
# shellcheck disable=SC2016

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEP_GRAPH="$REPO_ROOT/.agents/scripts/pulse-dep-graph.sh"

if [[ ! -f "$DEP_GRAPH" ]]; then
	echo "FAIL: cannot locate pulse-dep-graph.sh at $DEP_GRAPH" >&2
	exit 1
fi

# Parser under test — mirror of pulse-dep-graph.sh:123-138.
parse_blockers() {
	local body="$1"
	local blocker_lines blocker_tids blocker_nums
	blocker_lines=$(printf '%s' "$body" | grep -ioE '[Bb]locked[- ][Bb]y[^[:cntrl:]]*' || true)
	blocker_tids=$(printf '%s' "$blocker_lines" | grep -oE 't[0-9]+' | grep -oE '[0-9]+' || true)
	blocker_nums=$(printf '%s' "$blocker_lines" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' || true)
	printf 'tids=%s\nnums=%s\n' \
		"$(printf '%s' "$blocker_tids" | tr '\n' ',' | sed 's/,$//')" \
		"$(printf '%s' "$blocker_nums" | tr '\n' ',' | sed 's/,$//')"
}

pass_count=0
fail_count=0

assert_parse() {
	local label="$1" body="$2" want_tids="$3" want_nums="$4"
	local got got_tids got_nums
	got=$(parse_blockers "$body")
	got_tids=$(printf '%s\n' "$got" | awk -F= '/^tids=/ {print $2}')
	got_nums=$(printf '%s\n' "$got" | awk -F= '/^nums=/ {print $2}')
	if [[ "$got_tids" == "$want_tids" && "$got_nums" == "$want_nums" ]]; then
		printf 'PASS: %s\n' "$label"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL: %s\n  body:     %q\n  want_tids=%q got_tids=%q\n  want_nums=%q got_nums=%q\n' \
			"$label" "$body" "$want_tids" "$got_tids" "$want_nums" "$got_nums" >&2
		fail_count=$((fail_count + 1))
	fi
}

# Markdown format (emitted by brief-template.md:172) — the 92% case per GH#18429.
# SC2016: the backticks in the test bodies below are LITERAL markdown characters
# (the exact format the framework emits). Single-quoting is correct and intentional.
# shellcheck disable=SC2016
assert_parse 'markdown single tid' '**Blocked by:** `t143`' '143' ''
assert_parse 'markdown comma tids' '**Blocked by:** `t143`, `t200`' '143,200' ''
assert_parse 'markdown single issue' '**Blocked by:** #18429' '' '18429'
assert_parse 'markdown mixed tid and issue' '**Blocked by:** `t143`, #18429' '143' '18429'
assert_parse 'markdown three comma tids' '**Blocked by:** `t135`, `t145`, `t200`' '135,145,200' ''

# TODO.md bare format.
assert_parse 'todo single tid' 'blocked-by:t135' '135' ''
assert_parse 'todo comma tids' 'blocked-by:t135,t145' '135,145' ''
assert_parse 'todo comma issues' 'blocked-by:#18429,#18430' '' '18429,18430'

# Case variations.
assert_parse 'Blocked By case' 'Blocked By: t143' '143' ''
assert_parse 'BLOCKED-BY case' 'BLOCKED-BY: t200' '200' ''

# No-match baselines — must NOT match anything.
assert_parse 'no blocked-by' 'This task has no dependencies.' '' ''
assert_parse 'tid without keyword' 'References task t143 somewhere.' '' ''

# Multi-line body — blocked-by line is inside a longer issue body.
assert_parse 'multiline body' "$(printf '## Dependencies\n\n**Blocked by:** `t143`\n\nOther text.')" '143' ''

printf '\n'
printf 'Results: %d passed, %d failed\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

printf 'All pulse-dep-graph blocker parse tests passed.\n'
exit 0
