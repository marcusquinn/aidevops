#!/usr/bin/env bash
# =============================================================================
# MCP Index Helper - Tool description indexing for on-demand MCP discovery
# =============================================================================
# Creates and maintains an index of MCP tool descriptions for efficient
# on-demand discovery instead of loading all tool definitions upfront.
#
# Usage:
#   mcp-index-helper.sh sync              # Sync MCP descriptions from opencode.json
#   mcp-index-helper.sh search "query"    # Search for tools matching query
#   mcp-index-helper.sh list [mcp-name]   # List tools for an MCP server
#   mcp-index-helper.sh status            # Show index status
#   mcp-index-helper.sh rebuild           # Force rebuild index
#
# Architecture:
#   - Extracts tool descriptions from MCP server manifests
#   - Stores in SQLite FTS5 for fast full-text search
#   - Enables agents to discover tools without loading all MCPs
#   - Supports lazy-loading pattern: search → find MCP → enable MCP → use tool
# =============================================================================

set -euo pipefail

# Configuration
readonly INDEX_DIR="${AIDEVOPS_MCP_INDEX_DIR:-$HOME/.aidevops/.agent-workspace/mcp-index}"
readonly INDEX_DB="$INDEX_DIR/mcp-tools.db"
readonly OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
# shellcheck disable=SC2034  # Used for future cache invalidation
readonly CACHE_TTL_HOURS=24

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

