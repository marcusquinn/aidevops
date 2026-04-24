#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-backoff-helper.sh — Per-issue rate_limit backoff gate (t2781, GH#20680)
#
# Prevents repeated dispatch of issues that repeatedly produce rate_limit exits.
# Reads headless-runtime-metrics.jsonl to count per-issue rate_limit exits within
# a lookback window, then applies a graduated cooldown.
#
# Problem being solved:
#   headless-runtime-metrics.jsonl shows 407 rate_limit events (~31.5h burn).
#   The existing fast_fail rate_limit path immediately retries when another account
#   is available — so a pool of N accounts means an issue can fail N times per
#   cycle with zero cooldown. This compounds cost at scale.
#
# Backoff schedule (tuned against observed 407-event cluster):
#   failures | cooldown
#   ---------|----------
#   1        | 5 min  (300s)   — single fluke; retry quickly
#   2        | 30 min (1800s)  — pattern emerging; cool off
#   3        | 2h     (7200s)  — systemic; wait for capacity recovery
#   4+       | 24h    (86400s) — apply needs-maintainer-review too
#
# Subcommands:
#   check <issue_num> [<slug>]  — exit 0 if clear, exit 1 if cooldown active,
#                                 exit 2 on error (fail-open: dispatch proceeds)
#   help                        — usage information
#
# Exit codes (check):
#   0  — clear; dispatch may proceed
#   1  — cooldown active; prints "BACKOFF_ACTIVE reason=rate_limit_cooldown next=<ts>"
#        and next-eligible human timestamp to stderr
#   2  — error (fail-open: dispatch proceeds with warning logged)
#
# Environment overrides:
#   DISPATCH_BACKOFF_METRICS_FILE     — path to headless-runtime-metrics.jsonl
#                                       (default: ~/.aidevops/logs/headless-runtime-metrics.jsonl)
#   DISPATCH_BACKOFF_LOOKBACK_SECS    — how far back to count failures (default 604800 = 7 days)
#   DISPATCH_BACKOFF_NMR_THRESHOLD    — failure count at which to request NMR (default 4)
#   AIDEVOPS_SKIP_DISPATCH_BACKOFF=1  — emergency bypass (dispatch proceeds unconditionally)
#
# Integration:
#   Sourced by pulse-dispatch-engine.sh. The check_dispatch_backoff() function
#   is called in _dff_should_skip_candidate() after fast_fail_is_skipped().
#   For NMR application (failure >= threshold), the caller reads the "NMR_REQUIRED"
#   marker from stderr and applies the label via gh.
#
# Counter:
#   dispatch_backoff_skipped in ~/.aidevops/logs/pulse-stats.json
#   (via pulse-stats-helper.sh / pulse_stats_increment). Surfaced by `aidevops status`.
#
# Why read JSONL instead of a separate state file:
#   The JSONL is the authoritative, tamper-evident record of per-worker outcomes.
#   A separate state file would diverge on crash, restart, or manual recovery.
#   awk processes the JSONL in O(n) with a 500K file in <10ms — cheap enough
#   for every dispatch cycle candidate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# Source pulse-stats-helper.sh for counter support (optional — fail-open if missing).
# shellcheck source=pulse-stats-helper.sh
if [[ -f "${SCRIPT_DIR}/pulse-stats-helper.sh" ]]; then
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/pulse-stats-helper.sh"
fi

# LOGFILE for sourced-mode usage (caller sets it; standalone mode defines a default).
LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"

# Configuration (overridable via environment).
DISPATCH_BACKOFF_METRICS_FILE="${DISPATCH_BACKOFF_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
DISPATCH_BACKOFF_LOOKBACK_SECS="${DISPATCH_BACKOFF_LOOKBACK_SECS:-604800}"  # 7 days
DISPATCH_BACKOFF_NMR_THRESHOLD="${DISPATCH_BACKOFF_NMR_THRESHOLD:-4}"       # 4+ failures → NMR

# Backoff intervals in seconds (indexed by failure count; index 0 unused).
# Index >= NMR_THRESHOLD uses the last entry (86400 = 24h).
readonly _BACKOFF_SCHEDULE=(0 300 1800 7200 86400)  # [0]=unused [1]=5m [2]=30m [3]=2h [4+]=24h

