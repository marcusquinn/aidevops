#!/usr/bin/env bash
# batch-cleanup-helper.sh - Batch simple chore tasks into a single dispatch
#
# Reduces worktree/PR overhead for simple TODO.md-only cleanup tasks.
# Instead of N*(worktree + PR + CI + merge) for N chore tasks, this
# groups them into a single dispatch: 1 worktree + 1 PR + 1 CI + 1 merge.
#
# Eligibility criteria for batch-cleanup grouping:
#   - Tagged #chore in TODO.md
#   - Estimated <=15m (~15m, ~10m, ~5m, ~Xm where X<=15)
#   - No blocked-by: dependencies on non-complete tasks
#   - No assignee: or started: fields (unclaimed)
#   - Status: pending ([ ] checkbox)
#
# Usage:
#   batch-cleanup-helper.sh scan [--repo path] [--dry-run]
#   batch-cleanup-helper.sh dispatch [--repo path] [--dry-run]
#   batch-cleanup-helper.sh status
#   batch-cleanup-helper.sh help
#
# Integration:
#   Called by supervisor auto-pickup (Strategy 5) when chore tasks are found.
#   Can also be run manually to trigger a cleanup batch.
#
# t1146: Add batch-task-creation capability to reduce worktree/PR overhead

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Source supervisor constants and helpers
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/supervisor/_common.sh"

readonly SUPERVISOR_DIR="${AIDEVOPS_SUPERVISOR_DIR:-$HOME/.aidevops/.agent-workspace/supervisor}"
readonly SUPERVISOR_DB="$SUPERVISOR_DIR/supervisor.db"
# shellcheck disable=SC2034  # Used by sourced _common.sh log functions
readonly SUPERVISOR_LOG="${HOME}/.aidevops/logs/supervisor.log"

# Maximum estimate (in minutes) for a task to be eligible for batch cleanup
readonly BATCH_CLEANUP_MAX_MINUTES=15

# Minimum tasks to trigger a batch (avoid overhead for single tasks)
readonly BATCH_CLEANUP_MIN_TASKS=2

# PID file to prevent concurrent batch-cleanup dispatches
readonly BATCH_CLEANUP_PID_FILE="$SUPERVISOR_DIR/pids/batch-cleanup.pid"

#######################################
# Parse estimate string to minutes
# Handles: ~5m, ~10m, ~15m, ~1h, ~0.5h, ~30m
# Args: $1 = estimate string (e.g., "~10m" or "~1h")
# Returns: integer minutes on stdout, or empty if unparseable
#######################################
parse_estimate_minutes() {
	local estimate="$1"

	# Strip leading ~ and whitespace
	estimate="${estimate#\~}"
	estimate="${estimate// /}"

	if [[ "$estimate" =~ ^([0-9]+)m$ ]]; then
		echo "${BASH_REMATCH[1]}"
		return 0
	fi

	if [[ "$estimate" =~ ^([0-9]+)h$ ]]; then
		echo $((BASH_REMATCH[1] * 60))
		return 0
	fi

	if [[ "$estimate" =~ ^([0-9]+)\.([0-9]+)h$ ]]; then
		local hours="${BASH_REMATCH[1]}"
		local frac="${BASH_REMATCH[2]}"
		# Convert fractional hours: 0.5h = 30m, 1.5h = 90m
		echo $((hours * 60 + frac * 6))
		return 0
	fi

	# Unparseable — return empty (caller treats as ineligible)
	return 0
}

#######################################
# Check if a task's blocked-by dependencies are all resolved
# Args: $1 = task line from TODO.md, $2 = todo_file path
# Returns: 0 if unblocked (eligible), 1 if blocked
#######################################
is_task_unblocked() {
	local task_line="$1"
	local todo_file="$2"

	# Extract blocked-by: field
	local blocked_by
	blocked_by=$(echo "$task_line" | grep -oE 'blocked-by:[^ ]+' | sed 's/blocked-by://' || true)

	if [[ -z "$blocked_by" ]]; then
		return 0 # No dependencies — unblocked
	fi

	# Check each dependency
	local dep
	IFS=',' read -ra deps <<<"$blocked_by"
	for dep in "${deps[@]}"; do
		dep="${dep// /}"
		[[ -z "$dep" ]] && continue

		# Check if dependency is complete ([x]) in TODO.md
		local dep_line
		dep_line=$(grep -E "^[[:space:]]*- \[x\] ${dep} " "$todo_file" 2>/dev/null | head -1 || true)
		if [[ -z "$dep_line" ]]; then
			# Dependency not complete — task is blocked
			return 1
		fi
	done

	return 0 # All dependencies resolved
}

