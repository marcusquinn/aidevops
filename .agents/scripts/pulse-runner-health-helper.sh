#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-runner-health-helper.sh — Per-runner zero-attempt circuit breaker (t2897).
#
# When N consecutive "zero-attempt" worker dispatches happen on this runner,
# the breaker pauses dispatch on this machine and synchronously runs
# `aidevops update`. If the update changed VERSION the t2579 restart hook
# refreshes code on the next cycle. If the update reports no change, the
# runner has a real local problem (broken install, gh auth, MCP failures,
# network) — stay paused and post a single advisory.
#
# A "zero-attempt" outcome means a dispatched worker never produced real
# work — the four signals are listed in the brief and recorded by callers.
# Workers that produce a commit, open a PR, or burn >5K tokens are real
# attempts and reset the counter — even if the work failed, the failure is
# brief/tier/codebase, not version skew.
#
# The breaker is per-runner: peer runners are unaffected. Cross-runner
# coordination already takes over naturally (no DISPATCH_CLAIM from a
# paused runner = peers see the issue as unclaimed).
#
# Subcommands:
#   record-outcome <signal> <issue>    — record a worker outcome (zero or non-zero attempt).
#   is-paused                          — exit 0 if breaker tripped, exit 1 if closed.
#   pause [--reason "<text>"]          — manually trip the breaker.
#   resume [--reason "<text>"]         — manually clear the breaker.
#   status [--json]                    — print human or JSON state summary.
#   help                               — show usage.
#
# State file: ~/.aidevops/cache/runner-health.json (v1 schema in brief).
# Advisory:   ~/.aidevops/advisories/runner-health-degraded.advisory
# Stamp:      ~/.aidevops/cache/runner-health-advisory.stamp (dedup).
#
# Environment overrides:
#   RUNNER_HEALTH_FAILURE_THRESHOLD          (default 10)
#   RUNNER_HEALTH_WINDOW_HOURS               (default 6)
#   RUNNER_HEALTH_BREAKER_RESUME_AFTER_UPDATE (default true)
#   RUNNER_HEALTH_NO_UPDATE_PAUSE_HOURS      (default 24)
#   RUNNER_HEALTH_DISABLED                   (default 0; set 1 to make all subcommands no-op)
#   RUNNER_HEALTH_TEST_NOW                   (test-only; ISO-8601 string used as "now")

set -euo pipefail

# Resolve script directory for sourcing siblings.
RUNNER_HEALTH_HELPER_DIR="${RUNNER_HEALTH_HELPER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Source shared color/print constants when available; otherwise guard.
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091
if [[ -r "${RUNNER_HEALTH_HELPER_DIR}/shared-constants.sh" ]]; then
	source "${RUNNER_HEALTH_HELPER_DIR}/shared-constants.sh" 2>/dev/null || true
fi
# Local fallbacks for color codes and counter helper if shared-constants didn't load.
[[ -z "${RED+x}" ]] && RED=''
[[ -z "${GREEN+x}" ]] && GREEN=''
[[ -z "${YELLOW+x}" ]] && YELLOW=''
[[ -z "${NC+x}" ]] && NC=''

# Tunables.
RUNNER_HEALTH_FAILURE_THRESHOLD="${RUNNER_HEALTH_FAILURE_THRESHOLD:-10}"
RUNNER_HEALTH_WINDOW_HOURS="${RUNNER_HEALTH_WINDOW_HOURS:-6}"
RUNNER_HEALTH_BREAKER_RESUME_AFTER_UPDATE="${RUNNER_HEALTH_BREAKER_RESUME_AFTER_UPDATE:-true}"
RUNNER_HEALTH_NO_UPDATE_PAUSE_HOURS="${RUNNER_HEALTH_NO_UPDATE_PAUSE_HOURS:-24}"
RUNNER_HEALTH_DISABLED="${RUNNER_HEALTH_DISABLED:-0}"

