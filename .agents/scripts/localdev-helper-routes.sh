#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# localdev-helper-routes.sh -- Traefik route files and /etc/hosts management
# =============================================================================
# Creates and removes Traefik conf.d/ route YAML files, manages /etc/hosts
# entries (primary DNS mechanism for .local domains in browsers), and checks
# dnsmasq resolver configuration.
#
# Usage: source "${SCRIPT_DIR}/localdev-helper-routes.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LOCALDEV_ROUTES_LIB_LOADED:-}" ]] && return 0
_LOCALDEV_ROUTES_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (caller may not set it)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Traefik Route File
# =============================================================================

# Create Traefik conf.d/{name}.yml route file
create_traefik_route() {
	local name="$1"
	local port="$2"
	local domain="${name}.local"
	local route_file="$CONFD_DIR/${name}.yml"

	mkdir -p "$CONFD_DIR"

	cat >"$route_file" <<YAML
http:
  routers:
    ${name}:
      rule: "Host(\`${domain}\`) || Host(\`*.${domain}\`)"
      entryPoints:
        - websecure
      service: ${name}
      tls: {}

  services:
    ${name}:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:${port}"
        responseForwarding:
          flushInterval: "100ms"
        serversTransport: "default@internal"

  serversTransports:
    default:
      forwardingTimeouts:
        dialTimeout: "30s"
        responseHeaderTimeout: "30s"

tls:
  certificates:
    - certFile: /certs/${domain}+1.pem
      keyFile: /certs/${domain}+1-key.pem
YAML

	# Validate: reject files containing ANSI escape codes or non-parseable YAML
	if command -v python3 >/dev/null 2>&1; then
		local py_err
		py_err="$(
			python3 - "$route_file" 2>&1 <<'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path, 'rb') as fh:
    raw = fh.read()
if b'\x1b[' in raw:
    print("ANSI escape codes detected")
    sys.exit(1)
try:
    yaml.safe_load(raw)
except yaml.YAMLError as e:
    print(f"YAML parse error: {e}")
    sys.exit(2)
PYEOF
		)"
		local py_exit=$?
		if [[ "$py_exit" -ne 0 ]]; then
			print_error "YAML corruption in $route_file ($py_err) — removing"
			rm -f "$route_file"
			return 1
		fi
	fi
	print_success "Created Traefik route: $route_file"
	return 0
}

# Remove Traefik conf.d/{name}.yml route file
remove_traefik_route() {
	local name="$1"
	local route_file="$CONFD_DIR/${name}.yml"

	if [[ -f "$route_file" ]]; then
		rm -f "$route_file"
		print_success "Removed Traefik route: $route_file"
	else
		print_info "No Traefik route file found for $name (already removed?)"
	fi
	return 0
}

# =============================================================================
# /etc/hosts Entry (Primary DNS for Browsers)
# =============================================================================

# Add /etc/hosts entry for a domain (REQUIRED for .local in browsers)
# macOS reserves .local for mDNS (Bonjour), which intercepts resolution before
# /etc/resolver/local. Only /etc/hosts reliably overrides mDNS for browsers.
add_hosts_entry() {
	local domain="$1"
	local marker="# localdev: $domain"

	# Check if already present
	if grep -q "$marker" /etc/hosts 2>/dev/null; then
		print_info "/etc/hosts entry for $domain already exists — skipping"
		return 0
	fi

	print_info "Adding /etc/hosts entry for $domain (required for browser resolution)..."
	printf '\n127.0.0.1 %s %s # localdev: %s\n' "$domain" "*.$domain" "$domain" | sudo tee -a /etc/hosts >/dev/null
	print_success "Added /etc/hosts entry: 127.0.0.1 $domain *.$domain"
	return 0
}

# Remove /etc/hosts entry for a domain
remove_hosts_entry() {
	local domain="$1"
	local marker="# localdev: $domain"

	if ! grep -q "$marker" /etc/hosts 2>/dev/null; then
		print_info "No /etc/hosts entry found for $domain (already removed?)"
		return 0
	fi

	print_info "Removing /etc/hosts entry for $domain..."
	# Use a temp file to avoid in-place sed issues on macOS
	local tmp
	tmp="$(mktemp)"
	grep -v "$marker" /etc/hosts >"$tmp"
	sudo cp "$tmp" /etc/hosts
	rm -f "$tmp"
	print_success "Removed /etc/hosts entry for $domain"
	return 0
}

# Check if dnsmasq resolver is configured (determines if hosts fallback is needed)
is_dnsmasq_configured() {
	[[ -f "/etc/resolver/local" ]] && grep -q 'nameserver 127.0.0.1' /etc/resolver/local 2>/dev/null
	return $?
}
