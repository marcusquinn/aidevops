#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2029,SC2129
set -euo pipefail

# Hetzner Helper Script  
# Manages Hetzner Cloud VPS servers across multiple projects

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# String literal constants
readonly ERROR_SERVER_NAME_REQUIRED="Server name is required"
readonly ERROR_INVALID_JSON="Invalid JSON in configuration file"


# Common message constants
readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 [command] [options]"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

# Common constants
readonly AUTH_BEARER_PREFIX="Authorization: Bearer"
readonly HETZNER_API_SERVERS="https://api.hetzner.cloud/v1/servers"

# Configuration file
CONFIG_FILE="../configs/hetzner-config.json"

# Check if config file exists
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "$ERROR_CONFIG_NOT_FOUND"
        print_info "Copy and customize: cp ../configs/hetzner-config.json.txt $CONFIG_FILE"
        exit 1
    fi

    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        print_error "$ERROR_INVALID_JSON"
        exit 1
    fi

    return 0
}

# List all servers from all projects
list_servers() {
    check_config
    print_info "Fetching servers from all Hetzner projects..."
    
    projects=$(jq -r '.projects | keys[]' "$CONFIG_FILE")
    
    for project in $projects; do
        api_token=$(jq -r ".projects.$project.api_token" "$CONFIG_FILE")
        description=$(jq -r ".projects.$project.description" "$CONFIG_FILE")
        account=$(jq -r ".projects.$project.account" "$CONFIG_FILE")
        
        print_info "Project: $project ($description)"
        print_info "Account: $account"
        
        servers=$(curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
                      "$HETZNER_API_SERVERS" | \
                  jq -r '.servers[]? | "  - \(.name) (\(.public_net.ipv4.ip)) - \(.server_type.name) - \(.status)"')
        
        if [[ -n "$servers" ]]; then
            echo "$servers"
        else
            echo "  - No servers found"
        fi
        
        echo ""
    done

    return 0
}

# Connect to a specific server
connect_server() {
    local server_name="$1"
    check_config
    
    if [[ -z "$server_name" ]]; then
        print_error "$ERROR_SERVER_NAME_REQUIRED"
        list_servers
        exit 1
    fi
    
    # Find server across all projects
    local server_info
    server_info=$(get_server_details "$server_name")
    if [[ -z "$server_info" ]]; then
        print_error "Server not found: $server_name"
        exit 1
    fi
    
    local ip name project
    read -r ip name project <<< "$server_info"
    print_info "Connecting to $name ($ip) in project $project..."
    ssh "root@$ip"
    return 0
}

# Execute command on server
exec_on_server() {
    local server_name="$1"
    local command="$2"
    check_config
    
    if [[ -z "$server_name" || -z "$command" ]]; then
        print_error "Usage: exec [server] [command]"
        exit 1
    fi
    
    local server_info
    server_info=$(get_server_details "$server_name")
    if [[ -z "$server_info" ]]; then
        print_error "Server not found: $server_name"
        exit 1
    fi
    
    local ip
    read -r ip _ _ <<< "$server_info"
    print_info "Executing '$command' on $server_name..."
    ssh "root@$ip" "$command"
    return 0
}

# Get server details by name
get_server_details() {
    local server_name="$1"
    check_config
    
    projects=$(jq -r '.projects | keys[]' "$CONFIG_FILE")
    
    for project in $projects; do
        api_token=$(jq -r ".projects.$project.api_token" "$CONFIG_FILE")
        
        server_info=$(curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
                          "$HETZNER_API_SERVERS" | \
                      jq -r ".servers[]? | select(.name == \"$server_name\") | \"\(.public_net.ipv4.ip) \(.name) $project\"")
        
        if [[ -n "$server_info" ]]; then
            echo "$server_info"
            return 0
        fi
    done
    
    return 1
}

