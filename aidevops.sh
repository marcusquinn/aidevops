#!/usr/bin/env bash

# AI DevOps Framework CLI
# Usage: aidevops <command> [options]
#
# Version: 2.105.6

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Paths
INSTALL_DIR="$HOME/Git/aidevops"
AGENTS_DIR="$HOME/.aidevops/agents"
CONFIG_DIR="$HOME/.config/aidevops"
REPOS_FILE="$CONFIG_DIR/repos.json"
# shellcheck disable=SC2034  # Used in fresh install fallback
REPO_URL="https://github.com/marcusquinn/aidevops.git"
VERSION_FILE="$INSTALL_DIR/VERSION"

# Portable sed in-place edit (macOS BSD sed vs GNU sed)
sed_inplace() { if [[ "$(uname)" == "Darwin" ]]; then sed -i '' "$@"; else sed -i "$@"; fi; }

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() { echo -e "${BOLD}${CYAN}$1${NC}"; }

# Get current version
get_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE"
    else
        echo "unknown"
    fi
}

# Get remote version
get_remote_version() {
    # Use GitHub API (not cached) instead of raw.githubusercontent.com (cached 5 min)
    local version
    if command -v jq &>/dev/null; then
        version=$(curl -fsSL "https://api.github.com/repos/marcusquinn/aidevops/contents/VERSION" 2>/dev/null | jq -r '.content // empty' 2>/dev/null | base64 -d 2>/dev/null | tr -d '\n')
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    fi
    # Fallback to raw (cached) if jq unavailable or API fails
    curl -fsSL "https://raw.githubusercontent.com/marcusquinn/aidevops/main/VERSION" 2>/dev/null || echo "unknown"
}

# Check if a command exists
check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Check if a directory exists
check_dir() {
    [[ -d "$1" ]]
}

# Check if a file exists
check_file() {
    [[ -f "$1" ]]
}

# Initialize repos.json if it doesn't exist
init_repos_file() {
    if [[ ! -f "$REPOS_FILE" ]]; then
        mkdir -p "$CONFIG_DIR"
        echo '{"initialized_repos": []}' > "$REPOS_FILE"
    fi
    return 0
}

# Register a repo in repos.json
# Usage: register_repo <path> <version> <features>
register_repo() {
    local repo_path="$1"
    local version="$2"
    local features="$3"
    
    init_repos_file
    
    # Normalize path (resolve symlinks, remove trailing slash)
    if ! repo_path=$(cd "$repo_path" 2>/dev/null && pwd -P); then
        print_warning "Cannot access path: $repo_path"
        return 1
    fi
    
    if ! command -v jq &>/dev/null; then
        print_warning "jq not installed - repo tracking disabled"
        return 0
    fi
    
    # Check if repo already registered
    if jq -e --arg path "$repo_path" '.initialized_repos[] | select(.path == $path)' "$REPOS_FILE" &>/dev/null; then
        # Update existing entry
        local temp_file="${REPOS_FILE}.tmp"
        jq --arg path "$repo_path" --arg version "$version" --arg features "$features" \
            '(.initialized_repos[] | select(.path == $path)) |= {path: $path, version: $version, features: ($features | split(",")), updated: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}' \
            "$REPOS_FILE" > "$temp_file" && mv "$temp_file" "$REPOS_FILE"
    else
        # Add new entry
        local temp_file="${REPOS_FILE}.tmp"
        jq --arg path "$repo_path" --arg version "$version" --arg features "$features" \
            '.initialized_repos += [{path: $path, version: $version, features: ($features | split(",")), initialized: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}]' \
            "$REPOS_FILE" > "$temp_file" && mv "$temp_file" "$REPOS_FILE"
    fi
    return 0
}

# Get list of registered repos
get_registered_repos() {
    init_repos_file
    
    if ! command -v jq &>/dev/null; then
        echo "[]"
        return 0
    fi
    
    jq -r '.initialized_repos[] | .path' "$REPOS_FILE" 2>/dev/null || echo ""
    return 0
}

# Check if a repo needs upgrade (version behind current)
check_repo_needs_upgrade() {
    local repo_path="$1"
    local current_version
    current_version=$(get_version)
    
    if ! command -v jq &>/dev/null; then
        return 1
    fi
    
    local repo_version
    repo_version=$(jq -r --arg path "$repo_path" '.initialized_repos[] | select(.path == $path) | .version' "$REPOS_FILE" 2>/dev/null)
    
    if [[ -z "$repo_version" || "$repo_version" == "null" ]]; then
        return 1
    fi
    
    # Compare versions (simple string comparison works for semver)
    if [[ "$repo_version" != "$current_version" ]]; then
        return 0  # needs upgrade
    fi
    return 1  # up to date
}

# Check if a planning file needs upgrading (version mismatch or missing TOON markers)
# Usage: check_planning_file_version <file> <template>
# Returns 0 if upgrade needed, 1 if up to date
check_planning_file_version() {
    local file="$1" template="$2"
    if [[ -f "$file" ]]; then
        if ! grep -q "TOON:meta" "$file" 2>/dev/null; then
            return 0
        fi
        local current_ver template_ver
        current_ver=$(grep -A1 "TOON:meta" "$file" 2>/dev/null | tail -1 | cut -d',' -f1)
        template_ver=$(grep -A1 "TOON:meta" "$template" 2>/dev/null | tail -1 | cut -d',' -f1)
        if [[ -n "$template_ver" ]] && [[ "$current_ver" != "$template_ver" ]]; then
            return 0
        fi
        return 1
    else
        # No file = no upgrade needed (init would create it)
        return 1
    fi
}

# Check if a repo's planning templates need upgrading
# Returns 0 if any planning file needs upgrade
check_planning_needs_upgrade() {
    local repo_path="$1"
    local todo_file="$repo_path/TODO.md"
    local plans_file="$repo_path/todo/PLANS.md"
    local todo_template="$AGENTS_DIR/templates/todo-template.md"
    local plans_template="$AGENTS_DIR/templates/plans-template.md"

    [[ ! -f "$todo_template" ]] && return 1

    if check_planning_file_version "$todo_file" "$todo_template"; then
        return 0
    fi
    if [[ -f "$plans_template" ]] && check_planning_file_version "$plans_file" "$plans_template"; then
        return 0
    fi
    return 1
}

# Detect if current directory has aidevops but isn't registered
detect_unregistered_repo() {
    local project_root
    
    # Check if in a git repo
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        return 1
    fi
    
    project_root=$(git rev-parse --show-toplevel 2>/dev/null)
    
    # Check for .aidevops.json
    if [[ ! -f "$project_root/.aidevops.json" ]]; then
        return 1
    fi
    
    init_repos_file
    
    if ! command -v jq &>/dev/null; then
        return 1
    fi
    
    # Check if already registered
    if jq -e --arg path "$project_root" '.initialized_repos[] | select(.path == $path)' "$REPOS_FILE" &>/dev/null; then
        return 1  # already registered
    fi
    
    # Not registered - return the path
    echo "$project_root"
    return 0
}

# Check if on protected branch and offer worktree creation
# Returns 0 if safe to proceed, 1 if user cancelled
# Sets WORKTREE_PATH if worktree was created
check_protected_branch() {
    local branch_type="${1:-chore}"
    local branch_suffix="${2:-aidevops-setup}"
    
    # Not in a git repo - skip check
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        return 0
    fi
    
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || echo "")
    
    # Not on a protected branch - safe to proceed
    if [[ ! "$current_branch" =~ ^(main|master)$ ]]; then
        return 0
    fi
    
    local project_root
    project_root=$(git rev-parse --show-toplevel)
    local repo_name
    repo_name=$(basename "$project_root")
    local suggested_branch="$branch_type/$branch_suffix"
    
    echo ""
    print_warning "On protected branch '$current_branch'"
    echo ""
    echo "Options:"
    echo "  1. Create worktree: $suggested_branch (recommended)"
    echo "  2. Continue on $current_branch (commits directly to main)"
    echo "  3. Cancel"
    echo ""
    local choice
    read -r -p "Choice [1]: " choice
    choice="${choice:-1}"
    
    case "$choice" in
        1)
            # Create worktree
            local worktree_dir
            worktree_dir="$(dirname "$project_root")/${repo_name}-${branch_type}-${branch_suffix}"
            
            print_info "Creating worktree at $worktree_dir..."
            
            if [[ -f "$AGENTS_DIR/scripts/worktree-helper.sh" ]]; then
                if bash "$AGENTS_DIR/scripts/worktree-helper.sh" add "$suggested_branch" 2>/dev/null; then
                    export WORKTREE_PATH="$worktree_dir"
                    echo ""
                    print_success "Worktree created!"
                    print_info "Switching to: $worktree_dir"
                    echo ""
                    # Change to worktree directory
                    cd "$worktree_dir" || return 1
                    return 0
                else
                    print_error "Failed to create worktree"
                    return 1
                fi
            else
                # Fallback without helper script
                if git worktree add -b "$suggested_branch" "$worktree_dir" 2>/dev/null; then
                    export WORKTREE_PATH="$worktree_dir"
                    echo ""
                    print_success "Worktree created!"
                    print_info "Switching to: $worktree_dir"
                    echo ""
                    cd "$worktree_dir" || return 1
                    return 0
                else
                    print_error "Failed to create worktree"
                    return 1
                fi
            fi
            ;;
        2)
            print_warning "Continuing on $current_branch - changes will commit directly"
            return 0
            ;;
        3|*)
            print_info "Cancelled"
            return 1
            ;;
    esac
}

