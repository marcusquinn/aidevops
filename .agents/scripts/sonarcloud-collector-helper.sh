#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# =============================================================================
# SonarCloud Collector Helper - Code Quality Issues into SQLite (t1032.3)
# =============================================================================
# Polls SonarCloud API for issues and security hotspots, extracts findings
# into a SQLite database, and maps severity to our unified scale.
#
# Usage:
#   sonarcloud-collector-helper.sh collect [--project KEY] [--branch NAME]
#   sonarcloud-collector-helper.sh query [--severity LEVEL] [--format json|text]
#   sonarcloud-collector-helper.sh summary [--last N]
#   sonarcloud-collector-helper.sh status
#   sonarcloud-collector-helper.sh export [--format json|csv]
#   sonarcloud-collector-helper.sh help
#
# Subtask: t1032.3 - SonarCloud collector for unified audit system
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

readonly COLLECTOR_DATA_DIR="${HOME}/.aidevops/.agent-workspace/work/code-audit"
readonly COLLECTOR_DB="${COLLECTOR_DATA_DIR}/audit.db"
readonly SONARCLOUD_API_BASE="https://sonarcloud.io/api"

# =============================================================================
# Logging
# =============================================================================

log_info() {
	echo -e "${BLUE}[SONARCLOUD]${NC} $*"
	return 0
}
log_success() {
	echo -e "${GREEN}[SONARCLOUD]${NC} $*"
	return 0
}
log_warn() {
	echo -e "${YELLOW}[SONARCLOUD]${NC} $*"
	return 0
}
log_error() {
	echo -e "${RED}[SONARCLOUD]${NC} $*" >&2
	return 0
}

# =============================================================================
# SQLite wrapper: sets busy_timeout on every connection (t135.3 pattern)
# =============================================================================

db() {
	sqlite3 -cmd ".timeout 5000" "$@"
}

# =============================================================================
# Database Initialization
# =============================================================================

ensure_db() {
	mkdir -p "$COLLECTOR_DATA_DIR" 2>/dev/null || true

	if [[ ! -f "$COLLECTOR_DB" ]]; then
		init_db
		return 0
	fi

	# Ensure WAL mode for existing databases
	local current_mode
	current_mode=$(db "$COLLECTOR_DB" "PRAGMA journal_mode;" 2>/dev/null || echo "")
	if [[ "$current_mode" != "wal" ]]; then
		db "$COLLECTOR_DB" "PRAGMA journal_mode=WAL;" 2>/dev/null || log_warn "Failed to enable WAL mode"
	fi

	return 0
}

init_db() {
	db "$COLLECTOR_DB" <<'SQL' >/dev/null
PRAGMA journal_mode=WAL;

-- Unified audit findings table (shared across all collectors)
CREATE TABLE IF NOT EXISTS audit_findings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source          TEXT NOT NULL,
    repo            TEXT NOT NULL,
    branch          TEXT,
    project_key     TEXT,
    finding_key     TEXT UNIQUE,
    severity        TEXT NOT NULL,
    category        TEXT,
    rule            TEXT,
    message         TEXT NOT NULL,
    path            TEXT,
    line            INTEGER,
    component       TEXT,
    status          TEXT,
    created_at      TEXT,
    updated_at      TEXT,
    collected_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Collection runs tracking
CREATE TABLE IF NOT EXISTS collection_runs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source          TEXT NOT NULL,
    repo            TEXT NOT NULL,
    project_key     TEXT,
    branch          TEXT,
    collected_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    finding_count   INTEGER DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'complete'
);

CREATE INDEX IF NOT EXISTS idx_findings_source ON audit_findings(source);
CREATE INDEX IF NOT EXISTS idx_findings_severity ON audit_findings(severity);
CREATE INDEX IF NOT EXISTS idx_findings_repo ON audit_findings(repo);
CREATE INDEX IF NOT EXISTS idx_findings_path ON audit_findings(path);
CREATE INDEX IF NOT EXISTS idx_findings_key ON audit_findings(finding_key);
CREATE INDEX IF NOT EXISTS idx_runs_source ON collection_runs(source);
SQL

	log_info "Database initialized: $COLLECTOR_DB"
	return 0
}

# =============================================================================
# Severity Mapping
# =============================================================================

map_severity() {
	local sonar_severity="$1"

	case "$sonar_severity" in
	BLOCKER)
		echo "critical"
		;;
	CRITICAL)
		echo "critical"
		;;
	MAJOR)
		echo "high"
		;;
	MINOR)
		echo "medium"
		;;
	INFO)
		echo "info"
		;;
	*)
		echo "info"
		;;
	esac
}

# =============================================================================
# API Helpers
# =============================================================================

