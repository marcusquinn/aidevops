#!/usr/bin/env bash

# headless-runtime-helper.sh - Model-aware OpenCode wrapper for pulse/workers
#
# Features:
#   - Alternates between configured headless providers/models
#   - Persists OpenCode session IDs per provider + session key
#   - Records backoff state per model (rate limits) or per provider (auth errors)
#   - Clears backoff automatically when auth changes or retry windows expire
#   - Supports opencode/* gateway models when explicitly configured

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

readonly DEFAULT_HEADLESS_MODELS="anthropic/claude-sonnet-4-6"
readonly STATE_DIR="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
readonly STATE_DB="${STATE_DIR}/state.db"
readonly OPENCODE_BIN_DEFAULT="${OPENCODE_BIN:-opencode}"
readonly SANDBOX_EXEC_HELPER="${SCRIPT_DIR}/sandbox-exec-helper.sh"
readonly HEADLESS_SANDBOX_TIMEOUT_DEFAULT="${AIDEVOPS_HEADLESS_SANDBOX_TIMEOUT:-3600}"
readonly OPENCODE_AUTH_FILE="${HOME}/.local/share/opencode/auth.json"
readonly LOCK_DIR="${STATE_DIR}/locks"

# _acquire_session_lock: prevent duplicate workers for the same session-key (GH#6538).
#
# Creates a PID lock file at $LOCK_DIR/<session_key>.pid. If a lock file
# already exists with a live PID, returns 1 (duplicate — caller should exit).
# If the PID is dead, cleans up the stale lock and acquires a new one.
#
# Args: $1 = session_key
# Returns: 0 = lock acquired, 1 = duplicate detected (live process exists)
_acquire_session_lock() {
	local lock_session_key="$1"
	mkdir -p "$LOCK_DIR" 2>/dev/null || true

	# Sanitise session key for use as filename (replace / and spaces)
	local safe_key
	safe_key=$(printf '%s' "$lock_session_key" | tr '/ ' '__')
	local lock_file="${LOCK_DIR}/${safe_key}.pid"

	if [[ -f "$lock_file" ]]; then
		local existing_pid
		existing_pid=$(cat "$lock_file" 2>/dev/null) || existing_pid=""
		if [[ -n "$existing_pid" ]] && [[ "$existing_pid" =~ ^[0-9]+$ ]]; then
			if kill -0 "$existing_pid" 2>/dev/null; then
				# Live process exists — duplicate dispatch
				print_warning "Duplicate dispatch blocked: session-key '${lock_session_key}' already has active worker PID ${existing_pid} (GH#6538)"
				return 1
			fi
			# PID is dead — stale lock, clean up and proceed
		fi
		rm -f "$lock_file"
	fi

	# Write our PID to the lock file
	printf '%s' "$$" >"$lock_file"
	return 0
}

# _release_session_lock: remove the PID lock file for a session-key.
# Only removes if the lock file contains our own PID (safety against races).
#
# Args: $1 = session_key
_release_session_lock() {
	local lock_session_key="$1"
	local safe_key
	safe_key=$(printf '%s' "$lock_session_key" | tr '/ ' '__')
	local lock_file="${LOCK_DIR}/${safe_key}.pid"

	if [[ -f "$lock_file" ]]; then
		local stored_pid
		stored_pid=$(cat "$lock_file" 2>/dev/null) || stored_pid=""
		if [[ "$stored_pid" == "$$" ]]; then
			rm -f "$lock_file"
		fi
	fi
	return 0
}

build_sandbox_passthrough_csv() {
	local names=()
	local seen_names=" "
	local name

	while IFS='=' read -r name _; do
		case "$name" in
		# OPENCODE_PID is the pulse's own opencode process PID. Passing it to
		# workers causes them to attach to the pulse's session instead of
		# creating independent sessions (GH#6668). Exclude it explicitly.
		OPENCODE_PID) ;;
		AIDEVOPS_* | PULSE_* | GH_* | GITHUB_* | OPENAI_* | ANTHROPIC_* | GOOGLE_* | OPENCODE_* | CLAUDE_* | XDG_* | REAL_HOME | TMPDIR | TMP | TEMP | RTK_* | VERIFY_*)
			if [[ "$seen_names" == *" ${name} "* ]]; then
				continue
			fi
			seen_names+="${name} "
			names+=("$name")
			;;
		esac
	done < <(env)

	local IFS=,
	printf '%s' "${names[*]}"
	return 0
}

