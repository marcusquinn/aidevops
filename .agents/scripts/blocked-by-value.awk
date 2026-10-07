# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Shared value grammar for blocked-by field lines (GH#33881).
# jq twin: blocker_value_line in pulse-dep-graph-reduce.jq; keep them identical.
#
# Input: lines that begin at a blocked-by label (colon optional). Output: one
# line per input line.
#   - Negation-led value (none, nothing, no, n/a, nil, a dash): the label only,
#     with no references.
#   - Leading reference list: the label followed by the accepted tokens only.
#     The list stops at the first token that is not a reference.
#   - Any other value (prose-led): the original line unchanged, so ambiguous
#     declarations fail closed instead of silently losing a real blocker.
# References: #N, GH#N, owner/repo#N, "owner/repo #N", and task-ID-shaped
# tokens. Invalid task-ID-shaped tokens are kept, so downstream malformed
# detection still fires. Separators: whitespace , ; and & + /
# Backticks and emphasis markers are ignored.

function is_task_like(t,    rest) {
	if (t ~ /^[tT][0-9][A-Za-z0-9.-]*$/) return 1
	if (t ~ /^t[A-Z][A-Za-z0-9.-]*$/) return 1
	if (t ~ /^[tT][oO][A-Za-z0-9]+-[A-Za-z0-9.-]+$/) {
		rest = substr(t, 3)
		return (index(rest, "-") == 27)
	}
	return 0
}

function is_issue(t) {
	return (t ~ /^#[0-9]+$/)
}

function is_ref(t) {
	if (is_issue(t)) return 1
	if (t ~ /^[Gg][Hh]#[0-9]+$/) return 1
	if (t ~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[0-9]+$/) return 1
	return is_task_like(t)
}

function is_slug(t) {
	return (t ~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/)
}

function is_negation(t,    l) {
	l = tolower(t)
	return (l == "none" || l == "nothing" || l == "no" || l == "n/a" || l == "na" || l == "nil" || l == "-" || l == "—" || l == "–")
}

BEGIN {
	label_re = "^[ \t]*(\\*\\*)?blocked[- ]by(\\*\\*)?[ \t]*:?(\\*\\*)?"
}

{
	line = $0
	if (!match(tolower(line), label_re)) {
		print line
		next
	}
	label = substr(line, 1, RLENGTH)
	value = substr(line, RLENGTH + 1)
	gsub(/[`*]/, " ", value)
	n = split(value, raw, /[ \t,;]+/)
	k = 0
	for (i = 1; i <= n; i++) {
		t = raw[i]
		sub(/^[(_]+/, "", t)
		sub(/[_.:!?)]+$/, "", t)
		if (t == "" || tolower(t) == "and" || t == "&" || t == "+" || t == "/") continue
		tok[++k] = t
	}
	if (k == 0 || is_negation(tok[1])) {
		sub(/[ \t]+$/, "", label)
		print label
		next
	}
	out = ""
	i = 1
	while (i <= k) {
		t = tok[i]
		if (is_ref(t)) {
			out = out (out == "" ? "" : ", ") t
			i++
			continue
		}
		if (is_slug(t) && i < k && is_issue(tok[i + 1])) {
			out = out (out == "" ? "" : ", ") t tok[i + 1]
			i += 2
			continue
		}
		break
	}
	if (out == "") {
		print line
	} else {
		sub(/[ \t]+$/, "", label)
		print label " " out
	}
}
