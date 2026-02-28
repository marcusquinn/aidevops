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

	# shellcheck disable=SC2034 # Used by memory-helper.sh main() and recall.sh/maintenance.sh
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

	# Create pattern_metadata table if missing (t1095 migration)
	# Companion table for pattern records — stores strategy, quality, failure_mode, tokens
	local has_pattern_metadata
	has_pattern_metadata=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='pattern_metadata';" 2>/dev/null || echo "0")
	if [[ "$has_pattern_metadata" == "0" ]]; then
		log_info "Creating pattern_metadata table (t1095)..."
		db "$MEMORY_DB" <<'EOF'
CREATE TABLE IF NOT EXISTS pattern_metadata (
    id TEXT PRIMARY KEY,
    strategy TEXT DEFAULT 'normal' CHECK(strategy IN ('normal', 'prompt-repeat', 'escalated')),
    quality TEXT DEFAULT NULL CHECK(quality IS NULL OR quality IN ('ci-pass-first-try', 'ci-pass-after-fix', 'needs-human')),
    failure_mode TEXT DEFAULT NULL CHECK(failure_mode IS NULL OR failure_mode IN ('hallucination', 'context-miss', 'incomplete', 'wrong-file', 'timeout')),
    tokens_in INTEGER DEFAULT NULL,
    tokens_out INTEGER DEFAULT NULL,
    estimated_cost REAL DEFAULT NULL
);
EOF
		# Backfill existing pattern records with default strategy='normal'
		local pattern_types="$PATTERN_TYPES_SQL"
		local backfill_count
		backfill_count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ($pattern_types);" 2>/dev/null || echo "0")
		if [[ "$backfill_count" -gt 0 ]]; then
			db "$MEMORY_DB" "INSERT OR IGNORE INTO pattern_metadata (id, strategy) SELECT id, 'normal' FROM learnings WHERE type IN ($pattern_types);"
			log_success "Backfilled $backfill_count existing pattern records into pattern_metadata"
		fi
		log_success "pattern_metadata table created (t1095)"
	fi

	# Add estimated_cost column to pattern_metadata if missing (t1114 migration)
	local has_estimated_cost
	has_estimated_cost=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM pragma_table_info('pattern_metadata') WHERE name='estimated_cost';" 2>/dev/null || echo "0")
	if [[ "$has_estimated_cost" == "0" ]]; then
		db "$MEMORY_DB" "ALTER TABLE pattern_metadata ADD COLUMN estimated_cost REAL DEFAULT NULL;" 2>/dev/null ||
			echo "[WARN] Failed to add estimated_cost column (may already exist)" >&2
	fi

	# Create learning_entities junction table if missing (t1363.3 migration)
	# Links learnings to entities — enables entity-scoped memory queries.
	# Supports M:M: a learning can relate to multiple entities.
	local has_learning_entities
	has_learning_entities=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='learning_entities';" 2>/dev/null || echo "0")
	if [[ "$has_learning_entities" == "0" ]]; then
		log_info "Creating learning_entities junction table (t1363.3)..."
		db "$MEMORY_DB" <<'EOF'
CREATE TABLE IF NOT EXISTS learning_entities (
    learning_id TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (learning_id, entity_id)
);
CREATE INDEX IF NOT EXISTS idx_learning_entities_entity ON learning_entities(entity_id);
EOF
		log_success "learning_entities junction table created (t1363.3)"
	fi

	# Create entity memory tables if missing (t1363.1 migration)
	# Part of the conversational memory system (p035).
	# These tables extend memory.db with entity tracking, cross-channel identity,
	# versioned profiles, and interaction logging.
	local has_entities
	has_entities=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='entities';" 2>/dev/null || echo "0")
	if [[ "$has_entities" == "0" ]]; then
		log_info "Creating entity memory tables (t1363.1)..."
		db "$MEMORY_DB" <<'EOF'
