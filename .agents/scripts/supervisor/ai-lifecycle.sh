#!/usr/bin/env bash
# ai-lifecycle.sh - AI-first task lifecycle engine
#
# Architecture: GATHER → DECIDE → EXECUTE
#
# 1. gather_task_state()  — collects facts from DB, GitHub, git. Pure data.
# 2. ai_decide()          — sends state to opus model, gets JSON action back.
# 3. execute_action()     — runs what the AI decided. Complex work dispatches
#                           an interactive AI worker with full tool access.
#
# Design principle: Shell gathers data and executes commands. AI makes every
# decision. No case statements, no fast-paths, no deterministic decision gates.
# The AI sees the same state a human would and picks the next step.
#
# Sourced by: supervisor-helper.sh
# Depends on: dispatch.sh (resolve_ai_cli, resolve_model)
#             deploy.sh (merge_task_pr, cleanup_after_merge, etc.)
#             state.sh (cmd_transition)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SUPERVISOR_DIR, SCRIPT_DIR, REPO_PATH
#   db(), log_info(), log_warn(), log_error(), log_success(), sql_escape()
#   cmd_transition(), parse_pr_url()

# AI model for ALL lifecycle decisions — opus for full intelligence
AI_LIFECYCLE_MODEL="${AI_LIFECYCLE_MODEL:-opus}"

# Timeout for AI decision calls (seconds)
AI_LIFECYCLE_TIMEOUT="${AI_LIFECYCLE_TIMEOUT:-90}"

# Log directory for decision audit trail
AI_LIFECYCLE_LOG_DIR="${AI_LIFECYCLE_LOG_DIR:-$HOME/.aidevops/logs/ai-lifecycle}"

