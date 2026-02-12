#!/usr/bin/env bash
# shellcheck disable=SC1091
# quality-sweep-helper.sh — Unified quality debt sweep: fetch, normalize, and store
# findings from code quality tools (SonarCloud, Codacy, CodeFactor, CodeRabbit).
#
# t245: Parent task — unified quality debt pipeline
# t245.1: SonarCloud API integration
# t245.2: Codacy API integration
# t245.3: Finding-to-task pipeline (finding-to-task-helper.sh)
# t245.4: Daily GitHub Action (quality-sweep.yml)
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

    local tmp_body
    tmp_body=$(mktemp)
    trap 'rm -f "${tmp_body:-}"' RETURN

    curl "${curl_args[@]}" -o "$tmp_body" -w '%{http_code}' "$url" 2>/dev/null || {
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
# Top-level orchestration commands (called by GitHub Action — t245.4)
# =============================================================================

# Run the full quality sweep across all configured sources.
# Arguments (via flags):
#   --severity LEVEL   Minimum severity to report (default: medium)
#   --auto-dispatch    Auto-dispatch tasks to workers (future)
# Output: JSON findings file in SWEEP_DATA_DIR/findings/
cmd_run() {
    local severity="medium"
    local auto_dispatch="false"
    local include_shellcheck="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --severity) severity="${2:-medium}"; shift 2 ;;
            --auto-dispatch) auto_dispatch="true"; shift ;;
            --shellcheck) include_shellcheck="true"; shift ;;
            *) shift ;;
        esac
    done

    init_db
    mkdir -p "${SWEEP_DATA_DIR}/findings" 2>/dev/null || true

    local timestamp
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    local findings_file="${SWEEP_DATA_DIR}/findings/${timestamp}-findings.json"
    local total_findings=0
    local sources_run=0
    local sources_failed=0

    print_info "Starting quality sweep (severity >= $severity)"

    # --- ShellCheck (local, opt-in via --shellcheck flag) ---
    # Full ShellCheck already runs in code-quality.yml on every push/PR.
    # Include here only when explicitly requested (can be slow on large repos).
    local shellcheck_findings=0
    if [[ "$include_shellcheck" == "true" ]]; then
        if command -v shellcheck &>/dev/null; then
            _save_cleanup_scope
            trap '_run_cleanups' RETURN
            local sc_json
            sc_json=$(mktemp)
            push_cleanup "rm -f '${sc_json}'"

            local sh_file_list
            sh_file_list=$(mktemp)
            push_cleanup "rm -f '${sh_file_list}'"
            git ls-files '*.sh' 2>/dev/null > "$sh_file_list" || find . -name '*.sh' -not -path './.git/*' > "$sh_file_list"

            local sh_count
            sh_count=$(wc -l < "$sh_file_list" | tr -d ' ')
            print_info "Running ShellCheck on $sh_count shell scripts..."

            local sc_results="[]"
            if [[ "$sh_count" -gt 0 ]]; then
                sc_results=$(xargs shellcheck -f json -S warning < "$sh_file_list" 2>/dev/null || echo "[]")
                if ! echo "$sc_results" | jq empty 2>/dev/null; then
                    sc_results="[]"
                fi
            fi

            # Convert ShellCheck JSON to normalized format, filter by severity
            shellcheck_findings=$(echo "$sc_results" | jq --arg sev "$severity" '
                def sc_level_to_severity:
                    if . == "error" then "high"
                    elif . == "warning" then "medium"
                    elif . == "info" then "low"
                    elif . == "style" then "info"
                    else "info"
                    end;
                def severity_rank:
                    if . == "critical" then 1
                    elif . == "high" then 2
                    elif . == "medium" then 3
                    elif . == "low" then 4
                    elif . == "info" then 5
                    else 6
                    end;
                ($sev | severity_rank) as $min_rank |
                [.[] | {
                    source: "shellcheck",
                    external_key: ("SC" + (.code | tostring) + ":" + .file + ":" + (.line | tostring)),
                    file: .file,
                    line: .line,
                    end_line: (.endLine // .line),
                    severity: (.level | sc_level_to_severity),
                    type: "CODE_SMELL",
                    rule: ("SC" + (.code | tostring)),
                    message: .message,
                    status: "OPEN"
                } | select((.severity | severity_rank) <= $min_rank)]
                | length
            ')
            print_info "ShellCheck: $shellcheck_findings findings (severity >= $severity)"
            sources_run=$((sources_run + 1))
        else
            print_warning "ShellCheck not installed — skipping"
        fi
    fi

    # --- SonarCloud (remote API) ---
    local sonar_findings=0
    load_sonar_token
    if [[ -n "${SONAR_TOKEN:-}" ]]; then
        print_info "Fetching SonarCloud findings..."
        if fetch_sonarcloud_issues --project "$SONAR_DEFAULT_PROJECT" >/dev/null 2>&1; then
            local sev_filter
            case "$severity" in
                critical) sev_filter="'critical'" ;;
                high)     sev_filter="'critical','high'" ;;
                medium)   sev_filter="'critical','high','medium'" ;;
                low)      sev_filter="'critical','high','medium','low'" ;;
                *)        sev_filter="'critical','high','medium','low','info'" ;;
            esac
            sonar_findings=$(db "$SWEEP_DB" "SELECT count(*) FROM findings WHERE source='sonarcloud' AND severity IN ($sev_filter);")
            print_info "SonarCloud: $sonar_findings findings (severity >= $severity)"
            sources_run=$((sources_run + 1))
        else
            print_warning "SonarCloud fetch failed — continuing with other sources"
            sources_failed=$((sources_failed + 1))
        fi
    else
        print_info "SONAR_TOKEN not set — skipping SonarCloud (public API is rate-limited)"
    fi

    # --- Codacy (remote API) ---
    local codacy_findings=0
    load_codacy_token 2>/dev/null || true
    if [[ -n "${CODACY_API_TOKEN:-}" ]]; then
        print_info "Fetching Codacy findings..."
        if fetch_codacy_issues >/dev/null 2>&1; then
            local codacy_sev_filter
            case "$severity" in
                critical) codacy_sev_filter="'critical'" ;;
                high)     codacy_sev_filter="'critical','high'" ;;
                medium)   codacy_sev_filter="'critical','high','medium'" ;;
                low)      codacy_sev_filter="'critical','high','medium','low'" ;;
                *)        codacy_sev_filter="'critical','high','medium','low','info'" ;;
            esac
            codacy_findings=$(db "$SWEEP_DB" "SELECT count(*) FROM findings WHERE source='codacy' AND severity IN ($codacy_sev_filter);")
            print_info "Codacy: $codacy_findings findings (severity >= $severity)"
            sources_run=$((sources_run + 1))
        else
            print_warning "Codacy fetch failed — continuing with other sources"
            sources_failed=$((sources_failed + 1))
        fi
    else
        print_info "CODACY_API_TOKEN not set — skipping Codacy"
    fi

    # --- CodeRabbit / CodeFactor (future) ---

    total_findings=$((shellcheck_findings + sonar_findings + codacy_findings))

    # Build findings JSON output (combine all sources from DB, filtered by severity)
    local all_findings_json="[]"
    if [[ -f "$SWEEP_DB" ]]; then
        local output_sev_filter
        case "$severity" in
            critical) output_sev_filter="'critical'" ;;
            high)     output_sev_filter="'critical','high'" ;;
            medium)   output_sev_filter="'critical','high','medium'" ;;
            low)      output_sev_filter="'critical','high','medium','low'" ;;
            *)        output_sev_filter="'critical','high','medium','low','info'" ;;
        esac
        all_findings_json=$(db "$SWEEP_DB" -json "SELECT source, external_key, file, line, end_line, severity, type, rule, message, status FROM findings WHERE status='OPEN' AND severity IN ($output_sev_filter) ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END LIMIT 500;" 2>/dev/null || echo "[]")
    fi

    # Assemble final findings file
    jq -n \
        --argjson sonar_count "$sonar_findings" \
        --argjson codacy_count "$codacy_findings" \
        --argjson shellcheck_count "$shellcheck_findings" \
        --argjson total "$total_findings" \
        --argjson sources_run "$sources_run" \
        --argjson sources_failed "$sources_failed" \
        --arg severity "$severity" \
        --arg timestamp "$timestamp" \
        --argjson findings "$all_findings_json" \
        '{
            meta: {
                timestamp: $timestamp,
                severity_filter: $severity,
                sources_run: $sources_run,
                sources_failed: $sources_failed
            },
            stats: {
                total_findings: $total,
                deduplicated_findings: $total,
                final_findings: $total
            },
            findings: $findings,
            breakdown: {
                sonarcloud: $sonar_count,
                codacy: $codacy_count,
                shellcheck: $shellcheck_count
            }
        }' > "$findings_file"

    print_success "Sweep complete: $total_findings findings across $sources_run sources"
    print_info "Findings saved to: $findings_file"

    if [[ "$auto_dispatch" == "true" ]]; then
        print_info "Auto-dispatch requested — generating tasks..."
        cmd_tasks --findings "$findings_file"
    fi

    return 0
}

