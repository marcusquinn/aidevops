#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Contest Helper — Create Sub-Library
# =============================================================================
# Contest creation flow: should-contest decision, model selection, and
# contest/entry insertion into the supervisor DB.
#
# Usage: source "${SCRIPT_DIR}/contest-helper-create.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - contest-helper.sh orchestrator (db, sql_escape, ensure_contest_tables, log_*)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CONTEST_CREATE_LIB_LOADED:-}" ]] && return 0
_CONTEST_CREATE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

#######################################
# Determine if a task should use contest mode (t1011)
# Returns 0 (yes) if:
#   1. Task has explicit model:contest in TODO.md
#   2. No pattern data exists for this task type (new territory)
#   3. Pattern data is inconclusive (no tier has >75% success with 3+ samples)
# Returns 1 (no) otherwise
#######################################
cmd_should_contest() {
	local task_id="${1:-}"
	if [[ -z "$task_id" ]]; then
		log_error "Usage: contest-helper.sh should-contest <task_id>"
		return 1
	fi

	ensure_contest_tables || return 1

	# Check 1: Explicit model:contest in TODO.md
	local repo_path
	repo_path=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo ".")
	local todo_file="${repo_path:-.}/TODO.md"
	if [[ -f "$todo_file" ]]; then
		local task_line
		task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" 2>/dev/null || true)
		if echo "$task_line" | grep -q 'model:contest'; then
			log_info "Task $task_id has explicit model:contest — contest mode triggered"
			echo "explicit"
			return 0
		fi
	fi

	# Check 2: Query pattern-tracker for this task type (archived — graceful fallback)
	local pattern_helper="${SCRIPT_DIR}/archived/pattern-tracker-helper.sh"
	if [[ ! -x "$pattern_helper" ]]; then
		log_warn "Pattern tracker not available — defaulting to no contest"
		echo "no_tracker"
		return 1
	fi

	# Get recommendation JSON
	local pattern_json
	pattern_json=$("$pattern_helper" recommend --json 2>/dev/null || echo "")

	if [[ -z "$pattern_json" || "$pattern_json" == "{}" ]]; then
		log_info "No pattern data available for $task_id — contest mode triggered (new territory)"
		echo "no_data"
		return 0
	fi

	# Check if any tier has strong enough signal (>75% success, 3+ samples)
	local total_samples
	total_samples=$(echo "$pattern_json" | sed -n 's/.*"total_samples"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' 2>/dev/null || echo "0")
	local success_rate
	success_rate=$(echo "$pattern_json" | sed -n 's/.*"success_rate"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' 2>/dev/null || echo "0")

	if [[ "$total_samples" -lt 3 ]]; then
		log_info "Insufficient pattern data ($total_samples samples) for $task_id — contest mode triggered"
		echo "insufficient_data"
		return 0
	fi

	if [[ "$success_rate" -lt 75 ]]; then
		log_info "Low success rate (${success_rate}%) for $task_id — contest mode triggered"
		echo "low_success_rate"
		return 0
	fi

	# Strong signal exists — no contest needed
	log_info "Strong pattern data (${success_rate}% over $total_samples samples) — no contest needed"
	echo "strong_signal"
	return 1
}

