#!/usr/bin/env bash
# show-plan-helper.sh - Display detailed plan information
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   show-plan-helper.sh [plan-name|plan-id]
#   show-plan-helper.sh --current     # Show plan for current branch
#   show-plan-helper.sh --list        # List all plans briefly
#
# Options:
#   --json             Output as JSON
#   --no-color         Disable colors

set -euo pipefail

# Colors (reserved for future terminal output enhancement)
# shellcheck disable=SC2034
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
# shellcheck disable=SC2034
BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' DIM='\033[2m' NC='\033[0m'

# Options
OUTPUT_JSON=false
NO_COLOR=false
SHOW_CURRENT=false
LIST_ONLY=false
PLAN_QUERY=""

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

# Extract a plan section from PLANS.md
# Returns the full plan content between ### headers
extract_plan() {
    local plans_file="$1"
    local query="$2"
    local query_lower
    query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')
    
    local in_plan=false
    local found=false
    local plan_content=""
    local current_title=""
    
    while IFS= read -r line; do
        # Detect plan header
        if [[ "$line" =~ ^###[[:space:]]+\[([0-9-]+)\][[:space:]]+(.+)$ ]]; then
            # If we were in a matching plan, we're done
            if $found; then
                break
            fi
            
            current_title="${BASH_REMATCH[2]}"
            current_title="${current_title% ✓}"
            local title_lower
            title_lower=$(echo "$current_title" | tr '[:upper:]' '[:lower:]')
            
            # Check if this matches our query
            if [[ "$title_lower" == *"$query_lower"* ]] || [[ "$query" =~ ^p[0-9]+$ ]]; then
                # For plan ID, we need to check the TOON block
                if [[ "$query" =~ ^p[0-9]+$ ]]; then
                    in_plan=true
                    plan_content="$line"$'\n'
                else
                    found=true
                    in_plan=true
                    plan_content="$line"$'\n'
                fi
            else
                in_plan=false
            fi
            continue
        fi
        
        # Check for plan ID in TOON block
        if $in_plan && [[ "$query" =~ ^p[0-9]+$ ]] && [[ "$line" =~ TOON:plan.*$query ]]; then
            found=true
        fi
        
        # Detect section change (end of plans)
        if [[ "$line" =~ ^##[[:space:]]+(Completed|Archived|Format)[[:space:]]+ ]]; then
            if $found; then
                break
            fi
            in_plan=false
            continue
        fi
        
        # Accumulate content if in matching plan
        if $in_plan; then
            plan_content+="$line"$'\n'
        fi
        
    done < "$plans_file"
    
    if $found; then
        echo "$plan_content"
        return 0
    fi
    
    return 1
}

# Parse plan content into structured data
parse_plan_content() {
    local content="$1"
    
    local title=""
    local status=""
    local estimate=""
    local phase="0"
    local total_phases="0"
    local purpose=""
    local in_purpose=false
    local progress=""
    local in_progress=false
    local decisions=""
    local in_decisions=false
    local discoveries=""
    local in_discoveries=false
    local context=""
    local in_context=false
    
    while IFS= read -r line; do
        # Title
        if [[ "$line" =~ ^###[[:space:]]+\[([0-9-]+)\][[:space:]]+(.+)$ ]]; then
            title="${BASH_REMATCH[2]}"
            title="${title% ✓}"
            continue
        fi
        
        # Status
        if [[ "$line" =~ ^\*\*Status:\*\*[[:space:]]+(.+)$ ]]; then
            status="${BASH_REMATCH[1]}"
            if [[ "$status" =~ \(Phase[[:space:]]+([0-9]+)/([0-9]+)\) ]]; then
                phase="${BASH_REMATCH[1]}"
                total_phases="${BASH_REMATCH[2]}"
            fi
            continue
        fi
        
        # Estimate
        if [[ "$line" =~ ^\*\*Estimate:\*\*[[:space:]]+(.+)$ ]]; then
            estimate="${BASH_REMATCH[1]}"
            continue
        fi
        
        # Section headers
        if [[ "$line" =~ ^####[[:space:]]+Purpose ]]; then
            in_purpose=true
            in_progress=false
            in_decisions=false
            in_discoveries=false
            in_context=false
            continue
        fi
        
        if [[ "$line" =~ ^####[[:space:]]+Progress ]]; then
            in_purpose=false
            in_progress=true
            in_decisions=false
            in_discoveries=false
            in_context=false
            continue
        fi
        
        if [[ "$line" =~ ^####[[:space:]]+Decision ]]; then
            in_purpose=false
            in_progress=false
            in_decisions=true
            in_discoveries=false
            in_context=false
            continue
        fi
        
        if [[ "$line" =~ ^####[[:space:]]+(Surprises|Discoveries) ]]; then
            in_purpose=false
            in_progress=false
            in_decisions=false
            in_discoveries=true
            in_context=false
            continue
        fi
        
        if [[ "$line" =~ ^####[[:space:]]+Context ]]; then
            in_purpose=false
            in_progress=false
            in_decisions=false
            in_discoveries=false
            in_context=true
            continue
        fi
        
        # Skip TOON blocks
        [[ "$line" =~ ^\<\!--TOON ]] && continue
        [[ "$line" =~ ^--\> ]] && continue
        
        # Accumulate content
        if $in_purpose && [[ -n "$line" ]]; then
            purpose+="$line"$'\n'
        fi
        if $in_progress && [[ "$line" =~ ^-\ \[ ]]; then
            progress+="$line"$'\n'
        fi
        if $in_decisions && [[ "$line" =~ ^-\ \*\*Decision ]]; then
            decisions+="$line"$'\n'
        fi
        if $in_discoveries && [[ "$line" =~ ^-\ \*\*Observation ]]; then
            discoveries+="$line"$'\n'
        fi
        if $in_context && [[ -n "$line" ]]; then
            context+="$line"$'\n'
        fi
        
    done <<< "$content"
    
    # Output as pipe-delimited for easy parsing
    echo "TITLE|$title"
    echo "STATUS|$status"
    echo "ESTIMATE|$estimate"
    echo "PHASE|$phase"
    echo "TOTAL_PHASES|$total_phases"
    echo "PURPOSE|${purpose//$'\n'/\\n}"
    echo "PROGRESS|${progress//$'\n'/\\n}"
    echo "DECISIONS|${decisions//$'\n'/\\n}"
    echo "DISCOVERIES|${discoveries//$'\n'/\\n}"
    echo "CONTEXT|${context//$'\n'/\\n}"
}

# Get related tasks from TODO.md
get_related_tasks() {
    local todo_file="$1"
    local plan_title="$2"
    local plan_title_lower
    plan_title_lower=$(echo "$plan_title" | tr '[:upper:]' '[:lower:]')
    
    # Create a slug from the title for matching
    local slug
    slug=$(echo "$plan_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g')
    
    while IFS= read -r line; do
        # Look for tasks that reference this plan
        if [[ "$line" =~ ^[[:space:]]*-\ \[ ]] && [[ "$line" =~ \#plan ]]; then
            local line_lower
            line_lower=$(echo "$line" | tr '[:upper:]' '[:lower:]')
            if [[ "$line_lower" == *"$plan_title_lower"* ]] || [[ "$line" == *"$slug"* ]]; then
                # Extract task ID and description
                local task_id=""
                if [[ "$line" =~ (t[0-9]+) ]]; then
                    task_id="${BASH_REMATCH[1]}"
                fi
                local desc
                desc=$(echo "$line" | sed 's/^[[:space:]]*- \[[^]]*\][[:space:]]*//' | sed 's/^t[0-9.]*[[:space:]]*//' | cut -d'#' -f1 | xargs)
                echo "$task_id|$desc"
            fi
        fi
    done < "$todo_file"
}

# Output plan as markdown
output_markdown() {
    local plans_file="$1"
    local todo_file="$2"
    local query="$3"
    
    local content
    content=$(extract_plan "$plans_file" "$query") || {
        echo "ERROR: Plan not found: $query" >&2
        echo "" >&2
        echo "Available plans:" >&2
        list_plans "$plans_file"
        return 1
    }
    
    # Parse the content
    local title="" status="" estimate="" phase="" total_phases=""
    local purpose="" progress="" decisions="" discoveries="" context=""
    
    while IFS='|' read -r key value; do
        case "$key" in
            TITLE) title="$value" ;;
            STATUS) status="$value" ;;
            ESTIMATE) estimate="$value" ;;
            PHASE) phase="$value" ;;
            TOTAL_PHASES) total_phases="$value" ;;
            PURPOSE) purpose="${value//\\n/$'\n'}" ;;
            PROGRESS) progress="${value//\\n/$'\n'}" ;;
            DECISIONS) decisions="${value//\\n/$'\n'}" ;;
            DISCOVERIES) discoveries="${value//\\n/$'\n'}" ;;
            CONTEXT) context="${value//\\n/$'\n'}" ;;
        esac
    done < <(parse_plan_content "$content")
    
    # Output formatted plan
    echo "# $title"
    echo ""
    echo "**Status:** $status"
    echo "**Estimate:** $estimate"
    [[ "$phase" != "0" ]] && echo "**Progress:** Phase $phase of $total_phases"
    echo ""
    
    if [[ -n "$purpose" ]]; then
        echo "## Purpose"
        echo ""
        echo "$purpose"
    fi
    
    if [[ -n "$progress" ]]; then
        echo "## Progress"
        echo ""
        echo "$progress"
    fi
    
    if [[ -n "$context" ]]; then
        echo "## Context"
        echo ""
        echo "$context"
    fi
    
    if [[ -n "$decisions" ]]; then
        echo "## Decisions"
        echo ""
        echo "$decisions"
    fi
    
    if [[ -n "$discoveries" ]]; then
        echo "## Discoveries"
        echo ""
        echo "$discoveries"
    fi
    
    # Related tasks
    echo "## Related Tasks"
    echo ""
    local has_tasks=false
    while IFS='|' read -r task_id desc; do
        [[ -z "$task_id" ]] && continue
        has_tasks=true
        echo "- $task_id: $desc"
    done < <(get_related_tasks "$todo_file" "$title")
    
    if ! $has_tasks; then
        echo "*No related tasks found*"
    fi
    
    echo ""
    echo "---"
    echo ""
    echo "**Options:**"
    echo "1. Start working on this plan"
    echo "2. View another plan"
    echo "3. Back to task list (\`/list-todo\`)"
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

# Output plan as JSON
output_json() {
    local plans_file="$1"
    local todo_file="$2"
    local query="$3"
    
    local content
    content=$(extract_plan "$plans_file" "$query") || {
        echo '{"error": "Plan not found"}'
        return 1
    }
    
    local title="" status="" estimate="" phase="" total_phases=""
    local purpose="" progress="" decisions="" discoveries="" context=""
    
    while IFS='|' read -r key value; do
        case "$key" in
            TITLE) title="$value" ;;
            STATUS) status="$value" ;;
            ESTIMATE) estimate="$value" ;;
            PHASE) phase="$value" ;;
            TOTAL_PHASES) total_phases="$value" ;;
            PURPOSE) purpose="$value" ;;
            PROGRESS) progress="$value" ;;
            DECISIONS) decisions="$value" ;;
            DISCOVERIES) discoveries="$value" ;;
            CONTEXT) context="$value" ;;
        esac
    done < <(parse_plan_content "$content")
    
    # Escape for JSON
    title=$(json_escape "$title")
    status=$(json_escape "$status")
    estimate=$(json_escape "$estimate")
    purpose=$(json_escape "$purpose")
    progress=$(json_escape "$progress")
    decisions=$(json_escape "$decisions")
    discoveries=$(json_escape "$discoveries")
    context=$(json_escape "$context")
    
    # Handle empty numeric fields
    [[ -z "$phase" ]] && phase=0
    [[ -z "$total_phases" ]] && total_phases=0
    
    cat << EOF
{
  "title": "$title",
  "status": "$status",
  "estimate": "$estimate",
  "phase": $phase,
  "total_phases": $total_phases,
  "purpose": "$purpose",
  "progress": "$progress",
  "decisions": "$decisions",
  "discoveries": "$discoveries",
  "context": "$context",
  "related_tasks": [
EOF
    
    local first=true
    while IFS='|' read -r task_id desc; do
        [[ -z "$task_id" ]] && continue
        $first || echo ","
        first=false
        desc=$(json_escape "$desc")
        printf '    {"id": "%s", "desc": "%s"}' "$task_id" "$desc"
    done < <(get_related_tasks "$todo_file" "$title")
    
    echo ""
    echo "  ]"
    echo "}"
}

# List all plans briefly
list_plans() {
    local plans_file="$1"
    
    [[ ! -f "$plans_file" ]] && {
        echo "No PLANS.md found"
        return 1
    }
    
    echo "| # | Plan | Status | Estimate |"
    echo "|---|------|--------|----------|"
    
    local num=0
    local in_active=true
    
    while IFS= read -r line; do
        # Stop at completed/archived sections
        if [[ "$line" =~ ^##[[:space:]]+(Completed|Archived) ]]; then
            in_active=false
            continue
        fi
        
        # Only process active plans
        $in_active || continue
        
        # Detect plan header
        if [[ "$line" =~ ^###[[:space:]]+\[([0-9-]+)\][[:space:]]+(.+)$ ]]; then
            ((num++))
            local title="${BASH_REMATCH[2]}"
            title="${title% ✓}"
            local status=""
            local estimate=""
            
            # Read next few lines for status and estimate
            while IFS= read -r meta_line; do
                if [[ "$meta_line" =~ ^\*\*Status:\*\*[[:space:]]+(.+)$ ]]; then
                    status="${BASH_REMATCH[1]}"
                elif [[ "$meta_line" =~ ^\*\*Estimate:\*\*[[:space:]]+(.+)$ ]]; then
                    estimate="${BASH_REMATCH[1]}"
                    break
                elif [[ "$meta_line" =~ ^#### ]]; then
                    break
                fi
            done
            
            echo "| $num | $title | $status | $estimate |"
        fi
    done < "$plans_file"
}

# Get plan for current branch
get_current_branch_plan() {
    local branch
    branch=$(git branch --show-current 2>/dev/null || echo "")
    
    [[ -z "$branch" ]] && {
        echo "ERROR: Not in a git repository" >&2
        return 1
    }
    
    # Extract potential plan name from branch
    # e.g., feature/list-todo-show-plan-commands -> list-todo-show-plan
    local plan_hint
    plan_hint=$(echo "$branch" | sed 's|^[^/]*/||' | sed 's/-commands$//' | sed 's/-helper$//' | tr '-' ' ')
    
    echo "$plan_hint"
}

# Show help
show_help() {
    cat << 'EOF'
Usage: show-plan-helper.sh [options] [plan-name|plan-id]

Arguments:
  plan-name          Fuzzy match plan by title (e.g., "opencode", "destructive")
  plan-id            Exact plan ID (e.g., "p001", "p002")

Options:
  --current          Show plan related to current git branch
  --list             List all active plans briefly
  --json             Output as JSON
  --no-color         Disable colors
  --help, -h         Show this help

Examples:
  show-plan-helper.sh opencode           # Show aidevops-opencode Plugin plan
  show-plan-helper.sh p001               # Show plan by ID
  show-plan-helper.sh --current          # Show plan for current branch
  show-plan-helper.sh --list             # List all plans
  show-plan-helper.sh "destructive"      # Fuzzy match "Destructive Command Hooks"
EOF
}

# Main
main() {
    # Parse command line
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --current) SHOW_CURRENT=true ;;
            --list) LIST_ONLY=true ;;
            --json) OUTPUT_JSON=true ;;
            --no-color) NO_COLOR=true ;;
            --help|-h) show_help; exit 0 ;;
            -*) echo "Unknown option: $1" >&2; exit 1 ;;
            *) PLAN_QUERY="$1" ;;
        esac
        shift
    done
    
    # Disable colors if requested
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
    
    local plans_file="$project_root/todo/PLANS.md"
    local todo_file="$project_root/TODO.md"
    
    [[ ! -f "$plans_file" ]] && {
        echo "ERROR: No PLANS.md found at $plans_file" >&2
        exit 1
    }
    
    # Handle --list
    if $LIST_ONLY; then
        list_plans "$plans_file"
        exit 0
    fi
    
    # Handle --current
    if $SHOW_CURRENT; then
        PLAN_QUERY=$(get_current_branch_plan) || exit 1
    fi
    
    # Require a query
    if [[ -z "$PLAN_QUERY" ]]; then
        echo "Usage: show-plan-helper.sh [plan-name|plan-id]" >&2
        echo "" >&2
        echo "Available plans:" >&2
        list_plans "$plans_file"
        exit 1
    fi
    
    # Output
    if $OUTPUT_JSON; then
        output_json "$plans_file" "$todo_file" "$PLAN_QUERY"
    else
        output_markdown "$plans_file" "$todo_file" "$PLAN_QUERY"
    fi
}

main "$@"
