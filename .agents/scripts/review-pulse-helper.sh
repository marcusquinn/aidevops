#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# =============================================================================
# Review Pulse Helper - Daily Full Codebase AI Review
# =============================================================================
# Triggers CodeRabbit CLI full-repo review, collects findings into structured
# JSON, filters false positives, and optionally creates TODO tasks for valid
# findings that can be dispatched to workers.
#
# Usage:
#   review-pulse-helper.sh run [--output DIR] [--severity LEVEL] [--dry-run]
#   review-pulse-helper.sh findings [--format json|text] [--severity LEVEL]
#   review-pulse-helper.sh tasks [--dry-run] [--auto-dispatch]
#   review-pulse-helper.sh status
#   review-pulse-helper.sh history [--last N]
#   review-pulse-helper.sh help
#
# Subtasks (t166):
#   t166.1 - Daily pulse trigger (this script + cron/GH Action)
#   t166.2 - Structured feedback collection (run + findings commands)
#   t166.3 - Auto-create tasks from findings (tasks command)
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

readonly PULSE_DATA_DIR="${HOME}/.aidevops/.agent-workspace/work/review-pulse"
readonly FINDINGS_DIR="${PULSE_DATA_DIR}/findings"
readonly HISTORY_FILE="${PULSE_DATA_DIR}/history.jsonl"
readonly SEVERITY_LEVELS=("critical" "high" "medium" "low" "info")

# False positive patterns - known CodeRabbit false positives for shell-heavy repos
readonly FALSE_POSITIVE_PATTERNS=(
    "Consider using.*instead of.*for better"
    "Missing shebang"
    "File is too long"
    "Consider splitting this file"
)

# =============================================================================
# Helper Functions
# =============================================================================

# Ensure data directories exist
ensure_dirs() {
    mkdir -p "$FINDINGS_DIR" 2>/dev/null || true
    return 0
}

# Get current timestamp in ISO 8601
now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
    return 0
}

# Get repo info
get_repo_info() {
    local repo_name
    repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "unknown")")
    echo "$repo_name"
    return 0
}

# Get current commit SHA
get_head_sha() {
    git rev-parse HEAD 2>/dev/null || echo "unknown"
    return 0
}

# Check if CodeRabbit CLI is available
check_coderabbit() {
    if ! command -v coderabbit &>/dev/null; then
        print_error "CodeRabbit CLI not installed"
        print_info "Install: curl -fsSL https://cli.coderabbit.ai/install.sh | sh"
        print_info "Then: coderabbit auth login"
        return 1
    fi
    return 0
}

# Classify severity from CodeRabbit output line
classify_severity() {
    local line="$1"
    local lower_line
    lower_line=$(echo "$line" | tr '[:upper:]' '[:lower:]')

    if echo "$lower_line" | grep -qE "security|vulnerability|injection|credential|secret|xss|csrf"; then
        echo "critical"
    elif echo "$lower_line" | grep -qE "bug|error|race.condition|memory.leak|null.pointer|crash"; then
        echo "high"
    elif echo "$lower_line" | grep -qE "performance|inefficient|unused|dead.code|complexity"; then
        echo "medium"
    elif echo "$lower_line" | grep -qE "style|naming|convention|formatting|documentation"; then
        echo "low"
    else
        echo "info"
    fi
    return 0
}

# Check if a finding is a known false positive
is_false_positive() {
    local finding="$1"

    for pattern in "${FALSE_POSITIVE_PATTERNS[@]}"; do
        if echo "$finding" | grep -qiE "$pattern"; then
            return 0
        fi
    done
    return 1
}

# Severity meets minimum threshold
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
# Core: Run Full Codebase Review (t166.1)
# =============================================================================

