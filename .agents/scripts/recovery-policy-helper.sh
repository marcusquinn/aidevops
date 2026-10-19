#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# =============================================================================
# recovery-policy-helper.sh — read-only repo-delegated queue recovery policy
# (GH#35129). Resolves `.aidevops.json` `recovery_policy` ("path.md#Heading")
# and the referenced section's single fenced JSON block from ONE pinned
# remote default-branch commit. Never reads managed repository directories,
# never evaluates policy text, never writes.
#
# Usage: recovery-policy-helper.sh <owner/repo>
#
# Exit codes:
#   0  valid policy; stdout is {repo, revision, path, heading, actions}
#   3  no policy declared (no .aidevops.json or no recovery_policy key):
#      existing recovery behaviour applies
#   1  invalid policy, insufficient access or API failure: fail closed,
#      existing recovery behaviour applies
# Reference: reference/recovery-policy.md
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "$0" ]] && set -euo pipefail

RECOVERY_POLICY_NONE=3

# Print one repository file's decoded content at an exact revision.
# Returns 0 on success, RECOVERY_POLICY_NONE on HTTP 404, 1 otherwise.
_recovery_policy_file() {
	local repo="$1"
	local revision="$2"
	local path="$3"
	local response=""
	if ! response=$(gh api -X GET "repos/${repo}/contents/${path}" -f ref="$revision" 2>&1); then
		[[ "$response" == *"HTTP 404"* ]] && return "$RECOVERY_POLICY_NONE"
		return 1
	fi
	# The contents API wraps base64 at 60 columns; jq's @base64d rejects the
	# embedded newlines, so strip whitespace before decoding.
	printf '%s' "$response" |
		jq -er 'select(.type == "file" and .encoding == "base64" and .size <= 65536)
			| .content | gsub("\\s"; "") | @base64d' || return 1
	return 0
}

# Validate the declared section and print the normalized policy JSON.
# Policy text is data: no includes, evaluation or local file access.
_recovery_policy_parse() {
	local repo="$1"
	local revision="$2"
	local path="$3"
	local heading="$4"
	local document="$5"
	# shellcheck disable=SC2016 # Python regex anchors are not shell expansions.
	printf '%s' "$document" | python3 -c '
import json, re, sys
repo, revision, path, heading = sys.argv[1:]
lines = sys.stdin.read().splitlines()
# One CommonMark-style fence scanner: a fence closes only with the same
# character and at least the opening length. Headings and json blocks count
# only at top level; anything inside another fence is example content.
structural, blocks, fence, body = [], [], None, []
for i, line in enumerate(lines):
    m = re.match(r"^ {0,3}(`{3,}|~{3,})[ \t]*(.*?)[ \t]*$", line)
    if fence is None:
        if m and not (m[1][0] == "`" and "`" in m[2]):
            fence = (m[1][0], len(m[1]), m[2].split()[0].lower() if m[2] else "", i)
            body = []
            continue
        h = re.fullmatch(r"(#{1,6}) +(.+?)(?: +#+)? *", line)
        if h:
            structural.append((i, len(h[1]), h[2]))
        continue
    if m and not m[2] and m[1][0] == fence[0] and len(m[1]) >= fence[1]:
        if fence[2] == "json":
            blocks.append((fence[3], "\n".join(body)))
        fence = None
        continue
    body.append(line)
matches = [(i, level) for i, level, text in structural if text == heading]
if len(matches) != 1:
    sys.exit("policy: heading must occur exactly once")
start, level = matches[0]
end = next((i for i, lvl, _ in structural if i > start and lvl <= level), len(lines))
section_blocks = [text for i, text in blocks if start < i < end]
if len(section_blocks) != 1:
    sys.exit("policy: section requires exactly one top-level json fenced block")
try:
    policy = json.loads(section_blocks[0])
except ValueError as exc:
    sys.exit(f"policy: invalid JSON: {exc}")
actions = policy.get("actions") if isinstance(policy, dict) else None
allowed = {"outlier_hold", "session_cap_split", "brief_authority"}
if not isinstance(actions, dict) or not actions.keys() <= allowed:
    sys.exit("policy: unknown action or invalid actions object")
def text(value):
    return isinstance(value, str) and value.strip() != ""
# Lifecycle, origin and approval labels belong to guarded helpers and trust
# gates; a repo policy can never apply them directly.
protected = re.compile(r"^(status:|origin:|ai-approved$|needs-maintainer-review$|external-contributor$)")
for name, action in actions.items():
    if not isinstance(action, dict):
        sys.exit(f"policy: {name} must be an object")
    conditions, labels = action.get("conditions"), action.get("labels")
    if not (isinstance(conditions, list) and conditions and all(text(c) for c in conditions)):
        sys.exit(f"policy: {name} requires non-empty conditions")
    if not text(action.get("issue_template")):
        sys.exit(f"policy: {name} requires issue_template")
    if not (isinstance(labels, list) and labels and all(text(l) for l in labels)):
        sys.exit(f"policy: {name} requires non-empty labels")
    # GitHub label names are case-insensitive; compare case-folded, trimmed.
    folded = [l.strip().casefold() for l in labels]
    if any(protected.match(l) for l in folded):
        sys.exit(f"policy: {name} names a protected lifecycle/trust label")
    if name == "outlier_hold" and "hold-for-review" not in folded:
        sys.exit("policy: outlier_hold must retain hold-for-review")
    if name == "session_cap_split" and not (
            type(action.get("session_budget")) is int and action["session_budget"] > 0 and
            text(action.get("split_pattern"))):
        sys.exit("policy: session_cap_split requires positive session_budget and split_pattern")
print(json.dumps(dict(repo=repo, revision=revision, path=path, heading=heading, actions=actions)))
' "$repo" "$revision" "$path" "$heading" || return 1
	return 0
}

recovery_policy_load() {
	local repo="${1:-}"
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	local metadata="" branch="" revision="" config="" pointer="" path="" heading="" document="" rc=0
	metadata=$(gh api "repos/${repo}") || return 1
	#aidevops:trust-boundary — remote policy is authority only for a writer on
	# this repo, and only from its committed default branch, never a PR checkout.
	printf '%s' "$metadata" | jq -e '.permissions | (.admin == true or .maintain == true or .push == true)' >/dev/null || return 1
	branch=$(printf '%s' "$metadata" | jq -er '.default_branch | select(type == "string" and length > 0)') || return 1
	revision=$(gh api -X GET "repos/${repo}/commits" -f sha="$branch" -f per_page=1 --jq '.[0].sha') || return 1
	[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return 1
	config=$(_recovery_policy_file "$repo" "$revision" .aidevops.json) || {
		rc=$?
		return "$rc"
	}
	printf '%s' "$config" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
	printf '%s' "$config" | jq -e 'has("recovery_policy")' >/dev/null || return "$RECOVERY_POLICY_NONE"
	pointer=$(printf '%s' "$config" | jq -er '.recovery_policy | select(type == "string" and length > 0)') || return 1
	# A repository-relative Markdown file plus an exact ATX heading, not a URL.
	path="${pointer%%#*}"
	heading="${pointer#*#}"
	[[ "$pointer" == *'#'* && "$path" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*\.md$ && -n "$heading" ]] || return 1
	case "/$path/" in */../* | */./*) return 1 ;; esac
	# A declared but missing document is invalid, not "no policy".
	document=$(_recovery_policy_file "$repo" "$revision" "$path") || return 1
	_recovery_policy_parse "$repo" "$revision" "$path" "$heading" "$document" || return 1
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	recovery_policy_load "$@"
fi