#######################################
# Gather the real-world state for a task.
# Returns structured text that the AI can reason about.
# PURE DATA — no decisions, no filtering, no skipping.
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
	# Note: worker_pid column was removed in schema migration; use session_id instead.
	# The query previously referenced worker_pid which caused silent SQLite errors,
	# making gather_task_state return empty for ALL tasks and breaking Phase 3 entirely.
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, status, pr_url, repo, branch, worktree, error,
		       rebase_attempts, retries, max_retries, model, session_id
		FROM tasks WHERE id = '$escaped_id';
	" 2>/dev/null || echo "")

	if [[ -z "$task_row" ]]; then
		return 1
	fi

	local tid tstatus tpr trepo tbranch tworktree terror trebase tretries tmax_retries tmodel tsession
	IFS='|' read -r tid tstatus tpr trepo tbranch tworktree terror trebase tretries tmax_retries tmodel tsession <<<"$task_row"

	# GitHub PR state (if PR exists)
	local pr_state="none" pr_merge_state="none" pr_ci_summary="none"
	local pr_ci_failed_names="none" pr_review_decision="none"
	local pr_number="" pr_repo_slug="" pr_base_ref="main"

	if [[ -n "$tpr" && "$tpr" != "no_pr" && "$tpr" != "task_only" && "$tpr" != "verified_complete" ]]; then
		local parsed_pr
		parsed_pr=$(parse_pr_url "$tpr" 2>/dev/null) || parsed_pr=""
		if [[ -n "$parsed_pr" ]]; then
			pr_repo_slug="${parsed_pr%%|*}"
			pr_number="${parsed_pr##*|}"

			if [[ -n "$pr_number" && -n "$pr_repo_slug" ]] && command -v gh &>/dev/null; then
				local pr_json
				pr_json=$(gh pr view "$pr_number" --repo "$pr_repo_slug" \
					--json state,isDraft,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,baseRefName \
					2>/dev/null || echo "")

				if [[ -n "$pr_json" ]]; then
					pr_state=$(printf '%s' "$pr_json" | jq -r '.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
					pr_merge_state=$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
					pr_review_decision=$(printf '%s' "$pr_json" | jq -r '.reviewDecision // "NONE"' 2>/dev/null || echo "NONE")
					pr_base_ref=$(printf '%s' "$pr_json" | jq -r '.baseRefName // "main"' 2>/dev/null || echo "main")

					local is_draft
					is_draft=$(printf '%s' "$pr_json" | jq -r '.isDraft // false' 2>/dev/null || echo "false")
					if [[ "$is_draft" == "true" ]]; then
						pr_state="DRAFT"
					fi

					# CI summary
					local check_rollup
					check_rollup=$(printf '%s' "$pr_json" | jq -r '.statusCheckRollup // []' 2>/dev/null || echo "[]")
					if [[ "$check_rollup" != "[]" && "$check_rollup" != "null" ]]; then
						local pending failed passed total
						pending=$(printf '%s' "$check_rollup" | jq '[.[] | select(.status == "IN_PROGRESS" or .status == "QUEUED" or .status == "PENDING")] | length' 2>/dev/null || echo "0")
						failed=$(printf '%s' "$check_rollup" | jq '[.[] | select((.conclusion | test("FAILURE|TIMED_OUT|ACTION_REQUIRED")) or .state == "FAILURE" or .state == "ERROR")] | length' 2>/dev/null || echo "0")
						passed=$(printf '%s' "$check_rollup" | jq '[.[] | select(.conclusion == "SUCCESS" or .state == "SUCCESS")] | length' 2>/dev/null || echo "0")
						total=$(printf '%s' "$check_rollup" | jq 'length' 2>/dev/null || echo "0")
						pr_ci_summary="total:${total} passed:${passed} failed:${failed} pending:${pending}"

						# Names of failed checks
						local failed_names
						failed_names=$(printf '%s' "$check_rollup" | jq -r '[.[] | select((.conclusion | test("FAILURE|TIMED_OUT|ACTION_REQUIRED")) or .state == "FAILURE" or .state == "ERROR") | .name] | join(", ")' 2>/dev/null || echo "")
						if [[ -n "$failed_names" ]]; then
							pr_ci_failed_names="$failed_names"
						fi
					fi
				fi
			fi
		fi
	fi

	# Worker process state — session_id replaces worker_pid after schema migration.
	# We can check if a worker session is active by looking for the session's
	# log file or checking if the status implies an active worker.
	local worker_alive="unknown"
	if [[ -n "$tsession" && "$tsession" != "0" && "$tsession" != "" ]]; then
		# Session exists — check if the task is in an active-worker state
		if [[ "$tstatus" == "running" || "$tstatus" == "dispatched" ]]; then
			worker_alive="yes (session: ${tsession:0:12}...)"
		else
			worker_alive="no (session ended)"
		fi
	else
		worker_alive="no worker"
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

	# Output structured state — every field the AI needs to make a decision
	cat <<-STATE
		TASK: $tid
		DB_STATUS: $tstatus
		ERROR: ${terror:-none}
		WORKER_ALIVE: $worker_alive
		PR_URL: ${tpr:-none}
		PR_NUMBER: ${pr_number:-none}
		PR_REPO: ${pr_repo_slug:-none}
		PR_STATE: $pr_state
		PR_BASE_BRANCH: $pr_base_ref
		PR_MERGE_STATE: $pr_merge_state
		PR_CI: $pr_ci_summary
		PR_CI_FAILED_CHECKS: $pr_ci_failed_names
		PR_REVIEW: $pr_review_decision
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
# Ask AI for the next action on a task.
# The AI gets full state and decides what to do.
# NO fast-paths, NO deterministic shortcuts.
#
# Arguments:
#   $1 - task state snapshot (from gather_task_state)
#   $2 - task ID (for logging)
# Outputs:
#   JSON object with action and reasoning on stdout
# Returns:
#   0 on success, 1 on failure
#######################################
ai_decide() {
	local task_state="$1"
	local task_id="$2"

	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_error "ai-lifecycle: no AI CLI available"
		return 1
	}

	local ai_model
	ai_model=$(resolve_model "$AI_LIFECYCLE_MODEL" "$ai_cli" 2>/dev/null) || {
		log_error "ai-lifecycle: no model available for tier $AI_LIFECYCLE_MODEL"
		return 1
	}

	local prompt
	prompt="You are the AI supervisor for a DevOps pipeline. You see a task's current state and must decide the single next action to move it toward completion.

CURRENT STATE:
$task_state

YOUR GOAL: Make progress. Every cycle should move the task closer to merged+deployed. If something is broken, fix it. If something is blocked, unblock it. Never just wait unless work is genuinely in progress.

AVAILABLE ACTIONS:
- merge_pr: Squash-merge the PR (CI passed, mergeable)
- update_branch: Update PR branch via GitHub API (PR behind base, no conflicts)
- rebase_branch: Git rebase onto base branch (when update_branch failed or unavailable)
- fix_ci: Dispatch AI worker to fix CI failures in the worktree (format, lint, typecheck, tests)
- resolve_conflicts: Dispatch AI worker to resolve merge conflicts intelligently (reads both sides, understands code, merges correctly)
- fix_and_push: Dispatch AI worker to diagnose and fix any issue blocking the PR (general-purpose problem solver)
- promote_draft: Convert draft PR to ready for review
- close_pr: Close PR without merging (obsolete or superseded)
- deploy: Run post-merge deployment (PR already merged)
- mark_complete: Mark task as deployed without deploy step (no PR, or non-deployable repo)
- dismiss_reviews: Dismiss bot reviews blocking merge
- retry_ci: Re-trigger CI checks (only for transient/infra failures, not code failures)
- wait: Do nothing this cycle (ONLY when a worker is actively running or CI is actively in progress)
- cancel: Cancel the task entirely (unrecoverable)

DECISION RULES:
- PR MERGED on GitHub → deploy (always)
- PR CLEAN or UNSTABLE with PR_REVIEW APPROVED → merge_pr
- PR CLEAN or UNSTABLE with PR_REVIEW not APPROVED → wait (human review required before merge)
- PR BEHIND base → update_branch
- PR DIRTY/CONFLICTING → resolve_conflicts (dispatch AI worker to fix)
- PR BLOCKED with CI failures → fix_ci (dispatch AI worker to fix)
- CI has pending checks AND no failures → wait
- Worker is alive → wait
- Task complete with no PR → mark_complete
- Task blocked with error → fix_and_push (dispatch AI worker to diagnose and fix)
- PR is DRAFT → promote_draft
- NEVER wait when there is a fixable problem. Fix it.
- NEVER wait more than 2 cycles for the same issue. Escalate to fix_and_push.
- If rebase_attempts > 3 → resolve_conflicts (not another rebase)

Respond with ONLY a JSON object (no markdown, no explanation outside the JSON):
{\"action\": \"<action_name>\", \"reason\": \"<one sentence>\", \"status_tag\": \"<status tag for TODO.md>\"}"

	local ai_result=""

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout "$AI_LIFECYCLE_TIMEOUT" opencode run \
			-m "$ai_model" \
			--format default \
			--title "lifecycle-${task_id}-$$" \
			"$prompt" 2>/dev/null || echo "")
		# Strip ANSI codes
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		local claude_model="${ai_model#*/}"
		ai_result=$(portable_timeout "$AI_LIFECYCLE_TIMEOUT" claude \
			-p "$prompt" \
			--model "$claude_model" \
			--output-format text 2>/dev/null || echo "")
	fi

	if [[ -z "$ai_result" ]]; then
		log_warn "ai-lifecycle: empty response from AI for $task_id"
		return 1
	fi

	# Extract JSON from response
	local json_block
	json_block=$(printf '%s' "$ai_result" | grep -oE '\{[^}]+\}' | head -1)

	if [[ -z "$json_block" ]]; then
		log_warn "ai-lifecycle: no JSON in response for $task_id"
		log_warn "ai-lifecycle: raw: $(printf '%s' "$ai_result" | head -c 300)"
		return 1
	fi

	local action
	action=$(printf '%s' "$json_block" | jq -r '.action // ""' 2>/dev/null || echo "")
	if [[ -z "$action" ]]; then
		log_warn "ai-lifecycle: no action field in response for $task_id"
		return 1
	fi

	# Log the decision for audit trail
	mkdir -p "$AI_LIFECYCLE_LOG_DIR" 2>/dev/null || true
	local timestamp
	timestamp=$(date -u '+%Y%m%d-%H%M%S')
	{
		echo "# Decision: $task_id @ $timestamp"
		echo "Action: $action"
		echo "Reason: $(printf '%s' "$json_block" | jq -r '.reason // ""' 2>/dev/null)"
		echo ""
		echo "## State"
		echo "$task_state"
	} >"$AI_LIFECYCLE_LOG_DIR/decision-${task_id}-${timestamp}.md" 2>/dev/null || true

	printf '%s' "$json_block"
	return 0
}

