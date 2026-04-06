#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2029
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

# Delegate command to a provider-specific helper script
delegate_to_provider() {
	local auth_type="$1"
	local command="$2"
	local args="$3"

	local helper_script="./.agents/scripts/${auth_type}-helper.sh"

	case "$command" in
	"connect" | "ssh" | "")
		local desc
		desc=$(get_provider_connect_message "$auth_type")
		print_info "$desc"
		"$helper_script" list
		;;
	*)
		print_info "Delegating to provider-specific helper..."
		# shellcheck disable=SC2086
		"$helper_script" "$command" $args
		;;
	esac
	return 0
}

# Return the connect info message for a provider (matches original output)
get_provider_connect_message() {
	local auth_type="$1"

	case "$auth_type" in
	"hostinger") echo "Use Hostinger helper for site management..." ;;
	"hetzner") echo "Use Hetzner helper for server management..." ;;
	"closte") echo "Use Closte helper for server management..." ;;
	"cloudron") echo "Use Cloudron helper for server management..." ;;
	"dns") echo "Use DNS helper for domain management..." ;;
	"localhost") echo "Use Localhost helper for local development..." ;;
	"aws") echo "Use AWS helper for instance management..." ;;
	*) echo "Use ${auth_type} helper for management..." ;;
	esac
	return 0
}

# Run an SSH command with optional non-standard port
run_ssh_command() {
	local host="$1"
	local port="$2"
	shift 2
	local remote_cmd="$*"

	local port_args=()
	if [[ -n "$port" && "$port" != "22" ]]; then
		port_args=(-p "$port")
	fi

	if [[ -n "$remote_cmd" ]]; then
		ssh "${port_args[@]}" "$host" "$remote_cmd"
	else
		ssh "${port_args[@]}" "$host"
	fi
	return 0
}

# Handle SSH server commands (connect, status, exec)
handle_ssh_server() {
	local host="$1"
	local port="$2"
	local command="$3"
	local args="$4"

	case "$command" in
	"connect" | "ssh" | "")
		print_info "Connecting to $host..."
		run_ssh_command "$host" "$port"
		;;
	"status")
		print_info "Checking status of $host..."
		run_ssh_command "$host" "$port" "echo 'Server: \$(hostname)' && echo 'Uptime: \$(uptime)' && echo 'Load: \$(cat /proc/loadavg)' && echo 'Memory:' && free -h"
		;;
	"exec")
		if [[ -z "$args" ]]; then
			print_error "No command specified for exec"
			return 1
		fi
		print_info "Executing '$args' on $host..."
		run_ssh_command "$host" "$port" "$args"
		;;
	"help" | "-h" | "--help")
		show_help
		;;
	*)
		print_error "$ERROR_UNKNOWN_COMMAND $command"
		print_info "Use '$0 help' for usage information"
		return 1
		;;
	esac
	return 0
}

# Check if a server is a provider-delegated type
is_provider_server() {
	local server="$1"

	case "$server" in
	"hostinger" | "hetzner" | "closte" | "cloudron" | "dns" | "localhost" | "aws")
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# Show help text
show_help() {
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
	return 0
}

# --- Main ---

# Handle no-args and list command early
if [[ $# -eq 0 ]]; then
	show_help
	exit 0
fi

if [[ "$1" == "list" ]]; then
	list_servers
	exit 0
fi

if [[ "$1" == "help" || "$1" == "-h" || "$1" == "--help" ]]; then
	show_help
	exit 0
fi

# Parse arguments
server="$1"
command="${2:-connect}"
shift "$(($# > 2 ? 2 : $#))"
args="$*"

# Validate server
config=$(get_server_config "$server")
if [[ -z "$config" ]]; then
	print_error "Unknown server: $server"
	echo ""
	list_servers
	exit 1
fi

read -r host port auth_type <<<"$config"

# Route to provider helper or SSH handler
if is_provider_server "$server"; then
	delegate_to_provider "$auth_type" "$command" "$args"
else
	handle_ssh_server "$host" "$port" "$command" "$args"
fi
