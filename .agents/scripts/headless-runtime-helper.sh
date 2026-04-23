#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# headless-runtime-helper.sh - Model-aware OpenCode wrapper for pulse/workers
#
# Features:
#   - Alternates between configured headless providers/models
#   - Persists OpenCode session IDs per provider + session key
#   - Records backoff state per model (rate limits) or per provider (auth errors)
#   - Clears backoff automatically when auth changes or retry windows expire
#   - NOTE: opencode/* gateway models are NOT used (per-token billing, too expensive)
#
# Stable utility functions (state DB, provider auth, backoff, output parsing,
# metrics, sandbox, contract, watchdog, model choice, cmd builders) live in
# headless-runtime-lib.sh — sourced below. This file is the thin orchestrator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./worker-lifecycle-common.sh
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

# SSH agent integration for commit signing (t1882)
# Source persisted agent.env so workers can sign commits without passphrase prompts.
if [[ -f "$HOME/.ssh/agent.env" ]]; then
	# shellcheck source=/dev/null
	. "$HOME/.ssh/agent.env" >/dev/null 2>&1 || true
fi

# Absolute fallback when both pool and routing table are unavailable (GH#17769)
readonly DEFAULT_HEADLESS_MODELS="anthropic/claude-sonnet-4-6"
readonly STATE_DIR="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
readonly STATE_DB="${STATE_DIR}/state.db"
readonly OPENCODE_BIN_DEFAULT="${OPENCODE_BIN:-opencode}"
readonly SANDBOX_EXEC_HELPER="${SCRIPT_DIR}/sandbox-exec-helper.sh"
readonly DISPATCH_LEDGER_HELPER="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
readonly OAUTH_POOL_HELPER="${SCRIPT_DIR}/oauth-pool-helper.sh"
readonly HEADLESS_SANDBOX_TIMEOUT_DEFAULT="${AIDEVOPS_HEADLESS_SANDBOX_TIMEOUT:-3600}"
readonly OPENCODE_AUTH_FILE="${HOME}/.local/share/opencode/auth.json"
readonly LOCK_DIR="${STATE_DIR}/locks"
readonly METRICS_DIR="${HOME}/.aidevops/logs"
readonly METRICS_FILE="${METRICS_DIR}/headless-runtime-metrics.jsonl"

# Source the stable utility library (t2013 split).
# All state DB, provider auth, backoff, output parsing, metrics, sandbox,
# worker contract, watchdog, DB merge, dispatch ledger, failure reporting,
# canary, model choice, and cmd builder functions live here.
# shellcheck source=./headless-runtime-lib.sh
source "${SCRIPT_DIR}/headless-runtime-lib.sh"

# Activity watchdog timeout — used by _invoke_opencode and the inline watchdog fallback.
HEADLESS_ACTIVITY_TIMEOUT_SECONDS="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-300}"

# =============================================================================
# CLI subcommands — select, backoff, session
# =============================================================================

cmd_select() {
	local role="worker"
	local model_override=""
	local tier_override=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--role)
			role="${2:-}"
			shift 2
			;;
		--model)
			model_override="${2:-}"
			shift 2
			;;
		--tier)
			tier_override="${2:-}"
			shift 2
			;;
		*)
			print_error "Unknown option for select: $1"
			return 1
			;;
		esac
	done

	# When a tier is specified, resolve the concrete model for that tier and
	# use it as the explicit model override. This ensures the round-robin
	# selects from the correct tier's model pool (e.g., haiku for tier:simple,
	# opus for tier:thinking) rather than always defaulting to sonnet.
	if [[ -n "$tier_override" && -z "$model_override" ]]; then
		local tier_model=""
		tier_model=$(resolve_model_tier "$tier_override" 2>/dev/null) || tier_model=""
		if [[ -n "$tier_model" ]]; then
			model_override="$tier_model"
		fi
	fi

	local selected
	selected=$(choose_model "$role" "$model_override") || return $?
	printf '%s\n' "$selected"
	return 0
}

cmd_backoff() {
	local action="${1:-status}"
	shift || true
	case "$action" in
	status)
		db_query "SELECT provider || '|' || reason || '|' || retry_after || '|' || updated_at FROM provider_backoff ORDER BY provider;"
		return 0
		;;
	clear)
		local key="${1:-}"
		[[ -n "$key" ]] || {
			print_error "Usage: backoff clear <provider-or-model>"
			return 1
		}
		clear_provider_backoff "$key"
		return 0
		;;
	set)
		local key="${1:-}"
		local reason="${2:-provider_error}"
		local retry_seconds="${3:-300}"
		[[ -n "$key" ]] || {
			print_error "Usage: backoff set <provider-or-model> <reason> [retry_seconds]"
			return 1
		}
		local provider
		provider=$(extract_provider "$key" 2>/dev/null || printf '%s' "$key")
		local tmp_file
		tmp_file=$(mktemp)
		printf 'manual backoff %s %s %s\n' "$key" "$reason" "$retry_seconds" >"$tmp_file"
		record_provider_backoff "$provider" "$reason" "$tmp_file" "$key"
		if [[ "$retry_seconds" != "300" ]]; then
			if [[ ! "$retry_seconds" =~ ^[0-9]+$ ]]; then
				print_error "retry_seconds must be an integer"
				return 1
			fi
			local retry_after
			retry_after=$(date -u -v+"${retry_seconds}"S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "+${retry_seconds} seconds" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "")
			db_query "UPDATE provider_backoff SET retry_after = '$(sql_escape "$retry_after")' WHERE provider = '$(sql_escape "$key")';" >/dev/null
		fi
		rm -f "$tmp_file"
		return 0
		;;
	*)
		print_error "Unknown backoff action: $action"
		return 1
		;;
	esac
}

cmd_session() {
	local action="${1:-status}"
	shift || true
	case "$action" in
	status)
		db_query "SELECT provider || '|' || session_key || '|' || session_id || '|' || model || '|' || updated_at FROM provider_sessions ORDER BY provider, session_key;"
		return 0
		;;
	clear)
		local provider="${1:-}"
		local session_key="${2:-}"
		[[ -n "$provider" && -n "$session_key" ]] || {
			print_error "Usage: session clear <provider> <session_key>"
			return 1
		}
		db_query "DELETE FROM provider_sessions WHERE provider = '$(sql_escape "$provider")' AND session_key = '$(sql_escape "$session_key")';" >/dev/null
		return 0
		;;
	*)
		print_error "Unknown session action: $action"
		return 1
		;;
	esac
}

# =============================================================================
# Run argument parsing and validation
# =============================================================================

