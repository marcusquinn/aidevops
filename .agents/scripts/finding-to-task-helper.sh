#!/usr/bin/env bash
# shellcheck disable=SC1091
# finding-to-task-helper.sh — Convert quality sweep findings into TODO tasks.
#
# t245.3: Finding-to-task pipeline — group findings, create TODO tasks, auto-dispatch.
#
# Reads from the quality-sweep findings DB (populated by quality-sweep-helper.sh),
# groups findings by file or rule, deduplicates against existing TODO.md entries,
# and generates TODO-compatible task lines. Optionally triggers supervisor auto-pickup.
#
# Usage:
#   finding-to-task-helper.sh group [--by file|rule|severity] [--source SOURCE] [--min-severity LEVEL]
#   finding-to-task-helper.sh create [--repo PATH] [--dry-run] [--auto-dispatch] [--min-severity LEVEL]
#   finding-to-task-helper.sh status
#   finding-to-task-helper.sh help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
init_log_file

# =============================================================================
# Constants
# =============================================================================

readonly SWEEP_DATA_DIR="${HOME}/.aidevops/.agent-workspace/work/quality-sweep"
readonly SWEEP_DB="${SWEEP_DATA_DIR}/findings.db"
readonly TASK_DB="${SWEEP_DATA_DIR}/finding-tasks.db"

# Minimum findings to create a grouped task (avoids noise)
readonly MIN_FINDINGS_PER_TASK=1

# =============================================================================
# SQLite wrapper
# =============================================================================

db() {
    sqlite3 -cmd ".timeout 5000" "$@"
    return $?
}

# =============================================================================
# Task tracking DB initialization
# =============================================================================

init_task_db() {
    mkdir -p "$SWEEP_DATA_DIR" 2>/dev/null || true

    db "$TASK_DB" <<'SQL' >/dev/null
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS generated_tasks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    group_key       TEXT NOT NULL,
    group_by        TEXT NOT NULL DEFAULT 'file',
    task_line       TEXT NOT NULL,
    finding_count   INTEGER NOT NULL DEFAULT 0,
    max_severity    TEXT NOT NULL DEFAULT 'info',
    sources         TEXT NOT NULL DEFAULT '',
    todo_task_id    TEXT,
    dispatched      INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(group_key, group_by)
);

CREATE TABLE IF NOT EXISTS task_findings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id         INTEGER NOT NULL REFERENCES generated_tasks(id),
    finding_id      INTEGER NOT NULL,
    source          TEXT NOT NULL,
    file            TEXT NOT NULL DEFAULT '',
    line            INTEGER NOT NULL DEFAULT 0,
    severity        TEXT NOT NULL DEFAULT 'info',
    rule            TEXT NOT NULL DEFAULT '',
    message         TEXT NOT NULL DEFAULT '',
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(task_id, finding_id, source)
);

CREATE INDEX IF NOT EXISTS idx_gt_group ON generated_tasks(group_key, group_by);
CREATE INDEX IF NOT EXISTS idx_gt_severity ON generated_tasks(max_severity);
CREATE INDEX IF NOT EXISTS idx_tf_task ON task_findings(task_id);
SQL
    return 0
}

# =============================================================================
# Severity helpers
# =============================================================================

severity_rank() {
    local sev="$1"
    case "$sev" in
        critical) echo 1 ;;
        high)     echo 2 ;;
        medium)   echo 3 ;;
        low)      echo 4 ;;
        info)     echo 5 ;;
        *)        echo 5 ;;
    esac
    return 0
}

higher_severity() {
    local a="$1"
    local b="$2"
    local rank_a
    local rank_b
    rank_a=$(severity_rank "$a")
    rank_b=$(severity_rank "$b")
    if [[ "$rank_a" -le "$rank_b" ]]; then
        echo "$a"
    else
        echo "$b"
    fi
    return 0
}

