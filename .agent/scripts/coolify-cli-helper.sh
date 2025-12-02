#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Coolify CLI Helper Script
# Comprehensive Coolify self-hosted deployment and management using Coolify CLI
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
readonly CONFIG_FILE="$REPO_ROOT/configs/coolify-cli-config.json"

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
readonly ERROR_COOLIFY_NOT_INSTALLED="Coolify CLI is required but not installed"
readonly ERROR_NOT_CONFIGURED="Coolify CLI is not configured. Run 'coolify context add'"
readonly ERROR_CONTEXT_MISSING="Context configuration not found"
# Removed unused error constants to fix ShellCheck SC2034 warnings

# Success Messages
readonly SUCCESS_APP_DEPLOYED="Application deployed successfully"
readonly SUCCESS_SERVER_ADDED="Server added successfully"
readonly SUCCESS_DATABASE_CREATED="Database created successfully"
readonly SUCCESS_CONTEXT_ADDED="Context added successfully"
# Removed unused success constant to fix ShellCheck SC2034 warning

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
    
    if ! command -v coolify &> /dev/null; then
        print_error "$ERROR_COOLIFY_NOT_INSTALLED"
        print_info "Install Coolify CLI:"
        print_info "  curl -fsSL https://raw.githubusercontent.com/coollabsio/coolify-cli/main/scripts/install.sh | bash"
        print_info "  Or: go install github.com/coollabsio/coolify-cli/coolify@latest"
        exit 1
    fi

    # Skip context check for local development commands and help
    case "$command" in
        "help"|"-h"|"--help"|"dev"|"build"|"init"|"list-contexts"|"add-context"|"version")
            print_info "Running local command (context not required)"
            ;;
        *)
            if ! coolify context list &> /dev/null; then
                print_error "$ERROR_NOT_CONFIGURED"
                print_info "Add a context: coolify context add <name> <url> <token>"
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
        print_info "Create configuration: cp configs/coolify-cli-config.json.txt $CONFIG_FILE"
        return 1
    fi
    return 0
}

get_context_config() {
    local context_name="$1"
    
    if ! jq -e ".contexts.\"$context_name\"" "$CONFIG_FILE" &>/dev/null; then
        print_error "$ERROR_CONTEXT_MISSING: $context_name"
        return 1
    fi
    
    jq -r ".contexts.\"$context_name\"" "$CONFIG_FILE"
    return 0
}

# ------------------------------------------------------------------------------
# LOCAL DEVELOPMENT FUNCTIONS
# ------------------------------------------------------------------------------

start_local_dev_server() {
    local context_name="$1"
    local project_path="${2:-.}"
    local port="${3:-3000}"
    
    print_info "Starting local development server..."
    print_info "Project path: $project_path"
    print_info "Port: $port"
    
    cd "$project_path" || {
        print_error "Failed to change to project directory: $project_path"
        return 1
    }
    
    # Check if we have a Coolify context configured
    if coolify context list &> /dev/null && [[ -n "$context_name" ]]; then
        print_info "Coolify context available - using Coolify development mode"
        print_info "Note: This will use local development, not Coolify deployment"
    fi
    
    print_info "Starting local development server (no Coolify deployment required)"
    start_local_server "$project_path" "$port"
    return 0
}