# Generate SSH configurations
generate_ssh_configs() {
    check_config
    print_info "Generating SSH configurations for all servers..."
    
    projects=$(jq -r '.projects | keys[]' "$CONFIG_FILE")
    
    echo "# Hetzner servers SSH configuration" > ~/.ssh/hetzner_config
    echo "# Generated on $(date)" >> ~/.ssh/hetzner_config
    
    for project in $projects; do
        api_token=$(jq -r ".projects.$project.api_token" "$CONFIG_FILE")
        description=$(jq -r ".projects.$project.description" "$CONFIG_FILE")
        
        print_info "Processing project: $project ($description)"
        
        servers=$(curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
                      "$HETZNER_API_SERVERS" | \
                  jq -r '.servers[]? | "\(.name) \(.public_net.ipv4.ip)"')
        
        if [[ -n "$servers" ]]; then
            echo "" >> ~/.ssh/hetzner_config
            echo "# Project: $project ($description)" >> ~/.ssh/hetzner_config
            
            while IFS=' ' read -r name ip; do
                if [[ -n "$name" && -n "$ip" && "$name" != "null" && "$ip" != "null" ]]; then
                    echo "" >> ~/.ssh/hetzner_config
                    echo "Host $name" >> ~/.ssh/hetzner_config
                    echo "    HostName $ip" >> ~/.ssh/hetzner_config
                    echo "    User root" >> ~/.ssh/hetzner_config
                    echo "    IdentityFile ~/.ssh/id_ed25519" >> ~/.ssh/hetzner_config
                    echo "    AddKeysToAgent yes" >> ~/.ssh/hetzner_config
                    echo "    UseKeychain yes" >> ~/.ssh/hetzner_config
                    echo "    # Project: $project" >> ~/.ssh/hetzner_config
                    print_success "Added SSH config for $name ($ip)"
                fi
            done <<< "$servers"
        fi
    done
    
    print_success "SSH configurations generated in ~/.ssh/hetzner_config"
    print_info "Add 'Include ~/.ssh/hetzner_config' to your ~/.ssh/config"
    return 0
}

# Create a new VPS
create_server() {
    local project_name="$1"
    local server_name="$2"
    local server_type="${3:-cx22}"
    local location="${4:-nbg1}"
    local image="${5:-ubuntu-24.04}"

    check_config

    if [[ -z "$project_name" || -z "$server_name" ]]; then
        print_error "Usage: create [project] [server_name] [server_type] [location] [image]"
        print_info "Available projects:"
        jq -r '.accounts | keys[]' "$CONFIG_FILE" | sed 's/^/  - /'
        exit 1
    fi

    # Get API token for project
    local api_token
    api_token=$(jq -r ".accounts.\"$project_name\".api_token" "$CONFIG_FILE")
    if [[ "$api_token" == "null" || -z "$api_token" ]]; then
        print_error "Project '$project_name' not found in configuration"
        exit 1
    fi

    print_info "Creating VPS with specifications:"
    echo "  Project: $project_name"
    echo "  Name: $server_name"
    echo "  Type: $server_type"
    echo "  Location: $location"
    echo "  Image: $image"
    echo ""

    # Create the server
    local response
    response=$(curl -s -X POST \
        -H "$AUTH_BEARER_PREFIX $api_token" \
        -H "$CONTENT_TYPE_JSON" \
        -d "{
            \"name\": \"$server_name\",
            \"server_type\": \"$server_type\",
            \"location\": \"$location\",
            \"image\": \"$image\",
            \"start_after_create\": true
        }" \
        "$HETZNER_API_SERVERS")

    # Check if creation was successful
    if echo "$response" | jq -e '.server' > /dev/null; then
        local server_id
        local server_ip
        local root_password
        server_id=$(echo "$response" | jq -r '.server.id')
        server_ip=$(echo "$response" | jq -r '.server.public_net.ipv4.ip // "pending"')
        root_password=$(echo "$response" | jq -r '.root_password // "not_provided"')

        print_success "VPS created successfully!"
        echo "  Server ID: $server_id"
        echo "  Server Name: $server_name"
        echo "  IP Address: $server_ip"
        echo "  Root Password: $root_password"
        echo ""
        print_info "The server is being initialized. This may take a few minutes."
        print_info "Check status with: $0 status $server_name"

    else
        print_error "Failed to create VPS"
        echo "Response: $response"
        exit 1
    fi

    return 0
}

# Check server status
check_server_status() {
    local server_name="$1"
    check_config

    if [[ -z "$server_name" ]]; then
        print_error "Server name is required"
        exit 1
    fi

    # Find server across all projects
    local found=false
    local projects
    projects=$(jq -r '.accounts | keys[]' "$CONFIG_FILE")

    for project in $projects; do
        local api_token
        api_token=$(jq -r ".accounts.\"$project\".api_token" "$CONFIG_FILE")

        local response
        response=$(curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
                       "$HETZNER_API_SERVERS")

        local server_info
        server_info=$(echo "$response" | jq -r ".servers[] | select(.name == \"$server_name\")")

        if [[ -n "$server_info" ]]; then
            local status
            local ip
            local server_type
            status=$(echo "$server_info" | jq -r '.status')
            ip=$(echo "$server_info" | jq -r '.public_net.ipv4.ip')
            server_type=$(echo "$server_info" | jq -r '.server_type.name')

            print_info "Server: $server_name (Project: $project)"
            echo "  Status: $status"
            echo "  IP: $ip"
            echo "  Type: $server_type"
            found=true
            break
        fi
    done

    if [[ "$found" == false ]]; then
        print_error "Server '$server_name' not found"
        exit 1
    fi

    return 0
}

