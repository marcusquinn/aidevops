#!/usr/bin/env bash
# cleanup.sh - Cleanup and worktree management functions
#
# Functions for creating/cleaning worktrees, killing workers,
# and post-merge cleanup


#######################################
# Create a worktree for a task
# Returns the worktree path on stdout
#######################################
create_task_worktree() {
	local task_id="$1"
	local repo="$2"
	local force_fresh="${3:-false}"

	local branch_name="feature/${task_id}"
	# Derive worktree path: ~/Git/repo-name.feature-tXXX (matches wt convention)
	local repo_basename
	repo_basename=$(basename "$repo")
	local repo_parent
	repo_parent=$(dirname "$repo")
	local worktree_path="${repo_parent}/${repo_basename}.feature-${task_id}"

	# Detect and clean stale branches/worktrees before creating new ones.
	# A branch is "stale" if it exists but is not ahead of main (no unique
	# commits), or if force_fresh is requested (retry with clean slate).
	local needs_cleanup=false

	if [[ "$force_fresh" == "true" ]]; then
		# (t229) Check for open PRs — reuse the branch to preserve review context
		# instead of deleting and recreating (reduces PR churn)
		local open_pr_url
		open_pr_url=$(gh pr list --head "$branch_name" --state open --json url --jq '.[0].url' 2>/dev/null || echo "")
		if [[ -n "$open_pr_url" && "$open_pr_url" != "null" ]]; then
			# Validate PR belongs to this task (t223)
			local repo_slug_ff
			repo_slug_ff=$(detect_repo_slug "$repo" 2>/dev/null || echo "")
			local validated_ff=""
			if [[ -n "$repo_slug_ff" ]]; then
				validated_ff=$(validate_pr_belongs_to_task "$task_id" "$repo_slug_ff" "$open_pr_url") || validated_ff=""
			fi
			if [[ -n "$validated_ff" ]]; then
				# (t229) Reuse existing branch+PR: reset worktree to main content
				# but keep the branch so the open PR and its review context survive.
				log_info "Force-fresh with existing PR — resetting branch to main (preserving PR: $open_pr_url)" >&2
				if [[ -d "$worktree_path" ]]; then
					# Reset worktree contents to match main (fresh code, same branch)
					if git -C "$worktree_path" fetch origin main &>/dev/null &&
						git -C "$worktree_path" reset --hard origin/main &>/dev/null; then
						# Force-push the reset so remote branch matches local.
						# This lets the worker's normal `git push` work without --force.
						# --force-with-lease is safer than --force (rejects if someone else pushed).
						git -C "$worktree_path" push --force-with-lease origin "$branch_name" &>/dev/null ||
							log_warn "Force-push after reset failed — worker may need --force on first push" >&2
						log_info "Worktree $worktree_path reset to origin/main on branch $branch_name" >&2
						echo "$worktree_path"
						return 0
					else
						log_warn "Failed to reset worktree to main — falling back to recreate" >&2
					fi
				else
					# No worktree but branch+PR exist — create worktree on existing branch
					# First fetch to ensure we have the remote branch
					git -C "$repo" fetch origin "$branch_name" &>/dev/null || true
					if git -C "$repo" worktree add "$worktree_path" "$branch_name" >&2 2>&1; then
						# Reset to main for fresh code
						if git -C "$worktree_path" fetch origin main &>/dev/null &&
							git -C "$worktree_path" reset --hard origin/main &>/dev/null; then
							# Force-push the reset so remote branch matches local
							git -C "$worktree_path" push --force-with-lease origin "$branch_name" &>/dev/null ||
								log_warn "Force-push after reset failed — worker may need --force on first push" >&2
							register_worktree "$worktree_path" "$branch_name" --task "$task_id"
							log_info "Created worktree on existing branch $branch_name, reset to origin/main" >&2
							echo "$worktree_path"
							return 0
						else
							log_warn "Failed to reset new worktree to main — falling back to recreate" >&2
							git -C "$repo" worktree remove "$worktree_path" --force &>/dev/null || true
						fi
					else
						log_warn "Failed to create worktree on existing branch — falling back to recreate" >&2
					fi
				fi
				# If we get here, the reuse attempt failed — fall through to full cleanup
				log_warn "Branch reuse failed for $task_id — falling back to delete+recreate" >&2
			else
				log_warn "Force-fresh: open PR on $branch_name does not reference $task_id — skipping PR reuse to prevent cross-contamination" >&2
			fi
		fi
		needs_cleanup=true
		log_info "Force-fresh requested for $task_id — cleaning stale worktree/branch" >&2
	elif [[ -d "$worktree_path" ]]; then
		# Worktree exists — check if the branch has unmerged work worth keeping
		local ahead_count
		ahead_count=$(git -C "$worktree_path" rev-list --count "main..HEAD" 2>/dev/null || echo "0")
		if [[ "$ahead_count" -eq 0 ]]; then
			# Before deleting, check if branch has an open PR with unmerged work
			local open_pr_count
			open_pr_count=$(gh pr list --head "$branch_name" --state open --json number --jq 'length' 2>/dev/null || echo "0")
			if [[ "$open_pr_count" -gt 0 ]]; then
				log_warn "Branch $branch_name has 0 commits ahead but has an open PR — keeping" >&2
				echo "$worktree_path"
				return 0
			fi
			needs_cleanup=true
			log_info "Stale worktree for $task_id (0 commits ahead of main, no open PR) — recreating" >&2
		else
			# Has commits — check if branch has diverged badly from main
			# (more than 50 files changed = likely rebased from old main)
			local diff_files
			diff_files=$(git -C "$worktree_path" diff --name-only "main..HEAD" 2>/dev/null | wc -l || echo "0")
			diff_files=$(echo "$diff_files" | tr -d ' ')
			if [[ "$diff_files" -gt 50 ]]; then
				needs_cleanup=true
				log_warn "Stale worktree for $task_id ($diff_files files diverged from main) — recreating" >&2
			else
				log_info "Worktree already exists with $ahead_count commit(s): $worktree_path" >&2
				echo "$worktree_path"
				return 0
			fi
		fi
	elif git -C "$repo" rev-parse --verify "$branch_name" &>/dev/null; then
		# No worktree but branch exists — check if it's stale
		local ahead_count
		ahead_count=$(git -C "$repo" rev-list --count "main..$branch_name" 2>/dev/null || echo "0")
		if [[ "$ahead_count" -eq 0 ]]; then
			# Before deleting, check if branch has an open PR with unmerged work
			local open_pr_count
			open_pr_count=$(gh pr list --head "$branch_name" --state open --json number --jq 'length' 2>/dev/null || echo "0")
			if [[ "$open_pr_count" -gt 0 ]]; then
				log_warn "Branch $branch_name has 0 commits ahead but has an open PR — skipping cleanup" >&2
			else
				needs_cleanup=true
				log_info "Stale branch $branch_name (0 commits ahead of main, no open PR) — deleting" >&2
			fi
		else
			local diff_files
			diff_files=$(git -C "$repo" diff --name-only "main..$branch_name" 2>/dev/null | wc -l || echo "0")
			diff_files=$(echo "$diff_files" | tr -d ' ')
			if [[ "$diff_files" -gt 50 ]]; then
				needs_cleanup=true
				log_warn "Stale branch $branch_name ($diff_files files diverged from main) — deleting" >&2
			fi
		fi
	fi

	if [[ "$needs_cleanup" == "true" ]]; then
		# Ownership check (t189): refuse to clean worktrees owned by other sessions
		if [[ -d "$worktree_path" ]] && is_worktree_owned_by_others "$worktree_path"; then
			local stale_owner_info
			stale_owner_info=$(check_worktree_owner "$worktree_path" || echo "unknown")
			log_warn "Cannot clean stale worktree $worktree_path — owned by another active session (owner: $stale_owner_info)" >&2
			# Return existing path — let the caller decide
			echo "$worktree_path"
			return 0
		fi
		# Remove worktree if it exists
		if [[ -d "$worktree_path" ]]; then
			git -C "$repo" worktree remove "$worktree_path" --force &>/dev/null || rm -rf "$worktree_path"
			git -C "$repo" worktree prune &>/dev/null || true
			# Unregister ownership (t189)
			unregister_worktree "$worktree_path"
		fi
		# Delete local branch — MUST suppress stdout (outputs "Deleted branch ...")
		# which would pollute the function's return value captured by $()
		git -C "$repo" branch -D "$branch_name" &>/dev/null || true
		# Delete remote branch (best-effort, don't fail if remote is gone)
		git -C "$repo" push origin --delete "$branch_name" &>/dev/null || true
	fi

	# Try wt first (redirect its verbose output to stderr)
	if command -v wt &>/dev/null; then
		if wt switch -c "$branch_name" -C "$repo" >&2 2>&1; then
			# Register ownership (t189)
			register_worktree "$worktree_path" "$branch_name" --task "$task_id"
			echo "$worktree_path"
			return 0
		fi
	fi

	# Fallback: raw git worktree add (quiet, reliable)
	if git -C "$repo" worktree add "$worktree_path" -b "$branch_name" >&2 2>&1; then
		# Register ownership (t189)
		register_worktree "$worktree_path" "$branch_name" --task "$task_id"
		echo "$worktree_path"
		return 0
	fi

	# Branch may already exist without worktree (e.g. remote-only)
	if git -C "$repo" worktree add "$worktree_path" "$branch_name" >&2 2>&1; then
		# Register ownership (t189)
		register_worktree "$worktree_path" "$branch_name" --task "$task_id"
		echo "$worktree_path"
		return 0
	fi

	log_error "Failed to create worktree for $task_id at $worktree_path"
	return 1
}

