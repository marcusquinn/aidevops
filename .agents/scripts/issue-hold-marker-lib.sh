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

# GH#38821: human-owned hold labels shared by the dependency reconciler and the
# blocked-companion normalizer so the two cannot drift. Space-separated.
ISSUE_HUMAN_HOLD_LABELS="hold-for-review no-auto-dispatch"

# Succeeds when a ",a,b," wrapped label CSV carries a human-owned hold label.
issue_labels_csv_have_human_hold() {
	local csv="$1"
	local hold=""
	for hold in $ISSUE_HUMAN_HOLD_LABELS; do
		[[ "$csv" == *",${hold},"* ]] && return 0
	done
	return 1
}

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
	# BSD/macOS grep -i does not fold U+017F (long s) to "s" the way the jq
	# reducer's Unicode-aware test() does; fold it explicitly so both agree.
	normalized="${normalized//ſ/s}"
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

# GH#39856: machine-readable time gate for date-bound holds.
#   <!-- aidevops:not-before at=2026-11-26T07:00:00Z reason=external_event_date -->
# The marker must stand alone on its line outside fenced code, so documentation
# that quotes it (inline code or ``` examples) is never a hold. The dependency
# passes post the release receipt once, after `at` has passed:
#   <!-- aidevops:not-before-released at=2026-11-26T07:00:00Z -->
ISSUE_NOT_BEFORE_MARKER='aidevops:not-before'
ISSUE_NOT_BEFORE_RELEASED_MARKER='aidevops:not-before-released'

# shellcheck disable=SC2016 # jq program; $vars are jq variables.
_IHM_NOT_BEFORE_JQ='
def trusted: (.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR");
def unfenced_lines:
	reduce (split("\n")[]) as $line ({fence: "", out: []};
		($line | sub("^ {0,3}"; "")) as $t
		| .fence as $f
		| if $f != "" then
			(if ($t | test("^" + $f + "[" + $f[0:1] + "]*\\s*$")) then .fence = "" else . end)
		elif ($t | test("^(`{3,}|~{3,})")) then .fence = ($t | capture("^(?<f>`{3,}|~{3,})").f)
		else .out += [$line] end)
	| .out[];
def marker_ats($name):
	[unfenced_lines
		| select(test("^\\s*<!--\\s*" + $name + "\\s[^>]*-->\\s*$"))
		| (capture("\\sat=(?<at>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)(\\s|-->)") // {at: null}).at
		| {at: ., epoch: (if . == null then null else (try fromdateiso8601 catch null) end)}];
(if type == "array" then . else error("comments must be an array") end)
| (if ([.[0]? | arrays] | length) > 0 then add else . end)
| map(select(type == "object" and trusted) | (.body // "")) as $trusted
| ((($body | marker_ats($nb)) | map(. + {trusted: $body_trusted}))
	+ [$trusted[] | marker_ats($nb)[] | . + {trusted: true}]) as $markers
| [$trusted[] | marker_ats($rel)[] | .at | select(. != null)] as $released
| if ($markers | length) == 0 then "none"
elif any($markers[]; .epoch == null) then "invalid 0 -"
else ($markers | max_by(.epoch)) as $max
	| if $max.epoch > $now then "active \($max.epoch) \($max.at)"
	else ([$markers[] | select(.trusted)] | max_by(.epoch)) as $latest
		| if $latest == null then "none"
		elif ($released | index($latest.at)) != null then "released \($latest.epoch) \($latest.at)"
		else "expired \($latest.epoch) \($latest.at)" end
	end
end'

# issue_not_before_state — evaluate time-gate markers (GH#39856).
# Only trusted comments (OWNER/MEMBER/COLLABORATOR) count. A body marker always
# holds (an author can only delay their own issue) but releases only when the
# caller vouches for the body author ($3=true). A malformed marker holds.
# Args: $1 comments JSON (array or --paginate --slurp pages), $2 issue body,
#       $3 body author trusted (true|false), $4 optional now epoch.
# Output: "none", "active <epoch> <iso>", "invalid 0 -", "expired <epoch> <iso>"
#         (release due) or "released <epoch> <iso>" (receipt already posted).
# Returns: 0 on readable evidence, 2 on unreadable comments (caller fails closed).
issue_not_before_state() {
	local comments_json="${1:-[]}"
	local body="${2:-}"
	local body_trusted="${3:-false}"
	local now="${4:-}"
	local state=""
	[[ "$body_trusted" == true ]] || body_trusted=false
	[[ "$now" =~ ^[0-9]+$ ]] || now=$(date -u +%s) || return 2
	state=$(printf '%s' "$comments_json" | jq -r --arg body "$body" \
		--argjson body_trusted "$body_trusted" --argjson now "$now" \
		--arg nb "$ISSUE_NOT_BEFORE_MARKER" --arg rel "$ISSUE_NOT_BEFORE_RELEASED_MARKER" \
		"$_IHM_NOT_BEFORE_JQ" 2>/dev/null) || return 2
	[[ "$state" =~ ^(none|invalid\ 0\ -|(active|expired|released)\ [0-9]+\ [0-9TZ:-]+)$ ]] || return 2
	printf '%s\n' "$state"
	return 0
}

# issue_not_before_blocks — succeed while a time gate holds the issue: an
# unexpired or malformed marker, or unreadable evidence (fail closed).
# Args: as issue_not_before_state.
issue_not_before_blocks() {
	local state=""
	state=$(issue_not_before_state "$@") || return 0
	case "${state%% *}" in
	active | invalid) return 0 ;;
	esac
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
