#!/bin/bash

# Vercel CLI Helper Script
# Comprehensive Vercel deployment and project management using Vercel CLI
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
readonly CONFIG_FILE="$REPO_ROOT/configs/vercel-cli-config.json"

# Colors
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Error Messages
readonly ERROR_CONFIG_MISSING="Configuration file not found at $CONFIG_FILE"
readonly ERROR_VERCEL_NOT_INSTALLED="Vercel CLI is required but not installed"
readonly ERROR_NOT_LOGGED_IN="Vercel CLI is not authenticated. Run 'vercel login'"
readonly ERROR_ACCOUNT_MISSING="Account configuration not found"
# Removed unused error constants to fix ShellCheck SC2034 warnings
readonly ERROR_DEPLOYMENT_FAILED="Deployment failed"

# Success Messages
# Removed unused success constant to fix ShellCheck SC2034 warning
readonly SUCCESS_DEPLOYMENT_COMPLETE="Deployment completed successfully"
readonly SUCCESS_ENV_UPDATED="Environment variables updated successfully"
readonly SUCCESS_DOMAIN_ADDED="Domain added successfully"
# Removed unused success constant to fix ShellCheck SC2034 warning

# JQ Expressions
readonly JQ_TEAM_ID_EXPR='.team_id // empty'

# ------------------------------------------------------------------------------
# UTILITY FUNCTIONS
# ------------------------------------------------------------------------------

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg" >&2
    return 0
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $msg"
    return 0
}

print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    return 0
}

# ------------------------------------------------------------------------------
# DEPENDENCY CHECKS
# ------------------------------------------------------------------------------

check_dependencies() {
    local command="${1:-}"

    if ! command -v vercel &> /dev/null; then
        print_error "$ERROR_VERCEL_NOT_INSTALLED"
        print_info "Install Vercel CLI:"
        print_info "  npm: npm i -g vercel"
        print_info "  yarn: yarn global add vercel"
        print_info "  pnpm: pnpm add -g vercel"
        exit 1
    fi

    # Skip authentication check for local development commands and help
    case "$command" in
        "help"|"-h"|"--help"|"dev"|"build"|"init"|"list-accounts")
            print_info "Running local command (authentication not required)"
            ;;
        *)
            if ! vercel whoami &> /dev/null; then
                print_error "$ERROR_NOT_LOGGED_IN"
                print_info "Authenticate with: vercel login"
                print_info "Or use local development commands: dev, build, init"
                exit 1
            fi
            ;;
    esac

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
        print_info "Create configuration: cp configs/vercel-cli-config.json.txt $CONFIG_FILE"
        return 1
    fi
    return 0
}

get_account_config() {
    local account_name="$1"
    
    if ! jq -e ".accounts.\"$account_name\"" "$CONFIG_FILE" &>/dev/null; then
        print_error "$ERROR_ACCOUNT_MISSING: $account_name"
        return 1
    fi
    
    jq -r ".accounts.\"$account_name\"" "$CONFIG_FILE"
    return 0
}

# ------------------------------------------------------------------------------
# PROJECT MANAGEMENT FUNCTIONS
# ------------------------------------------------------------------------------

list_projects() {
    local account_name="${1:-}"
    
    print_info "Listing Vercel projects..."
    
    if [[ -n "$account_name" ]]; then
        local account_config
        if ! account_config=$(get_account_config "$account_name"); then
            return 1
        fi
        
        local team_id
        team_id=$(echo "$account_config" | jq -r "$JQ_TEAM_ID_EXPR")
        
        if [[ -n "$team_id" ]]; then
            vercel list --scope "$team_id"
        else
            vercel list
        fi
    else
        vercel list
    fi
    return 0
}

# ------------------------------------------------------------------------------
# ENVIRONMENT VARIABLES MANAGEMENT
# ------------------------------------------------------------------------------

list_env_vars() {
    local account_name="$1"
    local project_name="$2"
    local environment="${3:-development}"

    print_info "Listing environment variables for project: $project_name"

    local account_config
    if ! account_config=$(get_account_config "$account_name"); then
        return 1
    fi

    local team_id
    team_id=$(echo "$account_config" | jq -r "$JQ_TEAM_ID_EXPR")

    local env_args=()
    if [[ -n "$team_id" ]]; then
        env_args+=(--scope "$team_id")
    fi

    vercel env ls "${env_args[@]}" --environment "$environment"
    return 0
}

