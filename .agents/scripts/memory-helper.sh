#!/usr/bin/env bash
# memory-helper.sh - Lightweight memory system for aidevops
# Uses SQLite FTS5 for fast text search without external dependencies
#
# Inspired by Supermemory's architecture for:
# - Relational versioning (updates, extends, derives relationships)
# - Dual timestamps (created_at vs event_date)
# - Contextual disambiguation (atomic, self-contained memories)
#
# Usage:
#   memory-helper.sh store --content "learning" [--type TYPE] [--tags "a,b"] [--session-id ID]
#   memory-helper.sh store --content "new info" --supersedes mem_xxx --relation updates
#   memory-helper.sh recall --query "search terms" [--limit 5] [--type TYPE] [--max-age-days 30]
#   memory-helper.sh history <id>             # Show version history for a memory
#   memory-helper.sh stats                    # Show memory statistics
#   memory-helper.sh prune [--older-than-days 90] [--dry-run]  # Remove stale entries
#   memory-helper.sh validate                 # Check for stale/low-quality entries
#   memory-helper.sh export [--format json|toon]  # Export all memories
#
# Namespace Support (per-runner memory isolation):
#   memory-helper.sh --namespace my-runner store --content "runner-specific learning"
#   memory-helper.sh --namespace my-runner recall --query "search" [--shared]
#   memory-helper.sh --namespace my-runner stats
#   memory-helper.sh namespaces              # List all namespaces
#
# Relational Versioning (inspired by Supermemory):
#   - updates: New info supersedes old (e.g., "favorite color is now green")
#   - extends: Adds detail without contradiction (e.g., adding job title)
#   - derives: Second-order inference from combining memories
#
# Dual Timestamps:
#   - created_at: When the memory was stored
#   - event_date: When the event described actually occurred
#
# Staleness Prevention:
#   - Entries have created_at and last_accessed_at timestamps
#   - Recall updates last_accessed_at (frequently used = valuable)
#   - Prune removes entries older than threshold AND never accessed
#   - Validate warns about potentially stale entries

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly MEMORY_BASE_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
readonly DEFAULT_MAX_AGE_DAYS=90

# Namespace support: --namespace sets a per-runner isolated DB
# Parsed in main() before command dispatch
MEMORY_NAMESPACE=""
MEMORY_DIR="$MEMORY_BASE_DIR"
MEMORY_DB="$MEMORY_DIR/memory.db"
readonly STALE_WARNING_DAYS=60

# Valid learning types (matches documentation and Continuous-Claude-v3)
readonly VALID_TYPES="WORKING_SOLUTION FAILED_APPROACH CODEBASE_PATTERN USER_PREFERENCE TOOL_CONFIG DECISION CONTEXT ARCHITECTURAL_DECISION ERROR_FIX OPEN_THREAD SUCCESS_PATTERN FAILURE_PATTERN"

# Valid relation types (inspired by Supermemory's relational versioning)
# - updates: New info supersedes old (state mutation)
# - extends: Adds detail without contradiction (refinement)
# - derives: Second-order inference from combining memories
readonly VALID_RELATIONS="updates extends derives"

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
# Now with backup-before-modify pattern (t188)
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
# Migrate existing database to new schema
#######################################
migrate_db() {
    # Check if event_date column exists in FTS5 table
    # FTS5 tables don't support ALTER TABLE, so we check via pragma
    local has_event_date
    has_event_date=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM pragma_table_info('learnings') WHERE name='event_date';" 2>/dev/null || echo "0")
    
    if [[ "$has_event_date" == "0" ]]; then
        log_info "Migrating database to add event_date and relations..."
        
        # For FTS5, we need to recreate the table
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
        log_success "Database migrated successfully"
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
    norm_id=$(db "$MEMORY_DB" <<EOF
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
            done <<< "$candidates"
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
    local prune_interval_seconds=86400  # 24 hours

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

#######################################
# Store a learning
#######################################
cmd_store() {
    local content=""
    local type="WORKING_SOLUTION"
    local tags=""
    local confidence="medium"
    local session_id=""
    local project_path=""
    local source="manual"
    local event_date=""
    local supersedes_id=""
    local relation_type=""
    local auto_captured=0
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --content) content="$2"; shift 2 ;;
            --type) type="$2"; shift 2 ;;
            --tags) tags="$2"; shift 2 ;;
            --confidence) confidence="$2"; shift 2 ;;
            --session-id) session_id="$2"; shift 2 ;;
            --project) project_path="$2"; shift 2 ;;
            --source) source="$2"; shift 2 ;;
            --event-date) event_date="$2"; shift 2 ;;
            --supersedes) supersedes_id="$2"; shift 2 ;;
            --relation) relation_type="$2"; shift 2 ;;
            --auto|--auto-captured) auto_captured=1; source="auto"; shift ;;
            *) 
                # Allow content as positional argument
                if [[ -z "$content" ]]; then
                    content="$1"
                fi
                shift ;;
        esac
    done
    
    # Validate required fields
    if [[ -z "$content" ]]; then
        log_error "Content is required. Use --content \"your learning\""
        return 1
    fi
    
    # Privacy filter: strip <private>...</private> blocks
    content=$(echo "$content" | sed 's/<private>[^<]*<\/private>//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
    
    # Privacy filter: reject content that looks like secrets
    if echo "$content" | grep -qE '(sk-[a-zA-Z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[a-zA-Z0-9]{36}|gho_[a-zA-Z0-9]{36}|xoxb-[a-zA-Z0-9-]{20,}|api[_-]?key[[:space:]"'"'"':=]+[a-zA-Z0-9_-]{16,})'; then
        log_error "Content appears to contain secrets (API keys, tokens). Refusing to store."
        log_error "Remove sensitive data or wrap in <private>...</private> tags to exclude."
        return 1
    fi
    
    # If content is empty after privacy filtering, skip
    if [[ -z "$content" ]]; then
        log_warn "Content is empty after privacy filtering. Skipping."
        return 0
    fi
    
    # Validate type
    local type_pattern=" $type "
    if [[ ! " $VALID_TYPES " =~ $type_pattern ]]; then
        log_error "Invalid type: $type"
        log_error "Valid types: $VALID_TYPES"
        return 1
    fi
    
    # Validate confidence
    if [[ ! "$confidence" =~ ^(high|medium|low)$ ]]; then
        log_error "Invalid confidence: $confidence (use high, medium, or low)"
        return 1
    fi
    
    # Validate relation_type if provided
    if [[ -n "$relation_type" ]]; then
        local relation_pattern=" $relation_type "
        if [[ ! " $VALID_RELATIONS " =~ $relation_pattern ]]; then
            log_error "Invalid relation type: $relation_type"
            log_error "Valid relations: $VALID_RELATIONS"
            return 1
        fi
        
        # If relation_type is provided, supersedes_id is required
        if [[ -z "$supersedes_id" ]]; then
            log_error "When using --relation, --supersedes <id> is required"
            return 1
        fi
    fi
    
    # If supersedes_id is provided, relation_type defaults to 'updates'
    if [[ -n "$supersedes_id" && -z "$relation_type" ]]; then
        relation_type="updates"
    fi
    
    # Generate session_id if not provided
    if [[ -z "$session_id" ]]; then
        session_id="session_$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Get current project path if not provided
    if [[ -z "$project_path" ]]; then
        project_path="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    
    init_db
    
    # Deduplication: skip if content already exists (unless it's a relational update)
    if [[ -z "$supersedes_id" ]]; then
        local existing_id
        if existing_id=$(check_duplicate "$content" "$type"); then
            log_warn "Duplicate detected (matches $existing_id). Skipping store."
            # Update access tracking on the existing entry to keep it fresh
            db "$MEMORY_DB" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count)
VALUES ('$existing_id', datetime('now'), 1)
ON CONFLICT(id) DO UPDATE SET 
    last_accessed_at = datetime('now'),
    access_count = access_count + 1;
EOF
            echo "$existing_id"
            return 0
        fi
    fi
    
    # Opportunistic auto-prune (runs at most once per 24h)
    auto_prune
    
    local id
    id=$(generate_id)
    local created_at
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Default event_date to created_at if not provided
    if [[ -z "$event_date" ]]; then
        event_date="$created_at"
    elif ! [[ "$event_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        log_warn "event_date '$event_date' may not be a valid ISO format (YYYY-MM-DD...)"
    fi
    
    # Escape single quotes for SQL (prevents SQL injection)
    local escaped_content="${content//"'"/"''"}"
    local escaped_tags="${tags//"'"/"''"}"
    local escaped_project="${project_path//"'"/"''"}"
    local escaped_supersedes="${supersedes_id//"'"/"''"}"
    
    # Validate supersedes_id exists if provided
    if [[ -n "$supersedes_id" ]]; then
        local exists
        exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$escaped_supersedes';")
        if [[ "$exists" == "0" ]]; then
            log_error "Supersedes ID not found: $supersedes_id"
            return 1
        fi
    fi
    
    db "$MEMORY_DB" <<EOF
INSERT INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source)
VALUES ('$id', '$session_id', '$escaped_content', '$type', '$escaped_tags', '$confidence', '$created_at', '$event_date', '$escaped_project', '$source');
EOF
    
    # Store auto-captured flag in access table
    if [[ "$auto_captured" -eq 1 ]]; then
        db "$MEMORY_DB" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count, auto_captured)
