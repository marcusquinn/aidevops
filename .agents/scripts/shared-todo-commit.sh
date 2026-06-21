#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared TODO.md Serialized Commit+Push (extracted from shared-constants.sh)
# =============================================================================
# Atomic-locked, pull-rebase-retry commit+push for TODO.md and adjacent
# planning files (todo/). Extracted from shared-constants.sh (t2441, GH#20094)
# to keep that file below the file-size-debt ratchet (1500 lines). Mirrors the
# Phase 1 (shared-feature-toggles.sh, t2427/PR #20063) and Phase 2
# (shared-model-tier.sh, t2440/PR #20092) split precedents.
#
# Prevents race conditions when multiple actors (supervisor, interactive
# sessions) push to TODO.md on main simultaneously. Workers (headless dispatch
# runners) must NOT call this function or edit TODO.md directly — they report
# status via exit code/log/mailbox; the supervisor handles all TODO.md updates.
#
# Public API (backward-compatible — single non-test caller is
# planning-commit-helper.sh, which sources shared-constants.sh and gets this
# function transitively):
#   - todo_commit_push <repo_path> <commit_message> [files]
#                                     — acquires lock, calls inner with
#                                       pull-rebase-retry, releases lock on
#                                       EXIT. `files` defaults to
#                                       "TODO.md todo/". Returns 0 on success
#                                       or 1 on failure after retries.
#
# Internal helpers:
#   - _todo_acquire_lock <log_target>  — portable atomic lock via mkdir,
#                                        with stale-lock detection (PID +
#                                        age safety net). Returns 0 on
#                                        acquired, 1 on timeout.
#   - _todo_release_lock              — removes the lock dir.
#   - _todo_commit_push_inner         — pull-rebase-retry loop bounded by
#                                        TODO_MAX_RETRIES.
#
# Tunable constants (readonly):
#   - TODO_LOCK_DIR              — ${HOME}/.aidevops/locks
#   - TODO_LOCK_PATH             — ${TODO_LOCK_DIR}/todo-md.lock
#   - TODO_MAX_RETRIES           — 3
#   - TODO_LOCK_TIMEOUT          — 30 (seconds to wait for lock acquisition)
#   - TODO_STALE_LOCK_AGE        — 120 (seconds before age-based reclaim)
#   - AIDEVOPS_PLANNING_FORCE_PR_FALLBACK=1
#                                 — force the protected-default planning PR
#                                   path (test/operator override).
#   - AIDEVOPS_PLANNING_PR_REPO_SLUG=owner/repo
#                                 — override GitHub slug detection for PRs.
#
# Usage: source "${SCRIPT_DIR}/shared-todo-commit.sh"
#        # Sourced from shared-constants.sh — rarely sourced directly.
#
# Dependencies:
#   - git (must be on PATH).
#   - bash 4+ (uses `${var:-default}` and trap EXIT).
#   - portable-stat.sh (cross-platform stat via shared-constants.sh).
#   - $AIDEVOPS_LOG_FILE (optional — log target for lock + retry diagnostics;
#     defaults to /dev/null).
#
# NOTE: This file is sourced BY shared-constants.sh, so all print_* and other
# utility functions from shared-constants.sh are already in scope at load time.
# If sourcing this file standalone (e.g. in tests), source shared-constants.sh
# first — this library does not call any print_* helpers directly.
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_TODO_COMMIT_LOADED:-}" ]] && return 0
_SHARED_TODO_COMMIT_LOADED=1

# =============================================================================
# TODO.md Serialized Commit+Push
# =============================================================================
# Provides atomic locking and pull-rebase-retry for TODO.md operations.
# Prevents race conditions when multiple actors (supervisor, interactive sessions)
# push to TODO.md on main simultaneously.
#
# Workers (headless dispatch runners) must NOT call this function or edit TODO.md
# directly. They report status via exit code/log/mailbox; the supervisor handles
# all TODO.md updates.
#
# Usage:
#   todo_commit_push "repo_path" "commit message"
#   todo_commit_push "repo_path" "commit message" "TODO.md todo/"  # custom paths
#
# Returns 0 on success, 1 on failure after retries.

