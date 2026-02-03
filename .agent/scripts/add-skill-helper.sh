#!/bin/bash
# =============================================================================
# Add External Skill Helper
# =============================================================================
# Import external skills from GitHub repos or ClawdHub, convert to aidevops
# format, handle conflicts, and track upstream sources for update detection.
#
# Usage:
#   add-skill-helper.sh add <url|owner/repo|clawdhub:slug> [--name <name>] [--force]
#   add-skill-helper.sh list
#   add-skill-helper.sh check-updates
#   add-skill-helper.sh remove <name>
#   add-skill-helper.sh help
#
# Examples:
#   add-skill-helper.sh add dmmulroy/cloudflare-skill
#   add-skill-helper.sh add https://github.com/anthropics/skills/pdf
#   add-skill-helper.sh add vercel-labs/agent-skills --name vercel
#   add-skill-helper.sh add clawdhub:caldav-calendar
#   add-skill-helper.sh add https://clawdhub.com/Asleep123/caldav-calendar
#   add-skill-helper.sh check-updates
# =============================================================================

set -euo pipefail

# Configuration
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
SKILL_SOURCES="${AGENTS_DIR}/configs/skill-sources.json"
TEMP_DIR="${TMPDIR:-/tmp}/aidevops-skill-import"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[add-skill]${NC} $1"
    return 0
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
    return 0
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    return 0
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    return 0
}

show_help() {
    cat << 'EOF'
Add External Skill Helper - Import skills from GitHub or ClawdHub to aidevops

USAGE:
    add-skill-helper.sh <command> [options]

COMMANDS:
    add <url|owner/repo|clawdhub:slug>    Import a skill
    list                                   List all imported skills
    check-updates                          Check for upstream updates
    remove <name>                          Remove an imported skill
    help                                   Show this help message

OPTIONS:
    --name <name>           Override the skill name
    --force                 Overwrite existing skill without prompting
    --dry-run               Show what would be done without making changes

EXAMPLES:
    # Import from GitHub shorthand
    add-skill-helper.sh add dmmulroy/cloudflare-skill

    # Import specific skill from multi-skill repo
    add-skill-helper.sh add anthropics/skills/pdf

    # Import with custom name
    add-skill-helper.sh add vercel-labs/agent-skills --name vercel-deploy

    # Import from ClawdHub (shorthand)
    add-skill-helper.sh add clawdhub:caldav-calendar

    # Import from ClawdHub (full URL)
    add-skill-helper.sh add https://clawdhub.com/Asleep123/caldav-calendar

    # Check all imported skills for updates
    add-skill-helper.sh check-updates

SUPPORTED SOURCES:
    - GitHub repos (owner/repo or full URL)
    - ClawdHub registry (clawdhub:slug or clawdhub.com URL)

SUPPORTED FORMATS:
    - SKILL.md (OpenSkills/Claude Code/ClawdHub format)
    - AGENTS.md (aidevops/Windsurf format)
    - .cursorrules (Cursor format)
    - Raw markdown files

The skill will be converted to aidevops format and placed in .agent/
with symlinks created to other AI assistant locations by setup.sh.
EOF
    return 0
}

# Ensure skill-sources.json exists
ensure_skill_sources() {
    if [[ ! -f "$SKILL_SOURCES" ]]; then
        mkdir -p "$(dirname "$SKILL_SOURCES")"
        # shellcheck disable=SC2016 # Single quotes intentional - $schema/$comment are JSON keys, not variables
        echo '{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$comment": "Registry of imported external skills with upstream tracking",
  "version": "1.0.0",
  "skills": []
}' > "$SKILL_SOURCES"
    fi
    return 0
}