#######################################
# Clean up a worktree for a completed/failed task
# Checks ownership registry (t189) before removal
# t240: Added runtime file cleanup, explicit rm fallback, and verification
#######################################
cleanup_task_worktree() {
	local worktree_path="$1"
	local repo="$2"

	if [[ ! -d "$worktree_path" ]]; then
		# Directory gone — clean up registry entry if any
		unregister_worktree "$worktree_path"
		return 0
	fi

	# Ownership check (t189): refuse to remove worktrees owned by other sessions
	if is_worktree_owned_by_others "$worktree_path"; then
		local owner_info
		owner_info=$(check_worktree_owner "$worktree_path" || echo "unknown")
		log_warn "Skipping cleanup of $worktree_path — owned by another active session (owner: $owner_info)"
		return 0
	fi

	# t240: Clean up aidevops runtime files before removal to prevent
	# "contains untracked files" errors (matches worktree-helper.sh cmd_remove)
	rm -rf "$worktree_path/.agents/loop-state" 2>/dev/null || true
	rm -rf "$worktree_path/.agents/tmp" 2>/dev/null || true
	rm -f "$worktree_path/.agents/.DS_Store" 2>/dev/null || true
	rmdir "$worktree_path/.agents" 2>/dev/null || true

	# Try wt remove first (worktrunk CLI)
	if command -v wt &>/dev/null; then
		if wt remove "$worktree_path" 2>>"$SUPERVISOR_LOG"; then
			unregister_worktree "$worktree_path"
			return 0
		fi
	fi

	# Fallback: git worktree remove
	git -C "$repo" worktree remove "$worktree_path" --force 2>>"$SUPERVISOR_LOG" || true

	# t240: Verify removal succeeded — if directory persists, force-remove it
	# This handles edge cases where git worktree remove fails silently
	# (e.g., corrupted .git file, stale lock, or remaining untracked files)
	if [[ -d "$worktree_path" ]]; then
		log_warn "Worktree directory persists after git removal: $worktree_path — force-removing (t240)"
		rm -rf "$worktree_path" 2>>"$SUPERVISOR_LOG" || true
		# Also prune the stale worktree reference from git
		git -C "$repo" worktree prune 2>>"$SUPERVISOR_LOG" || true
	fi

	# Unregister regardless of removal success
	unregister_worktree "$worktree_path"
	return 0
}

