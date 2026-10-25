#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Hostinger Helper Script
# Manages Hostinger shared hosting sites and API operations

# Source shared constants if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

# HTTP Constants
# Error message constants
readonly HELP_SHOW_MESSAGE="Show this help"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

# Configuration file (legacy site commands): resolved from the script location,
# not the caller's working directory.
CONFIG_FILE="${HOSTINGER_CONFIG_FILE:-$SCRIPT_DIR/../configs/hostinger-config.json}"

# Check if config file exists
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "$ERROR_CONFIG_NOT_FOUND: $CONFIG_FILE"
        print_info "Copy and customize: cp $SCRIPT_DIR/../configs/hostinger-config.json.txt $CONFIG_FILE"
        exit 1
    fi

    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        print_error "$ERROR_INVALID_JSON"
        exit 1
    fi

    return 0
}

# List all sites
list_sites() {
    check_config
    print_info "Available Hostinger sites:"
    
    sites=$(jq -r '.sites | keys[]' "$CONFIG_FILE")
    for site in $sites; do
        description=$(jq -r ".sites.$site.description" "$CONFIG_FILE")
        path=$(jq -r ".sites.$site.domain_path" "$CONFIG_FILE")
        echo "  - $site: $description ($path)"
    done

    return 0
}

# Connect to a specific site
connect_site() {
    local site="$1"
    check_config
    
    if [[ -z "$site" ]]; then
        print_error "Please specify a site name"
        list_sites
        exit 1
    fi
    
    # Get site configuration
    local server
    local port
    local username
    local password_file
    local ssh_identity_file
    local domain_path
    server=$(jq -r ".sites.$site.server" "$CONFIG_FILE")
    port=$(jq -r ".sites.$site.port" "$CONFIG_FILE")
    username=$(jq -r ".sites.$site.username" "$CONFIG_FILE")
    password_file=$(jq -r ".sites.$site.password_file // empty" "$CONFIG_FILE")
    ssh_identity_file=$(jq -r ".sites.$site.ssh_identity_file // empty" "$CONFIG_FILE")
    domain_path=$(jq -r ".sites.$site.domain_path" "$CONFIG_FILE")

    if [[ "$server" == "null" ]]; then
        print_error "Site not found: $site"
        list_sites
        exit 1
    fi

    print_info "Connecting to $site..."

    # Prefer SSH key auth if configured (Hostinger recommends it)
    if [[ -n "$ssh_identity_file" ]]; then
        local expanded_identity="${ssh_identity_file/#\~/$HOME}"
        ssh -i "$expanded_identity" -p "$port" "$username@$server" -t "cd $domain_path && bash" || exit
        return 0
    fi

    # Fallback: sshpass with password file (backward compatible)
    password_file="${password_file/\~/$HOME}"
    if [[ ! -f "$password_file" ]]; then
        print_error "Password file not found: $password_file"
        print_info "Create password file: echo 'your-password' > $password_file && chmod 600 $password_file"
        exit 1
    fi

    # Connect with sshpass
    sshpass -f "$password_file" ssh -p "$port" "$username@$server" -t "cd $domain_path && bash" || exit
    return 0
}

# Execute command on site
exec_on_site() {
    local site="$1"
    local command="$2"
    check_config
    
    if [[ -z "$site" || -z "$command" ]]; then
        print_error "Usage: exec [site] [command]"
        exit 1
    fi
    
    # Get site configuration
    local server
    local port
    local username
    local password_file
    local ssh_identity_file
    local domain_path
    server=$(jq -r ".sites.$site.server" "$CONFIG_FILE")
    port=$(jq -r ".sites.$site.port" "$CONFIG_FILE")
    username=$(jq -r ".sites.$site.username" "$CONFIG_FILE")
    password_file=$(jq -r ".sites.$site.password_file // empty" "$CONFIG_FILE")
    ssh_identity_file=$(jq -r ".sites.$site.ssh_identity_file // empty" "$CONFIG_FILE")
    domain_path=$(jq -r ".sites.$site.domain_path" "$CONFIG_FILE")

    if [[ "$server" == "null" ]]; then
        print_error "Site not found: $site"
        exit 1
    fi

    print_info "Executing '$command' on $site..."

    # Prefer SSH key auth if configured (Hostinger recommends it)
    if [[ -n "$ssh_identity_file" ]]; then
        local expanded_identity="${ssh_identity_file/#\~/$HOME}"
        ssh -i "$expanded_identity" -p "$port" "$username@$server" "cd $domain_path && $command" || exit
        return 0
    fi

    # Fallback: sshpass with password file (backward compatible)
    password_file="${password_file/\~/$HOME}"
    sshpass -f "$password_file" ssh -p "$port" "$username@$server" "cd $domain_path && $command" || exit
    return 0
}

