#!/usr/bin/env bash
# stuck-detection.sh - Advisory stuck detection for long-running tasks (t1332)
#
# At configurable time milestones (default: 30/60/120 min), evaluates
# long-running task progress via haiku-tier AI reasoning. If stuck detected
# (confidence >0.7), tags GitHub issue with `stuck-detection` label and posts
# explanatory comment with suggested actions.
#
# ADVISORY ONLY — never auto-cancels, auto-pivots, or modifies tasks.
# Label removed on subsequent success.
#
# Inspired by Ouroboros soft self-check at round milestones.
#
# Used by: pulse.sh Phase 0.75 (Stuck Detection)
# Depends on: dispatch.sh (resolve_ai_cli, resolve_model)
#             issue-sync.sh (find_task_issue_number, detect_repo_slug)
#             _common.sh (db, log_*, sql_escape, portable_timeout)
# Sourced by: supervisor-helper.sh (set -euo pipefail inherited)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SUPERVISOR_DIR, SCRIPT_DIR
#   db(), log_info(), log_warn(), log_error(), log_verbose(), sql_escape()
#   resolve_model(), resolve_ai_cli(), portable_timeout()
#   find_task_issue_number(), detect_repo_slug()

# Configurable milestones (space-separated minutes, ascending order)
# Override via env: SUPERVISOR_STUCK_MILESTONES="30 60 120"
STUCK_DETECTION_MILESTONES="${SUPERVISOR_STUCK_MILESTONES:-30 60 120}"

# Confidence threshold for stuck detection (0.0-1.0)
STUCK_DETECTION_CONFIDENCE_THRESHOLD="${SUPERVISOR_STUCK_CONFIDENCE_THRESHOLD:-0.7}"

# GitHub label for stuck detection
STUCK_DETECTION_LABEL="stuck-detection"

# Stuck detection log table name
STUCK_DETECTION_TABLE="stuck_detection_log"

#######################################
# Ensure the stuck_detection_log table exists (t1332)
# Tracks each milestone check: task, milestone, AI verdict, confidence.
# Called by ensure_db migration and by check functions.
#######################################
_create_stuck_detection_schema() {
	db "$SUPERVISOR_DB" <<'STUCK_SCHEMA'
CREATE TABLE IF NOT EXISTS stuck_detection_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id         TEXT NOT NULL,
    milestone_min   INTEGER NOT NULL,
    elapsed_min     INTEGER NOT NULL,
    confidence      REAL NOT NULL DEFAULT 0.0,
    is_stuck        INTEGER NOT NULL DEFAULT 0,
    reasoning       TEXT DEFAULT '',
    suggested_actions TEXT DEFAULT '',
    issue_labeled   INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_stuck_detection_task ON stuck_detection_log(task_id);
CREATE INDEX IF NOT EXISTS idx_stuck_detection_created ON stuck_detection_log(created_at);
STUCK_SCHEMA
	return 0
}