add_env_var() {
    local account_name="$1"
    local project_name="$2"
    local var_name="$3"
    local var_value="$4"
    local environment="${5:-development}"

    print_info "Adding environment variable: $var_name"

    local account_config
    if ! account_config=$(get_account_config "$account_name"); then
        return 1
    fi

    local team_id
    team_id=$(echo "$account_config" | jq -r "$JQ_TEAM_ID_EXPR")

    local env_args=()
    if [[ -n "$team_id" ]]; then
        env_args+=(--scope "$team_id")
    fi

    if echo "$var_value" | vercel env add "$var_name" "${env_args[@]}" --environment "$environment"; then
        print_success "$SUCCESS_ENV_UPDATED"
    else
        print_error "Failed to add environment variable"
        return 1
    fi
    return 0
}

remove_env_var() {
    local account_name="$1"
    local project_name="$2"
    local var_name="$3"
    local environment="${4:-development}"

    print_info "Removing environment variable: $var_name"

    local account_config
    if ! account_config=$(get_account_config "$account_name"); then
        return 1
    fi

    local team_id
    team_id=$(echo "$account_config" | jq -r "$JQ_TEAM_ID_EXPR")

    local env_args=()
    if [[ -n "$team_id" ]]; then
        env_args+=(--scope "$team_id")
    fi

    if vercel env rm "$var_name" "${env_args[@]}" --environment "$environment" --yes; then
        print_success "Environment variable removed successfully"
    else
        print_error "Failed to remove environment variable"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# DOMAIN MANAGEMENT FUNCTIONS
# ------------------------------------------------------------------------------

list_domains() {
    local account_name="$1"

    print_info "Listing domains..."

    local account_config
    if ! account_config=$(get_account_config "$account_name"); then
        return 1
    fi

    local team_id
    team_id=$(echo "$account_config" | jq -r "$JQ_TEAM_ID_EXPR")

    if [[ -n "$team_id" ]]; then
        vercel domains ls --scope "$team_id"
    else
        vercel domains ls
    fi
    return 0
}

add_domain() {
    local account_name="$1"
    local project_name="$2"
    local domain_name="$3"

    print_info "Adding domain: $domain_name to project: $project_name"

    local account_config
    if ! account_config=$(get_account_config "$account_name"); then
        return 1
    fi

    local team_id
    team_id=$(echo "$account_config" | jq -r "$JQ_TEAM_ID_EXPR")

    local domain_args=()
    if [[ -n "$team_id" ]]; then
        domain_args+=(--scope "$team_id")
    fi

    if vercel domains add "$domain_name" "${domain_args[@]}"; then
        print_success "$SUCCESS_DOMAIN_ADDED"

        # Link domain to project
        if vercel alias set "$project_name" "$domain_name" "${domain_args[@]}"; then
            print_success "Domain linked to project successfully"
        else
            print_warning "Domain added but failed to link to project"
        fi
    else
        print_error "Failed to add domain"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# LOCAL DEVELOPMENT FUNCTIONS
# ------------------------------------------------------------------------------

start_dev_server() {
    local account_name="$1"
    local project_path="${2:-.}"
    local port="${3:-3000}"
    local token="${4:-}"

    print_info "Starting local development server..."
    print_info "Project path: $project_path"
    print_info "Port: $port"

    cd "$project_path" || {
        print_error "Failed to change to project directory: $project_path"
        return 1
    }

    # Check if we have authentication or token
    if [[ -n "$token" ]] || vercel whoami &> /dev/null; then
        print_info "Using Vercel CLI development server (authenticated)"
        local dev_args=("--listen" "$port" "--yes")
        if [[ -n "$token" ]]; then
            dev_args+=(--token "$token")
        fi

        print_info "Starting Vercel dev server on http://localhost:$port"
        print_info "Press Ctrl+C to stop the server"

        vercel dev "${dev_args[@]}"
    else
        print_info "No authentication found - using local development mode"
        start_local_dev_server "$project_path" "$port"
    fi
    return 0
}

start_local_dev_server() {
    local project_path="$1"
    local port="$2"

    print_info "Starting local development server (no Vercel authentication required)"
    print_info "Server will run on http://localhost:$port"

    # Check for common development scripts
    if [[ -f "package.json" ]]; then
        if jq -e '.scripts.dev' package.json &>/dev/null; then
            print_info "Found 'dev' script in package.json"
            PORT="$port" npm run dev
        elif jq -e '.scripts.start' package.json &>/dev/null; then
            print_info "Found 'start' script in package.json"
            PORT="$port" npm run start
        elif [[ -f "server.js" ]]; then
            print_info "Found server.js - starting with Node.js"
            PORT="$port" node server.js
        elif [[ -f "index.js" ]]; then
            print_info "Found index.js - starting with Node.js"
            PORT="$port" node index.js
        else
            print_warning "No development script found in package.json"
            print_info "Available scripts:"
            jq -r '.scripts | keys[]' package.json 2>/dev/null || echo "  No scripts found"
            return 1
        fi
    elif [[ -f "server.js" ]]; then
        print_info "Found server.js - starting with Node.js"
        PORT="$port" node server.js
    elif [[ -f "index.js" ]]; then
        print_info "Found index.js - starting with Node.js"
        PORT="$port" node index.js
    elif [[ -f "index.html" ]]; then
        print_info "Found index.html - starting simple HTTP server"
        if command -v python3 &> /dev/null; then
            print_info "Using Python 3 HTTP server"
            python3 -m http.server "$port"
        elif command -v python &> /dev/null; then
            print_info "Using Python 2 HTTP server"
            python -m SimpleHTTPServer "$port"
        elif command -v npx &> /dev/null; then
            print_info "Using npx serve"
            npx serve -p "$port"
        else
            print_error "No suitable HTTP server found"
            print_info "Install Python or Node.js to serve static files"
            return 1
        fi
    else
        print_error "No recognizable project structure found"
        print_info "Expected: package.json, server.js, index.js, or index.html"
        return 1
    fi
    return 0
}

build_project() {
    local account_name="$1"
    local project_path="${2:-.}"
    local token="${3:-}"

    print_info "Building project locally..."
    print_info "Project path: $project_path"

    cd "$project_path" || {
        print_error "Failed to change to project directory: $project_path"
        return 1
    }

    # Check if we have authentication or token
    if [[ -n "$token" ]] || vercel whoami &> /dev/null; then
        print_info "Using Vercel CLI build (authenticated)"
        local build_args=()
        if [[ -n "$token" ]]; then
            build_args+=(--token "$token")
        fi

        if [[ ${#build_args[@]} -gt 0 ]]; then
            vercel build "${build_args[@]}"
        else
            vercel build
        fi

        local exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            print_success "Vercel build completed successfully"
        else
            print_error "Vercel build failed"
            return 1
        fi
    else
        print_info "No authentication found - using local build mode"
        build_local_project "$project_path"
    fi
    return 0
}

build_local_project() {
    local project_path="$1"

    print_info "Building project locally (no Vercel authentication required)"

    # Check for common build scripts
    if [[ -f "package.json" ]]; then
        if jq -e '.scripts.build' package.json &>/dev/null; then
            print_info "Found 'build' script in package.json"
            npm run build
            local exit_code=$?
            if [[ $exit_code -eq 0 ]]; then
                print_success "Local build completed successfully"

                # Show build output location
                if [[ -d "dist" ]]; then
                    print_info "Build output: ./dist/"
                elif [[ -d "build" ]]; then
                    print_info "Build output: ./build/"
                elif [[ -d ".next" ]]; then
                    print_info "Build output: ./.next/"
                elif [[ -d "out" ]]; then
                    print_info "Build output: ./out/"
                fi
            else
                print_error "Local build failed"
                return 1
            fi
        else
            print_warning "No 'build' script found in package.json"
            print_info "Available scripts:"
            jq -r '.scripts | keys[]' package.json 2>/dev/null || echo "  No scripts found"
            return 1
        fi
    else
        print_warning "No package.json found - nothing to build"
        print_info "This appears to be a static project"
        return 0
    fi
    return 0
}

init_project() {
    local account_name="$1"
    local project_path="${2:-.}"
    local example="${3:-}"

    print_info "Initializing Vercel example project..."
    print_info "Project path: $project_path"

    local init_args=()

    if [[ -n "$example" ]]; then
        init_args+=("$example")
        print_info "Using example: $example"
    fi

    init_args+=("$project_path")

    if vercel init "${init_args[@]}"; then
        print_success "Project initialized successfully"
    else
        print_error "Project initialization failed"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# PROJECT INFORMATION FUNCTIONS
# ------------------------------------------------------------------------------

get_project_info() {
    local account_name="$1"
    local project_name="$2"

    print_info "Getting project information: $project_name"

    local account_config
    if ! account_config=$(get_account_config "$account_name"); then
        return 1
    fi

    local team_id
    team_id=$(echo "$account_config" | jq -r "$JQ_TEAM_ID_EXPR")

    local inspect_args=()
    if [[ -n "$team_id" ]]; then
        inspect_args+=(--scope "$team_id")
    fi

    vercel inspect "$project_name" "${inspect_args[@]}"
    return 0
}

list_deployments() {
    local account_name="$1"
    local project_name="${2:-}"
    local limit="${3:-10}"

    print_info "Listing deployments..."

    local account_config
    if ! account_config=$(get_account_config "$account_name"); then
        return 1
    fi

    local team_id
    team_id=$(echo "$account_config" | jq -r "$JQ_TEAM_ID_EXPR")

    local list_args=()
    if [[ -n "$team_id" ]]; then
        list_args+=(--scope "$team_id")
    fi

    if [[ -n "$project_name" ]]; then
        list_args+=("$project_name")
    fi

    vercel list "${list_args[@]}" --limit "$limit"
    return 0
}

# ------------------------------------------------------------------------------
# ACCOUNT MANAGEMENT
# ------------------------------------------------------------------------------

list_accounts() {
    print_info "Available Vercel accounts:"

    if [[ -f "$CONFIG_FILE" ]]; then
        jq -r '.accounts | keys[]' "$CONFIG_FILE" | while read -r account; do
            local account_info
            account_info=$(jq -r ".accounts.\"$account\"" "$CONFIG_FILE")
            local team_name
            team_name=$(echo "$account_info" | jq -r '.team_name // "Personal"')
            local description
            description=$(echo "$account_info" | jq -r '.description // "No description"')

            echo "  - $account ($team_name): $description"
        done
    else
        print_warning "No configuration file found"
    fi

    print_info ""
    print_info "Current Vercel user:"
    vercel whoami
    return 0
}

# ------------------------------------------------------------------------------
# HELP FUNCTION
# ------------------------------------------------------------------------------

show_help() {
    cat << 'EOF'
Vercel CLI Helper - Comprehensive Vercel deployment and project management

USAGE:
  ./providers/vercel-cli-helper.sh [COMMAND] [ACCOUNT] [OPTIONS...]

COMMANDS:
  Project Management:
    list-projects [account]                    - List all projects
    deploy [account] [path] [env] [build-env] - Deploy project
    get-project [account] [project]           - Get project information
    list-deployments [account] [project] [limit] - List deployments

  Local Development (No Authentication Required):
    dev [account] [path] [port] [token]       - Start development server (local or Vercel)
    build [account] [path] [token]            - Build project locally (local or Vercel)
    init [account] [path] [example]           - Initialize Vercel example project

  Environment Variables:
    list-env [account] [project] [env]        - List environment variables
    add-env [account] [project] [name] [value] [env] - Add environment variable
    remove-env [account] [project] [name] [env] - Remove environment variable

  Domain Management:
    list-domains [account]                    - List domains
    add-domain [account] [project] [domain]   - Add domain to project

  Account Management:
    list-accounts                             - List configured accounts
    whoami                                    - Show current Vercel user

  General:
    help                                      - Show this help message

PARAMETERS:
  account    - Account name from configuration (required for most commands)
  project    - Project name or ID
  path       - Project path (default: current directory)
  env        - Environment: development, preview, production (default: preview)
  domain     - Domain name to add
  name       - Environment variable name
  value      - Environment variable value
  limit      - Number of deployments to list (default: 10)

EXAMPLES:
  $0 list-projects personal
  $0 deploy personal ./my-app production
  $0 dev personal ./my-app 3001
  $0 build personal ./my-app
  $0 init personal ./new-project nextjs
  $0 add-env personal my-project API_KEY "secret-key" production
  $0 add-domain personal my-project example.com
  $0 list-deployments personal my-project 20

CONFIGURATION:
  File: configs/vercel-cli-config.json
  Example: cp configs/vercel-cli-config.json.txt configs/vercel-cli-config.json

REQUIREMENTS:
  - Vercel CLI installed (authentication optional for local development)
  - jq JSON processor
  - Node.js (for local development server)
  - Valid Vercel authentication token (for deployment commands only)

For more information, see the Vercel CLI documentation: https://vercel.com/docs/cli
EOF
    return 0
}

# ------------------------------------------------------------------------------
# MAIN FUNCTION
# ------------------------------------------------------------------------------

main() {
    local command="${1:-help}"
    local account_name="${2:-}"
    local target="${3:-}"
    local options="${4:-}"

    case "$command" in
        "list-projects")
            list_projects "$account_name"
            ;;
        "deploy")
            local project_path="$target"
            local environment="$options"
            local build_env="$5"
            deploy_project "$account_name" "$project_path" "$environment" "$build_env"
            ;;
        "get-project")
            get_project_info "$account_name" "$target"
            ;;
        "list-deployments")
            local project_name="$target"
            local limit="$options"
            list_deployments "$account_name" "$project_name" "$limit"
            ;;
        "dev")
            local project_path="$target"
            local port="$options"
            local token="${5:-}"
            start_dev_server "$account_name" "$project_path" "$port" "$token"
            ;;
        "build")
            local project_path="$target"
            local token="$options"
            build_project "$account_name" "$project_path" "$token"
            ;;
        "init")
            local project_path="$target"
            local framework="$options"
            init_project "$account_name" "$project_path" "$framework"
            ;;
        "list-env")
            local project_name="$target"
            local environment="$options"
            list_env_vars "$account_name" "$project_name" "$environment"
            ;;
        "add-env")
            local project_name="$target"
            local var_name="$options"
            local var_value="${5:-}"
            local environment="${6:-}"
            add_env_var "$account_name" "$project_name" "$var_name" "$var_value" "$environment"
            ;;
        "remove-env")
            local project_name="$target"
            local var_name="$options"
            local environment="${5:-}"
            remove_env_var "$account_name" "$project_name" "$var_name" "$environment"
            ;;
        "list-domains")
            list_domains "$account_name"
            ;;
        "add-domain")
            local project_name="$target"
            local domain_name="$options"
            add_domain "$account_name" "$project_name" "$domain_name"
            ;;
        "list-accounts")
            list_accounts
            ;;
        "whoami")
            vercel whoami
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
check_dependencies "${1:-help}"
load_config

# Execute main function
main "$@"

deploy_project() {
    local account_name="$1"
    local project_path="${2:-.}"
    local environment="${3:-preview}"
    local build_env="${4:-}"
    
    print_info "Deploying project from: $project_path"
    print_info "Environment: $environment"
    
    local account_config
    if ! account_config=$(get_account_config "$account_name"); then
        return 1
    fi
    
    local team_id
    team_id=$(echo "$account_config" | jq -r "$JQ_TEAM_ID_EXPR")

    local deploy_args=()
    
    if [[ -n "$team_id" ]]; then
        deploy_args+=(--scope "$team_id")
    fi
    
    case "$environment" in
        "production"|"prod")
            deploy_args+=(--prod)
            ;;
        "preview")
            # Default behavior
            ;;
        *)
            print_warning "Unknown environment: $environment, using preview"
            ;;
    esac
    
    if [[ -n "$build_env" ]]; then
        deploy_args+=(--build-env "$build_env")
    fi
    
    if vercel deploy "$project_path" "${deploy_args[@]}"; then
        print_success "$SUCCESS_DEPLOYMENT_COMPLETE"
    else
        print_error "$ERROR_DEPLOYMENT_FAILED"
        return 1
    fi
    return 0
}
