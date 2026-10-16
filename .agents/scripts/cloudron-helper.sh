#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2129,SC2317
set -euo pipefail

# Cloudron Helper Script
# Manages Cloudron servers and applications

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# String literal constants
readonly ERROR_SERVER_NAME_REQUIRED="Server name is required"
readonly ERROR_SERVER_NOT_FOUND="Server not found in configuration"
readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 [command] [options]"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

# Error message constants
# readonly USAGE_PREFIX="Usage:"  # Currently unused

# Configuration file
CONFIG_FILE="../configs/cloudron-config.json"

# Check if config file exists
check_config() {
	if [[ ! -f "$CONFIG_FILE" ]]; then
		print_error "$ERROR_CONFIG_NOT_FOUND"
		print_info "Copy and customize: cp ../configs/cloudron-config.json.txt $CONFIG_FILE"
		exit 1
	fi
	return 0
}

# Check if Cloudron CLI is installed
check_cloudron_cli() {
	if ! command -v cloudron >/dev/null 2>&1; then
		print_warning "Cloudron CLI not found"
		print_info "Install with: npm install -g cloudron"
		print_info "Or download from: https://cloudron.io/documentation/cli/"
		return 1
	fi
	return 0
}

# List all Cloudron servers
list_servers() {
	check_config
	print_info "Available Cloudron servers:"

	servers=$(jq -r '.servers | keys[]' "$CONFIG_FILE")
	for server in $servers; do
		description=$(jq -r ".servers.$server.description" "$CONFIG_FILE")
		domain=$(jq -r ".servers.$server.domain" "$CONFIG_FILE")
		ip=$(jq -r ".servers.$server.ip" "$CONFIG_FILE")
		echo "  - $server: $description ($domain - $ip)"
	done
	return 0
}

# Connect to Cloudron server (SSH as root initially)
connect_server() {
	local server="$1"
	check_config

	if [[ -z "$server" ]]; then
		print_error "$ERROR_SERVER_NAME_REQUIRED"
		list_servers
		exit 1
	fi

	# Get server configuration
	local ip
	ip=$(jq -r ".servers.$server.ip" "$CONFIG_FILE")
	local domain
	domain=$(jq -r ".servers.$server.domain" "$CONFIG_FILE")
	local ssh_port
	ssh_port=$(jq -r ".servers.$server.ssh_port" "$CONFIG_FILE")

	if [[ "$ip" == "null" ]]; then
		print_error "$ERROR_SERVER_NOT_FOUND"
		list_servers
		exit 1
	fi

	ssh_port="${ssh_port:-22}"

	print_info "Connecting to Cloudron server $server ($domain)..."
	print_warning "Note: Use 'root' user for initial SSH access to Cloudron servers"

	ssh -p "$ssh_port" "root@$ip"
	return 0
}

# Execute command on Cloudron server
exec_on_server() {
	local server="$1"
	local command="$2"
	check_config

	if [[ -z "$server" || -z "$command" ]]; then
		print_error "Usage: exec [server] [command]"
		exit 1
	fi

	# Get server configuration
	local ip
	ip=$(jq -r ".servers.$server.ip" "$CONFIG_FILE")
	local ssh_port
	ssh_port=$(jq -r ".servers.$server.ssh_port" "$CONFIG_FILE")

	if [[ "$ip" == "null" ]]; then
		print_error "$ERROR_SERVER_NOT_FOUND"
		exit 1
	fi

	ssh_port="${ssh_port:-22}"

	print_info "Executing '$command' on $server..."
	ssh -p "$ssh_port" "root@$ip" "$command"
	return 0
}

