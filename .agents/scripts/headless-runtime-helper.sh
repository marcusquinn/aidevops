#!/usr/bin/env bash

# headless-runtime-helper.sh - Model-aware OpenCode wrapper for pulse/workers
#
# Features:
#   - Alternates between configured headless providers/models
#   - Persists OpenCode session IDs per provider + session key
#   - Records backoff state per model (rate limits) or per provider (auth errors)
#   - Clears backoff automatically when auth changes or retry windows expire
#   - NOTE: opencode/* gateway models are NOT used (per-token billing, too expensive)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

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

# _register_dispatch_ledger: register this dispatch in the in-flight ledger (GH#6696).
# Extracts issue number from session_key (pattern: "issue-NNN") and registers
# the dispatch so the pulse can detect in-flight workers before they create PRs.
#
# Args: $1 = session_key, $2 = work_dir (used to resolve repo slug)
_register_dispatch_ledger() {
	local ledger_session_key="$1"
	local ledger_work_dir="$2"

	[[ -x "$DISPATCH_LEDGER_HELPER" ]] || return 0

	local ledger_issue=""
	local ledger_repo=""

	# Extract issue number from session key (e.g., "issue-42" -> "42")
	if [[ "$ledger_session_key" =~ ^issue-([0-9]+)$ ]]; then
		ledger_issue="${BASH_REMATCH[1]}"
	fi

	# Resolve repo slug from work_dir via git remote
	if [[ -n "$ledger_work_dir" && -d "$ledger_work_dir" ]]; then
		ledger_repo=$(git -C "$ledger_work_dir" remote get-url origin 2>/dev/null | sed -E 's|.*[:/]([^/]+/[^/]+)(\.git)?$|\1|' || true)
	fi

	local ledger_args=(register --session-key "$ledger_session_key" --pid "$$")
	[[ -n "$ledger_issue" ]] && ledger_args+=(--issue "$ledger_issue")
	[[ -n "$ledger_repo" ]] && ledger_args+=(--repo "$ledger_repo")

	"$DISPATCH_LEDGER_HELPER" "${ledger_args[@]}" 2>/dev/null || true
	return 0
}

# _update_dispatch_ledger: mark a dispatch as completed or failed (GH#6696).
# Args: $1 = session_key, $2 = status ("completed" or "failed")
_update_dispatch_ledger() {
	local ledger_session_key="$1"
	local ledger_status="$2"

	[[ -x "$DISPATCH_LEDGER_HELPER" ]] || return 0

	"$DISPATCH_LEDGER_HELPER" "$ledger_status" --session-key "$ledger_session_key" 2>/dev/null || true
	return 0
}

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
	ollama | local)
		# Local providers have no auth material — use a static signature
		# so backoff state clears only when the provider string changes
		auth_material="${auth_material}|local=true"
		;;
	*)
		auth_material="${auth_material}|unknown=true"
		;;
	esac

	sha256_text "$auth_material"
	return 0
}

