#!/bin/bash

# AI Assistant Server Access Framework Setup Script
# Helps developers set up the framework for their infrastructure
#
# Version: 2.6.0

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check system requirements
check_requirements() {
    print_info "Checking system requirements..."
    
    local missing_deps=()
    
    # Check for required commands
    command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    command -v ssh >/dev/null 2>&1 || missing_deps+=("ssh")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo ""
        echo "Install missing dependencies:"
        echo "  macOS: brew install ${missing_deps[*]}"
        echo "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
        echo "  CentOS/RHEL: sudo yum install ${missing_deps[*]}"
        exit 1
    fi
    
    print_success "All required dependencies found"
}

# Check for optional dependencies
check_optional_deps() {
    print_info "Checking optional dependencies..."
    
    if ! command -v sshpass >/dev/null 2>&1; then
        print_warning "sshpass not found - needed for password-based SSH (like Hostinger)"
        echo "  Install: brew install sshpass (macOS) or sudo apt-get install sshpass (Linux)"
    else
        print_success "sshpass found"
    fi
    return 0
}

# Setup Git CLI tools
setup_git_clis() {
    print_info "Setting up Git CLI tools..."
    
    local cli_tools=()
    local installs_needed=()
    
    # Check for GitHub CLI
    if ! command -v gh >/dev/null 2>&1; then
        print_warning "GitHub CLI (gh) not found"
        echo "  GitHub CLI provides enhanced GitHub integration"
        echo "  Install: brew install gh (macOS) or sudo apt install gh (Ubuntu)"
        echo "  Alternative: https://cli.github.com/manual/installation"
        installs_needed+=("GitHub CLI")
    else
        cli_tools+=("GitHub CLI")
    fi
    
    # Check for GitLab CLI
    if ! command -v glab >/dev/null 2>&1; then
        print_warning "GitLab CLI (glab) not found"
        echo "  GitLab CLI provides enhanced GitLab integration"
        echo "  Install: brew install glab (macOS) or sudo apt install glab (Ubuntu)"
        echo "  Alternative: https://glab.readthedocs.io/en/latest/installation/"
        installs_needed+=("GitLab CLI")
    else
        cli_tools+=("GitLab CLI")
    fi
    
    # Check for Gitea CLI
    if ! command -v tea >/dev/null 2>&1; then
        print_warning "Gitea CLI (tea) not found"
        echo "  Gitea CLI provides enhanced Gitea integration"
        echo "  Install: go install code.gitea.io/tea/cmd/tea@latest"
        echo "  Alternative: https://dl.gitea.io/tea/"
        installs_needed+=("Gitea CLI")
    else
        cli_tools+=("Gitea CLI")
    fi
    
    # Report status and provide setup guidance
    if [[ ${#cli_tools[@]} -gt 0 ]]; then
        print_success "Found Git CLI tools: ${cli_tools[*]}"
    fi
    
    if [[ ${#installs_needed[@]} -gt 0 ]]; then
        print_warning "Missing Git CLI tools: ${installs_needed[*]}"
        echo ""
        echo "🚀 BULK INSTALLATION COMMANDS:"
        echo "  macOS: brew install ${installs_needed[*]//GitHub CLI/gh} ${installs_needed[*]//GitLab CLI/glab} ${installs_needed[*]//Gitea CLI/tea}"
        echo "  Ubuntu: sudo apt install ${installs_needed[*]//GitHub CLI/gh} ${installs_needed[*]//GitLab CLI/glab} ${installs_needed[*]//Gitea CLI/tea}"
        echo ""
        echo "📋 CONFIGURATION STEPS:"
        echo "  1. GitHub CLI: gh auth login"
        echo "  2. GitLab CLI: glab auth login"  
        echo "  3. Gitea CLI: tea login add or configure API token in configs/gitea-cli-config.json"
        echo ""
        echo "📁 CONFIGURATION TEMPLATES:"
        echo "  GitHub: cp configs/github-cli-config.json.txt configs/github-cli-config.json"
        echo "  GitLab: cp configs/gitlab-cli-config.json.txt configs/gitlab-cli-config.json"
        echo "  Gitea: cp configs/gitea-cli-config.json.txt configs/gitea-cli-config.json"
        echo ""
        print_info "Git CLI helpers available in .agent/scripts/:"
        echo "  • .agent/scripts/github-cli-helper.sh - GitHub repository management"
        echo "  • .agent/scripts/gitlab-cli-helper.sh - GitLab project management"
        echo "  • .agent/scripts/gitea-cli-helper.sh - Gitea repository management"
        echo ""
        echo "📖 USAGE EXAMPLES:"
        echo "  • ./.agent/scripts/github-cli-helper.sh list-repos <account>"
        echo "  • ./.agent/scripts/gitlab-cli-helper.sh create-project <account> <name>"
        echo "  • ./.agent/scripts/gitea-cli-helper.sh create-repo <account> <repo>"
    else
        print_success "✅ All Git CLI tools installed and ready for use!"
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

# Setup shell aliases
setup_aliases() {
    print_info "Setting up shell aliases..."
    
    local shell_rc=""
    if [[ "$SHELL" == *"zsh"* ]]; then
        shell_rc="$HOME/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
        shell_rc="$HOME/.bashrc"
    else
        print_warning "Unknown shell, skipping alias setup"
        return
    fi
    
    # Check if aliases already exist
    if grep -q "# AI Assistant Server Access" "$shell_rc" 2>/dev/null; then
        print_info "Server Access aliases already configured in $shell_rc - Skipping"
        return
    fi
    
    read -r -p "Add shell aliases to $shell_rc? (y/n): " add_aliases
    
    if [[ "$add_aliases" == "y" ]]; then
        cat >> "$shell_rc" << 'EOF'

# AI Assistant Server Access Framework
alias servers='./.agent/scripts/servers-helper.sh'
alias servers-list='./.agent/scripts/servers-helper.sh list'
alias hostinger='./.agent/scripts/hostinger-helper.sh'
alias hetzner='./.agent/scripts/hetzner-helper.sh'
alias aws-helper='./.agent/scripts/aws-helper.sh'
EOF
        print_success "Aliases added to $shell_rc"
        print_info "Run 'source $shell_rc' or restart your terminal to use aliases"
    else
        print_info "Skipped alias setup by user request"
    fi
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

# Main setup function
main() {
    echo "🤖 AI DevOps Framework Setup"
    echo "============================="
    echo ""

    verify_location
    check_requirements
    check_optional_deps
    setup_git_clis
    setup_ssh_key
    setup_configs
    set_permissions
    setup_aliases
    deploy_ai_templates
    deploy_aidevops_agents
    inject_agents_reference
    update_opencode_config
    configure_ai_clis
    setup_python_env
    setup_nodejs_env
    setup_augment_context_engine

    echo ""
    print_success "🎉 Setup complete!"
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
    echo "• Augment Context Engine - Semantic codebase retrieval"
    echo "• Context7               - Real-time library documentation"
    echo "• Repomix                - Token-efficient codebase packing"
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
