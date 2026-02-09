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
#   reconcile       Fix mismatched ref:GH# values and detect drift
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
FORCE_CLOSE="${FORCE_CLOSE:-false}"
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
# Uses awk for performance — avoids spawning subprocesses per line on large files
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

    # Use awk to extract the section efficiently (single pass, no per-line subprocesses)
    # Matching strategy: exact > substring > date-prefix + word overlap (handles TODO.md/PLANS.md drift)
    awk -v anchor="$anchor" '
    BEGIN {
        in_section = 0; heading_level = 0

        # Extract date prefix from anchor for fuzzy matching (e.g., "2026-02-08")
        if (match(anchor, /^[0-9]{4}-[0-9]{2}-[0-9]{2}/)) {
            anchor_date = substr(anchor, RSTART, RLENGTH)
            anchor_rest = substr(anchor, RLENGTH + 2)  # skip date + hyphen
        } else {
            anchor_date = ""
            anchor_rest = anchor
        }
        # Split anchor remainder into words for overlap scoring
        n_anchor_words = split(anchor_rest, anchor_words, "-")
    }

    function check_match(line_anchor) {
        # 1. Exact match
        if (line_anchor == anchor) return 1
        # 2. Substring containment (either direction)
        if (index(line_anchor, anchor) > 0 || index(anchor, line_anchor) > 0) return 1
        # 3. Date-prefix + word overlap (handles renamed/abbreviated headings)
        if (anchor_date != "" && index(line_anchor, anchor_date) > 0) {
            score = 0
            for (i = 1; i <= n_anchor_words; i++) {
                if (length(anchor_words[i]) >= 3 && index(line_anchor, anchor_words[i]) > 0) {
                    score++
                }
            }
            # Require >50% word overlap for fuzzy match
            if (n_anchor_words > 0 && score > n_anchor_words / 2) return 1
        }
        return 0
    }

    /^#{1,6} / {
        if (in_section == 0) {
            # Generate anchor from heading: strip leading #s, lowercase, strip special chars, spaces to hyphens
            line_anchor = $0
            gsub(/^#+[[:space:]]+/, "", line_anchor)
            line_anchor = tolower(line_anchor)
            gsub(/[^a-z0-9 -]/, "", line_anchor)
            gsub(/ /, "-", line_anchor)

            if (check_match(line_anchor)) {
                in_section = 1
                match($0, /^#+/)
                heading_level = RLENGTH
                print
                next
            }
        } else {
            # Check if this heading is at same or higher level (ends section)
            match($0, /^#+/)
            if (RLENGTH <= heading_level) {
                exit
            }
        }
    }

    in_section == 1 { print }
    ' "$plans_file"

    return 0
}

# Extract a named subsection from a plan section
# Uses awk for consistent, efficient extraction
# Args: $1=plan_section, $2=heading_pattern (e.g., "Purpose"), $3=max_lines (0=unlimited)
_extract_plan_subsection() {
    local plan_section="$1"
    local heading_pattern="$2"
    local max_lines="${3:-0}"
    local skip_toon="${4:-true}"
    local skip_placeholder="${5:-false}"

    local result
    result=$(echo "$plan_section" | awk -v pattern="$heading_pattern" -v skip_toon="$skip_toon" -v max_lines="$max_lines" -v skip_placeholder="$skip_placeholder" '
    BEGIN { in_section = 0; count = 0 }
    /^####[[:space:]]+/ {
        if (in_section == 1) { exit }
        if ($0 ~ "^####[[:space:]]+" pattern) { in_section = 1; next }
        next
    }
    /^###[[:space:]]+/ { if (in_section == 1) exit }
    in_section == 1 {
        if (skip_toon == "true" && $0 ~ /^<!--TOON:/) exit
        if (/^[[:space:]]*$/) next
        if (skip_placeholder == "true" && $0 ~ /To be populated/) next
        if (max_lines > 0 && count >= max_lines) exit
        print
        count++
    }
    ')

    echo "$result"
    return 0
}

# Extract just the Purpose section from a plan
extract_plan_purpose() {
    local plan_section="$1"
    _extract_plan_subsection "$plan_section" "Purpose" 20 "false"
    return 0
}

# Extract the Decision Log from a plan
extract_plan_decisions() {
    local plan_section="$1"
    _extract_plan_subsection "$plan_section" "Decision Log" 0 "true"
    return 0
}

# Extract Progress section from a plan
extract_plan_progress() {
    local plan_section="$1"
    _extract_plan_subsection "$plan_section" "Progress" 0 "true"
    return 0
}

# Extract Discoveries section from a plan
extract_plan_discoveries() {
    local plan_section="$1"
    _extract_plan_subsection "$plan_section" "Surprises" 0 "true" "true"
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
    local in_frontmatter=false
    local past_frontmatter=false

    while IFS= read -r line; do
        # Skip YAML frontmatter
        if [[ "$line" == "---" ]] && [[ "$past_frontmatter" == "false" ]]; then
            if [[ "$in_frontmatter" == "true" ]]; then
                past_frontmatter=true
                in_frontmatter=false
                continue
            fi
            in_frontmatter=true
            continue
        fi
        if [[ "$in_frontmatter" == "true" ]]; then
            continue
        fi

        # Skip empty lines at the start
        if [[ -z "${line// /}" ]] && [[ $line_count -eq 0 ]]; then
            continue
        fi

        # Include the title heading (# Title) as first line
        if [[ $line_count -eq 0 ]] && [[ "$line" == "# "* ]]; then
            summary="$line"
            line_count=1
            continue
        fi

        summary="$summary"$'\n'"$line"
        line_count=$((line_count + 1))

        # Stop at max lines
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
            tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
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
            tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
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

    # Get all open issues with t-number prefixes (include assignees for assignee: sync)
    local issues_json
    issues_json=$(gh issue list --repo "$repo_slug" --state open --limit 200 --json number,title,assignees 2>/dev/null || echo "[]")

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

    # Sync GitHub Issue assignees → TODO.md assignee: field (t165 bi-directional sync)
    local assignee_synced=0
    while IFS= read -r issue_line; do
        local issue_number
        issue_number=$(echo "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
        local issue_title
        issue_title=$(echo "$issue_line" | jq -r '.title' 2>/dev/null || echo "")
        local assignee_login
        assignee_login=$(echo "$issue_line" | jq -r '.assignees[0].login // empty' 2>/dev/null || echo "")

        local task_id
        task_id=$(echo "$issue_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
        if [[ -z "$task_id" || -z "$assignee_login" ]]; then
            continue
        fi

        # Check if task exists in TODO.md
        if ! grep -qE "^- \[.\] ${task_id} " "$todo_file" 2>/dev/null; then
            continue
        fi

        # Check if TODO.md already has an assignee: on this task
        local task_line_content
        task_line_content=$(grep -E "^- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
        local existing_assignee
        existing_assignee=$(echo "$task_line_content" | grep -oE 'assignee:[A-Za-z0-9._@-]+' | head -1 | sed 's/^assignee://' || echo "")

        if [[ -n "$existing_assignee" ]]; then
            # Already has an assignee — TODO.md is authoritative, don't overwrite
            continue
        fi

        # No assignee in TODO.md but issue has assignee — sync it
        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY-RUN] Would add assignee:$assignee_login to $task_id (from GH#$issue_number)"
            assignee_synced=$((assignee_synced + 1))
            continue
        fi

        # Add assignee:login before logged: or at end of line
        local line_num
        line_num=$(grep -nE "^- \[.\] ${task_id} " "$todo_file" | head -1 | cut -d: -f1)
        if [[ -n "$line_num" ]]; then
            local current_line
            current_line=$(sed -n "${line_num}p" "$todo_file")
            local new_line
            if echo "$current_line" | grep -qE 'logged:'; then
                new_line=$(echo "$current_line" | sed -E "s/( logged:)/ assignee:${assignee_login}\1/")
            else
                new_line="${current_line} assignee:${assignee_login}"
            fi
            sed_inplace "${line_num}s|.*|${new_line}|" "$todo_file"
            log_verbose "Synced assignee:$assignee_login to $task_id (from GH#$issue_number)"
            assignee_synced=$((assignee_synced + 1))
        fi
    done < <(echo "$issues_json" | jq -c '.[]' 2>/dev/null || true)

    print_info "Pull complete: $synced refs synced, $assignee_synced assignees synced to TODO.md"
    return 0
}

# Fix a mismatched ref:GH# in TODO.md (t179.1)
# Replaces old_number with new_number for the given task
fix_gh_ref_in_todo() {
    local task_id="$1"
    local old_number="$2"
    local new_number="$3"
    local todo_file="$4"

    if [[ -z "$old_number" || -z "$new_number" || "$old_number" == "$new_number" ]]; then
        return 0
    fi

    # Replace the old ref with the new one
    sed_inplace -E "s/^(- \[.\] ${task_id} .*)ref:GH#${old_number}/\1ref:GH#${new_number}/" "$todo_file"
    log_verbose "Fixed ref:GH#$old_number -> ref:GH#$new_number for $task_id"
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

# Verify a completed task has evidence of real work (merged PR or verified: field)
# Returns 0 if verified, 1 if not
# shellcheck disable=SC2155
task_has_completion_evidence() {
    local task_line="$1"
    local task_id="$2"
    local repo_slug="$3"

    # Check 1: Has verified:YYYY-MM-DD field (human-verified)
    if echo "$task_line" | grep -qE 'verified:[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
        return 0
    fi

    # Check 2: Has a merged PR reference in the task line (e.g., "PR #NNN merged" in Notes)
    # Look for the task and its Notes lines
    if echo "$task_line" | grep -qiE 'PR #[0-9]+ merged|PR.*merged'; then
        return 0
    fi

    # Check 3: Search for a merged PR with this task ID in the title
    if command -v gh &>/dev/null && [[ -n "$repo_slug" ]]; then
        local merged_pr
        merged_pr=$(gh pr list --repo "$repo_slug" --state merged --search "$task_id in:title" --limit 1 --json number --jq '.[0].number' 2>/dev/null || echo "")
        if [[ -n "$merged_pr" ]]; then
            return 0
        fi
    fi

    return 1
}

# Close: close GitHub issue when TODO.md task is completed
# Guard (t163): requires merged PR or verified: field before closing
# Fallback (t179.1): search by task ID in issue title when ref:GH# doesn't match
cmd_close() {
    local target_task="${1:-}"
    local project_root
    project_root=$(find_project_root) || return 1
    local repo_slug="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
    local todo_file="$project_root/TODO.md"
    verify_gh_cli || return 1

    # Collect completed tasks — both with and without GH refs (t179.1)
    local tasks=()
    if [[ -n "$target_task" ]]; then
        tasks=("$target_task")
    else
        # Include all completed tasks, not just those with ref:GH#
        while IFS= read -r line; do
            local tid
            tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
            if [[ -n "$tid" ]]; then
                tasks+=("$tid")
            fi
        done < <(grep -E '^- \[x\] t[0-9]+' "$todo_file" || true)
    fi

    if [[ ${#tasks[@]} -eq 0 ]]; then
        print_info "No completed tasks to close"
        return 0
    fi

    local closed=0
    local skipped=0
    local ref_fixed=0
    for task_id in "${tasks[@]}"; do
        local task_line
        task_line=$(grep -E "^- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
        local issue_number
        issue_number=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")

        # t179.1: Fallback — search by task ID in issue title when ref:GH# is missing or stale
        if [[ -z "$issue_number" ]]; then
            log_verbose "$task_id: no ref:GH# in TODO.md, searching GitHub by title..."
            issue_number=$(gh issue list --repo "$repo_slug" --state open --search "in:title ${task_id}:" --json number --jq '.[0].number' 2>/dev/null || echo "")
            if [[ -n "$issue_number" && "$issue_number" != "null" ]]; then
                log_verbose "$task_id: found open issue #$issue_number by title search"
                # Fix the ref in TODO.md
                if [[ "$DRY_RUN" != "true" ]]; then
                    add_gh_ref_to_todo "$task_id" "$issue_number" "$todo_file"
                    ref_fixed=$((ref_fixed + 1))
                fi
            else
                # Also check closed issues (might already be closed)
                issue_number=$(gh issue list --repo "$repo_slug" --state closed --search "in:title ${task_id}:" --json number --jq '.[0].number' 2>/dev/null || echo "")
                if [[ -n "$issue_number" && "$issue_number" != "null" ]]; then
                    log_verbose "$task_id: found closed issue #$issue_number (already closed)"
                    if [[ "$DRY_RUN" != "true" ]]; then
                        add_gh_ref_to_todo "$task_id" "$issue_number" "$todo_file"
                        ref_fixed=$((ref_fixed + 1))
                    fi
                    continue  # Already closed, nothing to do
                fi
                log_verbose "$task_id: no matching GitHub issue found"
                continue
            fi
        else
            # Verify the ref:GH# actually matches an issue with this task ID (t179.1)
            local ref_title
            ref_title=$(gh issue view "$issue_number" --repo "$repo_slug" --json title --jq '.title' 2>/dev/null || echo "")
            local ref_task_id
            ref_task_id=$(echo "$ref_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")

            if [[ -n "$ref_task_id" && "$ref_task_id" != "$task_id" ]]; then
                # ref:GH# points to a different task's issue — search for the correct one
                log_verbose "$task_id: ref:GH#$issue_number belongs to $ref_task_id, searching for correct issue..."
                local correct_number
                correct_number=$(gh issue list --repo "$repo_slug" --state all --search "in:title ${task_id}:" --json number,state --jq '.[] | select(.state == "OPEN") | .number' 2>/dev/null | head -1 || echo "")
                if [[ -z "$correct_number" ]]; then
                    correct_number=$(gh issue list --repo "$repo_slug" --state all --search "in:title ${task_id}:" --json number --jq '.[0].number' 2>/dev/null || echo "")
                fi
                if [[ -n "$correct_number" && "$correct_number" != "null" ]]; then
                    log_verbose "$task_id: correct issue is #$correct_number (was ref:GH#$issue_number)"
                    if [[ "$DRY_RUN" != "true" ]]; then
                        fix_gh_ref_in_todo "$task_id" "$issue_number" "$correct_number" "$todo_file"
                        ref_fixed=$((ref_fixed + 1))
                    fi
                    issue_number="$correct_number"
                fi
            fi
        fi

        if [[ -z "$issue_number" || "$issue_number" == "null" ]]; then
            continue
        fi

        # Guard: verify task has completion evidence (merged PR or verified: field)
        if [[ "$FORCE_CLOSE" != "true" ]]; then
            # Check the full task block (task line + all subtasks/notes)
            local task_with_notes
            task_with_notes=$(extract_task_block "$task_id" "$todo_file")
            if [[ -z "$task_with_notes" ]]; then
                task_with_notes="$task_line"
            fi

            if ! task_has_completion_evidence "$task_with_notes" "$task_id" "$repo_slug"; then
                print_warning "Skipping #$issue_number ($task_id): no merged PR or verified: field found"
                log_verbose "  To force close: FORCE_CLOSE=true issue-sync-helper.sh close $task_id"
                log_verbose "  To verify: add 'verified:$(date +%Y-%m-%d)' to the task line in TODO.md"
                skipped=$((skipped + 1))
                continue
            fi
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

    print_info "Close complete: $closed closed, $skipped skipped (no evidence), $ref_fixed refs fixed"
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

# Reconcile: fix mismatched ref:GH# values in TODO.md (t179.2)
# Scans all tasks with ref:GH#, verifies the issue number matches an issue
# with the task ID in its title, and fixes mismatches.
# Also finds open issues for completed tasks and closes them.
cmd_reconcile() {
    local project_root
    project_root=$(find_project_root) || return 1
    local repo_slug="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
    local todo_file="$project_root/TODO.md"

    verify_gh_cli || return 1

    print_info "Reconciling ref:GH# values in $repo_slug..."

    local ref_fixed=0
    local ref_ok=0
    local stale_closed=0
    local orphan_issues=0

    # Phase 1: Verify all ref:GH# values in TODO.md match actual issues
    while IFS= read -r line; do
        local tid
        tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
        local gh_ref
        gh_ref=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")

        if [[ -z "$tid" || -z "$gh_ref" ]]; then
            continue
        fi

        # Verify the issue title matches this task ID
        local issue_title
        issue_title=$(gh issue view "$gh_ref" --repo "$repo_slug" --json title --jq '.title' 2>/dev/null || echo "")
        local issue_task_id
        issue_task_id=$(echo "$issue_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")

        if [[ "$issue_task_id" == "$tid" ]]; then
            ref_ok=$((ref_ok + 1))
            continue
        fi

        # Mismatch — search for the correct issue
        print_warning "MISMATCH: $tid has ref:GH#$gh_ref but issue title is '$issue_title'"
        local correct_number
        correct_number=$(gh issue list --repo "$repo_slug" --state all --search "in:title ${tid}:" --json number --jq '.[0].number' 2>/dev/null || echo "")

        if [[ -n "$correct_number" && "$correct_number" != "null" && "$correct_number" != "$gh_ref" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                print_info "[DRY-RUN] Would fix $tid: ref:GH#$gh_ref -> ref:GH#$correct_number"
            else
                fix_gh_ref_in_todo "$tid" "$gh_ref" "$correct_number" "$todo_file"
                print_success "Fixed $tid: ref:GH#$gh_ref -> ref:GH#$correct_number"
            fi
            ref_fixed=$((ref_fixed + 1))
        elif [[ -z "$correct_number" || "$correct_number" == "null" ]]; then
            print_warning "$tid: no matching issue found on GitHub (ref:GH#$gh_ref is stale)"
        fi
    done < <(grep -E '^- \[.\] t[0-9]+.*ref:GH#[0-9]+' "$todo_file" || true)

    # Phase 2: Find open issues for completed tasks (including those without ref:GH#)
    local open_issues_json
    open_issues_json=$(gh issue list --repo "$repo_slug" --state open --limit 200 --json number,title 2>/dev/null || echo "[]")

    while IFS= read -r issue_line; do
        local issue_number
        issue_number=$(echo "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
        local issue_title
        issue_title=$(echo "$issue_line" | jq -r '.title' 2>/dev/null || echo "")

        local issue_tid
        issue_tid=$(echo "$issue_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
        if [[ -z "$issue_tid" ]]; then
            continue
        fi

        # Check if task is completed in TODO.md
        if grep -qE "^- \[x\] ${issue_tid} " "$todo_file" 2>/dev/null; then
            print_warning "STALE: GH#$issue_number ($issue_tid) is open but task is completed"
            stale_closed=$((stale_closed + 1))
        fi

        # Check if task exists at all in TODO.md
        if ! grep -qE "^- \[.\] ${issue_tid} " "$todo_file" 2>/dev/null; then
            log_verbose "ORPHAN: GH#$issue_number ($issue_tid) has no matching TODO.md entry"
            orphan_issues=$((orphan_issues + 1))
        fi
    done < <(echo "$open_issues_json" | jq -c '.[]' 2>/dev/null || true)

    echo ""
    echo "=== Reconciliation Report ==="
    echo "Refs verified OK:          $ref_ok"
    echo "Refs fixed (mismatch):     $ref_fixed"
    echo "Stale open issues:         $stale_closed"
    echo "Orphan issues (no task):   $orphan_issues"
    echo ""

    if [[ $stale_closed -gt 0 ]]; then
        print_info "Run 'issue-sync-helper.sh close' to close stale issues"
    fi
    if [[ $ref_fixed -gt 0 && "$DRY_RUN" != "true" ]]; then
        print_success "Fixed $ref_fixed mismatched refs in TODO.md"
    fi
    if [[ $ref_fixed -eq 0 && $stale_closed -eq 0 && $orphan_issues -eq 0 ]]; then
        print_success "All refs are correct, no drift detected"
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
  reconcile       Fix mismatched ref:GH# values and detect drift (t179.2)
  status          Show sync drift between TODO.md and GitHub
  parse [tNNN]    Parse and display task context (debug/dry-run)
  help            Show this help message

Options:
  --repo SLUG     Override repo slug (default: auto-detect from git remote)
  --dry-run       Show what would be done without making changes
  --verbose       Show detailed output
  --force         Force close: skip merged-PR/verified check (use with caution)

Examples:
  issue-sync-helper.sh push                    # Push all unsynced tasks
  issue-sync-helper.sh push t020               # Push specific task
  issue-sync-helper.sh enrich t020             # Enrich issue with plan context
  issue-sync-helper.sh enrich                  # Enrich all open tasks with refs
  issue-sync-helper.sh pull                    # Sync GH refs to TODO.md
  issue-sync-helper.sh close                   # Close issues for done tasks
  issue-sync-helper.sh reconcile               # Fix ref:GH# mismatches
  issue-sync-helper.sh reconcile --dry-run     # Preview reconciliation
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
            --force)
                FORCE_CLOSE="true"
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
        reconcile)
            cmd_reconcile
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