# Show a summary of the most recent sweep run.
cmd_sweep_summary() {
    local findings_dir="${SWEEP_DATA_DIR}/findings"
    local latest
    latest=$(ls -t "$findings_dir"/*-findings.json 2>/dev/null | head -1 || echo "")

    if [[ -z "$latest" || ! -f "$latest" ]]; then
        print_warning "No findings file found. Run 'quality-sweep-helper.sh run' first."
        return 0
    fi

    print_info "Quality Sweep Summary ($(basename "$latest"))"
    echo ""

    local total deduped final
    total=$(jq '.stats.total_findings // 0' "$latest")
    deduped=$(jq '.stats.deduplicated_findings // 0' "$latest")
    final=$(jq '.stats.final_findings // 0' "$latest")

    echo "Total findings:      $total"
    echo "After deduplication: $deduped"
    echo "Final actionable:    $final"
    echo ""

    echo "By Source:"
    jq -r '.breakdown | to_entries[] | "  \(.key): \(.value)"' "$latest"
    echo ""

    # Show critical/high from DB if available
    if [[ -f "$SWEEP_DB" ]]; then
        local critical high
        critical=$(db "$SWEEP_DB" "SELECT count(*) FROM findings WHERE severity='critical';" 2>/dev/null || echo "0")
        high=$(db "$SWEEP_DB" "SELECT count(*) FROM findings WHERE severity='high';" 2>/dev/null || echo "0")
        if [[ "$critical" -gt 0 || "$high" -gt 0 ]]; then
            echo "Attention Required:"
            echo "  Critical: $critical"
            echo "  High:     $high"
        else
            echo "No critical or high severity findings."
        fi
    fi

    return 0
}

# Generate task suggestions from findings (dry-run by default).
# When --create is used, allocates task IDs via claim-task-id.sh (t319.3)
# and outputs TODO-compatible task lines with proper tNNN IDs.
# Arguments (via flags):
#   --dry-run          Show tasks without creating them (default)
#   --create           Create tasks with allocated IDs via claim-task-id.sh
#   --findings FILE    Use specific findings file
cmd_tasks() {
    local dry_run="true"
    local findings_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run="true"; shift ;;
            --create) dry_run="false"; shift ;;
            --findings) findings_file="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$findings_file" ]]; then
        local findings_dir="${SWEEP_DATA_DIR}/findings"
        findings_file=$(ls -t "$findings_dir"/*-findings.json 2>/dev/null | head -1 || echo "")
    fi

    if [[ -z "$findings_file" || ! -f "$findings_file" ]]; then
        print_warning "No findings file found. Run 'quality-sweep-helper.sh run' first."
        return 0
    fi

    print_info "Task Suggestions from Quality Sweep"
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        echo "(dry-run mode — no tasks will be created)"
        echo ""
    fi

    # Group findings by rule and suggest tasks
    if [[ ! -f "$SWEEP_DB" ]]; then
        echo "No database available — showing findings file summary only."
        jq -r '.findings | group_by(.rule) | sort_by(-length) | .[:10][] | "  \(.[0].rule) (\(.[0].severity)): \(length) findings"' "$findings_file" 2>/dev/null || true
        return 0
    fi

    # Query grouped findings (top 10 rules with OPEN status)
    local grouped_json
    grouped_json=$(db "$SWEEP_DB" -json \
        "SELECT rule, severity, count(*) as count,
                'Fix ' || count(*) || ' ' || rule || ' quality findings' as suggested_task
         FROM findings
         WHERE status='OPEN'
         GROUP BY rule
         ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END, count DESC
         LIMIT 10;" 2>/dev/null || echo "[]")

    local group_count
    group_count=$(echo "$grouped_json" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$group_count" -eq 0 ]]; then
        print_info "No open findings to create tasks from."
        return 0
    fi

    if [[ "$dry_run" == "true" ]]; then
        echo "Suggested tasks by rule (top 10 most frequent):"
        echo ""
        db "$SWEEP_DB" -header -column \
            "SELECT rule, severity, count(*) as count,
                    'Fix ' || count(*) || ' ' || rule || ' quality findings' as suggested_task
             FROM findings
             WHERE status='OPEN'
             GROUP BY rule
             ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END, count DESC
             LIMIT 10;"
        return 0
    fi

    # --create mode: allocate IDs via claim-task-id.sh and output task lines (t319.3)
    local claim_script="${SCRIPT_DIR}/claim-task-id.sh"
    if [[ ! -x "$claim_script" ]]; then
        print_error "claim-task-id.sh not found or not executable at: $claim_script"
        return 1
    fi

    local repo_path
    repo_path=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
    local tasks_created=0
    local task_lines=""

    _save_cleanup_scope
    trap '_run_cleanups' RETURN
    local tmp_groups
    tmp_groups=$(mktemp)
    push_cleanup "rm -f '${tmp_groups}'"
    echo "$grouped_json" | jq -c '.[]' >"$tmp_groups"

    while IFS= read -r group; do
        local rule severity count suggested_task
        rule=$(echo "$group" | jq -r '.rule')
        severity=$(echo "$group" | jq -r '.severity')
        count=$(echo "$group" | jq -r '.count')
        suggested_task=$(echo "$group" | jq -r '.suggested_task')

        # Map severity to priority tag
        local priority_tag
        case "$severity" in
            critical) priority_tag="#critical" ;;
            high)     priority_tag="#high" ;;
            medium)   priority_tag="#medium" ;;
            *)        priority_tag="#low" ;;
        esac

        # Estimate effort based on finding count
        local estimate="~30m"
        if [[ "$count" -gt 10 ]]; then
            estimate="~2h"
        elif [[ "$count" -gt 5 ]]; then
            estimate="~1h"
        fi

        # Allocate task ID via claim-task-id.sh
        local task_title="${suggested_task} (${severity})"
        local claim_output task_id gh_ref
        if claim_output=$("$claim_script" --title "${task_title:0:80}" --description "Auto-created from quality sweep: ${count} ${rule} findings" --labels "quality,auto-dispatch" --repo-path "$repo_path" 2>&1); then
            task_id=$(echo "$claim_output" | grep "^task_id=" | cut -d= -f2)
            gh_ref=$(echo "$claim_output" | grep "^ref=" | cut -d= -f2)
        else
            print_warning "Failed to allocate task ID for rule ${rule}: $claim_output"
            print_info "Skipping (will retry on next run)"
            continue
        fi

        if [[ -z "$task_id" ]]; then
            print_warning "No task_id returned for rule ${rule}, skipping"
            continue
        fi

        # Build task line
        local task_line="- [ ] ${task_id} ${suggested_task} ${priority_tag} #quality #auto-dispatch ${estimate}"
        if [[ -n "$gh_ref" && "$gh_ref" != "offline" ]]; then
            task_line="${task_line} ref:${gh_ref}"
        fi
        task_line="${task_line} logged:$(date +%Y-%m-%d)"

        task_lines="${task_lines}${task_line}\n"
        tasks_created=$((tasks_created + 1))
    done <"$tmp_groups"

    if [[ -n "$task_lines" ]]; then
        echo ""
        print_success "Generated $tasks_created task(s) with allocated IDs"
        echo ""
        echo "=== Task Lines (for TODO.md) ==="
        echo ""
        echo -e "$task_lines"
        echo "================================"
        echo ""
        print_info "To add these to TODO.md, copy the lines above into the appropriate section."
        print_info "Tasks tagged #auto-dispatch will be picked up by supervisor auto-pickup."
    else
        print_info "No tasks created."
    fi

    return 0
}

# =============================================================================
# Top-level help
# =============================================================================

show_help() {
    echo ""
    echo "quality-sweep-helper.sh — Unified quality debt sweep"
    echo ""
    echo "Usage:"
    echo "  quality-sweep-helper.sh run [--severity LEVEL] [--auto-dispatch] [--shellcheck]"
    echo "  quality-sweep-helper.sh summary"
    echo "  quality-sweep-helper.sh tasks [--dry-run]"
    echo "  quality-sweep-helper.sh <source> <command> [options]"
    echo ""
    echo "Top-level commands (used by GitHub Action — t245.4):"
    echo "  run          Run full quality sweep across all sources"
    echo "  summary      Show summary of most recent sweep"
    echo "  tasks        Generate task suggestions from findings"
    echo ""
    echo "Sources:"
    echo "  sonarcloud   SonarCloud code quality findings (t245.1)"
    echo "  codacy       Codacy code quality findings (t245.2)"
    echo "  codefactor   CodeFactor findings (future)"
    echo "  coderabbit   CodeRabbit findings (future — see coderabbit-collector-helper.sh)"
    echo ""
    echo "Cross-source:"
    echo "  dedup        Show findings that appear in multiple sources (same file+line+type)"
    echo ""
    echo "Commands (per source):"
    echo "  fetch        Fetch findings from the source API"
    echo "  query        Query stored findings with filters"
    echo "  summary      Show breakdown by severity/type/rule/file"
    echo "  export       Export findings as JSON or CSV"
    echo "  status       Show configuration and database status"
    echo ""
    echo "Examples:"
    echo "  quality-sweep-helper.sh run --severity high"
    echo "  quality-sweep-helper.sh summary"
    echo "  quality-sweep-helper.sh tasks --dry-run"
    echo "  quality-sweep-helper.sh sonarcloud fetch"
    echo "  quality-sweep-helper.sh sonarcloud query --severity high --limit 20"
    echo "  quality-sweep-helper.sh codacy fetch"
    echo "  quality-sweep-helper.sh codacy fetch --org myorg --repo myrepo"
    echo "  quality-sweep-helper.sh dedup --format json"
    echo ""
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        # Top-level orchestration commands (called by GitHub Action — t245.4)
        run)
            cmd_run "$@"
            ;;
        summary)
            cmd_sweep_summary "$@"
            ;;
        tasks)
            cmd_tasks "$@"
            ;;
        # Source-specific commands
        sonarcloud)
            cmd_sonarcloud "$@"
            ;;
        codacy)
            cmd_codacy "$@"
            ;;
        dedup)
            cmd_dedup "$@"
            ;;
        codefactor|coderabbit)
            print_warning "Source '$cmd' is not yet implemented. See TODO.md for t245.3+."
            return 0
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $cmd"
            show_help
            return 1
            ;;
    esac
    return 0
}

main "$@"
