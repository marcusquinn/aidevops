#!/usr/bin/env bash
# utility.sh - General utility functions
#
# Functions for proof-logs, system monitoring, concurrency,
# dashboard, notifications, and misc helpers


#######################################
# Write a structured proof-log entry (t218)
#
# Records an immutable evidence record for task completion trust.
# Each entry captures: what happened, what evidence was used, and
# who/what made the decision. Used for audit trails, pipeline
# latency analysis (t219), and trust verification.
#
# Arguments (all via flags for clarity):
#   --task <id>           Task ID (required)
#   --event <type>        Event type (required): evaluate, complete, retry,
#                         blocked, failed, verify_pass, verify_fail,
#                         pr_review, merge, deploy, quality_gate,
#                         dispatch, escalate, self_heal
#   --stage <name>        Pipeline stage: evaluate, pr_review, review_triage,
#                         merging, deploying, verifying, etc.
#   --decision <text>     Decision made (e.g., "complete:PR_URL", "retry:rate_limited")
#   --evidence <text>     Evidence used (e.g., "exit_code=0, signal=FULL_LOOP_COMPLETE")
#   --maker <text>        Decision maker (e.g., "heuristic:tier1", "ai_eval:sonnet",
#                         "quality_gate", "human")
#   --pr-url <url>        PR URL if relevant
#   --duration <secs>     Duration of this stage in seconds
#   --metadata <json>     Additional JSON metadata
#
# Returns 0 on success, 1 on missing required args, silently succeeds
# if DB is unavailable (proof-logs are best-effort, never block pipeline).
#######################################
write_proof_log() {
	local task_id="" event="" stage="" decision="" evidence=""
	local maker="" pr_url="" duration="" metadata=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task)
			task_id="${2:-}"
			shift 2
			;;
		--event)
			event="${2:-}"
			shift 2
			;;
		--stage)
			stage="${2:-}"
			shift 2
			;;
		--decision)
			decision="${2:-}"
			shift 2
			;;
		--evidence)
			evidence="${2:-}"
			shift 2
			;;
		--maker)
			maker="${2:-}"
			shift 2
			;;
		--pr-url)
			pr_url="${2:-}"
			shift 2
			;;
		--duration)
			duration="${2:-}"
			shift 2
			;;
		--metadata)
			metadata="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Required fields
	if [[ -z "$task_id" || -z "$event" ]]; then
		return 1
	fi

	# Best-effort: don't block pipeline if DB is unavailable
	if [[ ! -f "${SUPERVISOR_DB:-}" ]]; then
		return 0
	fi

	# Escape all text fields for SQL safety
	local e_task e_event e_stage e_decision e_evidence e_maker e_pr e_meta
	e_task=$(sql_escape "$task_id")
	e_event=$(sql_escape "$event")
	e_stage=$(sql_escape "${stage:-}")
	e_decision=$(sql_escape "${decision:-}")
	e_evidence=$(sql_escape "${evidence:-}")
	e_maker=$(sql_escape "${maker:-}")
	e_pr=$(sql_escape "${pr_url:-}")
	e_meta=$(sql_escape "${metadata:-}")

	# Build INSERT with only non-empty optional fields
	local cols="task_id, event"
	local vals="'$e_task', '$e_event'"

	if [[ -n "$stage" ]]; then
		cols="$cols, stage"
		vals="$vals, '$e_stage'"
	fi
	if [[ -n "$decision" ]]; then
		cols="$cols, decision"
		vals="$vals, '$e_decision'"
	fi
	if [[ -n "$evidence" ]]; then
		cols="$cols, evidence"
		vals="$vals, '$e_evidence'"
	fi
	if [[ -n "$maker" ]]; then
		cols="$cols, decision_maker"
		vals="$vals, '$e_maker'"
	fi
	if [[ -n "$pr_url" ]]; then
		cols="$cols, pr_url"
		vals="$vals, '$e_pr'"
	fi
	if [[ -n "$duration" ]]; then
		cols="$cols, duration_secs"
		vals="$vals, $duration"
	fi
	if [[ -n "$metadata" ]]; then
		cols="$cols, metadata"
		vals="$vals, '$e_meta'"
	fi

	db "$SUPERVISOR_DB" "INSERT INTO proof_logs ($cols) VALUES ($vals);" 2>/dev/null || true

	log_verbose "proof-log: $task_id $event ${stage:+stage=$stage }${decision:+decision=$decision}"
	return 0
}

