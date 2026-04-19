#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Model — Model Choice & Cmd Builders (GH#19699)
# =============================================================================
# Model selection, session management, and CLI command construction functions
# extracted from headless-runtime-lib.sh to reduce file size.
#
# Covers two functional areas:
#   1. Model Choice  — configured model list derivation, round-robin rotation,
#                       tier downgrade, explicit model validation, session ID mgmt
#   2. Cmd Builders  — headless variant resolution, OpenCode server detection,
#                       opencode/claude CLI command assembly, completion signal
#                       detection in worker output
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-model.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning)
#   - headless-runtime-lib.sh Section 1 functions (db_query, sql_escape, trim_spaces)
#   - headless-runtime-provider.sh (extract_provider, provider_auth_available,
#     model_backoff_active)
#   - worker-lifecycle-common.sh (resolve_model_tier)
#   - Constants from headless-runtime-helper.sh (OPENCODE_BIN_DEFAULT,
#     DEFAULT_HEADLESS_MODELS, SCRIPT_DIR)
#   - bash 3.2+, python3, jq, curl (optional)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_MODEL_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_MODEL_LOADED=1

# --- Model Choice ---

# Derive the headless model list from the routing table (GH#17769).
# Flow: routing table sonnet tier -> optional provider allowlist -> providers with
# usable auth at dispatch time. This eliminates AIDEVOPS_HEADLESS_MODELS as a
# user-configurable env var while allowing temporary provider pinning via
# AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST.
get_configured_models() {
	local allowlist_raw="${AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST:-}"
	local -a allowlist=()
	local -a models=()
	local provider model

	# Backward compatibility: if legacy env var is still set, log deprecation
	# warning but respect it as an override for one release cycle.
	if [[ -n "${AIDEVOPS_HEADLESS_MODELS:-}" ]]; then
		print_warning "AIDEVOPS_HEADLESS_MODELS is deprecated (v3.7+). Model routing is now automatic via pool + routing table. Remove this export from credentials.sh. Respecting override for this release cycle."
		local -a raw_models=()
		IFS=',' read -r -a raw_models <<<"$AIDEVOPS_HEADLESS_MODELS"
		for item in "${raw_models[@]}"; do
			item=$(trim_spaces "$item")
			[[ -z "$item" ]] && continue
			provider=$(extract_provider "$item" 2>/dev/null || printf '%s' "")
			[[ -z "$provider" ]] && continue
			models+=("$item")
		done
		if [[ ${#models[@]} -gt 0 ]]; then
			printf '%s\n' "${models[@]}"
			return 0
		fi
	fi

	if [[ -n "$allowlist_raw" ]]; then
		IFS=',' read -r -a allowlist <<<"$allowlist_raw"
	fi

	local routing_table="${SCRIPT_DIR}/../custom/configs/model-routing-table.json"
	if [[ ! -f "$routing_table" ]]; then
		routing_table="${SCRIPT_DIR}/../configs/model-routing-table.json"
	fi

	if [[ -f "$routing_table" ]] && command -v jq >/dev/null 2>&1; then
		while IFS= read -r model; do
			[[ -z "$model" ]] && continue
			provider=$(extract_provider "$model" 2>/dev/null || printf '%s' "")
			[[ -z "$provider" ]] && continue

			if [[ ${#allowlist[@]} -gt 0 ]]; then
				local allowed=false
				local allowed_provider
				for allowed_provider in "${allowlist[@]}"; do
					allowed_provider=$(trim_spaces "$allowed_provider")
					if [[ "$allowed_provider" == "$provider" ]]; then
						allowed=true
						break
					fi
				done
				[[ "$allowed" == "true" ]] || continue
			fi

			if ! provider_auth_available "$provider"; then
				continue
			fi

			models+=("$model")
		done < <(jq -r '.tiers.sonnet.models[]? // empty' "$routing_table" 2>/dev/null)
	fi

	# Fallback: if routing derivation yielded nothing and no allowlist is forcing a
	# provider subset, use the historical default when auth is available.
	if [[ ${#models[@]} -eq 0 ]] && [[ -z "$allowlist_raw" ]]; then
		provider=$(extract_provider "$DEFAULT_HEADLESS_MODELS" 2>/dev/null || printf '%s' "")
		if [[ -n "$provider" ]] && provider_auth_available "$provider"; then
			models+=("$DEFAULT_HEADLESS_MODELS")
		fi
	fi

	printf '%s\n' "${models[@]}"
	return 0
}

get_last_provider() {
	local role="$1"
	db_query "SELECT last_provider FROM provider_rotation WHERE role = '$(sql_escape "$role")';"
	return 0
}

set_last_provider() {
	local role="$1"
	local provider="$2"
	db_query "
INSERT INTO provider_rotation (role, last_provider, updated_at)
VALUES ('$(sql_escape "$role")', '$(sql_escape "$provider")', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
ON CONFLICT(role) DO UPDATE SET
    last_provider = excluded.last_provider,
    updated_at = excluded.updated_at;
" >/dev/null
	return 0
}

get_session_id() {
	local provider="$1"
	local session_key="$2"
	db_query "SELECT session_id FROM provider_sessions WHERE provider = '$(sql_escape "$provider")' AND session_key = '$(sql_escape "$session_key")';"
	return 0
}

clear_session_id() {
	local provider="$1"
	local session_key="$2"
	db_query "DELETE FROM provider_sessions WHERE provider = '$(sql_escape "$provider")' AND session_key = '$(sql_escape "$session_key")';" >/dev/null
	return 0
}

store_session_id() {
	local provider="$1"
	local session_key="$2"
	local session_id="$3"
	local model="$4"
	db_query "
INSERT INTO provider_sessions (provider, session_key, session_id, model, updated_at)
VALUES (
    '$(sql_escape "$provider")',
    '$(sql_escape "$session_key")',
    '$(sql_escape "$session_id")',
    '$(sql_escape "$model")',
    strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
)
ON CONFLICT(provider, session_key) DO UPDATE SET
    session_id = excluded.session_id,
    model = excluded.model,
    updated_at = excluded.updated_at;
" >/dev/null
	return 0
}

# _choose_model_explicit: validate and return an explicitly-requested model.
# Returns 0 on success (prints model), 1 on bad format, 75 if backed off.
_choose_model_explicit() {
	local explicit_model="$1"
	local provider
	provider=$(extract_provider "$explicit_model" 2>/dev/null || printf '%s' "")
	if [[ -z "$provider" ]]; then
		print_error "Model must use provider/model format: $explicit_model"
		return 1
	fi
	if model_backoff_active "$explicit_model"; then
		print_warning "$explicit_model is currently backed off"
		return 75
	fi
	printf '%s' "$explicit_model"
	return 0
}

# _choose_model_tier_downgrade: check pattern history for a cheaper tier.
# Prints the downgraded model name if one is recommended; prints nothing otherwise.
# Non-blocking -- any failure falls through silently.
_choose_model_tier_downgrade() {
	local current_model="$1"
	local downgrade_task_type="${AIDEVOPS_TIER_DOWNGRADE_TASK_TYPE:-}"
	[[ -n "$downgrade_task_type" ]] || return 0

	local current_tier=""
	case "$current_model" in
	*opus*) current_tier="opus" ;;
	*sonnet*) current_tier="sonnet" ;;
	*haiku*) current_tier="haiku" ;;
	*flash*) current_tier="flash" ;;
	*pro*) current_tier="pro" ;;
	esac
	[[ -n "$current_tier" ]] || return 0

	local pattern_helper="${SCRIPT_DIR}/archived/pattern-tracker-helper.sh"
	if [[ ! -x "$pattern_helper" ]]; then
		pattern_helper="${HOME}/.aidevops/agents/scripts/archived/pattern-tracker-helper.sh"
	fi
	[[ -x "$pattern_helper" ]] || return 0

	local lower_tier
	lower_tier=$("$pattern_helper" tier-downgrade-check \
		--requested-tier "$current_tier" \
		--task-type "$downgrade_task_type" \
		--min-samples "${AIDEVOPS_TIER_DOWNGRADE_MIN_SAMPLES:-3}" \
		2>/dev/null || true)
	[[ -n "$lower_tier" ]] || return 0

	local lower_model
	lower_model=$(resolve_model_tier "$lower_tier" 2>/dev/null || true)
	if [[ -n "$lower_model" && "$lower_model" != "$current_model" ]]; then
		print_info "Model for dispatch: pattern data recommends ${lower_tier} over ${current_tier} (TIER_DOWNGRADE_OK, task_type=${downgrade_task_type})"
		printf '%s' "$lower_model"
	fi
	return 0
}

# _choose_model_auto: select the next available model via round-robin rotation.
# Skips models that are backed off or have no auth. Returns 75 if all are backed off.
_choose_model_auto() {
	local role="$1"
	local -a models=()
	local current_model
	while IFS= read -r current_model; do
		models+=("$current_model")
	done < <(get_configured_models)
	if [[ ${#models[@]} -eq 0 ]]; then
		print_error "No direct provider models configured for headless runtime"
		return 1
	fi

	local last_provider start_index i idx current_provider
	last_provider=$(get_last_provider "$role")
	start_index=0
	if [[ -n "$last_provider" ]]; then
		for i in "${!models[@]}"; do
			current_provider=$(extract_provider "${models[$i]}")
			if [[ "$current_provider" == "$last_provider" ]]; then
				start_index=$(((i + 1) % ${#models[@]}))
				break
			fi
		done
	fi

	for ((i = 0; i < ${#models[@]}; i++)); do
		idx=$(((start_index + i) % ${#models[@]}))
		current_model="${models[$idx]}"
		current_provider=$(extract_provider "$current_model")
		# Skip providers with no auth configured -- silent skip, no backoff recorded.
		# This keeps Codex in the default list for users with OpenAI OAuth while
		# being invisible to users who have no OpenAI auth at all.
		if ! provider_auth_available "$current_provider"; then
			continue
		fi
		# Check model-level backoff (rate limits) and provider-level (auth errors)
		if model_backoff_active "$current_model"; then
			continue
		fi
		set_last_provider "$role" "$current_provider"

		# Pattern-driven tier downgrade (t5148): non-blocking check.
		local downgraded
		downgraded=$(_choose_model_tier_downgrade "$current_model")
		if [[ -n "$downgraded" ]]; then
			printf '%s' "$downgraded"
			return 0
		fi

		printf '%s' "$current_model"
		return 0
	done

	print_warning "All configured models are currently backed off"
	return 75
}

choose_model() {
	local role="$1"
	local explicit_model="${2:-}"

	if [[ -n "$explicit_model" ]]; then
		_choose_model_explicit "$explicit_model"
		return $?
	fi

	_choose_model_auto "$role"
	return $?
}

# --- Cmd Builders ---

resolve_headless_variant() {
	local role="$1"
	local tier="${2:-}"
	local variant="${AIDEVOPS_HEADLESS_VARIANT:-}"
	local tier_upper=""

	if [[ -n "$tier" ]]; then
		tier_upper=$(printf '%s' "$tier" | tr '[:lower:]-' '[:upper:]_')
		case "$tier_upper" in
		HAIKU | FLASH | SONNET | PRO | OPUS | HEALTH | EVAL | CODING)
			local tier_env_var="AIDEVOPS_HEADLESS_VARIANT_${tier_upper}"
			local tier_variant="${!tier_env_var:-}"
			if [[ -n "$tier_variant" ]]; then
				variant="$tier_variant"
			fi
			;;
		esac
	fi

	case "$role" in
	pulse)
		if [[ -n "${AIDEVOPS_HEADLESS_PULSE_VARIANT:-}" ]]; then
			variant="${AIDEVOPS_HEADLESS_PULSE_VARIANT}"
		fi
		;;
	worker)
		if [[ -n "${AIDEVOPS_HEADLESS_WORKER_VARIANT:-}" ]]; then
			variant="${AIDEVOPS_HEADLESS_WORKER_VARIANT}"
		fi
		;;
	esac

	if [[ -n "$tier" ]]; then
		case "$tier_upper" in
		HAIKU | FLASH | SONNET | PRO | OPUS | HEALTH | EVAL | CODING)
			local tier_env_var="AIDEVOPS_HEADLESS_VARIANT_${tier_upper}"
			local tier_variant="${!tier_env_var:-}"
			if [[ -n "$tier_variant" ]]; then
				variant="$tier_variant"
			fi
			;;
		esac
	fi

	printf '%s' "$variant"
	return 0
}

# _detect_opencode_server: check if an opencode server is already listening.
# GH#17829: When `opencode serve` is running, `opencode run` without --attach
# fails with "Session not found". Detect the running server and return its URL.
#
# Detection strategy (does NOT rely on OPENCODE_PID -- that's intentionally
# excluded from worker envs per GH#6668):
#   1. Check OPENCODE_SERVER_PASSWORD is set (indicates a server context)
#   2. Verify a server is actually listening on the expected port
#
# Outputs two lines to stdout: URL then password (empty if no server found).
# Returns: 0 if a server is detected, 1 otherwise.
_detect_opencode_server() {
	local password="${OPENCODE_SERVER_PASSWORD:-}"
	if [[ -z "$password" ]]; then
		return 1
	fi

	local port="${OPENCODE_PORT:-4096}"
	local url="http://localhost:${port}"

	# Verify the server is actually listening (timeout 2s, silent).
	# Use /api/session/list as a lightweight endpoint -- it returns 401 without
	# auth but proves the server is up (vs connection refused).
	local http_code
	http_code=$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "${url}/api/session/list" 2>/dev/null)
	if [[ "$http_code" == "200" || "$http_code" == "401" ]]; then
		printf '%s\n%s\n' "$url" "$password"
		return 0
	fi

	# Fallback: check if anything is listening on the port (no curl endpoint needed)
	if command -v lsof >/dev/null 2>&1; then
		if lsof -iTCP:"$port" -sTCP:LISTEN -P -n >/dev/null 2>&1; then
			printf '%s\n%s\n' "$url" "$password"
			return 0
		fi
	fi

	return 1
}

# _build_run_cmd: build the opencode command array for a run attempt.
# Args: selected_model work_dir prompt title variant_override agent_name persisted_session
#       extra_args (remaining positional args)
# Outputs: space-separated command (caller must eval or use array assignment).
# Returns: 0 always.
_build_run_cmd() {
	local selected_model="$1"
	local work_dir="$2"
	local prompt="$3"
	local title="$4"
	local variant_override="$5"
	local agent_name="$6"
	local persisted_session="$7"
	shift 7

	# Emit base command args as null-delimited tokens (bash 3.2 compat: no local -a in subshell)
	printf '%s\0' "$OPENCODE_BIN_DEFAULT" run "$prompt" --dir "$work_dir" -m "$selected_model" --title "$title" --format json
	if [[ -n "$agent_name" ]]; then
		printf '%s\0' --agent "$agent_name"
	fi
	if [[ -n "$persisted_session" ]]; then
		printf '%s\0' --session "$persisted_session" --continue
	fi
	if [[ -n "$variant_override" ]]; then
		printf '%s\0' --variant "$variant_override"
	fi
	# GH#17829: Attach to running opencode server if one is detected.
	# Without this, `opencode run` tries to start an embedded server that
	# conflicts with the user's `opencode serve`, causing "Session not found".
	local _server_info=""
	if _server_info=$(_detect_opencode_server); then
		local _server_url _server_pass
		_server_url=$(echo "$_server_info" | head -1)
		_server_pass=$(echo "$_server_info" | tail -1)
		printf '%s\0' --attach "$_server_url" --password "$_server_pass"
	fi
	# Emit any extra args passed as positional parameters.
	# Use "$@" rather than a shift loop so the pre-commit positional-param
	# check (which flags $1-$9 usage) stays quiet while behaviour is identical.
	if [[ $# -gt 0 ]]; then
		printf '%s\0' "$@"
	fi
	return 0
}

# _build_claude_cmd: build the claude CLI headless command as null-delimited tokens.
# Used when --runtime claude is explicitly specified. OpenCode remains the default.
# Args: selected_model work_dir prompt title agent_name [extra_args...]
_build_claude_cmd() {
	local selected_model="$1"
	local work_dir="$2"
	local prompt="$3"
	local title="$4"
	local agent_name="$5"
	shift 5

	# claude -p runs headless and prints output. --output-format stream-json
	# gives structured output compatible with our result parsing.
	# GH#16978: Claude CLI uses --cwd, not --directory (--directory is not a valid flag).
	printf '%s\0' "claude" "-p" "$prompt" "--output-format" "stream-json" "--verbose"
	if [[ -n "$work_dir" ]]; then
		printf '%s\0' "--cwd" "$work_dir"
	fi
	if [[ -n "$agent_name" ]]; then
		printf '%s\0' "--agent" "$agent_name"
	elif type -P claude >/dev/null 2>&1; then
		# Default to build-plus agent when none specified, if it exists in
		# the agent directory. This gives headless Claude sessions the same
		# aidevops agent behaviour as interactive sessions.
		local claude_agent_dir="$HOME/.claude/agents"
		if [[ -f "$claude_agent_dir/build-plus.md" ]]; then
			printf '%s\0' "--agent" "build-plus"
		fi
	fi
	# Model override: claude CLI uses --model flag
	if [[ -n "$selected_model" ]]; then
		# Strip provider prefix (anthropic/) -- claude CLI doesn't need it
		local claude_model="${selected_model#*/}"
		printf '%s\0' "--model" "$claude_model"
	fi
	# Max turns for safety
	printf '%s\0' "--max-turns" "50"
	# Permission mode: allow all tools in headless
	printf '%s\0' "--permission-mode" "bypassPermissions"
	# Emit any extra args.
	# Use "$@" rather than a shift loop so the pre-commit positional-param
	# check (which flags $1-$9 usage) stays quiet while behaviour is identical.
	if [[ $# -gt 0 ]]; then
		printf '%s\0' "$@"
	fi
	return 0
}

# output_has_completion_signal: check if a worker run produced a meaningful
# completion signal (FULL_LOOP_COMPLETE, BLOCKED, or PR creation).
# Workers that produce tool calls but exit without these signals stopped
# prematurely -- typically after investigation/setup but before implementation.
#
# Args: $1 = output file path
# Returns: 0 if completion signal found, 1 if premature exit
output_has_completion_signal() {
	local file_path="$1"
	[[ -f "$file_path" ]] || return 1
	python3 - "$file_path" <<'PY'
import sys, json
from pathlib import Path

# GH#17549: Only check the MODEL'S OWN text output, not tool call results.
# The tee output includes file contents the model read (tool_use events).
# full-loop.md contains "FULL_LOOP_COMPLETE" as documentation -- grepping
# the raw output matches that and falsely classifies the run as complete,
# preventing the continuation retry from ever firing.
#
# Strategy: parse JSON lines for "type":"text" events (model output) and
# check only those. Fall back to raw grep for non-JSON output (claude CLI).

raw = Path(sys.argv[1]).read_text(errors="ignore")

# Extract model text from JSON stream (OpenCode format)
model_text_parts = []
for line in raw.splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue
    # OpenCode text events contain the model's own output.
    # GH#17596 (MEDIUM): consolidate extraction into a single pass checking
    # multiple common paths for text and tool input fields.
    event_type = obj.get("type", "")
    if event_type == "text":
        part = obj.get("part", {})
        text = (
            obj.get("text")
            or part.get("text")
            or ""
        )
        if text:
            model_text_parts.append(text)
    # Also check tool calls where the MODEL invoked gh pr create/merge
    # (the input field shows what the model requested, not file contents)
    elif event_type == "tool_use":
        part = obj.get("part", {})
        state = part.get("state", {})
        # GH#17596 (MEDIUM): check multiple common input paths
        inp = (
            obj.get("input")
            or part.get("input")
            or state.get("input")
            or {}
        )
        if isinstance(inp, dict):
            cmd = inp.get("command", "")
            if cmd:
                model_text_parts.append(cmd)

model_text = "\n".join(model_text_parts)

# If we extracted model text, use it exclusively
if model_text.strip():
    for marker in ("FULL_LOOP_COMPLETE", "BLOCKED", "TASK_COMPLETE"):
        if marker in model_text:
            sys.exit(0)
    # GH#17596 (HIGH): verify both model intent AND actual success signal in raw.
    # Checking model_text alone may match commands the model merely mentioned
    # or invoked but that failed. Requiring a success signal in raw (same as
    # the fallback block) prevents false-positive completion classification.
    if "gh pr create" in model_text and ("pull/" in raw or "created pull request" in raw.lower()):
        sys.exit(0)
    if "gh pr merge" in model_text and "merged" in raw.lower():
        sys.exit(0)
    if "git push" in model_text and ("-> " in raw or "branch " in raw):
        sys.exit(0)
    sys.exit(1)

# Fallback for non-JSON output (claude CLI, plain text)
for marker in ("FULL_LOOP_COMPLETE", "BLOCKED", "TASK_COMPLETE"):
    if marker in raw:
        sys.exit(0)
if "gh pr create" in raw and ("pull/" in raw or "Created pull request" in raw.lower()):
    sys.exit(0)
if "gh pr merge" in raw and ("Merged" in raw or "merged" in raw):
    sys.exit(0)
if "git push" in raw and ("-> " in raw or "branch " in raw):
    sys.exit(0)

sys.exit(1)
PY
	return $?
}
