#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GH Wrappers -- Status Labels, Issue Filtering, Read Wrappers
# =============================================================================
# Functions for issue status label state machine, non-task filtering, and
# gh issue/pr read wrappers with REST fallback on GraphQL exhaustion.
#
# Usage: source "${SCRIPT_DIR}/shared-gh-wrappers-status.sh"
#
# Dependencies:
#   - shared-constants.sh (print_info, etc.)
#   - shared-gh-wrappers-rest-fallback.sh (_rest_should_fallback,
#     _rest_args_have_search, _rest_issue_view, _rest_issue_list,
#     _rest_issue_search, _rest_pr_list)
#   - _gh_with_timeout (from orchestrator)
#   - ISSUE_STATUS_LABELS (from orchestrator)
#   - gh CLI, jq
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_STATUS_LIB_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_STATUS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# Filter out non-task issues from a JSON array.
#
# Reads a JSON array of issue objects (each with .labels[].name) from
# stdin, removes any issue carrying a label in NON_TASK_LABELS, and
# writes the filtered array to stdout.
#
# Usage:
#   filtered=$(echo "$issues_json" | _filter_non_task_issues)
#
# Globals:
#   NON_TASK_LABELS — bash array (defined in orchestrator)
#
# Returns: 0 always (empty input → "[]")
#######################################
_filter_non_task_issues() {
	local _ntl_json
	_ntl_json=$(printf '%s\n' "${NON_TASK_LABELS[@]}" | jq -R . | jq -sc .) || _ntl_json="[]"
	jq --argjson ntl "$_ntl_json" \
		'[.[] | select((.labels // []) | map(.name) | any(. as $n | $ntl[] | . == $n) | not)]' \
		2>/dev/null || echo "[]"
	return 0
}

#######################################
# Return 0 when a gh_pr_list argv shape is safe to serve from the short-lived
# cross-process PR snapshot cache. The cache is deliberately scoped to open PR
# list reads because those dominate pulse dedup/merge pressure and can tolerate
# a small freshness window while keeping dispatch pipelines full.
# Args: gh-style argv
#######################################
_gh_pr_list_snapshot_cacheable() {
	_rest_args_have_search "$@" && return 1
	_rest_pr_list_can_preserve_args "$@" || return 1
	local _state="open"
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--state)
			if [[ $# -gt 1 ]]; then
				_state="$2"
				shift 2
			else
				shift
			fi
			;;
		--state=*) _state="${_arg#--state=}"; shift ;;
		*) shift ;;
		esac
	done
	[[ "$_state" == "open" ]] && return 0
	return 1
}

#######################################
# Build a filesystem-safe key for an exact gh_pr_list argv shape.
# Args: gh-style argv
# Stdout: cache key
#######################################
_gh_pr_list_snapshot_key() {
	local _joined=""
	local _arg
	for _arg in "$@"; do
		_joined="${_joined}${_arg}"$'\034'
	done
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$_joined" | shasum -a 256 | awk '{print $1}'
	elif command -v openssl >/dev/null 2>&1; then
		printf '%s' "$_joined" | openssl dgst -sha256 | awk '{print $NF}'
	else
		printf '%s' "$_joined" | cksum | awk '{print $1}'
	fi
	return 0
}

#######################################
# Build the repository prefix used by PR-list snapshot cache files. Keeping the
# repository hash outside the exact-argv hash allows terminal PR mutations to
# evict every cached open-list shape for one repository without flushing other
# repositories from the shared cache.
# Args: gh-style argv
# Stdout: repository cache key
#######################################
_gh_pr_list_snapshot_repo_key() {
	local _repo_slug=""
	local _arg=""
	local _expect_repo=0
	for _arg in "$@"; do
		if [[ "$_expect_repo" -eq 1 ]]; then
			_repo_slug="$_arg"
			_expect_repo=0
			continue
		fi
		case "$_arg" in
		--repo | -R) _expect_repo=1 ;;
		--repo=*) _repo_slug="${_arg#--repo=}" ;;
		-R?*) _repo_slug="${_arg#-R}" ;;
		esac
	done
	[[ -n "$_repo_slug" ]] || _repo_slug="_implicit"
	_gh_pr_list_snapshot_key "$_repo_slug"
	return $?
}

#######################################
# Record one lightweight telemetry event for the exact gh_pr_list argv shape.
# The shape key is the same full-argv hash used by the exact-output caches, so
# repeated counts identify only semantics-preserving candidates for migration.
# Args: gh-style argv
#######################################
_gh_pr_list_shape_record() {
	local _key
	_key="$(_gh_pr_list_snapshot_key "$@")" || return 0
	_gh_read_cache_record gh_pr_list_shape "shape:${_key}"
	return 0
}

#######################################
# Record a lightweight cache decision in the same instrumentation stream as API
# calls. These records use path=other so cache hit/miss/stale decisions are
# visible without inflating REST/GraphQL call counts.
# Args: $1 = cache name, $2 = decision
#######################################
_gh_read_cache_record() {
	local _cache_name="$1"
	local _decision="$2"
	gh_record_call other "${_cache_name}" unknown other "${_decision}" 2>/dev/null || true
	return 0
}

#######################################
# Record why the exact-output gh_pr_view cache is unavailable without making
# normal non-cache callers noisy. Pulse enables AIDEVOPS_GH_PR_VIEW_CACHE, so
# these records expose disabled/invalid TTL states during cache triage.
# Returns: 0 always.
#######################################
_gh_pr_view_snapshot_record_disabled() {
	if [[ "${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" == "1" ]]; then
		_gh_read_cache_record gh_pr_view_cache bypass-disabled
	elif [[ "${AIDEVOPS_GH_PR_VIEW_CACHE:-0}" == "1" ]]; then
		_gh_read_cache_record gh_pr_view_cache bypass
	fi
	return 0
}

#######################################
# Read a cached gh_pr_list snapshot when present and fresh.
# Args: gh-style argv
# Stdout: cached command output
#######################################
_gh_pr_list_snapshot_get() {
	local _ttl="${AIDEVOPS_GH_PR_LIST_CACHE_TTL:-15}"
	[[ "${AIDEVOPS_GH_PR_LIST_CACHE_DISABLE:-0}" == "1" ]] && return 1
	[[ "$_ttl" =~ ^[0-9]+$ && "$_ttl" -gt 0 ]] || return 1
	_gh_pr_list_snapshot_cacheable "$@" || { _gh_read_cache_record gh_pr_list_cache bypass; return 1; }
	local _repo_key _key _path _now _mtime _age
	_repo_key="$(_gh_pr_list_snapshot_repo_key "$@")" || return 1
	_key="$(_gh_pr_list_snapshot_key "$@")"
	_path="${AIDEVOPS_GH_PR_LIST_CACHE_DIR:-${HOME}/.aidevops/cache/gh-pr-list-snapshots}/${_repo_key}-${_key}.json"
	[[ -f "$_path" ]] || { _gh_read_cache_record gh_pr_list_cache miss; return 1; }
	_now=$(date +%s 2>/dev/null || printf '0')
	_mtime=$(perl -e 'print((stat($ARGV[0]))[9] || 0)' "$_path" 2>/dev/null || printf '0')
	[[ "$_now" =~ ^[0-9]+$ && "$_mtime" =~ ^[0-9]+$ ]] || return 1
	_age=$(( _now - _mtime ))
	[[ "$_age" -ge 0 && "$_age" -le "$_ttl" ]] || { _gh_read_cache_record gh_pr_list_cache stale; return 1; }
	_gh_read_cache_record gh_pr_list_cache hit
	printf '%s' "$(<"$_path")"
	return 0
}

