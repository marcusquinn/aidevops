#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared PR-description and explicit merge-message validation (GH#36797).

_gh_pr_body_negated_closing_ref() {
	local body_text="$1"
	local negation='(not|never|cannot|without|don[^[:space:]]{0,3}t|doesn[^[:space:]]{0,3}t|won[^[:space:]]{0,3}t|shouldn[^[:space:]]{0,3}t|can[^[:space:]]{0,3}t|mustn[^[:space:]]{0,3}t)'
	local keyword='(close[sd]?|fix(e[sd])?|resolve[sd]?)'
	local ref='(https?://[^[:space:]]+/(issues|pull)/[0-9]+|([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+)'
	# Bound the clause to 24 words; allow list commas, but not sentence or
	# semicolon boundaries. This is a wording guard, not an intent classifier.
	local gap='[[:space:]]+([[:alpha:]]+,?[[:space:]]+){0,24}'
	local pattern="(^|[^[:alnum:]_])${negation}${gap}${keyword}:?[[:space:]]+${ref}"
	local stripped="" match="" backtick=$'\x60'
	stripped=$(printf '%s\n' "$body_text" |
		awk '
			{
				line = $0
				sub(/^ ? ? ?/, "", line)
				marker = substr(line, 1, 1)
				run = 0
				if (marker == "`" || marker == "~") {
					while (substr(line, run + 1, 1) == marker) run++
				}
				suffix = substr(line, run + 1)
				if (run >= 3) {
					if (!fenced && (marker != "`" || index(suffix, "`") == 0)) {
						fenced = 1
						fence_marker = marker
						fence_length = run
						next
					}
					if (fenced && marker == fence_marker && run >= fence_length && suffix ~ /^[ \t]*$/) {
						fenced = 0
						next
					}
				}
				if (!fenced) print
			}' |
		sed -E "s/${backtick}[^${backtick}]*${backtick}//g" |
		tr '\n' ' ')
	match=$(printf '%s\n' "$stripped" | grep -oiE "$pattern" | sed -n '1p') || true
	[[ -n "$match" ]] || return 1
	match="${match#"${match%%[![:space:]]*}"}"
	printf '%s\n' "$match"
	return 0
}

_gh_validate_pr_closing_keywords() {
	local arg="" pending="" body_text="" has_body=0 body_file="" has_body_file=0
	for arg in "$@"; do
		if [[ "$pending" == "body" ]]; then
			body_text="$arg"
			pending=""
			continue
		elif [[ "$pending" == "body-file" ]]; then
			body_file="$arg"
			pending=""
			continue
		fi
		case "$arg" in
		--body | -b) has_body=1; body_text=""; pending="body" ;;
		--body=*) has_body=1; body_text="${arg#--body=}" ;;
		-b?*) has_body=1; body_text="${arg#-b}" ;;
		--body-file | -F) has_body_file=1; pending="body-file" ;;
		--body-file=*) has_body_file=1; body_file="${arg#--body-file=}" ;;
		-F?*) has_body_file=1; body_file="${arg#-F}" ;;
		*) ;;
		esac
	done
	if [[ "$has_body" -eq 1 && "$has_body_file" -eq 1 ]]; then
		_GH_EDIT_REJECTION_REASON="PR body cannot use --body and --body-file together"
		printf '[SAFETY] %s. Use only one body source before writing.\n' "$_GH_EDIT_REJECTION_REASON" >&2
		return 1
	fi
	if [[ "$has_body" -eq 0 && -n "$body_file" ]]; then
		if [[ ! -f "$body_file" || ! -r "$body_file" ]]; then
			_GH_EDIT_REJECTION_REASON="PR body file cannot be inspected before writing"
			printf '[SAFETY] %s. Materialize a readable body file, or use gh-write-helper.sh for --body-file - input.\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
		body_text=$(<"$body_file")
	fi
	[[ -n "$body_text" ]] || return 0
	if ! _gh_pr_body_negated_closing_ref "$body_text" >/dev/null; then
		_gh_validate_pr_worker_identity "$body_text" "$@"
		return $?
	fi
	# Do not echo the author's body: it has not passed the privacy scan yet.
	_GH_EDIT_REJECTION_REASON="negated closing keyword — GitHub still treats it as a closing reference"
	printf '[SAFETY] gh pr body rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
	printf '[SAFETY] Use "Ref #N" or "For #N" and state "The referenced PR or issue remains open." Negation does not neutralize closing keywords.\n' >&2
	return 1
}