# Status command - check all installations
cmd_status() {
    print_header "AI DevOps Framework Status"
    echo "=========================="
    echo ""
    
    local current_version
    current_version=$(get_version)
    local remote_version
    remote_version=$(get_remote_version)
    
    # Version info
    print_header "Version"
    echo "  Installed: $current_version"
    echo "  Latest:    $remote_version"
    if [[ "$current_version" != "$remote_version" && "$remote_version" != "unknown" ]]; then
        print_warning "Update available! Run: aidevops update"
    elif [[ "$current_version" == "$remote_version" ]]; then
        print_success "Up to date"
    fi
    echo ""
    
    # Installation paths
    print_header "Installation"
    if check_dir "$INSTALL_DIR"; then
        print_success "Repository: $INSTALL_DIR"
    else
        print_error "Repository: Not found at $INSTALL_DIR"
    fi
    
    if check_dir "$AGENTS_DIR"; then
        local agent_count
        agent_count=$(find "$AGENTS_DIR" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
        print_success "Agents: $AGENTS_DIR ($agent_count files)"
    else
        print_error "Agents: Not deployed"
    fi
    echo ""
    
    # Required dependencies
    print_header "Required Dependencies"
    for cmd in git curl jq ssh; do
        if check_cmd "$cmd"; then
            print_success "$cmd"
        else
            print_error "$cmd - not installed"
        fi
    done
    echo ""
    
    # Optional dependencies
    print_header "Optional Dependencies"
    if check_cmd sshpass; then
        print_success "sshpass"
    else
        print_warning "sshpass - not installed (needed for password SSH)"
    fi
    echo ""
    
    # Recommended tools
    print_header "Recommended Tools"
    
    # Tabby
    if [[ "$(uname)" == "Darwin" ]]; then
        if check_dir "/Applications/Tabby.app"; then
            print_success "Tabby terminal"
        else
            print_warning "Tabby terminal - not installed"
        fi
    else
        if check_cmd tabby; then
            print_success "Tabby terminal"
        else
            print_warning "Tabby terminal - not installed"
        fi
    fi
    
    # Zed
    if [[ "$(uname)" == "Darwin" ]]; then
        if check_dir "/Applications/Zed.app"; then
            print_success "Zed editor"
            # Check OpenCode extension
            if check_dir "$HOME/Library/Application Support/Zed/extensions/installed/opencode"; then
                print_success "  └─ OpenCode extension"
            else
                print_warning "  └─ OpenCode extension - not installed"
            fi
        else
            print_warning "Zed editor - not installed"
        fi
    else
        if check_cmd zed; then
            print_success "Zed editor"
            if check_dir "$HOME/.local/share/zed/extensions/installed/opencode"; then
                print_success "  └─ OpenCode extension"
            else
                print_warning "  └─ OpenCode extension - not installed"
            fi
        else
            print_warning "Zed editor - not installed"
        fi
    fi
    echo ""
    
    # Git CLI tools
    print_header "Git CLI Tools"
    if check_cmd gh; then
        print_success "GitHub CLI (gh)"
    else
        print_warning "GitHub CLI (gh) - not installed"
    fi
    
    if check_cmd glab; then
        print_success "GitLab CLI (glab)"
    else
        print_warning "GitLab CLI (glab) - not installed"
    fi
    
    if check_cmd tea; then
        print_success "Gitea CLI (tea)"
    else
        print_warning "Gitea CLI (tea) - not installed"
    fi
    echo ""
    
    # AI Tools
    print_header "AI Tools & MCPs"
    
    if check_cmd opencode; then
        print_success "OpenCode CLI"
    else
        print_warning "OpenCode CLI - not installed"
    fi
    
    if check_cmd auggie; then
        if check_file "$HOME/.augment/session.json"; then
            print_success "Augment Context Engine (authenticated)"
        else
            print_warning "Augment Context Engine (not authenticated)"
        fi
    else
        print_warning "Augment Context Engine - not installed"
    fi
    
    if check_cmd osgrep; then
        print_success "osgrep (local semantic search)"
    else
        print_warning "osgrep - not installed"
    fi
    
    if check_cmd bd; then
        print_success "Beads CLI (task graph)"
    else
        print_warning "Beads CLI (bd) - not installed"
    fi
    echo ""
    
    # Python/Node environments
    print_header "Development Environments"
    
    if check_dir "$INSTALL_DIR/python-env/dspy-env"; then
        print_success "DSPy Python environment"
    else
        print_warning "DSPy Python environment - not created"
    fi
    
    if check_cmd dspyground; then
        print_success "DSPyGround"
    else
        print_warning "DSPyGround - not installed"
    fi
    echo ""
    
    # AI Assistant configs
    print_header "AI Assistant Configurations"
    
    local ai_configs=(
        "$HOME/.config/opencode/opencode.json:OpenCode"
        "$HOME/.claude/commands:Claude Code CLI"
        "$HOME/CLAUDE.md:Claude Code memory"
    )
    
    for config in "${ai_configs[@]}"; do
        local path="${config%%:*}"
        local name="${config##*:}"
        if [[ -e "$path" ]]; then
            print_success "$name"
        else
            print_warning "$name - not configured"
        fi
    done
    echo ""
    
    # SSH key
    print_header "SSH Configuration"
    if check_file "$HOME/.ssh/id_ed25519"; then
        print_success "Ed25519 SSH key"
    else
        print_warning "Ed25519 SSH key - not found"
    fi
    echo ""
}

# Update/upgrade command
cmd_update() {
    print_header "Updating AI DevOps Framework"
    echo ""
    
    local current_version
    current_version=$(get_version)
    
    print_info "Current version: $current_version"
    print_info "Fetching latest version..."
    
    if check_dir "$INSTALL_DIR/.git"; then
        cd "$INSTALL_DIR" || exit 1
        
        # Fetch and check for updates
        git fetch origin main --quiet
        
        local local_hash
        local_hash=$(git rev-parse HEAD)
        local remote_hash
        remote_hash=$(git rev-parse origin/main)
        
        if [[ "$local_hash" == "$remote_hash" ]]; then
            print_success "Framework already up to date!"
            
            # Even when repo is current, deployed agents may be stale
            # (e.g., previous setup.sh was interrupted or failed)
            local repo_version deployed_version
            repo_version=$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo "unknown")
            deployed_version=$(cat "$HOME/.aidevops/agents/VERSION" 2>/dev/null || echo "none")
            if [[ "$repo_version" != "$deployed_version" ]]; then
                print_warning "Deployed agents ($deployed_version) don't match repo ($repo_version)"
                print_info "Re-running setup to sync agents..."
                bash "$INSTALL_DIR/setup.sh" --non-interactive
            fi
        else
            print_info "Pulling latest changes..."
            local old_hash
            old_hash=$(git rev-parse HEAD)
            
            if git pull --ff-only origin main --quiet; then
                local new_version new_hash
                new_version=$(get_version)
                new_hash=$(git rev-parse HEAD)
                print_success "Updated to version $new_version"
                
                # Print bounded summary of meaningful changes
                if [[ "$old_hash" != "$new_hash" ]]; then
                    local total_commits
                    total_commits=$(git rev-list --count "$old_hash..$new_hash")
                    echo ""
                    print_info "Changes since $current_version ($total_commits commits):"
                    git log --oneline "$old_hash..$new_hash" \
                        | grep -E '^[a-f0-9]+ (feat|fix|refactor|perf|docs):' \
                        | head -20
                    if [[ "$total_commits" -gt 20 ]]; then
                        echo "  ... and more (run 'git log --oneline' in $INSTALL_DIR for full list)"
                    fi
                fi
                
                echo ""
                print_info "Running setup to apply changes..."
                bash "$INSTALL_DIR/setup.sh" --non-interactive
            else
                print_error "Failed to pull updates"
                print_info "Try: cd $INSTALL_DIR && git pull"
                return 1
            fi
        fi
    else
        print_warning "Repository not found, performing fresh install..."
        # Download setup script to temp file first (not piped to shell)
        local tmp_setup
        tmp_setup=$(mktemp "${TMPDIR:-/tmp}/aidevops-setup-XXXXXX.sh") || {
            print_error "Failed to create temp file for setup script"
            return 1
        }
        if curl -fsSL "https://raw.githubusercontent.com/marcusquinn/aidevops/main/setup.sh" -o "$tmp_setup" 2>/dev/null && [[ -s "$tmp_setup" ]]; then
            chmod +x "$tmp_setup"
            bash "$tmp_setup"
            local setup_exit=$?
            rm -f "$tmp_setup"
            [[ $setup_exit -ne 0 ]] && return 1
        else
            rm -f "$tmp_setup"
            print_error "Failed to download setup script"
            print_info "Try: git clone https://github.com/marcusquinn/aidevops.git $INSTALL_DIR && bash $INSTALL_DIR/setup.sh"
            return 1
        fi
    fi
    
    # Check registered repos for updates
    echo ""
    print_header "Checking Initialized Projects"
    
    local repos_needing_upgrade=()
    local current_ver
    current_ver=$(get_version)
    
    while IFS= read -r repo_path; do
        [[ -z "$repo_path" ]] && continue
        
        if [[ -d "$repo_path" ]]; then
            if check_repo_needs_upgrade "$repo_path"; then
                repos_needing_upgrade+=("$repo_path")
            fi
        fi
    done < <(get_registered_repos)
    
    if [[ ${#repos_needing_upgrade[@]} -eq 0 ]]; then
        print_success "All registered projects are up to date"
    else
        echo ""
        print_warning "${#repos_needing_upgrade[@]} project(s) may need updates:"
        for repo in "${repos_needing_upgrade[@]}"; do
            local repo_name
            repo_name=$(basename "$repo")
            echo "  - $repo_name ($repo)"
        done
        echo ""
        read -r -p "Update .aidevops.json version in these projects? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            for repo in "${repos_needing_upgrade[@]}"; do
                if [[ -f "$repo/.aidevops.json" ]]; then
                    print_info "Updating $repo..."
                    # Update version in .aidevops.json
                    if command -v jq &>/dev/null; then
                        local temp_file="${repo}/.aidevops.json.tmp"
                        jq --arg version "$current_ver" '.version = $version' "$repo/.aidevops.json" > "$temp_file" && \
                            mv "$temp_file" "$repo/.aidevops.json"
                        
                        # Update repos.json entry
                        local features
                        features=$(jq -r '[.features | to_entries[] | select(.value == true) | .key] | join(",")' "$repo/.aidevops.json" 2>/dev/null || echo "")
                        register_repo "$repo" "$current_ver" "$features"
                        
                         print_success "Updated $(basename "$repo")"
                    else
                        print_warning "jq not installed - manual update needed for $repo"
                    fi
                fi
            done
        fi
    fi
    
    # Check planning templates in registered repos
    echo ""
    print_header "Checking Planning Templates"
    
    local repos_needing_planning=()
    while IFS= read -r repo_path; do
        [[ -z "$repo_path" ]] && continue
        [[ ! -d "$repo_path" ]] && continue
        # Only check repos with planning enabled
        if [[ -f "$repo_path/.aidevops.json" ]]; then
            local has_planning
            has_planning=$(grep -o '"planning": *true' "$repo_path/.aidevops.json" 2>/dev/null || true)
            if [[ -n "$has_planning" ]] && check_planning_needs_upgrade "$repo_path"; then
                repos_needing_planning+=("$repo_path")
            fi
        fi
    done < <(get_registered_repos)
    
    if [[ ${#repos_needing_planning[@]} -eq 0 ]]; then
        print_success "All planning templates are up to date"
    else
        echo ""
        print_warning "${#repos_needing_planning[@]} project(s) have outdated planning templates:"
        for repo in "${repos_needing_planning[@]}"; do
            local repo_name
            repo_name=$(basename "$repo")
            local todo_ver
            todo_ver=$(grep -A1 "TOON:meta" "$repo/TODO.md" 2>/dev/null | tail -1 | cut -d',' -f1)
            echo "  - $repo_name (v${todo_ver:-none})"
        done
        local template_ver
        template_ver=$(grep -A1 "TOON:meta" "$AGENTS_DIR/templates/todo-template.md" 2>/dev/null | tail -1 | cut -d',' -f1)
        echo ""
        echo "  Latest template: v${template_ver} (adds risk field, active session time estimates)"
        echo ""
        read -r -p "Upgrade planning templates in these projects? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            for repo in "${repos_needing_planning[@]}"; do
                print_info "Upgrading $(basename "$repo")..."
                # Run upgrade-planning in the repo context
                (cd "$repo" && cmd_upgrade_planning --force) || print_warning "Failed to upgrade $(basename "$repo")"
            done
        else
            print_info "Run 'aidevops upgrade-planning' in each project to upgrade manually"
        fi
    fi
}

# Uninstall command
cmd_uninstall() {
    print_header "Uninstall AI DevOps Framework"
    echo ""
    
    print_warning "This will remove:"
    echo "  - $AGENTS_DIR (deployed agents)"
    echo "  - $INSTALL_DIR (repository)"
    echo "  - AI assistant configuration references"
    echo "  - Shell aliases (if added)"
    echo ""
    print_warning "This will NOT remove:"
    echo "  - Installed tools (Tabby, Zed, gh, glab, etc.)"
    echo "  - SSH keys"
    echo "  - Python/Node environments"
    echo ""
    
    read -r -p "Are you sure you want to uninstall? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        print_info "Uninstall cancelled"
        return 0
    fi
    
    echo ""
    
    # Remove agents directory
    if check_dir "$AGENTS_DIR"; then
        print_info "Removing $AGENTS_DIR..."
        rm -rf "$AGENTS_DIR"
        print_success "Removed agents directory"
    fi
    
    # Remove config backups
    if check_dir "$HOME/.aidevops"; then
        print_info "Removing $HOME/.aidevops..."
        rm -rf "$HOME/.aidevops"
        print_success "Removed aidevops config directory"
    fi
    
    # Remove AI assistant references
    print_info "Removing AI assistant configuration references..."
    
    local ai_agent_files=(
        "$HOME/.config/opencode/agent/AGENTS.md"
        "$HOME/.claude/commands/AGENTS.md"
        "$HOME/.opencode/AGENTS.md"
    )
    
    for file in "${ai_agent_files[@]}"; do
        if check_file "$file"; then
            # Check if it only contains our reference
            if grep -q "Add ~/.aidevops/agents/AGENTS.md" "$file" 2>/dev/null; then
                rm -f "$file"
                print_success "Removed $file"
            fi
        fi
    done
    
    # Remove shell aliases
    print_info "Removing shell aliases..."
    for rc_file in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
        if check_file "$rc_file"; then
            if grep -q "# AI Assistant Server Access Framework" "$rc_file" 2>/dev/null; then
                # Create backup
                cp "$rc_file" "$rc_file.bak"
                # Remove our alias block (from comment to empty line)
                sed_inplace '/# AI Assistant Server Access Framework/,/^$/d' "$rc_file"
                print_success "Removed aliases from $rc_file"
            fi
        fi
    done
    
    # Remove memory files
    print_info "Removing AI memory files..."
    local memory_files=(
        "$HOME/CLAUDE.md"
    )
    
    for file in "${memory_files[@]}"; do
        if check_file "$file"; then
            rm -f "$file"
            print_success "Removed $file"
        fi
    done
    
    # Remove repository (ask separately)
    echo ""
    read -r -p "Also remove the repository at $INSTALL_DIR? (yes/no): " remove_repo
    
    if [[ "$remove_repo" == "yes" ]]; then
        if check_dir "$INSTALL_DIR"; then
            print_info "Removing $INSTALL_DIR..."
            rm -rf "$INSTALL_DIR"
            print_success "Removed repository"
        fi
    else
        print_info "Keeping repository at $INSTALL_DIR"
    fi
    
    echo ""
    print_success "Uninstall complete!"
    print_info "To reinstall, run:"
    echo "  npm install -g aidevops && aidevops update"
    echo "  OR: brew install marcusquinn/tap/aidevops && aidevops update"
}

# Init command - initialize aidevops in a project
cmd_init() {
    local features="${1:-all}"
    
    print_header "Initialize AI DevOps in Project"
    echo ""
    
    # Check if we're in a git repo
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        print_error "Not in a git repository"
        print_info "Run 'git init' first or navigate to a git repository"
        return 1
    fi
    
    # Check for protected branch and offer worktree
    if ! check_protected_branch "chore" "aidevops-init"; then
        return 1
    fi
    
    local project_root
    project_root=$(git rev-parse --show-toplevel)
    print_info "Project root: $project_root"
    echo ""
    
    # Parse features
    local enable_planning=false
    local enable_git_workflow=false
    local enable_code_quality=false
    local enable_time_tracking=false
    local enable_database=false
    local enable_beads=false
    
    case "$features" in
        all)
            enable_planning=true
            enable_git_workflow=true
            enable_code_quality=true
            enable_time_tracking=true
            enable_database=true
            enable_beads=true
            ;;
        planning)
            enable_planning=true
            ;;
        git-workflow)
            enable_git_workflow=true
            ;;
        code-quality)
            enable_code_quality=true
            ;;
        time-tracking)
            enable_time_tracking=true
            enable_planning=true  # time-tracking requires planning
            ;;
        database)
            enable_database=true
            ;;
        beads)
            enable_beads=true
            enable_planning=true  # beads requires planning
            ;;
        *)
            # Comma-separated list
            IFS=',' read -ra FEATURE_LIST <<< "$features"
            for feature in "${FEATURE_LIST[@]}"; do
                case "$feature" in
                    planning) enable_planning=true ;;
                    git-workflow) enable_git_workflow=true ;;
                    code-quality) enable_code_quality=true ;;
                    time-tracking) 
                        enable_time_tracking=true
                        enable_planning=true
                        ;;
                    database) enable_database=true ;;
                    beads)
                        enable_beads=true
                        enable_planning=true
                        ;;
                esac
            done
            ;;
    esac
    
    # Create .aidevops.json config
    local config_file="$project_root/.aidevops.json"
    local aidevops_version
    aidevops_version=$(get_version)
    
    print_info "Creating .aidevops.json..."
    cat > "$config_file" << EOF
{
  "version": "$aidevops_version",
  "initialized": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "features": {
    "planning": $enable_planning,
    "git_workflow": $enable_git_workflow,
    "code_quality": $enable_code_quality,
    "time_tracking": $enable_time_tracking,
    "database": $enable_database,
    "beads": $enable_beads
  },
  "time_tracking": {
    "enabled": $enable_time_tracking,
    "prompt_on_commit": true,
    "auto_record_branch_start": true
  },
  "database": {
    "enabled": $enable_database,
    "schema_path": "schemas",
    "migrations_path": "migrations",
    "seeds_path": "seeds",
    "auto_generate_migration": true
  },
  "beads": {
    "enabled": $enable_beads,
    "sync_on_commit": false,
    "auto_ready_check": true
  }
}
EOF
    print_success "Created .aidevops.json"
    
    # Create .agents symlink (or migrate from legacy .agent)
    if [[ -L "$project_root/.agent" || -d "$project_root/.agent" ]]; then
        # Migrate legacy .agent symlink to .agents
        rm -f "$project_root/.agent"
        ln -s "$AGENTS_DIR" "$project_root/.agents"
        print_success "Migrated .agent -> .agents symlink"
    elif [[ ! -e "$project_root/.agents" ]]; then
        print_info "Creating .agents symlink..."
        ln -s "$AGENTS_DIR" "$project_root/.agents"
        print_success "Created .agents -> $AGENTS_DIR"
    else
        print_warning ".agents already exists, skipping symlink"
    fi
    
    # Create planning files if enabled
    if [[ "$enable_planning" == "true" ]]; then
        print_info "Setting up planning files..."
        
        # Create TODO.md from template
        if [[ ! -f "$project_root/TODO.md" ]]; then
            if [[ -f "$AGENTS_DIR/templates/todo-template.md" ]]; then
                cp "$AGENTS_DIR/templates/todo-template.md" "$project_root/TODO.md"
                print_success "Created TODO.md"
            else
                # Fallback minimal template
                cat > "$project_root/TODO.md" << 'EOF'
