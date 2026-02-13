#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# =============================================================================
# Audit Task Creator Helper - Auto-create tasks from multi-source findings (t1032.4)
# =============================================================================
# Reads findings from the unified audit_findings table (populated by
# code-audit-helper.sh from CodeRabbit, Codacy, SonarCloud, CodeFactor),
# filters false positives, reclassifies severity, deduplicates, and outputs
# TODO-compatible task lines. Optionally dispatches via supervisor.
#
# Also supports legacy mode: reading directly from the CodeRabbit collector DB
# and review-pulse JSON files (for backward compatibility before t1032.1 lands).
#
# Usage:
#   audit-task-creator-helper.sh scan [--source SOURCE] [--severity LEVEL] [--dry-run]
#   audit-task-creator-helper.sh create [--source SOURCE] [--severity LEVEL] [--dry-run] [--dispatch]
#   audit-task-creator-helper.sh verify <finding-id> [--valid|--false-positive]
#   audit-task-creator-helper.sh stats
#   audit-task-creator-helper.sh help
#
# Sources: coderabbit, codacy, sonarcloud, codefactor, pulse, all (default)
#
# Replaces: coderabbit-task-creator-helper.sh (kept as symlink for backward compat)
# Subtask: t1032.4 - Generalise task-creator to accept multi-source findings
#
# Author: AI DevOps Framework
# Version: 2.0.0
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
readonly TASK_CREATOR_DB="${AUDIT_DATA_DIR}/task-creator.db"

# Legacy paths (CodeRabbit-only, used when unified DB not available)
readonly LEGACY_COLLECTOR_DB="${HOME}/.aidevops/.agent-workspace/work/coderabbit-reviews/reviews.db"
readonly LEGACY_PULSE_DIR="${HOME}/.aidevops/.agent-workspace/work/review-pulse/findings"
readonly LEGACY_TASK_DB="${HOME}/.aidevops/.agent-workspace/work/coderabbit-reviews/task-creator.db"

readonly SEVERITY_LEVELS=("critical" "high" "medium" "low" "info")
readonly VALID_SOURCES=("coderabbit" "codacy" "sonarcloud" "codefactor" "pulse" "all")

# =============================================================================
# False Positive Patterns (source-agnostic)
# =============================================================================
# These patterns identify review bot output that is NOT actionable findings.
# Each pattern is a regex matched against the finding description/body.

readonly -a FP_PATTERNS=(
	# CodeRabbit bot instructions / meta-comments
	"<!-- tips_start -->"
	"<!-- tips_end -->"
	"Thank you for using CodeRabbit"
	"We offer full suites of"
	"<!-- commit_ids_reviewed_start -->"
	# Codacy auto-generated
	"Codacy found no issues"
	"No new issues found"
	# SonarCloud auto-generated
	"SonarCloud Quality Gate passed"
	"No new issues to report"
	# Generic bot noise
	"This comment was automatically generated"
	"Powered by .* analysis"
)

# Patterns that only indicate FP when they appear at the START of the body
readonly -a FP_START_PATTERNS=(
	"<!-- This is an auto-generated comment"
	"<!-- walkthrough_start -->"
)

# Source-specific FP patterns (keyed by source name)
# CodeRabbit walkthrough-only detection is handled in is_false_positive()

# Severity re-classification patterns
# Review bots sometimes mark findings with severity that differs from
# content-based classification. These patterns catch the mismatch.
readonly -a SEVERITY_UPGRADE_CRITICAL=(
	"rm -rf.*empty variable"
	"path traversal"
	"command injection"
	"arbitrary code execution"
	"credential.*exposed"
	"secret.*hardcoded"
	"remote code execution"
	"deserialization.*untrusted"
)

readonly -a SEVERITY_UPGRADE_HIGH=(
	"unvalidated.*input"
	"missing.*validation"
	"SQL injection"
	"XSS"
	"CSRF"
	"open redirect"
	"insecure.*random"
	"weak.*crypto"
)

# =============================================================================
# Logging
# =============================================================================

log_info() {
	echo -e "${BLUE}[AUDIT-TASK]${NC} $*"
	return 0
}
log_success() {
	echo -e "${GREEN}[AUDIT-TASK]${NC} $*"
	return 0
}
log_warn() {
	echo -e "${YELLOW}[AUDIT-TASK]${NC} $*"
	return 0
}
log_error() {
	echo -e "${RED}[AUDIT-TASK]${NC} $*" >&2
	return 0
}

# =============================================================================
# SQLite wrapper
# =============================================================================

db() {
	sqlite3 -cmd ".timeout 5000" "$@"
}

# =============================================================================
# Detect which DB mode to use
# =============================================================================
# Returns "unified" if the audit_findings table exists in AUDIT_DB,
# "legacy" if only the old CodeRabbit collector DB exists,
# or "none" if no data source is available.

detect_db_mode() {
	# Check for unified audit DB with audit_findings table
	if [[ -f "$AUDIT_DB" ]]; then
		local has_table
		has_table=$(db "$AUDIT_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='audit_findings';" 2>/dev/null || echo "")
		if [[ -n "$has_table" ]]; then
			echo "unified"
			return 0
		fi
	fi

	# Fall back to legacy CodeRabbit collector DB
	if [[ -f "$LEGACY_COLLECTOR_DB" ]] || [[ -d "$LEGACY_PULSE_DIR" ]]; then
		echo "legacy"
		return 0
	fi

	echo "none"
	return 0
}

# =============================================================================
# Task Creator Database (local processing state)
# =============================================================================

get_active_task_db() {
	local mode
	mode=$(detect_db_mode)
	if [[ "$mode" == "legacy" ]]; then
		# Use legacy path if it exists, otherwise use new path
		if [[ -f "$LEGACY_TASK_DB" ]]; then
			echo "$LEGACY_TASK_DB"
			return 0
		fi
	fi
	echo "$TASK_CREATOR_DB"
	return 0
}