#######################################
# Calculate stage duration from the last proof-log entry for a task (t218)
# Returns duration in seconds between the last logged event and now.
# Used to measure pipeline stage latency for t219 analysis.
#######################################
_proof_log_stage_duration() {
	local task_id="$1"
	local stage="${2:-}"

	if [[ ! -f "${SUPERVISOR_DB:-}" ]]; then
		echo ""
		return 0
	fi

	local e_task
	e_task=$(sql_escape "$task_id")

	local last_ts=""
	if [[ -n "$stage" ]]; then
		local e_stage
		e_stage=$(sql_escape "$stage")
		last_ts=$(db "$SUPERVISOR_DB" "
            SELECT timestamp FROM proof_logs
            WHERE task_id = '$e_task' AND stage = '$e_stage'
            ORDER BY id DESC LIMIT 1;
        " 2>/dev/null || echo "")
	fi

	# Fallback: last event for this task regardless of stage
	if [[ -z "$last_ts" ]]; then
		last_ts=$(db "$SUPERVISOR_DB" "
            SELECT timestamp FROM proof_logs
            WHERE task_id = '$e_task'
            ORDER BY id DESC LIMIT 1;
        " 2>/dev/null || echo "")
	fi

	if [[ -z "$last_ts" ]]; then
		echo ""
		return 0
	fi

	local last_epoch now_epoch
	last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" "+%s" 2>/dev/null || date -d "$last_ts" "+%s" 2>/dev/null || echo "")
	now_epoch=$(date +%s)

	if [[ -n "$last_epoch" && -n "$now_epoch" ]]; then
		echo $((now_epoch - last_epoch))
	else
		echo ""
	fi
	return 0
}

# Check GitHub authentication in a way that works with GH_TOKEN env var.
# gh auth status may fail in cron even when GH_TOKEN is valid (keyring issues).
# This function checks GH_TOKEN first, then falls back to gh auth status.
check_gh_auth() {
	# Cache auth check result for 5 minutes to avoid repeated API calls.
	# Each pulse calls this 1-5 times; cron runs every 2-5 minutes.
	# Caching saves ~288 API calls/day at 2-min pulse intervals.
	local cache_file="${SUPERVISOR_DIR:-.}/.gh-auth-cache"
	local cache_ttl=300 # 5 minutes

	if [[ -f "$cache_file" ]]; then
		local cache_age
		local cache_mtime
		cache_mtime=$(stat -c '%Y' "$cache_file" 2>/dev/null || stat -f '%m' "$cache_file" 2>/dev/null || echo "0")
		cache_age=$(($(date +%s) - cache_mtime))
		if [[ "$cache_age" -lt "$cache_ttl" ]]; then
			local cached_result
			cached_result=$(cat "$cache_file" 2>/dev/null || echo "")
			if [[ "$cached_result" == "ok" ]]; then
				return 0
			fi
			# Cached failure — still retry in case token was refreshed
		fi
	fi

	# If GH_TOKEN is set, verify it works with a lightweight API call
	if [[ -n "${GH_TOKEN:-}" ]]; then
		if gh api user --jq '.login' >/dev/null 2>&1; then
			mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true
			echo "ok" >"$cache_file" 2>/dev/null || true
			return 0
		fi
	fi
	# Fall back to gh auth status (works interactively with keyring)
	if gh auth status >/dev/null 2>&1; then
		mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true
		echo "ok" >"$cache_file" 2>/dev/null || true
		return 0
	fi
	echo "fail" >"$cache_file" 2>/dev/null || true
	return 1
}

# Acquire the pulse lock. Returns 0 on success, 1 if another pulse is running.
acquire_pulse_lock() {
	# Attempt 1: try atomic mkdir directly (fast path, no races)
	if mkdir "$PULSE_LOCK_DIR" 2>/dev/null; then
		echo $$ >"$PULSE_LOCK_DIR/pid" 2>/dev/null || true
		return 0
	fi

	# Lock exists — check if it's stale (age > timeout) or held by a dead process.
	# To avoid TOCTOU races where two processes both detect a dead/stale holder,
	# both rm the lock, and both re-acquire: use atomic rename (mv) to claim the
	# stale lock exclusively, then clean up and retry mkdir.
	local should_break=false
	local break_reason=""

	# Check stale lock (age exceeds timeout)
	local lock_age=0
	local lock_mtime
	if [[ "$(uname)" == "Darwin" ]]; then
		lock_mtime=$(stat -f %m "$PULSE_LOCK_DIR" 2>/dev/null || echo "0")
	else
		lock_mtime=$(stat -c %Y "$PULSE_LOCK_DIR" 2>/dev/null || echo "0")
	fi
	local now_epoch
	now_epoch=$(date +%s)
	lock_age=$((now_epoch - lock_mtime))

	if [[ "$lock_age" -gt "$PULSE_LOCK_TIMEOUT" ]]; then
		should_break=true
		break_reason="stale (age: ${lock_age}s > timeout: ${PULSE_LOCK_TIMEOUT}s)"
	fi

	# Check dead holder process
	if [[ "$should_break" == "false" ]]; then
		local holder_pid
		holder_pid=$(cat "$PULSE_LOCK_DIR/pid" 2>/dev/null || echo "")
		if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
			should_break=true
			break_reason="dead holder (PID $holder_pid)"
		fi
	fi

	if [[ "$should_break" == "true" ]]; then
		# Atomically rename the stale lock to a unique temp name.
		# mv on the same filesystem is atomic — only one process wins.
		local stale_dir="${PULSE_LOCK_DIR}.stale.$$"
		if mv "$PULSE_LOCK_DIR" "$stale_dir" 2>/dev/null; then
			# We won the rename race — clean up and retry
			log_warn "Breaking pulse lock ($break_reason)"
			rm -rf "$stale_dir"
			if mkdir "$PULSE_LOCK_DIR" 2>/dev/null; then
				echo $$ >"$PULSE_LOCK_DIR/pid" 2>/dev/null || true
				return 0
			fi
		fi
		# Another process won the rename race or re-acquired first — fall through
	fi

	return 1
}

# Release the pulse lock. Safe to call multiple times.
release_pulse_lock() {
	# Only release if we own the lock (PID matches)
	local holder_pid
	holder_pid=$(cat "$PULSE_LOCK_DIR/pid" 2>/dev/null || echo "")
	if [[ "$holder_pid" == "$$" ]]; then
		rm -rf "$PULSE_LOCK_DIR"
	fi
	return 0
}

#######################################
# Get the number of CPU cores on this system
# Returns integer count on stdout
#######################################
get_cpu_cores() {
	if [[ "$(uname)" == "Darwin" ]]; then
		sysctl -n hw.logicalcpu 2>/dev/null || echo 4
	elif [[ -f /proc/cpuinfo ]]; then
		grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 4
	else
		nproc 2>/dev/null || echo 4
	fi
	return 0
}

#######################################
# Check system load and resource pressure (t135.15)
#
# Outputs key=value pairs:
#   load_1m, load_5m, load_15m  - Load averages
#   cpu_cores                    - Logical CPU count
#   load_ratio                   - Actual CPU usage percentage (0-100)
#                                  On macOS: from `top` (100 - idle%), accurate
#                                  On Linux: from /proc/stat or load average fallback
#                                  NOTE: Previously used load_avg/cores which is
#                                  misleading on macOS — load average includes I/O
#                                  wait and uninterruptible sleep, not just CPU.
#   process_count                - Total system processes
#   supervisor_process_count     - Processes spawned by supervisor workers
#   memory_pressure              - low|medium|high (macOS) or free MB (Linux)
#   overloaded                   - true|false (cpu_usage > threshold)
#
# $1 (optional): max load factor (default: 2, used for Linux fallback only)
#######################################
check_system_load() {
	local max_load_factor="${1:-2}"

	local cpu_cores
	cpu_cores=$(get_cpu_cores)
	echo "cpu_cores=$cpu_cores"

	# Load averages (cross-platform, kept for logging/display)
	local load_1m="0" load_5m="0" load_15m="0"
	if [[ "$(uname)" == "Darwin" ]]; then
		local load_str
		load_str=$(sysctl -n vm.loadavg 2>/dev/null || echo "{ 0.00 0.00 0.00 }")
		load_1m=$(echo "$load_str" | awk '{print $2}')
		load_5m=$(echo "$load_str" | awk '{print $3}')
		load_15m=$(echo "$load_str" | awk '{print $4}')
	elif [[ -f /proc/loadavg ]]; then
		read -r load_1m load_5m load_15m _ </proc/loadavg
	else
		local uptime_str
		uptime_str=$(uptime 2>/dev/null || echo "")
		if [[ -n "$uptime_str" ]]; then
			load_1m=$(echo "$uptime_str" | grep -oE 'load average[s]?: [0-9.]+' | grep -oE '[0-9.]+$' || echo "0")
			load_5m=$(echo "$uptime_str" | awk -F'[, ]+' '{print $(NF-1)}' || echo "0")
			load_15m=$(echo "$uptime_str" | awk -F'[, ]+' '{print $NF}' || echo "0")
		fi
	fi
	echo "load_1m=$load_1m"
	echo "load_5m=$load_5m"
	echo "load_15m=$load_15m"

	# Actual CPU usage (the PRIMARY metric for throttling decisions)
	# On macOS, load average is misleading — it includes processes in
	# uninterruptible sleep (I/O wait, Backblaze, Spotlight, etc.),
	# so load avg of 150 on 10 cores can coexist with 35% idle CPU.
	# Use `top -l 1` to get real CPU idle percentage instead.
	local load_ratio=0
	if [[ "$(uname)" == "Darwin" ]]; then
		local cpu_idle_pct
		# Use -l 2 and take the LAST sample: top's first sample is cumulative
		# since boot, the second is the actual current interval delta.
		cpu_idle_pct=$(top -l 2 -n 0 -s 1 2>/dev/null | awk '/CPU usage/ {gsub(/%/,""); for(i=1;i<=NF;i++) if($(i+1)=="idle") idle=int($i)} END {print idle}')
		if [[ -n "$cpu_idle_pct" && "$cpu_idle_pct" -ge 0 ]]; then
			load_ratio=$((100 - cpu_idle_pct))
		else
			# Fallback to load average if top fails
			if [[ "$cpu_cores" -gt 0 ]]; then
				load_ratio=$(awk "BEGIN {printf \"%d\", ($load_1m / $cpu_cores) * 100}")
			fi
		fi
	elif [[ "$cpu_cores" -gt 0 ]]; then
		# Linux: use load average ratio (load avg includes only runnable processes)
		load_ratio=$(awk "BEGIN {printf \"%d\", ($load_1m / $cpu_cores) * 100}")
	fi
	echo "load_ratio=$load_ratio"

	# Total process count
	local process_count=0
	process_count=$(ps aux 2>/dev/null | wc -l | tr -d ' ')
	echo "process_count=$process_count"

	# Supervisor worker process count (opencode workers spawned by supervisor)
	local supervisor_process_count=0
	if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
		for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
			[[ -f "$pid_file" ]] || continue
			local wpid
			wpid=$(cat "$pid_file")
			if kill -0 "$wpid" 2>/dev/null; then
				# Count this worker + all its descendants
				local desc_count
				desc_count=$(_list_descendants "$wpid" 2>/dev/null | wc -l | tr -d ' ')
				supervisor_process_count=$((supervisor_process_count + 1 + desc_count))
			fi
		done
	fi
	echo "supervisor_process_count=$supervisor_process_count"

	# Memory pressure
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS: use memory_pressure command for system-wide free percentage
		# vm_stat "Pages free" is misleading — macOS keeps it near zero by design,
		# using inactive/purgeable/compressed pages as available memory instead.
		local pressure="low"
		local free_pct=100
		local mp_output
		mp_output=$(memory_pressure 2>/dev/null || echo "")
		if [[ -n "$mp_output" ]]; then
			free_pct=$(echo "$mp_output" | grep -oE 'free percentage: [0-9]+' | grep -oE '[0-9]+' || echo "100")
		fi
		if [[ "$free_pct" -lt 10 ]]; then
			pressure="high"
		elif [[ "$free_pct" -lt 25 ]]; then
			pressure="medium"
		fi
		echo "memory_pressure=$pressure"
	else
		# Linux: parse /proc/meminfo
		local mem_available_kb=0
		if [[ -f /proc/meminfo ]]; then
			mem_available_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
		fi
		local mem_available_mb=$((mem_available_kb / 1024))
		echo "memory_pressure=${mem_available_mb}MB"
	fi

	# Overloaded check: CPU usage > 85% (real saturation)
	# On macOS load_ratio is now actual CPU% (0-100), not load_avg/cores*100
	# On Linux load_ratio is still load_avg/cores*100 (threshold adjusted)
	if [[ "$(uname)" == "Darwin" ]]; then
		if [[ "$load_ratio" -gt 85 ]]; then
			echo "overloaded=true"
		else
			echo "overloaded=false"
		fi
	else
		local threshold=$((cpu_cores * max_load_factor * 100))
		if [[ "$load_ratio" -gt "$threshold" ]]; then
			echo "overloaded=true"
		else
			echo "overloaded=false"
		fi
	fi

	return 0
}

#######################################
# Get the physical memory footprint of a process in MB (t264)
# On macOS: uses footprint(1) for phys_footprint (what Activity Monitor shows)
# On Linux: reads /proc/PID/status VmRSS (resident set size)
# Returns: footprint in MB on stdout, or 0 if process not found
#
# $1: PID to measure
#######################################
get_process_footprint_mb() {
	local pid="$1"

	# Verify process exists
	if ! kill -0 "$pid" 2>/dev/null; then
		echo "0"
		return 0
	fi

	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS: footprint --pid gives phys_footprint (dirty + swapped + compressed)
		# This matches what Activity Monitor displays
		local fp_output
		fp_output=$(footprint --pid "$pid" -f bytes --noCategories 2>/dev/null || echo "")
		if [[ -n "$fp_output" ]]; then
			local fp_bytes
			fp_bytes=$(echo "$fp_output" | grep -oE 'phys_footprint: [0-9]+' | grep -oE '[0-9]+' || echo "")
			if [[ -n "$fp_bytes" && "$fp_bytes" -gt 0 ]] 2>/dev/null; then
				echo "$((fp_bytes / 1048576))"
				return 0
			fi
			# Fallback: parse the Footprint line (e.g., "Footprint: 30 GB" or "Footprint: 500 MB")
			local fp_line
			fp_line=$(echo "$fp_output" | grep -E 'Footprint:' | head -1)
			if [[ -n "$fp_line" ]]; then
				local fp_val fp_unit
				fp_val=$(echo "$fp_line" | grep -oE '[0-9]+' | head -1)
				fp_unit=$(echo "$fp_line" | grep -oE '(GB|MB|KB)' | head -1)
				case "$fp_unit" in
				GB) echo "$((fp_val * 1024))" ;;
				MB) echo "$fp_val" ;;
				KB) echo "$((fp_val / 1024))" ;;
				*) echo "0" ;;
				esac
				return 0
			fi
		fi
		# Final fallback: RSS from ps (underestimates — doesn't include swapped pages)
		local rss_kb
		rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
		if [[ -n "$rss_kb" && "$rss_kb" -gt 0 ]] 2>/dev/null; then
			echo "$((rss_kb / 1024))"
			return 0
		fi
	else
		# Linux: VmRSS from /proc (closest to physical footprint)
		if [[ -f "/proc/$pid/status" ]]; then
			local vm_rss_kb
			vm_rss_kb=$(awk '/VmRSS/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
			if [[ -n "$vm_rss_kb" && "$vm_rss_kb" -gt 0 ]] 2>/dev/null; then
				echo "$((vm_rss_kb / 1024))"
				return 0
			fi
		fi
		# Fallback: RSS from ps
		local rss_kb
		rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
		if [[ -n "$rss_kb" && "$rss_kb" -gt 0 ]] 2>/dev/null; then
			echo "$((rss_kb / 1024))"
			return 0
		fi
	fi

	echo "0"
	return 0
}

