#!/usr/bin/env bash
# batch-strategy-helper.sh - Batch execution strategies for task decomposition dispatch
#
# Implements depth-first and breadth-first batch ordering for dispatching
# decomposed subtasks. Integrates with existing pulse concurrency controls
# (MAX_WORKERS, quality-debt cap, PULSE_SCOPE_REPOS).
#
# Part of the recursive task decomposition pipeline (t1408 / p041).
#
# Usage:
#   batch-strategy-helper.sh order --strategy <depth-first|breadth-first> --tasks <json>
#   batch-strategy-helper.sh next-batch --strategy <depth-first|breadth-first> --tasks <json> --concurrency <N>
#   batch-strategy-helper.sh validate --tasks <json>
#   batch-strategy-helper.sh help
#
# Input format (--tasks JSON):
#   Array of task objects with fields:
#     id:         Task ID (e.g., "t1408.1")
#     parent_id:  Parent task ID (e.g., "t1408") — defines the branch
#     status:     "pending" | "in_progress" | "completed" | "blocked"
#     blocked_by: Array of task IDs this task depends on (optional)
#     depth:      Nesting depth (0 = root, 1 = child, 2 = grandchild)
#
# Output format:
#   order:      JSON array of batches, each batch is an array of task IDs
#   next-batch: JSON array of task IDs ready for immediate dispatch
#   validate:   JSON object with validation results
#
# Exit codes:
#   0 - Success
#   1 - Error (invalid input, missing dependencies)
#   2 - No tasks ready for dispatch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

LOG_PREFIX="BATCH"

# Default configuration
readonly DEFAULT_STRATEGY="depth-first"
readonly DEFAULT_CONCURRENCY=4
readonly MAX_BATCH_SIZE=8

#######################################
# Show help text
#######################################
show_help() {
	cat <<'HELP'
batch-strategy-helper.sh - Batch execution strategies for decomposed tasks

COMMANDS:
  order         Generate full batch ordering for all pending tasks
  next-batch    Get the next batch of tasks ready for dispatch
  validate      Validate task dependency graph (detect cycles, missing deps)
  help          Show this help text

OPTIONS:
  --strategy <depth-first|breadth-first>
                Batch ordering strategy (default: depth-first)
  --tasks <json>
                JSON array of task objects (required for order/next-batch/validate)
  --tasks-file <path>
                Read tasks JSON from file instead of argument
  --concurrency <N>
                Max tasks per batch (default: 4, max: 8)

STRATEGIES:
  depth-first (default)
    Complete all leaves under one branch before starting the next.
    Tasks within each branch run concurrently up to the concurrency limit.
    Good for dependent work where branch B builds on branch A's output.

    Example (3 branches, concurrency=2):
      Batch 1: [t1.1, t1.2]    (branch 1, first 2 leaves)
      Batch 2: [t1.3]          (branch 1, remaining leaf)
      Batch 3: [t2.1, t2.2]    (branch 2, first 2 leaves)
      Batch 4: [t3.1, t3.2]    (branch 3, first 2 leaves)

  breadth-first
    One task from each branch per batch, spreading progress evenly.
    Good for independent work where all branches can proceed in parallel.

    Example (3 branches, concurrency=3):
      Batch 1: [t1.1, t2.1, t3.1]    (one from each branch)
      Batch 2: [t1.2, t2.2, t3.2]    (next from each branch)
      Batch 3: [t1.3, t2.3, t3.3]    (remaining from each branch)

EXAMPLES:
  # Get full batch ordering
  batch-strategy-helper.sh order --strategy depth-first --tasks '[
    {"id":"t1.1","parent_id":"t1","status":"pending","depth":1},
    {"id":"t1.2","parent_id":"t1","status":"pending","depth":1},
    {"id":"t2.1","parent_id":"t2","status":"pending","depth":1}
  ]'

  # Get next dispatchable batch
  batch-strategy-helper.sh next-batch --strategy breadth-first \
    --tasks-file /tmp/subtasks.json --concurrency 3

  # Validate dependency graph
  batch-strategy-helper.sh validate --tasks-file /tmp/subtasks.json
HELP
	return 0
}