ensure_task_db() {
	local active_db
	active_db=$(get_active_task_db)
	local db_dir
	db_dir=$(dirname "$active_db")
	mkdir -p "$db_dir" 2>/dev/null || true

	if [[ ! -f "$active_db" ]]; then
		init_task_db "$active_db"
		return 0
	fi

	# Ensure WAL mode
	local current_mode
	current_mode=$(db "$active_db" "PRAGMA journal_mode;" 2>/dev/null || echo "")
	if [[ "$current_mode" != "wal" ]]; then
		db "$active_db" "PRAGMA journal_mode=WAL;" 2>/dev/null || true
	fi

	# Migrate schema if needed (add source_tool column for multi-source tracking)
	local has_source_tool
	has_source_tool=$(db "$active_db" "SELECT COUNT(*) FROM pragma_table_info('processed_findings') WHERE name='source_tool';" 2>/dev/null || echo "0")
	if [[ "$has_source_tool" == "0" ]]; then
		db "$active_db" "ALTER TABLE processed_findings ADD COLUMN source_tool TEXT DEFAULT 'coderabbit';" 2>/dev/null || true
	fi

	return 0
}

init_task_db() {
	local target_db="$1"
	db "$target_db" <<'SQL' >/dev/null
PRAGMA journal_mode=WAL;

-- Processed findings with verification status
CREATE TABLE IF NOT EXISTS processed_findings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source          TEXT NOT NULL,
    source_id       TEXT NOT NULL,
    source_tool     TEXT NOT NULL DEFAULT 'unknown',
    pr_number       INTEGER,
    path            TEXT,
    line            INTEGER,
    severity        TEXT NOT NULL,
    original_severity TEXT,
    category        TEXT,
    description     TEXT NOT NULL,
    is_false_positive INTEGER NOT NULL DEFAULT 0,
    fp_reason       TEXT,
    is_duplicate    INTEGER NOT NULL DEFAULT 0,
    duplicate_of    INTEGER,
    task_id         TEXT,
    task_created    INTEGER NOT NULL DEFAULT 0,
    dispatched      INTEGER NOT NULL DEFAULT 0,
    verified_by     TEXT,
    verified_at     TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE(source, source_id)
);

-- Task creation log
CREATE TABLE IF NOT EXISTS task_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    finding_id      INTEGER REFERENCES processed_findings(id),
    task_id         TEXT NOT NULL,
    description     TEXT NOT NULL,
    severity        TEXT NOT NULL,
    source_tool     TEXT DEFAULT 'unknown',
    dispatched      INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_pf_source ON processed_findings(source, source_id);
CREATE INDEX IF NOT EXISTS idx_pf_severity ON processed_findings(severity);
CREATE INDEX IF NOT EXISTS idx_pf_fp ON processed_findings(is_false_positive);
CREATE INDEX IF NOT EXISTS idx_pf_task ON processed_findings(task_created);
CREATE INDEX IF NOT EXISTS idx_pf_source_tool ON processed_findings(source_tool);
SQL

	log_info "Task creator database initialized: $target_db"
	return 0
}

# =============================================================================
# SQL Escape Helper
# =============================================================================

sql_escape() {
	local val="$1"
	val="${val//\\\'/\'}"
	val="${val//\\\"/\"}"
	val="${val//\'/\'\'}"
	echo "$val"
	return 0
}

# =============================================================================
# False Positive Detection (source-agnostic)
# =============================================================================

is_false_positive() {
	local body="$1"
	local source_tool="${2:-unknown}"

	# Check patterns that match anywhere in body
	for pattern in "${FP_PATTERNS[@]}"; do
		if echo "$body" | grep -qiE "$pattern"; then
			echo "$pattern"
			return 0
		fi
	done

	# Check patterns that only match at the START of the body
	local first_line
	first_line=$(echo "$body" | head -1)
	for pattern in "${FP_START_PATTERNS[@]}"; do
		if echo "$first_line" | grep -qiE "$pattern"; then
			echo "starts-with:$pattern"
			return 0
		fi
	done

	# Source-specific FP detection
	case "$source_tool" in
	coderabbit)
		# Walkthrough-only comments (contain walkthrough but no actionable content)
		if echo "$body" | grep -q "walkthrough" && ! echo "$body" | grep -qiE "Potential issue|suggestion|warning|error|fix"; then
			echo "walkthrough-only"
			return 0
		fi
		;;
	codacy)
		# Codacy sometimes reports style-only issues as findings
		if echo "$body" | grep -qiE "^Style:.*formatting|^Convention:.*whitespace"; then
			echo "style-only"
			return 0
		fi
		;;
	sonarcloud)
		# SonarCloud info-level code smells that are just suggestions
		if echo "$body" | grep -qiE "^Refactor this .* to reduce its Cognitive Complexity"; then
			# These are valid but often low-priority — don't filter, let severity handle it
			:
		fi
		;;
	esac

	# Empty or whitespace-only bodies
	if [[ -z "${body// /}" ]]; then
		echo "empty-body"
		return 0
	fi

	return 1
}

# =============================================================================
# Severity Reclassification (source-agnostic)
# =============================================================================

reclassify_severity() {
	local body="$1"
	local current_severity="$2"
	local source_tool="${3:-unknown}"
	local lower_body
	lower_body=$(echo "$body" | tr '[:upper:]' '[:lower:]')

	# Check for critical upgrades (content-based, all sources)
	for pattern in "${SEVERITY_UPGRADE_CRITICAL[@]}"; do
		if echo "$lower_body" | grep -qiE "$pattern"; then
			echo "critical"
			return 0
		fi
	done

	# Check for high upgrades (content-based, all sources)
	for pattern in "${SEVERITY_UPGRADE_HIGH[@]}"; do
		if echo "$lower_body" | grep -qiE "$pattern" && [[ "$current_severity" != "critical" ]]; then
			echo "high"
			return 0
		fi
	done

	# Source-specific severity markers
	case "$source_tool" in
	coderabbit)
		# CodeRabbit's own emoji markers
		if echo "$body" | grep -qE "🔴 Critical"; then
			echo "critical"
			return 0
		elif echo "$body" | grep -qE "🟠 Major"; then
			echo "high"
			return 0
		elif echo "$body" | grep -qE "🟡 Minor"; then
			echo "medium"
			return 0
		fi
		;;
	sonarcloud)
		# SonarCloud severity mapping (BLOCKER/CRITICAL/MAJOR/MINOR/INFO)
		if echo "$body" | grep -qiE "BLOCKER"; then
			echo "critical"
			return 0
		elif echo "$body" | grep -qiE "CRITICAL"; then
			echo "critical"
			return 0
		elif echo "$body" | grep -qiE "MAJOR"; then
			echo "high"
			return 0
		fi
		;;
	codacy)
		# Codacy severity mapping (Error/Warning/Info)
		if echo "$body" | grep -qiE "^Error:"; then
			echo "high"
			return 0
		fi
		;;
	esac

	echo "$current_severity"
	return 0
}

