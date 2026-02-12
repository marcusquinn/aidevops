#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# =============================================================================
# CodeRabbit Task Creator Helper - Auto-create tasks from review findings (t166.3)
# =============================================================================
# Reads CodeRabbit findings from the collector SQLite DB (PR reviews) and/or
# review-pulse JSON files (CLI reviews), filters false positives, deduplicates,
# and outputs TODO-compatible task lines. Optionally dispatches via supervisor.
#
# Usage:
#   coderabbit-task-creator-helper.sh scan [--source db|pulse|all] [--severity LEVEL] [--dry-run]
#   coderabbit-task-creator-helper.sh create [--source db|pulse|all] [--severity LEVEL] [--dry-run] [--dispatch]
#   coderabbit-task-creator-helper.sh verify <finding-id> [--valid|--false-positive]
#   coderabbit-task-creator-helper.sh stats
#   coderabbit-task-creator-helper.sh help
#
# Subtask: t166.3 - Auto-create tasks from valid CodeRabbit findings
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

readonly COLLECTOR_DB="${HOME}/.aidevops/.agent-workspace/work/coderabbit-reviews/reviews.db"
readonly PULSE_FINDINGS_DIR="${HOME}/.aidevops/.agent-workspace/work/review-pulse/findings"
readonly TASK_CREATOR_DB="${HOME}/.aidevops/.agent-workspace/work/coderabbit-reviews/task-creator.db"
readonly SEVERITY_LEVELS=("critical" "high" "medium" "low" "info")

# =============================================================================
# False Positive Patterns
# =============================================================================
# These patterns identify CodeRabbit output that is NOT actionable findings.
# Each pattern is a regex matched against the comment body.

readonly -a FP_PATTERNS=(
	# Bot instructions / meta-comments (safe to match anywhere)
	"<!-- tips_start -->"
	"<!-- tips_end -->"
	"Thank you for using CodeRabbit"
	"We offer full suites of"
	"<!-- commit_ids_reviewed_start -->"
)

# Patterns that only indicate FP when they appear at the START of the body
# (CodeRabbit appends auto-generated footers to ALL comments, including valid findings)
readonly -a FP_START_PATTERNS=(
	"<!-- This is an auto-generated comment"
	"<!-- walkthrough_start -->"
)

# Severity re-classification patterns
# CodeRabbit sometimes marks findings with emoji severity that differs from
# keyword-based classification. These patterns catch the mismatch.
readonly -a SEVERITY_UPGRADE_CRITICAL=(
	"rm -rf.*empty variable"
	"path traversal"
	"command injection"
	"arbitrary code execution"
	"credential.*exposed"
	"secret.*hardcoded"
)

readonly -a SEVERITY_UPGRADE_HIGH=(
	"unvalidated.*input"
	"missing.*validation"
	"SQL injection"
	"XSS"
	"CSRF"
)

# =============================================================================
# Logging
# =============================================================================

log_info() {
	echo -e "${BLUE}[TASK-CREATOR]${NC} $*"
	return 0
}
log_success() {
	echo -e "${GREEN}[TASK-CREATOR]${NC} $*"
	return 0
}
log_warn() {
	echo -e "${YELLOW}[TASK-CREATOR]${NC} $*"
	return 0
}
log_error() {
	echo -e "${RED}[TASK-CREATOR]${NC} $*" >&2
	return 0
}

# =============================================================================
# SQLite wrapper
# =============================================================================

db() {
	sqlite3 -cmd ".timeout 5000" "$@"
}

# =============================================================================
# Task Creator Database
# =============================================================================

ensure_task_db() {
	local db_dir
	db_dir=$(dirname "$TASK_CREATOR_DB")
	mkdir -p "$db_dir" 2>/dev/null || true

	if [[ ! -f "$TASK_CREATOR_DB" ]]; then
		init_task_db
		return 0
	fi

	# Ensure WAL mode
	local current_mode
	current_mode=$(db "$TASK_CREATOR_DB" "PRAGMA journal_mode;" 2>/dev/null || echo "")
	if [[ "$current_mode" != "wal" ]]; then
		db "$TASK_CREATOR_DB" "PRAGMA journal_mode=WAL;" 2>/dev/null || true
	fi

	return 0
}

