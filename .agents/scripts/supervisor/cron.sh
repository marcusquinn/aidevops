#!/usr/bin/env bash
# cron.sh - Scheduler abstraction for pulse management and auto-pickup
#
# Platform-aware: uses launchd on macOS, cron on Linux.
# Same CLI interface (cron install/uninstall/status) regardless of backend.
#
# On macOS: generates ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist
# On Linux: installs a crontab entry (unchanged behaviour)

# Source launchd helpers (macOS backend)
# shellcheck source=launchd.sh
_CRON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_CRON_DIR}/launchd.sh" ]]; then
	# shellcheck disable=SC1091
	source "${_CRON_DIR}/launchd.sh"
fi

#######################################
# Manage pulse scheduling (platform-aware)
# On macOS: installs/uninstalls LaunchAgent plist
# On Linux: installs/uninstalls crontab entry
# Same CLI: cron [install|uninstall|status] [--interval N] [--batch id]
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
	script_path="${SCRIPT_DIR}/supervisor-helper.sh"
	local cron_log="${SUPERVISOR_DIR}/cron.log"

	# Ensure supervisor dir exists for log file
	mkdir -p "$SUPERVISOR_DIR"

	# Platform dispatch: launchd on macOS, cron on Linux
	local backend
	backend="$(_get_scheduler_backend 2>/dev/null || echo "cron")"

	if [[ "$backend" == "launchd" ]]; then
		_cmd_cron_launchd "$action" "$script_path" "$interval" "$batch_arg" "$cron_log"
		return $?
	fi

	# Linux: cron backend (unchanged)
	_cmd_cron_linux "$action" "$script_path" "$interval" "$batch_arg" "$cron_log"
	return $?
}