#######################################
# Kill a worker's process tree (PID + all descendants)
# Called when a worker finishes to prevent orphaned processes
#######################################
cleanup_worker_processes() {
	local task_id="$1"

	local pid_file="$SUPERVISOR_DIR/pids/${task_id}.pid"
	if [[ ! -f "$pid_file" ]]; then
		return 0
	fi

	local pid
	pid=$(cat "$pid_file")

	# Kill the entire process group if possible
	# First kill descendants (children, grandchildren), then the worker itself
	local killed=0
	if kill -0 "$pid" 2>/dev/null; then
		# Recursively kill all descendants
		_kill_descendants "$pid"
		# Kill the worker process itself
		kill "$pid" 2>/dev/null && killed=$((killed + 1))
		# Wait briefly for cleanup
		sleep 1
		# Force kill if still alive
		if kill -0 "$pid" 2>/dev/null; then
			kill -9 "$pid" 2>/dev/null || true
		fi
	fi

	rm -f "$pid_file"

	if [[ "$killed" -gt 0 ]]; then
		log_info "Cleaned up worker process for $task_id (PID: $pid)"
	fi

	return 0
}

#######################################
# Recursively kill all descendant processes of a PID
#######################################
_kill_descendants() {
	local parent_pid="$1"
	local children
	children=$(pgrep -P "$parent_pid" 2>/dev/null) || true

	if [[ -n "$children" ]]; then
		for child in $children; do
			_kill_descendants "$child"
			kill "$child" 2>/dev/null || true
		done
	fi

	return 0
}