#######################################
# Scan TODO.md for batch-cleanup-eligible tasks
# Args: $1 = repo path, $2 = dry_run (true/false)
# Outputs: newline-separated task IDs eligible for batch cleanup
#######################################
scan_eligible_tasks() {
	local repo="$1"
	local dry_run="${2:-false}"
	local todo_file="$repo/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		log_warn "TODO.md not found at $todo_file"
		return 1
	fi

	local eligible_tasks=()

	# Find all pending #chore tasks
	local chore_tasks
	chore_tasks=$(grep -E '^[[:space:]]*- \[ \] (t[0-9]+(\.[0-9]+)*) .*#chore' "$todo_file" 2>/dev/null || true)

	if [[ -z "$chore_tasks" ]]; then
		log_info "No pending #chore tasks found"
		echo ""
		return 0
	fi

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue

		local task_id
		task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
		if [[ -z "$task_id" ]]; then
			continue
		fi

		# Skip tasks with assignee: or started: (already claimed)
		if echo "$line" | grep -qE '(assignee:|started:)'; then
			log_info "  $task_id: already claimed — skipping"
			continue
		fi

		# Check estimate — must be <=15m
		local estimate
		estimate=$(echo "$line" | grep -oE '~[0-9]+(\.[0-9]+)?[mh]' | head -1 || true)
		if [[ -z "$estimate" ]]; then
			log_info "  $task_id: no estimate found — skipping (batch-cleanup requires explicit estimate)"
			continue
		fi

		local minutes
		minutes=$(parse_estimate_minutes "$estimate")
		if [[ -z "$minutes" ]]; then
			log_info "  $task_id: unparseable estimate '$estimate' — skipping"
			continue
		fi

		if [[ "$minutes" -gt "$BATCH_CLEANUP_MAX_MINUTES" ]]; then
			log_info "  $task_id: estimate ${minutes}m > ${BATCH_CLEANUP_MAX_MINUTES}m — skipping"
			continue
		fi

		# Check blocked-by dependencies
		if ! is_task_unblocked "$line" "$todo_file"; then
			log_info "  $task_id: has unresolved blocked-by dependencies — skipping"
			continue
		fi

		# Check if already tracked in supervisor DB
		if [[ -f "$SUPERVISOR_DB" ]]; then
			local existing
			existing=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || true)
			if [[ -n "$existing" && "$existing" != "cancelled" && "$existing" != "complete" ]]; then
				log_info "  $task_id: already tracked in supervisor (status: $existing) — skipping"
				continue
			fi
		fi

		log_info "  $task_id: eligible for batch cleanup (estimate: ${minutes}m)"
		eligible_tasks+=("$task_id")

	done <<<"$chore_tasks"

	if [[ "${#eligible_tasks[@]}" -eq 0 ]]; then
		echo ""
		return 0
	fi

	printf '%s\n' "${eligible_tasks[@]}"
	return 0
}

#######################################
# Dispatch a single batch-cleanup worker for multiple chore tasks
# The worker handles all tasks in one PR, reducing overhead by ~80%.
#
# Args: $1 = repo path, $2 = space-separated task IDs, $3 = dry_run
#######################################
dispatch_batch_cleanup_worker() {
	local repo="$1"
	local task_ids_str="$2"
	local dry_run="${3:-false}"

	local -a task_ids
	read -ra task_ids <<<"$task_ids_str"

	if [[ "${#task_ids[@]}" -eq 0 ]]; then
		log_warn "No task IDs provided to dispatch_batch_cleanup_worker"
		return 1
	fi

	# Check for already-running batch-cleanup worker (throttle)
	mkdir -p "$(dirname "$BATCH_CLEANUP_PID_FILE")"
	if [[ -f "$BATCH_CLEANUP_PID_FILE" ]]; then
		local existing_pid
		existing_pid=$(cat "$BATCH_CLEANUP_PID_FILE" 2>/dev/null || true)
		if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
			log_info "Batch-cleanup worker already running (PID: $existing_pid) — skipping"
			return 0
		fi
		rm -f "$BATCH_CLEANUP_PID_FILE"
	fi

	# Resolve AI CLI
	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_error "No AI CLI available for batch-cleanup worker"
		return 1
	}

	# Build task list for the prompt
	local task_list=""
	local todo_file="$repo/TODO.md"
	local task_id
	for task_id in "${task_ids[@]}"; do
		local task_line
		task_line=$(grep -E "^[[:space:]]*- \[ \] ${task_id} " "$todo_file" 2>/dev/null | head -1 || true)
		if [[ -n "$task_line" ]]; then
			task_list+="- ${task_id}: $(echo "$task_line" | sed -E 's/^[[:space:]]*- \[ \] [^ ]+ //' | head -c 120)"$'\n'
		else
			task_list+="- ${task_id}: (description not found in TODO.md)"$'\n'
		fi
	done

	# Generate task CSV for prompt and PR title
	local task_csv
	task_csv=$(printf '%s,' "${task_ids[@]}" | sed 's/,$//')

	# Build the worker prompt
	local worker_prompt
	read -r -d '' worker_prompt <<PROMPT || true
