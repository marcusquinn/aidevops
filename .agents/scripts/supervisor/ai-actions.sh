#!/usr/bin/env bash
# ai-actions.sh - AI Supervisor action executor (t1085.3)
#
# Executes validated actions from the AI reasoning engine's action plan.
# Each action type is validated before execution to prevent unintended changes.
#
# Used by: pulse.sh Phase 14 (AI Action Execution) — wired in t1085.5
# Depends on: ai-reason.sh (run_ai_reasoning), todo-sync.sh, issue-sync.sh
# Sourced by: supervisor-helper.sh (set -euo pipefail inherited)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SCRIPT_DIR, REPO_PATH
#   db(), log_info(), log_warn(), log_error(), sql_escape()
#   commit_and_push_todo() (from todo-sync.sh)
#   find_task_issue_number() (from issue-sync.sh)
#   detect_repo_slug() (from supervisor-helper.sh)

# Action execution log directory (shares with ai-reason)
AI_ACTIONS_LOG_DIR="${AI_ACTIONS_LOG_DIR:-$HOME/.aidevops/logs/ai-supervisor}"

# Semantic dedup: minimum keyword matches for pre-filter candidates (t1218, t1220)
# The keyword pre-filter extracts distinctive words from the proposed title and
# counts overlap with existing open tasks. Tasks with >= this many matching
# keywords become candidates for the AI semantic check.
# Set to 2 (lower than before) since the AI makes the final call.
AI_SEMANTIC_DEDUP_MIN_MATCHES="${AI_SEMANTIC_DEDUP_MIN_MATCHES:-2}"

# AI semantic dedup: use sonnet to verify duplicates (t1220)
# When true, keyword pre-filter candidates are verified by a sonnet API call
# that understands semantic similarity. When false, falls back to keyword-only.
AI_SEMANTIC_DEDUP_USE_AI="${AI_SEMANTIC_DEDUP_USE_AI:-true}"

# AI semantic dedup timeout in seconds
AI_SEMANTIC_DEDUP_TIMEOUT="${AI_SEMANTIC_DEDUP_TIMEOUT:-30}"

# Valid action types — any action not in this list is rejected
readonly AI_VALID_ACTION_TYPES="comment_on_issue create_task create_subtasks flag_for_review adjust_priority close_verified request_info create_improvement escalate_model propose_auto_dispatch"

# Maximum actions per execution cycle (safety limit)
AI_MAX_ACTIONS_PER_CYCLE="${AI_MAX_ACTIONS_PER_CYCLE:-10}"

# Dry-run mode — validate but don't execute (set via --dry-run flag or env)
AI_ACTIONS_DRY_RUN="${AI_ACTIONS_DRY_RUN:-false}"

# Dedup window: number of recent cycles to check for duplicate actions (t1138)
# An action is suppressed if the same (action_type, target) pair was executed
# within this many recent cycles. Set to 0 to disable dedup.
AI_ACTION_DEDUP_WINDOW="${AI_ACTION_DEDUP_WINDOW:-5}"

# Cycle-aware dedup: skip targets whose state hasn't changed since last action (t1179)
# When enabled (default), dedup also checks a state fingerprint for each target.
# If the same (action_type, target) was acted on AND the target's state hasn't
# changed, the action is suppressed. If state changed, the action is allowed
# through even if it was recently executed.
# Set to "false" to fall back to basic (action_type, target) dedup only.
AI_ACTION_CYCLE_AWARE_DEDUP="${AI_ACTION_CYCLE_AWARE_DEDUP:-true}"

#######################################
# Extract the dedup target key from an action based on its type (t1138)
# Each action type has a natural "target" — the entity it acts on.
# Returns a stable string key for dedup comparison.
# Arguments:
#   $1 - JSON action object
#   $2 - action type
# Outputs:
#   Target key string (e.g., "issue:1572", "task:t123")
#######################################
_extract_action_target() {
	local action="$1"
	local action_type="$2"

	case "$action_type" in
	comment_on_issue | flag_for_review | request_info | close_verified)
		local issue_number
		issue_number=$(printf '%s' "$action" | jq -r '.issue_number // "unknown"')
		echo "issue:${issue_number}"
		;;
	create_task | create_improvement)
		# For task creation, use the title as target to prevent duplicate tasks
		local title
		title=$(printf '%s' "$action" | jq -r '.title // "unknown"')
		echo "title:${title}"
		;;
	create_subtasks)
		local parent_task_id
		parent_task_id=$(printf '%s' "$action" | jq -r '.parent_task_id // "unknown"')
		echo "task:${parent_task_id}"
		;;
	adjust_priority | escalate_model | propose_auto_dispatch)
		local task_id
		task_id=$(printf '%s' "$action" | jq -r '.task_id // "unknown"')
		echo "task:${task_id}"
		;;
	*)
		echo "unknown:${action_type}"
		;;
	esac
}

#######################################
# Compute a state fingerprint for a dedup target (t1179)
# The fingerprint captures the target's current state so that cycle-aware
# dedup can detect when a target has changed since the last action.
# Returns a short hash string; "unknown" if state cannot be determined.
#
# State sources by target type:
#   issue:N  → GitHub issue state + label count + comment count + updated_at
#   task:tN  → TODO.md checkbox state + assignee + started/blocked fields
#   title:X  → "static" (creation targets don't have mutable state)
#
# Arguments:
#   $1 - target key (from _extract_action_target)
#   $2 - repo path
#   $3 - repo slug (owner/repo)
# Outputs:
#   State fingerprint string (md5 truncated to 12 chars)
#######################################
_compute_target_state_hash() {
	local target="$1"
	local repo_path="${2:-}"
	local repo_slug="${3:-}"

	local target_type="${target%%:*}"
	local target_id="${target#*:}"
	local state_data=""

	case "$target_type" in
	issue)
		# Query GitHub issue state if gh CLI is available
		if [[ -n "$repo_slug" ]] && command -v gh &>/dev/null; then
			state_data=$(gh issue view "$target_id" --repo "$repo_slug" \
				--json state,labels,comments,updatedAt \
				--jq '[.state, (.labels | length | tostring), (.comments | length | tostring), .updatedAt] | join("|")' \
				2>/dev/null || echo "")
		fi
		# Fallback: check DB for task state if issue maps to a task
		if [[ -z "$state_data" && -n "${SUPERVISOR_DB:-}" && -f "${SUPERVISOR_DB:-}" ]]; then
			state_data=$(db "$SUPERVISOR_DB" "
				SELECT status || '|' || COALESCE(pr_url,'') || '|' || COALESCE(updated_at,'')
				FROM tasks WHERE issue_url LIKE '%/$target_id' OR issue_url LIKE '%issues/$target_id'
				LIMIT 1;
			" 2>/dev/null || echo "")
		fi
		;;
	task)
		# Check TODO.md for task state
		if [[ -n "$repo_path" && -f "$repo_path/TODO.md" ]]; then
			local task_line
			task_line=$(grep -E "^\s*- \[.\] ${target_id}(\s|\.|$)" "$repo_path/TODO.md" 2>/dev/null | head -1 || echo "")
			if [[ -n "$task_line" ]]; then
				# Extract: checkbox state, assignee, started, blocked-by, pr: fields
				local checkbox
				checkbox=$(printf '%s' "$task_line" | grep -oE '\[.\]' | head -1 || echo "")
				local assignee
				assignee=$(printf '%s' "$task_line" | grep -oE 'assignee:[^ ]+' || echo "")
				local started
				started=$(printf '%s' "$task_line" | grep -oE 'started:[^ ]+' || echo "")
				local blocked
				blocked=$(printf '%s' "$task_line" | grep -oE 'blocked-by:[^ ]+' || echo "")
				local pr_field
				pr_field=$(printf '%s' "$task_line" | grep -oE 'pr:#[0-9]+' || echo "")
				state_data="${checkbox}|${assignee}|${started}|${blocked}|${pr_field}"
			fi
		fi
		# Also check DB state
		if [[ -n "${SUPERVISOR_DB:-}" && -f "${SUPERVISOR_DB:-}" ]]; then
			local db_state
			db_state=$(db "$SUPERVISOR_DB" "
				SELECT status || '|' || COALESCE(pr_url,'') || '|' || retries || '|' || COALESCE(updated_at,'')
				FROM tasks WHERE id = '$(sql_escape "$target_id")'
				LIMIT 1;
			" 2>/dev/null || echo "")
			if [[ -n "$db_state" ]]; then
				state_data="${state_data}|db:${db_state}"
			fi
		fi
		;;
	title)
		# Creation targets (create_task, create_improvement) — check if title
		# already exists in TODO.md to detect if it was already created
		if [[ -n "$repo_path" && -f "$repo_path/TODO.md" ]]; then
			local title_exists
			title_exists=$(grep -cF "$target_id" "$repo_path/TODO.md" 2>/dev/null || echo "0")
			state_data="exists:${title_exists}"
		else
			state_data="static"
		fi
		;;
	*)
		state_data="unknown"
		;;
	esac

	# If we couldn't determine state, return "unknown" — dedup will fall back
	# to basic (action_type, target) matching without state awareness
	if [[ -z "$state_data" ]]; then
		echo "unknown"
		return 0
	fi

	# Hash the state data to a short fingerprint
	local hash
	if command -v md5sum &>/dev/null; then
		hash=$(printf '%s' "$state_data" | md5sum | cut -c1-12)
	elif command -v md5 &>/dev/null; then
		hash=$(printf '%s' "$state_data" | md5 | cut -c1-12)
	else
		# Fallback: use the raw data (truncated)
		hash=$(printf '%s' "$state_data" | cut -c1-32)
	fi

	echo "$hash"
	return 0
}

