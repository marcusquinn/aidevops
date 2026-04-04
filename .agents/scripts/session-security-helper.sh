#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# session-security-helper.sh — Session-scoped composite security scoring (t1428.3)
#
# Provides session-scoped security context that accumulates signals across
# operations. Implements lightweight taint tracking without syscall interception.
#
# When prompt-guard-helper.sh detects sensitive file access or injection patterns,
# it writes to the session state. When network-tier-helper.sh evaluates an outbound
# request, it checks the session state — if sensitive data was accessed, the
# composite score gets elevated.
#
# Session context is stored as JSON at:
#   ~/.aidevops/.agent-workspace/security/session-context.json
#
# Usage:
#   session-security-helper.sh init [--session-id ID]       Initialize session context
#   session-security-helper.sh record-signal <type> <severity> <detail> [--session-id ID]
#                                                            Record a security signal
#   session-security-helper.sh get-score [--session-id ID]   Get composite security score
#   session-security-helper.sh get-context [--session-id ID] Get full session context (JSON)
#   session-security-helper.sh check-taint [--session-id ID] Check if session is tainted
#   session-security-helper.sh elevate-tier <domain> [--session-id ID]
#                                                            Get elevated tier for domain
#   session-security-helper.sh reset [--session-id ID]       Reset session context
#   session-security-helper.sh cleanup [--max-age HOURS]     Remove stale session files
#   session-security-helper.sh test                          Run built-in test suite
#   session-security-helper.sh help                          Show usage
#
# Signal types:
#   prompt-injection    Prompt injection pattern detected
#   sensitive-file      Sensitive file accessed (credentials, .env, keys)
#   sensitive-data      Sensitive data pattern detected in content
#   network-flag        Network tier 4/5 domain accessed
#   sandbox-violation   Sandbox boundary violation
#
# Severity weights (summed for composite score):
#   LOW=1, MEDIUM=2, HIGH=3, CRITICAL=4
#
# Composite score thresholds:
#   0       CLEAN    — no security signals
#   1-3     LOW      — minor signals, no action needed
#   4-7     MEDIUM   — elevated awareness, log network access
#   8-15    HIGH     — tainted session, elevate network tier checks
#   16+     CRITICAL — heavily tainted, block tier 4+ network access
#
# Environment:
#   SESSION_SECURITY_DIR     Override session context directory
#   SESSION_SECURITY_ID      Default session ID (fallback: PID-based)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

LOG_PREFIX="SEC-SESSION"

# =============================================================================
# Constants
# =============================================================================

readonly SESSION_SECURITY_BASE_DIR="${SESSION_SECURITY_DIR:-${HOME}/.aidevops/.agent-workspace/security}"

# Severity weights (must match prompt-guard-helper.sh)
readonly SS_WEIGHT_LOW=1
readonly SS_WEIGHT_MEDIUM=2
readonly SS_WEIGHT_HIGH=3
readonly SS_WEIGHT_CRITICAL=4

# Composite score thresholds
readonly SS_THRESHOLD_LOW=1
readonly SS_THRESHOLD_MEDIUM=4
readonly SS_THRESHOLD_HIGH=8
readonly SS_THRESHOLD_CRITICAL=16

# Taint flag: session is considered tainted at MEDIUM or above
readonly SS_TAINT_THRESHOLD="$SS_THRESHOLD_MEDIUM"

# Maximum age for stale session files (hours)
readonly SS_DEFAULT_MAX_AGE=24

# =============================================================================
# Session ID Resolution
# =============================================================================

# Resolve the session ID from flags, env, or generate a default.
# Arguments:
#   $@ - remaining args to scan for --session-id
# Output: session ID on stdout
_ss_resolve_session_id() {
	local session_id="${SESSION_SECURITY_ID:-}"

	# Scan args for --session-id
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-id)
			session_id="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Fallback: PID-based ID
	if [[ -z "$session_id" ]]; then
		session_id="pid-$$"
	fi

	printf '%s' "$session_id"
	return 0
}

