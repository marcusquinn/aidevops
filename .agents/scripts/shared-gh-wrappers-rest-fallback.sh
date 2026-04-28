#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GitHub CLI Wrappers -- REST Fallback (t2574, GH#20243; t2689)
# =============================================================================
# When gh's native `gh issue create|comment|edit|view|list` commands fail and
# GraphQL quota is exhausted (remaining <= threshold), these translators retry
# via `gh api` REST endpoints, which run against GitHub's separate 5000/hour
# core REST budget.
#
# Detection: _gh_should_fallback_to_rest -- consults gh api rate_limit.
# Write translators (t2574): _gh_issue_create_rest, _gh_issue_comment_rest,
#   _gh_issue_edit_rest, _gh_pr_create_rest.
# Read translators (t2689, t2772): _rest_issue_view, _rest_issue_list, _rest_pr_list.
#
# Note on field mapping (_rest_issue_view): `gh issue view --json id` returns
# the GraphQL node_id (e.g. I_kgDO...). The REST endpoint stores this in the
# `node_id` field, not `id`. Callers that need the node_id for GraphQL mutations
# should note that those mutations will also fail during GraphQL exhaustion, so
# the discrepancy is benign in practice. All other fields (state, title, body,
# labels, assignees, createdAt) map directly between gh and REST responses.
#
# Loaded by shared-gh-wrappers.sh. Do not source directly.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_REST_FALLBACK_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_REST_FALLBACK_LOADED=1

# Threshold below which we route reads/writes through REST instead of GraphQL.
# Env override: AIDEVOPS_GH_REST_FALLBACK_THRESHOLD
#
# Tuning rationale:
#   t2574 (default 10):   only engaged after 99.8% of the GraphQL budget was
#                         spent — by then in-flight ops were already failing.
#   t2744 (default 1000): proactive fallback at 20% remaining. Routes read-
#                         heavy traffic through the 5000/hr REST core pool
#                         while GraphQL keeps reserve for GraphQL-only
#                         mutations. Doubles steady-state capacity.
#   t2902 (default 1500): raised again. Operational data over 4.5 days on
#                         the marcusquinn runtime: 47 lifetime circuit-breaker
#                         fires (~10/day) AND GraphQL still hit 0/5000. The
#                         1000-point reserve was consumed faster than expected
#                         because `gh search` calls in pulse-batch-prefetch
#                         (per-owner per-cycle) were not routed through this
#                         threshold — they bypassed the wrappers entirely.
#                         t2902 wires those call sites in (see
#                         pulse-batch-prefetch-helper.sh) AND raises the
#                         threshold to give earlier headroom (1500 = 30%
#                         remaining). Pair: instrumentation + earlier
#                         fallback. Trivial revert: set back to 1000 here.
_GH_REST_FALLBACK_THRESHOLD="${AIDEVOPS_GH_REST_FALLBACK_THRESHOLD:-1500}"

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
# Append the aidevops signature footer to a body file if not already present.
# Used by REST fallback write translators to ensure every GitHub write carries
# the canonical <!-- aidevops:sig --> audit marker (t2707).
#
# Fail-open: a missing helper or write error must never break the write call.
#
# Args: $1=body_file_path
# Returns: 0 always
#######################################
_rest_fallback_append_sig() {
	local body_file="$1"
	[[ -f "$body_file" ]] || return 0
	grep -q "<!-- aidevops:sig -->" "$body_file" 2>/dev/null && return 0
	local helper="" _cand
	for _cand in \
		"${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" \
		"$(dirname "${BASH_SOURCE[0]:-$0}")/gh-signature-helper.sh"; do
		[[ -x "$_cand" ]] && { helper="$_cand"; break; }
	done
	[[ -z "$helper" ]] && return 0
	local footer
	footer=$("$helper" footer 2>/dev/null) || return 0
	[[ -n "$footer" ]] && printf '%s' "$footer" >>"$body_file" || true
	return 0
}

