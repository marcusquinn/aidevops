#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Worker identity, duplicate detection, PID resolution, and readiness checks.
# Source through dispatch-single-issue-helper.sh; it owns dependencies and state.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_DSI_TRACKING_LOADED:-}" ]] && return 0
_DSI_TRACKING_LOADED=1

if [[ -z "${_DSI_SCRIPT_DIR:-}" ]]; then
	_dsi_tracking_path="${BASH_SOURCE[0]%/*}"
	[[ "$_dsi_tracking_path" == "${BASH_SOURCE[0]}" ]] && _dsi_tracking_path="."
	_DSI_SCRIPT_DIR="$(cd "$_dsi_tracking_path" && pwd)"
	unset _dsi_tracking_path
fi

#######################################
# Extract a --dir value from a worker command line.
# Args: $1 - command line
# Stdout: worktree path, or empty string
#######################################
_dsi_extract_worktree_from_cmd() {
	local cmd="$1"
	local worktree_path=""
	if [[ "$cmd" =~ --dir[[:space:]]+([^[:space:]]+) ]]; then
		worktree_path="${BASH_REMATCH[1]}"
	fi
	printf '%s\n' "$worktree_path"
	return 0
}

#######################################
# Resolve a repo slug from a worktree path.
# Args: $1 - worktree path
# Stdout: owner/repo slug, or empty string
#######################################
_dsi_repo_slug_for_worktree() {
	local worktree_path="$1"
	local remote_url=""
	if [[ -z "$worktree_path" || ! -d "$worktree_path" ]]; then
		printf '\n'
		return 0
	fi
	remote_url=$(git -C "$worktree_path" remote get-url origin 2>/dev/null || true)
	# Strip suffixes before matching so dotted names (owner/my.repo) resolve.
	remote_url="${remote_url%/}"
	remote_url="${remote_url%.git}"
	if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	printf '\n'
	return 0
}

#######################################
# Emit active worker process lines for duplicate detection.
# Tests override this function with fixture output.
# Stdout: ps rows: "PID STAT COMMAND..."
# `ps` right-aligns PID and pads STAT, so consumers must strip leading
# whitespace before each field split. Untrimmed, every PID below 10000 on
# macOS parses as empty and live workers are silently dropped (GH#33916).
#######################################
_dsi_ps_worker_lines() {
	ps axwwo pid=,stat=,command= 2>/dev/null || true
	return 0
}

#######################################
# Check whether a PID is currently signalable by this runner.
# Tests override this function with deterministic process fixtures.
# Args: $1 - PID
# Returns: 0 live, 1 dead/inaccessible
#######################################
_dsi_pid_is_live() {
	local pid="$1"
	kill -0 "$pid" 2>/dev/null
	return $?
}

#######################################
# Check if a command line belongs to a worker for an issue number.
# Args: $1 - issue number, $2 - command line
# Returns: 0 match, 1 no match
#######################################
_dsi_cmd_matches_issue() {
	local issue_number="$1"
	local cmd="$2"
	local issue_re="([Ii]ssue[[:space:]]+#|[Ii]ssue[[:space:]]+|GH#)${issue_number}([^0-9]|$)"
	if [[ "$cmd" =~ $issue_re ]]; then
		return 0
	fi
	if [[ "$cmd" == *"--session-key issue-${issue_number}"* || "$cmd" == *"--session-key manual-cli-${issue_number}-"* ]]; then
		return 0
	fi
	return 1
}

#######################################
# Find a manual-dispatch log that names a worker PID.
# Args: $1 - issue number, $2 - PID
# Stdout: log path, or "<unknown>"
#######################################
_dsi_find_log_for_pid() {
	local issue_number="$1"
	local worker_pid="$2"
	local candidate=""
	for candidate in "$_DSI_LOG_DIR"/manual-dispatch-"${issue_number}"-*.log; do
		[[ -f "$candidate" ]] || continue
		if grep -Fq "Dispatched PID: ${worker_pid}" "$candidate" 2>/dev/null; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	printf '%s\n' "$_DSI_UNKNOWN_VALUE"
	return 0
}