#######################################
# Parse command-line arguments
# Sets global variables: COMMAND, STRATEGY, TASKS_JSON, CONCURRENCY
#######################################
parse_args() {
	COMMAND=""
	STRATEGY="$DEFAULT_STRATEGY"
	TASKS_JSON=""
	CONCURRENCY="$DEFAULT_CONCURRENCY"

	if [[ $# -eq 0 ]]; then
		show_help
		return 1
	fi

	COMMAND="$1"
	shift

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--strategy)
			STRATEGY="${2:-}"
			shift 2
			;;
		--tasks)
			TASKS_JSON="${2:-}"
			shift 2
			;;
		--tasks-file)
			local tasks_file="${2:-}"
			if [[ -z "$tasks_file" || ! -f "$tasks_file" ]]; then
				log_error "Tasks file not found: ${tasks_file:-<empty>}"
				return 1
			fi
			TASKS_JSON=$(cat "$tasks_file")
			shift 2
			;;
		--concurrency)
			CONCURRENCY="${2:-$DEFAULT_CONCURRENCY}"
			shift 2
			;;
		--help | -h)
			show_help
			return 0
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Validate strategy
	case "$STRATEGY" in
	depth-first | breadth-first) ;;
	*)
		log_error "Invalid strategy: $STRATEGY (must be depth-first or breadth-first)"
		return 1
		;;
	esac

	# Validate concurrency is numeric and within bounds
	if ! [[ "$CONCURRENCY" =~ ^[0-9]+$ ]]; then
		log_warn "Invalid concurrency '$CONCURRENCY', using default $DEFAULT_CONCURRENCY"
		CONCURRENCY="$DEFAULT_CONCURRENCY"
	fi
	if [[ "$CONCURRENCY" -gt "$MAX_BATCH_SIZE" ]]; then
		log_warn "Concurrency $CONCURRENCY exceeds max $MAX_BATCH_SIZE, capping"
		CONCURRENCY="$MAX_BATCH_SIZE"
	fi
	if [[ "$CONCURRENCY" -lt 1 ]]; then
		CONCURRENCY=1
	fi

	# Validate tasks JSON is present for commands that need it
	case "$COMMAND" in
	order | next-batch | validate)
		if [[ -z "$TASKS_JSON" ]]; then
			log_error "Tasks JSON is required for '$COMMAND' command (use --tasks or --tasks-file)"
			return 1
		fi
		# Validate it's valid JSON
		if ! echo "$TASKS_JSON" | jq empty 2>/dev/null; then
			log_error "Invalid JSON in tasks input"
			return 1
		fi
		;;
	esac

	return 0
}

#######################################
# Check if a task's blockers are all resolved
# Arguments:
#   $1 - task JSON object (single task)
#   $2 - full tasks JSON array
# Returns: 0 if all blockers resolved, 1 if still blocked
#######################################
is_task_unblocked() {
	local task="$1"
	local all_tasks="$2"

	local blocked_by
	blocked_by=$(echo "$task" | jq -r '.blocked_by // [] | .[]' 2>/dev/null)

	if [[ -z "$blocked_by" ]]; then
		return 0
	fi

	local blocker_id
	while IFS= read -r blocker_id; do
		[[ -z "$blocker_id" ]] && continue
		local blocker_status
		blocker_status=$(echo "$all_tasks" | jq -r --arg id "$blocker_id" \
			'.[] | select(.id == $id) | .status' 2>/dev/null)

		if [[ "$blocker_status" != "completed" ]]; then
			return 1
		fi
	done <<<"$blocked_by"

	return 0
}

#######################################
# Get dispatchable tasks (pending + unblocked)
# Arguments:
#   $1 - tasks JSON array
# Output: JSON array of dispatchable task objects
#######################################
get_dispatchable_tasks() {
	local all_tasks="$1"

	# Filter to pending tasks first
	local pending_tasks
	pending_tasks=$(echo "$all_tasks" | jq '[.[] | select(.status == "pending")]')

	local result="[]"
	local task_count
	task_count=$(echo "$pending_tasks" | jq 'length')

	local i=0
	while [[ $i -lt "$task_count" ]]; do
		local task
		task=$(echo "$pending_tasks" | jq ".[$i]")

		if is_task_unblocked "$task" "$all_tasks"; then
			result=$(echo "$result" | jq --argjson task "$task" '. + [$task]')
		fi

		i=$((i + 1))
	done

	echo "$result"
	return 0
}

#######################################
# Group tasks by parent (branch)
# Arguments:
#   $1 - tasks JSON array
# Output: JSON object mapping parent_id -> array of task objects
#######################################
group_by_parent() {
	local tasks="$1"

	echo "$tasks" | jq '
		group_by(.parent_id)
		| map({key: .[0].parent_id, value: .})
		| from_entries
	'
	return 0
}

