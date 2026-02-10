#!/usr/bin/env bash
# shellcheck disable=SC2155
#
# migrate-pr-backfill.sh — Retroactive PR backfill for supervisor DB (t237)
#
# One-time data migration: for each deployed/verified/complete/merged task with
# no_pr/task_only/empty pr_url, search GitHub for merged PRs matching the task's
# branch or containing the task ID in the title. Validate matches and update DB.
#
# Uses the same validation logic as validate_pr_belongs_to_task() (t232):
#   - PR title or branch must contain the task ID as a word boundary match
#   - Prevents cross-contamination between tasks
#
# Usage:
#   migrate-pr-backfill.sh [--dry-run] [--verbose] [--task <id>]
#
# Options:
#   --dry-run   Show what would be updated without making changes
#   --verbose   Show detailed output for each task
#   --task <id> Process only a specific task ID (for testing)
#
# Exit codes:
#   0 — Migration completed (some tasks may remain unmatched)
#   1 — Fatal error (DB not found, GitHub CLI unavailable)

set -euo pipefail

# --- Configuration -----------------------------------------------------------

readonly SUPERVISOR_DIR="${HOME}/.aidevops/.agent-workspace/supervisor"
readonly SUPERVISOR_DB="${SUPERVISOR_DIR}/supervisor.db"
readonly MIGRATION_LOG="${SUPERVISOR_DIR}/migrate-pr-backfill.log"

DRY_RUN="false"
VERBOSE="false"
SINGLE_TASK=""

# --- Argument parsing ---------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN="true"; shift ;;
        --verbose)  VERBOSE="true"; shift ;;
        --task)     SINGLE_TASK="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Helpers ------------------------------------------------------------------

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$MIGRATION_LOG"; }
log_verbose() { [[ "$VERBOSE" == "true" ]] && log "  $*" || true; }

db() {
    sqlite3 -cmd ".timeout 5000" "$@"
}

sql_escape() {
    local input="$1"
    echo "${input//\'/\'\'}"
}

# --- Pre-flight checks --------------------------------------------------------

if [[ ! -f "$SUPERVISOR_DB" ]]; then
    echo "ERROR: Supervisor DB not found at $SUPERVISOR_DB" >&2
    exit 1
fi

if ! command -v gh &>/dev/null; then
    echo "ERROR: GitHub CLI (gh) not found" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq not found" >&2
    exit 1
fi

# Verify gh is authenticated
if ! gh auth status &>/dev/null; then
    echo "ERROR: GitHub CLI not authenticated (run 'gh auth login')" >&2
    exit 1
fi

# --- Detect repo slug ---------------------------------------------------------

detect_repo_slug() {
    local project_root="${1:-.}"
    local remote_url
    remote_url=$(git -C "$project_root" remote get-url origin 2>/dev/null || echo "")
    remote_url="${remote_url%.git}"
    local slug
    slug=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|' || echo "")
    if [[ -z "$slug" ]]; then
        return 1
    fi
    echo "$slug"
    return 0
}

# --- Validate PR belongs to task (mirrors supervisor-helper.sh:5110) ----------

validate_pr_belongs_to_task() {
    local task_id="$1"
    local repo_slug="$2"
    local pr_url="$3"

    if [[ -z "$pr_url" || -z "$task_id" || -z "$repo_slug" ]]; then
        return 1
    fi

    local pr_number
    pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$' || echo "")
    if [[ -z "$pr_number" ]]; then
        return 1
    fi

    # Fetch PR title and head branch with retry + exponential backoff (t211)
    local pr_info="" attempt max_attempts=3 backoff=2
    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        pr_info=$(gh pr view "$pr_number" --repo "$repo_slug" \
            --json title,headRefName 2>/dev/null || echo "")
        if [[ -n "$pr_info" ]]; then
            break
        fi
        if (( attempt < max_attempts )); then
            log_verbose "validate: attempt $attempt/$max_attempts failed for PR #$pr_number — retrying in ${backoff}s"
            sleep "$backoff"
            backoff=$(( backoff * 2 ))
        fi
    done

    if [[ -z "$pr_info" ]]; then
        log_verbose "validate: cannot fetch PR #$pr_number after $max_attempts attempts"
        return 1
    fi

    local pr_title pr_branch
    pr_title=$(echo "$pr_info" | jq -r '.title // ""' 2>/dev/null || echo "")
    pr_branch=$(echo "$pr_info" | jq -r '.headRefName // ""' 2>/dev/null || echo "")

    # Word boundary match: "t195" matches "feature/t195" but not "t1950"
    if echo "$pr_title" | grep -qi "\b${task_id}\b" 2>/dev/null; then
        echo "$pr_url"
        return 0
    fi

    if echo "$pr_branch" | grep -qi "\b${task_id}\b" 2>/dev/null; then
        echo "$pr_url"
        return 0
    fi

    log_verbose "validate: PR #$pr_number does not reference $task_id (title='$pr_title', branch='$pr_branch')"
    return 1
}

