#!/usr/bin/env bash
# shellcheck disable=SC1091
# quality-sweep-helper.sh — Unified quality debt sweep: fetch, normalize, and store
# findings from code quality tools (SonarCloud, Codacy, CodeFactor, CodeRabbit).
#
# t245: Parent task — unified quality debt pipeline
# t245.1: SonarCloud API integration
# t245.2: Codacy API integration
# t245.3: Finding-to-task pipeline (finding-to-task-helper.sh)
# t245.4: Daily GitHub Action (future)
#
# Usage:
#   quality-sweep-helper.sh sonarcloud [fetch|query|summary|export|status] [options]
#   quality-sweep-helper.sh codacy [fetch|query|summary|export|status|dedup] [options]
#   quality-sweep-helper.sh help
#
# SonarCloud auth: SONAR_TOKEN env var, gopass, or ~/.config/aidevops/credentials.sh
# Codacy auth: CODACY_API_TOKEN env var, gopass, or ~/.config/aidevops/credentials.sh
# Public repos work without auth (rate-limited).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
init_log_file

# =============================================================================
# Constants
# =============================================================================

readonly SWEEP_DATA_DIR="${HOME}/.aidevops/.agent-workspace/work/quality-sweep"
readonly SWEEP_DB="${SWEEP_DATA_DIR}/findings.db"
readonly SONAR_API_URL="https://sonarcloud.io/api"
readonly SONAR_DEFAULT_PROJECT="marcusquinn_aidevops"
readonly SONAR_PAGE_SIZE=500

readonly CODACY_API_URL="https://app.codacy.com/api/v3"
readonly CODACY_DEFAULT_PROVIDER="gh"
readonly CODACY_DEFAULT_ORG="marcusquinn"
readonly CODACY_DEFAULT_REPO="aidevops"
readonly CODACY_PAGE_SIZE=100

# =============================================================================
# SQLite wrapper (matches coderabbit-collector pattern)
# =============================================================================

db() {
    sqlite3 -cmd ".timeout 5000" "$@"
    return $?
}

# =============================================================================
# Database initialization
# =============================================================================

init_db() {
    mkdir -p "$SWEEP_DATA_DIR" 2>/dev/null || true

    db "$SWEEP_DB" <<'SQL'
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS findings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source          TEXT NOT NULL,
    external_key    TEXT,
    file            TEXT NOT NULL DEFAULT '',
    line            INTEGER NOT NULL DEFAULT 0,
    end_line        INTEGER NOT NULL DEFAULT 0,
    severity        TEXT NOT NULL DEFAULT 'info',
    type            TEXT NOT NULL DEFAULT 'CODE_SMELL',
    rule            TEXT NOT NULL DEFAULT '',
    message         TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'OPEN',
    effort          TEXT NOT NULL DEFAULT '',
    tags            TEXT NOT NULL DEFAULT '',
    created_at      TEXT NOT NULL DEFAULT '',
    collected_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(source, external_key)
);

CREATE TABLE IF NOT EXISTS sweep_runs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source          TEXT NOT NULL,
    project_key     TEXT NOT NULL DEFAULT '',
    started_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    completed_at    TEXT,
    total_fetched   INTEGER NOT NULL DEFAULT 0,
    new_findings    INTEGER NOT NULL DEFAULT 0,
    updated_findings INTEGER NOT NULL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'running'
);

CREATE INDEX IF NOT EXISTS idx_findings_source ON findings(source);
CREATE INDEX IF NOT EXISTS idx_findings_severity ON findings(severity);
CREATE INDEX IF NOT EXISTS idx_findings_file ON findings(file);
CREATE INDEX IF NOT EXISTS idx_findings_rule ON findings(rule);
CREATE INDEX IF NOT EXISTS idx_findings_status ON findings(status);
CREATE INDEX IF NOT EXISTS idx_findings_source_key ON findings(source, external_key);
CREATE INDEX IF NOT EXISTS idx_sweep_runs_source ON sweep_runs(source);
SQL
    return 0
}

# =============================================================================
# Credential loading (3-tier: env -> gopass -> credentials.sh)
# =============================================================================

load_sonar_token() {
    # Tier 1: Environment variable
    if [[ -n "${SONAR_TOKEN:-}" ]]; then
        return 0
    fi

    # Tier 2: gopass encrypted store
    if command -v gopass &>/dev/null; then
        SONAR_TOKEN=$(gopass show "aidevops/sonarcloud-token" 2>/dev/null) || true
        if [[ -n "${SONAR_TOKEN:-}" ]]; then
            export SONAR_TOKEN
            return 0
        fi
    fi

    # Tier 3: Plaintext credentials file
    local creds_file="${HOME}/.config/aidevops/credentials.sh"
    if [[ -f "$creds_file" ]]; then
        # shellcheck source=/dev/null
        source "$creds_file"
        if [[ -n "${SONAR_TOKEN:-}" ]]; then
            return 0
        fi
    fi

    # No token found — will use unauthenticated access (public repos only)
    return 0
}

# =============================================================================
# SonarCloud API helpers
# =============================================================================

# Make an authenticated (or unauthenticated) API call to SonarCloud.
# Arguments:
#   $1 - API endpoint path (e.g., /issues/search)
#   $2 - Query parameters (URL-encoded)
# Output: JSON response on stdout
# Returns: 0 on success, 1 on failure
sonar_api_call() {
    local endpoint="$1"
    local params="${2:-}"
    local url="${SONAR_API_URL}${endpoint}"

    if [[ -n "$params" ]]; then
        url="${url}?${params}"
    fi

    local curl_args=(-s --fail-with-body --max-time "$DEFAULT_TIMEOUT")

    if [[ -n "${SONAR_TOKEN:-}" ]]; then
        curl_args+=(-u "${SONAR_TOKEN}:")
    fi

    local response
    local http_code
    local tmp_body
    tmp_body=$(mktemp)
    trap 'rm -f "${tmp_body:-}"' RETURN

    http_code=$(curl "${curl_args[@]}" -o "$tmp_body" -w '%{http_code}' "$url" 2>/dev/null) || {
        print_error "SonarCloud API request failed: ${endpoint}"
        return 1
    }

    if [[ "$http_code" -ge 400 ]]; then
        local error_msg
        error_msg=$(jq -r '.errors[0].msg // "Unknown error"' "$tmp_body" 2>/dev/null || echo "HTTP $http_code")
        print_error "SonarCloud API error ($http_code): $error_msg"
        return 1
    fi

    cat "$tmp_body"
    return 0
}