-- Layer 2: Entity relationship model
CREATE TABLE IF NOT EXISTS entities (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('person', 'agent', 'service')),
    display_name TEXT DEFAULT NULL,
    aliases TEXT DEFAULT '',
    notes TEXT DEFAULT '',
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Cross-channel identity linking
CREATE TABLE IF NOT EXISTS entity_channels (
    entity_id TEXT NOT NULL,
    channel TEXT NOT NULL CHECK(channel IN ('matrix', 'simplex', 'email', 'cli', 'slack', 'discord', 'telegram', 'irc', 'web')),
    channel_id TEXT NOT NULL,
    display_name TEXT DEFAULT NULL,
    confidence TEXT DEFAULT 'suggested' CHECK(confidence IN ('confirmed', 'suggested', 'inferred')),
    verified_at TEXT DEFAULT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (channel, channel_id),
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_entity_channels_entity ON entity_channels(entity_id);

-- Layer 0: Raw interaction log (immutable, append-only)
CREATE TABLE IF NOT EXISTS interactions (
    id TEXT PRIMARY KEY,
    entity_id TEXT NOT NULL,
    channel TEXT NOT NULL,
    channel_id TEXT DEFAULT NULL,
    conversation_id TEXT DEFAULT NULL,
    direction TEXT NOT NULL DEFAULT 'inbound' CHECK(direction IN ('inbound', 'outbound', 'system')),
    content TEXT NOT NULL,
    metadata TEXT DEFAULT '{}',
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_interactions_entity ON interactions(entity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_interactions_conversation ON interactions(conversation_id);
CREATE INDEX IF NOT EXISTS idx_interactions_channel ON interactions(channel, channel_id, created_at DESC);

-- Layer 1: Per-conversation context
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    entity_id TEXT NOT NULL,
    channel TEXT NOT NULL,
    channel_id TEXT DEFAULT NULL,
    topic TEXT DEFAULT '',
    summary TEXT DEFAULT '',
    status TEXT DEFAULT 'active' CHECK(status IN ('active', 'idle', 'closed')),
    interaction_count INTEGER DEFAULT 0,
    first_interaction_at TEXT DEFAULT NULL,
    last_interaction_at TEXT DEFAULT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_conversations_entity ON conversations(entity_id, status);

-- Layer 2: Versioned entity profiles
CREATE TABLE IF NOT EXISTS entity_profiles (
    id TEXT PRIMARY KEY,
    entity_id TEXT NOT NULL,
    profile_key TEXT NOT NULL,
    profile_value TEXT NOT NULL,
    evidence TEXT DEFAULT '',
    confidence TEXT DEFAULT 'medium' CHECK(confidence IN ('high', 'medium', 'low')),
    supersedes_id TEXT DEFAULT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE,
    FOREIGN KEY (supersedes_id) REFERENCES entity_profiles(id)
);
CREATE INDEX IF NOT EXISTS idx_entity_profiles_entity ON entity_profiles(entity_id, profile_key);
CREATE INDEX IF NOT EXISTS idx_entity_profiles_supersedes ON entity_profiles(supersedes_id);

-- Capability gaps detected from entity interactions
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

-- FTS5 index for searching interactions
CREATE VIRTUAL TABLE IF NOT EXISTS interactions_fts USING fts5(
    id UNINDEXED,
    entity_id UNINDEXED,
    content,
    channel UNINDEXED,
    created_at UNINDEXED,
    tokenize='porter unicode61'
);
EOF
		log_success "Entity memory tables created (t1363.1)"
	fi

	# Create conversation_summaries table if missing (t1363.2 migration)
	# Versioned, immutable conversation summaries with source range references.
	local has_conv_summaries
	has_conv_summaries=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='conversation_summaries';" 2>/dev/null || echo "0")
	if [[ "$has_conv_summaries" == "0" ]]; then
		log_info "Creating conversation_summaries table (t1363.2)..."
		db "$MEMORY_DB" <<'EOF'
CREATE TABLE IF NOT EXISTS conversation_summaries (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    summary TEXT NOT NULL,
    source_range_start TEXT NOT NULL,
    source_range_end TEXT NOT NULL,
    source_interaction_count INTEGER DEFAULT 0,
    tone_profile TEXT DEFAULT '{}',
    pending_actions TEXT DEFAULT '[]',
    supersedes_id TEXT DEFAULT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE,
    FOREIGN KEY (supersedes_id) REFERENCES conversation_summaries(id)
);
CREATE INDEX IF NOT EXISTS idx_conv_summaries_conv ON conversation_summaries(conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_conv_summaries_supersedes ON conversation_summaries(supersedes_id);
EOF
		log_success "conversation_summaries table created (t1363.2)"
	fi

	# Add channel index to conversations if missing (t1363.2)
	local has_conv_channel_idx
	has_conv_channel_idx=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_conversations_channel';" 2>/dev/null || echo "0")
	if [[ "$has_conv_channel_idx" == "0" ]]; then
		db "$MEMORY_DB" "CREATE INDEX IF NOT EXISTS idx_conversations_channel ON conversations(channel, status);" 2>/dev/null || true
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

-- Learning-entity junction table (t1363.3) — links learnings to entities
-- Enables entity-scoped memory queries (e.g., "what do I know about this person?")
CREATE TABLE IF NOT EXISTS learning_entities (
    learning_id TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (learning_id, entity_id)
);
CREATE INDEX IF NOT EXISTS idx_learning_entities_entity ON learning_entities(entity_id);

-- Extended pattern metadata (t1095, t1114) — companion table for pattern records
-- Stores structured fields that can't go in FTS5 (strategy, quality, failure_mode, tokens, cost)
CREATE TABLE IF NOT EXISTS pattern_metadata (
    id TEXT PRIMARY KEY,
    strategy TEXT DEFAULT 'normal' CHECK(strategy IN ('normal', 'prompt-repeat', 'escalated')),
    quality TEXT DEFAULT NULL CHECK(quality IS NULL OR quality IN ('ci-pass-first-try', 'ci-pass-after-fix', 'needs-human')),
    failure_mode TEXT DEFAULT NULL CHECK(failure_mode IS NULL OR failure_mode IN ('hallucination', 'context-miss', 'incomplete', 'wrong-file', 'timeout')),
    tokens_in INTEGER DEFAULT NULL,
    tokens_out INTEGER DEFAULT NULL,
    estimated_cost REAL DEFAULT NULL
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
# Only runs if last prune was >24h ago, to avoid overhead on every store.
#
# Uses AI-judged relevance (t1363.6) for borderline entries instead of
# a flat DEFAULT_MAX_AGE_DAYS cutoff. The AI judge considers memory type,
# entity context, and access patterns. Falls back to type-aware heuristics
# when AI is unavailable.
#######################################
auto_prune() {
	local prune_marker="$MEMORY_DIR/.last_auto_prune"
	local prune_interval_seconds=86400 # 24 hours

	# Check if we should run
	if [[ -f "$prune_marker" ]]; then
		local last_prune
		last_prune=$(stat -c %Y "$prune_marker" 2>/dev/null || stat -f %m "$prune_marker" 2>/dev/null || echo "0")
		local now
		now=$(date +%s)
		local elapsed=$((now - last_prune))
		if [[ "$elapsed" -lt "$prune_interval_seconds" ]]; then
			return 0
		fi
	fi

	local threshold_judge="${SCRIPT_DIR}/ai-threshold-judge.sh"

	# Get candidates: entries older than 60 days that were never accessed
	# (60 days is the minimum threshold for any type — the judge decides the rest)
	local candidates
	candidates=$(db "$MEMORY_DB" "SELECT l.id, l.type, l.confidence, substr(l.content, 1, 300), CAST(julianday('now') - julianday(l.created_at) AS INTEGER) FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-60 days') AND a.id IS NULL;" 2>/dev/null || echo "")

	if [[ -z "$candidates" ]]; then
		touch "$prune_marker"
		return 0
	fi

	local prune_ids=""
	local prune_count=0
	local keep_count=0

	while IFS='|' read -r mem_id mem_type mem_confidence mem_content age_days; do
		[[ -z "$mem_id" ]] && continue

		local verdict="keep"
		if [[ -x "$threshold_judge" ]]; then
			verdict=$("$threshold_judge" judge-prune-relevance \
				--content "$mem_content" \
				--age-days "$age_days" \
				--type "$mem_type" \
				--accessed "false" \
				--confidence "${mem_confidence:-medium}" 2>/dev/null || echo "keep")
		else
			# Inline fallback: original flat threshold
			if [[ "$age_days" -gt "$DEFAULT_MAX_AGE_DAYS" ]]; then
				verdict="prune"
			fi
		fi

		if [[ "$verdict" == "prune" ]]; then
			if [[ -n "$prune_ids" ]]; then
				prune_ids="${prune_ids},'${mem_id//\'/\'\'}'"
			else
				prune_ids="'${mem_id//\'/\'\'}'"
			fi
			prune_count=$((prune_count + 1))
		else
			keep_count=$((keep_count + 1))
		fi
	done <<<"$candidates"

	if [[ "$prune_count" -gt 0 && -n "$prune_ids" ]]; then
		db "$MEMORY_DB" "DELETE FROM learning_relations WHERE id IN ($prune_ids);" 2>/dev/null || true
		db "$MEMORY_DB" "DELETE FROM learning_relations WHERE supersedes_id IN ($prune_ids);" 2>/dev/null || true
		db "$MEMORY_DB" "DELETE FROM learning_access WHERE id IN ($prune_ids);" 2>/dev/null || true
		db "$MEMORY_DB" "DELETE FROM learnings WHERE id IN ($prune_ids);" 2>/dev/null || true
		db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');" 2>/dev/null || true
		log_info "Auto-pruned $prune_count entries (AI-judged relevance, kept $keep_count borderline)"
	fi

	# Update marker
	touch "$prune_marker"
	return 0
}

#######################################
# Validate that an entity_id exists in the entities table
# Returns 0 if valid, 1 if not found
#######################################
validate_entity_id() {
	local entity_id="$1"
	local escaped_id="${entity_id//"'"/"''"}"
	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$escaped_id';" 2>/dev/null || echo "0")
	if [[ "$exists" == "0" ]]; then
		return 1
	fi
	return 0
}

#######################################
# Link a learning to an entity in the junction table
#######################################
link_learning_entity() {
	local learning_id="$1"
	local entity_id="$2"
	local escaped_learning="${learning_id//"'"/"''"}"
	local escaped_entity="${entity_id//"'"/"''"}"
	db "$MEMORY_DB" <<EOF
INSERT OR IGNORE INTO learning_entities (learning_id, entity_id)
VALUES ('$escaped_learning', '$escaped_entity');
EOF
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
