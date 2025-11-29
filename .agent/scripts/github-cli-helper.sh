#!/bin/bash

# GitHub CLI Helper Script
# Comprehensive GitHub management using GitHub CLI (gh)
# Managed by AI DevOps Framework

# Set strict mode
set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION & CONSTANTS
# ------------------------------------------------------------------------------

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="$script_dir"

repo_root="$(dirname "$SCRIPT_DIR")"
readonly REPO_ROOT="$repo_root"
readonly CONFIG_FILE="$REPO_ROOT/configs/github-cli-config.json"

# Colors
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Error Messages
readonly ERROR_CONFIG_MISSING="Configuration file not found at $CONFIG_FILE"
readonly ERROR_GH_NOT_INSTALLED="GitHub CLI (gh) is required but not installed"
readonly ERROR_NOT_LOGGED_IN="GitHub CLI is not authenticated. Run 'gh auth login'"
readonly ERROR_ACCOUNT_MISSING="Account configuration not found"
readonly ERROR_ARGS_MISSING="Missing required arguments"
readonly ERROR_API_FAILED="GitHub API request failed"

readonly ERROR_REPO_NAME_REQUIRED="Repository name is required"
readonly ERROR_ISSUE_TITLE_REQUIRED="Issue title is required"
readonly ERROR_ISSUE_NUMBER_REQUIRED="Issue number is required"
readonly ERROR_PR_TITLE_REQUIRED="Pull request title is required"
readonly ERROR_PR_NUMBER_REQUIRED="Pull request number is required"
readonly ERROR_BRANCH_NAME_REQUIRED="Branch name is required"
readonly ERROR_OWNER_NOT_CONFIGURED="Owner not configured for account"
readonly ERROR_FAILED_TO_READ_CONFIG="Failed to read configuration"

# Success Messages
readonly SUCCESS_REPO_CREATED="Repository created successfully"
readonly SUCCESS_ISSUE_CREATED="Issue created successfully"
readonly SUCCESS_PR_CREATED="Pull request created successfully"
readonly SUCCESS_BRANCH_CREATED="Branch created successfully"
readonly SUCCESS_ISSUE_CLOSED="Issue closed successfully"
readonly SUCCESS_PR_MERGED="Pull request merged successfully"

# Common constants
readonly CONTENT_TYPE_JSON="Content-Type: application/json"
readonly AUTH_HEADER_TOKEN="Authorization: token"

# ------------------------------------------------------------------------------
# UTILITY FUNCTIONS
# ------------------------------------------------------------------------------

print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    return 0
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $msg"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    return 0
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg" >&2
    return 0
}

# ------------------------------------------------------------------------------
# DEPENDENCY CHECKING
# ------------------------------------------------------------------------------

check_dependencies() {
    if ! command -v gh &> /dev/null; then
        print_error "$ERROR_GH_NOT_INSTALLED"
        print_info "Install GitHub CLI:"
        print_info "  macOS: brew install gh"
        print_info "  Ubuntu: sudo apt install gh"
        print_info "  Other: https://cli.github.com/manual/installation"
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        print_error "$ERROR_NOT_LOGGED_IN"
        print_info "Authenticate with: gh auth login"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        print_error "jq is required but not installed"
        print_info "Install: brew install jq (macOS) or sudo apt install jq (Ubuntu)"
        exit 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# CONFIGURATION LOADING
# ------------------------------------------------------------------------------

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "$ERROR_CONFIG_MISSING"
        print_info "Create configuration: cp configs/github-cli-config.json.txt $CONFIG_FILE"
        return 1
    fi
    return 0
}

get_account_config() {
    local account_name="$1"
    
    if [[ -z "$account_name" ]]; then
        print_error "$ERROR_ARGS_MISSING"
        return 1
    fi

    local config
    if ! config=$(jq -r ".accounts.\"$account_name\"" "$CONFIG_FILE" 2>/dev/null); then
        print_error "$ERROR_FAILED_TO_READ_CONFIG"
        return 1
    fi

    if [[ "$config" == "null" ]]; then
        print_error "$ERROR_ACCOUNT_MISSING: $account_name"
        return 1
    fi

    echo "$config"
    return 0
}

# ------------------------------------------------------------------------------
# REPOSITORY MANAGEMENT
# ------------------------------------------------------------------------------