# Map SonarCloud severity/impact to normalized severity.
# SonarCloud uses "impacts" array with softwareQuality + severity.
# Fallback to legacy "severity" field.
# Arguments:
#   $1 - JSON issue object (via stdin or argument)
# This is handled in jq, not shell — see fetch_sonarcloud_issues().

# =============================================================================
# SonarCloud fetch with pagination
# =============================================================================

# Fetch all issues from SonarCloud API with pagination.
# Arguments (via flags):
#   --project KEY    Project key (default: SONAR_DEFAULT_PROJECT)
#   --statuses LIST  Comma-separated statuses (default: OPEN,CONFIRMED)
#   --types LIST     Comma-separated types (default: all)
#   --resolved BOOL  Include resolved issues (default: false)
# Output: Total issues fetched count on stdout
# Side effect: Inserts/updates findings in SQLite
fetch_sonarcloud_issues() {
    local project_key="${SONAR_DEFAULT_PROJECT}"
    local statuses="OPEN,CONFIRMED"
    local types=""
    local resolved="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) project_key="${2:-}"; shift 2 ;;
            --statuses) statuses="${2:-}"; shift 2 ;;
            --types) types="${2:-}"; shift 2 ;;
            --resolved) resolved="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    init_db

    # Create sweep run record
    local run_id
    run_id=$(db "$SWEEP_DB" "INSERT INTO sweep_runs (source, project_key) VALUES ('sonarcloud', '$(echo "$project_key" | sed "s/'/''/g")'); SELECT last_insert_rowid();")

    local page=1
    local total_fetched=0
    local new_count=0
    local updated_count=0
    local total_issues=0

    print_info "Fetching SonarCloud issues for project: $project_key"

    while true; do
        # Build query parameters
        local params="componentKeys=${project_key}&resolved=${resolved}&statuses=${statuses}&ps=${SONAR_PAGE_SIZE}&p=${page}"
        if [[ -n "$types" ]]; then
            params="${params}&types=${types}"
        fi

        local response
        response=$(sonar_api_call "/issues/search" "$params") || {
            print_error "Failed to fetch page $page"
            db "$SWEEP_DB" "UPDATE sweep_runs SET status='failed', completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=$run_id;"
            return 1
        }

        # Extract total on first page
        if [[ $page -eq 1 ]]; then
            total_issues=$(echo "$response" | jq -r '.total // 0')
            print_info "Total issues reported by SonarCloud: $total_issues"
        fi

        # Extract issues count on this page
        local page_count
        page_count=$(echo "$response" | jq '.issues | length')

        if [[ "$page_count" -eq 0 ]]; then
            break
        fi

        # Generate SQL inserts from JSON using jq
        # Normalize severity: SonarCloud "impacts" array -> our severity scale
        # impacts[].severity: HIGH -> high, MEDIUM -> medium, LOW -> low
        # Legacy severity field: BLOCKER/CRITICAL -> critical, MAJOR -> high,
        #   MINOR -> medium, INFO -> info
        _save_cleanup_scope
        trap '_run_cleanups' RETURN
        local sql_file
        sql_file=$(mktemp)
        push_cleanup "rm -f '${sql_file}'"

        echo "$response" | jq -r '
            def normalize_severity:
                if . == "BLOCKER" then "critical"
                elif . == "CRITICAL" then "critical"
                elif . == "HIGH" then "high"
                elif . == "MAJOR" then "high"
                elif . == "MEDIUM" then "medium"
                elif . == "MINOR" then "medium"
                elif . == "LOW" then "low"
                elif . == "INFO" then "info"
                else "info"
                end;

            def sql_escape: gsub("'"'"'"; "'"'"''"'"'");

            .issues[] |
            {
                key: .key,
                file: (.component // "" | split(":") | if length > 1 then .[1:] | join(":") else .[0] end),
                line: (.line // .textRange.startLine // 0),
                end_line: (.textRange.endLine // .line // 0),
                severity: (
                    if (.impacts | length) > 0 then
                        (.impacts[0].severity | normalize_severity)
                    else
                        (.severity // "INFO" | normalize_severity)
                    end
                ),
                type: (.type // "CODE_SMELL"),
                rule: (.rule // ""),
                message: (.message // ""),
                status: (.status // "OPEN"),
                effort: (.effort // .debt // ""),
                tags: ((.tags // []) | join(",")),
                created_at: (.creationDate // "")
            } |
            "INSERT INTO findings (source, external_key, file, line, end_line, severity, type, rule, message, status, effort, tags, created_at) VALUES (\(q"sonarcloud"), \(q .key | sql_escape), \(q .file | sql_escape), \(.line), \(.end_line), \(q .severity), \(q .type), \(q .rule | sql_escape), \(q .message | sql_escape), \(q .status), \(q .effort), \(q .tags | sql_escape), \(q .created_at)) ON CONFLICT(source, external_key) DO UPDATE SET severity=excluded.severity, status=excluded.status, message=excluded.message, effort=excluded.effort, tags=excluded.tags, collected_at=strftime(\(q"%Y-%m-%dT%H:%M:%SZ"), \(q"now"));"
        ' > "$sql_file" 2>/dev/null || {
            # jq @text quoting not available — use simpler approach
            echo "$response" | jq -r '
                def normalize_severity:
                    if . == "BLOCKER" then "critical"
                    elif . == "CRITICAL" then "critical"
                    elif . == "HIGH" then "high"
                    elif . == "MAJOR" then "high"
                    elif . == "MEDIUM" then "medium"
                    elif . == "MINOR" then "medium"
                    elif . == "LOW" then "low"
                    elif . == "INFO" then "info"
                    else "info"
                    end;

                def esc: gsub("'"'"'"; "'"'"''"'"'");

                .issues[] |
                "INSERT INTO findings (source, external_key, file, line, end_line, severity, type, rule, message, status, effort, tags, created_at) VALUES ('"'"'sonarcloud'"'"', '"'"'" + (.key | esc) + "'"'"', '"'"'" + ((.component // "" | split(":") | if length > 1 then .[1:] | join(":") else .[0] end) | esc) + "'"'"', " + ((.line // .textRange.startLine // 0) | tostring) + ", " + ((.textRange.endLine // .line // 0) | tostring) + ", '"'"'" + (if (.impacts | length) > 0 then (.impacts[0].severity | normalize_severity) else ((.severity // "INFO") | normalize_severity) end) + "'"'"', '"'"'" + ((.type // "CODE_SMELL") | esc) + "'"'"', '"'"'" + ((.rule // "") | esc) + "'"'"', '"'"'" + ((.message // "") | esc) + "'"'"', '"'"'" + ((.status // "OPEN") | esc) + "'"'"', '"'"'" + ((.effort // .debt // "") | esc) + "'"'"', '"'"'" + (((.tags // []) | join(",")) | esc) + "'"'"', '"'"'" + ((.creationDate // "") | esc) + "'"'"') ON CONFLICT(source, external_key) DO UPDATE SET severity=excluded.severity, status=excluded.status, message=excluded.message, effort=excluded.effort, tags=excluded.tags, collected_at=strftime('"'"'%Y-%m-%dT%H:%M:%SZ'"'"', '"'"'now'"'"');"
            ' > "$sql_file"
        }

        # Count new vs updated before applying
        local pre_count
        pre_count=$(db "$SWEEP_DB" "SELECT count(*) FROM findings WHERE source='sonarcloud';")

        # Execute SQL
        db "$SWEEP_DB" < "$sql_file"

        local post_count
        post_count=$(db "$SWEEP_DB" "SELECT count(*) FROM findings WHERE source='sonarcloud';")

        local page_new=$((post_count - pre_count))
        local page_updated=$((page_count - page_new))
        new_count=$((new_count + page_new))
        updated_count=$((updated_count + page_updated))
        total_fetched=$((total_fetched + page_count))

        print_info "Page $page: $page_count issues ($page_new new, $page_updated updated)"

        # Check if we've fetched all pages
        if [[ $total_fetched -ge $total_issues ]] || [[ $page_count -lt $SONAR_PAGE_SIZE ]]; then
            break
        fi

        page=$((page + 1))

        # SonarCloud API limit: max 10,000 results (page * ps <= 10000)
        if [[ $((page * SONAR_PAGE_SIZE)) -gt 10000 ]]; then
            print_warning "Reached SonarCloud API limit of 10,000 results. Use filters to narrow scope."
            break
        fi
    done

    # Update sweep run record
    db "$SWEEP_DB" "UPDATE sweep_runs SET status='complete', completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'), total_fetched=$total_fetched, new_findings=$new_count, updated_findings=$updated_count WHERE id=$run_id;"

    print_success "Fetched $total_fetched issues ($new_count new, $updated_count updated)"
    echo "$total_fetched"
    return 0
}

# =============================================================================
# Query findings
# =============================================================================

cmd_sonarcloud_query() {
    local severity=""
    local file_pattern=""
    local rule=""
    local status=""
    local limit="50"
    local format="table"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --severity) severity="${2:-}"; shift 2 ;;
            --file) file_pattern="${2:-}"; shift 2 ;;
            --rule) rule="${2:-}"; shift 2 ;;
            --status) status="${2:-}"; shift 2 ;;
            --limit) limit="${2:-}"; shift 2 ;;
            --format) format="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    init_db

    local where="WHERE source='sonarcloud'"
    if [[ -n "$severity" ]]; then
        where="$where AND severity='$(echo "$severity" | sed "s/'/''/g")'"
    fi
    if [[ -n "$file_pattern" ]]; then
        where="$where AND file LIKE '%$(echo "$file_pattern" | sed "s/'/''/g")%'"
    fi
    if [[ -n "$rule" ]]; then
        where="$where AND rule LIKE '%$(echo "$rule" | sed "s/'/''/g")%'"
    fi
    if [[ -n "$status" ]]; then
        where="$where AND status='$(echo "$status" | sed "s/'/''/g")'"
    fi

    case "$format" in
        json)
            db "$SWEEP_DB" -json "SELECT file, line, severity, type, rule, message, status, effort, tags, created_at FROM findings $where ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END, file, line LIMIT $limit;"
            ;;
        csv)
            db "$SWEEP_DB" -header -csv "SELECT file, line, severity, type, rule, message, status, effort, tags, created_at FROM findings $where ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END, file, line LIMIT $limit;"
            ;;
        table|*)
            echo ""
            db "$SWEEP_DB" -header -column "SELECT file, line, severity, rule, message FROM findings $where ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END, file, line LIMIT $limit;"
            ;;
    esac
    return 0
}

# =============================================================================
# Summary statistics
# =============================================================================

cmd_sonarcloud_summary() {
    init_db

    local total
    total=$(db "$SWEEP_DB" "SELECT count(*) FROM findings WHERE source='sonarcloud';")

    if [[ "$total" -eq 0 ]]; then
        print_warning "No SonarCloud findings in database. Run 'quality-sweep-helper.sh sonarcloud fetch' first."
        return 0
    fi

    print_info "SonarCloud Findings Summary"
    echo ""

    echo "By Severity:"
    db "$SWEEP_DB" -header -column "SELECT severity, count(*) as count FROM findings WHERE source='sonarcloud' GROUP BY severity ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END;"
    echo ""

    echo "By Type:"
    db "$SWEEP_DB" -header -column "SELECT type, count(*) as count FROM findings WHERE source='sonarcloud' GROUP BY type ORDER BY count DESC;"
    echo ""

    echo "By Rule (top 15):"
    db "$SWEEP_DB" -header -column "SELECT rule, severity, count(*) as count FROM findings WHERE source='sonarcloud' GROUP BY rule ORDER BY count DESC LIMIT 15;"
    echo ""

    echo "By File (top 15):"
    db "$SWEEP_DB" -header -column "SELECT file, count(*) as count FROM findings WHERE source='sonarcloud' GROUP BY file ORDER BY count DESC LIMIT 15;"
    echo ""

    echo "Total: $total findings"
    return 0
}

# =============================================================================
# Export findings
# =============================================================================

cmd_sonarcloud_export() {
    local format="json"
    local output=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) format="${2:-}"; shift 2 ;;
            --output) output="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    init_db

    local query="SELECT source, external_key, file, line, end_line, severity, type, rule, message, status, effort, tags, created_at, collected_at FROM findings WHERE source='sonarcloud' ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END, file, line;"

    local result
    case "$format" in
        json)
            result=$(db "$SWEEP_DB" -json "$query")
            ;;
        csv)
            result=$(db "$SWEEP_DB" -header -csv "$query")
            ;;
        *)
            print_error "Unknown format: $format (use json or csv)"
            return 1
            ;;
    esac

    if [[ -n "$output" ]]; then
        echo "$result" > "$output"
        print_success "Exported to: $output"
    else
        echo "$result"
    fi
    return 0
}

