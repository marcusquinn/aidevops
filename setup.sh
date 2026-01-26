#!/bin/bash

# AI Assistant Server Access Framework Setup Script
# Helps developers set up the framework for their infrastructure
#
# Version: 2.89.3
#
# Quick Install (one-liner):
#   bash <(curl -fsSL https://aidevops.dev/install)
#   OR: bash <(curl -fsSL https://raw.githubusercontent.com/marcusquinn/aidevops/main/setup.sh)

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Global flags
CLEAN_MODE=false
INTERACTIVE_MODE=false
UPDATE_TOOLS_MODE=false
REPO_URL="https://github.com/marcusquinn/aidevops.git"
INSTALL_DIR="$HOME/Git/aidevops"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Find best python3 binary (prefer Homebrew/pyenv over system)
find_python3() {
    local candidates=(
        "/opt/homebrew/bin/python3"
        "/usr/local/bin/python3"
        "$HOME/.pyenv/shims/python3"
    )
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    # Fallback to PATH
    if command -v python3 &> /dev/null; then
        command -v python3
        return 0
    fi
    return 1
}

# Confirm step in interactive mode
# Usage: confirm_step "Step description" && function_to_run
# Returns: 0 if confirmed or not interactive, 1 if skipped
confirm_step() {
    local step_name="$1"
    
    # Skip confirmation in non-interactive mode
    if [[ "$INTERACTIVE_MODE" != "true" ]]; then
        return 0
    fi
    
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Step:${NC} $step_name"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    while true; do
        echo -n -e "${GREEN}Run this step? [Y]es / [n]o / [q]uit: ${NC}"
        read -r response
        # Convert to lowercase (bash 3.2 compatible)
        response=$(echo "$response" | tr '[:upper:]' '[:lower:]')
        case "$response" in
            y|yes|"")
                return 0
                ;;
            n|no|s|skip)
                print_warning "Skipped: $step_name"
                return 1
                ;;
            q|quit|exit)
                echo ""
                print_info "Setup cancelled by user"
                exit 0
                ;;
            *)
                echo "Please answer: y (yes), n (no), or q (quit)"
                ;;
        esac
    done
}

# Backup rotation settings
BACKUP_KEEP_COUNT=10

# Create a backup with rotation (keeps last N backups)
# Usage: create_backup_with_rotation <source_path> <backup_name>
# Example: create_backup_with_rotation "$target_dir" "agents"
# Creates: ~/.aidevops/agents-backups/20251221_123456/
create_backup_with_rotation() {
    local source_path="$1"
    local backup_name="$2"
    local backup_base="$HOME/.aidevops/${backup_name}-backups"
    local backup_dir
    backup_dir="$backup_base/$(date +%Y%m%d_%H%M%S)"
    
    # Create backup directory
    mkdir -p "$backup_dir"
    
    # Copy source to backup
    if [[ -d "$source_path" ]]; then
        cp -R "$source_path" "$backup_dir/"
    elif [[ -f "$source_path" ]]; then
        cp "$source_path" "$backup_dir/"
    else
        print_warning "Source path does not exist: $source_path"
        return 1
    fi
    
    print_info "Backed up to $backup_dir"
    
    # Rotate old backups (keep last N)
    local backup_count
    backup_count=$(find "$backup_base" -maxdepth 1 -type d -name "20*" 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ $backup_count -gt $BACKUP_KEEP_COUNT ]]; then
        local to_delete=$((backup_count - BACKUP_KEEP_COUNT))
        print_info "Rotating backups: removing $to_delete old backup(s), keeping last $BACKUP_KEEP_COUNT"
        
        # Delete oldest backups (sorted by name = sorted by date)
        find "$backup_base" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort | head -n "$to_delete" | while read -r old_backup; do
            rm -rf "$old_backup"
        done
    fi
    
    return 0
}

# Remove deprecated agent paths that have been moved
# This ensures clean upgrades when agents are reorganized
cleanup_deprecated_paths() {
    local agents_dir="$HOME/.aidevops/agents"
    local cleaned=0
    
    # List of deprecated paths (add new ones here when reorganizing)
    local deprecated_paths=(
        # v2.40.7: wordpress moved from root to tools/wordpress
        "$agents_dir/wordpress.md"
        "$agents_dir/wordpress"
        # v2.41.0: build-agent and build-mcp moved from root to tools/
        "$agents_dir/build-agent.md"
        "$agents_dir/build-agent"
        "$agents_dir/build-mcp.md"
        "$agents_dir/build-mcp"
    )
    
    for path in "${deprecated_paths[@]}"; do
        if [[ -e "$path" ]]; then
            rm -rf "$path"
            ((cleaned++))
        fi
    done
    
    if [[ $cleaned -gt 0 ]]; then
        print_info "Cleaned up $cleaned deprecated agent path(s)"
    fi
    
    return 0
}

# Remove deprecated MCP entries from opencode.json
# These MCPs have been replaced by curl-based subagents (zero context cost)
cleanup_deprecated_mcps() {
    local opencode_config="$HOME/.config/opencode/opencode.json"
    
    if [[ ! -f "$opencode_config" ]]; then
        return 0
    fi
    
    if ! command -v jq &> /dev/null; then
        return 0
    fi
    
    # MCPs replaced by curl subagents in v2.79.0
    local deprecated_mcps=(
        "hetzner-awardsapp"
        "hetzner-brandlight"
        "hetzner-marcusquinn"
        "hetzner-storagebox"
        "ahrefs"
        "serper"
        "dataforseo"
        "hostinger-api"
        "shadcn"
        "repomix"
    )
    
    # Tool rules to remove (for MCPs that no longer exist)
    local deprecated_tools=(
        "hetzner-*"
        "hostinger-api_*"
        "ahrefs_*"
        "dataforseo_*"
        "serper_*"
        "shadcn_*"
        "repomix_*"
    )
    
    local cleaned=0
    local tmp_config
    tmp_config=$(mktemp)
    
    cp "$opencode_config" "$tmp_config"
    
    for mcp in "${deprecated_mcps[@]}"; do
        if jq -e ".mcp[\"$mcp\"]" "$tmp_config" > /dev/null 2>&1; then
            jq "del(.mcp[\"$mcp\"])" "$tmp_config" > "${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
            ((cleaned++))
        fi
    done
    
    for tool in "${deprecated_tools[@]}"; do
        if jq -e ".tools[\"$tool\"]" "$tmp_config" > /dev/null 2>&1; then
            jq "del(.tools[\"$tool\"])" "$tmp_config" > "${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
        fi
    done
    
    # Also remove deprecated tool refs from SEO agent
    if jq -e '.agent.SEO.tools["dataforseo_*"]' "$tmp_config" > /dev/null 2>&1; then
        jq 'del(.agent.SEO.tools["dataforseo_*"]) | del(.agent.SEO.tools["serper_*"]) | del(.agent.SEO.tools["ahrefs_*"])' "$tmp_config" > "${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
    fi
    
    # Migrate npx/pipx commands to full binary paths (faster startup, PATH-independent)
    # Parallel arrays avoid bash associative array issues with @ in package names
    local -a mcp_pkgs=(
        "chrome-devtools-mcp"
        "mcp-server-gsc"
        "playwriter"
        "@steipete/macos-automator-mcp"
        "@steipete/claude-code-mcp"
        "analytics-mcp"
    )
    local -a mcp_bins=(
        "chrome-devtools-mcp"
        "mcp-server-gsc"
        "playwriter"
        "macos-automator-mcp"
        "claude-code-mcp"
        "analytics-mcp"
    )

    local i
    for i in "${!mcp_pkgs[@]}"; do
        local pkg="${mcp_pkgs[$i]}"
        local bin_name="${mcp_bins[$i]}"
        # Find MCP key using npx/bunx/pipx for this package (single query)
        local mcp_key
        mcp_key=$(jq -r --arg pkg "$pkg" '.mcp | to_entries[] | select(.value.command != null) | select(.value.command | join(" ") | test("npx.*" + $pkg + "|bunx.*" + $pkg + "|pipx.*run.*" + $pkg)) | .key' "$tmp_config" 2>/dev/null | head -1)

        if [[ -n "$mcp_key" ]]; then
            # Resolve full path for the binary
            local full_path
            full_path=$(resolve_mcp_binary_path "$bin_name")
            if [[ -n "$full_path" ]]; then
                jq --arg k "$mcp_key" --arg p "$full_path" '.mcp[$k].command = [$p]' "$tmp_config" > "${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
                ((cleaned++))
            fi
        fi
    done

    # Migrate outscraper from bash -c wrapper to full binary path
    if jq -e '.mcp.outscraper.command | join(" ") | test("bash.*outscraper")' "$tmp_config" > /dev/null 2>&1; then
        local outscraper_path
        outscraper_path=$(resolve_mcp_binary_path "outscraper-mcp-server")
        if [[ -n "$outscraper_path" ]]; then
            # Source the API key and set it in environment
            local outscraper_key=""
            if [[ -f "$HOME/.config/aidevops/mcp-env.sh" ]]; then
                # shellcheck source=/dev/null
                outscraper_key=$(source "$HOME/.config/aidevops/mcp-env.sh" && echo "${OUTSCRAPER_API_KEY:-}")
            fi
            jq --arg p "$outscraper_path" --arg key "$outscraper_key" '.mcp.outscraper.command = [$p] | .mcp.outscraper.environment = {"OUTSCRAPER_API_KEY": $key}' "$tmp_config" > "${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
            ((cleaned++))
        fi
    fi

    if [[ $cleaned -gt 0 ]]; then
        create_backup_with_rotation "$opencode_config" "opencode"
        mv "$tmp_config" "$opencode_config"
        print_info "Updated $cleaned MCP entry/entries in opencode.json (using full binary paths)"
    else
        rm -f "$tmp_config"
    fi

    # Always resolve bare binary names to full paths (fixes PATH-dependent startup)
    update_mcp_paths_in_opencode
    
    return 0
}

# Migrate old config-backups to new per-type backup structure
# This runs once to clean up the legacy backup directory
migrate_old_backups() {
    local old_backup_dir="$HOME/.aidevops/config-backups"
    
    # Skip if old directory doesn't exist
    if [[ ! -d "$old_backup_dir" ]]; then
        return 0
    fi
    
    # Count old backups
    local old_count
    old_count=$(find "$old_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ $old_count -eq 0 ]]; then
        # Empty directory, just remove it
        rm -rf "$old_backup_dir"
        return 0
    fi
    
    print_info "Migrating $old_count old backups to new structure..."
    
    # Create new backup directories
    mkdir -p "$HOME/.aidevops/agents-backups"
    mkdir -p "$HOME/.aidevops/opencode-backups"
    
    # Move the most recent backups (up to BACKUP_KEEP_COUNT) to new locations
    # Old backups contained mixed content, so we'll just keep the newest ones as agents backups
    local migrated=0
    for backup in $(find "$old_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort -r | head -n "$BACKUP_KEEP_COUNT"); do
        local backup_name
        backup_name=$(basename "$backup")
        
        # Check if it contains agents folder (most common)
        if [[ -d "$backup/agents" ]]; then
            mv "$backup" "$HOME/.aidevops/agents-backups/$backup_name"
            ((migrated++))
        # Check if it contains opencode.json
        elif [[ -f "$backup/opencode.json" ]]; then
            mv "$backup" "$HOME/.aidevops/opencode-backups/$backup_name"
            ((migrated++))
        fi
    done
    
    # Remove remaining old backups and the old directory
    rm -rf "$old_backup_dir"
    
    if [[ $migrated -gt 0 ]]; then
        print_success "Migrated $migrated recent backups, removed $((old_count - migrated)) old backups"
    else
        print_info "Cleaned up $old_count old backups"
    fi
    
    return 0
}

# Migrate loop state from .claude/ to .agent/loop-state/ in user projects
# This handles the breaking change from v2.51.0 where loop state directory moved
# The migration is non-destructive: moves files, doesn't delete originals until confirmed
migrate_loop_state_directories() {
    print_info "Checking for legacy loop state directories..."
    
    local migrated=0
    local git_dirs=()
    
    # Find Git repositories in common locations
    # Check ~/Git/ and current directory's parent
    for search_dir in "$HOME/Git" "$(dirname "$(pwd)")"; do
        if [[ -d "$search_dir" ]]; then
            while IFS= read -r -d '' git_dir; do
                git_dirs+=("$(dirname "$git_dir")")
            done < <(find "$search_dir" -maxdepth 3 -type d -name ".git" -print0 2>/dev/null)
        fi
    done
    
    for repo_dir in "${git_dirs[@]}"; do
        local old_state_dir="$repo_dir/.claude"
        local new_state_dir="$repo_dir/.agent/loop-state"
        
        # Skip if no old state directory
        [[ ! -d "$old_state_dir" ]] && continue
        
        # Check for loop state files in old location
        local has_loop_state=false
        if [[ -f "$old_state_dir/ralph-loop.local.state" ]] || \
           [[ -f "$old_state_dir/loop-state.json" ]] || \
           [[ -d "$old_state_dir/receipts" ]]; then
            has_loop_state=true
        fi
        
        [[ "$has_loop_state" != "true" ]] && continue
        
        print_info "Found legacy loop state in: $repo_dir/.claude/"
        
        # Create new directory
        mkdir -p "$new_state_dir"
        
        # Move loop-related files
        for file in ralph-loop.local.state loop-state.json re-anchor.md guardrails.md; do
            if [[ -f "$old_state_dir/$file" ]]; then
                mv "$old_state_dir/$file" "$new_state_dir/"
                print_info "  Moved $file"
            fi
        done
        
        # Move receipts directory
        if [[ -d "$old_state_dir/receipts" ]]; then
            mv "$old_state_dir/receipts" "$new_state_dir/"
            print_info "  Moved receipts/"
        fi
        
        # Check if .claude/ is now empty (only has hidden files or nothing)
        local remaining
        remaining=$(find "$old_state_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
        
        if [[ "$remaining" -eq 0 ]]; then
            rmdir "$old_state_dir" 2>/dev/null && print_info "  Removed empty .claude/"
        else
            print_warning "  .claude/ has other files, not removing"
        fi
        
        # Update .gitignore if needed
        local gitignore="$repo_dir/.gitignore"
        if [[ -f "$gitignore" ]]; then
            if ! grep -q "^\.agent/loop-state/" "$gitignore" 2>/dev/null; then
                echo ".agent/loop-state/" >> "$gitignore"
                print_info "  Added .agent/loop-state/ to .gitignore"
            fi
        fi
        
        ((migrated++))
    done
    
    if [[ $migrated -gt 0 ]]; then
        print_success "Migrated loop state in $migrated repositories"
    else
        print_info "No legacy loop state directories found"
    fi
    
    return 0
}

# Bootstrap: Clone or update repo if running remotely (via curl)
bootstrap_repo() {
    # Detect if running from curl (no script directory context)
    local script_path="${BASH_SOURCE[0]}"
    
    # If script_path is empty or stdin, we're running from curl
    if [[ -z "$script_path" || "$script_path" == "/dev/stdin" || "$script_path" == "bash" ]]; then
        print_info "Remote install detected - bootstrapping repository..."
        
        # Check for git
        if ! command -v git >/dev/null 2>&1; then
            print_error "git is required but not installed"
            echo "Install git first: brew install git (macOS) or sudo apt install git (Linux)"
            exit 1
        fi
        
        # Create parent directory
        mkdir -p "$(dirname "$INSTALL_DIR")"
        
        if [[ -d "$INSTALL_DIR/.git" ]]; then
            print_info "Existing installation found - updating..."
            cd "$INSTALL_DIR" || exit 1
            git pull --ff-only
            if [[ $? -ne 0 ]]; then
                print_warning "Git pull failed - trying reset to origin/main"
                git fetch origin
                git reset --hard origin/main
            fi
        else
            print_info "Cloning aidevops to $INSTALL_DIR..."
            if [[ -d "$INSTALL_DIR" ]]; then
                print_warning "Directory exists but is not a git repo - backing up"
                mv "$INSTALL_DIR" "$INSTALL_DIR.backup.$(date +%Y%m%d_%H%M%S)"
            fi
            git clone "$REPO_URL" "$INSTALL_DIR"
            if [[ $? -ne 0 ]]; then
                print_error "Failed to clone repository"
                exit 1
            fi
        fi
        
        print_success "Repository ready at $INSTALL_DIR"
        
        # Re-execute the local script
        cd "$INSTALL_DIR" || exit 1
        exec bash "./setup.sh" "$@"
    fi
}

# Detect package manager
detect_package_manager() {
    if command -v brew >/dev/null 2>&1; then
        echo "brew"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        echo "unknown"
    fi
}

# Install packages using detected package manager
install_packages() {
    local pkg_manager="$1"
    shift
    local packages=("$@")
    
    case "$pkg_manager" in
        brew)
            brew install "${packages[@]}"
            ;;
        apt)
            sudo apt-get update && sudo apt-get install -y "${packages[@]}"
            ;;
        dnf)
            sudo dnf install -y "${packages[@]}"
            ;;
        yum)
            sudo yum install -y "${packages[@]}"
            ;;
        pacman)
            sudo pacman -S --noconfirm "${packages[@]}"
            ;;
        apk)
            sudo apk add "${packages[@]}"
            ;;
        *)
            return 1
            ;;
    esac
}

