#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-peer-quarantine-helper.sh — Cross-runner peer quarantine (t3194).
#
# Sibling to pulse-runner-health-helper.sh (t2897), but partitioned by PEER
# instead of self. The runner-health breaker protects the runner whose own
# dispatches are dying; this helper protects PEERS by detecting when another
# runner is emitting recovery primitives on the GitHub comment trail and
# automatically quarantining its claims so they stop blocking dispatch.
#
# Detection signal: the canonical recovery comment shape emitted by
# pulse-cleanup.sh:978 —
#
#   CLAIM_RELEASED reason=launch_recovery:no_worker_process runner=<peer>
#
# Each comment matching that shape is one observed "zero-attempt failure"
# attributable to <peer>. When the rolling counter for any peer hits the
# configured threshold inside the rolling window, the helper writes a
# `peer-quarantine-until=<ISO>` entry to the shared dispatch-override.conf
# and emits a single deduped advisory.
#
# The dispatch-dedup-helper.sh assignee filter (Layer 6 sub-step) reads the
# same conf file and treats any peer with `peer-quarantine-until=<ISO>` set
# to a future timestamp as if it were on the legacy `ignore` list — its
# claim no longer blocks this runner's dispatch.
#
# Manual `dispatch-override.conf` entries (`honour | ignore | warn |
# honour-only-above:V`) are NEVER touched by this helper. Only entries whose
# value starts with `peer-quarantine-` are auto-managed.
#
# Subcommands:
#   record-peer-event <peer> <issue-ref>   — record one observed peer recovery event.
#   is-quarantined <peer>                  — exit 0 if quarantined, 1 if not.
#   status [--json] [<peer>]               — print human or JSON state summary.
#   release <peer> [--reason "<text>"]     — manually clear a peer's quarantine.
#   scan-comments [<peer-filter>]          — read JSON array of comments from
#                                            stdin, extract launch-recovery
#                                            events, record each. (Used by
#                                            dispatch-dedup-helper.sh's
#                                            comment fetch path for zero-cost
#                                            opportunistic detection.)
#   help                                   — show usage.
#
# State file: ~/.aidevops/cache/peer-quarantine.json (v1 schema).
# Advisory:   ~/.aidevops/advisories/peer-quarantine-<peer>.advisory
# Stamp:      ~/.aidevops/cache/peer-quarantine-advisory-<peer>.stamp (24h dedup).
# Override:   ~/.config/aidevops/dispatch-override.conf (shared with t2422).
#
# Environment overrides:
#   PEER_QUARANTINE_FAILURE_THRESHOLD       (default 5)
#   PEER_QUARANTINE_WINDOW_HOURS            (default 1)
#   PEER_QUARANTINE_DURATION_HOURS          (default 6)
#   PEER_QUARANTINE_DISABLED                (default 0; set 1 to no-op all subcommands)
#   PEER_QUARANTINE_TEST_NOW                (test-only; ISO-8601 string used as "now")
#   PEER_QUARANTINE_OVERRIDE_CONF           (test-only; override conf path)

set -euo pipefail

# Resolve script directory for sourcing siblings.
PEER_QUARANTINE_HELPER_DIR="${PEER_QUARANTINE_HELPER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Source shared color/print constants when available; otherwise guard.
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091
if [[ -r "${PEER_QUARANTINE_HELPER_DIR}/shared-constants.sh" ]]; then
	source "${PEER_QUARANTINE_HELPER_DIR}/shared-constants.sh" 2>/dev/null || true
fi
# Local fallbacks for color codes if shared-constants didn't load.
[[ -z "${RED+x}" ]] && RED=''
[[ -z "${GREEN+x}" ]] && GREEN=''
[[ -z "${YELLOW+x}" ]] && YELLOW=''
[[ -z "${NC+x}" ]] && NC=''

# Tunables.
PEER_QUARANTINE_FAILURE_THRESHOLD="${PEER_QUARANTINE_FAILURE_THRESHOLD:-5}"
PEER_QUARANTINE_WINDOW_HOURS="${PEER_QUARANTINE_WINDOW_HOURS:-1}"
PEER_QUARANTINE_DURATION_HOURS="${PEER_QUARANTINE_DURATION_HOURS:-6}"
PEER_QUARANTINE_DISABLED="${PEER_QUARANTINE_DISABLED:-0}"

