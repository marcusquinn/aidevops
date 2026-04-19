#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Library -- Stable Utility Functions (t2013)
# =============================================================================
# Shared functions extracted from headless-runtime-helper.sh that provide
# stable utility capabilities: state DB, provider auth, backoff, output
# parsing, metrics, sandbox passthrough, worker contract, watchdog, DB merge,
# dispatch ledger, failure reporting, canary, model choice, and cmd builders.
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning, timeout_sec)
#   - worker-lifecycle-common.sh (escalate_issue_tier, resolve_model_tier)
#   - Constants from headless-runtime-helper.sh (STATE_DIR, STATE_DB, etc.)
#   - bash 3.2+, sqlite3, python3, jq
#
# Mirrors the issue-sync-helper.sh + issue-sync-lib.sh split precedent.
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_LIB_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_LIB_LOADED=1

# --- Section 1: State DB ---

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

# --- Section 2: Provider Auth ---

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
	# returns filesystem metadata (free blocks), not file mtime -- causing
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
	local | ollama)
		# Local/Ollama providers are always considered available (no auth needed -- local daemon)
		return 0
		;;
	*)
		# Unknown provider: assume available (don't silently drop unknown providers)
		return 0
		;;
	esac
}

# --- Section 3: Backoff Parsing/Recording ---

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
            # At least one account is available -- no provider-level backoff
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

# t1835: Reduced from 900s -- Anthropic API rate limits clear in 10-60s.
# 900s was blocking interactive sessions for 15 minutes unnecessarily.
numeric = re.search(r"\b429\b", text)
if numeric:
    print(60)
    sys.exit(0)

print(0)
PY
	return 0
}

attempt_pool_recovery() {
	local provider="$1"
	local reason="$2"
	local details_file="$3"

	# t2249: oauth-pool-helper.sh is now XDG_DATA_HOME-aware, so rotation from
	# a headless worker targets the worker's ISOLATED auth.json
	# (${XDG_DATA_HOME}/opencode/auth.json), not the shared interactive file.
	# The original "rotate kills interactive session" hazard is structurally
	# resolved.
	#
	# Mid-run rotation is still skipped here because opencode caches OAuth
	# access tokens in memory for the active session — rewriting auth.json
	# mid-run does NOT invalidate those cached tokens. The useful signal is
	# mark-failure below: it updates shared pool metadata so the pre-dispatch
	# check in invoke_opencode will rotate the NEXT worker to a healthy
	# account. This is how cascade dispatches recover from rate_limit.
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

	# Safe: mark the account as failed in pool metadata. Pre-dispatch rotation
	# in invoke_opencode reads this metadata to route the NEXT worker away.
	"$OAUTH_POOL_HELPER" mark-failure "$provider" "$reason" "$retry_seconds" >/dev/null 2>&1 || true

	# t2249: mid-run rotation intentionally skipped — opencode caches OAuth
	# tokens in memory, so rewriting auth.json mid-run has no effect on the
	# already-running model call. The NEXT worker's pre-dispatch check picks
	# up the mark-failure above and rotates the isolated auth before spawn.
	print_warning "${provider} ${reason} detected; recorded backoff (in-flight rotation no-op — opencode token cache)"
	return 1
}

