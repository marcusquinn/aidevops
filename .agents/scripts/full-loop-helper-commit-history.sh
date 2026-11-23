#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Commit History -- WIP finalization, replacement ancestry, validators
# =============================================================================
# Focused sub-library for full-loop-helper-commit.sh (GH#39385 split). Holds
# branch-history finalization (WIP squash), replacement-PR ancestry validation
# and project validator/node detection. Function names and globals are unchanged.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-commit-history.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning)
#   - full-loop-helper-commit.sh (_is_wip_commit_message)
#   - Globals: _FULL_LOOP_TRUE, HEADLESS
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_FULL_LOOP_COMMIT_HISTORY_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_COMMIT_HISTORY_LIB_LOADED=1

# Explain the rebase recovery after a non-ancestor refusal. commit-and-pr has
# already committed staged work by this point, so a clean worktree needs a plain
# rebase; an unnamed stash would save nothing and its pop would restore another
# worktree's entry from the shared stash list (GH#39787).
# Args: $1=base ref (for example origin/main)
_report_non_ancestor_recovery() {
	local base_ref="$1"
	local worktree_status="" head_short=""
	if ! worktree_status=$(git status --porcelain 2>/dev/null); then
		print_error "Rebase onto ${base_ref}, resolve any conflicts, then retry commit-and-pr."
		return 0
	fi
	if [[ -z "$worktree_status" ]]; then
		head_short=$(git rev-parse --short HEAD 2>/dev/null || echo "HEAD")
		print_error "Pending changes are already committed at ${head_short}; the worktree is clean."
		print_error "Run 'git rebase ${base_ref}' directly (no stash needed), resolve any conflicts, then retry commit-and-pr."
		return 0
	fi
	print_error "Uncommitted changes remain. Commit them as WIP or use 'git rebase --autostash ${base_ref}'; never an unnamed stash/pop pair (the stash list is shared by all worktrees)."
	print_error "Then resolve any conflicts and retry commit-and-pr."
	return 0
}

# Replace branch history with one final commit when any branch commit is WIP.
# The caller-supplied final message is authoritative. On commit-hook failure,
# restore the original branch tip and preserve any hook-produced working changes.
# Args: $1=final commit message
_finalize_wip_history() {
	local commit_message="$1"
	if _is_wip_commit_message "$commit_message"; then
		print_error "Cannot finalize WIP history with another WIP message: ${commit_message}"
		return 1
	fi

	local base_branch="" branch_range="" branch_subjects=""
	local base_ref="" base_oid=""
	base_branch=$(_resolve_pr_base_branch origin) || return 1
	printf -v base_ref 'origin/%s' "$base_branch"
	if ! git fetch origin "$base_branch" --quiet 2>/dev/null; then
		print_error "Cannot refresh ${base_ref} before WIP history finalization."
		return 1
	fi
	base_oid=$(git rev-parse "$base_ref" 2>/dev/null) || {
		print_error "Cannot snapshot ${base_ref} before WIP history finalization."
		return 1
	}
	printf -v branch_range '%s..HEAD' "$base_oid"
	if ! branch_subjects=$(git log --format=%s "$branch_range" 2>/dev/null); then
		print_error "Cannot inspect branch commit subjects relative to ${base_ref}."
		return 1
	fi

	local subject="" has_wip=0
	while IFS= read -r subject; do
		if _is_wip_commit_message "$subject"; then
			has_wip=1
			break
		fi
	done <<<"$branch_subjects"
	if [[ "$has_wip" == "0" ]]; then
		return 0
	fi

	# The exact-base ancestry proof protects the soft reset below. Non-WIP
	# history does not need rewriting, so let the normal rebase stage integrate
	# a concurrently advanced base instead of rejecting safe base drift here.
	if ! git merge-base --is-ancestor "$base_oid" HEAD 2>/dev/null; then
		print_error "Refusing WIP finalization: current ${base_ref} is not an ancestor of HEAD."
		_report_non_ancestor_recovery "$base_ref"
		return 1
	fi

	local worktree_status=""
	if ! worktree_status=$(git status --porcelain 2>/dev/null); then
		print_error "Cannot verify a clean worktree before WIP history finalization."
		return 1
	fi
	if [[ -n "$worktree_status" ]]; then
		print_error "Refusing to rewrite WIP history with uncommitted changes present."
		return 1
	fi

	local original_head=""
	original_head=$(git rev-parse HEAD 2>/dev/null) || {
		print_error "Cannot record the original branch tip before WIP finalization."
		return 1
	}
	print_info "Finalizing WIP history into one commit relative to ${base_ref} at ${base_oid}..."
	if ! git reset --soft "$base_oid"; then
		print_error "Failed to prepare WIP history for finalization."
		return 1
	fi
	if git diff --cached --quiet 2>/dev/null; then
		print_error "WIP branch has no net changes relative to ${base_ref}."
		git reset --mixed "$original_head" >/dev/null 2>&1 || true
		return 1
	fi
	if ! git commit -m "$commit_message"; then
		print_error "Final WIP squash commit failed; restoring original branch tip."
		if ! git reset --mixed "$original_head" >/dev/null 2>&1; then
			print_error "Failed to restore original branch tip ${original_head}; recover it manually."
		fi
		return 1
	fi
	local final_subject=""
	final_subject=$(git log -1 --format=%s 2>/dev/null || echo "")
	if _is_wip_commit_message "$final_subject"; then
		print_error "Final commit hook produced another WIP subject; restoring original branch tip."
		git reset --mixed "$original_head" >/dev/null 2>&1 || true
		return 1
	fi
	print_info "WIP history finalized as: ${final_subject}"
	return 0
}

