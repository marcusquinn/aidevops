#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Canonical Recovery State -- local ref guards and GitHub remote resolution
# =============================================================================
# Local ref verification/rollback helpers, GitHub remote URL parsing,
# registered-slug lookup and canonical remote resolution.
#
# Usage: source "${SCRIPT_DIR}/canonical-recovery-state.sh"
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_CANONICAL_RECOVERY_STATE_LIB_LOADED:-}" ]] && return 0
_CANONICAL_RECOVERY_STATE_LIB_LOADED=1

local_ref_is_absent() {
	local repo="$1"
	local ref="$2"
	local status=0
	"$REAL_GIT" -C "$repo" show-ref --verify --quiet "$ref" || status=$?
	[[ "$status" -eq 1 ]] || return 1
	return 0
}

verify_initial_local_state() {
	local repo="$1"
	local ref="$2"
	local state="$3"
	local expected_sha="$4"
	local current_sha=""
	local head_ref=""
	if [[ "$state" == "$LOCAL_STATE_UNBORN" ]]; then
		if ! head_ref=$("$REAL_GIT" -C "$repo" symbolic-ref --quiet HEAD 2>&1); then
			head_ref=""
		fi
		local_ref_is_absent "$repo" "$ref" || return 1
		[[ "$head_ref" == "$ref" ]] || return 1
		return 0
	fi
	if ! current_sha=$("$REAL_GIT" -C "$repo" rev-parse --verify "${ref}^{commit}" 2>&1); then
		current_sha=""
	fi
	[[ -n "$current_sha" && "$current_sha" == "$expected_sha" ]] || return 1
	return 0
}

verify_post_cas_state() {
	local repo="$1"
	local local_ref="$2"
	local branch="$3"
	local remote_ref="$4"
	local target_sha="$5"
	local current_branch=""
	local current_local_sha=""
	local current_remote_sha=""
	if ! current_branch=$("$REAL_GIT" -C "$repo" symbolic-ref --quiet --short HEAD 2>&1); then
		current_branch=""
	fi
	if ! current_local_sha=$("$REAL_GIT" -C "$repo" rev-parse --verify "${local_ref}^{commit}" 2>&1); then
		current_local_sha=""
	fi
	if ! current_remote_sha=$("$REAL_GIT" -C "$repo" rev-parse --verify "${remote_ref}^{commit}" 2>&1); then
		current_remote_sha=""
	fi
	[[ "$current_branch" == "$branch" && "$current_local_sha" == "$target_sha" &&
		"$current_remote_sha" == "$target_sha" ]] || return 1
	return 0
}

rollback_local_ref() {
	local repo="$1"
	local ref="$2"
	local state="$3"
	local initial_sha="$4"
	local target_sha="$5"
	local message="$6"
	if [[ "$state" == "$LOCAL_STATE_UNBORN" ]]; then
		"$REAL_GIT" -C "$repo" update-ref -m "$message" -d "$ref" "$target_sha" || return 1
		return 0
	fi
	"$REAL_GIT" -C "$repo" update-ref -m "$message" "$ref" "$initial_sha" "$target_sha" || return 1
	return 0
}

restore_unborn_worktree() {
	local repo="$1"
	local target_sha="$2"
	local empty_tree="$3"
	"$REAL_GIT" -C "$repo" read-tree --dry-run -u -m "$target_sha" "$empty_tree" || return 1
	"$REAL_GIT" -C "$repo" read-tree -u -m "$target_sha" "$empty_tree" || return 1
	return 0
}

github_slug_from_remote_url() {
	local url="$1"
	local slug=""
	local remainder=""
	local authority=""
	local port=""
	case "$url" in
	git@github.com:*) slug="${url#git@github.com:}" ;;
	ssh://* | https://* | http://* | git://*)
		remainder="${url#*://}"
		[[ "$remainder" == */* ]] || return 1
		authority="${remainder%%/*}"
		slug="${remainder#*/}"
		case "$url" in
		ssh://*)
			case "$authority" in
			git@github.com) ;;
			git@github.com:*) port="${authority#git@github.com:}" ;;
			*) return 1 ;;
			esac
			;;
		*)
			case "$authority" in
			github.com) ;;
			github.com:*) port="${authority#github.com:}" ;;
			*) return 1 ;;
			esac
			;;
		esac
		[[ -z "$port" || "$port" =~ ^[0-9]+$ ]] || return 1
		;;
	*) return 1 ;;
	esac
	slug="${slug%%\?*}"
	slug="${slug%%#*}"
	slug="${slug%/}"
	slug="${slug%.git}"
	[[ -n "$slug" && "$slug" == */* && "${slug#*/}" != */* ]] || return 1
	printf '%s\n' "$slug"
	return 0
}