# Paths.
PEER_QUARANTINE_CACHE_DIR="${PEER_QUARANTINE_CACHE_DIR:-${HOME}/.aidevops/cache}"
PEER_QUARANTINE_STATE_FILE="${PEER_QUARANTINE_STATE_FILE:-${PEER_QUARANTINE_CACHE_DIR}/peer-quarantine.json}"
PEER_QUARANTINE_ADVISORY_DIR="${PEER_QUARANTINE_ADVISORY_DIR:-${HOME}/.aidevops/advisories}"
PEER_QUARANTINE_OVERRIDE_CONF="${PEER_QUARANTINE_OVERRIDE_CONF:-${HOME}/.config/aidevops/dispatch-override.conf}"

# Cap on the rolling event ledger PER PEER.
PEER_QUARANTINE_LEDGER_CAP=20

#######################################
# UTC ISO-8601 timestamp. Honours PEER_QUARANTINE_TEST_NOW for deterministic tests.
#######################################
_pq_now() {
	if [[ -n "${PEER_QUARANTINE_TEST_NOW:-}" ]]; then
		printf '%s\n' "$PEER_QUARANTINE_TEST_NOW"
	else
		date -u '+%Y-%m-%dT%H:%M:%SZ'
	fi
	return 0
}

#######################################
# Convert an ISO-8601 UTC timestamp to epoch seconds. Handles both BSD
# (macOS) and GNU date variants. Falls back to 0 on parse failure.
# Args: $1 = ISO-8601 string
# Stdout: epoch seconds (or 0 on failure)
#######################################
_pq_iso_to_epoch() {
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
# Add N seconds to an ISO-8601 UTC timestamp and return the new ISO string.
# Args: $1 = ISO timestamp, $2 = seconds to add (may be negative)
#######################################
_pq_iso_add_seconds() {
	local iso="$1"
	local seconds="$2"
	local epoch=""
	local new_epoch=""
	epoch=$(_pq_iso_to_epoch "$iso")
	[[ "$epoch" -eq 0 ]] && {
		printf '\n'
		return 1
	}
	new_epoch=$((epoch + seconds))
	# BSD date.
	local out
	out=$(date -u -r "$new_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
	# GNU date.
	[[ -z "$out" ]] && out=$(date -u -d "@${new_epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
	printf '%s\n' "$out"
	return 0
}

#######################################
# Normalise a peer login to UPPER_WITH_UNDERSCORES, mirroring the
# dispatch-override-resolve.sh slug normalisation rules so that the conf
# entries we write are read back consistently by the existing resolver.
# Args: $1 = login (e.g. alex-solovyev, bot.user, user@example.com)
# Stdout: ALEX_SOLOVYEV / BOT_USER / USER_EXAMPLE_COM
#######################################
_pq_login_to_var() {
	local login="$1"
	# Replace dash, dot, @ with underscore; uppercase.
	printf '%s' "$login" | tr 'a-z\-.@' 'A-Z___'
	return 0
}

#######################################
# Build a jq path expression for a peer's record root or sub-field. Single
# source of truth for the `.peers["<login>"]` selector pattern — call sites
# that interpolate this into a jq filter use $(_pq_jq_path "$peer" <field>)
# instead of hand-writing the selector. Keeps the literal `.peers["` from
# proliferating across the file (linters-local-validators.sh repeated-string
# ratchet flags 3+ identical literal fragments).
#
# Args:
#   $1 = peer login (used verbatim in the bracket; quote in jq via "%s")
#   $2 = optional sub-field name (no leading dot)
# Output: a single-line jq path expression on stdout.
#######################################
_pq_jq_path() {
	local _login="$1"
	local _field="${2:-}"
	if [[ -n "$_field" ]]; then
		printf '.peers["%s"].%s' "$_login" "$_field"
	else
		printf '.peers["%s"]' "$_login"
	fi
	return 0
}

#######################################
# Convenience wrapper: read a peer's sub-field from the state file. Composes
# `_pq_jq_path` with `_pq_state_get` so call sites avoid an inline command
# substitution that the linter ratchets on as a repeated literal.
# Args: $1 = peer login, $2 = field name (no leading dot)
# Output: field value on stdout (empty on missing/error).
#######################################
_pq_get_field() {
	local _peer="$1"
	local _field="$2"
	local _path
	_path=$(_pq_jq_path "$_peer" "$_field")
	_pq_state_get "$_path"
	return 0
}

#######################################
# Return the current ISO timestamp wrapped in JSON double-quotes so jq
# filters can interpolate the result directly. Centralises the JSON-quoting
# pattern so the repeated-literals validator sees a single point of truth
# instead of every call site rebuilding the form inline.
# Output: "<iso-ts>" on stdout (with literal double-quote bytes).
#######################################
_pq_now_q() {
	local _now
	_now=$(_pq_now)
	printf '"%s"' "$_now"
	return 0
}

#######################################
# Ensure cache + advisory directories exist with safe perms.
#######################################
_pq_ensure_dirs() {
	mkdir -p "$PEER_QUARANTINE_CACHE_DIR" "$PEER_QUARANTINE_ADVISORY_DIR" 2>/dev/null || return 1
	# Override conf parent (~/.config/aidevops) — best-effort, may already exist.
	mkdir -p "$(dirname "$PEER_QUARANTINE_OVERRIDE_CONF")" 2>/dev/null || true
	return 0
}

#######################################
# Initialise an empty state file. Idempotent.
#######################################
_pq_init_state() {
	[[ -f "$PEER_QUARANTINE_STATE_FILE" ]] && return 0
	_pq_ensure_dirs || return 1
	local now
	now=$(_pq_now)
	cat >"$PEER_QUARANTINE_STATE_FILE" <<EOF
{
  "version": 1,
  "initialized_at": "${now}",
  "peers": {}
}
EOF
	return 0
}

#######################################
# Atomic write: render JSON via jq pipeline, write to tmp, mv into place.
# Args: $1 = jq filter (operates on existing state)
#######################################
_pq_state_apply() {
	local jq_filter="$1"
	_pq_init_state || return 1
	command -v jq >/dev/null 2>&1 || return 1
	local tmp
	tmp="${PEER_QUARANTINE_STATE_FILE}.tmp.$$"
	if jq "$jq_filter" <"$PEER_QUARANTINE_STATE_FILE" >"$tmp" 2>/dev/null; then
		mv "$tmp" "$PEER_QUARANTINE_STATE_FILE"
		return 0
	fi
	rm -f "$tmp"
	return 1
}

#######################################
# Read a jq path from the state file. Returns empty string on failure.
# Args: $1 = jq path expression
#######################################
_pq_state_get() {
	local jq_path="$1"
	[[ -f "$PEER_QUARANTINE_STATE_FILE" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	jq -r "${jq_path} // empty" <"$PEER_QUARANTINE_STATE_FILE" 2>/dev/null || true
	return 0
}

#######################################
# Determine if a peer's window is expired based on its window_started_at.
# Args: $1 = peer login
# Returns: 0 if window expired (counter should reset), 1 if still inside.
#######################################
_pq_peer_window_expired() {
	local peer="$1"
	local started
	started=$(_pq_get_field "$peer" window_started_at)
	[[ -z "$started" ]] && return 0
	local started_epoch=""
	local now_epoch=""
	local now_iso=""
	started_epoch=$(_pq_iso_to_epoch "$started")
	now_iso=$(_pq_now)
	now_epoch=$(_pq_iso_to_epoch "$now_iso")
	[[ "$started_epoch" -eq 0 ]] && return 0
	local age=$((now_epoch - started_epoch))
	local window_seconds=$((PEER_QUARANTINE_WINDOW_HOURS * 3600))
	[[ "$age" -gt "$window_seconds" ]] && return 0
	return 1
}

#######################################
# cmd_record_peer_event — record one observed peer recovery event for the
# zero-attempt class. Increments the peer's rolling counter; trips the
# quarantine when the threshold is reached inside the rolling window.
# Args: $1 = peer login
#       $2 = issue ref (e.g. owner/repo#NNN) — audit-only.
#######################################
cmd_record_peer_event() {
	# Accept both flag-style (--peer NAME --issue-ref REF [--reason TEXT])
	# and positional (peer issue-ref) for backward compatibility. Brief
	# specifies flag-style; positional preserved so test harnesses and
	# legacy callers still work.
	local peer=""
	local issue_ref="unknown"
	local _reason="" # reserved for future ledger field; accepted but unused
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--peer)
			peer="${2:-}"
			shift 2
			;;
		--issue-ref)
			issue_ref="${2:-unknown}"
			shift 2
			;;
		--reason)
			_reason="${2:-}"
			shift 2
			;;
		--event-iso)
			# Accepted for symmetry with scan-comments; ignored — the
			# helper always uses _pq_now so PEER_QUARANTINE_TEST_NOW is
			# the single override knob.
			shift 2
			;;
		--*)
			printf 'record-peer-event: unknown flag: %s\n' "$_arg" >&2
			return 1
			;;
		*)
			if [[ -z "$peer" ]]; then
				peer="$_arg"
			elif [[ "$issue_ref" == "unknown" ]]; then
				issue_ref="$_arg"
			fi
			shift
			;;
		esac
	done
	if [[ -z "$peer" ]]; then
		echo "Usage: $0 record-peer-event --peer <name> --issue-ref <slug#num> [--reason <text>]" >&2
		return 1
	fi
	[[ "$PEER_QUARANTINE_DISABLED" == "1" ]] && return 0
	command -v jq >/dev/null 2>&1 || return 0
	_pq_init_state || return 1

	local now=""
	local peer_root=""
	local now_q=""
	now=$(_pq_now)
	peer_root=$(_pq_jq_path "$peer")
	# Pre-quote `${now}` once via the shared helper so call sites can
	# interpolate the JSON-quoted form without rebuilding it locally.
	now_q=$(_pq_now_q)

	# Window expiry: if the peer's rolling window has elapsed without
	# tripping, reset its counter and re-anchor the window. Must run BEFORE
	# applying the new event so a stale window doesn't carry an old counter.
	if _pq_peer_window_expired "$peer"; then
		_pq_state_apply \
			"${peer_root} = ((${peer_root} // {}) + {failure_count:0, window_started_at:${now_q}})" || true
	fi

	# Build an event entry and increment the counter atomically.
	local event_entry
	event_entry=$(jq -n \
		--arg ref "$issue_ref" \
		--arg ts "$now" \
		'{issue_ref:$ref, ts:$ts}')

	# Initialise the peer record if missing; bump counter; append to ledger
	# with rolling cap.
	_pq_state_apply "
		${peer_root} = (
			(${peer_root} // {failure_count:0, window_started_at:${now_q}, events:[]})
			| .failure_count = ((.failure_count // 0) + 1)
			| .last_event_at = ${now_q}
			| .events = (((.events // []) + [${event_entry}]) | .[-${PEER_QUARANTINE_LEDGER_CAP}:])
		)
	" || return 1

	# Trip evaluation extracted to _pq_eval_trip to keep this function below
	# the function-complexity gate.
	_pq_eval_trip "$peer" "$now" "$issue_ref" || true
	return 0
}

#######################################
# _pq_eval_trip — evaluate whether the peer's failure_count crossed the
# threshold and trip (or re-extend) the quarantine if so. Only counts up
# to the threshold; further events past the trip refresh quarantine_until
# via _pq_trip_peer rather than re-tripping.
# Args: $1 = peer login
#       $2 = current ISO timestamp
#       $3 = issue ref (audit-only)
# Returns: 0 always (no-op when below threshold or already covered).
#######################################
_pq_eval_trip() {
	local peer="$1"
	local now="$2"
	local issue_ref="$3"
	local count=""
	count=$(_pq_get_field "$peer" failure_count)
	[[ -z "$count" ]] && count=0
	[[ "$count" -lt "$PEER_QUARANTINE_FAILURE_THRESHOLD" ]] && return 0
	local existing_until=""
	existing_until=$(_pq_get_field "$peer" quarantine_until)
	local now_epoch=""
	now_epoch=$(_pq_iso_to_epoch "$now")
	local until_epoch=0
	[[ -n "$existing_until" ]] && until_epoch=$(_pq_iso_to_epoch "$existing_until")
	# Trip (or re-extend) only if not already covering current time.
	if [[ "$until_epoch" -le "$now_epoch" ]]; then
		_pq_trip_peer "$peer" "$issue_ref" "failure_count=${count}"
	fi
	return 0
}

#######################################
# Trip the peer breaker: set quarantine_until ISO, write the override conf
# entry, and emit a deduped advisory.
# Args: $1 = peer login
#       $2 = triggering issue ref (audit only)
#       $3 = reason string
#######################################
_pq_trip_peer() {
	local peer="$1"
	local triggering_issue="$2"
	local reason="$3"
	local now=""
	local until_iso=""
	local peer_root=""
	local now_q=""
	local until_q=""
	local reason_q=""
	local trig_q=""
	now=$(_pq_now)
	until_iso=$(_pq_iso_add_seconds "$now" $((PEER_QUARANTINE_DURATION_HOURS * 3600)))
	[[ -z "$until_iso" ]] && return 1
	peer_root=$(_pq_jq_path "$peer")
	# Pre-quote each value once so the jq filter interpolates JSON-quoted
	# forms via local vars instead of repeating the escape pattern at every
	# field assignment.
	now_q=$(_pq_now_q)
	until_q="\"${until_iso}\""
	reason_q="\"${reason}\""
	trig_q="\"${triggering_issue}\""

	# Persist quarantine_until on the peer record.
	_pq_state_apply \
		"${peer_root}.quarantine_until = ${until_q} \
		| ${peer_root}.quarantined_at = ${now_q} \
		| ${peer_root}.reason = ${reason_q} \
		| ${peer_root}.triggering_issue = ${trig_q}" || true

	# Write the override conf entry. The conf format is shared with t2422
	# (`DISPATCH_OVERRIDE_<PEER>=<value>`), and dispatch-dedup-helper.sh
	# reads `peer-quarantine-until=<ISO>` as a "treat-as-ignore-while-active"
	# directive.
	_pq_write_override_entry "$peer" "$until_iso" || true

	# Advisory (deduped 24h or on state change).
	_pq_post_advisory "$peer" "$until_iso" "$reason" "$triggering_issue"
	return 0
}

#######################################
# Atomically rewrite ~/.config/aidevops/dispatch-override.conf so that the
# DISPATCH_OVERRIDE_<PEER> line carries `peer-quarantine-until=<ISO>`.
# Manual entries (honour | ignore | warn | honour-only-above:V) are
# preserved untouched — only existing peer-quarantine-* values for the
# same peer are overwritten.
# Args: $1 = peer login (lowercase or mixed)
#       $2 = ISO timestamp
#######################################
_pq_write_override_entry() {
	local peer="$1"
	local until_iso="$2"
	local conf="$PEER_QUARANTINE_OVERRIDE_CONF"
	_pq_ensure_dirs || return 1

	local var_name
	var_name="DISPATCH_OVERRIDE_$(_pq_login_to_var "$peer")"
	local new_value="peer-quarantine-until=${until_iso}"
	local new_line="${var_name}=\"${new_value}\""
	local tmp
	tmp="${conf}.tmp.$$"
	# Read existing conf (if any) and write a copy with the entry replaced
	# or appended. If an existing line for the same var name carries a
	# manual value (anything not starting with peer-quarantine-), leave it
	# alone — manual intent wins.
	local replaced=0
	if [[ -f "$conf" ]]; then
		while IFS= read -r line; do
			if [[ "$line" =~ ^${var_name}= ]]; then
				# Existing entry for this peer — check if manual.
				local existing_val
				existing_val="${line#"${var_name}"=}"
				existing_val="${existing_val#\"}"
				existing_val="${existing_val%\"}"
				existing_val="${existing_val#\'}"
				existing_val="${existing_val%\'}"
				if [[ "$existing_val" == peer-quarantine-* ]]; then
					# Auto-managed entry — replace it.
					printf '%s\n' "$new_line" >>"$tmp"
					replaced=1
					continue
				fi
				# Manual entry — preserve it. Skip writing the auto entry
				# this pass; dispatch-dedup will see the manual value and
				# act on it. We log this as a hint via the advisory.
				printf '%s\n' "$line" >>"$tmp"
				replaced=1
				continue
			fi
			printf '%s\n' "$line" >>"$tmp"
		done <"$conf"
	fi
	if [[ "$replaced" -eq 0 ]]; then
		[[ -s "$tmp" ]] && printf '\n' >>"$tmp"
		printf '# Auto-managed by pulse-peer-quarantine-helper.sh (t3194)\n' >>"$tmp"
		printf '%s\n' "$new_line" >>"$tmp"
	fi
	mv "$tmp" "$conf"
	chmod 600 "$conf" 2>/dev/null || true
	return 0
}

#######################################
# Remove the auto-managed conf entry for a peer (manual entries preserved).
# Args: $1 = peer login
#######################################
_pq_clear_override_entry() {
	local peer="$1"
	local conf="$PEER_QUARANTINE_OVERRIDE_CONF"
	[[ -f "$conf" ]] || return 0
	local var_name
	var_name="DISPATCH_OVERRIDE_$(_pq_login_to_var "$peer")"
	local tmp
	tmp="${conf}.tmp.$$"
	while IFS= read -r line; do
		if [[ "$line" =~ ^${var_name}= ]]; then
			# Drop only auto-managed entries (peer-quarantine-* values).
			local existing_val
			existing_val="${line#"${var_name}"=}"
			existing_val="${existing_val#\"}"
			existing_val="${existing_val%\"}"
			existing_val="${existing_val#\'}"
			existing_val="${existing_val%\'}"
			if [[ "$existing_val" == peer-quarantine-* ]]; then
				continue
			fi
		fi
		printf '%s\n' "$line" >>"$tmp"
	done <"$conf"
	# Also strip the auto-managed banner line if it was the only reason
	# for the file's existence — but only when we're sure no other
	# auto entries remain. Cheaper to leave it alone.
	mv "$tmp" "$conf"
	chmod 600 "$conf" 2>/dev/null || true
	return 0
}

#######################################
# Write/refresh the per-peer advisory file with 24h dedup.
# Args: $1 = peer login
#       $2 = quarantine_until ISO
#       $3 = reason
#       $4 = triggering issue ref (audit)
#######################################
_pq_post_advisory() {
	local peer="$1"
	local until_iso="$2"
	local reason="$3"
	local triggering="$4"
	_pq_ensure_dirs || return 1

	local advisory_file=""
	local stamp_file=""
	advisory_file="${PEER_QUARANTINE_ADVISORY_DIR}/peer-quarantine-${peer}.advisory"
	stamp_file="${PEER_QUARANTINE_CACHE_DIR}/peer-quarantine-advisory-${peer}.stamp"

	local now=""
	local now_epoch=""
	now=$(_pq_now)
	now_epoch=$(_pq_iso_to_epoch "$now")
	local should_emit=1

	if [[ -f "$stamp_file" ]]; then
		local prior_until=""
		local prior_ts=""
		local prior_epoch=""
		prior_until=$(sed -n 1p "$stamp_file" 2>/dev/null || echo "")
		prior_ts=$(sed -n 2p "$stamp_file" 2>/dev/null || echo "")
		prior_epoch=$(_pq_iso_to_epoch "$prior_ts")
		# If the quarantine_until is unchanged (same trip event) and less
		# than 24h since last advisory, suppress.
		if [[ "$prior_until" == "$until_iso" ]] && [[ "$prior_epoch" -gt 0 ]]; then
			local age=$((now_epoch - prior_epoch))
			if [[ "$age" -lt $((24 * 3600)) ]]; then
				should_emit=0
			fi
		fi
	fi

	if [[ "$should_emit" -eq 1 ]]; then
		cat >"$advisory_file" <<EOF
Peer-runner ${peer} has been quarantined by this runner.

Reason:           ${reason}
Triggering issue: ${triggering}
Quarantine until: ${until_iso}
Created:          ${now}

Effect: this runner will treat ${peer}'s DISPATCH_CLAIM comments and
assignee entries as non-blocking until quarantine expires. Other peers
that read this conf file will do the same.

Diagnose: pulse-peer-quarantine-helper.sh status
Release:  pulse-peer-quarantine-helper.sh release ${peer}
Background: reference/cross-runner-coordination.md §9
EOF
		printf '%s\n%s\n' "$until_iso" "$now" >"$stamp_file"
	fi
	return 0
}

#######################################
# cmd_is_quarantined — exit 0 if the named peer is currently quarantined
# (quarantine_until is in the future and breaker is enabled), exit 1
# otherwise. Auto-expiry is enforced here: a stale quarantine_until is
# treated as not-quarantined without rewriting the state file.
# Args: $1 = peer login
#######################################
cmd_is_quarantined() {
	# Accept both --peer NAME (brief-specified) and positional <peer>.
	local peer=""
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--peer)
			peer="${2:-}"
			shift 2
			;;
		--*)
			printf 'is-quarantined: unknown flag: %s\n' "$_arg" >&2
			return 1
			;;
		*)
			[[ -z "$peer" ]] && peer="$_arg"
			shift
			;;
		esac
	done
	if [[ -z "$peer" ]]; then
		echo "Usage: $0 is-quarantined --peer <name>" >&2
		return 1
	fi
	[[ "$PEER_QUARANTINE_DISABLED" == "1" ]] && return 1
	[[ -f "$PEER_QUARANTINE_STATE_FILE" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	local until_iso
	until_iso=$(_pq_get_field "$peer" quarantine_until)
	[[ -z "$until_iso" ]] && return 1
	local until_epoch=""
	local now_epoch=""
	local now_iso=""
	until_epoch=$(_pq_iso_to_epoch "$until_iso")
	now_iso=$(_pq_now)
	now_epoch=$(_pq_iso_to_epoch "$now_iso")
	[[ "$until_epoch" -gt "$now_epoch" ]] && return 0
	return 1
}

#######################################
# cmd_release — manually clear a peer's quarantine. Removes the auto-
# managed conf entry and clears the in-memory state for that peer.
#######################################
cmd_release() {
	# Accept --peer NAME (brief-specified) plus positional <peer>; --reason
	# remains optional. Unknown flags are rejected so typos don't get
	# silently swallowed as the peer name.
	local peer=""
	local reason="manual release"
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--peer)
			peer="${2:-}"
			shift 2
			;;
		--reason)
			reason="${2:-manual release}"
			shift 2
			;;
		--*)
			printf 'release: unknown flag: %s\n' "$_arg" >&2
			return 1
			;;
		*)
			[[ -z "$peer" ]] && peer="$_arg"
			shift
			;;
		esac
	done
	if [[ -z "$peer" ]]; then
		echo "Usage: $0 release --peer <name> [--reason \"<text>\"]" >&2
		return 1
	fi
	_pq_init_state || return 1
	# Reset the peer's record. Pre-compute the JSON-quoted "now" once via
	# the shared helper so the jq filter interpolates `${now_q}` directly.
	local peer_root=""
	local now_q=""
	local reason_q=""
	peer_root=$(_pq_jq_path "$peer")
	now_q=$(_pq_now_q)
	reason_q="\"${reason}\""
	_pq_state_apply \
		"${peer_root} = {failure_count:0, window_started_at:${now_q}, quarantine_until:null, released_at:${now_q}, release_reason:${reason_q}, events:[]}" || return 1
	_pq_clear_override_entry "$peer"
	# Clear advisory + stamp.
	rm -f "${PEER_QUARANTINE_ADVISORY_DIR}/peer-quarantine-${peer}.advisory" \
		"${PEER_QUARANTINE_CACHE_DIR}/peer-quarantine-advisory-${peer}.stamp" 2>/dev/null || true
	printf '%bReleased%b: peer %s quarantine cleared (%s)\n' \
		"$GREEN" "$NC" "$peer" "$reason" >&2
	return 0
}