# =============================================================================
# Status check
# =============================================================================

cmd_sonarcloud_status() {
    echo ""
    print_info "Quality Sweep Status"
    echo ""

    # Check dependencies
    echo "Dependencies:"
    if command -v jq &>/dev/null; then
        echo "  jq: $(jq --version 2>/dev/null || echo 'available')"
    else
        echo "  jq: NOT FOUND (required)"
    fi
    if command -v curl &>/dev/null; then
        echo "  curl: available"
    else
        echo "  curl: NOT FOUND (required)"
    fi
    if command -v sqlite3 &>/dev/null; then
        echo "  sqlite3: available"
    else
        echo "  sqlite3: NOT FOUND (required)"
    fi
    echo ""

    # Check auth
    load_sonar_token
    echo "Authentication:"
    if [[ -n "${SONAR_TOKEN:-}" ]]; then
        echo "  SONAR_TOKEN: configured"
    else
        echo "  SONAR_TOKEN: not set (using unauthenticated access — public repos only)"
    fi
    echo ""

    # Check database
    echo "Database:"
    if [[ -f "$SWEEP_DB" ]]; then
        init_db
        local total
        total=$(db "$SWEEP_DB" "SELECT count(*) FROM findings WHERE source='sonarcloud';")
        echo "  Location: $SWEEP_DB"
        echo "  SonarCloud findings: $total"

        local last_run
        last_run=$(db "$SWEEP_DB" "SELECT started_at || ' (' || status || ', ' || total_fetched || ' fetched)' FROM sweep_runs WHERE source='sonarcloud' ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "none")
        echo "  Last run: $last_run"
    else
        echo "  Location: $SWEEP_DB (not yet created)"
        echo "  Run 'quality-sweep-helper.sh sonarcloud fetch' to initialize"
    fi
    echo ""
    return 0
}

# =============================================================================
# SonarCloud command router
# =============================================================================

cmd_sonarcloud() {
    local subcmd="${1:-help}"
    shift || true

    # Check dependencies
    if ! command -v jq &>/dev/null; then
        print_error "jq is required but not installed. Install with: brew install jq"
        return 1
    fi
    if ! command -v curl &>/dev/null; then
        print_error "curl is required but not installed."
        return 1
    fi

    case "$subcmd" in
        fetch)
            load_sonar_token
            fetch_sonarcloud_issues "$@"
            ;;
        query)
            cmd_sonarcloud_query "$@"
            ;;
        summary)
            cmd_sonarcloud_summary "$@"
            ;;
        export)
            cmd_sonarcloud_export "$@"
            ;;
        status)
            cmd_sonarcloud_status "$@"
            ;;
        help|*)
            echo ""
            echo "Usage: quality-sweep-helper.sh sonarcloud <command> [options]"
            echo ""
            echo "Commands:"
            echo "  fetch     Fetch issues from SonarCloud API and store in database"
            echo "  query     Query stored findings with filters"
            echo "  summary   Show severity/type/rule/file breakdown"
            echo "  export    Export findings as JSON or CSV"
            echo "  status    Show configuration and database status"
            echo ""
            echo "Fetch options:"
            echo "  --project KEY      SonarCloud project key (default: $SONAR_DEFAULT_PROJECT)"
            echo "  --statuses LIST    Comma-separated statuses (default: OPEN,CONFIRMED)"
            echo "  --types LIST       Comma-separated types: BUG,VULNERABILITY,CODE_SMELL"
            echo "  --resolved BOOL    Include resolved issues (default: false)"
            echo ""
            echo "Query options:"
            echo "  --severity LEVEL   Filter by severity: critical, high, medium, low, info"
            echo "  --file PATTERN     Filter by file path (substring match)"
            echo "  --rule PATTERN     Filter by rule ID (substring match)"
            echo "  --status STATUS    Filter by status: OPEN, CONFIRMED, etc."
            echo "  --limit N          Max results (default: 50)"
            echo "  --format FMT       Output format: table, json, csv (default: table)"
            echo ""
            echo "Export options:"
            echo "  --format FMT       Output format: json, csv (default: json)"
            echo "  --output FILE      Write to file instead of stdout"
            echo ""
            echo "Authentication:"
            echo "  Set SONAR_TOKEN via:"
            echo "    1. Environment variable: export SONAR_TOKEN=your_token"
            echo "    2. gopass: aidevops secret set sonarcloud-token"
            echo "    3. credentials.sh: ~/.config/aidevops/credentials.sh"
            echo "  Public repos work without authentication (rate-limited)."
            echo ""
            ;;
    esac
    return 0
}