#######################################
# Initialize SQLite database with FTS5
#######################################
init_db() {
    mkdir -p "$INDEX_DIR"
    
    if [[ ! -f "$INDEX_DB" ]]; then
        log_info "Creating MCP tool index at $INDEX_DB"
        
        sqlite3 "$INDEX_DB" <<'EOF'
-- Main tools table
CREATE TABLE IF NOT EXISTS mcp_tools (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    mcp_name TEXT NOT NULL,
    tool_name TEXT NOT NULL,
    description TEXT,
    input_schema TEXT,
    category TEXT,
    enabled_globally INTEGER DEFAULT 0,
    indexed_at TEXT DEFAULT (datetime('now')),
    UNIQUE(mcp_name, tool_name)
);

-- FTS5 virtual table for fast text search
CREATE VIRTUAL TABLE IF NOT EXISTS mcp_tools_fts USING fts5(
    mcp_name,
    tool_name,
    description,
    category,
    content='mcp_tools',
    content_rowid='id'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS mcp_tools_ai AFTER INSERT ON mcp_tools BEGIN
    INSERT INTO mcp_tools_fts(rowid, mcp_name, tool_name, description, category)
    VALUES (new.id, new.mcp_name, new.tool_name, new.description, new.category);
END;

CREATE TRIGGER IF NOT EXISTS mcp_tools_ad AFTER DELETE ON mcp_tools BEGIN
    INSERT INTO mcp_tools_fts(mcp_tools_fts, rowid, mcp_name, tool_name, description, category)
    VALUES ('delete', old.id, old.mcp_name, old.tool_name, old.description, old.category);
END;

CREATE TRIGGER IF NOT EXISTS mcp_tools_au AFTER UPDATE ON mcp_tools BEGIN
    INSERT INTO mcp_tools_fts(mcp_tools_fts, rowid, mcp_name, tool_name, description, category)
    VALUES ('delete', old.id, old.mcp_name, old.tool_name, old.description, old.category);
    INSERT INTO mcp_tools_fts(rowid, mcp_name, tool_name, description, category)
    VALUES (new.id, new.mcp_name, new.tool_name, new.description, new.category);
END;

-- Metadata table for tracking sync state
CREATE TABLE IF NOT EXISTS sync_metadata (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at TEXT DEFAULT (datetime('now'))
);

-- Index for common queries
CREATE INDEX IF NOT EXISTS idx_mcp_tools_mcp ON mcp_tools(mcp_name);
CREATE INDEX IF NOT EXISTS idx_mcp_tools_enabled ON mcp_tools(enabled_globally);
EOF
        log_success "Database initialized"
    fi
}

#######################################
# Check if index needs refresh
#######################################
needs_refresh() {
    if [[ ! -f "$INDEX_DB" ]]; then
        return 0
    fi
    
    local last_sync
    last_sync=$(sqlite3 "$INDEX_DB" "SELECT value FROM sync_metadata WHERE key='last_sync'" 2>/dev/null || echo "")
    
    if [[ -z "$last_sync" ]]; then
        return 0
    fi
    
    # Check if opencode.json is newer than last sync
    if [[ -f "$OPENCODE_CONFIG" ]]; then
        local config_mtime
        config_mtime=$(stat -f %m "$OPENCODE_CONFIG" 2>/dev/null || stat -c %Y "$OPENCODE_CONFIG" 2>/dev/null || echo "0")
        local sync_epoch
        sync_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_sync" +%s 2>/dev/null || date -d "$last_sync" +%s 2>/dev/null || echo "0")
        
        if [[ "$config_mtime" -gt "$sync_epoch" ]]; then
            return 0
        fi
    fi
    
    return 1
}

#######################################
# Extract MCP tool descriptions from config
# Uses Python for reliable JSON parsing
#######################################
sync_from_config() {
    init_db
    
    if [[ ! -f "$OPENCODE_CONFIG" ]]; then
        log_error "OpenCode config not found: $OPENCODE_CONFIG"
        return 1
    fi
    
    log_info "Syncing MCP tool descriptions from opencode.json..."
    
    # Use Python to extract MCP info and tool global states
    python3 << 'PYEOF'
import json
import sqlite3
import os
import sys

config_path = os.path.expanduser("~/.config/opencode/opencode.json")
db_path = os.path.expanduser("~/.aidevops/.agent-workspace/mcp-index/mcp-tools.db")

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
except Exception as e:
    print(f"Error reading config: {e}", file=sys.stderr)
    sys.exit(1)

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Get MCP servers from config
mcp_servers = config.get('mcp', {})
global_tools = config.get('tools', {})

tool_count = 0
mcp_count = 0

for mcp_name, mcp_config in mcp_servers.items():
    if not isinstance(mcp_config, dict):
        continue
    
    # Skip disabled MCPs
    if not mcp_config.get('enabled', True):
        continue
    
    mcp_count += 1
    
    # Check if this MCP's tools are globally enabled
    tool_pattern = f"{mcp_name}_*"
    globally_enabled = 1 if global_tools.get(tool_pattern, False) else 0
    
    # Extract known tools from the MCP name pattern
    # We'll create placeholder entries that can be enriched later
    # when the MCP is actually loaded
    
    # Common tool patterns based on MCP naming conventions
    tool_categories = {
        'context7': ['query-docs', 'resolve-library-id'],
        'osgrep': ['search', 'trace', 'skeleton'],
        'augment-context-engine': ['codebase-retrieval'],
        'dataforseo': ['serp', 'keywords', 'backlinks', 'domain-analytics'],
        # serper - REMOVED: Uses curl subagent (.agents/seo/serper.md)
        'gsc': ['query', 'sitemaps', 'inspect'],
        'shadcn': ['browse', 'search', 'install'],
        'playwriter': ['navigate', 'click', 'type', 'screenshot'],
        'macos-automator': ['run-applescript', 'run-jxa', 'list-apps'],
        'outscraper': ['google-maps', 'reviews', 'business-info'],
        'quickfile': ['invoices', 'expenses', 'reports'],
        'localwp': ['sites', 'start', 'stop'],
        'claude-code-mcp': ['run_claude_code'],
    }
    
    # Get category and tools for this MCP
    category = 'general'
    known_tools = []
    
    for pattern, tools in tool_categories.items():
        if pattern in mcp_name.lower():
            known_tools = tools
            # Derive category from MCP name
            if 'seo' in mcp_name.lower() or pattern in ['dataforseo', 'gsc']:
                category = 'seo'
            elif pattern in ['context7', 'osgrep', 'augment-context-engine']:
                category = 'context'
            elif pattern in ['shadcn', 'playwriter']:
                category = 'browser'
            elif pattern == 'macos-automator':
                category = 'automation'
            elif pattern == 'outscraper':
                category = 'data-extraction'
            elif pattern == 'quickfile':
                category = 'accounting'
            elif pattern == 'localwp':
                category = 'wordpress'
            elif pattern == 'claude-code-mcp':
                category = 'ai-assistant'
            break
    
    # If no known tools, create a generic entry
    if not known_tools:
        known_tools = ['*']  # Placeholder for unknown tools
    
    for tool in known_tools:
        tool_name = f"{mcp_name}_{tool}" if tool != '*' else f"{mcp_name}_*"
        description = f"Tool from {mcp_name} MCP server"
        
        # More specific descriptions for known tools
        tool_descriptions = {
            'query-docs': 'Query documentation for a library using Context7',
            'resolve-library-id': 'Resolve a library name to Context7 ID',
            'search': 'Search for content or code',
            'trace': 'Trace code execution paths',
            'skeleton': 'Generate code skeleton/structure',
            'codebase-retrieval': 'Semantic search across codebase using Augment',
            'pack_codebase': 'Package local codebase for AI analysis',
            'pack_remote_repository': 'Package remote GitHub repo for AI analysis',
            'run_claude_code': 'Run Claude Code as a one-shot subprocess',
        }
        
        if tool in tool_descriptions:
            description = tool_descriptions[tool]
        
        cursor.execute('''
            INSERT OR REPLACE INTO mcp_tools 
            (mcp_name, tool_name, description, category, enabled_globally, indexed_at)
            VALUES (?, ?, ?, ?, ?, datetime('now'))
        ''', (mcp_name, tool_name, description, category, globally_enabled))
        tool_count += 1

# Update sync metadata
cursor.execute('''
    INSERT OR REPLACE INTO sync_metadata (key, value, updated_at)
    VALUES ('last_sync', datetime('now'), datetime('now'))
''')
cursor.execute('''
    INSERT OR REPLACE INTO sync_metadata (key, value, updated_at)
    VALUES ('mcp_count', ?, datetime('now'))
''', (str(mcp_count),))
cursor.execute('''
    INSERT OR REPLACE INTO sync_metadata (key, value, updated_at)
    VALUES ('tool_count', ?, datetime('now'))
''', (str(tool_count),))

conn.commit()
conn.close()

print(f"Synced {tool_count} tools from {mcp_count} MCP servers")
PYEOF
    
    log_success "Sync complete"
    return 0
}

#######################################
# Search for tools matching a query
#######################################
search_tools() {
    local query="$1"
    local limit="${2:-10}"
    
    init_db
    
    # Auto-sync if needed
    if needs_refresh; then
        sync_from_config
    fi
    
    echo -e "${CYAN}Searching for tools matching: ${NC}$query"
    echo ""
    
    # Escape single quotes for SQL injection prevention
    local query_esc="${query//\'/\'\'}"
    
    # Validate limit is a positive integer
    if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
        log_error "Limit must be a positive integer"
        return 1
    fi
    
    # FTS5 search with ranking
    sqlite3 -header -column "$INDEX_DB" <<EOF
SELECT 
    mcp_name as MCP,
    tool_name as Tool,
    description as Description,
    category as Category,
    CASE enabled_globally WHEN 1 THEN 'Yes' ELSE 'No' END as Global
FROM mcp_tools_fts
WHERE mcp_tools_fts MATCH '$query_esc'
ORDER BY rank
LIMIT $limit;
EOF
    return 0
}

#######################################
# List tools for a specific MCP
#######################################
list_tools() {
    local mcp_name="${1:-}"
    
    init_db
    
    if [[ -z "$mcp_name" ]]; then
        # List all MCPs with tool counts
        echo -e "${CYAN}MCP Servers with indexed tools:${NC}"
        echo ""
        sqlite3 -header -column "$INDEX_DB" <<'EOF'
SELECT 
    mcp_name as MCP,
    COUNT(*) as Tools,
    category as Category,
    MAX(CASE enabled_globally WHEN 1 THEN 'Yes' ELSE 'No' END) as Global
FROM mcp_tools
GROUP BY mcp_name
ORDER BY mcp_name;
EOF
    else
        # List tools for specific MCP
        echo -e "${CYAN}Tools for MCP: ${NC}$mcp_name"
        echo ""
        # Escape single quotes for SQL injection prevention
        local mcp_name_esc="${mcp_name//\'/\'\'}"
        sqlite3 -header -column "$INDEX_DB" <<EOF
SELECT 
    tool_name as Tool,
    description as Description,
    CASE enabled_globally WHEN 1 THEN 'Yes' ELSE 'No' END as Global
FROM mcp_tools
WHERE mcp_name = '$mcp_name_esc'
ORDER BY tool_name;
EOF
    fi
    return 0
}

#######################################
# Show index status
#######################################
show_status() {
    init_db
    
    echo -e "${CYAN}MCP Tool Index Status${NC}"
    echo "====================="
    echo ""
    
    local last_sync mcp_count tool_count
    last_sync=$(sqlite3 "$INDEX_DB" "SELECT value FROM sync_metadata WHERE key='last_sync'" 2>/dev/null || echo "Never")
    mcp_count=$(sqlite3 "$INDEX_DB" "SELECT value FROM sync_metadata WHERE key='mcp_count'" 2>/dev/null || echo "0")
    tool_count=$(sqlite3 "$INDEX_DB" "SELECT value FROM sync_metadata WHERE key='tool_count'" 2>/dev/null || echo "0")
    
    echo "Database: $INDEX_DB"
    echo "Last sync: $last_sync"
    echo "MCP servers: $mcp_count"
    echo "Tools indexed: $tool_count"
    echo ""
    
    # Show globally enabled vs disabled
    local enabled disabled
    enabled=$(sqlite3 "$INDEX_DB" "SELECT COUNT(*) FROM mcp_tools WHERE enabled_globally = 1" 2>/dev/null || echo "0")
    disabled=$(sqlite3 "$INDEX_DB" "SELECT COUNT(*) FROM mcp_tools WHERE enabled_globally = 0" 2>/dev/null || echo "0")
    
    echo "Globally enabled tools: $enabled"
    echo "Disabled (on-demand): $disabled"
    echo ""
    
    # Show by category
    echo -e "${CYAN}Tools by category:${NC}"
    sqlite3 -header -column "$INDEX_DB" <<'EOF'
SELECT 
    category as Category,
    COUNT(*) as Tools,
    SUM(CASE enabled_globally WHEN 1 THEN 1 ELSE 0 END) as Enabled,
    SUM(CASE enabled_globally WHEN 0 THEN 1 ELSE 0 END) as OnDemand
FROM mcp_tools
GROUP BY category
ORDER BY Tools DESC;
EOF
    return 0
}

#######################################
# Rebuild index from scratch
#######################################
rebuild_index() {
    log_info "Rebuilding MCP tool index..."
    
    if [[ -f "$INDEX_DB" ]]; then
        rm -f "$INDEX_DB"
        log_info "Removed old index"
    fi
    
    sync_from_config
    log_success "Index rebuilt"
    return 0
}

#######################################
# Get MCP for a tool (for lazy-loading)
#######################################
get_mcp_for_tool() {
    local tool_query="$1"
    
    init_db
    
    # Escape single quotes and percent signs for SQL injection prevention
    local tool_query_esc="${tool_query//\'/\'\'}"
    tool_query_esc="${tool_query_esc//%/%%}"
    
    # Find which MCP provides this tool
    sqlite3 "$INDEX_DB" <<EOF
SELECT DISTINCT mcp_name
FROM mcp_tools
WHERE tool_name LIKE '%$tool_query_esc%'
LIMIT 1;
EOF
    return 0
}

#######################################
# Show help
#######################################
show_help() {
    cat << 'EOF'
MCP Index Helper - Tool description indexing for on-demand MCP discovery

Usage:
  mcp-index-helper.sh sync              Sync MCP descriptions from opencode.json
  mcp-index-helper.sh search "query"    Search for tools matching query
  mcp-index-helper.sh list [mcp-name]   List tools (all MCPs or specific one)
  mcp-index-helper.sh status            Show index status
  mcp-index-helper.sh rebuild           Force rebuild index
  mcp-index-helper.sh get-mcp "tool"    Find which MCP provides a tool
  mcp-index-helper.sh help              Show this help

Examples:
  mcp-index-helper.sh search "screenshot"
  mcp-index-helper.sh search "seo keyword"
  mcp-index-helper.sh list context7
  mcp-index-helper.sh get-mcp "query-docs"

The index enables on-demand MCP discovery:
  1. Agent searches for capability: "I need to take screenshots"
  2. Index returns: playwriter MCP has screenshot tools
  3. Agent enables playwriter MCP for this session
  4. Agent uses the tool

This avoids loading all MCP tool definitions upfront, reducing context usage.
EOF
}

#######################################
# Main
#######################################
main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        sync)
            sync_from_config
            ;;
        search)
            if [[ -z "${1:-}" ]]; then
                log_error "Usage: mcp-index-helper.sh search \"query\""
                return 1
            fi
            search_tools "$1" "${2:-10}"
            ;;
        list)
            list_tools "${1:-}"
            ;;
        status)
            show_status
            ;;
        rebuild)
            rebuild_index
            ;;
        get-mcp)
            if [[ -z "${1:-}" ]]; then
                log_error "Usage: mcp-index-helper.sh get-mcp \"tool-name\""
                return 1
            fi
            get_mcp_for_tool "$1"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
}

main "$@"