get_configured_models() {
	local configured="${AIDEVOPS_HEADLESS_MODELS:-}"
	local allowlist_raw="${AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST:-}"
	local -a allowlist=()
	local -a raw_models=()
	local -a models=()
	local item provider

	if [[ -z "$configured" ]] && type config_get >/dev/null 2>&1; then
		configured=$(config_get "orchestration.headless_models" "")
		if [[ "$configured" == "null" ]]; then
			configured=""
		fi
	fi
	if [[ -z "$configured" ]]; then
		configured="$DEFAULT_HEADLESS_MODELS"
	fi

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
	local provider="${2:-anthropic}"

	# t1835: Check if provider-auth.mjs already set a server-sourced cooldown
	# in oauth-pool.json. Only return a cooldown if ALL accounts for this
	# provider are rate-limited. A single exhausted account must NOT block
	# workers that can use another available account (GH#15489).
	local pool_file="${HOME}/.aidevops/oauth-pool.json"
	if [[ -f "$pool_file" ]]; then
		local remaining
		remaining=$(POOL_FILE="$pool_file" PROVIDER="$provider" python3 -c "
import json, os, time, sys
try:
    pool = json.load(open(os.environ['POOL_FILE']))
    now_ms = int(time.time() * 1000)
    accounts = pool.get(os.environ['PROVIDER'], [])
    if not accounts:
        print(0); sys.exit(0)
    # Only back off if ALL accounts are rate-limited with active cooldowns
    min_remaining = None
    for a in accounts:
        cd = a.get('cooldownUntil')
        if cd and int(cd) > now_ms and a.get('status') == 'rate-limited':
            remaining_s = max(1, (int(cd) - now_ms) // 1000)
            min_remaining = min(min_remaining, remaining_s) if min_remaining else remaining_s
        else:
            # At least one account is available — no provider-level backoff
            print(0); sys.exit(0)
    print(min_remaining or 0)
except Exception:
    print(0)
" 2>/dev/null)
		if [[ "$remaining" -gt 0 ]]; then
			echo "$remaining"
			return 0
		fi
	fi

	# Fallback: parse worker log text for retry hints
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

# t1835: Reduced from 900s — Anthropic API rate limits clear in 10-60s.
# 900s was blocking interactive sessions for 15 minutes unnecessarily.
numeric = re.search(r"\b429\b", text)
if numeric:
    print(60)
    sys.exit(0)

print(0)
PY
	return 0
}

append_runtime_metric() {
	local role="$1"
	local session_key="$2"
	local model="$3"
	local provider="$4"
	local result="$5"
	local exit_code="$6"
	local failure_reason="$7"
	local activity="$8"
	local duration_ms="$9"
	mkdir -p "$METRICS_DIR" 2>/dev/null || true
	ROLE="$role" SESSION_KEY="$session_key" MODEL="$model" PROVIDER="$provider" \
		RESULT="$result" EXIT_CODE="$exit_code" FAILURE_REASON="$failure_reason" \
		ACTIVITY="$activity" DURATION_MS="$duration_ms" METRICS_PATH="$METRICS_FILE" python3 - <<'PY' >/dev/null 2>&1 || true
import json
import os
import time

record = {
    "ts": int(time.time()),
    "role": os.environ.get("ROLE", ""),
    "session_key": os.environ.get("SESSION_KEY", ""),
    "model": os.environ.get("MODEL", ""),
    "provider": os.environ.get("PROVIDER", ""),
    "result": os.environ.get("RESULT", "unknown"),
    "exit_code": int(os.environ.get("EXIT_CODE", "1") or 1),
    "failure_reason": os.environ.get("FAILURE_REASON", ""),
    "activity": os.environ.get("ACTIVITY", "0") == "1",
    "duration_ms": int(os.environ.get("DURATION_MS", "0") or 0),
}
with open(os.environ["METRICS_PATH"], "a") as f:
    f.write(json.dumps(record, separators=(",", ":")) + "\n")
PY
	return 0
}

attempt_pool_recovery() {
	local provider="$1"
	local reason="$2"
	local details_file="$3"

	# CRITICAL SAFETY GUARD: oauth-pool-helper.sh rotate OVERWRITES the shared
	# auth file (~/.local/share/opencode/auth.json) which is used by BOTH
	# interactive sessions AND headless workers. When a headless worker triggers
	# rotation, it kills the user's interactive session by swapping the token
	# out from under it. The user must then Esc+Esc, manually rotate in a
	# terminal, and type "continue" to recover.
	#
	# Fix: headless workers NEVER call pool rotation. They only record the
	# backoff so the pre-dispatch check skips the dead provider on the next
	# cycle. Token rotation is an INTERACTIVE-ONLY operation — the user
	# decides when to switch accounts.
	#
	# The mark-failure call below is safe (only updates the pool JSON metadata,
	# does not touch auth.json). The rotate call is the dangerous one.
	case "$provider" in
	anthropic | openai | cursor | google) ;;
	*)
		return 1
		;;
	esac

	case "$reason" in
	rate_limit | auth_error) ;;
	*)
		return 1
		;;
	esac

	[[ -x "$OAUTH_POOL_HELPER" ]] || return 1

	local retry_seconds
	retry_seconds=$(parse_retry_after_seconds "$details_file" "$provider")
	if [[ "$retry_seconds" -le 0 ]]; then
		# t1835: Reduced rate_limit fallback from 900s to 60s.
		# Anthropic API rate limits clear in 10-60s; 900s was blocking
		# interactive sessions for 15 minutes unnecessarily.
		case "$reason" in
		rate_limit) retry_seconds=60 ;;
		auth_error) retry_seconds=3600 ;;
		*) retry_seconds=300 ;;
		esac
	fi

	# Safe: mark the account as failed in pool metadata (no auth file mutation)
	"$OAUTH_POOL_HELPER" mark-failure "$provider" "$reason" "$retry_seconds" >/dev/null 2>&1 || true

	# DANGEROUS: rotate rewrites the shared auth.json — SKIP for headless workers.
	# Only record backoff so the pre-dispatch check routes to the other provider.
	# Interactive sessions handle rotation explicitly via `oauth-pool-helper.sh rotate`.
	print_warning "${provider} ${reason} detected; recorded backoff (rotation skipped — interactive-only)"
	return 1
}

