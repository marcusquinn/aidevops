#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# =============================================================================
# Quality Sweep Helper - Finding-to-task pipeline (t245.3)
# =============================================================================
# Groups normalized findings from all quality tools (SonarCloud, Codacy,
# CodeFactor, CodeRabbit) by file/category, creates batched TODO tasks,
# deduplicates against existing tasks, and optionally auto-dispatches.
#
# Usage:
#   quality-sweep-helper.sh ingest <source> <findings-json>
#   quality-sweep-helper.sh create-tasks [--min-severity LEVEL] [--dry-run] [--auto-dispatch]
#   quality-sweep-helper.sh groups [--min-severity LEVEL]
#   quality-sweep-helper.sh stats
#   quality-sweep-helper.sh help
#
# Sources: sonarcloud, codacy, codefactor, coderabbit, manual
#
# Findings JSON format (one object per finding):
#   { "file": "path/to/file.sh", "line": 42, "severity": "medium",
#     "category": "code_smell", "rule": "bash:S1234", "message": "..." }
#
# Subtask: t245.3 - Finding-to-task pipeline
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
init_log_file

# =============================================================================
# Constants
# =============================================================================

readonly SWEEP_DB="${HOME}/.aidevops/.agent-workspace/work/quality-sweep/sweep.db"

# =============================================================================
# Logging
# =============================================================================

log_info()    { echo -e "${BLUE}[QUALITY-SWEEP]${NC} $*"; return 0; }
log_success() { echo -e "${GREEN}[QUALITY-SWEEP]${NC} $*"; return 0; }
log_warn()    { echo -e "${YELLOW}[QUALITY-SWEEP]${NC} $*"; return 0; }
log_error()   { echo -e "${RED}[QUALITY-SWEEP]${NC} $*" >&2; return 0; }

# =============================================================================
# SQLite wrapper
# =============================================================================

db() {
    sqlite3 -cmd ".timeout 5000" "$@"
}

sql_escape() {
    local val="$1"
    val="${val//\'/\'\'}"
    printf '%s' "$val"
    return 0
}

# =============================================================================
# Database Setup
# =============================================================================

ensure_db() {
    local db_dir
    db_dir=$(dirname "$SWEEP_DB")
    mkdir -p "$db_dir" 2>/dev/null || true

    if [[ ! -f "$SWEEP_DB" ]]; then
        init_db
        return 0
    fi

    # Ensure WAL mode
    local current_mode
    current_mode=$(db "$SWEEP_DB" "PRAGMA journal_mode;" 2>/dev/null || echo "")
    if [[ "$current_mode" != "wal" ]]; then
        db "$SWEEP_DB" "PRAGMA journal_mode=WAL;" 2>/dev/null || true
    fi

    return 0
}

init_db() {
    db "$SWEEP_DB" << 'SQL' >/dev/null
PRAGMA journal_mode=WAL;

-- Normalized findings from all quality tools
CREATE TABLE IF NOT EXISTS findings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source          TEXT NOT NULL,
    source_id       TEXT NOT NULL,
    file            TEXT,
    line            INTEGER,
    severity        TEXT NOT NULL,
    category        TEXT NOT NULL,
    rule            TEXT,
    message         TEXT NOT NULL,
    is_duplicate    INTEGER NOT NULL DEFAULT 0,
    duplicate_of    INTEGER,
    task_id         TEXT,
    task_created    INTEGER NOT NULL DEFAULT 0,
    ingested_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE(source, source_id)
);

-- Task groups: batched findings grouped by file + category
CREATE TABLE IF NOT EXISTS task_groups (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    file            TEXT NOT NULL,
    category        TEXT NOT NULL,
    finding_count   INTEGER NOT NULL DEFAULT 0,
    max_severity    TEXT NOT NULL,
    task_id         TEXT,
    todo_written    INTEGER NOT NULL DEFAULT 0,
    dispatched      INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE(file, category)
);

