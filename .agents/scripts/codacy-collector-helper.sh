#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# =============================================================================
# Codacy Collector Helper - Poll Codacy API for Findings into SQLite (t1032.2)
# =============================================================================
# Polls the Codacy API for repository issues, classifies severity, and stores
# findings in the shared audit_findings SQLite table. Handles pagination,
# rate limits, and API errors gracefully.
#
# Usage:
#   codacy-collector-helper.sh collect [--repo OWNER/REPO] [--account NAME]
#   codacy-collector-helper.sh query [--severity LEVEL] [--category CAT] [--format json|text]
#   codacy-collector-helper.sh summary
#   codacy-collector-helper.sh status
#   codacy-collector-helper.sh export [--format json|csv]
#   codacy-collector-helper.sh help
#
# Subtask: t1032.2 - Codacy collector for unified audit pipeline
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
readonly CODACY_BASE_URL="https://app.codacy.com/api/v3"
readonly CODACY_PAGE_SIZE=100
readonly CODACY_MAX_PAGES=50
readonly CODACY_RATE_LIMIT_WAIT=60
readonly CODACY_RETRY_BACKOFF_BASE=2
# Config file paths (working config preferred, template as fallback)
readonly AUDIT_CONFIG="configs/code-audit-config.json"
readonly AUDIT_CONFIG_TEMPLATE="configs/code-audit-config.json.txt"

# =============================================================================
# Logging
# =============================================================================

log_info() {
	echo -e "${BLUE}[CODACY]${NC} $*" >&2
	return 0
}
log_success() {
	echo -e "${GREEN}[CODACY]${NC} $*" >&2
	return 0
}
log_warn() {
	echo -e "${YELLOW}[CODACY]${NC} $*" >&2
	return 0
}
log_error() {
	echo -e "${RED}[CODACY]${NC} $*" >&2
	return 0
}

# =============================================================================
# SQLite wrapper: sets busy_timeout on every connection (t135.3 pattern)
# =============================================================================

