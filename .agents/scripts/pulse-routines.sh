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
#   - _routine_parse_line
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
	if [[ -z "$epoch" ]]; then
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
		# Script-only dispatch — zero LLM tokens.
		# Split run_script into the executable path and optional space-separated
		# arguments (e.g. "scripts/process-guard-helper.sh kill-runaways" becomes
		# script_path=".../process-guard-helper.sh" script_args=("kill-runaways")).
		# Using an array avoids word-splitting issues and safely passes args.
		local run_parts=()
		IFS=' ' read -r -a run_parts <<< "$run_script"
		local script_path="${agents_dir}/${run_parts[0]}"
		local script_args=("${run_parts[@]:1}")
		if [[ ! -x "$script_path" ]]; then
			echo "[pulse-wrapper] routine ${routine_id}: script not found or not executable: ${script_path}" >>"$LOGFILE"
			_routine_update_state "$routine_id" "failure"
			return 1
		fi
		if [[ ${#script_args[@]} -gt 0 ]]; then
			echo "[pulse-wrapper] routine ${routine_id}: executing script ${script_path} ${script_args[*]}" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] routine ${routine_id}: executing script ${script_path}" >>"$LOGFILE"
		fi
		local exit_code=0
		"$script_path" "${script_args[@]}" >>"$LOGFILE" 2>&1 || exit_code=$?
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
			--prompt "Execute routine ${routine_id}: ${description}" &
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
				--prompt "Execute routine ${routine_id}: ${description}" &
		fi
	fi

	_routine_update_state "$routine_id" "$status"

	# Call routine-log-helper.sh if available (t1926)
	if [[ -x "$ROUTINE_LOG_HELPER" ]]; then
		"$ROUTINE_LOG_HELPER" update "$routine_id" "$status" 2>/dev/null || true
	fi

	return 0
}

# Module-scope variables set by _routine_parse_line (prefixed to avoid collision).
# These are intentionally module-scope rather than nameref — avoids bash 4.3+ requirement
# for the re-exec guard fallback path, and matches the existing pattern in pulse-wrapper.sh.
_RPL_ID=""
_RPL_REPEAT=""
_RPL_RUN=""
_RPL_AGENT=""
_RPL_DESC=""

#######################################
# Parse a single routine TODO line into its component fields.
#
# Extracts routine_id, repeat expression, run script, agent name, and
# description from a TODO.md routine line. Sets module-scope variables
# (_RPL_ID, _RPL_REPEAT, _RPL_RUN, _RPL_AGENT, _RPL_DESC) on success.
#
# Arguments: $1 - a TODO.md line matching the routine pattern
# Returns: 0 if the line was successfully parsed, 1 if it should be skipped
#######################################
_routine_parse_line() {
	local line="$1"
	_RPL_ID=""
	_RPL_REPEAT=""
	_RPL_RUN=""
	_RPL_AGENT=""
	_RPL_DESC=""

	# Skip disabled routines ([ ] prefix)
	[[ "$line" =~ ^[[:space:]]*-[[:space:]]\[x\] ]] || return 1

	# Extract routine ID (rNNN) — anchored to immediately after [x] so that
	# r-prefixed IDs mentioned in task descriptions cannot produce a false match.
	if [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[x\][[:space:]]+(r[0-9]+) ]]; then
		_RPL_ID="${BASH_REMATCH[1]}"
	else
		return 1
	fi

	# Extract repeat: field
	# Use a variable to hold the regex so bash does not misparse the
	# literal ')' inside the character class [^)] as the closing '))'
	# of the [[ ]] compound.  The alternation handles cron(min hr …)
	# which contains spaces inside the parentheses — a plain
	# [^[:space:]]+ regex truncates at the first space (bug t2160).
	local _re_repeat='repeat:(cron\([^)]*\)|[^[:space:]]+)'
	if [[ "$line" =~ $_re_repeat ]]; then
		_RPL_REPEAT="${BASH_REMATCH[1]}"
	else
		return 1
	fi

	# Persistent: lifecycle-managed externally (launchd/systemd/supervisor).
	# The pulse never schedules these — skip silently (bug t2175).
	if [[ "$_RPL_REPEAT" == "persistent" ]]; then
		return 1
	fi

	# Extract optional run: field — captures script path and any trailing
	# space-separated argument tokens. Field keywords (agent:, repeat:,
	# started:, blocked-by:) always contain a colon, so we stop as soon as
	# we encounter a token with a colon embedded.
	if [[ "$line" =~ run:([^[:space:]]+) ]]; then
		_RPL_RUN="${BASH_REMATCH[1]}"
		# Append optional argument tokens that follow the script path.
		# Stop when a token contains ':' (field keyword) or starts with '#'.
		local _run_rest="${line#*run:"${_RPL_RUN}"}"
		local _arg_token
		while [[ "$_run_rest" =~ ^[[:space:]]+([^[:space:]]+)(.*)$ ]]; do
			_arg_token="${BASH_REMATCH[1]}"
			[[ "$_arg_token" == *:* || "$_arg_token" == "#"* || "$_arg_token" == "~"* || "$_arg_token" == "@"* ]] && break
			_RPL_RUN="${_RPL_RUN} ${_arg_token}"
			_run_rest="${BASH_REMATCH[2]}"
		done
	fi

	# Extract optional agent: field
	if [[ "$line" =~ agent:([^[:space:]]+) ]]; then
		_RPL_AGENT="${BASH_REMATCH[1]}"
	fi

	# Extract description (text between ID and first field tag)
	_RPL_DESC=$(printf '%s' "$line" | sed -E 's/^.*\[x\][[:space:]]*(r[0-9]+)[[:space:]]*//' | sed -E 's/[[:space:]]*(repeat:|run:|agent:|#|~|@|started:|blocked-by:).*//')

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
		[[ -f "$todo_file" ]] || continue

		# Extract enabled routine lines: [x] rNNN ... repeat:EXPR
		# Selector requires r[0-9]+ immediately after [x] to prevent t-prefix task
		# descriptions that mention repeat: from false-matching (bug t2175).
		local line
		while IFS= read -r line; do
			if ! _routine_parse_line "$line"; then
				continue
			fi

			# Check if due
			local last_epoch
			last_epoch=$(_routine_last_run_epoch "$_RPL_ID")

			if "$ROUTINE_SCHEDULE_HELPER" is-due "$_RPL_REPEAT" "$last_epoch"; then
				echo "[pulse-wrapper] routine ${_RPL_ID} is due (expr=${_RPL_REPEAT}, last_run_epoch=${last_epoch})" >>"$LOGFILE"
				_routine_execute "$_RPL_ID" "$_RPL_DESC" "$_RPL_RUN" "$_RPL_AGENT" "$repo_path"
				routines_dispatched=$((routines_dispatched + 1))
			fi
		done < <(grep -E '^\s*-\s*\[x\][[:space:]]+r[0-9]+[[:space:]].*repeat:' "$todo_file" 2>/dev/null || true)

	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false) | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null || true)

	if [[ "$routines_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] evaluate_routines: dispatched ${routines_dispatched} routine(s)" >>"$LOGFILE"
	fi

	return 0
}
