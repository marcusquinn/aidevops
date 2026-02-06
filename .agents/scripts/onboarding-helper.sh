#!/bin/bash
# shellcheck disable=SC2034,SC2155

# Onboarding Helper - Interactive setup and service status for aidevops
#
# This script provides:
# 1. Service status detection (what's configured vs needs setup)
# 2. Personalized recommendations based on user's work type
# 3. Setup guidance with links and commands
#
# Usage: ./onboarding-helper.sh [command]
# Commands:
#   status      - Show all services and their configuration status
#   recommend   - Get personalized service recommendations
#   guide       - Show setup guide for a specific service
#   json        - Output status as JSON
#   help        - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0

set -euo pipefail

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly PURPLE='\033[0;35m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# Credential file locations
readonly CREDENTIALS_FILE="$HOME/.config/aidevops/credentials.sh"
readonly CODERABBIT_KEY_FILE="$HOME/.config/coderabbit/api_key"

# Source credentials.sh if it exists
if [[ -f "$CREDENTIALS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CREDENTIALS_FILE"
fi

# Check if an environment variable is set and not a placeholder
is_configured() {
    local var_name="$1"
    local value="${!var_name:-}"
    
    if [[ -z "$value" ]]; then
        return 1
    fi
    
    # Check for placeholder patterns
    local lower_value
    lower_value=$(echo "$value" | tr '[:upper:]' '[:lower:]')
    
    case "$lower_value" in
        *your*|*replace*|*changeme*|*example*|*placeholder*|xxx*|none|null)
            return 1 ;;
        *)
            return 0 ;;
    esac
}

# Check if a CLI tool is authenticated
is_cli_authenticated() {
    local cli="$1"
    
    case "$cli" in
        gh)
            gh auth status &>/dev/null && return 0 || return 1
            ;;
        glab)
            glab auth status &>/dev/null && return 0 || return 1
            ;;
        tea)
            tea login list 2>/dev/null | grep -q "Name:" && return 0 || return 1
            ;;
        auggie)
            auggie token print &>/dev/null && return 0 || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Check if a tool is installed
is_installed() {
    local tool="$1"
    command -v "$tool" &>/dev/null
}

# Print service status
print_service() {
    local name="$1"
    local status="$2"
    local details="${3:-}"
    
    local icon status_color
    case "$status" in
        "ready")
            icon="✓"
            status_color="${GREEN}"
            ;;
        "partial")
            icon="◐"
            status_color="${YELLOW}"
            ;;
        "needs-setup")
            icon="○"
            status_color="${RED}"
            ;;
        "optional")
            icon="·"
            status_color="${DIM}"
            ;;
        *)
            icon="?"
            status_color="${NC}"
            ;;
    esac
    
    if [[ -n "$details" ]]; then
        echo -e "  ${status_color}${icon}${NC} ${name} ${DIM}(${details})${NC}"
    else
        echo -e "  ${status_color}${icon}${NC} ${name}"
    fi
    return 0
}

# Check AI providers
check_ai_providers() {
    echo -e "${BLUE}AI Providers${NC}"
    
    if is_configured "OPENAI_API_KEY"; then
        print_service "OpenAI" "ready" "API key configured"
    else
        print_service "OpenAI" "needs-setup" "OPENAI_API_KEY not set"
    fi
    
    if is_configured "ANTHROPIC_API_KEY"; then
        print_service "Anthropic" "ready" "API key configured"
    else
        print_service "Anthropic" "needs-setup" "ANTHROPIC_API_KEY not set"
    fi
    
    echo ""
    return 0
}

# Check Git platforms
check_git_platforms() {
    echo -e "${BLUE}Git Platforms${NC}"
    
    if is_installed "gh"; then
        if is_cli_authenticated "gh"; then
            print_service "GitHub CLI" "ready" "authenticated"
        else
            print_service "GitHub CLI" "partial" "installed, needs auth"
        fi
    else
        print_service "GitHub CLI" "needs-setup" "not installed"
    fi
    
    if is_installed "glab"; then
        if is_cli_authenticated "glab"; then
            print_service "GitLab CLI" "ready" "authenticated"
        else
            print_service "GitLab CLI" "partial" "installed, needs auth"
        fi
    else
        print_service "GitLab CLI" "optional" "not installed"
    fi
    
    if is_installed "tea"; then
        if is_cli_authenticated "tea"; then
            print_service "Gitea CLI" "ready" "authenticated"
        else
            print_service "Gitea CLI" "partial" "installed, needs auth"
        fi
    else
        print_service "Gitea CLI" "optional" "not installed"
    fi
    
    echo ""
    return 0
}