# _parse_run_args: parse cmd_run flags into caller-scoped variables.
# Caller must declare: role session_key work_dir title prompt prompt_file
#                      model_override tier_override variant_override agent_name extra_args
# Returns 1 on unknown flag.
_parse_run_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--role)
			role="${2:-}"
			shift 2
			;;
		--session-key)
			session_key="${2:-}"
			shift 2
			;;
		--dir)
			work_dir="${2:-}"
			shift 2
			;;
		--title)
			title="${2:-}"
			shift 2
			;;
		--prompt)
			prompt="${2:-}"
			shift 2
			;;
		--prompt-file)
			prompt_file="${2:-}"
			shift 2
			;;
		--model)
			model_override="${2:-}"
			shift 2
			;;
		--tier)
			tier_override="${2:-}"
			shift 2
			;;
		--variant)
			variant_override="${2:-}"
			shift 2
			;;
		--agent)
			agent_name="${2:-}"
			shift 2
			;;
		--runtime)
			# Explicit runtime override: "opencode" (default), "claude", etc.
			headless_runtime="${2:-}"
			shift 2
			;;
		--opencode-arg)
			extra_args+=("${2:-}")
			shift 2
			;;
		--detach)
			detach=1
			shift
			;;
		*)
			print_error "Unknown option for run: $1"
			return 1
			;;
		esac
	done
	return 0
}

# _validate_run_args: check required fields and resolve prompt from file if needed.
# Operates on caller-scoped variables set by _parse_run_args.
_validate_run_args() {
	[[ -n "$session_key" ]] || {
		print_error "run requires --session-key"
		return 1
	}
	[[ -n "$work_dir" ]] || {
		print_error "run requires --dir"
		return 1
	}
	[[ -n "$title" ]] || {
		print_error "run requires --title"
		return 1
	}
	if [[ -z "$prompt" && -n "$prompt_file" ]]; then
		[[ -f "$prompt_file" ]] || {
			print_error "Prompt file not found: $prompt_file"
			return 1
		}
		prompt=$(<"$prompt_file")
	fi
	[[ -n "$prompt" ]] || {
		print_error "run requires --prompt or --prompt-file"
		return 1
	}
	return 0
}

# =============================================================================
# Runtime invocation — OpenCode and Claude CLI
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
	# Log-friendly identity: prefer email, fall back to a short access-token
	# fingerprint. Never log full access tokens (they are secrets).
	if [[ -n "$current_email" ]]; then
		identity_label="$current_email"
	else
		identity_label="access=${current_access:0:8}…"
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
			if [[ -n "$new_email" ]]; then
				new_label="$new_email"
			elif [[ -n "$new_access" ]]; then
				new_label="access=${new_access:0:8}…"
			else
				new_label="unknown"
			fi
			print_info "[lifecycle] pre_dispatch_rotate: ${provider} ${identity_label} -> ${new_label}"
		else
			print_warning "[lifecycle] pre_dispatch_rotate failed for ${provider}; continuing with current account"
		fi
	fi

	return 0
}