# =============================================================================
# Codacy credential loading (3-tier: env -> gopass -> credentials.sh)
# =============================================================================

load_codacy_token() {
    # Tier 1: Environment variable
    if [[ -n "${CODACY_API_TOKEN:-}" ]]; then
        return 0
    fi

    # Tier 2: gopass encrypted store
    if command -v gopass &>/dev/null; then
        CODACY_API_TOKEN=$(gopass show "aidevops/codacy-token" 2>/dev/null) || true
        if [[ -n "${CODACY_API_TOKEN:-}" ]]; then
            export CODACY_API_TOKEN
            return 0
        fi
    fi

    # Tier 3: Plaintext credentials file
    local creds_file="${HOME}/.config/aidevops/credentials.sh"
    if [[ -f "$creds_file" ]]; then
        # shellcheck source=/dev/null
        source "$creds_file"
        if [[ -n "${CODACY_API_TOKEN:-}" ]]; then
            return 0
        fi
    fi

    # No token found — Codacy API requires authentication
    print_warning "CODACY_API_TOKEN not found. Set via env, gopass, or credentials.sh."
    return 1
}

# =============================================================================
# Codacy API helpers
# =============================================================================

# Make an authenticated API call to Codacy v3 API.
# Arguments:
#   $1 - API endpoint path (e.g., /analysis/organizations/gh/org/repositories/repo/issues)
#   $2 - Query parameters (URL-encoded, optional)
# Output: JSON response on stdout
# Returns: 0 on success, 1 on failure
codacy_api_call() {
    local endpoint="$1"
    local params="${2:-}"
    local url="${CODACY_API_URL}${endpoint}"

    if [[ -n "$params" ]]; then
        url="${url}?${params}"
    fi

    local curl_args=(-s --fail-with-body --max-time "$DEFAULT_TIMEOUT")

    if [[ -n "${CODACY_API_TOKEN:-}" ]]; then
        curl_args+=(-H "api-token: ${CODACY_API_TOKEN}")
    fi
    curl_args+=(-H "Accept: application/json")

    local http_code
    local tmp_body
    tmp_body=$(mktemp)
    trap 'rm -f "${tmp_body:-}"' RETURN

    http_code=$(curl "${curl_args[@]}" -o "$tmp_body" -w '%{http_code}' "$url" 2>/dev/null) || {
        print_error "Codacy API request failed: ${endpoint}"
        return 1
    }

    if [[ "$http_code" -ge 400 ]]; then
        local error_msg
        error_msg=$(jq -r '.message // .error // "Unknown error"' "$tmp_body" 2>/dev/null || echo "HTTP $http_code")
        print_error "Codacy API error ($http_code): $error_msg"
        return 1
    fi

    cat "$tmp_body"
    return 0
}

