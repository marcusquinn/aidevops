#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Skill Update Batch Library — Batch PR Pipeline and cmd_pr Orchestrator
# =============================================================================
# Batch PR pipeline and cmd_pr dispatcher extracted from skill-update-helper.sh.
#
# Covers:
#   - _collect_skills_needing_update: scan all skills for updates
#   - _reimport_skills_in_worktree: re-import skills into a shared worktree
#   - _update_url_skill_hashes: persist updated hashes for URL skills
#   - _commit_batch_changes: build batch commit message and commit
#   - _create_batch_pr: push branch and create single batch PR
#   - _batch_reimport_and_verify: orchestrate re-import + verify changes exist
#   - cmd_pr_batch: end-to-end batch (single-pr) PR pipeline
#   - _pr_check_url_skill / _pr_check_github_skill: per-skill PR dispatch helpers
#   - cmd_pr: top-level PR command dispatcher (routes to batch or per-skill)
#
# Usage: source "${SCRIPT_DIR}/skill-update-batch-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - skill-update-core-lib.sh (parse_github_url, fetch_url_conditional,
#     update_cache_headers, update_last_checked, get_latest_commit,
#     is_url_skill, check_skill_sources, require_jq, log_* functions)
#   - skill-update-pr-lib.sh (get_repo_root, get_default_branch,
#     _create_worktree_for_branch, cmd_pr_single, _cleanup_worktree,
#     update_upstream_hash)
#   - Global vars from skill-update-helper.sh orchestrator (SKILL_SOURCES,
#     ADD_SKILL_HELPER, NON_INTERACTIVE, QUIET, DRY_RUN, BATCH_MODE)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SKILL_UPDATE_BATCH_LIB_LOADED:-}" ]] && return 0
_SKILL_UPDATE_BATCH_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (may already be set by orchestrator)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Batch PR Pipeline — collect all updated skills into a single PR (t1082.3)
# =============================================================================

# Scan skill-sources.json and collect skills that need updates into parallel arrays.
# Populates the caller's skills_to_update, skill_urls, skill_current_commits,
# skill_latest_commits arrays (caller must declare them before calling).
# Arguments:
#   $1 - target skill name filter (empty = all skills)
# Returns: 0 always (individual failures are logged and skipped)
_collect_skills_needing_update() {
	local target_skill="${1:-}"

	while IFS= read -r skill_json; do
		local name upstream_url current_commit
		name=$(echo "$skill_json" | jq -r '.name')
		upstream_url=$(echo "$skill_json" | jq -r '.upstream_url')
		current_commit=$(echo "$skill_json" | jq -r '.upstream_commit // empty')

		if [[ -n "$target_skill" && "$name" != "$target_skill" ]]; then
			continue
		fi

		if is_url_skill "$skill_json"; then
			local stored_hash stored_etag stored_last_modified latest_hash
			stored_hash=$(echo "$skill_json" | jq -r '.upstream_hash // empty')
			stored_etag=$(echo "$skill_json" | jq -r '.upstream_etag // empty')
			stored_last_modified=$(echo "$skill_json" | jq -r '.upstream_last_modified // empty')

			if ! latest_hash=$(fetch_url_conditional "$upstream_url" "$stored_etag" "$stored_last_modified"); then
				log_warning "Could not fetch URL for $name: $upstream_url — skipping"
				continue
			fi
			update_cache_headers "$name" "$FETCH_RESP_ETAG" "$FETCH_RESP_LAST_MODIFIED"
			update_last_checked "$name"

			if [[ "$latest_hash" == "not_modified" ]]; then
				[[ "$QUIET" != true ]] && echo -e "${GREEN}Up to date${NC}: $name (304 Not Modified)"
				continue
			fi
			if [[ -n "$stored_hash" && "$latest_hash" == "$stored_hash" ]]; then
				[[ "$QUIET" != true ]] && echo -e "${GREEN}Up to date${NC}: $name"
				continue
			fi

			log_info "Update available: $name (hash ${stored_hash:0:12} → ${latest_hash:0:12})"
			skills_to_update+=("$name")
			skill_urls+=("$upstream_url")
			skill_current_commits+=("$stored_hash")
			skill_latest_commits+=("$latest_hash")
			continue
		fi

		if [[ "$upstream_url" != *"github.com"* ]]; then
			[[ "$QUIET" != true ]] && log_info "Skipping $name (non-GitHub source: ${upstream_url})"
			continue
		fi

		local owner_repo latest_commit
		owner_repo=$(parse_github_url "$upstream_url")
		owner_repo=$(echo "$owner_repo" | cut -d'/' -f1-2)

		if [[ -z "$owner_repo" || "$owner_repo" == "/" ]]; then
			log_warning "Could not parse URL for $name: $upstream_url — skipping"
			continue
		fi
		if ! latest_commit=$(get_latest_commit "$owner_repo"); then
			log_warning "Could not fetch latest commit for $name ($owner_repo) — skipping"
			continue
		fi
		update_last_checked "$name"

		if [[ -n "$current_commit" && "$latest_commit" == "$current_commit" ]]; then
			[[ "$QUIET" != true ]] && echo -e "${GREEN}Up to date${NC}: $name"
			continue
		fi

		log_info "Update available: $name (${current_commit:0:7} → ${latest_commit:0:7})"
		skills_to_update+=("$name")
		skill_urls+=("$upstream_url")
		skill_current_commits+=("$current_commit")
		skill_latest_commits+=("$latest_commit")

	done < <(jq -c '.skills[]' "$SKILL_SOURCES")
	return 0
}