# Log prefix for all messages from this module.
_DB_LOG_PREFIX="[dispatch-backoff]"

#######################################
# Compute cooldown seconds for a given failure count.
#
# Args:
#   $1 - failure_count (integer >= 1)
# Stdout: cooldown in seconds
#######################################
_db_cooldown_for_count() {
	local count="$1"
	local max_idx=$(( ${#_BACKOFF_SCHEDULE[@]} - 1 ))
	local idx="$count"
	[[ "$idx" -gt "$max_idx" ]] && idx="$max_idx"
	[[ "$idx" -lt 1 ]] && idx=1
	printf '%s\n' "${_BACKOFF_SCHEDULE[$idx]}"
	return 0
}

#######################################
# Count rate_limit exits for an issue in the metrics JSONL within the lookback window.
#
# Uses jq for JSONL parsing — select() filters matching entries in a single
# pass. BSD awk (macOS default) does not support capture groups in match(),
# so awk-based parsing would fail silently. jq is a hard framework dependency.
#
# Returns two values on stdout: "<count> <last_ts>"
#   count   — number of rate_limit entries in the lookback window
#   last_ts — epoch of the most recent rate_limit entry (0 if count=0)
#
# Args:
#   $1 - issue_number (integer)
#   $2 - since_epoch  (only count entries with ts >= this)
# Stdout: "count last_ts"
#######################################
_db_count_rate_limit_events() {
	local issue_number="$1"
	local since_epoch="$2"
	local session_key="issue-${issue_number}"
	local metrics_file="$DISPATCH_BACKOFF_METRICS_FILE"

	if [[ ! -f "$metrics_file" ]]; then
		printf '0 0\n'
		return 0
	fi

	# jq JSONL parser: select matching entries (session_key, result, ts >= since),
	# emit ts values, collect count and max. Single pass over the file.
	# --slurp reads all lines into an array for aggregate operations.
	# Fallback: if jq fails, return "0 0" (fail-open).
	local result
	result=$(jq -r --arg sk "$session_key" --argjson since "$since_epoch" \
		'select(.session_key == $sk and .result == "rate_limit" and (.ts // 0) >= $since) | .ts' \
		"$metrics_file" 2>/dev/null \
		| awk 'BEGIN{count=0;last=0} {count++; if($1+0>last+0)last=$1+0} END{printf "%d %d\n",count,last}' \
		2>/dev/null) || result="0 0"

	[[ -n "$result" ]] || result="0 0"
	printf '%s\n' "$result"
	return 0
}

#######################################
# Check whether dispatch backoff is active for an issue.
#
# Reads headless-runtime-metrics.jsonl for recent rate_limit events,
# applies the graduated cooldown schedule, and returns exit 1 if
# the cooldown window is still active.
#
# Called from _dff_should_skip_candidate() in pulse-dispatch-engine.sh
# immediately after fast_fail_is_skipped().
#
# Exit codes:
#   0 — clear; dispatch may proceed
#   1 — cooldown active; prints BACKOFF_ACTIVE line to stderr
#   2 — error; fail-open (caller should log warning and proceed)
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (informational only — JSONL does not include slug)
#######################################
check_dispatch_backoff() {
	local issue_number="$1"
	local repo_slug="${2:-unknown}"

	# Emergency bypass.
	if [[ "${AIDEVOPS_SKIP_DISPATCH_BACKOFF:-0}" == "1" ]]; then
		echo "${_DB_LOG_PREFIX} AIDEVOPS_SKIP_DISPATCH_BACKOFF=1 — bypassing rate-limit backoff check" >>"$LOGFILE"
		return 0
	fi

	# Validate input.
	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		echo "${_DB_LOG_PREFIX} WARNING: invalid issue_number '${issue_number}' — proceeding (fail-open)" >>"$LOGFILE"
		return 2
	fi

	local now
	now=$(date +%s 2>/dev/null) || now=0
	if [[ "$now" -eq 0 ]]; then
		echo "${_DB_LOG_PREFIX} WARNING: could not get current epoch — proceeding (fail-open)" >>"$LOGFILE"
		return 2
	fi

	local since=$(( now - DISPATCH_BACKOFF_LOOKBACK_SECS ))
	[[ "$since" -lt 0 ]] && since=0

	# Count recent rate_limit events.
	local count_result
	count_result=$(_db_count_rate_limit_events "$issue_number" "$since") || count_result="0 0"

	local count last_ts
	read -r count last_ts <<<"$count_result"
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	[[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0

	if [[ "$count" -eq 0 ]]; then
		# No recent rate_limit events — clear for dispatch.
		return 0
	fi

	# Compute cooldown window.
	local cooldown_secs
	cooldown_secs=$(_db_cooldown_for_count "$count")
	local next_eligible=$(( last_ts + cooldown_secs ))

	if [[ "$now" -lt "$next_eligible" ]]; then
		# Cooldown still active.
		local wait_remaining=$(( next_eligible - now ))
		local next_human
		next_human=$(date -r "$next_eligible" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
			date -d "@${next_eligible}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
			printf 'epoch:%s' "$next_eligible")

		local nmr_flag=""
		if [[ "$count" -ge "$DISPATCH_BACKOFF_NMR_THRESHOLD" ]]; then
			nmr_flag=" NMR_REQUIRED"
		fi

		printf 'BACKOFF_ACTIVE reason=rate_limit_cooldown count=%s cooldown=%ss wait=%ss next=%s%s\n' \
			"$count" "$cooldown_secs" "$wait_remaining" "$next_human" "$nmr_flag" >&2

		echo "${_DB_LOG_PREFIX} BACKOFF_ACTIVE #${issue_number} (${repo_slug}) count=${count} cooldown=${cooldown_secs}s wait=${wait_remaining}s next=${next_human}${nmr_flag}" >>"$LOGFILE"

		# Increment stats counter.
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "dispatch_backoff_skipped" 2>/dev/null || true
		fi

		return 1
	fi

	# Cooldown has elapsed — clear for dispatch.
	echo "${_DB_LOG_PREFIX} backoff elapsed for #${issue_number} (${repo_slug}) count=${count} last_rate_limit=$(date -r "$last_ts" '+%H:%M:%S' 2>/dev/null || printf '%s' "$last_ts") — dispatch may proceed" >>"$LOGFILE"
	return 0
}

#######################################
# Apply needs-maintainer-review to an issue when rate_limit failures
# have exceeded the NMR threshold. Called by the dispatch engine when
# check_dispatch_backoff returns 1 AND the stderr contains "NMR_REQUIRED".
#
# Idempotent: only applies NMR once per issue (uses a marker comment).
# Best-effort: failures are logged but never fatal.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - failure_count
#######################################
_db_apply_nmr_if_needed() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"

	local nmr_marker="<!-- dispatch-backoff:rate_limit_nmr -->"

	# Idempotency check.
	local existing_nmr=""
	existing_nmr=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq "[.[] | select(.body | contains(\"dispatch-backoff:rate_limit_nmr\"))] | length" \
		2>/dev/null) || existing_nmr=""
	if [[ "$existing_nmr" =~ ^[1-9][0-9]*$ ]]; then
		echo "${_DB_LOG_PREFIX} NMR already applied for #${issue_number} (${repo_slug}) — skipping" >>"$LOGFILE"
		return 0
	fi

	# Apply the label.
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "needs-maintainer-review" 2>/dev/null || true

	# Post diagnostic comment.
	local body="${nmr_marker}
## Rate-Limit Backoff Circuit Breaker (t2781)

**Trigger:** ${failure_count} rate_limit failure(s) for this issue within the lookback window (threshold: ${DISPATCH_BACKOFF_NMR_THRESHOLD}).
**Action:** Applied \`needs-maintainer-review\`. Further automated dispatch is suspended for 24h and until the label is removed.

**Why this is different from other NMR trips:** Worker rate_limit failures are NOT a problem with the issue body or model tier — they indicate provider capacity exhaustion specific to this issue's account/provider pairing. Escalating to a higher tier would not help.

**Possible causes:**
- Provider rate limits for the account(s) dispatching this issue are exhausted
- The issue's model/tier routing hits a heavily contended capacity tier
- Multiple concurrent dispatches competing for the same limited capacity

**Recommended actions:**
1. Check \`aidevops status\` for current GraphQL budget and account pool state
2. Rotate or add accounts via \`model-accounts-pool-helper.sh\`
3. Wait for provider rate-limit reset (typically 1h for Anthropic, 24h for OpenAI tier limits)
4. Remove \`needs-maintainer-review\` to re-enable dispatch once capacity recovers

_Per-issue rate_limit backoff circuit breaker (t2781). The \`dispatch-backoff:rate_limit_nmr\` marker is recognised by \`_nmr_application_is_circuit_breaker_trip\` in \`pulse-nmr-approval.sh\` (t2386 split semantics: auto-approval preserves NMR)._"

	if declare -F gh_issue_comment >/dev/null 2>&1; then
		gh_issue_comment "$issue_number" --repo "$repo_slug" --body "$body" 2>/dev/null || true
	else
		gh issue comment "$issue_number" --repo "$repo_slug" --body "$body" 2>/dev/null || true
	fi

	echo "${_DB_LOG_PREFIX} NMR applied for #${issue_number} (${repo_slug}) count=${failure_count}" >>"$LOGFILE"
	return 0
}

#######################################
# Standalone CLI entry point.
#######################################
_main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
		check)
			local issue_number="${1:-}"
			local slug="${2:-unknown}"

			if [[ -z "$issue_number" ]]; then
				printf 'Error: issue_number required\n' >&2
				printf 'Usage: dispatch-backoff-helper.sh check <issue_number> [<slug>]\n' >&2
				return 1
			fi

			local backoff_stderr_output=""
			local backoff_rc=0
			backoff_stderr_output=$(check_dispatch_backoff "$issue_number" "$slug" 2>&1 >/dev/null) || backoff_rc=$?

			case "$backoff_rc" in
				0)
					printf 'CLEAR: no active rate_limit backoff for issue #%s\n' "$issue_number"
					return 0
					;;
				1)
					printf '%s\n' "$backoff_stderr_output"

					# Apply NMR if needed (NMR_REQUIRED in output).
					if printf '%s' "$backoff_stderr_output" | grep -q 'NMR_REQUIRED'; then
						local count_field
						count_field=$(printf '%s' "$backoff_stderr_output" | grep -oE 'count=[0-9]+' | head -1 | cut -d= -f2)
						[[ "$count_field" =~ ^[0-9]+$ ]] || count_field="$DISPATCH_BACKOFF_NMR_THRESHOLD"
						_db_apply_nmr_if_needed "$issue_number" "$slug" "$count_field"
					fi
					return 1
					;;
				*)
					printf 'WARNING: backoff check error (fail-open)\n' >&2
					return 2
					;;
			esac
			;;
		help | --help | -h)
			printf 'dispatch-backoff-helper.sh — Per-issue rate_limit backoff gate (t2781)\n\n'
			printf 'Usage:\n'
			printf '  dispatch-backoff-helper.sh check <issue_num> [<slug>]  # exit 0=clear, 1=backoff active, 2=error\n'
			printf '\n'
			printf 'Environment:\n'
			printf '  DISPATCH_BACKOFF_METRICS_FILE      path to headless-runtime-metrics.jsonl\n'
			printf '  DISPATCH_BACKOFF_LOOKBACK_SECS     lookback window in seconds (default 604800 = 7 days)\n'
			printf '  DISPATCH_BACKOFF_NMR_THRESHOLD     failure count triggering NMR (default 4)\n'
			printf '  AIDEVOPS_SKIP_DISPATCH_BACKOFF=1   emergency bypass\n'
			return 0
			;;
		*)
			printf 'Unknown command: %s\n' "$cmd" >&2
			printf 'Run: dispatch-backoff-helper.sh help\n' >&2
			return 1
			;;
	esac
}

# Only run _main when executed directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_main "$@"
fi
