#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# localdev-ports-lib.sh -- Port registry and collision detection
# =============================================================================
# Manages the port registry at ~/.local-dev-proxy/ports.json.
# Handles port assignment, app/domain registration, and LocalWP collision detection.
#
# Usage: source "${SCRIPT_DIR}/localdev-ports-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - localdev-helper.sh exports: PORTS_FILE, LOCALDEV_DIR
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LOCALDEV_PORTS_LIB_LOADED:-}" ]] && return 0
_LOCALDEV_PORTS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (in case sourced without the orchestrator)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Port Registry Helpers
# =============================================================================
# Port registry: ~/.local-dev-proxy/ports.json
# Format: { "apps": { "myapp": { "port": 3100, "domain": "myapp.local", "added": "ISO" } } }

PORT_RANGE_START=3100
PORT_RANGE_END=3999

# Ensure ports.json exists with valid structure
ensure_ports_file() {
	mkdir -p "$LOCALDEV_DIR"
	if [[ ! -f "$PORTS_FILE" ]]; then
		echo '{"apps":{}}' >"$PORTS_FILE"
	fi
	return 0
}

# Read the ports registry (outputs JSON)
read_ports_registry() {
	ensure_ports_file
	cat "$PORTS_FILE"
	return 0
}

# Check if an app name is already registered
is_app_registered() {
	local name="$1"
	local registry
	registry="$(read_ports_registry)"
	if command -v jq >/dev/null 2>&1; then
		local result
		result="$(echo "$registry" | jq -r --arg n "$name" '.apps[$n] // empty')"
		if [[ -n "$result" ]]; then return 0; else return 1; fi
	else
		# Fallback: grep-based check
		echo "$registry" | grep -q "\"$name\"" && return 0 || return 1
	fi
}

# Get port for a registered app
get_app_port() {
	local name="$1"
	local registry
	registry="$(read_ports_registry)"
	if command -v jq >/dev/null 2>&1; then
		echo "$registry" | jq -r --arg n "$name" '.apps[$n].port // empty'
	else
		# Fallback: grep + sed
		echo "$registry" | grep -A3 "\"$name\"" | grep '"port"' | sed 's/.*: *\([0-9]*\).*/\1/'
	fi
	return 0
}

# Check if a port is already in use in the registry (apps + branches)
is_port_registered() {
	local port="$1"
	local registry
	registry="$(read_ports_registry)"
	if command -v jq >/dev/null 2>&1; then
		local result
		result="$(echo "$registry" | jq -r --argjson p "$port" \
			'[.apps[] | (select(.port == $p)), (.branches // {} | .[] | select(.port == $p))] | length')"
		if [[ "$result" -gt 0 ]]; then return 0; else return 1; fi
	else
		echo "$registry" | grep -q "\"port\": *$port" && return 0 || return 1
	fi
}

# Check if a port is in use by the OS
is_port_in_use() {
	local port="$1"
	lsof -i ":$port" >/dev/null 2>&1 && return 0 || return 1
}

# Auto-assign next available port in 3100-3999 range
# Optimised: single lsof batch query + single registry read replaces
# up to 900 per-port lsof calls (t2261).
assign_port() {
	# 1. Read the registry ONCE, extract all registered ports (apps + branches)
	local registry
	registry="$(read_ports_registry)"
	local registered_ports=""
	if command -v jq >/dev/null 2>&1; then
		registered_ports="$(echo "$registry" | jq -r '
			[.apps[] | .port, (.branches // {} | .[].port)] | .[] | tostring
		' 2>/dev/null)"
	else
		# Fallback: grep all port values from the JSON
		registered_ports="$(echo "$registry" | grep -oE '"port": *[0-9]+' | grep -oE '[0-9]+')"
	fi

	# 2. Batch-query OS listening ports in the range (single lsof call)
	local os_ports=""
	if command -v lsof >/dev/null 2>&1; then
		os_ports="$(lsof -iTCP:"${PORT_RANGE_START}"-"${PORT_RANGE_END}" -sTCP:LISTEN -nP 2>/dev/null \
			| awk 'NR>1{split($9,a,":"); print a[length(a)]}')"
	fi

	# 3. Build a comma-delimited lookup string for O(1) bash pattern matching
	local busy_set
	busy_set=",$(printf '%s\n%s' "$registered_ports" "$os_ports" | sort -un | tr '\n' ','),"

	# 4. Find first available port (pure bash — no process forks in the loop)
	local port="$PORT_RANGE_START"
	while [[ "$port" -le "$PORT_RANGE_END" ]]; do
		case "$busy_set" in
			*",$port,"*) ;; # port is busy, skip
			*) echo "$port"; return 0 ;;
		esac
		port=$((port + 1))
	done
	print_error "No available ports in range $PORT_RANGE_START-$PORT_RANGE_END"
	return 1
}