#######################################
# Generate depth-first batch ordering
#
# Complete all leaves under one branch before starting the next.
# Within each branch, tasks are dispatched concurrently up to the
# concurrency limit.
#
# Arguments:
#   $1 - dispatchable tasks JSON array
#   $2 - concurrency limit
# Output: JSON array of batches (each batch is array of task IDs)
#######################################
order_depth_first() {
	local tasks="$1"
	local concurrency="$2"

	local grouped
	grouped=$(group_by_parent "$tasks")

	# Get sorted branch keys (parent IDs) for deterministic ordering
	local branches
	branches=$(echo "$grouped" | jq -r 'keys | sort | .[]')

	local batches="[]"

	local branch
	while IFS= read -r branch; do
		[[ -z "$branch" ]] && continue

		# Get task IDs for this branch, sorted by ID for deterministic order
		local branch_task_ids
		branch_task_ids=$(echo "$grouped" | jq -r --arg b "$branch" \
			'.[$b] | sort_by(.id) | .[].id')

		# Split into batches of $concurrency size
		local batch="[]"
		local batch_count=0

		local task_id
		while IFS= read -r task_id; do
			[[ -z "$task_id" ]] && continue

			batch=$(echo "$batch" | jq --arg id "$task_id" '. + [$id]')
			batch_count=$((batch_count + 1))

			if [[ "$batch_count" -ge "$concurrency" ]]; then
				batches=$(echo "$batches" | jq --argjson b "$batch" '. + [$b]')
				batch="[]"
				batch_count=0
			fi
		done <<<"$branch_task_ids"

		# Add remaining tasks in the last partial batch
		if [[ "$batch_count" -gt 0 ]]; then
			batches=$(echo "$batches" | jq --argjson b "$batch" '. + [$b]')
		fi
	done <<<"$branches"

	echo "$batches"
	return 0
}

#######################################
# Generate breadth-first batch ordering
#
# One task from each branch per batch, spreading progress evenly.
# Each batch contains at most one task per branch, up to the
# concurrency limit.
#
# Uses jq for all state management to avoid bash 3.2 associative
# array incompatibility on macOS.
#
# Arguments:
#   $1 - dispatchable tasks JSON array
#   $2 - concurrency limit
# Output: JSON array of batches (each batch is array of task IDs)
#######################################
order_breadth_first() {
	local tasks="$1"
	local concurrency="$2"

	# Use jq to do the entire breadth-first ordering in one pass.
	# This avoids bash associative arrays (not available in bash 3.2/macOS)
	# and is more efficient than shell loops for JSON manipulation.
	echo "$tasks" | jq --argjson c "$concurrency" '
		# Group by parent_id, sort each group by id
		group_by(.parent_id)
		| map(sort_by(.id) | [.[].id])
		| . as $branches
		|
		# Find the maximum branch length
		([.[] | length] | max // 0) as $max_len
		|
		# Build batches: for each "round", take one task from each branch
		[range($max_len)] | map(. as $round |
			[$branches[] | if length > $round then .[$round] else empty end]
		)
		|
		# Flatten into concurrency-limited batches
		# Each round may have more tasks than concurrency allows
		reduce .[] as $round_tasks ([];
			if ($round_tasks | length) <= $c then
				. + [$round_tasks]
			else
				# Split oversized rounds into concurrency-sized chunks
				. + [
					$round_tasks
					| [range(0; length; $c)]
					| map($round_tasks[.:(.+$c)])
				] | flatten(1)
			end
		)
		|
		# Remove empty batches
		map(select(length > 0))
	'
	return 0
}

#######################################
# Command: order
# Generate full batch ordering for all dispatchable tasks
#######################################
cmd_order() {
	local dispatchable
	dispatchable=$(get_dispatchable_tasks "$TASKS_JSON")

	local task_count
	task_count=$(echo "$dispatchable" | jq 'length')

	if [[ "$task_count" -eq 0 ]]; then
		log_info "No dispatchable tasks found"
		echo "[]"
		return 2
	fi

	local batches
	case "$STRATEGY" in
	depth-first)
		batches=$(order_depth_first "$dispatchable" "$CONCURRENCY")
		;;
	breadth-first)
		batches=$(order_breadth_first "$dispatchable" "$CONCURRENCY")
		;;
	esac

	local batch_count
	batch_count=$(echo "$batches" | jq 'length')
	log_info "Strategy: $STRATEGY | Tasks: $task_count | Batches: $batch_count | Concurrency: $CONCURRENCY"

	echo "$batches" | jq '.'
	return 0
}

#######################################
# Command: next-batch
# Get the next batch of tasks ready for immediate dispatch
#######################################
cmd_next_batch() {
	local dispatchable
	dispatchable=$(get_dispatchable_tasks "$TASKS_JSON")

	local task_count
	task_count=$(echo "$dispatchable" | jq 'length')

	if [[ "$task_count" -eq 0 ]]; then
		log_info "No tasks ready for dispatch"
		echo "[]"
		return 2
	fi

	local batches
	case "$STRATEGY" in
	depth-first)
		batches=$(order_depth_first "$dispatchable" "$CONCURRENCY")
		;;
	breadth-first)
		batches=$(order_breadth_first "$dispatchable" "$CONCURRENCY")
		;;
	esac

	# Return only the first batch
	local first_batch
	first_batch=$(echo "$batches" | jq '.[0] // []')

	local batch_size
	batch_size=$(echo "$first_batch" | jq 'length')
	log_info "Next batch ($STRATEGY): $batch_size task(s) ready"

	echo "$first_batch" | jq '.'
	return 0
}