#######################################
# Check if an action was recently executed (dedup check) (t1138, t1179)
# Queries the action_dedup_log for matching (action_type, target) pairs
# within the configured rolling window of recent cycles.
#
# Cycle-aware mode (t1179): When AI_ACTION_CYCLE_AWARE_DEDUP is true,
# also compares the target's current state hash against the hash stored
# when the action was last executed. If the state has changed, the action
# is allowed through (returns 1 = not duplicate) even if the same
# (action_type, target) was recently executed.
#
# Arguments:
#   $1 - action type
#   $2 - target key
#   $3 - (optional) current state hash for cycle-aware comparison (t1179)
# Returns:
#   0 if duplicate found (should skip), 1 if no duplicate (safe to execute)
#######################################
_is_duplicate_action() {
	local action_type="$1"
	local target="$2"
	local current_state_hash="${3:-}"

	# Dedup disabled
	if [[ "${AI_ACTION_DEDUP_WINDOW:-0}" -eq 0 ]]; then
		return 1
	fi

	# Check if DB and table exist
	if [[ -z "${SUPERVISOR_DB:-}" || ! -f "${SUPERVISOR_DB:-}" ]]; then
		return 1
	fi

	local escaped_type escaped_target
	escaped_type=$(sql_escape "$action_type")
	escaped_target=$(sql_escape "$target")

	# Get the N most recent distinct cycle IDs
	local recent_cycles
	recent_cycles=$(db "$SUPERVISOR_DB" "
		SELECT DISTINCT cycle_id FROM action_dedup_log
		WHERE status = 'executed'
		ORDER BY created_at DESC
		LIMIT $AI_ACTION_DEDUP_WINDOW;
	" 2>>"${SUPERVISOR_LOG:-/dev/null}" || echo "")

	if [[ -z "$recent_cycles" ]]; then
		return 1
	fi

	# Build an IN clause from recent cycle IDs
	local in_clause=""
	while IFS= read -r cid; do
		[[ -z "$cid" ]] && continue
		local escaped_cid
		escaped_cid=$(sql_escape "$cid")
		if [[ -z "$in_clause" ]]; then
			in_clause="'$escaped_cid'"
		else
			in_clause="$in_clause,'$escaped_cid'"
		fi
	done <<<"$recent_cycles"

	local match_count
	match_count=$(db "$SUPERVISOR_DB" "
		SELECT COUNT(*) FROM action_dedup_log
		WHERE action_type = '$escaped_type'
		  AND target = '$escaped_target'
		  AND status = 'executed'
		  AND cycle_id IN ($in_clause);
	" 2>>"${SUPERVISOR_LOG:-/dev/null}" || echo "0")

	if [[ "$match_count" -eq 0 ]]; then
		# No prior execution found — not a duplicate
		return 1
	fi

	# Basic dedup says this is a duplicate. Now check cycle-aware state (t1179).
	if [[ "${AI_ACTION_CYCLE_AWARE_DEDUP:-true}" != "true" ]]; then
		# Cycle-aware dedup disabled — use basic dedup result
		return 0
	fi

	# If we have a current state hash, compare against the most recent stored hash
	if [[ -n "$current_state_hash" && "$current_state_hash" != "unknown" ]]; then
		local last_state_hash
		last_state_hash=$(db "$SUPERVISOR_DB" "
			SELECT state_hash FROM action_dedup_log
			WHERE action_type = '$escaped_type'
			  AND target = '$escaped_target'
			  AND status = 'executed'
			  AND state_hash IS NOT NULL
			  AND state_hash != ''
			  AND state_hash != 'unknown'
			  AND cycle_id IN ($in_clause)
			ORDER BY created_at DESC
			LIMIT 1;
		" 2>>"${SUPERVISOR_LOG:-/dev/null}" || echo "")

		if [[ -n "$last_state_hash" && "$last_state_hash" != "$current_state_hash" ]]; then
			# State has changed since last action — allow the action through
			log_info "AI Actions: cycle-aware dedup: $action_type on $target — state changed ($last_state_hash -> $current_state_hash), allowing"
			return 1
		fi

		# State unchanged (or no prior hash) — suppress as duplicate
		return 0
	fi

	# No state hash available — fall back to basic dedup (suppress)
	return 0
}

#######################################
# Record an executed or suppressed action in the dedup log (t1138, t1179)
# Arguments:
#   $1 - cycle ID
#   $2 - action type
#   $3 - target key
#   $4 - status ("executed" or "dedup_suppressed")
#   $5 - (optional) state hash for cycle-aware dedup (t1179)
#######################################
_record_action_dedup() {
	local cycle_id="$1"
	local action_type="$2"
	local target="$3"
	local status="${4:-executed}"
	local state_hash="${5:-}"

	if [[ -z "${SUPERVISOR_DB:-}" || ! -f "${SUPERVISOR_DB:-}" ]]; then
		log_warn "AI Actions: SUPERVISOR_DB not found, cannot record action for dedup."
		return 1
	fi

	local escaped_cycle escaped_type escaped_target escaped_hash
	escaped_cycle=$(sql_escape "$cycle_id")
	escaped_type=$(sql_escape "$action_type")
	escaped_target=$(sql_escape "$target")
	escaped_hash=$(sql_escape "${state_hash:-}")

	db "$SUPERVISOR_DB" "
		INSERT INTO action_dedup_log (cycle_id, action_type, target, status, state_hash)
		VALUES ('$escaped_cycle', '$escaped_type', '$escaped_target', '$status', '$escaped_hash');
	" 2>>"${SUPERVISOR_LOG:-/dev/null}" || {
		log_warn "AI Actions: failed to record dedup entry for $action_type on $target"
		return 1
	}

	return 0
}

#######################################
# Keyword pre-filter: find candidate duplicate tasks (t1218, t1220)
#
# Fast keyword overlap scan — extracts distinctive words from the proposed
# title and counts how many appear in each open task. Returns up to 5
# candidates with the highest overlap for the AI to evaluate.
#
# Arguments:
#   $1 - proposed task title
#   $2 - path to TODO.md
# Outputs:
#   Newline-separated list of "task_id|title_excerpt" for candidates
#   Empty if no candidates found
# Returns:
#   0 if candidates found, 1 if none
#######################################
_keyword_prefilter_open_tasks() {
	local title="$1"
	local todo_file="$2"
	local min_matches="${AI_SEMANTIC_DEDUP_MIN_MATCHES:-2}"

	if [[ ! -f "$todo_file" ]]; then
		return 1
	fi

	local stop_words=" a an the and or but in on to for of is it by at from with as be do has have had this that are was were will can may should would could into not no add fix investigate implement create update check "

	local keywords=""
	local keyword_count=0
	local word
	while IFS= read -r word; do
		[[ -z "$word" ]] && continue
		[[ ${#word} -lt 3 ]] && continue
		if [[ "$stop_words" == *" $word "* ]]; then
			continue
		fi
		keywords="${keywords} ${word}"
		keyword_count=$((keyword_count + 1))
	done < <(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n')

	if [[ $keyword_count -lt $min_matches ]]; then
		return 1
	fi

	# Collect candidates: task_id|match_count|title_excerpt
	local candidates=""
	local task_line

	while IFS= read -r task_line; do
		[[ -z "$task_line" ]] && continue

		local existing_id
		existing_id=$(printf '%s' "$task_line" | grep -oE 't[0-9]+(\.[0-9]+)?' | head -1)
		[[ -z "$existing_id" ]] && continue

		local lower_line
		lower_line=$(printf '%s' "$task_line" | tr '[:upper:]' '[:lower:]')

		local match_count=0
		local kw
		for kw in $keywords; do
			if [[ "$lower_line" == *"$kw"* ]]; then
				match_count=$((match_count + 1))
			fi
		done

		if [[ $match_count -ge $min_matches ]]; then
			# Extract a readable title excerpt (first 120 chars after the task ID)
			local excerpt
			excerpt=$(printf '%s' "$task_line" | sed -E 's/^[[:space:]]*- \[.\] t[0-9]+(\.[0-9]+)? //' | head -c 120)
			candidates="${candidates}${existing_id}|${match_count}|${excerpt}\n"
		fi
	done < <(grep -E '^\s*- \[ \] t[0-9]' "$todo_file" 2>/dev/null)

	if [[ -z "$candidates" ]]; then
		return 1
	fi

	# Sort by match count descending, take top 5
	printf '%b' "$candidates" | sort -t'|' -k2 -rn | head -5
	return 0
}

#######################################
# AI semantic dedup: ask sonnet if a proposed task duplicates an existing one (t1220)
#
# Sends a focused prompt to sonnet with the proposed title and candidate
# existing tasks. The AI determines whether the proposed task is semantically
# a duplicate — understanding that different phrasing can describe the same
# work (e.g., "Investigate X failures" vs "Add diagnostics for X failures").
#
# Arguments:
#   $1 - proposed task title
#   $2 - candidate list (newline-separated "task_id|match_count|excerpt")
# Outputs:
#   If duplicate: the existing task ID (e.g., "t1190")
#   If not duplicate: empty string
# Returns:
#   0 if duplicate confirmed, 1 if not duplicate or AI unavailable
#######################################
_ai_semantic_dedup_check() {
	local proposed_title="$1"
	local candidates="$2"

	# Build the candidate list for the prompt
	local candidate_list=""
	local line
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local cid cexcerpt
		cid=$(printf '%s' "$line" | cut -d'|' -f1)
		cexcerpt=$(printf '%s' "$line" | cut -d'|' -f3-)
		candidate_list="${candidate_list}- ${cid}: ${cexcerpt}\n"
	done <<<"$candidates"

	if [[ -z "$candidate_list" ]]; then
		return 1
	fi

	# Resolve AI CLI and sonnet model
	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_warn "AI Actions: semantic dedup AI check skipped — no AI CLI available"
		return 1
	}

	local ai_model
	ai_model=$(resolve_model "sonnet" "$ai_cli" 2>/dev/null) || {
		log_warn "AI Actions: semantic dedup AI check skipped — sonnet model unavailable"
		return 1
	}

	local prompt
	prompt="You are a task deduplication checker. Determine if a proposed new task is a semantic duplicate of any existing task.

PROPOSED NEW TASK:
\"${proposed_title}\"

EXISTING OPEN TASKS:
$(printf '%b' "$candidate_list")

A task is a DUPLICATE if it describes essentially the same work, investigation, or fix — even if the wording differs. For example:
- \"Investigate X failures\" and \"Add diagnostics for X failures\" are duplicates (same root problem)
- \"Fix timeout in dispatch\" and \"Add logging to dispatch\" are NOT duplicates (different work)

Respond with ONLY a JSON object, no markdown fencing, no explanation:
- If duplicate: {\"duplicate\": true, \"existing_task\": \"tXXXX\", \"confidence\": \"high|medium\"}
- If not duplicate: {\"duplicate\": false}"

	local ai_timeout="${AI_SEMANTIC_DEDUP_TIMEOUT:-30}"
	local ai_result=""

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout "$ai_timeout" opencode run \
			-m "$ai_model" \
			--format default \
			--title "dedup-check-$$" \
			"$prompt" 2>/dev/null || echo "")
		# Strip ANSI escape codes
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		local claude_model="${ai_model#*/}"
		ai_result=$(portable_timeout "$ai_timeout" claude \
			-p "$prompt" \
			--model "$claude_model" \
			--output-format text 2>/dev/null || echo "")
	fi

	# Parse the response — extract JSON from potentially noisy output
	local json_block=""
	json_block=$(printf '%s' "$ai_result" | grep -oE '\{[^}]+\}' | head -1)

	if [[ -z "$json_block" ]]; then
		log_warn "AI Actions: semantic dedup AI check — could not parse response, falling back to keyword-only"
		return 1
	fi

	local is_duplicate existing_task confidence
	is_duplicate=$(printf '%s' "$json_block" | jq -r '.duplicate // false' 2>/dev/null || echo "false")
	existing_task=$(printf '%s' "$json_block" | jq -r '.existing_task // ""' 2>/dev/null || echo "")
	confidence=$(printf '%s' "$json_block" | jq -r '.confidence // "unknown"' 2>/dev/null || echo "unknown")

	if [[ "$is_duplicate" == "true" && -n "$existing_task" ]]; then
		log_info "AI Actions: semantic dedup (t1220): sonnet confirmed duplicate of $existing_task (confidence: $confidence)"
		printf '%s' "$existing_task"
		return 0
	fi

	log_info "AI Actions: semantic dedup (t1220): sonnet says NOT a duplicate"
	return 1
}

#######################################
# Check if a similar open task already exists in TODO.md (t1218, t1220)
#
# Two-layer dedup:
#   1. Fast keyword pre-filter scans open tasks for word overlap (free, instant)
#   2. If candidates found and AI dedup enabled, asks sonnet to confirm
#      semantic similarity (accurate, ~$0.002 per check)
#
# If AI is unavailable or disabled, falls back to keyword-only with a
# higher threshold (3+ matches required without AI confirmation).
#
# Arguments:
#   $1 - proposed task title
#   $2 - path to TODO.md
# Outputs:
#   If similar task found: "tXXXX" (the existing task ID)
#   If no similar task: "" (empty string)
# Returns:
#   0 if similar task found (should skip creation)
#   1 if no similar task (safe to create)
#######################################
_check_similar_open_task() {
	local title="$1"
	local todo_file="$2"

	if [[ ! -f "$todo_file" ]]; then
		return 1
	fi

	# Step 1: Fast keyword pre-filter
	local candidates
	candidates=$(_keyword_prefilter_open_tasks "$title" "$todo_file") || return 1

	# Step 2: AI semantic check (if enabled and CLI available)
	if [[ "${AI_SEMANTIC_DEDUP_USE_AI:-true}" == "true" ]]; then
		local ai_result
		if ai_result=$(_ai_semantic_dedup_check "$title" "$candidates"); then
			printf '%s' "$ai_result"
			return 0
		fi
		# AI said not a duplicate or was unavailable — trust the AI over keywords
		log_info "AI Actions: semantic dedup: AI did not confirm duplicate, allowing task creation"
		return 1
	fi

	# Fallback: keyword-only mode (AI disabled) — require higher threshold
	local best_id best_count
	best_id=$(printf '%s' "$candidates" | head -1 | cut -d'|' -f1)
	best_count=$(printf '%s' "$candidates" | head -1 | cut -d'|' -f2)

	# Without AI confirmation, require 3+ keyword matches (stricter)
	if [[ -n "$best_id" && "$best_count" -ge 3 ]]; then
		log_info "AI Actions: semantic dedup (keyword-only fallback): $best_id matches with $best_count keywords"
		printf '%s' "$best_id"
		return 0
	fi

	return 1
}

#######################################
# Execute a validated action plan from the AI reasoning engine
# Arguments:
#   $1 - JSON action plan (array of action objects)
#   $2 - repo path
#   $3 - (optional) mode: "execute" (default), "dry-run", "validate-only"
# Outputs:
#   JSON execution report to stdout
# Returns:
#   0 on success (even if some actions failed), 1 on invalid input
#######################################
execute_action_plan() {
	local action_plan="$1"
	local repo_path="${2:-$REPO_PATH}"
	local mode="${3:-execute}"

	# Ensure log directory exists
	mkdir -p "$AI_ACTIONS_LOG_DIR"

	local timestamp
	timestamp=$(date -u '+%Y%m%d-%H%M%S')
	local action_log="$AI_ACTIONS_LOG_DIR/actions-${timestamp}.md"

	# Validate input is a JSON array (t1223)
	# Step 1: Check it's valid JSON at all
	local input_type
	input_type=$(printf '%s' "$action_plan" | jq 'type' 2>/dev/null || echo "")
	if [[ -z "$input_type" ]]; then
		# jq failed — not valid JSON
		local raw_len raw_head
		raw_len=$(printf '%s' "$action_plan" | wc -c | tr -d ' ')
		raw_head=$(printf '%s' "$action_plan" | head -c 200 | tr '\n' ' ')
		log_error "AI Actions: invalid JSON input (len=${raw_len} head='${raw_head}')"
		echo '{"error":"invalid_json","executed":0,"failed":0}'
		return 1
	fi

	# Step 2: Verify it's specifically an array — jq 'length' on a string/object
	# returns a non-negative number and bypasses the -1 guard, causing downstream
	# failures when the loop tries jq ".[$i]" on a non-array value (t1223)
	if [[ "$input_type" != '"array"' ]]; then
		local raw_len raw_head
		raw_len=$(printf '%s' "$action_plan" | wc -c | tr -d ' ')
		raw_head=$(printf '%s' "$action_plan" | head -c 200 | tr '\n' ' ')
		log_warn "AI Actions: expected array, got ${input_type} (len=${raw_len} head='${raw_head}') — returning gracefully"
		echo '{"error":"non_array_input","executed":0,"failed":0,"skipped":0,"actions":[]}'
		return 0
	fi

	local action_count
	action_count=$(printf '%s' "$action_plan" | jq 'length' 2>/dev/null || echo 0)

	if [[ "$action_count" -eq 0 ]]; then
		log_info "AI Actions: empty action plan — nothing to execute"
		echo '{"executed":0,"failed":0,"skipped":0,"actions":[]}'
		return 0
	fi

	# Safety limit
	if [[ "$action_count" -gt "$AI_MAX_ACTIONS_PER_CYCLE" ]]; then
		log_warn "AI Actions: plan has $action_count actions, capping at $AI_MAX_ACTIONS_PER_CYCLE"
		action_plan=$(printf '%s' "$action_plan" | jq ".[0:$AI_MAX_ACTIONS_PER_CYCLE]")
		action_count="$AI_MAX_ACTIONS_PER_CYCLE"
	fi

	log_info "AI Actions: processing $action_count actions ($mode mode)"

	# Generate a unique cycle ID for dedup tracking (t1138)
	local cycle_id="cycle-${timestamp}-$$"

	# Start log
	{
		echo "# AI Supervisor Action Execution Log"
		echo ""
		echo "Timestamp: $timestamp"
		echo "Cycle ID: $cycle_id"
		echo "Mode: $mode"
		echo "Actions: $action_count"
		echo "Repo: $repo_path"
		echo "Dedup window: ${AI_ACTION_DEDUP_WINDOW:-0} cycles"
		echo "Cycle-aware dedup: ${AI_ACTION_CYCLE_AWARE_DEDUP:-true}"
		echo ""
	} >"$action_log"

	# Resolve repo slug for GitHub operations
	local repo_slug=""
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")

	# Process each action
	local executed=0
	local failed=0
	local skipped=0
	local dedup_suppressed=0
	local results="[]"
	local i

	for ((i = 0; i < action_count; i++)); do
		local action
		action=$(printf '%s' "$action_plan" | jq ".[$i]")

		local action_type
		action_type=$(printf '%s' "$action" | jq -r '.type // "unknown"')

		local reasoning
		reasoning=$(printf '%s' "$action" | jq -r '.reasoning // "no reasoning provided"')

		# Step 1: Validate action type
		if ! validate_action_type "$action_type"; then
			log_warn "AI Actions: skipping invalid action type '$action_type'"
			skipped=$((skipped + 1))
			results=$(printf '%s' "$results" | jq \
				--argjson idx "$i" \
				--arg type "$action_type" \
				'. + [{"index": $idx, "type": $type, "status": "skipped", "reason": "invalid_action_type"}]')
			{
				echo "## Action $((i + 1)): $action_type — SKIPPED (invalid type)"
				echo ""
			} >>"$action_log"
			continue
		fi

		# Step 2: Validate action-specific fields
		local validation_error
		validation_error=$(validate_action_fields "$action" "$action_type")
		if [[ -n "$validation_error" ]]; then
			log_warn "AI Actions: skipping $action_type — $validation_error"
			skipped=$((skipped + 1))
			results=$(printf '%s' "$results" | jq \
				--argjson idx "$i" \
				--arg type "$action_type" \
				--arg reason "$validation_error" \
				'. + [{"index": $idx, "type": $type, "status": "skipped", "reason": $reason}]')
			{
				echo "## Action $((i + 1)): $action_type — SKIPPED ($validation_error)"
				echo ""
			} >>"$action_log"
			continue
		fi

		# Step 2b: Dedup check — skip if same (action_type, target) was
		# executed in the last N cycles (t1138, t1179 cycle-aware)
		local dedup_target
		dedup_target=$(_extract_action_target "$action" "$action_type")

		# Compute state hash for cycle-aware dedup (t1179)
		local state_hash=""
		if [[ "${AI_ACTION_CYCLE_AWARE_DEDUP:-true}" == "true" && "${AI_ACTION_DEDUP_WINDOW:-0}" -gt 0 ]]; then
			state_hash=$(_compute_target_state_hash "$dedup_target" "$repo_path" "$repo_slug")
		fi

		if [[ "${AI_ACTION_DEDUP_WINDOW:-0}" -gt 0 ]] && _is_duplicate_action "$action_type" "$dedup_target" "$state_hash"; then
			log_info "AI Actions: [$((i + 1))/$action_count] $action_type on $dedup_target — dedup_suppressed (acted on in last $AI_ACTION_DEDUP_WINDOW cycles, state unchanged)"
			skipped=$((skipped + 1))
			dedup_suppressed=$((dedup_suppressed + 1))
			_record_action_dedup "$cycle_id" "$action_type" "$dedup_target" "dedup_suppressed" "$state_hash"
			local escaped_dedup_reason
			escaped_dedup_reason=$(printf '%s' "dedup_suppressed: $action_type on $dedup_target already executed in last $AI_ACTION_DEDUP_WINDOW cycles (state_hash=$state_hash)" | jq -Rs '.')
			results=$(printf '%s' "$results" | jq ". + [{\"index\":$i,\"type\":\"$action_type\",\"status\":\"dedup_suppressed\",\"target\":\"$dedup_target\",\"state_hash\":\"$state_hash\",\"reason\":$escaped_dedup_reason}]")
			{
				echo "## Action $((i + 1)): $action_type — DEDUP SUPPRESSED (cycle-aware)"
				echo "Target: $dedup_target"
				echo "State hash: $state_hash"
				echo "Reasoning: $reasoning"
				echo "Suppression: same (action_type, target) executed in last $AI_ACTION_DEDUP_WINDOW cycles, target state unchanged"
				echo ""
			} >>"$action_log"
			continue
		fi

		# Step 3: Execute (or simulate in dry-run/validate-only mode)
		if [[ "$mode" == "validate-only" ]]; then
			log_info "AI Actions: [$((i + 1))/$action_count] $action_type — validated"
			skipped=$((skipped + 1))
			results=$(printf '%s' "$results" | jq \
				--argjson idx "$i" \
				--arg type "$action_type" \
				'. + [{"index": $idx, "type": $type, "status": "validated"}]')
			{
				echo "## Action $((i + 1)): $action_type — VALIDATED"
				echo "Reasoning: $reasoning"
				echo ""
			} >>"$action_log"
			continue
		fi

		if [[ "$mode" == "dry-run" || "$AI_ACTIONS_DRY_RUN" == "true" ]]; then
			log_info "AI Actions: [$((i + 1))/$action_count] $action_type — dry-run"
			executed=$((executed + 1))
			results=$(printf '%s' "$results" | jq \
				--argjson idx "$i" \
				--arg type "$action_type" \
				'. + [{"index": $idx, "type": $type, "status": "dry_run"}]')
			{
				echo "## Action $((i + 1)): $action_type — DRY RUN"
				echo "Reasoning: $reasoning"
				echo ""
				echo '```json'
				printf '%s' "$action" | jq '.'
				echo '```'
				echo ""
			} >>"$action_log"
			continue
		fi

		# Execute the action
		local exec_result
		exec_result=$(execute_single_action "$action" "$action_type" "$repo_path" "$repo_slug" 2>>"$SUPERVISOR_LOG")
		local exec_rc=$?

		# Extract only the JSON portion from exec_result — git operations
		# (commit_and_push_todo) can leak stdout noise (e.g. "Updating ...",
		# "Fast-forward", "Created autostash") before the final JSON line.
		local exec_result_json
		exec_result_json=$(printf '%s' "$exec_result" | grep -E '^\{' | tail -1)
		if [[ -z "$exec_result_json" ]] || ! printf '%s' "$exec_result_json" | jq '.' &>/dev/null; then
			# Not valid JSON — wrap the entire result as a JSON string value
			exec_result_json=$(jq -Rn --arg v "$exec_result" '$v')
		fi

		if [[ $exec_rc -eq 0 ]]; then
			executed=$((executed + 1))
			log_info "AI Actions: [$((i + 1))/$action_count] $action_type — success"
			results=$(printf '%s' "$results" | jq \
				--argjson idx "$i" \
				--arg type "$action_type" \
				--argjson r "$exec_result_json" \
				'. + [{"index": $idx, "type": $type, "status": "executed", "result": $r}]')
			_record_action_dedup "$cycle_id" "$action_type" "$dedup_target" "executed" "$state_hash"
		else
			failed=$((failed + 1))
			log_warn "AI Actions: [$((i + 1))/$action_count] $action_type — failed"
			results=$(printf '%s' "$results" | jq \
				--argjson idx "$i" \
				--arg type "$action_type" \
				--arg error "$exec_result" \
				'. + [{"index": $idx, "type": $type, "status": "failed", "error": $error}]')
		fi

		{
			echo "## Action $((i + 1)): $action_type — $([ $exec_rc -eq 0 ] && echo "SUCCESS" || echo "FAILED")"
			echo "Reasoning: $reasoning"
			echo "Result: $exec_result"
			echo ""
		} >>"$action_log"
	done

	# Summary
	local summary
	summary=$(jq -n \
		--argjson executed "$executed" \
		--argjson failed "$failed" \
		--argjson skipped "$skipped" \
		--argjson dedup_suppressed "$dedup_suppressed" \
		--argjson actions "$results" \
		'{executed: $executed, failed: $failed, skipped: $skipped, dedup_suppressed: $dedup_suppressed, actions: $actions}')

	{
		echo "## Summary"
		echo ""
		echo "- Executed: $executed"
		echo "- Failed: $failed"
		echo "- Skipped: $skipped"
		echo "- Dedup suppressed: $dedup_suppressed"
		echo ""
	} >>"$action_log"

	log_info "AI Actions: complete (executed=$executed failed=$failed skipped=$skipped dedup_suppressed=$dedup_suppressed log=$action_log)"

	# Store execution event in DB
	db "$SUPERVISOR_DB" "
		INSERT INTO state_log (task_id, from_state, to_state, reason)
		VALUES ('ai-supervisor', 'actions', 'complete',
				'$(sql_escape "AI actions: $executed executed, $failed failed, $skipped skipped, $dedup_suppressed dedup_suppressed")');
	" 2>/dev/null || true

	printf '%s' "$summary"
	return 0
}

#######################################
# Validate that an action type is in the allowed list
# Arguments:
#   $1 - action type string
# Returns:
#   0 if valid, 1 if invalid
#######################################
validate_action_type() {
	local action_type="$1"
	local valid_type

	for valid_type in $AI_VALID_ACTION_TYPES; do
		if [[ "$action_type" == "$valid_type" ]]; then
			return 0
		fi
	done

	return 1
}

#######################################
# Validate action-specific required fields
# Arguments:
#   $1 - JSON action object
#   $2 - action type
# Returns:
#   Empty string if valid, error message if invalid
#######################################
validate_action_fields() {
	local action="$1"
	local action_type="$2"

	case "$action_type" in
	comment_on_issue)
		local issue_number body
		issue_number=$(printf '%s' "$action" | jq -r '.issue_number // empty')
		body=$(printf '%s' "$action" | jq -r '.body // empty')
		if [[ -z "$issue_number" ]]; then
			echo "missing required field: issue_number"
			return 0
		fi
		if [[ -z "$body" ]]; then
			echo "missing required field: body"
			return 0
		fi
		# Validate issue_number is a positive integer
		if ! [[ "$issue_number" =~ ^[0-9]+$ ]] || [[ "$issue_number" -eq 0 ]]; then
			echo "issue_number must be a positive integer, got: $issue_number"
			return 0
		fi
		;;
	create_task)
		local title
		title=$(printf '%s' "$action" | jq -r '.title // empty')
		if [[ -z "$title" ]]; then
			echo "missing required field: title"
			return 0
		fi
		;;
	create_subtasks)
		local parent_task_id subtasks
		parent_task_id=$(printf '%s' "$action" | jq -r '.parent_task_id // empty')
		subtasks=$(printf '%s' "$action" | jq -r '.subtasks // empty')
		if [[ -z "$parent_task_id" ]]; then
			echo "missing required field: parent_task_id"
			return 0
		fi
		if [[ -z "$subtasks" || "$subtasks" == "null" ]]; then
			echo "missing required field: subtasks (array)"
			return 0
		fi
		local subtask_count
		subtask_count=$(printf '%s' "$action" | jq '.subtasks | length' 2>/dev/null || echo 0)
		if [[ "$subtask_count" -eq 0 ]]; then
			echo "subtasks array is empty"
			return 0
		fi
		;;
	flag_for_review)
		local issue_number reason
		issue_number=$(printf '%s' "$action" | jq -r '.issue_number // empty')
		reason=$(printf '%s' "$action" | jq -r '.reason // empty')
		if [[ -z "$issue_number" ]]; then
			echo "missing required field: issue_number"
			return 0
		fi
		if [[ -z "$reason" ]]; then
			echo "missing required field: reason"
			return 0
		fi
		if ! [[ "$issue_number" =~ ^[0-9]+$ ]] || [[ "$issue_number" -eq 0 ]]; then
			echo "issue_number must be a positive integer, got: $issue_number"
			return 0
		fi
		;;
	adjust_priority)
		local task_id new_priority
		task_id=$(printf '%s' "$action" | jq -r '.task_id // empty')
		new_priority=$(printf '%s' "$action" | jq -r '.new_priority // empty')
		if [[ -z "$task_id" ]]; then
			echo "missing required field: task_id"
			return 0
		fi
		# Validate new_priority when provided — must be one of the known values.
		# The executor infers priority from reasoning text when the field is absent,
		# but if the field IS present it must be a valid value (t1197).
		if [[ -n "$new_priority" && "$new_priority" != "null" ]]; then
			case "$new_priority" in
			high | medium | low | critical) ;;
			*)
				echo "invalid new_priority: $new_priority (must be high|medium|low|critical)"
				return 0
				;;
			esac
		fi
		;;
	close_verified)
		local issue_number pr_number
		issue_number=$(printf '%s' "$action" | jq -r '.issue_number // empty')
		pr_number=$(printf '%s' "$action" | jq -r '.pr_number // empty')
		if [[ -z "$issue_number" ]]; then
			echo "missing required field: issue_number"
			return 0
		fi
		if [[ -z "$pr_number" ]]; then
			echo "missing required field: pr_number (must prove merged PR exists)"
			return 0
		fi
		if ! [[ "$issue_number" =~ ^[0-9]+$ ]] || [[ "$issue_number" -eq 0 ]]; then
			echo "issue_number must be a positive integer, got: $issue_number"
			return 0
		fi
		if ! [[ "$pr_number" =~ ^[0-9]+$ ]] || [[ "$pr_number" -eq 0 ]]; then
			echo "pr_number must be a positive integer, got: $pr_number"
			return 0
		fi
		;;
	request_info)
		local issue_number questions
		issue_number=$(printf '%s' "$action" | jq -r '.issue_number // empty')
		questions=$(printf '%s' "$action" | jq -r '.questions // empty')
		if [[ -z "$issue_number" ]]; then
			echo "missing required field: issue_number"
			return 0
		fi
		if [[ -z "$questions" || "$questions" == "null" ]]; then
			echo "missing required field: questions (array)"
			return 0
		fi
		if ! [[ "$issue_number" =~ ^[0-9]+$ ]] || [[ "$issue_number" -eq 0 ]]; then
			echo "issue_number must be a positive integer, got: $issue_number"
			return 0
		fi
		;;
	create_improvement)
		local title
		title=$(printf '%s' "$action" | jq -r '.title // empty')
		if [[ -z "$title" ]]; then
			echo "missing required field: title"
			return 0
		fi
		;;
	escalate_model)
		local task_id from_tier to_tier
		task_id=$(printf '%s' "$action" | jq -r '.task_id // empty')
		from_tier=$(printf '%s' "$action" | jq -r '.from_tier // empty')
		to_tier=$(printf '%s' "$action" | jq -r '.to_tier // empty')
		if [[ -z "$task_id" ]]; then
			echo "missing required field: task_id"
			return 0
		fi
		if [[ -z "$to_tier" ]]; then
			echo "missing required field: to_tier"
			return 0
		fi
		;;
	propose_auto_dispatch)
		local task_id recommended_model
		task_id=$(printf '%s' "$action" | jq -r '.task_id // empty')
		recommended_model=$(printf '%s' "$action" | jq -r '.recommended_model // empty')
		if [[ -z "$task_id" ]]; then
			echo "missing required field: task_id"
			return 0
		fi
		if [[ -z "$recommended_model" ]]; then
			echo "missing required field: recommended_model"
			return 0
		fi
		# Validate model tier
		case "$recommended_model" in
		haiku | flash | sonnet | pro | opus) ;;
		*)
			echo "invalid recommended_model: $recommended_model (must be haiku|flash|sonnet|pro|opus)"
			return 0
			;;
		esac
		;;
	*)
		echo "unhandled action type: $action_type"
		return 0
		;;
	esac

	# Valid — return empty string
	echo ""
	return 0
}