# List apps on Cloudron server
list_apps() {
	local server="$1"
	check_config

	if [[ -z "$server" ]]; then
		print_error "$ERROR_SERVER_NAME_REQUIRED"
		exit 1
	fi

	local domain
	domain=$(jq -r ".servers.$server.domain" "$CONFIG_FILE")
	local token
	token=$(jq -r ".servers.$server.api_token" "$CONFIG_FILE")

	if [[ "$domain" == "null" ]]; then
		print_error "$ERROR_SERVER_NOT_FOUND"
		exit 1
	fi

	if check_cloudron_cli; then
		print_info "Listing apps on $server ($domain)..."
		if [[ "$token" != "null" ]]; then
			cloudron list --server "$domain" --token "$token"
		else
			print_warning "No API token configured. Using SSH method..."
			exec_on_server "$server" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -v redis"
		fi
	else
		print_info "Using SSH method to list apps..."
		return 0
		exec_on_server "$server" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -v redis"
	fi
	return 0
}

# Execute command in Cloudron app container
exec_in_app() {
	local server="$1"
	local app_id="$2"
	local command="$3"
	check_config

	if [[ -z "$server" || -z "$app_id" || -z "$command" ]]; then
		print_error "Usage: exec-app [server] [app-id] [command]"
		exit 1
	fi

	print_info "Executing '$command' in app $app_id on $server..."
	exec_on_server "$server" "docker exec $app_id $command"
	return 0
}

# Check Cloudron server status
check_status() {
	local server="$1"
	check_config

	if [[ -z "$server" ]]; then
		return 0
		print_error "$ERROR_SERVER_NAME_REQUIRED"
		exit 1
	fi

	return 0
	print_info "Checking Cloudron server status for $server..."
	exec_on_server "$server" "echo 'Cloudron Status:' && systemctl status cloudron --no-pager -l && echo '' && echo 'Docker Status:' && docker ps --format 'table {{.Names}}\t{{.Status}}' | head -10"
	return 0
}

# Generate SSH configurations for Cloudron servers
generate_ssh_configs() {
	check_config
	print_info "Generating SSH configurations for Cloudron servers..."

	servers=$(jq -r '.servers | keys[]' "$CONFIG_FILE")

	echo "# Cloudron servers SSH configuration" >~/.ssh/cloudron_config
	echo "# Generated on $(date)" >>~/.ssh/cloudron_config
	echo "# Note: Cloudron servers typically require 'root' user for SSH access" >>~/.ssh/cloudron_config

	for server in $servers; do
		ip=$(jq -r ".servers.$server.ip" "$CONFIG_FILE")
		domain=$(jq -r ".servers.$server.domain" "$CONFIG_FILE")
		ssh_port=$(jq -r ".servers.$server.ssh_port" "$CONFIG_FILE")
		description=$(jq -r ".servers.$server.description" "$CONFIG_FILE")

		ssh_port="${ssh_port:-22}"

		echo "" >>~/.ssh/cloudron_config
		echo "# $description ($domain)" >>~/.ssh/cloudron_config
		echo "Host $server" >>~/.ssh/cloudron_config
		echo "    HostName $ip" >>~/.ssh/cloudron_config
		echo "    Port $ssh_port" >>~/.ssh/cloudron_config
		echo "    User root" >>~/.ssh/cloudron_config
		echo "    IdentityFile ~/.ssh/id_ed25519" >>~/.ssh/cloudron_config
		echo "    AddKeysToAgent yes" >>~/.ssh/cloudron_config
		echo "    UseKeychain yes" >>~/.ssh/cloudron_config

		print_success "Added SSH config for $server ($domain)"
	done

	print_success "SSH configurations generated in ~/.ssh/cloudron_config"
	print_info "Add 'Include ~/.ssh/cloudron_config' to your ~/.ssh/config"
	return 0
}

# Make API call to Cloudron server
api_call() {
	local server="$1"
	local method="$2"
	local endpoint="$3"
	local data="$4"

	check_config

	local domain
	domain=$(jq -r ".servers.$server.domain" "$CONFIG_FILE")
	local token
	token=$(jq -r ".servers.$server.api_token" "$CONFIG_FILE")

	if [[ "$domain" == "null" ]]; then
		print_error "$ERROR_SERVER_NOT_FOUND"
		return 1
	fi

	if [[ "$token" == "null" ]]; then
		print_error "API token not configured for server $server"
		return 1
	fi

	local base_url="https://${domain}"
	local url="${base_url}${endpoint}"

	if [[ -n "$data" ]]; then
		curl -s -X "$method" \
			-H "Authorization: Bearer ${token}" \
			-H "Content-Type: application/json" \
			-d "$data" \
			"$url"
	else
		curl -s -X "$method" \
			-H "Authorization: Bearer ${token}" \
			"$url"
	fi
	return 0
}

