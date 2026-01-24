#!/usr/bin/env bash
# session-time-helper.sh - Analyse Claude Code session active time
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   session-time-helper.sh [command] [options]
#
# Commands:
#   list              List recent sessions with active time
#   analyse <id>      Detailed breakdown of a specific session
#   summary           Aggregate stats across all sessions
#   calibrate         Compare estimates vs actuals for TODO.md tasks
#
# Options:
#   --project <path>  Project path (default: current directory)
#   --threshold <s>   AFK threshold in seconds (default: 300 = 5min)
#   --limit <n>       Number of sessions to show (default: 10)
#   --json            Output as JSON

set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# Defaults
CLAUDE_DIR="${HOME}/.claude"
AFK_THRESHOLD=300  # 5 minutes in seconds
LIMIT=10
OUTPUT_JSON=false
PROJECT_PATH=""

# Escape string for JSON output
json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    printf '%s' "$str"
}

# Get project sessions directory from project path
get_sessions_dir() {
    local project_path="${1:-$PWD}"
    # Claude Code encodes paths with dashes replacing slashes
    local encoded="${project_path//\//-}"
    local sessions_dir="${CLAUDE_DIR}/projects/${encoded}"

    if [[ -d "$sessions_dir" ]]; then
        echo "$sessions_dir"
        return 0
    fi

    # For worktrees, try the main repo path
    local main_worktree
    main_worktree=$(git -C "$project_path" worktree list 2>/dev/null | head -1 | awk '{print $1}')
    if [[ -n "$main_worktree" ]] && [[ "$main_worktree" != "$project_path" ]]; then
        encoded="${main_worktree//\//-}"
        sessions_dir="${CLAUDE_DIR}/projects/${encoded}"
        if [[ -d "$sessions_dir" ]]; then
            echo "$sessions_dir"
            return 0
        fi
    fi

    echo ""
    return 1
}

# Format seconds to human-readable duration
format_duration() {
    local total_seconds="$1"
    local hours=$((total_seconds / 3600))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$((total_seconds % 60))

    if [[ $hours -gt 0 ]]; then
        printf "%dh %dm" "$hours" "$minutes"
    elif [[ $minutes -gt 0 ]]; then
        printf "%dm %ds" "$minutes" "$seconds"
    else
        printf "%ds" "$seconds"
    fi
}

# Format ISO timestamp to local time (macOS compatible)
format_timestamp() {
    local ts="$1"
    [[ -z "$ts" ]] && { echo "unknown"; return 0; }
    local clean_ts="${ts%%.*}"
    clean_ts="${clean_ts//T/ }"
    clean_ts="${clean_ts%%Z}"
    if command -v gdate &>/dev/null; then
        gdate -d "$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "${clean_ts:0:16}"
    else
        date -j -f "%Y-%m-%d %H:%M:%S" "$clean_ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "${clean_ts:0:16}"
    fi
}

# Convert ISO timestamp to epoch seconds (macOS compatible)
ts_to_epoch() {
    local ts="$1"
    local clean_ts="${ts%%.*}"
    clean_ts="${clean_ts//T/ }"
    clean_ts="${clean_ts%%Z}"
    if command -v gdate &>/dev/null; then
        gdate -d "$ts" '+%s' 2>/dev/null || echo "0"
    else
        date -j -f "%Y-%m-%d %H:%M:%S" "$clean_ts" '+%s' 2>/dev/null || echo "0"
    fi
}

# Extract timestamps from a session JSONL file (user + assistant messages only)
extract_timestamps() {
    local session_file="$1"
    # Only extract from user/assistant message lines (skip file-history-snapshot, etc.)
    grep -E '"type":"(user|assistant)"' "$session_file" 2>/dev/null \
        | grep -o '"timestamp":"[^"]*"' \
        | sed 's/"timestamp":"//;s/"//' \
        | sort
}