VALUES ('$id', '$created_at', 0, 1)
ON CONFLICT(id) DO UPDATE SET auto_captured = 1;
EOF
    fi
    
    # Store relation if provided
    if [[ -n "$supersedes_id" ]]; then
        db "$MEMORY_DB" <<EOF
INSERT INTO learning_relations (id, supersedes_id, relation_type, created_at)
VALUES ('$id', '$escaped_supersedes', '$relation_type', '$created_at');
EOF
        log_info "Relation: $id $relation_type $supersedes_id"
    fi
    
    log_success "Stored learning: $id"
    
    # Auto-index for semantic search (non-blocking, background)
    local embeddings_script
    embeddings_script="$(dirname "$0")/memory-embeddings-helper.sh"
    if [[ -x "$embeddings_script" ]]; then
        local auto_args=()
        if [[ -n "$MEMORY_NAMESPACE" ]]; then
            auto_args+=("--namespace" "$MEMORY_NAMESPACE")
        fi
        auto_args+=("auto-index" "$id")
        "$embeddings_script" "${auto_args[@]}" 2>/dev/null || true
    fi
    
    echo "$id"
}

#######################################
# Recall learnings with search
#######################################
cmd_recall() {
    local query=""
    local limit=5
    local type_filter=""
    local max_age_days=""
    local project_filter=""
    local format="text"
    local recent_mode=false
    local semantic_mode=false
    local hybrid_mode=false
    local shared_mode=false
    local auto_only=false
    local manual_only=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --query|-q) query="$2"; shift 2 ;;
            --limit|-l) limit="$2"; shift 2 ;;
            --type|-t) type_filter="$2"; shift 2 ;;
            --max-age-days) max_age_days="$2"; shift 2 ;;
            --project|-p) project_filter="$2"; shift 2 ;;
            --recent) recent_mode=true; limit="${2:-10}"; shift; [[ "${1:-}" =~ ^[0-9]+$ ]] && shift ;;
            --semantic|--similar) semantic_mode=true; shift ;;
            --hybrid) hybrid_mode=true; shift ;;
            --shared) shared_mode=true; shift ;;
            --auto-only) auto_only=true; shift ;;
            --manual-only) manual_only=true; shift ;;
            --format) format="$2"; shift 2 ;;
            --json) format="json"; shift ;;
            --stats) cmd_stats; return 0 ;;
            *) 
                # Allow query as positional argument
                if [[ -z "$query" ]]; then
                    query="$1"
                fi
                shift ;;
        esac
    done
    
    init_db
    
    # Build auto-capture filter clause
    local auto_filter=""
    if [[ "$auto_only" == true ]]; then
        auto_filter="AND COALESCE(a.auto_captured, 0) = 1"
    elif [[ "$manual_only" == true ]]; then
        auto_filter="AND COALESCE(a.auto_captured, 0) = 0"
    fi
    
    # Handle --recent mode (no query required)
    if [[ "$recent_mode" == true ]]; then
        local results
        results=$(db -json "$MEMORY_DB" "SELECT l.id, l.content, l.type, l.tags, l.confidence, l.created_at, COALESCE(a.last_accessed_at, '') as last_accessed_at, COALESCE(a.access_count, 0) as access_count, COALESCE(a.auto_captured, 0) as auto_captured FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE 1=1 $auto_filter ORDER BY l.created_at DESC LIMIT $limit;")
        if [[ "$format" == "json" ]]; then
            echo "$results"
        else
            echo ""
            echo "=== Recent Memories (last $limit) ==="
            echo ""
            echo "$results" | format_results_text
        fi
        return 0
    fi
    
    if [[ -z "$query" ]]; then
        log_error "Query is required. Use --query \"search terms\" or --recent"
        return 1
    fi
    
    # Handle --semantic or --hybrid mode (delegate to embeddings helper)
    if [[ "$semantic_mode" == true || "$hybrid_mode" == true ]]; then
        local embeddings_script
        embeddings_script="$(dirname "$0")/memory-embeddings-helper.sh"
        if [[ ! -x "$embeddings_script" ]]; then
            log_error "Semantic search not available. Run: memory-embeddings-helper.sh setup"
            return 1
        fi
        local semantic_args=()
        if [[ -n "$MEMORY_NAMESPACE" ]]; then
            semantic_args+=("--namespace" "$MEMORY_NAMESPACE")
        fi
        semantic_args+=("search" "$query" "--limit" "$limit")
        if [[ "$hybrid_mode" == true ]]; then
            semantic_args+=("--hybrid")
        fi
        if [[ "$format" == "json" ]]; then
            semantic_args+=("--json")
        fi
        "$embeddings_script" "${semantic_args[@]}"
        return $?
    fi
    
    # Escape query for FTS5 - wrap in double quotes to handle special chars
    # FTS5 treats hyphens as NOT operator, asterisks as prefix, etc.
    # Quoting the query makes it a literal phrase search.
    local escaped_query="${query//"'"/"''"}"
    # Escape embedded double quotes for FTS5 (double them), then wrap in quotes
    escaped_query="\"${escaped_query//\"/\"\"}\""
    
    # Build filters with validation
    local extra_filters=""
    if [[ -n "$type_filter" ]]; then
        # Validate type to prevent SQL injection
        local type_pattern=" $type_filter "
        if [[ ! " $VALID_TYPES " =~ $type_pattern ]]; then
            log_error "Invalid type: $type_filter"
            log_error "Valid types: $VALID_TYPES"
            return 1
        fi
        extra_filters="$extra_filters AND type = '$type_filter'"
    fi
    if [[ -n "$max_age_days" ]]; then
        # Validate max_age_days is a positive integer
        if ! [[ "$max_age_days" =~ ^[0-9]+$ ]]; then
            log_error "--max-age-days must be a positive integer"
            return 1
        fi
        extra_filters="$extra_filters AND created_at >= datetime('now', '-$max_age_days days')"
    fi
    if [[ -n "$project_filter" ]]; then
        local escaped_project="${project_filter//"'"/"''"}"
        extra_filters="$extra_filters AND project_path LIKE '%$escaped_project%'"
    fi
    
    # Build auto-capture filter for main query
    local auto_join_filter=""
    if [[ "$auto_only" == true ]]; then
        auto_join_filter="AND COALESCE(learning_access.auto_captured, 0) = 1"
    elif [[ "$manual_only" == true ]]; then
        auto_join_filter="AND COALESCE(learning_access.auto_captured, 0) = 0"
    fi
    
    # Search using FTS5 with BM25 ranking
    # Note: FTS5 tables require special handling - can't use table alias in bm25()
    local results
    results=$(db -json "$MEMORY_DB" <<EOF
SELECT 
    learnings.id,
    learnings.content,
    learnings.type,
    learnings.tags,
    learnings.confidence,
    learnings.created_at,
    COALESCE(learning_access.last_accessed_at, '') as last_accessed_at,
    COALESCE(learning_access.access_count, 0) as access_count,
    COALESCE(learning_access.auto_captured, 0) as auto_captured,
    bm25(learnings) as score
FROM learnings
LEFT JOIN learning_access ON learnings.id = learning_access.id
WHERE learnings MATCH '$escaped_query' $extra_filters $auto_join_filter
ORDER BY score
LIMIT $limit;
EOF
)
    
    # Update access tracking for returned results (prevents staleness)
    if [[ -n "$results" && "$results" != "[]" ]]; then
        local ids
        ids=$(echo "$results" | extract_ids_from_json)
        if [[ -n "$ids" ]]; then
            while IFS= read -r id; do
                [[ -z "$id" ]] && continue
                db "$MEMORY_DB" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count)
VALUES ('$id', datetime('now'), 1)
ON CONFLICT(id) DO UPDATE SET 
    last_accessed_at = datetime('now'),
    access_count = access_count + 1;
EOF
            done <<< "$ids"
        fi
    fi
    
    # Shared search: also query global DB when in a namespace with --shared
    local shared_results=""
    if [[ "$shared_mode" == true && -n "$MEMORY_NAMESPACE" ]]; then
        local global_db
        global_db=$(global_db_path)
        if [[ -f "$global_db" ]]; then
            shared_results=$(db -json "$global_db" <<EOF
SELECT 
    learnings.id,
    learnings.content,
    learnings.type,
    learnings.tags,
    learnings.confidence,
    learnings.created_at,
    COALESCE(learning_access.last_accessed_at, '') as last_accessed_at,
    COALESCE(learning_access.access_count, 0) as access_count,
    bm25(learnings) as score
FROM learnings
LEFT JOIN learning_access ON learnings.id = learning_access.id
WHERE learnings MATCH '$escaped_query' $extra_filters
ORDER BY score
LIMIT $limit;
EOF
)
            # Update access tracking in global DB for shared results
            if [[ -n "$shared_results" && "$shared_results" != "[]" ]]; then
                local shared_ids
                shared_ids=$(echo "$shared_results" | extract_ids_from_json)
                if [[ -n "$shared_ids" ]]; then
                    while IFS= read -r sid; do
                        [[ -z "$sid" ]] && continue
                        db "$global_db" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count)
