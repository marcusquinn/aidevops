#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Commit Gates -- privacy and stacked-branch validation
# =============================================================================
# Sourced by full-loop-helper-commit.sh. Function bodies are kept verbatim;
# caller-scoped inputs and the orchestrator's helper directory remain unchanged.
# Dependencies: full-loop-helper-commit.sh and its shared logging/guard helpers.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_FULL_LOOP_COMMIT_GATES_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_COMMIT_GATES_LIB_LOADED=1

# Check the committed public diff before running expensive validators. The
# pre-push hook remains authoritative for the actual ref being pushed.
_commit_and_pr_privacy_scan() {
	local remote_url="" base_branch="" entities_file="" hits="" scan_rc=0
	local target_repo="" fetch_url="" public_head=""
	remote_url=$(git remote get-url --push origin 2>/dev/null) || return 1
	# shellcheck source=./privacy-guard-helper.sh
	# shellcheck disable=SC1091
	source "${_FULL_LOOP_COMMIT_DIR}/privacy-guard-helper.sh"
	if ! privacy_is_target_public "$remote_url"; then
		return 0
	fi
	base_branch=$(_resolve_pr_base_branch origin) || return 1
	entities_file=$(mktemp) || return 1
	if ! privacy_enumerate_private_entities "$entities_file"; then
		rm -f "$entities_file"
		privacy_log ERROR "could not enumerate private entity inventory — failing closed"
		return 1
	fi
	# GH#39261: pass the same public head and target slug as the authoritative
	# pre-push hook (privacy-guard-pre-push.sh). Without them this preview was
	# stricter than the hook and blocked content the target already publishes.
	# A tracking ref is a public head only when the fetch remote is the target.
	if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/]+) ]]; then
		target_repo="${BASH_REMATCH[1]%.git}"
	fi
	fetch_url=$(git remote get-url origin 2>/dev/null) || fetch_url=""
	if [[ -n "$target_repo" && "$fetch_url" =~ github\.com[:/]([^/]+/[^/]+) ]] && [[ "${BASH_REMATCH[1]%.git}" == "$target_repo" ]]; then
		public_head=$(git rev-parse --verify --quiet "refs/remotes/origin/${base_branch}^{commit}" 2>/dev/null) || public_head=""
	fi
	print_info "[privacy-guard] Scanning public diff before validators..."
	hits=$(privacy_scan_public_diff "refs/remotes/origin/${base_branch}" HEAD "$entities_file" "$public_head" "$target_repo") || scan_rc=$?
	rm -f "$entities_file"
	if [[ "$scan_rc" -eq 1 && -n "$hits" ]]; then
		printf '\n[privacy-guard][BLOCK] Push to origin contains private references in public-repo content:\n\n%s\n\n' "$hits" >&2
		printf '  Remove the private material from the committed content and amend/rewrite the commit before pushing.\n\n' >&2
		return 1
	fi
	if [[ "$scan_rc" -ne 0 ]]; then
		privacy_log ERROR "private-entity scan failed (rc=${scan_rc}) — failing closed; no verified findings"
		return 1
	fi
	return 0
}

# GH#39770: scan one PR text input with the public-write guard, naming the flag
# (never the matched material) on a block. $1=flag name, $2=text, $3=repo slug.
_commit_and_pr_scan_text_input() {
	local flag="$1" text="$2" repo="$3" err="" labels=""
	[[ -n "$text" ]] || return 0
	if err=$(privacy_guard_public_write "$repo" "$text" 2>&1 >/dev/null); then
		return 0
	fi
	# Keep only bracketed category labels such as [local-path]; drop any matched text.
	labels=$(printf '%s' "$err" | rg -o '\[(local-path|secret[^]]*|[a-z-]+)\]' | rg -v '^\[privacy-guard\]$|^\[BLOCK\]$' | sort -u | paste -sd, - 2>/dev/null) || labels=""
	if [[ "$err" == *"contains private material"* ]]; then
		printf '[privacy-guard][BLOCK] %s contains private material%s\n' "$flag" "${labels:+: ${labels}}" >&2
	else
		printf '[privacy-guard][BLOCK] %s could not be verified by the privacy guard\n' "$flag" >&2
	fi
	printf '  Remove the private material from %s and rerun; nothing was validated or pushed.\n' "$flag" >&2
	return 1
}