# Guard against re-declaration when shared-constants.sh is sourced more than once
# in a process (the readonly statement would otherwise abort the second source).
if [[ -z "${TODO_LOCK_DIR:-}" ]]; then
	readonly TODO_LOCK_DIR="${HOME}/.aidevops/locks"
	readonly TODO_LOCK_PATH="${TODO_LOCK_DIR}/todo-md.lock"
	readonly TODO_MAX_RETRIES=3
	readonly TODO_LOCK_TIMEOUT=30
	readonly TODO_STALE_LOCK_AGE=120
	readonly TODO_COMMIT_RESULT_NOOP="noop"
	readonly TODO_COMMIT_RESULT_DIRECT="direct"
	readonly TODO_COMMIT_RESULT_PR="pr"
fi
if [[ -z "${TODO_COMMIT_RESULT_NOOP:-}" ]]; then
	readonly TODO_COMMIT_RESULT_NOOP="noop"
	readonly TODO_COMMIT_RESULT_DIRECT="direct"
	readonly TODO_COMMIT_RESULT_PR="pr"
fi

# good stuff — portable atomic lock using mkdir (works on macOS + Linux).
# mkdir is atomic on all POSIX systems -- only one process succeeds.
_todo_acquire_lock() {
	local log_target="${1:-/dev/null}"
	local waited=0

	while [[ $waited -lt $TODO_LOCK_TIMEOUT ]]; do
		if mkdir "$TODO_LOCK_PATH" 2>/dev/null; then
			echo $$ >"$TODO_LOCK_PATH/pid"
			return 0
		fi

		# Check for stale lock (owner process died)
		if [[ -f "$TODO_LOCK_PATH/pid" ]]; then
			local lock_pid
			lock_pid=$(cat "$TODO_LOCK_PATH/pid" 2>/dev/null || echo "")
			# t2421: command-aware liveness — bare kill -0 lies on macOS PID reuse
			if [[ -n "$lock_pid" ]] && ! _is_process_alive_and_matches "$lock_pid" "${FRAMEWORK_PROCESS_PATTERN:-}"; then
				echo "[todo_lock] Removing stale lock (PID $lock_pid dead or reused, t2421)" >>"$log_target"
				rm -rf "$TODO_LOCK_PATH"
				continue
			fi
		fi

		# Check lock age (safety net for orphaned locks)
		if [[ -d "$TODO_LOCK_PATH" ]]; then
			local lock_age
			lock_age=$(($(date +%s) - $(_file_mtime_epoch "$TODO_LOCK_PATH")))
			if [[ $lock_age -gt $TODO_STALE_LOCK_AGE ]]; then
				echo "[todo_lock] Removing stale lock (age ${lock_age}s > ${TODO_STALE_LOCK_AGE}s)" >>"$log_target"
				rm -rf "$TODO_LOCK_PATH"
				continue
			fi
		fi

		sleep 1
		waited=$((waited + 1))
	done

	echo "[todo_lock] Failed to acquire lock after ${TODO_LOCK_TIMEOUT}s" >>"$log_target"
	return 1
}

_todo_release_lock() {
	rm -rf "$TODO_LOCK_PATH"
	return 0
}

_todo_current_branch() {
	local repo_path="$1"
	local current_branch=""
	current_branch=$(git -C "$repo_path" branch --show-current 2>/dev/null) || current_branch=""
	printf '%s\n' "$current_branch"
	return 0
}

_todo_default_branch() {
	local repo_path="$1"
	local default_branch=""
	default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || default_branch=""
	if [[ -z "$default_branch" ]]; then
		default_branch=$(git -C "$repo_path" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -1) || default_branch=""
	fi
	if [[ -z "$default_branch" ]]; then
		if git -C "$repo_path" rev-parse --verify --quiet main >/dev/null 2>&1; then
			default_branch="main"
		elif git -C "$repo_path" rev-parse --verify --quiet master >/dev/null 2>&1; then
			default_branch="master"
		else
			default_branch=$(_todo_current_branch "$repo_path")
		fi
	fi
	printf '%s\n' "$default_branch"
	return 0
}