-- Mapping: which findings belong to which task group
CREATE TABLE IF NOT EXISTS group_findings (
    group_id        INTEGER NOT NULL REFERENCES task_groups(id),
    finding_id      INTEGER NOT NULL REFERENCES findings(id),
    PRIMARY KEY (group_id, finding_id)
);

CREATE INDEX IF NOT EXISTS idx_f_source ON findings(source, source_id);
CREATE INDEX IF NOT EXISTS idx_f_severity ON findings(severity);
CREATE INDEX IF NOT EXISTS idx_f_task ON findings(task_created);
CREATE INDEX IF NOT EXISTS idx_f_file_cat ON findings(file, category);
CREATE INDEX IF NOT EXISTS idx_tg_todo ON task_groups(todo_written);
SQL

    log_info "Quality sweep database initialized: $SWEEP_DB"
    return 0
}

# =============================================================================
# Severity Helpers
# =============================================================================

severity_rank() {
    local sev="$1"
    case "$sev" in
        critical) echo 1 ;;
        high)     echo 2 ;;
        medium)   echo 3 ;;
        low)      echo 4 ;;
        info)     echo 5 ;;
        *)        echo 6 ;;
    esac
    return 0
}

meets_severity_threshold() {
    local sev="$1"
    local threshold="$2"
    local sev_rank threshold_rank
    sev_rank=$(severity_rank "$sev")
    threshold_rank=$(severity_rank "$threshold")
    [[ "$sev_rank" -le "$threshold_rank" ]]
    return $?
}

higher_severity() {
    local a="$1"
    local b="$2"
    local rank_a rank_b
    rank_a=$(severity_rank "$a")
    rank_b=$(severity_rank "$b")
    if [[ "$rank_a" -le "$rank_b" ]]; then
        echo "$a"
    else
        echo "$b"
    fi
    return 0
}

# =============================================================================
# Command: ingest — Import normalized findings from a source
# =============================================================================