db() {
	sqlite3 -cmd ".timeout 5000" "$@"
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

# Load Codacy credentials from config file or environment variables.
# Priority: env vars > working config > template config
# Sets: CODACY_TOKEN, CODACY_PROVIDER, CODACY_REPOS
load_codacy_config() {
	local account="${1:-personal}"

	# Environment variables take priority
	if [[ -n "${CODACY_API_TOKEN:-}" ]]; then
		CODACY_TOKEN="$CODACY_API_TOKEN"
	elif [[ -n "${CODACY_PROJECT_TOKEN:-}" ]]; then
		CODACY_TOKEN="$CODACY_PROJECT_TOKEN"
	fi

	# Try config files for additional settings
	local config_file=""
	if [[ -f "$AUDIT_CONFIG" ]]; then
		config_file="$AUDIT_CONFIG"
	elif [[ -f "$AUDIT_CONFIG_TEMPLATE" ]]; then
		config_file="$AUDIT_CONFIG_TEMPLATE"
	fi

	if [[ -n "$config_file" ]] && command -v jq &>/dev/null; then
		# Load token from config if not already set via env
		if [[ -z "${CODACY_TOKEN:-}" ]]; then
			CODACY_TOKEN=$(jq -r ".services.codacy.accounts.${account}.api_token // empty" "$config_file" 2>/dev/null || echo "")
		fi

		# Load organization/username for API path
		local org username
		org=$(jq -r ".services.codacy.accounts.${account}.organization // empty" "$config_file" 2>/dev/null || echo "")
		username=$(jq -r ".services.codacy.accounts.${account}.username // empty" "$config_file" 2>/dev/null || echo "")
		CODACY_PROVIDER="${org:-$username}"

		# Load configured repositories (available for multi-repo collection)
		export CODACY_REPOS
		CODACY_REPOS=$(jq -r ".services.codacy.accounts.${account}.repositories // [] | .[]" "$config_file" 2>/dev/null || echo "")
	fi

	# Validate token
	if [[ -z "${CODACY_TOKEN:-}" || "$CODACY_TOKEN" == "YOUR_"* ]]; then
		log_error "Codacy API token not configured"
		log_info "Set CODACY_API_TOKEN env var or configure in $AUDIT_CONFIG"
		return 1
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
# API Request with Rate Limit and Retry Handling
# =============================================================================

# Make a Codacy API request with retry logic and rate limit handling.
# Arguments:
#   $1 - API endpoint path (after base URL)
#   $2 - HTTP method (GET or POST, default: POST)
#   $3 - Request body (optional, for POST)
# Output: API response JSON on stdout
# Returns: 0 on success, 1 on failure after retries
codacy_api_request() {
	local endpoint="$1"
	local method="${2:-POST}"
	local body="${3:-}"
	local attempt=0
	local response=""
	local http_code=""

	while [[ $attempt -lt $MAX_RETRIES ]]; do
		attempt=$((attempt + 1))

		local tmp_response tmp_headers
		tmp_response=$(mktemp)
		tmp_headers=$(mktemp)

		local curl_args=(
			-s
			-w "%{http_code}"
			-o "$tmp_response"
			-D "$tmp_headers"
			-H "api-token: ${CODACY_TOKEN}"
			-H "Accept: application/json"
		)

		if [[ "$method" == "POST" ]]; then
			curl_args+=(-X POST -H "Content-Type: application/json")
			if [[ -n "$body" ]]; then
				curl_args+=(-d "$body")
			fi
		fi

		http_code=$(curl "${curl_args[@]}" "${CODACY_BASE_URL}${endpoint}" 2>/dev/null) || {
			rm -f "$tmp_response" "$tmp_headers"
			local wait_time=$((CODACY_RETRY_BACKOFF_BASE ** attempt))
			log_warn "API request failed (attempt ${attempt}/${MAX_RETRIES}), retrying in ${wait_time}s..."
			sleep "$wait_time"
			continue
		}

		response=$(cat "$tmp_response" 2>/dev/null || echo "")
		rm -f "$tmp_response" "$tmp_headers"

		case "$http_code" in
		200)
			echo "$response"
			return 0
			;;
		429)
			# Rate limited — extract retry-after or use default wait
			local retry_after="$CODACY_RATE_LIMIT_WAIT"
			log_warn "Rate limited (429). Waiting ${retry_after}s before retry (attempt ${attempt}/${MAX_RETRIES})..."
			sleep "$retry_after"
			continue
			;;
		401)
			log_error "Authentication failed (401). Check CODACY_API_TOKEN."
			return 1
			;;
		403)
			log_error "Access forbidden (403). Check API token permissions."
			return 1
			;;
		404)
			log_error "Resource not found (404): ${endpoint}"
			return 1
			;;
		500 | 502 | 503 | 504)
			local wait_time=$((CODACY_RETRY_BACKOFF_BASE ** attempt))
			log_warn "Server error (${http_code}), retrying in ${wait_time}s (attempt ${attempt}/${MAX_RETRIES})..."
			sleep "$wait_time"
			continue
			;;
		*)
			log_warn "Unexpected HTTP ${http_code} (attempt ${attempt}/${MAX_RETRIES})"
			local wait_time=$((CODACY_RETRY_BACKOFF_BASE ** attempt))
			sleep "$wait_time"
			continue
			;;
		esac
	done

	log_error "API request failed after ${MAX_RETRIES} attempts: ${endpoint}"
	return 1
}

# =============================================================================
# Core: Collect Findings with Pagination
# =============================================================================