# Get app info by subdomain
app_info() {
	local server="$1"
	local subdomain="$2"

	if [[ -z "$server" || -z "$subdomain" ]]; then
		print_error "Usage: app-info [server] [subdomain]"
		return 1
	fi

	print_info "Getting app info for $subdomain on $server..."

	local response
	response=$(api_call "$server" "GET" "/api/v1/apps")

	if [[ -z "$response" ]]; then
		print_error "Failed to get apps list"
		return 1
	fi

	# Filter by subdomain
	local app_info
	app_info=$(echo "$response" | jq -r ".apps[] | select(.location == \"$subdomain\")")

	if [[ -z "$app_info" ]]; then
		print_error "App not found with subdomain: $subdomain"
		return 1
	fi

	echo "$app_info" | jq '.'
	return 0
}

# Wait for app to be ready
wait_ready() {
	local server="$1"
	local app_id="$2"
	local max_wait="${3:-300}" # Default 5 minutes
	local check_interval=5
	local elapsed=0

	if [[ -z "$server" || -z "$app_id" ]]; then
		print_error "Usage: wait-ready [server] [app-id] [max-wait-seconds]"
		return 1
	fi

	print_info "Waiting for app $app_id to be ready (max ${max_wait}s)..."

	while [[ $elapsed -lt $max_wait ]]; do
		local response
		response=$(api_call "$server" "GET" "/api/v1/apps/$app_id")

		if [[ -z "$response" ]]; then
			print_warning "Failed to get app status, retrying..."
			sleep "$check_interval"
			elapsed=$((elapsed + check_interval))
			continue
		fi

		local status
		status=$(echo "$response" | jq -r '.runState')

		print_info "Current status: $status"

		if [[ "$status" == "running" ]]; then
			print_success "App is ready!"
			return 0
		elif [[ "$status" == "error" || "$status" == "stopped" ]]; then
			print_error "App failed to start. Status: $status"
			return 1
		fi

		sleep "$check_interval"
		elapsed=$((elapsed + check_interval))
	done

	print_error "Timeout waiting for app to be ready"
	return 1
}

# Install app on Cloudron server
install_app() {
	local server="$1"
	local app_store_id="$2"
	local subdomain="$3"
	local domain="$4"

	if [[ -z "$server" || -z "$app_store_id" || -z "$subdomain" ]]; then
		print_error "Usage: install-app [server] [appStoreId] [subdomain] [domain]"
		print_info "Example: install-app cloudron01 io.gitea.cloudronapp my-gitea example.com"
		return 1
	fi

	# If domain not provided, use server's default domain
	if [[ -z "$domain" ]]; then
		check_config
		domain=$(jq -r ".servers.$server.domain" "$CONFIG_FILE")
	fi

	print_info "Installing app $app_store_id at $subdomain.$domain on $server..."

	local data
	data=$(jq -n \
		--arg appStoreId "$app_store_id" \
		--arg location "$subdomain" \
		--arg domain "$domain" \
		'{appStoreId: $appStoreId, location: $location, domain: $domain}')

	local response
	response=$(api_call "$server" "POST" "/api/v1/apps/install" "$data")

	if [[ -z "$response" ]]; then
		print_error "Failed to install app"
		return 1
	fi

	local app_id
	app_id=$(echo "$response" | jq -r '.id')

	if [[ "$app_id" == "null" || -z "$app_id" ]]; then
		print_error "Installation failed: $(echo "$response" | jq -r '.message // .error // "Unknown error"')"
		return 1
	fi

	print_success "App installation started. App ID: $app_id"
	print_info "Use 'wait-ready $server $app_id' to monitor installation progress"

	echo "$app_id"
	return 0
}

