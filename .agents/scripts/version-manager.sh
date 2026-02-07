#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Version Manager for AI DevOps Framework
# Manages semantic versioning and automated version bumping
#
# Author: AI DevOps Framework
# Version: 1.1.0

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

print_info() { local msg="$1"; echo -e "${BLUE}[INFO]${NC} $msg"; return 0; }
print_success() { local msg="$1"; echo -e "${GREEN}[SUCCESS]${NC} $msg"; return 0; }
print_warning() { local msg="$1"; echo -e "${YELLOW}[WARNING]${NC} $msg"; return 0; }
print_error() { local msg="$1"; echo -e "${RED}[ERROR]${NC} $msg" >&2; return 0; }

# Cross-platform sed in-place edit (works on macOS and Linux)
# Usage: sed_inplace 'pattern' 'file'
sed_inplace() {
    local pattern="$1"
    local file="$2"
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$pattern" "$file"
    else
        sed -i "$pattern" "$file"
    fi
    return $?
}

# Repository root directory
# First try git (works when called from any location within a repo)
# Fall back to script-relative path (for when script is sourced or tested standalone)
if git rev-parse --show-toplevel &>/dev/null; then
    REPO_ROOT="$(git rev-parse --show-toplevel)"
else
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
VERSION_FILE="$REPO_ROOT/VERSION"

# Function to get current version
get_current_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE"
    else
        echo "1.0.0"
    fi
    return 0
}

# Function to bump version
bump_version() {
    local bump_type="$1"
    local current_version
    current_version=$(get_current_version)
    
    IFS='.' read -r major minor patch <<< "$current_version"
    
    case "$bump_type" in
        "major")
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        "minor")
            minor=$((minor + 1))
            patch=0
            ;;
        "patch")
            patch=$((patch + 1))
            ;;
        *)
            print_error "Invalid bump type. Use: major, minor, or patch"
            return 1
            ;;
    esac
    
    local new_version="$major.$minor.$patch"
    echo "$new_version" > "$VERSION_FILE"
    echo "$new_version"
    return 0
}

# Function to check changelog has entry for version
check_changelog_version() {
    local version="$1"
    local changelog_file="$REPO_ROOT/CHANGELOG.md"
    
    if [[ ! -f "$changelog_file" ]]; then
        print_warning "CHANGELOG.md not found"
        return 1
    fi
    
    # Check if version entry exists
    if grep -q "^\## \[$version\]" "$changelog_file"; then
        print_success "CHANGELOG.md: $version ✓"
        return 0
    else
        print_error "CHANGELOG.md missing entry for version $version"
        return 1
    fi
}

# Function to check changelog has unreleased content
check_changelog_unreleased() {
    local changelog_file="$REPO_ROOT/CHANGELOG.md"
    
    if [[ ! -f "$changelog_file" ]]; then
        print_warning "CHANGELOG.md not found"
        return 1
    fi
    
    # Check if [Unreleased] section exists
    if ! grep -q "^\## \[Unreleased\]" "$changelog_file"; then
        print_error "CHANGELOG.md missing [Unreleased] section"
        return 1
    fi
    
    # Check if there's content under [Unreleased]
    local unreleased_content
    unreleased_content=$(sed -n '/^## \[Unreleased\]/,/^## \[/p' "$changelog_file" | grep -v "^##" | grep -v "^$" | head -5)
    
    if [[ -z "$unreleased_content" ]]; then
        print_warning "CHANGELOG.md [Unreleased] section is empty"
        return 1
    fi
    
    print_success "CHANGELOG.md has unreleased content ✓"
    return 0
}

# Function to generate changelog preview from commits
generate_changelog_preview() {
    local prev_tag
    prev_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
    
    local version
    version=$(get_current_version)
    
    echo "## [$version] - $(date +%Y-%m-%d)"
    echo ""
    
    # Categorize commits
    local added="" changed="" fixed="" security=""
    
    local commits
    if [[ -n "$prev_tag" ]]; then
        commits=$(git log "$prev_tag"..HEAD --pretty=format:"%s" 2>/dev/null)
    else
        commits=$(git log --oneline -20 --pretty=format:"%s" 2>/dev/null)
    fi
    
    while IFS= read -r commit; do
        case "$commit" in
            feat:*|feat\(*) added="$added\n- ${commit#feat: }" ;;
            fix:*|fix\(*) fixed="$fixed\n- ${commit#fix: }" ;;
            security:*) security="$security\n- ${commit#security: }" ;;
            refactor:*|docs:*|chore:*) changed="$changed\n- $commit" ;;
            *) ;; # Ignore other commit types
        esac
    done <<< "$commits"
    
    [[ -n "$added" ]] && echo -e "### Added\n$added\n"
    [[ -n "$changed" ]] && echo -e "### Changed\n$changed\n"
    [[ -n "$fixed" ]] && echo -e "### Fixed\n$fixed\n"
    [[ -n "$security" ]] && echo -e "### Security\n$security\n"
    
    return 0
}