# Calculate active time for a session file
# Returns: active|wall|msgs|afk|first_ts|last_ts
calculate_active_time() {
    local session_file="$1"
    local threshold="${2:-$AFK_THRESHOLD}"

    local timestamps
    timestamps=$(extract_timestamps "$session_file")

    if [[ -z "$timestamps" ]]; then
        echo "0|0|0|0||"
        return 0
    fi

    local prev_epoch=0
    local total_active=0
    local afk_time=0
    local msg_count=0
    local first_epoch=0
    local last_epoch=0
    local first_ts=""
    local last_ts=""

    while IFS= read -r ts; do
        [[ -z "$ts" ]] && continue
        msg_count=$((msg_count + 1))

        local epoch
        epoch=$(ts_to_epoch "$ts")
        [[ "$epoch" == "0" ]] && continue

        if [[ $first_epoch -eq 0 ]]; then
            first_epoch=$epoch
            first_ts="$ts"
        fi
        last_epoch=$epoch
        last_ts="$ts"

        if [[ $prev_epoch -gt 0 ]]; then
            local gap=$((epoch - prev_epoch))
            [[ $gap -lt 0 ]] && gap=0
            if [[ $gap -lt $threshold ]]; then
                total_active=$((total_active + gap))
            else
                afk_time=$((afk_time + gap))
            fi
        fi

        prev_epoch=$epoch
    done <<< "$timestamps"

    local total_wall=0
    if [[ $first_epoch -gt 0 ]] && [[ $last_epoch -gt 0 ]]; then
        total_wall=$((last_epoch - first_epoch))
    fi

    echo "${total_active}|${total_wall}|${msg_count}|${afk_time}|${first_ts}|${last_ts}"
}

# Get session title from JSONL (summary or first user message)
get_session_title() {
    local session_file="$1"
    local summary
    summary=$(grep '"type":"summary"' "$session_file" 2>/dev/null \
        | head -1 \
        | grep -o '"summary":"[^"]*"' \
        | sed 's/"summary":"//;s/"$//')
    if [[ -n "$summary" ]]; then
        echo "$summary"
        return 0
    fi
    # Fall back to first user message content
    local first_msg
    first_msg=$(grep '"type":"user"' "$session_file" 2>/dev/null \
        | grep -v 'local-command' \
        | head -1 \
        | grep -o '"content":"[^"]*"' \
        | head -1 \
        | sed 's/"content":"//;s/"$//' \
        | cut -c1-60)
    if [[ -n "$first_msg" ]]; then
        echo "$first_msg"
        return 0
    fi
    echo "(untitled)"
}

# List sessions with active time
cmd_list() {
    local sessions_dir
    sessions_dir=$(get_sessions_dir "$PROJECT_PATH") || {
        echo -e "${RED}No sessions found for project: ${PROJECT_PATH:-$PWD}${NC}" >&2
        echo -e "${DIM}Looking in: ${CLAUDE_DIR}/projects/${NC}" >&2
        return 1
    }

    local session_files
    session_files=$(find "$sessions_dir" -maxdepth 1 -name "*.jsonl" -type f | sort -r | head -"$LIMIT")

    if [[ -z "$session_files" ]]; then
        echo -e "${RED}No session files found${NC}" >&2
        return 1
    fi

    if [[ "$OUTPUT_JSON" == "true" ]]; then
        echo "["
        local first=true
    else
        printf "${BOLD}%-10s %-18s %-10s %-10s %-5s %s${NC}\n" "Session" "Started" "Active" "Wall" "Msgs" "Title"
        printf "%s\n" "$(printf '%.0s─' {1..95})"
    fi

    while IFS= read -r session_file; do
        [[ -z "$session_file" ]] && continue

        local result
        result=$(calculate_active_time "$session_file")

        local active wall msgs afk first_ts last_ts
        IFS='|' read -r active wall msgs afk first_ts last_ts <<< "$result"

        # Skip empty/trivial sessions
        [[ $msgs -lt 3 ]] && continue

        local session_id
        session_id=$(basename "$session_file" .jsonl)
        local title
        title=$(get_session_title "$session_file")
        local started
        started=$(format_timestamp "$first_ts")
        local active_fmt
        active_fmt=$(format_duration "$active")
        local wall_fmt
        wall_fmt=$(format_duration "$wall")

        if [[ "$OUTPUT_JSON" == "true" ]]; then
            [[ "$first" == "true" ]] && first=false || echo ","
            local escaped_title
            escaped_title=$(json_escape "$title")
            printf '  {"session_id":"%s","started":"%s","active_seconds":%d,"wall_seconds":%d,"messages":%d,"afk_seconds":%d,"title":"%s"}' \
                "$session_id" "$first_ts" "$active" "$wall" "$msgs" "$afk" "$escaped_title"
        else
            local short_id="${session_id:0:8}"
            printf "%-10s %-18s ${GREEN}%-10s${NC} ${DIM}%-10s${NC} %-5s %s\n" \
                "$short_id" "$started" "$active_fmt" "$wall_fmt" "$msgs" "${title:0:40}"
        fi
    done <<< "$session_files"

    if [[ "$OUTPUT_JSON" == "true" ]]; then
        echo ""
        echo "]"
    else
        echo ""
        echo -e "${DIM}AFK threshold: ${AFK_THRESHOLD}s | Active = time between messages (gaps < ${AFK_THRESHOLD}s)${NC}"
    fi
}

