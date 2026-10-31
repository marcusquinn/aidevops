#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Worker Invocation -- Startup support and failure diagnostics
# =============================================================================
# Sourced by headless-runtime-worker.sh after its constants and dependencies.
# Usage: source "${SCRIPT_DIR}/headless-runtime-worker-invocation.sh"

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_HEADLESS_RUNTIME_WORKER_INVOCATION_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_WORKER_INVOCATION_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Runtime invocation support — auth rotation & rate-limit monitoring
# =============================================================================

# _maybe_rotate_isolated_auth: pre-dispatch OAuth rotation check for headless workers (t2249).
#
# When the account copied into the isolated auth.json is currently in
# cooldown per the SHARED pool metadata (recorded by a prior worker's
# mark-failure), rotate the isolated file to a healthy account BEFORE
# opencode spawns. This prevents wasted dispatches on known-dead accounts.
#
# Safe because OPENCODE_AUTH_FILE in oauth-pool-helper.sh is now
# XDG_DATA_HOME-aware (t2249): rotate writes to the ISOLATED file,
# not the shared interactive auth.json.
#
# Args: $1 = absolute path to the isolated auth.json
#       $2 = provider (e.g., "anthropic")
# Returns: 0 always — best-effort; rotation failure must not block dispatch.
_maybe_rotate_isolated_auth() {
	local isolated_auth="$1"
	local provider="$2"
	local pool_file="${AIDEVOPS_OAUTH_POOL_FILE:-${HOME}/.aidevops/oauth-pool.json}"
	local oauth_helper="${OAUTH_POOL_HELPER:-${HOME}/.aidevops/agents/scripts/oauth-pool-helper.sh}"

	# Skip silently when prerequisites are missing (jq, pool, isolated auth, helper).
	command -v jq >/dev/null 2>&1 || return 0
	[[ -f "$isolated_auth" ]] || return 0
	[[ -f "$pool_file" ]] || return 0
	[[ -x "$oauth_helper" ]] || return 0

	# Extract BOTH the email and access token currently written in the
	# isolated auth for this provider. build_auth_entry (in
	# oauth-pool-lib/_common.py) writes only {type, refresh, access, expires}
	# on rotation — NOT email. So after the first rotation, the isolated
	# auth.json has no email field and the previous email-only lookup here
	# returned early, defeating the rotation on every subsequent dispatch.
	# (CodeRabbit review #4135227617, verified against live production
	# ~/.local/share/opencode/auth.json 2026-04-19.)
	local current_email current_access
	current_email=$(jq -r --arg p "$provider" '.[$p].email // empty' "$isolated_auth" 2>/dev/null || true)
	current_access=$(jq -r --arg p "$provider" '.[$p].access // empty' "$isolated_auth" 2>/dev/null || true)
	[[ -n "$current_email" || -n "$current_access" ]] || return 0

	# Look up the account in the shared pool. Try email first (most common —
	# interactive auth with email was copied to isolated at worker startup).
	# Fall back to access-token match when email is absent (isolated auth
	# was already rotated at least once, dropping email per build_auth_entry).
	local pool_match=""
	if [[ -n "$current_email" ]]; then
		pool_match=$(jq -c --arg p "$provider" --arg e "$current_email" \
			'.[$p] | map(select(.email == $e)) | .[0] // empty' "$pool_file" 2>/dev/null || true)
	fi
	if [[ -z "$pool_match" && -n "$current_access" ]]; then
		pool_match=$(jq -c --arg p "$provider" --arg a "$current_access" \
			'.[$p] | map(select(.access == $a)) | .[0] // empty' "$pool_file" 2>/dev/null || true)
	fi
	[[ -n "$pool_match" ]] || return 0

	local cooldown_until now_ms identity_label
	cooldown_until=$(printf '%s' "$pool_match" | jq -r '.cooldownUntil // 0' 2>/dev/null || echo 0)
	[[ -n "$cooldown_until" ]] || cooldown_until=0
	# Log-friendly identity: private workloads suppress account identity, while
	# ordinary workers may use email. Never log access-token fragments.
	if [[ "${AIDEVOPS_PRIVATE_WORKLOAD:-0}" == "1" ]]; then
		identity_label="[private]"
	elif [[ -n "$current_email" ]]; then
		identity_label="$current_email"
	else
		identity_label="access credential"
	fi
	now_ms=$(($(date +%s) * 1000))

	# Only rotate when cooldown is still active (in the future).
	if [[ "$cooldown_until" -gt "$now_ms" ]]; then
		local isolated_dir
		isolated_dir="$(dirname "$(dirname "$isolated_auth")")"
		print_info "[lifecycle] pre_dispatch_rotate: ${provider} account=${identity_label} in cooldown; rotating isolated auth (dir=${isolated_dir})"
		# XDG_DATA_HOME is already exported by caller; passing it explicitly here
		# makes the intent explicit in logs and protects against env stripping.
		if XDG_DATA_HOME="$isolated_dir" "$oauth_helper" rotate "$provider" >/dev/null 2>&1; then
			local new_email new_access new_label
			new_email=$(jq -r --arg p "$provider" '.[$p].email // empty' "$isolated_auth" 2>/dev/null || echo "")
			new_access=$(jq -r --arg p "$provider" '.[$p].access // empty' "$isolated_auth" 2>/dev/null || echo "")
			if [[ "${AIDEVOPS_PRIVATE_WORKLOAD:-0}" == "1" ]]; then
				new_label="[private]"
			elif [[ -n "$new_email" ]]; then
				new_label="$new_email"
			elif [[ -n "$new_access" ]]; then
				new_label="access credential"
			else
				new_label="$_HRW_STATUS_UNKNOWN"
			fi
			print_info "[lifecycle] pre_dispatch_rotate: ${provider} ${identity_label} -> ${new_label}"
		else
			print_warning "[lifecycle] pre_dispatch_rotate failed for ${provider}; continuing with current account"
		fi
	fi

	return 0
}