# Uninstall app from Cloudron server
uninstall_app() {
	local server="$1"
	local app_id="$2"

	if [[ -z "$server" || -z "$app_id" ]]; then
		print_error "Usage: uninstall-app [server] [app-id]"
		print_info "Use 'app-info [server] [subdomain]' to get the app ID"
		return 1
	fi

	print_warning "Uninstalling app $app_id from $server..."

	local response
	response=$(api_call "$server" "POST" "/api/v1/apps/$app_id/uninstall" "")

	if [[ -z "$response" ]]; then
		print_error "Failed to uninstall app"
		return 1
	fi

	# Check for error in response
	local error
	error=$(echo "$response" | jq -r '.message // .error // empty')

	if [[ -n "$error" ]]; then
		print_error "Uninstallation failed: $error"
		return 1
	fi

	print_success "App uninstallation initiated"
	return 0
}

# Remote probe for health checks. Emits key=value lines only (no secrets).
# Placeholders: __UNITS__ (space-separated systemd units).
# shellcheck disable=SC2016 # runs remotely; expansion must not happen locally
readonly CLOUDRON_HEALTH_PROBE='
for u in __UNITS__; do echo "unit.$u=$(systemctl is-active "$u" 2>&1 | sed -n 1p)"; done
echo "failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | cut -d" " -f1 | paste -sd, -)"
echo "disk_pct=$(df -P / | tail -n1 | tr -s " " | cut -d" " -f5 | tr -d %)"
echo "dpkg_audit=$(dpkg --audit 2>&1 | sed -n 1,5p | tr "\n" " ")"
if command -v cloudron-support >/dev/null 2>&1; then
  timeout 120 cloudron-support --check-db-migrations >/dev/null 2>&1; echo "db_migrations_rc=$?"
  timeout 120 cloudron-support --check-services >/dev/null 2>&1; echo "services_rc=$?"
else
  echo "db_migrations_rc=missing"; echo "services_rc=missing"
fi
echo "backup_age_hours=$(mysql -uroot -ppassword box -N -B -e "SELECT IFNULL(TIMESTAMPDIFF(HOUR, MAX(creationTime), NOW()), -1) FROM backups WHERE state=\"normal\"" 2>/dev/null | sed -n 1p)"
echo "api_version=$(curl -fsS -m 10 http://127.0.0.1:3000/api/v1/cloudron/status 2>/dev/null | jq -r ".version // empty" 2>/dev/null)"
'

# Fleet health check: detects a dead Cloudron platform even if the dashboard looks up.
# Usage: health <server> [--format json|text] [--backup-max-hours N]
#        [--disk-warn N] [--disk-crit N] [--extra-unit NAME]
# Exit: 0 = ok/warn only, 2 = critical finding, 1 = usage/connection error.
health_check() {
	local server="${1:-}"
	shift || true
	local format="json" backup_max=48 disk_warn=85 disk_crit=95 extra_units=""

	if [[ -z "$server" ]]; then
		print_error "$ERROR_SERVER_NAME_REQUIRED"
		return 1
	fi
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		case "$opt" in
		--format) format="${2:-json}"; shift 2 ;;
		--backup-max-hours) backup_max="${2:-48}"; shift 2 ;;
		--disk-warn) disk_warn="${2:-85}"; shift 2 ;;
		--disk-crit) disk_crit="${2:-95}"; shift 2 ;;
		--extra-unit) extra_units="${extra_units} ${2:-}"; shift 2 ;;
		*) print_error "Unknown health option: $opt"; return 1 ;;
		esac
	done
	if [[ ! "$backup_max$disk_warn$disk_crit" =~ ^[0-9]+$ ]]; then
		print_error "Thresholds must be integers"
		return 1
	fi
	if [[ ! "$extra_units" =~ ^[A-Za-z0-9@._:\ -]*$ ]]; then
		print_error "Invalid --extra-unit value"
		return 1
	fi

	check_config
	local ip ssh_port
	ip=$(jq -r ".servers.\"$server\".ip" "$CONFIG_FILE")
	ssh_port=$(jq -r ".servers.\"$server\".ssh_port // 22" "$CONFIG_FILE")
	if [[ "$ip" == null ]]; then
		print_error "$ERROR_SERVER_NOT_FOUND"
		return 1
	fi

	local units="box mysql docker nginx unbound${extra_units}"
	local probe="${CLOUDRON_HEALTH_PROBE//__UNITS__/$units}"
	local out
	if ! out=$(ssh -p "$ssh_port" -o BatchMode=yes -o ConnectTimeout=15 "root@${ip}" "$probe" 2>/dev/null); then
		out=""
	fi

	local findings
	findings=$(health_evaluate "$out" "$units" "$extra_units" "$backup_max" "$disk_warn" "$disk_crit")

	local crit warn status exit_code=0
	crit=$(jq '[.[] | select(.severity=="critical")] | length' <<<"$findings")
	warn=$(jq '[.[] | select(.severity=="warn")] | length' <<<"$findings")
	status=ok
	((warn > 0)) && status=warn
	if ((crit > 0)); then
		status=critical
		exit_code=2
	fi

	if [[ "$format" == "text" ]]; then
		print_info "Cloudron health for $server: $status ($crit critical, $warn warn)"
		jq -r '.[] | "  [\(.severity)] \(.check): \(.message)"' <<<"$findings"
	else
		jq -n --arg s "$server" --arg st "$status" --argjson f "$findings" \
			'{server:$s,status:$st,findings:$f}'
	fi
	return "$exit_code"
}

