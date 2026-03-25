#!/usr/bin/env bash
# task-decompose-helper.sh - LLM-powered task classification and decomposition
# Part of the recursive task decomposition system (t1408 / p041).
#
# Classifies tasks as atomic (execute directly) or composite (split into subtasks),
# then recursively decomposes composites into 2-5 independent subtasks with
# dependency edges and lineage context.
#
# Inspired by TinyAGI/fractals — adopts the classify/decompose/lineage pattern,
# not the code. Uses haiku-tier LLM calls (~$0.001 each).
#
# Usage:
#   task-decompose-helper.sh classify <description> [--lineage <json>] [--depth N] [--task-id ID] [--todo-file PATH]
#   task-decompose-helper.sh decompose <description> [--lineage <json>] [--max-subtasks 5] [--task-id ID] [--todo-file PATH]
#   task-decompose-helper.sh format-lineage --parent <desc> --children <json> [--current N]
#   task-decompose-helper.sh format-lineage --test
#   task-decompose-helper.sh has-subtasks <task-id> [--todo-file <path>]
#   task-decompose-helper.sh help
#
# Environment:
#   ANTHROPIC_API_KEY — required for AI calls (falls back to heuristic without it)
#   DECOMPOSE_MAX_DEPTH — max recursion depth (default: 3)
#   DECOMPOSE_MAX_SUBTASKS — max subtasks per decomposition (default: 5)
#   DECOMPOSE_NO_LLM — set to "true" to force heuristic fallback (for testing)
#
# Exit codes:
#   0 - Success
#   1 - Error
#   2 - API unavailable (heuristic fallback used)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly DEFAULT_MAX_DEPTH="${DECOMPOSE_MAX_DEPTH:-3}"
readonly DEFAULT_MAX_SUBTASKS="${DECOMPOSE_MAX_SUBTASKS:-5}"
readonly AI_HELPER="${SCRIPT_DIR}/ai-research-helper.sh"
# DECOMPOSE_NO_LLM or legacy DECOMPOSE_TEST_NO_LLM disables LLM calls (for testing)
readonly NO_LLM="${DECOMPOSE_NO_LLM:-${DECOMPOSE_TEST_NO_LLM:-false}}"

#######################################
# Check if LLM calls are available and enabled
# Returns: 0 if LLM can be used, 1 if not
#######################################
llm_available() {
	if [[ "$NO_LLM" == "true" ]]; then
		return 1
	fi
	if [[ ! -x "$AI_HELPER" ]]; then
		return 1
	fi
	return 0
}

#######################################
# Check if a task already has subtasks in TODO.md (internal helper)
# Arguments:
#   $1 — task ID
#   $2 — path to TODO.md
# Output: "true" or "false" on stdout
# Returns: 0 always
#######################################
check_existing_subtasks() {
	local task_id="$1"
	local todo_file="$2"

	if [[ -z "$task_id" || ! -f "$todo_file" ]]; then
		echo "false"
		return 0
	fi

	# Escape regex metacharacters in task_id to prevent injection.
	# Pattern covers all ERE special chars including ] and {}.
	local escaped_id
	# Single quotes intentional: sed pattern must not expand
	# shellcheck disable=SC2016
	escaped_id=$(printf '%s' "$task_id" | sed 's/[][\\.^$*+?(){}|]/\\&/g')

	local parent_pattern="^- \\[[ x-]\\] ${escaped_id} "
	local child_pattern="^  - \\[[ x-]\\] ${escaped_id}\\."

	if grep -qE "$parent_pattern" "$todo_file" && grep -qE "$child_pattern" "$todo_file"; then
		echo "true"
	else
		echo "false"
	fi
	return 0
}

