#!/usr/bin/env bash
# ai-lifecycle.sh - AI-driven task lifecycle engine
#
# Replaces hardcoded bash heuristics with intelligence-first decision making.
# For each active task: gathers real-world state, asks AI "what's the next
# action?", executes it, and updates TODO tags so users always know what's
# happening.
#
# Design principle: AI decides, bash executes. No case statements for
# lifecycle decisions. The AI sees the same state a human would and picks
# the obvious next step.
#
# Used by: pulse.sh Phase 3 (replaces process_post_pr_lifecycle)
# Depends on: dispatch.sh (resolve_ai_cli, resolve_model)
#             todo-sync.sh (commit_and_push_todo)
#             deploy.sh (merge_task_pr, rebase_sibling_pr, check_pr_status,
#                        run_postflight_for_task, run_deploy_for_task,
#                        cleanup_after_merge, rebase_sibling_prs_after_merge)
# Sourced by: supervisor-helper.sh (set -euo pipefail inherited)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SUPERVISOR_DIR, SCRIPT_DIR, REPO_PATH
#   db(), log_info(), log_warn(), log_error(), log_success(), sql_escape()
#   cmd_transition(), parse_pr_url()

# ── Status Tag Vocabulary ──────────────────────────────────────────────
#
# These tags appear on TODO.md task lines as status:<value> so users can
# see at a glance what the supervisor is doing with each task.
#
# Lifecycle states:
#   status:dispatched       — Worker session launched
#   status:running          — Worker actively coding
#   status:evaluating       — Checking worker output
#   status:pr-open          — PR created, awaiting CI
#   status:ci-running       — CI checks in progress
#   status:ci-passed        — CI green, ready to merge
#   status:merging          — Merge in progress
#   status:merged           — PR merged to main
#   status:deploying        — Running deploy/setup
#   status:deployed         — Live on main, awaiting verification
#   status:verified         — Post-merge verification passed
#
# Action states (transient — what the supervisor is doing right now):
#   status:updating-branch  — Running gh pr update-branch (GitHub API)
#   status:rebasing         — Running git rebase onto main
#   status:resolving-conflicts — AI resolving merge conflicts
#   status:reviewing-threads — Triaging PR review comments
#
# Problem states (visible to user — needs attention or patience):
#   status:behind-main      — PR needs update, supervisor will handle
#   status:has-conflicts    — Merge conflicts, AI attempting resolution
#   status:ci-failed        — CI checks failed, investigating
#   status:changes-requested — Human reviewer requested changes
#   status:blocked:<reason> — Cannot proceed, reason given
#
# ── End Vocabulary ─────────────────────────────────────────────────────

# Log directory for AI lifecycle decisions
AI_LIFECYCLE_LOG_DIR="${AI_LIFECYCLE_LOG_DIR:-$HOME/.aidevops/logs/ai-lifecycle}"

# Timeout for AI decision calls (seconds). These are fast, focused calls.
AI_LIFECYCLE_DECISION_TIMEOUT="${AI_LIFECYCLE_DECISION_TIMEOUT:-60}"

# Model tier for lifecycle decisions. Sonnet is sufficient — these are
# bounded, factual decisions, not creative reasoning.
AI_LIFECYCLE_MODEL_TIER="${AI_LIFECYCLE_MODEL_TIER:-sonnet}"

#######################################
# Update the status: tag on a task's TODO.md line
# This is the primary communication channel to users.
#
# Arguments:
#   $1 - task ID
#   $2 - new status value (e.g., "ci-running", "merging", "behind-main")
#   $3 - (optional) repo path override
# Returns:
#   0 on success, 1 on failure (non-fatal — status tags are best-effort)
#######################################
update_task_status_tag() {
	local task_id="$1"
	local new_status="$2"
	local repo_override="${3:-}"

	local trepo="$repo_override"
	if [[ -z "$trepo" ]]; then
		local escaped_id
		escaped_id=$(sql_escape "$task_id")
		trepo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	fi

	if [[ -z "$trepo" ]]; then
		log_warn "update_task_status_tag: no repo for $task_id"
		return 1
	fi

	local todo_file="$trepo/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		return 1
	fi

	# Find the task line (open checkbox only — completed tasks don't get status updates)
	local line_num
	line_num=$(grep -nE "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file" | head -1 | cut -d: -f1)
	if [[ -z "$line_num" ]]; then
		return 0 # Task not found as open — may already be completed
	fi

	local task_line
	task_line=$(sed -n "${line_num}p" "$todo_file")

	# Remove existing status: tag if present
	local updated_line
	updated_line=$(printf '%s' "$task_line" | sed -E 's/ status:[^ ]*//')

	# Append new status tag
	updated_line="${updated_line} status:${new_status}"

	# Replace the line in-place
	sed_inplace "${line_num}s|.*|${updated_line}|" "$todo_file"

	return 0
}