# =============================================================================
# Description Extraction (source-agnostic)
# =============================================================================

extract_description() {
	local body="$1"
	local source_tool="${2:-unknown}"

	case "$source_tool" in
	coderabbit)
		# Try to extract the bold title line (CodeRabbit format: **Title here**)
		local title
		title=$(echo "$body" | grep -oE '\*\*[^*]+\*\*' | head -1 | sed 's/\*\*//g')
		if [[ -n "$title" && ${#title} -gt 10 ]]; then
			echo "${title:0:120}"
			return 0
		fi
		;;
	codacy | sonarcloud | codefactor)
		# These tools typically provide a clean one-line description
		# Use the first non-empty line
		local desc
		desc=$(echo "$body" | grep -vE '^\s*$' | head -1 | sed 's/^[[:space:]]*//')
		if [[ -n "$desc" ]]; then
			echo "${desc:0:120}"
			return 0
		fi
		;;
	esac

	# Fallback: first non-empty, non-marker line
	local desc
	desc=$(echo "$body" | grep -vE '^\s*$|^<!--|^_⚠️|^\*\*|^<details|^<summary|^```' | head -1 | sed 's/^[[:space:]]*//')

	if [[ -n "$desc" ]]; then
		echo "${desc:0:120}"
		return 0
	fi

	echo "(no description extracted)"
	return 0
}

# =============================================================================
# Severity Threshold Check
# =============================================================================

meets_severity_threshold() {
	local finding_severity="$1"
	local min_severity="$2"

	local finding_idx=99
	local min_idx=99

	for i in "${!SEVERITY_LEVELS[@]}"; do
		if [[ "${SEVERITY_LEVELS[$i]}" == "$finding_severity" ]]; then
			finding_idx=$i
		fi
		if [[ "${SEVERITY_LEVELS[$i]}" == "$min_severity" ]]; then
			min_idx=$i
		fi
	done

	[[ $finding_idx -le $min_idx ]]
	return $?
}

# =============================================================================
# Source Filter Helper
# =============================================================================

build_source_filter() {
	local source="$1"
	case "$source" in
	all) echo "" ;;
	coderabbit) echo "AND (source_tool = 'coderabbit' OR source IN ('collector_db', 'pulse'))" ;;
	codacy) echo "AND source_tool = 'codacy'" ;;
	sonarcloud) echo "AND source_tool = 'sonarcloud'" ;;
	codefactor) echo "AND source_tool = 'codefactor'" ;;
	pulse) echo "AND source = 'pulse'" ;;
	*)
		log_error "Unknown source: $source (use: ${VALID_SOURCES[*]})"
		return 1
		;;
	esac
	return 0
}

# =============================================================================
# Core: Scan Findings from Unified audit_findings Table
# =============================================================================

