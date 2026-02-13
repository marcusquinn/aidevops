#!/usr/bin/env bash
# pattern-tracker-helper.sh - Track and analyze success/failure patterns
# Extends memory-helper.sh with pattern-specific analysis and routing decisions
#
# Usage:
#   pattern-tracker-helper.sh record --outcome success --task-type "code-review" \
#       --model sonnet --description "Used structured review checklist"
#   pattern-tracker-helper.sh record --outcome failure --task-type "refactor" \
#       --model haiku --description "Haiku missed edge cases in complex refactor"
#   pattern-tracker-helper.sh analyze [--task-type TYPE] [--model MODEL]
#   pattern-tracker-helper.sh suggest "task description"
#   pattern-tracker-helper.sh recommend --task-type "bugfix"
#   pattern-tracker-helper.sh stats
#   pattern-tracker-helper.sh export [--format json|csv]
#   pattern-tracker-helper.sh report
#   pattern-tracker-helper.sh help

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
init_log_file

readonly SCRIPT_DIR
readonly MEMORY_HELPER="$SCRIPT_DIR/memory-helper.sh"
readonly MEMORY_DB="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}/memory.db"

# All pattern-related memory types (dedicated + supervisor-generated)
# All pattern-related memory types (dedicated + supervisor-generated)
# Use via: local types_sql="$PATTERN_TYPES_SQL" then sqlite3 ... "$types_sql" ...
# Or inline in single-line sqlite3 calls where variable expansion works correctly
PATTERN_TYPES="'SUCCESS_PATTERN','FAILURE_PATTERN','WORKING_SOLUTION','FAILED_APPROACH','ERROR_FIX'"
readonly PATTERN_TYPES

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; return 0; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; return 0; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; return 0; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; return 0; }

# Valid task types for pattern tracking
readonly VALID_TASK_TYPES="code-review refactor bugfix feature docs testing deployment security architecture planning research content seo"

# Valid model tiers
readonly VALID_MODELS="haiku flash sonnet pro opus"

#######################################
# Ensure memory database exists
# Returns 0 if DB exists, 1 if not
#######################################
ensure_db() {
    if [[ ! -f "$MEMORY_DB" ]]; then
        log_warn "No memory database found at: $MEMORY_DB"
        log_info "Run 'memory-helper.sh store' to initialize the database."
        return 1
    fi
    return 0
}

#######################################
# SQL-escape a value (double single quotes)
#######################################
sql_escape() {
    local val="$1"
    echo "${val//\'/\'\'}"
}

