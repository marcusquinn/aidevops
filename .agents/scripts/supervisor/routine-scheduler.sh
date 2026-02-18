#!/usr/bin/env bash
# routine-scheduler.sh - Intelligent routine scheduling for supervisor pulse (t1093)
#
# Phase 14: AI-driven routine scheduling that adapts frequency and priority
# based on project state signals. Instead of hardcoded daily/hourly schedules,
# evaluates whether each routine is worth running now.
#
# Decision signals used:
#   - Consecutive zero-findings runs (skip audit if clean for N days)
#   - Open critical issues (prioritize bug fixes over maintenance routines)
#   - Recent task failure rate (prioritize self-healing over cosmetic updates)
#   - Time since last run (minimum interval still enforced as a floor)
#
# Routines managed:
#   - memory_audit    (Phase 9)  — skip if no memories to process
#   - coderabbit      (Phase 10) — skip if 0 findings for 3+ consecutive days
#   - task_creation   (Phase 10b)— skip if no new findings
#   - models_md       (Phase 12) — defer when critical issues are open
#   - skill_update    (Phase 13) — defer when failure rate is high
#
# Used by: pulse.sh Phase 14
# Sourced by: supervisor-helper.sh
# Globals expected: SUPERVISOR_DB, SUPERVISOR_DIR, SUPERVISOR_LOG
#   db(), log_info(), log_warn(), log_verbose(), sql_escape()

# State file for routine scheduling decisions (JSON)
ROUTINE_SCHEDULER_STATE="${ROUTINE_SCHEDULER_STATE:-$SUPERVISOR_DIR/routine-scheduler-state.json}"

# Minimum intervals (seconds) — AI can defer beyond these but never run before
readonly ROUTINE_MIN_INTERVAL_MEMORY_AUDIT=3600   # 1 hour floor
readonly ROUTINE_MIN_INTERVAL_CODERABBIT=43200    # 12 hour floor
readonly ROUTINE_MIN_INTERVAL_TASK_CREATION=43200 # 12 hour floor
readonly ROUTINE_MIN_INTERVAL_MODELS_MD=1800      # 30 min floor
readonly ROUTINE_MIN_INTERVAL_SKILL_UPDATE=43200  # 12 hour floor

# Skip thresholds — consecutive zero-findings runs before deferring
readonly ROUTINE_SKIP_THRESHOLD_CODERABBIT=3    # skip after 3 clean days
readonly ROUTINE_SKIP_THRESHOLD_TASK_CREATION=2 # skip after 2 clean runs

# Critical issue threshold — open issues with critical/bug labels
readonly ROUTINE_CRITICAL_ISSUE_THRESHOLD=3 # defer cosmetic routines if >= N critical issues

# Failure rate threshold — recent task failures that trigger self-heal priority
readonly ROUTINE_FAILURE_RATE_THRESHOLD=3 # defer maintenance if >= N failures in 24h

#######################################
# Initialize or load the routine scheduler state
# Creates state file if it doesn't exist
# Returns: 0 on success
#######################################
routine_scheduler_init() {
	if [[ ! -f "$ROUTINE_SCHEDULER_STATE" ]]; then
		mkdir -p "$(dirname "$ROUTINE_SCHEDULER_STATE")"
		cat >"$ROUTINE_SCHEDULER_STATE" <<'EOF'
{
  "routines": {
    "memory_audit": {
      "last_run": 0,
      "consecutive_zero_findings": 0,
      "last_findings_count": -1,
      "skip_until": 0,
      "run_count": 0
    },
    "coderabbit": {
      "last_run": 0,
      "consecutive_zero_findings": 0,
      "last_findings_count": -1,
      "skip_until": 0,
      "run_count": 0
    },
    "task_creation": {
      "last_run": 0,
      "consecutive_zero_findings": 0,
      "last_findings_count": -1,
      "skip_until": 0,
      "run_count": 0
    },
    "models_md": {
      "last_run": 0,
      "consecutive_zero_findings": 0,
      "last_findings_count": -1,
      "skip_until": 0,
      "run_count": 0
    },
    "skill_update": {
      "last_run": 0,
      "consecutive_zero_findings": 0,
      "last_findings_count": -1,
      "skip_until": 0,
      "run_count": 0
    }
  },
  "project_signals": {
    "critical_issues_count": 0,
    "recent_failure_count": 0,
    "signals_updated_at": 0
  }
}
EOF
		log_verbose "  Phase 14: Initialized routine scheduler state"
	fi
	return 0
}