You are a batch-cleanup worker with SPECIAL PERMISSION to edit TODO.md and todo/ files.

## Purpose
This is a batch-cleanup dispatch (t1146). Instead of N separate worktrees and PRs for N
simple chore tasks, you will handle ALL of them in a single PR. This reduces overhead by ~80%.

## MANDATORY Worker Restrictions (t173) - EXCEPTION FOR THIS WORKER
You ARE allowed to edit TODO.md and todo/ files for this specific batch-cleanup task.
This is the ONLY exception to the worker TODO.md restriction.
- Do NOT edit any files outside TODO.md and todo/ directory.
- Do NOT create separate branches per task — use a single branch for all tasks.
- Create ONE PR for all tasks combined.

## Tasks to Complete
The following #chore tasks must all be completed in a single PR:

${task_list}

## Instructions

### Step 1: Create a single branch
\`\`\`bash
git checkout -b chore/batch-cleanup-$(date +%Y%m%d)
\`\`\`

### Step 2: Apply all task changes
For each task above, apply the required changes to TODO.md or todo/ files.
Common chore operations:
- Mark cancelled: change \`- [ ]\` to \`- [-]\` and add \`cancelled:YYYY-MM-DD\`
- Fix duplicate: remove the duplicate line
- Fix typo: correct the text in place
- Update metadata: add/fix fields like \`ref:\`, \`blocked-by:\`, etc.

Read the task description carefully to understand what change is needed.

### Step 3: Commit all changes together
\`\`\`bash
git add TODO.md todo/
git commit -m "chore: batch cleanup ${task_csv} (t1146)"
\`\`\`

### Step 4: Create a single PR
\`\`\`bash
gh pr create --title "chore: batch cleanup ${task_csv}" --body "Batch cleanup of simple chore tasks (t1146).

Tasks completed in this PR:
${task_list}

This batch dispatch reduces overhead vs individual PRs per task.
Ref: t1146"
\`\`\`

### Step 5: Signal completion
Output the following line so the supervisor can detect completion:
\`\`\`
BATCH_CLEANUP_COMPLETE tasks=${task_csv}
\`\`\`

## CRITICAL Rules
- Handle ALL tasks in this list — do not skip any without explanation
- Make ONLY the changes described in each task — do not refactor or expand scope
- If a task is ambiguous, make the most conservative interpretation
- If a task is already done, note it in the PR body and continue
- Exit 0 on success, non-zero on failure
PROMPT

	if [[ "$dry_run" == "true" ]]; then
		log_info "[DRY RUN] Would dispatch batch-cleanup worker for: ${task_csv}"
		log_info "[DRY RUN] Tasks: ${#task_ids[@]}"
		log_info "[DRY RUN] AI CLI: $ai_cli"
		return 0
	fi

	# Set up log file
	local log_dir="$SUPERVISOR_DIR/logs"
	mkdir -p "$log_dir"
	local log_file
	log_file="$log_dir/batch-cleanup-$(date +%Y%m%d%H%M%S).log"

	log_info "Dispatching batch-cleanup worker for ${#task_ids[@]} tasks: ${task_csv}"
	log_info "Log: $log_file"

	# Dispatch headless worker
	local dispatch_cmd=("$ai_cli" run --format json)

	# Add model flag if supported
	if [[ "$ai_cli" == "opencode" ]]; then
		dispatch_cmd+=(--model "anthropic/claude-sonnet-4-6")
	fi

	nohup "${dispatch_cmd[@]}" "$worker_prompt" \
		>"$log_file" 2>&1 &
	local worker_pid=$!
	echo "$worker_pid" >"$BATCH_CLEANUP_PID_FILE"

	log_success "Batch-cleanup worker dispatched (PID: $worker_pid)"
	log_info "Tasks: ${task_csv}"
	log_info "Log: $log_file"

	return 0
}

#######################################
# Main scan command: find and report eligible tasks
# Args: --repo path, --dry-run
#######################################
cmd_scan() {
	local repo="" dry_run="false"

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
		--dry-run)
			dry_run="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	[[ -z "$repo" ]] && repo="$(pwd)"

	log_info "Scanning for batch-cleanup-eligible tasks in $repo..."

	local eligible
	eligible=$(scan_eligible_tasks "$repo" "$dry_run")

	if [[ -z "$eligible" ]]; then
		log_info "No eligible tasks found (need #chore + ~<=15m + unblocked)"
		return 0
	fi

	local count
	count=$(echo "$eligible" | grep -c '^t' || true)
	log_success "Found $count eligible task(s):"
	echo "$eligible" | while IFS= read -r tid; do
		[[ -z "$tid" ]] && continue
		echo "  $tid"
	done

	if [[ "$count" -lt "$BATCH_CLEANUP_MIN_TASKS" ]]; then
		log_info "Only $count task(s) found — minimum is $BATCH_CLEANUP_MIN_TASKS for batch dispatch"
		log_info "Use 'dispatch' command to force dispatch even with fewer tasks"
	fi

	return 0
}

#######################################
# Main dispatch command: scan and dispatch batch-cleanup worker
# Args: --repo path, --dry-run, --force (bypass min-tasks check)
#######################################
cmd_dispatch() {
	local repo="" dry_run="false" force="false"

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
		--dry-run)
			dry_run="true"
			shift
			;;
		--force)
			force="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	[[ -z "$repo" ]] && repo="$(pwd)"

	log_info "Scanning for batch-cleanup-eligible tasks..."

	local eligible
	eligible=$(scan_eligible_tasks "$repo" "$dry_run")

	if [[ -z "$eligible" ]]; then
		log_info "No eligible tasks found — nothing to dispatch"
		return 0
	fi

	local -a task_ids
	while IFS= read -r tid; do
		[[ -z "$tid" ]] && continue
		task_ids+=("$tid")
	done <<<"$eligible"

	local count="${#task_ids[@]}"

	if [[ "$count" -lt "$BATCH_CLEANUP_MIN_TASKS" && "$force" != "true" ]]; then
		log_info "Only $count task(s) eligible — minimum is $BATCH_CLEANUP_MIN_TASKS"
		log_info "Use --force to dispatch anyway, or wait for more chore tasks to accumulate"
		return 0
	fi

	log_success "Dispatching batch-cleanup worker for $count task(s): ${task_ids[*]}"
	dispatch_batch_cleanup_worker "$repo" "${task_ids[*]}" "$dry_run"
	return $?
}

#######################################
# Status command: show batch-cleanup worker status
#######################################
cmd_status() {
	echo "Batch Cleanup Status"
	echo "  PID file: $BATCH_CLEANUP_PID_FILE"

	if [[ -f "$BATCH_CLEANUP_PID_FILE" ]]; then
		local pid
		pid=$(cat "$BATCH_CLEANUP_PID_FILE" 2>/dev/null || true)
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
			echo "  Worker: RUNNING (PID: $pid)"
		else
			echo "  Worker: NOT RUNNING (stale PID: $pid)"
		fi
	else
		echo "  Worker: NOT RUNNING"
	fi

	echo "  Eligibility criteria:"
	echo "    - Tagged: #chore"
	echo "    - Estimate: <=${BATCH_CLEANUP_MAX_MINUTES}m"
	echo "    - Status: pending ([ ])"
	echo "    - No unresolved blocked-by dependencies"
	echo "    - No assignee: or started: fields"
	echo "  Min tasks for auto-dispatch: $BATCH_CLEANUP_MIN_TASKS"

	return 0
}

#######################################
# Show usage
#######################################
show_usage() {
	cat <<'EOF'
batch-cleanup-helper.sh - Batch simple chore tasks into a single dispatch

Usage:
  batch-cleanup-helper.sh scan [--repo path] [--dry-run]
  batch-cleanup-helper.sh dispatch [--repo path] [--dry-run] [--force]
  batch-cleanup-helper.sh status
  batch-cleanup-helper.sh help

Commands:
  scan      Find and list eligible tasks without dispatching
  dispatch  Scan and dispatch a single batch-cleanup worker for all eligible tasks
  status    Show current batch-cleanup worker status
  help      Show this help

Options:
  --repo <path>   Repository with TODO.md (default: current directory)
  --dry-run       Show what would happen without executing
  --force         Dispatch even if fewer than minimum tasks found

Eligibility criteria (all must be true):
  - Tagged #chore in TODO.md
  - Estimated <=15m (~5m, ~10m, ~15m)
  - Status: pending ([ ] checkbox)
  - No unresolved blocked-by: dependencies
  - No assignee: or started: fields (unclaimed)

Integration:
  Called automatically by supervisor auto-pickup (Strategy 5) during pulse.
  Can also be run manually to trigger a cleanup batch.

Expected savings:
  N chore tasks: N*(worktree + PR + CI + merge) → 1*(worktree + PR + CI + merge)
  ~80% token reduction for cleanup batches of 5+ tasks.

t1146: Add batch-task-creation capability to reduce worktree/PR overhead
EOF
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	scan) cmd_scan "$@" ;;
	dispatch) cmd_dispatch "$@" ;;
	status) cmd_status "$@" ;;
	help | --help | -h) show_usage ;;
	*)
		log_error "Unknown command: $command"
		show_usage
		return 1
		;;
	esac
}

main "$@"