# List available server types
list_server_types() {
    local project_name="${1:-main}"
    check_config

    local api_token
    api_token=$(jq -r ".accounts.\"$project_name\".api_token" "$CONFIG_FILE")
    if [[ "$api_token" == "null" || -z "$api_token" ]]; then
        print_error "Project '$project_name' not found in configuration"
        exit 1
    fi

    print_info "Available server types:"
    curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
         "https://api.hetzner.cloud/v1/server_types" | \
    jq -r '.server_types[] | "  \(.name) - \(.cores) cores, \(.memory)GB RAM, \(.disk)GB disk - €\(.prices[0].price_monthly.gross)/month"'

    return 0
}

# List available locations
list_locations() {
    local project_name="${1:-main}"
    check_config

    local api_token
    api_token=$(jq -r ".accounts.\"$project_name\".api_token" "$CONFIG_FILE")
    if [[ "$api_token" == "null" || -z "$api_token" ]]; then
        print_error "Project '$project_name' not found in configuration"
        exit 1
    fi

    print_info "Available locations:"
    curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
         "https://api.hetzner.cloud/v1/locations" | \
    jq -r '.locations[] | "  \(.name) - \(.description) (\(.country))"'

    return 0
}

# List available images
list_images() {
    local project_name="${1:-main}"
    check_config

    local api_token
    api_token=$(jq -r ".accounts.\"$project_name\".api_token" "$CONFIG_FILE")
    if [[ "$api_token" == "null" || -z "$api_token" ]]; then
        print_error "Project '$project_name' not found in configuration"
        exit 1
    fi

    print_info "Available images (OS):"
    curl -s -H "$AUTH_BEARER_PREFIX $api_token" \
         "https://api.hetzner.cloud/v1/images?type=system" | \
    jq -r '.images[] | select(.status == "available") | "  \(.name) - \(.description)"'

    return 0
}

# Resolve the credentials.sh path (never sourced; parsed as data)
hz_credentials_file() {
    printf '%s' "${AIDEVOPS_CREDENTIALS_FILE:-$HOME/.config/aidevops/credentials.sh}"
    return 0
}

# Read NAME from credentials.sh without sourcing it. Prints value or nothing.
hz_read_credentials_value() {
    local name="$1"
    local file
    file="$(hz_credentials_file)"
    [[ -r "$file" ]] || return 0
    local line
    line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${name}=" "$file" | tail -n 1) || true
    [[ -n "$line" ]] || return 0
    local value="${line#*=}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s' "$value"
    return 0
}

# Resolve an API token for a project. Order: JSON config, then
# HCLOUD_TOKEN_<PROJECT_UPPER> from env, credentials.sh, `aidevops secret get`.
# The token is returned on stdout only for internal capture; never printed to users.
hz_resolve_token() {
    local project="$1"
    local token=""
    if [[ -f "$CONFIG_FILE" ]] && jq empty "$CONFIG_FILE" 2>/dev/null; then
        token=$(jq -r --arg p "$project" '(.projects[$p].api_token // .accounts[$p].api_token // empty)' "$CONFIG_FILE" 2>/dev/null) || token=""
    fi
    if [[ -z "$token" || "$token" == "null" ]]; then
        local key
        key="HCLOUD_TOKEN_$(printf '%s' "$project" | tr '[:lower:]-' '[:upper:]_')"
        token="${!key:-}"
        if [[ -z "$token" ]]; then
            token=$(hz_read_credentials_value "$key")
        fi
        if [[ -z "$token" ]] && command -v aidevops >/dev/null 2>&1; then
            token=$(aidevops secret get "$key" </dev/null 2>/dev/null) || token=""
        fi
    fi
    if [[ -z "$token" || "$token" == "null" ]]; then
        return 1
    fi
    printf '%s' "$token"
    return 0
}

# Authenticated API call; token is passed via curl config on stdin so it never
# appears in the process list or output. Usage: hz_api <project> <method> <url> [json-body]
hz_api() {
    local project="$1"
    local method="$2"
    local url="$3"
    local body="${4:-}"
    local token
    if ! token=$(hz_resolve_token "$project"); then
        print_error "No token for project '$project' (config api_token or HCLOUD_TOKEN_$(printf '%s' "$project" | tr '[:lower:]-' '[:upper:]_'))"
        return 1
    fi
    local args=(-sS --fail-with-body -X "$method" -K - -H "Content-Type: application/json")
    if [[ -n "$body" ]]; then
        args+=(-d "$body")
    fi
    printf 'header = "%s %s"\n' "$AUTH_BEARER_PREFIX" "$token" | curl "${args[@]}" "$url"
    return $?
}

