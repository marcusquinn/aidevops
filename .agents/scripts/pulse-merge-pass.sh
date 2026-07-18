#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-merge-pass.sh — Deterministic merge-pass checkpoint orchestration
# =============================================================================
# Provides checkpoint, PR cursor, graceful-budget, and all-repository pass
# helpers for pulse-merge-process.sh.
#
# Usage: source "${SCRIPT_DIR}/pulse-merge-pass.sh"
# Part of aidevops framework: https://aidevops.sh

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_MERGE_PASS_LOADED:-}" ]] && return 0
_PULSE_MERGE_PASS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_pmp_pass_path="${BASH_SOURCE[0]%/*}"
	[[ "$_pmp_pass_path" == "${BASH_SOURCE[0]}" ]] && _pmp_pass_path="."
	SCRIPT_DIR="$(cd "$_pmp_pass_path" && pwd)"
	unset _pmp_pass_path
fi

_pmp_write_merge_checkpoint() {
	local checkpoint_file="$1"
	local repo_slug="$2"
	local checkpoint_dir=""

	[[ -n "$checkpoint_file" && -n "$repo_slug" ]] || return 0
	checkpoint_dir="${checkpoint_file%/*}"
	if [[ -n "$checkpoint_dir" && "$checkpoint_dir" != "$checkpoint_file" ]]; then
		mkdir -p "$checkpoint_dir" 2>/dev/null || return 0
	fi
	printf '%s\n' "$repo_slug" >"$checkpoint_file" 2>/dev/null || true
	return 0
}

_pmp_clear_merge_checkpoint() {
	local checkpoint_file="$1"

	[[ -n "$checkpoint_file" ]] || return 0
	rm -f "$checkpoint_file" 2>/dev/null || true
	return 0
}

_pmp_clear_merge_pr_cursor() {
	local cursor_file="$1"

	[[ -n "$cursor_file" ]] || return 0
	rm -f "$cursor_file" 2>/dev/null || true
	return 0
}

_pmp_write_merge_pr_cursor() {
	local cursor_file="$1"
	local repo_slug="$2"
	local next_index="$3"
	local last_pr_number="$4"
	local next_pr_number="$5"

	[[ -n "$cursor_file" && -n "$repo_slug" ]] || return 0
	[[ "$next_index" =~ ^[0-9]+$ ]] || next_index=0
	printf '%s|%s|%s|%s\n' "$repo_slug" "$next_index" "$last_pr_number" "$next_pr_number" >"$cursor_file" 2>/dev/null || true
	return 0
}

