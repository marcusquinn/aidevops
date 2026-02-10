#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# =============================================================================
# Quality Sweep Helper - Unified Quality Findings Pipeline
# =============================================================================
# Fetches issues from multiple code quality tools (Codacy API, SonarCloud API),
# normalizes them into a unified finding format, deduplicates across tools, and
# outputs structured JSON for downstream task creation (t245.3).
#
# Usage:
#   quality-sweep-helper.sh codacy [--branch BRANCH] [--output FILE]
#   quality-sweep-helper.sh sonar [--branch BRANCH] [--output FILE]
#   quality-sweep-helper.sh sweep [--branch BRANCH] [--output FILE]
#   quality-sweep-helper.sh dedup --codacy FILE --sonar FILE [--output FILE]
#   quality-sweep-helper.sh help
#
# Commands:
#   codacy    Fetch and normalize issues from Codacy API
#   sonar     Fetch and normalize issues from SonarCloud API
#   sweep     Fetch from all sources, normalize, and deduplicate
#   dedup     Deduplicate pre-fetched finding files
#   help      Show this help message
#
# Environment Variables:
#   CODACY_API_TOKEN       - Codacy account API token (required for codacy/sweep)
#   CODACY_PROVIDER        - Git provider: gh, gl, bb (default: gh)
#   CODACY_ORGANIZATION    - Organization name (default: from config or git)
#   CODACY_REPOSITORY      - Repository name (default: from config or git)
#   SONAR_TOKEN            - SonarCloud token (required for sonar/sweep)
#   SONAR_PROJECT_KEY      - SonarCloud project key (default: marcusquinn_aidevops)
#
# Part of t245: Unified quality debt sweep
# t245.2: Codacy API integration — fetch, normalize, deduplicate
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Constants
# =============================================================================

readonly CODACY_API_BASE="https://app.codacy.com/api/v3"
readonly SONAR_API_BASE="https://sonarcloud.io"
readonly SWEEP_DATA_DIR="${HOME}/.aidevops/.agent-workspace/work/quality-sweep"
readonly DEFAULT_PROVIDER="gh"
readonly DEFAULT_SONAR_PROJECT_KEY="marcusquinn_aidevops"
readonly API_PAGE_LIMIT=100

# Severity and category mappings are handled inline in jq normalization.
# Codacy levels: Error -> high, Warning -> medium, Info -> low
# Codacy categories: Security -> security, ErrorProne -> bug, others -> code_smell
# SonarCloud severity: BLOCKER/CRITICAL -> critical, MAJOR -> high, MINOR -> medium, INFO -> low
# SonarCloud types: BUG -> bug, VULNERABILITY/SECURITY_HOTSPOT -> security, CODE_SMELL -> code_smell

# =============================================================================
# Helper Functions
# =============================================================================

# Stderr variants of print functions for use in data-returning functions
# (prevents status messages from mixing with JSON output on stdout)
log_info() { print_info "$1" >&2; return 0; }
log_error() { print_error "$1" >&2; return 0; }
log_warning() { print_warning "$1" >&2; return 0; }
log_success() { print_success "$1" >&2; return 0; }

ensure_dirs() {
    mkdir -p "$SWEEP_DATA_DIR" 2>/dev/null || true
    return 0
}

now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
    return 0
}

# Get repository info from git remote or config
detect_repo_info() {
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")

    if [[ -z "$remote_url" ]]; then
        print_error "Not in a git repository or no origin remote"
        return 1
    fi

    # Extract org/repo from git remote URL
    # Handles: git@github.com:org/repo.git, https://github.com/org/repo.git
    local org_repo
    org_repo=$(echo "$remote_url" | sed -E 's#.*[:/]([^/]+)/([^/.]+)(\.git)?$#\1/\2#')

    local org
    org=$(echo "$org_repo" | cut -d'/' -f1)
    local repo
    repo=$(echo "$org_repo" | cut -d'/' -f2)

    echo "${org}/${repo}"
    return 0
}

