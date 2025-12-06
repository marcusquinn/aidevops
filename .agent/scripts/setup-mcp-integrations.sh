#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# 🚀 Advanced MCP Integrations Setup Script
# Sets up powerful Model Context Protocol integrations for AI-assisted development

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

print_header() { local msg="$1"; echo -e "${PURPLE}$msg${NC}"; return 0; }
print_info() { local msg="$1"; echo -e "${BLUE}$msg${NC}"; return 0; }
print_success() { local msg="$1"; echo -e "${GREEN}✅ $msg${NC}"; return 0; }
print_warning() { local msg="$1"; echo -e "${YELLOW}⚠️  $msg${NC}"; return 0; }
print_error() { local msg="$1"; echo -e "${RED}❌ $msg${NC}"; return 0; }

# Available MCP integrations
get_mcp_command() {
    local integration="$1"
    case "$integration" in
        "chrome-devtools") echo "npx chrome-devtools-mcp@latest" ;;
        "playwright") echo "npx playwright-mcp@latest" ;;
        "cloudflare-browser") echo "npx cloudflare-browser-rendering-mcp@latest" ;;
        "ahrefs") echo "npx -y @ahrefs/mcp@latest" ;;
        "perplexity") echo "npx perplexity-mcp@latest" ;;
        "nextjs-devtools") echo "npx next-devtools-mcp@latest" ;;
        "google-search-console") echo "npx mcp-server-gsc@latest" ;;
        "pagespeed-insights") echo "npx mcp-pagespeed-server@latest" ;;
        "grep-vercel") echo "remote:https://mcp.grep.app" ;;
        "stagehand") echo "node ${HOME}/.aidevops/stagehand/examples/basic-example.js" ;;
        "stagehand-python") echo "${HOME}/.aidevops/stagehand-python/.venv/bin/python ${HOME}/.aidevops/stagehand-python/examples/basic_example.py" ;;
        "stagehand-both") echo "both" ;;
        *) echo "" ;;
    esac
    return 0
}

# Available integrations list
MCP_LIST="chrome-devtools playwright cloudflare-browser ahrefs perplexity nextjs-devtools google-search-console pagespeed-insights grep-vercel stagehand stagehand-python stagehand-both"

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check Node.js
    if ! command -v node &> /dev/null; then
        print_error "Node.js is required but not installed"
        print_info "Install Node.js from: https://nodejs.org/"
        exit 1
    fi
    
    local node_version
    node_version=$(node --version | cut -d'v' -f2)
    print_success "Node.js version: $node_version"

    # Check npm
    if ! command -v npm &> /dev/null; then
        print_error "npm is required but not installed"
        exit 1
    fi

    local npm_version
    npm_version=$(npm --version)
    print_success "npm version: $npm_version"

    # Check if Claude Desktop is available
    if command -v claude &> /dev/null; then
        print_success "Claude Desktop CLI detected"
    else
        print_warning "Claude Desktop CLI not found - manual configuration will be needed"
    fi

    return 0
}

