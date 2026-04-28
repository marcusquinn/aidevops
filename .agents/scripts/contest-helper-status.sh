#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Contest Helper — Status Sub-Library
# =============================================================================
# Contest status display, listing, pulse-check integration, and entry status
# synchronisation from supervisor subtasks.
#
# Usage: source "${SCRIPT_DIR}/contest-helper-status.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - contest-helper.sh orchestrator (db, sql_escape, ensure_contest_tables, log_*)
#   - contest-helper-evaluate.sh (cmd_evaluate — called by cmd_pulse_check)
#   - contest-helper-apply.sh (cmd_apply — called by cmd_pulse_check)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CONTEST_STATUS_LIB_LOADED:-}" ]] && return 0
_CONTEST_STATUS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

#######################################
# Check contest status — are all entries complete?
#######################################
cmd_status() {
	local contest_id="${1:-}"
	if [[ -z "$contest_id" ]]; then
		log_error "Usage: contest-helper.sh status <contest_id>"
		return 1
	fi

	ensure_contest_tables || return 1

	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	local contest_row
	contest_row=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT task_id, status, winner_model, winner_score, models, created_at
		FROM contests WHERE id = '$escaped_cid';
	")

	if [[ -z "$contest_row" ]]; then
		log_error "Contest not found: $contest_id"
		return 1
	fi

	local ctask_id cstatus cwinner cscore cmodels ccreated
	IFS=$'\t' read -r ctask_id cstatus cwinner cscore cmodels ccreated <<<"$contest_row"

	echo -e "${BOLD}Contest: $contest_id${NC}"
	echo "  Task:     $ctask_id"
	echo "  Status:   $cstatus"
	echo "  Models:   $cmodels"
	echo "  Created:  $ccreated"
	if [[ -n "$cwinner" ]]; then
		echo -e "  Winner:   ${GREEN}$cwinner${NC} (score: $cscore)"
	fi

	# Show entries
	echo ""
	echo -e "${BOLD}Entries:${NC}"
	local entries
	entries=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, model, status, weighted_score, task_id
		FROM contest_entries
		WHERE contest_id = '$escaped_cid'
		ORDER BY weighted_score DESC;
	")

	while IFS=$'\t' read -r eid emodel estatus escore etask; do
		[[ -z "$eid" ]] && continue
		local status_color="$NC"
		case "$estatus" in
		complete) status_color="$GREEN" ;;
		running | dispatched) status_color="$BLUE" ;;
		failed) status_color="$RED" ;;
		esac
		printf "  %-40s %-30s ${status_color}%-12s${NC} score: %.2f  task: %s\n" \
			"$eid" "$emodel" "$estatus" "${escore:-0}" "$etask"
	done <<<"$entries"

	return 0
}

#######################################
# List contests
#######################################
cmd_list() {
	local filter=""
	local _opt
	while [[ $# -gt 0 ]]; do
		_opt="$1"
		case "$_opt" in
		--active)
			filter="AND status NOT IN ('complete','failed','cancelled')"
			shift
			;;
		--completed)
			filter="AND status = 'complete'"
			shift
			;;
		*) shift ;;
		esac
	done

	ensure_contest_tables || return 1

	local contests
	contests=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, task_id, status, winner_model, winner_score, models, created_at
		FROM contests
		WHERE 1=1 $filter
		ORDER BY created_at DESC;
	")

	if [[ -z "$contests" ]]; then
		echo "No contests found"
		return 0
	fi

	printf "${BOLD}%-40s %-12s %-12s %-25s %-8s %s${NC}\n" \
		"CONTEST" "TASK" "STATUS" "WINNER" "SCORE" "CREATED"

	while IFS=$'\t' read -r cid ctask cstatus cwinner cscore cmodels ccreated; do
		[[ -z "$cid" ]] && continue
		local status_color="$NC"
		case "$cstatus" in
		complete) status_color="$GREEN" ;;
		running | evaluating | scoring) status_color="$BLUE" ;;
		failed) status_color="$RED" ;;
		esac
		printf "%-40s %-12s ${status_color}%-12s${NC} %-25s %-8s %s\n" \
			"$cid" "$ctask" "$cstatus" "${cwinner:-—}" "${cscore:-—}" "$ccreated"
	done <<<"$contests"

	return 0
}

