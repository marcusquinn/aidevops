#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# =============================================================================
# Code Audit Helper - Unified Audit Orchestrator (t1032.1)
# =============================================================================
# Calls each service collector (CodeRabbit, Codacy, SonarCloud, CodeFactor),
# aggregates findings into a common SQLite schema, deduplicates cross-service
# findings on same file+line, and outputs a unified report.
#
# This file is the thin orchestrator. Sub-libraries:
#   - code-audit-helper-collectors.sh  (service collector functions)
#   - code-audit-helper-report.sh      (report/summary output)
#   - code-audit-helper-commands.sh    (status, reset, regression, help)
#
# Usage:
#   code-audit-helper.sh audit [--repo REPO] [--pr NUMBER] [--services LIST]
#   code-audit-helper.sh report [--format json|text|csv] [--severity LEVEL]
#   code-audit-helper.sh summary [--pr NUMBER]
#   code-audit-helper.sh status
#   code-audit-helper.sh check-regression
#   code-audit-helper.sh reset
#   code-audit-helper.sh help
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

readonly AUDIT_DATA_DIR="${HOME}/.aidevops/.agent-workspace/work/code-audit"
readonly AUDIT_DB="${AUDIT_DATA_DIR}/audit.db"
readonly AUDIT_CONFIG_TEMPLATE="configs/code-audit-config.json.txt"
readonly AUDIT_CONFIG="configs/code-audit-config.json"

# Known services (used by get_configured_services fallback)
readonly KNOWN_SERVICES="coderabbit codacy sonarcloud codefactor"

# =============================================================================
# Logging: uses shared log_* from shared-constants.sh with AUDIT prefix
# =============================================================================
# shellcheck disable=SC2034  # Used by shared-constants.sh log_* functions
LOG_PREFIX="AUDIT"

# =============================================================================
# SQLite wrapper: sets busy_timeout on every connection (t135.3 pattern)
# =============================================================================

db() {
	sqlite3 -cmd ".timeout 5000" "$@"
	return $?
}

# =============================================================================
# Database Initialization
# =============================================================================

ensure_db() {
	mkdir -p "$AUDIT_DATA_DIR" 2>/dev/null || true

	if [[ ! -f "$AUDIT_DB" ]]; then
		init_db
		return 0
	fi

	# Ensure WAL mode for existing databases
	local current_mode
	current_mode=$(db "$AUDIT_DB" "PRAGMA journal_mode;" 2>/dev/null || echo "")
	if [[ "$current_mode" != "wal" ]]; then
		db "$AUDIT_DB" "PRAGMA journal_mode=WAL;" 2>/dev/null || log_warn "Failed to enable WAL mode"
	fi

	return 0
}

init_db() {
	db "$AUDIT_DB" <<'SQL' >/dev/null
PRAGMA journal_mode=WAL;

-- Audit runs: one row per orchestrated audit invocation
CREATE TABLE IF NOT EXISTS audit_runs (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    repo         TEXT NOT NULL,
    pr_number    INTEGER DEFAULT 0,
    head_sha     TEXT DEFAULT '',
    started_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    completed_at TEXT DEFAULT '',
    services_run TEXT DEFAULT '',
    status       TEXT NOT NULL DEFAULT 'running'
);

-- Unified findings from all services
CREATE TABLE IF NOT EXISTS audit_findings (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id       INTEGER REFERENCES audit_runs(id),
    source       TEXT NOT NULL,
    severity     TEXT NOT NULL DEFAULT 'info',
    path         TEXT DEFAULT '',
    line         INTEGER DEFAULT 0,
    description  TEXT NOT NULL,
    category     TEXT DEFAULT 'general',
    rule_id      TEXT DEFAULT '',
    dedup_key    TEXT DEFAULT '',
    is_duplicate INTEGER DEFAULT 0,
    collected_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_findings_run ON audit_findings(run_id);
CREATE INDEX IF NOT EXISTS idx_findings_source ON audit_findings(source);
CREATE INDEX IF NOT EXISTS idx_findings_severity ON audit_findings(severity);
CREATE INDEX IF NOT EXISTS idx_findings_path ON audit_findings(path);
CREATE INDEX IF NOT EXISTS idx_findings_dedup ON audit_findings(dedup_key);
CREATE INDEX IF NOT EXISTS idx_findings_dup_flag ON audit_findings(is_duplicate);
SQL

	log_info "Database initialized: $AUDIT_DB"
	return 0
}

# =============================================================================
# Configuration Loading
# =============================================================================

# Get the list of enabled services from config or defaults
get_configured_services() {
	local config_file=""

	# Try working config first, then template
	if [[ -f "$AUDIT_CONFIG" ]]; then
		config_file="$AUDIT_CONFIG"
	elif [[ -f "$AUDIT_CONFIG_TEMPLATE" ]]; then
		config_file="$AUDIT_CONFIG_TEMPLATE"
	fi

	if [[ -n "$config_file" ]] && command -v jq &>/dev/null; then
		jq -r '.services | keys[]' "$config_file" 2>/dev/null || echo "$KNOWN_SERVICES"
	else
		echo "$KNOWN_SERVICES"
	fi
	return 0
}

# =============================================================================
# Repository Info
# =============================================================================

get_repo() {
	local repo
	repo="${GITHUB_REPOSITORY:-}"
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
			log_warn "Not in a GitHub repository or gh CLI not configured"
			echo "unknown/unknown"
			return 0
		}
	fi
	echo "$repo"
	return 0
}

