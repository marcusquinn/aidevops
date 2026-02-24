#!/usr/bin/env bash
# ai-pickup-decisions.sh - AI judgment for auto-pickup task selection (t1319)
#
# Migrates the decision logic from cmd_auto_pickup() (~475 lines of dispatch
# gating, blocked-by chain checking, and task selection) to AI judgment.
#
# Architecture: GATHER (shell) → JUDGE (AI) → RETURN (shell)
# - Shell gathers candidate tasks from TODO.md (grep patterns)
# - Shell gathers DB state (tracked tasks, statuses)
# - Shell gathers blocker/dependency data
# - AI receives structured context and decides which tasks to pick up
# - Shell parses AI response and executes the pickup actions
# - Falls back to deterministic logic if AI is unavailable
#
# What stays in shell:
# - TODO.md parsing (grep for candidates)
# - DB queries (task status, cross-repo checks)
# - is_task_blocked() / _check_and_skip_if_blocked() (data queries)
# - _is_cross_repo_misregistration() (data query)
# - cmd_add / cmd_batch execution (side effects)
# - dispatch_decomposition_worker() (execution)
# - Scheduler install/uninstall (cmd_cron, cmd_watch)
#
# What moves to AI:
# - Dispatch gating decisions (should this task be picked up?)
# - Priority/ordering among eligible tasks
# - Blocker tag interpretation (which -needed tags block?)
# - Subtask inheritance decisions
# - Batch grouping strategy
#
# Sourced by: supervisor-helper.sh (after cron.sh and dispatch.sh)
# Depends on: cron.sh (is_task_blocked, _is_cross_repo_misregistration,
#             dispatch_decomposition_worker)
#             dispatch.sh (resolve_ai_cli, resolve_model)
#             _common.sh (portable_timeout, log_*)
#             state.sh (check_task_already_done)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SUPERVISOR_DIR, SCRIPT_DIR
#   db(), log_info(), log_warn(), log_error(), log_success(), sql_escape()
#   resolve_ai_cli(), resolve_model(), portable_timeout()
#   is_task_blocked(), _is_cross_repo_misregistration()
#   check_task_already_done(), cmd_add(), cmd_batch(), get_cpu_cores()
#   dispatch_decomposition_worker(), ensure_db()

# Feature flag: enable/disable AI pickup decisions (default: enabled)
# Set to "false" to use deterministic logic exclusively (original cmd_auto_pickup).
AI_PICKUP_DECISIONS_ENABLED="${AI_PICKUP_DECISIONS_ENABLED:-true}"

# Model tier for pickup decisions — sonnet is sufficient for structured
# classification. The context is small (task lines + DB state).
AI_PICKUP_DECISIONS_MODEL="${AI_PICKUP_DECISIONS_MODEL:-sonnet}"

# Timeout for AI judgment calls (seconds)
AI_PICKUP_DECISIONS_TIMEOUT="${AI_PICKUP_DECISIONS_TIMEOUT:-45}"

# Log directory for decision audit trail
AI_PICKUP_DECISIONS_LOG_DIR="${AI_PICKUP_DECISIONS_LOG_DIR:-$HOME/.aidevops/logs/ai-pickup-decisions}"

# Portable timeout alias — uses portable_timeout from _common.sh when sourced,
# or defines a local fallback for standalone execution.
if ! declare -f portable_timeout &>/dev/null; then
	portable_timeout() {
		local secs="$1"
		shift
		if command -v timeout &>/dev/null; then
			timeout "$secs" "$@"
			return $?
		fi
		"$@" &
		local cmd_pid=$!
		(
			sleep "$secs"
			kill "$cmd_pid" 2>/dev/null
		) &
		local watchdog_pid=$!
		wait "$cmd_pid" 2>/dev/null
		local exit_code=$?
		kill "$watchdog_pid" 2>/dev/null
		wait "$watchdog_pid" 2>/dev/null
		if [[ $exit_code -eq 137 || $exit_code -eq 143 ]]; then
			return 124
		fi
		return "$exit_code"
	}
fi

#######################################
# Internal: Call AI CLI with a prompt and return the raw response.
# Handles both opencode and claude CLIs, strips ANSI codes.
#
# Args:
#   $1 - prompt text
#   $2 - title suffix for session naming
# Outputs:
#   Raw AI response on stdout (ANSI-stripped)
# Returns:
#   0 on success, 1 on failure
#######################################
_ai_pickup_call() {
	local prompt="$1"
	local title_suffix="$2"

	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_warn "ai-pickup-decisions: no AI CLI available"
		return 1
	}

	local ai_model
	ai_model=$(resolve_model "$AI_PICKUP_DECISIONS_MODEL" "$ai_cli" 2>/dev/null) || {
		log_warn "ai-pickup-decisions: model $AI_PICKUP_DECISIONS_MODEL unavailable"
		return 1
	}

	local ai_result=""
	local timeout_secs="$AI_PICKUP_DECISIONS_TIMEOUT"

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout "$timeout_secs" opencode run \
			-m "$ai_model" \
			--format default \
			--title "pickup-${title_suffix}-$$" \
			"$prompt" 2>/dev/null || echo "")
		# Strip ANSI escape codes
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		local claude_model="${ai_model#*/}"
		ai_result=$(portable_timeout "$timeout_secs" claude \
			-p "$prompt" \
			--model "$claude_model" \
			--output-format text 2>/dev/null || echo "")
	fi

	if [[ -z "$ai_result" ]]; then
		return 1
	fi

	printf '%s' "$ai_result"
	return 0
}

