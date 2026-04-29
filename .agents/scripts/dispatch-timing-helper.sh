#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# dispatch-timing-helper.sh — t3003: adaptive per-candidate dispatch timeout.
#
# Replaces the fixed FILL_FLOOR_PER_CANDIDATE_TIMEOUT (default 30s) with a
# rolling-window measurement of recent dispatch attempts. Recommends a timeout
# based on EWMA + p95 of recent successes, with PROBE mode after a timeout to
# re-measure under degraded conditions.
#
# WHY (incident 2026-04-27):
#   Direct measurements showed `gh issue edit` taking 3-5s/call. The launch
#   path (assign_and_label, lock, post_launch_hooks) makes 4-6 such calls,
#   exceeding the 30s budget. Result: every dispatch timed out, zero workers
#   spawned, 30+ minutes of pulse cycles with no progress. Fixed timeouts
#   cannot adapt to gh API latency drift.
#
# DESIGN:
#   - Append-only JSONL state file: ~/.aidevops/.agent-workspace/tmp/dispatch-timing-stats.jsonl
#   - Mutex via mkdir lock (no flock dependency — bash 3.2 / macOS compat)
#   - All times in MILLISECONDS (integer math throughout — no float deps)
#   - Bash 3.2 compatible (no associative arrays)
#
# ALGORITHM (recommend):
#   1. Read last N records (default 20).
#   2. Filter to outcome=success, get elapsed_ms array.
#   3. <3 successes → bootstrap default (90000ms).
#   4. Compute EWMA(alpha=0.3) over successes.
#   5. recommended = max(EWMA * 2.0, p95(elapsed_ms))
#   6. If LAST record was a timeout AND it was the immediate previous attempt
#      → PROBE mode: recommended = max(recommended, last_timeout_used * 2).
#   7. Clamp [MIN_TIMEOUT_MS, MAX_TIMEOUT_MS].
#
# USAGE:
#   dispatch-timing-helper.sh recommend [--repo SLUG]
#       → prints recommended timeout in ms (integer)
#   dispatch-timing-helper.sh record \
#       --repo SLUG --issue N --outcome (success|timeout|skip) \
#       --elapsed-ms N --timeout-used-ms N [--probe true|false]
#   dispatch-timing-helper.sh stats [--json]
#   dispatch-timing-helper.sh reset
#   dispatch-timing-helper.sh help

set -uo pipefail

# Source shared constants for color codes + bash 4 self-heal guard
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$SCRIPT_DIR/shared-constants.sh" ]] && source "$SCRIPT_DIR/shared-constants.sh"

# ---------------------------------------------------------------------------
# Tunables — env-overridable, all in milliseconds
# ---------------------------------------------------------------------------

# Hard floor: never recommend below this (gives the simplest possible dispatch
# enough breathing room).
: "${DISPATCH_TIMING_MIN_TIMEOUT_MS:=30000}"

# Hard ceiling: never recommend above this (prevents one runaway latency from
# locking the entire pulse cycle).
: "${DISPATCH_TIMING_MAX_TIMEOUT_MS:=300000}"

# Bootstrap default when we have <3 success measurements.
: "${DISPATCH_TIMING_BOOTSTRAP_MS:=90000}"

# Window size — last N records considered for recommendations.
: "${DISPATCH_TIMING_WINDOW:=20}"

# EWMA alpha (fixed-point, scaled by 100 — alpha=0.3 means 30).
# Higher = more responsive to recent measurements.
: "${DISPATCH_TIMING_EWMA_ALPHA_PCT:=30}"

# Safety multiplier on recent average (fixed-point ×100). Default 200 = 2.0x.
: "${DISPATCH_TIMING_SAFETY_MULT_PCT:=200}"

# Probe-mode multiplier (fixed-point ×100). Default 200 = 2.0x last_timeout.
: "${DISPATCH_TIMING_PROBE_MULT_PCT:=200}"