# Function to generate changelog content from commits (cleaner format)
generate_changelog_content() {
    local prev_tag
    prev_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
    
    # Categorize commits
    local added="" changed="" fixed="" security="" removed="" deprecated=""
    
    local commits
    if [[ -n "$prev_tag" ]]; then
        commits=$(git log "$prev_tag"..HEAD --pretty=format:"%s" 2>/dev/null)
    else
        commits=$(git log --oneline -20 --pretty=format:"%s" 2>/dev/null)
    fi
    
    while IFS= read -r commit; do
        # Skip empty lines and release commits
        [[ -z "$commit" ]] && continue
        [[ "$commit" == chore\(release\):* ]] && continue
        
        # Clean up commit message - remove type prefix for cleaner output
        local clean_msg="$commit"
        
        case "$commit" in
            feat:*) 
                clean_msg="${commit#feat: }"
                added="${added}- ${clean_msg}\n"
                ;;
            feat\(*\):*)
                clean_msg=$(echo "$commit" | sed 's/^feat([^)]*): //')
                added="${added}- ${clean_msg}\n"
                ;;
            fix:*)
                clean_msg="${commit#fix: }"
                fixed="${fixed}- ${clean_msg}\n"
                ;;
            fix\(*\):*)
                clean_msg=$(echo "$commit" | sed 's/^fix([^)]*): //')
                fixed="${fixed}- ${clean_msg}\n"
                ;;
            security:*)
                clean_msg="${commit#security: }"
                security="${security}- ${clean_msg}\n"
                ;;
            docs:*)
                clean_msg="${commit#docs: }"
                changed="${changed}- Documentation: ${clean_msg}\n"
                ;;
            refactor:*)
                clean_msg="${commit#refactor: }"
                changed="${changed}- Refactor: ${clean_msg}\n"
                ;;
            perf:*)
                clean_msg="${commit#perf: }"
                changed="${changed}- Performance: ${clean_msg}\n"
                ;;
            BREAKING\ CHANGE:*|breaking:*)
                clean_msg="${commit#BREAKING CHANGE: }"
                clean_msg="${clean_msg#breaking: }"
                removed="${removed}- **BREAKING**: ${clean_msg}\n"
                ;;
            deprecate:*|deprecated:*)
                clean_msg="${commit#deprecate: }"
                clean_msg="${clean_msg#deprecated: }"
                deprecated="${deprecated}- ${clean_msg}\n"
                ;;
            # Skip chore commits (noise in changelog)
            chore:*|chore\(*) ;;
            *) ;; # Ignore other commit types
        esac
    done <<< "$commits"
    
    # Output in Keep a Changelog order
    [[ -n "$added" ]] && printf "### Added\n\n%b\n" "$added"
    [[ -n "$changed" ]] && printf "### Changed\n\n%b\n" "$changed"
    [[ -n "$deprecated" ]] && printf "### Deprecated\n\n%b\n" "$deprecated"
    [[ -n "$removed" ]] && printf "### Removed\n\n%b\n" "$removed"
    [[ -n "$fixed" ]] && printf "### Fixed\n\n%b\n" "$fixed"
    [[ -n "$security" ]] && printf "### Security\n\n%b\n" "$security"
    
    return 0
}