# Check hosting providers
check_hosting() {
    echo -e "${BLUE}Hosting Providers${NC}"
    
    # Hetzner - check for any HCLOUD_TOKEN_* variable
    local hetzner_configured=false
    for var in $(env | grep -o '^HCLOUD_TOKEN_[A-Z_]*' 2>/dev/null || true); do
        if is_configured "$var"; then
            hetzner_configured=true
            break
        fi
    done
    if [[ "$hetzner_configured" == "true" ]]; then
        print_service "Hetzner Cloud" "ready" "API token configured"
    else
        print_service "Hetzner Cloud" "needs-setup" "HCLOUD_TOKEN_* not set"
    fi
    
    if is_configured "CLOUDFLARE_API_TOKEN"; then
        print_service "Cloudflare" "ready" "API token configured"
    else
        print_service "Cloudflare" "needs-setup" "CLOUDFLARE_API_TOKEN not set"
    fi
    
    if is_configured "COOLIFY_API_TOKEN"; then
        print_service "Coolify" "ready" "API token configured"
    else
        print_service "Coolify" "optional" "COOLIFY_API_TOKEN not set"
    fi
    
    if is_configured "VERCEL_TOKEN"; then
        print_service "Vercel" "ready" "token configured"
    else
        print_service "Vercel" "optional" "VERCEL_TOKEN not set"
    fi
    
    echo ""
    return 0
}

# Check code quality services
check_code_quality() {
    echo -e "${BLUE}Code Quality${NC}"
    
    if is_configured "SONAR_TOKEN"; then
        print_service "SonarCloud" "ready" "token configured"
    else
        print_service "SonarCloud" "needs-setup" "SONAR_TOKEN not set"
    fi
    
    if is_configured "CODACY_PROJECT_TOKEN"; then
        print_service "Codacy" "ready" "token configured"
    else
        print_service "Codacy" "optional" "CODACY_PROJECT_TOKEN not set"
    fi
    
    if [[ -f "$CODERABBIT_KEY_FILE" ]]; then
        print_service "CodeRabbit" "ready" "API key file exists"
    elif is_configured "CODERABBIT_API_KEY"; then
        print_service "CodeRabbit" "ready" "API key configured"
    else
        print_service "CodeRabbit" "optional" "not configured"
    fi
    
    if is_configured "SNYK_TOKEN"; then
        print_service "Snyk" "ready" "token configured"
    else
        print_service "Snyk" "optional" "SNYK_TOKEN not set"
    fi
    
    echo ""
    return 0
}

# Check SEO services
check_seo() {
    echo -e "${BLUE}SEO & Research${NC}"
    
    if is_configured "DATAFORSEO_USERNAME" && is_configured "DATAFORSEO_PASSWORD"; then
        print_service "DataForSEO" "ready" "credentials configured"
    else
        print_service "DataForSEO" "needs-setup" "credentials not set"
    fi
    
    if is_configured "SERPER_API_KEY"; then
        print_service "Serper" "ready" "API key configured"
    else
        print_service "Serper" "optional" "SERPER_API_KEY not set"
    fi
    
    if is_configured "OUTSCRAPER_API_KEY"; then
        print_service "Outscraper" "ready" "API key configured"
    else
        print_service "Outscraper" "optional" "OUTSCRAPER_API_KEY not set"
    fi
    
    echo ""
    return 0
}

# Check context tools
check_context_tools() {
    echo -e "${BLUE}Context & Semantic Search${NC}"
    
    if is_installed "auggie"; then
        if is_cli_authenticated "auggie"; then
            print_service "Augment Context Engine" "ready" "authenticated"
        else
            print_service "Augment Context Engine" "partial" "installed, needs login"
        fi
    else
        print_service "Augment Context Engine" "needs-setup" "auggie not installed"
    fi
    
    if is_installed "osgrep"; then
        print_service "osgrep" "ready" "installed (local)"
    else
        print_service "osgrep" "optional" "not installed"
    fi
    
    # Context7 is MCP-only, no auth needed
    print_service "Context7" "ready" "MCP (no auth needed)"
    
    # sqlite3 is required for memory system
    if is_installed "sqlite3"; then
        print_service "sqlite3" "ready" "memory system ready"
    else
        print_service "sqlite3" "needs-setup" "required for memory system"
    fi
    
    echo ""
    return 0
}