# Paths.
RUNNER_HEALTH_CACHE_DIR="${RUNNER_HEALTH_CACHE_DIR:-${HOME}/.aidevops/cache}"
RUNNER_HEALTH_STATE_FILE="${RUNNER_HEALTH_CACHE_DIR}/runner-health.json"
RUNNER_HEALTH_ADVISORY_DIR="${RUNNER_HEALTH_ADVISORY_DIR:-${HOME}/.aidevops/advisories}"
RUNNER_HEALTH_ADVISORY_FILE="${RUNNER_HEALTH_ADVISORY_DIR}/runner-health-degraded.advisory"
RUNNER_HEALTH_ADVISORY_STAMP="${RUNNER_HEALTH_CACHE_DIR}/runner-health-advisory.stamp"

# Cap on the rolling outcome ledger (per brief).
RUNNER_HEALTH_LEDGER_CAP=20

#######################################
# UTC ISO-8601 timestamp. Honours RUNNER_HEALTH_TEST_NOW for deterministic tests.
#######################################
_rh_now() {
	if [[ -n "${RUNNER_HEALTH_TEST_NOW:-}" ]]; then
		printf '%s\n' "$RUNNER_HEALTH_TEST_NOW"
	else
		date -u '+%Y-%m-%dT%H:%M:%SZ'
	fi
	return 0
}

#######################################
# Convert an ISO-8601 UTC timestamp to epoch seconds. Handles both BSD
# (macOS) and GNU date variants. Falls back to printing 0 on parse failure
# so callers can detect bad data with an explicit zero check.
# Args: $1 = ISO-8601 string
# Stdout: epoch seconds (or 0 on failure)
#######################################
_rh_iso_to_epoch() {
	local iso="${1:-}"
	[[ -z "$iso" ]] && {
		printf '0\n'
		return 0
	}
	local epoch=""
	# BSD date (macOS).
	epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' 2>/dev/null || true)
	# GNU date (Linux).
	[[ -z "$epoch" ]] && epoch=$(date -u -d "$iso" '+%s' 2>/dev/null || true)
	[[ -z "$epoch" ]] && epoch="0"
	printf '%s\n' "$epoch"
	return 0
}

#######################################
# Detect the local runner login. Used as a tag in state files so a shared
# state file (unlikely but possible across tooling) can be partitioned.
#######################################
_rh_self_login() {
	if command -v gh >/dev/null 2>&1; then
		local login
		login=$(gh api user --jq '.login' 2>/dev/null || true)
		if [[ -n "$login" ]]; then
			printf '%s\n' "$login"
			return 0
		fi
	fi
	printf '%s\n' "${USER:-unknown}"
	return 0
}

#######################################
# Ensure cache + advisory directories exist with safe perms.
#######################################
_rh_ensure_dirs() {
	mkdir -p "$RUNNER_HEALTH_CACHE_DIR" "$RUNNER_HEALTH_ADVISORY_DIR" 2>/dev/null || return 1
	return 0
}

#######################################
# Initialise an empty state file. Idempotent — won't overwrite existing.
#######################################
_rh_init_state() {
	[[ -f "$RUNNER_HEALTH_STATE_FILE" ]] && return 0
	_rh_ensure_dirs || return 1
	local self_login
	self_login=$(_rh_self_login)
	local now
	now=$(_rh_now)
	cat >"$RUNNER_HEALTH_STATE_FILE" <<EOF
{
  "version": 1,
  "self_login": "${self_login}",
  "consecutive_zero_attempts": 0,
  "window_started_at": "${now}",
  "last_outcomes": [],
  "circuit_breaker": {
    "state": "closed",
    "tripped_at": null,
    "last_update_attempt_at": null,
    "last_update_outcome": null,
    "reason": null
  }
}
EOF
	return 0
}