#######################################
# Build the LLM prompt for task classification
# Arguments:
#   $1 — task description
#   $2 — depth (integer)
#   $3 — lineage context string (may be empty)
# Output: prompt string on stdout
# Returns: 0 always
#######################################
build_classify_prompt() {
	local description="$1"
	local depth="$2"
	local lineage_context="$3"

	printf '%s' "You are classifying a software development task as either ATOMIC or COMPOSITE.

ATOMIC means: a single developer can implement this in one focused session without further planning. It has one clear deliverable — a single PR.
COMPOSITE means: this clearly contains 2 or more independent concerns that should be worked on separately by different developers in parallel.

Rules:
- When in doubt, choose ATOMIC. Over-decomposition creates more overhead (more PRs, more merge conflicts, more coordination) than under-decomposition.
- A task that is large but has a single concern (e.g., 'refactor the auth module') is ATOMIC.
- A task that lists multiple independent features (e.g., 'build login, registration, and OAuth') is COMPOSITE.
- At depth ${depth} in the hierarchy. Deeper tasks should almost always be atomic.
- If the task mentions 'and' connecting truly independent deliverables, it's likely COMPOSITE.
- Bug fixes, refactors, documentation tasks, and single-feature tasks are almost always ATOMIC.
- A task with 'with' connecting a feature and its natural sub-component (e.g., 'profile page with avatar upload') is ATOMIC — the sub-component is part of the feature, not independent.

Examples:
- 'Fix the login page redirect loop' -> ATOMIC (single bug fix)
- 'Refactor the authentication module to use JWT tokens' -> ATOMIC (single concern, even if large)
- 'Create classify/decompose LLM prompts and helper functions' -> ATOMIC (single deliverable: one script)
- 'Add CI self-healing to pulse' -> ATOMIC (single feature addition)
- 'Build auth system with login, registration, password reset, and OAuth' -> COMPOSITE (4 independent features)
- 'Recursive task decomposition with classify pipeline, lineage context, batch strategies, pulse integration' -> COMPOSITE (4 independent concerns)
- 'Build a CRM with contacts, deals, email integration, and reporting dashboard' -> COMPOSITE (4 independent modules)
- 'Create user management and billing system and notification service' -> COMPOSITE (3 independent systems)
${lineage_context}
Task description: ${description}

Respond with ONLY a JSON object (no markdown, no explanation outside the JSON):
{\"kind\": \"atomic\" or \"composite\", \"confidence\": 0.0-1.0, \"reasoning\": \"one sentence explanation\"}"
	return 0
}

#######################################
# Call the LLM for classification and return validated JSON
# Arguments:
#   $1 — prompt string
# Output: validated JSON on stdout
# Returns: 0 on success, 1 on failure
#######################################
call_classify_llm() {
	local prompt="$1"
	local raw_result
	raw_result=$("$AI_HELPER" --prompt "$prompt" --model haiku --max-tokens 200 || echo "")
	if [[ -z "$raw_result" ]]; then
		return 1
	fi
	local json_result
	json_result=$(extract_classify_json "$raw_result")
	if [[ -z "$json_result" ]]; then
		return 1
	fi
	echo "$json_result"
	return 0
}

#######################################
# Classify a task as atomic or composite using LLM judgment
#
# Arguments:
#   $1 — task description
#   --lineage JSON — ancestor chain (optional)
#   --depth N — current depth in hierarchy (default: 0)
#   --task-id ID — task ID to check for existing subtasks (optional)
#   --todo-file PATH — path to TODO.md for context (optional)
#
# Output: JSON {"kind": "atomic"|"composite", "confidence": 0-1, "reasoning": "..."}
# Exit: 0 on success, 2 if API unavailable (heuristic used)
#######################################
cmd_classify() {
	local description=""
	local lineage=""
	local depth=0
	local task_id=""
	local todo_file=""

	# First positional arg is description
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		description="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--lineage)
			lineage="$2"
			shift 2
			;;
		--depth)
			depth="$2"
			shift 2
			;;
		--task-id)
			task_id="$2"
			shift 2
			;;
		--todo-file)
			todo_file="$2"
			shift 2
			;;
		*)
			if [[ -z "$description" ]]; then description="$1"; fi
			shift
			;;
		esac
	done

	if [[ -z "$description" ]]; then
		log_error "Usage: task-decompose-helper.sh classify <description> [--lineage <json>] [--depth N] [--task-id ID] [--todo-file PATH]"
		return 1
	fi

	# Fast-path: task already has subtasks — treat as atomic for dispatch
	if [[ -n "$task_id" && -n "$todo_file" ]]; then
		local has_children
		has_children=$(check_existing_subtasks "$task_id" "$todo_file")
		if [[ "$has_children" == "true" ]]; then
			echo '{"kind": "atomic", "confidence": 1.0, "reasoning": "Task already has subtasks in TODO.md — skip re-decomposition"}'
			return 0
		fi
	fi

	# Fast-path: depth 2+ is almost certainly atomic
	if [[ "$depth" -ge 2 ]]; then
		echo '{"kind": "atomic", "confidence": 0.9, "reasoning": "Depth >= 2, biased toward atomic per decomposition rules"}'
		return 0
	fi

	# Try LLM classification
	if llm_available; then
		local lineage_context=""
		if [[ -n "$lineage" ]]; then
			lineage_context="
