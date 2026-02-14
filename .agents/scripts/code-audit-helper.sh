#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# =============================================================================
# Code Audit Helper - Unified Audit Orchestrator (t1032.1)
# =============================================================================
# Calls each service collector (CodeRabbit, Codacy, SonarCloud, CodeFactor),
# aggregates findings into a common SQLite schema, deduplicates cross-service
# findings on same file+line, and outputs a unified report.
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
# Logging
# =============================================================================

log_info() {
	echo -e "${BLUE}[AUDIT]${NC} $*" >&2
	return 0
}
log_success() {
	echo -e "${GREEN}[AUDIT]${NC} $*" >&2
	return 0
}
log_warn() {
	echo -e "${YELLOW}[AUDIT]${NC} $*" >&2
	return 0
}
log_error() {
	echo -e "${RED}[AUDIT]${NC} $*" >&2
	return 0
}

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
	val="${val//\'/\'\'}"
	echo "$val"
	return 0
}

# =============================================================================
# Service Collectors
# =============================================================================

# Collect findings from CodeRabbit via its collector helper
collect_coderabbit() {
	local run_id="$1"
	local _repo="$2" # reserved for future repo-scoped collection
	local pr_number="$3"
	local count=0

	local collector="${SCRIPT_DIR}/coderabbit-collector-helper.sh"
	if [[ ! -x "$collector" ]]; then
		log_warn "CodeRabbit collector not found: $collector"
		return 0
	fi

	# If we have a PR, collect from it
	if [[ "$pr_number" -gt 0 ]]; then
		log_info "Collecting CodeRabbit findings for PR #${pr_number}..."
		"$collector" collect --pr "$pr_number" 2>/dev/null || {
			log_warn "CodeRabbit collection failed for PR #${pr_number}"
			echo "0"
			return 0
		}

		# Import from CodeRabbit's own DB into unified audit_findings
		local cr_db="${HOME}/.aidevops/.agent-workspace/work/coderabbit-reviews/reviews.db"
		if [[ -f "$cr_db" ]]; then
			count=$(import_coderabbit_findings "$run_id" "$cr_db" "$pr_number")
		fi
	else
		log_info "No PR specified — skipping CodeRabbit (requires PR context)"
	fi

	echo "$count"
	return 0
}

# Import CodeRabbit findings from its native DB into audit_findings
import_coderabbit_findings() {
	local run_id="$1"
	local cr_db="$2"
	local pr_number="$3"

	# Extract comments from CodeRabbit DB and insert into audit_findings
	local sql_file
	sql_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${sql_file}'"

	db "$cr_db" -separator $'\x1f' "
        SELECT path, line, severity, category, body
        FROM comments
        WHERE pr_number = $pr_number
        ORDER BY collected_at DESC;
    " 2>/dev/null | while IFS=$'\x1f' read -r path line severity category body; do
		local desc
		desc=$(echo "$body" | cut -c1-500)
		local dedup_key="${path}:${line}"
		echo "INSERT INTO audit_findings (run_id, source, severity, path, line, description, category, dedup_key)
              VALUES ($run_id, 'coderabbit', '$(sql_escape "$severity")', '$(sql_escape "$path")', ${line:-0},
                      '$(sql_escape "$desc")', '$(sql_escape "$category")', '$(sql_escape "$dedup_key")');" >>"$sql_file"
	done

	if [[ -s "$sql_file" ]]; then
		db "$AUDIT_DB" <"$sql_file" 2>/dev/null || log_warn "Some CodeRabbit imports may have failed"
	fi

	local count
	count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE run_id = $run_id AND source = 'coderabbit';")
	echo "${count:-0}"
	return 0
}