#######################################
# Read a value from the routine scheduler state JSON
# Arguments:
#   $1 - jq path (e.g., ".routines.coderabbit.last_run")
# Returns: value on stdout, empty string on error
#######################################
routine_state_get() {
	local jq_path="$1"
	if [[ ! -f "$ROUTINE_SCHEDULER_STATE" ]] || ! command -v jq &>/dev/null; then
		echo ""
		return 0
	fi
	jq -r "${jq_path} // empty" "$ROUTINE_SCHEDULER_STATE" 2>/dev/null || echo ""
}

#######################################
# Update a value in the routine scheduler state JSON
# Arguments:
#   $1 - jq update expression (e.g., ".routines.coderabbit.last_run = 1234567890")
# Returns: 0 on success, 1 on failure
#######################################
routine_state_set() {
	local jq_expr="$1"
	if [[ ! -f "$ROUTINE_SCHEDULER_STATE" ]] || ! command -v jq &>/dev/null; then
		return 0
	fi
	local tmp_file
	tmp_file=$(mktemp "${ROUTINE_SCHEDULER_STATE}.tmp.XXXXXX") || return 1
	if jq "${jq_expr}" "$ROUTINE_SCHEDULER_STATE" >"$tmp_file" 2>/dev/null; then
		mv "$tmp_file" "$ROUTINE_SCHEDULER_STATE"
		return 0
	else
		rm -f "$tmp_file"
		return 1
	fi
}