# _invoke_opencode: run the opencode command (with or without sandbox) and capture output.
# Args: output_file exit_code_file cmd_args (null-delimited, read from stdin via process sub)
# Caller passes the cmd array elements as positional args after the two file args.
# Returns: 0 always (exit code written to exit_code_file).
#
# Includes an activity watchdog: if no LLM activity appears in the output
# file within HEADLESS_ACTIVITY_TIMEOUT_SECONDS (default 300s), the opencode
# process is killed. This catches rate-limited providers that cause the
# worker to hang indefinitely waiting for an API response. Without this,
# stalled workers consume slots permanently and rotation never fires
# (because the retry logic only runs after the process exits).
# GH#17442: increased from 90s to 300s — with 335 agents in the system
# prompt, OpenCode needs 60-120s to initialize before first model output.
_invoke_opencode() {
	local output_file="$1"
	local exit_code_file="$2"
	shift 2
	local -a cmd=("$@")

	# Auth isolation for headless workers: each worker gets its own copy of
	# auth.json via XDG_DATA_HOME redirection. opencode uses
	# $XDG_DATA_HOME/opencode/auth.json for OAuth tokens. Without isolation,
	# headless workers share the interactive session's auth file — when ANY
	# worker's opencode process refreshes an expired access token, it writes
	# a new token to the shared file, invalidating the interactive session's
	# in-flight request and crashing it.
	#
	# IMPORTANT: XDG_DATA_HOME redirection moves the ENTIRE opencode data dir,
	# including the session database. We set OPENCODE_DB to point back to the
	# shared DB so worker sessions are visible to stats/session-time queries
	# while auth remains isolated.
	#
	# The isolated dir is per-PID and cleaned up after the worker exits.
	local isolated_data_dir=""
	if [[ "${AIDEVOPS_HEADLESS_AUTH_ISOLATION:-1}" == "1" ]]; then
		# t2758: Reuse pre-warmed isolated DB dir if the dispatcher already ran
		# opencode --version against it to trigger migration + skill-dedup.
		# Falls back to a fresh mktemp when pre-warming was skipped or failed.
		if [[ -n "${AIDEVOPS_WORKER_PREWARM_DIR:-}" && -d "${AIDEVOPS_WORKER_PREWARM_DIR:-}" ]]; then
			isolated_data_dir="$AIDEVOPS_WORKER_PREWARM_DIR"
			print_info "[lifecycle] opencode_warm_done dir=$isolated_data_dir (reusing pre-warmed dir) pid=$$"
		else
			isolated_data_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-worker-auth.XXXXXX")
		fi
		mkdir -p "${isolated_data_dir}/opencode"
		# Copy the current auth.json so the worker has valid tokens at startup
		if [[ -f "$OPENCODE_AUTH_FILE" ]]; then
			cp "$OPENCODE_AUTH_FILE" "${isolated_data_dir}/opencode/auth.json" 2>/dev/null || true
			chmod 600 "${isolated_data_dir}/opencode/auth.json" 2>/dev/null || true
		fi
		# GH#17549: Each worker gets its OWN SQLite DB (no shared OPENCODE_DB).
		# Previously we set OPENCODE_DB back to the shared DB for session stats,
		# but concurrent workers with busy_timeout=0 cause SQLITE_BUSY which
		# silently kills streaming connections — workers stall at step_start
		# with zero API errors. Session stats are sacrificed for reliability.
		export XDG_DATA_HOME="$isolated_data_dir"
		print_info "[lifecycle] db_isolated dir=$isolated_data_dir pid=$$"

		# t2249: Pre-dispatch OAuth pool check. If the account copied into the
		# isolated auth.json is in cooldown per shared pool metadata (recorded
		# by a prior worker's mark-failure), rotate the isolated file to a
		# healthy account BEFORE opencode spawns. Best-effort: failure here
		# must not block dispatch — opencode will then retry via its normal
		# backoff path. Only runs when isolation is active (XDG_DATA_HOME is
		# set above), so this cannot corrupt a shared interactive auth.json.
		#
		# Provider is resolved from the caller's selected_model (set on
		# _invoke_provider by _execute_run_attempt). Hardcoding "anthropic"
		# here would skip rotation for openai/google/cursor workers, so they
		# would still burn dispatches on cooldown-marked accounts in those
		# pools. Defaulting to "anthropic" keeps legacy callers (tests,
		# diagnostics) working when _invoke_provider is unset.
		if [[ -f "${isolated_data_dir}/opencode/auth.json" ]]; then
			_maybe_rotate_isolated_auth "${isolated_data_dir}/opencode/auth.json" "${_invoke_provider:-anthropic}"
		fi
	fi

	# Run in subshell to avoid fragile set +e/set -e toggling (GH#4225).
	# Subshell localises errexit so main shell state is never modified.
	# Exit code is written to a temp file — NOT captured via $() — because
	# tee stdout would contaminate the $() capture (bash 3.2 has no clean
	# way to separate tee output from the exit code in a single $()).
	(
		set +e
		# Inject --print-logs for headless workers so opencode's internal Go logs
		# (API errors, model resolution, DB writes) appear in the worker log.
		# This is critical for diagnosing silent exits — the JSON event stream
		# shows step_start then nothing, but the Go logs show the actual error.
		local -a _oc_cmd=("${cmd[@]}")
		if [[ "${HEADLESS:-}" == "1" ]]; then
			# Insert --print-logs after the 'run' subcommand
			local -a _new_cmd=()
			local _inserted=0
			for _arg in "${_oc_cmd[@]}"; do
				_new_cmd+=("$_arg")
				if [[ "$_arg" == "run" && "$_inserted" -eq 0 ]]; then
					_new_cmd+=("--print-logs" "--log-level" "WARN")
					_inserted=1
				fi
			done
			_oc_cmd=("${_new_cmd[@]}")
		fi
		if [[ -x "$SANDBOX_EXEC_HELPER" && "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" != "1" ]]; then
			local passthrough_csv
			passthrough_csv="$(build_sandbox_passthrough_csv)"
			# --stream-stdout: let child stdout flow through the pipe to tee
			# so the activity watchdog can monitor output in real-time
			# (GH#15180 bug #4). Without this, the sandbox captures stdout to
			# a temp file and replays it after exit — the watchdog sees nothing
			# and kills every sandboxed worker at ~93s.
			if [[ -n "$passthrough_csv" ]]; then
				"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --stream-stdout --passthrough "$passthrough_csv" -- "${_oc_cmd[@]}" 2>&1 | tee "$output_file"
			else
				"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --stream-stdout -- "${_oc_cmd[@]}" 2>&1 | tee "$output_file"
			fi
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		else
			if [[ "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" == "1" ]]; then
				print_info "AIDEVOPS_HEADLESS_SANDBOX_DISABLED=1 — using bare timeout (no privilege isolation) (GH#20146 audit)"
			fi
			timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" "${_oc_cmd[@]}" 2>&1 | tee "$output_file"
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		fi
	) &
	local worker_pid=$!

	# Activity watchdog: monitor the output file for LLM activity.
	# If no activity appears within the timeout, the provider is likely
	# rate-limited and the worker will hang indefinitely. Kill it so the
	# retry loop in cmd_run can rotate to the next provider.
	#
	# GH#17648: Launch as a STANDALONE process via nohup, not a backgrounded
	# function. The previous `_run_activity_watchdog ... &` died silently when
	# nohup changed the subshell's process group — stalled workers sat forever.
	# The standalone script has its own process lifecycle, independent of the
	# worker subshell.
	local _watchdog_script="${SCRIPT_DIR}/worker-activity-watchdog.sh"
	local watchdog_pid=""
	local _stall_timeout="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-600}"
	[[ "$_stall_timeout" =~ ^[0-9]+$ ]] || _stall_timeout=600
	local _phase1_timeout="${HEADLESS_PHASE1_TIMEOUT_SECONDS:-60}"
	[[ "$_phase1_timeout" =~ ^[0-9]+$ ]] || _phase1_timeout=60

	if [[ -x "$_watchdog_script" ]]; then
		nohup "$_watchdog_script" \
			--output-file "$output_file" \
			--worker-pid "$worker_pid" \
			--exit-code-file "$exit_code_file" \
			--session-key "${_invoke_session_key:-}" \
			--repo-slug "${DISPATCH_REPO_SLUG:-}" \
			--stall-timeout "$_stall_timeout" \
			--phase1-timeout "$_phase1_timeout" \
			</dev/null >/dev/null 2>&1 &
		watchdog_pid=$!
		print_info "[lifecycle] activity_watchdog_started pid=$watchdog_pid worker=$worker_pid stall_timeout=${_stall_timeout}s"
	else
		# Fallback: use inline function if standalone script is missing
		# (should not happen in normal deployment)
		print_warning "[lifecycle] standalone watchdog not found at $_watchdog_script — falling back to inline"
		_run_activity_watchdog "$output_file" "$worker_pid" "$exit_code_file" "$_invoke_session_key" &
		watchdog_pid=$!
	fi

	# Wait for the worker to finish (watchdog will kill it if stalled)
	print_info "[lifecycle] waiting_for_worker pid=$worker_pid watchdog=$watchdog_pid"
	local _wait_status=0
	wait "$worker_pid" 2>/dev/null || _wait_status=$?
	print_info "[lifecycle] worker_exited pid=$worker_pid wait_status=$_wait_status"

	# Clean up the watchdog — it should exit on its own when it detects
	# the worker PID is gone, but kill it explicitly to be safe.
	if [[ -n "$watchdog_pid" ]]; then
		kill "$watchdog_pid" 2>/dev/null || true
		wait "$watchdog_pid" 2>/dev/null || true
	fi
	print_info "[lifecycle] watchdog_cleaned pid=$watchdog_pid"

	# Merge worker session data back to shared DB, then clean up.
	# Worker is done — no contention, single-writer merge is safe.
	if [[ -n "$isolated_data_dir" && -d "$isolated_data_dir" ]]; then
		if _merge_worker_db "$isolated_data_dir"; then
			print_info "[lifecycle] db_merged dir=$isolated_data_dir pid=$$"
		else
			print_warning "[lifecycle] db_merge_failed dir=$isolated_data_dir pid=$$"
		fi
		rm -rf "$isolated_data_dir" 2>/dev/null || true
		unset XDG_DATA_HOME
		print_info "[lifecycle] db_cleanup dir=$isolated_data_dir pid=$$"
	fi

	print_info "[lifecycle] invoke_opencode_returning pid=$$"
	return 0
}

# _invoke_claude: run the claude CLI command and capture output.
# Same interface as _invoke_opencode for interchangeability.
# Args: output_file exit_code_file cmd_args...
_invoke_claude() {
	local output_file="$1"
	local exit_code_file="$2"
	shift 2
	local -a cmd=("$@")

	(
		set +e
		if [[ -x "$SANDBOX_EXEC_HELPER" && "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" != "1" ]]; then
			local passthrough_csv
			passthrough_csv="$(build_sandbox_passthrough_csv)"
			if [[ -n "$passthrough_csv" ]]; then
				"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --passthrough "$passthrough_csv" -- "${cmd[@]}" 2>&1 | tee "$output_file"
			else
				"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io -- "${cmd[@]}" 2>&1 | tee "$output_file"
			fi
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		else
			if [[ "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" == "1" ]]; then
				print_info "AIDEVOPS_HEADLESS_SANDBOX_DISABLED=1 — using bare exec (no privilege isolation) (GH#20146 audit)"
			fi
			"${cmd[@]}" 2>&1 | tee "$output_file"
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		fi
	) || true
	return 0
}