# TODO

## In Progress

<!-- Tasks currently being worked on -->

## Backlog

<!-- Prioritized list of upcoming tasks -->

---

*Format: `- [ ] Task description @owner #tag ~estimate`*
*Time tracking: `started:`, `completed:`, `actual:`*
EOF
                print_success "Created TODO.md (minimal template)"
            fi
        else
            print_warning "TODO.md already exists, skipping"
        fi
        
        # Create todo/ directory and PLANS.md
        mkdir -p "$project_root/todo/tasks"
        
        if [[ ! -f "$project_root/todo/PLANS.md" ]]; then
            if [[ -f "$AGENTS_DIR/templates/plans-template.md" ]]; then
                cp "$AGENTS_DIR/templates/plans-template.md" "$project_root/todo/PLANS.md"
                print_success "Created todo/PLANS.md"
            else
                # Fallback minimal template
                cat > "$project_root/todo/PLANS.md" << 'EOF'
# Execution Plans

Complex, multi-session work that requires detailed planning.

## Active Plans

<!-- Plans currently in progress -->

## Completed Plans

<!-- Archived completed plans -->

---

*See `.agents/workflows/plans.md` for planning workflow*
EOF
                print_success "Created todo/PLANS.md (minimal template)"
            fi
        else
            print_warning "todo/PLANS.md already exists, skipping"
        fi
        
        # Create .gitkeep in tasks
        touch "$project_root/todo/tasks/.gitkeep"
    fi
    
    # Create database directories if enabled
    if [[ "$enable_database" == "true" ]]; then
        print_info "Setting up database schema directories..."
        
        # Create schemas directory with AGENTS.md
        if [[ ! -d "$project_root/schemas" ]]; then
            mkdir -p "$project_root/schemas"
            cat > "$project_root/schemas/AGENTS.md" << 'EOF'