#######################################
# Return whether startup output contains an attributable provider failure that
# should stop a worker before its first model event. Reuse the canonical trusted
# classifier so IDs, paths, tool output, and other incidental text cannot create
# provider backoff.
#
# Args:
#   $1 output_file — worker startup output
#
# Returns: 0 for trusted rate-limit/quota/server failures, 1 otherwise.
#######################################
_output_has_trusted_fast_provider_failure() {
	local output_file="$1"
	local classification=""
	local reason="" provider_type="" provider_status="" classification_source="" classification_pattern=""

	[[ -f "$output_file" ]] || return 1
	classification=$(_classify_trusted_provider_failure "$output_file" 2>/dev/null) || return 1
	[[ -n "$classification" ]] || return 1
	IFS=$'\t' read -r reason provider_type provider_status classification_source classification_pattern <<<"$classification"

	case "$reason" in
	rate_limit | quota_exceeded)
		return 0
		;;
	provider_error)
		[[ "$provider_type" == "server_error" ]] && return 0
		;;
	esac
	return 1
}

#######################################
# _launch_rate_limit_fast_monitor: background 30s sentinel that detects
# Anthropic 429 / provider-overload patterns on the FIRST API call and
# kills the worker cleanly before the 20-min opencode retry zombie forms.
#
# GH#21578 / t3021 — Three simultaneous workers were killed at t=20min
# (exit 143, duration_ms ~1.2M) because opencode silently retried a 429
# for the full slot lifetime. Each zombie blocked one dispatch slot.
#
# Strategy: poll output_file every 5s for monitor_window seconds (default 30).
# If rate-limit / HTTP-5xx patterns appear AND the worker produced no LLM
# activity yet (JSON events), SIGTERM the worker, write exit_code=0 and the
# .rate_limit_fast sentinel next to exit_code_file, then exit.
# _execute_run_attempt reads the sentinel and routes to exit 80, which
# cmd_run handles without incrementing the fast-fail / NMR counter.
#
# Args:
#   $1 output_file      — tee'd worker output file to monitor
#   $2 worker_pid       — the worker subshell PID to kill on detection
#   $3 exit_code_file   — path for writing exit_code=0 + creating sentinel
#   $4 monitor_window   — seconds to watch (default: 30)
#
# Returns: 0 always (launched in background; caller captures PID via $!)
#######################################
_launch_rate_limit_fast_monitor() {
	local output_file="$1"
	local worker_pid="$2"
	local exit_code_file="$3"
	local monitor_window="${4:-30}"
	local poll_interval=5

	(
		set +e
		local elapsed=0
		local sentinel="${exit_code_file}.rate_limit_fast"
		local activity_detected=""

		while [[ "$elapsed" -lt "$monitor_window" ]]; do
			sleep "$poll_interval"
			elapsed=$((elapsed + poll_interval))

			# Exit cleanly if the worker already finished on its own.
			if ! kill -0 "$worker_pid" 2>/dev/null; then
				return 0
			fi

			# Only fire if no LLM activity has been produced yet.
			# If the model already started working (step_start, tool, etc.),
			# this is not a dead-on-arrival rate limit — let the watchdog handle it.
			activity_detected=$(output_has_activity "$output_file" 2>/dev/null) || activity_detected="0"
			if [[ "$activity_detected" == "1" ]]; then
				return 0
			fi

			# Only canonical, attributable provider evidence may stop the worker.
			if _output_has_trusted_fast_provider_failure "$output_file"; then
				# Kill the worker cleanly — this is a transient API condition.
				kill -TERM "$worker_pid" 2>/dev/null || true
				sleep 2
				kill -0 "$worker_pid" 2>/dev/null && kill -KILL "$worker_pid" 2>/dev/null || true
				# Signal _execute_run_attempt to route as rate_limit_fast (exit 80).
				printf '%s' "0" >"$exit_code_file" 2>/dev/null || true
				printf '%s' "1" >"$sentinel" 2>/dev/null || true
				return 0
			fi
		done
		return 0
	) &
	printf '%s' "$!"
	return 0
}