#######################################
# Select top-3 models for contest
# Uses model-registry + fallback-chain to pick diverse, available models
#######################################
select_contest_models() {
	local explicit_models="${1:-}"

	if [[ -n "$explicit_models" ]]; then
		echo "$explicit_models"
		return 0
	fi

	# Try model-registry for data-driven selection
	local registry_helper="${SCRIPT_DIR}/model-registry-helper.sh"
	if [[ -x "$registry_helper" ]]; then
		# Get top models from different tiers for diversity
		local opus_model sonnet_model pro_model
		opus_model=$("$registry_helper" list --tier opus --json 2>/dev/null | sed -n 's/.*"model_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || echo "")
		sonnet_model=$("$registry_helper" list --tier sonnet --json 2>/dev/null | sed -n 's/.*"model_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || echo "")
		pro_model=$("$registry_helper" list --tier pro --json 2>/dev/null | sed -n 's/.*"model_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || echo "")

		if [[ -n "$opus_model" && -n "$sonnet_model" && -n "$pro_model" ]]; then
			echo "${opus_model},${sonnet_model},${pro_model}"
			return 0
		fi
	fi

	# Fallback to defaults
	echo "$DEFAULT_CONTEST_MODELS"
	return 0
}

#######################################
# Parse arguments for cmd_create
# Sets task_id, explicit_models, batch_id in caller scope via stdout
# Usage: _parse_create_args "$@"
# Outputs: task_id<TAB>explicit_models<TAB>batch_id
#######################################
_parse_create_args() {
	local task_id="" explicit_models="" batch_id=""
	local _opt _val

	if [[ $# -gt 0 ]]; then
		_opt="$1"
		if [[ ! "$_opt" =~ ^-- ]]; then
			task_id="$_opt"
			shift
		fi
	fi

	while [[ $# -gt 0 ]]; do
		_opt="$1"
		case "$_opt" in
		--models)
			[[ $# -lt 2 ]] && {
				log_error "--models requires a value"
				return 1
			}
			_val="$2"
			explicit_models="$_val"
			shift 2
			;;
		--batch)
			[[ $# -lt 2 ]] && {
				log_error "--batch requires a value"
				return 1
			}
			_val="$2"
			batch_id="$_val"
			shift 2
			;;
		*)
			log_error "Unknown option: $_opt"
			return 1
			;;
		esac
	done

	printf '%s\t%s\t%s' "$task_id" "$explicit_models" "$batch_id"
	return 0
}

#######################################
# Create contest entries for each model
# Usage: _create_contest_entries <contest_id> <task_id> <models_csv>
#######################################
_create_contest_entries() {
	local contest_id="$1"
	local task_id="$2"
	local models="$3"

	local model_index=0
	local IFS=','
	for model in $models; do
		model_index=$((model_index + 1))
		local entry_id="${contest_id}-entry-${model_index}"
		local entry_task_id="${task_id}-contest-${model_index}"

		db "$SUPERVISOR_DB" "
			INSERT INTO contest_entries (id, contest_id, model, task_id, status)
			VALUES (
				'$(sql_escape "$entry_id")',
				'$(sql_escape "$contest_id")',
				'$(sql_escape "$model")',
				'$(sql_escape "$entry_task_id")',
				'pending'
			);
		"

		log_info "Created entry $entry_id for model $model (task: $entry_task_id)"
	done
	unset IFS

	echo "$model_index"
	return 0
}

#######################################
# Verify task exists in supervisor DB and return its fields.
# Usage: _create_verify_task <escaped_id>
# Outputs: repo<TAB>description  (empty = not found)
#######################################
_create_verify_task() {
	local escaped_id="$1"

	db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT repo, description
		FROM tasks WHERE id = '$escaped_id';
	"
	return 0
}

#######################################
# Check for an existing active contest for a task.
# Usage: _create_check_existing <escaped_id>
# Outputs: existing contest ID (empty = none)
#######################################
_create_check_existing() {
	local escaped_id="$1"

	db "$SUPERVISOR_DB" "
		SELECT id FROM contests
		WHERE task_id = '$escaped_id'
		AND status NOT IN ('complete','failed','cancelled');
	"
	return 0
}

#######################################
# Insert a contest record and its entries; outputs contest_id.
# Usage: _create_insert_contest <task_id> <escaped_id> <tdesc> <trepo> <models> <batch_id>
#######################################
_create_insert_contest() {
	local task_id="$1"
	local escaped_id="$2"
	local tdesc="$3"
	local trepo="$4"
	local models="$5"
	local batch_id="$6"

	local contest_id
	contest_id="contest-${task_id}-$(date +%Y%m%d%H%M%S)"

	db "$SUPERVISOR_DB" "
		INSERT INTO contests (id, task_id, description, status, models, batch_id, repo)
		VALUES (
			'$(sql_escape "$contest_id")',
			'$escaped_id',
			'$(sql_escape "$tdesc")',
			'pending',
			'$(sql_escape "$models")',
			'$(sql_escape "${batch_id:-}")',
			'$(sql_escape "${trepo:-.}")'
		);
	"

	local model_count
	model_count=$(_create_contest_entries "$contest_id" "$task_id" "$models")

	log_success "Contest created: $contest_id with ${model_count} entries"
	echo "$contest_id"
	return 0
}

#######################################
# Create a contest for a task (t1011)
# Dispatches the same task to top-3 models in parallel
#######################################
cmd_create() {
	local parsed_args task_id explicit_models batch_id
	parsed_args=$(_parse_create_args "$@") || return 1
	IFS=$'\t' read -r task_id explicit_models batch_id <<<"$parsed_args"

	if [[ -z "$task_id" ]]; then
		log_error "Usage: contest-helper.sh create <task_id> [--models 'model1,model2,model3']"
		return 1
	fi

	ensure_contest_tables || return 1

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	local task_row
	task_row=$(_create_verify_task "$escaped_id")
	if [[ -z "$task_row" ]]; then
		log_error "Task not found in supervisor DB: $task_id"
		return 1
	fi

	local trepo tdesc
	IFS=$'\t' read -r trepo tdesc <<<"$task_row"

	local existing_contest
	existing_contest=$(_create_check_existing "$escaped_id")
	if [[ -n "$existing_contest" ]]; then
		log_warn "Active contest already exists for $task_id: $existing_contest"
		echo "$existing_contest"
		return 0
	fi

	local models
	models=$(select_contest_models "$explicit_models")
	log_info "Contest models: $models"

	_create_insert_contest "$task_id" "$escaped_id" "$tdesc" "$trepo" "$models" "$batch_id"
	return 0
}
