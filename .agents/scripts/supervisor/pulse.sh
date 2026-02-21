#!/usr/bin/env bash
# pulse.sh - Supervisor pulse cycle functions
#
# Functions for the main pulse loop and post-PR lifecycle processing

#######################################
# Convert an ISO 8601 timestamp to a Unix epoch integer (t1249)
# Tries BSD date (-j -f), then GNU date (-d), falls back to 0.
# Args: $1 = ISO 8601 timestamp (e.g. "2026-02-19T08:00:00Z")
# Returns: epoch integer via stdout
#######################################
_iso_to_epoch() {
	local iso_ts="$1"
	date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso_ts" "+%s" 2>/dev/null ||
		date -d "$iso_ts" "+%s" 2>/dev/null ||
		echo "0"
}

#######################################
# Record a stale state recovery event to stale_recovery_log (t1202, t1249)
# Provides per-event metrics for observability and root-cause analysis.
# Args:
#   --task <id>                Task ID
#   --phase <phase>            Which phase detected it (0.7, 0.8, 1c)
#   --from <state>             Original stale state
#   --to <state>               State transitioned to
#   --stale-secs <N>           How long the task was stale
#   --root-cause <text>        Why the task got stuck (optional)
#   --had-pr <0|1>             Whether task had a PR (optional, default 0)
#   --retries <N>              Retry count at recovery time (optional, default 0)
#   --max-retries <N>          Max retries configured (optional, default 3)
#   --batch <id>               Batch ID (optional)
#   --worker-completed-at <ts> When the worker process finished (optional, t1249)
#   --eval-started-at <ts>     When evaluation began (optional, t1249)
#   --eval-lag-secs <N>        Gap between worker completion and eval start (optional, t1249)
#######################################
_record_stale_recovery() {
	local task_id="" phase="" from_state="" to_state="" stale_secs=0
	local root_cause="" had_pr=0 retries=0 max_retries=3 batch_id=""
	local worker_completed_at="" eval_started_at="" eval_lag_secs="NULL"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task)
			task_id="$2"
			shift 2
			;;
		--phase)
			phase="$2"
			shift 2
			;;
		--from)
			from_state="$2"
			shift 2
			;;
		--to)
			to_state="$2"
			shift 2
			;;
		--stale-secs)
			stale_secs="$2"
			shift 2
			;;
		--root-cause)
			root_cause="$2"
			shift 2
			;;
		--had-pr)
			had_pr="$2"
			shift 2
			;;
		--retries)
			retries="$2"
			shift 2
			;;
		--max-retries)
			max_retries="$2"
			shift 2
			;;
		--batch)
			batch_id="$2"
			shift 2
			;;
		--worker-completed-at)
			worker_completed_at="$2"
			shift 2
			;;
		--eval-started-at)
			eval_started_at="$2"
			shift 2
			;;
		--eval-lag-secs)
			eval_lag_secs="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	[[ -z "$task_id" || -z "$phase" || -z "$from_state" || -z "$to_state" ]] && return 0

	db "$SUPERVISOR_DB" "
		INSERT INTO stale_recovery_log
			(task_id, phase, from_state, to_state, stale_seconds, root_cause,
			 had_pr, had_live_worker, retries_at_recovery, max_retries, batch_id,
			 worker_completed_at, eval_started_at, eval_lag_seconds)
		VALUES (
			'$(sql_escape "$task_id")', '$(sql_escape "$phase")',
			'$(sql_escape "$from_state")', '$(sql_escape "$to_state")',
			$stale_secs, '$(sql_escape "$root_cause")',
			$had_pr, 0, $retries, $max_retries,
			'$(sql_escape "$batch_id")',
			'$(sql_escape "$worker_completed_at")', '$(sql_escape "$eval_started_at")',
			$eval_lag_secs);" 2>/dev/null || true
}

