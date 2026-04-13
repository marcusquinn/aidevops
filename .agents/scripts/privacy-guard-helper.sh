#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# privacy-guard-helper.sh — Shared library for the git pre-push privacy guard.
#
# Enumerates private repo slugs from ~/.config/aidevops/repos.json and scans
# a git diff range for TODO.md / todo/** content that would leak a private
# slug into a public target.
#
# This file is sourced by:
#   - .agents/hooks/privacy-guard-pre-push.sh (the actual git pre-push hook)
#   - .agents/scripts/test-privacy-guard.sh   (the test harness)
#
# It is NOT intended to be executed directly — it is a library. Functions
# exit the caller via `return`, never `exit`, to preserve the hook's control
# flow.
#
# Functions exported:
#   privacy_is_target_public <remote_url>        exit 0 public, 1 private, 2 unknown
#   privacy_enumerate_private_slugs [out_file]   writes one slug per line
#   privacy_scan_diff <base_sha> <head_sha>      writes "file:line: slug" to stdout
#   privacy_scan_paths                           list of path globs scanned
#   privacy_log <level> <msg>                    tagged stderr log
#
# Cache: ~/.aidevops/cache/repo-privacy.json (TTL 10m)
# Repos: ~/.config/aidevops/repos.json

set -u
# Do NOT set -e here — callers may source this file and we don't want our
# early returns to abort their scripts unexpectedly.

# =============================================================================
# Configuration
# =============================================================================

PRIVACY_REPOS_CONFIG="${PRIVACY_REPOS_CONFIG:-$HOME/.config/aidevops/repos.json}"
PRIVACY_CACHE_FILE="${PRIVACY_CACHE_FILE:-$HOME/.aidevops/cache/repo-privacy.json}"
PRIVACY_CACHE_TTL="${PRIVACY_CACHE_TTL:-600}" # 10 minutes
# Paths whose diffs we scan. Shell globs, matched against every changed file
# in the diff range. Keep tight — this is the set of "planning-only" paths
# that bypass the worktree-PR flow and go direct to main.
PRIVACY_SCAN_GLOBS=(
	"TODO.md"
	"todo/"
	".github/ISSUE_TEMPLATE/"
	"README.md"
)

# =============================================================================
# Logging
# =============================================================================

#######################################
# Emit a tagged log line to stderr.
# Arguments:
#   $1 - level (INFO/WARN/ERROR/BLOCK)
#   $@ - message
#######################################
privacy_log() {
	local level="$1"
	shift
	printf '[privacy-guard][%s] %s\n' "$level" "$*" >&2
	return 0
}

# =============================================================================
# Target-privacy lookup
# =============================================================================

#######################################
# Given a git remote URL, parse owner/repo and ask gh whether it is public.
# Caches positive + negative results to ~/.aidevops/cache/repo-privacy.json
# with a 10-minute TTL to keep hook latency under 500ms on warm cache.
# Arguments:
#   $1 - remote URL (https://github.com/owner/repo.git or git@github.com:owner/repo.git)
# Returns:
#   0 if public, 1 if private, 2 if unknown (fail-open: hook allows push).
#######################################
privacy_is_target_public() {
	local url="$1"
	local slug=""

	# Extract owner/repo from either SSH or HTTPS form, strip optional .git
	if [[ "$url" =~ github\.com[:/]([^/]+/[^/]+) ]]; then
		slug="${BASH_REMATCH[1]%.git}"
	else
		privacy_log WARN "Non-GitHub remote ($url) — fail-open, allowing push"
		return 2
	fi

	# Cache hit?
	# NOTE: use `.private | tostring` — NOT `.private // ""`. The `//` operator
	# treats `false` as null-ish and would collapse every public cache entry
	# to an empty string (t1969 regression: cached public → cache miss →
	# unnecessary gh probe). `tostring` returns "true", "false", or "null".
	mkdir -p "$(dirname "$PRIVACY_CACHE_FILE")" 2>/dev/null || true
	if [[ -f "$PRIVACY_CACHE_FILE" ]]; then
		local cached_ts cached_private now
		cached_ts=$(jq -r --arg slug "$slug" '.[$slug].checked_at // ""' "$PRIVACY_CACHE_FILE" 2>/dev/null)
		cached_private=$(jq -r --arg slug "$slug" '.[$slug].private | tostring' "$PRIVACY_CACHE_FILE" 2>/dev/null)
		now=$(date +%s)
		if [[ -n "$cached_ts" && "$cached_private" != "null" ]]; then
			local age=$((now - cached_ts))
			if [[ "$age" -lt "$PRIVACY_CACHE_TTL" ]]; then
				if [[ "$cached_private" == "false" ]]; then
					return 0
				else
					return 1
				fi
			fi
		fi
	fi

	# Cold probe via gh
	if ! command -v gh >/dev/null 2>&1; then
		privacy_log WARN "gh CLI not installed — fail-open, allowing push to $slug"
		return 2
	fi
	if ! gh auth status >/dev/null 2>&1; then
		privacy_log WARN "gh not authenticated — fail-open, allowing push to $slug"
		return 2
	fi

	# Use `.private | tostring` — NOT `.private // "unknown"`. The `//` operator
	# treats `false` as null-ish, so `.private // "unknown"` returns "unknown"
	# for every public repo. `tostring` returns "true", "false", or "null".
	local is_private
	is_private=$(gh api "repos/${slug}" --jq '.private | tostring' 2>/dev/null) || {
		privacy_log WARN "gh api repos/${slug} failed — fail-open"
		return 2
	}

	case "$is_private" in
	true)
		_privacy_cache_write "$slug" "true"
		return 1
		;;
	false)
		_privacy_cache_write "$slug" "false"
		return 0
		;;
	*)
		privacy_log WARN "gh returned unexpected privacy value ($is_private) for $slug — fail-open"
		return 2
		;;
	esac
}

