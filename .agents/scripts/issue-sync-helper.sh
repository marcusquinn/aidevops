#!/usr/bin/env bash
# shellcheck disable=SC2155
# =============================================================================
# aidevops Issue Sync Helper
# =============================================================================
# Bi-directional sync between TODO.md/PLANS.md and GitHub issues.
# Composes rich issue bodies with subtasks, plan context, and PRD links.
#
# Usage: issue-sync-helper.sh [command] [options]
#
# Commands:
#   push [tNNN]     Create/update GitHub issues from TODO.md tasks
#   enrich [tNNN]   Update existing issue bodies with full context
#   pull            Sync GitHub issue refs back to TODO.md
#   close [tNNN]    Close GitHub issue when TODO.md task is [x]
#   status          Show sync drift between TODO.md and GitHub
#   parse [tNNN]    Parse and display task context (dry-run)
#   help            Show this help message
#
# Options:
#   --repo SLUG     Override repo slug (default: auto-detect from git remote)
#   --dry-run       Show what would be done without making changes
#   --verbose       Show detailed output
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Configuration
# =============================================================================

VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
REPO_SLUG=""

# =============================================================================
# Utility Functions
# =============================================================================

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        print_info "$1"
    fi
    return 0
}

# Find project root (contains TODO.md)
find_project_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/TODO.md" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    print_error "No TODO.md found in directory tree"
    return 1
}

# Detect repo slug from git remote
detect_repo_slug() {
    local project_root="$1"
    local slug
    local remote_url
    remote_url=$(git -C "$project_root" remote get-url origin 2>/dev/null || echo "")
    # Handle both HTTPS (github.com/owner/repo.git) and SSH (git@github.com:owner/repo.git)
    remote_url="${remote_url%.git}"  # Strip .git suffix
    slug=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|' || echo "")
    if [[ -z "$slug" ]]; then
        print_error "Could not detect GitHub repo slug from git remote"
        return 1
    fi
    echo "$slug"
    return 0
}

# Verify gh CLI is available and authenticated
verify_gh_cli() {
    if ! command -v gh &>/dev/null; then
        print_error "gh CLI not installed. Install with: brew install gh"
        return 1
    fi
    if ! gh auth status &>/dev/null 2>&1; then
        print_error "gh CLI not authenticated. Run: gh auth login"
        return 1
    fi
    return 0
}

# =============================================================================
# TODO.md Parser
# =============================================================================

# Parse a single task line from TODO.md
# Returns structured data as key=value pairs
parse_task_line() {
    local line="$1"

    # Extract checkbox status
    local status="open"
    if echo "$line" | grep -qE '^\s*- \[x\]'; then
        status="completed"
    elif echo "$line" | grep -qE '^\s*- \[-\]'; then
        status="declined"
    fi

    # Extract task ID
    local task_id
    task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")

    # Extract description (between task ID and first #tag or ~estimate or →)
    local description
    description=$(echo "$line" | sed -E 's/^\s*- \[.\] t[0-9]+(\.[0-9]+)* //' | sed -E 's/ (#[a-z]|~[0-9]|→ |logged:|started:|completed:|ref:|actual:|blocked-by:).*//' || echo "")

    # Extract tags
    local tags
    tags=$(echo "$line" | grep -oE '#[a-z][a-z0-9-]*' | tr '\n' ',' | sed 's/,$//' || echo "")

    # Extract estimate
    local estimate
    estimate=$(echo "$line" | grep -oE '~[0-9]+[hmd](\s*\(ai:[^)]+\))?' | head -1 || echo "")

    # Extract plan link
    local plan_link
    plan_link=$(echo "$line" | grep -oE '→ \[todo/PLANS\.md#[^]]+\]' | sed 's/→ \[//' | sed 's/\]//' || echo "")

    # Extract existing GH ref
    local gh_ref
    gh_ref=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")

    # Extract logged date
    local logged
    logged=$(echo "$line" | grep -oE 'logged:[0-9-]+' | sed 's/logged://' || echo "")

    echo "task_id=$task_id"
    echo "status=$status"
    echo "description=$description"
    echo "tags=$tags"
    echo "estimate=$estimate"
    echo "plan_link=$plan_link"
    echo "gh_ref=$gh_ref"
    echo "logged=$logged"
    return 0
}