#######################################
# Execute a lifecycle action.
# Simple actions run inline. Complex actions (resolve_conflicts, fix_ci,
# fix_and_push) dispatch an interactive AI worker with full tool access.
#
# Arguments:
#   $1 - task ID
#   $2 - action name
#   $3 - reason (for logging)
#   $4 - status_tag (for TODO.md)
# Returns:
#   0 on success, 1 on failure
#######################################
execute_action() {
	local task_id="$1"
	local action="$2"
	local reason="${3:-}"
	local status_tag="${4:-}"

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Get task details from DB
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT pr_url, repo, branch, worktree FROM tasks WHERE id = '$escaped_id';
	" 2>/dev/null || echo "")

	local tpr trepo tbranch tworktree
	IFS='|' read -r tpr trepo tbranch tworktree <<<"$task_row"

	# Parse PR details
	local pr_number="" pr_repo_slug="" pr_base_branch="main"
	if [[ -n "$tpr" && "$tpr" != "no_pr" && "$tpr" != "task_only" && "$tpr" != "verified_complete" ]]; then
		local parsed_pr
		parsed_pr=$(parse_pr_url "$tpr" 2>/dev/null) || parsed_pr=""
		if [[ -n "$parsed_pr" ]]; then
			pr_repo_slug="${parsed_pr%%|*}"
			pr_number="${parsed_pr##*|}"
			local base_ref
			base_ref=$(gh pr view "$pr_number" --repo "$pr_repo_slug" \
				--json baseRefName --jq '.baseRefName' 2>/dev/null) || base_ref=""
			if [[ -n "$base_ref" ]]; then
				pr_base_branch="$base_ref"
			fi
		fi
	fi

	# Update status tag on TODO.md
	if [[ -n "$status_tag" ]] && declare -f update_task_status_tag &>/dev/null; then
		update_task_status_tag "$task_id" "$status_tag" "$trepo" 2>/dev/null || true
	fi

	log_info "ai-lifecycle: $task_id → $action ($reason)"

	case "$action" in

	merge_pr)
		# t1314: Human review gate — require APPROVED review unless auto-merge is explicitly enabled.
		# Without this, the AI lifecycle merges PRs as soon as mergeState is CLEAN/UNSTABLE,
		# bypassing human review entirely. Default: require human approval.
		local auto_merge_enabled="${SUPERVISOR_AUTO_MERGE_ENABLED:-false}"
		if [[ "$auto_merge_enabled" != "true" ]]; then
			local current_review_decision="NONE"
			if [[ -n "$pr_number" && -n "$pr_repo_slug" ]] && command -v gh &>/dev/null; then
				current_review_decision=$(gh pr view "$pr_number" --repo "$pr_repo_slug" \
					--json reviewDecision --jq '.reviewDecision // "NONE"' 2>/dev/null || echo "NONE")
			fi
			if [[ "$current_review_decision" != "APPROVED" ]]; then
				log_info "ai-lifecycle: $task_id merge blocked — human review required (reviewDecision=$current_review_decision, set SUPERVISOR_AUTO_MERGE_ENABLED=true to bypass) (t1314)"
				cmd_transition "$task_id" "review_waiting" 2>>"$SUPERVISOR_LOG" || true
				return 0
			fi
		fi
		cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
		if merge_task_pr "$task_id" 2>>"$SUPERVISOR_LOG"; then
			cmd_transition "$task_id" "merged" 2>>"$SUPERVISOR_LOG" || true
			# Post-merge: pull base, rebase siblings, deploy, cleanup
			if [[ -n "$trepo" && -d "$trepo" ]]; then
				git -C "$trepo" pull --rebase origin "$pr_base_branch" 2>>"$SUPERVISOR_LOG" || true
			fi
			rebase_sibling_prs_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || true
			run_postflight_for_task "$task_id" "$trepo" 2>>"$SUPERVISOR_LOG" || true
			cmd_transition "$task_id" "deploying" 2>>"$SUPERVISOR_LOG" || true
			run_deploy_for_task "$task_id" "$trepo" 2>>"$SUPERVISOR_LOG" || true
			cmd_transition "$task_id" "deployed" 2>>"$SUPERVISOR_LOG" || true
			cleanup_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || true
			update_todo_on_complete "$task_id" 2>>"$SUPERVISOR_LOG" || true
			log_success "ai-lifecycle: $task_id merged and deployed"
			return 0
		else
			log_warn "ai-lifecycle: merge failed for $task_id"
			cmd_transition "$task_id" "blocked" --error "Merge failed" 2>>"$SUPERVISOR_LOG" || true
			return 1
		fi
		;;

	update_branch)
		if [[ -n "$pr_number" && -n "$pr_repo_slug" ]]; then
			if gh pr update-branch "$pr_number" --repo "$pr_repo_slug" 2>>"$SUPERVISOR_LOG"; then
				log_success "ai-lifecycle: branch updated for $task_id"
				return 0
			fi
		fi
		log_warn "ai-lifecycle: update_branch failed for $task_id"
		return 1
		;;

	rebase_branch)
		if rebase_sibling_pr "$task_id" 2>>"$SUPERVISOR_LOG"; then
			log_success "ai-lifecycle: rebase succeeded for $task_id"
			local current_attempts
			current_attempts=$(db "$SUPERVISOR_DB" "SELECT rebase_attempts FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "0")
			db "$SUPERVISOR_DB" "UPDATE tasks SET rebase_attempts = $((current_attempts + 1)) WHERE id = '$escaped_id';" 2>/dev/null || true
			return 0
		fi
		log_warn "ai-lifecycle: rebase failed for $task_id"
		return 1
		;;

	resolve_conflicts | fix_ci | fix_and_push)
		# These all dispatch an interactive AI worker with full tool access.
		# The worker gets the problem description and solves it autonomously.
		_dispatch_ai_worker "$task_id" "$action" "$trepo" "$tworktree" "$tbranch" "$tpr" "$pr_base_branch"
		return $?
		;;

	promote_draft)
		if [[ -n "$pr_number" && -n "$pr_repo_slug" ]]; then
			if gh pr ready "$pr_number" --repo "$pr_repo_slug" 2>>"$SUPERVISOR_LOG"; then
				log_success "ai-lifecycle: draft promoted for $task_id"
				return 0
			fi
		fi
		return 1
		;;

	close_pr)
		if [[ -n "$pr_number" && -n "$pr_repo_slug" ]]; then
			gh pr close "$pr_number" --repo "$pr_repo_slug" \
				--comment "Closed by AI supervisor: $reason" 2>>"$SUPERVISOR_LOG" || true
		fi
		cmd_transition "$task_id" "cancelled" --error "PR closed: $reason" 2>>"$SUPERVISOR_LOG" || true
		cleanup_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || true
		return 0
		;;

	deploy)
		if [[ -n "$trepo" && -d "$trepo" ]]; then
			git -C "$trepo" pull --rebase origin "$pr_base_branch" 2>>"$SUPERVISOR_LOG" || true
		fi
		# Fast-track through merge states if needed
		local current_status
		current_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
		if [[ "$current_status" != "merged" && "$current_status" != "deploying" && "$current_status" != "deployed" ]]; then
			cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
			cmd_transition "$task_id" "merged" 2>>"$SUPERVISOR_LOG" || true
		fi
		cmd_transition "$task_id" "deploying" 2>>"$SUPERVISOR_LOG" || true
		run_deploy_for_task "$task_id" "$trepo" 2>>"$SUPERVISOR_LOG" || true
		cmd_transition "$task_id" "deployed" 2>>"$SUPERVISOR_LOG" || true
		cleanup_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || true
		update_todo_on_complete "$task_id" 2>>"$SUPERVISOR_LOG" || true
		log_success "ai-lifecycle: $task_id deployed"
		return 0
		;;

	mark_complete)
		local current_status
		current_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
		if [[ "$current_status" == "complete" || "$current_status" == "blocked" ]]; then
			cmd_transition "$task_id" "deployed" 2>>"$SUPERVISOR_LOG" || true
		fi
		cleanup_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || true
		update_todo_on_complete "$task_id" 2>>"$SUPERVISOR_LOG" || true
		log_success "ai-lifecycle: $task_id marked complete"
		return 0
		;;

	dismiss_reviews)
		if [[ -n "$pr_number" && -n "$pr_repo_slug" ]] && declare -f dismiss_bot_reviews &>/dev/null; then
			dismiss_bot_reviews "$pr_number" "$pr_repo_slug" 2>>"$SUPERVISOR_LOG" || true
		fi
		return 0
		;;

	retry_ci)
		if [[ -n "$pr_repo_slug" && -n "$pr_number" ]]; then
			local head_sha
			head_sha=$(gh api "repos/${pr_repo_slug}/pulls/${pr_number}" --jq '.head.sha' 2>/dev/null || echo "")
			if [[ -n "$head_sha" ]]; then
				gh api "repos/${pr_repo_slug}/check-suites" \
					-X POST -f head_sha="$head_sha" 2>>"$SUPERVISOR_LOG" || true
				log_info "ai-lifecycle: CI re-requested for $task_id"
				return 0
			fi
		fi
		return 1
		;;

	wait)
		log_info "ai-lifecycle: waiting for $task_id ($reason)"
		return 0
		;;

	cancel)
		cmd_transition "$task_id" "cancelled" --error "$reason" 2>>"$SUPERVISOR_LOG" || true
		cleanup_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || true
		return 0
		;;

	*)
		log_warn "ai-lifecycle: unknown action '$action' for $task_id"
		return 1
		;;
	esac
}

