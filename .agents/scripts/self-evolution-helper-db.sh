#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Self-Evolution DB -- Database utilities and schema initialization
# =============================================================================
# SQLite wrapper, SQL escaping, gap ID generation, schema init, and time
# utilities for the self-evolution subsystem.
#
# Usage: source "${SCRIPT_DIR}/self-evolution-helper-db.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error, log_success, backup_sqlite_db)
#   - EVOL_MEMORY_BASE_DIR and EVOL_MEMORY_DB must be set by the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SELF_EVOL_DB_LIB_LOADED:-}" ]] && return 0
_SELF_EVOL_DB_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# SQLite wrapper (same as entity/memory system)
#######################################
evol_db() {
	sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA foreign_keys=ON;" "$@"
	return $?
}

#######################################
# SQL-escape a value (double single quotes)
#######################################
evol_sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
	return 0
}

#######################################
# SQL-escape a value for use in LIKE patterns
# Escapes single quotes AND LIKE wildcards (%, _)
# Use with: LIKE '...' ESCAPE '\'
# Currently unused — available for future LIKE-based dedup queries.
#######################################
# shellcheck disable=SC2329  # utility function, may be called by future code
evol_sql_escape_like() {
	local val="$1"
	# Escape backslash first (so it doesn't double-escape later replacements)
	val="${val//\\/\\\\}"
	# Escape LIKE wildcards
	val="${val//%/\\%}"
	val="${val//_/\\_}"
	# Escape single quotes for SQL string literal
	val="${val//\'/\'\'}"
	echo "$val"
	return 0
}

#######################################
# Generate unique gap ID
#######################################
generate_gap_id() {
	echo "gap_$(date +%Y%m%d%H%M%S)_$(head -c 4 /dev/urandom | xxd -p)"
	return 0
}

#######################################
# Initialize/verify capability_gaps table exists
# The table is created by entity-helper.sh init_entity_db, but we
# ensure it exists here for standalone usage.
#######################################
init_evol_db() {
	mkdir -p "$EVOL_MEMORY_BASE_DIR"

	# Set WAL mode, busy timeout, and enable foreign keys for CASCADE
	evol_db "$EVOL_MEMORY_DB" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;" >/dev/null 2>&1

	evol_db "$EVOL_MEMORY_DB" <<'SCHEMA'

-- Capability gaps detected from entity interactions
-- Feeds into self-evolution loop: gap -> TODO -> upgrade -> better service
CREATE TABLE IF NOT EXISTS capability_gaps (
    id TEXT PRIMARY KEY,
    entity_id TEXT DEFAULT NULL,
    description TEXT NOT NULL,
    evidence TEXT DEFAULT '',
    frequency INTEGER DEFAULT 1,
    status TEXT DEFAULT 'detected' CHECK(status IN ('detected', 'todo_created', 'resolved', 'wont_fix')),
    todo_ref TEXT DEFAULT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_capability_gaps_status ON capability_gaps(status);
CREATE INDEX IF NOT EXISTS idx_capability_gaps_entity ON capability_gaps(entity_id);
CREATE INDEX IF NOT EXISTS idx_capability_gaps_frequency ON capability_gaps(frequency DESC);

-- Gap evidence links — maps gaps to the specific interactions that revealed them
-- Provides the full evidence trail: gap → interaction IDs → raw messages
CREATE TABLE IF NOT EXISTS gap_evidence (
    gap_id TEXT NOT NULL,
    interaction_id TEXT NOT NULL,
    relevance TEXT DEFAULT 'primary',
    added_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (gap_id, interaction_id),
    FOREIGN KEY (gap_id) REFERENCES capability_gaps(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_gap_evidence_gap ON gap_evidence(gap_id);
CREATE INDEX IF NOT EXISTS idx_gap_evidence_interaction ON gap_evidence(interaction_id);

SCHEMA

	return 0
}

#######################################
# Get ISO timestamp for N hours ago
#######################################
hours_ago_iso() {
	local hours="$1"
	if [[ "$(uname)" == "Darwin" ]]; then
		date -u -v-"${hours}"H +"%Y-%m-%dT%H:%M:%SZ"
	else
		date -u -d "${hours} hours ago" +"%Y-%m-%dT%H:%M:%SZ"
	fi
	return 0
}