get_head_sha() {
	git rev-parse --short HEAD 2>/dev/null || echo "unknown"
	return 0
}

# =============================================================================
# SQL Escape Helper
# =============================================================================

sql_escape() {
	local val
	val="$1"
	# Replace newlines and carriage returns with spaces to prevent
	# multi-line SQL corruption in line-by-line INSERT generation
	val="${val//[$'\r\n']/ }"
	val="${val//\'/\'\'}"
	echo "$val"
	return 0
}

# =============================================================================
# Source sub-libraries
# =============================================================================

# shellcheck source=./code-audit-helper-collectors.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/code-audit-helper-collectors.sh"

# shellcheck source=./code-audit-helper-report.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/code-audit-helper-report.sh"

# shellcheck source=./code-audit-helper-commands.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/code-audit-helper-commands.sh"

# =============================================================================
# Deduplication
# =============================================================================

# Mark duplicate findings: same file+line across different services.
# The first finding (lowest id) is kept as primary; others are marked duplicate.
deduplicate_findings() {
	local run_id="$1"

	log_info "Deduplicating cross-service findings..."

	db "$AUDIT_DB" "
        UPDATE audit_findings
        SET is_duplicate = 1
        WHERE run_id = $run_id
          AND dedup_key != ''
          AND dedup_key != ':0'
          AND id NOT IN (
              SELECT MIN(id)
              FROM audit_findings
              WHERE run_id = $run_id
                AND dedup_key != ''
                AND dedup_key != ':0'
              GROUP BY dedup_key
          );
    " 2>/dev/null || log_warn "Deduplication query may have partially failed"

	local dup_count
	dup_count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE run_id = $run_id AND is_duplicate = 1;")
	local total
	total=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE run_id = $run_id;")

	log_info "Deduplication: ${dup_count} duplicates found out of ${total} total findings"
	return 0
}

# =============================================================================
# Audit Command (Main Orchestrator)
# =============================================================================

# Parse audit command arguments into _AUDIT_REPO, _AUDIT_PR, _AUDIT_SERVICES
# Returns 1 on validation failure.
parse_audit_args() {
	_AUDIT_REPO=""
	_AUDIT_PR=0
	_AUDIT_SERVICES=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --repo"
				return 1
			}
			_AUDIT_REPO="$2"
			shift 2
			;;
		--pr)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --pr"
				return 1
			}
			_AUDIT_PR="$2"
			shift 2
			;;
		--services)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --services"
				return 1
			}
			_AUDIT_SERVICES="$2"
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

# Resolve repo and pr_number to concrete values (auto-detect if not set)
_resolve_audit_context() {
	local _repo_ref="$1"
	local _pr_ref="$2"

	# Validate numeric inputs to prevent SQL injection
	if [[ "$_AUDIT_PR" != "0" ]] && ! [[ "$_AUDIT_PR" =~ ^[0-9]+$ ]]; then
		log_error "Invalid PR number: $_AUDIT_PR"
		return 1
	fi

	return 0
}