#######################################
# Find a live worker by repo+issue and/or exact worktree path.
# Args: $1 - issue number, $2 - repo slug, $3 - worktree path (optional)
# Stdout: TSV source, pid, log, worktree, session_key
# Returns: 0 found, 1 none
#######################################
_dsi_find_live_dispatch() {
	local issue_number="$1"
	local repo_slug="$2"
	local target_worktree="${3:-}"
	local line pid stat cmd worktree_path worker_repo log_path session_key

	while IFS= read -r line; do
		line="${line#"${line%%[![:space:]]*}"}"
		[[ -n "$line" ]] || continue
		pid="${line%%[[:space:]]*}"
		line="${line#*[[:space:]]}"
		line="${line#"${line%%[![:space:]]*}"}"
		stat="${line%%[[:space:]]*}"
		cmd="${line#*[[:space:]]}"
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		[[ "$stat" == *Z* || "$stat" == *T* ]] && continue
		[[ "$cmd" == *"dispatch-single-issue-helper.sh"* ]] && continue

		worktree_path=$(_dsi_extract_worktree_from_cmd "$cmd")
		if [[ -n "$target_worktree" && "$worktree_path" == "$target_worktree" ]]; then
			log_path=$(_dsi_find_log_for_pid "$issue_number" "$pid")
			session_key=$(printf '%s' "$cmd" | sed -n 's/.*--session-key[[:space:]]\([^[:space:]]*\).*/\1/p' | head -1)
			printf 'process\t%s\t%s\t%s\t%s\n' "$pid" "$log_path" "$worktree_path" "${session_key:-$_DSI_UNKNOWN_VALUE}"
			return 0
		fi

		_dsi_cmd_matches_issue "$issue_number" "$cmd" || continue
		worker_repo=$(_dsi_repo_slug_for_worktree "$worktree_path")
		[[ "$worker_repo" == "$repo_slug" ]] || continue
		log_path=$(_dsi_find_log_for_pid "$issue_number" "$pid")
		session_key=$(printf '%s' "$cmd" | sed -n 's/.*--session-key[[:space:]]\([^[:space:]]*\).*/\1/p' | head -1)
		printf 'process\t%s\t%s\t%s\t%s\n' "$pid" "$log_path" "${worktree_path:-$_DSI_UNKNOWN_VALUE}" "${session_key:-$_DSI_UNKNOWN_VALUE}"
		return 0
	done < <(_dsi_ps_worker_lines)

	return 1
}

#######################################
# Find a live ledger entry for repo+issue.
# Args: $1 - issue number, $2 - repo slug
# Stdout: TSV source, pid, log, worktree, session_key
# Returns: 0 found, 1 none
#######################################
_dsi_find_ledger_dispatch() {
	local issue_number="$1"
	local repo_slug="$2"
	local entry pid session_key worktree_path log_path
	entry=$("$_DSI_LEDGER_HELPER" check-issue --issue "$issue_number" --repo "$repo_slug" 2>/dev/null) || entry=""
	[[ -n "$entry" ]] || return 1
	pid=$(printf '%s' "$entry" | jq -r '.pid // "?"')
	session_key=$(printf '%s' "$entry" | jq -r --arg unknown "$_DSI_UNKNOWN_VALUE" '.session_key // $unknown')
	worktree_path=$(printf '%s' "$entry" | jq -r '.worktree_path // ""')
	[[ -n "$worktree_path" && "$worktree_path" != "null" ]] || worktree_path="$_DSI_UNKNOWN_VALUE"
	log_path=$(_dsi_find_log_for_pid "$issue_number" "$pid")
	printf 'ledger\t%s\t%s\t%s\t%s\n' "$pid" "$log_path" "$worktree_path" "$session_key"
	return 0
}

#######################################
# Print active dispatch details from a TSV record.
# Args: TSV source, pid, log, worktree, session_key
#######################################
_dsi_print_dispatch_details() {
	local record="$1"
	local source pid log_path worktree_path session_key
	IFS=$'\t' read -r source pid log_path worktree_path session_key <<<"$record"
	_dsi_info "  Evidence source:  ${source}"
	_dsi_info "  Existing PID:     ${pid}"
	_dsi_info "  Existing log:     ${log_path}"
	_dsi_info "  Existing worktree:${worktree_path}"
	_dsi_info "  Existing session: ${session_key}"
	return 0
}