# Get the session context file path for a given session ID.
# Arguments:
#   $1 - session ID
# Output: file path on stdout
_ss_context_file() {
	local session_id="$1"
	# Sanitize session ID for filesystem safety (allow alphanumeric, dash, underscore, dot)
	local safe_id
	safe_id=$(printf '%s' "$session_id" | tr -cd 'a-zA-Z0-9._-')
	if [[ -z "$safe_id" ]]; then
		safe_id="default"
	fi
	printf '%s/session-%s.json' "$SESSION_SECURITY_BASE_DIR" "$safe_id"
	return 0
}

# =============================================================================
# Severity Helpers
# =============================================================================

# Convert severity string to numeric weight.
# Arguments:
#   $1 - severity string (LOW, MEDIUM, HIGH, CRITICAL)
# Output: numeric weight on stdout
_ss_severity_weight() {
	local severity="$1"
	case "$severity" in
	CRITICAL) echo "$SS_WEIGHT_CRITICAL" ;;
	HIGH) echo "$SS_WEIGHT_HIGH" ;;
	MEDIUM) echo "$SS_WEIGHT_MEDIUM" ;;
	LOW) echo "$SS_WEIGHT_LOW" ;;
	*) echo "0" ;;
	esac
	return 0
}

# Convert composite score to threat level string.
# Arguments:
#   $1 - composite score (integer)
# Output: threat level on stdout
_ss_score_to_level() {
	local score="$1"
	if [[ "$score" -ge "$SS_THRESHOLD_CRITICAL" ]]; then
		echo "CRITICAL"
	elif [[ "$score" -ge "$SS_THRESHOLD_HIGH" ]]; then
		echo "HIGH"
	elif [[ "$score" -ge "$SS_THRESHOLD_MEDIUM" ]]; then
		echo "MEDIUM"
	elif [[ "$score" -ge "$SS_THRESHOLD_LOW" ]]; then
		echo "LOW"
	else
		echo "CLEAN"
	fi
	return 0
}

# =============================================================================
# Session Context Operations
# =============================================================================

# Initialize a new session context file.
# Arguments:
#   $1 - session ID
# Returns: 0 on success
cmd_init() {
	local session_id
	session_id=$(_ss_resolve_session_id "$@")
	local context_file
	context_file=$(_ss_context_file "$session_id")

	mkdir -p "$SESSION_SECURITY_BASE_DIR" 2>/dev/null || true

	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Create initial context (portable JSON without jq)
	cat >"$context_file" <<EOF
{
  "session_id": "${session_id}",
  "created_at": "${timestamp}",
  "updated_at": "${timestamp}",
  "composite_score": 0,
  "threat_level": "CLEAN",
  "tainted": false,
  "signal_count": 0,
  "signals": []
}
EOF

	log_info "Session security context initialized: ${session_id}"
	echo "$session_id"
	return 0
}