# =============================================================================
# Result handling and run execution
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
	[[ -n "$safe_session" ]] || safe_session="unknown"
	[[ -n "$safe_model" ]] || safe_model="unknown"

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

# _handle_run_result: process output_file after opencode exits.
# Args: exit_code output_file role provider session_key selected_model
# Sets caller variable _run_failure_reason on failure.
# Returns: 0 success, 75 no-activity backoff, 77 premature exit, non-zero on failure.
_handle_run_result() {
	local exit_code="$1"
	local output_file="$2"
	local role="$3"
	local provider="$4"
	local session_key="$5"
	local selected_model="$6"

	local discovered_session activity_detected
	discovered_session=$(extract_session_id_from_output "$output_file")
	activity_detected=$(output_has_activity "$output_file")
	_run_activity_detected="$activity_detected"
	_run_result_label="failed"

	if [[ "$exit_code" -eq 0 ]]; then
		if [[ "$activity_detected" != "1" ]]; then
			_run_result_label="no_activity"
			# Do NOT record provider backoff for no_activity. Exit 0 with no LLM
			# output can be caused by local issues (bad prompt, sandbox problem,
			# opencode bug) — not the provider's fault. Recording provider_error
			# here falsely flags healthy providers as rate-limited, causing the
			# pre-dispatch check to skip them and starve the worker pool.
			# The activity watchdog (exit 124) handles genuine provider failures.
			#
			# t2119: preserve the output file for post-mortem forensics instead
			# of deleting it. Workers that die in setup with exit 0 + no JSON
			# events leave no other trace of WHY they died — not in observability
			# DB (never reached the model), not in pulse.log, not in the
			# session DB (never created one). The output file captured by tee is
			# the only place plugin/runtime stderr lands. Moving it to a
			# retention-capped diagnostics dir lets operators actually diagnose
			# the residual 30s no_activity failures that the t2116-session
			# plist-reload fix didn't fully resolve.
			_preserve_no_activity_output "$output_file" "$session_key" "$selected_model"
			print_warning "$selected_model returned exit 0 without any model activity (no backoff recorded — forensic copy preserved via t2119)"
			return 75
		fi
		# Store session ID for potential continuation (before deleting output)
		if [[ "$role" != "pulse" && -n "$discovered_session" ]]; then
			store_session_id "$provider" "$session_key" "$discovered_session" "$selected_model"
		fi

		# GH#17436: Check for premature exit — worker produced activity (tool
		# calls) but stopped without completing (no PR, no FULL_LOOP_COMPLETE,
		# no BLOCKED). This is the #1 GPT-5.4 failure mode: reads issue, creates
		# worktree, then exits without writing code. Previously classified as
		# "success" which prevented fast-fail escalation from ever triggering.
		#
		# Only check implementation workers (session_key=issue-*), not pulse
		# or triage sessions which don't produce PR completion signals.
		if [[ "$role" == "worker" && "$session_key" == issue-* ]]; then
			if ! output_has_completion_signal "$output_file"; then
				# Diagnose empty tool results that may have caused the model to stop.
				# Each is a closeable gap (wrong path, missing prefix, moved file).
				_log_empty_result_gaps "$output_file" "$selected_model" "$session_key"

				_run_result_label="premature_exit"
				rm -f "$output_file"
				print_warning "$selected_model worker exited with activity but no completion signal (premature exit — will attempt continuation)"
				return 77
			fi
		fi

		_run_result_label="success"
		rm -f "$output_file"
		return 0
	fi

	local failure_reason
	# Exit code 124 = activity watchdog timeout (stall or dead runtime).
	#
	# GH#17648: Distinguish "stall with prior activity" from "dead on arrival".
	# A mid-session stall (stream drop after the model was working) should try
	# continuation — the model may have created a worktree, written files, etc.
	# Killing and starting fresh wastes all that context.
	#
	# - 124 + activity → return 78 (watchdog_stall_continue) so the retry loop
	#   can resume the session with a continuation prompt before giving up.
	# - 124 + no activity → rate_limit as before (provider never responded).
	if [[ "$exit_code" -eq 124 ]]; then
		if [[ "$activity_detected" == "1" ]]; then
			# Worker was making progress, then stalled (stream drop, hung connection).
			# Store session ID for continuation before deleting output.
			local discovered_session_for_continue
			discovered_session_for_continue=$(extract_session_id_from_output "$output_file")
			if [[ "$role" != "pulse" && -n "$discovered_session_for_continue" ]]; then
				store_session_id "$provider" "$session_key" "$discovered_session_for_continue" "$selected_model"
			fi
			_run_result_label="watchdog_stall_continue"
			rm -f "$output_file"
			print_warning "$selected_model watchdog stall with prior activity — will attempt session continuation"
			return 78
		fi
		failure_reason="rate_limit"
		print_warning "$selected_model activity watchdog timeout (no activity) — classifying as rate_limit for rotation"
	else
		failure_reason=$(classify_failure_reason "$output_file")
	fi
	_run_result_label="$failure_reason"

	if attempt_pool_recovery "$provider" "$failure_reason" "$output_file"; then
		_run_should_retry=1
		rm -f "$output_file"
		_run_failure_reason="$failure_reason"
		return 76
	fi

	# Pulse supervisor failures must NOT block worker dispatch. The supervisor
	# and workers may use different accounts (isolated auth) and the supervisor
	# hitting a rate limit doesn't mean the provider is down for workers.
	# Record pulse backoffs under a role-scoped key so the pre-dispatch check
	# (which queries the model key) doesn't see them.
	if [[ "$role" == "pulse" ]]; then
		record_provider_backoff "$provider" "$failure_reason" "$output_file" "pulse/${selected_model}"
	else
		record_provider_backoff "$provider" "$failure_reason" "$output_file" "$selected_model"
	fi
	rm -f "$output_file"
	_run_failure_reason="$failure_reason"
	_run_should_retry=0
	return "$exit_code"
}