# Maximum log size — trim to this many lines when exceeded.
: "${DISPATCH_TIMING_MAX_LINES:=1000}"

# State file location.
WORKSPACE_DIR="${AIDEVOPS_WORKSPACE_DIR:-${HOME}/.aidevops/.agent-workspace}"
STATE_DIR="${WORKSPACE_DIR}/tmp"
STATE_FILE="${DISPATCH_TIMING_STATE_FILE:-${STATE_DIR}/dispatch-timing-stats.jsonl}"
LOCK_DIR="${STATE_FILE}.lock.d"

# Lock acquisition timeout (mkdir-based busy-wait).
: "${DISPATCH_TIMING_LOCK_TIMEOUT_S:=5}"

# JSONL field-name constants — extracted to satisfy repeated-literal ratchet
# and to centralise the schema in one place.
readonly _DT_FIELD_OUTCOME="outcome"
readonly _DT_FIELD_ELAPSED_MS="elapsed_ms"
readonly _DT_FIELD_TIMEOUT_USED_MS="timeout_used_ms"

# ---------------------------------------------------------------------------
# Lock helpers — mkdir-based mutex (atomic on POSIX filesystems)
# ---------------------------------------------------------------------------

_dt_acquire_lock() {
	local timeout_s="${DISPATCH_TIMING_LOCK_TIMEOUT_S}"
	local elapsed=0
	mkdir -p "$STATE_DIR" 2>/dev/null
	while ! mkdir "$LOCK_DIR" 2>/dev/null; do
		# Check for stale lock (>30s old → assume crashed)
		if [[ -d "$LOCK_DIR" ]]; then
			local lock_mtime now_epoch age_s
			lock_mtime=$(_file_mtime_epoch "$LOCK_DIR")
			now_epoch=$(date +%s)
			age_s=$((now_epoch - lock_mtime))
			if ((age_s > 30)); then
				rmdir "$LOCK_DIR" 2>/dev/null || true
				continue
			fi
		fi
		sleep 0.1
		elapsed=$((elapsed + 1))
		if ((elapsed > timeout_s * 10)); then
			# Lock acquisition timeout — record helper must remain non-fatal,
			# so callers proceed without recording rather than blocking dispatch.
			return 1
		fi
	done
	# Stamp lock with PID for diagnostics
	echo "$$" >"${LOCK_DIR}/pid" 2>/dev/null || true
	return 0
}