# Update context file using jq (when available).
# Arguments:
#   $1 - context_file path
#   $2 - signal_type
#   $3 - severity
#   $4 - weight (integer)
#   $5 - safe_detail
#   $6 - timestamp
# Returns: 0 on success
_ss_record_signal_jq() {
	local context_file="$1"
	local signal_type="$2"
	local severity="$3"
	local weight="$4"
	local safe_detail="$5"
	local timestamp="$6"

	local new_signal
	new_signal=$(jq -nc \
		--arg ts "$timestamp" \
		--arg type "$signal_type" \
		--arg sev "$severity" \
		--argjson weight "$weight" \
		--arg detail "$safe_detail" \
		'{timestamp: $ts, type: $type, severity: $sev, weight: $weight, detail: $detail}')

	local updated
	updated=$(jq \
		--argjson signal "$new_signal" \
		--argjson weight "$weight" \
		--arg ts "$timestamp" \
		--argjson taint_threshold "$SS_TAINT_THRESHOLD" \
		'
		.signals += [$signal] |
		.signal_count += 1 |
		.composite_score += $weight |
		.updated_at = $ts |
		.tainted = (.composite_score >= $taint_threshold) |
		.threat_level = (
			if .composite_score >= 16 then "CRITICAL"
			elif .composite_score >= 8 then "HIGH"
			elif .composite_score >= 4 then "MEDIUM"
			elif .composite_score >= 1 then "LOW"
			else "CLEAN"
			end
		)
		' "$context_file")

	printf '%s\n' "$updated" >"$context_file"
	return 0
}

# Update context file without jq (portable sed/grep fallback).
# Arguments:
#   $1 - context_file path
#   $2 - session_id
#   $3 - signal_type
#   $4 - severity
#   $5 - weight (integer)
#   $6 - safe_detail
#   $7 - timestamp
# Returns: 0 on success
_ss_record_signal_fallback() {
	local context_file="$1"
	local session_id="$2"
	local signal_type="$3"
	local severity="$4"
	local weight="$5"
	local safe_detail="$6"
	local timestamp="$7"

	local current_score=0
	local current_count=0
	local existing_signals=""
	local created_at="$timestamp"

	if [[ -f "$context_file" ]]; then
		current_score=$(grep -o '"composite_score": *[0-9]*' "$context_file" | grep -o '[0-9]*' | head -1) || current_score=0
		current_count=$(grep -o '"signal_count": *[0-9]*' "$context_file" | grep -o '[0-9]*' | head -1) || current_count=0
		existing_signals=$(sed -n '/\"signals\"/,/\]/p' "$context_file" | grep -v '"signals"' | grep -v '^\s*\]' | sed 's/^[[:space:]]*//' || true)
		created_at=$(grep -o '"created_at": *"[^"]*"' "$context_file" 2>/dev/null | cut -d'"' -f4 || echo "$timestamp")
	fi

	local new_score=$((current_score + weight))
	local new_count=$((current_count + 1))
	local new_level
	new_level=$(_ss_score_to_level "$new_score")
	local new_tainted="false"
	if [[ "$new_score" -ge "$SS_TAINT_THRESHOLD" ]]; then
		new_tainted="true"
	fi

	local signal_entry
	signal_entry=$(printf '    {"timestamp": "%s", "type": "%s", "severity": "%s", "weight": %d, "detail": "%s"}' \
		"$timestamp" "$signal_type" "$severity" "$weight" "$safe_detail")

	local signals_content=""
	if [[ -n "$existing_signals" ]]; then
		existing_signals=$(printf '%s' "$existing_signals" | sed 's/,*[[:space:]]*$//')
		signals_content="${existing_signals},
${signal_entry}"
	else
		signals_content="$signal_entry"
	fi

	cat >"$context_file" <<EOF
{
  "session_id": "${session_id}",
  "created_at": "${created_at}",
  "updated_at": "${timestamp}",
  "composite_score": ${new_score},
  "threat_level": "${new_level}",
  "tainted": ${new_tainted},
  "signal_count": ${new_count},
  "signals": [
${signals_content}
  ]
}
EOF
	return 0
}

# Record a security signal in the session context.
# Arguments:
#   $1 - signal type (prompt-injection, sensitive-file, sensitive-data, network-flag, sandbox-violation)
#   $2 - severity (LOW, MEDIUM, HIGH, CRITICAL)
#   $3 - detail description
#   Remaining args scanned for --session-id
# Returns: 0 on success
cmd_record_signal() {
	local signal_type="${1:-}"
	local severity="${2:-}"
	local detail="${3:-}"
	shift 3 2>/dev/null || true

	if [[ -z "$signal_type" || -z "$severity" ]]; then
		log_error "Usage: session-security-helper.sh record-signal <type> <severity> <detail> [--session-id ID]"
		return 1
	fi

	local session_id
	session_id=$(_ss_resolve_session_id "$@")
	local context_file
	context_file=$(_ss_context_file "$session_id")

	# Auto-init if context doesn't exist
	if [[ ! -f "$context_file" ]]; then
		cmd_init --session-id "$session_id" >/dev/null
	fi

	local weight
	weight=$(_ss_severity_weight "$severity")
	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Truncate detail for storage (max 200 chars)
	local safe_detail
	safe_detail=$(printf '%s' "$detail" | head -c 200 | tr -d '"' | tr -d "\\" | tr '\n' ' ')

	if command -v jq &>/dev/null; then
		_ss_record_signal_jq "$context_file" "$signal_type" "$severity" "$weight" "$safe_detail" "$timestamp"
	else
		_ss_record_signal_fallback "$context_file" "$session_id" "$signal_type" "$severity" "$weight" "$safe_detail" "$timestamp"
	fi

	log_warn "Signal recorded: ${signal_type} (${severity}, +${weight}) — session ${session_id}, score now $(cmd_get_score --session-id "$session_id")"
	return 0
}

# Get the composite security score for a session.
# Arguments:
#   Scanned for --session-id
# Output: composite score (integer) on stdout
cmd_get_score() {
	local session_id
	session_id=$(_ss_resolve_session_id "$@")
	local context_file
	context_file=$(_ss_context_file "$session_id")

	if [[ ! -f "$context_file" ]]; then
		echo "0"
		return 0
	fi

	if command -v jq &>/dev/null; then
		jq -r '.composite_score // 0' "$context_file"
	else
		grep -o '"composite_score": *[0-9]*' "$context_file" | grep -o '[0-9]*' | head -1 || echo "0"
	fi
	return 0
}

# Get the full session context as JSON.
# Arguments:
#   Scanned for --session-id
# Output: JSON on stdout
cmd_get_context() {
	local session_id
	session_id=$(_ss_resolve_session_id "$@")
	local context_file
	context_file=$(_ss_context_file "$session_id")

	if [[ ! -f "$context_file" ]]; then
		echo '{"session_id":"'"$session_id"'","composite_score":0,"threat_level":"CLEAN","tainted":false,"signal_count":0,"signals":[]}'
		return 0
	fi

	cat "$context_file"
	return 0
}

# Check if the session is tainted (composite score >= taint threshold).
# Arguments:
#   Scanned for --session-id
# Returns: 0 if tainted, 1 if clean
# Output: "TAINTED" or "CLEAN" on stdout
cmd_check_taint() {
	local session_id
	session_id=$(_ss_resolve_session_id "$@")
	local context_file
	context_file=$(_ss_context_file "$session_id")

	if [[ ! -f "$context_file" ]]; then
		echo "CLEAN"
		return 1
	fi

	local score
	score=$(cmd_get_score --session-id "$session_id")

	if [[ "$score" -ge "$SS_TAINT_THRESHOLD" ]]; then
		local level
		level=$(_ss_score_to_level "$score")
		echo "TAINTED|score=${score}|level=${level}"
		return 0
	fi

	echo "CLEAN|score=${score}"
	return 1
}

# Get the elevated network tier for a domain based on session taint.
# If the session is tainted, domains that would normally be tier 3-4
# get elevated (tier number increases = more restrictive).
# Arguments:
#   $1 - domain
#   Remaining args scanned for --session-id
# Output: elevated tier number on stdout
cmd_elevate_tier() {
	local domain="${1:-}"
	shift || true

	if [[ -z "$domain" ]]; then
		log_error "Domain required. Usage: session-security-helper.sh elevate-tier <domain> [--session-id ID]"
		return 1
	fi

	local session_id
	session_id=$(_ss_resolve_session_id "$@")

	# Get base tier from network-tier-helper.sh if available
	local base_tier=4
	local net_tier_helper="${SCRIPT_DIR}/network-tier-helper.sh"
	if [[ -x "$net_tier_helper" ]]; then
		base_tier=$("$net_tier_helper" classify "$domain" 2>/dev/null) || base_tier=4
	fi

	# Get session score
	local score
	score=$(cmd_get_score --session-id "$session_id")
	local level
	level=$(_ss_score_to_level "$score")

	# Elevation logic:
	# - CLEAN/LOW: no elevation
	# - MEDIUM: tier 4 (unknown) → tier 5 (deny)
	# - HIGH: tier 3+ → tier 5 (deny)
	# - CRITICAL: tier 2+ → tier 5 (deny), only tier 1 allowed
	local elevated_tier="$base_tier"

	case "$level" in
	CRITICAL)
		if [[ "$base_tier" -ge 2 ]]; then
			elevated_tier=5
		fi
		;;
	HIGH)
		if [[ "$base_tier" -ge 3 ]]; then
			elevated_tier=5
		fi
		;;
	MEDIUM)
		if [[ "$base_tier" -ge 4 ]]; then
			elevated_tier=5
		fi
		;;
	*)
		# CLEAN or LOW: no elevation
		elevated_tier="$base_tier"
		;;
	esac

	if [[ "$elevated_tier" != "$base_tier" ]]; then
		log_warn "Tier elevated: ${domain} T${base_tier}→T${elevated_tier} (session ${level}, score=${score})"
	fi

	echo "$elevated_tier"
	return 0
}

