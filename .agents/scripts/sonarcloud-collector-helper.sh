#!/usr/bin/env bash
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

# Logging: uses shared log_* from shared-constants.sh with SONARCLOUD prefix
# shellcheck disable=SC2034  # Used by shared-constants.sh log_* functions
LOG_PREFIX="SONARCLOUD"

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
	# Database schema is managed by code-audit-helper.sh (t1032.1)
	# This function is a no-op since the schema already exists
	log_info "Using existing audit database: $COLLECTOR_DB"
	return 0
}

# =============================================================================
# Severity Mapping
# =============================================================================

map_severity() {
	local sonar_severity
	sonar_severity="$1"

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
	return 0
}

get_project_key() {
	local repo
	repo="$1"
	# SonarCloud project key is typically org_repo format
	# Example: marcusquinn_aidevops
	echo "$repo" | tr '/' '_'
	return 0
}

call_sonar_api() {
	local endpoint
	endpoint="$1"
	shift
	local token
	token=$(get_sonar_token) || return 1

	local url
	url="${SONARCLOUD_API_BASE}${endpoint}"

	curl -s -u "${token}:" "$url" "$@"
	return $?
}

# =============================================================================
# Collection Functions
# =============================================================================

collect_issues() {
	local run_id
	run_id="$1"
	local project_key
	project_key="$2"
	local branch
	branch="${3:-}"
	local page
	page=1
	local page_size
	page_size=500
	local total_collected
	total_collected=0

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

			local severity rule message component line
			severity=$(echo "$issue" | jq -r '.severity // "INFO"')
			rule=$(echo "$issue" | jq -r '.rule // ""')
			message=$(echo "$issue" | jq -r '.message // ""')
			component=$(echo "$issue" | jq -r '.component // ""')
			line=$(echo "$issue" | jq -r '.line // 0')

			# Extract file path from component (remove project key prefix)
			local path
			path=$(echo "$component" | sed "s|^${project_key}:||")

			# Map severity
			local mapped_severity
			mapped_severity=$(map_severity "$severity")

			# Store in database (run_id, severity, category, rule_id, description, path, line)
			store_finding "$run_id" "$mapped_severity" "issue" "$rule" "$message" "$path" "$line"

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
	local run_id
	run_id="$1"
	local project_key
	project_key="$2"
	local branch
	branch="${3:-}"
	local page
	page=1
	local page_size
	page_size=500
	local total_collected
	total_collected=0

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

			local severity rule message component line
			severity=$(echo "$hotspot" | jq -r '.vulnerabilityProbability // "LOW"')
			rule=$(echo "$hotspot" | jq -r '.ruleKey // ""')
			message=$(echo "$hotspot" | jq -r '.message // ""')
			component=$(echo "$hotspot" | jq -r '.component // ""')
			line=$(echo "$hotspot" | jq -r '.line // 0')

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

			# Store in database (run_id, severity, category, rule_id, description, path, line)
			store_finding "$run_id" "$mapped_severity" "security_hotspot" "$rule" "$message" "$path" "$line"

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
	local run_id
	run_id="$1"
	local severity
	severity="$2"
	local category
	category="$3"
	local rule_id
	rule_id="$4"
	local description
	description="$5"
	local path
	path="$6"
	local line
	line="$7"

	# Create dedup key from path:line:rule
	local dedup_key
	dedup_key="${path}:${line}:${rule_id}"

	# Use parameterized query to prevent SQL injection
	db "$COLLECTOR_DB" \
		"INSERT INTO audit_findings (run_id, source, severity, path, line, description, category, rule_id, dedup_key) VALUES (?, 'sonarcloud', ?, ?, ?, ?, ?, ?, ?);" \
		"$run_id" "$severity" "$path" "$line" "$description" "$category" "$rule_id" "$dedup_key" >/dev/null

	return 0
}

# =============================================================================
# Command Handlers
# =============================================================================

cmd_collect() {
	local project_key
	project_key=""
	local branch
	branch=""
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

	# Create audit run (using existing schema from t1032.1)
	local run_id
	run_id=$(
		db "$COLLECTOR_DB" <<SQL
INSERT INTO audit_runs (repo, pr_number, head_sha, services_run, status)
VALUES ('$repo', 0, '', 'sonarcloud', 'running');
SELECT last_insert_rowid();
SQL
	)

	# Collect issues and hotspots
	local total_findings=0

	if collect_issues "$run_id" "$project_key" "$branch"; then
		local issue_count
		issue_count=$(db "$COLLECTOR_DB" "SELECT COUNT(*) FROM audit_findings WHERE run_id=$run_id AND category='issue';")
		total_findings=$((total_findings + issue_count))
	fi

	if collect_hotspots "$run_id" "$project_key" "$branch"; then
		local hotspot_count
		hotspot_count=$(db "$COLLECTOR_DB" "SELECT COUNT(*) FROM audit_findings WHERE run_id=$run_id AND category='security_hotspot';")
		total_findings=$((total_findings + hotspot_count))
	fi

	# Update run status
	db "$COLLECTOR_DB" <<SQL >/dev/null
UPDATE audit_runs
SET status = 'complete',
    completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
WHERE id = $run_id;
SQL

	log_success "Collection complete. Total findings: $total_findings"
	return 0
}

cmd_query() {
	local severity
	severity=""
	local format
	format="text"

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
        'rule_id', rule_id,
        'description', description,
        'path', path,
        'line', line
    )
)
FROM audit_findings
WHERE source='sonarcloud' $where_clause;
SQL
	else
		db "$COLLECTOR_DB" <<SQL
SELECT severity, category, path, line, description
FROM audit_findings
WHERE source='sonarcloud' $where_clause
ORDER BY severity, path, line;
SQL
	fi

	return 0
}

cmd_summary() {
	local last_n
	last_n=1

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
    r.started_at,
    r.repo,
    COUNT(f.id) as finding_count,
    r.status
FROM audit_runs r
LEFT JOIN audit_findings f ON f.run_id = r.id AND f.source = 'sonarcloud'
WHERE r.services_run LIKE '%sonarcloud%'
GROUP BY r.id
ORDER BY r.started_at DESC
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
	last_run=$(db "$COLLECTOR_DB" "SELECT started_at FROM audit_runs WHERE services_run LIKE '%sonarcloud%' ORDER BY started_at DESC LIMIT 1;")

	log_info "Total findings: $total_findings"
	log_info "Last collection: ${last_run:-never}"

	return 0
}

cmd_export() {
	local format
	format="json"

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
        'run_id', run_id,
        'source', source,
        'severity', severity,
        'category', category,
        'rule_id', rule_id,
        'description', description,
        'path', path,
        'line', line,
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