record_provider_backoff() {
	local provider="$1"
	local reason="$2"
	local details_file="$3"
	local model="${4:-$provider}"
	local details retry_seconds auth_signature retry_after backoff_key

	# local_error = worker/sandbox/prompt issue, NOT provider's fault.
	# Skip backoff entirely — recording it falsely flags healthy providers.
	if [[ "$reason" == "local_error" ]]; then
		return 0
	fi

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
	retry_seconds=$(parse_retry_after_seconds "$details_file" "$provider")
	if [[ "$retry_seconds" -le 0 ]]; then
		# t1835: Reduced rate_limit fallback from 900s to 60s
		case "$reason" in
		rate_limit) retry_seconds=60 ;;
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
	ollama)
		# Ollama: no auth needed, just check if server is reachable
		if curl -sf --max-time 2 "${OLLAMA_HOST:-http://localhost:11434}/api/tags" >/dev/null 2>&1; then
			return 0
		fi
		return 1
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
	# Distinguish actual provider errors (5xx, connection refused, timeout)
	# from local/worker failures (sandbox crash, bad prompt, opencode bug).
	# Only provider errors should trigger backoff — local failures don't
	# mean the provider is unhealthy.
	if [[ "$lowered" =~ (500|502|503|504|internal\ server\ error|service\ unavailable|gateway|connection\ refused|connection.*reset|overloaded) ]]; then
		printf '%s' "provider_error"
		return 0
	fi
	# Default: local_error — do NOT record provider backoff for this
	printf '%s' "local_error"
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
    if event_type in {"text", "tool", "tool-invocation", "tool-result", "step_start", "step_finish", "reasoning"}:
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