# Reset the session context (clear all signals).
# Arguments:
#   Scanned for --session-id
cmd_reset() {
	local session_id
	session_id=$(_ss_resolve_session_id "$@")
	local context_file
	context_file=$(_ss_context_file "$session_id")

	if [[ -f "$context_file" ]]; then
		rm -f "$context_file"
	fi

	cmd_init --session-id "$session_id" >/dev/null
	log_info "Session security context reset: ${session_id}"
	return 0
}

# Clean up stale session context files.
# Arguments:
#   --max-age HOURS (default: 24)
cmd_cleanup() {
	local max_age="$SS_DEFAULT_MAX_AGE"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--max-age)
			max_age="${2:-$SS_DEFAULT_MAX_AGE}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ ! -d "$SESSION_SECURITY_BASE_DIR" ]]; then
		log_info "No session security directory to clean"
		return 0
	fi

	local cleaned=0
	local max_age_minutes=$((max_age * 60))

	# Find and remove session files older than max_age
	while IFS= read -r -d '' file; do
		rm -f "$file"
		cleaned=$((cleaned + 1))
	done < <(find "$SESSION_SECURITY_BASE_DIR" -name 'session-*.json' -mmin +"$max_age_minutes" -print0 2>/dev/null)

	if [[ "$cleaned" -gt 0 ]]; then
		log_info "Cleaned ${cleaned} stale session context file(s) (older than ${max_age}h)"
	fi
	return 0
}