cmd_ingest() {
    local source=""
    local findings_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)
                [[ -z "${2:-}" || "$2" == --* ]] && { log_error "Missing value for --source"; return 1; }
                source="$2"; shift 2 ;;
            *)
                if [[ -z "$findings_file" ]]; then
                    findings_file="$1"; shift
                else
                    log_warn "Unknown option: $1"; shift
                fi
                ;;
        esac
    done

    if [[ -z "$source" ]]; then
        # Try to infer source from first positional arg
        if [[ -n "$findings_file" && "$findings_file" =~ ^(sonarcloud|codacy|codefactor|coderabbit|manual)$ ]]; then
            source="$findings_file"
            findings_file=""
        else
            log_error "Source is required: --source <sonarcloud|codacy|codefactor|coderabbit|manual>"
            return 1
        fi
    fi

    # Validate source
    case "$source" in
        sonarcloud|codacy|codefactor|coderabbit|manual) ;;
        *) log_error "Unknown source: $source (expected: sonarcloud, codacy, codefactor, coderabbit, manual)"; return 1 ;;
    esac

    # Read findings from file or stdin
    local findings_json
    if [[ -n "$findings_file" && -f "$findings_file" ]]; then
        findings_json=$(cat "$findings_file")
    elif [[ -n "$findings_file" && "$findings_file" != "-" ]]; then
        log_error "Findings file not found: $findings_file"
        return 1
    else
        # Read from stdin
        findings_json=$(cat)
    fi

    # Validate JSON
    if ! echo "$findings_json" | jq empty 2>/dev/null; then
        log_error "Invalid JSON input"
        return 1
    fi

    ensure_db

    # Handle both array and single-object input
    local count
    count=$(echo "$findings_json" | jq 'if type == "array" then length else 1 end' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        log_info "No findings to ingest"
        return 0
    fi

    log_info "Ingesting $count finding(s) from $source..."

    local ingested=0
    local duplicates=0
    local tmp_ingest
    tmp_ingest=$(mktemp)
    trap 'rm -f "${tmp_ingest:-}"' RETURN

    # Normalize to array
    echo "$findings_json" | jq -c 'if type == "array" then .[] else . end' > "$tmp_ingest"

    while IFS= read -r finding; do
        local file line severity category rule message source_id
        file=$(echo "$finding" | jq -r '.file // ""')
        line=$(echo "$finding" | jq -r '.line // 0')
        severity=$(echo "$finding" | jq -r '.severity // "medium"')
        category=$(echo "$finding" | jq -r '.category // "unknown"')
        rule=$(echo "$finding" | jq -r '.rule // ""')
        message=$(echo "$finding" | jq -r '.message // ""')
        source_id=$(echo "$finding" | jq -r '.source_id // .id // .rule // ""')

        # Generate source_id if not provided
        if [[ -z "$source_id" ]]; then
            source_id="${file}:${line}:${rule}"
        fi

        # Normalize severity
        case "$severity" in
            BLOCKER|blocker|CRITICAL|critical) severity="critical" ;;
            MAJOR|major|HIGH|high)             severity="high" ;;
            MINOR|minor|MEDIUM|medium)         severity="medium" ;;
            INFO|info|LOW|low)                 severity="low" ;;
            *)                                 severity="info" ;;
        esac

        # Normalize category
        case "$category" in
            CODE_SMELL|code_smell|smell)        category="code_smell" ;;
            BUG|bug)                            category="bug" ;;
            VULNERABILITY|vulnerability|vuln)   category="vulnerability" ;;
            SECURITY_HOTSPOT|security_hotspot)  category="security_hotspot" ;;
            DUPLICATION|duplication)             category="duplication" ;;
            *)                                  category="$category" ;;
        esac

        local esc_file esc_message esc_rule esc_source_id
        esc_file=$(sql_escape "$file")
        esc_message=$(sql_escape "$message")
        esc_rule=$(sql_escape "$rule")
        esc_source_id=$(sql_escape "$source_id")

        # Insert or ignore (UNIQUE constraint handles dedup within same source)
        local result
        result=$(db "$SWEEP_DB" "
            INSERT OR IGNORE INTO findings (source, source_id, file, line, severity, category, rule, message)
            VALUES ('$source', '$esc_source_id', '$esc_file', $line, '$severity', '$category', '$esc_rule', '$esc_message');
            SELECT changes();
        " 2>/dev/null || echo "0")

        if [[ "$result" -gt 0 ]]; then
            ingested=$((ingested + 1))
        else
            duplicates=$((duplicates + 1))
        fi
    done < "$tmp_ingest"

    # Cross-source dedup: mark findings with same file+line+category from different sources
    _cross_source_dedup

    log_success "Ingested: $ingested new, $duplicates already known (source: $source)"
    return 0
}

# =============================================================================
# Cross-source deduplication
# =============================================================================

_cross_source_dedup() {
    # For each finding, check if another source already has a finding for the
    # same file + line + category. Mark the newer one as duplicate.
    db "$SWEEP_DB" "
        UPDATE findings SET is_duplicate = 1, duplicate_of = (
            SELECT f2.id FROM findings f2
            WHERE f2.file = findings.file
              AND f2.line = findings.line
              AND f2.category = findings.category
              AND f2.source != findings.source
              AND f2.id < findings.id
              AND f2.is_duplicate = 0
            LIMIT 1
        )
        WHERE is_duplicate = 0
          AND EXISTS (
            SELECT 1 FROM findings f2
            WHERE f2.file = findings.file
              AND f2.line = findings.line
              AND f2.category = findings.category
              AND f2.source != findings.source
              AND f2.id < findings.id
              AND f2.is_duplicate = 0
          );
    " 2>/dev/null || true
    return 0
}

