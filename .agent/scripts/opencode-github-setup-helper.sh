#!/bin/bash
# shellcheck disable=SC2034
#
# OpenCode GitHub/GitLab Setup Helper
#
# DESCRIPTION:
#   Detects git remote type (GitHub, GitLab, Gitea, Bitbucket) and checks
#   OpenCode integration status. Provides setup instructions and can create
#   GitHub Actions workflow files for OpenCode automation.
#
# USAGE:
#   opencode-github-setup-helper.sh <command>
#
# COMMANDS:
#   check           - Check OpenCode integration status for current repo
#   setup           - Show setup instructions for detected platform
#   create-workflow - Create GitHub Actions workflow file (GitHub only)
#   help            - Show help message
#
# EXAMPLES:
#   opencode-github-setup-helper.sh check
#   opencode-github-setup-helper.sh setup
#   opencode-github-setup-helper.sh create-workflow
#
# DEPENDENCIES:
#   - git (required)
#   - gh (GitHub CLI, optional but recommended)
#
# AUTHOR: AI DevOps Framework
# VERSION: 1.0.0
# LICENSE: MIT

set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION & CONSTANTS
# ------------------------------------------------------------------------------

readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

readonly GITHUB_APP_URL="https://github.com/apps/opencode-agent"
readonly OPENCODE_GITHUB_DOCS="https://opencode.ai/docs/github/"
readonly OPENCODE_GITLAB_DOCS="https://opencode.ai/docs/gitlab/"

# ------------------------------------------------------------------------------
# UTILITY FUNCTIONS
# ------------------------------------------------------------------------------

# Print an informational message in blue
# Arguments:
#   $1 - Message to print
# Returns: 0
print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    return 0
}

# Print a success message in green
# Arguments:
#   $1 - Message to print
# Returns: 0
print_success() {
    local msg="$1"
    echo -e "${GREEN}[OK]${NC} $msg"
    return 0
}

# Print a warning message in yellow
# Arguments:
#   $1 - Message to print
# Returns: 0
print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARN]${NC} $msg"
    return 0
}

# Print an error/missing message in red
# Arguments:
#   $1 - Message to print
# Returns: 0
print_error() {
    local msg="$1"
    echo -e "${RED}[MISSING]${NC} $msg"
    return 0
}

# ------------------------------------------------------------------------------
# DETECTION FUNCTIONS
# ------------------------------------------------------------------------------

# Detect the type of git remote (github, gitlab, gitea, bitbucket, or unknown)
# Arguments: None
# Outputs: Writes remote type to stdout (github|gitlab|gitea|bitbucket|unknown|none)
# Returns: 0
detect_remote_type() {
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null) || {
        echo "none"
        return 0
    }
    
    if [[ "$remote_url" == *"github.com"* ]]; then
        echo "github"
    elif [[ "$remote_url" == *"gitlab"* ]]; then
        echo "gitlab"
    elif [[ "$remote_url" == *"gitea"* ]] || [[ "$remote_url" == *"forgejo"* ]]; then
        echo "gitea"
    elif [[ "$remote_url" == *"bitbucket"* ]]; then
        echo "bitbucket"
    else
        echo "unknown"
    fi
    return 0
}

# Get the origin remote URL
# Arguments: None
# Outputs: Writes remote URL to stdout (empty string if not found)
# Returns: 0
get_remote_url() {
    git remote get-url origin 2>/dev/null || echo ""
    return 0
}

# Extract owner/repo from git remote URL
# Handles both SSH and HTTPS URL formats:
#   - git@github.com:owner/repo.git
#   - https://github.com/owner/repo.git
#   - https://github.com/owner/repo
# Arguments: None
# Outputs: Writes "owner/repo" to stdout (empty string if not found)
# Returns: 0
get_repo_owner_name() {
    local remote_url
    remote_url=$(get_remote_url)
    
    if [[ -z "$remote_url" ]]; then
        echo ""
        return 0
    fi
    
    # Extract owner/repo from various URL formats
    local repo_path
    repo_path=$(echo "$remote_url" | sed -E 's#.*[:/]([^/]+/[^/]+)(\.git)?$#\1#')
    echo "$repo_path"
    return 0
}

# ------------------------------------------------------------------------------
# GITHUB CHECKS
# ------------------------------------------------------------------------------

# Check if OpenCode GitHub App is installed on the repository
# Requires GitHub CLI (gh) to be installed and authenticated
# Arguments:
#   $1 - Repository path in "owner/repo" format
# Returns: 0 if app is installed, 1 otherwise
check_github_app() {
    local repo_path="$1"
    
    if ! command -v gh &> /dev/null; then
        print_warning "GitHub CLI (gh) not installed - cannot check app status"
        return 1
    fi
    
    if ! gh auth status &> /dev/null; then
        print_warning "GitHub CLI not authenticated - run 'gh auth login'"
        return 1
    fi
    
    # Check if OpenCode app is installed on the repo
    local installations
    installations=$(gh api "repos/$repo_path/installation" 2>/dev/null) || {
        return 1
    }
    
    if [[ -n "$installations" ]]; then
        return 0
    fi
    return 1
}