# =============================================================================
# Codacy fetch with cursor-based pagination
# =============================================================================

# Fetch all issues from Codacy API v3 with cursor-based pagination.
# Arguments (via flags):
#   --provider PROVIDER  Git provider (default: gh)
#   --org ORG            Organization/username (default: CODACY_DEFAULT_ORG)
#   --repo REPO          Repository name (default: CODACY_DEFAULT_REPO)
# Output: Total issues fetched count on stdout
# Side effect: Inserts/updates findings in SQLite
fetch_codacy_issues() {
    local provider="${CODACY_DEFAULT_PROVIDER}"
    local org="${CODACY_DEFAULT_ORG}"
    local repo="${CODACY_DEFAULT_REPO}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --provider) provider="${2:-}"; shift 2 ;;
            --org) org="${2:-}"; shift 2 ;;
            --repo) repo="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    init_db

    # Create sweep run record
    local run_id
    run_id=$(db "$SWEEP_DB" "INSERT INTO sweep_runs (source, project_key) VALUES ('codacy', '$(echo "${org}/${repo}" | sed "s/'/''/g")'); SELECT last_insert_rowid();")

    local cursor=""
    local total_fetched=0
    local new_count=0
    local updated_count=0
    local page_num=0

    print_info "Fetching Codacy issues for: ${provider}/${org}/${repo}"

    while true; do
        page_num=$((page_num + 1))

        # Build query parameters — Codacy v3 uses cursor-based pagination
        local params="limit=${CODACY_PAGE_SIZE}"
        if [[ -n "$cursor" ]]; then
            params="${params}&cursor=${cursor}"
        fi

        local endpoint="/analysis/organizations/${provider}/${org}/repositories/${repo}/issues"
        local response
        response=$(codacy_api_call "$endpoint" "$params") || {
            print_error "Failed to fetch page $page_num"
            db "$SWEEP_DB" "UPDATE sweep_runs SET status='failed', completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=$run_id;"
            return 1
        }

        # Extract issues count on this page
        local page_count
        page_count=$(echo "$response" | jq '.data | length // 0')

        if [[ "$page_count" -eq 0 ]]; then
            break
        fi

        # Generate SQL inserts from JSON using jq
        # Normalize Codacy severity -> our severity scale:
        #   Error -> high, Warning -> medium, Info -> info
        # Normalize Codacy patternCategory -> our type:
        #   Security -> VULNERABILITY, ErrorProne -> BUG,
        #   CodeStyle/Compatibility/Performance/UnusedCode -> CODE_SMELL
        _save_cleanup_scope
        trap '_run_cleanups' RETURN
        local sql_file
        sql_file=$(mktemp)
        push_cleanup "rm -f '${sql_file}'"

        echo "$response" | jq -r '
            def normalize_severity:
                if . == "Error" then "high"
                elif . == "Warning" then "medium"
                elif . == "Info" then "info"
                else "info"
                end;

            def normalize_type:
                if . == "Security" then "VULNERABILITY"
                elif . == "ErrorProne" then "BUG"
                elif . == "CodeStyle" then "CODE_SMELL"
                elif . == "Compatibility" then "CODE_SMELL"
                elif . == "Performance" then "CODE_SMELL"
                elif . == "UnusedCode" then "CODE_SMELL"
                elif . == "Complexity" then "CODE_SMELL"
                elif . == "Documentation" then "CODE_SMELL"
                elif . == "BestPractice" then "CODE_SMELL"
                else "CODE_SMELL"
                end;

            def esc: gsub("'"'"'"; "'"'"''"'"'");

            .data[] |
            "INSERT INTO findings (source, external_key, file, line, end_line, severity, type, rule, message, status, effort, tags, created_at) VALUES ('"'"'codacy'"'"', '"'"'" + ((.issueId // .commitIssueId // "") | tostring | esc) + "'"'"', '"'"'" + ((.filePath // "") | esc) + "'"'"', " + ((.lineNumber // 0) | tostring) + ", " + ((.lineNumber // 0) | tostring) + ", '"'"'" + ((.severity // "Info") | normalize_severity) + "'"'"', '"'"'" + ((.patternCategory // "CodeStyle") | normalize_type) + "'"'"', '"'"'" + ((.patternId // "") | esc) + "'"'"', '"'"'" + ((.message // "") | esc) + "'"'"', '"'"'OPEN'"'"', '"'"''"'"', '"'"'" + ((.language // "") | esc) + "'"'"', '"'"'" + ((.createdAt // "") | esc) + "'"'"') ON CONFLICT(source, external_key) DO UPDATE SET severity=excluded.severity, status=excluded.status, message=excluded.message, effort=excluded.effort, tags=excluded.tags, collected_at=strftime('"'"'%Y-%m-%dT%H:%M:%SZ'"'"', '"'"'now'"'"');"
        ' > "$sql_file" 2>/dev/null || {
            print_error "Failed to parse Codacy response on page $page_num"
            db "$SWEEP_DB" "UPDATE sweep_runs SET status='failed', completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=$run_id;"
            return 1
        }

        # Count new vs updated before applying
        local pre_count
        pre_count=$(db "$SWEEP_DB" "SELECT count(*) FROM findings WHERE source='codacy';")

        # Execute SQL
        db "$SWEEP_DB" < "$sql_file"

        local post_count
        post_count=$(db "$SWEEP_DB" "SELECT count(*) FROM findings WHERE source='codacy';")

        local page_new=$((post_count - pre_count))
        local page_updated=$((page_count - page_new))
        new_count=$((new_count + page_new))
        updated_count=$((updated_count + page_updated))
        total_fetched=$((total_fetched + page_count))

        print_info "Page $page_num: $page_count issues ($page_new new, $page_updated updated)"

        # Extract cursor for next page
        cursor=$(echo "$response" | jq -r '.pagination.cursor // empty' 2>/dev/null) || cursor=""
        if [[ -z "$cursor" ]]; then
            break
        fi

        # Safety limit — prevent infinite loops
        if [[ $page_num -ge 100 ]]; then
            print_warning "Reached page limit (100). Use filters to narrow scope."
            break
        fi
    done

    # Update sweep run record
    db "$SWEEP_DB" "UPDATE sweep_runs SET status='complete', completed_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'), total_fetched=$total_fetched, new_findings=$new_count, updated_findings=$updated_count WHERE id=$run_id;"

    print_success "Fetched $total_fetched issues ($new_count new, $updated_count updated)"
    echo "$total_fetched"
    return 0
}

# =============================================================================
# Codacy query findings
# =============================================================================

cmd_codacy_query() {
    local severity=""
    local file_pattern=""
    local rule=""
    local status=""
    local limit="50"
    local format="table"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --severity) severity="${2:-}"; shift 2 ;;
            --file) file_pattern="${2:-}"; shift 2 ;;
            --rule) rule="${2:-}"; shift 2 ;;
            --status) status="${2:-}"; shift 2 ;;
            --limit) limit="${2:-}"; shift 2 ;;
            --format) format="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    init_db

    local where="WHERE source='codacy'"
    if [[ -n "$severity" ]]; then
        where="$where AND severity='$(echo "$severity" | sed "s/'/''/g")'"
    fi
    if [[ -n "$file_pattern" ]]; then
        where="$where AND file LIKE '%$(echo "$file_pattern" | sed "s/'/''/g")%'"
    fi
    if [[ -n "$rule" ]]; then
        where="$where AND rule LIKE '%$(echo "$rule" | sed "s/'/''/g")%'"
    fi
    if [[ -n "$status" ]]; then
        where="$where AND status='$(echo "$status" | sed "s/'/''/g")'"
    fi

    case "$format" in
        json)
            db "$SWEEP_DB" -json "SELECT file, line, severity, type, rule, message, status, effort, tags, created_at FROM findings $where ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END, file, line LIMIT $limit;"
            ;;
        csv)
            db "$SWEEP_DB" -header -csv "SELECT file, line, severity, type, rule, message, status, effort, tags, created_at FROM findings $where ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END, file, line LIMIT $limit;"
            ;;
        table|*)
            echo ""
            db "$SWEEP_DB" -header -column "SELECT file, line, severity, rule, message FROM findings $where ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END, file, line LIMIT $limit;"
            ;;
    esac
    return 0
}