cmd_collect() {
	local repo=""
	local account="personal"

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
		--account)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --account"
				return 1
			}
			account="$2"
			shift 2
			;;
		*)
			log_warn "Unknown option: $1"
			shift
			;;
		esac
	done

	# Load credentials
	load_codacy_config "$account" || return 1

	# Auto-detect repo if not specified
	if [[ -z "$repo" ]]; then
		repo=$(get_repo)
	fi

	if ! command -v jq &>/dev/null; then
		log_error "jq is required but not installed"
		return 1
	fi

	ensure_db

	local head_sha
	head_sha=$(get_head_sha)

	# Derive org and repo name from OWNER/REPO format
	local org repo_name
	org="${CODACY_PROVIDER:-}"
	if [[ -z "$org" ]]; then
		org=$(echo "$repo" | cut -d'/' -f1)
	fi
	repo_name=$(echo "$repo" | cut -d'/' -f2)

	log_info "Collecting Codacy findings for ${org}/${repo_name}..."

	# Create audit run
	local run_id
	run_id=$(db "$AUDIT_DB" "
		INSERT INTO audit_runs (repo, head_sha, services_run)
		VALUES ('$(sql_escape "$repo")', '$(sql_escape "$head_sha")', 'codacy');
		SELECT last_insert_rowid();
	")

	log_info "Audit run #${run_id} started"

	# Paginated collection
	local total_collected=0
	local cursor=""
	local page=0
	local has_more=true

	while [[ "$has_more" == "true" && $page -lt $CODACY_MAX_PAGES ]]; do
		page=$((page + 1))

		# Build request body with cursor-based pagination
		local request_body
		if [[ -n "$cursor" ]]; then
			request_body="{\"limit\": ${CODACY_PAGE_SIZE}, \"cursor\": \"${cursor}\"}"
		else
			request_body="{\"limit\": ${CODACY_PAGE_SIZE}}"
		fi

		local endpoint="/analysis/organizations/gh/${org}/repositories/${repo_name}/issues/search"

		log_info "Fetching page ${page} (cursor: ${cursor:-start})..."

		local response
		response=$(codacy_api_request "$endpoint" "POST" "$request_body") || {
			log_warn "Failed to fetch page ${page} — stopping pagination"
			break
		}

		# Check if response has data
		local issue_count
		issue_count=$(echo "$response" | jq '.data | length' 2>/dev/null || echo "0")

		if [[ "$issue_count" -eq 0 ]]; then
			log_info "No more issues found on page ${page}"
			break
		fi

		# Parse and insert findings
		local page_count
		page_count=$(insert_findings "$run_id" "$response")
		total_collected=$((total_collected + page_count))

		log_info "Page ${page}: ${page_count} findings collected (total: ${total_collected})"

		# Check for next page cursor
		cursor=$(echo "$response" | jq -r '.pagination.cursor // empty' 2>/dev/null || echo "")
		if [[ -z "$cursor" ]]; then
			has_more=false
		fi
	done

	# Mark duplicates within this run
	deduplicate_findings "$run_id"

	# Update audit run as completed
	db "$AUDIT_DB" "
		UPDATE audit_runs
		SET completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
		    status = 'complete'
		WHERE id = $run_id;
	"

	local unique_count
	unique_count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE run_id = $run_id AND is_duplicate = 0;")

	log_success "Collection complete: ${total_collected} total, ${unique_count} unique findings (run #${run_id})"
	log_info "Database: $AUDIT_DB"

	return 0
}

# =============================================================================
# Insert Findings from API Response
# =============================================================================

# Parse a Codacy API response page and insert findings into audit_findings.
# Uses jq for safe SQL generation (avoids shell expansion of special chars).
# Arguments:
#   $1 - run_id
#   $2 - API response JSON
# Output: count of inserted findings
insert_findings() {
	local run_id="$1"
	local response="$2"

	local sql_file jq_filter_file
	sql_file=$(mktemp)
	jq_filter_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${sql_file}'"
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
    elif . == "BestPractice" then "general"
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

	local count=0
	if [[ -s "$sql_file" ]]; then
		db "$AUDIT_DB" <"$sql_file" 2>/dev/null || log_warn "Some Codacy inserts may have failed"
		count=$(wc -l <"$sql_file" | tr -d ' ')
	fi

	echo "$count"
	return 0
}

# =============================================================================
# Deduplication
# =============================================================================