_dt_release_lock() {
	rm -f "${LOCK_DIR}/pid" 2>/dev/null || true
	rmdir "$LOCK_DIR" 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# Read helpers — return last N JSONL records
# ---------------------------------------------------------------------------

_dt_read_window() {
	local n="${1:-$DISPATCH_TIMING_WINDOW}"
	[[ -f "$STATE_FILE" ]] || return 0
	tail -n "$n" "$STATE_FILE" 2>/dev/null
	return 0
}

# Compute integer p95 of a newline-separated list of integers.
# Args: $1 = newline-separated values (via stdin would also work).
# Output: p95 value.
_dt_p95() {
	local values="$1"
	local count
	count=$(printf '%s\n' "$values" | grep -c .)
	if ((count == 0)); then
		echo "0"
		return 0
	fi
	local sorted idx p95
	sorted=$(printf '%s\n' "$values" | sort -n)
	# 95th percentile: index = ceil(count * 0.95) - 1, 0-based
	idx=$(((count * 95 + 99) / 100 - 1))
	((idx < 0)) && idx=0
	((idx >= count)) && idx=$((count - 1))
	p95=$(printf '%s\n' "$sorted" | awk -v i="$idx" 'NR==i+1 {print; exit}')
	echo "${p95:-0}"
	return 0
}

# Compute EWMA over a newline-separated list of integers (oldest first).
# alpha = DISPATCH_TIMING_EWMA_ALPHA_PCT / 100.
# Output: integer EWMA value.
_dt_ewma() {
	local values="$1"
	local alpha="${DISPATCH_TIMING_EWMA_ALPHA_PCT}"
	local count
	count=$(printf '%s\n' "$values" | grep -c .)
	if ((count == 0)); then
		echo "0"
		return 0
	fi
	# EWMA = alpha * value + (1 - alpha) * prev_ewma
	# Fixed-point: alpha is /100, so ewma = (alpha * v + (100 - alpha) * prev) / 100
	local ewma=0 first=1 v
	while IFS= read -r v; do
		[[ -z "$v" ]] && continue
		[[ "$v" =~ ^[0-9]+$ ]] || continue
		if ((first)); then
			ewma="$v"
			first=0
		else
			ewma=$(((alpha * v + (100 - alpha) * ewma) / 100))
		fi
	done <<<"$values"
	echo "$ewma"
	return 0
}

# ---------------------------------------------------------------------------
# Subcommand: recommend
# ---------------------------------------------------------------------------

_dt_cmd_recommend() {
	# Note: --repo is accepted for forward compatibility (per-repo timing in
	# the future), but currently the recommendation is global. Parsed and
	# discarded.
	while (("$#")); do
		local arg="$1"
		case "$arg" in
		--repo)
			shift
			;;
		--repo=*)
			:
			;;
		esac
		shift
	done

	# Read window
	local window
	window=$(_dt_read_window "$DISPATCH_TIMING_WINDOW")

	if [[ -z "$window" ]]; then
		# No history → bootstrap default
		echo "$DISPATCH_TIMING_BOOTSTRAP_MS"
		return 0
	fi

	# Extract success elapsed_ms values (oldest first for EWMA)
	local successes
	successes=$(printf '%s\n' "$window" | _dt_extract_field "success" "$_DT_FIELD_ELAPSED_MS")
	local success_count
	success_count=$(printf '%s\n' "$successes" | grep -c .)

	local recommended

	if ((success_count < 3)); then
		# Insufficient data → bootstrap
		recommended="$DISPATCH_TIMING_BOOTSTRAP_MS"
	else
		# EWMA + p95 + safety multiplier
		local ewma p95 ewma_safe
		ewma=$(_dt_ewma "$successes")
		p95=$(_dt_p95 "$successes")
		ewma_safe=$(((ewma * DISPATCH_TIMING_SAFETY_MULT_PCT) / 100))
		# recommended = max(ewma_safe, p95)
		if ((ewma_safe > p95)); then
			recommended="$ewma_safe"
		else
			recommended="$p95"
		fi
	fi

	# Probe mode: if LAST record is a timeout, recommend at least 2× last_timeout_used
	local last_outcome last_timeout_used probe_mode="false"
	last_outcome=$(printf '%s\n' "$window" | tail -n 1 | _dt_json_field "$_DT_FIELD_OUTCOME")
	if [[ "$last_outcome" == "timeout" ]]; then
		last_timeout_used=$(printf '%s\n' "$window" | tail -n 1 | _dt_json_field "$_DT_FIELD_TIMEOUT_USED_MS")
		if [[ "$last_timeout_used" =~ ^[0-9]+$ ]]; then
			local probe_recommended=$(((last_timeout_used * DISPATCH_TIMING_PROBE_MULT_PCT) / 100))
			if ((probe_recommended > recommended)); then
				recommended="$probe_recommended"
				probe_mode="true"
			fi
		fi
	fi

	# Clamp to [MIN, MAX]
	if ((recommended < DISPATCH_TIMING_MIN_TIMEOUT_MS)); then
		recommended="$DISPATCH_TIMING_MIN_TIMEOUT_MS"
	fi
	if ((recommended > DISPATCH_TIMING_MAX_TIMEOUT_MS)); then
		recommended="$DISPATCH_TIMING_MAX_TIMEOUT_MS"
	fi

	# Round to nearest 1000 (whole seconds)
	recommended=$(((recommended + 500) / 1000 * 1000))

	# Output two lines: timeout_ms and probe_bool
	echo "$recommended"
	echo "$probe_mode"
	return 0
}