# Create a snapshot: snapshot-create <project> <server> <description> [label=value]
snapshot_create() {
    local project="${1:-}"
    local server="${2:-}"
    local description="${3:-}"
    local label="${4:-}"
    if [[ -z "$project" || -z "$server" || -z "$description" ]]; then
        print_error "Usage: snapshot-create <project> <server> <description> [label=value]"
        return 1
    fi
    local server_id
    server_id=$(hz_server_id "$project" "$server") || return 1
    local body
    if [[ -n "$label" ]]; then
        if [[ "$label" != *=* ]]; then
            print_error "Label must be key=value"
            return 1
        fi
        body=$(jq -nc --arg d "$description" --arg k "${label%%=*}" --arg v "${label#*=}" \
            '{type:"snapshot",description:$d,labels:{($k):$v}}')
    else
        body=$(jq -nc --arg d "$description" '{type:"snapshot",description:$d}')
    fi
    hz_api "$project" POST "$HETZNER_API_SERVERS/$server_id/actions/create_image" "$body" |
        jq -r '"Image: \(.image.id // "?")  Action: \(.action.id // "?")  Status: \(.action.status // "?")"'
    return "${PIPESTATUS[0]}"
}

# Resolve a server name or numeric ID to an ID
hz_server_id() {
    local project="$1"
    local server="$2"
    if [[ "$server" =~ ^[0-9]+$ ]]; then
        printf '%s' "$server"
        return 0
    fi
    local id
    id=$(hz_api "$project" GET "$HETZNER_API_SERVERS?name=$server" | jq -r '.servers[0].id // empty') || return 1
    if [[ -z "$id" ]]; then
        print_error "Server '$server' not found in project '$project'"
        return 1
    fi
    printf '%s' "$id"
    return 0
}

# List snapshots: snapshot-list <project> [label-selector]
snapshot_list() {
    local project="${1:-}"
    local selector="${2:-}"
    if [[ -z "$project" ]]; then
        print_error "Usage: snapshot-list <project> [label-selector]"
        return 1
    fi
    local url="https://api.hetzner.cloud/v1/images?type=snapshot"
    if [[ -n "$selector" ]]; then
        url="$url&label_selector=$(jq -rn --arg s "$selector" '$s|@uri')"
    fi
    hz_api "$project" GET "$url" |
        jq -r '.images[]? | "\(.id)\t\(.status)\t\(.created)\t\(.description // "")"'
    return "${PIPESTATUS[0]}"
}

# Delete snapshot: snapshot-delete <project> <image-id> --confirm
snapshot_delete() {
    local project="${1:-}"
    local image_id="${2:-}"
    local confirm="${3:-}"
    if [[ -z "$project" || -z "$image_id" ]]; then
        print_error "Usage: snapshot-delete <project> <image-id> --confirm"
        return 1
    fi
    if [[ ! "$image_id" =~ ^[0-9]+$ ]]; then
        print_error "Image ID must be numeric"
        return 1
    fi
    if [[ "$confirm" != "--confirm" ]]; then
        print_error "Destructive: re-run with --confirm to delete image $image_id"
        return 1
    fi
    hz_api "$project" DELETE "https://api.hetzner.cloud/v1/images/$image_id" >/dev/null || return 1
    print_info "Deleted image $image_id"
    return 0
}

# Action status: action-status <project> <action-id>
action_status() {
    local project="${1:-}"
    local action_id="${2:-}"
    if [[ -z "$project" || ! "$action_id" =~ ^[0-9]+$ ]]; then
        print_error "Usage: action-status <project> <action-id>"
        return 1
    fi
    hz_api "$project" GET "https://api.hetzner.cloud/v1/actions/$action_id" |
        jq -r '.action | "\(.id)\t\(.command)\t\(.status)\t\(.progress)%\t\(.error.message // "")"'
    return "${PIPESTATUS[0]}"
}