# Extract a task and all its subtasks + notes from TODO.md
# Returns the full block of text for a given task ID
extract_task_block() {
    local task_id="$1"
    local todo_file="$2"

    local in_block=false
    local block=""
    local task_indent=-1

    while IFS= read -r line; do
        # Check if this is the target task line
        if [[ "$in_block" == "false" ]] && echo "$line" | grep -qE "^\s*- \[.\] ${task_id} "; then
            in_block=true
            block="$line"
            # Calculate indent level
            task_indent=$(echo "$line" | sed -E 's/[^ ].*//' | wc -c)
            task_indent=$((task_indent - 1))
            continue
        fi

        if [[ "$in_block" == "true" ]]; then
            # Check if we've hit the next task at same or lower indent
            local current_indent
            current_indent=$(echo "$line" | sed -E 's/[^ ].*//' | wc -c)
            current_indent=$((current_indent - 1))

            # Empty lines within block are kept
            if [[ -z "${line// /}" ]]; then
                break
            fi

            # If indent is <= task indent and it's a new task, we're done
            if [[ $current_indent -le $task_indent ]] && echo "$line" | grep -qE '^\s*- \[.\] t[0-9]'; then
                break
            fi

            # If indent is <= task indent and it's not a subtask/notes line, we're done
            if [[ $current_indent -le $task_indent ]] && ! echo "$line" | grep -qE '^\s*- '; then
                break
            fi

            block="$block"$'\n'"$line"
        fi
    done < "$todo_file"

    echo "$block"
    return 0
}

# Extract subtasks from a task block
extract_subtasks() {
    local block="$1"
    # Skip the first line (parent task), get indented subtask lines
    echo "$block" | tail -n +2 | grep -E '^\s+- \[.\] t[0-9]' || true
    return 0
}

# Extract Notes from a task block
extract_notes() {
    local block="$1"
    echo "$block" | grep -E '^\s+- Notes:' | sed 's/^\s*- Notes: //' || true
    return 0
}

# =============================================================================
# PLANS.md Parser
# =============================================================================

# Extract a plan section from PLANS.md given an anchor
extract_plan_section() {
    local plan_link="$1"
    local project_root="$2"

    if [[ -z "$plan_link" ]]; then
        return 0
    fi

    local plans_file="$project_root/todo/PLANS.md"
    if [[ ! -f "$plans_file" ]]; then
        log_verbose "PLANS.md not found at $plans_file"
        return 0
    fi

    # Convert anchor to heading text for matching
    # e.g., "todo/PLANS.md#2026-02-08-git-issues-bi-directional-sync"
    local anchor
    anchor="${plan_link#todo/PLANS.md#}"

    # Find the heading that matches the anchor
    local in_section=false
    local section=""
    local heading_level=0

    while IFS= read -r line; do
        # Check for heading match
        if [[ "$in_section" == "false" ]]; then
            # Generate anchor from heading: lowercase, spaces to hyphens, strip special chars
            local line_anchor
            line_anchor=$(echo "$line" | sed -E 's/^#+\s+//' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 -]//g' | sed -E 's/ /-/g')

            if [[ "$line_anchor" == "$anchor" ]] || echo "$line_anchor" | grep -qF "$anchor"; then
                in_section=true
                heading_level=$(echo "$line" | grep -oE '^#+' | wc -c)
                heading_level=$((heading_level - 1))
                section="$line"
                continue
            fi
        fi

        if [[ "$in_section" == "true" ]]; then
            # Check if we've hit the next heading at same or higher level
            if echo "$line" | grep -qE '^#{1,'"$heading_level"'} [^#]'; then
                break
            fi
            section="$section"$'\n'"$line"
        fi
    done < "$plans_file"

    echo "$section"
    return 0
}

# Extract just the Purpose section from a plan
extract_plan_purpose() {
    local plan_section="$1"
    local in_purpose=false
    local purpose=""

    while IFS= read -r line; do
        if echo "$line" | grep -qE '^####\s+Purpose'; then
            in_purpose=true
            continue
        fi
        if [[ "$in_purpose" == "true" ]]; then
            if echo "$line" | grep -qE '^####\s+'; then
                break
            fi
            purpose="$purpose"$'\n'"$line"
        fi
    done <<< "$plan_section"

    echo "$purpose" | sed '/^$/d' | head -20
    return 0
}

# Extract the Decision Log from a plan
extract_plan_decisions() {
    local plan_section="$1"
    local in_decisions=false
    local decisions=""

    while IFS= read -r line; do
        if echo "$line" | grep -qE '^####\s+Decision Log'; then
            in_decisions=true
            continue
        fi
        if [[ "$in_decisions" == "true" ]]; then
            if echo "$line" | grep -qE '^####\s+'; then
                break
            fi
            # Skip TOON blocks
            if echo "$line" | grep -qE '^<!--TOON:'; then
                break
            fi
            decisions="$decisions"$'\n'"$line"
        fi
    done <<< "$plan_section"

    echo "$decisions" | sed '/^$/d'
    return 0
}

# Extract Progress section from a plan
extract_plan_progress() {
    local plan_section="$1"
    local in_progress=false
    local progress=""

    while IFS= read -r line; do
        if echo "$line" | grep -qE '^####\s+Progress'; then
            in_progress=true
            continue
        fi
        if [[ "$in_progress" == "true" ]]; then
            if echo "$line" | grep -qE '^####\s+'; then
                break
            fi
            # Skip TOON blocks
            if echo "$line" | grep -qE '^<!--TOON:'; then
                break
            fi
            progress="$progress"$'\n'"$line"
        fi
    done <<< "$plan_section"

    echo "$progress" | sed '/^$/d'
    return 0
}