#######################################
# Dispatch an interactive AI worker to solve a complex problem.
# The worker gets full context and tool access — it can read files,
# edit code, run commands, resolve conflicts, fix tests, etc.
#
# Arguments:
#   $1 - task ID
#   $2 - action type (resolve_conflicts, fix_ci, fix_and_push)
#   $3 - repo path
#   $4 - worktree path
#   $5 - branch name
#   $6 - PR URL
#   $7 - base branch
# Returns:
#   0 on dispatch success, 1 on failure
#######################################
_dispatch_ai_worker() {
	local task_id="$1"
	local action_type="$2"
	local repo_path="$3"
	local worktree="${4:-}"
	local branch="${5:-}"
	local pr_url="${6:-}"
	local base_branch="${7:-main}"

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_error "ai-lifecycle: no AI CLI for worker dispatch"
		return 1
	}

	local ai_model
	ai_model=$(resolve_model "opus" "$ai_cli" 2>/dev/null) || ai_model=""

	local workdir="${worktree:-$repo_path}"
	if [[ ! -d "$workdir" ]]; then
		# Try to recreate worktree if it's gone
		if [[ -n "$branch" && -n "$repo_path" ]]; then
			log_info "ai-lifecycle: recreating worktree for $task_id"
			local wt_path
			wt_path="${HOME}/Git/$(basename "$repo_path")-fix-${task_id}"
			git -C "$repo_path" worktree add "$wt_path" "origin/$branch" 2>>"$SUPERVISOR_LOG" || {
				log_error "ai-lifecycle: cannot create worktree for $task_id"
				return 1
			}
			workdir="$wt_path"
			db "$SUPERVISOR_DB" "UPDATE tasks SET worktree = '$wt_path' WHERE id = '$escaped_id';" 2>/dev/null || true
		else
			log_error "ai-lifecycle: no workdir available for $task_id"
			return 1
		fi
	fi

	# Get error context from DB
	local task_error
	task_error=$(db "$SUPERVISOR_DB" "SELECT error FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "unknown")

	# Build the worker prompt based on action type
	local worker_prompt=""
	case "$action_type" in
	resolve_conflicts)
		worker_prompt="You are fixing merge conflicts for task $task_id.

