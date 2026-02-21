#!/usr/bin/env bash
# ai-reason.sh - AI Supervisor reasoning engine (t1085.2)
#
# Spawns an opus-tier AI session with project context from ai-context.sh,
# has it reason about project state, and outputs a structured action plan.
#
# Used by: pulse.sh Phase 13 (AI Supervisor Reasoning)
# Depends on: ai-context.sh (build_ai_context)
# Sourced by: supervisor-helper.sh (set -euo pipefail inherited)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SCRIPT_DIR, REPO_PATH
#   db(), log_info(), log_warn(), log_error(), sql_escape()
#   resolve_model(), resolve_ai_cli() (from dispatch.sh)
#   build_ai_context() (from ai-context.sh)

# AI reasoning log directory
AI_REASON_LOG_DIR="${AI_REASON_LOG_DIR:-$HOME/.aidevops/logs/ai-supervisor}"

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
# Check if there is actionable work worth reasoning about
# Avoids spawning an expensive opus session when nothing needs attention.
# Arguments:
#   $1 - repo path
# Returns:
#   0 if actionable work exists, 1 if nothing to reason about
#######################################
has_actionable_work() {
	local repo_path="${1:-$REPO_PATH}"
	local actionable=0

	# Resolve GitHub owner/repo from git remote (gh --repo needs owner/repo, not path)
	local gh_repo=""
	if command -v gh &>/dev/null; then
		gh_repo=$(git -C "$repo_path" remote get-url origin 2>/dev/null |
			sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#' | sed 's/\.git$//' || echo "")
	fi

	# 1. Open GitHub issues (excluding supervisor/logging noise)
	local open_issues=0
	if [[ -n "$gh_repo" ]]; then
		open_issues=$(gh issue list --repo "$gh_repo" --state open --limit 100 --json number,title \
			--jq '[.[] | select(.title | test("^\\[(Supervisor|Auditor|Auto-|Cron)"; "i") | not) | select(.title | test("Daily CodeRabbit"; "i") | not)] | length' 2>/dev/null || echo 0)
	fi
	if [[ "$open_issues" -gt 0 ]]; then
		actionable=$((actionable + open_issues))
		log_verbose "AI Reasoning: $open_issues actionable open issues"
	fi

	# 2. Open PRs needing attention (not yet approved or merged)
	local open_prs=0
	if [[ -n "$gh_repo" ]]; then
		open_prs=$(gh pr list --repo "$gh_repo" --state open --limit 50 --json number \
			--jq 'length' 2>/dev/null || echo 0)
	fi
	if [[ "$open_prs" -gt 0 ]]; then
		actionable=$((actionable + open_prs))
		log_verbose "AI Reasoning: $open_prs open PRs"
	fi

	# 3. Open tasks that are blocked (might be unblockable)
	local blocked_tasks=0
	if [[ -f "$repo_path/TODO.md" ]]; then
		blocked_tasks=$(grep -c '^\- \[ \].*blocked-by:' "$repo_path/TODO.md" 2>/dev/null | tail -1 || echo 0)
		blocked_tasks="${blocked_tasks//[^0-9]/}"
		blocked_tasks="${blocked_tasks:-0}"
	fi
	if [[ "$blocked_tasks" -gt 0 ]]; then
		actionable=$((actionable + blocked_tasks))
		log_verbose "AI Reasoning: $blocked_tasks blocked tasks"
	fi

	# 4. Recently failed workers (last 24h) — may need intervention
	local recent_failures=0
	if [[ -f "$SUPERVISOR_DB" ]]; then
		recent_failures=$(db "$SUPERVISOR_DB" "
			SELECT COUNT(*) FROM tasks
			WHERE status IN ('failed', 'error')
			  AND updated_at > datetime('now', '-24 hours');
		" 2>/dev/null || echo 0)
	fi
	if [[ "$recent_failures" -gt 0 ]]; then
		actionable=$((actionable + recent_failures))
		log_verbose "AI Reasoning: $recent_failures recent worker failures"
	fi

	if [[ "$actionable" -eq 0 ]]; then
		log_info "AI Reasoning: nothing actionable — skipping reasoning cycle"
		return 1
	fi

	log_verbose "AI Reasoning: $actionable actionable items found"
	return 0
}

#######################################
# Run the AI reasoning cycle
# Arguments:
#   $1 - repo path
#   $2 - (optional) mode: "full" (default), "dry-run", "read-only"
# Outputs:
#   JSON action plan to stdout (in full mode)
#   Reasoning log to AI_REASON_LOG_DIR
# Returns:
#   0 on success, 1 on failure, 2 on timeout
#######################################
run_ai_reasoning() {
	local repo_path="${1:-$REPO_PATH}"
	local mode="${2:-full}"

	# Ensure log directory exists
	mkdir -p "$AI_REASON_LOG_DIR"

	# Concurrency guard — prevent overlapping AI reasoning sessions
	local lock_file="$AI_REASON_LOG_DIR/.ai-reason.lock"
	if [[ -f "$lock_file" ]]; then
		local lock_pid lock_age
		lock_pid=$(head -1 "$lock_file" 2>/dev/null || echo 0)
		lock_age=$(($(date +%s) - $(stat -f %m "$lock_file" 2>/dev/null || stat -c %Y "$lock_file" 2>/dev/null || echo 0)))
		# If lock holder is still alive and lock is not stale (< 5 min), skip
		if kill -0 "$lock_pid" 2>/dev/null && [[ "$lock_age" -lt 300 ]]; then
			log_info "AI Reasoning: already running (PID $lock_pid, ${lock_age}s old) — skipping"
			echo '{"skipped":"concurrency_guard","actions":[]}'
			return 0
		fi
		# Stale lock — remove and continue
		log_info "AI Reasoning: removing stale lock (PID $lock_pid, ${lock_age}s old)"
		rm -f "$lock_file"
	fi
	# Acquire lock
	echo "$$" >"$lock_file"

	# Helper to release lock — called before every return
	_release_ai_lock() { rm -f "$lock_file"; }

	local timestamp
	timestamp=$(date -u '+%Y%m%d-%H%M%S')
	local reason_log="$AI_REASON_LOG_DIR/reason-${timestamp}.md"

	log_info "AI Reasoning: starting ($mode mode)"

	# Step 1: Build context
	local context
	context=$(build_ai_context "$repo_path" "full" 2>/dev/null) || {
		log_error "AI Reasoning: failed to build context"
		_release_ai_lock
		return 1
	}

	local context_bytes
	context_bytes=$(printf '%s' "$context" | wc -c | tr -d ' ')
	log_info "AI Reasoning: context built (${context_bytes} bytes)"

	# Step 2: Build the reasoning prompt
	local system_prompt
	system_prompt=$(build_reasoning_prompt)

	local user_prompt
	user_prompt="$(
		cat <<PROMPT
Here is the current project state:

$context

Analyze this state and produce your action plan as a JSON array.
PROMPT
	)"

	# Step 3: Log the prompt (for auditability)
	{
		echo "# AI Supervisor Reasoning Log"
		echo ""
		echo "Timestamp: $timestamp"
		echo "Mode: $mode"
		echo "Context bytes: $context_bytes"
		echo ""
		echo "## Context Snapshot"
		echo ""
		echo "$context"
		echo ""
		echo "## System Prompt"
		echo ""
		echo "$system_prompt"
		echo ""
	} >"$reason_log"

	# Step 4: In dry-run mode, stop here
	if [[ "$mode" == "dry-run" ]]; then
		log_info "AI Reasoning: dry-run complete (log: $reason_log)"
		_release_ai_lock
		echo '{"mode":"dry-run","actions":[]}'
		return 0
	fi

	# Step 5: Resolve AI CLI and model
	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_error "AI Reasoning: no AI CLI available"
		echo '{"error":"no_ai_cli","actions":[]}' >>"$reason_log"
		_release_ai_lock
		return 1
	}

	local ai_model
	ai_model=$(resolve_model "opus" "$ai_cli" 2>/dev/null) || {
		log_warn "AI Reasoning: opus model unavailable, falling back to sonnet"
		ai_model=$(resolve_model "sonnet" "$ai_cli" 2>/dev/null) || {
			log_error "AI Reasoning: no model available"
			_release_ai_lock
			return 1
		}
	}

	log_info "AI Reasoning: using $ai_model via $ai_cli"

	# Step 6: Spawn AI session
	# Default 300s (5 min) — opus needs time to analyze 15KB+ context and produce structured JSON
	local ai_timeout="${SUPERVISOR_AI_TIMEOUT:-300}"
	local ai_result=""

	local full_prompt="${system_prompt}

${user_prompt}"

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout "$ai_timeout" opencode run \
			-m "$ai_model" \
			--format default \
			--title "ai-supervisor-${timestamp}" \
			"$full_prompt" 2>/dev/null || echo "")
		# Strip ANSI escape codes — opencode --format default includes terminal
		# colour codes that corrupt JSON parsing (t1182)
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		local claude_model="${ai_model#*/}"
		ai_result=$(portable_timeout "$ai_timeout" claude \
			-p "$full_prompt" \
			--model "$claude_model" \
			--output-format text 2>/dev/null || echo "")
	fi

	# Handle empty or whitespace-only response — treat as empty action plan
	# rather than a hard error (t1182: empty output is a valid "no actions" signal)
	local ai_result_trimmed
	ai_result_trimmed=$(printf '%s' "$ai_result" | tr -d '[:space:]')
	if [[ -z "$ai_result_trimmed" ]]; then
		log_info "AI Reasoning: empty response from AI CLI — treating as empty action plan"
		{
			echo "## AI Response"
			echo ""
			echo "Model: $ai_model"
			echo "CLI: $ai_cli"
			echo "Timeout: ${ai_timeout}s"
			echo "Response length: 0 bytes (empty)"
			echo ""
			echo "## Parsing Result"
			echo ""
			echo "Status: EMPTY — treated as empty action plan []"
		} >>"$reason_log"
		printf '%s' "[]"
		_release_ai_lock
		return 0
	fi

	# Step 7: Log the AI response
	{
		echo "## AI Response"
		echo ""
		echo "Model: $ai_model"
		echo "CLI: $ai_cli"
		echo "Timeout: ${ai_timeout}s"
		echo "Response length: $(printf '%s' "$ai_result" | wc -c | tr -d ' ') bytes"
		echo ""
		echo '```'
		echo "$ai_result"
		echo '```'
		echo ""
	} >>"$reason_log"

	# Step 8: Parse the JSON action plan from the response
	local action_plan
	action_plan=$(extract_action_plan "$ai_result")

	# Retry once if parse failed on a non-empty response (t1187, t1201)
	# The AI model occasionally produces malformed or truncated JSON on the first
	# attempt (e.g., markdown-fenced JSON, empty response, preamble text before the
	# array). A single retry with a simplified prompt resolves most transient failures
	# without adding significant latency (the retry only fires when the first attempt
	# fails). The simplified prompt strips the large context and explicitly reinforces
	# "respond with ONLY a JSON array, no markdown fencing" (t1201).
	if [[ -z "$action_plan" || "$action_plan" == "null" ]]; then
		log_warn "AI Reasoning: parse failed on first attempt — retrying with simplified JSON-only prompt (t1187, t1201)"
		{
			echo "## Parse Attempt 1"
			echo ""
			echo "Status: FAILED — retrying with simplified JSON-only prompt"
		} >>"$reason_log"

		# Simplified retry prompt: strip the large context, keep only the output
		# format requirement with explicit reinforcement against markdown fencing.
		# This is more likely to produce clean JSON when the model returned empty
		# output or markdown-wrapped JSON on the first attempt (t1201).
		local simplified_retry_prompt
		simplified_retry_prompt="$(
			cat <<'SIMPLIFIED_PROMPT'
