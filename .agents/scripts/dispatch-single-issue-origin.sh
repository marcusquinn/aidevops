#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#33629: repository-identity prerequisite for worker Git authentication.
# Source through dispatch-single-issue-helper.sh; it owns dependencies and state.
#
# The worker Git auth gate binds scoped credentials to the exact dispatch slug
# and refuses any other origin. That refusal stays. This library classifies the
# refusal before any claim so dry-run and real dispatch agree, separates a
# verified same-ID transfer/rename (repository_identity_drift) from an unknown
# origin (repository_origin_mismatch), and offers one explicit, compare-and-swap
# repair for the verified case only. Unknown identity always fails closed.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_DSI_ORIGIN_LOADED:-}" ]] && return 0
_DSI_ORIGIN_LOADED=1

#######################################
# Lower-case a string portably (Bash 3.2 has no ${var,,}).
#######################################
_dsi_lower() {
	local value="$1"
	printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
	return 0
}

#######################################
# Split a GitHub origin URL into transport prefix, slug, and suffix.
# Accepts https://github.com/O/R, git@github.com:O/R, ssh://git@github.com/O/R,
# each with an optional .git suffix. Anything else is not classifiable.
# Args: $1 - origin URL
# Outputs: "<prefix>\t<owner/repo>\t<suffix>"
# Returns: 0 when parsed, 1 otherwise
#######################################
_dsi_github_origin_parts() {
	local origin="$1"
	local suffix=""
	if [[ "$origin" == *.git ]]; then
		suffix=".git"
		origin="${origin%.git}"
	fi
	[[ "$origin" =~ ^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$ ]] || return 1
	printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$suffix"
	return 0
}

#######################################
# Prove two slugs name the same immutable GitHub repository. GitHub serves a
# transferred or renamed repository's former name as a redirect to the current
# repository, so both lookups must return the same numeric ID and the dispatch
# slug must be the name GitHub reports now. Read-only; any API failure, ID
# mismatch, or reused former name fails closed.
# Args: $1 - origin slug, $2 - dispatch slug
# Returns: 0 when verified, 1 otherwise
#######################################
_dsi_verify_same_repository() {
	local origin_slug="$1"
	local repo_slug="$2"
	local origin_meta="" target_meta=""
	local origin_id="" origin_name="" target_id="" target_name="" wanted=""
	origin_meta=$(gh api "repos/${origin_slug}" --jq '[(.id | tostring), .full_name] | @tsv' 2>/dev/null) || return 1
	target_meta=$(gh api "repos/${repo_slug}" --jq '[(.id | tostring), .full_name] | @tsv' 2>/dev/null) || return 1
	IFS=$'\t' read -r origin_id origin_name <<<"$origin_meta"
	IFS=$'\t' read -r target_id target_name <<<"$target_meta"
	[[ "$origin_id" =~ ^[0-9]+$ && "$origin_id" == "$target_id" ]] || return 1
	wanted=$(_dsi_lower "$repo_slug")
	[[ "$(_dsi_lower "$target_name")" == "$wanted" && "$(_dsi_lower "$origin_name")" == "$wanted" ]] || return 1
	return 0
}

#######################################
# Classify an origin that _dsi_prepare_worker_git_auth would reject. Mirrors
# that gate's applicability and comparison exactly, so a clean result here
# means the real gate accepts the same configuration. Never mutates anything.
# Args: $1 - repo path (canonical or worktree; origin config is shared)
#       $2 - dispatch slug
# Outputs: repository_identity_drift | repository_origin_mismatch (when unmet)
# Returns: 0 when the gate accepts or does not apply, 1 when unmet
#######################################
_dsi_origin_identity_prerequisite() {
	local repo_path="$1"
	local repo_slug="$2"
	local origin="" normalized=""
	[[ "${WORKER_SCOPED_TOKENS:-true}" == "true" ]] || return 0
	[[ -x "${_DSI_TOKEN_HELPER:-}" && -x "${_DSI_ASKPASS_HELPER:-}" ]] || return 0
	origin=$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)
	normalized=$(_dsi_normalize_github_https_origin "$origin") || return 0
	[[ "$normalized" != "https://github.com/${repo_slug}" ]] || return 0
	if _dsi_verify_same_repository "${normalized#https://github.com/}" "$repo_slug"; then
		printf 'repository_identity_drift\n'
	else
		printf 'repository_origin_mismatch\n'
	fi
	return 1
}

