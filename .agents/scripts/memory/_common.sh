#!/usr/bin/env bash
# memory/_common.sh - Shared utilities for memory-helper modules
# Sourced by memory-helper.sh; do not execute directly.
#
# Provides: logging, DB wrapper, namespace resolution, init_db, migrate_db,
#           format helpers, dedup helpers, auto-prune, ID generation

# Include guard
[[ -n "${_MEMORY_COMMON_LOADED:-}" ]] && return 0
_MEMORY_COMMON_LOADED=1

#######################################
# Print colored message
#######################################
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

#######################################
# Return the global (non-namespaced) memory DB path
#######################################
global_db_path() {
	echo "$MEMORY_BASE_DIR/memory.db"
	return 0
}

#######################################
# SQLite wrapper: sets busy_timeout on every connection (t135.3)
# busy_timeout is per-connection and must be set each time
#######################################
db() {
	sqlite3 -cmd ".timeout 5000" "$@"
}

#######################################
# Resolve namespace to memory directory and DB path
# Sets MEMORY_DIR and MEMORY_DB globals
#######################################
resolve_namespace() {
	local namespace="$1"

	if [[ -z "$namespace" ]]; then
		MEMORY_DIR="$MEMORY_BASE_DIR"
		MEMORY_DB="$MEMORY_DIR/memory.db"
		return 0
	fi

	# Validate namespace name (same rules as runner names)
	if [[ ! "$namespace" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
		log_error "Invalid namespace: '$namespace' (must start with letter, contain only alphanumeric, hyphens, underscores)"
		return 1
	fi
	if [[ ${#namespace} -gt 40 ]]; then
		log_error "Namespace name too long: '$namespace' (max 40 characters)"
		return 1
	fi

	MEMORY_NAMESPACE="$namespace"
	MEMORY_DIR="$MEMORY_BASE_DIR/namespaces/$namespace"
	MEMORY_DB="$MEMORY_DIR/memory.db"
	return 0
}

#######################################
# Migrate existing database to new schema
# With backup-before-modify pattern (t188)
# Note: t311.4 resolved duplicate migrate_db() — this is the single
# authoritative version with t188 backup/rollback safety.
#######################################
migrate_db() {
	# Check if event_date column exists in FTS5 table
	# FTS5 tables don't support ALTER TABLE, so we check via pragma
	local has_event_date
	has_event_date=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM pragma_table_info('learnings') WHERE name='event_date';" 2>/dev/null || echo "0")

	if [[ "$has_event_date" == "0" ]]; then
		log_info "Migrating database to add event_date and relations..."

		# Backup before destructive FTS5 table recreation (t188)
		local migrate_backup
		migrate_backup=$(backup_sqlite_db "$MEMORY_DB" "pre-migrate-event-date")
		if [[ $? -ne 0 || -z "$migrate_backup" ]]; then
			log_error "Backup failed for memory migration — aborting"
			return 1
		fi
		log_info "Pre-migration backup: $migrate_backup"

		# Get pre-migration row count for verification
		local pre_count
		pre_count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")

		db "$MEMORY_DB" <<'EOF'
-- Create new FTS5 table with event_date
CREATE VIRTUAL TABLE IF NOT EXISTS learnings_new USING fts5(
    id UNINDEXED,
    session_id UNINDEXED,
    content,
    type,
    tags,
    confidence UNINDEXED,
    created_at UNINDEXED,
    event_date UNINDEXED,
    project_path UNINDEXED,
    source UNINDEXED,
    tokenize='porter unicode61'
);

-- Copy existing data (event_date defaults to created_at for existing entries)
INSERT INTO learnings_new (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source)
SELECT id, session_id, content, type, tags, confidence, created_at, created_at, project_path, source FROM learnings;

-- Drop old table and rename new
DROP TABLE learnings;
ALTER TABLE learnings_new RENAME TO learnings;

-- Create relations table if not exists
CREATE TABLE IF NOT EXISTS learning_relations (
    id TEXT PRIMARY KEY,
    supersedes_id TEXT,
    relation_type TEXT CHECK(relation_type IN ('updates', 'extends', 'derives')),
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
EOF

		# Verify row counts after migration (t188)
		local post_count
		post_count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
		if [[ "$post_count" -lt "$pre_count" ]]; then
			log_error "Memory migration FAILED: row count decreased ($pre_count -> $post_count) — rolling back"
			rollback_sqlite_db "$MEMORY_DB" "$migrate_backup"
			return 1
		fi

		log_success "Database migrated successfully ($pre_count rows preserved)"
		cleanup_sqlite_backups "$MEMORY_DB" 5
	fi

	# Ensure relations table exists (for databases created before this feature)
	db "$MEMORY_DB" <<'EOF'
CREATE TABLE IF NOT EXISTS learning_relations (
    id TEXT PRIMARY KEY,
    supersedes_id TEXT,
    relation_type TEXT CHECK(relation_type IN ('updates', 'extends', 'derives')),
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
EOF

	# Add auto_captured column to learning_access if missing (t058 migration)
	local has_auto_captured
	has_auto_captured=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM pragma_table_info('learning_access') WHERE name='auto_captured';" 2>/dev/null || echo "0")
	if [[ "$has_auto_captured" == "0" ]]; then
		db "$MEMORY_DB" "ALTER TABLE learning_access ADD COLUMN auto_captured INTEGER DEFAULT 0;" || echo "[WARN] Failed to add auto_captured column (may already exist)" >&2
	fi

	# Add graduated_at column to learning_access if missing (t184 migration)
	local has_graduated
	has_graduated=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM pragma_table_info('learning_access') WHERE name='graduated_at';" 2>/dev/null || echo "0")
	if [[ "$has_graduated" == "0" ]]; then
		db "$MEMORY_DB" "ALTER TABLE learning_access ADD COLUMN graduated_at TEXT DEFAULT NULL;" || echo "[WARN] Failed to add graduated_at column (may already exist)" >&2
	fi

	return 0
}

#######################################
# Format JSON results as text (jq fallback)
# Uses jq if available, otherwise basic parsing
#######################################
format_results_text() {
	local input
	input=$(cat)

	if [[ -z "$input" || "$input" == "[]" ]]; then
		return 0
	fi

	if command -v jq &>/dev/null; then
		echo "$input" | jq -r '.[] | "[\(.type)] (\(.confidence)) - Score: \(.score // "N/A" | tostring | .[0:6])\n  \(.content)\n  Tags: \(.tags)\n  Created: \(.created_at) | Accessed: \(.access_count)x\n"' 2>/dev/null
	else
		# Basic fallback without jq - parse JSON manually
		echo "$input" | sed 's/},{/}\n{/g' | while read -r line; do
			local type content tags created access_count
			type=$(echo "$line" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
			content=$(echo "$line" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | head -c 100)
			tags=$(echo "$line" | sed -n 's/.*"tags":"\([^"]*\)".*/\1/p')
			created=$(echo "$line" | sed -n 's/.*"created_at":"\([^"]*\)".*/\1/p')
			access_count=$(echo "$line" | sed -n 's/.*"access_count":\([0-9]*\).*/\1/p')
			[[ -n "$type" ]] && echo "[$type] $content..."
			[[ -n "$tags" ]] && echo "  Tags: $tags | Created: $created | Accessed: ${access_count:-0}x"
			echo ""
		done
	fi
}

#######################################
# Extract IDs from JSON (jq fallback)
#######################################
extract_ids_from_json() {
	local input
	input=$(cat)

	if command -v jq &>/dev/null; then
		echo "$input" | jq -r '.[].id' 2>/dev/null
	else
		# Basic fallback - extract id values
		echo "$input" | grep -o '"id":"[^"]*"' | sed 's/"id":"//g; s/"//g'
	fi
	return 0
}

#######################################
# Initialize database with FTS5 schema
#######################################
init_db() {
	mkdir -p "$MEMORY_DIR"

	if [[ ! -f "$MEMORY_DB" ]]; then
		log_info "Creating memory database at $MEMORY_DB"

		db "$MEMORY_DB" <<'EOF'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

-- FTS5 virtual table for searchable content
-- Note: FTS5 doesn't support foreign keys, so relationships are tracked separately
CREATE VIRTUAL TABLE IF NOT EXISTS learnings USING fts5(
    id UNINDEXED,
    session_id UNINDEXED,
    content,
    type,
    tags,
    confidence UNINDEXED,
    created_at UNINDEXED,
    event_date UNINDEXED,
    project_path UNINDEXED,
    source UNINDEXED,
    tokenize='porter unicode61'
);

-- Separate table for access tracking and metadata (FTS5 doesn't support UPDATE)
CREATE TABLE IF NOT EXISTS learning_access (
    id TEXT PRIMARY KEY,
    last_accessed_at TEXT,
    access_count INTEGER DEFAULT 0,
    auto_captured INTEGER DEFAULT 0
);

-- Relational versioning table (inspired by Supermemory)
-- Tracks how memories relate to each other over time
CREATE TABLE IF NOT EXISTS learning_relations (
    id TEXT PRIMARY KEY,
    supersedes_id TEXT,
    relation_type TEXT CHECK(relation_type IN ('updates', 'extends', 'derives')),
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
EOF
		log_success "Database initialized with relational versioning support"
	else
		# Migrate existing database if needed
		migrate_db
	fi

	# Ensure WAL mode for existing databases created before t135.3
	# WAL is persistent but may not be set on pre-existing DBs
	local current_mode
	current_mode=$(db "$MEMORY_DB" "PRAGMA journal_mode;" 2>/dev/null || echo "")
	if [[ "$current_mode" != "wal" ]]; then
		db "$MEMORY_DB" "PRAGMA journal_mode=WAL;" 2>/dev/null || echo "[WARN] Failed to enable WAL mode for memory DB" >&2
	fi

	return 0
}

#######################################
# Normalize content for deduplication comparison
# Lowercases, strips extra whitespace, removes punctuation
#######################################
normalize_content() {
	local text="$1"
	# Lowercase, collapse whitespace, strip leading/trailing, remove punctuation
	echo "$text" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '[:punct:]'
	return 0
}

#######################################
# Check for duplicate memory before storing
# Returns 0 if duplicate found (with ID on stdout), 1 if no duplicate
#######################################
check_duplicate() {
	local content="$1"
	local type="$2"

	# 1. Exact content match (same type)
	local escaped_content="${content//"'"/"''"}"
	local exact_id
	exact_id=$(db "$MEMORY_DB" "SELECT id FROM learnings WHERE content = '$escaped_content' AND type = '$type' LIMIT 1;" 2>/dev/null || echo "")
	if [[ -n "$exact_id" ]]; then
		echo "$exact_id"
		return 0
	fi

	# 2. Normalized content match (catches whitespace/punctuation/case differences)
	local normalized
	normalized=$(normalize_content "$content")
	local escaped_normalized="${normalized//"'"/"''"}"

	# Compare normalized versions of existing entries of the same type
	local norm_id
	norm_id=$(
		db "$MEMORY_DB" <<EOF
SELECT l.id FROM learnings l
WHERE l.type = '$type'
AND replace(replace(replace(replace(replace(lower(l.content),
    '.',''),"'",''),',',''),'!',''),'?','') 
    LIKE '%${escaped_normalized}%'
LIMIT 1;
EOF
	)

	# The LIKE approach above is coarse; refine with a stricter normalized comparison
	# by checking if the normalized stored content equals the normalized new content
	if [[ -z "$norm_id" ]]; then
		# Use FTS5 to find candidates, then compare normalized forms
		local fts_query="${content//"'"/"''"}"
		# Escape embedded double quotes for FTS5
		fts_query="\"${fts_query//\"/\"\"}\""
		local candidates
		candidates=$(db "$MEMORY_DB" "SELECT id, content FROM learnings WHERE learnings MATCH '$fts_query' AND type = '$type' LIMIT 10;" 2>/dev/null || echo "")
		if [[ -n "$candidates" ]]; then
			while IFS='|' read -r cand_id cand_content; do
				[[ -z "$cand_id" ]] && continue
				local cand_normalized
				cand_normalized=$(normalize_content "$cand_content")
				if [[ "$cand_normalized" == "$normalized" ]]; then
					echo "$cand_id"
					return 0
				fi
			done <<<"$candidates"
		fi
	else
		echo "$norm_id"
		return 0
	fi

	return 1
}

#######################################
# Auto-prune stale entries (called opportunistically on store)
# Only runs if last prune was >24h ago, to avoid overhead on every store
#######################################
auto_prune() {
	local prune_marker="$MEMORY_DIR/.last_auto_prune"
	local prune_interval_seconds=86400 # 24 hours

	# Check if we should run
	if [[ -f "$prune_marker" ]]; then
		local last_prune
		last_prune=$(stat -f %m "$prune_marker" 2>/dev/null || stat -c %Y "$prune_marker" 2>/dev/null || echo "0")
		local now
		now=$(date +%s)
		local elapsed=$((now - last_prune))
		if [[ "$elapsed" -lt "$prune_interval_seconds" ]]; then
			return 0
		fi
	fi

	# Run lightweight prune: remove entries >90 days old that were never accessed
	local stale_count
	stale_count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-$DEFAULT_MAX_AGE_DAYS days') AND a.id IS NULL;" 2>/dev/null || echo "0")

	if [[ "$stale_count" -gt 0 ]]; then
		local subquery="SELECT l.id FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-$DEFAULT_MAX_AGE_DAYS days') AND a.id IS NULL"
		db "$MEMORY_DB" "DELETE FROM learning_relations WHERE id IN ($subquery);" 2>/dev/null || true
		db "$MEMORY_DB" "DELETE FROM learning_relations WHERE supersedes_id IN ($subquery);" 2>/dev/null || true
		db "$MEMORY_DB" "DELETE FROM learning_access WHERE id IN ($subquery);" 2>/dev/null || true
		db "$MEMORY_DB" "DELETE FROM learnings WHERE id IN ($subquery);" 2>/dev/null || true
		db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');" 2>/dev/null || true
		log_info "Auto-pruned $stale_count stale entries (>$DEFAULT_MAX_AGE_DAYS days, never accessed)"
	fi

	# Update marker
	touch "$prune_marker"
	return 0
}

#######################################
# Generate unique ID
#######################################
generate_id() {
	# Use timestamp + random for uniqueness
	echo "mem_$(date +%Y%m%d%H%M%S)_$(head -c 4 /dev/urandom | xxd -p)"
	return 0
}