#######################################
# _gh_split_csv: portable CSV tokeniser. Emits one token per line to stdout.
#
# Works in bash 3.2+, zsh 5+, and BusyBox ash — uses POSIX parameter
# expansion only. Does NOT use:
#   - `read -ra arr` (bash-only; zsh emits "bad option: -a")
#   - `read -A arr` (zsh-only; bash emits "invalid option")
#   - `mapfile`/`readarray` (bash 4.4+ only)
#   - `${(f)var}` (zsh-only array expansion)
#
# Args: $1=csv_string $2=delimiter (default: comma)
# Returns: 0 always
#
# Usage:
#   while IFS= read -r _tok; do
#       [[ -n "$_tok" ]] && arr+=("$_tok")
#   done < <(_gh_split_csv "a,b,c")
#######################################
_gh_split_csv() {
	local _str="$1"
	local _delim="${2:-,}"
	while [[ -n "$_str" ]]; do
		if [[ "$_str" == *"$_delim"* ]]; then
			printf '%s\n' "${_str%%"$_delim"*}"
			_str="${_str#*"$_delim"}"
		else
			printf '%s\n' "$_str"
			_str=""
		fi
	done
	return 0
}

#######################################
# Return 0 (true) when GraphQL rate limit remaining is <= threshold.
# `gh api rate_limit` is a free endpoint (does not count against quotas).
# Fail-safe: if the response is unparseable (network error, gh auth missing),
# return 1 (false) so the caller sees the original error rather than triggering
# an unnecessary REST retry that may also fail.
#
# Optional arg: $1=pre-computed remaining count (integer string).
# When provided, skips the `gh api rate_limit` call — callers that already
# know the current rate-limit state (e.g. after fetching it once for a loop)
# can pass it to avoid redundant I/O.
#######################################
_gh_should_fallback_to_rest() {
	# Test/CI override: set _GH_SHOULD_FALLBACK_OVERRIDE=1 to force true without
	# requiring a real rate-limit state. Use in unit tests and manual smoke runs.
	[[ "${_GH_SHOULD_FALLBACK_OVERRIDE:-0}" == "1" ]] && return 0
	local remaining="${1:-}"
	if [[ -z "$remaining" ]]; then
		remaining=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null)
	fi
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
	gh_record_call rest 2>/dev/null || true
	local title=""
	local body=""
	local body_file=""
	local repo=""
	local milestone=""
	local has_body=0
	local -a labels
	local -a assignees
	local _tok
	labels=()
	assignees=()

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
		--label) while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_gh_split_csv "${2:-}"); shift 2 ;;
		--label=*) while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_gh_split_csv "${_arg#--label=}"); shift ;;
		--assignee) while IFS= read -r _tok; do [[ -n "$_tok" ]] && assignees+=("$_tok"); done < <(_gh_split_csv "${2:-}"); shift 2 ;;
		--assignee=*) while IFS= read -r _tok; do [[ -n "$_tok" ]] && assignees+=("$_tok"); done < <(_gh_split_csv "${_arg#--assignee=}"); shift ;;
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
	[[ -n "$tmp_body" ]] && _rest_fallback_append_sig "$tmp_body"

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
	gh_record_call rest 2>/dev/null || true
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
	_rest_fallback_append_sig "$tmp_body"

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
	gh_record_call rest 2>/dev/null || true
	local num_or_url=""
	local repo=""
	local title=""
	local body=""
	local body_file=""
	local milestone=""
	local state=""
	local has_title=0 has_body=0 has_milestone=0 has_state=0
	local -a add_labels
	local -a rm_labels
	local -a add_assignees
	local -a rm_assignees
	local _tok
	add_labels=()
	rm_labels=()
	add_assignees=()
	rm_assignees=()

	local _first="${1:-}"
	if [[ $# -gt 0 && "$_first" != --* ]]; then
		num_or_url="$_first"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		local _arg="$1" _v=""
		[[ "$_arg" == *=* ]] && { _v="${_arg#*=}"; _arg="${_arg%%=*}"; shift; } || { _v="${2:-}"; shift 2; }
		case "$_arg" in
		--repo)            repo="$_v" ;;
		--title)           title="$_v"; has_title=1 ;;
		--body)            body="$_v"; has_body=1 ;;
		--body-file)       body_file="$_v"; has_body=1 ;;
		--add-label)       while IFS= read -r _tok; do [[ -n "$_tok" ]] && add_labels+=("$_tok"); done < <(_gh_split_csv "$_v") ;;
		--remove-label)    while IFS= read -r _tok; do [[ -n "$_tok" ]] && rm_labels+=("$_tok"); done < <(_gh_split_csv "$_v") ;;
		--add-assignee)    while IFS= read -r _tok; do [[ -n "$_tok" ]] && add_assignees+=("$_tok"); done < <(_gh_split_csv "$_v") ;;
		--remove-assignee) while IFS= read -r _tok; do [[ -n "$_tok" ]] && rm_assignees+=("$_tok"); done < <(_gh_split_csv "$_v") ;;
		--milestone)       milestone="$_v"; has_milestone=1 ;;
		--state)           state="$_v"; has_state=1 ;;
		*) : ;;
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