record_provider_backoff() {
	local provider="$1"
	local reason="$2"
	local details_file="$3"
	local model="${4:-$provider}"
	local details retry_seconds auth_signature retry_after backoff_key

	# local_error = worker/sandbox/prompt issue, NOT provider's fault.
	# Skip backoff entirely -- recording it falsely flags healthy providers.
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

# Legacy wrapper -- kept for backward compatibility with cmd_backoff CLI
provider_backoff_active() {
	local provider="$1"
	backoff_active_for_key "$provider" "$provider"
	return $?
}

# --- Section 4: Output Parsing ---

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
	# Only provider errors should trigger backoff -- local failures don't
	# mean the provider is unhealthy.
	if [[ "$lowered" =~ (500|502|503|504|internal\ server\ error|service\ unavailable|gateway|connection\ refused|connection.*reset|overloaded) ]]; then
		printf '%s' "provider_error"
		return 0
	fi
	# Default: local_error -- do NOT record provider backoff for this
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
        continue
    part = obj.get("part") or {}
    if part.get("sessionID"):
        session_id = part["sessionID"]
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

#######################################
# _log_empty_result_gaps: scan worker output for empty tool results that
# preceded the model stopping. Each is a gap (wrong path, missing prefix)
# that can be closed with better hints or fallback patterns.
# Logs to ~/.aidevops/logs/worker-empty-results.log for pattern analysis.
# Args: $1=output_file $2=model $3=session_key
#######################################
_log_empty_result_gaps() {
	local output_file="$1"
	local model="$2"
	local session_key="$3"

	[[ -f "$output_file" ]] || return 0

	local diag_log="${HOME}/.aidevops/logs/worker-empty-results.log"
	mkdir -p "$(dirname "$diag_log")" 2>/dev/null || true

	local _py_script
	_py_script=$(mktemp "${TMPDIR:-/tmp}/aidevops-empty-gaps.XXXXXX.py") || return 0
	cat >"$_py_script" <<'EMPTYPY'
import json, sys, os, datetime
from pathlib import Path
of = os.environ.get("ER_OUTPUT_FILE", "")
md = os.environ.get("ER_MODEL", "")
sk = os.environ.get("ER_SESSION_KEY", "")
dl = os.environ.get("ER_DIAG_LOG", "")
if not of or not dl:
    sys.exit(0)
lines = Path(of).read_text(errors="ignore").splitlines()
gaps, tc = [], 0
for ln in lines:
    ln = ln.strip()
    if not ln.startswith("{"):
        continue
    try:
        o = json.loads(ln)
    except Exception:
        continue
    if o.get("type") == "tool_use":
        tc += 1
        st = o.get("part", {}).get("state", {})
        ip = st.get("input", {})
        out = (st.get("output", "") or "").strip()
        empty = (out == "" or out == "0" or out == "\n"
                 or ("grep" == o["part"].get("tool", "") and "Found 0 matches" in out))
        if empty:
            det = ((ip.get("command", "") or "")[:120]
                   or (ip.get("pattern", "") or "")[:80]
                   or (ip.get("filePath", "") or "")[:120]
                   or (ip.get("description", "") or "")[:80])
            gaps.append({"t": o["part"].get("tool", ""), "d": det, "i": tc})
if not gaps:
    sys.exit(0)
ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
with open(dl, "a") as f:
    f.write("\n[%s] model=%s session=%s tools=%d empty=%d\n" % (ts, md, sk, tc, len(gaps)))
    for g in gaps:
        f.write("  #%d/%d %s -> EMPTY: %s\n" % (g["i"], tc, g["t"], g["d"]))
print("[empty-result-gaps] %d empty in %d tool calls:" % (len(gaps), tc))
for g in gaps:
    print("  [%d/%d] %s -> EMPTY: %s" % (g["i"], tc, g["t"], g["d"][:100]))
EMPTYPY
	ER_OUTPUT_FILE="$output_file" ER_MODEL="$model" ER_SESSION_KEY="$session_key" ER_DIAG_LOG="$diag_log" \
		python3 "$_py_script" 2>/dev/null || true
	rm -f "$_py_script" 2>/dev/null || true
	return 0
}

# --- Section 5: Metrics ---

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

# --- Section 6: Sandbox Passthrough ---

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
		# OTEL_* is passed through so headless workers under the sandbox
		# can export OTLP traces when OTEL_EXPORTER_OTLP_ENDPOINT is set.
		# Without this, opencode never initialises its OTLP exporter and
		# all aidevops.* plugin span enrichment is silently dropped (t2186).
		AIDEVOPS_* | PULSE_* | GH_* | GITHUB_* | OPENAI_* | ANTHROPIC_* | GOOGLE_* | OPENCODE_* | CLAUDE_* | XDG_* | OTEL_* | REAL_HOME | TMPDIR | TMP | TEMP | RTK_* | VERIFY_*)
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

