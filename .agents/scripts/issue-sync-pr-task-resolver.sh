#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

[[ "${BASH_SOURCE[0]}" == "$0" ]] && set -euo pipefail

# Shared awk functions for TODO row parsing (GH#35755).
# todo_strip_comments drops <!-- ... --> spans, including multi-line comments,
# with the same semantics as issue-sync-lib-parse.sh strip_html_comments, while
# keeping one output line per input line so FNR diagnostics stay exact. The
# GH#17804 TODO template keeps its format examples (t1, t2, ...) in a comment.
# todo_normalize_id strips leading zeros per dotted segment (t034 -> t34), the
# same identity task-id-normalize-helper.sh applies, so a normalized historical
# duplicate is compared with its padded baseline rather than reported as new.
_TODO_ROW_AWK_FUNCTIONS='
function todo_strip_comments(line,    out, pos) {
	out = ""
	while (length(line) > 0) {
		if (todo_in_comment) {
			pos = index(line, "-->")
			if (pos == 0) return out
			line = substr(line, pos + 3)
			todo_in_comment = 0
		} else {
			pos = index(line, "<!--")
			if (pos == 0) return out line
			out = out substr(line, 1, pos - 1)
			line = substr(line, pos + 4)
			todo_in_comment = 1
		}
	}
	return out
}
function todo_normalize_id(id,    count, parts, i, segment, out) {
	count = split(substr(id, 2), parts, ".")
	out = substr(id, 1, 1)
	for (i = 1; i <= count; i++) {
		segment = parts[i]
		sub(/^0+/, "", segment)
		if (segment == "") segment = "0"
		out = out (i > 1 ? "." : "") segment
	}
	return out
}
'

# Emit one canonical key per task ID and issue mapping on TODO checkbox rows.
# Keeping this parser here makes issue-sync resolution, push guards, and merge
# guards agree about what constitutes a mapping. Rows inside HTML comments are
# documentation, never mappings. Pass "normalize" as $2 to emit task IDs
# without leading zeros (duplicate comparison); the default keeps literal IDs.
todo_mapping_keys() {
	local todo_file="$1"
	local normalize="0"

	[[ "${2:-}" == "normalize" ]] && normalize="1"
	[[ -f "$todo_file" ]] || return 1
	awk -v normalize="$normalize" "${_TODO_ROW_AWK_FUNCTIONS}"'
		{ $0 = todo_strip_comments($0) }
		/^[[:space:]]*-[[:space:]]\[[^]]\][[:space:]]+t[0-9]+(\.[0-9]+)*([[:space:]]|$)/ {
			task = $0
			sub(/^[[:space:]]*-[[:space:]]\[[^]]\][[:space:]]+/, "", task)
			split(task, fields, /[[:space:]]+/)
			print "task:" (normalize == "1" ? todo_normalize_id(fields[1]) : fields[1])
			while (match($0, /ref:GH#[0-9]+/)) {
				print "issue:" substr($0, RSTART + 7, RLENGTH - 7)
				$0 = substr($0, RSTART + RLENGTH)
			}
		}
	' "$todo_file" || return 1
	return 0
}

