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
# Large function groups are split into sub-libraries (GH#19699):
#   - headless-runtime-provider.sh  (auth + backoff)
#   - headless-runtime-failure.sh   (dispatch claim + fast-fail)
#   - headless-runtime-model.sh     (model choice + cmd builders)
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

# Resolve SCRIPT_DIR if not set by caller, so sub-library sourcing works when
# the lib is sourced directly (e.g. from a test harness). Matches the
# issue-sync-lib.sh precedent; a no-op when the caller has already set it.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

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

# --- Sub-library sourcing (GH#19699) ---
# Provider auth + backoff (Sections 2-3)
# shellcheck source=./headless-runtime-provider.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-provider.sh"

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

# --- Sub-library sourcing (GH#19699) ---
# Failure reporting (Section 11: dispatch claim + fast-fail)
# shellcheck source=./headless-runtime-failure.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-failure.sh"

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

# --- Sub-library sourcing (GH#19699) ---
# Model choice + cmd builders (Sections 13-14)
# shellcheck source=./headless-runtime-model.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-model.sh"