_pmp_read_merge_pr_cursor_last() {
	local cursor_file="$1"
	local repo_slug="$2"
	local last_pr_var="$3"
	local cursor_repo="" cursor_next_index="" cursor_last_pr="" cursor_next_pr=""

	[[ "$last_pr_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	if [[ -n "$cursor_file" && -f "$cursor_file" ]]; then
		IFS='|' read -r cursor_repo cursor_next_index cursor_last_pr cursor_next_pr <"$cursor_file" || true
		if [[ "$cursor_repo" == "$repo_slug" ]]; then
			printf -v "$last_pr_var" '%s' "$cursor_last_pr"
			return 0
		fi
	fi
	printf -v "$last_pr_var" '%s' ''
	return 0
}

_pmp_pr_cursor_index_for_number() {
	local pr_json="$1"
	local pr_number="$2"

	[[ -n "$pr_number" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$pr_json" | jq --argjson pr_number "$pr_number" 'map(.number == $pr_number) | index(true) // empty' 2>/dev/null
	return 0
}

_pmp_pr_object_at_index() {
	local pr_json="$1"
	local pr_index="$2"

	[[ "$pr_index" =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$pr_json" | jq -c --argjson pr_index "$pr_index" '.[$pr_index]' 2>/dev/null
	return 0
}

_pmp_pr_number_at_index() {
	local pr_json="$1"
	local pr_index="$2"

	[[ "$pr_index" =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$pr_json" | jq -r --argjson pr_index "$pr_index" '.[$pr_index].number // empty' 2>/dev/null
	return 0
}

_pmp_prepare_merge_pr_cursor_resume() {
	local repo_slug="$1"
	local pr_json="$2"
	local pr_count="$3"
	local cursor_file="$4"
	local logfile="$5"
	local start_index_var="$6"
	local cursor_repo="" cursor_next_index="" cursor_last_pr="" cursor_next_pr=""
	local start_index=0 located_index=""

	[[ "$start_index_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0

	if [[ -n "$cursor_file" && -f "$cursor_file" ]]; then
		IFS='|' read -r cursor_repo cursor_next_index cursor_last_pr cursor_next_pr <"$cursor_file" || true
		if [[ "$cursor_repo" == "$repo_slug" ]]; then
			located_index=$(_pmp_pr_cursor_index_for_number "$pr_json" "$cursor_next_pr") || located_index=""
			if [[ "$located_index" =~ ^[0-9]+$ ]]; then
				start_index="$located_index"
			else
				located_index=$(_pmp_pr_cursor_index_for_number "$pr_json" "$cursor_last_pr") || located_index=""
				if [[ "$located_index" =~ ^[0-9]+$ ]]; then
					start_index=$((located_index + 1))
				elif [[ "$cursor_next_index" =~ ^[0-9]+$ ]]; then
					start_index="$cursor_next_index"
				fi
			fi
			if [[ "$start_index" -ge "$pr_count" ]]; then
				_pmp_clear_merge_pr_cursor "$cursor_file"
				start_index=0
			else
				echo "[pulse-wrapper] Merge pass: resuming ${repo_slug} at PR cursor index=${start_index} last_pr=${cursor_last_pr:-none} next_pr=${cursor_next_pr:-none}" >>"$logfile"
			fi
		elif [[ -n "$cursor_repo" ]]; then
			echo "[pulse-wrapper] Merge pass: ignoring stale PR cursor repo=${cursor_repo} while processing ${repo_slug}" >>"$logfile"
			_pmp_clear_merge_pr_cursor "$cursor_file"
		fi
	fi

	printf -v "$start_index_var" '%s' "$start_index"
	return 0
}

_pmp_merge_pass_budget_deadline() {
	local pass_start="$1"
	local budget_seconds="${PULSE_MERGE_GRACEFUL_BUDGET_SECONDS:-}"
	local ceiling_seconds="${PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS:-${PRE_RUN_STAGE_TIMEOUT:-0}}"
	local reserve_seconds="${PULSE_MERGE_GRACEFUL_BUDGET_RESERVE_SECONDS:-45}"

	[[ "$pass_start" =~ ^[0-9]+$ ]] || pass_start=0
	[[ "$reserve_seconds" =~ ^[0-9]+$ ]] || reserve_seconds=45
	if [[ -z "$budget_seconds" ]]; then
		[[ "$ceiling_seconds" =~ ^[0-9]+$ ]] || ceiling_seconds=0
		if [[ "$ceiling_seconds" -gt "$reserve_seconds" ]]; then
			budget_seconds=$((ceiling_seconds - reserve_seconds))
		else
			budget_seconds=0
		fi
	fi
	[[ "$budget_seconds" =~ ^[0-9]+$ ]] || budget_seconds=0
	if [[ "$budget_seconds" -gt 0 && "$pass_start" -gt 0 ]]; then
		printf '%s' "$((pass_start + budget_seconds))"
	else
		printf '0'
	fi
	return 0
}

_pmp_merge_pass_budget_exhausted() {
	local deadline_epoch="${_PMP_MERGE_PASS_DEADLINE_EPOCH:-0}"
	local now_epoch=""

	[[ "$deadline_epoch" =~ ^[0-9]+$ ]] || deadline_epoch=0
	[[ "$deadline_epoch" -gt 0 ]] || return 1
	now_epoch=$(_pmp_now_epoch)
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0
	[[ "$now_epoch" -ge "$deadline_epoch" ]] || return 1
	return 0
}

_pmp_pause_merge_pr_cursor() {
	local repo_slug="$1"
	local pr_json="$2"
	local cursor_index="$3"
	local pause_reason="$4"
	local merged_var="$5"
	local closed_var="$6"
	local failed_var="$7"
	local merged_count="$8"
	local closed_count="$9"
	local failed_count="${10}"
	local required_contexts_cache_dir="${11:-}"
	local author_permission_cache_dir="${12:-}"
	local next_pr="" last_pr=""
	local cursor_file="${PULSE_MERGE_PR_CURSOR_FILE:-}"
	local logfile="${LOGFILE:-/dev/null}"

	next_pr=$(_pmp_pr_number_at_index "$pr_json" "$cursor_index") || next_pr=""
	_pmp_read_merge_pr_cursor_last "$cursor_file" "$repo_slug" last_pr || last_pr=""
	_pmp_write_merge_pr_cursor "$cursor_file" "$repo_slug" "$cursor_index" "$last_pr" "$next_pr"
	case "$pause_reason" in
	budget)
		echo "[pulse-wrapper] Merge pass: graceful time budget exhausted for ${repo_slug}; pausing at PR cursor index=${cursor_index} next_pr=${next_pr:-none}" >>"$logfile"
		;;
	cooldown)
		echo "[pulse-wrapper] Merge pass: GitHub cooldown active for ${repo_slug}; pausing remaining PR processing" >>"$logfile"
		;;
	stop) ;;
	esac
	eval "${merged_var}=${merged_count}; ${closed_var}=${closed_count}; ${failed_var}=${failed_count}"
	[[ -n "$required_contexts_cache_dir" ]] && rm -rf -- "$required_contexts_cache_dir"
	[[ -n "$author_permission_cache_dir" ]] && rm -rf -- "$author_permission_cache_dir"
	return 5
}

_pmp_repo_rows_contain_slug() {
	local repo_rows="$1"
	local checkpoint_slug="$2"
	local row_slug="" row_path=""

	[[ -n "$repo_rows" && -n "$checkpoint_slug" ]] || return 1
	while IFS='|' read -r row_slug row_path; do
		[[ -n "$row_slug" ]] || continue
		if [[ "$row_slug" == "$checkpoint_slug" ]]; then
			return 0
		fi
	done <<<"$repo_rows"
	return 1
}

_pmp_prepare_merge_checkpoint_resume() {
	local repo_rows="$1"
	local checkpoint_file="$2"
	local logfile="$3"
	local checkpoint_var="$4"
	local resume_pending_var="$5"
	local resumed_var="$6"
	local checkpoint=""
	local resume_pending=0
	local resumed=0

	[[ "$checkpoint_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	[[ "$resume_pending_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	[[ "$resumed_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1

	if [[ -n "$checkpoint_file" && -f "$checkpoint_file" ]]; then
		IFS= read -r checkpoint <"$checkpoint_file" || [[ -n "$checkpoint" ]] || true
		if [[ -n "$checkpoint" ]]; then
			if _pmp_repo_rows_contain_slug "$repo_rows" "$checkpoint"; then
				resume_pending=1
				resumed=1
				echo "[pulse-wrapper] Deterministic merge pass resuming after checkpoint repo=${checkpoint}" >>"$logfile"
			else
				echo "[pulse-wrapper] Deterministic merge pass ignoring stale checkpoint repo=${checkpoint}" >>"$logfile"
				_pmp_clear_merge_checkpoint "$checkpoint_file"
				checkpoint=""
			fi
		fi
	fi

	printf -v "$checkpoint_var" '%s' "$checkpoint"
	printf -v "$resume_pending_var" '%s' "$resume_pending"
	printf -v "$resumed_var" '%s' "$resumed"
	return 0
}

_pmp_checkpoint_resume_skip_repo() {
	local repo_slug="$1"
	local checkpoint="$2"
	local resume_pending_var="$3"
	local resume_pending=""

	[[ "$resume_pending_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	resume_pending="${!resume_pending_var:-}"
	[[ "$resume_pending" -eq 1 ]] || return 1
	if [[ "$repo_slug" == "$checkpoint" ]]; then
		printf -v "$resume_pending_var" '%s' '0'
	fi
	return 0
}

_pmp_add_counter_var() {
	local counter_var="$1"
	local increment="${2:-0}"
	local current=""

	[[ "$counter_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	current="${!counter_var:-}"
	[[ "$current" =~ ^[0-9]+$ ]] || current=0
	[[ "$increment" =~ ^[0-9]+$ ]] || increment=0
	printf -v "$counter_var" '%s' "$((current + increment))"
	return 0
}

_pmp_process_merge_repo_for_pass() {
	local repo_slug="$1"
	local checkpoint_file="$2"
	local logfile="$3"
	local stop_flag="$4"
	local total_merged_var="$5"
	local total_closed_var="$6"
	local total_failed_var="$7"
	local total_eligible_var="$8"
	local completed_all_var="$9"

	if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 \
		|| ! repo_allows_pulse_write_actions "$repo_slug"; then
		echo "[pulse-wrapper] Deterministic merge pass skipped ${repo_slug}: repo role is contributor/read-only" >>"$logfile"
		_pmp_write_merge_checkpoint "$checkpoint_file" "$repo_slug"
		return 0
	fi

	local repo_merged=0 repo_closed=0 repo_failed=0 _mr_repo_pr_count=0
	local _mr_repo_list_s=0 _mr_repo_mergeability_s=0 _mr_repo_ruleset_s=0 _mr_repo_branch_protection_s=0 _mr_repo_stuck_detector_s=0
	local _mr_repo_start _mr_repo_stuck_start _mr_repo_total_s=0
	_mr_repo_start=$(_pmp_now_epoch)

	local _mr_repo_rc=0
	_merge_ready_prs_for_repo "$repo_slug" repo_merged repo_closed repo_failed _mr_repo_pr_count "_mr_repo_" || _mr_repo_rc=$?
	_pmp_add_counter_var "$total_merged_var" "$repo_merged"
	_pmp_add_counter_var "$total_closed_var" "$repo_closed"
	_pmp_add_counter_var "$total_failed_var" "$repo_failed"
	if [[ "$_mr_repo_rc" -eq 5 ]]; then
		echo "[pulse-wrapper] Deterministic merge pass paused mid-repo ${repo_slug}; PR cursor persisted" >>"$logfile"
		printf -v "$completed_all_var" '%s' '0'
		return 0
	fi

	_mr_repo_stuck_start=$(_pmp_now_epoch)
	if declare -F pulse_merge_stuck_run_pass >/dev/null 2>&1; then
		pulse_merge_stuck_run_pass "$repo_slug" || true
	fi
	if declare -F _pms_count_eligible_unmerged_for_repo >/dev/null 2>&1; then
		local _repo_eligible
		_repo_eligible=$(_pms_count_eligible_unmerged_for_repo "$repo_slug" 2>/dev/null) || _repo_eligible=0
		[[ "$_repo_eligible" =~ ^[0-9]+$ ]] || _repo_eligible=0
		_pmp_add_counter_var "$total_eligible_var" "$_repo_eligible"
	fi

	_pmp_add_elapsed_seconds _mr_repo_stuck_detector_s "$_mr_repo_stuck_start"
	_pmp_add_elapsed_seconds _mr_repo_total_s "$_mr_repo_start"
	_pmp_log_repo_timing_summary "$repo_slug" "$_mr_repo_total_s" "$_mr_repo_list_s" "$_mr_repo_mergeability_s" "$_mr_repo_ruleset_s" "$_mr_repo_branch_protection_s" "$_mr_repo_stuck_detector_s" "$repo_merged" "$repo_closed" "$repo_failed" "$_mr_repo_pr_count"
	_pmp_write_merge_checkpoint "$checkpoint_file" "$repo_slug"
	_pmp_clear_merge_pr_cursor "${PULSE_MERGE_PR_CURSOR_FILE:-}"

	if [[ -f "$stop_flag" ]]; then
		echo "[pulse-wrapper] Deterministic merge pass: stop flag appeared mid-run" >>"$logfile"
		printf -v "$completed_all_var" '%s' '0'
	fi
	return 0
}

merge_ready_prs_all_repos() {
	# Initialise required env vars with ${VAR:-default} guards so this
	# function can be called standalone from pulse-merge-routine.sh (t2862)
	# without relying on pulse-wrapper.sh having set them in the bootstrap.
	# When called from pulse-wrapper.sh the pre-existing values are kept.
	local _mr_stop_flag="${STOP_FLAG:-${HOME}/.aidevops/logs/pulse-session.stop}"
	local _mr_repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local _mr_logfile="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
	local _mr_checkpoint_file="${PULSE_MERGE_CHECKPOINT_FILE:-${HOME}/.aidevops/logs/pulse-merge-checkpoint}"
	PULSE_MERGE_PR_CURSOR_FILE="${PULSE_MERGE_PR_CURSOR_FILE:-${_mr_checkpoint_file}.pr-cursor}"
	PULSE_MERGE_BATCH_LIMIT="${PULSE_MERGE_BATCH_LIMIT:-50}"
	local _mr_pass_start
	_mr_pass_start=$(_pmp_now_epoch)
	_PMP_MERGE_PASS_DEADLINE_EPOCH=$(_pmp_merge_pass_budget_deadline "$_mr_pass_start")

	if [[ -f "$_mr_stop_flag" ]]; then
		echo "[pulse-wrapper] Deterministic merge pass skipped: stop flag present" >>"$_mr_logfile"
		return 0
	fi

	if [[ ! -f "$_mr_repos_json" ]]; then
		echo "[pulse-wrapper] Deterministic merge pass skipped: repos.json not found" >>"$_mr_logfile"
		return 0
	fi

	local total_merged=0
	local total_closed=0
	local total_failed=0

	local total_eligible_unmerged=0
	local _mr_repo_rows=""
	local _mr_checkpoint=""
	local _mr_resume_pending=0
	local _mr_resumed_from_checkpoint=0
	local _mr_completed_all=1
	local repo_slug="" repo_path=""

	_mr_repo_rows=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | [.slug, .path] | join("|")' "$_mr_repos_json" 2>/dev/null) || _mr_repo_rows=""
	_pmp_prepare_merge_checkpoint_resume "$_mr_repo_rows" "$_mr_checkpoint_file" "$_mr_logfile" \
		_mr_checkpoint _mr_resume_pending _mr_resumed_from_checkpoint || true

	while IFS='|' read -r repo_slug repo_path; do
		[[ -n "$repo_slug" ]] || continue
		if _pmp_checkpoint_resume_skip_repo "$repo_slug" "$_mr_checkpoint" _mr_resume_pending; then
			continue
		fi
		_pmp_process_merge_repo_for_pass "$repo_slug" "$_mr_checkpoint_file" "$_mr_logfile" "$_mr_stop_flag" \
			total_merged total_closed total_failed total_eligible_unmerged _mr_completed_all
		if [[ "$_mr_completed_all" -eq 0 ]]; then
			break
		fi
	done <<<"$_mr_repo_rows"

	if [[ "$_mr_completed_all" -eq 1 ]]; then
		_pmp_clear_merge_checkpoint "$_mr_checkpoint_file"
		_pmp_clear_merge_pr_cursor "$PULSE_MERGE_PR_CURSOR_FILE"
	fi

	# t3193: positive deterministic progress is conclusive even when a pass pauses
	# or resumes from a checkpoint, so reset the streak immediately after a merge
	# or conflict close. A no-progress aggregate is meaningful only after a fresh
	# full pass; partial tails skip it to avoid distorting the all-repo signal.
	# Resolves at runtime via bash lazy lookup (pulse-merge-stuck.sh).
	if declare -F pulse_merge_zero_progress_record >/dev/null 2>&1; then
		if [[ "$total_merged" -gt 0 || "$total_closed" -gt 0 ]]; then
			pulse_merge_zero_progress_record "$total_eligible_unmerged" "$total_merged" "$total_closed" || true
		elif [[ "$_mr_completed_all" -eq 1 && "$_mr_resumed_from_checkpoint" -eq 0 ]]; then
			pulse_merge_zero_progress_record "$total_eligible_unmerged" "$total_merged" "$total_closed" || true
		fi
	fi

	echo "[pulse-wrapper] Deterministic merge pass complete: merged=${total_merged}, closed_conflicting=${total_closed}, failed=${total_failed}, eligible_unmerged=${total_eligible_unmerged}" >>"$_mr_logfile"
	# Write health counter deltas to a temp file (GH#18571, GH#15107).
	# run_stage_with_timeout backgrounds this function in a subshell, so
	# direct updates to _PULSE_HEALTH_* variables are lost on return.
	# The parent process reads this file after the stage completes.
	local _health_delta_file="${TMPDIR:-/tmp}/pulse-health-merge-$$.tmp"
	printf '%s %s\n' "$total_merged" "$total_closed" >"$_health_delta_file" || true
	local _mr_pass_total_s=0
	_pmp_add_elapsed_seconds _mr_pass_total_s "$_mr_pass_start"
	echo "[pulse-wrapper] deterministic_merge_pass timing: total_s=${_mr_pass_total_s} merged=${total_merged} closed_conflicting=${total_closed} failed=${total_failed} eligible_unmerged=${total_eligible_unmerged}" >>"$_mr_logfile"
	return 0
}
