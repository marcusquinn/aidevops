#!/usr/bin/env bash
# state.sh - State machine and task/batch status functions
#
# Functions for state transitions, status queries, and task lifecycle


#######################################
# Validate a state transition
# Returns 0 if valid, 1 if invalid
#######################################
validate_transition() {
	local from_state="$1"
	local to_state="$2"
	local transition="${from_state}:${to_state}"

	for valid in "${VALID_TRANSITIONS[@]}"; do
		if [[ "$valid" == "$transition" ]]; then
			return 0
		fi
	done

	return 1
}

#######################################
# Transition a task to a new state
#######################################
cmd_transition() {
	local task_id="" new_state="" error_msg=""
	local session_id="" worktree="" branch="" log_file="" pr_url=""

	# Positional args
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		new_state="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--error)
			[[ $# -lt 2 ]] && {
				log_error "--error requires a value"
				return 1
			}
			error_msg="$2"
			shift 2
			;;
		--session)
			[[ $# -lt 2 ]] && {
				log_error "--session requires a value"
				return 1
			}
			session_id="$2"
			shift 2
			;;
		--worktree)
			[[ $# -lt 2 ]] && {
				log_error "--worktree requires a value"
				return 1
			}
			worktree="$2"
			shift 2
			;;
		--branch)
			[[ $# -lt 2 ]] && {
				log_error "--branch requires a value"
				return 1
			}
			branch="$2"
			shift 2
			;;
		--log-file)
			[[ $# -lt 2 ]] && {
				log_error "--log-file requires a value"
				return 1
			}
			log_file="$2"
			shift 2
			;;
		--pr-url)
			[[ $# -lt 2 ]] && {
				log_error "--pr-url requires a value"
				return 1
			}
			pr_url="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$task_id" || -z "$new_state" ]]; then
		log_error "Usage: supervisor-helper.sh transition <task_id> <new_state> [--error \"reason\"]"
		return 1
	fi

	# Validate new_state is a known state
	if [[ ! " $VALID_STATES " =~ [[:space:]]${new_state}[[:space:]] ]]; then
		log_error "Invalid state: $new_state"
		log_error "Valid states: $VALID_STATES"
		return 1
	fi

	ensure_db

	# Get current state
	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local current_state
	current_state=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';")

	if [[ -z "$current_state" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	# Validate transition
	if ! validate_transition "$current_state" "$new_state"; then
		log_error "Invalid transition: $current_state -> $new_state for task $task_id"
		log_error "Valid transitions from '$current_state':"
		for valid in "${VALID_TRANSITIONS[@]}"; do
			if [[ "$valid" == "${current_state}:"* ]]; then
				echo "  -> ${valid#*:}"
			fi
		done
		return 1
	fi

	# Build UPDATE query with optional fields
	local -a update_parts=("status = '$new_state'")
	update_parts+=("updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')")

	if [[ -n "$error_msg" ]]; then
		update_parts+=("error = '$(sql_escape "$error_msg")'")
	fi

	# Set started_at on first dispatch
	if [[ "$new_state" == "dispatched" && "$current_state" == "queued" ]]; then
		update_parts+=("started_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')")
	fi

	# Set completed_at on terminal states
	if [[ "$new_state" == "complete" || "$new_state" == "deployed" || "$new_state" == "verified" || "$new_state" == "failed" || "$new_state" == "cancelled" ]]; then
		update_parts+=("completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')")
	fi

	# Increment retries on retry
	if [[ "$new_state" == "retrying" ]]; then
		update_parts+=("retries = retries + 1")
	fi

	# Set optional metadata fields
	if [[ -n "${session_id:-}" ]]; then
		update_parts+=("session_id = '$(sql_escape "$session_id")'")
	fi
	if [[ -n "${worktree:-}" ]]; then
		update_parts+=("worktree = '$(sql_escape "$worktree")'")
	fi
	if [[ -n "${branch:-}" ]]; then
		update_parts+=("branch = '$(sql_escape "$branch")'")
	fi
	if [[ -n "${log_file:-}" ]]; then
		update_parts+=("log_file = '$(sql_escape "$log_file")'")
	fi
	if [[ -n "${pr_url:-}" ]]; then
		update_parts+=("pr_url = '$(sql_escape "$pr_url")'")
	fi

	local update_sql
	update_sql=$(
		IFS=','
		echo "${update_parts[*]}"
	)

	db "$SUPERVISOR_DB" "
        UPDATE tasks SET $update_sql WHERE id = '$escaped_id';
    "

	# Log the transition
	local escaped_reason
	escaped_reason=$(sql_escape "${error_msg:-State transition}")
	db "$SUPERVISOR_DB" "
        INSERT INTO state_log (task_id, from_state, to_state, reason)
        VALUES ('$escaped_id', '$current_state', '$new_state', '$escaped_reason');
    "

	log_success "Task $task_id: $current_state -> $new_state"
	if [[ -n "$error_msg" ]]; then
		log_info "Reason: $error_msg"
	fi

	# Proof-log: record lifecycle stage transitions (t218)
	# Only log transitions that represent significant pipeline stages
	# (not every micro-transition, to keep proof-logs focused)
	case "$new_state" in
	dispatched | pr_review | review_triage | merging | merged | deploying | deployed | verifying | verified | verify_failed)
		local _stage_duration
		_stage_duration=$(_proof_log_stage_duration "$task_id" "$current_state")
		write_proof_log --task "$task_id" --event "transition" --stage "$new_state" \
			--decision "$current_state->$new_state" \
			--evidence "${error_msg:+error=$error_msg}" \
			--maker "cmd_transition" \
			${pr_url:+--pr-url "$pr_url"} \
			${_stage_duration:+--duration "$_stage_duration"} 2>/dev/null || true
		;;
	esac

	# t1009: Sync GitHub issue status label on every state transition
	# Best-effort — silently skips if gh CLI unavailable or no issue linked
	sync_issue_status_label "$task_id" "$new_state" "$current_state" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true

	# Auto-generate VERIFY.md entry when task reaches deployed (t180.4)
	if [[ "$new_state" == "deployed" ]]; then
		generate_verify_entry "$task_id" 2>>"$SUPERVISOR_LOG" || true
	fi

	# Check if batch is complete after task completion
	check_batch_completion "$task_id"

	return 0
}