VALUES ('$sid', datetime('now'), 1)
ON CONFLICT(id) DO UPDATE SET 
    last_accessed_at = datetime('now'),
    access_count = access_count + 1;
EOF
                    done <<< "$shared_ids"
                fi
            fi
        fi
    fi

    # Output based on format
    if [[ "$format" == "json" ]]; then
        if [[ -n "$shared_results" && "$shared_results" != "[]" ]]; then
            # Merge namespace and global results into single JSON array
            if command -v jq &>/dev/null; then
                local ns_json="${results:-[]}"
                jq -s '.[0] + .[1] | sort_by(.score) | .[:'"$limit"']' \
                    <(echo "$ns_json") <(echo "$shared_results")
            else
                echo "$results"
                echo "$shared_results"
            fi
        else
            echo "$results"
        fi
    else
        if [[ -z "$results" || "$results" == "[]" ]]; then
            if [[ -z "$shared_results" || "$shared_results" == "[]" ]]; then
                log_warn "No results found for: $query"
                return 0
            fi
        fi
        
        local header_suffix=""
        if [[ -n "$MEMORY_NAMESPACE" ]]; then
            header_suffix=" [namespace: $MEMORY_NAMESPACE]"
        fi
        
        echo ""
        echo "=== Memory Recall: \"$query\"${header_suffix} ==="
        echo ""
        
        if [[ -n "$results" && "$results" != "[]" ]]; then
            echo "$results" | format_results_text
        fi
        
        if [[ -n "$shared_results" && "$shared_results" != "[]" ]]; then
            echo ""
            echo "--- Shared (global) results ---"
            echo ""
            echo "$shared_results" | format_results_text
        fi
    fi
}

#######################################
# Show version history for a memory
# Traces the chain of updates/extends/derives
#######################################
cmd_history() {
    local memory_id="$1"
    
    if [[ -z "$memory_id" ]]; then
        log_error "Memory ID is required. Usage: memory-helper.sh history <id>"
        return 1
    fi
    
    init_db
    
    # Escape memory_id for SQL (prevents SQL injection)
    local escaped_id="${memory_id//"'"/"''"}"
    
    # Check if memory exists
    local exists
    exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$escaped_id';")
    if [[ "$exists" == "0" ]]; then
        log_error "Memory not found: $memory_id"
        return 1
    fi
    
    echo ""
    echo "=== Version History for $memory_id ==="
    echo ""
    
    # Show the current memory
    echo "Current:"
    db "$MEMORY_DB" <<EOF
SELECT '  [' || type || '] ' || substr(content, 1, 80) || '...'
FROM learnings WHERE id = '$escaped_id';
SELECT '  Created: ' || created_at || ' | Event: ' || COALESCE(event_date, 'N/A')
FROM learnings WHERE id = '$escaped_id';
EOF
    
    # Show what this memory supersedes (ancestors)
    echo ""
    echo "Supersedes (ancestors):"
    local ancestors
    ancestors=$(db "$MEMORY_DB" <<EOF
WITH RECURSIVE ancestors AS (
    SELECT lr.supersedes_id, lr.relation_type, 1 as depth
    FROM learning_relations lr
    WHERE lr.id = '$escaped_id'
    UNION ALL
    SELECT lr.supersedes_id, lr.relation_type, a.depth + 1
    FROM learning_relations lr
    JOIN ancestors a ON lr.id = a.supersedes_id
    WHERE a.depth < 10
)
SELECT a.supersedes_id, a.relation_type, a.depth, 
       l.type, substr(l.content, 1, 60), l.created_at
FROM ancestors a
JOIN learnings l ON a.supersedes_id = l.id
ORDER BY a.depth;
EOF
)
    
    if [[ -z "$ancestors" ]]; then
        echo "  (none - this is the original)"
    else
        echo "$ancestors" | while IFS='|' read -r sup_id rel_type depth mem_type content created; do
            local indent
            indent=$(printf '%*s' "$((depth * 2))" '')
            echo "${indent}[${rel_type}] $sup_id"
            echo "${indent}  [${mem_type}] $content..."
            echo "${indent}  Created: $created"
        done
    fi
    
    # Show what supersedes this memory (descendants)
    echo ""
    echo "Superseded by (descendants):"
    local descendants
    descendants=$(db "$MEMORY_DB" <<EOF
WITH RECURSIVE descendants AS (
    SELECT lr.id as child_id, lr.relation_type, 1 as depth
    FROM learning_relations lr
    WHERE lr.supersedes_id = '$escaped_id'
    UNION ALL
    SELECT lr.id, lr.relation_type, d.depth + 1
    FROM learning_relations lr
    JOIN descendants d ON lr.supersedes_id = d.child_id
    WHERE d.depth < 10
)
SELECT d.child_id, d.relation_type, d.depth,
       l.type, substr(l.content, 1, 60), l.created_at
FROM descendants d
JOIN learnings l ON d.child_id = l.id
ORDER BY d.depth;
EOF
)
    
    if [[ -z "$descendants" ]]; then
        echo "  (none - this is the latest)"
    else
        echo "$descendants" | while IFS='|' read -r child_id rel_type depth mem_type content created; do
            local indent
            indent=$(printf '%*s' "$((depth * 2))" '')
            echo "${indent}[${rel_type}] $child_id"
            echo "${indent}  [${mem_type}] $content..."
            echo "${indent}  Created: $created"
        done
    fi
    
    return 0
}

#######################################
# Find the latest version of a memory
# Follows the chain of 'updates' relations to find the current truth
#######################################
cmd_latest() {
    local memory_id="$1"
    
    if [[ -z "$memory_id" ]]; then
        log_error "Memory ID is required. Usage: memory-helper.sh latest <id>"
        return 1
    fi
    
    init_db
    
    # Escape memory_id for SQL (prevents SQL injection)
    local escaped_id="${memory_id//"'"/"''"}"
    
    # Find the latest in the chain (no descendants with 'updates' relation)
    local latest_id
    latest_id=$(db "$MEMORY_DB" <<EOF
WITH RECURSIVE chain AS (
    SELECT '$escaped_id' as id
    UNION ALL
    SELECT lr.id
    FROM learning_relations lr
    JOIN chain c ON lr.supersedes_id = c.id
    WHERE lr.relation_type = 'updates'
)
SELECT id FROM chain
WHERE id NOT IN (SELECT supersedes_id FROM learning_relations WHERE relation_type = 'updates')
LIMIT 1;
EOF
)
    
    if [[ -z "$latest_id" ]]; then
        latest_id="$memory_id"
    fi
    
    # Escape latest_id for the final query
    local escaped_latest="${latest_id//"'"/"''"}"
    
    echo "$latest_id"
    
    # Show the content
    db "$MEMORY_DB" <<EOF
SELECT '[' || type || '] ' || content
FROM learnings WHERE id = '$escaped_latest';
EOF
    
    return 0
}

#######################################
# Show memory statistics
#######################################
cmd_stats() {
    init_db
    
    local header_suffix=""
    if [[ -n "$MEMORY_NAMESPACE" ]]; then
        header_suffix=" [namespace: $MEMORY_NAMESPACE]"
    fi
    
    echo ""
    echo "=== Memory Statistics${header_suffix} ==="
    echo ""
    
    db "$MEMORY_DB" <<'EOF'
SELECT 'Total learnings' as metric, COUNT(*) as value FROM learnings
UNION ALL
SELECT 'By type: ' || type, COUNT(*) FROM learnings GROUP BY type
UNION ALL
SELECT 'Auto-captured', COUNT(*) FROM learning_access WHERE auto_captured = 1
UNION ALL
SELECT 'Manual', COUNT(*) FROM learnings l 
    LEFT JOIN learning_access a ON l.id = a.id WHERE COALESCE(a.auto_captured, 0) = 0
UNION ALL
SELECT 'Never accessed', COUNT(*) FROM learnings l 
    LEFT JOIN learning_access a ON l.id = a.id WHERE a.id IS NULL
UNION ALL
SELECT 'High confidence', COUNT(*) FROM learnings WHERE confidence = 'high';
EOF
    
    echo ""
    
    # Show relation statistics
    echo "Relational versioning:"
    db "$MEMORY_DB" <<'EOF'
SELECT '  Total relations', COUNT(*) FROM learning_relations
UNION ALL
SELECT '  Updates (supersedes)', COUNT(*) FROM learning_relations WHERE relation_type = 'updates'
UNION ALL
SELECT '  Extends (adds detail)', COUNT(*) FROM learning_relations WHERE relation_type = 'extends'
UNION ALL
SELECT '  Derives (inferred)', COUNT(*) FROM learning_relations WHERE relation_type = 'derives';
EOF
    
    echo ""
    
    # Show age distribution
    echo "Age distribution:"
    db "$MEMORY_DB" <<'EOF'
SELECT 
    CASE 
        WHEN created_at >= datetime('now', '-7 days') THEN '  Last 7 days'
        WHEN created_at >= datetime('now', '-30 days') THEN '  Last 30 days'
        WHEN created_at >= datetime('now', '-90 days') THEN '  Last 90 days'
        ELSE '  Older than 90 days'
    END as age_bucket,
    COUNT(*) as count
FROM learnings
GROUP BY 1
ORDER BY 1;
EOF
    return 0
}