#######################################
# macOS launchd backend for cmd_cron
# Arguments:
#   $1 - action (install|uninstall|status)
#   $2 - script_path
#   $3 - interval (minutes)
#   $4 - batch_arg
#   $5 - log_path
#######################################
_cmd_cron_launchd() {
	local action="$1"
	local script_path="$2"
	local interval="$3"
	local batch_arg="$4"
	local log_path="$5"

	local interval_seconds=$((interval * 60))

	case "$action" in
	install)
		# Auto-migrate existing cron entry if present
		launchd_migrate_from_cron \
			"supervisor-pulse" \
			"$script_path" \
			"$log_path" \
			"$interval_seconds" \
			"$batch_arg"

		# Install (migrate handles the case where cron existed; install handles fresh)
		if ! _launchd_is_loaded "com.aidevops.aidevops-supervisor-pulse"; then
			launchd_install_supervisor_pulse \
				"$script_path" \
				"$interval_seconds" \
				"$log_path" \
				"$batch_arg"
		fi

		if [[ -n "$batch_arg" ]]; then
			log_info "Batch filter: $batch_arg"
		fi
		return 0
		;;

	uninstall)
		launchd_uninstall_supervisor_pulse
		return 0
		;;

	status)
		launchd_status_supervisor_pulse

		# Show log tail if it exists
		if [[ -f "$log_path" ]]; then
			local log_size
			log_size=$(wc -c <"$log_path" | tr -d ' ')
			echo "  Log:      $log_path ($log_size bytes)"
			echo ""
			echo "  Last 5 log lines:"
			tail -5 "$log_path" 2>/dev/null | while IFS= read -r line; do
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
# Linux cron backend for cmd_cron
# Arguments:
#   $1 - action (install|uninstall|status)
#   $2 - script_path
#   $3 - interval (minutes)
#   $4 - batch_arg
#   $5 - log_path
#######################################
_cmd_cron_linux() {
	local action="$1"
	local script_path="$2"
	local interval="$3"
	local batch_arg="$4"
	local log_path="$5"

	local cron_marker="# aidevops-supervisor-pulse"

	# Detect current PATH for cron environment (t1006)
	local user_path="${PATH}"

	# GH_TOKEN is resolved at runtime by pulse.sh (t1260)
	# Previously baked into crontab/plist as plaintext — no longer needed here

	# Build cron command with environment variables
	local env_vars=""
	if [[ -n "$user_path" ]]; then
		env_vars="PATH=${user_path}"
	fi

	local cron_cmd="*/${interval} * * * * ${env_vars:+${env_vars} }${script_path} pulse ${batch_arg} >> ${log_path} 2>&1 ${cron_marker}"

	case "$action" in
	install)
		# Check if already installed
		if crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
			log_warn "Supervisor cron already installed. Use 'cron uninstall' first to change settings."
			_cmd_cron_linux status "$script_path" "$interval" "$batch_arg" "$log_path"
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
		log_info "Log: ${log_path}"
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
		if [[ -f "$log_path" ]]; then
			local log_size
			log_size=$(wc -c <"$log_path" | tr -d ' ')
			echo "  Log:      $log_path ($log_size bytes)"
			echo ""
			echo "  Last 5 log lines:"
			tail -5 "$log_path" 2>/dev/null | while IFS= read -r line; do
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
# Watch TODO.md for changes (platform-aware)
# On macOS: installs a WatchPaths LaunchAgent (no fswatch dependency)
# On Linux: uses fswatch (existing behaviour)
# Triggers auto-pickup + pulse on file modification
#######################################
cmd_watch() {
	local repo=""
	local uninstall=false

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
		--uninstall)
			uninstall=true
			shift
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
	local script_path="${SCRIPT_DIR}/supervisor-helper.sh"
	local watch_log="${SUPERVISOR_DIR}/watch.log"

	# Platform dispatch
	local backend
	backend="$(_get_scheduler_backend 2>/dev/null || echo "cron")"

	if [[ "$backend" == "launchd" ]]; then
		# macOS: use WatchPaths LaunchAgent (no fswatch required)
		if [[ "$uninstall" == "true" ]]; then
			launchd_uninstall_todo_watcher
			return $?
		fi

		if [[ ! -f "$todo_file" ]]; then
			log_error "TODO.md not found at $todo_file"
			return 1
		fi

		mkdir -p "$SUPERVISOR_DIR"
		launchd_install_todo_watcher \
			"$script_path" \
			"$todo_file" \
			"$repo" \
			"$watch_log"
		log_info "TODO.md watcher installed via launchd WatchPaths"
		log_info "Triggers: auto-pickup --repo $repo on every TODO.md change"
		log_info "Uninstall: supervisor-helper.sh watch --uninstall"
		return $?
	fi

	# Linux: fswatch backend (unchanged)
	if [[ "$uninstall" == "true" ]]; then
		log_info "On Linux, 'watch' runs in the foreground. Use Ctrl+C to stop."
		return 0
	fi

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
# Check if a task has unresolved blocked-by dependencies (t1243).
# Parses the blocked-by: field from a TODO.md task line and checks
# whether each blocker is completed ([x]) or declined ([-]) in TODO.md.
#
# Returns 0 (blocked) if any dependency is unresolved, outputting
# the unresolved blocker IDs to stdout. Returns 1 (not blocked)
# if all dependencies are resolved or no blocked-by: field exists.
#
# Args:
#   $1 - task line from TODO.md
#   $2 - path to TODO.md file
#
# Stdout: comma-separated unresolved blocker IDs (only on return 0)
# Returns: 0 = blocked, 1 = not blocked
#######################################
is_task_blocked() {
	local task_line="$1"
	local todo_file="$2"

	# Extract blocked-by: field
	local blocked_by
	blocked_by=$(printf '%s' "$task_line" | grep -oE 'blocked-by:[^ ]+' | sed 's/blocked-by://' || true)

	if [[ -z "$blocked_by" ]]; then
		return 1 # No dependencies — not blocked
	fi

	# Check each dependency
	local unresolved=""
	local dep
	IFS=',' read -ra deps <<<"$blocked_by"
	for dep in "${deps[@]}"; do
		dep="${dep// /}"
		[[ -z "$dep" ]] && continue

		# Check if dependency is completed ([x]) or declined ([-]) in TODO.md
		if grep -qE "^[[:space:]]*- \[x\] ${dep}( |$)" "$todo_file" 2>/dev/null; then
			continue # Resolved
		fi
		if grep -qE "^[[:space:]]*- \[-\] ${dep}( |$)" "$todo_file" 2>/dev/null; then
			continue # Declined = resolved
		fi

		# Unresolved
		if [[ -n "$unresolved" ]]; then
			unresolved="${unresolved},${dep}"
		else
			unresolved="$dep"
		fi
	done

	if [[ -n "$unresolved" ]]; then
		echo "$unresolved"
		return 0 # Blocked
	fi

	return 1 # All resolved — not blocked
}

