#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# counter-trend-delta.sh — Detect 3x regression in pulse counter rate (t3072).
#
# Reads $STATS_FILE (default ~/.aidevops/logs/pulse-stats.json) and computes
# the count of timestamps in the last $WINDOW_SECONDS vs the prior window of
# the same length. Flags any counter where recent_count >= prior_count*3 AND
# prior_count >= MIN_BASELINE (so a quiet period followed by a single tick
# does not trip the detector).
#
# Output (stdout, only when returning 1):
#   One JSON object per line: {id, title, body}
#
# Inputs (env, all overridable for tests):
#   STATS_FILE        path to pulse-stats.json (default ~/.aidevops/logs/pulse-stats.json)
#   NOW_EPOCH         "current" epoch (default $(date +%s))
#   WINDOW_SECONDS    window size in seconds (default 14400 = 4h)
#   REGRESSION_MULT   multiplier threshold (default 3)
#   MIN_BASELINE      minimum prior-window count to flag (default 3)
#
# Function contract:
#   runtime_audit_check  — returns 0 (no finding) or 1 (finding)
#
# Anti-pattern guard: this detector never makes a network or gh call.
# It reads pulse-stats.json only; reading the file we want to surface
# regressions in is the entire point.

# shellcheck shell=bash

runtime_audit_id() { printf 'counter-trend-delta\n'; return 0; }

runtime_audit_check() {
	local stats_file="${STATS_FILE:-${HOME}/.aidevops/logs/pulse-stats.json}"
	local now_epoch="${NOW_EPOCH:-$(date +%s)}"
	local window="${WINDOW_SECONDS:-14400}"
	local mult="${REGRESSION_MULT:-3}"
	local min_baseline="${MIN_BASELINE:-3}"

	if [[ ! -f "$stats_file" ]]; then
		return 0
	fi

	local recent_start=$((now_epoch - window))
	local prior_start=$((recent_start - window))

	# Use jq to compute regressions in one pass. Output is one line per
	# regressed counter: "<name>\t<recent>\t<prior>\t<ratio>".
	local regressions
	regressions=$(jq -r --argjson now "$now_epoch" --argjson win "$window" \
		--argjson mult "$mult" --argjson min_base "$min_baseline" '
		.counters // {}
		| to_entries
		| map(select(.value | type == "array"))
		| map({
			name: .key,
			recent: ([.value[] | select(. >= ($now - $win) and . <= $now)] | length),
			prior:  ([.value[] | select(. >= ($now - 2*$win) and . < ($now - $win))] | length)
		})
		| map(select(.prior >= $min_base and .recent >= .prior * $mult))
		| .[] | "\(.name)\t\(.recent)\t\(.prior)\t\((.recent/.prior)|tostring|.[0:5])"
	' "$stats_file" 2>/dev/null) || regressions=""

	if [[ -z "$regressions" ]]; then
		return 0
	fi

	# Build evidence table for the body
	local evidence_table
	evidence_table=$(printf '| Counter | Last %dh | Prior %dh | Ratio |\n| --- | --- | --- | --- |\n' \
		"$((window / 3600))" "$((window / 3600))")
	while IFS=$'\t' read -r name recent prior ratio; do
		# shellcheck disable=SC2016  # intentional literal markdown backticks
		evidence_table+=$(printf '\n| `%s` | %s | %s | %sx |' "$name" "$recent" "$prior" "$ratio")
	done <<<"$regressions"

	local first_counter
	first_counter=$(printf '%s\n' "$regressions" | head -1 | cut -f1)

	local title="runtime-audit: counter regression detected (\`${first_counter}\`)"
	# Build body via temp file — avoids heredoc-inside-$() which breaks Bash 3.2
	# (single quotes in heredoc content confuse the Bash 3.2 $() nesting parser).
	# GH#21782: pre-existing Bash 3.2 compat fix bundled with PyYAML/sed PR.
	local _body_tmp
	_body_tmp=$(mktemp)
	cat >"$_body_tmp" <<MARKDOWN
## Task

A pulse counter has regressed sharply in the last $((window / 3600))h compared to the prior $((window / 3600))h window. This is the kind of trend shift that the supervisor LLM cycle does not detect because it never reads \`pulse-stats.json\` directly — it relies on issue and PR state.

## Evidence

${evidence_table}

Counter source: \`${stats_file/#$HOME/\~}\`

## Why

Sharp counter regressions are the supervisor’s structural blind spot — they appear in operational state long before they manifest as failed issues. Each regression cited above warrants investigation: a 3x-or-greater jump on a counter usually means a config change, a new bottleneck, or a regression in a recently-deployed script.

## How

1. Read the relevant pulse-stats counter array directly: \`jq '.counters.${first_counter}' $stats_file\` and look for the time-stamp clusters.
2. Cross-reference with \`~/.aidevops/logs/pulse-wrapper.log\` for the same window using \`grep\` on the counter name or related script names.
3. Check recent commits to the script that emits this counter: \`git log --since="24 hours ago" -- .agents/scripts/\`.
4. If a fix is identified, file a separate task with the implementation pattern.
5. If no fix is needed (e.g. the regression is a healthy response to load), close this issue with that rationale.

## Acceptance Criteria

1. Root cause identified for each regressed counter listed above.
2. Either a fix PR linked to this issue, or a closing comment explaining why the regression is benign.

## Verification

Run the audit again after the fix lands:
\`\`\`
~/.aidevops/agents/scripts/runtime-health-audit-helper.sh --dry-run
\`\`\`
The regression block for the cited counters should no longer appear.

<!-- aidevops:generator=runtime-audit detector=counter-trend-delta -->
MARKDOWN
	local body
	body=$(cat "$_body_tmp")
	rm -f "$_body_tmp"

	jq -n --arg id "counter-trend-delta" --arg title "$title" --arg body "$body" \
		'{id: $id, title: $title, body: $body}'
	return 1
}