#######################################
# List all descendant PIDs of a process (stdout, space-separated)
# Used to build protection lists without killing anything
#######################################
_list_descendants() {
	local parent_pid="$1"
	local children
	children=$(pgrep -P "$parent_pid" 2>/dev/null) || true

	for child in $children; do
		echo "$child"
		_list_descendants "$child"
	done

	return 0
}

#######################################
# Kill all orphaned worker processes (emergency cleanup)
# Finds opencode worker processes with PPID=1 that match supervisor patterns
#######################################
cmd_kill_workers() {
	local dry_run=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	# Collect PIDs to protect: active workers still in running/dispatched state
	local protected_pattern=""
	if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
		for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
			[[ -f "$pid_file" ]] || continue
			local pid
			pid=$(cat "$pid_file")
			local task_id
			task_id=$(basename "$pid_file" .pid)

			# Check if task is still active
			local task_status
			task_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")

			if [[ "$task_status" == "running" || "$task_status" == "dispatched" ]] && kill -0 "$pid" 2>/dev/null; then
				protected_pattern="${protected_pattern}|${pid}"
				# Also protect all descendants (children, grandchildren, MCP servers)
				local descendants
				descendants=$(_list_descendants "$pid")
				for desc in $descendants; do
					protected_pattern="${protected_pattern}|${desc}"
				done
			fi
		done
	fi

	# Also protect the calling process chain (this terminal session)
	local self_pid=$$
	while [[ "$self_pid" -gt 1 ]] 2>/dev/null; do
		protected_pattern="${protected_pattern}|${self_pid}"
		self_pid=$(ps -o ppid= -p "$self_pid" 2>/dev/null | tr -d ' ')
		[[ -z "$self_pid" ]] && break
	done
	protected_pattern="${protected_pattern#|}"

	log_info "Protected PIDs (active workers + self): $(echo "$protected_pattern" | tr '|' ' ' | wc -w | tr -d ' ') processes"

	# Find orphaned opencode worker processes (PPID=1, not in any terminal session)
	local orphan_count=0
	local killed_count=0

	while read -r pid; do
		local ppid
		ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
		[[ "$ppid" != "1" ]] && continue

		# Check not in protected list
		if [[ -n "$protected_pattern" ]] && echo "|${protected_pattern}|" | grep -q "|${pid}|"; then
			continue
		fi

		orphan_count=$((orphan_count + 1))

		if [[ "$dry_run" == "true" ]]; then
			local cmd_info
			cmd_info=$(ps -o args= -p "$pid" 2>/dev/null | head -c 80)
			log_info "  [dry-run] Would kill PID $pid: $cmd_info"
		else
			_kill_descendants "$pid"
			kill "$pid" 2>/dev/null && killed_count=$((killed_count + 1))
		fi
	done < <(pgrep -f 'opencode|claude' 2>/dev/null || true)

	if [[ "$dry_run" == "true" ]]; then
		log_info "Found $orphan_count orphaned worker processes (dry-run, none killed)"
	else
		if [[ "$killed_count" -gt 0 ]]; then
			log_success "Killed $killed_count orphaned worker processes"
		else
			log_info "No orphaned worker processes found"
		fi
	fi

	return 0
}