list_repos() {
    local account_name="$1"
    local filter="${2:-}"
    
    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "Owner not configured for account: $account_name"
        return 1
    fi

    print_info "Listing repositories for $owner..."
    
    local query="owner:$owner"
    if [[ -n "$filter" ]]; then
        query="$query $filter"
    fi

    if ! gh repo list "$owner" --limit 50 --search "$query"; then
        print_error "$ERROR_API_FAILED"
        return 1
    fi
    return 0
}

create_repo() {
    local account_name="$1"
    local repo_name="$2"
    local repo_description="${3:-}"
    local visibility="${4:-public}"
    local auto_init="${5:-false}"

    if [[ -z "$repo_name" ]]; then
        print_error "$ERROR_REPO_NAME_REQUIRED"
        print_info "Usage: github-cli-helper.sh create-repo <account> <repo-name> [description] [visibility]"
        return 1
    fi

    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "$ERROR_OWNER_NOT_CONFIGURED: $account_name"
        return 1
    fi

    print_info "Creating repository: $owner/$repo_name"

    local gh_args=("$owner/$repo_name" --description "$repo_description" --visibility "$visibility")
    if [[ "$auto_init" == "true" ]]; then
        gh_args+=(--auto-init)
    fi

    if gh repo create "${gh_args[@]}"; then
        print_success "$SUCCESS_REPO_CREATED: $owner/$repo_name"
        
        # Add to configuration if not exists
        if ! jq -e ".repos.\"$owner/$repo_name\"" "$CONFIG_FILE" &>/dev/null; then
            jq --arg repo "$owner/$repo_name" --arg owner "$owner" --arg name "$repo_name" \
               '.repos[$repo] = {owner: $owner, name: $name, account: $account_name}' \
               "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        fi
    else
        print_error "Failed to create repository"
        return 1
    fi
    return 0
}

delete_repo() {
    local account_name="$1"
    local repo_name="$2"

    if [[ -z "$repo_name" ]]; then
        print_error "$ERROR_ARGS_MISSING"
        return 1
    fi

    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "Owner not configured for account: $account_name"
        return 1
    fi

    print_warning "This will permanently delete repository: $owner/$repo_name"
    print_info "To confirm, type 'DELETE':"
    read -r confirmation

    if [[ "$confirmation" != "DELETE" ]]; then
        print_info "Deletion cancelled"
        return 0
    fi

    print_info "Deleting repository: $owner/$repo_name"
    
    if gh repo delete "$owner/$repo_name" --confirm; then
        print_success "Repository deleted successfully"
        
        # Remove from configuration
        jq --arg repo "$owner/$repo_name" 'del(.repos[$repo])' \
           "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
        print_error "Failed to delete repository"
        return 1
    fi
    return 0
}

get_repo_info() {
    local account_name="$1"
    local repo_name="$2"

    if [[ -z "$repo_name" ]]; then
        print_error "$ERROR_ARGS_MISSING"
        return 1
    fi

    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "Owner not configured for account: $account_name"
        return 1
    fi

    print_info "Repository information for $owner/$repo_name:"
    gh repo view "$owner/$repo_name"
    return 0
}

# ------------------------------------------------------------------------------
# ISSUE MANAGEMENT
# ------------------------------------------------------------------------------

list_issues() {
    local account_name="$1"
    local repo_name="$2"
    local state="${3:-open}"

    if [[ -z "$repo_name" ]]; then
        print_error "$ERROR_ARGS_MISSING"
        return 1
    fi

    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "Owner not configured for account: $account_name"
        return 1
    fi

    print_info "Listing issues for $owner/$repo_name (state: $state)"
    gh issue list --repo "$owner/$repo_name" --limit 50 --state "$state"
    return 0
}

create_issue() {
    local account_name="$1"
    local repo_name="$2"
    local title="$3"
    local body="${4:-}"

    if [[ -z "$title" ]]; then
        print_error "$ERROR_ISSUE_TITLE_REQUIRED"
        return 1
    fi

    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "$ERROR_OWNER_NOT_CONFIGURED: $account_name"
        return 1
    fi

    print_info "Creating issue in $owner/$repo_name"

    if gh issue create --repo "$owner/$repo_name" --title "$title" --body "$body"; then
        print_success "$SUCCESS_ISSUE_CREATED"
    else
        print_error "Failed to create issue"
        return 1
    fi
    return 0
}