#######################################
# Check if the supervisor's own cron process should trigger a respawn (t264)
# The supervisor runs via cron every 2 minutes. Each invocation is a fresh
# process, so the supervisor itself doesn't accumulate memory. However,
# long-running interactive OpenCode sessions (used as supervisor monitors)
# DO accumulate WebKit malloc pages. This function checks the PARENT
# process chain for bloated OpenCode instances and logs a warning.
#
# For cron-based supervisors: no action needed (each pulse is fresh).
# For interactive sessions: logs a recommendation to restart.
#
# $1 (optional): threshold in MB (default: SUPERVISOR_SELF_MEM_LIMIT or 8192)
# Returns: 0 if healthy, 1 if respawn recommended
#######################################
check_supervisor_memory() {
	local threshold_mb="${1:-${SUPERVISOR_SELF_MEM_LIMIT:-8192}}"

	# Check our own process footprint
	local self_footprint
	self_footprint=$(get_process_footprint_mb $$)

	if [[ "$self_footprint" -gt "$threshold_mb" ]] 2>/dev/null; then
		log_warn "Supervisor process (PID $$) footprint ${self_footprint}MB exceeds ${threshold_mb}MB"
		log_warn "Recommendation: restart the supervisor session to reclaim memory"
		return 1
	fi

	# Check if we're running inside an interactive OpenCode session
	# by walking up the process tree looking for opencode processes
	local check_pid=$$
	local depth=0
	while [[ "$check_pid" -gt 1 && "$depth" -lt 10 ]] 2>/dev/null; do
		local parent_pid
		parent_pid=$(ps -o ppid= -p "$check_pid" 2>/dev/null | tr -d ' ')
		[[ -z "$parent_pid" || "$parent_pid" == "0" ]] && break

		local parent_cmd
		parent_cmd=$(ps -o comm= -p "$parent_pid" 2>/dev/null || echo "")
		if [[ "$parent_cmd" == *"opencode"* ]]; then
			local parent_footprint
			parent_footprint=$(get_process_footprint_mb "$parent_pid")
			if [[ "$parent_footprint" -gt "$threshold_mb" ]] 2>/dev/null; then
				log_warn "Parent OpenCode session (PID $parent_pid) footprint ${parent_footprint}MB exceeds ${threshold_mb}MB"
				log_warn "WebKit/Bun malloc accumulates dirty pages that are never freed"
				log_warn "Recommendation: save session state and restart OpenCode to reclaim ${parent_footprint}MB"

				# Write a respawn marker file for external tooling to detect
				local respawn_marker="${SUPERVISOR_DIR}/respawn-recommended"
				{
					echo "pid=$parent_pid"
					echo "footprint_mb=$parent_footprint"
					echo "threshold_mb=$threshold_mb"
					echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
					echo "reason=webkit_malloc_accumulation"
				} >"$respawn_marker"

				return 1
			fi
		fi

		check_pid="$parent_pid"
		depth=$((depth + 1))
	done

	# Clean up stale respawn marker if we're healthy
	rm -f "${SUPERVISOR_DIR}/respawn-recommended" 2>/dev/null || true

	return 0
}

#######################################
# Log a respawn event to persistent history (t264.1)
# Appends a structured line to respawn-history.log for pattern analysis.
# Each line: timestamp | pid | footprint_mb | threshold_mb | reason | batch_id | uptime
#
# $1: PID of the process being respawned
# $2: footprint in MB
# $3: threshold in MB
# $4: reason (e.g., "batch_complete_memory_exceeded")
# $5: batch_id (optional)
#######################################
log_respawn_event() {
	local pid="$1"
	local footprint_mb="$2"
	local threshold_mb="$3"
	local reason="$4"
	local batch_id="${5:-none}"

	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	local uptime_str="unknown"
	uptime_str=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ' || echo "unknown")

	mkdir -p "$(dirname "$RESPAWN_LOG")" 2>/dev/null || true
	echo "${timestamp}|${pid}|${footprint_mb}MB|${threshold_mb}MB|${reason}|batch:${batch_id}|uptime:${uptime_str}" >>"$RESPAWN_LOG"

	log_info "Respawn logged: PID=$pid footprint=${footprint_mb}MB reason=$reason batch=$batch_id uptime=$uptime_str"
	return 0
}