#######################################
# Validate and warn about stale entries
#######################################
cmd_validate() {
    init_db
    
    echo ""
    echo "=== Memory Validation ==="
    echo ""
    
    # Check for stale entries (old + never accessed)
    local stale_count
    stale_count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-$STALE_WARNING_DAYS days') AND a.id IS NULL;")
    
    if [[ "$stale_count" -gt 0 ]]; then
        log_warn "Found $stale_count potentially stale entries (>$STALE_WARNING_DAYS days old, never accessed)"
        echo ""
        echo "Stale entries:"
        db "$MEMORY_DB" <<EOF
SELECT l.id, l.type, substr(l.content, 1, 60) || '...' as content_preview, l.created_at
FROM learnings l
LEFT JOIN learning_access a ON l.id = a.id
WHERE l.created_at < datetime('now', '-$STALE_WARNING_DAYS days') 
AND a.id IS NULL
LIMIT 10;
EOF
        echo ""
        echo "Run 'memory-helper.sh prune --older-than-days $STALE_WARNING_DAYS' to clean up"
    else
        log_success "No stale entries found"
    fi
    
    # Check for exact duplicate content
    local dup_count
    dup_count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM (SELECT content, COUNT(*) as cnt FROM learnings GROUP BY content HAVING cnt > 1);" 2>/dev/null || echo "0")
    
    if [[ "$dup_count" -gt 0 ]]; then
        log_warn "Found $dup_count groups of exact duplicate entries"
        echo ""
        echo "Exact duplicates:"
        db "$MEMORY_DB" <<'EOF'
SELECT substr(l.content, 1, 60) || '...' as content_preview,
       l.type,
       COUNT(*) as copies,
       GROUP_CONCAT(l.id, ', ') as ids
FROM learnings l
GROUP BY l.content
HAVING COUNT(*) > 1
ORDER BY copies DESC
LIMIT 10;
EOF
        echo ""
        echo "Run 'memory-helper.sh dedup --dry-run' to preview cleanup"
        echo "Run 'memory-helper.sh dedup' to remove duplicates"
    else
        log_success "No exact duplicate entries found"
    fi
    
    # Check for near-duplicate content (normalized comparison)
    local near_dup_count
    near_dup_count=$(db "$MEMORY_DB" <<'EOF'
SELECT COUNT(*) FROM (
    SELECT replace(replace(replace(replace(replace(lower(content),
        '.',''),"'",''),',',''),'!',''),'?','') as norm,
        COUNT(*) as cnt
    FROM learnings
    GROUP BY norm
    HAVING cnt > 1
);
EOF
    )
    near_dup_count="${near_dup_count:-0}"
    
    if [[ "$near_dup_count" -gt "$dup_count" ]]; then
        local near_only=$((near_dup_count - dup_count))
        log_warn "Found $near_only additional near-duplicate groups (differ only in case/punctuation)"
        echo "  Run 'memory-helper.sh dedup' to consolidate"
    fi
    
    # Check for superseded entries that may be obsolete
    local superseded_count
    superseded_count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learning_relations WHERE relation_type = 'updates';" 2>/dev/null || echo "0")
    if [[ "$superseded_count" -gt 0 ]]; then
        log_info "$superseded_count memories have been superseded by newer versions"
    fi
    
    # Check database size
    local db_size
    db_size=$(du -h "$MEMORY_DB" | cut -f1)
    log_info "Database size: $db_size"
    return 0
}

#######################################
# Deduplicate memories
# Removes exact and near-duplicate entries, keeping the oldest (most established)
# Merges tags from removed entries into the surviving one
#######################################
cmd_dedup() {
    local dry_run=false
    local include_near=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --exact-only) include_near=false; shift ;;
            *) shift ;;
        esac
    done

    init_db

    log_info "Scanning for duplicate memories..."

    # Phase 1: Exact duplicates (same content string)
    local exact_groups
    exact_groups=$(db "$MEMORY_DB" <<'EOF'
SELECT GROUP_CONCAT(id, '|') as ids, content, type, COUNT(*) as cnt
FROM learnings
GROUP BY content
HAVING cnt > 1
ORDER BY cnt DESC;
EOF
    )

    local exact_removed=0
    if [[ -n "$exact_groups" ]]; then
        # Query each duplicate group individually for reliable parsing
        local dup_contents
        dup_contents=$(db "$MEMORY_DB" "SELECT content FROM learnings GROUP BY content HAVING COUNT(*) > 1;")

        while IFS= read -r dup_content; do
            [[ -z "$dup_content" ]] && continue
            local escaped_dup="${dup_content//"'"/"''"}"

            # Get all IDs for this content, ordered by created_at (oldest first)
            local all_ids
            all_ids=$(db "$MEMORY_DB" "SELECT id FROM learnings WHERE content = '$escaped_dup' ORDER BY created_at ASC;")

            local keep_id=""
            while IFS= read -r mem_id; do
                [[ -z "$mem_id" ]] && continue
                if [[ -z "$keep_id" ]]; then
                    keep_id="$mem_id"
                    continue
                fi

                # This is a duplicate to remove
                local escaped_keep="${keep_id//"'"/"''"}"
                local escaped_remove="${mem_id//"'"/"''"}"

                if [[ "$dry_run" == true ]]; then
                    log_info "[DRY RUN] Would remove $mem_id (duplicate of $keep_id)"
                else
                    # Merge tags
                    local keep_tags remove_tags
                    keep_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$escaped_keep';")
                    remove_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$escaped_remove';")
                    if [[ -n "$remove_tags" ]]; then
                        local merged_tags
                        merged_tags=$(echo "$keep_tags,$remove_tags" | tr ',' '\n' | sort -u | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
                        local merged_tags_esc="${merged_tags//"'"/"''"}"
                        db "$MEMORY_DB" "UPDATE learnings SET tags = '$merged_tags_esc' WHERE id = '$escaped_keep';"
                    fi

                    # Transfer access history (keep higher count)
                    db "$MEMORY_DB" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count)
SELECT '$escaped_keep', last_accessed_at, access_count
FROM learning_access WHERE id = '$escaped_remove'
AND NOT EXISTS (SELECT 1 FROM learning_access WHERE id = '$escaped_keep')
ON CONFLICT(id) DO UPDATE SET
    access_count = MAX(learning_access.access_count, excluded.access_count),
    last_accessed_at = MAX(learning_access.last_accessed_at, excluded.last_accessed_at);
