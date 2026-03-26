#!/usr/bin/env bash
# audit-log-helper.sh — Tamper-evident audit logging with hash chaining (t1412.8)
# Commands: log | verify | tail | status | rotate | help
# Docs: tools/security/tamper-evident-audit.md
#
# Append-only JSONL log with SHA-256 hash chaining. Each entry includes the
# hash of the previous entry, creating a chain. Modifying or deleting any
# entry breaks the chain, making tampering detectable via `verify`.
#
# Event types (16 — must match AUDIT_EVENT_TYPES array below):
#   worker.dispatch    — Worker spawned by pulse/supervisor
#   worker.complete    — Worker finished (success or failure)
#   worker.error       — Worker encountered an error
#   credential.access  — Credential read/write via gopass or credentials.sh
#   credential.rotate  — Credential rotation
#   config.change      — Framework config modification
#   config.deploy      — Config deployment (setup.sh)
#   security.event     — Prompt injection detected, verification triggered
#   security.injection — Prompt injection detected
#   security.scan      — Security scan performed
#   operation.verify   — High-stakes operation verified
#   operation.block    — High-stakes operation blocked
#   system.startup     — Framework startup
#   system.update      — Framework update
#   system.rotate      — Audit log rotation
#   testing.runtime    — Runtime test execution (pass/fail/skip with structured detail)
#
# Usage:
#   audit-log-helper.sh log <event-type> <message> [--detail key=value ...]
#   audit-log-helper.sh verify [--quiet]
#   audit-log-helper.sh tail [N]
#   audit-log-helper.sh status
#   audit-log-helper.sh rotate [--max-size MB]
#   audit-log-helper.sh help
#
# Environment:
#   AUDIT_LOG_DIR    Override log directory (default: ~/.aidevops/.agent-workspace/observability)
#   AUDIT_LOG_FILE   Override log file path (default: $AUDIT_LOG_DIR/audit.jsonl)
#   AUDIT_QUIET      Suppress informational stderr output when "true"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" || true
init_log_file || true

# =============================================================================
# Constants
# =============================================================================

readonly AUDIT_VERSION="1.0.0"
readonly AUDIT_LOG_DIR_DEFAULT="${HOME}/.aidevops/.agent-workspace/observability"
readonly AUDIT_LOG_FILE_DEFAULT="audit.jsonl"
readonly AUDIT_GENESIS_HASH="0000000000000000000000000000000000000000000000000000000000000000"
readonly AUDIT_MAX_MESSAGE_LEN=4096
readonly AUDIT_MAX_DETAIL_LEN=8192
readonly AUDIT_DEFAULT_ROTATE_MB=50

# Valid event types (prefix-based hierarchy)
readonly -a AUDIT_EVENT_TYPES=(
	"worker.dispatch"
	"worker.complete"
	"worker.error"
	"credential.access"
	"credential.rotate"
	"config.change"
	"config.deploy"
	"security.event"
	"security.injection"
	"security.scan"
	"operation.verify"
	"operation.block"
	"system.startup"
	"system.update"
	"system.rotate"
	"testing.runtime"
)

# =============================================================================
# Internal helpers
# =============================================================================

# Get the resolved audit log file path.
# Output: absolute path on stdout
_audit_log_path() {
	local dir="${AUDIT_LOG_DIR:-${AUDIT_LOG_DIR_DEFAULT}}"
	local file="${AUDIT_LOG_FILE:-${dir}/${AUDIT_LOG_FILE_DEFAULT}}"
	echo "$file"
	return 0
}

# Ensure the audit log directory and file exist with correct permissions.
# The log file is created with 0600 (owner read/write only).
_audit_ensure_log() {
	local log_file
	log_file="$(_audit_log_path)"
	local log_dir
	log_dir="$(dirname "$log_file")"

	if [[ ! -d "$log_dir" ]]; then
		mkdir -p "$log_dir" || true
		chmod 700 "$log_dir" || _audit_warn "Could not set log directory permissions to 700: $log_dir"
	fi

	if [[ ! -f "$log_file" ]]; then
		: >"$log_file"
		chmod 600 "$log_file" || _audit_warn "Could not set log file permissions to 600: $log_file"
	fi

	return 0
}

