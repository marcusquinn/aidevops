#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared issue-body hold/defer marker detection.
#
# Operational hold phrases ("on hold", "hold for ...", "paused", ...) count only
# at the start of a normalized line (after list/quote/heading/emphasis prefixes).
# Fenced blocks and HTML comments are skipped and table rows are rejected, so
# explanatory prose such as "neither is a hold for this part" is not a hold.

[[ -n "${_ISSUE_HOLD_MARKER_LIB_LOADED:-}" ]] && return 0
_ISSUE_HOLD_MARKER_LIB_LOADED=1

_ihm_normalize_hold_line() {
	local line="$1"
	local prefix=""
	local count=0
	local quote_re='^>[[:space:]]*'
	local list_re='^([-+*]|[0-9]+[.)])[[:space:]]+'
	local checkbox_re='^\[[ xX]\][[:space:]]+'
	local heading_re='^#{1,6}[[:space:]]+'
	local emphasis_re='^(\*\*|__|\*|_)'

	while [[ "$count" -lt 8 ]]; do
		prefix=""
		if [[ "$line" =~ ^[[:space:]]+ ]]; then
			prefix="${BASH_REMATCH[0]}"
		elif [[ "$line" =~ $quote_re ]]; then
			prefix="${BASH_REMATCH[0]}"
		elif [[ "$line" =~ $list_re ]]; then
			prefix="${BASH_REMATCH[0]}"
		elif [[ "$line" =~ $checkbox_re ]]; then
			prefix="${BASH_REMATCH[0]}"
		elif [[ "$line" =~ $heading_re ]]; then
			prefix="${BASH_REMATCH[0]}"
		elif [[ "$line" =~ $emphasis_re ]]; then
			prefix="${BASH_REMATCH[0]}"
		else
			break
		fi
		line="${line#"$prefix"}"
		count=$((count + 1))
	done
	printf '%s\n' "$line"
	return 0
}

_ihm_line_is_operational_hold() {
	local line="$1"
	local normalized=""
	local without_pipes=""
	local pipe_count=0
	normalized=$(_ihm_normalize_hold_line "$line") || return 1
	[[ -n "$normalized" ]] || return 1
	without_pipes="${normalized//|/}"
	pipe_count=$((${#normalized} - ${#without_pipes}))
	[[ "$normalized" != \|* && "$normalized" != *\| && "$pipe_count" -lt 2 ]] || return 1
	printf '%s\n' "$normalized" |
		grep -qiE '^(defer[[:space:]]+until|do[-[:space:]]+not[-[:space:]]+dispatch|on[-[:space:]]+hold|hold[[:space:]]+for|paused)([[:space:]:]|$)'
	return $?
}

_ihm_fence_marker() {
	local line="$1"
	local backtick_re='^(`{3,})'
	local tilde_re='^(~{3,})'
	if [[ "$line" =~ $backtick_re || "$line" =~ $tilde_re ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

_ihm_fence_closes() {
	local line="$1"
	local opener="$2"
	local candidate=""
	local remainder=""
	candidate=$(_ihm_fence_marker "$line") || return 1
	[[ "${candidate:0:1}" == "${opener:0:1}" && "${#candidate}" -ge "${#opener}" ]] || return 1
	remainder="${line#"$candidate"}"
	[[ "$remainder" =~ ^[[:space:]]*$ ]]
	return $?
}

# issue_hold_text_has_operational_hold — line-anchored operational hold check.
# Args: $1=text. Returns 0 when a hold phrase leads a line outside fences/comments.
issue_hold_text_has_operational_hold() {
	local text="$1"
	local line=""
	local before_comment=""
	local comment_tail=""
	local normalized=""
	local in_comment=false
	local fence_marker=""

	while IFS= read -r line || [[ -n "$line" ]]; do
		normalized=$(_ihm_normalize_hold_line "$line") || return 1
		if [[ -n "$fence_marker" ]]; then
			_ihm_fence_closes "$normalized" "$fence_marker" && fence_marker=""
			continue
		fi
		if [[ "$in_comment" == "true" ]]; then
			[[ "$line" == *"-->"* ]] || continue
			line="${line#*-->}"
			in_comment=false
		fi
		while [[ "$line" == *"<!--"* ]]; do
			before_comment="${line%%<!--*}"
			comment_tail="${line#*<!--}"
			if [[ "$comment_tail" == *"-->"* ]]; then
				line="${before_comment}${comment_tail#*-->}"
			else
				line="$before_comment"
				in_comment=true
				break
			fi
		done
		normalized=$(_ihm_normalize_hold_line "$line") || return 1
		fence_marker=$(_ihm_fence_marker "$normalized" || true)
		[[ -z "$fence_marker" ]] || continue
		_ihm_line_is_operational_hold "$line" && return 0
	done <<<"$text"
	return 1
}

# issue_body_has_defer_marker — detect an explicit non-dispatch hold in issue text.
# HUMAN_UNBLOCK_REQUIRED is a strong marker anywhere in the body; other phrases
# must lead a line.
# Args: $1=issue body
# Output: true or false
issue_body_has_defer_marker() {
	local body="$1"
	if printf '%s' "$body" | grep -qE 'HUMAN_UNBLOCK_REQUIRED' ||
		issue_hold_text_has_operational_hold "$body"; then
		printf 'true\n'
	else
		printf 'false\n'
	fi
	return 0
}
