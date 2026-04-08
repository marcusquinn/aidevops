#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-batch-prefetch-helper.sh — Org-level prefetch for pulse (t2030)
#
# Collapses per-repo `gh issue list` / `gh pr list` calls into a single
# `gh search` per owner, dramatically reducing GitHub API consumption
# during pulse prefetch.
#
# The pulse historically ran one `gh issue list --repo $slug` and one
# `gh pr list --repo $slug` per pulse-enabled repo every cycle. With
# 40+ repos that burns ~100 GraphQL calls per cycle before any actual
# work, exhausting the 5000/hr budget.
#
# This helper groups repos by owner, runs ONE `gh search issues
# --owner X` per owner, then splits the response into per-slug cache
# files. Downstream consumers (pulse-wrapper.sh prefetch functions)
# read the cache file if present and fall back to per-repo on miss.
#
# Usage:
#   pulse-batch-prefetch-helper.sh refresh [--repos-json PATH]
#     Read pulse-enabled repos from repos.json, group by owner, run
#     one gh search per owner for issues AND prs, write per-slug cache.
#
#   pulse-batch-prefetch-helper.sh cache-path --kind issues|prs --slug owner/repo
#     Print the cache file path for a given kind+slug. Empty output if
#     not cached. Used by pulse-wrapper.sh to check for a cached result.
#
#   pulse-batch-prefetch-helper.sh clear
#     Remove all cached batch prefetch files.
#
#   pulse-batch-prefetch-helper.sh status
#     Show cache contents (owner counts, ages, file sizes).
#
# Cache format:
#   ~/.aidevops/.agent-workspace/supervisor/batch-prefetch/
#     issues-{owner}--{repo}.json  — array of issue objects (per-slug)
#     prs-{owner}--{repo}.json     — array of pr objects (per-slug)
#     .last-refresh-{owner}        — unix timestamp of last owner refresh
#
# Each cached file mirrors the shape that `gh issue list --repo slug
# --json number,title,labels,updatedAt,assignees` returns, so pulse
# consumers can use the data without transformation.
#
# Environment:
#   PULSE_BATCH_PREFETCH_DIR    Override cache directory
#   PULSE_BATCH_PREFETCH_TTL    Cache freshness in seconds (default: 240)
#   PULSE_BATCH_PREFETCH_LIMIT  Max results per owner search (default: 1000)
#   AIDEVOPS_REPOS_JSON         Override repos.json path

set -uo pipefail

# shellcheck disable=SC2034
SCRIPT_VERSION="1.0.0"

CACHE_DIR="${PULSE_BATCH_PREFETCH_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor/batch-prefetch}"
CACHE_TTL="${PULSE_BATCH_PREFETCH_TTL:-240}"
SEARCH_LIMIT="${PULSE_BATCH_PREFETCH_LIMIT:-1000}"
REPOS_JSON="${AIDEVOPS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"

#######################################
# Log a message to stderr with a helper prefix.
# Globals: none
# Arguments:
#   $* - message text
# Returns:
#   0 always
#######################################
_log() {
	local msg="$*"
	echo "[pulse-batch-prefetch] ${msg}" >&2
	return 0
}

#######################################
# Sanitise a repo slug into a filesystem-safe filename component.
# Example: "Ultimate-Multisite/ultimate-multisite" -> "Ultimate-Multisite--ultimate-multisite"
# Arguments:
#   $1 - repo slug (owner/repo)
# Outputs:
#   Sanitised name on stdout
# Returns:
#   0 on success, 1 if slug is empty
#######################################
_slug_to_filename() {
	local slug="${1:-}"
	if [[ -z "$slug" ]]; then
		return 1
	fi
	# Replace / with -- (double dash distinguishes from single-dash in org names)
	echo "${slug//\//--}"
	return 0
}