# --- Section 7: Worker Contract ---

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

	if [[ "$prompt_text" == *"HEADLESS_CONTINUATION_CONTRACT_V"* ]]; then
		printf '%s' "$prompt_text"
		return 0
	fi

	local contract
	contract=$(
		cat <<'EOF'
[HEADLESS_CONTINUATION_CONTRACT_V6]
This is a HEADLESS worker session. No user is present. No user input is available.
You must drive autonomously to completion or an evidence-backed BLOCKED outcome.

Setup shortcuts -- the dispatcher has already done these for you:
- Your worktree is pre-created. Check $WORKER_WORKTREE_PATH env var for the path.
  If set, you are already in the worktree on a feature branch. Do NOT call
  pre-edit-check.sh, worktree-helper.sh, or session-rename tools.
  If not set, create a worktree yourself via worktree-helper.sh add.
- Do NOT call aidevops-update-check.sh -- it exits immediately for headless workers.
- Do NOT call session-rename or session-rename_sync_branch -- your session title
  is already set to the issue title by the dispatcher.

Key file paths (use these directly, do NOT search for them):
- Full-loop workflow: .agents/scripts/commands/full-loop.md
- All agent scripts live under .agents/scripts/ (not scripts/ at root)

Implementation approach:
1. Read the issue body FIRST (gh issue view $WORKER_ISSUE_NUMBER). Look for a "Worker Guidance" or "How" section -- it contains the files to modify, reference patterns, and verification commands. Follow these directly instead of exploring the codebase broadly.
2. Budget discipline: spend at most 25% of your effort on reading/exploring. After reading the issue body + 2-3 reference files mentioned in it, start writing code. Do not read entire helper scripts -- read only the sections you will modify.
3. If the issue body lacks file paths and implementation steps, exit BLOCKED with reason "missing implementation context" so the dispatcher can enrich the body. Do NOT explore broadly to compensate for a vague issue.

Empty tool results:
If a tool call returns empty output, it usually means the path or pattern was wrong, not that the resource is missing. Common causes: missing .agents/ prefix on paths, wrong glob pattern, file moved/renamed. Retry with corrected paths before giving up. If retries also fail, log what you tried and continue with the next step. Do NOT stop the session over one empty result.

Commit and PR shortcut:
After implementing, use full-loop-helper.sh commit-and-pr to collapse commit+push+PR+merge-summary into one call:
  PR_NUMBER=$(full-loop-helper.sh commit-and-pr --issue $WORKER_ISSUE_NUMBER --message "feat: description" --summary "what was done" --testing "how verified")
Then merge: full-loop-helper.sh merge "$PR_NUMBER"

Mandatory behavior:
4. Never ask for user confirmation, approval, or next steps. No user will respond.
5. Never emit user-directed language ("If you want...", "Let me know...", "Should I...").
6. Reading the issue and reading docs are SETUP -- not completion. You MUST continue through implementation, commit, push, and PR creation after setup.
7. Do not stop at "PR opened" or "in review" states. Continue through review polling, merge readiness checks, merge, and required closing comments.
8. If merge/close cannot complete, exit only with a clear BLOCKED outcome and evidence (failing check, missing permission, unresolved conflict, or explicit policy gate).
9. Model escalation before BLOCKED (GH#14964): BLOCKED is only valid after exhausting all autonomous solution paths. Before exiting BLOCKED, attempt model escalation -- retry with the next tier (sonnet -> opus via --model anthropic/claude-opus-4-6). Review-policy metadata, nominal GitHub states, and lower-tier model limits are NOT valid blockers on their own.

Activity watchdog constraint -- CRITICAL:
A continuous watchdog monitors your output. If you produce no tool calls or text
output for 300 seconds, you will be killed. Therefore:
  - NEVER use sleep/wait/poll longer than 240 seconds.
  - For review-bot-gate polling, use the --timeout flag (max 240s per poll cycle).
  - If a CI check or merge is slow, emit a status message between waits to keep
    the watchdog alive. Any tool call or text output resets the 300s timer.
  - Prefer short poll intervals (30-60s) with status output between iterations.

Pre-exit self-check -- MANDATORY:
Before ending your session, verify ALL of these:
  - At least one commit with implementation changes exists on your branch.
  - A PR exists for your branch: run gh pr list --head YOUR_BRANCH_NAME
  - A MERGE_SUMMARY comment exists on the PR (full-loop step 4.2.1). Verify: gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --jq '[.[] | select(.body | test("MERGE_SUMMARY"))] | length' returns 1. If 0, post it now -- the merge pass uses it for closing comments.
  - If any check fails, you are NOT done -- continue working.
  - The only valid exit states are FULL_LOOP_COMPLETE or BLOCKED with evidence.
EOF
	)

	printf '%s\n\n%s' "$prompt_text" "$contract"
	return 0
}

# --- Section 8: Activity Watchdog (inline fallback) ---