Lineage context (ancestor chain):
${lineage}
"
		fi
		local prompt
		prompt=$(build_classify_prompt "$description" "$depth" "$lineage_context")
		local json_result
		if json_result=$(call_classify_llm "$prompt"); then
			echo "$json_result"
			return 0
		fi
	fi

	# Heuristic fallback (subshell isolates set -e from grep non-matches inside heuristic)
	local heuristic_result
	heuristic_result=$(heuristic_classify "$description" "$depth")
	echo "$heuristic_result"
	return 2
}

#######################################
# Extract and validate classification JSON from LLM response
# Handles clean JSON, markdown-wrapped, and freeform responses.
#
# Arguments:
#   $1 — raw LLM response text
# Output: validated JSON on stdout, or empty string
#######################################
extract_classify_json() {
	local response="$1"

	# Try 1: extract JSON object containing "kind" key
	local json_result
	json_result=$(echo "$response" | sed -n 's/.*\({[^}]*"kind"[^}]*}\).*/\1/p' | head -1)

	if [[ -n "$json_result" ]]; then
		local kind
		kind=$(echo "$json_result" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
		if [[ "$kind" == "atomic" || "$kind" == "composite" ]]; then
			echo "$json_result"
			return 0
		fi
	fi

	# Try 2: extract kind from freeform response
	local lower_result
	lower_result=$(echo "$response" | tr '[:upper:]' '[:lower:]')
	if echo "$lower_result" | grep -q "composite"; then
		echo '{"kind": "composite", "confidence": 0.7, "reasoning": "LLM indicated composite (parsed from freeform response)"}'
		return 0
	elif echo "$lower_result" | grep -q "atomic"; then
		echo '{"kind": "atomic", "confidence": 0.7, "reasoning": "LLM indicated atomic (parsed from freeform response)"}'
		return 0
	fi

	# No valid classification found
	echo ""
	return 0
}

#######################################
# Heuristic classification fallback (no LLM)
# Counts signals of composite tasks: multiple "and"-connected features,
# numbered lists, semicolons separating concerns.
#
# Arguments:
#   $1 — task description
#   $2 — depth (default: 0)
# Output: JSON classification
#######################################
heuristic_classify() {
	local description="$1"
	local depth="${2:-0}"

	# At depth 2+, always atomic
	if [[ "$depth" -ge 2 ]]; then
		echo '{"kind": "atomic", "confidence": 0.9, "reasoning": "Heuristic: depth >= 2, biased toward atomic"}'
		return 0
	fi

	local composite_signals=0

	# Count "and" connecting what look like independent features
	# e.g., "login, registration, and OAuth" = 3 features
	local comma_count
	comma_count=$(echo "$description" | tr -cd ',' | wc -c | tr -d ' ')
	if [[ "$comma_count" -ge 2 ]]; then
		composite_signals=$((composite_signals + 1))
	fi

	# Comma-separated list with "and" is a strong composite signal
	# e.g., "login, registration, password reset, and OAuth"
	local and_count
	and_count=$(echo "$description" | grep -oiE '\band\b' | wc -l | tr -d ' ')
	if [[ "$comma_count" -ge 1 && "$and_count" -ge 1 ]]; then
		composite_signals=$((composite_signals + 1))
	fi

	# Check for numbered lists or bullet points
	if echo "$description" | grep -qE '(^|\s)[0-9]+\.\s|^\s*[-*]\s'; then
		composite_signals=$((composite_signals + 1))
	fi

	# Multiple "and" connecting independent concerns
	# 3+ "and"s is a very strong signal (e.g., "X and Y and Z and W")
	if [[ "$and_count" -ge 3 ]]; then
		composite_signals=$((composite_signals + 2))
	elif [[ "$and_count" -ge 2 ]]; then
		composite_signals=$((composite_signals + 1))
	fi

	# Check for explicit multi-feature keywords
	if echo "$description" | grep -qiE 'multiple|several|various|both.*and|as well as'; then
		composite_signals=$((composite_signals + 1))
	fi

	# Bug fixes, refactors, docs are almost always atomic
	if echo "$description" | grep -qiE '^(fix|bugfix|refactor|document|update|add a comment|rename|remove|delete|upgrade|bump)'; then
		composite_signals=$((composite_signals - 2))
	fi

	if [[ "$composite_signals" -ge 2 ]]; then
		echo '{"kind": "composite", "confidence": 0.5, "reasoning": "Heuristic: multiple composite signals detected (commas, ands, multi-feature keywords)"}'
	else
		echo '{"kind": "atomic", "confidence": 0.6, "reasoning": "Heuristic: few composite signals, defaulting to atomic"}'
	fi
	return 0
}

#######################################
# Build the LLM prompt for task decomposition
# Arguments:
#   $1 — task description
#   $2 — max subtasks (integer)
#   $3 — lineage context string (may be empty)
# Output: prompt string on stdout
# Returns: 0 always
#######################################
build_decompose_prompt() {
	local description="$1"
	local max_subtasks="$2"
	local lineage_context="$3"

	printf '%s' "You are decomposing a software development task into independent subtasks for parallel execution by different developers.

Rules:
- Break into the MINIMUM number of subtasks (2-${max_subtasks}). Never pad with unnecessary tasks. Fewer subtasks = less coordination overhead.
- Each subtask must be real, distinct work that a developer would naturally treat as a separate unit — a separate PR.
- Each subtask should be independently implementable (can be assigned to a different developer working in parallel).
- Include dependency edges: if subtask B needs subtask A's output, note it in blocked_by.
- Use the blocked_by array to express dependencies (0-indexed subtask numbers).
- Suggest a batch strategy: 'depth-first' if subtasks have sequential dependencies, 'breadth-first' if mostly independent.
- Each subtask description should be specific enough to be a standalone task brief — not vague like 'handle edge cases'.

Examples:

Task: 'Build auth system with login, registration, password reset, and OAuth'
Result: 4 subtasks (login, registration, password reset, OAuth) — all independent, breadth-first.

Task: 'Build a REST API with database schema, then create frontend that calls the API, then add end-to-end tests'
Result: 3 subtasks (API+schema, frontend, e2e tests) — sequential dependencies, depth-first.
  - Frontend blocked_by API (needs endpoints to call)
  - E2E tests blocked_by both (needs working system)

Task: 'Recursive task decomposition with classify pipeline, lineage context, batch strategies, pulse integration'
Result: 4-5 subtasks — classify/decompose helper, dispatch integration, lineage context, batch strategies, testing.
  - Integration blocked_by helper (needs classify/decompose to exist)
  - Testing blocked_by all implementation subtasks
${lineage_context}
Task to decompose: ${description}

Respond with ONLY a JSON object (no markdown, no explanation outside the JSON):
{
  \"subtasks\": [
    {\"description\": \"subtask description\", \"blocked_by\": []},
    {\"description\": \"subtask description\", \"blocked_by\": [0]}
  ],
  \"strategy\": \"depth-first\" or \"breadth-first\"
}"
	return 0
}

#######################################
# Call the LLM for decomposition and return validated JSON
# Arguments:
#   $1 — prompt string
#   $2 — max subtasks (for validation)
# Output: validated JSON on stdout
# Returns: 0 on success, 1 on failure
#######################################
call_decompose_llm() {
	local prompt="$1"
	local max_subtasks="$2"
	local raw_result
	raw_result=$("$AI_HELPER" --prompt "$prompt" --model haiku --max-tokens 600 || echo "")
	if [[ -z "$raw_result" ]]; then
		return 1
	fi
	local json_result
	json_result=$(extract_decompose_json "$raw_result" "$max_subtasks")
	if [[ -z "$json_result" ]]; then
		return 1
	fi
	echo "$json_result"
	return 0
}

#######################################
# Decompose a composite task into subtasks using LLM
#
# Arguments:
#   $1 — task description
#   --lineage JSON — ancestor chain (optional)
#   --max-subtasks N — max subtasks (default: 5)
#   --task-id ID — task ID to check for existing subtasks (optional)
#   --todo-file PATH — path to TODO.md for context (optional)
#
# Output: JSON {"subtasks": [{"description": "...", "blocked_by": []}], "strategy": "depth-first"|"breadth-first"}
# Exit: 0 on success, 1 on error, 2 if API unavailable
#######################################
cmd_decompose() {
	local description=""
	local lineage=""
	local max_subtasks="$DEFAULT_MAX_SUBTASKS"
	local task_id=""
	local todo_file=""

	# First positional arg is description
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		description="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--lineage)
			lineage="$2"
			shift 2
			;;
		--max-subtasks)
			max_subtasks="$2"
			shift 2
			;;
		--task-id)
			task_id="$2"
			shift 2
			;;
		--todo-file)
			todo_file="$2"
			shift 2
			;;
		*)
			if [[ -z "$description" ]]; then description="$1"; fi
			shift
			;;
		esac
	done

	if [[ -z "$description" ]]; then
		log_error "Usage: task-decompose-helper.sh decompose <description> [--lineage <json>] [--max-subtasks N] [--task-id ID] [--todo-file PATH]"
		return 1
	fi

	# Guard: refuse to re-decompose a task that already has subtasks
	if [[ -n "$task_id" && -n "$todo_file" ]]; then
		local has_children
		has_children=$(check_existing_subtasks "$task_id" "$todo_file")
		if [[ "$has_children" == "true" ]]; then
			log_error "Task ${task_id} already has subtasks in TODO.md — skipping re-decomposition"
			return 1
		fi
	fi

	# Try LLM decomposition
	if llm_available; then
		local lineage_context=""
		if [[ -n "$lineage" ]]; then
			lineage_context="
