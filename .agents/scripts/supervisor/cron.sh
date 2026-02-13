#!/usr/bin/env bash
# cron.sh - Cron scheduling and auto-pickup functions
#
# Functions for cron pulse management, TODO.md watching,
# and automatic task pickup


#######################################
# Manage cron-based pulse scheduling
# Installs/uninstalls a crontab entry that runs pulse every N minutes
#######################################
cmd_cron() {
	local action="${1:-status}"
	shift || true

	local interval=2
	local batch_arg=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--interval)
			[[ $# -lt 2 ]] && {
				log_error "--interval requires a value"
				return 1
			}
			interval="$2"
			shift 2
			;;
		--batch)
			[[ $# -lt 2 ]] && {
				log_error "--batch requires a value"
				return 1
			}
			batch_arg="--batch $2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local script_path
	script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/supervisor-helper.sh"
	local cron_marker="# aidevops-supervisor-pulse"

	# Detect current PATH for cron environment (t1006)
	local user_path="${PATH}"

	# Detect GH_TOKEN from gh CLI if available (t1006)
	local gh_token=""
	if command -v gh &>/dev/null; then
		gh_token=$(gh auth token 2>/dev/null || true)
	fi

	# Build cron command with environment variables
	local env_vars=""
	if [[ -n "$user_path" ]]; then
		env_vars="PATH=${user_path}"
	fi
	if [[ -n "$gh_token" ]]; then
		env_vars="${env_vars:+${env_vars} }GH_TOKEN=${gh_token}"
	fi

	local cron_cmd="*/${interval} * * * * ${env_vars:+${env_vars} }${script_path} pulse ${batch_arg} >> ${SUPERVISOR_DIR}/cron.log 2>&1 ${cron_marker}"

	case "$action" in
	install)
		# Ensure supervisor dir exists for log file
		mkdir -p "$SUPERVISOR_DIR"

		# Check if already installed
		if crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
			log_warn "Supervisor cron already installed. Use 'cron uninstall' first to change settings."
			cmd_cron status
			return 0
		fi

		# Add to crontab (preserve existing entries)
		# Use temp file instead of stdin pipe to avoid macOS hang under load
		local existing_cron
		existing_cron=$(crontab -l 2>/dev/null || true)
		local temp_cron
		temp_cron=$(mktemp)
		if [[ -n "$existing_cron" ]]; then
			printf "%s\n%s\n" "$existing_cron" "$cron_cmd" >"$temp_cron"
		else
			printf "%s\n" "$cron_cmd" >"$temp_cron"
		fi
		crontab "$temp_cron"
		rm -f "$temp_cron"

		log_success "Installed supervisor cron (every ${interval} minutes)"
		log_info "Log: ${SUPERVISOR_DIR}/cron.log"
		if [[ -n "$batch_arg" ]]; then
			log_info "Batch filter: $batch_arg"
		fi
		return 0
		;;

	uninstall)
		if ! crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
			log_info "No supervisor cron entry found"
			return 0
		fi

		# Remove the supervisor line from crontab
		# Use temp file instead of stdin pipe to avoid macOS hang under load
		local temp_cron
		temp_cron=$(mktemp)
		if crontab -l 2>/dev/null | grep -vF "$cron_marker" >"$temp_cron"; then
			crontab "$temp_cron"
		else
			# If crontab is now empty, remove it entirely
			crontab -r 2>/dev/null || true
		fi
		rm -f "$temp_cron"

		log_success "Uninstalled supervisor cron"
		return 0
		;;

	status)
		echo -e "${BOLD}=== Supervisor Cron Status ===${NC}"

		if crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
			local cron_line
			cron_line=$(crontab -l 2>/dev/null | grep -F "$cron_marker")
			echo -e "  Status:   ${GREEN}installed${NC}"
			echo "  Schedule: $cron_line"
		else
			echo -e "  Status:   ${YELLOW}not installed${NC}"
			echo "  Install:  supervisor-helper.sh cron install [--interval N] [--batch id]"
		fi

		# Show cron log tail if it exists
		local cron_log="${SUPERVISOR_DIR}/cron.log"
		if [[ -f "$cron_log" ]]; then
			local log_size
			log_size=$(wc -c <"$cron_log" | tr -d ' ')
			echo "  Log:      $cron_log ($log_size bytes)"
			echo ""
			echo "  Last 5 log lines:"
			tail -5 "$cron_log" 2>/dev/null | while IFS= read -r line; do
				echo "    $line"
			done
		fi

		return 0
		;;

	*)
		log_error "Usage: supervisor-helper.sh cron [install|uninstall|status] [--interval N] [--batch id]"
		return 1
		;;
	esac
}

