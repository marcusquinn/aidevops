#!/usr/bin/env bash
# =============================================================================
# Memory Graduate Helper - Promote validated memories into shared docs
# =============================================================================
# Identifies high-value memories from the local SQLite DB and graduates them
# into the shared codebase (.agents/) so all users benefit from learnings.
#
# Graduation criteria (configurable):
#   - High confidence OR frequently accessed (access_count >= threshold)
#   - Not already graduated
#   - Content is actionable (not just session metadata)
#
# Usage:
#   memory-graduate-helper.sh candidates [--limit N] [--min-access N]
#   memory-graduate-helper.sh graduate [--dry-run] [--limit N] [--min-access N]
#   memory-graduate-helper.sh status
#   memory-graduate-helper.sh help
#
# Integration:
#   - Called by supervisor pulse (memory audit phase)
#   - Called manually via /graduate-memories command
#   - Writes to .agents/aidevops/graduated-learnings.md
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

readonly MEMORY_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
readonly MEMORY_DB="$MEMORY_DIR/memory.db"

# Default graduation thresholds
readonly DEFAULT_MIN_ACCESS=3
readonly DEFAULT_LIMIT=20

# Target file for graduated learnings (relative to repo root)
readonly GRADUATED_FILE_NAME="graduated-learnings.md"

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

#######################################
# SQLite wrapper with busy_timeout
#######################################
db() {
    sqlite3 -cmd ".timeout 5000" "$@"
}

#######################################
# Find the repo root (for writing graduated-learnings.md)
#######################################
find_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null || echo ""
}

#######################################
# Resolve the graduated learnings file path
#######################################
graduated_file_path() {
    local repo_root
    repo_root=$(find_repo_root)
    if [[ -z "$repo_root" ]]; then
        log_error "Not in a git repository. Cannot locate graduated-learnings.md"
        return 1
    fi
    echo "$repo_root/.agents/aidevops/$GRADUATED_FILE_NAME"
}

#######################################
# Ensure the graduated_at column exists in learning_access
#######################################
ensure_schema() {
    if [[ ! -f "$MEMORY_DB" ]]; then
        log_error "Memory database not found: $MEMORY_DB"
        log_error "Run memory-helper.sh store to initialize."
        return 1
    fi

    local has_graduated
    has_graduated=$(db "$MEMORY_DB" \
        "SELECT COUNT(*) FROM pragma_table_info('learning_access') WHERE name='graduated_at';" \
        2>/dev/null || echo "0")

    if [[ "$has_graduated" == "0" ]]; then
        log_info "Migrating schema: adding graduated_at column..."
        db "$MEMORY_DB" \
            "ALTER TABLE learning_access ADD COLUMN graduated_at TEXT DEFAULT NULL;" \
            2>/dev/null || true
        log_success "Schema updated"
    fi

    return 0
}