# =============================================================================
# Test Suite
# =============================================================================

# Assert equality helper used within cmd_test scope.
# Increments passed/failed/total counters (caller-scoped via upvar pattern).
# Arguments: $1=desc $2=expected $3=actual
# Note: passed/failed/total must be declared in the calling scope.
_test_assert_eq() {
	local desc="$1"
	local expected="$2"
	local actual="$3"
	total=$((total + 1))
	if [[ "$actual" == "$expected" ]]; then
		echo "  PASS $desc"
		passed=$((passed + 1))
	else
		echo "  FAIL $desc (expected='$expected', got='$actual')"
		failed=$((failed + 1))
	fi
	return 0
}

# Assert exit-code helper used within cmd_test scope.
# Arguments: $1=desc $2=expected_exit $@=command
_test_assert_exit() {
	local desc="$1"
	local expected_exit="$2"
	shift 2
	total=$((total + 1))
	local actual_exit=0
	"$@" >/dev/null 2>&1 || actual_exit=$?
	if [[ "$actual_exit" -eq "$expected_exit" ]]; then
		echo "  PASS $desc (exit=$actual_exit)"
		passed=$((passed + 1))
	else
		echo "  FAIL $desc (expected exit=$expected_exit, got=$actual_exit)"
		failed=$((failed + 1))
	fi
	return 0
}

# Test group: init and initial state.
_test_group_init() {
	local test_session="$1"
	echo ""
	echo "Testing init:"
	local init_result
	init_result=$(cmd_init --session-id "$test_session" 2>/dev/null)
	_test_assert_eq "Init returns session ID" "$test_session" "$init_result"

	local score
	score=$(cmd_get_score --session-id "$test_session" 2>/dev/null)
	_test_assert_eq "Initial score is 0" "0" "$score"

	echo ""
	echo "Testing check-taint (clean session):"
	_test_assert_exit "Clean session returns exit 1" 1 cmd_check_taint --session-id "$test_session"
	return 0
}