# Run CodeRabbit CLI review against the full codebase
# Uses --base with empty tree to force full-repo diff
run_review_pulse() {
    local output_dir="${1:-$FINDINGS_DIR}"
    local min_severity="${2:-medium}"
    local dry_run="${3:-false}"

    ensure_dirs

    if ! check_coderabbit; then
        return 1
    fi

    local timestamp
    timestamp=$(now_iso)
    local repo_name
    repo_name=$(get_repo_info)
    local head_sha
    head_sha=$(get_head_sha)
    local run_id
    run_id="${repo_name}-$(date -u +%Y%m%d-%H%M%S)"
    local raw_output="${output_dir}/${run_id}-raw.txt"
    local findings_file="${output_dir}/${run_id}-findings.json"

    print_info "Starting review pulse: $run_id"
    print_info "Repo: $repo_name | SHA: ${head_sha:0:8} | Min severity: $min_severity"

    if [[ "$dry_run" == "true" ]]; then
        print_warning "[DRY RUN] Would run: coderabbit --plain --type all"
        echo '{"run_id":"'"$run_id"'","dry_run":true,"findings":[]}'
        return 0
    fi

    # Run CodeRabbit CLI - full codebase review
    # --plain for parseable output, --type all for committed + uncommitted
    print_info "Running CodeRabbit CLI review (this may take 2-5 minutes)..."

    local review_exit=0
    if ! coderabbit --plain --type all > "$raw_output" 2>&1; then
        review_exit=$?
        print_warning "CodeRabbit CLI exited with code $review_exit"
        # Non-zero exit may still have useful output (e.g., findings found)
    fi

    if [[ ! -s "$raw_output" ]]; then
        print_warning "CodeRabbit produced no output"
        # Record empty run in history
        echo '{"run_id":"'"$run_id"'","timestamp":"'"$timestamp"'","repo":"'"$repo_name"'","sha":"'"$head_sha"'","findings_count":0,"exit_code":'"$review_exit"'}' >> "$HISTORY_FILE"
        return 0
    fi

    local raw_size
    raw_size=$(wc -c < "$raw_output" | tr -d ' ')
    print_success "Review complete: ${raw_size} bytes of output"

    # Parse raw output into structured findings (t166.2)
    parse_findings "$raw_output" "$findings_file" "$min_severity" "$run_id" "$timestamp" "$repo_name" "$head_sha"

    local findings_count
    findings_count=$(jq '.findings | length' "$findings_file" 2>/dev/null || echo "0")

    # Record in history
    echo '{"run_id":"'"$run_id"'","timestamp":"'"$timestamp"'","repo":"'"$repo_name"'","sha":"'"$head_sha"'","findings_count":'"$findings_count"',"exit_code":'"$review_exit"'}' >> "$HISTORY_FILE"

    print_success "Pulse complete: $findings_count findings at severity >= $min_severity"
    print_info "Raw output: $raw_output"
    print_info "Findings: $findings_file"

    return 0
}

# =============================================================================
# Core: Parse Findings into Structured Format (t166.2)
# =============================================================================

# Parse CodeRabbit plain-text output into structured JSON findings
parse_findings() {
    local raw_file="$1"
    local output_file="$2"
    local min_severity="$3"
    local run_id="$4"
    local timestamp="$5"
    local repo_name="$6"
    local head_sha="$7"

    local findings_json='[]'
    local total_count=0
    local filtered_count=0
    local false_positive_count=0

    local current_file=""
    local current_finding=""

    # Parse the CodeRabbit output line by line
    # CodeRabbit --plain output format varies, but typically includes:
    # - File paths (often with line numbers)
    # - Finding descriptions
    # - Severity indicators
    while IFS= read -r line; do
        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Detect file path lines (e.g., "src/file.sh:42" or "## file.sh")
        if echo "$line" | grep -qE '^(##\s+|[a-zA-Z0-9_./-]+\.[a-zA-Z]+:[0-9]+|File:\s)'; then
            # Save previous finding if exists
            if [[ -n "$current_finding" ]]; then
                _add_finding
            fi

            # Extract file path
            current_file=$(echo "$line" | sed -E 's/^##\s+//; s/^File:\s+//; s/:([0-9]+).*$//')
            current_finding=""
            continue
        fi

        # Accumulate finding text
        if [[ -n "$current_file" ]]; then
            if [[ -n "$current_finding" ]]; then
                current_finding="${current_finding} ${line}"
            else
                current_finding="$line"
            fi
        fi
    done < "$raw_file"

    # Don't forget the last finding
    if [[ -n "$current_finding" ]]; then
        _add_finding
    fi

    # Build final JSON output
    cat > "$output_file" << FINDINGS_EOF
{
  "run_id": "$run_id",
  "timestamp": "$timestamp",
  "repo": "$repo_name",
  "sha": "$head_sha",
  "min_severity": "$min_severity",
  "stats": {
    "total_parsed": $total_count,
    "after_severity_filter": $filtered_count,
    "false_positives_removed": $false_positive_count,
    "final_findings": $(echo "$findings_json" | jq 'length')
  },
  "findings": $findings_json
}
FINDINGS_EOF

    return 0
}