PR: ${pr_url:-none}
Branch: ${branch:-none}
Base branch: $base_branch
Working directory: $workdir

Steps:
1. git fetch origin $base_branch
2. git rebase --abort (ignore errors if no rebase in progress)
3. git rebase origin/$base_branch
4. For each conflict: read BOTH versions, understand the intent of each change, produce a correct merge that preserves both features
5. git add the resolved files, git rebase --continue
6. Repeat until rebase is complete
7. git push --force-with-lease origin $branch
8. Verify: gh pr view $pr_url --json mergeStateStatus

IMPORTANT: Do NOT just pick one side. Read the code, understand what each side is doing, and merge them correctly. If one side adds a feature and the other refactors, keep both the feature and the refactoring.

Output ONLY one of: RESOLVED or FAILED:<reason>"
		;;

	fix_ci)
		worker_prompt="You are fixing CI failures for task $task_id.

PR: ${pr_url:-none}
Branch: ${branch:-none}
Working directory: $workdir
Error: ${task_error:-unknown}

Steps:
1. Check which CI checks failed: gh pr checks ${pr_url:-}
2. For format/lint failures: run the project's format and lint fix commands
3. For typecheck failures: read the error output, fix the type errors in the source code
4. For test failures: read the test output, fix the failing tests or the code they test
5. git add -A && git commit -m 'fix: resolve CI failures for $task_id'
6. git push --force-with-lease origin $branch
7. Verify the push succeeded