# =============================================================================
# Command: groups — Show finding groups (file + category)
# =============================================================================

cmd_groups() {
    local min_severity="medium"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --min-severity)
                [[ -z "${2:-}" || "$2" == --* ]] && { log_error "Missing value for --min-severity"; return 1; }
                min_severity="$2"; shift 2 ;;
            *) log_warn "Unknown option: $1"; shift ;;
        esac
    done

    ensure_db
    _build_groups "$min_severity"

    log_info "Finding groups (min severity: $min_severity):"
    echo ""
    printf "%-50s %-20s %5s %-10s %s\n" "FILE" "CATEGORY" "COUNT" "SEVERITY" "TASK_ID"
    printf "%-50s %-20s %5s %-10s %s\n" "----" "--------" "-----" "--------" "-------"

    db "$SWEEP_DB" -separator '|' "
        SELECT file, category, finding_count, max_severity,
               COALESCE(task_id, '-')
        FROM task_groups
        WHERE finding_count > 0
        ORDER BY
            CASE max_severity
                WHEN 'critical' THEN 1
                WHEN 'high' THEN 2
                WHEN 'medium' THEN 3
                WHEN 'low' THEN 4
                ELSE 5
            END,
            finding_count DESC;
    " 2>/dev/null | while IFS='|' read -r file cat cnt sev tid; do
        # Truncate long file paths
        local display_file="$file"
        if [[ ${#display_file} -gt 48 ]]; then
            display_file="...${display_file: -45}"
        fi
        printf "%-50s %-20s %5s %-10s %s\n" "$display_file" "$cat" "$cnt" "$sev" "$tid"
    done

    echo ""
    return 0
}

# =============================================================================
# Build/refresh task groups from findings
# =============================================================================

_build_groups() {
    local min_severity="$1"

    # Build severity filter
    local severity_filter=""
    case "$min_severity" in
        critical) severity_filter="AND severity IN ('critical')" ;;
        high)     severity_filter="AND severity IN ('critical', 'high')" ;;
        medium)   severity_filter="AND severity IN ('critical', 'high', 'medium')" ;;
        low)      severity_filter="AND severity IN ('critical', 'high', 'medium', 'low')" ;;
        *)        severity_filter="" ;;
    esac

    # Upsert task_groups from findings
    db "$SWEEP_DB" "
        INSERT OR REPLACE INTO task_groups (file, category, finding_count, max_severity, task_id, todo_written, dispatched)
        SELECT
            f.file,
            f.category,
            COUNT(*) AS finding_count,
            CASE
                WHEN SUM(CASE WHEN f.severity = 'critical' THEN 1 ELSE 0 END) > 0 THEN 'critical'
                WHEN SUM(CASE WHEN f.severity = 'high' THEN 1 ELSE 0 END) > 0 THEN 'high'
                WHEN SUM(CASE WHEN f.severity = 'medium' THEN 1 ELSE 0 END) > 0 THEN 'medium'
                WHEN SUM(CASE WHEN f.severity = 'low' THEN 1 ELSE 0 END) > 0 THEN 'low'
                ELSE 'info'
            END AS max_severity,
            COALESCE(tg.task_id, NULL),
            COALESCE(tg.todo_written, 0),
            COALESCE(tg.dispatched, 0)
        FROM findings f
        LEFT JOIN task_groups tg ON tg.file = f.file AND tg.category = f.category
        WHERE f.is_duplicate = 0
          AND f.task_created = 0
          AND f.file != ''
          $severity_filter
        GROUP BY f.file, f.category
        HAVING COUNT(*) > 0;
    " 2>/dev/null || true

    # Rebuild group_findings mapping
    db "$SWEEP_DB" "
        DELETE FROM group_findings;
        INSERT INTO group_findings (group_id, finding_id)
        SELECT tg.id, f.id
        FROM findings f
        JOIN task_groups tg ON tg.file = f.file AND tg.category = f.category
        WHERE f.is_duplicate = 0
          AND f.task_created = 0
          AND f.file != ''
          $severity_filter;
    " 2>/dev/null || true

    return 0
}