You are an AI Engineering Manager. Your previous response could not be parsed as a JSON array.

Respond with ONLY a JSON array of actions. No markdown fencing (no ```json or ```), no explanation, no preamble — just the raw JSON array starting with [ and ending with ].

If you have no actions to propose, respond with exactly: []

Valid action types: comment_on_issue, create_task, create_subtasks, flag_for_review, adjust_priority, close_verified, request_info, create_improvement, escalate_model, propose_auto_dispatch

Example of correct output (raw JSON, no fencing):
[{"type":"comment_on_issue","issue_number":123,"body":"Status update","reasoning":"Issue needs acknowledgment"}]

Or if nothing needs attention:
[]

Respond with ONLY the JSON array. No markdown, no explanation, no code fences.
SIMPLIFIED_PROMPT
		)"

		local ai_result_retry=""
		if [[ "$ai_cli" == "opencode" ]]; then
			ai_result_retry=$(portable_timeout "$ai_timeout" opencode run \
				-m "$ai_model" \
				--format default \
				--title "ai-supervisor-${timestamp}-retry" \
				"$simplified_retry_prompt" 2>/dev/null || echo "")
			ai_result_retry=$(printf '%s' "$ai_result_retry" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
		else
			local claude_model_retry="${ai_model#*/}"
			ai_result_retry=$(portable_timeout "$ai_timeout" claude \
				-p "$simplified_retry_prompt" \
				--model "$claude_model_retry" \
				--output-format text 2>/dev/null || echo "")
		fi

		local ai_result_retry_trimmed
		ai_result_retry_trimmed=$(printf '%s' "$ai_result_retry" | tr -d '[:space:]')
		if [[ -n "$ai_result_retry_trimmed" ]]; then
			action_plan=$(extract_action_plan "$ai_result_retry")
			{
				echo ""
				echo "## Parse Attempt 2 (simplified JSON-only prompt retry, t1201)"
				echo ""
				echo "Response length: $(printf '%s' "$ai_result_retry" | wc -c | tr -d ' ') bytes"
				echo "Parse result: $([ -n "$action_plan" ] && echo "SUCCESS" || echo "FAILED")"
			} >>"$reason_log"
		else
			log_info "AI Reasoning: simplified retry also returned empty response — treating as empty action plan"
			{
				echo ""
				echo "## Parse Attempt 2 (simplified JSON-only prompt retry, t1201)"
				echo ""
				echo "Response length: 0 bytes (empty)"
				echo "Parse result: EMPTY — treating as empty action plan []"
			} >>"$reason_log"
		fi
	fi

	if [[ -z "$action_plan" || "$action_plan" == "null" ]]; then
		log_warn "AI Reasoning: no parseable action plan after retry — treating as empty action plan"
		# Debug diagnostics for intermittent parse failures (t1182, t1187)
		local response_len json_block_count first_bytes last_bytes raw_hex_head
		response_len=$(printf '%s' "$ai_result" | wc -c | tr -d ' ')
		json_block_count=$(printf '%s' "$ai_result" | grep -c '^```json' 2>/dev/null || echo 0)
		first_bytes=$(printf '%s' "$ai_result" | head -c 200 | tr '\n' ' ')
		last_bytes=$(printf '%s' "$ai_result" | tail -c 200 | tr '\n' ' ')
		raw_hex_head=$(printf '%s' "$ai_result" | head -c 32 | od -An -tx1 | tr -d ' \n' | head -c 64)
		{
			echo "## Parsing Result"
			echo ""
			echo "Status: FAILED after retry — returning empty action plan (rc=0)"
			echo ""
			echo "### Debug Diagnostics"
			echo "- Response length: $response_len bytes"
			echo "- \`\`\`json blocks found: $json_block_count"
			echo "- First 200 bytes: \`$first_bytes\`"
			echo "- Last 200 bytes: \`$last_bytes\`"
			echo "- First 32 bytes (hex): \`$raw_hex_head\`"
			echo ""
			echo "### Raw Response (for debugging)"
			echo ""
			echo '```'
			printf '%s' "$ai_result"
			echo ""
			echo '```'
		} >>"$reason_log"
		log_warn "AI Reasoning: raw response logged to $reason_log (${response_len} bytes, ${json_block_count} json blocks)"
		printf '%s' "[]"
		_release_ai_lock
		return 0
	fi

	# Step 9: Validate the action plan
	local action_count
	action_count=$(printf '%s' "$action_plan" | jq 'length' 2>/dev/null || echo 0)

	{
		echo "## Parsed Action Plan"
		echo ""
		echo "Actions: $action_count"
		echo ""
		echo '```json'
		printf '%s' "$action_plan" | jq '.' 2>/dev/null || printf '%s' "$action_plan"
		echo ""
		echo '```'
	} >>"$reason_log"

	log_info "AI Reasoning: complete ($action_count actions, log: $reason_log)"

	# Step 10: Store reasoning event in DB
	db "$SUPERVISOR_DB" "
		INSERT INTO state_log (task_id, from_state, to_state, reason)
		VALUES ('ai-supervisor', 'reasoning', 'complete',
				'AI reasoning: $action_count actions proposed (model: $ai_model)');
	" 2>/dev/null || true

	# Output the action plan
	printf '%s' "$action_plan"
	_release_ai_lock
	return 0
}