# Database Schemas

Declarative schema files - source of truth for database structure.

See: `@sql-migrations` or `.agents/workflows/sql-migrations.md`
EOF
            print_success "Created schemas/ directory"
        else
            print_warning "schemas/ already exists, skipping"
        fi
        
        # Create migrations directory with AGENTS.md
        if [[ ! -d "$project_root/migrations" ]]; then
            mkdir -p "$project_root/migrations"
            cat > "$project_root/migrations/AGENTS.md" << 'EOF'
# Database Migrations

Auto-generated versioned migration files. Do not edit manually.

See: `@sql-migrations` or `.agents/workflows/sql-migrations.md`
EOF
            print_success "Created migrations/ directory"
        else
            print_warning "migrations/ already exists, skipping"
        fi
        
        # Create seeds directory with AGENTS.md
        if [[ ! -d "$project_root/seeds" ]]; then
            mkdir -p "$project_root/seeds"
            cat > "$project_root/seeds/AGENTS.md" << 'EOF'
# Database Seeds

Initial and reference data (roles, statuses, test accounts).

See: `@sql-migrations` or `.agents/workflows/sql-migrations.md`
EOF
            print_success "Created seeds/ directory"
        else
            print_warning "seeds/ already exists, skipping"
        fi
    fi
    
    # Initialize Beads if enabled
    if [[ "$enable_beads" == "true" ]]; then
        print_info "Setting up Beads task graph..."
        
        # Check if Beads CLI is installed
        if ! command -v bd &> /dev/null; then
            print_warning "Beads CLI (bd) not installed"
            echo "  Install with: brew install steveyegge/beads/bd"
            echo "  Or: go install github.com/steveyegge/beads/cmd/bd@latest"
        else
            # Initialize Beads in the project
            if [[ ! -d "$project_root/.beads" ]]; then
                print_info "Initializing Beads database..."
                if (cd "$project_root" && bd init 2>/dev/null); then
                    print_success "Beads initialized"
                else
                    print_warning "Beads init failed - run manually: bd init"
                fi
            else
                print_info "Beads already initialized"
            fi
            
            # Run initial sync from TODO.md/PLANS.md
            if [[ -f "$AGENTS_DIR/scripts/beads-sync-helper.sh" ]]; then
                print_info "Syncing tasks to Beads..."
                if bash "$AGENTS_DIR/scripts/beads-sync-helper.sh" push "$project_root" 2>/dev/null; then
                    print_success "Tasks synced to Beads"
                else
                    print_warning "Beads sync failed - run manually: beads-sync-helper.sh push"
                fi
            fi
        fi
    fi
    
    # Add to .gitignore if needed
    local gitignore="$project_root/.gitignore"
    if [[ -f "$gitignore" ]]; then
        if ! grep -q "^\.agents$" "$gitignore" 2>/dev/null; then
            {
                echo ""
                echo "# aidevops"
                echo ".agents"
            } >> "$gitignore"
            print_success "Added .agents to .gitignore"
            # Also add legacy .agent for backward compatibility
            if ! grep -q "^\.agent$" "$gitignore" 2>/dev/null; then
                echo ".agent" >> "$gitignore"
            fi
        fi
        # Add .beads if beads is enabled
        if [[ "$enable_beads" == "true" ]]; then
            if ! grep -q "^\.beads$" "$gitignore" 2>/dev/null; then
                echo ".beads" >> "$gitignore"
                print_success "Added .beads to .gitignore"
            fi
        fi
    fi
    
    # Generate collaborator pointer files (lightweight AGENTS.md references)
    local pointer_content="Read AGENTS.md for all project context and instructions."
    local pointer_files=(".cursorrules" ".windsurfrules" ".clinerules" ".github/copilot-instructions.md")
    local pointer_created=0
    for pf in "${pointer_files[@]}"; do
        local pf_path="$project_root/$pf"
        if [[ ! -f "$pf_path" ]]; then
            mkdir -p "$(dirname "$pf_path")"
            echo "$pointer_content" > "$pf_path"
            ((pointer_created++))
        fi
    done
    if [[ $pointer_created -gt 0 ]]; then
        print_success "Created $pointer_created collaborator pointer file(s) (.cursorrules, etc.)"
    else
        print_info "Collaborator pointer files already exist"
    fi
    
    # Build features string for registration
    local features_list=""
    [[ "$enable_planning" == "true" ]] && features_list="${features_list}planning,"
    [[ "$enable_git_workflow" == "true" ]] && features_list="${features_list}git-workflow,"
    [[ "$enable_code_quality" == "true" ]] && features_list="${features_list}code-quality,"
    [[ "$enable_time_tracking" == "true" ]] && features_list="${features_list}time-tracking,"
    [[ "$enable_database" == "true" ]] && features_list="${features_list}database,"
    [[ "$enable_beads" == "true" ]] && features_list="${features_list}beads,"
    features_list="${features_list%,}"  # Remove trailing comma
    
    # Register repo in repos.json
    register_repo "$project_root" "$aidevops_version" "$features_list"
    
    echo ""
    print_success "AI DevOps initialized!"
    echo ""
    echo "Enabled features:"
    [[ "$enable_planning" == "true" ]] && echo "  ✓ Planning (TODO.md, PLANS.md)"
    [[ "$enable_git_workflow" == "true" ]] && echo "  ✓ Git workflow (branch management)"
    [[ "$enable_code_quality" == "true" ]] && echo "  ✓ Code quality (linting, auditing)"
    [[ "$enable_time_tracking" == "true" ]] && echo "  ✓ Time tracking (estimates, actuals)"
    [[ "$enable_database" == "true" ]] && echo "  ✓ Database (schemas/, migrations/, seeds/)"
    [[ "$enable_beads" == "true" ]] && echo "  ✓ Beads (task graph visualization)"
    echo ""
    echo "Next steps:"
    if [[ "$enable_beads" == "true" ]]; then
        echo "  1. Add tasks to TODO.md with dependencies (blocked-by:t001)"
        echo "  2. Run /ready to see unblocked tasks"
        echo "  3. Run /sync-beads to sync with Beads graph"
        echo "  4. Use 'bd' CLI for graph visualization"
    elif [[ "$enable_database" == "true" ]]; then
        echo "  1. Add schema files to schemas/"
        echo "  2. Run diff to generate migrations"
        echo "  3. See .agents/workflows/sql-migrations.md"
    else
        echo "  1. Add tasks to TODO.md"
        echo "  2. Use /create-prd for complex features"
        echo "  3. Use /feature to start development"
    fi
}