get_sonar_token() {
	local token

	# Try gopass first
	if command -v gopass >/dev/null 2>&1; then
		token=$(gopass show -o aidevops/SONAR_TOKEN 2>/dev/null || echo "")
	fi

	# Fallback to credentials.sh
	if [[ -z "$token" ]] && [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
		# shellcheck disable=SC1091
		source "${HOME}/.config/aidevops/credentials.sh"
		token="${SONAR_TOKEN:-}"
	fi

	# Fallback to environment
	if [[ -z "$token" ]]; then
		token="${SONAR_TOKEN:-}"
	fi

	if [[ -z "$token" ]]; then
		log_error "SONAR_TOKEN not found. Set via: aidevops secret set SONAR_TOKEN"
		return 1
	fi

	echo "$token"
}

get_project_key() {
	local repo="$1"
	# SonarCloud project key is typically org_repo format
	# Example: marcusquinn_aidevops
	echo "$repo" | tr '/' '_'
}

call_sonar_api() {
	local endpoint="$1"
	shift
	local token
	token=$(get_sonar_token) || return 1

	local url="${SONARCLOUD_API_BASE}${endpoint}"

	curl -s -u "${token}:" "$url" "$@"
}

# =============================================================================
# Collection Functions
# =============================================================================

collect_issues() {
	local project_key="$1"
	local branch="${2:-}"
	local page=1
	local page_size=500
	local total_collected=0

	log_info "Collecting issues for project: $project_key"

	while true; do
		local params="componentKeys=${project_key}&p=${page}&ps=${page_size}&resolved=false"
		if [[ -n "$branch" ]]; then
			params="${params}&branch=${branch}"
		fi

		local response
		response=$(call_sonar_api "/issues/search?${params}") || {
			log_error "Failed to fetch issues from SonarCloud API"
			return 1
		}

		# Check if response is valid JSON
		if ! echo "$response" | jq empty 2>/dev/null; then
			log_error "Invalid JSON response from SonarCloud API"
			return 1
		fi

		# Extract issues
		local issues
		issues=$(echo "$response" | jq -c '.issues[]?' 2>/dev/null || echo "")

		if [[ -z "$issues" ]]; then
			break
		fi

		# Process each issue
		while IFS= read -r issue; do
			[[ -z "$issue" ]] && continue

			local key severity rule message component line status created updated
			key=$(echo "$issue" | jq -r '.key // ""')
			severity=$(echo "$issue" | jq -r '.severity // "INFO"')
			rule=$(echo "$issue" | jq -r '.rule // ""')
			message=$(echo "$issue" | jq -r '.message // ""')
			component=$(echo "$issue" | jq -r '.component // ""')
			line=$(echo "$issue" | jq -r '.line // "null"')
			status=$(echo "$issue" | jq -r '.status // ""')
			created=$(echo "$issue" | jq -r '.creationDate // ""')
			updated=$(echo "$issue" | jq -r '.updateDate // ""')

			# Extract file path from component (remove project key prefix)
			local path
			path=$(echo "$component" | sed "s|^${project_key}:||")

			# Map severity
			local mapped_severity
			mapped_severity=$(map_severity "$severity")

			# Store in database
			store_finding "sonarcloud" "$project_key" "$branch" "$key" "$mapped_severity" \
				"issue" "$rule" "$message" "$path" "$line" "$component" "$status" \
				"$created" "$updated"

			((total_collected++))
		done <<<"$issues"

		# Check if there are more pages
		local total
		total=$(echo "$response" | jq -r '.total // 0')
		if [[ $((page * page_size)) -ge $total ]]; then
			break
		fi

		((page++))
	done

	log_success "Collected $total_collected issues"
	return 0
}

collect_hotspots() {
	local project_key="$1"
	local branch="${2:-}"
	local page=1
	local page_size=500
	local total_collected=0

	log_info "Collecting security hotspots for project: $project_key"

	while true; do
		local params="projectKey=${project_key}&p=${page}&ps=${page_size}&status=TO_REVIEW"
		if [[ -n "$branch" ]]; then
			params="${params}&branch=${branch}"
		fi

		local response
		response=$(call_sonar_api "/hotspots/search?${params}") || {
			log_error "Failed to fetch hotspots from SonarCloud API"
			return 1
		}

		# Check if response is valid JSON
		if ! echo "$response" | jq empty 2>/dev/null; then
			log_error "Invalid JSON response from SonarCloud API"
			return 1
		fi

		# Extract hotspots
		local hotspots
		hotspots=$(echo "$response" | jq -c '.hotspots[]?' 2>/dev/null || echo "")

		if [[ -z "$hotspots" ]]; then
			break
		fi

		# Process each hotspot
		while IFS= read -r hotspot; do
			[[ -z "$hotspot" ]] && continue

			local key severity rule message component line status created updated
			key=$(echo "$hotspot" | jq -r '.key // ""')
			severity=$(echo "$hotspot" | jq -r '.vulnerabilityProbability // "LOW"')
			rule=$(echo "$hotspot" | jq -r '.ruleKey // ""')
			message=$(echo "$hotspot" | jq -r '.message // ""')
			component=$(echo "$hotspot" | jq -r '.component // ""')
			line=$(echo "$hotspot" | jq -r '.line // "null"')
			status=$(echo "$hotspot" | jq -r '.status // ""')
			created=$(echo "$hotspot" | jq -r '.creationDate // ""')
			updated=$(echo "$hotspot" | jq -r '.updateDate // ""')

			# Extract file path from component
			local path
			path=$(echo "$component" | sed "s|^${project_key}:||")

			# Map hotspot severity (HIGH/MEDIUM/LOW) to our scale
			local mapped_severity
			case "$severity" in
			HIGH)
				mapped_severity="high"
				;;
			MEDIUM)
				mapped_severity="medium"
				;;
			LOW)
				mapped_severity="low"
				;;
			*)
				mapped_severity="info"
				;;
			esac

			# Store in database
			store_finding "sonarcloud" "$project_key" "$branch" "$key" "$mapped_severity" \
				"security_hotspot" "$rule" "$message" "$path" "$line" "$component" "$status" \
				"$created" "$updated"

			((total_collected++))
		done <<<"$hotspots"

		# Check if there are more pages
		local paging
		paging=$(echo "$response" | jq -r '.paging // {}')
		local total
		total=$(echo "$paging" | jq -r '.total // 0')
		if [[ $((page * page_size)) -ge $total ]]; then
			break
		fi

		((page++))
	done

	log_success "Collected $total_collected security hotspots"
	return 0
}