# =============================================================================
# Codacy summary statistics
# =============================================================================

cmd_codacy_summary() {
    init_db

    local total
    total=$(db "$SWEEP_DB" "SELECT count(*) FROM findings WHERE source='codacy';")

    if [[ "$total" -eq 0 ]]; then
        print_warning "No Codacy findings in database. Run 'quality-sweep-helper.sh codacy fetch' first."
        return 0
    fi

    print_info "Codacy Findings Summary"
    echo ""

    echo "By Severity:"
    db "$SWEEP_DB" -header -column "SELECT severity, count(*) as count FROM findings WHERE source='codacy' GROUP BY severity ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END;"
    echo ""

    echo "By Type:"
    db "$SWEEP_DB" -header -column "SELECT type, count(*) as count FROM findings WHERE source='codacy' GROUP BY type ORDER BY count DESC;"
    echo ""

    echo "By Rule (top 15):"
    db "$SWEEP_DB" -header -column "SELECT rule, severity, count(*) as count FROM findings WHERE source='codacy' GROUP BY rule ORDER BY count DESC LIMIT 15;"
    echo ""

    echo "By File (top 15):"
    db "$SWEEP_DB" -header -column "SELECT file, count(*) as count FROM findings WHERE source='codacy' GROUP BY file ORDER BY count DESC LIMIT 15;"
    echo ""

    echo "Total: $total findings"
    return 0
}