scan_unified_findings() {
	local min_severity="$1"
	local source_filter="$2"

	if [[ ! -f "$AUDIT_DB" ]]; then
		log_warn "Unified audit DB not found: $AUDIT_DB"
		log_info "Run 'code-audit-helper.sh collect' first, or findings will be read from legacy sources"
		return 0
	fi

	local active_db
	active_db=$(get_active_task_db)
	ensure_task_db

	# Build source filter for audit_findings query
	local af_source_filter=""
	case "$source_filter" in
	*coderabbit*) af_source_filter="AND af.source = 'coderabbit'" ;;
	*codacy*) af_source_filter="AND af.source = 'codacy'" ;;
	*sonarcloud*) af_source_filter="AND af.source = 'sonarcloud'" ;;
	*codefactor*) af_source_filter="AND af.source = 'codefactor'" ;;
	*) af_source_filter="" ;; # all sources
	esac

	# Get already-processed source IDs
	local processed_ids
	processed_ids=$(db "$active_db" "
		SELECT source_id FROM processed_findings WHERE source = 'unified';
	" 2>/dev/null || echo "")

	# Build exclusion clause
	local exclude_clause=""
	if [[ -n "$processed_ids" ]]; then
		local id_list
		id_list=$(echo "$processed_ids" | sed "s/'/''/" | awk '{printf "'\''%s'\'',", $0}' | sed 's/,$//')
		exclude_clause="AND CAST(af.id AS TEXT) NOT IN ($id_list)"
	fi

	# Query unprocessed findings from unified table
	local findings_json
	findings_json=$(db "$AUDIT_DB" -json "
		SELECT af.id, af.source, af.severity, af.path, af.line, af.description,
		       af.category, af.rule_id, af.pr_number
		FROM audit_findings af
		WHERE 1=1
		  $af_source_filter
		  $exclude_clause
		ORDER BY af.id;
	" 2>/dev/null || echo "[]")

	if [[ "$findings_json" == "[]" || -z "$findings_json" ]]; then
		log_info "No unprocessed findings in unified audit DB"
		return 0
	fi

	local count
	count=$(echo "$findings_json" | jq 'length' 2>/dev/null || echo "0")
	log_info "Scanning $count unprocessed findings from unified audit DB..."

	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"
	echo "$findings_json" | jq -c '.[]' >"$tmp_file"

	local total=0 valid=0 false_positives=0 duplicates=0 below_threshold=0

	while IFS= read -r finding; do
		total=$((total + 1))

		local finding_id source severity path line description category
		finding_id=$(echo "$finding" | jq -r '.id')
		source=$(echo "$finding" | jq -r '.source')
		severity=$(echo "$finding" | jq -r '.severity')
		path=$(echo "$finding" | jq -r '.path // ""')
		line=$(echo "$finding" | jq -r '.line // 0')
		description=$(echo "$finding" | jq -r '.description')
		category=$(echo "$finding" | jq -r '.category // "general"')

		# Check false positive
		local fp_reason=""
		fp_reason=$(is_false_positive "$description" "$source") || true

		if [[ -n "$fp_reason" ]]; then
			false_positives=$((false_positives + 1))
			local escaped_fp
			escaped_fp=$(sql_escape "$fp_reason")
			local escaped_desc
			escaped_desc=$(sql_escape "$description")
			db "$active_db" "
				INSERT OR IGNORE INTO processed_findings
					(source, source_id, source_tool, pr_number, path, line, severity,
					 original_severity, category, description, is_false_positive, fp_reason)
				VALUES ('unified', '$(sql_escape "$finding_id")', '$(sql_escape "$source")',
					${line:-0}, '$(sql_escape "$path")', ${line:-0},
					'$severity', '$severity', '$(sql_escape "$category")',
					'$escaped_desc', 1, '$escaped_fp');
			" 2>/dev/null || true
			continue
		fi

		# Reclassify severity
		local new_severity
		new_severity=$(reclassify_severity "$description" "$severity" "$source")

		# Check severity threshold
		if ! meets_severity_threshold "$new_severity" "$min_severity"; then
			below_threshold=$((below_threshold + 1))
			local escaped_desc
			escaped_desc=$(sql_escape "$description")
			db "$active_db" "
				INSERT OR IGNORE INTO processed_findings
					(source, source_id, source_tool, pr_number, path, line, severity,
					 original_severity, category, description, is_false_positive)
				VALUES ('unified', '$(sql_escape "$finding_id")', '$(sql_escape "$source")',
					0, '$(sql_escape "$path")', ${line:-0},
					'$new_severity', '$severity', '$(sql_escape "$category")',
					'$escaped_desc', 0);
			" 2>/dev/null || true
			continue
		fi

		# Check for duplicates (same path + similar description)
		local escaped_desc
		escaped_desc=$(sql_escape "$description")
		local existing_dup
		existing_dup=$(db "$active_db" "
			SELECT id FROM processed_findings
			WHERE path = '$(sql_escape "$path")'
			  AND is_false_positive = 0
			  AND description = '$escaped_desc'
			LIMIT 1;
		" 2>/dev/null || echo "")

		local is_dup=0
		local dup_of=""
		if [[ -n "$existing_dup" ]]; then
			is_dup=1
			dup_of="$existing_dup"
			duplicates=$((duplicates + 1))
		fi

		valid=$((valid + 1))

		# Insert processed finding
		db "$active_db" "
			INSERT OR IGNORE INTO processed_findings
				(source, source_id, source_tool, pr_number, path, line, severity,
				 original_severity, category, description,
				 is_false_positive, is_duplicate, duplicate_of)
			VALUES ('unified', '$(sql_escape "$finding_id")', '$(sql_escape "$source")',
				0, '$(sql_escape "$path")', ${line:-0},
				'$new_severity', '$severity', '$(sql_escape "$category")', '$escaped_desc',
				0, $is_dup, $(if [[ -n "$dup_of" ]]; then echo "$dup_of"; else echo "NULL"; fi));
		" 2>/dev/null || true
	done <"$tmp_file"

	log_info "Unified scan: total=$total valid=$valid fp=$false_positives dup=$duplicates below_threshold=$below_threshold"
	return 0
}

# =============================================================================
# Legacy: Scan CodeRabbit Collector DB
# =============================================================================

scan_legacy_db_findings() {
	local min_severity="$1"

	if [[ ! -f "$LEGACY_COLLECTOR_DB" ]]; then
		log_warn "Legacy collector DB not found: $LEGACY_COLLECTOR_DB"
		log_info "Run 'coderabbit-collector-helper.sh collect --pr NUMBER' first"
		return 0
	fi

	local active_db
	active_db=$(get_active_task_db)
	ensure_task_db

	local processed_ids
	processed_ids=$(db "$active_db" "
		SELECT source_id FROM processed_findings WHERE source = 'collector_db';
	" 2>/dev/null || echo "")

	local exclude_clause=""
	if [[ -n "$processed_ids" ]]; then
		local id_list
		id_list=$(echo "$processed_ids" | tr '\n' ',' | sed 's/,$//')
		exclude_clause="WHERE c.gh_comment_id NOT IN ($id_list)"
	fi

	local comments_json
	comments_json=$(db "$LEGACY_COLLECTOR_DB" -json "
		SELECT c.id, c.pr_number, c.path, c.line, c.severity, c.category, c.body, c.gh_comment_id
		FROM comments c
		$exclude_clause
		ORDER BY c.pr_number, c.id;
	" 2>/dev/null || echo "[]")

	if [[ "$comments_json" == "[]" || -z "$comments_json" ]]; then
		log_info "No unprocessed findings in legacy collector DB"
		return 0
	fi

	local count
	count=$(echo "$comments_json" | jq 'length' 2>/dev/null || echo "0")
	log_info "Scanning $count unprocessed comments from legacy collector DB..."

	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"
	echo "$comments_json" | jq -c '.[]' >"$tmp_file"

	local total=0 valid=0 false_positives=0 duplicates=0 below_threshold=0

	while IFS= read -r comment; do
		total=$((total + 1))

		local comment_id pr_number path line severity category body
		comment_id=$(echo "$comment" | jq -r '.gh_comment_id // .id')
		pr_number=$(echo "$comment" | jq -r '.pr_number')
		path=$(echo "$comment" | jq -r '.path // ""')
		line=$(echo "$comment" | jq -r '.line // 0')
		severity=$(echo "$comment" | jq -r '.severity')
		category=$(echo "$comment" | jq -r '.category')
		body=$(echo "$comment" | jq -r '.body')

		local fp_reason=""
		fp_reason=$(is_false_positive "$body" "coderabbit") || true

		if [[ -n "$fp_reason" ]]; then
			false_positives=$((false_positives + 1))
			local escaped_fp
			escaped_fp=$(sql_escape "$fp_reason")
			local escaped_desc
			escaped_desc=$(sql_escape "$(extract_description "$body" "coderabbit")")
			db "$active_db" "
				INSERT OR IGNORE INTO processed_findings
					(source, source_id, source_tool, pr_number, path, line, severity,
					 original_severity, category, description, is_false_positive, fp_reason)
				VALUES ('collector_db', '$(sql_escape "$comment_id")', 'coderabbit',
					$pr_number, '$(sql_escape "$path")', ${line:-0},
					'$severity', '$severity', '$(sql_escape "$category")',
					'$escaped_desc', 1, '$escaped_fp');
			" 2>/dev/null || true
			continue
		fi

		local new_severity
		new_severity=$(reclassify_severity "$body" "$severity" "coderabbit")

		if ! meets_severity_threshold "$new_severity" "$min_severity"; then
			below_threshold=$((below_threshold + 1))
			local escaped_desc
			escaped_desc=$(sql_escape "$(extract_description "$body" "coderabbit")")
			db "$active_db" "
				INSERT OR IGNORE INTO processed_findings
					(source, source_id, source_tool, pr_number, path, line, severity,
					 original_severity, category, description, is_false_positive)
				VALUES ('collector_db', '$(sql_escape "$comment_id")', 'coderabbit',
					$pr_number, '$(sql_escape "$path")', ${line:-0},
					'$new_severity', '$severity', '$(sql_escape "$category")',
					'$escaped_desc', 0);
			" 2>/dev/null || true
			continue
		fi

		local description
		description=$(extract_description "$body" "coderabbit")
		local escaped_desc
		escaped_desc=$(sql_escape "$description")
		local existing_dup
		existing_dup=$(db "$active_db" "
			SELECT id FROM processed_findings
			WHERE path = '$(sql_escape "$path")'
			  AND is_false_positive = 0
			  AND description = '$escaped_desc'
			LIMIT 1;
		" 2>/dev/null || echo "")

		local is_dup=0
		local dup_of=""
		if [[ -n "$existing_dup" ]]; then
			is_dup=1
			dup_of="$existing_dup"
			duplicates=$((duplicates + 1))
		fi

		valid=$((valid + 1))

		db "$active_db" "
			INSERT OR IGNORE INTO processed_findings
				(source, source_id, source_tool, pr_number, path, line, severity,
				 original_severity, category, description,
				 is_false_positive, is_duplicate, duplicate_of)
			VALUES ('collector_db', '$(sql_escape "$comment_id")', 'coderabbit',
				$pr_number, '$(sql_escape "$path")', ${line:-0},
				'$new_severity', '$severity', '$(sql_escape "$category")', '$escaped_desc',
				0, $is_dup, $(if [[ -n "$dup_of" ]]; then echo "$dup_of"; else echo "NULL"; fi));
		" 2>/dev/null || true
	done <"$tmp_file"

	log_info "Legacy DB scan: total=$total valid=$valid fp=$false_positives dup=$duplicates below_threshold=$below_threshold"
	return 0
}

# =============================================================================
# Legacy: Scan review-pulse JSON findings
# =============================================================================

scan_legacy_pulse_findings() {
	local min_severity="$1"

	if [[ ! -d "$LEGACY_PULSE_DIR" ]]; then
		log_info "No pulse findings directory: $LEGACY_PULSE_DIR"
		return 0
	fi

	local active_db
	active_db=$(get_active_task_db)
	ensure_task_db

	local latest_findings
	latest_findings=$(find "$LEGACY_PULSE_DIR" -maxdepth 1 -name '*-findings.json' -print0 2>/dev/null |
		xargs -0 ls -t 2>/dev/null | head -1 || echo "")

	if [[ -z "$latest_findings" || ! -f "$latest_findings" ]]; then
		log_info "No pulse findings files found"
		return 0
	fi

	local findings_count
	findings_count=$(jq '.findings | length' "$latest_findings" 2>/dev/null || echo "0")

	if [[ "$findings_count" -eq 0 ]]; then
		log_info "No findings in latest pulse run"
		return 0
	fi

	log_info "Scanning $findings_count findings from pulse: $(basename "$latest_findings")"

	local valid=0

	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"
	jq -c '.findings[]' "$latest_findings" >"$tmp_file"

	while IFS= read -r finding; do
		local finding_id file severity description
		finding_id=$(echo "$finding" | jq -r '.id')
		file=$(echo "$finding" | jq -r '.file')
		severity=$(echo "$finding" | jq -r '.severity')
		description=$(echo "$finding" | jq -r '.description')

		local existing
		existing=$(db "$active_db" "
			SELECT id FROM processed_findings
			WHERE source = 'pulse' AND source_id = '$(sql_escape "$finding_id")'
			LIMIT 1;
		" 2>/dev/null || echo "")

		if [[ -n "$existing" ]]; then
			continue
		fi

		if ! meets_severity_threshold "$severity" "$min_severity"; then
			continue
		fi

		valid=$((valid + 1))
		local escaped_desc
		escaped_desc=$(sql_escape "$description")

		db "$active_db" "
			INSERT OR IGNORE INTO processed_findings
				(source, source_id, source_tool, path, severity, original_severity,
				 category, description)
			VALUES ('pulse', '$(sql_escape "$finding_id")', 'coderabbit',
				'$(sql_escape "$file")', '$severity', '$severity',
				'general', '$escaped_desc');
		" 2>/dev/null || true
	done <"$tmp_file"

	log_info "Pulse scan: $valid new findings processed"
	return 0
}

# =============================================================================
# Core: Scan Command
# =============================================================================

cmd_scan() {
	local source="all"
	local min_severity="medium"
	local dry_run="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--source)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --source"
				return 1
			}
			source="$2"
			shift 2
			;;
		--severity)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --severity"
				return 1
			}
			min_severity="$2"
			shift 2
			;;
		--dry-run)
			dry_run="true"
			shift
			;;
		*)
			log_warn "Unknown option: $1"
			shift
			;;
		esac
	done

	ensure_task_db

	if [[ "$dry_run" == "true" ]]; then
		log_info "[DRY RUN] Would scan sources: $source (severity >= $min_severity)"
	fi

	local mode
	mode=$(detect_db_mode)
	log_info "DB mode: $mode"

	local source_filter
	source_filter=$(build_source_filter "$source") || return 1

	if [[ "$mode" == "unified" ]]; then
		# Use unified audit_findings table
		scan_unified_findings "$min_severity" "$source_filter"

		# Also scan legacy sources if they exist (for findings not yet migrated)
		if [[ "$source" == "all" || "$source" == "coderabbit" || "$source" == "pulse" ]]; then
			if [[ -f "$LEGACY_COLLECTOR_DB" ]]; then
				scan_legacy_db_findings "$min_severity"
			fi
			if [[ -d "$LEGACY_PULSE_DIR" ]]; then
				scan_legacy_pulse_findings "$min_severity"
			fi
		fi
	elif [[ "$mode" == "legacy" ]]; then
		# Legacy mode: only CodeRabbit sources available
		case "$source" in
		all | coderabbit)
			scan_legacy_db_findings "$min_severity"
			scan_legacy_pulse_findings "$min_severity"
			;;
		pulse)
			scan_legacy_pulse_findings "$min_severity"
			;;
		codacy | sonarcloud | codefactor)
			log_warn "Source '$source' requires unified audit DB (run code-audit-helper.sh collect first)"
			log_info "Only CodeRabbit findings available in legacy mode"
			return 0
			;;
		*)
			log_error "Unknown source: $source"
			return 1
			;;
		esac
	else
		log_warn "No audit data sources found"
		log_info "Run 'code-audit-helper.sh collect' or 'coderabbit-collector-helper.sh collect --pr NUMBER'"
		return 0
	fi

	# Show summary of actionable findings
	local active_db
	active_db=$(get_active_task_db)
	local actionable_count
	actionable_count=$(db "$active_db" "
		SELECT COUNT(*) FROM processed_findings
		WHERE is_false_positive = 0
		  AND is_duplicate = 0
		  AND task_created = 0;
	" 2>/dev/null || echo "0")

	log_success "Actionable findings ready for task creation: $actionable_count"

	if [[ "$actionable_count" -gt 0 ]]; then
		echo ""
		echo "Severity breakdown:"
		db "$active_db" -separator '|' "
			SELECT severity, COUNT(*) as cnt
			FROM processed_findings
			WHERE is_false_positive = 0 AND is_duplicate = 0 AND task_created = 0
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
		echo "By source tool:"
		db "$active_db" -separator '|' "
			SELECT COALESCE(source_tool, 'unknown') as tool, COUNT(*) as cnt
			FROM processed_findings
			WHERE is_false_positive = 0 AND is_duplicate = 0 AND task_created = 0
			GROUP BY source_tool
			ORDER BY cnt DESC;
		" 2>/dev/null | while IFS='|' read -r tool cnt; do
			printf "  %-15s %s\n" "$tool" "$cnt"
		done
		echo ""
	fi

	return 0
}