# _execute_run_attempt: run one headless invocation and handle the result.
# Dispatches to OpenCode (default) or Claude CLI (when --runtime claude specified).
# Args: role session_key work_dir title prompt selected_model variant_override agent_name
#       extra_args (array passed as remaining positional args after the named ones)
# Reads caller variable headless_runtime (set by _parse_run_args --runtime flag).
# Prints the discovered session ID to stdout on success (may be empty).
# Returns: 0 success, 75 no-activity backoff, non-zero on failure.
# Sets caller variable _run_failure_reason on failure.
_execute_run_attempt() {
	local role="$1"
	local session_key="$2"
	local work_dir="$3"
	local title="$4"
	local prompt="$5"
	local selected_model="$6"
	local variant_override="$7"
	local agent_name="$8"
	shift 8
	local -a extra_args=("$@")

	# Determine which runtime to use. Default is opencode unless explicitly overridden.
	local runtime="${headless_runtime:-opencode}"

	local provider persisted_session=""
	provider=$(extract_provider "$selected_model")
	if [[ "$role" == "pulse" ]]; then
		# Pulse runs must start from the current pre-fetched state each cycle.
		# Reusing a prior session contaminates later /pulse runs with stale
		# conversational context, which leads to idle watchdog kills and an
		# empty worker pool. Workers still keep session reuse.
		clear_session_id "$provider" "$session_key"
	else
		persisted_session=$(get_session_id "$provider" "$session_key")
	fi

	local -a cmd=()
	case "$runtime" in
	claude)
		if ! type -P claude >/dev/null 2>&1; then
			print_error "Claude CLI not found in PATH (requested via --runtime claude)"
			return 1
		fi
		while IFS= read -r -d '' arg; do
			cmd+=("$arg")
		done < <(_build_claude_cmd "$selected_model" "$work_dir" "$prompt" "$title" \
			"$agent_name" "${extra_args[@]+"${extra_args[@]}"}")
		;;
	opencode | *)
		while IFS= read -r -d '' arg; do
			cmd+=("$arg")
		done < <(_build_run_cmd "$selected_model" "$work_dir" "$prompt" "$title" \
			"$variant_override" "$agent_name" "$persisted_session" "${extra_args[@]+"${extra_args[@]}"}")
		;;
	esac

	# GH#17549: Claim guard — verify a DISPATCH_CLAIM exists for this runner
	# before launching a worker for an issue. This prevents pulse LLMs from
	# bypassing dispatch_with_dedup() by calling headless-runtime-helper directly.
	# GH#17549: Export repo slug for _release_dispatch_claim on failure.
	# The claim guard was removed — it checked for DISPATCH_CLAIM nonce= comments
	# but dispatch_with_dedup posts "Dispatching worker" comments instead (GH#15317).
	# The mismatch caused the guard to reject every legitimate dispatch, creating
	# a claim→reject→release→reclaim loop. dispatch_with_dedup is the authoritative
	# dedup layer; a second check here adds no safety and causes false rejections.
	# GH#20542: DISPATCH_REPO_SLUG export moved to _cmd_run_prepare (called
	# before the EXIT trap is armed) so _release_dispatch_claim always has a
	# non-empty slug. The role+session_key guard here is no longer needed —
	# _cmd_run_prepare sets the slug for all roles unconditionally.

	local output_file exit_code_file exit_code
	local start_ms end_ms duration_ms
	start_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s' "0")
	output_file=$(mktemp)
	exit_code_file=$(mktemp)
	exit_code=0

	# GH#17549: expose session_key to _invoke_opencode → watchdog → _watchdog_kill
	# so claim release can identify the issue. Module-level var avoids changing
	# _invoke_opencode's interface which is shared with _invoke_claude.
	_invoke_session_key="$session_key"
	# t2249: expose provider to _invoke_opencode → _maybe_rotate_isolated_auth
	# so non-anthropic workers (openai/cursor/google) also benefit from pre-
	# dispatch rotation against their own pool entries. Same rationale as
	# _invoke_session_key above: keep _invoke_opencode's arg list stable.
	_invoke_provider="$provider"

	print_info "[lifecycle] worker_start session=$session_key model=$selected_model runtime=$runtime pid=$$"

	case "$runtime" in
	claude) _invoke_claude "$output_file" "$exit_code_file" "${cmd[@]}" ;;
	*) _invoke_opencode "$output_file" "$exit_code_file" "${cmd[@]}" ;;
	esac
	print_info "[lifecycle] invoke_returned session=$session_key pid=$$ exit_code_file_exists=$(test -f "$exit_code_file" && echo yes || echo no)"
	exit_code=$(cat "$exit_code_file" 2>/dev/null) || exit_code=1
	print_info "[lifecycle] exit_code_read session=$session_key exit_code=$exit_code"

	# Activity watchdog race fix: the watchdog writes a marker file when it
	# kills a stalled worker. The dying subshell may overwrite exit_code_file
	# with its own exit code (0 or 143), losing the watchdog's 124. The marker
	# file is authoritative — if it exists, this was a watchdog kill.
	if [[ -f "${exit_code_file}.watchdog_killed" ]]; then
		exit_code=124
		rm -f "${exit_code_file}.watchdog_killed"
	fi
	rm -f "$exit_code_file"

	# GH#16978 Bug B: Stale session ID causes "Session not found" on OpenCode.
	# When a persisted session ID is stale (e.g., from a previous OpenCode version
	# or a different machine), OpenCode exits non-zero with "Session not found"
	# instead of creating a new session. Detect this, clear the stale ID, and
	# retry once without --session so a fresh session is created.
	if [[ "$exit_code" -ne 0 && "$runtime" != "claude" && -n "$persisted_session" ]]; then
		local output_text=""
		output_text=$(cat "$output_file" 2>/dev/null || true)
		if [[ "$output_text" == *"Session not found"* ]]; then
			print_warning "Stale session ID detected for ${session_key} — clearing and retrying without --session (GH#16978)"
			clear_session_id "$provider" "$session_key"
			persisted_session=""
			rm -f "$output_file"
			output_file=$(mktemp)
			exit_code_file=$(mktemp)
			exit_code=0
			# Rebuild command without the stale --session flag
			cmd=()
			while IFS= read -r -d '' arg; do
				cmd+=("$arg")
			done < <(_build_run_cmd "$selected_model" "$work_dir" "$prompt" "$title" \
				"$agent_name" "" "${extra_args[@]+"${extra_args[@]}"}")
			_invoke_opencode "$output_file" "$exit_code_file" "${cmd[@]}"
			exit_code=$(cat "$exit_code_file" 2>/dev/null) || exit_code=1
			if [[ -f "${exit_code_file}.watchdog_killed" ]]; then
				exit_code=124
				rm -f "${exit_code_file}.watchdog_killed"
			fi
			rm -f "$exit_code_file"
		fi
	fi

	# GH#17549: Post-exit worker diagnostics — log exit code, signal, and
	# session state to the output file so the worker log captures it.
	# OpenCode exits silently on API errors; this is our only visibility.
	# Extract session ID BEFORE the append block to avoid SC2094 (read+write same file).
	local _diag_session_id="" _diag_incomplete_msgs="0"
	if [[ "$exit_code" -eq 0 && -f "$output_file" ]]; then
		_diag_session_id=$(extract_session_id_from_output "$output_file" 2>/dev/null || true)
		if [[ -n "$_diag_session_id" ]]; then
			_diag_incomplete_msgs=$(sqlite3 ~/.local/share/opencode/opencode.db \
				"SELECT count(*) FROM message WHERE session_id='${_diag_session_id}' AND json_extract(data, '$.role')='assistant' AND json_extract(data, '$.time.completed') IS NULL" 2>/dev/null || echo "0")
		fi
	fi
	{
		printf '\n[WORKER_EXIT_DIAGNOSTICS] exit_code=%s model=%s role=%s session_key=%s\n' \
			"$exit_code" "$selected_model" "$role" "$session_key"
		if [[ "$exit_code" -eq 124 ]]; then
			printf '[WORKER_EXIT_DIAGNOSTICS] cause=watchdog_kill (no LLM activity within timeout)\n'
		elif [[ "$exit_code" -eq 137 ]]; then
			printf '[WORKER_EXIT_DIAGNOSTICS] cause=SIGKILL (OOM or external kill)\n'
		elif [[ "$exit_code" -eq 143 ]]; then
			printf '[WORKER_EXIT_DIAGNOSTICS] cause=SIGTERM (graceful termination)\n'
		elif [[ "$exit_code" -eq 0 && "$_diag_incomplete_msgs" -gt 0 ]]; then
			printf '[WORKER_EXIT_DIAGNOSTICS] cause=mid_turn_death (session %s has %s incomplete assistant messages — API likely dropped)\n' \
				"$_diag_session_id" "$_diag_incomplete_msgs"
		elif [[ "$exit_code" -ne 0 ]]; then
			printf '[WORKER_EXIT_DIAGNOSTICS] cause=unknown (exit_code=%s)\n' "$exit_code"
		fi
	} >>"$output_file" 2>/dev/null || true

	print_info "[lifecycle] calling_handle_run_result session=$session_key exit_code=$exit_code output_size=$(wc -c <"$output_file" 2>/dev/null || echo 0)"
	local handle_exit=0
	if _handle_run_result "$exit_code" "$output_file" "$role" "$provider" "$session_key" "$selected_model"; then
		handle_exit=0
	else
		handle_exit=$?
	fi
	print_info "[lifecycle] handle_run_result_returned session=$session_key handle_exit=$handle_exit result_label=${_run_result_label:-unknown}"
	end_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s' "0")
	if [[ "$end_ms" =~ ^[0-9]+$ && "$start_ms" =~ ^[0-9]+$ && "$end_ms" -ge "$start_ms" ]]; then
		duration_ms=$((end_ms - start_ms))
	else
		duration_ms=0
	fi
	append_runtime_metric "$role" "$session_key" "$selected_model" "$provider" "${_run_result_label:-failed}" "$handle_exit" "${_run_failure_reason:-}" "${_run_activity_detected:-0}" "$duration_ms"
	return "$handle_exit"
}