EOF

                    # Re-point relations
                    db "$MEMORY_DB" "UPDATE learning_relations SET supersedes_id = '$escaped_keep' WHERE supersedes_id = '$escaped_remove';" 2>/dev/null || true
                    db "$MEMORY_DB" "DELETE FROM learning_relations WHERE id = '$escaped_remove';" 2>/dev/null || true

                    # Delete duplicate
                    db "$MEMORY_DB" "DELETE FROM learning_access WHERE id = '$escaped_remove';"
                    db "$MEMORY_DB" "DELETE FROM learnings WHERE id = '$escaped_remove';"
                fi
                exact_removed=$((exact_removed + 1))
            done <<< "$all_ids"
        done <<< "$dup_contents"
    fi

    # Phase 2: Near-duplicates (normalized content match)
    local near_removed=0
    if [[ "$include_near" == true ]]; then
        local near_groups
        near_groups=$(db "$MEMORY_DB" <<'EOF'
SELECT GROUP_CONCAT(id, ',') as ids,
       replace(replace(replace(replace(replace(lower(content),
           '.',''),"'",''),',',''),'!',''),'?','') as norm,
       COUNT(*) as cnt
FROM learnings
GROUP BY norm
HAVING cnt > 1
ORDER BY cnt DESC;
EOF
        )

        if [[ -n "$near_groups" ]]; then
            while IFS='|' read -r id_list _norm _cnt; do
                [[ -z "$id_list" ]] && continue
                # Skip if this was already handled as an exact duplicate
                local id_count
                id_count=$(echo "$id_list" | tr ',' '\n' | wc -l | tr -d ' ')
                [[ "$id_count" -le 1 ]] && continue

                local ids_arr
                IFS=',' read -ra ids_arr <<< "$id_list"

                # Find the oldest entry to keep
                local oldest_id=""
                local oldest_date="9999"
                for nid in "${ids_arr[@]}"; do
                    [[ -z "$nid" ]] && continue
                    local nid_esc="${nid//"'"/"''"}"
                    local nid_exists
                    nid_exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$nid_esc';" 2>/dev/null || echo "0")
                    [[ "$nid_exists" == "0" ]] && continue

                    local nid_date
                    nid_date=$(db "$MEMORY_DB" "SELECT created_at FROM learnings WHERE id = '$nid_esc';" 2>/dev/null || echo "9999")
                    # shellcheck disable=SC2071 # Intentional lexicographic comparison for ISO date strings
                    if [[ "$nid_date" < "$oldest_date" ]]; then
                        oldest_date="$nid_date"
                        oldest_id="$nid"
                    fi
                done

                [[ -z "$oldest_id" ]] && continue

                for nid in "${ids_arr[@]}"; do
                    [[ -z "$nid" || "$nid" == "$oldest_id" ]] && continue
                    local nid_esc="${nid//"'"/"''"}"
                    local nid_exists
                    nid_exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$nid_esc';" 2>/dev/null || echo "0")
                    [[ "$nid_exists" == "0" ]] && continue

                    local oldest_esc="${oldest_id//"'"/"''"}"

                    if [[ "$dry_run" == true ]]; then
                        local preview
                        preview=$(db "$MEMORY_DB" "SELECT substr(content, 1, 50) FROM learnings WHERE id = '$nid_esc';")
                        log_info "[DRY RUN] Would remove near-dup $nid (keep $oldest_id): $preview..."
                    else
                        # Merge tags
                        local keep_tags remove_tags
                        keep_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$oldest_esc';")
                        remove_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$nid_esc';")
                        if [[ -n "$remove_tags" ]]; then
                            local merged_tags
                            merged_tags=$(echo "$keep_tags,$remove_tags" | tr ',' '\n' | sort -u | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
                            local merged_tags_esc="${merged_tags//"'"/"''"}"
                            db "$MEMORY_DB" "UPDATE learnings SET tags = '$merged_tags_esc' WHERE id = '$oldest_esc';"
                        fi

                        # Re-point relations and delete
                        db "$MEMORY_DB" "UPDATE learning_relations SET supersedes_id = '$oldest_esc' WHERE supersedes_id = '$nid_esc';" 2>/dev/null || true
                        db "$MEMORY_DB" "DELETE FROM learning_relations WHERE id = '$nid_esc';" 2>/dev/null || true
                        db "$MEMORY_DB" "DELETE FROM learning_access WHERE id = '$nid_esc';"
                        db "$MEMORY_DB" "DELETE FROM learnings WHERE id = '$nid_esc';"
                    fi
                    near_removed=$((near_removed + 1))
                done
            done <<< "$near_groups"
        fi
    fi

    local total_removed=$((exact_removed + near_removed))

    if [[ "$total_removed" -eq 0 ]]; then
        log_success "No duplicates found"
    elif [[ "$dry_run" == true ]]; then
        log_info "[DRY RUN] Would remove $total_removed duplicates ($exact_removed exact, $near_removed near)"
    else
        # Rebuild FTS index
        db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"
        log_success "Removed $total_removed duplicates ($exact_removed exact, $near_removed near)"
    fi

    return 0
}

#######################################
# Prune old/stale entries
#######################################
cmd_prune() {
    local older_than_days=$DEFAULT_MAX_AGE_DAYS
    local dry_run=false
    local keep_accessed=true
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --older-than-days) older_than_days="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            --include-accessed) keep_accessed=false; shift ;;
            *) shift ;;
        esac
    done
    
    init_db
    
    # Build query to find stale entries
    local count
    if [[ "$keep_accessed" == true ]]; then
        count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-$older_than_days days') AND a.id IS NULL;")
    else
        count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE created_at < datetime('now', '-$older_than_days days');")
    fi
    
    if [[ "$count" -eq 0 ]]; then
        log_success "No entries to prune"
        return 0
    fi
    
    if [[ "$dry_run" == true ]]; then
        log_info "[DRY RUN] Would delete $count entries"
        echo ""
        if [[ "$keep_accessed" == true ]]; then
            db "$MEMORY_DB" <<EOF
SELECT l.id, l.type, substr(l.content, 1, 50) || '...' as preview, l.created_at
FROM learnings l
LEFT JOIN learning_access a ON l.id = a.id
WHERE l.created_at < datetime('now', '-$older_than_days days') AND a.id IS NULL
LIMIT 20;
EOF
        else
            db "$MEMORY_DB" <<EOF
SELECT id, type, substr(content, 1, 50) || '...' as preview, created_at
FROM learnings 
WHERE created_at < datetime('now', '-$older_than_days days')
LIMIT 20;
EOF
        fi
    else
        # Validate older_than_days is a positive integer
        if ! [[ "$older_than_days" =~ ^[0-9]+$ ]]; then
            log_error "--older-than-days must be a positive integer"
            return 1
        fi

        # Backup before bulk delete (t188)
        local prune_backup
        prune_backup=$(backup_sqlite_db "$MEMORY_DB" "pre-prune")
        if [[ $? -ne 0 || -z "$prune_backup" ]]; then
            log_warn "Backup failed before prune — proceeding cautiously"
        fi
        
        # Use efficient single DELETE with subquery
        local subquery
        if [[ "$keep_accessed" == true ]]; then
            subquery="SELECT l.id FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-$older_than_days days') AND a.id IS NULL"
        else
            subquery="SELECT id FROM learnings WHERE created_at < datetime('now', '-$older_than_days days')"
        fi
        
        # Delete from all tables using the subquery (much faster than loop)
        # Clean up relations first to avoid orphaned references
        db "$MEMORY_DB" "DELETE FROM learning_relations WHERE id IN ($subquery);"
        db "$MEMORY_DB" "DELETE FROM learning_relations WHERE supersedes_id IN ($subquery);"
        db "$MEMORY_DB" "DELETE FROM learning_access WHERE id IN ($subquery);"
        db "$MEMORY_DB" "DELETE FROM learnings WHERE id IN ($subquery);"
        
        log_success "Pruned $count stale entries"
        
        # Rebuild FTS index
        db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"
        log_info "Rebuilt search index"

        # Clean up old backups (t188)
        cleanup_sqlite_backups "$MEMORY_DB" 5
    fi
}