# Compute SHA-256 hash of a string.
# Arguments: $1 — string to hash
# Output: hex digest on stdout
_audit_sha256() {
	local input="$1"
	# Use shasum (macOS/Linux) or sha256sum (Linux)
	if command -v shasum &>/dev/null; then
		printf '%s' "$input" | shasum -a 256 | cut -d' ' -f1
	elif command -v sha256sum &>/dev/null; then
		printf '%s' "$input" | sha256sum | cut -d' ' -f1
	else
		print_shared_error "No SHA-256 tool found (need shasum or sha256sum)" 2>/dev/null ||
			echo "[ERROR] No SHA-256 tool found" >&2
		return 1
	fi
	return 0
}

# Get the hash of the last entry in the audit log.
# Output: hash on stdout (genesis hash if log is empty)
_audit_last_hash() {
	local log_file
	log_file="$(_audit_log_path)"

	if [[ ! -f "$log_file" ]] || [[ ! -s "$log_file" ]]; then
		echo "$AUDIT_GENESIS_HASH"
		return 0
	fi

	# Extract the hash field from the last line
	local last_line
	last_line="$(tail -1 "$log_file" 2>/dev/null || echo "")"

	if [[ -z "$last_line" ]]; then
		echo "$AUDIT_GENESIS_HASH"
		return 0
	fi

	# Parse hash from JSON — use jq if available, fallback to sed
	local hash
	if command -v jq &>/dev/null; then
		hash="$(echo "$last_line" | jq -r '.hash // empty' 2>/dev/null || echo "")"
	else
		# Fallback: POSIX sed extraction (no grep -P, works on macOS)
		hash="$(echo "$last_line" | sed -n 's/.*,"hash":"\([a-f0-9]\{64\}\)".*/\1/p')"
	fi

	if [[ -z "$hash" ]]; then
		echo "$AUDIT_GENESIS_HASH"
		return 0
	fi

	echo "$hash"
	return 0
}

# Validate an event type against the AUDIT_EVENT_TYPES allowlist.
# Arguments: $1 — event type string (e.g., "worker.dispatch")
# Returns: 0 if valid, 1 if invalid
_audit_validate_event_type() {
	local event_type="$1"

	local valid_type
	for valid_type in "${AUDIT_EVENT_TYPES[@]}"; do
		if [[ "$event_type" == "$valid_type" ]]; then
			return 0
		fi
	done

	return 1
}

# Escape a string for safe JSON embedding.
# Handles: backslash, double-quote, newline, tab, carriage return, and
# other control characters (0x00-0x1F).
# Arguments: $1 — string to escape
# Output: escaped string on stdout
_audit_json_escape() {
	local input="$1"
	# Use jq if available for reliable escaping (preferred path)
	if command -v jq &>/dev/null; then
		printf '%s' "$input" | jq -Rs '.' | sed 's/^"//;s/"$//'
		return 0
	fi
	# Fallback: manual escaping for common characters.
	# Note: this does not handle all Unicode edge cases — jq is strongly
	# preferred. This fallback exists only for minimal environments.
	local escaped="$input"
	escaped="${escaped//\\/\\\\}"
	escaped="${escaped//\"/\\\"}"
	escaped="${escaped//$'\n'/\\n}"
	escaped="${escaped//$'\t'/\\t}"
	escaped="${escaped//$'\r'/\\r}"
	# Strip remaining control characters (0x00-0x1F except those already handled)
	escaped="$(printf '%s' "$escaped" | tr -d '\000-\010\013\014\016-\037')"
	echo "$escaped"
	return 0
}

# Print informational message to stderr (suppressed when AUDIT_QUIET=true).
# Arguments: $1 — message string
_audit_info() {
	local msg="$1"
	if [[ "${AUDIT_QUIET:-false}" != "true" ]]; then
		echo -e "${GREEN:-}[AUDIT]${NC:-} $msg" >&2
	fi
	return 0
}

# Print warning message to stderr (always shown).
# Arguments: $1 — message string
_audit_warn() {
	local msg="$1"
	echo -e "${YELLOW:-}[AUDIT WARN]${NC:-} $msg" >&2
	return 0
}