#######################################
# Internal: Extract JSON array from AI response.
# Handles markdown fencing, preamble text, etc.
#
# Args:
#   $1 - raw AI response
# Outputs:
#   JSON array on stdout, or empty string
# Returns:
#   0 if JSON array found, 1 if not
#######################################
_ai_pickup_extract_json() {
	local response="$1"

	# Try 1: Direct parse as array
	local parsed
	if parsed=$(printf '%s' "$response" | jq '.' 2>/dev/null) && [[ -n "$parsed" ]]; then
		local jtype
		jtype=$(printf '%s' "$parsed" | jq 'type' 2>/dev/null || echo "")
		if [[ "$jtype" == '"array"' ]]; then
			printf '%s' "$parsed"
			return 0
		fi
	fi

	# Try 2: Extract from ```json block
	local json_block
	json_block=$(printf '%s' "$response" | awk '
		/^```json/ { capture=1; block=""; next }
		/^```$/ && capture { capture=0; last_block=block; next }
		capture { block = block (block ? "\n" : "") $0 }
		END { if (capture && block) print block; else if (last_block) print last_block }
	')
	if [[ -n "$json_block" ]]; then
		if parsed=$(printf '%s' "$json_block" | jq '.' 2>/dev/null) && [[ -n "$parsed" ]]; then
			local jtype2
			jtype2=$(printf '%s' "$parsed" | jq 'type' 2>/dev/null || echo "")
			if [[ "$jtype2" == '"array"' ]]; then
				printf '%s' "$parsed"
				return 0
			fi
		fi
	fi

	# Try 3: Grep for JSON array (first [ to last ])
	local arr_match
	arr_match=$(printf '%s' "$response" | awk '
		/^\s*\[/ { capture=1; block="" }
		capture { block = block (block ? "\n" : "") $0 }
		/^\s*\]/ && capture { capture=0; last_block=block }
		END { if (last_block) print last_block }
	')
	if [[ -n "$arr_match" ]]; then
		if parsed=$(printf '%s' "$arr_match" | jq '.' 2>/dev/null) && [[ -n "$parsed" ]]; then
			printf '%s' "$parsed"
			return 0
		fi
	fi

	return 1
}

#######################################
# Internal: Log an AI pickup decision for audit trail.
#
# Args:
#   $1 - decision summary
#   $2 - (optional) full context for the log file
#######################################
_ai_pickup_log_decision() {
	local decision="$1"
	local context="${2:-}"

	mkdir -p "$AI_PICKUP_DECISIONS_LOG_DIR" 2>/dev/null || true

	local timestamp
	timestamp=$(date -u '+%Y%m%d-%H%M%S')
	local log_file="$AI_PICKUP_DECISIONS_LOG_DIR/pickup-${timestamp}.md"

	{
		echo "# AI Pickup Decision @ $timestamp"
		echo ""
		echo "Decision: $decision"
		echo ""
		if [[ -n "$context" ]]; then
			echo "## Context"
			echo ""
			echo "$context"
		fi
	} >"$log_file" 2>/dev/null || true

	return 0
}

###############################################################################
# GATHER PHASE: Collect all candidate tasks and their context
#
# Scans TODO.md using the same patterns as the original cmd_auto_pickup
# but instead of making inline decisions, builds a structured context
# document for the AI to reason about.
###############################################################################

#######################################
# Gather candidate tasks from TODO.md for AI evaluation.
# Collects tasks from all 4 original strategies plus DB state.
#
# Args:
#   $1 - repo path
#   $2 - todo_file path
# Outputs:
#   JSON document on stdout with all candidate data
# Returns:
#   0 on success, 1 on error
#######################################
_gather_pickup_candidates() {
	local repo="$1"
	local todo_file="$2"

	ensure_db

	local candidates_json="[]"

	# Strategy 1: Tasks tagged #auto-dispatch
	local tagged_tasks
	tagged_tasks=$(grep -E '^[[:space:]]*- \[ \] (t[0-9]+(\.[0-9]+)*) .*#auto-dispatch' "$todo_file" 2>/dev/null || true)

	if [[ -n "$tagged_tasks" ]]; then
		while IFS= read -r line; do
			local task_id
			task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
			[[ -z "$task_id" ]] && continue

			local candidate_json
			candidate_json=$(_build_candidate_json "$task_id" "$line" "$repo" "$todo_file" "tagged_auto_dispatch")
			if [[ -n "$candidate_json" ]]; then
				candidates_json=$(printf '%s' "$candidates_json" | jq --argjson c "$candidate_json" '. + [$c]')
			fi
		done <<<"$tagged_tasks"
	fi

	# Strategy 2: Tasks in "Dispatch Queue" section
	local in_dispatch_section=false
	local section_tasks=""

	while IFS= read -r line; do
		if echo "$line" | grep -qE '^#{1,3} '; then
			if echo "$line" | grep -qi 'dispatch.queue'; then
				in_dispatch_section=true
				continue
			else
				in_dispatch_section=false
				continue
			fi
		fi
		if [[ "$in_dispatch_section" == "true" ]] && echo "$line" | grep -qE '^[[:space:]]*- \[ \] t[0-9]+'; then
			section_tasks+="$line"$'\n'
		fi
	done <"$todo_file"

	if [[ -n "$section_tasks" ]]; then
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			local task_id
			task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
			[[ -z "$task_id" ]] && continue

			# Skip if already added by Strategy 1
			local already_added
			already_added=$(printf '%s' "$candidates_json" | jq --arg id "$task_id" '[.[] | select(.task_id == $id)] | length' 2>/dev/null || echo "0")
			if [[ "$already_added" -gt 0 ]]; then
				continue
			fi

			local candidate_json
			candidate_json=$(_build_candidate_json "$task_id" "$line" "$repo" "$todo_file" "dispatch_queue_section")
			if [[ -n "$candidate_json" ]]; then
				candidates_json=$(printf '%s' "$candidates_json" | jq --argjson c "$candidate_json" '. + [$c]')
			fi
		done <<<"$section_tasks"
	fi

	# Strategy 3: #plan tasks with PLANS.md references but no subtasks
	local plan_tasks
	plan_tasks=$(grep -E '^[[:space:]]*- \[ \] (t[0-9]+) .*#plan.*→ \[todo/PLANS\.md#' "$todo_file" 2>/dev/null || true)

	if [[ -n "$plan_tasks" ]]; then
		while IFS= read -r line; do
			local task_id
			task_id=$(echo "$line" | grep -oE 't[0-9]+' | head -1)
			[[ -z "$task_id" ]] && continue

			# Check if task already has subtasks
			local has_subtasks
			has_subtasks=$(grep -E "^[[:space:]]+-[[:space:]]\[[ xX-]\][[:space:]]${task_id}\.[0-9]+" "$todo_file" 2>/dev/null || true)
			if [[ -n "$has_subtasks" ]]; then
				continue
			fi

			# Extract PLANS.md anchor
			local plan_anchor
			plan_anchor=$(echo "$line" | grep -oE 'todo/PLANS\.md#[^]]+' | sed 's/todo\/PLANS\.md#//' || true)

			local candidate_json
			candidate_json=$(_build_candidate_json "$task_id" "$line" "$repo" "$todo_file" "plan_decomposition")
			if [[ -n "$candidate_json" ]]; then
				# Add plan_anchor to the candidate
				candidate_json=$(printf '%s' "$candidate_json" | jq --arg anchor "${plan_anchor:-}" '. + {plan_anchor: $anchor}')
				candidates_json=$(printf '%s' "$candidates_json" | jq --argjson c "$candidate_json" '. + [$c]')
			fi
		done <<<"$plan_tasks"
	fi

	# Strategy 4: Subtask inheritance from #auto-dispatch parents
	local parent_ids
	parent_ids=$(grep -E '^[[:space:]]*- \[ \] (t[0-9]+) .*#auto-dispatch' "$todo_file" 2>/dev/null |
		grep -oE 't[0-9]+' | sort -u || true)

	if [[ -n "$parent_ids" ]]; then
		while IFS= read -r parent_id; do
			[[ -z "$parent_id" ]] && continue

			# Extract parent's model tier
			local parent_line
			parent_line=$(grep -E "^[[:space:]]*- \[[ xX-]\] ${parent_id} " "$todo_file" 2>/dev/null | head -1 || true)
			local parent_model=""
			if [[ -n "$parent_line" ]]; then
				parent_model=$(echo "$parent_line" | grep -oE 'model:[a-zA-Z0-9/_.-]+' | head -1 | sed 's/^model://' || true)
			fi

			# Find open subtasks of this parent
			local subtasks
			subtasks=$(grep -E "^[[:space:]]*- \[ \] ${parent_id}\.[0-9]+" "$todo_file" 2>/dev/null || true)
			[[ -z "$subtasks" ]] && continue

			while IFS= read -r sub_line; do
				[[ -z "$sub_line" ]] && continue
				local sub_id
				sub_id=$(echo "$sub_line" | grep -oE 't[0-9]+(\.[0-9]+)+' | head -1)
				[[ -z "$sub_id" ]] && continue

				# Skip if already has own #auto-dispatch tag (handled by Strategy 1)
				if echo "$sub_line" | grep -qE '#auto-dispatch'; then
					continue
				fi

				# Skip if already added
				local already_added
				already_added=$(printf '%s' "$candidates_json" | jq --arg id "$sub_id" '[.[] | select(.task_id == $id)] | length' 2>/dev/null || echo "0")
				if [[ "$already_added" -gt 0 ]]; then
					continue
				fi

				local candidate_json
				candidate_json=$(_build_candidate_json "$sub_id" "$sub_line" "$repo" "$todo_file" "subtask_inheritance")
				if [[ -n "$candidate_json" ]]; then
					# Add parent context
					candidate_json=$(printf '%s' "$candidate_json" | jq \
						--arg pid "$parent_id" \
						--arg pmodel "${parent_model:-}" \
						'. + {parent_id: $pid, parent_model: $pmodel}')
					candidates_json=$(printf '%s' "$candidates_json" | jq --argjson c "$candidate_json" '. + [$c]')
				fi
			done <<<"$subtasks"
		done <<<"$parent_ids"
	fi

	printf '%s' "$candidates_json"
	return 0
}

#######################################
# Build a JSON object for a single candidate task.
# Gathers all the data the AI needs to make a decision.
#
# Args:
#   $1 - task_id
#   $2 - task line from TODO.md
#   $3 - repo path
#   $4 - todo_file path
#   $5 - source strategy name
# Outputs:
#   JSON object on stdout, or empty string if task should be pre-filtered
# Returns:
#   0 always
#######################################
_build_candidate_json() {
	local task_id="$1"
	local line="$2"
	local repo="$3"
	local todo_file="$4"
	local source="$5"

	# Pre-filter: cross-repo misregistration (data check, not a decision)
	if _is_cross_repo_misregistration "$task_id" "$repo"; then
		return 0
	fi

	# Gather DB state
	local db_status=""
	db_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || true)

	# Gather blocker info
	local blocked_by=""
	blocked_by=$(printf '%s' "$line" | grep -oE 'blocked-by:[^ ]+' | sed 's/blocked-by://' || true)

	local unresolved_blockers=""
	if [[ -n "$blocked_by" ]]; then
		unresolved_blockers=$(is_task_blocked "$line" "$todo_file" 2>/dev/null || true)
	fi

	# Check for -needed blocker tags
	local needed_tags=""
	needed_tags=$(echo "$line" | grep -oE '(account|hosting|login|api-key|clarification|resources|payment|approval|decision|design|content|dns|domain|testing)-needed' || true)

	# Check for assignee/started metadata
	local has_assignee="false"
	if echo "$line" | grep -qE '(assignee:[a-zA-Z0-9_-]+|started:[0-9]{4}-[0-9]{2}-[0-9]{2}T)'; then
		has_assignee="true"
	fi

	# Check for merged PR
	local has_merged_pr="false"
	if check_task_already_done "$task_id" "$repo" 2>/dev/null; then
		has_merged_pr="true"
	fi

	# Extract model tier
	local model_tier=""
	model_tier=$(echo "$line" | grep -oE 'model:[a-zA-Z0-9/_.-]+' | head -1 | sed 's/^model://' || true)

	# Extract estimate
	local estimate=""
	estimate=$(echo "$line" | grep -oE '~[0-9]+[hm]' | head -1 || true)

	# Extract tags
	local tags=""
	tags=$(echo "$line" | grep -oE '#[a-zA-Z0-9_-]+' | tr '\n' ',' | sed 's/,$//' || true)

	# Extract ref
	local ref=""
	ref=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 || true)

	# Build JSON
	local json
	json=$(jq -n \
		--arg id "$task_id" \
		--arg line "$line" \
		--arg source "$source" \
		--arg db_status "${db_status:-none}" \
		--arg blocked_by "${blocked_by:-}" \
		--arg unresolved_blockers "${unresolved_blockers:-}" \
		--arg needed_tags "${needed_tags:-}" \
		--argjson has_assignee "$has_assignee" \
		--argjson has_merged_pr "$has_merged_pr" \
		--arg model_tier "${model_tier:-}" \
		--arg estimate "${estimate:-}" \
		--arg tags "${tags:-}" \
		--arg ref "${ref:-}" \
		'{
			task_id: $id,
			line: $line,
			source: $source,
			db_status: $db_status,
			blocked_by: $blocked_by,
			unresolved_blockers: $unresolved_blockers,
			needed_tags: $needed_tags,
			has_assignee: $has_assignee,
			has_merged_pr: $has_merged_pr,
			model_tier: $model_tier,
			estimate: $estimate,
			tags: $tags,
			ref: $ref
		}')

	printf '%s' "$json"
	return 0
}