# Report duplicate task IDs and issue mappings introduced relative to a
# baseline TODO snapshot. Return 0 for no regression, 1 for duplicates, and 2
# when evidence cannot be read. Output is suitable for push/merge diagnostics.
todo_duplicate_report() {
	local todo_file="$1"
	local baseline_file="${2:-}"
	local temp_dir=""
	local candidate_keys=""
	local baseline_keys=""
	local candidate_counts=""
	local baseline_counts=""
	local regressions=""
	local duplicates=""

	[[ -f "$todo_file" ]] || return 2
	temp_dir=$(mktemp -d) || return 2
	candidate_keys="${temp_dir}/candidate-keys"
	baseline_keys="${temp_dir}/baseline-keys"
	candidate_counts="${temp_dir}/candidate-counts"
	baseline_counts="${temp_dir}/baseline-counts"
	regressions="${temp_dir}/regressions"
	if ! todo_mapping_keys "$todo_file" normalize >"$candidate_keys"; then
		rm -rf "$temp_dir"
		return 2
	fi
	: >"$baseline_keys"
	if [[ -n "$baseline_file" ]]; then
		if [[ ! -f "$baseline_file" ]] || ! todo_mapping_keys "$baseline_file" normalize >"$baseline_keys"; then
			rm -rf "$temp_dir"
			return 2
		fi
	fi

	sort "$candidate_keys" | uniq -c >"$candidate_counts" || {
		rm -rf "$temp_dir"
		return 2
	}
	sort "$baseline_keys" | uniq -c >"$baseline_counts" || {
		rm -rf "$temp_dir"
		return 2
	}
	awk '
		FNR == NR { baseline[$2] = $1; next }
		$1 > 1 && $1 > (baseline[$2] + 0) { print $2 }
	' "$baseline_counts" "$candidate_counts" >"$regressions" || {
		rm -rf "$temp_dir"
		return 2
	}
	# With no regressions an empty first file would make FNR == NR true for the
	# TODO file itself, so the diagnostic pass must not run at all.
	if [[ ! -s "$regressions" ]]; then
		rm -rf "$temp_dir"
		return 0
	fi

	# Gather every affected line in one pass; avoid rescanning a large TODO.md for
	# every duplicate mapping while retaining actionable diagnostics. Comment
	# stripping and ID normalization match todo_mapping_keys exactly.
	awk "${_TODO_ROW_AWK_FUNCTIONS}"'
		FNR == NR { order[++count] = $1; wanted[$1] = 1; next }
		{
			$0 = todo_strip_comments($0)
			if ($0 ~ /^[[:space:]]*-[[:space:]]\[[^]]\][[:space:]]+t[0-9]+(\.[0-9]+)*([[:space:]]|$)/) {
				task = $0
				sub(/^[[:space:]]*-[[:space:]]\[[^]]\][[:space:]]+/, "", task)
				split(task, fields, /[[:space:]]+/)
				key = "task:" todo_normalize_id(fields[1])
				if (key in wanted) lines[key] = lines[key] (lines[key] ? "," : "") FNR
			}
			while (match($0, /ref:GH#[0-9]+/)) {
				issue = substr($0, RSTART, RLENGTH)
				key = "issue:" substr(issue, 8)
				if (key in wanted) lines[key] = lines[key] (lines[key] ? "," : "") FNR
				$0 = substr($0, RSTART + RLENGTH)
			}
		}
		END {
			for (position = 1; position <= count; position++) {
				key = order[position]
				value = substr(key, index(key, ":") + 1)
				if (key ~ /^task:/) {
					printf "  Duplicate task ID: %s  (TODO.md lines: %s)\n", value, lines[key]
				} else {
					printf "  Duplicate issue mapping: ref:GH#%s  (TODO.md lines: %s)\n", value, lines[key]
				}
			}
		}
	' "$regressions" "$todo_file"
	duplicates=$(<"$regressions")

	rm -rf "$temp_dir"
	[[ -n "$duplicates" ]] && return 1
	return 0
}

collect_effective_issues() {
	local todo_file="$1"
	local issue_numbers="$2"
	local vetoed_issue_numbers="$3"
	local issue_number=""
	local matches=""

	for issue_number in $issue_numbers; do
		if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
			printf 'ERROR: invalid closing issue number: %s\n' "$issue_number" >&2
			return 1
		fi
		if [[ " $vetoed_issue_numbers " == *" $issue_number "* ]]; then
			continue
		fi
		RESOLVED_EFFECTIVE_ISSUES="${RESOLVED_EFFECTIVE_ISSUES}${RESOLVED_EFFECTIVE_ISSUES:+ }${issue_number}"
		matches=$(grep -E "^[[:space:]]*- \[[ x]\] t[0-9]+(\.[0-9]+)* .*ref:GH#${issue_number}([[:space:]]|$)" "$todo_file" || true)
		if [[ -n "$matches" ]]; then
			RESOLVED_TASK_BACKED="true"
		fi
	done
	return 0
}