#######################################
# Check if supervisor should respawn after a batch wave completes (t264.1)
# Conditions: no running/queued tasks AND memory exceeds threshold.
# If triggered: saves checkpoint, logs respawn event, exits cleanly.
# The next cron pulse (2 min) starts fresh with zero accumulated memory.
#
# $1: batch_id (optional)
# Returns: 0 if respawn was triggered (caller should exit), 1 if no respawn needed
#######################################
attempt_respawn_after_batch() {
	local batch_id="${1:-}"
	local threshold_mb="${SUPERVISOR_SELF_MEM_LIMIT:-8192}"

	# Only respawn if there are no running or queued tasks
	local active_count=0
	if [[ -n "$batch_id" ]]; then
		active_count=$(db "$SUPERVISOR_DB" "
            SELECT COUNT(*) FROM tasks
            WHERE batch_id = '$(sql_escape "$batch_id")'
            AND status IN ('queued', 'dispatched', 'running', 'evaluating', 'retrying');
        " 2>/dev/null || echo "0")
	else
		active_count=$(db "$SUPERVISOR_DB" "
            SELECT COUNT(*) FROM tasks
            WHERE status IN ('queued', 'dispatched', 'running', 'evaluating', 'retrying');
        " 2>/dev/null || echo "0")
	fi

	if [[ "$active_count" -gt 0 ]]; then
		log_verbose "  Phase 11: $active_count tasks still active, skipping respawn check"
		return 1
	fi

	# Check if we're inside an interactive session with high memory
	local check_pid=$$
	local depth=0
	while [[ "$check_pid" -gt 1 && "$depth" -lt 10 ]] 2>/dev/null; do
		local parent_pid
		parent_pid=$(ps -o ppid= -p "$check_pid" 2>/dev/null | tr -d ' ')
		[[ -z "$parent_pid" || "$parent_pid" == "0" ]] && break

		local parent_cmd
		parent_cmd=$(ps -o comm= -p "$parent_pid" 2>/dev/null || echo "")
		if [[ "$parent_cmd" == *"opencode"* || "$parent_cmd" == *"claude"* ]]; then
			local parent_footprint
			parent_footprint=$(get_process_footprint_mb "$parent_pid" 2>/dev/null || echo "0")

			if [[ "$parent_footprint" -gt "$threshold_mb" ]] 2>/dev/null; then
				log_warn "  Phase 11: Batch complete + memory ${parent_footprint}MB > ${threshold_mb}MB — triggering respawn"

				# Log the respawn event to persistent history
				log_respawn_event "$parent_pid" "$parent_footprint" "$threshold_mb" \
					"batch_complete_memory_exceeded" "$batch_id"

				# Save checkpoint so next session can resume
				if [[ -x "$SESSION_CHECKPOINT_HELPER" ]]; then
					local next_tasks_summary=""
					next_tasks_summary=$(db "$SUPERVISOR_DB" "
                        SELECT id || ': ' || COALESCE(description, 'no description')
                        FROM tasks WHERE status IN ('queued', 'blocked')
                        ORDER BY id LIMIT 5;
                    " 2>/dev/null || echo "none pending")

					"$SESSION_CHECKPOINT_HELPER" save \
						--task "supervisor-respawn" \
						--batch "${batch_id:-none}" \
						--note "Auto-respawn after batch completion. Memory: ${parent_footprint}MB exceeded ${threshold_mb}MB threshold. Reason: WebKit/Bun malloc accumulation. Next cron pulse will start fresh." \
						--next "$next_tasks_summary" \
						2>>"$SUPERVISOR_LOG" || true
					log_info "  Phase 11: Checkpoint saved for respawn continuity"
				fi

				# Write respawn marker (signals the parent session to restart)
				local respawn_marker="${SUPERVISOR_DIR}/respawn-recommended"
				{
					echo "pid=$parent_pid"
					echo "footprint_mb=$parent_footprint"
					echo "threshold_mb=$threshold_mb"
					echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
					echo "reason=batch_complete_memory_exceeded"
					echo "batch_id=${batch_id:-none}"
					echo "action=respawn_triggered"
				} >"$respawn_marker"

				return 0
			fi
		fi

		check_pid="$parent_pid"
		depth=$((depth + 1))
	done

	# Cron-based pulse or memory within threshold — no respawn needed
	return 1
}

#######################################
# Show respawn history log (t264.1)
# Displays the persistent log of all respawn events with optional filtering.
#######################################
cmd_respawn_history() {
	local lines="${1:-20}"

	echo -e "${BOLD}=== Respawn History (t264.1) ===${NC}"
	echo -e "  Log: ${RESPAWN_LOG}"
	echo ""

	if [[ ! -f "$RESPAWN_LOG" ]]; then
		echo "  No respawn events recorded yet."
		return 0
	fi

	local total
	total=$(wc -l <"$RESPAWN_LOG" | tr -d ' ')
	echo -e "  Total events: ${total}"
	echo -e "  Showing last ${lines}:"
	echo ""
	echo -e "  ${DIM}TIMESTAMP                  | PID    | FOOTPRINT | THRESHOLD | REASON                          | BATCH        | UPTIME${NC}"
	echo -e "  ${DIM}$(printf '%.0s-' {1..120})${NC}"

	tail -n "$lines" "$RESPAWN_LOG" | while IFS='|' read -r ts pid fp thresh reason batch uptime; do
		printf "  %-26s | %-6s | %-9s | %-9s | %-31s | %-12s | %s\n" \
			"$ts" "$pid" "$fp" "$thresh" "$reason" "$batch" "$uptime"
	done

	return 0
}

#######################################
# Calculate adaptive concurrency based on system load (t135.15.2)
# Returns the recommended concurrency limit on stdout
#
# Strategy (bidirectional scaling, using actual CPU usage):
#   On macOS, load_ratio = actual CPU usage % (0-100) from `top`.
#   On Linux, load_ratio = load_avg / cores * 100 (traditional).
#
#   - CPU < 40%:  scale UP (base * 2, capped at max_concurrency)
#   - CPU 40-70%: use base concurrency (no change)
#   - CPU 70-85%: reduce by 50%
#   - CPU > 85%:  reduce to minimum floor
#   - Memory pressure high: reduce to minimum floor
#   - Minimum floor is 1 (allows at least 1 worker always)
#   - Maximum cap defaults to cpu_cores (prevents runaway scaling)
#
# $1: base concurrency (from batch or global default)
# $2: max load factor (default: 2, Linux fallback only)
# $3: max concurrency cap (default: cpu_cores, hard upper limit)
#######################################
calculate_adaptive_concurrency() {
	local base_concurrency="${1:-4}"
	local max_load_factor="${2:-2}"
	local max_concurrency_cap="${3:-0}"
	local min_concurrency=1

	local load_output
	load_output=$(check_system_load "$max_load_factor")

	local cpu_cores load_ratio memory_pressure overloaded
	cpu_cores=$(echo "$load_output" | grep '^cpu_cores=' | cut -d= -f2)
	load_ratio=$(echo "$load_output" | grep '^load_ratio=' | cut -d= -f2)
	memory_pressure=$(echo "$load_output" | grep '^memory_pressure=' | cut -d= -f2)
	overloaded=$(echo "$load_output" | grep '^overloaded=' | cut -d= -f2)

	# Default max cap to cpu_cores if not specified
	if [[ "$max_concurrency_cap" -le 0 ]]; then
		max_concurrency_cap="$cpu_cores"
	fi

	local effective_concurrency="$base_concurrency"

	# High memory pressure: drop to minimum floor
	if [[ "$memory_pressure" == "high" ]]; then
		effective_concurrency="$min_concurrency"
		echo "$effective_concurrency"
		return 0
	fi

	if [[ "$overloaded" == "true" ]]; then
		# Severely overloaded (CPU > 85%): minimum floor
		effective_concurrency="$min_concurrency"
	elif [[ "$load_ratio" -gt 70 ]]; then
		# Heavy load (CPU 70-85%): halve concurrency
		effective_concurrency=$(((base_concurrency + 1) / 2))
	elif [[ "$load_ratio" -lt 40 ]]; then
		# Light load (CPU < 40%): scale up to double base
		effective_concurrency=$((base_concurrency * 2))
	fi
	# else: CPU 40-70% — use base_concurrency as-is

	# Enforce minimum floor
	if [[ "$effective_concurrency" -lt "$min_concurrency" ]]; then
		effective_concurrency="$min_concurrency"
	fi

	# Enforce maximum cap
	if [[ "$effective_concurrency" -gt "$max_concurrency_cap" ]]; then
		effective_concurrency="$max_concurrency_cap"
	fi

	echo "$effective_concurrency"
	return 0
}

#######################################
# Find the project root (directory containing TODO.md) (t165)
# Walks up from $PWD until it finds TODO.md or hits /.
# Outputs the path on stdout, returns 1 if not found.
#######################################
find_project_root() {
	local dir="$PWD"
	while [[ "$dir" != "/" ]]; do
		if [[ -f "$dir/TODO.md" ]]; then
			echo "$dir"
			return 0
		fi
		dir="$(dirname "$dir")"
	done
	log_error "No TODO.md found in directory tree"
	return 1
}

#######################################
# Detect GitHub repo slug from git remote (t165)
# Handles both HTTPS and SSH remote URLs.
# $1: project_root (directory with .git)
# Outputs "owner/repo" on stdout, returns 1 if not detected.
#######################################
detect_repo_slug() {
	local project_root="${1:-.}"
	local remote_url
	remote_url=$(git -C "$project_root" remote get-url origin 2>/dev/null || echo "")
	remote_url="${remote_url%.git}"
	local slug
	slug=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|' || echo "")
	if [[ -z "$slug" ]]; then
		log_error "Could not detect GitHub repo slug from git remote"
		return 1
	fi
	echo "$slug"
	return 0
}

#######################################
# Command: proof-log — query and export proof-logs (t218)
#
# Usage:
#   supervisor-helper.sh proof-log <task_id>              Show proof-log for a task
#   supervisor-helper.sh proof-log <task_id> --json       Export as JSON
#   supervisor-helper.sh proof-log <task_id> --timeline   Show stage timing timeline
#   supervisor-helper.sh proof-log --recent [N]           Show N most recent entries (default 20)
#   supervisor-helper.sh proof-log --stats                Show aggregate statistics
#######################################
cmd_proof_log() {
	local task_id="" format="table" mode="task" limit_n=20

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			format="json"
			shift
			;;
		--timeline)
			mode="timeline"
			shift
			;;
		--recent)
			mode="recent"
			shift
			;;
		--stats)
			mode="stats"
			shift
			;;
		--limit)
			limit_n="${2:-20}"
			shift 2
			;;
		-*)
			log_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$task_id" ]]; then
				# Check if it's a number (for --recent N)
				if [[ "$mode" == "recent" && "$1" =~ ^[0-9]+$ ]]; then
					limit_n="$1"
				else
					task_id="$1"
				fi
			fi
			shift
			;;
		esac
	done

	ensure_db

	# Check if proof_logs table exists
	local has_table
	has_table=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='proof_logs';" 2>/dev/null || echo "0")
	if [[ "$has_table" -eq 0 ]]; then
		log_warn "No proof_logs table found. Run a pulse cycle to initialize."
		return 1
	fi

	case "$mode" in
	stats)
		echo "=== Proof-Log Statistics ==="
		echo ""
		local total_entries
		total_entries=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM proof_logs;" 2>/dev/null || echo "0")
		echo "Total entries: $total_entries"
		echo ""
		echo "Events by type:"
		db -column -header "$SUPERVISOR_DB" "
                SELECT event, count(*) as count
                FROM proof_logs
                GROUP BY event
                ORDER BY count DESC;
            " 2>/dev/null || true
		echo ""
		echo "Average stage durations (seconds):"
		db -column -header "$SUPERVISOR_DB" "
                SELECT stage, count(*) as samples,
                       CAST(avg(duration_secs) AS INTEGER) as avg_secs,
                       min(duration_secs) as min_secs,
                       max(duration_secs) as max_secs
                FROM proof_logs
                WHERE duration_secs IS NOT NULL AND duration_secs > 0
                GROUP BY stage
                ORDER BY avg_secs DESC;
            " 2>/dev/null || true
		echo ""
		echo "Tasks with most proof-log entries:"
		db -column -header "$SUPERVISOR_DB" "
                SELECT task_id, count(*) as entries,
                       min(timestamp) as first_event,
                       max(timestamp) as last_event
                FROM proof_logs
                GROUP BY task_id
                ORDER BY entries DESC
                LIMIT 10;
            " 2>/dev/null || true
		;;

	recent)
		if [[ "$format" == "json" ]]; then
			echo "["
			local first=true
			while IFS='|' read -r pid ptask pevent pstage pdecision pevidence pmaker ppr pdur pmeta pts; do
				[[ -z "$pid" ]] && continue
				if [[ "$first" != "true" ]]; then echo ","; fi
				first=false
				local _esc_evidence="${pevidence:-}"
				_esc_evidence="${_esc_evidence//\"/\\\"}"
				local _esc_meta="${pmeta:-}"
				_esc_meta="${_esc_meta//\"/\\\"}"
				printf '  {"id":%s,"task_id":"%s","event":"%s","stage":"%s","decision":"%s","evidence":"%s","decision_maker":"%s","pr_url":"%s","duration_secs":%s,"metadata":"%s","timestamp":"%s"}' \
					"$pid" "$ptask" "$pevent" "${pstage:-}" "${pdecision:-}" \
					"$_esc_evidence" \
					"${pmaker:-}" "${ppr:-}" "${pdur:-null}" \
					"$_esc_meta" "$pts"
			done < <(db -separator '|' "$SUPERVISOR_DB" "
                    SELECT id, task_id, event, stage, decision, evidence,
                           decision_maker, pr_url, duration_secs, metadata, timestamp
                    FROM proof_logs
                    ORDER BY id DESC
                    LIMIT $limit_n;
                " 2>/dev/null)
			echo ""
			echo "]"
		else
			db -column -header "$SUPERVISOR_DB" "
                    SELECT id, task_id, event, stage, decision, decision_maker, duration_secs, timestamp
                    FROM proof_logs
                    ORDER BY id DESC
                    LIMIT $limit_n;
                " 2>/dev/null || true
		fi
		;;

	timeline)
		if [[ -z "$task_id" ]]; then
			log_error "Usage: proof-log <task_id> --timeline"
			return 1
		fi
		local escaped_id
		escaped_id=$(sql_escape "$task_id")
		echo "=== Pipeline Timeline: $task_id ==="
		echo ""
		local entry_count=0
		while IFS='|' read -r pts pstage pevent pdecision pdur; do
			[[ -z "$pts" ]] && continue
			entry_count=$((entry_count + 1))
			local duration_label=""
			if [[ -n "$pdur" && "$pdur" != "" ]]; then
				duration_label=" (${pdur}s)"
			fi
			printf "  %s  %-18s  %-15s  %s%s\n" "$pts" "${pstage:-—}" "$pevent" "${pdecision:-}" "$duration_label"
		done < <(db -separator '|' "$SUPERVISOR_DB" "
                SELECT timestamp, stage, event, decision, duration_secs
                FROM proof_logs
                WHERE task_id = '$escaped_id'
                ORDER BY id ASC;
            " 2>/dev/null)
		if [[ "$entry_count" -eq 0 ]]; then
			echo "  No proof-log entries found for $task_id"
		fi
		echo ""
		# Show total pipeline duration
		local first_ts last_ts
		first_ts=$(db "$SUPERVISOR_DB" "SELECT timestamp FROM proof_logs WHERE task_id = '$escaped_id' ORDER BY id ASC LIMIT 1;" 2>/dev/null || echo "")
		last_ts=$(db "$SUPERVISOR_DB" "SELECT timestamp FROM proof_logs WHERE task_id = '$escaped_id' ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
		if [[ -n "$first_ts" && -n "$last_ts" && "$first_ts" != "$last_ts" ]]; then
			local first_epoch last_epoch
			first_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$first_ts" "+%s" 2>/dev/null || date -d "$first_ts" "+%s" 2>/dev/null || echo "")
			last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" "+%s" 2>/dev/null || date -d "$last_ts" "+%s" 2>/dev/null || echo "")
			if [[ -n "$first_epoch" && -n "$last_epoch" ]]; then
				local total_secs=$((last_epoch - first_epoch))
				local total_min=$((total_secs / 60))
				echo "  Total pipeline duration: ${total_min}m ${total_secs}s (${total_secs}s)"
			fi
		fi
		;;

	task)
		if [[ -z "$task_id" ]]; then
			log_error "Usage: proof-log <task_id> [--json|--timeline]"
			log_error "       proof-log --recent [N]"
			log_error "       proof-log --stats"
			return 1
		fi
		local escaped_id
		escaped_id=$(sql_escape "$task_id")

		if [[ "$format" == "json" ]]; then
			echo "["
			local first=true
			while IFS='|' read -r pid pevent pstage pdecision pevidence pmaker ppr pdur pmeta pts; do
				[[ -z "$pid" ]] && continue
				if [[ "$first" != "true" ]]; then echo ","; fi
				first=false
				local _esc_evidence="${pevidence:-}"
				_esc_evidence="${_esc_evidence//\"/\\\"}"
				local _esc_meta="${pmeta:-}"
				_esc_meta="${_esc_meta//\"/\\\"}"
				printf '  {"id":%s,"event":"%s","stage":"%s","decision":"%s","evidence":"%s","decision_maker":"%s","pr_url":"%s","duration_secs":%s,"metadata":"%s","timestamp":"%s"}' \
					"$pid" "$pevent" "${pstage:-}" "${pdecision:-}" \
					"$_esc_evidence" \
					"${pmaker:-}" "${ppr:-}" "${pdur:-null}" \
					"$_esc_meta" "$pts"
			done < <(db -separator '|' "$SUPERVISOR_DB" "
                    SELECT id, event, stage, decision, evidence,
                           decision_maker, pr_url, duration_secs, metadata, timestamp
                    FROM proof_logs
                    WHERE task_id = '$escaped_id'
                    ORDER BY id ASC;
                " 2>/dev/null)
			echo ""
			echo "]"
		else
			echo "=== Proof-Log: $task_id ==="
			echo ""
			db -column -header "$SUPERVISOR_DB" "
                    SELECT id, event, stage, decision, decision_maker, duration_secs, timestamp
                    FROM proof_logs
                    WHERE task_id = '$escaped_id'
                    ORDER BY id ASC;
                " 2>/dev/null || true
			echo ""
			local entry_count
			entry_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM proof_logs WHERE task_id = '$escaped_id';" 2>/dev/null || echo "0")
			echo "Total entries: $entry_count"
		fi
		;;
	esac

	return 0
}

cmd_dashboard() {
	local refresh_interval=2
	local batch_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--interval)
			[[ $# -lt 2 ]] && {
				log_error "--interval requires a value"
				return 1
			}
			refresh_interval="$2"
			shift 2
			;;
		--batch)
			[[ $# -lt 2 ]] && {
				log_error "--batch requires a value"
				return 1
			}
			batch_filter="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	# Terminal setup
	local term_cols term_rows
	term_cols=$(tput cols 2>/dev/null || echo 120)
	term_rows=$(tput lines 2>/dev/null || echo 40)

	# State
	local paused=false
	local scroll_offset=0
	local start_time
	start_time=$(date +%s)

	# Save terminal state and hide cursor
	tput smcup 2>/dev/null || true
	tput civis 2>/dev/null || true
	stty -echo -icanon min 0 time 0 2>/dev/null || true

	# Cleanup on exit
	_dashboard_cleanup() {
		tput rmcup 2>/dev/null || true
		tput cnorm 2>/dev/null || true
		stty echo icanon 2>/dev/null || true
	}
	trap _dashboard_cleanup EXIT INT TERM

	# Color helpers using tput for portability
	local c_reset c_bold c_dim c_red c_green c_yellow c_blue c_cyan c_magenta c_white c_bg_black
	c_reset=$(tput sgr0 2>/dev/null || printf '\033[0m')
	c_bold=$(tput bold 2>/dev/null || printf '\033[1m')
	c_dim=$(tput dim 2>/dev/null || printf '\033[2m')
	c_red=$(tput setaf 1 2>/dev/null || printf '\033[31m')
	c_green=$(tput setaf 2 2>/dev/null || printf '\033[32m')
	c_yellow=$(tput setaf 3 2>/dev/null || printf '\033[33m')
	c_blue=$(tput setaf 4 2>/dev/null || printf '\033[34m')
	c_cyan=$(tput setaf 6 2>/dev/null || printf '\033[36m')
	c_white=$(tput setaf 7 2>/dev/null || printf '\033[37m')

	# Format elapsed time as Xh Xm Xs
	_fmt_elapsed() {
		local secs="$1"
		local h=$((secs / 3600))
		local m=$(((secs % 3600) / 60))
		local s=$((secs % 60))
		if [[ "$h" -gt 0 ]]; then
			printf '%dh %dm %ds' "$h" "$m" "$s"
		elif [[ "$m" -gt 0 ]]; then
			printf '%dm %ds' "$m" "$s"
		else
			printf '%ds' "$s"
		fi
	}

	# Render a progress bar: _render_bar <current> <total> <width>
	_render_bar() {
		local current="$1" total="$2" width="${3:-30}"
		local filled=0
		if [[ "$total" -gt 0 ]]; then
			filled=$(((current * width) / total))
		fi
		local empty=$((width - filled))
		local pct=0
		if [[ "$total" -gt 0 ]]; then
			pct=$(((current * 100) / total))
		fi
		printf '%s' "${c_green}"
		local i
		for ((i = 0; i < filled; i++)); do printf '%s' "█"; done
		printf '%s' "${c_dim}"
		for ((i = 0; i < empty; i++)); do printf '%s' "░"; done
		printf '%s %3d%%' "${c_reset}" "$pct"
	}

	# Color for a task status
	_status_color() {
		local status="$1"
		case "$status" in
		running | dispatched) printf '%s' "${c_green}" ;;
		evaluating | retrying | pr_review | review_triage | merging | deploying | verifying) printf '%s' "${c_yellow}" ;;
		blocked | failed | verify_failed) printf '%s' "${c_red}" ;;
		complete | merged) printf '%s' "${c_cyan}" ;;
		deployed) printf '%s' "${c_green}${c_bold}" ;;
		verified) printf '%s' "${c_green}${c_bold}" ;;
		queued) printf '%s' "${c_white}" ;;
		cancelled) printf '%s' "${c_dim}" ;;
		*) printf '%s' "${c_reset}" ;;
		esac
	}

	# Status icon
	_status_icon() {
		local status="$1"
		case "$status" in
		running) printf '%s' ">" ;;
		dispatched) printf '%s' "~" ;;
		evaluating) printf '%s' "?" ;;
		retrying) printf '%s' "!" ;;
		complete) printf '%s' "+" ;;
		pr_review) printf '%s' "R" ;;
		review_triage) printf '%s' "T" ;;
		merging) printf '%s' "M" ;;
		merged) printf '%s' "=" ;;
		deploying) printf '%s' "D" ;;
		deployed) printf '%s' "*" ;;
		verifying) printf '%s' "V" ;;
		verified) printf '%s' "#" ;;
		verify_failed) printf '%s' "!" ;;
		blocked) printf '%s' "X" ;;
		failed) printf '%s' "x" ;;
		queued) printf '%s' "." ;;
		cancelled) printf '%s' "-" ;;
		*) printf '%s' " " ;;
		esac
	}

	# Truncate string to width
	_trunc() {
		local str="$1" max="$2"
		if [[ "${#str}" -gt "$max" ]]; then
			printf '%s' "${str:0:$((max - 1))}…"
		else
			printf '%-*s' "$max" "$str"
		fi
	}

	# Render one frame
	_render_frame() {
		# Refresh terminal size
		term_cols=$(tput cols 2>/dev/null || echo 120)
		term_rows=$(tput lines 2>/dev/null || echo 40)

		local now
		now=$(date +%s)
		local elapsed=$((now - start_time))

		# Move cursor to top-left, clear screen
		tput home 2>/dev/null || printf '\033[H'
		tput ed 2>/dev/null || printf '\033[J'

		local line=0
		local max_lines=$((term_rows - 1))

		# === HEADER ===
		local header_left="SUPERVISOR DASHBOARD"
		local header_right
		if [[ "$paused" == "true" ]]; then
			header_right="[PAUSED] $(date '+%H:%M:%S') | up $(_fmt_elapsed "$elapsed")"
		else
			header_right="$(date '+%H:%M:%S') | up $(_fmt_elapsed "$elapsed") | refresh ${refresh_interval}s"
		fi
		local header_pad=$((term_cols - ${#header_left} - ${#header_right}))
		[[ "$header_pad" -lt 1 ]] && header_pad=1
		printf '%s%s%s%*s%s%s\n' "${c_bold}${c_cyan}" "$header_left" "${c_reset}" "$header_pad" "" "${c_dim}" "$header_right${c_reset}"
		line=$((line + 1))

		# Separator
		printf '%s' "${c_dim}"
		printf '%*s' "$term_cols" '' | tr ' ' '─'
		printf '%s\n' "${c_reset}"
		line=$((line + 1))

		# === BATCH SUMMARY ===
		local batch_where=""
		if [[ -n "$batch_filter" ]]; then
			batch_where="AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$(sql_escape "$batch_filter")')"
		fi

		local counts
		counts=$(db "$SUPERVISOR_DB" "
            SELECT
                count(*) as total,
                sum(CASE WHEN t.status = 'queued' THEN 1 ELSE 0 END),
                sum(CASE WHEN t.status IN ('dispatched','running') THEN 1 ELSE 0 END),
                sum(CASE WHEN t.status = 'evaluating' THEN 1 ELSE 0 END),
                sum(CASE WHEN t.status = 'retrying' THEN 1 ELSE 0 END),
                sum(CASE WHEN t.status IN ('complete','pr_review','review_triage','merging','merged','deploying','deployed') THEN 1 ELSE 0 END),
                sum(CASE WHEN t.status IN ('blocked','failed') THEN 1 ELSE 0 END),
                sum(CASE WHEN t.status = 'cancelled' THEN 1 ELSE 0 END)
            FROM tasks t WHERE 1=1 $batch_where;
        " 2>/dev/null)

		local total queued active evaluating retrying finished errored cancelled
		IFS='|' read -r total queued active evaluating retrying finished errored cancelled <<<"$counts"
		total=${total:-0}
		queued=${queued:-0}
		active=${active:-0}
		evaluating=${evaluating:-0}
		retrying=${retrying:-0}
		finished=${finished:-0}
		errored=${errored:-0}
		cancelled=${cancelled:-0}

		# Batch info line
		local batch_label="All Tasks"
		if [[ -n "$batch_filter" ]]; then
			local batch_name
			batch_name=$(db "$SUPERVISOR_DB" "SELECT name FROM batches WHERE id = '$(sql_escape "$batch_filter")';" 2>/dev/null || echo "$batch_filter")
			batch_label="Batch: ${batch_name:-$batch_filter}"
		fi

		printf ' %s%s%s  ' "${c_bold}" "$batch_label" "${c_reset}"
		printf '%s%d total%s | ' "${c_white}" "$total" "${c_reset}"
		printf '%s%d queued%s | ' "${c_white}" "$queued" "${c_reset}"
		printf '%s%d active%s | ' "${c_green}" "$active" "${c_reset}"
		printf '%s%d eval%s | ' "${c_yellow}" "$evaluating" "${c_reset}"
		printf '%s%d retry%s | ' "${c_yellow}" "$retrying" "${c_reset}"
		printf '%s%d done%s | ' "${c_cyan}" "$finished" "${c_reset}"
		printf '%s%d err%s' "${c_red}" "$errored" "${c_reset}"
		if [[ "$cancelled" -gt 0 ]]; then
			printf ' | %s%d cancel%s' "${c_dim}" "$cancelled" "${c_reset}"
		fi
		printf '\n'
		line=$((line + 1))

		# Progress bar
		local completed_for_bar=$((finished + cancelled))
		printf ' Progress: '
		_render_bar "$completed_for_bar" "$total" 40
		printf '  (%d/%d)\n' "$completed_for_bar" "$total"
		line=$((line + 1))

		# Separator
		printf '%s' "${c_dim}"
		printf '%*s' "$term_cols" '' | tr ' ' '─'
		printf '%s\n' "${c_reset}"
		line=$((line + 1))

		# === TASK TABLE ===
		# Column widths (adaptive to terminal width)
		local col_icon=3 col_id=8 col_status=12 col_retry=7 col_pr=0 col_error=0
		local col_desc_min=20
		local remaining=$((term_cols - col_icon - col_id - col_status - col_retry - 8))

		# Allocate PR column if any tasks have PR URLs
		local has_prs
		has_prs=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE pr_url IS NOT NULL AND pr_url != '' $batch_where;" 2>/dev/null || echo 0)
		if [[ "$has_prs" -gt 0 ]]; then
			col_pr=12
			remaining=$((remaining - col_pr))
		fi

		# Allocate error column if any tasks have errors
		local has_errors
		has_errors=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE error IS NOT NULL AND error != '' $batch_where;" 2>/dev/null || echo 0)
		if [[ "$has_errors" -gt 0 ]]; then
			col_error=25
			remaining=$((remaining - col_error))
		fi

		local col_desc=$remaining
		[[ "$col_desc" -lt "$col_desc_min" ]] && col_desc=$col_desc_min

		# Table header
		printf ' %s' "${c_bold}${c_dim}"
		printf '%-*s' "$col_icon" " "
		printf '%-*s' "$col_id" "TASK"
		printf '%-*s' "$col_status" "STATUS"
		printf '%-*s' "$col_desc" "DESCRIPTION"
		printf '%-*s' "$col_retry" "RETRY"
		[[ "$col_pr" -gt 0 ]] && printf '%-*s' "$col_pr" "PR"
		[[ "$col_error" -gt 0 ]] && printf '%-*s' "$col_error" "ERROR"
		printf '%s\n' "${c_reset}"
		line=$((line + 1))

		# Fetch tasks
		local tasks
		tasks=$(db -separator '	' "$SUPERVISOR_DB" "
            SELECT t.id, t.status, t.description, t.retries, t.max_retries,
                   COALESCE(t.pr_url, ''), COALESCE(t.error, '')
            FROM tasks t
            WHERE 1=1 $batch_where
            ORDER BY
                CASE t.status
                    WHEN 'running' THEN 1
                    WHEN 'dispatched' THEN 2
                    WHEN 'evaluating' THEN 3
                    WHEN 'retrying' THEN 4
                    WHEN 'queued' THEN 5
                    WHEN 'pr_review' THEN 6
                    WHEN 'review_triage' THEN 7
                    WHEN 'merging' THEN 8
                    WHEN 'deploying' THEN 9
                    WHEN 'blocked' THEN 10
                    WHEN 'failed' THEN 11
                    WHEN 'complete' THEN 12
                    WHEN 'merged' THEN 13
                    WHEN 'deployed' THEN 14
                    WHEN 'cancelled' THEN 15
                END, t.created_at ASC;
        " 2>/dev/null)

		local task_count=0
		local visible_start=$scroll_offset
		local visible_rows=$((max_lines - line - 6))
		[[ "$visible_rows" -lt 3 ]] && visible_rows=3

		if [[ -n "$tasks" ]]; then
			local task_idx=0
			while IFS='	' read -r tid tstatus tdesc tretries tmax tpr terror; do
				task_count=$((task_count + 1))
				if [[ "$task_idx" -lt "$visible_start" ]]; then
					task_idx=$((task_idx + 1))
					continue
				fi
				if [[ "$task_idx" -ge $((visible_start + visible_rows)) ]]; then
					task_idx=$((task_idx + 1))
					continue
				fi

				local sc
				sc=$(_status_color "$tstatus")
				local si
				si=$(_status_icon "$tstatus")

				printf ' %s%s%s ' "$sc" "$si" "${c_reset}"
				printf '%-*s' "$col_id" "$tid"
				printf '%s%-*s%s' "$sc" "$col_status" "$tstatus" "${c_reset}"
				_trunc "${tdesc:-}" "$col_desc"
				printf ' '
				if [[ "$tretries" -gt 0 ]]; then
					printf '%s%d/%d%s' "${c_yellow}" "$tretries" "$tmax" "${c_reset}"
					local pad=$((col_retry - ${#tretries} - ${#tmax} - 1))
					[[ "$pad" -gt 0 ]] && printf '%*s' "$pad" ''
				else
					printf '%-*s' "$col_retry" "0/$tmax"
				fi
				if [[ "$col_pr" -gt 0 ]]; then
					if [[ -n "$tpr" ]]; then
						local pr_num
						pr_num=$(echo "$tpr" | grep -oE '[0-9]+$' || echo "$tpr")
						printf ' %s#%-*s%s' "${c_blue}" $((col_pr - 2)) "$pr_num" "${c_reset}"
					else
						printf ' %-*s' "$col_pr" ""
					fi
				fi
				if [[ "$col_error" -gt 0 && -n "$terror" ]]; then
					printf ' %s' "${c_red}"
					_trunc "$terror" "$col_error"
					printf '%s' "${c_reset}"
				fi
				printf '\n'
				line=$((line + 1))
				task_idx=$((task_idx + 1))
			done <<<"$tasks"
		else
			printf ' %s(no tasks)%s\n' "${c_dim}" "${c_reset}"
			line=$((line + 1))
		fi

		# Scroll indicator
		if [[ "$task_count" -gt "$visible_rows" ]]; then
			local scroll_end=$((scroll_offset + visible_rows))
			[[ "$scroll_end" -gt "$task_count" ]] && scroll_end=$task_count
			printf ' %s[%d-%d of %d tasks]%s\n' "${c_dim}" "$((scroll_offset + 1))" "$scroll_end" "$task_count" "${c_reset}"
			line=$((line + 1))
		fi

		# === SYSTEM RESOURCES ===
		# Only show if we have room
		if [[ "$line" -lt $((max_lines - 4)) ]]; then
			printf '%s' "${c_dim}"
			printf '%*s' "$term_cols" '' | tr ' ' '─'
			printf '%s\n' "${c_reset}"
			line=$((line + 1))

			local load_output
			load_output=$(check_system_load 2>/dev/null || echo "")

			if [[ -n "$load_output" ]]; then
				local sys_cores sys_load1 sys_load5 sys_load15 sys_procs sys_sup_procs sys_mem sys_overloaded sys_load_ratio
				sys_cores=$(echo "$load_output" | grep '^cpu_cores=' | cut -d= -f2)
				sys_load1=$(echo "$load_output" | grep '^load_1m=' | cut -d= -f2)
				sys_load5=$(echo "$load_output" | grep '^load_5m=' | cut -d= -f2)
				sys_load15=$(echo "$load_output" | grep '^load_15m=' | cut -d= -f2)
				sys_load_ratio=$(echo "$load_output" | grep '^load_ratio=' | cut -d= -f2)
				sys_procs=$(echo "$load_output" | grep '^process_count=' | cut -d= -f2)
				sys_sup_procs=$(echo "$load_output" | grep '^supervisor_process_count=' | cut -d= -f2)
				sys_mem=$(echo "$load_output" | grep '^memory_pressure=' | cut -d= -f2)
				sys_overloaded=$(echo "$load_output" | grep '^overloaded=' | cut -d= -f2)

				printf ' %sSYSTEM%s  ' "${c_bold}" "${c_reset}"
				printf 'CPU: %s%s%%%s (%s cores, load avg: %s/%s/%s)  ' \
					"$([[ "$sys_overloaded" == "true" ]] && printf '%s' "${c_red}${c_bold}" || printf '%s' "${c_green}")" \
					"$sys_load_ratio" "${c_reset}" "$sys_cores" "$sys_load1" "$sys_load5" "$sys_load15"
				printf 'Procs: %s (%s supervisor)  ' "$sys_procs" "$sys_sup_procs"
				printf 'Mem: %s%s%s' \
					"$([[ "$sys_mem" == "high" ]] && printf '%s' "${c_red}" || ([[ "$sys_mem" == "medium" ]] && printf '%s' "${c_yellow}" || printf '%s' "${c_green}"))" \
					"$sys_mem" "${c_reset}"
				if [[ "$sys_overloaded" == "true" ]]; then
					printf '  %s!! OVERLOADED !!%s' "${c_red}${c_bold}" "${c_reset}"
				fi
				printf '\n'
				line=$((line + 1))
			fi

			# Active workers with PIDs
			if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
				local worker_info=""
				local worker_count=0
				for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
					[[ -f "$pid_file" ]] || continue
					local wpid wtask_id
					wpid=$(cat "$pid_file")
					wtask_id=$(basename "$pid_file" .pid)
					if kill -0 "$wpid" 2>/dev/null; then
						worker_count=$((worker_count + 1))
						if [[ -n "$worker_info" ]]; then
							worker_info="$worker_info, "
						fi
						worker_info="${worker_info}${wtask_id}(pid:${wpid})"
					fi
				done
				if [[ "$worker_count" -gt 0 ]]; then
					printf ' %sWORKERS%s %d active: %s\n' "${c_bold}" "${c_reset}" "$worker_count" "$worker_info"
					line=$((line + 1))
				fi
			fi
		fi

		# === FOOTER ===
		# Move to last line
		local footer_line=$((max_lines))
		tput cup "$footer_line" 0 2>/dev/null || printf '\033[%d;0H' "$footer_line"
		printf '%s q%s=quit  %sp%s=pause  %sr%s=refresh  %sj/k%s=scroll  %s?%s=help' \
			"${c_bold}" "${c_reset}" "${c_bold}" "${c_reset}" "${c_bold}" "${c_reset}" \
			"${c_bold}" "${c_reset}" "${c_bold}" "${c_reset}"
	}

	# Main loop
	while true; do
		if [[ "$paused" != "true" ]]; then
			_render_frame
		fi

		# Read keyboard input (non-blocking)
		local key=""
		local wait_count=0
		local wait_max=$((refresh_interval * 10))

		while [[ "$wait_count" -lt "$wait_max" ]]; do
			key=""
			read -rsn1 -t 0.1 key 2>/dev/null || true

			case "$key" in
			q | Q)
				return 0
				;;
			p | P)
				if [[ "$paused" == "true" ]]; then
					paused=false
				else
					paused=true
					# Show paused indicator
					tput cup 0 $((term_cols - 10)) 2>/dev/null || true
					printf '%s[PAUSED]%s' "${c_yellow}${c_bold}" "${c_reset}"
				fi
				;;
			r | R)
				_render_frame
				wait_count=0
				;;
			j | J)
				local max_task_count
				max_task_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks;" 2>/dev/null || echo 0)
				if [[ "$scroll_offset" -lt $((max_task_count - 1)) ]]; then
					scroll_offset=$((scroll_offset + 1))
					_render_frame
				fi
				;;
			k | K)
				if [[ "$scroll_offset" -gt 0 ]]; then
					scroll_offset=$((scroll_offset - 1))
					_render_frame
				fi
				;;
			'?')
				tput home 2>/dev/null || printf '\033[H'
				tput ed 2>/dev/null || printf '\033[J'
				printf '%s%sSupervisor Dashboard Help%s\n\n' "${c_bold}" "${c_cyan}" "${c_reset}"
				printf '  %sq%s     Quit dashboard\n' "${c_bold}" "${c_reset}"
				printf '  %sp%s     Pause/resume auto-refresh\n' "${c_bold}" "${c_reset}"
				printf '  %sr%s     Force refresh now\n' "${c_bold}" "${c_reset}"
				printf '  %sj/k%s   Scroll task list down/up\n' "${c_bold}" "${c_reset}"
				printf '  %s?%s     Show this help\n\n' "${c_bold}" "${c_reset}"
				printf '%sStatus Icons:%s\n' "${c_bold}" "${c_reset}"
				printf '  %s>%s running  %s~%s dispatched  %s?%s evaluating  %s!%s retrying\n' \
					"${c_green}" "${c_reset}" "${c_green}" "${c_reset}" "${c_yellow}" "${c_reset}" "${c_yellow}" "${c_reset}"
				printf '  %s+%s complete %s=%s merged      %s*%s deployed    %s.%s queued\n' \
					"${c_cyan}" "${c_reset}" "${c_cyan}" "${c_reset}" "${c_green}" "${c_reset}" "${c_white}" "${c_reset}"
				printf '  %sX%s blocked  %sx%s failed      %s-%s cancelled   %sR%s pr_review\n' \
					"${c_red}" "${c_reset}" "${c_red}" "${c_reset}" "${c_dim}" "${c_reset}" "${c_yellow}" "${c_reset}"
				printf '  %sT%s triage   %sM%s merging     %sD%s deploying\n\n' \
					"${c_yellow}" "${c_reset}" "${c_yellow}" "${c_reset}" "${c_yellow}" "${c_reset}"
				printf 'Press any key to return...'
				read -rsn1 _ 2>/dev/null || true
				_render_frame
				wait_count=0
				;;
			esac

			wait_count=$((wait_count + 1))
		done
	done
}

#######################################
# TUI Dashboard - live-updating terminal UI for supervisor monitoring (t068.8)
#
# Renders a full-screen dashboard with:
#   - Header: batch name, uptime, refresh interval
#   - Task table: ID, status (color-coded), description, retries, PR URL
#   - Batch progress bar
#   - System resources: load, memory, worker processes
#   - Keyboard controls: q=quit, p=pause/resume, r=refresh, j/k=scroll
#
# Zero dependencies beyond bash + sqlite3 + tput (standard on macOS/Linux).
# Refreshes every N seconds (default 2). Reads from supervisor.db.
#######################################

#######################################
# Manually trigger queue health issue update (t1013)
# Usage: supervisor-helper.sh queue-health [--batch <id>]
# Forces an immediate update of the pinned queue health issue.
#######################################
cmd_queue_health() {
	local batch_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--batch)
			[[ $# -lt 2 ]] && {
				log_error "Missing batch ID"
				return 1
			}
			batch_id="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db
	log_info "Updating queue health issues..."
	local health_repos
	health_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks WHERE repo IS NOT NULL AND repo != '';" 2>/dev/null || echo "")
	if [[ -n "$health_repos" ]]; then
		while IFS= read -r health_repo; do
			[[ -z "$health_repo" ]] && continue
			local health_slug
			health_slug=$(detect_repo_slug "$health_repo" 2>/dev/null || echo "")
			[[ -z "$health_slug" ]] && continue
			update_queue_health_issue "$batch_id" "$health_slug" "$health_repo"
		done <<<"$health_repos"
	fi
	log_success "Queue health issues updated"
	return 0
}

#######################################
# Check supervisor session memory footprint (t264)
# Shows the footprint of this process and any parent OpenCode session.
# OpenCode/Bun accumulates WebKit malloc dirty pages that are never freed;
# the only reclaim path is process restart. Workers are short-lived and
# already cleaned up by Phase 4 — this command focuses on the long-running
# supervisor session that needs periodic respawn on compaction.
#######################################
cmd_mem_check() {
	local threshold_mb="${SUPERVISOR_SELF_MEM_LIMIT:-8192}"

	echo -e "${BOLD}=== Supervisor Session Memory (t264) ===${NC}"
	echo -e "  Respawn threshold: ${threshold_mb}MB (SUPERVISOR_SELF_MEM_LIMIT)"
	echo ""

	# This process (the bash script itself — trivial)
	local self_footprint
	self_footprint=$(get_process_footprint_mb $$ 2>/dev/null || echo "0")
	echo "  This process (PID $$): ${self_footprint}MB"

	# Walk up the process tree looking for parent OpenCode sessions
	local found_opencode=false
	local check_pid=$$
	local depth=0
	while [[ "$check_pid" -gt 1 && "$depth" -lt 10 ]] 2>/dev/null; do
		local parent_pid
		parent_pid=$(ps -o ppid= -p "$check_pid" 2>/dev/null | tr -d ' ')
		[[ -z "$parent_pid" || "$parent_pid" == "0" ]] && break

		local parent_cmd
		parent_cmd=$(ps -o comm= -p "$parent_pid" 2>/dev/null || echo "")
		if [[ "$parent_cmd" == *"opencode"* ]]; then
			found_opencode=true
			local parent_footprint
			parent_footprint=$(get_process_footprint_mb "$parent_pid")
			local uptime_str
			uptime_str=$(ps -o etime= -p "$parent_pid" 2>/dev/null | tr -d ' ' || echo "n/a")

			local fp_color="$GREEN"
			if [[ "$parent_footprint" -gt "$threshold_mb" ]] 2>/dev/null; then
				fp_color="$RED"
			elif [[ "$parent_footprint" -gt "$((threshold_mb / 2))" ]] 2>/dev/null; then
				fp_color="$YELLOW"
			fi

			echo -e "  Parent OpenCode (PID $parent_pid): ${fp_color}${parent_footprint}MB${NC}  uptime: $uptime_str"

			if [[ "$parent_footprint" -gt "$threshold_mb" ]] 2>/dev/null; then
				echo ""
				echo -e "  ${RED}RESPAWN RECOMMENDED${NC}"
				echo "    WebKit/Bun malloc accumulates dirty pages that are never freed."
				echo "    Trigger compaction or restart the session to reclaim ${parent_footprint}MB."
			fi
		fi

		check_pid="$parent_pid"
		depth=$((depth + 1))
	done

	if [[ "$found_opencode" == "false" ]]; then
		echo ""
		echo -e "  ${GREEN}No parent OpenCode session detected${NC} (cron-based pulse — each invocation is fresh)"
	fi

	# Check for respawn marker from previous pulse
	if [[ -f "${SUPERVISOR_DIR}/respawn-recommended" ]]; then
		echo ""
		echo -e "  ${YELLOW}Respawn marker present${NC} (from previous pulse):"
		while IFS= read -r line; do
			echo "    $line"
		done <"${SUPERVISOR_DIR}/respawn-recommended"
	fi

	# Show recent respawn history (t264.1)
	if [[ -f "$RESPAWN_LOG" ]]; then
		local respawn_count
		respawn_count=$(wc -l <"$RESPAWN_LOG" | tr -d ' ')
		echo ""
		echo -e "  ${BOLD}Respawn history:${NC} ${respawn_count} total events (use 'respawn-history' for full log)"
		echo -e "  Last 3:"
		tail -n 3 "$RESPAWN_LOG" | while IFS='|' read -r ts pid fp thresh reason batch uptime; do
			echo -e "    ${DIM}${ts}${NC} PID=${pid} ${fp} reason=${reason} ${batch} ${uptime}"
		done
	fi

	return 0
}

#######################################
# Send notification about task state change
# Uses mail-helper.sh and optionally matrix-dispatch-helper.sh
#######################################
send_task_notification() {
	local task_id="$1"
	local event_type="$2" # complete, blocked, failed
	local detail="${3:-}"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT description, repo, pr_url, error FROM tasks WHERE id = '$escaped_id';
    ")

	local tdesc trepo tpr terror
	IFS='|' read -r tdesc trepo tpr terror <<<"$task_row"

	local message=""
	case "$event_type" in
	complete)
		message="Task $task_id completed: ${tdesc:-no description}"
		if [[ -n "$tpr" ]]; then
			message="$message | PR: $tpr"
		fi
		;;
	blocked)
		message="Task $task_id BLOCKED: ${detail:-${terror:-unknown reason}} | ${tdesc:-no description}"
		;;
	failed)
		message="Task $task_id FAILED: ${detail:-${terror:-unknown reason}} | ${tdesc:-no description}"
		;;
	*)
		message="Task $task_id [$event_type]: ${detail:-${tdesc:-no description}}"
		;;
	esac

	# Send via mail-helper.sh (inter-agent mailbox)
	if [[ -x "$MAIL_HELPER" ]]; then
		local priority="normal"
		if [[ "$event_type" == "blocked" || "$event_type" == "failed" ]]; then
			priority="high"
		fi
		"$MAIL_HELPER" send \
			--to coordinator \
			--type status_report \
			--priority "$priority" \
			--payload "$message" 2>/dev/null || true
		log_info "Notification sent via mail: $event_type for $task_id"
	fi

	# Send via Matrix if configured
	local matrix_helper="${SCRIPT_DIR}/matrix-dispatch-helper.sh"
	if [[ -x "$matrix_helper" ]]; then
		local matrix_room
		matrix_room=$("$matrix_helper" mappings 2>/dev/null | head -1 | cut -d'|' -f1 | tr -d ' ' || true)
		if [[ -n "$matrix_room" ]]; then
			"$matrix_helper" test --room "$matrix_room" --message "$message" 2>/dev/null || true
			log_info "Notification sent via Matrix: $event_type for $task_id"
		fi
	fi

	# macOS audio alerts via afplay (reliable across all process contexts)
	# TTS (say) requires Accessibility permissions for Tabby/terminal app -
	# enable in System Settings > Privacy & Security > Accessibility
	if [[ "$(uname)" == "Darwin" ]]; then
		case "$event_type" in
		complete) afplay /System/Library/Sounds/Glass.aiff 2>/dev/null & ;;
		blocked) afplay /System/Library/Sounds/Basso.aiff 2>/dev/null & ;;
		failed) afplay /System/Library/Sounds/Sosumi.aiff 2>/dev/null & ;;
		esac
	fi

	return 0
}

