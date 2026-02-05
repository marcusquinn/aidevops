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

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

#######################################
# Print colored message
#######################################
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

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
# Get the global (non-namespaced) DB path
#######################################
global_db_path() {
    echo "$MEMORY_BASE_DIR/memory.db"
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
        
        sqlite3 "$MEMORY_DB" <<'EOF'
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

-- Separate table for access tracking (FTS5 doesn't support UPDATE)
CREATE TABLE IF NOT EXISTS learning_access (
    id TEXT PRIMARY KEY,
    last_accessed_at TEXT,
    access_count INTEGER DEFAULT 0
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
    return 0
}

#######################################
# Migrate existing database to new schema
#######################################
migrate_db() {
    # Check if event_date column exists in FTS5 table
    # FTS5 tables don't support ALTER TABLE, so we check via pragma
    local has_event_date
    has_event_date=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM pragma_table_info('learnings') WHERE name='event_date';" 2>/dev/null || echo "0")
    
    if [[ "$has_event_date" == "0" ]]; then
        log_info "Migrating database to add event_date and relations..."
        
        # For FTS5, we need to recreate the table
        sqlite3 "$MEMORY_DB" <<'EOF'
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
    sqlite3 "$MEMORY_DB" <<'EOF'
CREATE TABLE IF NOT EXISTS learning_relations (
    id TEXT PRIMARY KEY,
    supersedes_id TEXT,
    relation_type TEXT CHECK(relation_type IN ('updates', 'extends', 'derives')),
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
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
        exists=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$escaped_supersedes';")
        if [[ "$exists" == "0" ]]; then
            log_error "Supersedes ID not found: $supersedes_id"
            return 1
        fi
    fi
    
    sqlite3 "$MEMORY_DB" <<EOF
INSERT INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source)
VALUES ('$id', '$session_id', '$escaped_content', '$type', '$escaped_tags', '$confidence', '$created_at', '$event_date', '$escaped_project', '$source');
EOF
    
    # Store relation if provided
    if [[ -n "$supersedes_id" ]]; then
        sqlite3 "$MEMORY_DB" <<EOF
INSERT INTO learning_relations (id, supersedes_id, relation_type, created_at)
VALUES ('$id', '$escaped_supersedes', '$relation_type', '$created_at');
EOF
        log_info "Relation: $id $relation_type $supersedes_id"
    fi
    
    log_success "Stored learning: $id"
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
    local shared_mode=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --query|-q) query="$2"; shift 2 ;;
            --limit|-l) limit="$2"; shift 2 ;;
            --type|-t) type_filter="$2"; shift 2 ;;
            --max-age-days) max_age_days="$2"; shift 2 ;;
            --project|-p) project_filter="$2"; shift 2 ;;
            --recent) recent_mode=true; limit="${2:-10}"; shift; [[ "${1:-}" =~ ^[0-9]+$ ]] && shift ;;
            --semantic|--similar) semantic_mode=true; shift ;;
            --shared) shared_mode=true; shift ;;
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
    
    # Handle --recent mode (no query required)
    if [[ "$recent_mode" == true ]]; then
        local results
        results=$(sqlite3 -json "$MEMORY_DB" "SELECT l.id, l.content, l.type, l.tags, l.confidence, l.created_at, COALESCE(a.last_accessed_at, '') as last_accessed_at, COALESCE(a.access_count, 0) as access_count FROM learnings l LEFT JOIN learning_access a ON l.id = a.id ORDER BY l.created_at DESC LIMIT $limit;")
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
    
    # Handle --semantic mode (delegate to embeddings helper)
    if [[ "$semantic_mode" == true ]]; then
        local embeddings_script
        embeddings_script="$(dirname "$0")/memory-embeddings-helper.sh"
        if [[ ! -x "$embeddings_script" ]]; then
            log_error "Semantic search not available. Run: memory-embeddings-helper.sh setup"
            return 1
        fi
        local semantic_args=("search" "$query" "--limit" "$limit")
        if [[ "$format" == "json" ]]; then
            semantic_args+=("--json")
        fi
        "$embeddings_script" "${semantic_args[@]}"
        return $?
    fi
    
    # Escape query for FTS5 - escape both single and double quotes
    local escaped_query="${query//"'"/"''"}"
    escaped_query="${escaped_query//\"/\"\"}"
    
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
    
    # Search using FTS5 with BM25 ranking
    # Note: FTS5 tables require special handling - can't use table alias in bm25()
    local results
    results=$(sqlite3 -json "$MEMORY_DB" <<EOF
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
    
    # Update access tracking for returned results (prevents staleness)
    if [[ -n "$results" && "$results" != "[]" ]]; then
        local ids
        ids=$(echo "$results" | extract_ids_from_json)
        if [[ -n "$ids" ]]; then
            while IFS= read -r id; do
                [[ -z "$id" ]] && continue
                sqlite3 "$MEMORY_DB" <<EOF
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
            shared_results=$(sqlite3 -json "$global_db" <<EOF
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
    exists=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE id = '$escaped_id';")
    if [[ "$exists" == "0" ]]; then
        log_error "Memory not found: $memory_id"
        return 1
    fi
    
    echo ""
    echo "=== Version History for $memory_id ==="
    echo ""
    
    # Show the current memory
    echo "Current:"
    sqlite3 "$MEMORY_DB" <<EOF
SELECT '  [' || type || '] ' || substr(content, 1, 80) || '...'
FROM learnings WHERE id = '$escaped_id';
SELECT '  Created: ' || created_at || ' | Event: ' || COALESCE(event_date, 'N/A')
FROM learnings WHERE id = '$escaped_id';
EOF
    
    # Show what this memory supersedes (ancestors)
    echo ""
    echo "Supersedes (ancestors):"
    local ancestors
    ancestors=$(sqlite3 "$MEMORY_DB" <<EOF
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
    descendants=$(sqlite3 "$MEMORY_DB" <<EOF
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
    latest_id=$(sqlite3 "$MEMORY_DB" <<EOF
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
    sqlite3 "$MEMORY_DB" <<EOF
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
    
    sqlite3 "$MEMORY_DB" <<'EOF'
SELECT 'Total learnings' as metric, COUNT(*) as value FROM learnings
UNION ALL
SELECT 'By type: ' || type, COUNT(*) FROM learnings GROUP BY type
UNION ALL
SELECT 'Never accessed', COUNT(*) FROM learnings l 
    LEFT JOIN learning_access a ON l.id = a.id WHERE a.id IS NULL
UNION ALL
SELECT 'High confidence', COUNT(*) FROM learnings WHERE confidence = 'high';
EOF
    
    echo ""
    
    # Show relation statistics
    echo "Relational versioning:"
    sqlite3 "$MEMORY_DB" <<'EOF'
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
    sqlite3 "$MEMORY_DB" <<'EOF'
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
    stale_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-$STALE_WARNING_DAYS days') AND a.id IS NULL;")
    
    if [[ "$stale_count" -gt 0 ]]; then
        log_warn "Found $stale_count potentially stale entries (>$STALE_WARNING_DAYS days old, never accessed)"
        echo ""
        echo "Stale entries:"
        sqlite3 "$MEMORY_DB" <<EOF
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
    
    # Check for duplicate content
    local dup_count
    dup_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM (SELECT content, COUNT(*) as cnt FROM learnings GROUP BY content HAVING cnt > 1);" 2>/dev/null || echo "0")
    
    if [[ "$dup_count" -gt 0 ]]; then
        log_warn "Found $dup_count duplicate entries"
    fi
    
    # Check database size
    local db_size
    db_size=$(du -h "$MEMORY_DB" | cut -f1)
    log_info "Database size: $db_size"
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
        count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-$older_than_days days') AND a.id IS NULL;")
    else
        count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE created_at < datetime('now', '-$older_than_days days');")
    fi
    
    if [[ "$count" -eq 0 ]]; then
        log_success "No entries to prune"
        return 0
    fi
    
    if [[ "$dry_run" == true ]]; then
        log_info "[DRY RUN] Would delete $count entries"
        echo ""
        if [[ "$keep_accessed" == true ]]; then
            sqlite3 "$MEMORY_DB" <<EOF
SELECT l.id, l.type, substr(l.content, 1, 50) || '...' as preview, l.created_at
FROM learnings l
LEFT JOIN learning_access a ON l.id = a.id
WHERE l.created_at < datetime('now', '-$older_than_days days') AND a.id IS NULL
LIMIT 20;
EOF
        else
            sqlite3 "$MEMORY_DB" <<EOF
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
        
        # Use efficient single DELETE with subquery
        local subquery
        if [[ "$keep_accessed" == true ]]; then
            subquery="SELECT l.id FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-$older_than_days days') AND a.id IS NULL"
        else
            subquery="SELECT id FROM learnings WHERE created_at < datetime('now', '-$older_than_days days')"
        fi
        
        # Delete from all tables using the subquery (much faster than loop)
        # Clean up relations first to avoid orphaned references
        sqlite3 "$MEMORY_DB" "DELETE FROM learning_relations WHERE id IN ($subquery);"
        sqlite3 "$MEMORY_DB" "DELETE FROM learning_relations WHERE supersedes_id IN ($subquery);"
        sqlite3 "$MEMORY_DB" "DELETE FROM learning_access WHERE id IN ($subquery);"
        sqlite3 "$MEMORY_DB" "DELETE FROM learnings WHERE id IN ($subquery);"
        
        log_success "Pruned $count stale entries"
        
        # Rebuild FTS index
        sqlite3 "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"
        log_info "Rebuilt search index"
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
    duplicates=$(sqlite3 "$MEMORY_DB" <<EOF
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
            older_tags=$(sqlite3 "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$older_id_esc';")
            newer_tags=$(sqlite3 "$MEMORY_DB" "SELECT tags FROM learnings WHERE id = '$newer_id_esc';")
            
            if [[ -n "$newer_tags" ]]; then
                local merged_tags
                merged_tags=$(echo "$older_tags,$newer_tags" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
                # Escape merged_tags for SQL injection prevention
                local merged_tags_esc="${merged_tags//"'"/"''"}"
                sqlite3 "$MEMORY_DB" "UPDATE learnings SET tags = '$merged_tags_esc' WHERE id = '$older_id_esc';"
            fi
            
            # Transfer access history
            sqlite3 "$MEMORY_DB" "UPDATE learning_access SET id = '$older_id_esc' WHERE id = '$newer_id_esc' AND NOT EXISTS (SELECT 1 FROM learning_access WHERE id = '$older_id_esc');" 2>/dev/null || true
            
            # Re-point relations that referenced the deleted memory to the surviving one
            sqlite3 "$MEMORY_DB" "UPDATE learning_relations SET supersedes_id = '$older_id_esc' WHERE supersedes_id = '$newer_id_esc';"
            sqlite3 "$MEMORY_DB" "DELETE FROM learning_relations WHERE id = '$newer_id_esc';"
            
            # Delete the newer duplicate
            sqlite3 "$MEMORY_DB" "DELETE FROM learning_access WHERE id = '$newer_id_esc';"
            sqlite3 "$MEMORY_DB" "DELETE FROM learnings WHERE id = '$newer_id_esc';"
            
            consolidated=$((consolidated + 1))
        done <<< "$duplicates"
        
        # Rebuild FTS index
        sqlite3 "$MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');"
        
        log_success "Consolidated $consolidated memory pairs"
    fi
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
            sqlite3 -json "$MEMORY_DB" "SELECT l.*, COALESCE(a.last_accessed_at, '') as last_accessed_at, COALESCE(a.access_count, 0) as access_count FROM learnings l LEFT JOIN learning_access a ON l.id = a.id ORDER BY l.created_at DESC;"
            ;;
        toon)
            # TOON format for token efficiency
            local count
            count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings;")
            echo "learnings[$count]{id,type,confidence,content,tags,created_at}:"
            sqlite3 -separator ',' "$MEMORY_DB" "SELECT id, type, confidence, content, tags, created_at FROM learnings ORDER BY created_at DESC;" | while read -r line; do
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
                count=$(sqlite3 "$ns_db" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
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
        global_count=$(sqlite3 "$global_db" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
    fi
    printf "  %-25s %s entries\n" "(global)" "$global_count"

    for ns_path in $namespaces; do
        local ns_name
        ns_name=$(basename "$ns_path")
        local ns_db="$ns_path/memory.db"
        local count=0
        if [[ -f "$ns_db" ]]; then
            count=$(sqlite3 "$ns_db" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
        fi
        printf "  %-25s %s entries\n" "$ns_name" "$count"
    done

    echo ""
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
    store       Store a new learning
    recall      Search and retrieve learnings
    history     Show version history for a memory (ancestors/descendants)
    latest      Find the latest version of a memory chain
    stats       Show memory statistics
    validate    Check for stale/duplicate entries
    prune       Remove old entries
    consolidate Merge similar memories to reduce redundancy
    export      Export all memories
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
    --semantic            Use semantic similarity search (requires embeddings setup)
    --similar             Alias for --semantic
    --stats               Show memory statistics
    --json                Output as JSON

PRUNE OPTIONS:
    --older-than-days <n> Age threshold (default: 90)
    --dry-run             Show what would be deleted
    --include-accessed    Also prune accessed entries

DUAL TIMESTAMPS:
    - created_at:  When the memory was stored in the database
    - event_date:  When the event described actually occurred
    This enables temporal reasoning like "what happened last week?"

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

    # Recall learnings (keyword search - default)
    memory-helper.sh recall --query "database search" --limit 10

    # Recall learnings (semantic similarity - opt-in, requires setup)
    memory-helper.sh recall --query "how to optimize queries" --semantic

    # Check for stale entries
    memory-helper.sh validate

    # Clean up old unused entries
    memory-helper.sh prune --older-than-days 60 --dry-run

    # Consolidate similar memories
    memory-helper.sh consolidate --dry-run

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
        history) cmd_history "$@" ;;
        latest) cmd_latest "$@" ;;
        stats) cmd_stats ;;
        validate) cmd_validate ;;
        prune) cmd_prune "$@" ;;
        consolidate) cmd_consolidate "$@" ;;
        export) cmd_export "$@" ;;
        namespaces) cmd_namespaces "$@" ;;
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