#######################################
# Read a top-level field from the state file via jq. Returns empty string
# if the file doesn't exist or jq is missing or the field is null.
# Args: $1 = jq path expression (e.g. ".consecutive_zero_attempts")
#######################################
_rh_get_field() {
	local jq_path="$1"
	[[ -f "$RUNNER_HEALTH_STATE_FILE" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	jq -r "${jq_path} // empty" <"$RUNNER_HEALTH_STATE_FILE" 2>/dev/null || true
	return 0
}

#######################################
# Atomic write: render JSON via jq pipeline, write to tmp, mv into place.
# Args: $1 = jq filter (operates on existing state)
#######################################
_rh_state_apply() {
	local jq_filter="$1"
	_rh_init_state || return 1
	local tmp
	tmp="${RUNNER_HEALTH_STATE_FILE}.tmp.$$"
	if jq "$jq_filter" <"$RUNNER_HEALTH_STATE_FILE" >"$tmp" 2>/dev/null; then
		mv "$tmp" "$RUNNER_HEALTH_STATE_FILE"
		return 0
	fi
	rm -f "$tmp"
	return 1
}

#######################################
# Recognised zero-attempt signals. Anything else is treated as a real
# attempt (resets counter).
#######################################
_rh_is_zero_attempt_signal() {
	local signal="$1"
	case "$signal" in
	no_worker_process | no_branch_created | low_token_usage | watchdog_killed_no_commit)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

#######################################
# Determine if a window is expired vs the recorded window_started_at.
# Returns 0 (expired) if more than RUNNER_HEALTH_WINDOW_HOURS have passed.
#######################################
_rh_window_expired() {
	local started
	started=$(_rh_get_field '.window_started_at')
	[[ -z "$started" ]] && return 0
	local started_epoch now_epoch
	started_epoch=$(_rh_iso_to_epoch "$started")
	now_epoch=$(_rh_iso_to_epoch "$(_rh_now)")
	[[ "$started_epoch" -eq 0 ]] && return 0
	local age=$((now_epoch - started_epoch))
	local window_seconds=$((RUNNER_HEALTH_WINDOW_HOURS * 3600))
	[[ "$age" -gt "$window_seconds" ]] && return 0
	return 1
}

#######################################
# cmd_record_outcome — record a worker outcome. Caller passes the signal
# string and the issue identifier for the audit ledger.
#
# Increments `consecutive_zero_attempts` for zero-attempt signals; resets
# to 0 for any other signal (real-attempt outcomes). When the counter
# reaches RUNNER_HEALTH_FAILURE_THRESHOLD inside the rolling window, the
# breaker trips and `aidevops update` runs synchronously.
#######################################
cmd_record_outcome() {
	local signal="${1:-}"
	local issue="${2:-unknown}"
	if [[ -z "$signal" ]]; then
		echo "Usage: $0 record-outcome <signal> <issue-id>" >&2
		return 1
	fi
	[[ "$RUNNER_HEALTH_DISABLED" == "1" ]] && return 0
	_rh_init_state || return 1
	command -v jq >/dev/null 2>&1 || return 0

	local now
	now=$(_rh_now)
	local is_zero=0
	if _rh_is_zero_attempt_signal "$signal"; then is_zero=1; fi

	# Window expiry: if the rolling window has elapsed without tripping,
	# zero out the counter and re-anchor the window. Done BEFORE applying
	# the new outcome so a stale window doesn't carry an old counter.
	if _rh_window_expired; then
		_rh_state_apply ".consecutive_zero_attempts = 0 | .window_started_at = \"${now}\"" || true
	fi

	# Append outcome to ledger and update counter.
	local new_counter
	if [[ "$is_zero" -eq 1 ]]; then
		# Counter increments; the window may need to be re-anchored if it
		# was idle through expiry above (already done) — otherwise keep it.
		_rh_state_apply ".consecutive_zero_attempts += 1" || true
	else
		_rh_state_apply ".consecutive_zero_attempts = 0 | .window_started_at = \"${now}\"" || true
	fi

	# Append outcome with rolling cap. jq idiom: keep last N entries.
	local outcome_entry
	outcome_entry=$(jq -n \
		--arg issue "$issue" \
		--arg signal "$signal" \
		--arg ts "$now" \
		--argjson zero "$is_zero" \
		'{issue:$issue, signal:$signal, ts:$ts, zero_attempt:($zero==1)}')
	_rh_state_apply ".last_outcomes += [${outcome_entry}] | .last_outcomes = (.last_outcomes | .[-${RUNNER_HEALTH_LEDGER_CAP}:])" || true

	# Trip evaluation. Only zero-attempt outcomes can trip the breaker
	# (real-attempt outcomes already reset the counter above).
	new_counter=$(_rh_get_field '.consecutive_zero_attempts')
	[[ -z "$new_counter" ]] && new_counter=0
	local current_state
	current_state=$(_rh_get_field '.circuit_breaker.state')
	[[ -z "$current_state" ]] && current_state="closed"

	if [[ "$is_zero" -eq 1 ]] \
		&& [[ "$current_state" == "closed" ]] \
		&& [[ "$new_counter" -ge "$RUNNER_HEALTH_FAILURE_THRESHOLD" ]]; then
		_rh_trip_breaker "$issue" "consecutive_zero_attempts=${new_counter}"
	fi
	return 0
}

#######################################
# Trip the breaker: write `tripped` state, post an advisory, and
# synchronously run `aidevops update`. If the update changed VERSION
# (exit 0 from cmd_check) the t2579 restart hook fires and the next
# cycle will pick up new code; we leave the state as `tripped` and let
# the resume path (next cmd_record_outcome non-zero) reopen it.
# Args: $1 = triggering issue (audit only)
#       $2 = reason string
#######################################
_rh_trip_breaker() {
	local triggering_issue="$1"
	local reason="$2"
	local now
	now=$(_rh_now)

	# Mark tripped first so concurrent paths see the breaker open.
	_rh_state_apply \
		".circuit_breaker.state = \"tripped\" \
		| .circuit_breaker.tripped_at = \"${now}\" \
		| .circuit_breaker.reason = \"${reason}\"" || true

	# Write/refresh the advisory (deduped) so the operator sees this on
	# the next session greeting.
	_rh_post_advisory "tripped" "$reason" "$triggering_issue"

	# Synchronous update. Run via the deployed helper to avoid spawning
	# a separate shell when the canonical install is missing.
	local update_helper="${HOME}/.aidevops/agents/scripts/auto-update-helper.sh"
	local update_outcome="error"
	if [[ -x "$update_helper" ]]; then
		# Run check synchronously. Output to log only — never the user's
		# session — to avoid noise from a per-issue trigger.
		local update_log="${HOME}/.aidevops/logs/runner-health-update.log"
		mkdir -p "$(dirname "$update_log")" 2>/dev/null || true
		local update_rc=0
		"$update_helper" check >>"$update_log" 2>&1 || update_rc=$?
		if [[ "$update_rc" -eq 0 ]]; then
			update_outcome="ran"
		else
			update_outcome="failed"
		fi
	else
		update_outcome="helper_missing"
	fi

	_rh_state_apply \
		".circuit_breaker.last_update_attempt_at = \"$(_rh_now)\" \
		| .circuit_breaker.last_update_outcome = \"${update_outcome}\"" || true
	return 0
}

#######################################
# Write the advisory file with dedup. Re-emit only when:
#   (a) breaker first trips (no stamp file yet);
#   (b) update outcome differs from prior;
#   (c) more than 24h since last advisory.
# Args: $1 = state ("tripped" | "resumed")
#       $2 = reason
#       $3 = triggering issue (audit)
#######################################
_rh_post_advisory() {
	local state="$1"
	local reason="$2"
	local triggering="$3"
	_rh_ensure_dirs || return 1

	local now
	now=$(_rh_now)
	local now_epoch
	now_epoch=$(_rh_iso_to_epoch "$now")
	local should_emit=1

	if [[ -f "$RUNNER_HEALTH_ADVISORY_STAMP" ]]; then
		# Stamp file holds prior state + last_emit_ts on two lines.
		local prior_state prior_ts prior_epoch
		prior_state=$(sed -n 1p "$RUNNER_HEALTH_ADVISORY_STAMP" 2>/dev/null || echo "")
		prior_ts=$(sed -n 2p "$RUNNER_HEALTH_ADVISORY_STAMP" 2>/dev/null || echo "")
		prior_epoch=$(_rh_iso_to_epoch "$prior_ts")
		# If state unchanged AND less than 24h elapsed, skip.
		if [[ "$prior_state" == "$state" ]]; then
			if [[ "$prior_epoch" -gt 0 ]]; then
				local age=$((now_epoch - prior_epoch))
				if [[ "$age" -lt $((24 * 3600)) ]]; then
					should_emit=0
				fi
			fi
		fi
	fi

	if [[ "$should_emit" -eq 1 ]]; then
		cat >"$RUNNER_HEALTH_ADVISORY_FILE" <<EOF
Runner-health circuit breaker is currently ${state}.

Reason:           ${reason}
Triggering issue: ${triggering}
Updated:          ${now}

Diagnose: pulse-runner-health-helper.sh status
Resume:   pulse-runner-health-helper.sh resume --reason "<text>"
Background: reference/cross-runner-coordination.md §4.4
EOF
		printf '%s\n%s\n' "$state" "$now" >"$RUNNER_HEALTH_ADVISORY_STAMP"
	fi
	return 0
}

#######################################
# cmd_is_paused — exit 0 if breaker is tripped, exit 1 otherwise.
# Pulse calls this before the dispatch evaluation step.
#######################################
cmd_is_paused() {
	[[ "$RUNNER_HEALTH_DISABLED" == "1" ]] && return 1
	[[ -f "$RUNNER_HEALTH_STATE_FILE" ]] || return 1
	local state
	state=$(_rh_get_field '.circuit_breaker.state')
	[[ "$state" == "tripped" ]] && return 0
	return 1
}

#######################################
# cmd_pause — manually trip the breaker. For operator use; not called
# from the auto-trip path (that uses _rh_trip_breaker directly).
#######################################
cmd_pause() {
	local reason="manual pause"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--reason)
			reason="${2:-manual pause}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	_rh_init_state || return 1
	local now
	now=$(_rh_now)
	_rh_state_apply \
		".circuit_breaker.state = \"tripped\" \
		| .circuit_breaker.tripped_at = \"${now}\" \
		| .circuit_breaker.reason = \"${reason}\"" || return 1
	_rh_post_advisory "tripped" "$reason" "manual"
	printf '%bPaused%b: runner-health breaker tripped (%s)\n' \
		"$YELLOW" "$NC" "$reason" >&2
	return 0
}

#######################################
# cmd_resume — manually clear the breaker. Logs reason in the audit ledger.
#######################################
cmd_resume() {
	local reason="manual resume"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--reason)
			reason="${2:-manual resume}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	_rh_init_state || return 1
	local now
	now=$(_rh_now)
	_rh_state_apply \
		".circuit_breaker.state = \"closed\" \
		| .circuit_breaker.tripped_at = null \
		| .circuit_breaker.reason = \"${reason}\" \
		| .consecutive_zero_attempts = 0 \
		| .window_started_at = \"${now}\"" || return 1
	# Clear the advisory file and stamp so the next trip can post fresh.
	rm -f "$RUNNER_HEALTH_ADVISORY_FILE" "$RUNNER_HEALTH_ADVISORY_STAMP" 2>/dev/null || true
	printf '%bResumed%b: runner-health breaker cleared (%s)\n' \
		"$GREEN" "$NC" "$reason" >&2
	return 0
}

