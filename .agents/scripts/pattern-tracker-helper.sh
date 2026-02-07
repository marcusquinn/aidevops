#!/usr/bin/env bash
# pattern-tracker-helper.sh - Track and analyze success/failure patterns
# Extends memory-helper.sh with pattern-specific analysis
#
# Usage:
#   pattern-tracker-helper.sh record --outcome success --task-type "code-review" \
#       --model sonnet --description "Used structured review checklist"
#   pattern-tracker-helper.sh record --outcome failure --task-type "refactor" \
#       --model haiku --description "Haiku missed edge cases in complex refactor"
#   pattern-tracker-helper.sh analyze [--task-type TYPE] [--model MODEL]
#   pattern-tracker-helper.sh suggest "task description"
#   pattern-tracker-helper.sh stats
#   pattern-tracker-helper.sh help

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly SCRIPT_DIR
readonly MEMORY_HELPER="$SCRIPT_DIR/memory-helper.sh"

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Valid task types for pattern tracking
readonly VALID_TASK_TYPES="code-review refactor bugfix feature docs testing deployment security architecture planning research content seo"

# Valid model tiers
readonly VALID_MODELS="haiku flash sonnet pro opus"

#######################################
# Record a success or failure pattern
#######################################
cmd_record() {
    local outcome=""
    local task_type=""
    local model=""
    local description=""
    local tags=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --outcome) outcome="$2"; shift 2 ;;
            --task-type) task_type="$2"; shift 2 ;;
            --model) model="$2"; shift 2 ;;
            --description|--desc) description="$2"; shift 2 ;;
            --tags) tags="$2"; shift 2 ;;
            *)
                if [[ -z "$description" ]]; then
                    description="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate required fields
    if [[ -z "$outcome" ]]; then
        log_error "Outcome required: --outcome success|failure"
        return 1
    fi

    if [[ "$outcome" != "success" && "$outcome" != "failure" ]]; then
        log_error "Outcome must be 'success' or 'failure'"
        return 1
    fi

    if [[ -z "$description" ]]; then
        log_error "Description required: --description \"what happened\""
        return 1
    fi

    # Validate task type if provided
    if [[ -n "$task_type" ]]; then
        local type_pattern=" $task_type "
        if [[ ! " $VALID_TASK_TYPES " =~ $type_pattern ]]; then
            log_warn "Non-standard task type: $task_type (standard: $VALID_TASK_TYPES)"
        fi
    fi

    # Validate model if provided
    if [[ -n "$model" ]]; then
        local model_pattern=" $model "
        if [[ ! " $VALID_MODELS " =~ $model_pattern ]]; then
            log_warn "Non-standard model: $model (standard: $VALID_MODELS)"
        fi
    fi

    # Build memory type
    local memory_type
    if [[ "$outcome" == "success" ]]; then
        memory_type="SUCCESS_PATTERN"
    else
        memory_type="FAILURE_PATTERN"
    fi

    # Build tags
    local all_tags="pattern"
    [[ -n "$task_type" ]] && all_tags="$all_tags,$task_type"
    [[ -n "$model" ]] && all_tags="$all_tags,model:$model"
    [[ -n "$tags" ]] && all_tags="$all_tags,$tags"

    # Build content with structured metadata
    local content="$description"
    [[ -n "$task_type" ]] && content="[task:$task_type] $content"
    [[ -n "$model" ]] && content="$content [model:$model]"

    # Store via memory-helper.sh
    "$MEMORY_HELPER" store \
        --content "$content" \
        --type "$memory_type" \
        --tags "$all_tags" \
        --confidence "high"

    log_success "Recorded $outcome pattern: $description"
    return 0
}