# Upgrade planning command - upgrade TODO.md and PLANS.md to latest templates
cmd_upgrade_planning() {
    local force=false
    local backup=true
    local dry_run=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force=true; shift ;;
            --no-backup) backup=false; shift ;;
            --dry-run|-n) dry_run=true; shift ;;
            *) shift ;;
        esac
    done
    
    print_header "Upgrade Planning Files"
    echo ""
    
    # Check if in a git repo
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        print_error "Not in a git repository"
        return 1
    fi
    
    # Check for protected branch and offer worktree (skip for dry-run)
    if [[ "$dry_run" != "true" ]]; then
        if ! check_protected_branch "chore" "upgrade-planning"; then
            return 1
        fi
    fi
    
    local project_root
    project_root=$(git rev-parse --show-toplevel)
    
    # Check if aidevops is initialized
    if [[ ! -f "$project_root/.aidevops.json" ]]; then
        print_error "aidevops not initialized in this project"
        print_info "Run 'aidevops init' first"
        return 1
    fi
    
    # Check if planning is enabled (use jq if available, fallback to grep)
    if command -v jq &>/dev/null; then
        if ! jq -e '.features.planning == true' "$project_root/.aidevops.json" &>/dev/null; then
            print_error "Planning feature not enabled"
            print_info "Run 'aidevops init planning' to enable"
            return 1
        fi
    else
        local planning_enabled
        planning_enabled=$(grep -o '"planning": *true' "$project_root/.aidevops.json" 2>/dev/null || echo "")
        if [[ -z "$planning_enabled" ]]; then
            print_error "Planning feature not enabled"
            print_info "Run 'aidevops init planning' to enable"
            return 1
        fi
    fi
    
    local todo_file="$project_root/TODO.md"
    local plans_file="$project_root/todo/PLANS.md"
    local todo_template="$AGENTS_DIR/templates/todo-template.md"
    local plans_template="$AGENTS_DIR/templates/plans-template.md"
    
    # Check templates exist
    if [[ ! -f "$todo_template" ]]; then
        print_error "TODO template not found: $todo_template"
        return 1
    fi
    if [[ ! -f "$plans_template" ]]; then
        print_error "PLANS template not found: $plans_template"
        return 1
    fi
    
    local needs_upgrade=false
    local todo_needs_upgrade=false
    local plans_needs_upgrade=false
    
    # Check TODO.md
    if check_planning_file_version "$todo_file" "$todo_template"; then
        if [[ -f "$todo_file" ]]; then
            if ! grep -q "TOON:meta" "$todo_file" 2>/dev/null; then
                print_warning "TODO.md uses minimal template (missing TOON markers)"
            else
                local current_ver template_ver
                current_ver=$(grep -A1 "TOON:meta" "$todo_file" 2>/dev/null | tail -1 | cut -d',' -f1)
                template_ver=$(grep -A1 "TOON:meta" "$todo_template" 2>/dev/null | tail -1 | cut -d',' -f1)
                print_warning "TODO.md format version $current_ver -> $template_ver (adds risk field, updated estimates)"
            fi
        else
            print_info "TODO.md not found - will create from template"
        fi
        todo_needs_upgrade=true
        needs_upgrade=true
    else
        local current_ver
        current_ver=$(grep -A1 "TOON:meta" "$todo_file" 2>/dev/null | tail -1 | cut -d',' -f1)
        print_success "TODO.md already up to date (v${current_ver})"
    fi
    
    # Check PLANS.md
    if check_planning_file_version "$plans_file" "$plans_template"; then
        if [[ -f "$plans_file" ]]; then
            if ! grep -q "TOON:meta" "$plans_file" 2>/dev/null; then
                print_warning "todo/PLANS.md uses minimal template (missing TOON markers)"
            else
                local current_plans_ver template_plans_ver
                current_plans_ver=$(grep -A1 "TOON:meta" "$plans_file" 2>/dev/null | tail -1 | cut -d',' -f1)
                template_plans_ver=$(grep -A1 "TOON:meta" "$plans_template" 2>/dev/null | tail -1 | cut -d',' -f1)
                print_warning "todo/PLANS.md format version $current_plans_ver -> $template_plans_ver"
            fi
        else
            print_info "todo/PLANS.md not found - will create from template"
        fi
        plans_needs_upgrade=true
        needs_upgrade=true
    else
        local current_plans_ver
        current_plans_ver=$(grep -A1 "TOON:meta" "$plans_file" 2>/dev/null | tail -1 | cut -d',' -f1)
        print_success "todo/PLANS.md already up to date (v${current_plans_ver})"
    fi
    
    if [[ "$needs_upgrade" == "false" ]]; then
        echo ""
        print_success "Planning files are up to date!"
        return 0
    fi
    
    echo ""
    
    if [[ "$dry_run" == "true" ]]; then
        print_info "Dry run - no changes will be made"
        echo ""
        [[ "$todo_needs_upgrade" == "true" ]] && echo "  Would upgrade: TODO.md"
        [[ "$plans_needs_upgrade" == "true" ]] && echo "  Would upgrade: todo/PLANS.md"
        return 0
    fi
    
    # Confirm upgrade unless forced
    if [[ "$force" == "false" ]]; then
        echo "Files to upgrade:"
        [[ "$todo_needs_upgrade" == "true" ]] && echo "  - TODO.md"
        [[ "$plans_needs_upgrade" == "true" ]] && echo "  - todo/PLANS.md"
        echo ""
        echo "This will:"
        echo "  1. Extract existing tasks from current files"
        echo "  2. Create backups (.bak files)"
        echo "  3. Apply new TOON-enhanced templates"
        echo "  4. Merge existing tasks into new structure"
        echo ""
        read -r -p "Continue? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            print_info "Upgrade cancelled"
            return 0
        fi
    fi
    
    echo ""
    
    # Upgrade TODO.md
    if [[ "$todo_needs_upgrade" == "true" ]]; then
        print_info "Upgrading TODO.md..."
        
        # Extract existing tasks if file exists
        local existing_tasks=""
        if [[ -f "$todo_file" ]]; then
            # Extract task lines (lines starting with - [ ] or - [x] or - [-])
            existing_tasks=$(grep -E "^[[:space:]]*- \[([ x-])\]" "$todo_file" 2>/dev/null || echo "")
            
            # Create backup
            if [[ "$backup" == "true" ]]; then
                cp "$todo_file" "${todo_file}.bak"
                print_success "Backup created: TODO.md.bak"
            fi
        fi
        
        # Copy template (strip YAML frontmatter - lines between first two ---)
        # Use temp file to avoid race condition on failure
        local temp_todo="${todo_file}.new"
        if awk '/^---$/ && !p {c++; if(c==2) p=1; next} p' "$todo_template" > "$temp_todo" 2>/dev/null && [[ -s "$temp_todo" ]]; then
            mv "$temp_todo" "$todo_file"
        else
            rm -f "$temp_todo"
            cp "$todo_template" "$todo_file"
        fi
        
        # Update date placeholder
        sed_inplace "s/{{DATE}}/$(date +%Y-%m-%d)/" "$todo_file" 2>/dev/null || true
        
        # Merge existing tasks into Backlog section (after the TOON block closing tag)
        if [[ -n "$existing_tasks" ]]; then
            # Find the Backlog TOON block and insert tasks after its closing -->
            if grep -q "<!--TOON:backlog" "$todo_file"; then
                local temp_file="${todo_file}.merge"
                local tasks_file
                tasks_file=$(mktemp)
                printf '%s\n' "$existing_tasks" > "$tasks_file"
                # Use while-read to avoid BSD awk "newline in string" warning with -v
                local in_backlog=false
                while IFS= read -r line || [[ -n "$line" ]]; do
                    if [[ "$line" == *"<!--TOON:backlog"* ]]; then
                        in_backlog=true
                    fi
                    if [[ "$in_backlog" == true && "$line" == "-->" ]]; then
                        echo "$line"
                        echo ""
                        cat "$tasks_file"
                        in_backlog=false
                        continue
                    fi
                    echo "$line"
                done < "$todo_file" > "$temp_file"
                rm -f "$tasks_file"
                mv "$temp_file" "$todo_file"
                print_success "Merged existing tasks into Backlog"
            fi
        fi
        
        print_success "TODO.md upgraded to TOON-enhanced template"
    fi
    
    # Upgrade PLANS.md
    if [[ "$plans_needs_upgrade" == "true" ]]; then
        print_info "Upgrading todo/PLANS.md..."
        
        # Ensure directory exists
        mkdir -p "$project_root/todo/tasks"
        
        # Extract existing plans if file exists
        local existing_plans=""
        if [[ -f "$plans_file" ]]; then
            # Extract plan sections (### headers and their content)
            existing_plans=$(awk '/^### /{found=1} found{print}' "$plans_file" 2>/dev/null || echo "")
            
            # Create backup
            if [[ "$backup" == "true" ]]; then
                cp "$plans_file" "${plans_file}.bak"
                print_success "Backup created: todo/PLANS.md.bak"
            fi
        fi
        
        # Copy template (strip YAML frontmatter - lines between first two ---)
        # Use temp file to avoid race condition on failure
        local temp_plans="${plans_file}.new"
        if awk '/^---$/ && !p {c++; if(c==2) p=1; next} p' "$plans_template" > "$temp_plans" 2>/dev/null && [[ -s "$temp_plans" ]]; then
            mv "$temp_plans" "$plans_file"
        else
            rm -f "$temp_plans"
            cp "$plans_template" "$plans_file"
        fi
        
        # Update date placeholder
        sed_inplace "s/{{DATE}}/$(date +%Y-%m-%d)/" "$plans_file" 2>/dev/null || true
        
        # Merge existing plans into Active Plans section (after the TOON block closing tag)
        if [[ -n "$existing_plans" ]]; then
            if grep -q "<!--TOON:active_plans" "$plans_file"; then
                local temp_file="${plans_file}.merge"
                local plans_content_file
                plans_content_file=$(mktemp)
                printf '%s\n' "$existing_plans" > "$plans_content_file"
                # Use while-read to avoid BSD awk "newline in string" warning with -v
                local in_active=false
                while IFS= read -r line || [[ -n "$line" ]]; do
                    if [[ "$line" == *"<!--TOON:active_plans"* ]]; then
                        in_active=true
                    fi
                    if [[ "$in_active" == true && "$line" == "-->" ]]; then
                        echo "$line"
                        echo ""
                        cat "$plans_content_file"
                        in_active=false
                        continue
                    fi
                    echo "$line"
                done < "$plans_file" > "$temp_file"
                rm -f "$plans_content_file"
                mv "$temp_file" "$plans_file"
                print_success "Merged existing plans into Active Plans"
            fi
        fi
        
        print_success "todo/PLANS.md upgraded to TOON-enhanced template"
    fi
    
    # Update .aidevops.json with template version
    local config_file="$project_root/.aidevops.json"
    local aidevops_version
    aidevops_version=$(get_version)
    
    # Add/update templates_version in config (use jq if available)
    if command -v jq &>/dev/null; then
        local temp_json="${config_file}.tmp"
        jq --arg version "$aidevops_version" '.templates_version = $version' "$config_file" > "$temp_json" && \
            mv "$temp_json" "$config_file"
    else
        # Fallback using awk for portable newline handling (BSD sed doesn't support \n)
        if ! grep -q '"templates_version"' "$config_file" 2>/dev/null; then
            # Insert templates_version after version line
            local temp_json="${config_file}.tmp"
            awk -v ver="$aidevops_version" '
                /"version":/ { 
                    sub(/"version": "[^"]*"/, "\"version\": \"" ver "\",\n  \"templates_version\": \"" ver "\"")
                }
                { print }
            ' "$config_file" > "$temp_json" && mv "$temp_json" "$config_file"
        else
            # Update existing templates_version
            sed_inplace "s/\"templates_version\": \"[^\"]*\"/\"templates_version\": \"$aidevops_version\"/" "$config_file" 2>/dev/null || true
        fi
    fi
    
    echo ""
    print_success "Planning files upgraded!"
    echo ""
    echo "Next steps:"
    echo "  1. Review the upgraded files"
    echo "  2. Verify your tasks were preserved"
    if [[ "$backup" == "true" ]]; then
        echo "  3. Remove .bak files when satisfied"
        echo ""
        echo "If issues occurred, restore from backups:"
        [[ "$todo_needs_upgrade" == "true" ]] && echo "  mv TODO.md.bak TODO.md"
        [[ "$plans_needs_upgrade" == "true" ]] && echo "  mv todo/PLANS.md.bak todo/PLANS.md"
    fi
}