#######################################
# Batch-commit all status tag updates for a repo
# Called once per pulse after all tasks are processed, not per-task.
#
# Arguments:
#   $1 - repo path
# Returns:
#   0 on success
#######################################
commit_status_tag_updates() {
	local repo_path="$1"

	if [[ ! -f "$repo_path/TODO.md" ]]; then
		return 0
	fi

	# Check if TODO.md has uncommitted changes
	if ! git -C "$repo_path" diff --quiet -- TODO.md 2>/dev/null; then
		if declare -f commit_and_push_todo &>/dev/null; then
			commit_and_push_todo "$repo_path" "chore: update task status tags" >>"${SUPERVISOR_LOG:-/dev/null}" 2>&1 || {
				log_warn "commit_status_tag_updates: commit failed for $repo_path (non-fatal)"
				return 1
			}
		fi
	fi

	return 0
}

#######################################
# Gather the real-world state for a task
# Returns a structured text snapshot that the AI can reason about.
#
# Arguments:
#   $1 - task ID
# Outputs:
#   State snapshot on stdout
# Returns:
#   0 on success, 1 if task not found
#######################################
gather_task_state() {
	local task_id="$1"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# DB state
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, status, pr_url, repo, branch, worktree, error,
		       rebase_attempts, retries, max_retries, model
		FROM tasks WHERE id = '$escaped_id';
	" 2>/dev/null || echo "")

	if [[ -z "$task_row" ]]; then
		return 1
	fi

	local tid tstatus tpr trepo tbranch tworktree terror trebase tretries tmax_retries tmodel
	IFS='|' read -r tid tstatus tpr trepo tbranch tworktree terror trebase tretries tmax_retries tmodel <<<"$task_row"

	# GitHub PR state (if PR exists)
	local pr_state="" pr_merge_state="" pr_ci_status="" pr_review_decision="" pr_number="" pr_repo_slug=""
	if [[ -n "$tpr" && "$tpr" != "no_pr" && "$tpr" != "task_only" && "$tpr" != "verified_complete" ]]; then
		local parsed_pr
		parsed_pr=$(parse_pr_url "$tpr" 2>/dev/null) || parsed_pr=""
		if [[ -n "$parsed_pr" ]]; then
			pr_repo_slug="${parsed_pr%%|*}"
			pr_number="${parsed_pr##*|}"

			if [[ -n "$pr_number" && -n "$pr_repo_slug" ]] && command -v gh &>/dev/null; then
				local pr_json
				pr_json=$(gh pr view "$pr_number" --repo "$pr_repo_slug" \
					--json state,isDraft,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup \
					2>/dev/null || echo "")

				if [[ -n "$pr_json" ]]; then
					pr_state=$(printf '%s' "$pr_json" | jq -r '.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
					pr_merge_state=$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

					# Retry once if UNKNOWN (GitHub lazy-loads mergeStateStatus)
					if [[ "$pr_merge_state" == "UNKNOWN" ]]; then
						sleep 2
						local retry_json
						retry_json=$(gh pr view "$pr_number" --repo "$pr_repo_slug" \
							--json mergeable,mergeStateStatus 2>/dev/null || echo "")
						if [[ -n "$retry_json" ]]; then
							pr_merge_state=$(printf '%s' "$retry_json" | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
						fi
					fi

					pr_review_decision=$(printf '%s' "$pr_json" | jq -r '.reviewDecision // "NONE"' 2>/dev/null || echo "NONE")

					# Summarize CI status
					local check_rollup
					check_rollup=$(printf '%s' "$pr_json" | jq -r '.statusCheckRollup // []' 2>/dev/null || echo "[]")
					if [[ "$check_rollup" != "[]" && "$check_rollup" != "null" ]]; then
						local pending failed passed
						pending=$(printf '%s' "$check_rollup" | jq '[.[] | select(.status == "IN_PROGRESS" or .status == "QUEUED" or .status == "PENDING")] | length' 2>/dev/null || echo "0")
						failed=$(printf '%s' "$check_rollup" | jq '[.[] | select((.conclusion | test("FAILURE|TIMED_OUT|ACTION_REQUIRED")) or .state == "FAILURE" or .state == "ERROR")] | length' 2>/dev/null || echo "0")
						passed=$(printf '%s' "$check_rollup" | jq '[.[] | select(.conclusion == "SUCCESS" or .state == "SUCCESS")] | length' 2>/dev/null || echo "0")
						pr_ci_status="passed:${passed} failed:${failed} pending:${pending}"
					else
						pr_ci_status="no-checks"
					fi

					local is_draft
					is_draft=$(printf '%s' "$pr_json" | jq -r '.isDraft // false' 2>/dev/null || echo "false")
					if [[ "$is_draft" == "true" ]]; then
						pr_state="DRAFT"
					fi
				fi
			fi
		fi
	fi

	# Worktree state
	local worktree_exists="false"
	if [[ -n "$tworktree" && -d "$tworktree" ]]; then
		worktree_exists="true"
	fi

	# Recent state transitions (last 5)
	local recent_transitions
	recent_transitions=$(db "$SUPERVISOR_DB" "
		SELECT from_state || ' -> ' || to_state || ' (' || reason || ') at ' || timestamp
		FROM state_log WHERE task_id = '$escaped_id'
		ORDER BY timestamp DESC LIMIT 5;
	" 2>/dev/null || echo "none")

	# Output structured state
	cat <<STATE
TASK: $tid
DB_STATUS: $tstatus
ERROR: ${terror:-none}
PR_URL: ${tpr:-none}
PR_NUMBER: ${pr_number:-none}
PR_REPO: ${pr_repo_slug:-none}
PR_STATE: ${pr_state:-none}
PR_MERGE_STATE: ${pr_merge_state:-none}
PR_CI: ${pr_ci_status:-unknown}
PR_REVIEW: ${pr_review_decision:-none}
BRANCH: ${tbranch:-none}
WORKTREE: ${tworktree:-none}
WORKTREE_EXISTS: $worktree_exists
REPO: ${trepo:-none}
REBASE_ATTEMPTS: ${trebase:-0}
RETRIES: ${tretries:-0}/${tmax_retries:-3}
MODEL: ${tmodel:-unknown}
RECENT_TRANSITIONS:
$recent_transitions
STATE

	return 0
}

#######################################
# Ask AI for the next action on a task
# This is a focused, bounded call — not open-ended reasoning.
#
# Arguments:
#   $1 - task state snapshot (from gather_task_state)
# Outputs:
#   JSON object with action and reasoning on stdout
# Returns:
#   0 on success, 1 on failure
#######################################
decide_next_action() {
	local task_state="$1"

	# Resolve AI CLI and model
	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_error "ai-lifecycle: no AI CLI available"
		return 1
	}

	local ai_model
	ai_model=$(resolve_model "$AI_LIFECYCLE_MODEL_TIER" "$ai_cli" 2>/dev/null) || {
		log_error "ai-lifecycle: no model available"
		return 1
	}

	local prompt
	prompt="You are a DevOps engineer looking at a task's current state. Decide the single next action to move it forward.

$task_state

AVAILABLE ACTIONS (pick exactly one):
- merge_pr: Squash-merge the PR (use when CI passed, no conflicts, reviews OK)
- update_branch: Update PR branch via GitHub API (use when PR is BEHIND main, no conflicts)
- rebase_branch: Git rebase onto main (use when update_branch isn't available or failed)
- promote_draft: Convert draft PR to ready (use when PR is DRAFT and worker is done)
- close_pr: Close the PR without merging (use when PR is obsolete or superseded)
- retry_ci: Re-request CI checks (use when CI failed transiently)
- wait: Do nothing this cycle (use when CI is running, or need to wait for something)
- deploy: Run post-merge deployment (use when PR is already merged)
- mark_deployed: Mark task as deployed without running deploy (non-deployable repos)
- dismiss_reviews: Dismiss bot reviews blocking merge
- escalate: Dispatch an AI worker to fix the issue (use as last resort for complex conflicts)

RULES:
- Pick the SIMPLEST action that makes progress
- If PR is BEHIND with no conflicts: update_branch (not rebase)
- If PR is CLEAN or UNSTABLE with CI passed: merge_pr
- If PR is already MERGED: deploy
- If CI is still running: wait
- Never pick escalate unless simpler actions have been tried and failed
- If the task has no PR and status is complete: mark_deployed

Respond with ONLY a JSON object, no markdown fencing:
{\"action\": \"<action_name>\", \"reason\": \"<one line explanation>\", \"status_tag\": \"<status tag for TODO.md>\"}"

	local ai_result=""
	local ai_timeout="$AI_LIFECYCLE_DECISION_TIMEOUT"

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout "$ai_timeout" opencode run \
			-m "$ai_model" \
			--format default \
			--title "lifecycle-decision-$$" \
			"$prompt" 2>/dev/null || echo "")
		# Strip ANSI codes
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		local claude_model="${ai_model#*/}"
		ai_result=$(portable_timeout "$ai_timeout" claude \
			-p "$prompt" \
			--model "$claude_model" \
			--output-format text 2>/dev/null || echo "")
	fi

	if [[ -z "$ai_result" ]]; then
		log_warn "ai-lifecycle: empty response from AI"
		return 1
	fi

	# Extract JSON from response (may have preamble/postamble)
	local json_block
	json_block=$(printf '%s' "$ai_result" | grep -oE '\{[^}]+\}' | head -1)

	if [[ -z "$json_block" ]]; then
		log_warn "ai-lifecycle: could not parse JSON from response"
		log_warn "ai-lifecycle: raw response: $(printf '%s' "$ai_result" | head -c 200)"
		return 1
	fi

	# Validate required fields
	local action
	action=$(printf '%s' "$json_block" | jq -r '.action // ""' 2>/dev/null || echo "")
	if [[ -z "$action" ]]; then
		log_warn "ai-lifecycle: no action field in response"
		return 1
	fi

	printf '%s' "$json_block"
	return 0
}

#######################################
# Execute a lifecycle action decided by the AI
#
# Arguments:
#   $1 - task ID
#   $2 - action name (from decide_next_action)
#   $3 - task repo path
# Returns:
#   0 on success, 1 on failure
#######################################
execute_lifecycle_action() {
	local task_id="$1"
	local action="$2"
	local repo_path="$3"

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Get PR details from DB
	local tpr tbranch tworktree
	tpr=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	tbranch=$(db "$SUPERVISOR_DB" "SELECT branch FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	tworktree=$(db "$SUPERVISOR_DB" "SELECT worktree FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

	local parsed_pr pr_number pr_repo_slug
	if [[ -n "$tpr" && "$tpr" != "no_pr" ]]; then
		parsed_pr=$(parse_pr_url "$tpr" 2>/dev/null) || parsed_pr=""
		if [[ -n "$parsed_pr" ]]; then
			pr_repo_slug="${parsed_pr%%|*}"
			pr_number="${parsed_pr##*|}"
		fi
	fi

	case "$action" in
	merge_pr)
		log_info "ai-lifecycle: merging PR for $task_id"
		update_task_status_tag "$task_id" "merging" "$repo_path"

		# Transition through the state machine
		cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true

		if merge_task_pr "$task_id" 2>>"$SUPERVISOR_LOG"; then
			cmd_transition "$task_id" "merged" 2>>"$SUPERVISOR_LOG" || true
			update_task_status_tag "$task_id" "merged" "$repo_path"

			# Post-merge: pull main, rebase siblings, deploy
			git -C "$repo_path" pull --rebase origin main 2>>"$SUPERVISOR_LOG" || true
			rebase_sibling_prs_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || true

			# Run postflight + deploy
			run_postflight_for_task "$task_id" "$repo_path" 2>>"$SUPERVISOR_LOG" || true
			update_task_status_tag "$task_id" "deploying" "$repo_path"
			cmd_transition "$task_id" "deploying" 2>>"$SUPERVISOR_LOG" || true

			run_deploy_for_task "$task_id" "$repo_path" 2>>"$SUPERVISOR_LOG" || true
			cmd_transition "$task_id" "deployed" 2>>"$SUPERVISOR_LOG" || true
			update_task_status_tag "$task_id" "deployed" "$repo_path"

			# Clean up worktree
			cleanup_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || true

			# Update TODO.md completion
			update_todo_on_complete "$task_id" 2>>"$SUPERVISOR_LOG" || true

			log_success "ai-lifecycle: $task_id merged and deployed"
			return 0
		else
			log_warn "ai-lifecycle: merge failed for $task_id"
			update_task_status_tag "$task_id" "blocked:merge-failed" "$repo_path"
			cmd_transition "$task_id" "blocked" --error "Merge failed" 2>>"$SUPERVISOR_LOG" || true
			return 1
		fi
		;;

	update_branch)
		log_info "ai-lifecycle: updating PR branch for $task_id via GitHub API"
		update_task_status_tag "$task_id" "updating-branch" "$repo_path"

		if [[ -z "$pr_number" || -z "$pr_repo_slug" ]]; then
			log_warn "ai-lifecycle: no PR number/repo for update_branch on $task_id"
			return 1
		fi

		# Use GitHub API to update the branch (no local git needed)
		if gh api "repos/${pr_repo_slug}/pulls/${pr_number}/update-branch" \
			-X PUT -f expected_head_sha="" 2>>"$SUPERVISOR_LOG"; then
			log_success "ai-lifecycle: branch updated for $task_id — CI will re-run"
			update_task_status_tag "$task_id" "ci-running" "$repo_path"
			# Reset rebase counter since we used a different strategy
			db "$SUPERVISOR_DB" "UPDATE tasks SET rebase_attempts = 0 WHERE id = '$escaped_id';" 2>/dev/null || true
			return 0
		else
			log_warn "ai-lifecycle: GitHub API update-branch failed for $task_id — will try rebase next cycle"
			update_task_status_tag "$task_id" "behind-main" "$repo_path"
			return 1
		fi
		;;

	rebase_branch)
		log_info "ai-lifecycle: rebasing branch for $task_id"
		update_task_status_tag "$task_id" "rebasing" "$repo_path"

		if rebase_sibling_pr "$task_id" 2>>"$SUPERVISOR_LOG"; then
			log_success "ai-lifecycle: rebase succeeded for $task_id"
			update_task_status_tag "$task_id" "ci-running" "$repo_path"
			# Increment rebase counter
			local current_attempts
			current_attempts=$(db "$SUPERVISOR_DB" "SELECT rebase_attempts FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "0")
			db "$SUPERVISOR_DB" "UPDATE tasks SET rebase_attempts = $((current_attempts + 1)) WHERE id = '$escaped_id';" 2>/dev/null || true
			return 0
		else
			log_warn "ai-lifecycle: rebase failed for $task_id"
			update_task_status_tag "$task_id" "has-conflicts" "$repo_path"
			return 1
		fi
		;;

	promote_draft)
		log_info "ai-lifecycle: promoting draft PR for $task_id"
		update_task_status_tag "$task_id" "pr-open" "$repo_path"

		if [[ -n "$pr_number" && -n "$pr_repo_slug" ]]; then
			if gh pr ready "$pr_number" --repo "$pr_repo_slug" 2>>"$SUPERVISOR_LOG"; then
				log_success "ai-lifecycle: draft promoted for $task_id"
				update_task_status_tag "$task_id" "ci-running" "$repo_path"
				return 0
			fi
		fi
		log_warn "ai-lifecycle: draft promotion failed for $task_id"
		return 1
		;;

	close_pr)
		log_info "ai-lifecycle: closing PR for $task_id (obsolete/superseded)"
		if [[ -n "$pr_number" && -n "$pr_repo_slug" ]]; then
			gh pr close "$pr_number" --repo "$pr_repo_slug" \
				--comment "Closed by AI supervisor: PR obsolete or superseded" \
				2>>"$SUPERVISOR_LOG" || true
		fi
		cmd_transition "$task_id" "cancelled" --error "PR closed (obsolete)" 2>>"$SUPERVISOR_LOG" || true
		update_task_status_tag "$task_id" "cancelled" "$repo_path"
		cleanup_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || true
		return 0
		;;

	retry_ci)
		log_info "ai-lifecycle: retrying CI for $task_id"
		update_task_status_tag "$task_id" "ci-running" "$repo_path"
		# Push an empty commit to re-trigger CI, or use gh api
		if [[ -n "$pr_repo_slug" && -n "$tbranch" ]]; then
			# Get the latest commit SHA on the PR branch
			local head_sha
			head_sha=$(gh api "repos/${pr_repo_slug}/pulls/${pr_number}" --jq '.head.sha' 2>/dev/null || echo "")
			if [[ -n "$head_sha" ]]; then
				# Re-request check suites
				gh api "repos/${pr_repo_slug}/check-suites" \
					-X POST -f head_sha="$head_sha" 2>>"$SUPERVISOR_LOG" || true
				log_info "ai-lifecycle: CI re-requested for $task_id"
				return 0
			fi
		fi
		return 1
		;;

	wait)
		log_info "ai-lifecycle: waiting for $task_id (no action needed this cycle)"
		# Status tag already set by gather phase — don't overwrite
		return 0
		;;

	deploy)
		log_info "ai-lifecycle: deploying $task_id (PR already merged)"
		update_task_status_tag "$task_id" "deploying" "$repo_path"

		# Ensure we're on latest main
		git -C "$repo_path" pull --rebase origin main 2>>"$SUPERVISOR_LOG" || true

		# Transition through merge states if not already there
		local current_status
		current_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
		case "$current_status" in
		complete | pr_review)
			cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
			cmd_transition "$task_id" "merged" 2>>"$SUPERVISOR_LOG" || true
			cmd_transition "$task_id" "deploying" 2>>"$SUPERVISOR_LOG" || true
			;;
		merged)
			cmd_transition "$task_id" "deploying" 2>>"$SUPERVISOR_LOG" || true
			;;
		blocked)
			# Blocked but PR is merged — advance through states
			db "$SUPERVISOR_DB" "UPDATE tasks SET status = 'deploying', error = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = '$escaped_id';" 2>/dev/null || true
			;;
		esac

		run_deploy_for_task "$task_id" "$repo_path" 2>>"$SUPERVISOR_LOG" || true
		cmd_transition "$task_id" "deployed" 2>>"$SUPERVISOR_LOG" || true
		update_task_status_tag "$task_id" "deployed" "$repo_path"
		cleanup_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || true
		update_todo_on_complete "$task_id" 2>>"$SUPERVISOR_LOG" || true

		log_success "ai-lifecycle: $task_id deployed"
		return 0
		;;

	mark_deployed)
		log_info "ai-lifecycle: marking $task_id deployed (no deploy needed)"
		update_task_status_tag "$task_id" "deployed" "$repo_path"

		local current_status
		current_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
		if [[ "$current_status" == "complete" ]]; then
			cmd_transition "$task_id" "deployed" 2>>"$SUPERVISOR_LOG" || true
		elif [[ "$current_status" == "blocked" ]]; then
			db "$SUPERVISOR_DB" "UPDATE tasks SET status = 'deployed', error = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = '$escaped_id';" 2>/dev/null || true
		fi

		cleanup_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || true
		update_todo_on_complete "$task_id" 2>>"$SUPERVISOR_LOG" || true

		log_success "ai-lifecycle: $task_id marked deployed"
		return 0
		;;

	dismiss_reviews)
		log_info "ai-lifecycle: dismissing bot reviews for $task_id"
		update_task_status_tag "$task_id" "reviewing-threads" "$repo_path"

		if [[ -n "$pr_number" && -n "$pr_repo_slug" ]] && declare -f dismiss_bot_reviews &>/dev/null; then
			dismiss_bot_reviews "$pr_number" "$pr_repo_slug" 2>>"$SUPERVISOR_LOG" || true
			log_info "ai-lifecycle: bot reviews dismissed for $task_id"
			return 0
		fi
		return 1
		;;

	escalate)
		log_info "ai-lifecycle: escalating $task_id to opus worker"
		update_task_status_tag "$task_id" "resolving-conflicts" "$repo_path"

		# Dispatch an opus worker to fix the issue
		local esc_ai_cli
		esc_ai_cli=$(resolve_ai_cli 2>/dev/null || echo "")
		if [[ -z "$esc_ai_cli" ]]; then
			log_warn "ai-lifecycle: no AI CLI for escalation"
			return 1
		fi

		local esc_model
		esc_model=$(resolve_model "opus" "$esc_ai_cli" 2>/dev/null || echo "")

		local esc_workdir="${tworktree:-$repo_path}"
		local esc_error
		esc_error=$(db "$SUPERVISOR_DB" "SELECT error FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "unknown")
		local esc_prompt
		esc_prompt="You are fixing a stuck PR for task $task_id.

PR: ${tpr:-none}
Branch: ${tbranch:-none}
Error: $esc_error

Steps:
1. cd to $esc_workdir
2. git fetch origin main
3. Abort any stale rebase: git rebase --abort (ignore errors)
4. git rebase origin/main
5. If conflicts: resolve them intelligently, git add, git rebase --continue
6. git push --force-with-lease origin $tbranch
7. Verify: gh pr view $tpr --json mergeStateStatus
8. If clean: gh pr merge $tpr --squash
9. Output ONLY: RESOLVED_MERGED if merged, RESOLVED_REBASED if rebased, RESOLVED_FAILED:<reason> if failed"

		local esc_log
		esc_log="${SUPERVISOR_DIR}/logs/escalation-${task_id}-$(date +%Y%m%d-%H%M%S).log"
		mkdir -p "$SUPERVISOR_DIR/logs" 2>/dev/null || true

		if [[ "$esc_ai_cli" == "opencode" ]]; then
			(cd "$esc_workdir" && opencode run \
				${esc_model:+-m "$esc_model"} \
				--format json \
				--title "escalation-${task_id}" \
				"$esc_prompt" \
				>"$esc_log" 2>&1) &
		else
			local claude_model="${esc_model#*/}"
			(cd "$esc_workdir" && claude \
				-p "$esc_prompt" \
				${claude_model:+--model "$claude_model"} \
				>"$esc_log" 2>&1) &
		fi
		local esc_pid=$!

		# Record in DB
		db "$SUPERVISOR_DB" "UPDATE tasks SET
			status = 'running',
			error = 'Escalation: AI worker resolving conflicts (PID $esc_pid)',
			worker_pid = $esc_pid,
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = '$escaped_id';" 2>/dev/null || true

		# Create PID file for health monitoring
		mkdir -p "$SUPERVISOR_DIR/pids" 2>/dev/null || true
		echo "$esc_pid" >"$SUPERVISOR_DIR/pids/${task_id}.pid"

		log_success "ai-lifecycle: escalation worker dispatched for $task_id (PID $esc_pid)"
		return 0
		;;

	*)
		log_warn "ai-lifecycle: unknown action '$action' for $task_id"
		return 1
		;;
	esac
}

