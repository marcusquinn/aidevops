#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# localdev-helper-ports.sh -- Port registry, project name inference, and certs
# =============================================================================
# Manages the port registry (ports.json), project name inference, collision
# detection, domain helpers, and mkcert certificate generation/removal.
#
# Usage: source "${SCRIPT_DIR}/localdev-helper-ports.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - ensure_mkcert() from localdev-helper-init.sh
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LOCALDEV_PORTS_LIB_LOADED:-}" ]] && return 0
_LOCALDEV_PORTS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (caller may not set it)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Project Name Inference
# =============================================================================
# Infer a localdev-compatible project name from the current directory.
# Priority: 1) package.json "name" field, 2) git repo basename.
# Sanitises to lowercase alphanumeric + hyphens (localdev add requirement).

# Infer project name from the current directory or a given path.
# Outputs a sanitised name suitable for localdev add.
infer_project_name() {
	local dir="${1:-.}"
	local name=""

	# Try package.json "name" field first (most explicit signal)
	if [[ -f "$dir/package.json" ]]; then
		if command -v jq >/dev/null 2>&1; then
			name="$(jq -r '.name // empty' "$dir/package.json" 2>/dev/null)"
		else
			# Fallback: grep-based extraction
			name="$(grep -m1 '"name"' "$dir/package.json" 2>/dev/null | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
		fi
		# Strip npm scope prefix (@org/name -> name)
		name="${name##*/}"
	fi

	# Fallback: git repo basename (strip worktree suffix)
	if [[ -z "$name" ]]; then
		local repo_root=""
		if [[ -d "$dir/.git" ]] || [[ -f "$dir/.git" ]]; then
			repo_root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
		fi
		if [[ -n "$repo_root" ]]; then
			name="$(basename "$repo_root")"
			# If this is a worktree, get the main repo name
			if [[ -f "$repo_root/.git" ]]; then
				local main_worktree
				main_worktree="$(git -C "$repo_root" worktree list --porcelain 2>/dev/null | head -1 | cut -d' ' -f2-)"
				if [[ -n "$main_worktree" ]]; then
					name="$(basename "$main_worktree")"
				fi
			fi
		else
			# Last resort: directory basename
			name="$(basename "$(cd "$dir" && pwd)")"
		fi
	fi

	# Sanitise: lowercase, replace non-alphanumeric with hyphens, collapse, trim
	name="$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//')"

	if [[ -z "$name" ]]; then
		return 1
	fi

	echo "$name"
	return 0
}

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

# Serialise ports.json read-modify-write (GH#33970). Concurrent worker
# worktree creation previously read the same snapshot, assigned the same
# port, and the last writer won. mkdir is atomic; the lock mirrors the
# serve launch lock in localdev-helper-serve.sh.
LOCALDEV_REGISTRY_LOCK_WAIT_SECS="${LOCALDEV_REGISTRY_LOCK_WAIT_SECS:-30}"
LOCALDEV_REGISTRY_LOCK_HELD=""

# Return 0 when a path's mtime is at least $2 seconds old.
_localdev_registry_path_older_than() {
	local path="$1"
	local min_age="$2"
	local modified_at=""
	modified_at="$(_file_mtime_epoch "$path")" || return 1
	[[ "$modified_at" =~ ^[0-9]+$ ]] || return 1
	[[ $(($(date +%s) - modified_at)) -ge "$min_age" ]] || return 1
	return 0
}

# Reclaim a lock whose recorded holder is dead. A just-created lock without a
# PID is left alone until its owner had time to record itself. Reclaimers
# serialise on a separate guard: while it is held, a stale lock cannot be
# replaced (mkdir fails and its dead owner never removes it), so validation
# and removal cannot hit a lock that a new owner acquired in between.
_localdev_registry_remove_stale_lock() {
	local lock_dir="$1"
	local guard="${lock_dir}.reclaim"
	local holder_pid=""
	local rc=1
	if ! mkdir "$guard" 2>/dev/null; then
		# A reclaimer that died inside the microsecond critical section.
		_localdev_registry_path_older_than "$guard" 10 && rmdir "$guard" 2>/dev/null
		return 1
	fi
	[[ -f "$lock_dir/pid" ]] && IFS= read -r holder_pid <"$lock_dir/pid" || true
	if [[ -d "$lock_dir" ]] &&
		! { [[ "$holder_pid" =~ ^[0-9]+$ ]] && kill -0 "$holder_pid" 2>/dev/null; } &&
		_localdev_registry_path_older_than "$lock_dir" 5; then
		rm -f -- "$lock_dir/pid"
		rmdir "$lock_dir" 2>/dev/null && rc=0
	fi
	rmdir "$guard" 2>/dev/null || true
	return "$rc"
}