# Features command - list available features
cmd_features() {
    print_header "AI DevOps Features"
    echo ""
    
    echo "Available features for 'aidevops init':"
    echo ""
    echo "  planning       TODO.md and PLANS.md task management"
    echo "                 - Quick task tracking in TODO.md"
    echo "                 - Complex execution plans in todo/PLANS.md"
    echo "                 - PRD and task file generation"
    echo ""
    echo "  git-workflow   Branch management and PR workflows"
    echo "                 - Automatic branch suggestions"
    echo "                 - Preflight quality checks"
    echo "                 - PR creation and review"
    echo ""
    echo "  code-quality   Linting and code auditing"
    echo "                 - ShellCheck, secretlint, pattern checks"
    echo "                 - Remote auditing (CodeRabbit, Codacy, SonarCloud)"
    echo "                 - Code standards compliance"
    echo ""
    echo "  time-tracking  Time estimation and tracking"
    echo "                 - Estimate format: ~4h (ai:2h test:1h)"
    echo "                 - Automatic started:/completed: timestamps"
    echo "                 - Release time summaries"
    echo ""
    echo "  database       Declarative database schema management"
    echo "                 - schemas/ for declarative SQL/TypeScript"
    echo "                 - migrations/ for versioned changes"
    echo "                 - seeds/ for initial/test data"
    echo "                 - Auto-generate migrations on schema diff"
    echo ""
    echo "  beads          Task graph visualization with Beads"
    echo "                 - Dependency tracking (blocked-by:, blocks:)"
    echo "                 - Graph visualization with bd CLI"
    echo "                 - Ready task detection (/ready)"
    echo "                 - Bi-directional sync with TODO.md/PLANS.md"
    echo ""
    echo "Usage:"
    echo "  aidevops init                    # Enable all features"
    echo "  aidevops init planning           # Enable only planning"
    echo "  aidevops init beads              # Enable beads (includes planning)"
    echo "  aidevops init database           # Enable only database"
    echo "  aidevops init planning,database  # Enable multiple"
    echo ""
}

# Update tools command - check and update installed tools
# Passes all arguments through to tool-version-check.sh
cmd_update_tools() {
    print_header "Tool Version Check"
    echo ""
    
    local tool_check_script="$AGENTS_DIR/scripts/tool-version-check.sh"
    
    if [[ ! -f "$tool_check_script" ]]; then
        print_error "Tool version check script not found"
        print_info "Run 'aidevops update' first to get the latest scripts"
        return 1
    fi
    
    # Pass all arguments through to the script
    bash "$tool_check_script" "$@"
}