#######################################
# Check running contests and evaluate completed ones (for pulse integration)
# Returns: number of contests that were evaluated
#######################################
cmd_pulse_check() {
	ensure_contest_tables || return 1

	local evaluated=0

	# Find running contests where all entries are done
	local running_contests
	running_contests=$(db "$SUPERVISOR_DB" "
		SELECT c.id FROM contests c
		WHERE c.status = 'running'
		AND (
			SELECT count(*) FROM contest_entries ce
			WHERE ce.contest_id = c.id
			AND ce.status NOT IN ('complete','failed','cancelled')
		) = 0;
	")

	while IFS= read -r contest_id; do
		[[ -z "$contest_id" ]] && continue

		# Sync entry statuses from their subtasks
		_sync_entry_statuses "$contest_id"

		# Re-check after sync
		local still_pending
		still_pending=$(db "$SUPERVISOR_DB" "
			SELECT count(*) FROM contest_entries
			WHERE contest_id = '$(sql_escape "$contest_id")'
			AND status NOT IN ('complete','failed','cancelled');
		")

		if [[ "$still_pending" -eq 0 ]]; then
			log_info "Contest $contest_id ready for evaluation"
			if cmd_evaluate "$contest_id"; then
				cmd_apply "$contest_id" || true
				evaluated=$((evaluated + 1))
			fi
		fi
	done <<<"$running_contests"

	echo "$evaluated"
	return 0
}

#######################################
# Sync contest entry statuses from their supervisor subtasks
#######################################
_sync_entry_statuses() {
	local contest_id="$1"
	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	local entries
	entries=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT ce.id, ce.task_id, ce.status
		FROM contest_entries ce
		WHERE ce.contest_id = '$escaped_cid'
		AND ce.status NOT IN ('complete','failed','cancelled');
	")

	while IFS=$'\t' read -r eid etask estatus; do
		[[ -z "$eid" ]] && continue

		# Check the subtask's status in the supervisor DB
		local task_status
		task_status=$(db "$SUPERVISOR_DB" "
			SELECT status FROM tasks WHERE id = '$(sql_escape "$etask")';
		" 2>/dev/null || echo "")

		case "$task_status" in
		complete | pr_review | merging | merged | deploying | deployed | verifying | verified)
			# Task completed — get PR info
			local task_pr task_wt
			task_pr=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$(sql_escape "$etask")';" 2>/dev/null || echo "")
			task_wt=$(db "$SUPERVISOR_DB" "SELECT worktree FROM tasks WHERE id = '$(sql_escape "$etask")';" 2>/dev/null || echo "")

			db "$SUPERVISOR_DB" "
				UPDATE contest_entries SET
					status = 'complete',
					pr_url = '$(sql_escape "${task_pr:-}")',
					worktree = '$(sql_escape "${task_wt:-}")',
					completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
				WHERE id = '$(sql_escape "$eid")';
			"
			log_info "Contest entry $eid: synced to complete (task $etask is $task_status)"
			;;
		failed | blocked | cancelled)
			db "$SUPERVISOR_DB" "
				UPDATE contest_entries SET status = 'failed'
				WHERE id = '$(sql_escape "$eid")';
			"
			log_info "Contest entry $eid: synced to failed (task $etask is $task_status)"
			;;
		running | dispatched | evaluating)
			db "$SUPERVISOR_DB" "
				UPDATE contest_entries SET status = 'running'
				WHERE id = '$(sql_escape "$eid")';
			"
			;;
		esac
	done <<<"$entries"

	return 0
}