IMPORTANT: Actually fix the root cause. Don't just suppress errors or skip tests. Read the error messages and fix the code.

Output ONLY one of: FIXED or FAILED:<reason>"
		;;

	fix_and_push)
		worker_prompt="You are a senior engineer diagnosing and fixing a blocked task.

Task: $task_id
PR: ${pr_url:-none}
Branch: ${branch:-none}
Working directory: $workdir
Current error: ${task_error:-unknown}

Your job: Figure out what's wrong and fix it. This task is stuck and needs your intelligence to unblock it.

Steps:
1. Understand the current state: git status, gh pr view, check CI, check for conflicts
2. Diagnose the root cause of the blockage
3. Fix it — whether that's resolving conflicts, fixing code, updating dependencies, or anything else
4. Commit and push your fix
5. Verify the PR is in a better state than before

Output ONLY one of: FIXED:<what you did> or FAILED:<why you couldn't fix it>"
		;;
	esac

	# Dispatch the worker
	local worker_log
	worker_log="${SUPERVISOR_DIR}/logs/worker-${task_id}-$(date +%Y%m%d-%H%M%S).log"
	mkdir -p "$SUPERVISOR_DIR/logs" 2>/dev/null || true

	log_info "ai-lifecycle: dispatching $action_type worker for $task_id in $workdir"

	if [[ "$ai_cli" == "opencode" ]]; then
		(cd "$workdir" && opencode run \
			${ai_model:+-m "$ai_model"} \
			--format json \
			--title "${action_type}-${task_id}" \
			"$worker_prompt" \
			>"$worker_log" 2>&1) &
	else
		local claude_model="${ai_model#*/}"
		(cd "$workdir" && claude \
			-p "$worker_prompt" \
			${claude_model:+--model "$claude_model"} \
			>"$worker_log" 2>&1) &
	fi
	local worker_pid=$!

	# Record in DB — use session_id (not worker_pid which was removed in schema migration)
	db "$SUPERVISOR_DB" "UPDATE tasks SET
		status = 'running',
		error = '${action_type}: AI worker solving (PID $worker_pid)',
		session_id = 'pid:$worker_pid',
		log_file = '$(sql_escape "$worker_log")',
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
	WHERE id = '$escaped_id';" 2>/dev/null || true

	# PID file for health monitoring
	mkdir -p "$SUPERVISOR_DIR/pids" 2>/dev/null || true
	echo "$worker_pid" >"$SUPERVISOR_DIR/pids/${task_id}.pid"

	log_success "ai-lifecycle: $action_type worker dispatched for $task_id (PID $worker_pid)"
	return 0
}