#######################################
# Activity watchdog for _invoke_opencode.
#
# Runs as a background process alongside the worker. Polls the output
# file for LLM activity indicators (JSON events from opencode: text,
# tool, reasoning, step_start). If none appear within the timeout,
# kills the worker process.
#
# The initial output always contains the sandbox startup line (~300 bytes).
# This is NOT activity -- it's just the executor logging. Real activity
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
	local session_key="${4:-}"
	local stall_timeout="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-600}"
	[[ "$stall_timeout" =~ ^[0-9]+$ ]] || stall_timeout=600

	# GH#17549: Continuous activity watchdog.
	#
	# Phase 1 (fast, 0-60s): any output at all. Zero bytes = dead runtime.
	# Phase 2 (continuous): monitors file growth. If the output file stops
	#   growing for stall_timeout seconds, the worker is stalled -- kill it.
	#
	# Previous design (broken): returned 0 after first LLM activity event,
	# never monitoring again. Workers that stalled mid-session were invisible.
	local phase1_timeout="${HEADLESS_PHASE1_TIMEOUT_SECONDS:-60}"
	[[ "$phase1_timeout" =~ ^[0-9]+$ ]] || phase1_timeout=60

	local poll_interval=10
	local phase1_passed=0
	local phase1_elapsed=0
	local last_size=0
	local stall_seconds=0

	while true; do
		# Worker exited on its own -- watchdog not needed
		if ! kill -0 "$worker_pid" 2>/dev/null; then
			return 0
		fi

		local current_size=0
		if [[ -f "$output_file" ]]; then
			current_size=$(wc -c <"$output_file" 2>/dev/null || echo "0")
			current_size="${current_size##* }"
		fi

		# Phase 1: any output at all
		if [[ "$phase1_passed" -eq 0 ]]; then
			if [[ "$current_size" -gt 0 ]]; then
				phase1_passed=1
				last_size="$current_size"
				stall_seconds=0
			else
				phase1_elapsed=$((phase1_elapsed + poll_interval))
				if [[ "$phase1_elapsed" -ge "$phase1_timeout" ]]; then
					_watchdog_kill "$worker_pid" "$exit_code_file" "$output_file" \
						"phase1: zero output in ${phase1_timeout}s -- runtime failed to start" "$session_key"
					return 0
				fi
			fi
			sleep "$poll_interval"
			continue
		fi

		# Phase 2: continuous growth monitoring
		if [[ "$current_size" -gt "$last_size" ]]; then
			# File is growing -- worker is alive
			last_size="$current_size"
			stall_seconds=0
		else
			# No growth -- increment stall counter
			stall_seconds=$((stall_seconds + poll_interval))
		fi

		if [[ "$stall_seconds" -ge "$stall_timeout" ]]; then
			_watchdog_kill "$worker_pid" "$exit_code_file" "$output_file" \
				"stall: no output growth for ${stall_timeout}s (stuck at ${current_size}b)" "$session_key"
			return 0
		fi

		sleep "$poll_interval"
	done
}

#######################################
# Kill a stalled worker and all its children.
# Extracted from _run_activity_watchdog for reuse by both phases.
#
# Args:
#   $1 - worker PID
#   $2 - exit code file
#   $3 - output file
#   $4 - reason string (logged)
#######################################
_watchdog_kill() {
	local worker_pid="$1"
	local exit_code_file="$2"
	local output_file="$3"
	local reason="$4"
	local session_key="${5:-}"

	print_warning "Activity watchdog: ${reason} -- killing worker (PID $worker_pid)"
	# Write the marker BEFORE killing -- the dying subshell may overwrite
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
	printf '\n[WATCHDOG_KILL] timestamp=%s worker_pid=%s reason="%s"\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$worker_pid" "$reason" >>"$output_file" 2>/dev/null || true

	# Release the dispatch claim so the issue is immediately available
	# for re-dispatch instead of waiting for the 30-min TTL.
	if [[ -n "$session_key" ]]; then
		_release_dispatch_claim "$session_key" "watchdog_kill:${reason}"
	fi
	return 0
}

# --- Section 9: DB Merge ---

#######################################
# Merge worker's isolated SQLite DB back to the shared DB.
# Called after worker exits -- no contention risk.
# Uses ATTACH DATABASE to copy session and message rows.
# Non-fatal: merge failure doesn't block cleanup.
#######################################
_merge_worker_db() {
	local isolated_dir="$1"
	local worker_db="${isolated_dir}/opencode/opencode.db"
	local shared_db="${HOME}/.local/share/opencode/opencode.db"

	if [[ ! -f "$worker_db" ]]; then
		return 0
	fi
	if [[ ! -f "$shared_db" ]]; then
		return 0
	fi

	# Merge session and message tables. INSERT OR IGNORE avoids duplicates
	# on the primary key (id). Timeout 5s -- if shared DB is locked by
	# interactive session, skip rather than block cleanup.
	sqlite3 "$shared_db" <<-SQL 2>/dev/null || true
		.timeout 5000
		ATTACH DATABASE '${worker_db}' AS worker;
		INSERT OR IGNORE INTO session SELECT * FROM worker.session;
		INSERT OR IGNORE INTO message SELECT * FROM worker.message;
		DETACH DATABASE worker;
	SQL
	return 0
}