#######################################
# Process a single task through the AI lifecycle engine
# This is the main entry point — replaces cmd_pr_lifecycle for a single task.
#
# Arguments:
#   $1 - task ID
# Returns:
#   0 on success (action taken or wait), 1 on failure
#######################################
process_task_lifecycle() {
	local task_id="$1"

	mkdir -p "$AI_LIFECYCLE_LOG_DIR" 2>/dev/null || true

	# Step 1: Gather real-world state
	local task_state
	task_state=$(gather_task_state "$task_id") || {
		log_warn "ai-lifecycle: could not gather state for $task_id"
		return 1
	}

	# Step 2: Fast-path deterministic decisions (no AI needed)
	# These are unambiguous — no judgment required.
	local fast_action=""
	fast_action=$(fast_path_decision "$task_state" "$task_id")

	if [[ -n "$fast_action" ]]; then
		local fp_action fp_reason fp_status_tag
		fp_action=$(printf '%s' "$fast_action" | jq -r '.action' 2>/dev/null || echo "")
		fp_reason=$(printf '%s' "$fast_action" | jq -r '.reason' 2>/dev/null || echo "")
		fp_status_tag=$(printf '%s' "$fast_action" | jq -r '.status_tag' 2>/dev/null || echo "")

		log_info "ai-lifecycle: $task_id — fast-path: $fp_action ($fp_reason)"

		if [[ -n "$fp_status_tag" ]]; then
			local trepo
			trepo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
			update_task_status_tag "$task_id" "$fp_status_tag" "$trepo"
		fi

		local trepo
		trepo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
		execute_lifecycle_action "$task_id" "$fp_action" "$trepo"
		return $?
	fi

	# Step 3: Ask AI for the decision
	local decision
	decision=$(decide_next_action "$task_state") || {
		log_warn "ai-lifecycle: AI decision failed for $task_id — defaulting to wait"
		return 0
	}

	local action reason status_tag
	action=$(printf '%s' "$decision" | jq -r '.action' 2>/dev/null || echo "wait")
	reason=$(printf '%s' "$decision" | jq -r '.reason' 2>/dev/null || echo "")
	status_tag=$(printf '%s' "$decision" | jq -r '.status_tag' 2>/dev/null || echo "")

	# Log the decision
	local timestamp
	timestamp=$(date -u '+%Y%m%d-%H%M%S')
	{
		echo "# Lifecycle Decision: $task_id"
		echo "Timestamp: $timestamp"
		echo "Action: $action"
		echo "Reason: $reason"
		echo "Status tag: $status_tag"
		echo ""
		echo "## Task State"
		echo "$task_state"
	} >"$AI_LIFECYCLE_LOG_DIR/decision-${task_id}-${timestamp}.md" 2>/dev/null || true

	log_info "ai-lifecycle: $task_id — AI decided: $action ($reason)"

	# Step 4: Update status tag
	if [[ -n "$status_tag" ]]; then
		local trepo
		trepo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
		update_task_status_tag "$task_id" "$status_tag" "$trepo"
	fi

	# Step 5: Execute the action
	local trepo
	trepo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
	execute_lifecycle_action "$task_id" "$action" "$trepo"
	return $?
}