# Check system requirements
check_requirements() {
    print_info "Checking system requirements..."
    
    # Ensure Homebrew is in PATH (macOS Apple Silicon)
    if [[ -x "/opt/homebrew/bin/brew" ]] && ! echo "$PATH" | grep -q "/opt/homebrew/bin"; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        print_warning "Homebrew not in PATH - added for this session"
        echo ""
        echo "  To fix permanently, add to ~/.bash_profile or ~/.zshrc:"
        echo "    eval \"\$(/opt/homebrew/bin/brew shellenv)\""
        echo ""
    fi
    
    local missing_deps=()
    
    # Check for required commands
    command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    command -v ssh >/dev/null 2>&1 || missing_deps+=("ssh")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_warning "Missing required dependencies: ${missing_deps[*]}"
        
        local pkg_manager
        pkg_manager=$(detect_package_manager)
        
        if [[ "$pkg_manager" == "unknown" ]]; then
            print_error "Could not detect package manager"
            echo ""
            echo "Please install manually:"
            echo "  macOS: brew install ${missing_deps[*]}"
            echo "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
            echo "  Fedora: sudo dnf install ${missing_deps[*]}"
            echo "  CentOS/RHEL: sudo yum install ${missing_deps[*]}"
            echo "  Arch: sudo pacman -S ${missing_deps[*]}"
            echo "  Alpine: sudo apk add ${missing_deps[*]}"
            exit 1
        fi
        
        echo ""
        read -r -p "Install missing dependencies using $pkg_manager? (y/n): " install_deps
        
        if [[ "$install_deps" == "y" ]]; then
            print_info "Installing ${missing_deps[*]}..."
            if install_packages "$pkg_manager" "${missing_deps[@]}"; then
                print_success "Dependencies installed successfully"
            else
                print_error "Failed to install dependencies"
                exit 1
            fi
        else
            print_error "Cannot continue without required dependencies"
            exit 1
        fi
    fi
    
    print_success "All required dependencies found"
}

# Check for optional dependencies
check_optional_deps() {
    print_info "Checking optional dependencies..."
    
    local missing_optional=()
    
    if ! command -v sshpass >/dev/null 2>&1; then
        missing_optional+=("sshpass")
    else
        print_success "sshpass found"
    fi
    
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        print_warning "Missing optional dependencies: ${missing_optional[*]}"
        echo "  sshpass - needed for password-based SSH (like Hostinger)"
        
        local pkg_manager
        pkg_manager=$(detect_package_manager)
        
        if [[ "$pkg_manager" != "unknown" ]]; then
            read -r -p "Install optional dependencies using $pkg_manager? (y/n): " install_optional
            
            if [[ "$install_optional" == "y" ]]; then
                print_info "Installing ${missing_optional[*]}..."
                if install_packages "$pkg_manager" "${missing_optional[@]}"; then
                    print_success "Optional dependencies installed"
                else
                    print_warning "Failed to install optional dependencies (non-critical)"
                fi
            else
                print_info "Skipped optional dependencies"
            fi
        fi
    fi
    return 0
}

# Setup Git CLI tools
setup_git_clis() {
    print_info "Setting up Git CLI tools..."
    
    local cli_tools=()
    local missing_packages=()
    local missing_names=()
    
    # Check for GitHub CLI
    if ! command -v gh >/dev/null 2>&1; then
        missing_packages+=("gh")
        missing_names+=("GitHub CLI")
    else
        cli_tools+=("GitHub CLI")
    fi
    
    # Check for GitLab CLI
    if ! command -v glab >/dev/null 2>&1; then
        missing_packages+=("glab")
        missing_names+=("GitLab CLI")
    else
        cli_tools+=("GitLab CLI")
    fi
    
    # Report found tools
    if [[ ${#cli_tools[@]} -gt 0 ]]; then
        print_success "Found Git CLI tools: ${cli_tools[*]}"
    fi
    
    # Offer to install missing tools
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        print_warning "Missing Git CLI tools: ${missing_names[*]}"
        echo "  These provide enhanced Git platform integration (repos, PRs, issues)"
        
        local pkg_manager
        pkg_manager=$(detect_package_manager)
        
        if [[ "$pkg_manager" != "unknown" ]]; then
            echo ""
            read -r -p "Install Git CLI tools (${missing_packages[*]}) using $pkg_manager? (y/n): " install_git_clis
            
            if [[ "$install_git_clis" == "y" ]]; then
                print_info "Installing ${missing_packages[*]}..."
                if install_packages "$pkg_manager" "${missing_packages[@]}"; then
                    print_success "Git CLI tools installed"
                    echo ""
                    echo "📋 Next steps - authenticate each CLI:"
                    for pkg in "${missing_packages[@]}"; do
                        case "$pkg" in
                            gh) echo "  • gh auth login" ;;
                            glab) echo "  • glab auth login" ;;
                        esac
                    done
                else
                    print_warning "Failed to install some Git CLI tools (non-critical)"
                fi
            else
                print_info "Skipped Git CLI tools installation"
                echo ""
                echo "📋 Manual installation:"
                echo "  macOS: brew install ${missing_packages[*]}"
                echo "  Ubuntu: sudo apt install ${missing_packages[*]}"
                echo "  Fedora: sudo dnf install ${missing_packages[*]}"
            fi
        else
            echo ""
            echo "📋 Manual installation:"
            echo "  macOS: brew install ${missing_packages[*]}"
            echo "  Ubuntu: sudo apt install ${missing_packages[*]}"
            echo "  Fedora: sudo dnf install ${missing_packages[*]}"
        fi
    else
        print_success "All Git CLI tools installed and ready!"
    fi
    
    # Check for Gitea CLI separately (not in standard package managers)
    if ! command -v tea >/dev/null 2>&1; then
        print_info "Gitea CLI (tea) not found - install manually if needed:"
        echo "  go install code.gitea.io/tea/cmd/tea@latest"
        echo "  Or download from: https://dl.gitea.io/tea/"
    else
        print_success "Gitea CLI (tea) found"
    fi
    
    return 0
}

# Setup file discovery tools (fd, ripgrep) for efficient file searching
setup_file_discovery_tools() {
    print_info "Setting up file discovery tools..."
    
    local missing_tools=()
    local missing_packages=()
    local missing_names=()
    
    # Check for fd (fd-find)
    if ! command -v fd >/dev/null 2>&1; then
        missing_tools+=("fd")
        missing_packages+=("fd")
        missing_names+=("fd (fast file finder)")
    else
        local fd_version
        fd_version=$(fd --version 2>/dev/null | head -1 || echo "unknown")
        print_success "fd found: $fd_version"
    fi
    
    # Check for ripgrep
    if ! command -v rg >/dev/null 2>&1; then
        missing_tools+=("rg")
        missing_packages+=("ripgrep")
        missing_names+=("ripgrep (fast content search)")
    else
        local rg_version
        rg_version=$(rg --version 2>/dev/null | head -1 || echo "unknown")
        print_success "ripgrep found: $rg_version"
    fi
    
    # Offer to install missing tools
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        print_warning "Missing file discovery tools: ${missing_names[*]}"
        echo ""
        echo "  These tools provide 10x faster file discovery than built-in glob:"
        echo "    fd      - Fast alternative to 'find', respects .gitignore"
        echo "    ripgrep - Fast alternative to 'grep', respects .gitignore"
        echo ""
        echo "  AI agents use these for efficient codebase navigation."
        echo ""
        
        local pkg_manager
        pkg_manager=$(detect_package_manager)
        
        if [[ "$pkg_manager" != "unknown" ]]; then
            local install_fd_tools="y"
            if [[ "$INTERACTIVE_MODE" == "true" ]]; then
                read -r -p "Install file discovery tools (${missing_packages[*]}) using $pkg_manager? (y/n): " install_fd_tools
            fi
            
            if [[ "$install_fd_tools" == "y" ]]; then
                print_info "Installing ${missing_packages[*]}..."
                
                # Handle package name differences across package managers
                local actual_packages=()
                for pkg in "${missing_packages[@]}"; do
                    case "$pkg_manager" in
                        apt)
                            # Debian/Ubuntu uses fd-find instead of fd
                            if [[ "$pkg" == "fd" ]]; then
                                actual_packages+=("fd-find")
                            else
                                actual_packages+=("$pkg")
                            fi
                            ;;
                        *)
                            actual_packages+=("$pkg")
                            ;;
                    esac
                done
                
                if install_packages "$pkg_manager" "${actual_packages[@]}"; then
                    print_success "File discovery tools installed"
                    
                    # On Debian/Ubuntu, fd is installed as fdfind - create alias in all existing shell rc files
                    if [[ "$pkg_manager" == "apt" ]] && command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
                        local rc_files=("$HOME/.bashrc" "$HOME/.zshrc")
                        local added_to=""
                        
                        for rc_file in "${rc_files[@]}"; do
                            [[ ! -f "$rc_file" ]] && continue
                            
                            if ! grep -q 'alias fd="fdfind"' "$rc_file" 2>/dev/null; then
                                if { echo '' >> "$rc_file" && \
                                     echo '# fd-find alias for Debian/Ubuntu (added by aidevops)' >> "$rc_file" && \
                                     echo 'alias fd="fdfind"' >> "$rc_file"; }; then
                                    added_to="${added_to:+$added_to, }$rc_file"
                                fi
                            fi
                        done
                        
                        if [[ -n "$added_to" ]]; then
                            print_success "Added alias fd=fdfind to: $added_to"
                            echo "  Restart your shell to activate"
                        else
                            print_success "fd alias already configured"
                        fi
                    fi
                else
                    print_warning "Failed to install some file discovery tools (non-critical)"
                fi
            else
                print_info "Skipped file discovery tools installation"
                echo ""
                echo "  Manual installation:"
                echo "    macOS:        brew install fd ripgrep"
                echo "    Ubuntu/Debian: sudo apt install fd-find ripgrep"
                echo "    Fedora:       sudo dnf install fd-find ripgrep"
                echo "    Arch:         sudo pacman -S fd ripgrep"
            fi
        else
            echo ""
            echo "  Manual installation:"
            echo "    macOS:        brew install fd ripgrep"
            echo "    Ubuntu/Debian: sudo apt install fd-find ripgrep"
            echo "    Fedora:       sudo dnf install fd-find ripgrep"
            echo "    Arch:         sudo pacman -S fd ripgrep"
        fi
    else
        print_success "All file discovery tools installed!"
    fi
    
    return 0
}

# Setup Worktrunk - Git worktree management for parallel AI agent workflows
setup_worktrunk() {
    print_info "Setting up Worktrunk (git worktree management)..."
    
    # Check if worktrunk (wt) is already installed
    if command -v wt >/dev/null 2>&1; then
        local wt_version
        wt_version=$(wt --version 2>/dev/null | head -1 || echo "unknown")
        print_success "Worktrunk already installed: $wt_version"
        
        # Check if shell integration is installed
        local shell_name
        shell_name=$(basename "${SHELL:-/bin/bash}")
        local shell_rc=""
        case "$shell_name" in
            zsh)  shell_rc="$HOME/.zshrc" ;;
            bash) 
                if [[ "$(uname)" == "Darwin" ]]; then
                    shell_rc="$HOME/.bash_profile"
                else
                    shell_rc="$HOME/.bashrc"
                fi
                ;;
        esac
        
        if [[ -n "$shell_rc" ]] && [[ -f "$shell_rc" ]]; then
            if ! grep -q "worktrunk" "$shell_rc" 2>/dev/null; then
                print_info "Shell integration not detected"
                read -r -p "Install Worktrunk shell integration (enables 'wt switch' to change directories)? (y/n): " install_shell
                if [[ "$install_shell" == "y" ]]; then
                    if wt config shell install 2>/dev/null; then
                        print_success "Shell integration installed"
                        print_info "Restart your terminal or run: source $shell_rc"
                    else
                        print_warning "Shell integration failed - run manually: wt config shell install"
                    fi
                fi
            else
                print_success "Shell integration already configured"
            fi
        fi
        return 0
    fi
    
    # Worktrunk not installed - offer to install
    print_info "Worktrunk makes git worktrees as easy as branches"
    echo "  • wt switch feat     - Switch/create worktree (with cd)"
    echo "  • wt list            - List worktrees with CI status"
    echo "  • wt merge           - Squash/rebase/merge + cleanup"
    echo "  • Hooks for automated setup (npm install, etc.)"
    echo ""
    echo "  Note: aidevops also includes worktree-helper.sh as a fallback"
    echo ""
    
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    if [[ "$pkg_manager" == "brew" ]]; then
        read -r -p "Install Worktrunk via Homebrew? (y/n): " install_wt
        
        if [[ "$install_wt" == "y" ]]; then
            print_info "Installing Worktrunk..."
            if brew install max-sixty/worktrunk/wt 2>/dev/null; then
                print_success "Worktrunk installed"
                
                # Install shell integration
                print_info "Installing shell integration..."
                if wt config shell install 2>/dev/null; then
                    print_success "Shell integration installed"
                    print_info "Restart your terminal or source your shell config"
                else
                    print_warning "Shell integration failed - run manually: wt config shell install"
                fi
                
                echo ""
                print_info "Quick start:"
                echo "  wt switch feature/my-feature  # Create/switch to worktree"
                echo "  wt list                       # List all worktrees"
                echo "  wt merge                      # Merge and cleanup"
                echo ""
                print_info "Documentation: ~/.aidevops/agents/tools/git/worktrunk.md"
            else
                print_warning "Homebrew installation failed"
                echo "  Try: cargo install worktrunk && wt config shell install"
            fi
        else
            print_info "Skipped Worktrunk installation"
            print_info "Install later: brew install max-sixty/worktrunk/wt"
            print_info "Fallback available: ~/.aidevops/agents/scripts/worktree-helper.sh"
        fi
    elif command -v cargo >/dev/null 2>&1; then
        read -r -p "Install Worktrunk via Cargo? (y/n): " install_wt
        
        if [[ "$install_wt" == "y" ]]; then
            print_info "Installing Worktrunk via Cargo..."
            if cargo install worktrunk 2>/dev/null; then
                print_success "Worktrunk installed"
                
                # Install shell integration
                if wt config shell install 2>/dev/null; then
                    print_success "Shell integration installed"
                else
                    print_warning "Shell integration failed - run manually: wt config shell install"
                fi
            else
                print_warning "Cargo installation failed"
            fi
        else
            print_info "Skipped Worktrunk installation"
        fi
    else
        print_warning "Worktrunk not installed"
        echo ""
        echo "  Install options:"
        echo "    macOS/Linux (Homebrew): brew install max-sixty/worktrunk/wt"
        echo "    Cargo:                  cargo install worktrunk"
        echo "    Windows:                winget install max-sixty.worktrunk"
        echo ""
        echo "  After install: wt config shell install"
        echo ""
        print_info "Fallback available: ~/.aidevops/agents/scripts/worktree-helper.sh"
    fi
    
    return 0
}