#######################################
# cmd_status — print state. Default human-readable; --json emits raw JSON.
# Optional positional <peer> filters output to that peer.
#######################################
cmd_status() {
	local emit_json=0
	local filter_peer=""
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--json)
			emit_json=1
			shift
			;;
		*)
			[[ -z "$filter_peer" ]] && filter_peer="$_arg"
			shift
			;;
		esac
	done

	if [[ ! -f "$PEER_QUARANTINE_STATE_FILE" ]]; then
		if [[ "$emit_json" -eq 1 ]]; then
			printf '{"state":"uninitialized","peers":{}}\n'
		else
			printf 'state: uninitialized (no record-peer-event calls yet)\n'
		fi
		return 0
	fi

	if [[ "$emit_json" -eq 1 ]]; then
		if [[ -n "$filter_peer" ]]; then
			jq --arg p "$filter_peer" '.peers[$p] // null' <"$PEER_QUARANTINE_STATE_FILE" 2>/dev/null || cat "$PEER_QUARANTINE_STATE_FILE"
		else
			cat "$PEER_QUARANTINE_STATE_FILE"
		fi
		return 0
	fi

	# Human format.
	local now_epoch=""
	local now_iso=""
	now_iso=$(_pq_now)
	now_epoch=$(_pq_iso_to_epoch "$now_iso")
	local peers
	if [[ -n "$filter_peer" ]]; then
		peers="$filter_peer"
	else
		peers=$(jq -r '.peers | keys[]' <"$PEER_QUARANTINE_STATE_FILE" 2>/dev/null || true)
	fi
	if [[ -z "$peers" ]]; then
		printf 'no peers tracked (threshold=%s, window=%sh, duration=%sh)\n' \
			"$PEER_QUARANTINE_FAILURE_THRESHOLD" \
			"$PEER_QUARANTINE_WINDOW_HOURS" \
			"$PEER_QUARANTINE_DURATION_HOURS"
		return 0
	fi
	local peer=""
	local count=""
	local window=""
	local until_iso=""
	local state=""
	local until_epoch=""
	while IFS= read -r peer; do
		[[ -z "$peer" ]] && continue
		count=$(_pq_get_field "$peer" failure_count)
		window=$(_pq_get_field "$peer" window_started_at)
		until_iso=$(_pq_get_field "$peer" quarantine_until)
		until_epoch=$(_pq_iso_to_epoch "${until_iso:-}")
		if [[ -n "$until_iso" ]] && [[ "$until_epoch" -gt "$now_epoch" ]]; then
			state="quarantined"
		else
			state="closed"
		fi
		printf 'peer=%s state=%s count=%s/%s window_started=%s' \
			"$peer" "$state" "${count:-0}" "$PEER_QUARANTINE_FAILURE_THRESHOLD" "${window:-n/a}"
		if [[ "$state" == "quarantined" ]]; then
			printf ' until=%s' "$until_iso"
		fi
		printf '\n'
	done <<<"$peers"
	return 0
}