init_state_db() {
	mkdir -p "$STATE_DIR" 2>/dev/null || true
	sqlite3 "$STATE_DB" <<'SQL' >/dev/null 2>&1
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS provider_backoff (
    provider       TEXT PRIMARY KEY,
    reason         TEXT NOT NULL,
    retry_after    TEXT DEFAULT '',
    auth_signature TEXT DEFAULT '',
    details        TEXT DEFAULT '',
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS provider_sessions (
    provider     TEXT NOT NULL,
    session_key  TEXT NOT NULL,
    session_id   TEXT NOT NULL,
    model        TEXT NOT NULL,
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (provider, session_key)
);

CREATE TABLE IF NOT EXISTS provider_rotation (
    role         TEXT PRIMARY KEY,
    last_provider TEXT NOT NULL,
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
SQL
	return 0
}

db_query() {
	local query="$1"
	sqlite3 -cmd ".timeout 5000" "$STATE_DB" "$query" 2>/dev/null
	return $?
}

sql_escape() {
	local value="$1"
	printf '%s' "${value//\'/\'\'}"
	return 0
}

trim_spaces() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
	return 0
}

extract_provider() {
	local model="$1"
	if [[ "$model" == */* ]]; then
		printf '%s' "${model%%/*}"
		return 0
	fi
	return 1
}

provider_signature_override_var() {
	local provider="$1"
	case "$provider" in
	anthropic) printf '%s' "AIDEVOPS_HEADLESS_AUTH_SIGNATURE_ANTHROPIC" ;;
	openai) printf '%s' "AIDEVOPS_HEADLESS_AUTH_SIGNATURE_OPENAI" ;;
	*) printf '%s' "" ;;
	esac
	return 0
}

sha256_text() {
	local value="$1"
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
		return 0
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$value" | sha256sum | awk '{print $1}'
		return 0
	fi
	print_error "sha256_text requires 'shasum' or 'sha256sum'"
	return 1
}

file_mtime() {
	local path="$1"
	if [[ ! -e "$path" ]]; then
		printf '%s' "missing"
		return 0
	fi
	# Linux first (stat -c), then macOS (stat -f). On Linux, stat -f '%m'
	# returns filesystem metadata (free blocks), not file mtime — causing
	# auth signatures to change between calls and clearing backoff state.
	stat -c '%Y' "$path" 2>/dev/null || stat -f '%m' "$path" 2>/dev/null || printf '%s' "unknown"
	return 0
}

get_auth_signature() {
	local provider="$1"
	local override_var
	override_var=$(provider_signature_override_var "$provider")
	if [[ -n "$override_var" && -n "${!override_var:-}" ]]; then
		printf '%s' "${!override_var}"
		return 0
	fi

	local auth_material="provider=${provider}"
	case "$provider" in
	anthropic)
		local auth_status auth_mtime
		auth_status=$(timeout_sec 10 "$OPENCODE_BIN_DEFAULT" auth status 2>/dev/null || true)
		auth_mtime=$(file_mtime "$OPENCODE_AUTH_FILE")
		auth_material="${auth_material}|status=${auth_status}|mtime=${auth_mtime}"
		;;
	openai)
		if [[ -n "${OPENAI_API_KEY:-}" ]]; then
			auth_material="${auth_material}|env=$(sha256_text "$OPENAI_API_KEY")"
		else
			# OpenAI can also be authenticated via OpenCode OAuth (no direct API key needed).
			# Include the OAuth auth status in the signature so backoff clears on re-auth.
			local auth_status auth_mtime
			auth_status=$(timeout_sec 10 "$OPENCODE_BIN_DEFAULT" auth status 2>/dev/null || true)
			auth_mtime=$(file_mtime "$OPENCODE_AUTH_FILE")
			auth_material="${auth_material}|status=${auth_status}|mtime=${auth_mtime}|env=missing"
		fi
		;;
	opencode)
		# Gateway models use OpenCode's OAuth session
		local auth_mtime
		auth_mtime=$(file_mtime "$OPENCODE_AUTH_FILE")
		auth_material="${auth_material}|mtime=${auth_mtime}"
		;;
	*)
		auth_material="${auth_material}|unknown=true"
		;;
	esac

	sha256_text "$auth_material"
	return 0
}

get_configured_models() {
	local configured="${AIDEVOPS_HEADLESS_MODELS:-$DEFAULT_HEADLESS_MODELS}"
	local allowlist_raw="${AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST:-}"
	local -a allowlist=()
	local -a raw_models=()
	local -a models=()
	local item provider

	if [[ -n "$allowlist_raw" ]]; then
		IFS=',' read -r -a allowlist <<<"$allowlist_raw"
	fi

	IFS=',' read -r -a raw_models <<<"$configured"
	for item in "${raw_models[@]}"; do
		item=$(trim_spaces "$item")
		[[ -z "$item" ]] && continue
		provider=$(extract_provider "$item" 2>/dev/null || printf '%s' "")
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
		models+=("$item")
	done

	if [[ ${#models[@]} -eq 0 ]]; then
		return 1
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

clear_provider_backoff() {
	local provider="$1"
	db_query "DELETE FROM provider_backoff WHERE provider = '$(sql_escape "$provider")';" >/dev/null
	return 0
}

parse_retry_after_seconds() {
	local file_path="$1"
	python3 - "$file_path" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="ignore").lower()
patterns = [
    (r"retry after\s+(\d+)\s*(second|seconds|sec|secs|s)\b", 1),
    (r"retry after\s+(\d+)\s*(minute|minutes|min|mins|m)\b", 60),
    (r"retry after\s+(\d+)\s*(hour|hours|hr|hrs|h)\b", 3600),
    (r"retry after\s+(\d+)\s*(day|days|d)\b", 86400),
    (r"try again in\s+(\d+)\s*(second|seconds|sec|secs|s)\b", 1),
    (r"try again in\s+(\d+)\s*(minute|minutes|min|mins|m)\b", 60),
    (r"try again in\s+(\d+)\s*(hour|hours|hr|hrs|h)\b", 3600),
    (r"try again in\s+(\d+)\s*(day|days|d)\b", 86400),
]
for pattern, multiplier in patterns:
    match = re.search(pattern, text)
    if match:
        print(int(match.group(1)) * multiplier)
        sys.exit(0)

numeric = re.search(r"\b429\b", text)
if numeric:
    print(900)
    sys.exit(0)

print(0)
PY
	return 0
}

record_provider_backoff() {
	local provider="$1"
	local reason="$2"
	local details_file="$3"
	local model="${4:-$provider}"
	local details retry_seconds auth_signature retry_after backoff_key

	# Auth errors back off at provider level (shared credentials).
	# Rate limits and provider errors back off at model level so that
	# other models from the same provider remain available as fallbacks.
	if [[ "$reason" == "auth_error" ]]; then
		backoff_key="$provider"
	else
		backoff_key="$model"
	fi

	details=$(
		python3 - "$details_file" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(errors="ignore")
text = " ".join(text.split())
print(text[:400])
PY
	)
	auth_signature=$(get_auth_signature "$provider")
	retry_seconds=$(parse_retry_after_seconds "$details_file")
	if [[ "$retry_seconds" -le 0 ]]; then
		case "$reason" in
		rate_limit) retry_seconds=900 ;;
		auth_error) retry_seconds=3600 ;;
		*) retry_seconds=300 ;;
		esac
	fi
	retry_after=$(date -u -v+"${retry_seconds}"S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "+${retry_seconds} seconds" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "")
	db_query "
INSERT INTO provider_backoff (provider, reason, retry_after, auth_signature, details, updated_at)
VALUES (
    '$(sql_escape "$backoff_key")',
    '$(sql_escape "$reason")',
    '$(sql_escape "$retry_after")',
    '$(sql_escape "$auth_signature")',
    '$(sql_escape "$details")',
    strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
)
ON CONFLICT(provider) DO UPDATE SET
    reason = excluded.reason,
    retry_after = excluded.retry_after,
    auth_signature = excluded.auth_signature,
    details = excluded.details,
    updated_at = excluded.updated_at;
" >/dev/null
	return 0
}

backoff_active_for_key() {
	local key="$1"
	local provider="$2"
	local row stored_retry_after stored_signature current_signature
	row=$(db_query "SELECT reason || '|' || retry_after || '|' || auth_signature FROM provider_backoff WHERE provider = '$(sql_escape "$key")';")
	if [[ -z "$row" ]]; then
		return 1
	fi

	IFS='|' read -r stored_reason stored_retry_after stored_signature <<<"$row"
	current_signature=$(get_auth_signature "$provider")
	if [[ -n "$stored_signature" && -n "$current_signature" && "$stored_signature" != "$current_signature" ]]; then
		clear_provider_backoff "$key"
		return 1
	fi

	if [[ -n "$stored_retry_after" ]]; then
		local now_epoch retry_epoch
		now_epoch=$(date -u '+%s')
		retry_epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$stored_retry_after" '+%s' 2>/dev/null || date -u -d "$stored_retry_after" '+%s' 2>/dev/null || printf '%s' "0")
		if [[ "$retry_epoch" -le "$now_epoch" ]]; then
			clear_provider_backoff "$key"
			return 1
		fi
	fi

	return 0
}

model_backoff_active() {
	local model="$1"
	local provider
	provider=$(extract_provider "$model" 2>/dev/null || printf '%s' "")

	# Check model-level backoff (rate limits, provider errors)
	if backoff_active_for_key "$model" "$provider"; then
		return 0
	fi

	# Check provider-level backoff (auth errors affect all models)
	if [[ -n "$provider" && "$provider" != "$model" ]]; then
		if backoff_active_for_key "$provider" "$provider"; then
			return 0
		fi
	fi

	return 1
}

# Legacy wrapper — kept for backward compatibility with cmd_backoff CLI
provider_backoff_active() {
	local provider="$1"
	backoff_active_for_key "$provider" "$provider"
	return $?
}

provider_auth_available() {
	local provider="$1"
	case "$provider" in
	anthropic)
		# Anthropic: API key env var OR OpenCode OAuth session
		if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
			return 0
		fi
		if [[ -f "$OPENCODE_AUTH_FILE" ]]; then
			return 0
		fi
		return 1
		;;
	openai)
		# OpenAI: API key env var OR OpenCode OAuth session (OAuth subscription includes Codex)
		if [[ -n "${OPENAI_API_KEY:-}" ]]; then
			return 0
		fi
		if [[ -f "$OPENCODE_AUTH_FILE" ]]; then
			return 0
		fi
		return 1
		;;
	opencode)
		# OpenCode gateway models use OpenCode's OAuth session
		if [[ -f "$OPENCODE_AUTH_FILE" ]]; then
			return 0
		fi
		return 1
		;;
	local)
		# Local provider is always considered available (no auth needed)
		return 0
		;;
	*)
		# Unknown provider: assume available (don't silently drop unknown providers)
		return 0
		;;
	esac
}

classify_failure_reason() {
	local file_path="$1"
	local lowered
	lowered=$(
		python3 - "$file_path" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(errors="ignore").lower())
PY
	)
	if [[ "$lowered" == *"rate limit"* ]] || [[ "$lowered" == *"429"* ]] || [[ "$lowered" == *"too many requests"* ]]; then
		printf '%s' "rate_limit"
		return 0
	fi
	if [[ "$lowered" =~ (unauthorized|401|invalid\ api\ key|authentication|token\ refresh\ failed|invalid_grant|invalid\ refresh\ token) ]] || [[ "$lowered" == *"auth"* && "$lowered" == *"failed"* ]]; then
		printf '%s' "auth_error"
		return 0
	fi
	printf '%s' "provider_error"
	return 0
}

extract_session_id_from_output() {
	local file_path="$1"
	python3 - "$file_path" <<'PY'
import json
import sys
from pathlib import Path

session_id = ""
for line in Path(sys.argv[1]).read_text(errors="ignore").splitlines():
    line = line.strip()
    if not line or not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("sessionID"):
        session_id = obj["sessionID"]
        break
    part = obj.get("part") or {}
    if part.get("sessionID"):
        session_id = part["sessionID"]
        break
print(session_id)
PY
	return 0
}

output_has_activity() {
	local file_path="$1"
	python3 - "$file_path" <<'PY'
import json
import sys
from pathlib import Path

activity = False
for line in Path(sys.argv[1]).read_text(errors="ignore").splitlines():
    line = line.strip()
    if not line or not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    event_type = obj.get("type", "")
    if event_type in {"text", "tool", "tool-invocation", "tool-result", "step-start", "step_finish", "reasoning"}:
        activity = True
        break

print("1" if activity else "0")
PY
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
# Non-blocking — any failure falls through silently.
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
		# Skip providers with no auth configured — silent skip, no backoff recorded.
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

cmd_select() {
	local role="worker"
	local model_override=""
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
		*)
			print_error "Unknown option for select: $1"
			return 1
			;;
		esac
	done

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

# _parse_run_args: parse cmd_run flags into caller-scoped variables.
# Caller must declare: role session_key work_dir title prompt prompt_file
#                      model_override agent_name extra_args
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
		--agent)
			agent_name="${2:-}"
			shift 2
			;;
		--opencode-arg)
			extra_args+=("${2:-}")
			shift 2
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

# _build_run_cmd: build the opencode command array for a run attempt.
# Args: selected_model work_dir prompt title agent_name persisted_session
#       extra_args (remaining positional args)
# Outputs: space-separated command (caller must eval or use array assignment).
# Returns: 0 always.
_build_run_cmd() {
	local selected_model="$1"
	local work_dir="$2"
	local prompt="$3"
	local title="$4"
	local agent_name="$5"
	local persisted_session="$6"
	shift 6

	# Emit base command args as null-delimited tokens (bash 3.2 compat: no local -a in subshell)
	printf '%s\0' "$OPENCODE_BIN_DEFAULT" run "$prompt" --dir "$work_dir" -m "$selected_model" --title "$title" --format json
	if [[ -n "$agent_name" ]]; then
		printf '%s\0' --agent "$agent_name"
	fi
	if [[ -n "$persisted_session" ]]; then
		printf '%s\0' --session "$persisted_session" --continue
	fi
	# Emit any extra args passed as positional parameters
	while [[ $# -gt 0 ]]; do
		printf '%s\0' "$1"
		shift
	done
	return 0
}

# _invoke_opencode: run the opencode command (with or without sandbox) and capture output.
# Args: output_file exit_code_file cmd_args (null-delimited, read from stdin via process sub)
# Caller passes the cmd array elements as positional args after the two file args.
# Returns: 0 always (exit code written to exit_code_file).
_invoke_opencode() {
	local output_file="$1"
	local exit_code_file="$2"
	shift 2
	local -a cmd=("$@")

	# Run in subshell to avoid fragile set +e/set -e toggling (GH#4225).
	# Subshell localises errexit so main shell state is never modified.
	# Exit code is written to a temp file — NOT captured via $() — because
	# tee stdout would contaminate the $() capture (bash 3.2 has no clean
	# way to separate tee output from the exit code in a single $()).
	(
		set +e
		if [[ -x "$SANDBOX_EXEC_HELPER" && "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" != "1" ]]; then
			# Pass cmd array elements as separate arguments after --.
			# Previous code used printf -v to build a single escaped string,
			# which the sandbox received as one argument and passed to env as
			# a single executable path — causing "No such file or directory".
			# Bash 3.2 compat: no local -a in subshells, no printf -v tricks.
			local passthrough_csv
			passthrough_csv="$(build_sandbox_passthrough_csv)"
			if [[ -n "$passthrough_csv" ]]; then
				"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --passthrough "$passthrough_csv" -- "${cmd[@]}" 2>&1 | tee "$output_file"
			else
				"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io -- "${cmd[@]}" 2>&1 | tee "$output_file"
			fi
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		else
			"${cmd[@]}" 2>&1 | tee "$output_file"
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		fi
	) || true
	return 0
}

# _handle_run_result: process output_file after opencode exits.
# Args: exit_code output_file role provider session_key selected_model
# Sets caller variable _run_failure_reason on failure.
# Returns: 0 success, 75 no-activity backoff, non-zero on failure.
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

	if [[ "$exit_code" -eq 0 ]]; then
		if [[ "$activity_detected" != "1" ]]; then
			record_provider_backoff "$provider" "provider_error" "$output_file" "$selected_model"
			rm -f "$output_file"
			print_warning "$selected_model returned exit 0 without any model activity; backing off model"
			return 75
		fi
		if [[ "$role" != "pulse" && -n "$discovered_session" ]]; then
			store_session_id "$provider" "$session_key" "$discovered_session" "$selected_model"
		fi
		rm -f "$output_file"
		return 0
	fi

	local failure_reason
	failure_reason=$(classify_failure_reason "$output_file")
	record_provider_backoff "$provider" "$failure_reason" "$output_file" "$selected_model"
	rm -f "$output_file"
	_run_failure_reason="$failure_reason"
	return "$exit_code"
}

# _execute_run_attempt: run one opencode invocation and handle the result.
# Args: role session_key work_dir title prompt selected_model agent_name model_override
#       extra_args (array passed as remaining positional args after the named ones)
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
	local agent_name="$7"
	local model_override="$8"
	shift 8
	local -a extra_args=("$@")

	local provider persisted_session=""
	provider=$(extract_provider "$selected_model")
	if [[ "$role" == "pulse" ]]; then
		# Pulse runs must start from the current pre-fetched state each cycle.
		# Reusing a prior OpenCode session contaminates later /pulse runs with
		# stale conversational context, which leads to idle watchdog kills and an
		# empty worker pool. Workers still keep session reuse.
		clear_session_id "$provider" "$session_key"
	else
		persisted_session=$(get_session_id "$provider" "$session_key")
	fi

	local -a cmd=()
	while IFS= read -r -d '' arg; do
		cmd+=("$arg")
	done < <(_build_run_cmd "$selected_model" "$work_dir" "$prompt" "$title" \
		"$agent_name" "$persisted_session" "${extra_args[@]+"${extra_args[@]}"}")

	local output_file exit_code_file exit_code
	output_file=$(mktemp)
	exit_code_file=$(mktemp)
	exit_code=0

	_invoke_opencode "$output_file" "$exit_code_file" "${cmd[@]}"
	exit_code=$(cat "$exit_code_file" 2>/dev/null) || exit_code=1
	rm -f "$exit_code_file"

	_handle_run_result "$exit_code" "$output_file" "$role" "$provider" "$session_key" "$selected_model"
	return $?
}

cmd_run() {
	local role="worker"
	local session_key=""
	local work_dir=""
	local title=""
	local prompt=""
	local prompt_file=""
	local model_override=""
	local agent_name=""
	local -a extra_args=()

	_parse_run_args "$@" || return 1
	_validate_run_args || return 1

	# GH#6538: Acquire a session-key lock to prevent duplicate workers.
	# The pulse (or any caller) may dispatch the same session-key twice in
	# rapid succession — before the first worker appears in process lists.
	# The lock file acts as an immediate dedup guard: the second invocation
	# sees the first's PID and exits without spawning a sandbox process.
	if ! _acquire_session_lock "$session_key"; then
		return 0
	fi
	# shellcheck disable=SC2064
	trap "_release_session_lock '$session_key'" EXIT

	local selected_model
	selected_model=$(choose_model "$role" "$model_override") || {
		local choose_exit=$?
		_release_session_lock "$session_key"
		trap - EXIT
		return "$choose_exit"
	}

	local attempt=1
	local max_attempts=2
	local _run_failure_reason=""
	local run_exit=1
	while [[ "$attempt" -le "$max_attempts" ]]; do
		_run_failure_reason=""
		_execute_run_attempt \
			"$role" "$session_key" "$work_dir" "$title" "$prompt" \
			"$selected_model" "$agent_name" "$model_override" \
			"${extra_args[@]+"${extra_args[@]}"}"
		local attempt_exit=$?

		if [[ "$attempt_exit" -eq 0 ]]; then
			_release_session_lock "$session_key"
			trap - EXIT
			return 0
		fi

		# Only retry on auth errors when no explicit model was requested
		# and we have attempts remaining.
		if [[ -n "$model_override" || "$_run_failure_reason" != "auth_error" || "$attempt" -ge "$max_attempts" ]]; then
			_release_session_lock "$session_key"
			trap - EXIT
			return "$attempt_exit"
		fi

		local provider next_model
		provider=$(extract_provider "$selected_model")
		next_model=$(choose_model "$role" "") || {
			_release_session_lock "$session_key"
			trap - EXIT
			return "$attempt_exit"
		}
		print_warning "$provider auth failure detected at startup; retrying once with alternate provider model $next_model"
		selected_model="$next_model"
		attempt=$((attempt + 1))
	done

	# Unreachable: loop always executes (attempt starts at 1, max_attempts=2)
	# and every path inside returns explicitly. Kept as defensive fallback.
	_release_session_lock "$session_key"
	trap - EXIT
	return 1
}

show_help() {
	cat <<'EOF'
headless-runtime-helper.sh - Model-aware headless OpenCode runtime

Usage:
  headless-runtime-helper.sh select [--role pulse|worker] [--model provider/model]
  headless-runtime-helper.sh run --role pulse|worker --session-key KEY --dir PATH --title TITLE (--prompt TEXT | --prompt-file FILE) [--model provider/model] [--agent NAME] [--opencode-arg ARG]
  headless-runtime-helper.sh backoff [status|set MODEL-OR-PROVIDER REASON [SECONDS]|clear MODEL-OR-PROVIDER]
  headless-runtime-helper.sh session [status|clear PROVIDER SESSION_KEY]
  headless-runtime-helper.sh help

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
  AIDEVOPS_HEADLESS_MODELS defaults to anthropic/claude-sonnet-4-6,openai/gpt-4o
  AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST can restrict selection to providers like: openai
  Gateway models (opencode/*) are supported when explicitly configured.
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