# Check if OpenCode GitHub Actions workflow file exists
# Arguments: None
# Returns: 0 if workflow exists, 1 otherwise
check_github_workflow() {
    if [[ -f ".github/workflows/opencode.yml" ]]; then
        return 0
    fi
    return 1
}

# Check if AI provider API key is configured in repository secrets
# Looks for ANTHROPIC_API_KEY, OPENAI_API_KEY, or GOOGLE_API_KEY
# Arguments:
#   $1 - Repository path in "owner/repo" format
# Returns: 0 if at least one AI key is configured, 1 otherwise
check_github_secrets() {
    local repo_path="$1"
    
    if ! command -v gh &> /dev/null; then
        return 1
    fi
    
    # Check if any AI provider API key secret exists
    local secrets
    secrets=$(gh secret list 2>/dev/null) || return 1
    
    if echo "$secrets" | grep -q "ANTHROPIC_API_KEY\|OPENAI_API_KEY\|GOOGLE_API_KEY"; then
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# GITLAB CHECKS
# ------------------------------------------------------------------------------

# Check if GitLab CI is configured with OpenCode
# Looks for .gitlab-ci.yml containing "opencode" reference
# Arguments: None
# Returns: 0 if OpenCode is configured in GitLab CI, 1 otherwise
check_gitlab_ci() {
    if [[ -f ".gitlab-ci.yml" ]]; then
        # Check if it contains opencode configuration
        if grep -q "opencode" ".gitlab-ci.yml" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# ------------------------------------------------------------------------------
# MAIN COMMANDS
# ------------------------------------------------------------------------------

# Command: Check OpenCode integration status for the current repository
# Detects platform type and runs appropriate checks
# Arguments: None
# Returns: 0 on success, 1 if no git remote found
cmd_check() {
    print_info "Checking OpenCode integration status..."
    echo ""
    
    local remote_type
    remote_type=$(detect_remote_type)
    
    local remote_url
    remote_url=$(get_remote_url)
    
    local repo_path
    repo_path=$(get_repo_owner_name)
    
    if [[ "$remote_type" == "none" ]]; then
        print_error "No git remote found"
        echo "  This directory is not a git repository or has no origin remote."
        return 1
    fi
    
    echo "Repository: $repo_path"
    echo "Remote URL: $remote_url"
    echo "Platform:   $remote_type"
    echo ""
    
    case "$remote_type" in
        "github")
            check_github_status "$repo_path"
            ;;
        "gitlab")
            check_gitlab_status
            ;;
        "gitea")
            print_warning "Gitea/Forgejo detected"
            echo "  OpenCode integration is not yet available for Gitea."
            echo "  Use the standard git CLI workflow instead."
            ;;
        "bitbucket")
            print_warning "Bitbucket detected"
            echo "  OpenCode integration is not yet available for Bitbucket."
            ;;
        *)
            print_warning "Unknown git platform"
            echo "  Remote URL: $remote_url"
            ;;
    esac
    return 0
}

# Display GitHub-specific integration status
# Shows app installation, workflow, and secrets status
# Arguments:
#   $1 - Repository path in "owner/repo" format
# Returns: 0
check_github_status() {
    local repo_path="$1"
    
    echo "=== GitHub Integration Status ==="
    echo ""
    
    # Check GitHub App
    if check_github_app "$repo_path"; then
        print_success "GitHub App installed"
    else
        print_error "GitHub App not installed"
        echo "  Install at: $GITHUB_APP_URL"
        echo "  Or run: opencode github install"
    fi
    
    # Check workflow file
    if check_github_workflow; then
        print_success "Workflow file exists (.github/workflows/opencode.yml)"
    else
        print_error "Workflow file missing"
        echo "  Create: .github/workflows/opencode.yml"
        echo "  Or run: opencode github install"
    fi
    
    # Check secrets
    if check_github_secrets "$repo_path"; then
        print_success "AI provider API key configured"
    else
        print_error "No AI provider API key found in secrets"
        echo "  Add ANTHROPIC_API_KEY to repository secrets"
        echo "  Settings → Secrets and variables → Actions"
    fi
    
    echo ""
    echo "=== Usage ==="
    echo "Once configured, use in any issue or PR comment:"
    echo "  /oc explain this issue"
    echo "  /oc fix this bug"
    echo "  /opencode review this PR"
    echo ""
    echo "Docs: $OPENCODE_GITHUB_DOCS"
    return 0
}