#######################################
# Diagnose root cause of a stale evaluating/running task (t1202, t1249)
# Checks log files, PID state, evaluate step artifacts, and timing data to
# determine why the task got stuck.
# Args: $1 = task_id, $2 = stale_status
# Returns: root cause string via stdout
# Side-effect: sets global _DIAG_WORKER_COMPLETED_AT, _DIAG_EVAL_STARTED_AT,
#              _DIAG_EVAL_LAG_SECS for the caller to capture timing data (t1249)
#######################################
_diagnose_stale_root_cause() {
	local task_id="$1"
	local stale_status="$2"
	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# t1249: Reset timing globals — caller reads these after the call
	_DIAG_WORKER_COMPLETED_AT=""
	_DIAG_EVAL_STARTED_AT=""
	_DIAG_EVAL_LAG_SECS="NULL"

	local log_file
	log_file=$(db "$SUPERVISOR_DB" "SELECT log_file FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

	# Check 1: No log file at all — dispatch likely failed
	if [[ -z "$log_file" || ! -f "$log_file" ]]; then
		echo "no_log_file"
		return 0
	fi

	# Check 2: Log file empty — worker never started
	local log_size
	log_size=$(wc -c <"$log_file" 2>/dev/null | tr -d ' ')
	if [[ "$log_size" -eq 0 ]]; then
		echo "empty_log_file"
		return 0
	fi

	# Check 3: For evaluating tasks, check if evaluation was attempted
	if [[ "$stale_status" == "evaluating" ]]; then
		# t1249: Capture timing data — how long between worker completion and eval start?
		local db_completed_at db_eval_started_at
		db_completed_at=$(db "$SUPERVISOR_DB" "SELECT completed_at FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
		db_eval_started_at=$(db "$SUPERVISOR_DB" "SELECT evaluating_started_at FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
		_DIAG_WORKER_COMPLETED_AT="$db_completed_at"
		_DIAG_EVAL_STARTED_AT="$db_eval_started_at"

		# Calculate eval lag if both timestamps are available
		if [[ -n "$db_completed_at" && -n "$db_eval_started_at" ]]; then
			local completed_epoch eval_epoch
			completed_epoch=$(_iso_to_epoch "$db_completed_at")
			eval_epoch=$(_iso_to_epoch "$db_eval_started_at")
			if [[ "$completed_epoch" -gt 0 && "$eval_epoch" -gt 0 ]]; then
				local lag=$((eval_epoch - completed_epoch))
				# Negative lag means evaluating_started_at was set before completed_at
				# (race condition: pulse transitioned to evaluating before worker set completed_at)
				_DIAG_EVAL_LAG_SECS="$lag"
				if [[ "$lag" -lt 0 ]]; then
					echo "eval_race_condition_negative_lag"
					return 0
				fi
				# Large positive lag (>30s) suggests the pulse was delayed picking up the worker
				if [[ "$lag" -gt 30 ]]; then
					echo "eval_delayed_pickup_lag_${lag}s"
					return 0
				fi
			fi
		elif [[ -z "$db_eval_started_at" && -n "$db_completed_at" ]]; then
			# Worker completed but evaluating_started_at was never set — transition to
			# evaluating happened before t1249 migration, or the transition was bypassed
			_DIAG_EVAL_LAG_SECS="NULL"
		fi

		# t1251/t1254/t1259: Check if evaluation is actively in progress via heartbeat.
		# MUST run BEFORE log content checks — if eval is actively running, we must
		# skip regardless of what error strings appear in the log (t1258 fix: the
		# previous ordering caused worker_failed_before_eval to fire on tasks that
		# were actively evaluating, bypassing this heartbeat guard entirely).
		# evaluate_with_ai() updates updated_at at the start of each AI eval call
		# and every 20s via a periodic background heartbeat (t1254).
		# t1259: Phase 1 also writes a pre-evaluation heartbeat immediately before
		# calling evaluate_worker(), ensuring updated_at is fresh even for fast-path
		# completions where evaluate_with_ai() is never called (tasks with
		# FULL_LOOP_COMPLETE signal or PR URL + clean exit). Without this, the
		# heartbeat window was anchored to cmd_transition("evaluating"), not the
		# actual start of evaluation.
		# heartbeat_window = eval_timeout * 2 + 60: defense-in-depth in case the
		# heartbeat process itself fails or is delayed. Under normal operation the
		# periodic heartbeat keeps updated_at fresh and a much smaller window would
		# suffice, but this wider window ensures Phase 0.7 does not fire if the
		# heartbeat subshell is unexpectedly killed or stalled.
		local eval_timeout_cfg="${SUPERVISOR_EVAL_TIMEOUT:-90}"
		local heartbeat_window=$((eval_timeout_cfg * 2 + 60))
		local db_updated_at
		db_updated_at=$(db "$SUPERVISOR_DB" "SELECT updated_at FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
		if [[ -n "$db_updated_at" ]]; then
			local updated_epoch now_epoch secs_since_update
			updated_epoch=$(_iso_to_epoch "$db_updated_at")
			now_epoch=$(date +%s 2>/dev/null || echo 0)
			if [[ "$updated_epoch" -gt 0 && "$now_epoch" -gt 0 ]]; then
				secs_since_update=$((now_epoch - updated_epoch))
				if [[ "$secs_since_update" -lt "$heartbeat_window" ]]; then
					echo "eval_in_progress_heartbeat_${secs_since_update}s"
					return 0
				fi
			fi
		fi

		# Check if the evaluate step left any error indicators in the log.
		# t1258: Only check the last 20 lines to avoid false positives from
		# REPROMPT METADATA headers that embed previous failure content (e.g.,
		# a retry log that includes WORKER_FAILED from the prior attempt).
		# Full-log grep caused worker_failed_before_eval false positives on
		# tasks that were actively evaluating their second or third attempt.
		if tail -20 "$log_file" 2>/dev/null | grep -q 'WORKER_FAILED\|DISPATCH_ERROR\|command not found'; then
			echo "worker_failed_before_eval"
			return 0
		fi

		# t1245: Check if PR URL was already persisted (early-persist checkpoint hit)
		# This means evaluate_worker() ran far enough to discover the PR but the pulse
		# was killed before cmd_transition("complete") — a clean recovery case.
		local db_pr_url
		db_pr_url=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
		if [[ -n "$db_pr_url" && "$db_pr_url" != "no_pr" && "$db_pr_url" != "task_only" ]]; then
			echo "pulse_killed_after_pr_persist"
			return 0
		fi

		# t1256: Check for eval checkpoint file — written by evaluate_with_ai() at
		# eval start and removed on completion. If it exists, the pulse was killed
		# mid-evaluation (SIGTERM, cron restart, system shutdown). This is a more
		# precise diagnosis than the generic "eval_process_died" fallback.
		local eval_checkpoint_dir="${SUPERVISOR_DIR}/eval-checkpoints"
		local eval_checkpoint_file="${eval_checkpoint_dir}/${task_id}.eval"
		if [[ -f "$eval_checkpoint_file" ]]; then
			echo "pulse_killed_mid_eval"
			return 0
		fi

		# t1258: Check supervisor log for AI eval activity — the worker log never
		# contains evaluate_with_ai (it's a supervisor function). The previous check
		# searched the wrong file and never matched, masking ai_eval_timeout cases.
		if [[ -n "${SUPERVISOR_LOG:-}" && -f "$SUPERVISOR_LOG" ]]; then
			if tail -100 "$SUPERVISOR_LOG" 2>/dev/null | grep -q "evaluate_with_ai.*${task_id}\|AI eval.*${task_id}"; then
				echo "ai_eval_timeout"
				return 0
			fi
		fi

		# Check if the pulse was killed mid-evaluation (no completion marker)
		echo "eval_process_died"
		return 0
	fi

	# Check 4: For running tasks, check for OOM/crash indicators
	if [[ "$stale_status" == "running" ]]; then
		if grep -q 'Killed\|OOM\|out of memory\|Cannot allocate' "$log_file" 2>/dev/null; then
			echo "worker_oom_killed"
			return 0
		fi
		if grep -q 'rate.limit\|429\|Too Many Requests' "$log_file" 2>/dev/null; then
			echo "worker_rate_limited"
			return 0
		fi
		echo "worker_died_unknown"
		return 0
	fi

	# Check 5: For dispatched tasks
	if [[ "$stale_status" == "dispatched" ]]; then
		echo "dispatch_never_started"
		return 0
	fi

	echo "unknown"
}

#######################################
# Stale GC report — observability into stale state recovery patterns (t1202)
# Shows frequency, root causes, and trends from stale_recovery_log.
# Args:
#   --days <N>    Look back N days (default: 7)
#   --json        Output as JSON
#######################################
cmd_stale_gc_report() {
	ensure_db

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

	# Check if table exists
	local has_table
	has_table=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='stale_recovery_log';" 2>/dev/null || echo "0")
	if [[ "$has_table" -eq 0 ]]; then
		echo "No stale_recovery_log table found. Run a pulse cycle first to initialize."
		return 0
	fi

	local total_events
	total_events=$(db "$SUPERVISOR_DB" "
		SELECT count(*) FROM stale_recovery_log
		WHERE created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days');
	" 2>/dev/null || echo "0")

	if [[ "$json_output" == "true" ]]; then
		# JSON output for programmatic consumption
		local json_result
		json_result=$(db -json "$SUPERVISOR_DB" "
			SELECT
				phase,
				from_state,
				to_state,
				root_cause,
				count(*) as event_count,
				avg(stale_seconds) as avg_stale_secs,
				max(stale_seconds) as max_stale_secs,
				sum(had_pr) as with_pr_count,
				avg(eval_lag_seconds) as avg_eval_lag_secs,
				max(eval_lag_seconds) as max_eval_lag_secs,
				count(eval_lag_seconds) as eval_lag_sample_count
			FROM stale_recovery_log
			WHERE created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days')
			GROUP BY phase, from_state, to_state, root_cause
			ORDER BY event_count DESC;
		" 2>/dev/null || echo "[]")
		echo "$json_result"
		return 0
	fi

	# Human-readable report
	echo "=== Stale State GC Report (last ${days} days) ==="
	echo ""
	echo "Total recovery events: $total_events"
	echo ""

	if [[ "$total_events" -eq 0 ]]; then
		echo "No stale state recoveries in the last ${days} days."
		return 0
	fi

	# Summary by phase
	echo "--- By Phase ---"
	db -column -header "$SUPERVISOR_DB" "
		SELECT
			phase AS Phase,
			count(*) AS Events,
			printf('%.0f', avg(stale_seconds)) AS 'Avg Stale (s)',
			max(stale_seconds) AS 'Max Stale (s)'
		FROM stale_recovery_log
		WHERE created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days')
		GROUP BY phase
		ORDER BY Events DESC;
	" 2>/dev/null || echo "(no data)"
	echo ""

	# Summary by root cause
	echo "--- By Root Cause ---"
	db -column -header "$SUPERVISOR_DB" "
		SELECT
			root_cause AS 'Root Cause',
			count(*) AS Events,
			printf('%.0f', avg(stale_seconds)) AS 'Avg Stale (s)'
		FROM stale_recovery_log
		WHERE created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days')
			AND root_cause != ''
		GROUP BY root_cause
		ORDER BY Events DESC;
	" 2>/dev/null || echo "(no data)"
	echo ""

	# Summary by from_state → to_state transition
	echo "--- State Transitions ---"
	db -column -header "$SUPERVISOR_DB" "
		SELECT
			from_state || ' → ' || to_state AS Transition,
			count(*) AS Events,
			sum(had_pr) AS 'With PR'
		FROM stale_recovery_log
		WHERE created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days')
		GROUP BY from_state, to_state
		ORDER BY Events DESC;
	" 2>/dev/null || echo "(no data)"
	echo ""

	# Most frequently stuck tasks (repeat offenders)
	echo "--- Repeat Offenders (tasks recovered 2+ times) ---"
	db -column -header "$SUPERVISOR_DB" "
		SELECT
			task_id AS Task,
			count(*) AS Recoveries,
			group_concat(DISTINCT root_cause) AS 'Root Causes',
			group_concat(DISTINCT phase) AS Phases
		FROM stale_recovery_log
		WHERE created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days')
		GROUP BY task_id
		HAVING count(*) >= 2
		ORDER BY Recoveries DESC
		LIMIT 10;
	" 2>/dev/null || echo "(none)"
	echo ""

	# t1249: Eval lag analysis — time between worker completion and evaluation start
	# Only shown when timing data is available (requires t1249 migration)
	local has_eval_lag_data
	has_eval_lag_data=$(db "$SUPERVISOR_DB" "
		SELECT count(*) FROM stale_recovery_log
		WHERE eval_lag_seconds IS NOT NULL
		AND created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days');
	" 2>/dev/null || echo "0")
	if [[ "$has_eval_lag_data" -gt 0 ]]; then
		echo "--- Eval Lag Analysis (t1249: worker completion → eval start) ---"
		db -column -header "$SUPERVISOR_DB" "
			SELECT
				root_cause AS 'Root Cause',
				count(*) AS Events,
				printf('%.1f', avg(eval_lag_seconds)) AS 'Avg Lag (s)',
				max(eval_lag_seconds) AS 'Max Lag (s)',
				min(eval_lag_seconds) AS 'Min Lag (s)'
			FROM stale_recovery_log
			WHERE eval_lag_seconds IS NOT NULL
			AND created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days')
			GROUP BY root_cause
			ORDER BY Events DESC;
		" 2>/dev/null || echo "(no data)"
		echo ""
	fi

	# t1252: Eval duration analysis — how long AI evaluation actually takes
	# Only shown when eval_duration_secs data is available (requires t1252 migration)
	local has_eval_duration_data
	has_eval_duration_data=$(db "$SUPERVISOR_DB" "
		SELECT count(*) FROM tasks
		WHERE eval_duration_secs IS NOT NULL
		AND updated_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days');
	" 2>/dev/null || echo "0")
	if [[ "$has_eval_duration_data" -gt 0 ]]; then
		echo "--- Eval Duration Analysis (t1252: AI evaluation step timing) ---"
		db -column -header "$SUPERVISOR_DB" "
			SELECT
				count(*) AS Evals,
				printf('%.1f', avg(eval_duration_secs)) AS 'Avg Duration (s)',
				max(eval_duration_secs) AS 'Max Duration (s)',
				min(eval_duration_secs) AS 'Min Duration (s)',
				sum(CASE WHEN eval_duration_secs >= 60 THEN 1 ELSE 0 END) AS 'Watchdog Threshold Exceeded'
			FROM tasks
			WHERE eval_duration_secs IS NOT NULL
			AND updated_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days');
		" 2>/dev/null || echo "(no data)"
		echo ""
	fi

	# t1256: Rate limit cooldown status — tasks currently deferred due to rate limiting
	local rate_limited_count
	rate_limited_count=$(db "$SUPERVISOR_DB" "
		SELECT count(*) FROM tasks
		WHERE status = 'queued'
		AND rate_limit_until IS NOT NULL
		AND rate_limit_until > strftime('%Y-%m-%dT%H:%M:%SZ','now');
	" 2>/dev/null || echo "0")
	if [[ "$rate_limited_count" -gt 0 ]]; then
		echo "--- Rate Limit Cooldown (t1256) ---"
		echo "Tasks currently deferred (rate_limit_until > now): $rate_limited_count"
		db -column -header "$SUPERVISOR_DB" "
			SELECT
				id AS Task,
				rate_limit_until AS 'Retry After',
				retries AS Retries
			FROM tasks
			WHERE status = 'queued'
			AND rate_limit_until IS NOT NULL
			AND rate_limit_until > strftime('%Y-%m-%dT%H:%M:%SZ','now')
			ORDER BY rate_limit_until ASC;
		" 2>/dev/null || echo "(no data)"
		echo ""
	fi

	# Daily trend
	echo "--- Daily Trend ---"
	db -column -header "$SUPERVISOR_DB" "
		SELECT
			date(created_at) AS Date,
			count(*) AS Events,
			count(DISTINCT task_id) AS 'Unique Tasks'
		FROM stale_recovery_log
		WHERE created_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days')
		GROUP BY date(created_at)
		ORDER BY Date DESC;
	" 2>/dev/null || echo "(no data)"

	return 0
}

#######################################
# Refresh updated_at for a task to extend Phase 0.7 heartbeat window (t1259)
# Args: $1 = task_id
#######################################
_update_task_heartbeat() {
	local task_id="$1"
	db "$SUPERVISOR_DB" "UPDATE tasks SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || true
}

#######################################
# Check if a task has had a prompt-repeat attempt (t1097)
# Args: $1 = task_id
# Returns: 0 if attempted, 1 if not
#######################################
_was_prompt_repeat_attempted() {
	local task_id="$1"
	local prompt_repeat_done
	prompt_repeat_done=$(db "$SUPERVISOR_DB" "SELECT COALESCE(prompt_repeat_done, 0) FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "0")
	if [[ "$prompt_repeat_done" -ge 1 ]]; then
		return 0
	fi
	return 1
}

#######################################
# Get per-task-type hang timeout in seconds (t1196)
# Args: $1 = task description (used to infer task type from tags/keywords)
# Returns: timeout in seconds via stdout
# Env overrides (all in seconds):
#   SUPERVISOR_TIMEOUT_TESTING    (default: 7200  — 2h, tests can be slow)
#   SUPERVISOR_TIMEOUT_REFACTOR   (default: 7200  — 2h, large refactors)
#   SUPERVISOR_TIMEOUT_FEATURE    (default: 5400  — 90m, typical feature work)
#   SUPERVISOR_TIMEOUT_BUGFIX     (default: 3600  — 1h, focused fixes)
#   SUPERVISOR_TIMEOUT_DOCS       (default: 1800  — 30m, documentation)
#   SUPERVISOR_TIMEOUT_SECURITY   (default: 5400  — 90m, security work)
#   SUPERVISOR_TIMEOUT_ARCHITECTURE (default: 7200 — 2h, architecture tasks)
#   SUPERVISOR_WORKER_TIMEOUT     (default: 3600  — fallback for unclassified tasks)
#######################################
get_task_timeout() {
	local task_desc="${1:-}"
	local desc_lower
	desc_lower=$(echo "$task_desc" | tr '[:upper:]' '[:lower:]')
	local tags
	tags=$(echo "$task_desc" | grep -oE '#[a-zA-Z][a-zA-Z0-9_-]*' | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' || echo "")

	# Testing tasks: integration tests, unit tests, e2e — can be legitimately slow
	if [[ "$tags" == *"#test"* || "$desc_lower" =~ add.*test|write.*test|run.*test|integration.*test|e2e ]]; then
		echo "${SUPERVISOR_TIMEOUT_TESTING:-7200}"
		return 0
	fi

	# Architecture tasks: large-scale design work
	if [[ "$tags" == *"#architecture"* || "$desc_lower" =~ architect ]]; then
		echo "${SUPERVISOR_TIMEOUT_ARCHITECTURE:-7200}"
		return 0
	fi

	# Refactor tasks: large code changes
	if [[ "$tags" == *"#refactor"* || "$desc_lower" =~ refactor ]]; then
		echo "${SUPERVISOR_TIMEOUT_REFACTOR:-7200}"
		return 0
	fi

	# Security tasks: audits, pentesting
	if [[ "$tags" == *"#security"* || "$desc_lower" =~ security ]]; then
		echo "${SUPERVISOR_TIMEOUT_SECURITY:-5400}"
		return 0
	fi

	# Feature/enhancement tasks: typical implementation work
	if [[ "$tags" == *"#feature"* || "$tags" == *"#enhancement"* || "$tags" == *"#self-improvement"* || "$desc_lower" =~ implement|add.*feature|new.*feature ]]; then
		echo "${SUPERVISOR_TIMEOUT_FEATURE:-5400}"
		return 0
	fi

	# Bugfix tasks: focused, should be faster
	if [[ "$tags" == *"#bugfix"* || "$tags" == *"#fix"* || "$desc_lower" =~ fix.*bug|bugfix|hotfix ]]; then
		echo "${SUPERVISOR_TIMEOUT_BUGFIX:-3600}"
		return 0
	fi

	# Docs tasks: documentation updates — fastest
	if [[ "$tags" == *"#docs"* || "$desc_lower" =~ update.*doc|add.*doc|documentation ]]; then
		echo "${SUPERVISOR_TIMEOUT_DOCS:-1800}"
		return 0
	fi

	# Default: use global SUPERVISOR_WORKER_TIMEOUT
	echo "${SUPERVISOR_WORKER_TIMEOUT:-3600}"
	return 0
}

#######################################
# Phase 0.9 helper: run sanity check for a single repo
# Extracted to avoid duplicating the open-task check + sanity-check + auto-pickup
# sequence for the multi-repo and single-repo code paths in cmd_pulse.
#######################################
_run_sanity_check_for_repo() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		return
	fi

	local open_count
	open_count=$(grep -cE '^\s*- \[ \] t[0-9]+' "$todo_file" 2>/dev/null || echo 0)
	if [[ "$open_count" -gt 0 ]]; then
		local sanity_fixed
		sanity_fixed=$(run_sanity_check "$repo_path" 2>>"$SUPERVISOR_LOG")
		if [[ "${sanity_fixed:-0}" -gt 0 ]]; then
			log_info "Phase 0.9: Sanity check fixed $sanity_fixed issue(s) in $repo_path — re-running auto-pickup"
			cmd_auto_pickup --repo "$repo_path" 2>>"$SUPERVISOR_LOG" || true
		fi
	fi
}

#######################################
# Supervisor pulse - stateless check and dispatch cycle
# Designed to run via cron every 5 minutes
#######################################
cmd_pulse() {
	local batch_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--batch)
			[[ $# -lt 2 ]] && {
				log_error "--batch requires a value"
				return 1
			}
			batch_id="$2"
			shift 2
			;;
		--no-self-heal)
			export SUPERVISOR_SELF_HEAL="false"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	# Resolve GH_TOKEN at runtime if not already set (t1260)
	# Previously baked into the launchd plist as plaintext — now resolved
	# from gh CLI keychain, gopass, or credential-helper at each pulse.
	if [[ -z "${GH_TOKEN:-}" ]]; then
		local _resolved_token=""
		# Try gh CLI (reads from macOS Keychain when user is logged in)
		if command -v gh &>/dev/null; then
			_resolved_token=$(gh auth token 2>/dev/null || true)
		fi
		# Fallback: gopass encrypted store
		if [[ -z "$_resolved_token" ]] && command -v gopass &>/dev/null; then
			_resolved_token=$(gopass show -o "aidevops/GH_TOKEN" 2>/dev/null || true)
		fi
		if [[ -n "$_resolved_token" ]]; then
			export GH_TOKEN="$_resolved_token"
		fi
	fi

	# Acquire pulse dispatch lock to prevent concurrent pulses from
	# independently dispatching workers and exceeding concurrency limits (t159)
	if ! acquire_pulse_lock; then
		log_warn "Another pulse is already running — skipping this invocation"
		return 0
	fi
	# Ensure lock is released and temp files cleaned on exit (normal, error, or signal)
	# shellcheck disable=SC2064
	trap "release_pulse_lock; rm -f '${SUPERVISOR_DIR}/MODELS.md.tmp' 2>/dev/null || true" EXIT INT TERM

	log_info "=== Supervisor Pulse $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

	# Pulse-level health check flag: once health is confirmed in this pulse,
	# skip subsequent checks to avoid 8-second probes per task
	_PULSE_HEALTH_VERIFIED=""

	# t1052: Defer batch post-completion actions (retrospective, session review,
	# distillation) until the end of the pulse cycle. Without this, when multiple
	# tasks auto-verify in a single pulse, check_batch_completion() runs expensive
	# actions after EACH task transition instead of once per batch.
	_PULSE_DEFER_BATCH_COMPLETION="true"
	_PULSE_DEFERRED_BATCH_IDS=""

	# Phase 0: Auto-pickup new tasks from TODO.md (t128.5)
	# Scans for #auto-dispatch tags and Dispatch Queue section
	local all_repos
	all_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks;" 2>/dev/null || true)
	if [[ -n "$all_repos" ]]; then
		while IFS= read -r repo_path; do
			if [[ -f "$repo_path/TODO.md" ]]; then
				cmd_auto_pickup --repo "$repo_path" 2>>"$SUPERVISOR_LOG" || true
			fi
		done <<<"$all_repos"
	else
		# No tasks yet - try current directory
		if [[ -f "$(pwd)/TODO.md" ]]; then
			cmd_auto_pickup --repo "$(pwd)" 2>>"$SUPERVISOR_LOG" || true
		fi
	fi

	# Phase 0.5: Task ID deduplication safety net (t303)
	# Detect and resolve duplicate task IDs in the supervisor DB
	# This catches collisions from concurrent task creation (offline mode, race conditions)
	local duplicate_ids
	duplicate_ids=$(db "$SUPERVISOR_DB" "
        SELECT id, COUNT(*) as cnt
        FROM tasks
        GROUP BY id
        HAVING cnt > 1;
    " 2>/dev/null || echo "")

	if [[ -n "$duplicate_ids" ]]; then
		log_warn "Phase 0.5: Duplicate task IDs detected, resolving..."
		while IFS='|' read -r dup_id dup_count; do
			[[ -z "$dup_id" ]] && continue
			log_warn "  Duplicate task ID: $dup_id (${dup_count} instances)"

			# Keep the oldest task (first created), mark others as cancelled
			local all_instances
			all_instances=$(db -separator '|' "$SUPERVISOR_DB" "
                SELECT rowid, created_at, status
                FROM tasks
                WHERE id = '$(sql_escape "$dup_id")'
                ORDER BY created_at ASC;
            " 2>/dev/null || echo "")

			local first_row=true
			while IFS='|' read -r rowid created_at status; do
				[[ -z "$rowid" ]] && continue
				if [[ "$first_row" == "true" ]]; then
					log_info "    Keeping: rowid=$rowid (created: $created_at, status: $status)"
					first_row=false
				else
					log_warn "    Cancelling duplicate: rowid=$rowid (created: $created_at, status: $status)"
					db "$SUPERVISOR_DB" "
                        UPDATE tasks
                        SET status = 'cancelled',
                            error = 'Duplicate task ID - cancelled by Phase 0.5 dedup (t303)',
                            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                        WHERE rowid = $rowid;
                    " 2>>"$SUPERVISOR_LOG" || true
				fi
			done <<<"$all_instances"
		done <<<"$duplicate_ids"
		log_success "Phase 0.5: Deduplication complete"
	fi

	# Phase 0.5b: Deduplicate task IDs in TODO.md (t319.4)
	# Scans for duplicate tNNN on multiple open `- [ ]` lines.
	# Keeps first occurrence, renames duplicates to t(max+1).
	if [[ -n "$all_repos" ]]; then
		while IFS= read -r repo_path; do
			if [[ -f "$repo_path/TODO.md" ]]; then
				dedup_todo_task_ids "$repo_path" 2>>"$SUPERVISOR_LOG" || true
			fi
		done <<<"$all_repos"
	else
		if [[ -f "$(pwd)/TODO.md" ]]; then
			dedup_todo_task_ids "$(pwd)" 2>>"$SUPERVISOR_LOG" || true
		fi
	fi

	# Phase 0.5c: DB→TODO.md cancelled/verified consistency check (t1139)
	# When the supervisor cancels tasks (e.g., Phase 0.5 dedup, Phase 3b2 obsolete PR),
	# the DB is updated but TODO.md still shows [ ]. This creates a persistent
	# inconsistency where cancelled tasks appear dispatchable, wasting reasoning cycles.
	# This phase proactively annotates TODO.md for any DB-cancelled tasks that are
	# still open in TODO.md. Runs every pulse (not gated on idle) because cancelled
	# tasks can appear mid-flight and should be cleaned up promptly.
	local repos_for_cancel_sync
	repos_for_cancel_sync=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks WHERE status = 'cancelled';" 2>/dev/null || true)
	if [[ -n "$repos_for_cancel_sync" ]]; then
		local cancel_synced=0
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			local todo_path="$repo_path/TODO.md"
			[[ ! -f "$todo_path" ]] && continue

			# Find cancelled tasks in DB that are still open in TODO.md
			local cancelled_tasks
			cancelled_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
				SELECT id, error FROM tasks
				WHERE status = 'cancelled'
				AND repo = '$(sql_escape "$repo_path")';
			" 2>/dev/null || true)

			if [[ -z "$cancelled_tasks" ]]; then
				continue
			fi

			while IFS='|' read -r ctid cerror; do
				[[ -z "$ctid" ]] && continue
				# Only act if task is still open ([ ]) in TODO.md
				if grep -qE "^[[:space:]]*- \[ \] ${ctid}( |$)" "$todo_path"; then
					log_info "  Phase 0.5c: $ctid cancelled in DB but open in TODO.md — annotating"
					update_todo_on_cancelled "$ctid" "${cerror:-cancelled by supervisor}" \
						2>>"$SUPERVISOR_LOG" || {
						log_warn "  Phase 0.5c: Failed to annotate $ctid"
						continue
					}
					cancel_synced=$((cancel_synced + 1))
				fi
			done <<<"$cancelled_tasks"
		done <<<"$repos_for_cancel_sync"

		if [[ "$cancel_synced" -gt 0 ]]; then
			log_success "Phase 0.5c: Synced $cancel_synced cancelled task(s) to TODO.md"
		else
			log_verbose "Phase 0.5c: No cancelled/TODO.md drift detected"
		fi
	else
		log_verbose "Phase 0.5c: No cancelled tasks in DB"
	fi

	# Phase 0.5d: Auto-unblock tasks with resolved blockers (t1243)
	# Scans TODO.md for open tasks with blocked-by: fields and checks whether
	# all blocking tasks are completed ([x]) or declined ([-]). If all blockers
	# are resolved, removes the blocked-by: field so the task becomes dispatchable.
	# Runs every pulse before Phase 0.6/Phase 2 so newly unblocked tasks are
	# immediately eligible for dispatch without manual intervention.
	if [[ -n "$all_repos" ]]; then
		while IFS= read -r repo_path; do
			if [[ -f "$repo_path/TODO.md" ]]; then
				auto_unblock_resolved_tasks "$repo_path" 2>>"$SUPERVISOR_LOG" || true
			fi
		done <<<"$all_repos"
	else
		if [[ -f "$(pwd)/TODO.md" ]]; then
			auto_unblock_resolved_tasks "$(pwd)" 2>>"$SUPERVISOR_LOG" || true
		fi
	fi

	# Phase 0.5e: Stale-claim auto-recovery (t1263)
	# When interactive sessions claim tasks (assignee: + started:) but die or
	# move on without completing them, the tasks become permanently stuck:
	# auto-pickup skips them because they have assignee/started fields, but no
	# worker is running. This phase detects stale claims (>24h, no active worker
	# or worktree) and strips assignee:/started: so auto-pickup can re-dispatch.
	# Respects t1017 assignee ownership: only unclaims tasks assigned to local user.
	if [[ -n "$all_repos" ]]; then
		while IFS= read -r repo_path; do
			if [[ -f "$repo_path/TODO.md" ]]; then
				recover_stale_claims "$repo_path" 2>>"$SUPERVISOR_LOG" || true
			fi
		done <<<"$all_repos"
	else
		if [[ -f "$(pwd)/TODO.md" ]]; then
			recover_stale_claims "$(pwd)" 2>>"$SUPERVISOR_LOG" || true
		fi
	fi

	# Phase 0.6: Queue-dispatchability reconciliation (t1180)
	# Syncs DB queue state with TODO.md reality to eliminate phantom queue entries.
	# Runs every pulse (not gated on idle) because phantom entries can appear
	# mid-flight and should be cleaned up promptly before Phase 2 dispatch.
	# Catches tasks that were queued in DB but whose TODO.md state diverged:
	#   - Completed ([x]) or cancelled ([-]) tasks still queued in DB
	#   - Tasks queued in DB but no longer tagged #auto-dispatch in TODO.md
	if [[ -n "$all_repos" ]]; then
		while IFS= read -r repo_path; do
			if [[ -f "$repo_path/TODO.md" ]]; then
				cmd_reconcile_queue_dispatchability --repo "$repo_path" \
					${batch_id:+--batch "$batch_id"} 2>>"$SUPERVISOR_LOG" || true
			fi
		done <<<"$all_repos"
	else
		if [[ -f "$(pwd)/TODO.md" ]]; then
			cmd_reconcile_queue_dispatchability --repo "$(pwd)" \
				${batch_id:+--batch "$batch_id"} 2>>"$SUPERVISOR_LOG" || true
		fi
	fi

	# Phase 0.7: Stale-state detection (t1132, enhanced t1202, t1250)
	# Detect tasks in active states (running/dispatched/evaluating) that have no
	# live worker process. This catches stale state from previous crashes, stuck
	# evaluations, or supervisor restarts where PID files were cleaned up but DB
	# state was not updated. Unlike Phase 4b (which only checks for missing PID
	# files), this phase also checks tasks WITH PID files whose PIDs are dead,
	# providing a comprehensive upfront consistency sweep.
	#
	# Grace periods (t1202): Evaluating uses a shorter grace period than
	# running/dispatched because evaluation is a supervisor-side operation
	# (seconds, not minutes). A task stuck in evaluating for >2min almost
	# certainly has a dead evaluation process.
	#   - SUPERVISOR_EVALUATING_GRACE_SECONDS (default 120 = 2 min)
	#   - SUPERVISOR_STALE_GRACE_SECONDS (default 600 = 10 min) for running/dispatched
	#   - SUPERVISOR_FAST_PATH_EVALUATING_GRACE_SECONDS (default 30s) for evaluating+PR (t1259: was 10s)
	#   - SUPERVISOR_DEAD_PID_GRACE_SECONDS (default 60s) for running with dead PID
	#   - SUPERVISOR_RATE_LIMIT_COOLDOWN_SECONDS (default 300 = 5 min) for rate-limited tasks (t1256)
	#
	# Fast-path recovery (t1250): Two additional zero-grace queries eliminate the
	# most common stale-evaluating patterns without waiting for grace periods:
	#   1. evaluating + pr_url already persisted → immediate pr_review (no grace)
	#      Root cause: pulse killed after t1245 early-persist but before cmd_transition.
	#      The PR URL in the DB proves evaluate_worker() completed its critical work.
	#   2. running/dispatched + dead PID file → shorter grace (60s vs 600s)
	#      Root cause: worker died and PID file confirms it. No need to wait 10min.
	local stale_grace_seconds="${SUPERVISOR_STALE_GRACE_SECONDS:-600}"
	local evaluating_grace_seconds="${SUPERVISOR_EVALUATING_GRACE_SECONDS:-120}"
	local dead_pid_grace_seconds="${SUPERVISOR_DEAD_PID_GRACE_SECONDS:-60}"

	# Fast-path 1 (t1250): evaluating tasks with pr_url already persisted — recover
	# with a minimal grace (vs 120s standard). The PR URL proves evaluate_worker()
	# ran far enough to find the PR (t1245 early-persist checkpoint). Only the final
	# cmd_transition call was lost. A grace period avoids racing with the current
	# pulse's own evaluation (Phase 1 transitions to evaluating, then immediately
	# calls evaluate_worker — we don't want to recover a task that's actively
	# evaluating). t1259: Increased default from 10s to 30s — evaluate_worker()
	# can take 10-30s for PR discovery via GitHub API. A 10s grace caused false
	# recoveries when the task was actively being evaluated but updated_at was
	# 10-30s old (set by cmd_transition("evaluating"), not yet refreshed by the
	# t1259 pre-evaluation heartbeat). The heartbeat check in
	# _diagnose_stale_root_cause() provides the real protection (240s window);
	# this grace period is just a first-pass filter to avoid unnecessary work.
	local fast_path_evaluating_grace="${SUPERVISOR_FAST_PATH_EVALUATING_GRACE_SECONDS:-30}"
	local fast_path_evaluating_tasks
	fast_path_evaluating_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, status, updated_at FROM tasks
		WHERE status = 'evaluating'
		AND pr_url IS NOT NULL
		AND pr_url != ''
		AND pr_url != 'no_pr'
		AND pr_url != 'task_only'
		AND pr_url != 'task_obsolete'
		AND updated_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${fast_path_evaluating_grace} seconds')
		ORDER BY updated_at ASC;
	" 2>/dev/null || echo "")

	# Query evaluating tasks without PR URL — use standard grace period
	local stale_evaluating_tasks
	stale_evaluating_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, status, updated_at FROM tasks
		WHERE status = 'evaluating'
		AND (pr_url IS NULL OR pr_url = '' OR pr_url = 'no_pr' OR pr_url = 'task_only' OR pr_url = 'task_obsolete')
		AND updated_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${evaluating_grace_seconds} seconds')
		ORDER BY updated_at ASC;
	" 2>/dev/null || echo "")

	# Phase 0.7 no longer handles running/dispatched tasks — Phase 1 evaluates
	# those directly without an intermediate evaluating state. Phase 0.7 only
	# cleans up legacy evaluating tasks (from prior pulse versions or crashes).
	local stale_active_tasks=""
	local _parts=()
	[[ -n "$fast_path_evaluating_tasks" ]] && _parts+=("$fast_path_evaluating_tasks")
	[[ -n "$stale_evaluating_tasks" ]] && _parts+=("$stale_evaluating_tasks")
	if [[ "${#_parts[@]}" -gt 0 ]]; then
		stale_active_tasks=$(printf '%s\n' "${_parts[@]}")
	fi

	if [[ -n "$stale_active_tasks" ]]; then
		local stale_recovered=0
		local stale_skipped=0

		while IFS='|' read -r stale_id stale_status stale_updated; do
			[[ -z "$stale_id" ]] && continue

			# Check if a live worker process exists for this task
			local stale_pid_file="$SUPERVISOR_DIR/pids/${stale_id}.pid"
			local stale_has_live_worker=false

			if [[ -f "$stale_pid_file" ]]; then
				local stale_pid
				stale_pid=$(cat "$stale_pid_file" 2>/dev/null || echo "")
				if [[ -n "$stale_pid" ]] && kill -0 "$stale_pid" 2>/dev/null; then
					stale_has_live_worker=true
				fi
			fi

			if [[ "$stale_has_live_worker" == "true" ]]; then
				# Worker is alive — skip (Phase 1/4 will handle normally)
				stale_skipped=$((stale_skipped + 1))
				continue
			fi

			# Calculate how long the task has been stale (needed for fast-path guard below)
			local stale_secs=0
			if [[ -n "$stale_updated" ]]; then
				local updated_epoch
				updated_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$stale_updated" "+%s" 2>/dev/null || date -d "$stale_updated" "+%s" 2>/dev/null || echo "0")
				local now_epoch
				now_epoch=$(date "+%s")
				if [[ "$updated_epoch" -gt 0 ]]; then
					stale_secs=$((now_epoch - updated_epoch))
				fi
			fi

			# Fast-path 2 guard (t1250): for running/dispatched tasks in the short-grace
			# window (60-600s), only recover if a PID file exists with a dead PID.
			# Without a PID file, we can't confirm the worker is gone — it may still be
			# starting up. These tasks will be caught by the standard 600s grace query.
			if [[ "$stale_status" == "running" || "$stale_status" == "dispatched" ]]; then
				if [[ "$stale_secs" -lt "$stale_grace_seconds" && ! -f "$stale_pid_file" ]]; then
					stale_skipped=$((stale_skipped + 1))
					continue
				fi
			fi

			# Diagnose root cause (t1202, t1249)
			# _diagnose_stale_root_cause sets _DIAG_WORKER_COMPLETED_AT, _DIAG_EVAL_STARTED_AT,
			# _DIAG_EVAL_LAG_SECS as side-effects for timing instrumentation (t1249)
			local root_cause
			root_cause=$(_diagnose_stale_root_cause "$stale_id" "$stale_status")
			local diag_worker_completed_at="${_DIAG_WORKER_COMPLETED_AT:-}"
			local diag_eval_started_at="${_DIAG_EVAL_STARTED_AT:-}"
			local diag_eval_lag_secs="${_DIAG_EVAL_LAG_SECS:-NULL}"

			local stale_retries stale_max_retries stale_pr_url
			stale_retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$stale_id")';" 2>/dev/null || echo "0")
			stale_max_retries=$(db "$SUPERVISOR_DB" "SELECT max_retries FROM tasks WHERE id = '$(sql_escape "$stale_id")';" 2>/dev/null || echo "3")
			stale_pr_url=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$(sql_escape "$stale_id")';" 2>/dev/null || echo "")

			local had_pr_flag=0
			[[ -n "$stale_pr_url" && "$stale_pr_url" != "no_pr" && "$stale_pr_url" != "task_only" ]] && had_pr_flag=1

			# t1251: Skip recovery if evaluation is actively in progress (heartbeat check).
			# evaluate_with_ai() updates updated_at at the start of each AI eval call.
			# If the root cause is eval_in_progress_heartbeat_*, the task is not stuck —
			# it's actively evaluating. Recovering it would interrupt a live eval and
			# cause unnecessary re-queuing (the primary driver of the 73% stale rate).
			if [[ "$root_cause" == eval_in_progress_heartbeat_* ]]; then
				log_info "  Phase 0.7: $stale_id skipped — AI eval actively in progress ($root_cause)"
				stale_skipped=$((stale_skipped + 1))
				continue
			fi

			# No live worker — this is stale state. Transition based on retry eligibility.
			# Effective grace: fast-path (evaluating+PR) < evaluating < running/dispatched
			local effective_grace="$stale_grace_seconds"
			if [[ "$stale_status" == "evaluating" ]]; then
				if [[ "$had_pr_flag" -eq 1 ]]; then
					effective_grace="$fast_path_evaluating_grace"
				else
					effective_grace="$evaluating_grace_seconds"
				fi
			fi
			log_warn "  Phase 0.7: Stale $stale_status task $stale_id (updated: $stale_updated, ${stale_secs}s stale, grace: ${effective_grace}s, cause: $root_cause)"

			# Clean up any stale PID file
			if [[ -f "$stale_pid_file" ]]; then
				rm -f "$stale_pid_file" 2>/dev/null || true
			fi

			local recovery_to_state=""

			# t1145/t1250/t1258: If the stale task has a PR, route to pr_review instead of
			# re-queuing — the work is done, only evaluation (or the worker) died.
			# Applies to both 'evaluating' and 'running' states with a PR URL.
			# Fast-path evaluating tasks (with PR URL) arrive here with a 30s grace instead
			# of 120s, reducing the median recovery latency from ~120s to ~30s (t1259: was 10s).
			# Running tasks with a PR (e.g., worker_oom_killed after creating PR) previously
			# went to queued unnecessarily — they should go directly to pr_review (t1258).
			if [[ "$had_pr_flag" -eq 1 ]]; then
				recovery_to_state="pr_review"
				log_info "  Phase 0.7: $stale_id → pr_review (has PR, $stale_status process died, cause: $root_cause)"
				cmd_transition "$stale_id" "pr_review" --pr-url "$stale_pr_url" --error "Stale $stale_status recovery (Phase 0.7/t1145/t1250/t1258): process died, PR exists (cause: $root_cause)" 2>>"$SUPERVISOR_LOG" || true
				db "$SUPERVISOR_DB" "
					INSERT INTO state_log (task_id, from_state, to_state, reason)
					VALUES ('$(sql_escape "$stale_id")', '$(sql_escape "$stale_status")',
						'pr_review',
						'Phase 0.7 stale-state recovery (t1145/t1202/t1250/t1258): $stale_status with dead worker but PR exists — routed to pr_review (cause: $(sql_escape "$root_cause"))');
				" 2>/dev/null || true
			elif [[ "$stale_retries" -lt "$stale_max_retries" ]]; then
				# Retries remaining — re-queue for dispatch
				recovery_to_state="queued"
				local new_retries=$((stale_retries + 1))
				log_info "  Phase 0.7: $stale_id → queued (retry $new_retries/$stale_max_retries, was $stale_status, cause: $root_cause)"
				db "$SUPERVISOR_DB" "UPDATE tasks SET retries = $new_retries WHERE id = '$(sql_escape "$stale_id")';" 2>/dev/null || true
				# t1256: Rate limit cooldown — when the root cause is worker_rate_limited,
				# set rate_limit_until to prevent immediate re-dispatch into the same limit.
				# Default cooldown: 5 minutes (SUPERVISOR_RATE_LIMIT_COOLDOWN_SECONDS).
				# This addresses the #1 stale-evaluating root cause (29% of events).
				if [[ "$root_cause" == "worker_rate_limited" ]]; then
					local rate_limit_cooldown="${SUPERVISOR_RATE_LIMIT_COOLDOWN_SECONDS:-300}"
					db "$SUPERVISOR_DB" "UPDATE tasks SET rate_limit_until = strftime('%Y-%m-%dT%H:%M:%SZ','now','+${rate_limit_cooldown} seconds') WHERE id = '$(sql_escape "$stale_id")';" 2>/dev/null || true
					log_info "  Phase 0.7: $stale_id rate_limit_until set (+${rate_limit_cooldown}s cooldown, t1256)"
				fi
				cmd_transition "$stale_id" "queued" --error "Stale state recovery (Phase 0.7/t1132): was $stale_status with no live worker for >${effective_grace}s (cause: $root_cause)" 2>>"$SUPERVISOR_LOG" || true
				db "$SUPERVISOR_DB" "
					INSERT INTO state_log (task_id, from_state, to_state, reason)
					VALUES ('$(sql_escape "$stale_id")', '$(sql_escape "$stale_status")',
						'queued',
						'Phase 0.7 stale-state recovery (t1132/t1202): no live worker for >${effective_grace}s (cause: $(sql_escape "$root_cause"))');
				" 2>/dev/null || true
			else
				# Retries exhausted — mark as failed
				recovery_to_state="failed"
				log_warn "  Phase 0.7: $stale_id → failed (retries exhausted $stale_retries/$stale_max_retries, was $stale_status, cause: $root_cause)"
				cmd_transition "$stale_id" "failed" --error "Stale state recovery (Phase 0.7/t1132): was $stale_status with no live worker, retries exhausted ($stale_retries/$stale_max_retries, cause: $root_cause)" 2>>"$SUPERVISOR_LOG" || true
				attempt_self_heal "$stale_id" "failed" "Stale state: $stale_status with no live worker (cause: $root_cause)" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
				db "$SUPERVISOR_DB" "
					INSERT INTO state_log (task_id, from_state, to_state, reason)
					VALUES ('$(sql_escape "$stale_id")', '$(sql_escape "$stale_status")',
						'failed',
						'Phase 0.7 stale-state recovery (t1132/t1202): no live worker for >${effective_grace}s, retries exhausted (cause: $(sql_escape "$root_cause"))');
				" 2>/dev/null || true
			fi

			# Record metrics to stale_recovery_log (t1202, t1249)
			# Use phase "0.7fp" for fast-path recoveries (t1250) to distinguish
			# them from standard grace-period recoveries in observability reports.
			local _record_phase="0.7"
			[[ "$stale_status" == "evaluating" && "$had_pr_flag" -eq 1 && "$stale_secs" -lt "$evaluating_grace_seconds" ]] && _record_phase="0.7fp"
			_record_stale_recovery \
				--task "$stale_id" --phase "$_record_phase" \
				--from "$stale_status" --to "$recovery_to_state" \
				--stale-secs "$stale_secs" --root-cause "$root_cause" \
				--had-pr "$had_pr_flag" --retries "$stale_retries" \
				--max-retries "$stale_max_retries" --batch "${batch_id:-}" \
				--worker-completed-at "$diag_worker_completed_at" \
				--eval-started-at "$diag_eval_started_at" \
				--eval-lag-secs "$diag_eval_lag_secs"

			# Clean up worker process tree (in case of zombie children)
			cleanup_worker_processes "$stale_id" 2>>"$SUPERVISOR_LOG" || true

			# t1256: Clean up eval checkpoint file if it exists — the task has been
			# recovered, so the checkpoint is no longer needed. Prevents accumulation
			# of stale checkpoint files from pulse_killed_mid_eval recoveries.
			local stale_eval_checkpoint="${SUPERVISOR_DIR}/eval-checkpoints/${stale_id}.eval"
			if [[ -f "$stale_eval_checkpoint" ]]; then
				rm -f "$stale_eval_checkpoint" 2>/dev/null || true
				log_verbose "  Phase 0.7: removed eval checkpoint for $stale_id"
			fi

			stale_recovered=$((stale_recovered + 1))
		done <<<"$stale_active_tasks"

		if [[ "$stale_recovered" -gt 0 ]]; then
			log_success "  Phase 0.7: Recovered $stale_recovered stale task(s) ($stale_skipped still alive)"
			# Store pattern for observability
			local pattern_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
			if [[ -x "$pattern_helper" ]]; then
				"$pattern_helper" record \
					--type "SELF_HEAL_PATTERN" \
					--task "supervisor" \
					--model "n/a" \
					--detail "Phase 0.7 stale-state recovery (t1202/t1250): $stale_recovered tasks recovered (fp_eval_grace=${fast_path_evaluating_grace}s, eval_grace=${evaluating_grace_seconds}s, dead_pid_grace=${dead_pid_grace_seconds}s, other_grace=${stale_grace_seconds}s)" \
					2>/dev/null || true
			fi
		fi
	fi

	# Phase 0.8: REMOVED — running/dispatched tasks are now evaluated directly
	# by Phase 1 without an intermediate evaluating state. Phase 1 re-reads
	# current DB state before acting, preventing the race condition where
	# Phase 0.7/0.8 and Phase 1 both tried to transition the same task.

	# Phase 1: Check running workers for completion
	# Also check 'evaluating' tasks - AI eval may have timed out, leaving them stuck
	local running_tasks
	running_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, log_file FROM tasks
        WHERE status IN ('running', 'dispatched', 'evaluating')
        ORDER BY started_at ASC;
    ")

	local completed_count=0
	local failed_count=0
	local dispatched_count=0

	# Track which task is being evaluated (for logging on pulse kill)
	local _phase1_evaluating_tid=""
	local _phase1_pre_eval_state=""

	if [[ -n "$running_tasks" ]]; then
		# No intermediate evaluating state — if pulse is killed mid-evaluation,
		# the task stays in running/dispatched and the next pulse re-evaluates it.
		# shellcheck disable=SC2064  # intentional: expand SUPERVISOR_DIR at definition time
		trap "release_pulse_lock; rm -f '${SUPERVISOR_DIR}/MODELS.md.tmp' 2>/dev/null || true" TERM INT

		while IFS='|' read -r tid _; do
			# Check if worker process is still alive
			local pid_file="$SUPERVISOR_DIR/pids/${tid}.pid"
			local is_alive=false

			if [[ -f "$pid_file" ]]; then
				local pid
				pid=$(cat "$pid_file")
				if kill -0 "$pid" 2>/dev/null; then
					is_alive=true
				fi
			fi

			if [[ "$is_alive" == "true" ]]; then
				log_info "  $tid: still running"
				continue
			fi

			# Worker is done - evaluate outcome directly (no intermediate evaluating state)
			# Re-read current state fresh from DB to avoid race conditions with Phase 0.7
			local current_task_state
			current_task_state=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")

			# Skip if another phase already moved this task to a post-running state
			if [[ "$current_task_state" != "running" && "$current_task_state" != "dispatched" && "$current_task_state" != "evaluating" ]]; then
				log_info "  $tid: skipping — already transitioned to $current_task_state by another phase"
				continue
			fi

			log_info "  $tid: worker finished, evaluating..."
			_phase1_pre_eval_state="$current_task_state"
			_phase1_evaluating_tid="$tid"

			# Get task description for memory context (t128.6)
			local tid_desc
			tid_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")

			# Get task model and repo for model label tracking (t1010)
			local tid_model tid_repo
			tid_model=$(db "$SUPERVISOR_DB" "SELECT model FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
			tid_repo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")

			# t1251: Fast-path evaluation for tasks with PR already in DB (t1245 early-persist).
			# If the PR URL is already persisted, evaluate_worker() will find it immediately
			# via the heuristic tiers and return complete: without needing AI eval.
			# Skip AI eval proactively to avoid the 60-90s AI eval window that causes
			# tasks to appear stuck in 'evaluating' and trigger Phase 0.7 recovery.
			local tid_existing_pr
			tid_existing_pr=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
			local skip_ai="false"
			if [[ -n "$tid_existing_pr" && "$tid_existing_pr" != "no_pr" && "$tid_existing_pr" != "task_only" && "$tid_existing_pr" != "task_obsolete" ]]; then
				# PR already in DB from t1245 early-persist — heuristic tiers will find it,
				# no need for AI eval. Skipping saves 60-90s and prevents stale-evaluating.
				skip_ai="true"
				log_info "  $tid: PR already in DB ($tid_existing_pr) — skipping AI eval (t1251 fast-path)"
			fi

			# Heartbeat: refresh updated_at before evaluation
			_update_task_heartbeat "$tid"

			local outcome
			local eval_maker="evaluate_worker"
			# Prefer assess_task (AI-powered, reads real sources of truth)
			# over evaluate_worker (1900-line deterministic heuristic tree).
			# Falls back to evaluate_worker_with_metadata, then evaluate_worker.
			if command -v assess_task_with_metadata &>/dev/null; then
				outcome=$(assess_task_with_metadata "$tid")
				eval_maker="assess_task"
			elif command -v evaluate_worker_with_metadata &>/dev/null; then
				outcome=$(evaluate_worker_with_metadata "$tid" "$skip_ai")
				eval_maker="evaluate_worker_with_metadata"
			else
				outcome=$(evaluate_worker "$tid" "$skip_ai")
			fi
			local outcome_type="${outcome%%:*}"
			local outcome_detail="${outcome#*:}"

			# Post-evaluation heartbeat
			if [[ "$outcome_type" == "complete" ]]; then
				_update_task_heartbeat "$tid"
			fi

			# Proof-log: record evaluation outcome (t218)
			local _eval_duration
			_eval_duration=$(_proof_log_stage_duration "$tid" "evaluate")
			write_proof_log --task "$tid" --event "evaluate" --stage "evaluate" \
				--decision "$outcome" --evidence "skip_ai=$skip_ai" \
				--maker "$eval_maker" \
				${_eval_duration:+--duration "$_eval_duration"} 2>/dev/null || true

			# Budget tracking: record spend from worker log (t1100)
			record_worker_spend "$tid" "$tid_model" 2>>"$SUPERVISOR_LOG" || true

			# Eager orphaned PR scan (t216): if evaluation didn't find a PR,
			# immediately check GitHub before retrying/failing. This catches
			# PRs that evaluate_worker() missed (API timeout, non-standard
			# branch, etc.) without waiting for the Phase 6 throttled sweep.
			if [[ "$outcome_type" != "complete" ]]; then
				scan_orphaned_pr_for_task "$tid" 2>>"$SUPERVISOR_LOG" || true
				# Re-check: if the eager scan found a PR and transitioned
				# the task to complete, update our outcome to match
				local post_scan_status
				post_scan_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
				if [[ "$post_scan_status" == "complete" ]]; then
					local post_scan_pr
					post_scan_pr=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
					log_success "  $tid: COMPLETE via eager orphaned PR scan ($post_scan_pr)"
					completed_count=$((completed_count + 1))
					cleanup_worker_processes "$tid"
					# Success pattern already stored by scan_orphaned_pr_for_task
					handle_diagnostic_completion "$tid" 2>>"$SUPERVISOR_LOG" || true
					_phase1_evaluating_tid="" # t1269: clear before continue
					_phase1_pre_eval_state=""
					continue
				fi
			fi

			case "$outcome_type" in
			alive)
				# assess_task safety net: worker is still running despite PID check above
				log_info "  $tid: still running (confirmed by assess_task)"
				_phase1_evaluating_tid=""
				_phase1_pre_eval_state=""
				continue
				;;
			complete)
				# Quality gate check before accepting completion (t132.6)
				local gate_result
				gate_result=$(run_quality_gate "$tid" "${batch_id:-}" 2>>"$SUPERVISOR_LOG") || gate_result="pass"
				local gate_type="${gate_result%%:*}"

				if [[ "$gate_type" == "escalate" ]]; then
					local escalated_model="${gate_result#escalate:}"
					log_warn "  $tid: ESCALATING to $escalated_model (quality gate failed)"
					# Proof-log: quality gate escalation (t218)
					write_proof_log --task "$tid" --event "escalate" --stage "quality_gate" \
						--decision "escalate:$escalated_model" \
						--evidence "gate_result=$gate_result" \
						--maker "quality_gate" 2>/dev/null || true
					# run_quality_gate already set status=queued and updated model
					# Clean up worker process tree before re-dispatch (t128.7)
					cleanup_worker_processes "$tid"
					store_failure_pattern "$tid" "escalated" "Quality gate -> $escalated_model" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
					# Add escalated:model label (original model that failed quality gate) (t1010)
					add_model_label "$tid" "escalated" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
					send_task_notification "$tid" "escalated" "Re-queued with $escalated_model" 2>>"$SUPERVISOR_LOG" || true
					_phase1_evaluating_tid="" # t1269: clear before continue
					_phase1_pre_eval_state=""
					continue
				fi

				log_success "  $tid: COMPLETE ($outcome_detail)"
				# t1183 Bug 2: Persist transition IMMEDIATELY after quality gate passes.
				# This is the crash-safe checkpoint — if the pulse is killed after this
				# line, the task is safely in 'complete' state and Phase 3 will pick it up.
				# All subsequent operations (proof-log, patterns, notifications) are
				# non-critical and can be lost without affecting correctness.
				cmd_transition "$tid" "complete" --pr-url "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				completed_count=$((completed_count + 1))
				# Clean up worker process tree and PID file (t128.7)
				cleanup_worker_processes "$tid"
				# Reset dispatch dedup guard state on success (t1206): clear last_failure_at
				# and consecutive_failure_count so a re-queued task is not deferred by a
				# stale cooldown from a pre-success failure.
				reset_failure_dedup_state "$tid" 2>>"$SUPERVISOR_LOG" || true
				# --- Non-critical post-processing below (safe to lose on kill) ---
				# Proof-log: task completion (t218)
				write_proof_log --task "$tid" --event "complete" --stage "evaluate" \
					--decision "complete:$outcome_detail" \
					--evidence "gate=$gate_result" \
					--maker "pulse:phase1" \
					--pr-url "$outcome_detail" 2>/dev/null || true
				# Auto-update TODO.md and send notification (t128.4)
				update_todo_on_complete "$tid" 2>>"$SUPERVISOR_LOG" || true
				send_task_notification "$tid" "complete" "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				# Store success pattern in memory (t128.6)
				store_success_pattern "$tid" "$outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
				# Track prompt-repeat outcome for pattern data (t1097)
				if _was_prompt_repeat_attempted "$tid"; then
					local pr_pattern_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
					if [[ -x "$pr_pattern_helper" ]]; then
						"$pr_pattern_helper" record \
							--type "SUCCESS_PATTERN" \
							--task "$tid" \
							--model "${tid_model:-unknown}" \
							--detail "prompt_repeat_success: task completed after reinforced prompt at same tier" \
							2>/dev/null || true
					fi
					log_info "  $tid: prompt-repeat strategy succeeded (t1097)"
				fi
				# Add implemented:model label to GitHub issue (t1010)
				add_model_label "$tid" "implemented" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
				# Self-heal: if this was a diagnostic task, re-queue the parent (t150)
				handle_diagnostic_completion "$tid" 2>>"$SUPERVISOR_LOG" || true
				;;
			retry)
				log_warn "  $tid: RETRY ($outcome_detail)"
				# Proof-log: retry decision (t218)
				write_proof_log --task "$tid" --event "retry" --stage "evaluate" \
					--decision "retry:$outcome_detail" \
					--maker "pulse:phase1" 2>/dev/null || true
				# Update dispatch dedup guard state (t1206): track failure timestamp and
				# consecutive count so check_dispatch_dedup_guard() can enforce cooldown
				# and block tasks that fail identically 2+ times in succession.
				# NOTE: must run BEFORE cmd_transition so the DB error column still holds
				# the *previous* failure's error for accurate streak comparison.
				update_failure_dedup_state "$tid" "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				cmd_transition "$tid" "retrying" --error "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				# Clean up worker process tree before re-prompt (t128.7)
				cleanup_worker_processes "$tid"
				# Store failure pattern in memory (t128.6)
				store_failure_pattern "$tid" "retry" "$outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
				# Track prompt-repeat failure for pattern data (t1097)
				# If this task already had a prompt-repeat attempt and is failing again,
				# record that prompt-repeat didn't help for this task type.
				if _was_prompt_repeat_attempted "$tid"; then
					local pr_pattern_helper_retry="${SCRIPT_DIR}/pattern-tracker-helper.sh"
					if [[ -x "$pr_pattern_helper_retry" ]]; then
						"$pr_pattern_helper_retry" record \
							--type "FAILURE_PATTERN" \
							--task "$tid" \
							--model "${tid_model:-unknown}" \
							--detail "prompt_repeat_failure: task failed again after reinforced prompt ($outcome_detail)" \
							2>/dev/null || true
					fi
					log_info "  $tid: prompt-repeat strategy failed, will escalate model (t1097)"
				fi
				# Add retried:model label to GitHub issue (t1010)
				add_model_label "$tid" "retried" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
				# Backend quota errors: defer re-prompt to next pulse (t095-diag-1).
				# Quota resets take hours, not minutes. Immediate re-prompt wastes
				# retry attempts. Leave in retrying state for deferred retry loop.
				if [[ "$outcome_detail" == "backend_quota_error" || "$outcome_detail" == "backend_infrastructure_error" ]]; then
					log_warn "  $tid: backend issue ($outcome_detail), deferring re-prompt to next pulse"
					_phase1_evaluating_tid="" # t1269: clear before continue
					_phase1_pre_eval_state=""
					continue
				fi
				# Prompt-repeat retry strategy (t1097): before escalating to a more
				# expensive model, try the same tier with a reinforced prompt. Many
				# failures are due to insufficient prompt clarity, not model capability.
				local prompt_repeat_eligible=""
				prompt_repeat_eligible=$(should_prompt_repeat "$tid" "$outcome_detail" 2>/dev/null) || prompt_repeat_eligible=""
				if [[ "$prompt_repeat_eligible" == "eligible" ]]; then
					log_info "  $tid: attempting prompt-repeat retry at same tier (t1097)"
					local pr_rc=0
					do_prompt_repeat "$tid" 2>>"$SUPERVISOR_LOG" || pr_rc=$?
					if [[ "$pr_rc" -eq 0 ]]; then
						dispatched_count=$((dispatched_count + 1))
						log_info "  $tid: prompt-repeat dispatched successfully"
						_phase1_evaluating_tid="" # t1269: clear before continue
						_phase1_pre_eval_state=""
						continue
					fi
					log_warn "  $tid: prompt-repeat dispatch failed (rc=$pr_rc), falling through to model escalation"
				else
					log_info "  $tid: prompt-repeat not eligible ($prompt_repeat_eligible), proceeding to model escalation"
				fi
				# Auto-escalate model on retry so re-prompt uses stronger model (t314 wiring)
				escalate_model_on_failure "$tid" 2>>"$SUPERVISOR_LOG" || true
				# Re-prompt in existing worktree (continues context)
				local reprompt_rc=0
				cmd_reprompt "$tid" 2>>"$SUPERVISOR_LOG" || reprompt_rc=$?
				if [[ "$reprompt_rc" -eq 0 ]]; then
					dispatched_count=$((dispatched_count + 1))
					log_info "  $tid: re-prompted successfully"
				elif [[ "$reprompt_rc" -eq 75 ]]; then
					# EX_TEMPFAIL: backend unhealthy, task stays in retrying
					# state for the next pulse to pick up (t153-pre-diag-1)
					log_warn "  $tid: backend unhealthy, deferring re-prompt to next pulse"
				else
					# Re-prompt failed - check if max retries exceeded
					local current_retries
					current_retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 0)
					local max_retries_val
					max_retries_val=$(db "$SUPERVISOR_DB" "SELECT max_retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 3)
					if [[ "$current_retries" -ge "$max_retries_val" ]]; then
						log_error "  $tid: max retries exceeded ($current_retries/$max_retries_val), marking blocked"
						cmd_transition "$tid" "blocked" --error "Max retries exceeded: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
						# Auto-update TODO.md and send notification (t128.4)
						update_todo_on_blocked "$tid" "Max retries exceeded: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
						send_task_notification "$tid" "blocked" "Max retries exceeded: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
						# Store failure pattern in memory (t128.6)
						store_failure_pattern "$tid" "blocked" "Max retries exceeded: $outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
						# Add failed:model label to GitHub issue (t1010)
						add_model_label "$tid" "failed" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
						# Self-heal: attempt diagnostic subtask (t150)
						attempt_self_heal "$tid" "blocked" "$outcome_detail" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
					else
						log_error "  $tid: re-prompt failed, marking failed"
						cmd_transition "$tid" "failed" --error "Re-prompt dispatch failed: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
						failed_count=$((failed_count + 1))
						# Auto-update TODO.md and send notification (t128.4)
						update_todo_on_blocked "$tid" "Re-prompt dispatch failed: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
						send_task_notification "$tid" "failed" "Re-prompt dispatch failed: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
						# Store failure pattern in memory (t128.6)
						store_failure_pattern "$tid" "failed" "Re-prompt dispatch failed: $outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
						# Add failed:model label to GitHub issue (t1010)
						add_model_label "$tid" "failed" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
						# Self-heal: attempt diagnostic subtask (t150)
						attempt_self_heal "$tid" "failed" "$outcome_detail" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
					fi
				fi
				;;
			blocked)
				log_warn "  $tid: BLOCKED ($outcome_detail)"
				# Proof-log: blocked decision (t218)
				write_proof_log --task "$tid" --event "blocked" --stage "evaluate" \
					--decision "blocked:$outcome_detail" \
					--maker "pulse:phase1" 2>/dev/null || true
				cmd_transition "$tid" "blocked" --error "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				# Clean up worker process tree and PID file (t128.7)
				cleanup_worker_processes "$tid"
				# Auto-update TODO.md and send notification (t128.4)
				update_todo_on_blocked "$tid" "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				send_task_notification "$tid" "blocked" "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
				# Store failure pattern in memory (t128.6)
				store_failure_pattern "$tid" "blocked" "$outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
				# Add failed:model label to GitHub issue (t1010)
				add_model_label "$tid" "failed" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
				# Self-heal: attempt diagnostic subtask (t150)
				attempt_self_heal "$tid" "blocked" "$outcome_detail" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
				;;
			failed)
				# t1113: Classify failure mode to distinguish environment issues from
				# task/code problems. Environment failures (worker_never_started,
				# log_file_missing, etc.) are re-queued without burning retry count
				# since the task itself isn't at fault.
				local failed_fmode=""
				failed_fmode=$(classify_failure_mode "$outcome_detail" 2>/dev/null) || failed_fmode="AMBIGUOUS"

				if [[ "$failed_fmode" == "ENVIRONMENT" ]]; then
					# t1113: Environment failure — re-queue without incrementing retry count.
					# The CLI/environment was broken, not the task. Burning retries here
					# would exhaust max_retries on infrastructure issues, permanently
					# failing tasks that would succeed once the environment is fixed.
					log_warn "  $tid: ENVIRONMENT failure ($outcome_detail) — re-queuing without retry increment (t1113)"
					write_proof_log --task "$tid" --event "environment_failure" --stage "evaluate" \
						--decision "requeue:$outcome_detail" \
						--evidence "failure_mode=ENVIRONMENT,retry_preserved=true" \
						--maker "pulse:phase1:t1113" 2>/dev/null || true
					# Clean up worker process tree and PID file
					cleanup_worker_processes "$tid"
					# Transition back to queued (preserves current retry count)
					cmd_transition "$tid" "queued" --error "environment:$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
					# Store pattern for diagnostics but don't mark as task failure
					store_failure_pattern "$tid" "environment" "$outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
					# Invalidate CLI health cache so next pulse re-checks
					local cli_cache_dir="${SUPERVISOR_DIR}/health"
					rm -f "$cli_cache_dir"/cli-* 2>/dev/null || true
					_PULSE_CLI_VERIFIED=""
					log_info "  $tid: CLI health cache invalidated — next dispatch will re-verify"
				else
					log_error "  $tid: FAILED ($outcome_detail)"
					# Proof-log: failed decision (t218)
					write_proof_log --task "$tid" --event "failed" --stage "evaluate" \
						--decision "failed:$outcome_detail" \
						--maker "pulse:phase1" 2>/dev/null || true
					cmd_transition "$tid" "failed" --error "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
					failed_count=$((failed_count + 1))
					# Clean up worker process tree and PID file (t128.7)
					cleanup_worker_processes "$tid"
					# Auto-update TODO.md and send notification (t128.4)
					update_todo_on_blocked "$tid" "FAILED: $outcome_detail" 2>>"$SUPERVISOR_LOG" || true
					send_task_notification "$tid" "failed" "$outcome_detail" 2>>"$SUPERVISOR_LOG" || true
					# Store failure pattern in memory (t128.6)
					store_failure_pattern "$tid" "failed" "$outcome_detail" "$tid_desc" 2>>"$SUPERVISOR_LOG" || true
					# Add failed:model label to GitHub issue (t1010)
					add_model_label "$tid" "failed" "$tid_model" "${tid_repo:-.}" 2>>"$SUPERVISOR_LOG" || true
					# Self-heal: attempt diagnostic subtask (t150)
					attempt_self_heal "$tid" "failed" "$outcome_detail" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
				fi
				;;
			esac

			# t1269: Clear evaluation tracking — task has been fully processed.
			# If the pulse is killed after this point, the task is already in its
			# final state (complete/retrying/blocked/failed/queued) and doesn't
			# need rollback.
			_phase1_evaluating_tid=""
			_phase1_pre_eval_state=""
		done <<<"$running_tasks"

		# t1269: Restore original signal trap after evaluation loop completes.
		# The EXIT trap (release_pulse_lock) is still active from the outer scope.
		# shellcheck disable=SC2064  # intentional: expand SUPERVISOR_DIR at definition time
		trap "release_pulse_lock; rm -f '${SUPERVISOR_DIR}/MODELS.md.tmp' 2>/dev/null || true" TERM INT
	fi

	# Phase 1b: Re-prompt stale retrying tasks (t153-pre-diag-1)
	# Tasks left in 'retrying' state from a previous pulse where the backend was
	# unhealthy (health check returned EX_TEMPFAIL=75). Try re-prompting them now.
	local retrying_tasks
	retrying_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id FROM tasks
        WHERE status = 'retrying'
        AND retries < max_retries
        ORDER BY updated_at ASC;
    ")

	if [[ -n "$retrying_tasks" ]]; then
		while IFS='|' read -r tid; do
			[[ -z "$tid" ]] && continue
			log_info "  $tid: retrying (deferred from previous pulse)"
			local reprompt_rc=0
			cmd_reprompt "$tid" 2>>"$SUPERVISOR_LOG" || reprompt_rc=$?
			if [[ "$reprompt_rc" -eq 0 ]]; then
				dispatched_count=$((dispatched_count + 1))
				log_info "  $tid: re-prompted successfully"
			elif [[ "$reprompt_rc" -eq 75 ]]; then
				log_warn "  $tid: backend still unhealthy, deferring again"
			else
				log_error "  $tid: re-prompt failed (exit $reprompt_rc)"
				local current_retries
				current_retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 0)
				local max_retries_val
				max_retries_val=$(db "$SUPERVISOR_DB" "SELECT max_retries FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo 3)
				if [[ "$current_retries" -ge "$max_retries_val" ]]; then
					cmd_transition "$tid" "blocked" --error "Max retries exceeded during deferred re-prompt" 2>>"$SUPERVISOR_LOG" || true
					attempt_self_heal "$tid" "blocked" "Max retries exceeded during deferred re-prompt" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
				else
					cmd_transition "$tid" "failed" --error "Re-prompt dispatch failed" 2>>"$SUPERVISOR_LOG" || true
					attempt_self_heal "$tid" "failed" "Re-prompt dispatch failed" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
				fi
			fi
		done <<<"$retrying_tasks"
	fi

	# Phase 1c: Auto-reap stuck evaluating tasks (self-healing, enhanced t1202)
	# Tasks can get stuck in 'evaluating' when the worker dies but evaluation
	# fails or times out. Phase 1 handles tasks with dead workers that it finds
	# in the running_tasks query, but tasks can also get stuck if:
	#   - The evaluation itself crashed (jq error, timeout, etc.)
	#   - The task was left in evaluating from a previous pulse that was killed
	# This phase catches any evaluating task older than the evaluating grace
	# period (t1202: uses SUPERVISOR_EVALUATING_GRACE_SECONDS, default 120s)
	# with no live worker process, and force-transitions it for retry.
	#
	# Note: Phase 0.7 also catches stale evaluating tasks, but uses updated_at
	# which can be refreshed by other DB operations. Phase 1c is a safety net
	# that runs after Phase 1's evaluation attempts, catching tasks that Phase 1
	# transitioned to evaluating but then failed to complete evaluation.
	local phase1c_grace="${SUPERVISOR_EVALUATING_GRACE_SECONDS:-120}"
	local stuck_evaluating
	stuck_evaluating=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, updated_at FROM tasks
		WHERE status = 'evaluating'
		AND updated_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${phase1c_grace} seconds')
		ORDER BY updated_at ASC;
	" 2>/dev/null || echo "")

	if [[ -n "$stuck_evaluating" ]]; then
		while IFS='|' read -r stuck_id stuck_updated; do
			[[ -z "$stuck_id" ]] && continue

			# Double-check: is the worker actually dead?
			local stuck_pid_file="$SUPERVISOR_DIR/pids/${stuck_id}.pid"
			local stuck_alive=false
			if [[ -f "$stuck_pid_file" ]]; then
				local stuck_pid
				stuck_pid=$(cat "$stuck_pid_file" 2>/dev/null || echo "")
				if [[ -n "$stuck_pid" ]] && kill -0 "$stuck_pid" 2>/dev/null; then
					stuck_alive=true
				fi
			fi

			if [[ "$stuck_alive" == "true" ]]; then
				log_info "  Phase 1c: $stuck_id evaluating since $stuck_updated but worker still alive — skipping"
				continue
			fi

			# Diagnose root cause (t1202, t1249)
			# _diagnose_stale_root_cause sets _DIAG_* timing globals (t1249)
			local stuck_root_cause
			stuck_root_cause=$(_diagnose_stale_root_cause "$stuck_id" "evaluating")
			local stuck_worker_completed_at="${_DIAG_WORKER_COMPLETED_AT:-}"
			local stuck_eval_started_at="${_DIAG_EVAL_STARTED_AT:-}"
			local stuck_eval_lag_secs="${_DIAG_EVAL_LAG_SECS:-NULL}"

			# t1251: Skip recovery if evaluation is actively in progress (heartbeat check).
			# The heartbeat in evaluate_with_ai() updates updated_at at eval start.
			# Phase 1c's grace query uses updated_at, so a heartbeat-refreshed task
			# won't appear here — but check anyway as a safety net.
			if [[ "$stuck_root_cause" == eval_in_progress_heartbeat_* ]]; then
				log_info "  Phase 1c: $stuck_id skipped — AI eval actively in progress ($stuck_root_cause)"
				continue
			fi

			# Calculate stale duration
			local stuck_stale_secs=0
			if [[ -n "$stuck_updated" ]]; then
				local stuck_epoch
				stuck_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$stuck_updated" "+%s" 2>/dev/null || date -d "$stuck_updated" "+%s" 2>/dev/null || echo "0")
				local stuck_now
				stuck_now=$(date "+%s")
				if [[ "$stuck_epoch" -gt 0 ]]; then
					stuck_stale_secs=$((stuck_now - stuck_epoch))
				fi
			fi

			# t1249: Include eval lag in log message when available
			local stuck_eval_lag_info=""
			if [[ "$stuck_eval_lag_secs" != "NULL" ]]; then
				stuck_eval_lag_info=", eval_lag: ${stuck_eval_lag_secs}s"
			fi
			log_warn "  Phase 1c: $stuck_id stuck in evaluating since $stuck_updated (${stuck_stale_secs}s, worker dead, cause: $stuck_root_cause${stuck_eval_lag_info})"

			# t1183 Bug 1: Check if task already has a PR before retrying.
			# If a PR exists, the worker succeeded but evaluation was lost —
			# send to pr_review (Phase 3) instead of retrying (which would
			# dispatch a duplicate worker and potentially create a duplicate PR).
			local stuck_pr_url
			stuck_pr_url=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$(sql_escape "$stuck_id")';" 2>/dev/null || echo "")
			local stuck_had_pr=0
			[[ -n "$stuck_pr_url" && "$stuck_pr_url" != "no_pr" && "$stuck_pr_url" != "task_only" ]] && stuck_had_pr=1
			local stuck_to_state=""

			if [[ "$stuck_had_pr" -eq 1 ]]; then
				stuck_to_state="pr_review"
				cmd_transition "$stuck_id" "pr_review" 2>>"$SUPERVISOR_LOG" || true
				log_info "  Phase 1c: $stuck_id → pr_review (has PR: $stuck_pr_url, cause: $stuck_root_cause)"
			else
				# No PR — use original retry/fail logic
				# Check retry count
				local stuck_retries stuck_max_retries
				stuck_retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$stuck_id")';" 2>/dev/null || echo 0)
				stuck_max_retries=$(db "$SUPERVISOR_DB" "SELECT max_retries FROM tasks WHERE id = '$(sql_escape "$stuck_id")';" 2>/dev/null || echo 3)

				if [[ "$stuck_retries" -lt "$stuck_max_retries" ]]; then
					# Transition to retrying so it gets re-dispatched
					stuck_to_state="retrying"
					cmd_transition "$stuck_id" "retrying" --error "Auto-reaped: stuck in evaluating >${phase1c_grace}s with dead worker (Phase 1c/t1202, cause: $stuck_root_cause)" 2>>"$SUPERVISOR_LOG" || true
					db "$SUPERVISOR_DB" "UPDATE tasks SET retries = retries + 1, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '$(sql_escape "$stuck_id")';" 2>/dev/null || true
					log_info "  Phase 1c: $stuck_id → retrying (retry $((stuck_retries + 1))/$stuck_max_retries, cause: $stuck_root_cause)"
				else
					# Max retries exhausted — mark as failed
					stuck_to_state="failed"
					cmd_transition "$stuck_id" "failed" --error "Auto-reaped: stuck in evaluating >${phase1c_grace}s, max retries exhausted (Phase 1c/t1202, cause: $stuck_root_cause)" 2>>"$SUPERVISOR_LOG" || true
					log_warn "  Phase 1c: $stuck_id → failed (max retries exhausted, cause: $stuck_root_cause)"
				fi
			fi

			# Record metrics to stale_recovery_log (t1202, t1249)
			local stuck_retries_val
			stuck_retries_val=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$stuck_id")';" 2>/dev/null || echo 0)
			local stuck_max_val
			stuck_max_val=$(db "$SUPERVISOR_DB" "SELECT max_retries FROM tasks WHERE id = '$(sql_escape "$stuck_id")';" 2>/dev/null || echo 3)
			_record_stale_recovery \
				--task "$stuck_id" --phase "1c" \
				--from "evaluating" --to "$stuck_to_state" \
				--stale-secs "$stuck_stale_secs" --root-cause "$stuck_root_cause" \
				--had-pr "$stuck_had_pr" --retries "$stuck_retries_val" \
				--max-retries "$stuck_max_val" --batch "${batch_id:-}" \
				--worker-completed-at "$stuck_worker_completed_at" \
				--eval-started-at "$stuck_eval_started_at" \
				--eval-lag-secs "$stuck_eval_lag_secs"

			# Clean up PID file
			cleanup_worker_processes "$stuck_id" 2>>"$SUPERVISOR_LOG" || true
		done <<<"$stuck_evaluating"
	fi

	# Phase 1d: Post-completion auto-unblock pass (t1247)
	# Phase 0.5d runs BEFORE Phase 1, so tasks completed in this pulse (marked [x]
	# by update_todo_on_complete in Phase 1) are missed by the earlier unblock pass.
	# This second pass runs immediately after Phase 1 so any newly-completed blockers
	# unblock their downstream tasks in the same pulse — no extra 2-minute wait.
	# The DB-fallback in auto_unblock_resolved_tasks (also t1247) handles the case
	# where update_todo_on_complete failed but the DB status is already terminal.
	if [[ -n "$all_repos" ]]; then
		while IFS= read -r repo_path; do
			if [[ -f "$repo_path/TODO.md" ]]; then
				auto_unblock_resolved_tasks "$repo_path" 2>>"$SUPERVISOR_LOG" || true
			fi
		done <<<"$all_repos"
	else
		if [[ -f "$(pwd)/TODO.md" ]]; then
			auto_unblock_resolved_tasks "$(pwd)" 2>>"$SUPERVISOR_LOG" || true
		fi
	fi

	# Phase 0.9: Sanity check — question assumptions when queue appears empty
	# Runs after all recovery phases (0.5–0.8, 1–1d) and before dispatch (Phase 2).
	# When the queue has zero dispatchable tasks but open tasks exist in TODO.md,
	# cross-references DB state, TODO.md state, and system state to find
	# contradictions that cause silent stalls. Fixes: stale claims on DB-failed
	# tasks, failed blocker cascades, missing #auto-dispatch tags, DB orphans.
	local queued_before_sanity
	queued_before_sanity=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE status = 'queued';" 2>/dev/null || echo 0)
	if [[ "$queued_before_sanity" -eq 0 ]]; then
		# No queued tasks — check if there are open tasks in TODO.md that should be dispatchable
		if [[ -n "$all_repos" ]]; then
			while IFS= read -r repo_path; do
				_run_sanity_check_for_repo "$repo_path"
			done <<<"$all_repos"
		else
			_run_sanity_check_for_repo "$(pwd)"
		fi
	fi

	# Phase 2: Dispatch queued tasks up to concurrency limit

	if [[ -n "$batch_id" ]]; then
		local next_tasks
		next_tasks=$(cmd_next "$batch_id" 10)

		if [[ -n "$next_tasks" ]]; then
			while IFS=$'\t' read -r tid _ _ _; do
				# Guard: skip malformed task IDs (e.g., from embedded newlines
				# in diagnostic task descriptions containing EXIT:0 or markers)
				if [[ -z "$tid" || "$tid" =~ [[:space:]:] || ! "$tid" =~ ^[a-zA-Z0-9._-]+$ ]]; then
					log_warn "Skipping malformed task ID in cmd_next output: '${tid:0:40}'"
					continue
				fi
				local dispatch_exit=0
				cmd_dispatch "$tid" --batch "$batch_id" || dispatch_exit=$?
				if [[ "$dispatch_exit" -eq 0 ]]; then
					dispatched_count=$((dispatched_count + 1))
				elif [[ "$dispatch_exit" -eq 2 ]]; then
					log_info "Concurrency limit reached, stopping dispatch"
					break
				elif [[ "$dispatch_exit" -eq 3 ]]; then
					log_warn "Provider unavailable for $tid, stopping dispatch until next pulse"
					break
				else
					log_warn "Dispatch failed for $tid (exit $dispatch_exit), trying next task"
				fi
			done <<<"$next_tasks"
		fi
	else
		# Global dispatch (no batch filter)
		local next_tasks
		next_tasks=$(cmd_next "" 10)

		if [[ -n "$next_tasks" ]]; then
			while IFS=$'\t' read -r tid _ _ _; do
				# Guard: skip malformed task IDs (same as batch dispatch above)
				if [[ -z "$tid" || "$tid" =~ [[:space:]:] || ! "$tid" =~ ^[a-zA-Z0-9._-]+$ ]]; then
					log_warn "Skipping malformed task ID in cmd_next output: '${tid:0:40}'"
					continue
				fi
				local dispatch_exit=0
				cmd_dispatch "$tid" || dispatch_exit=$?
				if [[ "$dispatch_exit" -eq 0 ]]; then
					dispatched_count=$((dispatched_count + 1))
				elif [[ "$dispatch_exit" -eq 2 ]]; then
					log_info "Concurrency limit reached, stopping dispatch"
					break
				elif [[ "$dispatch_exit" -eq 3 ]]; then
					log_warn "Provider unavailable for $tid, stopping dispatch until next pulse"
					break
				else
					log_warn "Dispatch failed for $tid (exit $dispatch_exit), trying next task"
				fi
			done <<<"$next_tasks"
		fi
	fi

	# Phase 2b: Dispatch stall detection and auto-recovery
	# If there are queued tasks but nothing was dispatched and nothing is running,
	# the pipeline is stalled. Common causes:
	#   - No active batch (auto-pickup creates batches, but may have failed)
	#   - All tasks stuck in non-dispatchable states (evaluating, blocked)
	#   - Provider unavailable for extended period
	#   - Concurrency limit misconfigured to 0
	if [[ "$dispatched_count" -eq 0 ]]; then
		local queued_count running_count
		queued_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE status = 'queued';" 2>/dev/null || echo 0)
		running_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE status IN ('running', 'dispatched');" 2>/dev/null || echo 0)

		if [[ "$queued_count" -gt 0 && "$running_count" -eq 0 ]]; then
			log_warn "Phase 2b: Dispatch stall detected — $queued_count queued, 0 running, 0 dispatched this pulse"

			# Diagnose: is there an active batch?
			local active_batch_count
			active_batch_count=$(db "$SUPERVISOR_DB" "
				SELECT COUNT(*) FROM batches
				WHERE status IN ('active', 'running');" 2>/dev/null || echo 0)

			if [[ "$active_batch_count" -eq 0 ]]; then
				log_warn "Phase 2b: No active batch found — queued tasks have no batch to dispatch from"
				# Auto-recovery: trigger auto-pickup to create a batch
				# This handles the case where tasks were added to the DB but no batch was created
				local stall_repos
				stall_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks WHERE status = 'queued';" 2>/dev/null || echo "")
				if [[ -n "$stall_repos" ]]; then
					while IFS= read -r stall_repo; do
						[[ -z "$stall_repo" ]] && continue
						log_info "Phase 2b: Re-running auto-pickup for $stall_repo to create batch"
						cmd_auto_pickup --repo "$stall_repo" 2>>"$SUPERVISOR_LOG" || true
					done <<<"$stall_repos"
				fi
			else
				# Batch exists but dispatch failed — log diagnostic info
				local batch_info
				batch_info=$(db -separator '|' "$SUPERVISOR_DB" "
					SELECT id, concurrency, status FROM batches
					WHERE status IN ('active', 'running')
					LIMIT 1;" 2>/dev/null || echo "")
				log_warn "Phase 2b: Active batch exists ($batch_info) but dispatch produced 0 — check concurrency limits and provider health"
			fi

			# Track stall count in state_log for the AI self-reflection to pick up
			db "$SUPERVISOR_DB" "
				INSERT INTO state_log (task_id, from_state, to_state, reason)
				VALUES ('supervisor', 'dispatch', 'stalled',
						'$(sql_escape "Dispatch stall: $queued_count queued, 0 running, 0 dispatched. Active batches: $active_batch_count")');
			" 2>/dev/null || true
		fi
	fi

	# Phase 2.5: Contest mode — check running contests for completion (t1011)
	# If any contest has all entries complete, evaluate cross-rankings and apply winner
	local contest_helper="${SCRIPT_DIR}/contest-helper.sh"
	if [[ -x "$contest_helper" ]]; then
		local has_contests
		has_contests=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='contests';" 2>/dev/null || echo "0")
		if [[ "$has_contests" -gt 0 ]]; then
			local running_contests
			running_contests=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM contests WHERE status IN ('running','evaluating');" 2>/dev/null || echo "0")
			if [[ "$running_contests" -gt 0 ]]; then
				log_info "Phase 2.5: Checking $running_contests running contest(s)..."
				local evaluated_count
				evaluated_count=$("$contest_helper" pulse-check 2>/dev/null || echo "0")
				if [[ "$evaluated_count" -gt 0 ]]; then
					log_success "Phase 2.5: Evaluated $evaluated_count contest(s)"
				fi
			fi
		fi
	fi

	# Phase 3a: Adopt untracked PRs into the supervisor pipeline
	# Scans open PRs for each tracked repo and adopts any that:
	#   1. Have a task ID in the title (tNNN: description)
	#   2. Are not already tracked in the supervisor DB
	#   3. Have a matching open task in TODO.md
	# Adopted PRs get a DB entry with status=complete so Phase 3 processes them
	# through the normal review → merge → verify lifecycle.
	# This closes the gap where interactive sessions create PRs that the
	# supervisor can't manage (review, merge, verify, clean up).
	if command -v gh &>/dev/null; then
		adopt_untracked_prs 2>>"$SUPERVISOR_LOG" || true
	fi

	# Phase 3: Post-PR lifecycle (t128.8)
	# Process tasks that workers completed (PR created) but still need merge/deploy
	# t265: Redirect stderr to log and capture errors before || true suppresses them
	if ! process_post_pr_lifecycle "${batch_id:-}" 2>>"$SUPERVISOR_LOG"; then
		log_error "Phase 3 (process_post_pr_lifecycle) failed — see $SUPERVISOR_LOG for details"
	fi

	# Phase 3b: Post-merge verification (t180.4)
	# Run check: directives from VERIFY.md for deployed tasks
	# t265: Redirect stderr to log and capture errors before || true suppresses them
	if ! process_verify_queue "${batch_id:-}" 2>>"$SUPERVISOR_LOG"; then
		log_error "Phase 3b (process_verify_queue) failed — see $SUPERVISOR_LOG for details"
	fi

	# Phase 3b2: Reconcile stale blocked/verify_failed tasks against GitHub PR state
	# Tasks can get stuck in 'blocked' or 'verify_failed' when the supervisor
	# encounters an error (merge conflict, rebase failure, verify check failure)
	# but the PR is subsequently merged by a later pulse or manual action.
	# This phase queries GitHub for the actual PR state and advances tasks
	# whose PRs have already been merged. Also handles PRs closed without merge
	# (cancels the task) and tasks with obsolete/unreachable PR URLs.
	# First: cancel tasks with obsolete/sentinel PR URLs
	local obsolete_tasks
	obsolete_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, status, pr_url FROM tasks
		WHERE status IN ('blocked', 'verify_failed')
		  AND pr_url IN ('task_obsolete')
		ORDER BY id;
	" 2>/dev/null || echo "")

	if [[ -n "$obsolete_tasks" ]]; then
		while IFS='|' read -r obs_id obs_status obs_pr; do
			[[ -z "$obs_id" ]] && continue
			log_warn "  Phase 3b2: $obs_id ($obs_status) has obsolete PR marker '$obs_pr' — cancelling"
			cmd_transition "$obs_id" "cancelled" --error "Task obsolete (PR marker: $obs_pr)" 2>>"$SUPERVISOR_LOG" || true
			cleanup_after_merge "$obs_id" 2>>"$SUPERVISOR_LOG" || true
		done <<<"$obsolete_tasks"
	fi

	# Then: reconcile tasks with real PR URLs against GitHub
	if command -v gh &>/dev/null; then
		local stale_tasks
		stale_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
			SELECT id, status, pr_url, repo FROM tasks
			WHERE status IN ('blocked', 'verify_failed')
			  AND pr_url IS NOT NULL
			  AND pr_url != ''
			  AND pr_url != 'no_pr'
			  AND pr_url != 'task_only'
			  AND pr_url != 'task_obsolete'
			  AND pr_url != 'verified_complete'
			ORDER BY id;
		" 2>/dev/null || echo "")

		if [[ -n "$stale_tasks" ]]; then
			local reconciled_merged=0
			local reconciled_closed=0
			local reconciled_obsolete=0

			while IFS='|' read -r stale_id stale_status stale_pr _stale_repo; do
				[[ -z "$stale_id" ]] && continue

				# Extract PR number and repo slug from URL
				local pr_number="" pr_repo_slug=""
				if [[ "$stale_pr" =~ github\.com/([^/]+/[^/]+)/pull/([0-9]+)$ ]]; then
					pr_repo_slug="${BASH_REMATCH[1]}"
					pr_number="${BASH_REMATCH[2]}"
				fi
				if [[ -z "$pr_number" ]]; then
					# Non-standard PR URL or obsolete marker — mark as cancelled
					log_warn "  Phase 3b2: $stale_id has non-parseable PR URL '$stale_pr' — cancelling"
					cmd_transition "$stale_id" "cancelled" --error "PR URL not parseable: $stale_pr" 2>>"$SUPERVISOR_LOG" || true
					reconciled_obsolete=$((reconciled_obsolete + 1))
					continue
				fi

				# Query GitHub for actual PR state (use --repo for cron compatibility)
				local pr_json
				pr_json=$(gh pr view "$pr_number" --repo "$pr_repo_slug" --json state,mergedAt 2>/dev/null || echo "")
				if [[ -z "$pr_json" ]]; then
					log_warn "  Phase 3b2: $stale_id PR #$pr_number unreachable — skipping"
					continue
				fi

				local pr_state pr_merged_at
				pr_state=$(echo "$pr_json" | grep -o '"state":"[^"]*"' | cut -d'"' -f4 || echo "")
				pr_merged_at=$(echo "$pr_json" | grep -o '"mergedAt":"[^"]*"' | cut -d'"' -f4 || echo "")

				if [[ "$pr_state" == "MERGED" ]]; then
					local escaped_stale_id
					escaped_stale_id=$(sql_escape "$stale_id")

					if [[ "$stale_status" == "verify_failed" ]]; then
						# verify_failed: PR was already merged and deployed, but
						# post-merge verification failed. Put back to 'deployed'
						# so Phase 3b (verify queue) can re-run verification.
						# Cap retries to prevent infinite deployed→verify_failed loop (t1075).
						local verify_reset_count
						verify_reset_count=$(db "$SUPERVISOR_DB" "
							SELECT COUNT(*) FROM state_log
							WHERE task_id = '$escaped_stale_id'
							  AND from_state = 'verify_failed'
							  AND to_state = 'deployed';" 2>/dev/null || echo "0")
						local max_verify_retries=3

						if [[ "$verify_reset_count" -ge "$max_verify_retries" ]]; then
							# Exhausted verification retries — mark permanently failed
							log_error "  Phase 3b2: $stale_id exhausted $max_verify_retries verification retries — marking failed"
							db "$SUPERVISOR_DB" "UPDATE tasks SET
								status = 'failed',
								error = 'Verification failed after $max_verify_retries retries — manual fix needed',
								updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
							WHERE id = '$escaped_stale_id';" 2>/dev/null || true
							db "$SUPERVISOR_DB" "INSERT INTO state_log (task_id, from_state, to_state, timestamp, reason)
							VALUES ('$escaped_stale_id', 'verify_failed', 'failed',
								strftime('%Y-%m-%dT%H:%M:%SZ','now'),
								'Phase 3b2: verification exhausted ($verify_reset_count/$max_verify_retries retries)');" 2>/dev/null || true
							sync_issue_status_label "$stale_id" "failed" "phase_3b2" 2>>"$SUPERVISOR_LOG" || true
						else
							log_info "  Phase 3b2: $stale_id (verify_failed) — PR #$pr_number merged, resetting to deployed for re-verification (attempt $((verify_reset_count + 1))/$max_verify_retries)"
							db "$SUPERVISOR_DB" "UPDATE tasks SET
								status = 'deployed',
								error = NULL,
								updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
							WHERE id = '$escaped_stale_id';" 2>/dev/null || true
							db "$SUPERVISOR_DB" "INSERT INTO state_log (task_id, from_state, to_state, timestamp, reason)
							VALUES ('$escaped_stale_id', 'verify_failed', 'deployed',
								strftime('%Y-%m-%dT%H:%M:%SZ','now'),
								'Phase 3b2: reset for re-verification attempt $((verify_reset_count + 1))/$max_verify_retries (PR #$pr_number merged)');" 2>/dev/null || true
							sync_issue_status_label "$stale_id" "deployed" "phase_3b2" 2>>"$SUPERVISOR_LOG" || true
						fi
					else
						# blocked: PR merged but task stuck in blocked state.
						# Advance to deployed and mark complete.
						log_success "  Phase 3b2: $stale_id ($stale_status) — PR #$pr_number already MERGED ($pr_merged_at), advancing to deployed"
						db "$SUPERVISOR_DB" "UPDATE tasks SET
							status = 'deployed',
							error = NULL,
							completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
							updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
						WHERE id = '$escaped_stale_id';" 2>/dev/null || true
						db "$SUPERVISOR_DB" "INSERT INTO state_log (task_id, from_state, to_state, timestamp, reason)
						VALUES ('$escaped_stale_id', '$stale_status', 'deployed',
							strftime('%Y-%m-%dT%H:%M:%SZ','now'),
							'Phase 3b2 reconciliation: PR #$pr_number merged at $pr_merged_at');" 2>/dev/null || true
						# Clean up worktree if it exists
						cleanup_after_merge "$stale_id" 2>>"$SUPERVISOR_LOG" || log_warn "  Worktree cleanup issue for $stale_id (non-blocking)"
						# Update TODO.md
						update_todo_on_complete "$stale_id" 2>>"$SUPERVISOR_LOG" || true
						# Sync GitHub issue status
						sync_issue_status_label "$stale_id" "deployed" "phase_3b2" 2>>"$SUPERVISOR_LOG" || true
					fi
					# Proof-log for both paths
					write_proof_log --task "$stale_id" --event "reconcile_merged" --stage "phase_3b2" \
						--decision "$stale_status->deployed (PR already merged)" \
						--evidence "pr=#$pr_number merged_at=$pr_merged_at prev_status=$stale_status" \
						--maker "pulse:phase_3b2" 2>/dev/null || true
					reconciled_merged=$((reconciled_merged + 1))

				elif [[ "$pr_state" == "CLOSED" ]]; then
					# PR was closed without merge — the work was abandoned or superseded
					log_warn "  Phase 3b2: $stale_id ($stale_status) — PR #$pr_number CLOSED without merge, resetting to queued for re-dispatch"
					# Reset to queued so it can be re-dispatched with a fresh worktree
					local escaped_stale_id
					escaped_stale_id=$(sql_escape "$stale_id")
					db "$SUPERVISOR_DB" "UPDATE tasks SET
						status = 'queued',
						error = NULL,
						pr_url = NULL,
						worktree = NULL,
						branch = NULL,
						retries = 0,
						rebase_attempts = 0,
						updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
					WHERE id = '$escaped_stale_id';" 2>/dev/null || true
					# Log the state transition
					db "$SUPERVISOR_DB" "INSERT INTO state_log (task_id, from_state, to_state, timestamp, reason)
					VALUES ('$escaped_stale_id', '$stale_status', 'queued',
						strftime('%Y-%m-%dT%H:%M:%SZ','now'),
						'Phase 3b2 reconciliation: PR #$pr_number closed without merge');" 2>/dev/null || true
					# Clean up old worktree if it exists
					cleanup_after_merge "$stale_id" 2>>"$SUPERVISOR_LOG" || true
					write_proof_log --task "$stale_id" --event "reconcile_closed" --stage "phase_3b2" \
						--decision "blocked->queued (PR closed without merge)" \
						--evidence "pr=#$pr_number prev_status=$stale_status" \
						--maker "pulse:phase_3b2" 2>/dev/null || true
					reconciled_closed=$((reconciled_closed + 1))

				else
					# PR is still OPEN — leave the task in its current state
					# Phase 3.5 (rebase retry) or Phase 3.6 (escalation) will handle it
					:
				fi
			done <<<"$stale_tasks"

			if [[ $((reconciled_merged + reconciled_closed + reconciled_obsolete)) -gt 0 ]]; then
				log_success "  Phase 3b2: Reconciled $reconciled_merged merged, $reconciled_closed closed, $reconciled_obsolete obsolete"
			fi
		fi
	fi

	# Phase 3c: Reconcile terminal DB states with GitHub issues (t1038)
	# Tasks can reach terminal states (cancelled, failed, verified) via direct DB
	# updates or manual intervention, bypassing cmd_transition and its issue sync.
	# This sweep finds tasks in terminal states whose GitHub issues are still open
	# and syncs them. Runs at most once per 10 minutes to avoid API rate limits.
	local reconcile_cooldown_file="${SUPERVISOR_DIR}/reconcile-issues-last-run"
	local reconcile_cooldown=600 # 10 minutes
	local should_reconcile=true
	if [[ -f "$reconcile_cooldown_file" ]]; then
		local last_reconcile
		last_reconcile=$(cat "$reconcile_cooldown_file" 2>/dev/null || echo "0")
		local now_epoch
		now_epoch=$(date +%s)
		if [[ $((now_epoch - last_reconcile)) -lt "$reconcile_cooldown" ]]; then
			should_reconcile=false
		fi
	fi

	if [[ "$should_reconcile" == "true" ]] && command -v gh &>/dev/null; then
		# Two queries: (1) cancelled/failed are always safe to close,
		# (2) deployed/verified only if they have a real PR (not no_pr/task_only/empty).
		# This prevents closing issues for false completions from the no_pr cascade.
		local terminal_tasks
		terminal_tasks=$(db "$SUPERVISOR_DB" "
			SELECT id, status, repo FROM tasks
			WHERE (
				status IN ('cancelled', 'failed')
				OR (
					status IN ('verified', 'deployed')
					AND pr_url IS NOT NULL
					AND pr_url != ''
					AND pr_url != 'no_pr'
					AND pr_url != 'task_only'
					AND pr_url != 'verified_complete'
				)
			)
			AND id IN (
				SELECT DISTINCT task_id FROM state_log
				WHERE timestamp > datetime('now', '-7 days')
			)
		;" 2>/dev/null || echo "")

		if [[ -n "$terminal_tasks" ]]; then
			local reconciled=0
			while IFS='|' read -r rec_id rec_status rec_repo; do
				[[ -z "$rec_id" ]] && continue

				# Find the GitHub issue number
				local rec_issue
				rec_issue=$(find_task_issue_number "$rec_id" "$rec_repo" 2>/dev/null || echo "")
				[[ -z "$rec_issue" ]] && continue

				local rec_slug
				rec_slug=$(detect_repo_slug "$rec_repo" 2>/dev/null || echo "")
				[[ -z "$rec_slug" ]] && continue

				# Check if the issue is still open
				local issue_state
				issue_state=$(gh issue view "$rec_issue" --repo "$rec_slug" --json state -q .state 2>/dev/null || echo "")
				if [[ "$issue_state" == "OPEN" ]]; then
					log_info "  Phase 3c: Reconciling $rec_id ($rec_status) — issue #$rec_issue still open"
					sync_issue_status_label "$rec_id" "$rec_status" "reconcile" 2>>"$SUPERVISOR_LOG" || true
					reconciled=$((reconciled + 1))
				fi
			done <<<"$terminal_tasks"

			if [[ "$reconciled" -gt 0 ]]; then
				log_success "  Phase 3c: Reconciled $reconciled issue(s)"
			fi
		fi

		date +%s >"$reconcile_cooldown_file" 2>/dev/null || true
	fi

	# Phase 3.5: Auto-retry blocked merge-conflict tasks (t1029)
	# When a task is blocked with "Merge conflict — auto-rebase failed", periodically
	# re-attempt the rebase after main advances. Other PRs merging often resolve conflicts.
	local max_retry_cycles=3
	local blocked_tasks
	blocked_tasks=$(db "$SUPERVISOR_DB" "SELECT id, repo, error, rebase_attempts, last_main_sha FROM tasks WHERE status = 'blocked' AND error LIKE '%Merge conflict%auto-rebase failed%';" 2>/dev/null || echo "")

	if [[ -n "$blocked_tasks" ]]; then
		while IFS='|' read -r blocked_id blocked_repo _ blocked_rebase_attempts blocked_last_main_sha; do
			[[ -z "$blocked_id" ]] && continue

			# Cap at max_retry_cycles total retry cycles to prevent infinite loops
			if [[ "${blocked_rebase_attempts:-0}" -ge "$max_retry_cycles" ]]; then
				log_info "  Skipping $blocked_id — max retry cycles ($max_retry_cycles) reached"
				continue
			fi

			# Get current main SHA
			local current_main_sha
			current_main_sha=$(git -C "$blocked_repo" rev-parse origin/main 2>/dev/null || echo "")
			if [[ -z "$current_main_sha" ]]; then
				log_warn "  Failed to get origin/main SHA for $blocked_id in $blocked_repo"
				continue
			fi

			# Check if main has advanced since last attempt
			if [[ -n "$blocked_last_main_sha" && "$current_main_sha" == "$blocked_last_main_sha" ]]; then
				# Main hasn't advanced — skip retry
				continue
			fi

			# Main has advanced (or this is first retry) — reset counter and retry
			log_info "  Main advanced for $blocked_id — retrying rebase (attempt $((blocked_rebase_attempts + 1))/$max_retry_cycles)"

			# Update last_main_sha before attempting rebase
			local escaped_blocked_id
			escaped_blocked_id=$(sql_escape "$blocked_id")
			db "$SUPERVISOR_DB" "UPDATE tasks SET last_main_sha = '$current_main_sha' WHERE id = '$escaped_blocked_id';" 2>/dev/null || true

			# Attempt rebase
			if rebase_sibling_pr "$blocked_id" 2>>"$SUPERVISOR_LOG"; then
				log_success "  Auto-rebase retry succeeded for $blocked_id — transitioning to pr_review"
				# Increment rebase_attempts counter
				db "$SUPERVISOR_DB" "UPDATE tasks SET rebase_attempts = $((blocked_rebase_attempts + 1)) WHERE id = '$escaped_blocked_id';" 2>/dev/null || true
				# Transition back to pr_review so CI can run
				cmd_transition "$blocked_id" "pr_review" --error "" 2>>"$SUPERVISOR_LOG" || true
			else
				# Rebase still failed — increment counter and stay blocked
				log_warn "  Auto-rebase retry failed for $blocked_id — staying blocked"
				db "$SUPERVISOR_DB" "UPDATE tasks SET rebase_attempts = $((blocked_rebase_attempts + 1)) WHERE id = '$escaped_blocked_id';" 2>/dev/null || true
			fi
		done <<<"$blocked_tasks"
	fi

	# Phase 3.6: Escalate rebase-blocked PRs to opus worker (t1050)
	# When auto-rebase fails max_retry_cycles times, dispatch an opus worker to
	# manually rebase, resolve conflicts, and merge the PR. Only ONE escalation
	# runs at a time (sequential) so each subsequent rebase has a clean base.
	local escalation_lock="${SUPERVISOR_DIR}/rebase-escalation.lock"
	local escalation_cooldown=300 # 5 minutes between escalations

	# Check if an escalation is already running or recently completed
	local should_escalate=true
	if [[ -f "$escalation_lock" ]]; then
		local lock_pid lock_age
		lock_pid=$(head -1 "$escalation_lock" 2>/dev/null || echo "")
		lock_age=$(($(date +%s) - $(stat -c %Y "$escalation_lock" 2>/dev/null || stat -f %m "$escalation_lock" 2>/dev/null || echo "0")))
		# Check if the lock holder is still alive
		if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
			# Lock holder alive — respect cooldown
			if [[ "$lock_age" -lt "$escalation_cooldown" ]]; then
				should_escalate=false
				log_verbose "  Phase 3.6: escalation in progress (PID $lock_pid, ${lock_age}s/${escalation_cooldown}s)"
			else
				# Running too long — stale, remove
				log_warn "  Phase 3.6: escalation lock stale (PID $lock_pid alive but ${lock_age}s old), removing"
				rm -f "$escalation_lock" 2>/dev/null || true
			fi
		elif [[ "$lock_age" -lt "$escalation_cooldown" ]]; then
			# Lock holder dead but within cooldown — likely just finished
			should_escalate=false
			log_verbose "  Phase 3.6: escalation cooldown (${lock_age}s/${escalation_cooldown}s)"
		else
			# Lock holder dead and past cooldown — stale lock from crashed pulse
			log_info "  Phase 3.6: removing stale escalation lock (PID $lock_pid dead, ${lock_age}s old)"
			rm -f "$escalation_lock" 2>/dev/null || true
		fi
	fi

	if [[ "$should_escalate" == "true" ]]; then
		# Find ONE task that has exhausted auto-rebase retries
		local escalation_candidate
		escalation_candidate=$(db "$SUPERVISOR_DB" "
			SELECT t.id, t.repo, t.pr_url, t.branch, t.rebase_attempts
			FROM tasks t
			WHERE t.status = 'blocked'
			  AND t.error LIKE '%Merge conflict%auto-rebase failed%'
			  AND t.rebase_attempts >= $max_retry_cycles
			  AND t.pr_url IS NOT NULL AND t.pr_url != '' AND t.pr_url != 'no_pr'
			ORDER BY t.rebase_attempts ASC, t.id ASC
			LIMIT 1;
		" 2>/dev/null || echo "")

		if [[ -n "$escalation_candidate" ]]; then
			local esc_id esc_repo esc_pr esc_branch esc_attempts
			IFS='|' read -r esc_id esc_repo esc_pr esc_branch esc_attempts <<<"$escalation_candidate"

			if [[ -n "$esc_id" ]]; then
				log_info "  Phase 3.6: escalating $esc_id to opus worker (rebase_attempts=$esc_attempts, pr=$esc_pr)"

				# Resolve AI CLI
				local esc_ai_cli
				esc_ai_cli=$(resolve_ai_cli 2>/dev/null || echo "")
				if [[ -z "$esc_ai_cli" ]]; then
					log_warn "  Phase 3.6: no AI CLI available for escalation"
				else
					# Find the worktree path
					local esc_worktree=""
					local esc_wt_row
					esc_wt_row=$(db "$SUPERVISOR_DB" "SELECT worktree FROM tasks WHERE id = '$(sql_escape "$esc_id")';" 2>/dev/null || echo "")
					if [[ -n "$esc_wt_row" && -d "$esc_wt_row" ]]; then
						esc_worktree="$esc_wt_row"
					fi

					# Build the escalation prompt
					local esc_prompt="You are resolving a merge conflict that automated tools could not handle.

TASK: $esc_id
BRANCH: $esc_branch
PR: $esc_pr
REPO: $esc_repo
WORKTREE: ${esc_worktree:-$esc_repo}

STEPS:
1. cd to the worktree (or repo if no worktree)
2. Run: git fetch origin main
3. Abort any in-progress rebase: git rebase --abort (ignore errors)
4. Clean any dirty state: git stash push -m 'pre-escalation' (ignore errors)
5. Run: git rebase origin/main
6. If conflicts occur, resolve ALL of them:
   - Read each conflicting file
   - Understand both sides' intent
   - Merge intelligently (keep both sides' changes where possible)
   - Remove ALL conflict markers
   - git add each resolved file
   - git rebase --continue
   - Repeat for each commit in the rebase
7. After rebase completes: git push --force-with-lease origin $esc_branch
8. Verify the PR is no longer in conflict: gh pr view $esc_pr --json mergeStateStatus
9. If CI passes, merge: gh pr merge $esc_pr --squash
10. Output ONLY: 'ESCALATION_MERGED: $esc_id' if merged, 'ESCALATION_REBASED: $esc_id' if rebased but not merged, or 'ESCALATION_FAILED: reason' if failed

RULES:
- Do NOT modify the intent of any code — only resolve conflicts
- Prefer the feature branch for new functionality, main for structural changes
- If a file has been deleted on main but modified on the branch, keep the branch version
- Do NOT create new commits beyond what the rebase produces"

					# Resolve model — use opus for complex conflict resolution
					local esc_model
					esc_model=$(resolve_model "opus" "$esc_ai_cli" 2>/dev/null || echo "")

					# Dispatch the worker
					local esc_log_dir="${SUPERVISOR_DIR}/logs"
					mkdir -p "$esc_log_dir" 2>/dev/null || true
					local esc_log_file
					esc_log_file="${esc_log_dir}/escalation-${esc_id}-$(date +%Y%m%d-%H%M%S).log"

					local esc_workdir="${esc_worktree:-$esc_repo}"
					if [[ "$esc_ai_cli" == "opencode" ]]; then
						(cd "$esc_workdir" && $esc_ai_cli run \
							${esc_model:+--model "$esc_model"} \
							--format json \
							--title "escalation-rebase-${esc_id}" \
							"$esc_prompt" \
							>"$esc_log_file" 2>&1) &
						local esc_pid=$!
					else
						(cd "$esc_workdir" && $esc_ai_cli -p "$esc_prompt" \
							${esc_model:+--model "$esc_model"} \
							>"$esc_log_file" 2>&1) &
						local esc_pid=$!
					fi

					# Record the escalation in the DB
					db "$SUPERVISOR_DB" "UPDATE tasks SET
						status = 'running',
						error = 'Escalation: opus rebase worker (PID $esc_pid)',
						worker_pid = $esc_pid,
						updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
					WHERE id = '$(sql_escape "$esc_id")';" 2>/dev/null || true

					# Create lock file AFTER successful dispatch (stores worker PID for stale detection)
					echo "$esc_pid" >"$escalation_lock" 2>/dev/null || true

					log_success "  Phase 3.6: dispatched opus worker PID $esc_pid for $esc_id"
					send_task_notification "$esc_id" "escalated" "Opus rebase worker dispatched (PID $esc_pid)" 2>>"$SUPERVISOR_LOG" || true
				fi
			fi
		fi
	fi

	# t1052: Flush deferred batch completions after all lifecycle phases.
	# Runs retrospective, session review, distillation, and auto-release
	# once per batch that became complete during this pulse, instead of
	# once per task transition. This is the key performance fix — reduces
	# overhead from O(tasks_per_batch) to O(1) per batch.
	flush_deferred_batch_completions 2>>"$SUPERVISOR_LOG" || true

	# Phase 4: Worker health checks - detect dead, hung, and orphaned workers
	# t1196: Per-task-type hang timeout via get_task_timeout() — replaces single global value.
	# Absolute max runtime: kill workers regardless of log activity.
	# Prevents runaway workers (e.g., shellcheck on huge files) from accumulating
	# and exhausting system memory. Default 4 hours.
	local worker_max_runtime_seconds="${SUPERVISOR_WORKER_MAX_RUNTIME:-14400}" # 4 hour default (t314: restored after merge overwrite)

	if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
		for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
			[[ -f "$pid_file" ]] || continue
			local health_pid
			health_pid=$(cat "$pid_file")
			local health_task
			health_task=$(basename "$pid_file" .pid)
			local health_status
			health_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$health_task")';" 2>/dev/null || echo "")

			if ! kill -0 "$health_pid" 2>/dev/null; then
				# Dead worker: PID no longer exists
				rm -f "$pid_file"
				# t1222: Clean up hang warning marker for dead workers
				rm -f "$SUPERVISOR_DIR/pids/${health_task}.hang-warned"
				if [[ "$health_status" == "running" || "$health_status" == "dispatched" ]]; then
					log_warn "  Dead worker for $health_task (PID $health_pid gone, was $health_status) — evaluating"
					cmd_evaluate "$health_task" --no-ai 2>>"$SUPERVISOR_LOG" || {
						# Evaluation failed — force transition so task doesn't stay stuck
						cmd_transition "$health_task" "failed" --error "Worker process died (PID $health_pid)" 2>>"$SUPERVISOR_LOG" || true
						failed_count=$((failed_count + 1))
						attempt_self_heal "$health_task" "failed" "Worker process died" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
					}
				fi
			else
				# Alive worker: check for hung state or max runtime exceeded
				if [[ "$health_status" == "running" || "$health_status" == "dispatched" ]]; then
					local should_kill=false
					local kill_reason=""

					# t1196: Resolve per-task-type hang timeout from description/tags
					local health_task_desc
					health_task_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$(sql_escape "$health_task")';" 2>/dev/null || echo "")
					local worker_timeout_seconds
					worker_timeout_seconds=$(get_task_timeout "$health_task_desc")

					# Check 1: Absolute max runtime (prevents indefinite accumulation)
					local started_at
					started_at=$(db "$SUPERVISOR_DB" "SELECT started_at FROM tasks WHERE id = '$(sql_escape "$health_task")';" 2>/dev/null || echo "")
					if [[ -n "$started_at" ]]; then
						local started_epoch
						started_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || date -d "$started_at" +%s 2>/dev/null || echo "0")
						local now_epoch
						now_epoch=$(date +%s)
						local runtime_seconds=$((now_epoch - started_epoch))
						if [[ "$started_epoch" -gt 0 && "$runtime_seconds" -gt "$worker_max_runtime_seconds" ]]; then
							should_kill=true
							kill_reason="Max runtime exceeded (${runtime_seconds}s > ${worker_max_runtime_seconds}s limit)"
						fi
					fi

					# Check 2: Hung state (no log output for timeout period)
					# t1199: Use per-task hung timeout based on ~estimate (2x estimate, 4h cap, 30m default)
					# t1222: Two-phase hang detection — graceful SIGTERM at 50% timeout, hard SIGKILL at 100%.
					#   Saves ~15 minutes per hung worker by terminating early and retrying immediately
					#   instead of waiting the full timeout. The wrapper's EXIT trap handles child cleanup.
					if [[ "$should_kill" == "false" ]]; then
						local log_file
						log_file=$(db "$SUPERVISOR_DB" "SELECT log_file FROM tasks WHERE id = '$(sql_escape "$health_task")';" 2>/dev/null || echo "")
						if [[ -n "$log_file" && -f "$log_file" ]]; then
							local log_age_seconds=0
							local log_mtime
							log_mtime=$(stat -c %Y "$log_file" 2>/dev/null || stat -f %m "$log_file" 2>/dev/null || echo "0")
							local now_epoch
							now_epoch=$(date +%s)
							log_age_seconds=$((now_epoch - log_mtime))
							# Compute per-task hung timeout from ~estimate field (t1199)
							local task_hung_timeout
							task_hung_timeout=$(get_task_hung_timeout "$health_task" 2>/dev/null || echo "$worker_timeout_seconds")

							# t1222: Two-phase hang detection (disable with SUPERVISOR_HANG_GRACEFUL=false)
							local hang_graceful="${SUPERVISOR_HANG_GRACEFUL:-true}"
							local hang_warn_threshold=$((task_hung_timeout / 2))
							local hang_warn_marker="$SUPERVISOR_DIR/pids/${health_task}.hang-warned"

							if [[ "$log_age_seconds" -gt "$task_hung_timeout" ]]; then
								# Phase 2 (or single-phase if graceful disabled): Full timeout exceeded — hard kill
								should_kill=true
								kill_reason="Worker hung (no output for ${log_age_seconds}s, timeout ${task_hung_timeout}s)"
								rm -f "$hang_warn_marker"
							elif [[ "$hang_graceful" == "true" && "$log_age_seconds" -gt "$hang_warn_threshold" ]]; then
								# Phase 1: 50% timeout exceeded — attempt graceful termination
								if [[ ! -f "$hang_warn_marker" ]]; then
									# First detection at 50%: send SIGTERM for graceful shutdown
									log_warn "  t1222: Worker $health_task possibly hung (no output for ${log_age_seconds}s, 50% of ${task_hung_timeout}s timeout)"
									log_warn "  t1222: Sending SIGTERM for graceful shutdown (PID $health_pid)"
									echo "$now_epoch" >"$hang_warn_marker" 2>/dev/null || true
									# SIGTERM triggers the wrapper's cleanup_children trap
									kill -TERM "$health_pid" 2>/dev/null || true
								else
									# Already warned — check if SIGTERM worked (grace period: 2 pulse cycles ~4min)
									local warn_epoch=0
									warn_epoch=$(cat "$hang_warn_marker" 2>/dev/null || echo "0")
									warn_epoch="${warn_epoch:-0}"
									local grace_elapsed=$((now_epoch - warn_epoch))
									# Grace period: min(240s, max(120s, 25% of hung timeout))
									# At 2-min cron this spans 1-2 cycles; at 5-min cron the hard kill fires on the next cycle
									local grace_period=$((task_hung_timeout / 4))
									if [[ "$grace_period" -gt 240 ]]; then
										grace_period=240
									fi
									if [[ "$grace_period" -lt 120 ]]; then
										grace_period=120
									fi
									if [[ "$grace_elapsed" -gt "$grace_period" ]]; then
										# Grace period expired, worker didn't terminate — escalate to hard kill
										should_kill=true
										kill_reason="Worker hung (graceful SIGTERM failed after ${grace_elapsed}s grace, no output for ${log_age_seconds}s)"
										rm -f "$hang_warn_marker"
									fi
								fi
							fi
						fi
					fi

					if [[ "$should_kill" == "true" ]]; then
						log_warn "  Killing worker for $health_task (PID $health_pid): $kill_reason"
						# Kill all descendants first (shellcheck, node, bash-language-server, etc.)
						_kill_descendants "$health_pid"
						kill "$health_pid" 2>/dev/null || true
						sleep 2
						# Force kill if still alive
						if kill -0 "$health_pid" 2>/dev/null; then
							kill -9 "$health_pid" 2>/dev/null || true
						fi
						rm -f "$pid_file"
						# t1222: Clean up hang warning marker on kill
						rm -f "$SUPERVISOR_DIR/pids/${health_task}.hang-warned"

						# t1074: Auto-retry timed-out workers up to max_retries before marking failed.
						# Check if the task has a PR already (worker may have created one before timeout).
						# If so, transition to pr_review instead of re-queuing from scratch.
						local task_retries task_max_retries task_pr_url
						task_retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$(sql_escape "$health_task")';" 2>/dev/null || echo "0")
						task_max_retries=$(db "$SUPERVISOR_DB" "SELECT max_retries FROM tasks WHERE id = '$(sql_escape "$health_task")';" 2>/dev/null || echo "3")
						task_pr_url=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$(sql_escape "$health_task")';" 2>/dev/null || echo "")

						if [[ -n "$task_pr_url" && "$task_pr_url" != "null" ]]; then
							# Worker created a PR before timing out — let the PR lifecycle handle it
							log_info "  $health_task has PR ($task_pr_url) — transitioning to pr_review instead of failed"
							cmd_transition "$health_task" "pr_review" --error "" 2>>"$SUPERVISOR_LOG" || true
						elif [[ "$task_retries" -lt "$task_max_retries" ]]; then
							# Retries remaining — increment and re-queue
							local new_retries=$((task_retries + 1))
							log_info "  $health_task timed out — re-queuing (retry $new_retries/$task_max_retries)"
							db "$SUPERVISOR_DB" "UPDATE tasks SET retries = $new_retries WHERE id = '$(sql_escape "$health_task")';" 2>/dev/null || true
							cmd_transition "$health_task" "queued" --error "Retry $new_retries: $kill_reason" 2>>"$SUPERVISOR_LOG" || true
							# Auto-escalate model so retry uses stronger model (t314 wiring)
							escalate_model_on_failure "$health_task" 2>>"$SUPERVISOR_LOG" || true
						else
							# Retries exhausted — mark as failed
							cmd_transition "$health_task" "failed" --error "$kill_reason (retries exhausted: $task_retries/$task_max_retries)" 2>>"$SUPERVISOR_LOG" || true
							failed_count=$((failed_count + 1))
							escalate_model_on_failure "$health_task" 2>>"$SUPERVISOR_LOG" || true
							attempt_self_heal "$health_task" "failed" "$kill_reason" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
						fi
					fi
				fi
			fi
		done
	fi

	# Phase 4b: DB orphans — tasks marked running/dispatched/evaluating with no PID file
	# t1208: Extended to include 'evaluating' state — Phase 0.7 covers stale-by-time
	# but tasks can also become orphaned when the PID file is missing entirely
	# (e.g., supervisor killed mid-dispatch before PID file was written).
	local db_orphans
	db_orphans=$(db "$SUPERVISOR_DB" "SELECT id, status FROM tasks WHERE status IN ('running', 'dispatched', 'evaluating');" 2>/dev/null || echo "")
	if [[ -n "$db_orphans" ]]; then
		while IFS='|' read -r orphan_id orphan_status; do
			[[ -n "$orphan_id" ]] || continue
			local orphan_pid_file="$SUPERVISOR_DIR/pids/${orphan_id}.pid"
			if [[ ! -f "$orphan_pid_file" ]]; then
				log_warn "  DB orphan: $orphan_id marked $orphan_status but no PID file — evaluating (t1208)"
				cmd_evaluate "$orphan_id" --no-ai 2>>"$SUPERVISOR_LOG" || {
					cmd_transition "$orphan_id" "failed" --error "No worker process found (DB orphan, was $orphan_status)" 2>>"$SUPERVISOR_LOG" || true
					failed_count=$((failed_count + 1))
					# Auto-escalate model on failure so self-heal retry uses stronger model (t314 wiring)
					escalate_model_on_failure "$orphan_id" 2>>"$SUPERVISOR_LOG" || true
					attempt_self_heal "$orphan_id" "failed" "No worker process found" "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true
				}
			fi
		done <<<"$db_orphans"
	fi

	# Phase 4b2: Stale pr_review recovery (t1208)
	# Tasks in 'pr_review' are processed by Phase 3 (process_post_pr_lifecycle) each
	# pulse. However, if cmd_pr_lifecycle fails repeatedly or the PR is in an
	# unexpected state, the task can get stuck in pr_review indefinitely.
	# After SUPERVISOR_PR_REVIEW_STALE_SECONDS (default 3600 = 1h), force a
	# re-attempt via cmd_pr_lifecycle. If that also fails, log a warning so the
	# operator can investigate — do NOT auto-fail pr_review tasks since the PR
	# may be legitimately waiting for CI or human review.
	local pr_review_stale_seconds="${SUPERVISOR_PR_REVIEW_STALE_SECONDS:-3600}"
	local stale_pr_review
	stale_pr_review=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, pr_url, updated_at
        FROM tasks
        WHERE status = 'pr_review'
        AND updated_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${pr_review_stale_seconds} seconds')
        ORDER BY updated_at ASC;
    " 2>/dev/null || echo "")

	if [[ -n "$stale_pr_review" ]]; then
		local pr_review_recovered=0
		while IFS='|' read -r spr_id spr_pr_url spr_updated; do
			[[ -n "$spr_id" ]] || continue
			log_warn "  Stale pr_review: $spr_id (last updated: ${spr_updated:-unknown}, >${pr_review_stale_seconds}s) — re-attempting lifecycle (t1208)"
			if cmd_pr_lifecycle "$spr_id" 2>>"$SUPERVISOR_LOG"; then
				local spr_new_status
				spr_new_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$spr_id")';" 2>/dev/null || echo "")
				if [[ "$spr_new_status" != "pr_review" ]]; then
					log_info "  Phase 4b2: $spr_id advanced from pr_review → $spr_new_status"
					pr_review_recovered=$((pr_review_recovered + 1))
				else
					log_warn "  Phase 4b2: $spr_id still in pr_review after lifecycle attempt — may need manual review (PR: ${spr_pr_url:-none})"
				fi
			else
				log_warn "  Phase 4b2: cmd_pr_lifecycle failed for stale $spr_id — will retry next pulse (PR: ${spr_pr_url:-none})"
			fi
		done <<<"$stale_pr_review"
		if [[ "$pr_review_recovered" -gt 0 ]]; then
			log_info "  Phase 4b2: $pr_review_recovered stale pr_review task(s) advanced"
		fi
	fi

	# Phase 4c: Cancel stale diagnostic subtasks whose parent is already resolved
	# Diagnostic tasks (diagnostic_of != NULL) become stale when the parent task
	# reaches a terminal state (deployed, cancelled, failed) before the diagnostic
	# is dispatched. Cancel them to free queue slots.
	local stale_diags
	stale_diags=$(db "$SUPERVISOR_DB" "
        SELECT d.id, d.diagnostic_of, p.status AS parent_status
        FROM tasks d
        JOIN tasks p ON d.diagnostic_of = p.id
        WHERE d.diagnostic_of IS NOT NULL
          AND d.status IN ('queued', 'retrying')
          AND p.status IN ('deployed', 'cancelled', 'failed', 'complete', 'merged');
    " 2>/dev/null || echo "")

	if [[ -n "$stale_diags" ]]; then
		while IFS='|' read -r diag_id parent_id parent_status; do
			[[ -n "$diag_id" ]] || continue
			log_info "  Cancelling stale diagnostic $diag_id (parent $parent_id is $parent_status)"
			cmd_transition "$diag_id" "cancelled" --error "Parent task $parent_id already $parent_status" 2>>"$SUPERVISOR_LOG" || true
		done <<<"$stale_diags"
	fi

	# Phase 4d: Auto-recover stuck deploying tasks (t222, t248)
	# Tasks can get stuck in 'deploying' if the deploy succeeds but the
	# transition to 'deployed' fails (e.g., DB write error, process killed
	# mid-transition). Detect tasks in 'deploying' state for longer than
	# the deploy timeout and auto-recover them via process_post_pr_lifecycle
	# (which now handles the deploying state in Step 4b of cmd_pr_lifecycle).
	# t248: Reduced from 600s (10min) to 120s (2min) for faster recovery
	local deploying_timeout_seconds="${SUPERVISOR_DEPLOY_TIMEOUT:-120}" # 2 min default
	local stuck_deploying
	stuck_deploying=$(db "$SUPERVISOR_DB" "
        SELECT id, updated_at FROM tasks
        WHERE status = 'deploying'
        AND updated_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${deploying_timeout_seconds} seconds');
    " 2>/dev/null || echo "")

	if [[ -n "$stuck_deploying" ]]; then
		while IFS='|' read -r stuck_id stuck_updated; do
			[[ -n "$stuck_id" ]] || continue
			log_warn "  Stuck deploying: $stuck_id (last updated: ${stuck_updated:-unknown}, timeout: ${deploying_timeout_seconds}s) — triggering recovery (t222)"
			# process_post_pr_lifecycle will pick this up and run cmd_pr_lifecycle
			# which now handles the deploying state in Step 4b
			cmd_pr_lifecycle "$stuck_id" 2>>"$SUPERVISOR_LOG" || {
				log_error "  Recovery failed for stuck deploying task $stuck_id — forcing to deployed"
				cmd_transition "$stuck_id" "deployed" --error "Force-recovered from stuck deploying (t222)" 2>>"$SUPERVISOR_LOG" || true
			}
		done <<<"$stuck_deploying"
	fi

	# Phase 5: Summary
	local total_running
	total_running=$(cmd_running_count "${batch_id:-}")
	local total_queued
	total_queued=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status = 'queued';")
	local total_complete
	total_complete=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('complete', 'deployed', 'verified');")
	local total_pr_review
	total_pr_review=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('pr_review', 'review_triage', 'merging', 'merged', 'deploying');")
	local total_verifying
	total_verifying=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('verifying', 'verify_failed');")

	local total_failed
	total_failed=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('failed', 'blocked');")
	local total_tasks
	total_tasks=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks;")

	# System resource snapshot (t135.15.3)
	local resource_output
	resource_output=$(check_system_load 2>/dev/null || echo "")
	local sys_load_1m sys_load_5m sys_cpu_cores sys_load_ratio sys_memory sys_proc_count sys_supervisor_procs sys_overloaded
	sys_load_1m=$(echo "$resource_output" | grep '^load_1m=' | cut -d= -f2)
	sys_load_5m=$(echo "$resource_output" | grep '^load_5m=' | cut -d= -f2)
	sys_cpu_cores=$(echo "$resource_output" | grep '^cpu_cores=' | cut -d= -f2)
	sys_load_ratio=$(echo "$resource_output" | grep '^load_ratio=' | cut -d= -f2)
	sys_memory=$(echo "$resource_output" | grep '^memory_pressure=' | cut -d= -f2)
	sys_proc_count=$(echo "$resource_output" | grep '^process_count=' | cut -d= -f2)
	sys_supervisor_procs=$(echo "$resource_output" | grep '^supervisor_process_count=' | cut -d= -f2)
	sys_overloaded=$(echo "$resource_output" | grep '^overloaded=' | cut -d= -f2)

	echo ""
	log_info "Pulse summary:"
	log_info "  Evaluated:  $((completed_count + failed_count)) workers"
	log_info "  Completed:  $completed_count"
	log_info "  Failed:     $failed_count"
	log_info "  Dispatched: $dispatched_count new"
	log_info "  Running:    $total_running"
	log_info "  Queued:     $total_queued"
	log_info "  Post-PR:    $total_pr_review"
	log_info "  Verifying:  $total_verifying"
	log_info "  Total done: $total_complete / $total_tasks"

	# t1208: State/worker count mismatch warning
	# Detect when DB shows active states (running/evaluating/pr_review) but
	# no live PID files exist — indicates stale state entries not yet cleaned up.
	# This warning surfaces the inconsistency so operators can investigate.
	local db_active_running db_active_evaluating db_active_pr_review
	db_active_running=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status IN ('running', 'dispatched');" 2>/dev/null || echo "0")
	db_active_evaluating=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status = 'evaluating';" 2>/dev/null || echo "0")
	db_active_pr_review=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE status = 'pr_review';" 2>/dev/null || echo "0")

	# Count live PID files
	local live_pid_count=0
	if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
		for _pid_f in "$SUPERVISOR_DIR/pids"/*.pid; do
			[[ -f "$_pid_f" ]] || continue
			local _pid
			_pid=$(cat "$_pid_f" 2>/dev/null || echo "")
			if [[ -n "$_pid" ]] && kill -0 "$_pid" 2>/dev/null; then
				live_pid_count=$((live_pid_count + 1))
			fi
		done
	fi

	# Warn when DB shows running/evaluating tasks but no live workers exist
	local db_active_workers=$((db_active_running + db_active_evaluating))
	if [[ "$db_active_workers" -gt 0 && "$live_pid_count" -eq 0 ]]; then
		log_warn "  STATE MISMATCH: DB shows ${db_active_running} running + ${db_active_evaluating} evaluating but 0 live workers (t1208)"
		log_warn "  Stale state recovery (Phase 0.7/0.8/4b) should clean these up next pulse"
	elif [[ "$db_active_workers" -gt "$live_pid_count" ]]; then
		log_warn "  STATE MISMATCH: DB shows $db_active_workers active tasks but only $live_pid_count live workers (t1208)"
	fi

	# Warn when pr_review count is unexpectedly high (>10 suggests stuck tasks)
	local pr_review_warn_threshold="${SUPERVISOR_PR_REVIEW_WARN_THRESHOLD:-10}"
	if [[ "$db_active_pr_review" -gt "$pr_review_warn_threshold" ]]; then
		log_warn "  PR_REVIEW BACKLOG: $db_active_pr_review tasks in pr_review state (threshold: $pr_review_warn_threshold) — check for stuck tasks (t1208)"
	fi

	# Resource stats (t135.15.3)
	if [[ -n "$sys_load_1m" ]]; then
		local load_color="$GREEN"
		if [[ "$sys_overloaded" == "true" ]]; then
			load_color="$RED"
		elif [[ -n "$sys_load_ratio" && "$sys_load_ratio" -gt 100 ]]; then
			load_color="$YELLOW"
		fi
		local mem_color="$GREEN"
		if [[ "$sys_memory" == "high" ]]; then
			mem_color="$RED"
		elif [[ "$sys_memory" == "medium" ]]; then
			mem_color="$YELLOW"
		fi
		echo ""
		log_info "System resources:"
		echo -e "  ${BLUE}[SUPERVISOR]${NC}   CPU:      ${load_color}${sys_load_ratio}%${NC} used (${sys_cpu_cores} cores, load avg: ${sys_load_1m}/${sys_load_5m})"
		echo -e "  ${BLUE}[SUPERVISOR]${NC}   Memory:   ${mem_color}${sys_memory}${NC}"
		echo -e "  ${BLUE}[SUPERVISOR]${NC}   Procs:    ${sys_proc_count} total, ${sys_supervisor_procs} supervisor"
		# Show adaptive concurrency for the active batch
		if [[ -n "$batch_id" ]]; then
			local display_base display_max display_load_factor display_adaptive
			local escaped_display_batch
			escaped_display_batch=$(sql_escape "$batch_id")
			display_base=$(db "$SUPERVISOR_DB" "SELECT concurrency FROM batches WHERE id = '$escaped_display_batch';" 2>/dev/null || echo "?")
			display_max=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_concurrency, 0) FROM batches WHERE id = '$escaped_display_batch';" 2>/dev/null || echo "0")
			display_load_factor=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_load_factor, 2) FROM batches WHERE id = '$escaped_display_batch';" 2>/dev/null || echo "2")
			display_adaptive=$(calculate_adaptive_concurrency "${display_base:-4}" "${display_load_factor:-2}" "${display_max:-0}")
			local adaptive_label="base:${display_base}"
			if [[ "$display_adaptive" -gt "${display_base:-0}" ]]; then
				adaptive_label="${adaptive_label} ${GREEN}scaled:${display_adaptive}${NC}"
			elif [[ "$display_adaptive" -lt "${display_base:-0}" ]]; then
				adaptive_label="${adaptive_label} ${YELLOW}throttled:${display_adaptive}${NC}"
			else
				adaptive_label="${adaptive_label} effective:${display_adaptive}"
			fi
			local cap_display="auto"
			[[ "${display_max:-0}" -gt 0 ]] && cap_display="$display_max"
			echo -e "  ${BLUE}[SUPERVISOR]${NC}   Workers:  ${adaptive_label} (cap:${cap_display})"
		fi
		if [[ "$sys_overloaded" == "true" ]]; then
			echo -e "  ${BLUE}[SUPERVISOR]${NC}   ${RED}OVERLOADED${NC} - adaptive throttling active"
		fi

	fi

	# macOS notification on progress (when something changed this pulse)
	if [[ $((completed_count + failed_count + dispatched_count)) -gt 0 ]]; then
		local batch_label="${batch_id:-all tasks}"
		notify_batch_progress "$total_complete" "$total_tasks" "$total_failed" "$batch_label" 2>/dev/null || true
	fi

	# Phase 4: Periodic process hygiene - clean up orphaned worker processes
	# Runs every pulse to prevent accumulation between cleanup calls
	local orphan_killed=0
	if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
		for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
			[[ -f "$pid_file" ]] || continue
			local cleanup_tid
			cleanup_tid=$(basename "$pid_file" .pid)
			local cleanup_status
			cleanup_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$cleanup_tid")';" 2>/dev/null || echo "")
			case "$cleanup_status" in
			complete | failed | cancelled | blocked | deployed | verified | verify_failed | pr_review | review_triage | merging | merged | deploying | verifying)
				cleanup_worker_processes "$cleanup_tid" 2>/dev/null || true
				orphan_killed=$((orphan_killed + 1))
				;;
			esac
		done
	fi
	if [[ "$orphan_killed" -gt 0 ]]; then
		log_info "  Cleaned:    $orphan_killed stale worker processes"
	fi

	# Phase 4e: System-wide orphan process sweep + memory pressure emergency kill
	# Catches processes that escaped PID-file tracking (e.g., PID file deleted,
	# never written, or child processes like shellcheck/node that outlived their parent).
	# Also triggers emergency cleanup when memory pressure is critical.
	local sweep_killed=0

	# Build a set of PIDs we should NOT kill (active tracked workers + this process chain)
	local protected_pids=""
	if [[ -d "$SUPERVISOR_DIR/pids" ]]; then
		for pid_file in "$SUPERVISOR_DIR/pids"/*.pid; do
			[[ -f "$pid_file" ]] || continue
			local sweep_pid
			sweep_pid=$(cat "$pid_file" 2>/dev/null || echo "")
			[[ -z "$sweep_pid" ]] && continue
			local sweep_task_status
			sweep_task_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$(basename "$pid_file" .pid)")';" 2>/dev/null || echo "")
			if [[ "$sweep_task_status" == "running" || "$sweep_task_status" == "dispatched" ]] && kill -0 "$sweep_pid" 2>/dev/null; then
				protected_pids="${protected_pids} ${sweep_pid}"
				local sweep_descendants
				sweep_descendants=$(_list_descendants "$sweep_pid" 2>/dev/null || true)
				if [[ -n "$sweep_descendants" ]]; then
					protected_pids="${protected_pids} ${sweep_descendants}"
				fi
			fi
		done
	fi
	# Protect this process chain
	local self_pid=$$
	while [[ "$self_pid" -gt 1 ]] 2>/dev/null; do
		protected_pids="${protected_pids} ${self_pid}"
		self_pid=$(ps -o ppid= -p "$self_pid" 2>/dev/null | tr -d ' ')
		[[ -z "$self_pid" ]] && break
	done

	# Find orphaned opencode/shellcheck/bash-language-server processes with PPID=1
	# PPID=1 means the parent died and the process was reparented to init/launchd
	local orphan_candidates
	orphan_candidates=$(pgrep -f 'opencode|shellcheck|bash-language-server' 2>/dev/null || true)
	if [[ -n "$orphan_candidates" ]]; then
		while read -r opid; do
			[[ -z "$opid" ]] && continue
			# Skip protected PIDs
			if echo " ${protected_pids} " | grep -q " ${opid} "; then
				continue
			fi
			# Only kill orphans (PPID=1) — processes whose parent has died
			local oppid
			oppid=$(ps -o ppid= -p "$opid" 2>/dev/null | tr -d ' ')
			[[ "$oppid" != "1" ]] && continue

			local ocmd
			ocmd=$(ps -o args= -p "$opid" 2>/dev/null | head -c 100)
			log_warn "  Killing orphaned process PID $opid (PPID=1): $ocmd"
			_kill_descendants "$opid"
			kill "$opid" 2>/dev/null || true
			sleep 0.5
			if kill -0 "$opid" 2>/dev/null; then
				kill -9 "$opid" 2>/dev/null || true
			fi
			sweep_killed=$((sweep_killed + 1))
		done <<<"$orphan_candidates"
	fi

	# Memory pressure emergency kill: if memory is critical, kill ALL non-protected
	# worker processes regardless of PPID. This is the last line of defence against
	# the system running out of RAM and becoming unresponsive.
	if [[ "${sys_memory:-}" == "high" ]]; then
		log_error "  CRITICAL: Memory pressure HIGH — emergency worker cleanup"
		local emergency_candidates
		emergency_candidates=$(pgrep -f 'opencode|shellcheck|bash-language-server' 2>/dev/null || true)
		if [[ -n "$emergency_candidates" ]]; then
			while read -r epid; do
				[[ -z "$epid" ]] && continue
				if echo " ${protected_pids} " | grep -q " ${epid} "; then
					continue
				fi
				local ecmd
				ecmd=$(ps -o args= -p "$epid" 2>/dev/null | head -c 100)
				log_warn "  Emergency kill PID $epid: $ecmd"
				_kill_descendants "$epid"
				kill -9 "$epid" 2>/dev/null || true
				sweep_killed=$((sweep_killed + 1))
			done <<<"$emergency_candidates"
		fi
	fi

	if [[ "$sweep_killed" -gt 0 ]]; then
		log_warn "  Phase 4e: Killed $sweep_killed orphaned/emergency processes"
	fi

	# Phase 6: Orphaned PR scanner — broad sweep (t210, t216)
	# Detect PRs that workers created but the supervisor missed during evaluation.
	# Throttled internally (10-minute interval) to avoid excessive GH API calls.
	# Note: Phase 1 now runs an eager per-task scan immediately after evaluation
	# (scan_orphaned_pr_for_task), so this broad sweep mainly catches edge cases
	# like tasks that were already in failed/blocked state before the eager scan
	# was introduced, or tasks evaluated by Phase 4b DB orphan detection.
	scan_orphaned_prs "${batch_id:-}" 2>>"$SUPERVISOR_LOG" || true

	# Phase 7: Reconcile TODO.md for any stale tasks (t160)
	# Runs when completed tasks exist and nothing is actively running/queued
	if [[ "$total_running" -eq 0 && "$total_queued" -eq 0 && "$total_complete" -gt 0 ]]; then
		cmd_reconcile_todo ${batch_id:+--batch "$batch_id"} 2>>"$SUPERVISOR_LOG" || true
	fi

	# Phase 7b: Bidirectional DB<->TODO.md reconciliation (t1001)
	# Fills gaps not covered by Phase 7:
	#   - DB failed/blocked tasks with no TODO.md annotation
	#   - Tasks marked [x] in TODO.md but DB still in non-terminal state
	#   - DB orphans with no TODO.md entry (logged as warnings)
	# Runs when nothing is actively running/queued to avoid mid-flight interference.
	if [[ "$total_running" -eq 0 && "$total_queued" -eq 0 ]]; then
		cmd_reconcile_db_todo ${batch_id:+--batch "$batch_id"} 2>>"$SUPERVISOR_LOG" || true
	fi

	# Phase 8: Issue-sync reconciliation (t179.3)
	# Close stale GitHub issues and fix ref:GH# drift.
	# Runs periodically (every ~50 min) when no workers active, to avoid
	# excessive GH API calls. Uses a timestamp file to throttle.
	if [[ "$total_running" -eq 0 && "$total_queued" -eq 0 ]]; then
		local issue_sync_interval=3000 # seconds (~50 min)
		local issue_sync_stamp="$SUPERVISOR_DIR/issue-sync-last-run"
		local now_epoch
		now_epoch=$(date +%s)
		local last_run=0
		if [[ -f "$issue_sync_stamp" ]]; then
			last_run=$(cat "$issue_sync_stamp" 2>/dev/null || echo 0)
		fi
		local elapsed=$((now_epoch - last_run))
		if [[ "$elapsed" -ge "$issue_sync_interval" ]]; then
			log_info "  Phase 8: Issue-sync reconciliation (${elapsed}s since last run)"
			# Find a repo with TODO.md to run against
			local sync_repo=""
			sync_repo=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks LIMIT 1;" 2>/dev/null || echo "")
			if [[ -z "$sync_repo" ]]; then
				sync_repo="$(pwd)"
			fi
			local issue_sync_script="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/issue-sync-helper.sh"
			if [[ -f "$issue_sync_script" && -f "$sync_repo/TODO.md" ]]; then
				# Run reconcile to fix ref:GH# drift
				bash "$issue_sync_script" reconcile --verbose 2>>"$SUPERVISOR_LOG" || true
				# Run close to close stale issues for completed tasks
				bash "$issue_sync_script" close --verbose 2>>"$SUPERVISOR_LOG" || true
				echo "$now_epoch" >"$issue_sync_stamp"
				log_info "  Phase 8: Issue-sync complete"
			else
				log_verbose "  Phase 8: Skipped (issue-sync-helper.sh or TODO.md not found)"
			fi
		else
			local remaining=$((issue_sync_interval - elapsed))
			log_verbose "  Phase 8: Skipped (${remaining}s until next run)"
		fi

		# Phase 8b: Status label reconciliation sweep (t1009)
		# Checks all tasks in the DB and ensures their GitHub issue labels match
		# the current supervisor state. Catches drift from missed transitions,
		# manual label changes, or failed API calls.
		# Piggybacks on the same interval/idle check as Phase 8.
		if [[ "$elapsed" -ge "$issue_sync_interval" ]]; then
			# Derive repo_slug from sync_repo (set in Phase 8 above)
			local rec_repo_slug
			rec_repo_slug=$(detect_repo_slug "${sync_repo:-.}" 2>/dev/null || echo "")
			if [[ -n "$rec_repo_slug" ]]; then
				log_info "  Phase 8b: Status label reconciliation sweep"
				ensure_status_labels "$rec_repo_slug"
				local reconcile_count=0
				local reconcile_tasks
				reconcile_tasks=$(db "$SUPERVISOR_DB" "SELECT id, status FROM tasks WHERE status NOT IN ('verified','deployed','cancelled','failed');" 2>/dev/null || echo "")
				while IFS='|' read -r rec_tid rec_status; do
					[[ -z "$rec_tid" ]] && continue
					local rec_issue
					rec_issue=$(find_task_issue_number "$rec_tid" "${sync_repo:-.}")
					[[ -z "$rec_issue" ]] && continue

					local expected_label
					expected_label=$(state_to_status_label "$rec_status")
					[[ -z "$expected_label" ]] && continue

					# Check if the issue already has the correct label
					local current_labels
					current_labels=$(gh issue view "$rec_issue" --repo "$rec_repo_slug" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
					if [[ "$current_labels" != *"$expected_label"* ]]; then
						# Build remove args for all status labels except the expected one
						local -a rec_remove_args=()
						local rec_label
						while IFS=',' read -ra rec_labels; do
							for rec_label in "${rec_labels[@]}"; do
								if [[ "$rec_label" != "$expected_label" ]]; then
									rec_remove_args+=("--remove-label" "$rec_label")
								fi
							done
						done <<<"$ALL_STATUS_LABELS"
						gh issue edit "$rec_issue" --repo "$rec_repo_slug" \
							--add-label "$expected_label" "${rec_remove_args[@]}" 2>/dev/null || true
						log_verbose "  Phase 8b: Fixed #$rec_issue ($rec_tid): -> $expected_label"
						reconcile_count=$((reconcile_count + 1))
					fi
				done <<<"$reconcile_tasks"
				if [[ "$reconcile_count" -gt 0 ]]; then
					log_info "  Phase 8b: Reconciled $reconcile_count issue label(s)"
				else
					log_verbose "  Phase 8b: All labels in sync"
				fi
			else
				log_verbose "  Phase 8b: Skipped (could not detect repo slug)"
			fi
		fi
	fi

	# Phase 8c: Per-repo pinned health issues — live status dashboard (t1013)
	# Each repo gets its own pinned issue with stats filtered to that repo.
	# Graceful degradation — never breaks the pulse if gh fails.
	local health_repos
	health_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks WHERE repo IS NOT NULL AND repo != '';" 2>/dev/null || echo "")
	if [[ -n "$health_repos" ]]; then
		while IFS= read -r health_repo; do
			[[ -z "$health_repo" ]] && continue
			local health_slug
			health_slug=$(detect_repo_slug "$health_repo" 2>/dev/null || echo "")
			[[ -z "$health_slug" ]] && continue
			update_queue_health_issue "${batch_id:-}" "$health_slug" "$health_repo" 2>>"$SUPERVISOR_LOG" || true
		done <<<"$health_repos"
	fi

	# Phase 14: Intelligent routine scheduling (t1093)
	# Pre-computes scheduling decisions for Phases 9-13 based on project state signals.
	# Decisions are exported as ROUTINE_DECISION_* env vars consumed by each phase.
	# Signals: consecutive zero-findings runs, open critical issues, recent failure rate.
	# Routines can be skipped (interval not met), deferred (explicit hold), or approved.
	if declare -f run_phase14_routine_scheduler &>/dev/null; then
		run_phase14_routine_scheduler 2>>"$SUPERVISOR_LOG" || true
	fi

	# Phase 9: Memory audit pulse (t185)
	# Runs dedup, prune, graduate, and opportunity scan.
	# The audit script self-throttles (24h interval), so calling every pulse is safe.
	# Phase 14 may defer this if signals indicate it's not worth running.
	local audit_script="${SCRIPT_DIR}/memory-audit-pulse.sh"
	if [[ -x "$audit_script" ]]; then
		local _phase9_decision="${ROUTINE_DECISION_MEMORY_AUDIT:-run}"
		if [[ "$_phase9_decision" == "run" ]]; then
			log_verbose "  Phase 9: Memory audit pulse"
			"$audit_script" run --quiet 2>>"$SUPERVISOR_LOG" || true
			routine_record_run "memory_audit" 0 2>/dev/null || true
		else
			log_verbose "  Phase 9: Memory audit pulse skipped by Phase 14 (decision: ${_phase9_decision})"
		fi
	fi

	# Phase 10: CodeRabbit daily pulse (t166.1)
	# Triggers a full codebase review via CodeRabbit CLI or GitHub API.
	# The pulse script self-throttles (24h cooldown), so calling every pulse is safe.
	# Phase 14 may defer this if 3+ consecutive zero-findings days or critical issues open.
	local coderabbit_pulse_script="${SCRIPT_DIR}/coderabbit-pulse-helper.sh"
	if [[ -x "$coderabbit_pulse_script" ]]; then
		local _phase10_decision="${ROUTINE_DECISION_CODERABBIT:-run}"
		if [[ "$_phase10_decision" == "run" ]]; then
			log_verbose "  Phase 10: CodeRabbit daily pulse"
			local pulse_repo=""
			pulse_repo=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks LIMIT 1;" 2>/dev/null || echo "")
			if [[ -z "$pulse_repo" ]]; then
				pulse_repo="$(pwd)"
			fi
			bash "$coderabbit_pulse_script" run --repo "$pulse_repo" --quiet 2>>"$SUPERVISOR_LOG" || true
			routine_record_run "coderabbit" 0 2>/dev/null || true
		else
			log_verbose "  Phase 10: CodeRabbit pulse skipped by Phase 14 (decision: ${_phase10_decision})"
		fi
	fi

	# Phase 10b: Auto-create TODO tasks from quality findings (t299, t1032.5)
	# Unified audit orchestrator: collects findings from all configured services
	# (CodeRabbit, Codacy, SonarCloud, CodeFactor) via code-audit-helper.sh, then
	# creates tasks via audit-task-creator-helper.sh. Falls back to CodeRabbit-only
	# coderabbit-task-creator-helper.sh if the unified scripts are not yet available.
	# Self-throttles with 24h cooldown. Phase 14 may defer if consecutive empty runs.
	local audit_collect_script="${SCRIPT_DIR}/code-audit-helper.sh"
	local unified_task_creator="${SCRIPT_DIR}/audit-task-creator-helper.sh"
	local legacy_task_creator="${SCRIPT_DIR}/coderabbit-task-creator-helper.sh"
	local task_creator_script=""
	# Prefer unified task creator (t1032.4), fall back to legacy CodeRabbit-only
	if [[ -x "$unified_task_creator" ]]; then
		task_creator_script="$unified_task_creator"
	elif [[ -x "$legacy_task_creator" ]]; then
		task_creator_script="$legacy_task_creator"
	fi
	local task_creation_cooldown_file="${SUPERVISOR_DIR}/task-creation-last-run"
	local task_creation_cooldown=86400 # 24 hours
	if [[ -n "$task_creator_script" ]]; then
		local should_run_task_creation=true
		# Phase 14 intelligent scheduling check
		local _phase10b_decision="${ROUTINE_DECISION_TASK_CREATION:-run}"
		if [[ "$_phase10b_decision" != "run" ]]; then
			should_run_task_creation=false
			log_verbose "  Phase 10b: Task creation skipped by Phase 14 (decision: ${_phase10b_decision})"
		elif [[ -f "$task_creation_cooldown_file" ]]; then
			local last_run
			last_run=$(cat "$task_creation_cooldown_file" 2>/dev/null || echo "0")
			local now
			now=$(date +%s)
			local elapsed=$((now - last_run))
			if [[ $elapsed -lt $task_creation_cooldown ]]; then
				should_run_task_creation=false
				local remaining=$(((task_creation_cooldown - elapsed) / 3600))
				log_verbose "  Phase 10b: Task creation skipped (${remaining}h until next run)"
			fi
		fi

		if [[ "$should_run_task_creation" == "true" ]]; then
			log_info "  Phase 10b: Auto-creating tasks from quality findings"
			date +%s >"$task_creation_cooldown_file"

			# Determine repo for TODO.md
			local task_repo=""
			task_repo=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks LIMIT 1;" 2>/dev/null || echo "")
			if [[ -z "$task_repo" ]]; then
				task_repo="$(pwd)"
			fi
			local todo_file="$task_repo/TODO.md"

			if [[ -f "$todo_file" ]]; then
				local tasks_added=0

				# Step 1: Collect findings from all audit services (t1032.5)
				# code-audit-helper.sh aggregates CodeRabbit, Codacy, SonarCloud,
				# CodeFactor findings into a unified audit_findings table.
				# Skip if the script is a stub or not yet implemented.
				if [[ -x "$audit_collect_script" ]]; then
					local collect_size
					collect_size=$(wc -c <"$audit_collect_script" 2>/dev/null || echo "0")
					# Only run if the script has substantive content (>100 bytes, not a stub)
					if [[ "$collect_size" -gt 100 ]]; then
						log_info "    Phase 10b: Collecting findings from all audit services"
						bash "$audit_collect_script" collect --repo "$task_repo" 2>>"$SUPERVISOR_LOG" || {
							log_warn "    Phase 10b: Audit collection returned non-zero (continuing with task creation)"
						}
					else
						log_verbose "    Phase 10b: code-audit-helper.sh is a stub, skipping collection"
					fi
				fi

				# Step 2: Create tasks from findings (t1032.5)
				# The task creator (unified or legacy) scans findings, filters
				# false positives, deduplicates, and outputs TODO-compatible lines.
				local creator_label="unified"
				if [[ "$task_creator_script" == "$legacy_task_creator" ]]; then
					creator_label="CodeRabbit-only (legacy)"
				fi
				log_info "    Phase 10b: Running task creator ($creator_label)"

				local cr_output
				cr_output=$(bash "$task_creator_script" create 2>>"$SUPERVISOR_LOG" || echo "")
				if [[ -n "$cr_output" ]]; then
					# Extract task lines between the markers
					local cr_tasks
					cr_tasks=$(echo "$cr_output" | sed -n '/=== Task Lines/,/===$/p' | grep -E '^\s*- \[ \]' || true)
					if [[ -n "$cr_tasks" ]]; then
						local claim_script="${SCRIPT_DIR}/claim-task-id.sh"

						# Append each task line to TODO.md
						while IFS= read -r task_line; do
							local new_line="$task_line"

							# If the task line already has a tNNN ID (from claim-task-id.sh
							# inside the task creator), use it as-is.
							# Otherwise, allocate a new ID via claim-task-id.sh.
							if ! echo "$new_line" | grep -qE '^\s*- \[ \] t[0-9]+'; then
								local claim_output claimed_id
								if [[ -x "$claim_script" ]]; then
									local task_desc
									task_desc=$(echo "$new_line" | sed -E 's/^\s*- \[ \] //')

									# Extract hashtags from task description for labels
									local labels=""
									local tag_list=()
									local task_desc_copy="$task_desc"
									while [[ "$task_desc_copy" =~ \#([a-zA-Z0-9_-]+) ]]; do
										local tag="${BASH_REMATCH[1]}"
										tag_list+=("$tag")
										task_desc_copy="${task_desc_copy#*#"${tag}"}"
									done
									if [[ ${#tag_list[@]} -gt 0 ]]; then
										labels=$(
											IFS=,
											echo "${tag_list[*]}"
										)
									fi

									claim_output=$("$claim_script" --title "${task_desc:0:80}" --labels "$labels" --repo-path "$task_repo" 2>>"$SUPERVISOR_LOG") || claim_output=""
									claimed_id=$(echo "$claim_output" | grep "^task_id=" | cut -d= -f2)
								fi
								if [[ -n "${claimed_id:-}" ]]; then
									new_line=$(echo "$new_line" | sed -E "s/^(\s*- \[ \] )/\1${claimed_id} /")
									# Add ref if available
									local claimed_ref
									claimed_ref=$(echo "$claim_output" | grep "^ref=" | cut -d= -f2)
									if [[ -n "$claimed_ref" && "$claimed_ref" != "offline" ]]; then
										new_line="$new_line ref:${claimed_ref}"
									fi
								else
									log_warn "    Failed to allocate task ID via claim-task-id.sh, skipping line"
									continue
								fi
							fi

							# Ensure #auto-dispatch tag and source tag
							if ! echo "$new_line" | grep -q '#auto-dispatch'; then
								new_line="$new_line #auto-dispatch"
							fi
							if ! echo "$new_line" | grep -q '#auto-review'; then
								new_line="$new_line #auto-review"
							fi
							if ! echo "$new_line" | grep -q 'logged:'; then
								new_line="$new_line logged:$(date +%Y-%m-%d)"
							fi
							# Append to TODO.md
							echo "$new_line" >>"$todo_file"
							tasks_added=$((tasks_added + 1))
							# Extract task ID for logging
							local logged_id
							logged_id=$(echo "$new_line" | grep -oE 't[0-9]+' | head -1 || echo "unknown")
							log_info "    Created ${logged_id} from audit finding"
						done <<<"$cr_tasks"
					fi
				fi

				# Step 3: Commit and push if tasks were added
				if [[ $tasks_added -gt 0 ]]; then
					log_info "  Phase 10b: Added $tasks_added task(s) to TODO.md"
					if git -C "$task_repo" add TODO.md 2>>"$SUPERVISOR_LOG" &&
						git -C "$task_repo" commit -m "chore: auto-create $tasks_added task(s) from audit findings (Phase 10b)" 2>>"$SUPERVISOR_LOG" &&
						git -C "$task_repo" push 2>>"$SUPERVISOR_LOG"; then
						log_success "  Phase 10b: Committed and pushed $tasks_added new task(s)"
					else
						log_warn "  Phase 10b: Failed to commit/push TODO.md changes"
					fi
				else
					log_verbose "  Phase 10b: No new tasks to create"
				fi
				routine_record_run "task_creation" "$tasks_added" 2>/dev/null || true
			fi
		fi
	fi

	# Phase 10c: Audit regression detection + auto-remediation (t1032.6, t1045)
	# Queries SonarCloud API for current findings, compares against last snapshot.
	# On regression: logs warning, auto-creates tasks for new findings.
	# Runs at most once per hour to avoid API rate limits.
	local audit_helper="${SCRIPT_DIR}/code-audit-helper.sh"
	local task_creator="${SCRIPT_DIR}/audit-task-creator-helper.sh"
	if [[ -x "$audit_helper" ]]; then
		local regression_cache="${HOME}/.aidevops/.agent-workspace/tmp/regression-last-check"
		local now_epoch
		now_epoch=$(date +%s)
		local last_check=0
		if [[ -f "$regression_cache" ]]; then
			last_check=$(cat "$regression_cache" 2>/dev/null) || last_check=0
		fi
		local elapsed=$((now_epoch - last_check))
		if [[ "$elapsed" -ge 3600 ]]; then
			log_verbose "  Phase 10c: Checking for audit regressions"
			mkdir -p "$(dirname "$regression_cache")" 2>/dev/null || true
			echo "$now_epoch" >"$regression_cache"
			if ! bash "$audit_helper" check-regression 2>>"$SUPERVISOR_LOG"; then
				log_warn "  Phase 10c: Audit regressions detected — review SonarCloud dashboard"
				# Auto-create tasks for new findings (t1045)
				if [[ -x "$task_creator" ]]; then
					log_info "  Phase 10c: Auto-creating tasks for new findings"
					if bash "$task_creator" create --severity high --dispatch 2>>"$SUPERVISOR_LOG"; then
						log_success "  Phase 10c: Tasks created and dispatched"
					else
						log_warn "  Phase 10c: Task creation failed (see log)"
					fi
				fi
			fi
		else
			log_verbose "  Phase 10c: Skipping (last check $((elapsed / 60))m ago, interval=60m)"
		fi
	fi

	# Phase 11: Supervisor session memory monitoring + respawn (t264, t264.1)
	# OpenCode/Bun processes accumulate WebKit malloc dirty pages that are never
	# returned to the OS. Over long sessions, a single process can grow to 25GB+.
	# Cron-based pulses are already fresh processes (no accumulation).
	#
	# Respawn strategy (t264.1): after a batch wave completes (no running/queued
	# tasks) AND memory exceeds threshold, save checkpoint and exit cleanly.
	# The next cron pulse (2 min) starts fresh with zero accumulated memory.
	# Workers are NOT killed — they're short-lived and managed by Phase 4.
	if attempt_respawn_after_batch "${batch_id:-}" 2>/dev/null; then
		log_warn "  Phase 11: Respawn triggered — releasing lock and exiting for fresh restart"
		release_pulse_lock
		trap - EXIT INT TERM
		return 0
	fi
	# If no respawn needed, still log a warning if memory is high (passive monitoring)
	if ! check_supervisor_memory 2>/dev/null; then
		log_warn "  Phase 11: Memory exceeds threshold but tasks still active — monitoring"
	fi

	# Phase 12: Regenerate MODELS.md (global) + MODELS-PERFORMANCE.md (per-repo) (t1012, t1133)
	# Throttled to once per hour — only regenerates when pattern data may have changed.
	# Step 1: Generate global MODELS.md once (catalog, tiers, pricing)
	# Step 2: Propagate global MODELS.md to all registered repos
	# Step 3: Generate per-repo MODELS-PERFORMANCE.md from local pattern data
	# Phase 14 may defer this when critical issues are open (cosmetic update).
	local models_md_interval=3600 # seconds (1 hour)
	local models_md_stamp="$SUPERVISOR_DIR/models-md-last-regen"
	local models_md_now
	models_md_now=$(date +%s)
	local models_md_last=0
	if [[ -f "$models_md_stamp" ]]; then
		models_md_last=$(cat "$models_md_stamp" 2>/dev/null || echo 0)
	fi
	local models_md_elapsed=$((models_md_now - models_md_last))
	local _phase12_decision="${ROUTINE_DECISION_MODELS_MD:-run}"
	if [[ "$_phase12_decision" != "run" ]]; then
		log_verbose "  Phase 12: MODELS.md regen skipped by Phase 14 (decision: ${_phase12_decision})"
	elif [[ "$models_md_elapsed" -ge "$models_md_interval" ]]; then
		local generate_script="${SCRIPT_DIR}/generate-models-md.sh"
		if [[ -x "$generate_script" ]]; then
			# Step 1: Generate global MODELS.md in a temp file for propagation
			local global_models_tmp="${SUPERVISOR_DIR}/MODELS.md.tmp"
			local global_generated=0
			if "$generate_script" --mode global --output "$global_models_tmp" --quiet 2>/dev/null; then
				global_generated=1
				log_verbose "  Phase 12: Generated global MODELS.md"
			else
				log_warn "  Phase 12: Global MODELS.md generation failed"
			fi

			# Step 2+3: Iterate registered repos — propagate global + generate performance
			local models_repos
			models_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks;" 2>/dev/null || true)
			if [[ -n "$models_repos" ]]; then
				# Deduplicate repo roots (multiple worktree paths may resolve to same root)
				local seen_roots=""
				while IFS= read -r models_repo_path; do
					[[ -n "$models_repo_path" && -d "$models_repo_path" ]] || continue
					local models_repo_root
					models_repo_root=$(git -C "$models_repo_path" rev-parse --show-toplevel 2>/dev/null) || continue

					# Skip duplicate repo roots
					if [[ " $seen_roots " == *" $models_repo_root "* ]]; then
						continue
					fi
					seen_roots="$seen_roots $models_repo_root"

					local models_changed=0

					# Step 2: Propagate global MODELS.md
					if [[ "$global_generated" -eq 1 && -f "$global_models_tmp" ]]; then
						if ! cp "$global_models_tmp" "${models_repo_root}/MODELS.md" 2>/dev/null; then
							log_warn "  Phase 12: Failed to copy global MODELS.md to $models_repo_root"
						elif ! git -C "$models_repo_root" diff --quiet -- MODELS.md 2>/dev/null; then
							models_changed=1
						fi
					fi

					# Step 3: Generate per-repo MODELS-PERFORMANCE.md
					if "$generate_script" --mode performance --repo-path "$models_repo_root" \
						--output "${models_repo_root}/MODELS-PERFORMANCE.md" --quiet 2>/dev/null; then
						if ! git -C "$models_repo_root" diff --quiet -- MODELS-PERFORMANCE.md 2>/dev/null; then
							models_changed=1
						fi
						# Also stage new untracked MODELS-PERFORMANCE.md
						if git -C "$models_repo_root" ls-files --others --exclude-standard -- MODELS-PERFORMANCE.md 2>/dev/null | grep -q .; then
							models_changed=1
						fi
					else
						log_warn "  Phase 12: MODELS-PERFORMANCE.md generation failed for $models_repo_root"
					fi

					# Commit and push if anything changed
					if [[ "$models_changed" -eq 1 ]]; then
						git -C "$models_repo_root" add MODELS.md MODELS-PERFORMANCE.md 2>/dev/null
						if git -C "$models_repo_root" commit -m "docs: update model files from aidevops (t1133)" --no-verify 2>/dev/null &&
							git -C "$models_repo_root" push 2>/dev/null; then
							log_info "  Phase 12: MODELS.md + MODELS-PERFORMANCE.md updated ($models_repo_root)"
						else
							log_warn "  Phase 12: Model files regenerated but commit/push failed ($models_repo_root)"
						fi
					else
						log_verbose "  Phase 12: Model files unchanged in $models_repo_root"
					fi
				done <<<"$models_repos"
			fi

			# Cleanup temp file
			rm -f "$global_models_tmp" 2>/dev/null || true
		fi
		echo "$models_md_now" >"$models_md_stamp" 2>/dev/null || true
		routine_record_run "models_md" -1 2>/dev/null || true
	else
		local models_md_remaining=$((models_md_interval - models_md_elapsed))
		log_verbose "  Phase 12: MODELS.md regen skipped (${models_md_remaining}s until next run)"
	fi

	# Phase 12b: Tier drift detection (t1191)
	# Checks if tasks are consistently running at higher tiers than requested.
	# Throttled to once per hour (same cadence as MODELS.md regen).
	# Logs a warning when escalation rate exceeds 25%, error when >50%.
	local tier_drift_interval=3600
	local tier_drift_stamp="$SUPERVISOR_DIR/tier-drift-last-check"
	local tier_drift_now
	tier_drift_now=$(date +%s)
	local tier_drift_last=0
	if [[ -f "$tier_drift_stamp" ]]; then
		tier_drift_last=$(cat "$tier_drift_stamp" 2>/dev/null || echo 0)
	fi
	local tier_drift_elapsed=$((tier_drift_now - tier_drift_last))
	if [[ "$tier_drift_elapsed" -ge "$tier_drift_interval" ]]; then
		local pattern_drift_helper="${SCRIPT_DIR}/../pattern-tracker-helper.sh"
		local budget_drift_helper="${SCRIPT_DIR}/../budget-tracker-helper.sh"

		# Pattern-tracker tier drift (memory-based)
		if [[ -x "$pattern_drift_helper" ]]; then
			local drift_summary
			drift_summary=$("$pattern_drift_helper" tier-drift --summary --days 7 2>/dev/null) || drift_summary=""
			if [[ -n "$drift_summary" ]]; then
				# Extract escalation percentage
				local drift_pct
				drift_pct=$(echo "$drift_summary" | grep -oE '[0-9]+%' | head -1 | tr -d '%') || drift_pct="0"
				if [[ "$drift_pct" -gt 50 ]]; then
					log_warn "  Phase 12b: HIGH tier drift — $drift_summary"
					log_warn "  Phase 12b: >50% of tasks escalating tier. Check SUPERVISOR_MODEL and model routing."
				elif [[ "$drift_pct" -gt 25 ]]; then
					log_info "  Phase 12b: Moderate tier drift — $drift_summary"
				else
					log_verbose "  Phase 12b: Tier drift normal — $drift_summary"
				fi
			fi
		fi

		# Budget-tracker tier drift (cost-based)
		if [[ -x "$budget_drift_helper" ]]; then
			local budget_drift_summary
			budget_drift_summary=$("$budget_drift_helper" tier-drift --summary --days 7 2>/dev/null) || budget_drift_summary=""
			if [[ -n "$budget_drift_summary" ]]; then
				log_verbose "  Phase 12b: $budget_drift_summary"
			fi
		fi

		echo "$tier_drift_now" >"$tier_drift_stamp" 2>/dev/null || true
	else
		local tier_drift_remaining=$((tier_drift_interval - tier_drift_elapsed))
		log_verbose "  Phase 12b: Tier drift check skipped (${tier_drift_remaining}s until next run)"
	fi

	# Phase 13: Skill update PR pipeline (t1082.2, t1082.3)
	# Optional phase — disabled by default. Enable via SUPERVISOR_SKILL_UPDATE_PR=true.
	# Runs skill-update-helper.sh pr on a configurable schedule (default: daily).
	# Only runs for repos where the authenticated user has write/admin permission,
	# ensuring PRs are only created where the user is a maintainer.
	# Batch mode: SUPERVISOR_SKILL_UPDATE_BATCH_MODE (one-per-skill|single-pr, default: one-per-skill)
	# Phase 14 may defer this when failure rate is high or critical issues are open.
	local skill_update_pr_enabled="${SUPERVISOR_SKILL_UPDATE_PR:-false}"
	if [[ "$skill_update_pr_enabled" == "true" ]]; then
		local skill_update_interval="${SUPERVISOR_SKILL_UPDATE_INTERVAL:-86400}" # seconds (24h default)
		local skill_update_stamp="$SUPERVISOR_DIR/skill-update-pr-last-run"
		local skill_update_now
		skill_update_now=$(date +%s)
		local skill_update_last=0
		if [[ -f "$skill_update_stamp" ]]; then
			skill_update_last=$(cat "$skill_update_stamp" 2>/dev/null || echo 0)
		fi
		local skill_update_elapsed=$((skill_update_now - ${skill_update_last:-0}))
		local _phase13_decision="${ROUTINE_DECISION_SKILL_UPDATE:-run}"
		if [[ "$_phase13_decision" != "run" ]]; then
			log_verbose "  Phase 13: Skill update PR skipped by Phase 14 (decision: ${_phase13_decision})"
		elif [[ "$skill_update_elapsed" -ge "$skill_update_interval" ]]; then
			local skill_update_script="${SCRIPT_DIR}/skill-update-helper.sh"
			if [[ -x "$skill_update_script" ]]; then
				# Determine the repo root to check maintainer permission
				local skill_update_repo=""
				skill_update_repo=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks LIMIT 1;" 2>/dev/null || echo "")
				if [[ -z "$skill_update_repo" ]]; then
					skill_update_repo="$(pwd)"
				fi
				local skill_update_repo_root=""
				skill_update_repo_root=$(git -C "$skill_update_repo" rev-parse --show-toplevel 2>/dev/null) || true
				# Check viewer permission — only run if user is a maintainer (WRITE or ADMIN)
				local viewer_permission=""
				if [[ -n "$skill_update_repo_root" ]] && command -v gh &>/dev/null; then
					viewer_permission=$(gh repo view --json viewerPermission --jq '.viewerPermission' \
						-R "$(git -C "$skill_update_repo_root" remote get-url origin 2>/dev/null |
							sed 's|.*github\.com[:/]\([^/]*/[^/]*\)\.git|\1|; s|.*github\.com[:/]\([^/]*/[^/]*\)$|\1|')" \
						2>/dev/null || echo "")
				fi
				if [[ "$viewer_permission" == "ADMIN" || "$viewer_permission" == "WRITE" ]]; then
					# Resolve batch mode: CLI env var > supervisor env var > default
					local skill_batch_mode="${SUPERVISOR_SKILL_UPDATE_BATCH_MODE:-one-per-skill}"
					log_info "  Phase 13: Running skill update PR pipeline (permission: $viewer_permission, batch-mode: $skill_batch_mode)"
					if SKILL_UPDATE_BATCH_MODE="$skill_batch_mode" \
						"$skill_update_script" pr --quiet 2>>"$SUPERVISOR_LOG"; then
						log_success "  Phase 13: Skill update PR pipeline complete"
					else
						log_warn "  Phase 13: Skill update PR pipeline finished with errors (see $SUPERVISOR_LOG)"
					fi
				elif [[ -z "$viewer_permission" ]]; then
					log_verbose "  Phase 13: Skipped (could not determine repo permission — gh CLI unavailable or not a GitHub repo)"
				else
					log_verbose "  Phase 13: Skipped (viewer permission '$viewer_permission' — write/admin required)"
				fi
			else
				log_verbose "  Phase 13: Skipped (skill-update-helper.sh not found)"
			fi
			echo "$skill_update_now" >"$skill_update_stamp" 2>/dev/null || true
			routine_record_run "skill_update" -1 2>/dev/null || true
		else
			local skill_update_remaining=$((skill_update_interval - skill_update_elapsed))
			log_verbose "  Phase 13: Skill update PR skipped (${skill_update_remaining}s until next run)"
		fi
	fi

	# Phase 14: AI Supervisor reasoning + action execution (t1085.5)
	# Attempts AI reasoning on EVERY pulse. Natural guards prevent waste:
	#   - SUPERVISOR_AI_ENABLED: master switch (default: true)
	#   - should_run_ai_reasoning(): checks has_actionable_work() + time-based cooldown
	#   - run_ai_reasoning() lock file: prevents concurrent AI sessions
	# Controlled by SUPERVISOR_AI_ENABLED (default: true) and
	# SUPERVISOR_AI_COOLDOWN (default: 300 seconds = 5 min).
	# Dedicated log: $SUPERVISOR_DIR/logs/ai-supervisor.log
	local ai_enabled="${SUPERVISOR_AI_ENABLED:-true}"
	if [[ "$ai_enabled" == "true" ]]; then
		local ai_last_run_file="${SUPERVISOR_DIR}/ai-supervisor-last-run"
		local ai_log_dir="${SUPERVISOR_DIR}/logs"
		local ai_log_file="${ai_log_dir}/ai-supervisor.log"

		# Determine repo path
		local ai_repo_path=""
		ai_repo_path=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks LIMIT 1;" 2>/dev/null || echo "")
		if [[ -z "$ai_repo_path" ]]; then
			ai_repo_path="$(pwd)"
		fi

		# Natural guards: actionable work check + time-based cooldown
		if should_run_ai_reasoning "false" "$ai_repo_path"; then
			log_info "  Phase 14: AI supervisor reasoning + action execution"

			# Ensure log directory exists
			mkdir -p "$ai_log_dir" 2>/dev/null || true

			# Record start timestamp
			local ai_start_ts
			ai_start_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
			{
				echo ""
				echo "=== AI Supervisor Run: $ai_start_ts ==="
			} >>"$ai_log_file" 2>/dev/null || true

			# Run the full AI pipeline (reasoning -> action execution)
			local ai_result=""
			local ai_rc=0
			ai_result=$(run_ai_actions_pipeline "$ai_repo_path" "full" 2>>"$ai_log_file") || ai_rc=$?

			# Record completion timestamp
			local ai_end_ts
			ai_end_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
			echo "$ai_end_ts" >"$ai_last_run_file" 2>/dev/null || true

			if [[ $ai_rc -eq 0 ]]; then
				# Extract summary from result JSON
				local ai_executed ai_failed ai_skipped
				ai_executed=$(printf '%s' "$ai_result" | jq -r '.executed // 0' 2>/dev/null || echo 0)
				ai_failed=$(printf '%s' "$ai_result" | jq -r '.failed // 0' 2>/dev/null || echo 0)
				ai_skipped=$(printf '%s' "$ai_result" | jq -r '.skipped // 0' 2>/dev/null || echo 0)
				log_success "  Phase 14: AI pipeline complete (executed=$ai_executed failed=$ai_failed skipped=$ai_skipped)"
				{
					echo "Result: executed=$ai_executed failed=$ai_failed skipped=$ai_skipped"
					echo "=== End: $ai_end_ts ==="
				} >>"$ai_log_file" 2>/dev/null || true
			else
				log_warn "  Phase 14: AI pipeline returned rc=$ai_rc (see $ai_log_file)"
				{
					echo "Result: rc=$ai_rc (pipeline error)"
					echo "=== End: $ai_end_ts ==="
				} >>"$ai_log_file" 2>/dev/null || true
			fi
		else
			log_verbose "  Phase 14: AI pipeline skipped (no actionable work or cooldown active)"
		fi
	else
		log_verbose "  Phase 14: AI pipeline disabled (SUPERVISOR_AI_ENABLED=false)"
	fi

	# t1052: Clear deferred batch completion flag to avoid leaking state
	# if the supervisor process is reused for non-pulse commands
	_PULSE_DEFER_BATCH_COMPLETION=""
	_PULSE_DEFERRED_BATCH_IDS=""

	# Release pulse dispatch lock (t159)
	release_pulse_lock
	# Reset trap to avoid interfering with other commands in the same process
	trap - EXIT INT TERM

	return 0
}

#######################################
# Phase 3a: Adopt untracked PRs into the supervisor pipeline
# Scans open PRs for each tracked repo and creates DB entries for any
# that have a task ID in the title but aren't tracked in the supervisor DB.
# This allows PRs created in interactive sessions to be managed by the
# supervisor (review, merge, verify, clean up) without manual registration.
#
# Adoption criteria:
#   1. PR title matches pattern: tNNN: description (or tNNN.N: description)
#   2. No task in the DB already has this PR URL
#   3. The task ID exists as an open task in TODO.md
#   4. The task is not already in the DB (avoids duplicating worker tasks)
#
# Adopted tasks enter the DB with status=complete and the PR URL, so
# Phase 3 picks them up through the normal lifecycle.
#######################################
adopt_untracked_prs() {
	ensure_db

	# Collect all unique repos from the DB
	local repos
	repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks WHERE repo IS NOT NULL AND repo != '';" 2>/dev/null || echo "")

	if [[ -z "$repos" ]]; then
		return 0
	fi

	local adopted_count=0

	while IFS= read -r repo_path; do
		[[ -z "$repo_path" || ! -d "$repo_path" ]] && continue

		# Get repo slug for gh CLI
		local repo_slug
		repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")
		if [[ -z "$repo_slug" ]]; then
			continue
		fi

		# List open PRs (limit to 20 to avoid API rate limits)
		local open_prs
		open_prs=$(gh pr list --repo "$repo_slug" --state open --limit 20 \
			--json number,title,url 2>/dev/null || echo "[]")

		local pr_count
		pr_count=$(printf '%s' "$open_prs" | jq 'length' 2>/dev/null || echo 0)

		local i=0
		while [[ "$i" -lt "$pr_count" ]]; do
			local pr_number pr_title pr_url
			pr_number=$(printf '%s' "$open_prs" | jq -r ".[$i].number" 2>/dev/null || echo "")
			pr_title=$(printf '%s' "$open_prs" | jq -r ".[$i].title" 2>/dev/null || echo "")
			pr_url=$(printf '%s' "$open_prs" | jq -r ".[$i].url" 2>/dev/null || echo "")
			i=$((i + 1))

			# Extract task ID from PR title (pattern: tNNN: or tNNN.N:)
			local task_id=""
			if [[ "$pr_title" =~ ^(t[0-9]+(\.[0-9]+)?):\ .* ]]; then
				task_id="${BASH_REMATCH[1]}"
			fi

			if [[ -z "$task_id" ]]; then
				continue
			fi

			# Check if this PR is already tracked in the DB
			local existing_pr
			existing_pr=$(db "$SUPERVISOR_DB" "
				SELECT id FROM tasks
				WHERE pr_url = '$(sql_escape "$pr_url")'
				LIMIT 1;
			" 2>/dev/null || echo "")

			if [[ -n "$existing_pr" ]]; then
				continue
			fi

			# Check if this task ID is already in the DB (worker-dispatched)
			local existing_task
			existing_task=$(db "$SUPERVISOR_DB" "
				SELECT id, status FROM tasks
				WHERE id = '$(sql_escape "$task_id")'
				LIMIT 1;
			" 2>/dev/null || echo "")

			if [[ -n "$existing_task" ]]; then
				# Task exists but doesn't have this PR URL — link it
				local existing_status
				existing_status=$(echo "$existing_task" | cut -d'|' -f2)
				# Only link if the task is in a state where a PR makes sense
				if [[ "$existing_status" =~ ^(queued|running|evaluating|retrying|complete)$ ]]; then
					db "$SUPERVISOR_DB" "
						UPDATE tasks
						SET pr_url = '$(sql_escape "$pr_url")',
						    status = 'complete',
						    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
						WHERE id = '$(sql_escape "$task_id")';
					" 2>/dev/null || true
					log_info "Phase 3a: Linked PR #$pr_number to existing task $task_id (was: $existing_status)"
					adopted_count=$((adopted_count + 1))
				fi
				continue
			fi

			# Task not in DB — check if it exists in TODO.md
			local todo_file="$repo_path/TODO.md"
			if [[ ! -f "$todo_file" ]]; then
				continue
			fi

			local todo_line
			todo_line=$(grep -E "^[[:space:]]*- \[( |x|-)\] $task_id " "$todo_file" 2>/dev/null | head -1 || true)

			if [[ -z "$todo_line" ]]; then
				continue
			fi

			# Extract description from TODO.md
			local description
			description=$(echo "$todo_line" | sed -E 's/^[[:space:]]*- \[( |x|-)\] [^ ]* //' || true)

			# Adopt: create a DB entry with status=complete and the PR URL
			# Phase 3 will then process it through review → merge → verify
			local batch_id_for_adopt=""
			# Find the active batch for this repo to associate the task
			batch_id_for_adopt=$(db "$SUPERVISOR_DB" "
				SELECT b.id FROM batches b
				WHERE b.status IN ('active', 'running')
				ORDER BY b.created_at DESC
				LIMIT 1;
			" 2>/dev/null || echo "")

			db "$SUPERVISOR_DB" "
				INSERT INTO tasks (id, status, description, repo, pr_url, model, max_retries, created_at, updated_at)
				VALUES (
					'$(sql_escape "$task_id")',
					'complete',
					'$(sql_escape "$description")',
					'$(sql_escape "$repo_path")',
					'$(sql_escape "$pr_url")',
					'interactive',
					0,
					strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
					strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
				);
			" 2>/dev/null || {
				log_warn "Phase 3a: Failed to insert task $task_id (may already exist)"
				continue
			}

			# Associate with active batch if one exists
			if [[ -n "$batch_id_for_adopt" ]]; then
				db "$SUPERVISOR_DB" "
					INSERT OR IGNORE INTO batch_tasks (batch_id, task_id)
					VALUES ('$(sql_escape "$batch_id_for_adopt")', '$(sql_escape "$task_id")');
				" 2>/dev/null || true
			fi

			log_success "Phase 3a: Adopted PR #$pr_number ($pr_url) as task $task_id"
			adopted_count=$((adopted_count + 1))
		done
	done <<<"$repos"

	if [[ "$adopted_count" -gt 0 ]]; then
		log_info "Phase 3a: Adopted $adopted_count untracked PR(s)"
	fi

	return 0
}

#######################################
# Process post-PR lifecycle for all eligible tasks
# Called as Phase 3 of the pulse cycle
# Finds tasks in complete/pr_review/merging/merged states with PR URLs
#
# t225: Serial merge strategy for sibling subtasks
# When multiple subtasks share a parent (e.g., t215.1, t215.2, t215.3),
# only one sibling is allowed to merge per pulse cycle. After it merges,
# rebase_sibling_prs_after_merge() (called from cmd_pr_lifecycle) rebases
# the remaining siblings' branches onto the updated main. This prevents
# cascading merge conflicts that occur when parallel PRs all target main.
#######################################
process_post_pr_lifecycle() {
	local batch_id="${1:-}"

	ensure_db

	# Find tasks eligible for post-PR processing
	local where_clause="t.status IN ('complete', 'pr_review', 'review_triage', 'merging', 'merged', 'deploying')"
	if [[ -n "$batch_id" ]]; then
		where_clause="$where_clause AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$(sql_escape "$batch_id")')"
	fi

	local eligible_tasks
	eligible_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT t.id, t.status, t.pr_url FROM tasks t
        WHERE $where_clause
        ORDER BY t.updated_at ASC;
    ")

	if [[ -z "$eligible_tasks" ]]; then
		return 0
	fi

	local processed=0
	local merged_count=0
	local deployed_count=0
	local deferred_count=0

	# t1183 Bug 3: Cap merges per pulse to prevent runaway merge loops.
	# Each merge dirties remaining PRs (main moves forward), so unlimited
	# merges can cause cascading rebase failures. Default: 5 per pulse.
	local max_merges_per_pulse="${SUPERVISOR_MAX_MERGES_PER_PULSE:-5}"

	# t225: Track which parent IDs have already had a sibling merge in this pulse.
	# Only one sibling per parent group is allowed to merge per cycle.
	# Use a simple string list (bash 3.2 compatible — no associative arrays).
	local merged_parents=""

	while IFS='|' read -r tid tstatus tpr; do
		# t1183 Bug 3: Stop processing if we've hit the merge cap.
		# Remaining tasks will be picked up in the next pulse cycle.
		if [[ "$merged_count" -ge "$max_merges_per_pulse" ]]; then
			log_info "  Phase 3: reached max merges per pulse ($max_merges_per_pulse), deferring rest to next cycle"
			break
		fi

		# Skip tasks without PRs that are already complete
		# t1030: Defense-in-depth — cmd_transition() also guards complete->deployed
		# when a real PR URL exists, but this fast path should only fire for genuinely
		# PR-less tasks. The "|| $tpr == verified_complete" case is a verify-mode
		# worker that confirmed prior work without creating a new PR.
		if [[ "$tstatus" == "complete" && (-z "$tpr" || "$tpr" == "no_pr" || "$tpr" == "task_only" || "$tpr" == "verified_complete") ]]; then
			# t240: Clean up worktree even for no-PR tasks before marking deployed
			cleanup_after_merge "$tid" 2>>"$SUPERVISOR_LOG" || log_warn "Worktree cleanup issue for $tid (no-PR batch path, non-blocking)"
			# No PR - transition directly to deployed
			cmd_transition "$tid" "deployed" 2>>"$SUPERVISOR_LOG" || true
			deployed_count=$((deployed_count + 1))
			log_info "  $tid: no PR, marked deployed (worktree cleaned)"
			continue
		fi

		# t225: Serial merge guard for sibling subtasks
		# If this task is a subtask and a sibling has already merged in this
		# pulse, defer it to the next cycle (after rebase completes).
		local parent_id
		parent_id=$(extract_parent_id "$tid")
		if [[ -n "$parent_id" ]] && [[ "$merged_parents" == *"|${parent_id}|"* ]]; then
			# A sibling already merged — defer this task to next pulse
			# so the rebase can land first and CI can re-run
			log_info "  $tid: deferred (sibling under $parent_id already merged this pulse — serial merge strategy)"
			deferred_count=$((deferred_count + 1))
			continue
		fi

		log_info "  $tid: processing post-PR lifecycle (status: $tstatus)"
		if cmd_pr_lifecycle "$tid" >>"$SUPERVISOR_DIR/post-pr.log" 2>&1; then
			local new_status
			new_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
			case "$new_status" in
			merged | deploying | deployed)
				merged_count=$((merged_count + 1))
				# t225: Record that this parent group had a merge
				if [[ -n "$parent_id" ]]; then
					merged_parents="${merged_parents}|${parent_id}|"
				fi
				# t1183 Bug 3: After a successful merge, pull main in the task's
				# repo so subsequent PRs in this pulse can rebase cleanly against
				# the updated main. Without this, each merge dirties remaining PRs
				# and they fail rebase until the next pulse.
				local merge_repo
				merge_repo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
				if [[ -n "$merge_repo" && -d "$merge_repo" ]]; then
					git -C "$merge_repo" pull --rebase origin main 2>>"$SUPERVISOR_LOG" ||
						log_warn "  $tid: failed to pull main in $merge_repo after merge (non-blocking)"
				fi
				;;
			esac
			if [[ "$new_status" == "deployed" ]]; then
				deployed_count=$((deployed_count + 1))
			fi
		fi
		processed=$((processed + 1))
	done <<<"$eligible_tasks"

	if [[ "$processed" -gt 0 || "$deferred_count" -gt 0 ]]; then
		log_info "Post-PR lifecycle: processed=$processed merged=$merged_count deployed=$deployed_count deferred=$deferred_count"
	fi

	return 0
}

#######################################
# Extract parent task ID from a subtask ID (t225)
# e.g., t215.3 -> t215, t100.1.2 -> t100.1, t50 -> "" (no parent)
#######################################
extract_parent_id() {
	local task_id="$1"
	if [[ "$task_id" =~ ^(t[0-9]+(\.[0-9]+)*)\.[0-9]+$ ]]; then
		echo "${BASH_REMATCH[1]}"
	fi
	# No output for non-subtasks (intentional)
	return 0
}

#######################################
# Triage command — bulk diagnose and resolve stuck tasks
# Provides a summary of all blocked/verify_failed/failed tasks,
# categorizes them by root cause, and optionally resolves them.
#
# Usage:
#   supervisor-helper.sh triage [--dry-run] [--auto-resolve]
#
# Categories:
#   merged-but-stuck: PR merged on GitHub but DB still blocked/verify_failed
#   closed-no-merge:  PR closed without merge — needs re-dispatch
#   obsolete-pr:      PR URL is a sentinel (task_obsolete) — cancel
#   changes-requested: Review requested changes but PR since merged — advance
#   rebase-exhausted: Auto-rebase retries exhausted — needs escalation
#   no-pr:            Blocked with no PR URL — needs investigation
#######################################
cmd_triage() {
	local dry_run=false
	local auto_resolve=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--auto-resolve)
			auto_resolve=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	if ! command -v gh &>/dev/null; then
		log_error "gh CLI required for triage — install with: brew install gh"
		return 1
	fi

	echo ""
	log_info "=== Queue Triage Report ==="
	echo ""

	# Gather all stuck tasks
	local stuck_tasks
	stuck_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, status, pr_url, error, repo, rebase_attempts FROM tasks
		WHERE status IN ('blocked', 'verify_failed', 'failed')
		ORDER BY status, id;
	" 2>/dev/null || echo "")

	if [[ -z "$stuck_tasks" ]]; then
		log_success "No stuck tasks found — queue is healthy"
		return 0
	fi

	# Categorize
	local cat_merged_stuck=""
	local cat_closed_no_merge=""
	local cat_obsolete=""
	local cat_rebase_exhausted=""
	local cat_no_pr=""
	local cat_open_pr=""
	local total_stuck=0

	while IFS='|' read -r tid tstatus tpr terror _trepo trebase; do
		[[ -z "$tid" ]] && continue
		total_stuck=$((total_stuck + 1))

		# No PR or sentinel
		if [[ -z "$tpr" || "$tpr" == "no_pr" || "$tpr" == "task_only" ]]; then
			cat_no_pr="${cat_no_pr}${tid}|${tstatus}|${terror}\n"
			continue
		fi
		if [[ "$tpr" == "task_obsolete" ]]; then
			cat_obsolete="${cat_obsolete}${tid}|${tstatus}|${tpr}\n"
			continue
		fi

		# Extract PR number and repo slug from URL
		local pr_num="" triage_repo_slug=""
		if [[ "$tpr" =~ github\.com/([^/]+/[^/]+)/pull/([0-9]+)$ ]]; then
			triage_repo_slug="${BASH_REMATCH[1]}"
			pr_num="${BASH_REMATCH[2]}"
		fi
		if [[ -z "$pr_num" ]]; then
			cat_obsolete="${cat_obsolete}${tid}|${tstatus}|unparseable:${tpr}\n"
			continue
		fi

		# Query GitHub (use --repo for cron compatibility)
		local pr_json
		pr_json=$(gh pr view "$pr_num" --repo "$triage_repo_slug" --json state,mergedAt 2>/dev/null || echo "")
		if [[ -z "$pr_json" ]]; then
			cat_no_pr="${cat_no_pr}${tid}|${tstatus}|PR #${pr_num} unreachable\n"
			continue
		fi

		local pr_state
		pr_state=$(echo "$pr_json" | grep -o '"state":"[^"]*"' | cut -d'"' -f4 || echo "")

		case "$pr_state" in
		MERGED)
			cat_merged_stuck="${cat_merged_stuck}${tid}|${tstatus}|PR #${pr_num} MERGED\n"
			;;
		CLOSED)
			cat_closed_no_merge="${cat_closed_no_merge}${tid}|${tstatus}|PR #${pr_num} CLOSED\n"
			;;
		OPEN)
			if [[ "${trebase:-0}" -ge 3 ]]; then
				cat_rebase_exhausted="${cat_rebase_exhausted}${tid}|${tstatus}|PR #${pr_num} rebase_attempts=${trebase}\n"
			else
				cat_open_pr="${cat_open_pr}${tid}|${tstatus}|PR #${pr_num} OPEN (${terror})\n"
			fi
			;;
		esac
	done <<<"$stuck_tasks"

	# Print report
	local resolve_count=0

	_print_category() {
		local label="$1"
		local data="$2"
		local action="$3"
		if [[ -n "$data" ]]; then
			echo -e "${YELLOW}${label}${NC} (action: ${action}):"
			echo -e "$data" | while IFS='|' read -r cid cstatus cdetail; do
				[[ -z "$cid" ]] && continue
				echo "  $cid [$cstatus] — $cdetail"
			done
			echo ""
		fi
	}

	_print_category "MERGED BUT STUCK" "$cat_merged_stuck" "advance to deployed"
	_print_category "CLOSED WITHOUT MERGE" "$cat_closed_no_merge" "reset to queued for re-dispatch"
	_print_category "OBSOLETE PR" "$cat_obsolete" "cancel"
	_print_category "REBASE EXHAUSTED" "$cat_rebase_exhausted" "escalate to opus worker"
	_print_category "OPEN PR (in progress)" "$cat_open_pr" "wait for Phase 3.5/3.6"
	_print_category "NO PR / UNREACHABLE" "$cat_no_pr" "investigate manually"

	log_info "Total stuck: $total_stuck"
	echo ""

	if [[ "$dry_run" == "true" ]]; then
		log_info "[DRY RUN] No changes made"
		return 0
	fi

	if [[ "$auto_resolve" != "true" ]]; then
		log_info "Run with --auto-resolve to fix resolvable categories automatically"
		log_info "Or run 'supervisor-helper.sh pulse' to let Phase 3b2 handle it on next cycle"
		return 0
	fi

	# Auto-resolve: merged-but-stuck
	if [[ -n "$cat_merged_stuck" ]]; then
		log_info "Resolving merged-but-stuck tasks..."
		while IFS='|' read -r cid cstatus _cdetail; do
			[[ -z "$cid" ]] && continue
			local escaped_cid
			escaped_cid=$(sql_escape "$cid")

			if [[ "$cstatus" == "verify_failed" ]]; then
				# verify_failed: reset to deployed for re-verification, do NOT mark complete
				log_info "  $cid: resetting to deployed for re-verification (was verify_failed)"
				db "$SUPERVISOR_DB" "UPDATE tasks SET
					status = 'deployed', error = NULL,
					updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
				WHERE id = '$escaped_cid';" 2>/dev/null || true
				db "$SUPERVISOR_DB" "INSERT INTO state_log (task_id, from_state, to_state, timestamp, reason)
				VALUES ('$escaped_cid', 'verify_failed', 'deployed',
					strftime('%Y-%m-%dT%H:%M:%SZ','now'),
					'Triage: reset for re-verification (PR merged)');" 2>/dev/null || true
				sync_issue_status_label "$cid" "deployed" "triage" 2>>"$SUPERVISOR_LOG" || true
			else
				# blocked: advance to deployed and mark complete
				log_info "  $cid: advancing to deployed (was $cstatus)"
				db "$SUPERVISOR_DB" "UPDATE tasks SET
					status = 'deployed', error = NULL,
					completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
					updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
				WHERE id = '$escaped_cid';" 2>/dev/null || true
				db "$SUPERVISOR_DB" "INSERT INTO state_log (task_id, from_state, to_state, timestamp, reason)
				VALUES ('$escaped_cid', '$cstatus', 'deployed',
					strftime('%Y-%m-%dT%H:%M:%SZ','now'),
					'Triage auto-resolve: PR merged on GitHub');" 2>/dev/null || true
				cleanup_after_merge "$cid" 2>>"$SUPERVISOR_LOG" || true
				update_todo_on_complete "$cid" 2>>"$SUPERVISOR_LOG" || true
				sync_issue_status_label "$cid" "deployed" "triage" 2>>"$SUPERVISOR_LOG" || true
			fi
			resolve_count=$((resolve_count + 1))
		done <<<"$(echo -e "$cat_merged_stuck")"
	fi

	# Auto-resolve: closed-no-merge
	if [[ -n "$cat_closed_no_merge" ]]; then
		log_info "Resolving closed-without-merge tasks..."
		while IFS='|' read -r cid _cstatus _cdetail; do
			[[ -z "$cid" ]] && continue
			log_info "  $cid: resetting to queued"
			local escaped_cid
			escaped_cid=$(sql_escape "$cid")
			db "$SUPERVISOR_DB" "UPDATE tasks SET
				status = 'queued', error = NULL, pr_url = NULL,
				worktree = NULL, branch = NULL, retries = 0,
				rebase_attempts = 0,
				updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
			WHERE id = '$escaped_cid';" 2>/dev/null || true
			cleanup_after_merge "$cid" 2>>"$SUPERVISOR_LOG" || true
			resolve_count=$((resolve_count + 1))
		done <<<"$(echo -e "$cat_closed_no_merge")"
	fi

	# Auto-resolve: obsolete
	if [[ -n "$cat_obsolete" ]]; then
		log_info "Resolving obsolete tasks..."
		while IFS='|' read -r cid _cstatus cdetail; do
			[[ -z "$cid" ]] && continue
			log_info "  $cid: cancelling"
			cmd_transition "$cid" "cancelled" --error "Triage: obsolete PR ($cdetail)" 2>>"$SUPERVISOR_LOG" || true
			cleanup_after_merge "$cid" 2>>"$SUPERVISOR_LOG" || true
			resolve_count=$((resolve_count + 1))
		done <<<"$(echo -e "$cat_obsolete")"
	fi

	log_success "Resolved $resolve_count task(s)"
	return 0
}