#######################################
# Show status of a task, batch, or overall
#######################################
cmd_status() {
	local target="${1:-}"

	ensure_db

	if [[ -z "$target" ]]; then
		# Overall status
		echo -e "${BOLD}=== Supervisor Status ===${NC}"
		echo ""

		# Task counts by state
		echo "Tasks:"
		db -separator ': ' "$SUPERVISOR_DB" "
            SELECT status, count(*) FROM tasks GROUP BY status ORDER BY
            CASE status
                WHEN 'running' THEN 1
                WHEN 'dispatched' THEN 2
                WHEN 'evaluating' THEN 3
                WHEN 'retrying' THEN 4
                WHEN 'queued' THEN 5
                WHEN 'pr_review' THEN 6
                WHEN 'review_triage' THEN 7
                WHEN 'merging' THEN 8
                WHEN 'deploying' THEN 9
                WHEN 'blocked' THEN 10
                WHEN 'failed' THEN 11
                WHEN 'complete' THEN 12
                WHEN 'merged' THEN 13
                WHEN 'deployed' THEN 14
                WHEN 'cancelled' THEN 15
            END;
        " 2>/dev/null | while IFS=': ' read -r state count; do
			local color="$NC"
			case "$state" in
			running | dispatched) color="$GREEN" ;;
			evaluating | retrying | pr_review | review_triage | merging | deploying | verifying) color="$YELLOW" ;;
			blocked | failed | verify_failed) color="$RED" ;;
			complete | merged) color="$CYAN" ;;
			deployed | verified) color="$GREEN" ;;
			esac
			echo -e "  ${color}${state}${NC}: $count"
		done

		local total
		total=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks;")
		echo "  total: $total"
		echo ""

		# Active batches
		echo "Batches:"
		local batches
		batches=$(db -separator '|' "$SUPERVISOR_DB" "
            SELECT b.id, b.name, b.concurrency, b.status,
                   (SELECT count(*) FROM batch_tasks bt WHERE bt.batch_id = b.id) as task_count,
                   (SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
                    WHERE bt.batch_id = b.id AND t.status = 'complete') as done_count,
                   b.release_on_complete, b.release_type
            FROM batches b ORDER BY b.created_at DESC LIMIT 10;
        ")

		if [[ -n "$batches" ]]; then
			while IFS='|' read -r bid bname bconc bstatus btotal bdone brelease_flag brelease_type; do
				local release_label=""
				if [[ "${brelease_flag:-0}" -eq 1 ]]; then
					release_label=", release:${brelease_type:-patch}"
				fi
				echo -e "  ${CYAN}$bname${NC} ($bid) [$bstatus] $bdone/$btotal tasks, concurrency:$bconc${release_label}"
			done <<<"$batches"
		else
			echo "  No batches"
		fi

		echo ""

		# DB file size
		if [[ -f "$SUPERVISOR_DB" ]]; then
			local db_size
			db_size=$(du -h "$SUPERVISOR_DB" | cut -f1)
			echo "Database: $SUPERVISOR_DB ($db_size)"
		fi

		return 0
	fi

	# Check if target is a task or batch
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, repo, description, status, session_id, worktree, branch,
               log_file, retries, max_retries, model, error, pr_url,
               created_at, started_at, completed_at
        FROM tasks WHERE id = '$(sql_escape "$target")';
    ")

	if [[ -n "$task_row" ]]; then
		echo -e "${BOLD}=== Task: $target ===${NC}"
		IFS='|' read -r tid trepo tdesc tstatus tsession tworktree tbranch \
			tlog tretries tmax_retries tmodel terror tpr tcreated tstarted tcompleted <<<"$task_row"

		echo -e "  Status:      ${BOLD}$tstatus${NC}"
		echo "  Repo:        $trepo"
		[[ -n "$tdesc" ]] && echo "  Description: $(echo "$tdesc" | head -c 100)"
		echo "  Model:       $tmodel"
		echo "  Retries:     $tretries / $tmax_retries"
		[[ -n "$tsession" ]] && echo "  Session:     $tsession"
		[[ -n "$tworktree" ]] && echo "  Worktree:    $tworktree"
		[[ -n "$tbranch" ]] && echo "  Branch:      $tbranch"
		[[ -n "$tlog" ]] && echo "  Log:         $tlog"
		[[ -n "$terror" ]] && echo -e "  Error:       ${RED}$terror${NC}"
		[[ -n "$tpr" ]] && echo "  PR:          $tpr"
		echo "  Created:     $tcreated"
		[[ -n "$tstarted" ]] && echo "  Started:     $tstarted"
		[[ -n "$tcompleted" ]] && echo "  Completed:   $tcompleted"

		# Show state history
		echo ""
		echo "  State History:"
		db -separator '|' "$SUPERVISOR_DB" "
            SELECT from_state, to_state, reason, timestamp
            FROM state_log WHERE task_id = '$(sql_escape "$target")'
            ORDER BY timestamp ASC;
        " | while IFS='|' read -r from to reason ts; do
			if [[ -z "$from" ]]; then
				echo "    $ts: -> $to ($reason)"
			else
				echo "    $ts: $from -> $to ($reason)"
			fi
		done

		# Show batch membership
		local batch_membership
		batch_membership=$(db -separator '|' "$SUPERVISOR_DB" "
            SELECT b.name, b.id FROM batch_tasks bt
            JOIN batches b ON bt.batch_id = b.id
            WHERE bt.task_id = '$(sql_escape "$target")';
        ")
		if [[ -n "$batch_membership" ]]; then
			echo ""
			echo "  Batches:"
			while IFS='|' read -r bname bid; do
				echo "    $bname ($bid)"
			done <<<"$batch_membership"
		fi

		return 0
	fi

	# Check if target is a batch
	local batch_row
	batch_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, name, concurrency, status, created_at, release_on_complete, release_type
        FROM batches WHERE id = '$(sql_escape "$target")' OR name = '$(sql_escape "$target")';
    ")

	if [[ -n "$batch_row" ]]; then
		local bid bname bconc bstatus bcreated brelease_flag brelease_type
		IFS='|' read -r bid bname bconc bstatus bcreated brelease_flag brelease_type <<<"$batch_row"
		local bmax_conc
		bmax_conc=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_concurrency, 0) FROM batches WHERE id = '$(sql_escape "$bid")';" 2>/dev/null || echo "0")
		local bmax_load
		bmax_load=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_load_factor, 2) FROM batches WHERE id = '$(sql_escape "$bid")';" 2>/dev/null || echo "2")
		local badaptive
		badaptive=$(calculate_adaptive_concurrency "${bconc:-4}" "${bmax_load:-2}" "${bmax_conc:-0}")
		local cap_display="auto"
		[[ "${bmax_conc:-0}" -gt 0 ]] && cap_display="$bmax_conc"
		echo -e "${BOLD}=== Batch: $bname ===${NC}"
		echo "  ID:          $bid"
		echo "  Status:      $bstatus"
		echo "  Concurrency: $bconc (adaptive: $badaptive, cap: $cap_display)"
		if [[ "${brelease_flag:-0}" -eq 1 ]]; then
			echo -e "  Release:     ${GREEN}enabled${NC} (${brelease_type:-patch} on complete)"
		else
			echo "  Release:     disabled"
		fi
		echo "  Created:     $bcreated"
		echo ""
		echo "  Tasks:"

		db -separator '|' "$SUPERVISOR_DB" "
            SELECT t.id, t.status, t.description, t.retries, t.max_retries
            FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$(sql_escape "$bid")'
            ORDER BY bt.position;
        " | while IFS='|' read -r tid tstatus tdesc tretries tmax; do
			local color="$NC"
			case "$tstatus" in
			running | dispatched) color="$GREEN" ;;
			evaluating | retrying | pr_review | review_triage | merging | deploying | verifying) color="$YELLOW" ;;
			blocked | failed | verify_failed) color="$RED" ;;
			complete | merged) color="$CYAN" ;;
			deployed | verified) color="$GREEN" ;;
			esac
			local desc_short
			desc_short=$(echo "$tdesc" | head -c 60)
			echo -e "    ${color}[$tstatus]${NC} $tid: $desc_short (retries: $tretries/$tmax)"
		done

		return 0
	fi

	log_error "Not found: $target (not a task ID or batch ID/name)"
	return 1
}

