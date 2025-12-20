#!/bin/bash

# AI Assistant Server Access Framework Setup Script
# Helps developers set up the framework for their infrastructure
#
# Version: 2.34.0
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
REPO_URL="https://github.com/marcusquinn/aidevops.git"
INSTALL_DIR="$HOME/Git/aidevops"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

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
    
    # Copy AI context template
    if [[ ! -f "ai-context.md" ]]; then
        cp "ai-context.md.txt" "ai-context.md"
        print_success "Created ai-context.md"
        print_warning "Please customize ai-context.md with your infrastructure details"
    else
        print_info "Found existing ai-context.md - Skipping"
    fi
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
        
        # Check if ~/.local/bin is in PATH
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            print_warning "Add ~/.local/bin to your PATH for the 'aidevops' command"
            print_info "Add this to your shell config: export PATH=\"\$HOME/.local/bin:\$PATH\""
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

# Deploy aidevops agents to user location
deploy_aidevops_agents() {
    print_info "Deploying aidevops agents to ~/.aidevops/agents/..."
    
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local source_dir="$script_dir/.agent"
    local target_dir="$HOME/.aidevops/agents"
    local backup_base="$HOME/.aidevops/config-backups"
    local backup_dir="$backup_base/$(date +%Y%m%d_%H%M%S)"
    
    # Create backup if target exists
    if [[ -d "$target_dir" ]]; then
        mkdir -p "$backup_dir"
        cp -R "$target_dir" "$backup_dir/"
        print_info "Backed up existing agents to $backup_dir"
    fi
    
    # Create target directory and copy agents
    mkdir -p "$target_dir"
    
    # If clean mode, remove stale files first
    if [[ "$CLEAN_MODE" == "true" ]]; then
        print_info "Clean mode: removing stale files from $target_dir"
        rm -rf "${target_dir:?}"/*
    fi
    
    # Copy all agent files and folders (excluding scripts which are large)
    # We copy scripts separately to maintain structure
    cp -R "$source_dir"/* "$target_dir/"
    
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
    else
        print_error "Failed to deploy agents"
        return 1
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
    local backup_base="$HOME/.aidevops/config-backups"
    local backup_dir="$backup_base/$(date +%Y%m%d_%H%M%S)"
    
    if [[ ! -f "$opencode_config" ]]; then
        print_info "OpenCode config not found at $opencode_config - skipping"
        return 0
    fi
    
    # Create backup
    mkdir -p "$backup_dir"
    cp "$opencode_config" "$backup_dir/opencode.json"
    print_info "Backed up opencode.json to $backup_dir"
    
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

# Configure AI CLI tools to read AGENTS.md automatically
configure_ai_clis() {
    print_info "Configuring AI CLI tools to read AGENTS.md automatically..."

    local ai_config_script=".agent/scripts/ai-cli-config.sh"

    if [[ -f "$ai_config_script" ]]; then
        if bash "$ai_config_script"; then
            print_success "AI CLI tools configured successfully"
        else
            print_warning "AI CLI configuration encountered some issues (non-critical)"
        fi
    else
        print_warning "AI CLI configuration script not found at $ai_config_script"
    fi
    return 0
}

# Setup Python environment for DSPy
setup_python_env() {
    print_info "Setting up Python environment for DSPy..."

    # Check if Python 3 is available
    if ! command -v python3 &> /dev/null; then
        print_warning "Python 3 not found - DSPy setup skipped"
        print_info "Install Python 3.8+ to enable DSPy integration"
        return
    fi

    local python_version=$(python3 --version | cut -d' ' -f2 | cut -d'.' -f1-2)
    local version_check=$(python3 -c "import sys; print(1 if sys.version_info >= (3, 8) else 0)")

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
    source python-env/dspy-env/bin/activate
    pip install --upgrade pip > /dev/null 2>&1
    pip install -r requirements.txt > /dev/null 2>&1

    if [[ $? -eq 0 ]]; then
        print_success "DSPy dependencies installed successfully"
    else
        print_warning "Failed to install DSPy dependencies - check requirements.txt"
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

    # The actual MCP configuration is handled by ai-cli-config.sh
    # which is called via configure_ai_clis
    # This function just validates prerequisites

    print_info "Augment Context Engine will be configured by ai-cli-config.sh"
    print_info "Supported tools: OpenCode, Cursor, Gemini CLI, Claude Code, Droid"
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
            if bash "$AGENTS_DIR/scripts/dev-browser-helper.sh" setup 2>/dev/null; then
                print_success "dev-browser installed"
                print_info "Start server with: bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start"
            else
                print_warning "dev-browser setup failed - run manually:"
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
    
    print_info "Browser tools: dev-browser (stateful), Playwriter (extension), Stagehand (AI)"
}

# Setup OpenCode Plugins (Antigravity OAuth)
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
    
    # Plugin to install/update
    local plugin_name="opencode-antigravity-auth"
    local plugin_spec="opencode-antigravity-auth@latest"
    
    # Check if plugin array exists and if plugin is already configured
    local has_plugin_array
    has_plugin_array=$(jq -e '.plugin' "$opencode_config" 2>/dev/null && echo "true" || echo "false")
    
    if [[ "$has_plugin_array" == "true" ]]; then
        # Check if plugin is already in the array
        local plugin_exists
        plugin_exists=$(jq -e --arg p "$plugin_name" '.plugin | map(select(startswith($p))) | length > 0' "$opencode_config" 2>/dev/null && echo "true" || echo "false")
        
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
    
    print_info "Antigravity OAuth plugin enables Google OAuth for OpenCode"
    print_info "After setup, authenticate with: opencode auth login"
    print_info "Then select 'Google' → 'OAuth with Google (Antigravity)'"
    print_info "Models available: gemini-3-pro-high, claude-opus-4-5-thinking, etc."
    print_info "See: https://github.com/NoeFabris/opencode-antigravity-auth"
    
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
    has_plugin_array=$(jq -e '.plugin' "$opencode_config" 2>/dev/null && echo "true" || echo "false")
    
    if [[ "$has_plugin_array" == "true" ]]; then
        # Check if plugin is already in the array
        local plugin_exists
        plugin_exists=$(jq -e --arg p "$plugin_name" '.plugin | map(select(. == $p or startswith($p + "@"))) | length > 0' "$opencode_config" 2>/dev/null && echo "true" || echo "false")
        
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
    print_info "Setting up SEO MCP servers..."

    local has_node=false
    local has_python=false
    local has_uv=false

    # Check Node.js
    if command -v node &> /dev/null; then
        has_node=true
    fi

    # Check Python
    if command -v python3 &> /dev/null; then
        has_python=true
    fi

    # Check uv (Python package manager)
    if command -v uv &> /dev/null; then
        has_uv=true
    elif command -v uvx &> /dev/null; then
        has_uv=true
    fi

    # DataForSEO MCP (Node.js based)
    if [[ "$has_node" == "true" ]]; then
        print_info "DataForSEO MCP available via: npx dataforseo-mcp-server"
        print_info "Configure credentials in ~/.config/aidevops/mcp-env.sh:"
        print_info "  DATAFORSEO_USERNAME and DATAFORSEO_PASSWORD"
    else
        print_warning "Node.js not found - DataForSEO MCP requires Node.js"
    fi

    # Serper MCP (Python based, uses uv/uvx)
    if [[ "$has_uv" == "true" ]]; then
        print_info "Serper MCP available via: uvx serper-mcp-server"
        print_info "Configure credentials in ~/.config/aidevops/mcp-env.sh:"
        print_info "  SERPER_API_KEY"
    elif [[ "$has_python" == "true" ]]; then
        print_info "Serper MCP available via: pip install serper-mcp-server"
        print_info "Then run: python3 -m serper_mcp_server"
        print_info "Configure credentials in ~/.config/aidevops/mcp-env.sh:"
        print_info "  SERPER_API_KEY"
        
        # Offer to install uv for better experience
        read -r -p "Install uv (recommended Python package manager)? (y/n): " install_uv
        if [[ "$install_uv" == "y" ]]; then
            print_info "Installing uv..."
            curl -LsSf https://astral.sh/uv/install.sh | sh
            if [[ $? -eq 0 ]]; then
                print_success "uv installed successfully"
                print_info "Restart your terminal or run: source ~/.bashrc (or ~/.zshrc)"
            else
                print_warning "Failed to install uv"
            fi
        fi
    else
        print_warning "Python not found - Serper MCP requires Python 3.11+"
    fi

    # Check if credentials are configured
    if [[ -f "$HOME/.config/aidevops/mcp-env.sh" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.config/aidevops/mcp-env.sh"
        
        if [[ -n "$DATAFORSEO_USERNAME" && -n "$DATAFORSEO_PASSWORD" ]]; then
            print_success "DataForSEO credentials configured"
        else
            print_info "DataForSEO: Set credentials with:"
            print_info "  bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_USERNAME your_username"
            print_info "  bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_PASSWORD your_password"
        fi
        
        if [[ -n "$SERPER_API_KEY" ]]; then
            print_success "Serper API key configured"
        else
            print_info "Serper: Set API key with:"
            print_info "  bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set SERPER_API_KEY your_key"
        fi
    else
        print_info "Configure SEO API credentials:"
        print_info "  bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh setup"
    fi

    print_info "SEO MCP documentation: ~/.aidevops/agents/seo/"
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
            --help|-h)
                echo "Usage: ./setup.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --clean    Remove stale files before deploying (cleans ~/.aidevops/agents/)"
                echo "  --help     Show this help message"
                echo ""
                echo "Default behavior adds/overwrites files without removing deleted agents."
                echo "Use --clean after removing or renaming agents to sync deletions."
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
    echo ""

    verify_location
    check_requirements
    check_optional_deps
    setup_recommended_tools
    setup_git_clis
    setup_ssh_key
    setup_configs
    set_permissions
    install_aidevops_cli
    setup_aliases
    deploy_ai_templates
    deploy_aidevops_agents
    inject_agents_reference
    update_opencode_config
    configure_ai_clis
    setup_python_env
    setup_nodejs_env
    setup_augment_context_engine
    setup_osgrep
    setup_seo_mcps
    setup_browser_tools
    setup_opencode_plugins
    setup_oh_my_opencode

    echo ""
    print_success "🎉 Setup complete!"
    echo ""
echo "CLI Command:"
echo "  aidevops init       - Initialize aidevops in a project"
echo "  aidevops features   - List available features"
echo "  aidevops status     - Check installation status"
echo "  aidevops update     - Update to latest version"
echo "  aidevops uninstall  - Remove aidevops"
    echo ""
    echo "Deployed to:"
    echo "  ~/.aidevops/agents/     - Agent files (main agents, subagents, scripts)"
    echo "  ~/.aidevops/config-backups/ - Backups of previous configurations"
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
    echo "• Accounting, AI-DevOps, Content, Health, Legal, Marketing,"
    echo "  Research, Sales, SEO, WordPress"
    echo ""
    echo "AI CLI Tools (configured to read AGENTS.md automatically):"
    echo "• aider-guided    - Aider with AGENTS.md context"
    echo "• claude-guided   - Claude CLI with AGENTS.md context"
    echo "• qwen-guided     - Qwen CLI with AGENTS.md context"
    echo "• windsurf-guided - Windsurf IDE with AGENTS.md context"
    echo "• ai-with-context - Universal wrapper for any AI tool"
    echo "• agents          - View repository AGENTS.md"
    echo "• cdai            - Navigate to AI framework"
    echo ""
    echo "MCP Integrations:"
    echo "• Augment Context Engine - Cloud semantic codebase retrieval"
    echo "• Context7               - Real-time library documentation"
    echo "• Repomix                - Token-efficient codebase packing"
    echo "• DataForSEO             - Comprehensive SEO data APIs"
    echo "• Serper                 - Google Search API"
    echo ""
    echo "CLI Tools (use via bash):"
    echo "• osgrep                 - Local semantic search (100% private)"
    echo "                           Usage: osgrep \"search query\""
    echo ""
    echo "AI Memory Files (created for comprehensive tool support):"
    echo "• ~/CLAUDE.md     - Claude CLI memory file"
    echo "• ~/GEMINI.md     - Gemini CLI memory file"
    echo "• ~/.qwen/QWEN.md - Qwen CLI memory file"
    echo "• ~/WINDSURF.md   - Windsurf IDE memory file"
    echo "• ~/.cursorrules  - Cursor AI rules file"
    echo "• ~/.github/copilot-instructions.md - GitHub Copilot instructions"
    echo "• ~/.factory/DROID.md   - Factory.ai Droid memory file"
    echo "• ~/.codeium/windsurf/memories/global_rules.md - Windsurf global rules"
    echo ""
    echo "DSPy & DSPyGround Integration:"
    echo "• ./.agent/scripts/dspy-helper.sh        - DSPy prompt optimization toolkit"
    echo "• ./.agent/scripts/dspyground-helper.sh  - DSPyGround playground interface"
    echo "• python-env/dspy-env/              - Python virtual environment for DSPy"
    echo "• data/dspy/                        - DSPy projects and datasets"
    echo "• data/dspyground/                  - DSPyGround projects and configurations"
    echo ""
    echo "Security reminders:"
    echo "- Never commit configuration files with real credentials"
    echo "- Use strong passwords and enable MFA on all accounts"
    echo "- Regularly rotate API tokens and SSH keys"
    echo ""
    echo "Happy server managing! 🚀"
    return 0
}

# Run setup
main "$@"
