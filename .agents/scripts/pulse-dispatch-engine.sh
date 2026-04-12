#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-engine.sh — High-level dispatch engine — worker launch check, ranked candidate build, deterministic fill-floor, LLM supervisor gate, backlog snapshot, adaptive launch settle wait, utilization invariants, underfill recycler + re-fill during active cycle, pre-flight stages, initial underfill computation, early-exit recycle loop.
#
# Extracted from pulse-wrapper.sh in Phase 9 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
# Phase 9 is the highest-risk phase — core dispatch logic.
#
# This module is sourced by pulse-wrapper.sh. Depends on shared-constants.sh
# and worker-lifecycle-common.sh being sourced first by the orchestrator.
#
# Functions in this module (in source order):
#   - check_worker_launch
#   - build_ranked_dispatch_candidates_json
#   - dispatch_deterministic_fill_floor
#   - _should_run_llm_supervisor
#   - _update_backlog_snapshot
#   - _adaptive_launch_settle_wait
#   - apply_deterministic_fill_floor
#   - enforce_utilization_invariants
#   - run_underfill_worker_recycler
#   - maybe_refill_underfilled_pool_during_active_pulse
#   - _run_preflight_stages
#   - _compute_initial_underfill
#   - _run_early_exit_recycle_loop
#
# Pure move from pulse-wrapper.sh. Byte-identical function bodies.
# Phase 12 post-gate simplification will split the largest functions
# (dispatch_with_dedup=370, _is_task_committed_to_main=189, etc.).