#######################################
# Consolidate similar memories
# Merges memories with similar content to reduce redundancy
#######################################
cmd_consolidate() {
    local dry_run=false
    local similarity_threshold=0.5
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --threshold) similarity_threshold="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    
    # Validate similarity_threshold is a valid decimal
    if ! [[ "$similarity_threshold" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        log_error "--threshold must be a decimal number (e.g., 0.5)"
        return 1
    fi
    
    init_db
    
    log_info "Analyzing memories for consolidation..."
    
    # Find potential duplicates using FTS5 similarity
    # Group by type and look for similar content
    local duplicates
    duplicates=$(db "$MEMORY_DB" <<EOF
SELECT 
    l1.id as id1, 
    l2.id as id2,
    l1.type,
    substr(l1.content, 1, 50) as content1,
    substr(l2.content, 1, 50) as content2,
    l1.created_at as created1,
    l2.created_at as created2
FROM learnings l1
JOIN learnings l2 ON l1.type = l2.type 
    AND l1.id < l2.id
    AND l1.content != l2.content
WHERE (
    -- Check for significant word overlap
    (SELECT COUNT(*) FROM (
        SELECT value FROM json_each('["' || replace(lower(l1.content), ' ', '","') || '"]')
        INTERSECT
        SELECT value FROM json_each('["' || replace(lower(l2.content), ' ', '","') || '"]')
    )) * 2.0 / (
        length(l1.content) - length(replace(l1.content, ' ', '')) + 1 +
        length(l2.content) - length(replace(l2.content, ' ', '')) + 1
    ) > $similarity_threshold
)
LIMIT 20;
EOF
)
    
    if [[ -z "$duplicates" ]]; then
        log_success "No similar memories found for consolidation"
        return 0
    fi
    
    local count
    count=$(echo "$duplicates" | wc -l | tr -d ' ')
    
    if [[ "$dry_run" == true ]]; then
        log_info "[DRY RUN] Found $count potential consolidation pairs:"
        echo ""
        echo "$duplicates" | while IFS='|' read -r id1 id2 type content1 content2 created1 created2; do
            echo "  [$type] #$id1 vs #$id2"
            echo "    1: $content1..."
            echo "    2: $content2..."
            echo ""
        done
        echo ""
        log_info "Run without --dry-run to consolidate"
    else
        # Backup before consolidation deletes (t188)
        local consolidate_backup
        consolidate_backup=$(backup_sqlite_db "$MEMORY_DB" "pre-consolidate")
        if [[ $? -ne 0 || -z "$consolidate_backup" ]]; then
            log_warn "Backup failed before consolidation — proceeding cautiously"
        fi

        local consolidated=0
        
        # Use here-string instead of pipe to avoid subshell variable scope issue
        while IFS='|' read -r id1 id2 type content1 content2 created1 created2; do
            [[ -z "$id1" ]] && continue
            
            # Keep the older entry (more established), merge tags
            local older_id newer_id
            if [[ "$created1" < "$created2" ]]; then
                older_id="$id1"
                newer_id="$id2"
            else
                older_id="$id2"
                newer_id="$id1"
            fi
            
            # Escape IDs for SQL injection prevention
            local older_id_esc="${older_id//"'"/"''"}"
            local newer_id_esc="${newer_id//"'"/"''"}"
            
            # Merge tags from newer into older
            local older_tags newer_tags
            older_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$older_id_esc';")
            newer_tags=$(db "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$newer_id_esc';")
            
            if [[ -n "$newer_tags" ]]; then
                local merged_tags
                merged_tags=$(echo "$older_tags,$newer_tags" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
                # Escape merged_tags for SQL injection prevention
                local merged_tags_esc="${merged_tags//"'"/"''"}"
                db "$MEMORY_DB" "UPDATE learnings SET tags = '$merged_tags_esc' WHERE id = '$older_id_esc';"
            fi
            
            # Transfer access history
            db "$MEMORY_DB" "UPDATE learning_access SET id = '$older_id_esc' WHERE id = '$newer_id_esc' AND NOT EXISTS (SELECT 1 FROM learning_access WHERE id = '$older_id_esc');" || echo "[WARN] Failed to transfer access history from $newer_id_esc to $older_id_esc" >&2
            
            # Re-point relations that referenced the deleted memory to the surviving one
            db "$MEMORY_DB" "UPDATE learning_relations SET supersedes_id = '$older_id_esc' WHERE supersedes_id = '$newer_id_esc';"
            db "$MEMORY_DB" "DELETE FROM learning_relations WHERE id = '$newer_id_esc';"
            
            # Delete the newer duplicate
            db "$MEMORY_DB" "DELETE FROM learning_access WHERE id = '$newer_id_esc';"
            db "$MEMORY_DB" "DELETE FROM learnings WHERE id = '$newer_id_esc';"
            
            consolidated=$((consolidated + 1))
        done <<< "$duplicates"
        
        # Rebuild FTS index
        db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"
        
        log_success "Consolidated $consolidated memory pairs"

        # Clean up old backups (t188)
        cleanup_sqlite_backups "$MEMORY_DB" 5
    fi
}

#######################################
# Prune repetitive pattern entries by keyword (t230)
# Consolidates entries where the same error/pattern keyword appears
# across many tasks, keeping only a few representative entries
#######################################
cmd_prune_patterns() {
    local keyword=""
    local dry_run=false
    local keep_count=3
    local types="FAILURE_PATTERN,ERROR_FIX,FAILED_APPROACH"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keyword) keyword="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            --keep) keep_count="$2"; shift 2 ;;
            --types) types="$2"; shift 2 ;;
            *) 
                if [[ -z "$keyword" ]]; then
                    keyword="$1"
                fi
                shift ;;
        esac
    done

    if [[ -z "$keyword" ]]; then
        log_error "Usage: memory-helper.sh prune-patterns <keyword> [--keep N] [--dry-run]"
        log_error "Example: memory-helper.sh prune-patterns clean_exit_no_signal --keep 3"
        return 1
    fi

    # Validate keep_count is a positive integer
    if ! [[ "$keep_count" =~ ^[1-9][0-9]*$ ]]; then
        log_error "--keep must be a positive integer (got: $keep_count)"
        return 1
    fi

    init_db

    # Build type filter SQL
    local type_sql=""
    local IFS=','
    local type_parts=()
    read -ra type_parts <<< "$types"
    unset IFS
    local type_conditions=()
    for t in "${type_parts[@]}"; do
        type_conditions+=("'$t'")
    done
    type_sql=$(printf "%s," "${type_conditions[@]}")
    type_sql="${type_sql%,}"

    local escaped_keyword="${keyword//"'"/"''"}"

    # Count matching entries
    local total_count
    total_count=$(db "$MEMORY_DB" \
        "SELECT COUNT(*) FROM learnings WHERE type IN ($type_sql) AND content LIKE '%${escaped_keyword}%';")

    if [[ "$total_count" -le "$keep_count" ]]; then
        log_success "Only $total_count entries match '$keyword' (keep=$keep_count). Nothing to prune."
        return 0
    fi

    local to_remove=$((total_count - keep_count))
    log_info "Found $total_count entries matching '$keyword' across types ($types)"
    log_info "Will keep $keep_count newest entries, remove $to_remove"

    if [[ "$dry_run" == true ]]; then
        log_info "[DRY RUN] Would remove $to_remove entries. Entries to keep:"
        db "$MEMORY_DB" <<EOF
SELECT id, type, substr(content, 1, 80) || '...' as preview, created_at
FROM learnings
WHERE type IN ($type_sql) AND content LIKE '%${escaped_keyword}%'
ORDER BY created_at DESC
LIMIT $keep_count;
EOF
        echo ""
        log_info "[DRY RUN] Sample entries to remove:"
        db "$MEMORY_DB" <<EOF
SELECT id, type, substr(content, 1, 80) || '...' as preview, created_at
FROM learnings
WHERE type IN ($type_sql) AND content LIKE '%${escaped_keyword}%'
ORDER BY created_at DESC
LIMIT 5 OFFSET $keep_count;
EOF
        return 0
    fi

    # Backup before bulk delete
    local prune_backup
    prune_backup=$(backup_sqlite_db "$MEMORY_DB" "pre-prune-patterns")
    if [[ $? -ne 0 || -z "$prune_backup" ]]; then
        log_warn "Backup failed before prune-patterns — proceeding cautiously"
    fi

    # Get IDs to keep (newest N per type combination)
    local keep_ids
    keep_ids=$(db "$MEMORY_DB" <<EOF
SELECT id FROM learnings
WHERE type IN ($type_sql) AND content LIKE '%${escaped_keyword}%'
ORDER BY created_at DESC
LIMIT $keep_count;
EOF
    )

    # Build exclusion list
    local exclude_sql=""
    while IFS= read -r kid; do
        [[ -z "$kid" ]] && continue
        local kid_esc="${kid//"'"/"''"}"
        if [[ -z "$exclude_sql" ]]; then
            exclude_sql="'$kid_esc'"
        else
            exclude_sql="$exclude_sql,'$kid_esc'"
        fi
    done <<< "$keep_ids"

    # Delete matching entries except the ones we're keeping
    local delete_where="type IN ($type_sql) AND content LIKE '%${escaped_keyword}%'"
    if [[ -n "$exclude_sql" ]]; then
        delete_where="$delete_where AND id NOT IN ($exclude_sql)"
    fi

    # Clean up relations first
    db "$MEMORY_DB" "DELETE FROM learning_relations WHERE id IN (SELECT id FROM learnings WHERE $delete_where);" 2>/dev/null || true
    db "$MEMORY_DB" "DELETE FROM learning_relations WHERE supersedes_id IN (SELECT id FROM learnings WHERE $delete_where);" 2>/dev/null || true
    db "$MEMORY_DB" "DELETE FROM learning_access WHERE id IN (SELECT id FROM learnings WHERE $delete_where);"
    db "$MEMORY_DB" "DELETE FROM learnings WHERE $delete_where;"

    # Rebuild FTS index
    db "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"

    log_success "Pruned $to_remove repetitive '$keyword' entries (kept $keep_count newest)"

    # Clean up old backups
    cleanup_sqlite_backups "$MEMORY_DB" 5

    return 0
}

#######################################
# Export memories
#######################################
cmd_export() {
    local format="json"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) format="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    
    init_db
    
    case "$format" in
        json)
            db -json "$MEMORY_DB" "SELECT l.*, COALESCE(a.last_accessed_at, '') as last_accessed_at, COALESCE(a.access_count, 0) as access_count FROM learnings l LEFT JOIN learning_access a ON l.id = a.id ORDER BY l.created_at DESC;"
            ;;
        toon)
            # TOON format for token efficiency
            local count
            count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings;")
            echo "learnings[$count]{id,type,confidence,content,tags,created_at}:"
            db -separator ',' "$MEMORY_DB" "SELECT id, type, confidence, content, tags, created_at FROM learnings ORDER BY created_at DESC;" | while read -r line; do
                echo "  $line"
            done
            ;;
        *)
            log_error "Unknown format: $format (use json or toon)"
            return 1
            ;;
    esac
}