# Check browser automation
check_browser() {
    echo -e "${BLUE}Browser Automation${NC}"
    
    if is_installed "npx" && npx --no-install playwright --version &>/dev/null 2>&1; then
        print_service "Playwright" "ready" "installed"
    else
        print_service "Playwright" "optional" "not installed"
    fi
    
    # Stagehand needs OpenAI or Anthropic key
    if is_configured "OPENAI_API_KEY" || is_configured "ANTHROPIC_API_KEY"; then
        print_service "Stagehand" "ready" "AI key available"
    else
        print_service "Stagehand" "needs-setup" "needs AI API key"
    fi
    
    print_service "Chrome DevTools" "ready" "MCP (no auth needed)"
    print_service "Playwriter" "optional" "browser extension"
    
    echo ""
    return 0
}

# Check AWS services
check_aws() {
    echo -e "${BLUE}AWS Services${NC}"
    
    if is_configured "AWS_ACCESS_KEY_ID" && is_configured "AWS_SECRET_ACCESS_KEY"; then
        print_service "AWS" "ready" "credentials configured"
        
        if is_configured "AWS_DEFAULT_REGION"; then
            print_service "  Region" "ready" "${AWS_DEFAULT_REGION:-}"
        else
            print_service "  Region" "partial" "AWS_DEFAULT_REGION not set"
        fi
    else
        print_service "AWS" "optional" "credentials not set"
    fi
    
    echo ""
    return 0
}

# Check WordPress tools
check_wordpress() {
    echo -e "${BLUE}WordPress${NC}"
    
    if is_installed "wp"; then
        print_service "WP-CLI" "ready" "installed"
    else
        print_service "WP-CLI" "optional" "not installed"
    fi
    
    # Check for LocalWP
    if [[ -d "/Applications/Local.app" ]] || [[ -d "$HOME/Applications/Local.app" ]]; then
        print_service "LocalWP" "ready" "installed"
    else
        print_service "LocalWP" "optional" "not installed"
    fi
    
    # MainWP config check (XDG-compliant location)
    if [[ -f "$HOME/.config/aidevops/mainwp-config.json" ]]; then
        print_service "MainWP" "ready" "config exists"
    else
        print_service "MainWP" "optional" "not configured"
    fi
    
    echo ""
    return 0
}

# Show full status
show_status() {
    echo ""
    echo -e "${BLUE}aidevops Service Status${NC}"
    echo "========================"
    echo ""
    echo -e "${DIM}Legend: ${GREEN}✓${NC}${DIM} ready  ${YELLOW}◐${NC}${DIM} partial  ${RED}○${NC}${DIM} needs setup  ${DIM}·${NC}${DIM} optional${NC}"
    echo ""
    
    check_ai_providers
    check_git_platforms
    check_hosting
    check_code_quality
    check_seo
    check_context_tools
    check_browser
    check_aws
    check_wordpress
    
    echo -e "${DIM}---${NC}"
    echo -e "Run ${BLUE}~/.aidevops/agents/scripts/list-keys-helper.sh${NC} for detailed key status"
    echo -e "Run ${BLUE}/onboarding${NC} in OpenCode for interactive setup guidance"
    echo ""
    return 0
}