#######################################
# Send a macOS notification for batch progress milestones
# Called from pulse summary when notable progress occurs
#######################################
notify_batch_progress() {
	local completed="$1"
	local total="$2"
	local failed="${3:-0}"
	local batch_name="${4:-batch}"

	[[ "$(uname)" != "Darwin" ]] && return 0

	local remaining=$((total - completed - failed))
	local message="${completed}/${total} done"
	if [[ "$failed" -gt 0 ]]; then
		message="$message, $failed failed"
	fi
	if [[ "$remaining" -gt 0 ]]; then
		message="$message, $remaining remaining"
	fi

	if [[ "$completed" -eq "$total" && "$failed" -eq 0 ]]; then
		message="All $total tasks complete!"
		nohup afplay /System/Library/Sounds/Hero.aiff &>/dev/null &
		nohup say "Batch complete. All $total tasks finished successfully." &>/dev/null &
	elif [[ "$remaining" -eq 0 ]]; then
		message="Batch finished: $message"
		nohup afplay /System/Library/Sounds/Purr.aiff &>/dev/null &
		nohup say "Batch finished. $completed of $total done. $failed failed." &>/dev/null &
	else
		nohup afplay /System/Library/Sounds/Pop.aiff &>/dev/null &
	fi

	return 0
}

#######################################
# Command: update-todo - manually trigger TODO.md update for a task

#######################################
# Command: notify - manually send notification for a task
#######################################
cmd_notify() {
	local task_id=""

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh notify <task_id>"
		return 1
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local tstatus
	tstatus=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';")

	if [[ -z "$tstatus" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local terror
	terror=$(db "$SUPERVISOR_DB" "SELECT error FROM tasks WHERE id = '$escaped_id';")

	send_task_notification "$task_id" "$tstatus" "${terror:-}"
	return 0
}