# Detailed analysis of a single session
cmd_analyse() {
    local session_id="$1"
    local sessions_dir
    sessions_dir=$(get_sessions_dir "$PROJECT_PATH") || {
        echo -e "${RED}No sessions found for project${NC}" >&2
        return 1
    }

    # Find matching session file (support partial IDs)
    local session_file
    session_file=$(find "$sessions_dir" -maxdepth 1 -name "${session_id}*.jsonl" -type f | head -1)

    if [[ -z "$session_file" ]] || [[ ! -f "$session_file" ]]; then
        echo -e "${RED}Session not found: $session_id${NC}" >&2
        return 1
    fi

    local result
    result=$(calculate_active_time "$session_file")

    local active wall msgs afk first_ts last_ts
    IFS='|' read -r active wall msgs afk first_ts last_ts <<< "$result"

    local title
    title=$(get_session_title "$session_file")

    echo -e "${BOLD}Session Analysis${NC}"
    echo -e "$(printf '%.0s─' {1..50})"
    echo -e "${CYAN}Title:${NC}    $title"
    echo -e "${CYAN}ID:${NC}       $(basename "$session_file" .jsonl)"
    echo -e "${CYAN}Started:${NC}  $(format_timestamp "$first_ts")"
    echo -e "${CYAN}Ended:${NC}    $(format_timestamp "$last_ts")"
    echo ""
    echo -e "${BOLD}Time Breakdown${NC}"
    echo -e "  ${GREEN}Active time:${NC}  $(format_duration "$active")"
    echo -e "  ${DIM}Wall time:${NC}    $(format_duration "$wall")"
    echo -e "  ${YELLOW}AFK time:${NC}     $(format_duration "$afk")"
    echo -e "  ${CYAN}Messages:${NC}     $msgs"

    if [[ $wall -gt 0 ]]; then
        local efficiency=$(( (active * 100) / wall ))
        echo -e "  ${BLUE}Efficiency:${NC}   ${efficiency}% active"
    fi

    # Gap distribution
    echo ""
    echo -e "${BOLD}Gap Distribution${NC}"
    local timestamps
    timestamps=$(extract_timestamps "$session_file")
    local gaps_under_1m=0 gaps_1_5m=0 gaps_5_15m=0 gaps_over_15m=0
    local prev_epoch=0

    while IFS= read -r ts; do
        [[ -z "$ts" ]] && continue
        local epoch
        epoch=$(ts_to_epoch "$ts")
        [[ "$epoch" == "0" ]] && continue

        if [[ $prev_epoch -gt 0 ]]; then
            local gap=$((epoch - prev_epoch))
            [[ $gap -lt 0 ]] && gap=0
            if [[ $gap -lt 60 ]]; then
                gaps_under_1m=$((gaps_under_1m + 1))
            elif [[ $gap -lt 300 ]]; then
                gaps_1_5m=$((gaps_1_5m + 1))
            elif [[ $gap -lt 900 ]]; then
                gaps_5_15m=$((gaps_5_15m + 1))
            else
                gaps_over_15m=$((gaps_over_15m + 1))
            fi
        fi
        prev_epoch=$epoch
    done <<< "$timestamps"

    echo -e "  < 1 min:   $gaps_under_1m ${DIM}(active interaction)${NC}"
    echo -e "  1-5 min:   $gaps_1_5m ${DIM}(reading/thinking)${NC}"
    echo -e "  5-15 min:  $gaps_5_15m ${DIM}(short AFK)${NC}"
    echo -e "  > 15 min:  $gaps_over_15m ${DIM}(long AFK)${NC}"
}

