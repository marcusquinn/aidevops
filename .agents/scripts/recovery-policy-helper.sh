#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Read-only repo recovery authority from one pinned default-branch revision.
# Usage: recovery-policy-helper.sh <owner/repo>

[[ "${BASH_SOURCE[0]}" == "$0" ]] && set -euo pipefail

_recovery_policy_file() {
	local repo="$1"
	local revision="$2"
	local path="$3"
	local response=""
	response=$(gh api -X GET "repos/${repo}/contents/${path}" -f ref="$revision") || return 1
	printf '%s' "$response" |
		jq -er 'select(.type == "file" and .encoding == "base64" and .size <= 65536) | .content | @base64d' || return 1
	return 0
}

recovery_policy_load() {
	local repo="${1:-}"
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	local metadata="" branch="" revision="" config="" pointer="" path="" heading="" document=""
	metadata=$(gh api "repos/${repo}") || return 1
	#aidevops:trust-boundary — remote policy is authority only for a writer on
	# this repo, and only from its committed default branch, never a PR checkout.
	printf '%s' "$metadata" | jq -e '.permissions | (.admin == true or .maintain == true or .push == true)' >/dev/null || return 1
	branch=$(printf '%s' "$metadata" | jq -er '.default_branch | select(type == "string" and length > 0)') || return 1
	revision=$(gh api -X GET "repos/${repo}/commits" -f sha="$branch" -f per_page=1 --jq '.[0].sha') || return 1
	[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return 1
	config=$(_recovery_policy_file "$repo" "$revision" .aidevops.json) || return 1
	pointer=$(printf '%s' "$config" | jq -er '.recovery_policy | select(type == "string" and length > 0)') || return 1
	# A repository-relative Markdown file plus an exact ATX heading, not a URL.
	path="${pointer%%#*}"
	heading="${pointer#*#}"
	[[ "$pointer" == *'#'* && "$path" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*\.md$ && -n "$heading" ]] || return 1
	case "/$path/" in */../* | */./*) return 1 ;; esac
	document=$(_recovery_policy_file "$repo" "$revision" "$path") || return 1
	# Parse only the declared section. No evaluation, includes or local file reads.
	# shellcheck disable=SC2016 # Python regex end anchors are not shell expansions.
	printf '%s' "$document" | python3 -c '
import json, re, sys
repo, revision, path, heading = sys.argv[1:]
lines = sys.stdin.read().splitlines()
matches = [(i, len(m[1])) for i, line in enumerate(lines)
           if (m := re.fullmatch(r"(#{1,6}) +(.+?) *", line)) and m[2] == heading]
if len(matches) != 1:
    sys.exit("policy: heading must occur exactly once")
start, level = matches[0]
end = len(lines)
for i in range(start + 1, len(lines)):
    m = re.match(r"^(#{1,6}) +", lines[i])
    if m and len(m[1]) <= level:
        end = i
        break
section = "\n".join(lines[start + 1:end])
blocks = re.findall(r"^```json\s*\n(.*?)\n``` *$", section, re.M | re.S)
if len(blocks) != 1:
    sys.exit("policy: section requires one JSON block")
policy = json.loads(blocks[0])
actions = policy.get("actions") if isinstance(policy, dict) else None
allowed = {"outlier_hold", "session_cap_split", "brief_authority"}
if not isinstance(actions, dict) or not actions.keys() <= allowed:
    sys.exit("policy: unknown action or invalid actions object")
for name, action in actions.items():
    if not isinstance(action, dict):
        sys.exit("policy: invalid action")
    conditions, labels = action.get("conditions"), action.get("labels")
    if not (isinstance(conditions, list) and conditions and
            all(isinstance(c, str) and c.strip() for c in conditions) and
            isinstance(action.get("issue_template"), str) and action["issue_template"].strip() and
            isinstance(labels, list) and labels and
            all(isinstance(l, str) and l.strip() for l in labels)):
        sys.exit("policy: conditions, issue_template and labels are required")
    if name == "outlier_hold" and "hold-for-review" not in labels:
        sys.exit("policy: outlier holds must retain hold-for-review")
    if name == "session_cap_split" and not (
            type(action.get("session_budget")) is int and action["session_budget"] > 0 and
            isinstance(action.get("split_pattern"), str) and action["split_pattern"].strip()):
        sys.exit("policy: split requires positive session_budget and split_pattern")
print(json.dumps(dict(repo=repo, revision=revision, path=path, heading=heading, actions=actions)))
' "$repo" "$revision" "$path" "$heading" || return 1
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	recovery_policy_load "$@"
fi