# Setup recommended tools (Tabby terminal, Zed editor)
setup_recommended_tools() {
    print_info "Checking recommended development tools..."
    
    local missing_tools=()
    local missing_names=()
    
    # Check for Tabby terminal
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS - check Applications folder
        if [[ ! -d "/Applications/Tabby.app" ]]; then
            missing_tools+=("tabby")
            missing_names+=("Tabby (modern terminal)")
        else
            print_success "Tabby terminal found"
        fi
    elif [[ "$(uname)" == "Linux" ]]; then
        # Linux - check if tabby command exists
        if ! command -v tabby >/dev/null 2>&1; then
            missing_tools+=("tabby")
            missing_names+=("Tabby (modern terminal)")
        else
            print_success "Tabby terminal found"
        fi
    fi
    
    # Check for Zed editor
    local zed_exists=false
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS - check Applications folder
        if [[ ! -d "/Applications/Zed.app" ]]; then
            missing_tools+=("zed")
            missing_names+=("Zed (AI-native editor)")
        else
            print_success "Zed editor found"
            zed_exists=true
        fi
    elif [[ "$(uname)" == "Linux" ]]; then
        # Linux - check if zed command exists
        if ! command -v zed >/dev/null 2>&1; then
            missing_tools+=("zed")
            missing_names+=("Zed (AI-native editor)")
        else
            print_success "Zed editor found"
            zed_exists=true
        fi
    fi
    
    # Check for OpenCode extension in existing Zed installation
    if [[ "$zed_exists" == "true" ]]; then
        local zed_extensions_dir=""
        if [[ "$(uname)" == "Darwin" ]]; then
            zed_extensions_dir="$HOME/Library/Application Support/Zed/extensions/installed"
        elif [[ "$(uname)" == "Linux" ]]; then
            zed_extensions_dir="$HOME/.local/share/zed/extensions/installed"
        fi
        
        if [[ -d "$zed_extensions_dir" ]]; then
            if [[ ! -d "$zed_extensions_dir/opencode" ]]; then
                read -r -p "Install OpenCode extension for Zed? (y/n): " install_opencode_ext
                if [[ "$install_opencode_ext" == "y" ]]; then
                    print_info "Installing OpenCode extension..."
                    if [[ "$(uname)" == "Darwin" ]]; then
                        open "zed://extension/opencode" 2>/dev/null
                        print_success "OpenCode extension install triggered"
                        print_info "Zed will open and prompt to install the extension"
                    elif [[ "$(uname)" == "Linux" ]]; then
                        xdg-open "zed://extension/opencode" 2>/dev/null || \
                        print_info "Open Zed and install 'opencode' from Extensions"
                    fi
                fi
            else
                print_success "OpenCode extension already installed in Zed"
            fi
        fi
    fi
    
    # Offer to install missing tools
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        print_warning "Missing recommended tools: ${missing_names[*]}"
        echo "  Tabby - Modern terminal with profiles, SSH manager, split panes"
        echo "  Zed   - High-performance AI-native code editor"
        echo ""
        
        # Install Tabby if missing
        if [[ " ${missing_tools[*]} " =~ " tabby " ]]; then
            read -r -p "Install Tabby terminal? (y/n): " install_tabby
            
            if [[ "$install_tabby" == "y" ]]; then
                print_info "Installing Tabby..."
                if [[ "$(uname)" == "Darwin" ]]; then
                    if command -v brew >/dev/null 2>&1; then
                        brew install --cask tabby
                        if [[ $? -eq 0 ]]; then
                            print_success "Tabby installed successfully"
                        else
                            print_warning "Failed to install Tabby via Homebrew"
                            echo "  Download manually: https://github.com/Eugeny/tabby/releases/latest"
                        fi
                    else
                        print_warning "Homebrew not found"
                        echo "  Download manually: https://github.com/Eugeny/tabby/releases/latest"
                    fi
                elif [[ "$(uname)" == "Linux" ]]; then
                    local pkg_manager
                    pkg_manager=$(detect_package_manager)
                    case "$pkg_manager" in
                        apt)
                            # Add packagecloud repo for Tabby
                            print_info "Adding Tabby repository..."
                            curl -s https://packagecloud.io/install/repositories/eugeny/tabby/script.deb.sh | sudo bash
                            sudo apt-get install -y tabby-terminal
                            ;;
                        dnf|yum)
                            print_info "Adding Tabby repository..."
                            curl -s https://packagecloud.io/install/repositories/eugeny/tabby/script.rpm.sh | sudo bash
                            sudo "$pkg_manager" install -y tabby-terminal
                            ;;
                        pacman)
                            # AUR package
                            print_info "Tabby available in AUR as 'tabby-bin'"
                            echo "  Install with: yay -S tabby-bin"
                            ;;
                        *)
                            echo "  Download manually: https://github.com/Eugeny/tabby/releases/latest"
                            ;;
                    esac
                fi
            else
                print_info "Skipped Tabby installation"
            fi
        fi
        
        # Install Zed if missing
        if [[ " ${missing_tools[*]} " =~ " zed " ]]; then
            read -r -p "Install Zed editor? (y/n): " install_zed
            
            if [[ "$install_zed" == "y" ]]; then
                print_info "Installing Zed..."
                local zed_installed=false
                if [[ "$(uname)" == "Darwin" ]]; then
                    if command -v brew >/dev/null 2>&1; then
                        brew install --cask zed
                        if [[ $? -eq 0 ]]; then
                            print_success "Zed installed successfully"
                            zed_installed=true
                        else
                            print_warning "Failed to install Zed via Homebrew"
                            echo "  Download manually: https://zed.dev/download"
                        fi
                    else
                        print_warning "Homebrew not found"
                        echo "  Download manually: https://zed.dev/download"
                    fi
                elif [[ "$(uname)" == "Linux" ]]; then
                    # Zed provides an install script for Linux
                    print_info "Running Zed install script..."
                    curl -f https://zed.dev/install.sh | sh
                    if [[ $? -eq 0 ]]; then
                        print_success "Zed installed successfully"
                        zed_installed=true
                    else
                        print_warning "Failed to install Zed"
                        echo "  See: https://zed.dev/docs/linux"
                    fi
                fi
                
                # Install OpenCode extension for Zed
                if [[ "$zed_installed" == "true" ]]; then
                    read -r -p "Install OpenCode extension for Zed? (y/n): " install_opencode_ext
                    if [[ "$install_opencode_ext" == "y" ]]; then
                        print_info "Installing OpenCode extension..."
                        if [[ "$(uname)" == "Darwin" ]]; then
                            open "zed://extension/opencode" 2>/dev/null
                            print_success "OpenCode extension install triggered"
                            print_info "Zed will open and prompt to install the extension"
                        elif [[ "$(uname)" == "Linux" ]]; then
                            xdg-open "zed://extension/opencode" 2>/dev/null || \
                            print_info "Open Zed and install 'opencode' from Extensions (Cmd+Shift+X)"
                        fi
                    fi
                fi
            else
                print_info "Skipped Zed installation"
            fi
        fi
    else
        print_success "All recommended tools installed!"
    fi
    
    return 0
}

# Setup MiniSim - iOS/Android emulator launcher (macOS only)
setup_minisim() {
    # Only available on macOS
    if [[ "$(uname)" != "Darwin" ]]; then
        return 0
    fi
    
    print_info "Setting up MiniSim (iOS/Android emulator launcher)..."
    
    # Check if MiniSim is already installed
    if [[ -d "/Applications/MiniSim.app" ]]; then
        print_success "MiniSim already installed"
        print_info "Global shortcut: Option + Shift + E"
        return 0
    fi
    
    # Check if Xcode or Android Studio is installed (MiniSim needs at least one)
    local has_xcode=false
    local has_android=false
    
    if command -v xcrun >/dev/null 2>&1 && xcrun simctl list devices >/dev/null 2>&1; then
        has_xcode=true
    fi
    
    if [[ -n "${ANDROID_HOME:-}" ]] || [[ -n "${ANDROID_SDK_ROOT:-}" ]] || [[ -d "$HOME/Library/Android/sdk" ]]; then
        has_android=true
    fi
    
    if [[ "$has_xcode" == "false" && "$has_android" == "false" ]]; then
        print_info "MiniSim requires Xcode (iOS) or Android Studio (Android)"
        print_info "Install one of these first, then re-run setup to install MiniSim"
        return 0
    fi
    
    # Show what's available
    local available_for=""
    if [[ "$has_xcode" == "true" ]]; then
        available_for="iOS simulators"
    fi
    if [[ "$has_android" == "true" ]]; then
        if [[ -n "$available_for" ]]; then
            available_for="$available_for and Android emulators"
        else
            available_for="Android emulators"
        fi
    fi
    
    print_info "MiniSim is a menu bar app for launching $available_for"
    echo "  Features:"
    echo "    - Global shortcut: Option + Shift + E"
    echo "    - Launch/manage iOS simulators and Android emulators"
    echo "    - Copy device UDID/ADB ID"
    echo "    - Cold boot Android emulators"
    echo "    - Run Android emulators without audio (saves Bluetooth battery)"
    echo ""
    
    # Check if Homebrew is available
    if ! command -v brew >/dev/null 2>&1; then
        print_warning "Homebrew not found - cannot install MiniSim automatically"
        echo "  Install manually: https://github.com/okwasniewski/MiniSim/releases"
        return 0
    fi
    
    local install_minisim
    read -r -p "Install MiniSim? (y/n): " install_minisim
    
    if [[ "$install_minisim" == "y" ]]; then
        print_info "Installing MiniSim..."
        if brew install --cask minisim; then
            print_success "MiniSim installed successfully"
            print_info "Global shortcut: Option + Shift + E"
            print_info "Documentation: ~/.aidevops/agents/tools/mobile/minisim.md"
        else
            print_warning "Failed to install MiniSim via Homebrew"
            echo "  Install manually: https://github.com/okwasniewski/MiniSim/releases"
        fi
    else
        print_info "Skipped MiniSim installation"
        print_info "Install later: brew install --cask minisim"
    fi
    
    return 0
}

# Setup SSH key if needed
setup_ssh_key() {
    print_info "Checking SSH key setup..."
    
    if [[ ! -f ~/.ssh/id_ed25519 ]]; then
        print_warning "Ed25519 SSH key not found"
        read -r -p "Generate new Ed25519 SSH key? (y/n): " generate_key
        
        if [[ "$generate_key" == "y" ]]; then
            read -r -p "Enter your email address: " email
            ssh-keygen -t ed25519 -C "$email"
            print_success "SSH key generated"
        else
            print_info "Skipping SSH key generation"
        fi
    else
        print_success "Ed25519 SSH key found"
    fi
    return 0
}

