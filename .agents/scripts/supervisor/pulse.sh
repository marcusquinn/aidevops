#!/usr/bin/env bash
# pulse.sh - Supervisor pulse cycle functions
#
# Functions for the main pulse loop and post-PR lifecycle processing

#######################################
# Supervisor pulse - stateless check and dispatch cycle
# Designed to run via cron every 5 minutes
#######################################
cmd_pulse() {
	local batch_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--batch)
			[[ $# -lt 2 ]] && {
				log_error "--batch requires a value"
				return 1
			}
			batch_id="$2"
			shift 2
			;;
		--no-self-heal)
			export SUPERVISOR_SELF_HEAL="false"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	# Acquire pulse dispatch lock to prevent concurrent pulses from
	# independently dispatching workers and exceeding concurrency limits (t159)
	if ! acquire_pulse_lock; then
		log_warn "Another pulse is already running — skipping this invocation"
		return 0
	fi
	# Ensure lock is released on exit (normal, error, or signal)
	# shellcheck disable=SC2064
	trap "release_pulse_lock" EXIT INT TERM

	log_info "=== Supervisor Pulse $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

	# Pulse-level health check flag: once health is confirmed in this pulse,
	# skip subsequent checks to avoid 8-second probes per task
	_PULSE_HEALTH_VERIFIED=""

	# Phase 0: Auto-pickup new tasks from TODO.md (t128.5)
	# Scans for #auto-dispatch tags and Dispatch Queue section
	local all_repos
	all_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks;" 2>/dev/null || true)
	if [[ -n "$all_repos" ]]; then
		while IFS= read -r repo_path; do
			if [[ -f "$repo_path/TODO.md" ]]; then
				cmd_auto_pickup --repo "$repo_path" 2>>"$SUPERVISOR_LOG" || true
			fi
		done <<<"$all_repos"
	else
		# No tasks yet - try current directory
		if [[ -f "$(pwd)/TODO.md" ]]; then
			cmd_auto_pickup --repo "$(pwd)" 2>>"$SUPERVISOR_LOG" || true
		fi
	fi

	# Phase 0.5: Task ID deduplication safety net (t303)
	# Detect and resolve duplicate task IDs in the supervisor DB
	# This catches collisions from concurrent task creation (offline mode, race conditions)
	local duplicate_ids
	duplicate_ids=$(db "$SUPERVISOR_DB" "
        SELECT id, COUNT(*) as cnt
        FROM tasks
        GROUP BY id
        HAVING cnt > 1;
    " 2>/dev/null || echo "")

	if [[ -n "$duplicate_ids" ]]; then
		log_warn "Phase 0.5: Duplicate task IDs detected, resolving..."
		while IFS='|' read -r dup_id dup_count; do
			[[ -z "$dup_id" ]] && continue
			log_warn "  Duplicate task ID: $dup_id (${dup_count} instances)"

			# Keep the oldest task (first created), mark others as cancelled
			local all_instances
			all_instances=$(db -separator '|' "$SUPERVISOR_DB" "
                SELECT rowid, created_at, status
                FROM tasks
                WHERE id = '$(sql_escape "$dup_id")'
                ORDER BY created_at ASC;
            " 2>/dev/null || echo "")

			local first_row=true
			while IFS='|' read -r rowid created_at status; do
				[[ -z "$rowid" ]] && continue
				if [[ "$first_row" == "true" ]]; then
					log_info "    Keeping: rowid=$rowid (created: $created_at, status: $status)"
					first_row=false
				else
					log_warn "    Cancelling duplicate: rowid=$rowid (created: $created_at, status: $status)"
					db "$SUPERVISOR_DB" "
                        UPDATE tasks
                        SET status = 'cancelled',
                            error = 'Duplicate task ID - cancelled by Phase 0.5 dedup (t303)',
                            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                        WHERE rowid = $rowid;
                    " 2>>"$SUPERVISOR_LOG" || true
				fi
			done <<<"$all_instances"
		done <<<"$duplicate_ids"
		log_success "Phase 0.5: Deduplication complete"
	fi

	# Phase 0.5b: Deduplicate task IDs in TODO.md (t319.4)
	# Scans for duplicate tNNN on multiple open `- [ ]` lines.
	# Keeps first occurrence, renames duplicates to t(max+1).
	if [[ -n "$all_repos" ]]; then
		while IFS= read -r repo_path; do
			if [[ -f "$repo_path/TODO.md" ]]; then
				dedup_todo_task_ids "$repo_path" 2>>"$SUPERVISOR_LOG" || true
			fi
		done <<<"$all_repos"
	else
		if [[ -f "$(pwd)/TODO.md" ]]; then
			dedup_todo_task_ids "$(pwd)" 2>>"$SUPERVISOR_LOG" || true
		fi
	fi

	# Phase 1: Check running workers for completion
	# Also check 'evaluating' tasks - AI eval may have timed out, leaving them stuck
	local running_tasks
	running_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, log_file FROM tasks
        WHERE status IN ('running', 'dispatched', 'evaluating')
        ORDER BY started_at ASC;
    ")

	local completed_count=0
	local failed_count=0
	local dispatched_count=0

	if [[ -n "$running_tasks" ]]; then
		while IFS='|' read -r tid tlog; do
			# Check if worker process is still alive
			local pid_file="$SUPERVISOR_DIR/pids/${tid}.pid"
			local is_alive=false

			if [[ -f "$pid_file" ]]; then
				local pid
				pid=$(cat "$pid_file")
				if kill -0 "$pid" 2>/dev/null; then
					is_alive=true
				fi
			fi

			if [[ "$is_alive" == "true" ]]; then
				log_info "  $tid: still running"
				continue
			fi

			# Worker is done - evaluate outcome
			# Check current state to handle already-evaluating tasks (AI eval timeout)
			local current_task_state
			current_task_state=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")

			if [[ "$current_task_state" == "evaluating" ]]; then
				log_info "  $tid: stuck in evaluating (AI eval likely timed out), re-evaluating without AI..."
			else
				log_info "  $tid: worker finished, evaluating..."
				# Transition to evaluating
				cmd_transition "$tid" "evaluating" 2>>"$SUPERVISOR_LOG" || true
			fi

			# Get task description for memory context (t128.6)
			local tid_desc
			tid_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")

			# Get task model and repo for model label tracking (t1010)
			local tid_model tid_repo
			tid_model=$(db "$SUPERVISOR_DB" "SELECT model FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
			tid_repo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")

			# Skip AI eval for stuck tasks (it already timed out once)
			local skip_ai="false"
			if [[ "$current_task_state" == "evaluating" ]]; then
				skip_ai="true"
			fi

			local outcome
			outcome=$(evaluate_worker "$tid" "$skip_ai")
			local outcome_type="${outcome%%:*}"
			local outcome_detail="${outcome#*:}"

			# Proof-log: record evaluation outcome (t218)
			local _eval_duration
			_eval_duration=$(_proof_log_stage_duration "$tid" "evaluate")
			write_proof_log --task "$tid" --event "evaluate" --stage "evaluate" \
				--decision "$outcome" --evidence "skip_ai=$skip_ai" \
				--maker "evaluate_worker" \
				${_eval_duration:+--duration "$_eval_duration"} 2>/dev/null || true

			# Eager orphaned PR scan (t216): if evaluation didn't find a PR,
			# immediately check GitHub before retrying/failing. This catches
			# PRs that evaluate_worker() missed (API timeout, non-standard
			# branch, etc.) without waiting for the Phase 6 throttled sweep.
			if [[ "$outcome_type" != "complete" ]]; then
				scan_orphaned_pr_for_task "$tid" 2>>"$SUPERVISOR_LOG" || true
				# Re-check: if the eager scan found a PR and transitioned
				# the task to complete, update our outcome to match
				local post_scan_status
				post_scan_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
				if [[ "$post_scan_status" == "complete" ]]; then
					local post_scan_pr
					post_scan_pr=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
					log_success "  $tid: COMPLETE via eager orphaned PR scan ($post_scan_pr)"
					completed_count=$((completed_count + 1))
					cleanup_worker_processes "$tid"
					# Success pattern already stored by scan_orphaned_pr_for_task
					handle_diagnostic_completion "$tid" 2>>"$SUPERVISOR_LOG" || true
					continue
				fi
			fi

			case "$outcome_type" in
			complete)
				# Quality gate check before accepting completion (t132.6)
				local gate_result
				gate_result=$(run_quality_gate "$tid" "${batch_id:-}" 2>>"$SUPERVISOR_LOG") || gate_result="pass"
				local gate_type="${gate_result%%:*}"

				if [[ "$gate_type" == "escalate" ]]; then
					local escalated_model="${gate_result#escalate:}"
					log_warn "  $tid: ESCALATING to $escalated_model (quality gate failed)"
					# Proof-log: quality gate escalation (t218)
					write_proof_log --task "$tid" --event "escalate" --stage "quality_gate" \
						--decision "escalate:$escalated_model" \
						--evidence "gate_result=$gate_result" \
						--maker "quality_gate" 2>/dev/null || true
					# run_quality_gate already set status=queued and updated model
					# Clean up worker process tree before re-dispatch (t128.7)
					cleanup_worker_processes "$tid"
					store_failure_pattern "$tid" "escalated" "Quality gate -> $escalated_model" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
					# Add escalated:model label (original model that failed quality gate) (t1010)
					add_model_label "$tid" "escalated" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
					send_task_notification "$tid" "escalated" "Re-queued with $escalated_model" 2>>"$SUPERVISOR_LOG" || true
					continue
				fi

				log_success "  $tid: COMPLETE ($outcome_detail)"
				# Proof-log: task completion (t218)
				write_proof_log --task "$tid" --event "complete" --stage "evaluate" \
					--decision "complete:$outcome_detail" \
					--evidence "gate=$gate_result" \
					--maker "pulse:phase1" \
					--pr-url "$outcome_detail" 2>/dev/null || true
				cmd_transition "$tid" "complete" --pr-url "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				completed_count=$((completed_count + 1))
				# Clean up worker process tree and PID file (t128.7)
				cleanup_worker_processes "$tid"
				# Auto-update TODO.md and send notification (t128.4)
				update_todo_on_complete "$tid" 2>>"$SUPERVISOR_LOG" || true
				send_task_notification "$tid" "complete" "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				# Store success pattern in memory (t128.6)
				store_success_pattern "$tid" "$outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
				# Add implemented:model label to GitHub issue (t1010)
				add_model_label "$tid" "implemented" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
				# Self-heal: if this was a diagnostic task, re-queue the parent (t150)
				handle_diagnostic_completion "$tid" 2>>"$SUPERVISOR_LOG" || true
				;;
			retry)
				log_warn "  $tid: RETRY ($outcome_detail)"
				# Proof-log: retry decision (t218)
				write_proof_log --task "$tid" --event "retry" --stage "evaluate" \
					--decision "retry:$outcome_detail" \
					--maker "pulse:phase1" 2>/dev/null || true
				cmd_transition "$tid" "retrying" --error "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				# Clean up worker process tree before re-prompt (t128.7)
				cleanup_worker_processes "$tid"
				# Store failure pattern in memory (t128.6)
				store_failure_pattern "$tid" "retry" "$outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
				# Add retried:model label to GitHub issue (t1010)
				add_model_label "$tid" "retried" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
				# Auto-escalate model on retry so re-prompt uses stronger model (t314 wiring)
				escalate_model_on_failure "$tid" 2>>"$SUPERVISOR_LOG" || true
				# Backend quota errors: defer re-prompt to next pulse (t095-diag-1).
				# Quota resets take hours, not minutes. Immediate re-prompt wastes
				# retry attempts. Leave in retrying state for deferred retry loop.
				if [[ "$outcome_detail" == "backend_quota_error" || "$outcome_detail" == "backend_infrastructure_error" ]]; then
					log_warn "  $tid: backend issue ($outcome_detail), deferring re-prompt to next pulse"
					continue
				fi
				# Re-prompt in existing worktree (continues context)
				local reprompt_rc=0
				cmd_reprompt "$tid" 2>>"$SUPERVISOR_LOG" || reprompt_rc=$?
				if [[ "$reprompt_rc" -eq 0 ]]; then
					dispatched_count=$((dispatched_count + 1))
					log_info "  $tid: re-prompted successfully"
				elif [[ "$reprompt_rc" -eq 75 ]]; then
					# EX_TEMPFAIL: backend unhealthy, task stays in retrying
					# state for the next pulse to pick up (t153-pre-diag-1)
					log_warn "  $tid: backend unhealthy, deferring re-prompt to next pulse"
				else
					# Re-prompt failed - check if max retries exceeded
					local current_retries
					current_retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 0)
					local max_retries_val
					max_retries_val=$(db "$SUPERVISOR_DB" "SELECT max_retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 3)
					if [[ "$current_retries" -ge "$max_retries_val" ]]; then
						log_error "  $tid: max retries exceeded ($current_retries/$max_retries_val), marking blocked"
						cmd_transition "$tid" "blocked" --error "Max retries exceeded: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
						# Auto-update TODO.md and send notification (t128.4)
						update_todo_on_blocked "$tid" "Max retries exceeded: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
						send_task_notification "$tid" "blocked" "Max retries exceeded: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
						# Store failure pattern in memory (t128.6)
						store_failure_pattern "$tid" "blocked" "Max retries exceeded: $outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
						# Add failed:model label to GitHub issue (t1010)
						add_model_label "$tid" "failed" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
						# Self-heal: attempt diagnostic subtask (t150)
						attempt_self_heal "$tid" "blocked" "$outcome_detail" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
					else
						log_error "  $tid: re-prompt failed, marking failed"
						cmd_transition "$tid" "failed" --error "Re-prompt dispatch failed: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
						failed_count=$((failed_count + 1))
						# Auto-update TODO.md and send notification (t128.4)
						update_todo_on_blocked "$tid" "Re-prompt dispatch failed: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
						send_task_notification "$tid" "failed" "Re-prompt dispatch failed: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
						# Store failure pattern in memory (t128.6)
						store_failure_pattern "$tid" "failed" "Re-prompt dispatch failed: $outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
						# Add failed:model label to GitHub issue (t1010)
						add_model_label "$tid" "failed" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
						# Self-heal: attempt diagnostic subtask (t150)
						attempt_self_heal "$tid" "failed" "$outcome_detail" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
					fi
				fi
				;;
			blocked)
				log_warn "  $tid: BLOCKED ($outcome_detail)"
				# Proof-log: blocked decision (t218)
				write_proof_log --task "$tid" --event "blocked" --stage "evaluate" \
					--decision "blocked:$outcome_detail" \
					--maker "pulse:phase1" 2>/dev/null || true
				cmd_transition "$tid" "blocked" --error "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				# Clean up worker process tree and PID file (t128.7)
				cleanup_worker_processes "$tid"
				# Auto-update TODO.md and send notification (t128.4)
				update_todo_on_blocked "$tid" "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				send_task_notification "$tid" "blocked" "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				# Store failure pattern in memory (t128.6)
				store_failure_pattern "$tid" "blocked" "$outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
				# Add failed:model label to GitHub issue (t1010)
				add_model_label "$tid" "failed" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
				# Self-heal: attempt diagnostic subtask (t150)
				attempt_self_heal "$tid" "blocked" "$outcome_detail" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
				;;
			failed)
				log_error "  $tid: FAILED ($outcome_detail)"
				# Proof-log: failed decision (t218)
				write_proof_log --task "$tid" --event "failed" --stage "evaluate" \
					--decision "failed:$outcome_detail" \
					--maker "pulse:phase1" 2>/dev/null || true
				cmd_transition "$tid" "failed" --error "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				failed_count=$((failed_count + 1))
				# Clean up worker process tree and PID file (t128.7)
				cleanup_worker_processes "$tid"
				# Auto-update TODO.md and send notification (t128.4)
				update_todo_on_blocked "$tid" "FAILED: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				send_task_notification "$tid" "failed" "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				# Store failure pattern in memory (t128.6)
				store_failure_pattern "$tid" "failed" "$outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
				# Add failed:model label to GitHub issue (t1010)
				add_model_label "$tid" "failed" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
				# Self-heal: attempt diagnostic subtask (t150)
				attempt_self_heal "$tid" "failed" "$outcome_detail" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
				;;
			esac
		done <<<"$running_tasks"
	fi

	# Phase 1b: Re-prompt stale retrying tasks (t153-pre-diag-1)
	# Tasks left in 'retrying' state from a previous pulse where the backend was
	# unhealthy (health check returned EX_TEMPFAIL=75). Try re-prompting them now.
	local retrying_tasks
	retrying_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id FROM tasks
        WHERE status = 'retrying'
        AND retries < max_retries
        ORDER BY updated_at ASC;
    ")

	if [[ -n "$retrying_tasks" ]]; then
		while IFS='|' read -r tid; do
			[[ -z "$tid" ]] && continue
			log_info "  $tid: retrying (deferred from previous pulse)"
			local reprompt_rc=0
			cmd_reprompt "$tid" 2>>"$SUPERVISOR_LOG" || reprompt_rc=$?
			if [[ "$reprompt_rc" -eq 0 ]]; then
				dispatched_count=$((dispatched_count + 1))
				log_info "  $tid: re-prompted successfully"
			elif [[ "$reprompt_rc" -eq 75 ]]; then
				log_warn "  $tid: backend still unhealthy, deferring again"
			else
				log_error "  $tid: re-prompt failed (exit $reprompt_rc)"
				local current_retries
				current_retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 0)
				local max_retries_val
				max_retries_val=$(db "$SUPERVISOR_DB" "SELECT max_retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 3)
				if [[ "$current_retries" -ge "$max_retries_val" ]]; then
					cmd_transition "$tid" "blocked" --error "Max retries exceeded during deferred re-prompt" 2>>"$SUPERVISOR_LOG" || true
					attempt_self_heal "$tid" "blocked" "Max retries exceeded during deferred re-prompt" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
				else
					cmd_transition "$tid" "failed" --error "Re-prompt dispatch failed" 2>>"$SUPERVISOR_LOG" || true
					attempt_self_heal "$tid" "failed" "Re-prompt dispatch failed" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
				fi
			fi
		done <<<"$retrying_tasks"
	fi

	# Phase 2: Dispatch queued tasks up to concurrency limit

	if [[ -n "$batch_id" ]]; then
		local next_tasks
		next_tasks=$(cmd_next "$batch_id" 10)

		if [[ -n "$next_tasks" ]]; then
			while IFS=$'\t' read -r tid trepo tdesc tmodel; do
				# Guard: skip malformed task IDs (e.g., from embedded newlines
				# in diagnostic task descriptions containing EXIT:0 or markers)
				if [[ -z "$tid" || "$tid" =~ [[:space:]:] || ! "$tid" =~ ^[a-zA-Z0-9._-]+$ ]]; then
					log_warn "Skipping malformed task ID in cmd_next output: '${tid:0:40}'"
					continue
				fi
				local dispatch_exit=0
				cmd_dispatch "$tid" --batch "$batch_id" || dispatch_exit=$?
				if [[ "$dispatch_exit" -eq 0 ]]; then
					dispatched_count=$((dispatched_count + 1))
				elif [[ "$dispatch_exit" -eq 2 ]]; then
					log_info "Concurrency limit reached, stopping dispatch"
					break
				elif [[ "$dispatch_exit" -eq 3 ]]; then
					log_warn "Provider unavailable for $tid, stopping dispatch until next pulse"
					break
				else
					log_warn "Dispatch failed for $tid (exit $dispatch_exit), trying next task"
				fi
			done <<<"$next_tasks"
		fi
	else
		# Global dispatch (no batch filter)
		local next_tasks
		next_tasks=$(cmd_next "" 10)

		if [[ -n "$next_tasks" ]]; then
			while IFS=$'\t' read -r tid trepo tdesc tmodel; do
				# Guard: skip malformed task IDs (same as batch dispatch above)
				if [[ -z "$tid" || "$tid" =~ [[:space:]:] || ! "$tid" =~ ^[a-zA-Z0-9._-]+$ ]]; then
					log_warn "Skipping malformed task ID in cmd_next output: '${tid:0:40}'"
					continue
				fi
				local dispatch_exit=0
				cmd_dispatch "$tid" || dispatch_exit=$?
				if [[ "$dispatch_exit" -eq 0 ]]; then
					dispatched_count=$((dispatched_count + 1))
				elif [[ "$dispatch_exit" -eq 2 ]]; then
					log_info "Concurrency limit reached, stopping dispatch"
					break
				elif [[ "$dispatch_exit" -eq 3 ]]; then
					log_warn "Provider unavailable for $tid, stopping dispatch until next pulse"
					break
				else
					log_warn "Dispatch failed for $tid (exit $dispatch_exit), trying next task"
				fi
			done <<<"$next_tasks"
		fi
	fi

	# Phase 2.5: Contest mode — check running contests for completion (t1011)
	# If any contest has all entries complete, evaluate cross-rankings and apply winner
	local contest_helper="${SCRIPT_DIR}/contest-helper.sh"
	if [[ -x "$contest_helper" ]]; then
		local has_contests
		has_contests=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='contests';" 2>/dev/null || echo "0")
		if [[ "$has_contests" -gt 0 ]]; then
			local running_contests
			running_contests=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM contests WHERE status IN ('running','evaluating');" 2>/dev/null || echo "0")
			if [[ "$running_contests" -gt 0 ]]; then
				log_info "Phase 2.5: Checking $running_contests running contest(s)..."
				local evaluated_count
				evaluated_count=$("$contest_helper" pulse-check 2>/dev/null || echo "0")
				if [[ "$evaluated_count" -gt 0 ]]; then
					log_success "Phase 2.5: Evaluated $evaluated_count contest(s)"
				fi
			fi
		fi
	fi

	# Phase 3: Post-PR lifecycle (t128.8)
	# Process tasks that workers completed (PR created) but still need merge/deploy
	# t265: Redirect stderr to log and capture errors before || true suppresses them
	if ! process_post_pr_lifecycle "${batch_id:-}" 2>>"$SUPERVISOR_LOG"; then
		log_error "Phase 3 (process_post_pr_lifecycle) failed — see $SUPERVISOR_LOG for details"
	fi

	# Phase 3b: Post-merge verification (t180.4)
	# Run check: directives from VERIFY.md for deployed tasks
	# t265: Redirect stderr to log and capture errors before || true suppresses them
	if ! process_verify_queue "${batch_id:-}" 2>>"$SUPERVISOR_LOG"; then
		log_error "Phase 3b (process_verify_queue) failed — see $SUPERVISOR_LOG for details"
	fi

	# Phase 3.5: Auto-retry blocked merge-conflict tasks (t1029)
	# When a task is blocked with "Merge conflict — auto-rebase failed", periodically
	# re-attempt the rebase after main advances. Other PRs merging often resolve conflicts.
	local blocked_tasks
	blocked_tasks=$(db "$SUPERVISOR_DB" "SELECT id, repo, error, rebase_attempts, last_main_sha FROM tasks WHERE status = 'blocked' AND error LIKE '%Merge conflict%auto-rebase failed%';" 2>/dev/null || echo "")

	if [[ -n "$blocked_tasks" ]]; then
		while IFS='|' read -r blocked_id blocked_repo blocked_error blocked_rebase_attempts blocked_last_main_sha; do
			[[ -z "$blocked_id" ]] && continue

			# Cap at 3 total retry cycles to prevent infinite loops
			local max_retry_cycles=3
			if [[ "${blocked_rebase_attempts:-0}" -ge "$max_retry_cycles" ]]; then
				log_info "  Skipping $blocked_id — max retry cycles ($max_retry_cycles) reached"
				continue
			fi

			# Get current main SHA
			local current_main_sha
			current_main_sha=$(git -C "$blocked_repo" rev-parse origin/main 2>/dev/null || echo "")
			if [[ -z "$current_main_sha" ]]; then
				log_warn "  Failed to get origin/main SHA for $blocked_id in $blocked_repo"
				continue
			fi

			# Check if main has advanced since last attempt
			if [[ -n "$blocked_last_main_sha" && "$current_main_sha" == "$blocked_last_main_sha" ]]; then
				# Main hasn't advanced — skip retry
				continue
			fi

			# Main has advanced (or this is first retry) — reset counter and retry
			log_info "  Main advanced for $blocked_id — retrying rebase (attempt $((blocked_rebase_attempts + 1))/$max_retry_cycles)"

			# Update last_main_sha before attempting rebase
			local escaped_blocked_id
			escaped_blocked_id=$(sql_escape "$blocked_id")
			db "$SUPERVISOR_DB" "UPDATE tasks SET last_main_sha = '$current_main_sha' WHERE id = '$escaped_blocked_id';" 2>/dev/null || true

			# Attempt rebase
			if rebase_sibling_pr "$blocked_id" 2>>"$SUPERVISOR_LOG"; then
				log_success "  Auto-rebase retry succeeded for $blocked_id — transitioning to pr_review"
				# Increment rebase_attempts counter
				db "$SUPERVISOR_DB" "UPDATE tasks SET rebase_attempts = $((blocked_rebase_attempts + 1)) WHERE id = '$escaped_blocked_id';" 2>/dev/null || true
				# Transition back to pr_review so CI can run
				cmd_transition "$blocked_id" "pr_review" --error "" 2>>"$SUPERVISOR_LOG" || true
			else
				# Rebase still failed — increment counter and stay blocked
				log_warn "  Auto-rebase retry failed for $blocked_id — staying blocked"
				db "$SUPERVISOR_DB" "UPDATE tasks SET rebase_attempts = $((blocked_rebase_attempts + 1)) WHERE id = '$escaped_blocked_id';" 2>/dev/null || true
			fi
		done <<<"$blocked_tasks"
	fi

	# Phase 4: Worker health checks - detect dead, hung, and orphaned workers
	local worker_timeout_seconds="${SUPERVISOR_WORKER_TIMEOUT:-3600}" # 1 hour default (t314: restored after merge overwrite)
	# Absolute max runtime: kill workers regardless of log activity.
	# Prevents runaway workers (e.g., shellcheck on huge files) from accumulating
	# and exhausting system memory. Default 2 hours.
	local worker_max_runtime_seconds="${SUPERVISOR_WORKER_MAX_RUNTIME:-14400}" # 4 hour default (t314: restored after merge overwrite)

	if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
		for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
			[[ -f "$pid_file" ]] || continue
			local health_pid
			health_pid=$(cat "$pid_file")
			local health_task
			health_task=$(basename "$pid_file" .pid)
			local health_status
			health_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$health_task")';" 2>/dev/null || echo "")

			if ! kill -0 "$health_pid" 2>/dev/null; then
				# Dead worker: PID no longer exists
				rm -f "$pid_file"
				if [[ "$health_status" == "running" || "$health_status" == "dispatched" ]]; then
					log_warn "  Dead worker for $health_task (PID $health_pid gone, was $health_status) — evaluating"
					cmd_evaluate "$health_task" --no-ai 2>>"$SUPERVISOR_LOG" || {
						# Evaluation failed — force transition so task doesn't stay stuck
						cmd_transition "$health_task" "failed" --error "Worker process died (PID $health_pid)" 2>>"$SUPERVISOR_LOG" || true
						failed_count=$((failed_count + 1))
						attempt_self_heal "$health_task" "failed" "Worker process died" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
					}
				fi
			else
				# Alive worker: check for hung state or max runtime exceeded
				if [[ "$health_status" == "running" || "$health_status" == "dispatched" ]]; then
					local should_kill=false
					local kill_reason=""

					# Check 1: Absolute max runtime (prevents indefinite accumulation)
					local started_at
					started_at=$(db "$SUPERVISOR_DB" "SELECT started_at FROM tasks WHERE id = '$(sql_escape "$health_task")';" 2>/dev/null || echo "")
					if [[ -n "$started_at" ]]; then
						local started_epoch
						started_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || date -d "$started_at" +%s 2>/dev/null || echo "0")
						local now_epoch
						now_epoch=$(date +%s)
						local runtime_seconds=$((now_epoch - started_epoch))
						if [[ "$started_epoch" -gt 0 && "$runtime_seconds" -gt "$worker_max_runtime_seconds" ]]; then
							should_kill=true
							kill_reason="Max runtime exceeded (${runtime_seconds}s > ${worker_max_runtime_seconds}s limit)"
						fi
					fi

					# Check 2: Hung state (no log output for timeout period)
					if [[ "$should_kill" == "false" ]]; then
						local log_file
						log_file=$(db "$SUPERVISOR_DB" "SELECT log_file FROM tasks WHERE id = '$(sql_escape "$health_task")';" 2>/dev/null || echo "")
						if [[ -n "$log_file" && -f "$log_file" ]]; then
							local log_age_seconds=0
							local log_mtime
							log_mtime=$(stat -c %Y "$log_file" 2>/dev/null || stat -f %m "$log_file" 2>/dev/null || echo "0")
							local now_epoch
							now_epoch=$(date +%s)
							log_age_seconds=$((now_epoch - log_mtime))
							if [[ "$log_age_seconds" -gt "$worker_timeout_seconds" ]]; then
								should_kill=true
								kill_reason="Worker hung (no output for ${log_age_seconds}s, timeout ${worker_timeout_seconds}s)"
							fi
						fi
					fi

					if [[ "$should_kill" == "true" ]]; then
						log_warn "  Killing worker for $health_task (PID $health_pid): $kill_reason"
						# Kill all descendants first (shellcheck, node, bash-language-server, etc.)
						_kill_descendants "$health_pid"
						kill "$health_pid" 2>/dev/null || true
						sleep 2
						# Force kill if still alive
						if kill -0 "$health_pid" 2>/dev/null; then
							kill -9 "$health_pid" 2>/dev/null || true
						fi
						rm -f "$pid_file"
						cmd_transition "$health_task" "failed" --error "$kill_reason" 2>>"$SUPERVISOR_LOG" || true
						failed_count=$((failed_count + 1))
						# Auto-escalate model on failure so retry uses stronger model (t314 wiring)
						escalate_model_on_failure "$health_task" 2>>"$SUPERVISOR_LOG" || true
						attempt_self_heal "$health_task" "failed" "$kill_reason" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
					fi
				fi
			fi
		done
	fi

	# Phase 4b: DB orphans — tasks marked running/dispatched with no PID file
	local db_orphans
	db_orphans=$(db "$SUPERVISOR_DB" "SELECT id FROM tasks WHERE status IN ('running', 'dispatched');" 2>/dev/null || echo "")
	if [[ -n "$db_orphans" ]]; then
		while IFS= read -r orphan_id; do
			[[ -n "$orphan_id" ]] || continue
			local orphan_pid_file="$SUPERVISOR_DIR/pids/${orphan_id}.pid"
			if [[ ! -f "$orphan_pid_file" ]]; then
				log_warn "  DB orphan: $orphan_id marked running but no PID file — evaluating"
				cmd_evaluate "$orphan_id" --no-ai 2>>"$SUPERVISOR_LOG" || {
					cmd_transition "$orphan_id" "failed" --error "No worker process found (DB orphan)" 2>>"$SUPERVISOR_LOG" || true
					failed_count=$((failed_count + 1))
					# Auto-escalate model on failure so self-heal retry uses stronger model (t314 wiring)
					escalate_model_on_failure "$orphan_id" 2>>"$SUPERVISOR_LOG" || true
					attempt_self_heal "$orphan_id" "failed" "No worker process found" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
				}
			fi
		done <<<"$db_orphans"
	fi

	# Phase 4c: Cancel stale diagnostic subtasks whose parent is already resolved
	# Diagnostic tasks (diagnostic_of != NULL) become stale when the parent task
	# reaches a terminal state (deployed, cancelled, failed) before the diagnostic
	# is dispatched. Cancel them to free queue slots.
	local stale_diags
	stale_diags=$(db "$SUPERVISOR_DB" "
        SELECT d.id, d.diagnostic_of, p.status AS parent_status
        FROM tasks d
        JOIN tasks p ON d.diagnostic_of = p.id
        WHERE d.diagnostic_of IS NOT NULL
          AND d.status IN ('queued', 'retrying')
          AND p.status IN ('deployed', 'cancelled', 'failed', 'complete', 'merged');
    " 2>/dev/null || echo "")

	if [[ -n "$stale_diags" ]]; then
		while IFS='|' read -r diag_id parent_id parent_status; do
			[[ -n "$diag_id" ]] || continue
			log_info "  Cancelling stale diagnostic $diag_id (parent $parent_id is $parent_status)"
			cmd_transition "$diag_id" "cancelled" --error "Parent task $parent_id already $parent_status" 2>>"$SUPERVISOR_LOG" || true
		done <<<"$stale_diags"
	fi

	# Phase 4d: Auto-recover stuck deploying tasks (t222, t248)
	# Tasks can get stuck in 'deploying' if the deploy succeeds but the
	# transition to 'deployed' fails (e.g., DB write error, process killed
	# mid-transition). Detect tasks in 'deploying' state for longer than
	# the deploy timeout and auto-recover them via process_post_pr_lifecycle
	# (which now handles the deploying state in Step 4b of cmd_pr_lifecycle).
	# t248: Reduced from 600s (10min) to 120s (2min) for faster recovery
	local deploying_timeout_seconds="${SUPERVISOR_DEPLOY_TIMEOUT:-120}" # 2 min default
	local stuck_deploying
	stuck_deploying=$(db "$SUPERVISOR_DB" "
        SELECT id, updated_at FROM tasks
        WHERE status = 'deploying'
        AND updated_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${deploying_timeout_seconds} seconds');
    " 2>/dev/null || echo "")

	if [[ -n "$stuck_deploying" ]]; then
		while IFS='|' read -r stuck_id stuck_updated; do
			[[ -n "$stuck_id" ]] || continue
			log_warn "  Stuck deploying: $stuck_id (last updated: ${stuck_updated:-unknown}, timeout: ${deploying_timeout_seconds}s) — triggering recovery (t222)"
			# process_post_pr_lifecycle will pick this up and run cmd_pr_lifecycle
			# which now handles the deploying state in Step 4b
			cmd_pr_lifecycle "$stuck_id" 2>>"$SUPERVISOR_LOG" || {
				log_error "  Recovery failed for stuck deploying task $stuck_id — forcing to deployed"
				cmd_transition "$stuck_id" "deployed" --error "Force-recovered from stuck deploying (t222)" 2>>"$SUPERVISOR_LOG" || true
			}
		done <<<"$stuck_deploying"
	fi

	# Phase 5: Summary
	local total_running
	total_running=$(cmd_running_count "${batch_id:-}")
	local total_queued
	total_queued=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status = 'queued';")
	local total_complete
	total_complete=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('complete', 'deployed', 'verified');")
	local total_pr_review
	total_pr_review=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('pr_review', 'review_triage', 'merging', 'merged', 'deploying');")
	local total_verifying
	total_verifying=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('verifying', 'verify_failed');")

	local total_failed
	total_failed=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('failed', 'blocked');")
	local total_tasks
	total_tasks=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks;")

	# System resource snapshot (t135.15.3)
	local resource_output
	resource_output=$(check_system_load 2>/dev/null || echo "")
	local sys_load_1m sys_load_5m sys_cpu_cores sys_load_ratio sys_memory sys_proc_count sys_supervisor_procs sys_overloaded
	sys_load_1m=$(echo "$resource_output" | grep '^load_1m=' | cut -d= -f2)
	sys_load_5m=$(echo "$resource_output" | grep '^load_5m=' | cut -d= -f2)
	sys_cpu_cores=$(echo "$resource_output" | grep '^cpu_cores=' | cut -d= -f2)
	sys_load_ratio=$(echo "$resource_output" | grep '^load_ratio=' | cut -d= -f2)
	sys_memory=$(echo "$resource_output" | grep '^memory_pressure=' | cut -d= -f2)
	sys_proc_count=$(echo "$resource_output" | grep '^process_count=' | cut -d= -f2)
	sys_supervisor_procs=$(echo "$resource_output" | grep '^supervisor_process_count=' | cut -d= -f2)
	sys_overloaded=$(echo "$resource_output" | grep '^overloaded=' | cut -d= -f2)

	echo ""
	log_info "Pulse summary:"
	log_info "  Evaluated:  $((completed_count + failed_count)) workers"
	log_info "  Completed:  $completed_count"
	log_info "  Failed:     $failed_count"
	log_info "  Dispatched: $dispatched_count new"
	log_info "  Running:    $total_running"
	log_info "  Queued:     $total_queued"
	log_info "  Post-PR:    $total_pr_review"
	log_info "  Verifying:  $total_verifying"
	log_info "  Total done: $total_complete / $total_tasks"

	# Resource stats (t135.15.3)
	if [[ -n "$sys_load_1m" ]]; then
		local load_color="$GREEN"
		if [[ "$sys_overloaded" == "true" ]]; then
			load_color="$RED"
		elif [[ -n "$sys_load_ratio" && "$sys_load_ratio" -gt 100 ]]; then
			load_color="$YELLOW"
		fi
		local mem_color="$GREEN"
		if [[ "$sys_memory" == "high" ]]; then
			mem_color="$RED"
		elif [[ "$sys_memory" == "medium" ]]; then
			mem_color="$YELLOW"
		fi
		echo ""
		log_info "System resources:"
		echo -e "  ${BLUE}[SUPERVISOR]${NC}   CPU:      ${load_color}${sys_load_ratio}%${NC} used (${sys_cpu_cores} cores, load avg: ${sys_load_1m}/${sys_load_5m})"
		echo -e "  ${BLUE}[SUPERVISOR]${NC}   Memory:   ${mem_color}${sys_memory}${NC}"
		echo -e "  ${BLUE}[SUPERVISOR]${NC}   Procs:    ${sys_proc_count} total, ${sys_supervisor_procs} supervisor"
		# Show adaptive concurrency for the active batch
		if [[ -n "$batch_id" ]]; then
			local display_base display_max display_load_factor display_adaptive
			local escaped_display_batch
			escaped_display_batch=$(sql_escape "$batch_id")
			display_base=$(db "$SUPERVISOR_DB" "SELECT concurrency FROM batches WHERE id = '$escaped_display_batch';" 2>/dev/null || echo "?")
			display_max=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_concurrency, 0) FROM batches WHERE id = '$escaped_display_batch';" 2>/dev/null || echo "0")
			display_load_factor=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_load_factor, 2) FROM batches WHERE id = '$escaped_display_batch';" 2>/dev/null || echo "2")
			display_adaptive=$(calculate_adaptive_concurrency "${display_base:-4}" "${display_load_factor:-2}" "${display_max:-0}")
			local adaptive_label="base:${display_base}"
			if [[ "$display_adaptive" -gt "${display_base:-0}" ]]; then
				adaptive_label="${adaptive_label} ${GREEN}scaled:${display_adaptive}${NC}"
			elif [[ "$display_adaptive" -lt "${display_base:-0}" ]]; then
				adaptive_label="${adaptive_label} ${YELLOW}throttled:${display_adaptive}${NC}"
			else
				adaptive_label="${adaptive_label} effective:${display_adaptive}"
			fi
			local cap_display="auto"
			[[ "${display_max:-0}" -gt 0 ]] && cap_display="$display_max"
			echo -e "  ${BLUE}[SUPERVISOR]${NC}   Workers:  ${adaptive_label} (cap:${cap_display})"
		fi
		if [[ "$sys_overloaded" == "true" ]]; then
			echo -e "  ${BLUE}[SUPERVISOR]${NC}   ${RED}OVERLOADED${NC} - adaptive throttling active"
		fi

	fi

	# macOS notification on progress (when something changed this pulse)
	if [[ $((completed_count + failed_count + dispatched_count)) -gt 0 ]]; then
		local batch_label="${batch_id:-all tasks}"
		notify_batch_progress "$total_complete" "$total_tasks" "$total_failed" "$batch_label" 2>/dev/null || true
	fi

	# Phase 4: Periodic process hygiene - clean up orphaned worker processes
	# Runs every pulse to prevent accumulation between cleanup calls
	local orphan_killed=0
	if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
		for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
			[[ -f "$pid_file" ]] || continue
			local cleanup_tid
			cleanup_tid=$(basename "$pid_file" .pid)
			local cleanup_status
			cleanup_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$cleanup_tid")';" 2>/dev/null || echo "")
			case "$cleanup_status" in
			complete | failed | cancelled | blocked | deployed | verified | verify_failed | pr_review | review_triage | merging | merged | deploying | verifying)
				cleanup_worker_processes "$cleanup_tid" 2>/dev/null || true
				orphan_killed=$((orphan_killed + 1))
				;;
			esac
		done
	fi
	if [[ "$orphan_killed" -gt 0 ]]; then
		log_info "  Cleaned:    $orphan_killed stale worker processes"
	fi

	# Phase 4e: System-wide orphan process sweep + memory pressure emergency kill
	# Catches processes that escaped PID-file tracking (e.g., PID file deleted,
	# never written, or child processes like shellcheck/node that outlived their parent).
	# Also triggers emergency cleanup when memory pressure is critical.
	local sweep_killed=0

	# Build a set of PIDs we should NOT kill (active tracked workers + this process chain)
	local protected_pids=""
	if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
		for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
			[[ -f "$pid_file" ]] || continue
			local sweep_pid
			sweep_pid=$(cat "$pid_file" 2>/dev/null || echo "")
			[[ -z "$sweep_pid" ]] && continue
			local sweep_task_status
			sweep_task_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$(basename "$pid_file" .pid)")';" 2>/dev/null || echo "")
			if [[ "$sweep_task_status" == "running" || "$sweep_task_status" == "dispatched" ]] && kill -0 "$sweep_pid" 2>/dev/null; then
				protected_pids="${protected_pids} ${sweep_pid}"
				local sweep_descendants
				sweep_descendants=$(_list_descendants "$sweep_pid" 2>/dev/null || true)
				if [[ -n "$sweep_descendants" ]]; then
					protected_pids="${protected_pids} ${sweep_descendants}"
				fi
			fi
		done
	fi
	# Protect this process chain
	local self_pid=$$
	while [[ "$self_pid" -gt 1 ]] 2>/dev/null; do
		protected_pids="${protected_pids} ${self_pid}"
		self_pid=$(ps -o ppid= -p "$self_pid" 2>/dev/null | tr -d ' ')
		[[ -z "$self_pid" ]] && break
	done

	# Find orphaned opencode/shellcheck/bash-language-server processes with PPID=1
	# PPID=1 means the parent died and the process was reparented to init/launchd
	local orphan_candidates
	orphan_candidates=$(pgrep -f 'opencode|shellcheck|bash-language-server' 2>/dev/null || true)
	if [[ -n "$orphan_candidates" ]]; then
		while read -r opid; do
			[[ -z "$opid" ]] && continue
			# Skip protected PIDs
			if echo " ${protected_pids} " | grep -q " ${opid} "; then
				continue
			fi
			# Only kill orphans (PPID=1) — processes whose parent has died
			local oppid
			oppid=$(ps -o ppid= -p "$opid" 2>/dev/null | tr -d ' ')
			[[ "$oppid" != "1" ]] && continue

			local ocmd
			ocmd=$(ps -o args= -p "$opid" 2>/dev/null | head -c 100)
			log_warn "  Killing orphaned process PID $opid (PPID=1): $ocmd"
			_kill_descendants "$opid"
			kill "$opid" 2>/dev/null || true
			sleep 0.5
			if kill -0 "$opid" 2>/dev/null; then
				kill -9 "$opid" 2>/dev/null || true
			fi
			sweep_killed=$((sweep_killed + 1))
		done <<<"$orphan_candidates"
	fi

	# Memory pressure emergency kill: if memory is critical, kill ALL non-protected
	# worker processes regardless of PPID. This is the last line of defence against
	# the system running out of RAM and becoming unresponsive.
	if [[ "${sys_memory:-}" == "high" ]]; then
		log_error "  CRITICAL: Memory pressure HIGH — emergency worker cleanup"
		local emergency_candidates
		emergency_candidates=$(pgrep -f 'opencode|shellcheck|bash-language-server' 2>/dev/null || true)
		if [[ -n "$emergency_candidates" ]]; then
			while read -r epid; do
				[[ -z "$epid" ]] && continue
				if echo " ${protected_pids} " | grep -q " ${epid} "; then
					continue
				fi
				local ecmd
				ecmd=$(ps -o args= -p "$epid" 2>/dev/null | head -c 100)
				log_warn "  Emergency kill PID $epid: $ecmd"
				_kill_descendants "$epid"
				kill -9 "$epid" 2>/dev/null || true
				sweep_killed=$((sweep_killed + 1))
			done <<<"$emergency_candidates"
		fi
	fi

	if [[ "$sweep_killed" -gt 0 ]]; then
		log_warn "  Phase 4e: Killed $sweep_killed orphaned/emergency processes"
	fi

	# Phase 6: Orphaned PR scanner — broad sweep (t210, t216)
	# Detect PRs that workers created but the supervisor missed during evaluation.
	# Throttled internally (10-minute interval) to avoid excessive GH API calls.
	# Note: Phase 1 now runs an eager per-task scan immediately after evaluation
	# (scan_orphaned_pr_for_task), so this broad sweep mainly catches edge cases
	# like tasks that were already in failed/blocked state before the eager scan
	# was introduced, or tasks evaluated by Phase 4b DB orphan detection.
	scan_orphaned_prs "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true

	# Phase 7: Reconcile TODO.md for any stale tasks (t160)
	# Runs when completed tasks exist and nothing is actively running/queued
	if [[ "$total_running" -eq 0 && "$total_queued" -eq 0 && "$total_complete" -gt 0 ]]; then
		cmd_reconcile_todo ${batch_id:+--batch "$batch_id"} 2>>"$SUPERVISOR_LOG" || true
	fi

	# Phase 7b: Bidirectional DB<->TODO.md reconciliation (t1001)
	# Fills gaps not covered by Phase 7:
	#   - DB failed/blocked tasks with no TODO.md annotation
	#   - Tasks marked [x] in TODO.md but DB still in non-terminal state
	#   - DB orphans with no TODO.md entry (logged as warnings)
	# Runs when nothing is actively running/queued to avoid mid-flight interference.
	if [[ "$total_running" -eq 0 && "$total_queued" -eq 0 ]]; then
		cmd_reconcile_db_todo ${batch_id:+--batch "$batch_id"} 2>>"$SUPERVISOR_LOG" || true
	fi

	# Phase 8: Issue-sync reconciliation (t179.3)
	# Close stale GitHub issues and fix ref:GH# drift.
	# Runs periodically (every ~50 min) when no workers active, to avoid
	# excessive GH API calls. Uses a timestamp file to throttle.
	if [[ "$total_running" -eq 0 && "$total_queued" -eq 0 ]]; then
		local issue_sync_interval=3000 # seconds (~50 min)
		local issue_sync_stamp="$SUPERVISOR_DIR/issue-sync-last-run"
		local now_epoch
		now_epoch=$(date +%s)
		local last_run=0
		if [[ -f "$issue_sync_stamp" ]]; then
			last_run=$(cat "$issue_sync_stamp" 2>/dev/null || echo 0)
		fi
		local elapsed=$((now_epoch - last_run))
		if [[ "$elapsed" -ge "$issue_sync_interval" ]]; then
			log_info "  Phase 8: Issue-sync reconciliation (${elapsed}s since last run)"
			# Find a repo with TODO.md to run against
			local sync_repo=""
			sync_repo=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks LIMIT 1;" 2>/dev/null || echo "")
			if [[ -z "$sync_repo" ]]; then
				sync_repo="$(pwd)"
			fi
			local issue_sync_script="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/issue-sync-helper.sh"
			if [[ -f "$issue_sync_script" && -f "$sync_repo/TODO.md" ]]; then
				# Run reconcile to fix ref:GH# drift
				bash "$issue_sync_script" reconcile --verbose 2>>"$SUPERVISOR_LOG" || true
				# Run close to close stale issues for completed tasks
				bash "$issue_sync_script" close --verbose 2>>"$SUPERVISOR_LOG" || true
				echo "$now_epoch" >"$issue_sync_stamp"
				log_info "  Phase 8: Issue-sync complete"
			else
				log_verbose "  Phase 8: Skipped (issue-sync-helper.sh or TODO.md not found)"
			fi
		else
			local remaining=$((issue_sync_interval - elapsed))
			log_verbose "  Phase 8: Skipped (${remaining}s until next run)"
		fi

		# Phase 8b: Status label reconciliation sweep (t1009)
		# Checks all tasks in the DB and ensures their GitHub issue labels match
		# the current supervisor state. Catches drift from missed transitions,
		# manual label changes, or failed API calls.
		# Piggybacks on the same interval/idle check as Phase 8.
		if [[ "$elapsed" -ge "$issue_sync_interval" ]]; then
			# Derive repo_slug from sync_repo (set in Phase 8 above)
			local rec_repo_slug
			rec_repo_slug=$(detect_repo_slug "${sync_repo:-.}" 2>/dev/null || echo "")
			if [[ -n "$rec_repo_slug" ]]; then
				log_info "  Phase 8b: Status label reconciliation sweep"
				ensure_status_labels "$rec_repo_slug"
				local reconcile_count=0
				local reconcile_tasks
				reconcile_tasks=$(db "$SUPERVISOR_DB" "SELECT id, status FROM tasks WHERE status NOT IN ('verified','deployed','cancelled','failed');" 2>/dev/null || echo "")
				while IFS='|' read -r rec_tid rec_status; do
					[[ -z "$rec_tid" ]] && continue
					local rec_issue
					rec_issue=$(find_task_issue_number "$rec_tid" "${sync_repo:-.}")
					[[ -z "$rec_issue" ]] && continue

					local expected_label
					expected_label=$(state_to_status_label "$rec_status")
					[[ -z "$expected_label" ]] && continue

					# Check if the issue already has the correct label
					local current_labels
					current_labels=$(gh issue view "$rec_issue" --repo "$rec_repo_slug" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
					if [[ "$current_labels" != *"$expected_label"* ]]; then
						# Build remove args for all status labels except the expected one
						local -a rec_remove_args=()
						local rec_label
						while IFS=',' read -ra rec_labels; do
							for rec_label in "${rec_labels[@]}"; do
								if [[ "$rec_label" != "$expected_label" ]]; then
									rec_remove_args+=("--remove-label" "$rec_label")
								fi
							done
						done <<<"$ALL_STATUS_LABELS"
						gh issue edit "$rec_issue" --repo "$rec_repo_slug" \
							--add-label "$expected_label" "${rec_remove_args[@]}" 2>/dev/null || true
						log_verbose "  Phase 8b: Fixed #$rec_issue ($rec_tid): -> $expected_label"
						reconcile_count=$((reconcile_count + 1))
					fi
				done <<<"$reconcile_tasks"
				if [[ "$reconcile_count" -gt 0 ]]; then
					log_info "  Phase 8b: Reconciled $reconcile_count issue label(s)"
				else
					log_verbose "  Phase 8b: All labels in sync"
				fi
			else
				log_verbose "  Phase 8b: Skipped (could not detect repo slug)"
			fi
		fi
	fi

	# Phase 8c: Per-repo pinned health issues — live status dashboard (t1013)
	# Each repo gets its own pinned issue with stats filtered to that repo.
	# Graceful degradation — never breaks the pulse if gh fails.
	local health_repos
	health_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks WHERE repo IS NOT NULL AND repo != '';" 2>/dev/null || echo "")
	if [[ -n "$health_repos" ]]; then
		while IFS= read -r health_repo; do
			[[ -z "$health_repo" ]] && continue
			local health_slug
			health_slug=$(detect_repo_slug "$health_repo" 2>/dev/null || echo "")
			[[ -z "$health_slug" ]] && continue
			update_queue_health_issue "${batch_id:-}" "$health_slug" "$health_repo" 2>>"$SUPERVISOR_LOG" || true
		done <<<"$health_repos"
	fi

	# Phase 9: Memory audit pulse (t185)
	# Runs dedup, prune, graduate, and opportunity scan.
	# The audit script self-throttles (24h interval), so calling every pulse is safe.
	local audit_script="${SCRIPT_DIR}/memory-audit-pulse.sh"
	if [[ -x "$audit_script" ]]; then
		log_verbose "  Phase 9: Memory audit pulse"
		"$audit_script" run --quiet 2>>"$SUPERVISOR_LOG" || true
	fi

	# Phase 10: CodeRabbit daily pulse (t166.1)
	# Triggers a full codebase review via CodeRabbit CLI or GitHub API.
	# The pulse script self-throttles (24h cooldown), so calling every pulse is safe.
	local coderabbit_pulse_script="${SCRIPT_DIR}/coderabbit-pulse-helper.sh"
	if [[ -x "$coderabbit_pulse_script" ]]; then
		log_verbose "  Phase 10: CodeRabbit daily pulse"
		local pulse_repo=""
		pulse_repo=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks LIMIT 1;" 2>/dev/null || echo "")
		if [[ -z "$pulse_repo" ]]; then
			pulse_repo="$(pwd)"
		fi
		bash "$coderabbit_pulse_script" run --repo "$pulse_repo" --quiet 2>>"$SUPERVISOR_LOG" || true
	fi

	# Phase 10b: Auto-create TODO tasks from quality findings (t299)
	# Converts CodeRabbit and quality-sweep findings into TODO.md tasks.
	# Self-throttles with 24h cooldown. Only runs if task creator script exists.
	local task_creator_script="${SCRIPT_DIR}/coderabbit-task-creator-helper.sh"
	local task_creation_cooldown_file="${SUPERVISOR_DIR}/task-creation-last-run"
	local task_creation_cooldown=86400 # 24 hours
	if [[ -x "$task_creator_script" ]]; then
		local should_run_task_creation=true
		if [[ -f "$task_creation_cooldown_file" ]]; then
			local last_run
			last_run=$(cat "$task_creation_cooldown_file" 2>/dev/null || echo "0")
			local now
			now=$(date +%s)
			local elapsed=$((now - last_run))
			if [[ $elapsed -lt $task_creation_cooldown ]]; then
				should_run_task_creation=false
				local remaining=$(((task_creation_cooldown - elapsed) / 3600))
				log_verbose "  Phase 10b: Task creation skipped (${remaining}h until next run)"
			fi
		fi

		if [[ "$should_run_task_creation" == "true" ]]; then
			log_info "  Phase 10b: Auto-creating tasks from quality findings"
			date +%s >"$task_creation_cooldown_file"

			# Determine repo for TODO.md
			local task_repo=""
			task_repo=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks LIMIT 1;" 2>/dev/null || echo "")
			if [[ -z "$task_repo" ]]; then
				task_repo="$(pwd)"
			fi
			local todo_file="$task_repo/TODO.md"

			if [[ -f "$todo_file" ]]; then
				local tasks_added=0

				# 1. CodeRabbit findings → tasks
				# coderabbit-task-creator-helper.sh already allocates IDs via
				# claim-task-id.sh (t319.3). We use the IDs it returns directly
				# instead of re-assigning with grep-based max_id (collision-prone).
				local cr_output
				cr_output=$(bash "$task_creator_script" create 2>>"$SUPERVISOR_LOG" || echo "")
				if [[ -n "$cr_output" ]]; then
					# Extract task lines between the markers
					local cr_tasks
					cr_tasks=$(echo "$cr_output" | sed -n '/=== Task Lines/,/===$/p' | grep -E '^\s*- \[ \]' || true)
					if [[ -n "$cr_tasks" ]]; then
						local claim_script="${SCRIPT_DIR}/claim-task-id.sh"

						# Append each task line to TODO.md
						while IFS= read -r task_line; do
							local new_line="$task_line"

							# If the task line already has a tNNN ID (from claim-task-id.sh
							# inside coderabbit-task-creator), use it as-is.
							# Otherwise, allocate a new ID via claim-task-id.sh.
							if ! echo "$new_line" | grep -qE '^\s*- \[ \] t[0-9]+'; then
								local claim_output claimed_id
								if [[ -x "$claim_script" ]]; then
									local task_desc
									task_desc=$(echo "$new_line" | sed -E 's/^\s*- \[ \] //')
									claim_output=$("$claim_script" --title "${task_desc:0:80}" --repo-path "$task_repo" 2>>"$SUPERVISOR_LOG") || claim_output=""
									claimed_id=$(echo "$claim_output" | grep "^task_id=" | cut -d= -f2)
								fi
								if [[ -n "${claimed_id:-}" ]]; then
									new_line=$(echo "$new_line" | sed -E "s/^(\s*- \[ \] )/\1${claimed_id} /")
									# Add ref if available
									local claimed_ref
									claimed_ref=$(echo "$claim_output" | grep "^ref=" | cut -d= -f2)
									if [[ -n "$claimed_ref" && "$claimed_ref" != "offline" ]]; then
										new_line="$new_line ref:${claimed_ref}"
									fi
								else
									log_warn "    Failed to allocate task ID via claim-task-id.sh, skipping line"
									continue
								fi
							fi

							# Ensure #auto-dispatch tag and source tag
							if ! echo "$new_line" | grep -q '#auto-dispatch'; then
								new_line="$new_line #auto-dispatch"
							fi
							if ! echo "$new_line" | grep -q '#auto-review'; then
								new_line="$new_line #auto-review"
							fi
							if ! echo "$new_line" | grep -q 'logged:'; then
								new_line="$new_line logged:$(date +%Y-%m-%d)"
							fi
							# Append to TODO.md
							echo "$new_line" >>"$todo_file"
							tasks_added=$((tasks_added + 1))
							# Extract task ID for logging
							local logged_id
							logged_id=$(echo "$new_line" | grep -oE 't[0-9]+' | head -1 || echo "unknown")
							log_info "    Created ${logged_id} from CodeRabbit finding"
						done <<<"$cr_tasks"
					fi
				fi

				# 2. Commit and push if tasks were added
				if [[ $tasks_added -gt 0 ]]; then
					log_info "  Phase 10b: Added $tasks_added task(s) to TODO.md"
					if git -C "$task_repo" add TODO.md 2>>"$SUPERVISOR_LOG" &&
						git -C "$task_repo" commit -m "chore: auto-create $tasks_added task(s) from quality findings (Phase 10b)" 2>>"$SUPERVISOR_LOG" &&
						git -C "$task_repo" push 2>>"$SUPERVISOR_LOG"; then
						log_success "  Phase 10b: Committed and pushed $tasks_added new task(s)"
					else
						log_warn "  Phase 10b: Failed to commit/push TODO.md changes"
					fi
				else
					log_verbose "  Phase 10b: No new tasks to create"
				fi
			fi
		fi
	fi

	# Phase 10c: Audit regression detection (t1032.6)
	# Checks for >20% increase in audit findings vs previous run.
	# Logs warnings to pulse log when regressions are detected.
	local audit_helper="${SCRIPT_DIR}/code-audit-helper.sh"
	if [[ -x "$audit_helper" ]]; then
		log_verbose "  Phase 10c: Checking for audit regressions"
		if ! bash "$audit_helper" check-regression 2>>"$SUPERVISOR_LOG"; then
			log_warn "  Phase 10c: Audit regressions detected (see warnings above)"
		fi
	fi

	# Phase 11: Supervisor session memory monitoring + respawn (t264, t264.1)
	# OpenCode/Bun processes accumulate WebKit malloc dirty pages that are never
	# returned to the OS. Over long sessions, a single process can grow to 25GB+.
	# Cron-based pulses are already fresh processes (no accumulation).
	#
	# Respawn strategy (t264.1): after a batch wave completes (no running/queued
	# tasks) AND memory exceeds threshold, save checkpoint and exit cleanly.
	# The next cron pulse (2 min) starts fresh with zero accumulated memory.
	# Workers are NOT killed — they're short-lived and managed by Phase 4.
	if attempt_respawn_after_batch "${batch_id:-}" 2>/dev/null; then
		log_warn "  Phase 11: Respawn triggered — releasing lock and exiting for fresh restart"
		release_pulse_lock
		trap - EXIT INT TERM
		return 0
	fi
	# If no respawn needed, still log a warning if memory is high (passive monitoring)
	if ! check_supervisor_memory 2>/dev/null; then
		log_warn "  Phase 11: Memory exceeds threshold but tasks still active — monitoring"
	fi

	# Phase 12: Regenerate MODELS.md leaderboard (t1012)
	# Throttled to once per hour — only regenerates when pattern data may have changed.
	# Iterates over known repos and updates MODELS.md in each repo root.
	local models_md_interval=3600 # seconds (1 hour)
	local models_md_stamp="$SUPERVISOR_DIR/models-md-last-regen"
	local models_md_now
	models_md_now=$(date +%s)
	local models_md_last=0
	if [[ -f "$models_md_stamp" ]]; then
		models_md_last=$(cat "$models_md_stamp" 2>/dev/null || echo 0)
	fi
	local models_md_elapsed=$((models_md_now - models_md_last))
	if [[ "$models_md_elapsed" -ge "$models_md_interval" ]]; then
		local generate_script="${SCRIPT_DIR}/generate-models-md.sh"
		if [[ -x "$generate_script" ]]; then
			local models_repos
			models_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks;" 2>/dev/null || true)
			if [[ -n "$models_repos" ]]; then
				while IFS= read -r models_repo_path; do
					[[ -n "$models_repo_path" && -d "$models_repo_path" ]] || continue
					local models_repo_root
					models_repo_root=$(git -C "$models_repo_path" rev-parse --show-toplevel 2>/dev/null) || continue
					log_verbose "  Phase 12: Regenerating MODELS.md in $models_repo_root"
					if "$generate_script" --output "${models_repo_root}/MODELS.md" --quiet 2>/dev/null; then
						if git -C "$models_repo_root" diff --quiet -- MODELS.md 2>/dev/null; then
							log_verbose "  Phase 12: MODELS.md unchanged in $models_repo_root"
						else
							git -C "$models_repo_root" add MODELS.md 2>/dev/null &&
								git -C "$models_repo_root" commit -m "chore: regenerate MODELS.md leaderboard (t1012)" --no-verify 2>/dev/null &&
								git -C "$models_repo_root" push 2>/dev/null &&
								log_info "  Phase 12: MODELS.md updated and pushed ($models_repo_root)" ||
								log_warn "  Phase 12: MODELS.md regenerated but commit/push failed ($models_repo_root)"
						fi
					else
						log_warn "  Phase 12: MODELS.md generation failed for $models_repo_root"
					fi
				done <<<"$models_repos"
			fi
		fi
		echo "$models_md_now" >"$models_md_stamp" 2>/dev/null || true
	else
		local models_md_remaining=$((models_md_interval - models_md_elapsed))
		log_verbose "  Phase 12: MODELS.md regen skipped (${models_md_remaining}s until next run)"
	fi

	# Release pulse dispatch lock (t159)
	release_pulse_lock
	# Reset trap to avoid interfering with other commands in the same process
	trap - EXIT INT TERM

	return 0
}