is_github_remote_url() {
	local url="$1"
	case "$url" in
	git@github.com:* | ssh://git@github.com/* | ssh://git@github.com:*/* | \
		https://github.com/* | https://github.com:*/* | http://github.com/* | \
		http://github.com:*/* | git://github.com/* | git://github.com:*/*)
		return 0
		;;
	*) return 1 ;;
	esac
}

origin_is_local_mirror() {
	local repo="$1"
	local fetch_urls=""
	local push_urls=""
	local url=""
	local fetch_count=0
	local push_count=0
	fetch_urls=$("$REAL_GIT" -C "$repo" config --get-all remote.origin.url 2>/dev/null || true)
	push_urls=$("$REAL_GIT" -C "$repo" config --get-all remote.origin.pushurl 2>/dev/null || true)
	[[ -n "$push_urls" ]] || push_urls="$fetch_urls"
	while IFS= read -r url; do
		[[ -n "$url" ]] || continue
		fetch_count=$((fetch_count + 1))
		case "$url" in
		file://* | /* | ./* | ../*) ;;
		*) return 1 ;;
		esac
	done <<<"$fetch_urls"
	while IFS= read -r url; do
		[[ -n "$url" ]] || continue
		push_count=$((push_count + 1))
		case "$url" in
		file://* | /* | ./* | ../*) ;;
		*) return 1 ;;
		esac
	done <<<"$push_urls"
	[[ "$fetch_count" -gt 0 && "$push_count" -gt 0 ]] || return 1
	return 0
}