# Run each configured service collector and accumulate findings.
# Outputs "services_run|total_findings" on stdout.
run_service_collectors() {
	local run_id="$1"
	local repo="$2"
	local pr_number="$3"
	local services="$4"

	local services_run=""
	local total_findings=0

	local services_array
	read -ra services_array <<<"$services"
	for service in "${services_array[@]}"; do
		local count=0
		case "$service" in
		coderabbit)
			count=$(collect_coderabbit "$run_id" "$repo" "$pr_number")
			;;
		sonarcloud)
			count=$(collect_sonarcloud "$run_id" "$repo" "$pr_number")
			;;
		codacy)
			count=$(collect_codacy "$run_id" "$repo" "$pr_number")
			;;
		codefactor)
			count=$(collect_codefactor "$run_id" "$repo" "$pr_number")
			;;
		*)
			log_warn "Unknown service: $service — skipping"
			continue
			;;
		esac

		log_info "${service}: ${count} finding(s) collected"
		total_findings=$((total_findings + count))

		if [[ -n "$services_run" ]]; then
			services_run="${services_run},${service}"
		else
			services_run="$service"
		fi
	done

	echo "${services_run}|${total_findings}"
	return 0
}

# Iterate services and collect findings; outputs services_run and total_findings
_run_audit_services() {
	local run_id="$1"
	local repo="$2"
	local pr_number="$3"
	local services="$4"

	# Run collectors and parse result
	local collector_result
	collector_result=$(run_service_collectors "$run_id" "$repo" "$pr_number" "$services")
	local services_run total_findings
	IFS='|' read -r services_run total_findings <<<"$collector_result"

	# Return via stdout: "services_run|total_findings"
	echo "${services_run}|${total_findings}"
	return 0
}

# Auto-detect PR number if not already set (0 means unset).
# Outputs the resolved PR number to stdout.
_audit_detect_pr() {
	local pr_number="$1"

	if [[ "$pr_number" -ne 0 ]]; then
		echo "$pr_number"
		return 0
	fi

	local detected
	detected=$(gh pr view --json number -q .number 2>/dev/null || echo "0")
	if ! [[ "$detected" =~ ^[0-9]+$ ]]; then
		log_warn "Could not auto-detect PR number, defaulting to 0"
		detected=0
	fi
	echo "$detected"
	return 0
}

# Create an audit run record and return its ID.
_audit_create_run() {
	local repo="$1"
	local pr_number="$2"
	local head_sha="$3"

	db "$AUDIT_DB" "
        INSERT INTO audit_runs (repo, pr_number, head_sha)
        VALUES ('$(sql_escape "$repo")', $pr_number, '$(sql_escape "$head_sha")');
        SELECT last_insert_rowid();
    "
	return 0
}

# Mark an audit run as complete with services_run metadata.
_audit_finalize_run() {
	local run_id="$1"
	local services_run="$2"

	db "$AUDIT_DB" "
        UPDATE audit_runs
        SET completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            services_run = '$(sql_escape "$services_run")',
            status = 'complete'
        WHERE id = $run_id;
    "
	return 0
}

cmd_audit() {
	local repo=""
	local pr_number=0
	local services_filter=""

	parse_audit_args "$@" || return 1

	repo="$_AUDIT_REPO"
	pr_number="$_AUDIT_PR"
	services_filter="$_AUDIT_SERVICES"

	_resolve_audit_context repo pr_number || return 1

	[[ -z "$repo" ]] && repo=$(get_repo)
	pr_number=$(_audit_detect_pr "$pr_number")

	local head_sha
	head_sha=$(get_head_sha)

	ensure_db

	log_info "Starting unified code audit for ${repo}"
	[[ "$pr_number" -gt 0 ]] && log_info "PR: #${pr_number} (SHA: ${head_sha})"

	local run_id
	run_id=$(_audit_create_run "$repo" "$pr_number" "$head_sha")
	log_info "Audit run #${run_id} started"

	local services
	if [[ -n "$services_filter" ]]; then
		services="$services_filter"
	else
		services=$(get_configured_services)
	fi

	local result services_run total_findings
	result=$(_run_audit_services "$run_id" "$repo" "$pr_number" "$services")
	IFS='|' read -r services_run total_findings <<<"$result"

	deduplicate_findings "$run_id"
	_audit_finalize_run "$run_id" "$services_run"

	echo ""
	print_summary "$run_id"

	log_success "Audit run #${run_id} complete: ${total_findings} total findings from ${services_run}"
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	audit) cmd_audit "$@" ;;
	report) cmd_report "$@" ;;
	summary) cmd_summary "$@" ;;
	check-regression) cmd_check_regression "$@" ;;
	status) cmd_status "$@" ;;
	reset) cmd_reset "$@" ;;
	help | --help | -h) show_help ;;
	*)
		log_error "$ERROR_UNKNOWN_COMMAND $command"
		echo ""
		show_help
		return 1
		;;
	esac
	return 0
}

main "$@"