#######################################
# Fast-path deterministic decisions
# These don't need AI — the answer is unambiguous from the state.
#
# Arguments:
#   $1 - task state snapshot
#   $2 - task ID
# Outputs:
#   JSON action object if fast-path applies, empty string otherwise
# Returns:
#   0 if fast-path found, 1 if AI needed
#######################################
fast_path_decision() {
	local task_state="$1"
	local task_id="$2"

	# Extract key fields from state snapshot
	local db_status pr_state pr_merge_state pr_ci pr_url
	db_status=$(printf '%s' "$task_state" | grep '^DB_STATUS:' | cut -d' ' -f2)
	pr_state=$(printf '%s' "$task_state" | grep '^PR_STATE:' | cut -d' ' -f2)
	pr_merge_state=$(printf '%s' "$task_state" | grep '^PR_MERGE_STATE:' | cut -d' ' -f2)
	pr_ci=$(printf '%s' "$task_state" | grep '^PR_CI:' | cut -d' ' -f2-)
	pr_url=$(printf '%s' "$task_state" | grep '^PR_URL:' | cut -d' ' -f2)

	# PR already merged → deploy
	if [[ "$pr_state" == "MERGED" ]]; then
		echo '{"action":"deploy","reason":"PR already merged","status_tag":"deploying"}'
		return 0
	fi

	# No PR and task is complete → mark deployed
	if [[ "$db_status" == "complete" && ("$pr_url" == "none" || "$pr_url" == "no_pr" || "$pr_url" == "task_only" || "$pr_url" == "verified_complete") ]]; then
		echo '{"action":"mark_deployed","reason":"No PR, task complete","status_tag":"deployed"}'
		return 0
	fi

	# PR is CLEAN (all checks passed, no conflicts) → merge
	if [[ "$pr_merge_state" == "CLEAN" ]]; then
		echo '{"action":"merge_pr","reason":"CI passed, PR clean","status_tag":"merging"}'
		return 0
	fi

	# PR is UNSTABLE (non-required checks failed) → merge (safe)
	if [[ "$pr_merge_state" == "UNSTABLE" ]]; then
		echo '{"action":"merge_pr","reason":"Required checks passed (non-required failed)","status_tag":"merging"}'
		return 0
	fi

	# PR is BEHIND (just needs branch update, no conflicts) → update branch
	if [[ "$pr_merge_state" == "BEHIND" ]]; then
		echo '{"action":"update_branch","reason":"PR behind main, no conflicts","status_tag":"updating-branch"}'
		return 0
	fi

	# PR is DRAFT → promote
	if [[ "$pr_state" == "DRAFT" ]]; then
		echo '{"action":"promote_draft","reason":"Draft PR ready for review","status_tag":"pr-open"}'
		return 0
	fi

	# CI still running → wait
	if [[ "$pr_ci" == *"pending:"* ]]; then
		local pending_count
		pending_count=$(printf '%s' "$pr_ci" | grep -oE 'pending:[0-9]+' | cut -d: -f2)
		if [[ "${pending_count:-0}" -gt 0 ]]; then
			echo '{"action":"wait","reason":"CI checks still running","status_tag":"ci-running"}'
			return 0
		fi
	fi

	# PR closed without merge → task needs re-evaluation (let AI decide)
	# DIRTY (conflicts) → let AI decide (rebase vs escalate)
	# BLOCKED with CI failures → let AI decide
	# Everything else → AI decides

	return 1
}