# Test group: signal recording and taint transitions.
_test_group_signals() {
	local test_session="$1"
	local score

	echo ""
	echo "Testing record-signal (LOW):"
	cmd_record_signal "prompt-injection" "LOW" "Test low signal" --session-id "$test_session" 2>/dev/null
	score=$(cmd_get_score --session-id "$test_session" 2>/dev/null)
	_test_assert_eq "Score after LOW signal" "1" "$score"

	echo ""
	echo "Testing record-signal (MEDIUM):"
	cmd_record_signal "sensitive-file" "MEDIUM" "Accessed .env file" --session-id "$test_session" 2>/dev/null
	score=$(cmd_get_score --session-id "$test_session" 2>/dev/null)
	_test_assert_eq "Score after LOW+MEDIUM" "3" "$score"

	echo ""
	echo "Testing check-taint (below threshold):"
	_test_assert_exit "Score 3 is not tainted (threshold=4)" 1 cmd_check_taint --session-id "$test_session"

	echo ""
	echo "Testing record-signal (HIGH) — crosses taint threshold:"
	cmd_record_signal "sensitive-data" "HIGH" "API key pattern detected" --session-id "$test_session" 2>/dev/null
	score=$(cmd_get_score --session-id "$test_session" 2>/dev/null)
	_test_assert_eq "Score after LOW+MEDIUM+HIGH" "6" "$score"

	echo ""
	echo "Testing check-taint (tainted session):"
	_test_assert_exit "Score 6 is tainted" 0 cmd_check_taint --session-id "$test_session"

	echo ""
	echo "Testing get-context:"
	local context
	context=$(cmd_get_context --session-id "$test_session" 2>/dev/null)
	total=$((total + 1))
	if echo "$context" | grep -q '"signal_count"'; then
		echo "  PASS get-context returns valid JSON with signal_count"
		passed=$((passed + 1))
	else
		echo "  FAIL get-context missing signal_count"
		failed=$((failed + 1))
	fi

	echo ""
	echo "Testing record-signal (CRITICAL) — reaches HIGH level:"
	cmd_record_signal "sandbox-violation" "CRITICAL" "Sandbox escape attempt" --session-id "$test_session" 2>/dev/null
	score=$(cmd_get_score --session-id "$test_session" 2>/dev/null)
	_test_assert_eq "Score after all signals" "10" "$score"

	local taint_result
	taint_result=$(cmd_check_taint --session-id "$test_session" 2>/dev/null) || true
	total=$((total + 1))
	if echo "$taint_result" | grep -q "TAINTED.*HIGH"; then
		echo "  PASS Taint check shows HIGH level"
		passed=$((passed + 1))
	else
		echo "  FAIL Taint check expected HIGH level, got: $taint_result"
		failed=$((failed + 1))
	fi
	return 0
}

# Test group: score-to-level and severity weight mappings.
_test_group_mappings() {
	echo ""
	echo "Testing score-to-level mapping:"
	_test_assert_eq "Score 0 = CLEAN" "CLEAN" "$(_ss_score_to_level 0)"
	_test_assert_eq "Score 1 = LOW" "LOW" "$(_ss_score_to_level 1)"
	_test_assert_eq "Score 3 = LOW" "LOW" "$(_ss_score_to_level 3)"
	_test_assert_eq "Score 4 = MEDIUM" "MEDIUM" "$(_ss_score_to_level 4)"
	_test_assert_eq "Score 7 = MEDIUM" "MEDIUM" "$(_ss_score_to_level 7)"
	_test_assert_eq "Score 8 = HIGH" "HIGH" "$(_ss_score_to_level 8)"
	_test_assert_eq "Score 15 = HIGH" "HIGH" "$(_ss_score_to_level 15)"
	_test_assert_eq "Score 16 = CRITICAL" "CRITICAL" "$(_ss_score_to_level 16)"
	_test_assert_eq "Score 100 = CRITICAL" "CRITICAL" "$(_ss_score_to_level 100)"

	echo ""
	echo "Testing severity weight mapping:"
	_test_assert_eq "LOW weight" "1" "$(_ss_severity_weight "LOW")"
	_test_assert_eq "MEDIUM weight" "2" "$(_ss_severity_weight "MEDIUM")"
	_test_assert_eq "HIGH weight" "3" "$(_ss_severity_weight "HIGH")"
	_test_assert_eq "CRITICAL weight" "4" "$(_ss_severity_weight "CRITICAL")"
	_test_assert_eq "Unknown weight" "0" "$(_ss_severity_weight "UNKNOWN")"
	return 0
}