# --- Section 10: Dispatch Ledger / Session Locks ---

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
# already exists with a live PID, returns 1 (duplicate -- caller should exit).
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
				# Live process exists -- duplicate dispatch
				print_warning "Duplicate dispatch blocked: session-key '${lock_session_key}' already has active worker PID ${existing_pid} (GH#6538)"
				return 1
			fi
			# PID is dead -- stale lock, clean up and proceed
		fi
		rm -f "$lock_file"
	fi

	# nice -- lock acquired, this session key is ours
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

# --- Section 11: Failure Reporting ---

#######################################
# Release a dispatch claim by posting a CLAIM_RELEASED comment.
# The dedup guard recognises this and allows immediate re-dispatch
# instead of waiting for the 30-min TTL to expire.
#
# Args:
#   $1 = session_key (contains issue number and repo slug)
#   $2 = reason (logged in the comment for debugging)
#######################################
_release_dispatch_claim() {
	local session_key="$1"
	local reason="${2:-worker_failed}"

	# Extract issue number and repo slug from session key
	# Format: pulse-{login}-{repo}-{issue} or similar
	local issue_number=""
	local repo_slug=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)
	# Try to get repo slug from the dispatch ledger or env
	repo_slug="${DISPATCH_REPO_SLUG:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		print_warning "Cannot release claim: missing issue=$issue_number repo=$repo_slug"
		return 0
	fi

	local comment_body
	comment_body="CLAIM_RELEASED reason=${reason} runner=$(whoami) ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST \
		--field body="$comment_body" \
		>/dev/null 2>&1 || {
		print_warning "Failed to post CLAIM_RELEASED on #${issue_number} (non-fatal)"
	}
	print_info "Released claim on #${issue_number} (reason: ${reason})"
	return 0
}

#######################################
# Acquire the fast-fail mkdir lock with retries.
#
# Args:
#   $1 - lock_dir path
#   $2 - issue_number (for warning message)
#   $3 - repo_slug (for warning message)
# Returns: 0=acquired, 1=timed out
#######################################
_fast_fail_acquire_lock() {
	local lock_dir="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			print_warning "[fast-fail] lock timeout for #${issue_number} (${repo_slug})"
			return 1
		fi
		sleep 0.1
	done
	return 0
}

#######################################
# Read existing count and backoff from fast-fail state file.
# Stale entries (older than expiry_secs) are treated as absent.
#
# Args:
#   $1 - state_file path
#   $2 - key (repo_slug/issue_number)
#   $3 - now (epoch seconds)
#   $4 - expiry_secs
# Sets globals: _FAST_FAIL_EXISTING_COUNT, _FAST_FAIL_EXISTING_BACKOFF
#######################################
_fast_fail_read_state() {
	local state_file="$1"
	local key="$2"
	local now="$3"
	local expiry_secs="$4"
	_FAST_FAIL_EXISTING_COUNT=0
	_FAST_FAIL_EXISTING_BACKOFF=0
	if [[ ! -f "$state_file" ]]; then
		return 0
	fi
	local entry=""
	entry=$(jq -r --arg k "$key" '.[$k] // empty' "$state_file" 2>/dev/null) || entry=""
	if [[ -z "$entry" ]]; then
		return 0
	fi
	local entry_ts=""
	entry_ts=$(printf '%s' "$entry" | jq -r '.ts // 0' 2>/dev/null) || entry_ts=0
	# Expire stale entries
	if [[ $((now - entry_ts)) -ge "$expiry_secs" ]]; then
		return 0
	fi
	_FAST_FAIL_EXISTING_COUNT=$(printf '%s' "$entry" | jq -r '.count // 0' 2>/dev/null) || _FAST_FAIL_EXISTING_COUNT=0
	_FAST_FAIL_EXISTING_BACKOFF=$(printf '%s' "$entry" | jq -r '.backoff_secs // 0' 2>/dev/null) || _FAST_FAIL_EXISTING_BACKOFF=0
	return 0
}

