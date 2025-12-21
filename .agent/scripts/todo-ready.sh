#!/usr/bin/env bash
# todo-ready.sh - Show tasks with no open blockers (ready to work on)
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   todo-ready.sh [options]
#
# Options:
#   --json    Output as JSON for programmatic use
#   --count   Only show count of ready tasks
#   --verbose Show all task details

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# Parse tasks from TODO.md
parse_tasks() {
    local todo_file="$1"
    local task_id=""
    local task_desc=""
    local task_est=""
    local task_blocker=""
    
    while IFS= read -r line; do
        # Skip non-task lines
        [[ ! "$line" =~ ^[[:space:]]*-\ \[ ]] && continue
        
        # Get task ID (tNNN or tNNN.N or tNNN.N.N)
        task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
        
        # Get description (text after ID, before first # or ~)
        task_desc=$(echo "$line" | sed 's/^[[:space:]]*- \[[^]]*\] //' | sed 's/t[0-9.]*[[:space:]]*//' | cut -d'#' -f1 | cut -d'~' -f1 | xargs)
        
        # Get estimate
        task_est=$(echo "$line" | grep -oE '~[0-9]+[hmd]' | head -1 || echo "")
        
        # Check status and output
        if [[ "$line" =~ \[x\] ]]; then
            # Done - skip
            continue
        elif [[ "$line" =~ \[-\] ]]; then
            # Declined - skip
            continue
        elif [[ "$line" =~ \[\>\] ]]; then
            # In progress
            echo "IN_PROGRESS|$task_id|$task_desc|$task_est|"
        elif [[ "$line" =~ blocked-by: ]]; then
            # Blocked
            task_blocker=$(echo "$line" | grep -oE 'blocked-by:[^ ]+' | cut -d: -f2 || echo "")
            echo "BLOCKED|$task_id|$task_desc|$task_est|$task_blocker"
        else
            # Ready (open, no blockers)
            echo "READY|$task_id|$task_desc|$task_est|"
        fi
    done < "$todo_file"
}

# Output as text
output_text() {
    local ready_count=0
    local blocked_count=0
    local in_progress_count=0
    
    echo "=== Ready Tasks (No Blockers) ==="
    echo ""
    
    while IFS='|' read -r status id desc est blocker; do
        case "$status" in
            READY)
                ((ready_count++))
                echo "  $ready_count. $id: $desc ${est:+($est)}"
                ;;
            BLOCKED)
                ((blocked_count++))
                ;;
            IN_PROGRESS)
                ((in_progress_count++))
                ;;
        esac
    done
    
    if [[ $ready_count -eq 0 ]]; then
        echo "  No ready tasks found"
    fi
    
    echo ""
    echo "Blocked: $blocked_count | In Progress: $in_progress_count"
    echo ""
    echo "Start work with: \"Let's work on [task-id]\""
}

# Output as verbose
output_verbose() {
    echo -e "${BLUE}=== Ready Tasks (No Blockers) ===${NC}"
    echo ""
    
    while IFS='|' read -r status id desc est blocker; do
        case "$status" in
            READY)
                echo -e "${GREEN}READY${NC} $id: $desc ${est:+($est)}"
                ;;
        esac
    done
    
    echo ""
    echo -e "${YELLOW}=== Blocked Tasks ===${NC}"
    echo ""
    
    # Re-read for blocked
    while IFS='|' read -r status id desc est blocker; do
        case "$status" in
            BLOCKED)
                echo -e "${YELLOW}BLOCKED${NC} $id: $desc (waiting on: $blocker)"
                ;;
        esac
    done
    
    echo ""
    echo -e "${BLUE}=== In Progress ===${NC}"
    echo ""
    
    # Re-read for in progress
    while IFS='|' read -r status id desc est blocker; do
        case "$status" in
            IN_PROGRESS)
                echo -e "${BLUE}IN PROGRESS${NC} $id: $desc ${est:+($est)}"
                ;;
        esac
    done
}

# Output as JSON
output_json() {
    local ready_json=""
    local blocked_json=""
    local in_progress_json=""
    local ready_count=0
    local blocked_count=0
    local in_progress_count=0
    
    while IFS='|' read -r status id desc est blocker; do
        case "$status" in
            READY)
                [[ $ready_count -gt 0 ]] && ready_json+=","
                ready_json+="{\"id\":\"$id\",\"desc\":\"$desc\",\"est\":\"$est\"}"
                ((ready_count++))
                ;;
            BLOCKED)
                [[ $blocked_count -gt 0 ]] && blocked_json+=","
                blocked_json+="{\"id\":\"$id\",\"desc\":\"$desc\",\"est\":\"$est\",\"blocked_by\":\"$blocker\"}"
                ((blocked_count++))
                ;;
            IN_PROGRESS)
                [[ $in_progress_count -gt 0 ]] && in_progress_json+=","
                in_progress_json+="{\"id\":\"$id\",\"desc\":\"$desc\",\"est\":\"$est\"}"
                ((in_progress_count++))
                ;;
        esac
    done
    
    cat <<EOF
{
  "ready": [$ready_json],
  "blocked": [$blocked_json],
  "in_progress": [$in_progress_json],
  "summary": {
    "ready": $ready_count,
    "blocked": $blocked_count,
    "in_progress": $in_progress_count
  }
}
EOF
}

# Main
main() {
    local output_format="text"
    
    # Parse command line
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) output_format="json" ;;
            --count) output_format="count" ;;
            --verbose) output_format="verbose" ;;
            --help|-h) 
                echo "Usage: todo-ready.sh [--json|--count|--verbose]"
                exit 0
                ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
        shift
    done
    
    # Find project
    local project_root
    project_root=$(find_project_root) || {
        echo "ERROR: Not in a project directory (no TODO.md found)" >&2
        exit 1
    }
    
    local todo_file="$project_root/TODO.md"
    
    # Parse and output
    case "$output_format" in
        count)
            parse_tasks "$todo_file" | grep -c "^READY|" || echo "0"
            ;;
        json)
            parse_tasks "$todo_file" | output_json
            ;;
        verbose)
            # Need to parse multiple times for verbose output
            parse_tasks "$todo_file" > /tmp/todo-ready-$$
            output_verbose < /tmp/todo-ready-$$
            rm -f /tmp/todo-ready-$$
            ;;
        *)
            parse_tasks "$todo_file" | output_text
            ;;
    esac
}

main "$@"
