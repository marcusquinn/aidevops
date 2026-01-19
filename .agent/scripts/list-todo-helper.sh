#!/usr/bin/env bash
# list-todo-helper.sh - Fast task listing with sorting and filtering
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   list-todo-helper.sh [options]
#
# Sorting options:
#   --priority, -p     Sort by priority (high -> medium -> low)
#   --estimate, -e     Sort by time estimate (shortest first)
#   --date, -d         Sort by logged date (newest first)
#   --alpha, -a        Sort alphabetically
#
# Filtering options:
#   --tag, -t TAG      Filter by tag (#seo, #security, etc.)
#   --owner, -o NAME   Filter by assignee (@marcus, etc.)
#   --status STATUS    Filter by status (pending, in-progress, done, plan)
#   --estimate-filter  Filter by estimate (<2h, >1d, 1h-4h)
#
# Grouping options:
#   --group-by, -g BY  Group by: status (default), tag, owner, estimate
#
# Display options:
#   --plans            Include full plan details from PLANS.md
#   --done             Include completed tasks
#   --all              Show everything (pending + done + plans)
#   --compact          One-line per task (no details)
#   --limit N          Limit results
#   --json             Output as JSON
#   --no-color         Disable colors

set -euo pipefail

# Colors (reserved for future terminal output enhancement)
# shellcheck disable=SC2034
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
# shellcheck disable=SC2034
BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' DIM='\033[2m' NC='\033[0m'

# Defaults
SORT_BY="status"
# shellcheck disable=SC2034  # Reserved for future grouping feature
GROUP_BY="status"
FILTER_TAG=""
FILTER_OWNER=""
FILTER_STATUS=""
FILTER_ESTIMATE=""
SHOW_PLANS=false
SHOW_DONE=false
SHOW_ALL=false
COMPACT=false
LIMIT=0
OUTPUT_JSON=false
NO_COLOR=false

# Find project root
find_project_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/TODO.md" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# Parse time estimate to minutes for sorting
parse_estimate_to_minutes() {
    local est="$1"
    local total=0
    
    # Remove ~ prefix
    est="${est#\~}"
    
    # Handle empty
    [[ -z "$est" ]] && echo "0" && return
    
    # Parse days
    if [[ "$est" =~ ([0-9.]+)d ]]; then
        local days="${BASH_REMATCH[1]}"
        total=$(awk "BEGIN {print $total + $days * 480}")
    fi
    
    # Parse hours
    if [[ "$est" =~ ([0-9.]+)h ]]; then
        local hours="${BASH_REMATCH[1]}"
        total=$(awk "BEGIN {print $total + $hours * 60}")
    fi
    
    # Parse minutes
    if [[ "$est" =~ ([0-9.]+)m ]]; then
        local mins="${BASH_REMATCH[1]}"
        total=$(awk "BEGIN {print $total + $mins}")
    fi
    
    printf "%.0f" "$total"
}

# Check if estimate matches filter range
matches_estimate_filter() {
    local est="$1"
    local filter="$2"
    
    [[ -z "$filter" ]] && return 0
    [[ -z "$est" ]] && return 1
    
    local minutes
    minutes=$(parse_estimate_to_minutes "$est")
    
    # Parse filter
    if [[ "$filter" =~ ^\<([0-9]+)([hmd])$ ]]; then
        local val="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        local filter_mins=0
        case "$unit" in
            m) filter_mins=$val ;;
            h) filter_mins=$((val * 60)) ;;
            d) filter_mins=$((val * 480)) ;;
        esac
        [[ $minutes -lt $filter_mins ]] && return 0
    elif [[ "$filter" =~ ^\>([0-9]+)([hmd])$ ]]; then
        local val="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        local filter_mins=0
        case "$unit" in
            m) filter_mins=$val ;;
            h) filter_mins=$((val * 60)) ;;
            d) filter_mins=$((val * 480)) ;;
        esac
        [[ $minutes -gt $filter_mins ]] && return 0
    elif [[ "$filter" =~ ^([0-9]+)([hmd])-([0-9]+)([hmd])$ ]]; then
        local val1="${BASH_REMATCH[1]}"
        local unit1="${BASH_REMATCH[2]}"
        local val2="${BASH_REMATCH[3]}"
        local unit2="${BASH_REMATCH[4]}"
        local min_mins=0 max_mins=0
        case "$unit1" in
            m) min_mins=$val1 ;;
            h) min_mins=$((val1 * 60)) ;;
            d) min_mins=$((val1 * 480)) ;;
        esac
        case "$unit2" in
            m) max_mins=$val2 ;;
            h) max_mins=$((val2 * 60)) ;;
            d) max_mins=$((val2 * 480)) ;;
        esac
        [[ $minutes -ge $min_mins && $minutes -le $max_mins ]] && return 0
    fi
    
    return 1
}