# Re-import each skill in a worktree, populating imported_skills and failed_skills arrays.
# Arguments:
#   $1 - worktree path
# Reads: skills_to_update, skill_urls (parallel arrays from caller)
# Populates: imported_skills, failed_skills (caller must declare them)
# Returns: 0 always
_reimport_skills_in_worktree() {
	local worktree_path="$1"

	for i in "${!skills_to_update[@]}"; do
		local skill_name="${skills_to_update[$i]}"
		local upstream_url="${skill_urls[$i]}"

		log_info "Re-importing $skill_name in batch worktree..."
		local add_skill_in_wt="${worktree_path}/.agents/scripts/add-skill-helper.sh"
		if [[ ! -x "$add_skill_in_wt" ]]; then
			add_skill_in_wt="$ADD_SKILL_HELPER"
		fi

		if (cd "$worktree_path" && "$add_skill_in_wt" add "$upstream_url" --force --skip-security 2>&1); then
			log_success "Re-imported $skill_name"
			imported_skills+=("$skill_name")
		else
			log_error "Failed to re-import $skill_name — skipping"
			failed_skills+=("$skill_name")
		fi
	done
	return 0
}

# Update upstream_hash for URL-sourced skills that were successfully re-imported.
# Arguments:
#   $1 - newline-separated list of successfully imported skill names
# Reads: skills_to_update, skill_latest_commits (parallel arrays from caller)
# Returns: 0 always
_update_url_skill_hashes() {
	local imported_skills_list="$1"

	for i in "${!skills_to_update[@]}"; do
		local sname="${skills_to_update[$i]}"
		local sformat
		sformat=$(jq -r --arg name "$sname" '.skills[] | select(.name == $name) | .format_detected // empty' "$SKILL_SOURCES")
		if [[ "$sformat" != "url" ]]; then
			continue
		fi
		if echo "$imported_skills_list" | grep -qxF "$sname"; then
			update_upstream_hash "$sname" "${skill_latest_commits[$i]}"
			log_info "Updated upstream_hash for URL skill: $sname"
		fi
	done
	return 0
}