# Shared with Pulse explicit association. Output is empty, one issue, or a
# sorted ambiguous candidate set (including the sentinel "ambiguous").
_gh_pr_body_explicit_issues() {
	local body_text="$1"
	printf '%s\n' "$body_text" | awk '
		/^[[:space:]]*(```|~~~)/ {
			fence_line = $0
			sub(/^[[:space:]]*/, "", fence_line)
			match(fence_line, /^(`+|~+)/)
			fence_run = substr(fence_line, 1, RLENGTH)
			if (!fence) {
				fence = 1
				fence_marker = substr(fence_run, 1, 1)
				fence_length = length(fence_run)
			} else if (substr(fence_run, 1, 1) == fence_marker && length(fence_run) >= fence_length &&
				substr(fence_line, length(fence_run) + 1) ~ /^[[:space:]]*$/) {
				fence = 0
			}
			next
		}
		fence { next }
		/<!--/ { comment = 1 }
		comment { if ($0 ~ /-->/) comment = 0; next }
		/^[[:space:]]*#/ {
			section = tolower($0)
			sub(/^[[:space:]]*/, "", section)
			match(section, /^#+/)
			depth = RLENGTH
			if (secondary && depth <= secondary) secondary = 0
			if (section ~ /(remaining|follow.?up|related|next steps)/) secondary = depth
			next
		}
		secondary || /^[[:space:]]*>/ || /^([ ]{4}|\t)/ { next }
		{
			line = tolower($0)
			if (line !~ /^[[:space:]]*(for|ref)[:[:space:]]+#[1-9][0-9]*([^[:alnum:]_]|$)/) next
			sub(/^[[:space:]]*(for|ref)[:[:space:]]+#/, "", line)
			issue = line
			sub(/[^0-9].*$/, "", issue)
			sub(/^[0-9]+/, "", line)
			# Later context is not a task; another declaration or clause target is.
			clause = line
			rest = ""
			if (match(line, /[.;!?]([[:space:]]|$)/)) {
				clause = substr(line, 1, RSTART - 1)
				rest = substr(line, RSTART)
			}
			if (clause ~ /#[0-9]/ || rest ~ /[^[:alnum:]_](for|ref)[:[:space:]]+#[0-9]/) print "ambiguous"
			print issue
		}
	' | sort -u
	return $?
}

# Called only for an inspected body, never a title/label-only edit. The origin
# is dynamically scoped by the create/edit entrypoints, not inferred from prose.
_gh_validate_pr_worker_identity() {
	local body_text="$1"
	shift
	local origin="${_GH_PR_IDENTITY_ORIGIN:-}" labels="" repo="" number="" issues=""
	if [[ "$origin" == "edit" ]]; then
		repo=$(_gh_extract_repo_from_args "$@")
		number=$(_gh_extract_number_from_args "$@")
		if ! labels=$(gh_pr_view "$number" --repo "$repo" --json labels --jq '[.labels[].name]' 2>/dev/null) ||
			! printf '%s' "$labels" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
			_GH_EDIT_REJECTION_REASON="PR origin labels unavailable before body edit"
			printf '[SAFETY] %s; retry when PR metadata is readable.\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
		printf '%s' "$labels" | jq -e 'index("origin:worker") != null' >/dev/null || return 0
	elif [[ "$origin" != "origin:worker" ]]; then
		return 0
	fi
	# Native closing declarations retain their existing authoritative selection.
	if printf '%s' "$body_text" | grep -qiE '(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]+#[0-9]+'; then
		return 0
	fi
	issues=$(_gh_pr_body_explicit_issues "$body_text") || return 1
	if [[ -z "$issues" || "$issues" == *$'\n'* || "$issues" == "ambiguous" ]]; then
		_GH_EDIT_REJECTION_REASON="worker PR body has ambiguous or missing explicit issue identity"
		# shellcheck disable=SC2016 # Literal Markdown code spans, not commands.
		printf '[SAFETY] %s; keep one standalone `For #N` line; move other references under `## Related`.\n' "$_GH_EDIT_REJECTION_REASON" >&2
		return 1
	fi
	return 0
}
