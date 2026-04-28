#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# localdev-helper-status.sh -- Remove, list, and status dashboard functions
# =============================================================================
# Implements cmd_rm (remove app), cmd_list (unified dashboard),
# and cmd_status (infrastructure health check), plus supporting helpers
# for cert status, port health, LocalWP site reading, and output formatting.
#
# Usage: source "${SCRIPT_DIR}/localdev-helper-status.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning,
#                          safe_grep_count)
#   - localdev-helper-ports.sh (is_app_registered, deregister_app, ensure_ports_file)
#   - localdev-helper-routes.sh (remove_traefik_route, remove_hosts_entry)
#   - localdev-helper-ports.sh (remove_cert)
#   - localdev-helper-branch.sh (remove_all_branches)
#   - localdev-helper-db.sh (pg_container_exists, pg_container_running,
#                             LOCALDEV_PG_CONTAINER, LOCALDEV_PG_PORT, LOCALDEV_PG_USER)
#   - detect_brew_prefix() from localdev-helper.sh orchestrator
#   - _cmd_list_localdev_projects() from localdev-helper.sh orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LOCALDEV_STATUS_LIB_LOADED:-}" ]] && return 0
_LOCALDEV_STATUS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (caller may not set it)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Remove Command
# =============================================================================

cmd_rm() {
	local name="${1:-}"

	if [[ -z "$name" ]]; then
		print_error "Usage: localdev-helper.sh rm <name>"
		exit 1
	fi

	local domain="${name}.local"

	print_info "localdev rm $name ($domain)"
	echo ""

	# Check if app is registered
	if ! is_app_registered "$name"; then
		print_warning "App '$name' is not registered in port registry"
		print_info "  Attempting cleanup of any leftover files..."
	fi

	# Step 1: Remove all branch routes for this app
	remove_all_branches "$name"

	# Step 2: Remove Traefik route file
	remove_traefik_route "$name"

	# Step 3: Remove mkcert cert files
	remove_cert "$name"

	# Step 4: Remove /etc/hosts entry (if present)
	remove_hosts_entry "$domain"

	# Step 5: Deregister from port registry
	deregister_app "$name"
	print_success "Removed $name from port registry"

	echo ""
	print_success "localdev rm complete: $name"
	return 0
}

# =============================================================================
# Dashboard Helpers — cert status, process health, LocalWP sites.json
# =============================================================================

# Check if cert files exist for a domain and return status string
# Returns: "ok" (both files exist), "missing" (neither), "partial" (one missing)
check_cert_status() {
	local name="$1"
	local domain="${name}.local"
	local cert_file="$CERTS_DIR/${domain}+1.pem"
	local key_file="$CERTS_DIR/${domain}+1-key.pem"

	if [[ -f "$cert_file" ]] && [[ -f "$key_file" ]]; then
		echo "ok"
	elif [[ -f "$cert_file" ]] || [[ -f "$key_file" ]]; then
		echo "partial"
	else
		echo "missing"
	fi
	return 0
}

# Check if something is listening on a given port
# Returns: "up" (listening), "down" (nothing listening)
check_port_health() {
	local port="$1"
	if lsof -i ":$port" -sTCP:LISTEN >/dev/null 2>&1; then
		echo "up"
	else
		echo "down"
	fi
	return 0
}

# Get the process name listening on a port (empty if nothing)
get_port_process() {
	local port="$1"
	lsof -i ":$port" -sTCP:LISTEN -t 2>/dev/null | head -1 | xargs -I{} ps -p {} -o comm= 2>/dev/null | head -1
	return 0
}