#######################################
# Check if a task is blocked by unresolved dependencies.
# Returns 0 (should skip) if blocked, 1 (should not skip) otherwise.
# Usage: _check_and_skip_if_blocked <line> <task_id> <todo_file>
#######################################
_check_and_skip_if_blocked() {
	local line
	line="$1"
	local task_id
	task_id="$2"
	local todo_file
	todo_file="$3"
	local unresolved_blockers

	if unresolved_blockers=$(is_task_blocked "$line" "$todo_file"); then
		log_info "  $task_id: blocked by unresolved dependencies ($unresolved_blockers) — skipping"
		return 0
	fi
	return 1
}

#######################################
# t1239: Cross-repo misregistration guard for auto-pickup.
# Returns 0 (skip) if the task_id is already registered in the DB
# under a DIFFERENT repo path than the one being scanned.
# This prevents subtasks or tasks from private repos from being
# picked up as if they belong to the current repo.
#
# Args:
#   $1 - task_id (e.g. t004.1)
#   $2 - current repo path being scanned
#
# Returns:
#   0 - task is misregistered (caller should skip)
#   1 - task is safe to register in this repo
#######################################
_is_cross_repo_misregistration() {
	local task_id="$1"
	local current_repo="$2"

	# Check if this task_id is already registered in the DB under a different repo
	local db_repo
	db_repo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$task_id")' LIMIT 1;" 2>/dev/null || echo "")

	if [[ -z "$db_repo" ]]; then
		# Not in DB yet — no misregistration possible at this stage
		return 1
	fi

	# Canonicalize paths for comparison
	local canonical_current canonical_db
	canonical_current=$(realpath "$current_repo" 2>/dev/null || echo "$current_repo")
	canonical_db=$(realpath "$db_repo" 2>/dev/null || echo "$db_repo")

	if [[ "$canonical_current" != "$canonical_db" ]]; then
		log_warn "  $task_id: cross-repo misregistration detected — already registered to $(basename "$canonical_db") but found in $(basename "$canonical_current") TODO.md — skipping (t1239)"
		return 0
	fi

	return 1
}

#######################################
# Scan TODO.md for tasks tagged #auto-dispatch or in a
# "Dispatch Queue" section. Auto-adds them to supervisor
# if not already tracked, then queues them for dispatch.
#
# Decision logic delegated to ai-pickup-decisions.sh (t1319).
# This function is now a thin wrapper that delegates to
# ai_auto_pickup() which uses AI judgment with deterministic
# fallback. The original ~460 lines of inline gating logic
# have been extracted to the GATHER→JUDGE→EXECUTE pipeline
# in ai-pickup-decisions.sh.
#
# Scheduler install/uninstall (cmd_cron, cmd_watch) and
# decomposition worker dispatch remain in this file.
#######################################
cmd_auto_pickup() {
	# Delegate to AI-powered pickup (with deterministic fallback)
	ai_auto_pickup "$@"
	return $?
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
