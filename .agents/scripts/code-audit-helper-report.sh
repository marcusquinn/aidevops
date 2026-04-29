#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Code Audit Helper -- Report & Summary Output
# =============================================================================
# Report generation and summary output functions for the unified code audit
# system. Supports text, JSON, and CSV output formats.
#
# Usage: source "${SCRIPT_DIR}/code-audit-helper-report.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, color vars, etc.)
#   - code-audit-helper.sh (db, sql_escape, ensure_db, AUDIT_DB constants)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CODE_AUDIT_REPORT_LIB_LOADED:-}" ]] && return 0
_CODE_AUDIT_REPORT_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

# =============================================================================
# Summary Output
# =============================================================================

# Print run metadata (repo, PR, SHA, timestamps, services).
print_summary_header() {
    local run_id="$1"

    echo "============================================"
    echo "  Unified Code Audit Report (Run #${run_id})"
    echo "============================================"
    echo ""

    local run_info
    run_info=$(db "$AUDIT_DB" -separator '|' "
        SELECT repo, pr_number, head_sha, started_at, completed_at, services_run
        FROM audit_runs WHERE id = $run_id;
    ")
    if [[ -n "$run_info" ]]; then
        local repo pr sha started completed services
        IFS='|' read -r repo pr sha started completed services <<<"$run_info"
        echo "  Repository:  $repo"
        [[ "$pr" -gt 0 ]] && echo "  PR:          #${pr}"
        echo "  SHA:         $sha"
        echo "  Started:     $started"
        echo "  Completed:   $completed"
        echo "  Services:    $services"
        echo ""
    fi
    return 0
}

# Print findings grouped by severity with colour coding.
print_findings_by_severity() {
    local run_id="$1"

    echo "  Findings by Severity:"
    db "$AUDIT_DB" -separator '|' "
        SELECT severity, COUNT(*) as cnt
        FROM audit_findings
        WHERE run_id = $run_id AND is_duplicate = 0
        GROUP BY severity
        ORDER BY
            CASE severity
                WHEN 'critical' THEN 1
                WHEN 'high' THEN 2
                WHEN 'medium' THEN 3
                WHEN 'low' THEN 4
                ELSE 5
            END;
    " | while IFS='|' read -r sev cnt; do
        local color="$NC"
        case "$sev" in
        critical) color="$RED" ;;
        high) color="$RED" ;;
        medium) color="$YELLOW" ;;
        low) color="$BLUE" ;;
        *) color="$NC" ;;
        esac
        printf "    ${color}%-10s${NC} %s\n" "$sev" "$cnt"
    done
    echo ""
    return 0
}

# Print the top 10 most affected files.
print_most_affected_files() {
    local run_id="$1"

    echo "  Most Affected Files (top 10):"
    db "$AUDIT_DB" -separator '|' "
        SELECT path, COUNT(*) as cnt,
               GROUP_CONCAT(DISTINCT source) as sources,
               GROUP_CONCAT(DISTINCT severity) as severities
        FROM audit_findings
        WHERE run_id = $run_id AND is_duplicate = 0 AND path != ''
        GROUP BY path
        ORDER BY cnt DESC
        LIMIT 10;
    " | while IFS='|' read -r path cnt sources severities; do
        printf "    %-45s %3s  [%s] (%s)\n" "$path" "$cnt" "$sources" "$severities"
    done
    echo ""
    return 0
}

# Print deduplication statistics.
print_dedup_stats() {
    local run_id="$1"

    local total_raw unique_count dup_count
    total_raw=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE run_id = $run_id;")
    unique_count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE run_id = $run_id AND is_duplicate = 0;")
    dup_count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE run_id = $run_id AND is_duplicate = 1;")
    echo "  Deduplication:"
    echo "    Total raw findings:  $total_raw"
    echo "    Unique findings:     $unique_count"
    echo "    Duplicates removed:  $dup_count"
    echo ""
    return 0
}

