#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Upstream release gates (GH#37696). An issue that must wait until a
# third-party upstream tags a release containing a specific commit declares,
# on its own line in the issue body:
#
#   <!-- aidevops:upstream-release-gate repo=OWNER/REPO commit=<40-hex SHA> -->
#
# The gate is satisfied when one of the URG_MAX_TAGS (default 3) highest
# version-sorted tags among the first 100 returned for OWNER/REPO contains the
# commit (GitHub compare status `ahead` or `identical`). Tags are
# used rather than GitHub Releases because many upstreams only push tags.
# This library only reads GitHub; the dependency reconciler owns mutation.

[[ -n "${_UPSTREAM_RELEASE_GATE_LIB_LOADED:-}" ]] && return 0
_UPSTREAM_RELEASE_GATE_LIB_LOADED=1

URG_NOT_READY=2
URG_MAX_GATES=5
URG_MARKER_RE='^<!-- aidevops:upstream-release-gate repo=[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+ commit=[0-9a-f]{40} -->$'

# Print trimmed body lines that open a gate marker comment, skipping fenced
# code blocks (``` or ~~~; a fence closes on the same character with at least
# the opener's length). Inline prose mentions do not start a line, so only
# deliberate markers and malformed attempts at one are returned.
_urg_marker_lines() {
	local body="$1"
	printf '%s\n' "$body" | tr -d '\r' | awk '
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			sub(/[ \t]+$/, "", line)
			if (match(line, /^(```+|~~~+)/)) {
				run = substr(line, 1, RLENGTH)
				if (fence == "") { fence = run; next }
				rest = substr(line, RLENGTH + 1)
				if (substr(run, 1, 1) == substr(fence, 1, 1) && length(run) >= length(fence) && rest ~ /^[ \t]*$/) fence = ""
				next
			}
			if (fence != "") next
			if (line ~ /^<!--[ \t]*aidevops:upstream-release-gate/) print line
		}'
	return 0
}

# Print one "OWNER/REPO SHA" line per well-formed gate marker.
upstream_release_gates() {
	local body="$1"
	_urg_marker_lines "$body" | grep -E "$URG_MARKER_RE" |
		sed -E 's/^<!-- aidevops:upstream-release-gate repo=([^ ]+) commit=([0-9a-f]{40}) -->$/\1 \2/' | sort -u || true
	return 0
}

# Return 0 when the body declares any gate marker, well-formed or not.
upstream_release_gate_declared() {
	local body="$1"
	[[ -n "$(_urg_marker_lines "$body")" ]]
	return $?
}

# Return 0 when there are 1..URG_MAX_GATES markers and every one is well formed.
upstream_release_gates_well_formed() {
	local body="$1"
	local lines="" declared=0 valid=0
	lines=$(_urg_marker_lines "$body")
	[[ -n "$lines" ]] || return 1
	declared=$(printf '%s\n' "$lines" | grep -c . || true)
	valid=$(printf '%s\n' "$lines" | grep -cE "$URG_MARKER_RE" || true)
	[[ "$declared" -le "$URG_MAX_GATES" && "$declared" == "${valid:-0}" ]]
	return $?
}

# Check one gate. Prints "TAG TAG_SHA" when satisfied. Returns 0 satisfied,
# URG_NOT_READY when no checked tag contains the commit, 1 on API/shape error.
upstream_release_gate_satisfied() {
	local upstream="$1"
	local commit="$2"
	local max_tags="${URG_MAX_TAGS:-3}"
	local tags="" tag="" tag_sha="" status=""
	[[ "$upstream" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
	[[ "$max_tags" =~ ^[1-9][0-9]?$ ]] || max_tags=3
	# The tags endpoint orders names roughly reverse-lexically (v1.9 above v1.10),
	# so read one page and version-sort locally before taking the newest names.
	tags=$(gh api "repos/${upstream}/tags?per_page=100" \
		--jq 'if type == "array" then .[] | "\(.name) \(.commit.sha)" else error("not an array") end' 2>/dev/null) || return 1
	if [[ "$(printf '%s\n' "$tags" | grep -c . || true)" -ge 100 ]]; then
		printf '[upstream-release-gate] %s has 100+ tags; newer versions beyond the first page may be missed\n' "$upstream" >&2
	fi
	tags=$(printf '%s\n' "$tags" | sort -rV | sed -n "1,${max_tags}p")
	while read -r tag tag_sha; do
		[[ -n "$tag" ]] || continue
		[[ "$tag_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
		status=$(gh api "repos/${upstream}/compare/${commit}...${tag_sha}?per_page=1" --jq '.status' 2>/dev/null) || return 1
		case "$status" in
		ahead | identical)
			printf '%s %s\n' "$tag" "$tag_sha"
			return 0
			;;
		behind | diverged) ;;
		*) return 1 ;;
		esac
	done <<<"$tags"
	return "$URG_NOT_READY"
}

# Evaluate every gate in an issue body. Returns 0 when all are satisfied,
# URG_NOT_READY when any is unsatisfied or malformed, 1 on API error.
upstream_release_gates_ready() {
	local body="$1"
	local log_prefix="${2:-[upstream-release-gate]}"
	local gates="" upstream="" commit="" proof="" rc=0
	if ! upstream_release_gates_well_formed "$body"; then
		printf '%s malformed upstream-release-gate marker; leaving blocked\n' "$log_prefix" >&2
		return "$URG_NOT_READY"
	fi
	gates=$(upstream_release_gates "$body")
	while read -r upstream commit; do
		[[ -n "$upstream" ]] || continue
		rc=0
		proof=$(upstream_release_gate_satisfied "$upstream" "$commit") || rc=$?
		if [[ "$rc" -eq "$URG_NOT_READY" ]]; then
			printf '%s %s@%s is not in a recent tag yet\n' "$log_prefix" "$upstream" "${commit:0:12}" >&2
			return "$rc"
		elif [[ "$rc" -ne 0 ]]; then
			printf '%s %s@%s could not be checked (API or response error)\n' "$log_prefix" "$upstream" "${commit:0:12}" >&2
			return 1
		fi
		printf '%s %s@%s satisfied by tag %s\n' "$log_prefix" "$upstream" "${commit:0:12}" "$proof" >&2
	done <<<"$gates"
	return 0
}