# Function to update CHANGELOG.md with new version
update_changelog() {
    local version="$1"
    local changelog_file="$REPO_ROOT/CHANGELOG.md"
    local today
    today=$(date +%Y-%m-%d)
    
    if [[ ! -f "$changelog_file" ]]; then
        print_warning "CHANGELOG.md not found, creating new one"
        cat > "$changelog_file" << 'EOF'
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

EOF
    fi
    
    # Check if [Unreleased] section exists
    if ! grep -q "^\## \[Unreleased\]" "$changelog_file"; then
        print_error "CHANGELOG.md missing [Unreleased] section"
        return 1
    fi
    
    # Generate changelog content from commits
    local changelog_content
    changelog_content=$(generate_changelog_content)
    
    if [[ -z "$changelog_content" ]]; then
        print_warning "No conventional commits found for changelog generation"
        changelog_content="### Changed

- Version bump and maintenance updates
"
    fi
    
    # Create temp files for the update
    local temp_file content_file
    temp_file=$(mktemp)
    content_file=$(mktemp)
    
    # Write the new version section to a temp file (avoids awk multiline issues)
    cat > "$content_file" << EOF
## [$version] - $today

$changelog_content
EOF
    
    # Process the changelog using sed instead of awk for reliability
    # 1. Find the [Unreleased] line
    # 2. Keep it, add blank line, then insert new version content
    # 3. Skip any existing content under [Unreleased] until next ## section
    
    local in_unreleased=0
    local printed_new=0
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "## [Unreleased]"* ]]; then
            echo "## [Unreleased]"
            echo ""
            cat "$content_file"
            in_unreleased=1
            printed_new=1
        elif [[ "$line" == "## ["* ]] && [[ $in_unreleased -eq 1 ]]; then
            # Next version section found, stop skipping
            in_unreleased=0
            echo ""
            echo "$line"
        elif [[ $in_unreleased -eq 0 ]]; then
            echo "$line"
        fi
        # Skip lines while in_unreleased=1 (old unreleased content)
    done < "$changelog_file" > "$temp_file"
    
    # Replace original file
    mv "$temp_file" "$changelog_file"
    rm -f "$content_file"
    
    print_success "Updated CHANGELOG.md: [Unreleased] → [$version] - $today"
    return 0
}

# Function to run preflight quality checks
run_preflight_checks() {
    print_info "Running preflight quality checks..."
    
    local preflight_script="$REPO_ROOT/.agents/scripts/linters-local.sh"
    
    if [[ -f "$preflight_script" ]]; then
        if bash "$preflight_script"; then
            print_success "Preflight checks passed ✓"
            return 0
        else
            print_error "Preflight checks failed"
            return 1
        fi
    else
        print_warning "Preflight script not found, skipping checks"
        return 0
    fi
}

# Function to validate version consistency across files
# Delegates to the standalone validator script for single source of truth
validate_version_consistency() {
    local expected_version="$1"
    local validator_script="${REPO_ROOT}/.agents/scripts/validate-version-consistency.sh"
    
    print_info "Validating version consistency across files..."
    
    if [[ -x "$validator_script" ]]; then
        # Use the standalone validator (single source of truth)
        "$validator_script" "$expected_version"
        return $?
    else
        # Fallback: basic validation if standalone script not found
        print_warning "Standalone validator not found, using basic validation"
        
        local errors=0
        
        # Check VERSION file
        if [[ -f "$VERSION_FILE" ]]; then
            local version_file_content
            version_file_content=$(cat "$VERSION_FILE")
            if [[ "$version_file_content" != "$expected_version" ]]; then
                print_error "VERSION file contains '$version_file_content', expected '$expected_version'"
                errors=$((errors + 1))
            else
                print_success "VERSION file: $expected_version ✓"
            fi
        else
            print_error "VERSION file not found"
            errors=$((errors + 1))
        fi
        
        if [[ $errors -eq 0 ]]; then
            print_success "Basic version validation passed: $expected_version"
            return 0
        else
            print_error "Found $errors version inconsistencies"
            return 1
        fi
    fi
    return 0
}

