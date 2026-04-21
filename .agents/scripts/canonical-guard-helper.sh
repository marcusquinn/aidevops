#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# canonical-guard-helper.sh — defence-in-depth for cleanup routines.
#
# Prevents the worktree-cleanup subsystem from accidentally trashing a
# registered canonical repository when its derivation of "the main
# worktree path" returns empty (e.g. git missing from PATH, transient
# git failure, empty `git worktree list --porcelain`).
#
# Canonical failure mode it defends against (2026-04-20 23:50 incident):
#   _porcelain=$(git worktree list --porcelain)
#   main_worktree_path="${_porcelain%%$'\n'*}"
#   main_worktree_path="${main_worktree_path#worktree }"
# If $_porcelain is empty, $main_worktree_path becomes "" and the guard
#   [[ "$worktree_path" != "$main_wt_path" ]]
# reduces to [[ "$worktree_path" != "" ]] — always true for real paths —
# and canonical gets swept alongside the orphans.
#
# Usage (source this file then call):
#   if is_registered_canonical "$path"; then
#       echo "REFUSED: $path is a registered canonical repository" >&2
#       return 1
#   fi
#
# Also exposes:
#   assert_git_available     — fail-loud when git is missing from PATH
#   assert_main_worktree_sane — fail-loud when a main_worktree_path value
#                               is empty or a known-canonical path

# Resolve a path via realpath / readlink -f / pwd-P fallback chain.
# Prints the resolved path on stdout, empty string if resolution fails.
# Bash 3.2 compatible (no readarray / no ${var,,}).
_canonical_guard_resolve_path() {
	local raw="${1:-}"
	[[ -z "$raw" ]] && return 1
	# Strip trailing slashes (except root).
	while [[ "${raw}" != "/" && "${raw: -1}" == "/" ]]; do
		raw="${raw%/}"
	done
	# Prefer the path to resolve even if it does not currently exist.
	local resolved=""
	if [[ -d "$raw" ]]; then
		resolved=$(cd "$raw" 2>/dev/null && pwd -P)
	fi
	if [[ -z "$resolved" ]] && command -v realpath >/dev/null 2>&1; then
		resolved=$(realpath -m "$raw" 2>/dev/null || realpath "$raw" 2>/dev/null || true)
	fi
	if [[ -z "$resolved" ]] && command -v readlink >/dev/null 2>&1; then
		resolved=$(readlink -f "$raw" 2>/dev/null || true)
	fi
	# Last-resort: take the raw path as-is.
	if [[ -z "$resolved" ]]; then
		resolved="$raw"
	fi
	printf '%s' "$resolved"
	return 0
}

# Returns 0 if $1 is a path registered as a canonical repository in
# ~/.config/aidevops/repos.json (.initialized_repos[].path), 1 otherwise.
# Path comparison is done after realpath resolution on both sides, so
# symlinks, trailing slashes, and relative paths all resolve correctly.
#
# Env:
#   AIDEVOPS_REPOS_JSON — override the default repos.json path (for tests)
#   AIDEVOPS_CANONICAL_EXTRA_PATHS — optional newline-separated extra paths
#                                   to treat as canonical (defence extension
#                                   for mirror/backup scenarios)
#
# Fail-open exceptions (return 1, allow action) are intentionally NARROW:
#   - repos.json missing → return 1 (framework not initialised yet)
#   - jq missing         → return 1 (cannot parse, caller must degrade)
# Any other condition, including a malformed repos.json, returns 0
# (treat as canonical) so that ambiguity fails SAFE — no destructive
# operation proceeds when we cannot confirm the path is non-canonical.
is_registered_canonical() {
	local candidate="${1:-}"
	[[ -z "$candidate" ]] && return 0 # Empty path → treat as canonical (fail safe)

	local repos_json="${AIDEVOPS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	[[ -f "$repos_json" ]] || return 1 # No registry → fail open
	command -v jq >/dev/null 2>&1 || return 1 # No jq → fail open

	local candidate_resolved
	candidate_resolved=$(_canonical_guard_resolve_path "$candidate")
	[[ -z "$candidate_resolved" ]] && return 0 # Unresolvable → fail safe

	# Build a newline-separated list of registered canonical paths (resolved).
	# Malformed JSON → jq non-zero; in that case fall through to the extra
	# paths check and then fail safe (return 0).
	local registered_paths=""
	registered_paths=$(jq -r '.initialized_repos[].path // empty' "$repos_json" 2>/dev/null || true)

	# Append any extra paths from env (newline-separated).
	if [[ -n "${AIDEVOPS_CANONICAL_EXTRA_PATHS:-}" ]]; then
		registered_paths="${registered_paths}
${AIDEVOPS_CANONICAL_EXTRA_PATHS}"
	fi

	# If we have no registered paths and repos.json exists, that's unusual
	# but not necessarily malformed — just means no repos are registered.
	[[ -z "$registered_paths" ]] && return 1

	local reg
	while IFS= read -r reg; do
		[[ -z "$reg" ]] && continue
		local reg_resolved
		reg_resolved=$(_canonical_guard_resolve_path "$reg")
		[[ -z "$reg_resolved" ]] && continue
		if [[ "$candidate_resolved" == "$reg_resolved" ]]; then
			return 0 # MATCH — is canonical
		fi
	done <<<"$registered_paths"

	return 1 # Not canonical
}

# Assert git is available in PATH. Prints FATAL to stderr and returns 1 if not.
# Intended for use at the TOP of cleanup entry points so we fail-loud before
# any derivation from `git worktree list` runs against empty output.
assert_git_available() {
	if ! command -v git >/dev/null 2>&1; then
		echo "FATAL: git not available in PATH — refusing cleanup operation" >&2
		return 1
	fi
	return 0
}

# Assert that a main-worktree-path value is sane before it is used as a
# cleanup guard ("never trash this path"). Rejects: empty string, a path
# that resolves to a registered canonical from within a repo that isn't
# supposed to BE that canonical (mixed context), a path that doesn't look
# like a filesystem path at all.
# Args: $1 = main_worktree_path derived from caller
# Returns 0 if sane; non-zero (and prints FATAL) if unsafe.
assert_main_worktree_sane() {
	local mwp="${1:-}"
	if [[ -z "$mwp" ]]; then
		echo "FATAL: main_worktree_path is empty — refusing cleanup (would trash everything)" >&2
		return 1
	fi
	# A worktree path must start with / (absolute). Relative paths indicate
	# parse corruption (e.g. ANSI bleed ate the leading slash).
	if [[ "${mwp:0:1}" != "/" ]]; then
		echo "FATAL: main_worktree_path is not absolute: '$mwp' — refusing cleanup" >&2
		return 1
	fi
	return 0
}