#######################################
# Watch TODO.md for changes using fswatch
# Triggers auto-pickup + pulse on file modification
# Alternative to cron for real-time responsiveness
#######################################
cmd_watch() {
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
		log_error "TODO.md not found at $todo_file"
		return 1
	fi

	# Check for fswatch
	if ! command -v fswatch &>/dev/null; then
		log_error "fswatch not found. Install with: brew install fswatch"
		log_info "Alternative: use 'supervisor-helper.sh cron install' for cron-based scheduling"
		return 1
	fi

	local script_path
	script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/supervisor-helper.sh"

	log_info "Watching $todo_file for changes..."
	log_info "Press Ctrl+C to stop"
	log_info "On change: auto-pickup + pulse"

	# Use fswatch with a 2-second latency to debounce rapid edits
	fswatch --latency 2 -o "$todo_file" | while read -r _count; do
		log_info "TODO.md changed, running auto-pickup + pulse..."
		"$script_path" auto-pickup --repo "$repo" 2>&1 || true
		"$script_path" pulse 2>&1 || true
		echo ""
	done

	return 0
}

#######################################
# Scan TODO.md for tasks tagged #auto-dispatch or in a
# "Dispatch Queue" section. Auto-adds them to supervisor
# if not already tracked, then queues them for dispatch.
#######################################
cmd_auto_pickup() {
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

	local picked_up=0

	# Strategy 1: Find tasks tagged #auto-dispatch
	# Matches: - [ ] tXXX description #auto-dispatch ...
	local tagged_tasks
	tagged_tasks=$(grep -E '^[[:space:]]*- \[ \] (t[0-9]+(\.[0-9]+)*) .*#auto-dispatch' "$todo_file" 2>/dev/null || true)

	if [[ -n "$tagged_tasks" ]]; then
		while IFS= read -r line; do
			local task_id
			task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
			if [[ -z "$task_id" ]]; then
				continue
			fi

			# Check if already in supervisor
			local existing
			existing=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || true)
			if [[ -n "$existing" ]]; then
				if [[ "$existing" == "complete" || "$existing" == "cancelled" ]]; then
					continue
				fi
				log_info "  $task_id: already tracked (status: $existing)"
				continue
			fi

			# Pre-pickup check: skip tasks with merged PRs (t224).
			# cmd_add also checks, but checking here provides better logging.
			if check_task_already_done "$task_id" "$repo"; then
				log_info "  $task_id: already completed (merged PR) — skipping auto-pickup"
				continue
			fi

			# Add to supervisor
			if cmd_add "$task_id" --repo "$repo"; then
				picked_up=$((picked_up + 1))
				log_success "  Auto-picked: $task_id (tagged #auto-dispatch)"
			fi
		done <<<"$tagged_tasks"
	fi

	# Strategy 2: Find tasks in "Dispatch Queue" section
	# Looks for a markdown section header containing "Dispatch Queue"
	# and picks up all open tasks under it until the next section header
	local in_dispatch_section=false
	local section_tasks=""

	while IFS= read -r line; do
		# Detect section headers (## or ###)
		if echo "$line" | grep -qE '^#{1,3} '; then
			if echo "$line" | grep -qi 'dispatch.queue'; then
				in_dispatch_section=true
				continue
			else
				in_dispatch_section=false
				continue
			fi
		fi

		if [[ "$in_dispatch_section" == "true" ]]; then
			# Match open task lines
			if echo "$line" | grep -qE '^[[:space:]]*- \[ \] t[0-9]+'; then
				section_tasks+="$line"$'\n'
			fi
		fi
	done <"$todo_file"

	if [[ -n "$section_tasks" ]]; then
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			local task_id
			task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
			if [[ -z "$task_id" ]]; then
				continue
			fi

			local existing
			existing=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || true)
			if [[ -n "$existing" ]]; then
				if [[ "$existing" == "complete" || "$existing" == "cancelled" ]]; then
					continue
				fi
				log_info "  $task_id: already tracked (status: $existing)"
				continue
			fi

			# Pre-pickup check: skip tasks with merged PRs (t224).
			if check_task_already_done "$task_id" "$repo"; then
				log_info "  $task_id: already completed (merged PR) — skipping auto-pickup"
				continue
			fi

			if cmd_add "$task_id" --repo "$repo"; then
				picked_up=$((picked_up + 1))
				log_success "  Auto-picked: $task_id (Dispatch Queue section)"
			fi
		done <<<"$section_tasks"
	fi

	# Strategy 3: Find #plan tasks with PLANS.md references but no subtasks (t274)
	# Matches: - [ ] tXXX description #plan ... → [todo/PLANS.md#anchor]
	# Dispatches decomposition worker to generate subtasks with #auto-dispatch
	local plan_tasks
	plan_tasks=$(grep -E '^[[:space:]]*- \[ \] (t[0-9]+) .*#plan.*→ \[todo/PLANS\.md#' "$todo_file" 2>/dev/null || true)

	if [[ -n "$plan_tasks" ]]; then
		while IFS= read -r line; do
			local task_id
			task_id=$(echo "$line" | grep -oE 't[0-9]+' | head -1)
			if [[ -z "$task_id" ]]; then
				continue
			fi

			# Check if task already has subtasks (e.g., t001.1, t001.2)
			# Matches any checkbox state: [ ], [x], [X], [-]
			local has_subtasks
			has_subtasks=$(grep -E "^[[:space:]]+-[[:space:]]\[[ xX-]\][[:space:]]${task_id}\.[0-9]+" "$todo_file" 2>/dev/null || true)
			if [[ -n "$has_subtasks" ]]; then
				log_info "  $task_id: already has subtasks — skipping auto-decomposition"
				continue
			fi

			# Check if already in supervisor
			local existing
			existing=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || true)
			if [[ -n "$existing" ]]; then
				if [[ "$existing" == "complete" || "$existing" == "cancelled" ]]; then
					continue
				fi
				log_info "  $task_id: already tracked (status: $existing)"
				continue
			fi

			# Pre-pickup check: skip tasks with merged PRs (t224).
			if check_task_already_done "$task_id" "$repo"; then
				log_info "  $task_id: already completed (merged PR) — skipping auto-pickup"
				continue
			fi

			# Extract PLANS.md anchor from the line
			local plan_anchor
			plan_anchor=$(echo "$line" | grep -oE 'todo/PLANS\.md#[^]]+' | sed 's/todo\/PLANS\.md#//' || true)
			if [[ -z "$plan_anchor" ]]; then
				log_warn "  $task_id: #plan tag found but no PLANS.md anchor — skipping"
				continue
			fi

			# Add to supervisor (plan_anchor passed directly to dispatch_decomposition_worker)
			if cmd_add "$task_id" --repo "$repo"; then
				picked_up=$((picked_up + 1))
				log_success "  Auto-picked: $task_id (#plan task for decomposition)"

				# Dispatch decomposition worker immediately
				log_info "  Dispatching decomposition worker for $task_id..."
				dispatch_decomposition_worker "$task_id" "$plan_anchor" "$repo"
			fi
		done <<<"$plan_tasks"
	fi

	if [[ "$picked_up" -eq 0 ]]; then
		log_info "No new tasks to pick up"
	else
		log_success "Picked up $picked_up new tasks"

		# Auto-batch: assign picked-up tasks to a batch (t296)
		# Find unbatched queued tasks (just added by auto-pickup)
		local unbatched_queued
		unbatched_queued=$(db "$SUPERVISOR_DB" "
            SELECT t.id FROM tasks t
            WHERE t.status = 'queued'
              AND t.id NOT IN (SELECT task_id FROM batch_tasks)
            ORDER BY t.created_at;
        " 2>/dev/null || true)

		if [[ -n "$unbatched_queued" ]]; then
			# Check for an active batch (has non-terminal tasks)
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
				# Derive base concurrency from CPU cores (cores / 2, min 2)
				# A 10-core Mac gets 5, a 32-core server gets 16, etc.
				# The adaptive scaling in calculate_adaptive_concurrency() then
				# adjusts up/down from this base depending on actual load.
				local auto_cores="$(get_cpu_cores)"
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
		fi
	fi

	return 0
}