# =============================================================================
# Core: Create Tasks from Findings
# =============================================================================

cmd_create() {
	local source="all"
	local min_severity="medium"
	local dry_run="false"
	local dispatch="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--source)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --source"
				return 1
			}
			source="$2"
			shift 2
			;;
		--severity)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --severity"
				return 1
			}
			min_severity="$2"
			shift 2
			;;
		--dry-run)
			dry_run="true"
			shift
			;;
		--dispatch)
			dispatch="true"
			shift
			;;
		*)
			log_warn "Unknown option: $1"
			shift
			;;
		esac
	done

	ensure_task_db

	# First scan for new findings
	cmd_scan --source "$source" --severity "$min_severity"

	local active_db
	active_db=$(get_active_task_db)

	# Build severity filter for SQL
	local severity_filter=""
	case "$min_severity" in
	critical) severity_filter="AND severity IN ('critical')" ;;
	high) severity_filter="AND severity IN ('critical', 'high')" ;;
	medium) severity_filter="AND severity IN ('critical', 'high', 'medium')" ;;
	low) severity_filter="AND severity IN ('critical', 'high', 'medium', 'low')" ;;
	*) severity_filter="" ;; # info = all
	esac

	# Build source filter
	local source_sql_filter
	source_sql_filter=$(build_source_filter "$source") || return 1

	# Get actionable findings
	local findings_json
	findings_json=$(db "$active_db" -json "
		SELECT id, source, source_id, source_tool, pr_number, path, line,
		       severity, category, description
		FROM processed_findings
		WHERE is_false_positive = 0
		  AND is_duplicate = 0
		  AND task_created = 0
		  $severity_filter
		  $source_sql_filter
		ORDER BY
			CASE severity
				WHEN 'critical' THEN 1
				WHEN 'high' THEN 2
				WHEN 'medium' THEN 3
				WHEN 'low' THEN 4
				ELSE 5
			END,
			created_at ASC;
	" 2>/dev/null || echo "[]")

	local count
	count=$(echo "$findings_json" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		log_info "No actionable findings to create tasks from"
		return 0
	fi

	log_info "Creating tasks for $count actionable findings..."

	local tasks_created=0
	local task_lines=""

	local tmp_create
	tmp_create=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_create}'"
	echo "$findings_json" | jq -c '.[]' >"$tmp_create"

	while IFS= read -r finding; do
		local finding_id severity category path description pr_number source_tool
		finding_id=$(echo "$finding" | jq -r '.id')
		severity=$(echo "$finding" | jq -r '.severity')
		category=$(echo "$finding" | jq -r '.category')
		path=$(echo "$finding" | jq -r '.path // ""')
		description=$(echo "$finding" | jq -r '.description')
		pr_number=$(echo "$finding" | jq -r '.pr_number // ""')
		source_tool=$(echo "$finding" | jq -r '.source_tool // "unknown"')

		# Map severity to priority tag
		local priority_tag
		case "$severity" in
		critical) priority_tag="#critical" ;;
		high) priority_tag="#high" ;;
		medium) priority_tag="#medium" ;;
		*) priority_tag="#low" ;;
		esac

		# Build location info
		local location=""
		if [[ -n "$path" && "$path" != "" && "$path" != "null" ]]; then
			location=" [${path}]"
		fi

		# Build PR reference
		local pr_ref=""
		if [[ -n "$pr_number" && "$pr_number" != "" && "$pr_number" != "null" && "$pr_number" != "0" ]]; then
			pr_ref=" from-pr:#${pr_number}"
		fi

		# Build source tag
		local source_tag=""
		if [[ -n "$source_tool" && "$source_tool" != "unknown" ]]; then
			source_tag=" #${source_tool}"
		fi

		# Allocate task ID via claim-task-id.sh
		local task_id=""
		local gh_ref=""
		local claim_output

		local task_title="Fix ${category} issue (${severity}): ${description:0:80}"

		if claim_output=$("${SCRIPT_DIR}/claim-task-id.sh" --title "$task_title" --description "Auto-created from ${source_tool} finding #${finding_id}" --labels "quality,auto-review" 2>&1); then
			task_id=$(echo "$claim_output" | grep "^task_id=" | cut -d= -f2)
			gh_ref=$(echo "$claim_output" | grep "^ref=" | cut -d= -f2)

			if [[ -z "$task_id" ]]; then
				log_warn "Failed to parse task_id from claim-task-id.sh output, skipping finding #${finding_id}"
				continue
			fi
		else
			log_warn "Failed to claim task ID for finding #${finding_id}: $claim_output"
			log_info "Skipping this finding (will retry on next run)"
			continue
		fi

		# Build task description
		local task_desc="Fix ${category} issue (${severity}): ${description}${location}${pr_ref} ${priority_tag}${source_tag} #quality #auto-review #auto-dispatch ~30m"

		# Add GitHub issue reference if available
		if [[ -n "$gh_ref" && "$gh_ref" != "offline" ]]; then
			task_desc="${task_desc} ref:${gh_ref}"
		fi

		if [[ "$dry_run" == "true" ]]; then
			echo "  [DRY RUN] ${task_id} ${task_desc}"
		else
			task_lines="${task_lines}- [ ] ${task_id} ${task_desc}\n"

			# Mark as task created in DB
			db "$active_db" "
				UPDATE processed_findings SET task_created = 1, task_id = '${task_id}' WHERE id = $finding_id;
			" 2>/dev/null || true

			# Log task creation
			local escaped_desc
			escaped_desc=$(sql_escape "$task_desc")
			db "$active_db" "
				INSERT INTO task_log (finding_id, task_id, description, severity, source_tool)
				VALUES ($finding_id, '${task_id}', '$escaped_desc', '$severity', '$(sql_escape "$source_tool")');
			" 2>/dev/null || true
		fi

		tasks_created=$((tasks_created + 1))
	done <"$tmp_create"

	if [[ "$dry_run" == "true" ]]; then
		log_info "[DRY RUN] Would create $count task(s)"
		return 0
	fi

	if [[ -n "$task_lines" ]]; then
		echo ""
		log_success "Generated $tasks_created task description(s)"
		echo ""
		echo "=== Task Lines (for TODO.md) ==="
		echo ""
		echo -e "$task_lines"
		echo "================================"
		echo ""
		log_info "To add these to TODO.md, copy the lines above into the appropriate section."
		log_info "Tasks tagged #auto-dispatch will be picked up by supervisor auto-pickup."
	fi

	# Optional dispatch via supervisor
	if [[ "$dispatch" == "true" ]]; then
		dispatch_tasks
	fi

	return 0
}

