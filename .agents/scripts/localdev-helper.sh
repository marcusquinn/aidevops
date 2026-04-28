#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# localdev - Local development environment manager
# Manages dnsmasq, Traefik conf.d, mkcert certs, and port registry
# for production-like .local domains with HTTPS on port 443.
#
# DNS: /etc/hosts entries are the PRIMARY mechanism for .local domains in
# browsers (macOS mDNS intercepts .local before /etc/resolver/local).
# dnsmasq provides wildcard resolution for CLI tools only.
# Coexists with LocalWP: LocalWP entries (#Local Site) in /etc/hosts
# take precedence; localdev entries use a different marker (# localdev:).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

# Error message constants (fallback if shared-constants.sh unavailable)
if [[ -z "${ERROR_UNKNOWN_COMMAND:-}" ]]; then
	readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
fi
if [[ -z "${HELP_USAGE_INFO:-}" ]]; then
	readonly HELP_USAGE_INFO="Use '$0 help' for usage information"
fi

# Paths
readonly LOCALDEV_DIR="$HOME/.local-dev-proxy"
readonly CONFD_DIR="$LOCALDEV_DIR/conf.d"
export PORTS_FILE="$LOCALDEV_DIR/ports.json"
export CERTS_DIR="$HOME/.local-ssl-certs"
readonly TRAEFIK_STATIC="$LOCALDEV_DIR/traefik.yml"
readonly DOCKER_COMPOSE="$LOCALDEV_DIR/docker-compose.yml"
readonly BACKUP_DIR="$LOCALDEV_DIR/backup"

# LocalWP sites.json path (macOS standard location)
LOCALWP_SITES_JSON="${LOCALWP_SITES_JSON:-$HOME/Library/Application Support/Local/sites.json}"

# Detect Homebrew prefix (Apple Silicon vs Intel)
detect_brew_prefix() {
	if [[ -d "/opt/homebrew" ]]; then
		echo "/opt/homebrew"
	elif [[ -d "/usr/local/Cellar" ]]; then
		echo "/usr/local"
	else
		echo ""
	fi
	return 0
}

# =============================================================================
# Sub-library sourcing
# =============================================================================

# shellcheck source=./localdev-helper-init.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/localdev-helper-init.sh"

# shellcheck source=./localdev-helper-ports.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/localdev-helper-ports.sh"

# shellcheck source=./localdev-helper-routes.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/localdev-helper-routes.sh"

# shellcheck source=./localdev-helper-branch.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/localdev-helper-branch.sh"

# shellcheck source=./localdev-helper-run.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/localdev-helper-run.sh"

# shellcheck source=./localdev-helper-db.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/localdev-helper-db.sh"

# shellcheck source=./localdev-helper-status.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/localdev-helper-status.sh"

# =============================================================================
# Add Command
# =============================================================================
# NOTE: cmd_add stays in the orchestrator (identity-key preservation — 105
# lines exceeds the 100-line function-complexity threshold; moving to a new
# file would register it as a new violation per reference/large-file-split.md).

