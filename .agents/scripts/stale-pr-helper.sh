#!/usr/bin/env bash
# stale-pr-helper.sh - Detect stale open PRs and notify via mail-helper.sh (t241)
#
# Scans for open PRs older than a configurable threshold (default: 24h) that are
# not linked to active tasks in the supervisor DB or TODO.md. Sends notifications
# via the inter-agent mailbox so the supervisor or human can take action.
#
# Usage:
#   stale-pr-helper.sh scan [--repo <path>] [--threshold <hours>] [--dry-run] [--verbose]
#   stale-pr-helper.sh report [--repo <path>] [--threshold <hours>]
#   stale-pr-helper.sh help
#
# Commands:
#   scan      Scan for stale PRs and send mail notifications for new findings
#   report    Print a summary of stale PRs to stdout (no notifications)
#   help      Show this help message
#
# Options:
#   --repo <path>        Repository path (default: current directory)
#   --threshold <hours>  PR age threshold in hours (default: 24)
#   --dry-run            Show what would be notified without sending mail
#   --verbose            Show detailed output
#
# Integration:
#   Can be called from supervisor pulse cycle or standalone.
#   Self-throttles to avoid excessive GitHub API calls (10-minute interval).
#
# Notifications:
#   Sends 'discovery' type messages via mail-helper.sh to 'supervisor'.
#   Each stale PR is notified once per 24h cycle (dedup via stamp file).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly STALE_PR_DIR="${HOME}/.aidevops/.agent-workspace/stale-pr"
readonly STALE_PR_STAMP_DIR="${STALE_PR_DIR}/notified"
readonly SCAN_THROTTLE_FILE="${STALE_PR_DIR}/last-scan"
readonly SCAN_INTERVAL=600  # seconds (10 min) — matches orphaned PR scan interval
readonly DEFAULT_THRESHOLD_HOURS=24
readonly NOTIFICATION_COOLDOWN=86400  # seconds (24h) — don't re-notify for same PR

# Logging
log_info()    { echo -e "${BLUE}[STALE-PR]${NC} $*"; }
log_success() { echo -e "${GREEN}[STALE-PR]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[STALE-PR]${NC} $*"; }
log_error()   { echo -e "${RED}[STALE-PR]${NC} $*" >&2; }

# Globals
REPO_PATH=""
THRESHOLD_HOURS="$DEFAULT_THRESHOLD_HOURS"
DRY_RUN=false
VERBOSE=false

#######################################
# Ensure required directories exist
#######################################
ensure_dirs() {
    mkdir -p "$STALE_PR_DIR" "$STALE_PR_STAMP_DIR"
    return 0
}

#######################################
# Check if scan should be throttled
# Returns: 0 if scan should proceed, 1 if throttled
#######################################
check_throttle() {
    if [[ ! -f "$SCAN_THROTTLE_FILE" ]]; then
        return 0
    fi
    local last_run
    last_run=$(cat "$SCAN_THROTTLE_FILE" 2>/dev/null || echo 0)
    local now_epoch
    now_epoch=$(date +%s)
    local elapsed=$((now_epoch - last_run))
    if [[ "$elapsed" -lt "$SCAN_INTERVAL" ]]; then
        local remaining=$((SCAN_INTERVAL - elapsed))
        if [[ "$VERBOSE" == true ]]; then
            log_info "Throttled (${remaining}s until next scan)"
        fi
        return 1
    fi
    return 0
}

#######################################
# Update throttle timestamp
#######################################
update_throttle() {
    local now_epoch
    now_epoch=$(date +%s)
    echo "$now_epoch" > "$SCAN_THROTTLE_FILE"
    return 0
}

#######################################
# Detect repo slug from git remote
#######################################
detect_repo_slug() {
    local project_root="${1:-.}"
    local remote_url
    remote_url=$(git -C "$project_root" remote get-url origin 2>/dev/null || echo "")
    remote_url="${remote_url%.git}"
    local slug
    slug=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|' || echo "")
    if [[ -z "$slug" ]]; then
        log_error "Could not detect GitHub repo slug from git remote in $project_root"
        return 1
    fi
    echo "$slug"
    return 0
}

#######################################
# Check if a PR was already notified within the cooldown period
# Arguments: PR number
# Returns: 0 if already notified (skip), 1 if not (should notify)
#######################################
is_recently_notified() {
    local pr_number="$1"
    local stamp_file="${STALE_PR_STAMP_DIR}/pr-${pr_number}"
    if [[ ! -f "$stamp_file" ]]; then
        return 1
    fi
    local stamp_time
    stamp_time=$(cat "$stamp_file" 2>/dev/null || echo 0)
    local now_epoch
    now_epoch=$(date +%s)
    local elapsed=$((now_epoch - stamp_time))
    if [[ "$elapsed" -lt "$NOTIFICATION_COOLDOWN" ]]; then
        return 0
    fi
    return 1
}