# Repos command - list and manage registered repos
cmd_repos() {
    local action="${1:-list}"
    
    case "$action" in
        list|ls)
            print_header "Registered AI DevOps Projects"
            echo ""
            
            init_repos_file
            
            if ! command -v jq &>/dev/null; then
                print_error "jq required for repo management"
                return 1
            fi
            
            local count
            count=$(jq '.initialized_repos | length' "$REPOS_FILE" 2>/dev/null || echo "0")
            
            if [[ "$count" == "0" ]]; then
                print_info "No projects registered yet"
                echo ""
                echo "Initialize a project with: aidevops init"
                return 0
            fi
            
            local current_ver
            current_ver=$(get_version)
            
            jq -r '.initialized_repos[] | "\(.path)|\(.version)|\(.features | join(","))"' "$REPOS_FILE" 2>/dev/null | while IFS='|' read -r path version features; do
                local name
                name=$(basename "$path")
                local status="✓"
                local status_color="$GREEN"
                
                if [[ "$version" != "$current_ver" ]]; then
                    status="↑"
                    status_color="$YELLOW"
                fi
                
                if [[ ! -d "$path" ]]; then
                    status="✗"
                    status_color="$RED"
                fi
                
                echo -e "${status_color}${status}${NC} ${BOLD}$name${NC}"
                echo "    Path: $path"
                echo "    Version: $version"
                echo "    Features: $features"
                echo ""
            done
            
            echo "Legend: ✓ up-to-date  ↑ update available  ✗ not found"
            ;;
        
        add)
            # Register current directory
            if ! git rev-parse --is-inside-work-tree &>/dev/null; then
                print_error "Not in a git repository"
                return 1
            fi
            
            local project_root
            project_root=$(git rev-parse --show-toplevel)
            
            if [[ ! -f "$project_root/.aidevops.json" ]]; then
                print_error "No .aidevops.json found - run 'aidevops init' first"
                return 1
            fi
            
            local version features
            if command -v jq &>/dev/null; then
                version=$(jq -r '.version' "$project_root/.aidevops.json" 2>/dev/null || echo "unknown")
                features=$(jq -r '[.features | to_entries[] | select(.value == true) | .key] | join(",")' "$project_root/.aidevops.json" 2>/dev/null || echo "")
            else
                version="unknown"
                features=""
            fi
            
            register_repo "$project_root" "$version" "$features"
            print_success "Registered $(basename "$project_root")"
            ;;
        
        remove|rm)
            local repo_path="${2:-}"
            local original_path="$repo_path"
            
            if [[ -z "$repo_path" ]]; then
                # Use current directory
                if git rev-parse --is-inside-work-tree &>/dev/null; then
                    repo_path=$(git rev-parse --show-toplevel)
                    original_path="$repo_path"
                else
                    print_error "Specify a repo path or run from within a git repo"
                    return 1
                fi
            fi
            
            # Normalize path (keep original if normalization fails)
            repo_path=$(cd "$repo_path" 2>/dev/null && pwd -P) || repo_path="$original_path"
            
            if ! command -v jq &>/dev/null; then
                print_error "jq required for repo management"
                return 1
            fi
            
            local temp_file="${REPOS_FILE}.tmp"
            jq --arg path "$repo_path" '.initialized_repos |= map(select(.path != $path))' "$REPOS_FILE" > "$temp_file" && \
                mv "$temp_file" "$REPOS_FILE"
            
            print_success "Removed $repo_path from registry"
            ;;
        
        clean)
            # Remove entries for repos that no longer exist
            print_info "Cleaning up stale repo entries..."
            
            if ! command -v jq &>/dev/null; then
                print_error "jq required for repo management"
                return 1
            fi
            
            local removed=0
            local temp_file="${REPOS_FILE}.tmp"
            
            while IFS= read -r repo_path; do
                [[ -z "$repo_path" ]] && continue
                if [[ ! -d "$repo_path" ]]; then
                    jq --arg path "$repo_path" '.initialized_repos |= map(select(.path != $path))' "$REPOS_FILE" > "$temp_file" && \
                        mv "$temp_file" "$REPOS_FILE"
                    print_info "Removed: $repo_path"
                    removed=$((removed + 1))
                fi
            done < <(get_registered_repos)
            
            if [[ $removed -eq 0 ]]; then
                print_success "No stale entries found"
            else
                print_success "Removed $removed stale entries"
            fi
            ;;
        
        *)
            echo "Usage: aidevops repos <command>"
            echo ""
            echo "Commands:"
            echo "  list     List all registered projects (default)"
            echo "  add      Register current project"
            echo "  remove   Remove project from registry"
            echo "  clean    Remove entries for non-existent projects"
            ;;
    esac
}

# Detect command - check for unregistered aidevops repos
cmd_detect() {
    print_header "Detecting AI DevOps Projects"
    echo ""
    
    # Check current directory first
    local unregistered
    unregistered=$(detect_unregistered_repo)
    
    if [[ -n "$unregistered" ]]; then
        print_info "Found unregistered aidevops project:"
        echo "  $unregistered"
        echo ""
        read -r -p "Register this project? [Y/n] " response
        response="${response:-y}"
        if [[ "$response" =~ ^[Yy]$ ]]; then
            local version features
            if command -v jq &>/dev/null; then
                version=$(jq -r '.version' "$unregistered/.aidevops.json" 2>/dev/null || echo "unknown")
                features=$(jq -r '[.features | to_entries[] | select(.value == true) | .key] | join(",")' "$unregistered/.aidevops.json" 2>/dev/null || echo "")
            else
                version="unknown"
                features=""
            fi
            register_repo "$unregistered" "$version" "$features"
            print_success "Registered $(basename "$unregistered")"
        fi
        return 0
    fi
    
    # Scan common locations
    print_info "Scanning for aidevops projects in ~/Git/..."
    
    local found=0
    local to_register=()
    
    if [[ -d "$HOME/Git" ]]; then
        while IFS= read -r -d '' aidevops_json; do
            local repo_dir
            repo_dir=$(dirname "$aidevops_json")
            
            # Check if already registered
            init_repos_file
            if command -v jq &>/dev/null; then
                if ! jq -e --arg path "$repo_dir" '.initialized_repos[] | select(.path == $path)' "$REPOS_FILE" &>/dev/null; then
                    to_register+=("$repo_dir")
                    found=$((found + 1))
                fi
            fi
        done < <(find "$HOME/Git" -maxdepth 3 -name ".aidevops.json" -print0 2>/dev/null)
    fi
    
    if [[ $found -eq 0 ]]; then
        print_success "No unregistered aidevops projects found"
        return 0
    fi
    
    echo ""
    print_info "Found $found unregistered project(s):"
    for repo in "${to_register[@]}"; do
        echo "  - $(basename "$repo") ($repo)"
    done
    
    echo ""
    read -r -p "Register all? [Y/n] " response
    response="${response:-y}"
    if [[ "$response" =~ ^[Yy]$ ]]; then
        for repo in "${to_register[@]}"; do
            local version features
            if command -v jq &>/dev/null; then
                version=$(jq -r '.version' "$repo/.aidevops.json" 2>/dev/null || echo "unknown")
                features=$(jq -r '[.features | to_entries[] | select(.value == true) | .key] | join(",")' "$repo/.aidevops.json" 2>/dev/null || echo "")
            else
                version="unknown"
                features=""
            fi
            register_repo "$repo" "$version" "$features"
            print_success "Registered $(basename "$repo")"
        done
    fi
    return 0
}

