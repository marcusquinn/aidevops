#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GitHub CLI Wrappers -- REST Fallback (t2574, GH#20243)
# =============================================================================
# When gh's native `gh issue create|comment|edit` commands fail and GraphQL
# quota is exhausted (remaining <= threshold), these translators retry the
# operation via `gh api` REST endpoints, which run against GitHub's separate
# 5000/hour core REST budget.
#
# Detection: _gh_should_fallback_to_rest -- consults gh api rate_limit.
# Translators: _gh_issue_create_rest, _gh_issue_comment_rest, _gh_issue_edit_rest.
#
# Loaded by shared-gh-wrappers.sh. Do not source directly.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_REST_FALLBACK_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_REST_FALLBACK_LOADED=1

# Threshold below which we consider GraphQL exhausted.
# Env override: AIDEVOPS_GH_REST_FALLBACK_THRESHOLD
_GH_REST_FALLBACK_THRESHOLD="${AIDEVOPS_GH_REST_FALLBACK_THRESHOLD:-10}"

#######################################
# Build the `-F` value for `gh api` that uploads a file's contents as the
# `body` form field. Centralised so the `body=@...` literal lives in exactly
# one place; callers use "$(_gh_rest_body_file_arg "$path")".
#######################################
_gh_rest_body_file_arg() {
	local path="$1"
	printf 'body=@%s' "$path"
	return 0
}

#######################################
# Return 0 (true) when GraphQL rate limit remaining is <= threshold.
# `gh api rate_limit` is a free endpoint (does not count against quotas).
# Fail-safe: if the response is unparseable (network error, gh auth missing),
# return 1 (false) so the caller sees the original error rather than triggering
# an unnecessary REST retry that may also fail.
#######################################
_gh_should_fallback_to_rest() {
	local remaining
	remaining=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null)
	[[ "$remaining" =~ ^[0-9]+$ ]] || return 1
	[[ "$remaining" -le "$_GH_REST_FALLBACK_THRESHOLD" ]]
}

#######################################
# Internal: If first arg looks like a GitHub issue URL, extract the repo slug
# and issue number. Returns via stdout on two lines (repo, then num) so we
# stay bash 3.2-compatible (nameref `local -n` is bash 4.3+).
# Caller pattern:  { read -r repo; read -r num; } < <(_gh_rest_normalize_issue_ref "$ref" "$repo")
# If the ref is a bare number, the first line is the current repo arg unchanged.
# Args: $1=url_or_num $2=current_repo_value (empty OK)
#######################################
_gh_rest_normalize_issue_ref() {
	local raw="$1"
	local repo="${2:-}"
	local num=""
	if [[ "$raw" =~ ^https?://github\.com/([^/]+/[^/]+)/(issues|pull)/([0-9]+) ]]; then
		[[ -z "$repo" ]] && repo="${BASH_REMATCH[1]}"
		num="${BASH_REMATCH[3]}"
	else
		num="$raw"
	fi
	printf '%s\n%s\n' "$repo" "$num"
	return 0
}

#######################################
# _gh_issue_create_rest: POST /repos/{owner}/{repo}/issues.
# Parses gh-style args (--title, --body, --body-file, --label, --assignee,
# --milestone) into a REST payload. Emits the issue html_url on stdout,
# mirroring `gh issue create`. Returns underlying gh api exit code.
#######################################
_gh_issue_create_rest() {
	local title=""
	local body=""
	local body_file=""
	local repo=""
	local milestone=""
	local has_body=0
	local -a labels=()
	local -a assignees=()
	local -a _toks=()

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo) repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--title) title="${2:-}"; shift 2 ;;
		--title=*) title="${_arg#--title=}"; shift ;;
		--body) body="${2:-}"; has_body=1; shift 2 ;;
		--body=*) body="${_arg#--body=}"; has_body=1; shift ;;
		--body-file) body_file="${2:-}"; has_body=1; shift 2 ;;
		--body-file=*) body_file="${_arg#--body-file=}"; has_body=1; shift ;;
		--label) IFS=',' read -ra _toks <<<"${2:-}"; labels+=("${_toks[@]}"); shift 2 ;;
		--label=*) IFS=',' read -ra _toks <<<"${_arg#--label=}"; labels+=("${_toks[@]}"); shift ;;
		--assignee) IFS=',' read -ra _toks <<<"${2:-}"; assignees+=("${_toks[@]}"); shift 2 ;;
		--assignee=*) IFS=',' read -ra _toks <<<"${_arg#--assignee=}"; assignees+=("${_toks[@]}"); shift ;;
		--milestone) milestone="${2:-}"; shift 2 ;;
		--milestone=*) milestone="${_arg#--milestone=}"; shift ;;
		*) shift ;;
		esac
	done

	if [[ -z "$repo" ]]; then
		printf '_gh_issue_create_rest: --repo is required\n' >&2
		return 1
	fi
	if [[ -z "$title" ]]; then
		printf '_gh_issue_create_rest: --title is required\n' >&2
		return 1
	fi

	local tmp_body="" tmp_body_owned=0
	if [[ $has_body -eq 1 ]]; then
		if [[ -n "$body_file" ]]; then
			tmp_body="$body_file"
		else
			tmp_body=$(mktemp -t aidevops-gh-rest-body.XXXXXX) || return 1
			tmp_body_owned=1
			printf '%s' "$body" >"$tmp_body"
		fi
	fi

	local -a api_args=(-X POST "/repos/${repo}/issues" -f "title=${title}")
	[[ -n "$tmp_body" ]] && api_args+=(-F "$(_gh_rest_body_file_arg "$tmp_body")")
	local _lbl
	for _lbl in "${labels[@]}"; do
		[[ -n "$_lbl" ]] && api_args+=(-f "labels[]=${_lbl}")
	done
	local _asn
	for _asn in "${assignees[@]}"; do
		[[ -n "$_asn" ]] && api_args+=(-f "assignees[]=${_asn}")
	done
	[[ -n "$milestone" ]] && api_args+=(-F "milestone=${milestone}")

	local html_url rc
	html_url=$(gh api "${api_args[@]}" --jq '.html_url' 2>&1)
	rc=$?

	[[ $tmp_body_owned -eq 1 && -f "$tmp_body" ]] && rm -f "$tmp_body"

	if [[ $rc -eq 0 ]]; then
		printf '%s\n' "$html_url"
	else
		printf '%s\n' "$html_url" >&2
	fi
	return $rc
}

