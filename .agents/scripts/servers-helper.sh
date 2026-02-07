#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153
set -euo pipefail

# Global Servers Helper Script
# Unified access to all servers across all providers
# For detailed provider-specific operations, use individual helper scripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Get server configuration (hostname, port, auth method)
get_server_config() {
    local server="$1"
    
    case "$server" in
        # Add your servers here - customize for your infrastructure
        "production-web")
            echo "production-web.example.com 22 ssh"
            ;;
        "staging-web")
            echo "staging-web.example.com 22 ssh"
            ;;
        "development")
            echo "dev.example.com 22 ssh"
            ;;
        "hostinger")
            echo "hostinger-helper none hostinger"
            ;;
        "hetzner")
            echo "hetzner-helper none hetzner"
            ;;
        "closte")
            echo "closte-helper none closte"
            ;;
        "cloudron")
            echo "cloudron-helper none cloudron"
            ;;
        "coolify")
            echo "coolify-helper none coolify"
            ;;
        "dns")
            echo "dns-helper none dns"
            ;;
        "localhost")
            echo "localhost-helper none localhost"
            ;;
        "aws")
            echo "aws-helper none aws"
            ;;
        "github")
            echo "github-cli-helper none github"
            ;;
        "gitlab")
            echo "gitlab-cli-helper none gitlab"
            ;;
        "gitea")
            echo "gitea-cli-helper none gitea"
            ;;
        *)
            echo ""
            ;;
    esac
    return 0
}

# List all available servers
list_servers() {
    echo "Available servers:"
    echo "  - production-web (production-web.example.com) - Production web server"
    echo "  - staging-web (staging-web.example.com) - Staging web server"
    echo "  - development (dev.example.com) - Development server"
    echo "  - hostinger (multiple sites) - Hostinger shared hosting"
    echo "  - hetzner (multiple servers) - Hetzner Cloud VPS servers"
    echo "  - closte (multiple servers) - Closte.com VPS servers"
    echo "  - cloudron (multiple servers) - Cloudron server management"
    echo "  - coolify (multiple servers) - Coolify self-hosted deployment platform"
    echo "  - dns (multiple providers) - DNS management across providers"
    echo "  - localhost (local development) - Local Docker apps with .local domains"
    echo "  - aws (multiple instances) - AWS EC2 instances"
    echo "  - github (multiple repositories) - GitHub CLI management"
    echo "  - gitlab (multiple projects) - GitLab CLI management"
    echo "  - gitea (multiple repositories) - Gitea CLI management"
    return 0
}