# Install specific MCP integration
install_mcp() {
    local mcp_name="$1"
    local mcp_command
    mcp_command=$(get_mcp_command "$mcp_name")

    if [[ -z "$mcp_command" ]]; then
        print_error "Unknown MCP integration: $mcp_name"
        return 1
    fi
    
    print_info "Installing $mcp_name MCP..."
    
    case "$mcp_name" in
        "chrome-devtools")
            print_info "Setting up Chrome DevTools MCP with advanced configuration..."
            if command -v claude &> /dev/null; then
                claude mcp add chrome-devtools "$mcp_command" --channel=canary --headless=true
            fi
            ;;
        "playwright")
            print_info "Installing Playwright browsers..."
            npx playwright install
            if command -v claude &> /dev/null; then
                claude mcp add playwright "$mcp_command"
            fi
            ;;
        "cloudflare-browser")
            print_warning "Cloudflare Browser Rendering requires API credentials"
            print_info "Set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN environment variables"
            ;;
        "ahrefs")
            print_warning "Ahrefs MCP requires API key"
            print_info "Get your standard 40-char API key from: https://ahrefs.com/api"
            print_info "Note: JWT-style tokens do NOT work - use the standard API key"
            print_info ""
            print_info "Store in ~/.config/aidevops/mcp-env.sh:"
            print_info "  export AHREFS_API_KEY=\"your_40_char_key\""
            print_info ""
            print_info "For OpenCode, use bash wrapper pattern in opencode.json:"
            print_info '  "ahrefs": {'
            print_info '    "type": "local",'
            print_info '    "command": ["/bin/bash", "-c", "API_KEY=\$AHREFS_API_KEY /opt/homebrew/bin/npx -y @ahrefs/mcp@latest"],'
            print_info '    "enabled": true'
            print_info '  }'
            print_info ""
            print_info "Note: The MCP expects API_KEY env var, not AHREFS_API_KEY"
            ;;
        "perplexity")
            print_warning "Perplexity MCP requires API key"
            print_info "Set PERPLEXITY_API_KEY environment variable"
            print_info "Get your API key from: https://docs.perplexity.ai/"
            ;;
        "nextjs-devtools")
            print_info "Setting up Next.js DevTools MCP..."
            if command -v claude &> /dev/null; then
                claude mcp add nextjs-devtools "$mcp_command"
            fi
            ;;
        "google-search-console")
            print_warning "Google Search Console MCP requires Google API credentials"
            print_info "Set GOOGLE_APPLICATION_CREDENTIALS environment variable"
            print_info "Get credentials from: https://console.cloud.google.com/"
            print_info "Enable Search Console API in your Google Cloud project"
            if command -v claude &> /dev/null; then
                claude mcp add google-search-console "$mcp_command"
            fi
            ;;
        "pagespeed-insights")
            print_info "Setting up PageSpeed Insights MCP for website performance auditing..."
            print_warning "Optional: Set GOOGLE_API_KEY for higher rate limits"
            print_info "Get API key from: https://console.cloud.google.com/"
            print_info "Enable PageSpeed Insights API in your Google Cloud project"
            print_info "Also installing Lighthouse CLI for comprehensive auditing..."

            # Install Lighthouse CLI if not present
            if ! command -v lighthouse &> /dev/null; then
                npm install -g lighthouse
            fi

            if command -v claude &> /dev/null; then
                claude mcp add pagespeed-insights "$mcp_command"
            fi

            print_success "PageSpeed Insights MCP setup complete!"
            print_info "Use: ./.agent/scripts/pagespeed-helper.sh for CLI access"
            ;;
        "grep-vercel")
            print_info "Setting up Grep by Vercel MCP for GitHub code search..."
            print_info "This is a remote MCP server - no local installation required"
            print_info "URL: https://mcp.grep.app"
            
            # Add to Claude MCP if available
            if command -v claude &> /dev/null; then
                claude mcp add gh_grep --url "https://mcp.grep.app"
            fi
            
            print_success "Grep by Vercel MCP setup complete!"
            print_info "Use 'gh_grep' tool in prompts to search GitHub code"
            print_info "Example: 'use gh_grep to find examples of SST Astro components'"
            ;;
        "stagehand")
            print_info "Setting up Stagehand AI Browser Automation MCP integration..."

            # First ensure Stagehand JavaScript is installed
            if ! bash "${SCRIPT_DIR}/../../.agent/scripts/stagehand-helper.sh" status &> /dev/null; then
                print_info "Installing Stagehand JavaScript first..."
                bash "${SCRIPT_DIR}/../../.agent/scripts/stagehand-helper.sh" install
            fi

            # Setup advanced configuration
            bash "${SCRIPT_DIR}/stagehand-setup.sh" setup

            # Add to Claude MCP if available
            if command -v claude &> /dev/null; then
                claude mcp add stagehand "node" --args "${HOME}/.aidevops/stagehand/examples/basic-example.js"
            fi

            print_success "Stagehand JavaScript MCP integration completed"
            print_info "Try: 'Ask Claude to help with browser automation using Stagehand'"
            print_info "Use: ./.agent/scripts/stagehand-helper.sh for CLI access"
            ;;
        "stagehand-python")
            print_info "Setting up Stagehand Python AI Browser Automation MCP integration..."

            # First ensure Stagehand Python is installed
            if ! bash "${SCRIPT_DIR}/../../.agent/scripts/stagehand-python-helper.sh" status &> /dev/null; then
                print_info "Installing Stagehand Python first..."
                bash "${SCRIPT_DIR}/../../.agent/scripts/stagehand-python-helper.sh" install
            fi

            # Setup advanced configuration
            bash "${SCRIPT_DIR}/stagehand-python-setup.sh" setup

            # Add to Claude MCP if available
            if command -v claude &> /dev/null; then
                local python_path="${HOME}/.aidevops/stagehand-python/.venv/bin/python"
                claude mcp add stagehand-python "$python_path" --args "${HOME}/.aidevops/stagehand-python/examples/basic_example.py"
            fi

            print_success "Stagehand Python MCP integration completed"
            print_info "Try: 'Ask Claude to help with Python browser automation using Stagehand'"
            print_info "Use: ./.agent/scripts/stagehand-python-helper.sh for CLI access"
            ;;
        "stagehand-both")
            print_info "Setting up both Stagehand JavaScript and Python MCP integrations..."

            # Setup JavaScript version
            bash "$0" stagehand

            # Setup Python version
            bash "$0" stagehand-python

            print_success "Both Stagehand integrations completed"
            print_info "JavaScript: ./.agent/scripts/stagehand-helper.sh"
            print_info "Python: ./.agent/scripts/stagehand-python-helper.sh"
            ;;
        *)
            print_error "Unknown MCP integration: $mcp_name"
            print_info "Available integrations: $MCP_LIST"
            return 1
            ;;
    esac
    
    print_success "$mcp_name MCP setup completed"
    return 0
}