#######################################
# cmd_status — print state. Default human-readable; --json emits raw JSON.
#######################################
cmd_status() {
	local emit_json=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			emit_json=1
			shift
			;;
		*)
			shift
			;;
		esac
	done

	if [[ ! -f "$RUNNER_HEALTH_STATE_FILE" ]]; then
		if [[ "$emit_json" -eq 1 ]]; then
			printf '{"state":"uninitialized"}\n'
		else
			printf 'state: uninitialized (no record-outcome calls yet)\n'
		fi
		return 0
	fi

	if [[ "$emit_json" -eq 1 ]]; then
		cat "$RUNNER_HEALTH_STATE_FILE"
		return 0
	fi

	# Human format.
	local state counter window_started tripped_at update_at update_outcome reason
	state=$(_rh_get_field '.circuit_breaker.state')
	counter=$(_rh_get_field '.consecutive_zero_attempts')
	window_started=$(_rh_get_field '.window_started_at')
	tripped_at=$(_rh_get_field '.circuit_breaker.tripped_at')
	update_at=$(_rh_get_field '.circuit_breaker.last_update_attempt_at')
	update_outcome=$(_rh_get_field '.circuit_breaker.last_update_outcome')
	reason=$(_rh_get_field '.circuit_breaker.reason')

	printf 'state:               %s\n' "${state:-unknown}"
	printf 'consecutive zero:    %s / %s threshold\n' "${counter:-0}" "$RUNNER_HEALTH_FAILURE_THRESHOLD"
	printf 'window started:      %s\n' "${window_started:-n/a}"
	if [[ "$state" == "tripped" ]]; then
		printf 'tripped at:          %s\n' "${tripped_at:-n/a}"
		printf 'last update run:     %s (%s)\n' "${update_at:-never}" "${update_outcome:-n/a}"
		printf 'reason:              %s\n' "${reason:-n/a}"
	fi
	return 0
}