severity_to_tag() {
    local sev="$1"
    case "$sev" in
        critical) echo "#critical" ;;
        high)     echo "#high" ;;
        medium)   echo "#medium" ;;
        low)      echo "#low" ;;
        *)        echo "#info" ;;
    esac
    return 0
}

severity_to_estimate() {
    local sev="$1"
    local count="$2"
    case "$sev" in
        critical) echo "~2h" ;;
        high)
            if [[ "$count" -gt 5 ]]; then
                echo "~2h"
            else
                echo "~1h"
            fi
            ;;
        medium)
            if [[ "$count" -gt 10 ]]; then
                echo "~2h"
            elif [[ "$count" -gt 3 ]]; then
                echo "~1h"
            else
                echo "~30m"
            fi
            ;;
        *)       echo "~30m" ;;
    esac
    return 0
}

# =============================================================================
# Check findings DB exists
# =============================================================================

check_findings_db() {
    if [[ ! -f "$SWEEP_DB" ]]; then
        print_error "Findings database not found at $SWEEP_DB"
        print_info "Run 'quality-sweep-helper.sh sonarcloud fetch' first to populate findings."
        return 1
    fi
    return 0
}

# =============================================================================
# Group findings
# =============================================================================

cmd_group() {
    local group_by="file"
    local source=""
    local min_severity="info"
    local format="table"
    local limit="50"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --by)           group_by="${2:-file}"; shift 2 ;;
            --source)       source="${2:-}"; shift 2 ;;
            --min-severity) min_severity="${2:-info}"; shift 2 ;;
            --format)       format="${2:-table}"; shift 2 ;;
            --limit)        limit="${2:-50}"; shift 2 ;;
            *)              shift ;;
        esac
    done

    check_findings_db || return 1

    local min_rank
    min_rank=$(severity_rank "$min_severity")

    # Build WHERE clause
    local where="WHERE status IN ('OPEN', 'CONFIRMED')"
    if [[ -n "$source" ]]; then
        where="$where AND source='$(echo "$source" | sed "s/'/''/g")'"
    fi
    where="$where AND CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END <= $min_rank"

    local query=""
    case "$group_by" in
        file)
            query="SELECT file as group_key, count(*) as finding_count, MIN(CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END) as sev_rank, CASE MIN(CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END) WHEN 1 THEN 'critical' WHEN 2 THEN 'high' WHEN 3 THEN 'medium' WHEN 4 THEN 'low' ELSE 'info' END as max_severity, GROUP_CONCAT(DISTINCT source) as sources FROM findings $where GROUP BY file HAVING count(*) >= $MIN_FINDINGS_PER_TASK ORDER BY sev_rank ASC, finding_count DESC LIMIT $limit;"
            ;;
        rule)
            query="SELECT rule as group_key, count(*) as finding_count, MIN(CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END) as sev_rank, CASE MIN(CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END) WHEN 1 THEN 'critical' WHEN 2 THEN 'high' WHEN 3 THEN 'medium' WHEN 4 THEN 'low' ELSE 'info' END as max_severity, GROUP_CONCAT(DISTINCT source) as sources FROM findings $where GROUP BY rule HAVING count(*) >= $MIN_FINDINGS_PER_TASK ORDER BY sev_rank ASC, finding_count DESC LIMIT $limit;"
            ;;
        severity)
            query="SELECT severity as group_key, count(*) as finding_count, MIN(CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END) as sev_rank, severity as max_severity, GROUP_CONCAT(DISTINCT source) as sources FROM findings $where GROUP BY severity ORDER BY sev_rank ASC LIMIT $limit;"
            ;;
        *)
            print_error "Unknown grouping: $group_by (use: file, rule, severity)"
            return 1
            ;;
    esac

    case "$format" in
        json)
            db "$SWEEP_DB" -json "$query"
            ;;
        csv)
            db "$SWEEP_DB" -header -csv "$query"
            ;;
        table|*)
            echo ""
            print_info "Findings grouped by: $group_by (min severity: $min_severity)"
            echo ""
            db "$SWEEP_DB" -header -column "$query"
            ;;
    esac
    return 0
}