# append_worker_headless_contract: append unattended continuation rules to
# worker /full-loop prompts without changing interactive /full-loop behavior.
#
# This contract is injected at dispatch time by the headless runtime wrapper,
# so full-loop.md can remain dual-purpose (interactive + headless).
#
# Args: $1 = prompt text
# Output: prompt text (possibly appended)
# Env:
#   AIDEVOPS_HEADLESS_APPEND_CONTRACT=0 disables prompt augmentation.
append_worker_headless_contract() {
	local prompt_text="$1"
	local append_enabled="${AIDEVOPS_HEADLESS_APPEND_CONTRACT:-1}"

	if [[ "$append_enabled" == "0" ]]; then
		printf '%s' "$prompt_text"
		return 0
	fi

	if [[ "$prompt_text" != *"/full-loop"* ]]; then
		printf '%s' "$prompt_text"
		return 0
	fi

	if [[ "$prompt_text" == *"HEADLESS_CONTINUATION_CONTRACT_V1"* ]]; then
		printf '%s' "$prompt_text"
		return 0
	fi

	local contract
	contract=$(
		cat <<'EOF'
[HEADLESS_CONTINUATION_CONTRACT_V1]
This worker run is unattended.

Mandatory behavior:
1. Never ask for user confirmation or next steps.
2. Do not stop at "PR opened" or "in review" states.
3. Continue through review polling, merge readiness checks, merge, and required closing comments.
4. If merge/close cannot complete, exit only with a clear BLOCKED outcome and evidence (failing check, missing permission, unresolved conflict, or explicit policy gate).
5. Do not emit user-directed language like "If you want, I can...".
6. Model escalation before BLOCKED (GH#14964): BLOCKED is only valid after exhausting all autonomous solution paths. Before exiting BLOCKED, attempt model escalation — retry with the next tier (sonnet -> opus via --model anthropic/claude-opus-4-6). Review-policy metadata, nominal GitHub states, and lower-tier model limits are NOT valid blockers on their own. A genuine blocker requires evidence that persists after escalation.
EOF
	)

	printf '%s\n\n%s' "$prompt_text" "$contract"
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
#
# Includes an activity watchdog: if no LLM activity appears in the output
# file within HEADLESS_ACTIVITY_TIMEOUT_SECONDS (default 90s), the opencode
# process is killed. This catches rate-limited providers that cause the
# worker to hang indefinitely waiting for an API response. Without this,
# stalled workers consume slots permanently and rotation never fires
# (because the retry logic only runs after the process exits).
HEADLESS_ACTIVITY_TIMEOUT_SECONDS="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-90}"

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
		isolated_data_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-worker-auth.XXXXXX")
		mkdir -p "${isolated_data_dir}/opencode"
		# Copy the current auth.json so the worker has valid tokens at startup
		if [[ -f "$OPENCODE_AUTH_FILE" ]]; then
			cp "$OPENCODE_AUTH_FILE" "${isolated_data_dir}/opencode/auth.json" 2>/dev/null || true
			chmod 600 "${isolated_data_dir}/opencode/auth.json" 2>/dev/null || true
		fi
		# Preserve the shared session DB path before redirecting XDG_DATA_HOME.
		# OPENCODE_DB tells opencode to use the shared DB for session/message
		# persistence even when XDG_DATA_HOME points to an isolated temp dir.
		local real_data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
		export OPENCODE_DB="${real_data_home}/opencode/opencode.db"
		export XDG_DATA_HOME="$isolated_data_dir"
	fi

	# Run in subshell to avoid fragile set +e/set -e toggling (GH#4225).
	# Subshell localises errexit so main shell state is never modified.
	# Exit code is written to a temp file — NOT captured via $() — because
	# tee stdout would contaminate the $() capture (bash 3.2 has no clean
	# way to separate tee output from the exit code in a single $()).
	(
		set +e
		if [[ -x "$SANDBOX_EXEC_HELPER" && "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" != "1" ]]; then
			local passthrough_csv
			passthrough_csv="$(build_sandbox_passthrough_csv)"
			# --stream-stdout: let child stdout flow through the pipe to tee
			# so the activity watchdog can monitor output in real-time
			# (GH#15180 bug #4). Without this, the sandbox captures stdout to
			# a temp file and replays it after exit — the watchdog sees nothing
			# and kills every sandboxed worker at ~93s.
			if [[ -n "$passthrough_csv" ]]; then
				"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --stream-stdout --passthrough "$passthrough_csv" -- "${cmd[@]}" 2>&1 | tee "$output_file"
			else
				"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --stream-stdout -- "${cmd[@]}" 2>&1 | tee "$output_file"
			fi
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		else
			timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" "${cmd[@]}" 2>&1 | tee "$output_file"
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		fi
	) &
	local worker_pid=$!

	# Activity watchdog: monitor the output file for LLM activity.
	# If no activity appears within the timeout, the provider is likely
	# rate-limited and the worker will hang indefinitely. Kill it so the
	# retry loop in cmd_run can rotate to the next provider.
	_run_activity_watchdog "$output_file" "$worker_pid" "$exit_code_file" &
	local watchdog_pid=$!

	# Wait for the worker to finish (watchdog will kill it if stalled)
	wait "$worker_pid" 2>/dev/null || true

	# Clean up the watchdog
	kill "$watchdog_pid" 2>/dev/null || true
	wait "$watchdog_pid" 2>/dev/null || true

	# Clean up isolated auth dir (worker is done, tokens no longer needed)
	if [[ -n "$isolated_data_dir" && -d "$isolated_data_dir" ]]; then
		rm -rf "$isolated_data_dir" 2>/dev/null || true
		unset XDG_DATA_HOME
	fi

	return 0
}

#######################################
# Activity watchdog for _invoke_opencode.
#
# Runs as a background process alongside the worker. Polls the output
# file for LLM activity indicators (JSON events from opencode: text,
# tool, reasoning, step_start). If none appear within the timeout,
# kills the worker process.
#
# The initial output always contains the sandbox startup line (~300 bytes).
# This is NOT activity — it's just the executor logging. Real activity
# starts when the LLM responds with structured JSON events.
#
# Args:
#   $1 - output file path
#   $2 - worker PID to kill on timeout
#   $3 - exit code file (written with 124 on timeout)
#######################################
_run_activity_watchdog() {
	local output_file="$1"
	local worker_pid="$2"
	local exit_code_file="$3"
	local timeout="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-90}"
	[[ "$timeout" =~ ^[0-9]+$ ]] || timeout=90

	local elapsed=0
	local poll_interval=5

	while [[ "$elapsed" -lt "$timeout" ]]; do
		# Check if worker already exited (success or failure — watchdog not needed)
		if ! kill -0 "$worker_pid" 2>/dev/null; then
			return 0
		fi

		# Check for LLM activity in the output file
		# Activity indicators: JSON events from opencode (text, tool, reasoning, etc.)
		if [[ -f "$output_file" ]]; then
			# output_has_activity is defined earlier — checks for JSON events
			# But we can't call it from a background process easily.
			# Instead, check for common activity markers directly.
			if grep -qE '"type"\s*:\s*"(text|tool|tool-invocation|tool-result|step_start|step_finish|reasoning)"' "$output_file" 2>/dev/null; then
				# Real LLM activity detected — worker is alive
				return 0
			fi
		fi

		sleep "$poll_interval"
		elapsed=$((elapsed + poll_interval))
	done

	# Timeout reached with no activity — kill the stalled worker and all its
	# children (opencode, tee, etc.). Sending only to $worker_pid leaves
	# pipeline children as orphans consuming CPU+memory (GH#15180 bug #2).
	if kill -0 "$worker_pid" 2>/dev/null; then
		print_warning "Activity watchdog: no LLM activity in ${timeout}s — killing stalled worker (PID $worker_pid)"
		# Write the marker BEFORE killing — the dying subshell may overwrite
		# exit_code_file with its own exit code (race condition). The marker
		# file survives because only the watchdog writes to it.
		touch "${exit_code_file}.watchdog_killed"
		# Kill child processes first (pipeline members: opencode, tee), then
		# the subshell itself. pkill -P walks the process tree by PPID.
		pkill -P "$worker_pid" 2>/dev/null || true
		kill "$worker_pid" 2>/dev/null || true
		sleep 2
		pkill -9 -P "$worker_pid" 2>/dev/null || true
		kill -9 "$worker_pid" 2>/dev/null || true
		printf '124' >"$exit_code_file"
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
	printf '%s\0' "claude" "-p" "$prompt" "--output-format" "stream-json" "--verbose"
	if [[ -n "$work_dir" ]]; then
		printf '%s\0' "--directory" "$work_dir"
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
		# Strip provider prefix (anthropic/) — claude CLI doesn't need it
		local claude_model="${selected_model#*/}"
		printf '%s\0' "--model" "$claude_model"
	fi
	# Max turns for safety
	printf '%s\0' "--max-turns" "50"
	# Permission mode: allow all tools in headless
	printf '%s\0' "--permission-mode" "bypassPermissions"
	# Emit any extra args
	while [[ $# -gt 0 ]]; do
		printf '%s\0' "$1"
		shift
	done
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
			rm -f "$output_file"
			print_warning "$selected_model returned exit 0 without any model activity (no backoff recorded — may be local issue)"
			return 75
		fi
		_run_result_label="success"
		if [[ "$role" != "pulse" && -n "$discovered_session" ]]; then
			store_session_id "$provider" "$session_key" "$discovered_session" "$selected_model"
		fi
		rm -f "$output_file"
		return 0
	fi

	local failure_reason
	# Exit code 124 = activity watchdog timeout. The worker produced no LLM
	# activity, which almost always means the provider is rate-limited or
	# unreachable. Classify as rate_limit to trigger pool rotation — the
	# output file won't contain explicit rate limit text since the API never
	# responded at all.
	if [[ "$exit_code" -eq 124 ]]; then
		failure_reason="rate_limit"
		print_warning "$selected_model activity watchdog timeout — classifying as rate_limit for rotation"
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
# Args: role session_key work_dir title prompt selected_model agent_name model_override
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
	local agent_name="$7"
	local model_override="$8"
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
			"$agent_name" "$persisted_session" "${extra_args[@]+"${extra_args[@]}"}")
		;;
	esac

	local output_file exit_code_file exit_code
	local start_ms end_ms duration_ms
	start_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s' "0")
	output_file=$(mktemp)
	exit_code_file=$(mktemp)
	exit_code=0

	case "$runtime" in
	claude) _invoke_claude "$output_file" "$exit_code_file" "${cmd[@]}" ;;
	*) _invoke_opencode "$output_file" "$exit_code_file" "${cmd[@]}" ;;
	esac
	exit_code=$(cat "$exit_code_file" 2>/dev/null) || exit_code=1

	# Activity watchdog race fix: the watchdog writes a marker file when it
	# kills a stalled worker. The dying subshell may overwrite exit_code_file
	# with its own exit code (0 or 143), losing the watchdog's 124. The marker
	# file is authoritative — if it exists, this was a watchdog kill.
	if [[ -f "${exit_code_file}.watchdog_killed" ]]; then
		exit_code=124
		rm -f "${exit_code_file}.watchdog_killed"
	fi
	rm -f "$exit_code_file"

	local handle_exit=0
	if _handle_run_result "$exit_code" "$output_file" "$role" "$provider" "$session_key" "$selected_model"; then
		handle_exit=0
	else
		handle_exit=$?
	fi
	end_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s' "0")
	if [[ "$end_ms" =~ ^[0-9]+$ && "$start_ms" =~ ^[0-9]+$ && "$end_ms" -ge "$start_ms" ]]; then
		duration_ms=$((end_ms - start_ms))
	else
		duration_ms=0
	fi
	append_runtime_metric "$role" "$session_key" "$selected_model" "$provider" "${_run_result_label:-failed}" "$handle_exit" "${_run_failure_reason:-}" "${_run_activity_detected:-0}" "$duration_ms"
	return "$handle_exit"
}

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