#######################################
# Read the list of pulse-enabled repo slugs from repos.json, grouped by owner.
# Emits lines of form "owner\tslug" for each repo where pulse: true and
# local_only is not true.
# Globals:
#   REPOS_JSON
# Outputs:
#   Tab-separated owner\tslug pairs on stdout, one per line
# Returns:
#   0 on success, 1 if repos.json is missing or invalid
#######################################
_list_pulse_repos_by_owner() {
	if [[ ! -f "$REPOS_JSON" ]]; then
		_log "repos.json not found: $REPOS_JSON"
		return 1
	fi

	if ! jq -e . "$REPOS_JSON" >/dev/null 2>&1; then
		_log "repos.json is not valid JSON: $REPOS_JSON"
		return 1
	fi

	jq -r '
		.initialized_repos[]
		| select(.pulse == true)
		| select((.local_only // false) | not)
		| .slug
		| split("/") as $parts
		| select($parts | length == 2)
		| "\($parts[0])\t\(.)"
	' "$REPOS_JSON" 2>/dev/null
	return 0
}

#######################################
# Fetch all open issues for a single owner via `gh search issues --owner X`.
# Writes the raw JSON array to stdout. Logs failures but still exits 0
# with an empty array, so callers can treat missing data as "no open issues".
#
# Arguments:
#   $1 - owner (GitHub org or user)
# Outputs:
#   JSON array on stdout (empty array on any failure)
# Returns:
#   0 always (errors are logged, not propagated)
#######################################
_fetch_owner_issues() {
	local owner="${1:-}"
	if [[ -z "$owner" ]]; then
		echo "[]"
		return 0
	fi

	local err_file result
	err_file=$(mktemp "${TMPDIR:-/tmp}/pulse-batch-issues.XXXXXX.err")
	result=$(gh search issues \
		--owner "$owner" \
		--state open \
		--limit "$SEARCH_LIMIT" \
		--json number,title,labels,updatedAt,assignees,repository \
		2>"$err_file") || result=""

	if [[ -z "$result" || "$result" == "null" ]]; then
		local err_msg
		err_msg=$(head -c 500 "$err_file" 2>/dev/null || echo "unknown")
		_log "gh search issues FAILED for owner=${owner}: ${err_msg}"
		rm -f "$err_file"
		echo "[]"
		return 0
	fi

	rm -f "$err_file"
	echo "$result"
	return 0
}

#######################################
# Fetch all open PRs for a single owner via `gh search prs --owner X`.
# Note: gh search does NOT support reviewDecision or statusCheckRollup —
# the pulse enriches those in a separate per-PR pass. This helper only
# fetches the fields that match `gh pr list` basic output.
#
# Arguments:
#   $1 - owner (GitHub org or user)
# Outputs:
#   JSON array on stdout (empty array on any failure)
# Returns:
#   0 always
#######################################
_fetch_owner_prs() {
	local owner="${1:-}"
	if [[ -z "$owner" ]]; then
		echo "[]"
		return 0
	fi

	local err_file result
	err_file=$(mktemp "${TMPDIR:-/tmp}/pulse-batch-prs.XXXXXX.err")
	result=$(gh search prs \
		--owner "$owner" \
		--state open \
		--limit "$SEARCH_LIMIT" \
		--json number,title,author,createdAt,updatedAt,repository \
		2>"$err_file") || result=""

	if [[ -z "$result" || "$result" == "null" ]]; then
		local err_msg
		err_msg=$(head -c 500 "$err_file" 2>/dev/null || echo "unknown")
		_log "gh search prs FAILED for owner=${owner}: ${err_msg}"
		rm -f "$err_file"
		echo "[]"
		return 0
	fi

	rm -f "$err_file"
	echo "$result"
	return 0
}

#######################################
# Split a combined search result (many repos) into per-slug files under
# $CACHE_DIR. Each output file contains a JSON array of just the entries
# matching that slug, with the top-level `repository` field stripped to
# match the shape of `gh issue list --repo X` / `gh pr list --repo X`.
#
# Arguments:
#   $1 - kind ("issues" or "prs")
#   $2 - list of slugs for this owner (space-separated)
#   $3 - combined JSON result from _fetch_owner_*
# Outputs:
#   One line per slug written to stdout: "slug count"
# Returns:
#   0 on success, 1 on fatal jq error
#######################################
_split_by_slug() {
	local kind="$1"
	local slugs="$2"
	local combined="$3"

	mkdir -p "$CACHE_DIR" 2>/dev/null || {
		_log "Failed to create cache dir: $CACHE_DIR"
		return 1
	}

	local slug filename cache_file per_slug count
	for slug in $slugs; do
		filename=$(_slug_to_filename "$slug") || continue
		cache_file="${CACHE_DIR}/${kind}-${filename}.json"

		per_slug=$(echo "$combined" | jq --arg s "$slug" \
			'[.[] | select(.repository.nameWithOwner == $s) | del(.repository)]' 2>/dev/null) || per_slug="[]"

		if [[ -z "$per_slug" || "$per_slug" == "null" ]]; then
			per_slug="[]"
		fi

		# Atomic write via temp + rename
		local tmp_file
		tmp_file=$(mktemp "${cache_file}.XXXXXX")
		echo "$per_slug" >"$tmp_file"
		mv -f "$tmp_file" "$cache_file"

		count=$(echo "$per_slug" | jq 'length' 2>/dev/null) || count=0
		echo "${slug} ${count}"
	done
	return 0
}

#######################################
# Refresh the batch prefetch cache for all pulse-enabled repos.
# Groups repos by owner, fetches issues + prs once per owner, splits
# results into per-slug cache files. Writes a per-owner timestamp marker
# so consumers can check freshness.
#
# Arguments: none (reads repos.json)
# Outputs:
#   Summary lines on stdout (one per slug per kind)
# Returns:
#   0 on success, 1 if repos.json is missing/invalid
#######################################
cmd_refresh() {
	local pairs
	pairs=$(_list_pulse_repos_by_owner) || return 1

	if [[ -z "$pairs" ]]; then
		_log "No pulse-enabled repos found in $REPOS_JSON"
		return 0
	fi

	mkdir -p "$CACHE_DIR" 2>/dev/null || {
		_log "Failed to create cache dir: $CACHE_DIR"
		return 1
	}

	# Group slugs by owner using a temp file (bash 3.2 — no associative arrays)
	local tmp_groups
	tmp_groups=$(mktemp "${TMPDIR:-/tmp}/pulse-batch-groups.XXXXXX")
	echo "$pairs" | sort -u >"$tmp_groups"

	local owners
	owners=$(awk -F'\t' '{print $1}' "$tmp_groups" | sort -u)

	local owner owner_slugs issues_json prs_json ts
	local total_issues=0 total_prs=0 owner_count=0

	for owner in $owners; do
		owner_count=$((owner_count + 1))
		owner_slugs=$(awk -F'\t' -v o="$owner" '$1 == o {print $2}' "$tmp_groups" | tr '\n' ' ')

		_log "Refreshing owner=${owner} slugs=$(echo "$owner_slugs" | wc -w | tr -d ' ')"

		issues_json=$(_fetch_owner_issues "$owner")
		prs_json=$(_fetch_owner_prs "$owner")

		local issue_summary pr_summary
		issue_summary=$(_split_by_slug issues "$owner_slugs" "$issues_json") || issue_summary=""
		pr_summary=$(_split_by_slug prs "$owner_slugs" "$prs_json") || pr_summary=""

		if [[ -n "$issue_summary" ]]; then
			local issue_owner_count
			issue_owner_count=$(echo "$issue_summary" | awk '{sum+=$2} END {print sum+0}')
			total_issues=$((total_issues + issue_owner_count))
			echo "$issue_summary" | while read -r line; do
				echo "issues ${line}"
			done
		fi
		if [[ -n "$pr_summary" ]]; then
			local pr_owner_count
			pr_owner_count=$(echo "$pr_summary" | awk '{sum+=$2} END {print sum+0}')
			total_prs=$((total_prs + pr_owner_count))
			echo "$pr_summary" | while read -r line; do
				echo "prs ${line}"
			done
		fi

		# Write freshness marker
		ts=$(date +%s)
		echo "$ts" >"${CACHE_DIR}/.last-refresh-${owner}"
	done

	rm -f "$tmp_groups"
	_log "Refresh complete: owners=${owner_count} total_issues=${total_issues} total_prs=${total_prs}"
	return 0
}

#######################################
# Print the cache file path for a given kind+slug if it exists and is
# fresh (within CACHE_TTL seconds). Empty output means cache miss or
# stale — callers should fall back to per-repo fetch.
#
# Arguments:
#   $1 - --kind
#   $2 - issues|prs
#   $3 - --slug
#   $4 - owner/repo
# Outputs:
#   Absolute path to cache file (if fresh), empty otherwise
# Returns:
#   0 if cache hit + fresh, 1 if miss or stale
#######################################
cmd_cache_path() {
	local kind="" slug=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--kind)
			kind="$2"
			shift 2
			;;
		--slug)
			slug="$2"
			shift 2
			;;
		*)
			_log "cache-path: unknown arg: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$kind" || -z "$slug" ]]; then
		_log "cache-path: --kind and --slug required"
		return 1
	fi

	if [[ "$kind" != "issues" && "$kind" != "prs" ]]; then
		_log "cache-path: --kind must be 'issues' or 'prs'"
		return 1
	fi

	local filename cache_file owner
	filename=$(_slug_to_filename "$slug") || return 1
	cache_file="${CACHE_DIR}/${kind}-${filename}.json"

	if [[ ! -f "$cache_file" ]]; then
		return 1
	fi

	# Check freshness via owner marker
	owner="${slug%%/*}"
	local marker="${CACHE_DIR}/.last-refresh-${owner}"
	if [[ ! -f "$marker" ]]; then
		return 1
	fi

	local last_refresh now age
	last_refresh=$(cat "$marker" 2>/dev/null || echo 0)
	now=$(date +%s)
	age=$((now - last_refresh))

	if [[ "$age" -gt "$CACHE_TTL" ]]; then
		return 1
	fi

	echo "$cache_file"
	return 0
}