# Show recommendations based on work type
show_recommendations() {
    local work_type="${1:-}"
    
    echo ""
    echo -e "${PURPLE}Recommended Services${NC}"
    echo "===================="
    echo ""
    
    case "$work_type" in
        web|webdev|"web development"|1)
            echo -e "${BLUE}For Web Development:${NC}"
            echo ""
            echo "Essential:"
            echo "  • GitHub CLI (gh) - Repository management"
            echo "  • OpenAI API - AI-powered coding assistance"
            echo "  • Augment Context Engine - Semantic codebase search"
            echo "  • Playwright - Browser testing"
            echo ""
            echo "Recommended:"
            echo "  • Vercel or Coolify - Deployment"
            echo "  • Cloudflare - DNS and CDN"
            echo "  • SonarCloud - Code quality"
            ;;
        devops|infrastructure|2)
            echo -e "${BLUE}For DevOps & Infrastructure:${NC}"
            echo ""
            echo "Essential:"
            echo "  • GitHub/GitLab CLI - Repository management"
            echo "  • Hetzner Cloud - VPS servers"
            echo "  • Cloudflare - DNS management"
            echo "  • Coolify - Self-hosted PaaS"
            echo ""
            echo "Recommended:"
            echo "  • SonarCloud + Codacy - Code quality"
            echo "  • Snyk - Security scanning"
            echo "  • AWS - Cloud services"
            ;;
        seo|marketing|"content marketing"|3)
            echo -e "${BLUE}For SEO & Content Marketing:${NC}"
            echo ""
            echo "Essential:"
            echo "  • DataForSEO - Keyword research, SERP analysis"
            echo "  • Serper - Google Search API"
            echo "  • Google Search Console - Search performance"
            echo ""
            echo "Recommended:"
            echo "  • Outscraper - Business data extraction"
            echo "  • Stagehand - Browser automation for research"
            ;;
        wordpress|clients|"multiple sites"|4)
            echo -e "${BLUE}For WordPress & Client Management:${NC}"
            echo ""
            echo "Essential:"
            echo "  • LocalWP - Local WordPress development"
            echo "  • MainWP - Fleet management"
            echo "  • GitHub CLI - Version control"
            echo ""
            echo "Recommended:"
            echo "  • Hostinger or Hetzner - Hosting"
            echo "  • Cloudflare - DNS and security"
            echo "  • DataForSEO - SEO analysis"
            ;;
        *)
            echo -e "${BLUE}General Recommendations:${NC}"
            echo ""
            echo "Start with these core services:"
            echo "  1. GitHub CLI (gh auth login)"
            echo "  2. OpenAI or Anthropic API key"
            echo "  3. Augment Context Engine (semantic search)"
            echo ""
            echo "Then add based on your needs:"
            echo "  • Hosting: Hetzner, Cloudflare, Coolify, Vercel"
            echo "  • Quality: SonarCloud, Codacy, CodeRabbit"
            echo "  • SEO: DataForSEO, Serper"
            echo "  • WordPress: LocalWP, MainWP"
            ;;
    esac
    
    echo ""
    return 0
}

# Show setup guide for a specific service
show_guide() {
    local service="${1:-}"
    
    echo ""
    
    case "$service" in
        github|gh)
            echo -e "${BLUE}GitHub CLI Setup${NC}"
            echo ""
            echo "1. Install: brew install gh"
            echo "2. Authenticate: gh auth login"
            echo "3. Verify: gh auth status"
            ;;
        openai)
            echo -e "${BLUE}OpenAI API Setup${NC}"
            echo ""
            echo "1. Get API key: https://platform.openai.com/api-keys"
            echo "2. Store key:"
            echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set OPENAI_API_KEY \"sk-...\""
            echo "3. Restart terminal or: source ~/.config/aidevops/credentials.sh"
            ;;
        anthropic)
            echo -e "${BLUE}Anthropic API Setup${NC}"
            echo ""
            echo "1. Get API key: https://console.anthropic.com/settings/keys"
            echo "2. Store key:"
            echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set ANTHROPIC_API_KEY \"sk-ant-...\""
            echo "3. Restart terminal or: source ~/.config/aidevops/credentials.sh"
            ;;
        hetzner)
            echo -e "${BLUE}Hetzner Cloud Setup${NC}"
            echo ""
            echo "1. Create account: https://www.hetzner.com/cloud"
            echo "2. Go to: Security -> API Tokens"
            echo "3. Generate token with Read & Write permissions"
            echo "4. Store token:"
            echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set HCLOUD_TOKEN_MAIN \"your-token\""
            ;;
        cloudflare)
            echo -e "${BLUE}Cloudflare Setup${NC}"
            echo ""
            echo "1. Create account: https://cloudflare.com"
            echo "2. Go to: My Profile -> API Tokens"
            echo "3. Create token with Zone:Read, DNS:Edit permissions"
            echo "4. Store token:"
            echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set CLOUDFLARE_API_TOKEN \"your-token\""
            ;;
        dataforseo)
            echo -e "${BLUE}DataForSEO Setup${NC}"
            echo ""
            echo "1. Create account: https://app.dataforseo.com"
            echo "2. Go to: API Access"
            echo "3. Store credentials:"
            echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_USERNAME \"your-email\""
            echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_PASSWORD \"your-password\""
            ;;
        augment|auggie)
            echo -e "${BLUE}Augment Context Engine Setup${NC}"
            echo ""
            echo "1. Install: npm install -g @augmentcode/auggie@prerelease"
            echo "2. Login: auggie login (opens browser)"
            echo "3. Verify: auggie token print"
            ;;
        sonarcloud|sonar)
            echo -e "${BLUE}SonarCloud Setup${NC}"
            echo ""
            echo "1. Create account: https://sonarcloud.io"
            echo "2. Go to: My Account -> Security"
            echo "3. Generate token"
            echo "4. Store token:"
            echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set SONAR_TOKEN \"your-token\""
            ;;
        *)
            echo "Available guides: github, openai, anthropic, hetzner, cloudflare,"
            echo "                  dataforseo, augment, sonarcloud"
            echo ""
            echo "Usage: $0 guide <service>"
            ;;
    esac
    
    echo ""
    return 0
}