#######################################
# _gh_issue_comment_rest: POST /repos/{owner}/{repo}/issues/{N}/comments.
# Mirrors `gh issue comment <num_or_url> --repo SLUG --body ... | --body-file PATH`.
# Emits the new comment html_url on stdout. Returns underlying gh api exit code.
#######################################
_gh_issue_comment_rest() {
	local num_or_url=""
	local repo=""
	local body=""
	local body_file=""
	local has_body=0

	local _first="${1:-}"
	if [[ $# -gt 0 && "$_first" != --* ]]; then
		num_or_url="$_first"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo) repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--body) body="${2:-}"; has_body=1; shift 2 ;;
		--body=*) body="${_arg#--body=}"; has_body=1; shift ;;
		--body-file) body_file="${2:-}"; has_body=1; shift 2 ;;
		--body-file=*) body_file="${_arg#--body-file=}"; has_body=1; shift ;;
		*) shift ;;
		esac
	done

	local num=""
	{ read -r repo; read -r num; } < <(_gh_rest_normalize_issue_ref "$num_or_url" "$repo")

	if [[ -z "$repo" || -z "$num" ]]; then
		printf '_gh_issue_comment_rest: issue number and --repo are required\n' >&2
		return 1
	fi
	if [[ ! "$num" =~ ^[0-9]+$ ]]; then
		printf '_gh_issue_comment_rest: invalid issue number: %s\n' "$num" >&2
		return 1
	fi
	if [[ $has_body -eq 0 ]]; then
		printf '_gh_issue_comment_rest: --body or --body-file required\n' >&2
		return 1
	fi

	local tmp_body="" tmp_body_owned=0
	if [[ -n "$body_file" ]]; then
		tmp_body="$body_file"
	else
		tmp_body=$(mktemp -t aidevops-gh-rest-body.XXXXXX) || return 1
		tmp_body_owned=1
		printf '%s' "$body" >"$tmp_body"
	fi

	local out rc
	out=$(gh api -X POST "/repos/${repo}/issues/${num}/comments" \
		-F "$(_gh_rest_body_file_arg "$tmp_body")" --jq '.html_url' 2>&1)
	rc=$?

	[[ $tmp_body_owned -eq 1 && -f "$tmp_body" ]] && rm -f "$tmp_body"

	if [[ $rc -eq 0 ]]; then
		printf '%s\n' "$out"
	else
		printf '%s\n' "$out" >&2
	fi
	return $rc
}