#######################################
# Record a success or failure pattern
#######################################
cmd_record() {
    local outcome=""
    local task_type=""
    local model=""
    local description=""
    local tags=""
    local task_id=""
    local duration=""
    local retries=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --outcome) outcome="$2"; shift 2 ;;
            --task-type) task_type="$2"; shift 2 ;;
            --model) model="$2"; shift 2 ;;
            --description|--desc) description="$2"; shift 2 ;;
            --tags) tags="$2"; shift 2 ;;
            --task-id) task_id="$2"; shift 2 ;;
            --duration) duration="$2"; shift 2 ;;
            --retries) retries="$2"; shift 2 ;;
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
        local type_check=" $task_type "
        if [[ ! " $VALID_TASK_TYPES " =~ $type_check ]]; then
            log_warn "Non-standard task type: $task_type (standard: $VALID_TASK_TYPES)"
        fi
    fi

    # Validate model if provided
    if [[ -n "$model" ]]; then
        local model_check=" $model "
        if [[ ! " $VALID_MODELS " =~ $model_check ]]; then
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
    [[ -n "$task_id" ]] && all_tags="$all_tags,$task_id"
    [[ -n "$duration" ]] && all_tags="$all_tags,duration:$duration"
    [[ -n "$retries" ]] && all_tags="$all_tags,retries:$retries"
    [[ -n "$tags" ]] && all_tags="$all_tags,$tags"

    # Build content with structured metadata
    local content="$description"
    [[ -n "$task_type" ]] && content="[task:$task_type] $content"
    [[ -n "$model" ]] && content="$content [model:$model]"
    [[ -n "$task_id" ]] && content="$content [id:$task_id]"
    [[ -n "$duration" ]] && content="$content [duration:${duration}s]"
    [[ -n "$retries" && "$retries" != "0" ]] && content="$content [retries:$retries]"

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
# Uses direct SQLite for reliability
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

    ensure_db || return 0

    echo ""
    echo -e "${CYAN}=== Pattern Analysis ===${NC}"
    echo ""

    # Build WHERE clause for filtering
    local where_success="type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION')"
    local where_failure="type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX')"

    if [[ -n "$task_type" ]]; then
        local escaped_type
        escaped_type=$(sql_escape "$task_type")
        where_success="$where_success AND (tags LIKE '%${escaped_type}%' OR content LIKE '%task:${escaped_type}%')"
        where_failure="$where_failure AND (tags LIKE '%${escaped_type}%' OR content LIKE '%task:${escaped_type}%')"
    fi

    if [[ -n "$model" ]]; then
        local escaped_model
        escaped_model=$(sql_escape "$model")
        where_success="$where_success AND (tags LIKE '%model:${escaped_model}%' OR content LIKE '%model:${escaped_model}%')"
        where_failure="$where_failure AND (tags LIKE '%model:${escaped_model}%' OR content LIKE '%model:${escaped_model}%')"
    fi

    # Success patterns
    echo -e "${GREEN}Success Patterns:${NC}"
    local success_results
    success_results=$(sqlite3 "$MEMORY_DB" "SELECT content FROM learnings WHERE $where_success ORDER BY created_at DESC LIMIT $limit;" 2>/dev/null || echo "")

    if [[ -n "$success_results" ]]; then
        while IFS= read -r line; do
            echo "  + $line"
        done <<< "$success_results"
    else
        echo "  (none recorded)"
    fi

    echo ""

    # Failure patterns
    echo -e "${RED}Failure Patterns:${NC}"
    local failure_results
    failure_results=$(sqlite3 "$MEMORY_DB" "SELECT content FROM learnings WHERE $where_failure ORDER BY created_at DESC LIMIT $limit;" 2>/dev/null || echo "")

    if [[ -n "$failure_results" ]]; then
        while IFS= read -r line; do
            echo "  - $line"
        done <<< "$failure_results"
    else
        echo "  (none recorded)"
    fi

    echo ""

    # Summary counts
    local success_count failure_count
    success_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE $where_success;" 2>/dev/null || echo "0")
    failure_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE $where_failure;" 2>/dev/null || echo "0")

    echo -e "${CYAN}Summary:${NC}"
    echo "  Successes: $success_count"
    echo "  Failures: $failure_count"
    [[ -n "$task_type" ]] && echo "  Task type: $task_type"
    [[ -n "$model" ]] && echo "  Model: $model"
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

    # Search for relevant success patterns via FTS5
    echo -e "${GREEN}What has worked before:${NC}"
    local success_results
    success_results=$("$MEMORY_HELPER" recall --query "$task_desc" --type SUCCESS_PATTERN --limit 5 --json 2>/dev/null || echo "[]")

    # Also search WORKING_SOLUTION (supervisor-generated)
    local working_results
    working_results=$("$MEMORY_HELPER" recall --query "$task_desc" --type WORKING_SOLUTION --limit 3 --json 2>/dev/null || echo "[]")

    local found_success=false
    if command -v jq &>/dev/null; then
        local count
        count=$(echo "$success_results" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$count" -gt 0 ]]; then
            echo "$success_results" | jq -r '.[] | "  + \(.content)"' 2>/dev/null
            found_success=true
        fi
        count=$(echo "$working_results" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$count" -gt 0 ]]; then
            echo "$working_results" | jq -r '.[] | "  + \(.content)"' 2>/dev/null
            found_success=true
        fi
    fi
    if [[ "$found_success" == false ]]; then
        echo "  (no matching success patterns)"
    fi

    echo ""

    # Search for relevant failure patterns
    echo -e "${RED}What to avoid:${NC}"
    local failure_results
    failure_results=$("$MEMORY_HELPER" recall --query "$task_desc" --type FAILURE_PATTERN --limit 5 --json 2>/dev/null || echo "[]")

    local failed_results
    failed_results=$("$MEMORY_HELPER" recall --query "$task_desc" --type FAILED_APPROACH --limit 3 --json 2>/dev/null || echo "[]")

    local found_failure=false
    if command -v jq &>/dev/null; then
        local count
        count=$(echo "$failure_results" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$count" -gt 0 ]]; then
            echo "$failure_results" | jq -r '.[] | "  - \(.content)"' 2>/dev/null
            found_failure=true
        fi
        count=$(echo "$failed_results" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$count" -gt 0 ]]; then
            echo "$failed_results" | jq -r '.[] | "  - \(.content)"' 2>/dev/null
            found_failure=true
        fi
    fi
    if [[ "$found_failure" == false ]]; then
        echo "  (no matching failure patterns)"
    fi

    echo ""

    # Model recommendation based on patterns
    _show_model_hint "$task_desc"

    return 0
}

#######################################
# Recommend model tier based on pattern history
# Queries patterns tagged with model info and calculates success rates
#######################################
cmd_recommend() {
    local task_type=""
    local task_desc=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task-type) task_type="$2"; shift 2 ;;
            *)
                if [[ -z "$task_desc" ]]; then
                    task_desc="$1"
                else
                    task_desc="$task_desc $1"
                fi
                shift
                ;;
        esac
    done

    ensure_db || {
        echo ""
        echo -e "${CYAN}=== Model Recommendation ===${NC}"
        echo ""
        echo "  No pattern data available. Default recommendation: sonnet"
        echo "  Record patterns to enable data-driven routing."
        echo ""
        return 0
    }

    echo ""
    echo -e "${CYAN}=== Model Recommendation ===${NC}"
    echo ""

    # Build filter clause
    local filter=""
    if [[ -n "$task_type" ]]; then
        local escaped_type
        escaped_type=$(sql_escape "$task_type")
        filter="AND (tags LIKE '%${escaped_type}%' OR content LIKE '%task:${escaped_type}%')"
        echo -e "  Task type: ${WHITE}$task_type${NC}"
    fi
    if [[ -n "$task_desc" ]]; then
        echo -e "  Description: ${WHITE}$task_desc${NC}"
    fi
    echo ""

    # Query success/failure counts per model tier
    echo -e "${CYAN}Model Performance (from pattern history):${NC}"
    echo ""
    printf "  %-10s %8s %8s %10s\n" "Model" "Success" "Failure" "Rate"
    printf "  %-10s %8s %8s %10s\n" "-----" "-------" "-------" "----"

    local best_model="" best_rate=0 has_data=false

    for model_tier in $VALID_MODELS; do
        local model_filter="AND (tags LIKE '%model:${model_tier}%' OR content LIKE '%model:${model_tier}%')"

        local successes failures
        successes=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION') $model_filter $filter;" 2>/dev/null || echo "0")
        failures=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX') $model_filter $filter;" 2>/dev/null || echo "0")

        local total=$((successes + failures))
        if [[ "$total" -gt 0 ]]; then
            has_data=true
            local rate
            rate=$(( (successes * 100) / total ))
            printf "  %-10s %8d %8d %9d%%\n" "$model_tier" "$successes" "$failures" "$rate"

            # Track best model (prefer higher success rate, break ties with more data)
            if [[ "$rate" -gt "$best_rate" ]] || { [[ "$rate" -eq "$best_rate" ]] && [[ "$total" -gt 0 ]]; }; then
                best_rate=$rate
                best_model=$model_tier
            fi
        else
            printf "  %-10s %8s %8s %10s\n" "$model_tier" "-" "-" "no data"
        fi
    done

    echo ""

    # Recommendation
    if [[ "$has_data" == true && -n "$best_model" ]]; then
        echo -e "  ${GREEN}Recommended: ${WHITE}$best_model${GREEN} (${best_rate}% success rate)${NC}"

        # Add context about the recommendation
        if [[ "$best_rate" -lt 50 ]]; then
            echo -e "  ${YELLOW}Warning: Low success rate across all models. Consider reviewing task approach.${NC}"
        elif [[ "$best_rate" -lt 75 ]]; then
            echo -e "  ${YELLOW}Note: Moderate success rate. Consider using a higher-tier model for complex tasks.${NC}"
        fi
    else
        echo -e "  ${YELLOW}No pattern data for model comparison. Default: sonnet${NC}"
        echo "  Record patterns with --model flag to enable data-driven routing."
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

    ensure_db || return 0

    # Count by dedicated pattern types
    local success_count failure_count
    success_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type = 'SUCCESS_PATTERN';" 2>/dev/null || echo "0")
    failure_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type = 'FAILURE_PATTERN';" 2>/dev/null || echo "0")

    # Count supervisor-generated patterns
    local working_count failed_count error_count
    working_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type = 'WORKING_SOLUTION' AND tags LIKE '%supervisor%';" 2>/dev/null || echo "0")
    failed_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type = 'FAILED_APPROACH' AND tags LIKE '%supervisor%';" 2>/dev/null || echo "0")
    error_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type = 'ERROR_FIX' AND tags LIKE '%supervisor%';" 2>/dev/null || echo "0")

    echo "  Dedicated patterns:"
    echo "    SUCCESS_PATTERN: $success_count"
    echo "    FAILURE_PATTERN: $failure_count"
    echo ""
    echo "  Supervisor-generated:"
    echo "    WORKING_SOLUTION: $working_count"
    echo "    FAILED_APPROACH: $failed_count"
    echo "    ERROR_FIX: $error_count"
    echo ""

    local total=$(( success_count + failure_count + working_count + failed_count + error_count ))
    echo "  Total trackable patterns: $total"
    echo ""

    # Show task type breakdown
    echo "  Task types with patterns:"
    local found_any=false
    for task_type in $VALID_TASK_TYPES; do
        local type_count
        type_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ($PATTERN_TYPES) AND (tags LIKE '%${task_type}%' OR content LIKE '%task:${task_type}%');" 2>/dev/null || echo "0")
        if [[ "$type_count" -gt 0 ]]; then
            echo "    $task_type: $type_count"
            found_any=true
        fi
    done
    if [[ "$found_any" == false ]]; then
        echo "    (none recorded with task types)"
    fi
    echo ""

    # Show model tier breakdown
    echo "  Model tiers with patterns:"
    local found_model=false
    for model_tier in $VALID_MODELS; do
        local model_count
        model_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ($PATTERN_TYPES) AND (tags LIKE '%model:${model_tier}%' OR content LIKE '%model:${model_tier}%');" 2>/dev/null || echo "0")
        if [[ "$model_count" -gt 0 ]]; then
            echo "    $model_tier: $model_count"
            found_model=true
        fi
    done
    if [[ "$found_model" == false ]]; then
        echo "    (none recorded with model tiers)"
    fi
    echo ""

    # Success rate
    local total_success=$((success_count + working_count))
    local total_failure=$((failure_count + failed_count + error_count))
    local total_all=$((total_success + total_failure))
    if [[ "$total_all" -gt 0 ]]; then
        local overall_rate=$(( (total_success * 100) / total_all ))
        echo "  Overall success rate: ${overall_rate}% ($total_success/$total_all)"
    fi
    echo ""
    return 0
}

#######################################
# Export patterns as JSON or CSV
#######################################
cmd_export() {
    local format="json"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format|-f) format="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    ensure_db || return 1

    # SQL for pattern types (used in queries below)
    local types_sql="'SUCCESS_PATTERN','FAILURE_PATTERN','WORKING_SOLUTION','FAILED_APPROACH','ERROR_FIX'"

    case "$format" in
        json)
            # Use sqlite3 -json for proper JSON output
            local query="SELECT l.id, l.type, l.content, l.tags, l.confidence, l.created_at, COALESCE(a.access_count, 0) as access_count FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.type IN ($types_sql) ORDER BY l.created_at DESC;"
            sqlite3 -json "$MEMORY_DB" "$query" 2>/dev/null || echo "[]"
            ;;
        csv)
            echo "id,type,content,tags,confidence,created_at,access_count"
            local csv_query="SELECT l.id, l.type, l.content, l.tags, l.confidence, l.created_at, COALESCE(a.access_count, 0) FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.type IN ($types_sql) ORDER BY l.created_at DESC;"
            sqlite3 -csv "$MEMORY_DB" "$csv_query" 2>/dev/null
            ;;
        *)
            log_error "Unknown format: $format (use json or csv)"
            return 1
            ;;
    esac
    return 0
}