#######################################
# Mark a PR as notified
# Arguments: PR number
#######################################
mark_notified() {
    local pr_number="$1"
    local stamp_file="${STALE_PR_STAMP_DIR}/pr-${pr_number}"
    local now_epoch
    now_epoch=$(date +%s)
    echo "$now_epoch" > "$stamp_file"
    return 0
}

#######################################
# Get active task IDs from TODO.md
# Returns: newline-separated list of task IDs (e.g., t001, t002.1)
#######################################
get_active_task_ids() {
    local repo_path="$1"
    local todo_file="${repo_path}/TODO.md"
    if [[ ! -f "$todo_file" ]]; then
        return 0
    fi
    # Extract task IDs from unchecked items: - [ ] t123 ...
    grep -oE '^\s*- \[ \] (t[0-9]+(\.[0-9]+)?)' "$todo_file" 2>/dev/null \
        | sed -E 's/^\s*- \[ \] //' \
        || true
    return 0
}

#######################################
# Get PR numbers linked to active tasks in TODO.md
# Returns: newline-separated list of PR numbers
#######################################
get_linked_pr_numbers() {
    local repo_path="$1"
    local todo_file="${repo_path}/TODO.md"
    if [[ ! -f "$todo_file" ]]; then
        return 0
    fi
    # Extract pr:#NNN or pr:NNN from unchecked task lines
    grep -E '^\s*- \[ \]' "$todo_file" 2>/dev/null \
        | grep -oE 'pr:#?[0-9]+' \
        | sed -E 's/pr:#?//' \
        || true
    return 0
}

#######################################
# Get task IDs from supervisor DB that are actively being worked on
# Returns: newline-separated list of task IDs
#######################################
get_active_db_task_ids() {
    local supervisor_db="${HOME}/.aidevops/.agent-workspace/supervisor/supervisor.db"
    if [[ ! -f "$supervisor_db" ]]; then
        return 0
    fi
    sqlite3 -cmd ".timeout 5000" "$supervisor_db" \
        "SELECT id FROM tasks WHERE status IN ('queued', 'dispatched', 'running', 'evaluating', 'retrying', 'complete', 'pr_review', 'review_triage', 'merging');" \
        2>/dev/null || true
    return 0
}

#######################################
# Get PR URLs linked in supervisor DB
# Returns: newline-separated list of PR URLs
#######################################
get_db_linked_pr_urls() {
    local supervisor_db="${HOME}/.aidevops/.agent-workspace/supervisor/supervisor.db"
    if [[ ! -f "$supervisor_db" ]]; then
        return 0
    fi
    sqlite3 -cmd ".timeout 5000" "$supervisor_db" \
        "SELECT pr_url FROM tasks WHERE pr_url IS NOT NULL AND pr_url != '' AND pr_url != 'no_pr' AND pr_url != 'task_only' AND pr_url != 'task_obsolete';" \
        2>/dev/null || true
    return 0
}

#######################################
# Check if a PR branch matches any active task ID
# Arguments: branch name, active task IDs (newline-separated)
# Returns: 0 if linked, 1 if not
#######################################
is_branch_linked_to_task() {
    local branch="$1"
    local active_ids="$2"
    if [[ -z "$active_ids" ]]; then
        return 1
    fi
    # Check if branch contains any active task ID (e.g., feature/t123, t123-fix)
    while IFS= read -r tid; do
        [[ -n "$tid" ]] || continue
        if [[ "$branch" == *"$tid"* ]]; then
            return 0
        fi
    done <<< "$active_ids"
    return 1
}

#######################################
# Check if a PR number is in the linked set
# Arguments: PR number, linked PR numbers (newline-separated)
# Returns: 0 if linked, 1 if not
#######################################
is_pr_number_linked() {
    local pr_number="$1"
    local linked_numbers="$2"
    if [[ -z "$linked_numbers" ]]; then
        return 1
    fi
    while IFS= read -r num; do
        [[ -n "$num" ]] || continue
        if [[ "$pr_number" == "$num" ]]; then
            return 0
        fi
    done <<< "$linked_numbers"
    return 1
}