#######################################
# Refresh project-level signals used for scheduling decisions
# Signals: critical issue count, recent failure count
# Cached for 10 minutes to avoid repeated GitHub API calls
# Returns: 0 on success
#######################################
routine_refresh_signals() {
	local now
	now=$(date +%s)
	local signals_updated_at
	signals_updated_at=$(routine_state_get ".project_signals.signals_updated_at")
	signals_updated_at="${signals_updated_at:-0}"

	# Cache signals for 10 minutes
	local cache_ttl=600
	if [[ $((now - signals_updated_at)) -lt "$cache_ttl" ]]; then
		local _signals_age=$((now - signals_updated_at))
		log_verbose "  Phase 14: Signals cached (updated ${_signals_age}s ago)"
		return 0
	fi

	log_verbose "  Phase 14: Refreshing project signals"

	# Count critical/bug open issues
	local critical_count=0
	if command -v gh &>/dev/null; then
		local gh_repo=""
		gh_repo=$(git -C "${REPO_PATH:-$(pwd)}" remote get-url origin 2>/dev/null |
			sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#' || echo "")
		if [[ -n "$gh_repo" ]]; then
			critical_count=$(gh issue list --repo "$gh_repo" --state open \
				--search 'label:bug,critical,P0,P1,"severity:critical","severity:high"' \
				--limit 50 --json number --jq 'length' 2>/dev/null || echo 0)
		fi
	fi

	# Count recent task failures (last 24h)
	local failure_count=0
	if [[ -f "${SUPERVISOR_DB:-}" ]]; then
		failure_count=$(db "$SUPERVISOR_DB" "
			SELECT COUNT(*) FROM tasks
			WHERE status = 'failed'
			  AND updated_at > datetime('now', '-24 hours');
		" 2>/dev/null || echo 0)
	fi

	# Update signals in state
	routine_state_set \
		".project_signals.critical_issues_count = ${critical_count} |
		 .project_signals.recent_failure_count = ${failure_count} |
		 .project_signals.signals_updated_at = ${now}" 2>/dev/null || true

	log_verbose "  Phase 14: Signals — critical_issues=${critical_count} recent_failures=${failure_count}"
	return 0
}

#######################################
# Evaluate whether a routine should run now
# Uses project signals + routine history to make an intelligent decision.
# Arguments:
#   $1 - routine name (memory_audit|coderabbit|task_creation|models_md|skill_update)
#   $2 - minimum interval in seconds (floor — never run before this)
# Outputs:
#   "run"    — routine should run now
#   "skip"   — routine should be skipped this cycle (with reason to stdout)
#   "defer"  — routine should be deferred this cycle (signal-driven; re-evaluated each pulse)
# Returns:
#   0 if should run, 1 if should skip/defer
#######################################
should_run_routine() {
	local routine_name="$1"
	local min_interval="${2:-3600}"

	local now
	now=$(date +%s)

	# Ensure state is initialized
	routine_scheduler_init 2>/dev/null || true

	# Check skip_until (explicit deferral)
	local skip_until
	skip_until=$(routine_state_get ".routines.${routine_name}.skip_until")
	skip_until="${skip_until:-0}"
	if [[ "$skip_until" -gt "$now" ]]; then
		local skip_remaining=$((skip_until - now))
		log_verbose "  Phase 14: ${routine_name} deferred (${skip_remaining}s remaining)"
		echo "defer"
		return 1
	fi

	# Check minimum interval floor
	local last_run
	last_run=$(routine_state_get ".routines.${routine_name}.last_run")
	last_run="${last_run:-0}"
	local elapsed=$((now - last_run))
	if [[ "$elapsed" -lt "$min_interval" ]]; then
		local remaining=$((min_interval - elapsed))
		log_verbose "  Phase 14: ${routine_name} skipped (${remaining}s until min interval)"
		echo "skip"
		return 1
	fi

	# Load project signals
	local critical_issues
	critical_issues=$(routine_state_get ".project_signals.critical_issues_count")
	critical_issues="${critical_issues:-0}"
	local recent_failures
	recent_failures=$(routine_state_get ".project_signals.recent_failure_count")
	recent_failures="${recent_failures:-0}"

	# Load routine-specific state
	local consecutive_zero
	consecutive_zero=$(routine_state_get ".routines.${routine_name}.consecutive_zero_findings")
	consecutive_zero="${consecutive_zero:-0}"

	# Apply intelligent scheduling rules per routine
	case "$routine_name" in
	coderabbit)
		# Skip if 3+ consecutive zero-findings days (clean codebase)
		if [[ "$consecutive_zero" -ge "$ROUTINE_SKIP_THRESHOLD_CODERABBIT" ]]; then
			# Still run weekly even if clean (reset check)
			local weekly_interval=604800
			if [[ "$elapsed" -lt "$weekly_interval" ]]; then
				log_info "  Phase 14: coderabbit skipped — ${consecutive_zero} consecutive clean runs (next forced run in $((weekly_interval - elapsed))s)"
				echo "skip"
				return 1
			fi
			log_info "  Phase 14: coderabbit forced — weekly check despite ${consecutive_zero} clean runs"
		fi
		# Defer if many critical issues open (workers should fix bugs, not audit)
		if [[ "$critical_issues" -ge "$ROUTINE_CRITICAL_ISSUE_THRESHOLD" ]]; then
			log_info "  Phase 14: coderabbit deferred — ${critical_issues} critical issues open (prioritizing bug fixes)"
			echo "defer"
			return 1
		fi
		;;

	task_creation)
		# Skip if 2+ consecutive zero-findings runs
		if [[ "$consecutive_zero" -ge "$ROUTINE_SKIP_THRESHOLD_TASK_CREATION" ]]; then
			local daily_interval=86400
			if [[ "$elapsed" -lt "$daily_interval" ]]; then
				log_info "  Phase 14: task_creation deferred — ${consecutive_zero} consecutive empty runs"
				echo "skip"
				return 1
			fi
		fi
		;;

	models_md)
		# Defer MODELS.md regen when critical issues are open (cosmetic update)
		if [[ "$critical_issues" -ge "$ROUTINE_CRITICAL_ISSUE_THRESHOLD" ]]; then
			log_verbose "  Phase 14: models_md deferred — ${critical_issues} critical issues open"
			echo "defer"
			return 1
		fi
		;;

	skill_update)
		# Defer skill updates when failure rate is high (system is struggling)
		if [[ "$recent_failures" -ge "$ROUTINE_FAILURE_RATE_THRESHOLD" ]]; then
			log_info "  Phase 14: skill_update deferred — ${recent_failures} recent failures (prioritizing self-healing)"
			echo "defer"
			return 1
		fi
		# Also defer when critical issues are open
		if [[ "$critical_issues" -ge "$ROUTINE_CRITICAL_ISSUE_THRESHOLD" ]]; then
			log_verbose "  Phase 14: skill_update deferred — ${critical_issues} critical issues open"
			echo "defer"
			return 1
		fi
		;;

	memory_audit)
		# Memory audit is lightweight — only skip if very recently run
		# (handled by min_interval check above)
		;;
	esac

	log_verbose "  Phase 14: ${routine_name} approved to run (elapsed=${elapsed}s, zero_streak=${consecutive_zero}, critical=${critical_issues}, failures=${recent_failures})"
	echo "run"
	return 0
}