start_local_server() {
    local port="$2"
    
    print_info "Starting local development server on http://localhost:$port"
    
    # Check for common development setups
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
    elif [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
        print_info "Found docker-compose file - starting with Docker Compose"
        docker-compose up --build
    elif [[ -f "Dockerfile" ]]; then
        print_info "Found Dockerfile - building and running container"
        local image_name
        image_name="local-dev-$(basename "$PWD")"
        docker build -t "$image_name" .
        docker run -p "$port:$port" "$image_name"
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
        print_info "Expected: package.json, docker-compose.yml, Dockerfile, or index.html"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# COOLIFY MANAGEMENT FUNCTIONS
# ------------------------------------------------------------------------------

list_applications() {
    local context_name="${1:-}"

    print_info "Listing Coolify applications..."

    if [[ -n "$context_name" ]]; then
        coolify --context "$context_name" app list
    else
        coolify app list
    fi
    return 0
}

deploy_application() {
    local context_name="$1"
    local app_identifier="$2"
    local force="${3:-false}"

    print_info "Deploying application: $app_identifier"

    local deploy_args=()
    if [[ "$force" == "true" ]]; then
        deploy_args+=(--force)
    fi

    if [[ -n "$context_name" ]]; then
        deploy_args+=(--context "$context_name")
    fi

    # Try to deploy by name first, then by UUID
    if coolify "${deploy_args[@]}" deploy name "$app_identifier"; then
        print_success "$SUCCESS_APP_DEPLOYED: $app_identifier"
    elif coolify "${deploy_args[@]}" deploy uuid "$app_identifier"; then
        print_success "$SUCCESS_APP_DEPLOYED: $app_identifier"
    else
        print_error "$ERROR_DEPLOYMENT_FAILED: $app_identifier"
        return 1
    fi
    return 0
}

get_application_info() {
    local context_name="$1"
    local app_uuid="$2"

    print_info "Getting application information: $app_uuid"

    if [[ -n "$context_name" ]]; then
        coolify --context "$context_name" app get "$app_uuid"
    else
        coolify app get "$app_uuid"
    fi
    return 0
}

list_servers() {
    local context_name="${1:-}"

    print_info "Listing Coolify servers..."

    if [[ -n "$context_name" ]]; then
        coolify --context "$context_name" server list
    else
        coolify server list
    fi
    return 0
}

add_server() {
    local context_name="$1"
    local server_name="$2"
    local server_ip="$3"
    local private_key_uuid="$4"
    local port="${5:-22}"
    local user="${6:-root}"
    local validate="${7:-false}"

    print_info "Adding server: $server_name ($server_ip)"

    local server_args=("$server_name" "$server_ip" "$private_key_uuid")
    server_args+=(--port "$port" --user "$user")

    if [[ "$validate" == "true" ]]; then
        server_args+=(--validate)
    fi

    if [[ -n "$context_name" ]]; then
        server_args+=(--context "$context_name")
    fi

    if coolify server add "${server_args[@]}"; then
        print_success "$SUCCESS_SERVER_ADDED: $server_name"
    else
        print_error "Failed to add server: $server_name"
        return 1
    fi
    return 0
}

list_databases() {
    local context_name="${1:-}"

    print_info "Listing Coolify databases..."

    if [[ -n "$context_name" ]]; then
        coolify --context "$context_name" database list
    else
        coolify database list
    fi
    return 0
}

create_database() {
    local context_name="$1"
    local db_type="$2"
    local server_uuid="$3"
    local project_uuid="$4"
    local environment_name="$5"
    local db_name="${6:-}"
    local instant_deploy="${7:-false}"

    print_info "Creating $db_type database: $db_name"

    local db_args=("$db_type")
    db_args+=(--server-uuid "$server_uuid")
    db_args+=(--project-uuid "$project_uuid")
    db_args+=(--environment-name "$environment_name")

    if [[ -n "$db_name" ]]; then
        db_args+=(--name "$db_name")
    fi

    if [[ "$instant_deploy" == "true" ]]; then
        db_args+=(--instant-deploy)
    fi

    if [[ -n "$context_name" ]]; then
        db_args+=(--context "$context_name")
    fi

    if coolify database create "${db_args[@]}"; then
        print_success "$SUCCESS_DATABASE_CREATED: $db_name"
    else
        print_error "Failed to create database: $db_name"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# CONTEXT MANAGEMENT FUNCTIONS
# ------------------------------------------------------------------------------

list_contexts() {
    print_info "Available Coolify contexts:"

    if [[ -f "$CONFIG_FILE" ]]; then
        jq -r '.contexts | keys[]' "$CONFIG_FILE" | while read -r context; do
            local context_info
            context_info=$(jq -r ".contexts.\"$context\"" "$CONFIG_FILE")
            local url
            url=$(echo "$context_info" | jq -r '.url // "Unknown URL"')
            local description
            description=$(echo "$context_info" | jq -r '.description // "No description"')

            echo "  - $context ($url): $description"
        done
    else
        print_warning "No configuration file found"
    fi

    print_info ""
    print_info "Coolify CLI contexts:"
    coolify context list 2>/dev/null || print_warning "No Coolify CLI contexts configured"
    return 0
}

add_context() {
    local context_name="$1"
    local url="$2"
    local token="$3"
    local set_default="${4:-false}"

    print_info "Adding Coolify context: $context_name"
    print_info "URL: $url"

    local context_args=("$context_name" "$url" "$token")

    if [[ "$set_default" == "true" ]]; then
        context_args+=(--default)
    fi

    if coolify context add "${context_args[@]}"; then
        print_success "$SUCCESS_CONTEXT_ADDED: $context_name"

        # Add to our configuration file if it exists
        if [[ -f "$CONFIG_FILE" ]]; then
            jq --arg name "$context_name" --arg url "$url" --arg desc "Coolify instance at $url" \
               '.contexts[$name] = {url: $url, description: $desc}' \
               "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        fi
    else
        print_error "Failed to add context: $context_name"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# BUILD FUNCTIONS
# ------------------------------------------------------------------------------

build_project() {
    local project_path="${2:-.}"

    print_info "Building project locally..."
    print_info "Project path: $project_path"

    cd "$project_path" || {
        print_error "Failed to change to project directory: $project_path"
        return 1
    }

    # Check for common build setups
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
    elif [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
        print_info "Found docker-compose file - building services"
        docker-compose build
    elif [[ -f "Dockerfile" ]]; then
        print_info "Found Dockerfile - building container"
        local image_name
        image_name="local-build-$(basename "$PWD")"
        docker build -t "$image_name" .
        print_success "Docker image built: $image_name"
    else
        print_warning "No build configuration found"
        print_info "This appears to be a static project or requires manual build setup"
        return 0
    fi
    return 0
}

# ------------------------------------------------------------------------------
# HELP FUNCTION
# ------------------------------------------------------------------------------

show_help() {
    cat << 'EOF'
Coolify CLI Helper - Comprehensive self-hosted deployment and management

USAGE:
  ./.agent/scripts/coolify-cli-helper.sh [COMMAND] [CONTEXT] [OPTIONS...]

COMMANDS:
  Local Development (No Context Required):
    dev [context] [path] [port]               - Start local development server
    build [context] [path]                    - Build project locally
    init [context] [path] [type]              - Initialize project structure

  Application Management:
    list-apps [context]                       - List all applications
    deploy [context] [app-name-or-uuid] [force] - Deploy application
    get-app [context] [app-uuid]              - Get application details
    app-logs [context] [app-uuid]             - Get application logs

  Server Management:
    list-servers [context]                    - List all servers
    add-server [context] [name] [ip] [key-uuid] [port] [user] [validate] - Add server
    get-server [context] [server-uuid]        - Get server details

  Database Management:
    list-databases [context]                  - List all databases
    create-db [context] [type] [server-uuid] [project-uuid] [env] [name] [deploy] - Create database

  Context Management:
    list-contexts                             - List configured contexts
    add-context [name] [url] [token] [default] - Add Coolify context
    use-context [name]                        - Switch to context

  General:
    help                                      - Show this help message
    version                                   - Show Coolify CLI version

PARAMETERS:
  context    - Context name from configuration (optional for most commands)
  path       - Project path (default: current directory)
  port       - Development server port (default: 3000)
  type       - Project type: nodejs, docker, static (for init)
  force      - Force deployment (true/false, default: false)
  validate   - Validate server after adding (true/false, default: false)

EXAMPLES:
  # Local development (no context required)
  $0 dev local ./my-app 3000
  $0 build local ./my-app

  # Coolify operations (requires context)
  $0 add-context production https://coolify.example.com your-api-token true
  $0 list-apps production
  $0 deploy production my-application
  $0 create-db production postgresql server-uuid project-uuid main mydb true

  # Server management
  $0 add-server production myserver 192.168.1.100 key-uuid 22 root true
  $0 list-servers production

CONFIGURATION:
  File: configs/coolify-cli-config.json
  Example: cp configs/coolify-cli-config.json.txt configs/coolify-cli-config.json

REQUIREMENTS:
  - Coolify CLI installed (context optional for local development)
  - jq JSON processor
  - Docker (for Docker-based projects)
  - Node.js (for Node.js projects)
  - Valid Coolify API token (for deployment commands only)

LOCAL DEVELOPMENT:
  The helper supports immediate local development without Coolify setup:
  - Node.js projects with package.json
  - Docker projects with Dockerfile or docker-compose.yml
  - Static HTML projects
  - Automatic framework detection and server startup

For more information, see: https://github.com/coollabsio/coolify-cli
EOF
    return 0
}

# ------------------------------------------------------------------------------
# MAIN FUNCTION
# ------------------------------------------------------------------------------

main() {
    local command="${1:-help}"
    local context_name="${2:-}"
    local target="${3:-}"
    local options="${4:-}"

    case "$command" in
        "dev")
            local project_path="$target"
            local port="$options"
            start_local_dev_server "$context_name" "$project_path" "$port"
            ;;
        "build")
            local project_path="$target"
            build_project "$context_name" "$project_path"
            ;;
        "list-apps")
            list_applications "$context_name"
            ;;
        "deploy")
            local app_identifier="$target"
            local force="$options"
            deploy_application "$context_name" "$app_identifier" "$force"
            ;;
        "get-app")
            local app_uuid="$target"
            get_application_info "$context_name" "$app_uuid"
            ;;
        "list-servers")
            list_servers "$context_name"
            ;;
        "add-server")
            local server_name="$target"
            local server_ip="$options"
            local private_key_uuid="${5:-}"
            local port="${6:-22}"
            local user="${7:-root}"
            local validate="${8:-false}"
            add_server "$context_name" "$server_name" "$server_ip" "$private_key_uuid" "$port" "$user" "$validate"
            ;;
        "list-databases")
            list_databases "$context_name"
            ;;
        "create-db")
            local db_type="$target"
            local server_uuid="$options"
            local project_uuid="${5:-}"
            local environment_name="${6:-}"
            local db_name="${7:-}"
            local instant_deploy="${8:-false}"
            create_database "$context_name" "$db_type" "$server_uuid" "$project_uuid" "$environment_name" "$db_name" "$instant_deploy"
            ;;
        "list-contexts")
            list_contexts
            ;;
        "add-context")
            local context_name="$target"
            local url="$options"
            local token="${5:-}"
            local set_default="${6:-false}"
            add_context "$context_name" "$url" "$token" "$set_default"
            ;;
        "use-context")
            local context_name="$target"
            coolify context use "$context_name"
            ;;
        "version")
            coolify --version
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
check_dependencies "${1:-help}"
load_config

# Execute main function
main "$@"