#######################################
# Write updated fast-fail state atomically via tmp+mv.
#
# Args:
#   $1  - state_file path
#   $2  - state_dir path
#   $3  - key (repo_slug/issue_number)
#   $4  - new_count
#   $5  - now (epoch seconds)
#   $6  - reason
#   $7  - retry_after (epoch seconds)
#   $8  - new_backoff (seconds)
#   $9  - crash_type (may be empty)
#######################################
_fast_fail_write_state() {
	local state_file="$1"
	local state_dir="$2"
	local key="$3"
	local new_count="$4"
	local now="$5"
	local reason="$6"
	local retry_after="$7"
	local new_backoff="$8"
	local crash_type="$9"
	local updated_state=""
	if [[ -f "$state_file" ]]; then
		updated_state=$(jq --arg k "$key" \
			--argjson count "$new_count" \
			--argjson ts "$now" \
			--arg reason "$reason" \
			--argjson retry_after "$retry_after" \
			--argjson backoff_secs "$new_backoff" \
			--arg crash_type "${crash_type:-}" \
			'.[$k] = {"count": $count, "ts": $ts, "reason": $reason, "retry_after": $retry_after, "backoff_secs": $backoff_secs, "crash_type": $crash_type}' \
			"$state_file") || {
			echo "Error: Failed to update $state_file" >&2
			updated_state=""
		}
	else
		updated_state=$(printf '{}' | jq --arg k "$key" \
			--argjson count "$new_count" \
			--argjson ts "$now" \
			--arg reason "$reason" \
			--argjson retry_after "$retry_after" \
			--argjson backoff_secs "$new_backoff" \
			--arg crash_type "${crash_type:-}" \
			'.[$k] = {"count": $count, "ts": $ts, "reason": $reason, "retry_after": $retry_after, "backoff_secs": $backoff_secs, "crash_type": $crash_type}' \
			2>/dev/null) || updated_state=""
	fi
	if [[ -z "$updated_state" ]]; then
		return 0
	fi
	local tmp_file=""
	tmp_file=$(mktemp "${state_dir}/.fast-fail-counter.XXXXXX" 2>/dev/null) || tmp_file=""
	if [[ -z "$tmp_file" ]]; then
		return 0
	fi
	printf '%s\n' "$updated_state" >"$tmp_file" 2>/dev/null &&
		mv "$tmp_file" "$state_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null
	return 0
}

#######################################
# Report worker failure to the shared fast-fail counter and trigger
# tier escalation when threshold is reached.
#
# Previously, only the pulse (recover_failed_launch_state) and launchd
# watchdog wrote to the counter -- both asynchronous, discovering failures
# 10-30 minutes after the worker died. This function lets the worker
# self-report immediately on exit, so escalation fires within seconds
# instead of 60-90+ minutes. The pulse path remains as a backup for
# workers that crash hard before reaching this function.
#
# Uses the same state file and locking as pulse-wrapper.sh and
# worker-watchdog.sh (fast-fail-counter.json + mkdir lock).
#
# Args:
#   $1 - session_key (e.g., "issue-marcusquinn-aidevops-17642")
#   $2 - failure reason (premature_exit, rate_limit, etc.)
#   $3 - crash_type (optional, e.g., "overwhelmed")
#######################################
_report_failure_to_fast_fail() {
	local session_key="$1"
	local reason="${2:-worker_failed}"
	local crash_type="${3:-}"

	# Extract issue number from session key (last numeric segment)
	local issue_number=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)
	local repo_slug="${DISPATCH_REPO_SLUG:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		return 0
	fi

	# Only report for worker role (not pulse/triage sessions)
	if [[ "$session_key" != issue-* ]]; then
		return 0
	fi

	local state_file="${HOME}/.aidevops/.agent-workspace/supervisor/fast-fail-counter.json"
	local state_dir
	state_dir=$(dirname "$state_file")
	mkdir -p "$state_dir" 2>/dev/null || true

	# Acquire lock (shared with pulse-wrapper.sh and worker-watchdog.sh)
	local lock_dir="${state_file}.lockdir"
	_fast_fail_acquire_lock "$lock_dir" "$issue_number" "$repo_slug" || return 0

	local key now
	key="${repo_slug}/${issue_number}"
	now=$(date +%s)

	local initial_backoff="${FAST_FAIL_INITIAL_BACKOFF_SECS:-600}"
	local max_backoff="${FAST_FAIL_MAX_BACKOFF_SECS:-604800}"
	local expiry_secs="${FAST_FAIL_EXPIRY_SECS:-604800}"

	# Read current state -- sets _FAST_FAIL_EXISTING_COUNT and _FAST_FAIL_EXISTING_BACKOFF
	_fast_fail_read_state "$state_file" "$key" "$now" "$expiry_secs"
	local existing_count="$_FAST_FAIL_EXISTING_COUNT"
	local existing_backoff="$_FAST_FAIL_EXISTING_BACKOFF"

	# Non-rate-limit failures: increment + exponential backoff
	local new_count=$((existing_count + 1))
	local new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : initial_backoff))
	[[ "$new_backoff" -gt "$max_backoff" ]] && new_backoff="$max_backoff"
	local retry_after=$((now + new_backoff))

	# Write updated state atomically (tmp + mv)
	_fast_fail_write_state "$state_file" "$state_dir" "$key" "$new_count" "$now" \
		"$reason" "$retry_after" "$new_backoff" "$crash_type"

	# Release lock
	rmdir "$lock_dir" 2>/dev/null || true

	print_info "[fast-fail] #${issue_number} (${repo_slug}) count=${new_count} backoff=${new_backoff}s reason=${reason} crash_type=${crash_type:-unclassified}"

	# Trigger tier escalation (escalate_issue_tier from worker-lifecycle-common.sh)
	# Only fires when new_count == threshold -- not on every failure.
	# Pass crash_type so escalation uses crash-type-aware thresholds:
	# "overwhelmed" escalates immediately (threshold=1).
	if [[ "$new_count" -gt "$existing_count" ]]; then
		escalate_issue_tier "$issue_number" "$repo_slug" "$new_count" "$reason" "$crash_type" || true
	fi

	return 0
}