# Function to update version in files
update_version_in_files() {
    local new_version="$1"
    local errors=0
    
    print_info "Updating version references in files..."
    
    # Update VERSION file
    if [[ -f "$VERSION_FILE" ]]; then
        echo "$new_version" > "$VERSION_FILE"
        if [[ "$(cat "$VERSION_FILE")" == "$new_version" ]]; then
            print_success "Updated VERSION file"
        else
            print_error "Failed to update VERSION file"
            errors=$((errors + 1))
        fi
    fi
    
    # Update package.json if it exists
    if [[ -f "$REPO_ROOT/package.json" ]]; then
        sed_inplace "s/\"version\": \"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\"/\"version\": \"$new_version\"/" "$REPO_ROOT/package.json"
        if grep -q "\"version\": \"$new_version\"" "$REPO_ROOT/package.json"; then
            print_success "Updated package.json"
        else
            print_error "Failed to update package.json"
            errors=$((errors + 1))
        fi
    fi
    
    # Update sonar-project.properties
    if [[ -f "$REPO_ROOT/sonar-project.properties" ]]; then
        sed_inplace "s/sonar\.projectVersion=.*/sonar.projectVersion=$new_version/" "$REPO_ROOT/sonar-project.properties"
        if grep -q "sonar.projectVersion=$new_version" "$REPO_ROOT/sonar-project.properties"; then
            print_success "Updated sonar-project.properties"
        else
            print_error "Failed to update sonar-project.properties"
            errors=$((errors + 1))
        fi
    fi
    
    # Update setup.sh if it exists
    if [[ -f "$REPO_ROOT/setup.sh" ]]; then
        sed_inplace "s/# Version: .*/# Version: $new_version/" "$REPO_ROOT/setup.sh"
        if grep -q "# Version: $new_version" "$REPO_ROOT/setup.sh"; then
            print_success "Updated setup.sh"
        else
            print_error "Failed to update setup.sh"
            errors=$((errors + 1))
        fi
    fi
    
    # Update aidevops.sh CLI if it exists
    if [[ -f "$REPO_ROOT/aidevops.sh" ]]; then
        sed_inplace "s/# Version: .*/# Version: $new_version/" "$REPO_ROOT/aidevops.sh"
        if grep -q "# Version: $new_version" "$REPO_ROOT/aidevops.sh"; then
            print_success "Updated aidevops.sh"
        else
            print_error "Failed to update aidevops.sh"
            errors=$((errors + 1))
        fi
    fi
    
    # Update README version badge (skip if using dynamic GitHub release badge)
    if [[ -f "$REPO_ROOT/README.md" ]]; then
        if grep -q "img.shields.io/github/v/release" "$REPO_ROOT/README.md"; then
            # Dynamic badge - no update needed, GitHub handles it automatically
            print_success "README.md uses dynamic GitHub release badge (no update needed)"
        elif grep -q "Version-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*-blue" "$REPO_ROOT/README.md"; then
            # Hardcoded badge - update it
            sed_inplace "s/Version-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*-blue/Version-$new_version-blue/" "$REPO_ROOT/README.md"
            
            # Validate the update was successful
            if grep -q "Version-$new_version-blue" "$REPO_ROOT/README.md"; then
                print_success "Updated README.md version badge to $new_version"
            else
                print_error "Failed to update README.md version badge"
                errors=$((errors + 1))
            fi
        else
            # No version badge found - that's okay, just warn
            print_warning "README.md has no version badge (consider adding dynamic GitHub release badge)"
        fi
    else
        print_warning "README.md not found, skipping version badge update"
    fi
    
    # Update Claude Code plugin marketplace.json
    if [[ -f "$REPO_ROOT/.claude-plugin/marketplace.json" ]]; then
        sed_inplace "s/\"version\": \"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\"/\"version\": \"$new_version\"/" "$REPO_ROOT/.claude-plugin/marketplace.json"
        
        # Validate the update was successful
        if grep -q "\"version\": \"$new_version\"" "$REPO_ROOT/.claude-plugin/marketplace.json"; then
            print_success "Updated .claude-plugin/marketplace.json"
        else
            print_error "Failed to update .claude-plugin/marketplace.json"
            errors=$((errors + 1))
        fi
    fi
    
    # Return error if any updates failed
    if [[ $errors -gt 0 ]]; then
        print_error "Failed to update $errors file(s)"
        return 1
    fi
    
    print_success "All version files updated to $new_version"
    return 0
}

# Function to verify local branch is in sync with remote
# Prevents release failures when local has diverged (e.g., after squash merge)
verify_remote_sync() {
    local branch="$1"
    branch="${branch:-main}"
    
    cd "$REPO_ROOT" || exit 1
    
    # Verify we're actually on the expected branch
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null)
    if [[ "$current_branch" != "$branch" ]]; then
        print_error "Not on $branch branch (currently on: ${current_branch:-detached HEAD})"
        print_info "Switch to $branch first: git checkout $branch"
        return 1
    fi
    
    print_info "Verifying local/$branch is in sync with origin/$branch..."
    
    # Fetch latest from remote
    if ! git fetch origin "$branch" --quiet 2>/dev/null; then
        print_warning "Could not fetch from remote - proceeding without sync check"
        return 0
    fi
    
    local local_sha
    local_sha=$(git rev-parse "$branch" 2>/dev/null)
    local remote_sha
    remote_sha=$(git rev-parse "origin/$branch" 2>/dev/null)
    
    if [[ -z "$local_sha" || -z "$remote_sha" ]]; then
        print_warning "Could not determine local/remote SHA - proceeding without sync check"
        return 0
    fi
    
    if [[ "$local_sha" != "$remote_sha" ]]; then
        # Check relationship: behind, ahead, or diverged
        if git merge-base --is-ancestor "$local_sha" "$remote_sha" 2>/dev/null; then
            # Local is behind remote - auto-pull with rebase
            print_info "Local $branch is behind origin/$branch, pulling..."
            if git pull --rebase origin "$branch" --quiet 2>/dev/null; then
                print_success "Auto-pulled latest changes from origin/$branch"
                return 0
            else
                print_error "Failed to auto-pull. Manual intervention required."
                print_info "Fix with: git pull --rebase origin $branch"
                return 1
            fi
        elif git merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null; then
            # Local is ahead of remote - this is fine for release, just inform
            print_info "Local $branch is ahead of origin/$branch (unpushed commits)"
            print_info "This is expected if you have local commits ready to release."
            return 0
        else
            # Truly diverged - cannot auto-fix
            print_error "Local $branch has diverged from origin/$branch"
            print_info "  Local:  $local_sha"
            print_info "  Remote: $remote_sha"
            echo ""
            print_info "This commonly happens after a squash merge on GitHub."
            print_info "Fix with: git fetch origin && git reset --hard origin/$branch"
            return 1
        fi
    fi
    
    print_success "Local $branch is in sync with origin/$branch"
    return 0
}