#######################################
# Check if a milestone has already been evaluated for a task (t1332)
# Prevents duplicate checks at the same milestone in the same run.
# Args:
#   $1 = task_id
#   $2 = milestone_min
# Returns: 0 if already checked, 1 if not
#######################################
_milestone_already_checked() {
	local task_id="$1"
	local milestone_min="$2"

	local count
	count=$(db "$SUPERVISOR_DB" "
		SELECT count(*) FROM ${STUCK_DETECTION_TABLE}
		WHERE task_id = '$(sql_escape "$task_id")'
		AND milestone_min = $milestone_min;
	" 2>/dev/null || echo "0")

	if [[ "$count" -gt 0 ]]; then
		return 0
	fi
	return 1
}

#######################################
# Get the next unchecked milestone for a task (t1332)
# Given elapsed minutes, returns the highest milestone that:
#   1. Has been reached (elapsed >= milestone)
#   2. Has NOT been checked yet
# Args:
#   $1 = task_id
#   $2 = elapsed_min (integer)
# Returns: milestone value via stdout, empty if none due
#######################################
_get_next_milestone() {
	local task_id="$1"
	local elapsed_min="$2"
	local result=""

	# Iterate milestones in ascending order, find highest unchecked one
	for milestone in $STUCK_DETECTION_MILESTONES; do
		if [[ "$elapsed_min" -ge "$milestone" ]]; then
			if ! _milestone_already_checked "$task_id" "$milestone"; then
				result="$milestone"
			fi
		fi
	done

	echo "$result"
	return 0
}

#######################################
# Build context for AI stuck evaluation (t1332)
# Gathers task metadata, log tail, state history, and timing info.
# Args:
#   $1 = task_id
#   $2 = elapsed_min
#   $3 = milestone_min
# Returns: context string via stdout
#######################################
_build_stuck_context() {
	local task_id="$1"
	local elapsed_min="$2"
	local milestone_min="$3"
	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Task metadata from DB
	local task_desc task_status task_retries task_model task_error task_started
	task_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	task_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	task_retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "0")
	task_model=$(db "$SUPERVISOR_DB" "SELECT model FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	task_error=$(db "$SUPERVISOR_DB" "SELECT error FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	task_started=$(db "$SUPERVISOR_DB" "SELECT started_at FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

	# Worker log tail (last 50 lines for context)
	local log_file log_tail
	log_file=$(db "$SUPERVISOR_DB" "SELECT log_file FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	log_tail=""
	if [[ -n "$log_file" && -f "$log_file" ]]; then
		log_tail=$(tail -50 "$log_file" 2>/dev/null || echo "(log unreadable)")
	else
		log_tail="(no log file available)"
	fi

	# State history
	local state_history
	state_history=$(db "$SUPERVISOR_DB" "
		SELECT from_state || ' -> ' || to_state || ' (' || reason || ') at ' || timestamp
		FROM state_log
		WHERE task_id = '$escaped_id'
		ORDER BY timestamp DESC
		LIMIT 10;
	" 2>/dev/null || echo "(no state history)")

	# Previous stuck checks for this task
	local prev_checks
	prev_checks=$(db "$SUPERVISOR_DB" "
		SELECT 'Milestone ' || milestone_min || 'min: stuck=' || is_stuck || ' confidence=' || confidence || ' (' || reasoning || ')'
		FROM ${STUCK_DETECTION_TABLE}
		WHERE task_id = '$escaped_id'
		ORDER BY created_at ASC;
	" 2>/dev/null || echo "(no previous checks)")

	# Compose context
	cat <<CONTEXT
## Task Stuck Detection Check

**Task ID**: ${task_id}
**Description**: ${task_desc}
**Status**: ${task_status}
**Model**: ${task_model}
**Started**: ${task_started}
**Elapsed**: ${elapsed_min} minutes
**Milestone**: ${milestone_min} minutes
**Retries**: ${task_retries}
**Last Error**: ${task_error:-none}

### State History (recent first)
${state_history}

### Previous Stuck Checks
${prev_checks}

### Worker Log (last 50 lines)
\`\`\`
${log_tail}
\`\`\`
CONTEXT
	return 0
}

#######################################
# Evaluate whether a task is stuck using haiku-tier AI (t1332)
# Returns JSON: {"is_stuck": bool, "confidence": float, "reasoning": str, "suggested_actions": str}
# Args:
#   $1 = task_id
#   $2 = elapsed_min
#   $3 = milestone_min
# Returns: JSON verdict via stdout
#######################################
_evaluate_stuck_with_ai() {
	local task_id="$1"
	local elapsed_min="$2"
	local milestone_min="$3"

	# Resolve AI CLI and model
	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_warn "stuck-detection: AI CLI not available, skipping evaluation for $task_id"
		echo '{"is_stuck": false, "confidence": 0.0, "reasoning": "AI CLI unavailable", "suggested_actions": ""}'
		return 0
	}

	local ai_model
	ai_model=$(resolve_model "haiku" "$ai_cli" 2>/dev/null) || {
		log_warn "stuck-detection: cannot resolve haiku model, skipping evaluation for $task_id"
		echo '{"is_stuck": false, "confidence": 0.0, "reasoning": "model unavailable", "suggested_actions": ""}'
		return 0
	}

	# Build context
	local context
	context=$(_build_stuck_context "$task_id" "$elapsed_min" "$milestone_min")

	local prompt
	prompt="You are a DevOps supervisor evaluating whether a long-running automated task is stuck.

${context}

Analyze the task's progress and determine if it appears stuck. Consider:
1. Is the worker log showing active progress (new output, file changes, test runs)?
2. Has the task been in the same state for an unusually long time?
3. Are there error patterns suggesting a loop or repeated failure?
4. Is the elapsed time reasonable for this type of task?
5. Could the worker be doing legitimate long-running work (large refactor, many tests)?

Respond with ONLY a JSON object (no markdown, no explanation outside JSON):
{
  \"is_stuck\": true/false,
  \"confidence\": 0.0-1.0,
  \"reasoning\": \"Brief explanation of why you think the task is/isn't stuck\",
  \"suggested_actions\": \"If stuck, what should the human operator consider doing\"
}"

	local ai_result=""
	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout 15 opencode run \
			-m "$ai_model" \
			--format default \
			--title "stuck-check-$$" \
			"$prompt" 2>/dev/null || echo "")
		# Strip ANSI escape codes
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		local claude_model="${ai_model#*/}"
		ai_result=$(portable_timeout 15 claude \
			-p "$prompt" \
			--model "$claude_model" \
			--output-format text 2>/dev/null || echo "")
	fi

	# Parse JSON from AI response
	if [[ -n "$ai_result" ]]; then
		local json_block
		json_block=$(printf '%s' "$ai_result" | grep -oE '\{[^}]+\}' | head -1)
		if [[ -n "$json_block" ]]; then
			# Validate it has required fields
			local has_is_stuck
			has_is_stuck=$(printf '%s' "$json_block" | jq -r '.is_stuck // empty' 2>/dev/null || echo "")
			if [[ -n "$has_is_stuck" ]]; then
				echo "$json_block"
				return 0
			fi
		fi
	fi

	# AI failed to produce valid JSON — return safe default
	log_warn "stuck-detection: AI evaluation failed for $task_id (no valid JSON), defaulting to not-stuck"
	echo '{"is_stuck": false, "confidence": 0.0, "reasoning": "AI evaluation failed to produce valid response", "suggested_actions": ""}'
	return 0
}

#######################################
# Apply stuck-detection label and comment to GitHub issue (t1332)
# ADVISORY ONLY — does not modify task state.
# Args:
#   $1 = task_id
#   $2 = confidence (float)
#   $3 = reasoning (string)
#   $4 = suggested_actions (string)
#   $5 = milestone_min
#   $6 = elapsed_min
# Returns: 0 on success, 1 on failure (non-fatal)
#######################################
_label_stuck_on_github() {
	local task_id="$1"
	local confidence="$2"
	local reasoning="$3"
	local suggested_actions="$4"
	local milestone_min="$5"
	local elapsed_min="$6"

	# Skip if gh CLI not available
	command -v gh &>/dev/null || return 0

	# Find the task's repo and issue
	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local repo_path
	repo_path=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	if [[ -z "$repo_path" ]]; then
		return 0
	fi

	local issue_number
	issue_number=$(find_task_issue_number "$task_id" "$repo_path")
	if [[ -z "$issue_number" ]]; then
		log_verbose "stuck-detection: no GitHub issue for $task_id, skipping label"
		return 0
	fi

	local repo_slug
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		return 0
	fi

	# Ensure the stuck-detection label exists
	gh label create "$STUCK_DETECTION_LABEL" --repo "$repo_slug" \
		--color "D93F0B" \
		--description "Advisory: AI detected task may be stuck (t1332)" \
		--force 2>/dev/null || true

	# Apply label
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "$STUCK_DETECTION_LABEL" 2>/dev/null || true

	# Post explanatory comment
	local comment_body
	comment_body=$(
		cat <<EOF
## Stuck Detection Advisory (t1332)

**Milestone**: ${milestone_min} min check (task running for ${elapsed_min} min)
**Confidence**: ${confidence}
**Assessment**: ${reasoning}

### Suggested Actions
${suggested_actions}

---
*This is an advisory notification only. No automated action has been taken. The \`${STUCK_DETECTION_LABEL}\` label will be automatically removed if the task completes successfully.*
EOF
	)

	gh issue comment "$issue_number" --repo "$repo_slug" \
		--body "$comment_body" 2>/dev/null || true

	log_info "stuck-detection: labeled issue #$issue_number for $task_id (confidence: $confidence)"
	return 0
}

#######################################
# Remove stuck-detection label from GitHub issue (t1332)
# Called when a previously-flagged task completes successfully.
# Args:
#   $1 = task_id
# Returns: 0
#######################################
remove_stuck_label_on_success() {
	local task_id="$1"

	# Check if this task was ever flagged as stuck
	local was_flagged
	was_flagged=$(db "$SUPERVISOR_DB" "
		SELECT count(*) FROM ${STUCK_DETECTION_TABLE}
		WHERE task_id = '$(sql_escape "$task_id")'
		AND is_stuck = 1;
	" 2>/dev/null || echo "0")

	if [[ "$was_flagged" -eq 0 ]]; then
		return 0
	fi

	# Skip if gh CLI not available
	command -v gh &>/dev/null || return 0

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local repo_path
	repo_path=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	if [[ -z "$repo_path" ]]; then
		return 0
	fi

	local issue_number
	issue_number=$(find_task_issue_number "$task_id" "$repo_path")
	if [[ -z "$issue_number" ]]; then
		return 0
	fi

	local repo_slug
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		return 0
	fi

	# Remove the label
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--remove-label "$STUCK_DETECTION_LABEL" 2>/dev/null || true

	# Post resolution comment
	gh issue comment "$issue_number" --repo "$repo_slug" \
		--body "Stuck detection resolved: task $task_id completed successfully. Removing \`${STUCK_DETECTION_LABEL}\` label." \
		2>/dev/null || true

	log_info "stuck-detection: removed label from issue #$issue_number for $task_id (task succeeded)"
	return 0
}

#######################################
# Run stuck detection checks for all running tasks (t1332)
# Called from pulse.sh Phase 0.75.
# Iterates running/dispatched tasks, checks if any have reached
# an unchecked milestone, and evaluates them via AI.
#
# ADVISORY ONLY — never modifies task state.
#
# Returns: number of stuck tasks detected (for logging)
#######################################
cmd_stuck_detection() {
	# Ensure schema exists
	_create_stuck_detection_schema

	local stuck_count=0
	local checked_count=0

	# Query running/dispatched tasks with their start times
	local active_tasks
	active_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, started_at, status FROM tasks
		WHERE status IN ('running', 'dispatched')
		AND started_at IS NOT NULL
		ORDER BY started_at ASC;
	" 2>/dev/null || echo "")

	if [[ -z "$active_tasks" ]]; then
		log_verbose "stuck-detection: no active tasks to check"
		return 0
	fi

	local now_epoch
	now_epoch=$(date +%s 2>/dev/null || echo 0)

	while IFS='|' read -r task_id started_at task_status; do
		[[ -z "$task_id" || -z "$started_at" ]] && continue

		# Calculate elapsed minutes
		local started_epoch elapsed_secs elapsed_min
		started_epoch=$(_iso_to_epoch "$started_at")
		if [[ "$started_epoch" -eq 0 ]]; then
			continue
		fi
		elapsed_secs=$((now_epoch - started_epoch))
		elapsed_min=$((elapsed_secs / 60))

		# Check if any milestone is due
		local next_milestone
		next_milestone=$(_get_next_milestone "$task_id" "$elapsed_min")
		if [[ -z "$next_milestone" ]]; then
			continue
		fi

		log_info "stuck-detection: checking $task_id at ${next_milestone}min milestone (elapsed: ${elapsed_min}min)"

		# Evaluate via AI
		local verdict
		verdict=$(_evaluate_stuck_with_ai "$task_id" "$elapsed_min" "$next_milestone")

		# Parse verdict
		local is_stuck confidence reasoning suggested_actions
		is_stuck=$(printf '%s' "$verdict" | jq -r '.is_stuck // false' 2>/dev/null || echo "false")
		confidence=$(printf '%s' "$verdict" | jq -r '.confidence // 0.0' 2>/dev/null || echo "0.0")
		reasoning=$(printf '%s' "$verdict" | jq -r '.reasoning // ""' 2>/dev/null || echo "")
		suggested_actions=$(printf '%s' "$verdict" | jq -r '.suggested_actions // ""' 2>/dev/null || echo "")

		# Normalize is_stuck to integer
		local is_stuck_int=0
		if [[ "$is_stuck" == "true" ]]; then
			is_stuck_int=1
		fi

		# Record the check in the log
		local issue_labeled=0

		# Check confidence threshold for stuck detection
		if [[ "$is_stuck_int" -eq 1 ]]; then
			# Compare confidence against threshold using awk (float comparison)
			local above_threshold
			above_threshold=$(awk "BEGIN { print ($confidence >= $STUCK_DETECTION_CONFIDENCE_THRESHOLD) ? 1 : 0 }" 2>/dev/null || echo "0")

			if [[ "$above_threshold" -eq 1 ]]; then
				log_warn "stuck-detection: $task_id appears STUCK (confidence: $confidence, milestone: ${next_milestone}min)"
				log_warn "  Reasoning: $reasoning"
				log_warn "  Suggested: $suggested_actions"

				# Label GitHub issue (advisory only)
				if _label_stuck_on_github "$task_id" "$confidence" "$reasoning" "$suggested_actions" "$next_milestone" "$elapsed_min"; then
					issue_labeled=1
				fi

				stuck_count=$((stuck_count + 1))
			else
				log_info "stuck-detection: $task_id flagged stuck but below threshold (confidence: $confidence < $STUCK_DETECTION_CONFIDENCE_THRESHOLD)"
				is_stuck_int=0
			fi
		else
			log_info "stuck-detection: $task_id appears healthy at ${next_milestone}min milestone (confidence: $confidence)"
		fi

		# Record to DB
		db "$SUPERVISOR_DB" "
			INSERT INTO ${STUCK_DETECTION_TABLE}
				(task_id, milestone_min, elapsed_min, confidence, is_stuck, reasoning, suggested_actions, issue_labeled)
			VALUES (
				'$(sql_escape "$task_id")', $next_milestone, $elapsed_min,
				$confidence, $is_stuck_int,
				'$(sql_escape "$reasoning")', '$(sql_escape "$suggested_actions")',
				$issue_labeled
			);
		" 2>/dev/null || true

		checked_count=$((checked_count + 1))
	done <<<"$active_tasks"

	if [[ "$checked_count" -gt 0 ]]; then
		log_info "stuck-detection: checked $checked_count task(s), $stuck_count stuck"
	fi

	echo "$stuck_count"
	return 0
}

#######################################
# Stuck detection report — observability into stuck detection patterns (t1332)
# Shows frequency, confidence distribution, and task patterns.
# Args:
#   --days <N>    Look back N days (default: 7)
#   --json        Output as JSON
#######################################
cmd_stuck_detection_report() {
	_create_stuck_detection_schema

	local days=7
	local json_output=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--days)
			days="$2"
			shift 2
			;;
		--json)
			json_output=true
			shift
			;;
		*) shift ;;
		esac
	done

	local total_checks
	total_checks=$(db "$SUPERVISOR_DB" "
		SELECT count(*) FROM ${STUCK_DETECTION_TABLE}
		WHERE created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days');
	" 2>/dev/null || echo "0")

	local stuck_checks
	stuck_checks=$(db "$SUPERVISOR_DB" "
		SELECT count(*) FROM ${STUCK_DETECTION_TABLE}
		WHERE is_stuck = 1
		AND created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days');
	" 2>/dev/null || echo "0")

	if [[ "$json_output" == "true" ]]; then
		local json_result
		json_result=$(db -json "$SUPERVISOR_DB" "
			SELECT
				task_id,
				milestone_min,
				elapsed_min,
				confidence,
				is_stuck,
				reasoning,
				suggested_actions,
				issue_labeled,
				created_at
			FROM ${STUCK_DETECTION_TABLE}
			WHERE created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days')
			ORDER BY created_at DESC;
		" 2>/dev/null || echo "[]")
		echo "$json_result"
		return 0
	fi

	echo "=== Stuck Detection Report (last ${days} days) ==="
	echo ""
	echo "Total checks: $total_checks"
	echo "Stuck detected: $stuck_checks"
	echo ""

	if [[ "$total_checks" -eq 0 ]]; then
		echo "No stuck detection checks in the last ${days} days."
		return 0
	fi

	echo "--- By Milestone ---"
	db -column -header "$SUPERVISOR_DB" "
		SELECT
			milestone_min AS 'Milestone (min)',
			count(*) AS Checks,
			sum(is_stuck) AS 'Stuck',
			printf('%.2f', avg(confidence)) AS 'Avg Confidence'
		FROM ${STUCK_DETECTION_TABLE}
		WHERE created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days')
		GROUP BY milestone_min
		ORDER BY milestone_min ASC;
	" 2>/dev/null || echo "(no data)"
	echo ""

	echo "--- Stuck Tasks ---"
	db -column -header "$SUPERVISOR_DB" "
		SELECT
			task_id AS Task,
			milestone_min AS 'Milestone',
			confidence AS Confidence,
			reasoning AS Reasoning,
			created_at AS 'Detected At'
		FROM ${STUCK_DETECTION_TABLE}
		WHERE is_stuck = 1
		AND created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days')
		ORDER BY created_at DESC
		LIMIT 20;
	" 2>/dev/null || echo "(none)"
	echo ""

	echo "--- Repeat Offenders ---"
	db -column -header "$SUPERVISOR_DB" "
		SELECT
			task_id AS Task,
			count(*) AS 'Times Stuck',
			group_concat(DISTINCT milestone_min) AS Milestones,
			printf('%.2f', avg(confidence)) AS 'Avg Confidence'
		FROM ${STUCK_DETECTION_TABLE}
		WHERE is_stuck = 1
		AND created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days')
		GROUP BY task_id
		HAVING count(*) >= 2
		ORDER BY count(*) DESC
		LIMIT 10;
	" 2>/dev/null || echo "(none)"

	return 0
}