#######################################
# Store a successful gh_pr_list snapshot for a short freshness window.
# This is an exact-output cache: successful empty stdout is a valid value
# for jq filters that intentionally emit nothing on empty result sets. Do not
# reject 0-byte bodies unless the cache format grows explicit corruption
# metadata/sentinels that can distinguish invalid files from valid empty output.
# Args: $1 = command output, $2.. = gh-style argv
#######################################
_gh_pr_list_snapshot_put() {
	local _body="$1"; shift
	local _ttl="${AIDEVOPS_GH_PR_LIST_CACHE_TTL:-15}"
	[[ "${AIDEVOPS_GH_PR_LIST_CACHE_DISABLE:-0}" == "1" ]] && return 0
	[[ "$_ttl" =~ ^[0-9]+$ && "$_ttl" -gt 0 ]] || return 0
	_gh_pr_list_snapshot_cacheable "$@" || return 0
	local _dir _repo_key _key _path _tmp
	_dir="${AIDEVOPS_GH_PR_LIST_CACHE_DIR:-${HOME}/.aidevops/cache/gh-pr-list-snapshots}"
	mkdir -p "$_dir" 2>/dev/null || return 0
	_repo_key="$(_gh_pr_list_snapshot_repo_key "$@")" || return 0
	_key="$(_gh_pr_list_snapshot_key "$@")"
	_path="${_dir}/${_repo_key}-${_key}.json"
	_tmp=$(mktemp "${_dir}/.pr-list-${_key}.XXXXXX" 2>/dev/null) || return 0
	printf '%s' "$_body" >"$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 0; }
	mv "$_tmp" "$_path" 2>/dev/null || rm -f "$_tmp"
	_gh_read_cache_record gh_pr_list_cache store
	return 0
}

#######################################
# Invalidate all cached open-PR list shapes for one repository. Terminal merge
# and close paths call this after GitHub confirms that a PR is no longer open.
# Args: $1 = repository slug
#######################################
gh_pr_list_cache_invalidate_repo() {
	local _repo_slug="$1"
	[[ -n "$_repo_slug" ]] || return 1
	local _dir="${AIDEVOPS_GH_PR_LIST_CACHE_DIR:-${HOME}/.aidevops/cache/gh-pr-list-snapshots}"
	local _repo_key=""
	local _path=""
	local _rc=0
	_repo_key="$(_gh_pr_list_snapshot_key "$_repo_slug")" || return 1
	if [[ -d "$_dir" ]]; then
		for _path in "${_dir}/${_repo_key}-"*.json; do
			[[ -f "$_path" ]] || continue
			rm -f -- "$_path" 2>/dev/null || _rc=1
		done
	fi
	_gh_read_cache_record gh_pr_list_cache invalidate
	return "$_rc"
}

#######################################
# Return 0 when gh_pr_view exact-output caching is enabled. This cache is scoped
# to pulse cycles (or explicit callers) through AIDEVOPS_GH_PR_VIEW_CACHE and is
# keyed by the full argv, so different field sets never share projected output.
# It is intentionally separate from the repo#PR REST-object cache in
# shared-gh-wrappers-rest-fallback.sh: exact-output hits preserve one argv shape,
# while REST-object reuse projects supported fields from one REST response.
# Mutation-sensitive merge gates must set AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1
# before reading mergeable/reviewDecision/check state after update-branch, label,
# review, or merge-state mutations.
#######################################
_gh_pr_view_snapshot_enabled() {
	[[ "${AIDEVOPS_GH_PR_VIEW_CACHE:-0}" == "1" ]] || return 1
	[[ "${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" == "1" ]] && return 1
	local _ttl="${AIDEVOPS_GH_PR_VIEW_CACHE_TTL:-15}"
	[[ "$_ttl" =~ ^[0-9]+$ && "$_ttl" -gt 0 ]] || return 1
	return 0
}

#######################################
# Build a filesystem-safe key for an exact gh_pr_view argv shape.
# Args: gh-style argv
# Stdout: cache key
#######################################
_gh_pr_view_snapshot_key() {
	_gh_pr_list_snapshot_key "$@"
	return $?
}

#######################################
# Resolve the exact-output gh_pr_view cache path for the given argv.
# Args: gh-style argv
# Stdout: cache file path
#######################################
_gh_pr_view_snapshot_path() {
	local _dir="${AIDEVOPS_GH_PR_VIEW_CACHE_DIR:-${HOME}/.aidevops/cache/gh-pr-view-snapshots}"
	mkdir -p "$_dir" 2>/dev/null || return 1
	local _key
	_key="$(_gh_pr_view_snapshot_key "$@")" || return 1
	printf '%s/argv-%s.out' "$_dir" "$_key"
	return 0
}

#######################################
# Read a cached gh_pr_view exact-output snapshot when present and fresh.
# Args: gh-style argv
# Stdout: cached command output
#######################################
_gh_pr_view_snapshot_get() {
	_gh_pr_view_snapshot_enabled || { _gh_pr_view_snapshot_record_disabled; return 1; }
	local _ttl="${AIDEVOPS_GH_PR_VIEW_CACHE_TTL:-15}"
	local _path _now _mtime _age
	_path="$(_gh_pr_view_snapshot_path "$@")" || { _gh_read_cache_record gh_pr_view_cache bypass; return 1; }
	[[ -f "$_path" ]] || { _gh_read_cache_record gh_pr_view_cache miss; return 1; }
	_now=$(date +%s 2>/dev/null || printf '0')
	_mtime=$(perl -e 'print((stat($ARGV[0]))[9] || 0)' "$_path" 2>/dev/null || printf '0')
	[[ "$_now" =~ ^[0-9]+$ && "$_mtime" =~ ^[0-9]+$ ]] || return 1
	_age=$(( _now - _mtime ))
	[[ "$_age" -ge 0 && "$_age" -le "$_ttl" ]] || { _gh_read_cache_record gh_pr_view_cache stale; return 1; }
	_gh_read_cache_record gh_pr_view_cache hit
	printf '%s' "$(<"$_path")"
	return 0
}

#######################################
# Store a successful gh_pr_view exact-output snapshot.
# Args: $1 = command output, $2.. = gh-style argv
#######################################
_gh_pr_view_snapshot_put() {
	local _body="$1"
	shift
	_gh_pr_view_snapshot_enabled || return 0
	local _path _dir _tmp
	_path="$(_gh_pr_view_snapshot_path "$@")" || return 0
	_dir="${_path%/*}"
	_tmp=$(mktemp "${_dir}/.pr-view-argv.XXXXXX" 2>/dev/null) || return 0
	printf '%s' "$_body" >"$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 0; }
	mv "$_tmp" "$_path" 2>/dev/null || rm -f "$_tmp"
	_gh_read_cache_record gh_pr_view_cache store
	return 0
}

#######################################
# Classify a gh pr view --json field for mixed REST/GQL split routing.
# Args: $1 = field name
# Stdout: rest, gql, or unsupported
#######################################
_gh_pr_view_field_route_class() {
	local _field="$1"
	case "$_field" in
	number|state|merged|mergedAt|closedAt|mergeCommit|mergedBy|mergeable|isDraft|labels|author|title|body|url|createdAt|updatedAt|baseRefName|headRefName|headRefOid) printf 'rest' ;;
	statusCheckRollup|reviews|latestReviews|reviewThreads|commits|files|reviewDecision|autoMergeRequest|mergeStateStatus) printf 'gql' ;;
	*) printf 'unsupported' ;;
	esac
	return 0
}

#######################################
# Partition gh pr view fields into REST-safe and GraphQL-only subsets.
# Args: $1 = comma-separated field list
# Stdout: rest fields, gql fields, unsupported count (one line each)
#######################################
_gh_pr_view_partition_fields() {
	local _fields="$1"
	local _rest_fields=""
	local _gql_fields=""
	local _unsupported_count=0
	local _field=""
	local _class=""
	while IFS= read -r _field; do
		[[ -z "$_field" ]] && continue
		_class="$(_gh_pr_view_field_route_class "$_field")"
		case "$_class" in
		rest) _rest_fields="${_rest_fields}${_rest_fields:+,}${_field}" ;;
		gql) _gql_fields="${_gql_fields}${_gql_fields:+,}${_field}" ;;
		*) _unsupported_count=$(( _unsupported_count + 1 )) ;;
		esac
	done < <(_rest_split_csv "$_fields")
	printf '%s\n%s\n%s\n' "$_rest_fields" "$_gql_fields" "$_unsupported_count"
	return 0
}