# Create MCP configuration templates
create_config_templates() {
    print_header "Creating MCP Configuration Templates"
    
    local config_dir="configs/mcp-templates"
    mkdir -p "$config_dir"
    
    # Chrome DevTools template
    cat > "$config_dir/chrome-devtools.json" << 'EOF'
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "chrome-devtools-mcp@latest",
        "--channel=canary",
        "--headless=true",
        "--isolated=true",
        "--viewport=1920x1080",
        "--logFile=/tmp/chrome-mcp.log"
      ]
    }
  }
    return 0
}
EOF

    # Playwright template
    cat > "$config_dir/playwright.json" << 'EOF'
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["playwright-mcp@latest"]
    }
  }
}
EOF

    # Stagehand JavaScript template
    cat > "$config_dir/stagehand.json" << 'EOF'
{
  "mcpServers": {
    "stagehand": {
      "command": "node",
      "args": [
        "-e",
        "const { Stagehand } = require('@browserbasehq/stagehand'); console.log('Stagehand JavaScript AI Browser Automation Ready');"
      ],
      "env": {
        "STAGEHAND_ENV": "LOCAL",
        "STAGEHAND_VERBOSE": "1",
        "STAGEHAND_HEADLESS": "false"
      }
    }
  }
}
EOF

    # Stagehand Python template
    cat > "$config_dir/stagehand-python.json" << 'EOF'
{
  "mcpServers": {
    "stagehand-python": {
      "command": "python",
      "args": [
        "-c",
        "from stagehand import Stagehand; print('Stagehand Python AI Browser Automation Ready')"
      ],
      "env": {
        "STAGEHAND_ENV": "LOCAL",
        "STAGEHAND_VERBOSE": "1",
        "STAGEHAND_HEADLESS": "false",
        "PYTHONPATH": "${HOME}/.aidevops/stagehand-python/.venv/lib/python3.11/site-packages"
      }
    }
  }
}
EOF

    # Combined Stagehand template
    cat > "$config_dir/stagehand-both.json" << 'EOF'
{
  "mcpServers": {
    "stagehand-js": {
      "command": "node",
      "args": [
        "-e",
        "const { Stagehand } = require('@browserbasehq/stagehand'); console.log('Stagehand JavaScript Ready');"
      ],
      "env": {
        "STAGEHAND_ENV": "LOCAL",
        "STAGEHAND_VERBOSE": "1",
        "STAGEHAND_HEADLESS": "false"
      }
    },
    "stagehand-python": {
      "command": "python",
      "args": [
        "-c",
        "from stagehand import Stagehand; print('Stagehand Python Ready')"
      ],
      "env": {
        "STAGEHAND_ENV": "LOCAL",
        "STAGEHAND_VERBOSE": "1",
        "STAGEHAND_HEADLESS": "false"
      }
    }
  }
}
EOF

    print_success "Configuration templates created in $config_dir/"
    return 0
}

# Main setup function
main() {
    local command="${1:-help}"

    print_header "Advanced MCP Integrations Setup"
    echo

    check_prerequisites
    echo

    if [[ $# -eq 0 ]]; then
        print_info "Available MCP integrations:"
        for mcp in $MCP_LIST; do
            echo "  - $mcp"
        done
        echo
        print_info "Usage: $0 [integration_name|all]"
        print_info "Example: $0 chrome-devtools"
        print_info "Example: $0 all"
        exit 0
    fi
    
    create_config_templates
    echo
    
    if [[ "$command" == "all" ]]; then
        print_header "Installing All MCP Integrations"
        for mcp in $MCP_LIST; do
            install_mcp "$mcp"
            echo
        done
    elif [[ "$MCP_LIST" == *"$command"* ]]; then
        install_mcp "$command"
    else
        print_error "Unknown MCP integration: $command"
        print_info "Available integrations: $MCP_LIST"
        exit 1
    fi
    
    echo
    print_success "MCP integrations setup completed!"
    print_info "Next steps:"
    print_info "1. Configure API keys in your environment"
    print_info "2. Review configuration templates in configs/mcp-templates/"
    print_info "3. Test integrations with your AI assistant"
    print_info "4. Check .agent/MCP-INTEGRATIONS.md for usage examples"
    return 0
}

main "$@"
