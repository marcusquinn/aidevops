#!/usr/bin/env bash
# list-verify-helper.sh - List verification queue entries with filtering
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   list-verify-helper.sh [options]
#
# Filtering options:
#   --pending          Show only pending verifications [ ]
#   --passed           Show only passed verifications [x]
#   --failed           Show only failed verifications [!]
#   --task, -t ID      Filter by task ID (e.g., t168)
#
# Display options:
#   --compact          One-line per entry (no details)
#   --json             Output as JSON
#   --no-color         Disable colors
#   --help, -h         Show this help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Defaults
FILTER_STATUS=""
FILTER_TASK=""
COMPACT=false
OUTPUT_JSON=false
NO_COLOR=false

# Colors
C_GREEN="\033[0;32m"
C_RED="\033[0;31m"
C_YELLOW="\033[1;33m"
# shellcheck disable=SC2034  # Reserved for future use
C_BOLD="\033[1m"
# shellcheck disable=SC2034  # Reserved for future use
C_DIM="\033[2m"
C_NC="\033[0m"

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

# Parse a verification entry block into structured data
# Input: lines of a single verify entry (starting with - [ ] or - [x] or - [!])
# Output: status|verify_id|task_id|description|pr|merged|files|checks|verified|failed_reason
parse_verify_entries() {
    local verify_file="$1"
    local in_queue=false
    local current_status=""
    local current_vid=""
    local current_tid=""
    local current_desc=""
    local current_pr=""
    local current_merged=""
    local current_files=""
    local current_checks=""
    local current_verified=""
    local current_failed=""

    flush_entry() {
        if [[ -n "$current_vid" ]]; then
            echo "${current_status}|${current_vid}|${current_tid}|${current_desc}|${current_pr}|${current_merged}|${current_files}|${current_checks}|${current_verified}|${current_failed}"
        fi
        current_status=""
        current_vid=""
        current_tid=""
        current_desc=""
        current_pr=""
        current_merged=""
        current_files=""
        current_checks=""
        current_verified=""
        current_failed=""
    }

    while IFS= read -r line; do
        # Detect queue boundaries
        if [[ "$line" == "<!-- VERIFY-QUEUE-START -->" ]]; then
            in_queue=true
            continue
        fi
        if [[ "$line" == "<!-- VERIFY-QUEUE-END -->" ]]; then
            flush_entry
            in_queue=false
            continue
        fi

        $in_queue || continue

        # Skip blank lines
        [[ -z "$line" ]] && continue

        # New entry: - [ ] v001 t168 Description | PR #660 | merged:2026-02-08
        if [[ "$line" =~ ^-\ \[(.)\]\ (v[0-9]+)\ (t[0-9]+)\ (.+) ]]; then
            flush_entry
            local marker="${BASH_REMATCH[1]}"
            current_vid="${BASH_REMATCH[2]}"
            current_tid="${BASH_REMATCH[3]}"
            local rest="${BASH_REMATCH[4]}"

            case "$marker" in
                " ") current_status="pending" ;;
                "x") current_status="passed" ;;
                "!") current_status="failed" ;;
                *) current_status="unknown" ;;
            esac

            # Extract PR number
            if [[ "$rest" =~ \|\ PR\ #([0-9]+) ]]; then
                current_pr="#${BASH_REMATCH[1]}"
            elif [[ "$rest" =~ \|\ cherry-picked:([a-f0-9]+) ]]; then
                current_pr="cherry:${BASH_REMATCH[1]}"
            fi

            # Extract merged date
            if [[ "$rest" =~ merged:([0-9-]+) ]]; then
                current_merged="${BASH_REMATCH[1]}"
            fi

            # Extract verified date
            if [[ "$rest" =~ verified:([0-9-]+) ]]; then
                current_verified="${BASH_REMATCH[1]}"
            fi

            # Extract failed reason
            if [[ "$rest" =~ failed:([0-9-]+)\ reason:(.+) ]]; then
                current_failed="${BASH_REMATCH[2]}"
            fi

            # Description is everything before the first |
            current_desc="${rest%%|*}"
            current_desc="${current_desc%"${current_desc##*[![:space:]]}"}"

            continue
        fi

        # Metadata lines (indented under an entry)
        if [[ "$line" =~ ^[[:space:]]+files:\ (.+) ]]; then
            current_files="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+check:\ (.+) ]]; then
            if [[ -n "$current_checks" ]]; then
                current_checks="${current_checks}; ${BASH_REMATCH[1]}"
            else
                current_checks="${BASH_REMATCH[1]}"
            fi
        fi

    done < "$verify_file"

    # Flush last entry
    flush_entry
}

# Apply filters
apply_filters() {
    local line="$1"
    local status
    local tid
    status=$(echo "$line" | cut -d'|' -f1)
    tid=$(echo "$line" | cut -d'|' -f3)

    # Status filter
    if [[ -n "$FILTER_STATUS" ]]; then
        [[ "$status" != "$FILTER_STATUS" ]] && return 1
    fi

    # Task filter
    if [[ -n "$FILTER_TASK" ]]; then
        [[ "$tid" != "$FILTER_TASK" ]] && return 1
    fi

    return 0
}

# Output as markdown
output_markdown() {
    local entries_file="$1"

    local pending_count=0
    local passed_count=0
    local failed_count=0

    # Count entries
    while IFS='|' read -r status vid tid desc pr merged files checks verified failed_reason; do
        case "$status" in
            pending) ((pending_count++)) ;;
            passed) ((passed_count++)) ;;
            failed) ((failed_count++)) ;;
        esac
    done < "$entries_file"

    local total=$((pending_count + passed_count + failed_count))

    echo "## Verification Queue"
    echo ""

    if [[ $total -eq 0 ]]; then
        echo "*No verification entries found.*"
        echo ""
        return 0
    fi

    # Failed section (most important)
    if [[ $failed_count -gt 0 ]]; then
        if $NO_COLOR; then
            echo "### Failed ($failed_count)"
        else
            echo -e "### ${C_RED}Failed ($failed_count)${C_NC}"
        fi
        echo ""

        if $COMPACT; then
            while IFS='|' read -r status vid tid desc pr merged files checks verified failed_reason; do
                [[ "$status" != "failed" ]] && continue
                echo "- [!] $vid $tid $desc $pr ${failed_reason:+reason: $failed_reason}"
            done < "$entries_file"
        else
            echo "| # | Verify | Task | Description | PR | Merged | Reason |"
            echo "|---|--------|------|-------------|-----|--------|--------|"
            local num=0
            while IFS='|' read -r status vid tid desc pr merged files checks verified failed_reason; do
                [[ "$status" != "failed" ]] && continue
                ((num++))
                echo "| $num | $vid | $tid | $desc | $pr | $merged | ${failed_reason:--} |"
            done < "$entries_file"
        fi
        echo ""
        echo "---"
        echo ""
    fi

    # Pending section
    if [[ $pending_count -gt 0 ]]; then
        if $NO_COLOR; then
            echo "### Pending ($pending_count)"
        else
            echo -e "### ${C_YELLOW}Pending ($pending_count)${C_NC}"
        fi
        echo ""

        if $COMPACT; then
            while IFS='|' read -r status vid tid desc pr merged files checks verified failed_reason; do
                [[ "$status" != "pending" ]] && continue
                echo "- [ ] $vid $tid $desc $pr"
            done < "$entries_file"
        else
            echo "| # | Verify | Task | Description | PR | Merged | Checks |"
            echo "|---|--------|------|-------------|-----|--------|--------|"
            local num=0
            while IFS='|' read -r status vid tid desc pr merged files checks verified failed_reason; do
                [[ "$status" != "pending" ]] && continue
                ((num++))
                local check_count
                if [[ -n "$checks" ]]; then
                    check_count=$(echo "$checks" | tr ';' '\n' | wc -l | xargs)
                else
                    check_count=0
                fi
                echo "| $num | $vid | $tid | $desc | $pr | $merged | ${check_count} checks |"
            done < "$entries_file"
        fi
        echo ""
        echo "---"
        echo ""
    fi

    # Passed section
    if [[ $passed_count -gt 0 ]]; then
        if $NO_COLOR; then
            echo "### Passed ($passed_count)"
        else
            echo -e "### ${C_GREEN}Passed ($passed_count)${C_NC}"
        fi
        echo ""

        if $COMPACT; then
            while IFS='|' read -r status vid tid desc pr merged files checks verified failed_reason; do
                [[ "$status" != "passed" ]] && continue
                echo "- [x] $vid $tid $desc $pr verified:$verified"
            done < "$entries_file"
        else
            echo "| # | Verify | Task | Description | PR | Merged | Verified |"
            echo "|---|--------|------|-------------|-----|--------|----------|"
            local num=0
            while IFS='|' read -r status vid tid desc pr merged files checks verified failed_reason; do
                [[ "$status" != "passed" ]] && continue
                ((num++))
                echo "| $num | $vid | $tid | $desc | $pr | $merged | ${verified:--} |"
            done < "$entries_file"
        fi
        echo ""
        echo "---"
        echo ""
    fi

    # Summary
    echo -e "**Summary:** ${pending_count} pending | ${passed_count} passed | ${failed_count} failed | ${total} total"
}