#######################################
# _gh_issue_edit_rest: PATCH /repos/{owner}/{repo}/issues/{N}.
# Handles --title, --body, --body-file, --add-label, --remove-label,
# --add-assignee, --remove-assignee, --milestone, --state. REST PATCH
# requires the FULL labels/assignees arrays (not deltas), so we fetch
# current state and compute the target set when label/assignee flags
# are present. Current-state fetch uses REST (`gh api /repos/...`) which
# is not affected by GraphQL exhaustion.
#######################################
_gh_issue_edit_rest() {
	local num_or_url=""
	local repo=""
	local title=""
	local body=""
	local body_file=""
	local milestone=""
	local state=""
	local has_title=0 has_body=0 has_milestone=0 has_state=0
	local -a add_labels=() rm_labels=() add_assignees=() rm_assignees=() _toks=()

	local _first="${1:-}"
	if [[ $# -gt 0 && "$_first" != --* ]]; then
		num_or_url="$_first"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo) repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--title) title="${2:-}"; has_title=1; shift 2 ;;
		--title=*) title="${_arg#--title=}"; has_title=1; shift ;;
		--body) body="${2:-}"; has_body=1; shift 2 ;;
		--body=*) body="${_arg#--body=}"; has_body=1; shift ;;
		--body-file) body_file="${2:-}"; has_body=1; shift 2 ;;
		--body-file=*) body_file="${_arg#--body-file=}"; has_body=1; shift ;;
		--add-label) IFS=',' read -ra _toks <<<"${2:-}"; add_labels+=("${_toks[@]}"); shift 2 ;;
		--add-label=*) IFS=',' read -ra _toks <<<"${_arg#--add-label=}"; add_labels+=("${_toks[@]}"); shift ;;
		--remove-label) IFS=',' read -ra _toks <<<"${2:-}"; rm_labels+=("${_toks[@]}"); shift 2 ;;
		--remove-label=*) IFS=',' read -ra _toks <<<"${_arg#--remove-label=}"; rm_labels+=("${_toks[@]}"); shift ;;
		--add-assignee) IFS=',' read -ra _toks <<<"${2:-}"; add_assignees+=("${_toks[@]}"); shift 2 ;;
		--add-assignee=*) IFS=',' read -ra _toks <<<"${_arg#--add-assignee=}"; add_assignees+=("${_toks[@]}"); shift ;;
		--remove-assignee) IFS=',' read -ra _toks <<<"${2:-}"; rm_assignees+=("${_toks[@]}"); shift 2 ;;
		--remove-assignee=*) IFS=',' read -ra _toks <<<"${_arg#--remove-assignee=}"; rm_assignees+=("${_toks[@]}"); shift ;;
		--milestone) milestone="${2:-}"; has_milestone=1; shift 2 ;;
		--milestone=*) milestone="${_arg#--milestone=}"; has_milestone=1; shift ;;
		--state) state="${2:-}"; has_state=1; shift 2 ;;
		--state=*) state="${_arg#--state=}"; has_state=1; shift ;;
		*) shift ;;
		esac
	done

	local num=""
	{ read -r repo; read -r num; } < <(_gh_rest_normalize_issue_ref "$num_or_url" "$repo")

	if [[ -z "$repo" || -z "$num" ]]; then
		printf '_gh_issue_edit_rest: issue number and --repo are required\n' >&2
		return 1
	fi
	if [[ ! "$num" =~ ^[0-9]+$ ]]; then
		printf '_gh_issue_edit_rest: invalid issue number: %s\n' "$num" >&2
		return 1
	fi

	local _issue_path="/repos/${repo}/issues/${num}"
	local -a api_args=(-X PATCH "$_issue_path")
	[[ $has_title -eq 1 ]] && api_args+=(-f "title=${title}")
	[[ $has_milestone -eq 1 ]] && api_args+=(-F "milestone=${milestone:-null}")
	[[ $has_state -eq 1 ]] && api_args+=(-f "state=${state}")

	local tmp_body=""
	local tmp_body_owned=0
	if [[ $has_body -eq 1 ]]; then
		if [[ -n "$body_file" ]]; then
			tmp_body="$body_file"
		else
			tmp_body=$(mktemp -t aidevops-gh-rest-body.XXXXXX) || return 1
			tmp_body_owned=1
			printf '%s' "$body" >"$tmp_body"
		fi
		api_args+=(-F "$(_gh_rest_body_file_arg "$tmp_body")")
	fi

	# Labels and assignees: REST requires full arrays. Delegated to
	# _gh_rest_print_patch_array_flags; see that helper for the state-fetch
	# and delta-application logic.
	local _flag _val
	if [[ ${#add_labels[@]} -gt 0 || ${#rm_labels[@]} -gt 0 ]]; then
		while IFS=$'\t' read -r _flag _val; do
			api_args+=("$_flag" "$_val")
		done < <(_gh_rest_print_patch_array_flags "$_issue_path" "labels" ".labels[].name" \
			"$(printf '%s\n' "${add_labels[@]}")" "$(printf '%s\n' "${rm_labels[@]}")")
	fi
	if [[ ${#add_assignees[@]} -gt 0 || ${#rm_assignees[@]} -gt 0 ]]; then
		while IFS=$'\t' read -r _flag _val; do
			api_args+=("$_flag" "$_val")
		done < <(_gh_rest_print_patch_array_flags "$_issue_path" "assignees" ".assignees[].login" \
			"$(printf '%s\n' "${add_assignees[@]}")" "$(printf '%s\n' "${rm_assignees[@]}")")
	fi

	gh api "${api_args[@]}" >/dev/null 2>&1
	local rc=$?

	[[ $tmp_body_owned -eq 1 && -f "$tmp_body" ]] && rm -f "$tmp_body"

	return $rc
}

#######################################
# Print -f flags for a PATCH array field (labels or assignees) given the
# current state (fetched via REST) and add/remove deltas. Output is one
# tab-separated `-f\tfield[]=value` pair per line; caller reads with
# `IFS=$'\t' read -r k v` and appends both to the api_args array.
# Factored out of _gh_issue_edit_rest so that function stays under the
# 100-line complexity gate.
#
# Args: $1=issue_path  $2=field_name  $3=jq_expr  $4=adds_nl  $5=rms_nl
#######################################
_gh_rest_print_patch_array_flags() {
	local issue_path="$1"
	local field="$2"
	local jq_expr="$3"
	local adds="$4"
	local rms="$5"
	local _current _target _elem
	_current=$(gh api "$issue_path" --jq "$jq_expr" 2>/dev/null) || _current=""
	_target=$(_gh_rest_compute_target_set "$_current" "$adds" "$rms")
	while IFS= read -r _elem; do
		[[ -n "$_elem" ]] && printf -- '-f\t%s[]=%s\n' "$field" "$_elem"
	done <<<"$_target"
	return 0
}

#######################################
# _gh_rest_compute_target_set: given the current values of a list field
# (newline-separated), an add set (newline-separated), and a remove set
# (newline-separated), emit the target set (removes subtracted first, then
# adds unioned, deduped) one value per line on stdout.
#
# Used by _gh_issue_edit_rest to translate --add-label/--remove-label and
# --add-assignee/--remove-assignee flags into the full array that REST PATCH
# requires.
#######################################
_gh_rest_compute_target_set() {
	local current="$1" adds="$2" rms="$3"
	local -a target=()
	local v to_rm existing to_add skip dup

	while IFS= read -r v; do
		[[ -z "$v" ]] && continue
		skip=0
		while IFS= read -r to_rm; do
			[[ -n "$to_rm" && "$v" == "$to_rm" ]] && { skip=1; break; }
		done <<<"$rms"
		[[ $skip -eq 0 ]] && target+=("$v")
	done <<<"$current"

	while IFS= read -r to_add; do
		[[ -z "$to_add" ]] && continue
		dup=0
		for existing in "${target[@]}"; do
			[[ "$existing" == "$to_add" ]] && {
				dup=1
				break
			}
		done
		[[ $dup -eq 0 ]] && target+=("$to_add")
	done <<<"$adds"

	local elem
	for elem in "${target[@]}"; do printf '%s\n' "$elem"; done
	return 0
}