#######################################
# Verify that a ledger record still names the same live worker process.
# A lease can intentionally outlive its local PID for cross-runner dedup, so
# launch-worker status must independently validate PID liveness plus the
# session, worktree, issue, and repository encoded in the process command.
# Args: $1 - issue number, $2 - repo slug, $3 - ledger TSV record
# Returns: 0 verified live worker, 1 stale/dead/reused PID evidence,
#          2 PID is live but absent from the process listing (unverifiable)
#######################################
_dsi_ledger_record_has_live_identity() {
	local issue_number="$1"
	local repo_slug="$2"
	local record="$3"
	local source="" pid="" log_path="" worktree_path="" session_key=""
	IFS=$'\t' read -r source pid log_path worktree_path session_key <<<"$record"

	[[ "$source" == "ledger" && "$pid" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$session_key" && "$session_key" != "$_DSI_UNKNOWN_VALUE" ]] || return 1
	[[ -n "$worktree_path" && "$worktree_path" != "$_DSI_UNKNOWN_VALUE" ]] || return 1
	_dsi_pid_is_live "$pid" || return 1

	local line="" process_pid="" stat="" cmd=""
	local process_session="" process_worktree="" process_repo=""
	while IFS= read -r line; do
		line="${line#"${line%%[![:space:]]*}"}"
		[[ -n "$line" ]] || continue
		process_pid="${line%%[[:space:]]*}"
		[[ "$process_pid" == "$pid" ]] || continue
		line="${line#*[[:space:]]}"
		line="${line#"${line%%[![:space:]]*}"}"
		stat="${line%%[[:space:]]*}"
		cmd="${line#*[[:space:]]}"
		[[ "$stat" != *Z* && "$stat" != *T* ]] || return 1
		[[ "$cmd" == *"headless-runtime-helper.sh"* ]] || return 1

		process_session=$(printf '%s' "$cmd" | sed -n 's/.*--session-key[[:space:]]\([^[:space:]]*\).*/\1/p')
		[[ "$process_session" == "$session_key" ]] || return 1
		process_worktree=$(_dsi_extract_worktree_from_cmd "$cmd")
		[[ "$process_worktree" == "$worktree_path" ]] || return 1
		_dsi_cmd_matches_issue "$issue_number" "$cmd" || return 1
		process_repo=$(_dsi_repo_slug_for_worktree "$process_worktree")
		[[ "$process_repo" == "$repo_slug" ]] || return 1
		return 0
	done < <(_dsi_ps_worker_lines)

	# kill -0 succeeded but no listing row named the PID: identity is unknown,
	# not disproven. Callers must not report this as a confident inactive state.
	return 2
}

#######################################
# Print an existing active dispatch as a blocking duplicate.
# Args: TSV source, pid, log, worktree, session_key
#######################################
_dsi_print_existing_dispatch() {
	local record="$1"
	local source="${record%%$'\t'*}"
	_dsi_err "Active worker already owns this issue or worktree (${source})"
	_dsi_print_dispatch_details "$record"
	return 0
}

#######################################
# Fail closed if an active dispatch already owns repo+issue or worktree.
# Args: $1 - issue number, $2 - repo slug, $3 - worktree path (optional)
# Returns: 0 clear, 1 blocked
#######################################
_dsi_guard_no_existing_dispatch() {
	local issue_number="$1"
	local repo_slug="$2"
	local worktree_path="${3:-}"
	local record=""
	if record=$(_dsi_find_ledger_dispatch "$issue_number" "$repo_slug"); then
		_dsi_print_existing_dispatch "$record"
		return 1
	fi
	if record=$(_dsi_find_live_dispatch "$issue_number" "$repo_slug" "$worktree_path"); then
		_dsi_print_existing_dispatch "$record"
		return 1
	fi
	return 0
}

#######################################
# Resolve the real worker PID from the worker_log file.
# _detach_worker (headless-runtime-worker-prepare.sh) prints "Dispatched PID: <pid>"
# for the detached worker process itself; under systemd it runs in its own
# user scope outside the caller's cgroup (GH#33993).
# We poll the log briefly waiting for that line; if it never appears,
# fall back to the launch wrapper PID (degraded — ledger may show dead PID).
# Args: $1 - worker_log path, $2 - launch_pid (fallback)
# Stdout: PID (single integer)
#######################################
_dsi_resolve_worker_pid() {
	local worker_log="$1"
	local launch_pid="$2"
	local attempts=0
	while [[ $attempts -lt 30 ]]; do
		if [[ -s "$worker_log" ]]; then
			local pid
			pid=$(grep -oE 'Dispatched PID: [0-9]+' "$worker_log" 2>/dev/null | awk '{print $3}' | head -1)
			if [[ -n "$pid" ]]; then
				echo "$pid"
				return 0
			fi
		fi
		sleep 0.1
		attempts=$((attempts + 1))
	done
	# Fallback: caller can decide what to do with degraded state
	_dsi_warn "Could not extract worker PID from log within 3s — using launch wrapper PID (ledger may go stale)"
	echo "$launch_pid"
	return 0
}

#######################################
# Return the detached runtime log path used by headless-runtime-helper.sh.
# Args: $1 - session_key
# Stdout: absolute log path
#######################################
_dsi_detached_runtime_log() {
	local session_key="$1"
	printf '/tmp/worker-%s.log' "$session_key"
	return 0
}

#######################################
# Resolve the bounded manual-dispatch readiness budget.
# The detached worker may spend the full canary allowance before preparation
# emits worker_started, so the default must cover canary plus setup overhead.
# Stdout: timeout seconds
#######################################
_dsi_ready_timeout_seconds() {
	local canary_timeout_s="${CANARY_TIMEOUT_SECONDS:-$_DSI_DEFAULT_CANARY_TIMEOUT_SECONDS}"
	local configured_timeout_s="${AIDEVOPS_DSI_READY_TIMEOUT_SECONDS:-}"
	if ! [[ "$canary_timeout_s" =~ ^[0-9]+$ ]]; then
		canary_timeout_s="$_DSI_DEFAULT_CANARY_TIMEOUT_SECONDS"
	fi
	local default_timeout_s=$((canary_timeout_s + _DSI_READY_PREPARATION_ALLOWANCE_SECONDS))
	if [[ -z "$configured_timeout_s" ]] || ! [[ "$configured_timeout_s" =~ ^[0-9]+$ ]]; then
		configured_timeout_s="$default_timeout_s"
	fi
	printf '%s\n' "$configured_timeout_s"
	return 0
}

#######################################
# Wait until a detached worker reaches an observable readiness signal.
#
# The outer nohup wrapper can exit successfully before model selection,
# canary, and worker preparation complete. Treat launch as ready only when the
# real child is alive and has emitted the canonical worker-start marker, or has
# exited/failed with inspectable log evidence. Ledger registration happens
# before the worker-start marker, so it is progress evidence but not readiness.
# This prevents silent success when pre-worker setup blocks.
# Args:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - session_key
#   $4 - worker_pid
#   $5 - launcher_log path
# Returns: 0 ready, 1 failed/not-ready before timeout
#######################################
_dsi_wait_for_worker_readiness() {
	local issue_number="$1"
	local repo_slug="$2"
	local session_key="$3"
	local worker_pid="$4"
	local launcher_log="$5"
	local runtime_log
	runtime_log=$(_dsi_detached_runtime_log "$session_key")
	local timeout_s
	timeout_s=$(_dsi_ready_timeout_seconds)
	local attempts=0
	local max_attempts=$((timeout_s * 10))

	while [[ "$attempts" -le "$max_attempts" ]]; do
		if [[ -s "$runtime_log" ]] &&
			grep -Fq -e "worker_started" -e "worker_start session=${session_key}" "$runtime_log" 2>/dev/null; then
			return 0
		fi

		if [[ -n "$worker_pid" ]] && ! kill -0 "$worker_pid" 2>/dev/null; then
			_dsi_err "Worker launch failed — detached child exited before readiness"
			_dsi_info "  Launcher log: ${launcher_log}"
			_dsi_info "  Runtime log:  ${runtime_log}"
			return 1
		fi

		if [[ "$attempts" -eq "$max_attempts" ]]; then
			break
		fi
		sleep 0.1
		attempts=$((attempts + 1))
	done

	_dsi_err "Worker launch did not reach readiness within ${timeout_s}s"
	_dsi_info "  Worker PID:   ${worker_pid}"
	_dsi_info "  Launcher log: ${launcher_log}"
	_dsi_info "  Runtime log:  ${runtime_log}"
	return 1
}