#######################################
# Command: validate
# Validate task dependency graph
#######################################
cmd_validate() {
	local result
	result=$(jq -n '{valid: true, errors: [], warnings: []}')

	local task_count
	task_count=$(echo "$TASKS_JSON" | jq 'length')

	# Check 1: All task IDs are unique
	local unique_count
	unique_count=$(echo "$TASKS_JSON" | jq '[.[].id] | unique | length')
	if [[ "$unique_count" -ne "$task_count" ]]; then
		result=$(echo "$result" | jq '.valid = false | .errors += ["Duplicate task IDs found"]')
	fi

	# Check 2: All blocked_by references point to existing tasks
	local all_ids
	all_ids=$(echo "$TASKS_JSON" | jq -r '.[].id')

	local all_blockers
	all_blockers=$(echo "$TASKS_JSON" | jq -r '.[].blocked_by // [] | .[]' 2>/dev/null | sort -u)

	local blocker_id
	while IFS= read -r blocker_id; do
		[[ -z "$blocker_id" ]] && continue
		if ! echo "$all_ids" | grep -qx "$blocker_id"; then
			result=$(echo "$result" | jq --arg id "$blocker_id" \
				'.valid = false | .errors += ["blocked_by references non-existent task: \($id)"]')
		fi
	done <<<"$all_blockers"

	# Check 3: Detect circular dependencies (simple DFS)
	local has_cycle=false
	local task_id
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		local visited="$task_id"
		local current="$task_id"
		local depth=0

		while [[ $depth -lt 20 ]]; do
			local deps
			deps=$(echo "$TASKS_JSON" | jq -r --arg id "$current" \
				'.[] | select(.id == $id) | .blocked_by // [] | .[]' 2>/dev/null)

			if [[ -z "$deps" ]]; then
				break
			fi

			local dep
			while IFS= read -r dep; do
				[[ -z "$dep" ]] && continue
				if echo "$visited" | grep -qx "$dep"; then
					has_cycle=true
					result=$(echo "$result" | jq --arg id "$task_id" --arg dep "$dep" \
						'.valid = false | .errors += ["Circular dependency detected: \($id) -> ... -> \($dep)"]')
					break 2
				fi
				visited="${visited}"$'\n'"${dep}"
				current="$dep"
			done <<<"$deps"

			depth=$((depth + 1))
		done
	done <<<"$all_ids"

	# Check 4: Warn about tasks with no parent_id
	local orphan_count
	orphan_count=$(echo "$TASKS_JSON" | jq '[.[] | select(.parent_id == null or .parent_id == "")] | length')
	if [[ "$orphan_count" -gt 0 ]]; then
		result=$(echo "$result" | jq --arg n "$orphan_count" \
			'.warnings += ["\($n) task(s) have no parent_id — they will form their own branch"]')
	fi

	# Check 5: Warn about deeply nested tasks (depth > 3)
	local deep_count
	deep_count=$(echo "$TASKS_JSON" | jq '[.[] | select((.depth // 0) > 3)] | length')
	if [[ "$deep_count" -gt 0 ]]; then
		result=$(echo "$result" | jq --arg n "$deep_count" \
			'.warnings += ["\($n) task(s) exceed recommended depth limit of 3"]')
	fi

	local is_valid
	is_valid=$(echo "$result" | jq -r '.valid')
	if [[ "$is_valid" == "true" ]]; then
		log_success "Task graph is valid ($task_count tasks)"
	else
		local error_count
		error_count=$(echo "$result" | jq '.errors | length')
		log_error "Task graph has $error_count error(s)"
	fi

	echo "$result" | jq '.'
	return 0
}

#######################################
# Main entry point
#######################################
main() {
	# Require jq for JSON processing
	if ! command -v jq &>/dev/null; then
		log_error "jq is required but not installed"
		return 1
	fi

	parse_args "$@" || return $?

	case "$COMMAND" in
	order)
		cmd_order
		;;
	next-batch)
		cmd_next_batch
		;;
	validate)
		cmd_validate
		;;
	help | --help | -h)
		show_help
		;;
	*)
		log_error "Unknown command: $COMMAND"
		show_help
		return 1
		;;
	esac
}

main "$@"