# Function to check for uncommitted changes
check_working_tree_clean() {
    local uncommitted
    uncommitted=$(git status --porcelain 2>/dev/null)
    
    if [[ -n "$uncommitted" ]]; then
        print_error "Working tree has uncommitted changes:"
        echo "$uncommitted" | head -20
        echo ""
        print_info "Options:"
        print_info "  1. Commit your changes first: git add -A && git commit -m 'your message'"
        print_info "  2. Stash changes: git stash"
        print_info "  3. Use --allow-dirty to release anyway (not recommended)"
        return 1
    fi
    return 0
}

# Function to extract task IDs from commit messages since last tag
# Only extracts from commits that indicate task COMPLETION, not mere mentions
# Completion patterns:
#   - Conventional commits with task scope: feat(t001):, fix(t002):, docs(t003):
#   - Explicit completion phrases: "mark t001 done", "complete t002", "closes t003"
#   - Multi-task with explicit marker: "mark t001, t002 done" (tasks before "done")
extract_task_ids_from_commits() {
    local prev_tag
    prev_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
    
    local commits
    if [[ -n "$prev_tag" ]]; then
        commits=$(git log "$prev_tag"..HEAD --pretty=format:"%s" 2>/dev/null)
    else
        commits=$(git log --oneline -50 --pretty=format:"%s" 2>/dev/null)
    fi
    
    local task_ids=""
    
    while IFS= read -r commit; do
        [[ -z "$commit" ]] && continue
        
        # Pattern 1: Conventional commits with task ID in scope
        # e.g., feat(t001):, fix(t002):, docs(t003.1):, refactor(t004):
        if [[ "$commit" =~ ^(feat|fix|docs|refactor|perf|test|chore|style|build|ci)\(t[0-9]{3}(\.[0-9]+)*\): ]]; then
            local id
            id=$(echo "$commit" | grep -oE '\(t[0-9]{3}(\.[0-9]+)*\)' | tr -d '()')
            task_ids="$task_ids $id"
        fi
        
        # Pattern 2: "mark tXXX done/complete" - extract task IDs between "mark" and "done/complete"
        # e.g., "mark t004, t048, t069 done" -> t004, t048, t069
        if [[ "$commit" =~ mark[[:space:]]+(.*)[[:space:]]+(done|complete) ]]; then
            local segment="${BASH_REMATCH[1]}"
            local ids
            ids=$(echo "$segment" | grep -oE '\bt[0-9]{3}(\.[0-9]+)*\b')
            task_ids="$task_ids $ids"
        fi
        
        # Pattern 3: "complete/completes/closes tXXX" - task ID immediately after keyword
        # e.g., "complete t037", "closes t001"
        local ids
        ids=$(echo "$commit" | grep -oE '(completes?|closes?)[[:space:]]+t[0-9]{3}(\.[0-9]+)*' | grep -oE 't[0-9]{3}(\.[0-9]+)*')
        if [[ -n "$ids" ]]; then
            task_ids="$task_ids $ids"
        fi
        
        # Pattern 4: "tXXX complete/done/finished" - task ID before completion word
        # e.g., "t001 complete", "t002 done"
        ids=$(echo "$commit" | grep -oE 't[0-9]{3}(\.[0-9]+)*[[:space:]]+(complete|done|finished)' | grep -oE 't[0-9]{3}(\.[0-9]+)*')
        if [[ -n "$ids" ]]; then
            task_ids="$task_ids $ids"
        fi
        
    done <<< "$commits"
    
    # Deduplicate and sort
    echo "$task_ids" | tr ' ' '\n' | grep -E '^t[0-9]{3}' | sort -u
    return 0
}