# Register an app in ports.json
register_app() {
	local name="$1"
	local port="$2"
	local domain="$3"
	local added
	added="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	ensure_ports_file

	if command -v jq >/dev/null 2>&1; then
		local tmp
		tmp="$(mktemp)"
		jq --arg n "$name" --argjson p "$port" --arg d "$domain" --arg a "$added" \
			'.apps[$n] = {"port": $p, "domain": $d, "added": $a}' \
			"$PORTS_FILE" >"$tmp" && mv "$tmp" "$PORTS_FILE"
	else
		# Fallback: Python (available on macOS)
		python3 - "$PORTS_FILE" "$name" "$port" "$domain" "$added" <<'PYEOF'
import sys, json
f, name, port, domain, added = sys.argv[1:]
with open(f) as fh:
    data = json.load(fh)
data['apps'][name] = {'port': int(port), 'domain': domain, 'added': added}
with open(f, 'w') as fh:
    json.dump(data, fh, indent=2)
PYEOF
	fi
	return 0
}

# Remove an app from ports.json
deregister_app() {
	local name="$1"

	ensure_ports_file

	if command -v jq >/dev/null 2>&1; then
		local tmp
		tmp="$(mktemp)"
		jq --arg n "$name" 'del(.apps[$n])' "$PORTS_FILE" >"$tmp" && mv "$tmp" "$PORTS_FILE"
	else
		python3 - "$PORTS_FILE" "$name" <<'PYEOF'
import sys, json
f, name = sys.argv[1:]
with open(f) as fh:
    data = json.load(fh)
data['apps'].pop(name, None)
with open(f, 'w') as fh:
    json.dump(data, fh, indent=2)
PYEOF
	fi
	return 0
}

# =============================================================================
# Collision Detection
# =============================================================================

# Get all LocalWP domains from /etc/hosts
get_localwp_domains() {
	grep '#Local Site' /etc/hosts 2>/dev/null | awk '{print $2}' | sort -u
	return 0
}

# Check if a domain is used by LocalWP
is_localwp_domain() {
	local domain="$1"
	get_localwp_domains | grep -qx "$domain" && return 0 || return 1
}

# Check if a domain is already registered in our port registry
is_domain_registered() {
	local domain="$1"
	local registry
	registry="$(read_ports_registry)"
	if command -v jq >/dev/null 2>&1; then
		local result
		result="$(echo "$registry" | jq -r --arg d "$domain" '[.apps[] | select(.domain == $d)] | length')"
		if [[ "$result" -gt 0 ]]; then return 0; else return 1; fi
	else
		echo "$registry" | grep -q "\"$domain\"" && return 0 || return 1
	fi
}

# Check if a domain is in /etc/hosts (any entry, not just LocalWP)
is_domain_in_hosts() {
	local domain="$1"
	grep -q "^[^#].*[[:space:]]$domain" /etc/hosts 2>/dev/null
	return $?
}

# Full collision check: returns 0 if safe, 1 if collision
check_collision() {
	local name="$1"
	local domain="$2"
	local collision=0

	# Check app name collision in registry
	if is_app_registered "$name"; then
		print_error "App '$name' is already registered in port registry"
		print_info "  Use: localdev-helper.sh rm $name  (to remove first)"
		collision=1
	fi

	# Check domain collision with LocalWP
	if is_localwp_domain "$domain"; then
		print_error "Domain '$domain' is already used by LocalWP"
		print_info "  LocalWP domains take precedence via /etc/hosts"
		collision=1
	fi

	# Check domain collision in our registry
	if is_domain_registered "$domain"; then
		print_error "Domain '$domain' is already registered in port registry"
		collision=1
	fi

	return "$collision"
}