close_issue() {
    local account_name="$1"
    local repo_name="$2"
    local issue_number="$3"

    if [[ -z "$issue_number" ]]; then
        print_error "$ERROR_ISSUE_NUMBER_REQUIRED"
        return 1
    fi

    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "$ERROR_OWNER_NOT_CONFIGURED: $account_name"
        return 1
    fi

    print_info "Closing issue #$issue_number in $owner/$repo_name"

    if gh issue close --repo "$owner/$repo_name" "$issue_number"; then
        print_success "$SUCCESS_ISSUE_CLOSED"
    else
        print_error "Failed to close issue"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# PULL REQUEST MANAGEMENT
# ------------------------------------------------------------------------------

list_prs() {
    local account_name="$1"
    local repo_name="$2"
    local state="${3:-open}"

    if [[ -z "$repo_name" ]]; then
        print_error "$ERROR_ARGS_MISSING"
        return 1
    fi

    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "Owner not configured for account: $account_name"
        return 1
    fi

    print_info "Listing pull requests for $owner/$repo_name (state: $state)"
    gh pr list --repo "$owner/$repo_name" --limit 50 --state "$state"
    return 0
}

create_pr() {
    local account_name="$1"
    local repo_name="$2"
    local title="$3"
    local base_branch="${4:-main}"
    local head_branch="${5:-}"
    local body="${6:-}"

    if [[ -z "$title" ]]; then
        print_error "$ERROR_PR_TITLE_REQUIRED"
        return 1
    fi

    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "$ERROR_OWNER_NOT_CONFIGURED: $account_name"
        return 1
    fi

    print_info "Creating pull request in $owner/$repo_name"

    local gh_args=("--repo" "$owner/$repo_name" "--title" "$title" "--base" "$base_branch")
    if [[ -n "$head_branch" ]]; then
        gh_args+=("--head" "$head_branch")
    fi
    if [[ -n "$body" ]]; then
        gh_args+=("--body" "$body")
    fi

    if gh pr create "${gh_args[@]}"; then
        print_success "$SUCCESS_PR_CREATED"
    else
        print_error "Failed to create pull request"
        return 1
    fi
    return 0
}

merge_pr() {
    local account_name="$1"
    local repo_name="$2"
    local pr_number="$3"
    local merge_method="${4:-merge}"

    if [[ -z "$pr_number" ]]; then
        print_error "$ERROR_PR_NUMBER_REQUIRED"
        return 1
    fi

    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "$ERROR_OWNER_NOT_CONFIGURED: $account_name"
        return 1
    fi

    print_info "Merging pull request #$pr_number in $owner/$repo_name"

    if gh pr merge --repo "$owner/$repo_name" "$pr_number" --"$merge_method"; then
        print_success "$SUCCESS_PR_MERGED"
    else
        print_error "Failed to merge pull request"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# BRANCH MANAGEMENT
# ------------------------------------------------------------------------------

list_branches() {
    local account_name="$1"
    local repo_name="$2"

    if [[ -z "$repo_name" ]]; then
        print_error "$ERROR_ARGS_MISSING"
        return 1
    fi

    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "Owner not configured for account: $account_name"
        return 1
    fi

    print_info "Listing branches for $owner/$repo_name"
    gh repo list "$owner" --limit 1 "--json" "nameWithOwner" | jq -r '.[0].nameWithOwner' | \
        xargs -I {} gh api "repos/{}/branches" --jq '.[] | .name'
    return 0
}

create_branch() {
    local account_name="$1"
    local repo_name="$2"
    local branch_name="$3"
    local source_branch="${4:-main}"

    if [[ -z "$branch_name" ]]; then
        print_error "$ERROR_BRANCH_NAME_REQUIRED"
        return 1
    fi

    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "$ERROR_OWNER_NOT_CONFIGURED: $account_name"
        return 1
    fi

    print_info "Creating branch '$branch_name' in $owner/$repo_name from '$source_branch'"

    # Use API to create branch reference
    if gh api "repos/$owner/$repo_name/git/refs/heads/$source_branch" --jq '.object.sha' | \
        xargs -I {} gh api --method POST "repos/$owner/$repo_name/git/refs" \
           --field "ref=refs/heads/$branch_name" --field "sha={}"; then
        print_success "$SUCCESS_BRANCH_CREATED"
    else
        print_error "Failed to create branch"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# ACCOUNT MANAGEMENT
# ------------------------------------------------------------------------------

list_accounts() {
    print_info "Configured GitHub accounts:"
    if [[ -f "$CONFIG_FILE" ]]; then
        jq -r '.accounts | keys[]' "$CONFIG_FILE" 2>/dev/null || print_warning "No accounts configured"
    else
        print_warning "Configuration file not found"
    fi
    return 0
}

show_help() {
    cat << EOF
GitHub CLI Helper Script
Usage: $0 [command] [account] [arguments]

GitHub management using GitHub CLI (gh)

COMMANDS:
  Repository Management:
    list-repos [account] [filter]           - List repositories (can filter by name)
    create-repo <account> <name> [desc] [vis] [init] - Create repository
      visibility: public|private (default: public)
      auto_init: true|false (default: false)
    delete-repo <account> <name>            - Delete repository (requires confirmation)
    get-repo <account> <name>               - Get repository information

  Issue Management:
    list-issues <account> <repo> [state]    - List issues (open|closed|all)
    create-issue <account> <repo> <title> [body] - Create issue
    close-issue <account> <repo> <number>   - Close issue

  Pull Request Management:
    list-prs <account> <repo> [state]       - List pull requests
    create-pr <account> <repo> <title> [base] [head] [body] - Create PR
    merge-pr <account> <repo> <number> [method] - Merge PR (merge|squash|rebase)

  Branch Management:
    list-branches <account> <repo>           - List branches
    create-branch <account> <repo> <branch> [source] - Create branch

  Account Management:
    list-accounts                            - List configured accounts
    help                                     - $HELP_SHOW_MESSAGE

EXAMPLES:
  $0 list-repos marcusquinn
  $0 create-repo marcusquinn my-new-project "My awesome project" public true
  $0 list-issues marcusquinn my-repo open
  $0 create-issue marcusquinn my-repo "Bug report" "Describe the issue here"
  $0 create-pr marcusquinn my-repo "Fix bug" main bugfix

CONFIGURATION:
  File: configs/github-cli-config.json
  Example: cp configs/github-cli-config.json.txt configs/github-cli-config.json

REQUIREMENTS:
  - GitHub CLI (gh) installed and authenticated
  - jq JSON processor
  - Valid GitHub authentication token

For more information, see the GitHub CLI documentation: https://cli.github.com/manual/
EOF
    return 0
}

# ------------------------------------------------------------------------------
# MAIN COMMAND HANDLER
# ------------------------------------------------------------------------------

main() {
    local command="${1:-help}"
    local account_name="$2"
    local target="$3"
    local options="$4"

    case "$command" in
        "list-repos")
            list_repos "$account_name" "$target"
            ;;
        "create-repo")
            local repo_desc="$options"
            local repo_vis="$5"
            local repo_init="$6"
            create_repo "$account_name" "$target" "$repo_desc" "$repo_vis" "$repo_init"
            ;;
        "delete-repo")
            delete_repo "$account_name" "$target"
            ;;
        "get-repo")
            get_repo_info "$account_name" "$target"
            ;;
        "list-issues")
            list_issues "$account_name" "$target" "$options"
            ;;
        "create-issue")
            local issue_body="$5"
            create_issue "$account_name" "$target" "$options" "$issue_body"
            ;;
        "close-issue")
            close_issue "$account_name" "$target" "$options"
            ;;
        "list-prs")
            list_prs "$account_name" "$target" "$options"
            ;;
        "create-pr")
            local pr_base="$5"
            local pr_head="$6"
            local pr_body="$7"
            create_pr "$account_name" "$target" "$options" "$pr_base" "$pr_head" "$pr_body"
            ;;
        "merge-pr")
            local merge_method="$5"
            merge_pr "$account_name" "$target" "$options" "$merge_method"
            ;;
        "list-branches")
            list_branches "$account_name" "$target"
            ;;
        "create-branch")
            local source_branch="$5"
            create_branch "$account_name" "$target" "$options" "$source_branch"
            ;;
        "list-accounts")
            list_accounts
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            print_info "Use '$0 help' for usage information"
            exit 1
            ;;
    esac
    
    return 0
}

# Initialize
check_dependencies
load_config

# Execute main function
main "$@"