# Internal: Add a finding to the findings array
# Uses variables from parse_findings scope
_add_finding() {
    total_count=$((total_count + 1))

    local severity
    severity=$(classify_severity "$current_finding")

    # Check severity threshold
    if ! meets_severity_threshold "$severity" "$min_severity"; then
        return 0
    fi

    # Check false positives
    if is_false_positive "$current_finding"; then
        false_positive_count=$((false_positive_count + 1))
        return 0
    fi

    filtered_count=$((filtered_count + 1))
    finding_id=$((finding_id + 1))

    # Escape the finding text for JSON
    local escaped_finding
    escaped_finding=$(echo "$current_finding" | jq -Rs '.' | sed 's/^"//;s/"$//')

    # Add to findings array
    findings_json=$(echo "$findings_json" | jq \
        --arg id "f${finding_id}" \
        --arg file "$current_file" \
        --arg severity "$severity" \
        --arg description "$escaped_finding" \
        --arg raw "$current_finding" \
        '. + [{
            "id": $id,
            "file": $file,
            "severity": $severity,
            "description": $description,
            "verified": false,
            "task_created": false
        }]')

    return 0
}

# =============================================================================
# Core: Auto-Create Tasks from Findings (t166.3)
# =============================================================================

# Create TODO tasks from validated findings
# Delegates to coderabbit-task-creator-helper.sh for full false-positive
# filtering, severity reclassification, deduplication, and supervisor dispatch.
create_tasks_from_findings() {
    local dry_run="${1:-false}"
    local auto_dispatch="${2:-false}"

    local task_creator="${SCRIPT_DIR}/coderabbit-task-creator-helper.sh"

    if [[ -x "$task_creator" ]]; then
        # Delegate to the dedicated task creator (t166.3)
        local args=("create" "--source" "pulse")
        if [[ "$dry_run" == "true" ]]; then
            args+=("--dry-run")
        fi
        if [[ "$auto_dispatch" == "true" ]]; then
            args+=("--dispatch")
        fi
        "$task_creator" "${args[@]}"
        return $?
    fi

    # Fallback: basic task generation (pre-t166.3 behaviour)
    print_warning "coderabbit-task-creator-helper.sh not found, using basic task generation"

    ensure_dirs

    local latest_findings
    latest_findings=$(find "$FINDINGS_DIR" -maxdepth 1 -name '*-findings.json' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)

    if [[ -z "$latest_findings" || ! -f "$latest_findings" ]]; then
        print_warning "No findings files found. Run 'review-pulse-helper.sh run' first."
        return 1
    fi

    local findings_count
    findings_count=$(jq '.findings | length' "$latest_findings")

    if [[ "$findings_count" -eq 0 ]]; then
        print_info "No findings to create tasks from."
        return 0
    fi

    print_info "Processing $findings_count findings from: $(basename "$latest_findings")"

    local tasks_created=0
    local task_lines=""

    while IFS= read -r finding; do
        local severity file description
        severity=$(echo "$finding" | jq -r '.severity')
        file=$(echo "$finding" | jq -r '.file')
        description=$(echo "$finding" | jq -r '.description' | head -c 120)

        local priority_tag
        case "$severity" in
            critical) priority_tag="#critical" ;;
            high)     priority_tag="#high" ;;
            medium)   priority_tag="#medium" ;;
            *)        priority_tag="#low" ;;
        esac

        local task_desc="CodeRabbit finding ($severity): $description [${file}] $priority_tag #quality #auto-review"

        if [[ "$dry_run" == "true" ]]; then
            print_info "[DRY RUN] Would create task: $task_desc"
        else
            task_lines="${task_lines}${task_desc}\n"
        fi

        tasks_created=$((tasks_created + 1))
    done < <(jq -c '.findings[]' "$latest_findings")

    if [[ "$dry_run" == "true" ]]; then
        print_info "[DRY RUN] Would create $tasks_created tasks"
        return 0
    fi

    if [[ $tasks_created -gt 0 ]]; then
        print_success "Generated $tasks_created task descriptions"
        print_info "Task descriptions (for supervisor or manual addition):"
        echo ""
        echo -e "$task_lines"
        echo ""
    fi

    return 0
}