# Load Codacy config from configs/codacy-config.json if available
load_codacy_config() {
    local config_file="configs/codacy-config.json"

    if [[ -f "$config_file" ]] && command -v jq >/dev/null 2>&1; then
        local org
        org=$(jq -r '.organization // empty' "$config_file" 2>/dev/null)
        local repo
        repo=$(jq -r '.repository // empty' "$config_file" 2>/dev/null)

        if [[ -n "$org" && -z "${CODACY_ORGANIZATION:-}" ]]; then
            CODACY_ORGANIZATION="$org"
        fi
        if [[ -n "$repo" && -z "${CODACY_REPOSITORY:-}" ]]; then
            CODACY_REPOSITORY="$repo"
        fi
    fi

    # Fallback to git detection
    if [[ -z "${CODACY_ORGANIZATION:-}" || -z "${CODACY_REPOSITORY:-}" ]]; then
        local detected
        detected=$(detect_repo_info) || return 1
        CODACY_ORGANIZATION="${CODACY_ORGANIZATION:-$(echo "$detected" | cut -d'/' -f1)}"
        CODACY_REPOSITORY="${CODACY_REPOSITORY:-$(echo "$detected" | cut -d'/' -f2)}"
    fi

    return 0
}

# =============================================================================
# Codacy API Integration (t245.2)
# =============================================================================

# Fetch issues from Codacy API v3 with cursor-based pagination
# Endpoint: POST /analysis/organizations/{provider}/{org}/repositories/{repo}/issues/search
fetch_codacy_issues() {
    local branch="${1:-}"
    local provider="${CODACY_PROVIDER:-$DEFAULT_PROVIDER}"
    local organization="${CODACY_ORGANIZATION:-}"
    local repository="${CODACY_REPOSITORY:-}"
    local api_token="${CODACY_API_TOKEN:-}"

    if [[ -z "$api_token" ]]; then
        log_error "CODACY_API_TOKEN not set. Get token from: https://app.codacy.com/account/api-tokens"
        return 1
    fi

    load_codacy_config || return 1

    # Re-read after config load
    organization="${CODACY_ORGANIZATION:-}"
    repository="${CODACY_REPOSITORY:-}"

    if [[ -z "$organization" || -z "$repository" ]]; then
        log_error "Cannot determine Codacy organization/repository"
        return 1
    fi

    local endpoint="${CODACY_API_BASE}/analysis/organizations/${provider}/${organization}/repositories/${repository}/issues/search"

    log_info "Fetching Codacy issues for ${provider}/${organization}/${repository}..."
    if [[ -n "$branch" ]]; then
        log_info "Branch filter: ${branch}"
    fi

    local all_issues="[]"
    local cursor=""
    local page=0
    local total_fetched=0

    while true; do
        page=$((page + 1))

        # Build request body
        local body="{}"
        if [[ -n "$branch" ]]; then
            body=$(jq -n --arg branch "$branch" '{"branchName": $branch}')
        fi

        # Build URL with pagination
        local url="${endpoint}?limit=${API_PAGE_LIMIT}"
        if [[ -n "$cursor" ]]; then
            url="${url}&cursor=${cursor}"
        fi

        local response
        local http_code
        http_code=$(curl -s -o /tmp/codacy_response.json -w "%{http_code}" \
            -X POST "$url" \
            -H "api-token: ${api_token}" \
            -H "${CONTENT_TYPE_JSON}" \
            -d "$body" 2>/dev/null) || true

        if [[ "$http_code" != "200" ]]; then
            local error_body
            error_body=$(cat /tmp/codacy_response.json 2>/dev/null || echo "no response body")
            log_error "Codacy API returned HTTP ${http_code} (page ${page})"
            log_info "Response: ${error_body}"
            rm -f /tmp/codacy_response.json
            # Return what we have so far if we got some data
            if [[ "$total_fetched" -gt 0 ]]; then
                log_warning "Returning ${total_fetched} issues fetched before error"
                echo "$all_issues"
                return 0
            fi
            return 1
        fi

        response=$(cat /tmp/codacy_response.json)
        rm -f /tmp/codacy_response.json

        # Extract issues from response
        local page_issues
        page_issues=$(echo "$response" | jq '.data // []')
        local page_count
        page_count=$(echo "$page_issues" | jq 'length')

        if [[ "$page_count" -eq 0 ]]; then
            break
        fi

        total_fetched=$((total_fetched + page_count))
        all_issues=$(echo "$all_issues" "$page_issues" | jq -s '.[0] + .[1]')

        log_info "  Page ${page}: ${page_count} issues (total: ${total_fetched})"

        # Check for next page cursor
        cursor=$(echo "$response" | jq -r '.pagination.cursor // empty')
        if [[ -z "$cursor" ]]; then
            break
        fi
    done

    log_success "Fetched ${total_fetched} issues from Codacy"
    echo "$all_issues"
    return 0
}