# Read LocalWP sites from sites.json (richer data than /etc/hosts grep)
# Outputs JSON array: [{name, domain, path, http_port, status}]
read_localwp_sites() {
	local sites_json="$LOCALWP_SITES_JSON"

	if [[ ! -f "$sites_json" ]]; then
		echo "[]"
		return 0
	fi

	if command -v jq >/dev/null 2>&1; then
		jq '[to_entries[] | .value | {
			name: .name,
			domain: .domain,
			path: .path,
			http_port: ((.services.nginx.ports.HTTP // .services.apache.ports.HTTP // [null])[0]),
			php_version: (.services.php.version // "unknown"),
			mysql_version: (.services.mysql.version // "unknown")
		}]' "$sites_json" 2>/dev/null || echo "[]"
	else
		python3 - "$sites_json" <<'PYEOF'
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    sites = []
    for key, site in data.items():
        services = site.get('services', {})
        nginx = services.get('nginx', {}).get('ports', {}).get('HTTP', [None])
        apache = services.get('apache', {}).get('ports', {}).get('HTTP', [None])
        http_port = nginx[0] if nginx[0] else (apache[0] if apache[0] else None)
        sites.append({
            'name': site.get('name', ''),
            'domain': site.get('domain', ''),
            'path': site.get('path', ''),
            'http_port': http_port,
            'php_version': services.get('php', {}).get('version', 'unknown'),
            'mysql_version': services.get('mysql', {}).get('version', 'unknown'),
        })
    print(json.dumps(sites))
except Exception:
    print('[]')
PYEOF
	fi
	return 0
}

# Format a status indicator for terminal output
format_status() {
	local status="$1"
	case "$status" in
	ok | up)
		echo "[OK]"
		;;
	down)
		echo "[--]"
		;;
	missing)
		echo "[!!]"
		;;
	partial)
		echo "[!?]"
		;;
	*)
		echo "[??]"
		;;
	esac
	return 0
}

# =============================================================================
# List Command — Unified dashboard
# =============================================================================

# Print the LocalWP sites section of cmd_list
_cmd_list_localwp_sites() {
	echo "--- LocalWP sites (read-only) ---"
	echo ""

	local localwp_data
	localwp_data="$(read_localwp_sites)"
	local localwp_count
	if command -v jq >/dev/null 2>&1; then
		localwp_count="$(echo "$localwp_data" | jq 'length')"
	else
		localwp_count="$(echo "$localwp_data" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")"
	fi

	if [[ "$localwp_count" -eq 0 ]] || [[ "$localwp_count" == "0" ]]; then
		print_info "  No LocalWP sites found"
		if [[ ! -f "$LOCALWP_SITES_JSON" ]]; then
			print_info "  (sites.json not found at: $LOCALWP_SITES_JSON)"
		fi
		return 0
	fi

	printf "  %-20s %-28s %-6s %-6s %-10s %s\n" "NAME" "DOMAIN" "PORT" "PROC" "PHP" "MYSQL"
	printf "  %-20s %-28s %-6s %-6s %-10s %s\n" "----" "------" "----" "----" "---" "-----"

	if command -v jq >/dev/null 2>&1; then
		echo "$localwp_data" | jq -r '.[] | "\(.name)\t\(.domain)\t\(.http_port // "-")\t\(.php_version)\t\(.mysql_version)"' |
			while IFS=$'\t' read -r lwp_name lwp_domain lwp_port lwp_php lwp_mysql; do
				[[ -z "$lwp_name" ]] && continue
				# Reset IFS to default before $() calls — prevents zsh IFS leak corrupting PATH lookup
				local lwp_health lwp_health_fmt _saved_ifs="$IFS"
				IFS=$' \t\n'
				if [[ "$lwp_port" != "-" ]] && [[ "$lwp_port" != "null" ]] && [[ -n "$lwp_port" ]]; then
					lwp_health="$(check_port_health "$lwp_port")"
				else
					lwp_health="down"
					lwp_port="-"
				fi
				lwp_health_fmt="$(format_status "$lwp_health")"
				IFS="$_saved_ifs"
				printf "  %-20s %-28s %-6s %-6s %-10s %s\n" \
					"$lwp_name" "$lwp_domain" "$lwp_port" \
					"$lwp_health_fmt" "$lwp_php" "$lwp_mysql"
			done
	else
		python3 -c "