# Setup configuration files
setup_configs() {
    print_info "Setting up configuration files..."
    
    # Create configs directory if it doesn't exist
    mkdir -p configs
    
    # Copy template configs if they don't exist
    for template in configs/*.txt; do
        if [[ -f "$template" ]]; then
            config_file="${template%.txt}"
            if [[ ! -f "$config_file" ]]; then
                cp "$template" "$config_file"
                print_success "Created $(basename "$config_file")"
                print_warning "Please edit $(basename "$config_file") with your actual credentials"
            else
                print_info "Found existing config: $(basename "$config_file") - Skipping"
            fi
        fi
    done
    
    return 0
}

# Set proper permissions
set_permissions() {
    print_info "Setting proper file permissions..."
    
    # Make scripts executable
    chmod +x ./*.sh
    chmod +x .agent/scripts/*.sh
    chmod +x ssh/*.sh
    
    # Secure configuration files
    chmod 600 configs/*.json 2>/dev/null || true
    
    print_success "File permissions set"
    return 0
}

# Add ~/.local/bin to PATH in shell config
add_local_bin_to_path() {
    local shell_rc=""
    local path_line='export PATH="$HOME/.local/bin:$PATH"'
    
    # Detect shell config file
    if [[ "$SHELL" == *"zsh"* ]] || [[ -n "$ZSH_VERSION" ]]; then
        shell_rc="$HOME/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]] || [[ -n "$BASH_VERSION" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            shell_rc="$HOME/.bash_profile"
        else
            shell_rc="$HOME/.bashrc"
        fi
    elif [[ -f "$HOME/.zshrc" ]]; then
        shell_rc="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
        shell_rc="$HOME/.bashrc"
    elif [[ -f "$HOME/.bash_profile" ]]; then
        shell_rc="$HOME/.bash_profile"
    fi
    
    if [[ -z "$shell_rc" ]]; then
        print_warning "Could not detect shell config file"
        print_info "Add this to your shell config: $path_line"
        return 0
    fi
    
    # Create the rc file if it doesn't exist
    if [[ ! -f "$shell_rc" ]]; then
        touch "$shell_rc"
    fi
    
    # Check if already added
    if grep -q '\.local/bin' "$shell_rc" 2>/dev/null; then
        print_info "~/.local/bin already in PATH (found in $shell_rc)"
        return 0
    fi
    
    # Add to shell config
    echo "" >> "$shell_rc"
    echo "# Added by aidevops setup" >> "$shell_rc"
    echo "$path_line" >> "$shell_rc"
    
    print_success "Added ~/.local/bin to PATH in $shell_rc"
    print_info "Run 'source $shell_rc' or restart your terminal to use 'aidevops' command"
    
    # Also export for current session
    export PATH="$HOME/.local/bin:$PATH"
    
    return 0
}

# Install aidevops CLI command
install_aidevops_cli() {
    print_info "Installing aidevops CLI command..."
    
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local cli_source="$script_dir/aidevops.sh"
    local cli_target="/usr/local/bin/aidevops"
    
    if [[ ! -f "$cli_source" ]]; then
        print_warning "aidevops.sh not found - skipping CLI installation"
        return 0
    fi
    
    # Check if we can write to /usr/local/bin
    if [[ -w "/usr/local/bin" ]]; then
        # Direct symlink
        ln -sf "$cli_source" "$cli_target"
        print_success "Installed aidevops command to $cli_target"
    elif [[ -w "$HOME/.local/bin" ]] || mkdir -p "$HOME/.local/bin" 2>/dev/null; then
        # Use ~/.local/bin instead
        cli_target="$HOME/.local/bin/aidevops"
        ln -sf "$cli_source" "$cli_target"
        print_success "Installed aidevops command to $cli_target"
        
        # Check if ~/.local/bin is in PATH and add it if not
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            add_local_bin_to_path
        fi
    else
        # Need sudo
        print_info "Installing aidevops command requires sudo..."
        if sudo ln -sf "$cli_source" "$cli_target"; then
            print_success "Installed aidevops command to $cli_target"
        else
            print_warning "Could not install aidevops command globally"
            print_info "You can run it directly: $cli_source"
        fi
    fi
    
    return 0
}

# Setup shell aliases
setup_aliases() {
    print_info "Setting up shell aliases..."
    
    local shell_rc=""
    local shell_name=""
    
    # Detect shell - check $SHELL first, then try to detect from process
    if [[ "$SHELL" == *"zsh"* ]]; then
        shell_rc="$HOME/.zshrc"
        shell_name="zsh"
    elif [[ "$SHELL" == *"bash"* ]]; then
        # macOS: use .bash_profile (login shell), Linux: use .bashrc
        if [[ "$(uname)" == "Darwin" ]]; then
            shell_rc="$HOME/.bash_profile"
        else
            shell_rc="$HOME/.bashrc"
        fi
        shell_name="bash"
    elif [[ "$SHELL" == *"fish"* ]]; then
        shell_rc="$HOME/.config/fish/config.fish"
        shell_name="fish"
    elif [[ "$SHELL" == *"ksh"* ]]; then
        shell_rc="$HOME/.kshrc"
        shell_name="ksh"
    elif [[ -n "$ZSH_VERSION" ]]; then
        shell_rc="$HOME/.zshrc"
        shell_name="zsh"
    elif [[ -n "$BASH_VERSION" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            shell_rc="$HOME/.bash_profile"
        else
            shell_rc="$HOME/.bashrc"
        fi
        shell_name="bash"
    else
        # Fallback: check common rc files
        if [[ -f "$HOME/.zshrc" ]]; then
            shell_rc="$HOME/.zshrc"
            shell_name="zsh"
        elif [[ -f "$HOME/.bashrc" ]]; then
            shell_rc="$HOME/.bashrc"
            shell_name="bash"
        elif [[ -f "$HOME/.bash_profile" ]]; then
            shell_rc="$HOME/.bash_profile"
            shell_name="bash"
        else
            print_warning "Could not detect shell configuration file"
            print_info "Supported shells: bash, zsh, fish, ksh"
            print_info "You can manually add aliases to your shell config"
            return 0
        fi
    fi
    
    # Create the rc file if it doesn't exist (common on fresh systems)
    if [[ ! -f "$shell_rc" ]]; then
        print_info "Creating $shell_rc (file did not exist)"
        touch "$shell_rc"
    fi
    
    # Check if aliases already exist
    if grep -q "# AI Assistant Server Access" "$shell_rc" 2>/dev/null; then
        print_info "Server Access aliases already configured in $shell_rc - Skipping"
        return 0
    fi
    
    print_info "Detected shell: $shell_name"
    read -r -p "Add shell aliases to $shell_rc? (y/n): " add_aliases
    
    if [[ "$add_aliases" == "y" ]]; then
        # Fish shell uses different syntax
        if [[ "$shell_name" == "fish" ]]; then
            mkdir -p "$HOME/.config/fish"
            cat >> "$shell_rc" << 'EOF'

# AI Assistant Server Access Framework
alias servers './.agent/scripts/servers-helper.sh'
alias servers-list './.agent/scripts/servers-helper.sh list'
alias hostinger './.agent/scripts/hostinger-helper.sh'
alias hetzner './.agent/scripts/hetzner-helper.sh'
alias aws-helper './.agent/scripts/aws-helper.sh'
EOF
        else
            # Bash, zsh, ksh use same syntax
            cat >> "$shell_rc" << 'EOF'

# AI Assistant Server Access Framework
alias servers='./.agent/scripts/servers-helper.sh'
alias servers-list='./.agent/scripts/servers-helper.sh list'
alias hostinger='./.agent/scripts/hostinger-helper.sh'
alias hetzner='./.agent/scripts/hetzner-helper.sh'
alias aws-helper='./.agent/scripts/aws-helper.sh'
EOF
        fi
        print_success "Aliases added to $shell_rc"
        print_info "Run 'source $shell_rc' or restart your terminal to use aliases"
    else
        print_info "Skipped alias setup by user request"
    fi
    return 0
}

# Setup terminal title integration (syncs tab title with git repo/branch)
setup_terminal_title() {
    print_info "Setting up terminal title integration..."
    
    local setup_script=".agent/scripts/terminal-title-setup.sh"
    
    if [[ ! -f "$setup_script" ]]; then
        print_warning "Terminal title setup script not found - skipping"
        return 0
    fi
    
    # Check if already installed
    local shell_name
    shell_name=$(basename "${SHELL:-/bin/bash}")
    local rc_file=""
    
    case "$shell_name" in
        zsh)  rc_file="$HOME/.zshrc" ;;
        bash) rc_file="$HOME/.bashrc" ;;
        fish) rc_file="$HOME/.config/fish/config.fish" ;;
    esac
    
    if [[ -n "$rc_file" ]] && [[ -f "$rc_file" ]] && grep -q "aidevops terminal-title" "$rc_file" 2>/dev/null; then
        print_info "Terminal title integration already configured in $rc_file - Skipping"
        return 0
    fi
    
    # Show current status before asking
    echo ""
    print_info "Terminal title integration syncs your terminal tab with git repo/branch"
    print_info "Example: Tab shows 'aidevops/feature/xyz' when in that branch"
    echo ""
    echo "Current status:"
    
    # Shell info
    local shell_info="$shell_name"
    if [[ "$shell_name" == "zsh" ]] && [[ -d "$HOME/.oh-my-zsh" ]]; then
        shell_info="$shell_name (Oh-My-Zsh)"
    fi
    echo "  Shell: $shell_info"
    
    # Tabby info
    local tabby_config="$HOME/Library/Application Support/tabby/config.yaml"
    if [[ -f "$tabby_config" ]]; then
        local disabled_count
        disabled_count=$(grep -c "disableDynamicTitle: true" "$tabby_config" 2>/dev/null || echo "0")
        if [[ "$disabled_count" -gt 0 ]]; then
            echo "  Tabby: detected, dynamic titles disabled in $disabled_count profile(s) (will fix)"
        else
            echo "  Tabby: detected, dynamic titles enabled"
        fi
    fi
    
    echo ""
    read -r -p "Install terminal title integration? (y/n): " install_title
    
    if [[ "$install_title" == "y" ]]; then
        if bash "$setup_script" install; then
            print_success "Terminal title integration installed"
        else
            print_warning "Terminal title setup encountered issues (non-critical)"
        fi
    else
        print_info "Skipped terminal title setup by user request"
        print_info "You can install later with: ~/.aidevops/agents/scripts/terminal-title-setup.sh install"
    fi
    
    return 0
}

# Deploy AI assistant templates
deploy_ai_templates() {
    print_info "Deploying AI assistant templates..."

    if [[ -f "templates/deploy-templates.sh" ]]; then
        print_info "Running template deployment script..."
        bash templates/deploy-templates.sh

        if [[ $? -eq 0 ]]; then
            print_success "AI assistant templates deployed successfully"
        else
            print_warning "Template deployment encountered issues (non-critical)"
        fi
    else
        print_warning "Template deployment script not found - skipping"
    fi
    return 0
}

# Extract OpenCode prompts from binary (for Plan+ system-reminder)
# Must run before deploy_aidevops_agents so the cache exists for injection
extract_opencode_prompts() {
    local extract_script=".agent/scripts/extract-opencode-prompts.sh"
    if [[ -f "$extract_script" ]]; then
        if bash "$extract_script"; then
            print_success "OpenCode prompts extracted"
        else
            print_warning "OpenCode prompt extraction encountered issues (non-critical)"
        fi
    fi
    return 0
}

# Check if upstream OpenCode prompts have drifted from our synced version
check_opencode_prompt_drift() {
    local drift_script=".agent/scripts/opencode-prompt-drift-check.sh"
    if [[ -f "$drift_script" ]]; then
        local output exit_code=0
        output=$(bash "$drift_script" --quiet 2>/dev/null) || exit_code=$?
        if [[ "$exit_code" -eq 1 && "$output" == PROMPT_DRIFT* ]]; then
            local local_hash upstream_hash
            local_hash=$(echo "$output" | cut -d'|' -f2)
            upstream_hash=$(echo "$output" | cut -d'|' -f3)
            print_warning "OpenCode upstream prompt has changed (${local_hash} → ${upstream_hash})"
            print_info "  Review: https://github.com/anomalyco/opencode/compare/${local_hash}...${upstream_hash}"
            print_info "  Update .agent/prompts/build.txt if needed"
        elif [[ "$exit_code" -eq 0 ]]; then
            print_success "OpenCode prompt in sync with upstream"
        else
            print_warning "Could not check prompt drift (network issue or missing dependency)"
        fi
    fi
    return 0
}

# Deploy aidevops agents to user location
deploy_aidevops_agents() {
    print_info "Deploying aidevops agents to ~/.aidevops/agents/..."
    
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local source_dir="$script_dir/.agent"
    local target_dir="$HOME/.aidevops/agents"
    
    # Validate source directory exists (catches curl install from wrong directory)
    if [[ ! -d "$source_dir" ]]; then
        print_error "Agent source directory not found: $source_dir"
        print_info "This usually means setup.sh was run from the wrong directory."
        print_info "The bootstrap should have cloned the repo and re-executed."
        print_info ""
        print_info "To fix manually:"
        print_info "  cd ~/Git/aidevops && ./setup.sh"
        return 1
    fi
    
    # Create backup if target exists (with rotation)
    if [[ -d "$target_dir" ]]; then
        create_backup_with_rotation "$target_dir" "agents"
    fi
    
    # Create target directory and copy agents
    mkdir -p "$target_dir"
    
    # If clean mode, remove stale files first
    if [[ "$CLEAN_MODE" == "true" ]]; then
        print_info "Clean mode: removing stale files from $target_dir"
        rm -rf "${target_dir:?}"/*
    fi
    
    # Copy all agent files and folders, excluding:
    # - loop-state/ (local runtime state, not agents)
    # Use rsync for selective exclusion
    if command -v rsync &>/dev/null; then
        rsync -a --exclude='loop-state/' "$source_dir/" "$target_dir/"
    else
        # Fallback: copy then remove loop-state
        cp -R "$source_dir"/* "$target_dir/"
        rm -rf "$target_dir/loop-state" 2>/dev/null || true
    fi
    
    if [[ $? -eq 0 ]]; then
        print_success "Deployed agents to $target_dir"
        
        # Set permissions on scripts
        chmod +x "$target_dir/scripts/"*.sh 2>/dev/null || true
        
        # Count what was deployed
        local agent_count
        agent_count=$(find "$target_dir" -name "*.md" -type f | wc -l | tr -d ' ')
        local script_count
        script_count=$(find "$target_dir/scripts" -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')
        
        print_info "Deployed $agent_count agent files and $script_count scripts"
        
        # Copy VERSION file from repo root to deployed agents
        if [[ -f "$script_dir/VERSION" ]]; then
            if cp "$script_dir/VERSION" "$target_dir/VERSION"; then
                print_info "Copied VERSION file to deployed agents"
            else
                print_warning "Failed to copy VERSION file (Plan+ may not read version correctly)"
            fi
        else
            print_warning "VERSION file not found in repo root"
        fi
        
        # Inject extracted OpenCode plan-reminder into Plan+ if available
        local plan_reminder="$HOME/.aidevops/cache/opencode-prompts/plan-reminder.txt"
        local plan_plus="$target_dir/plan-plus.md"
        if [[ -f "$plan_reminder" && -f "$plan_plus" ]]; then
            # Check if plan-plus.md has the placeholder marker
            if grep -q "OPENCODE-PLAN-REMINDER-INJECT" "$plan_plus"; then
                # Replace placeholder with extracted content
                local reminder_content
                reminder_content=$(cat "$plan_reminder")
                # Use awk to replace the placeholder section
                awk -v content="$reminder_content" '
                    /<!-- OPENCODE-PLAN-REMINDER-INJECT-START -->/ { print; print content; skip=1; next }
                    /<!-- OPENCODE-PLAN-REMINDER-INJECT-END -->/ { skip=0 }
                    !skip { print }
                ' "$plan_plus" > "$plan_plus.tmp" && mv "$plan_plus.tmp" "$plan_plus"
                print_info "Injected OpenCode plan-reminder into Plan+"
            fi
        fi
    else
        print_error "Failed to deploy agents"
        return 1
    fi
    
    return 0
}

# Generate Agent Skills SKILL.md files for cross-tool compatibility
generate_agent_skills() {
    print_info "Generating Agent Skills SKILL.md files..."
    
    local skills_script="$HOME/.aidevops/agents/scripts/generate-skills.sh"
    
    if [[ -f "$skills_script" ]]; then
        if bash "$skills_script" 2>/dev/null; then
            print_success "Agent Skills SKILL.md files generated"
            print_info "Skills compatible with: Cursor, Claude Code, VS Code, GitHub Copilot"
        else
            print_warning "Agent Skills generation encountered issues (non-critical)"
        fi
    else
        print_warning "Agent Skills generator not found at $skills_script"
    fi
    
    return 0
}

# Create symlinks for imported skills to AI assistant skill directories
create_skill_symlinks() {
    print_info "Creating symlinks for imported skills..."
    
    local skill_sources="$HOME/.aidevops/agents/configs/skill-sources.json"
    local agents_dir="$HOME/.aidevops/agents"
    
    # Skip if no skill-sources.json or jq not available
    if [[ ! -f "$skill_sources" ]]; then
        print_info "No imported skills found (skill-sources.json not present)"
        return 0
    fi
    
    if ! command -v jq &>/dev/null; then
        print_warning "jq not found - cannot create skill symlinks"
        return 0
    fi
    
    # Check if there are any skills
    local skill_count
    skill_count=$(jq '.skills | length' "$skill_sources" 2>/dev/null || echo "0")
    
    if [[ "$skill_count" -eq 0 ]]; then
        print_info "No imported skills to symlink"
        return 0
    fi
    
    # AI assistant skill directories
    local skill_dirs=(
        "$HOME/.config/opencode/skills"
        "$HOME/.codex/skills"
        "$HOME/.claude/skills"
        "$HOME/.config/amp/tools"
    )
    
    # Create skill directories if they don't exist
    for dir in "${skill_dirs[@]}"; do
        mkdir -p "$dir" 2>/dev/null || true
    done
    
    local created_count=0
    
    # Read each skill and create symlinks
    while IFS= read -r skill_json; do
        local name local_path
        name=$(echo "$skill_json" | jq -r '.name')
        local_path=$(echo "$skill_json" | jq -r '.local_path')
        
        # Skip if path doesn't exist
        local full_path="$agents_dir/${local_path#.agent/}"
        if [[ ! -f "$full_path" ]]; then
            print_warning "Skill file not found: $full_path"
            continue
        fi
        
        # Create symlinks in each AI assistant directory
        for skill_dir in "${skill_dirs[@]}"; do
            local target_file
            
            # Amp expects <name>.md directly, others expect <name>/SKILL.md
            if [[ "$skill_dir" == *"/amp/tools" ]]; then
                target_file="$skill_dir/${name}.md"
            else
                local target_dir="$skill_dir/$name"
                target_file="$target_dir/SKILL.md"
                # Create skill subdirectory
                mkdir -p "$target_dir" 2>/dev/null || continue
            fi
            
            # Create symlink (remove existing first)
            rm -f "$target_file" 2>/dev/null || true
            if ln -sf "$full_path" "$target_file" 2>/dev/null; then
                ((created_count++))
            fi
        done
    done < <(jq -c '.skills[]' "$skill_sources" 2>/dev/null)
    
    if [[ $created_count -gt 0 ]]; then
        print_success "Created $created_count skill symlinks across AI assistants"
    else
        print_info "No skill symlinks created"
    fi
    
    return 0
}

# Check for updates to imported skills from upstream repositories
check_skill_updates() {
    print_info "Checking for skill updates..."
    
    local skill_sources="$HOME/.aidevops/agents/configs/skill-sources.json"
    
    # Skip if no skill-sources.json or required tools not available
    if [[ ! -f "$skill_sources" ]]; then
        print_info "No imported skills to check"
        return 0
    fi
    
    if ! command -v jq &>/dev/null; then
        print_warning "jq not found - cannot check skill updates"
        return 0
    fi
    
    if ! command -v curl &>/dev/null; then
        print_warning "curl not found - cannot check skill updates"
        return 0
    fi
    
    local skill_count
    skill_count=$(jq '.skills | length' "$skill_sources" 2>/dev/null || echo "0")
    
    if [[ "$skill_count" -eq 0 ]]; then
        print_info "No imported skills to check"
        return 0
    fi
    
    local updates_available=0
    local update_list=""
    
    # Check each skill for updates
    while IFS= read -r skill_json; do
        local name upstream_url upstream_commit
        name=$(echo "$skill_json" | jq -r '.name')
        upstream_url=$(echo "$skill_json" | jq -r '.upstream_url')
        upstream_commit=$(echo "$skill_json" | jq -r '.upstream_commit // empty')
        
        # Skip skills without upstream URL or commit (e.g., context7 imports)
        if [[ -z "$upstream_url" || "$upstream_url" == "null" ]]; then
            continue
        fi
        if [[ -z "$upstream_commit" ]]; then
            continue
        fi
        
        # Extract owner/repo from GitHub URL
        local owner_repo
        owner_repo=$(echo "$upstream_url" | sed -E 's|https://github.com/||; s|\.git$||; s|/tree/.*||')
        
        if [[ -z "$owner_repo" || ! "$owner_repo" =~ / ]]; then
            continue
        fi
        
        # Get latest commit from GitHub API (silent, with timeout)
        local latest_commit
        latest_commit=$(curl -s --max-time 5 "https://api.github.com/repos/$owner_repo/commits?per_page=1" 2>/dev/null | jq -r '.[0].sha // empty')
        
        if [[ -n "$latest_commit" && "$latest_commit" != "$upstream_commit" ]]; then
            ((updates_available++))
            update_list="${update_list}\n  - $name (${upstream_commit:0:7} → ${latest_commit:0:7})"
        fi
    done < <(jq -c '.skills[]' "$skill_sources" 2>/dev/null)
    
    if [[ $updates_available -gt 0 ]]; then
        print_warning "Skill updates available:$update_list"
        print_info "Run: ~/.aidevops/agents/scripts/add-skill-helper.sh check-updates"
        print_info "To update a skill: ~/.aidevops/agents/scripts/add-skill-helper.sh add <url> --force"
    else
        print_success "All imported skills are up to date"
    fi
    
    return 0
}

# Inject aidevops reference into AI assistant AGENTS.md files
inject_agents_reference() {
    print_info "Adding aidevops reference to AI assistant configurations..."
    
    local reference_line='Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.'
    
    # AI assistant agent directories - these get cleaned and receive AGENTS.md reference
    # Format: "config_dir:agents_subdir" where agents_subdir is the folder containing agent files
    local ai_agent_dirs=(
        "$HOME/.config/opencode:agent"
        "$HOME/.cursor:rules"
        "$HOME/.claude:commands"
        "$HOME/.continue:."
        "$HOME/.cody:."
        "$HOME/.opencode:."
    )
    
    local updated_count=0
    
    for entry in "${ai_agent_dirs[@]}"; do
        local config_dir="${entry%%:*}"
        local agents_subdir="${entry##*:}"
        local agents_dir="$config_dir/$agents_subdir"
        local agents_file="$agents_dir/AGENTS.md"
        
        # Only process if the config directory exists (tool is installed)
        if [[ -d "$config_dir" ]]; then
            # Create agents subdirectory if needed
            mkdir -p "$agents_dir"
            
            # Check if AGENTS.md exists and has our reference
            if [[ -f "$agents_file" ]]; then
                # Check first line for our reference
                local first_line
                first_line=$(head -1 "$agents_file" 2>/dev/null || echo "")
                if [[ "$first_line" != *"~/.aidevops/agents/AGENTS.md"* ]]; then
                    # Prepend reference to existing file
                    local temp_file
                    temp_file=$(mktemp)
                    echo "$reference_line" > "$temp_file"
                    echo "" >> "$temp_file"
                    cat "$agents_file" >> "$temp_file"
                    mv "$temp_file" "$agents_file"
                    print_success "Added reference to $agents_file"
                    ((updated_count++))
                else
                    print_info "Reference already exists in $agents_file"
                fi
            else
                # Create new file with just the reference
                echo "$reference_line" > "$agents_file"
                print_success "Created $agents_file with aidevops reference"
                ((updated_count++))
            fi
        fi
    done
    
    if [[ $updated_count -eq 0 ]]; then
        print_info "No AI assistant configs found to update (tools may not be installed yet)"
    else
        print_success "Updated $updated_count AI assistant configuration(s)"
    fi
    
    return 0
}

# Update OpenCode configuration
update_opencode_config() {
    print_info "Updating OpenCode configuration..."
    
    local opencode_config="$HOME/.config/opencode/opencode.json"
    
    if [[ ! -f "$opencode_config" ]]; then
        print_info "OpenCode config not found at $opencode_config - skipping"
        return 0
    fi
    
    # Create backup (with rotation)
    create_backup_with_rotation "$opencode_config" "opencode"
    
    # Generate OpenCode agent configuration
    # - Primary agents: Added to opencode.json (for Tab order & MCP control)
    # - Subagents: Generated as markdown in ~/.config/opencode/agent/
    local generator_script=".agent/scripts/generate-opencode-agents.sh"
    if [[ -f "$generator_script" ]]; then
        print_info "Generating OpenCode agent configuration..."
        if bash "$generator_script"; then
            print_success "OpenCode agents configured (11 primary in JSON, subagents as markdown)"
        else
            print_warning "OpenCode agent generation encountered issues"
        fi
    else
        print_warning "OpenCode agent generator not found at $generator_script"
    fi
    
    # Generate OpenCode commands
    # - Commands from workflows and agents -> /command-name
    local commands_script=".agent/scripts/generate-opencode-commands.sh"
    if [[ -f "$commands_script" ]]; then
        print_info "Generating OpenCode commands..."
        if bash "$commands_script"; then
            print_success "OpenCode commands configured"
        else
            print_warning "OpenCode command generation encountered issues"
        fi
    else
        print_warning "OpenCode command generator not found at $commands_script"
    fi
    
    return 0
}

# Verify repository location
verify_location() {
    local current_dir
    current_dir="$(pwd)"
    local expected_location="$HOME/Git/aidevops"

    if [[ "$current_dir" != "$expected_location" ]]; then
        print_warning "Repository is not in the recommended location"
        print_info "Current location: $current_dir"
        print_info "Recommended location: $expected_location"
        echo ""
        echo "For optimal AI assistant integration, consider moving this repository to:"
        echo "  mkdir -p ~/git"
        echo "  mv '$current_dir' '$expected_location'"
        echo ""
    else
        print_success "Repository is in the recommended location: $expected_location"
    fi
    return 0
}



# Setup Python environment for DSPy
setup_python_env() {
    print_info "Setting up Python environment for DSPy..."

    # Check if Python 3 is available
    local python3_bin
    if ! python3_bin=$(find_python3); then
        print_warning "Python 3 not found - DSPy setup skipped"
        print_info "Install Python 3.8+ to enable DSPy integration"
        return
    fi

    local python_version
    python_version=$("$python3_bin" --version | cut -d' ' -f2 | cut -d'.' -f1-2)
    local version_check
    version_check=$("$python3_bin" -c "import sys; print(1 if sys.version_info >= (3, 8) else 0)")

    if [[ "$version_check" != "1" ]]; then
        print_warning "Python 3.8+ required for DSPy, found $python_version - DSPy setup skipped"
        return
    fi

    # Create Python virtual environment
    if [[ ! -d "python-env/dspy-env" ]]; then
        print_info "Creating Python virtual environment for DSPy..."
        mkdir -p python-env
        python3 -m venv python-env/dspy-env

        if [[ $? -eq 0 ]]; then
            print_success "Python virtual environment created"
        else
            print_warning "Failed to create Python virtual environment - DSPy setup skipped"
            return
        fi
    else
        print_info "Python virtual environment already exists"
    fi

    # Install DSPy dependencies
    print_info "Installing DSPy dependencies..."
    # shellcheck source=/dev/null
    source python-env/dspy-env/bin/activate
    pip install --upgrade pip > /dev/null 2>&1
    
    local pip_output
    if pip_output=$(pip install -r requirements.txt 2>&1); then
        print_success "DSPy dependencies installed successfully"
    else
        print_warning "Failed to install DSPy dependencies:"
        # Show last few lines of error for debugging
        echo "$pip_output" | tail -8 | sed 's/^/  /'
        echo ""
        print_info "Check requirements.txt or run manually:"
        print_info "  source python-env/dspy-env/bin/activate && pip install -r requirements.txt"
    fi
}

# Setup Node.js environment for DSPyGround
setup_nodejs_env() {
    print_info "Setting up Node.js environment for DSPyGround..."

    # Check if Node.js is available
    if ! command -v node &> /dev/null; then
        print_warning "Node.js not found - DSPyGround setup skipped"
        print_info "Install Node.js 18+ to enable DSPyGround integration"
        return
    fi

    local node_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
    if [[ $node_version -lt 18 ]]; then
        print_warning "Node.js 18+ required for DSPyGround, found v$node_version - DSPyGround setup skipped"
        return
    fi

    # Check if npm is available
    if ! command -v npm &> /dev/null; then
        print_warning "npm not found - DSPyGround setup skipped"
        return
    fi

    # Install DSPyGround globally if not already installed
    if ! command -v dspyground &> /dev/null; then
        print_info "Installing DSPyGround globally..."
        npm install -g dspyground > /dev/null 2>&1

        if [[ $? -eq 0 ]]; then
            print_success "DSPyGround installed successfully"
        else
            print_warning "Failed to install DSPyGround globally"
        fi
    else
        print_success "DSPyGround already installed"
    fi
}

# Install MCP servers globally for fast startup (no npx/pipx overhead)
install_mcp_packages() {
    print_info "Installing MCP server packages globally (eliminates npx startup delay)..."

    # Node.js MCP packages to install globally
    local -a node_mcps=(
        "chrome-devtools-mcp"
        "mcp-server-gsc"
        "playwriter"
        "@steipete/macos-automator-mcp"
        "@steipete/claude-code-mcp"
    )

    local installer=""
    local install_cmd=""

    if command -v bun &> /dev/null; then
        installer="bun"
        install_cmd="bun install -g"
    elif command -v npm &> /dev/null; then
        installer="npm"
        install_cmd="npm install -g"
    else
        print_warning "Neither bun nor npm found - cannot install MCP packages"
        print_info "Install bun (recommended): curl -fsSL https://bun.sh/install | bash"
        return 0
    fi

    print_info "Using $installer to install/update Node.js MCP packages..."

    # Always install latest (bun install -g is fast and idempotent)
    local updated=0
    local failed=0
    local pkg
    for pkg in "${node_mcps[@]}"; do
        if $install_cmd "${pkg}@latest" > /dev/null 2>&1; then
            ((updated++))
        else
            ((failed++))
            print_warning "Failed to install/update $pkg"
        fi
    done

    if [[ $updated -gt 0 ]]; then
        print_success "$updated Node.js MCP packages installed/updated to latest via $installer"
    fi
    if [[ $failed -gt 0 ]]; then
        print_warning "$failed packages failed (check network or package names)"
    fi

    # Python MCP packages (install or upgrade)
    if command -v pipx &> /dev/null; then
        print_info "Installing/updating analytics-mcp via pipx..."
        if command -v analytics-mcp &> /dev/null; then
            pipx upgrade analytics-mcp > /dev/null 2>&1 || true
        else
            pipx install analytics-mcp > /dev/null 2>&1 || print_warning "Failed to install analytics-mcp"
        fi
    fi

    if command -v uv &> /dev/null; then
        print_info "Installing/updating outscraper-mcp-server via uv..."
        if command -v outscraper-mcp-server &> /dev/null; then
            uv tool upgrade outscraper-mcp-server > /dev/null 2>&1 || true
        else
            uv tool install outscraper-mcp-server > /dev/null 2>&1 || print_warning "Failed to install outscraper-mcp-server"
        fi
    fi

    # Update opencode.json with resolved full paths for all MCP binaries
    update_mcp_paths_in_opencode

    print_info "MCP servers will start instantly (no registry lookups on each launch)"
    return 0
}

# Resolve full path for an MCP binary, checking common install locations
# Usage: resolve_mcp_binary_path "binary-name"
# Returns: full path on stdout, or empty string if not found
resolve_mcp_binary_path() {
    local bin_name="$1"
    local resolved=""

    # Check common locations in priority order
    local search_paths=(
        "$HOME/.bun/bin/$bin_name"
        "/opt/homebrew/bin/$bin_name"
        "/usr/local/bin/$bin_name"
        "$HOME/.local/bin/$bin_name"
        "$HOME/.npm-global/bin/$bin_name"
    )

    for path in "${search_paths[@]}"; do
        if [[ -x "$path" ]]; then
            resolved="$path"
            break
        fi
    done

    # Fallback: use command -v if in PATH (portable, POSIX-compliant)
    if [[ -z "$resolved" ]]; then
        resolved=$(command -v "$bin_name" 2>/dev/null || true)
    fi

    echo "$resolved"
    return 0
}

# Update opencode.json MCP commands to use full binary paths
# This ensures MCPs start regardless of PATH configuration
update_mcp_paths_in_opencode() {
    local opencode_config="$HOME/.config/opencode/opencode.json"

    if [[ ! -f "$opencode_config" ]]; then
        return 0
    fi

    if ! command -v jq &> /dev/null; then
        return 0
    fi

    local tmp_config
    tmp_config=$(mktemp)
    cp "$opencode_config" "$tmp_config"

    local updated=0

    # Get all MCP entries with local commands
    local mcp_keys
    mcp_keys=$(jq -r '.mcp | to_entries[] | select(.value.type == "local") | select(.value.command != null) | .key' "$tmp_config" 2>/dev/null)

    while IFS= read -r mcp_key; do
        [[ -z "$mcp_key" ]] && continue

        # Get the first element of the command array (the binary)
        local current_cmd
        current_cmd=$(jq -r --arg k "$mcp_key" '.mcp[$k].command[0]' "$tmp_config" 2>/dev/null)

        # Skip if already a full path
        if [[ "$current_cmd" == /* ]]; then
            # Verify the path still exists
            if [[ ! -x "$current_cmd" ]]; then
                # Path is stale, try to resolve
                local bin_name
                bin_name=$(basename "$current_cmd")
                local new_path
                new_path=$(resolve_mcp_binary_path "$bin_name")
                if [[ -n "$new_path" && "$new_path" != "$current_cmd" ]]; then
                    jq --arg k "$mcp_key" --arg p "$new_path" '.mcp[$k].command[0] = $p' "$tmp_config" > "${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
                    ((updated++))
                fi
            fi
            continue
        fi

        # Skip docker (container runtime) and node (resolved separately below)
        case "$current_cmd" in
            docker|node) continue ;;
        esac

        # Resolve the full path
        local full_path
        full_path=$(resolve_mcp_binary_path "$current_cmd")

        if [[ -n "$full_path" && "$full_path" != "$current_cmd" ]]; then
            jq --arg k "$mcp_key" --arg p "$full_path" '.mcp[$k].command[0] = $p' "$tmp_config" > "${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
            ((updated++))
        fi
    done <<< "$mcp_keys"

    # Also resolve 'node' commands (e.g., quickfile, amazon-order-history)
    # These use ["node", "/path/to/index.js"] - node itself should be resolved
    local node_path
    node_path=$(resolve_mcp_binary_path "node")
    if [[ -n "$node_path" ]]; then
        local node_mcp_keys
        node_mcp_keys=$(jq -r '.mcp | to_entries[] | select(.value.type == "local") | select(.value.command != null) | select(.value.command[0] == "node") | .key' "$tmp_config" 2>/dev/null)
        while IFS= read -r mcp_key; do
            [[ -z "$mcp_key" ]] && continue
            jq --arg k "$mcp_key" --arg p "$node_path" '.mcp[$k].command[0] = $p' "$tmp_config" > "${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
            ((updated++))
        done <<< "$node_mcp_keys"
    fi

    if [[ $updated -gt 0 ]]; then
        create_backup_with_rotation "$opencode_config" "opencode"
        mv "$tmp_config" "$opencode_config"
        print_success "Updated $updated MCP commands to use full binary paths in opencode.json"
    else
        rm -f "$tmp_config"
    fi

    return 0
}

# Setup LocalWP MCP server for AI database access
setup_localwp_mcp() {
    print_info "Setting up LocalWP MCP server..."

    # Check if LocalWP is installed
    local localwp_found=false
    if [[ -d "/Applications/Local.app" ]] || [[ -d "$HOME/Applications/Local.app" ]]; then
        localwp_found=true
    fi

    if [[ "$localwp_found" != "true" ]]; then
        print_info "LocalWP not found - skipping MCP server setup"
        print_info "Install LocalWP from: https://localwp.com/"
        return 0
    fi

    print_success "LocalWP found"

    # Check if npm is available
    if ! command -v npm &> /dev/null; then
        print_warning "npm not found - cannot install LocalWP MCP server"
        print_info "Install Node.js and npm first"
        return 0
    fi

    # Check if mcp-local-wp is already installed
    if command -v mcp-local-wp &> /dev/null; then
        print_success "LocalWP MCP server already installed"
        return 0
    fi

    # Offer to install mcp-local-wp
    print_info "LocalWP MCP server enables AI assistants to query WordPress databases"
    read -r -p "Install LocalWP MCP server (@verygoodplugins/mcp-local-wp)? (y/n): " install_mcp

    if [[ "$install_mcp" == "y" ]]; then
        print_info "Installing LocalWP MCP server..."
        if npm install -g @verygoodplugins/mcp-local-wp > /dev/null 2>&1; then
            print_success "LocalWP MCP server installed successfully"
            print_info "Start with: ~/.aidevops/agents/scripts/localhost-helper.sh start-mcp"
            print_info "Or configure in OpenCode MCP settings for auto-start"
        else
            print_warning "Failed to install LocalWP MCP server"
            print_info "Try manually: npm install -g @verygoodplugins/mcp-local-wp"
        fi
    else
        print_info "Skipped LocalWP MCP server installation"
        print_info "Install later: npm install -g @verygoodplugins/mcp-local-wp"
    fi

    return 0
}

# Setup Augment Context Engine MCP
setup_augment_context_engine() {
    print_info "Setting up Augment Context Engine MCP..."

    # Check Node.js version (requires 22+)
    if ! command -v node &> /dev/null; then
        print_warning "Node.js not found - Augment Context Engine setup skipped"
        print_info "Install Node.js 22+ to enable Augment Context Engine"
        return
    fi

    local node_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
    if [[ $node_version -lt 22 ]]; then
        print_warning "Node.js 22+ required for Augment Context Engine, found v$node_version"
        print_info "Install: brew install node@22 (macOS) or nvm install 22"
        return
    fi

    # Check if auggie is installed
    if ! command -v auggie &> /dev/null; then
        print_warning "Auggie CLI not found"
        print_info "Install with: npm install -g @augmentcode/auggie@prerelease"
        print_info "Then run: auggie login"
        return
    fi

    # Check if logged in
    if [[ ! -f "$HOME/.augment/session.json" ]]; then
        print_warning "Auggie not logged in"
        print_info "Run: auggie login"
        return
    fi

    print_success "Auggie CLI found and authenticated"

    # MCP configuration is handled by generate-opencode-agents.sh for OpenCode
    # Other tools (Cursor, Claude Code, etc.) discover skills via SKILL.md files

    print_info "Augment Context Engine available for tools supporting Agent Skills"
    print_info "Supported tools: OpenCode, Cursor, Claude Code, VS Code, GitHub Copilot"
    print_info "Verification: 'What is this project? Please use codebase retrieval tool.'"
}

# Setup osgrep - Local Semantic Search
setup_osgrep() {
    print_info "Setting up osgrep (local semantic search)..."

    # Check Node.js version (requires 18+)
    if ! command -v node &> /dev/null; then
        print_warning "Node.js not found - osgrep setup skipped"
        print_info "Install Node.js 18+ to enable osgrep"
        return
    fi

    local node_version
    node_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
    if [[ $node_version -lt 18 ]]; then
        print_warning "Node.js 18+ required for osgrep, found v$node_version"
        print_info "Install: brew install node@18 (macOS) or nvm install 18"
        return
    fi

    # Check if osgrep is installed
    if ! command -v osgrep &> /dev/null; then
        print_warning "osgrep CLI not found"
        print_info "Install with: npm install -g osgrep"
        print_info "Then run: osgrep setup (downloads ~150MB embedding models)"
        return
    fi

    # Check if models are downloaded
    if [[ ! -d "$HOME/.osgrep" ]]; then
        print_warning "osgrep models not yet downloaded"
        print_info "Run: osgrep setup"
        print_info "This downloads ~150MB of embedding models for local semantic search"
    else
        print_success "osgrep CLI found and configured"
    fi

    # Note about Claude Code integration
    print_info "osgrep provides 100% local semantic search (no cloud, no auth)"
    print_info "For Claude Code: osgrep install-claude-code"
    print_info "Supported tools: OpenCode, Cursor, Gemini CLI, Claude Code, Zed"
    print_info "Verification: 'Search for authentication handling in this codebase'"
}

# Setup Beads - Task Graph Visualization
setup_beads() {
    print_info "Setting up Beads (task graph visualization)..."
    
    # Check if Beads CLI (bd) is already installed
    if command -v bd &> /dev/null; then
        local bd_version
        bd_version=$(bd --version 2>/dev/null | head -1 || echo "unknown")
        print_success "Beads CLI (bd) already installed: $bd_version"
    else
        # Try to install via Homebrew first (macOS/Linux with Homebrew)
        if command -v brew &> /dev/null; then
            print_info "Installing Beads via Homebrew..."
            if brew install steveyegge/beads/bd 2>/dev/null; then
                print_success "Beads CLI installed via Homebrew"
            else
                print_warning "Homebrew tap installation failed, trying alternative..."
                # Try Go install if Go is available
                if command -v go &> /dev/null; then
                    print_info "Installing Beads via Go..."
                    if go install github.com/steveyegge/beads/cmd/bd@latest 2>/dev/null; then
                        print_success "Beads CLI installed via Go"
                        print_info "Ensure \$GOPATH/bin is in your PATH"
                    else
                        print_warning "Go installation failed"
                    fi
                fi
            fi
        elif command -v go &> /dev/null; then
            print_info "Installing Beads via Go..."
            if go install github.com/steveyegge/beads/cmd/bd@latest 2>/dev/null; then
                print_success "Beads CLI installed via Go"
                print_info "Ensure \$GOPATH/bin is in your PATH"
            else
                print_warning "Go installation failed"
            fi
        else
            # Provide manual installation instructions
            print_warning "Beads CLI (bd) not installed"
            echo ""
            echo "  Install options:"
            echo "    macOS/Linux (Homebrew): brew install steveyegge/beads/bd"
            echo "    Go:                     go install github.com/steveyegge/beads/cmd/bd@latest"
            echo "    Manual:                 https://github.com/steveyegge/beads/releases"
            echo ""
        fi
    fi
    
    print_info "Beads provides task graph visualization for TODO.md and PLANS.md"
    print_info "After installation, run: aidevops init beads"
    
    # Offer to install optional Beads UI tools
    setup_beads_ui
    
    return 0
}

# Setup Beads UI Tools (optional visualization tools)
setup_beads_ui() {
    echo ""
    print_info "Beads UI tools provide enhanced visualization:"
    echo "  • beads_viewer (Python) - PageRank, critical path, graph analytics"
    echo "  • beads-ui (Node.js)    - Web dashboard with live updates"
    echo "  • bdui (Node.js)        - React/Ink terminal UI"
    echo "  • perles (Rust)         - BQL query language TUI"
    echo ""
    
    read -r -p "Install optional Beads UI tools? (y/n): " install_beads_ui
    
    if [[ "$install_beads_ui" != "y" ]]; then
        print_info "Skipped Beads UI tools (can install later from beads.md docs)"
        return 0
    fi
    
    local installed_count=0
    
    # beads_viewer (Python)
    if command -v pip3 &> /dev/null || command -v pip &> /dev/null; then
        read -r -p "  Install beads_viewer (Python TUI with graph analytics)? (y/n): " install_viewer
        if [[ "$install_viewer" == "y" ]]; then
            print_info "Installing beads_viewer..."
            if pip3 install beads-viewer 2>/dev/null || pip install beads-viewer 2>/dev/null; then
                print_success "beads_viewer installed"
                ((installed_count++))
            else
                print_warning "Failed to install beads_viewer"
            fi
        fi
    fi
    
    # beads-ui (Node.js)
    if command -v npm &> /dev/null; then
        read -r -p "  Install beads-ui (Web dashboard)? (y/n): " install_web
        if [[ "$install_web" == "y" ]]; then
            print_info "Installing beads-ui..."
            if npm install -g beads-ui 2>/dev/null; then
                print_success "beads-ui installed (run: beads-ui)"
                ((installed_count++))
            else
                print_warning "Failed to install beads-ui"
            fi
        fi
        
        read -r -p "  Install bdui (React/Ink TUI)? (y/n): " install_bdui
        if [[ "$install_bdui" == "y" ]]; then
            print_info "Installing bdui..."
            if npm install -g bdui 2>/dev/null; then
                print_success "bdui installed (run: bdui)"
                ((installed_count++))
            else
                print_warning "Failed to install bdui"
            fi
        fi
    fi
    
    # perles (Rust)
    if command -v cargo &> /dev/null; then
        read -r -p "  Install perles (BQL query language TUI)? (y/n): " install_perles
        if [[ "$install_perles" == "y" ]]; then
            print_info "Installing perles (this may take a few minutes)..."
            if cargo install perles 2>/dev/null; then
                print_success "perles installed (run: perles)"
                ((installed_count++))
            else
                print_warning "Failed to install perles"
            fi
        fi
    fi
    
    if [[ $installed_count -gt 0 ]]; then
        print_success "Installed $installed_count Beads UI tool(s)"
    else
        print_info "No Beads UI tools installed"
    fi
    
    echo ""
    print_info "Beads UI documentation: ~/.aidevops/agents/tools/task-management/beads.md"
    
    return 0
}

# Setup Browser Automation Tools (Bun, dev-browser, Playwriter)
setup_browser_tools() {
    print_info "Setting up browser automation tools..."
    
    local has_bun=false
    local has_node=false
    
    # Check Bun
    if command -v bun &> /dev/null; then
        has_bun=true
        print_success "Bun $(bun --version) found"
    fi
    
    # Check Node.js (for Playwriter)
    if command -v node &> /dev/null; then
        has_node=true
    fi
    
    # Install Bun if not present (required for dev-browser)
    if [[ "$has_bun" == "false" ]]; then
        print_info "Installing Bun (required for dev-browser)..."
        if curl -fsSL https://bun.sh/install | bash 2>/dev/null; then
            # Source the updated PATH
            export BUN_INSTALL="$HOME/.bun"
            export PATH="$BUN_INSTALL/bin:$PATH"
            if command -v bun &> /dev/null; then
                has_bun=true
                print_success "Bun installed: $(bun --version)"
            fi
        else
            print_warning "Bun installation failed - dev-browser will need manual setup"
        fi
    fi
    
    # Setup dev-browser if Bun is available
    if [[ "$has_bun" == "true" ]]; then
        local dev_browser_dir="$HOME/.aidevops/dev-browser"
        
        if [[ -d "${dev_browser_dir}/skills/dev-browser" ]]; then
            print_success "dev-browser already installed"
        else
            print_info "Installing dev-browser (stateful browser automation)..."
            local dev_browser_output
            if dev_browser_output=$(bash "$HOME/.aidevops/agents/scripts/dev-browser-helper.sh" setup 2>&1); then
                print_success "dev-browser installed"
                print_info "Start server with: bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start"
            else
                print_warning "dev-browser setup failed:"
                # Show last few lines of error output for debugging
                echo "$dev_browser_output" | tail -5 | sed 's/^/  /'
                echo ""
                print_info "Run manually to see full output:"
                print_info "  bash ~/.aidevops/agents/scripts/dev-browser-helper.sh setup"
            fi
        fi
    fi
    
    # Playwriter MCP (Node.js based, runs via npx)
    if [[ "$has_node" == "true" ]]; then
        print_success "Playwriter MCP available (runs via npx playwriter@latest)"
        print_info "Install Chrome extension: https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe"
    else
        print_warning "Node.js not found - Playwriter MCP unavailable"
    fi
    
    # Playwright MCP (cross-browser testing automation)
    if [[ "$has_node" == "true" ]]; then
        print_info "Setting up Playwright MCP..."
        
        # Check if Playwright browsers are installed (--no-install prevents auto-download)
        if npx --no-install playwright --version &> /dev/null 2>&1; then
            print_success "Playwright already installed"
        else
            local install_playwright
            read -r -p "Install Playwright MCP with browsers (chromium, firefox, webkit)? (y/n): " install_playwright
            
            if [[ "$install_playwright" == "y" ]]; then
                print_info "Installing Playwright browsers..."
                if npx playwright install; then
                    print_success "Playwright browsers installed"
                else
                    print_warning "Playwright browser installation failed"
                    print_info "Run manually: npx playwright install"
                fi
            else
                print_info "Skipped Playwright installation"
                print_info "Install later with: npx playwright install"
            fi
        fi
        
        print_info "Playwright MCP runs via: npx playwright-mcp@latest"
    fi
    
    if [[ "$has_node" == "true" ]]; then
        print_info "Browser tools: dev-browser (stateful), Playwriter (extension), Playwright (testing), Stagehand (AI)"
    else
        print_info "Browser tools: dev-browser (stateful), Stagehand (AI)"
    fi
    return 0
}

# Setup AI Orchestration Frameworks (Langflow, CrewAI, AutoGen)
setup_ai_orchestration() {
    print_info "Setting up AI orchestration frameworks..."
    
    local has_python=false
    
    # Check Python (prefer Homebrew/pyenv over system)
    local python3_bin
    if python3_bin=$(find_python3); then
        local python_version
        python_version=$("$python3_bin" --version 2>&1 | cut -d' ' -f2)
        local major minor
        major=$(echo "$python_version" | cut -d. -f1)
        minor=$(echo "$python_version" | cut -d. -f2)
        
        if [[ $major -ge 3 ]] && [[ $minor -ge 10 ]]; then
            has_python=true
            print_success "Python $python_version found (3.10+ required)"
        else
            print_warning "Python 3.10+ required for AI orchestration, found $python_version"
            echo ""
            echo "  Upgrade options:"
            echo "    macOS (Homebrew): brew install python@3.12"
            echo "    macOS (pyenv):    pyenv install 3.12 && pyenv global 3.12"
            echo "    Ubuntu/Debian:    sudo apt install python3.12"
            echo "    Fedora:           sudo dnf install python3.12"
            echo ""
        fi
    else
        print_warning "Python 3 not found - AI orchestration frameworks unavailable"
        echo ""
        echo "  Install options:"
        echo "    macOS: brew install python@3.12"
        echo "    Linux: sudo apt install python3 (or dnf/pacman)"
        echo ""
        return 0
    fi
    
    if [[ "$has_python" == "false" ]]; then
        return 0
    fi
    
    # Create orchestration directory
    mkdir -p "$HOME/.aidevops/orchestration"
    
    # Info about available frameworks
    print_info "AI Orchestration Frameworks available:"
    echo "  - Langflow: Visual flow builder (localhost:7860)"
    echo "  - CrewAI: Multi-agent teams (localhost:8501)"
    echo "  - AutoGen: Microsoft agentic AI (localhost:8081)"
    echo ""
    print_info "Setup individual frameworks with:"
    echo "  bash .agent/scripts/langflow-helper.sh setup"
    echo "  bash .agent/scripts/crewai-helper.sh setup"
    echo "  bash .agent/scripts/autogen-helper.sh setup"
    echo ""
    print_info "See .agent/tools/ai-orchestration/overview.md for comparison"
    
    return 0
}

# Setup OpenCode Plugins (Antigravity OAuth)
# Helper function to add/update a single plugin in OpenCode config
add_opencode_plugin() {
    local plugin_name="$1"
    local plugin_spec="$2"
    local opencode_config="$3"
    
    # Check if plugin array exists and if plugin is already configured
    local has_plugin_array
    has_plugin_array=$(jq -e '.plugin' "$opencode_config" >/dev/null 2>&1 && echo "true" || echo "false")
    
    if [[ "$has_plugin_array" == "true" ]]; then
        # Check if plugin is already in the array
        local plugin_exists
        plugin_exists=$(jq -e --arg p "$plugin_name" '.plugin | map(select(startswith($p))) | length > 0' "$opencode_config" >/dev/null 2>&1 && echo "true" || echo "false")
        
        if [[ "$plugin_exists" == "true" ]]; then
            # Update existing plugin to latest version
            local temp_file
            temp_file=$(mktemp)
            jq --arg old "$plugin_name" --arg new "$plugin_spec" \
                '.plugin = [.plugin[] | if startswith($old) then $new else . end]' \
                "$opencode_config" > "$temp_file" && mv "$temp_file" "$opencode_config"
            print_success "Updated $plugin_name to latest version"
        else
            # Add plugin to existing array
            local temp_file
            temp_file=$(mktemp)
            jq --arg p "$plugin_spec" '.plugin += [$p]' "$opencode_config" > "$temp_file" && mv "$temp_file" "$opencode_config"
            print_success "Added $plugin_name plugin to OpenCode config"
        fi
    else
        # Create plugin array with the plugin
        local temp_file
        temp_file=$(mktemp)
        jq --arg p "$plugin_spec" '. + {plugin: [$p]}' "$opencode_config" > "$temp_file" && mv "$temp_file" "$opencode_config"
        print_success "Created plugin array with $plugin_name"
    fi
}

setup_opencode_plugins() {
    print_info "Setting up OpenCode plugins..."
    
    local opencode_config="$HOME/.config/opencode/opencode.json"
    
    # Check if OpenCode is installed
    if ! command -v opencode &> /dev/null; then
        print_warning "OpenCode not found - plugin setup skipped"
        print_info "Install OpenCode first: https://opencode.ai"
        return 0
    fi
    
    # Check if config exists
    if [[ ! -f "$opencode_config" ]]; then
        print_warning "OpenCode config not found at $opencode_config - plugin setup skipped"
        return 0
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        print_warning "jq not found - cannot update OpenCode config"
        return 0
    fi
    
    # Setup aidevops compaction plugin (local file plugin)
    local aidevops_plugin_path="$HOME/.aidevops/agents/plugins/opencode-aidevops/index.mjs"
    if [[ -f "$aidevops_plugin_path" ]]; then
        print_info "Setting up aidevops compaction plugin..."
        add_opencode_plugin "file://$HOME/.aidevops" "file://${aidevops_plugin_path}" "$opencode_config"
        print_success "aidevops compaction plugin registered (preserves context across compaction)"
    fi

    # Setup Antigravity OAuth plugin (Google OAuth)
    print_info "Setting up Antigravity OAuth plugin..."
    add_opencode_plugin "opencode-antigravity-auth" "opencode-antigravity-auth@latest" "$opencode_config"
    
    print_info "Antigravity OAuth plugin enables Google OAuth for OpenCode"
    print_info "Models available: gemini-3-pro-high, claude-opus-4-5-thinking, etc."
    print_info "See: https://github.com/NoeFabris/opencode-antigravity-auth"
    echo ""
    
    # Note: opencode-anthropic-auth is built into OpenCode v1.1.36+
    # Adding it as an external plugin causes TypeError due to double-loading.
    # Removed in v2.90.0 - see PR #230.
    
    print_info "After setup, authenticate with: opencode auth login"
    print_info "  • For Google OAuth: Select 'Google' → 'OAuth with Google (Antigravity)'"
    print_info "  • For Claude OAuth: Select 'Anthropic' → 'Claude Pro/Max' (built-in)"
    
    return 0
}

# Setup Oh-My-OpenCode Plugin (coding productivity features)
setup_oh_my_opencode() {
    print_info "Setting up Oh-My-OpenCode plugin..."
    
    local opencode_config="$HOME/.config/opencode/opencode.json"
    
    # Check if OpenCode is installed
    if ! command -v opencode &> /dev/null; then
        print_warning "OpenCode not found - Oh-My-OpenCode setup skipped"
        return 0
    fi
    
    # Check if config exists
    if [[ ! -f "$opencode_config" ]]; then
        print_warning "OpenCode config not found - Oh-My-OpenCode setup skipped"
        return 0
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        print_warning "jq not found - cannot update OpenCode config"
        return 0
    fi
    
    echo ""
    print_info "Oh-My-OpenCode adds coding productivity features:"
    echo "  • Async background agents (parallel task execution)"
    echo "  • LSP tools (11 tools: hover, goto, references, rename, etc.)"
    echo "  • AST-Grep (semantic code search/replace)"
    echo "  • Curated agents (OmO, Oracle, Librarian, Explore, Frontend)"
    echo "  • Claude Code compatibility (hooks, commands, skills)"
    echo "  • Context window monitoring and session recovery"
    echo ""
    echo "  Note: aidevops provides DevOps infrastructure (hosting, DNS, WordPress, SEO)"
    echo "        Oh-My-OpenCode provides coding productivity (LSP, AST, background agents)"
    echo "        They are complementary and work well together."
    echo ""
    
    read -r -p "Install Oh-My-OpenCode plugin? (y/n): " install_omo
    
    if [[ "$install_omo" != "y" ]]; then
        print_info "Skipped Oh-My-OpenCode installation"
        return 0
    fi
    
    local plugin_name="oh-my-opencode"
    
    # Check if plugin array exists
    local has_plugin_array
    has_plugin_array=$(jq -e '.plugin' "$opencode_config" >/dev/null 2>&1 && echo "true" || echo "false")
    
    if [[ "$has_plugin_array" == "true" ]]; then
        # Check if plugin is already in the array
        local plugin_exists
        plugin_exists=$(jq -e --arg p "$plugin_name" '.plugin | map(select(. == $p or startswith($p + "@"))) | length > 0' "$opencode_config" >/dev/null 2>&1 && echo "true" || echo "false")
        
        if [[ "$plugin_exists" == "true" ]]; then
            print_info "Oh-My-OpenCode already configured"
        else
            # Add plugin to existing array
            local temp_file
            temp_file=$(mktemp)
            jq --arg p "$plugin_name" '.plugin += [$p]' "$opencode_config" > "$temp_file" && mv "$temp_file" "$opencode_config"
            print_success "Added Oh-My-OpenCode plugin to OpenCode config"
        fi
    else
        # Create plugin array with the plugin
        local temp_file
        temp_file=$(mktemp)
        jq --arg p "$plugin_name" '. + {plugin: [$p]}' "$opencode_config" > "$temp_file" && mv "$temp_file" "$opencode_config"
        print_success "Created plugin array with Oh-My-OpenCode"
    fi
    
    # Create oh-my-opencode config if it doesn't exist
    local omo_config="$HOME/.config/opencode/oh-my-opencode.json"
    if [[ ! -f "$omo_config" ]]; then
        print_info "Creating Oh-My-OpenCode configuration..."
        cat > "$omo_config" << 'EOF'
{
  "$schema": "https://raw.githubusercontent.com/code-yeongyu/oh-my-opencode/master/assets/oh-my-opencode.schema.json",
  "google_auth": false,
  "disabled_mcps": ["context7"],
  "agents": {}
}
EOF
        print_success "Created $omo_config"
        print_info "Note: context7 MCP disabled in OmO (aidevops configures it separately)"
    fi
    
    print_success "Oh-My-OpenCode plugin configured"
    echo ""
    print_info "Oh-My-OpenCode features now available:"
    echo "  • Type 'ultrawork' or 'ulw' for maximum performance mode"
    echo "  • Background agents run in parallel"
    echo "  • LSP tools: lsp_hover, lsp_goto_definition, lsp_rename, etc."
    echo "  • AST-Grep: ast_grep_search, ast_grep_replace"
    echo ""
    print_info "Curated agents (use @agent-name):"
    echo "  • @oracle     - Architecture, code review (GPT 5.2)"
    echo "  • @librarian  - Docs lookup, GitHub examples (Sonnet 4.5)"
    echo "  • @explore    - Fast codebase exploration (Grok)"
    echo "  • @frontend-ui-ux-engineer - UI development (Gemini 3 Pro)"
    echo ""
    print_info "Documentation: https://github.com/code-yeongyu/oh-my-opencode"
    
    return 0
}

setup_seo_mcps() {
    print_info "Setting up SEO integrations..."
    
    # SEO services use curl-based subagents (no MCP needed)
    # Subagents: serper.md, dataforseo.md, ahrefs.md, google-search-console.md
    print_info "SEO uses curl-based subagents (zero context cost until invoked)"
    
    # Check if credentials are configured
    if [[ -f "$HOME/.config/aidevops/mcp-env.sh" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.config/aidevops/mcp-env.sh"
        
        [[ -n "$DATAFORSEO_USERNAME" ]] && print_success "DataForSEO credentials configured" || \
            print_info "DataForSEO: set DATAFORSEO_USERNAME and DATAFORSEO_PASSWORD in mcp-env.sh"
        
        [[ -n "$SERPER_API_KEY" ]] && print_success "Serper API key configured" || \
            print_info "Serper: set SERPER_API_KEY in mcp-env.sh"
        
        [[ -n "$AHREFS_API_KEY" ]] && print_success "Ahrefs API key configured" || \
            print_info "Ahrefs: set AHREFS_API_KEY in mcp-env.sh"
    else
        print_info "Configure SEO API credentials in ~/.config/aidevops/mcp-env.sh"
    fi
    
    # GSC uses MCP (OAuth2 complexity warrants it)
    local gsc_creds="$HOME/.config/aidevops/gsc-credentials.json"
    if [[ -f "$gsc_creds" ]]; then
        print_success "Google Search Console credentials configured"
    else
        print_info "GSC: Create service account JSON at $gsc_creds"
        print_info "  See: ~/.aidevops/agents/seo/google-search-console.md"
    fi

    print_info "SEO documentation: ~/.aidevops/agents/seo/"
    return 0
}

# Setup Google Analytics MCP (uses shared GSC service account credentials)
setup_google_analytics_mcp() {
    print_info "Setting up Google Analytics MCP..."
    
    local opencode_config="$HOME/.config/opencode/opencode.json"
    local gsc_creds="$HOME/.config/aidevops/gsc-credentials.json"
    
    # Check if opencode.json exists
    if [[ ! -f "$opencode_config" ]]; then
        print_warning "OpenCode config not found at $opencode_config - skipping Google Analytics MCP"
        return 0
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        print_warning "jq not found - cannot add Google Analytics MCP to config"
        print_info "Install jq and re-run setup, or manually add the MCP config"
        return 0
    fi
    
    # Check if pipx is available
    if ! command -v pipx &> /dev/null; then
        print_warning "pipx not found - Google Analytics MCP requires pipx"
        print_info "Install pipx: brew install pipx (macOS) or pip install pipx"
        print_info "Then re-run setup to add Google Analytics MCP"
        return 0
    fi
    
    # Auto-detect credentials from shared GSC service account
    local creds_path=""
    local project_id=""
    local enable_mcp="false"
    
    if [[ -f "$gsc_creds" ]]; then
        creds_path="$gsc_creds"
        # Extract project_id from service account JSON
        project_id=$(jq -r '.project_id // empty' "$gsc_creds" 2>/dev/null)
        if [[ -n "$project_id" ]]; then
            enable_mcp="true"
            print_success "Found GSC credentials - sharing with Google Analytics MCP"
            print_info "Project: $project_id"
        fi
    fi
    
    # Check if google-analytics-mcp already exists in config
    if jq -e '.mcp["google-analytics-mcp"]' "$opencode_config" > /dev/null 2>&1; then
        # Update existing entry if we have credentials now
        if [[ "$enable_mcp" == "true" ]]; then
            local tmp_config
            tmp_config=$(mktemp)
            if jq --arg creds "$creds_path" --arg proj "$project_id" \
                '.mcp["google-analytics-mcp"].environment.GOOGLE_APPLICATION_CREDENTIALS = $creds |
                 .mcp["google-analytics-mcp"].environment.GOOGLE_PROJECT_ID = $proj |
                 .mcp["google-analytics-mcp"].enabled = true' \
                "$opencode_config" > "$tmp_config" 2>/dev/null; then
                mv "$tmp_config" "$opencode_config"
                print_success "Updated Google Analytics MCP with GSC credentials (enabled)"
            else
                rm -f "$tmp_config"
                print_warning "Failed to update Google Analytics MCP config"
            fi
        else
            print_info "Google Analytics MCP already configured in OpenCode"
        fi
        return 0
    fi
    
    # Add google-analytics-mcp to opencode.json
    local tmp_config
    tmp_config=$(mktemp)
    
    if jq --arg creds "$creds_path" --arg proj "$project_id" --argjson enabled "$enable_mcp" \
        '.mcp["google-analytics-mcp"] = {
        "type": "local",
        "command": ["analytics-mcp"],
        "environment": {
            "GOOGLE_APPLICATION_CREDENTIALS": $creds,
            "GOOGLE_PROJECT_ID": $proj
        },
        "enabled": $enabled
    }' "$opencode_config" > "$tmp_config" 2>/dev/null; then
        mv "$tmp_config" "$opencode_config"
        if [[ "$enable_mcp" == "true" ]]; then
            print_success "Added Google Analytics MCP to OpenCode (enabled with GSC credentials)"
        else
            print_success "Added Google Analytics MCP to OpenCode (disabled - no credentials found)"
            print_info "To enable: Create service account JSON at $gsc_creds"
        fi
        print_info "Or use the google-analytics subagent which enables it automatically"
    else
        rm -f "$tmp_config"
        print_warning "Failed to add Google Analytics MCP to config"
    fi
    
    # Show setup instructions
    print_info "Google Analytics MCP setup:"
    print_info "  1. Enable Google Analytics Admin & Data APIs in Google Cloud Console"
    print_info "  2. Configure ADC: gcloud auth application-default login --scopes https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform"
    print_info "  3. Update GOOGLE_APPLICATION_CREDENTIALS path in opencode.json"
    print_info "  4. Set GOOGLE_PROJECT_ID in opencode.json"
    print_info "Documentation: ~/.aidevops/agents/services/analytics/google-analytics.md"
    
    return 0
}

# Setup multi-tenant credential storage
setup_multi_tenant_credentials() {
    print_info "Multi-tenant credential storage..."
    
    local credential_helper="$HOME/.aidevops/agents/scripts/credential-helper.sh"
    
    if [[ ! -f "$credential_helper" ]]; then
        # Try local script if deployed version not available yet
        credential_helper=".agent/scripts/credential-helper.sh"
    fi
    
    if [[ ! -f "$credential_helper" ]]; then
        print_warning "credential-helper.sh not found - skipping"
        return 0
    fi
    
    # Check if already initialized
    if [[ -d "$HOME/.config/aidevops/tenants" ]]; then
        local tenant_count
        tenant_count=$(find "$HOME/.config/aidevops/tenants" -maxdepth 1 -type d | wc -l)
        # Subtract 1 for the tenants/ dir itself
        tenant_count=$((tenant_count - 1))
        print_success "Multi-tenant already initialized ($tenant_count tenant(s))"
        bash "$credential_helper" status
        return 0
    fi
    
    # Check if there are existing credentials to migrate
    if [[ -f "$HOME/.config/aidevops/mcp-env.sh" ]]; then
        local key_count
        key_count=$(grep -c "^export " "$HOME/.config/aidevops/mcp-env.sh" 2>/dev/null || echo "0")
        print_info "Found $key_count existing API keys in mcp-env.sh"
        print_info "Multi-tenant enables managing separate credential sets for:"
        echo "  - Multiple clients (agency/freelance work)"
        echo "  - Multiple environments (production, staging)"
        echo "  - Multiple accounts (personal, work)"
        echo ""
        print_info "Your existing keys will be migrated to a 'default' tenant."
        print_info "Everything continues to work as before - this is non-breaking."
        echo ""
        
        read -r -p "Enable multi-tenant credential storage? (y/n): " enable_mt
        enable_mt=$(echo "$enable_mt" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$enable_mt" == "y" || "$enable_mt" == "yes" ]]; then
            bash "$credential_helper" init
            print_success "Multi-tenant credential storage enabled"
            echo ""
            print_info "Quick start:"
            echo "  credential-helper.sh create client-name    # Create a tenant"
            echo "  credential-helper.sh switch client-name    # Switch active tenant"
            echo "  credential-helper.sh set KEY val --tenant X  # Add key to tenant"
            echo "  credential-helper.sh status                # Show current state"
        else
            print_info "Skipped. Enable later: credential-helper.sh init"
        fi
    else
        print_info "No existing credentials found. Multi-tenant available when needed."
        print_info "Enable later: credential-helper.sh init"
    fi
    
    return 0
}

# Check for tool updates after setup
check_tool_updates() {
    print_info "Checking for tool updates..."
    
    local tool_check_script="$HOME/.aidevops/agents/scripts/tool-version-check.sh"
    
    if [[ ! -f "$tool_check_script" ]]; then
        # Try local script if deployed version not available yet
        tool_check_script=".agent/scripts/tool-version-check.sh"
    fi
    
    if [[ ! -f "$tool_check_script" ]]; then
        print_warning "Tool version check script not found - skipping update check"
        return 0
    fi
    
    # Run the check in quiet mode first to see if there are updates
    # Capture both output and exit code
    local outdated_output
    local check_exit_code
    outdated_output=$(bash "$tool_check_script" --quiet 2>&1) || check_exit_code=$?
    check_exit_code=${check_exit_code:-0}
    
    # If the script failed, warn and continue
    if [[ $check_exit_code -ne 0 ]]; then
        print_warning "Tool version check encountered an error (exit code: $check_exit_code)"
        print_info "Run 'aidevops update-tools' manually to check for updates"
        return 0
    fi
    
    if [[ -z "$outdated_output" ]]; then
        print_success "All tools are up to date!"
        return 0
    fi
    
    # Show what's outdated
    echo ""
    print_warning "Some tools have updates available:"
    echo ""
    bash "$tool_check_script" --quiet
    echo ""
    
    read -r -p "Update all outdated tools now? (y/n): " do_update
    
    if [[ "$do_update" == "y" || "$do_update" == "Y" ]]; then
        print_info "Updating tools..."
        bash "$tool_check_script" --update
        print_success "Tool updates complete!"
    else
        print_info "Skipped tool updates"
        print_info "Run 'aidevops update-tools' anytime to update tools"
    fi
    
    return 0
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --clean)
                CLEAN_MODE=true
                shift
                ;;
            --interactive|-i)
                INTERACTIVE_MODE=true
                shift
                ;;
            --update|-u)
                UPDATE_TOOLS_MODE=true
                shift
                ;;
            --help|-h)
                echo "Usage: ./setup.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --clean        Remove stale files before deploying (cleans ~/.aidevops/agents/)"
                echo "  --interactive  Ask confirmation before each step"
                echo "  -i             Short for --interactive"
                echo "  --update       Check for and offer to update outdated tools after setup"
                echo "  -u             Short for --update"
                echo "  --help         Show this help message"
                echo ""
                echo "Default behavior adds/overwrites files without removing deleted agents."
                echo "Use --clean after removing or renaming agents to sync deletions."
                echo "Use --interactive to control each step individually."
                echo "Use --update to check for tool updates after setup completes."
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Main setup function
main() {
    # Bootstrap first (handles curl install)
    bootstrap_repo "$@"
    
    parse_args "$@"
    
    echo "🤖 AI DevOps Framework Setup"
    echo "============================="
    if [[ "$CLEAN_MODE" == "true" ]]; then
        echo "Mode: Clean (removing stale files)"
    fi
    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        echo "Mode: Interactive (confirm each step)"
        echo ""
        echo "Controls: [Y]es (default) / [n]o skip / [q]uit"
    fi
    if [[ "$UPDATE_TOOLS_MODE" == "true" ]]; then
        echo "Mode: Update (will check for tool updates after setup)"
    fi
    echo ""

    # Required steps (always run)
    verify_location
    check_requirements
    
    # Optional steps with confirmation in interactive mode
    confirm_step "Check optional dependencies (bun, node, python)" && check_optional_deps
    confirm_step "Setup recommended tools (Tabby, Zed, etc.)" && setup_recommended_tools
    confirm_step "Setup MiniSim (iOS/Android emulator launcher)" && setup_minisim
    confirm_step "Setup Git CLIs (gh, glab, tea)" && setup_git_clis
    confirm_step "Setup file discovery tools (fd, ripgrep)" && setup_file_discovery_tools
    confirm_step "Setup Worktrunk (git worktree management)" && setup_worktrunk
    confirm_step "Setup SSH key" && setup_ssh_key
    confirm_step "Setup configuration files" && setup_configs
    confirm_step "Set secure permissions on config files" && set_permissions
    confirm_step "Install aidevops CLI command" && install_aidevops_cli
    confirm_step "Setup shell aliases" && setup_aliases
    confirm_step "Setup terminal title integration" && setup_terminal_title
    confirm_step "Deploy AI templates to home directories" && deploy_ai_templates
    confirm_step "Migrate old backups to new structure" && migrate_old_backups
    confirm_step "Migrate loop state from .claude/ to .agent/loop-state/" && migrate_loop_state_directories
    confirm_step "Cleanup deprecated agent paths" && cleanup_deprecated_paths
    confirm_step "Cleanup deprecated MCP entries (hetzner, serper, etc.)" && cleanup_deprecated_mcps
    confirm_step "Extract OpenCode prompts" && extract_opencode_prompts
    confirm_step "Check OpenCode prompt drift" && check_opencode_prompt_drift
    confirm_step "Deploy aidevops agents to ~/.aidevops/agents/" && deploy_aidevops_agents
    confirm_step "Setup multi-tenant credential storage" && setup_multi_tenant_credentials
    confirm_step "Generate agent skills (SKILL.md files)" && generate_agent_skills
    confirm_step "Create symlinks for imported skills" && create_skill_symlinks
    confirm_step "Check for skill updates from upstream" && check_skill_updates
    confirm_step "Inject agents reference into AI configs" && inject_agents_reference
    confirm_step "Update OpenCode configuration" && update_opencode_config
    confirm_step "Setup Python environment (DSPy, crawl4ai)" && setup_python_env
    confirm_step "Setup Node.js environment" && setup_nodejs_env
    confirm_step "Install MCP packages globally (fast startup)" && install_mcp_packages
    confirm_step "Setup LocalWP MCP server" && setup_localwp_mcp
    confirm_step "Setup Augment Context Engine MCP" && setup_augment_context_engine
    confirm_step "Setup osgrep (local semantic search)" && setup_osgrep
    confirm_step "Setup Beads task management" && setup_beads
    confirm_step "Setup SEO integrations (curl subagents)" && setup_seo_mcps
    confirm_step "Setup Google Analytics MCP" && setup_google_analytics_mcp
    confirm_step "Setup browser automation tools" && setup_browser_tools
    confirm_step "Setup AI orchestration frameworks info" && setup_ai_orchestration
    confirm_step "Setup OpenCode plugins" && setup_opencode_plugins
    confirm_step "Setup Oh-My-OpenCode" && setup_oh_my_opencode

    echo ""
    print_success "🎉 Setup complete!"
    echo ""
echo "CLI Command:"
echo "  aidevops init         - Initialize aidevops in a project"
echo "  aidevops features     - List available features"
echo "  aidevops status       - Check installation status"
echo "  aidevops update       - Update to latest version"
echo "  aidevops update-tools - Check for and update installed tools"
echo "  aidevops uninstall    - Remove aidevops"
    echo ""
    echo "Deployed to:"
    echo "  ~/.aidevops/agents/     - Agent files (main agents, subagents, scripts)"
    echo "  ~/.aidevops/*-backups/  - Backups with rotation (keeps last $BACKUP_KEEP_COUNT)"
    echo ""
    echo "Next steps:"
    echo "1. Edit configuration files in configs/ with your actual credentials"
    echo "2. Setup Git CLI tools and authentication (shown during setup)"
    echo "3. Setup API keys: bash .agent/scripts/setup-local-api-keys.sh setup"
    echo "4. Test access: ./.agent/scripts/servers-helper.sh list"
    echo "5. Read documentation: ~/.aidevops/agents/AGENTS.md"
    echo ""
    echo "For development on aidevops framework itself:"
    echo "  See ~/Git/aidevops/AGENTS.md"
    echo ""
    echo "OpenCode Primary Agents (12 total, Tab to switch):"
    echo "• Plan+      - Enhanced planning with context tools (read-only)"
    echo "• Build+     - Enhanced build with context tools (full access)"
    echo "• Accounts, AI-DevOps, Content, Health, Legal, Marketing,"
    echo "  Research, Sales, SEO, WordPress"
    echo ""
    echo "Agent Skills (SKILL.md) - Cross-tool compatibility:"
    echo "• Cursor, Claude Code, VS Code, GitHub Copilot auto-discover skills"
    echo "• 21 SKILL.md files generated in ~/.aidevops/agents/"
    echo "• Skills include: wordpress, seo, aidevops, build-mcp, and more"
    echo ""
    echo "MCP Integrations (OpenCode):"
    echo "• Augment Context Engine - Cloud semantic codebase retrieval"
    echo "• Context7               - Real-time library documentation"
    echo "• osgrep                 - Local semantic search (100% private)"
    echo "• GSC                    - Google Search Console (MCP + OAuth2)"
    echo "• Google Analytics       - Analytics data (shared GSC credentials)"
    echo ""
    echo "SEO Integrations (curl subagents - no MCP overhead):"
    echo "• DataForSEO             - Comprehensive SEO data APIs"
    echo "• Serper                 - Google Search API"
    echo "• Ahrefs                 - Backlink and keyword data"
    echo ""
    echo "DSPy & DSPyGround Integration:"
    echo "• ./.agent/scripts/dspy-helper.sh        - DSPy prompt optimization toolkit"
    echo "• ./.agent/scripts/dspyground-helper.sh  - DSPyGround playground interface"
    echo "• python-env/dspy-env/              - Python virtual environment for DSPy"
    echo "• data/dspy/                        - DSPy projects and datasets"
    echo "• data/dspyground/                  - DSPyGround projects and configurations"
    echo ""
    echo "Task Management:"
    echo "• Beads CLI (bd)                    - Task graph visualization"
    echo "• beads-sync-helper.sh              - Sync TODO.md/PLANS.md with Beads"
    echo "• todo-ready.sh                     - Show tasks with no open blockers"
    echo "• Run: aidevops init beads          - Initialize Beads in a project"
    echo ""
    echo "Security reminders:"
    echo "- Never commit configuration files with real credentials"
    echo "- Use strong passwords and enable MFA on all accounts"
    echo "- Regularly rotate API tokens and SSH keys"
    echo ""
    echo "Happy server managing! 🚀"
    echo ""
    
    # Check for tool updates if --update flag was passed
    if [[ "$UPDATE_TOOLS_MODE" == "true" ]]; then
        echo ""
        check_tool_updates
    fi
    
    # Offer to launch onboarding for new users (only if not running inside OpenCode)
    if [[ -z "${OPENCODE_SESSION:-}" ]] && command -v opencode &>/dev/null; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "🎯 Ready to configure your services?"
        echo ""
        echo "Launch OpenCode with the onboarding wizard to:"
        echo "  • See which services are already configured"
        echo "  • Get personalized recommendations based on your work"
        echo "  • Set up API keys and credentials interactively"
        echo ""
        read -r -p "Launch OpenCode with /onboarding now? (y/n): " launch_onboarding
        if [[ "$launch_onboarding" == "y" || "$launch_onboarding" == "Y" ]]; then
            echo ""
            echo "Starting OpenCode..."
            opencode --prompt "/onboarding"
        else
            echo ""
            echo "You can run /onboarding anytime in OpenCode to configure services."
        fi
    fi
    
    return 0
}

# Run setup
main "$@"