# Skill command - manage agent skills
cmd_skill() {
    local action="${1:-help}"
    shift || true

    # Disable telemetry for any downstream tools (add-skill, skills CLI)
    export DISABLE_TELEMETRY=1
    export DO_NOT_TRACK=1
    export SKILLS_NO_TELEMETRY=1

    local add_skill_script="$AGENTS_DIR/scripts/add-skill-helper.sh"
    local update_skill_script="$AGENTS_DIR/scripts/skill-update-helper.sh"

    case "$action" in
        add|a)
            if [[ $# -lt 1 ]]; then
                print_error "Source required (owner/repo or URL)"
                echo ""
                echo "Usage: aidevops skill add <source> [options]"
                echo ""
                echo "Examples:"
                echo "  aidevops skill add vercel-labs/agent-skills"
                echo "  aidevops skill add anthropics/skills/pdf"
                echo "  aidevops skill add https://github.com/owner/repo"
                echo ""
                echo "Options:"
                echo "  --name <name>   Override the skill name"
                echo "  --force         Overwrite existing skill"
                echo "  --dry-run       Preview without making changes"
                echo ""
                echo "Browse skills: https://skills.sh"
                return 1
            fi

            if [[ ! -f "$add_skill_script" ]]; then
                print_error "add-skill-helper.sh not found"
                print_info "Run 'aidevops update' to get the latest scripts"
                return 1
            fi

            bash "$add_skill_script" add "$@"
            ;;
        list|ls|l)
            if [[ ! -f "$add_skill_script" ]]; then
                print_error "add-skill-helper.sh not found"
                return 1
            fi
            bash "$add_skill_script" list
            ;;
        check|c)
            if [[ ! -f "$update_skill_script" ]]; then
                print_error "skill-update-helper.sh not found"
                return 1
            fi
            bash "$update_skill_script" check "$@"
            ;;
        update|u)
            if [[ ! -f "$update_skill_script" ]]; then
                print_error "skill-update-helper.sh not found"
                return 1
            fi
            bash "$update_skill_script" update "$@"
            ;;
        remove|rm)
            if [[ $# -lt 1 ]]; then
                print_error "Skill name required"
                echo "Usage: aidevops skill remove <name>"
                return 1
            fi
            if [[ ! -f "$add_skill_script" ]]; then
                print_error "add-skill-helper.sh not found"
                return 1
            fi
            bash "$add_skill_script" remove "$@"
            ;;
        status|s)
            if [[ ! -f "$update_skill_script" ]]; then
                print_error "skill-update-helper.sh not found"
                return 1
            fi
            bash "$update_skill_script" status "$@"
            ;;
        generate|gen|g)
            local generate_script="$AGENTS_DIR/scripts/generate-skills.sh"
            if [[ ! -f "$generate_script" ]]; then
                print_error "generate-skills.sh not found"
                print_info "Run 'aidevops update' to get the latest scripts"
                return 1
            fi
            print_info "Generating SKILL.md stubs for cross-tool discovery..."
            bash "$generate_script" "$@"
            ;;
        scan)
            local security_script="$AGENTS_DIR/scripts/security-helper.sh"
            if [[ ! -f "$security_script" ]]; then
                print_error "security-helper.sh not found"
                print_info "Run 'aidevops update' to get the latest scripts"
                return 1
            fi
            bash "$security_script" skill-scan "$@"
            ;;
        clean)
            local generate_script="$AGENTS_DIR/scripts/generate-skills.sh"
            if [[ ! -f "$generate_script" ]]; then
                print_error "generate-skills.sh not found"
                return 1
            fi
            bash "$generate_script" --clean "$@"
            ;;
        help|--help|-h)
            print_header "Agent Skills Management"
            echo ""
            echo "Import and manage reusable AI agent skills from the community."
            echo "Skills are converted to aidevops format with upstream tracking."
            echo "Telemetry is disabled - no data sent to third parties."
            echo ""
            echo "Usage: aidevops skill <command> [options]"
            echo ""
            echo "Commands:"
            echo "  add <source>     Import a skill from GitHub (saved as *-skill.md)"
            echo "  list             List all imported skills"
            echo "  check            Check for upstream updates"
            echo "  update [name]    Update specific or all skills"
            echo "  remove <name>    Remove an imported skill"
            echo "  scan [name]      Security scan imported skills (Cisco Skill Scanner)"
            echo "  status           Show detailed skill status"
            echo "  generate         Generate SKILL.md stubs for cross-tool discovery"
            echo "  clean            Remove generated SKILL.md stubs"
            echo ""
            echo "Source formats:"
            echo "  owner/repo                    GitHub shorthand"
            echo "  owner/repo/path/to/skill      Specific skill in multi-skill repo"
            echo "  https://github.com/owner/repo Full URL"
            echo ""
            echo "Examples:"
            echo "  aidevops skill add vercel-labs/agent-skills"
            echo "  aidevops skill add anthropics/skills/pdf"
            echo "  aidevops skill add expo/skills --name expo-dev"
            echo "  aidevops skill check"
            echo "  aidevops skill update"
            echo "  aidevops skill scan"
            echo "  aidevops skill scan cloudflare-platform"
            echo "  aidevops skill generate --dry-run"
            echo ""
            echo "Imported skills are saved with a -skill suffix to distinguish"
            echo "from native aidevops subagents (e.g., playwright-skill.md vs playwright.md)."
            echo ""
            echo "Browse community skills: https://skills.sh"
            echo "Agent Skills specification: https://agentskills.io"
            ;;
        *)
            print_error "Unknown skill command: $action"
            echo "Run 'aidevops skill help' for usage information."
            return 1
            ;;
    esac
}

# Help command
cmd_help() {
    local version
    version=$(get_version)
    
    echo "AI DevOps Framework CLI v$version"
    echo ""
    echo "Usage: aidevops <command> [options]"
    echo ""
    echo "Commands:"
    echo "  init [features]    Initialize aidevops in current project"
    echo "  upgrade-planning   Upgrade TODO.md/PLANS.md to latest templates"
    echo "  features           List available features for init"
    echo "  skill <cmd>        Manage agent skills (add/list/check/update/remove)"
    echo "  status             Check installation status of all components"
    echo "  update             Update aidevops to the latest version (alias: upgrade)"
    echo "  upgrade            Alias for update"
    echo "  update-tools       Check for outdated tools (--update to auto-update)"
    echo "  repos [cmd]        Manage registered projects (list/add/remove/clean)"
    echo "  secret <cmd>       Manage secrets (set/list/run/init/import/status)"
    echo "  detect             Find and register aidevops projects"
    echo "  uninstall          Remove aidevops from your system"
    echo "  version            Show version information"
    echo "  help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  aidevops init                # Initialize with all features"
    echo "  aidevops init planning       # Initialize with planning only"
    echo "  aidevops upgrade-planning    # Upgrade planning files to latest"
    echo "  aidevops features            # List available features"
    echo "  aidevops status              # Check what's installed"
    echo "  aidevops update              # Update framework + check projects"
    echo "  aidevops repos               # List registered projects"
    echo "  aidevops repos add           # Register current project"
    echo "  aidevops detect              # Find unregistered projects"
    echo "  aidevops update-tools        # Check for outdated tools"
    echo "  aidevops update-tools -u     # Update all outdated tools"
    echo "  aidevops uninstall           # Remove aidevops"
    echo ""
    echo "Secrets:"
    echo "  aidevops secret set NAME     # Store a secret (hidden input)"
    echo "  aidevops secret list         # List secret names (never values)"
    echo "  aidevops secret run CMD      # Run with secrets injected + redacted"
    echo "  aidevops secret init         # Initialize gopass encrypted store"
    echo "  aidevops secret import       # Import from credentials.sh to gopass"
    echo "  aidevops secret status       # Show backend status"
    echo ""
    echo "Skills:"
    echo "  aidevops skill add <source>  # Import a skill from GitHub"
    echo "  aidevops skill list          # List imported skills"
    echo "  aidevops skill check         # Check for upstream updates"
    echo "  aidevops skill update [name] # Update skills to latest"
    echo "  aidevops skill remove <name> # Remove an imported skill"
    echo ""
    echo "Installation:"
    echo "  npm install -g aidevops && aidevops update      # via npm (recommended)"
    echo "  brew install marcusquinn/tap/aidevops && aidevops update  # via Homebrew"
    echo "  curl -fsSL https://aidevops.sh -o /tmp/aidevops-setup.sh && bash /tmp/aidevops-setup.sh  # manual"
    echo ""
    echo "Documentation: https://github.com/marcusquinn/aidevops"
}

# Version command
cmd_version() {
    local current_version
    current_version=$(get_version)
    local remote_version
    remote_version=$(get_remote_version)
    
    echo "aidevops $current_version"
    
    if [[ "$remote_version" != "unknown" && "$current_version" != "$remote_version" ]]; then
        echo "Latest: $remote_version (run 'aidevops update' to upgrade)"
    fi
}

# Main entry point
main() {
    local command="${1:-help}"
    
    # Auto-detect unregistered repo on any command (silent check)
    local unregistered
    unregistered=$(detect_unregistered_repo 2>/dev/null) || true
    if [[ -n "$unregistered" && "$command" != "detect" && "$command" != "repos" ]]; then
        echo -e "${YELLOW}[TIP]${NC} This project uses aidevops but isn't registered. Run: aidevops repos add"
        echo ""
    fi
    
    # Check if agents need updating (skip for update command itself)
    if [[ "$command" != "update" && "$command" != "upgrade" && "$command" != "u" ]]; then
        local cli_version agents_version
        cli_version=$(get_version)
        if [[ -f "$AGENTS_DIR/VERSION" ]]; then
            agents_version=$(cat "$AGENTS_DIR/VERSION")
        else
            agents_version="not installed"
        fi
        
        if [[ "$agents_version" == "not installed" ]]; then
            echo -e "${YELLOW}[WARN]${NC} Agents not installed. Run: aidevops update"
            echo ""
        elif [[ "$cli_version" != "$agents_version" ]]; then
            echo -e "${YELLOW}[WARN]${NC} Version mismatch - CLI: $cli_version, Agents: $agents_version"
            echo -e "       Run: aidevops update"
            echo ""
        fi
    fi
    
    case "$command" in
        init|i)
            shift
            cmd_init "$@"
            ;;
        features|f)
            cmd_features
            ;;
        status|s)
            cmd_status
            ;;
        update|upgrade|u)
            cmd_update
            ;;
        update-tools|tools)
            shift
            cmd_update_tools "$@"
            ;;
        upgrade-planning|up)
            shift
            cmd_upgrade_planning "$@"
            ;;
        repos|projects)
            shift
            cmd_repos "$@"
            ;;
        skill|skills)
            shift
            cmd_skill "$@"
            ;;
        detect|scan)
            cmd_detect
            ;;
        secret|secrets)
            shift
            local secret_helper="$AGENTS_DIR/scripts/secret-helper.sh"
            if [[ ! -f "$secret_helper" ]]; then
                secret_helper="$INSTALL_DIR/.agents/scripts/secret-helper.sh"
            fi
            if [[ -f "$secret_helper" ]]; then
                bash "$secret_helper" "$@"
            else
                print_error "secret-helper.sh not found. Run: aidevops update"
                exit 1
            fi
            ;;
        uninstall|remove)
            cmd_uninstall
            ;;
        version|v|-v|--version)
            cmd_version
            ;;
        help|h|-h|--help)
            cmd_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