# Evaluate probe output into a JSON findings array on stdout.
# Args: probe-output units extra-units backup-max-hours disk-warn disk-crit
health_evaluate() {
	local out="$1" units="$2" extra_units="$3" backup_max="$4" disk_warn="$5" disk_crit="$6"
	local findings="[]"
	_hf_add() {
		local sev="$1" check="$2" msg="$3"
		findings=$(jq -c --arg s "$sev" --arg c "$check" --arg m "$msg" '. + [{severity:$s,check:$c,message:$m}]' <<<"$findings")
		return 0
	}
	_hf_val() {
		local key="$1"
		local line
		line=$(printf '%s\n' "$out" | grep "^${key}=" | sed -n 1p || true)
		printf '%s' "${line#"${key}="}"
		return 0
	}

	if [[ -z "$out" ]]; then
		_hf_add critical connectivity "SSH probe failed or returned nothing"
	else
		local u state sev
		for u in $units; do
			state=$(_hf_val "unit.$u")
			[[ "$state" == "active" ]] && continue
			sev=critical
			[[ "$u" == "unbound" ]] && sev=warn
			[[ " ${extra_units} " == *" $u "* ]] && sev=critical
			_hf_add "$sev" "unit:$u" "systemctl is-active reports '${state:-unknown}'"
		done
		local failed disk dpkg_out dbm svc bage ver
		failed=$(_hf_val failed_units)
		[[ -n "$failed" ]] && _hf_add warn systemd-failed "Failed units: $failed"
		disk=$(_hf_val disk_pct)
		if [[ ! "$disk" =~ ^[0-9]+$ ]]; then
			_hf_add warn disk "Could not read root filesystem usage"
		elif ((disk >= disk_crit)); then
			_hf_add critical disk "Root filesystem ${disk}% used (critical >= ${disk_crit}%)"
		elif ((disk >= disk_warn)); then
			_hf_add warn disk "Root filesystem ${disk}% used (warn >= ${disk_warn}%)"
		fi
		dpkg_out=$(_hf_val dpkg_audit)
		[[ -n "${dpkg_out// /}" ]] && _hf_add warn dpkg "dpkg --audit reports half-configured packages: ${dpkg_out}"
		dbm=$(_hf_val db_migrations_rc)
		[[ "$dbm" != "0" ]] && _hf_add warn db-migrations "cloudron-support --check-db-migrations result: ${dbm:-unknown}"
		svc=$(_hf_val services_rc)
		[[ "$svc" != "0" ]] && _hf_add warn services "cloudron-support --check-services result: ${svc:-unknown}"
		bage=$(_hf_val backup_age_hours)
		if [[ ! "$bage" =~ ^-?[0-9]+$ || "$bage" == "-1" ]]; then
			_hf_add critical backup "No successful backup found or backups unreadable"
		elif ((bage > backup_max)); then
			_hf_add critical backup "Newest successful backup is ${bage}h old (max ${backup_max}h)"
		fi
		ver=$(_hf_val api_version)
		[[ -z "$ver" ]] && _hf_add critical api "Local /api/v1/cloudron/status returned no version"
	fi
	printf '%s' "$findings"
	return 0
}