deduplicate_findings() {
	local run_id="$1"

	log_info "Deduplicating findings..."

	db "$AUDIT_DB" "
		UPDATE audit_findings
		SET is_duplicate = 1
		WHERE run_id = $run_id
		  AND source = 'codacy'
		  AND dedup_key != ''
		  AND dedup_key != ':0'
		  AND id NOT IN (
		      SELECT MIN(id)
		      FROM audit_findings
		      WHERE run_id = $run_id
		        AND source = 'codacy'
		        AND dedup_key != ''
		        AND dedup_key != ':0'
		      GROUP BY dedup_key
		  );
	" 2>/dev/null || log_warn "Deduplication query may have partially failed"

	local dup_count
	dup_count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE run_id = $run_id AND is_duplicate = 1;")
	if [[ "${dup_count:-0}" -gt 0 ]]; then
		log_info "Marked ${dup_count} duplicate(s)"
	fi

	return 0
}

# =============================================================================
# Query Command
# =============================================================================

cmd_query() {
	local severity=""
	local category=""
	local format="text"
	local limit=50

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--severity)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --severity"
				return 1
			}
			severity="$2"
			shift 2
			;;
		--category)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --category"
				return 1
			}
			category="$2"
			shift 2
			;;
		--format)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --format"
				return 1
			}
			format="$2"
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

	ensure_db

	# Build WHERE clause
	local where="WHERE source = 'codacy' AND is_duplicate = 0"
	if [[ -n "$severity" ]]; then
		where="${where} AND severity = '$(sql_escape "$severity")'"
	fi
	if [[ -n "$category" ]]; then
		where="${where} AND category = '$(sql_escape "$category")'"
	fi

	if [[ "$format" == "json" ]]; then
		db "$AUDIT_DB" -json "
			SELECT id, severity, path, line, description, category, rule_id, collected_at
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
	else
		echo ""
		echo "Codacy Findings"
		echo "==============="
		if [[ -n "$severity" ]]; then
			echo "Severity: ${severity}"
		fi
		if [[ -n "$category" ]]; then
			echo "Category: ${category}"
		fi
		echo ""

		db "$AUDIT_DB" -separator $'\x1f' "
			SELECT severity, path, line,
			       substr(replace(replace(description, char(10), ' '), char(13), ''), 1, 120),
			       rule_id
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
		" | while IFS=$'\x1f' read -r sev path line desc rule; do
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

			printf "  ${color}[%-8s]${NC} %s" "$sev" "$location"
			if [[ -n "$rule" ]]; then
				printf " (%s)" "$rule"
			fi
			echo ""
			echo "    ${desc}"
			echo ""
		done

		local total
		total=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings $where;")
		echo "Total: ${total} finding(s)"
	fi

	return 0
}

# =============================================================================
# Summary Command
# =============================================================================