# API operations: api [METHOD] ENDPOINT [JSON_BODY]
# The token comes from HOSTINGER_API_TOKEN, else the aidevops secret store
# (re-exec with injection, like fleet/cron), else the legacy config file.
# It is passed to curl on stdin, never on the command line.
api_call() {
    local first="${1:-}"
    local second="${2:-}"
    local third="${3:-}"
    local method="GET"
    local endpoint="$first"
    local body=""
    local api_token="${HOSTINGER_API_TOKEN:-}"
    local base_url="${HOSTINGER_API_BASE_URL:-https://developers.hostinger.com}"

    case "$first" in
    GET | POST | PUT | PATCH | DELETE)
        method="$first"
        endpoint="$second"
        body="$third"
        ;;
    esac
    if [[ -z "$endpoint" ]]; then
        print_error "Usage: api [GET|POST|PUT|PATCH|DELETE] ENDPOINT [JSON_BODY]"
        return 1
    fi

    if [[ -z "$api_token" && -z "${HOSTINGER_API_REEXEC:-}" ]] &&
        command -v aidevops >/dev/null 2>&1 &&
        aidevops secret check HOSTINGER_API_TOKEN >/dev/null 2>&1; then
        local status=0
        HOSTINGER_API_REEXEC=1 aidevops secret HOSTINGER_API_TOKEN -- \
            "$SCRIPT_DIR/hostinger-helper.sh" api "$method" "$endpoint" "$body" || status=$?
        return "$status"
    fi

    if [[ -z "$api_token" ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            print_error "Hostinger API token not found"
            print_info "Store it with: aidevops secret set HOSTINGER_API_TOKEN"
            return 1
        fi
        check_config
        api_token=$(jq -r '.api.token // empty' "$CONFIG_FILE")
        base_url=$(jq -r --arg d "$base_url" '.api.base_url // $d' "$CONFIG_FILE")
        if [[ -z "$api_token" || "$api_token" == "YOUR_HOSTINGER_API_TOKEN_HERE" ]]; then
            print_error "API token not configured"
            return 1
        fi
    fi

    endpoint="${endpoint#/}"
    local -a curl_args=(-sS -K - -X "$method" -H "Accept: application/json")
    if [[ -n "$body" ]]; then
        curl_args+=(-H "Content-Type: application/json" --data-binary "$body")
    fi
    printf 'header = "%s %s"\n' "$AUTH_HEADER_PREFIX" "$api_token" |
        curl "${curl_args[@]}" "${base_url%/}/$endpoint"
    return $?
}

# Read-only SSL status; resolve the hosting username without caller substitution.
ssl_status() {
    local domain="${1:-}"
    local encoded_domain
    local websites
    local username
    local encoded_username
    local response

    if [[ -z "$domain" || ! "$domain" =~ ^[[:alnum:]]([[:alnum:].-]*[[:alnum:]])?$ || "$domain" == *..* ]]; then
        print_error "Usage: ssl-status DOMAIN (hostname only)" >&2
        return 1
    fi

    encoded_domain=$(jq -rn --arg domain "$domain" '$domain | @uri') || return 1
    websites=$(api_call GET "api/hosting/v1/websites?domain=$encoded_domain") || return 1
    if ! username=$(printf '%s' "$websites" | jq -er '.data[0].username | select(type == "string" and length > 0)'); then
        print_error "Could not resolve hosting username for: $domain" >&2
        return 1
    fi
    encoded_username=$(jq -rn --arg username "$username" '$username | @uri') || return 1
    response=$(api_call GET "api/hosting/v1/accounts/$encoded_username/websites/$encoded_domain/ssl/status") || return 1
    printf '%s\n' "$response" | jq -e . || return 1
    return 0
}

# Read-only fleet inventory, onboarding plan and drift check (hosting_fleet.py).
# Module names avoid the credential ignore pattern 'hostinger_*' in .gitignore.
fleet_command() {
    local subcommand="${1:-help}"
    local engine="${SCRIPT_DIR}/hosting_fleet.py"
    local discovery_lib="${SCRIPT_DIR}/aidevops-cli/repo-discovery-lib.sh"
    local status=0
    local argument=""
    local offline=0

    case "$subcommand" in
    inventory)
        shift
        for argument in "$@"; do
            [[ "$argument" == "--api-response" ]] && offline=1
        done
        # Inject the token from the secret store without exposing it.
        if [[ "$offline" -eq 0 && -z "${HOSTINGER_API_TOKEN:-}" ]] &&
            command -v aidevops >/dev/null 2>&1 &&
            aidevops secret check HOSTINGER_API_TOKEN >/dev/null 2>&1; then
            aidevops secret HOSTINGER_API_TOKEN -- python3 "$engine" inventory "$@" || status=$?
            return "$status"
        fi
        python3 "$engine" inventory "$@" || status=$?
        return "$status"
        ;;
    plan | drift | ready | move)
        shift
        python3 "$engine" "$subcommand" --discovery-lib "$discovery_lib" "$@" || status=$?
        return "$status"
        ;;
    privacy-sync | provision)
        shift
        python3 "$engine" "$subcommand" "$@" || status=$?
        return "$status"
        ;;
    help | -h | --help)
        echo "Usage: $0 fleet <inventory|plan|drift|ready|provision|move|privacy-sync> [options]"
        echo ""
        echo "  inventory [--username U] [--discover-networks --ssh ALIAS] [--network-map FILE]"
        echo "      GET-only website inventory; groups shared roots; optional read-only"
        echo "      SSH 'wp site list' adds multisite blogs that have no panel entry"
        echo "  plan  [--owner ORG] [--owner-exception DOMAIN=OWNER]... [--site-repo HOST=REPO]..."
        echo "        [--ignore DOMAIN]... [--config FILE]"
        echo "      Write a content-hashed onboarding plan (no mutations)"
        echo "  drift [plan options] [--json] [--fail-on-drift]"
        echo "      Compare hosting, repos.json and canonical layout (exit 3 on drift)"
        echo "  ready [plan options] [--worker-evidence] [--json] [--fail-on-not-ready]"
        echo "      Read-only configured readiness per repo: private remote, owner, push,"
        echo "      default-branch heads, effective project config, Pulse/maintenance,"
        echo "      gh auth; writes a private receipt (exit 4 if not all ready)"
        echo "  provision [--plan FILE] [--site DOMAIN]... [--apply --plan-sha256 HASH]"
        echo "      Preview (default) or apply the saved plan: create/adopt private repo,"
        echo "      clone, native init, push + issue + PR (never merges); resumable,"
        echo "      append-only private receipt (exit 5 if any repository failed)"
        echo "  move --site DOMAIN... [plan options] [--apply --confirm HASH]"
        echo "      Preview named misplaced sites (read-only). Apply: snapshot maintenance/"
        echo "      Pulse, pause, scoped native migrate-layout plan + apply, restore both"
        echo "      by slug; partial moves stay paused (exit 6 on failure)"
        echo "  move --restore SNAPSHOT"
        echo "      Restore a paused move once every repository moved (or none did)"
        echo "  privacy-sync [--inventory FILE] [--config FILE]"
        echo "      Offline sync to the local private entity guard (counts only)"
        echo "      Also runs automatically after inventory"
        echo ""
        echo "Fleet config (optional, 0600): ~/.config/aidevops/hosting-fleet.json"
        echo "  {\"owner\": ORG, \"owner_exceptions\": {DOMAIN: OWNER},"
        echo "   \"site_repos\": {HOST: REPO}, \"ignore\": [DOMAIN]}  -- flags add to it"
        echo "Private output: ~/.aidevops/.agent-workspace/work/hostinger-fleet/"
        echo "Details: services/hosting/hostinger.md 'Fleet inventory and drift'"
        return 0
        ;;
    *)
        print_error "Unknown fleet command: $subcommand"
        return 1
        ;;
    esac
}