#######################################
# List all memory namespaces
#######################################
cmd_namespaces() {
    local output_format="table"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) output_format="$2"; shift 2 ;;
            --json) output_format="json"; shift ;;
            *) shift ;;
        esac
    done

    local ns_dir="$MEMORY_BASE_DIR/namespaces"

    if [[ ! -d "$ns_dir" ]]; then
        log_info "No namespaces configured"
        echo ""
        echo "Create one with:"
        echo "  memory-helper.sh --namespace my-runner store --content \"learning\""
        return 0
    fi

    local namespaces
    namespaces=$(find "$ns_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

    if [[ -z "$namespaces" ]]; then
        log_info "No namespaces configured"
        return 0
    fi

    if [[ "$output_format" == "json" ]]; then
        echo "["
        local first=true
        for ns_path in $namespaces; do
            local ns_name
            ns_name=$(basename "$ns_path")
            local ns_db="$ns_path/memory.db"
            local count=0
            if [[ -f "$ns_db" ]]; then
                count=$(db "$ns_db" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
            fi
            if [[ "$first" == true ]]; then
                first=false
            else
                echo ","
            fi
            printf '  {"namespace": "%s", "entries": %d, "path": "%s"}' "$ns_name" "$count" "$ns_path"
        done
        echo ""
        echo "]"
        return 0
    fi

    echo ""
    echo "=== Memory Namespaces ==="
    echo ""

    # Global DB stats
    local global_db
    global_db=$(global_db_path)
    local global_count=0
    if [[ -f "$global_db" ]]; then
        global_count=$(db "$global_db" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
    fi
    printf "  %-25s %s entries\n" "(global)" "$global_count"

    for ns_path in $namespaces; do
        local ns_name
        ns_name=$(basename "$ns_path")
        local ns_db="$ns_path/memory.db"
        local count=0
        if [[ -f "$ns_db" ]]; then
            count=$(db "$ns_db" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
        fi
        printf "  %-25s %s entries\n" "$ns_name" "$count"
    done

    echo ""
    return 0
}

#######################################
# Prune orphaned namespaces
# Removes namespace directories that have no matching runner
#######################################
cmd_namespaces_prune() {
    local dry_run=false
    local runners_dir="${AIDEVOPS_RUNNERS_DIR:-$HOME/.aidevops/.agent-workspace/runners}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            *) shift ;;
        esac
    done

    local ns_dir="$MEMORY_BASE_DIR/namespaces"

    if [[ ! -d "$ns_dir" ]]; then
        log_info "No namespaces to prune"
        return 0
    fi

    local namespaces
    namespaces=$(find "$ns_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

    if [[ -z "$namespaces" ]]; then
        log_info "No namespaces to prune"
        return 0
    fi

    local orphaned=0
    local kept=0

    for ns_path in $namespaces; do
        local ns_name
        ns_name=$(basename "$ns_path")
        local runner_path="$runners_dir/$ns_name"

        if [[ -d "$runner_path" && -f "$runner_path/config.json" ]]; then
            kept=$((kept + 1))
            continue
        fi

        local ns_db="$ns_path/memory.db"
        local count=0
        if [[ -f "$ns_db" ]]; then
            count=$(db "$ns_db" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
        fi

        if [[ "$dry_run" == true ]]; then
            log_warn "[DRY RUN] Would remove orphaned namespace: $ns_name ($count entries)"
        else
            rm -rf "$ns_path"
            log_info "Removed orphaned namespace: $ns_name ($count entries)"
        fi
        orphaned=$((orphaned + 1))
    done

    if [[ "$orphaned" -eq 0 ]]; then
        log_success "No orphaned namespaces found ($kept active)"
    elif [[ "$dry_run" == true ]]; then
        log_warn "[DRY RUN] Would remove $orphaned orphaned namespaces ($kept active)"
    else
        log_success "Removed $orphaned orphaned namespaces ($kept active)"
    fi

    return 0
}

#######################################
# Migrate memories between namespaces
# Copies entries from one namespace (or global) to another
#######################################
cmd_namespaces_migrate() {
    local from_ns=""
    local to_ns=""
    local dry_run=false
    local move=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) from_ns="$2"; shift 2 ;;
            --to) to_ns="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            --move) move=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$from_ns" || -z "$to_ns" ]]; then
        log_error "Both --from and --to are required"
        echo "Usage: memory-helper.sh namespaces migrate --from <ns|global> --to <ns|global> [--dry-run] [--move]"
        return 1
    fi

    # Resolve source DB
    local from_db
    if [[ "$from_ns" == "global" ]]; then
        from_db="$MEMORY_BASE_DIR/memory.db"
    else
        from_db="$MEMORY_BASE_DIR/namespaces/$from_ns/memory.db"
    fi

    if [[ ! -f "$from_db" ]]; then
        log_error "Source not found: $from_db"
        return 1
    fi

    # Resolve target DB
    local to_db
    local to_dir
    if [[ "$to_ns" == "global" ]]; then
        to_db="$MEMORY_BASE_DIR/memory.db"
        to_dir="$MEMORY_BASE_DIR"
    else
        to_dir="$MEMORY_BASE_DIR/namespaces/$to_ns"
        to_db="$to_dir/memory.db"
    fi

    # Count entries to migrate
    local count
    count=$(db "$from_db" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        log_info "No entries to migrate from $from_ns"
        return 0
    fi

    if [[ "$dry_run" == true ]]; then
        log_info "[DRY RUN] Would migrate $count entries from '$from_ns' to '$to_ns'"
        if [[ "$move" == true ]]; then
            log_info "[DRY RUN] Would delete entries from source after migration"
        fi
        return 0
    fi

    # Ensure target DB exists with correct schema
    mkdir -p "$to_dir"
    local saved_dir="$MEMORY_DIR"
    local saved_db="$MEMORY_DB"
    MEMORY_DIR="$to_dir"
    MEMORY_DB="$to_db"
    init_db
    MEMORY_DIR="$saved_dir"
    MEMORY_DB="$saved_db"

    # Migrate using ATTACH DATABASE
    db "$to_db" <<EOF
ATTACH DATABASE '$from_db' AS source;

-- Insert entries that don't already exist (by id)
INSERT OR IGNORE INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source)
SELECT id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source
FROM source.learnings;

-- Migrate access tracking
INSERT OR IGNORE INTO learning_access (id, last_accessed_at, access_count)
SELECT id, last_accessed_at, access_count
FROM source.learning_access;

-- Migrate relations
INSERT OR IGNORE INTO learning_relations (id, supersedes_id, relation_type, created_at)
SELECT id, supersedes_id, relation_type, created_at
FROM source.learning_relations;

DETACH DATABASE source;
EOF

    log_success "Migrated $count entries from '$from_ns' to '$to_ns'"

    # If --move, delete from source (with backup — t188)
    if [[ "$move" == true ]]; then
        backup_sqlite_db "$from_db" "pre-move-to-${to_ns}" >/dev/null 2>&1 || log_warn "Backup of source failed before move"
        db "$from_db" "DELETE FROM learning_relations;"
        db "$from_db" "DELETE FROM learning_access;"
        db "$from_db" "DELETE FROM learnings;"
        db "$from_db" "INSERT INTO learnings(learnings) VALUES('rebuild');"
        log_info "Cleared source: $from_ns"
    fi

    return 0
}

#######################################
# Show auto-capture log
# Convenience command: recall --recent --auto-only
#######################################
cmd_log() {
    local limit=20
    local format="text"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit|-l) limit="$2"; shift 2 ;;
            --json) format="json"; shift ;;
            --format) format="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    
    init_db
    
    local results
    results=$(db -json "$MEMORY_DB" "SELECT l.id, l.content, l.type, l.tags, l.confidence, l.created_at, l.source, COALESCE(a.last_accessed_at, '') as last_accessed_at, COALESCE(a.access_count, 0) as access_count, COALESCE(a.auto_captured, 0) as auto_captured FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE COALESCE(a.auto_captured, 0) = 1 ORDER BY l.created_at DESC LIMIT $limit;")
    
    if [[ "$format" == "json" ]]; then
        echo "$results"
    else
        local header_suffix=""
        if [[ -n "$MEMORY_NAMESPACE" ]]; then
            header_suffix=" [namespace: $MEMORY_NAMESPACE]"
        fi
        
        echo ""
        echo "=== Auto-Capture Log (last $limit)${header_suffix} ==="
        echo ""
        
        if [[ -z "$results" || "$results" == "[]" ]]; then
            log_info "No auto-captured memories yet."
            echo ""
            echo "Auto-capture stores memories when AI agents detect:"
            echo "  - Working solutions after debugging"
            echo "  - Failed approaches to avoid"
            echo "  - Architecture decisions"
            echo "  - Tool configurations"
            echo ""
            echo "Use --auto flag when storing: memory-helper.sh store --auto --content \"...\""
        else
            echo "$results" | format_results_text
            
            # Show summary
            local total_auto
            total_auto=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learning_access WHERE auto_captured = 1;")
            echo "---"
            echo "Total auto-captured: $total_auto"
        fi
    fi
    return 0
}