#######################################
# Process all active tasks through the AI lifecycle engine
# This replaces process_post_pr_lifecycle in pulse.sh Phase 3.
#
# Arguments:
#   $1 - (optional) batch ID filter
# Returns:
#   0 on success
#######################################
process_ai_lifecycle() {
	local batch_id="${1:-}"

	ensure_db

	# Find tasks eligible for lifecycle processing
	local where_clause="t.status IN ('complete', 'pr_review', 'review_triage', 'merging', 'merged', 'deploying', 'blocked')"
	if [[ -n "$batch_id" ]]; then
		where_clause="$where_clause AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$(sql_escape "$batch_id")')"
	fi

	# Include blocked tasks — the AI can decide how to unblock them
	local eligible_tasks
	eligible_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT t.id, t.status, t.pr_url, t.repo FROM tasks t
		WHERE $where_clause
		ORDER BY
			CASE t.status
				WHEN 'merging' THEN 1
				WHEN 'merged' THEN 2
				WHEN 'deploying' THEN 3
				WHEN 'review_triage' THEN 4
				WHEN 'pr_review' THEN 5
				WHEN 'complete' THEN 6
				WHEN 'blocked' THEN 7
			END,
			t.updated_at ASC;
	")

	if [[ -z "$eligible_tasks" ]]; then
		return 0
	fi

	local processed=0
	local merged_count=0
	local max_merges_per_pulse="${SUPERVISOR_MAX_MERGES_PER_PULSE:-5}"
	local merged_parents=""
	local repos_with_changes=""

	local total_eligible=0
	total_eligible=$(printf '%s\n' "$eligible_tasks" | grep -c '.' || echo "0")
	log_info "ai-lifecycle: $total_eligible eligible tasks"

	while IFS='|' read -r tid tstatus tpr trepo; do
		[[ -z "$tid" ]] && continue

		# Cap merges per pulse
		if [[ "$merged_count" -ge "$max_merges_per_pulse" ]]; then
			log_info "ai-lifecycle: reached max merges per pulse ($max_merges_per_pulse)"
			break
		fi

		# Serial merge guard for sibling subtasks
		local parent_id
		parent_id=$(extract_parent_id "$tid" 2>/dev/null || echo "")
		if [[ -n "$parent_id" ]] && [[ "$merged_parents" == *"|${parent_id}|"* ]]; then
			log_info "ai-lifecycle: $tid deferred (sibling under $parent_id already merged this pulse)"
			continue
		fi

		# Ensure task is in pr_review state for lifecycle processing
		# (complete tasks need to transition first)
		if [[ "$tstatus" == "complete" ]]; then
			# Check if PR exists before transitioning
			if [[ -n "$tpr" && "$tpr" != "no_pr" && "$tpr" != "task_only" && "$tpr" != "verified_complete" ]]; then
				cmd_transition "$tid" "pr_review" 2>>"$SUPERVISOR_LOG" || true
			fi
		fi

		log_info "ai-lifecycle: processing $tid ($tstatus)"

		if process_task_lifecycle "$tid"; then
			# Check if a merge happened
			local new_status
			new_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
			log_info "ai-lifecycle: $tid → $new_status"
			case "$new_status" in
			merged | deploying | deployed)
				merged_count=$((merged_count + 1))
				if [[ -n "$parent_id" ]]; then
					merged_parents="${merged_parents}|${parent_id}|"
				fi
				# Pull main so subsequent PRs can merge cleanly
				if [[ -n "$trepo" && -d "$trepo" ]]; then
					git -C "$trepo" pull --rebase origin main 2>>"$SUPERVISOR_LOG" || true
				fi
				;;
			esac
		else
			log_warn "ai-lifecycle: $tid failed (process_task_lifecycle returned non-zero)"
		fi

		# Track repos that had status tag changes
		if [[ -n "$trepo" && "$repos_with_changes" != *"$trepo"* ]]; then
			repos_with_changes="${repos_with_changes} ${trepo}"
		fi

		processed=$((processed + 1))
	done <<<"$eligible_tasks"

	# Batch-commit all status tag updates
	for repo in $repos_with_changes; do
		[[ -z "$repo" ]] && continue
		commit_status_tag_updates "$repo" 2>>"$SUPERVISOR_LOG" || true
	done

	if [[ "$processed" -gt 0 ]]; then
		log_info "ai-lifecycle: processed $processed tasks, merged $merged_count"
	fi

	return 0
}