# hPanel cron jobs via the Hostinger API (hosting_cron.py). SSH has no crontab on
# shared hosting, so this is the supported way to inspect and change jobs.
cron_command() {
    local subcommand="${1:-help}"
    local engine="${SCRIPT_DIR}/hosting_cron.py"
    local status=0

    case "$subcommand" in
    list | create | delete | output)
        if [[ -z "${HOSTINGER_API_TOKEN:-}" ]] &&
            command -v aidevops >/dev/null 2>&1 &&
            aidevops secret check HOSTINGER_API_TOKEN >/dev/null 2>&1; then
            aidevops secret HOSTINGER_API_TOKEN -- python3 "$engine" "$@" || status=$?
            return "$status"
        fi
        python3 "$engine" "$@" || status=$?
        return "$status"
        ;;
    help | -h | --help)
        echo "Usage: $0 cron <list|create|delete|output> --ssh ALIAS [options]"
        echo ""
        echo "  list   --ssh ALIAS [--json]"
        echo "  create --ssh ALIAS --time 'CRON' --command 'CMD' [--apply]"
        echo "  delete --ssh ALIAS --uid UID [--apply]"
        echo "  output --ssh ALIAS --uid UID"
        echo ""
        echo "create/delete preview unless --apply is given. Each change snapshots the"
        echo "job list (0600) to ~/.aidevops/.agent-workspace/work/hostinger-cron/ and"
        echo "prints the list afterwards. A failed change lists live jobs; never retry blindly."
        echo "Details: services/hosting/hostinger-wordpress-cron.md"
        return 0
        ;;
    *)
        print_error "Unknown cron command: $subcommand"
        return 1
        ;;
    esac
}