#######################################
# Build gh-style pr view argv with --json replaced and --jq/-q removed.
# Args: $1 = replacement --json fields, $2.. = original gh pr view argv
# Stdout: NUL-delimited argv for mapfile/readarray-free Bash 3.2 consumers.
#######################################
_gh_pr_view_args_for_json_fields() {
	local _json_fields="$1"
	shift
	local _arg=""
	local _saw_json=0
	while [[ $# -gt 0 ]]; do
		_arg="$1"
		case "$_arg" in
		--json) printf '%s\0%s\0' --json "$_json_fields"; _saw_json=1; shift $(( $# >= 2 ? 2 : 1 )) ;;
		--json=*) printf '%s\0%s\0' --json "$_json_fields"; _saw_json=1; shift ;;
		--jq | -q) shift $(( $# >= 2 ? 2 : 1 )) ;;
		--jq=* | -q=*) shift ;;
		*) printf '%s\0' "$_arg"; shift ;;
		esac
	done
	[[ $_saw_json -eq 0 ]] && printf '%s\0%s\0' --json "$_json_fields"
	return 0
}

#######################################
# Read NUL-delimited argv from stdin into the named array (Bash 3.2 safe).
# Args: $1 = destination array variable name
#######################################
_gh_pr_view_read_nul_argv_into() {
	local _dest_var="$1"
	local _item=""
	eval "$_dest_var=()"
	while IFS= read -r -d '' _item; do
		local _quoted_item=""
		printf -v _quoted_item '%q' "$_item"
		eval "$_dest_var+=(\$_quoted_item)"
	done
	return 0
}

#######################################
# Serve mixed REST/GQL gh_pr_view field sets by fetching REST-equivalent fields
# through the REST translator and only GraphQL-only fields through gh pr view.
# Args: gh-style argv
# Stdout: merged gh-compatible output, with original --jq/-q applied if present.
# Returns: 0 when split handled; 1 when caller should use the legacy path.
#######################################
_gh_pr_view_try_mixed_split() {
	local -a _orig_args=("$@")
	local _fields=""
	_fields="$(_rest_args_json_fields "${_orig_args[@]}")"
	[[ -n "$_fields" ]] || return 1
	local _rest_fields="" _gql_fields="" _unsupported_count="0"
	{ read -r _rest_fields; read -r _gql_fields; read -r _unsupported_count; } < <(_gh_pr_view_partition_fields "$_fields")
	[[ -n "$_rest_fields" && -n "$_gql_fields" && "$_unsupported_count" == "0" ]] || return 1
	local _jq_expr=""
	local _i=0
	while [[ $_i -lt ${#_orig_args[@]} ]]; do
		case "${_orig_args[$_i]}" in
		--jq | -q) _i=$(( _i + 1 )); _jq_expr="${_orig_args[$_i]:-}" ;;
		--jq=* | -q=*) _jq_expr="${_orig_args[$_i]#*=}" ;;
		*) ;;
		esac
		_i=$(( _i + 1 ))
	done
	local -a _rest_args=()
	local -a _gql_args=()
	_gh_pr_view_read_nul_argv_into _rest_args < <(_gh_pr_view_args_for_json_fields "$_rest_fields" "${_orig_args[@]}")
	_gh_pr_view_read_nul_argv_into _gql_args < <(_gh_pr_view_args_for_json_fields "$_gql_fields" "${_orig_args[@]}")
	local _rest_out="" _gql_out="" _merged=""
	_rest_out="$(_rest_pr_view "${_rest_args[@]}")" || return 1
	gh_record_call graphql gh_pr_view_split 2>/dev/null || true
	_gql_out="$(_gh_with_timeout read gh pr view "${_gql_args[@]}")" || return 1
	_merged="$(jq -c -s '(.[0] // {}) * (.[1] // {})' < <(printf '%s\n%s\n' "$_rest_out" "$_gql_out"))" || return 1
	if [[ -n "$_jq_expr" ]]; then
		printf '%s\n' "$_merged" | jq -r "$_jq_expr"
		return $?
	fi
	printf '%s' "$_merged"
	return 0
}

# Print the managed status-label contract as name/color/description TSV rows.
_status_label_contract() {
	printf '%s\t%s\t%s\n' \
		"status:available" "0e8a16" "Task is available for claiming" \
		"status:queued" "fbca04" "Worker dispatched, not yet started" \
		"status:claimed" "f9d0c4" "Interactive implementation is actively claimed" \
		"status:in-progress" "1d76db" "Worker actively running" \
		"status:in-review" "5319e7" "Non-draft PR ready for review/merge" \
		"status:done" "6f42c1" "Task is complete" \
		"status:blocked" "d93f0b" "Partial work blocked; inspect reason and next action"
	return 0
}

# Fetch only exact contract labels in one request, independent of repo label count.
# Aliases avoid both repository-wide pagination and truncated label search results.
_status_labels_snapshot() {
	local repo="$1"
	local fields=""
	local response=""
	local name=""
	local index=0
	while IFS=$'\t' read -r name _; do
		fields="${fields} label${index}: label(name: \"${name}\") { name color description }"
		index=$((index + 1))
	done < <(_status_label_contract)
	AIDEVOPS_GH_ROUTE_DECISION="status-label-contract-exact-graphql" \
		response=$(_gh_with_timeout read gh api graphql \
		-f query="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) { ${fields} } }" \
		-f owner="${repo%%/*}" -f name="${repo#*/}") || return 1
	# Null labels mean confirmed absence. Errors, null repositories and malformed
	# partial responses are unknown state and must never trigger label mutations.
	printf '%s' "$response" | jq -er --argjson count "$index" '
		def is_string: type == "string";
		if ((.errors // []) | length) == 0
			and (.data.repository | type) == "object"
			and (.data.repository | length) == $count
			and all(.data.repository[]; . == null or
				(type == "object" and (.name | is_string)
				and (.color | is_string)
				and (.description == null or (.description | is_string))))
		then [.data.repository[] | select(. != null) |
			[.name, (.color | ascii_downcase), (.description // "")] | @tsv] | join("\n")
		else error("unable to verify exact status-label snapshot") end'
	return $?
}

# Print color/description for one exact label name from a snapshot.
_status_label_snapshot_definition() {
	local snapshot="$1"
	local expected_name="$2"
	local name=""
	local color=""
	local description=""
	while IFS=$'\t' read -r name color description; do
		if [[ "$name" == "$expected_name" ]]; then
			printf '%s\t%s' "$color" "$description"
			return 0
		fi
	done <<<"$snapshot"
	return 1
}

# Return success only when a snapshot exactly satisfies the full contract.
_status_label_snapshot_matches_contract() {
	local snapshot="$1"
	local name=""
	local color=""
	local description=""
	local actual=""
	while IFS=$'\t' read -r name color description; do
		actual=$(_status_label_snapshot_definition "$snapshot" "$name") || return 1
		[[ "$actual" == "${color}"$'\t'"${description}" ]] || return 1
	done < <(_status_label_contract)
	return 0
}

# Create a missing definition or reconcile a concurrent create deterministically.
_status_label_create_or_reconcile() {
	local repo="$1"
	local name="$2"
	local color="$3"
	local description="$4"
	if AIDEVOPS_GH_ROUTE_DECISION="status-label-contract-create-rest" \
		_gh_with_timeout write gh label create "$name" --repo "$repo" \
		--description "$description" --color "$color" 2>/dev/null; then
		return 0
	fi

	local refreshed=""
	local actual=""
	refreshed=$(_status_labels_snapshot "$repo") || return 1
	actual=$(_status_label_snapshot_definition "$refreshed" "$name") || return 1
	if [[ "$actual" == "${color}"$'\t'"${description}" ]]; then
		return 0
	fi
	AIDEVOPS_GH_ROUTE_DECISION="status-label-contract-edit-rest" \
		_gh_with_timeout write gh label edit "$name" --repo "$repo" \
		--description "$description" --color "$color"
	return $?
}

# Ensure all core status:* labels exist on a repo (idempotent, cached per-process).
# A converged repository costs one exact-label read and zero writes. Missing or
# drifted definitions are reconciled, then the complete contract is re-verified
# before the process-local cache is populated.
#
# Usage: ensure_status_labels_exist "owner/repo"
_STATUS_LABELS_ENSURED=""
ensure_status_labels_exist() {
	local repo="$1"
	[[ -z "$repo" ]] && return 1
	# Skip if already ensured for this repo in this process
	case ",${_STATUS_LABELS_ENSURED}," in
	*",${repo},"*) return 0 ;;
	esac

	local snapshot=""
	snapshot=$(_status_labels_snapshot "$repo") || return 1
	if ! _status_label_snapshot_matches_contract "$snapshot"; then
		local name=""
		local color=""
		local description=""
		local actual=""
		while IFS=$'\t' read -r name color description; do
			actual=$(_status_label_snapshot_definition "$snapshot" "$name") || actual=""
			[[ "$actual" == "${color}"$'\t'"${description}" ]] && continue
			if [[ -n "$actual" ]]; then
				AIDEVOPS_GH_ROUTE_DECISION="status-label-contract-edit-rest" \
					_gh_with_timeout write gh label edit "$name" --repo "$repo" \
					--description "$description" --color "$color" || return 1
			else
				_status_label_create_or_reconcile "$repo" "$name" "$color" "$description" || return 1
			fi
		done < <(_status_label_contract)
		snapshot=$(_status_labels_snapshot "$repo") || return 1
		_status_label_snapshot_matches_contract "$snapshot" || return 1
	fi

	_STATUS_LABELS_ENSURED="${_STATUS_LABELS_ENSURED:+${_STATUS_LABELS_ENSURED},}${repo}"
	return 0
}

#######################################
# GH#38360: status:blocked must carry a needs-* companion label that names
# what unblocks it; a bare status:blocked is a false block.
#
# Companion label contract as name/color/description TSV rows. Definitions
# match label-sync-helper.sh SYSTEM_LABELS so a sync never fights a lazy create.
# The first three are owned by the blocked state: set_issue_status removes them
# whenever an issue leaves status:blocked. needs-credentials keeps its own
# maintainer-owned lifecycle (terminal re-arm also clears it).
#######################################
[[ -n "${BLOCKED_NEEDS_AI_RECOVERY+x}" ]] || BLOCKED_NEEDS_AI_RECOVERY="needs-ai-recovery"
[[ -n "${BLOCKED_NEEDS_DEPENDENCY+x}" ]] || BLOCKED_NEEDS_DEPENDENCY="needs-dependency"
[[ -n "${BLOCKED_NEEDS_SOURCE_ACCESS+x}" ]] || BLOCKED_NEEDS_SOURCE_ACCESS="needs-source-access"
[[ -n "${BLOCKED_NEEDS_MAINTAINER_INPUT+x}" ]] || BLOCKED_NEEDS_MAINTAINER_INPUT="needs-maintainer-input"
[[ -n "${BLOCKED_NEEDS_CREDENTIALS+x}" ]] || BLOCKED_NEEDS_CREDENTIALS="needs-credentials"
_blocked_companion_contract() {
	local attention="E4007C"
	printf '%s\t%s\t%s\n' \
		"$BLOCKED_NEEDS_AI_RECOVERY" "$attention" "Blocked: AI recovery pending; the recovery supervisor solves or releases it, no human action needed" \
		"$BLOCKED_NEEDS_DEPENDENCY" "$attention" "Blocked: waits on a linked open issue; solve that first, unblocks when it closes" \
		"$BLOCKED_NEEDS_SOURCE_ACCESS" "$attention" "Blocked: a required external source refuses access; needs a permitted capture, an alternative source, or host recovery" \
		"$BLOCKED_NEEDS_MAINTAINER_INPUT" "$attention" "Blocked: owner decision or input that AI cannot supply; the issue names the exact ask" \
		"$BLOCKED_NEEDS_CREDENTIALS" "$attention" "Opt-out: block auto-dispatch — requires credentials or account access"
	return 0
}

# Companions owned by the blocked state (removed on every exit from blocked).
BLOCKED_OWNED_COMPANION_LABELS=("$BLOCKED_NEEDS_AI_RECOVERY" "$BLOCKED_NEEDS_DEPENDENCY" "$BLOCKED_NEEDS_MAINTAINER_INPUT" "$BLOCKED_NEEDS_SOURCE_ACCESS")

#######################################
# Print the needs-* companion label for a blocker reason class.
#
# Human-owned classes name the exact human input. Runner- and brief-owned
# classes (runner_capability_unmet, push/network policy timeouts, missing or
# excluded Files Scope, target_code_blocker, unknown, and any unrecognised
# reason) are AI-resolvable: they map to needs-ai-recovery, which routes the
# hold to the recovery supervisor instead of a human.
#
# permission_required maps to needs-maintainer-input, not
# needs-maintainer-permissions: that label is reserved for scoped grant
# requests from worker-permission-helper.sh, whose approval flow clears it; a
# terminal-only denial has no request envelope (headless-runtime-failure.sh
# _hrff_apply_terminal_permission_hold).
#
# Args: $1 = reason class
#######################################
blocked_needs_label_for_reason() {
	local reason="${1:-}"
	case "$reason" in
	input_required | permission_required | maintainer_input | spend_decision)
		printf '%s\n' "$BLOCKED_NEEDS_MAINTAINER_INPUT"
		;;
	source_access_blocked)
		printf '%s\n' "$BLOCKED_NEEDS_SOURCE_ACCESS"
		;;
	credentials | missing_secret)
		printf '%s\n' "$BLOCKED_NEEDS_CREDENTIALS"
		;;
	external_trigger_pending | dependency)
		printf '%s\n' "$BLOCKED_NEEDS_DEPENDENCY"
		;;
	*)
		printf '%s\n' "$BLOCKED_NEEDS_AI_RECOVERY"
		;;
	esac
	return 0
}