#######################################
# Process all active tasks through the AI lifecycle engine.
# This is the main entry point called from pulse.sh Phase 3.
#
# For each eligible task: gather state → AI decides → execute action.
#
# Arguments:
#   $1 - (optional) batch ID filter
# Returns:
#   0 on success
#######################################
process_ai_lifecycle() {
	local batch_id="${1:-}"

	ensure_db

	# Find ALL tasks that need attention — not just specific states.
	# The AI decides what to do with each one, including whether to wait.
	local where_clause="t.status IN ('complete', 'pr_review', 'review_triage', 'merging', 'merged', 'deploying', 'blocked', 'running', 'evaluating', 'dispatched', 'verified', 'deployed')"
	if [[ -n "$batch_id" ]]; then
		where_clause="$where_clause AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$(sql_escape "$batch_id")')"
	fi

	# Exclude terminal states that genuinely need no action
	# verified/deployed WITH merged PRs are truly done
	# cancelled tasks are done
	local eligible_tasks
	eligible_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT t.id, t.status, t.pr_url, t.repo FROM tasks t
		WHERE $where_clause
		AND t.status != 'cancelled'
		AND NOT (t.status IN ('verified', 'deployed') AND (t.pr_url IS NULL OR t.pr_url = '' OR t.pr_url = 'no_pr' OR t.pr_url = 'task_only' OR t.pr_url = 'verified_complete'))
		ORDER BY
			CASE t.status
				WHEN 'merging' THEN 1
				WHEN 'merged' THEN 2
				WHEN 'deploying' THEN 3
				WHEN 'blocked' THEN 4
				WHEN 'review_triage' THEN 5
				WHEN 'pr_review' THEN 6
				WHEN 'complete' THEN 7
				WHEN 'running' THEN 8
				WHEN 'evaluating' THEN 9
				WHEN 'dispatched' THEN 10
				WHEN 'verified' THEN 11
				WHEN 'deployed' THEN 12
			END,
			t.updated_at ASC
		LIMIT 20;
	")

	if [[ -z "$eligible_tasks" ]]; then
		log_info "ai-lifecycle: no tasks need attention"
		return 0
	fi

	local processed=0
	local actioned=0
	local max_actions_per_pulse="${SUPERVISOR_MAX_ACTIONS_PER_PULSE:-10}"

	# Track merged parent IDs to serialize sibling merges
	local merged_parents=""

	local total_eligible
	total_eligible=$(printf '%s\n' "$eligible_tasks" | grep -c '.' || echo "0")
	log_info "ai-lifecycle: $total_eligible tasks to evaluate"

	while IFS='|' read -r tid tstatus tpr trepo; do
		[[ -z "$tid" ]] && continue

		# Cap actions per pulse to prevent runaway
		if [[ "$actioned" -ge "$max_actions_per_pulse" ]]; then
			log_info "ai-lifecycle: reached max actions ($max_actions_per_pulse), rest deferred"
			break
		fi

		# Serial merge guard for siblings
		local parent_id
		parent_id=$(extract_parent_id "$tid" 2>/dev/null || echo "")
		if [[ -n "$parent_id" ]] && [[ "$merged_parents" == *"|${parent_id}|"* ]]; then
			log_info "ai-lifecycle: $tid deferred (sibling merge this pulse)"
			continue
		fi

		# Transition complete tasks with PRs to pr_review
		if [[ "$tstatus" == "complete" && -n "$tpr" && "$tpr" != "no_pr" && "$tpr" != "task_only" && "$tpr" != "verified_complete" ]]; then
			cmd_transition "$tid" "pr_review" 2>>"$SUPERVISOR_LOG" || true
		fi

		# GATHER
		local task_state
		task_state=$(gather_task_state "$tid") || {
			log_warn "ai-lifecycle: could not gather state for $tid"
			continue
		}

		# DECIDE
		local decision
		decision=$(ai_decide "$task_state" "$tid") || {
			log_warn "ai-lifecycle: AI decision failed for $tid — skipping"
			continue
		}

		local action reason status_tag
		action=$(printf '%s' "$decision" | jq -r '.action // "wait"' 2>/dev/null || echo "wait")
		reason=$(printf '%s' "$decision" | jq -r '.reason // ""' 2>/dev/null || echo "")
		status_tag=$(printf '%s' "$decision" | jq -r '.status_tag // ""' 2>/dev/null || echo "")

		log_info "ai-lifecycle: $tid ($tstatus) → $action: $reason"

		# EXECUTE
		if [[ "$action" != "wait" ]]; then
			execute_action "$tid" "$action" "$reason" "$status_tag"
			actioned=$((actioned + 1))

			# Track merges for sibling serialization
			local new_status
			new_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
			case "$new_status" in
			merged | deploying | deployed)
				if [[ -n "$parent_id" ]]; then
					merged_parents="${merged_parents}|${parent_id}|"
				fi
				# Pull base so subsequent PRs can merge cleanly
				if [[ -n "$trepo" && -d "$trepo" ]]; then
					local base_ref
					base_ref=$(gh pr view "$tpr" --repo "$(detect_repo_slug "$trepo" 2>/dev/null || echo "")" \
						--json baseRefName --jq '.baseRefName' 2>/dev/null) || base_ref="main"
					git -C "$trepo" pull --rebase origin "$base_ref" 2>>"$SUPERVISOR_LOG" || true
				fi
				;;
			esac
		fi

		processed=$((processed + 1))
	done <<<"$eligible_tasks"

	# Batch-commit status tag updates
	if [[ -n "$eligible_tasks" ]]; then
		local repos_seen=""
		while IFS='|' read -r _ _ _ trepo; do
			if [[ -n "$trepo" && "$repos_seen" != *"$trepo"* ]]; then
				repos_seen="${repos_seen} ${trepo}"
				if declare -f commit_status_tag_updates &>/dev/null; then
					commit_status_tag_updates "$trepo" 2>>"$SUPERVISOR_LOG" || true
				fi
			fi
		done <<<"$eligible_tasks"
	fi

	log_info "ai-lifecycle: evaluated $processed tasks, actioned $actioned"
	return 0
}

# Keep update_task_status_tag for backward compatibility with other modules
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
		return 1
	fi

	local todo_file="$trepo/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		return 1
	fi

	local line_num
	line_num=$(grep -nE "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file" | head -1 | cut -d: -f1)
	if [[ -z "$line_num" ]]; then
		return 0
	fi

	local task_line
	task_line=$(sed -n "${line_num}p" "$todo_file")

	local updated_line
	updated_line=$(printf '%s' "$task_line" | sed -E 's/ status:[^ ]*//')
	updated_line="${updated_line} status:${new_status}"

	sed_inplace "${line_num}s|.*|${updated_line}|" "$todo_file"
	return 0
}

# Keep commit_status_tag_updates for backward compatibility
commit_status_tag_updates() {
	local repo_path="$1"

	if [[ ! -f "$repo_path/TODO.md" ]]; then
		return 0
	fi

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