cmd_summary() {
	ensure_db

	echo ""
	echo "Codacy Findings Summary"
	echo "======================="
	echo ""

	# Latest run info
	local run_info
	run_info=$(db "$AUDIT_DB" -separator '|' "
		SELECT id, repo, head_sha, started_at, completed_at, status
		FROM audit_runs
		WHERE services_run LIKE '%codacy%'
		ORDER BY id DESC LIMIT 1;
	" 2>/dev/null || echo "")

	if [[ -n "$run_info" ]]; then
		local run_id repo sha started completed status
		IFS='|' read -r run_id repo sha started completed status <<<"$run_info"
		echo "  Latest Run:  #${run_id} (${status})"
		echo "  Repository:  $repo"
		echo "  SHA:         $sha"
		echo "  Started:     $started"
		echo "  Completed:   $completed"
		echo ""
	else
		echo "  No Codacy collection runs found."
		echo "  Run: codacy-collector-helper.sh collect"
		echo ""
		return 0
	fi

	# Severity breakdown
	echo "  Severity Breakdown:"
	db "$AUDIT_DB" -separator '|' "
		SELECT severity, COUNT(*) as cnt
		FROM audit_findings
		WHERE source = 'codacy' AND is_duplicate = 0
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
	echo "  Category Breakdown:"
	db "$AUDIT_DB" -separator '|' "
		SELECT category, COUNT(*) as cnt
		FROM audit_findings
		WHERE source = 'codacy' AND is_duplicate = 0
		GROUP BY category
		ORDER BY cnt DESC;
	" | while IFS='|' read -r cat cnt; do
		printf "    %-15s %s\n" "$cat" "$cnt"
	done

	echo ""
	echo "  Most Affected Files (top 10):"
	db "$AUDIT_DB" -separator '|' "
		SELECT path, COUNT(*) as cnt,
		       GROUP_CONCAT(DISTINCT severity) as severities
		FROM audit_findings
		WHERE source = 'codacy' AND is_duplicate = 0 AND path != ''
		GROUP BY path
		ORDER BY cnt DESC
		LIMIT 10;
	" | while IFS='|' read -r path cnt severities; do
		printf "    %-45s %3s (%s)\n" "$path" "$cnt" "$severities"
	done

	echo ""

	# Total stats
	local total unique dups
	total=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE source = 'codacy';")
	unique=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE source = 'codacy' AND is_duplicate = 0;")
	dups=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE source = 'codacy' AND is_duplicate = 1;")
	echo "  Total findings:    $total"
	echo "  Unique findings:   $unique"
	echo "  Duplicates:        $dups"
	echo ""

	return 0
}

# =============================================================================
# Status Command
# =============================================================================

cmd_status() {
	ensure_db

	echo ""
	echo "Codacy Collector Status"
	echo "======================="
	echo ""

	# Check dependencies
	if command -v curl &>/dev/null; then
		log_success "curl: installed"
	else
		log_error "curl: not installed (required)"
	fi

	if command -v jq &>/dev/null; then
		log_success "jq: installed"
	else
		log_error "jq: not installed (required)"
	fi

	if command -v sqlite3 &>/dev/null; then
		log_success "sqlite3: installed"
	else
		log_error "sqlite3: not installed (required)"
	fi

	echo ""

	# Token status
	if [[ -n "${CODACY_API_TOKEN:-}${CODACY_PROJECT_TOKEN:-}" ]]; then
		log_success "Codacy token: set via environment"
	elif [[ -f "$AUDIT_CONFIG" ]]; then
		local token
		token=$(jq -r '.services.codacy.accounts.personal.api_token // empty' "$AUDIT_CONFIG" 2>/dev/null || echo "")
		if [[ -n "$token" && "$token" != "YOUR_"* ]]; then
			log_success "Codacy token: configured in $AUDIT_CONFIG"
		else
			log_warn "Codacy token: placeholder in $AUDIT_CONFIG"
		fi
	elif [[ -f "$AUDIT_CONFIG_TEMPLATE" ]]; then
		log_warn "Codacy token: not configured (using template)"
		log_info "  Copy $AUDIT_CONFIG_TEMPLATE to $AUDIT_CONFIG and add your token"
	else
		log_warn "Codacy token: not configured"
	fi

	echo ""

	# Database stats
	if [[ -f "$AUDIT_DB" ]]; then
		local run_count finding_count
		run_count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_runs WHERE services_run LIKE '%codacy%';" 2>/dev/null || echo "0")
		finding_count=$(db "$AUDIT_DB" "SELECT COUNT(*) FROM audit_findings WHERE source = 'codacy';" 2>/dev/null || echo "0")

		echo "Database: $AUDIT_DB"
		echo "  Codacy runs:     $run_count"
		echo "  Codacy findings: $finding_count"

		local last_run
		last_run=$(db "$AUDIT_DB" "
			SELECT completed_at || ' (Run #' || id || ')'
			FROM audit_runs
			WHERE services_run LIKE '%codacy%'
			ORDER BY id DESC LIMIT 1;
		" 2>/dev/null || echo "never")
		echo "  Last collection: $last_run"

		local db_size
		if [[ "$(uname)" == "Darwin" ]]; then
			db_size=$(stat -f %z "$AUDIT_DB" 2>/dev/null || echo "0")
		else
			db_size=$(stat -c %s "$AUDIT_DB" 2>/dev/null || echo "0")
		fi
		echo "  DB size:         $((db_size / 1024)) KB"
	else
		echo "Database: not created yet"
		echo "  Run 'codacy-collector-helper.sh collect' to start"
	fi

	echo ""
	return 0
}

# =============================================================================
# Export Command
# =============================================================================

cmd_export() {
	local format="json"

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
		*)
			log_warn "Unknown option: $1"
			shift
			;;
		esac
	done

	ensure_db

	case "$format" in
	json)
		db "$AUDIT_DB" -json "
			SELECT af.id, af.severity, af.path, af.line, af.description,
			       af.category, af.rule_id, af.dedup_key, af.is_duplicate,
			       af.collected_at, ar.repo, ar.head_sha
			FROM audit_findings af
			LEFT JOIN audit_runs ar ON af.run_id = ar.id
			WHERE af.source = 'codacy'
			ORDER BY af.run_id DESC, af.severity, af.path, af.line;
		"
		;;
	csv)
		echo "id,severity,path,line,description,category,rule_id,is_duplicate,collected_at"
		db "$AUDIT_DB" -csv "
			SELECT id, severity, path, line,
			       substr(replace(description, char(10), ' '), 1, 200),
			       category, rule_id, is_duplicate, collected_at
			FROM audit_findings
			WHERE source = 'codacy'
			ORDER BY run_id DESC, severity, path, line;
		"
		;;
	*)
		log_error "Unknown format: $format (use json or csv)"
		return 1
		;;
	esac

	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	cat <<'HELP_EOF'