# Acquire the registry lock (re-entrant within one process).
localdev_registry_lock() {
	local lock_dir="${PORTS_FILE}.lock"
	local attempts=$((LOCALDEV_REGISTRY_LOCK_WAIT_SECS * 4))
	local attempt=0
	[[ -n "$LOCALDEV_REGISTRY_LOCK_HELD" ]] && return 0
	ensure_ports_file
	while [[ "$attempt" -lt "$attempts" ]]; do
		if mkdir "$lock_dir" 2>/dev/null; then
			if ! printf '%s\n' "$$" >"$lock_dir/pid"; then
				rmdir "$lock_dir" 2>/dev/null || true
				print_error "Unable to record port registry lock owner: $lock_dir"
				return 1
			fi
			LOCALDEV_REGISTRY_LOCK_HELD="$lock_dir"
			trap 'localdev_registry_unlock' EXIT
			return 0
		fi
		if [[ -L "$lock_dir" || (-e "$lock_dir" && ! -d "$lock_dir") ]]; then
			print_error "Refusing invalid port registry lock path: $lock_dir"
			return 1
		fi
		_localdev_registry_remove_stale_lock "$lock_dir" || true
		sleep 0.25
		attempt=$((attempt + 1))
	done
	print_error "Timed out waiting for port registry lock: $lock_dir"
	return 1
}

# Release the registry lock if this process holds it.
localdev_registry_unlock() {
	local lock_dir="$LOCALDEV_REGISTRY_LOCK_HELD"
	[[ -n "$lock_dir" ]] || return 0
	LOCALDEV_REGISTRY_LOCK_HELD=""
	trap - EXIT
	rm -f -- "$lock_dir/pid"
	rmdir "$lock_dir" 2>/dev/null || true
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
		[[ -n "$result" ]]
	else
		# Fallback: grep-based check
		echo "$registry" | grep -q "\"$name\""
	fi
	return $?
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
		[[ "$result" -gt 0 ]]
	else
		echo "$registry" | grep -q "\"port\": *$port"
	fi
	return $?
}

# Check if a port is in use by the OS
is_port_in_use() {
	local port="$1"
	lsof -i ":$port" >/dev/null 2>&1
	return $?
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
	print_info "  Stale branch registrations from removed worktrees hold ports. Reclaim them:"
	print_info "  localdev-helper.sh branch prune --repo <canonical-repo-path> [--dry-run]"
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
	get_localwp_domains | grep -qx "$domain"
	return $?
}

# Check if a domain is already registered in our port registry
is_domain_registered() {
	local domain="$1"
	local registry
	registry="$(read_ports_registry)"
	if command -v jq >/dev/null 2>&1; then
		local result
		result="$(echo "$registry" | jq -r --arg d "$domain" '[.apps[] | select(.domain == $d)] | length')"
		[[ "$result" -gt 0 ]]
	else
		echo "$registry" | grep -q "\"$domain\""
	fi
	return $?
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

	if [[ "$collision" -ne 0 ]]; then
		return 1
	fi
	return 0
}

# =============================================================================
# Certificate Generation
# =============================================================================

# Generate mkcert wildcard cert for a domain
# Creates: ~/.local-ssl-certs/{name}.local+1.pem and {name}.local+1-key.pem
generate_cert() {
	local name="$1"
	local domain="${name}.local"
	local wildcard="*.${domain}"

	# Ensure mkcert is available (auto-install if missing, GH#6415)
	if ! command -v mkcert >/dev/null 2>&1 && ! ensure_mkcert; then
		print_error "mkcert is required to generate SSL certificates"
		return 1
	fi

	mkdir -p "$CERTS_DIR"

	print_info "Generating mkcert wildcard cert for $wildcard and $domain..."

	# mkcert generates files named after the first domain arg
	# Output: {domain}+1.pem and {domain}+1-key.pem (wildcard is second arg)
	(cd "$CERTS_DIR" && run_stable_mkcert "$domain" "$wildcard")

	# Verify cert was created
	local cert_file="$CERTS_DIR/${domain}+1.pem"
	local key_file="$CERTS_DIR/${domain}+1-key.pem"

	if [[ ! -f "$cert_file" ]] || [[ ! -f "$key_file" ]]; then
		print_error "mkcert failed to generate cert files"
		print_info "  Expected: $cert_file"
		print_info "  Expected: $key_file"
		return 1
	fi

	print_success "Generated cert: $cert_file"
	print_success "Generated key:  $key_file"
	return 0
}

# Remove mkcert cert files for a domain
remove_cert() {
	local name="$1"
	local domain="${name}.local"
	local cert_file="$CERTS_DIR/${domain}+1.pem"
	local key_file="$CERTS_DIR/${domain}+1-key.pem"

	local removed=0
	if [[ -f "$cert_file" ]]; then
		rm -f "$cert_file"
		print_success "Removed cert: $cert_file"
		removed=1
	fi
	if [[ -f "$key_file" ]]; then
		rm -f "$key_file"
		print_success "Removed key:  $key_file"
		removed=1
	fi

	if [[ "$removed" -eq 0 ]]; then
		print_info "No cert files found for $domain (already removed?)"
	fi
	return 0
}