# Extract Discoveries section from a plan
extract_plan_discoveries() {
    local plan_section="$1"
    local in_discoveries=false
    local discoveries=""

    while IFS= read -r line; do
        if echo "$line" | grep -qE '^####\s+Surprises'; then
            in_discoveries=true
            continue
        fi
        if [[ "$in_discoveries" == "true" ]]; then
            if echo "$line" | grep -qE '^####\s+|^###\s+'; then
                break
            fi
            # Skip TOON blocks
            if echo "$line" | grep -qE '^<!--TOON:'; then
                break
            fi
            discoveries="$discoveries"$'\n'"$line"
        fi
    done <<< "$plan_section"

    # Only return if there's actual content (not just placeholder text)
    local cleaned
    cleaned=$(echo "$discoveries" | sed '/^$/d' | grep -v 'To be populated' || true)
    echo "$cleaned"
    return 0
}

# =============================================================================
# PRD/Task File Lookup
# =============================================================================

# Find related PRD and task files in todo/tasks/
# Checks both grep matches and explicit ref:todo/tasks/ from the task line
find_related_files() {
    local task_id="$1"
    local project_root="$2"
    local tasks_dir="$project_root/todo/tasks"
    local todo_file="$project_root/TODO.md"
    local all_files=""

    # 1. Follow explicit ref:todo/tasks/ from the task line
    if [[ -f "$todo_file" ]]; then
        local task_line
        task_line=$(grep -E "^- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
        local explicit_refs
        explicit_refs=$(echo "$task_line" | grep -oE 'ref:todo/tasks/[^ ]+' | sed 's/ref://' || true)
        while IFS= read -r ref; do
            if [[ -n "$ref" && -f "$project_root/$ref" ]]; then
                all_files="${all_files:+$all_files"$'\n'"}$project_root/$ref"
            fi
        done <<< "$explicit_refs"
    fi

    # 2. Search for files referencing this task ID in todo/tasks/
    if [[ -d "$tasks_dir" ]]; then
        local grep_files
        grep_files=$(grep -rl "$task_id" "$tasks_dir" 2>/dev/null || true)
        if [[ -n "$grep_files" ]]; then
            all_files="${all_files:+$all_files"$'\n'"}$grep_files"
        fi
    fi

    # Deduplicate
    if [[ -n "$all_files" ]]; then
        echo "$all_files" | sort -u
    fi
    return 0
}

# Extract a summary from a PRD or task file (first meaningful section, max 30 lines)
extract_file_summary() {
    local file_path="$1"
    local max_lines="${2:-30}"

    if [[ ! -f "$file_path" ]]; then
        return 0
    fi

    local summary=""
    local line_count=0
    local in_content=false
    local past_frontmatter=false

    while IFS= read -r line; do
        # Skip YAML frontmatter
        if [[ "$line" == "---" ]] && [[ "$past_frontmatter" == "false" ]]; then
            if [[ "$in_content" == "true" ]]; then
                past_frontmatter=true
                in_content=false
                continue
            fi
            in_content=true
            continue
        fi
        if [[ "$in_content" == "true" ]]; then
            continue
        fi

        # Skip empty lines at the start
        if [[ -z "${line// /}" ]] && [[ $line_count -eq 0 ]]; then
            continue
        fi

        # Skip the title heading (# Title)
        if [[ $line_count -eq 0 ]] && echo "$line" | grep -qE '^# '; then
            summary="$line"
            line_count=1
            continue
        fi

        summary="$summary"$'\n'"$line"
        line_count=$((line_count + 1))

        # Stop at max lines or at a major section break after getting some content
        if [[ $line_count -ge $max_lines ]]; then
            summary="$summary"$'\n'"..."
            break
        fi
    done < "$file_path"

    echo "$summary"
    return 0
}

# =============================================================================
# Tag to Label Mapping
# =============================================================================

# Map TODO.md #tags to GitHub labels
map_tags_to_labels() {
    local tags="$1"

    if [[ -z "$tags" ]]; then
        return 0
    fi

    local labels=""
    local IFS=','
    for tag in $tags; do
        tag="${tag#\#}"  # Remove # prefix if present
        case "$tag" in
            plan) labels="${labels:+$labels,}plan" ;;
            bugfix|bug) labels="${labels:+$labels,}bug" ;;
            enhancement|feat|feature) labels="${labels:+$labels,}enhancement" ;;
            security) labels="${labels:+$labels,}security" ;;
            git|sync) labels="${labels:+$labels,}git" ;;
            orchestration) labels="${labels:+$labels,}orchestration" ;;
            plugins) labels="${labels:+$labels,}plugins" ;;
            architecture) labels="${labels:+$labels,}architecture" ;;
            voice) labels="${labels:+$labels,}voice" ;;
            tools) labels="${labels:+$labels,}tools" ;;
            seo) labels="${labels:+$labels,}seo" ;;
            research) labels="${labels:+$labels,}research" ;;
            agents) labels="${labels:+$labels,}agents" ;;
            browser) labels="${labels:+$labels,}browser" ;;
            mobile) labels="${labels:+$labels,}mobile" ;;
            content) labels="${labels:+$labels,}content" ;;
            accounting) labels="${labels:+$labels,}accounting" ;;
            dashboard) labels="${labels:+$labels,}dashboard" ;;
            multi-model) labels="${labels:+$labels,}multi-model" ;;
            quality|hardening) labels="${labels:+$labels,}quality" ;;
            # Tags that don't map to labels are silently skipped
        esac
    done

    # Deduplicate
    echo "$labels" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//'
    return 0
}