#######################################
# List tasks with optional filters
#######################################
cmd_list() {
	local state="" batch="" format="text"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--state)
			[[ $# -lt 2 ]] && {
				log_error "--state requires a value"
				return 1
			}
			state="$2"
			shift 2
			;;
		--batch)
			[[ $# -lt 2 ]] && {
				log_error "--batch requires a value"
				return 1
			}
			batch="$2"
			shift 2
			;;
		--format)
			[[ $# -lt 2 ]] && {
				log_error "--format requires a value"
				return 1
			}
			format="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	local where_clauses=()
	if [[ -n "$state" ]]; then
		where_clauses+=("t.status = '$(sql_escape "$state")'")
	fi
	if [[ -n "$batch" ]]; then
		where_clauses+=("EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$(sql_escape "$batch")')")
	fi

	local where_sql=""
	if [[ ${#where_clauses[@]} -gt 0 ]]; then
		where_sql="WHERE $(
			IFS=' AND '
			echo "${where_clauses[*]}"
		)"
	fi

	if [[ "$format" == "json" ]]; then
		db -json "$SUPERVISOR_DB" "
            SELECT t.id, t.repo, t.description, t.status, t.retries, t.max_retries,
                   t.model, t.error, t.pr_url, t.session_id, t.worktree, t.branch,
                   t.created_at, t.started_at, t.completed_at
            FROM tasks t $where_sql
            ORDER BY t.created_at DESC;
        "
	else
		local results
		results=$(db -separator '|' "$SUPERVISOR_DB" "
            SELECT t.id, t.status, t.description, t.retries, t.max_retries, t.repo
            FROM tasks t $where_sql
            ORDER BY
                CASE t.status
                    WHEN 'running' THEN 1
                    WHEN 'dispatched' THEN 2
                    WHEN 'evaluating' THEN 3
                    WHEN 'retrying' THEN 4
                    WHEN 'queued' THEN 5
                    WHEN 'pr_review' THEN 6
                    WHEN 'review_triage' THEN 7
                    WHEN 'merging' THEN 8
                    WHEN 'deploying' THEN 9
                    WHEN 'blocked' THEN 10
                    WHEN 'failed' THEN 11
                    WHEN 'complete' THEN 12
                    WHEN 'merged' THEN 13
                    WHEN 'deployed' THEN 14
                    WHEN 'cancelled' THEN 15
                END, t.created_at DESC;
        ")

		if [[ -z "$results" ]]; then
			log_info "No tasks found"
			return 0
		fi

		while IFS='|' read -r tid tstatus tdesc tretries tmax trepo; do
			local color="$NC"
			case "$tstatus" in
			running | dispatched) color="$GREEN" ;;
			evaluating | retrying | pr_review | review_triage | merging | deploying | verifying) color="$YELLOW" ;;
			blocked | failed | verify_failed) color="$RED" ;;
			complete | merged) color="$CYAN" ;;
			deployed | verified) color="$GREEN" ;;
			esac
			local desc_short
			desc_short=$(echo "$tdesc" | head -c 60)
			echo -e "${color}[$tstatus]${NC} $tid: $desc_short (retries: $tretries/$tmax)"
		done <<<"$results"
	fi

	return 0
}