# =============================================================================
# Display Commands
# =============================================================================

# Show findings from the latest or specified run
show_findings() {
    local format="${1:-text}"
    local min_severity="${2:-medium}"

    ensure_dirs

    local latest_findings
    latest_findings=$(find "$FINDINGS_DIR" -maxdepth 1 -name '*-findings.json' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)

    if [[ -z "$latest_findings" || ! -f "$latest_findings" ]]; then
        print_warning "No findings files found. Run 'review-pulse-helper.sh run' first."
        return 1
    fi

    if [[ "$format" == "json" ]]; then
        jq '.' "$latest_findings"
        return 0
    fi

    # Text format
    local run_id timestamp findings_count
    run_id=$(jq -r '.run_id' "$latest_findings")
    timestamp=$(jq -r '.timestamp' "$latest_findings")
    findings_count=$(jq '.findings | length' "$latest_findings")

    echo ""
    echo "Review Pulse Findings"
    echo "====================="
    echo "Run: $run_id"
    echo "Time: $timestamp"
    echo "Findings: $findings_count (severity >= $min_severity)"
    echo ""

    if [[ "$findings_count" -eq 0 ]]; then
        print_success "No findings at this severity level."
        return 0
    fi

    # Group by severity
    for sev in "${SEVERITY_LEVELS[@]}"; do
        local sev_count
        sev_count=$(jq --arg s "$sev" '[.findings[] | select(.severity == $s)] | length' "$latest_findings")

        if [[ "$sev_count" -gt 0 ]]; then
            echo "--- $sev ($sev_count) ---"
            jq -r --arg s "$sev" '.findings[] | select(.severity == $s) | "  [\(.id)] \(.file): \(.description[0:100])"' "$latest_findings"
            echo ""
        fi
    done

    # Stats
    echo "--- Stats ---"
    jq -r '.stats | "Total parsed: \(.total_parsed) | After filter: \(.after_severity_filter) | False positives: \(.false_positives_removed) | Final: \(.final_findings)"' "$latest_findings"

    return 0
}

# Show pulse run history
show_history() {
    local last_n="${1:-10}"

    ensure_dirs

    if [[ ! -f "$HISTORY_FILE" ]]; then
        print_info "No pulse history yet. Run 'review-pulse-helper.sh run' to start."
        return 0
    fi

    echo ""
    echo "Review Pulse History (last $last_n)"
    echo "===================================="
    echo ""

    tail -n "$last_n" "$HISTORY_FILE" | while IFS= read -r line; do
        local run_id timestamp findings_count exit_code
        run_id=$(echo "$line" | jq -r '.run_id')
        timestamp=$(echo "$line" | jq -r '.timestamp')
        findings_count=$(echo "$line" | jq -r '.findings_count')
        exit_code=$(echo "$line" | jq -r '.exit_code')

        local status_icon="OK"
        [[ "$exit_code" -ne 0 ]] && status_icon="WARN"

        echo "  [$status_icon] $timestamp | $run_id | $findings_count findings"
    done

    echo ""
    return 0
}