Codacy Collector Helper - Poll Codacy API for Findings (t1032.2)

USAGE:
  codacy-collector-helper.sh <command> [options]

COMMANDS:
  collect     Poll Codacy API and store findings in audit_findings table
  query       Query stored Codacy findings with filters
  summary     Show severity/category breakdown and stats
  status      Show collector status, dependencies, and DB info
  export      Export Codacy findings as JSON or CSV
  help        Show this help

COLLECT OPTIONS:
  --repo OWNER/REPO   Repository (default: auto-detect from git)
  --account NAME      Config account name (default: personal)

QUERY OPTIONS:
  --severity LEVEL    Filter: critical, high, medium, low, info
  --category CAT      Filter: security, bug, performance, style, documentation,
                      refactoring, general
  --format FORMAT     Output: text (default), json
  --limit N           Max results (default: 50)

EXPORT OPTIONS:
  --format FORMAT     Output: json (default), csv

EXAMPLES:
  # Collect findings from current repo
  codacy-collector-helper.sh collect

  # Collect from specific repo
  codacy-collector-helper.sh collect --repo owner/repo

  # Query critical findings
  codacy-collector-helper.sh query --severity critical

  # Query security findings as JSON
  codacy-collector-helper.sh query --category security --format json

  # Show summary
  codacy-collector-helper.sh summary

  # Export all findings
  codacy-collector-helper.sh export --format csv > codacy-findings.csv

SEVERITY MAPPING (Codacy -> Unified):
  Error    -> critical
  Warning  -> high
  Info     -> medium
  (other)  -> info

CATEGORY MAPPING (Codacy -> Unified):
  Security      -> security
  ErrorProne    -> bug
  Performance   -> performance
  CodeStyle     -> style
  UnusedCode    -> style
  Complexity    -> refactoring
  Documentation -> documentation
  BestPractice  -> general
  Compatibility -> general

AUTHENTICATION:
  Set CODACY_API_TOKEN environment variable, or configure in:
    configs/code-audit-config.json (working config, gitignored)
    configs/code-audit-config.json.txt (template, committed)

API DETAILS:
  Endpoint: POST /analysis/organizations/gh/{org}/repositories/{repo}/issues/search
  Pagination: cursor-based, 100 items per page, max 50 pages
  Rate limits: automatic retry with 60s backoff on 429
  Retries: 3 attempts with exponential backoff on server errors

DATABASE:
  SQLite database at: ~/.aidevops/.agent-workspace/work/code-audit/audit.db
  Table: audit_findings (shared with all audit collectors)
  Source field: 'codacy'

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
	collect) cmd_collect "$@" ;;
	query) cmd_query "$@" ;;
	summary) cmd_summary "$@" ;;
	status) cmd_status "$@" ;;
	export) cmd_export "$@" ;;
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
