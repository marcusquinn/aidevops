#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Contest Helper — Dispatch Sub-Library
# =============================================================================
# Contest entry dispatch: launches parallel workers for each model entry.
#
# Usage: source "${SCRIPT_DIR}/contest-helper-dispatch.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - contest-helper.sh orchestrator (db, sql_escape, ensure_contest_tables, log_*)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CONTEST_DISPATCH_LIB_LOADED:-}" ]] && return 0
_CONTEST_DISPATCH_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

#######################################
# Dispatch a single contest entry as a worker subtask
# Usage: _dispatch_single_entry <entry_id> <entry_model> <entry_task_id>
#                               <ctask_id> <cdesc> <crepo> <cbatch_id>
# Returns 0 on success, 1 on failure
#######################################
_dispatch_single_entry() {
	local entry_id="$1"
	local entry_model="$2"
	local entry_task_id="$3"
	local ctask_id="$4"
	local cdesc="$5"
	local crepo="$6"
	local cbatch_id="$7"

	local supervisor_helper="${SCRIPT_DIR}/pulse-wrapper.sh"

	log_info "Dispatching contest entry: $entry_id (model: $entry_model)"

	# Add subtask to supervisor DB with the specific model
	# NOTE: supervisor-helper.sh was removed; pulse-wrapper.sh is the successor
	if ! "$supervisor_helper" add "$entry_task_id" \
		--repo "${crepo:-.}" \
		--description "Contest entry for $ctask_id: $cdesc" \
		--model "$entry_model" 2>/dev/null; then
		log_error "Failed to add subtask $entry_task_id for entry $entry_id"
		db "$SUPERVISOR_DB" "
			UPDATE contest_entries SET status = 'failed'
			WHERE id = '$(sql_escape "$entry_id")';
		"
		return 1
	fi

	# Add to batch if one exists
	if [[ -n "$cbatch_id" ]]; then
		"$supervisor_helper" db "
			INSERT OR IGNORE INTO batch_tasks (batch_id, task_id)
			VALUES ('$(sql_escape "$cbatch_id")', '$(sql_escape "$entry_task_id")');
		" 2>/dev/null || true
	fi

	# Dispatch the subtask
	if ! "$supervisor_helper" dispatch "$entry_task_id" ${cbatch_id:+--batch "$cbatch_id"} 2>/dev/null; then
		log_warn "Failed to dispatch entry $entry_id"
		db "$SUPERVISOR_DB" "
			UPDATE contest_entries SET status = 'failed'
			WHERE id = '$(sql_escape "$entry_id")';
		"
		return 1
	fi

	# Update entry with dispatch info
	local subtask_info
	subtask_info=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT worktree, branch, log_file
		FROM tasks WHERE id = '$(sql_escape "$entry_task_id")';
	")
	local ewt ebranch elog
	IFS=$'\t' read -r ewt ebranch elog <<<"$subtask_info"

	db "$SUPERVISOR_DB" "
		UPDATE contest_entries SET
			status = 'dispatched',
			worktree = '$(sql_escape "${ewt:-}")',
			branch = '$(sql_escape "${ebranch:-}")',
			log_file = '$(sql_escape "${elog:-}")'
		WHERE id = '$(sql_escape "$entry_id")';
	"
	return 0
}

#######################################
# Load contest details from DB; outputs task_id<TAB>desc<TAB>repo<TAB>batch_id
# Returns 1 if not found.
#######################################
_dispatch_load_contest() {
	local escaped_cid="$1"

	local row
	row=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT task_id, description, repo, batch_id
		FROM contests WHERE id = '$escaped_cid';
	")
	if [[ -z "$row" ]]; then
		return 1
	fi
	printf '%s' "$row"
	return 0
}

#######################################
# Dispatch all pending entries for a contest; outputs dispatched_count.
#######################################
_dispatch_run_entries() {
	local escaped_cid="$1"
	local ctask_id="$2"
	local cdesc="$3"
	local crepo="$4"
	local cbatch_id="$5"

	local entries
	entries=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, model, task_id
		FROM contest_entries
		WHERE contest_id = '$escaped_cid' AND status = 'pending';
	")

	local dispatched_count=0
	while IFS=$'\t' read -r entry_id entry_model entry_task_id; do
		[[ -z "$entry_id" ]] && continue
		if _dispatch_single_entry \
			"$entry_id" "$entry_model" "$entry_task_id" \
			"$ctask_id" "$cdesc" "$crepo" "$cbatch_id"; then
			dispatched_count=$((dispatched_count + 1))
		fi
	done <<<"$entries"

	echo "$dispatched_count"
	return 0
}

#######################################
# Dispatch contest entries as parallel workers
# Creates subtasks in supervisor DB and dispatches them
#######################################
cmd_dispatch_contest() {
	local contest_id="${1:-}"
	if [[ -z "$contest_id" ]]; then
		log_error "Usage: contest-helper.sh dispatch <contest_id>"
		return 1
	fi

	ensure_contest_tables || return 1

	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	local contest_row
	contest_row=$(_dispatch_load_contest "$escaped_cid") || {
		log_error "Contest not found: $contest_id"
		return 1
	}

	local ctask_id cdesc crepo cbatch_id
	IFS=$'\t' read -r ctask_id cdesc crepo cbatch_id <<<"$contest_row"

	db "$SUPERVISOR_DB" "
		UPDATE contests SET status = 'dispatching', metadata = 'dispatch_started:$(date -u +%Y-%m-%dT%H:%M:%SZ)'
		WHERE id = '$escaped_cid';
	"

	local entries
	entries=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, model, task_id
		FROM contest_entries
		WHERE contest_id = '$escaped_cid' AND status = 'pending';
	")
	if [[ -z "$entries" ]]; then
		log_warn "No pending entries for contest $contest_id"
		return 0
	fi

	local dispatched_count
	dispatched_count=$(_dispatch_run_entries "$escaped_cid" "$ctask_id" "$cdesc" "$crepo" "$cbatch_id")

	if [[ "$dispatched_count" -gt 0 ]]; then
		db "$SUPERVISOR_DB" "
			UPDATE contests SET status = 'running'
			WHERE id = '$escaped_cid';
		"
		log_success "Dispatched $dispatched_count contest entries for $contest_id"
	else
		db "$SUPERVISOR_DB" "
			UPDATE contests SET status = 'failed',
				metadata = COALESCE(metadata,'') || ' dispatch_failed:all_entries'
			WHERE id = '$escaped_cid';
		"
		log_error "All contest entries failed to dispatch"
		return 1
	fi

	return 0
}