#######################################
# Dispatch a decomposition worker for a #plan task (t274)
# Reads PLANS.md section and generates subtasks in TODO.md
# with #auto-dispatch tags for autonomous execution.
#
# This is a special worker that IS allowed to edit TODO.md
# because it's generating subtasks for orchestration.
#
# Arguments:
#   $1 - task_id (e.g., t199)
#   $2 - plan_anchor (e.g., 2026-02-09-content-creation-agent-architecture)
#   $3 - repo path
#######################################
dispatch_decomposition_worker() {
	local task_id="$1"
	local plan_anchor="$2"
	local repo="$3"

	if [[ -z "$task_id" || -z "$plan_anchor" || -z "$repo" ]]; then
		log_error "dispatch_decomposition_worker: missing required arguments"
		return 1
	fi

	local plans_file="$repo/todo/PLANS.md"
	if [[ ! -f "$plans_file" ]]; then
		log_error "  $task_id: PLANS.md not found at $plans_file"
		return 1
	fi

	# Check for already-running decomposition worker (throttle)
	local pid_file="$SUPERVISOR_DIR/pids/${task_id}-decompose.pid"
	if [[ -f "$pid_file" ]]; then
		local existing_pid
		existing_pid=$(cat "$pid_file" 2>/dev/null || true)
		if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
			log_info "  $task_id: decomposition worker already running (PID: $existing_pid)"
			return 0
		fi
		# Stale PID file — clean up
		rm -f "$pid_file"
	fi

	# Resolve AI CLI (uses opencode with claude fallback)
	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_error "  $task_id: no AI CLI available for decomposition worker"
		return 1
	}

	# Build decomposition prompt with explicit TODO.md edit permission
	local decomposition_prompt
	read -r -d '' decomposition_prompt <<EOF || true
