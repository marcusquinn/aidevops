#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Contest Helper — Apply Sub-Library
# =============================================================================
# Apply contest winner, record results in pattern-tracker and response-scoring
# DB for permanent routing data.
#
# Usage: source "${SCRIPT_DIR}/contest-helper-apply.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - contest-helper.sh orchestrator (db, sql_escape, ensure_contest_tables, log_*)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CONTEST_APPLY_LIB_LOADED:-}" ]] && return 0
_CONTEST_APPLY_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

#######################################
# Record contest results in pattern-tracker (t1011)
# Stores success/failure patterns for each model's performance
#######################################
_record_contest_patterns() {
	local contest_id="$1"
	local pattern_helper="${SCRIPT_DIR}/archived/pattern-tracker-helper.sh"

	if [[ ! -x "$pattern_helper" ]]; then
		log_warn "Pattern tracker not available — skipping pattern recording"
		return 0
	fi

	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	local contest_task
	contest_task=$(db "$SUPERVISOR_DB" "SELECT task_id FROM contests WHERE id = '$escaped_cid';")
	local winner_model
	winner_model=$(db "$SUPERVISOR_DB" "SELECT winner_model FROM contests WHERE id = '$escaped_cid';")

	# Record each entry's result
	local entries
	entries=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT model, weighted_score, status
		FROM contest_entries
		WHERE contest_id = '$escaped_cid';
	")

	while IFS=$'\t' read -r emodel escore estatus; do
		[[ -z "$emodel" ]] && continue

		local outcome="success"
		if [[ "$estatus" == "failed" ]]; then
			outcome="failure"
		fi

		"$pattern_helper" record \
			--outcome "$outcome" \
			--description "Contest $contest_id: model $emodel scored $escore (winner: $winner_model)" \
			--model "$emodel" \
			--task-id "$contest_task" \
			--tags "contest,cross-rank" 2>/dev/null || true
	done <<<"$entries"

	log_info "Recorded contest patterns for $contest_id"
	return 0
}

#######################################
# Record contest results in response-scoring DB (t1011)
# Creates prompt + responses + scores for permanent comparison data
#######################################
_record_contest_scores() {
	local contest_id="$1"
	local scoring_helper="${SCRIPT_DIR}/response-scoring-helper.sh"

	if [[ ! -x "$scoring_helper" ]]; then
		log_warn "Response scoring helper not available — skipping score recording"
		return 0
	fi

	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	# Get contest details
	local contest_desc
	contest_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM contests WHERE id = '$escaped_cid';")

	# Create a prompt in the scoring DB
	local prompt_id
	prompt_id=$("$scoring_helper" prompt add \
		--title "Contest: $contest_id" \
		--text "$contest_desc" \
		--category "contest" \
		--difficulty "medium" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "")

	if [[ -z "$prompt_id" ]]; then
		log_warn "Failed to create scoring prompt — skipping score recording"
		return 0
	fi

	# Record each entry as a response with scores
	local entries
	entries=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT model, output_summary, score_correctness, score_completeness,
			   score_code_quality, score_clarity, weighted_score
		FROM contest_entries
		WHERE contest_id = '$escaped_cid' AND status = 'complete';
	")

	while IFS=$'\t' read -r emodel esummary ecorrect ecomplete equality eclarity _eweighted; do
		[[ -z "$emodel" ]] && continue

		# Reset IFS to default before $() calls — prevents zsh IFS leak corrupting PATH lookup
		local response_id _saved_ifs="$IFS"
		IFS=$' \t\n'
		response_id=$("$scoring_helper" record \
			--prompt "$prompt_id" \
			--model "$emodel" \
			--text "${esummary:-No output}" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "")

		IFS="$_saved_ifs"
		if [[ -n "$response_id" ]]; then
			# Record scores (convert float to int for the 1-5 scale)
			local int_correct int_complete int_quality int_clarity
			int_correct=$(printf '%.0f' "${ecorrect:-0}" 2>/dev/null || echo "3")
			int_complete=$(printf '%.0f' "${ecomplete:-0}" 2>/dev/null || echo "3")
			int_quality=$(printf '%.0f' "${equality:-0}" 2>/dev/null || echo "3")
			int_clarity=$(printf '%.0f' "${eclarity:-0}" 2>/dev/null || echo "3")

			# Clamp to 1-5 range
			for var in int_correct int_complete int_quality int_clarity; do
				local val="${!var}"
				[[ "$val" -lt 1 ]] && printf -v "$var" '%d' 1
				[[ "$val" -gt 5 ]] && printf -v "$var" '%d' 5
			done

			"$scoring_helper" score \
				--response "$response_id" \
				--correctness "$int_correct" \
				--completeness "$int_complete" \
				--code-quality "$int_quality" \
				--clarity "$int_clarity" \
				--scored-by "contest-cross-rank" 2>/dev/null || true
		fi
	done <<<"$entries"

	log_info "Recorded contest scores in response-scoring DB"
	return 0
}

