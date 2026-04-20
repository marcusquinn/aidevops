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
#
# Usage: source "${SCRIPT_DIR}/shared-todo-commit.sh"
#        # Sourced from shared-constants.sh — rarely sourced directly.
#
# Dependencies:
#   - git (must be on PATH).
#   - bash 4+ (uses `${var:-default}` and trap EXIT).
#   - GNU coreutils OR macOS BSD coreutils (handles `stat -f` vs `stat -c`).
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
			if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
				echo "[todo_lock] Removing stale lock (PID $lock_pid dead)" >>"$log_target"
				rm -rf "$TODO_LOCK_PATH"
				continue
			fi
		fi

		# Check lock age (safety net for orphaned locks)
		if [[ -d "$TODO_LOCK_PATH" ]]; then
			local lock_age
			if [[ "$(uname)" == "Darwin" ]]; then
				lock_age=$(($(date +%s) - $(stat -f %m "$TODO_LOCK_PATH" 2>/dev/null || echo "0")))
			else
				lock_age=$(($(date +%s) - $(stat -c %Y "$TODO_LOCK_PATH" 2>/dev/null || echo "0")))
			fi
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

todo_commit_push() {
	local repo_path="$1"
	local commit_msg="$2"
	local files="${3:-TODO.md todo/}"
	local log_target="${AIDEVOPS_LOG_FILE:-/dev/null}"

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

	while [[ $attempt -lt $TODO_MAX_RETRIES ]]; do
		attempt=$((attempt + 1))

		# Pull latest before staging (rebase to keep linear history)
		local current_branch
		current_branch=$(git -C "$repo_path" branch --show-current 2>/dev/null || echo "main")
		if git -C "$repo_path" remote get-url origin &>/dev/null; then
			git -C "$repo_path" pull --rebase origin "$current_branch" 2>>"$log_target" || {
				echo "[todo_commit_push] Pull --rebase failed (attempt $attempt/$TODO_MAX_RETRIES)" >>"$log_target"
				# If rebase conflicts, abort and retry
				git -C "$repo_path" rebase --abort 2>/dev/null || true
				sleep 1
				continue
			}
		fi

		# Stage planning files
		local file
		for file in $files; do
			git -C "$repo_path" add "$file" 2>/dev/null || true
		done

		# Check if anything was staged
		if git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
			echo "[todo_commit_push] No changes staged" >>"$log_target"
			return 0
		fi

		# Commit
		if ! git -C "$repo_path" commit -m "$commit_msg" --no-verify 2>>"$log_target"; then
			echo "[todo_commit_push] Commit failed (attempt $attempt/$TODO_MAX_RETRIES)" >>"$log_target"
			continue
		fi

		# Push
		if git -C "$repo_path" push origin "$current_branch" 2>>"$log_target"; then
			echo "[todo_commit_push] Success on attempt $attempt" >>"$log_target"
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
			return 0
		fi

		sleep $((attempt))
	done

	echo "[todo_commit_push] Failed after $TODO_MAX_RETRIES attempts" >>"$log_target"
	return 1
}