You are a task decomposition worker with SPECIAL PERMISSION to edit TODO.md.

Your mission: Read a plan from PLANS.md and generate subtasks in TODO.md with #auto-dispatch tags.

## MANDATORY Worker Restrictions (t173) - EXCEPTION FOR THIS WORKER
You ARE allowed to edit TODO.md for this specific task because you are generating
subtasks for orchestration. This is the ONLY exception to the worker TODO.md restriction.
- Do NOT edit todo/PLANS.md or todo/tasks/* — these are supervisor-managed.
- Do NOT create branches or PRs — commit directly to main.

## Task Details
Task ID: $task_id
Plan anchor: $plan_anchor
Repository: $repo

## Instructions

### Step 1: Read the plan
Read todo/PLANS.md and find the section with anchor matching the plan_anchor above.
The anchor format is: ### [YYYY-MM-DD] Plan Title
Look for the heading that matches the anchor slug.

### Step 2: Analyze the plan structure
Extract:
- Phases or milestones (usually in #### Progress or #### Phases section)
- Deliverables and their estimates
- Dependencies between phases
- Any special requirements or constraints

### Step 3: Generate subtasks
Create subtasks following this format:
- Parent task line: DO NOT MODIFY (already exists in TODO.md)
- Subtasks: ${task_id}.1, ${task_id}.2, etc.
- Indentation: 2 spaces before the dash
- Each subtask MUST have #auto-dispatch tag
- Include estimates (~Xh or ~Xm) based on plan
- Add blocked-by: dependencies if phases are sequential
- Keep descriptions concise but actionable

### Step 4: Insert subtasks in TODO.md
1. Find the parent task line (starts with "- [ ] ${task_id} ")
2. Insert subtasks immediately after it (before any blank line or next task)
3. Preserve all existing content
4. DO NOT modify the parent task line

### Step 5: Commit and exit
1. Run: git add TODO.md
2. Run: git commit -m "feat: auto-decompose ${task_id} from PLANS.md (${plan_anchor})"
3. Run: git push origin main
4. Exit with status 0

## Example output format
\`\`\`markdown
- [ ] t300 Email Testing Suite #plan → [todo/PLANS.md#2026-02-10-email-testing-suite] ~2h
  - [ ] t300.1 Email Design Test agent + helper script ~35m #auto-dispatch
  - [ ] t300.2 Email Delivery Test agent + helper script ~35m #auto-dispatch blocked-by:t300.1
  - [ ] t300.3 Email Health Check enhancements ~15m #auto-dispatch blocked-by:t300.2
  - [ ] t300.4 Cross-references + integration ~10m #auto-dispatch blocked-by:t300.3
\`\`\`

## CRITICAL Rules
- DO NOT modify the parent task line — it MUST remain [ ] (unchecked)
- DO NOT mark the parent task [x] — it stays open until ALL subtasks are complete
- DO NOT remove any existing content
- ONLY add the indented subtasks
- Each subtask MUST be actionable and have #auto-dispatch
- Commit directly to main (no branch, no PR)
- This is a TODO.md-only change (exception to worker restrictions)
- Exit 0 when done, exit 1 on error

## Uncertainty Decision Framework
If the plan structure is unclear:
- PROCEED: Generate subtasks based on visible phases/milestones
- PROCEED: Use reasonable estimates if not specified in plan
- FLAG: Exit with error if plan anchor not found in PLANS.md
- FLAG: Exit with error if plan has no actionable content

Start now. Read todo/PLANS.md, find the anchor, generate subtasks, commit, push, exit 0.
EOF

	# Create logs and PID directories
	mkdir -p "$HOME/.aidevops/logs"
	mkdir -p "$SUPERVISOR_DIR/pids"

	local worker_log="$HOME/.aidevops/logs/decomposition-worker-${task_id}.log"
	log_info "  Decomposition worker log: $worker_log"

	# Build dispatch script for the decomposition worker
	local dispatch_script="${SUPERVISOR_DIR}/pids/${task_id}-decompose-dispatch.sh"
	{
		echo '#!/usr/bin/env bash'
		echo "echo 'DECOMPOSE_WORKER_STARTED task_id=${task_id} pid=\$\$ timestamp='\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "cd '${repo}' || { echo 'DECOMPOSE_FAILED: cd to repo failed: ${repo}'; exit 1; }"
	} >"$dispatch_script"

	# Append CLI-specific invocation
	if [[ "$ai_cli" == "opencode" ]]; then
		{
			printf 'exec opencode run --format json --title %q %q\n' \
				"decompose-${task_id}" "$decomposition_prompt"
		} >>"$dispatch_script"
	else
		{
			printf 'exec claude -p %q --output-format json\n' \
				"$decomposition_prompt"
		} >>"$dispatch_script"
	fi
	chmod +x "$dispatch_script"

	# Wrapper script with cleanup handlers (matches cmd_dispatch pattern)
	local wrapper_script="${SUPERVISOR_DIR}/pids/${task_id}-decompose-wrapper.sh"
	{
		echo '#!/usr/bin/env bash'
		echo 'cleanup_children() {'
		echo '  local children'
		echo '  children=$(pgrep -P $$ 2>/dev/null || true)'
		echo '  if [[ -n "$children" ]]; then'
		echo '    kill -TERM $children 2>/dev/null || true'
		echo '    sleep 0.5'
		echo '    kill -9 $children 2>/dev/null || true'
		echo '  fi'
		echo '}'
		echo 'trap cleanup_children EXIT INT TERM'
		echo "'${dispatch_script}' >> '${worker_log}' 2>&1"
		echo "rc=\$?"
		echo "echo \"EXIT:\${rc}\" >> '${worker_log}'"
		echo "if [ \$rc -ne 0 ]; then"
		echo "  echo \"DECOMPOSE_WORKER_ERROR: dispatch exited with code \${rc}\" >> '${worker_log}'"
		echo "fi"
	} >"$wrapper_script"
	chmod +x "$wrapper_script"

	# Launch background process with nohup + setsid (matches cmd_dispatch pattern)
	if command -v setsid &>/dev/null; then
		nohup setsid bash "${wrapper_script}" &>/dev/null &
	else
		nohup bash "${wrapper_script}" &>/dev/null &
	fi
	disown 2>/dev/null || true
	local worker_pid=$!

	# Store PID for throttle check and monitoring
	echo "$worker_pid" >"$pid_file"
	log_success "  Decomposition worker dispatched (PID: $worker_pid, CLI: $ai_cli)"

	# Update task metadata with worker PID
	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	db "$SUPERVISOR_DB" "UPDATE tasks SET metadata = CASE WHEN metadata IS NULL OR metadata = '' THEN 'decomposition_worker_pid=$worker_pid' ELSE metadata || ',decomposition_worker_pid=$worker_pid' END WHERE id = '$escaped_id';" 2>/dev/null || true

	return 0
}