# Display GitLab-specific integration status
# Shows CI/CD configuration status and required variables
# Arguments: None
# Returns: 0
check_gitlab_status() {
    echo "=== GitLab Integration Status ==="
    echo ""
    
    # Check CI/CD file
    if check_gitlab_ci; then
        print_success "GitLab CI configured with OpenCode"
    else
        print_error "GitLab CI not configured for OpenCode"
        echo "  Add OpenCode job to .gitlab-ci.yml"
    fi
    
    echo ""
    echo "=== Required CI/CD Variables ==="
    echo "  ANTHROPIC_API_KEY     - AI provider API key"
    echo "  GITLAB_TOKEN_OPENCODE - GitLab access token"
    echo "  GITLAB_HOST           - gitlab.com or your instance"
    echo ""
    echo "=== Usage ==="
    echo "Once configured, use in any issue or MR comment:"
    echo "  @opencode explain this issue"
    echo "  @opencode fix this"
    echo "  @opencode review this MR"
    echo ""
    echo "Docs: $OPENCODE_GITLAB_DOCS"
    return 0
}

# Command: Show setup instructions for detected platform
# Provides step-by-step guidance for GitHub or GitLab integration
# Arguments: None
# Returns: 0
cmd_setup() {
    local remote_type
    remote_type=$(detect_remote_type)
    
    case "$remote_type" in
        "github")
            print_info "Setting up OpenCode GitHub integration..."
            echo ""
            echo "Run the automated setup:"
            echo "  opencode github install"
            echo ""
            echo "Or manual setup:"
            echo "  1. Install GitHub App: $GITHUB_APP_URL"
            echo "  2. Create workflow: .github/workflows/opencode.yml"
            echo "  3. Add secret: ANTHROPIC_API_KEY"
            echo ""
            echo "See: ~/.aidevops/agents/tools/git/opencode-github.md"
            ;;
        "gitlab")
            print_info "Setting up OpenCode GitLab integration..."
            echo ""
            echo "Manual setup required:"
            echo "  1. Add CI/CD variables (Settings → CI/CD → Variables)"
            echo "  2. Create/update .gitlab-ci.yml with OpenCode job"
            echo "  3. Configure webhook for comment triggers"
            echo ""
            echo "See: ~/.aidevops/agents/tools/git/opencode-gitlab.md"
            ;;
        *)
            print_error "OpenCode integration not available for: $remote_type"
            ;;
    esac
    return 0
}

# Command: Create GitHub Actions workflow file for OpenCode
# Creates .github/workflows/opencode.yml with proper permissions and triggers
# Arguments: None
# Returns: 0 on success, 1 if not GitHub or workflow exists
cmd_create_workflow() {
    local remote_type
    remote_type=$(detect_remote_type)
    
    if [[ "$remote_type" != "github" ]]; then
        print_error "This command is for GitHub repositories only"
        return 1
    fi
    
    if [[ -f ".github/workflows/opencode.yml" ]]; then
        print_warning "Workflow file already exists: .github/workflows/opencode.yml"
        echo "Delete it first if you want to recreate."
        return 1
    fi
    
    mkdir -p .github/workflows
    
    cat > .github/workflows/opencode.yml << 'EOF'
name: opencode
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

jobs:
  opencode:
    if: |
      contains(github.event.comment.body, '/oc') ||
      contains(github.event.comment.body, '/opencode')
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: write
      pull-requests: write
      issues: write
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 1

      - name: Run OpenCode
        uses: sst/opencode/github@latest
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        with:
          model: anthropic/claude-sonnet-4-20250514
EOF
    
    print_success "Created .github/workflows/opencode.yml"
    echo ""
    echo "Next steps:"
    echo "  1. Install GitHub App: $GITHUB_APP_URL"
    echo "  2. Add ANTHROPIC_API_KEY to repository secrets"
    echo "  3. Commit and push the workflow file"
    return 0
}

# Display help message with usage examples
# Arguments: None
# Returns: 0
show_help() {
    cat << 'EOF'
OpenCode GitHub/GitLab Setup Helper

Usage: opencode-github-setup-helper.sh <command>

Commands:
  check              Check OpenCode integration status for current repo
  setup              Show setup instructions for detected platform
  create-workflow    Create GitHub Actions workflow file (GitHub only)
  help               Show this help message

Examples:
  # Check if OpenCode is configured
  opencode-github-setup-helper.sh check

  # Get setup instructions
  opencode-github-setup-helper.sh setup

  # Create workflow file
  opencode-github-setup-helper.sh create-workflow

For more information:
  GitHub: https://opencode.ai/docs/github/
  GitLab: https://opencode.ai/docs/gitlab/
EOF
    return 0
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

# Main entry point - routes to appropriate command handler
# Arguments:
#   $1 - Command to run (default: check)
# Returns: Exit code from command handler
main() {
    local command="${1:-check}"
    
    case "$command" in
        "check"|"status")
            cmd_check
            ;;
        "setup"|"install")
            cmd_setup
            ;;
        "create-workflow"|"workflow")
            cmd_create_workflow
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo "Use 'opencode-github-setup-helper.sh help' for usage"
            return 1
            ;;
    esac
    return 0
}

main "$@"