# =============================================================================
# Generate task description from a group of findings
# =============================================================================

build_task_description() {
    local group_by="$1"
    local group_key="$2"
    local finding_count="$3"
    local max_severity="$4"
    local sources="$5"

    local desc=""
    local priority_tag
    local estimate
    priority_tag=$(severity_to_tag "$max_severity")
    estimate=$(severity_to_estimate "$max_severity" "$finding_count")

    case "$group_by" in
        file)
            local short_file
            short_file=$(basename "$group_key")
            if [[ "$finding_count" -eq 1 ]]; then
                desc="Fix quality finding in ${short_file} (${max_severity}) [${group_key}]"
            else
                desc="Fix ${finding_count} quality findings in ${short_file} (${max_severity}) [${group_key}]"
            fi
            ;;
        rule)
            if [[ "$finding_count" -eq 1 ]]; then
                desc="Fix ${group_key} quality rule violation (${max_severity})"
            else
                desc="Fix ${finding_count} ${group_key} violations across codebase (${max_severity})"
            fi
            ;;
        severity)
            desc="Fix ${finding_count} ${max_severity}-severity quality findings"
            ;;
    esac

    local source_tag=""
    if [[ -n "$sources" ]]; then
        local src
        for src in $(echo "$sources" | tr ',' ' '); do
            source_tag="${source_tag} #${src}"
        done
    fi

    echo "${desc} ${priority_tag} #quality #auto-dispatch${source_tag} ${estimate}"
    return 0
}

# =============================================================================
# Check if a task already exists in TODO.md for this group
# =============================================================================

task_exists_in_todo() {
    local todo_file="$1"
    local group_key="$2"
    local group_by="$3"

    if [[ ! -f "$todo_file" ]]; then
        return 1
    fi

    case "$group_by" in
        file)
            # Check if there's an open task referencing this file path
            if grep -qE "^[[:space:]]*- \[ \] t[0-9].*\[${group_key}\]" "$todo_file" 2>/dev/null; then
                return 0
            fi
            ;;
        rule)
            # Check if there's an open task referencing this rule
            if grep -qF "$group_key" "$todo_file" 2>/dev/null; then
                if grep -qE "^[[:space:]]*- \[ \] t[0-9].*$(echo "$group_key" | sed 's/[.[\*^$()+?{|]/\\&/g')" "$todo_file" 2>/dev/null; then
                    return 0
                fi
            fi
            ;;
        severity)
            # Severity-based tasks are always unique enough
            return 1
            ;;
    esac
    return 1
}

# =============================================================================
# Check if a group was already processed in the task DB
# =============================================================================