# Print error message to stderr (always shown).
# Arguments: $1 — message string
_audit_error() {
	local msg="$1"
	echo -e "${RED:-}[AUDIT ERROR]${NC:-} $msg" >&2
	return 0
}

# =============================================================================
# Commands
# =============================================================================

# Parse --detail key=value pairs from argument list.
# Arguments: $@ — remaining args after event_type and message have been shifted
# Output: detail_json on stdout (always valid JSON object)
# Returns: 0 on success, 1 on parse error
_audit_parse_details() {
	local detail_pairs=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--detail)
			if [[ $# -lt 2 ]]; then
				_audit_error "--detail requires a key=value argument"
				return 1
			fi
			local kv="$2"
			local key="${kv%%=*}"
			local value="${kv#*=}"
			if [[ "$key" == "$kv" ]]; then
				_audit_error "Invalid --detail format: $kv (expected key=value)"
				return 1
			fi
			local escaped_key escaped_value
			escaped_key="$(_audit_json_escape "$key")"
			escaped_value="$(_audit_json_escape "$value")"
			if [[ -z "$detail_pairs" ]]; then
				detail_pairs="\"${escaped_key}\":\"${escaped_value}\""
			else
				detail_pairs="${detail_pairs},\"${escaped_key}\":\"${escaped_value}\""
			fi
			shift 2
			;;
		*)
			_audit_warn "Unknown argument: $1 (ignored)"
			shift
			;;
		esac
	done

	local detail_json="{}"
	if [[ -n "$detail_pairs" ]]; then
		detail_json="{${detail_pairs}}"
	fi
	if [[ ${#detail_json} -gt $AUDIT_MAX_DETAIL_LEN ]]; then
		detail_json='{"error":"detail_truncated"}'
	fi

	echo "$detail_json"
	return 0
}

# Build a JSON entry (without the hash field) from its components.
# Arguments: $1=seq $2=ts $3=event_type $4=message $5=detail_json $6=actor $7=host $8=prev_hash
# Output: compact JSON on stdout
_audit_build_entry_no_hash() {
	local seq="$1" ts="$2" event_type="$3" message="$4"
	local detail_json="$5" actor="$6" host="$7" prev_hash="$8"

	if command -v jq &>/dev/null; then
		jq -c -n \
			--argjson seq "${seq}" \
			--arg ts "${ts}" \
			--arg type "${event_type}" \
			--arg msg "${message}" \
			--argjson detail "${detail_json}" \
			--arg actor "${actor}" \
			--arg host "${host}" \
			--arg prev_hash "${prev_hash}" \
			'{seq: $seq, ts: $ts, type: $type, msg: $msg, detail: $detail, actor: $actor, host: $host, prev_hash: $prev_hash}'
	else
		local escaped_msg escaped_actor escaped_host
		escaped_msg="$(_audit_json_escape "$message")"
		escaped_actor="$(_audit_json_escape "$actor")"
		escaped_host="$(_audit_json_escape "$host")"
		echo "{\"seq\":${seq},\"ts\":\"${ts}\",\"type\":\"${event_type}\",\"msg\":\"${escaped_msg}\",\"detail\":${detail_json},\"actor\":\"${escaped_actor}\",\"host\":\"${escaped_host}\",\"prev_hash\":\"${prev_hash}\"}"
	fi
	return 0
}

# Append a single audit entry to the log under an flock-serialised lock.
# Handles: seq allocation, prev_hash lookup, entry construction, hash, append.
# Arguments: $1=log_file $2=event_type $3=message $4=detail_json $5=ts $6=actor $7=host
# Returns: 0 on success, 1 on lock failure
_audit_locked_append() {
	local log_file="$1" event_type="$2" message="$3" detail_json="$4"
	local ts="$5" actor="$6" host="$7"

	local lock_file="${log_file}.lock"
	# Serialize the read-modify-write path with flock to prevent concurrent
	# writers from duplicating sequence numbers or breaking the hash chain.
	# Uses fd 200 for the lock file; released automatically when fd is closed.
	if command -v flock &>/dev/null; then
		exec 200>"$lock_file"
		if ! flock -w 10 200; then
			_audit_error "Could not acquire audit log lock after 10s"
			exec 200>&-
			return 1
		fi
	fi
	# Note: if flock is unavailable (e.g., macOS without util-linux), we proceed
	# without locking — single-writer scenarios are still safe.

	local seq
	if [[ -s "$log_file" ]]; then
		seq="$(wc -l <"$log_file" | tr -d ' ')"
		seq=$((seq + 1))
	else
		seq=1
	fi

	local prev_hash
	prev_hash="$(_audit_last_hash)"

	local entry_no_hash
	entry_no_hash="$(_audit_build_entry_no_hash \
		"$seq" "$ts" "$event_type" "$message" "$detail_json" "$actor" "$host" "$prev_hash")"

	local entry_hash
	entry_hash="$(_audit_sha256 "$entry_no_hash")"

	local entry
	if command -v jq &>/dev/null; then
		entry=$(echo "$entry_no_hash" | jq -c --arg hash "$entry_hash" '. + {hash: $hash}')
	else
		# Reconstruct with hash appended (fallback — jq strongly preferred)
		# Strip trailing } and append hash field
		entry="${entry_no_hash%\}},\"hash\":\"${entry_hash}\"}"
	fi

	echo "$entry" >>"$log_file"

	if command -v flock &>/dev/null; then
		exec 200>&-
	fi

	echo "$seq"
	return 0
}

# Log a security-sensitive event with hash chaining.
#
# Arguments:
#   $1 — event type (e.g., "worker.dispatch")
#   $2 — human-readable message
#   $3+ — optional --detail key=value pairs
#
# The entry is a JSON object with fields:
#   seq       — monotonic sequence number
#   ts        — ISO 8601 timestamp
#   type      — event type
#   msg       — message
#   detail    — optional key-value object
#   actor     — USER or session ID
#   host      — hostname
#   prev_hash — SHA-256 of the previous entry's JSON (or genesis hash)
#   hash      — SHA-256 of this entry (computed over all fields except hash)
#
# The hash chain works as follows:
#   entry_N.prev_hash = entry_(N-1).hash
#   entry_N.hash = SHA-256(entry_N without the hash field)
#
# Tampering with any entry breaks the chain because:
#   - Modifying entry_N changes its hash
#   - entry_(N+1).prev_hash no longer matches entry_N.hash
cmd_log() {
	local event_type="${1:-}"
	local message="${2:-}"

	if [[ -z "$event_type" ]]; then
		_audit_error "Event type required. Usage: audit-log-helper.sh log <event-type> <message>"
		return 1
	fi

	if ! _audit_validate_event_type "$event_type"; then
		_audit_error "Invalid event type: $event_type"
		echo "Valid types: ${AUDIT_EVENT_TYPES[*]}" >&2
		return 1
	fi

	if [[ -z "$message" ]]; then
		_audit_error "Message required. Usage: audit-log-helper.sh log <event-type> <message>"
		return 1
	fi

	if [[ ${#message} -gt $AUDIT_MAX_MESSAGE_LEN ]]; then
		message="${message:0:$AUDIT_MAX_MESSAGE_LEN}...[truncated]"
	fi

	shift 2

	local detail_json
	detail_json="$(_audit_parse_details "$@")" || return 1

	_audit_ensure_log

	local log_file
	log_file="$(_audit_log_path)"

	local ts actor host
	ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"
	actor="${AIDEVOPS_SESSION_ID:-${USER:-unknown}}"
	host="$(hostname -s 2>/dev/null || echo "unknown")"

	local seq
	seq="$(_audit_locked_append \
		"$log_file" "$event_type" "$message" "$detail_json" "$ts" "$actor" "$host")" || return 1

	_audit_info "Logged ${event_type} (seq=${seq})"

	return 0
}

# Verify a single audit log entry against the expected previous hash.
# Arguments: $1=line_num $2=line $3=expected_prev_hash
# Output: next expected_prev_hash on stdout (the stored hash of this entry)
# Returns: 0 if entry is valid, number of errors found (1 or 2) otherwise
_audit_verify_entry() {
	local line_num="$1" line="$2" expected_prev_hash="$3"

	# Check 1: Valid JSON
	if command -v jq &>/dev/null && ! echo "$line" | jq -e '.' &>/dev/null; then
		_audit_error "Entry ${line_num}: Invalid JSON"
		return 1
	fi

	# Extract fields
	local stored_hash stored_prev_hash entry_no_hash_json
	if command -v jq &>/dev/null; then
		stored_hash="$(echo "$line" | jq -r '.hash // empty')"
		stored_prev_hash="$(echo "$line" | jq -r '.prev_hash // empty')"
		entry_no_hash_json="$(echo "$line" | jq -c 'del(.hash)')"
	else
		# Fallback: sed-based extraction (POSIX-compatible, no grep -P)
		stored_hash="$(echo "$line" | sed -n 's/.*,"hash":"\([a-f0-9]\{64\}\)".*/\1/p')"
		stored_prev_hash="$(echo "$line" | sed -n 's/.*"prev_hash":"\([a-f0-9]\{64\}\)".*/\1/p')"
		# Remove the trailing ,"hash":"..." anchored to end of line
		entry_no_hash_json="$(echo "$line" | sed 's/,"hash":"[a-f0-9]\{64\}"}$/}/')"
	fi

	if [[ -z "$stored_hash" ]]; then
		_audit_error "Entry ${line_num}: Missing hash field"
		return 1
	fi

	local entry_errors=0

	# Check 2: prev_hash matches expected
	if [[ "$stored_prev_hash" != "$expected_prev_hash" ]]; then
		_audit_error "Entry ${line_num}: Chain broken — prev_hash mismatch"
		_audit_error "  Expected: ${expected_prev_hash}"
		_audit_error "  Found:    ${stored_prev_hash}"
		entry_errors=$((entry_errors + 1))
	fi

	# Check 3: hash matches content
	local computed_hash
	computed_hash="$(_audit_sha256 "$entry_no_hash_json")"
	if [[ "$computed_hash" != "$stored_hash" ]]; then
		_audit_error "Entry ${line_num}: Hash mismatch — entry has been tampered with"
		_audit_error "  Stored:   ${stored_hash}"
		_audit_error "  Computed: ${computed_hash}"
		entry_errors=$((entry_errors + 1))
	fi

	# Emit the stored hash so the caller can advance expected_prev_hash
	echo "$stored_hash"
	return "$entry_errors"
}

# Verify the integrity of the audit log hash chain.
#
# Checks:
#   1. Each entry is valid JSON
#   2. Each entry's hash matches SHA-256(entry without hash field)
#   3. Each entry's prev_hash matches the previous entry's hash
#   4. First entry's prev_hash is the genesis hash
#
# Arguments:
#   --quiet — suppress per-entry output, only show result
#
# Returns: 0 if chain is valid, 1 if tampered/broken
cmd_verify() {
	local quiet="false"
	if [[ "${1:-}" == "--quiet" ]]; then
		quiet="true"
	fi

	local log_file
	log_file="$(_audit_log_path)"

	if [[ ! -f "$log_file" ]]; then
		_audit_info "No audit log found — nothing to verify"
		return 0
	fi

	if [[ ! -s "$log_file" ]]; then
		_audit_info "Audit log is empty — nothing to verify"
		return 0
	fi

	local total_lines
	total_lines="$(wc -l <"$log_file" | tr -d ' ')"

	if [[ "$quiet" != "true" ]]; then
		_audit_info "Verifying ${total_lines} entries..."
	fi

	local line_num=0
	local expected_prev_hash="$AUDIT_GENESIS_HASH"
	local errors=0
	local line

	while IFS= read -r line; do
		line_num=$((line_num + 1))

		if [[ -z "$line" ]]; then
			continue
		fi

		local entry_hash
		entry_hash="$(_audit_verify_entry "$line_num" "$line" "$expected_prev_hash")"
		local entry_errors=$?
		errors=$((errors + entry_errors))

		# Advance chain only when the entry itself was parseable (hash non-empty)
		if [[ -n "$entry_hash" ]]; then
			expected_prev_hash="$entry_hash"
		fi

	done <"$log_file"

	if [[ $errors -gt 0 ]]; then
		_audit_error "Verification FAILED: ${errors} error(s) in ${total_lines} entries"
		return 1
	fi

	if [[ "$quiet" != "true" ]]; then
		_audit_info "Verification PASSED: ${total_lines} entries, chain intact"
	fi

	return 0
}

# Show the last N entries from the audit log.
# Arguments: $1 — number of entries (default: 10)
cmd_tail() {
	local count="${1:-10}"
	# Validate count is a positive integer (prevent command injection via tail)
	if [[ ! "$count" =~ ^[0-9]+$ ]]; then
		_audit_error "Invalid count: $count (must be a positive integer)"
		return 1
	fi
	local log_file
	log_file="$(_audit_log_path)"

	if [[ ! -f "$log_file" ]] || [[ ! -s "$log_file" ]]; then
		_audit_info "Audit log is empty"
		return 0
	fi

	if command -v jq &>/dev/null; then
		tail -"${count}" "$log_file" | jq -c '{seq, ts, type, msg, actor}'
	else
		tail -"${count}" "$log_file"
	fi

	return 0
}

# Show audit log status and statistics.
cmd_status() {
	local log_file
	log_file="$(_audit_log_path)"

	echo "Audit Log Status"
	echo "================"
	echo "Version:  ${AUDIT_VERSION}"
	echo "Log file: ${log_file}"

	if [[ ! -f "$log_file" ]]; then
		echo "Status:   No log file (will be created on first event)"
		return 0
	fi

	local size_bytes
	size_bytes="$(wc -c <"$log_file" | tr -d ' ')"
	local size_human
	if [[ $size_bytes -gt 1048576 ]]; then
		size_human="$((size_bytes / 1048576)) MB"
	elif [[ $size_bytes -gt 1024 ]]; then
		size_human="$((size_bytes / 1024)) KB"
	else
		size_human="${size_bytes} bytes"
	fi

	local entry_count
	entry_count="$(wc -l <"$log_file" | tr -d ' ')"

	echo "Entries:  ${entry_count}"
	echo "Size:     ${size_human}"

	# Show first and last timestamps
	if [[ $entry_count -gt 0 ]]; then
		local first_ts last_ts
		if command -v jq &>/dev/null; then
			first_ts="$(head -1 "$log_file" | jq -r '.ts // "unknown"' 2>/dev/null || echo "unknown")"
			last_ts="$(tail -1 "$log_file" | jq -r '.ts // "unknown"' 2>/dev/null || echo "unknown")"
		else
			first_ts="unknown"
			last_ts="unknown"
		fi
		echo "First:    ${first_ts}"
		echo "Last:     ${last_ts}"
	fi

	# Quick chain verification
	echo ""
	if cmd_verify --quiet 2>/dev/null; then
		echo -e "Chain:    ${GREEN:-}INTACT${NC:-}"
	else
		echo -e "Chain:    ${RED:-}BROKEN${NC:-} — run 'audit-log-helper.sh verify' for details"
	fi

	# Event type breakdown
	if [[ $entry_count -gt 0 ]] && command -v jq &>/dev/null; then
		echo ""
		echo "Event breakdown:"
		jq -r '.type' "$log_file" 2>/dev/null | sort | uniq -c | sort -rn | while IFS= read -r line; do
			echo "  $line"
		done
	fi

	return 0
}

# Rotate the audit log when it exceeds a size threshold.
# The rotated file is renamed with a timestamp suffix.
# A rotation event is logged in the new log file.
#
# Arguments:
#   --max-size MB — size threshold in megabytes (default: 50)
cmd_rotate() {
	local max_size_mb="$AUDIT_DEFAULT_ROTATE_MB"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--max-size)
			if [[ $# -lt 2 ]]; then
				_audit_error "--max-size requires a numeric MB value"
				return 1
			fi
			max_size_mb="$2"
			# Validate max_size_mb is a positive integer (prevent arithmetic injection)
			if [[ ! "$max_size_mb" =~ ^[0-9]+$ ]]; then
				_audit_error "Invalid max-size: $max_size_mb (must be a positive integer)"
				return 1
			fi
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	local log_file
	log_file="$(_audit_log_path)"

	if [[ ! -f "$log_file" ]]; then
		_audit_info "No audit log to rotate"
		return 0
	fi

	local size_bytes
	size_bytes="$(wc -c <"$log_file" | tr -d ' ')"
	local max_size_bytes=$((max_size_mb * 1048576))

	if [[ $size_bytes -lt $max_size_bytes ]]; then
		local size_mb=$((size_bytes / 1048576))
		_audit_info "Log size (${size_mb}MB) below threshold (${max_size_mb}MB) — no rotation needed"
		return 0
	fi

	# Verify chain before rotation
	if ! cmd_verify --quiet 2>/dev/null; then
		_audit_warn "Chain verification failed before rotation — rotating anyway but chain is already broken"
	fi

	# Rotate: rename with timestamp
	local rotate_ts
	rotate_ts="$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%dT%H%M%SZ')"
	local rotated_file="${log_file%.jsonl}.${rotate_ts}.jsonl"

	# Capture the last entry's hash before moving — this creates a cryptographic
	# link from the new log segment back to the rotated one. Without this, an
	# attacker could swap or delete rotated segments undetectably.
	local prev_segment_hash
	prev_segment_hash="$(_audit_last_hash)"

	mv "$log_file" "$rotated_file"
	chmod 400 "$rotated_file" || _audit_warn "Could not set rotated log permissions to 400: $rotated_file"

	_audit_info "Rotated to ${rotated_file}"

	# Log rotation event in the new (empty) log file with cryptographic handoff
	local rotated_entries
	rotated_entries="$(wc -l <"$rotated_file" | tr -d ' ')"
	cmd_log "system.rotate" "Audit log rotated" \
		--detail "rotated_file=${rotated_file}" \
		--detail "entries=${rotated_entries}" \
		--detail "size_bytes=${size_bytes}" \
		--detail "prev_segment_hash=${prev_segment_hash}"

	return 0
}

# Show help text.
cmd_help() {
	cat <<'HELP'
audit-log-helper.sh — Tamper-evident audit logging with hash chaining (t1412.8)

Each log entry includes a SHA-256 hash of the previous entry, creating a
chain. Modifying or deleting any entry breaks the chain, detectable via
the 'verify' command.

Commands:
  log <type> <message> [--detail k=v ...]   Append an audit event
  verify [--quiet]                           Verify hash chain integrity
  tail [N]                                   Show last N entries (default: 10)
  status                                     Show log status and statistics
  rotate [--max-size MB]                     Rotate log if over size threshold
  help                                       Show this help

Event types:
  worker.dispatch     Worker spawned by pulse/supervisor
  worker.complete     Worker finished (success or failure)
  worker.error        Worker encountered an error
  credential.access   Credential read/write
  credential.rotate   Credential rotation
  config.change       Framework config modification
  config.deploy       Config deployment (setup.sh)
  security.event      Security event (generic)
  security.injection  Prompt injection detected
  security.scan       Security scan performed
  operation.verify    High-stakes operation verified
  operation.block     High-stakes operation blocked
  system.startup      Framework startup
  system.update       Framework update
  system.rotate       Audit log rotation
  testing.runtime     Runtime test execution (pass/fail/skip)

Examples:
  # Log a worker dispatch
  audit-log-helper.sh log worker.dispatch "Dispatched worker for issue #42" \
    --detail repo=myproject --detail task_id=t1412

  # Log a credential access
  audit-log-helper.sh log credential.access "Read GitHub token for dispatch" \
    --detail scope=repo:read

  # Verify the audit chain
  audit-log-helper.sh verify

  # Show recent events
  audit-log-helper.sh tail 20

  # Check status
  audit-log-helper.sh status

Environment:
  AUDIT_LOG_DIR    Override log directory
  AUDIT_LOG_FILE   Override log file path
  AUDIT_QUIET      Suppress informational output ("true")
HELP
	return 0
}

# =============================================================================
# Main dispatch
# =============================================================================

# Entry point — dispatch to subcommand based on first argument.
# Arguments: $1 — command name (log|verify|tail|status|rotate|help)
#            $2+ — command-specific arguments
main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	log)
		cmd_log "$@"
		;;
	verify)
		cmd_verify "$@"
		;;
	tail)
		cmd_tail "$@"
		;;
	status)
		cmd_status "$@"
		;;
	rotate)
		cmd_rotate "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		_audit_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
