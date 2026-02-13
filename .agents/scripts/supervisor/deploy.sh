#!/usr/bin/env bash
# deploy.sh - PR lifecycle, merge, and deployment functions
#
# Functions for PR review, merge, postflight, deployment,
# verification, and rebase operations

#######################################
# Run postflight checks after merge
# Lightweight: just verifies the merge landed on main
#######################################
run_postflight_for_task() {
	local task_id="$1"
	local repo="$2"

	log_info "Running postflight for $task_id..."

	# Pull latest main to verify merge landed
	if ! git -C "$repo" pull origin main --ff-only 2>>"$SUPERVISOR_LOG"; then
		git -C "$repo" pull origin main 2>>"$SUPERVISOR_LOG" || true
	fi

	# Verify the branch was merged (PR should show as merged)
	local pr_status_full pr_status
	pr_status_full=$(check_pr_status "$task_id")
	pr_status="${pr_status_full%%|*}"
	if [[ "$pr_status" == "already_merged" ]]; then
		log_success "Postflight: PR confirmed merged for $task_id"
		return 0
	fi

	log_warn "Postflight: PR status is '$pr_status' for $task_id (expected already_merged)"
	return 1
}

#######################################
# Run deploy for a task (aidevops repos only)
# Uses targeted deploy-agents-on-merge.sh when available (t213),
# falls back to full setup.sh --non-interactive
#######################################
run_deploy_for_task() {
	local task_id="$1"
	local repo="$2"

	# Check if this is an aidevops repo
	local is_aidevops=false
	if [[ "$repo" == *"/aidevops"* ]]; then
		is_aidevops=true
	elif [[ -f "$repo/.aidevops-repo" ]]; then
		is_aidevops=true
	elif [[ -f "$repo/setup.sh" ]] && grep -q "aidevops" "$repo/setup.sh" 2>/dev/null; then
		is_aidevops=true
	fi

	if [[ "$is_aidevops" == "false" ]]; then
		log_info "Not an aidevops repo, skipping deploy for $task_id"
		return 0
	fi

	local deploy_log
	deploy_log="$SUPERVISOR_DIR/logs/${task_id}-deploy-$(date +%Y%m%d%H%M%S).log"
	mkdir -p "$SUPERVISOR_DIR/logs"

	# Try targeted deploy first (faster: only syncs changed agent files)
	local deploy_script="$repo/.agents/scripts/deploy-agents-on-merge.sh"
	if [[ -x "$deploy_script" ]]; then
		# Detect what changed in the merged PR to choose deploy strategy
		local pre_merge_commit=""
		local escaped_id
		escaped_id=$(sql_escape "$task_id")
		pre_merge_commit=$(db "$SUPERVISOR_DB" "
            SELECT json_extract(error, '$.pre_merge_commit')
            FROM tasks WHERE id = '$escaped_id';
        " 2>/dev/null || echo "")

		local deploy_args=("--repo" "$repo" "--quiet")
		if [[ -n "$pre_merge_commit" && "$pre_merge_commit" != "null" ]]; then
			deploy_args+=("--diff" "$pre_merge_commit")
			log_info "Targeted deploy for $task_id (diff since $pre_merge_commit)..."
		else
			log_info "Targeted deploy for $task_id (version-based detection)..."
		fi

		local deploy_output
		if deploy_output=$("$deploy_script" "${deploy_args[@]}" 2>&1); then
			log_success "Targeted deploy complete for $task_id"
			echo "$deploy_output" >"$deploy_log" 2>/dev/null || true
			return 0
		fi

		local deploy_exit=$?
		if [[ "$deploy_exit" -eq 2 ]]; then
			# Exit 2 = nothing to deploy (no changes detected)
			log_info "No agent changes to deploy for $task_id"
			return 0
		fi

		log_warn "Targeted deploy failed for $task_id (exit $deploy_exit), falling back to setup.sh"
		echo "$deploy_output" >"$deploy_log" 2>/dev/null || true
	fi

	# Fallback: full setup.sh --non-interactive
	if [[ ! -x "$repo/setup.sh" ]]; then
		log_warn "setup.sh not found or not executable in $repo"
		return 0
	fi

	log_info "Running setup.sh for $task_id (timeout: 300s)..."

	# Portable timeout: prefer timeout/gtimeout, fall back to background+kill
	local timeout_cmd=""
	if command -v timeout &>/dev/null; then
		timeout_cmd="timeout 300"
	elif command -v gtimeout &>/dev/null; then
		timeout_cmd="gtimeout 300"
	fi

	local deploy_output
	if [[ -n "$timeout_cmd" ]]; then
		if ! deploy_output=$(cd "$repo" && AIDEVOPS_NON_INTERACTIVE=true $timeout_cmd ./setup.sh --non-interactive 2>&1); then
			log_warn "Deploy (setup.sh) returned non-zero for $task_id (see $deploy_log)"
			echo "$deploy_output" >"$deploy_log" 2>/dev/null || true
			return 1
		fi
	else
		# Fallback: background process with manual timeout
		(cd "$repo" && AIDEVOPS_NON_INTERACTIVE=true ./setup.sh --non-interactive >"$deploy_log" 2>&1) &
		local deploy_pid=$!
		local waited=0
		while kill -0 "$deploy_pid" 2>/dev/null && [[ "$waited" -lt 300 ]]; do
			sleep 5
			waited=$((waited + 5))
		done
		if kill -0 "$deploy_pid" 2>/dev/null; then
			kill "$deploy_pid" 2>/dev/null || true
			log_warn "Deploy (setup.sh) timed out after 300s for $task_id (see $deploy_log)"
			return 1
		fi
		if ! wait "$deploy_pid"; then
			deploy_output=$(cat "$deploy_log" 2>/dev/null || echo "")
			log_warn "Deploy (setup.sh) returned non-zero for $task_id (see $deploy_log)"
			return 1
		fi
		deploy_output=$(cat "$deploy_log" 2>/dev/null || echo "")
	fi
	log_success "Deploy complete for $task_id"
	return 0
}

#######################################
# Record PR lifecycle timing metrics to proof-log for pipeline latency analysis (t219)
# Args: task_id, stage_timings (e.g., "pr_review:5s,merging:3s,deploying:12s,total:20s")
#######################################
record_lifecycle_timing() {
	local task_id="$1"
	local stage_timings="$2"

	if [[ -z "$task_id" || -z "$stage_timings" ]]; then
		return 0
	fi

	# Write to proof-log if it exists
	local proof_log="${SUPERVISOR_DIR}/proof-log.jsonl"
	if [[ ! -f "$proof_log" ]]; then
		return 0
	fi

	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Parse stage timings into JSON object
	local stages_json="{"
	local first=true
	IFS=',' read -ra STAGES <<<"$stage_timings"
	for stage in "${STAGES[@]}"; do
		if [[ "$stage" =~ ^([^:]+):(.+)$ ]]; then
			local stage_name="${BASH_REMATCH[1]}"
			local stage_time="${BASH_REMATCH[2]}"
			if [[ "$first" == "true" ]]; then
				first=false
			else
				stages_json="${stages_json},"
			fi
			stages_json="${stages_json}\"${stage_name}\":\"${stage_time}\""
		fi
	done
	stages_json="${stages_json}}"

	# Append to proof-log
	local log_entry
	log_entry=$(jq -n \
		--arg ts "$timestamp" \
		--arg tid "$task_id" \
		--arg event "pr_lifecycle_timing" \
		--argjson stages "$stages_json" \
		'{timestamp: $ts, task_id: $tid, event: $event, stages: $stages}' 2>/dev/null || echo "")

	if [[ -n "$log_entry" ]]; then
		echo "$log_entry" >>"$proof_log"
	fi

	return 0
}

#######################################
# Command: pr-lifecycle - handle full post-PR lifecycle for a task
# Checks CI, triages review threads, merges, runs postflight, deploys, cleans up worktree
# t219: Multi-stage transitions within single pulse for faster merge pipeline
#######################################
cmd_pr_lifecycle() {
	local task_id="" dry_run="false" skip_review_triage="false"

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--skip-review-triage)
			skip_review_triage=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Also check env var for global bypass (t148.6)
	if [[ "${SUPERVISOR_SKIP_REVIEW_TRIAGE:-false}" == "true" ]]; then
		skip_review_triage=true
	fi

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh pr-lifecycle <task_id> [--dry-run] [--skip-review-triage]"
		return 1
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, pr_url, repo, worktree FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local tstatus tpr trepo tworktree
	IFS='|' read -r tstatus tpr trepo tworktree <<<"$task_row"

	# t219: Track timing metrics for pipeline latency analysis
	local lifecycle_start_time
	lifecycle_start_time=$(date +%s)
	local stage_timings=""

	echo -e "${BOLD}=== Post-PR Lifecycle: $task_id ===${NC}"
	echo "  Status:   $tstatus"
	echo "  PR:       ${tpr:-none}"
	echo "  Repo:     $trepo"
	echo "  Worktree: ${tworktree:-none}"

	# Step 1: Transition to pr_review if still in complete
	if [[ "$tstatus" == "complete" ]]; then
		if [[ -z "$tpr" || "$tpr" == "no_pr" || "$tpr" == "task_only" || "$tpr" == "verified_complete" ]]; then
			# Discover PR via centralized link_pr_to_task() (t232, t223)
			local found_pr=""
			if [[ "$dry_run" == "false" ]]; then
				found_pr=$(link_pr_to_task "$task_id" --caller "cmd_pr_lifecycle") || found_pr=""
			fi
			if [[ -n "$found_pr" ]]; then
				log_info "Found PR for $task_id via branch lookup (validated): $found_pr"
				tpr="$found_pr"
			else
				log_warn "No PR for $task_id - skipping post-PR lifecycle"
				if [[ "$dry_run" == "false" ]]; then
					# t240: Clean up worktree even for no-PR tasks (previously skipped)
					cleanup_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || log_warn "Worktree cleanup issue for $task_id (no-PR path, non-blocking)"
					cmd_transition "$task_id" "deployed" 2>>"$SUPERVISOR_LOG" || true
				fi
				return 0
			fi
		fi
		if [[ "$dry_run" == "false" ]]; then
			cmd_transition "$task_id" "pr_review" 2>>"$SUPERVISOR_LOG" || true
		fi
		tstatus="pr_review"
	fi

	# Step 2: Check PR status
	if [[ "$tstatus" == "pr_review" ]]; then
		local stage_start
		stage_start=$(date +%s)

		# t298: Parse status|mergeStateStatus format
		local pr_status_full pr_status merge_state_status
		pr_status_full=$(check_pr_status "$task_id")
		pr_status="${pr_status_full%%|*}"
		merge_state_status="${pr_status_full##*|}"
		log_info "PR status: $pr_status (merge state: $merge_state_status)"

		case "$pr_status" in
		ready_to_merge | unstable_sonarcloud)
			# t227: unstable_sonarcloud = GH Action passed but external quality gate failed
			# This is safe to merge with --admin flag
			local merge_note=""
			if [[ "$pr_status" == "unstable_sonarcloud" ]]; then
				merge_note=" (SonarCloud external gate failed but GH Action passed - using --admin)"
				log_info "SonarCloud pattern detected: GH Action passed, external quality gate failed - will merge with --admin"
			fi

			# CI passed and no CHANGES_REQUESTED - but bot reviews post as
			# COMMENTED, so we need to check unresolved threads directly (t148)
			# t219: Fast-path optimization - check for zero review threads immediately
			# If CI is green and no threads exist, skip review_triage state entirely
			if [[ "$skip_review_triage" == "true" ]]; then
				log_info "Review triage skipped (--skip-review-triage) for $task_id${merge_note}"
				if [[ "$dry_run" == "false" ]]; then
					cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
				fi
				tstatus="merging"
			else
				# t219: Fast-path check - if zero review threads, skip triage state
				# t232: Use centralized parse_pr_url() for URL parsing
				local parsed_fastpath pr_number_fastpath repo_slug_fastpath
				parsed_fastpath=$(parse_pr_url "$tpr") || parsed_fastpath=""
				repo_slug_fastpath="${parsed_fastpath%%|*}"
				pr_number_fastpath="${parsed_fastpath##*|}"

				if [[ -n "$pr_number_fastpath" && -n "$repo_slug_fastpath" ]]; then
					local threads_json_fastpath
					threads_json_fastpath=$(check_review_threads "$repo_slug_fastpath" "$pr_number_fastpath" 2>/dev/null || echo "[]")
					local thread_count_fastpath
					thread_count_fastpath=$(echo "$threads_json_fastpath" | jq 'length' 2>/dev/null || echo "0")

					if [[ "$thread_count_fastpath" -eq 0 ]]; then
						log_info "Fast-path: CI green + zero review threads - skipping review_triage, going directly to merge${merge_note}"
						if [[ "$dry_run" == "false" ]]; then
							db "$SUPERVISOR_DB" "UPDATE tasks SET triage_result = '{\"action\":\"merge\",\"threads\":0,\"fast_path\":true,\"sonarcloud_unstable\":$(if [[ "$pr_status" == "unstable_sonarcloud" ]]; then echo "true"; else echo "false"; fi)}' WHERE id = '$escaped_id';"
							cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
						fi
						tstatus="merging"
					else
						# Has review threads - go through normal triage
						if [[ "$dry_run" == "false" ]]; then
							cmd_transition "$task_id" "review_triage" 2>>"$SUPERVISOR_LOG" || true
						fi
						tstatus="review_triage"
					fi
				else
					# Cannot parse PR URL - fall back to triage
					if [[ "$dry_run" == "false" ]]; then
						cmd_transition "$task_id" "review_triage" 2>>"$SUPERVISOR_LOG" || true
					fi
					tstatus="review_triage"
				fi
			fi
			;;
		already_merged)
			if [[ "$dry_run" == "false" ]]; then
				cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
				cmd_transition "$task_id" "merged" 2>>"$SUPERVISOR_LOG" || true
			fi
			tstatus="merged"
			;;
		ci_pending)
			# t298: Auto-rebase BEHIND/DIRTY PRs to unblock CI
			if [[ "$merge_state_status" == "BEHIND" || "$merge_state_status" == "DIRTY" ]]; then
				# Check rebase attempt counter to prevent infinite loops
				local rebase_attempts
				rebase_attempts=$(db "$SUPERVISOR_DB" "SELECT rebase_attempts FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "0")
				rebase_attempts=${rebase_attempts:-0}

				local max_rebase_attempts=2
				if [[ "$rebase_attempts" -lt "$max_rebase_attempts" ]]; then
					log_info "PR is $merge_state_status for $task_id — attempting auto-rebase (attempt $((rebase_attempts + 1))/$max_rebase_attempts)"

					if rebase_sibling_pr "$task_id"; then
						log_success "Auto-rebase succeeded for $task_id — CI will re-run"
						# Increment rebase counter
						if [[ "$dry_run" == "false" ]]; then
							db "$SUPERVISOR_DB" "UPDATE tasks SET rebase_attempts = $((rebase_attempts + 1)) WHERE id = '$escaped_id';"
						fi
						# Continue pulse — CI will re-run and we'll check again next pulse
						local stage_end
						stage_end=$(date +%s)
						stage_timings="${stage_timings}pr_review:$((stage_end - stage_start))s(rebased),"
						record_lifecycle_timing "$task_id" "$stage_timings" 2>/dev/null || true
						return 0
					else
						# Rebase failed (conflicts or other error)
						log_warn "Auto-rebase failed for $task_id — transitioning to blocked:merge_conflict"
						if [[ "$dry_run" == "false" ]]; then
							cmd_transition "$task_id" "blocked" --error "Merge conflict — auto-rebase failed" 2>>"$SUPERVISOR_LOG" || true
							send_task_notification "$task_id" "blocked" "PR has merge conflicts that require manual resolution" 2>>"$SUPERVISOR_LOG" || true
						fi
						return 1
					fi
				else
					log_warn "Max rebase attempts ($max_rebase_attempts) reached for $task_id — transitioning to blocked"
					if [[ "$dry_run" == "false" ]]; then
						cmd_transition "$task_id" "blocked" --error "Max rebase attempts reached — manual intervention required" 2>>"$SUPERVISOR_LOG" || true
						send_task_notification "$task_id" "blocked" "PR stuck in $merge_state_status state after $max_rebase_attempts rebase attempts" 2>>"$SUPERVISOR_LOG" || true
					fi
					return 1
				fi
			else
				# CI pending for other reasons (checks running, etc.)
				log_info "CI still pending for $task_id (merge state: $merge_state_status), will retry next pulse"
			fi

			# t219: Record timing even for early returns
			local stage_end
			stage_end=$(date +%s)
			stage_timings="${stage_timings}pr_review:$((stage_end - stage_start))s(ci_pending),"
			record_lifecycle_timing "$task_id" "$stage_timings" 2>/dev/null || true
			return 0
			;;
		ci_failed)
			log_warn "CI failed for $task_id"
			if [[ "$dry_run" == "false" ]]; then
				cmd_transition "$task_id" "blocked" --error "CI checks failed" 2>>"$SUPERVISOR_LOG" || true
				send_task_notification "$task_id" "blocked" "CI checks failed on PR" 2>>"$SUPERVISOR_LOG" || true
			fi
			return 1
			;;
		changes_requested)
			log_warn "Changes requested on PR for $task_id"
			if [[ "$dry_run" == "false" ]]; then
				cmd_transition "$task_id" "blocked" --error "PR changes requested" 2>>"$SUPERVISOR_LOG" || true
				send_task_notification "$task_id" "blocked" "PR changes requested" 2>>"$SUPERVISOR_LOG" || true
			fi
			return 1
			;;
		draft)
			# Auto-promote draft PRs when the worker is dead (t228)
			# Workers create draft PRs early for incremental commits. If the
			# worker ran out of context before running `gh pr ready`, the draft
			# is as complete as it's going to get — promote it automatically.
			local worker_pid_file="$SUPERVISOR_DIR/pids/${task_id}.pid"
			local worker_alive=false
			if [[ -f "$worker_pid_file" ]]; then
				local wpid
				wpid=$(cat "$worker_pid_file")
				if kill -0 "$wpid" 2>/dev/null; then
					worker_alive=true
				fi
			fi

			if [[ "$worker_alive" == "true" ]]; then
				log_info "PR is draft but worker still running for $task_id — waiting"
			else
				log_info "PR is draft and worker is dead for $task_id — auto-promoting to ready"
				if [[ "$dry_run" == "false" ]]; then
					# t232: Use centralized parse_pr_url() for URL parsing
					local parsed_draft pr_num_draft repo_slug_draft
					parsed_draft=$(parse_pr_url "$tpr") || parsed_draft=""
					repo_slug_draft="${parsed_draft%%|*}"
					pr_num_draft="${parsed_draft##*|}"
					if [[ -n "$pr_num_draft" && -n "$repo_slug_draft" ]]; then
						gh pr ready "$pr_num_draft" --repo "$repo_slug_draft" 2>>"$SUPERVISOR_LOG" || true
						log_success "Auto-promoted draft PR #$pr_num_draft to ready for $task_id"
					fi
				fi
			fi
			# t219: Record timing even for early returns
			local stage_end
			stage_end=$(date +%s)
			stage_timings="${stage_timings}pr_review:$((stage_end - stage_start))s(draft),"
			record_lifecycle_timing "$task_id" "$stage_timings" 2>/dev/null || true
			return 0
			;;
		closed)
			log_warn "PR was closed without merge for $task_id"
			if [[ "$dry_run" == "false" ]]; then
				cmd_transition "$task_id" "blocked" --error "PR closed without merge" 2>>"$SUPERVISOR_LOG" || true
			fi
			return 1
			;;
		no_pr)
			# Track consecutive no_pr failures to avoid infinite retry loop
			local no_pr_count
			no_pr_count=$(db "$SUPERVISOR_DB" "SELECT COALESCE(
                    (SELECT CAST(json_extract(error, '$.no_pr_retries') AS INTEGER)
                     FROM tasks WHERE id='$task_id'), 0);" 2>/dev/null || echo "0")
			no_pr_count=$((no_pr_count + 1))

			if [[ "$no_pr_count" -ge 5 ]]; then
				log_warn "No PR found for $task_id after $no_pr_count attempts -- blocking"
				if ! command -v gh &>/dev/null; then
					log_warn "  ROOT CAUSE: 'gh' CLI not in PATH ($(echo "$PATH" | tr ':' '\n' | head -5 | tr '\n' ':'))"
				fi
				if [[ "$dry_run" == "false" ]]; then
					cmd_transition "$task_id" "blocked" --error "PR unreachable after $no_pr_count attempts (gh in PATH: $(command -v gh 2>/dev/null || echo 'NOT FOUND'))" 2>>"$SUPERVISOR_LOG" || true
				fi
				return 1
			fi

			log_warn "No PR found for $task_id (attempt $no_pr_count/5)"
			# Store retry count in error field as JSON
			log_cmd "db-no-pr-retry" db "$SUPERVISOR_DB" "UPDATE tasks SET error = json_set(COALESCE(error, '{}'), '$.no_pr_retries', $no_pr_count), updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id='$task_id';" || log_warn "Failed to persist no_pr retry count for $task_id"
			return 0
			;;
		esac

		# t219: Record pr_review stage timing
		local stage_end
		stage_end=$(date +%s)
		stage_timings="${stage_timings}pr_review:$((stage_end - stage_start))s,"
	fi

	# Step 2b: Review triage - check unresolved threads and classify (t148)
	if [[ "$tstatus" == "review_triage" ]]; then
		local stage_start
		stage_start=$(date +%s)

		# Extract PR number and repo slug for GraphQL query (t232)
		local parsed_triage pr_number_triage repo_slug_triage
		parsed_triage=$(parse_pr_url "$tpr") || parsed_triage=""
		repo_slug_triage="${parsed_triage%%|*}"
		pr_number_triage="${parsed_triage##*|}"

		if [[ -z "$pr_number_triage" || -z "$repo_slug_triage" ]]; then
			log_warn "Cannot parse PR URL for triage: $tpr - skipping triage"
			if [[ "$dry_run" == "false" ]]; then
				cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
			fi
			tstatus="merging"
		else
			log_info "Checking unresolved review threads for $task_id (PR #$pr_number_triage)..."

			local threads_json
			threads_json=$(check_review_threads "$repo_slug_triage" "$pr_number_triage")

			local thread_count
			thread_count=$(echo "$threads_json" | jq 'length' 2>/dev/null || echo "0")

			if [[ "$thread_count" -eq 0 ]]; then
				log_info "No unresolved review threads for $task_id - proceeding to merge"
				if [[ "$dry_run" == "false" ]]; then
					db "$SUPERVISOR_DB" "UPDATE tasks SET triage_result = '{\"action\":\"merge\",\"threads\":0}' WHERE id = '$escaped_id';"
					cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
				fi
				tstatus="merging"
			else
				log_info "Found $thread_count unresolved review thread(s) for $task_id - triaging..."

				local triage_result
				triage_result=$(triage_review_feedback "$threads_json")

				local triage_action
				triage_action=$(echo "$triage_result" | jq -r '.action' 2>/dev/null || echo "merge")

				local triage_summary
				triage_summary=$(echo "$triage_result" | jq -r '.summary | "critical:\(.critical) high:\(.high) medium:\(.medium) low:\(.low) dismiss:\(.dismiss)"' 2>/dev/null || echo "unknown")

				log_info "Triage result for $task_id: action=$triage_action ($triage_summary)"

				if [[ "$dry_run" == "true" ]]; then
					log_info "[dry-run] Would take action: $triage_action"
					return 0
				fi

				# Store triage result in DB
				local escaped_triage
				escaped_triage=$(sql_escape "$triage_result")
				db "$SUPERVISOR_DB" "UPDATE tasks SET triage_result = '$escaped_triage' WHERE id = '$escaped_id';"

				case "$triage_action" in
				merge)
					# Only low/dismiss threads - safe to merge
					log_info "Review threads are low-severity/dismissible - proceeding to merge"
					cmd_transition "$task_id" "merging" 2>>"$SUPERVISOR_LOG" || true
					tstatus="merging"
					;;
				fix)
					# High/medium threads need fixing - dispatch a worker
					log_info "Dispatching review fix worker for $task_id ($triage_summary)"
					if dispatch_review_fix_worker "$task_id" "$triage_result" 2>>"$SUPERVISOR_LOG"; then
						# Worker dispatched - task is now running again
						# When it completes, it will go through evaluate -> complete -> pr_review -> triage again
						log_success "Review fix worker dispatched for $task_id"
					else
						log_error "Failed to dispatch review fix worker for $task_id"
						cmd_transition "$task_id" "blocked" --error "Review fix dispatch failed ($triage_summary)" 2>>"$SUPERVISOR_LOG" || true
						send_task_notification "$task_id" "blocked" "Review fix dispatch failed" 2>>"$SUPERVISOR_LOG" || true
					fi
					return 0
					;;
				block)
					# Critical threads - needs human review
					log_warn "Critical review threads found for $task_id - blocking for human review"
					cmd_transition "$task_id" "blocked" --error "Critical review threads: $triage_summary" 2>>"$SUPERVISOR_LOG" || true
					send_task_notification "$task_id" "blocked" "Critical review threads require human attention: $triage_summary" 2>>"$SUPERVISOR_LOG" || true
					return 1
					;;
				esac
			fi
		fi

		# t219: Record review_triage stage timing
		local stage_end
		stage_end=$(date +%s)
		stage_timings="${stage_timings}review_triage:$((stage_end - stage_start))s,"
	fi

	# Step 3: Merge
	if [[ "$tstatus" == "merging" ]]; then
		local stage_start
		stage_start=$(date +%s)

		if [[ "$dry_run" == "true" ]]; then
			log_info "[dry-run] Would merge PR for $task_id"
		else
			if merge_task_pr "$task_id" "$dry_run"; then
				cmd_transition "$task_id" "merged" 2>>"$SUPERVISOR_LOG" || true
				tstatus="merged"

				# t225: Rebase sibling subtask PRs after merge to prevent
				# cascading conflicts. Best-effort — failures are logged
				# but don't block the merged task's lifecycle.
				rebase_sibling_prs_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || true
			else
				cmd_transition "$task_id" "blocked" --error "Merge failed" 2>>"$SUPERVISOR_LOG" || true
				send_task_notification "$task_id" "blocked" "PR merge failed" 2>>"$SUPERVISOR_LOG" || true
				return 1
			fi
		fi

		# t219: Record merging stage timing
		local stage_end
		stage_end=$(date +%s)
		stage_timings="${stage_timings}merging:$((stage_end - stage_start))s,"
	fi

	# Step 4: Postflight + Deploy
	# t219: This step already runs deploy + verify in same pulse (no change needed)
	if [[ "$tstatus" == "merged" ]]; then
		local stage_start
		stage_start=$(date +%s)

		if [[ "$dry_run" == "false" ]]; then
			cmd_transition "$task_id" "deploying" || log_warn "Failed to transition $task_id to deploying"

			# Pull main and run postflight (non-blocking: verification only)
			run_postflight_for_task "$task_id" "$trepo" || log_warn "Postflight issue for $task_id (non-blocking)"

			# Deploy (aidevops repos only) - failure blocks deployed transition
			if ! run_deploy_for_task "$task_id" "$trepo"; then
				log_error "Deploy failed for $task_id - transitioning to failed"
				cmd_transition "$task_id" "failed" --error "Deploy (setup.sh) failed" 2>>"$SUPERVISOR_LOG" || true
				send_task_notification "$task_id" "failed" "Deploy failed after merge" 2>>"$SUPERVISOR_LOG" || true
				return 1
			fi

			# Clean up worktree and branch (non-blocking: housekeeping)
			cleanup_after_merge "$task_id" || log_warn "Worktree cleanup issue for $task_id (non-blocking)"

			# Update TODO.md (non-blocking: housekeeping)
			update_todo_on_complete "$task_id" || log_warn "TODO.md update issue for $task_id (non-blocking)"

			# Populate VERIFY.md queue for post-merge verification (t180.2)
			populate_verify_queue "$task_id" "$tpr" "$trepo" 2>>"$SUPERVISOR_LOG" || log_warn "Verify queue population issue for $task_id (non-blocking)"

			# t248: Final transition with retry logic (3 attempts: 0s, 1s, 3s)
			local deploy_retry_count=0
			local deploy_max_retries=3
			local deploy_succeeded=false
			local deploy_error=""

			while [[ "$deploy_retry_count" -lt "$deploy_max_retries" ]]; do
				if [[ "$deploy_retry_count" -gt 0 ]]; then
					local deploy_backoff=$((2 ** (deploy_retry_count - 1)))
					log_info "  Transition retry $deploy_retry_count/$deploy_max_retries after ${deploy_backoff}s backoff..."
					sleep "$deploy_backoff"
				fi

				if deploy_error=$(cmd_transition "$task_id" "deployed" 2>&1); then
					deploy_succeeded=true
					break
				fi

				deploy_retry_count=$((deploy_retry_count + 1))
				log_warn "  Transition attempt $deploy_retry_count failed: $deploy_error"
			done

			if [[ "$deploy_succeeded" == "true" ]]; then
				# Notify (best-effort, suppress errors)
				send_task_notification "$task_id" "deployed" "PR merged, deployed, worktree cleaned" 2>>"$SUPERVISOR_LOG" || true
				store_success_pattern "$task_id" "deployed" "" 2>>"$SUPERVISOR_LOG" || true
			else
				log_error "Failed to transition $task_id to deployed after $deploy_max_retries attempts: $deploy_error"
				# Task will remain in 'deploying' and Phase 4b will retry on next pulse
			fi
		else
			log_info "[dry-run] Would deploy and clean up for $task_id"
		fi

		# t219: Record deploying stage timing
		local stage_end
		stage_end=$(date +%s)
		stage_timings="${stage_timings}deploying:$((stage_end - stage_start))s,"
	fi

	# Step 4b: Auto-recover stuck deploying state (t222, t248, t263)
	# If a task is already in 'deploying' (from a prior pulse where the deploy
	# succeeded but the transition to 'deployed' failed), re-attempt the
	# transition and housekeeping steps. The deploy itself already completed
	# successfully — only the state transition was lost.
	if [[ "$tstatus" == "deploying" ]]; then
		local stage_start
		stage_start=$(date +%s)

		# t263: Check persistent recovery attempt counter to prevent infinite loops
		local escaped_id
		escaped_id=$(printf '%s' "$task_id" | sed "s/'/''/g")
		local recovery_attempts
		recovery_attempts=$(db "$SUPERVISOR_DB" "SELECT deploying_recovery_attempts FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "0")
		recovery_attempts=${recovery_attempts:-0}

		local max_global_recovery_attempts=10

		if [[ "$recovery_attempts" -ge "$max_global_recovery_attempts" ]]; then
			log_error "Task $task_id exceeded max recovery attempts ($max_global_recovery_attempts) — forcing to failed (t263)"

			# t263: Fallback direct SQL when cmd_transition fails repeatedly
			if ! cmd_transition "$task_id" "failed" --error "Exceeded max deploying recovery attempts ($max_global_recovery_attempts) — infinite loop guard triggered (t263)" 2>>"$SUPERVISOR_LOG"; then
				log_warn "cmd_transition failed, using fallback direct SQL update (t263)"
				db "$SUPERVISOR_DB" "UPDATE tasks SET status = 'failed', error = 'Exceeded max deploying recovery attempts ($max_global_recovery_attempts) — infinite loop guard + SQL fallback (t263)', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = '$escaped_id';" 2>>"$SUPERVISOR_LOG" || log_error "Fallback SQL update also failed for $task_id (t263)"
			fi

			send_task_notification "$task_id" "failed" "Exceeded max deploying recovery attempts ($max_global_recovery_attempts)" 2>>"$SUPERVISOR_LOG" || true
			return 1
		fi

		log_warn "Task $task_id stuck in deploying state — attempting auto-recovery (attempt $((recovery_attempts + 1))/$max_global_recovery_attempts) (t222, t248, t263)"

		# t263: Increment persistent recovery counter
		db "$SUPERVISOR_DB" "UPDATE tasks SET deploying_recovery_attempts = deploying_recovery_attempts + 1, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = '$escaped_id';" 2>>"$SUPERVISOR_LOG" || log_warn "Failed to increment recovery counter for $task_id (t263)"

		if [[ "$dry_run" == "false" ]]; then
			# Re-run housekeeping that may have been skipped when the prior
			# transition failed (all non-blocking, best-effort)
			cleanup_after_merge "$task_id" 2>>"$SUPERVISOR_LOG" || log_warn "Worktree cleanup issue for $task_id during recovery (non-blocking)"
			update_todo_on_complete "$task_id" 2>>"$SUPERVISOR_LOG" || log_warn "TODO.md update issue for $task_id during recovery (non-blocking)"
			populate_verify_queue "$task_id" "$tpr" "$trepo" 2>>"$SUPERVISOR_LOG" || log_warn "Verify queue population issue for $task_id during recovery (non-blocking)"

			# t248: Retry transition with exponential backoff (3 attempts: 0s, 1s, 3s)
			local retry_count=0
			local max_retries=3
			local retry_succeeded=false
			local transition_error=""

			while [[ "$retry_count" -lt "$max_retries" ]]; do
				if [[ "$retry_count" -gt 0 ]]; then
					local backoff_delay=$((2 ** (retry_count - 1)))
					log_info "  Retry $retry_count/$max_retries after ${backoff_delay}s backoff..."
					sleep "$backoff_delay"
				fi

				# Capture transition error output for debugging
				if transition_error=$(cmd_transition "$task_id" "deployed" 2>&1); then
					retry_succeeded=true
					break
				fi

				retry_count=$((retry_count + 1))
				log_warn "  Transition attempt $retry_count failed: $transition_error"
			done

			if [[ "$retry_succeeded" == "true" ]]; then
				log_success "Auto-recovered $task_id: deploying -> deployed (t222, t248, t263, attempts: $retry_count)"
				send_task_notification "$task_id" "deployed" "Auto-recovered from stuck deploying state (attempts: $retry_count)" 2>>"$SUPERVISOR_LOG" || true
				store_success_pattern "$task_id" "deployed" "" 2>>"$SUPERVISOR_LOG" || true
				write_proof_log --task "$task_id" --event "auto_recover" --stage "deploying" \
					--decision "deploying->deployed" --evidence "stuck_state_recovery,retries:$retry_count" \
					--maker "pr_lifecycle:t222:t248:t263" 2>/dev/null || true

				# t263: Reset recovery counter on success
				db "$SUPERVISOR_DB" "UPDATE tasks SET deploying_recovery_attempts = 0 WHERE id = '$escaped_id';" 2>>"$SUPERVISOR_LOG" || true
			else
				log_error "Auto-recovery failed for $task_id after $max_retries attempts — last error: $transition_error (t263)"

				# t263: Explicit error handling with fallback SQL
				# If the transition itself is invalid after retries, something is deeply wrong.
				# Transition to failed so the task doesn't stay stuck forever.
				if ! cmd_transition "$task_id" "failed" --error "Auto-recovery failed after $max_retries attempts: $transition_error (t222, t248, t263)" 2>>"$SUPERVISOR_LOG"; then
					log_warn "cmd_transition to failed also failed, using fallback direct SQL (t263)"
					db "$SUPERVISOR_DB" "UPDATE tasks SET status = 'failed', error = 'Auto-recovery failed after $max_retries attempts: $transition_error — SQL fallback used (t263)', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = '$escaped_id';" 2>>"$SUPERVISOR_LOG" || log_error "Fallback SQL update also failed for $task_id (t263)"
				fi

				send_task_notification "$task_id" "failed" "Stuck in deploying, auto-recovery failed after $max_retries attempts" 2>>"$SUPERVISOR_LOG" || true
			fi
		else
			log_info "[dry-run] Would auto-recover $task_id from deploying to deployed"
		fi

		# t222: Record recovery timing
		local stage_end
		stage_end=$(date +%s)
		stage_timings="${stage_timings}deploying_recovery:$((stage_end - stage_start))s,"
	fi

	# t219: Record total lifecycle timing and log to proof-log
	local lifecycle_end_time
	lifecycle_end_time=$(date +%s)
	local total_time
	total_time=$((lifecycle_end_time - lifecycle_start_time))
	stage_timings="${stage_timings}total:${total_time}s"

	log_success "Post-PR lifecycle complete for $task_id (status: $(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo 'unknown')) - timing: $stage_timings"

	# Record timing metrics to proof-log for pipeline latency analysis
	record_lifecycle_timing "$task_id" "$stage_timings" 2>/dev/null || true

	return 0
}