store_finding() {
	local source="$1"
	local repo="$2"
	local branch="$3"
	local finding_key="$4"
	local severity="$5"
	local category="$6"
	local rule="$7"
	local message="$8"
	local path="$9"
	local line="${10}"
	local component="${11}"
	local status="${12}"
	local created="${13}"
	local updated="${14}"

	# Escape single quotes for SQL
	message=$(echo "$message" | sed "s/'/''/g")
	path=$(echo "$path" | sed "s/'/''/g")
	component=$(echo "$component" | sed "s/'/''/g")

	db "$COLLECTOR_DB" <<SQL >/dev/null
INSERT OR REPLACE INTO audit_findings (
    source, repo, branch, project_key, finding_key, severity, category, rule,
    message, path, line, component, status, created_at, updated_at
) VALUES (
    '$source', '$repo', '$branch', '$repo', '$finding_key', '$severity', '$category', '$rule',
    '$message', '$path', $line, '$component', '$status', '$created', '$updated'
);
SQL

	return 0
}

# =============================================================================
# Command Handlers
# =============================================================================

cmd_collect() {
	local project_key=""
	local branch=""
	local repo

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--project)
			project_key="$2"
			shift 2
			;;
		--branch)
			branch="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	ensure_db

	# Get repo from git if not provided
	if [[ -z "$project_key" ]]; then
		repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
			log_error "Not in a GitHub repository or gh CLI not configured"
			return 1
		}
		project_key=$(get_project_key "$repo")
	else
		repo="$project_key"
	fi

	log_info "Starting collection for project: $project_key"

	# Create collection run
	local run_id
	run_id=$(
		db "$COLLECTOR_DB" <<SQL
INSERT INTO collection_runs (source, repo, project_key, branch)
VALUES ('sonarcloud', '$repo', '$project_key', '$branch');
SELECT last_insert_rowid();
SQL
	)

	# Collect issues and hotspots
	local total_findings=0

	if collect_issues "$project_key" "$branch"; then
		local issue_count
		issue_count=$(db "$COLLECTOR_DB" "SELECT COUNT(*) FROM audit_findings WHERE source='sonarcloud' AND category='issue' AND project_key='$project_key';")
		total_findings=$((total_findings + issue_count))
	fi

	if collect_hotspots "$project_key" "$branch"; then
		local hotspot_count
		hotspot_count=$(db "$COLLECTOR_DB" "SELECT COUNT(*) FROM audit_findings WHERE source='sonarcloud' AND category='security_hotspot' AND project_key='$project_key';")
		total_findings=$((total_findings + hotspot_count))
	fi

	# Update run status
	db "$COLLECTOR_DB" <<SQL >/dev/null
UPDATE collection_runs
SET finding_count = $total_findings
WHERE id = $run_id;
SQL

	log_success "Collection complete. Total findings: $total_findings"
	return 0
}

cmd_query() {
	local severity=""
	local format="text"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--severity)
			severity="$2"
			shift 2
			;;
		--format)
			format="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	ensure_db

	local where_clause=""
	if [[ -n "$severity" ]]; then
		where_clause="WHERE severity='$severity'"
	fi

	if [[ "$format" == "json" ]]; then
		db "$COLLECTOR_DB" <<SQL