#######################################
# _gh_pr_autodetect_head
# Returns the current git branch name for use as --head when omitted.
# Returns empty string when in detached HEAD state or outside a git repo.
# Emits an [INFO] log line when auto-detect fires.
#######################################
_gh_pr_autodetect_head() {
	local _branch
	_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
	if [[ -n "$_branch" && "$_branch" != "HEAD" ]]; then
		print_info "gh-wrapper: auto-detected --head=${_branch}"
		printf '%s\n' "$_branch"
	fi
	return 0
}

#######################################
# _gh_pr_autodetect_base <repo>
# Returns the repository's default branch for use as --base when omitted.
# Resolution order:
#   1. gh api /repos/{repo} --jq .default_branch (REST, no GraphQL cost)
#   2. git symbolic-ref refs/remotes/origin/HEAD
#   3. "main" (final fallback)
# Emits an [INFO] log line when auto-detect fires.
#######################################
_gh_pr_autodetect_base() {
	local _repo="${1:-}"
	local _base=""
	if [[ -n "$_repo" ]]; then
		_base=$(gh api "/repos/${_repo}" --jq '.default_branch' 2>/dev/null)
	fi
	if [[ -z "$_base" ]]; then
		_base=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
			| sed 's@^refs/remotes/origin/@@')
	fi
	[[ -z "$_base" ]] && _base="main"
	print_info "gh-wrapper: auto-detected --base=${_base}"
	printf '%s\n' "$_base"
	return 0
}

