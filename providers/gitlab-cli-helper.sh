#!/bin/bash

# GitLab CLI Helper Script
# Comprehensive GitLab management using GitLab CLI (glab)
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
readonly CONFIG_FILE="$REPO_ROOT/configs/gitlab-cli-config.json"

# Colors
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Error Messages
readonly ERROR_CONFIG_MISSING="Configuration file not found at $CONFIG_FILE"
readonly ERROR_GLAB_NOT_INSTALLED="GitLab CLI (glab) is required but not installed"
readonly ERROR_NOT_LOGGED_IN="GitLab CLI is not authenticated. Run 'glab auth login'"
readonly ERROR_ACCOUNT_MISSING="Account configuration not found"
readonly ERROR_ARGS_MISSING="Missing required arguments"
readonly ERROR_API_FAILED="GitLab API request failed"

# Success Messages
readonly SUCCESS_PROJECT_CREATED="Project created successfully"
readonly SUCCESS_ISSUE_CREATED="Issue created successfully"
readonly SUCCESS_MR_CREATED="Merge request created successfully"
readonly SUCCESS_BRANCH_CREATED="Branch created successfully"
readonly SUCCESS_ISSUE_CLOSED="Issue closed successfully"
readonly SUCCESS_MR_MERGED="Merge request merged successfully"

# Help Messages
readonly HELP_SHOW_MESSAGE="Show this help message"

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
    if ! command -v glab &> /dev/null; then
        print_error "$ERROR_GLAB_NOT_INSTALLED"
        print_info "Install GitLab CLI:"
        print_info "  macOS: brew install glab"
        print_info "  Ubuntu: sudo apt install glab"
        print_info "  Other: https://glab.readthedocs.io/en/latest/installation/"
        exit 1
    fi

    if ! glab auth status &> /dev/null; then
        print_error "$ERROR_NOT_LOGGED_IN"
        print_info "Authenticate with: glab auth login"
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
        print_info "Create configuration: cp configs/gitlab-cli-config.json.txt $CONFIG_FILE"
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
        print_error "Failed to read configuration"
        return 1
    fi

    if [[ "$config" == "null" ]]; then
        print_error "$ERROR_ACCOUNT_MISSING: $account_name"
        return 1
    fi

    echo "$config"
    return 0
}

get_project_info() {
    local account_name="$1"
    local project_identifier="$2"
    local config
    config=$(get_account_config "$account_name") || exit 1

    local instance_url
    instance_url=$(echo "$config" | jq -r '.instance_url // "EMPTY"')
    if [[ "$instance_url" == "EMPTY" || -z "$instance_url" ]]; then
        print_error "Instance URL not configured for account: $account_name"
        return 1
    fi

    # Try to find project by name or ID
    local project_info
    if project_info=$(glab api "projects?search=$project_identifier" --jq ".[] | select(.name_with_namespace == \"$project_identifier\" or .path == \"$project_identifier\" or .id == ($project_identifier | tonumber?))" 2>/dev/null); then
        if [[ -n "$project_info" ]]; then
            echo "$project_info" | jq -r '.id'
            return 0
        fi
    fi

    # If not found, try exact match
    if project_info=$(glab api "projects?search=$project_identifier" --jq ".[] | select(.path_with_namespace == \"$project_identifier\") | .id" 2>/dev/null); then
        echo "$project_info"
        return 0
    fi

    print_error "$ERROR_PROJECT_NOT_FOUND: $project_identifier"
    return 1
}

# ------------------------------------------------------------------------------
# PROJECT MANAGEMENT
# ------------------------------------------------------------------------------

list_projects() {
    local account_name="$1"
    local filter="${2:-}"
    local visibility="${3:-}"
    
    local config
    config=$(get_account_config "$account_name") || exit 1

    local instance_url
    instance_url=$(echo "$config" | jq -r '.instance_url // "EMPTY"')
    if [[ "$instance_url" == "EMPTY" || -z "$instance_url" ]]; then
        print_error "Instance URL not configured for account: $account_name"
        return 1
    fi

    print_info "Listing projects from $instance_url..."
    
    local api_path="projects"
    local query_params=""
    
    if [[ -n "$filter" ]]; then
        query_params="${query_params}&search=$filter"
    fi
    if [[ -n "$visibility" ]]; then
        query_params="${query_params}&visibility=$visibility"
    fi

    if [[ -n "$query_params" ]]; then
        api_path="$api_path?${query_params#&}"
    fi

    if ! glab api "$api_path" --jq '.[] | "\(.id): \(.name_with_namespace) (\(.visibility))"'; then
        print_error "$ERROR_API_FAILED"
        return 1
    fi
    return 0
}

