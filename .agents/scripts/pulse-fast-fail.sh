#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-fast-fail.sh — Per-issue fast-fail counter with cause-aware backoff (rate-limit vs crash). t1888, GH#2076, GH#17384.
#
# Extracted from pulse-wrapper.sh in Phase 2 of the phased decomposition
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
#   - _ff_key
#   - _ff_load
#   - _ff_query_pool_retry_seconds
#   - _ff_with_lock
#   - _ff_save
#   - fast_fail_record
#   - _fast_fail_record_locked
#   - fast_fail_reset
#   - _fast_fail_reset_locked
#   - fast_fail_is_skipped
#   - fast_fail_prune_expired
#   - _fast_fail_prune_expired_locked
#   - _ff_mark_enrichment_done
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_FAST_FAIL_LOADED:-}" ]] && return 0
_PULSE_FAST_FAIL_LOADED=1

#######################################
# Return the fast-fail state key for an issue.
# Arguments: $1 issue_number, $2 repo_slug
#######################################
_ff_key() {
	local issue_number="$1"
	local repo_slug="$2"
	printf '%s/%s' "$repo_slug" "$issue_number"
	return 0
}

#######################################
# Load the fast-fail state file as JSON.
# Outputs "{}" on missing or corrupt file.
#######################################
_ff_load() {
	if [[ ! -f "$FAST_FAIL_STATE_FILE" ]]; then
		printf '{}'
		return 0
	fi
	local content
	content=$(cat "$FAST_FAIL_STATE_FILE" 2>/dev/null) || content="{}"
	# Validate JSON; reset if corrupt
	if ! printf '%s' "$content" | jq empty 2>/dev/null; then
		printf '{}'
		return 0
	fi
	printf '%s' "$content"
	return 0
}