# GH#39770: scan PR text inputs before validators, rebase or push so a private
# value fails in seconds instead of after the full validator run. The later gh
# write wrapper scan stays in place as defense in depth.
_commit_and_pr_scan_text_inputs() {
	local remote_url="" repo=""
	[[ -n "${pr_title:-}${summary_what:-}${summary_testing:-}${summary_decisions:-}${summary_regression:-}" ]] || return 0
	remote_url=$(git remote get-url --push origin 2>/dev/null) || return 0
	if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/]+) ]]; then
		repo="${BASH_REMATCH[1]%.git}"
	else
		return 0
	fi
	# shellcheck source=./privacy-guard-helper.sh
	# shellcheck disable=SC1091
	source "${_FULL_LOOP_COMMIT_DIR}/privacy-guard-helper.sh"
	_commit_and_pr_scan_text_input "--title" "${pr_title:-}" "$repo" || return 1
	_commit_and_pr_scan_text_input "--summary" "${summary_what:-}" "$repo" || return 1
	_commit_and_pr_scan_text_input "--testing" "${summary_testing:-}" "$repo" || return 1
	_commit_and_pr_scan_text_input "--decisions" "${summary_decisions:-}" "$repo" || return 1
	_commit_and_pr_scan_text_input "--regression-evidence" "${summary_regression:-}" "$repo" || return 1
	return 0
}

# Fetch origin/<branch> so rebase and diff checks can use it.
_fetch_origin_branch() {
	local branch="$1"
	git fetch origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" --quiet 2>/dev/null &&
		git rev-parse --verify --quiet "refs/remotes/origin/${branch}" >/dev/null && return 0
	return 1
}

# Resolve the repository PR base (pr_base_branch config, then the remote
# default) via shared-pr-base.sh. Sets FULL_LOOP_PR_BASE{,_SOURCE}; empty when
# the shared resolver is unavailable, so origin/HEAD stays the fallback.
# Args: $1=repo slug
_resolve_repo_pr_base() {
	local repo_slug="$1"
	FULL_LOOP_PR_BASE=""
	FULL_LOOP_PR_BASE_SOURCE=""
	declare -F aidevops_pr_base_resolve >/dev/null 2>&1 || return 0
	local resolved="" top=""
	top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""
	resolved=$(aidevops_pr_base_resolve "$repo_slug" "$top") || return 0
	local branch="${resolved%% *}"
	if ! _fetch_origin_branch "$branch"; then
		print_error "PR base '${branch}' (source: ${resolved#* }) does not exist on origin; fix pr_base_branch or the remote default"
		return 1
	fi
	FULL_LOOP_PR_BASE="$branch"
	FULL_LOOP_PR_BASE_SOURCE="${resolved#* }"
	return 0
}

# Resolve the PR base and validate a --base override: it must differ from the
# current branch, exist on origin, and be either the repository PR base or the
# head of an open PR (a real stacked parent). Workers fail closed; interactive
# sessions may target another branch with a warning (explicit human intent).
# Sets FULL_LOOP_STACK_BASE for a stacked parent, empty otherwise.
# Args: $1=base branch (may be empty) $2=current branch $3=repo slug
_validate_stack_base() {
	local stack_base="$1"
	local current_branch="$2"
	local repo_slug="${3:-}"
	FULL_LOOP_STACK_BASE=""
	_resolve_repo_pr_base "$repo_slug" || return 1
	if [[ -z "$stack_base" || "$stack_base" == "${FULL_LOOP_PR_BASE:-}" ]]; then
		[[ -n "$FULL_LOOP_PR_BASE" ]] && print_info "PR base: ${FULL_LOOP_PR_BASE} (source: ${FULL_LOOP_PR_BASE_SOURCE})"
		return 0
	fi
	if [[ "$stack_base" == "$current_branch" ]]; then
		print_error "--base must name a branch other than the current branch (${current_branch})"
		return 1
	fi
	if ! git check-ref-format --branch "$stack_base" >/dev/null 2>&1; then
		print_error "--base '${stack_base}' is not a valid branch name"
		return 1
	fi
	if ! _fetch_origin_branch "$stack_base"; then
		print_error "--base branch '${stack_base}' does not exist on origin; push the parent branch first"
		return 1
	fi
	local parent_rc=0 headless=0
	[[ "${HEADLESS:-false}" == "true" || "${FULL_LOOP_HEADLESS:-}" == "true" ]] && headless=1
	if declare -F aidevops_pr_base_is_stacked_parent >/dev/null 2>&1 && [[ -n "$repo_slug" ]]; then
		aidevops_pr_base_is_stacked_parent "$repo_slug" "$stack_base" || parent_rc=$?
	fi
	if [[ "$parent_rc" -ne 0 ]]; then
		local why="is not the head of an open PR in ${repo_slug} (not a stacked parent)"
		[[ "$parent_rc" -eq 2 ]] && why="could not be verified as an open parent PR head (lookup failed)"
		if [[ "$headless" -eq 1 ]]; then
			print_error "--base '${stack_base}' ${why} and is not the PR base '${FULL_LOOP_PR_BASE:-unknown}'; refusing worker PR (GH#39167)"
			return 1
		fi
		print_warning "--base '${stack_base}' ${why}; PR base is '${FULL_LOOP_PR_BASE:-unknown}'. Proceeding on explicit interactive intent."
	fi
	FULL_LOOP_STACK_BASE="$stack_base"
	print_info "Stacked PR: base is origin/${stack_base} (--base; PR base ${FULL_LOOP_PR_BASE:-unresolved})"
	return 0
}