#######################################
# Apply the winning contest entry's output
# Merges the winner's branch/PR and cleans up losers
#######################################
cmd_apply() {
	local contest_id="${1:-}"
	if [[ -z "$contest_id" ]]; then
		log_error "Usage: contest-helper.sh apply <contest_id>"
		return 1
	fi

	ensure_contest_tables || return 1

	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	# Verify contest is complete
	local contest_row
	contest_row=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT status, winner_entry_id, winner_model, task_id
		FROM contests WHERE id = '$escaped_cid';
	")

	if [[ -z "$contest_row" ]]; then
		log_error "Contest not found: $contest_id"
		return 1
	fi

	local cstatus cwinner_entry cwinner_model ctask_id
	IFS=$'\t' read -r cstatus cwinner_entry cwinner_model ctask_id <<<"$contest_row"

	if [[ "$cstatus" != "complete" ]]; then
		log_error "Contest $contest_id is in '$cstatus' state, must be 'complete' to apply"
		return 1
	fi

	if [[ -z "$cwinner_entry" ]]; then
		log_error "No winner entry for contest $contest_id"
		return 1
	fi

	# Get winner's PR URL
	local winner_pr
	winner_pr=$(db "$SUPERVISOR_DB" "
		SELECT pr_url FROM contest_entries
		WHERE id = '$(sql_escape "$cwinner_entry")';
	")

	if [[ -n "$winner_pr" && "$winner_pr" != "no_pr" && "$winner_pr" != "task_only" ]]; then
		log_info "Winner PR: $winner_pr — promoting to the original task"

		# Update the original task's PR URL to point to the winner's PR
		db "$SUPERVISOR_DB" "
			UPDATE tasks SET
				pr_url = '$(sql_escape "$winner_pr")',
				model = '$(sql_escape "$cwinner_model")',
				error = 'Contest winner: $contest_id (model: $cwinner_model)'
			WHERE id = '$(sql_escape "$ctask_id")';
		"
	else
		log_warn "Winner has no PR — checking worktree for direct application"
		local winner_wt
		winner_wt=$(db "$SUPERVISOR_DB" "
			SELECT worktree FROM contest_entries
			WHERE id = '$(sql_escape "$cwinner_entry")';
		")

		if [[ -n "$winner_wt" && -d "$winner_wt" ]]; then
			log_info "Winner worktree: $winner_wt"
			# The supervisor's normal PR lifecycle will handle this
			db "$SUPERVISOR_DB" "
				UPDATE tasks SET
					worktree = '$(sql_escape "$winner_wt")',
					model = '$(sql_escape "$cwinner_model")',
					error = 'Contest winner: $contest_id (model: $cwinner_model)'
				WHERE id = '$(sql_escape "$ctask_id")';
			"
		fi
	fi

	# Cancel losing entries' tasks
	local losers
	losers=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT task_id, worktree FROM contest_entries
		WHERE contest_id = '$escaped_cid'
		AND id != '$(sql_escape "$cwinner_entry")'
		AND status = 'complete';
	")

	while IFS=$'\t' read -r loser_task _loser_wt; do
		[[ -z "$loser_task" ]] && continue
		log_info "Cancelling losing entry task: $loser_task"
		"${SCRIPT_DIR}/pulse-wrapper.sh" cancel "$loser_task" 2>/dev/null || true
	done <<<"$losers"

	log_success "Applied contest winner: $cwinner_model for task $ctask_id"
	return 0
}
