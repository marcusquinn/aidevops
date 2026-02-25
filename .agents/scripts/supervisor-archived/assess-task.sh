#!/usr/bin/env bash
# assess-task.sh - AI-powered task assessment
#
# Primary task evaluation engine (t1312: evaluate_worker removed from evaluate.sh).
# Replaces the former 687-line deterministic evaluate_worker() heuristic tree with
# a single AI call that reads the actual sources of truth:
#   1. Worker log (last 100 lines)
#   2. TODO.md (task line)
#   3. GitHub (PR state, issue state)
#   4. Process table (is worker alive?)
#   5. DB state (for context, not as truth)
#
# Returns a structured verdict: complete:<pr_url>, retry:<reason>, failed:<reason>
#
# Cost: ~$0.001 per call with haiku. Workers cost $0.50-2.00 each.
#
# Sourced by: supervisor-helper.sh
# Used by: pulse.sh Phase 1

# Gather all evidence about a task from real sources (not just DB)
gather_task_evidence() {
	local task_id="$1"

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# --- DB state (context, not truth) ---
	local db_row
	db_row=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT status, log_file, retries, max_retries, pr_url, repo, branch, error, model
		FROM tasks WHERE id = '$escaped_id';
	" 2>/dev/null || echo "")

	if [[ -z "$db_row" ]]; then
		echo "error:task_not_found"
		return 1
	fi

	local db_status db_log db_retries db_max_retries db_pr_url db_repo db_branch db_error db_model
	IFS='|' read -r db_status db_log db_retries db_max_retries db_pr_url db_repo db_branch db_error db_model <<<"$db_row"

	# --- Worker process (is it alive?) ---
	local worker_alive="false"
	local pid_file="$SUPERVISOR_DIR/pids/${task_id}.pid"
	if [[ -f "$pid_file" ]]; then
		local pid
		pid=$(cat "$pid_file" 2>/dev/null || echo "")
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
			worker_alive="true"
		fi
	fi

	# --- Worker log (last 100 lines of actual content) ---
	local log_tail="(no log file)"
	local log_signal="none" log_exit="" log_pr_url="" log_started="false"
	if [[ -n "$db_log" && -f "$db_log" ]]; then
		# Extract structured metadata
		local log_size
		log_size=$(wc -c <"$db_log" 2>/dev/null | tr -d ' ')

		if [[ "$log_size" -gt 0 ]]; then
			log_started="true"

			# Get completion signal
			if grep -q 'FULL_LOOP_COMPLETE' "$db_log" 2>/dev/null; then
				log_signal="FULL_LOOP_COMPLETE"
			elif grep -q 'VERIFY_COMPLETE' "$db_log" 2>/dev/null; then
				log_signal="VERIFY_COMPLETE"
			elif grep -q 'VERIFY_NOT_STARTED' "$db_log" 2>/dev/null; then
				log_signal="VERIFY_NOT_STARTED"
			elif grep -q 'VERIFY_INCOMPLETE' "$db_log" 2>/dev/null; then
				log_signal="VERIFY_INCOMPLETE"
			elif grep -q 'TASK_COMPLETE' "$db_log" 2>/dev/null; then
				log_signal="TASK_COMPLETE"
			fi

			# Get exit code
			log_exit=$(grep -o 'EXIT:[0-9]*' "$db_log" 2>/dev/null | tail -1 | cut -d: -f2 || echo "")

			# Get PR URL from final text output
			local last_text
			last_text=$(grep '"type":"text"' "$db_log" 2>/dev/null | tail -1 || true)
			if [[ -n "$last_text" ]]; then
				log_pr_url=$(echo "$last_text" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | tail -1 || true)
			fi

			# Get the last 50 lines of actual text content (not JSON metadata)
			log_tail=$(grep '"type":"text"' "$db_log" 2>/dev/null | tail -5 | sed -n 's/.*"text":"\([^"]*\)".*/\1/p' 2>/dev/null | tail -50 || tail -50 "$db_log" 2>/dev/null || echo "(could not read log)")
		fi
	elif [[ -z "$db_log" ]]; then
		log_tail="(no log path in DB — dispatch may have failed)"
	elif [[ ! -f "$db_log" ]]; then
		log_tail="(log file missing: $db_log)"
	fi

	# --- TODO.md (is task checked off?) ---
	local todo_state="unknown"
	local todo_line=""
	if [[ -n "$db_repo" && -d "$db_repo" ]]; then
		local todo_file="$db_repo/TODO.md"
		if [[ -f "$todo_file" ]]; then
			# Get the first occurrence of this task ID
			todo_line=$(grep -m1 "$task_id" "$todo_file" 2>/dev/null || echo "")
			if [[ -n "$todo_line" ]]; then
				if [[ "$todo_line" == *"[x]"* || "$todo_line" == *"[X]"* ]]; then
					todo_state="checked"
				else
					todo_state="open"
				fi
			else
				todo_state="not_found"
			fi
		fi
	fi

	# --- GitHub (PR state, if we have a PR URL) ---
	local gh_pr_state="" gh_pr_merged="" gh_pr_url=""
	local pr_to_check="${log_pr_url:-$db_pr_url}"
	if [[ -n "$pr_to_check" && "$pr_to_check" != "no_pr" && "$pr_to_check" != "task_only" && "$pr_to_check" != "verified_complete" && "$pr_to_check" != "task_obsolete" ]]; then
		gh_pr_url="$pr_to_check"
		# Parse PR URL to get repo and number
		local pr_repo pr_number
		pr_repo=$(echo "$pr_to_check" | grep -oE 'github\.com/[^/]+/[^/]+' | sed 's|github.com/||' || echo "")
		pr_number=$(echo "$pr_to_check" | grep -oE '/pull/[0-9]+' | sed 's|/pull/||' || echo "")
		if [[ -n "$pr_repo" && -n "$pr_number" ]]; then
			gh_pr_state=$(gh pr view "$pr_number" --repo "$pr_repo" --json state --jq '.state' </dev/null 2>/dev/null || echo "UNKNOWN")
			if [[ "$gh_pr_state" == "MERGED" ]]; then
				gh_pr_merged="true"
			else
				gh_pr_merged="false"
			fi
		fi
	fi

	# --- GitHub (check for PR by branch if no PR URL known) ---
	if [[ -z "$gh_pr_url" && -n "$db_branch" && -n "$db_repo" ]]; then
		local repo_slug
		repo_slug=$(detect_repo_slug "$db_repo" 2>/dev/null || echo "")
		if [[ -n "$repo_slug" ]]; then
			local branch_pr
			branch_pr=$(gh pr list --repo "$repo_slug" --head "$db_branch" --json url,state --jq '.[0] | "\(.url)|\(.state)"' </dev/null 2>/dev/null || echo "")
			if [[ -n "$branch_pr" ]]; then
				gh_pr_url="${branch_pr%%|*}"
				gh_pr_state="${branch_pr##*|}"
				[[ "$gh_pr_state" == "MERGED" ]] && gh_pr_merged="true" || gh_pr_merged="false"
			fi
		fi
	fi

	# --- Output structured evidence ---
	cat <<EVIDENCE
## Task: $task_id
DB status: $db_status | Retries: $db_retries/$db_max_retries | Model: ${db_model:-unknown}
DB error: ${db_error:-(none)}
Worker alive: $worker_alive
Log signal: $log_signal | Exit code: ${log_exit:-(none)} | Log started: $log_started
TODO.md: $todo_state${todo_line:+ — $todo_line}
PR URL: ${gh_pr_url:-(none)} | PR state: ${gh_pr_state:-(none)} | Merged: ${gh_pr_merged:-(none)}

### Worker log tail:
$log_tail
EVIDENCE
}