# =============================================================================
# Metrics subcommand
# =============================================================================

cmd_metrics() {
	local role_filter="pulse"
	local hours="24"
	local model_filter=""
	local fast_threshold_secs="120"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--role)
			role_filter="${2:-pulse}"
			shift 2
			;;
		--hours)
			hours="${2:-24}"
			shift 2
			;;
		--model)
			model_filter="${2:-}"
			shift 2
			;;
		--fast-threshold)
			fast_threshold_secs="${2:-120}"
			shift 2
			;;
		*)
			print_error "Unknown option for metrics: $1"
			return 1
			;;
		esac
	done

	if [[ ! "$hours" =~ ^[0-9]+$ ]]; then
		print_error "--hours must be an integer"
		return 1
	fi
	if [[ ! "$fast_threshold_secs" =~ ^[0-9]+$ ]]; then
		print_error "--fast-threshold must be an integer"
		return 1
	fi

	if [[ ! -f "$METRICS_FILE" ]]; then
		print_info "No runtime metrics recorded yet: $METRICS_FILE"
		return 0
	fi

	_execute_metrics_analysis "$role_filter" "$hours" "$model_filter" "$fast_threshold_secs"
	return 0
}

# =============================================================================
# Run lifecycle — prepare, finish, retry, detach
# =============================================================================

_cmd_run_finish() {
	local session_key="$1"
	local ledger_status="$2"

	# Release the dispatch claim so the issue is immediately available for
	# re-dispatch (next 2-min pulse cycle) instead of waiting for the
	# 30-min DISPATCH_COMMENT_MAX_AGE TTL to expire.
	#
	# Both success and failure paths post CLAIM_RELEASED — completion signal
	# consistency matters (GH#19836 follow-up). On success, the worker may
	# have exited without creating a PR (e.g., premise falsified and issue
	# closed, or worker completed an out-of-PR action). Relying only on
	# "PR with Closes #" or MERGE_SUMMARY to clear the claim leaves a 30-min
	# dead-zone where the issue is stuck with no audit trail. The
	# dispatch-dedup guard already treats any CLAIM_RELEASED as authoritative
	# (dispatch-dedup-helper.sh:1044), so this is safe — if a worker DID
	# create a PR with Closes, the PR-based dedup signal still wins and the
	# CLAIM_RELEASED comment is redundant operational metadata.
	if [[ "$ledger_status" == "fail" ]]; then
		_release_dispatch_claim "$session_key" "worker_failed"

		# Classify crash type from worker session state.
		# _run_result_label is set by _handle_run_result:
		#   "premature_exit" = model had activity but no completion signal
		#   "no_activity"    = no LLM output at all
		#   "watchdog_stall_continue" = stall with prior activity
		#   other            = provider/infra failures
		local crash_type=""
		case "${_run_result_label:-}" in
		premature_exit | watchdog_stall_continue)
			# Model attempted real work (read files, created worktree) but
			# couldn't produce commits/PR. This is "overwhelmed" — the model
			# tried and failed due to task complexity, not infra issues.
			crash_type="overwhelmed"
			;;
		no_activity)
			# No LLM output at all — infra/setup failure
			crash_type="no_work"
			;;
		*)
			# Provider errors, rate limits, auth failures — not a model
			# capability issue, don't classify for escalation purposes
			crash_type=""
			;;
		esac

		# Self-report to the fast-fail counter so tier escalation fires
		# immediately instead of waiting 30+ min for the pulse to discover
		# the orphaned assignment. Uses the failure reason from the retry
		# loop if available, otherwise defaults to "worker_failed".
		_report_failure_to_fast_fail "$session_key" "${_run_failure_reason:-worker_failed}" "$crash_type"
	else
		# Success path: post CLAIM_RELEASED with reason=worker_complete so
		# the audit trail on the issue thread shows the full lifecycle
		# (DISPATCH_CLAIM → CLAIM_RELEASED) even when no PR was created.
		# Non-fatal if the API call fails — the pulse will eventually GC
		# the claim via the TTL path.
		_release_dispatch_claim "$session_key" "worker_complete"
	fi

	_update_dispatch_ledger "$session_key" "$ledger_status"
	_release_session_lock "$session_key"
	trap - EXIT
	return 0
}