#######################################
# _gh_pr_create_rest: POST /repos/{owner}/{repo}/pulls.
# Parses gh-style args (--head, --base, --title, --body, --body-file, --draft,
# --label) into a REST payload. Labels are applied via a separate
# POST /repos/{owner}/{repo}/issues/{pr_number}/labels call because the
# GitHub pulls endpoint does not accept a labels field at creation time.
# Emits the PR html_url on stdout, mirroring `gh pr create`. Returns underlying
# gh api exit code.
# When --head or --base are omitted, auto-detects from git HEAD / repo
# default branch respectively (see _gh_pr_autodetect_head/base above).
#######################################
_gh_pr_create_rest() {
	gh_record_call rest 2>/dev/null || true
	local title=""
	local head=""
	local base=""
	local body=""
	local body_file=""
	local repo=""
	local draft=0
	local has_body=0
	local -a labels
	local _tok
	labels=()

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo) repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--title) title="${2:-}"; shift 2 ;;
		--title=*) title="${_arg#--title=}"; shift ;;
		--head) head="${2:-}"; shift 2 ;;
		--head=*) head="${_arg#--head=}"; shift ;;
		--base) base="${2:-}"; shift 2 ;;
		--base=*) base="${_arg#--base=}"; shift ;;
		--body) body="${2:-}"; has_body=1; shift 2 ;;
		--body=*) body="${_arg#--body=}"; has_body=1; shift ;;
		--body-file) body_file="${2:-}"; has_body=1; shift 2 ;;
		--body-file=*) body_file="${_arg#--body-file=}"; has_body=1; shift ;;
		--draft) draft=1; shift ;;
		--label) while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_gh_split_csv "${2:-}"); shift 2 ;;
		--label=*) while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_gh_split_csv "${_arg#--label=}"); shift ;;
		*) shift ;;
		esac
	done

	if [[ -z "$repo" ]]; then
		printf '_gh_pr_create_rest: --repo is required\n' >&2
		return 1
	fi
	if [[ -z "$title" ]]; then
		printf '_gh_pr_create_rest: --title is required\n' >&2
		return 1
	fi
	if [[ -z "$head" ]]; then
		head=$(_gh_pr_autodetect_head)
		if [[ -z "$head" ]]; then
			printf '_gh_pr_create_rest: --head is required\n' >&2
			return 1
		fi
	fi
	if [[ -z "$base" ]]; then
		base=$(_gh_pr_autodetect_base "$repo")
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
	[[ -n "$tmp_body" ]] && _rest_fallback_append_sig "$tmp_body"

	local -a api_args=(-X POST "/repos/${repo}/pulls"
		-f "title=$title"
		-f "head=$head"
		-f "base=$base")
	[[ -n "$tmp_body" ]] && api_args+=(-F "$(_gh_rest_body_file_arg "$tmp_body")")
	[[ $draft -eq 1 ]] && api_args+=(-F "draft=true")

	local html_url rc
	html_url=$(gh api "${api_args[@]}" --jq '.html_url' 2>&1)
	rc=$?

	[[ $tmp_body_owned -eq 1 && -f "$tmp_body" ]] && rm -f "$tmp_body"

	if [[ $rc -ne 0 ]]; then
		printf '%s\n' "$html_url" >&2
		return $rc
	fi

	printf '%s\n' "$html_url"

	# PRs share GitHub's issues label endpoint — apply labels if any.
	if [[ ${#labels[@]} -gt 0 ]]; then
		local pr_number
		pr_number=$(printf '%s' "$html_url" | grep -oE '[0-9]+$' || true)
		if [[ -n "$pr_number" ]]; then
			local -a label_args=(-X POST "/repos/${repo}/issues/${pr_number}/labels")
			local _lbl
			for _lbl in "${labels[@]}"; do
				[[ -n "$_lbl" ]] && label_args+=(-f "labels[]=${_lbl}")
			done
			gh api "${label_args[@]}" >/dev/null 2>&1 || true
		fi
	fi
	return 0
}

#######################################
# _rest_issue_view: GET /repos/{owner}/{repo}/issues/{N}.  (t2689)
# Parses gh-style args (positional number or URL, --repo, --json, --jq)
# and returns the issue JSON or a jq-filtered value. Mirrors `gh issue view`.
#
# The --json FIELDS flag is accepted for interface parity but ignored — the
# REST endpoint always returns the full issue object. Use --jq to extract
# specific fields. Field names align with `gh issue view --json` for all
# common fields (state, title, body, labels, assignees, createdAt).
# Exception: `id` maps to the numeric issue id in REST, not the GraphQL
# node_id — see the file header for the benign impact of this discrepancy.
#
# Returns the underlying gh api exit code.
#######################################
_rest_issue_view() {
	gh_record_call rest 2>/dev/null || true
	local num_or_url=""
	local repo=""
	local jq_expr=""

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
		--json) shift 2 ;;
		--json=*) shift ;;
		# t3027: accept -q as gh's documented shorthand for --jq. Without this,
		# callers using `gh issue view ... -q '.field'` (the idiomatic gh form)
		# silently lost the jq filter on REST fallback and got the full issue
		# object, breaking downstream string assignments.
		--jq | -q) jq_expr="${2:-}"; shift 2 ;;
		--jq=* | -q=*) jq_expr="${_arg#*=}"; shift ;;
		*) shift ;;
		esac
	done

	local num=""
	{ read -r repo; read -r num; } < <(_gh_rest_normalize_issue_ref "$num_or_url" "$repo")

	if [[ -z "$repo" || -z "$num" ]]; then
		printf '_rest_issue_view: issue number and --repo are required\n' >&2
		return 1
	fi
	if [[ ! "$num" =~ ^[0-9]+$ ]]; then
		printf '_rest_issue_view: invalid issue number: %s\n' "$num" >&2
		return 1
	fi

	local _path="/repos/${repo}/issues/${num}"
	# t2913: wall-clock timeout via _gh_with_timeout (defined in shared-gh-wrappers.sh).
	# Fail-open if helper not loaded — invoke gh api directly.
	local _gh_cmd=(gh api "$_path")
	[[ -n "$jq_expr" ]] && _gh_cmd+=(--jq "$jq_expr")
	if command -v _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "${_gh_cmd[@]}"
	else
		"${_gh_cmd[@]}"
	fi
	return $?
}