init_task_db() {
	db "$TASK_CREATOR_DB" <<'SQL' >/dev/null
PRAGMA journal_mode=WAL;

-- Processed findings with verification status
CREATE TABLE IF NOT EXISTS processed_findings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source          TEXT NOT NULL,
    source_id       TEXT NOT NULL,
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
    dispatched      INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_pf_source ON processed_findings(source, source_id);
CREATE INDEX IF NOT EXISTS idx_pf_severity ON processed_findings(severity);
CREATE INDEX IF NOT EXISTS idx_pf_fp ON processed_findings(is_false_positive);
CREATE INDEX IF NOT EXISTS idx_pf_task ON processed_findings(task_created);
SQL

	log_info "Task creator database initialized: $TASK_CREATOR_DB"
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
# False Positive Detection
# =============================================================================

# Check if a comment body matches any false positive pattern
is_false_positive() {
	local body="$1"

	# Check patterns that match anywhere in body
	for pattern in "${FP_PATTERNS[@]}"; do
		if echo "$body" | grep -qiE "$pattern"; then
			echo "$pattern"
			return 0
		fi
	done

	# Check patterns that only match at the START of the body
	# (CodeRabbit appends auto-generated footers to ALL comments)
	local first_line
	first_line=$(echo "$body" | head -1)
	for pattern in "${FP_START_PATTERNS[@]}"; do
		if echo "$first_line" | grep -qiE "$pattern"; then
			echo "starts-with:$pattern"
			return 0
		fi
	done

	# Check for walkthrough-only comments (contain walkthrough but no actionable content)
	# These have "Walkthrough" and "Changes" sections but no "Potential issue" markers
	if echo "$body" | grep -q "walkthrough" && ! echo "$body" | grep -qiE "Potential issue|suggestion|warning|error|fix"; then
		echo "walkthrough-only"
		return 0
	fi

	# Empty or whitespace-only bodies
	if [[ -z "${body// /}" ]]; then
		echo "empty-body"
		return 0
	fi

	return 1
}

# Re-classify severity based on body content
# CodeRabbit's emoji severity markers are more accurate than keyword matching
reclassify_severity() {
	local body="$1"
	local current_severity="$2"
	local lower_body
	lower_body=$(echo "$body" | tr '[:upper:]' '[:lower:]')

	# Check for critical upgrades
	for pattern in "${SEVERITY_UPGRADE_CRITICAL[@]}"; do
		if echo "$lower_body" | grep -qiE "$pattern"; then
			echo "critical"
			return 0
		fi
	done

	# Check for high upgrades
	for pattern in "${SEVERITY_UPGRADE_HIGH[@]}"; do
		if echo "$lower_body" | grep -qiE "$pattern" && [[ "$current_severity" != "critical" ]]; then
			echo "high"
			return 0
		fi
	done

	# Check CodeRabbit's own severity markers (emoji-based)
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

	echo "$current_severity"
	return 0
}

# Extract a concise description from a CodeRabbit comment body
extract_description() {
	local body="$1"

	# Try to extract the bold title line (CodeRabbit format: **Title here**)
	local title
	title=$(echo "$body" | grep -oE '\*\*[^*]+\*\*' | head -1 | sed 's/\*\*//g')

	if [[ -n "$title" && ${#title} -gt 10 ]]; then
		# Truncate to 120 chars
		echo "${title:0:120}"
		return 0
	fi

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
# Core: Scan Findings from Sources
# =============================================================================

# Scan the collector SQLite DB for unprocessed findings
scan_db_findings() {
	local min_severity="$1"

	if [[ ! -f "$COLLECTOR_DB" ]]; then
		log_warn "Collector DB not found: $COLLECTOR_DB"
		log_info "Run 'coderabbit-collector-helper.sh collect --pr NUMBER' first"
		return 0
	fi

	ensure_task_db

	# Get already-processed source IDs from task-creator DB
	local processed_ids
	processed_ids=$(db "$TASK_CREATOR_DB" "
        SELECT source_id FROM processed_findings WHERE source = 'collector_db';
    " 2>/dev/null || echo "")

	# Build exclusion clause for collector DB query
	local exclude_clause=""
	if [[ -n "$processed_ids" ]]; then
		# Convert newline-separated IDs to comma-separated for IN clause
		local id_list
		id_list=$(echo "$processed_ids" | tr '\n' ',' | sed 's/,$//')
		exclude_clause="WHERE c.gh_comment_id NOT IN ($id_list)"
	fi

	# Query all unprocessed comments from collector DB
	local comments_json
	comments_json=$(db "$COLLECTOR_DB" -json "
        SELECT c.id, c.pr_number, c.path, c.line, c.severity, c.category, c.body, c.gh_comment_id
        FROM comments c
        $exclude_clause
        ORDER BY c.pr_number, c.id;
    " 2>/dev/null || echo "[]")

	if [[ "$comments_json" == "[]" || -z "$comments_json" ]]; then
		log_info "No unprocessed findings in collector DB"
		return 0
	fi

	local count
	count=$(echo "$comments_json" | jq 'length' 2>/dev/null || echo "0")
	log_info "Scanning $count unprocessed comments from collector DB..."

	# Write comments to temp file for process substitution (avoids subshell)
	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"
	echo "$comments_json" | jq -c '.[]' >"$tmp_file"

	local total=0
	local valid=0
	local false_positives=0
	local duplicates=0
	local below_threshold=0

	# Process each comment (using redirect to avoid subshell variable loss)
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

		# Check false positive
		local fp_reason=""
		fp_reason=$(is_false_positive "$body") || true

		if [[ -n "$fp_reason" ]]; then
			false_positives=$((false_positives + 1))
			local escaped_fp
			escaped_fp=$(sql_escape "$fp_reason")
			local escaped_desc
			escaped_desc=$(sql_escape "$(extract_description "$body")")
			db "$TASK_CREATOR_DB" "
                INSERT OR IGNORE INTO processed_findings
                    (source, source_id, pr_number, path, line, severity, original_severity, category, description, is_false_positive, fp_reason)
                VALUES ('collector_db', '$(sql_escape "$comment_id")', $pr_number, '$(sql_escape "$path")', ${line:-0},
                        '$severity', '$severity', '$(sql_escape "$category")', '$escaped_desc', 1, '$escaped_fp');
            " 2>/dev/null || true
			continue
		fi

		# Reclassify severity
		local new_severity
		new_severity=$(reclassify_severity "$body" "$severity")

		# Check severity threshold
		if ! meets_severity_threshold "$new_severity" "$min_severity"; then
			below_threshold=$((below_threshold + 1))
			local escaped_desc
			escaped_desc=$(sql_escape "$(extract_description "$body")")
			db "$TASK_CREATOR_DB" "
                INSERT OR IGNORE INTO processed_findings
                    (source, source_id, pr_number, path, line, severity, original_severity, category, description, is_false_positive, fp_reason)
                VALUES ('collector_db', '$(sql_escape "$comment_id")', $pr_number, '$(sql_escape "$path")', ${line:-0},
                        '$new_severity', '$severity', '$(sql_escape "$category")', '$escaped_desc', 0, NULL);
            " 2>/dev/null || true
			continue
		fi

		# Check for duplicates (same path + similar description)
		local description
		description=$(extract_description "$body")
		local escaped_desc
		escaped_desc=$(sql_escape "$description")
		local existing_dup
		existing_dup=$(db "$TASK_CREATOR_DB" "
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
		db "$TASK_CREATOR_DB" "
            INSERT OR IGNORE INTO processed_findings
                (source, source_id, pr_number, path, line, severity, original_severity, category, description,
                 is_false_positive, is_duplicate, duplicate_of)
            VALUES ('collector_db', '$(sql_escape "$comment_id")', $pr_number, '$(sql_escape "$path")', ${line:-0},
                    '$new_severity', '$severity', '$(sql_escape "$category")', '$escaped_desc',
                    0, $is_dup, $(if [[ -n "$dup_of" ]]; then echo "$dup_of"; else echo "NULL"; fi));
        " 2>/dev/null || true
	done <"$tmp_file"

	rm -f "$tmp_file"

	log_info "DB scan: total=$total valid=$valid fp=$false_positives dup=$duplicates below_threshold=$below_threshold"
	return 0
}

# Scan review-pulse JSON findings
scan_pulse_findings() {
	local min_severity="$1"

	if [[ ! -d "$PULSE_FINDINGS_DIR" ]]; then
		log_info "No pulse findings directory: $PULSE_FINDINGS_DIR"
		return 0
	fi

	ensure_task_db

	local latest_findings
	latest_findings=$(find "$PULSE_FINDINGS_DIR" -maxdepth 1 -name '*-findings.json' -print0 2>/dev/null |
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

	# Write findings to temp file to avoid subshell variable loss
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

		# Check if already processed
		local existing
		existing=$(db "$TASK_CREATOR_DB" "
            SELECT id FROM processed_findings
            WHERE source = 'pulse' AND source_id = '$(sql_escape "$finding_id")'
            LIMIT 1;
        " 2>/dev/null || echo "")

		if [[ -n "$existing" ]]; then
			continue
		fi

		# Severity threshold already applied by review-pulse-helper.sh
		# but double-check
		if ! meets_severity_threshold "$severity" "$min_severity"; then
			continue
		fi

		valid=$((valid + 1))
		local escaped_desc
		escaped_desc=$(sql_escape "$description")

		db "$TASK_CREATOR_DB" "
            INSERT OR IGNORE INTO processed_findings
                (source, source_id, path, severity, original_severity, category, description)
            VALUES ('pulse', '$(sql_escape "$finding_id")', '$(sql_escape "$file")', '$severity', '$severity',
                    'general', '$escaped_desc');
        " 2>/dev/null || true
	done <"$tmp_file"

	rm -f "$tmp_file"

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

	case "$source" in
	db)
		scan_db_findings "$min_severity"
		;;
	pulse)
		scan_pulse_findings "$min_severity"
		;;
	all)
		scan_db_findings "$min_severity"
		scan_pulse_findings "$min_severity"
		;;
	*)
		log_error "Unknown source: $source (use: db, pulse, all)"
		return 1
		;;
	esac

	# Show summary of actionable findings
	local actionable_count
	actionable_count=$(db "$TASK_CREATOR_DB" "
        SELECT COUNT(*) FROM processed_findings
        WHERE is_false_positive = 0
          AND is_duplicate = 0
          AND task_created = 0;
    " 2>/dev/null || echo "0")

	log_success "Actionable findings ready for task creation: $actionable_count"

	# Show breakdown
	if [[ "$actionable_count" -gt 0 ]]; then
		echo ""
		echo "Severity breakdown:"
		db "$TASK_CREATOR_DB" -separator '|' "
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

	# Build severity filter for SQL
	local severity_filter=""
	case "$min_severity" in
	critical) severity_filter="AND severity IN ('critical')" ;;
	high) severity_filter="AND severity IN ('critical', 'high')" ;;
	medium) severity_filter="AND severity IN ('critical', 'high', 'medium')" ;;
	low) severity_filter="AND severity IN ('critical', 'high', 'medium', 'low')" ;;
	*) severity_filter="" ;; # info = all
	esac

	# Get actionable findings
	local findings_json
	findings_json=$(db "$TASK_CREATOR_DB" -json "
        SELECT id, source, source_id, pr_number, path, line, severity, category, description
        FROM processed_findings
        WHERE is_false_positive = 0
          AND is_duplicate = 0
          AND task_created = 0
          $severity_filter
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

	# Write findings to temp file to avoid subshell variable loss
	local tmp_create
	tmp_create=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_create}'"
	echo "$findings_json" | jq -c '.[]' >"$tmp_create"

	while IFS= read -r finding; do
		local finding_id severity category path description pr_number
		finding_id=$(echo "$finding" | jq -r '.id')
		severity=$(echo "$finding" | jq -r '.severity')
		category=$(echo "$finding" | jq -r '.category')
		path=$(echo "$finding" | jq -r '.path // ""')
		description=$(echo "$finding" | jq -r '.description')
		pr_number=$(echo "$finding" | jq -r '.pr_number // ""')

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

		# Allocate task ID via claim-task-id.sh (t303)
		local task_id=""
		local gh_ref=""
		local claim_output

		# Build task title for GitHub issue
		local task_title="Fix ${category} issue (${severity}): ${description:0:80}"

		# Try to claim task ID (online mode with GitHub issue as distributed lock)
		if claim_output=$("${SCRIPT_DIR}/claim-task-id.sh" --title "$task_title" --description "Auto-created from CodeRabbit finding #${finding_id}" --labels "quality,auto-review" 2>&1); then
			# Parse output: task_id=tNNN and ref=GH#NNN
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

		# Build task description with allocated task ID
		local task_desc="Fix ${category} issue (${severity}): ${description}${location}${pr_ref} ${priority_tag} #quality #auto-review #auto-dispatch ~30m"

		# Add GitHub issue reference if available
		if [[ -n "$gh_ref" && "$gh_ref" != "offline" ]]; then
			task_desc="${task_desc} ref:${gh_ref}"
		fi

		if [[ "$dry_run" == "true" ]]; then
			echo "  [DRY RUN] ${task_id} ${task_desc}"
		else
			task_lines="${task_lines}- [ ] ${task_id} ${task_desc}\n"

			# Mark as task created in DB and store allocated task ID
			db "$TASK_CREATOR_DB" "
                UPDATE processed_findings SET task_created = 1, task_id = '${task_id}' WHERE id = $finding_id;
            " 2>/dev/null || true

			# Log task creation
			local escaped_desc
			escaped_desc=$(sql_escape "$task_desc")
			db "$TASK_CREATOR_DB" "
                INSERT INTO task_log (finding_id, task_id, description, severity)
                VALUES ($finding_id, '${task_id}', '$escaped_desc', '$severity');
            " 2>/dev/null || true
		fi

		tasks_created=$((tasks_created + 1))
	done <"$tmp_create"

	rm -f "$tmp_create"

	if [[ "$dry_run" == "true" ]]; then
		log_info "[DRY RUN] Would create $count task(s)"
		return 0
	fi

	if [[ -n "$task_lines" ]]; then
		echo ""
		log_success "Generated $count task description(s)"
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

	# First positional arg is finding ID
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
		log_error "Usage: coderabbit-task-creator-helper.sh verify <finding-id> [--valid|--false-positive]"
		return 1
	fi

	if [[ -z "$verdict" ]]; then
		log_error "Specify --valid or --false-positive"
		return 1
	fi

	ensure_task_db

	local existing
	existing=$(db "$TASK_CREATOR_DB" "SELECT id FROM processed_findings WHERE id = $finding_id;" 2>/dev/null || echo "")

	if [[ -z "$existing" ]]; then
		log_error "Finding ID $finding_id not found"
		return 1
	fi

	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	if [[ "$verdict" == "false_positive" ]]; then
		db "$TASK_CREATOR_DB" "
            UPDATE processed_findings
            SET is_false_positive = 1, fp_reason = 'manual_verification', verified_by = 'user', verified_at = '$now'
            WHERE id = $finding_id;
        "
		log_success "Finding #$finding_id marked as false positive"
	else
		db "$TASK_CREATOR_DB" "
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
	ensure_task_db

	echo ""
	echo "CodeRabbit Task Creator Stats"
	echo "============================="
	echo ""

	# Overall counts
	local total fp valid dup tasks_created dispatched
	total=$(db "$TASK_CREATOR_DB" "SELECT COUNT(*) FROM processed_findings;" 2>/dev/null || echo "0")
	fp=$(db "$TASK_CREATOR_DB" "SELECT COUNT(*) FROM processed_findings WHERE is_false_positive = 1;" 2>/dev/null || echo "0")
	valid=$(db "$TASK_CREATOR_DB" "SELECT COUNT(*) FROM processed_findings WHERE is_false_positive = 0;" 2>/dev/null || echo "0")
	dup=$(db "$TASK_CREATOR_DB" "SELECT COUNT(*) FROM processed_findings WHERE is_duplicate = 1;" 2>/dev/null || echo "0")
	tasks_created=$(db "$TASK_CREATOR_DB" "SELECT COUNT(*) FROM processed_findings WHERE task_created = 1;" 2>/dev/null || echo "0")
	dispatched=$(db "$TASK_CREATOR_DB" "SELECT COUNT(*) FROM processed_findings WHERE dispatched = 1;" 2>/dev/null || echo "0")

	echo "Findings processed:  $total"
	echo "  False positives:   $fp"
	echo "  Valid findings:    $valid"
	echo "  Duplicates:        $dup"
	echo "  Tasks created:     $tasks_created"
	echo "  Dispatched:        $dispatched"
	echo ""

	# By source
	echo "By Source:"
	db "$TASK_CREATOR_DB" -separator '|' "
        SELECT source, COUNT(*) as cnt,
               SUM(is_false_positive) as fp,
               SUM(task_created) as tasks
        FROM processed_findings
        GROUP BY source;
    " 2>/dev/null | while IFS='|' read -r src cnt src_fp src_tasks; do
		printf "  %-15s total: %3s  fp: %3s  tasks: %3s\n" "$src" "$cnt" "$src_fp" "$src_tasks"
	done
	echo ""

	# By severity (valid only)
	echo "By Severity (valid findings):"
	db "$TASK_CREATOR_DB" -separator '|' "
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
	reclassified=$(db "$TASK_CREATOR_DB" "
        SELECT COUNT(*) FROM processed_findings
        WHERE severity != original_severity AND original_severity IS NOT NULL;
    " 2>/dev/null || echo "0")
	echo "Severity reclassified: $reclassified"

	# False positive patterns
	echo ""
	echo "False Positive Reasons:"
	db "$TASK_CREATOR_DB" -separator '|' "
        SELECT fp_reason, COUNT(*) as cnt
        FROM processed_findings
        WHERE is_false_positive = 1 AND fp_reason IS NOT NULL
        GROUP BY fp_reason
        ORDER BY cnt DESC
        LIMIT 10;
    " 2>/dev/null | while IFS='|' read -r reason cnt; do
		printf "  %-40s %s\n" "${reason:0:40}" "$cnt"
	done

	# Collector DB stats
	echo ""
	echo "Source Databases:"
	if [[ -f "$COLLECTOR_DB" ]]; then
		local db_comments
		db_comments=$(db "$COLLECTOR_DB" "SELECT COUNT(*) FROM comments;" 2>/dev/null || echo "0")
		echo "  Collector DB: $db_comments comments ($COLLECTOR_DB)"
	else
		echo "  Collector DB: not found"
	fi

	if [[ -d "$PULSE_FINDINGS_DIR" ]]; then
		local pulse_files
		pulse_files=$(find "$PULSE_FINDINGS_DIR" -maxdepth 1 -name '*-findings.json' 2>/dev/null | wc -l | tr -d ' ')
		echo "  Pulse findings: $pulse_files files ($PULSE_FINDINGS_DIR)"
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
CodeRabbit Task Creator Helper - Auto-create tasks from review findings (t166.3)

USAGE:
  coderabbit-task-creator-helper.sh <command> [options]

COMMANDS:
  scan        Scan findings from sources, filter false positives, classify
  create      Scan + generate TODO-compatible task lines
  verify      Manually verify a finding as valid or false positive
  stats       Show processing statistics
  help        Show this help

SCAN OPTIONS:
  --source SOURCE    Data source: db (collector SQLite), pulse (CLI JSON), all (default)
  --severity LEVEL   Minimum severity: critical, high, medium (default), low, info
  --dry-run          Show what would be scanned without processing

CREATE OPTIONS:
  --source SOURCE    Data source: db, pulse, all (default)
  --severity LEVEL   Minimum severity (default: medium)
  --dry-run          Show tasks that would be created
  --dispatch         After creating tasks, trigger supervisor auto-pickup

VERIFY OPTIONS:
  <finding-id>       The processed finding ID (from scan output or stats)
  --valid            Mark finding as valid (actionable)
  --false-positive   Mark finding as false positive (not actionable)

EXAMPLES:
  # Scan all sources for medium+ findings
  coderabbit-task-creator-helper.sh scan

  # Scan only collector DB for critical/high findings
  coderabbit-task-creator-helper.sh scan --source db --severity high

  # Create tasks (dry run first)
  coderabbit-task-creator-helper.sh create --dry-run
  coderabbit-task-creator-helper.sh create

  # Create tasks and dispatch via supervisor
  coderabbit-task-creator-helper.sh create --dispatch

  # Manually verify a finding
  coderabbit-task-creator-helper.sh verify 42 --false-positive
  coderabbit-task-creator-helper.sh verify 43 --valid

  # View statistics
  coderabbit-task-creator-helper.sh stats

FALSE POSITIVE DETECTION:
  The following patterns are automatically filtered:
  - CodeRabbit walkthrough summaries (auto-generated, not findings)
  - Summary tables and change lists
  - Bot meta-comments and tips
  - Empty or whitespace-only bodies

SEVERITY RECLASSIFICATION:
  CodeRabbit's keyword-based severity can be inaccurate. This script also checks:
  - CodeRabbit's own emoji markers (Critical, Major, Minor)
  - Content patterns (rm -rf, path traversal, injection, etc.)
  - Upgrades severity when body content indicates higher risk

INTEGRATION:
  # Daily cron (after collector runs)
  0 4 * * * cd /path/to/repo && ~/.aidevops/agents/scripts/coderabbit-task-creator-helper.sh create --dispatch

  # GitHub Actions (after review-pulse)
  - name: Create Tasks from Findings
    run: .agents/scripts/coderabbit-task-creator-helper.sh create --dry-run

  # Supervisor pulse integration
  # Add to Phase 8 (quality) of supervisor pulse

DATABASES:
  Collector DB: ~/.aidevops/.agent-workspace/work/coderabbit-reviews/reviews.db
  Task Creator DB: ~/.aidevops/.agent-workspace/work/coderabbit-reviews/task-creator.db
  Pulse Findings: ~/.aidevops/.agent-workspace/work/review-pulse/findings/

HELP_EOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	scan) cmd_scan "$@" ;;
	create) cmd_create "$@" ;;
	verify) cmd_verify "$@" ;;
	stats) cmd_stats "$@" ;;
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