create_project() {
    local account_name="$1"
    local project_name="$2"
    local project_description="${3:-}"
    local visibility="${4:-public}"
    local initialize_with_readme="${5:-false}"

    if [[ -z "$project_name" ]]; then
        print_error "Project name is required"
        print_info "Usage: gitlab-cli-helper.sh create-project <account> <name> [description] [visibility] [init]"
        return 1
    fi

    local config
    config=$(get_account_config "$account_name") || exit 1

    local instance_url
    instance_url=$(echo "$config" | jq -r '.instance_url // "EMPTY"')
    if [[ "$instance_url" == "EMPTY" || -z "$instance_url" ]]; then
        print_error "Instance URL not configured for account: $account_name"
        return 1
    fi

    local group_path
    group_path=$(echo "$config" | jq -r '.default_group // "EMPTY"')

    print_info "Creating project: $project_name"

    local project_data
    project_data="{\"name\": \"$project_name\""
    if [[ -n "$project_description" ]]; then
        project_data="$project_data, \"description\": \"$project_description\""
    fi
    project_data="$project_data, \"visibility\": \"$visibility\""
    if [[ "$initialize_with_readme" == "true" ]]; then
        project_data="$project_data, \"initialize_with_readme\": true"
    fi

    local api_path="projects"
    if [[ "$group_path" != "EMPTY" && -n "$group_path" ]]; then
        api_path="groups/$group_path/projects"
    fi

    local create_data
    if create_data=$(glab api --method POST "$api_path" --field "$project_data" 2>/dev/null); then
        local project_id
        project_id=$(echo "$create_data" | jq -r '.id')
        local project_path
        project_path=$(echo "$create_data" | jq -r '.path_with_namespace')
        print_success "$SUCCESS_PROJECT_CREATED: $project_path (ID: $project_id)"
        
        # Add to configuration
        jq --arg project_id "$project_id" --arg project_path "$project_path" --arg name "$project_name" \
           '.projects[$project_id] = {id: $project_id, path: $project_path, name: $name, account: $account_name}' \
           "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
        print_error "Failed to create project"
        return 1
    fi
    return 0
}

delete_project() {
    local account_name="$1"
    local project_identifier="$2"

    if [[ -z "$project_identifier" ]]; then
        print_error "$ERROR_ARGS_MISSING"
        return 1
    fi

    local project_id
    project_id=$(get_project_info "$account_name" "$project_identifier") || exit 1

    print_warning "This will permanently delete project (ID: $project_id)"
    print_info "To confirm, type 'DELETE':"
    read -r confirmation

    if [[ "$confirmation" != "DELETE" ]]; then
        print_info "Deletion cancelled"
        return 0
    fi

    print_info "Deleting project ID: $project_id"
    
    if glab api --method DELETE "projects/$project_id"; then
        print_success "Project deleted successfully"
        
        # Remove from configuration
        jq --arg project_id "$project_id" 'del(.projects[$project_id])' \
           "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
        print_error "Failed to delete project"
        return 1
    fi
    return 0
}

get_project_details() {
    local account_name="$1"
    local project_identifier="$2"

    if [[ -z "$project_identifier" ]]; then
        print_error "$ERROR_ARGS_MISSING"
        return 1
    fi

    local project_id
    project_id=$(get_project_info "$account_name" "$project_identifier") || exit 1

    print_info "Project details (ID: $project_id):"
    glab api "projects/$project_id"
    return 0
}

# ------------------------------------------------------------------------------
# ISSUE MANAGEMENT
# ------------------------------------------------------------------------------