cmd_add() {
	local name="${1:-}"
	local port_arg="${2:-}"

	if [[ -z "$name" ]]; then
		print_error "Usage: localdev-helper.sh add <name> [port]"
		print_info "  name: app name (e.g., myapp → myapp.local)"
		print_info "  port: optional port (auto-assigned from 3100-3999 if omitted)"
		exit 1
	fi

	# Validate name: alphanumeric + hyphens only
	if ! echo "$name" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
		print_error "Invalid app name '$name': use lowercase letters, numbers, and hyphens only"
		exit 1
	fi

	local domain="${name}.local"

	print_info "localdev add $name ($domain)"
	echo ""

	# Step 1: Collision detection
	if ! check_collision "$name" "$domain"; then
		exit 1
	fi

	# Step 2: Assign port
	local port
	if [[ -n "$port_arg" ]]; then
		port="$port_arg"
		# Validate port is a number
		if ! echo "$port" | grep -qE '^[0-9]+$'; then
			print_error "Invalid port '$port': must be a number"
			exit 1
		fi
		# Check port collision
		if is_port_registered "$port"; then
			print_error "Port $port is already registered in port registry"
			exit 1
		fi
		if is_port_in_use "$port"; then
			print_warning "Port $port is currently in use by another process"
			print_info "  The port will be registered but may conflict at runtime"
		fi
	else
		print_info "Auto-assigning port from range $PORT_RANGE_START-$PORT_RANGE_END..."
		port="$(assign_port)" || exit 1
		print_success "Assigned port: $port"
	fi

	# Step 3: Generate mkcert wildcard cert
	generate_cert "$name" || exit 1

	# Step 4: Create Traefik conf.d route file
	create_traefik_route "$name" "$port" || exit 1

	# Step 5: Add /etc/hosts entry (required for browser resolution of .local)
	# macOS mDNS intercepts .local before /etc/resolver/local, so dnsmasq alone
	# is insufficient for browsers. /etc/hosts is the only reliable mechanism.
	add_hosts_entry "$domain" || true

	# Step 6: Register in port registry
	register_app "$name" "$port" "$domain" || exit 1

	# Step 7: Reload Traefik if running (conf.d watch handles this, but signal for clarity)
	if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^local-traefik$'; then
		print_info "Traefik is running — conf.d watch will pick up new route automatically"
	else
		print_info "Traefik not running. Start with:"
		print_info "  cd $LOCALDEV_DIR && docker compose up -d"
	fi

	echo ""
	print_success "localdev add complete: $name"
	echo ""
	print_info "  Domain:  https://$domain"
	print_info "  Port:    $port (app should listen on this port)"
	print_info "  Cert:    $CERTS_DIR/${domain}+1.pem"
	print_info "  Route:   $CONFD_DIR/${name}.yml"
	print_info "  Registry: $PORTS_FILE"
	return 0
}

# =============================================================================
# List Projects Helper (orchestrator-level — identity-key preservation)
# =============================================================================
# NOTE: _cmd_list_localdev_projects stays in the orchestrator (identity-key
# preservation — 101 lines exceeds the 100-line function-complexity threshold).