# Extract value of $field from a single JSONL record on stdin.
# Uses grep -oE to isolate the specific key-value pair, which avoids the
# greedy-prefix issue where sed's .* can match a field name that appears as
# a substring inside a preceding field's value.  Bash 3.2 compatible — no
# jq dependency.
# Args: $1 = field name (string-valued or numeric).
_dt_json_field() {
	local field="$1"
	local line
	IFS= read -r line
	# Match "field":"value" (string) OR "field":NUMBER (numeric).
	# grep -oE emits only the matching text; tail -1 handles the rare
	# duplicate-key edge case by preferring the last occurrence.
	# Try string first
	local val
	val=$(printf '%s' "$line" | grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | tail -1 | cut -d'"' -f4)
	if [[ -n "$val" ]]; then
		echo "$val"
		return 0
	fi
	# Try numeric
	val=$(printf '%s' "$line" | grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*[0-9]+" | tail -1 | cut -d: -f2 | tr -d ' ')
	echo "$val"
	return 0
}

# Filter records on stdin where outcome matches $target_outcome, then extract
# the value of $field. Output: one value per line (oldest first, matching
# input order). Delegates to _dt_json_field to avoid duplicating sed patterns.
_dt_extract_field() {
	local target_outcome="$1"
	local field="$2"
	local line line_outcome val
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		line_outcome=$(printf '%s\n' "$line" | _dt_json_field "$_DT_FIELD_OUTCOME")
		[[ "$line_outcome" == "$target_outcome" ]] || continue
		val=$(printf '%s\n' "$line" | _dt_json_field "$field")
		[[ -n "$val" ]] && echo "$val"
	done
	return 0
}

# ---------------------------------------------------------------------------
# Subcommand: record
# ---------------------------------------------------------------------------

_dt_cmd_record() {
	local repo="" issue="" outcome="" elapsed_ms="" timeout_used_ms="" probe="false"
	while (("$#")); do
		local arg="$1"
		case "$arg" in
		--repo)
			repo="${2:-}"
			shift 2
			;;
		--issue)
			issue="${2:-}"
			shift 2
			;;
		--outcome)
			outcome="${2:-}"
			shift 2
			;;
		--elapsed-ms)
			elapsed_ms="${2:-}"
			shift 2
			;;
		--timeout-used-ms)
			timeout_used_ms="${2:-}"
			shift 2
			;;
		--probe)
			probe="${2:-false}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	# Validate required fields
	if [[ -z "$repo" || -z "$issue" || -z "$outcome" || -z "$elapsed_ms" || -z "$timeout_used_ms" ]]; then
		echo "Error: record requires --repo, --issue, --outcome, --elapsed-ms, --timeout-used-ms" >&2
		return 1
	fi
	[[ "$elapsed_ms" =~ ^[0-9]+$ ]] || {
		echo "Error: --elapsed-ms must be integer" >&2
		return 1
	}
	[[ "$timeout_used_ms" =~ ^[0-9]+$ ]] || {
		echo "Error: --timeout-used-ms must be integer" >&2
		return 1
	}
	case "$outcome" in
	success | timeout | skip) ;;
	*)
		echo "Error: --outcome must be success|timeout|skip" >&2
		return 1
		;;
	esac

	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Acquire lock — fail-open if we can't, so dispatch is never blocked
	# by recording machinery.
	_dt_acquire_lock || {
		echo "[dispatch-timing] WARN: lock timeout — skipping record (non-fatal)" >&2
		return 0
	}

	# Append record (atomic on POSIX <= PIPE_BUF=4096)
	mkdir -p "$STATE_DIR"
	printf '{"ts":"%s","repo":"%s","issue":%s,"outcome":"%s","elapsed_ms":%s,"timeout_used_ms":%s,"probe":%s}\n' \
		"$ts" "$repo" "$issue" "$outcome" "$elapsed_ms" "$timeout_used_ms" "$probe" \
		>>"$STATE_FILE"

	# Trim if oversized
	_dt_trim_if_needed

	_dt_release_lock
	return 0
}