# Show current status
show_status() {
    ensure_dirs

    echo ""
    echo "Review Pulse Status"
    echo "==================="
    echo ""

    # Check CodeRabbit CLI
    if command -v coderabbit &>/dev/null; then
        local cr_version
        cr_version=$(coderabbit --version 2>/dev/null || echo "unknown")
        print_success "CodeRabbit CLI: v$cr_version"
    else
        print_warning "CodeRabbit CLI: not installed"
    fi

    # Check data directory
    if [[ -d "$FINDINGS_DIR" ]]; then
        local findings_count
        findings_count=$(find "$FINDINGS_DIR" -maxdepth 1 -name '*-findings.json' 2>/dev/null | wc -l | tr -d ' ')
        print_info "Findings files: $findings_count"
    else
        print_info "Findings directory: not created yet"
    fi

    # Check history
    if [[ -f "$HISTORY_FILE" ]]; then
        local history_count
        history_count=$(wc -l < "$HISTORY_FILE" | tr -d ' ')
        print_info "History entries: $history_count"

        # Last run
        local last_run
        last_run=$(tail -1 "$HISTORY_FILE")
        local last_timestamp last_findings
        last_timestamp=$(echo "$last_run" | jq -r '.timestamp')
        last_findings=$(echo "$last_run" | jq -r '.findings_count')
        print_info "Last run: $last_timestamp ($last_findings findings)"
    else
        print_info "History: no runs yet"
    fi

    echo ""
    return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    cat << 'HELP_EOF'
Review Pulse Helper - Daily Full Codebase AI Review

USAGE:
  review-pulse-helper.sh <command> [options]

COMMANDS:
  run         Run full codebase review via CodeRabbit CLI
  findings    Show findings from latest run
  tasks       Generate task descriptions from findings
  status      Show pulse status and configuration
  history     Show run history
  help        Show this help

RUN OPTIONS:
  --output DIR       Output directory (default: ~/.aidevops/.agent-workspace/work/review-pulse/findings)
  --severity LEVEL   Minimum severity: critical, high, medium (default), low, info
  --dry-run          Show what would happen without running review

FINDINGS OPTIONS:
  --format FORMAT    Output format: text (default), json
  --severity LEVEL   Filter by minimum severity

TASKS OPTIONS:
  --dry-run          Show tasks that would be created
  --auto-dispatch    Attempt to dispatch via supervisor (requires task IDs in TODO.md)

HISTORY OPTIONS:
  --last N           Show last N runs (default: 10)

EXAMPLES:
  # Run daily pulse (medium+ severity)
  review-pulse-helper.sh run

  # Run with high severity filter only
  review-pulse-helper.sh run --severity high

  # View findings as JSON
  review-pulse-helper.sh findings --format json

  # Generate tasks (dry run first)
  review-pulse-helper.sh tasks --dry-run

  # Check status
  review-pulse-helper.sh status

INTEGRATION:
  # Cron (daily at 3 AM)
  0 3 * * * cd /path/to/repo && ~/.aidevops/agents/scripts/review-pulse-helper.sh run

  # GitHub Actions (see .github/workflows/review-pulse.yml)

  # Supervisor integration
  supervisor-helper.sh add t166-pulse --repo "$(pwd)" --description "Review pulse"

SEVERITY LEVELS:
  critical  - Security vulnerabilities, credential exposure
  high      - Bugs, race conditions, memory leaks
  medium    - Performance issues, dead code, complexity (default threshold)
  low       - Style, naming, conventions
  info      - Documentation, suggestions

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
        run)
            local output_dir="$FINDINGS_DIR"
            local severity="medium"
            local dry_run="false"

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --output)
                        [[ -z "${2:-}" || "$2" == --* ]] && { print_error "Missing value for --output"; return 1; }
                        output_dir="$2"; shift 2 ;;
                    --severity)
                        [[ -z "${2:-}" || "$2" == --* ]] && { print_error "Missing value for --severity"; return 1; }
                        severity="$2"; shift 2 ;;
                    --dry-run)    dry_run="true"; shift ;;
                    *)            print_warning "Unknown option: $1"; shift ;;
                esac
            done

            run_review_pulse "$output_dir" "$severity" "$dry_run"
            ;;
        findings)
            local format="text"
            local severity="medium"

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --format)
                        [[ -z "${2:-}" || "$2" == --* ]] && { print_error "Missing value for --format"; return 1; }
                        format="$2"; shift 2 ;;
                    --severity)
                        [[ -z "${2:-}" || "$2" == --* ]] && { print_error "Missing value for --severity"; return 1; }
                        severity="$2"; shift 2 ;;
                    *)            print_warning "Unknown option: $1"; shift ;;
                esac
            done

            show_findings "$format" "$severity"
            ;;
        tasks)
            local dry_run="false"
            local auto_dispatch="false"

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --dry-run)         dry_run="true"; shift ;;
                    --auto-dispatch)   auto_dispatch="true"; shift ;;
                    *)                 shift ;;
                esac
            done

            create_tasks_from_findings "$dry_run" "$auto_dispatch"
            ;;
        status)
            show_status
            ;;
        history)
            local last_n=10

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --last)
                        [[ -z "${2:-}" || "$2" == --* ]] && { print_error "Missing value for --last"; return 1; }
                        last_n="$2"; shift 2 ;;
                    *)       print_warning "Unknown option: $1"; shift ;;
                esac
            done

            show_history "$last_n"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "$ERROR_UNKNOWN_COMMAND $command"
            echo ""
            show_help
            return 1
            ;;
    esac
    return 0
}

main "$@"
