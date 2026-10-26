#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEP_GRAPH="${SCRIPT_DIR}/../pulse-dep-graph.sh"

# shellcheck source=../pulse-dep-graph.sh
source "$DEP_GRAPH"

# shellcheck disable=SC2016 # JSON fixture is intentionally literal.
fixture='[
  {"number":1,"title":"t1: root","body":"","labels":[],"state":"OPEN"},
  {"number":2,"title":"t2.1: child","body":"**Blocked by:** `t1`, #1\nDefer until next cycle","labels":[],"state":"OPEN"},
  {"number":3,"title":"Not a task","body":"blocked-by:t2.1,t999","labels":[{"name":"blocked-by:#2"}],"state":"OPEN"},
  {"number":4,"title":"to0aaaaaaaaaaaaaaaaaaaaaaaaa-12.3: namespaced","body":"BLOCKED BY t1","labels":[],"state":"CLOSED"},
  {"number":5,"title":"t5: self edge","body":"blocked-by:t5,#5","labels":[{"name":"blocked-by:t1"}],"state":"OPEN"},
  {"number":6,"title":"t6: malformed body","body":"blocked-by:t001","labels":[],"state":"OPEN"},
  {"number":7,"title":"t7: malformed label","body":"","labels":[{"name":"blocked-by:t001"}],"state":"OPEN"},
  {"number":"8","title":"t8: string number","body":"paused: awaiting decision","labels":[{"name":"blocked-by:#2"}],"state":"open"},
  {"number":"invalid","title":"t9: ignored","body":"blocked-by:t1","labels":[],"state":"OPEN"},
  {"number":10,"title":"t10: closed hold","body":"on hold","labels":[],"state":"CLOSED"},
  {"number":11,"title":"t1: duplicate task mapping","body":"blocked-by:#2,#2","labels":[],"state":"OPEN"},
  {"number":12,"title":"t12: adjacent brief paths","body":"blocked-by:todo/tasks/t1-brief.md,todo/tasks/t2.1-brief.md","labels":[],"state":"OPEN"}
]'

reference=$(_dep_graph_build_repo_data_reference "$fixture" | jq -S -c .)
reduced=$(_dep_graph_reduce_issues_json "$fixture" | jq -S -c .)

if [[ "$reference" != "$reduced" ]]; then
	printf 'FAIL dependency graph jq reduce differs from reference\n' >&2
	printf 'reference=%s\nreduced=%s\n' "$reference" "$reduced" >&2
	exit 1
fi

# Exercise both production parsers against explicit expectations, including the
# resolved-predecessor case: dependency edges must survive independently of holds.
# shellcheck disable=SC2016 # Markdown backticks in fixtures are literal.
hold_cases=$(jq -cn '[
  [false, "Other rows belong to other parts; neither is a hold for this part."],
  [false, "Historical navigation holds are documented here."],
  [true, "> - [ ] **On hold: pending human review**"],
  [true, "  1. __Defer until next cycle__"],
  [true, "### *Do--not dispatch: awaiting worker*"],
  [true, "+ Hold for approval"],
  [true, "Paused"],
  [false, "On holding is not a directive"],
  [false, "Hold format is historical"],
  [false, "```text\nOn hold: example\n```"],
  [false, "> ~~~~\n> Hold for example\n> ~~~\n> On hold: still fenced\n> ~~~~"],
  [true, "````\nOn hold: example\n```\n````\nPaused: actual hold"],
  [false, "<!-- On hold: hidden -->"],
  [false, "<!--\nPaused: hidden\n--> ordinary prose"],
  [true, "<!-- hidden -->On <!-- hidden -->hold: actual"],
  [true, "<!-- hidden\n--> Hold for approval"],
  [true, "<!-- ``` -->\nPaused: commented fence is not an opener\n```"],
  [false, "```\n<!--\n```\nOrdinary prose"],
  [true, "```\n<!--\n```\nOn hold: comments inside fences ignored"],
  [false, "| On hold | historical |"],
  [false, "On hold | historical |"],
  [false, "On hold |"],
  [true, "On hold: human | worker"],
  [true, "<!-- HUMAN_UNBLOCK_REQUIRED -->"],
  [true, "```\nHUMAN_UNBLOCK_REQUIRED\n```"],
  [false, "human_unblock_required"],
  [true, "Do-not-dispatch"],
  [true, "ON   HOLD: human"],
  [true, "Defer\tuntil: next cycle"]
]')
hold_fixture=$(jq -cn --argjson cases "$hold_cases" '
  [{number: 1, title: "t1: resolved predecessor", body: "", labels: [], state: "CLOSED"}]
  + [$cases | to_entries[] | {
    number: (.key + 2), title: ("hold case " + (.key | tostring)),
    body: ("Blocked by: #1\n" + .value[1]), labels: [], state: "OPEN"
  }]')
reference=$(_dep_graph_build_repo_data_reference "$hold_fixture" | jq -S -c .)
reduced=$(_dep_graph_reduce_issues_json "$hold_fixture" | jq -S -c .)
if [[ "$reference" != "$reduced" ]]; then
	printf 'FAIL hold classification differs from shared shell parser\nreference=%s\nreduced=%s\n' "$reference" "$reduced" >&2
	exit 1
fi
if ! jq -en --argjson graph "$reduced" --argjson cases "$hold_cases" '
  $graph.closed_issues == [1] and
  all($cases | to_entries[];
    ((.key + 2) | tostring) as $key | .value[0] as $expected |
    $graph.blocked_by[$key].issue_nums == ["1"] and
    $graph.blocked_by[$key].has_defer_marker == $expected and
    (($graph.defer_flags[$key] // false) == $expected))' >/dev/null; then
	printf 'FAIL hold classification expectations or independent dependency edges\n' >&2
	exit 1
fi

if [[ "${PULSE_DEP_GRAPH_BENCHMARK:-0}" == "1" ]]; then
	large_fixture=$(jq -cn '[range(1; 501) as $n | {
		number: $n,
		title: ("t" + ($n | tostring) + ": benchmark"),
		body: (if $n > 1 then "blocked-by:t1,#1" else "" end),
		labels: [],
		state: "OPEN"
	}]')
	reference_start=$(date +%s)
	_dep_graph_build_repo_data_reference "$large_fixture" >/dev/null
	reference_seconds=$(($(date +%s) - reference_start))
	reduced_start=$(date +%s)
	_dep_graph_reduce_issues_json "$large_fixture" >/dev/null
	reduced_seconds=$(($(date +%s) - reduced_start))
	printf 'BENCHMARK issues=500 reference_seconds=%s reduce_seconds=%s\n' "$reference_seconds" "$reduced_seconds"
fi

printf 'PASS dependency graph jq reduce matches reference\n'
exit 0