#######################################
# Write a slug -> {private, checked_at} entry to the privacy cache.
# Arguments:
#   $1 - slug
#   $2 - privacy string (true|false)
#######################################
_privacy_cache_write() {
	local slug="$1"
	local private="$2"
	local now
	now=$(date +%s)

	mkdir -p "$(dirname "$PRIVACY_CACHE_FILE")" 2>/dev/null || true
	if [[ ! -f "$PRIVACY_CACHE_FILE" ]]; then
		printf '{}\n' >"$PRIVACY_CACHE_FILE"
	fi

	local tmp
	tmp=$(mktemp "${PRIVACY_CACHE_FILE}.XXXXXX")
	jq --arg slug "$slug" --arg private "$private" --argjson now "$now" \
		'.[$slug] = {private: ($private == "true"), checked_at: $now}' \
		"$PRIVACY_CACHE_FILE" >"$tmp" 2>/dev/null && mv "$tmp" "$PRIVACY_CACHE_FILE" || rm -f "$tmp"
	return 0
}

# =============================================================================
# Private-slug enumeration
# =============================================================================

#######################################
# Enumerate private repo slugs from repos.json. A slug is considered private
# if ANY of these conditions hold:
#   - mirror_upstream is set (mirrors are private by design)
#   - local_only: true (no remote, definitionally not public)
#   - the slug's owner is the current gh user AND the repo is private on GH
#
# For speed, we use structural markers only (mirror_upstream, local_only).
# We do NOT probe every slug with gh api — that would cost N network calls
# on every push. Users who want additional slugs covered can add them to
# ~/.aidevops/configs/privacy-guard-extra-slugs.txt (one per line).
#
# Arguments:
#   $1 - (optional) output file path. If omitted, writes to stdout.
#######################################
privacy_enumerate_private_slugs() {
	local out_file="${1:-}"

	if [[ ! -f "$PRIVACY_REPOS_CONFIG" ]]; then
		privacy_log WARN "repos.json not found at $PRIVACY_REPOS_CONFIG"
		return 1
	fi

	local slugs
	slugs=$(jq -r '
		.initialized_repos[]?
		| select(
			(.mirror_upstream // null) != null and (.mirror_upstream // "") != ""
			or (.local_only // false) == true
		)
		| .slug // empty
	' "$PRIVACY_REPOS_CONFIG" 2>/dev/null)

	# Also include extra user-configured slugs
	local extra_file="$HOME/.aidevops/configs/privacy-guard-extra-slugs.txt"
	if [[ -f "$extra_file" ]]; then
		local extras
		extras=$(grep -vE '^\s*(#|$)' "$extra_file" 2>/dev/null || true)
		if [[ -n "$extras" ]]; then
			slugs=$(printf '%s\n%s\n' "$slugs" "$extras")
		fi
	fi

	# De-dupe while preserving order via awk
	slugs=$(printf '%s\n' "$slugs" | awk 'NF && !seen[$0]++')

	if [[ -n "$out_file" ]]; then
		printf '%s\n' "$slugs" >"$out_file"
	else
		printf '%s\n' "$slugs"
	fi
	return 0
}

# =============================================================================
# Diff scanning
# =============================================================================

#######################################
# Build a `git diff` path filter from PRIVACY_SCAN_GLOBS suitable for
# `git diff -- <pathspecs>`. Outputs pathspec args one per line.
#######################################
_privacy_pathspec_args() {
	local glob
	for glob in "${PRIVACY_SCAN_GLOBS[@]}"; do
		# Glob ending with / → match everything under that directory
		if [[ "$glob" == */ ]]; then
			printf '%s**\n' "$glob"
		else
			printf '%s\n' "$glob"
		fi
	done
	return 0
}

#######################################
# Scan the diff between two SHAs for added lines matching any private slug.
# Only lines added (prefix '+') in paths matching PRIVACY_SCAN_GLOBS are
# considered — we don't flag pre-existing content that has already been
# pushed. Output format: "file:NNN: slug" for each hit.
# Arguments:
#   $1 - base SHA (remote tip); may be 40 zeros for a new branch push
#   $2 - head SHA (local tip)
#   $3 - file containing newline-separated private slugs
# Writes: "file:line: slug" lines to stdout for each hit
# Returns: 0 if no hits, 1 if at least one hit
#######################################
privacy_scan_diff() {
	local base_sha="$1"
	local head_sha="$2"
	local slugs_file="$3"

	if [[ ! -s "$slugs_file" ]]; then
		# No private slugs to match → nothing to block
		return 0
	fi

	# Build path filter args for git diff
	local -a pathspecs=()
	while IFS= read -r p; do
		pathspecs+=("$p")
	done < <(_privacy_pathspec_args)

	# If base is all zeros, this is a new branch push — diff against the merge
	# base with the default branch instead (or fall back to empty tree).
	local diff_base="$base_sha"
	if [[ "$base_sha" =~ ^0+$ ]]; then
		local default_branch
		default_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||') || default_branch=""
		if [[ -z "$default_branch" ]]; then
			default_branch="main"
		fi
		diff_base=$(git merge-base "$head_sha" "origin/${default_branch}" 2>/dev/null) || diff_base=""
		if [[ -z "$diff_base" ]]; then
			# Fall back to the git empty tree
			diff_base=$(git hash-object -t tree /dev/null)
		fi
	fi

	# Produce a unified diff of ADDED lines in the path filter
	local diff_output
	diff_output=$(git diff --unified=0 --no-color "$diff_base" "$head_sha" -- "${pathspecs[@]}" 2>/dev/null) || return 0

	if [[ -z "$diff_output" ]]; then
		return 0
	fi

	# Walk the diff, tracking current file and hunk line counter. Match added
	# lines (those starting with "+" but not "+++") against private slugs using
	# grep -F -f for O(lines) matching instead of O(lines × slugs).
	local hits=0
	local current_file=""
	local line_num=0
	while IFS= read -r line; do
		case "$line" in
		"+++ b/"*)
			current_file="${line#+++ b/}"
			line_num=0
			;;
		"--- "*) ;;
		"@@ "*)
			# @@ -old,oldc +new,newc @@ — extract new start
			local rest="${line#@@ -*+}"
			local new_start="${rest%% *}"
			new_start="${new_start%,*}"
			line_num="$new_start"
			;;
		"+"*)
			# Skip the "+++ b/..." which we already handled
			[[ "$line" == "+++ "* ]] && continue
			local added="${line:1}"
			local matching_slugs slug
			# grep -F -f matches all slugs at once (fixed strings, no regex).
			# -o outputs only the matched text, one match per line.
			# grep exits 1 on no match; || true prevents aborting if the caller
			# has set -e.
			matching_slugs=$(printf '%s\n' "$added" | grep -F -o -f "$slugs_file" 2>/dev/null || true)
			if [[ -n "$matching_slugs" ]]; then
				while IFS= read -r slug; do
					[[ -z "$slug" ]] && continue
					printf '%s:%s: %s\n' "$current_file" "$line_num" "$slug"
					hits=$((hits + 1))
				done <<<"$matching_slugs"
			fi
			line_num=$((line_num + 1))
			;;
		" "*)
			line_num=$((line_num + 1))
			;;
		esac
	done <<<"$diff_output"

	if [[ "$hits" -gt 0 ]]; then
		return 1
	fi
	return 0
}
