#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared PR-description and explicit merge-message validation (GH#36797).

# Used by both the standalone gh shim and the safe-edit wrappers.
_gh_extract_repo_from_args() {
	local i=0
	local -a args=("$@")
	while [[ $i -lt ${#args[@]} ]]; do
		case "${args[i]}" in
		--repo | -R)
			if [[ -n "${args[i + 1]:-}" && "${args[i + 1]}" != -* ]]; then
				printf '%s\n' "${args[i + 1]}"
			fi
			return 0
			;;
		--repo=*)
			printf '%s\n' "${args[i]#--repo=}"
			return 0
			;;
		-R?*)
			printf '%s\n' "${args[i]#-R}"
			return 0
			;;
		esac
		i=$((i + 1))
	done
	return 0
}

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
		--help) return 0 ;;
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
	if [[ -z "$body_text" ]]; then
		# A create must provide inspectable text; metadata-only edits need none.
		# An edit that explicitly supplies a (possibly empty) body is validated
		# against PR labels; one with no body source is metadata-only.
		if [[ "${_GH_PR_IDENTITY_ORIGIN:-}" == "edit" ]]; then
			[[ "$has_body" -eq 1 || "$has_body_file" -eq 1 ]] || return 0
		else
			[[ "${_GH_PR_IDENTITY_ORIGIN:-}" == "origin:worker" ]] || return 0
		fi
	fi
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

# Preserve Pulse closing-target selection, including its PR-reference exception.
_gh_pr_body_closing_issues() {
	local body_text="$1"
	printf '%s' "$body_text" \
		| grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]+#[0-9]+' \
		| grep -oE '[0-9]+' | sort -u || true
	return 0
}

_gh_drop_closing_pull_request_refs() {
	local repo_slug="$1" candidates="$2"
	local candidate="" issue_json="" kept="" newline=$'\n'
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		issue_json=$(_gh_with_timeout read gh api "repos/${repo_slug}/issues/${candidate}" 2>/dev/null) || issue_json=""
		if [[ -n "$issue_json" ]] && printf '%s' "$issue_json" \
			| jq -e --argjson n "$candidate" '.number == $n and .pull_request != null' >/dev/null 2>&1; then
			if [[ -n "${LOGFILE:-}" ]]; then
				printf '[pulse-wrapper] _extract_linked_issue: ignoring closing reference #%s in %s — it is a pull request, not an issue (GH#36704)\n' "$candidate" "$repo_slug" >>"$LOGFILE"
			fi
			continue
		fi
		kept="${kept:+${kept}${newline}}${candidate}"
	done <<<"$candidates"
	printf '%s' "$kept"
	return 0
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
		{
			line = $0; visible = ""
			while (length(line)) {
				if (comment) {
					if (!match(line, /-->/)) { line = ""; break }
					line = substr(line, RSTART + RLENGTH); comment = 0
				} else if (match(line, /<!--/)) {
					visible = visible substr(line, 1, RSTART - 1) " "
					line = substr(line, RSTART + RLENGTH); comment = 1
				} else { visible = visible line; break }
			}
			$0 = visible
		}
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
	local worker_origin="origin:worker"
	# Raw shim writes can declare their origin in the body before labels exist.
	if [[ -z "$origin" && "$body_text" == *'<!-- aidevops:origin:worker -->'* ]]; then
		origin="$worker_origin"
	fi
	if [[ "$origin" == "edit" ]]; then
		repo=$(_gh_extract_repo_from_args "$@")
		local arg="" pending="" adding_worker=0
		local -a view_args=()
		for arg in "$@"; do
			if [[ -n "$pending" ]]; then
				if [[ "$pending" == "label" && ",${arg}," == *",origin:worker,"* ]]; then
					adding_worker=1
				fi
				pending=""
				continue
			fi
			case "$arg" in
			--add-label) pending="label" ;;
			--add-label=*) [[ ",${arg#*=}," != *",origin:worker,"* ]] || adding_worker=1 ;;
			--repo | -R | --body | -b | --body-file | -F | --title | -t | --base | -B | --milestone | -m | --remove-label | --add-assignee | --remove-assignee | --add-reviewer | --remove-reviewer | --add-project | --remove-project) pending="value" ;;
			-*) ;;
			*) [[ -n "$number" ]] || number="$arg" ;;
			esac
		done
		[[ -z "$number" ]] || view_args+=("$number")
		[[ -z "$repo" ]] || view_args+=(--repo "$repo")
		if ! labels=$(gh_pr_view "${view_args[@]}" --json labels --jq '[.labels[].name]' 2>/dev/null) ||
			! printf '%s' "$labels" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
			_GH_EDIT_REJECTION_REASON="PR origin labels unavailable before body edit"
			printf '[SAFETY] %s; retry when PR metadata is readable.\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
		if [[ "$adding_worker" -eq 0 ]]; then
			printf '%s' "$labels" | jq -e --arg origin "$worker_origin" 'index($origin) != null' >/dev/null || return 0
		fi
	elif [[ "$origin" != "$worker_origin" ]]; then
		return 0
	fi
	# Native closing declarations retain their existing authoritative selection;
	# ambiguous closing targets must not fall back to a For/Ref declaration.
	issues=$(_gh_pr_body_closing_issues "$body_text")
	if [[ "$issues" == *$'\n'* ]]; then
		[[ -n "$repo" ]] || repo=$(_gh_extract_repo_from_args "$@")
		issues=$(_gh_drop_closing_pull_request_refs "$repo" "$issues")
	fi
	if [[ -z "$issues" ]]; then
		issues=$(_gh_pr_body_explicit_issues "$body_text") || return 1
	fi
	if [[ -z "$issues" || "$issues" == *$'\n'* || "$issues" == "ambiguous" ]]; then
		_GH_EDIT_REJECTION_REASON="worker PR body has ambiguous or missing explicit issue identity"
		# shellcheck disable=SC2016 # Literal Markdown code spans, not commands.
		printf '[SAFETY] %s; keep one standalone `For #N` line; move other references under `## Related`.\n' "$_GH_EDIT_REJECTION_REASON" >&2
		return 1
	fi
	return 0
}