# Main function
main() {
    # Assign positional parameters to local variables
    local command="${1:-help}"
    local param2="${2:-}"
    local param3="${3:-}"

    # Main command handler
    case "$command" in
    "list")
        list_sites
        ;;
    "connect")
        if [[ -z "$param2" ]]; then
            print_error "Usage: connect [site]"
            return 1
        fi
        connect_site "$param2"
        ;;
    "exec")
        if [[ -z "$param2" || -z "$param3" ]]; then
            print_error "Usage: exec [site] [command]"
            return 1
        fi
        exec_on_site "$param2" "$param3"
        ;;
    "api")
        shift
        api_call "$@"
        return $?
        ;;
    "ssl-status")
        ssl_status "$param2"
        return $?
        ;;
    "fleet")
        shift
        fleet_command "$@"
        return $?
        ;;
    "cron")
        shift
        cron_command "$@"
        return $?
        ;;
    "help"|"-h"|"--help"|"")
        echo "Hostinger Helper Script"
        echo "Usage: $0 [command] [options]"
        echo ""
        echo "Commands:"
        echo "  list              - List all configured sites"
        echo "  connect [site]    - Connect to site directory via SSH"
        echo "  exec [site] [cmd] - Execute command on site"
        echo "  api [METHOD] ENDPOINT [JSON] - Hostinger API call (token from secret store)"
        echo "  ssl-status DOMAIN - Read-only SSL status (resolves hosting username)"
        echo "  fleet [cmd]       - Read-only fleet inventory, plan and drift ('fleet help')"
        echo "  cron [cmd]        - hPanel cron list/create/delete/output via API ('cron help')"
        echo "  help                 - $HELP_SHOW_MESSAGE"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 connect example.com"
        echo "  $0 exec example.com 'ls -la'"
        echo "  $0 api api/hosting/v1/websites"
        echo "  $0 api PATCH api/hosting/v1/accounts/USER/websites/DOMAIN/php/version '{\"version\":\"8.5\"}'"
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