registered_repo_slug() {
	local repo="$1"
	local config_path="${AIDEVOPS_REPOS_CONFIG:-${HOME}/.config/aidevops/repos.json}"
	local rows=""
	local entry_path=""
	local entry_slug=""
	local entry_real=""
	local matched_slug=""
	[[ -f "$config_path" ]] || {
		printf '\n'
		return 0
	}
	rows=$(jq -r '.initialized_repos[]? | [(.path // .repo_path // ""), (.slug // "")] | @tsv' \
		"$config_path" 2>/dev/null) || return 1
	while IFS=$'\t' read -r entry_path entry_slug; do
		[[ -n "$entry_path" ]] || continue
		case "$entry_path" in
		~/*) entry_path="${HOME}/${entry_path#~/}" ;;
		esac
		entry_real=$(cd "$entry_path" 2>/dev/null && pwd -P) || continue
		[[ "$entry_real" == "$repo" ]] || continue
		[[ -n "$entry_slug" ]] || continue
		[[ "$entry_slug" == */* && "${entry_slug#*/}" != */* ]] || return 1
		if [[ -n "$matched_slug" && "$matched_slug" != "$entry_slug" ]]; then
			return 1
		fi
		matched_slug="$entry_slug"
	done <<<"$rows"
	printf '%s\n' "$matched_slug"
	return 0
}

GIT_CONFIG_CAPTURE_VALUES=""
GIT_CONFIG_CAPTURE_STATUS=0
GIT_CONFIG_CAPTURE_HAD_OUTPUT=false

# Capture one complete git-config enumeration without hiding its exit status.
# The suffix keeps command substitution from stripping record-separating newlines.
capture_git_config_values() {
	local repo="$1"
	local key="$2"
	local marker="__AIDEVOPS_GIT_CONFIG_CAPTURE_END_8F3D1A__"
	local suffix=$'\n'"$marker"
	local captured=""
	local capture_status=0
	captured=$(
		set +e
		"$REAL_GIT" -C "$repo" config --get-all "$key" 2>/dev/null
		command_status=$?
		printf '%s' "$marker"
		exit "$command_status"
	) || capture_status=$?
	GIT_CONFIG_CAPTURE_VALUES=""
	GIT_CONFIG_CAPTURE_STATUS="$capture_status"
	GIT_CONFIG_CAPTURE_HAD_OUTPUT=false
	case "$captured" in
	"$marker") ;;
	*"$suffix")
		GIT_CONFIG_CAPTURE_VALUES="${captured%"$suffix"}"
		GIT_CONFIG_CAPTURE_HAD_OUTPUT=true
		;;
	*) return 1 ;;
	esac
	return 0
}

GITHUB_REMOTE_URL_COUNT=0
GITHUB_REMOTE_URLS_MATCH=0
GITHUB_REMOTE_URL_SEEN=0

validate_github_remote_url_set() {
	local urls="$1"
	local expected_lower="$2"
	local remote_url=""
	local remote_slug=""
	local remote_lower=""
	GITHUB_REMOTE_URL_COUNT=0
	GITHUB_REMOTE_URLS_MATCH=1
	GITHUB_REMOTE_URL_SEEN=0
	while IFS= read -r remote_url; do
		GITHUB_REMOTE_URL_COUNT=$((GITHUB_REMOTE_URL_COUNT + 1))
		if [[ -z "$remote_url" ]]; then
			GITHUB_REMOTE_URLS_MATCH=0
			continue
		fi
		if is_github_remote_url "$remote_url"; then
			GITHUB_REMOTE_URL_SEEN=1
		fi
		remote_slug=$(github_slug_from_remote_url "$remote_url" 2>/dev/null || true)
		if [[ -z "$remote_slug" ]]; then
			GITHUB_REMOTE_URLS_MATCH=0
			continue
		fi
		GITHUB_REMOTE_URL_SEEN=1
		remote_lower=$(printf '%s' "$remote_slug" | tr '[:upper:]' '[:lower:]') || return 1
		[[ -n "$expected_lower" && "$remote_lower" == "$expected_lower" ]] || GITHUB_REMOTE_URLS_MATCH=0
	done <<<"$urls"
	return 0
}

# Resolve the remote that represents the registered GitHub repository. Exact
# fetch+push identity is required. Callers may allow the origin fallback for
# local mirrors where no configured remote can be parsed as GitHub at all. The
# pinned framework updater may also accept equivalent aliases after every URL
# independently resolves to its immutable expected repository identity.
resolve_github_remote() {
	local repo="$1"
	local expected_slug="$2"
	local allow_local_mirror="${3:-true}"
	local allow_equivalent_aliases="${4:-false}"
	local expected_lower=""
	local remote_names=""
	local remote=""
	local fetch_key=""
	local push_key=""
	local fetch_urls=""
	local push_urls=""
	local fetch_status=0
	local push_status=0
	local push_had_output=false
	local remote_matches=0
	local fetch_count=0
	local push_count=0
	local candidate=""
	local candidate_count=0
	local github_seen=0
	expected_lower=$(printf '%s' "$expected_slug" | tr '[:upper:]' '[:lower:]') || return 1
	remote_names=$(LC_ALL=C "$REAL_GIT" -C "$repo" remote 2>/dev/null | LC_ALL=C sort) || return 1
	while IFS= read -r remote; do
		[[ -n "$remote" ]] || continue
		fetch_key="remote.${remote}.url"
		push_key="remote.${remote}.pushurl"
		capture_git_config_values "$repo" "$fetch_key" || return 1
		fetch_status="$GIT_CONFIG_CAPTURE_STATUS"
		fetch_urls="$GIT_CONFIG_CAPTURE_VALUES"
		[[ "$fetch_status" -eq 0 ]] || return 1
		capture_git_config_values "$repo" "$push_key" || return 1
		push_status="$GIT_CONFIG_CAPTURE_STATUS"
		push_urls="$GIT_CONFIG_CAPTURE_VALUES"
		push_had_output="$GIT_CONFIG_CAPTURE_HAD_OUTPUT"
		case "$push_status" in
		0) ;;
		1)
			[[ "$push_had_output" == "false" ]] || return 1
			push_urls="$fetch_urls"
			;;
		*) return 1 ;;
		esac
		validate_github_remote_url_set "$fetch_urls" "$expected_lower" || return 1
		fetch_count="$GITHUB_REMOTE_URL_COUNT"
		remote_matches="$GITHUB_REMOTE_URLS_MATCH"
		[[ "$GITHUB_REMOTE_URL_SEEN" -eq 0 ]] || github_seen=1
		validate_github_remote_url_set "$push_urls" "$expected_lower" || return 1
		push_count="$GITHUB_REMOTE_URL_COUNT"
		[[ "$GITHUB_REMOTE_URLS_MATCH" -eq 1 ]] || remote_matches=0
		[[ "$GITHUB_REMOTE_URL_SEEN" -eq 0 ]] || github_seen=1
		[[ "$remote_matches" -eq 1 && "$fetch_count" -gt 0 && "$push_count" -gt 0 ]] || continue
		if [[ -z "$candidate" || "$remote" == "origin" ]]; then
			candidate="$remote"
		fi
		candidate_count=$((candidate_count + 1))
	done <<<"$remote_names"
	#aidevops:trust-boundary
	# Multiple names are accepted only after every candidate's complete fetch and
	# push URL sets independently matched the caller's immutable expected slug.
	if [[ "$candidate_count" -eq 1 ||
		("$allow_equivalent_aliases" == "$BOOLEAN_TRUE" && "$candidate_count" -gt 1) ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi
	if [[ "$allow_local_mirror" == "$BOOLEAN_TRUE" && "$candidate_count" -eq 0 && "$github_seen" -eq 0 ]] &&
		origin_is_local_mirror "$repo"; then
		printf 'origin\n'
		return 0
	fi
	return 1
}