#######################################
# cmd_scan_comments — read a JSON array of comments from stdin and record
# every launch_recovery:no_worker_process event from a peer (i.e. not the
# self_login). Schema: each comment object should contain `body` (string)
# and `user.login` (string), or `body_start` + `author` (the shape produced
# by dispatch-dedup-helper.sh's existing comment fetch). Lines with
# unparseable shapes are ignored.
#
# Args (optional):
#   --self-login <login>  — skip events emitted by this login.
#   --issue-ref <ref>     — audit ref to record with each event.
#######################################
cmd_scan_comments() {
	local self_login=""
	local issue_ref="comment-scan"
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--self-login)
			self_login="${2:-}"
			shift 2
			;;
		--issue-ref)
			issue_ref="${2:-comment-scan}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	[[ "$PEER_QUARANTINE_DISABLED" == "1" ]] && return 0
	command -v jq >/dev/null 2>&1 || return 0

	local input
	input=$(cat 2>/dev/null || true)
	[[ -z "$input" ]] && return 0
	[[ "$input" == "[]" ]] && return 0
	[[ "$input" == "null" ]] && return 0

	# Extract `body` (or `body_start` for the dedup-helper shape) from
	# each comment, strip leading whitespace, and grep for the recovery
	# regex via jq's test() so we don't shell out per comment.
	local lines
	lines=$(printf '%s' "$input" | jq -r '
		[.[] | (
			(.body // .body_start // "")
			+ "|"
			+ ((.user.login // .author // ""))
		)]
		| .[]
		| select(test("^CLAIM_RELEASED reason=launch_recovery:no_worker_process runner=[A-Za-z0-9._\\-]+"))
	' 2>/dev/null) || lines=""
	[[ -z "$lines" ]] && return 0

	local body_and_author=""
	local body=""
	local peer=""
	while IFS= read -r body_and_author; do
		[[ -z "$body_and_author" ]] && continue
		body="${body_and_author%|*}"
		# Extract runner=<peer> from the body.
		peer=$(printf '%s' "$body" | sed -nE 's/.*runner=([A-Za-z0-9._-]+).*/\1/p' | head -1)
		[[ -z "$peer" ]] && continue
		# Skip self-login events — those are recorded by the local breaker.
		[[ -n "$self_login" && "$peer" == "$self_login" ]] && continue
		cmd_record_peer_event "$peer" "$issue_ref" || true
	done <<<"$lines"
	return 0
}

#######################################
# Help text.
#######################################
cmd_help() {
	cat <<'EOF'
pulse-peer-quarantine-helper.sh — Cross-runner peer quarantine (t3194).

USAGE:
  pulse-peer-quarantine-helper.sh record-peer-event <peer> <issue-ref>
  pulse-peer-quarantine-helper.sh is-quarantined <peer>
  pulse-peer-quarantine-helper.sh status [--json] [<peer>]
  pulse-peer-quarantine-helper.sh release <peer> [--reason "<text>"]
  pulse-peer-quarantine-helper.sh scan-comments [--self-login <login>] [--issue-ref <ref>]
  pulse-peer-quarantine-helper.sh help

DETECTION SIGNAL (per pulse-cleanup.sh:978):
  CLAIM_RELEASED reason=launch_recovery:no_worker_process runner=<peer>

ENVIRONMENT:
  PEER_QUARANTINE_FAILURE_THRESHOLD       (default 5)
  PEER_QUARANTINE_WINDOW_HOURS            (default 1)
  PEER_QUARANTINE_DURATION_HOURS          (default 6)
  PEER_QUARANTINE_DISABLED                (default 0; set 1 to no-op all subcommands)

EXIT CODES:
  is-quarantined:  0 = peer is currently quarantined (DO honour as if `ignore`)
                   1 = peer is not quarantined (honour normally)
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
	record-peer-event) cmd_record_peer_event "$@" ;;
	is-quarantined) cmd_is_quarantined "$@" ;;
	status) cmd_status "$@" ;;
	release) cmd_release "$@" ;;
	scan-comments) cmd_scan_comments "$@" ;;
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