# =============================================================================
# Claude CLI invocation
# =============================================================================

# _invoke_claude: run the claude CLI command and capture output.
# Same interface shape as _invoke_opencode (output/exit_code first), with an
# additional work_dir slot so the caller can set the child cwd via shell
# rather than a CLI flag.
#
# GH#21886: Claude CLI has no --cwd / --directory / --working-directory
# flag. Setting cwd MUST happen via `cd` in the parent shell before exec.
# This function isolates the cd in a subshell so it does not pollute the
# caller's PWD. A work directory is required, matching the public run command;
# inherited cwd must not stand in for explicit lifecycle context.
#
# GH#33117: the sandboxed path normalizes the process-scoped signing and
# repository-bound Git-auth environment exactly like
# _invoke_opencode_run_sandboxed (headless-runtime-invoke.sh), failing closed
# with exit 87/88 when either cannot be isolated. Without this, ambient
# GIT_CONFIG_* entries ahead of the signing entries make the passthrough drop
# the dedicated signing config and the worker signs with the global key.
#
# Args: output_file exit_code_file work_dir cmd_args...
_invoke_claude() {
	local output_file="$1"
	local exit_code_file="$2"
	local work_dir="$3"
	shift 3
	local -a cmd=("$@")
	if [[ -z "$work_dir" ]]; then
		print_error "Worker launch requires an explicit work directory"
		printf '%s' "75" >"$exit_code_file"
		return 0
	fi

	(
		set +e
		local egress_mode="${AIDEVOPS_WORKER_EGRESS_MODE:-auto}"
		local egress_worker_id="${AIDEVOPS_WORKER_ID:-${_invoke_session_key:-headless}}"
		local lifecycle_status=0 private_workload=0
		local lifecycle_worktree="$work_dir"
		if [[ -n "$lifecycle_worktree" && "$lifecycle_worktree" != /* ]]; then
			lifecycle_worktree="${PWD%/}/$lifecycle_worktree"
		fi
		if _headless_private_workload_enabled; then
			private_workload=1
		fi
		# shellcheck source=worker-lifecycle-state.sh
		source "${SCRIPT_DIR}/worker-lifecycle-state.sh"
		worker_lifecycle_prepare_launch "$lifecycle_worktree" "${SCRIPT_DIR}/../worker-lifecycle/worker-launch.py" "$private_workload" || lifecycle_status=$?
		if [[ "$lifecycle_status" -ne 0 ]]; then
			printf '%s' "$lifecycle_status" >"$exit_code_file"
			exit "$lifecycle_status"
		fi
		# Set child cwd via shell since claude CLI has no flag for it.
		if [[ -n "$work_dir" ]]; then
			if ! cd "$work_dir"; then
				print_error "_invoke_claude: cd '$work_dir' failed (GH#21886)"
				printf '%s' "1" >"$exit_code_file"
				exit 1
			fi
		fi
		if [[ -x "$SANDBOX_EXEC_HELPER" && "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" != "1" ]]; then
			# The sandbox entry owns admission; do not wrap the command twice.
			export AIDEVOPS_LIFECYCLE_WORKTREE="$lifecycle_worktree"
			export AIDEVOPS_PRIVATE_WORKLOAD="$private_workload"
			local passthrough_csv=""
			local runtime_role="${_invoke_role:-worker}"
			if ! prepare_headless_signing_sandbox_env "$runtime_role"; then
				print_error "Headless signing configuration could not be safely isolated for the sandbox"
				printf '%s' "87" >"$exit_code_file"
				exit 87
			fi
			if ! prepare_headless_git_auth_sandbox_env "$runtime_role"; then
				print_error "Repository-bound worker Git authentication could not be safely isolated for the sandbox"
				printf '%s' "88" >"$exit_code_file"
				exit 88
			fi
			passthrough_csv="$(build_sandbox_passthrough_csv "${_invoke_provider:-}" "$runtime_role")"
			if [[ -n "$passthrough_csv" ]]; then
				if [[ -n "${_HEADLESS_CLAUDE_STDIN_FILE:-}" && -f "${_HEADLESS_CLAUDE_STDIN_FILE:-}" ]]; then
					"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --egress-mode "$egress_mode" --worker-id "$egress_worker_id" --passthrough "$passthrough_csv" -- "${cmd[@]}" <"$_HEADLESS_CLAUDE_STDIN_FILE" 2>&1 | tee "$output_file"
				else
					"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --egress-mode "$egress_mode" --worker-id "$egress_worker_id" --passthrough "$passthrough_csv" -- "${cmd[@]}" 2>&1 | tee "$output_file"
				fi
			else
				if [[ -n "${_HEADLESS_CLAUDE_STDIN_FILE:-}" && -f "${_HEADLESS_CLAUDE_STDIN_FILE:-}" ]]; then
					"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --egress-mode "$egress_mode" --worker-id "$egress_worker_id" -- "${cmd[@]}" <"$_HEADLESS_CLAUDE_STDIN_FILE" 2>&1 | tee "$output_file"
				else
					"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --egress-mode "$egress_mode" --worker-id "$egress_worker_id" -- "${cmd[@]}" 2>&1 | tee "$output_file"
				fi
			fi
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		else
			if [[ "$egress_mode" == "required" ]]; then
				print_error "Whole-process worker egress is required, but the sandbox launcher is disabled or unavailable"
				printf '%s' "126" >"$exit_code_file"
				exit 126
			fi
			if [[ "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" == "1" ]]; then
				print_info "AIDEVOPS_HEADLESS_SANDBOX_DISABLED=1 — using bare timeout (no privilege isolation) (GH#20146 audit)"
			fi
			cmd=(${WORKER_LIFECYCLE_PREFIX[@]+"${WORKER_LIFECYCLE_PREFIX[@]}"} "${cmd[@]}")
			if [[ -n "${_HEADLESS_CLAUDE_STDIN_FILE:-}" && -f "${_HEADLESS_CLAUDE_STDIN_FILE:-}" ]]; then
				timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" "${cmd[@]}" <"$_HEADLESS_CLAUDE_STDIN_FILE" 2>&1 | tee "$output_file"
			else
				timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" "${cmd[@]}" 2>&1 | tee "$output_file"
			fi
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		fi
	) || true
	return 0
}

# =============================================================================
# Output preservation and classification
# =============================================================================

#######################################
# t2119: Preserve a worker output file on no_activity failure so operators
# can diagnose why the runtime exited without ever producing JSON events.
#
# Before t2119, _handle_run_result unconditionally `rm -f "$output_file"`
# on the no_activity path, erasing the only forensic evidence (opencode
# stderr via tee, plugin startup log lines, sandbox exec trace). This
# left the residual 30s failures observed in the t2116 session with zero
# diagnostic surface.
#
# Strategy: move (not copy — keeps disk usage bounded) the output file
# to ~/.aidevops/logs/worker-no-activity/<session>-<ts>.log. Size-cap
# each preserved file to 256KB (worker output files rarely exceed this;
# truncation is fine for forensic purposes). Retention-cap the directory
# to the 50 most recent files so the log directory doesn't grow
# unbounded on a looping failure.
#
# Best-effort throughout — a preservation failure must never propagate
# into the caller's error-handling path. The goal is forensics, not
# hard-guaranteed persistence.
#
# Args:
#   $1 - output_file path
#   $2 - session_key (e.g. issue-19114 or pulse)
#   $3 - model (for filename disambiguation; slashes stripped)
#######################################
_preserve_no_activity_output() {
	local output_file="$1"
	local session_key="${2:-unknown}"
	local model="${3:-unknown}"

	if [[ -z "$output_file" || ! -f "$output_file" ]]; then
		return 0
	fi
	if _headless_private_workload_enabled; then
		rm -f "$output_file" 2>/dev/null || true
		return 0
	fi

	local diag_dir="${HOME}/.aidevops/logs/worker-no-activity"
	if ! mkdir -p "$diag_dir" 2>/dev/null; then
		# Fall back to the original delete behaviour if the diagnostic
		# directory can't be created — we must not keep tmp files around.
		rm -f "$output_file" 2>/dev/null || true
		return 0
	fi

	# Sanitize session + model for use in a filename.
	local safe_session safe_model
	safe_session=$(printf '%s' "$session_key" | tr '/ ' '__' | tr -cd 'A-Za-z0-9._-' | cut -c1-64)
	safe_model=$(printf '%s' "$model" | tr '/ ' '__' | tr -cd 'A-Za-z0-9._-' | cut -c1-32)
	[[ -n "$safe_session" ]] || safe_session="$_HRW_STATUS_UNKNOWN"
	[[ -n "$safe_model" ]] || safe_model="$_HRW_STATUS_UNKNOWN"

	local ts
	ts=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)
	local dest="${diag_dir}/${ts}-${safe_session}-${safe_model}.log"

	# Size-cap: take the first 256KB of the output. For the no_activity
	# failure mode the interesting content (plugin init errors, opencode
	# startup logs, migration output, auth refresh messages) always
	# lands in the first few KB; anything past 256KB is noise.
	local max_bytes=262144
	if head -c "$max_bytes" "$output_file" >"$dest" 2>/dev/null; then
		local orig_size
		orig_size=$(wc -c <"$output_file" 2>/dev/null | tr -d ' ') || orig_size=0
		if [[ "$orig_size" -gt "$max_bytes" ]]; then
			printf '\n\n[...t2119 TRUNCATED at %d bytes, original %d bytes...]\n' \
				"$max_bytes" "$orig_size" >>"$dest" 2>/dev/null || true
		fi
	fi

	rm -f "$output_file" 2>/dev/null || true

	# Retention cap: keep the 50 most recent preserved files.
	# ls -t returns newest first; tail -n +51 selects everything beyond the cap.
	# Using find -print0 | sort would be more robust but ls is enough for
	# our flat directory of predictable filenames.
	local keep=50
	local prune_list
	prune_list=$(cd "$diag_dir" 2>/dev/null && ls -1t -- *.log 2>/dev/null | tail -n +$((keep + 1))) || prune_list=""
	if [[ -n "$prune_list" ]]; then
		while IFS= read -r _victim; do
			[[ -n "$_victim" ]] || continue
			rm -f "${diag_dir}/${_victim}" 2>/dev/null || true
		done <<<"$prune_list"
	fi

	return 0
}