#######################################
# Query the OAuth account pool to determine retry strategy for rate limits.
#
# Checks whether any non-rate-limited accounts are available for the given
# provider. If yes, returns 0 (immediate retry with rotation). If all
# accounts are exhausted, returns the number of seconds until the earliest
# account recovers via stdout.
#
# Uses the same logic as parse_retry_after_seconds() in headless-runtime-helper.sh
# but is self-contained so the pulse can query without launching a subprocess.
#
# Arguments:
#   $1 - provider (anthropic, openai, cursor, google)
# Stdout: seconds until earliest recovery (0 = accounts available now,
#         -1 = no pool configured / query failed)
# Returns: 0 always (best-effort)
#######################################
_ff_query_pool_retry_seconds() {
	local provider="${1:-anthropic}"
	local pool_file="${HOME}/.aidevops/oauth-pool.json"

	# No pool file = no pool management = signal "no pool configured" so caller
	# falls through to exponential backoff instead of treating it as "available now".
	if [[ ! -f "$pool_file" ]]; then
		echo "-1"
		return 0
	fi

	local result
	result=$(POOL_FILE="$pool_file" PROVIDER="$provider" python3 -c "
import json, os, time, sys
try:
    pool = json.load(open(os.environ['POOL_FILE']))
    now_ms = int(time.time() * 1000)
    accounts = pool.get(os.environ['PROVIDER'], [])
    if not accounts:
        # No accounts configured for this provider — can't determine availability
        print(-1); sys.exit(0)
    min_remaining = None
    for a in accounts:
        cd = a.get('cooldownUntil')
        if cd and int(cd) > now_ms and a.get('status') == 'rate-limited':
            remaining_s = max(1, (int(cd) - now_ms) // 1000)
            min_remaining = min(min_remaining, remaining_s) if min_remaining else remaining_s
        else:
            # At least one account is available — immediate retry
            print(0); sys.exit(0)
    # All accounts rate-limited — return shortest wait
    print(min_remaining or 0)
except Exception:
    print(-1)
" 2>/dev/null) || result="-1"

	[[ "$result" =~ ^-?[0-9]+$ ]] || result="-1"
	echo "$result"
	return 0
}

#######################################
# Acquire an exclusive lock for fast-fail state read-modify-write.
# Uses mkdir atomicity (same pattern as circuit-breaker-helper.sh).
# Both pulse-wrapper.sh and worker-watchdog.sh write to the same
# state file — this prevents lost increments from concurrent updates.
# (GH#2076, CodeRabbit review)
#
# Arguments: command and arguments to run under lock
# Returns: exit code of the wrapped command
#######################################
_ff_with_lock() {
	local lock_dir="${FAST_FAIL_STATE_FILE}.lockdir"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			echo "[pulse-wrapper] _ff_with_lock: lock acquisition timed out" >>"$LOGFILE"
			return 1
		fi
		sleep 0.1
	done
	local rc=0
	"$@" || rc=$?
	rmdir "$lock_dir" 2>/dev/null || true
	return "$rc"
}

#######################################
# Write updated state atomically (tmp + mv).
# Arguments: $1 JSON string
#######################################
_ff_save() {
	local json="$1"
	local state_dir
	state_dir=$(dirname "$FAST_FAIL_STATE_FILE")
	mkdir -p "$state_dir" 2>/dev/null || true
	local tmp_file
	tmp_file=$(mktemp "${state_dir}/.fast-fail-counter.XXXXXX" 2>/dev/null) || return 0
	if printf '%s\n' "$json" >"$tmp_file"; then
		mv "$tmp_file" "$FAST_FAIL_STATE_FILE" || {
			rm -f "$tmp_file"
			echo "[pulse-wrapper] _ff_save: failed to move fast-fail state" >>"$LOGFILE"
		}
	else
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _ff_save: failed to write fast-fail state" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Record a worker failure for an issue with cause-aware retry strategy.
#
# Rate-limit failures query the account pool before deciding on backoff.
# Non-rate-limit failures use exponential backoff (10m → 20m → ... → 7d).
#
# Acquires a file lock to prevent lost updates from concurrent
# pulse-wrapper and worker-watchdog writes. (GH#2076, GH#17384)
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - reason (rate_limit, backoff, stall, idle, thrash, runtime,
#                no_worker_process, cli_usage_output, local_error, etc.)
#   $4 - provider (optional, for rate-limit pool queries; default: anthropic)
#   $5 - crash_type (optional: "overwhelmed" | "no_work" | "partial" | "")
#######################################
fast_fail_record() {
	_ff_with_lock _fast_fail_record_locked "$@" || return 0
	return 0
}

_fast_fail_record_locked() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="${3:-launch_failure}"
	local provider="${4:-anthropic}"
	local crash_type="${5:-}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local key now state
	key=$(_ff_key "$issue_number" "$repo_slug")
	now=$(date +%s)
	state=$(_ff_load)

	# Read existing entry (reset all fields if expired)
	local existing_ts existing_count existing_backoff
	existing_ts=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].ts // 0' 2>/dev/null) || existing_ts=0
	existing_count=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].count // 0' 2>/dev/null) || existing_count=0
	existing_backoff=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].backoff_secs // 0' 2>/dev/null) || existing_backoff=0
	[[ "$existing_ts" =~ ^[0-9]+$ ]] || existing_ts=0
	[[ "$existing_count" =~ ^[0-9]+$ ]] || existing_count=0
	[[ "$existing_backoff" =~ ^[0-9]+$ ]] || existing_backoff=0

	local age=$((now - existing_ts))
	if [[ "$age" -ge "$FAST_FAIL_EXPIRY_SECS" ]]; then
		existing_count=0
		existing_backoff=0
	fi

	# ── Decide retry strategy based on failure cause ──
	local new_count="$existing_count"
	local new_backoff="$existing_backoff"
	local retry_after=0
	local log_action=""

	case "$reason" in
	rate_limit* | backoff)
		# Rate-limit: check if other accounts are available
		local pool_wait
		pool_wait=$(_ff_query_pool_retry_seconds "$provider")

		if [[ "$pool_wait" == "0" ]]; then
			# Other accounts available — immediate retry, no counter increment.
			# The next dispatch will rotate to a different account automatically.
			retry_after=0
			log_action="rate_limit_rotate (accounts available, immediate retry)"
		elif [[ "$pool_wait" == "-1" ]]; then
			# No pool configured or query failed — use exponential backoff
			new_count=$((existing_count + 1))
			new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : FAST_FAIL_INITIAL_BACKOFF_SECS))
			[[ "$new_backoff" -gt "$FAST_FAIL_MAX_BACKOFF_SECS" ]] && new_backoff="$FAST_FAIL_MAX_BACKOFF_SECS"
			retry_after=$((now + new_backoff))
			log_action="rate_limit_no_pool (no pool data, backoff=${new_backoff}s)"
		else
			# All accounts exhausted — wait for earliest recovery.
			# Use pool_wait for retry_after but keep backoff_secs on the
			# exponential ladder so a subsequent failure doesn't reset to
			# a short pool cooldown value.
			new_count=$((existing_count + 1))
			retry_after=$((now + pool_wait))
			new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : FAST_FAIL_INITIAL_BACKOFF_SECS))
			[[ "$new_backoff" -gt "$FAST_FAIL_MAX_BACKOFF_SECS" ]] && new_backoff="$FAST_FAIL_MAX_BACKOFF_SECS"
			log_action="rate_limit_exhausted (all accounts rate-limited, wait=${pool_wait}s, backoff_stage=${new_backoff}s)"
		fi
		;;

	*)
		# Non-rate-limit failure: exponential backoff
		new_count=$((existing_count + 1))
		new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : FAST_FAIL_INITIAL_BACKOFF_SECS))
		[[ "$new_backoff" -gt "$FAST_FAIL_MAX_BACKOFF_SECS" ]] && new_backoff="$FAST_FAIL_MAX_BACKOFF_SECS"
		retry_after=$((now + new_backoff))
		log_action="failure_backoff (count=${new_count}, backoff=${new_backoff}s)"
		;;
	esac

	# Write updated state (include crash_type for diagnostics)
	local updated_state
	updated_state=$(printf '%s' "$state" | jq \
		--arg k "$key" \
		--argjson count "$new_count" \
		--argjson ts "$now" \
		--arg reason "$reason" \
		--argjson retry_after "$retry_after" \
		--argjson backoff_secs "$new_backoff" \
		--arg crash_type "${crash_type:-}" \
		'.[$k] = {"count": $count, "ts": $ts, "reason": $reason, "retry_after": $retry_after, "backoff_secs": $backoff_secs, "crash_type": $crash_type}' 2>/dev/null) || return 0

	# Flag for enrichment on first non-rate-limit failure: a reasoning worker
	# will analyze the issue and add implementation guidance before re-dispatch.
	# Only set once — cleared after enrichment runs.
	local is_rate_limit=false
	case "$reason" in
	rate_limit* | backoff) is_rate_limit=true ;;
	esac
	if [[ "$is_rate_limit" == "false" && "$new_count" -eq 1 ]]; then
		updated_state=$(printf '%s' "$updated_state" | jq \
			--arg k "$key" \
			'.[$k].enrichment_needed = true' 2>/dev/null) || true
	fi

	_ff_save "$updated_state"
	echo "[pulse-wrapper] fast_fail_record: #${issue_number} (${repo_slug}) ${log_action} reason=${reason} crash_type=${crash_type:-unclassified}" >>"$LOGFILE"

	# Trigger tier escalation on non-rate-limit failures only (GH#2076).
	# Rate-limit paths (rate_limit*, backoff) don't escalate — the model isn't
	# the problem, it's provider capacity. Escalating would waste a higher tier.
	# Pass crash_type to escalate_issue_tier for crash-type-aware thresholds:
	# "overwhelmed" escalates immediately, others use default threshold.
	if [[ "$is_rate_limit" == "false" && "$new_count" -gt "$existing_count" ]]; then
		escalate_issue_tier "$issue_number" "$repo_slug" "$new_count" "$reason" "$crash_type" || true
	fi

	return 0
}