#######################################
# Help text.
#######################################
cmd_help() {
	cat <<'EOF'
pulse-runner-health-helper.sh — Per-runner zero-attempt circuit breaker.

USAGE:
  pulse-runner-health-helper.sh record-outcome <signal> <issue-id>
  pulse-runner-health-helper.sh is-paused
  pulse-runner-health-helper.sh pause [--reason "<text>"]
  pulse-runner-health-helper.sh resume [--reason "<text>"]
  pulse-runner-health-helper.sh status [--json]
  pulse-runner-health-helper.sh help

ZERO-ATTEMPT SIGNALS (reset counter when not one of these):
  no_worker_process          — worker process never spawned.
  no_branch_created          — worker dispatched but no git branch in target repo.
  low_token_usage            — worker exited with <ZERO_ATTEMPT_TOKEN_FLOOR tokens.
  watchdog_killed_no_commit  — watchdog killed worker before any commit.

ENVIRONMENT:
  RUNNER_HEALTH_FAILURE_THRESHOLD          (default 10)
  RUNNER_HEALTH_WINDOW_HOURS               (default 6)
  RUNNER_HEALTH_BREAKER_RESUME_AFTER_UPDATE (default true)
  RUNNER_HEALTH_NO_UPDATE_PAUSE_HOURS      (default 24)
  RUNNER_HEALTH_DISABLED                   (default 0; set 1 to no-op all subcommands)

EXIT CODES:
  is-paused:  0 = breaker tripped (do NOT dispatch)
              1 = breaker closed (safe to dispatch)
EOF
	return 0
}

#######################################
# Dispatch.
#######################################
main() {
	local cmd="${1:-help}"
	shift || true
	case "$cmd" in
	record-outcome) cmd_record_outcome "$@" ;;
	is-paused) cmd_is_paused ;;
	pause) cmd_pause "$@" ;;
	resume) cmd_resume "$@" ;;
	status) cmd_status "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		printf 'Unknown subcommand: %s\n' "$cmd" >&2
		cmd_help
		return 1
		;;
	esac
	return $?
}

# Only run if invoked directly (sourcing exposes functions for tests).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