# Build the batch commit message and commit staged changes.
# Arguments:
#   $1 - worktree path
#   $2 - branch name (for cleanup on failure)
#   $3 - timestamp (YYYYMMDD)
#   $4 - newline-separated list of successfully imported skill names
# Reads: skills_to_update, skill_current_commits, skill_latest_commits, imported_skills
# Returns: 0 on success, 1 on failure
_commit_batch_changes() {
	local worktree_path="$1"
	local branch_name="$2"
	local timestamp="$3"
	local imported_skills_list="$4"

	git -C "$worktree_path" add -A

	local commit_msg="chore: batch update ${#imported_skills[@]} skill(s) from upstream (t1082.3)"$'\n'$'\n'
	for i in "${!skills_to_update[@]}"; do
		local sname="${skills_to_update[$i]}"
		if echo "$imported_skills_list" | grep -qxF "$sname"; then
			commit_msg+="- ${sname}: ${skill_current_commits[$i]:0:12} → ${skill_latest_commits[$i]:0:12}"$'\n'
		fi
	done
	commit_msg+="Updated: ${timestamp}"

	local commit_output
	commit_output=$(git -C "$worktree_path" commit -m "$commit_msg" --no-verify 2>&1) || {
		log_error "Failed to commit batch changes: ${commit_output}"
		_cleanup_worktree "$worktree_path" "$branch_name"
		return 1
	}
	log_success "Committed batch skill updates"
	return 0
}