###############################################################################
# JUDGE PHASE: AI evaluates candidates and returns decisions
###############################################################################

#######################################
# Build the AI prompt for pickup decisions.
#
# Args:
#   $1 - candidates JSON array
#   $2 - repo path
# Outputs:
#   Prompt text on stdout
# Returns:
#   0 always
#######################################
_build_pickup_prompt() {
	local candidates="$1"
	local repo="$2"

	local candidate_count
	candidate_count=$(printf '%s' "$candidates" | jq 'length' 2>/dev/null || echo "0")

	local repo_name
	repo_name=$(basename "$repo")

	cat <<PROMPT
You are an AI Engineering Manager making task dispatch decisions for the "$repo_name" project.

## Your Role
Decide which candidate tasks should be picked up for autonomous dispatch.
You receive structured data about each candidate and return a JSON decision array.

## Decision Rules

### MUST SKIP (hard gates — these are non-negotiable):
1. **has_assignee=true**: Task already claimed by someone — never steal work
2. **has_merged_pr=true**: Task already completed — no duplicate work
3. **db_status in (complete, cancelled, verified)**: Terminal state — skip silently
4. **db_status is not "none"**: Already tracked in supervisor — skip with info log
5. **unresolved_blockers is non-empty**: Blocked by incomplete dependencies
6. **needed_tags is non-empty**: Requires human action (e.g., account-needed, approval-needed)

### SHOULD PICK UP (if none of the above apply):
- Tasks from "tagged_auto_dispatch" source: explicitly tagged for dispatch
- Tasks from "dispatch_queue_section" source: in the dispatch queue
- Tasks from "subtask_inheritance" source: parent has #auto-dispatch
- Tasks from "plan_decomposition" source: needs decomposition worker

### ADDITIONAL JUDGMENT (use your reasoning):
- If multiple tasks are eligible, consider dependency ordering (blocked-by chains)
- For subtask_inheritance: if parent_model is set and task has no model_tier, recommend inheriting
- For plan_decomposition: always recommend pickup + decomposition
- Consider task estimates when many tasks are eligible — prefer smaller tasks first for faster throughput

## Input Data
$candidate_count candidate task(s):

$candidates

## Output Format
Respond with ONLY a JSON array. No markdown fencing, no explanation, no preamble.
Each element must have exactly these fields:

[
  {
    "task_id": "t123",
    "decision": "pickup" | "skip" | "decompose",
    "reason": "brief explanation",
    "inherit_model": "opus" | "" (only for subtask_inheritance with parent_model)
  }
]

If no candidates should be picked up, respond with: []

Decision values:
- "pickup": Add to supervisor and queue for dispatch
- "skip": Do not pick up (with reason for logging)
- "decompose": Add to supervisor AND dispatch decomposition worker

Respond with ONLY the JSON array now.
PROMPT
	return 0
}