#######################################
# Filter out session metadata and low-value content
# Returns 0 if content is actionable, 1 if it should be skipped
#######################################
is_actionable() {
    local content="$1"

    # Skip batch retrospectives (session metadata)
    if [[ "$content" == *"Batch retrospective:"* ]]; then
        return 1
    fi

    # Skip session review entries
    if [[ "$content" == *"Session review for batch"* ]]; then
        return 1
    fi

    # Skip "Implemented feature:" one-liners (too vague)
    if [[ "$content" =~ ^Implemented\ feature:\ [a-zA-Z0-9_-]+$ ]]; then
        return 1
    fi

    # Skip pure commit message references (no actionable content)
    if [[ "$content" =~ ^(Merge\ pull\ request|docs:\ (add|mark|update)) ]]; then
        return 1
    fi

    # Skip entries shorter than 20 chars (too terse to be useful)
    if [[ ${#content} -lt 20 ]]; then
        return 1
    fi

    # Skip user-specific config (GPG keys, email addresses, local paths)
    if [[ "$content" == *"GPG key"* || "$content" == *"pinentry-mac"* ]]; then
        return 1
    fi
    if [[ "$content" == *"@"*".com"* && "$content" == *"initialized"* ]]; then
        return 1
    fi

    # Skip supervisor task status entries (operational, not learnings)
    if [[ "$content" =~ ^Supervisor\ task\ t[0-9]+ ]]; then
        return 1
    fi

    return 0
}

#######################################
# Categorize a memory into a section for the graduated doc
#######################################
categorize_memory() {
    local type="$1"

    case "$type" in
        WORKING_SOLUTION|ERROR_FIX)
            echo "Solutions & Fixes"
            ;;
        FAILED_APPROACH|FAILURE_PATTERN)
            echo "Anti-Patterns (What NOT to Do)"
            ;;
        CODEBASE_PATTERN|SUCCESS_PATTERN)
            echo "Patterns & Best Practices"
            ;;
        DECISION|ARCHITECTURAL_DECISION)
            echo "Architecture Decisions"
            ;;
        USER_PREFERENCE|TOOL_CONFIG)
            echo "Configuration & Preferences"
            ;;
        CONTEXT)
            echo "Context & Background"
            ;;
        *)
            echo "General Learnings"
            ;;
    esac
}

#######################################
# Find graduation candidates
# Criteria: high confidence OR frequently accessed, not yet graduated
#######################################
cmd_candidates() {
    local limit=$DEFAULT_LIMIT
    local min_access=$DEFAULT_MIN_ACCESS

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit|-l) limit="$2"; shift 2 ;;
            --min-access) min_access="$2"; shift 2 ;;
            --json) local format="json"; shift ;;
            *) shift ;;
        esac
    done

    ensure_schema || return 1

    log_info "Finding graduation candidates (min access: $min_access, limit: $limit)..."
    echo ""

    local results
    results=$(db -json "$MEMORY_DB" <<EOF
SELECT
    l.id,
    l.type,
    l.content,
    l.tags,
    l.confidence,
    l.created_at,
    COALESCE(a.access_count, 0) as access_count,
    COALESCE(a.last_accessed_at, '') as last_accessed_at
FROM learnings l
LEFT JOIN learning_access a ON l.id = a.id
WHERE (
    l.confidence = 'high'
    OR COALESCE(a.access_count, 0) >= $min_access
)
AND (a.graduated_at IS NULL OR a.graduated_at = '')
ORDER BY
    CASE WHEN l.confidence = 'high' THEN 0 ELSE 1 END,
    COALESCE(a.access_count, 0) DESC,
    l.created_at ASC
LIMIT $limit;
EOF
    )

    if [[ -z "$results" || "$results" == "[]" ]]; then
        log_info "No graduation candidates found."
        log_info "Memories qualify when: confidence=high OR access_count >= $min_access"
        return 0
    fi

    if [[ "${format:-text}" == "json" ]]; then
        echo "$results"
        return 0
    fi

    echo "=== Graduation Candidates ==="
    echo ""

    local count=0
    local actionable=0

    while IFS= read -r entry; do
        local id type content confidence access_count
        id=$(echo "$entry" | jq -r '.id')
        type=$(echo "$entry" | jq -r '.type')
        content=$(echo "$entry" | jq -r '.content')
        confidence=$(echo "$entry" | jq -r '.confidence')
        access_count=$(echo "$entry" | jq -r '.access_count')

        count=$((count + 1))

        if is_actionable "$content"; then
            actionable=$((actionable + 1))
            local category
            category=$(categorize_memory "$type")
            echo "  [$type] (confidence: $confidence, accessed: ${access_count}x)"
            echo "  Category: $category"
            echo "  ID: $id"
            echo "  $content"
            echo ""
        else
            echo "  [SKIP] $id - session metadata / low-value"
        fi
    done < <(echo "$results" | jq -c '.[]')

    echo "---"
    echo "Total candidates: $count (actionable: $actionable)"
    echo ""
    echo "Run 'memory-graduate-helper.sh graduate' to promote these to shared docs."

    return 0
}