#######################################
# Reset a task back to queued state
#######################################
cmd_reset() {
	local task_id="${1:-}"

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh reset <task_id>"
		return 1
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local current_state
	current_state=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';")

	if [[ -z "$current_state" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	if [[ "$current_state" == "queued" ]]; then
		log_info "Task $task_id is already queued"
		return 0
	fi

	# Only allow reset from terminal or blocked states
	if [[ "$current_state" != "blocked" && "$current_state" != "failed" && "$current_state" != "cancelled" && "$current_state" != "complete" ]]; then
		log_error "Cannot reset task in '$current_state' state. Only blocked/failed/cancelled/complete tasks can be reset."
		return 1
	fi

	# Pre-reset check: prevent re-queuing tasks that already have a merged PR (t224).
	# Without this, a completed task can be reset -> queued -> dispatched, wasting
	# an entire AI session on work that's already done and merged.
	local task_repo
	task_repo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';")
	if check_task_already_done "$task_id" "${task_repo:-.}"; then
		log_warn "Task $task_id has a merged PR or is marked [x] in TODO.md — refusing reset"
		log_warn "Use 'cancel' instead, or remove the merged PR reference to force reset"
		return 1
	fi

	db "$SUPERVISOR_DB" "
        UPDATE tasks SET
            status = 'queued',
            retries = 0,
            error = NULL,
            session_id = NULL,
            worktree = NULL,
            branch = NULL,
            log_file = NULL,
            pr_url = NULL,
            started_at = NULL,
            completed_at = NULL,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE id = '$escaped_id';
    "

	db "$SUPERVISOR_DB" "
        INSERT INTO state_log (task_id, from_state, to_state, reason)
        VALUES ('$escaped_id', '$current_state', 'queued', 'Manual reset');
    "

	log_success "Task $task_id reset: $current_state -> queued"
	return 0
}

#######################################
# Cancel a task or batch
#######################################
cmd_cancel() {
	local target="${1:-}"

	if [[ -z "$target" ]]; then
		log_error "Usage: supervisor-helper.sh cancel <task_id|batch_id>"
		return 1
	fi

	ensure_db

	local escaped_target
	escaped_target=$(sql_escape "$target")

	# Try as task first
	local task_status
	task_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_target';")

	if [[ -n "$task_status" ]]; then
		if [[ "$task_status" == "deployed" || "$task_status" == "cancelled" || "$task_status" == "failed" ]]; then
			log_warn "Task $target is already in terminal state: $task_status"
			return 0
		fi

		# Check if transition is valid
		if ! validate_transition "$task_status" "cancelled"; then
			log_error "Cannot cancel task in '$task_status' state"
			return 1
		fi

		db "$SUPERVISOR_DB" "
            UPDATE tasks SET
                status = 'cancelled',
                completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = '$escaped_target';
        "

		db "$SUPERVISOR_DB" "
            INSERT INTO state_log (task_id, from_state, to_state, reason)
            VALUES ('$escaped_target', '$task_status', 'cancelled', 'Manual cancellation');
        "

		log_success "Cancelled task: $target"
		return 0
	fi

	# Try as batch
	local batch_status
	batch_status=$(db "$SUPERVISOR_DB" "SELECT status FROM batches WHERE id = '$escaped_target' OR name = '$escaped_target';")

	if [[ -n "$batch_status" ]]; then
		local batch_id
		batch_id=$(db "$SUPERVISOR_DB" "SELECT id FROM batches WHERE id = '$escaped_target' OR name = '$escaped_target';")
		local escaped_batch
		escaped_batch=$(sql_escape "$batch_id")

		db "$SUPERVISOR_DB" "
            UPDATE batches SET status = 'cancelled', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = '$escaped_batch';
        "

		# Cancel all non-terminal tasks in the batch
		local cancelled_count
		cancelled_count=$(db "$SUPERVISOR_DB" "
            SELECT count(*) FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$escaped_batch'
            AND t.status NOT IN ('deployed', 'merged', 'failed', 'cancelled');
        ")

		db "$SUPERVISOR_DB" "
            UPDATE tasks SET
                status = 'cancelled',
                completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id IN (
                SELECT task_id FROM batch_tasks WHERE batch_id = '$escaped_batch'
            ) AND status NOT IN ('deployed', 'merged', 'failed', 'cancelled');
        "

		log_success "Cancelled batch: $target ($cancelled_count tasks cancelled)"
		return 0
	fi

	log_error "Not found: $target"
	return 1
}

#######################################
# Check if a batch is complete after task state change
#######################################
check_batch_completion() {
	local task_id="$1"
	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Find batches containing this task
	local batch_ids
	batch_ids=$(db "$SUPERVISOR_DB" "
        SELECT batch_id FROM batch_tasks WHERE task_id = '$escaped_id';
    ")

	if [[ -z "$batch_ids" ]]; then
		return 0
	fi

	while IFS= read -r batch_id; do
		local escaped_batch
		escaped_batch=$(sql_escape "$batch_id")

		# Count incomplete tasks in this batch
		local incomplete
		incomplete=$(db "$SUPERVISOR_DB" "
            SELECT count(*) FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$escaped_batch'
            AND t.status NOT IN ('complete', 'deployed', 'verified', 'merged', 'failed', 'cancelled');
        ")

		if [[ "$incomplete" -eq 0 ]]; then
			db "$SUPERVISOR_DB" "
                UPDATE batches SET status = 'complete', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                WHERE id = '$escaped_batch' AND status = 'active';
            "
			log_success "Batch $batch_id is now complete"
			# Run batch retrospective and store insights (t128.6)
			run_batch_retrospective "$batch_id" 2>>"$SUPERVISOR_LOG" || true

			# Run session review and distillation (t128.9)
			run_session_review "$batch_id" 2>>"$SUPERVISOR_LOG" || true

			# Trigger automatic release if configured (t128.10)
			local batch_release_flag
			batch_release_flag=$(db "$SUPERVISOR_DB" "SELECT release_on_complete FROM batches WHERE id = '$escaped_batch';" 2>/dev/null || echo "0")
			if [[ "$batch_release_flag" -eq 1 ]]; then
				local batch_release_type
				batch_release_type=$(db "$SUPERVISOR_DB" "SELECT release_type FROM batches WHERE id = '$escaped_batch';" 2>/dev/null || echo "patch")
				# Get repo from the first task in the batch
				local batch_repo
				batch_repo=$(db "$SUPERVISOR_DB" "
                    SELECT t.repo FROM batch_tasks bt
                    JOIN tasks t ON bt.task_id = t.id
                    WHERE bt.batch_id = '$escaped_batch'
                    ORDER BY bt.position LIMIT 1;
                " 2>/dev/null || echo "")
				if [[ -n "$batch_repo" ]]; then
					log_info "Batch $batch_id has release_on_complete enabled ($batch_release_type)"
					trigger_batch_release "$batch_id" "$batch_release_type" "$batch_repo" 2>>"$SUPERVISOR_LOG" || {
						log_error "Automatic release failed for batch $batch_id (non-blocking)"
					}
				else
					log_warn "Cannot trigger release for batch $batch_id: no repo found"
				fi
			fi
		fi
	done <<<"$batch_ids"

	return 0
}

#######################################
# Get count of running tasks (for concurrency checks)
#######################################
cmd_running_count() {
	ensure_db

	local batch_id="${1:-}"

	if [[ -n "$batch_id" ]]; then
		db "$SUPERVISOR_DB" "
            SELECT count(*) FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$(sql_escape "$batch_id")'
            AND t.status IN ('dispatched', 'running', 'evaluating');
        "
	else
		db "$SUPERVISOR_DB" "
            SELECT count(*) FROM tasks
            WHERE status IN ('dispatched', 'running', 'evaluating');
        "
	fi

	return 0
}

#######################################
# Get next queued tasks eligible for dispatch
#
# Returns queued tasks up to $limit. Does NOT check concurrency here —
# cmd_dispatch() performs the authoritative concurrency check with a fresh
# running count at dispatch time. This avoids a TOCTOU race where cmd_next()
# computes available slots based on a stale count, then cmd_dispatch() sees
# a different count after prior dispatches in the same pulse loop (t172).
#######################################
cmd_next() {
	local batch_id="${1:-}" limit="${2:-1}"

	ensure_db

	if [[ -n "$batch_id" ]]; then
		local escaped_batch
		escaped_batch=$(sql_escape "$batch_id")

		db -separator $'\t' "$SUPERVISOR_DB" "
            SELECT t.id, t.repo, t.description, t.model
            FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$escaped_batch'
            AND t.status = 'queued'
            AND t.retries < t.max_retries
            ORDER BY t.retries ASC, bt.position
            LIMIT $limit;
        "
	else
		db -separator $'\t' "$SUPERVISOR_DB" "
            SELECT id, repo, description, model
            FROM tasks
            WHERE status = 'queued'
            AND retries < max_retries
            ORDER BY retries ASC, created_at ASC
            LIMIT $limit;
        "
	fi

	return 0
}