# Aggregate summary across sessions
cmd_summary() {
    local sessions_dir
    sessions_dir=$(get_sessions_dir "$PROJECT_PATH") || {
        echo -e "${RED}No sessions found for project${NC}" >&2
        return 1
    }

    local total_active=0 total_wall=0 total_msgs=0 total_sessions=0
    local session_files
    session_files=$(find "$sessions_dir" -maxdepth 1 -name "*.jsonl" -type f)

    while IFS= read -r session_file; do
        [[ -z "$session_file" ]] && continue

        local result
        result=$(calculate_active_time "$session_file")

        local active wall msgs afk first_ts last_ts
        IFS='|' read -r active wall msgs afk first_ts last_ts <<< "$result"

        [[ $msgs -lt 3 ]] && continue

        total_active=$((total_active + active))
        total_wall=$((total_wall + wall))
        total_msgs=$((total_msgs + msgs))
        total_sessions=$((total_sessions + 1))
    done <<< "$session_files"

    echo -e "${BOLD}Session Summary (${PROJECT_PATH:-$PWD})${NC}"
    echo -e "$(printf '%.0s─' {1..40})"
    echo -e "${CYAN}Total sessions:${NC}     $total_sessions"
    echo -e "${GREEN}Total active:${NC}       $(format_duration "$total_active")"
    echo -e "${DIM}Total wall:${NC}         $(format_duration "$total_wall")"
    echo -e "${CYAN}Total messages:${NC}     $total_msgs"

    if [[ $total_sessions -gt 0 ]]; then
        local avg_active=$((total_active / total_sessions))
        local avg_msgs=$((total_msgs / total_sessions))
        echo ""
        echo -e "${BOLD}Averages${NC}"
        echo -e "  Active per session:   $(format_duration "$avg_active")"
        echo -e "  Messages per session: $avg_msgs"
    fi

    if [[ $total_wall -gt 0 ]]; then
        local efficiency=$(( (total_active * 100) / total_wall ))
        echo -e "  Overall efficiency:   ${efficiency}%"
    fi
}

# Compare TODO.md estimates vs actual session times
cmd_calibrate() {
    local project_root="${PROJECT_PATH:-$PWD}"
    local todo_file="${project_root}/TODO.md"

    if [[ ! -f "$todo_file" ]]; then
        echo -e "${RED}No TODO.md found at: $todo_file${NC}" >&2
        return 1
    fi

    echo -e "${BOLD}Estimate Calibration${NC}"
    echo -e "${DIM}Comparing TODO.md estimates with actuals${NC}"
    echo ""
    printf "${BOLD}%-8s %-10s %-10s %-7s %s${NC}\n" "Task" "Estimate" "Actual" "Ratio" "Title"
    printf "%s\n" "$(printf '%.0s─' {1..80})"

    local total_est_min=0 total_act_min=0 count=0

    while IFS= read -r line; do
        # Skip non-completed tasks
        [[ "$line" != *"[x]"* ]] && continue
        # Must have both ~estimate and actual:
        [[ "$line" != *"~"* ]] && continue
        [[ "$line" != *"actual:"* ]] && continue

        # Extract fields using grep (avoids BASH_REMATCH clobbering)
        local task_id estimate actual title
        task_id=$(echo "$line" | grep -o 't[0-9]\+' | head -1 || true)
        estimate=$(echo "$line" | grep -oE '~[0-9]+\.?[0-9]*[hm][0-9]*[m]?' | head -1 | sed 's/~//' || true)
        actual=$(echo "$line" | grep -oE 'actual:[0-9]+\.?[0-9]*[hm][0-9]*[m]?' | head -1 | sed 's/actual://' || true)
        title=$(echo "$line" | sed 's/.*\] //;s/ ~.*//' | cut -c1-35 || true)

        [[ -z "$task_id" ]] && continue
        [[ -z "$estimate" ]] && continue
        [[ -z "$actual" ]] && continue

        local est_min act_min
        est_min=$(duration_to_minutes "$estimate")
        act_min=$(duration_to_minutes "$actual")

        if [[ $act_min -gt 0 ]] && [[ $est_min -gt 0 ]]; then
            local ratio
            ratio=$(awk "BEGIN {printf \"%.1f\", $est_min / $act_min}")
            printf "%-8s %-10s %-10s ${YELLOW}%-7s${NC} %s\n" \
                "$task_id" "~$estimate" "$actual" "${ratio}x" "$title"
            total_est_min=$((total_est_min + est_min))
            total_act_min=$((total_act_min + act_min))
            count=$((count + 1))
        fi
    done < "$todo_file"

    if [[ $count -gt 0 ]] && [[ $total_act_min -gt 0 ]]; then
        echo ""
        local avg_ratio
        avg_ratio=$(awk "BEGIN {printf \"%.1f\", $total_est_min / $total_act_min}")
        echo -e "${BOLD}Calibration: ${YELLOW}${avg_ratio}x${NC} overestimate across $count tasks"
        echo -e "${DIM}Divide estimates by ${avg_ratio} for AI-executed tasks${NC}"
    elif [[ $count -eq 0 ]]; then
        echo -e "${DIM}No completed tasks with both ~estimate and actual: found${NC}"
    fi
}