# Print findings grouped by source (excluding duplicates).
print_findings_by_source() {
    local run_id="$1"

    echo "  Findings by Source:"
    db "$AUDIT_DB" -separator '|' "
        SELECT source, COUNT(*) as cnt
        FROM audit_findings
        WHERE run_id = $run_id AND is_duplicate = 0
        GROUP BY source
        ORDER BY cnt DESC;
    " | while IFS='|' read -r source cnt; do
        printf "    %-15s %s\n" "$source" "$cnt"
    done

    echo ""
    return 0
}

# Print findings grouped by category (excluding duplicates).
print_findings_by_category() {
    local run_id="$1"

    echo "  Findings by Category:"
    db "$AUDIT_DB" -separator '|' "
        SELECT category, COUNT(*) as cnt
        FROM audit_findings
        WHERE run_id = $run_id AND is_duplicate = 0
        GROUP BY category
        ORDER BY cnt DESC;
    " | while IFS='|' read -r cat cnt; do
        printf "    %-15s %s\n" "$cat" "$cnt"
    done

    echo ""
    return 0
}

print_summary() {
    local run_id="$1"

    print_summary_header "$run_id"
    print_findings_by_source "$run_id"
    print_findings_by_severity "$run_id"
    print_findings_by_category "$run_id"
    print_most_affected_files "$run_id"
    print_dedup_stats "$run_id"

    return 0
}

# =============================================================================
# Report Command
# =============================================================================

# Parse report command arguments into _RPT_FORMAT, _RPT_SEVERITY, _RPT_RUN_ID, _RPT_LIMIT.
# Returns 1 on validation failure.
parse_report_args() {
    _RPT_FORMAT="text"
    _RPT_SEVERITY=""
    _RPT_RUN_ID=""
    _RPT_LIMIT=100

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --format)
            [[ -z "${2:-}" || "$2" == --* ]] && {
                log_error "Missing value for --format"
                return 1
            }
            _RPT_FORMAT="$2"
            shift 2
            ;;
        --severity)
            [[ -z "${2:-}" || "$2" == --* ]] && {
                log_error "Missing value for --severity"
                return 1
            }
            _RPT_SEVERITY="$2"
            shift 2
            ;;
        --run)
            [[ -z "${2:-}" || "$2" == --* ]] && {
                log_error "Missing value for --run"
                return 1
            }
            _RPT_RUN_ID="$2"
            shift 2
            ;;
        --limit)
            [[ -z "${2:-}" || "$2" == --* ]] && {
                log_error "Missing value for --limit"
                return 1
            }
            _RPT_LIMIT="$2"
            shift 2
            ;;
        *)
            log_warn "Unknown option: $1"
            shift
            ;;
        esac
    done
    return 0
}

# Output findings in human-readable text format.
report_text() {
    local run_id="$1"
    local where="$2"
    local limit="$3"

    echo ""
    echo "Audit Findings (Run #${run_id})"
    echo "==============================="
    echo ""

    db "$AUDIT_DB" -separator $'\x1f' "
            SELECT source, severity, path, line,
                   substr(replace(replace(description, char(10), ' '), char(13), ''), 1, 120)
            FROM audit_findings
            $where
            ORDER BY
                CASE severity
                    WHEN 'critical' THEN 1
                    WHEN 'high' THEN 2
                    WHEN 'medium' THEN 3
                    WHEN 'low' THEN 4
                    ELSE 5
                END,
                path, line
            LIMIT $limit;
        " | while IFS=$'\x1f' read -r source sev path line desc; do
        local color="$NC"
        case "$sev" in
        critical) color="$RED" ;;
        high) color="$RED" ;;
        medium) color="$YELLOW" ;;
        low) color="$BLUE" ;;
        *) color="$NC" ;;
        esac

        local location=""
        if [[ -n "$path" && "$path" != "" ]]; then
            location="${path}:${line}"
        else
            location="(general)"
        fi

        printf "  ${color}[%-8s]${NC} %-12s %s\n" "$sev" "$source" "$location"
        echo "    ${desc}"
        echo ""
    done

    local total
    total=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings $where;")
    echo "Total unique findings: ${total}"

    return 0
}