#######################################
# Record that a routine ran and update its state
# Arguments:
#   $1 - routine name
#   $2 - findings count (0 = clean run, -1 = unknown/N/A, >0 = findings found)
# Returns: 0 on success
#######################################
routine_record_run() {
	local routine_name="$1"
	local findings_count="${2:--1}"

	local now
	now=$(date +%s)

	# Update consecutive zero-findings counter
	local consecutive_zero
	consecutive_zero=$(routine_state_get ".routines.${routine_name}.consecutive_zero_findings")
	consecutive_zero="${consecutive_zero:-0}"

	if [[ "$findings_count" -eq 0 ]]; then
		consecutive_zero=$((consecutive_zero + 1))
	elif [[ "$findings_count" -gt 0 ]]; then
		consecutive_zero=0
	fi
	# findings_count == -1 (unknown): don't change the streak

	# Get current run count
	local run_count
	run_count=$(routine_state_get ".routines.${routine_name}.run_count")
	run_count="${run_count:-0}"
	run_count=$((run_count + 1))

	routine_state_set \
		".routines.${routine_name}.last_run = ${now} |
		 .routines.${routine_name}.consecutive_zero_findings = ${consecutive_zero} |
		 .routines.${routine_name}.last_findings_count = ${findings_count} |
		 .routines.${routine_name}.skip_until = 0 |
		 .routines.${routine_name}.run_count = ${run_count}" 2>/dev/null || true

	log_verbose "  Phase 14: Recorded ${routine_name} run (findings=${findings_count}, zero_streak=${consecutive_zero}, total_runs=${run_count})"
	return 0
}

#######################################
# Set an explicit deferral for a routine
# Arguments:
#   $1 - routine name
#   $2 - defer duration in seconds
# Returns: 0 on success
#######################################
routine_defer() {
	local routine_name="$1"
	local defer_seconds="${2:-3600}"

	local now
	now=$(date +%s)
	local skip_until=$((now + defer_seconds))

	routine_state_set ".routines.${routine_name}.skip_until = ${skip_until}" 2>/dev/null || true
	log_verbose "  Phase 14: Deferred ${routine_name} for ${defer_seconds}s (until $(date -r "$skip_until" '+%H:%M:%S' 2>/dev/null || date -d "@$skip_until" '+%H:%M:%S' 2>/dev/null || echo "$skip_until"))"
	return 0
}

#######################################
# Print a summary of routine scheduling state
# Used for dashboard/status display
# Returns: 0 on success
#######################################
routine_scheduler_status() {
	if [[ ! -f "$ROUTINE_SCHEDULER_STATE" ]] || ! command -v jq &>/dev/null; then
		echo "  Routine scheduler: state file not found or jq unavailable"
		return 0
	fi

	local now
	now=$(date +%s)

	echo "  Routine Scheduler State (Phase 14):"
	echo "  ======================================"

	local routines=("memory_audit" "coderabbit" "task_creation" "models_md" "skill_update")
	for routine in "${routines[@]}"; do
		local last_run consecutive_zero skip_until run_count
		last_run=$(routine_state_get ".routines.${routine}.last_run")
		consecutive_zero=$(routine_state_get ".routines.${routine}.consecutive_zero_findings")
		skip_until=$(routine_state_get ".routines.${routine}.skip_until")
		run_count=$(routine_state_get ".routines.${routine}.run_count")

		last_run="${last_run:-0}"
		consecutive_zero="${consecutive_zero:-0}"
		skip_until="${skip_until:-0}"
		run_count="${run_count:-0}"

		local elapsed=$((now - last_run))
		local status_str="ready"
		if [[ "$skip_until" -gt "$now" ]]; then
			status_str="deferred ($((skip_until - now))s)"
		elif [[ "$last_run" -eq 0 ]]; then
			status_str="never run"
		fi

		printf "  %-16s runs=%-4s last=%-8s zero_streak=%-3s status=%s\n" \
			"${routine}" "${run_count}" "${elapsed}s ago" "${consecutive_zero}" "${status_str}"
	done

	local critical_issues recent_failures
	critical_issues=$(routine_state_get ".project_signals.critical_issues_count")
	recent_failures=$(routine_state_get ".project_signals.recent_failure_count")
	echo ""
	echo "  Signals: critical_issues=${critical_issues:-0} recent_failures=${recent_failures:-0}"
	return 0
}