# =============================================================================
# Command: create-tasks — Group findings and create TODO tasks
# =============================================================================

cmd_create_tasks() {
    local min_severity="medium"
    local dry_run="false"
    local auto_dispatch="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --min-severity)
                [[ -z "${2:-}" || "$2" == --* ]] && { log_error "Missing value for --min-severity"; return 1; }
                min_severity="$2"; shift 2 ;;
            --dry-run)        dry_run="true"; shift ;;
            --auto-dispatch)  auto_dispatch="true"; shift ;;
            *) log_warn "Unknown option: $1"; shift ;;
        esac
    done

    ensure_db

    # Build groups from current findings
    _build_groups "$min_severity"

    # Get groups that haven't been written to TODO yet
    local groups_json
    groups_json=$(db "$SWEEP_DB" -json "
        SELECT id, file, category, finding_count, max_severity
        FROM task_groups
        WHERE todo_written = 0
          AND finding_count > 0
        ORDER BY
            CASE max_severity
                WHEN 'critical' THEN 1
                WHEN 'high' THEN 2
                WHEN 'medium' THEN 3
                WHEN 'low' THEN 4
                ELSE 5
            END,
            finding_count DESC;
    " 2>/dev/null || echo "[]")

    local group_count
    group_count=$(echo "$groups_json" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$group_count" -eq 0 ]]; then
        log_info "No new task groups to create (all findings already have tasks)"
        return 0
    fi

    log_info "Found $group_count task group(s) to create..."

    # Find the repo root and TODO.md
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
    local todo_file="$repo_root/TODO.md"

    if [[ ! -f "$todo_file" ]]; then
        log_error "TODO.md not found at $todo_file"
        return 1
    fi

    # Get next available task ID
    local next_id
    next_id=$(_get_next_task_id "$todo_file")

    local tasks_created=0
    local task_lines=""
    local tmp_groups
    tmp_groups=$(mktemp)
    trap 'rm -f "${tmp_groups:-}"' RETURN

    echo "$groups_json" | jq -c '.[]' > "$tmp_groups"

    while IFS= read -r group; do
        local group_id file category finding_count max_severity
        group_id=$(echo "$group" | jq -r '.id')
        file=$(echo "$group" | jq -r '.file')
        category=$(echo "$group" | jq -r '.category')
        finding_count=$(echo "$group" | jq -r '.finding_count')
        max_severity=$(echo "$group" | jq -r '.max_severity')

        # Check for existing task in TODO.md covering this file + category
        if _task_exists_for_group "$todo_file" "$file" "$category"; then
            log_info "  Skipping: task already exists for $file ($category)"
            # Mark as written so we don't check again
            db "$SWEEP_DB" "UPDATE task_groups SET todo_written = 1 WHERE id = $group_id;" 2>/dev/null || true
            continue
        fi

        # Build human-readable category label
        local cat_label
        cat_label=$(_category_label "$category")

        # Build task description
        local short_file
        short_file=$(basename "$file")
        local task_id="t${next_id}"
        local dispatch_tag=""
        if [[ "$auto_dispatch" == "true" ]]; then
            dispatch_tag=" #auto-dispatch"
        fi

        # Estimate time based on finding count
        local estimate
        if [[ "$finding_count" -le 3 ]]; then
            estimate="~30m"
        elif [[ "$finding_count" -le 8 ]]; then
            estimate="~1h"
        else
            estimate="~2h"
        fi

        local today
        today=$(date -u '+%Y-%m-%d')
        local task_desc="Fix ${finding_count} ${cat_label} in ${short_file} (${max_severity}) — quality sweep findings for ${file} #quality #auto-review${dispatch_tag} ${estimate} logged:${today}"
        local task_line="- [ ] ${task_id} ${task_desc}"

        if [[ "$dry_run" == "true" ]]; then
            echo "  [DRY RUN] $task_line"
        else
            task_lines="${task_lines}${task_line}"$'\n'

            # Update DB
            local esc_task_id
            esc_task_id=$(sql_escape "$task_id")
            db "$SWEEP_DB" "
                UPDATE task_groups SET task_id = '$esc_task_id', todo_written = 1 WHERE id = $group_id;
                UPDATE findings SET task_created = 1, task_id = '$esc_task_id'
                    WHERE id IN (SELECT finding_id FROM group_findings WHERE group_id = $group_id);
            " 2>/dev/null || true
        fi

        tasks_created=$((tasks_created + 1))
        next_id=$((next_id + 1))
    done < "$tmp_groups"

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY RUN] Would create $tasks_created task(s)"
        return 0
    fi

    if [[ -z "$task_lines" ]]; then
        log_info "No new tasks to create (all groups already covered)"
        return 0
    fi

    # Insert task lines into TODO.md Backlog section
    _insert_tasks_into_todo "$todo_file" "$task_lines"

    log_success "Created $tasks_created task(s) in TODO.md"

    # Auto-dispatch if requested
    if [[ "$auto_dispatch" == "true" ]]; then
        _trigger_auto_dispatch "$repo_root"
    fi

    return 0
}