# Parse GitHub URL or shorthand into components
parse_github_url() {
    local input="$1"
    local owner=""
    local repo=""
    local subpath=""
    
    # Remove https://github.com/ prefix if present
    input="${input#https://github.com/}"
    input="${input#http://github.com/}"
    input="${input#github.com/}"
    
    # Remove .git suffix if present
    input="${input%.git}"
    
    # Remove /tree/main or /tree/master if present (use bash instead of sed for portability)
    if [[ "$input" =~ ^(.+)/tree/(main|master)(/.*)?$ ]]; then
        input="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
    fi
    
    # Split by /
    IFS='/' read -ra parts <<< "$input"
    
    if [[ ${#parts[@]} -ge 2 ]]; then
        owner="${parts[0]}"
        repo="${parts[1]}"
        
        # Everything after owner/repo is subpath
        if [[ ${#parts[@]} -gt 2 ]]; then
            # Join remaining parts with / using printf
            subpath=$(printf '%s/' "${parts[@]:2}")
            subpath="${subpath%/}"  # Remove trailing slash
        fi
    fi
    
    echo "$owner|$repo|$subpath"
    return 0
}

# Detect skill format from directory contents
# Returns: format|skill_subdir (e.g., "skill-md-nested|skill/cloudflare")
detect_format() {
    local dir="$1"
    
    # Check for direct SKILL.md first
    if [[ -f "$dir/SKILL.md" ]]; then
        echo "skill-md|"
        return 0
    fi
    
    # Check for nested skill directory (e.g., skill/*/SKILL.md)
    local nested_skill
    nested_skill=$(find "$dir" -maxdepth 3 -name "SKILL.md" -type f 2>/dev/null | head -1)
    if [[ -n "$nested_skill" ]]; then
        local skill_subdir
        skill_subdir=$(dirname "$nested_skill")
        skill_subdir="${skill_subdir#"$dir/"}"
        echo "skill-md-nested|$skill_subdir"
        return 0
    fi
    
    if [[ -f "$dir/AGENTS.md" ]]; then
        echo "agents-md|"
    elif [[ -f "$dir/.cursorrules" ]]; then
        echo "cursorrules|"
    elif [[ -f "$dir/README.md" ]]; then
        echo "readme|"
    else
        # Look for any .md file
        local md_file
        md_file=$(find "$dir" -maxdepth 1 -name "*.md" -type f | head -1)
        if [[ -n "$md_file" ]]; then
            echo "markdown|"
        else
            echo "unknown|"
        fi
    fi
    return 0
}

# Extract skill name from SKILL.md frontmatter
extract_skill_name() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    
    # Extract name from YAML frontmatter
    awk '
        /^---$/ { in_frontmatter = !in_frontmatter; next }
        in_frontmatter && /^name:/ {
            sub(/^name: */, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
            exit
        }
    ' "$file"
    return 0
}

# Extract description from SKILL.md frontmatter
extract_skill_description() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    
    awk '
        /^---$/ { in_frontmatter = !in_frontmatter; next }
        in_frontmatter && /^description:/ {
            sub(/^description: */, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
            exit
        }
    ' "$file"
    return 0
}

# Convert skill name to kebab-case
to_kebab_case() {
    local name="$1"
    echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g'
    return 0
}

# Determine target path in .agent/ based on skill content
determine_target_path() {
    local skill_name="$1"
    local _description="$2"  # Reserved for future category detection
    local source_dir="$3"
    
    # Analyze content to determine category
    local category="tools"
    
    # Check description and content for category hints
    local content=""
    if [[ -f "$source_dir/SKILL.md" ]]; then
        content=$(cat "$source_dir/SKILL.md")
    elif [[ -f "$source_dir/AGENTS.md" ]]; then
        content=$(cat "$source_dir/AGENTS.md")
    fi
    
    # Detect category from content (order matters - more specific patterns first)
    # Check skill name first for known services
    if [[ "$skill_name" == "cloudflare"* ]]; then
        category="services/hosting"
    elif echo "$content" | grep -qi "cloudflare workers\|cloudflare pages\|wrangler"; then
        category="services/hosting"
    # Architecture patterns (must come before generic patterns)
    elif echo "$content" | grep -qi "clean.architecture\|hexagonal\|ddd\|domain.driven\|ports.and.adapters\|onion.architecture\|cqrs\|event.sourcing"; then
        category="tools/architecture"
    elif echo "$content" | grep -qi "feature.sliced\|feature-sliced\|fsd.architecture\|slice.organization"; then
        category="tools/architecture"
    # Database and ORM
    elif echo "$content" | grep -qi "postgresql\|postgres\|drizzle\|prisma\|typeorm\|sequelize\|knex\|database.orm"; then
        category="services/database"
    # Diagrams and visualization
    elif echo "$content" | grep -qi "mermaid\|diagram\|flowchart\|sequence.diagram\|er.diagram\|uml"; then
        category="tools/diagrams"
    # Programming languages (specific patterns)
    elif echo "$content" | grep -qi "javascript\|typescript\|es6\|es2020\|es2022\|es2024\|ecmascript\|modern.js"; then
        category="tools/programming"
    elif echo "$content" | grep -qi "browser\|playwright\|puppeteer\|selenium"; then
        category="tools/browser"
    elif echo "$content" | grep -qi "seo\|search.ranking\|keyword.research"; then
        category="seo"
    elif echo "$content" | grep -qi "git\|github\|gitlab"; then
        category="tools/git"
    elif echo "$content" | grep -qi "code.review\|lint\|quality"; then
        category="tools/code-review"
    elif echo "$content" | grep -qi "credential\|secret\|password\|vault"; then
        category="tools/credentials"
    elif echo "$content" | grep -qi "vercel\|coolify\|docker\|kubernetes"; then
        category="tools/deployment"
    elif echo "$content" | grep -qi "proxmox\|hypervisor\|virtualization\|vm.management"; then
        category="services/hosting"
    elif echo "$content" | grep -qi "calendar\|caldav\|ical\|scheduling"; then
        category="tools/productivity"
    elif echo "$content" | grep -qi "dns\|hosting\|domain"; then
        category="services/hosting"
    fi
    
    # Append -skill suffix to distinguish imported skills from native subagents
    # This enables: glob *-skill.md for imports, update checks, conflict avoidance
    echo "$category/${skill_name}-skill"
    return 0
}

# Check for conflicts with existing files
# Returns conflict info with type: NATIVE (our subagent) or IMPORTED (previous skill)
check_conflicts() {
    local target_path="$1"
    local agent_dir="$2"
    
    local full_path="$agent_dir/$target_path"
    local md_path="${full_path}.md"
    local dir_path="$full_path"
    
    local conflicts=()
    
    if [[ -f "$md_path" ]]; then
        if [[ "$md_path" == *-skill.md ]]; then
            conflicts+=("IMPORTED: $md_path")
        else
            conflicts+=("NATIVE: $md_path")
        fi
    fi
    
    if [[ -d "$dir_path" ]]; then
        if [[ "$dir_path" == *-skill ]]; then
            conflicts+=("IMPORTED: $dir_path/")
        else
            conflicts+=("NATIVE: $dir_path/")
        fi
    fi
    
    # Also check for native subagent without -skill suffix (same base name)
    local base_name="${target_path%-skill}"
    local native_md="${agent_dir}/${base_name}.md"
    if [[ "$target_path" == *-skill && -f "$native_md" ]]; then
        # Native subagent exists with same base name - not a conflict since
        # -skill suffix differentiates, but inform the user
        conflicts+=("INFO: Native subagent exists at $native_md (no conflict, -skill suffix differentiates)")
    fi
    
    if [[ ${#conflicts[@]} -gt 0 ]]; then
        printf '%s\n' "${conflicts[@]}"
        return 1
    fi
    
    return 0
}

# Convert SKILL.md to aidevops format
convert_skill_md() {
    local source_file="$1"
    local target_file="$2"
    local skill_name="$3"
    
    # Read source content
    local content
    content=$(cat "$source_file")
    
    # Extract frontmatter
    local name
    local description
    name=$(extract_skill_name "$source_file")
    description=$(extract_skill_description "$source_file")
    
    # Escape YAML special characters in description
    local safe_description
    safe_description=$(printf '%s' "${description:-Imported skill}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/:/: /g; s/^- /\\- /')
    
    # Escape name for markdown heading
    local safe_name
    safe_name=$(printf '%s' "${name:-$skill_name}" | sed 's/\\/\\\\/g')
    
    # Create aidevops-style header with properly quoted description
    cat > "$target_file" << EOF
---
description: "${safe_description}"
mode: subagent
imported_from: external
---
# ${safe_name}

EOF
    
    # Append content after frontmatter
    awk '
        BEGIN { in_frontmatter = 0; after_frontmatter = 0 }
        /^---$/ { 
            if (!in_frontmatter) { in_frontmatter = 1; next }
            else { in_frontmatter = 0; after_frontmatter = 1; next }
        }
        after_frontmatter { print }
    ' "$source_file" >> "$target_file"
    
    return 0
}

# Register skill in skill-sources.json
register_skill() {
    local name="$1"
    local upstream_url="$2"
    local local_path="$3"
    local format="$4"
    local commit="${5:-}"
    local merge_strategy="${6:-added}"
    local notes="${7:-}"
    
    ensure_skill_sources
    
    # jq is required for reliable JSON manipulation
    if ! command -v jq &>/dev/null; then
        log_error "jq is required to update $SKILL_SOURCES"
        log_info "Install with: brew install jq (macOS) or apt install jq (Linux)"
        return 1
    fi
    
    # Check for existing entry and remove it (update scenario)
    local existing
    existing=$(jq -r --arg name "$name" '.skills[] | select(.name == $name) | .name' "$SKILL_SOURCES" 2>/dev/null || echo "")
    if [[ -n "$existing" ]]; then
        log_info "Updating existing skill registration: $name"
        local tmp_file
        tmp_file=$(mktemp)
        jq --arg name "$name" '.skills = [.skills[] | select(.name != $name)]' "$SKILL_SOURCES" > "$tmp_file"
        mv "$tmp_file" "$SKILL_SOURCES"
    fi
    
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Create new skill entry using jq for proper JSON escaping
    local new_entry
    new_entry=$(jq -n \
        --arg name "$name" \
        --arg upstream_url "$upstream_url" \
        --arg upstream_commit "$commit" \
        --arg local_path "$local_path" \
        --arg format_detected "$format" \
        --arg imported_at "$timestamp" \
        --arg last_checked "$timestamp" \
        --arg merge_strategy "$merge_strategy" \
        --arg notes "$notes" \
        '{
            name: $name,
            upstream_url: $upstream_url,
            upstream_commit: $upstream_commit,
            local_path: $local_path,
            format_detected: $format_detected,
            imported_at: $imported_at,
            last_checked: $last_checked,
            merge_strategy: $merge_strategy,
            notes: $notes
        }')
    
    local tmp_file
    tmp_file=$(mktemp)
    jq --argjson entry "$new_entry" '.skills += [$entry]' "$SKILL_SOURCES" > "$tmp_file"
    mv "$tmp_file" "$SKILL_SOURCES"
    
    return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_add() {
    local url="$1"
    shift
    
    local custom_name=""
    local force=false
    local dry_run=false
    
    # Parse options using named variable for clarity (S7679)
    local opt
    while [[ $# -gt 0 ]]; do
        opt="$1"
        case "$opt" in
            --name)
                custom_name="$2"
                shift 2
                ;;
            --force)
                force=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            *)
                log_error "Unknown option: $opt"
                return 1
                ;;
        esac
    done
    
    log_info "Parsing source: $url"
    
    # Detect ClawdHub source (clawdhub:slug or clawdhub.com URL)
    local is_clawdhub=false
    local clawdhub_slug=""
    
    if [[ "$url" == clawdhub:* ]]; then
        is_clawdhub=true
        clawdhub_slug="${url#clawdhub:}"
    elif [[ "$url" == *clawdhub.com* ]]; then
        is_clawdhub=true
        # Strip URL prefix and extract slug (last path segment)
        clawdhub_slug="${url#*clawdhub.com/}"
        clawdhub_slug="${clawdhub_slug#/}"
        clawdhub_slug="${clawdhub_slug%/}"
        # If format is owner/slug, take just the slug
        if [[ "$clawdhub_slug" == */* ]]; then
            clawdhub_slug="${clawdhub_slug##*/}"
        fi
    fi
    
    if [[ "$is_clawdhub" == true ]]; then
        cmd_add_clawdhub "$clawdhub_slug" "$custom_name" "$force" "$dry_run"
        return $?
    fi
    
    # Parse GitHub URL
    local parsed
    parsed=$(parse_github_url "$url")
    IFS='|' read -r owner repo subpath <<< "$parsed"
    
    if [[ -z "$owner" || -z "$repo" ]]; then
        log_error "Could not parse source URL: $url"
        log_info "Expected: owner/repo, https://github.com/owner/repo, or clawdhub:slug"
        return 1
    fi
    
    log_info "Owner: $owner, Repo: $repo, Subpath: ${subpath:-<root>}"
    
    # Create temp directory
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    # Try to use openskills if available
    if command -v openskills &>/dev/null; then
        log_info "Using openskills to fetch skill..."
        if openskills install "$owner/$repo${subpath:+/$subpath}" --yes --universal 2>/dev/null; then
            log_success "Skill installed via openskills"
            # openskills handles everything, just register it
            local skill_name="${custom_name:-$(basename "${subpath:-$repo}")}"
            skill_name=$(to_kebab_case "$skill_name")
            # openskills installs to ~/.config/opencode/skills/<name>/SKILL.md
            # Register with -skill suffix for consistency with direct imports
            register_skill "$skill_name" "https://github.com/$owner/$repo" ".agent/skills/${skill_name}-skill.md" "skill-md" "" "openskills" "Installed via openskills CLI"
            return 0
        fi
        log_warning "openskills failed, falling back to direct fetch"
    fi
    
    # Clone repository
    log_info "Cloning repository..."
    local clone_url="https://github.com/$owner/$repo.git"
    
    if ! git clone --depth 1 "$clone_url" "$TEMP_DIR/repo" 2>/dev/null; then
        log_error "Failed to clone repository: $clone_url"
        return 1
    fi
    
    # Navigate to subpath if specified
    local source_dir="$TEMP_DIR/repo"
    if [[ -n "$subpath" ]]; then
        source_dir="$TEMP_DIR/repo/$subpath"
        if [[ ! -d "$source_dir" ]]; then
            log_error "Subpath not found: $subpath"
            return 1
        fi
    fi
    
    # Detect format (returns format|skill_subdir)
    local format_result skill_subdir format
    format_result=$(detect_format "$source_dir")
    IFS='|' read -r format skill_subdir <<< "$format_result"
    log_info "Detected format: $format"
    
    # For nested skills, update source_dir to point to the skill directory
    local skill_source_dir="$source_dir"
    if [[ "$format" == "skill-md-nested" && -n "$skill_subdir" ]]; then
        skill_source_dir="$source_dir/$skill_subdir"
        log_info "Found nested skill at: $skill_subdir"
    fi
    
    # Determine skill name
    local skill_name=""
    if [[ -n "$custom_name" ]]; then
        skill_name=$(to_kebab_case "$custom_name")
    elif [[ "$format" == "skill-md" || "$format" == "skill-md-nested" ]]; then
        skill_name=$(extract_skill_name "$skill_source_dir/SKILL.md")
        skill_name=$(to_kebab_case "${skill_name:-$(basename "${subpath:-$repo}")}")
    else
        skill_name=$(to_kebab_case "$(basename "${subpath:-$repo}")")
    fi
    
    log_info "Skill name: $skill_name"
    
    # Get description
    local description=""
    if [[ "$format" == "skill-md" || "$format" == "skill-md-nested" ]]; then
        description=$(extract_skill_description "$skill_source_dir/SKILL.md")
    fi
    
    # Determine target path
    local target_path
    target_path=$(determine_target_path "$skill_name" "$description" "$skill_source_dir")
    log_info "Target path: .agent/$target_path"
    
    # Check for conflicts (check_conflicts returns 1 when conflicts exist)
    local conflicts
    conflicts=$(check_conflicts "$target_path" ".agent") || true
    if [[ -n "$conflicts" ]]; then
        # Filter out INFO lines (informational, not blocking)
        local blocking_conflicts
        blocking_conflicts=$(echo "$conflicts" | grep -v "^INFO:" || true)
        local info_lines
        info_lines=$(echo "$conflicts" | grep "^INFO:" || true)
        
        # Show info lines (native subagent coexistence)
        if [[ -n "$info_lines" ]]; then
            echo "$info_lines" | while read -r info; do
                log_info "${info#INFO: }"
            done
        fi
        
        # Handle blocking conflicts
        if [[ -n "$blocking_conflicts" && "$force" != true ]]; then
            # Determine conflict type for better messaging
            if echo "$blocking_conflicts" | grep -q "^NATIVE:"; then
                log_warning "Conflicts with native aidevops subagent(s):"
                echo "$blocking_conflicts" | while read -r conflict; do
                    echo "  - ${conflict#NATIVE: }"
                done
                echo ""
                echo "The -skill suffix should prevent this. If you see this,"
                echo "the imported skill has the same name as a native subagent."
                echo ""
            elif echo "$blocking_conflicts" | grep -q "^IMPORTED:"; then
                log_warning "Conflicts with previously imported skill(s):"
                echo "$blocking_conflicts" | while read -r conflict; do
                    echo "  - ${conflict#IMPORTED: }"
                done
                echo ""
            else
                log_warning "Conflicts detected:"
                echo "$blocking_conflicts" | while read -r conflict; do
                    echo "  - $conflict"
                done
                echo ""
            fi
            
            echo "Options:"
            echo "  1. Replace (overwrite existing)"
            echo "  2. Separate (use different name)"
            echo "  3. Skip (cancel import)"
            echo ""
            read -rp "Choose option [1-3]: " choice
            
            case "$choice" in
                1)
                    log_info "Replacing existing..."
                    ;;
                2)
                    read -rp "Enter new name: " new_name
                    skill_name=$(to_kebab_case "$new_name")
                    target_path=$(determine_target_path "$skill_name" "$description" "$source_dir")
                    ;;
                3|*)
                    log_info "Import cancelled"
                    return 0
                    ;;
            esac
        fi
    fi
    
    if [[ "$dry_run" == true ]]; then
        log_info "DRY RUN - Would create:"
        echo "  .agent/${target_path}.md"
        if [[ -d "$skill_source_dir/scripts" || -d "$skill_source_dir/references" ]]; then
            echo "  .agent/${target_path}/"
        fi
        return 0
    fi
    
    # Create target directory
    local target_dir
    target_dir=".agent/$(dirname "$target_path")"
    mkdir -p "$target_dir"
    
    # Convert and copy files
    local target_file=".agent/${target_path}.md"
    
    case "$format" in
        skill-md|skill-md-nested)
            convert_skill_md "$skill_source_dir/SKILL.md" "$target_file" "$skill_name"
            ;;
        agents-md)
            cp "$source_dir/AGENTS.md" "$target_file"
            ;;
        cursorrules)
            # Convert .cursorrules to markdown
            {
                echo "---"
                echo "description: Imported from .cursorrules"
                echo "mode: subagent"
                echo "imported_from: cursorrules"
                echo "---"
                echo "# $skill_name"
                echo ""
                cat "$source_dir/.cursorrules"
            } > "$target_file"
            ;;
        *)
            # Copy first markdown file found
            local md_file
            md_file=$(find "$source_dir" -maxdepth 1 -name "*.md" -type f | head -1)
            if [[ -n "$md_file" ]]; then
                cp "$md_file" "$target_file"
            else
                log_error "No suitable files found to import"
                return 1
            fi
            ;;
    esac
    
    log_success "Created: $target_file"
    
    # Copy additional resources (scripts, references, assets)
    for resource_dir in scripts references assets; do
        if [[ -d "$skill_source_dir/$resource_dir" ]]; then
            local target_resource_dir=".agent/${target_path}/$resource_dir"
            mkdir -p "$target_resource_dir"
            cp -r "$skill_source_dir/$resource_dir/"* "$target_resource_dir/" 2>/dev/null || true
            log_success "Copied: $resource_dir/"
        fi
    done
    
    # Get commit hash for tracking
    local commit_hash=""
    if [[ -d "$TEMP_DIR/repo/.git" ]]; then
        commit_hash=$(git -C "$TEMP_DIR/repo" rev-parse HEAD 2>/dev/null || echo "")
    fi
    
    # Register in skill-sources.json
    register_skill "$skill_name" "https://github.com/$owner/$repo${subpath:+/$subpath}" ".agent/${target_path}.md" "$format" "$commit_hash" "added" ""
    
    log_success "Skill '$skill_name' imported successfully"
    
    # Cleanup
    rm -rf "$TEMP_DIR"
    
    # Remind about setup.sh
    echo ""
    log_info "Run './setup.sh' to create symlinks for other AI assistants"
    
    return 0
}

# Import a skill from ClawdHub registry
cmd_add_clawdhub() {
    local slug="$1"
    local custom_name="$2"
    local force="$3"
    local dry_run="$4"
    
    if [[ -z "$slug" ]]; then
        log_error "ClawdHub slug required"
        return 1
    fi
    
    log_info "Importing from ClawdHub: $slug"
    
    # Get skill metadata from API
    local api_response
    api_response=$(curl -s --connect-timeout 10 --max-time 30 "${CLAWDHUB_API:-https://clawdhub.com/api/v1}/skills/${slug}" 2>/dev/null)
    
    if [[ -z "$api_response" ]] || ! echo "$api_response" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        log_error "Could not fetch skill info from ClawdHub API: $slug"
        return 1
    fi
    
    # Extract metadata
    local display_name summary owner_handle version
    display_name=$(echo "$api_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('skill',{}).get('displayName',''))" 2>/dev/null)
    summary=$(echo "$api_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('skill',{}).get('summary',''))" 2>/dev/null)
    owner_handle=$(echo "$api_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('owner',{}).get('handle',''))" 2>/dev/null)
    version=$(echo "$api_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('latestVersion',{}).get('version',''))" 2>/dev/null)
    
    log_info "Found: $display_name v${version} by @${owner_handle}"
    
    # Determine skill name
    local skill_name
    if [[ -n "$custom_name" ]]; then
        skill_name=$(to_kebab_case "$custom_name")
    else
        skill_name=$(to_kebab_case "$slug")
    fi
    
    # Determine target path
    local target_path
    target_path=$(determine_target_path "$skill_name" "$summary" ".")
    log_info "Target path: .agent/$target_path"
    
    # Check for conflicts
    local conflicts
    conflicts=$(check_conflicts "$target_path" ".agent") || true
    if [[ -n "$conflicts" ]]; then
        local blocking_conflicts
        blocking_conflicts=$(echo "$conflicts" | grep -v "^INFO:" || true)
        
        if [[ -n "$blocking_conflicts" && "$force" != true ]]; then
            log_warning "Conflicts detected:"
            echo "$blocking_conflicts" | while read -r conflict; do
                echo "  - ${conflict#*: }"
            done
            echo ""
            echo "Options:"
            echo "  1. Replace (overwrite existing)"
            echo "  2. Separate (use different name)"
            echo "  3. Skip (cancel import)"
            echo ""
            read -rp "Choose option [1-3]: " choice
            
            case "$choice" in
                1) log_info "Replacing existing..." ;;
                2)
                    read -rp "Enter new name: " new_name
                    skill_name=$(to_kebab_case "$new_name")
                    target_path=$(determine_target_path "$skill_name" "$summary" ".")
                    ;;
                3|*) log_info "Import cancelled"; return 0 ;;
            esac
        fi
    fi
    
    if [[ "$dry_run" == true ]]; then
        log_info "DRY RUN - Would create:"
        echo "  .agent/${target_path}.md"
        return 0
    fi
    
    # Fetch SKILL.md content using clawdhub-helper.sh (Playwright-based)
    local helper_script
    helper_script="$(dirname "$0")/clawdhub-helper.sh"
    local fetch_dir="${TMPDIR:-/tmp}/clawdhub-fetch/${slug}"
    
    rm -rf "$fetch_dir"
    
    if [[ -x "$helper_script" ]]; then
        if ! "$helper_script" fetch "$slug" --output "$fetch_dir"; then
            log_error "Failed to fetch SKILL.md from ClawdHub"
            return 1
        fi
    else
        log_error "clawdhub-helper.sh not found at: $helper_script"
        return 1
    fi
    
    # Verify SKILL.md was fetched
    if [[ ! -f "$fetch_dir/SKILL.md" || ! -s "$fetch_dir/SKILL.md" ]]; then
        log_error "SKILL.md not found or empty after fetch"
        return 1
    fi
    
    # Create target directory
    local target_dir
    target_dir=".agent/$(dirname "$target_path")"
    mkdir -p "$target_dir"
    
    # Convert to aidevops format
    local target_file=".agent/${target_path}.md"
    
    # Write aidevops-style header
    local safe_summary
    safe_summary=$(printf '%s' "${summary:-Imported from ClawdHub}" | sed 's/\\/\\\\/g; s/"/\\"/g')
    
    cat > "$target_file" << EOF
---
description: "${safe_summary}"
mode: subagent
imported_from: clawdhub
clawdhub_slug: "${slug}"
clawdhub_version: "${version}"
---
# ${display_name:-$skill_name}

EOF
    
    # Append the fetched SKILL.md content (skip any existing frontmatter)
    awk '
        BEGIN { in_frontmatter = 0; after_frontmatter = 0; has_frontmatter = 0 }
        NR == 1 && /^---$/ { in_frontmatter = 1; has_frontmatter = 1; next }
        in_frontmatter && /^---$/ { in_frontmatter = 0; after_frontmatter = 1; next }
        in_frontmatter { next }
        !has_frontmatter || after_frontmatter { print }
    ' "$fetch_dir/SKILL.md" >> "$target_file"
    
    log_success "Created: $target_file"
    
    # Register in skill-sources.json
    local upstream_url="https://clawdhub.com/${owner_handle}/${slug}"
    register_skill "$skill_name" "$upstream_url" ".agent/${target_path}.md" "clawdhub" "$version" "added" "ClawdHub v${version} by @${owner_handle}"
    
    # Cleanup
    rm -rf "$fetch_dir"
    
    log_success "Skill '$skill_name' imported from ClawdHub successfully"
    echo ""
    log_info "Run './setup.sh' to create symlinks for other AI assistants"
    
    return 0
}

cmd_list() {
    ensure_skill_sources
    
    echo ""
    echo "Imported Skills"
    echo "==============="
    echo ""
    
    if command -v jq &>/dev/null; then
        local count
        count=$(jq '.skills | length' "$SKILL_SOURCES")
        
        if [[ "$count" -eq 0 ]]; then
            echo "No skills imported yet."
            echo ""
            echo "Use: add-skill-helper.sh add <owner/repo>"
            return 0
        fi
        
        jq -r '.skills[] | "  \(.name)\n    Path: \(.local_path)\n    Source: \(.upstream_url)\n    Imported: \(.imported_at)\n"' "$SKILL_SOURCES"
    else
        cat "$SKILL_SOURCES"
    fi
    
    return 0
}

cmd_check_updates() {
    ensure_skill_sources
    
    log_info "Checking for upstream updates..."
    
    if ! command -v jq &>/dev/null; then
        log_error "jq is required for update checking"
        return 1
    fi
    
    local skills
    skills=$(jq -r '.skills[] | "\(.name)|\(.upstream_url)|\(.upstream_commit)"' "$SKILL_SOURCES")
    
    if [[ -z "$skills" ]]; then
        log_info "No imported skills to check"
        return 0
    fi
    
    local updates_available=false
    
    while IFS='|' read -r name url commit; do
        # Extract owner/repo from URL
        local parsed
        parsed=$(parse_github_url "$url")
        IFS='|' read -r owner repo subpath <<< "$parsed"
        
        if [[ -z "$owner" || -z "$repo" ]]; then
            log_warning "Could not parse URL for $name: $url"
            continue
        fi
        
        # Get latest commit from GitHub API
        local api_url="https://api.github.com/repos/$owner/$repo/commits?per_page=1"
        local latest_commit
        latest_commit=$(curl -s --connect-timeout 10 --max-time 30 "$api_url" | jq -r '.[0].sha // empty' 2>/dev/null)
        
        if [[ -z "$latest_commit" ]]; then
            log_warning "Could not fetch latest commit for $name"
            continue
        fi
        
        if [[ "$latest_commit" != "$commit" ]]; then
            updates_available=true
            echo -e "${YELLOW}UPDATE AVAILABLE${NC}: $name"
            echo "  Current: ${commit:0:7}"
            echo "  Latest:  ${latest_commit:0:7}"
            echo "  Run: add-skill-helper.sh add $url --force"
            echo ""
        else
            echo -e "${GREEN}Up to date${NC}: $name"
        fi
    done <<< "$skills"
    
    if [[ "$updates_available" == false ]]; then
        log_success "All skills are up to date"
    fi
    
    return 0
}

cmd_remove() {
    local name="$1"
    
    if [[ -z "$name" ]]; then
        log_error "Skill name required"
        return 1
    fi
    
    ensure_skill_sources
    
    if ! command -v jq &>/dev/null; then
        log_error "jq is required for skill removal"
        return 1
    fi
    
    # Find skill in registry
    local skill_path
    skill_path=$(jq -r --arg name "$name" '.skills[] | select(.name == $name) | .local_path' "$SKILL_SOURCES")
    
    if [[ -z "$skill_path" ]]; then
        log_error "Skill not found: $name"
        return 1
    fi
    
    log_info "Removing skill: $name"
    log_info "Path: $skill_path"
    
    # Remove files
    if [[ -f "$skill_path" ]]; then
        rm -f "$skill_path"
        log_success "Removed: $skill_path"
    fi
    
    # Remove directory if exists
    local dir_path="${skill_path%.md}"
    if [[ -d "$dir_path" ]]; then
        rm -rf "$dir_path"
        log_success "Removed: $dir_path/"
    fi
    
    # Remove from registry
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg name "$name" '.skills = [.skills[] | select(.name != $name)]' "$SKILL_SOURCES" > "$tmp_file"
    mv "$tmp_file" "$SKILL_SOURCES"
    
    log_success "Skill '$name' removed"
    
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        add)
            if [[ $# -lt 1 ]]; then
                log_error "URL or owner/repo required"
                echo "Usage: add-skill-helper.sh add <url|owner/repo> [--name <name>] [--force]"
                return 1
            fi
            cmd_add "$@"
            ;;
        list)
            cmd_list
            ;;
        check-updates|updates)
            cmd_check_updates
            ;;
        remove|rm)
            cmd_remove "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
}

main "$@"