# =============================================================================
# Dispatch Tasks via Supervisor
# =============================================================================

dispatch_tasks() {
	local supervisor="${SCRIPT_DIR}/supervisor-helper.sh"

	if [[ ! -x "$supervisor" ]]; then
		log_warn "supervisor-helper.sh not found or not executable"
		log_info "Tasks created but not dispatched. Use supervisor manually."
		return 0
	fi

	log_info "Triggering supervisor auto-pickup for #auto-dispatch tasks..."

	local repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

	if "$supervisor" auto-pickup --repo "$repo_root" 2>/dev/null; then
		log_success "Supervisor auto-pickup complete"
	else
		log_warn "Supervisor auto-pickup returned non-zero (may be normal if no new tasks)"
	fi

	return 0
}

# =============================================================================
# Verify Command - Manual verification of findings
# =============================================================================

cmd_verify() {
	local finding_id=""
	local verdict=""

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		finding_id="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--valid)
			verdict="valid"
			shift
			;;
		--false-positive)
			verdict="false_positive"
			shift
			;;
		*)
			log_warn "Unknown option: $1"
			shift
			;;
		esac
	done

	if [[ -z "$finding_id" ]]; then
		log_error "Usage: audit-task-creator-helper.sh verify <finding-id> [--valid|--false-positive]"
		return 1
	fi

	if [[ -z "$verdict" ]]; then
		log_error "Specify --valid or --false-positive"
		return 1
	fi

	local active_db
	active_db=$(get_active_task_db)
	ensure_task_db

	local existing
	existing=$(db "$active_db" "SELECT id FROM processed_findings WHERE id = $finding_id;" 2>/dev/null || echo "")

	if [[ -z "$existing" ]]; then
		log_error "Finding ID $finding_id not found"
		return 1
	fi

	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	if [[ "$verdict" == "false_positive" ]]; then
		db "$active_db" "
			UPDATE processed_findings
			SET is_false_positive = 1, fp_reason = 'manual_verification', verified_by = 'user', verified_at = '$now'
			WHERE id = $finding_id;
		"
		log_success "Finding #$finding_id marked as false positive"
	else
		db "$active_db" "
			UPDATE processed_findings
			SET is_false_positive = 0, fp_reason = NULL, verified_by = 'user', verified_at = '$now'
			WHERE id = $finding_id;
		"
		log_success "Finding #$finding_id verified as valid"
	fi

	return 0
}