#######################################
# _rest_pr_list: GET /repos/{owner}/{repo}/pulls.  (t2772)
# Parses gh-style args (--repo, --state, --head, --base, --limit,
# --json, --jq, -q) and returns a JSON array or jq-filtered output.
# Mirrors `gh pr list` for state/head/base filtering.
#
# The --search flag is not supported and is silently skipped.
# --json FIELDS is accepted for parity but ignored (the REST endpoint
# returns the full object; use --jq/-q to select).
#
# Returns the underlying gh api exit code.
#######################################
_rest_pr_list() {
	gh_record_call rest 2>/dev/null || true
	local repo=""
	local state="open"
	local limit=30
	local jq_expr=""
	local head_branch=""
	local base_branch=""

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo) repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--state) state="${2:-}"; shift 2 ;;
		--state=*) state="${_arg#--state=}"; shift ;;
		--head) head_branch="${2:-}"; shift 2 ;;
		--head=*) head_branch="${_arg#--head=}"; shift ;;
		--base) base_branch="${2:-}"; shift 2 ;;
		--base=*) base_branch="${_arg#--base=}"; shift ;;
		--limit) limit="${2:-}"; shift 2 ;;
		--limit=*) limit="${_arg#--limit=}"; shift ;;
		--json) shift 2 ;;
		--json=*) shift ;;
		--jq) jq_expr="${2:-}"; shift 2 ;;
		--jq=*) jq_expr="${_arg#--jq=}"; shift ;;
		-q) jq_expr="${2:-}"; shift 2 ;;
		--search) shift 2 ;;
		--search=*) shift ;;
		*) shift ;;
		esac
	done

	if [[ -z "$repo" ]]; then
		printf '_rest_pr_list: --repo is required\n' >&2
		return 1
	fi

	local _query="state=${state}&per_page=${limit}"
	if [[ -n "$head_branch" ]]; then
		local _head_encoded
		_head_encoded=$(jq -rn --arg v "$head_branch" '$v | @uri')
		_query="${_query}&head=${_head_encoded}"
	fi
	if [[ -n "$base_branch" ]]; then
		local _base_encoded
		_base_encoded=$(jq -rn --arg v "$base_branch" '$v | @uri')
		_query="${_query}&base=${_base_encoded}"
	fi

	local _path="/repos/${repo}/pulls?${_query}"
	# t2913: wall-clock timeout via _gh_with_timeout (defined in shared-gh-wrappers.sh).
	local _gh_cmd=(gh api "$_path")
	[[ -n "$jq_expr" ]] && _gh_cmd+=(--jq "$jq_expr")
	if command -v _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "${_gh_cmd[@]}"
	else
		"${_gh_cmd[@]}"
	fi
	return $?
}