#######################################
# Check if a PR URL is in the DB-linked set
# Arguments: PR URL, linked PR URLs (newline-separated)
# Returns: 0 if linked, 1 if not
#######################################
is_pr_url_linked_in_db() {
    local pr_url="$1"
    local linked_urls="$2"
    if [[ -z "$linked_urls" ]]; then
        return 1
    fi
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        if [[ "$pr_url" == "$url" ]]; then
            return 0
        fi
    done <<< "$linked_urls"
    return 1
}

#######################################
# Calculate PR age in hours from ISO 8601 date
# Arguments: ISO 8601 date string (e.g., 2026-02-09T10:30:00Z)
# Returns: age in hours (integer, rounded down)
#######################################
pr_age_hours() {
    local created_at="$1"
    local now_epoch
    now_epoch=$(date +%s)
    local created_epoch
    # macOS date -j -f and GNU date -d both handle ISO 8601
    if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s >/dev/null 2>&1; then
        created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || echo 0)
    elif date -d "$created_at" +%s >/dev/null 2>&1; then
        created_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo 0)
    else
        # Fallback: try stripping timezone and parsing
        local stripped
        stripped=$(echo "$created_at" | sed 's/T/ /; s/Z//')
        if date -d "$stripped" +%s >/dev/null 2>&1; then
            created_epoch=$(date -d "$stripped" +%s 2>/dev/null || echo 0)
        else
            log_warn "Cannot parse date: $created_at"
            echo 0
            return 0
        fi
    fi
    local age_seconds=$((now_epoch - created_epoch))
    local age_hours=$((age_seconds / 3600))
    echo "$age_hours"
    return 0
}

#######################################
# Send notification for a stale PR via mail-helper.sh
# Arguments: PR number, PR title, PR URL, PR branch, age in hours, repo slug
#######################################
send_notification() {
    local pr_number="$1"
    local pr_title="$2"
    local pr_url="$3"
    local pr_branch="$4"
    local age_hours="$5"
    local repo_slug="$6"

    local mail_helper="${SCRIPT_DIR}/mail-helper.sh"
    if [[ ! -x "$mail_helper" ]]; then
        log_warn "mail-helper.sh not found or not executable — skipping notification"
        return 1
    fi

    local payload="Stale PR detected: #${pr_number} (${age_hours}h old) in ${repo_slug}
Title: ${pr_title}
Branch: ${pr_branch}
URL: ${pr_url}
Action: Review, merge, or close this PR. It is not linked to any active task."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would notify: PR #${pr_number} — ${pr_title} (${age_hours}h old)"
        return 0
    fi

    bash "$mail_helper" send \
        --to supervisor \
        --type discovery \
        --priority normal \
        --payload "$payload" 2>/dev/null || {
        log_warn "Failed to send notification for PR #${pr_number}"
        return 1
    }

    mark_notified "$pr_number"
    log_info "Notified: PR #${pr_number} — ${pr_title} (${age_hours}h old)"
    return 0
}