# Show help
show_help() {
    echo "Onboarding Helper - Interactive setup and service status for aidevops"
    echo ""
    echo "Usage: $0 [command] [args]"
    echo ""
    echo "Commands:"
    echo "  status              - Show all services and their configuration status (default)"
    echo "  recommend [type]    - Get personalized recommendations"
    echo "                        Types: web, devops, seo, wordpress, or leave blank"
    echo "  guide <service>     - Show setup guide for a specific service"
    echo "                        Services: github, openai, anthropic, hetzner, cloudflare,"
    echo "                                  dataforseo, augment, sonarcloud"
    echo "  json                - Output status as JSON for programmatic use"
    echo "  help                - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 recommend devops"
    echo "  $0 guide openai"
    echo ""
    echo "Use /onboarding in OpenCode for the full interactive experience."
    return 0
}

# Output status as JSON
output_json() {
    local json="{"
    
    # AI Providers
    json+='"ai_providers":{'
    json+='"openai":{"configured":'
    is_configured "OPENAI_API_KEY" && json+='true' || json+='false'
    json+='},"anthropic":{"configured":'
    is_configured "ANTHROPIC_API_KEY" && json+='true' || json+='false'
    json+='}},'
    
    # Git Platforms
    json+='"git_platforms":{'
    json+='"github":{"installed":'
    is_installed "gh" && json+='true' || json+='false'
    json+=',"authenticated":'
    is_cli_authenticated "gh" && json+='true' || json+='false'
    json+='},"gitlab":{"installed":'
    is_installed "glab" && json+='true' || json+='false'
    json+=',"authenticated":'
    is_cli_authenticated "glab" && json+='true' || json+='false'
    json+='}},'
    
    # Hosting
    json+='"hosting":{'
    json+='"cloudflare":{"configured":'
    is_configured "CLOUDFLARE_API_TOKEN" && json+='true' || json+='false'
    json+='},"coolify":{"configured":'
    is_configured "COOLIFY_API_TOKEN" && json+='true' || json+='false'
    json+='},"vercel":{"configured":'
    is_configured "VERCEL_TOKEN" && json+='true' || json+='false'
    json+='}},'
    
    # Code Quality
    json+='"code_quality":{'
    json+='"sonarcloud":{"configured":'
    is_configured "SONAR_TOKEN" && json+='true' || json+='false'
    json+='},"codacy":{"configured":'
    is_configured "CODACY_PROJECT_TOKEN" && json+='true' || json+='false'
    json+='},"coderabbit":{"configured":'
    [[ -f "$CODERABBIT_KEY_FILE" ]] || is_configured "CODERABBIT_API_KEY" && json+='true' || json+='false'
    json+='}},'
    
    # SEO
    json+='"seo":{'
    json+='"dataforseo":{"configured":'
    is_configured "DATAFORSEO_USERNAME" && is_configured "DATAFORSEO_PASSWORD" && json+='true' || json+='false'
    json+='},"serper":{"configured":'
    is_configured "SERPER_API_KEY" && json+='true' || json+='false'
    json+='}},'
    
    # Context Tools
    json+='"context":{'
    json+='"augment":{"installed":'
    is_installed "auggie" && json+='true' || json+='false'
    json+=',"authenticated":'
    is_cli_authenticated "auggie" && json+='true' || json+='false'
    json+='},"osgrep":{"installed":'
    is_installed "osgrep" && json+='true' || json+='false'
    json+='},"sqlite3":{"installed":'
    is_installed "sqlite3" && json+='true' || json+='false'
    json+='}}'
    
    json+='}'
    
    echo "$json" | jq .
    return 0
}

# Main
main() {
    local command="${1:-status}"
    local arg="${2:-}"
    
    case "$command" in
        status)
            show_status
            ;;
        recommend|recommendations)
            show_recommendations "$arg"
            ;;
        guide|setup)
            show_guide "$arg"
            ;;
        json)
            output_json
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo "Unknown command: $command"
            echo "Use '$0 help' for usage information"
            return 1
            ;;
    esac
    
    return 0
}

main "$@"