_cmd_run_prepare() {
	local session_key="$1"
	local work_dir="$2"

	# GH#20542: Export DISPATCH_REPO_SLUG BEFORE arming the EXIT trap so
	# _release_dispatch_claim always has a non-empty slug, even when the
	# process exits between prepare and _execute_run_attempt (e.g. under
	# set -euo pipefail). Role-agnostic: the git extraction is cheap and
	# _release_dispatch_claim silently no-ops when issue_number is absent.
	local _prepare_repo_slug=""
	_prepare_repo_slug=$(git -C "$work_dir" remote get-url origin 2>/dev/null \
		| sed -E 's|.*github\.com[:/]||; s|\.git$||' || true)
	if [[ -n "$_prepare_repo_slug" ]]; then
		export DISPATCH_REPO_SLUG="$_prepare_repo_slug"
	fi

	# GH#6538: Acquire a session-key lock to prevent duplicate workers.
	# The pulse (or any caller) may dispatch the same session-key twice in
	# rapid succession — before the first worker appears in process lists.
	# The lock file acts as an immediate dedup guard: the second invocation
	# sees the first's PID and exits without spawning a sandbox process.
	if ! _acquire_session_lock "$session_key"; then
		return 2
	fi
	# shellcheck disable=SC2064
	trap "_release_dispatch_claim '$session_key' 'process_exit'; _release_session_lock '$session_key'; _update_dispatch_ledger '$session_key' 'fail'" EXIT

	# GH#6696: Register this dispatch in the in-flight ledger so the pulse
	# can detect workers that haven't created PRs yet. The ledger bridges
	# the 10-15 minute gap between dispatch and PR creation.
	_register_dispatch_ledger "$session_key" "$work_dir"
	return 0
}

_cmd_run_prepare_retry() {
	local role="$1"
	local session_key="$2"
	local model_override="$3"
	local attempt="$4"
	local max_attempts="$5"
	local selected_model="$6"
	local attempt_exit="$7"
	local provider=""
	local next_model=""

	cmd_run_action="retry"
	cmd_run_next_model="$selected_model"

	# Retry only in auto-selection mode and only when attempts remain.
	if [[ -n "$model_override" || "$attempt" -ge "$max_attempts" ]]; then
		_cmd_run_finish "$session_key" "fail"
		return "$attempt_exit"
	fi

	if [[ "$_run_should_retry" == "1" ]]; then
		print_warning "Retrying ${selected_model} once after pool account rotation"
		return 0
	fi

	if [[ "$_run_failure_reason" != "auth_error" && "$_run_failure_reason" != "rate_limit" ]]; then
		_cmd_run_finish "$session_key" "fail"
		return "$attempt_exit"
	fi

	provider=$(extract_provider "$selected_model")
	next_model=$(choose_model "$role" "") || {
		_cmd_run_finish "$session_key" "fail"
		return "$attempt_exit"
	}
	print_warning "$provider $_run_failure_reason detected; retrying with alternate provider model $next_model"
	cmd_run_action="switch"
	cmd_run_next_model="$next_model"
	return 0
}

_detach_worker() {
	local session_key="$1"
	shift
	local log_file="/tmp/worker-${session_key}.log"
	print_info "Detaching worker (log: $log_file)"
	(
		# Detach from terminal and redirect all output
		exec </dev/null >"$log_file" 2>&1
		# Re-invoke the script without --detach to avoid recursion
		local -a filtered_args=()
		for arg in "$@"; do
			[[ "$arg" == "--detach" ]] && continue
			filtered_args+=("$arg")
		done
		"$0" run "${filtered_args[@]}"
	) &
	local child_pid=$!
	print_info "Dispatched PID: $child_pid"
	return 0
}

# =============================================================================
# Main run orchestrator
# =============================================================================

cmd_run() {
	local role="worker"
	local session_key=""
	local work_dir=""
	local title=""
	local prompt=""
	local prompt_file=""
	local model_override=""
	local tier_override=""
	local variant_override=""
	local agent_name=""
	local headless_runtime=""
	local detach=0
	local -a extra_args=()

	_parse_run_args "$@" || return 1
	_validate_run_args || return 1

	if [[ "$detach" -eq 1 ]]; then
		_detach_worker "$session_key" "$@"
		return 0
	fi

	local selected_model
	selected_model=$(choose_model "$role" "$model_override") || {
		local choose_exit=$?
		_cmd_run_finish "$session_key" "fail"
		return "$choose_exit"
	}

	# GH#17549: Version guard — runs on EVERY dispatch (not cached).
	# Something keeps upgrading opencode to 1.3.17 between canary checks.
	_enforce_opencode_version_pin
	# GH#17549: Canary smoke test — verify OpenCode can start and complete
	# an API call before committing to a full worker dispatch. Runs BEFORE
	# _cmd_run_prepare so a canary failure never posts a dispatch claim or
	# increments the fast-fail counter. Cached for CANARY_CACHE_TTL_SECONDS
	# (default 30 min) so it runs at most once per pulse cycle.
	if ! _run_canary_test "$selected_model"; then
		print_warning "Canary failed — aborting dispatch for session $session_key (no claim posted)"
		return 1
	fi

	if [[ "$role" == "worker" ]]; then
		prompt=$(append_worker_headless_contract "$prompt")
	fi

	# GH#20542: DISPATCH_REPO_SLUG is now exported in _cmd_run_prepare (before
	# the EXIT trap is armed) so it is always available to _release_dispatch_claim.
	# _cmd_run_prepare is called immediately below; the export no longer needs to
	# live in _execute_run_attempt (which runs after the trap is already set).
	local prepare_exit=0
	_cmd_run_prepare "$session_key" "$work_dir" || prepare_exit=$?
	if [[ "$prepare_exit" -eq 2 ]]; then
		return 0
	fi
	if [[ "$prepare_exit" -ne 0 ]]; then
		return "$prepare_exit"
	fi

	if [[ -z "$variant_override" ]]; then
		variant_override=$(resolve_headless_variant "$role" "$tier_override")
	fi

	# GH#17436: Continuation retry configuration.
	# When a worker exits prematurely (activity but no completion signal),
	# resume the session with a "continue" prompt instead of starting fresh.
	# This catches the GPT-5.4 failure mode of stopping after investigation/setup.
	local max_continuation_retries="${HEADLESS_CONTINUATION_MAX_RETRIES:-10}"
	local continuation_count=0
	local original_prompt="$prompt"

	# GH#17648: Watchdog stall continuation configuration.
	# When the watchdog kills a worker that was making progress (stream drop,
	# hung connection), try resuming the session before giving up. This
	# preserves all work done so far (worktree, files, partial implementation)
	# instead of starting fresh with a different provider.
	local max_watchdog_continue_retries="${HEADLESS_WATCHDOG_CONTINUE_MAX_RETRIES:-2}"
	local watchdog_continue_count=0

	local attempt=1
	local max_attempts=3
	local cmd_run_action="retry"
	local cmd_run_next_model="$selected_model"
	local _run_failure_reason=""
	local _run_should_retry=0
	local _run_result_label="failed"
	local _run_activity_detected="0"
	while [[ "$attempt" -le "$max_attempts" ]]; do
		_run_failure_reason=""
		_run_should_retry=0
		_run_result_label="failed"
		_run_activity_detected="0"
		local attempt_exit=0
		if _execute_run_attempt \
			"$role" "$session_key" "$work_dir" "$title" "$prompt" \
			"$selected_model" "$variant_override" "$agent_name" \
			"${extra_args[@]+"${extra_args[@]}"}"; then
			attempt_exit=0
		else
			attempt_exit=$?
		fi

		if [[ "$attempt_exit" -eq 0 ]]; then
			_cmd_run_finish "$session_key" "complete"
			return 0
		fi

		# GH#17436: Handle premature exit (exit 77) — worker had activity but
		# no completion signal. Resume the session with a continuation prompt
		# instead of recording a provider failure and rotating.
		if [[ "$attempt_exit" -eq 77 && "$continuation_count" -lt "$max_continuation_retries" ]]; then
			continuation_count=$((continuation_count + 1))
			print_warning "Premature exit detected — sending continuation prompt (attempt ${continuation_count}/${max_continuation_retries})"

			# Swap to a continuation prompt that reinforces headless completion.
			# The session ID is already stored; _execute_run_attempt will use
			# --session <id> --continue to resume the existing conversation.
			prompt="Continue through to completion. This is a headless session — no user is present and no user input is available to assist. You have set up the environment but have not yet completed the task. Check your todo list, implement the required code changes, commit, push, and create a PR. After PR creation, you MUST post the MERGE_SUMMARY comment (full-loop step 4.2.1) — the merge pass needs it for closing comments. Then continue through review, merge, and closing comments. Do not stop until the outcome is FULL_LOOP_COMPLETE or BLOCKED with evidence."

			# Continuation retries don't consume provider-rotation attempts
			# since the provider isn't at fault — the model stopped early.
			continue
		fi

		# If we exhausted continuation retries, classify as a real failure
		# so the fast-fail counter increments and tier escalation can trigger.
		if [[ "$attempt_exit" -eq 77 ]]; then
			_run_failure_reason="premature_exit"
			_run_result_label="premature_exit"
			print_warning "Exhausted ${max_continuation_retries} continuation retries — recording as premature_exit failure"
			_cmd_run_finish "$session_key" "fail"
			return 1
		fi

		# GH#17648: Handle watchdog stall with activity (exit 78) — the worker
		# was making progress but the connection/stream dropped. Resume the
		# session to preserve context (worktree, files, partial implementation).
		# Try up to 2 continuations before falling through to provider rotation.
		if [[ "$attempt_exit" -eq 78 && "$watchdog_continue_count" -lt "$max_watchdog_continue_retries" ]]; then
			watchdog_continue_count=$((watchdog_continue_count + 1))
			print_warning "Watchdog stall with activity — resuming session (attempt ${watchdog_continue_count}/${max_watchdog_continue_retries})"

			# Resume with a prompt that explains the connection drop.
			# Session ID was stored by _handle_run_result before returning 78.
			prompt="Your previous connection dropped mid-session and the process was restarted. All your prior work (worktree, file changes, commits) is still on disk. Resume where you left off — check git status, your todo list, and continue through to completion. Do not restart from scratch. Do not stop until the outcome is FULL_LOOP_COMPLETE or BLOCKED with evidence."

			# Watchdog continuations don't consume provider-rotation attempts.
			continue
		fi

		# Exhausted watchdog continuations — fall through to provider rotation.
		if [[ "$attempt_exit" -eq 78 ]]; then
			print_warning "Exhausted ${max_watchdog_continue_retries} watchdog continuation retries — falling through to provider rotation"
			# Don't return — let it fall through to _cmd_run_prepare_retry
			# which will rotate to a different provider/model.
		fi

		_cmd_run_prepare_retry \
			"$role" "$session_key" "$model_override" "$attempt" \
			"$max_attempts" "$selected_model" "$attempt_exit" || return $?
		if [[ "$cmd_run_action" == "switch" ]]; then
			selected_model="$cmd_run_next_model"
		fi
		attempt=$((attempt + 1))
	done

	# Unreachable: loop always executes (attempt starts at 1, max_attempts=3)
	# and every path inside returns explicitly. Kept as defensive fallback.
	_cmd_run_finish "$session_key" "fail"
	return 1
}