#######################################
# Main scan logic
# Fetches open PRs, filters by age and linkage, sends notifications
#######################################
cmd_scan() {
    ensure_dirs

    if ! check_throttle; then
        return 0
    fi

    if ! validate_command_exists "gh"; then
        log_error "GitHub CLI (gh) is required but not installed"
        return 1
    fi

    if ! validate_command_exists "jq"; then
        log_error "jq is required but not installed"
        return 1
    fi

    local repo_slug
    repo_slug=$(detect_repo_slug "$REPO_PATH") || return 1

    if [[ "$VERBOSE" == true ]]; then
        log_info "Scanning ${repo_slug} for PRs older than ${THRESHOLD_HOURS}h..."
    fi

    # Fetch open PRs with creation date, author, and branch info
    local pr_json
    pr_json=$(gh pr list --repo "$repo_slug" --state open --limit 100 \
        --json number,title,headRefName,url,createdAt,author,isDraft 2>/dev/null || echo "")

    if [[ -z "$pr_json" || "$pr_json" == "[]" ]]; then
        update_throttle
        if [[ "$VERBOSE" == true ]]; then
            log_info "No open PRs found"
        fi
        return 0
    fi

    # Gather linkage data
    local active_task_ids
    active_task_ids=$(get_active_task_ids "$REPO_PATH")
    local active_db_ids
    active_db_ids=$(get_active_db_task_ids)
    # Combine both sources of active task IDs
    local all_active_ids
    all_active_ids=$(printf '%s\n%s' "$active_task_ids" "$active_db_ids" | sort -u | grep -v '^$' || true)

    local linked_pr_numbers
    linked_pr_numbers=$(get_linked_pr_numbers "$REPO_PATH")
    local linked_pr_urls
    linked_pr_urls=$(get_db_linked_pr_urls)

    # Process each PR
    local stale_count=0
    local total_prs
    total_prs=$(echo "$pr_json" | jq 'length' 2>/dev/null || echo 0)
    local notified_count=0

    local i=0
    while [[ "$i" -lt "$total_prs" ]]; do
        local pr_number pr_title pr_branch pr_url pr_created_at pr_is_draft
        pr_number=$(echo "$pr_json" | jq -r ".[$i].number" 2>/dev/null || echo "")
        pr_title=$(echo "$pr_json" | jq -r ".[$i].title" 2>/dev/null || echo "")
        pr_branch=$(echo "$pr_json" | jq -r ".[$i].headRefName" 2>/dev/null || echo "")
        pr_url=$(echo "$pr_json" | jq -r ".[$i].url" 2>/dev/null || echo "")
        pr_created_at=$(echo "$pr_json" | jq -r ".[$i].createdAt" 2>/dev/null || echo "")
        pr_is_draft=$(echo "$pr_json" | jq -r ".[$i].isDraft" 2>/dev/null || echo "false")

        i=$((i + 1))

        [[ -n "$pr_number" && "$pr_number" != "null" ]] || continue

        # Calculate age
        local age
        age=$(pr_age_hours "$pr_created_at")
        if [[ "$age" -lt "$THRESHOLD_HOURS" ]]; then
            if [[ "$VERBOSE" == true ]]; then
                log_info "  PR #${pr_number}: ${age}h old — below threshold, skipping"
            fi
            continue
        fi

        # Check linkage: is this PR linked to an active task?
        local linked=false

        # Check 1: PR number in TODO.md pr: field
        if is_pr_number_linked "$pr_number" "$linked_pr_numbers"; then
            linked=true
        fi

        # Check 2: PR URL in supervisor DB
        if [[ "$linked" == false ]] && is_pr_url_linked_in_db "$pr_url" "$linked_pr_urls"; then
            linked=true
        fi

        # Check 3: Branch name contains an active task ID
        if [[ "$linked" == false ]] && is_branch_linked_to_task "$pr_branch" "$all_active_ids"; then
            linked=true
        fi

        # Check 4: PR title contains an active task ID
        if [[ "$linked" == false ]]; then
            while IFS= read -r tid; do
                [[ -n "$tid" ]] || continue
                if [[ "$pr_title" == *"$tid"* ]]; then
                    linked=true
                    break
                fi
            done <<< "$all_active_ids"
        fi

        if [[ "$linked" == true ]]; then
            if [[ "$VERBOSE" == true ]]; then
                log_info "  PR #${pr_number}: ${age}h old — linked to active task, skipping"
            fi
            continue
        fi

        # This PR is stale and unlinked
        stale_count=$((stale_count + 1))

        # Check notification cooldown
        if is_recently_notified "$pr_number"; then
            if [[ "$VERBOSE" == true ]]; then
                log_info "  PR #${pr_number}: ${age}h old — already notified within cooldown"
            fi
            continue
        fi

        # Send notification
        local draft_label=""
        if [[ "$pr_is_draft" == "true" ]]; then
            draft_label=" [DRAFT]"
        fi
        send_notification "$pr_number" "${pr_title}${draft_label}" "$pr_url" "$pr_branch" "$age" "$repo_slug"
        notified_count=$((notified_count + 1))
    done

    update_throttle

    if [[ "$stale_count" -gt 0 ]]; then
        log_warn "Found $stale_count stale PR(s) (>${THRESHOLD_HOURS}h, unlinked). Notified: $notified_count"
    elif [[ "$VERBOSE" == true ]]; then
        log_success "No stale PRs found (checked $total_prs open PRs)"
    fi

    return 0
}