#######################################
# Ask AI to evaluate pickup candidates and return decisions.
#
# Args:
#   $1 - candidates JSON array
#   $2 - repo path
# Outputs:
#   JSON array of decisions on stdout
# Returns:
#   0 on success, 1 on AI failure (caller should use fallback)
#######################################
_ai_evaluate_candidates() {
	local candidates="$1"
	local repo="$2"

	local candidate_count
	candidate_count=$(printf '%s' "$candidates" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$candidate_count" -eq 0 ]]; then
		echo "[]"
		return 0
	fi

	local prompt
	prompt=$(_build_pickup_prompt "$candidates" "$repo")

	local timestamp
	timestamp=$(date -u '+%Y%m%d-%H%M%S')

	log_info "AI Pickup: evaluating $candidate_count candidate(s)..."

	local ai_response
	ai_response=$(_ai_pickup_call "$prompt" "eval-${timestamp}") || {
		log_warn "AI Pickup: AI call failed — falling back to deterministic logic"
		return 1
	}

	# Parse JSON array from response
	local decisions
	decisions=$(_ai_pickup_extract_json "$ai_response") || {
		log_warn "AI Pickup: failed to parse AI response — falling back to deterministic logic"
		_ai_pickup_log_decision "PARSE_FAILED" "Raw response: $ai_response"
		return 1
	}

	# Validate structure: each element must have task_id and decision
	local valid_count
	valid_count=$(printf '%s' "$decisions" | jq '[.[] | select(.task_id and .decision)] | length' 2>/dev/null || echo "0")
	local total_count
	total_count=$(printf '%s' "$decisions" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$valid_count" -ne "$total_count" ]]; then
		log_warn "AI Pickup: $((total_count - valid_count)) of $total_count decisions have invalid structure"
		# Filter to only valid ones
		decisions=$(printf '%s' "$decisions" | jq '[.[] | select(.task_id and .decision)]')
	fi

	# Log the decision
	_ai_pickup_log_decision "AI decided on $valid_count tasks" "Candidates: $candidates

Decisions: $decisions"

	log_info "AI Pickup: $valid_count decision(s) returned"
	printf '%s' "$decisions"
	return 0
}

###############################################################################
# EXECUTE PHASE: Apply AI decisions
###############################################################################

#######################################
# Execute AI pickup decisions — add tasks to supervisor, dispatch decomposition.
#
# Args:
#   $1 - decisions JSON array
#   $2 - candidates JSON array (for cross-reference)
#   $3 - repo path
#   $4 - todo_file path
# Outputs:
#   Number of tasks picked up on stdout
# Returns:
#   0 always
#######################################
_execute_pickup_decisions() {
	local decisions="$1"
	local candidates="$2"
	local repo="$3"
	local todo_file="$4"

	local picked_up=0
	local decision_count
	decision_count=$(printf '%s' "$decisions" | jq 'length' 2>/dev/null || echo "0")

	local i=0
	while [[ "$i" -lt "$decision_count" ]]; do
		local task_id decision reason inherit_model
		task_id=$(printf '%s' "$decisions" | jq -r ".[$i].task_id" 2>/dev/null || echo "")
		decision=$(printf '%s' "$decisions" | jq -r ".[$i].decision" 2>/dev/null || echo "")
		reason=$(printf '%s' "$decisions" | jq -r ".[$i].reason // \"\"" 2>/dev/null || echo "")
		inherit_model=$(printf '%s' "$decisions" | jq -r ".[$i].inherit_model // \"\"" 2>/dev/null || echo "")

		i=$((i + 1))

		[[ -z "$task_id" || -z "$decision" ]] && continue

		case "$decision" in
		pickup)
			local model_arg=""
			if [[ -n "$inherit_model" && "$inherit_model" != "null" ]]; then
				model_arg="--model $inherit_model"
				log_info "  $task_id: inheriting model:$inherit_model from parent"
			fi

			# shellcheck disable=SC2086
			if cmd_add "$task_id" --repo "$repo" $model_arg; then
				picked_up=$((picked_up + 1))
				log_success "  Auto-picked: $task_id ($reason)"
			fi
			;;
		decompose)
			# Look up plan_anchor from candidates
			local plan_anchor
			plan_anchor=$(printf '%s' "$candidates" | jq -r \
				--arg id "$task_id" \
				'[.[] | select(.task_id == $id)] | .[0].plan_anchor // ""' 2>/dev/null || echo "")

			if cmd_add "$task_id" --repo "$repo"; then
				picked_up=$((picked_up + 1))
				log_success "  Auto-picked: $task_id (#plan task for decomposition)"

				if [[ -n "$plan_anchor" ]]; then
					log_info "  Dispatching decomposition worker for $task_id..."
					dispatch_decomposition_worker "$task_id" "$plan_anchor" "$repo"
				else
					log_warn "  $task_id: decompose decision but no plan_anchor found"
				fi
			fi
			;;
		skip)
			if [[ -n "$reason" && "$reason" != "null" ]]; then
				log_info "  $task_id: skipped — $reason"
			fi
			;;
		*)
			log_warn "  $task_id: unknown decision '$decision' — skipping"
			;;
		esac
	done

	echo "$picked_up"
	return 0
}