# =============================================================================
# Get next available task ID from TODO.md
# =============================================================================

_get_next_task_id() {
    local todo_file="$1"

    # Find the highest top-level task ID (tNNN, not tNNN.N subtasks)
    local max_id
    max_id=$(grep -oE '\bt([0-9]+)\b' "$todo_file" 2>/dev/null \
        | grep -oE '[0-9]+' \
        | sort -n \
        | tail -1)

    if [[ -z "$max_id" ]]; then
        echo "300"
    else
        echo "$((max_id + 1))"
    fi
    return 0
}

# =============================================================================
# Check if a task already exists for a file + category
# =============================================================================

_task_exists_for_group() {
    local todo_file="$1"
    local file="$2"
    local category="$3"

    local short_file
    short_file=$(basename "$file")

    # Check for existing open tasks mentioning this file and category-related keywords
    local cat_keywords
    cat_keywords=$(_category_keywords "$category")

    # Search TODO.md for open tasks matching file + category
    local pattern="- \\[ \\] .*${short_file}.*${cat_keywords}"
    if grep -qiE "$pattern" "$todo_file" 2>/dev/null; then
        return 0
    fi

    # Also check for the exact file path
    if grep -qF "$file" "$todo_file" 2>/dev/null; then
        # Found the file path — check if it's in an open task with quality/review tags
        if grep -F "$file" "$todo_file" 2>/dev/null | grep -qE '- \[ \] .*#(quality|auto-review)'; then
            return 0
        fi
    fi

    return 1
}

# =============================================================================
# Category helpers
# =============================================================================

_category_label() {
    local category="$1"
    case "$category" in
        code_smell)        echo "code smells" ;;
        bug)               echo "bugs" ;;
        vulnerability)     echo "vulnerabilities" ;;
        security_hotspot)  echo "security hotspots" ;;
        duplication)       echo "duplications" ;;
        style)             echo "style issues" ;;
        performance)       echo "performance issues" ;;
        *)                 echo "${category} issues" ;;
    esac
    return 0
}

_category_keywords() {
    local category="$1"
    case "$category" in
        code_smell)        echo "code.smell|smell" ;;
        bug)               echo "bug" ;;
        vulnerability)     echo "vulnerabilit|vuln" ;;
        security_hotspot)  echo "security.hotspot|hotspot" ;;
        duplication)       echo "duplicat" ;;
        style)             echo "style" ;;
        performance)       echo "perf" ;;
        *)                 echo "$category" ;;
    esac
    return 0
}