#######################################
# All runner-local prerequisites checked before the first claim: the registered
# canonical path (GH#34003), then origin identity (GH#33629).
# Args: $1 - resolved repo path (may be empty), $2 - dispatch slug
# Outputs: unmet reason
# Returns: 0 when met, 1 otherwise
#######################################
_dsi_runner_local_prerequisite() {
	local repo_path="$1"
	local repo_slug="$2"
	_dsi_repo_path_prerequisite "$repo_path" || return 1
	_dsi_origin_identity_prerequisite "$repo_path" "$repo_slug" || return 1
	return 0
}

#######################################
# Print the operator action for an origin identity prerequisite. Diagnostics
# name only the dispatch slug; the former origin stays out of shared output.
# Args: $1 - reason, $2 - dispatch slug
#######################################
_dsi_origin_identity_hint() {
	local reason="$1"
	local repo_slug="$2"
	case "$reason" in
	repository_identity_drift)
		printf 'Origin still names the pre-transfer repository (same GitHub ID); review then run: dispatch-single-issue-helper.sh repair-origin %s --apply\n' "$repo_slug"
		;;
	repository_origin_mismatch)
		printf 'Origin is not verifiably the same GitHub repository as %s; correct the remote or repos.json manually (dispatch never rewrites unverified remotes)\n' "$repo_slug"
		;;
	esac
	return 0
}

#######################################
# Anchored ERE for git remote set-url's <oldurl>. Callers pass only URLs
# accepted by _dsi_github_origin_parts, whose sole ERE metacharacter is '.'.
#######################################
_dsi_origin_regex() {
	local url="$1"
	printf '^%s$' "$(printf '%s' "$url" | sed 's/[.]/\\./g')"
	return 0
}

#######################################
# Subcommand: repair-origin <owner/repo> [--apply]
# Realign a registered repository's origin to its dispatch slug after a
# verified same-ID transfer/rename. Preserves transport and .git suffix, only
# touches remote.origin.url, and swaps atomically against the URL it verified.
# Never changes refs, checkouts, files, other remotes, or unverified origins.
#######################################
cmd_repair_origin() {
	local repo_slug="${1:-}"
	local apply="${2:-}"
	local repo_path="" origin="" parts="" prefix="" origin_slug="" suffix="" new_url=""
	if [[ ! "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ || ( -n "$apply" && "$apply" != "--apply" ) ]]; then
		_dsi_err "Usage: dispatch-single-issue-helper.sh repair-origin <owner/repo> [--apply]"
		return 2
	fi
	repo_path=$(_dsi_repo_path_for_slug "$repo_slug" 2>/dev/null || true)
	if ! _dsi_repo_path_prerequisite "$repo_path" >/dev/null; then
		_dsi_err "repair-origin requires a dispatchable repos.json entry with an existing checkout for ${repo_slug}"
		return 1
	fi
	origin=$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)
	parts=$(_dsi_github_origin_parts "$origin") || {
		_dsi_err "Origin is not a recognised GitHub URL; refusing to rewrite it"
		return 1
	}
	IFS=$'\t' read -r prefix origin_slug suffix <<<"$parts"
	if [[ "$origin_slug" == "$repo_slug" ]]; then
		_dsi_ok "Origin already matches ${repo_slug}; nothing to repair"
		return 0
	fi
	if git -C "$repo_path" config --get-all remote.origin.pushurl >/dev/null 2>&1; then
		_dsi_err "Origin has a separate pushurl; refusing an automatic rewrite (repair manually)"
		return 1
	fi
	if ! _dsi_verify_same_repository "$origin_slug" "$repo_slug"; then
		_dsi_err "Origin is not verifiably the same GitHub repository (ID/redirect) as ${repo_slug}; refusing"
		return 1
	fi
	new_url="${prefix}${repo_slug}${suffix}"
	if [[ "$apply" != "--apply" ]]; then
		_dsi_info "Verified same-ID transfer; would set remote.origin.url to ${new_url} (re-run with --apply)"
		return 0
	fi
	# Compare-and-swap: git only rewrites the entry still matching the verified URL.
	if ! git -C "$repo_path" remote set-url origin "$new_url" "$(_dsi_origin_regex "$origin")" >/dev/null 2>&1; then
		_dsi_err "Origin changed or config is locked; nothing rewritten — re-run repair-origin"
		return 1
	fi
	[[ "$(git -C "$repo_path" remote get-url origin 2>/dev/null)" == "$new_url" ]] || {
		_dsi_err "Origin rewrite could not be verified"
		return 1
	}
	_dsi_ok "Origin realigned to ${new_url}; linked worktrees share this setting"
	return 0
}