import sys, json, subprocess
data = json.loads(sys.argv[1])
for site in data:
    name = site.get('name', '?')
    domain = site.get('domain', '?')
    port = site.get('http_port')
    php = site.get('php_version', '?')
    mysql = site.get('mysql_version', '?')
    port_str = str(port) if port else '-'
    proc_up = False
    if port:
        try:
            r = subprocess.run(['lsof', '-i', f':{port}', '-sTCP:LISTEN', '-t'],
                               capture_output=True, text=True, timeout=2)
            proc_up = r.returncode == 0
        except Exception:
            pass
    status = '[OK]' if proc_up else '[--]'
    print(f'  {name:<20} {domain:<28} {port_str:<6} {status:<6} {php:<10} {mysql}')
" "$localwp_data"
	fi
	return 0
}

# Print the Shared Postgres section of cmd_list
_cmd_list_postgres() {
	echo "--- Shared Postgres ---"
	echo ""
	if pg_container_running; then
		local db_count
		db_count="$(docker exec "$LOCALDEV_PG_CONTAINER" psql -U "$LOCALDEV_PG_USER" -tAc \
			"SELECT count(*) FROM pg_database WHERE datistemplate = false AND datname != 'postgres'" 2>/dev/null | tr -d ' ')"
		printf "  %-20s %-28s %-6s %-6s\n" "$LOCALDEV_PG_CONTAINER" "localhost:$LOCALDEV_PG_PORT" "$LOCALDEV_PG_PORT" "[OK]"
		print_info "  Databases: ${db_count:-0}"
	elif pg_container_exists; then
		printf "  %-20s %-28s %-6s %-6s\n" "$LOCALDEV_PG_CONTAINER" "localhost:$LOCALDEV_PG_PORT" "$LOCALDEV_PG_PORT" "[--]"
		print_info "  Container exists but stopped"
	else
		print_info "  Not configured (run: localdev db start)"
	fi
	return 0
}

cmd_list() {
	ensure_ports_file

	echo "=== Local Development Dashboard ==="
	echo ""

	_cmd_list_localdev_projects

	echo ""
	_cmd_list_localwp_sites

	echo ""
	_cmd_list_postgres

	echo ""
	echo "Legend: [OK]=healthy [--]=down [!!]=missing [!?]=partial"
	return 0
}

# =============================================================================
# Status Command
# =============================================================================

# Print dnsmasq and macOS resolver status sections for cmd_status
_cmd_status_dnsmasq() {
	echo "--- dnsmasq ---"
	local brew_prefix
	brew_prefix="$(detect_brew_prefix)"
	if [[ -n "$brew_prefix" ]] && [[ -f "$brew_prefix/etc/dnsmasq.conf" ]]; then
		if grep -q 'address=/.local/127.0.0.1' "$brew_prefix/etc/dnsmasq.conf" 2>/dev/null; then
			print_success "dnsmasq: .local wildcard configured"
		else
			print_warning "dnsmasq: .local wildcard NOT configured (run: localdev init)"
		fi
		if pgrep -x dnsmasq >/dev/null 2>&1; then
			print_success "dnsmasq process: running"
		else
			print_warning "dnsmasq process: not running"
		fi
	else
		print_warning "dnsmasq: config not found"
	fi

	echo ""
	echo "--- macOS resolver ---"
	if [[ -f "/etc/resolver/local" ]]; then
		print_success "/etc/resolver/local exists"
	else
		print_warning "/etc/resolver/local missing (run: localdev init)"
	fi
	return 0
}

# Print Traefik status section for cmd_status
_cmd_status_traefik() {
	echo "--- Traefik ---"
	if [[ -d "$CONFD_DIR" ]]; then
		local route_count
		route_count="$(find "$CONFD_DIR" -name '*.yml' -o -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
		print_success "conf.d/ directory: $route_count route file(s)"
		if [[ "$route_count" -gt 0 ]]; then
			find "$CONFD_DIR" -name '*.yml' -o -name '*.yaml' 2>/dev/null | while read -r f; do
				echo "  - $(basename "$f")"
			done
		fi
	else
		print_warning "conf.d/ directory not found (run: localdev init)"
	fi

	if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^local-traefik$'; then
		print_success "Traefik container: running"
		print_info "  Dashboard: http://localhost:8080"
	else
		print_warning "Traefik container: not running"
	fi
	return 0
}

