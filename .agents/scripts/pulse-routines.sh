#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-routines.sh — Recurring routine scheduler (repeat:/run:/agent: TODO entries).
#
# Extracted from pulse-wrapper.sh in Phase 1 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _routine_last_run_epoch
#   - _routine_update_state
#   - _routine_execute
#   - evaluate_routines
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing. pulse-wrapper.sh sources every
# module unconditionally on start, and characterization tests re-source to
# verify idempotency.
[[ -n "${_PULSE_ROUTINES_LOADED:-}" ]] && return 0
_PULSE_ROUTINES_LOADED=1

#######################################
# Read last-run epoch for a routine ID from state file
# Arguments: $1 - routine ID (e.g., r001)
# Output: epoch (0 if never run)
#######################################
_routine_last_run_epoch() {
	local routine_id="$1"
	if [[ ! -f "$ROUTINE_STATE_FILE" ]]; then
		printf '0'
		return 0
	fi
	local epoch
	epoch=$(jq -r --arg id "$routine_id" '.[$id].last_run // ""' "$ROUTINE_STATE_FILE" 2>/dev/null) || epoch=""
	if [[ -z "$epoch" || "$epoch" == "null" ]]; then
		printf '0'
		return 0
	fi
	# Convert ISO to epoch
	local epoch_num
	epoch_num=$(date -d "$epoch" +%s 2>/dev/null) || epoch_num=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$epoch" +%s 2>/dev/null) || epoch_num=0
	printf '%s' "$epoch_num"
	return 0
}

#######################################
# Update routine state after execution
# Arguments:
#   $1 - routine ID
#   $2 - status (success|failure)
#######################################
_routine_update_state() {
	local routine_id="$1"
	local status="$2"
	local now_iso
	now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	mkdir -p "$(dirname "$ROUTINE_STATE_FILE")" 2>/dev/null || true

	local existing="{}"
	if [[ -f "$ROUTINE_STATE_FILE" ]]; then
		existing=$(cat "$ROUTINE_STATE_FILE" 2>/dev/null) || existing="{}"
		echo "$existing" | jq empty 2>/dev/null || existing="{}"
	fi

	local tmp_file
	tmp_file=$(mktemp "$(dirname "$ROUTINE_STATE_FILE")/.routine-state.XXXXXX")
	if echo "$existing" | jq --arg id "$routine_id" --arg ts "$now_iso" --arg st "$status" \
		'.[$id] = {"last_run": $ts, "last_status": $st}' >"$tmp_file" 2>/dev/null; then
		mv "$tmp_file" "$ROUTINE_STATE_FILE"
	else
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _routine_update_state: failed to write state for ${routine_id}" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Execute a single routine
# Arguments:
#   $1 - routine ID (e.g., r001)
#   $2 - description
#   $3 - run: value (script path, relative to ~/.aidevops/agents/)
#   $4 - agent: value
#   $5 - repo path (for agent dispatch context)
#######################################
_routine_execute() {
	local routine_id="$1"
	local description="$2"
	local run_script="$3"
	local agent_name="$4"
	local repo_path="$5"

	local agents_dir="${HOME}/.aidevops/agents"
	local status="success"

	if [[ -n "$run_script" ]]; then
		# Script-only dispatch — zero LLM tokens
		local script_path="${agents_dir}/${run_script}"
		if [[ ! -x "$script_path" ]]; then
			echo "[pulse-wrapper] routine ${routine_id}: script not found or not executable: ${script_path}" >>"$LOGFILE"
			_routine_update_state "$routine_id" "failure"
			return 1
		fi
		echo "[pulse-wrapper] routine ${routine_id}: executing script ${script_path}" >>"$LOGFILE"
		local exit_code=0
		"$script_path" >>"$LOGFILE" 2>&1 || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			status="failure"
			echo "[pulse-wrapper] routine ${routine_id}: script exited with code ${exit_code}" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] routine ${routine_id}: script completed successfully" >>"$LOGFILE"
		fi
	elif [[ -n "$agent_name" ]]; then
		# LLM dispatch via headless runtime
		echo "[pulse-wrapper] routine ${routine_id}: dispatching agent '${agent_name}' for '${description}'" >>"$LOGFILE"
		local dispatch_dir="${repo_path:-$PULSE_DIR}"
		"$HEADLESS_RUNTIME_HELPER" run \
			--role worker \
			--session-key "routine-${routine_id}" \
			--dir "$dispatch_dir" \
			--agent "$agent_name" \
			--title "Routine ${routine_id}: ${description}" \
			--prompt "Execute routine ${routine_id}: ${description}" 9>&- &
		# Don't wait — let it run in background like a worker
	else
		# Fallback: check for custom script
		local custom_script="${agents_dir}/custom/scripts/${routine_id}.sh"
		if [[ -x "$custom_script" ]]; then
			echo "[pulse-wrapper] routine ${routine_id}: executing custom script ${custom_script}" >>"$LOGFILE"
			local exit_code=0
			"$custom_script" >>"$LOGFILE" 2>&1 || exit_code=$?
			if [[ "$exit_code" -ne 0 ]]; then
				status="failure"
			fi
		else
			# Default to agent:Build+
			echo "[pulse-wrapper] routine ${routine_id}: no run: or agent: — dispatching Build+ default" >>"$LOGFILE"
			"$HEADLESS_RUNTIME_HELPER" run \
				--role worker \
				--session-key "routine-${routine_id}" \
				--dir "${repo_path:-$PULSE_DIR}" \
				--title "Routine ${routine_id}: ${description}" \
				--prompt "Execute routine ${routine_id}: ${description}" 9>&- &
		fi
	fi

	_routine_update_state "$routine_id" "$status"

	# Call routine-log-helper.sh if available (t1926)
	if [[ -x "$ROUTINE_LOG_HELPER" ]]; then
		"$ROUTINE_LOG_HELPER" update "$routine_id" "$status" 2>/dev/null || true
	fi

	return 0
}

