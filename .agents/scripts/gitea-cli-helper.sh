#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Gitea CLI Helper Script
# Comprehensive Gitea management using tea (Gitea CLI) and API
# Managed by AI DevOps Framework

# Set strict mode
set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION & CONSTANTS
# ------------------------------------------------------------------------------

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR="$script_dir"

repo_root="$(dirname "$SCRIPT_DIR")"
readonly REPO_ROOT="$repo_root"
readonly CONFIG_FILE="$REPO_ROOT/configs/gitea-cli-config.json"

# Colors
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Common constants
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
# Error Messages
readonly ERROR_CONFIG_MISSING="Configuration file not found at $CONFIG_FILE"
readonly ERROR_TEA_NOT_INSTALLED="Gitea CLI (tea) is required but not installed"
readonly ERROR_NOT_LOGGED_IN="Gitea CLI is not authenticated. Run 'tea login'"
readonly ERROR_ACCOUNT_MISSING="Account configuration not found"
readonly ERROR_ARGS_MISSING="Missing required arguments"
readonly ERROR_API_FAILED="Gitea API request failed"
readonly ERROR_REPO_NAME_REQUIRED="Repository name is required"
readonly ERROR_ISSUE_TITLE_REQUIRED="Issue title is required"
readonly ERROR_ISSUE_NUMBER_REQUIRED="Issue number is required"
readonly ERROR_PR_NUMBER_REQUIRED="Pull request number is required"
readonly ERROR_BRANCH_NAME_REQUIRED="Branch name is required"
readonly ERROR_REPO_NOT_FOUND="Repository not found"
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
readonly CONTENT_TYPE_JSON="$CONTENT_TYPE_JSON"
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
    if ! command -v tea &> /dev/null; then
        print_error "$ERROR_TEA_NOT_INSTALLED"
        print_info "Install Gitea CLI (tea):"
        print_info "  Go: go install code.gitea.io/tea/cmd/tea@latest"
        print_info "  Binary: https://dl.gitea.io/tea/"
        print_info "  Homebrew: brew install tea (if available)"
        exit 1
    fi

    # Check if logged in (tea doesn't have auth status command, so we'll check config)
    if ! tea repos list --limit 1 &>/dev/null; then
        print_error "$ERROR_NOT_LOGGED_IN"
        print_info "Authenticate with: tea login add"
        print_info "Or set TEA_TOKEN environment variable"
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
        print_info "Create configuration: cp configs/gitea-cli-config.json.txt $CONFIG_FILE"
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

get_repo_full_name() {
    local account_name="$1"
    local repo_name="$2"
    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "$ERROR_OWNER_NOT_CONFIGURED: $account_name"
        return 1
    fi

    echo "$owner/$repo_name"
    return 0
}

get_repo_info() {
    local account_name="$1"
    local repo_name="$2"
    local repo_full_name
    repo_full_name=$(get_repo_full_name "$account_name" "$repo_name") || exit 1

    local repo_info
    if repo_info=$(tea repos list --login "$account_name" --owner "${repo_full_name%/*}" --repo "${repo_full_name#*/}" --output json 2>/dev/null); then
        echo "$repo_info"
        return 0
    fi

    print_error "$ERROR_REPO_NOT_FOUND: $repo_full_name"
    return 1
}

# ------------------------------------------------------------------------------
# REPOSITORY MANAGEMENT
# ------------------------------------------------------------------------------