#######################################
# Phase 14: Intelligent routine scheduling
# Wraps Phases 9-13 with AI-driven scheduling decisions.
# Called from cmd_pulse() during Phase 14 (runs before Phases 9–13).
# Arguments: none (uses globals)
# Returns: 0 on success
#######################################
run_phase14_routine_scheduler() {
	log_verbose "  Phase 14: Intelligent routine scheduling"

	# Ensure jq is available (required for state management)
	if ! command -v jq &>/dev/null; then
		log_verbose "  Phase 14: jq not available — skipping intelligent scheduling"
		return 0
	fi

	# Initialize state
	routine_scheduler_init 2>/dev/null || true

	# Refresh project signals (cached 10 min)
	routine_refresh_signals 2>/dev/null || true

	# Evaluate each routine and update scheduling recommendations
	# Results are stored in state for use by the individual phases
	# This phase runs BEFORE phases 9-13 to pre-compute decisions

	# Evaluate memory_audit (Phase 9)
	local mem_decision
	mem_decision=$(should_run_routine "memory_audit" "$ROUTINE_MIN_INTERVAL_MEMORY_AUDIT" 2>/dev/null || true)
	export ROUTINE_DECISION_MEMORY_AUDIT="${mem_decision:-run}"

	# Evaluate coderabbit (Phase 10)
	local cr_decision
	cr_decision=$(should_run_routine "coderabbit" "$ROUTINE_MIN_INTERVAL_CODERABBIT" 2>/dev/null || true)
	export ROUTINE_DECISION_CODERABBIT="${cr_decision:-run}"

	# Evaluate task_creation (Phase 10b)
	local tc_decision
	tc_decision=$(should_run_routine "task_creation" "$ROUTINE_MIN_INTERVAL_TASK_CREATION" 2>/dev/null || true)
	export ROUTINE_DECISION_TASK_CREATION="${tc_decision:-run}"

	# Evaluate models_md (Phase 12)
	local mm_decision
	mm_decision=$(should_run_routine "models_md" "$ROUTINE_MIN_INTERVAL_MODELS_MD" 2>/dev/null || true)
	export ROUTINE_DECISION_MODELS_MD="${mm_decision:-run}"

	# Evaluate skill_update (Phase 13)
	local su_decision
	su_decision=$(should_run_routine "skill_update" "$ROUTINE_MIN_INTERVAL_SKILL_UPDATE" 2>/dev/null || true)
	export ROUTINE_DECISION_SKILL_UPDATE="${su_decision:-run}"

	log_verbose "  Phase 14: Decisions — memory_audit=${ROUTINE_DECISION_MEMORY_AUDIT} coderabbit=${ROUTINE_DECISION_CODERABBIT} task_creation=${ROUTINE_DECISION_TASK_CREATION} models_md=${ROUTINE_DECISION_MODELS_MD} skill_update=${ROUTINE_DECISION_SKILL_UPDATE}"

	# Log summary to supervisor log
	local skip_count=0
	for decision in "$ROUTINE_DECISION_MEMORY_AUDIT" "$ROUTINE_DECISION_CODERABBIT" "$ROUTINE_DECISION_TASK_CREATION" "$ROUTINE_DECISION_MODELS_MD" "$ROUTINE_DECISION_SKILL_UPDATE"; do
		[[ "$decision" != "run" ]] && skip_count=$((skip_count + 1))
	done

	if [[ "$skip_count" -gt 0 ]]; then
		log_info "  Phase 14: Intelligent scheduling — deferring ${skip_count}/5 routine(s) based on project state"
	else
		log_verbose "  Phase 14: All routines approved to run"
	fi

	# Store scheduling decision event in DB for auditability
	if [[ -f "${SUPERVISOR_DB:-}" ]]; then
		db "$SUPERVISOR_DB" "
			INSERT INTO state_log (task_id, from_state, to_state, reason)
			VALUES ('routine-scheduler', 'evaluated', 'complete',
					'Phase 14: mem=${ROUTINE_DECISION_MEMORY_AUDIT} cr=${ROUTINE_DECISION_CODERABBIT} tc=${ROUTINE_DECISION_TASK_CREATION} mm=${ROUTINE_DECISION_MODELS_MD} su=${ROUTINE_DECISION_SKILL_UPDATE} skipped=${skip_count}/5');
		" 2>/dev/null || true
	fi

	return 0
}