# Print certificates status section for cmd_status
_cmd_status_certs() {
	echo "--- Certificates ---"
	if [[ -d "$CERTS_DIR" ]]; then
		local cert_count
		cert_count="$(find "$CERTS_DIR" -name '*.pem' -not -name '*-key.pem' 2>/dev/null | wc -l | tr -d ' ')"
		print_info "Cert directory: $CERTS_DIR ($cert_count cert(s))"

		ensure_ports_file
		if command -v jq >/dev/null 2>&1; then
			local app_names
			app_names="$(jq -r '.apps | keys[]' "$PORTS_FILE" 2>/dev/null)"
			if [[ -n "$app_names" ]]; then
				while IFS= read -r app_name; do
					[[ -z "$app_name" ]] && continue
					local cert_st
					cert_st="$(check_cert_status "$app_name")"
					case "$cert_st" in
					ok)
						print_success "  ${app_name}.local: cert + key present"
						;;
					partial)
						print_warning "  ${app_name}.local: cert or key missing (incomplete)"
						;;
					missing)
						print_warning "  ${app_name}.local: no cert files found"
						;;
					esac
				done <<<"$app_names"
			fi
		fi
	else
		print_warning "Cert directory not found: $CERTS_DIR"
	fi
	return 0
}

# Print port health section for cmd_status
_cmd_status_ports() {
	echo "--- Port health ---"
	ensure_ports_file
	if command -v jq >/dev/null 2>&1; then
		local apps_ports
		apps_ports="$(jq -r '.apps | to_entries[] | "\(.key)\t\(.value.port)"' "$PORTS_FILE" 2>/dev/null)"
		if [[ -n "$apps_ports" ]]; then
			while IFS=$'\t' read -r app_name app_port; do
				[[ -z "$app_name" ]] && continue
				# Reset IFS to default before $() calls — prevents zsh IFS leak corrupting PATH lookup
				local health proc_name _saved_ifs="$IFS"
				IFS=$' \t\n'
				health="$(check_port_health "$app_port")"
				proc_name="$(get_port_process "$app_port")"
				IFS="$_saved_ifs"
				if [[ "$health" == "up" ]]; then
					print_success "  $app_name (port $app_port): listening (${proc_name:-unknown})"
				else
					print_info "  $app_name (port $app_port): not listening"
				fi
			done <<<"$apps_ports"
		else
			print_info "  No apps registered"
		fi
	fi
	return 0
}

# Print LocalWP coexistence section for cmd_status
_cmd_status_localwp() {
	echo "--- LocalWP ---"
	if [[ -f "$LOCALWP_SITES_JSON" ]]; then
		local lwp_count
		if command -v jq >/dev/null 2>&1; then
			lwp_count="$(jq 'length' "$LOCALWP_SITES_JSON" 2>/dev/null || echo "0")"
		else
			lwp_count="$(python3 -c "import json; print(len(json.load(open('$LOCALWP_SITES_JSON'))))" 2>/dev/null || echo "0")"
		fi
		print_info "LocalWP sites.json: $lwp_count site(s)"
		print_info "  Path: $LOCALWP_SITES_JSON"
	else
		print_info "LocalWP sites.json not found"
	fi

	local hosts_count
	hosts_count="$(safe_grep_count '#Local Site' /etc/hosts)"
	if [[ "$hosts_count" -gt 0 ]]; then
		print_info "LocalWP /etc/hosts entries: $hosts_count"
	fi
	return 0
}

# Print Shared Postgres section for cmd_status
_cmd_status_postgres() {
	echo "--- Shared Postgres ---"
	if pg_container_running; then
		print_success "$LOCALDEV_PG_CONTAINER: running (port $LOCALDEV_PG_PORT)"
	elif pg_container_exists; then
		print_warning "$LOCALDEV_PG_CONTAINER: stopped"
	else
		print_info "$LOCALDEV_PG_CONTAINER: not created"
	fi
	return 0
}

cmd_status() {
	print_info "localdev status — infrastructure health"
	echo ""

	_cmd_status_dnsmasq

	echo ""
	_cmd_status_traefik

	echo ""
	_cmd_status_certs

	echo ""
	_cmd_status_ports

	echo ""
	_cmd_status_localwp

	echo ""
	_cmd_status_postgres

	return 0
}