[[ -n "${_PULSE_DISPATCH_ENGINE_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_ENGINE_LOADED=1

#######################################
# Launch validation gate for pulse dispatches (t1453)
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - optional grace timeout in seconds
#
# Exit codes:
#   0 - worker launch appears valid (process observed, no CLI usage output marker)
#   1 - launch invalid (no process within grace window or usage output detected)
#######################################
check_worker_launch() {
	local issue_number="$1"
	local repo_slug="$2"
	local grace_seconds="${3:-$PULSE_LAUNCH_GRACE_SECONDS}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_worker_launch: invalid arguments issue='$issue_number' repo='$repo_slug'" >>"$LOGFILE"
		return 1
	fi
	[[ "$grace_seconds" =~ ^[0-9]+$ ]] || grace_seconds="$PULSE_LAUNCH_GRACE_SECONDS"
	if [[ "$grace_seconds" -lt 1 ]]; then
		grace_seconds=1
	fi

	local safe_slug
	safe_slug=$(echo "$repo_slug" | tr '/:' '--')
	local -a log_candidates=(
		"/tmp/pulse-${safe_slug}-${issue_number}.log"
		"/tmp/pulse-${issue_number}.log"
	)

	local elapsed=0
	local poll_seconds=2
	while [[ "$elapsed" -lt "$grace_seconds" ]]; do
		if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
			local candidate
			for candidate in "${log_candidates[@]}"; do
				if [[ -f "$candidate" ]] && rg -q '^opencode run \[message\.\.\]|^run opencode with a message|^Options:' "$candidate"; then
					recover_failed_launch_state "$issue_number" "$repo_slug" "cli_usage_output"
					echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — CLI usage output detected in ${candidate}" >>"$LOGFILE"
					return 1
				fi
			done
			# Launch confirmed — do NOT reset fast-fail counter here.
			# A successful launch does not mean successful completion.
			# The counter is reset only when the issue is closed or a PR
			# is confirmed. Resetting on launch defeated the counter
			# entirely — workers that launched but died during execution
			# were invisible. (GH#2076, GH#17378)
			return 0
		fi
		sleep "$poll_seconds"
		elapsed=$((elapsed + poll_seconds))
	done

	recover_failed_launch_state "$issue_number" "$repo_slug" "no_worker_process"
	echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — no active worker process within ${grace_seconds}s" >>"$LOGFILE"
	return 1
}

#######################################
# Build ranked deterministic dispatch candidates across all pulse repos.
# Arguments:
#   $1 - max issues to fetch per repo (optional)
# Returns: JSON array sorted by score desc, updatedAt asc
#######################################
build_ranked_dispatch_candidates_json() {
	local per_repo_limit="${1:-$PULSE_RUNNABLE_ISSUE_LIMIT}"
	[[ "$per_repo_limit" =~ ^[0-9]+$ ]] || per_repo_limit="$PULSE_RUNNABLE_ISSUE_LIMIT"

	if [[ ! -f "$REPOS_JSON" ]]; then
		printf '[]\n'
		return 0
	fi

	local tmp_candidates
	tmp_candidates=$(mktemp 2>/dev/null || echo "/tmp/aidevops-pulse-candidates.$$")
	: >"$tmp_candidates"

	while IFS='|' read -r repo_slug repo_path repo_priority ph_start ph_end expires; do
		[[ -n "$repo_slug" && -n "$repo_path" ]] || continue
		if ! check_repo_pulse_schedule "$repo_slug" "$ph_start" "$ph_end" "$expires" "$REPOS_JSON"; then
			continue
		fi
		local repo_candidates_json
		repo_candidates_json=$(list_dispatchable_issue_candidates_json "$repo_slug" "$per_repo_limit") || repo_candidates_json='[]'
		if [[ -z "$repo_candidates_json" || "$repo_candidates_json" == "[]" ]]; then
			continue
		fi

		printf '%s' "$repo_candidates_json" | jq -c --arg slug "$repo_slug" --arg path "$repo_path" --arg priority "$repo_priority" '
			.[] |
			. + {
				repo_slug: $slug,
				repo_path: $path,
				repo_priority: $priority,
				score: (
					(if $priority == "product" then 2000 elif $priority == "tooling" then 1000 else 0 end) +
					(if (.labels | index("priority:critical")) != null then 10000
					 elif (.labels | index("priority:high")) != null then 8000
					 elif (.labels | index("bug")) != null then 7000
					 elif (.labels | index("enhancement")) != null then 6000
					 elif (.labels | index("quality-debt")) != null then 5000
					 elif (.labels | index("simplification-debt")) != null then 4000
					 else 3000 end)
				)
			}
		' >>"$tmp_candidates" 2>/dev/null || true
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "" and .path != "") | [(.slug), (.path), (.priority // "tooling"), (if .pulse_hours then (.pulse_hours.start | tostring) else "" end), (if .pulse_hours then (.pulse_hours.end | tostring) else "" end), (.pulse_expires // "")] | join("|")' "$REPOS_JSON" 2>/dev/null)

	if [[ ! -s "$tmp_candidates" ]]; then
		rm -f "$tmp_candidates"
		printf '[]\n'
		return 0
	fi

	jq -cs 'sort_by([-.score, (.updatedAt // "")])' "$tmp_candidates" 2>/dev/null || printf '[]\n'
	rm -f "$tmp_candidates"
	return 0
}

#######################################
# Deterministic fill floor for obvious backlog.
#
# This is intentionally narrow: it only materializes already-eligible issues
# and fills empty local slots. Ranking remains simple and auditable; judgment
# stays with the pulse LLM for merges, blockers, and unusual edge cases.
#
# Returns: dispatched worker count via stdout
#######################################
dispatch_deterministic_fill_floor() {
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Deterministic fill floor skipped: stop flag present" >>"$LOGFILE"
		echo 0
		return 0
	fi

	local max_workers active_workers available_slots runnable_count queued_without_worker
	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	runnable_count=$(normalize_count_output "$(count_runnable_candidates)")
	queued_without_worker=$(normalize_count_output "$(count_queued_without_worker)")
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0

	available_slots=$((max_workers - active_workers))
	if [[ "$available_slots" -le 0 ]]; then
		echo 0
		return 0
	fi

	local self_login
	self_login=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$self_login" ]]; then
		echo "[pulse-wrapper] Deterministic fill floor skipped: unable to resolve GitHub login" >>"$LOGFILE"
		echo 0
		return 0
	fi

	local candidates_json candidate_count
	candidates_json=$(build_ranked_dispatch_candidates_json "$PULSE_RUNNABLE_ISSUE_LIMIT") || candidates_json='[]'
	candidate_count=$(printf '%s' "$candidates_json" | jq 'length' 2>/dev/null) || candidate_count=0
	[[ "$candidate_count" =~ ^[0-9]+$ ]] || candidate_count=0
	if [[ "$candidate_count" -eq 0 ]]; then
		echo 0
		return 0
	fi

	echo "[pulse-wrapper] Deterministic fill floor: available=${available_slots}, runnable=${runnable_count}, queued_without_worker=${queued_without_worker}, candidates=${candidate_count}" >>"$LOGFILE"

	# Triage reviews first — community responsiveness before implementation backlog.
	# dispatch_triage_reviews returns the remaining available count via stdout.
	local triage_remaining
	triage_remaining=$(dispatch_triage_reviews "$available_slots" 2>>"$LOGFILE") || triage_remaining="$available_slots"
	[[ "$triage_remaining" =~ ^[0-9]+$ ]] || triage_remaining="$available_slots"
	local triage_dispatched=$((available_slots - triage_remaining))
	if [[ "$triage_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] Deterministic fill floor: dispatched ${triage_dispatched} triage review(s), ${triage_remaining} slots remaining for implementation" >>"$LOGFILE"
	fi
	available_slots="$triage_remaining"

	# Enrichment pass: analyze failed issues with reasoning before re-dispatch.
	# Runs after triage (responsiveness) but before implementation dispatch
	# (so enriched issues get better context on the next dispatch attempt).
	local enrichment_remaining
	enrichment_remaining=$(dispatch_enrichment_workers "$available_slots" 2>>"$LOGFILE") || enrichment_remaining="$available_slots"
	[[ "$enrichment_remaining" =~ ^[0-9]+$ ]] || enrichment_remaining="$available_slots"
	local enrichment_dispatched=$((available_slots - enrichment_remaining))
	if [[ "$enrichment_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] Deterministic fill floor: dispatched ${enrichment_dispatched} enrichment worker(s), ${enrichment_remaining} slots remaining for implementation" >>"$LOGFILE"
	fi
	available_slots="$enrichment_remaining"

	local dispatched_count=0
	while IFS= read -r candidate_json; do
		[[ -n "$candidate_json" ]] || continue
		if [[ "$dispatched_count" -ge "$available_slots" ]]; then
			break
		fi
		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Deterministic fill floor stopping early: stop flag appeared" >>"$LOGFILE"
			break
		fi

		local issue_number repo_slug repo_path issue_url issue_title dispatch_title prompt labels_csv model_override
		issue_number=$(printf '%s' "$candidate_json" | jq -r '.number // empty' 2>/dev/null)
		repo_slug=$(printf '%s' "$candidate_json" | jq -r '.repo_slug // empty' 2>/dev/null)
		repo_path=$(printf '%s' "$candidate_json" | jq -r '.repo_path // empty' 2>/dev/null)
		issue_url=$(printf '%s' "$candidate_json" | jq -r '.url // empty' 2>/dev/null)
		issue_title=$(printf '%s' "$candidate_json" | jq -r '.title // empty' 2>/dev/null | tr '\n' ' ')
		labels_csv=$(printf '%s' "$candidate_json" | jq -r '(.labels // []) | join(",")' 2>/dev/null)
		[[ "$issue_number" =~ ^[0-9]+$ ]] || continue
		[[ -n "$repo_slug" && -n "$repo_path" ]] || continue

		if check_terminal_blockers "$issue_number" "$repo_slug" >/dev/null 2>&1; then
			continue
		fi

		# Skip issues with repeated launch deaths (t1888)
		if fast_fail_is_skipped "$issue_number" "$repo_slug"; then
			echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} (${repo_slug}) — fast-fail threshold reached" >>"$LOGFILE"
			continue
		fi

		# t1899/t1937: Skip issues with placeholder/empty bodies — dispatching a
		# worker to an undescribed issue wastes a session. The body check is
		# a single API call cached for the candidate loop iteration.
		# Detects both the legacy GitLab stub and the current claim-task-id.sh
		# stub marker ("no description provided — enrich before dispatch").
		local issue_body
		issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body -q '.body' 2>/dev/null || echo "")
		if [[ -z "$issue_body" || "$issue_body" == "Task created via claim-task-id.sh" || "$issue_body" == "null" ]]; then
			echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} (${repo_slug}) — placeholder/empty issue body, needs enrichment before dispatch" >>"$LOGFILE"
			continue
		fi
		# t1937: Detect the current claim-task-id.sh stub marker embedded in
		# structured bodies (## Task\n\n<title>\n\n---\n*Created by claim-task-id.sh ...*)
		if [[ "$issue_body" == *"no description provided — enrich before dispatch"* ]]; then
			echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} (${repo_slug}) — claim-task-id.sh stub body, needs enrichment before dispatch" >>"$LOGFILE"
			continue
		fi

		dispatch_title="Issue #${issue_number}"
		prompt="/full-loop Implement issue #${issue_number}"
		if [[ -n "$issue_url" ]]; then
			prompt="${prompt} (${issue_url})"
		fi
		model_override=$(resolve_dispatch_model_for_labels "$labels_csv")

		local dispatch_rc=0
		dispatch_with_dedup "$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
			"$self_login" "$repo_path" "$prompt" "issue-${issue_number}" "$model_override" || dispatch_rc=$?
		if [[ "$dispatch_rc" -ne 0 ]]; then
			continue
		fi

		if ! check_worker_launch "$issue_number" "$repo_slug" >/dev/null 2>&1; then
			continue
		fi

		dispatched_count=$((dispatched_count + 1))
	done < <(printf '%s' "$candidates_json" | jq -c '.[]' 2>/dev/null)

	local total_dispatched=$((dispatched_count + triage_dispatched))
	echo "[pulse-wrapper] Deterministic fill floor complete: dispatched=${total_dispatched} (${triage_dispatched} triage + ${dispatched_count} implementation), target_available=${available_slots}" >>"$LOGFILE"
	echo "$total_dispatched"
	return 0
}

_should_run_llm_supervisor() {
	local now_epoch
	now_epoch=$(date +%s)

	# 1. Daily sweep: always run if last LLM was >24h ago
	local last_llm_epoch=0
	if [[ -f "${PULSE_DIR}/last_llm_run_epoch" ]]; then
		last_llm_epoch=$(cat "${PULSE_DIR}/last_llm_run_epoch" 2>/dev/null) || last_llm_epoch=0
	fi
	[[ "$last_llm_epoch" =~ ^[0-9]+$ ]] || last_llm_epoch=0

	local llm_age=$((now_epoch - last_llm_epoch))
	if [[ "$llm_age" -ge "$PULSE_LLM_DAILY_INTERVAL" ]]; then
		echo "[pulse-wrapper] LLM supervisor: daily sweep due (last run ${llm_age}s ago)" >>"$LOGFILE"
		printf 'daily_sweep\n' >"${PULSE_DIR}/llm_trigger_mode"
		return 0
	fi

	# 2. Backlog stall: check if issue+PR count has changed
	local snapshot_file="${PULSE_DIR}/backlog_snapshot.txt"
	if [[ ! -f "$snapshot_file" ]]; then
		# First run — take snapshot and run LLM
		_update_backlog_snapshot "$now_epoch"
		echo "[pulse-wrapper] LLM supervisor: first run (no snapshot)" >>"$LOGFILE"
		printf 'first_run\n' >"${PULSE_DIR}/llm_trigger_mode"
		return 0
	fi

	local snap_epoch snap_issues snap_prs
	read -r snap_epoch snap_issues snap_prs <"$snapshot_file" 2>/dev/null || snap_epoch=0
	[[ "$snap_epoch" =~ ^[0-9]+$ ]] || snap_epoch=0
	[[ "$snap_issues" =~ ^[0-9]+$ ]] || snap_issues=0
	[[ "$snap_prs" =~ ^[0-9]+$ ]] || snap_prs=0

	# Get current counts (fast — single API call per repo, cached in prefetch)
	# t1890: exclude persistent/supervisor/contributor issues from stall detection.
	# These management issues never close, so including them inflates the count
	# and makes the backlog appear stalled even when all actionable work is done.
	local current_issues=0 current_prs=0
	while IFS='|' read -r slug _; do
		[[ -n "$slug" ]] || continue
		local ic pc
		ic=$(gh issue list --repo "$slug" --state open --json number,labels --limit 500 \
			--jq '[.[] | select(.labels | map(.name) | (index("persistent")) | not)] | length' 2>/dev/null) || ic=0
		pc=$(gh pr list --repo "$slug" --state open --json number --jq 'length' --limit 200 2>/dev/null) || pc=0
		[[ "$ic" =~ ^[0-9]+$ ]] || ic=0
		[[ "$pc" =~ ^[0-9]+$ ]] || pc=0
		current_issues=$((current_issues + ic))
		current_prs=$((current_prs + pc))
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | [.slug, .path] | join("|")' "$REPOS_JSON" 2>/dev/null)

	local snap_age=$((now_epoch - snap_epoch))
	local total_before=$((snap_issues + snap_prs))
	local total_now=$((current_issues + current_prs))

	# Backlog is progressing — update snapshot, skip LLM
	if [[ "$total_now" -lt "$total_before" ]]; then
		_update_backlog_snapshot "$now_epoch" "$current_issues" "$current_prs"
		return 1
	fi

	# Backlog unchanged — check if stalled long enough
	if [[ "$snap_age" -ge "$PULSE_LLM_STALL_THRESHOLD" ]]; then
		echo "[pulse-wrapper] LLM supervisor: backlog stalled for ${snap_age}s (issues=${current_issues} prs=${current_prs}, unchanged from ${snap_issues}+${snap_prs})" >>"$LOGFILE"
		_update_backlog_snapshot "$now_epoch" "$current_issues" "$current_prs"
		printf 'stall\n' >"${PULSE_DIR}/llm_trigger_mode"
		return 0
	fi

	# Stalled but not long enough yet
	return 1
}

_update_backlog_snapshot() {
	local epoch="${1:-$(date +%s)}"
	local issues="${2:-0}"
	local prs="${3:-0}"
	printf '%s %s %s\n' "$epoch" "$issues" "$prs" >"${PULSE_DIR}/backlog_snapshot.txt"
	return 0
}

#######################################
# Compute and apply an adaptive launch-settle wait (t1887).
#
# Scales the wait from 0s (0 dispatches) to PULSE_LAUNCH_GRACE_SECONDS
# (PULSE_LAUNCH_SETTLE_BATCH_MAX or more dispatches) using linear
# interpolation. This avoids the static 35s wait when no workers were
# launched, saving ~35s per idle cycle.
#
# Formula: wait = ceil(dispatched / batch_max * grace_max)
# Examples (grace_max=35, batch_max=5):
#   0 dispatches → 0s
#   1 dispatch   → 7s
#   2 dispatches → 14s
#   3 dispatches → 21s
#   4 dispatches → 28s
#   5+ dispatches → 35s
#
# Arguments:
#   $1 - dispatched_count (integer, number of workers just launched)
#   $2 - context label for log (e.g. "fill floor", "recycle loop")
#######################################
_adaptive_launch_settle_wait() {
	local dispatched_count="${1:-0}"
	local context_label="${2:-dispatch}"

	[[ "$dispatched_count" =~ ^[0-9]+$ ]] || dispatched_count=0
	if [[ "$dispatched_count" -eq 0 ]]; then
		echo "[pulse-wrapper] Adaptive settle wait (${context_label}): 0 dispatches — skipping wait" >>"$LOGFILE"
		return 0
	fi

	local grace_max="$PULSE_LAUNCH_GRACE_SECONDS"
	local batch_max="$PULSE_LAUNCH_SETTLE_BATCH_MAX"
	[[ "$grace_max" =~ ^[0-9]+$ ]] || grace_max=35
	[[ "$batch_max" =~ ^[0-9]+$ ]] || batch_max=5
	[[ "$batch_max" -lt 1 ]] && batch_max=1

	# Clamp dispatched_count to batch_max ceiling
	local clamped="$dispatched_count"
	if [[ "$clamped" -gt "$batch_max" ]]; then
		clamped="$batch_max"
	fi

	# Linear interpolation: ceil(clamped / batch_max * grace_max)
	# Integer arithmetic: (clamped * grace_max + batch_max - 1) / batch_max
	local wait_seconds=$(((clamped * grace_max + batch_max - 1) / batch_max))
	[[ "$wait_seconds" -gt "$grace_max" ]] && wait_seconds="$grace_max"

	echo "[pulse-wrapper] Adaptive settle wait (${context_label}): ${dispatched_count} dispatch(es) → waiting ${wait_seconds}s (max ${grace_max}s at ${batch_max}+ dispatches)" >>"$LOGFILE"
	sleep "$wait_seconds"
	return 0
}

#
# Dispatches deterministic fill floor, then waits adaptively based on
# how many workers were launched so they can appear in process lists
# before the next worker count.
#######################################
apply_deterministic_fill_floor() {
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Deterministic fill floor skipped: stop flag present" >>"$LOGFILE"
		return 0
	fi

	local fill_dispatched
	fill_dispatched=$(dispatch_deterministic_fill_floor) || fill_dispatched=0
	[[ "$fill_dispatched" =~ ^[0-9]+$ ]] || fill_dispatched=0

	_adaptive_launch_settle_wait "$fill_dispatched" "fill floor"
	return 0
}

#######################################
# Enforce utilization invariants post-pulse (DEPRECATED — t1453)
#
# The LLM pulse session now runs a monitoring loop (sleep 60s, check
# slots, backfill) for up to 60 minutes, making this wrapper-level
# backfill loop redundant. The function is kept as a no-op stub for
# backward compatibility (pulse.md sources this file).
#
# Previously: re-launched run_pulse() in a loop until active workers
# >= MAX_WORKERS or no runnable work remained. Each iteration paid
# the full LLM cold-start penalty (~125s). The monitoring loop inside
# the LLM session eliminates this overhead — each backfill iteration
# costs ~3K tokens instead of a full session restart.
#######################################
enforce_utilization_invariants() {
	echo "[pulse-wrapper] enforce_utilization_invariants is deprecated — LLM session handles continuous slot filling" >>"$LOGFILE"
	return 0
}

#######################################
# Recycle stale workers aggressively when underfill is severe
#
# During deep underfill, long-running workers can occupy slots while making
# no mergeable progress. Run worker-watchdog with stricter thresholds so
# stale workers are recycled before the next pulse dispatch attempt.
#
# Throttle (t1885): when runnable+queued candidates are scarce
# (<= UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD) and underfill is not severe
# (< UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT), skip the watchdog run if it was
# called within UNDERFILL_RECYCLE_THROTTLE_SECS (default 5 min). This avoids
# repeated no-op watchdog scans when there is little work to dispatch.
# Severe underfill (>= 75% deficit) always bypasses the throttle.
#
# Arguments:
#   $1 - max workers
#   $2 - active workers
#   $3 - runnable candidate count
#   $4 - queued_without_worker count
#######################################
run_underfill_worker_recycler() {
	local max_workers="$1"
	local active_workers="$2"
	local runnable_count="$3"
	local queued_without_worker="$4"

	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$runnable_count" =~ ^[0-9]+$ ]] || runnable_count=0
	[[ "$queued_without_worker" =~ ^[0-9]+$ ]] || queued_without_worker=0

	if [[ "$active_workers" -ge "$max_workers" ]]; then
		return 0
	fi

	if [[ "$runnable_count" -eq 0 && "$queued_without_worker" -eq 0 ]]; then
		return 0
	fi

	if [[ ! -x "$WORKER_WATCHDOG_HELPER" ]]; then
		echo "[pulse-wrapper] Underfill recycler skipped: worker-watchdog helper missing or not executable (${WORKER_WATCHDOG_HELPER})" >>"$LOGFILE"
		return 0
	fi

	local deficit_pct
	deficit_pct=$(((max_workers - active_workers) * 100 / max_workers))
	if [[ "$deficit_pct" -lt "$UNDERFILL_RECYCLE_DEFICIT_MIN_PCT" ]]; then
		return 0
	fi

	# Time-based throttle (t1885): when runnable candidates are scarce and underfill
	# is not severe, avoid hammering worker-watchdog on every pulse cycle. Running
	# watchdog with few candidates produces no kills but still pays the process-scan
	# cost and generates noisy log entries. Bypass throttle for severe underfill
	# (>= UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT) so critical slot recovery is never delayed.
	local recycle_throttle_file="${HOME}/.aidevops/logs/underfill-recycle-last-run"
	local total_candidates=$((runnable_count + queued_without_worker))
	if [[ "$total_candidates" -le "$UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD" &&
		"$deficit_pct" -lt "$UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT" ]]; then
		local now_epoch
		now_epoch=$(date +%s)
		local last_run_epoch=0
		if [[ -f "$recycle_throttle_file" ]]; then
			last_run_epoch=$(cat "$recycle_throttle_file" 2>/dev/null || echo "0")
			[[ "$last_run_epoch" =~ ^[0-9]+$ ]] || last_run_epoch=0
		fi
		local secs_since_last=$((now_epoch - last_run_epoch))
		if [[ "$secs_since_last" -lt "$UNDERFILL_RECYCLE_THROTTLE_SECS" ]]; then
			echo "[pulse-wrapper] Underfill recycler throttled: candidates=${total_candidates} (threshold=${UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD}), deficit=${deficit_pct}% (<${UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT}% severe), last_run=${secs_since_last}s ago (throttle=${UNDERFILL_RECYCLE_THROTTLE_SECS}s)" >>"$LOGFILE"
			return 0
		fi
	fi

	local thrash_elapsed_threshold
	local thrash_message_threshold
	local progress_timeout
	local max_runtime
	if [[ "$deficit_pct" -ge 50 ]]; then
		thrash_elapsed_threshold=1800
		thrash_message_threshold=90
		progress_timeout=420
		max_runtime=7200
	else
		thrash_elapsed_threshold=3600
		thrash_message_threshold=120
		progress_timeout=480
		max_runtime=9000
	fi

	echo "[pulse-wrapper] Underfill recycler: running worker-watchdog (active ${active_workers}/${max_workers}, deficit ${deficit_pct}%, runnable=${runnable_count}, queued_without_worker=${queued_without_worker})" >>"$LOGFILE"

	if WORKER_WATCHDOG_NOTIFY=false \
		WORKER_THRASH_ELAPSED_THRESHOLD="$thrash_elapsed_threshold" \
		WORKER_THRASH_MESSAGE_THRESHOLD="$thrash_message_threshold" \
		WORKER_PROGRESS_TIMEOUT="$progress_timeout" \
		WORKER_MAX_RUNTIME="$max_runtime" \
		"$WORKER_WATCHDOG_HELPER" --check >>"$LOGFILE" 2>&1; then
		echo "[pulse-wrapper] Underfill recycler complete: worker-watchdog check finished" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Underfill recycler warning: worker-watchdog returned non-zero" >>"$LOGFILE"
	fi

	# Update throttle timestamp after each run (t1885)
	date +%s >"$recycle_throttle_file" 2>/dev/null || true

	return 0
}

#######################################
# Refill an underfilled worker pool while the pulse session is still alive.
#
# The pulse prompt asks the LLM to monitor every 60s, but the live session can
# still sleep or focus on a narrow thread while local slots sit idle. When the
# wrapper sees sustained idle/stall signals plus runnable work, it performs a
# bounded deterministic refill instead of waiting for the session to exit.
#
# Arguments:
#   $1 - last refill epoch (0 if never)
#   $2 - progress stall seconds
#   $3 - idle seconds
#   $4 - has_seen_progress (true/false)
#
# Returns: updated last refill epoch via stdout
#######################################
maybe_refill_underfilled_pool_during_active_pulse() {
	local last_refill_epoch="${1:-0}"
	local progress_stall_seconds="${2:-0}"
	local idle_seconds="${3:-0}"
	local has_seen_progress="${4:-false}"

	[[ "$last_refill_epoch" =~ ^[0-9]+$ ]] || last_refill_epoch=0
	[[ "$progress_stall_seconds" =~ ^[0-9]+$ ]] || progress_stall_seconds=0
	[[ "$idle_seconds" =~ ^[0-9]+$ ]] || idle_seconds=0
	[[ "$PULSE_ACTIVE_REFILL_INTERVAL" =~ ^[0-9]+$ ]] || PULSE_ACTIVE_REFILL_INTERVAL=120
	[[ "$PULSE_ACTIVE_REFILL_IDLE_MIN" =~ ^[0-9]+$ ]] || PULSE_ACTIVE_REFILL_IDLE_MIN=60
	[[ "$PULSE_ACTIVE_REFILL_STALL_MIN" =~ ^[0-9]+$ ]] || PULSE_ACTIVE_REFILL_STALL_MIN=120

	if [[ -f "$STOP_FLAG" || "$has_seen_progress" != "true" ]]; then
		echo "$last_refill_epoch"
		return 0
	fi

	if [[ "$idle_seconds" -lt "$PULSE_ACTIVE_REFILL_IDLE_MIN" && "$progress_stall_seconds" -lt "$PULSE_ACTIVE_REFILL_STALL_MIN" ]]; then
		echo "$last_refill_epoch"
		return 0
	fi

	local now_epoch
	now_epoch=$(date +%s)
	if [[ "$last_refill_epoch" -gt 0 ]]; then
		local since_last_refill=$((now_epoch - last_refill_epoch))
		if [[ "$since_last_refill" -lt "$PULSE_ACTIVE_REFILL_INTERVAL" ]]; then
			echo "$last_refill_epoch"
			return 0
		fi
	fi

	local max_workers active_workers runnable_count queued_without_worker
	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	runnable_count=$(normalize_count_output "$(count_runnable_candidates)")
	queued_without_worker=$(normalize_count_output "$(count_queued_without_worker)")
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0

	if [[ "$active_workers" -ge "$max_workers" || ("$runnable_count" -eq 0 && "$queued_without_worker" -eq 0) ]]; then
		echo "$last_refill_epoch"
		return 0
	fi

	echo "[pulse-wrapper] Active pulse refill: underfilled ${active_workers}/${max_workers} with runnable=${runnable_count}, queued_without_worker=${queued_without_worker}, idle=${idle_seconds}s, stall=${progress_stall_seconds}s" >>"$LOGFILE"
	run_underfill_worker_recycler "$max_workers" "$active_workers" "$runnable_count" "$queued_without_worker"
	dispatch_deterministic_fill_floor >/dev/null || true

	echo "$now_epoch"
	return 0
}

#######################################
# Main
#
# Execution order (t1429, GH#4513, GH#5628):
#   0. Instance lock (mkdir-based atomic — prevents concurrent pulses on macOS+Linux)
#   1. Gate checks (consent, dedup)
#   2. Cleanup (orphans, worktrees, stashes)
#   2.5. Daily complexity scan — .sh functions + .md agent docs (creates simplification-debt issues)
#   3. Prefetch state (parallel gh API calls)
#   4. Run pulse (LLM session — dispatch workers, merge PRs)
#
# Statistics (quality sweep, health issues, person-stats) run in a
# SEPARATE process — stats-wrapper.sh — on its own cron schedule.
# They must never share a process with the pulse because they depend
# on GitHub Search API (30 req/min limit). When budget is exhausted,
# contributor-activity-helper.sh bails out with partial results, but
# even the API calls themselves add latency that delays dispatch.
#######################################
#######################################
# Run pre-flight stages: cleanup, calculations, normalization (GH#5627)
#
# Returns: 0 if prefetch succeeded, 1 if prefetch failed (abort cycle)
#######################################
_run_preflight_stages() {
	# t1425, t1482: Write SETUP sentinel during pre-flight stages.
	echo "SETUP:$$" >"$PIDFILE"

	run_stage_with_timeout "cleanup_orphans" "$PRE_RUN_STAGE_TIMEOUT" cleanup_orphans || true
	run_stage_with_timeout "cleanup_stale_opencode" "$PRE_RUN_STAGE_TIMEOUT" cleanup_stale_opencode || true
	run_stage_with_timeout "cleanup_stalled_workers" "$PRE_RUN_STAGE_TIMEOUT" cleanup_stalled_workers || true
	run_stage_with_timeout "cleanup_worktrees" "$PRE_RUN_STAGE_TIMEOUT" cleanup_worktrees || true
	run_stage_with_timeout "cleanup_stashes" "$PRE_RUN_STAGE_TIMEOUT" cleanup_stashes || true

	# GH#17549: Archive old OpenCode sessions to keep the active DB small.
	# Concurrent workers hit SQLITE_BUSY on a bloated DB (busy_timeout=0).
	# Runs daily with a 30s budget — catches up over multiple pulse cycles.
	local _archive_helper="${SCRIPT_DIR}/opencode-db-archive.sh"
	if [[ -x "$_archive_helper" ]]; then
		"$_archive_helper" archive --max-duration-seconds 30 >>"$LOGFILE" 2>&1 || true
	fi

	# t1751: Reap zombie workers whose PRs have been merged by the deterministic merge pass.
	# Runs before worker counting so count_active_workers sees accurate slot availability.
	run_stage_with_timeout "reap_zombie_workers" "$PRE_RUN_STAGE_TIMEOUT" reap_zombie_workers || true

	# GH#6696: Expire stale in-flight ledger entries and prune old completed/failed ones.
	# This runs before worker counting so count_active_workers sees accurate ledger state.
	local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$_ledger_helper" ]]; then
		local expired_count
		expired_count=$("$_ledger_helper" expire 2>/dev/null) || expired_count=0
		"$_ledger_helper" prune >/dev/null 2>&1 || true
		if [[ "${expired_count:-0}" -gt 0 ]]; then
			echo "[pulse-wrapper] Dispatch ledger: expired ${expired_count} stale in-flight entries (GH#6696)" >>"$LOGFILE"
		fi
	fi

	calculate_max_workers
	calculate_priority_allocations
	local _session_ct
	_session_ct=$(check_session_count)
	if [[ "${_session_ct:-0}" -gt "$SESSION_COUNT_WARN" ]]; then
		echo "[pulse-wrapper] Session warning: $_session_ct interactive sessions open (threshold: $SESSION_COUNT_WARN). Each consumes 100-440MB + language servers. Consider closing unused tabs." >>"$LOGFILE"
	fi

	# Re-evaluate needs-consolidation labels before dispatch. Issues labeled
	# by an earlier (less precise) filter may no longer trigger under the
	# current filter. Auto-clearing here makes them dispatchable immediately
	# instead of stuck forever behind a label that list_dispatchable_issue_candidates_json
	# filters out (needs-* exclusion at line 6703).
	_reevaluate_consolidation_labels
	# t1982: Backfill pass for stuck needs-consolidation issues that never
	# got a consolidation-task child created (pre-t1982 dispatches just
	# labelled and returned). Dispatches a child retroactively so the
	# parent can actually be consolidated instead of sitting forever.
	_backfill_stale_consolidation_labels
	_reevaluate_simplification_labels

	# Early dispatch pass: fill available worker slots BEFORE heavy housekeeping.
	# Workers take 25-30s to cold-start (sandbox-exec + opencode), so dispatching
	# here lets them boot in parallel with the remaining housekeeping stages
	# (close_issues_with_merged_prs ~260s, prefetch_state ~130s, etc.).
	# The main fill floor at the end of the cycle catches any slots freed by
	# housekeeping. Without this, workers sit idle for ~7 minutes of cleanup.
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag present — skipping early fill floor" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Early fill floor: dispatching workers before housekeeping" >>"$LOGFILE"
		apply_deterministic_fill_floor
	fi

	# Routine comment responses: scan routine-tracking issues for unanswered
	# user comments and dispatch lightweight Haiku workers to respond.
	# Runs before heavy housekeeping so responses are fast.
	dispatch_routine_comment_responses || true

	# Daily complexity scan (GH#5628): creates simplification-debt issues
	# for .sh files with complex functions and .md agent docs exceeding size
	# threshold. Longest files first. Runs at most once per day.
	# Non-fatal — pulse proceeds even if the scan fails.
	run_stage_with_timeout "complexity_scan" "$PRE_RUN_STAGE_TIMEOUT" run_weekly_complexity_scan || true

	# Daily full codebase review via CodeRabbit (GH#17640): posts a review
	# trigger on issue #2632 once per 24h. Uses simple timestamp gate.
	# Non-fatal — pulse proceeds even if the review request fails.
	run_stage_with_timeout "coderabbit_review" "$PRE_RUN_STAGE_TIMEOUT" run_daily_codebase_review || true

	# Daily dedup cleanup: close duplicate simplification-debt issues.
	# Runs after complexity scan so any new duplicates from this cycle are caught.
	# Non-fatal — pulse proceeds even if cleanup fails.
	run_stage_with_timeout "dedup_cleanup" "$PRE_RUN_STAGE_TIMEOUT" run_simplification_dedup_cleanup || true

	# Prune expired fast-fail counter entries (t1888).
	# Lightweight — just reads and rewrites a small JSON file.
	fast_fail_prune_expired || true

	# Contribution watch: lightweight scan of external issues/PRs (t1419).
	prefetch_contribution_watch

	# Ensure active labels reflect ownership to prevent multi-worker overlap.
	run_stage_with_timeout "normalize_active_issue_assignments" "$PRE_RUN_STAGE_TIMEOUT" normalize_active_issue_assignments || true

	# Close issues whose linked PRs already merged (GH#16851).
	# The dedup guard blocks re-dispatch for these but they stay open forever.
	run_stage_with_timeout "close_issues_with_merged_prs" "$PRE_RUN_STAGE_TIMEOUT" close_issues_with_merged_prs || true

	# Reconcile status:done issues: close if merged PR exists, reset to
	# status:available if not (needs re-evaluation by a worker).
	run_stage_with_timeout "reconcile_stale_done_issues" "$PRE_RUN_STAGE_TIMEOUT" reconcile_stale_done_issues || true

	# Auto-approve maintainer issues: remove needs-maintainer-review when
	# the maintainer created or commented on the issue (GH#16842).
	run_stage_with_timeout "auto_approve_maintainer_issues" "$PRE_RUN_STAGE_TIMEOUT" auto_approve_maintainer_issues || true

	if ! run_stage_with_timeout "prefetch_state" "$PRE_RUN_STAGE_TIMEOUT" prefetch_state; then
		echo "[pulse-wrapper] prefetch_state did not complete successfully — aborting this cycle to avoid stale dispatch decisions" >>"$LOGFILE"
		_PULSE_HEALTH_PREFETCH_ERRORS=$((_PULSE_HEALTH_PREFETCH_ERRORS + 1))
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 1
	fi

	if [[ -f "$SCOPE_FILE" ]]; then
		local persisted_scope
		persisted_scope=$(cat "$SCOPE_FILE" 2>/dev/null || echo "")
		if [[ -n "$persisted_scope" ]]; then
			export PULSE_SCOPE_REPOS="$persisted_scope"
			echo "[pulse-wrapper] Restored PULSE_SCOPE_REPOS from ${SCOPE_FILE}" >>"$LOGFILE"
		fi
	fi

	return 0
}

#######################################
# Compute initial underfill state and run recycler (GH#5627)
#
# Outputs 2 lines: underfilled_mode, underfill_pct
#######################################
_compute_initial_underfill() {
	local max_workers active_workers underfilled_mode underfill_pct

	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	underfilled_mode=0
	underfill_pct=0
	if [[ "$active_workers" -lt "$max_workers" ]]; then
		underfilled_mode=1
		underfill_pct=$(((max_workers - active_workers) * 100 / max_workers))
	fi

	local runnable_count queued_without_worker
	runnable_count=$(normalize_count_output "$(count_runnable_candidates)")
	queued_without_worker=$(normalize_count_output "$(count_queued_without_worker)")
	run_underfill_worker_recycler "$max_workers" "$active_workers" "$runnable_count" "$queued_without_worker"

	# Re-check after recycler
	active_workers=$(count_active_workers)
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	if [[ "$active_workers" -lt "$max_workers" ]]; then
		underfilled_mode=1
		underfill_pct=$(((max_workers - active_workers) * 100 / max_workers))
	else
		underfilled_mode=0
		underfill_pct=0
	fi

	echo "$underfilled_mode"
	echo "$underfill_pct"
	return 0
}

#######################################
# Early-exit recycle loop (GH#5627, extracted from main)
#
# If the LLM exited quickly (<5 min) and the pool is still underfilled
# with runnable work, restart the pulse. Capped at PULSE_BACKFILL_MAX_ATTEMPTS.
#
# GH#6453: A grace-period wait is inserted before re-counting workers.
# Workers dispatched by the LLM pulse take several seconds to appear in
# list_active_worker_processes (sandbox-exec + opencode startup latency).
# Without this wait, count_active_workers() returns the pre-dispatch count,
# making the pool appear underfilled and triggering a second LLM pass that
# re-dispatches the same issues — doubling compute cost and causing branch
# conflicts. The wait duration is PULSE_LAUNCH_GRACE_SECONDS (default 20s).
#
# Arguments:
#   $1 - initial pulse_duration in seconds
#######################################
_run_early_exit_recycle_loop() {
	local pulse_duration="$1"
	local recycle_attempt=0

	while [[ "$recycle_attempt" -lt "$PULSE_BACKFILL_MAX_ATTEMPTS" ]]; do
		# Only recycle if the pulse ran for less than 5 minutes
		if [[ "$pulse_duration" -ge 300 ]]; then
			break
		fi

		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Stop flag set — skipping early-exit recycle" >>"$LOGFILE"
			break
		fi

		# GH#6453: Wait for newly-dispatched workers to appear in the process list
		# before re-counting. Workers dispatched by the LLM pulse take up to
		# PULSE_LAUNCH_GRACE_SECONDS to start (sandbox-exec + opencode startup).
		# Counting immediately after the LLM exits produces a false-negative
		# (workers running but not yet visible) that triggers duplicate dispatch.
		# t1887: LLM dispatch count is unknown here — use full grace to preserve
		# the GH#6453 safety guarantee.
		local grace_wait="$PULSE_LAUNCH_GRACE_SECONDS"
		[[ "$grace_wait" =~ ^[0-9]+$ ]] || grace_wait=35
		if [[ "$grace_wait" -gt 0 ]]; then
			echo "[pulse-wrapper] Early-exit recycle: waiting ${grace_wait}s for dispatched workers to appear (GH#6453)" >>"$LOGFILE"
			sleep "$grace_wait"
		fi

		# Re-check worker state
		local post_max post_active post_runnable post_queued
		post_max=$(get_max_workers_target)
		post_active=$(count_active_workers)
		post_runnable=$(normalize_count_output "$(count_runnable_candidates)")
		post_queued=$(normalize_count_output "$(count_queued_without_worker)")
		[[ "$post_max" =~ ^[0-9]+$ ]] || post_max=1
		[[ "$post_active" =~ ^[0-9]+$ ]] || post_active=0

		if [[ "$post_active" -ge "$post_max" ]]; then
			break
		fi
		if [[ "$post_runnable" -eq 0 && "$post_queued" -eq 0 ]]; then
			break
		fi
		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Early-exit recycle: stop flag appeared before deterministic fill" >>"$LOGFILE"
			break
		fi

		dispatch_deterministic_fill_floor >/dev/null || true
		post_active=$(count_active_workers)
		post_runnable=$(normalize_count_output "$(count_runnable_candidates)")
		post_queued=$(normalize_count_output "$(count_queued_without_worker)")
		[[ "$post_active" =~ ^[0-9]+$ ]] || post_active=0
		if [[ "$post_active" -ge "$post_max" ]]; then
			break
		fi
		if [[ "$post_runnable" -eq 0 && "$post_queued" -eq 0 ]]; then
			break
		fi

		local post_deficit_pct=$(((post_max - post_active) * 100 / post_max))
		recycle_attempt=$((recycle_attempt + 1))
		echo "[pulse-wrapper] Early-exit recycle attempt ${recycle_attempt}/${PULSE_BACKFILL_MAX_ATTEMPTS}: pulse ran ${pulse_duration}s (<300s), pool underfilled (active ${post_active}/${post_max}, deficit ${post_deficit_pct}%, runnable=${post_runnable}, queued=${post_queued})" >>"$LOGFILE"

		run_underfill_worker_recycler "$post_max" "$post_active" "$post_runnable" "$post_queued"

		if ! run_stage_with_timeout "prefetch_state" "$PRE_RUN_STAGE_TIMEOUT" prefetch_state; then
			echo "[pulse-wrapper] Early-exit recycle: prefetch_state failed — aborting recycle" >>"$LOGFILE"
			break
		fi

		# Recalculate underfill for the new pulse
		post_active=$(count_active_workers)
		[[ "$post_active" =~ ^[0-9]+$ ]] || post_active=0
		local recycle_underfilled_mode=0
		local recycle_underfill_pct=0
		if [[ "$post_active" -lt "$post_max" ]]; then
			recycle_underfilled_mode=1
			recycle_underfill_pct=$(((post_max - post_active) * 100 / post_max))
		fi

		local recycle_start_epoch
		recycle_start_epoch=$(date +%s)
		run_pulse "$recycle_underfilled_mode" "$recycle_underfill_pct"

		local recycle_end_epoch
		recycle_end_epoch=$(date +%s)
		pulse_duration=$((recycle_end_epoch - recycle_start_epoch))
	done

	if [[ "$recycle_attempt" -gt 0 ]]; then
		echo "[pulse-wrapper] Early-exit recycle completed after ${recycle_attempt} attempt(s)" >>"$LOGFILE"
	fi

	return 0
}