# =============================================================================
# Codacy export findings
# =============================================================================

cmd_codacy_export() {
    local format="json"
    local output=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) format="${2:-}"; shift 2 ;;
            --output) output="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    init_db

    local query="SELECT source, external_key, file, line, end_line, severity, type, rule, message, status, effort, tags, created_at, collected_at FROM findings WHERE source='codacy' ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END, file, line;"

    local result
    case "$format" in
        json)
            result=$(db "$SWEEP_DB" -json "$query")
            ;;
        csv)
            result=$(db "$SWEEP_DB" -header -csv "$query")
            ;;
        *)
            print_error "Unknown format: $format (use json or csv)"
            return 1
            ;;
    esac

    if [[ -n "$output" ]]; then
        echo "$result" > "$output"
        print_success "Exported to: $output"
    else
        echo "$result"
    fi
    return 0
}

# =============================================================================
# Codacy status check
# =============================================================================

cmd_codacy_status() {
    echo ""
    print_info "Codacy Sweep Status"
    echo ""

    # Check dependencies
    echo "Dependencies:"
    if command -v jq &>/dev/null; then
        echo "  jq: $(jq --version 2>/dev/null || echo 'available')"
    else
        echo "  jq: NOT FOUND (required)"
    fi
    if command -v curl &>/dev/null; then
        echo "  curl: available"
    else
        echo "  curl: NOT FOUND (required)"
    fi
    if command -v sqlite3 &>/dev/null; then
        echo "  sqlite3: available"
    else
        echo "  sqlite3: NOT FOUND (required)"
    fi
    echo ""

    # Check auth
    echo "Authentication:"
    if load_codacy_token 2>/dev/null; then
        echo "  CODACY_API_TOKEN: configured"
    else
        echo "  CODACY_API_TOKEN: not set (required — Codacy API needs authentication)"
    fi
    echo ""

    # Check database
    echo "Database:"
    if [[ -f "$SWEEP_DB" ]]; then
        init_db
        local total
        total=$(db "$SWEEP_DB" "SELECT count(*) FROM findings WHERE source='codacy';")
        echo "  Location: $SWEEP_DB"
        echo "  Codacy findings: $total"

        local last_run
        last_run=$(db "$SWEEP_DB" "SELECT started_at || ' (' || status || ', ' || total_fetched || ' fetched)' FROM sweep_runs WHERE source='codacy' ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "none")
        echo "  Last run: $last_run"
    else
        echo "  Location: $SWEEP_DB (not yet created)"
        echo "  Run 'quality-sweep-helper.sh codacy fetch' to initialize"
    fi
    echo ""
    return 0
}

# =============================================================================
# Cross-source deduplication
# =============================================================================

# Identify findings that appear in multiple sources (same file+line+type).
# This is a query-time operation — it does not modify the database.
# Arguments (via flags):
#   --format FMT   Output format: table, json, csv (default: table)
#   --limit N      Max results (default: 50)
# Output: Duplicate findings grouped by file+line+type
cmd_dedup() {
    local format="table"
    local limit="50"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) format="${2:-}"; shift 2 ;;
            --limit) limit="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    init_db

    local dedup_query="SELECT f.file, f.line, f.type, GROUP_CONCAT(DISTINCT f.source) as sources, GROUP_CONCAT(DISTINCT f.rule) as rules, MIN(CASE f.severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END) as sev_rank, CASE MIN(CASE f.severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END) WHEN 1 THEN 'critical' WHEN 2 THEN 'high' WHEN 3 THEN 'medium' WHEN 4 THEN 'low' ELSE 'info' END as worst_severity, COUNT(DISTINCT f.source) as source_count, f.message FROM findings f GROUP BY f.file, f.line, f.type HAVING COUNT(DISTINCT f.source) > 1 ORDER BY sev_rank, f.file, f.line LIMIT $limit"

    local total_dupes
    total_dupes=$(db "$SWEEP_DB" "SELECT COUNT(*) FROM (SELECT file, line, type FROM findings GROUP BY file, line, type HAVING COUNT(DISTINCT source) > 1);")

    if [[ "$total_dupes" -eq 0 ]]; then
        print_info "No cross-source duplicates found."
        echo ""
        echo "This means no finding appears in both SonarCloud and Codacy at the same file+line+type."
        echo "Run 'quality-sweep-helper.sh sonarcloud fetch' and 'quality-sweep-helper.sh codacy fetch' first."
        return 0
    fi

    print_info "Cross-Source Duplicate Findings: $total_dupes"
    echo ""

    case "$format" in
        json)
            db "$SWEEP_DB" -json "$dedup_query"
            ;;
        csv)
            db "$SWEEP_DB" -header -csv "$dedup_query"
            ;;
        table|*)
            db "$SWEEP_DB" -header -column "SELECT file, line, type, sources, worst_severity, rules FROM ($dedup_query);"
            ;;
    esac
    return 0
}