#######################################
# Print a one-line public explanation for a companion label: what is needed,
# who supplies it, the secure route, and what runs automatically afterwards.
# Args: $1 = companion label, $2 = optional reason class (an
#       external_trigger_pending hold has no linked blocking issue)
#######################################
blocked_companion_guidance() {
	local label="${1:-}"
	local reason="${2:-}"
	if [[ "$label" == "needs-dependency" && "$reason" == "external_trigger_pending" ]]; then
		printf '%s\n' 'Needed: the awaited trigger named above. Owner: the trigger-revisit pass (no human action) checks public evidence on a schedule and posts the retry directive when the trigger is met; an OWNER/MEMBER may post it sooner. Afterwards dispatch resumes automatically.'
		return 0
	fi
	case "$label" in
	needs-ai-recovery)
		# shellcheck disable=SC2016 # literal Markdown backticks
		printf '%s\n' 'Needed: AI recovery. Owner: the recovery supervisor (no human action). It solves or releases the hold, or names the one human input with a specific `needs-*` label and a comment. Afterwards dispatch resumes automatically.'
		;;
	needs-dependency)
		printf '%s\n' 'Needed: the linked blocking issue must close. Owner: whoever solves that issue (usually a worker). Afterwards the dependency pass removes status:blocked and this label automatically.'
		;;
	needs-maintainer-input)
		printf '%s\n' 'Needed: one owner decision or input that AI cannot supply (named in the brief or the latest blocker comment). Owner: maintainer. Route: answer in the issue brief, or post the retry directive; never paste secrets into issues. Afterwards the recovery pass removes status:blocked and this label and dispatch resumes.'
		;;
	needs-credentials)
		# shellcheck disable=SC2016 # literal Markdown backticks
		printf '%s\n' 'Needed: credentials or account access. Owner: maintainer. Route: provision on a runner with `aidevops secret set NAME` (never in issues or comments), then post the retry directive. Afterwards the recovery pass removes status:blocked and this label and dispatch resumes.'
		;;
	needs-source-access)
		printf '%s\n' 'Needed: a permitted capture, an alternative official source, or the host recovering. Owner: access owner. Route: provide the source through an approved channel or confirm the canonical site in the issue; never paste secrets into issues. Afterwards the recovery pass removes status:blocked and this label and dispatch resumes.'
		;;
	needs-maintainer-permissions)
		printf '%s\n' 'Needed: a scoped maintainer permission grant. Owner: maintainer. Route: approve the recorded permission request through the approval flow. Afterwards the grant verification removes status:blocked and this label.'
		;;
	*)
		printf '%s\n' 'Needed: see the latest blocker comment for the exact input and owner.'
		;;
	esac
	return 0
}

#######################################
# Ensure one companion label exists (lazy, cached per process and repo).
# Best-effort: REST label additions create a missing label anyway; this keeps
# the native gh fallback and the catalogued colour/description working.
# Args: $1 = repo slug, $2 = label
#######################################
_BLOCKED_COMPANIONS_ENSURED=""
ensure_blocked_companion_label() {
	local repo="$1"
	local label="$2"
	local name="" color="" description="" found=0 encoded=""
	[[ -n "$repo" && -n "$label" ]] || return 1
	case ",${_BLOCKED_COMPANIONS_ENSURED}," in
	*",${repo}|${label},"*) return 0 ;;
	esac
	while IFS=$'\t' read -r name color description; do
		if [[ "$name" == "$label" ]]; then
			found=1
			break
		fi
	done < <(_blocked_companion_contract)
	if [[ "$found" -eq 1 ]]; then
		encoded=$(printf '%s' "$label" | jq -sRr '@uri' 2>/dev/null) || encoded="$label"
		if ! AIDEVOPS_GH_ROUTE_DECISION="blocked-companion-label-read-rest" \
			_gh_with_timeout read gh api "repos/${repo}/labels/${encoded}" >/dev/null 2>&1; then
			AIDEVOPS_GH_ROUTE_DECISION="blocked-companion-label-create-rest" \
				_gh_with_timeout write gh label create "$label" --repo "$repo" \
				--color "$color" --description "$description" >/dev/null 2>&1 || true
		fi
	fi
	_BLOCKED_COMPANIONS_ENSURED="${_BLOCKED_COMPANIONS_ENSURED:+${_BLOCKED_COMPANIONS_ENSURED},}${repo}|${label}"
	return 0
}