# GH#33253: _finalize_wip_history (above) and _rebase_for_push both rewrite
# branch history, which defeats issue_open_pr_guard_check's require_ancestry
# proof if that check runs afterward on the rewritten HEAD. Validate an
# explicit --replace-pr's ancestry now, against the pre-finalization,
# pre-rebase HEAD, while the replaced PR's head commit is still reachable.
# Sets REPLACEMENT_PR_ANCESTRY_VALIDATED=1 when this call proved ancestry, so
# the final guard call downstream can skip its now-defeated ancestry check.
# Args: $1=issue_number $2=repo $3=branch $4=replacement_pr $5=replacement_reason
REPLACEMENT_PR_ANCESTRY_VALIDATED=0
_validate_replacement_pr_ancestry() {
	local issue_number="$1"
	local repo="$2"
	local branch="$3"
	local replacement_pr="$4"
	local replacement_reason="$5"

	REPLACEMENT_PR_ANCESTRY_VALIDATED=0
	[[ -n "$replacement_pr" ]] || return 0

	local guard_rc=0
	issue_open_pr_guard_check "$issue_number" "$repo" "$branch" \
		"$replacement_pr" "$replacement_reason" 1 || guard_rc=$?
	case "$guard_rc" in
	0)
		REPLACEMENT_PR_ANCESTRY_VALIDATED=1
		return 0
		;;
	3)
		# Continuing the same branch/author as the open PR; no separate
		# replacement-ancestry proof is required.
		return 0
		;;
	1)
		print_error "Aborting duplicate PR creation: open PR #${replacement_pr}'s head is not contained in this branch"
		return 1
		;;
	*)
		print_error "Aborting PR creation: replacement-PR ancestry evidence is unavailable or ambiguous"
		return 1
		;;
	esac
}

# --- Project Validators (t2842) ---
# Closes the worker-CI-failure gap where workers ship code that fails
# project CI checks (Format/Lint/Typecheck) because no pre-push
# validation runs at commit time.
# Decomposed into 5 helpers to stay under the function-complexity gate:
#   _run_project_validators       — orchestrator
#   _validators_should_run        — bypass-path check
#   _detect_node_project          — node-project detection (returns pm)
#   _validator_scopes             — affected-workspace/root scope selection
#   _run_scoped_node_checks       — bounded, mutation-guarded check-only scripts

# Print every file changed between the remote default branch and HEAD.
# The merge-base range keeps classification aligned with the complete PR diff
# even when lifecycle synchronization adds a docs-only commit at HEAD.
_validator_changed_files() {
	local base_branch=""
	local base_ref=""
	base_branch=$(_resolve_pr_base_branch origin) || return 1
	printf -v base_ref 'origin/%s' "$base_branch"
	if ! git diff --name-only "${base_ref}...HEAD" 2>/dev/null; then
		print_error "[validators] cannot inspect changed files relative to ${base_ref}"
		return 1
	fi
	return 0
}