# Test group: reset and non-existent session edge cases.
_test_group_misc() {
	local test_session="$1"

	echo ""
	echo "Testing reset:"
	cmd_reset --session-id "$test_session" 2>/dev/null
	local score
	score=$(cmd_get_score --session-id "$test_session" 2>/dev/null)
	_test_assert_eq "Score after reset" "0" "$score"

	echo ""
	echo "Testing non-existent session:"
	local ne_score
	ne_score=$(cmd_get_score --session-id "nonexistent-session-xyz" 2>/dev/null)
	_test_assert_eq "Non-existent session score" "0" "$ne_score"
	return 0
}

cmd_test() {
	echo "Session Security Helper — Test Suite (t1428.3)"
	echo "========================================================"

	local passed=0
	local failed=0
	local total=0

	local test_session
	test_session="test-$$-$(date +%s)"

	_test_group_init "$test_session"
	_test_group_signals "$test_session"
	_test_group_mappings
	_test_group_misc "$test_session"

	# Cleanup test session
	local test_file
	test_file=$(_ss_context_file "$test_session")
	rm -f "$test_file" 2>/dev/null || true

	echo ""
	echo "========================================================"
	echo "Results: $passed passed, $failed failed, $total total"

	if [[ "$failed" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'HELP'
session-security-helper.sh — Session-scoped composite security scoring (t1428.3)

Commands:
  init [--session-id ID]                Initialize session context
  record-signal <type> <severity> <detail> [--session-id ID]
                                        Record a security signal
  get-score [--session-id ID]           Get composite security score (integer)
  get-context [--session-id ID]         Get full session context (JSON)
  check-taint [--session-id ID]         Check if session is tainted
                                        Exit 0=tainted, 1=clean
  elevate-tier <domain> [--session-id ID]
                                        Get elevated network tier for domain
  reset [--session-id ID]               Reset session context
  cleanup [--max-age HOURS]             Remove stale session files (default: 24h)
  test                                  Run built-in test suite
  help                                  Show this help

Signal types:
  prompt-injection    Prompt injection pattern detected
  sensitive-file      Sensitive file accessed (credentials, .env, keys)
  sensitive-data      Sensitive data pattern in content
  network-flag        Network tier 4/5 domain accessed
  sandbox-violation   Sandbox boundary violation

Severity weights (summed for composite score):
  LOW=1  MEDIUM=2  HIGH=3  CRITICAL=4

Composite score thresholds:
  0       CLEAN    No security signals
  1-3     LOW      Minor signals, no action needed
  4-7     MEDIUM   Elevated awareness, tainted flag set
  8-15    HIGH     Tainted session, network tier elevation active
  16+     CRITICAL Heavily tainted, only tier 1 network allowed

Tier elevation (when session is tainted):
  MEDIUM:   tier 4 (unknown) → tier 5 (deny)
  HIGH:     tier 3+ → tier 5 (deny)
  CRITICAL: tier 2+ → tier 5 (deny), only tier 1 allowed

Environment:
  SESSION_SECURITY_DIR   Override session context directory
  SESSION_SECURITY_ID    Default session ID (fallback: PID-based)

Examples:
  # Initialize a session
  session-security-helper.sh init --session-id worker-abc123

  # Record that a sensitive file was accessed
  session-security-helper.sh record-signal sensitive-file HIGH \
    "Accessed ~/.config/aidevops/credentials.sh" --session-id worker-abc123

  # Check if session is tainted before network access
  if session-security-helper.sh check-taint --session-id worker-abc123; then
    echo "Session tainted — restricting network access"
  fi

  # Get elevated tier for a domain
  tier=$(session-security-helper.sh elevate-tier api.example.com --session-id worker-abc123)

  # Integration with prompt-guard-helper.sh
  prompt-guard-helper.sh scan "$content" --session-id worker-abc123

  # Clean up old sessions
  session-security-helper.sh cleanup --max-age 12
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	init)
		cmd_init "$@"
		;;
	record-signal | record)
		cmd_record_signal "$@"
		;;
	get-score | score)
		cmd_get_score "$@"
		;;
	get-context | context)
		cmd_get_context "$@"
		;;
	check-taint | taint)
		cmd_check_taint "$@"
		;;
	elevate-tier | elevate)
		cmd_elevate_tier "$@"
		;;
	reset)
		cmd_reset "$@"
		;;
	cleanup)
		cmd_cleanup "$@"
		;;
	test)
		cmd_test
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		log_error "Unknown command: ${cmd}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