# =============================================================================
# Issue Body Composer
# =============================================================================

# Compose a rich GitHub issue body from all available context
compose_issue_body() {
    local task_id="$1"
    local project_root="$2"

    local todo_file="$project_root/TODO.md"
    if [[ ! -f "$todo_file" ]]; then
        print_error "TODO.md not found at $todo_file"
        return 1
    fi

    # Extract the full task block
    local block
    block=$(extract_task_block "$task_id" "$todo_file")
    if [[ -z "$block" ]]; then
        print_error "Task $task_id not found in TODO.md"
        return 1
    fi

    # Parse the main task line
    local first_line
    first_line=$(echo "$block" | head -1)
    local parsed
    parsed=$(parse_task_line "$first_line")

    # Extract fields from parsed output
    local description tags estimate plan_link status logged
    description=$(echo "$parsed" | grep '^description=' | cut -d= -f2-)
    tags=$(echo "$parsed" | grep '^tags=' | cut -d= -f2-)
    estimate=$(echo "$parsed" | grep '^estimate=' | cut -d= -f2-)
    plan_link=$(echo "$parsed" | grep '^plan_link=' | cut -d= -f2-)
    status=$(echo "$parsed" | grep '^status=' | cut -d= -f2-)
    logged=$(echo "$parsed" | grep '^logged=' | cut -d= -f2-)

    # Start building the body
    local body=""

    # Task metadata
    body="**Task ID:** \`$task_id\`"
    if [[ -n "$estimate" ]]; then
        body="$body | **Estimate:** \`$estimate\`"
    fi
    if [[ -n "$logged" ]]; then
        body="$body | **Logged:** $logged"
    fi
    if [[ -n "$tags" ]]; then
        local formatted_tags
        formatted_tags=$(echo "$tags" | sed 's/,/ /g' | sed 's/#//g' | sed 's/[^ ]*/`&`/g')
        body="$body"$'\n'"**Tags:** $formatted_tags"
    fi

    # Subtasks
    local subtasks
    subtasks=$(extract_subtasks "$block")
    if [[ -n "$subtasks" ]]; then
        body="$body"$'\n\n'"## Subtasks"$'\n'
        while IFS= read -r subtask_line; do
            # Convert TODO.md checkbox format to GitHub checkbox
            local gh_line
            gh_line=$(echo "$subtask_line" | sed -E 's/^\s+//' | sed -E 's/^- \[x\]/- [x]/' | sed -E 's/^- \[ \]/- [ ]/' | sed -E 's/^- \[-\]/- [x] ~~/' )
            # Extract subtask notes if inline
            body="$body"$'\n'"$gh_line"
        done <<< "$subtasks"
    fi

    # Notes
    local notes
    notes=$(extract_notes "$block")
    if [[ -n "$notes" ]]; then
        body="$body"$'\n\n'"## Notes"$'\n\n'"$notes"
    fi

    # Plan context (if linked)
    if [[ -n "$plan_link" ]]; then
        local plan_section
        plan_section=$(extract_plan_section "$plan_link" "$project_root")
        if [[ -n "$plan_section" ]]; then
            # Purpose
            local purpose
            purpose=$(extract_plan_purpose "$plan_section")
            if [[ -n "$purpose" ]]; then
                body="$body"$'\n\n'"## Plan: Purpose"$'\n\n'"$purpose"
            fi

            # Progress
            local progress
            progress=$(extract_plan_progress "$plan_section")
            if [[ -n "$progress" ]]; then
                body="$body"$'\n\n'"<details><summary>Plan: Progress</summary>"$'\n\n'"$progress"$'\n\n'"</details>"
            fi

            # Decisions
            local decisions
            decisions=$(extract_plan_decisions "$plan_section")
            if [[ -n "$decisions" ]]; then
                body="$body"$'\n\n'"<details><summary>Plan: Decision Log</summary>"$'\n\n'"$decisions"$'\n\n'"</details>"
            fi

            # Discoveries
            local discoveries
            discoveries=$(extract_plan_discoveries "$plan_section")
            if [[ -n "$discoveries" ]]; then
                body="$body"$'\n\n'"<details><summary>Plan: Discoveries</summary>"$'\n\n'"$discoveries"$'\n\n'"</details>"
            fi
        fi
    fi

    # Related PRD/task files (with inline content)
    local related_files
    related_files=$(find_related_files "$task_id" "$project_root")
    if [[ -n "$related_files" ]]; then
        body="$body"$'\n\n'"## Related Files"
        while IFS= read -r file; do
            if [[ -n "$file" ]]; then
                local rel_path file_summary
                rel_path="${file#"$project_root"/}"
                file_summary=$(extract_file_summary "$file" 30)
                if [[ -n "$file_summary" ]]; then
                    body="$body"$'\n\n'"<details><summary><code>$rel_path</code></summary>"$'\n\n'"$file_summary"$'\n\n'"</details>"
                else
                    body="$body"$'\n\n'"- [\`$rel_path\`]($rel_path)"
                fi
            fi
        done <<< "$related_files"
    fi

    # Footer
    body="$body"$'\n\n'"---"$'\n'"*Synced from TODO.md by issue-sync-helper.sh*"

    echo "$body"
    return 0
}

