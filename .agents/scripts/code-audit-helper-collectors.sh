#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Code Audit Helper -- Service Collectors
# =============================================================================
# Service-specific collector functions for CodeRabbit, SonarCloud, Codacy,
# and CodeFactor. Each collector fetches findings from its respective API
# and inserts them into the unified audit_findings SQLite table.
#
# Usage: source "${SCRIPT_DIR}/code-audit-helper-collectors.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, etc.)
#   - code-audit-helper.sh (db, sql_escape, AUDIT_DB constants)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CODE_AUDIT_COLLECTORS_LIB_LOADED:-}" ]] && return 0
_CODE_AUDIT_COLLECTORS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

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

# Write the Codacy jq filter to a file path supplied as $1
_write_codacy_jq_filter() {
    local dest="$1"
    cat >"$dest" <<'JQ_EOF'
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

    local sql_file jq_filter_file
    sql_file=$(mktemp)
    _save_cleanup_scope
    trap '_run_cleanups' RETURN
    push_cleanup "rm -f '${sql_file}'"

    jq_filter_file=$(mktemp)
    push_cleanup "rm -f '${jq_filter_file}'"
    _write_codacy_jq_filter "$jq_filter_file"

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