#######################################
# Report command — print stale PR summary to stdout (no notifications)
#######################################
cmd_report() {
    ensure_dirs

    if ! validate_command_exists "gh"; then
        log_error "GitHub CLI (gh) is required but not installed"
        return 1
    fi

    if ! validate_command_exists "jq"; then
        log_error "jq is required but not installed"
        return 1
    fi

    local repo_slug
    repo_slug=$(detect_repo_slug "$REPO_PATH") || return 1

    log_info "Stale PR Report for ${repo_slug} (threshold: ${THRESHOLD_HOURS}h)"
    echo "---"

    local pr_json
    pr_json=$(gh pr list --repo "$repo_slug" --state open --limit 100 \
        --json number,title,headRefName,url,createdAt,author,isDraft 2>/dev/null || echo "")

    if [[ -z "$pr_json" || "$pr_json" == "[]" ]]; then
        echo "No open PRs found."
        return 0
    fi

    local active_task_ids
    active_task_ids=$(get_active_task_ids "$REPO_PATH")
    local active_db_ids
    active_db_ids=$(get_active_db_task_ids)
    local all_active_ids
    all_active_ids=$(printf '%s\n%s' "$active_task_ids" "$active_db_ids" | sort -u | grep -v '^$' || true)

    local linked_pr_numbers
    linked_pr_numbers=$(get_linked_pr_numbers "$REPO_PATH")
    local linked_pr_urls
    linked_pr_urls=$(get_db_linked_pr_urls)

    local total_prs
    total_prs=$(echo "$pr_json" | jq 'length' 2>/dev/null || echo 0)
    local stale_count=0

    local i=0
    while [[ "$i" -lt "$total_prs" ]]; do
        local pr_number pr_title pr_branch pr_url pr_created_at pr_author pr_is_draft
        pr_number=$(echo "$pr_json" | jq -r ".[$i].number" 2>/dev/null || echo "")
        pr_title=$(echo "$pr_json" | jq -r ".[$i].title" 2>/dev/null || echo "")
        pr_branch=$(echo "$pr_json" | jq -r ".[$i].headRefName" 2>/dev/null || echo "")
        pr_url=$(echo "$pr_json" | jq -r ".[$i].url" 2>/dev/null || echo "")
        pr_created_at=$(echo "$pr_json" | jq -r ".[$i].createdAt" 2>/dev/null || echo "")
        pr_author=$(echo "$pr_json" | jq -r ".[$i].author.login" 2>/dev/null || echo "unknown")
        pr_is_draft=$(echo "$pr_json" | jq -r ".[$i].isDraft" 2>/dev/null || echo "false")

        i=$((i + 1))

        [[ -n "$pr_number" && "$pr_number" != "null" ]] || continue

        local age
        age=$(pr_age_hours "$pr_created_at")
        if [[ "$age" -lt "$THRESHOLD_HOURS" ]]; then
            continue
        fi

        # Check linkage
        local linked=false
        if is_pr_number_linked "$pr_number" "$linked_pr_numbers"; then
            linked=true
        fi
        if [[ "$linked" == false ]] && is_pr_url_linked_in_db "$pr_url" "$linked_pr_urls"; then
            linked=true
        fi
        if [[ "$linked" == false ]] && is_branch_linked_to_task "$pr_branch" "$all_active_ids"; then
            linked=true
        fi
        if [[ "$linked" == false ]]; then
            while IFS= read -r tid; do
                [[ -n "$tid" ]] || continue
                if [[ "$pr_title" == *"$tid"* ]]; then
                    linked=true
                    break
                fi
            done <<< "$all_active_ids"
        fi

        local status_label="STALE"
        if [[ "$linked" == true ]]; then
            status_label="LINKED"
        fi

        local draft_label=""
        if [[ "$pr_is_draft" == "true" ]]; then
            draft_label=" [DRAFT]"
        fi

        if [[ "$linked" == false ]]; then
            stale_count=$((stale_count + 1))
            echo "  [${status_label}] PR #${pr_number}${draft_label} — ${age}h old — @${pr_author}"
            echo "    Title:  ${pr_title}"
            echo "    Branch: ${pr_branch}"
            echo "    URL:    ${pr_url}"
            echo ""
        elif [[ "$VERBOSE" == true ]]; then
            echo "  [${status_label}] PR #${pr_number}${draft_label} — ${age}h old — @${pr_author}"
            echo "    Title:  ${pr_title}"
            echo "    Branch: ${pr_branch}"
            echo ""
        fi
    done

    echo "---"
    echo "Total open PRs: ${total_prs} | Stale (>${THRESHOLD_HOURS}h, unlinked): ${stale_count}"
    return 0
}

#######################################
# Show help
#######################################
cmd_help() {
    sed -n '2,/^$/{ s/^# //; s/^#//; p; }' "$0"
    return 0
}

#######################################
# Parse arguments and dispatch
#######################################
main() {
    local command="${1:-help}"
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)
                REPO_PATH="${2:-.}"
                shift 2
                ;;
            --threshold)
                THRESHOLD_HOURS="${2:-$DEFAULT_THRESHOLD_HOURS}"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                cmd_help
                return 1
                ;;
        esac
    done

    # Default repo path to current directory
    if [[ -z "$REPO_PATH" ]]; then
        REPO_PATH="$(pwd)"
    fi

    case "$command" in
        scan)
            cmd_scan
            ;;
        report)
            cmd_report
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            log_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