list_issues() {
    local account_name="$1"
    local project_identifier="$2"
    local state="${3:-opened}"

    if [[ -z "$project_identifier" ]]; then
        print_error "$ERROR_ARGS_MISSING"
        return 1
    fi

    local project_id
    project_id=$(get_project_info "$account_name" "$project_identifier") || exit 1

    print_info "Listing issues for project (ID: $project_id) (state: $state)"
    glab api "projects/$project_id/issues?state=$state" --jq '.[] | "##\(.iid): \(.title) (\(.state))"'
    return 0
}

create_issue() {
    local account_name="$1"
    local project_identifier="$2"
    local title="$3"
    local description="${4:-}"

    if [[ -z "$title" ]]; then
        print_error "Issue title is required"
        return 1
    fi

    local project_id
    project_id=$(get_project_info "$account_name" "$project_identifier") || exit 1

    print_info "Creating issue in project (ID: $project_id)"

    if glab issue create --project "$project_id" --title "$title" --description "$description"; then
        print_success "$SUCCESS_ISSUE_CREATED"
    else
        print_error "Failed to create issue"
        return 1
    fi
    return 0
}

close_issue() {
    local account_name="$1"
    local project_identifier="$2"
    local issue_number="$3"

    if [[ -z "$issue_number" ]]; then
        print_error "Issue number is required"
        return 1
    fi

    local project_id
    project_id=$(get_project_info "$account_name" "$project_identifier") || exit 1

    print_info "Closing issue #$issue_number in project (ID: $project_id)"

    if glab issue update --project "$project_id" "$issue_number" --state-event close; then
        print_success "$SUCCESS_ISSUE_CLOSED"
    else
        print_error "Failed to close issue"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# MERGE REQUEST MANAGEMENT
# ------------------------------------------------------------------------------

list_merge_requests() {
    local account_name="$1"
    local project_identifier="$2"
    local state="${3:-opened}"

    if [[ -z "$project_identifier" ]]; then
        print_error "$ERROR_ARGS_MISSING"
        return 1
    fi

    local project_id
    project_id=$(get_project_info "$account_name" "$project_identifier") || exit 1

    print_info "Listing merge requests for project (ID: $project_id) (state: $state)"
    glab api "projects/$project_id/merge_requests?state=$state" --jq '.[] | "!#\(.iid): \(.title) (\(.state))"'
    return 0
}

create_merge_request() {
    local account_name="$1"
    local project_identifier="$2"
    local title="$3"
    local source_branch="${4:-}"
    local target_branch="${5:-main}"
    local description="${6:-}"

    if [[ -z "$title" || -z "$source_branch" ]]; then
        print_error "Merge request title and source branch are required"
        return 1
    fi

    local project_id
    project_id=$(get_project_info "$account_name" "$project_identifier") || exit 1

    print_info "Creating merge request in project (ID: $project_id)"

    if glab mr create --project "$project_id" --title "$title" --source-branch "$source_branch" --target-branch "$target_branch" --description "$description"; then
        print_success "$SUCCESS_MR_CREATED"
    else
        print_error "Failed to create merge request"
        return 1
    fi
    return 0
}

merge_merge_request() {
    local account_name="$1"
    local project_identifier="$2"
    local mr_number="$3"
    local merge_method="${4:-merge}"

    if [[ -z "$mr_number" ]]; then
        print_error "Merge request number is required"
        return 1
    fi

    local project_id
    project_id=$(get_project_info "$account_name" "$project_identifier") || exit 1

    print_info "Merging merge request !#$mr_number in project (ID: $project_id)"

    if glab mr merge --project "$project_id" "$mr_number" --yes --"$merge_method"; then
        print_success "$SUCCESS_MR_MERGED"
    else
        print_error "Failed to merge merge request"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# BRANCH MANAGEMENT
# ------------------------------------------------------------------------------

list_branches() {
    local account_name="$1"
    local project_identifier="$2"

    if [[ -z "$project_identifier" ]]; then
        print_error "$ERROR_ARGS_MISSING"
        return 1
    fi

    local project_id
    project_id=$(get_project_info "$account_name" "$project_identifier") || exit 1

    print_info "Listing branches for project (ID: $project_id)"
    glab api "projects/$project_id/repository/branches" --jq '.[] | .name'
    return 0
}

create_branch() {
    local account_name="$1"
    local project_identifier="$2"
    local branch_name="$3"
    local source_branch="${4:-main}"

    if [[ -z "$branch_name" ]]; then
        print_error "Branch name is required"
        return 1
    fi

    local project_id
    project_id=$(get_project_info "$account_name" "$project_identifier") || exit 1

    print_info "Creating branch '$branch_name' in project (ID: $project_id) from '$source_branch'"

    local branch_data
    branch_data="{\"branch\": \"$branch_name\", \"ref\": \"$source_branch\"}"

    if glab api --method POST "projects/$project_id/repository/branches" --field "$branch_data"; then
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
    print_info "Configured GitLab accounts:"
    if [[ -f "$CONFIG_FILE" ]]; then
        jq -r '.accounts | keys[]' "$CONFIG_FILE" 2>/dev/null || print_warning "No accounts configured"
    else
        print_warning "Configuration file not found"
    fi
    return 0
}

show_help() {
    cat << EOF
GitLab CLI Helper Script
Usage: $0 [command] [account] [arguments]

GitLab management using GitLab CLI (glab)

COMMANDS:
  Project Management:
    list-projects [account] [filter] [vis]   - List projects
      filter: search term
      visibility: internal|private|public
    create-project <account> <name> [desc] [vis] [init] - Create project
      visibility: internal|private|public (default: public)
      init: true|false to create README (default: false)
    delete-project <account> <project_id>    - Delete project (requires confirmation)
    get-project <account> <identifier>       - Get project details

  Issue Management:
    list-issues <account> <project> [state]  - List issues (opened|closed|all)
    create-issue <account> <project> <title> [desc] - Create issue
    close-issue <account> <project> <number> - Close issue

  Merge Request Management:
    list-mrs <account> <project> [state]     - List merge requests
    create-mr <account> <project> <title> <source> [target] [desc] - Create MR
    merge-mr <account> <project> <number> [method] - Merge MR (merge|squash|rebase)

  Branch Management:
    list-branches <account> <project>        - List branches
    create-branch <account> <project> <branch> [source] - Create branch

  Account Management:
    list-accounts                           - List configured accounts
    help                                    - $HELP_SHOW_MESSAGE

EXAMPLES:
  $0 list-projects marcusquinn
  $0 create-project marcusquinn new-project "My GitLab project" private true
  $0 list-issues marcusquinn my-project opened
  $0 create-issue marcusquinn my-project "Bug report" "Issue description"
  $0 create-mr marcusquinn my-project "Fix feature" fix-branch main

CONFIGURATION:
  File: configs/gitlab-cli-config.json
  Example: cp configs/gitlab-cli-config.json.txt configs/gitlab-cli-config.json

REQUIREMENTS:
  - GitLab CLI (glab) installed and authenticated
  - jq JSON processor
  - Valid GitLab access token

For more information, see the GitLab CLI documentation: https://glab.readthedocs.io/
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
        "list-projects")
            list_projects "$account_name" "$target" "$options"
            ;;
        "create-project")
            create_project "$account_name" "$target" "$options" "$5" "$6"
            ;;
        "delete-project")
            delete_project "$account_name" "$target"
            ;;
        "get-project")
            get_project_details "$account_name" "$target"
            ;;
        "list-issues")
            list_issues "$account_name" "$target" "$options"
            ;;
        "create-issue")
            create_issue "$account_name" "$target" "$options" "$5"
            ;;
        "close-issue")
            close_issue "$account_name" "$target" "$options"
            ;;
        "list-mrs")
            list_merge_requests "$account_name" "$target" "$options"
            ;;
        "create-mr")
            create_merge_request "$account_name" "$target" "$options" "$5" "$6" "$7"
            ;;
        "merge-mr")
            merge_merge_request "$account_name" "$target" "$options" "$5"
            ;;
        "list-branches")
            list_branches "$account_name" "$target"
            ;;
        "create-branch")
            create_branch "$account_name" "$target" "$options" "$5"
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