_dt_trim_if_needed() {
	[[ -f "$STATE_FILE" ]] || return 0
	local line_count
	line_count=$(wc -l <"$STATE_FILE" 2>/dev/null || echo "0")
	[[ "$line_count" =~ ^[0-9]+$ ]] || line_count=0
	if ((line_count > DISPATCH_TIMING_MAX_LINES)); then
		# Rotate: keep last MAX_LINES, archive rest
		local archive="${STATE_FILE}.1"
		local keep="$DISPATCH_TIMING_MAX_LINES"
		# Copy older lines to archive (append-only)
		head -n $((line_count - keep)) "$STATE_FILE" >>"$archive" 2>/dev/null || true
		# Keep last `keep` lines in place
		local tmp="${STATE_FILE}.tmp.$$"
		tail -n "$keep" "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Subcommand: stats
# ---------------------------------------------------------------------------

_dt_cmd_stats() {
	local json_mode=0
	while (("$#")); do
		local arg="$1"
		case "$arg" in
		--json) json_mode=1 ;;
		esac
		shift
	done

	local window total_records successes timeouts skips
	window=$(_dt_read_window "$DISPATCH_TIMING_WINDOW")
	total_records=0
	successes=0
	timeouts=0
	skips=0
	if [[ -n "$window" ]]; then
		total_records=$(printf '%s\n' "$window" | grep -c .)
		# Build the outcome-key prefix once so the field name only appears in
		# one place per scan (satisfies the repeated-literal ratchet).
		local outcome_key_prefix='"'"$_DT_FIELD_OUTCOME"'":"'
		successes=$(printf '%s\n' "$window" | grep -c "${outcome_key_prefix}success\"" 2>/dev/null || true)
		timeouts=$(printf '%s\n' "$window" | grep -c "${outcome_key_prefix}timeout\"" 2>/dev/null || true)
		skips=$(printf '%s\n' "$window" | grep -c "${outcome_key_prefix}skip\"" 2>/dev/null || true)
		[[ "$successes" =~ ^[0-9]+$ ]] || successes=0
		[[ "$timeouts" =~ ^[0-9]+$ ]] || timeouts=0
		[[ "$skips" =~ ^[0-9]+$ ]] || skips=0
	fi

	local success_values ewma p50 p95 recommended
	success_values=""
	ewma=0
	p50=0
	p95=0
	if ((successes > 0)); then
		success_values=$(printf '%s\n' "$window" | _dt_extract_field "success" "$_DT_FIELD_ELAPSED_MS")
		ewma=$(_dt_ewma "$success_values")
		# p50 = median = same algorithm as p95 with idx 50
		local sorted count idx
		count=$(printf '%s\n' "$success_values" | grep -c .)
		sorted=$(printf '%s\n' "$success_values" | sort -n)
		idx=$(((count * 50 + 99) / 100 - 1))
		((idx < 0)) && idx=0
		p50=$(printf '%s\n' "$sorted" | awk -v i="$idx" 'NR==i+1 {print; exit}')
		[[ -z "$p50" ]] && p50=0
		p95=$(_dt_p95 "$success_values")
	fi
	recommended=$(_dt_cmd_recommend)

	if ((json_mode)); then
		printf '{"window":%s,"total_records":%s,"successes":%s,"timeouts":%s,"skips":%s,"ewma_ms":%s,"p50_ms":%s,"p95_ms":%s,"recommended_ms":%s}\n' \
			"$DISPATCH_TIMING_WINDOW" "$total_records" "$successes" "$timeouts" "$skips" \
			"$ewma" "$p50" "$p95" "$recommended"
	else
		printf 'Dispatch timing stats (window=%s)\n' "$DISPATCH_TIMING_WINDOW"
		printf '  total records: %s\n' "$total_records"
		printf '  successes:     %s\n' "$successes"
		printf '  timeouts:      %s\n' "$timeouts"
		printf '  skips:         %s\n' "$skips"
		printf '  ewma_ms:       %s\n' "$ewma"
		printf '  p50_ms:        %s\n' "$p50"
		printf '  p95_ms:        %s\n' "$p95"
		printf '  recommended:   %sms (next dispatch budget)\n' "$recommended"
		printf '  state_file:    %s\n' "$STATE_FILE"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Subcommand: reset
# ---------------------------------------------------------------------------

_dt_cmd_reset() {
	_dt_acquire_lock || {
		echo "Error: lock timeout" >&2
		return 1
	}
	rm -f "$STATE_FILE" "${STATE_FILE}.1" 2>/dev/null
	_dt_release_lock
	echo "Reset: state file removed"
	return 0
}

# ---------------------------------------------------------------------------
# Subcommand: help
# ---------------------------------------------------------------------------

_dt_show_help() {
	cat <<'EOF'
dispatch-timing-helper.sh — t3003: adaptive per-candidate dispatch timeout.

USAGE:
  dispatch-timing-helper.sh recommend [--repo SLUG]
      Print recommended timeout (integer ms). Used by pulse-dispatch-engine
      to set per-candidate budget based on rolling-window measurement.

  dispatch-timing-helper.sh record \
      --repo SLUG --issue N --outcome (success|timeout|skip) \
      --elapsed-ms N --timeout-used-ms N [--probe true|false]
      Append a measurement record. Called by pulse-dispatch-engine after
      each dispatch attempt.

  dispatch-timing-helper.sh stats [--json]
      Print rolling-window statistics (EWMA, p50, p95, recommended).

  dispatch-timing-helper.sh reset
      Truncate state file. Used in tests and after major incidents.

  dispatch-timing-helper.sh help
      Show this help.

ENVIRONMENT:
  DISPATCH_TIMING_MIN_TIMEOUT_MS        Floor (default 30000)
  DISPATCH_TIMING_MAX_TIMEOUT_MS        Ceiling (default 300000)
  DISPATCH_TIMING_BOOTSTRAP_MS          Default when <3 successes (90000)
  DISPATCH_TIMING_WINDOW                Rolling window size (default 20)
  DISPATCH_TIMING_EWMA_ALPHA_PCT        EWMA alpha ×100 (default 30 = 0.3)
  DISPATCH_TIMING_SAFETY_MULT_PCT       Safety multiplier ×100 (default 200 = 2.0x)
  DISPATCH_TIMING_PROBE_MULT_PCT        Probe-mode multiplier ×100 (default 200)
  DISPATCH_TIMING_MAX_LINES             Trim threshold (default 1000)
  DISPATCH_TIMING_STATE_FILE            Override state file path
  DISPATCH_TIMING_LOCK_TIMEOUT_S        Lock acquisition timeout (default 5)

EXIT CODES:
  0  success
  1  invalid args / unrecoverable error
EOF
	return 0
}

# ---------------------------------------------------------------------------
# CLI entry
# ---------------------------------------------------------------------------

main() {
	local cmd="${1:-help}"
	shift || true
	case "$cmd" in
	recommend) _dt_cmd_recommend "$@" ;;
	record) _dt_cmd_record "$@" ;;
	stats) _dt_cmd_stats "$@" ;;
	reset) _dt_cmd_reset "$@" ;;
	help | --help | -h) _dt_show_help ;;
	*)
		echo "Error: unknown command '$cmd'" >&2
		_dt_show_help >&2
		return 1
		;;
	esac
	return $?
}

# Don't execute main if sourced (for tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