# Parse tasks from TODO.md into structured format
# Output: status|id|desc|est|tags|owner|logged|blocked_by|is_plan
parse_tasks() {
    local todo_file="$1"
    local in_section=""
    local in_code_block=false
    
    while IFS= read -r line; do
        # Track code blocks (skip examples in Format section)
        if [[ "$line" =~ ^\`\`\` ]]; then
            if $in_code_block; then
                in_code_block=false
            else
                in_code_block=true
            fi
            continue
        fi
        $in_code_block && continue
        
        # Track sections
        if [[ "$line" =~ ^##[[:space:]]+(Backlog|In\ Progress|In\ Review|Done|Ready|Declined) ]]; then
            in_section="${BASH_REMATCH[1]}"
            continue
        fi
        
        # Skip Format section entirely
        if [[ "$line" =~ ^##[[:space:]]+Format ]]; then
            in_section="Format"
            continue
        fi
        [[ "$in_section" == "Format" ]] && continue
        
        # Skip non-task lines
        [[ ! "$line" =~ ^[[:space:]]*-\ \[ ]] && continue
        
        # Skip subtasks (indented more than 2 spaces)
        [[ "$line" =~ ^[[:space:]]{4,}- ]] && continue
        
        # Determine status from checkbox
        local status="pending"
        if [[ "$line" =~ \[x\] ]]; then
            status="done"
        elif [[ "$line" =~ \[-\] ]]; then
            status="declined"
        elif [[ "$line" =~ \[\>\] ]]; then
            status="in-progress"
        fi
        
        # Override with section if available
        case "$in_section" in
            "In Progress") status="in-progress" ;;
            "In Review") status="in-review" ;;
            "Done") status="done" ;;
            "Declined") status="declined" ;;
        esac
        
        # Extract task ID
        local task_id=""
        if [[ "$line" =~ (t[0-9]+) ]]; then
            task_id="${BASH_REMATCH[1]}"
        fi
        
        # Extract description - get text after checkbox and ID, before metadata
        local desc=""
        desc=$(echo "$line" | sed 's/^[[:space:]]*- \[[^]]*\][[:space:]]*//' | sed 's/^t[0-9.]*[[:space:]]*//' | sed 's/[[:space:]]*#[^[:space:]].*$//' | sed 's/[[:space:]]*~[^[:space:]].*$//' | sed 's/[[:space:]]*@[^[:space:]].*$//' | sed 's/[[:space:]]*→.*$//' | sed 's/[[:space:]]*logged:.*$//' | sed 's/[[:space:]]*blocked-by:.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Extract estimate
        local est=""
        if [[ "$line" =~ ~([0-9.]+[hmd][^[:space:]]*) ]]; then
            est="~${BASH_REMATCH[1]}"
        fi
        
        # Extract tags
        local tags=""
        tags=$(echo "$line" | grep -oE '#[a-zA-Z0-9_-]+' | tr '\n' ',' | sed 's/,$//' || echo "")
        
        # Extract owner
        local owner=""
        if [[ "$line" =~ @([a-zA-Z0-9_-]+) ]]; then
            owner="@${BASH_REMATCH[1]}"
        fi
        
        # Extract logged date
        local logged=""
        if [[ "$line" =~ logged:([0-9-]+) ]]; then
            logged="${BASH_REMATCH[1]}"
        fi
        
        # Extract blocked-by
        local blocked_by=""
        if [[ "$line" =~ blocked-by:([^[:space:]]+) ]]; then
            blocked_by="${BASH_REMATCH[1]}"
        fi
        
        # Check if it's a plan reference
        local is_plan="false"
        if [[ "$line" =~ \#plan ]] || [[ "$line" =~ →.*PLANS\.md ]]; then
            is_plan="true"
        fi
        
        # Output structured data
        echo "$status|$task_id|$desc|$est|$tags|$owner|$logged|$blocked_by|$is_plan"
        
    done < "$todo_file"
}

# Parse plans from PLANS.md
parse_plans() {
    local plans_file="$1"
    
    [[ ! -f "$plans_file" ]] && return 0
    
    local in_plan=false
    local plan_title=""
    local plan_status=""
    local plan_est=""
    local plan_phase="0"
    local plan_total="0"
    local plan_next=""
    
    while IFS= read -r line; do
        # Detect plan header (### [date] Title)
        if [[ "$line" =~ ^###[[:space:]]+\[([0-9-]+)\][[:space:]]+(.+)$ ]]; then
            # Output previous plan if exists
            if [[ -n "$plan_title" ]]; then
                echo "plan|$plan_title|$plan_status|$plan_est|$plan_phase|$plan_total|$plan_next"
            fi
            plan_title="${BASH_REMATCH[2]}"
            # Remove trailing markers like ✓
            plan_title="${plan_title% ✓}"
            plan_status="Planning"
            plan_est=""
            plan_phase="0"
            plan_total="0"
            plan_next=""
            in_plan=true
            continue
        fi
        
        # Parse plan metadata
        if $in_plan; then
            if [[ "$line" =~ ^\*\*Status:\*\*[[:space:]]+(.+)$ ]]; then
                plan_status="${BASH_REMATCH[1]}"
                # Extract phase info if present
                if [[ "$plan_status" =~ \(Phase[[:space:]]+([0-9]+)/([0-9]+)\) ]]; then
                    plan_phase="${BASH_REMATCH[1]}"
                    plan_total="${BASH_REMATCH[2]}"
                elif [[ "$plan_status" =~ Completed ]]; then
                    plan_status="Completed"
                fi
            elif [[ "$line" =~ ^\*\*Estimate:\*\*[[:space:]]+(.+)$ ]]; then
                plan_est="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^-\ \[\ \].*Phase[[:space:]]+([0-9]+):(.+) ]] && [[ -z "$plan_next" ]]; then
                plan_next="Phase ${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
                # Trim estimate from next phase and whitespace
                plan_next=$(echo "$plan_next" | sed 's/~[0-9.]*[hmd].*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            fi
        fi
        
        # Detect section change (end of active plans)
        if [[ "$line" =~ ^##[[:space:]]+(Completed|Archived)[[:space:]]+Plans ]]; then
            in_plan=false
        fi
        
    done < "$plans_file"
    
    # Output last plan
    if [[ -n "$plan_title" ]] && [[ "$plan_status" != "Completed" ]]; then
        echo "plan|$plan_title|$plan_status|$plan_est|$plan_phase|$plan_total|$plan_next"
    fi
}

# Apply filters to task line
apply_filters() {
    local line="$1"
    
    IFS='|' read -r status id desc est tags owner logged blocked_by is_plan <<< "$line"
    
    # Status filter
    if [[ -n "$FILTER_STATUS" ]]; then
        [[ "$status" != "$FILTER_STATUS" ]] && return 1
    fi
    
    # Tag filter (case insensitive, literal substring match)
    if [[ -n "$FILTER_TAG" ]]; then
        local tag_lower
        local tags_lower
        tag_lower=$(echo "$FILTER_TAG" | tr '[:upper:]' '[:lower:]')
        tags_lower=$(echo "$tags" | tr '[:upper:]' '[:lower:]')
        # Use literal substring match, not regex
        [[ "$tags_lower" != *"$tag_lower"* ]] && return 1
    fi
    
    # Owner filter
    if [[ -n "$FILTER_OWNER" ]]; then
        local owner_check="@${FILTER_OWNER#@}"
        [[ "$owner" != "$owner_check" ]] && return 1
    fi
    
    # Estimate filter
    if [[ -n "$FILTER_ESTIMATE" ]]; then
        matches_estimate_filter "$est" "$FILTER_ESTIMATE" || return 1
    fi
    
    # Skip done unless requested
    if [[ "$status" == "done" || "$status" == "declined" ]]; then
        $SHOW_DONE || $SHOW_ALL || return 1
    fi
    
    return 0
}

# Sort tasks
sort_tasks() {
    local sort_by="$1"
    
    case "$sort_by" in
        priority)
            # Sort by tags containing priority keywords (high priority tags first)
            # #security, #bugfix, #critical come before others
            while IFS= read -r line; do
                local tags
                tags=$(echo "$line" | cut -d'|' -f5)
                local priority=3
                [[ "$tags" =~ (security|critical|urgent|bugfix|hotfix) ]] && priority=1
                [[ "$tags" =~ (feature|enhancement) ]] && priority=2
                echo "$priority|$line"
            done | sort -t'|' -k1,1n | cut -d'|' -f2-
            ;;
        estimate)
            # Sort by estimate (shortest first)
            while IFS= read -r line; do
                local est
                est=$(echo "$line" | cut -d'|' -f4)
                local mins
                mins=$(parse_estimate_to_minutes "$est")
                printf "%010d|%s\n" "$mins" "$line"
            done | sort -t'|' -k1,1n | cut -d'|' -f2-
            ;;
        date)
            # Sort by logged date (newest first)
            sort -t'|' -k7,7r
            ;;
        alpha)
            # Sort alphabetically by description
            sort -t'|' -k3,3
            ;;
        *)
            # Default: by status (in-progress first, then pending)
            while IFS= read -r line; do
                local status
                status=$(echo "$line" | cut -d'|' -f1)
                local order=3
                case "$status" in
                    in-progress) order=1 ;;
                    in-review) order=2 ;;
                    pending) order=3 ;;
                    done) order=4 ;;
                    declined) order=5 ;;
                esac
                echo "$order|$line"
            done | sort -t'|' -k1,1n | cut -d'|' -f2-
            ;;
    esac
}

# Output as markdown
output_markdown() {
    local tasks_file="$1"
    local plans_file="$2"
    
    local in_progress_count=0
    local pending_count=0
    local done_count=0
    local plan_count=0
    local blocked_count=0
    
    # Count tasks
    while IFS='|' read -r status id desc est tags owner logged blocked_by is_plan; do
        case "$status" in
            in-progress|in-review) ((in_progress_count++)) ;;
            pending) 
                ((pending_count++))
                [[ -n "$blocked_by" ]] && ((blocked_count++))
                ;;
            done) ((done_count++)) ;;
        esac
    done < "$tasks_file"
    
    # Count plans
    if [[ -f "$plans_file" ]] && [[ -s "$plans_file" ]]; then
        plan_count=$(wc -l < "$plans_file" | xargs)
    fi
    
    # Header
    echo "## Tasks Overview"
    echo ""
    
    # In Progress section
    echo "### In Progress ($in_progress_count)"
    echo ""
    
    local has_in_progress=false
    while IFS='|' read -r status id desc est tags owner logged blocked_by is_plan; do
        if [[ "$status" == "in-progress" || "$status" == "in-review" ]]; then
            has_in_progress=true
            break
        fi
    done < "$tasks_file"
    
    if $has_in_progress; then
        if $COMPACT; then
            while IFS='|' read -r status id desc est tags owner logged blocked_by is_plan; do
                [[ "$status" != "in-progress" && "$status" != "in-review" ]] && continue
                echo "- $id: $desc ${est:+$est} ${tags:+$tags}"
            done < "$tasks_file"
        else
            echo "| # | ID | Task | Est | Tags | Owner |"
            echo "|---|-----|------|-----|------|-------|"
            local num=0
            while IFS='|' read -r status id desc est tags owner logged blocked_by is_plan; do
                [[ "$status" != "in-progress" && "$status" != "in-review" ]] && continue
                ((num++))
                echo "| $num | $id | $desc | $est | $tags | ${owner:--} |"
            done < "$tasks_file"
        fi
    else
        echo "*No tasks currently in progress*"
    fi
    echo ""
    echo "---"
    echo ""
    
    # Backlog section
    echo "### Backlog ($pending_count pending)"
    echo ""
    
    if $COMPACT; then
        local num=0
        while IFS='|' read -r status id desc est tags owner logged blocked_by is_plan; do
            [[ "$status" != "pending" ]] && continue
            ((num++))
            [[ $LIMIT -gt 0 && $num -gt $LIMIT ]] && break
            local blocked_marker=""
            [[ -n "$blocked_by" ]] && blocked_marker=" [BLOCKED by $blocked_by]"
            echo "- $id: $desc ${est:+$est} ${tags:+$tags}$blocked_marker"
        done < "$tasks_file"
    else
        echo "| # | ID | Task | Est | Tags | Owner | Logged |"
        echo "|---|-----|------|-----|------|-------|--------|"
        local num=0
        while IFS='|' read -r status id desc est tags owner logged blocked_by is_plan; do
            [[ "$status" != "pending" ]] && continue
            ((num++))
            [[ $LIMIT -gt 0 && $num -gt $LIMIT ]] && break
            echo "| $num | $id | $desc | $est | $tags | ${owner:--} | $logged |"
        done < "$tasks_file"
    fi
    
    # Show blocked tasks
    if [[ $blocked_count -gt 0 ]]; then
        echo ""
        echo "**Blocked tasks** ($blocked_count):"
        while IFS='|' read -r status id desc est tags owner logged blocked_by is_plan; do
            [[ "$status" != "pending" ]] && continue
            [[ -z "$blocked_by" ]] && continue
            echo "- $id blocked-by:$blocked_by"
        done < "$tasks_file"
    fi
    
    echo ""
    echo "---"
    echo ""
    
    # Plans section
    if $SHOW_PLANS || $SHOW_ALL; then
        echo "### Plans ($plan_count active)"
        echo ""
        
        if [[ -f "$plans_file" ]] && [[ -s "$plans_file" ]]; then
            echo "| Plan | Status | Est | Next Phase |"
            echo "|------|--------|-----|------------|"
            while IFS='|' read -r type title status est phase total next; do
                [[ "$type" != "plan" ]] && continue
                local status_display="$status"
                [[ "$phase" != "0" && "$total" != "0" ]] && status_display="$status ($phase/$total)"
                echo "| **$title** | $status_display | $est | $next |"
            done < "$plans_file"
        else
            echo "*No active plans*"
        fi
        echo ""
        echo "---"
        echo ""
    fi
    
    # Done section
    if $SHOW_DONE || $SHOW_ALL; then
        echo "### Done ($done_count completed)"
        echo ""
        
        if $COMPACT; then
            while IFS='|' read -r status id desc est tags owner logged blocked_by is_plan; do
                [[ "$status" != "done" ]] && continue
                echo "- $id: $desc ${est:+$est}"
            done < "$tasks_file"
        else
            echo "| ID | Task | Est | Completed |"
            echo "|----|------|-----|-----------|"
            while IFS='|' read -r status id desc est tags owner logged blocked_by is_plan; do
                [[ "$status" != "done" ]] && continue
                echo "| $id | $desc | $est | $logged |"
            done < "$tasks_file"
        fi
        echo ""
        echo "---"
        echo ""
    fi
    
    # Summary
    echo "**Summary:** $pending_count pending | $in_progress_count in progress | $done_count done | $plan_count active plans"
    echo ""
    echo "---"
    echo ""
    echo "**Options:**"
    echo "1. Work on a specific task (enter task ID like \`t014\` or number)"
    echo "2. Filter/sort differently (e.g., \`--priority\`, \`-t seo\`, \`--estimate-filter \"<2h\"\`)"
    echo "3. Done browsing"
}

# Escape string for JSON output
json_escape() {
    local str="$1"
    # Escape backslash first, then other special chars
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "$str"
}

# Output as JSON
output_json() {
    local tasks_file="$1"
    local plans_file="$2"
    
    echo "{"
    
    # In Progress
    echo '  "in_progress": ['
    local first=true
    while IFS='|' read -r status id desc est tags owner logged blocked_by is_plan; do
        [[ "$status" != "in-progress" && "$status" != "in-review" ]] && continue
        $first || echo ","
        first=false
        desc=$(json_escape "$desc")
        tags=$(json_escape "$tags")
        owner=$(json_escape "$owner")
        printf '    {"id":"%s","desc":"%s","est":"%s","tags":"%s","owner":"%s"}' "$id" "$desc" "$est" "$tags" "$owner"
    done < "$tasks_file"
    echo ""
    echo "  ],"
    
    # Backlog
    echo '  "backlog": ['
    first=true
    while IFS='|' read -r status id desc est tags owner logged blocked_by is_plan; do
        [[ "$status" != "pending" ]] && continue
        $first || echo ","
        first=false
        desc=$(json_escape "$desc")
        tags=$(json_escape "$tags")
        owner=$(json_escape "$owner")
        printf '    {"id":"%s","desc":"%s","est":"%s","tags":"%s","owner":"%s","logged":"%s","blocked_by":"%s"}' "$id" "$desc" "$est" "$tags" "$owner" "$logged" "$blocked_by"
    done < "$tasks_file"
    echo ""
    echo "  ],"
    
    # Plans
    echo '  "plans": ['
    first=true
    if [[ -f "$plans_file" ]]; then
        while IFS='|' read -r type title status est phase total next; do
            [[ "$type" != "plan" ]] && continue
            $first || echo ","
            first=false
            title=$(json_escape "$title")
            status=$(json_escape "$status")
            next=$(json_escape "$next")
            printf '    {"title":"%s","status":"%s","est":"%s","phase":%s,"total":%s,"next":"%s"}' "$title" "$status" "$est" "${phase:-0}" "${total:-0}" "$next"
        done < "$plans_file"
    fi
    echo ""
    echo "  ],"
    
    # Done
    echo '  "done": ['
    first=true
    while IFS='|' read -r status id desc est tags owner logged blocked_by is_plan; do
        [[ "$status" != "done" ]] && continue
        $first || echo ","
        first=false
        desc=$(json_escape "$desc")
        printf '    {"id":"%s","desc":"%s","est":"%s","completed":"%s"}' "$id" "$desc" "$est" "$logged"
    done < "$tasks_file"
    echo ""
    echo "  ]"
    
    echo "}"
}

# Show help
show_help() {
    cat << 'EOF'
Usage: list-todo-helper.sh [options]

Sorting:
  --priority, -p     Sort by priority (security/bugfix first)
  --estimate, -e     Sort by time estimate (shortest first)
  --date, -d         Sort by logged date (newest first)
  --alpha, -a        Sort alphabetically

Filtering:
  --tag, -t TAG      Filter by tag (seo, security, etc.)
  --owner, -o NAME   Filter by assignee (marcus, etc.)
  --status STATUS    Filter by status (pending, in-progress, done)
  --estimate-filter  Filter by estimate (<2h, >1d, 1h-4h)

Display:
  --plans            Include plan details from PLANS.md
  --done             Include completed tasks
  --all              Show everything (pending + done + plans)
  --compact          One-line per task (no tables)
  --limit N          Limit results
  --json             Output as JSON
  --no-color         Disable colors

Examples:
  list-todo-helper.sh                    # All pending, grouped by status
  list-todo-helper.sh --priority         # Sorted by priority
  list-todo-helper.sh -t seo             # Only #seo tasks
  list-todo-helper.sh -o marcus -e       # Marcus's tasks, shortest first
  list-todo-helper.sh --estimate-filter "<2h"  # Quick wins under 2 hours
  list-todo-helper.sh --plans            # Include plan details
  list-todo-helper.sh --all --compact    # Everything, one line each
EOF
}

# Require argument for option
require_arg() {
    local opt="$1"
    local val="$2"
    if [[ -z "$val" || "$val" == -* ]]; then
        echo "ERROR: Option $opt requires an argument" >&2
        exit 1
    fi
}

# Main
main() {
    # Parse command line
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --priority|-p) SORT_BY="priority" ;;
            --estimate|-e) SORT_BY="estimate" ;;
            --date|-d) SORT_BY="date" ;;
            --alpha|-a) SORT_BY="alpha" ;;
            --tag|-t) require_arg "$1" "${2:-}"; FILTER_TAG="$2"; shift ;;
            --owner|-o) require_arg "$1" "${2:-}"; FILTER_OWNER="$2"; shift ;;
            --status) require_arg "$1" "${2:-}"; FILTER_STATUS="$2"; shift ;;
            --estimate-filter) require_arg "$1" "${2:-}"; FILTER_ESTIMATE="$2"; shift ;;
            --group-by|-g) require_arg "$1" "${2:-}"; GROUP_BY="$2"; shift ;;  # Reserved for future grouping feature (SC2034 expected)
            --plans) SHOW_PLANS=true ;;
            --done) SHOW_DONE=true ;;
            --all) SHOW_ALL=true ;;
            --compact) COMPACT=true ;;
            --limit) 
                require_arg "$1" "${2:-}"
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    echo "ERROR: --limit requires a numeric value" >&2
                    exit 1
                fi
                LIMIT="$2"; shift 
                ;;
            --json) OUTPUT_JSON=true ;;
            --no-color) NO_COLOR=true ;;
            --help|-h) show_help; exit 0 ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
        shift
    done
    
    # Disable colors if requested or not a terminal
    # shellcheck disable=SC2034
    if $NO_COLOR || [[ ! -t 1 ]]; then
        RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" DIM="" NC=""
    fi
    
    # Find project
    local project_root
    project_root=$(find_project_root) || {
        echo "ERROR: Not in a project directory (no TODO.md found)" >&2
        exit 1
    }
    
    local todo_file="$project_root/TODO.md"
    local plans_file="$project_root/todo/PLANS.md"
    
    # Create temp files
    local tasks_tmp
    local plans_tmp
    tasks_tmp=$(mktemp)
    plans_tmp=$(mktemp)
    # Use explicit paths in trap since local vars aren't accessible
    # shellcheck disable=SC2064
    trap "rm -f '$tasks_tmp' '$plans_tmp'" EXIT
    
    # Parse and filter tasks
    parse_tasks "$todo_file" | while IFS= read -r line; do
        if apply_filters "$line"; then
            echo "$line"
        fi
    done | sort_tasks "$SORT_BY" > "$tasks_tmp"
    
    # Parse plans
    parse_plans "$plans_file" > "$plans_tmp"
    
    # Output
    if $OUTPUT_JSON; then
        output_json "$tasks_tmp" "$plans_tmp"
    else
        output_markdown "$tasks_tmp" "$plans_tmp"
    fi
}

main "$@"
