#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#40206: dated holds and exhausted session budgets are shared scheduling data.

# Parse only bounded, explicit reopen syntax from the final assistant report.
# Never reinterpret a permission/input class, or publish the surrounding prose.
_terminal_blocker_recheck_after() {
	local captured="$1" now="${TERMINAL_BLOCKER_NOW_EPOCH:-}"
	[[ "$now" =~ ^[0-9]+$ ]] || now=$(date -u +%s)
	python3 -c '
import datetime as dt, json, re, sys
text = json.load(sys.stdin)["detail"]
now = int(sys.argv[1])
dates = []
for n, unit in re.findall(r"\brecheck\s+after\s+([1-9][0-9]{0,3})\s*(h(?:ours?)?|d(?:ays?)?|minutes?|mins?)\b", text, re.I):
    dates.append(now + int(n) * (86400 if unit.lower().startswith("d") else 3600 if unit.lower().startswith("h") else 60))
for value in re.findall(r"(?:\b(?:recheck\s+)?after\s+|^TERMINAL_BLOCKER_RECHECK_AFTER=)(\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}Z)?)(?![\w:+-])", text, re.I | re.M):
    try:
        dates.append(int(dt.datetime.fromisoformat(value.replace("Z", "+00:00")).replace(tzinfo=dt.timezone.utc).timestamp()))
    except ValueError:
        pass
if dates and max(dates) > now:
    print(dt.datetime.fromtimestamp(max(dates), dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$now" <<<"$captured"
	return $?
}

# Read only authenticated marker comments, not arbitrary issue prose.
_terminal_blocker_observed_recheck_after() {
	local comments="$1" observation="" retry=""
	observation=$(_terminal_blocker_latest_marker "$comments" "$_TBC_OBSERVATION_MARKER revision=") || return 1
	[[ -n "$observation" ]] || return 1
	retry=$(_terminal_blocker_latest_retry_comment "$comments") || retry=""
	_terminal_blocker_retry_after "$retry" "$observation" && return 1
	jq -er '.body | capture("(?m)^Recheck after: (?<at>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$").at | select((try fromdateiso8601 catch 0) > 0)' <<<"$observation" 2>/dev/null
	return $?
}

# A newer OWNER/MEMBER retry may override scheduling, never source access.
# Expiry wakes supervisor assessment, not an implementation worker: other
# ledger holds (consent, scope, session budget) still need their own decisions.
terminal_blocker_dated_hold_active() {
	local comments="$1" due="" now="${TERMINAL_BLOCKER_NOW_EPOCH:-}"
	due=$(_terminal_blocker_observed_recheck_after "$comments") || return 1
	due=$(jq -nr --arg at "$due" '$at | fromdateiso8601') || return 1
	[[ "$now" =~ ^[0-9]+$ ]] || now=$(date -u +%s)
	[[ "$now" -lt "$due" ]] || return 1
	printf 'TERMINAL_BLOCKER_DATED_HOLD recheck_after_epoch=%s\n' "$due"
	return 0
}

# A cap is a supervisor checkpoint, not authority for this helper to split work.
# Count distinct merged PRs explicitly cross-referencing this issue, never local
# attempt counters. Unavailable/incomplete evidence keeps a declared cap held.
terminal_blocker_session_cap_hold_active() {
	local issue_json="$1" repo="$2" issue="$3" cap="" timeline="" numbers="" number="" pr="" count=0 merged=""
	cap=$(python3 -c '
import json, re, sys
body = json.load(sys.stdin).get("body", "")
patterns = [r"\b([1-9][0-9]*)[- ]session\s+(?:cap|budget)\b", r"\b(?:session[_ -](?:cap|budget)|max[_ -]sessions)\s*[:=]\s*([1-9][0-9]*)\b"]
values = [int(n) for p in patterns for n in re.findall(p, body, re.I)]
if re.search(r"\btwo[- ]session\s+(?:cap|budget)\b", body, re.I): values.append(2)
if values: print(min(values))
' <<<"$issue_json") || return 1
	[[ "$cap" =~ ^[1-9][0-9]*$ ]] || return 1
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[0-9]+$ ]] || return 0
	timeline=$(gh api --paginate "repos/${repo}/issues/${issue}/timeline?per_page=100" 2>/dev/null) || return 0
	# Cross-repository references do not consume this issue's implementation budget.
	numbers=$(jq -rs --arg repo "$repo" '[.[][] | select(.event == "cross-referenced") | .source.issue
		| select(.pull_request and (((.repository.full_name // (.repository_url // "" | sub("^https://api.github.com/repos/"; ""))) | ascii_downcase) == ($repo | ascii_downcase)))
		| .number] | unique[]' <<<"$timeline") || return 0
	while IFS= read -r number; do
		[[ "$number" =~ ^[0-9]+$ ]] || continue
		pr=$(gh api "repos/${repo}/pulls/${number}" 2>/dev/null) || return 0
		# Partial/checkpoint PRs or explicit For/Ref issue references are evidence
		# of a non-final session; incidental mentions must not spend the budget.
		if jq -e --arg issue "$issue" '.merged_at != null and .merged == true and
			(((.title // "") + "\n" + (.body // "")) | test("(?i)\\b(partial|checkpoint)\\b|\\b(?:For|Ref) #" + $issue + "\\b"))' <<<"$pr" >/dev/null; then
			count=$((count + 1))
			merged="${merged}${merged:+,}${number}"
		fi
		if [[ "$count" -ge "$cap" ]]; then
			printf 'TERMINAL_BLOCKER_SESSION_CAP_HOLD budget=%s merged_prs=%s next_action=session_cap_split\n' "$cap" "$merged"
			return 0
		fi
	done <<<"$numbers"
	return 1
}