#######################################
# _rest_issue_list: GET /repos/{owner}/{repo}/issues.  (t2689)
# Parses gh-style args (--repo, --state, --label, --assignee, --limit,
# --json, --jq) and returns a JSON array or jq-filtered output.
# Mirrors `gh issue list` for state/label/assignee filtering.
#
# Multiple --label flags are collected and joined into a comma-separated
# `?labels=` query parameter (GitHub REST AND semantics — same as gh CLI).
# The --search flag is not supported by this REST translator and is silently
# skipped; callers that require full-text search semantics must use the
# GraphQL / Search API path. --json FIELDS is accepted for parity but
# ignored (the REST endpoint returns the full object; use --jq to select).
#
# Returns the underlying gh api exit code.
#######################################
_rest_issue_list() {
	gh_record_call rest 2>/dev/null || true
	local repo=""
	local state="open"
	local limit=30
	local jq_expr=""
	local assignee=""
	local -a labels
	local _tok
	labels=()

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo) repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--state) state="${2:-}"; shift 2 ;;
		--state=*) state="${_arg#--state=}"; shift ;;
		--label) while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_gh_split_csv "${2:-}"); shift 2 ;;
		--label=*) while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_gh_split_csv "${_arg#--label=}"); shift ;;
		--assignee) assignee="${2:-}"; shift 2 ;;
		--assignee=*) assignee="${_arg#--assignee=}"; shift ;;
		--limit) limit="${2:-}"; shift 2 ;;
		--limit=*) limit="${_arg#--limit=}"; shift ;;
		--json) shift 2 ;;
		--json=*) shift ;;
		--jq) jq_expr="${2:-}"; shift 2 ;;
		--jq=*) jq_expr="${_arg#--jq=}"; shift ;;
		--search) shift 2 ;;
		--search=*) shift ;;
		*) shift ;;
		esac
	done

	if [[ -z "$repo" ]]; then
		printf '_rest_issue_list: --repo is required\n' >&2
		return 1
	fi

	local _query="state=${state}&per_page=${limit}"
	if [[ ${#labels[@]} -gt 0 ]]; then
		local _labels_encoded=""
		local _label
		for _label in "${labels[@]}"; do
			local _enc
			_enc=$(jq -rn --arg v "$_label" '$v | @uri')
			_labels_encoded="${_labels_encoded:+${_labels_encoded}%2C}${_enc}"
		done
		_query="${_query}&labels=${_labels_encoded}"
	fi
	if [[ -n "$assignee" ]]; then
		local _assignee_encoded
		_assignee_encoded=$(jq -rn --arg v "$assignee" '$v | @uri')
		_query="${_query}&assignee=${_assignee_encoded}"
	fi

	local _path="/repos/${repo}/issues?${_query}"
	# t2913: wall-clock timeout via _gh_with_timeout (defined in shared-gh-wrappers.sh).
	local _gh_cmd=(gh api "$_path")
	[[ -n "$jq_expr" ]] && _gh_cmd+=(--jq "$jq_expr")
	if command -v _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "${_gh_cmd[@]}"
	else
		"${_gh_cmd[@]}"
	fi
	return $?
}

#######################################
# _rest_issue_search: GET /search/issues?q=...  (t2995)
# REST-side equivalent of `gh issue list --search`. Used by the gh_issue_list
# wrapper when GraphQL is exhausted AND the call carried a --search filter.
# The plain /repos/{owner}/{repo}/issues endpoint does NOT support full-text
# search, so the prior REST translator silently dropped --search and returned
# label-only results — a silent-correctness bug that caused the file-size-debt
# dedup helper to match wrong issues during exhaustion windows.
#
# Translation:
#   gh issue list --repo OWNER/REPO --state open \
#     --label LABEL --search QUERY --json number --jq '.[0].number'
# becomes:
#   gh api /search/issues?q=QUERY+repo:OWNER/REPO+is:issue+is:open+label:LABEL \
#     --jq '.items[0].number'
#
# Notes:
#   - Search API has its own quota (30 req/min for authenticated users) —
#     separate from both core REST and GraphQL pools.
#   - Multiple --label flags are AND-joined into multiple `+label:"X"` qualifiers.
#   - --json FIELDS is accepted for parity but ignored (caller uses --jq).
#   - --jq expressions written for `gh issue list` operate on a flat array
#     (e.g. `.[0].number`). The /search/issues endpoint wraps results in
#     `{items:[...]}`. To preserve drop-in semantics, we extract `.items`
#     before applying the user's jq filter.
#
# Returns the underlying gh api exit code.
#######################################
_rest_issue_search() {
	gh_record_call rest 2>/dev/null || true
	local repo=""
	local state=""
	local search=""
	local limit=30
	local jq_expr=""
	local -a labels
	local _tok
	labels=()

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo) repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--state) state="${2:-}"; shift 2 ;;
		--state=*) state="${_arg#--state=}"; shift ;;
		--label) while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_gh_split_csv "${2:-}"); shift 2 ;;
		--label=*) while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_gh_split_csv "${_arg#--label=}"); shift ;;
		--limit) limit="${2:-}"; shift 2 ;;
		--limit=*) limit="${_arg#--limit=}"; shift ;;
		--search) search="${2:-}"; shift 2 ;;
		--search=*) search="${_arg#--search=}"; shift ;;
		--json) shift 2 ;;
		--json=*) shift ;;
		--jq) jq_expr="${2:-}"; shift 2 ;;
		--jq=*) jq_expr="${_arg#--jq=}"; shift ;;
		*) shift ;;
		esac
	done

	if [[ -z "$repo" || -z "$search" ]]; then
		printf '_rest_issue_search: --repo and --search are required\n' >&2
		return 1
	fi

	# Build the q= parameter. Each token is URI-encoded individually then
	# joined with `+`. The repo:/is:issue/state qualifiers go AFTER the
	# user-supplied search to preserve the user's term ordering.
	local _q
	_q=$(jq -rn --arg v "$search" '$v | @uri')
	local _repo_enc
	_repo_enc=$(jq -rn --arg v "$repo" '$v | @uri')
	_q="${_q}+repo:${_repo_enc}+is:issue"
	if [[ -n "$state" && "$state" != "all" ]]; then
		# /search/issues uses `is:open` / `is:closed`, not `state:`.
		_q="${_q}+is:${state}"
	fi
	local _label
	for _label in "${labels[@]}"; do
		local _label_enc
		_label_enc=$(jq -rn --arg v "$_label" '$v | @uri')
		_q="${_q}+label:%22${_label_enc}%22"
	done

	local _path="/search/issues?q=${_q}&per_page=${limit}"

	# Translate caller's jq (which expects a flat array) into one that
	# operates on .items. If no --jq, just return .items as a JSON array.
	local _final_jq
	if [[ -n "$jq_expr" ]]; then
		_final_jq=".items | ${jq_expr}"
	else
		_final_jq=".items"
	fi

	local _gh_cmd=(gh api "$_path" --jq "$_final_jq")
	if command -v _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "${_gh_cmd[@]}"
	else
		"${_gh_cmd[@]}"
	fi
	return $?
}