# =============================================================================
# Insert task lines into TODO.md Backlog section
# =============================================================================

_insert_tasks_into_todo() {
    local todo_file="$1"
    local task_lines="$2"

    # Find the Backlog section header line number
    local backlog_line
    backlog_line=$(grep -n '^## Backlog' "$todo_file" 2>/dev/null | head -1 | cut -d: -f1)

    if [[ -z "$backlog_line" ]]; then
        log_warn "No '## Backlog' section found in TODO.md — appending to end"
        echo "" >> "$todo_file"
        echo "## Quality Sweep Tasks" >> "$todo_file"
        echo "" >> "$todo_file"
        printf '%s' "$task_lines" >> "$todo_file"
        return 0
    fi

    # Find the first task line after the Backlog header (skip blank lines)
    local insert_line=$((backlog_line + 1))
    local total_lines
    total_lines=$(wc -l < "$todo_file")

    # Skip blank lines after the header to find the insertion point
    while [[ "$insert_line" -le "$total_lines" ]]; do
        local line_content
        line_content=$(sed -n "${insert_line}p" "$todo_file")
        # Stop at the first non-blank line (task or next section)
        if [[ -n "$line_content" ]]; then
            break
        fi
        insert_line=$((insert_line + 1))
    done

    # Find the end of the existing task block (before next section header)
    local end_line="$insert_line"
    while [[ "$end_line" -le "$total_lines" ]]; do
        local line_content
        line_content=$(sed -n "${end_line}p" "$todo_file")
        # Stop at next section header
        if echo "$line_content" | grep -qE '^## '; then
            break
        fi
        end_line=$((end_line + 1))
    done

    # Insert before the next section (or at end of backlog tasks)
    # Go back to last non-blank line
    local actual_insert=$((end_line - 1))
    while [[ "$actual_insert" -gt "$backlog_line" ]]; do
        local line_content
        line_content=$(sed -n "${actual_insert}p" "$todo_file")
        if [[ -n "$line_content" ]]; then
            break
        fi
        actual_insert=$((actual_insert - 1))
    done

    # Insert after the last task in the Backlog section
    local tmp_todo
    tmp_todo=$(mktemp)
    {
        head -n "$actual_insert" "$todo_file"
        printf '%s' "$task_lines"
        tail -n +"$((actual_insert + 1))" "$todo_file"
    } > "$tmp_todo"

    mv "$tmp_todo" "$todo_file"

    log_info "Inserted tasks after line $actual_insert in TODO.md"
    return 0
}

# =============================================================================
# Trigger supervisor auto-pickup
# =============================================================================

_trigger_auto_dispatch() {
    local repo_root="$1"
    local supervisor="${SCRIPT_DIR}/supervisor-helper.sh"

    if [[ ! -x "$supervisor" ]]; then
        log_warn "supervisor-helper.sh not found — tasks created but not dispatched"
        log_info "Tasks tagged #auto-dispatch will be picked up on next supervisor pulse"
        return 0
    fi

    log_info "Triggering supervisor auto-pickup..."

    if "$supervisor" auto-pickup --repo "$repo_root" 2>/dev/null; then
        log_success "Supervisor auto-pickup complete"
    else
        log_warn "Supervisor auto-pickup returned non-zero (may be normal if no new tasks)"
    fi

    return 0
}

# =============================================================================
# Command: stats — Show sweep statistics
# =============================================================================

