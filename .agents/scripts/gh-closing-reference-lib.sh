#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared PR-description and explicit merge-message validation (GH#36797),
# plus the repository-target resolution shared with the gh shim (GH#39801).

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

# -----------------------------------------------------------------------------
# GH#39801: repository-target resolution.
# Native gh resolves an omitted target itself, but each aidevops layer that must
# know where a write lands (privacy guard, REST fallback, PR recovery, labels,
# audit) read only an explicit --repo (see also GH#23883, GH#30855). These
# helpers are the one resolver for those layers. They mirror native gh's
# non-interactive base-repository choice (cli/cli ResolvedRemotes.BaseRepo):
# -R/--repo, an issue/PR URL argument, GH_REPO, a `gh repo set-default` remote,
# then the first github.com remote ranked upstream > github > origin > others.
# No API calls. Parameter expansion only, so bash 3.2 and zsh behave the same.
# -----------------------------------------------------------------------------
_GH_TARGET_REPO=""
_GH_TARGET_REPO_SOURCE=""
_GH_TARGET_REPO_EXPLICIT=""
_GH_TARGET_REPO_REFERENCE=""

_gh_target_slug_valid() {
	local slug="$1"
	[[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
	return $?
}

# Print OWNER/REPO for a github.com HTTPS, SSH or scp-style URL.
_gh_target_slug_from_url() {
	local url="$1"
	local rest="" owner="" repo_name=""
	case "$url" in
	https://github.com/* | http://github.com/* | ssh://github.com/*) rest="${url#*://github.com/}" ;;
	https://*@github.com/* | http://*@github.com/* | ssh://*@github.com/*) rest="${url#*@github.com/}" ;;
	*@github.com:*) rest="${url#*@github.com:}" ;;
	*) return 1 ;;
	esac
	[[ "$rest" == */* ]] || return 1
	owner="${rest%%/*}"
	rest="${rest#*/}"
	repo_name="${rest%%/*}"
	repo_name="${repo_name%.git}"
	_gh_target_slug_valid "${owner}/${repo_name}" || return 1
	printf '%s/%s\n' "$owner" "$repo_name"
	return 0
}

# Print OWNER/REPO for a github.com issue or pull-request URL.
_gh_target_slug_from_reference() {
	local ref="$1"
	local rest="" owner="" repo_name="" kind="" number=""
	case "$ref" in
	https://github.com/*/*/*/* | http://github.com/*/*/*/*) rest="${ref#*://github.com/}" ;;
	*) return 1 ;;
	esac
	owner="${rest%%/*}"
	rest="${rest#*/}"
	repo_name="${rest%%/*}"
	rest="${rest#*/}"
	kind="${rest%%/*}"
	rest="${rest#*/}"
	number="${rest%%[/?#]*}"
	[[ "$kind" == "issues" || "$kind" == "pull" ]] || return 1
	[[ "$number" =~ ^[0-9]+$ ]] || return 1
	_gh_target_slug_valid "${owner}/${repo_name}" || return 1
	printf '%s/%s\n' "$owner" "$repo_name"
	return 0
}