#######################################
# Show help
#######################################
cmd_help() {
    cat <<'EOF'
memory-helper.sh - Lightweight memory system for aidevops

Inspired by Supermemory's architecture for relational versioning,
dual timestamps, and contextual disambiguation.

USAGE:
    memory-helper.sh [--namespace NAME] <command> [options]

COMMANDS:
    store       Store a new learning (with automatic deduplication)
    recall      Search and retrieve learnings
    log         Show recent auto-captured memories (alias for recall --recent --auto-only)
    history     Show version history for a memory (ancestors/descendants)
    latest      Find the latest version of a memory chain
    stats       Show memory statistics
    validate    Check for stale/duplicate entries (with detailed reports)
    prune       Remove old entries (auto-runs every 24h on store)
    prune-patterns  Remove repetitive pattern entries by keyword (e.g., clean_exit_no_signal)
    dedup       Remove exact and near-duplicate entries
    consolidate Merge similar memories to reduce redundancy
    export      Export all memories
    graduate    Promote validated memories into shared docs (delegates to memory-graduate-helper.sh)
    namespaces  List all memory namespaces
    help        Show this help

GLOBAL OPTIONS:
    --namespace <name>    Use isolated memory namespace (per-runner)
                          Creates DB at: memory/namespaces/<name>/memory.db

STORE OPTIONS:
    --content <text>      Learning content (required)
    --type <type>         Learning type (default: WORKING_SOLUTION)
    --tags <tags>         Comma-separated tags
    --confidence <level>  high, medium, or low (default: medium)
    --session-id <id>     Session identifier
    --project <path>      Project path
    --event-date <ISO>    When the event occurred (default: now)
    --supersedes <id>     ID of memory this updates/extends/derives from
    --relation <type>     Relation type: updates, extends, derives
    --auto                Mark as auto-captured (sets source=auto, tracked separately)

VALID TYPES:
    WORKING_SOLUTION, FAILED_APPROACH, CODEBASE_PATTERN, USER_PREFERENCE,
    TOOL_CONFIG, DECISION, CONTEXT, ARCHITECTURAL_DECISION, ERROR_FIX,
    OPEN_THREAD, SUCCESS_PATTERN, FAILURE_PATTERN

RELATION TYPES (inspired by Supermemory):
    updates   - New info supersedes old (state mutation)
                e.g., "My favorite color is now green" updates "...is blue"
    extends   - Adds detail without contradiction (refinement)
                e.g., Adding job title to existing employment memory
    derives   - Second-order inference from combining memories
                e.g., Inferring "works remotely" from location + job info

RECALL OPTIONS:
    --query <text>        Search query (required unless --recent)
    --limit <n>           Max results (default: 5)
    --type <type>         Filter by type
    --max-age-days <n>    Only recent entries
    --project <path>      Filter by project path
    --recent [n]          Show n most recent entries (default: 10)
    --shared              Also search global memory (when using --namespace)
    --auto-only           Show only auto-captured memories
    --manual-only         Show only manually stored memories
    --semantic            Use semantic similarity search (requires embeddings setup)
    --similar             Alias for --semantic
    --hybrid              Combine FTS5 keyword + semantic search using RRF
    --stats               Show memory statistics
    --json                Output as JSON

PRUNE OPTIONS:
    --older-than-days <n> Age threshold (default: 90)
    --dry-run             Show what would be deleted
    --include-accessed    Also prune accessed entries

PRUNE-PATTERNS OPTIONS:
    <keyword>             Error/pattern keyword to match (required)
    --keep <n>            Number of newest entries to keep (default: 3)
    --types <list>        Comma-separated types to search (default: FAILURE_PATTERN,ERROR_FIX,FAILED_APPROACH)
    --dry-run             Show what would be removed without deleting

DEDUP OPTIONS:
    --dry-run             Show what would be removed without deleting
    --exact-only          Only remove exact duplicates (skip near-duplicates)

DEDUPLICATION:
    - Store automatically detects and skips duplicate content
    - Exact matches: identical content string + same type
    - Near matches: same content after normalizing case/punctuation/whitespace
    - When a duplicate is detected on store, the existing entry's access count
      is incremented and its ID is returned
    - Use 'dedup' command to clean up existing duplicates in bulk

AUTO-PRUNING:
    - Runs automatically on every store (at most once per 24 hours)
    - Removes entries older than 90 days that have never been accessed
    - Frequently accessed memories are preserved regardless of age
    - Manual prune available via 'prune' command for custom thresholds

DUAL TIMESTAMPS:
    - created_at:  When the memory was stored in the database
    - event_date:  When the event described actually occurred
    This enables temporal reasoning like "what happened last week?"

PRIVACY FILTERS:
    - <private>...</private> tags are stripped from content before storage
    - Content matching secret patterns (API keys, tokens) is rejected
    - Use privacy-filter-helper.sh for comprehensive scanning

STALENESS PREVENTION:
    - Entries track created_at and last_accessed_at
    - Recall updates last_accessed_at (used = valuable)
    - Prune removes old entries that were never accessed
    - Validate warns about potentially stale entries

EXAMPLES:
    # Store a learning
    memory-helper.sh store --content "Use FTS5 for fast search" --type WORKING_SOLUTION

    # Store with event date (when it happened, not when stored)
    memory-helper.sh store --content "Fixed CORS issue" --event-date "2024-01-15T10:00:00Z"

    # Update an existing memory (creates version chain)
    memory-helper.sh store --content "Favorite color is now green" \
        --supersedes mem_xxx --relation updates

    # Extend a memory with more detail
    memory-helper.sh store --content "Job title: Senior Engineer" \
        --supersedes mem_yyy --relation extends

    # View version history
    memory-helper.sh history mem_xxx

    # Find latest version in a chain
    memory-helper.sh latest mem_xxx

    # Store an auto-captured memory (from AI agent)
    memory-helper.sh store --auto --content "Fixed CORS with nginx headers" --type WORKING_SOLUTION

    # Recall learnings (keyword search - default)
    memory-helper.sh recall --query "database search" --limit 10

    # Recall only auto-captured memories
    memory-helper.sh recall --recent --auto-only

    # Recall only manually stored memories
    memory-helper.sh recall --query "cors" --manual-only

    # Recall learnings (semantic similarity - opt-in, requires setup)
    memory-helper.sh recall --query "how to optimize queries" --semantic

    # Recall learnings (hybrid FTS5+semantic - best results)
    memory-helper.sh recall --query "authentication patterns" --hybrid

    # Check for stale entries
    memory-helper.sh validate

    # Clean up old unused entries
    memory-helper.sh prune --older-than-days 60 --dry-run

    # Consolidate similar memories
    memory-helper.sh consolidate --dry-run

    # Remove duplicate memories (preview first)
    memory-helper.sh dedup --dry-run
    memory-helper.sh dedup
    memory-helper.sh dedup --exact-only

NAMESPACE EXAMPLES:
    # Store in a runner-specific namespace
    memory-helper.sh --namespace code-reviewer store --content "Prefer explicit error handling"

    # Recall from namespace only
    memory-helper.sh --namespace code-reviewer recall "error handling"

    # Recall from namespace + global (shared access)
    memory-helper.sh --namespace code-reviewer recall "error handling" --shared

    # View namespace stats
    memory-helper.sh --namespace code-reviewer stats

    # List all namespaces
    memory-helper.sh namespaces

    # Remove orphaned namespaces (no matching runner)
    memory-helper.sh namespaces prune --dry-run
    memory-helper.sh namespaces prune

    # Migrate entries between namespaces
    memory-helper.sh namespaces migrate --from code-reviewer --to global --dry-run
    memory-helper.sh namespaces migrate --from code-reviewer --to global
    memory-helper.sh namespaces migrate --from global --to seo-analyst --move
EOF
    return 0
}

#######################################
# Main entry point
# Parses global --namespace flag before dispatching to commands
#######################################
main() {
    # Parse global flags before command
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --namespace|-n)
                if [[ $# -lt 2 ]]; then
                    log_error "--namespace requires a value"
                    return 1
                fi
                resolve_namespace "$2" || return 1
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done

    local command="${1:-help}"
    shift || true
    
    # Show namespace context if set
    if [[ -n "$MEMORY_NAMESPACE" ]]; then
        log_info "Using namespace: $MEMORY_NAMESPACE ($MEMORY_DB)"
    fi

    case "$command" in
        store) cmd_store "$@" ;;
        recall) cmd_recall "$@" ;;
        log) cmd_log "$@" ;;
        history) cmd_history "$@" ;;
        latest) cmd_latest "$@" ;;
        stats) cmd_stats ;;
        validate) cmd_validate ;;
        prune) cmd_prune "$@" ;;
        prune-patterns) cmd_prune_patterns "$@" ;;
        dedup) cmd_dedup "$@" ;;
        consolidate) cmd_consolidate "$@" ;;
        export) cmd_export "$@" ;;
        graduate)
            # Delegate to memory-graduate-helper.sh
            local graduate_script
            graduate_script="$(dirname "$0")/memory-graduate-helper.sh"
            if [[ ! -x "$graduate_script" ]]; then
                log_error "Graduate helper not found: $graduate_script"
                return 1
            fi
            "$graduate_script" "$@"
            ;;
        namespaces)
            # Support subcommands: namespaces [list|prune|migrate]
            local ns_subcmd="${1:-list}"
            case "$ns_subcmd" in
                prune) shift; cmd_namespaces_prune "$@" ;;
                migrate) shift; cmd_namespaces_migrate "$@" ;;
                list|--json|--format) cmd_namespaces "$@" ;;
                *) cmd_namespaces "$@" ;;
            esac
            ;;
        help|--help|-h) cmd_help ;;
        *)
            log_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
exit $?