#######################################
# Execute a single validated action
# Arguments:
#   $1 - JSON action object
#   $2 - action type
#   $3 - repo path
#   $4 - repo slug (owner/repo)
# Outputs:
#   JSON result to stdout
# Returns:
#   0 on success, 1 on failure
#######################################
execute_single_action() {
	local action="$1"
	local action_type="$2"
	local repo_path="$3"
	local repo_slug="$4"

	case "$action_type" in
	comment_on_issue) _exec_comment_on_issue "$action" "$repo_slug" ;;
	create_task) _exec_create_task "$action" "$repo_path" ;;
	create_subtasks) _exec_create_subtasks "$action" "$repo_path" ;;
	flag_for_review) _exec_flag_for_review "$action" "$repo_slug" ;;
	adjust_priority) _exec_adjust_priority "$action" "$repo_path" ;;
	close_verified) _exec_close_verified "$action" "$repo_slug" ;;
	request_info) _exec_request_info "$action" "$repo_slug" ;;
	create_improvement) _exec_create_improvement "$action" "$repo_path" ;;
	escalate_model) _exec_escalate_model "$action" "$repo_path" ;;
	propose_auto_dispatch) _exec_propose_auto_dispatch "$action" "$repo_path" ;;
	*)
		echo '{"error":"unhandled_action_type"}'
		return 1
		;;
	esac
}