# Convert duration string (4h, 30m, 1h30m, 1.5h) to minutes
duration_to_minutes() {
    local dur="$1"
    local minutes=0

    # Handle decimal hours (e.g., 1.5h -> 90m)
    if [[ "$dur" =~ ([0-9]+)\.([0-9]+)h ]]; then
        local whole="${BASH_REMATCH[1]}"
        local frac="${BASH_REMATCH[2]}"
        minutes=$(awk "BEGIN {printf \"%d\", ($whole + 0.$frac) * 60}")
    elif [[ "$dur" =~ ([0-9]+)h ]]; then
        minutes=$((minutes + BASH_REMATCH[1] * 60))
    fi
    # Minutes component (handles both "30m" and "1h30m")
    if [[ "$dur" =~ ([0-9]+)m$ ]] || [[ "$dur" =~ h([0-9]+)m ]]; then
        minutes=$((minutes + BASH_REMATCH[1]))
    fi
    # Bare number defaults to hours
    if [[ $minutes -eq 0 ]] && [[ "$dur" =~ ^[0-9]+$ ]]; then
        minutes=$((dur * 60))
    fi

    echo "$minutes"
}

# Main
main() {
    local command="list"
    local session_arg=""

    # Parse all arguments with standard while/shift pattern
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)  PROJECT_PATH="$2"; shift 2 ;;
            --threshold) AFK_THRESHOLD="$2"; shift 2 ;;
            --limit)    LIMIT="$2"; shift 2 ;;
            --json)     OUTPUT_JSON=true; shift ;;
            list|analyse|analyze|summary|calibrate)
                command="$1"; shift ;;
            help|--help|-h)
                command="help"; shift ;;
            *)
                # Positional arg (session ID for analyse)
                session_arg="$1"; shift ;;
        esac
    done

    # Default project path to PWD
    [[ -z "$PROJECT_PATH" ]] && PROJECT_PATH="$PWD"

    case "$command" in
        list)
            cmd_list
            ;;
        analyse|analyze)
            if [[ -z "$session_arg" ]]; then
                echo -e "${RED}Usage: session-time-helper.sh analyse <session-id>${NC}" >&2
                return 1
            fi
            cmd_analyse "$session_arg"
            ;;
        summary)
            cmd_summary
            ;;
        calibrate)
            cmd_calibrate
            ;;
        help)
            head -19 "$0" | tail -17
            ;;
        *)
            echo -e "${RED}Unknown command: $command${NC}" >&2
            echo "Commands: list, analyse, summary, calibrate" >&2
            return 1
            ;;
    esac
}

main "$@"