#######################################
# Analyze patterns from memory
#######################################
cmd_analyze() {
    local task_type=""
    local model=""
    local limit=20

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task-type) task_type="$2"; shift 2 ;;
            --model) model="$2"; shift 2 ;;
            --limit|-l) limit="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    echo ""
    echo -e "${CYAN}=== Pattern Analysis ===${NC}"
    echo ""

    # Fetch success patterns
    local success_query="SUCCESS_PATTERN"
    [[ -n "$task_type" ]] && success_query="$success_query task:$task_type"
    [[ -n "$model" ]] && success_query="$success_query model:$model"

    echo -e "${GREEN}Success Patterns:${NC}"
    local success_results
    success_results=$("$MEMORY_HELPER" recall --query "$success_query" --type SUCCESS_PATTERN --limit "$limit" --json 2>/dev/null || echo "[]")

    local success_count
    if command -v jq &>/dev/null; then
        success_count=$(echo "$success_results" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$success_count" -gt 0 ]]; then
            echo "$success_results" | jq -r '.[] | "  + \(.content)"' 2>/dev/null
        else
            echo "  (none recorded)"
        fi
    else
        if [[ "$success_results" != "[]" && -n "$success_results" ]]; then
            echo "$success_results"
        else
            echo "  (none recorded)"
            success_count=0
        fi
    fi

    echo ""

    # Fetch failure patterns
    local failure_query="FAILURE_PATTERN"
    [[ -n "$task_type" ]] && failure_query="$failure_query task:$task_type"
    [[ -n "$model" ]] && failure_query="$failure_query model:$model"

    echo -e "${RED}Failure Patterns:${NC}"
    local failure_results
    failure_results=$("$MEMORY_HELPER" recall --query "$failure_query" --type FAILURE_PATTERN --limit "$limit" --json 2>/dev/null || echo "[]")

    local failure_count
    if command -v jq &>/dev/null; then
        failure_count=$(echo "$failure_results" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$failure_count" -gt 0 ]]; then
            echo "$failure_results" | jq -r '.[] | "  - \(.content)"' 2>/dev/null
        else
            echo "  (none recorded)"
        fi
    else
        if [[ "$failure_results" != "[]" && -n "$failure_results" ]]; then
            echo "$failure_results"
        else
            echo "  (none recorded)"
            failure_count=0
        fi
    fi

    echo ""

    # Summary
    echo -e "${CYAN}Summary:${NC}"
    echo "  Successes: ${success_count:-0}"
    echo "  Failures: ${failure_count:-0}"
    if [[ -n "$task_type" ]]; then
        echo "  Task type: $task_type"
    fi
    if [[ -n "$model" ]]; then
        echo "  Model: $model"
    fi
    echo ""
    return 0
}

#######################################
# Suggest approach based on patterns
#######################################
cmd_suggest() {
    local task_desc="$*"

    if [[ -z "$task_desc" ]]; then
        log_error "Task description required: pattern-tracker-helper.sh suggest \"description\""
        return 1
    fi

    echo ""
    echo -e "${CYAN}=== Pattern Suggestions for: \"$task_desc\" ===${NC}"
    echo ""

    # Search for relevant success patterns
    echo -e "${GREEN}What has worked before:${NC}"
    local success_results
    success_results=$("$MEMORY_HELPER" recall --query "$task_desc" --type SUCCESS_PATTERN --limit 5 --json 2>/dev/null || echo "[]")

    if command -v jq &>/dev/null; then
        local success_count
        success_count=$(echo "$success_results" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$success_count" -gt 0 ]]; then
            echo "$success_results" | jq -r '.[] | "  + \(.content) (score: \(.score // "N/A"))"' 2>/dev/null
        else
            echo "  (no matching success patterns)"
        fi
    else
        echo "  (install jq for formatted output)"
    fi

    echo ""

    # Search for relevant failure patterns
    echo -e "${RED}What to avoid:${NC}"
    local failure_results
    failure_results=$("$MEMORY_HELPER" recall --query "$task_desc" --type FAILURE_PATTERN --limit 5 --json 2>/dev/null || echo "[]")

    if command -v jq &>/dev/null; then
        local failure_count
        failure_count=$(echo "$failure_results" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$failure_count" -gt 0 ]]; then
            echo "$failure_results" | jq -r '.[] | "  - \(.content) (score: \(.score // "N/A"))"' 2>/dev/null
        else
            echo "  (no matching failure patterns)"
        fi
    else
        echo "  (install jq for formatted output)"
    fi

    echo ""
    return 0
}

#######################################
# Show pattern statistics
#######################################
cmd_stats() {
    echo ""
    echo -e "${CYAN}=== Pattern Statistics ===${NC}"
    echo ""

    # Count by type using direct SQLite queries (FTS5 search unreliable for type filtering)
    local memory_db="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}/memory.db"

    if [[ ! -f "$memory_db" ]]; then
        echo "  No memory database found."
        return 0
    fi

    local success_count failure_count
    success_count=$(sqlite3 "$memory_db" "SELECT COUNT(*) FROM learnings WHERE type = 'SUCCESS_PATTERN';" 2>/dev/null || echo "0")
    failure_count=$(sqlite3 "$memory_db" "SELECT COUNT(*) FROM learnings WHERE type = 'FAILURE_PATTERN';" 2>/dev/null || echo "0")

    echo "  Success patterns: $success_count"
    echo "  Failure patterns: $failure_count"
    echo "  Total patterns: $(( success_count + failure_count ))"
    echo ""

    # Show task type breakdown by querying tags directly
    echo "  Task types with patterns:"
    local found_any=false
    for task_type in $VALID_TASK_TYPES; do
        local type_count
        type_count=$(sqlite3 "$memory_db" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'FAILURE_PATTERN') AND tags LIKE '%${task_type}%';" 2>/dev/null || echo "0")
        if [[ "$type_count" -gt 0 ]]; then
            echo "    $task_type: $type_count"
            found_any=true
        fi
    done
    if [[ "$found_any" == false ]]; then
        echo "    (none recorded with task types)"
    fi
    echo ""
    return 0
}

#######################################
# Show help
#######################################
cmd_help() {
    cat <<'EOF'
pattern-tracker-helper.sh - Track and analyze success/failure patterns

USAGE:
    pattern-tracker-helper.sh <command> [options]

COMMANDS:
    record      Record a success or failure pattern
    analyze     Analyze patterns by task type or model
    suggest     Get suggestions based on past patterns for a task
    stats       Show pattern statistics
    help        Show this help

RECORD OPTIONS:
    --outcome <success|failure>   Required: was this a success or failure?
    --task-type <type>            Task category (code-review, refactor, bugfix, etc.)
    --model <tier>                Model used (haiku, flash, sonnet, pro, opus)
    --description <text>          What happened (required)
    --tags <tags>                 Additional comma-separated tags

ANALYZE OPTIONS:
    --task-type <type>            Filter by task type
    --model <tier>                Filter by model tier
    --limit <n>                   Max results per category (default: 20)

VALID TASK TYPES:
    code-review, refactor, bugfix, feature, docs, testing, deployment,
    security, architecture, planning, research, content, seo

EXAMPLES:
    # Record a success
    pattern-tracker-helper.sh record --outcome success \
        --task-type code-review --model sonnet \
        --description "Structured checklist caught 3 bugs"

    # Record a failure
    pattern-tracker-helper.sh record --outcome failure \
        --task-type refactor --model haiku \
        --description "Haiku missed edge cases in complex refactor"

    # Analyze patterns for a task type
    pattern-tracker-helper.sh analyze --task-type bugfix

    # Get suggestions for a new task
    pattern-tracker-helper.sh suggest "refactor the auth middleware"

    # View statistics
    pattern-tracker-helper.sh stats
EOF
    return 0
}

#######################################
# Main entry point
#######################################
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        record) cmd_record "$@" ;;
        analyze) cmd_analyze "$@" ;;
        suggest) cmd_suggest "$@" ;;
        stats) cmd_stats ;;
        help|--help|-h) cmd_help ;;
        *)
            log_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
exit $?