SELECT json_group_array(
    json_object(
        'id', id,
        'severity', severity,
        'category', category,
        'rule', rule,
        'message', message,
        'path', path,
        'line', line,
        'status', status
    )
)
FROM audit_findings
WHERE source='sonarcloud' $where_clause;
SQL
	else
		db "$COLLECTOR_DB" <<SQL
SELECT severity, category, path, line, message
FROM audit_findings
WHERE source='sonarcloud' $where_clause
ORDER BY severity, path, line;
SQL
	fi

	return 0
}

cmd_summary() {
	local last_n=1

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--last)
			last_n="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	ensure_db

	log_info "SonarCloud Collection Summary (last $last_n runs)"

	db "$COLLECTOR_DB" <<SQL
SELECT
    collected_at,
    project_key,
    finding_count,
    status
FROM collection_runs
WHERE source='sonarcloud'
ORDER BY collected_at DESC
LIMIT $last_n;
SQL

	echo ""
	log_info "Findings by Severity:"

	db "$COLLECTOR_DB" <<SQL
SELECT
    severity,
    COUNT(*) as count
FROM audit_findings
WHERE source='sonarcloud'
GROUP BY severity
ORDER BY
    CASE severity
        WHEN 'critical' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        WHEN 'low' THEN 4
        WHEN 'info' THEN 5
    END;
SQL

	return 0
}

cmd_status() {
	ensure_db

	local total_findings
	total_findings=$(db "$COLLECTOR_DB" "SELECT COUNT(*) FROM audit_findings WHERE source='sonarcloud';")

	local last_run
	last_run=$(db "$COLLECTOR_DB" "SELECT collected_at FROM collection_runs WHERE source='sonarcloud' ORDER BY collected_at DESC LIMIT 1;")

	log_info "Total findings: $total_findings"
	log_info "Last collection: ${last_run:-never}"

	return 0
}

cmd_export() {
	local format="json"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format)
			format="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	ensure_db

	if [[ "$format" == "csv" ]]; then
		db "$COLLECTOR_DB" <<SQL
.mode csv
.headers on
SELECT * FROM audit_findings WHERE source='sonarcloud';
SQL
	else
		db "$COLLECTOR_DB" <<SQL
SELECT json_group_array(
    json_object(
        'id', id,
        'source', source,
        'repo', repo,
        'severity', severity,
        'category', category,
        'rule', rule,
        'message', message,
        'path', path,
        'line', line,
        'status', status,
        'collected_at', collected_at
    )
)
FROM audit_findings
WHERE source='sonarcloud';
SQL
	fi

	return 0
}

cmd_help() {
	cat <<'EOF'
SonarCloud Collector Helper - Code Quality Issues into SQLite

Usage:
  sonarcloud-collector-helper.sh collect [--project KEY] [--branch NAME]
  sonarcloud-collector-helper.sh query [--severity LEVEL] [--format json|text]
  sonarcloud-collector-helper.sh summary [--last N]
  sonarcloud-collector-helper.sh status
  sonarcloud-collector-helper.sh export [--format json|csv]
  sonarcloud-collector-helper.sh help

Commands:
  collect     Collect issues and security hotspots from SonarCloud
  query       Query stored findings
  summary     Show collection summary
  status      Show collector status
  export      Export findings to JSON or CSV
  help        Show this help message

Options:
  --project KEY       SonarCloud project key (default: auto-detect from repo)
  --branch NAME       Branch name to filter findings
  --severity LEVEL    Filter by severity (critical/high/medium/low/info)
  --format FORMAT     Output format (json/text/csv)
  --last N            Show last N collection runs

Environment:
  SONAR_TOKEN         SonarCloud API token (required)
                      Set via: aidevops secret set SONAR_TOKEN

Examples:
  # Collect findings for current repo
  sonarcloud-collector-helper.sh collect

  # Collect for specific project and branch
  sonarcloud-collector-helper.sh collect --project my_org_my_repo --branch main

  # Query critical findings
  sonarcloud-collector-helper.sh query --severity critical --format json

  # Show summary of last 5 runs
  sonarcloud-collector-helper.sh summary --last 5

  # Export all findings to CSV
  sonarcloud-collector-helper.sh export --format csv

EOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	if [[ $# -eq 0 ]]; then
		cmd_help
		return 0
	fi

	local command="$1"
	shift

	case "$command" in
	collect)
		cmd_collect "$@"
		;;
	query)
		cmd_query "$@"
		;;
	summary)
		cmd_summary "$@"
		;;
	status)
		cmd_status "$@"
		;;
	export)
		cmd_export "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