# Normalize [github.com/]OWNER/REPO or a github.com URL to OWNER/REPO.
_gh_target_normalize_repo() {
	local value="$1"
	case "$value" in
	github.com/*) value="${value#github.com/}" ;;
	*://* | *@github.com:*) value=$(_gh_target_slug_from_url "$value") || return 1 ;;
	esac
	_gh_target_slug_valid "$value" || return 1
	printf '%s\n' "$value"
	return 0
}

# GitHub repository names are case-insensitive.
_gh_target_same_repo() {
	local left="$1"
	local right="$2"
	[[ "$left" == "$right" ]] && return 0
	left=$(printf '%s' "$left" | tr '[:upper:]' '[:lower:]')
	right=$(printf '%s' "$right" | tr '[:upper:]' '[:lower:]')
	[[ "$left" == "$right" ]]
	return $?
}

# Print the repository native gh would use from the current checkout: a
# gh-resolved remote (`gh repo set-default`, fork clones) first, otherwise the
# highest-ranked github.com remote.
_gh_target_repo_from_checkout() {
	[[ "${GH_HOST:-github.com}" == "github.com" ]] || return 1
	local remotes="" resolved="" remote="" url="" kind="" slug="" score=0
	local best="" best_score=-1 chosen="" chosen_score=-1 key="" value="" resolution=""
	remotes=$(git remote -v 2>/dev/null) || return 1
	resolved=$(git config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null) || resolved=""
	while IFS=$' \t' read -r remote url kind; do
		[[ "$kind" == "(fetch)" ]] || continue
		slug=$(_gh_target_slug_from_url "$url") || continue
		case "$remote" in
		[Uu][Pp][Ss][Tt][Rr][Ee][Aa][Mm]) score=3 ;;
		[Gg][Ii][Tt][Hh][Uu][Bb]) score=2 ;;
		[Oo][Rr][Ii][Gg][Ii][Nn]) score=1 ;;
		*) score=0 ;;
		esac
		if [[ "$score" -gt "$best_score" ]]; then
			best="$slug"
			best_score="$score"
		fi
		resolution=""
		while IFS=' ' read -r key value; do
			[[ "$key" == "remote.${remote}.gh-resolved" ]] && resolution="$value"
		done <<<"$resolved"
		[[ -n "$resolution" && "$score" -gt "$chosen_score" ]] || continue
		[[ "$resolution" == "base" ]] || slug=$(_gh_target_normalize_repo "$resolution") || continue
		chosen="$slug"
		chosen_score="$score"
	done <<<"$remotes"
	[[ -n "$chosen" ]] || chosen="$best"
	[[ -n "$chosen" ]] || return 1
	printf '%s\n' "$chosen"
	return 0
}

# Print the target native gh uses when no -R/--repo or URL names one.
_gh_target_repo_default() {
	if [[ -n "${GH_REPO:-}" ]]; then
		_gh_target_normalize_repo "$GH_REPO"
		return $?
	fi
	_gh_target_repo_from_checkout
	return $?
}

# Resolve the target repository for gh-style issue/pr arguments.
# Sets _GH_TARGET_REPO (OWNER/REPO), _GH_TARGET_REPO_SOURCE
# (reference|explicit|env|checkout), _GH_TARGET_REPO_EXPLICIT and
# _GH_TARGET_REPO_REFERENCE.
# Returns: 0 resolved; 1 unresolvable; 2 -R/--repo value missing or malformed;
#   3 the issue/PR URLs and -R/--repo name different repositories
#   (_GH_TARGET_REPO is then the URL repository, as native gh uses it).
_gh_resolve_target_repo() {
	_GH_TARGET_REPO=""
	_GH_TARGET_REPO_SOURCE=""
	_GH_TARGET_REPO_EXPLICIT=""
	_GH_TARGET_REPO_REFERENCE=""
	local arg="" prev="" expect_repo=0 explicit="" explicit_seen=0 reference="" ref_slug="" conflict=0
	for arg in "$@"; do
		if [[ "$expect_repo" -eq 1 ]]; then
			[[ -n "$arg" && "$arg" != -* ]] || return 2
			explicit="$arg"
			expect_repo=0
			prev="$arg"
			continue
		fi
		case "$arg" in
		--repo | -R)
			explicit_seen=1
			expect_repo=1
			;;
		--repo=*)
			explicit_seen=1
			explicit="${arg#--repo=}"
			;;
		-R?*)
			explicit_seen=1
			explicit="${arg#-R}"
			;;
		https://github.com/* | http://github.com/*)
			# A URL given as the value of a text flag is content, not a target.
			case "$prev" in
			--title | -t | --body | -b | --body-file | -F | --comment | -c) ;;
			*)
				if ref_slug=$(_gh_target_slug_from_reference "$arg"); then
					[[ -z "$reference" ]] || _gh_target_same_repo "$reference" "$ref_slug" || conflict=1
					[[ -n "$reference" ]] || reference="$ref_slug"
				fi
				;;
			esac
			;;
		esac
		prev="$arg"
	done
	[[ "$expect_repo" -eq 0 ]] || return 2
	if [[ "$explicit_seen" -eq 1 ]]; then
		_gh_target_slug_valid "$explicit" || explicit=$(_gh_target_normalize_repo "$explicit") || return 2
		_GH_TARGET_REPO_EXPLICIT="$explicit"
	fi
	if [[ -n "$reference" ]]; then
		_GH_TARGET_REPO="$reference"
		_GH_TARGET_REPO_SOURCE="reference"
		_GH_TARGET_REPO_REFERENCE="$reference"
		[[ -z "$explicit" ]] || _gh_target_same_repo "$explicit" "$reference" || conflict=1
		[[ "$conflict" -eq 0 ]] || return 3
		return 0
	fi
	if [[ -n "$explicit" ]]; then
		_GH_TARGET_REPO="$explicit"
		_GH_TARGET_REPO_SOURCE="explicit"
		return 0
	fi
	_GH_TARGET_REPO=$(_gh_target_repo_default) || {
		_GH_TARGET_REPO=""
		return 1
	}
	_GH_TARGET_REPO_SOURCE="checkout"
	[[ -z "${GH_REPO:-}" ]] || _GH_TARGET_REPO_SOURCE="env"
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

# GH#40026: GitHub closes the target of a closing keyword anywhere in a PR body,
# including conditional or explanatory prose ("would make the sync close #N",
# "to avoid closing #N"). A wordlist of unsafe phrasings stays open-ended, so
# require the safe form instead. A declaration is a closing keyword that starts
# a line, list item or sentence, or continues a declaration list
# ("Resolves #1, fixes #2"). Any other closing reference must name a target that
# also has a declaration. Fenced blocks and inline code spans are ignored.
# Args: $1=body text, $2=optional OWNER/REPO so qualified self-references match
# Output: first undeclared target (#N or owner/repo#N). Exit: 0 found, 1 clean
_gh_pr_body_undeclared_closing_ref() {
	local body_text="$1" repo_slug="${2:-}"
	local match=""
	match=$(printf '%s\n' "$body_text" | awk -v repo="$repo_slug" '
		function ref_key(ref,    parts, slug) {
			if (ref ~ /^https?:\/\//) {
				sub(/^https?:\/\/[^\/]+\//, "", ref)
				split(ref, parts, "/")
				ref = parts[1] "/" parts[2] "#" parts[4]
			}
			if (substr(ref, 1, 1) == "#") return ref
			slug = substr(ref, 1, index(ref, "#") - 1)
			if (slug == repo) return substr(ref, index(ref, "#"))
			return ref
		}
		BEGIN {
			repo = tolower(repo)
			rf = "(https?://[^ \t]+/(issues|pull)/[0-9]+|[a-z0-9_.-]+/[a-z0-9_.-]+#[0-9]+|#[0-9]+)"
			pair = "(close[sd]?|fix(e[sd])?|resolve[sd]?):?[ \t]+" rf
			tail = rf "$"
		}
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
			if (fenced) next
			line = tolower($0)
			gsub(/`[^`]*`/, "", line)
			pos = 1
			last_end = 0
			last_decl = 0
			while (pos <= length(line) && match(substr(line, pos), pair)) {
				start = pos + RSTART - 1
				len = RLENGTH
				if (start > 1 && substr(line, start - 1, 1) ~ /[a-z0-9_]/) {
					pos = start + 1
					continue
				}
				phrase = substr(line, start, len)
				match(phrase, tail)
				key = ref_key(substr(phrase, RSTART))
				prefix = substr(line, 1, start - 1)
				between = ""
				if (last_end > 0) between = substr(line, last_end + 1, start - last_end - 1)
				if (prefix ~ /^[ \t]*(([-*+]|[0-9]+[.)])[ \t]+)?$/ || prefix ~ /[.!?;][ \t]+$/ ||
					(last_decl && between ~ /^[ \t]*(,|&|and|,[ \t]*and)?[ \t]*$/)) {
					declared[key] = 1
					last_decl = 1
				} else {
					inline_count++
					inline_key[inline_count] = key
					last_decl = 0
				}
				last_end = start + len - 1
				pos = start + len
			}
		}
		END {
			for (i = 1; i <= inline_count; i++) {
				if (!(inline_key[i] in declared)) {
					print inline_key[i]
					exit
				}
			}
		}')
	[[ -n "$match" ]] || return 1
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
	if _gh_pr_body_negated_closing_ref "$body_text" >/dev/null; then
		# Do not echo the author's body: it has not passed the privacy scan yet.
		_GH_EDIT_REJECTION_REASON="negated closing keyword — GitHub still treats it as a closing reference"
		printf '[SAFETY] gh pr body rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
		printf '[SAFETY] Use "Ref #N" or "For #N" and state "The referenced PR or issue remains open." Negation does not neutralize closing keywords.\n' >&2
		return 1
	fi
	if _gh_pr_body_undeclared_closing_ref "$body_text" "$(_gh_extract_repo_from_args "$@")" >/dev/null; then
		_GH_EDIT_REJECTION_REASON="closing keyword inside prose without a matching Resolves/Fixes/Closes declaration — GitHub still closes the referenced issue (GH#40026)"
		printf '[SAFETY] gh pr body rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
		printf '[SAFETY] To close it, add a standalone "Resolves #N" line. To leave it open, reword the prose without close/fix/resolve before the reference, or use "Ref #N" / "For #N".\n' >&2
		return 1
	fi
	_gh_validate_pr_worker_identity "$body_text" "$@"
	return $?
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
	# Syntax only: the live merge boundary verifies author, branch and exact diff.
	# Unknown or multiple markers cannot replace an issue identity (GH#39793:
	# sync-workflows joins badges-sync once the gate re-renders it byte-exactly).
	if [[ -z "$issues" ]] &&
		[[ "$body_text" == *'<!-- aidevops:routine-pr:badges-sync -->'* ||
		"$body_text" == *'<!-- aidevops:routine-pr:sync-workflows -->'* ]] &&
		[[ "$(printf '%s' "$body_text" | grep -o 'aidevops:routine-pr:' | grep -c .)" == 1 ]]; then
		return 0
	fi
	if [[ -z "$issues" || "$issues" == *$'\n'* || "$issues" == "ambiguous" ]]; then
		_GH_EDIT_REJECTION_REASON="worker PR body has ambiguous or missing explicit issue identity"
		# shellcheck disable=SC2016 # Literal Markdown code spans, not commands.
		printf '[SAFETY] %s; keep one standalone `For #N` line; move other references under `## Related`.\n' "$_GH_EDIT_REJECTION_REASON" >&2
		return 1
	fi
	return 0
}