Lineage context (what this task is part of):
${lineage}
"
		fi
		local prompt
		prompt=$(build_decompose_prompt "$description" "$max_subtasks" "$lineage_context")
		local json_result
		if json_result=$(call_decompose_llm "$prompt" "$max_subtasks"); then
			echo "$json_result"
			return 0
		fi
	fi

	# Heuristic fallback (subshell isolates set -e from grep non-matches inside heuristic)
	local heuristic_result
	heuristic_result=$(heuristic_decompose "$description" "$max_subtasks")
	echo "$heuristic_result"
	return 2
}

#######################################
# Extract and validate decomposition JSON from LLM response
# Handles clean JSON, markdown-wrapped, and brace-extracted responses.
#
# Arguments:
#   $1 — raw LLM response text
#   $2 — max subtasks allowed
# Output: validated JSON on stdout, or empty string
#######################################
extract_decompose_json() {
	local response="$1"
	local max_subtasks="${2:-5}"
	local json_result=""

	if ! command -v jq &>/dev/null; then
		echo ""
		return 0
	fi

	# Try 1: parse whole response as JSON
	json_result=$(echo "$response" | jq -c 'select(.subtasks)' 2>/dev/null || echo "")

	# Try 2: extract from markdown code block
	if [[ -z "$json_result" ]]; then
		local fence='```'
		json_result=$(echo "$response" | sed -n "/^${fence}/,/^${fence}/p" | sed '1d;$d' | jq -c 'select(.subtasks)' 2>/dev/null || echo "")
	fi

	# Try 3: find outermost JSON object with python3
	if [[ -z "$json_result" ]] && command -v python3 &>/dev/null; then
		json_result=$(echo "$response" | python3 -c "
import sys, json, re
text = sys.stdin.read()
match = re.search(r'\{.*\}', text, re.DOTALL)
if match:
    try:
        obj = json.loads(match.group())
        if 'subtasks' in obj:
            print(json.dumps(obj))
    except json.JSONDecodeError:
        pass
" 2>/dev/null || echo "")
	fi

	# Validate subtask count
	if [[ -n "$json_result" ]]; then
		local count
		count=$(echo "$json_result" | jq '.subtasks | length' 2>/dev/null || echo "0")
		if [[ "$count" -ge 2 && "$count" -le "$max_subtasks" ]]; then
			echo "$json_result"
			return 0
		fi
	fi

	echo ""
	return 0
}

#######################################
# Heuristic decomposition fallback (no LLM)
# Splits on "and", commas, or numbered items.
#
# Arguments:
#   $1 — task description
#   $2 — max subtasks
# Output: JSON decomposition
#######################################
heuristic_decompose() {
	local description="$1"
	local max_subtasks="${2:-5}"

	# Try to split on common patterns
	local subtasks=()

	# Pattern 1: "X, Y, and Z" or "X, Y, Z"
	# Remove the main verb/prefix to get the list items
	local items_text
	items_text=$(echo "$description" | sed -E 's/^(build|create|implement|add|develop|set up|configure)[[:space:]]+//i')

	# Split on ", and " or ", " or " and "
	while IFS= read -r item; do
		item=$(echo "$item" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
		if [[ -n "$item" ]]; then
			subtasks+=("$item")
		fi
	done < <(echo "$items_text" | sed 's/,\s*and\s*/\n/g; s/,\s*/\n/g; s/\s+and\s+/\n/g')

	# If we got fewer than 2 items, create a generic split
	if [[ ${#subtasks[@]} -lt 2 ]]; then
		subtasks=("Implement core functionality for: ${description}" "Add tests and documentation for: ${description}")
	fi

	# Cap at max_subtasks
	if [[ ${#subtasks[@]} -gt "$max_subtasks" ]]; then
		subtasks=("${subtasks[@]:0:$max_subtasks}")
	fi

	# Build JSON output
	local json_output='{"subtasks": ['
	local first=true
	for st in "${subtasks[@]}"; do
		if [[ "$first" == true ]]; then
			first=false
		else
			json_output="${json_output},"
		fi
		# Escape description for JSON
		local escaped_st
		escaped_st=$(printf '%s' "$st" | sed 's/\\/\\\\/g; s/"/\\"/g')
		json_output="${json_output}{\"description\": \"${escaped_st}\", \"blocked_by\": []}"
	done
	json_output="${json_output}], \"strategy\": \"breadth-first\"}"

	echo "$json_output"
	return 0
}

#######################################
# Format lineage context for worker prompts
# Produces an indented hierarchy showing the current task's position
# among its parent and siblings.
#
# Arguments:
#   --parent DESC — parent task description
#   --children JSON — array of child descriptions [{"description": "..."}]
#   --current N — 0-indexed position of current task among children
#   --test — run self-test with sample data
#
# Output: formatted lineage text block
#######################################
cmd_format_lineage() {
	local parent=""
	local children=""
	local current=-1
	local run_test=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--parent)
			parent="$2"
			shift 2
			;;
		--children)
			children="$2"
			shift 2
			;;
		--current)
			current="$2"
			shift 2
			;;
		--test)
			run_test=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ "$run_test" == true ]]; then
		format_lineage_self_test
		return $?
	fi

	if [[ -z "$parent" || -z "$children" ]]; then
		log_error "Usage: task-decompose-helper.sh format-lineage --parent <desc> --children <json> [--current N]"
		return 1
	fi

	format_lineage_block "$parent" "$children" "$current"
	return 0
}

#######################################
# Internal: produce the lineage text block
# Arguments:
#   $1 — parent description
#   $2 — children JSON array
#   $3 — current child index (0-based, -1 if none)
# Output: formatted text on stdout
#######################################
format_lineage_block() {
	local parent="$1"
	local children_json="$2"
	local current_idx="${3:--1}"

	echo "PROJECT CONTEXT:"
	echo "0. ${parent}"

	if ! command -v jq &>/dev/null; then
		log_error "jq required for lineage formatting"
		return 1
	fi

	local count
	count=$(echo "$children_json" | jq 'length' 2>/dev/null || echo "0")

	local i=0
	while [[ "$i" -lt "$count" ]]; do
		local desc
		desc=$(echo "$children_json" | jq -r "if .[$i] | type == \"object\" then .[$i].description else .[$i] end" 2>/dev/null || echo "subtask $((i + 1))")
		if [[ "$i" -eq "$current_idx" ]]; then
			echo "  $((i + 1)). ${desc}  <-- (this task)"
		else
			echo "  $((i + 1)). ${desc}"
		fi
		i=$((i + 1))
	done

	echo ""
	echo "You are one of several agents working in parallel on sibling tasks under the same parent."
	echo "Do not duplicate work that sibling tasks would handle -- focus only on your specific task."
	echo "If this task depends on interfaces/types from sibling tasks, define reasonable stubs."

	return 0
}

#######################################
# Self-test for format-lineage
# Verifies output structure with known inputs
# Returns: 0 if all checks pass, 1 if any fail
#######################################
format_lineage_self_test() {
	local parent="Build a CRM with contacts, deals, and email"
	local children='[{"description": "Implement contact management module"}, {"description": "Implement deal pipeline module"}, {"description": "Implement email integration module"}]'
	local current=1

	local output
	output=$(format_lineage_block "$parent" "$children" "$current")

	local pass=true

	# Check parent line
	if ! echo "$output" | grep -q "^0\. Build a CRM"; then
		log_error "Self-test FAIL: missing parent line"
		pass=false
	fi

	# Check current task marker
	if ! echo "$output" | grep -q "<-- (this task)"; then
		log_error "Self-test FAIL: missing current task marker"
		pass=false
	fi

	# Check marker is on correct task
	if ! echo "$output" | grep -q "deal pipeline.*<-- (this task)"; then
		log_error "Self-test FAIL: marker on wrong task"
		pass=false
	fi

	# Check sibling context message
	if ! echo "$output" | grep -q "sibling tasks"; then
		log_error "Self-test FAIL: missing sibling context message"
		pass=false
	fi

	# Check all children present
	if ! echo "$output" | grep -q "contact management"; then
		log_error "Self-test FAIL: missing child 1"
		pass=false
	fi
	if ! echo "$output" | grep -q "email integration"; then
		log_error "Self-test FAIL: missing child 3"
		pass=false
	fi

	if [[ "$pass" == true ]]; then
		echo "PASS: format-lineage self-test"
		return 0
	else
		echo "FAIL: format-lineage self-test"
		return 1
	fi
}

#######################################
# Check if a task already has subtasks in TODO.md
# Prevents re-decomposition of manually decomposed tasks.
#
# Arguments:
#   $1 — task ID (e.g., "t1408")
#   --todo-file PATH — path to TODO.md (default: ./TODO.md)
#
# Output: "true" or "false"
# Exit: 0 always
#######################################
cmd_has_subtasks() {
	local task_id=""
	local todo_file="./TODO.md"

	# First positional arg is task ID
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--todo-file)
			todo_file="$2"
			shift 2
			;;
		*)
			if [[ -z "$task_id" ]]; then
				task_id="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$task_id" ]]; then
		log_error "Usage: task-decompose-helper.sh has-subtasks <task-id> [--todo-file <path>]"
		return 1
	fi

	check_existing_subtasks "$task_id" "$todo_file"
	return 0
}