list_repos() {
    local account_name="$1"
    local owner_filter="${2:-}"
    
    local config
    config=$(get_account_config "$account_name") || exit 1

    local owner
    owner=$(echo "$config" | jq -r '.owner // "EMPTY"')
    if [[ "$owner" == "EMPTY" || -z "$owner" ]]; then
        print_error "$ERROR_OWNER_NOT_CONFIGURED: $account_name"
        return 1
    fi

    local tea_args=()
    tea_args+=("--login" "$account_name")
    tea_args+=("--owner" "$owner")
    
    if [[ -n "$owner_filter" ]]; then
        tea_args+=("--search" "$owner_filter")
    fi

    print_info "Listing repositories for $owner..."
    
    if ! tea repos list "${tea_args[@]}" --limit 50 --output tsb; then
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
        print_info "Usage: gitea-cli-helper.sh create-repo <account> <repo-name> [description] [visibility] [init]"
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

    local tea_args=()
    tea_args+=("--login" "$account_name")
    tea_args+=("--name" "$repo_name" "--owner" "$owner")
    
    if [[ -n "$repo_description" ]]; then
        tea_args+=("--description" "$repo_description")
    fi
    
    case "$visibility" in
        "private")
            tea_args+=("--private")
            ;;
        "internal")
            tea_args+=("--internal")
            ;;
        "public")
            tea_args+=("--public")
            ;;
        *)
            # Default to public if not specified
            tea_args+=("--public")
            ;;
    esac
    
    if [[ "$auto_init" == "true" ]]; then
        tea_args+=("--init")
    fi

    if tea repos create "${tea_args[@]}"; then
        print_success "$SUCCESS_REPO_CREATED: $owner/$repo_name"
        
        # Add to configuration if not exists
        local repo_full_name="$owner/$repo_name"
        if ! jq -e ".repos.\"$repo_full_name\"" "$CONFIG_FILE" &>/dev/null; then
            jq --arg repo "$repo_full_name" --arg account "$account_name" --arg name "$repo_name" \
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

    local repo_full_name
    repo_full_name=$(get_repo_full_name "$account_name" "$repo_name") || exit 1

    print_warning "This will permanently delete repository: $repo_full_name"
    print_info "To confirm, type 'DELETE':"
    read -r confirmation

    if [[ "$confirmation" != "DELETE" ]]; then
        print_info "Deletion cancelled"
        return 0
    fi

    print_info "Deleting repository: $repo_full_name"
    
    if tea repos delete --login "$account_name" --owner "${repo_full_name%/*}" --repo "${repo_full_name#*/}"; then
        print_success "Repository deleted successfully"
        
        # Remove from configuration
        jq --arg repo "$repo_full_name" 'del(.repos[$repo])' \
           "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
        print_error "Failed to delete repository"
        return 1
    fi
    return 0
}

get_repo_details() {
    local account_name="$1"
    local repo_name="$2"

    if [[ -z "$repo_name" ]]; then
        print_error "$ERROR_ARGS_MISSING"
        return 1
    fi

    local repo_full_name
    repo_full_name=$(get_repo_full_name "$account_name" "$repo_name") || exit 1

    print_info "Repository details for $repo_full_name:"
    tea repos show --login "$account_name" --owner "${repo_full_name%/*}" --repo "${repo_full_name#*/}" --output json | jq .
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

    local repo_full_name
    repo_full_name=$(get_repo_full_name "$account_name" "$repo_name") || exit 1

    print_info "Listing issues for $repo_full_name (state: $state)"
    tea issues list --login "$account_name" --owner "${repo_full_name%/*}" --repo "${repo_full_name#*/}" --state "$state" --limit 50 --output tsb
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

    local repo_full_name
    repo_full_name=$(get_repo_full_name "$account_name" "$repo_name") || exit 1

    print_info "Creating issue in $repo_full_name"

    local tea_args=()
    tea_args+=("--login" "$account_name")
    tea_args+=("--title" "$title" "--owner" "${repo_full_name%/*}" "--repo" "${repo_full_name#*/}")
    
    if [[ -n "$body" ]]; then
        tea_args+=("--body" "$body")
    fi

    if tea issues create "${tea_args[@]}" --output json; then
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

    local repo_full_name
    repo_full_name=$(get_repo_full_name "$account_name" "$repo_name") || exit 1

    print_info "Closing issue #$issue_number in $repo_full_name"

    if tea issues close --login "$account_name" --owner "${repo_full_name%/*}" --repo "${repo_full_name#*/}" --index "$issue_number"; then
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

    local repo_full_name
    repo_full_name=$(get_repo_full_name "$account_name" "$repo_name") || exit 1

    print_info "Listing pull requests for $repo_full_name (state: $state)"
    tea pulls list --login "$account_name" --owner "${repo_full_name%/*}" --repo "${repo_full_name#*/}" --state "$state" --limit 50 --output tsb
    return 0
}