#######################################
# Action: comment_on_issue
# Posts a comment on a GitHub issue
#######################################
_exec_comment_on_issue() {
	local action="$1"
	local repo_slug="$2"

	local issue_number body
	issue_number=$(printf '%s' "$action" | jq -r '.issue_number')
	body=$(printf '%s' "$action" | jq -r '.body')

	if [[ -z "$repo_slug" ]]; then
		echo '{"error":"no_repo_slug"}'
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		echo '{"error":"gh_cli_not_available"}'
		return 1
	fi

	# Verify issue exists before commenting
	if ! gh issue view "$issue_number" --repo "$repo_slug" --json number &>/dev/null; then
		echo "{\"error\":\"issue_not_found\",\"issue_number\":$issue_number}"
		return 1
	fi

	# Add AI supervisor attribution footer
	local full_body
	full_body="${body}

---
*Posted by AI Supervisor (automated reasoning cycle)*"

	if gh issue comment "$issue_number" --repo "$repo_slug" --body "$full_body" &>/dev/null; then
		echo "{\"commented\":true,\"issue_number\":$issue_number}"
		return 0
	else
		echo "{\"error\":\"comment_failed\",\"issue_number\":$issue_number}"
		return 1
	fi
}

#######################################
# Action: create_task
# Adds a new task to TODO.md via claim-task-id.sh
#######################################
_exec_create_task() {
	local action="$1"
	local repo_path="$2"

	local title description tags estimate model
	title=$(printf '%s' "$action" | jq -r '.title')
	description=$(printf '%s' "$action" | jq -r '.description // ""')
	tags=$(printf '%s' "$action" | jq -r '(.tags // []) | join(" ")')
	estimate=$(printf '%s' "$action" | jq -r '.estimate // "~1h"')
	model=$(printf '%s' "$action" | jq -r '.model // "sonnet"')

	local todo_file="$repo_path/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		echo '{"error":"todo_file_not_found"}'
		return 1
	fi

	# Semantic dedup: check if a similar open task already exists (t1218)
	local similar_task_id
	if similar_task_id=$(_check_similar_open_task "$title" "$todo_file"); then
		log_info "AI Actions: create_task skipped — similar open task $similar_task_id exists (t1218)"
		jq -n --arg existing "$similar_task_id" --arg title "$title" \
			'{"skipped": true, "reason": "similar_task_exists", "existing_task": $existing, "proposed_title": $title}'
		return 0
	fi

	# Allocate task ID via claim-task-id.sh
	local claim_script="${SCRIPT_DIR}/claim-task-id.sh"
	local task_id=""

	if [[ -x "$claim_script" ]]; then
		local claim_output
		claim_output=$("$claim_script" --title "$title" --repo-path "$repo_path" 2>/dev/null || echo "")
		task_id=$(printf '%s' "$claim_output" | grep -oE 'task_id=t[0-9]+' | head -1 | sed 's/task_id=//')
	fi

	if [[ -z "$task_id" ]]; then
		# Fallback: use timestamp-based ID (will be reconciled later)
		task_id="t$(date +%s | tail -c 5)"
		log_warn "AI Actions: claim-task-id.sh unavailable, using fallback ID $task_id"
	fi

	# Build the task line
	local task_line="- [ ] $task_id $title"
	if [[ -n "$tags" ]]; then
		task_line="$task_line $tags"
	fi
	task_line="$task_line $estimate model:$model"
	if [[ -n "$description" ]]; then
		task_line="$task_line — $description"
	fi

	# Append to TODO.md (before the first blank line after the last task)
	# Find the "Backlog" or last task section and append there
	printf '\n%s\n' "$task_line" >>"$todo_file"

	# Commit and push (redirect stdout to log — git operations leak noise)
	if declare -f commit_and_push_todo &>/dev/null; then
		commit_and_push_todo "$repo_path" "chore: AI supervisor created task $task_id" >>"$SUPERVISOR_LOG" 2>&1 || true
	fi

	jq -n --arg task_id "$task_id" --arg title "$title" \
		'{"created": true, "task_id": $task_id, "title": $title}'
	return 0
}