#######################################
# Build the system prompt for the AI reasoning engine
# Returns: prompt text on stdout
#######################################
build_reasoning_prompt() {
	cat <<'SYSTEM_PROMPT'
You are an AI Engineering Manager for a software project. You have been given a comprehensive snapshot of the project's current state including open issues, recent PRs, TODO tasks, worker outcomes, and health metrics.

Your job is to analyze this state and produce a structured action plan. You should think like a senior engineering manager who reviews the project board every morning and decides what needs attention.

## Your Capabilities

You can propose these action types:

1. **comment_on_issue** — Post a comment on a GitHub issue (acknowledge, provide status, request clarification)
2. **create_task** — Add a new task to TODO.md (with title, description, tags, estimate, model tier)
3. **create_subtasks** — Break down an existing task into subtasks. Required fields: `parent_task_id` (string: the task ID to break down, e.g. `"t1234"`), `subtasks` (array of objects, each with `title`, `tags`, `estimate`, `model`), `reasoning` (string).
4. **flag_for_review** — Flag an issue for human review with a reason
5. **adjust_priority** — Suggest reordering tasks with reasoning. Required fields: `task_id` (string), `new_priority` (string: must be exactly `"high"`, `"medium"`, or `"low"`), `reasoning` (string)
6. **close_verified** — Close an issue that has been verified complete (only if PR merged + evidence exists)
7. **request_info** — Ask for clarification on an issue
8. **create_improvement** — Create a self-improvement task to fix an efficiency gap, missing automation, or process weakness
9. **escalate_model** — Recommend changing a task's model tier (e.g., sonnet→opus for complex tasks failing at lower tier, or opus→sonnet for simple tasks wasting tokens)
10. **propose_auto_dispatch** — Propose adding #auto-dispatch tag to an eligible task. The executor adds a [proposed] prefix first; actual tagging happens after one pulse cycle confirmation. Use the "Auto-Dispatch Eligibility Assessment" section to identify candidates. Required fields: `task_id`, `recommended_model`, `reasoning`.
11. **park_task** — Add a `-needed` blocker tag to a task that requires human action before it can be dispatched (e.g., purchasing credits, creating an account, providing credentials). This prevents wasted worker sessions on tasks that will inevitably fail. Required fields: `task_id` (string), `blocker_tag` (string: one of `account-needed`, `hosting-needed`, `login-needed`, `api-key-needed`, `clarification-needed`, `resources-needed`, `payment-needed`, `approval-needed`, `decision-needed`, `design-needed`, `content-needed`, `dns-needed`, `domain-needed`, `testing-needed`), `reasoning` (string).

## Your Analysis Framework

For each analysis, consider:

1. **Solvability**: Which open issues can be broken into dispatchable tasks? Are there issues that just need a clear spec to become actionable?
2. **Verification**: Have recently closed issues/PRs been properly verified? Is there evidence of completion (merged PR, test results)?
3. **Linkage**: Do all closed issues have linked PRs with real deliverables? Are there orphan PRs or issues?
4. **Communication**: Should any issues get a comment? New issues that haven't been acknowledged? Stale issues that need a status update?
5. **Priority**: What should be worked on next and why? Are there blocked tasks that could be unblocked?
6. **Health**: Are there concerning patterns in worker outcomes? High failure rates? Recurring errors?
7. **Efficiency**: Are tokens being wasted? Are tasks assigned to models that are too powerful (opus for simple tasks) or too weak (sonnet for complex reasoning)? Are there repeated failures that indicate a systemic issue rather than a task-specific one? Look at pattern data for model tier success rates.
8. **Self-improvement**: What automation gaps exist? Are there manual steps that could be automated? Missing test coverage? Processes that break repeatedly? Documentation gaps that cause worker confusion? Create improvement tasks to fix these — the goal is maximum utility from minimal token use.
9. **Self-reflection**: Review the "AI Supervisor Self-Reflection" section. Are your own actions being skipped or failing? If an action type is repeatedly skipped (e.g., missing required fields), create a `create_improvement` task to fix the prompt or executor. If you keep acting on the same targets across cycles, stop repeating those actions. If pipeline errors appear, diagnose the root cause and create a fix task. Your goal is to make yourself more effective over time.
10. **Auto-dispatch coverage**: Review the "Auto-Dispatch Eligibility Assessment" section. Are there open tasks that meet all eligibility criteria but lack the #auto-dispatch tag? Propose tagging them via `propose_auto_dispatch`. Only propose for tasks marked "eligible" in the assessment. Never propose for tasks with assignees, unresolved blockers, vague descriptions, or estimates outside the ~30m-~4h range.
11. **Human-action blockers**: Are there tasks that cannot succeed without human intervention (purchasing credits, creating accounts, providing API keys, making design decisions)? Use `park_task` to add the appropriate `-needed` tag. This prevents wasted dispatch cycles. Check task descriptions for phrases like "top up credits", "sign up", "create account", "provide credentials", "manual testing required".

## Output Format

Respond with ONLY a JSON array of actions. Each action is an object with:

```json
[
  {
    "type": "comment_on_issue",
    "issue_number": 123,
    "body": "The comment text",
    "reasoning": "Why this action is needed"
  },
  {
    "type": "create_task",
    "title": "Task title",
    "description": "Full task description",
    "tags": ["#enhancement", "#auto-dispatch"],
    "estimate": "~1h",
    "model": "sonnet",
    "reasoning": "Why this task is needed"
  },
  {
    "type": "create_subtasks",
    "parent_task_id": "t1234",
    "subtasks": [
      {
        "title": "Research and design approach",
        "tags": ["#auto-dispatch"],
        "estimate": "~1h",
        "model": "sonnet"
      },
      {
        "title": "Implement the feature",
        "tags": ["#auto-dispatch"],
        "estimate": "~2h",
        "model": "sonnet"
      }
    ],
    "reasoning": "Task estimate exceeds 4h and has no existing subtasks — breaking into dispatchable units"
  },
  {
    "type": "create_improvement",
    "title": "Automate X to reduce manual intervention",
    "description": "Currently X requires manual steps. Automating this would save ~Y tokens/session.",
    "category": "automation",
    "tags": ["#enhancement", "#auto-dispatch", "#self-improvement"],
    "estimate": "~2h",
    "model": "sonnet",
    "reasoning": "Pattern data shows this manual step fails N% of the time"
  },
  {
    "type": "escalate_model",
    "task_id": "t1234",
    "from_tier": "sonnet",
    "to_tier": "opus",
    "reasoning": "Task failed 2/3 retries at sonnet. Pattern data shows similar tasks succeed at opus."
  },
  {
    "type": "adjust_priority",
    "task_id": "t1234",
    "new_priority": "high",
    "reasoning": "This task is blocking 3 others and should be dispatched next"
  },
  {
    "type": "adjust_priority",
    "task_id": "t5678",
    "new_priority": "low",
    "reasoning": "This task has no active blockers and lower business value than queued work"
  },
  {
    "type": "propose_auto_dispatch",
    "task_id": "t1234",
    "recommended_model": "sonnet",
    "reasoning": "Task has clear spec, bounded scope (~2h), no blockers, and pattern data shows 85% success rate for similar feature tasks at sonnet tier"
  },
  {
    "type": "flag_for_review",
    "issue_number": 456,
    "reason": "Why human review is needed",
    "reasoning": "Analysis that led to this conclusion"
  },
  {
    "type": "request_info",
    "issue_number": 789,
    "questions": ["What is the expected behavior?", "Can you provide reproduction steps?"],
    "reasoning": "Why we need this information"
  },
  {
    "type": "park_task",
    "task_id": "t251",
    "blocker_tag": "payment-needed",
    "reasoning": "Task requires manual credit purchase on cloud.higgsfield.ai before API testing can proceed"
  }
]
```

## Rules

- **EXCLUSION LIST (MANDATORY)**: The context snapshot begins with a "DO NOT ACT — Exclusion List" section. Before proposing ANY action, check its `task_id` and `issue_number` against that list. If the target appears in the exclusion list, OMIT the action entirely. Do not include it in your output, even as a comment. This is the highest-priority rule — it overrides all other analysis.
- Be conservative. Only propose actions you are confident are correct.
- Never close an issue unless you can verify a merged PR exists with real changes.
- Prefer acknowledging issues over ignoring them — a brief "We've seen this, it's queued" is better than silence.
- When creating tasks, include enough detail for an autonomous worker to implement them.
- Include `#auto-dispatch` tag on tasks that can run without human input.
- Keep comments professional and concise.
- If nothing needs attention, return an empty array: []
- Maximum 10 actions per reasoning cycle to keep changes manageable.
- **CRITICAL — DUPLICATE PREVENTION**: Before proposing `create_task` or `create_improvement`, scan the TODO tasks list in the context for ANY existing task (open OR recently completed) that addresses the same root cause, symptom, or investigation area. If such a task exists, DO NOT create a new one — instead, comment on the existing task's issue or adjust its priority. Creating duplicate investigation tasks wastes tokens and compute. A task completed yesterday about the same symptom means the fix is either deployed (wait and observe) or failed (reopen/escalate the existing task). Never create a new task when an existing one covers the same ground.
- For model selection on new tasks: use the cheapest tier that can succeed. Check pattern data — if similar tasks have >75% success at sonnet, don't use opus. Default to sonnet unless the task requires complex reasoning or architecture decisions.
- For escalate_model: only recommend when pattern data shows repeated failures at the current tier, or when the task description clearly requires capabilities beyond the current tier.
- For create_improvement: focus on changes that reduce future token spend or manual intervention. Quantify the expected benefit when possible (e.g., "saves ~500 tokens/task" or "eliminates manual step that fails 30% of the time").
- Self-improvement tasks should be tagged with `#self-improvement` and `#auto-dispatch` so they flow through the normal pipeline.
- For adjust_priority: `new_priority` is REQUIRED and must be exactly one of `"high"`, `"medium"`, or `"low"`. Actions missing this field will be skipped by the executor.
- For create_subtasks: `parent_task_id` is REQUIRED (the task ID string, e.g. `"t1234"`). `subtasks` is REQUIRED and must be a non-empty array. Actions missing either field will be skipped by the executor.
- For propose_auto_dispatch: only propose for tasks listed as "eligible" in the Auto-Dispatch Eligibility Assessment section. The executor uses a two-phase guard: first pulse adds `[proposed:auto-dispatch]` annotation, second pulse (confirmation) applies the actual `#auto-dispatch` tag. This prevents accidental tagging. Required fields: `task_id` (string), `recommended_model` (string: haiku|sonnet|opus), `reasoning` (string).

Respond with ONLY the JSON array. No markdown fencing, no explanation outside the JSON.
SYSTEM_PROMPT
	return 0
}