create_pr() {
    local account_name="$1"
    local repo_name="$2"
    local title="$3"
    local head_branch="${4:-}"
    local base_branch="${5:-main}"
    local body="${6:-}"

    if [[ -z "$title" || -z "$head_branch" ]]; then
        print_error "Pull request title and head branch are required"
        return 1
    fi

    local repo_full_name
    repo_full_name=$(get_repo_full_name "$account_name" "$repo_name") || exit 1

    print_info "Creating pull request in $repo_full_name"

    local tea_args=()
    tea_args+=("--login" "$account_name")
    tea_args+=("--title" "$title" "--head" "$head_branch" "--base" "$base_branch")
    tea_args+=("--owner" "${repo_full_name%/*}" "--repo" "${repo_full_name#*/}")
    
    if [[ -n "$body" ]]; then
        tea_args+=("--body" "$body")
    fi

    if tea pulls create "${tea_args[@]}" --output json; then
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

    local repo_full_name
    repo_full_name=$(get_repo_full_name "$account_name" "$repo_name") || exit 1

    print_info "Merging pull request #$pr_number in $repo_full_name"

    local tea_args=()
    tea_args+=("--login" "$account_name")
    tea_args+=("--owner" "${repo_full_name%/*}" --repo "${repo_full_name#*/}" --index "$pr_number")
    
    case "$merge_method" in
        "squash")
            tea_args+=("--squash")
            ;;
        "rebase")
            tea_args+=("--rebase")
            ;;
        "merge"|*)
            # Default merge behavior
            ;;
    esac

    if tea pulls merge "${tea_args[@]}"; then
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

    local repo_full_name
    repo_full_name=$(get_repo_full_name "$account_name" "$repo_name") || exit 1

    print_info "Listing branches for $repo_full_name"
    tea repos branches --login "$account_name" --owner "${repo_full_name%/*}" --repo "${repo_full_name#*/}" --output tsb
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

    # Get API URL from config or use default
    local api_url
    api_url=$(echo "$config" | jq -r '.api_url // "https://gitea.com/api/v1"')
    local token
    token=$(echo "$config" | jq -r '.token // ""')

    if [[ -z "$token" ]]; then
        print_error "API token not configured for account: $account_name"
        return 1
    fi

    print_info "Creating branch '$branch_name' in $owner/$repo_name from '$source_branch'"

    # Use API to create branch since tea doesn't have branch creation command
    local branch_data
    branch_data="{\"new_branch_name\": \"$branch_name\", \"old_branch_name\": \"$source_branch\"}"

    local curl_args=()
    curl_args+=("-X" "POST" "$api_url/repos/$owner/$repo_name/branches")
    curl_args+=("-H" "$AUTH_HEADER_TOKEN $token")
    curl_args+=("-H" "$CONTENT_TYPE_JSON")
    curl_args+=("-d" "$branch_data")

    if curl "${curl_args[@]}" &>/dev/null; then
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
    print_info "Configured Gitea accounts:"
    if [[ -f "$CONFIG_FILE" ]]; then
        jq -r '.accounts | keys[]' "$CONFIG_FILE" 2>/dev/null || print_warning "No accounts configured"
    else
        print_warning "Configuration file not found"
    fi
    return 0
}

show_help() {
    cat << EOF
Gitea CLI Helper Script
Usage: $0 [command] [account] [arguments]

Gitea management using Gitea CLI (tea)

COMMANDS:
  Repository Management:
    list-repos [account] [filter]           - List repositories (can filter by name)
    create-repo <account> <name> [desc] [vis] [init] - Create repository
      visibility: public|private|internal (default: public)
      auto_init: true|false (default: false)
    delete-repo <account> <name>            - Delete repository (requires confirmation)
    get-repo <account> <name>               - Get repository information

  Issue Management:
    list-issues <account> <repo> [state]    - List issues (open|closed|all)
    create-issue <account> <repo> <title> [body] - Create issue
    close-issue <account> <repo> <number>   - Close issue

  Pull Request Management:
    list-prs <account> <repo> [state]       - List pull requests
    create-pr <account> <repo> <title> <head> [base] [body] - Create PR
    merge-pr <account> <repo> <number> [method] - Merge PR (merge|squash|rebase)

  Branch Management:
    list-branches <account> <repo>          - List branches
    create-branch <account> <repo> <branch> [source] - Create branch

  Account Management:
    list-accounts                           - List configured accounts
    help                                     - $HELP_SHOW_MESSAGE

EXAMPLES:
  $0 list-repos marcusquinn
  $0 create-repo marcusquinn my-gitea-project "My Gitea project" private true
  $0 list-issues marcusquinn my-repo open
  $0 create-issue marcusquinn my-repo "Bug report" "Describe the issue here"
  $0 create-pr marcusquinn my-repo "Fix bug" bugfix-branch main

CONFIGURATION:
  File: configs/gitea-cli-config.json
  Example: cp configs/gitea-cli-config.json.txt configs/gitea-cli-config.json

REQUIREMENTS:
  - Gitea CLI (tea) installed and authenticated
  - jq JSON processor
  - Valid Gitea access token (configured in config file)

For more information, see the Gitea CLI documentation: https://gitea.com/tea/
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
            get_repo_details "$account_name" "$target"
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
            local pr_title="$options"
            local pr_head="$5"
            local pr_base="$6"
            local pr_body="$7"
            create_pr "$account_name" "$target" "$pr_title" "$pr_head" "$pr_base" "$pr_body"
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
            print_error "$ERROR_UNKNOWN_COMMAND $command"
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