#######################################
# Action: create_subtasks
# Breaks down an existing task into subtasks in TODO.md
#######################################
_exec_create_subtasks() {
	local action="$1"
	local repo_path="$2"

	local parent_task_id
	parent_task_id=$(printf '%s' "$action" | jq -r '.parent_task_id // empty')

	# Input validation: parent_task_id is required
	if [[ -z "$parent_task_id" || "$parent_task_id" == "null" ]]; then
		log_warn "create_subtasks: missing required field parent_task_id"
		echo '{"error":"missing_parent_task_id","detail":"parent_task_id is required and must be a non-empty string"}'
		return 1
	fi

	# Input validation: subtasks array is required and non-empty
	local subtask_count
	subtask_count=$(printf '%s' "$action" | jq '.subtasks | length' 2>/dev/null || echo 0)
	if [[ "$subtask_count" -eq 0 ]]; then
		log_warn "create_subtasks: subtasks array is missing or empty for parent $parent_task_id"
		jq -n --arg parent "$parent_task_id" \
			'{"error":"missing_subtasks","parent_task_id":$parent,"detail":"subtasks must be a non-empty array"}'
		return 1
	fi

	# Resolve the task's repo from the supervisor DB (t1234, t1237).
	# Tasks are always repo-specific — never guess by falling back to the
	# primary repo, because task IDs can collide across repos (e.g., both
	# aidevops and awardsapp have t003 for different things). Writing to
	# the wrong repo is a privacy breach if repo visibility differs.
	#
	# If the parent task is NOT in the DB, refuse to proceed — the AI reasoner
	# may be hallucinating subtasks for a task from another repo that happens
	# to share the same ID in the current repo's TODO.md.
	local db_repo_path=""
	if [[ -n "${SUPERVISOR_DB:-}" && -f "${SUPERVISOR_DB:-}" ]]; then
		db_repo_path=$(db "$SUPERVISOR_DB" "
			SELECT repo FROM tasks WHERE id = '$(sql_escape "$parent_task_id")' AND repo IS NOT NULL AND repo != '' LIMIT 1;
		" 2>/dev/null || echo "")
	fi
	if [[ -n "$db_repo_path" ]]; then
		local canonical_db
		canonical_db=$(realpath "$db_repo_path" 2>/dev/null || echo "")
		if [[ -n "$canonical_db" && -f "$canonical_db/TODO.md" ]]; then
			repo_path="$canonical_db"
		else
			log_warn "create_subtasks: DB repo path for $parent_task_id is stale or missing TODO.md: $db_repo_path"
			jq -n --arg parent "$parent_task_id" --arg repo "$db_repo_path" \
				'{"error":"db_repo_path_invalid","parent_task_id":$parent,"repo_path":$repo}'
			return 1
		fi
	elif [[ -n "${SUPERVISOR_DB:-}" && -f "${SUPERVISOR_DB:-}" ]]; then
		# DB exists but has no record for this task — refuse to guess (t1237).
		# The task may belong to another repo with a colliding ID.
		log_warn "create_subtasks: $parent_task_id not found in supervisor DB — cannot determine repo, refusing to guess"
		jq -n --arg parent "$parent_task_id" \
			'{"error":"task_not_in_db","parent_task_id":$parent,"detail":"Task not registered in supervisor DB. Cannot determine correct repo — refusing to create subtasks to prevent cross-repo writes."}'
		return 1
	fi

	local todo_file="$repo_path/TODO.md"

	# Guard: refuse to create subtasks for completed parent tasks (t1237).
	# The auto-subtasking eligibility check should skip [x] tasks, but if
	# the AI reasoner requests it anyway, block it here as a safety net.
	if grep -qE "^\s*- \[x\] $parent_task_id " "$todo_file" 2>/dev/null; then
		log_warn "create_subtasks: parent task $parent_task_id is already completed in $todo_file"
		jq -n --arg parent "$parent_task_id" --arg todo "$todo_file" \
			'{"error":"parent_task_completed","parent_task_id":$parent,"todo_file":$todo,"detail":"Cannot create subtasks for a completed task."}'
		return 1
	fi

	if [[ ! -f "$todo_file" ]]; then
		log_warn "create_subtasks: TODO.md not found at $todo_file (parent: $parent_task_id)"
		jq -n --arg parent "$parent_task_id" --arg repo "$repo_path" \
			'{"error":"todo_file_not_found","parent_task_id":$parent,"repo_path":$repo}'
		return 1
	fi

	# Verify parent task exists in TODO.md
	if ! grep -q "^\s*- \[.\] $parent_task_id " "$todo_file" 2>/dev/null; then
		log_warn "create_subtasks: parent task $parent_task_id not found in $todo_file"
		jq -n --arg parent "$parent_task_id" --arg todo "$todo_file" \
			'{"error":"parent_task_not_found","parent_task_id":$parent,"todo_file":$todo}'
		return 1
	fi

	# Count existing subtasks to determine next index
	# Note: grep -c exits 1 when count is 0. Placing the fallback assignment outside $()
	# makes this an || list — an excepted context for set -e — so no set -e abort occurs.
	local existing_subtask_count
	existing_subtask_count=$(grep -c "^\s*- \[.\] ${parent_task_id}\." "$todo_file" 2>/dev/null) || existing_subtask_count=0
	existing_subtask_count="${existing_subtask_count:-0}"

	local created_ids=""
	local next_index=$((existing_subtask_count + 1))

	# Find the line number of the parent task to insert subtasks after it
	local parent_line_num
	parent_line_num=$(grep -n "^\s*- \[.\] $parent_task_id " "$todo_file" | head -1 | cut -d: -f1)

	if [[ -z "$parent_line_num" ]]; then
		log_warn "create_subtasks: could not find line number for parent $parent_task_id in $todo_file"
		jq -n --arg parent "$parent_task_id" --arg todo "$todo_file" \
			'{"error":"parent_task_line_not_found","parent_task_id":$parent,"todo_file":$todo}'
		return 1
	fi

	# Build subtask lines
	local subtask_lines=""
	local j
	for ((j = 0; j < subtask_count; j++)); do
		local subtask
		subtask=$(printf '%s' "$action" | jq ".subtasks[$j]")

		local sub_title sub_tags sub_estimate sub_model
		sub_title=$(printf '%s' "$subtask" | jq -r '.title // "Untitled subtask"')
		sub_tags=$(printf '%s' "$subtask" | jq -r '(.tags // []) | join(" ")')
		sub_estimate=$(printf '%s' "$subtask" | jq -r '.estimate // "~30m"')
		sub_model=$(printf '%s' "$subtask" | jq -r '.model // "sonnet"')

		local sub_id="${parent_task_id}.${next_index}"
		local sub_line="  - [ ] $sub_id $sub_title"
		if [[ -n "$sub_tags" ]]; then
			sub_line="$sub_line $sub_tags"
		fi
		sub_line="$sub_line $sub_estimate model:$sub_model"

		subtask_lines="${subtask_lines}${sub_line}\n"
		created_ids="${created_ids}${sub_id},"
		next_index=$((next_index + 1))
	done

	# Find the insertion point: after the parent task and any existing subtasks
	local insert_after=$parent_line_num
	# Skip existing subtasks (indented lines starting with the parent ID pattern)
	local total_lines
	total_lines=$(wc -l <"$todo_file" | tr -d ' ')
	local check_line=$((parent_line_num + 1))
	while [[ $check_line -le $total_lines ]]; do
		local line_content
		line_content=$(sed -n "${check_line}p" "$todo_file")
		if [[ "$line_content" =~ ^[[:space:]]+- ]]; then
			insert_after=$check_line
			check_line=$((check_line + 1))
		else
			break
		fi
	done

	# Insert subtask lines after the insertion point
	local temp_file
	temp_file=$(mktemp)
	{
		head -n "$insert_after" "$todo_file"
		printf '%b' "$subtask_lines"
		tail -n "+$((insert_after + 1))" "$todo_file"
	} >"$temp_file"
	mv "$temp_file" "$todo_file"

	# Post-write verification: confirm each subtask ID was actually persisted (t1217)
	local missing_ids=""
	local verify_index=$((existing_subtask_count + 1))
	local k
	for ((k = 0; k < subtask_count; k++)); do
		local expected_id="${parent_task_id}.${verify_index}"
		if ! grep -q "^\s*- \[.\] ${expected_id} " "$todo_file" 2>/dev/null; then
			missing_ids="${missing_ids}${expected_id},"
		fi
		verify_index=$((verify_index + 1))
	done

	if [[ -n "$missing_ids" ]]; then
		missing_ids="${missing_ids%,}"
		log_warn "create_subtasks: post-write verification FAILED — subtask IDs not found in TODO.md: $missing_ids (parent: $parent_task_id)"
		jq -n --arg parent "$parent_task_id" --arg missing "$missing_ids" \
			'{"created":false,"error":"subtasks_not_persisted","parent_task_id":$parent,"missing_ids":$missing}'
		return 1
	fi

	# Commit and push (redirect stdout to log — git operations leak noise)
	if declare -f commit_and_push_todo &>/dev/null; then
		commit_and_push_todo "$repo_path" "chore: AI supervisor created subtasks for $parent_task_id" >>"$SUPERVISOR_LOG" 2>&1 || true
	fi

	# Remove trailing comma from created_ids
	created_ids="${created_ids%,}"

	# Post-execution verification: confirm subtasks are visible in TODO.md (t1214)
	local verified_count
	# Note: grep -c exits 1 when count is 0. Placing the fallback assignment outside $()
	# makes this an || list — an excepted context for set -e — so no set -e abort occurs.
	verified_count=$(grep -c "^[[:space:]]*- \[.\] ${parent_task_id}\." "$todo_file" 2>/dev/null) || verified_count=0
	verified_count="${verified_count:-0}"
	if [[ "$verified_count" -lt "$subtask_count" ]]; then
		jq -n --arg parent "$parent_task_id" --arg ids "$created_ids" \
			--argjson count "$subtask_count" --argjson verified "$verified_count" \
			'{"created":true,"parent_task_id":$parent,"subtask_ids":$ids,"count":$count,"verified_count":$verified,"warning":"subtask_count_mismatch"}'
		return 0
	fi

	jq -n --arg parent "$parent_task_id" --arg ids "$created_ids" \
		--argjson count "$subtask_count" --argjson verified "$verified_count" \
		'{"created":true,"parent_task_id":$parent,"subtask_ids":$ids,"count":$count,"verified_count":$verified}'
	return 0
}

#######################################
# Action: flag_for_review
# Labels an issue for human review and posts a comment explaining why
#######################################
_exec_flag_for_review() {
	local action="$1"
	local repo_slug="$2"

	local issue_number reason
	issue_number=$(printf '%s' "$action" | jq -r '.issue_number')
	reason=$(printf '%s' "$action" | jq -r '.reason')

	if [[ -z "$repo_slug" ]]; then
		echo '{"error":"no_repo_slug"}'
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		echo '{"error":"gh_cli_not_available"}'
		return 1
	fi

	# Verify issue exists
	if ! gh issue view "$issue_number" --repo "$repo_slug" --json number &>/dev/null; then
		echo "{\"error\":\"issue_not_found\",\"issue_number\":$issue_number}"
		return 1
	fi

	# Add "needs-review" label (create if it doesn't exist)
	gh label create "needs-review" --repo "$repo_slug" --description "Flagged for human review by AI supervisor" --color "D93F0B" 2>/dev/null || true
	gh issue edit "$issue_number" --repo "$repo_slug" --add-label "needs-review" 2>/dev/null || true

	# Post comment explaining why
	local comment_body
	comment_body="## Flagged for Human Review

**Reason:** $reason

This issue has been flagged by the AI supervisor for human review. Please assess and take appropriate action.

---
*Flagged by AI Supervisor (automated reasoning cycle)*"

	gh issue comment "$issue_number" --repo "$repo_slug" --body "$comment_body" &>/dev/null || true

	echo "{\"flagged\":true,\"issue_number\":$issue_number}"
	return 0
}

#######################################
# Action: adjust_priority
# Logs a priority adjustment recommendation
# NOTE: Does not reorder TODO.md (too risky for automated changes).
# Instead, posts the recommendation as a comment on the task's GitHub issue.
#######################################
_exec_adjust_priority() {
	local action="$1"
	local repo_path="$2"

	local task_id new_priority reasoning
	task_id=$(printf '%s' "$action" | jq -r '.task_id')
	new_priority=$(printf '%s' "$action" | jq -r '.new_priority // empty')
	reasoning=$(printf '%s' "$action" | jq -r '.reasoning // "No reasoning provided"')

	# Infer priority from reasoning if the AI omitted the field (common pattern —
	# the AI has omitted new_priority in 13+ actions across 5+ cycles)
	if [[ -z "$new_priority" || "$new_priority" == "null" ]]; then
		if printf '%s' "$reasoning" | grep -qi 'critical\|urgent\|blocker\|blocking'; then
			new_priority="critical"
		elif printf '%s' "$reasoning" | grep -qi 'high\|important\|prioriti'; then
			new_priority="high"
		elif printf '%s' "$reasoning" | grep -qi 'low\|minor\|defer'; then
			new_priority="low"
		else
			# Default to high — the AI is recommending a change, usually an escalation
			new_priority="high"
		fi
		log_warn "AI Actions: adjust_priority inferred new_priority='$new_priority' from reasoning (field was missing)"
	fi

	# Find the task's GitHub issue number
	local issue_number=""
	if declare -f find_task_issue_number &>/dev/null; then
		issue_number=$(find_task_issue_number "$task_id" "$repo_path" 2>/dev/null || echo "")
	fi

	local repo_slug=""
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")

	if [[ -n "$issue_number" && -n "$repo_slug" ]] && command -v gh &>/dev/null; then
		local comment_body
		comment_body="## Priority Adjustment Recommendation

**Task:** $task_id
**Recommended priority:** $new_priority
**Reasoning:** $reasoning

This is a recommendation from the AI supervisor. A human should review and decide whether to act on it.

---
*Recommended by AI Supervisor (automated reasoning cycle)*"

		gh issue comment "$issue_number" --repo "$repo_slug" --body "$comment_body" &>/dev/null || true
	fi

	# Log to DB for tracking
	db "$SUPERVISOR_DB" "
		INSERT INTO state_log (task_id, from_state, to_state, reason)
		VALUES ('$(sql_escape "$task_id")', 'priority', '$(sql_escape "$new_priority")',
				'$(sql_escape "AI priority recommendation: $reasoning")');
	" 2>/dev/null || true

	echo "{\"recommended\":true,\"task_id\":\"$task_id\",\"new_priority\":\"$new_priority\"}"
	return 0
}

#######################################
# Action: close_verified
# Closes a GitHub issue ONLY if a merged PR is verified
# This is the most safety-critical action — requires proof of merged PR
#######################################
_exec_close_verified() {
	local action="$1"
	local repo_slug="$2"

	local issue_number pr_number
	issue_number=$(printf '%s' "$action" | jq -r '.issue_number')
	pr_number=$(printf '%s' "$action" | jq -r '.pr_number')

	if [[ -z "$repo_slug" ]]; then
		echo '{"error":"no_repo_slug"}'
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		echo '{"error":"gh_cli_not_available"}'
		return 1
	fi

	# CRITICAL: Verify the PR is actually merged
	local pr_state
	pr_state=$(gh pr view "$pr_number" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null || echo "")

	if [[ "$pr_state" != "MERGED" ]]; then
		echo "{\"error\":\"pr_not_merged\",\"pr_number\":$pr_number,\"pr_state\":\"$pr_state\"}"
		return 1
	fi

	# Verify the PR has actual file changes (not empty)
	local changed_files
	changed_files=$(gh pr view "$pr_number" --repo "$repo_slug" --json changedFiles --jq '.changedFiles' 2>/dev/null || echo 0)

	if [[ "$changed_files" -eq 0 ]]; then
		echo "{\"error\":\"pr_has_no_changes\",\"pr_number\":$pr_number}"
		return 1
	fi

	# Verify the issue exists and is open
	local issue_state
	issue_state=$(gh issue view "$issue_number" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null || echo "")

	if [[ "$issue_state" != "OPEN" ]]; then
		echo "{\"error\":\"issue_not_open\",\"issue_number\":$issue_number,\"issue_state\":\"$issue_state\"}"
		return 1
	fi

	# Close with a comment explaining the verification
	local close_comment
	close_comment="## Verified Complete

This issue has been verified as complete:
- **PR:** #$pr_number (merged, $changed_files files changed)
- **Verification:** Automated check confirmed PR is merged with real deliverables

---
*Closed by AI Supervisor (automated verification)*"

	gh issue comment "$issue_number" --repo "$repo_slug" --body "$close_comment" &>/dev/null || true
	gh issue close "$issue_number" --repo "$repo_slug" --reason completed &>/dev/null || {
		echo "{\"error\":\"close_failed\",\"issue_number\":$issue_number}"
		return 1
	}

	echo "{\"closed\":true,\"issue_number\":$issue_number,\"pr_number\":$pr_number,\"changed_files\":$changed_files}"
	return 0
}

#######################################
# Action: request_info
# Posts a structured information request on a GitHub issue
#######################################
_exec_request_info() {
	local action="$1"
	local repo_slug="$2"

	local issue_number
	issue_number=$(printf '%s' "$action" | jq -r '.issue_number')

	if [[ -z "$repo_slug" ]]; then
		echo '{"error":"no_repo_slug"}'
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		echo '{"error":"gh_cli_not_available"}'
		return 1
	fi

	# Verify issue exists
	if ! gh issue view "$issue_number" --repo "$repo_slug" --json number &>/dev/null; then
		echo "{\"error\":\"issue_not_found\",\"issue_number\":$issue_number}"
		return 1
	fi

	# Build questions list
	local questions_md=""
	local q_count
	q_count=$(printf '%s' "$action" | jq '.questions | length')
	local q
	for ((q = 0; q < q_count; q++)); do
		local question
		question=$(printf '%s' "$action" | jq -r ".questions[$q]")
		questions_md="${questions_md}$((q + 1)). ${question}\n"
	done

	# Add "needs-info" label
	gh label create "needs-info" --repo "$repo_slug" --description "Additional information requested" --color "0075CA" 2>/dev/null || true
	gh issue edit "$issue_number" --repo "$repo_slug" --add-label "needs-info" 2>/dev/null || true

	local comment_body
	comment_body="## Information Requested

To make progress on this issue, we need some additional information:

$(printf '%b' "$questions_md")
Please provide the requested details so we can proceed.

---
*Requested by AI Supervisor (automated reasoning cycle)*"

	if gh issue comment "$issue_number" --repo "$repo_slug" --body "$comment_body" &>/dev/null; then
		echo "{\"requested\":true,\"issue_number\":$issue_number,\"questions\":$q_count}"
		return 0
	else
		echo "{\"error\":\"comment_failed\",\"issue_number\":$issue_number}"
		return 1
	fi
}

#######################################
# Action: create_improvement
# Creates a self-improvement task in TODO.md (like create_task but
# ensures #self-improvement tag and category metadata)
#######################################
_exec_create_improvement() {
	local action="$1"
	local repo_path="$2"

	local title description tags estimate model category
	title=$(printf '%s' "$action" | jq -r '.title')
	description=$(printf '%s' "$action" | jq -r '.description // ""')
	tags=$(printf '%s' "$action" | jq -r '(.tags // []) | join(" ")')
	estimate=$(printf '%s' "$action" | jq -r '.estimate // "~1h"')
	model=$(printf '%s' "$action" | jq -r '.model // "sonnet"')
	category=$(printf '%s' "$action" | jq -r '.category // "general"')

	# Ensure #self-improvement and #auto-dispatch tags are present
	if [[ "$tags" != *"#self-improvement"* ]]; then
		tags="$tags #self-improvement"
	fi
	if [[ "$tags" != *"#auto-dispatch"* ]]; then
		tags="$tags #auto-dispatch"
	fi

	local todo_file="$repo_path/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		echo '{"error":"todo_file_not_found"}'
		return 1
	fi

	# Semantic dedup: check if a similar open task already exists (t1218)
	local similar_task_id
	if similar_task_id=$(_check_similar_open_task "$title" "$todo_file"); then
		log_info "AI Actions: create_improvement skipped — similar open task $similar_task_id exists (t1218)"
		jq -n --arg existing "$similar_task_id" --arg title "$title" --arg category "$category" \
			'{"skipped": true, "reason": "similar_task_exists", "existing_task": $existing, "proposed_title": $title, "category": $category}'
		return 0
	fi

	# Allocate task ID via claim-task-id.sh
	local claim_script="${SCRIPT_DIR}/claim-task-id.sh"
	local task_id=""

	if [[ -x "$claim_script" ]]; then
		local claim_output
		claim_output=$("$claim_script" --title "$title" --repo-path "$repo_path" 2>/dev/null || echo "")
		task_id=$(printf '%s' "$claim_output" | grep -oE 'task_id=t[0-9]+' | head -1 | sed 's/task_id=//')
	fi

	if [[ -z "$task_id" ]]; then
		task_id="t$(date +%s | tail -c 5)"
		log_warn "AI Actions: claim-task-id.sh unavailable, using fallback ID $task_id"
	fi

	# Build the task line with category metadata
	local task_line="- [ ] $task_id $title $tags $estimate model:$model"
	if [[ -n "$category" && "$category" != "general" ]]; then
		task_line="$task_line category:$category"
	fi
	if [[ -n "$description" ]]; then
		task_line="$task_line — $description"
	fi

	printf '\n%s\n' "$task_line" >>"$todo_file"

	# Redirect stdout to log — git operations leak noise into function output
	if declare -f commit_and_push_todo &>/dev/null; then
		commit_and_push_todo "$repo_path" "chore: AI supervisor created improvement task $task_id" >>"$SUPERVISOR_LOG" 2>&1 || true
	fi

	jq -n --arg task_id "$task_id" --arg title "$title" --arg category "$category" \
		'{"created": true, "task_id": $task_id, "title": $title, "category": $category}'
	return 0
}

#######################################
# Action: escalate_model
# Updates a task's model tier in the supervisor DB and TODO.md
#######################################
_exec_escalate_model() {
	local action="$1"
	local repo_path="$2"

	local task_id from_tier to_tier reasoning
	task_id=$(printf '%s' "$action" | jq -r '.task_id')
	from_tier=$(printf '%s' "$action" | jq -r '.from_tier // "unknown"')
	to_tier=$(printf '%s' "$action" | jq -r '.to_tier')
	reasoning=$(printf '%s' "$action" | jq -r '.reasoning // ""')

	# Update model tier in supervisor DB if task exists there
	if [[ -n "$SUPERVISOR_DB" && -f "$SUPERVISOR_DB" ]]; then
		local db_task_exists
		db_task_exists=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE task_id = '$task_id';" 2>/dev/null || echo 0)
		if [[ "$db_task_exists" -gt 0 ]]; then
			db "$SUPERVISOR_DB" "UPDATE tasks SET model = '$to_tier' WHERE task_id = '$task_id';" 2>/dev/null || true
			log_info "AI Actions: escalated $task_id model in DB: $from_tier -> $to_tier"
		fi
	fi

	# Update model:X in TODO.md if present
	local todo_file="$repo_path/TODO.md"
	if [[ -f "$todo_file" ]]; then
		if grep -q "^\s*- \[.\] $task_id " "$todo_file" 2>/dev/null; then
			# Replace model:old with model:new on the task line
			if grep "^\s*- \[.\] $task_id " "$todo_file" | grep -q "model:"; then
				sed -i.bak "s/\(- \[.\] $task_id .*\)model:[a-z]*/\1model:$to_tier/" "$todo_file"
				rm -f "${todo_file}.bak"
			else
				# No model: field — append it
				sed -i.bak "s/\(- \[.\] $task_id .*\)/\1 model:$to_tier/" "$todo_file"
				rm -f "${todo_file}.bak"
			fi

			# Redirect stdout to log — git operations leak noise into function output
			if declare -f commit_and_push_todo &>/dev/null; then
				commit_and_push_todo "$repo_path" "chore: AI supervisor escalated $task_id model $from_tier -> $to_tier" >>"$SUPERVISOR_LOG" 2>&1 || true
			fi
		fi
	fi

	# Log the escalation event in state_log
	if [[ -n "$SUPERVISOR_DB" && -f "$SUPERVISOR_DB" ]]; then
		db "$SUPERVISOR_DB" "
			INSERT INTO state_log (task_id, from_state, to_state, reason)
			VALUES ('$task_id', 'model:$from_tier', 'model:$to_tier',
					'AI escalation: $reasoning');
		" 2>/dev/null || true
	fi

	echo "{\"escalated\":true,\"task_id\":\"$task_id\",\"from_tier\":\"$from_tier\",\"to_tier\":\"$to_tier\"}"
	return 0
}

#######################################
# Action: propose_auto_dispatch (t1134)
# Two-phase guard for auto-dispatch tagging:
#   Phase 1 (proposal): Adds "[proposed:auto-dispatch model:X]" annotation
#     to the task line in TODO.md. Does NOT add #auto-dispatch yet.
#   Phase 2 (confirmation): On the NEXT pulse cycle, if the [proposed:...]
#     annotation still exists (not removed by a human), converts it to
#     the actual #auto-dispatch tag + model:X field.
#
# This ensures no task is auto-tagged without at least one pulse cycle
# of visibility, giving humans a window to intervene.
#######################################
_exec_propose_auto_dispatch() {
	local action="$1"
	local repo_path="$2"

	local task_id recommended_model reasoning
	task_id=$(printf '%s' "$action" | jq -r '.task_id')
	recommended_model=$(printf '%s' "$action" | jq -r '.recommended_model // "sonnet"')
	reasoning=$(printf '%s' "$action" | jq -r '.reasoning // ""')

	# Find the correct TODO.md — search all registered repos
	local todo_file=""
	local task_repo=""

	# First check the provided repo
	if [[ -f "$repo_path/TODO.md" ]] && grep -qE "^[[:space:]]*- \[ \] ${task_id}( |$)" "$repo_path/TODO.md" 2>/dev/null; then
		todo_file="$repo_path/TODO.md"
		task_repo="$repo_path"
	fi

	# If not found, search other registered repos
	if [[ -z "$todo_file" && -f "$SUPERVISOR_DB" ]]; then
		local search_repos
		search_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks WHERE repo IS NOT NULL AND repo != '';" 2>/dev/null || echo "")
		if [[ -n "$search_repos" ]]; then
			while IFS= read -r search_repo; do
				[[ -z "$search_repo" || ! -f "$search_repo/TODO.md" ]] && continue
				if grep -qE "^[[:space:]]*- \[ \] ${task_id}( |$)" "$search_repo/TODO.md" 2>/dev/null; then
					todo_file="$search_repo/TODO.md"
					task_repo="$search_repo"
					break
				fi
			done <<<"$search_repos"
		fi
	fi

	if [[ -z "$todo_file" ]]; then
		echo "{\"error\":\"task_not_found\",\"task_id\":\"$task_id\"}"
		return 1
	fi

	# Check if task already has #auto-dispatch
	local task_line
	task_line=$(grep -E "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file" | head -1)
	if [[ -z "$task_line" ]]; then
		echo "{\"error\":\"task_not_found_in_todo\",\"task_id\":\"$task_id\"}"
		return 1
	fi

	if echo "$task_line" | grep -q '#auto-dispatch'; then
		echo "{\"skipped\":true,\"task_id\":\"$task_id\",\"reason\":\"already_tagged\"}"
		return 0
	fi

	# Check if task already has a [proposed:auto-dispatch] annotation
	if echo "$task_line" | grep -q '\[proposed:auto-dispatch'; then
		# Phase 2: Confirmation — the proposal survived one pulse cycle.
		# Convert [proposed:auto-dispatch model:X] to actual #auto-dispatch + model:X
		local proposed_model
		proposed_model=$(echo "$task_line" | grep -oE '\[proposed:auto-dispatch model:([a-z]+)\]' | grep -oE 'model:[a-z]+' | sed 's/model://')
		if [[ -z "$proposed_model" ]]; then
			proposed_model="$recommended_model"
		fi

		# Remove the [proposed:...] annotation and add #auto-dispatch + model:
		local new_line
		new_line=$(echo "$task_line" | sed -E 's/ *\[proposed:auto-dispatch[^]]*\]//')

		# Add #auto-dispatch if not present
		if ! echo "$new_line" | grep -q '#auto-dispatch'; then
			new_line="$new_line #auto-dispatch"
		fi

		# Add or update model: field
		if echo "$new_line" | grep -qE 'model:[a-z]+'; then
			new_line=$(echo "$new_line" | sed -E "s/model:[a-z]+/model:${proposed_model}/")
		else
			new_line="$new_line model:${proposed_model}"
		fi

		# Apply the change
		local escaped_old
		escaped_old=$(printf '%s\n' "$task_line" | sed 's/[[\.*^$()+?{|]/\\&/g')
		sed -i.bak "s|${escaped_old}|${new_line}|" "$todo_file"
		rm -f "${todo_file}.bak"

		# Commit and push
		if declare -f commit_and_push_todo &>/dev/null; then
			commit_and_push_todo "$task_repo" "chore: AI supervisor confirmed auto-dispatch for $task_id (model:$proposed_model, t1134)" >>"$SUPERVISOR_LOG" 2>&1 || true
		fi

		# Log the confirmation event
		if [[ -n "$SUPERVISOR_DB" && -f "$SUPERVISOR_DB" ]]; then
			db "$SUPERVISOR_DB" "
				INSERT INTO state_log (task_id, from_state, to_state, reason)
				VALUES ('$(sql_escape "$task_id")', 'proposed', 'auto-dispatch',
						'$(sql_escape "AI auto-dispatch confirmed: $reasoning")');
			" 2>/dev/null || true
		fi

		echo "{\"confirmed\":true,\"task_id\":\"$task_id\",\"model\":\"$proposed_model\",\"phase\":\"confirmation\"}"
		return 0
	fi

	# Phase 1: Proposal — add [proposed:auto-dispatch model:X] annotation
	local annotation=" [proposed:auto-dispatch model:${recommended_model}]"
	local new_line="${task_line}${annotation}"

	local escaped_old
	escaped_old=$(printf '%s\n' "$task_line" | sed 's/[[\.*^$()+?{|]/\\&/g')
	sed -i.bak "s|${escaped_old}|${new_line}|" "$todo_file"
	rm -f "${todo_file}.bak"

	# Commit and push
	if declare -f commit_and_push_todo &>/dev/null; then
		commit_and_push_todo "$task_repo" "chore: AI supervisor proposed auto-dispatch for $task_id (model:$recommended_model, t1134)" >>"$SUPERVISOR_LOG" 2>&1 || true
	fi

	# Log the proposal event
	if [[ -n "$SUPERVISOR_DB" && -f "$SUPERVISOR_DB" ]]; then
		db "$SUPERVISOR_DB" "
			INSERT INTO state_log (task_id, from_state, to_state, reason)
			VALUES ('$(sql_escape "$task_id")', 'untagged', 'proposed',
					'$(sql_escape "AI auto-dispatch proposed: model=$recommended_model, $reasoning")');
		" 2>/dev/null || true
	fi

	echo "{\"proposed\":true,\"task_id\":\"$task_id\",\"recommended_model\":\"$recommended_model\",\"phase\":\"proposal\"}"
	return 0
}

#######################################
# Run the full AI reasoning + action execution pipeline
# Convenience function that chains ai-reason.sh → ai-actions.sh
# Arguments:
#   $1 - repo path
#   $2 - (optional) mode: "full" (default), "dry-run"
# Returns:
#   0 on success, 1 on failure
#######################################
run_ai_actions_pipeline() {
	local repo_path="${1:-$REPO_PATH}"
	local mode="${2:-full}"

	# Step 1: Run reasoning to get action plan
	local action_plan
	action_plan=$(run_ai_reasoning "$repo_path" "$mode" 2>/dev/null)
	local reason_rc=$?

	if [[ $reason_rc -ne 0 ]]; then
		# Distinguish hard errors (no CLI, context failure) from soft parse failures.
		# A parse failure after retry is not actionable but should not cascade into
		# a pipeline error — return rc=0 with empty action set (t1187).
		local error_type
		error_type=$(printf '%s' "$action_plan" | jq -r '.error // ""' 2>/dev/null || echo "")
		if [[ "$error_type" == "no_action_plan" ]]; then
			log_warn "AI Actions Pipeline: reasoning parse failed — treating as empty action set (t1187)"
			echo '{"executed":0,"failed":0,"skipped":0,"actions":[]}'
			return 0
		fi
		log_warn "AI Actions Pipeline: reasoning failed (rc=$reason_rc, error=${error_type:-unknown})"
		echo '{"error":"reasoning_failed","actions":[]}'
		return 1
	fi

	# Handle empty or whitespace-only output — concurrency guard or other silent skip
	local _trimmed_plan
	_trimmed_plan=$(printf '%s' "$action_plan" | tr -d '[:space:]')
	if [[ -z "$action_plan" || -z "$_trimmed_plan" ]]; then
		log_info "AI Actions Pipeline: reasoning returned empty output (skipped)"
		echo '{"executed":0,"failed":0,"skipped":0,"actions":[]}'
		return 0
	fi

	# Check if the result is a skip/error object rather than an action array
	local plan_obj_type
	plan_obj_type=$(printf '%s' "$action_plan" | jq 'type' 2>/dev/null || echo "")
	if [[ "$plan_obj_type" == '"object"' ]]; then
		local is_skipped is_error
		is_skipped=$(printf '%s' "$action_plan" | jq 'has("skipped")' 2>/dev/null || echo "false")
		is_error=$(printf '%s' "$action_plan" | jq 'has("error")' 2>/dev/null || echo "false")
		if [[ "$is_skipped" == "true" ]]; then
			local skip_reason
			skip_reason=$(printf '%s' "$action_plan" | jq -r '.skipped // "unknown"')
			log_info "AI Actions Pipeline: reasoning skipped ($skip_reason)"
			echo '{"executed":0,"failed":0,"skipped":0,"actions":[]}'
			return 0
		fi
		if [[ "$is_error" == "true" ]]; then
			local error_msg
			error_msg=$(printf '%s' "$action_plan" | jq -r '.error // "unknown"')
			log_warn "AI Actions Pipeline: reasoning returned error: $error_msg"
			echo "$action_plan"
			return 1
		fi
	fi

	# Verify we got an array
	# t1189: If plan_type is empty (jq parse failed) or non-array, treat as warning + empty
	# plan rather than a hard error. This prevents rc=1 cascade from non-JSON AI responses.
	local plan_type
	plan_type=$(printf '%s' "$action_plan" | jq 'type' 2>/dev/null || echo "")
	if [[ "$plan_type" != '"array"' ]]; then
		# Log raw content for debugging (t1182/t1184, t1187: helps diagnose parse failures)
		local plan_len plan_head
		plan_len=$(printf '%s' "$action_plan" | wc -c | tr -d ' ')
		plan_head=$(printf '%s' "$action_plan" | head -c 200 | tr '\n' ' ')
		log_warn "AI Actions Pipeline: expected array, got ${plan_type:-<empty>} (len=${plan_len} head='${plan_head}') — treating as empty plan"
		# Write a diagnostic actions log so the failure is visible in the actions log
		# directory (not just the supervisor log). This makes it easier to correlate
		# parse failures with specific pulse cycles (t1211).
		mkdir -p "$AI_ACTIONS_LOG_DIR"
		local diag_timestamp diag_log
		diag_timestamp=$(date -u '+%Y%m%d-%H%M%S')
		diag_log="$AI_ACTIONS_LOG_DIR/actions-${diag_timestamp}-parse-failure.md"
		{
			echo "# AI Supervisor Action Execution Log — Parse Failure"
			echo ""
			echo "Timestamp: $diag_timestamp"
			echo "Status: PARSE_FAILURE — expected array, got ${plan_type:-<empty>}"
			echo "Response length: ${plan_len} bytes"
			echo ""
			echo "## Raw Response (first 500 bytes)"
			echo ""
			echo '```'
			printf '%s' "$action_plan" | head -c 500
			echo ""
			echo '```'
			echo ""
			echo "## Result"
			echo ""
			echo "Treated as empty action plan (rc=0). No actions executed."
		} >"$diag_log" 2>/dev/null || true
		log_info "AI Actions Pipeline: parse failure logged to $diag_log"
		# Return rc=0 with empty action set — a non-array response is not actionable
		# but should not cascade into a pipeline error (t1187)
		echo '{"executed":0,"failed":0,"skipped":0,"actions":[]}'
		return 0
	fi

	local plan_count
	plan_count=$(printf '%s' "$action_plan" | jq 'length' 2>/dev/null || echo 0)

	if [[ "$plan_count" -eq 0 ]]; then
		log_info "AI Actions Pipeline: no actions proposed"
		echo '{"executed":0,"failed":0,"skipped":0,"actions":[]}'
		return 0
	fi

	# Step 2: Execute the action plan
	local exec_mode="execute"
	if [[ "$mode" == "dry-run" ]]; then
		exec_mode="dry-run"
	fi

	execute_action_plan "$action_plan" "$repo_path" "$exec_mode"
	return $?
}

#######################################
# CLI entry point for standalone testing
# Usage: ai-actions.sh [--mode execute|dry-run|validate-only] [--repo /path] [--plan <json>]
#        ai-actions.sh pipeline [--mode full|dry-run] [--repo /path]
#######################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	set -euo pipefail
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	# Source dependencies
	# shellcheck source=_common.sh
	source "$SCRIPT_DIR/_common.sh"
	# shellcheck source=ai-context.sh
	source "$SCRIPT_DIR/ai-context.sh"
	# shellcheck source=ai-reason.sh
	source "$SCRIPT_DIR/ai-reason.sh"

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

	# Stub functions if not available from sourced modules
	if ! declare -f detect_repo_slug &>/dev/null; then
		detect_repo_slug() {
			local repo_path="${1:-.}"
			git -C "$repo_path" remote get-url origin 2>/dev/null |
				sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#' || echo ""
			return 0
		}
	fi

	if ! declare -f commit_and_push_todo &>/dev/null; then
		commit_and_push_todo() {
			log_warn "commit_and_push_todo stub — skipping commit"
			return 0
		}
	fi

	if ! declare -f find_task_issue_number &>/dev/null; then
		find_task_issue_number() {
			local task_id="${1:-}"
			local project_root="${2:-.}"
			local todo_file="$project_root/TODO.md"
			if [[ -f "$todo_file" ]]; then
				grep -oE "ref:GH#[0-9]+" "$todo_file" |
					head -1 | sed 's/ref:GH#//' || echo ""
			fi
			return 0
		}
	fi

	# Parse args
	mode="execute"
	repo_path="$REPO_PATH"
	plan=""
	subcommand=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		pipeline)
			subcommand="pipeline"
			shift
			;;
		dedup-stats)
			subcommand="dedup-stats"
			shift
			;;
		--mode)
			mode="$2"
			shift 2
			;;
		--repo)
			repo_path="$2"
			shift 2
			;;
		--plan)
			plan="$2"
			shift 2
			;;
		--dry-run)
			mode="dry-run"
			shift
			;;
		--help | -h)
			echo "Usage: ai-actions.sh [--mode execute|dry-run|validate-only] [--repo /path] [--plan <json>]"
			echo "       ai-actions.sh pipeline [--mode full|dry-run] [--repo /path]"
			echo "       ai-actions.sh dedup-stats"
			echo ""
			echo "Execute AI supervisor action plans."
			echo ""
			echo "Options:"
			echo "  --mode execute|dry-run|validate-only   Execution mode (default: execute)"
			echo "  --repo /path                           Repository path (default: git root)"
			echo "  --plan <json>                          JSON action plan (required unless pipeline)"
			echo "  --dry-run                              Shorthand for --mode dry-run"
			echo "  --help                                 Show this help"
			echo ""
			echo "Subcommands:"
			echo "  pipeline                               Run full reasoning + execution pipeline"
			echo "  dedup-stats                            Show action dedup statistics (t1138)"
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			exit 1
			;;
		esac
	done

	if [[ "$subcommand" == "pipeline" ]]; then
		run_ai_actions_pipeline "$repo_path" "$mode"
	elif [[ "$subcommand" == "dedup-stats" ]]; then
		# Show dedup statistics (t1138, t1179)
		if [[ ! -f "$SUPERVISOR_DB" ]]; then
			echo "No supervisor database found at $SUPERVISOR_DB" >&2
			exit 1
		fi
		has_table=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='action_dedup_log';" 2>/dev/null || echo "0")
		if [[ "$has_table" -eq 0 ]]; then
			echo "action_dedup_log table not found — run a pulse cycle first" >&2
			exit 1
		fi
		echo "=== Action Dedup Statistics (t1138, t1179 cycle-aware) ==="
		echo ""
		echo "--- Total entries ---"
		sqlite3 -column -header "$SUPERVISOR_DB" "
			SELECT status, COUNT(*) as count
			FROM action_dedup_log
			GROUP BY status
			ORDER BY count DESC;
		" 2>/dev/null || echo "(empty)"
		echo ""
		echo "--- Most suppressed targets (top 10) ---"
		sqlite3 -column -header "$SUPERVISOR_DB" "
			SELECT action_type, target, COUNT(*) as suppressed_count
			FROM action_dedup_log
			WHERE status = 'dedup_suppressed'
			GROUP BY action_type, target
			ORDER BY suppressed_count DESC
			LIMIT 10;
		" 2>/dev/null || echo "(none)"
		echo ""
		echo "--- Cycle-aware state changes (targets allowed through despite prior action) ---"
		sqlite3 -column -header "$SUPERVISOR_DB" "
			SELECT a1.target, a1.action_type,
			       a1.state_hash as prev_hash, a2.state_hash as new_hash,
			       a1.created_at as prev_action, a2.created_at as new_action
			FROM action_dedup_log a1
			JOIN action_dedup_log a2
			  ON a1.target = a2.target
			  AND a1.action_type = a2.action_type
			  AND a1.status = 'executed'
			  AND a2.status = 'executed'
			  AND a1.state_hash != ''
			  AND a2.state_hash != ''
			  AND a1.state_hash != a2.state_hash
			  AND a1.created_at < a2.created_at
			ORDER BY a2.created_at DESC
			LIMIT 10;
		" 2>/dev/null || echo "(none — cycle-aware dedup not yet active or no state changes detected)"
		echo ""
		echo "--- Recent dedup log (last 20 entries) ---"
		sqlite3 -column -header "$SUPERVISOR_DB" "
			SELECT cycle_id, action_type, target, status, state_hash, created_at
			FROM action_dedup_log
			ORDER BY created_at DESC
			LIMIT 20;
		" 2>/dev/null || echo "(empty)"
		echo ""
		echo "--- Dedup window: ${AI_ACTION_DEDUP_WINDOW:-5} cycles ---"
		echo "--- Cycle-aware dedup: ${AI_ACTION_CYCLE_AWARE_DEDUP:-true} ---"
	elif [[ -n "$plan" ]]; then
		execute_action_plan "$plan" "$repo_path" "$mode"
	else
		echo "Error: --plan <json> is required (or use 'pipeline' or 'dedup-stats' subcommand)" >&2
		exit 1
	fi
fi