# Main command handler
if [[ $# -eq 0 ]]; then
    server=""
    command="help"
elif [[ $# -eq 1 ]]; then
    if [[ "$1" == "list" ]]; then
        list_servers
        exit 0
    else
        server="$1"
        command="connect"
    fi
else
    server="$1"
    command="$2"
    shift 2
    args="$*"
fi

# Get server configuration
config=$(get_server_config "$server")
if [[ -z "$config" ]]; then
    print_error "Unknown server: $server"
    echo ""
    list_servers
    exit 1
fi

read -r host port auth_type <<< "$config"

# Handle different server types
case "$server" in
    "hostinger"|"hetzner"|"closte"|"cloudron"|"dns"|"localhost"|"aws")
        case "$command" in
            "connect"|"ssh"|"")
                if [[ "$auth_type" == "hostinger" ]]; then
                    print_info "Use Hostinger helper for site management..."
                    ./.agents/scripts/hostinger-helper.sh list
                elif [[ "$auth_type" == "hetzner" ]]; then
                    print_info "Use Hetzner helper for server management..."
                    ./.agents/scripts/hetzner-helper.sh list
                elif [[ "$auth_type" == "closte" ]]; then
                    print_info "Use Closte helper for server management..."
                    ./.agents/scripts/closte-helper.sh list
                elif [[ "$auth_type" == "cloudron" ]]; then
                    print_info "Use Cloudron helper for server management..."
                    ./.agents/scripts/cloudron-helper.sh list
                elif [[ "$auth_type" == "dns" ]]; then
                    print_info "Use DNS helper for domain management..."
                    ./.agents/scripts/dns-helper.sh list
                elif [[ "$auth_type" == "localhost" ]]; then
                    print_info "Use Localhost helper for local development..."
                    ./.agents/scripts/localhost-helper.sh list
                elif [[ "$auth_type" == "aws" ]]; then
                    print_info "Use AWS helper for instance management..."
                    ./.agents/scripts/aws-helper.sh list
                elif [[ "$auth_type" == "github" ]]; then
                    print_info "Use GitHub CLI helper for repository management..."
                    ./.agents/scripts/github-cli-helper.sh list-accounts
                elif [[ "$auth_type" == "gitlab" ]]; then
                    print_info "Use GitLab CLI helper for project management..."
                    ./.agents/scripts/gitlab-cli-helper.sh list-accounts
                elif [[ "$auth_type" == "gitea" ]]; then
                    print_info "Use Gitea CLI helper for repository management..."
                    ./.agents/scripts/gitea-cli-helper.sh list-accounts
                fi
                ;;
            *)
                print_info "Delegating to provider-specific helper..."
                ./.agents/scripts/"${auth_type}"-helper.sh "$command" "$args"
                ;;
        esac
        ;;
    *)
        # Handle regular SSH servers
        case "$command" in
            "connect"|"ssh"|"")
                print_info "Connecting to $host..."
                if [[ -n "$port" && "$port" != "22" ]]; then
                    ssh -p "$port" "$host"
                else
                    ssh "$host"
                fi
                ;;
            "status")
                print_info "Checking status of $host..."
                if [[ -n "$port" && "$port" != "22" ]]; then
                    ssh -p "$port" "$host" "echo 'Server: \$(hostname)' && echo 'Uptime: \$(uptime)' && echo 'Load: \$(cat /proc/loadavg)' && echo 'Memory:' && free -h"
                else
                    ssh "$host" "echo 'Server: \$(hostname)' && echo 'Uptime: \$(uptime)' && echo 'Load: \$(cat /proc/loadavg)' && echo 'Memory:' && free -h"
                fi
                ;;
            "exec")
                if [[ -n "$args" ]]; then
                    print_info "Executing '$args' on $host..."
                    if [[ -n "$port" && "$port" != "22" ]]; then
                        ssh -p "$port" "$host" "$args"
                    else
                        ssh "$host" "$args"
                    fi
                else
                    print_error "No command specified for exec"
                fi
                ;;
            "help"|"-h"|"--help")
                echo "Global Servers Helper Script"
                echo "Usage: $0 [server] [command]"
                echo ""
                echo "This script provides unified access to all servers across all providers."
                echo "For detailed provider-specific operations, use individual helper scripts."
                echo ""
                echo "Servers:"
                list_servers
                echo ""
                echo "Commands:"
                echo "  connect, ssh, (empty)  - Connect to server"
                echo "  status                 - Show server status"
                echo "  exec 'command'         - Execute command on server"
                echo "  list                   - List available servers"
                echo "  help                   - Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0 production-web connect"
                echo "  $0 staging-web status"
                echo "  $0 hostinger connect"
                echo "  $0 hetzner connect"
                echo ""
                echo "Provider-Specific Helpers:"
                echo "  ./.agents/scripts/hostinger-helper.sh      - Hostinger shared hosting"
                echo "  ./.agents/scripts/hetzner-helper.sh        - Hetzner Cloud VPS"
                echo "  ./.agents/scripts/closte-helper.sh         - Closte.com VPS servers"
                echo "  ./.agents/scripts/cloudron-helper.sh       - Cloudron server management"
                echo "  ./.agents/scripts/dns-helper.sh            - DNS management across providers"
                echo "  ./.agents/scripts/localhost-helper.sh      - Local development with .local domains"
                echo "  ./.agents/scripts/aws-helper.sh            - AWS EC2 instances"
                echo "  ./.agents/scripts/github-cli-helper.sh     - GitHub CLI repository management"
                echo "  ./.agents/scripts/gitlab-cli-helper.sh     - GitLab CLI project management"
                echo "  ./.agents/scripts/gitea-cli-helper.sh      - Gitea CLI repository management"
                ;;
            *)
                print_error "$ERROR_UNKNOWN_COMMAND $command"
                print_info "Use '$0 help' for usage information"
                exit 1
                ;;
        esac
        ;;
esac
