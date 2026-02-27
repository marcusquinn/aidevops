#!/usr/bin/env bash
# session-miner-pulse.sh — Daily self-improvement pulse
#
# Extracts learning signals from coding assistant session data,
# compresses them, and logs TODO suggestions for harness improvements.
#
# Designed for OpenCode now, adaptable to Claude Code or other tools.
#
# Usage:
#   session-miner-pulse.sh                    # Run with defaults
#   session-miner-pulse.sh --since 24h        # Only sessions from last 24h
#   session-miner-pulse.sh --db /path/to.db   # Custom DB path
#   session-miner-pulse.sh --dry-run          # Show what would be logged, don't write
#
# Called by: supervisor pulse (daily), manual invocation
# Output: Suggestions written to stdout. Use with opencode run for analysis.

set -euo pipefail

# --- Configuration ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINER_DIR="${HOME}/.aidevops/.agent-workspace/work/session-miner"
# Shipped with aidevops; copied to workspace on first run
EXTRACTOR_SRC="${SCRIPT_DIR}/session-miner/extract.py"
COMPRESSOR_SRC="${SCRIPT_DIR}/session-miner/compress.py"
EXTRACTOR="${MINER_DIR}/extract.py"
COMPRESSOR="${MINER_DIR}/compress.py"
STATE_FILE="${MINER_DIR}/.last-pulse"
LOCK_FILE="${MINER_DIR}/.pulse.lock"

# Default: OpenCode DB
DEFAULT_DB="${HOME}/.local/share/opencode/opencode.db"

# Minimum interval between pulses (seconds) — default 20 hours
MIN_INTERVAL="${SESSION_MINER_INTERVAL:-72000}"

# --- Functions ---

log_info() {
	local msg="$1"
	echo "[session-miner] ${msg}" >&2
	return 0
}

log_error() {
	local msg="$1"
	echo "[session-miner] ERROR: ${msg}" >&2
	return 0
}

check_lock() {
	if [[ -f "${LOCK_FILE}" ]]; then
		local lock_age
		# Cross-platform file mtime: Linux (stat -c) first, macOS (stat -f) fallback
		local lock_mtime
		lock_mtime=$(stat -c %Y "${LOCK_FILE}" 2>/dev/null || stat -f %m "${LOCK_FILE}" 2>/dev/null || echo 0)
		# Guard: ensure numeric (stat -f on Linux produces multi-line text, not a number)
		[[ "${lock_mtime}" =~ ^[0-9]+$ ]] || lock_mtime=0
		lock_age=$(($(date +%s) - lock_mtime))
		# Stale lock (>1 hour)
		if [[ "${lock_age}" -gt 3600 ]]; then
			log_info "Removing stale lock (${lock_age}s old)"
			rm -f "${LOCK_FILE}"
		else
			log_info "Another pulse is running (lock age: ${lock_age}s). Exiting."
			return 1
		fi
	fi
	echo "$$" >"${LOCK_FILE}"
	return 0
}

release_lock() {
	rm -f "${LOCK_FILE}"
	return 0
}

check_interval() {
	if [[ -f "${STATE_FILE}" ]]; then
		local last_run
		last_run=$(cat "${STATE_FILE}" 2>/dev/null || echo 0)
		local now
		now=$(date +%s)
		local elapsed=$((now - last_run))
		if [[ "${elapsed}" -lt "${MIN_INTERVAL}" ]]; then
			local remaining=$((MIN_INTERVAL - elapsed))
			log_info "Last pulse was ${elapsed}s ago. Next in ${remaining}s. Skipping."
			return 1
		fi
	fi
	return 0
}

record_pulse() {
	mkdir -p "${MINER_DIR}"
	date +%s >"${STATE_FILE}"
	return 0
}

detect_db() {
	local db_path="$1"

	if [[ -n "${db_path}" ]] && [[ -f "${db_path}" ]]; then
		echo "${db_path}"
		return 0
	fi

	# OpenCode
	if [[ -f "${DEFAULT_DB}" ]]; then
		echo "${DEFAULT_DB}"
		return 0
	fi

	# Claude Code (future — placeholder)
	# local claude_db="${HOME}/.claude/sessions.db"
	# if [[ -f "${claude_db}" ]]; then
	#     echo "${claude_db}"
	#     return 0
	# fi

	log_error "No session database found"
	return 1
}

count_new_sessions() {
	local db_path="$1"
	local since_ts="$2"

	local count
	count=$(sqlite3 "${db_path}" "SELECT COUNT(*) FROM session WHERE time_created > ${since_ts};" 2>/dev/null || echo 0)
	echo "${count}"
	return 0
}

run_extraction() {
	local db_path="$1"
	local output_dir="$2"

	if [[ ! -f "${EXTRACTOR}" ]]; then
		log_error "Extractor not found at ${EXTRACTOR}"
		return 1
	fi

	log_info "Running extraction from ${db_path}..."
	python3 "${EXTRACTOR}" --db "${db_path}" --format chunks --output "${output_dir}" 2>&1
	return $?
}

run_compression() {
	local chunks_dir="$1"

	if [[ ! -f "${COMPRESSOR}" ]]; then
		log_error "Compressor not found at ${COMPRESSOR}"
		return 1
	fi

	log_info "Running compression..."
	python3 "${COMPRESSOR}" "${chunks_dir}" 2>&1
	return $?
}