#######################################
# Print every needs-* label the passthrough edit flags add, one per line.
# Returns 0 when at least one is present.
# Args: edit flags (as passed to set_issue_status after the status)
#######################################
_blocked_flags_add_needs_label() {
	local arg="" value="" token="" expect_value=0 found=1
	local -a tokens=()
	for arg in "$@"; do
		if [[ "$expect_value" -eq 1 ]]; then
			value="$arg"
			expect_value=0
		elif [[ "$arg" == "--add-label" ]]; then
			expect_value=1
			continue
		elif [[ "$arg" == --add-label=* ]]; then
			value="${arg#--add-label=}"
		else
			continue
		fi
		IFS=',' read -r -a tokens <<<"$value"
		for token in ${tokens[@]+"${tokens[@]}"}; do
			token="${token#"${token%%[![:space:]]*}"}"
			if [[ "$token" == needs-* ]]; then
				printf '%s\n' "$token"
				found=0
			fi
		done
	done
	return "$found"
}

#######################################
# Print the companion label set_issue_status must add with status:blocked, or
# nothing when the passthrough flags or the live issue already carry a needs-*
# label. A caller that names no reason gets the AI-recovery route plus a
# warning, so a new writer can never create an unexplained hold.
# Args: $1 = issue number, $2 = repo slug, $@ = passthrough edit flags
#######################################
_blocked_status_companion_label() {
	local issue_num="$1"
	local repo_slug="$2"
	shift 2
	local issue_json="" explicit="" label=""
	if explicit=$(_blocked_flags_add_needs_label "$@"); then
		# Caller named the reason: only make sure catalogued companions exist.
		while IFS= read -r label; do
			[[ -n "$label" ]] && ensure_blocked_companion_label "$repo_slug" "$label"
		done <<<"$explicit"
		return 0
	fi
	AIDEVOPS_GH_ROUTE_DECISION="blocked-companion-snapshot-rest" \
		issue_json=$(_rest_api_call read gh api "/repos/${repo_slug}/issues/${issue_num}" 2>/dev/null) || issue_json=""
	# Companions the same call removes do not count as remaining.
	local arg="" removed="" expect_value=0
	for arg in "$@"; do
		if [[ "$expect_value" -eq 1 ]]; then
			removed+=",${arg}"
			expect_value=0
		elif [[ "$arg" == "--remove-label" ]]; then
			expect_value=1
		elif [[ "$arg" == --remove-label=* ]]; then
			removed+=",${arg#--remove-label=}"
		fi
	done
	if [[ -n "$issue_json" ]] && printf '%s' "$issue_json" |
		jq -e --arg removed "$removed" '($removed | split(",")) as $rm
			| any(.labels[]?; (.name // "") as $n | ($n | startswith("needs-")) and (($rm | index($n)) == null))' >/dev/null 2>&1; then
		return 0
	fi
	print_warning "gh-wrapper: status:blocked on #${issue_num} in ${repo_slug} named no needs-* reason; routing to ${BLOCKED_NEEDS_AI_RECOVERY} (GH#38360)"
	printf '%s\n' "$BLOCKED_NEEDS_AI_RECOVERY"
	return 0
}

#######################################
# Print blocked-owned companion labels present on the live issue, one per
# line, for native fallbacks. Prints nothing for a blocked target or when the
# snapshot is unavailable, so an absent label is never named.
# Args: $1 = target status, $2 = issue number, $3 = repo slug
#######################################
_blocked_companions_present_live() {
	local new_status="$1"
	local issue_num="$2"
	local repo_slug="$3"
	local issue_json="" label="" issue_path="/repos/${repo_slug}/issues"
	[[ "$new_status" != blocked ]] || return 0
	AIDEVOPS_GH_ROUTE_DECISION="blocked-companion-removal-snapshot-rest" \
		issue_json=$(_rest_api_call read gh api "${issue_path}/${issue_num}" 2>/dev/null) || return 0
	for label in "${BLOCKED_OWNED_COMPANION_LABELS[@]}"; do
		if printf '%s' "$issue_json" | jq -e --arg l "$label" 'any(.labels[]?; .name == $l)' >/dev/null 2>&1; then
			printf '%s\n' "$label"
		fi
	done
	return 0
}

#######################################
# Print set_issue_status companion deltas as "<add|remove>\t<label>" lines.
# Target blocked adds its needs-* companion (on both edit paths). Any other
# target removes the blocked-owned companions; the caller applies removals to
# the REST delta path only, whose snapshot filters absent labels, so the
# native fallback never names a label the repo may lack.
# Args: $1 = target status, $2 = issue number, $3 = repo slug,
#       $@ = passthrough edit flags
#######################################
_blocked_companion_status_deltas() {
	local new_status="$1"
	local issue_num="$2"
	local repo_slug="$3"
	shift 3
	local label=""
	if [[ "$new_status" != "blocked" ]]; then
		for label in "${BLOCKED_OWNED_COMPANION_LABELS[@]}"; do
			printf 'remove\t%s\n' "$label"
		done
		return 0
	fi
	label=$(_blocked_status_companion_label "$issue_num" "$repo_slug" "$@") || label=""
	[[ -z "$label" ]] || printf 'add\t%s\n' "$label"
	return 0
}

#######################################
# Return 0 when the target status is empty (clear only) or a managed status;
# otherwise print the set_issue_status usage error and return 1.
# Args: $1 = target status (without the status: prefix)
#######################################
_issue_status_target_valid() {
	local new_status="$1"
	local status=""
	[[ -n "$new_status" ]] || return 0
	for status in "${ISSUE_STATUS_LABELS[@]}"; do
		[[ "$status" == "$new_status" ]] && return 0
	done
	printf 'set_issue_status: invalid status "%s" (valid: %s)\n' \
		"$new_status" "${ISSUE_STATUS_LABELS[*]}" >&2
	return 1
}

#######################################
# Pick the deterministic survivor from newline-separated managed status names.
# The canonical precedence is shared with the issue invariant reconciler.
_status_convergence_survivor() {
	local statuses="$1"
	local precedent=""
	local current=""
	local has_available=0
	local has_blocked=0
	local has_active=0
	local blocked_status="blocked"
	while IFS= read -r current; do
		[[ "$current" == "available" ]] && has_available=1
		[[ "$current" == "$blocked_status" ]] && has_blocked=1
		[[ "$current" != "available" && "$current" != "$blocked_status" ]] && has_active=1
	done <<<"$statuses"
	if [[ "$has_available" -eq 1 && "$has_blocked" -eq 1 && "$has_active" -eq 0 ]]; then
		printf '%s\n' "$blocked_status"
		return 0
	fi
	for precedent in "${ISSUE_STATUS_LABEL_PRECEDENCE[@]}"; do
		while IFS= read -r current; do
			[[ "$current" == "$precedent" ]] && {
				printf '%s\n' "$precedent"
				return 0
			}
		done <<<"$statuses"
	done
	return 1
}

#######################################
# Print only canonical managed statuses from a validated issue snapshot.
# Other status-prefixed workflow labels are unrelated metadata.
_managed_statuses_from_snapshot() {
	local current_json="$1"
	local label=""
	local managed=""
	_rest_issue_delta_snapshot_valid "$current_json" || return 1
	while IFS= read -r label; do
		for managed in "${ISSUE_STATUS_LABELS[@]}"; do
			[[ "$label" == "status:${managed}" ]] && {
				printf '%s\n' "$managed"
				break
			}
		done
	done < <(printf '%s' "$current_json" | jq -r '.labels[].name')
	return 0
}

#######################################
# Count non-empty newline-separated statuses without external tooling.
_managed_status_count() {
	local statuses="$1"
	local current=""
	local count=0
	while IFS= read -r current; do
		[[ -n "$current" ]] && count=$((count + 1))
	done <<<"$statuses"
	printf '%s\n' "$count"
	return 0
}

#######################################
# Read and validate the current canonical managed statuses.
_read_managed_issue_statuses() {
	local issue_path="$1"
	local route="$2"
	local current_json=""
	AIDEVOPS_GH_ROUTE_DECISION="$route" \
		current_json=$(_rest_api_call read gh api "$issue_path" 2>/dev/null) || return 1
	_managed_statuses_from_snapshot "$current_json"
	return $?
}

#######################################
# Re-read immediately before destructive repair, then remove only losers from
# that fresh snapshot. Prints the winner used by the repair.
_repair_issue_status_conflict() {
	local issue_num="$1"
	local issue_path="$2"
	local statuses=""
	local status_count=0
	local winner=""
	local current=""
	statuses=$(_read_managed_issue_statuses "$issue_path" "status-convergence-repair-snapshot-rest") || return 1
	status_count=$(_managed_status_count "$statuses") || return 1
	[[ "$status_count" -gt 0 ]] || return 1
	if [[ "$status_count" -eq 1 ]]; then
		printf '%s\n' "$statuses"
		return 0
	fi
	winner=$(_status_convergence_survivor "$statuses") || return 1
	gh_record_call rest status_convergence_conflict unknown rest-core status-convergence-conflict 2>/dev/null || true
	print_warning "gh-wrapper: reconciling competing managed statuses on issue ${issue_num} to status:${winner}"
	while IFS= read -r current; do
		[[ -n "$current" && "$current" != "$winner" ]] || continue
		gh_record_call rest status_convergence_repair unknown rest-core status-convergence-repair 2>/dev/null || true
		AIDEVOPS_GH_ROUTE_DECISION="status-convergence-repair-rest" \
			_rest_issue_remove_label_deltas "$issue_path" "status:${current}" || return 1
	done <<<"$statuses"
	printf '%s\n' "$winner"
	return 0
}

#######################################
# Restore a precedence winner only when a terminal read observed no managed
# status. A different surviving status is never overwritten. The add and final
# read are each attempted once, bounding recovery from a stale loser deletion.
_compensate_missing_issue_status() {
	local issue_path="$1"
	local winner="$2"
	local statuses=""
	gh_record_call rest status_convergence_compensate unknown rest-core status-convergence-compensate 2>/dev/null || true
	AIDEVOPS_GH_ROUTE_DECISION="status-convergence-compensate-rest" \
		_rest_issue_apply_array_delta POST "${issue_path}/labels" labels "status:${winner}" || return 1
	statuses=$(_read_managed_issue_statuses "$issue_path" "status-convergence-compensate-verify-rest") || return 1
	[[ "$statuses" == "$winner" ]]
	return $?
}

#######################################
# Verify one completed status mutation and repair one observed conflict.
# This is bounded eventual convergence, not an atomic compare-and-swap: one
# verification read is typical; conflicts get one fresh repair snapshot, one
# loser-removal pass, and one terminal read.
_verify_issue_status_convergence() {
	local issue_num="$1"
	local repo_slug="$2"
	local cleared_status="$3"
	local issue_path="/repos/${repo_slug}/issues/${issue_num}"
	local statuses=""
	local status_count=0
	local winner=""

	gh_record_call rest status_convergence_verify unknown rest-core status-convergence-verify 2>/dev/null || true
	statuses=$(_read_managed_issue_statuses "$issue_path" "status-convergence-verify-rest") || return 1
	status_count=$(_managed_status_count "$statuses") || return 1
	if [[ "$status_count" -eq 0 ]]; then
		[[ -z "$cleared_status" ]] && return 0
		return 1
	fi
	[[ "$status_count" -eq 1 ]] && return 0
	winner=$(_repair_issue_status_conflict "$issue_num" "$issue_path") || return 1

	gh_record_call rest status_convergence_terminal_verify unknown rest-core status-convergence-terminal-verify 2>/dev/null || true
	statuses=$(_read_managed_issue_statuses "$issue_path" "status-convergence-terminal-verify-rest") || return 1
	if [[ "$statuses" != "$winner" ]]; then
		status_count=$(_managed_status_count "$statuses") || return 1
		[[ "$status_count" -eq 0 ]] || return 1
		_compensate_missing_issue_status "$issue_path" "$winner" || return 1
	fi
	gh_record_call rest status_convergence_complete unknown rest-core status-convergence-complete 2>/dev/null || true
	return 0
}

#######################################
# Transition an issue to one status:* label (t2033).
#
# The REST-first path uses targeted label and assignee subresource mutations so
# a stale read cannot replace concurrent unrelated values. Passthrough deltas
# complete before status reconciliation, so an invalid assignee or unrelated
# label cannot strand a partially applied status transition. Each phase retains
# native `gh issue edit` as a compatibility fallback. This is the ONLY sanctioned
# way to change an issue's status label so the state machine remains central.
#
# Args:
#   $1 — issue number
#   $2 — repo slug (owner/repo)
#   $3 — new status: one of available|queued|claimed|in-progress|in-review|done|blocked
#        OR empty string to clear all core status labels without adding one
#        (used only when a caller intentionally wants no lifecycle status)
#   $@ — additional gh issue edit flags passed through verbatim (e.g.,
#        --add-assignee, --remove-assignee, --add-label "other-non-status-label")
#
# Returns:
#   0 on gh success (including idempotent no-op cases)
#   1 on gh failure (logged; callers typically ignore with || true to match
#     the existing convention for best-effort label operations)
#   2 on invalid status argument (caller bug — not suppressed)
#
# Example:
#   set_issue_status 18444 owner/repo queued \
#       --add-assignee "$worker_login" \
#       --add-label "origin:worker"
#
#   set_issue_status 18444 owner/repo blocked \
#       --add-label "$(blocked_needs_label_for_reason input_required)"
#
# Blocked companions (GH#38360): `blocked` always lands with a needs-* label.
# Callers should name the reason via blocked_needs_label_for_reason; when the
# flags and the live issue carry no needs-* label, needs-ai-recovery is added
# with a warning. Any other target removes BLOCKED_OWNED_COMPANION_LABELS.
#######################################
set_issue_status() {
	gh_record_call rest set_issue_status 2>/dev/null || true
	local issue_num="$1"
	local repo_slug="$2"
	local new_status="$3"
	shift 3

	# Validate inputs
	if [[ -z "$issue_num" || -z "$repo_slug" ]]; then
		printf 'set_issue_status: issue_num and repo_slug are required\n' >&2
		return 2
	fi

	# Validate target status (empty is allowed = clear only)
	_issue_status_target_valid "$new_status" || return 2

	# Ensure labels exist (cached per-process per-repo so this is cheap).
	# Fail closed: an unknown repository-label contract makes sibling removals
	# unsafe and must not proceed to either edit path.
	if ! ensure_status_labels_exist "$repo_slug"; then
		print_warning "gh-wrapper: unable to verify status-label contract for ${repo_slug}"
		return 1
	fi

	# Build status-only flags: remove all core labels, add target if non-empty.
	local -a _status_flags=()
	local _label
	for _label in "${ISSUE_STATUS_LABELS[@]}"; do
		if [[ "$_label" == "$new_status" ]]; then
			_status_flags+=(--add-label "status:${_label}")
		else
			_status_flags+=(--remove-label "status:${_label}")
		fi
	done

	# GH#38360: blocked adds a needs-* companion on both edit paths; other
	# targets remove blocked-owned companions on the REST delta path only.
	local -a _status_rest_flags=("${_status_flags[@]}")
	local _companion_op="" _companion=""
	while IFS=$'\t' read -r _companion_op _companion; do
		[[ -n "$_companion" ]] || continue
		_status_rest_flags+=("--${_companion_op}-label" "$_companion")
		[[ "$_companion_op" == "add" ]] || continue
		ensure_blocked_companion_label "$repo_slug" "$_companion" || true
		_status_flags+=(--add-label "$_companion")
	done < <(_blocked_companion_status_deltas "$new_status" "$issue_num" "$repo_slug" "$@")

	# Complete passthrough deltas before touching status labels. If both REST and
	# native handling reject an extra (for example, an invalid assignee), the
	# existing status remains unchanged rather than becoming a dual-label state.
	local -a _extra_flags=("$@")
	local _rc=0
	local _native_flags=() _present=""
	if [[ ${#_extra_flags[@]} -gt 0 ]]; then
		AIDEVOPS_GH_ROUTE_DECISION="status-extra-edit-rest-deltas" \
			_rest_issue_edit_preserving_deltas "$issue_num" --repo "$repo_slug" "${_extra_flags[@]}"
		_rc=$?
		if [[ $_rc -ne 0 ]]; then
			if [[ "${_REST_ISSUE_DELTA_FAILURE_STAGE:-}" != "mutation" ]]; then
				print_info "[INFO] gh-wrapper: REST status preflight unavailable, using combined native edit"
				gh_record_call graphql set_issue_status_combined_native_fallback 2>/dev/null || true
				_native_flags=("${_status_flags[@]}")
				while IFS= read -r _present; do
					[[ -n "$_present" ]] && _native_flags+=(--remove-label "$_present")
				done < <(_blocked_companions_present_live "$new_status" "$issue_num" "$repo_slug")
				AIDEVOPS_GH_ROUTE_DECISION="status-combined-native-fallback" \
					_gh_with_timeout write gh issue edit "$issue_num" --repo "$repo_slug" \
					"${_native_flags[@]}" "${_extra_flags[@]}" 2>/dev/null
				_rc=$?
				[[ $_rc -eq 0 ]] || return $_rc
				_verify_issue_status_convergence "$issue_num" "$repo_slug" "$new_status"
				return $?
			fi
			print_info "[INFO] gh-wrapper: REST status extras failed, falling back to native gh issue edit"
			gh_record_call graphql set_issue_status_extra_native_fallback 2>/dev/null || true
			AIDEVOPS_GH_ROUTE_DECISION="status-extra-edit-native-fallback" \
				_gh_with_timeout write gh issue edit "$issue_num" --repo "$repo_slug" "${_extra_flags[@]}" 2>/dev/null
			_rc=$?
		fi
		[[ $_rc -eq 0 ]] || return $_rc
	fi

	AIDEVOPS_GH_ROUTE_DECISION="status-issue-edit-rest-deltas" \
		_rest_issue_edit_preserving_deltas "$issue_num" --repo "$repo_slug" \
		--delta-order remove-first "${_status_rest_flags[@]}"
	_rc=$?
	if [[ $_rc -ne 0 ]]; then
		print_info "[INFO] gh-wrapper: REST status delta edit failed, falling back to native gh issue edit"
		gh_record_call graphql set_issue_status_native_fallback 2>/dev/null || true
		_native_flags=("${_status_flags[@]}")
		while IFS= read -r _present; do
			[[ -n "$_present" ]] && _native_flags+=(--remove-label "$_present")
		done < <(_blocked_companions_present_live "$new_status" "$issue_num" "$repo_slug")
		AIDEVOPS_GH_ROUTE_DECISION="status-issue-edit-native-fallback" \
			_gh_with_timeout write gh issue edit "$issue_num" --repo "$repo_slug" "${_native_flags[@]}" 2>/dev/null
		_rc=$?
	fi
	[[ $_rc -eq 0 ]] || return $_rc
	_verify_issue_status_convergence "$issue_num" "$repo_slug" "$new_status"
	return $?
}

#######################################
# Transition an owned issue between accepted worker states without ever
# removing the source state before the target state has been accepted.
#
# The source label and owner are checked against the same REST snapshot used to
# plan targeted mutations. The target is added before sibling statuses are
# removed. There is deliberately no native fallback: if REST preflight or a
# mutation fails, retaining the source label (or a temporary source+target
# overlap) is safer than creating an unowned gap or overwriting a takeover.
#
# Args:
#   $1 — issue number
#   $2 — repo slug (owner/repo)
#   $3 — required assignee login
#   $4 — required source status
#   $5 — target status
# Returns: 0 on complete transition, 1 on precondition/mutation failure,
#          2 on invalid arguments
#######################################
transition_owned_issue_status() {
	gh_record_call rest transition_owned_issue_status 2>/dev/null || true
	local issue_num="$1"
	local repo_slug="$2"
	local owner_login="$3"
	local source_status="$4"
	local target_status="$5"

	if [[ -z "$issue_num" || -z "$repo_slug" || -z "$owner_login" || -z "$source_status" || -z "$target_status" ]]; then
		printf 'transition_owned_issue_status: all arguments are required\n' >&2
		return 2
	fi
	if [[ "$source_status" == "$target_status" ]]; then
		printf 'transition_owned_issue_status: source and target statuses must differ\n' >&2
		return 2
	fi

	local _candidate=""
	local _status=""
	local _valid=0
	for _candidate in "$source_status" "$target_status"; do
		_valid=0
		for _status in "${ISSUE_STATUS_LABELS[@]}"; do
			if [[ "$_status" == "$_candidate" ]]; then
				_valid=1
				break
			fi
		done
		if [[ "$_valid" -eq 0 ]]; then
			printf 'transition_owned_issue_status: invalid status "%s" (valid: %s)\n' \
				"$_candidate" "${ISSUE_STATUS_LABELS[*]}" >&2
			return 2
		fi
	done

	if ! ensure_status_labels_exist "$repo_slug"; then
		print_warning "gh-wrapper: unable to verify status-label contract for ${repo_slug}"
		return 1
	fi

	local -a _status_flags=()
	local _label=""
	local _status_label=""
	for _label in "${ISSUE_STATUS_LABELS[@]}"; do
		printf -v _status_label 'status:%s' "$_label"
		if [[ "$_label" == "$target_status" ]]; then
			_status_flags+=(--add-label "$_status_label")
		else
			_status_flags+=(--remove-label "$_status_label")
		fi
	done

	AIDEVOPS_GH_ROUTE_DECISION="owned-status-transition-rest-deltas" \
		_rest_issue_edit_preserving_deltas "$issue_num" --repo "$repo_slug" \
		--require-label "status:${source_status}" --require-assignee "$owner_login" \
		--delta-order add-first "${_status_flags[@]}"
	return $?
}

#######################################
# gh_issue_view — drop-in replacement for gh issue view.  (t2689)
# Routes directly to REST (`gh api GET /repos/{owner}/{repo}/issues/{N}`) when
# GraphQL remaining is below the fallback threshold, and still falls back to
# REST if the primary call fails during an exhaustion window. All arguments are
# forwarded unchanged to the selected path.
#
#   gh_issue_view 42 --repo owner/repo --json state --jq '.state'
#   gh_issue_view 42 --repo owner/repo --json title,body,labels,assignees
#
# Returns the exit code of whichever path succeeded (or the REST path's code
# when both paths ran).
#######################################
gh_issue_view() {
	local _first_num="${1:-}"
	local _rest_capable=0
	_rest_issue_view_can_preserve_args "$@" && _rest_capable=1
	if [[ $_rest_capable -eq 1 ]] && _rest_read_first_enabled; then
		print_info "[INFO] gh-wrapper: REST-first read mode, routing issue view #${_first_num} to REST"
		_rest_issue_view "$@"
		return $?
	fi
	if [[ $_rest_capable -eq 1 ]] && { { command -v github_app_should_route_rest >/dev/null 2>&1 && github_app_should_route_rest rest-core gh_issue_view; } || _rest_should_fallback; }; then
		print_info "[INFO] gh-wrapper: GraphQL budget low, routing issue view #${_first_num} to REST"
		_rest_issue_view "$@"
		return $?
	fi
	gh_record_call graphql gh_issue_view 2>/dev/null || true
	_gh_with_timeout read gh issue view "$@"
	local rc=$?
	if [[ $rc -ne 0 && $_rest_capable -eq 1 ]] && _rest_should_fallback; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue view #${_first_num}"
		_rest_issue_view "$@"
		rc=$?
	fi
	return $rc
}

#######################################
# gh_pr_list — drop-in replacement for gh pr list.  (t2772)
# Routes directly to REST (`gh api GET /repos/{owner}/{repo}/pulls`) when
# GraphQL remaining is below the fallback threshold, and still falls back to
# REST if the primary call fails during an exhaustion window. Direct list reads
# use /pulls; search-only filters use pagination-complete Search API qualifiers.
# Unsupported argument or JSON-field shapes remain on native GraphQL.
#
#   gh_pr_list --repo owner/repo --state open --json number,title
#   gh_pr_list --repo owner/repo --state open --limit 200 --json number --jq 'length'
#
# Returns the exit code of whichever path succeeded (or the REST path's code
# when both paths ran).
#######################################
gh_pr_list() {
	local _rest_capable=0
	local _prefer_native_filter=0
	local _uses_search=0
	local _pool="rest-core"
	_rest_pr_list_can_preserve_args "$@" && _rest_capable=1
	_rest_pr_list_prefers_native_filter "$@" && _prefer_native_filter=1
	if _rest_pr_list_requires_search "$@"; then
		_uses_search=1
		_pool="rest-search"
	fi
	_gh_pr_list_shape_record "$@"
	local _cached_output=""
	if _cached_output=$(_gh_pr_list_snapshot_get "$@" 2>/dev/null); then
		printf '%s' "$_cached_output"
		return 0
	fi
	local _out="" _rc=0
	if [[ $_rest_capable -eq 1 && $_prefer_native_filter -eq 0 ]] && _rest_read_first_enabled; then
		if [[ $_uses_search -eq 1 ]]; then
			print_info "[INFO] gh-wrapper: REST-first read mode, routing search-filtered pr list to /search/issues"
		else
			print_info "[INFO] gh-wrapper: REST-first read mode, routing pr list to REST"
		fi
		_out=$(_rest_pr_list_dispatch "$@")
		_rc=$?
		if [[ $_rc -eq 0 ]]; then
			_gh_pr_list_snapshot_put "$_out" "$@"
			printf '%s' "$_out"
		fi
		return $_rc
	fi
	if [[ $_rest_capable -eq 1 ]] && { { [[ $_prefer_native_filter -eq 0 ]] && command -v github_app_should_route_rest >/dev/null 2>&1 && github_app_should_route_rest "$_pool" gh_pr_list; } || _rest_should_fallback; }; then
		if [[ $_uses_search -eq 1 ]]; then
			print_info "[INFO] gh-wrapper: GraphQL budget low, routing search-filtered pr list to /search/issues"
		else
			print_info "[INFO] gh-wrapper: GraphQL budget low, routing pr list to REST"
		fi
		_out=$(_rest_pr_list_dispatch "$@")
		_rc=$?
		if [[ $_rc -eq 0 ]]; then
			_gh_pr_list_snapshot_put "$_out" "$@"
			printf '%s' "$_out"
		fi
		return $_rc
	fi
	gh_record_call graphql gh_pr_list 2>/dev/null || true
	_out=$(_gh_with_timeout read gh pr list "$@")
	local rc=$?
	if [[ $rc -ne 0 && $_rest_capable -eq 1 ]] && _rest_should_fallback; then
		if [[ $_uses_search -eq 1 ]]; then
			print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to /search/issues for search-filtered pr list"
		else
			print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for pr list"
		fi
		_out=$(_rest_pr_list_dispatch "$@")
		rc=$?
	fi
	if [[ $rc -eq 0 ]]; then
		_gh_pr_list_snapshot_put "$_out" "$@"
		printf '%s' "$_out"
	fi
	return $rc
}

#######################################
# gh_pr_view — drop-in replacement for gh pr view.  (t3460)
# Routes directly to REST (`gh api GET /repos/{owner}/{repo}/pulls/{N}`) when
# GraphQL remaining is below the fallback threshold, and still falls back to
# REST if the primary call fails during an exhaustion window. All arguments are
# forwarded unchanged to the selected path; the REST translator supports the
# common --repo, --json, --jq, and -q read shapes.
#
#   gh_pr_view 123 --repo owner/repo --json body --jq '.body // empty'
#   gh_pr_view 123 --repo owner/repo --json labels --jq '[.labels[].name] | join(",")'
#
# Returns the exit code of whichever path succeeded (or the REST path's code
# when both paths ran).
#######################################
gh_pr_view() {
	local _first_num="${1:-}"
	local _rest_shape_valid=0
	_rest_pr_view_args_supported structural "$@" && _rest_shape_valid=1
	local _cached_output=""
	if _cached_output=$(_gh_pr_view_snapshot_get "$@" 2>/dev/null); then
		printf '%s' "$_cached_output"
		return 0
	fi
	local _out="" _rc=0
	if [[ $_rest_shape_valid -eq 1 ]] && _out=$(_gh_pr_view_try_mixed_split "$@" 2>/dev/null); then
		_gh_pr_view_snapshot_put "$_out" "$@"
		printf '%s' "$_out"
		return 0
	fi
	if _rest_read_first_enabled && _rest_pr_view_can_preserve_args "$@"; then
		print_info "[INFO] gh-wrapper: REST-first read mode, routing pr view #${_first_num} to REST"
		_out=$(_rest_pr_view "$@")
		_rc=$?
		if [[ $_rc -eq 0 ]]; then
			_gh_pr_view_snapshot_put "$_out" "$@"
			printf '%s' "$_out"
		fi
		return $_rc
	fi
	if _rest_pr_view_can_preserve_args "$@" && { { command -v github_app_should_route_rest >/dev/null 2>&1 && github_app_should_route_rest rest-core gh_pr_view; } || _rest_should_fallback; }; then
		print_info "[INFO] gh-wrapper: GraphQL budget low, routing pr view #${_first_num} to REST"
		_out=$(_rest_pr_view "$@")
		_rc=$?
		if [[ $_rc -eq 0 ]]; then
			_gh_pr_view_snapshot_put "$_out" "$@"
			printf '%s' "$_out"
		fi
		return $_rc
	fi
	gh_record_call graphql gh_pr_view 2>/dev/null || true
	_out=$(_gh_with_timeout read gh pr view "$@")
	local rc=$?
	if [[ $rc -ne 0 ]] && _rest_pr_view_can_emergency_fallback_args "$@" && _rest_should_fallback; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for pr view #${_first_num}"
		_out=$(_rest_pr_view "$@")
		rc=$?
	fi
	if [[ $rc -eq 0 ]]; then
		_gh_pr_view_snapshot_put "$_out" "$@"
		printf '%s' "$_out"
	fi
	return $rc
}

#######################################
# gh_issue_list — drop-in replacement for gh issue list.  (t2689, t2995)
# Routes directly to REST when GraphQL remaining is below the fallback threshold,
# and still falls back to REST if the primary call fails during an exhaustion
# window.
# Supports --state, --label (multiple), --assignee, --author, --limit, --json,
# --jq, and --search when their complete argument shape can be preserved.
#
# Routing (t2995):
#   - --search non-empty → _rest_issue_search uses /search/issues?q=...
#     (separate quota: 30 req/min). Preserves search semantics so the
#     caller does not silently get a label-only result on fallback.
#   - --search empty → _rest_issue_list uses /repos/{owner}/{repo}/issues.
#
# Pre-t2995 behaviour silently dropped --search in the REST path, causing
# `_large_file_gate_find_existing_debt_issue` to match the wrong issue
# during GraphQL exhaustion windows.
#
#   gh_issue_list --repo owner/repo --state open --label bug --json number,title
#   gh_issue_list --repo owner/repo --state open --limit 500 --json number --jq length
#
# Returns the exit code of whichever path succeeded (or the REST path's code
# when both paths ran).
#######################################
gh_issue_list() {
	local _has_search=1
	_rest_args_have_search "$@" || _has_search=0
	local _rest_capable=0
	_rest_issue_list_can_preserve_args "$@" && _rest_capable=1
	local _pool="rest-core"
	[[ $_has_search -eq 1 ]] && _pool="rest-search"
	if [[ $_rest_capable -eq 1 ]] && _rest_read_first_enabled; then
		if [[ $_has_search -eq 1 ]]; then
			print_info "[INFO] gh-wrapper: REST-first read mode, routing issue list to /search/issues (--search preserved, t2995)"
		else
			print_info "[INFO] gh-wrapper: REST-first read mode, routing issue list to REST"
		fi
		_rest_issue_list_dispatch "$@"
		return $?
	fi
	if [[ $_rest_capable -eq 1 ]] && { { command -v github_app_should_route_rest >/dev/null 2>&1 && github_app_should_route_rest "$_pool" gh_issue_list; } || _rest_should_fallback; }; then
		if [[ $_has_search -eq 1 ]]; then
			print_info "[INFO] gh-wrapper: GraphQL budget low, routing issue list to /search/issues (--search preserved, t2995)"
		else
			print_info "[INFO] gh-wrapper: GraphQL budget low, routing issue list to REST"
		fi
		_rest_issue_list_dispatch "$@"
		return $?
	fi
	gh_record_call graphql gh_issue_list 2>/dev/null || true
	_gh_with_timeout read gh issue list "$@"
	local rc=$?
	if [[ $rc -ne 0 && $_rest_capable -eq 1 ]] && _rest_should_fallback; then
		# t2995: use search-aware REST fallback when --search is supplied.
		if [[ $_has_search -eq 1 ]]; then
			print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to /search/issues for issue list (--search preserved, t2995)"
		else
			print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue list"
		fi
		_rest_issue_list_dispatch "$@"
		rc=$?
	fi
	return $rc
}