# =============================================================================
# Stats Command
# =============================================================================

cmd_stats() {
	local active_db
	active_db=$(get_active_task_db)
	ensure_task_db

	local mode
	mode=$(detect_db_mode)

	echo ""
	echo "Audit Task Creator Stats"
	echo "========================"
	echo ""
	echo "DB mode: $mode"
	echo ""

	# Overall counts
	local total fp valid dup tasks_created dispatched
	total=$(db "$active_db" "SELECT COUNT(*) FROM processed_findings;" 2>/dev/null || echo "0")
	fp=$(db "$active_db" "SELECT COUNT(*) FROM processed_findings WHERE is_false_positive = 1;" 2>/dev/null || echo "0")
	valid=$(db "$active_db" "SELECT COUNT(*) FROM processed_findings WHERE is_false_positive = 0;" 2>/dev/null || echo "0")
	dup=$(db "$active_db" "SELECT COUNT(*) FROM processed_findings WHERE is_duplicate = 1;" 2>/dev/null || echo "0")
	tasks_created=$(db "$active_db" "SELECT COUNT(*) FROM processed_findings WHERE task_created = 1;" 2>/dev/null || echo "0")
	dispatched=$(db "$active_db" "SELECT COUNT(*) FROM processed_findings WHERE dispatched = 1;" 2>/dev/null || echo "0")

	echo "Findings processed:  $total"
	echo "  False positives:   $fp"
	echo "  Valid findings:    $valid"
	echo "  Duplicates:        $dup"
	echo "  Tasks created:     $tasks_created"
	echo "  Dispatched:        $dispatched"
	echo ""

	# By source tool
	echo "By Source Tool:"
	db "$active_db" -separator '|' "
		SELECT COALESCE(source_tool, source) as tool, COUNT(*) as cnt,
		       SUM(is_false_positive) as fp,
		       SUM(task_created) as tasks
		FROM processed_findings
		GROUP BY tool;
	" 2>/dev/null | while IFS='|' read -r tool cnt src_fp src_tasks; do
		printf "  %-15s total: %3s  fp: %3s  tasks: %3s\n" "$tool" "$cnt" "$src_fp" "$src_tasks"
	done
	echo ""

	# By severity (valid only)
	echo "By Severity (valid findings):"
	db "$active_db" -separator '|' "
		SELECT severity, COUNT(*) as cnt
		FROM processed_findings
		WHERE is_false_positive = 0
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

	# Severity reclassification stats
	local reclassified
	reclassified=$(db "$active_db" "
		SELECT COUNT(*) FROM processed_findings
		WHERE severity != original_severity AND original_severity IS NOT NULL;
	" 2>/dev/null || echo "0")
	echo "Severity reclassified: $reclassified"

	# False positive patterns
	echo ""
	echo "False Positive Reasons:"
	db "$active_db" -separator '|' "
		SELECT fp_reason, COUNT(*) as cnt
		FROM processed_findings
		WHERE is_false_positive = 1 AND fp_reason IS NOT NULL
		GROUP BY fp_reason
		ORDER BY cnt DESC
		LIMIT 10;
	" 2>/dev/null | while IFS='|' read -r reason cnt; do
		printf "  %-40s %s\n" "${reason:0:40}" "$cnt"
	done

	# Source databases
	echo ""
	echo "Source Databases:"
	if [[ -f "$AUDIT_DB" ]]; then
		local audit_count
		audit_count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings;" 2>/dev/null || echo "N/A")
		echo "  Unified audit DB: $audit_count findings ($AUDIT_DB)"
	else
		echo "  Unified audit DB: not found (run code-audit-helper.sh collect)"
	fi

	if [[ -f "$LEGACY_COLLECTOR_DB" ]]; then
		local db_comments
		db_comments=$(db "$LEGACY_COLLECTOR_DB" "SELECT COUNT(*) FROM comments;" 2>/dev/null || echo "0")
		echo "  Legacy collector DB: $db_comments comments ($LEGACY_COLLECTOR_DB)"
	else
		echo "  Legacy collector DB: not found"
	fi

	if [[ -d "$LEGACY_PULSE_DIR" ]]; then
		local pulse_files
		pulse_files=$(find "$LEGACY_PULSE_DIR" -maxdepth 1 -name '*-findings.json' 2>/dev/null | wc -l | tr -d ' ')
		echo "  Pulse findings: $pulse_files files ($LEGACY_PULSE_DIR)"
	else
		echo "  Pulse findings: directory not found"
	fi

	echo ""
	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	cat <<'HELP_EOF'
Audit Task Creator Helper - Auto-create tasks from multi-source findings (t1032.4)

USAGE:
  audit-task-creator-helper.sh <command> [options]

COMMANDS:
  scan        Scan findings from sources, filter false positives, classify
  create      Scan + generate TODO-compatible task lines
  verify      Manually verify a finding as valid or false positive
  stats       Show processing statistics
  help        Show this help

SCAN OPTIONS:
  --source SOURCE    Data source: coderabbit, codacy, sonarcloud, codefactor, pulse, all (default)
  --severity LEVEL   Minimum severity: critical, high, medium (default), low, info
  --dry-run          Show what would be scanned without processing

CREATE OPTIONS:
  --source SOURCE    Data source (default: all)
  --severity LEVEL   Minimum severity (default: medium)
  --dry-run          Show tasks that would be created
  --dispatch         After creating tasks, trigger supervisor auto-pickup

VERIFY OPTIONS:
  <finding-id>       The processed finding ID (from scan output or stats)
  --valid            Mark finding as valid (actionable)
  --false-positive   Mark finding as false positive (not actionable)

EXAMPLES:
  # Scan all sources for medium+ findings
  audit-task-creator-helper.sh scan

  # Scan only SonarCloud for critical/high findings
  audit-task-creator-helper.sh scan --source sonarcloud --severity high

  # Create tasks (dry run first)
  audit-task-creator-helper.sh create --dry-run
  audit-task-creator-helper.sh create

  # Create tasks from Codacy findings and dispatch via supervisor
  audit-task-creator-helper.sh create --source codacy --dispatch

  # Manually verify a finding
  audit-task-creator-helper.sh verify 42 --false-positive
  audit-task-creator-helper.sh verify 43 --valid

  # View statistics
  audit-task-creator-helper.sh stats

DB MODES:
  The script auto-detects which database to use:
  - unified: Reads from the audit_findings table in the unified audit DB
             (populated by code-audit-helper.sh from all configured services)
  - legacy:  Reads from the CodeRabbit collector DB and pulse JSON files
             (backward compatible with pre-t1032 setup)

  When in unified mode, legacy sources are also scanned for any findings
  not yet migrated to the unified DB.

FALSE POSITIVE DETECTION:
  Source-agnostic patterns are automatically filtered:
  - Bot meta-comments and tips (CodeRabbit, Codacy, SonarCloud)
  - Walkthrough summaries and change lists
  - Empty or whitespace-only bodies
  - Source-specific noise (CodeRabbit walkthroughs, Codacy style-only, etc.)

SEVERITY RECLASSIFICATION:
  Content-based severity analysis applies to all sources:
  - Security patterns (injection, traversal, RCE) → upgrade to critical/high
  - Source-specific markers (CodeRabbit emoji, SonarCloud BLOCKER, etc.)
  - Upgrades severity when body content indicates higher risk

BACKWARD COMPATIBILITY:
  This script replaces coderabbit-task-creator-helper.sh. The old name is
  kept as a symlink. All existing CLI options continue to work. The --source
  options 'db' and 'pulse' are mapped to 'coderabbit' and 'pulse' respectively.

INTEGRATION:
  # Daily cron (after code-audit-helper.sh collect)
  0 4 * * * cd /path/to/repo && ~/.aidevops/agents/scripts/audit-task-creator-helper.sh create --dispatch

  # Supervisor pulse Phase 10b integration
  # t1032.5 wires this into the supervisor pulse cycle

DATABASES:
  Unified audit DB: ~/.aidevops/.agent-workspace/work/code-audit/audit.db
  Task creator DB:  ~/.aidevops/.agent-workspace/work/code-audit/task-creator.db
  Legacy collector: ~/.aidevops/.agent-workspace/work/coderabbit-reviews/reviews.db
  Legacy task DB:   ~/.aidevops/.agent-workspace/work/coderabbit-reviews/task-creator.db
  Pulse findings:   ~/.aidevops/.agent-workspace/work/review-pulse/findings/

HELP_EOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	# Backward compatibility: map old --source values
	local args=()
	for arg in "$@"; do
		case "$arg" in
		db) args+=("coderabbit") ;;
		*) args+=("$arg") ;;
		esac
	done

	case "$command" in
	scan) cmd_scan "${args[@]+"${args[@]}"}" ;;
	create) cmd_create "${args[@]+"${args[@]}"}" ;;
	verify) cmd_verify "${args[@]+"${args[@]}"}" ;;
	stats) cmd_stats ;;
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