generate_summary() {
	local compressed_file="$1"

	if [[ ! -f "${compressed_file}" ]]; then
		log_error "Compressed signals file not found"
		return 1
	fi

	# Extract key metrics using python for JSON parsing
	python3 -c "
import json, sys
from pathlib import Path

data = json.loads(Path('${compressed_file}').read_text())

steerage = data.get('steerage', {})
errors = data.get('errors', {}).get('patterns', [])
total_steerage = sum(len(v) for v in steerage.values())

# Top error patterns (>10 occurrences)
top_errors = [p for p in errors if p['count'] > 10]
top_errors.sort(key=lambda x: -x['count'])

# Steerage category counts
cat_counts = {k: len(v) for k, v in steerage.items()}

print('## Session Miner Pulse Summary')
print()
print(f'Unique steerage signals: {total_steerage}')
print(f'Error patterns (>10 occurrences): {len(top_errors)}')
print()

if top_errors:
    print('### Top Error Patterns')
    for p in top_errors[:10]:
        recovery = p.get('recovery_patterns', [])
        recovery_str = f' -> recovery: {recovery[0][:60]}' if recovery else ''
        print(f'  {p[\"tool\"]}:{p[\"error_category\"]} ({p[\"count\"]}x){recovery_str}')
    print()

if cat_counts:
    print('### Steerage Categories')
    for cat, count in sorted(cat_counts.items(), key=lambda x: -x[1]):
        print(f'  {cat}: {count}')
    print()

# Flag high-frequency errors not yet in harness
harness_covered = {'edit_stale_read', 'not_read_first', 'edit_mismatch'}
uncovered = [p for p in top_errors if p['error_category'] not in harness_covered]
if uncovered:
    print('### Suggested Harness Improvements')
    for p in uncovered[:5]:
        print(f'  - {p[\"tool\"]}:{p[\"error_category\"]} ({p[\"count\"]}x) — consider adding prevention rule')
    print()
" 2>/dev/null
	return $?
}

# --- Main ---

main() {
	local db_override=""
	local dry_run=false
	local force=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--db)
			db_override="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		--force)
			force=true
			shift
			;;
		--since)
			# Ignored for now — full extraction each time, incremental later
			shift 2
			;;
		*)
			log_error "Unknown argument: $1"
			return 1
			;;
		esac
	done

	# Ensure extractor/compressor are in workspace
	mkdir -p "${MINER_DIR}"
	if [[ -f "${EXTRACTOR_SRC}" ]] && [[ ! -f "${EXTRACTOR}" || "${EXTRACTOR_SRC}" -nt "${EXTRACTOR}" ]]; then
		cp "${EXTRACTOR_SRC}" "${EXTRACTOR}"
	fi
	if [[ -f "${COMPRESSOR_SRC}" ]] && [[ ! -f "${COMPRESSOR}" || "${COMPRESSOR_SRC}" -nt "${COMPRESSOR}" ]]; then
		cp "${COMPRESSOR_SRC}" "${COMPRESSOR}"
	fi

	# Check interval (skip if too recent, unless forced)
	if [[ "${force}" != true ]]; then
		check_interval || return 0
	fi

	# Acquire lock
	check_lock || return 0
	trap release_lock EXIT

	# Find database
	local db_path
	db_path=$(detect_db "${db_override}") || return 1
	log_info "Using database: ${db_path}"

	# Check DB size
	local db_size
	# Cross-platform file size: Linux (stat -c) first, macOS (stat -f) fallback
	db_size=$(stat -c %s "${db_path}" 2>/dev/null || stat -f %z "${db_path}" 2>/dev/null || echo 0)
	# Guard: ensure numeric (stat -f on Linux produces multi-line text, not a number)
	[[ "${db_size}" =~ ^[0-9]+$ ]] || db_size=0
	if [[ "${db_size}" -lt 1000 ]]; then
		log_info "Database too small (${db_size} bytes). Nothing to mine."
		release_lock
		return 0
	fi

	# Create output directory for this run
	local run_ts
	run_ts=$(date +%Y%m%d_%H%M%S)
	local output_dir="${MINER_DIR}/pulse_${run_ts}"
	mkdir -p "${output_dir}"

	# Run extraction
	local extract_output
	extract_output=$(run_extraction "${db_path}" "${output_dir}" 2>&1) || {
		log_error "Extraction failed: ${extract_output}"
		release_lock
		return 1
	}

	# Find the chunks directory (extract.py creates a timestamped subdir)
	local chunks_dir
	chunks_dir=$(find "${output_dir}" -maxdepth 1 -type d -name "chunks_*" | head -1)
	if [[ -z "${chunks_dir}" ]]; then
		log_error "No chunks directory found in ${output_dir}"
		release_lock
		return 1
	fi

	# Run compression
	run_compression "${chunks_dir}" 2>&1 || {
		log_error "Compression failed"
		release_lock
		return 1
	}

	local compressed_file="${MINER_DIR}/compressed_signals.json"

	# Generate summary
	local summary
	summary=$(generate_summary "${compressed_file}" 2>&1)

	if [[ "${dry_run}" == true ]]; then
		echo "--- DRY RUN ---"
		echo "${summary}"
		echo "--- Would log TODO suggestions to relevant repos ---"
	else
		echo "${summary}"
		record_pulse
		log_info "Pulse complete. Output: ${output_dir}"
		log_info "Compressed signals: ${compressed_file}"
		log_info "Run 'opencode run --dir ~/Git/REPO --title \"Session miner analysis\" \"Analyse ${compressed_file} against the current harness and suggest improvements\"' for deep analysis."
	fi

	# Clean up old pulse directories (keep last 7)
	local old_dirs
	old_dirs=$(find "${MINER_DIR}" -maxdepth 1 -type d -name "pulse_*" | sort | head -n -7 2>/dev/null || true)
	if [[ -n "${old_dirs}" ]]; then
		echo "${old_dirs}" | while read -r dir; do
			rm -rf "${dir}"
		done
		log_info "Cleaned up old pulse directories"
	fi

	return 0
}

main "$@"