###############################################################################
# AUTO-BATCH PHASE: Group picked-up tasks into batches
# (Extracted from original cmd_auto_pickup — pure shell, no AI needed)
###############################################################################

#######################################
# Auto-batch unbatched queued tasks after pickup.
# Creates or extends batches with resource-aware concurrency.
#
# Args:
#   $1 - number of tasks picked up
# Returns:
#   0 always
#######################################
_auto_batch_picked_tasks() {
	local picked_up="$1"

	if [[ "$picked_up" -eq 0 ]]; then
		return 0
	fi

	# Find unbatched queued tasks
	local unbatched_queued
	unbatched_queued=$(db "$SUPERVISOR_DB" "
		SELECT t.id FROM tasks t
		WHERE t.status = 'queued'
		  AND t.id NOT IN (SELECT task_id FROM batch_tasks)
		ORDER BY t.created_at;
	" 2>/dev/null || true)

	if [[ -z "$unbatched_queued" ]]; then
		return 0
	fi

	# Check for an active batch
	local active_batch_id
	active_batch_id=$(db "$SUPERVISOR_DB" "
		SELECT b.id FROM batches b
		WHERE EXISTS (
			SELECT 1 FROM batch_tasks bt
			JOIN tasks t ON bt.task_id = t.id
			WHERE bt.batch_id = b.id
			  AND t.status NOT IN ('complete','deployed','verified','verify_failed','merged','cancelled','failed','blocked')
		)
		ORDER BY b.created_at DESC
		LIMIT 1;
	" 2>/dev/null || true)

	if [[ -n "$active_batch_id" ]]; then
		# Add to existing active batch
		local added_count=0
		local max_pos
		max_pos=$(db "$SUPERVISOR_DB" "
			SELECT COALESCE(MAX(position), -1) FROM batch_tasks
			WHERE batch_id = '$(sql_escape "$active_batch_id")';
		" 2>/dev/null || echo "-1")
		local pos=$((max_pos + 1))

		while IFS= read -r tid; do
			[[ -z "$tid" ]] && continue
			db "$SUPERVISOR_DB" "
				INSERT OR IGNORE INTO batch_tasks (batch_id, task_id, position)
				VALUES ('$(sql_escape "$active_batch_id")', '$(sql_escape "$tid")', $pos);
			"
			pos=$((pos + 1))
			added_count=$((added_count + 1))
		done <<<"$unbatched_queued"

		if [[ "$added_count" -gt 0 ]]; then
			log_success "Auto-batch: added $added_count tasks to active batch $active_batch_id"
		fi
	else
		# Create a new auto-batch with resource-aware concurrency
		local auto_batch_name
		auto_batch_name="auto-$(date +%Y%m%d-%H%M%S)"
		local task_csv
		task_csv=$(echo "$unbatched_queued" | tr '\n' ',' | sed 's/,$//')
		local auto_cores
		auto_cores="$(get_cpu_cores)"
		local auto_base_concurrency=$((auto_cores / 2))
		if [[ "$auto_base_concurrency" -lt 2 ]]; then
			auto_base_concurrency=2
		fi
		local auto_batch_id
		auto_batch_id=$(cmd_batch "$auto_batch_name" --concurrency "$auto_base_concurrency" --tasks "$task_csv" 2>/dev/null)
		if [[ -n "$auto_batch_id" ]]; then
			log_success "Auto-batch: created '$auto_batch_name' ($auto_batch_id) with $picked_up tasks"
		fi
	fi

	return 0
}

###############################################################################
# BATCH CLEANUP PHASE: Strategy 5 — group #chore tasks
# (Extracted from original cmd_auto_pickup — pure shell)
###############################################################################

#######################################
# Run batch-cleanup for simple #chore tasks (Strategy 5, t1146).
#
# Args:
#   $1 - repo path
# Returns:
#   0 always
#######################################
_run_batch_cleanup() {
	local repo="$1"

	local batch_cleanup_helper="${SCRIPT_DIR}/../batch-cleanup-helper.sh"
	if [[ ! -x "$batch_cleanup_helper" ]]; then
		return 0
	fi

	local chore_eligible
	chore_eligible=$("$batch_cleanup_helper" scan --repo "$repo" 2>>"$SUPERVISOR_LOG" | grep -E '^t[0-9]' || true)
	if [[ -z "$chore_eligible" ]]; then
		return 0
	fi

	local chore_count
	chore_count=$(echo "$chore_eligible" | grep -c '^t' || true)
	log_info "Strategy 5: found $chore_count #chore task(s) eligible for batch cleanup"
	if [[ "$chore_count" -ge 2 ]]; then
		log_info "  Triggering batch-cleanup dispatch for $chore_count tasks..."
		"$batch_cleanup_helper" dispatch --repo "$repo" 2>>"$SUPERVISOR_LOG" ||
			log_warn "  Batch-cleanup dispatch failed (non-fatal)"
	else
		log_info "  Only $chore_count task(s) — waiting for more to accumulate (min: 2)"
	fi

	return 0
}

###############################################################################
# DETERMINISTIC FALLBACK: Original inline decision logic
#
# Used when AI is disabled or unavailable. Preserves exact behavior of the
# original cmd_auto_pickup strategies 1-4.
###############################################################################

#######################################
# Deterministic fallback for a single candidate task.
# Replicates the original inline gating logic from cmd_auto_pickup.
#
# Args:
#   $1 - candidate JSON object
#   $2 - repo path
#   $3 - todo_file path
# Outputs:
#   "pickup", "decompose", or "skip" on stdout
# Returns:
#   0 always
#######################################
_deterministic_evaluate() {
	local candidate="$1"
	local repo="$2"
	local todo_file="$3"

	local task_id db_status has_assignee has_merged_pr unresolved_blockers needed_tags source
	task_id=$(printf '%s' "$candidate" | jq -r '.task_id')
	db_status=$(printf '%s' "$candidate" | jq -r '.db_status')
	has_assignee=$(printf '%s' "$candidate" | jq -r '.has_assignee')
	has_merged_pr=$(printf '%s' "$candidate" | jq -r '.has_merged_pr')
	unresolved_blockers=$(printf '%s' "$candidate" | jq -r '.unresolved_blockers')
	needed_tags=$(printf '%s' "$candidate" | jq -r '.needed_tags')
	source=$(printf '%s' "$candidate" | jq -r '.source')

	# Gate 1: Already claimed
	if [[ "$has_assignee" == "true" ]]; then
		log_info "  $task_id: already claimed or in progress — skipping auto-pickup"
		echo "skip"
		return 0
	fi

	# Gate 2: Blocked by dependencies
	if [[ -n "$unresolved_blockers" ]]; then
		log_info "  $task_id: blocked by unresolved dependencies ($unresolved_blockers) — skipping"
		echo "skip"
		return 0
	fi

	# Gate 3: Human action required
	if [[ -n "$needed_tags" ]]; then
		local blocker_tag
		blocker_tag=$(echo "$needed_tags" | head -1)
		log_info "  $task_id: blocked by $blocker_tag (human action required) — skipping auto-pickup"
		echo "skip"
		return 0
	fi

	# Gate 4: Already tracked in DB
	if [[ -n "$db_status" && "$db_status" != "none" ]]; then
		if [[ "$db_status" == "complete" || "$db_status" == "cancelled" || "$db_status" == "verified" ]]; then
			echo "skip"
			return 0
		fi
		log_info "  $task_id: already tracked (status: $db_status)"
		echo "skip"
		return 0
	fi

	# Gate 5: Already completed (merged PR)
	if [[ "$has_merged_pr" == "true" ]]; then
		log_info "  $task_id: already completed (merged PR) — skipping auto-pickup"
		echo "skip"
		return 0
	fi

	# Decision: plan decomposition
	if [[ "$source" == "plan_decomposition" ]]; then
		echo "decompose"
		return 0
	fi

	# Default: pick up
	echo "pickup"
	return 0
}

#######################################
# Run deterministic fallback for all candidates.
# Replicates original cmd_auto_pickup behavior exactly.
#
# Args:
#   $1 - candidates JSON array
#   $2 - repo path
#   $3 - todo_file path
# Outputs:
#   JSON array of decisions on stdout
# Returns:
#   0 always
#######################################
_deterministic_evaluate_all() {
	local candidates="$1"
	local repo="$2"
	local todo_file="$3"

	local decisions="[]"
	local candidate_count
	candidate_count=$(printf '%s' "$candidates" | jq 'length' 2>/dev/null || echo "0")

	local i=0
	while [[ "$i" -lt "$candidate_count" ]]; do
		local candidate
		candidate=$(printf '%s' "$candidates" | jq ".[$i]" 2>/dev/null)
		local task_id
		task_id=$(printf '%s' "$candidate" | jq -r '.task_id' 2>/dev/null || echo "")

		i=$((i + 1))
		[[ -z "$task_id" ]] && continue

		local decision
		decision=$(_deterministic_evaluate "$candidate" "$repo" "$todo_file")

		local parent_model=""
		parent_model=$(printf '%s' "$candidate" | jq -r '.parent_model // ""' 2>/dev/null || echo "")

		local inherit_model=""
		if [[ -n "$parent_model" && "$parent_model" != "null" ]]; then
			local task_model
			task_model=$(printf '%s' "$candidate" | jq -r '.model_tier // ""' 2>/dev/null || echo "")
			if [[ -z "$task_model" || "$task_model" == "null" ]]; then
				inherit_model="$parent_model"
			fi
		fi

		decisions=$(printf '%s' "$decisions" | jq \
			--arg id "$task_id" \
			--arg dec "$decision" \
			--arg reason "deterministic fallback" \
			--arg model "${inherit_model:-}" \
			'. + [{task_id: $id, decision: $dec, reason: $reason, inherit_model: $model}]')
	done

	printf '%s' "$decisions"
	return 0
}

###############################################################################
# PUBLIC API: AI-powered auto-pickup
###############################################################################

#######################################
# AI-powered auto-pickup: scan TODO.md and decide which tasks to dispatch.
# Replaces the decision logic in cmd_auto_pickup() with AI judgment.
# Falls back to deterministic logic if AI is unavailable.
#
# Args:
#   --repo <path>  Repository path (default: pwd)
# Returns:
#   0 on success, 1 on error
#######################################
ai_auto_pickup() {
	local repo=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			[[ $# -lt 2 ]] && {
				log_error "--repo requires a value"
				return 1
			}
			repo="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$repo" ]]; then
		repo="$(pwd)"
	fi

	local todo_file="$repo/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		log_warn "TODO.md not found at $todo_file"
		return 1
	fi

	ensure_db

	# Phase 1: GATHER — collect all candidate tasks
	log_info "AI Pickup: gathering candidates from $todo_file..."
	local candidates
	candidates=$(_gather_pickup_candidates "$repo" "$todo_file")

	local candidate_count
	candidate_count=$(printf '%s' "$candidates" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$candidate_count" -eq 0 ]]; then
		log_info "No new tasks to pick up"
		return 0
	fi

	log_info "AI Pickup: found $candidate_count candidate(s)"

	# Phase 2: JUDGE — AI evaluates candidates (or deterministic fallback)
	local decisions

	if [[ "$AI_PICKUP_DECISIONS_ENABLED" == "true" ]]; then
		decisions=$(_ai_evaluate_candidates "$candidates" "$repo") || {
			log_info "AI Pickup: falling back to deterministic evaluation"
			decisions=$(_deterministic_evaluate_all "$candidates" "$repo" "$todo_file")
		}
	else
		log_info "AI Pickup: AI disabled — using deterministic evaluation"
		decisions=$(_deterministic_evaluate_all "$candidates" "$repo" "$todo_file")
	fi

	# Phase 3: EXECUTE — apply decisions
	local picked_up
	picked_up=$(_execute_pickup_decisions "$decisions" "$candidates" "$repo" "$todo_file")

	# Phase 4: BATCH CLEANUP — Strategy 5 (pure shell, no AI)
	_run_batch_cleanup "$repo"

	# Phase 5: AUTO-BATCH — group picked-up tasks
	if [[ "$picked_up" -eq 0 ]]; then
		log_info "No new tasks to pick up"
	else
		log_success "Picked up $picked_up new tasks"
		_auto_batch_picked_tasks "$picked_up"
	fi

	return 0
}