group_already_processed() {
    local group_key="$1"
    local group_by="$2"

    local existing
    existing=$(db "$TASK_DB" "SELECT id FROM generated_tasks WHERE group_key='$(echo "$group_key" | sed "s/'/''/g")' AND group_by='$(echo "$group_by" | sed "s/'/''/g")';" 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        return 0
    fi
    return 1
}

# =============================================================================
# Create tasks from findings
# =============================================================================

cmd_create() {
    local repo=""
    local dry_run="false"
    local auto_dispatch="false"
    local group_by="file"
    local source=""
    local min_severity="medium"
    local limit="20"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)           repo="${2:-}"; shift 2 ;;
            --dry-run)        dry_run="true"; shift ;;
            --auto-dispatch)  auto_dispatch="true"; shift ;;
            --by)             group_by="${2:-file}"; shift 2 ;;
            --source)         source="${2:-}"; shift 2 ;;
            --min-severity)   min_severity="${2:-medium}"; shift 2 ;;
            --limit)          limit="${2:-20}"; shift 2 ;;
            *)                shift ;;
        esac
    done

    check_findings_db || return 1
    init_task_db

    if [[ -z "$repo" ]]; then
        repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi

    local todo_file="$repo/TODO.md"
    if [[ ! -f "$todo_file" ]]; then
        print_error "TODO.md not found at $todo_file"
        return 1
    fi

    local min_rank
    min_rank=$(severity_rank "$min_severity")

    # Build WHERE clause for findings
    local where="WHERE status IN ('OPEN', 'CONFIRMED')"
    if [[ -n "$source" ]]; then
        where="$where AND source='$(echo "$source" | sed "s/'/''/g")'"
    fi
    where="$where AND CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END <= $min_rank"

    # Get grouped findings
    local groups_json
    case "$group_by" in
        file)
            groups_json=$(db "$SWEEP_DB" -json "SELECT file as group_key, count(*) as finding_count, CASE MIN(CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END) WHEN 1 THEN 'critical' WHEN 2 THEN 'high' WHEN 3 THEN 'medium' WHEN 4 THEN 'low' ELSE 'info' END as max_severity, GROUP_CONCAT(DISTINCT source) as sources FROM findings $where GROUP BY file HAVING count(*) >= $MIN_FINDINGS_PER_TASK ORDER BY MIN(CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END) ASC, count(*) DESC LIMIT $limit;" 2>/dev/null || echo "[]")
            ;;
        rule)
            groups_json=$(db "$SWEEP_DB" -json "SELECT rule as group_key, count(*) as finding_count, CASE MIN(CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END) WHEN 1 THEN 'critical' WHEN 2 THEN 'high' WHEN 3 THEN 'medium' WHEN 4 THEN 'low' ELSE 'info' END as max_severity, GROUP_CONCAT(DISTINCT source) as sources FROM findings $where GROUP BY rule HAVING count(*) >= $MIN_FINDINGS_PER_TASK ORDER BY MIN(CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END) ASC, count(*) DESC LIMIT $limit;" 2>/dev/null || echo "[]")
            ;;
        *)
            print_error "Task creation only supports --by file or --by rule"
            return 1
            ;;
    esac

    if [[ -z "$groups_json" ]] || [[ "$groups_json" == "[]" ]]; then
        print_info "No findings match the criteria (source: ${source:-all}, min severity: $min_severity)"
        return 0
    fi

    local group_count
    group_count=$(echo "$groups_json" | jq 'length')
    print_info "Found $group_count finding groups (grouped by: $group_by, min severity: $min_severity)"

    local created=0
    local skipped_existing=0
    local skipped_processed=0
    local task_lines=""

    local i=0
    while [[ $i -lt $group_count ]]; do
        local group_key finding_count max_severity sources
        group_key=$(echo "$groups_json" | jq -r ".[$i].group_key")
        finding_count=$(echo "$groups_json" | jq -r ".[$i].finding_count")
        max_severity=$(echo "$groups_json" | jq -r ".[$i].max_severity")
        sources=$(echo "$groups_json" | jq -r ".[$i].sources")

        # Skip if already in TODO.md
        if task_exists_in_todo "$todo_file" "$group_key" "$group_by"; then
            skipped_existing=$((skipped_existing + 1))
            i=$((i + 1))
            continue
        fi

        # Skip if already processed in task DB
        if group_already_processed "$group_key" "$group_by"; then
            skipped_processed=$((skipped_processed + 1))
            i=$((i + 1))
            continue
        fi

        # Build task description
        local task_desc
        task_desc=$(build_task_description "$group_by" "$group_key" "$finding_count" "$max_severity" "$sources")

        local task_line="- [ ] ${task_desc}"

        if [[ "$dry_run" == "true" ]]; then
            echo "$task_line"
        else
            task_lines="${task_lines}${task_line}"$'\n'

            # Record in task DB
            local escaped_key escaped_line
            escaped_key=$(echo "$group_key" | sed "s/'/''/g")
            escaped_line=$(echo "$task_line" | sed "s/'/''/g")
            db "$TASK_DB" "INSERT OR REPLACE INTO generated_tasks (group_key, group_by, task_line, finding_count, max_severity, sources) VALUES ('$escaped_key', '$group_by', '$escaped_line', $finding_count, '$max_severity', '$(echo "$sources" | sed "s/'/''/g")');"

            # Record individual findings linked to this task
            local task_row_id
            task_row_id=$(db "$TASK_DB" "SELECT id FROM generated_tasks WHERE group_key='$escaped_key' AND group_by='$group_by';")

            local findings_sql
            case "$group_by" in
                file)
                    findings_sql="SELECT id, source, file, line, severity, rule, message FROM findings $where AND file='$escaped_key';"
                    ;;
                rule)
                    findings_sql="SELECT id, source, file, line, severity, rule, message FROM findings $where AND rule='$escaped_key';"
                    ;;
            esac

            db "$SWEEP_DB" -json "$findings_sql" 2>/dev/null | jq -r '.[] | "INSERT OR IGNORE INTO task_findings (task_id, finding_id, source, file, line, severity, rule, message) VALUES ('"$task_row_id"', \(.id), '"'"'\(.source)'"'"', '"'"'\(.file | gsub("'"'"'"; "'"'"''"'"'"))'"'"', \(.line), '"'"'\(.severity)'"'"', '"'"'\(.rule | gsub("'"'"'"; "'"'"''"'"'"))'"'"', '"'"'\(.message | gsub("'"'"'"; "'"'"''"'"'"))'"'"');"' 2>/dev/null | db "$TASK_DB" 2>/dev/null || true
        fi

        created=$((created + 1))
        i=$((i + 1))
    done

    if [[ "$dry_run" == "true" ]]; then
        echo ""
        print_info "Dry run: $created tasks would be created ($skipped_existing already in TODO, $skipped_processed already processed)"
        return 0
    fi

    if [[ $created -eq 0 ]]; then
        print_info "No new tasks to create ($skipped_existing already in TODO, $skipped_processed already processed)"
        return 0
    fi

    # Output the generated task lines
    echo ""
    print_success "Generated $created task lines ($skipped_existing skipped — already in TODO, $skipped_processed skipped — already processed):"
    echo ""
    echo "$task_lines"
    echo ""
    print_info "These task lines need task IDs (tNNN) assigned before adding to TODO.md."
    print_info "The supervisor or a human should insert them with proper IDs."

    # Auto-dispatch: trigger supervisor auto-pickup
    if [[ "$auto_dispatch" == "true" ]]; then
        dispatch_tasks "$repo"
    fi

    return 0
}