cmd_stats() {
    ensure_db

    echo ""
    log_info "Quality Sweep Statistics"
    echo ""

    # Total findings by source
    echo "Findings by source:"
    db "$SWEEP_DB" -separator '|' "
        SELECT source, COUNT(*) AS total,
               SUM(CASE WHEN is_duplicate = 0 AND task_created = 0 THEN 1 ELSE 0 END) AS actionable,
               SUM(CASE WHEN task_created = 1 THEN 1 ELSE 0 END) AS tasked,
               SUM(CASE WHEN is_duplicate = 1 THEN 1 ELSE 0 END) AS dupes
        FROM findings
        GROUP BY source
        ORDER BY total DESC;
    " 2>/dev/null | while IFS='|' read -r src total actionable tasked dupes; do
        printf "  %-15s total: %4s  actionable: %4s  tasked: %4s  dupes: %4s\n" "$src" "$total" "$actionable" "$tasked" "$dupes"
    done

    echo ""

    # Findings by severity
    echo "Findings by severity (non-duplicate):"
    db "$SWEEP_DB" -separator '|' "
        SELECT severity, COUNT(*)
        FROM findings
        WHERE is_duplicate = 0
        GROUP BY severity
        ORDER BY CASE severity
            WHEN 'critical' THEN 1
            WHEN 'high' THEN 2
            WHEN 'medium' THEN 3
            WHEN 'low' THEN 4
            ELSE 5
        END;
    " 2>/dev/null | while IFS='|' read -r sev cnt; do
        printf "  %-10s %s\n" "$sev" "$cnt"
    done

    echo ""

    # Task groups
    local total_groups pending_groups
    total_groups=$(db "$SWEEP_DB" "SELECT COUNT(*) FROM task_groups;" 2>/dev/null || echo "0")
    pending_groups=$(db "$SWEEP_DB" "SELECT COUNT(*) FROM task_groups WHERE todo_written = 0 AND finding_count > 0;" 2>/dev/null || echo "0")
    echo "Task groups: $total_groups total, $pending_groups pending"

    echo ""
    return 0
}

# =============================================================================
# Command: help
# =============================================================================

cmd_help() {
    cat << 'HELP'
Quality Sweep Helper - Finding-to-task pipeline (t245.3)

Groups normalized findings from all quality tools by file/category,
creates batched TODO tasks, and optionally auto-dispatches via supervisor.

Usage:
  quality-sweep-helper.sh ingest --source <SOURCE> [findings.json]
  quality-sweep-helper.sh create-tasks [OPTIONS]
  quality-sweep-helper.sh groups [--min-severity LEVEL]
  quality-sweep-helper.sh stats
  quality-sweep-helper.sh help

Commands:
  ingest          Import normalized findings from a quality tool
  create-tasks    Group findings and create TODO tasks
  groups          Show finding groups (file + category)
  stats           Show sweep statistics
  help            Show this help

Ingest options:
  --source SOURCE   Source tool: sonarcloud, codacy, codefactor, coderabbit, manual

Create-tasks options:
  --min-severity LEVEL   Minimum severity to include (default: medium)
  --dry-run              Show what would be created without writing
  --auto-dispatch        Tag tasks with #auto-dispatch and trigger supervisor

Findings JSON format (array of objects):
  [
    {
      "file": "path/to/file.sh",
      "line": 42,
      "severity": "medium",
      "category": "code_smell",
      "rule": "bash:S1234",
      "message": "Description of the issue"
    }
  ]

Severity levels: critical, high, medium, low, info
Categories: code_smell, bug, vulnerability, security_hotspot, duplication, style, performance

Examples:
  # Ingest SonarCloud findings
  sonarcloud-cli.sh issues --json | quality-sweep-helper.sh ingest --source sonarcloud

  # Preview tasks that would be created
  quality-sweep-helper.sh create-tasks --dry-run

  # Create tasks and auto-dispatch
  quality-sweep-helper.sh create-tasks --auto-dispatch

  # Show current finding groups
  quality-sweep-helper.sh groups --min-severity low
HELP
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        ingest)       cmd_ingest "$@" ;;
        create-tasks) cmd_create_tasks "$@" ;;
        groups)       cmd_groups "$@" ;;
        stats)        cmd_stats "$@" ;;
        help|--help|-h) cmd_help ;;
        *)
            log_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