_execute_metrics_analysis() {
	local role_filter="$1"
	local hours="$2"
	local model_filter="$3"
	local fast_threshold_secs="$4"

	ROLE_FILTER="$role_filter" HOURS="$hours" MODEL_FILTER="$model_filter" FAST_THRESHOLD_SECS="$fast_threshold_secs" METRICS_PATH="$METRICS_FILE" python3 - <<'PY'
import json
import os
import time
from collections import defaultdict

metrics_path = os.environ["METRICS_PATH"]
role_filter = os.environ.get("ROLE_FILTER", "pulse")
hours = int(os.environ.get("HOURS", "24"))
model_filter = os.environ.get("MODEL_FILTER", "")
fast_threshold_secs = int(os.environ.get("FAST_THRESHOLD_SECS", "120"))
cutoff = int(time.time()) - (hours * 3600)

def is_expensive_model(model: str) -> bool:
    normalized = (model or "").lower()
    return any(token in normalized for token in (
        "gpt-5.4",
        "claude-opus",
        "gemini-2.5-pro",
        "cursor/composer-2",
    )) or normalized in {"opus", "pro"}

rows = []
with open(metrics_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if int(row.get("ts", 0)) < cutoff:
            continue
        if role_filter and row.get("role") != role_filter:
            continue
        model = row.get("model", "")
        if model_filter and model_filter not in model:
            continue
        rows.append(row)

if not rows:
    print("No matching runtime metrics in selected window")
    raise SystemExit(0)

agg = defaultdict(lambda: {"runs": 0, "success": 0, "productive": 0, "retry_recovered": 0, "sum_duration": 0, "fast_productive": 0})
for row in rows:
    model = row.get("model", "unknown")
    item = agg[model]
    item["runs"] += 1
    if row.get("result") == "success":
        item["success"] += 1
    if row.get("result") == "success" and bool(row.get("activity", False)):
        item["productive"] += 1
        if int(row.get("duration_ms", 0) or 0) <= (fast_threshold_secs * 1000):
            item["fast_productive"] += 1
    if int(row.get("exit_code", 1)) == 76:
        item["retry_recovered"] += 1
    item["sum_duration"] += int(row.get("duration_ms", 0) or 0)

print(f"Headless runtime metrics (window={hours}h, role={role_filter}, fast_threshold={fast_threshold_secs}s)")
review_candidates = []
for model in sorted(agg.keys()):
    item = agg[model]
    runs = item["runs"]
    success_pct = (item["success"] / runs) * 100 if runs else 0
    productive_pct = (item["productive"] / runs) * 100 if runs else 0
    avg_sec = (item["sum_duration"] / runs) / 1000 if runs else 0
    print(f"- {model}: runs={runs}, success={item['success']} ({success_pct:.1f}%), productive={item['productive']} ({productive_pct:.1f}%), fast_productive={item['fast_productive']} (<={fast_threshold_secs}s), pool-recovered={item['retry_recovered']}, avg_duration={avg_sec:.1f}s")
    if item["fast_productive"] > 0 and is_expensive_model(model):
        review_candidates.append((model, item["fast_productive"], item["productive"]))

if review_candidates:
    print("Review candidates:")
    for model, fast_count, productive_count in review_candidates:
        print(f"- {model}: {fast_count}/{productive_count} productive successful runs finished within {fast_threshold_secs}s; review tier labels for simplification/doc work and prefer a cheaper default where possible")
PY
	return 0
}

_cmd_run_finish() {
	local session_key="$1"
	local ledger_status="$2"

	_update_dispatch_ledger "$session_key" "$ledger_status"
	_release_session_lock "$session_key"
	trap - EXIT
	return 0
}

_cmd_run_prepare() {
	local session_key="$1"
	local work_dir="$2"

	# GH#6538: Acquire a session-key lock to prevent duplicate workers.
	# The pulse (or any caller) may dispatch the same session-key twice in
	# rapid succession — before the first worker appears in process lists.
	# The lock file acts as an immediate dedup guard: the second invocation
	# sees the first's PID and exits without spawning a sandbox process.
	if ! _acquire_session_lock "$session_key"; then
		return 2
	fi
	# shellcheck disable=SC2064
	trap "_release_session_lock '$session_key'; _update_dispatch_ledger '$session_key' 'fail'" EXIT

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

cmd_run() {
	local role="worker"
	local session_key=""
	local work_dir=""
	local title=""
	local prompt=""
	local prompt_file=""
	local model_override=""
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

	if [[ "$role" == "worker" ]]; then
		prompt=$(append_worker_headless_contract "$prompt")
	fi

	local prepare_exit=0
	_cmd_run_prepare "$session_key" "$work_dir" || prepare_exit=$?
	if [[ "$prepare_exit" -eq 2 ]]; then
		return 0
	fi
	if [[ "$prepare_exit" -ne 0 ]]; then
		return "$prepare_exit"
	fi

	local selected_model
	selected_model=$(choose_model "$role" "$model_override") || {
		local choose_exit=$?
		_cmd_run_finish "$session_key" "fail"
		return "$choose_exit"
	}

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
			"$selected_model" "$agent_name" "$model_override" \
			"${extra_args[@]+"${extra_args[@]}"}"; then
			attempt_exit=0
		else
			attempt_exit=$?
		fi

		if [[ "$attempt_exit" -eq 0 ]]; then
			_cmd_run_finish "$session_key" "complete"
			return 0
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

show_help() {
	cat <<'EOF'
headless-runtime-helper.sh - Model-aware headless runtime (OpenCode default, Claude CLI opt-in)

Usage:
  headless-runtime-helper.sh select [--role pulse|worker] [--model provider/model]
  headless-runtime-helper.sh run --role pulse|worker --session-key KEY --dir PATH --title TITLE (--prompt TEXT | --prompt-file FILE) [--model provider/model] [--agent NAME] [--runtime opencode|claude] [--opencode-arg ARG] [--detach]
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
  AIDEVOPS_HEADLESS_MODELS defaults to anthropic/claude-sonnet-4-6,openai/gpt-4o
  AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST can restrict selection to providers like: openai
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