#######################################
# Clean up worktrees for completed/failed tasks
#######################################
cmd_cleanup() {
	local dry_run=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	# Find tasks with worktrees that are in terminal states
	local terminal_tasks
	terminal_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, worktree, repo, status FROM tasks
        WHERE worktree IS NOT NULL AND worktree != ''
        AND status IN ('deployed', 'verified', 'merged', 'failed', 'cancelled');
    ")

	if [[ -z "$terminal_tasks" ]]; then
		log_info "No worktrees to clean up"
		return 0
	fi

	local cleaned=0
	while IFS='|' read -r tid tworktree trepo tstatus; do
		if [[ ! -d "$tworktree" ]]; then
			log_info "  $tid: worktree already removed ($tworktree)"
			# Clear worktree field in DB
			db "$SUPERVISOR_DB" "
                UPDATE tasks SET worktree = NULL WHERE id = '$(sql_escape "$tid")';
            "
			continue
		fi

		if [[ "$dry_run" == "true" ]]; then
			log_info "  [dry-run] Would remove: $tworktree ($tid, $tstatus)"
		else
			log_info "  Removing worktree: $tworktree ($tid)"
			cleanup_task_worktree "$tworktree" "$trepo"
			db "$SUPERVISOR_DB" "
                UPDATE tasks SET worktree = NULL WHERE id = '$(sql_escape "$tid")';
            "
			cleaned=$((cleaned + 1))
		fi
	done <<<"$terminal_tasks"

	# Clean up worker processes and stale PID files (t128.7)
	local process_cleaned=0
	if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
		for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
			[[ -f "$pid_file" ]] || continue
			local task_id_from_pid
			task_id_from_pid=$(basename "$pid_file" .pid)
			local pid
			pid=$(cat "$pid_file")

			# Check task state - only clean up terminal-state tasks
			local task_state
			task_state=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id_from_pid")';" 2>/dev/null || echo "unknown")

			case "$task_state" in
			complete | failed | cancelled | blocked)
				if [[ "$dry_run" == "true" ]]; then
					local alive_status="dead"
					kill -0 "$pid" 2>/dev/null && alive_status="alive"
					log_info "  [dry-run] Would clean up $task_id_from_pid process tree (PID: $pid, $alive_status)"
				else
					cleanup_worker_processes "$task_id_from_pid"
					process_cleaned=$((process_cleaned + 1))
				fi
				;;
			running | dispatched)
				# Active task - check if PID is actually dead (stale)
				if ! kill -0 "$pid" 2>/dev/null; then
					if [[ "$dry_run" == "true" ]]; then
						log_info "  [dry-run] Would remove stale PID for active task $task_id_from_pid"
					else
						rm -f "$pid_file"
						log_warn "  Removed stale PID file for $task_id_from_pid (task still $task_state but process dead)"
					fi
				fi
				;;
			*)
				# Unknown task or not in DB - clean up if process is dead
				if ! kill -0 "$pid" 2>/dev/null; then
					if [[ "$dry_run" == "true" ]]; then
						log_info "  [dry-run] Would remove orphaned PID: $pid_file"
					else
						rm -f "$pid_file"
					fi
				fi
				;;
			esac
		done
	fi

	# Prune stale registry entries (t189)
	if [[ "$dry_run" == "false" ]]; then
		prune_worktree_registry
	fi

	# Auto-clean safe-to-drop stashes (t1005)
	local stash_cleaned=0
	if [[ -f "${SCRIPT_DIR}/stash-audit-helper.sh" ]]; then
		# Get list of repos from tasks
		local repos
		repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks WHERE repo IS NOT NULL AND repo != '';" 2>/dev/null || echo "")

		if [[ -n "$repos" ]]; then
			while IFS= read -r repo_path; do
				[[ -z "$repo_path" ]] && continue
				[[ ! -d "$repo_path" ]] && continue

				# Count stashes before cleanup
				local before_count
				before_count=$(cd "$repo_path" && git stash list 2>/dev/null | wc -l || echo "0")

				if [[ "$dry_run" == "true" ]]; then
					log_info "  [dry-run] Would audit stashes in: $repo_path"
				else
					# Run auto-clean (non-interactive)
					"${SCRIPT_DIR}/stash-audit-helper.sh" auto-clean --repo "$repo_path" >/dev/null 2>&1 || true

					# Count stashes after cleanup
					local after_count
					after_count=$(cd "$repo_path" && git stash list 2>/dev/null | wc -l || echo "0")

					local dropped=$((before_count - after_count))
					if [[ "$dropped" -gt 0 ]]; then
						stash_cleaned=$((stash_cleaned + dropped))
						log_info "  Cleaned $dropped stash(es) in: $repo_path"
					fi
				fi
			done <<<"$repos"
		fi
	fi

	if [[ "$dry_run" == "false" ]]; then
		if [[ "$stash_cleaned" -gt 0 ]]; then
			log_success "Cleaned up $cleaned worktrees, $process_cleaned worker processes, $stash_cleaned stashes"
		else
			log_success "Cleaned up $cleaned worktrees, $process_cleaned worker processes"
		fi
	fi

	return 0
}