# Function to auto-mark tasks complete in TODO.md based on commit messages
# Parses commits since last tag for task IDs and marks them complete
auto_mark_tasks_complete() {
    local todo_file="$REPO_ROOT/TODO.md"
    local today
    today=$(date +%Y-%m-%dT%H:%M:%SZ)
    local today_short
    today_short=$(date +%Y-%m-%d)
    
    if [[ ! -f "$todo_file" ]]; then
        print_warning "TODO.md not found, skipping task auto-completion"
        return 0
    fi
    
    print_info "Scanning commits for task IDs to auto-mark complete..."
    
    local task_ids
    task_ids=$(extract_task_ids_from_commits)
    
    if [[ -z "$task_ids" ]]; then
        print_info "No task IDs found in commits since last release"
        return 0
    fi
    
    local count=0
    local marked_tasks=""
    
    # Process each task ID
    while IFS= read -r task_id; do
        [[ -z "$task_id" ]] && continue
        
        # Build regex patterns (avoids shellcheck SC1087 false positive with [[:space:]])
        local unchecked_pattern="^[[:space:]]*- \\[ \\] ${task_id}[[:space:]]"
        local checked_pattern="^[[:space:]]*- \\[x\\] ${task_id}[[:space:]]"
        
        # Check if task exists and is not already complete
        # Pattern: - [ ] t001 ... (not already checked)
        if grep -qE "$unchecked_pattern" "$todo_file"; then
            # Mark task complete: change [ ] to [x] and add completed: timestamp
            # Use sed to update the line
            local escaped_id
            escaped_id=$(echo "$task_id" | sed 's/\./\\./g')
            
            # Build sed patterns
            local sed_unchecked_pattern="^[[:space:]]*- \\[ \\] ${escaped_id}[[:space:]]"
            
            # Check if line already has completed: field
            if grep -E "$sed_unchecked_pattern" "$todo_file" | grep -q "completed:"; then
                # Just change checkbox
                sed -i '' "s/^\\([[:space:]]*\\)- \\[ \\] \\(${escaped_id}[[:space:]]\\)/\\1- [x] \\2/" "$todo_file"
            else
                # Change checkbox and add completed: timestamp
                sed -i '' "s/^\\([[:space:]]*\\)- \\[ \\] \\(${escaped_id}[[:space:]].*\\)\$/\\1- [x] \\2 completed:$today_short/" "$todo_file"
            fi
            
            count=$((count + 1))
            marked_tasks="$marked_tasks $task_id"
            print_success "Marked $task_id as complete"
        elif grep -qE "$checked_pattern" "$todo_file"; then
            print_info "Task $task_id already marked complete"
        else
            print_warning "Task $task_id not found in TODO.md (may be subtask or already moved)"
        fi
    done <<< "$task_ids"
    
    if [[ $count -gt 0 ]]; then
        print_success "Auto-marked $count task(s) complete:$marked_tasks"
    fi
    
    return 0
}

# Function to commit version changes
commit_version_changes() {
    local version="$1"
    
    cd "$REPO_ROOT" || exit 1
    
    print_info "Committing version changes..."
    
    # Stage all version-related files (including CHANGELOG.md, TODO.md, and Claude plugin)
    git add VERSION package.json README.md setup.sh aidevops.sh sonar-project.properties CHANGELOG.md TODO.md .claude-plugin/marketplace.json 2>/dev/null
    
    # Check if there are changes to commit
    if git diff --cached --quiet; then
        print_info "No version changes to commit"
        return 0
    fi
    
    if git commit -m "chore(release): bump version to $version"; then
        print_success "Committed version changes"
        return 0
    else
        print_error "Failed to commit version changes"
        return 1
    fi
}

# Function to push changes and tags
push_changes() {
    cd "$REPO_ROOT" || exit 1
    
    print_info "Pushing changes to remote..."
    
    # Use --atomic to ensure commit and tag are pushed together (all-or-nothing)
    if git push --atomic origin main --tags; then
        print_success "Pushed changes and tags to remote"
        return 0
    else
        print_error "Failed to push to remote"
        return 1
    fi
}

# Function to create git tag
create_git_tag() {
    local version="$1"
    local tag_name="v$version"

    print_info "Creating git tag: $tag_name"

    cd "$REPO_ROOT" || exit 1

    if git tag -a "$tag_name" -m "Release $tag_name - AI DevOps Framework"; then
        print_success "Created git tag: $tag_name"
        return 0
    else
        print_error "Failed to create git tag"
        return 1
    fi
    return 0
}