_todo_origin_slug() {
	local repo_path="$1"
	local override_slug="${AIDEVOPS_PLANNING_PR_REPO_SLUG:-}"
	if [[ -n "$override_slug" ]]; then
		printf '%s\n' "$override_slug"
		return 0
	fi

	local remote_url=""
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || remote_url=""
	[[ -n "$remote_url" ]] || return 1

	local slug="$remote_url"
	case "$remote_url" in
	git@github.com:*) slug="${remote_url#git@github.com:}" ;;
	ssh://git@github.com/*) slug="${remote_url#ssh://git@github.com/}" ;;
	https://github.com/*) slug="${remote_url#https://github.com/}" ;;
	http://github.com/*) slug="${remote_url#http://github.com/}" ;;
	*) return 1 ;;
	esac
	slug="${slug%.git}"
	case "$slug" in
	*/*) printf '%s\n' "$slug" ;;
	*) return 1 ;;
	esac
	return 0
}

_todo_branch_requires_planning_pr() {
	local repo_path="$1"
	local branch_name="$2"
	local slug=""

	if [[ "${AIDEVOPS_PLANNING_FORCE_PR_FALLBACK:-0}" == "1" ]]; then
		return 0
	fi
	[[ -n "$branch_name" ]] || return 1
	command -v gh >/dev/null 2>&1 || return 1
	slug=$(_todo_origin_slug "$repo_path") || return 1
	if gh api "repos/${slug}/branches/${branch_name}/protection" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

_todo_slugify_ref_fragment() {
	local raw_text="$1"
	local slug=""
	slug=$(printf '%s' "$raw_text" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-48)
	[[ -n "$slug" ]] || slug="planning-files"
	printf '%s\n' "$slug"
	return 0
}

_todo_safe_planning_path() {
	local rel_path="$1"
	case "$rel_path" in
	TODO.md | todo/*) return 0 ;;
	*) return 1 ;;
	esac
}

_todo_changed_planning_files() {
	local repo_path="$1"
	local files="$2"
	{
		# shellcheck disable=SC2086 # files is the legacy space-delimited API.
		git -C "$repo_path" diff --name-only HEAD -- $files 2>/dev/null || true
		# shellcheck disable=SC2086 # files is the legacy space-delimited API.
		git -C "$repo_path" diff --name-only --cached -- $files 2>/dev/null || true
		# shellcheck disable=SC2086 # files is the legacy space-delimited API.
		git -C "$repo_path" ls-files --others --exclude-standard -- $files 2>/dev/null || true
	} | sort -u | grep -E '^(TODO\.md|todo/)' || true
	return 0
}

_todo_copy_planning_changes_to_worktree() {
	local repo_path="$1"
	local worktree_path="$2"
	local changed_files="$3"

	local rel_path
	while IFS= read -r rel_path; do
		[[ -n "$rel_path" ]] || continue
		_todo_safe_planning_path "$rel_path" || continue
		if [[ -e "${repo_path}/${rel_path}" ]]; then
			mkdir -p "${worktree_path}/$(dirname "$rel_path")" || return 1
			cp -p "${repo_path}/${rel_path}" "${worktree_path}/${rel_path}" || return 1
		else
			rm -f "${worktree_path}/${rel_path}" || return 1
		fi
	done <<<"$changed_files"
	return 0
}

_todo_clean_source_planning_changes() {
	local repo_path="$1"
	local changed_files="$2"

	local rel_path
	while IFS= read -r rel_path; do
		[[ -n "$rel_path" ]] || continue
		_todo_safe_planning_path "$rel_path" || continue
		if git -C "$repo_path" ls-files --error-unmatch -- "$rel_path" >/dev/null 2>&1; then
			git -C "$repo_path" reset -q HEAD -- "$rel_path" >/dev/null 2>&1 || true
			git -C "$repo_path" checkout -q -- "$rel_path" >/dev/null 2>&1 || return 1
		else
			rm -f "${repo_path}/${rel_path}" || return 1
		fi
	done <<<"$changed_files"
	return 0
}

_todo_remove_temp_worktree() {
	local repo_path="$1"
	local worktree_path="$2"
	[[ -n "$worktree_path" ]] || return 0
	if [[ -e "${worktree_path}/.git" ]]; then
		git -C "$repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
	fi
	return 0
}

_todo_planning_pr_body() {
	local source_branch="$1"
	local default_branch="$2"
	local commit_msg="$3"
	cat <<EOF
## Planning publication

- Publishes TODO.md and todo/ planning-file changes through a PR because ${default_branch} does not accept direct planning pushes.
- Source branch at helper invocation: ${source_branch}.
- Commit message: ${commit_msg}.

## Security and architecture guardrails

- This PR does not update .task-counter.
- Task IDs still come from claim-task-id.sh CAS allocation on a branch that permits atomic counter pushes.
- Do not replace counter allocation with a PR-backed counter update; PR review is not an atomic ID lock.

## Merge note

- Merge this planning-only PR before expecting pulse or issue-sync to see the TODO/todo changes.
EOF
	return 0
}

_todo_planning_pr_slug() {
	local repo_path="$1"
	local log_target="$2"

	local slug=""
	if ! command -v gh >/dev/null 2>&1 || ! command -v gh_create_pr >/dev/null 2>&1; then
		printf '%s\n' "[todo_commit_push] Planning PR fallback unavailable: gh/gh_create_pr not available" >>"$log_target"
		return 1
	fi
	slug=$(_todo_origin_slug "$repo_path") || {
		printf '%s\n' "[todo_commit_push] Planning PR fallback unavailable: cannot resolve GitHub repo slug" >>"$log_target"
		return 1
	}
	printf '%s\n' "$slug"
	return 0
}

_TODO_PLANNING_PR_BRANCH=""
_TODO_PLANNING_PR_WORKTREE=""

_todo_create_planning_worktree() {
	local repo_path="$1"
	local commit_msg="$2"
	local default_branch="$3"
	local log_target="$4"

	if git -C "$repo_path" remote get-url origin >/dev/null 2>&1; then
		git -C "$repo_path" fetch -q origin "$default_branch" 2>>"$log_target" || {
			printf '%s\n' "[todo_commit_push] Planning PR fallback failed: cannot fetch origin/${default_branch}" >>"$log_target"
			return 1
		}
	fi

	local repo_abs parent_dir repo_name slug_part timestamp branch_name worktree_path
	repo_abs=$(cd "$repo_path" 2>/dev/null && pwd -P) || return 1
	parent_dir=$(dirname "$repo_abs") || return 1
	repo_name=$(basename "$repo_abs") || return 1
	slug_part=$(_todo_slugify_ref_fragment "$commit_msg")
	timestamp=$(date -u +%Y%m%d%H%M%S)
	branch_name="planning/${timestamp}-$$-${slug_part}"
	worktree_path="${parent_dir}/${repo_name}-planning-${timestamp}-$$-${slug_part}"

	if [[ -e "$worktree_path" ]]; then
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: worktree path already exists" >>"$log_target"
		return 1
	fi

	git -C "$repo_path" worktree add -b "$branch_name" "$worktree_path" "origin/${default_branch}" >/dev/null 2>>"$log_target" || {
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: cannot create linked worktree" >>"$log_target"
		return 1
	}

	_TODO_PLANNING_PR_BRANCH="$branch_name"
	_TODO_PLANNING_PR_WORKTREE="$worktree_path"
	return 0
}

_todo_commit_planning_worktree() {
	local repo_path="$1"
	local worktree_path="$2"
	local changed_files="$3"
	local files="$4"
	local commit_msg="$5"
	local branch_name="$6"
	local log_target="$7"

	if ! _todo_copy_planning_changes_to_worktree "$repo_path" "$worktree_path" "$changed_files"; then
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: cannot copy planning changes" >>"$log_target"
		_todo_remove_temp_worktree "$repo_path" "$worktree_path"
		return 1
	fi

	# shellcheck disable=SC2086 # files is the legacy space-delimited API.
	git -C "$worktree_path" add $files 2>>"$log_target" || true
	if git -C "$worktree_path" diff --cached --quiet 2>/dev/null; then
		printf '%s\n' "[todo_commit_push] No changes staged in planning PR worktree" >>"$log_target"
		_todo_remove_temp_worktree "$repo_path" "$worktree_path"
		TODO_COMMIT_PUSH_RESULT="$TODO_COMMIT_RESULT_NOOP"
		return 0
	fi

	git -C "$worktree_path" commit -m "$commit_msg" --no-verify >/dev/null 2>>"$log_target" || {
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: commit failed" >>"$log_target"
		_todo_remove_temp_worktree "$repo_path" "$worktree_path"
		return 1
	}

	git -C "$worktree_path" push -u origin "$branch_name" >/dev/null 2>>"$log_target" || {
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: branch push failed" >>"$log_target"
		_todo_remove_temp_worktree "$repo_path" "$worktree_path"
		return 1
	}
	return 0
}

_todo_open_planning_pr() {
	local slug="$1"
	local default_branch="$2"
	local branch_name="$3"
	local current_branch="$4"
	local commit_msg="$5"
	local log_target="$6"

	local pr_title pr_body pr_url
	pr_title="$commit_msg"
	pr_body=$(_todo_planning_pr_body "$current_branch" "$default_branch" "$commit_msg")
	pr_url=$(AIDEVOPS_PR_CREATE_READY=1 gh_create_pr \
		--repo "$slug" \
		--base "$default_branch" \
		--head "$branch_name" \
		--title "$pr_title" \
		--body "$pr_body" 2>>"$log_target") || {
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: PR creation failed" >>"$log_target"
		return 1
	}
	printf '%s\n' "$pr_url"
	return 0
}

_todo_create_planning_pr() {
	local repo_path="$1"
	local commit_msg="$2"
	local files="$3"
	local current_branch="$4"
	local default_branch="$5"
	local log_target="$6"

	local slug="" changed_files="" branch_name="" worktree_path="" pr_url=""
	slug=$(_todo_planning_pr_slug "$repo_path" "$log_target") || return 1
	changed_files=$(_todo_changed_planning_files "$repo_path" "$files")
	if [[ -z "$changed_files" ]]; then
		printf '%s\n' "[todo_commit_push] No planning changes available for PR fallback" >>"$log_target"
		TODO_COMMIT_PUSH_RESULT="$TODO_COMMIT_RESULT_NOOP"
		return 0
	fi

	_todo_create_planning_worktree "$repo_path" "$commit_msg" "$default_branch" "$log_target" || return 1
	branch_name="$_TODO_PLANNING_PR_BRANCH"
	worktree_path="$_TODO_PLANNING_PR_WORKTREE"
	_todo_commit_planning_worktree "$repo_path" "$worktree_path" "$changed_files" "$files" "$commit_msg" "$branch_name" "$log_target" || return 1
	pr_url=$(_todo_open_planning_pr "$slug" "$default_branch" "$branch_name" "$current_branch" "$commit_msg" "$log_target") || return 1

	if ! _todo_clean_source_planning_changes "$repo_path" "$changed_files"; then
		printf '%s\n' "[todo_commit_push] Planning PR created but source planning cleanup failed" >>"$log_target"
		return 1
	fi
	_todo_remove_temp_worktree "$repo_path" "$worktree_path"
	TODO_COMMIT_PUSH_RESULT="$TODO_COMMIT_RESULT_PR"
	TODO_COMMIT_PUSH_PR_URL="$pr_url"
	printf '%s\n' "[todo_commit_push] Planning PR created: ${pr_url}" >>"$log_target"
	return 0
}

todo_commit_push() {
	local repo_path="$1"
	local commit_msg="$2"
	local files="${3:-TODO.md todo/}"
	local log_target="${AIDEVOPS_LOG_FILE:-/dev/null}"
	TODO_COMMIT_PUSH_RESULT=""
	TODO_COMMIT_PUSH_PR_URL=""

	mkdir -p "$TODO_LOCK_DIR" 2>/dev/null || true

	if ! _todo_acquire_lock "$log_target"; then
		return 1
	fi

	# Ensure lock is released on exit (including signals)
	trap '_todo_release_lock' EXIT

	local rc=0
	_todo_commit_push_inner "$repo_path" "$commit_msg" "$files" "$log_target" || rc=$?

	_todo_release_lock
	trap - EXIT

	return $rc
}

_todo_commit_push_inner() {
	local repo_path="$1"
	local commit_msg="$2"
	local files="$3"
	local log_target="$4"
	local attempt=0
	local current_branch=""
	local default_branch=""

	current_branch=$(_todo_current_branch "$repo_path")
	default_branch=$(_todo_default_branch "$repo_path")
	if [[ -n "$current_branch" && -n "$default_branch" && "$current_branch" == "$default_branch" ]]; then
		if _todo_branch_requires_planning_pr "$repo_path" "$default_branch"; then
			printf '%s\n' "[todo_commit_push] Default branch ${default_branch} requires PR publication for planning files" >>"$log_target"
			_todo_create_planning_pr "$repo_path" "$commit_msg" "$files" "$current_branch" "$default_branch" "$log_target"
			return $?
		fi
	fi

	current_branch=$(_todo_current_branch "$repo_path")
	[[ -n "$current_branch" ]] || current_branch="main"

	# Stage and commit before pull/rebase. Pulling first fails when the caller has
	# unstaged planning edits; after a local planning commit, rebase can safely
	# linearise against a moved remote branch before push.
	local file
	for file in $files; do
		git -C "$repo_path" add "$file" 2>/dev/null || true
	done

	if git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
		echo "[todo_commit_push] No changes staged" >>"$log_target"
		TODO_COMMIT_PUSH_RESULT="$TODO_COMMIT_RESULT_NOOP"
		return 0
	fi

	if ! git -C "$repo_path" commit -m "$commit_msg" --no-verify 2>>"$log_target"; then
		echo "[todo_commit_push] Commit failed" >>"$log_target"
		return 1
	fi

	while [[ $attempt -lt $TODO_MAX_RETRIES ]]; do
		attempt=$((attempt + 1))

		# Push first; only pay the rebase cost if the remote moved or rejected.
		if git -C "$repo_path" push origin "$current_branch" 2>>"$log_target"; then
			echo "[todo_commit_push] Success on attempt $attempt" >>"$log_target"
			TODO_COMMIT_PUSH_RESULT="$TODO_COMMIT_RESULT_DIRECT"
			return 0
		fi

		echo "[todo_commit_push] Push failed (attempt $attempt/$TODO_MAX_RETRIES), retrying..." >>"$log_target"

		# Push failed: pull --rebase to incorporate remote changes, then retry push
		git -C "$repo_path" pull --rebase origin "$current_branch" 2>>"$log_target" || {
			git -C "$repo_path" rebase --abort 2>/dev/null || true
			sleep 1
			continue
		}

		# Retry push after rebase
		if git -C "$repo_path" push origin "$current_branch" 2>>"$log_target"; then
			echo "[todo_commit_push] Success after rebase on attempt $attempt" >>"$log_target"
			TODO_COMMIT_PUSH_RESULT="$TODO_COMMIT_RESULT_DIRECT"
			return 0
		fi

		sleep $((attempt))
	done

	echo "[todo_commit_push] Failed after $TODO_MAX_RETRIES attempts" >>"$log_target"
	return 1
}