# Escape string for JSON output
json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "$str"
}

# Output as JSON
output_json() {
    local entries_file="$1"

    echo "{"

    local sections=("pending" "passed" "failed")
    local first_section=true

    for section in "${sections[@]}"; do
        $first_section || echo ","
        first_section=false

        echo "  \"${section}\": ["
        local first=true
        while IFS='|' read -r status vid tid desc pr merged files checks verified failed_reason; do
            [[ "$status" != "$section" ]] && continue
            $first || echo ","
            first=false
            desc=$(json_escape "$desc")
            files=$(json_escape "$files")
            checks=$(json_escape "$checks")
            failed_reason=$(json_escape "$failed_reason")
            printf '    {"verify_id":"%s","task_id":"%s","desc":"%s","pr":"%s","merged":"%s","files":"%s","checks":"%s","verified":"%s","failed_reason":"%s"}' \
                "$vid" "$tid" "$desc" "$pr" "$merged" "$files" "$checks" "$verified" "$failed_reason"
        done < "$entries_file"
        echo ""
        echo "  ]"
    done

    echo "}"
}

# Show help
show_help() {
    cat << 'EOF'
Usage: list-verify-helper.sh [options]

Filtering:
  --pending          Show only pending verifications [ ]
  --passed           Show only passed verifications [x]
  --failed           Show only failed verifications [!]
  --task, -t ID      Filter by task ID (e.g., t168)

Display:
  --compact          One-line per entry (no details)
  --json             Output as JSON
  --no-color         Disable colors
  --help, -h         Show this help

Examples:
  list-verify-helper.sh                # All entries, grouped by status
  list-verify-helper.sh --pending      # Only pending verifications
  list-verify-helper.sh --failed       # Only failed (needs attention)
  list-verify-helper.sh -t t168        # Specific task verification
  list-verify-helper.sh --compact      # One-line per entry
  list-verify-helper.sh --json         # JSON output
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
            --pending) FILTER_STATUS="pending" ;;
            --passed) FILTER_STATUS="passed" ;;
            --failed) FILTER_STATUS="failed" ;;
            --task|-t) require_arg "$1" "${2:-}"; FILTER_TASK="$2"; shift ;;
            --compact) COMPACT=true ;;
            --json) OUTPUT_JSON=true ;;
            --no-color) NO_COLOR=true ;;
            --help|-h) show_help; exit 0 ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
        shift
    done

    # Disable colors if not a terminal
    # shellcheck disable=SC2034
    if $NO_COLOR || [[ ! -t 1 ]]; then
        C_GREEN="" C_RED="" C_YELLOW="" C_BOLD="" C_DIM="" C_NC=""
    fi

    # Find project
    local project_root
    project_root=$(find_project_root) || {
        echo "ERROR: Not in a project directory (no TODO.md found)" >&2
        exit 1
    }

    local verify_file="$project_root/todo/VERIFY.md"

    if [[ ! -f "$verify_file" ]]; then
        echo "No verification queue found (todo/VERIFY.md does not exist)." >&2
        exit 0
    fi

    # Create temp file
    local entries_tmp
    entries_tmp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$entries_tmp'" EXIT

    # Parse and filter entries
    parse_verify_entries "$verify_file" | while IFS= read -r line; do
        if apply_filters "$line"; then
            echo "$line"
        fi
    done > "$entries_tmp"

    # Output
    if $OUTPUT_JSON; then
        output_json "$entries_tmp"
    else
        output_markdown "$entries_tmp"
    fi
}

main "$@"
