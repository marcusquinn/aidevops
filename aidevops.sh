#!/bin/bash

# AI DevOps Framework CLI
# Usage: aidevops <command> [options]
#
# Version: 2.13.0

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
REPO_URL="https://github.com/marcusquinn/aidevops.git"
VERSION_FILE="$INSTALL_DIR/VERSION"

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
        "$HOME/.cursor/rules:Cursor"
        "$HOME/.claude/commands:Claude Code"
        "$HOME/.continue:Continue.dev"
        "$HOME/CLAUDE.md:Claude CLI memory"
        "$HOME/GEMINI.md:Gemini CLI memory"
        "$HOME/.cursorrules:Cursor rules"
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
            print_success "Already up to date!"
            return 0
        fi
        
        print_info "Pulling latest changes..."
        git pull --ff-only origin main
        
        if [[ $? -eq 0 ]]; then
            local new_version
            new_version=$(get_version)
            print_success "Updated to version $new_version"
            echo ""
            print_info "Running setup to apply changes..."
            bash "$INSTALL_DIR/setup.sh"
        else
            print_error "Failed to pull updates"
            print_info "Try: cd $INSTALL_DIR && git pull"
            return 1
        fi
    else
        print_warning "Repository not found, performing fresh install..."
        bash <(curl -fsSL https://raw.githubusercontent.com/marcusquinn/aidevops/main/setup.sh)
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
        "$HOME/.cursor/rules/AGENTS.md"
        "$HOME/.claude/commands/AGENTS.md"
        "$HOME/.continue/AGENTS.md"
        "$HOME/.cody/AGENTS.md"
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
                sed -i.tmp '/# AI Assistant Server Access Framework/,/^$/d' "$rc_file"
                rm -f "$rc_file.tmp"
                print_success "Removed aliases from $rc_file"
            fi
        fi
    done
    
    # Remove memory files
    print_info "Removing AI memory files..."
    local memory_files=(
        "$HOME/CLAUDE.md"
        "$HOME/GEMINI.md"
        "$HOME/WINDSURF.md"
        "$HOME/.qwen/QWEN.md"
        "$HOME/.factory/DROID.md"
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
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/marcusquinn/aidevops/main/setup.sh)"
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
    
    local project_root
    project_root=$(git rev-parse --show-toplevel)
    print_info "Project root: $project_root"
    echo ""
    
    # Parse features
    local enable_planning=false
    local enable_git_workflow=false
    local enable_code_quality=false
    local enable_time_tracking=false
    
    case "$features" in
        all)
            enable_planning=true
            enable_git_workflow=true
            enable_code_quality=true
            enable_time_tracking=true
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
    "time_tracking": $enable_time_tracking
  },
  "time_tracking": {
    "enabled": $enable_time_tracking,
    "prompt_on_commit": true,
    "auto_record_branch_start": true
  }
}
EOF
    print_success "Created .aidevops.json"
    
    # Create .agent symlink
    if [[ ! -e "$project_root/.agent" ]]; then
        print_info "Creating .agent symlink..."
        ln -s "$AGENTS_DIR" "$project_root/.agent"
        print_success "Created .agent -> $AGENTS_DIR"
    else
        print_warning ".agent already exists, skipping symlink"
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

*See `.agent/workflows/plans.md` for planning workflow*
EOF
                print_success "Created todo/PLANS.md (minimal template)"
            fi
        else
            print_warning "todo/PLANS.md already exists, skipping"
        fi
        
        # Create .gitkeep in tasks
        touch "$project_root/todo/tasks/.gitkeep"
    fi
    
    # Add to .gitignore if needed
    local gitignore="$project_root/.gitignore"
    if [[ -f "$gitignore" ]]; then
        if ! grep -q "^\.agent$" "$gitignore" 2>/dev/null; then
            echo "" >> "$gitignore"
            echo "# aidevops" >> "$gitignore"
            echo ".agent" >> "$gitignore"
            print_success "Added .agent to .gitignore"
        fi
    fi
    
    echo ""
    print_success "AI DevOps initialized!"
    echo ""
    echo "Enabled features:"
    [[ "$enable_planning" == "true" ]] && echo "  ✓ Planning (TODO.md, PLANS.md)"
    [[ "$enable_git_workflow" == "true" ]] && echo "  ✓ Git workflow (branch management)"
    [[ "$enable_code_quality" == "true" ]] && echo "  ✓ Code quality (linting, auditing)"
    [[ "$enable_time_tracking" == "true" ]] && echo "  ✓ Time tracking (estimates, actuals)"
    echo ""
    echo "Next steps:"
    echo "  1. Add tasks to TODO.md"
    echo "  2. Use /create-prd for complex features"
    echo "  3. Use /feature to start development"
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
    echo "Usage:"
    echo "  aidevops init                    # Enable all features"
    echo "  aidevops init planning           # Enable only planning"
    echo "  aidevops init planning,git-workflow  # Enable multiple"
    echo ""
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
    echo "  init [features]  Initialize aidevops in current project"
    echo "  features         List available features for init"
    echo "  status           Check installation status of all components"
    echo "  update           Update to the latest version (alias: upgrade)"
    echo "  uninstall        Remove aidevops from your system"
    echo "  version          Show version information"
    echo "  help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  aidevops init                # Initialize with all features"
    echo "  aidevops init planning       # Initialize with planning only"
    echo "  aidevops features            # List available features"
    echo "  aidevops status              # Check what's installed"
    echo "  aidevops update              # Update to latest version"
    echo "  aidevops uninstall           # Remove aidevops"
    echo ""
    echo "Quick install:"
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/marcusquinn/aidevops/main/setup.sh)"
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