# Collect findings from SonarCloud via API
collect_sonarcloud() {
	local run_id="$1"
	local repo="$2"
	local _pr_number="$3"
	local count=0

	if [[ -z "${SONAR_TOKEN:-}" ]]; then
		log_warn "SONAR_TOKEN not set — skipping SonarCloud"
		echo "0"
		return 0
	fi

	log_info "Collecting SonarCloud findings..."

	local project_key="${SONAR_PROJECT_KEY:-}"
	if [[ -z "$project_key" ]]; then
		# Try to derive from repo name
		project_key=$(echo "$repo" | tr '/' '_')
	fi

	local api_url="https://sonarcloud.io/api/issues/search"
	local params="componentKeys=${project_key}&resolved=false&ps=100&statuses=OPEN,CONFIRMED,REOPENED"

	local response
	response=$(curl -s -u "${SONAR_TOKEN}:" "${api_url}?${params}" 2>/dev/null) || {
		log_warn "SonarCloud API request failed"
		echo "0"
		return 0
	}

	if ! command -v jq &>/dev/null; then
		log_warn "jq not available — cannot parse SonarCloud response"
		echo "0"
		return 0
	fi

	# Parse issues and insert into audit_findings
	local sql_file
	sql_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${sql_file}'"

	local jq_filter_file
	jq_filter_file=$(mktemp)
	push_cleanup "rm -f '${jq_filter_file}'"

	cat >"$jq_filter_file" <<'JQ_EOF'
def sql_str: gsub("'"; "''") | "'" + . + "'";
def map_severity:
    if . == "BLOCKER" then "critical"
    elif . == "CRITICAL" then "critical"
    elif . == "MAJOR" then "high"
    elif . == "MINOR" then "medium"
    elif . == "INFO" then "low"
    else "info"
    end;
def map_type:
    if . == "BUG" then "bug"
    elif . == "VULNERABILITY" then "security"
    elif . == "SECURITY_HOTSPOT" then "security"
    elif . == "CODE_SMELL" then "style"
    else "general"
    end;
(.issues // [])[] |
(.component // "" | split(":") | if length > 1 then .[1:] | join(":") else "" end) as $path |
((.line // 0) | tostring) as $line |
($path + ":" + $line) as $dedup_key |
"INSERT INTO audit_findings (run_id, source, severity, path, line, description, category, rule_id, dedup_key) VALUES (" +
$run_id + ", 'sonarcloud', " +
((.severity // "INFO") | map_severity | sql_str) + ", " +
($path | sql_str) + ", " +
$line + ", " +
((.message // "") | sql_str) + ", " +
((.type // "CODE_SMELL") | map_type | sql_str) + ", " +
((.rule // "") | sql_str) + ", " +
($dedup_key | sql_str) +
");"
JQ_EOF

	echo "$response" | jq -r \
		--arg run_id "$run_id" \
		-f "$jq_filter_file" >"$sql_file" 2>/dev/null || true

	if [[ -s "$sql_file" ]]; then
		db "$AUDIT_DB" <"$sql_file" 2>/dev/null || log_warn "Some SonarCloud imports may have failed"
	fi

	count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE run_id = $run_id AND source = 'sonarcloud';")
	echo "${count:-0}"
	return 0
}

# Collect findings from Codacy via API
collect_codacy() {
	local run_id="$1"
	local repo="$2"
	local _pr_number="$3"
	local count=0

	local api_token="${CODACY_API_TOKEN:-${CODACY_PROJECT_TOKEN:-}}"
	if [[ -z "$api_token" ]]; then
		log_warn "CODACY_API_TOKEN not set — skipping Codacy"
		echo "0"
		return 0
	fi

	log_info "Collecting Codacy findings..."

	local org username repo_name
	org="${CODACY_ORGANIZATION:-}"
	username="${CODACY_USERNAME:-}"
	repo_name=$(echo "$repo" | cut -d'/' -f2)
	local provider="${org:-$username}"

	if [[ -z "$provider" ]]; then
		# Try to derive from repo
		provider=$(echo "$repo" | cut -d'/' -f1)
	fi

	local api_url="https://app.codacy.com/api/v3/analysis/organizations/gh/${provider}/repositories/${repo_name}/issues/search"

	local response
	response=$(curl -s -H "api-token: ${api_token}" \
		-H "Content-Type: application/json" \
		-d '{"limit": 100}' \
		"$api_url" 2>/dev/null) || {
		log_warn "Codacy API request failed"
		echo "0"
		return 0
	}

	if ! command -v jq &>/dev/null; then
		log_warn "jq not available — cannot parse Codacy response"
		echo "0"
		return 0
	fi

	local sql_file
	sql_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${sql_file}'"

	local jq_filter_file
	jq_filter_file=$(mktemp)
	push_cleanup "rm -f '${jq_filter_file}'"

	cat >"$jq_filter_file" <<'JQ_EOF'
def sql_str: gsub("'"; "''") | "'" + . + "'";
def map_severity:
    if . == "Error" then "critical"
    elif . == "Warning" then "high"
    elif . == "Info" then "medium"
    else "info"
    end;
def map_category:
    if . == "Security" then "security"
    elif . == "ErrorProne" then "bug"
    elif . == "Performance" then "performance"
    elif . == "CodeStyle" then "style"
    elif . == "Compatibility" then "general"
    elif . == "UnusedCode" then "style"
    elif . == "Complexity" then "refactoring"
    elif . == "Documentation" then "documentation"
    else "general"
    end;
(.data // [])[] |
((.filePath // "") | tostring) as $path |
((.lineNumber // 0) | tostring) as $line |
($path + ":" + $line) as $dedup_key |
"INSERT INTO audit_findings (run_id, source, severity, path, line, description, category, rule_id, dedup_key) VALUES (" +
$run_id + ", 'codacy', " +
((.level // "Info") | map_severity | sql_str) + ", " +
($path | sql_str) + ", " +
$line + ", " +
((.message // "") | sql_str) + ", " +
((.patternInfo.category // "general") | map_category | sql_str) + ", " +
((.patternInfo.id // "") | sql_str) + ", " +
($dedup_key | sql_str) +
");"
JQ_EOF

	echo "$response" | jq -r \
		--arg run_id "$run_id" \
		-f "$jq_filter_file" >"$sql_file" 2>/dev/null || true

	if [[ -s "$sql_file" ]]; then
		db "$AUDIT_DB" <"$sql_file" 2>/dev/null || log_warn "Some Codacy imports may have failed"
	fi

	count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE run_id = $run_id AND source = 'codacy';")
	echo "${count:-0}"
	return 0
}

# Collect findings from CodeFactor via API
collect_codefactor() {
	local run_id="$1"
	local repo="$2"
	local _pr_number="$3"
	local count=0

	local api_token="${CODEFACTOR_API_TOKEN:-}"
	if [[ -z "$api_token" ]]; then
		log_warn "CODEFACTOR_API_TOKEN not set — skipping CodeFactor"
		echo "0"
		return 0
	fi

	log_info "Collecting CodeFactor findings..."

	local api_url="https://www.codefactor.io/api/v1/repos/github/${repo}/issues"

	local response
	response=$(curl -s -H "Authorization: Bearer ${api_token}" \
		-H "Accept: application/json" \
		"$api_url" 2>/dev/null) || {
		log_warn "CodeFactor API request failed"
		echo "0"
		return 0
	}

	if ! command -v jq &>/dev/null; then
		log_warn "jq not available — cannot parse CodeFactor response"
		echo "0"
		return 0
	fi

	local sql_file
	sql_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${sql_file}'"

	local jq_filter_file
	jq_filter_file=$(mktemp)
	push_cleanup "rm -f '${jq_filter_file}'"

	cat >"$jq_filter_file" <<'JQ_EOF'
def sql_str: gsub("'"; "''") | "'" + . + "'";
def map_severity:
    if . == "Critical" or . == "Major" then "critical"
    elif . == "Minor" then "medium"
    elif . == "Issue" then "high"
    else "info"
    end;
(.[] // empty) |
((.filePath // "") | tostring) as $path |
((.startLine // 0) | tostring) as $line |
($path + ":" + $line) as $dedup_key |
"INSERT INTO audit_findings (run_id, source, severity, path, line, description, category, rule_id, dedup_key) VALUES (" +
$run_id + ", 'codefactor', " +
((.severity // "Info") | map_severity | sql_str) + ", " +
($path | sql_str) + ", " +
$line + ", " +
((.message // .description // "") | sql_str) + ", 'general', " +
((.ruleId // "") | sql_str) + ", " +
($dedup_key | sql_str) +
");"
JQ_EOF

	echo "$response" | jq -r \
		--arg run_id "$run_id" \
		-f "$jq_filter_file" >"$sql_file" 2>/dev/null || true

	if [[ -s "$sql_file" ]]; then
		db "$AUDIT_DB" <"$sql_file" 2>/dev/null || log_warn "Some CodeFactor imports may have failed"
	fi

	count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE run_id = $run_id AND source = 'codefactor';")
	echo "${count:-0}"
	return 0
}

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

cmd_audit() {
	local repo=""
	local pr_number=0
	local services_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --repo"
				return 1
			}
			repo="$2"
			shift 2
			;;
		--pr)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --pr"
				return 1
			}
			pr_number="$2"
			shift 2
			;;
		--services)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --services"
				return 1
			}
			services_filter="$2"
			shift 2
			;;
		*)
			log_warn "Unknown option: $1"
			shift
			;;
		esac
	done

	# Validate numeric inputs to prevent SQL injection
	if [[ "$pr_number" != "0" ]] && ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
		log_error "Invalid PR number: $pr_number"
		return 1
	fi

	# Auto-detect repo if not specified
	if [[ -z "$repo" ]]; then
		repo=$(get_repo)
	fi

	# Auto-detect PR if not specified
	if [[ "$pr_number" -eq 0 ]]; then
		pr_number=$(gh pr view --json number -q .number 2>/dev/null || echo "0")
	fi

	local head_sha
	head_sha=$(get_head_sha)

	ensure_db

	log_info "Starting unified code audit for ${repo}"
	[[ "$pr_number" -gt 0 ]] && log_info "PR: #${pr_number} (SHA: ${head_sha})"

	# Create audit run
	local run_id
	run_id=$(db "$AUDIT_DB" "
        INSERT INTO audit_runs (repo, pr_number, head_sha)
        VALUES ('$(sql_escape "$repo")', $pr_number, '$(sql_escape "$head_sha")');
        SELECT last_insert_rowid();
    ")

	log_info "Audit run #${run_id} started"

	# Determine which services to run
	local services
	if [[ -n "$services_filter" ]]; then
		services="$services_filter"
	else
		services=$(get_configured_services)
	fi

	local services_run=""
	local total_findings=0

	# Iterate configured services and call each collector
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

	# Deduplicate cross-service findings
	deduplicate_findings "$run_id"

	# Update audit run as completed
	db "$AUDIT_DB" "
        UPDATE audit_runs
        SET completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            services_run = '$(sql_escape "$services_run")',
            status = 'complete'
        WHERE id = $run_id;
    "

	# Output summary
	echo ""
	print_summary "$run_id"

	log_success "Audit run #${run_id} complete: ${total_findings} total findings from ${services_run}"
	return 0
}

# =============================================================================
# Summary Output
# =============================================================================

print_summary() {
	local run_id="$1"

	echo "============================================"
	echo "  Unified Code Audit Report (Run #${run_id})"
	echo "============================================"
	echo ""

	# Run metadata
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

	# Findings by source (excluding duplicates)
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

	# Findings by severity (excluding duplicates)
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

	# Findings by category (excluding duplicates)
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

	# Most affected files (top 10, excluding duplicates)
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

	# Deduplication stats
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

# =============================================================================
# Report Command
# =============================================================================

cmd_report() {
	local format="text"
	local severity=""
	local run_id=""
	local limit=100

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --format"
				return 1
			}
			format="$2"
			shift 2
			;;
		--severity)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --severity"
				return 1
			}
			severity="$2"
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
		--limit)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --limit"
				return 1
			}
			limit="$2"
			shift 2
			;;
		*)
			log_warn "Unknown option: $1"
			shift
			;;
		esac
	done

	# Validate numeric inputs to prevent SQL injection
	if [[ -n "$run_id" ]] && ! [[ "$run_id" =~ ^[0-9]+$ ]]; then
		log_error "Invalid run ID: $run_id"
		return 1
	fi
	if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
		log_error "Invalid limit: $limit"
		return 1
	fi

	ensure_db

	# Default to latest run
	if [[ -z "$run_id" ]]; then
		run_id=$(db "$AUDIT_DB" "SELECT id FROM audit_runs ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
		if [[ -z "$run_id" ]]; then
			log_error "No audit runs found. Run 'code-audit-helper.sh audit' first."
			return 1
		fi
	fi

	# Build WHERE clause
	local where="WHERE run_id = $run_id AND is_duplicate = 0"
	if [[ -n "$severity" ]]; then
		where="${where} AND severity = '$(sql_escape "$severity")'"
	fi

	case "$format" in
	json)
		db "$AUDIT_DB" -json "
                SELECT id, source, severity, path, line, description, category, rule_id
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
            "
		;;
	text | *)
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
		;;
	esac

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
		if [[ "$(uname)" == "Darwin" ]]; then
			db_size=$(stat -f %z "$AUDIT_DB" 2>/dev/null || echo "0")
		else
			db_size=$(stat -c %s "$AUDIT_DB" 2>/dev/null || echo "0")
		fi
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

	# Get previous snapshot
	local prev_total prev_critical prev_high
	prev_total=$(db "$AUDIT_DB" "SELECT total FROM regression_snapshots WHERE source='sonarcloud' ORDER BY id DESC LIMIT 1;" 2>/dev/null) || prev_total=""
	prev_critical=$(db "$AUDIT_DB" "SELECT critical FROM regression_snapshots WHERE source='sonarcloud' ORDER BY id DESC LIMIT 1;" 2>/dev/null) || prev_critical=""
	prev_high=$(db "$AUDIT_DB" "SELECT high FROM regression_snapshots WHERE source='sonarcloud' ORDER BY id DESC LIMIT 1;" 2>/dev/null) || prev_high=""

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
	check-regression) cmd_check_regression "$@" ;;
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