#######################################
# Evaluate routines across all pulse-enabled repos
#
# Reads TODO.md from each pulse-enabled repo, extracts enabled routines
# ([x] lines with repeat: fields), checks if due, and dispatches.
#######################################
evaluate_routines() {
	if [[ ! -x "$ROUTINE_SCHEDULE_HELPER" ]]; then
		echo "[pulse-wrapper] evaluate_routines: schedule helper not found at ${ROUTINE_SCHEDULE_HELPER} — skipping" >>"$LOGFILE"
		return 0
	fi

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		echo "[pulse-wrapper] evaluate_routines: repos.json not found — skipping" >>"$LOGFILE"
		return 0
	fi

	local routines_dispatched=0
	local _routine_slug repo_path

	while IFS='|' read -r _routine_slug repo_path; do
		[[ -z "$repo_path" ]] && continue
		local todo_file="${repo_path}/TODO.md"
		if [[ ! -f "$todo_file" ]]; then
			continue
		fi

		# Extract enabled routine lines: [x] rNNN ... repeat:EXPR
		# Pattern: - [x] rNNN description repeat:expression [run:script] [agent:name]
		local line
		while IFS= read -r line; do
			# Skip disabled routines ([ ] prefix)
			[[ "$line" =~ ^[[:space:]]*-[[:space:]]\[x\] ]] || continue

			# Extract routine ID (rNNN)
			local routine_id=""
			if [[ "$line" =~ (r[0-9]+) ]]; then
				routine_id="${BASH_REMATCH[1]}"
			else
				continue
			fi

			# Extract repeat: field
			local repeat_expr=""
			if [[ "$line" =~ repeat:([^[:space:]]+) ]]; then
				repeat_expr="${BASH_REMATCH[1]}"
			else
				continue
			fi

			# Extract optional run: field
			local run_script=""
			if [[ "$line" =~ run:([^[:space:]]+) ]]; then
				run_script="${BASH_REMATCH[1]}"
			fi

			# Extract optional agent: field
			local agent_name=""
			if [[ "$line" =~ agent:([^[:space:]]+) ]]; then
				agent_name="${BASH_REMATCH[1]}"
			fi

			# Extract description (text between ID and first field tag)
			local description=""
			description=$(printf '%s' "$line" | sed -E 's/^.*\[x\][[:space:]]*(r[0-9]+)[[:space:]]*//' | sed -E 's/[[:space:]]*(repeat:|run:|agent:|#|~|@|started:|blocked-by:).*//')

			# Check if due
			local last_epoch
			last_epoch=$(_routine_last_run_epoch "$routine_id")

			if "$ROUTINE_SCHEDULE_HELPER" is-due "$repeat_expr" "$last_epoch"; then
				echo "[pulse-wrapper] routine ${routine_id} is due (expr=${repeat_expr}, last_run_epoch=${last_epoch})" >>"$LOGFILE"
				_routine_execute "$routine_id" "$description" "$run_script" "$agent_name" "$repo_path"
				routines_dispatched=$((routines_dispatched + 1))
			fi
		done < <(grep -E '^\s*-\s*\[x\].*repeat:' "$todo_file" 2>/dev/null || true)

	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false) | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null || true)

	if [[ "$routines_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] evaluate_routines: dispatched ${routines_dispatched} routine(s)" >>"$LOGFILE"
	fi

	return 0
}