# Build the batch PR body and create the PR via gh CLI.
# Arguments:
#   $1 - worktree path
#   $2 - branch name
#   $3 - default branch
#   $4 - newline-separated list of successfully imported skill names
# Reads: skills_to_update, skill_current_commits, skill_latest_commits, skill_urls,
#        imported_skills, failed_skills
# Returns: 0 on success, 1 on failure
_create_batch_pr() {
	local worktree_path="$1"
	local branch_name="$2"
	local default_branch="$3"
	local imported_skills_list="$4"

	local push_output
	push_output=$(git -C "$worktree_path" push -u origin "$branch_name" 2>&1) || {
		log_error "Failed to push batch branch: ${push_output}"
		return 1
	}
	log_success "Pushed batch branch: $branch_name"

	if ! command -v gh &>/dev/null; then
		log_warning "gh CLI not available — branch pushed but PR not created"
		log_info "Create PR manually: gh pr create --head $branch_name" # aidevops-allow: raw-gh-wrapper
		return 0
	fi
	if ! gh auth status &>/dev/null; then
		log_warning "gh auth unavailable — branch pushed but batch PR not created"
		log_info "Authenticate with: gh auth login"
		log_info "Create PR manually: gh pr create --head $branch_name" # aidevops-allow: raw-gh-wrapper
		return 1
	fi

	local skill_table="| Skill | Previous | Latest | Source |"$'\n'
	skill_table+="|-------|----------|--------|--------|"$'\n'
	for i in "${!skills_to_update[@]}"; do
		local sname="${skills_to_update[$i]}"
		if echo "$imported_skills_list" | grep -qxF "$sname"; then
			skill_table+="| \`${sname}\` | \`${skill_current_commits[$i]:0:12}\` | \`${skill_latest_commits[$i]:0:12}\` | ${skill_urls[$i]} |"$'\n'
		fi
	done

	local failed_note=""
	if [[ "${#failed_skills[@]}" -gt 0 ]]; then
		failed_note=$'\n'"**Note**: The following skills failed to re-import and are NOT included in this PR: ${failed_skills[*]}"$'\n'
	fi

	local pr_title="chore: batch update ${#imported_skills[@]} skill(s) from upstream"
	local pr_body
	pr_body="## Batch Skill Update

Automated batch update of ${#imported_skills[@]} skill(s) from upstream sources.

${skill_table}
${failed_note}
### Review checklist

- [ ] Verify each updated skill content is correct
- [ ] Check for breaking changes in skill formats
- [ ] Confirm security scan passes (re-run if needed)

---
*Generated by \`skill-update-helper.sh pr --batch-mode single-pr\`*"

	# Append signature footer
	local batch_sig=""
	batch_sig=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$pr_body" 2>/dev/null || true)
	pr_body="${pr_body}${batch_sig}"

	local repo_name_with_owner
	repo_name_with_owner=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
	# Origin label injected by gh_create_pr wrapper (t1756)
	local pr_create_args=("--head" "$branch_name" "--base" "$default_branch" "--title" "$pr_title" "--body" "$pr_body")
	if [[ -n "$repo_name_with_owner" ]]; then
		pr_create_args+=("--repo" "$repo_name_with_owner")
	fi
	local pr_create_output
	pr_create_output=$(gh_create_pr "${pr_create_args[@]}" 2>&1) || {
		log_error "Failed to create batch PR: ${pr_create_output}"
		log_info "Branch is pushed — create PR manually: gh pr create --head $branch_name" # aidevops-allow: raw-gh-wrapper
		return 1
	}
	log_success "Batch PR created: $pr_create_output"

	echo ""
	echo "Batch PR Summary:"
	echo "  Skills updated: ${#imported_skills[@]}"
	if [[ "${#failed_skills[@]}" -gt 0 ]]; then
		echo "  Skills failed:  ${#failed_skills[@]} (${failed_skills[*]})"
	fi
	echo "  PR: $pr_create_output"
	return 0
}

# Re-import skills into a worktree, update URL hashes, and verify changes exist.
# Arguments:
#   $1 - worktree path
#   $2 - branch name (for cleanup on no-change exit)
# Reads/populates: imported_skills, failed_skills (caller must declare them)
# Reads: skills_to_update, skill_urls, skill_latest_commits
# Returns: 0 if changes exist and ready to commit, 1 on failure or no changes
_batch_reimport_and_verify() {
	local worktree_path="$1"
	local branch_name="$2"

	_reimport_skills_in_worktree "$worktree_path"

	# Build newline-separated list for grep-based membership checks (bash 3.2 compatible)
	local imported_skills_list=""
	for imp in "${imported_skills[@]}"; do
		imported_skills_list="${imported_skills_list:+$imported_skills_list
}$imp"
	done

	_update_url_skill_hashes "$imported_skills_list"

	if [[ "${#imported_skills[@]}" -eq 0 ]]; then
		log_error "No skills were successfully imported — aborting batch PR"
		_cleanup_worktree "$worktree_path" "$branch_name"
		return 1
	fi

	if git -C "$worktree_path" diff --quiet && git -C "$worktree_path" diff --cached --quiet; then
		local untracked
		untracked=$(git -C "$worktree_path" ls-files --others --exclude-standard 2>/dev/null || echo "")
		if [[ -z "$untracked" ]]; then
			log_info "No changes detected after re-importing all skills — skipping"
			_cleanup_worktree "$worktree_path" "$branch_name"
			return 1
		fi
	fi

	# Echo the list so the caller can capture it without a global
	echo "$imported_skills_list"
	return 0
}

# Create one PR containing updates for all skills that have upstream changes.
# Arguments:
#   $1 - target skill name (optional; empty = all skills)
# Returns: 0 on success, 1 on failure
cmd_pr_batch() {
	local target_skill="${1:-}"

	require_jq

	local skill_count
	skill_count=$(check_skill_sources)

	log_info "Checking $skill_count imported skill(s) for upstream updates (batch mode)..."
	echo ""

	if [[ "$DRY_RUN" != true ]] && ! command -v gh &>/dev/null; then
		log_error "gh CLI is required for PR creation"
		log_info "Install with: brew install gh (macOS) or see https://cli.github.com/"
		return 1
	fi

	local repo_root default_branch
	repo_root=$(get_repo_root)
	if [[ -z "$repo_root" ]]; then
		log_error "Not in a git repository"
		return 1
	fi
	default_branch=$(get_default_branch)

	local skills_to_update=() skill_urls=() skill_current_commits=() skill_latest_commits=()
	_collect_skills_needing_update "$target_skill"

	local update_count="${#skills_to_update[@]}"
	if [[ "$update_count" -eq 0 ]]; then
		log_info "No skills require updates — no PR needed"
		return 0
	fi

	log_info "Found $update_count skill(s) with updates"
	echo ""

	local timestamp branch_name
	timestamp=$(date -u +"%Y%m%d")
	branch_name="chore/skill-update-batch-${timestamp}"

	if [[ "$DRY_RUN" == true ]]; then
		log_info "DRY RUN: Would create single batch PR for $update_count skill(s)"
		echo "  Branch: $branch_name"
		for i in "${!skills_to_update[@]}"; do
			echo "  - ${skills_to_update[$i]}: ${skill_current_commits[$i]:0:7} → ${skill_latest_commits[$i]:0:7}"
		done
		echo ""
		return 0
	fi

	if command -v gh &>/dev/null; then
		local existing_pr
		existing_pr=$(gh pr list --head "$branch_name" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
		if [[ -n "$existing_pr" ]]; then
			log_warning "PR #${existing_pr} already open for batch branch $branch_name — skipping"
			return 0
		fi
	fi

	local worktree_path
	worktree_path=$(_create_worktree_for_branch "$branch_name" "$repo_root" "batch") || return 1

	local imported_skills=() failed_skills=()
	local imported_skills_list
	imported_skills_list=$(_batch_reimport_and_verify "$worktree_path" "$branch_name") || return 1

	_commit_batch_changes "$worktree_path" "$branch_name" "$timestamp" "$imported_skills_list" || return 1
	_create_batch_pr "$worktree_path" "$branch_name" "$default_branch" "$imported_skills_list" || return 1

	if [[ "${#failed_skills[@]}" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# Check a URL-sourced skill and create a PR if an update is available.
# Increments caller's prs_created, prs_skipped, or prs_failed counters.
# Arguments:
#   $1 - skill JSON object (from jq -c)
#   $2 - skill name
#   $3 - upstream URL
# Returns: 0 always (counters reflect outcome)
_pr_check_url_skill() {
	local skill_json="$1"
	local name="$2"
	local upstream_url="$3"

	local stored_hash stored_etag stored_last_modified latest_hash
	stored_hash=$(echo "$skill_json" | jq -r '.upstream_hash // empty')
	stored_etag=$(echo "$skill_json" | jq -r '.upstream_etag // empty')
	stored_last_modified=$(echo "$skill_json" | jq -r '.upstream_last_modified // empty')

	if ! latest_hash=$(fetch_url_conditional "$upstream_url" "$stored_etag" "$stored_last_modified"); then
		log_warning "Could not fetch URL for $name: $upstream_url — skipping"
		((++prs_skipped))
		return 0
	fi

	update_cache_headers "$name" "$FETCH_RESP_ETAG" "$FETCH_RESP_LAST_MODIFIED"
	update_last_checked "$name"

	if [[ "$latest_hash" == "not_modified" ]]; then
		[[ "$QUIET" != true ]] && echo -e "${GREEN}Up to date${NC}: $name (304 Not Modified)"
		return 0
	fi
	if [[ -n "$stored_hash" && "$latest_hash" == "$stored_hash" ]]; then
		[[ "$QUIET" != true ]] && echo -e "${GREEN}Up to date${NC}: $name"
		return 0
	fi

	if cmd_pr_single "$name" "$upstream_url" "$stored_hash" "$latest_hash" "url"; then
		((++prs_created))
	else
		((++prs_failed))
	fi
	return 0
}

# Check a GitHub-sourced skill and create a PR if an update is available.
# Increments caller's prs_created, prs_skipped, or prs_failed counters.
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - current commit SHA (may be empty)
# Returns: 0 always (counters reflect outcome)
_pr_check_github_skill() {
	local name="$1"
	local upstream_url="$2"
	local current_commit="$3"

	if [[ "$upstream_url" != *"github.com"* ]]; then
		[[ "$QUIET" != true ]] && log_info "Skipping $name (non-GitHub source: ${upstream_url})"
		((++prs_skipped))
		return 0
	fi

	local owner_repo latest_commit
	owner_repo=$(parse_github_url "$upstream_url")
	owner_repo=$(echo "$owner_repo" | cut -d'/' -f1-2)

	if [[ -z "$owner_repo" || "$owner_repo" == "/" ]]; then
		log_warning "Could not parse URL for $name: $upstream_url — skipping"
		((++prs_skipped))
		return 0
	fi
	if ! latest_commit=$(get_latest_commit "$owner_repo"); then
		log_warning "Could not fetch latest commit for $name ($owner_repo) — skipping"
		((++prs_skipped))
		return 0
	fi

	update_last_checked "$name"

	if [[ -n "$current_commit" && "$latest_commit" == "$current_commit" ]]; then
		[[ "$QUIET" != true ]] && echo -e "${GREEN}Up to date${NC}: $name"
		return 0
	fi

	if cmd_pr_single "$name" "$upstream_url" "$current_commit" "$latest_commit" "github"; then
		((++prs_created))
	else
		((++prs_failed))
	fi
	return 0
}

# Orchestrator: check all skills and create PRs for those with updates.
# Dispatches to cmd_pr_batch (single-pr mode) or iterates cmd_pr_single
# (one-per-skill mode, default) based on BATCH_MODE.
cmd_pr() {
	local target_skill="${1:-}"

	if [[ "$BATCH_MODE" == "single-pr" ]]; then
		log_info "Batch mode: single-pr — all updated skills will be combined into one PR"
		cmd_pr_batch "$target_skill"
		return $?
	fi

	require_jq

	local skill_count
	skill_count=$(check_skill_sources)

	log_info "Checking $skill_count imported skill(s) for upstream updates (one PR per skill)..."
	echo ""

	if [[ "$DRY_RUN" != true ]] && ! command -v gh &>/dev/null; then
		log_error "gh CLI is required for PR creation"
		log_info "Install with: brew install gh (macOS) or see https://cli.github.com/"
		return 1
	fi

	local current_branch default_branch
	current_branch=$(git branch --show-current 2>/dev/null || echo "")
	default_branch=$(get_default_branch)

	if [[ "$DRY_RUN" != true && "$current_branch" != "$default_branch" ]]; then
		log_warning "Not on $default_branch (on $current_branch) — worktrees will branch from $default_branch"
	fi

	local prs_created=0
	local prs_skipped=0
	local prs_failed=0

	while IFS= read -r skill_json; do
		local name upstream_url current_commit
		name=$(echo "$skill_json" | jq -r '.name')
		upstream_url=$(echo "$skill_json" | jq -r '.upstream_url')
		current_commit=$(echo "$skill_json" | jq -r '.upstream_commit // empty')

		if [[ -n "$target_skill" && "$name" != "$target_skill" ]]; then
			continue
		fi

		if is_url_skill "$skill_json"; then
			_pr_check_url_skill "$skill_json" "$name" "$upstream_url"
			continue
		fi

		_pr_check_github_skill "$name" "$upstream_url" "$current_commit"

	done < <(jq -c '.skills[]' "$SKILL_SOURCES")

	echo ""
	echo "PR Pipeline Summary:"
	echo "  PRs created: $prs_created"
	if [[ $prs_skipped -gt 0 ]]; then
		echo "  Skipped: $prs_skipped"
	fi
	if [[ $prs_failed -gt 0 ]]; then
		echo "  Failed: $prs_failed"
	fi

	if [[ $prs_failed -gt 0 ]]; then
		return 1
	fi
	return 0
}