# Returns 0 if validators should run, 1 if any bypass condition applies.
# Prints the bypass reason on info as appropriate.
# Args: $1=skip_hooks (0|1)
_validators_should_run() {
	local skip_hooks="${1:-0}"
	if [[ "$skip_hooks" == "1" ]]; then
		return 1
	fi
	if [[ "${AIDEVOPS_SKIP_PROJECT_VALIDATORS:-0}" == "1" ]]; then
		print_info "[validators] AIDEVOPS_SKIP_PROJECT_VALIDATORS=1, skipping"
		return 1
	fi
	local changed_files=""
	if ! changed_files=$(_validator_changed_files); then
		print_warning "[validators] changed-file classification failed; running validators fail-closed"
		return 0
	fi
	local non_docs_count
	non_docs_count=$(printf '%s\n' "$changed_files" |
		grep -cvE '\.(md|txt|rst)$|^LICENSE|^COPYING|^\.gitignore$|^$' || true)
	# safe_grep_count guard (t2763): zero-match path may emit "0\n0"
	[[ "$non_docs_count" =~ ^[0-9]+$ ]] || non_docs_count=0
	if [[ "$non_docs_count" == "0" ]]; then
		print_info "[validators] docs-only change, skipping"
		return 1
	fi
	return 0
}

# Returns 0 when the PR range changes files covered by Node validators.
# This keeps shell-only commits from failing on missing local Node dependencies
# while preserving fail-closed typecheck behaviour for JS/TS/package changes.
_commit_touches_node_files() {
	local changed_files=""
	if ! changed_files=$(_validator_changed_files); then
		print_warning "[validators] Node changed-file classification failed; running Node validators fail-closed"
		return 0
	fi
	local changed_file
	while IFS= read -r changed_file; do
		case "$changed_file" in
		package.json | package-lock.json | npm-shrinkwrap.json | pnpm-lock.yaml | pnpm-workspace.yaml | yarn.lock | bun.lock | bun.lockb)
			return 0
			;;
		*.js | *.jsx | *.mjs | *.cjs | *.ts | *.tsx | *.mts | *.cts)
			return 0
			;;
		*.json | *.jsonc | *.yaml | *.yml)
			case "$changed_file" in
			*.eslintrc.* | eslint.config.* | tsconfig*.json | jsconfig*.json | prettier.config.* | .prettierrc*)
				return 0
				;;
			esac
			;;
		esac
	done <<<"$changed_files"
	return 1
}

# Detect node project type and chosen package manager.
# Sets caller-scope `pm` variable (npm/pnpm/yarn) on success.
# Returns 0 if a node project with relevant scripts is detected, 1 otherwise.
_detect_node_project() {
	if [[ ! -f package.json ]]; then
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		print_warning "[validators] jq not available, cannot inspect package.json — skipping"
		return 1
	fi
	local has_relevant_scripts
	# Check-only scripts and workspaces are executable validation surfaces. Legacy
	# mutating-only scripts are also detected so the orchestrator can fail with
	# actionable configuration guidance instead of silently reporting success.
	has_relevant_scripts=$(jq -r '
		(.scripts // {} |
		 [has("format:check"),has("check:format"),has("prettier:check"),
		  has("lint:check"),has("lint"),
		  has("typecheck"),has("check:types"),has("tsc"),has("test"),
		  has("format:fix"),has("format:write"),has("prettier:fix"),has("lint:fix")] |
		 any) or
		((.workspaces // []) |
		 if arrays then length > 0 else ((.packages? // []) | length > 0) end)
	' package.json 2>/dev/null || echo "false")
	if [[ "$has_relevant_scripts" != "true" && ! -f pnpm-workspace.yaml ]]; then
		return 1
	fi
	pm="npm"
	if [[ -f pnpm-lock.yaml ]]; then
		pm="pnpm"
	elif [[ -f yarn.lock ]]; then
		pm="yarn"
	fi
	return 0
}