#######################################
# Extract JSON action plan from AI response
# Handles responses that may include markdown fencing or preamble
# Arguments:
#   $1 - raw AI response text
# Returns:
#   JSON array on stdout, or empty string if not parseable
#######################################
extract_action_plan() {
	local response="$1"

	if [[ -z "$response" ]]; then
		echo ""
		return 0
	fi

	# Handle whitespace-only responses (e.g., model returned only newlines/spaces)
	local trimmed
	trimmed=$(printf '%s' "$response" | tr -d '[:space:]')
	if [[ -z "$trimmed" ]]; then
		echo ""
		return 0
	fi

	# Try 1: Direct JSON parse (response is pure JSON)
	local parsed
	parsed=$(printf '%s' "$response" | jq '.' 2>/dev/null)
	if [[ $? -eq 0 && -n "$parsed" ]]; then
		# Verify it's an array
		local is_array
		is_array=$(printf '%s' "$parsed" | jq 'type' 2>/dev/null || echo "")
		if [[ "$is_array" == '"array"' ]]; then
			printf '%s' "$parsed"
			return 0
		fi
	fi

	# Try 2: Extract the LAST ```json code block (AI often includes analysis
	# in earlier code blocks before the actual JSON action plan).
	# Also handles unclosed blocks (response ends without closing ```).
	local json_block
	json_block=$(printf '%s' "$response" | awk '
		/^```json/ { capture=1; block=""; next }
		/^```$/ && capture { capture=0; last_block=block; next }
		capture { block = block (block ? "\n" : "") $0 }
		END { if (capture && block) print block; else if (last_block) print last_block }
	')
	if [[ -n "$json_block" ]]; then
		parsed=$(printf '%s' "$json_block" | jq '.' 2>/dev/null)
		if [[ $? -eq 0 && -n "$parsed" ]]; then
			printf '%s' "$parsed"
			return 0
		fi
	fi

	# Try 3: Extract from any generic code block (last one, handles unclosed)
	# Only accept if the extracted content is a valid JSON array.
	json_block=$(printf '%s' "$response" | awk '
		/^```/ && !capture { capture=1; block=""; next }
		/^```$/ && capture { capture=0; last_block=block; next }
		capture { block = block (block ? "\n" : "") $0 }
		END { if (capture && block) print block; else if (last_block) print last_block }
	')
	if [[ -n "$json_block" ]]; then
		parsed=$(printf '%s' "$json_block" | jq '.' 2>/dev/null)
		if [[ $? -eq 0 && -n "$parsed" ]]; then
			local block_type
			block_type=$(printf '%s' "$parsed" | jq 'type' 2>/dev/null || echo "")
			if [[ "$block_type" == '"array"' ]]; then
				printf '%s' "$parsed"
				return 0
			fi
		fi
	fi

	# Try 4a: Single-line JSON array — grep for lines starting with [ and parse directly.
	# This handles the common case where the AI returns a single-line array possibly
	# surrounded by preamble/postamble text (t1201).
	local single_line_json
	single_line_json=$(printf '%s' "$response" | grep -E '^[[:space:]]*\[' | tail -1)
	if [[ -n "$single_line_json" ]]; then
		parsed=$(printf '%s' "$single_line_json" | jq '.' 2>/dev/null)
		if [[ $? -eq 0 && -n "$parsed" ]]; then
			local sl_type
			sl_type=$(printf '%s' "$parsed" | jq 'type' 2>/dev/null || echo "")
			if [[ "$sl_type" == '"array"' ]]; then
				printf '%s' "$parsed"
				return 0
			fi
		fi
	fi

	# Try 4b: Find the last multi-line JSON array in the response (between [ and ])
	# Handles both column-0 and indented arrays.
	local bracket_json
	bracket_json=$(printf '%s' "$response" | awk '
		/^[[:space:]]*\[/ { capture=1; block="" }
		capture { block = block (block ? "\n" : "") $0 }
		/^[[:space:]]*\]/ && capture { capture=0; last_block=block }
		END { if (last_block) print last_block }
	')
	if [[ -n "$bracket_json" ]]; then
		parsed=$(printf '%s' "$bracket_json" | jq '.' 2>/dev/null)
		if [[ $? -eq 0 && -n "$parsed" ]]; then
			local arr_type
			arr_type=$(printf '%s' "$parsed" | jq 'type' 2>/dev/null || echo "")
			if [[ "$arr_type" == '"array"' ]]; then
				printf '%s' "$parsed"
				return 0
			fi
		fi
	fi

	# Try 5: Write response to temp file and parse from file
	# This handles edge cases where the shell variable may have lost data
	# (e.g., null bytes, very long lines, or subshell truncation)
	local tmpfile
	tmpfile=$(mktemp "${TMPDIR:-/tmp}/ai-parse-XXXXXX")
	printf '%s' "$response" >"$tmpfile"

	# Try file-based extraction of last ```json block
	json_block=$(awk '
		/^```json/ { capture=1; block=""; next }
		/^```$/ && capture { capture=0; last_block=block; next }
		capture { block = block (block ? "\n" : "") $0 }
		END { if (capture && block) print block; else if (last_block) print last_block }
	' "$tmpfile")
	rm -f "$tmpfile"

	if [[ -n "$json_block" ]]; then
		parsed=$(printf '%s' "$json_block" | jq '.' 2>/dev/null)
		if [[ $? -eq 0 && -n "$parsed" ]]; then
			printf '%s' "$parsed"
			return 0
		fi
	fi

	# Try 6: Strip any remaining ANSI codes and retry ```json extraction (t1182)
	# Handles cases where ANSI stripping in run_ai_reasoning was incomplete or
	# the function is called directly with unstripped output.
	local clean_response
	clean_response=$(printf '%s' "$response" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	if [[ "$clean_response" != "$response" ]]; then
		# ANSI codes were present — retry extraction on clean response
		json_block=$(printf '%s' "$clean_response" | awk '
			/^```json/ { capture=1; block=""; next }
			/^```$/ && capture { capture=0; last_block=block; next }
			capture { block = block (block ? "\n" : "") $0 }
			END { if (capture && block) print block; else if (last_block) print last_block }
		')
		if [[ -n "$json_block" ]]; then
			parsed=$(printf '%s' "$json_block" | jq '.' 2>/dev/null)
			if [[ $? -eq 0 && -n "$parsed" ]]; then
				printf '%s' "$parsed"
				return 0
			fi
		fi
		# Also try direct parse of clean response
		parsed=$(printf '%s' "$clean_response" | jq '.' 2>/dev/null)
		if [[ $? -eq 0 && -n "$parsed" ]]; then
			local clean_type
			clean_type=$(printf '%s' "$parsed" | jq 'type' 2>/dev/null || echo "")
			if [[ "$clean_type" == '"array"' ]]; then
				printf '%s' "$parsed"
				return 0
			fi
		fi
	fi

	# Failed to parse
	echo ""
	return 0
}

#######################################
# Check if AI reasoning should run this pulse
# Uses natural guards instead of artificial pulse counting:
#   1. SUPERVISOR_AI_ENABLED master switch
#   2. has_actionable_work() pre-flight (skip if nothing to reason about)
#   3. Time-based cooldown (SUPERVISOR_AI_COOLDOWN, default 300s = 5 min)
# Arguments:
#   $1 - (optional) force: "true" to skip cooldown check
#   $2 - (optional) repo_path
# Returns:
#   0 if should run, 1 if should skip
#######################################
should_run_ai_reasoning() {
	local force="${1:-false}"
	local repo_path="${2:-$REPO_PATH}"

	if [[ "$force" == "true" ]]; then
		return 0
	fi

	# Check if AI reasoning is enabled
	if [[ "${SUPERVISOR_AI_ENABLED:-true}" != "true" ]]; then
		log_verbose "AI Reasoning: disabled (SUPERVISOR_AI_ENABLED=false)"
		return 1
	fi

	# Pre-flight: is there anything worth reasoning about?
	if ! has_actionable_work "$repo_path"; then
		return 1
	fi

	# Adaptive cooldown: shorter when dispatchable tasks exist, longer when idle.
	# Default base: 300s. With queued tasks: 60s. Idle: 600s.
	local cooldown="${SUPERVISOR_AI_COOLDOWN:-300}"
	if [[ -f "${SUPERVISOR_DB:-}" ]]; then
		local queued_count
		queued_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE status = 'queued';" 2>/dev/null || echo "0")
		queued_count="${queued_count//[^0-9]/}"
		queued_count="${queued_count:-0}"
		if [[ "$queued_count" -gt 0 ]]; then
			cooldown="${SUPERVISOR_AI_COOLDOWN_ACTIVE:-60}"
			log_verbose "AI Reasoning: adaptive cooldown ${cooldown}s (${queued_count} queued tasks)"
		else
			cooldown="${SUPERVISOR_AI_COOLDOWN_IDLE:-600}"
		fi
	fi

	# Get last AI run timestamp
	local last_run
	last_run=$(db "$SUPERVISOR_DB" "
		SELECT MAX(timestamp) FROM state_log
		WHERE task_id = 'ai-supervisor'
		  AND to_state = 'complete';
	" 2>/dev/null || echo "")

	if [[ -z "$last_run" || "$last_run" == "null" ]]; then
		# Never run before — run now
		return 0
	fi

	# Check if enough time has passed since last completion
	local last_epoch now_epoch
	last_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_run" "+%s" 2>/dev/null || date -d "$last_run" "+%s" 2>/dev/null || echo 0)
	now_epoch=$(date "+%s")
	local elapsed=$((now_epoch - last_epoch))

	if [[ "$elapsed" -lt "$cooldown" ]]; then
		log_verbose "AI Reasoning: cooldown (${elapsed}s / ${cooldown}s)"
		return 1
	fi

	return 0
}

#######################################
# CLI entry point for standalone testing
# Usage: ai-reason.sh [--mode full|dry-run|read-only] [--repo /path]
#######################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	set -euo pipefail
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	# Source dependencies
	# shellcheck source=_common.sh
	source "$SCRIPT_DIR/_common.sh"
	# shellcheck source=ai-context.sh
	source "$SCRIPT_DIR/ai-context.sh"

	# Colour codes
	BLUE="${BLUE:-\033[0;34m}"
	GREEN="${GREEN:-\033[0;32m}"
	YELLOW="${YELLOW:-\033[1;33m}"
	RED="${RED:-\033[0;31m}"
	NC="${NC:-\033[0m}"

	# Default paths
	SUPERVISOR_DB="${SUPERVISOR_DB:-$HOME/.aidevops/.agent-workspace/supervisor/supervisor.db}"
	SUPERVISOR_LOG="${SUPERVISOR_LOG:-$HOME/.aidevops/.agent-workspace/supervisor/cron.log}"
	REPO_PATH="${REPO_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

	# Stub resolve_ai_cli and resolve_model if not available
	if ! declare -f resolve_ai_cli &>/dev/null; then
		resolve_ai_cli() {
			if command -v opencode &>/dev/null; then
				echo "opencode"
			elif command -v claude &>/dev/null; then
				echo "claude"
			else
				echo ""
				return 1
			fi
			return 0
		}
	fi

	if ! declare -f resolve_model &>/dev/null; then
		resolve_model() {
			local tier="${1:-opus}"
			case "$tier" in
			opus) echo "anthropic/claude-opus-4-6" ;;
			sonnet) echo "anthropic/claude-sonnet-4-6" ;;
			*) echo "anthropic/claude-sonnet-4-6" ;;
			esac
			return 0
		}
	fi

	# Parse args
	mode="full"
	repo_path="$REPO_PATH"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mode)
			mode="$2"
			shift 2
			;;
		--repo)
			repo_path="$2"
			shift 2
			;;
		--help | -h)
			echo "Usage: ai-reason.sh [--mode full|dry-run|read-only] [--repo /path]"
			echo ""
			echo "Run AI supervisor reasoning cycle."
			echo ""
			echo "Options:"
			echo "  --mode full|dry-run   Reasoning mode (default: full)"
			echo "  --repo /path          Repository path (default: git root)"
			echo "  --help                Show this help"
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			exit 1
			;;
		esac
	done

	run_ai_reasoning "$repo_path" "$mode"
fi