# =============================================================================
# Dispatch tasks via supervisor auto-pickup
# =============================================================================

dispatch_tasks() {
    local repo="$1"

    local supervisor="${SCRIPT_DIR}/supervisor-helper.sh"
    if [[ ! -x "$supervisor" ]]; then
        print_warning "supervisor-helper.sh not found or not executable — skipping auto-dispatch"
        return 0
    fi

    print_info "Triggering supervisor auto-pickup for #auto-dispatch tasks..."
    if "$supervisor" auto-pickup --repo "$repo" 2>/dev/null; then
        print_success "Supervisor auto-pickup completed"
    else
        print_warning "Supervisor auto-pickup returned non-zero (tasks may need manual IDs first)"
    fi
    return 0
}

# =============================================================================
# Status
# =============================================================================

cmd_status() {
    echo ""
    print_info "Finding-to-Task Pipeline Status"
    echo ""

    # Check findings DB
    echo "Findings Database:"
    if [[ -f "$SWEEP_DB" ]]; then
        local total_findings
        total_findings=$(db "$SWEEP_DB" "SELECT count(*) FROM findings WHERE status IN ('OPEN', 'CONFIRMED');" 2>/dev/null || echo "0")
        echo "  Location: $SWEEP_DB"
        echo "  Open findings: $total_findings"

        echo ""
        echo "  By source:"
        db "$SWEEP_DB" -header -column "SELECT source, count(*) as count FROM findings WHERE status IN ('OPEN', 'CONFIRMED') GROUP BY source ORDER BY count DESC;" 2>/dev/null || echo "  (no data)"

        echo ""
        echo "  By severity:"
        db "$SWEEP_DB" -header -column "SELECT severity, count(*) as count FROM findings WHERE status IN ('OPEN', 'CONFIRMED') GROUP BY severity ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END;" 2>/dev/null || echo "  (no data)"
    else
        echo "  Not found — run 'quality-sweep-helper.sh sonarcloud fetch' first"
    fi

    echo ""

    # Check task DB
    echo "Task Generation Database:"
    if [[ -f "$TASK_DB" ]]; then
        local total_tasks
        total_tasks=$(db "$TASK_DB" "SELECT count(*) FROM generated_tasks;" 2>/dev/null || echo "0")
        local dispatched_tasks
        dispatched_tasks=$(db "$TASK_DB" "SELECT count(*) FROM generated_tasks WHERE dispatched=1;" 2>/dev/null || echo "0")
        echo "  Location: $TASK_DB"
        echo "  Generated tasks: $total_tasks"
        echo "  Dispatched: $dispatched_tasks"

        if [[ "$total_tasks" -gt 0 ]]; then
            echo ""
            echo "  By severity:"
            db "$TASK_DB" -header -column "SELECT max_severity, count(*) as count FROM generated_tasks GROUP BY max_severity ORDER BY CASE max_severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END;" 2>/dev/null || echo "  (no data)"

            echo ""
            echo "  Recent tasks:"
            db "$TASK_DB" -header -column "SELECT group_key, finding_count, max_severity, created_at FROM generated_tasks ORDER BY created_at DESC LIMIT 5;" 2>/dev/null || echo "  (no data)"
        fi
    else
        echo "  Not yet created — run 'finding-to-task-helper.sh create' first"
    fi

    echo ""
    return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    echo ""
    echo "finding-to-task-helper.sh — Convert quality findings into TODO tasks"
    echo ""
    echo "Usage: finding-to-task-helper.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  group      Preview how findings would be grouped"
    echo "  create     Generate TODO-compatible task lines from findings"
    echo "  status     Show pipeline status and statistics"
    echo "  help       Show this help message"
    echo ""
    echo "Group options:"
    echo "  --by TYPE          Group by: file (default), rule, severity"
    echo "  --source SOURCE    Filter by source (e.g., sonarcloud, codacy)"
    echo "  --min-severity LVL Minimum severity: critical, high, medium (default), low, info"
    echo "  --format FMT       Output format: table (default), json, csv"
    echo "  --limit N          Max groups to show (default: 50)"
    echo ""
    echo "Create options:"
    echo "  --repo PATH        Repository root (default: git root or cwd)"
    echo "  --dry-run          Preview task lines without recording"
    echo "  --auto-dispatch    Trigger supervisor auto-pickup after creation"
    echo "  --by TYPE          Group by: file (default), rule"
    echo "  --source SOURCE    Filter by source"
    echo "  --min-severity LVL Minimum severity (default: medium)"
    echo "  --limit N          Max tasks to create (default: 20)"
    echo ""
    echo "Pipeline:"
    echo "  1. quality-sweep-helper.sh sonarcloud fetch   # Populate findings DB"
    echo "  2. finding-to-task-helper.sh group             # Preview groupings"
    echo "  3. finding-to-task-helper.sh create --dry-run  # Preview task lines"
    echo "  4. finding-to-task-helper.sh create            # Generate tasks"
    echo "  5. Add task IDs (tNNN) and insert into TODO.md"
    echo "  6. finding-to-task-helper.sh create --auto-dispatch  # Or auto-pickup"
    echo ""
    echo "Examples:"
    echo "  finding-to-task-helper.sh group --by file --min-severity high"
    echo "  finding-to-task-helper.sh create --dry-run --by rule"
    echo "  finding-to-task-helper.sh create --auto-dispatch --min-severity critical"
    echo "  finding-to-task-helper.sh status"
    echo ""
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        group)
            cmd_group "$@"
            ;;
        create)
            cmd_create "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $cmd"
            show_help
            return 1
            ;;
    esac
    return 0
}

main "$@"