# =============================================================================
# Commands
# =============================================================================

# Push: create GitHub issues from TODO.md tasks
cmd_push() {
    local target_task="${1:-}"
    local project_root
    project_root=$(find_project_root) || return 1
    local repo_slug="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
    local todo_file="$project_root/TODO.md"

    verify_gh_cli || return 1

    # Collect tasks to process
    local tasks=()
    if [[ -n "$target_task" ]]; then
        tasks=("$target_task")
    else
        # Find all open tasks without GH refs (top-level only, not subtasks)
        while IFS= read -r line; do
            local tid
            tid=$(echo "$line" | grep -oE 't[0-9]+' | head -1 || echo "")
            if [[ -n "$tid" ]] && ! echo "$line" | grep -qE 'ref:GH#[0-9]+'; then
                # Skip subtasks (indented with more than 0 spaces before the dash)
                if echo "$line" | grep -qE '^- \['; then
                    tasks+=("$tid")
                fi
            fi
        done < <(grep -E '^- \[ \] t[0-9]+' "$todo_file" || true)
    fi

    if [[ ${#tasks[@]} -eq 0 ]]; then
        print_info "No tasks to push (all have ref:GH# or none match)"
        return 0
    fi

    print_info "Processing ${#tasks[@]} task(s) for push to $repo_slug"

    # Ensure status:available label exists (t164 — label may not exist in new repos)
    gh label create "status:available" --repo "$repo_slug" --color "0E8A16" --description "Task is available for claiming" --force 2>/dev/null || true

    local created=0
    local skipped=0
    for task_id in "${tasks[@]}"; do
        log_verbose "Processing $task_id..."

        # Check if issue already exists
        local existing
        existing=$(gh issue list --repo "$repo_slug" --search "in:title ${task_id}:" --json number --jq '.[0].number' 2>/dev/null || echo "")
        if [[ -n "$existing" && "$existing" != "null" ]]; then
            log_verbose "$task_id already has issue #$existing"
            # Add ref to TODO.md if missing
            add_gh_ref_to_todo "$task_id" "$existing" "$todo_file"
            skipped=$((skipped + 1))
            continue
        fi

        # Parse task for title and labels
        local task_line
        task_line=$(grep -E "^- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
        if [[ -z "$task_line" ]]; then
            print_warning "Task $task_id not found in TODO.md"
            continue
        fi

        local parsed
        parsed=$(parse_task_line "$task_line")
        local description
        description=$(echo "$parsed" | grep '^description=' | cut -d= -f2-)
        local tags
        tags=$(echo "$parsed" | grep '^tags=' | cut -d= -f2-)

        local title="${task_id}: ${description}"
        local labels
        labels=$(map_tags_to_labels "$tags")

        # Compose rich body
        local body
        body=$(compose_issue_body "$task_id" "$project_root")

        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY-RUN] Would create: $title"
            if [[ -n "$labels" ]]; then
                print_info "  Labels: $labels"
            fi
            created=$((created + 1))
            continue
        fi

        # Create the issue with status:available label (t164)
        local gh_args=("issue" "create" "--repo" "$repo_slug" "--title" "$title")
        gh_args+=("--body" "$body")
        if [[ -n "$labels" ]]; then
            gh_args+=("--label" "${labels},status:available")
        else
            gh_args+=("--label" "status:available")
        fi

        local issue_url
        issue_url=$(gh "${gh_args[@]}" 2>/dev/null || echo "")
        if [[ -z "$issue_url" ]]; then
            print_error "Failed to create issue for $task_id"
            continue
        fi

        local issue_number
        issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$' || echo "")
        if [[ -n "$issue_number" ]]; then
            print_success "Created #$issue_number: $title"
            add_gh_ref_to_todo "$task_id" "$issue_number" "$todo_file"
            created=$((created + 1))
        fi
    done

    print_info "Push complete: $created created, $skipped skipped (already exist)"
    return 0
}

# Enrich: update existing issue bodies with full context
cmd_enrich() {
    local target_task="${1:-}"
    local project_root
    project_root=$(find_project_root) || return 1
    local repo_slug="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
    local todo_file="$project_root/TODO.md"

    verify_gh_cli || return 1

    # Collect tasks to enrich
    local tasks=()
    if [[ -n "$target_task" ]]; then
        tasks=("$target_task")
    else
        # Find all open tasks WITH GH refs
        while IFS= read -r line; do
            local tid
            tid=$(echo "$line" | grep -oE 't[0-9]+' | head -1 || echo "")
            if [[ -n "$tid" ]]; then
                tasks+=("$tid")
            fi
        done < <(grep -E '^- \[ \] t[0-9]+.*ref:GH#[0-9]+' "$todo_file" || true)
    fi

    if [[ ${#tasks[@]} -eq 0 ]]; then
        print_info "No tasks to enrich"
        return 0
    fi

    print_info "Enriching ${#tasks[@]} issue(s) in $repo_slug"

    local enriched=0
    for task_id in "${tasks[@]}"; do
        # Find the issue number
        local task_line
        task_line=$(grep -E "^- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
        local issue_number
        issue_number=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")

        if [[ -z "$issue_number" ]]; then
            # Try searching GitHub
            issue_number=$(gh issue list --repo "$repo_slug" --search "in:title ${task_id}:" --json number --jq '.[0].number' 2>/dev/null || echo "")
        fi

        if [[ -z "$issue_number" || "$issue_number" == "null" ]]; then
            print_warning "$task_id: no matching GitHub issue found"
            continue
        fi

        # Compose rich body
        local body
        body=$(compose_issue_body "$task_id" "$project_root")

        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY-RUN] Would enrich #$issue_number ($task_id)"
            enriched=$((enriched + 1))
            continue
        fi

        # Update the issue body
        if gh issue edit "$issue_number" --repo "$repo_slug" --body "$body" 2>/dev/null; then
            print_success "Enriched #$issue_number ($task_id)"
            enriched=$((enriched + 1))
        else
            print_error "Failed to enrich #$issue_number ($task_id)"
        fi
    done

    print_info "Enrich complete: $enriched updated"
    return 0
}

# Pull: sync GitHub issue refs back to TODO.md
cmd_pull() {
    local project_root
    project_root=$(find_project_root) || return 1
    local repo_slug="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
    local todo_file="$project_root/TODO.md"

    verify_gh_cli || return 1

    # Get all open issues with t-number prefixes
    local issues_json
    issues_json=$(gh issue list --repo "$repo_slug" --state open --limit 200 --json number,title 2>/dev/null || echo "[]")

    local synced=0
    while IFS= read -r issue_line; do
        local issue_number
        issue_number=$(echo "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
        local issue_title
        issue_title=$(echo "$issue_line" | jq -r '.title' 2>/dev/null || echo "")

        # Extract task ID from issue title
        local task_id
        task_id=$(echo "$issue_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
        if [[ -z "$task_id" ]]; then
            continue
        fi

        # Check if TODO.md already has this ref
        if grep -qE "^- \[.\] ${task_id} .*ref:GH#${issue_number}" "$todo_file" 2>/dev/null; then
            continue
        fi

        # Check if task exists in TODO.md
        if ! grep -qE "^- \[.\] ${task_id} " "$todo_file" 2>/dev/null; then
            log_verbose "Issue #$issue_number ($task_id) has no matching TODO.md entry"
            continue
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY-RUN] Would add ref:GH#$issue_number to $task_id"
            synced=$((synced + 1))
            continue
        fi

        add_gh_ref_to_todo "$task_id" "$issue_number" "$todo_file"
        synced=$((synced + 1))
    done < <(echo "$issues_json" | jq -c '.[]' 2>/dev/null || true)

    # Also check closed issues for completed tasks
    local closed_json
    closed_json=$(gh issue list --repo "$repo_slug" --state closed --limit 200 --json number,title 2>/dev/null || echo "[]")

    while IFS= read -r issue_line; do
        local issue_number
        issue_number=$(echo "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
        local issue_title
        issue_title=$(echo "$issue_line" | jq -r '.title' 2>/dev/null || echo "")

        local task_id
        task_id=$(echo "$issue_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
        if [[ -z "$task_id" ]]; then
            continue
        fi

        if grep -qE "^- \[.\] ${task_id} .*ref:GH#${issue_number}" "$todo_file" 2>/dev/null; then
            continue
        fi

        if ! grep -qE "^- \[.\] ${task_id} " "$todo_file" 2>/dev/null; then
            continue
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY-RUN] Would add ref:GH#$issue_number to $task_id"
            synced=$((synced + 1))
            continue
        fi

        add_gh_ref_to_todo "$task_id" "$issue_number" "$todo_file"
        synced=$((synced + 1))
    done < <(echo "$closed_json" | jq -c '.[]' 2>/dev/null || true)

    print_info "Pull complete: $synced refs synced to TODO.md"
    return 0
}

# Add ref:GH#NNN to a task line in TODO.md
add_gh_ref_to_todo() {
    local task_id="$1"
    local issue_number="$2"
    local todo_file="$3"

    # Check if ref already exists
    if grep -qE "^- \[.\] ${task_id} .*ref:GH#${issue_number}" "$todo_file" 2>/dev/null; then
        return 0
    fi

    # Check if any GH ref exists (might be different number)
    if grep -qE "^- \[.\] ${task_id} .*ref:GH#" "$todo_file" 2>/dev/null; then
        log_verbose "$task_id already has a GH ref, skipping"
        return 0
    fi

    # Add ref before logged: or at end of line
    if grep -qE "^- \[.\] ${task_id} .*logged:" "$todo_file" 2>/dev/null; then
        sed_inplace -E "s/^(- \[.\] ${task_id} .*)( logged:)/\1 ref:GH#${issue_number}\2/" "$todo_file"
    else
        # Append at end of line
        sed_inplace -E "s/^(- \[.\] ${task_id} .*)/\1 ref:GH#${issue_number}/" "$todo_file"
    fi

    log_verbose "Added ref:GH#$issue_number to $task_id"
    return 0
}

# Close: close GitHub issue when TODO.md task is completed
cmd_close() {
    local target_task="${1:-}"
    local project_root
    project_root=$(find_project_root) || return 1
    local repo_slug="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
    local todo_file="$project_root/TODO.md"

    verify_gh_cli || return 1

    # Collect completed tasks with GH refs
    local tasks=()
    if [[ -n "$target_task" ]]; then
        tasks=("$target_task")
    else
        while IFS= read -r line; do
            local tid
            tid=$(echo "$line" | grep -oE 't[0-9]+' | head -1 || echo "")
            if [[ -n "$tid" ]]; then
                tasks+=("$tid")
            fi
        done < <(grep -E '^- \[x\] t[0-9]+.*ref:GH#[0-9]+' "$todo_file" || true)
    fi

    if [[ ${#tasks[@]} -eq 0 ]]; then
        print_info "No completed tasks with GH refs to close"
        return 0
    fi

    local closed=0
    for task_id in "${tasks[@]}"; do
        local task_line
        task_line=$(grep -E "^- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
        local issue_number
        issue_number=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")

        if [[ -z "$issue_number" ]]; then
            continue
        fi

        # Check if issue is already closed
        local issue_state
        issue_state=$(gh issue view "$issue_number" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null || echo "")
        if [[ "$issue_state" == "CLOSED" ]]; then
            log_verbose "#$issue_number already closed"
            continue
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY-RUN] Would close #$issue_number ($task_id)"
            closed=$((closed + 1))
            continue
        fi

        if gh issue close "$issue_number" --repo "$repo_slug" --comment "Completed. Task $task_id marked done in TODO.md." 2>/dev/null; then
            print_success "Closed #$issue_number ($task_id)"
            closed=$((closed + 1))
        else
            print_error "Failed to close #$issue_number ($task_id)"
        fi
    done

    print_info "Close complete: $closed issues closed"
    return 0
}

# Status: show sync drift between TODO.md and GitHub
cmd_status() {
    local project_root
    project_root=$(find_project_root) || return 1
    local repo_slug="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
    local todo_file="$project_root/TODO.md"

    verify_gh_cli || return 1

    print_info "Checking sync status for $repo_slug..."

    # Count tasks in TODO.md
    local total_open
    total_open=$(grep -cE '^- \[ \] t[0-9]+' "$todo_file" || echo "0")
    local total_completed
    total_completed=$(grep -cE '^- \[x\] t[0-9]+' "$todo_file" || echo "0")
    local with_ref
    with_ref=$(grep -cE '^- \[ \] t[0-9]+.*ref:GH#' "$todo_file" || echo "0")
    local without_ref
    without_ref=$((total_open - with_ref))

    # Count GitHub issues
    local gh_open
    gh_open=$(gh issue list --repo "$repo_slug" --state open --limit 500 --json number --jq 'length' 2>/dev/null || echo "0")
    local gh_closed
    gh_closed=$(gh issue list --repo "$repo_slug" --state closed --limit 500 --json number --jq 'length' 2>/dev/null || echo "0")

    # Count completed tasks with open issues (drift)
    local completed_with_open_issues=0
    while IFS= read -r line; do
        local issue_num
        issue_num=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
        if [[ -n "$issue_num" ]]; then
            local state
            state=$(gh issue view "$issue_num" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null || echo "")
            if [[ "$state" == "OPEN" ]]; then
                completed_with_open_issues=$((completed_with_open_issues + 1))
                print_warning "DRIFT: $line"
            fi
        fi
    done < <(grep -E '^- \[x\] t[0-9]+.*ref:GH#' "$todo_file" || true)

    echo ""
    echo "=== Sync Status ==="
    echo "TODO.md open tasks:        $total_open"
    echo "  - with GH ref:           $with_ref"
    echo "  - without GH ref:        $without_ref"
    echo "TODO.md completed tasks:   $total_completed"
    echo "GitHub open issues:        $gh_open"
    echo "GitHub closed issues:      $gh_closed"
    echo "Drift (done but open GH):  $completed_with_open_issues"
    echo ""

    if [[ $without_ref -gt 0 ]]; then
        print_warning "$without_ref open tasks have no GitHub issue. Run: issue-sync-helper.sh push"
    fi
    if [[ $completed_with_open_issues -gt 0 ]]; then
        print_warning "$completed_with_open_issues completed tasks have open GitHub issues. Run: issue-sync-helper.sh close"
    fi
    if [[ $without_ref -eq 0 && $completed_with_open_issues -eq 0 ]]; then
        print_success "TODO.md and GitHub issues are in sync"
    fi

    return 0
}

# Parse: display parsed task context (dry-run / debug)
cmd_parse() {
    local task_id="${1:-}"
    if [[ -z "$task_id" ]]; then
        print_error "Usage: issue-sync-helper.sh parse tNNN"
        return 1
    fi

    local project_root
    project_root=$(find_project_root) || return 1
    local todo_file="$project_root/TODO.md"

    echo "=== Task Block ==="
    local block
    block=$(extract_task_block "$task_id" "$todo_file")
    echo "$block"
    echo ""

    echo "=== Parsed Fields ==="
    local first_line
    first_line=$(echo "$block" | head -1)
    parse_task_line "$first_line"
    echo ""

    echo "=== Subtasks ==="
    extract_subtasks "$block"
    echo ""

    echo "=== Notes ==="
    extract_notes "$block"
    echo ""

    # Check for plan link
    local parsed
    parsed=$(parse_task_line "$first_line")
    local plan_link
    plan_link=$(echo "$parsed" | grep '^plan_link=' | cut -d= -f2-)
    if [[ -n "$plan_link" ]]; then
        echo "=== Plan Section ==="
        local plan_section
        plan_section=$(extract_plan_section "$plan_link" "$project_root")
        if [[ -n "$plan_section" ]]; then
            echo "Purpose:"
            extract_plan_purpose "$plan_section"
            echo ""
            echo "Decisions:"
            extract_plan_decisions "$plan_section"
            echo ""
            echo "Progress:"
            extract_plan_progress "$plan_section"
        else
            echo "(no plan section found for anchor: $plan_link)"
        fi
        echo ""
    fi

    echo "=== Related Files ==="
    find_related_files "$task_id" "$project_root"
    echo ""

    echo "=== Composed Issue Body ==="
    compose_issue_body "$task_id" "$project_root"

    return 0
}

# =============================================================================
# Main
# =============================================================================

cmd_help() {
    cat <<'EOF'
aidevops Issue Sync Helper

Bi-directional sync between TODO.md/PLANS.md and GitHub issues.

Usage: issue-sync-helper.sh [command] [options]

Commands:
  push [tNNN]     Create GitHub issues from TODO.md tasks (all open or specific)
  enrich [tNNN]   Update existing issue bodies with full context from PLANS.md
  pull            Sync GitHub issue refs back to TODO.md
  close [tNNN]    Close GitHub issues for completed TODO.md tasks
  status          Show sync drift between TODO.md and GitHub
  parse [tNNN]    Parse and display task context (debug/dry-run)
  help            Show this help message

Options:
  --repo SLUG     Override repo slug (default: auto-detect from git remote)
  --dry-run       Show what would be done without making changes
  --verbose       Show detailed output

Examples:
  issue-sync-helper.sh push                    # Push all unsynced tasks
  issue-sync-helper.sh push t020               # Push specific task
  issue-sync-helper.sh enrich t020             # Enrich issue with plan context
  issue-sync-helper.sh enrich                  # Enrich all open tasks with refs
  issue-sync-helper.sh pull                    # Sync GH refs to TODO.md
  issue-sync-helper.sh close                   # Close issues for done tasks
  issue-sync-helper.sh status                  # Show sync drift
  issue-sync-helper.sh parse t020              # Debug: show parsed context
  issue-sync-helper.sh push --dry-run          # Preview without changes
EOF
    return 0
}

main() {
    local command=""
    local positional_args=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)
                REPO_SLUG="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --verbose)
                VERBOSE="true"
                shift
                ;;
            help|--help|-h)
                cmd_help
                return 0
                ;;
            *)
                positional_args+=("$1")
                shift
                ;;
        esac
    done

    command="${positional_args[0]:-help}"

    case "$command" in
        push)
            cmd_push "${positional_args[1]:-}"
            ;;
        enrich)
            cmd_enrich "${positional_args[1]:-}"
            ;;
        pull)
            cmd_pull
            ;;
        close)
            cmd_close "${positional_args[1]:-}"
            ;;
        status)
            cmd_status
            ;;
        parse)
            cmd_parse "${positional_args[1]:-}"
            ;;
        help)
            cmd_help
            ;;
        *)
            print_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