# Normalize Codacy issues to unified finding format
normalize_codacy_issues() {
    local raw_issues="$1"

    local count
    count=$(echo "$raw_issues" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo "[]"
        return 0
    fi

    # Transform each Codacy issue to unified format
    # Codacy issue fields: filePath, lineNumber, patternInfo.id, patternInfo.level,
    #   patternInfo.category, message, toolInfo.name, commitInfo.timestamp
    echo "$raw_issues" | jq '
        [.[] | {
            id: ("codacy-" + (.filePath // "unknown") + ":" + ((.lineNumber // 0) | tostring) + ":" + (.patternInfo.id // "unknown")),
            source: "codacy",
            file: (.filePath // "unknown"),
            line: (.lineNumber // 0),
            severity: (
                if .patternInfo.level == "Error" then "high"
                elif .patternInfo.level == "Warning" then "medium"
                elif .patternInfo.level == "Info" then "low"
                else "medium"
                end
            ),
            category: (
                if .patternInfo.category == "Security" then "security"
                elif .patternInfo.category == "ErrorProne" then "bug"
                else "code_smell"
                end
            ),
            rule: (.patternInfo.id // "unknown"),
            message: (.message // "No message"),
            tool: (.toolInfo.name // "unknown"),
            verified: false,
            task_created: false
        }]
    '
    return 0
}

# =============================================================================
# SonarCloud API Integration (t245.1 — basic fetch for dedup)
# =============================================================================

# Fetch issues from SonarCloud API with pagination
fetch_sonar_issues() {
    local branch="${1:-}"
    local project_key="${SONAR_PROJECT_KEY:-$DEFAULT_SONAR_PROJECT_KEY}"
    local sonar_token="${SONAR_TOKEN:-}"

    if [[ -z "$sonar_token" ]]; then
        log_error "SONAR_TOKEN not set. Get token from: https://sonarcloud.io/account/security/"
        return 1
    fi

    log_info "Fetching SonarCloud issues for ${project_key}..."

    local all_issues="[]"
    local page=1
    local total_fetched=0
    local total_available=0

    while true; do
        local url="${SONAR_API_BASE}/api/issues/search?componentKeys=${project_key}&resolved=false&ps=${API_PAGE_LIMIT}&p=${page}"
        if [[ -n "$branch" ]]; then
            url="${url}&branch=${branch}"
        fi
        # Filter to new/confirmed (skip resolved/closed)
        url="${url}&statuses=OPEN,CONFIRMED,REOPENED"

        local response
        local http_code
        http_code=$(curl -s -o /tmp/sonar_response.json -w "%{http_code}" \
            -u "${sonar_token}:" \
            "$url" 2>/dev/null) || true

        if [[ "$http_code" != "200" ]]; then
            local error_body
            error_body=$(cat /tmp/sonar_response.json 2>/dev/null || echo "no response body")
            log_error "SonarCloud API returned HTTP ${http_code} (page ${page})"
            log_info "Response: ${error_body}"
            rm -f /tmp/sonar_response.json
            if [[ "$total_fetched" -gt 0 ]]; then
                log_warning "Returning ${total_fetched} issues fetched before error"
                echo "$all_issues"
                return 0
            fi
            return 1
        fi

        response=$(cat /tmp/sonar_response.json)
        rm -f /tmp/sonar_response.json

        if [[ "$page" -eq 1 ]]; then
            total_available=$(echo "$response" | jq '.total // 0')
            log_info "  Total available: ${total_available}"
        fi

        local page_issues
        page_issues=$(echo "$response" | jq '.issues // []')
        local page_count
        page_count=$(echo "$page_issues" | jq 'length')

        if [[ "$page_count" -eq 0 ]]; then
            break
        fi

        total_fetched=$((total_fetched + page_count))
        all_issues=$(echo "$all_issues" "$page_issues" | jq -s '.[0] + .[1]')

        log_info "  Page ${page}: ${page_count} issues (total: ${total_fetched})"

        # SonarCloud uses offset-based pagination
        if [[ "$total_fetched" -ge "$total_available" ]]; then
            break
        fi

        page=$((page + 1))
    done

    log_success "Fetched ${total_fetched} issues from SonarCloud"
    echo "$all_issues"
    return 0
}

# Normalize SonarCloud issues to unified finding format
normalize_sonar_issues() {
    local raw_issues="$1"

    local count
    count=$(echo "$raw_issues" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo "[]"
        return 0
    fi

    # SonarCloud issue fields: key, rule, severity, component, line, message, type, status
    # component format: "project_key:path/to/file.sh"
    echo "$raw_issues" | jq --arg project_key "${SONAR_PROJECT_KEY:-$DEFAULT_SONAR_PROJECT_KEY}" '
        [.[] | {
            id: ("sonar-" + (.component // "unknown" | sub("^[^:]+:"; "")) + ":" + ((.line // 0) | tostring) + ":" + (.rule // "unknown")),
            source: "sonarcloud",
            file: (.component // "unknown" | sub("^[^:]+:"; "")),
            line: (.line // 0),
            severity: (
                if .severity == "BLOCKER" then "critical"
                elif .severity == "CRITICAL" then "critical"
                elif .severity == "MAJOR" then "high"
                elif .severity == "MINOR" then "medium"
                elif .severity == "INFO" then "low"
                else "medium"
                end
            ),
            category: (
                if .type == "BUG" then "bug"
                elif .type == "VULNERABILITY" then "security"
                elif .type == "SECURITY_HOTSPOT" then "security"
                else "code_smell"
                end
            ),
            rule: (.rule // "unknown"),
            message: (.message // "No message"),
            tool: "sonarcloud",
            verified: false,
            task_created: false
        }]
    '
    return 0
}

# =============================================================================
# Deduplication (t245.2)
# =============================================================================

# Deduplicate findings across sources
# Two findings are considered duplicates if they share the same file + line + category.
# When duplicates are found, the finding with higher severity wins; the other is
# merged as a secondary source reference.
deduplicate_findings() {
    local codacy_findings="$1"
    local sonar_findings="$2"

    local codacy_count
    codacy_count=$(echo "$codacy_findings" | jq 'length')
    local sonar_count
    sonar_count=$(echo "$sonar_findings" | jq 'length')

    log_info "Deduplicating: ${codacy_count} Codacy + ${sonar_count} SonarCloud findings"

    # Merge both arrays and deduplicate using jq
    # Dedup key: file + line + category
    # When duplicate: keep higher severity, merge source info
    local merged
    merged=$(echo "$codacy_findings" "$sonar_findings" | jq -s '
        # Severity rank for comparison (lower number = higher severity)
        def severity_rank:
            if . == "critical" then 0
            elif . == "high" then 1
            elif . == "medium" then 2
            elif . == "low" then 3
            elif . == "info" then 4
            else 5
            end;

        .[0] + .[1]
        | group_by(.file + ":" + (.line | tostring) + ":" + .category)
        | map(
            if length == 1 then .[0]
            else
                # Multiple findings at same file+line+category — pick best severity
                sort_by(.severity | severity_rank)
                | .[0] as $primary
                | .[1:] as $others
                | $primary + {
                    also_found_by: [$others[].source],
                    merged_rules: ([$primary.rule] + [$others[].rule] | unique)
                }
            end
        )
    ')

    local merged_count
    merged_count=$(echo "$merged" | jq 'length')
    local dedup_removed
    dedup_removed=$(( codacy_count + sonar_count - merged_count ))

    log_success "Deduplicated: ${merged_count} unique findings (${dedup_removed} duplicates removed)"

    echo "$merged"
    return 0
}

# =============================================================================
# Output Formatting
# =============================================================================

# Wrap findings in the standard envelope format
wrap_findings_envelope() {
    local findings="$1"
    local sources="$2"

    local timestamp
    timestamp=$(now_iso)
    local repo_name
    repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "unknown")")
    local head_sha
    head_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    local total
    total=$(echo "$findings" | jq 'length')

    local by_severity
    by_severity=$(echo "$findings" | jq '{
        critical: [.[] | select(.severity == "critical")] | length,
        high: [.[] | select(.severity == "high")] | length,
        medium: [.[] | select(.severity == "medium")] | length,
        low: [.[] | select(.severity == "low")] | length,
        info: [.[] | select(.severity == "info")] | length
    }')

    local by_source
    by_source=$(echo "$findings" | jq '{
        codacy: [.[] | select(.source == "codacy")] | length,
        sonarcloud: [.[] | select(.source == "sonarcloud")] | length
    }')

    jq -n \
        --arg timestamp "$timestamp" \
        --arg repo "$repo_name" \
        --arg sha "$head_sha" \
        --arg sources "$sources" \
        --argjson total "$total" \
        --argjson by_severity "$by_severity" \
        --argjson by_source "$by_source" \
        --argjson findings "$findings" \
        '{
            run_id: ("quality-sweep-" + $repo + "-" + ($timestamp | gsub("[^0-9]"; ""))),
            timestamp: $timestamp,
            repo: $repo,
            sha: $sha,
            sources: ($sources | split(",")),
            stats: {
                total_findings: $total,
                by_severity: $by_severity,
                by_source: $by_source
            },
            findings: $findings
        }'
    return 0
}

# =============================================================================
# Commands
# =============================================================================

# Fetch and normalize Codacy issues only
cmd_codacy() {
    local branch="${1:-}"
    local output_file="${2:-}"

    ensure_dirs

    local raw_issues
    raw_issues=$(fetch_codacy_issues "$branch") || return 1

    local normalized
    normalized=$(normalize_codacy_issues "$raw_issues")

    local count
    count=$(echo "$normalized" | jq 'length')
    log_info "Normalized ${count} Codacy findings"

    local envelope
    envelope=$(wrap_findings_envelope "$normalized" "codacy")

    if [[ -n "$output_file" ]]; then
        echo "$envelope" > "$output_file"
        log_success "Output written to: ${output_file}"
    else
        echo "$envelope"
    fi
    return 0
}

# Fetch and normalize SonarCloud issues only
cmd_sonar() {
    local branch="${1:-}"
    local output_file="${2:-}"

    ensure_dirs

    local raw_issues
    raw_issues=$(fetch_sonar_issues "$branch") || return 1

    local normalized
    normalized=$(normalize_sonar_issues "$raw_issues")

    local count
    count=$(echo "$normalized" | jq 'length')
    log_info "Normalized ${count} SonarCloud findings"

    local envelope
    envelope=$(wrap_findings_envelope "$normalized" "sonarcloud")

    if [[ -n "$output_file" ]]; then
        echo "$envelope" > "$output_file"
        log_success "Output written to: ${output_file}"
    else
        echo "$envelope"
    fi
    return 0
}

# Full sweep: fetch from all sources, normalize, deduplicate
cmd_sweep() {
    local branch="${1:-}"
    local output_file="${2:-}"

    ensure_dirs

    local codacy_findings="[]"
    local sonar_findings="[]"
    local sources=""

    # Fetch Codacy (non-fatal if token missing)
    if [[ -n "${CODACY_API_TOKEN:-}" ]]; then
        local raw_codacy
        if raw_codacy=$(fetch_codacy_issues "$branch"); then
            codacy_findings=$(normalize_codacy_issues "$raw_codacy")
            sources="codacy"
        else
            log_warning "Codacy fetch failed, continuing with other sources"
        fi
    else
        log_warning "CODACY_API_TOKEN not set, skipping Codacy"
    fi

    # Fetch SonarCloud (non-fatal if token missing)
    if [[ -n "${SONAR_TOKEN:-}" ]]; then
        local raw_sonar
        if raw_sonar=$(fetch_sonar_issues "$branch"); then
            sonar_findings=$(normalize_sonar_issues "$raw_sonar")
            if [[ -n "$sources" ]]; then
                sources="${sources},sonarcloud"
            else
                sources="sonarcloud"
            fi
        else
            log_warning "SonarCloud fetch failed, continuing with other sources"
        fi
    else
        log_warning "SONAR_TOKEN not set, skipping SonarCloud"
    fi

    if [[ -z "$sources" ]]; then
        log_error "No quality sources available. Set CODACY_API_TOKEN and/or SONAR_TOKEN."
        return 1
    fi

    # Deduplicate
    local deduplicated
    deduplicated=$(deduplicate_findings "$codacy_findings" "$sonar_findings")

    local envelope
    envelope=$(wrap_findings_envelope "$deduplicated" "$sources")

    # Save to default location
    local default_output
    default_output="${SWEEP_DATA_DIR}/sweep-$(date -u +%Y%m%d-%H%M%S).json"
    echo "$envelope" > "$default_output"
    log_info "Sweep saved to: ${default_output}"

    if [[ -n "$output_file" ]]; then
        echo "$envelope" > "$output_file"
        log_success "Output written to: ${output_file}"
    else
        echo "$envelope"
    fi
    return 0
}

# Deduplicate pre-fetched finding files
cmd_dedup() {
    local codacy_file="${1:-}"
    local sonar_file="${2:-}"
    local output_file="${3:-}"

    if [[ -z "$codacy_file" || -z "$sonar_file" ]]; then
        log_error "Both --codacy and --sonar files required for dedup"
        return 1
    fi

    if [[ ! -f "$codacy_file" ]]; then
        log_error "Codacy findings file not found: ${codacy_file}"
        return 1
    fi
    if [[ ! -f "$sonar_file" ]]; then
        log_error "SonarCloud findings file not found: ${sonar_file}"
        return 1
    fi

    local codacy_findings
    codacy_findings=$(jq '.findings // []' "$codacy_file")
    local sonar_findings
    sonar_findings=$(jq '.findings // []' "$sonar_file")

    local deduplicated
    deduplicated=$(deduplicate_findings "$codacy_findings" "$sonar_findings")

    local envelope
    envelope=$(wrap_findings_envelope "$deduplicated" "codacy,sonarcloud")

    if [[ -n "$output_file" ]]; then
        echo "$envelope" > "$output_file"
        log_success "Output written to: ${output_file}"
    else
        echo "$envelope"
    fi
    return 0
}

# Show help
show_help() {
    cat << 'HELPEOF'
Quality Sweep Helper - Unified Quality Findings Pipeline (t245)

Usage: quality-sweep-helper.sh [command] [options]

Commands:
  codacy     Fetch and normalize issues from Codacy API
  sonar      Fetch and normalize issues from SonarCloud API
  sweep      Fetch from all sources, normalize, and deduplicate
  dedup      Deduplicate pre-fetched finding files
  help       Show this help message

Options:
  --branch BRANCH    Filter issues by branch name
  --output FILE      Write output to file (otherwise stdout)
  --codacy FILE      Codacy findings file (for dedup command)
  --sonar FILE       SonarCloud findings file (for dedup command)

Examples:
  quality-sweep-helper.sh codacy
  quality-sweep-helper.sh codacy --branch main --output codacy-findings.json
  quality-sweep-helper.sh sonar --output sonar-findings.json
  quality-sweep-helper.sh sweep --output all-findings.json
  quality-sweep-helper.sh dedup --codacy codacy.json --sonar sonar.json

Environment Variables:
  CODACY_API_TOKEN       Codacy account API token
  CODACY_PROVIDER        Git provider: gh, gl, bb (default: gh)
  CODACY_ORGANIZATION    Organization name
  CODACY_REPOSITORY      Repository name
  SONAR_TOKEN            SonarCloud authentication token
  SONAR_PROJECT_KEY      SonarCloud project key

Unified Finding Format:
  {
    "id": "source-file:line:rule",
    "source": "codacy|sonarcloud",
    "file": "path/to/file.sh",
    "line": 42,
    "severity": "critical|high|medium|low|info",
    "category": "security|bug|code_smell",
    "rule": "PatternId",
    "message": "Description of the issue",
    "tool": "shellcheck|eslint|...",
    "verified": false,
    "task_created": false
  }

Deduplication:
  Findings from different sources with the same file + line + category
  are merged into a single finding. The higher-severity version is kept,
  with also_found_by and merged_rules fields added.
HELPEOF
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true

    # Parse options
    local branch=""
    local output_file=""
    local codacy_file=""
    local sonar_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --branch)
                branch="${2:-}"
                shift 2
                ;;
            --output)
                output_file="${2:-}"
                shift 2
                ;;
            --codacy)
                codacy_file="${2:-}"
                shift 2
                ;;
            --sonar)
                sonar_file="${2:-}"
                shift 2
                ;;
            --help|-h)
                show_help
                return 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                return 1
                ;;
        esac
    done

    # Verify jq is available (required for all commands)
    if ! command -v jq >/dev/null 2>&1; then
        print_error "jq is required but not installed. Install with: brew install jq"
        return 1
    fi

    case "$command" in
        codacy)
            cmd_codacy "$branch" "$output_file"
            ;;
        sonar)
            cmd_sonar "$branch" "$output_file"
            ;;
        sweep)
            cmd_sweep "$branch" "$output_file"
            ;;
        dedup)
            cmd_dedup "$codacy_file" "$sonar_file" "$output_file"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "$ERROR_UNKNOWN_COMMAND $command"
            show_help
            return 1
            ;;
    esac
    return 0
}

main "$@"