# Metrics: metrics <project> <server> [minutes=30]
server_metrics() {
    local project="${1:-}"
    local server="${2:-}"
    local minutes="${3:-30}"
    if [[ -z "$project" || -z "$server" || ! "$minutes" =~ ^[0-9]+$ ]]; then
        print_error "Usage: metrics <project> <server> [minutes]"
        return 1
    fi
    local server_id
    server_id=$(hz_server_id "$project" "$server") || return 1
    local end start
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    start=$(date -u -d "-${minutes} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"${minutes}"M +%Y-%m-%dT%H:%M:%SZ)
    hz_api "$project" GET "$HETZNER_API_SERVERS/$server_id/metrics?type=cpu,disk&start=$start&end=$end&step=60" |
        jq -r '.metrics.time_series | to_entries[] | .key as $k | "\($k): last=\(.value.values[-1][1] // "n/a") max=\([.value.values[][1] | tonumber] | max)"'
    return "${PIPESTATUS[0]}"
}

# Network info: server-net <project> <server>
server_net() {
    local project="${1:-}"
    local server="${2:-}"
    if [[ -z "$project" || -z "$server" ]]; then
        print_error "Usage: server-net <project> <server>"
        return 1
    fi
    local server_id
    server_id=$(hz_server_id "$project" "$server") || return 1
    hz_api "$project" GET "$HETZNER_API_SERVERS/$server_id" |
        jq -r '.server.public_net | "ipv4: \(.ipv4.ip // "none")\nipv6: \(.ipv6.ip // "none")"'
    return "${PIPESTATUS[0]}"
}

# Main function
main() {
    # Assign positional parameters to local variables
    local command="${1:-help}"
    local param2="${2:-}"
    local param3="${3:-}"
    local param4="${4:-}"
    local param5="${5:-}"
    local param6="${6:-}"

    # Main command handler
    case "$command" in
    "list")
        list_servers
        ;;
    "create")
        create_server "$param2" "$param3" "$param4" "$param5" "$param6"
        ;;
    "status")
        check_server_status "$param2"
        ;;
    "connect")
        connect_server "$param2"
        ;;
    "exec")
        exec_on_server "$param2" "$param3"
        ;;
    "list-types")
        list_server_types "$param2"
        ;;
    "list-locations")
        list_locations "$param2"
        ;;
    "list-images")
        list_images "$param2"
        ;;
    "generate-ssh-configs")
        generate_ssh_configs
        ;;
    "snapshot-create")
        snapshot_create "$param2" "$param3" "$param4" "$param5"
        ;;
    "snapshot-list")
        snapshot_list "$param2" "$param3"
        ;;
    "snapshot-delete")
        snapshot_delete "$param2" "$param3" "$param4"
        ;;
    "action-status")
        action_status "$param2" "$param3"
        ;;
    "metrics")
        server_metrics "$param2" "$param3" "$param4"
        ;;
    "server-net")
        server_net "$param2" "$param3"
        ;;
    "help"|"-h"|"--help"|"")
        echo "Hetzner Helper Script"
        echo "$USAGE_COMMAND_OPTIONS"
        echo ""
        echo "Commands:"
        echo "  list                              - List all servers across projects"
        echo "  create [project] [name] [type] [location] [image] - Create new VPS"
        echo "  status [server]                   - Check server status"
        echo "  connect [server]                  - Connect to server via SSH"
        echo "  exec [server] [command]           - Execute command on server"
        echo "  list-types [project]              - List available server types"
        echo "  list-locations [project]          - List available locations"
        echo "  list-images [project]             - List available OS images"
        echo "  generate-ssh-configs              - Generate SSH configurations"
        echo "  snapshot-create <proj> <srv> <desc> [k=v] - Create snapshot"
        echo "  snapshot-list <proj> [label-selector]     - List snapshots"
        echo "  snapshot-delete <proj> <image-id> --confirm - Delete snapshot"
        echo "  action-status <proj> <action-id>  - Show action status"
        echo "  metrics <proj> <srv> [minutes]    - CPU/disk metrics (default 30)"
        echo "  server-net <proj> <srv>           - Show public IPv4/IPv6"
        echo "  (tokens: config api_token, else HCLOUD_TOKEN_<PROJECT> env/credentials.sh/aidevops secret)"
        echo "  help                              - $HELP_SHOW_MESSAGE"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 create main my-server cx22 nbg1 ubuntu-24.04"
        echo "  $0 status my-server"
        echo "  $0 connect web-server-01"
        echo "  $0 exec web-server-01 'uptime'"
        echo "  $0 list-types main"
        echo "  $0 generate-ssh-configs"
        echo ""
        echo "Defaults for create command:"
        echo "  Server Type: cx22 (2 cores, 4GB RAM, 40GB disk)"
        echo "  Location: nbg1 (Nuremberg, Germany)"
        echo "  Image: ubuntu-24.04 (Ubuntu 24.04 LTS)"
        ;;
    *)
        print_error "$ERROR_UNKNOWN_COMMAND $command"
        print_info "$HELP_USAGE_INFO"
        exit 1
        ;;
esac
return 0
}

# Run main function
main "$@"