# Call AI to assess a task and return a structured verdict
assess_task() {
	local task_id="$1"

	# Gather evidence from all real sources
	local evidence
	evidence=$(gather_task_evidence "$task_id" 2>/dev/null)

	if [[ "$evidence" == "error:task_not_found" ]]; then
		echo "failed:task_not_found"
		return 0
	fi

	# Fast path: if worker is still alive, skip AI call
	if echo "$evidence" | grep -q 'Worker alive: true'; then
		echo "alive"
		return 0
	fi

	# Fast path: if log has FULL_LOOP_COMPLETE + PR URL, no AI needed
	local log_signal log_pr gh_pr_state
	log_signal=$(echo "$evidence" | grep 'Log signal:' | grep -oE 'FULL_LOOP_COMPLETE|VERIFY_COMPLETE|VERIFY_NOT_STARTED|VERIFY_INCOMPLETE|TASK_COMPLETE' || echo "none")
	log_pr=$(echo "$evidence" | grep 'PR URL:' | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' || echo "")
	gh_pr_state=$(echo "$evidence" | grep 'PR state:' | sed 's/.*PR state: //' | sed 's/ |.*//' || echo "")

	# Deterministic fast paths — no AI needed for clear-cut cases
	if [[ "$log_signal" == "FULL_LOOP_COMPLETE" && -n "$log_pr" ]]; then
		echo "complete:${log_pr}"
		return 0
	fi
	if [[ "$log_signal" == "VERIFY_COMPLETE" ]]; then
		echo "complete:${log_pr:-verified_complete}"
		return 0
	fi
	if [[ "$log_signal" == "VERIFY_NOT_STARTED" && -n "$log_pr" ]]; then
		echo "complete:${log_pr}"
		return 0
	fi
	if [[ "$gh_pr_state" == "MERGED" && -n "$log_pr" ]]; then
		echo "complete:${log_pr}"
		return 0
	fi

	# No log file at all — dispatch failed
	if echo "$evidence" | grep -q 'Log started: false\|no log path in DB\|log file missing'; then
		echo "failed:no_worker_output"
		return 0
	fi

	# For ambiguous cases, call AI
	local ai_cli ai_model
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		# No AI available — fall back to simple heuristic
		if [[ -n "$log_pr" ]]; then
			echo "complete:${log_pr}"
		else
			echo "retry:no_ai_available_for_assessment"
		fi
		return 0
	}

	ai_model=$(resolve_model "haiku" "$ai_cli" 2>/dev/null) || {
		ai_model=$(resolve_model "sonnet" "$ai_cli" 2>/dev/null) || {
			# No model — fall back
			if [[ -n "$log_pr" ]]; then
				echo "complete:${log_pr}"
			else
				echo "retry:no_model_for_assessment"
			fi
			return 0
		}
	}

	local prompt
	prompt="$(
		cat <<PROMPT
You are a task supervisor. Assess this task and return EXACTLY ONE LINE in this format:
  complete:<pr_url_or_verified_complete>
  retry:<brief_reason>
  failed:<brief_reason>

Rules:
- If the worker created a PR and it's open/merged → complete:<pr_url>
- If the worker verified the task is done (VERIFY_COMPLETE) → complete:verified_complete
- If the worker failed but retries remain → retry:<reason>
- If the worker failed and retries exhausted → failed:<reason>
- If the log shows rate limiting or transient errors → retry:rate_limited
- If the log shows the task is already done/obsolete → complete:verified_complete
- If there's no useful output at all → failed:no_useful_output

$evidence
PROMPT
	)"

	local ai_result=""
	local ai_timeout="${SUPERVISOR_ASSESS_TIMEOUT:-30}"

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout "$ai_timeout" opencode run \
			-m "$ai_model" \
			--format default \
			--title "assess-${task_id}" \
			"$prompt" </dev/null 2>/dev/null || echo "")
		# Strip ANSI codes
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		local claude_model="${ai_model#*/}"
		ai_result=$(portable_timeout "$ai_timeout" claude \
			-p "$prompt" \
			--model "$claude_model" \
			--output-format text </dev/null 2>/dev/null || echo "")
	fi

	# Parse the verdict from AI response — find the first line matching our format
	local verdict=""
	verdict=$(echo "$ai_result" | grep -oE '^(complete|retry|failed):.*' | head -1 || echo "")

	if [[ -z "$verdict" ]]; then
		# AI didn't return a parseable verdict — fall back
		log_warn "assess_task: AI returned unparseable response for $task_id, falling back"
		if [[ -n "$log_pr" ]]; then
			verdict="complete:${log_pr}"
		elif [[ "$log_signal" != "none" ]]; then
			verdict="retry:ai_assessment_unparseable"
		else
			verdict="failed:ai_assessment_unparseable"
		fi
	fi

	log_info "assess_task: $task_id → $verdict (via $ai_model)"
	echo "$verdict"
}

# Wrapper that matches evaluate_worker_with_metadata() interface
# for drop-in replacement in pulse.sh Phase 1
assess_task_with_metadata() {
	local task_id="$1"
	local _skip_ai="${2:-false}" # ignored — we always use our own AI path

	local verdict
	verdict=$(assess_task "$task_id")

	local outcome_type="${verdict%%:*}"
	local outcome_detail="${verdict#*:}"

	# Classify failure mode and quality for pattern tracking
	local failure_mode="NONE"
	local quality_score="2"
	if [[ "$outcome_type" != "complete" && "$outcome_type" != "alive" ]]; then
		failure_mode="$outcome_detail"
		quality_score="0"
	fi

	# Record to pattern tracker (stdout must be suppressed — we're inside
	# a command substitution and only our echo "$verdict" should reach stdout)
	if command -v record_evaluation_metadata &>/dev/null; then
		record_evaluation_metadata \
			"$task_id" "$outcome_type" "$outcome_detail" \
			"$failure_mode" "$quality_score" "true" \
			>/dev/null 2>/dev/null || true
	fi

	log_info "assess_task_with_metadata: $task_id → $verdict [fmode:${failure_mode}] [quality:${quality_score}] [ai:true]"
	echo "$verdict"
}