# --- Section 12: Canary + Version Pin ---

CANARY_CACHE_TTL_SECONDS="${CANARY_CACHE_TTL_SECONDS:-1800}"
CANARY_TIMEOUT_SECONDS="${CANARY_TIMEOUT_SECONDS:-60}"

#######################################
# Version guard -- enforce OPENCODE_PINNED_VERSION before worker launch.
#
# Something outside our control (unknown process, worker side-effect)
# periodically upgrades opencode to @latest. This guard runs on every
# canary check and reinstalls the pinned version if it drifted.
# Cheap: one `opencode --version` + optional npm install.
#######################################
_enforce_opencode_version_pin() {
	local pin="${OPENCODE_PINNED_VERSION:-}"
	# No pin or pin is "latest" -> nothing to enforce
	if [[ -z "$pin" || "$pin" == "latest" ]]; then
		return 0
	fi

	local installed
	installed=$("$OPENCODE_BIN_DEFAULT" --version 2>/dev/null || echo "unknown")
	installed="${installed#v}"
	installed="${installed%%[[:space:]]*}"

	if [[ "$installed" == "$pin" ]]; then
		return 0
	fi

	print_warning "OpenCode version drift: installed=$installed, pin=$pin -- reinstalling"
	if npm install -g "opencode-ai@${pin}" >/dev/null 2>&1; then
		print_info "OpenCode restored to ${pin}"
	else
		print_warning "Failed to restore OpenCode to ${pin} -- canary will catch if broken"
	fi
	return 0
}