#######################################
# Help
#######################################
cmd_help() {
	cat <<'HELP'
task-decompose-helper.sh - LLM-powered task classification and decomposition

Classifies tasks as atomic (execute directly) or composite (split into subtasks),
then decomposes composites into 2-5 independent subtasks with dependency edges.
Part of the recursive task decomposition system (t1408 / p041).

Commands:
  classify <desc>       Classify task as atomic or composite
  decompose <desc>      Decompose composite task into subtasks
  format-lineage        Format lineage context for worker prompts
  has-subtasks <id>     Check if task already has subtasks in TODO.md
  help                  Show this help

Options:
  --lineage <json>      Ancestor chain context (for classify/decompose)
  --depth N             Current depth in hierarchy (for classify, default: 0)
  --max-subtasks N      Max subtasks per decomposition (default: 5)
  --task-id ID          Task ID to check for existing subtasks (for classify/decompose)
  --todo-file <path>    Path to TODO.md (for classify/decompose/has-subtasks)
  --parent <desc>       Parent task description (for format-lineage)
  --children <json>     Child task descriptions JSON array (for format-lineage)
  --current N           Current task index, 0-based (for format-lineage)
  --test                Run self-test (for format-lineage)

Environment:
  ANTHROPIC_API_KEY         Required for LLM calls (falls back to heuristics)
  DECOMPOSE_MAX_DEPTH       Max recursion depth (default: 3)
  DECOMPOSE_MAX_SUBTASKS    Max subtasks per level (default: 5)
  DECOMPOSE_NO_LLM          Set to "true" to force heuristic fallback (testing)

Examples:
  # Classify a task
  task-decompose-helper.sh classify "Add a comment to the calculateTotal function"
  # Output: {"kind": "atomic", "confidence": 0.9, ...}

  # Classify with TODO.md context (skips already-decomposed tasks)
  task-decompose-helper.sh classify "Build CRM" --task-id t1408 --todo-file ./TODO.md

  # Classify with lineage context
  task-decompose-helper.sh classify "Implement deal pipeline" --lineage '{"parent": "Build CRM"}'

  # Decompose a composite task
  task-decompose-helper.sh decompose "Build auth with login, registration, password reset, and OAuth"
  # Output: {"subtasks": [...], "strategy": "depth-first"}

  # Decompose with guard against re-decomposition
  task-decompose-helper.sh decompose "Build CRM" --task-id t1408 --todo-file ./TODO.md

  # Format lineage for a worker
  task-decompose-helper.sh format-lineage \
    --parent "Build a CRM" \
    --children '[{"description": "contacts"}, {"description": "deals"}]' \
    --current 1

  # Check if task already decomposed
  task-decompose-helper.sh has-subtasks t1408

  # Run lineage self-test
  task-decompose-helper.sh format-lineage --test

Cost: ~$0.001 per haiku classify/decompose call.
HELP
	return 0
}

#######################################
# Main dispatch
#######################################
main() {
	if [[ $# -eq 0 ]]; then
		cmd_help
		return 0
	fi

	local command="$1"
	shift

	case "$command" in
	classify) cmd_classify "$@" ;;
	decompose) cmd_decompose "$@" ;;
	format-lineage) cmd_format_lineage "$@" ;;
	has-subtasks) cmd_has_subtasks "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

# Only run main if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