# Validate report inputs (run_id, limit) and resolve the latest run_id if unset.
# Sets _RPT_RUN_ID in caller scope via the global (already set by parse_report_args).
# Returns 1 on validation failure.
_report_validate_and_resolve() {
    local run_id="$1"
    local limit="$2"

    if [[ -n "$run_id" ]] && ! [[ "$run_id" =~ ^[0-9]+$ ]]; then
        log_error "Invalid run ID: $run_id"
        return 1
    fi
    if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
        log_error "Invalid limit: $limit"
        return 1
    fi

    if [[ -z "$run_id" ]]; then
        run_id=$(db "$AUDIT_DB" "SELECT id FROM audit_runs ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
        if [[ -z "$run_id" ]]; then
            log_error "No audit runs found. Run 'code-audit-helper.sh audit' first."
            return 1
        fi
        _RPT_RUN_ID="$run_id"
    fi

    return 0
}

# Dispatch report output to the correct format handler.
_report_dispatch_format() {
    local format="$1"
    local run_id="$2"
    local where="$3"
    local limit="$4"

    local severity_order="
                ORDER BY
                    CASE severity
                        WHEN 'critical' THEN 1
                        WHEN 'high' THEN 2
                        WHEN 'medium' THEN 3
                        WHEN 'low' THEN 4
                        ELSE 5
                    END,
                    path, line
                LIMIT $limit"

    case "$format" in
    json)
        db "$AUDIT_DB" -json "
                SELECT id, source, severity, path, line, description, category, rule_id
                FROM audit_findings
                $where
                $severity_order;
            "
        ;;
    csv)
        echo "id,source,severity,path,line,description,category,rule_id"
        db "$AUDIT_DB" -csv "
                SELECT id, source, severity, path, line,
                       substr(replace(description, char(10), ' '), 1, 200),
                       category, rule_id
                FROM audit_findings
                $where
                $severity_order;
            "
        ;;
    text | *)
        report_text "$run_id" "$where" "$limit"
        ;;
    esac

    return 0
}

cmd_report() {
    parse_report_args "$@" || return 1

    local format="$_RPT_FORMAT"
    local severity="$_RPT_SEVERITY"
    local run_id="$_RPT_RUN_ID"
    local limit="$_RPT_LIMIT"

    ensure_db
    _report_validate_and_resolve "$run_id" "$limit" || return 1
    run_id="$_RPT_RUN_ID"

    local where="WHERE run_id = $run_id AND is_duplicate = 0"
    if [[ -n "$severity" ]]; then
        where="${where} AND severity = '$(sql_escape "$severity")'"
    fi

    _report_dispatch_format "$format" "$run_id" "$where" "$limit"

    return 0
}

# =============================================================================
# Summary Command
# =============================================================================

cmd_summary() {
    local pr_number=""
    local run_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --pr)
            [[ -z "${2:-}" || "$2" == --* ]] && {
                log_error "Missing value for --pr"
                return 1
            }
            pr_number="$2"
            shift 2
            ;;
        --run)
            [[ -z "${2:-}" || "$2" == --* ]] && {
                log_error "Missing value for --run"
                return 1
            }
            run_id="$2"
            shift 2
            ;;
        *)
            log_warn "Unknown option: $1"
            shift
            ;;
        esac
    done

    # Validate numeric inputs to prevent SQL injection
    if [[ -n "$pr_number" ]] && ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
        log_error "Invalid PR number: $pr_number"
        return 1
    fi
    if [[ -n "$run_id" ]] && ! [[ "$run_id" =~ ^[0-9]+$ ]]; then
        log_error "Invalid run ID: $run_id"
        return 1
    fi

    ensure_db

    # Find the run
    if [[ -z "$run_id" ]]; then
        if [[ -n "$pr_number" ]]; then
            run_id=$(db "$AUDIT_DB" "SELECT id FROM audit_runs WHERE pr_number = $pr_number ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
        else
            run_id=$(db "$AUDIT_DB" "SELECT id FROM audit_runs ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
        fi
    fi

    if [[ -z "$run_id" ]]; then
        log_error "No audit runs found. Run 'code-audit-helper.sh audit' first."
        return 1
    fi

    print_summary "$run_id"
    return 0
}