#######################################
# Fetch unresolved review threads for a PR via GitHub GraphQL API (t148.1)
#
# Bot reviews post as COMMENTED (not CHANGES_REQUESTED), so reviewDecision
# stays NONE even when there are actionable review threads. This function
# checks unresolved threads directly.
#
# $1: repo_slug (owner/repo)
# $2: pr_number
#
# Outputs JSON array of unresolved threads to stdout:
#   [{"id":"...", "path":"file.sh", "line":42, "body":"...", "author":"gemini-code-assist", "isBot":true, "createdAt":"..."}]
# Returns 0 on success, 1 on failure
#######################################
check_review_threads() {
	local repo_slug="$1"
	local pr_number="$2"

	if ! command -v gh &>/dev/null; then
		log_warn "gh CLI not found, cannot check review threads"
		echo "[]"
		return 1
	fi

	local owner repo
	owner="${repo_slug%%/*}"
	repo="${repo_slug##*/}"

	# GraphQL query to fetch all review threads with resolution status
	local graphql_query
	graphql_query='query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first: 1) {
            nodes {
              body
              author {
                login
              }
              createdAt
            }
          }
        }
      }
    }
  }
}'

	local result
	result=$(gh api graphql -f query="$graphql_query" \
		-F owner="$owner" -F repo="$repo" -F pr="$pr_number" \
		2>>"$SUPERVISOR_LOG" || echo "")

	if [[ -z "$result" ]]; then
		log_warn "GraphQL query failed for $repo_slug#$pr_number"
		echo "[]"
		return 1
	fi

	# Extract unresolved, non-outdated threads and format as JSON array
	local threads
	threads=$(echo "$result" | jq -r '
        [.data.repository.pullRequest.reviewThreads.nodes[]
         | select(.isResolved == false and .isOutdated == false)
         | {
             id: .id,
             path: .path,
             line: .line,
             body: (.comments.nodes[0].body // ""),
             author: (.comments.nodes[0].author.login // "unknown"),
             isBot: ((.comments.nodes[0].author.login // "") | test("bot$|\\[bot\\]$|gemini|coderabbit|copilot|codacy|sonar"; "i")),
             createdAt: (.comments.nodes[0].createdAt // "")
           }
        ]' 2>/dev/null || echo "[]")

	echo "$threads"
	return 0
}

#######################################
# Triage review feedback by severity (t148.2)
#
# Classifies each unresolved review thread into severity levels:
#   critical - Security vulnerabilities, data loss, crashes
#   high     - Bugs, logic errors, missing error handling
#   medium   - Code quality, performance, maintainability
#   low      - Style, naming, documentation, nits
#   dismiss  - False positives, already addressed, bot noise
#
# $1: JSON array of threads (from check_review_threads)
#
# Outputs JSON with classified threads and summary:
#   {"threads":[...with severity field...], "summary":{"critical":0,"high":1,...}, "action":"fix|merge|block"}
# Returns 0 on success
#######################################
triage_review_feedback() {
	local threads_json="$1"

	local thread_count
	thread_count=$(echo "$threads_json" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$thread_count" -eq 0 ]]; then
		echo '{"threads":[],"summary":{"critical":0,"high":0,"medium":0,"low":0,"dismiss":0},"action":"merge"}'
		return 0
	fi

	# Classify each thread using keyword heuristics
	# This avoids an AI call for most cases; AI eval is reserved for ambiguous threads
	local classified
	classified=$(echo "$threads_json" | jq '
        [.[] | . + {
            severity: (
                if (.body | test("security|vulnerab|injection|XSS|CSRF|auth bypass|privilege escalat|CVE|RCE|SSRF|secret|credential|password.*leak"; "i"))
                then "critical"
                elif (.body | test("bug|crash|data loss|race condition|deadlock|null pointer|undefined|NaN|infinite loop|memory leak|use.after.free|buffer overflow|missing error|unhandled|uncaught|panic|fatal"; "i"))
                then "high"
                elif (.body | test("performance|complexity|O\\(n|inefficient|redundant|duplicate|unused|dead code|refactor|simplif|error handling|validation|sanitiz|timeout|retry|fallback|edge case"; "i"))
                then "medium"
                elif (.body | test("nit|style|naming|typo|comment|documentation|whitespace|formatting|indentation|spelling|grammar|convention|prefer|consider|suggest|minor|optional|cosmetic"; "i"))
                then "low"
                elif (.isBot == true and (.body | test("looks good|no issues|approved|LGTM"; "i")))
                then "dismiss"
                else "medium"
                end
            )
        }]
    ' 2>/dev/null || echo "[]")

	# Count by severity
	local critical high medium low dismiss
	critical=$(echo "$classified" | jq '[.[] | select(.severity == "critical")] | length' 2>/dev/null || echo "0")
	high=$(echo "$classified" | jq '[.[] | select(.severity == "high")] | length' 2>/dev/null || echo "0")
	medium=$(echo "$classified" | jq '[.[] | select(.severity == "medium")] | length' 2>/dev/null || echo "0")
	low=$(echo "$classified" | jq '[.[] | select(.severity == "low")] | length' 2>/dev/null || echo "0")
	dismiss=$(echo "$classified" | jq '[.[] | select(.severity == "dismiss")] | length' 2>/dev/null || echo "0")

	# Determine action based on severity distribution
	local action="merge"
	if [[ "$critical" -gt 0 ]]; then
		action="block"
	elif [[ "$high" -gt 0 ]]; then
		action="fix"
	elif [[ "$medium" -gt 2 ]]; then
		action="fix"
	fi
	# low-only or dismiss-only threads: safe to merge

	# Build result JSON
	local result
	result=$(jq -n \
		--argjson threads "$classified" \
		--argjson critical "$critical" \
		--argjson high "$high" \
		--argjson medium "$medium" \
		--argjson low "$low" \
		--argjson dismiss "$dismiss" \
		--arg action "$action" \
		'{
            threads: $threads,
            summary: {critical: $critical, high: $high, medium: $medium, low: $low, dismiss: $dismiss},
            action: $action
        }' 2>/dev/null || echo '{"threads":[],"summary":{},"action":"merge"}')

	echo "$result"
	return 0
}

#######################################
# Dispatch a worker to fix review feedback for a task (t148.5)
#
# Creates a re-prompt in the task's existing worktree with context about
# the review threads that need fixing. The worker applies fixes and
# pushes to the existing PR branch.
#
# $1: task_id
# $2: triage_result JSON (from triage_review_feedback)
# Returns 0 on success, 1 on failure
#######################################
dispatch_review_fix_worker() {
	local task_id="$1"
	local triage_json="$2"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT repo, worktree, branch, pr_url, model, description
        FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local trepo tworktree tbranch tpr tmodel tdesc
	IFS='|' read -r trepo tworktree tbranch tpr tmodel tdesc <<<"$task_row"

	# Extract actionable threads (high + medium, skip low/dismiss)
	local fix_threads
	fix_threads=$(echo "$triage_json" | jq '[.threads[] | select(.severity == "critical" or .severity == "high" or .severity == "medium")]' 2>/dev/null || echo "[]")

	local fix_count
	fix_count=$(echo "$fix_threads" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$fix_count" -eq 0 ]]; then
		log_info "No actionable review threads to fix for $task_id"
		return 0
	fi

	# Build a concise fix prompt with thread details
	local thread_details
	thread_details=$(echo "$fix_threads" | jq -r '.[] | "- [\(.severity)] \(.path):\(.line // "?"): \(.body | split("\n")[0] | .[0:200])"' 2>/dev/null || echo "")

	local fix_prompt="Review feedback needs fixing for $task_id (PR: ${tpr:-unknown}).

$fix_count review thread(s) require attention:

$thread_details

Instructions:
1. Read each file mentioned and understand the review feedback
2. Apply fixes for critical and high severity issues (these are real bugs/security issues)
3. Apply fixes for medium severity issues where the feedback is valid
4. Dismiss low/nit feedback with a brief reply explaining why (if not already addressed)
5. After fixing, commit with message: fix: address review feedback for $task_id
6. Push to the existing branch ($tbranch) - do NOT create a new PR
7. Reply to resolved review threads on the PR with a brief note about the fix"

	# Determine working directory
	local work_dir="$trepo"
	if [[ -n "$tworktree" && -d "$tworktree" ]]; then
		work_dir="$tworktree"
	else
		# Worktree may have been cleaned up; recreate it
		local new_worktree
		new_worktree=$(create_task_worktree "$task_id" "$trepo" 2>/dev/null) || {
			log_error "Failed to create worktree for review fix: $task_id"
			return 1
		}
		work_dir="$new_worktree"
		# Update DB with new worktree path
		db "$SUPERVISOR_DB" "UPDATE tasks SET worktree = '$(sql_escape "$new_worktree")' WHERE id = '$escaped_id';"
	fi

	local ai_cli
	ai_cli=$(resolve_ai_cli) || return 1

	# Pre-dispatch availability check for review-fix workers (t233)
	# Previously missing — review-fix workers were spawned without any health check,
	# wasting compute when the provider was down or rate-limited.
	local health_model health_exit=0
	health_model=$(resolve_model "health" "$ai_cli")
	check_model_health "$ai_cli" "$health_model" || health_exit=$?
	if [[ "$health_exit" -ne 0 ]]; then
		case "$health_exit" in
		2)
			log_warn "Provider rate-limited for $task_id review-fix — deferring to next pulse"
			;;
		3)
			log_error "API key invalid/credits exhausted for $task_id review-fix"
			;;
		*)
			log_error "Provider unavailable for $task_id review-fix — deferring"
			;;
		esac
		return 1
	fi

	# Set up log file
	local log_dir="$SUPERVISOR_DIR/logs"
	mkdir -p "$log_dir"
	local log_file
	log_file="$log_dir/${task_id}-review-fix-$(date +%Y%m%d%H%M%S).log"

	# Pre-create log file with review-fix metadata (t183)
	{
		echo "=== REVIEW-FIX METADATA (t183) ==="
		echo "task_id=$task_id"
		echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "work_dir=$work_dir"
		echo "fix_threads=$fix_count"
		echo "=== END REVIEW-FIX METADATA ==="
		echo ""
	} >"$log_file" 2>/dev/null || true

	# Transition to dispatched for the fix cycle
	cmd_transition "$task_id" "dispatched" --log-file "$log_file" 2>>"$SUPERVISOR_LOG" || true

	log_info "Dispatching review fix worker for $task_id ($fix_count threads)"
	log_info "Working dir: $work_dir"

	# Build and execute dispatch command
	local -a cmd_parts=()
	if [[ "$ai_cli" == "opencode" ]]; then
		cmd_parts=(opencode run --format json)
		if [[ -n "$tmodel" ]]; then
			cmd_parts+=(-m "$tmodel")
		fi
		# t262: Include truncated description in review-fix session title
		local fix_title="${task_id}-review-fix"
		if [[ -n "$tdesc" ]]; then
			local short_desc="${tdesc%% -- *}"
			short_desc="${short_desc%% #*}"
			short_desc="${short_desc%% ~*}"
			if [[ ${#short_desc} -gt 25 ]]; then
				short_desc="${short_desc:0:22}..."
			fi
			fix_title="${task_id}-fix: ${short_desc}"
		fi
		cmd_parts+=(--title "$fix_title" "$fix_prompt")
	else
		cmd_parts=(claude -p "$fix_prompt" --output-format json)
	fi

	mkdir -p "$SUPERVISOR_DIR/pids"

	# Generate worker-specific MCP config with heavy indexers disabled (t221)
	local worker_xdg_config=""
	worker_xdg_config=$(generate_worker_mcp_config "$task_id" 2>/dev/null) || true

	# Write dispatch script with startup sentinel (t183)
	local dispatch_script="${SUPERVISOR_DIR}/pids/${task_id}-review-fix.sh"
	{
		echo '#!/usr/bin/env bash'
		echo "echo 'WORKER_STARTED task_id=${task_id} type=review-fix pid=\$\$ timestamp='\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "cd '${work_dir}' || { echo 'WORKER_FAILED: cd to work_dir failed: ${work_dir}'; exit 1; }"
		# Redirect worker to use MCP config with heavy indexers disabled (t221)
		if [[ -n "$worker_xdg_config" ]]; then
			echo "export XDG_CONFIG_HOME='${worker_xdg_config}'"
		fi
		printf 'exec '
		printf '%q ' "${cmd_parts[@]}"
		printf '\n'
	} >"$dispatch_script"
	chmod +x "$dispatch_script"

	# Wrapper script (t183): captures dispatch errors in log file
	# t253: Add cleanup handlers to prevent orphaned children when wrapper exits
	local wrapper_script="${SUPERVISOR_DIR}/pids/${task_id}-review-fix-wrapper.sh"
	{
		echo '#!/usr/bin/env bash'
		echo '# t253: Recursive cleanup to kill all descendant processes'
		echo '_kill_descendants_recursive() {'
		echo '  local parent_pid="$1"'
		echo '  local children'
		echo '  children=$(pgrep -P "$parent_pid" 2>/dev/null || true)'
		echo '  if [[ -n "$children" ]]; then'
		echo '    for child in $children; do'
		echo '      _kill_descendants_recursive "$child"'
		echo '    done'
		echo '  fi'
		echo '  kill -TERM "$parent_pid" 2>/dev/null || true'
		echo '}'
		echo ''
		echo 'cleanup_children() {'
		echo '  local wrapper_pid=$$'
		echo '  local children'
		echo '  children=$(pgrep -P "$wrapper_pid" 2>/dev/null || true)'
		echo '  if [[ -n "$children" ]]; then'
		echo '    # Recursively kill all descendants'
		echo '    for child in $children; do'
		echo '      _kill_descendants_recursive "$child"'
		echo '    done'
		echo '    sleep 0.5'
		echo '    # Force kill any survivors'
		echo '    for child in $children; do'
		echo '      pkill -9 -P "$child" 2>/dev/null || true'
		echo '      kill -9 "$child" 2>/dev/null || true'
		echo '    done'
		echo '  fi'
		echo '}'
		echo '# Register cleanup on EXIT, INT, TERM (KILL cannot be trapped)'
		echo 'trap cleanup_children EXIT INT TERM'
		echo ''
		echo "'${dispatch_script}' >> '${log_file}' 2>&1"
		echo "rc=\$?"
		echo "echo \"EXIT:\${rc}\" >> '${log_file}'"
		echo "if [ \$rc -ne 0 ]; then"
		echo "  echo \"WORKER_DISPATCH_ERROR: review-fix script exited with code \${rc}\" >> '${log_file}'"
		echo "fi"
	} >"$wrapper_script"
	chmod +x "$wrapper_script"

	# t253: Use setsid if available (Linux) for process group isolation
	if command -v setsid &>/dev/null; then
		nohup setsid bash "${wrapper_script}" &>/dev/null &
	else
		nohup bash "${wrapper_script}" &>/dev/null &
	fi
	local worker_pid=$!
	disown "$worker_pid" 2>/dev/null || true

	echo "$worker_pid" >"$SUPERVISOR_DIR/pids/${task_id}.pid"

	cmd_transition "$task_id" "running" --session "pid:$worker_pid" 2>>"$SUPERVISOR_LOG" || true

	log_success "Dispatched review fix worker for $task_id (PID: $worker_pid, $fix_count threads)"
	return 0
}

#######################################
# Dismiss bot reviews that are blocking PR merge (t226)
# Only dismisses reviews from known bot accounts (coderabbitai, gemini-code-assist)
# Returns: 0 if any reviews dismissed, 1 if none found or error
#######################################
dismiss_bot_reviews() {
	local pr_number="$1"
	local repo_slug="$2"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		log_warn "dismiss_bot_reviews: missing pr_number or repo_slug"
		return 1
	fi

	# Get all reviews for the PR
	local reviews_json
	reviews_json=$(gh api "repos/${repo_slug}/pulls/${pr_number}/reviews" 2>>"$SUPERVISOR_LOG" || echo "[]")

	if [[ -z "$reviews_json" || "$reviews_json" == "[]" ]]; then
		log_debug "dismiss_bot_reviews: no reviews found for PR #${pr_number}"
		return 1
	fi

	# Find bot reviews with CHANGES_REQUESTED state
	local bot_reviews
	bot_reviews=$(echo "$reviews_json" | jq -r '.[] | select(.state == "CHANGES_REQUESTED" and (.user.login == "coderabbitai" or .user.login == "gemini-code-assist[bot]")) | .id' 2>/dev/null || echo "")

	if [[ -z "$bot_reviews" ]]; then
		log_debug "dismiss_bot_reviews: no blocking bot reviews found for PR #${pr_number}"
		return 1
	fi

	local dismissed_count=0
	while IFS= read -r review_id; do
		if [[ -n "$review_id" ]]; then
			log_info "Dismissing bot review #${review_id} on PR #${pr_number}"
			if gh api -X PUT "repos/${repo_slug}/pulls/${pr_number}/reviews/${review_id}/dismissals" \
				-f message="Auto-dismissed: bot review does not block autonomous pipeline" \
				-f event="DISMISS" 2>>"$SUPERVISOR_LOG"; then
				((dismissed_count++))
				log_success "Dismissed bot review #${review_id}"
			else
				log_warn "Failed to dismiss bot review #${review_id}"
			fi
		fi
	done <<<"$bot_reviews"

	if [[ "$dismissed_count" -gt 0 ]]; then
		log_success "Dismissed ${dismissed_count} bot review(s) on PR #${pr_number}"
		return 0
	fi

	return 1
}

#######################################
# Check PR CI and review status for a task
# Returns: status|mergeStateStatus (e.g., "ci_pending|BEHIND", "ready_to_merge|CLEAN")
# Status values: ready_to_merge, unstable_sonarcloud, ci_pending, ci_failed, changes_requested, draft, no_pr
# t227: unstable_sonarcloud = SonarCloud GH Action passed but external quality gate failed
# t226: auto-dismiss bot reviews that block merge
# t298: Return mergeStateStatus to enable auto-rebase for BEHIND/DIRTY PRs
#######################################
check_pr_status() {
	local task_id="$1"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local pr_url
	pr_url=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$escaped_id';")

	# If no PR URL stored, discover via centralized link_pr_to_task() (t232)
	if [[ -z "$pr_url" || "$pr_url" == "no_pr" || "$pr_url" == "task_only" ]]; then
		pr_url=$(link_pr_to_task "$task_id" --caller "check_pr_status") || pr_url=""
		if [[ -z "$pr_url" ]]; then
			echo "no_pr|UNKNOWN"
			return 0
		fi
	fi

	# Extract owner/repo and PR number from URL (t232)
	local parsed_pr pr_number repo_slug
	parsed_pr=$(parse_pr_url "$pr_url") || parsed_pr=""
	if [[ -z "$parsed_pr" ]]; then
		echo "no_pr|UNKNOWN"
		return 0
	fi
	repo_slug="${parsed_pr%%|*}"
	pr_number="${parsed_pr##*|}"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		echo "no_pr|UNKNOWN"
		return 0
	fi

	# Check PR state
	# t277: Use mergeStateStatus to respect GitHub's required vs non-required check distinction
	# Note: mergeable field must be queried to populate mergeStateStatus correctly
	local pr_json
	pr_json=$(gh pr view "$pr_number" --repo "$repo_slug" --json state,isDraft,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup 2>>"$SUPERVISOR_LOG" || echo "")

	if [[ -z "$pr_json" ]]; then
		echo "no_pr|UNKNOWN"
		return 0
	fi

	local pr_state
	pr_state=$(echo "$pr_json" | jq -r '.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

	# Already merged
	if [[ "$pr_state" == "MERGED" ]]; then
		echo "already_merged|MERGED"
		return 0
	fi

	# Closed without merge
	if [[ "$pr_state" == "CLOSED" ]]; then
		echo "closed|CLOSED"
		return 0
	fi

	# Draft PR
	local is_draft
	is_draft=$(echo "$pr_json" | jq -r '.isDraft // false' 2>/dev/null || echo "false")
	if [[ "$is_draft" == "true" ]]; then
		echo "draft|DRAFT"
		return 0
	fi

	# t277: Check CI status using mergeStateStatus (respects required checks only)
	# mergeStateStatus values: BEHIND, BLOCKED, CLEAN, DIRTY, DRAFT, HAS_HOOKS, UNKNOWN, UNSTABLE
	local merge_state
	merge_state=$(echo "$pr_json" | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

	# t277: GitHub lazy-loads mergeStateStatus — first query often returns UNKNOWN.
	# Re-query once (the first call triggers computation, second returns the result).
	if [[ "$merge_state" == "UNKNOWN" ]]; then
		sleep 2
		local pr_json_retry
		pr_json_retry=$(gh pr view "$pr_number" --repo "$repo_slug" --json mergeable,mergeStateStatus 2>>"$SUPERVISOR_LOG" || echo "")
		if [[ -n "$pr_json_retry" ]]; then
			merge_state=$(echo "$pr_json_retry" | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
		fi
	fi

	# BLOCKED = required checks failed/pending, OR required reviews missing
	# UNSTABLE = non-required checks failed but required checks passed
	# CLEAN = all required checks passed, ready to merge
	# BEHIND = needs rebase/merge with base branch
	# DIRTY = merge conflicts

	# Hoist check_rollup above case to avoid duplicate declarations
	local check_rollup
	check_rollup=$(echo "$pr_json" | jq -r '.statusCheckRollup // []' 2>/dev/null || echo "[]")

	case "$merge_state" in
	BLOCKED)
		# BLOCKED can mean: required checks failed/pending, OR required reviews
		# are missing. We must distinguish CI blocks from review blocks.
		# Note: gh pr view --json statusCheckRollup does NOT include isRequired,
		# so we check for pending/failed checks and fall through if none found
		# (the block is likely due to required reviews, handled below).

		if [[ "$check_rollup" != "[]" && "$check_rollup" != "null" ]]; then
			local has_pending
			has_pending=$(echo "$check_rollup" | jq '[.[] | select(.status == "IN_PROGRESS" or .status == "QUEUED" or .status == "PENDING")] | length' 2>/dev/null || echo "0")

			if [[ "$has_pending" -gt 0 ]]; then
				echo "ci_pending|$merge_state"
				return 0
			fi

			# Check for explicitly failed checks (conclusion or state)
			local has_failed
			has_failed=$(echo "$check_rollup" | jq '[.[] | select((.conclusion | test("FAILURE|TIMED_OUT|ACTION_REQUIRED")) or .state == "FAILURE" or .state == "ERROR")] | length' 2>/dev/null || echo "0")

			if [[ "$has_failed" -gt 0 ]]; then
				echo "ci_failed|$merge_state"
				return 0
			fi
		fi

		# No CI failures or pending checks detected — BLOCKED is likely due to
		# required reviews or other non-CI branch protection rules.
		# Fall through to review check below.
		;;
	UNSTABLE)
		# t227: Non-required checks failed (e.g., CodeFactor, CodeRabbit)
		# Check for SonarCloud pattern specifically

		if [[ "$check_rollup" != "[]" && "$check_rollup" != "null" ]]; then
			local sonar_action_pass
			sonar_action_pass=$(echo "$check_rollup" | jq '[.[] | select(.name == "SonarCloud Analysis" and .conclusion == "SUCCESS")] | length' 2>/dev/null || echo "0")
			local sonar_gate_fail
			sonar_gate_fail=$(echo "$check_rollup" | jq '[.[] | select(.name == "SonarCloud Code Analysis" and .conclusion == "FAILURE")] | length' 2>/dev/null || echo "0")

			if [[ "$sonar_action_pass" -gt 0 && "$sonar_gate_fail" -gt 0 ]]; then
				echo "unstable_sonarcloud|$merge_state"
				return 0
			fi
		fi

		# Other non-required checks failed, but PR is still mergeable
		# Treat as ready since required checks passed
		# Fall through to review check
		;;
	CLEAN)
		# All required checks passed, fall through to review check
		;;
	BEHIND | DIRTY)
		# t298: Needs rebase or has conflicts - return merge_state for auto-rebase
		echo "ci_pending|$merge_state"
		return 0
		;;
	*)
		# UNKNOWN (even after retry), HAS_HOOKS — use mergeable as fallback.
		# Do NOT check individual statusCheckRollup items here because that
		# conflates non-required pending checks with actual blockers (the
		# original bug this fix addresses).
		local mergeable_state
		mergeable_state=$(echo "$pr_json" | jq -r '.mergeable // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

		case "$mergeable_state" in
		MERGEABLE)
			# GitHub says it's mergeable — fall through to review check
			;;
		CONFLICTING)
			echo "ci_pending|CONFLICTING"
			return 0
			;;
		*)
			# UNKNOWN mergeable too — report as pending, will resolve next pulse
			echo "ci_pending|$merge_state"
			return 0
			;;
		esac
		;;
	esac

	# Check review status
	local review_decision
	review_decision=$(echo "$pr_json" | jq -r '.reviewDecision // "NONE"' 2>/dev/null || echo "NONE")

	if [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
		# t226: Try to auto-dismiss bot reviews before declaring changes_requested
		log_info "PR #${pr_number} has CHANGES_REQUESTED — checking for bot reviews to dismiss"
		if dismiss_bot_reviews "$pr_number" "$repo_slug"; then
			# Re-fetch PR status after dismissal
			log_info "Re-checking PR #${pr_number} status after dismissing bot reviews"
			pr_json=$(gh pr view "$pr_number" --repo "$repo_slug" --json state,isDraft,reviewDecision,statusCheckRollup 2>>"$SUPERVISOR_LOG" || echo "")
			review_decision=$(echo "$pr_json" | jq -r '.reviewDecision // "NONE"' 2>/dev/null || echo "NONE")

			# If still CHANGES_REQUESTED after dismissal, there are human reviews blocking
			if [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
				log_warn "PR #${pr_number} still has CHANGES_REQUESTED after dismissing bot reviews (human reviews present)"
				echo "changes_requested|$merge_state"
				return 0
			else
				log_success "PR #${pr_number} unblocked after dismissing bot reviews"
				# Fall through to ready_to_merge check
			fi
		else
			# No bot reviews to dismiss, must be human reviews
			log_info "PR #${pr_number} has CHANGES_REQUESTED from human reviewers (not auto-dismissing)"
			echo "changes_requested|$merge_state"
			return 0
		fi
	fi

	# CI passed, no blocking reviews
	echo "ready_to_merge|$merge_state"
	return 0
}

#######################################
# Scan for orphaned PRs — PRs that workers created but the supervisor
# missed during evaluation (t210, t216).
#
# Scenarios this catches:
#   - Worker created PR but exited without FULL_LOOP_COMPLETE signal
#   - Worker used a non-standard branch name not in the DB branch column
#   - evaluate_worker() fallback PR detection failed (API timeout, etc.)
#   - Task stuck in failed/blocked/retrying with a valid PR on GitHub
#   - Tasks evaluated by Phase 4b DB orphan detection (no eager scan)
#
# Strategy:
#   1. Find tasks in non-terminal states that have no PR URL (or no_pr/task_only)
#   2. For each unique repo, do a single bulk gh pr list call
#   3. Match PRs to tasks by task ID in title or branch name
#   4. Link matched PRs and transition tasks to complete
#
# Throttled: runs at most every 10 minutes (uses timestamp file).
# Called from cmd_pulse() Phase 6 as a broad sweep.
# Note: Phase 1 now runs scan_orphaned_pr_for_task() eagerly after
# each worker evaluation (t216), so this broad sweep is a safety net.
#######################################
scan_orphaned_prs() {
	local batch_id="${1:-}"

	ensure_db

	# Throttle: run at most every 10 minutes to avoid excessive GH API calls
	local scan_interval=600 # seconds (10 min)
	local scan_stamp="$SUPERVISOR_DIR/orphan-pr-scan-last-run"
	local now_epoch
	now_epoch=$(date +%s)
	local last_run=0
	if [[ -f "$scan_stamp" ]]; then
		last_run=$(cat "$scan_stamp" 2>/dev/null || echo 0)
	fi
	local elapsed=$((now_epoch - last_run))
	if [[ "$elapsed" -lt "$scan_interval" ]]; then
		local remaining=$((scan_interval - elapsed))
		log_verbose "  Phase 6: Orphaned PR scan skipped (${remaining}s until next run)"
		return 0
	fi

	# Find tasks that might have orphaned PRs:
	# - Status indicates work was done but no PR linked
	# - pr_url is NULL, empty, 'no_pr', 'task_only', or 'task_obsolete'
	# - Includes terminal states (deployed, merged, verified) to catch manually merged PRs (t260)
	local where_clause="status IN ('failed', 'blocked', 'retrying', 'complete', 'running', 'evaluating', 'deployed', 'merged', 'verified')
        AND (pr_url IS NULL OR pr_url = '' OR pr_url = 'no_pr' OR pr_url = 'task_only' OR pr_url = 'task_obsolete')"
	if [[ -n "$batch_id" ]]; then
		where_clause="$where_clause AND id IN (SELECT task_id FROM batch_tasks WHERE batch_id = '$(sql_escape "$batch_id")')"
	fi

	local candidate_tasks
	candidate_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, repo, branch FROM tasks
        WHERE $where_clause
        ORDER BY updated_at DESC;
    " 2>/dev/null || echo "")

	if [[ -z "$candidate_tasks" ]]; then
		echo "$now_epoch" >"$scan_stamp"
		log_verbose "  Phase 6: Orphaned PR scan — no candidate tasks"
		return 0
	fi

	# Group tasks by repo to minimise API calls (one gh pr list per repo)
	local linked_count=0
	local scanned_repos=0

	# Collect unique repos from candidate tasks
	local unique_repos=""
	while IFS='|' read -r tid trepo tbranch; do
		[[ -n "$trepo" ]] || continue
		# Deduplicate repos (bash 3.2 compatible — no associative arrays)
		case "|${unique_repos}|" in
		*"|${trepo}|"*) ;; # already seen
		*) unique_repos="${unique_repos:+${unique_repos}|}${trepo}" ;;
		esac
	done <<<"$candidate_tasks"

	# For each unique repo, fetch open PRs and match against task IDs
	while IFS='|' read -r repo_path; do
		[[ -n "$repo_path" && -d "$repo_path" ]] || continue

		local repo_slug
		repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")
		if [[ -z "$repo_slug" ]]; then
			log_verbose "  Phase 6: Cannot determine repo slug for $repo_path — skipping"
			continue
		fi

		# Fetch all open PRs for this repo in a single API call
		# Include title, headRefName, and url for matching
		local pr_list
		pr_list=$(gh pr list --repo "$repo_slug" --state open --limit 100 \
			--json number,title,headRefName,url 2>>"$SUPERVISOR_LOG" || echo "")

		if [[ -z "$pr_list" || "$pr_list" == "[]" ]]; then
			scanned_repos=$((scanned_repos + 1))
			continue
		fi

		# Also check recently merged PRs (last 7 days) — workers may have
		# created PRs that were auto-merged or manually merged
		local merged_pr_list
		merged_pr_list=$(gh pr list --repo "$repo_slug" --state merged --limit 50 \
			--json number,title,headRefName,url 2>>"$SUPERVISOR_LOG" || echo "")

		# Combine open and merged PR lists
		local all_prs
		if [[ -n "$merged_pr_list" && "$merged_pr_list" != "[]" ]]; then
			# Merge the two JSON arrays
			all_prs=$(echo "$pr_list" "$merged_pr_list" | jq -s 'add' 2>/dev/null || echo "$pr_list")
		else
			all_prs="$pr_list"
		fi

		# For each candidate task in this repo, check if any PR matches
		while IFS='|' read -r tid trepo tbranch; do
			[[ -n "$tid" && "$trepo" == "$repo_path" ]] || continue

			# Check if any PR references this task ID in title or branch
			# Uses jq to filter — word boundary matching via regex
			local matched_pr_url
			matched_pr_url=$(echo "$all_prs" | jq -r --arg tid "$tid" '
                .[] | select(
                    (.title | test("\\b" + $tid + "\\b"; "i")) or
                    (.headRefName | test("\\b" + $tid + "\\b"; "i"))
                ) | .url
            ' 2>/dev/null | head -1 || echo "")

			if [[ -n "$matched_pr_url" ]]; then
				# Validate, persist, and transition via centralized link_pr_to_task() (t232)
				if link_pr_to_task "$tid" --url "$matched_pr_url" --transition --notify \
					--caller "scan_orphaned_prs" 2>>"${SUPERVISOR_LOG:-/dev/null}"; then
					linked_count=$((linked_count + 1))
				fi
			fi
		done <<<"$candidate_tasks"

		scanned_repos=$((scanned_repos + 1))
	done <<<"$(echo "$unique_repos" | tr '|' '\n')"

	# Update throttle timestamp
	echo "$now_epoch" >"$scan_stamp"

	if [[ "$linked_count" -gt 0 ]]; then
		log_success "  Phase 6: Orphaned PR scan — linked $linked_count PRs across $scanned_repos repos"
	else
		log_verbose "  Phase 6: Orphaned PR scan — no orphaned PRs found ($scanned_repos repos scanned)"
	fi

	return 0
}

#######################################
# Eager orphaned PR scan for a single task (t216).
#
# Called immediately after worker evaluation when the outcome is
# retry/failed/blocked and no PR was linked. Unlike scan_orphaned_prs()
# which is a throttled batch sweep (Phase 6), this does a targeted
# single-task lookup — one repo, one API call — with no throttle.
#
# This catches the common case where a worker created a PR but exited
# without the FULL_LOOP_COMPLETE signal, and evaluate_worker()'s
# fallback PR detection missed it (API timeout, non-standard branch, etc.).
#
# $1: task_id
#
# Returns 0 on success. Sets pr_url in DB and transitions task to
# complete if a matching PR is found.
#######################################
scan_orphaned_pr_for_task() {
	local task_id="$1"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Get task details
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, repo, branch, pr_url FROM tasks
        WHERE id = '$escaped_id';
    " 2>/dev/null || echo "")

	if [[ -z "$task_row" ]]; then
		return 0
	fi

	local tstatus trepo tbranch tpr_url
	IFS='|' read -r tstatus trepo tbranch tpr_url <<<"$task_row"

	# Skip if PR already linked (not orphaned)
	if [[ -n "$tpr_url" && "$tpr_url" != "no_pr" && "$tpr_url" != "task_only" && "$tpr_url" != "task_obsolete" && "$tpr_url" != "" ]]; then
		return 0
	fi

	# Need a repo to scan
	if [[ -z "$trepo" || ! -d "$trepo" ]]; then
		return 0
	fi

	local repo_slug
	repo_slug=$(detect_repo_slug "$trepo" 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		return 0
	fi

	# Fetch open PRs for this repo (single API call)
	local pr_list
	pr_list=$(gh pr list --repo "$repo_slug" --state open --limit 100 \
		--json number,title,headRefName,url 2>>"$SUPERVISOR_LOG" || echo "")

	# Also check recently merged PRs
	local merged_pr_list
	merged_pr_list=$(gh pr list --repo "$repo_slug" --state merged --limit 50 \
		--json number,title,headRefName,url 2>>"$SUPERVISOR_LOG" || echo "")

	# Combine open and merged PR lists
	local all_prs
	if [[ -n "$merged_pr_list" && "$merged_pr_list" != "[]" && -n "$pr_list" && "$pr_list" != "[]" ]]; then
		all_prs=$(echo "$pr_list" "$merged_pr_list" | jq -s 'add' 2>/dev/null || echo "$pr_list")
	elif [[ -n "$pr_list" && "$pr_list" != "[]" ]]; then
		all_prs="$pr_list"
	elif [[ -n "$merged_pr_list" && "$merged_pr_list" != "[]" ]]; then
		all_prs="$merged_pr_list"
	else
		return 0
	fi

	# Match PRs to this task by task ID in title or branch name
	local matched_pr_url
	matched_pr_url=$(echo "$all_prs" | jq -r --arg tid "$task_id" '
        .[] | select(
            (.title | test("\\b" + $tid + "\\b"; "i")) or
            (.headRefName | test("\\b" + $tid + "\\b"; "i"))
        ) | .url
    ' 2>/dev/null | head -1 || echo "")

	if [[ -z "$matched_pr_url" ]]; then
		return 0
	fi

	# Validate, persist, and optionally transition via centralized link_pr_to_task() (t232)
	link_pr_to_task "$task_id" --url "$matched_pr_url" --transition --notify \
		--caller "scan_orphaned_pr_for_task" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true

	return 0
}

#######################################
# Command: pr-check - check PR CI/review status for a task
#######################################
cmd_pr_check() {
	local task_id=""

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh pr-check <task_id>"
		return 1
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local pr_url
	pr_url=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$escaped_id';")

	echo -e "${BOLD}=== PR Check: $task_id ===${NC}"
	echo "  PR URL: ${pr_url:-none}"

	local status
	status=$(check_pr_status "$task_id")
	local color="$NC"
	case "$status" in
	ready_to_merge) color="$GREEN" ;;
	ci_pending | draft) color="$YELLOW" ;;
	ci_failed | changes_requested | closed) color="$RED" ;;
	already_merged) color="$CYAN" ;;
	esac
	echo -e "  Status: ${color}${status}${NC}"

	return 0
}

#######################################
# Get sibling subtasks for a given task (t225)
# Siblings share the same parent ID (e.g., t215.1, t215.2, t215.3 are siblings)
# Returns pipe-separated rows: id|status|pr_url|branch|worktree|repo
# Args: task_id [exclude_self]
#######################################
get_sibling_tasks() {
	local task_id="$1"
	local exclude_self="${2:-true}"

	# Extract parent ID: t215.3 -> t215, t100.1.2 -> t100.1
	local parent_id=""
	if [[ "$task_id" =~ ^(t[0-9]+(\.[0-9]+)*)\.[0-9]+$ ]]; then
		parent_id="${BASH_REMATCH[1]}"
	else
		# Not a subtask (no dot notation) — no siblings
		return 0
	fi

	ensure_db

	local escaped_parent
	escaped_parent=$(sql_escape "$parent_id")

	# Find all tasks whose ID starts with parent_id followed by a dot and a number
	# e.g., parent t215 matches t215.1, t215.2, etc. but not t2150 or t215abc
	local where_clause="t.id LIKE '${escaped_parent}.%' AND t.id GLOB '${escaped_parent}.[0-9]*'"
	if [[ "$exclude_self" == "true" ]]; then
		local escaped_id
		escaped_id=$(sql_escape "$task_id")
		where_clause="$where_clause AND t.id != '$escaped_id'"
	fi

	db -separator '|' "$SUPERVISOR_DB" "
        SELECT t.id, t.status, t.pr_url, t.branch, t.worktree, t.repo
        FROM tasks t
        WHERE $where_clause
        ORDER BY t.id ASC;
    "
	return 0
}

#######################################
# AI-assisted merge conflict resolution during rebase (t302)
# When a rebase hits conflicts, uses the AI CLI to resolve each
# conflicting file, then continues the rebase.
#
# Args:
#   $1: git_dir — the git working directory (repo or worktree)
#   $2: task_id — for logging
#
# Returns: 0 if all conflicts resolved, 1 if resolution failed
#######################################
resolve_rebase_conflicts() {
	local git_dir="$1"
	local task_id="$2"

	# Get list of conflicting files
	local conflicting_files
	conflicting_files=$(git -C "$git_dir" diff --name-only --diff-filter=U 2>/dev/null || true)

	if [[ -z "$conflicting_files" ]]; then
		log_warn "resolve_rebase_conflicts: no conflicting files found for $task_id"
		return 1
	fi

	local file_count
	file_count=$(echo "$conflicting_files" | wc -l | tr -d ' ')
	log_info "resolve_rebase_conflicts: $file_count conflicting file(s) for $task_id"

	# Resolve AI CLI
	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null || echo "")
	if [[ -z "$ai_cli" ]]; then
		log_warn "resolve_rebase_conflicts: AI CLI not available — cannot resolve conflicts"
		return 1
	fi

	# Process each conflicting file
	local resolved_count=0
	local failed_files=""
	while IFS= read -r conflict_file; do
		[[ -z "$conflict_file" ]] && continue

		local full_path="$git_dir/$conflict_file"
		if [[ ! -f "$full_path" ]]; then
			log_warn "resolve_rebase_conflicts: file not found: $conflict_file"
			failed_files="${failed_files}${failed_files:+, }${conflict_file}"
			continue
		fi

		log_info "  Resolving: $conflict_file"

		# Use AI CLI to resolve the conflict
		local resolve_prompt
		resolve_prompt="You are resolving a git rebase merge conflict in: $full_path

RULES:
1. Read the file — it contains git conflict markers (<<<<<<<, =======, >>>>>>>)
2. Resolve ALL conflict blocks by combining both sides' intent intelligently
3. For code: keep both sides' changes if they don't contradict; if they do, prefer the feature branch (theirs/HEAD) for new functionality and main (upstream) for structural changes
4. For config/docs: merge both additions
5. Remove ALL conflict markers — the file must be clean
6. Write the resolved file back to the SAME path
7. Do NOT modify any code outside conflict markers
8. Do NOT add comments explaining the resolution
9. After writing, run: git -C \"$git_dir\" add \"$conflict_file\"
10. Output ONLY 'RESOLVED' if successful or 'FAILED: reason' if not"

		# Run AI CLI — output is not used directly; the CLI writes the resolved file
		$ai_cli run --format json --title "resolve-conflict-${task_id}-$(basename "$conflict_file")" "$resolve_prompt" 2>>"$SUPERVISOR_LOG" || true

		# Check if the file was resolved (no more conflict markers)
		if git -C "$git_dir" diff --check -- "$conflict_file" 2>/dev/null; then
			# diff --check returns 0 if no conflict markers remain
			resolved_count=$((resolved_count + 1))
			log_info "  Resolved: $conflict_file"
		elif ! grep -q '<<<<<<<' "$full_path" 2>/dev/null; then
			# Fallback check: no conflict markers in file
			# Ensure it is staged
			git -C "$git_dir" add "$conflict_file" 2>>"$SUPERVISOR_LOG" || true
			resolved_count=$((resolved_count + 1))
			log_info "  Resolved: $conflict_file"
		else
			log_warn "  Failed to resolve: $conflict_file (conflict markers remain)"
			failed_files="${failed_files}${failed_files:+, }${conflict_file}"
		fi
	done <<<"$conflicting_files"

	if [[ -n "$failed_files" ]]; then
		log_warn "resolve_rebase_conflicts: failed to resolve: $failed_files"
		return 1
	fi

	log_success "resolve_rebase_conflicts: resolved $resolved_count/$file_count file(s) for $task_id"
	return 0
}
#######################################
# Rebase a single PR branch onto updated main (t225, t302)
# Used after merging a sibling's PR to prevent cascading conflicts.
# Operates on the worktree if available, otherwise creates a temp worktree.
# On conflict, uses escalating resolution: plain -> -Xtheirs -> AI CLI (t302).
# Args: task_id
# Returns: 0 on success, 1 on rebase failure, 2 on force-push failure
#######################################
rebase_sibling_pr() {
	local task_id="$1"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT branch, worktree, repo, pr_url FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_warn "rebase_sibling_pr: task $task_id not found in DB"
		return 1
	fi

	local tbranch tworktree trepo tpr
	IFS='|' read -r tbranch tworktree trepo tpr <<<"$task_row"

	if [[ -z "$tbranch" ]]; then
		log_warn "rebase_sibling_pr: no branch recorded for $task_id"
		return 1
	fi

	if [[ -z "$trepo" || ! -d "$trepo/.git" ]]; then
		log_warn "rebase_sibling_pr: repo not found for $task_id ($trepo)"
		return 1
	fi

	# Determine the git directory to operate in
	local git_dir="$trepo"
	local use_worktree=false
	if [[ -n "$tworktree" && -d "$tworktree" ]]; then
		git_dir="$tworktree"
		use_worktree=true
	fi

	log_info "rebase_sibling_pr: rebasing $task_id ($tbranch) onto main..."

	# Fetch latest main
	if ! git -C "$trepo" fetch origin main 2>>"$SUPERVISOR_LOG"; then
		log_warn "rebase_sibling_pr: failed to fetch origin main for $task_id"
		return 1
	fi

	if [[ "$use_worktree" == "true" ]]; then
		# Worktree is already on the branch — rebase in place
		if ! git -C "$git_dir" rebase origin/main 2>>"$SUPERVISOR_LOG"; then
			log_warn "rebase_sibling_pr: rebase conflict for $task_id — attempting AI resolution"
			# Try AI-assisted conflict resolution before aborting
			if resolve_rebase_conflicts "$git_dir" "$task_id"; then
				log_info "rebase_sibling_pr: AI resolved conflicts for $task_id — continuing rebase"
				if git -C "$git_dir" rebase --continue 2>>"$SUPERVISOR_LOG"; then
					log_success "rebase_sibling_pr: rebase completed after AI resolution for $task_id"
				else
					log_warn "rebase_sibling_pr: rebase --continue failed after AI resolution for $task_id"
					git -C "$git_dir" rebase --abort 2>>"$SUPERVISOR_LOG" || true
					return 1
				fi
			else
				log_warn "rebase_sibling_pr: AI resolution failed for $task_id — aborting"
				git -C "$git_dir" rebase --abort 2>>"$SUPERVISOR_LOG" || true
				return 1
			fi
		fi
	else
		# No worktree — checkout branch in main repo temporarily
		# This is less ideal but handles edge cases where worktree was cleaned up
		local current_branch
		current_branch=$(git -C "$git_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

		if ! git -C "$git_dir" checkout "$tbranch" 2>>"$SUPERVISOR_LOG"; then
			log_warn "rebase_sibling_pr: cannot checkout $tbranch for $task_id"
			return 1
		fi

		if ! git -C "$git_dir" rebase origin/main 2>>"$SUPERVISOR_LOG"; then
			log_warn "rebase_sibling_pr: rebase conflict for $task_id — attempting AI resolution"
			# Try AI-assisted conflict resolution before aborting
			if resolve_rebase_conflicts "$git_dir" "$task_id"; then
				log_info "rebase_sibling_pr: AI resolved conflicts for $task_id — continuing rebase"
				if git -C "$git_dir" rebase --continue 2>>"$SUPERVISOR_LOG"; then
					log_success "rebase_sibling_pr: rebase completed after AI resolution for $task_id"
				else
					log_warn "rebase_sibling_pr: rebase --continue failed after AI resolution for $task_id"
					git -C "$git_dir" rebase --abort 2>>"$SUPERVISOR_LOG" || true
					# Return to original branch
					git -C "$git_dir" checkout "${current_branch:-main}" 2>>"$SUPERVISOR_LOG" || true
					return 1
				fi
			else
				log_warn "rebase_sibling_pr: AI resolution failed for $task_id — aborting"
				git -C "$git_dir" rebase --abort 2>>"$SUPERVISOR_LOG" || true
				# Return to original branch
				git -C "$git_dir" checkout "${current_branch:-main}" 2>>"$SUPERVISOR_LOG" || true
				return 1
			fi
		fi

		# Return to original branch
		git -C "$git_dir" checkout "${current_branch:-main}" 2>>"$SUPERVISOR_LOG" || true
	fi

	# Force-push the rebased branch (required after rebase)
	if ! git -C "$git_dir" push --force-with-lease origin "$tbranch" 2>>"$SUPERVISOR_LOG"; then
		log_warn "rebase_sibling_pr: force-push failed for $task_id ($tbranch)"
		return 2
	fi

	log_success "rebase_sibling_pr: $task_id ($tbranch) rebased onto main and pushed"
	return 0
}

#######################################
# Rebase all sibling PRs after a merge (t225)
# Called after a subtask's PR is merged to prevent cascading conflicts
# in remaining sibling subtasks.
# Args: merged_task_id
# Returns: 0 (best-effort — individual failures are logged but don't block)
#######################################
rebase_sibling_prs_after_merge() {
	local merged_task_id="$1"

	local siblings
	siblings=$(get_sibling_tasks "$merged_task_id" "true")

	if [[ -z "$siblings" ]]; then
		return 0
	fi

	local rebase_count=0
	local fail_count=0
	local skip_count=0

	while IFS='|' read -r sid sstatus spr sbranch sworktree srepo; do
		# Only rebase siblings that have open PRs and are in states where
		# their branch is still active (not yet merged/deployed/cancelled)
		case "$sstatus" in
		complete | pr_review | review_triage | merging | running | evaluating | retrying | queued | dispatched)
			# These states have active branches that need rebasing
			;;
		*)
			# merged, deployed, verified, blocked, failed, cancelled — skip
			log_verbose "  rebase_siblings: skipping $sid (status: $sstatus)"
			skip_count=$((skip_count + 1))
			continue
			;;
		esac

		if [[ -z "$sbranch" ]]; then
			log_verbose "  rebase_siblings: skipping $sid (no branch)"
			skip_count=$((skip_count + 1))
			continue
		fi

		if rebase_sibling_pr "$sid"; then
			rebase_count=$((rebase_count + 1))
		else
			fail_count=$((fail_count + 1))
			log_warn "  rebase_siblings: failed to rebase $sid (non-blocking)"
		fi
	done <<<"$siblings"

	if [[ "$rebase_count" -gt 0 || "$fail_count" -gt 0 ]]; then
		log_info "rebase_siblings after $merged_task_id: rebased=$rebase_count failed=$fail_count skipped=$skip_count"
	fi

	return 0
}

#######################################
# Merge a PR for a task (squash merge)
# Returns 0 on success, 1 on failure
#######################################
merge_task_pr() {
	local task_id="$1"
	local dry_run="${2:-false}"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT pr_url, worktree, repo, branch FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local tpr tworktree trepo tbranch
	IFS='|' read -r tpr tworktree trepo tbranch <<<"$task_row"

	if [[ -z "$tpr" || "$tpr" == "no_pr" || "$tpr" == "task_only" ]]; then
		log_error "No PR URL for task $task_id"
		return 1
	fi

	# t232: Use centralized parse_pr_url() for URL parsing
	local parsed_merge pr_number repo_slug
	parsed_merge=$(parse_pr_url "$tpr") || parsed_merge=""
	if [[ -z "$parsed_merge" ]]; then
		log_error "Cannot parse PR URL: $tpr"
		return 1
	fi
	repo_slug="${parsed_merge%%|*}"
	pr_number="${parsed_merge##*|}"

	# Defense-in-depth: validate PR belongs to this task before merging (t223).
	# Prevents merging the wrong PR if cross-contamination occurred upstream.
	local merge_validated_url
	merge_validated_url=$(validate_pr_belongs_to_task "$task_id" "$repo_slug" "$tpr") || merge_validated_url=""
	if [[ -z "$merge_validated_url" ]]; then
		log_error "merge_task_pr: PR #$pr_number does not reference $task_id — refusing to merge (cross-contamination guard)"
		return 1
	fi

	if [[ "$dry_run" == "true" ]]; then
		log_info "[dry-run] Would merge PR #$pr_number in $repo_slug (squash)"
		return 0
	fi

	# t227: Check if this PR needs --admin flag due to SonarCloud external gate failure
	local use_admin_flag="false"
	local triage_result
	triage_result=$(db "$SUPERVISOR_DB" "SELECT triage_result FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	if [[ -n "$triage_result" && "$triage_result" != "null" ]]; then
		local sonarcloud_unstable
		sonarcloud_unstable=$(echo "$triage_result" | jq -r '.sonarcloud_unstable // false' 2>/dev/null || echo "false")
		if [[ "$sonarcloud_unstable" == "true" ]]; then
			use_admin_flag="true"
			log_info "SonarCloud external gate failed but GH Action passed - using --admin to bypass"
		fi
	fi

	# Also check current PR status for unstable_sonarcloud
	if [[ "$use_admin_flag" == "false" ]]; then
		local current_pr_status_full current_pr_status
		current_pr_status_full=$(check_pr_status "$task_id")
		current_pr_status="${current_pr_status_full%%|*}"
		if [[ "$current_pr_status" == "unstable_sonarcloud" ]]; then
			use_admin_flag="true"
			log_info "SonarCloud external gate failed but GH Action passed - using --admin to bypass"
		fi
	fi

	log_info "Merging PR #$pr_number in $repo_slug (squash)..."

	# Record pre-merge commit for targeted deploy (t213)
	local pre_merge_commit=""
	if [[ -n "$trepo" && -d "$trepo/.git" ]]; then
		pre_merge_commit=$(git -C "$trepo" rev-parse HEAD 2>/dev/null || echo "")
		if [[ -n "$pre_merge_commit" ]]; then
			db "$SUPERVISOR_DB" "UPDATE tasks SET error = json_set(COALESCE(error, '{}'), '$.pre_merge_commit', '$pre_merge_commit') WHERE id = '$escaped_id';" 2>/dev/null || true
		fi
	fi

	# Squash merge without --delete-branch (worktree handles branch cleanup)
	# t227: Add --admin flag if SonarCloud external gate failed
	local merge_output
	local merge_cmd="gh pr merge \"$pr_number\" --repo \"$repo_slug\" --squash"
	if [[ "$use_admin_flag" == "true" ]]; then
		merge_cmd="$merge_cmd --admin"
	fi

	if ! merge_output=$(eval "$merge_cmd" 2>&1); then
		log_error "Failed to merge PR #$pr_number. Output from gh:"
		log_error "$merge_output"
		return 1
	fi
	log_success "PR #$pr_number merged successfully"
	return 0
}

#######################################
# Command: pr-merge - merge a task's PR
#######################################
cmd_pr_merge() {
	local task_id="" dry_run="false"

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

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

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh pr-merge <task_id> [--dry-run]"
		return 1
	fi

	# Check PR is ready
	local pr_status_full pr_status
	pr_status_full=$(check_pr_status "$task_id")
	pr_status="${pr_status_full%%|*}"

	if [[ "$pr_status" != "ready_to_merge" ]]; then
		log_error "PR for $task_id is not ready to merge (status: $pr_status)"
		return 1
	fi

	merge_task_pr "$task_id" "$dry_run"
	return $?
}

# update_todo_with_issue_ref() removed in t020.6 — ref:GH#N is now added by
# issue-sync-helper.sh push (called from create_github_issue) and committed
# by commit_and_push_todo within create_github_issue itself.

#######################################
# Verify task has real deliverables before marking complete (t163.4)
# Checks: merged PR exists with substantive file changes (not just TODO.md)
# Returns 0 if verified, 1 if not
#######################################
verify_task_deliverables() {
	local task_id="$1"
	local pr_url="${2:-}"
	local repo="${3:-}"

	# Skip verification for diagnostic subtasks (they fix process, not deliverables)
	if [[ "$task_id" == *-diag-* ]]; then
		log_info "Skipping deliverable verification for diagnostic task $task_id"
		return 0
	fi

	# If no PR URL, task cannot be verified
	if [[ -z "$pr_url" || "$pr_url" == "no_pr" || "$pr_url" == "task_only" ]]; then
		log_warn "Task $task_id has no PR URL ($pr_url) - cannot verify deliverables"
		return 1
	fi

	# Extract repo slug and PR number from URL (t232)
	local parsed_verify repo_slug pr_number
	parsed_verify=$(parse_pr_url "$pr_url") || parsed_verify=""
	if [[ -z "$parsed_verify" ]]; then
		log_warn "Cannot parse PR URL for $task_id: $pr_url"
		return 1
	fi
	repo_slug="${parsed_verify%%|*}"
	pr_number="${parsed_verify##*|}"

	# Pre-flight: verify gh CLI is available and authenticated
	if ! command -v gh &>/dev/null; then
		log_warn "gh CLI not found; cannot verify deliverables for $task_id"
		return 1
	fi
	if ! check_gh_auth; then
		log_warn "gh CLI not authenticated; cannot verify deliverables for $task_id"
		return 1
	fi

	# Cross-contamination guard (t223): verify PR references this task ID
	# in its title or branch name before accepting it as a deliverable.
	local deliverable_validated
	deliverable_validated=$(validate_pr_belongs_to_task "$task_id" "$repo_slug" "$pr_url") || deliverable_validated=""
	if [[ -z "$deliverable_validated" ]]; then
		log_warn "verify_task_deliverables: PR #$pr_number does not reference $task_id — rejecting (cross-contamination guard)"
		return 1
	fi

	# Check PR is actually merged
	local pr_state
	if ! pr_state=$(gh pr view "$pr_number" --repo "$repo_slug" --json state --jq '.state' 2>>"$SUPERVISOR_LOG"); then
		log_warn "Failed to fetch PR state for $task_id (#$pr_number)"
		return 1
	fi
	if [[ "$pr_state" != "MERGED" ]]; then
		log_warn "PR #$pr_number for $task_id is not merged (state: ${pr_state:-unknown})"
		return 1
	fi

	# Check PR has substantive file changes (not just TODO.md or planning files)
	local changed_files
	if ! changed_files=$(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path' 2>>"$SUPERVISOR_LOG"); then
		log_warn "Failed to fetch PR files for $task_id (#$pr_number)"
		return 1
	fi
	local substantive_files
	substantive_files=$(echo "$changed_files" | grep -vE '^(TODO\.md$|todo/|\.github/workflows/)' || true)

	# For planning tasks (#plan, #audit, #chore, #docs), planning-only PRs are valid deliverables (t261)
	if [[ -z "$substantive_files" ]]; then
		# Check if this is a planning task by looking for planning-related tags in TODO.md
		local task_line
		if [[ -n "$repo" ]] && [[ -f "$repo/TODO.md" ]]; then
			task_line=$(grep -E "^\s*- \[.\] $task_id\b" "$repo/TODO.md" || true)
			if [[ -n "$task_line" ]] && echo "$task_line" | grep -qE '#(plan|audit|chore|docs)\b'; then
				log_info "Task $task_id is a planning task — accepting planning-only PR #$pr_number"
				write_proof_log --task "$task_id" --event "deliverable_verified" --stage "complete" \
					--decision "verified:PR#$pr_number:planning-task" \
					--evidence "pr_state=$pr_state,planning_only=true,pr_number=$pr_number" \
					--maker "verify_task_deliverables" \
					--pr-url "$pr_url" 2>/dev/null || true
				return 0
			fi
		fi
		log_warn "PR #$pr_number for $task_id has no substantive file changes (only planning/workflow files)"
		return 1
	fi

	local file_count
	file_count=$(echo "$substantive_files" | wc -l | tr -d ' ')
	# Proof-log: deliverable verification passed (t218)
	write_proof_log --task "$task_id" --event "deliverable_verified" --stage "complete" \
		--decision "verified:PR#$pr_number" \
		--evidence "pr_state=$pr_state,file_count=$file_count,pr_number=$pr_number" \
		--maker "verify_task_deliverables" \
		--pr-url "$pr_url" 2>/dev/null || true
	log_info "Verified $task_id: PR #$pr_number merged with $file_count substantive file(s)"
	return 0
}

#######################################
# Populate VERIFY.md queue after PR merge (t180.2)
# Extracts changed files from the PR and generates check: directives
# based on file types (shellcheck for .sh, file-exists for new files, etc.)
# Appends a new entry to the VERIFY-QUEUE in todo/VERIFY.md
#######################################

#######################################
# Run verification checks for a task from VERIFY.md (t180.3)
# Parses the verify entry, executes each check: directive, and
# marks the entry as [x] (pass) or [!] (fail)
# Returns 0 if all checks pass, 1 if any fail
#######################################
run_verify_checks() {
	local task_id="$1"
	local repo="${2:-}"

	if [[ -z "$repo" ]]; then
		log_warn "run_verify_checks: no repo for $task_id"
		return 1
	fi

	local verify_file="$repo/todo/VERIFY.md"
	if [[ ! -f "$verify_file" ]]; then
		log_info "No VERIFY.md at $verify_file — nothing to verify"
		return 0
	fi

	# Find the verify entry for this task (pending entries only)
	local entry_line
	entry_line=$(grep -n "^- \[ \] v[0-9]* $task_id " "$verify_file" | head -1 || echo "")

	if [[ -z "$entry_line" ]]; then
		log_info "No pending verify entry for $task_id in VERIFY.md"
		return 0
	fi

	local line_num="${entry_line%%:*}"
	local verify_id
	verify_id=$(echo "$entry_line" | grep -oE 'v[0-9]+' | head -1 || echo "")

	log_info "Running verification checks for $task_id ($verify_id)..."

	# Extract check: directives from subsequent indented lines
	local checks=()
	local check_line=$((line_num + 1))
	local total_lines
	total_lines=$(wc -l <"$verify_file")

	while [[ "$check_line" -le "$total_lines" ]]; do
		local line
		line=$(sed -n "${check_line}p" "$verify_file")
		# Stop at next entry or blank line (entries are separated by blank lines)
		if [[ -z "$line" || "$line" =~ ^-\ \[ ]]; then
			break
		fi
		# Extract check: directives
		if [[ "$line" =~ ^[[:space:]]*check:[[:space:]]*(.*) ]]; then
			checks+=("${BASH_REMATCH[1]}")
		fi
		check_line=$((check_line + 1))
	done

	if [[ ${#checks[@]} -eq 0 ]]; then
		log_info "No check: directives found for $task_id — marking verified"
		mark_verify_entry "$verify_file" "$task_id" "pass" ""
		return 0
	fi

	local all_passed=true
	local failures=()

	for check_cmd in "${checks[@]}"; do
		local check_type="${check_cmd%% *}"
		local check_arg="${check_cmd#* }"

		log_info "  check: $check_cmd"

		case "$check_type" in
		file-exists)
			if [[ -f "$repo/$check_arg" ]]; then
				log_success "    PASS: $check_arg exists"
			else
				log_error "    FAIL: $check_arg not found"
				all_passed=false
				failures+=("file-exists: $check_arg not found")
			fi
			;;
		shellcheck)
			if command -v shellcheck &>/dev/null; then
				if shellcheck "$repo/$check_arg" 2>>"$SUPERVISOR_LOG"; then
					log_success "    PASS: shellcheck $check_arg"
				else
					log_error "    FAIL: shellcheck $check_arg"
					all_passed=false
					failures+=("shellcheck: $check_arg has violations")
				fi
			else
				log_warn "    SKIP: shellcheck not installed"
			fi
			;;
		rg)
			# rg "pattern" file — check pattern exists in file
			local rg_pattern rg_file
			# Parse: rg "pattern" file or rg 'pattern' file
			if [[ "$check_arg" =~ ^[\"\'](.+)[\"\'][[:space:]]+(.+)$ ]]; then
				rg_pattern="${BASH_REMATCH[1]}"
				rg_file="${BASH_REMATCH[2]}"
			else
				# Fallback: first word is pattern, rest is file
				rg_pattern="${check_arg%% *}"
				rg_file="${check_arg#* }"
			fi
			if rg -q "$rg_pattern" "$repo/$rg_file" 2>/dev/null; then
				log_success "    PASS: rg \"$rg_pattern\" $rg_file"
			else
				log_error "    FAIL: pattern \"$rg_pattern\" not found in $rg_file"
				all_passed=false
				failures+=("rg: \"$rg_pattern\" not found in $rg_file")
			fi
			;;
		bash)
			if (cd "$repo" && bash "$check_arg" 2>>"$SUPERVISOR_LOG"); then
				log_success "    PASS: bash $check_arg"
			else
				log_error "    FAIL: bash $check_arg"
				all_passed=false
				failures+=("bash: $check_arg failed")
			fi
			;;
		*)
			log_warn "    SKIP: unknown check type '$check_type'"
			;;
		esac
	done

	local today
	today=$(date +%Y-%m-%d)

	if [[ "$all_passed" == "true" ]]; then
		mark_verify_entry "$verify_file" "$task_id" "pass" "$today"
		# Proof-log: verification passed (t218)
		local _verify_duration
		_verify_duration=$(_proof_log_stage_duration "$task_id" "verifying")
		write_proof_log --task "$task_id" --event "verify_pass" --stage "verifying" \
			--decision "verified" \
			--evidence "checks=${#checks[@]},all_passed=true,verify_id=$verify_id" \
			--maker "run_verify_checks" \
			${_verify_duration:+--duration "$_verify_duration"} 2>/dev/null || true
		log_success "All verification checks passed for $task_id ($verify_id)"
		return 0
	else
		local failure_reason
		failure_reason=$(printf '%s; ' "${failures[@]}")
		failure_reason="${failure_reason%; }"
		mark_verify_entry "$verify_file" "$task_id" "fail" "$today" "$failure_reason"
		# Proof-log: verification failed (t218)
		local _verify_duration
		_verify_duration=$(_proof_log_stage_duration "$task_id" "verifying")
		write_proof_log --task "$task_id" --event "verify_fail" --stage "verifying" \
			--decision "verify_failed" \
			--evidence "checks=${#checks[@]},failures=${#failures[@]},reason=${failure_reason:0:200}" \
			--maker "run_verify_checks" \
			${_verify_duration:+--duration "$_verify_duration"} 2>/dev/null || true
		log_error "Verification failed for $task_id ($verify_id): $failure_reason"
		return 1
	fi
}

#######################################
# Mark a verify entry as passed [x] or failed [!] in VERIFY.md (t180.3)
#######################################

#######################################
# Command: verify — manually run verification for a task (t180.3)
#######################################
cmd_verify() {
	local task_id=""

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh verify <task_id>"
		return 1
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, repo, pr_url FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local tstatus trepo tpr
	IFS='|' read -r tstatus trepo tpr <<<"$task_row"

	# Allow verify from deployed or verify_failed states
	if [[ "$tstatus" != "deployed" && "$tstatus" != "verify_failed" ]]; then
		log_error "Task $task_id is in state '$tstatus' — must be 'deployed' or 'verify_failed' to verify"
		return 1
	fi

	cmd_transition "$task_id" "verifying" 2>>"$SUPERVISOR_LOG" || {
		log_error "Failed to transition $task_id to verifying"
		return 1
	}

	if run_verify_checks "$task_id" "$trepo"; then
		cmd_transition "$task_id" "verified" 2>>"$SUPERVISOR_LOG" || true
		log_success "Task $task_id: VERIFIED"

		# Commit and push VERIFY.md changes
		commit_verify_changes "$trepo" "$task_id" "pass" 2>>"$SUPERVISOR_LOG" || true
		return 0
	else
		cmd_transition "$task_id" "verify_failed" 2>>"$SUPERVISOR_LOG" || true
		log_error "Task $task_id: VERIFY FAILED"

		# Commit and push VERIFY.md changes
		commit_verify_changes "$trepo" "$task_id" "fail" 2>>"$SUPERVISOR_LOG" || true
		return 1
	fi
}