# Print the localdev-managed projects section of cmd_list
_cmd_list_localdev_projects() {
	echo "--- localdev projects ---"
	echo ""

	if command -v jq >/dev/null 2>&1; then
		local count
		count="$(jq '.apps | length' "$PORTS_FILE")"
		if [[ "$count" -eq 0 ]]; then
			print_info "  No apps registered. Use: localdev-helper.sh add <name>"
		else
			printf "  %-20s %-28s %-6s %-6s %-6s %s\n" "NAME" "URL" "PORT" "CERT" "PROC" "PROCESS"
			printf "  %-20s %-28s %-6s %-6s %-6s %s\n" "----" "---" "----" "----" "----" "-------"

			local apps_json
			apps_json="$(jq -r '.apps | to_entries[] | "\(.key)\t\(.value.port)\t\(.value.domain)"' "$PORTS_FILE")"
			while IFS=$'\t' read -r app_name app_port app_domain; do
				[[ -z "$app_name" ]] && continue
				# Reset IFS to default before $() calls — prevents zsh IFS leak corrupting PATH lookup
				local cert_st health_st proc_name cert_fmt health_fmt _saved_ifs="$IFS"
				IFS=$' \t\n'
				cert_st="$(check_cert_status "$app_name")"
				health_st="$(check_port_health "$app_port")"
				proc_name="$(get_port_process "$app_port")"
				cert_fmt="$(format_status "$cert_st")"
				health_fmt="$(format_status "$health_st")"
				IFS="$_saved_ifs"
				printf "  %-20s %-28s %-6s %-6s %-6s %s\n" \
					"$app_name" "https://${app_domain}" "$app_port" \
					"$cert_fmt" "$health_fmt" \
					"${proc_name:--}"

				local branches_json
				IFS=$' \t\n'
				branches_json="$(jq -r --arg a "$app_name" \
					'.apps[$a].branches // {} | to_entries[] | "\(.key)\t\(.value.port)\t\(.value.subdomain)"' \
					"$PORTS_FILE" 2>/dev/null)"
				IFS="$_saved_ifs"
				if [[ -n "$branches_json" ]]; then
					while IFS=$'\t' read -r br_name br_port br_subdomain; do
						[[ -z "$br_name" ]] && continue
						# Reset IFS to default before $() calls inside nested loop
						local br_health br_proc br_health_fmt _saved_ifs2="$IFS"
						IFS=$' \t\n'
						br_health="$(check_port_health "$br_port")"
						br_proc="$(get_port_process "$br_port")"
						br_health_fmt="$(format_status "$br_health")"
						IFS="$_saved_ifs2"
						printf "  %-20s %-28s %-6s %-6s %-6s %s\n" \
							"  > $br_name" "https://${br_subdomain}" "$br_port" \
							"    " "$br_health_fmt" \
							"${br_proc:--}"
					done <<<"$branches_json"
				fi
			done <<<"$apps_json"
		fi
	else
		python3 - "$PORTS_FILE" "$CERTS_DIR" <<'PYEOF'
import sys, json, subprocess, os

ports_file, certs_dir = sys.argv[1], sys.argv[2]
with open(ports_file) as f:
    data = json.load(f)

apps = data.get('apps', {})
if not apps:
    print("  No apps registered.")
else:
    print(f"  {'NAME':<20} {'URL':<28} {'PORT':<6} {'CERT':<6} {'PROC':<6} {'PROCESS'}")
    print(f"  {'----':<20} {'---':<28} {'----':<6} {'----':<6} {'----':<6} {'-------'}")
    for name, info in apps.items():
        domain = info.get('domain', f'{name}.local')
        port = info.get('port', '?')
        cert = os.path.join(certs_dir, f'{domain}+1.pem')
        key = os.path.join(certs_dir, f'{domain}+1-key.pem')
        cert_ok = os.path.isfile(cert) and os.path.isfile(key)
        try:
            r = subprocess.run(['lsof', '-i', f':{port}', '-sTCP:LISTEN', '-t'],
                               capture_output=True, text=True, timeout=2)
            proc_up = r.returncode == 0
            pid = r.stdout.strip().split('\n')[0] if proc_up else ''
            proc_name = subprocess.run(['ps', '-p', pid, '-o', 'comm='],
                                       capture_output=True, text=True, timeout=2).stdout.strip() if pid else '-'
        except Exception:
            proc_up = False
            proc_name = '-'
        print(f"  {name:<20} https://{domain:<24} {port:<6} {'[OK]' if cert_ok else '[!!]':<6} {'[OK]' if proc_up else '[--]':<6} {proc_name}")
        for bname, binfo in info.get('branches', {}).items():
            bp = binfo.get('port', '?')
            try:
                r2 = subprocess.run(['lsof', '-i', f':{bp}', '-sTCP:LISTEN', '-t'],
                                    capture_output=True, text=True, timeout=2)
                bp_up = r2.returncode == 0
            except Exception:
                bp_up = False
            print(f"    > {bname:<16} https://{binfo.get('subdomain','?'):<24} {bp:<6} {'    ':<6} {'[OK]' if bp_up else '[--]':<6}")
PYEOF
	fi
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	echo "localdev — Local development environment manager"
	echo ""
	echo "Usage: localdev-helper.sh <command> [options]"
	echo ""
	echo "Commands:"
	echo "  run <command...>   Zero-config: auto-register + inject PORT + exec command"
	echo "  init               One-time setup: dnsmasq, resolver, Traefik conf.d migration"
	echo "  add <name> [port]  Register app: cert + Traefik route + port registry"
	echo "  rm <name>          Remove app: reverses all add operations (incl. branches)"
	echo "  branch <app> <branch> [port]  Add branch subdomain route"
	echo "  branch rm <app> <branch>      Remove branch route"
	echo "  branch list [app]             List branch routes"
	echo "  db <command>       Shared Postgres management (start, create, list, drop, url)"
	echo "  list               Dashboard: all projects, URLs, certs, health, LocalWP"
	echo "  status             Infrastructure health: dnsmasq, Traefik, certs, ports"
	echo "  help               Show this help message"
	echo ""
	echo "Run performs (zero-config):"
	echo "  1. Infer project name from package.json or git repo basename"
	echo "  2. Auto-register if not already registered (cert, route, port, /etc/hosts)"
	echo "  3. Detect worktree/branch and create branch subdomain if needed"
	echo "  4. Set PORT and HOST=0.0.0.0 environment variables"
	echo "  5. Exec the command (signals pass through directly)"
	echo ""
	echo "Add performs:"
	echo "  1. Collision detection (LocalWP, registry, port)"
	echo "  2. Auto-assign port from 3100-3999 (or use specified port)"
	echo "  3. Generate mkcert wildcard cert (*.name.local + name.local)"
	echo "  4. Create Traefik conf.d/{name}.yml route file"
	echo "  5. Add /etc/hosts entry (required for browser resolution of .local)"
	echo "  6. Register in ~/.local-dev-proxy/ports.json"
	echo ""
	echo "Remove reverses all add operations."
	echo ""
	echo "Init performs:"
	echo "  1. Configure dnsmasq with address=/.local/127.0.0.1 (CLI wildcard resolution)"
	echo "  2. Create /etc/resolver/local (routes .local to dnsmasq for CLI tools)"
	echo "  3. Migrate Traefik from single dynamic.yml to conf.d/ directory"
	echo "  4. Preserve existing routes (e.g., webapp)"
	echo "  5. Restart Traefik if running"
	echo "  Note: dnsmasq resolves .local for CLI tools only. Browsers need /etc/hosts"
	echo "  entries (added automatically by 'add' command) due to macOS mDNS."
	echo ""
	echo "Requires: docker, mkcert, dnsmasq"
	echo "  mkcert is auto-installed if missing (apt, dnf, pacman, brew)"
	echo "  dnsmasq: brew install dnsmasq (macOS) / sudo apt install dnsmasq (Linux)"
	echo "Requires: sudo (for /etc/hosts and dnsmasq restart)"
	echo ""
	echo "LocalWP coexistence:"
	echo "  Domains in /etc/hosts (#Local Site) take precedence over dnsmasq."
	echo "  localdev add detects and rejects collisions with LocalWP domains."
	echo ""
	echo "Port range: $PORT_RANGE_START-$PORT_RANGE_END (auto-assigned)"
	echo "Registry:   $PORTS_FILE"
	echo "Certs:      $CERTS_DIR"
	echo "Routes:     $CONFD_DIR"
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"

	case "$command" in
	init)
		cmd_init
		;;
	run)
		shift
		cmd_run "$@"
		;;
	add)
		shift
		cmd_add "$@"
		;;
	rm | remove)
		shift
		cmd_rm "$@"
		;;
	branch)
		shift
		cmd_branch "$@"
		;;
	db)
		shift
		cmd_db "$@"
		;;
	list | ls)
		cmd_list
		;;
	status)
		cmd_status
		;;
	infer-name)
		# Internal: infer project name for a directory (used by worktree-helper.sh)
		shift
		infer_project_name "${1:-.}"
		;;
	help | -h | --help | "")
		cmd_help
		;;
	*)
		print_error "$ERROR_UNKNOWN_COMMAND $command"
		print_info "$HELP_USAGE_INFO"
		exit 1
		;;
	esac
	return 0
}

main "$@"