#######################################
# Remove all cached batch prefetch files.
# Arguments: none
# Returns: 0 always
#######################################
cmd_clear() {
	if [[ -d "$CACHE_DIR" ]]; then
		rm -f "${CACHE_DIR}"/issues-*.json "${CACHE_DIR}"/prs-*.json "${CACHE_DIR}"/.last-refresh-*
		_log "Cache cleared: $CACHE_DIR"
	fi
	return 0
}

#######################################
# Print a human-readable status summary of the cache.
# Arguments: none
# Outputs:
#   Markdown-formatted summary on stdout
# Returns: 0 always
#######################################
cmd_status() {
	echo "# pulse-batch-prefetch status"
	echo "- cache_dir: ${CACHE_DIR}"
	echo "- ttl: ${CACHE_TTL}s"
	echo "- search_limit: ${SEARCH_LIMIT}"
	echo ""

	if [[ ! -d "$CACHE_DIR" ]]; then
		echo "Cache directory does not exist."
		return 0
	fi

	local now
	now=$(date +%s)

	echo "## Owner refresh markers"
	local marker owner last_refresh age
	for marker in "${CACHE_DIR}"/.last-refresh-*; do
		[[ -f "$marker" ]] || continue
		owner="${marker##*/.last-refresh-}"
		last_refresh=$(cat "$marker" 2>/dev/null || echo 0)
		age=$((now - last_refresh))
		echo "- ${owner}: age=${age}s"
	done
	echo ""

	echo "## Cached files"
	local f count kind rest
	for f in "${CACHE_DIR}"/issues-*.json "${CACHE_DIR}"/prs-*.json; do
		[[ -f "$f" ]] || continue
		count=$(jq 'length' "$f" 2>/dev/null || echo "?")
		rest="${f##*/}"
		kind="${rest%%-*}"
		echo "- ${rest} (kind=${kind} count=${count})"
	done

	return 0
}

#######################################
# Entry point.
# Arguments:
#   $1 - subcommand (refresh|cache-path|clear|status|help)
# Returns:
#   Subcommand exit code
#######################################
main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	refresh)
		cmd_refresh "$@"
		;;
	cache-path)
		cmd_cache_path "$@"
		;;
	clear)
		cmd_clear "$@"
		;;
	status)
		cmd_status "$@"
		;;
	help | --help | -h)
		sed -n '4,60p' "$0"
		;;
	*)
		_log "Unknown command: $cmd"
		sed -n '4,60p' "$0" >&2
		return 1
		;;
	esac
	return $?
}

main "$@"