#######################################
# Reset the fast-fail counter for an issue.
#
# Called when an issue is confirmed resolved (PR merged, issue closed) —
# NOT on launch success. Previously this was called on launch, which
# defeated the counter entirely since every launch reset it before the
# worker could fail. (GH#2076, GH#17378)
#
# Arguments: $1 issue_number, $2 repo_slug
#######################################
fast_fail_reset() {
	_ff_with_lock _fast_fail_reset_locked "$@" || return 0
	return 0
}

_fast_fail_reset_locked() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local key state updated_state
	key=$(_ff_key "$issue_number" "$repo_slug")
	state=$(_ff_load)

	# Only write if the key exists (avoid unnecessary writes)
	local existing
	existing=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k] // null' 2>/dev/null)
	if [[ "$existing" == "null" || -z "$existing" ]]; then
		return 0
	fi

	updated_state=$(printf '%s' "$state" | jq --arg k "$key" 'del(.[$k])' 2>/dev/null) || return 0
	_ff_save "$updated_state"
	echo "[pulse-wrapper] fast_fail_reset: #${issue_number} (${repo_slug}) counter cleared" >>"$LOGFILE"
	return 0
}

#######################################
# Check if an issue should be skipped due to retry backoff.
#
# An issue is skipped when EITHER condition is true:
#   1. retry_after is in the future (backoff timer hasn't expired)
#   2. count >= FAST_FAIL_SKIP_THRESHOLD (hard stop — too many failures)
#
# The distinction matters for diagnostics:
#   - Condition 1: "waiting for backoff/rate-limit to clear"
#   - Condition 2: "this issue is fundamentally broken, needs human"
#
# Exit codes:
#   0 - issue is skipped (do NOT dispatch)
#   1 - issue is not skipped (safe to dispatch)
# Arguments: $1 issue_number, $2 repo_slug
#######################################
fast_fail_is_skipped() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$repo_slug" ]] || return 1

	local key now state existing_ts existing_count existing_retry_after
	key=$(_ff_key "$issue_number" "$repo_slug")
	now=$(date +%s)
	state=$(_ff_load)

	existing_ts=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].ts // 0' 2>/dev/null) || existing_ts=0
	existing_count=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].count // 0' 2>/dev/null) || existing_count=0
	existing_retry_after=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].retry_after // 0' 2>/dev/null) || existing_retry_after=0
	[[ "$existing_ts" =~ ^[0-9]+$ ]] || existing_ts=0
	[[ "$existing_count" =~ ^[0-9]+$ ]] || existing_count=0
	[[ "$existing_retry_after" =~ ^[0-9]+$ ]] || existing_retry_after=0

	# Check overall expiry (entire entry is stale).
	# Mirror fast_fail_prune_expired(): only expire when BOTH the ts is old
	# AND the retry_after window has passed. This prevents discarding entries
	# that still have an active backoff timer (e.g., rate-limit waits).
	local age=$((now - existing_ts))
	if [[ "$age" -ge "$FAST_FAIL_EXPIRY_SECS" && "$existing_retry_after" -le "$now" ]]; then
		return 1 # Expired — not skipped
	fi

	# Hard stop: too many non-rate-limit failures
	if [[ "$existing_count" -ge "$FAST_FAIL_SKIP_THRESHOLD" ]]; then
		echo "[pulse-wrapper] fast_fail_is_skipped: #${issue_number} (${repo_slug}) HARD STOP count=${existing_count}>=${FAST_FAIL_SKIP_THRESHOLD}" >>"$LOGFILE"
		return 0 # Skipped
	fi

	# Backoff timer: retry_after is in the future
	if [[ "$existing_retry_after" -gt "$now" ]]; then
		local wait_remaining=$((existing_retry_after - now))
		echo "[pulse-wrapper] fast_fail_is_skipped: #${issue_number} (${repo_slug}) BACKOFF wait=${wait_remaining}s retry_after=$(date -r "$existing_retry_after" '+%H:%M:%S' 2>/dev/null || echo "$existing_retry_after")" >>"$LOGFILE"
		return 0 # Skipped — backoff timer active
	fi

	return 1 # Safe to dispatch
}