#######################################
# Graduate memories into shared docs
#######################################
cmd_graduate() {
    local dry_run=false
    local limit=$DEFAULT_LIMIT
    local min_access=$DEFAULT_MIN_ACCESS

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --limit|-l) limit="$2"; shift 2 ;;
            --min-access) min_access="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    ensure_schema || return 1

    local target_file
    target_file=$(graduated_file_path) || return 1

    log_info "Graduating memories to $target_file..."

    # Fetch candidates
    local results
    results=$(db -json "$MEMORY_DB" <<EOF
SELECT
    l.id,
    l.type,
    l.content,
    l.tags,
    l.confidence,
    l.created_at,
    COALESCE(a.access_count, 0) as access_count
FROM learnings l
LEFT JOIN learning_access a ON l.id = a.id
WHERE (
    l.confidence = 'high'
    OR COALESCE(a.access_count, 0) >= $min_access
)
AND (a.graduated_at IS NULL OR a.graduated_at = '')
ORDER BY
    CASE WHEN l.confidence = 'high' THEN 0 ELSE 1 END,
    COALESCE(a.access_count, 0) DESC,
    l.created_at ASC
LIMIT $limit;
EOF
    )

    if [[ -z "$results" || "$results" == "[]" ]]; then
        log_info "No memories to graduate."
        return 0
    fi

    # Collect actionable entries grouped by category
    # Use temp files for category grouping (bash 3.2 compat - no assoc arrays)
    local tmp_dir
    tmp_dir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" EXIT

    local graduated_count=0
    local skipped_count=0
    local graduated_ids=()

    while IFS= read -r entry; do
        local id type content confidence access_count
        id=$(echo "$entry" | jq -r '.id')
        type=$(echo "$entry" | jq -r '.type')
        content=$(echo "$entry" | jq -r '.content')
        confidence=$(echo "$entry" | jq -r '.confidence')
        access_count=$(echo "$entry" | jq -r '.access_count')

        if ! is_actionable "$content"; then
            skipped_count=$((skipped_count + 1))
            # Mark skipped entries as graduated too (so they don't reappear)
            graduated_ids+=("$id")
            continue
        fi

        local category
        category=$(categorize_memory "$type")
        local safe_category
        safe_category=$(echo "$category" | sed 's/[^a-zA-Z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

        # Store the real category name in a mapping file
        echo "$category" > "$tmp_dir/${safe_category}.name"

        # Append to category file
        {
            echo "- **[$type]** $content"
            echo "  *(confidence: $confidence, validated: ${access_count}x)*"
            echo ""
        } >> "$tmp_dir/${safe_category}.entries"

        graduated_ids+=("$id")
        graduated_count=$((graduated_count + 1))
    done < <(echo "$results" | jq -c '.[]')

    if [[ "$graduated_count" -eq 0 ]]; then
        log_info "No actionable memories to graduate ($skipped_count skipped as metadata)."
        # Still mark skipped entries
        if [[ "$dry_run" == false && ${#graduated_ids[@]} -gt 0 ]]; then
            mark_graduated "${graduated_ids[@]}"
        fi
        return 0
    fi

    if [[ "$dry_run" == true ]]; then
        log_info "[DRY RUN] Would graduate $graduated_count memories ($skipped_count skipped)"
        echo ""
        echo "=== Preview of graduated content ==="
        echo ""
        for entries_file in "$tmp_dir"/*.entries; do
            [[ -f "$entries_file" ]] || continue
            local base_name cat_name
            base_name=$(basename "$entries_file" .entries)
            cat_name=$(cat "$tmp_dir/${base_name}.name" 2>/dev/null || echo "$base_name")
            echo "### $cat_name"
            echo ""
            cat "$entries_file"
        done
        return 0
    fi

    # Build the content to append
    local new_content=""
    local timestamp
    timestamp=$(date -u +"%Y-%m-%d")

    new_content+="
## Graduated: $timestamp

"

    local first_category=true
    for entries_file in "$tmp_dir"/*.entries; do
        [[ -f "$entries_file" ]] || continue
        local base_name cat_name
        base_name=$(basename "$entries_file" .entries)
        cat_name=$(cat "$tmp_dir/${base_name}.name" 2>/dev/null || echo "$base_name")
        # Add blank line before heading (MD022) - skip for first category
        # (already has blank line from ## Graduated header above)
        if [[ "$first_category" == true ]]; then
            first_category=false
        else
            new_content+="
"
        fi
        new_content+="### $cat_name

"
        new_content+=$(cat "$entries_file")
        new_content+="
"
    done

    # Ensure target file exists with header
    if [[ ! -f "$target_file" ]]; then
        local target_dir
        target_dir=$(dirname "$target_file")
        mkdir -p "$target_dir"
        cat > "$target_file" << 'HEADER'
---
description: Shared learnings graduated from local memory across all users
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
---

# Graduated Learnings

Validated learnings promoted from local memory databases into shared documentation.
These patterns have been confirmed through repeated use across sessions.

**How memories graduate**: Memories qualify when they reach high confidence or are
accessed frequently (3+ times). The `memory-graduate-helper.sh` script identifies
candidates and appends them here. Each graduation batch is timestamped.

**Categories**:

- **Solutions & Fixes**: Working solutions to real problems
- **Anti-Patterns**: Approaches that failed (avoid repeating)
- **Patterns & Best Practices**: Proven approaches
- **Architecture Decisions**: Key design choices and rationale
- **Configuration & Preferences**: Tool and workflow settings
- **Context & Background**: Important background information

HEADER
        log_info "Created $target_file"
    fi

    # Append graduated content
    echo "$new_content" >> "$target_file"

    # Mark memories as graduated in the DB
    mark_graduated "${graduated_ids[@]}"

    log_success "Graduated $graduated_count memories ($skipped_count skipped as metadata)"
    log_info "Updated: $target_file"
    log_info "Remember to commit and push the changes."

    return 0
}

#######################################
# Mark memories as graduated in the DB
#######################################
mark_graduated() {
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    for id in "$@"; do
        local escaped_id="${id//"'"/"''"}"
        db "$MEMORY_DB" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count, graduated_at)
VALUES ('$escaped_id', datetime('now'), 0, '$timestamp')
ON CONFLICT(id) DO UPDATE SET graduated_at = '$timestamp';
EOF
    done

    return 0
}

#######################################
# Show graduation status
#######################################
cmd_status() {
    ensure_schema || return 1

    echo ""
    echo "=== Memory Graduation Status ==="
    echo ""

    # Total memories
    local total
    total=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
    echo "Total memories: $total"

    # Already graduated
    local graduated
    graduated=$(db "$MEMORY_DB" \
        "SELECT COUNT(*) FROM learning_access WHERE graduated_at IS NOT NULL AND graduated_at != '';" \
        2>/dev/null || echo "0")
    echo "Already graduated: $graduated"

    # Candidates (high confidence)
    local high_conf
    high_conf=$(db "$MEMORY_DB" <<EOF
SELECT COUNT(*) FROM learnings l
LEFT JOIN learning_access a ON l.id = a.id
WHERE l.confidence = 'high'
AND (a.graduated_at IS NULL OR a.graduated_at = '');
EOF
    )
    echo "High confidence (pending): ${high_conf:-0}"

    # Candidates (frequently accessed)
    local freq_accessed
    freq_accessed=$(db "$MEMORY_DB" <<EOF
SELECT COUNT(*) FROM learnings l
LEFT JOIN learning_access a ON l.id = a.id
WHERE COALESCE(a.access_count, 0) >= $DEFAULT_MIN_ACCESS
AND (a.graduated_at IS NULL OR a.graduated_at = '');
EOF
    )
    echo "Frequently accessed (pending): ${freq_accessed:-0}"

    # Total candidates (union)
    local total_candidates
    total_candidates=$(db "$MEMORY_DB" <<EOF
SELECT COUNT(*) FROM learnings l
LEFT JOIN learning_access a ON l.id = a.id
WHERE (
    l.confidence = 'high'
    OR COALESCE(a.access_count, 0) >= $DEFAULT_MIN_ACCESS
)
AND (a.graduated_at IS NULL OR a.graduated_at = '');
EOF
    )
    echo "Total candidates: ${total_candidates:-0}"

    # Check if graduated-learnings.md exists
    local target_file
    target_file=$(graduated_file_path 2>/dev/null || echo "")
    if [[ -n "$target_file" && -f "$target_file" ]]; then
        local line_count
        line_count=$(wc -l < "$target_file" | tr -d ' ')
        echo ""
        echo "Shared doc: $target_file ($line_count lines)"
    else
        echo ""
        echo "Shared doc: not yet created (will be created on first graduation)"
    fi

    echo ""
    return 0
}

#######################################
# Show help
#######################################
cmd_help() {
    cat << 'EOF'
memory-graduate-helper.sh - Promote validated memories into shared docs

Moves high-value learnings from the local SQLite memory database into
version-controlled documentation (.agents/aidevops/graduated-learnings.md)
so all framework users benefit from validated patterns.

USAGE:
    memory-graduate-helper.sh <command> [options]

COMMANDS:
    candidates  List memories eligible for graduation
    graduate    Promote eligible memories to shared docs
    status      Show graduation statistics
    help        Show this help

CANDIDATE OPTIONS:
    --limit N       Max candidates to show (default: 20)
    --min-access N  Min access count threshold (default: 3)
    --json          Output as JSON

GRADUATE OPTIONS:
    --dry-run       Preview without writing changes
    --limit N       Max memories to graduate (default: 20)
    --min-access N  Min access count threshold (default: 3)

GRADUATION CRITERIA:
    A memory qualifies for graduation when ANY of:
    - confidence = "high" (manually marked as high-value)
    - access_count >= 3 (frequently recalled, proving usefulness)

    AND:
    - Not already graduated (tracked via graduated_at timestamp)
    - Content is actionable (not session metadata or batch logs)

CATEGORIES:
    Memories are auto-categorized by type:
    - Solutions & Fixes:        WORKING_SOLUTION, ERROR_FIX
    - Anti-Patterns:            FAILED_APPROACH, FAILURE_PATTERN
    - Patterns & Best Practices: CODEBASE_PATTERN, SUCCESS_PATTERN
    - Architecture Decisions:    DECISION, ARCHITECTURAL_DECISION
    - Configuration:            USER_PREFERENCE, TOOL_CONFIG
    - Context:                  CONTEXT

WORKFLOW:
    1. Memories accumulate in local DB via /remember and auto-capture
    2. Frequently used memories gain access_count
    3. Run 'candidates' to review what qualifies
    4. Run 'graduate --dry-run' to preview
    5. Run 'graduate' to append to shared docs
    6. Commit and push the updated graduated-learnings.md

INTEGRATION:
    - Supervisor pulse: memory audit phase calls this automatically
    - Manual: /graduate-memories slash command
    - CI: Can be run in pre-release checks

EXAMPLES:
    # See what's ready to graduate
    memory-graduate-helper.sh candidates

    # Preview graduation output
    memory-graduate-helper.sh graduate --dry-run

    # Graduate with lower threshold
    memory-graduate-helper.sh graduate --min-access 2

    # Check status
    memory-graduate-helper.sh status
EOF
    return 0
}

#######################################
# Main
#######################################
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        candidates|list) cmd_candidates "$@" ;;
        graduate|promote) cmd_graduate "$@" ;;
        status|stats) cmd_status ;;
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