# --- Write proof log entry (mirrors supervisor-helper.sh:264) -----------------

write_proof_log() {
    local task_id="$1"
    local event="$2"
    local decision="$3"
    local evidence="$4"
    local pr_url="${5:-}"

    local escaped_task escaped_event escaped_decision escaped_evidence escaped_pr
    escaped_task=$(sql_escape "$task_id")
    escaped_event=$(sql_escape "$event")
    escaped_decision=$(sql_escape "$decision")
    escaped_evidence=$(sql_escape "$evidence")
    escaped_pr=$(sql_escape "$pr_url")

    db "$SUPERVISOR_DB" "
        INSERT INTO proof_logs (task_id, event, stage, decision, evidence, decision_maker, pr_url)
        VALUES ('$escaped_task', '$escaped_event', 'pr_backfill', '$escaped_decision', '$escaped_evidence', 'migrate-pr-backfill.sh (t237)', '$escaped_pr');
    " 2>/dev/null || true
}

# --- Fetch all merged PRs from GitHub ----------------------------------------

fetch_merged_prs() {
    local repo_slug="$1"
    local cache_file="${SUPERVISOR_DIR}/migrate-pr-backfill-cache.json"

    # Use cache if less than 5 minutes old
    if [[ -f "$cache_file" ]]; then
        local cache_age
        cache_age=$(( $(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if (( cache_age < 300 )); then
            log "Using cached PR list (${cache_age}s old)"
            cat "$cache_file"
            return 0
        fi
    fi

    log "Fetching all merged PRs from $repo_slug (this may take a moment)..."
    if ! gh pr list --repo "$repo_slug" --state merged --limit 1000 \
        --json number,title,headRefName,url 2>/dev/null > "$cache_file"; then
        echo "ERROR: Failed to fetch merged PRs" >&2
        return 1
    fi

    local count
    count=$(jq 'length' "$cache_file")
    log "Fetched $count merged PRs"
    cat "$cache_file"
    return 0
}

# --- Search merged PRs for a task ID -----------------------------------------

search_prs_for_task() {
    local task_id="$1"
    local merged_prs_json="$2"

    # Search by branch name: feature/{task_id} or containing task_id
    # Search by title: containing task_id as word boundary
    # jq filter: match task_id in headRefName or title (case-insensitive)
    local matches
    matches=$(echo "$merged_prs_json" | jq -r --arg tid "$task_id" '
        [.[] | select(
            (.headRefName | test("\\b" + $tid + "\\b"; "i")) or
            (.title | test("\\b" + $tid + "\\b"; "i"))
        )] | sort_by(.number) | reverse | .[].url
    ' 2>/dev/null || echo "")

    echo "$matches"
}

# --- Main migration -----------------------------------------------------------

main() {
    log "=== PR Backfill Migration (t237) ==="
    [[ "$DRY_RUN" == "true" ]] && log "DRY RUN — no changes will be made"

    # Get tasks needing backfill
    local task_query
    if [[ -n "$SINGLE_TASK" ]]; then
        local escaped_single
        escaped_single=$(sql_escape "$SINGLE_TASK")
        task_query="SELECT id, status, repo, branch, pr_url FROM tasks WHERE id = '$escaped_single';"
    else
        task_query="
            SELECT id, status, repo, branch, pr_url FROM tasks
            WHERE status IN ('deployed','verified','complete','merged')
            AND (pr_url IS NULL OR pr_url = '' OR pr_url = 'no_pr'
                 OR pr_url = 'task_only' OR pr_url = 'task_obsolete')
            ORDER BY id;
        "
    fi

    local tasks_raw
    tasks_raw=$(db -separator '|' "$SUPERVISOR_DB" "$task_query" 2>/dev/null || echo "")

    if [[ -z "$tasks_raw" ]]; then
        log "No tasks found needing PR backfill"
        exit 0
    fi

    local task_count
    task_count=$(echo "$tasks_raw" | wc -l | tr -d ' ')
    log "Found $task_count tasks to process"

    # Determine repo slug from first task's repo path
    local first_repo
    first_repo=$(echo "$tasks_raw" | head -1 | cut -d'|' -f3)
    local repo_slug
    repo_slug=$(detect_repo_slug "$first_repo") || {
        echo "ERROR: Cannot detect repo slug from $first_repo" >&2
        exit 1
    }
    log "Repo slug: $repo_slug"

    # Fetch all merged PRs
    local merged_prs_json
    merged_prs_json=$(fetch_merged_prs "$repo_slug") || exit 1

    # Counters
    local matched=0 unmatched=0 skipped=0 errors=0 already_linked=0

    # Process each task
    while IFS='|' read -r task_id status _repo branch pr_url; do
        [[ -z "$task_id" ]] && continue

        log_verbose "Processing $task_id (status=$status, branch=$branch, pr_url=${pr_url:-<empty>})"

        # Search for matching PRs in the pre-fetched list
        local candidate_urls
        candidate_urls=$(search_prs_for_task "$task_id" "$merged_prs_json")

        if [[ -z "$candidate_urls" ]]; then
            log_verbose "No merged PR found for $task_id"
            ((unmatched++)) || true

            if [[ "$DRY_RUN" != "true" ]]; then
                write_proof_log "$task_id" "pr_backfill" \
                    "no_match" \
                    "No merged PR found matching task ID in branch or title (searched $repo_slug)" \
                    ""
            fi
            continue
        fi

        # Try each candidate (most recent first) until one validates
        local linked="false"
        while IFS= read -r candidate_url; do
            [[ -z "$candidate_url" ]] && continue

            log_verbose "Candidate for $task_id: $candidate_url"

            # Validate the PR belongs to this task
            local validated_url
            validated_url=$(validate_pr_belongs_to_task "$task_id" "$repo_slug" "$candidate_url") || validated_url=""

            if [[ -z "$validated_url" ]]; then
                log_verbose "Validation failed for $task_id <-> $candidate_url"
                continue
            fi

            # Check if this PR is already linked to another task
            local existing_task
            existing_task=$(db "$SUPERVISOR_DB" "
                SELECT id FROM tasks
                WHERE pr_url = '$(sql_escape "$validated_url")'
                AND id != '$(sql_escape "$task_id")';
            " 2>/dev/null || echo "")

            if [[ -n "$existing_task" ]]; then
                log "SKIP $task_id: PR $validated_url already linked to $existing_task"
                ((already_linked++)) || true

                if [[ "$DRY_RUN" != "true" ]]; then
                    write_proof_log "$task_id" "pr_backfill" \
                        "skip_cross_linked" \
                        "PR already linked to task $existing_task — not overwriting" \
                        "$validated_url"
                fi
                linked="skip"
                break
            fi

            # Apply the update
            if [[ "$DRY_RUN" == "true" ]]; then
                log "DRY RUN: Would link $task_id -> $validated_url"
                linked="true"
                break
            else
                if db "$SUPERVISOR_DB" "
                    UPDATE tasks SET pr_url = '$(sql_escape "$validated_url")'
                    WHERE id = '$(sql_escape "$task_id")';
                " 2>/dev/null; then
                    log "LINKED $task_id -> $validated_url"
                    write_proof_log "$task_id" "pr_backfill" \
                        "linked" \
                        "Retroactive PR backfill: matched merged PR via branch/title search" \
                        "$validated_url"
                    linked="true"
                    break
                else
                    log "ERROR: Failed to update DB for $task_id"
                    ((errors++)) || true
                    linked="error"
                    break
                fi
            fi
        done <<< "$candidate_urls"

        case "$linked" in
            true)  ((matched++)) || true ;;
            skip)  ;; # already counted in already_linked
            error) ;; # already counted in errors
            *)     ((unmatched++)) || true ;;
        esac

        # Rate limit: small delay between GitHub API calls to avoid rate limiting
        sleep 0.5

    done <<< "$tasks_raw"

    # Summary
    log ""
    log "=== Migration Summary ==="
    log "Total tasks processed: $task_count"
    log "PRs linked:           $matched"
    log "No PR found:          $unmatched"
    log "Already cross-linked: $already_linked"
    log "Errors:               $errors"
    log "Skipped:              $skipped"
    [[ "$DRY_RUN" == "true" ]] && log "(DRY RUN — no changes were made)"
    log "========================="

    return 0
}

main "$@"
