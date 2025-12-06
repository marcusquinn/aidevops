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

# Help command
cmd_help() {
    local version
    version=$(get_version)
    
    echo "AI DevOps Framework CLI v$version"
    echo ""
    echo "Usage: aidevops <command> [options]"
    echo ""
    echo "Commands:"
    echo "  status      Check installation status of all components"
    echo "  update      Update to the latest version (alias: upgrade)"
    echo "  uninstall   Remove aidevops from your system"
    echo "  version     Show version information"
    echo "  help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  aidevops status      # Check what's installed"
    echo "  aidevops update      # Update to latest version"
    echo "  aidevops uninstall   # Remove aidevops"
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