# =============================================================================
# Codacy command router
# =============================================================================

cmd_codacy() {
    local subcmd="${1:-help}"
    shift || true

    # Check dependencies
    if ! command -v jq &>/dev/null; then
        print_error "jq is required but not installed. Install with: brew install jq"
        return 1
    fi
    if ! command -v curl &>/dev/null; then
        print_error "curl is required but not installed."
        return 1
    fi

    case "$subcmd" in
        fetch)
            load_codacy_token || return 1
            fetch_codacy_issues "$@"
            ;;
        query)
            cmd_codacy_query "$@"
            ;;
        summary)
            cmd_codacy_summary "$@"
            ;;
        export)
            cmd_codacy_export "$@"
            ;;
        status)
            cmd_codacy_status "$@"
            ;;
        dedup)
            cmd_dedup "$@"
            ;;
        help|*)
            echo ""
            echo "Usage: quality-sweep-helper.sh codacy <command> [options]"
            echo ""
            echo "Commands:"
            echo "  fetch     Fetch issues from Codacy API v3 and store in database"
            echo "  query     Query stored findings with filters"
            echo "  summary   Show severity/type/rule/file breakdown"
            echo "  export    Export findings as JSON or CSV"
            echo "  status    Show configuration and database status"
            echo "  dedup     Show cross-source duplicates (same file+line+type across tools)"
            echo ""
            echo "Fetch options:"
            echo "  --provider PROVIDER  Git provider: gh, bb, gl (default: $CODACY_DEFAULT_PROVIDER)"
            echo "  --org ORG            Organization/username (default: $CODACY_DEFAULT_ORG)"
            echo "  --repo REPO          Repository name (default: $CODACY_DEFAULT_REPO)"
            echo ""
            echo "Query options:"
            echo "  --severity LEVEL     Filter by severity: critical, high, medium, low, info"
            echo "  --file PATTERN       Filter by file path (substring match)"
            echo "  --rule PATTERN       Filter by rule ID (substring match)"
            echo "  --status STATUS      Filter by status: OPEN, etc."
            echo "  --limit N            Max results (default: 50)"
            echo "  --format FMT         Output format: table, json, csv (default: table)"
            echo ""
            echo "Export options:"
            echo "  --format FMT         Output format: json, csv (default: json)"
            echo "  --output FILE        Write to file instead of stdout"
            echo ""
            echo "Dedup options:"
            echo "  --format FMT         Output format: table, json, csv (default: table)"
            echo "  --limit N            Max results (default: 50)"
            echo ""
            echo "Authentication:"
            echo "  Set CODACY_API_TOKEN via:"
            echo "    1. Environment variable: export CODACY_API_TOKEN=your_token"
            echo "    2. gopass: aidevops secret set codacy-token"
            echo "    3. credentials.sh: ~/.config/aidevops/credentials.sh"
            echo "  Codacy API requires authentication (no public access)."
            echo ""
            ;;
    esac
    return 0
}

# =============================================================================
# Top-level help
# =============================================================================

show_help() {
    echo ""
    echo "quality-sweep-helper.sh — Unified quality debt sweep"
    echo ""
    echo "Usage: quality-sweep-helper.sh <source> <command> [options]"
    echo ""
    echo "Sources:"
    echo "  sonarcloud   SonarCloud code quality findings (t245.1)"
    echo "  codacy       Codacy code quality findings (t245.2)"
    echo "  codefactor   CodeFactor findings (future)"
    echo "  coderabbit   CodeRabbit findings (future — see coderabbit-collector-helper.sh)"
    echo ""
    echo "Cross-source:"
    echo "  dedup        Show findings that appear in multiple sources (same file+line+type)"
    echo "  triage       Finding-to-task pipeline (t245.3 — delegates to finding-to-task-helper.sh)"
    echo ""
    echo "Commands (per source):"
    echo "  fetch        Fetch findings from the source API"
    echo "  query        Query stored findings with filters"
    echo "  summary      Show breakdown by severity/type/rule/file"
    echo "  export       Export findings as JSON or CSV"
    echo "  status       Show configuration and database status"
    echo ""
    echo "Examples:"
    echo "  quality-sweep-helper.sh sonarcloud fetch"
    echo "  quality-sweep-helper.sh sonarcloud query --severity high --limit 20"
    echo "  quality-sweep-helper.sh sonarcloud summary"
    echo "  quality-sweep-helper.sh sonarcloud export --format json --output findings.json"
    echo "  quality-sweep-helper.sh codacy fetch"
    echo "  quality-sweep-helper.sh codacy fetch --org myorg --repo myrepo"
    echo "  quality-sweep-helper.sh codacy summary"
    echo "  quality-sweep-helper.sh dedup --format json"
    echo "  quality-sweep-helper.sh triage create --dry-run --by file"
    echo ""
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local source="${1:-help}"
    shift || true

    case "$source" in
        sonarcloud)
            cmd_sonarcloud "$@"
            ;;
        codacy)
            cmd_codacy "$@"
            ;;
        dedup)
            cmd_dedup "$@"
            ;;
        triage)
            # Delegate to finding-to-task-helper.sh (t245.3)
            local triage_script="${SCRIPT_DIR}/finding-to-task-helper.sh"
            if [[ ! -x "$triage_script" ]]; then
                print_error "finding-to-task-helper.sh not found at $triage_script"
                return 1
            fi
            "$triage_script" "$@"
            ;;
        codefactor|coderabbit)
            print_warning "Source '$source' is not yet implemented."
            return 0
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown source: $source"
            show_help
            return 1
            ;;
    esac
    return 0
}

main "$@"