#######################################
# Generate a summary report of patterns
#######################################
cmd_report() {
    ensure_db || return 0

    echo ""
    echo -e "${CYAN}=== Pattern Tracking Report ===${NC}"
    echo -e "  Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo ""

    # Overall counts
    local total_patterns
    total_patterns=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ($PATTERN_TYPES);" 2>/dev/null || echo "0")
    echo "  Total patterns tracked: $total_patterns"

    if [[ "$total_patterns" -eq 0 ]]; then
        echo ""
        echo "  No patterns recorded yet. Patterns are captured:"
        echo "    - Automatically by the supervisor after task completion"
        echo "    - Manually via: pattern-tracker-helper.sh record ..."
        echo ""
        return 0
    fi

    # Date range
    local oldest newest
    oldest=$(sqlite3 "$MEMORY_DB" "SELECT MIN(created_at) FROM learnings WHERE type IN ($PATTERN_TYPES);" 2>/dev/null || echo "unknown")
    newest=$(sqlite3 "$MEMORY_DB" "SELECT MAX(created_at) FROM learnings WHERE type IN ($PATTERN_TYPES);" 2>/dev/null || echo "unknown")
    echo "  Date range: $oldest to $newest"
    echo ""

    # Success vs failure breakdown
    local success_total failure_total
    success_total=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION');" 2>/dev/null || echo "0")
    failure_total=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX');" 2>/dev/null || echo "0")

    echo -e "  ${GREEN}Successes: $success_total${NC}"
    echo -e "  ${RED}Failures: $failure_total${NC}"

    local total_sf=$((success_total + failure_total))
    if [[ "$total_sf" -gt 0 ]]; then
        local rate=$(( (success_total * 100) / total_sf ))
        echo "  Success rate: ${rate}%"
    fi
    echo ""

    # Top failure reasons (most common failure content patterns)
    echo -e "${RED}Most Common Failure Patterns:${NC}"
    local top_failures
    top_failures=$(sqlite3 "$MEMORY_DB" "
        SELECT content, COUNT(*) as cnt
        FROM learnings
        WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX')
        GROUP BY content
        ORDER BY cnt DESC
        LIMIT 5;
    " 2>/dev/null || echo "")

    if [[ -n "$top_failures" ]]; then
        while IFS='|' read -r content cnt; do
            # Truncate long content
            if [[ ${#content} -gt 80 ]]; then
                content="${content:0:77}..."
            fi
            echo "  ($cnt) $content"
        done <<< "$top_failures"
    else
        echo "  (none)"
    fi
    echo ""

    # Model tier performance
    echo -e "${CYAN}Model Tier Performance:${NC}"
    printf "  %-10s %8s %8s %10s\n" "Model" "Success" "Failure" "Rate"
    printf "  %-10s %8s %8s %10s\n" "-----" "-------" "-------" "----"

    for model_tier in $VALID_MODELS; do
        local model_filter="AND (tags LIKE '%model:${model_tier}%' OR content LIKE '%model:${model_tier}%')"
        local m_success m_failure
        m_success=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION') $model_filter;" 2>/dev/null || echo "0")
        m_failure=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX') $model_filter;" 2>/dev/null || echo "0")

        local m_total=$((m_success + m_failure))
        if [[ "$m_total" -gt 0 ]]; then
            local m_rate=$(( (m_success * 100) / m_total ))
            printf "  %-10s %8d %8d %9d%%\n" "$model_tier" "$m_success" "$m_failure" "$m_rate"
        fi
    done
    echo ""

    # Recent patterns (last 5)
    echo -e "${CYAN}Recent Patterns (last 5):${NC}"
    local recent
    recent=$(sqlite3 -separator '|' "$MEMORY_DB" "
        SELECT type, content, created_at
        FROM learnings
        WHERE type IN ($PATTERN_TYPES)
        ORDER BY created_at DESC
        LIMIT 5;
    " 2>/dev/null || echo "")

    if [[ -n "$recent" ]]; then
        while IFS='|' read -r type content created_at; do
            local icon="?"
            case "$type" in
                SUCCESS_PATTERN|WORKING_SOLUTION) icon="${GREEN}+${NC}" ;;
                FAILURE_PATTERN|FAILED_APPROACH|ERROR_FIX) icon="${RED}-${NC}" ;;
            esac
            # Truncate long content
            if [[ ${#content} -gt 70 ]]; then
                content="${content:0:67}..."
            fi
            echo -e "  $icon $content"
            echo "    ($created_at)"
        done <<< "$recent"
    else
        echo "  (none)"
    fi
    echo ""
    return 0
}

#######################################
# Internal: Show model hint based on pattern data
# Used by suggest command to add routing context
#######################################
_show_model_hint() {
    if ! ensure_db 2>/dev/null; then
        return 0
    fi

    # Check if any patterns have model data
    local model_patterns
    model_patterns=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ($PATTERN_TYPES) AND (tags LIKE '%model:%' OR content LIKE '%model:%');" 2>/dev/null || echo "0")

    if [[ "$model_patterns" -gt 0 ]]; then
        echo -e "${CYAN}Model Routing Hint:${NC}"

        local best_model="" best_rate=0
        for model_tier in $VALID_MODELS; do
            local model_filter="AND (tags LIKE '%model:${model_tier}%' OR content LIKE '%model:${model_tier}%')"
            local m_success m_failure
            m_success=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION') $model_filter;" 2>/dev/null || echo "0")
            m_failure=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX') $model_filter;" 2>/dev/null || echo "0")

            local m_total=$((m_success + m_failure))
            if [[ "$m_total" -gt 2 ]]; then
                local m_rate=$(( (m_success * 100) / m_total ))
                if [[ "$m_rate" -gt "$best_rate" ]]; then
                    best_rate=$m_rate
                    best_model=$model_tier
                fi
            fi
        done

        if [[ -n "$best_model" ]]; then
            echo "  Based on pattern history, $best_model has the highest success rate (${best_rate}%)"
        else
            echo "  Not enough model-tagged patterns for a recommendation yet."
        fi
        echo ""
    fi
    return 0
}

#######################################
# Query model usage from GitHub issue labels (t1010)
# Correlates label data with memory patterns for richer analysis.
# Delegates to supervisor-helper.sh labels for the actual GitHub query,
# then enriches with success rates from the pattern database.
#######################################
cmd_label_stats() {
    local repo_slug="" action_filter="" model_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --repo)
            repo_slug="$2"
            shift 2
            ;;
        --action)
            action_filter="$2"
            shift 2
            ;;
        --model)
            model_filter="$2"
            shift 2
            ;;
        *) shift ;;
        esac
    done

    local supervisor_helper="${SCRIPT_DIR}/supervisor-helper.sh"
    if [[ ! -x "$supervisor_helper" ]]; then
        log_error "supervisor-helper.sh not found at: $supervisor_helper"
        return 1
    fi

    echo -e "${BOLD}Model Usage Analysis${NC} (labels + patterns)"
    echo "════════════════════════════════════════"

    # Get label data from supervisor as JSON
    local label_args=("labels" "--json")
    [[ -n "$repo_slug" ]] && label_args+=("--repo" "$repo_slug")
    [[ -n "$action_filter" ]] && label_args+=("--action" "$action_filter")
    [[ -n "$model_filter" ]] && label_args+=("--model" "$model_filter")

    local label_json
    label_json=$("$supervisor_helper" "${label_args[@]}" 2>/dev/null || echo "[]")

    if [[ "$label_json" == "[]" ]]; then
        echo ""
        echo "No model usage labels found on GitHub issues."
        echo "Labels are added automatically during supervisor dispatch and evaluation."
        echo ""
        echo "Showing memory-based pattern data instead:"
        echo ""
        cmd_report
        return 0
    fi

    # Display label summary
    echo ""
    echo -e "${BOLD}GitHub Issue Labels:${NC}"

    # Parse JSON entries (simple line-by-line since format is known)
    echo "$label_json" | tr ',' '\n' | tr -d '[]{}' | while IFS= read -r line; do
        local label count
        label=$(echo "$line" | grep -o '"label":"[^"]*"' | cut -d'"' -f4 || true)
        count=$(echo "$line" | grep -o '"count":[0-9]*' | cut -d: -f2 || true)
        if [[ -n "$label" && -n "$count" ]]; then
            printf "  %-25s %d issues\n" "$label" "$count"
        fi
    done

    # Enrich with pattern-tracker success rates
    echo ""
    echo -e "${BOLD}Memory Pattern Success Rates:${NC}"

    if ! ensure_db; then
        echo "  (no memory database — pattern data unavailable)"
        return 0
    fi

    for tier in haiku flash sonnet pro opus; do
        if [[ -n "$model_filter" && "$tier" != "$model_filter" ]]; then
            continue
        fi

        local success_count failure_count total rate
        success_count=$(sqlite3 "$MEMORY_DB" \
            "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN','WORKING_SOLUTION') AND (tags LIKE '%model:${tier}%' OR content LIKE '%[model:${tier}]%');" \
            2>/dev/null || echo "0")
        failure_count=$(sqlite3 "$MEMORY_DB" \
            "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN','FAILED_APPROACH','ERROR_FIX') AND (tags LIKE '%model:${tier}%' OR content LIKE '%[model:${tier}]%');" \
            2>/dev/null || echo "0")
        total=$((success_count + failure_count))

        if [[ "$total" -gt 0 ]]; then
            rate=$((success_count * 100 / total))
            printf "  %-10s %d/%d (%d%% success)\n" "$tier" "$success_count" "$total" "$rate"
        fi
    done

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
    recommend   Recommend model tier based on historical success rates
    stats       Show pattern statistics (includes supervisor patterns)
    export      Export patterns as JSON or CSV
    report      Generate a comprehensive pattern report
    label-stats Correlate GitHub issue labels with pattern data (t1010)
    help        Show this help

RECORD OPTIONS:
    --outcome <success|failure>   Required: was this a success or failure?
    --task-type <type>            Task category (code-review, refactor, bugfix, etc.)
    --model <tier>                Model used (haiku, flash, sonnet, pro, opus)
    --description <text>          What happened (required)
    --task-id <id>                Task identifier (e.g., t102.3)
    --duration <seconds>          How long the task took
    --retries <count>             Number of retries before completion
    --tags <tags>                 Additional comma-separated tags

ANALYZE OPTIONS:
    --task-type <type>            Filter by task type
    --model <tier>                Filter by model tier
    --limit <n>                   Max results per category (default: 20)

RECOMMEND OPTIONS:
    --task-type <type>            Filter recommendation by task type

EXPORT OPTIONS:
    --format <json|csv>           Output format (default: json)

VALID TASK TYPES:
    code-review, refactor, bugfix, feature, docs, testing, deployment,
    security, architecture, planning, research, content, seo

EXAMPLES:
    # Record a success with full metadata
    pattern-tracker-helper.sh record --outcome success \
        --task-type code-review --model sonnet --task-id t102.3 \
        --duration 120 --description "Structured checklist caught 3 bugs"

    # Record a failure
    pattern-tracker-helper.sh record --outcome failure \
        --task-type refactor --model haiku \
        --description "Haiku missed edge cases in complex refactor"

    # Get model recommendation for a task type
    pattern-tracker-helper.sh recommend --task-type bugfix

    # Analyze patterns for a task type
    pattern-tracker-helper.sh analyze --task-type bugfix

    # Get suggestions for a new task
    pattern-tracker-helper.sh suggest "refactor the auth middleware"

    # Export patterns as JSON
    pattern-tracker-helper.sh export --format json > patterns.json

    # Generate a report
    pattern-tracker-helper.sh report

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
        recommend) cmd_recommend "$@" ;;
        stats) cmd_stats ;;
        export) cmd_export "$@" ;;
        report) cmd_report ;;
        label-stats) cmd_label_stats "$@" ;;
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
