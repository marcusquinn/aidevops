#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Code Audit Helper -- Status, Reset, Regression & Help Commands
# =============================================================================
# Auxiliary commands for the unified code audit system: status checks,
# database reset, regression detection, and help output.
#
# Usage: source "${SCRIPT_DIR}/code-audit-helper-commands.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_success, log_error, etc.)
#   - code-audit-helper.sh (db, ensure_db, get_repo, AUDIT_DB, AUDIT_CONFIG,
#     AUDIT_CONFIG_TEMPLATE constants)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CODE_AUDIT_COMMANDS_LIB_LOADED:-}" ]] && return 0
_CODE_AUDIT_COMMANDS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

# =============================================================================
# Status Command
# =============================================================================

cmd_status() {
    ensure_db

    echo ""
    echo "Code Audit Orchestrator Status"
    echo "=============================="
    echo ""

    # Check dependencies
    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        log_success "GitHub CLI: authenticated"
    else
        log_warn "GitHub CLI: not available or not authenticated"
    fi

    if command -v jq &>/dev/null; then
        log_success "jq: installed"
    else
        log_warn "jq: not installed (required for API parsing)"
    fi

    if command -v sqlite3 &>/dev/null; then
        log_success "sqlite3: installed"
    else
        log_error "sqlite3: not installed (required)"
    fi

    echo ""

    # Service availability
    echo "Service Availability:"
    if [[ -n "${SONAR_TOKEN:-}" ]]; then
        log_success "  SonarCloud: token set"
    else
        log_warn "  SonarCloud: SONAR_TOKEN not set"
    fi
    if [[ -n "${CODACY_API_TOKEN:-}${CODACY_PROJECT_TOKEN:-}" ]]; then
        log_success "  Codacy: token set"
    else
        log_warn "  Codacy: CODACY_API_TOKEN not set"
    fi
    if [[ -n "${CODEFACTOR_API_TOKEN:-}" ]]; then
        log_success "  CodeFactor: token set"
    else
        log_warn "  CodeFactor: CODEFACTOR_API_TOKEN not set"
    fi

    local cr_collector="${SCRIPT_DIR}/coderabbit-collector-helper.sh"
    if [[ -x "$cr_collector" ]]; then
        log_success "  CodeRabbit: collector available"
    else
        log_warn "  CodeRabbit: collector not found"
    fi

    echo ""

    # Config file
    if [[ -f "$AUDIT_CONFIG" ]]; then
        log_success "Config: $AUDIT_CONFIG"
    elif [[ -f "$AUDIT_CONFIG_TEMPLATE" ]]; then
        log_warn "Config: using template ($AUDIT_CONFIG_TEMPLATE)"
        log_info "  Copy to $AUDIT_CONFIG and add your tokens"
    else
        log_warn "Config: not found"
    fi

    echo ""

    # Database stats
    if [[ -f "$AUDIT_DB" ]]; then
        local run_count finding_count
        run_count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_runs;" 2>/dev/null || echo "0")
        finding_count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings;" 2>/dev/null || echo "0")

        echo "Database: $AUDIT_DB"
        echo "  Audit runs:     $run_count"
        echo "  Total findings: $finding_count"

        local last_run
        last_run=$(db "$AUDIT_DB" "
            SELECT completed_at || ' (Run #' || id || ', ' || services_run || ')'
            FROM audit_runs ORDER BY id DESC LIMIT 1;
        " 2>/dev/null || echo "never")
        echo "  Last audit:     $last_run"

        local db_size
        db_size=$(_file_size_bytes "$AUDIT_DB")
        echo "  DB size:        $((db_size / 1024)) KB"
    else
        echo "Database: not created yet"
        echo "  Run 'code-audit-helper.sh audit' to start"
    fi

    echo ""
    return 0
}

# =============================================================================
# Reset Command
# =============================================================================

cmd_reset() {
    if [[ -f "$AUDIT_DB" ]]; then
        local backup
        backup=$(backup_sqlite_db "$AUDIT_DB" "pre-reset" 2>/dev/null || echo "")
        if [[ -n "$backup" ]]; then
            log_info "Backup created: $backup"
        fi
        rm -f "$AUDIT_DB" "${AUDIT_DB}-wal" "${AUDIT_DB}-shm"
        log_success "Audit database reset"
    else
        log_info "No database to reset"
    fi
    return 0
}

# =============================================================================
# Check Regression (t1045)
# =============================================================================
# Queries SonarCloud API for current open findings, compares against the last
# stored snapshot. Returns exit 1 if findings increased >20%.
# Stores current count in a regression-tracking table for next comparison.
# Called by supervisor pulse Phase 10c.

cmd_check_regression() {
    ensure_db

    # Ensure regression_snapshots table exists
    db "$AUDIT_DB" <<'SQL' >/dev/null
CREATE TABLE IF NOT EXISTS regression_snapshots (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    source       TEXT NOT NULL,
    total        INTEGER NOT NULL DEFAULT 0,
    critical     INTEGER NOT NULL DEFAULT 0,
    high         INTEGER NOT NULL DEFAULT 0,
    medium       INTEGER NOT NULL DEFAULT 0,
    low          INTEGER NOT NULL DEFAULT 0,
    checked_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_regression_source ON regression_snapshots(source);
SQL

    local repo
    repo=$(get_repo)
    # SonarCloud project key: owner_repo format
    local project_key
    project_key=$(echo "$repo" | tr '/' '_')

    # Query SonarCloud public API (no token needed for public repos)
    local api_url="https://sonarcloud.io/api/issues/search"
    local api_params="componentKeys=${project_key}&statuses=OPEN,CONFIRMED,REOPENED&ps=1&facets=severities"
    local response
    response=$(curl -sf "${api_url}?${api_params}" 2>/dev/null) || {
        log_warn "check-regression: SonarCloud API unreachable, skipping"
        return 0
    }

    # Parse totals from facets
    local total critical high medium low
    total=$(echo "$response" | jq -r '.total // 0' 2>/dev/null) || total=0
    critical=$(echo "$response" | jq -r '[.facets[]? | select(.property=="severities") | .values[]? | select(.val=="BLOCKER" or .val=="CRITICAL") | .count] | add // 0' 2>/dev/null) || critical=0
    high=$(echo "$response" | jq -r '[.facets[]? | select(.property=="severities") | .values[]? | select(.val=="MAJOR") | .count] | add // 0' 2>/dev/null) || high=0
    medium=$(echo "$response" | jq -r '[.facets[]? | select(.property=="severities") | .values[]? | select(.val=="MINOR") | .count] | add // 0' 2>/dev/null) || medium=0
    low=$(echo "$response" | jq -r '[.facets[]? | select(.property=="severities") | .values[]? | select(.val=="INFO") | .count] | add // 0' 2>/dev/null) || low=0

    # Sanitise: ensure all counts are integers (guards against malformed API responses)
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    [[ "$critical" =~ ^[0-9]+$ ]] || critical=0
    [[ "$high" =~ ^[0-9]+$ ]] || high=0
    [[ "$medium" =~ ^[0-9]+$ ]] || medium=0
    [[ "$low" =~ ^[0-9]+$ ]] || low=0

    # Get previous snapshot (single query for all columns)
    local prev_snapshot
    prev_snapshot=$(db "$AUDIT_DB" -separator '|' "SELECT total, critical, high FROM regression_snapshots WHERE source='sonarcloud' ORDER BY id DESC LIMIT 1;" 2>/dev/null) || prev_snapshot=""
    local prev_total prev_critical prev_high
    IFS='|' read -r prev_total prev_critical prev_high <<<"$prev_snapshot"

    # Store current snapshot
    db "$AUDIT_DB" "INSERT INTO regression_snapshots (source, total, critical, high, medium, low) VALUES ('sonarcloud', $total, $critical, $high, $medium, $low);" 2>/dev/null

    # First run — no previous data to compare
    if [[ -z "$prev_total" ]]; then
        log_info "check-regression: First snapshot recorded (total=$total, critical=$critical, high=$high, medium=$medium, low=$low)"
        return 0
    fi

    # Compare: any critical/high increase is a regression, >20% total increase is a regression
    local regression_found=0

    if [[ "$critical" -gt "${prev_critical:-0}" ]]; then
        log_warn "REGRESSION DETECTED: sonarcloud - critical findings increased (${prev_critical} -> ${critical})"
        regression_found=1
    fi

    if [[ "$high" -gt "${prev_high:-0}" ]]; then
        log_warn "REGRESSION DETECTED: sonarcloud - high severity findings increased (${prev_high} -> ${high})"
        regression_found=1
    fi

    if [[ "$prev_total" -gt 0 ]]; then
        local increase_pct=$(((total - prev_total) * 100 / prev_total))
        if [[ "$increase_pct" -gt 20 ]]; then
            log_warn "REGRESSION DETECTED: sonarcloud - findings increased by ${increase_pct}% (${prev_total} -> ${total})"
            regression_found=1
        fi
    fi

    if [[ "$regression_found" -eq 1 ]]; then
        return 1
    fi

    # Log improvement if findings decreased
    if [[ "$total" -lt "$prev_total" ]]; then
        log_success "check-regression: Findings improved (${prev_total} -> ${total})"
    else
        log_info "check-regression: No regression (total=$total, prev=$prev_total)"
    fi

    return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    cat <<'HELP_EOF'
Code Audit Helper - Unified Audit Orchestrator (t1032.1)

USAGE:
  code-audit-helper.sh <command> [options]

COMMANDS:
  audit            Run unified audit across all configured services
  report           Output detailed findings from the latest audit run
  summary          Show summary statistics for an audit run
  status           Show orchestrator status, dependencies, and DB info
  check-regression Compare current SonarCloud findings against last snapshot
  reset            Reset the audit database (creates backup first)
  help             Show this help

AUDIT OPTIONS:
  --repo OWNER/REPO   Repository (default: auto-detect from git)
  --pr NUMBER         PR number (default: auto-detect from branch)
  --services LIST     Comma-separated services to run (default: all configured)
                      Available: coderabbit, codacy, sonarcloud, codefactor

REPORT OPTIONS:
  --format FORMAT     Output: text (default), json, csv
  --severity LEVEL    Filter: critical, high, medium, low, info
  --run ID            Audit run ID (default: latest)
  --limit N           Max results (default: 100)

SUMMARY OPTIONS:
  --pr NUMBER         Filter by PR number
  --run ID            Audit run ID (default: latest)

EXAMPLES:
  # Run full audit (auto-detect repo and PR)
  code-audit-helper.sh audit

  # Audit specific repo and PR
  code-audit-helper.sh audit --repo owner/repo --pr 42

  # Audit only SonarCloud and Codacy
  code-audit-helper.sh audit --services "sonarcloud codacy"

  # View findings as JSON
  code-audit-helper.sh report --format json

  # View only critical findings
  code-audit-helper.sh report --severity critical

  # Show summary of latest audit
  code-audit-helper.sh summary

  # Check orchestrator status
  code-audit-helper.sh status

SERVICES:
  coderabbit   - AI-powered code review (requires PR, uses gh CLI)
  codacy       - Code quality analysis (requires CODACY_API_TOKEN)
  sonarcloud   - Security & maintainability (requires SONAR_TOKEN)
  codefactor   - Code quality grading (requires CODEFACTOR_API_TOKEN)

DATABASE:
  SQLite database at: ~/.aidevops/.agent-workspace/work/code-audit/audit.db
  Tables: audit_runs, audit_findings
  Direct query: sqlite3 ~/.aidevops/.agent-workspace/work/code-audit/audit.db "SELECT ..."

DEDUPLICATION:
  Findings from multiple services on the same file:line are deduplicated.
  The first finding (by insertion order) is kept; others are marked as duplicates.
  Reports and summaries exclude duplicates by default.

HELP_EOF
    return 0
}