_run_canary_test() {
	local requested_model="${1:-}"
	local cache_file="${STATE_DIR}/canary-last-pass"

	# Check cache -- skip if last canary passed recently
	if [[ -f "$cache_file" ]]; then
		local last_pass
		last_pass=$(cat "$cache_file" 2>/dev/null || echo "0")
		local now
		now=$(date +%s)
		local age=$((now - last_pass))
		if [[ "$age" -lt "$CANARY_CACHE_TTL_SECONDS" ]]; then
			return 0
		fi
	fi

	local canary_output
	canary_output=$(mktemp "${TMPDIR:-/tmp}/aidevops-canary.XXXXXX")

	# Run WITH plugins (not --pure) so our oauth-pool auth is available.
	# The canary must validate the same provider/model the upcoming run will use,
	# otherwise OpenAI opt-in runs still fail behind an Anthropic-only gate.
	local canary_model="$requested_model"
	if [[ -z "$canary_model" ]]; then
		while IFS= read -r canary_model; do
			[[ -n "$canary_model" ]] && break
		done < <(get_configured_models)
	fi
	# Fallback to the script-level default if routing resolution yielded nothing.
	if [[ -z "$canary_model" ]]; then
		canary_model="$DEFAULT_HEADLESS_MODELS"
	fi
	local canary_exit=0

	# GH#17829: Detect running opencode server and build attach args.
	# The canary must test the same mode workers will use -- if a server is
	# running, both canary and workers need --attach to avoid conflicts.
	local canary_attach_args=()
	local _canary_server_info=""
	if _canary_server_info=$(_detect_opencode_server); then
		local _canary_url _canary_pass
		_canary_url=$(echo "$_canary_server_info" | head -1)
		_canary_pass=$(echo "$_canary_server_info" | tail -1)
		canary_attach_args=(--attach "$_canary_url" --password "$_canary_pass")
	fi

	# DB isolation for canary: give it a fresh temp DB so it does not open
	# the shared opencode.db (which can be multi-GB with thousands of
	# accumulated sessions). Without this, opencode startup against the
	# shared DB takes >20s and the canary times out even when the model
	# responds correctly. Same pattern workers already use (GH#17549).
	local _canary_data_dir=""
	_canary_data_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-canary-db.XXXXXX")
	mkdir -p "${_canary_data_dir}/opencode"
	# Copy auth.json so the canary has valid tokens
	local _oc_auth="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json"
	if [[ -f "$_oc_auth" ]]; then
		cp "$_oc_auth" "${_canary_data_dir}/opencode/auth.json" 2>/dev/null || true
	fi

	# Process-tree timeout: the `opencode` npm distribution ships a Node.js
	# wrapper (#!/usr/bin/env node) that spawns the Go binary (.opencode)
	# as a child via child_process.spawnSync. A `perl alarm` only delivers
	# SIGALRM to the direct child (the Node wrapper); the Go grandchild
	# does NOT inherit the ITIMER_REAL and survives the alarm, orphaning
	# into the pulse service cgroup with PPID=systemd. `timeout(1)` puts
	# the whole invocation in a new process group and, on firing, signals
	# the entire group (SIGTERM, then SIGKILL after --kill-after grace),
	# catching the grandchild too. (GH#19623)
	local _canary_timeout_cmd=()
	if command -v timeout >/dev/null 2>&1; then
		# GNU coreutils timeout (Linux default; macOS via `brew install coreutils`)
		_canary_timeout_cmd=(timeout --kill-after=5s "${CANARY_TIMEOUT_SECONDS}s")
	elif command -v gtimeout >/dev/null 2>&1; then
		# macOS with coreutils installed as gtimeout
		_canary_timeout_cmd=(gtimeout --kill-after=5s "${CANARY_TIMEOUT_SECONDS}s")
	else
		# Last-resort fallback: perl alarm. Does NOT reap the Go grandchild
		# when opencode is installed via npm; install coreutils
		# (`brew install coreutils`) for clean behaviour.
		_canary_timeout_cmd=(perl -e "alarm $CANARY_TIMEOUT_SECONDS; exec @ARGV" --)
	fi

	XDG_DATA_HOME="$_canary_data_dir" \
		"${_canary_timeout_cmd[@]}" \
		"$OPENCODE_BIN_DEFAULT" run "Reply with exactly: CANARY_OK" \
		-m "$canary_model" --dir "${HOME}" \
		${canary_attach_args[@]+"${canary_attach_args[@]}"} \
		>"$canary_output" 2>&1 || canary_exit=$?

	# Clean up canary's isolated DB dir
	rm -rf "$_canary_data_dir" 2>/dev/null || true

	# Output-aware check: the model responding "CANARY_OK" is the real
	# success signal. The exit code reflects process lifecycle (opencode
	# cleanup time, signal handling) not model health. Previously this
	# required exit=0 AND CANARY_OK, but opencode 1.4.x takes longer to
	# shut down cleanly — the timeout mechanism kills it (exit=124/SIGTERM
	# or 137/SIGKILL on Linux; exit=142/SIGALRM on perl-alarm fallback)
	# even after the model has already responded. Checking output alone is
	# safe because CANARY_OK can only appear if the model actually
	# processed the prompt and generated a response.
	if grep -q "CANARY_OK" "$canary_output" 2>/dev/null; then
		# Cache the pass timestamp
		mkdir -p "${STATE_DIR}" 2>/dev/null || true
		date +%s >"$cache_file"
		rm -f "$canary_output"
		return 0
	fi

	# Canary failed -- log diagnostics (capture enough output to surface API errors,
	# not just startup hooks which is all head -5 typically showed)
	local oc_version
	oc_version=$("$OPENCODE_BIN_DEFAULT" --version 2>/dev/null || echo "unknown")
	print_warning "Canary test FAILED (exit=$canary_exit, model=$canary_model, opencode=$oc_version, timeout=${CANARY_TIMEOUT_SECONDS}s)"
	print_warning "Output (last 20 lines): $(tail -20 "$canary_output" 2>/dev/null || echo '<empty>')"
	rm -f "$canary_output"
	return 1
}

# --- Section 13: Model Choice ---

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

# --- Section 14: OpenCode Server Detection + Cmd Builders ---

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
	# Emit any extra args passed as positional parameters
	while [[ $# -gt 0 ]]; do
		printf '%s\0' "$1"
		shift
	done
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
	# Emit any extra args
	while [[ $# -gt 0 ]]; do
		printf '%s\0' "$1"
		shift
	done
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