#######################################
# Process post-PR lifecycle for all eligible tasks
# Called as Phase 3 of the pulse cycle
# Finds tasks in complete/pr_review/merging/merged states with PR URLs
#
# t225: Serial merge strategy for sibling subtasks
# When multiple subtasks share a parent (e.g., t215.1, t215.2, t215.3),
# only one sibling is allowed to merge per pulse cycle. After it merges,
# rebase_sibling_prs_after_merge() (called from cmd_pr_lifecycle) rebases
# the remaining siblings' branches onto the updated main. This prevents
# cascading merge conflicts that occur when parallel PRs all target main.
#######################################
process_post_pr_lifecycle() {
	local batch_id="${1:-}"

	ensure_db

	# Find tasks eligible for post-PR processing
	local where_clause="t.status IN ('complete', 'pr_review', 'review_triage', 'merging', 'merged', 'deploying')"
	if [[ -n "$batch_id" ]]; then
		where_clause="$where_clause AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$(sql_escape "$batch_id")')"
	fi

	local eligible_tasks
	eligible_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT t.id, t.status, t.pr_url FROM tasks t
        WHERE $where_clause
        ORDER BY t.updated_at ASC;
    ")

	if [[ -z "$eligible_tasks" ]]; then
		return 0
	fi

	local processed=0
	local merged_count=0
	local deployed_count=0
	local deferred_count=0

	# t225: Track which parent IDs have already had a sibling merge in this pulse.
	# Only one sibling per parent group is allowed to merge per cycle.
	# Use a simple string list (bash 3.2 compatible — no associative arrays).
	local merged_parents=""

	while IFS='|' read -r tid tstatus tpr; do
		# Skip tasks without PRs that are already complete
		# t1030: Defense-in-depth — cmd_transition() also guards complete->deployed
		# when a real PR URL exists, but this fast path should only fire for genuinely
		# PR-less tasks. The "|| $tpr == verified_complete" case is a verify-mode
		# worker that confirmed prior work without creating a new PR.
		if [[ "$tstatus" == "complete" && (-z "$tpr" || "$tpr" == "no_pr" || "$tpr" == "task_only" || "$tpr" == "verified_complete") ]]; then
			# t240: Clean up worktree even for no-PR tasks before marking deployed
			cleanup_after_merge "$tid" 2>>"$SUPERVISOR_LOG" || log_warn "Worktree cleanup issue for $tid (no-PR batch path, non-blocking)"
			# No PR - transition directly to deployed
			cmd_transition "$tid" "deployed" 2>>"$SUPERVISOR_LOG" || true
			deployed_count=$((deployed_count + 1))
			log_info "  $tid: no PR, marked deployed (worktree cleaned)"
			continue
		fi

		# t225: Serial merge guard for sibling subtasks
		# If this task is a subtask and a sibling has already merged in this
		# pulse, defer it to the next cycle (after rebase completes).
		local parent_id
		parent_id=$(extract_parent_id "$tid")
		if [[ -n "$parent_id" ]]; then
			# Check if a sibling already merged in this pulse
			if [[ "$merged_parents" == *"|${parent_id}|"* ]]; then
				# A sibling already merged — defer this task to next pulse
				# so the rebase can land first and CI can re-run
				log_info "  $tid: deferred (sibling under $parent_id already merged this pulse — serial merge strategy)"
				deferred_count=$((deferred_count + 1))
				continue
			fi
		fi

		log_info "  $tid: processing post-PR lifecycle (status: $tstatus)"
		if cmd_pr_lifecycle "$tid" >>"$SUPERVISOR_DIR/post-pr.log" 2>&1; then
			local new_status
			new_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
			case "$new_status" in
			merged | deploying | deployed)
				merged_count=$((merged_count + 1))
				# t225: Record that this parent group had a merge
				if [[ -n "$parent_id" ]]; then
					merged_parents="${merged_parents}|${parent_id}|"
				fi
				;;
			esac
			if [[ "$new_status" == "deployed" ]]; then
				deployed_count=$((deployed_count + 1))
			fi
		fi
		processed=$((processed + 1))
	done <<<"$eligible_tasks"

	if [[ "$processed" -gt 0 || "$deferred_count" -gt 0 ]]; then
		log_info "Post-PR lifecycle: processed=$processed merged=$merged_count deployed=$deployed_count deferred=$deferred_count"
	fi

	return 0
}

#######################################
# Extract parent task ID from a subtask ID (t225)
# e.g., t215.3 -> t215, t100.1.2 -> t100.1, t50 -> "" (no parent)
#######################################
extract_parent_id() {
	local task_id="$1"
	if [[ "$task_id" =~ ^(t[0-9]+(\.[0-9]+)*)\.[0-9]+$ ]]; then
		echo "${BASH_REMATCH[1]}"
	fi
	# No output for non-subtasks (intentional)
	return 0
}