#######################################
# Prune expired entries from the fast-fail state file.
# An entry is expired when its ts is older than FAST_FAIL_EXPIRY_SECS
# AND its retry_after has passed (we don't prune entries that still
# have an active backoff timer, even if they're old).
# Called periodically to keep the file small.
#######################################
fast_fail_prune_expired() {
	_ff_with_lock _fast_fail_prune_expired_locked || return 0
	return 0
}

_fast_fail_prune_expired_locked() {
	local now state pruned
	now=$(date +%s)
	state=$(_ff_load)

	pruned=$(printf '%s' "$state" | jq \
		--argjson now "$now" \
		--argjson expiry "$FAST_FAIL_EXPIRY_SECS" \
		'with_entries(select(
			(($now - (.value.ts // 0)) < $expiry) or
			((.value.retry_after // 0) > $now)
		))' 2>/dev/null) || return 0

	local before_count after_count
	before_count=$(printf '%s' "$state" | jq 'length' 2>/dev/null) || before_count=0
	after_count=$(printf '%s' "$pruned" | jq 'length' 2>/dev/null) || after_count=0

	if [[ "$before_count" -ne "$after_count" ]]; then
		_ff_save "$pruned"
		echo "[pulse-wrapper] fast_fail_prune_expired: pruned $((before_count - after_count)) expired entries" >>"$LOGFILE"
	fi
	return 0
}

# Mark enrichment as done in the fast-fail state (called under lock).
_ff_mark_enrichment_done() {
	local issue_number="$1"
	local repo_slug="$2"
	local key state

	key=$(_ff_key "$issue_number" "$repo_slug")
	state=$(_ff_load)

	local updated_state
	updated_state=$(printf '%s' "$state" | jq \
		--arg k "$key" \
		'if .[$k] then .[$k].enrichment_needed = false | .[$k].enrichment_done = true else . end' \
		2>/dev/null) || return 0

	_ff_save "$updated_state"
	return 0
}