# =============================================================================
# Help and main entry point
# =============================================================================

show_help() {
	cat <<'EOF'
headless-runtime-helper.sh - Model-aware headless runtime (OpenCode default, Claude CLI opt-in)

Usage:
  headless-runtime-helper.sh select [--role pulse|worker] [--model provider/model]
  headless-runtime-helper.sh run --role pulse|worker --session-key KEY --dir PATH --title TITLE (--prompt TEXT | --prompt-file FILE) [--model provider/model] [--tier haiku|sonnet|opus|...] [--variant NAME] [--agent NAME] [--runtime opencode|claude] [--opencode-arg ARG] [--detach]
  headless-runtime-helper.sh backoff [status|set MODEL-OR-PROVIDER REASON [SECONDS]|clear MODEL-OR-PROVIDER]
  headless-runtime-helper.sh session [status|clear PROVIDER SESSION_KEY]
  headless-runtime-helper.sh metrics [--role pulse|worker] [--hours N] [--model SUBSTRING] [--fast-threshold N]
  headless-runtime-helper.sh help

Runtime selection:
  Default runtime is OpenCode. Use --runtime claude to dispatch via Claude CLI.
  Claude CLI headless uses `claude -p` with --agent build-plus (auto-detected).

Backoff granularity:
  Rate limits and provider errors are recorded per model (e.g. anthropic/claude-sonnet-4-6).
  Auth errors are recorded per provider (e.g. anthropic) since credentials are shared.
  This allows fallback from sonnet to opus when only sonnet is rate-limited.

Dedup guard (GH#6538):
  Each 'run' invocation acquires a PID lock file keyed by --session-key.
  If a live process already holds the lock, the second invocation exits
  immediately (exit 0) without spawning a worker. Stale locks (dead PIDs)
  are cleaned up automatically. Lock files: $STATE_DIR/locks/<key>.pid

Defaults:
  Model list is derived from routing table + auth availability (GH#17769).
  Fallback: anthropic/claude-sonnet-4-6 if routing resolution fails.
  AIDEVOPS_HEADLESS_MODELS is deprecated — respected as override for one release cycle.
  AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST can restrict selection to providers like: openai
  AIDEVOPS_HEADLESS_VARIANT_SONNET / AIDEVOPS_HEADLESS_VARIANT_OPUS can set tier defaults.
  AIDEVOPS_HEADLESS_VARIANT sets an OpenCode model variant (for example: high, xhigh).
  AIDEVOPS_HEADLESS_PULSE_VARIANT / AIDEVOPS_HEADLESS_WORKER_VARIANT override by role.
  AIDEVOPS_HEADLESS_APPEND_CONTRACT=0 disables worker /full-loop contract injection
  NOTE: opencode/* gateway models are NOT used — per-token billing is too expensive.
EOF
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	init_state_db
	case "$command" in
	select)
		cmd_select "$@"
		return $?
		;;
	run)
		cmd_run "$@"
		return $?
		;;
	backoff)
		cmd_backoff "$@"
		return $?
		;;
	session)
		cmd_session "$@"
		return $?
		;;
	metrics)
		cmd_metrics "$@"
		return $?
		;;
	passthrough-csv)
		# Print the sandbox passthrough CSV to stdout. Used by tests and
		# diagnostics to verify which env vars are included/excluded.
		build_sandbox_passthrough_csv
		return 0
		;;
	help | --help | -h)
		show_help
		return 0
		;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