map_issue_tasks() {
	local todo_file="$1"
	local effective_issues="$2"
	local issue_number=""
	local matches=""
	local match_count="0"
	local task_id=""

	for issue_number in $effective_issues; do
		matches=$(grep -E "^[[:space:]]*- \[[ x]\] t[0-9]+(\.[0-9]+)* .*ref:GH#${issue_number}([[:space:]]|$)" "$todo_file" || true)
		match_count=$(printf '%s\n' "$matches" | grep -c . || true)
		if [[ "$match_count" -eq 0 ]]; then
			printf 'ERROR: closing issue #%s has no exact ref:GH#%s TODO mapping\n' "$issue_number" "$issue_number" >&2
			return 1
		fi
		if [[ "$match_count" -ne 1 ]]; then
			printf 'ERROR: closing issue #%s has %s ref:GH#%s TODO mappings; expected exactly one\n' "$issue_number" "$match_count" "$issue_number" >&2
			return 1
		fi
		if ! [[ "$matches" =~ ^[[:space:]]*-[[:space:]]\[[[:space:]x]\][[:space:]]+(t[0-9]+(\.[0-9]+)*) ]]; then
			printf 'ERROR: closing issue #%s has an invalid TODO mapping\n' "$issue_number" >&2
			return 1
		fi
		task_id="${BASH_REMATCH[1]}"
		RESOLVED_ISSUE_TASK_PAIRS="${RESOLVED_ISSUE_TASK_PAIRS}${RESOLVED_ISSUE_TASK_PAIRS:+ }${issue_number}:${task_id}"
		if [[ " $RESOLVED_TASK_IDS " != *" $task_id "* ]]; then
			RESOLVED_TASK_IDS="${RESOLVED_TASK_IDS}${RESOLVED_TASK_IDS:+ }${task_id}"
		fi
	done
	return 0
}

resolve_pr_task_ids() {
	local todo_file="$1"
	local issue_numbers="$2"
	local title_task_id="$3"
	local vetoed_issue_numbers="$4"
	RESOLVED_TASK_IDS=""
	RESOLVED_EFFECTIVE_ISSUES=""
	RESOLVED_TASK_BACKED="false"
	RESOLVED_ISSUE_TASK_PAIRS=""

	if [[ ! -f "$todo_file" ]]; then
		printf 'ERROR: TODO file not found: %s\n' "$todo_file" >&2
		return 1
	fi
	collect_effective_issues "$todo_file" "$issue_numbers" "$vetoed_issue_numbers" || return 1
	# Legacy worker titles may use t<issue> without an actual TODO task. Only
	# canonical task rows (with an exact ID) make those titles task-backed.
	if [[ -n "$title_task_id" ]] && todo_mapping_keys "$todo_file" | grep -Fx "task:$title_task_id" >/dev/null; then
		RESOLVED_TASK_BACKED="true"
	fi
	if [[ "$RESOLVED_TASK_BACKED" == "true" ]]; then
		map_issue_tasks "$todo_file" "$RESOLVED_EFFECTIVE_ISSUES" || return 1
	fi

	if [[ "$RESOLVED_TASK_BACKED" == "true" && -n "$title_task_id" && " $RESOLVED_TASK_IDS " != *" $title_task_id "* ]]; then
		printf 'ERROR: PR title task %s conflicts with closing-issue TODO mapping(s): %s\n' "$title_task_id" "$RESOLVED_TASK_IDS" >&2
		return 1
	fi

	printf '%s|%s|%s|%s\n' "$RESOLVED_TASK_IDS" "$RESOLVED_EFFECTIVE_ISSUES" "$RESOLVED_TASK_BACKED" "$RESOLVED_ISSUE_TASK_PAIRS"
	return 0
}

main() {
	local todo_file="${1:-}"
	local issue_numbers="${2:-}"
	local title_task_id="${3:-}"
	local vetoed_issue_numbers="${4:-}"
	resolve_pr_task_ids "$todo_file" "$issue_numbers" "$title_task_id" "$vetoed_issue_numbers"
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