#######################################
# Clean up worktree after successful merge
# Returns to main repo, pulls, removes worktree
# t240: Added verification logging and DB cleanup for missing worktrees
#######################################
cleanup_after_merge() {
	local task_id="$1"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT worktree, repo, branch FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		return 0
	fi

	local tworktree trepo tbranch
	IFS='|' read -r tworktree trepo tbranch <<<"$task_row"

	# Clean up worktree
	if [[ -n "$tworktree" && -d "$tworktree" ]]; then
		log_info "Cleaning up worktree for $task_id: $tworktree"
		cleanup_task_worktree "$tworktree" "$trepo"

		# t240: Verify cleanup succeeded
		if [[ -d "$tworktree" ]]; then
			log_warn "Worktree cleanup incomplete for $task_id: $tworktree still exists (t240)"
		else
			log_info "Worktree removed successfully for $task_id: $tworktree"
		fi

		# Clear worktree field in DB
		db "$SUPERVISOR_DB" "
            UPDATE tasks SET worktree = NULL WHERE id = '$escaped_id';
        "
	elif [[ -n "$tworktree" && ! -d "$tworktree" ]]; then
		# t240: Worktree path in DB but directory already gone — clean up DB + registry
		log_info "Worktree already removed for $task_id: $tworktree (cleaning DB reference)"
		unregister_worktree "$tworktree"
		db "$SUPERVISOR_DB" "
            UPDATE tasks SET worktree = NULL WHERE id = '$escaped_id';
        "
	fi

	# Delete the remote branch (already merged)
	if [[ -n "$tbranch" ]]; then
		git -C "$trepo" push origin --delete "$tbranch" 2>>"$SUPERVISOR_LOG" || true
		git -C "$trepo" branch -d "$tbranch" 2>>"$SUPERVISOR_LOG" || true
		log_info "Cleaned up branch: $tbranch"

		# t240: Clear branch field in DB after cleanup
		db "$SUPERVISOR_DB" "
            UPDATE tasks SET branch = NULL WHERE id = '$escaped_id';
        "
	fi

	# Prune worktrees
	if command -v wt &>/dev/null; then
		wt prune -C "$trepo" 2>>"$SUPERVISOR_LOG" || true
	else
		git -C "$trepo" worktree prune 2>>"$SUPERVISOR_LOG" || true
	fi

	return 0
}