# Function to create GitHub release
create_github_release() {
    local version="$1"
    local tag_name="v$version"

    print_info "Creating GitHub release: $tag_name"

    # Try GitHub CLI first
    if command -v gh &> /dev/null && gh auth status &> /dev/null; then
        print_info "Using GitHub CLI for release creation"

        # Generate release notes based on version
        local release_notes
        release_notes=$(generate_release_notes "$version")

        # Create GitHub release
        if gh release create "$tag_name" \
            --title "$tag_name - AI DevOps Framework" \
            --notes "$release_notes" \
            --latest; then
            print_success "Created GitHub release: $tag_name"
            return 0
        else
            print_error "Failed to create GitHub release with GitHub CLI"
            return 1
        fi
    else
        # GitHub CLI not available
        print_warning "GitHub release creation skipped - GitHub CLI not available"
        print_info "To enable GitHub releases:"
        print_info "1. Install GitHub CLI: brew install gh (macOS)"
        print_info "2. Authenticate: gh auth login"
        return 0
    fi
    return 0
}

# Function to generate release notes
generate_release_notes() {
    local version="$1"
    # Parse version components (reserved for version-specific logic)
    # shellcheck disable=SC2034
    local major minor patch
    IFS='.' read -r major minor patch <<< "$version"

    cat << EOF
## AI DevOps Framework v$version

### Installation

\`\`\`bash
# npm (recommended)
npm install -g aidevops && aidevops update

# Homebrew
brew install marcusquinn/tap/aidevops && aidevops update

# curl
bash <(curl -fsSL https://aidevops.sh)
\`\`\`

### What's New

See [CHANGELOG.md](CHANGELOG.md) for detailed changes.

### Quick Start

\`\`\`bash
# Check installation
aidevops status

# Initialize in a project
aidevops init

# Update framework + projects
aidevops update

# List registered projects
aidevops repos
\`\`\`

### Documentation

- **[Setup Guide](README.md)**: Complete framework setup
- **[User Guide](.agents/AGENTS.md)**: AI assistant integration
- **[API Integrations](.agents/aidevops/api-integrations.md)**: Service APIs

### Links

- **Website**: https://aidevops.sh
- **Repository**: https://github.com/marcusquinn/aidevops
- **Issues**: https://github.com/marcusquinn/aidevops/issues

---

**Full Changelog**: https://github.com/marcusquinn/aidevops/compare/v1.0.0...v$version
EOF
    return 0
}

# Main function
main() {
    local action="$1"
    local bump_type="$2"
    
    case "$action" in
        "get")
            get_current_version
            ;;
        "bump")
            if [[ -z "$bump_type" ]]; then
                print_error "Bump type required. Usage: $0 bump [major|minor|patch]"
                exit 1
            fi
            
            local current_version
            current_version=$(get_current_version)
            print_info "Current version: $current_version"
            
            local new_version
            new_version=$(bump_version "$bump_type")
            
            if [[ $? -eq 0 ]]; then
                print_success "Bumped version: $current_version → $new_version"
                if ! update_version_in_files "$new_version"; then
                    print_error "Failed to update version in all files"
                    print_info "Run validation to check: $0 validate"
                    exit 1
                fi
                echo "$new_version"
            else
                exit 1
            fi
            ;;
        "tag")
            local version
            version=$(get_current_version)
            create_git_tag "$version"
            ;;
        "release")
            if [[ -z "$bump_type" ]]; then
                print_error "Bump type required. Usage: $0 release [major|minor|patch]"
                exit 1
            fi

            # Parse flags (can be in any order after bump_type)
            local force_flag=""
            local skip_preflight=""
            local allow_dirty=""
            for arg in "${@:3}"; do
                case "$arg" in
                    "--force") force_flag="--force" ;;
                    "--skip-preflight") skip_preflight="--skip-preflight" ;;
                    "--allow-dirty") allow_dirty="--allow-dirty" ;;
                    *) ;;  # Ignore unknown flags
                esac
            done

            print_info "Creating release with $bump_type version bump..."

            # Verify local branch is in sync with remote (prevents post-squash-merge failures)
            if ! verify_remote_sync "main"; then
                if [[ "$force_flag" != "--force" ]]; then
                    print_error "Cannot release when local/remote are out of sync."
                    print_info "Use --force to bypass (not recommended)"
                    exit 1
                else
                    print_warning "Bypassing remote sync check with --force"
                fi
            fi

            # Check for uncommitted changes
            if [[ "$allow_dirty" != "--allow-dirty" ]]; then
                if ! check_working_tree_clean; then
                    print_error "Cannot release with uncommitted changes."
                    print_info "Commit your changes first, or use --allow-dirty to bypass (not recommended)"
                    exit 1
                fi
            else
                print_warning "Releasing with uncommitted changes (--allow-dirty)"
            fi

            # Run preflight checks unless skipped
            if [[ "$skip_preflight" != "--skip-preflight" ]]; then
                if ! run_preflight_checks; then
                    print_error "Preflight checks failed. Fix issues or use --skip-preflight to bypass."
                    exit 1
                fi
            else
                print_warning "Skipping preflight checks with --skip-preflight"
            fi

            # Check changelog has content before proceeding
            if ! check_changelog_unreleased; then
                if [[ "$force_flag" != "--force" ]]; then
                    print_error "CHANGELOG.md [Unreleased] section is empty or missing"
                    print_info "Add changelog entries or use --force to bypass"
                    print_info "Run: $0 changelog-preview to see suggested entries"
                    exit 1
                else
                    print_warning "Bypassing changelog check with --force"
                fi
            fi

            local new_version
            new_version=$(bump_version "$bump_type")

            if [[ $? -eq 0 ]]; then
                print_info "Updating version references in files..."
                if ! update_version_in_files "$new_version"; then
                    print_error "Failed to update version in all files. Aborting release."
                    print_info "The VERSION file may have been updated. Run validation to check:"
                    print_info "  $0 validate"
                    exit 1
                fi

                print_info "Updating CHANGELOG.md..."
                if ! update_changelog "$new_version"; then
                    print_warning "Failed to update CHANGELOG.md automatically"
                fi

                # Auto-mark tasks complete based on commit messages
                auto_mark_tasks_complete

                print_info "Validating version consistency..."
                if validate_version_consistency "$new_version"; then
                    print_success "Version validation passed"
                    commit_version_changes "$new_version"
                    create_git_tag "$new_version"
                    if ! push_changes; then
                        # Rollback: delete local tag since --atomic ensures nothing was pushed
                        print_warning "Rolling back local tag v$new_version due to push failure"
                        git tag -d "v$new_version" 2>/dev/null
                        echo ""
                        print_info "The version commit exists locally. To complete the release:"
                        print_info "  1. Fix the issue (e.g., git fetch origin && git rebase origin/main)"
                        print_info "  2. Re-create tag: git tag -a v$new_version -m 'Release v$new_version'"
                        print_info "  3. Push: git push --atomic origin main --tags"
                        print_info "  4. Create release: $0 github-release"
                        exit 1
                    fi
                    create_github_release "$new_version"
                    print_success "Release $new_version created successfully!"
                else
                    print_error "Version validation failed. Please fix inconsistencies before creating release."
                    exit 1
                fi
            else
                exit 1
            fi
            ;;
        "github-release")
            local version
            version=$(get_current_version)
            create_github_release "$version"
            ;;
        "validate")
            local version
            version=$(get_current_version)
            validate_version_consistency "$version"
            ;;
        "changelog-check")
            local version
            version=$(get_current_version)
            print_info "Checking CHANGELOG.md for version $version..."
            if check_changelog_version "$version"; then
                print_success "CHANGELOG.md is in sync with VERSION"
            else
                print_error "CHANGELOG.md is out of sync with VERSION ($version)"
                print_info "Run: $0 changelog-preview to see suggested entries"
                exit 1
            fi
            ;;
        "changelog-preview")
            print_info "Generating changelog preview from commits..."
            echo ""
            generate_changelog_preview
            ;;
        "auto-mark-tasks")
            print_info "Auto-marking tasks complete from commit messages..."
            auto_mark_tasks_complete
            ;;
        "list-task-ids")
            print_info "Task IDs found in commits since last release:"
            extract_task_ids_from_commits
            ;;
        *)
            echo "AI DevOps Framework Version Manager"
            echo ""
            echo "Usage: $0 [action] [options]"
            echo ""
            echo "Actions:"
            echo "  get                           Get current version"
            echo "  bump [major|minor|patch]      Bump version"
            echo "  tag                           Create git tag for current version"
            echo "  github-release                Create GitHub release for current version"
            echo "  release [major|minor|patch]   Bump version, update files, create tag and GitHub release"
            echo "  validate                      Validate version consistency across all files"
            echo "  changelog-check               Check CHANGELOG.md has entry for current version"
            echo "  changelog-preview             Generate changelog entry from commits since last tag"
            echo "  auto-mark-tasks               Auto-mark tasks complete based on commit messages"
            echo "  list-task-ids                 List task IDs found in commits since last release"
            echo ""
            echo "Options:"
            echo "  --force                       Bypass changelog check (use with release)"
            echo "  --skip-preflight              Bypass quality checks (use with release)"
            echo ""
            echo "Examples:"
            echo "  $0 get"
            echo "  $0 bump minor"
            echo "  $0 release patch"
            echo "  $0 release minor --force"
            echo "  $0 release patch --skip-preflight"
            echo "  $0 release patch --force --skip-preflight"
            echo "  $0 github-release"
            echo "  $0 validate"
            echo "  $0 changelog-check"
            echo "  $0 changelog-preview"
            ;;
    esac
    return 0
}

main "$@"