# Assign positional parameters to local variables
# Main function
main() {
	local command="${1:-help}"
	local param2="${2:-}"
	local param3="${3:-}"
	local param4="${4:-}"

	local server_name="$param2"
	local command_to_run="$param3"

	# Main command handler
	case "$command" in
	"list")
		list_servers
		;;
	"connect")
		connect_server "$server_name"
		;;
	"exec")
		exec_on_server "$server_name" "$command_to_run"
		;;
	"apps")
		list_apps "$server_name"
		;;
	"exec-app")
		exec_in_app "$param2" "$param3" "$param4"
		;;
	"status")
		check_status "$param2"
		;;
	"generate-ssh-configs")
		generate_ssh_configs
		;;
	"app-info")
		app_info "$param2" "$param3"
		;;
	"install-app")
		install_app "$param2" "$param3" "$param4" "${5:-}"
		;;
	"uninstall-app")
		uninstall_app "$param2" "$param3"
		;;
	"wait-ready")
		wait_ready "$param2" "$param3" "${4:-300}"
		;;
	"health" | "fleet-health")
		shift || true
		health_check "$@"
		;;
	"help" | "-h" | "--help" | "")
		echo "Cloudron Helper Script"
		echo "$USAGE_COMMAND_OPTIONS"
		echo ""
		echo "Commands:"
		echo "  list                                    - List all Cloudron servers"
		echo "  connect [server]                        - Connect to server via SSH (as root)"
		echo "  exec [server] [command]                 - Execute command on server"
		echo "  apps [server]                           - List apps on Cloudron server"
		echo "  exec-app [server] [app] [cmd]           - Execute command in app container"
		echo "  status [server]                         - Check Cloudron server status"
		echo "  generate-ssh-configs                    - Generate SSH configurations"
		echo "  app-info [server] [subdomain]           - Get app details by subdomain"
		echo "  install-app [server] [id] [sub] [dom]   - Install app (domain optional)"
		echo "  uninstall-app [server] [app-id]         - Uninstall app"
		echo "  wait-ready [server] [app-id] [timeout]  - Wait for app to be ready"
		echo "  health [server] [--format json|text] [--backup-max-hours N] [--disk-warn N] [--disk-crit N] [--extra-unit U]"
		echo "                                          - Fleet health; exit 2 on critical findings"
		echo "  help                          - $HELP_SHOW_MESSAGE"
		echo ""
		echo "Examples:"
		echo "  $0 list"
		echo "  $0 connect cloudron01"
		echo "  $0 apps cloudron01"
		echo "  $0 app-info cloudron01 my-app"
		echo "  $0 install-app cloudron01 io.gitea.cloudronapp my-gitea"
		echo "  $0 wait-ready cloudron01 app-abc123"
		echo "  $0 uninstall-app cloudron01 app-abc123"
		echo "  $0 exec-app cloudron01 app-id 'ls -la /app/data'"
		echo "  $0 status cloudron01"
		echo ""
		echo "Note: Cloudron servers typically require 'root' user for SSH access"
		echo "Access recovery: an invalid CLI token is not proof SSH recovery is unavailable."
		echo "With authorised SSH, inspect cloudron-support --help and installed version first;"
		echo "preserve active support logins, keep temporary credentials private, and revoke them after use."
		echo "Do not reset owner passwords, insert raw tokens, bypass auth, or weaken host-key checking."
		echo "Install Cloudron CLI: npm install -g cloudron"
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
