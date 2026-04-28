#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# localdev-helper-branch.sh -- Branch subdomain routing for worktrees
# =============================================================================
# Creates branch-specific subdomain routes: feature-xyz.myapp.local
# Reuses the wildcard cert from `localdev add` (*.myapp.local).
# Port registry tracks branch->port mappings per project in ports.json.
#
# Usage: source "${SCRIPT_DIR}/localdev-helper-branch.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - localdev-helper-ports.sh (is_app_registered, read_ports_registry, ensure_ports_file,
#                                assign_port, is_port_registered, is_port_in_use,
#                                is_localwp_domain, PORT_RANGE_START, PORT_RANGE_END)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LOCALDEV_BRANCH_LIB_LOADED:-}" ]] && return 0
_LOCALDEV_BRANCH_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (caller may not set it)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Branch Command — Subdomain routing for worktrees/branches
# =============================================================================

# Sanitise branch name for use in domains and Traefik router names
# Converts slashes to hyphens, strips invalid chars, lowercases
sanitise_branch_name() {
	local branch="$1"
	echo "$branch" | tr '[:upper:]' '[:lower:]' | sed 's|/|-|g; s|[^a-z0-9-]||g; s|--*|-|g; s|^-||; s|-$||'
	return 0
}

# Check if a branch is registered for an app
is_branch_registered() {
	local app="$1"
	local branch="$2"
	local registry
	registry="$(read_ports_registry)"
	if command -v jq >/dev/null 2>&1; then
		local result
		result="$(echo "$registry" | jq -r --arg a "$app" --arg b "$branch" '.apps[$a].branches[$b] // empty')"
		[[ -n "$result" ]]
	else
		echo "$registry" | grep -q "\"$branch\""
	fi
	return $?
}

# Get port for a registered branch
get_branch_port() {
	local app="$1"
	local branch="$2"
	local registry
	registry="$(read_ports_registry)"
	if command -v jq >/dev/null 2>&1; then
		echo "$registry" | jq -r --arg a "$app" --arg b "$branch" '.apps[$a].branches[$b].port // empty'
	else
		echo "$registry" | grep -A5 "\"$branch\"" | grep '"port"' | head -1 | sed 's/.*: *\([0-9]*\).*/\1/'
	fi
	return 0
}

# Register a branch in ports.json under its parent app
register_branch() {
	local app="$1"
	local branch="$2"
	local port="$3"
	local subdomain="$4"
	local added
	added="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	ensure_ports_file

	if command -v jq >/dev/null 2>&1; then
		local tmp
		tmp="$(mktemp)"
		jq --arg a "$app" --arg b "$branch" --argjson p "$port" --arg s "$subdomain" --arg d "$added" \
			'.apps[$a].branches //= {} | .apps[$a].branches[$b] = {"port": $p, "subdomain": $s, "added": $d}' \
			"$PORTS_FILE" >"$tmp" && mv "$tmp" "$PORTS_FILE"
	else
		python3 - "$PORTS_FILE" "$app" "$branch" "$port" "$subdomain" "$added" <<'PYEOF'
import sys, json
f, app, branch, port, subdomain, added = sys.argv[1:]
with open(f) as fh:
    data = json.load(fh)
if 'branches' not in data['apps'][app]:
    data['apps'][app]['branches'] = {}
data['apps'][app]['branches'][branch] = {
    'port': int(port), 'subdomain': subdomain, 'added': added
}
with open(f, 'w') as fh:
    json.dump(data, fh, indent=2)
PYEOF
	fi
	return 0
}

# Remove a branch from ports.json
deregister_branch() {
	local app="$1"
	local branch="$2"

	ensure_ports_file

	if command -v jq >/dev/null 2>&1; then
		local tmp
		tmp="$(mktemp)"
		jq --arg a "$app" --arg b "$branch" 'del(.apps[$a].branches[$b])' \
			"$PORTS_FILE" >"$tmp" && mv "$tmp" "$PORTS_FILE"
	else
		python3 - "$PORTS_FILE" "$app" "$branch" <<'PYEOF'
import sys, json
f, app, branch = sys.argv[1:]
with open(f) as fh:
    data = json.load(fh)
data['apps'].get(app, {}).get('branches', {}).pop(branch, None)
with open(f, 'w') as fh:
    json.dump(data, fh, indent=2)
PYEOF
	fi
	return 0
}

# Create Traefik conf.d route for a branch subdomain
# Reuses the parent app's wildcard cert — no new cert generation needed
create_branch_traefik_route() {
	local app="$1"
	local branch="$2"
	local port="$3"
	local subdomain="$4"
	local app_domain="${app}.local"
	local route_name="${app}--${branch}"
	local route_file="$CONFD_DIR/${route_name}.yml"

	mkdir -p "$CONFD_DIR"

	cat >"$route_file" <<YAML
http:
  routers:
    ${route_name}:
      rule: "Host(\`${subdomain}\`)"
      entryPoints:
        - websecure
      service: ${route_name}
      tls: {}
      priority: 100

  services:
    ${route_name}:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:${port}"
        responseForwarding:
          flushInterval: "100ms"
        serversTransport: "default@internal"

tls:
  certificates:
    - certFile: /certs/${app_domain}+1.pem
      keyFile: /certs/${app_domain}+1-key.pem
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
	print_success "Created branch route: $route_file"
	return 0
}

# Remove Traefik conf.d route for a branch
remove_branch_traefik_route() {
	local app="$1"
	local branch="$2"
	local route_name="${app}--${branch}"
	local route_file="$CONFD_DIR/${route_name}.yml"

	if [[ -f "$route_file" ]]; then
		rm -f "$route_file"
		print_success "Removed branch route: $route_file"
	else
		print_info "No branch route file found for $route_name (already removed?)"
	fi
	return 0
}

# Remove all branch routes and registry entries for an app
remove_all_branches() {
	local app="$1"
	local registry
	registry="$(read_ports_registry)"

	if command -v jq >/dev/null 2>&1; then
		local branches
		branches="$(echo "$registry" | jq -r --arg a "$app" '.apps[$a].branches // {} | keys[]' 2>/dev/null)"
		if [[ -n "$branches" ]]; then
			while IFS= read -r branch; do
				remove_branch_traefik_route "$app" "$branch"
			done <<<"$branches"
			# Clear all branches from registry
			local tmp
			tmp="$(mktemp)"
			jq --arg a "$app" '.apps[$a].branches = {}' "$PORTS_FILE" >"$tmp" && mv "$tmp" "$PORTS_FILE"
			print_success "Removed all branch entries for $app from registry"
		fi
	else
		# Fallback: remove route files matching the pattern
		local pattern="$CONFD_DIR/${app}--*.yml"
		local files
		# shellcheck disable=SC2086 # glob pattern must be word-split by ls
		files="$(ls $pattern 2>/dev/null || true)"
		if [[ -n "$files" ]]; then
			echo "$files" | while IFS= read -r f; do
				rm -f "$f"
				print_success "Removed branch route: $f"
			done
		fi
	fi
	return 0
}

# Route cmd_branch subcommands (rm, list, help).
# Returns 0 if a subcommand was matched (caller should return immediately),
# returns 1 if no subcommand matched (caller should continue with add logic).
# Sets _BRANCH_SUBCMD_EXIT to the exit code of the dispatched subcommand.
_cmd_branch_route_subcmd() {
	local subcmd="$1"
	local app="$2"
	local branch_raw="$3"
	_BRANCH_SUBCMD_EXIT=0
	case "$subcmd" in
	rm | remove)
		cmd_branch_rm "$app" "$branch_raw"
		_BRANCH_SUBCMD_EXIT=$?
		return 0
		;;
	list | ls)
		cmd_branch_list "$app"
		_BRANCH_SUBCMD_EXIT=$?
		return 0
		;;
	help | -h | --help)
		cmd_branch_help
		_BRANCH_SUBCMD_EXIT=0
		return 0
		;;
	esac
	return 1
}

# Validate branch add prerequisites (app registered, branch not duplicate, no LocalWP collision)
# Args: app branch subdomain
_cmd_branch_validate() {
	local app="$1"
	local branch="$2"
	local subdomain="$3"

	if ! is_app_registered "$app"; then
		print_error "App '$app' is not registered. Register it first:"
		print_info "  localdev-helper.sh add $app"
		exit 1
	fi

	if is_branch_registered "$app" "$branch"; then
		local existing_port
		existing_port="$(get_branch_port "$app" "$branch")"
		print_error "Branch '$branch' is already registered for '$app' on port $existing_port"
		print_info "  Remove first: localdev-helper.sh branch rm $app $branch"
		exit 1
	fi

	if is_localwp_domain "$subdomain"; then
		print_error "Subdomain '$subdomain' is already used by LocalWP"
		exit 1
	fi
	return 0
}

# Assign port for a branch; outputs port to stdout
# Args: port_arg (may be empty for auto-assign)
_cmd_branch_assign_port() {
	local port_arg="$1"
	local port=""
	if [[ -n "$port_arg" ]]; then
		port="$port_arg"
		if ! echo "$port" | grep -qE '^[0-9]+$'; then
			print_error "Invalid port '$port': must be a number"
			exit 1
		fi
		if is_port_registered "$port"; then
			print_error "Port $port is already registered in port registry"
			exit 1
		fi
		if is_port_in_use "$port"; then
			print_warning "Port $port is currently in use by another process"
		fi
	else
		print_info "Auto-assigning port from range $PORT_RANGE_START-$PORT_RANGE_END..."
		port="$(assign_port)" || exit 1
		print_success "Assigned port: $port"
	fi
	echo "$port"
	return 0
}

cmd_branch() {
	local subcmd="${1:-}"
	local app="${2:-}"
	local branch_raw="${3:-}"
	local port_arg="${4:-}"

	# Handle subcommands: branch rm, branch list, branch help
	_BRANCH_SUBCMD_EXIT=0
	if _cmd_branch_route_subcmd "$subcmd" "$app" "$branch_raw"; then
		return "$_BRANCH_SUBCMD_EXIT"
	fi

	# Default: branch add <app> <branch> [port]
	# If subcmd looks like an app name (not a known subcommand), shift args
	if [[ -n "$subcmd" ]] && [[ "$subcmd" != "add" ]]; then
		# subcmd is actually the app name
		port_arg="$branch_raw"
		branch_raw="$app"
		app="$subcmd"
	elif [[ "$subcmd" == "add" ]]; then
		: # args are already correct
	fi

	if [[ -z "$app" ]] || [[ -z "$branch_raw" ]]; then
		print_error "Usage: localdev-helper.sh branch <app> <branch> [port]"
		print_info "  app:    registered app name (e.g., myapp)"
		print_info "  branch: branch/worktree name (e.g., feature-xyz, feature/login)"
		print_info "  port:   optional port (auto-assigned if omitted)"
		echo ""
		print_info "Subcommands:"
		print_info "  branch rm <app> <branch>   Remove a branch route"
		print_info "  branch list [app]          List branch routes"
		exit 1
	fi

	# Sanitise branch name for DNS/Traefik compatibility
	local branch
	branch="$(sanitise_branch_name "$branch_raw")"
	if [[ "$branch" != "$branch_raw" ]]; then
		print_info "Sanitised branch name: '$branch_raw' → '$branch'"
	fi

	if [[ -z "$branch" ]]; then
		print_error "Branch name '$branch_raw' is invalid (empty after sanitisation)"
		exit 1
	fi

	local subdomain="${branch}.${app}.local"

	print_info "localdev branch $app $branch ($subdomain)"
	echo ""

	# Steps 1–3: Validate prerequisites
	_cmd_branch_validate "$app" "$branch" "$subdomain"

	# Step 4: Assign port
	local port
	port="$(_cmd_branch_assign_port "$port_arg")"

	# Step 5: Verify parent cert exists (wildcard from `add` covers subdomains)
	local cert_file="$CERTS_DIR/${app}.local+1.pem"
	if [[ ! -f "$cert_file" ]]; then
		print_error "Wildcard cert not found: $cert_file"
		print_info "  The parent app cert covers *.${app}.local subdomains"
		print_info "  Re-run: localdev-helper.sh add $app"
		exit 1
	fi

	# Step 6: Create Traefik route for branch subdomain
	create_branch_traefik_route "$app" "$branch" "$port" "$subdomain" || exit 1

	# Step 7: Register branch in port registry
	register_branch "$app" "$branch" "$port" "$subdomain" || exit 1

	# Step 8: Traefik auto-reload
	if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^local-traefik$'; then
		print_info "Traefik is running — conf.d watch will pick up new route automatically"
	else
		print_info "Traefik not running. Start with:"
		print_info "  cd $LOCALDEV_DIR && docker compose up -d"
	fi

	echo ""
	print_success "localdev branch complete: $branch.$app"
	echo ""
	print_info "  Subdomain: https://$subdomain"
	print_info "  Port:      $port (branch app should listen on this port)"
	print_info "  Route:     $CONFD_DIR/${app}--${branch}.yml"
	print_info "  Cert:      $cert_file (wildcard, shared with parent)"
	return 0
}

cmd_branch_rm() {
	local app="${1:-}"
	local branch_raw="${2:-}"

	if [[ -z "$app" ]] || [[ -z "$branch_raw" ]]; then
		print_error "Usage: localdev-helper.sh branch rm <app> <branch>"
		exit 1
	fi

	local branch
	branch="$(sanitise_branch_name "$branch_raw")"

	print_info "localdev branch rm $app $branch"
	echo ""

	if ! is_branch_registered "$app" "$branch"; then
		print_warning "Branch '$branch' is not registered for app '$app'"
		print_info "  Attempting cleanup of any leftover files..."
	fi

	# Remove Traefik route
	remove_branch_traefik_route "$app" "$branch"

	# Deregister from port registry
	deregister_branch "$app" "$branch"
	print_success "Removed branch '$branch' from $app registry"

	echo ""
	print_success "localdev branch rm complete: $branch.$app"
	return 0
}

cmd_branch_list() {
	local app="${1:-}"

	ensure_ports_file

	if [[ -n "$app" ]]; then
		# List branches for a specific app
		if ! is_app_registered "$app"; then
			print_error "App '$app' is not registered"
			exit 1
		fi

		print_info "Branches for $app:"
		echo ""

		if command -v jq >/dev/null 2>&1; then
			local count
			count="$(jq -r --arg a "$app" '.apps[$a].branches // {} | length' "$PORTS_FILE")"
			if [[ "$count" -eq 0 ]]; then
				print_info "  No branches registered. Use: localdev-helper.sh branch $app <branch>"
				return 0
			fi
			jq -r --arg a "$app" '.apps[$a].branches // {} | to_entries[] | "  \(.key)\t\(.value.subdomain)\tport:\(.value.port)\tadded:\(.value.added)"' "$PORTS_FILE"
		else
			python3 - "$PORTS_FILE" "$app" <<'PYEOF'
import sys, json
f, app = sys.argv[1:]
with open(f) as fh:
    data = json.load(fh)
branches = data.get('apps', {}).get(app, {}).get('branches', {})
if not branches:
    print("  No branches registered.")
else:
    for name, info in branches.items():
        print(f"  {name}\t{info['subdomain']}\tport:{info['port']}\tadded:{info['added']}")
PYEOF
		fi
	else
		# List all branches across all apps
		print_info "All branch routes:"
		echo ""

		if command -v jq >/dev/null 2>&1; then
			local has_branches=0
			local apps
			apps="$(jq -r '.apps | keys[]' "$PORTS_FILE")"
			while IFS= read -r a; do
				[[ -z "$a" ]] && continue
				local bcount
				bcount="$(jq -r --arg a "$a" '.apps[$a].branches // {} | length' "$PORTS_FILE")"
				if [[ "$bcount" -gt 0 ]]; then
					has_branches=1
					echo "  $a:"
					jq -r --arg a "$a" '.apps[$a].branches // {} | to_entries[] | "    \(.key)\t\(.value.subdomain)\tport:\(.value.port)"' "$PORTS_FILE"
				fi
			done <<<"$apps"
			if [[ "$has_branches" -eq 0 ]]; then
				print_info "  No branches registered for any app."
			fi
		else
			python3 - "$PORTS_FILE" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
found = False
for app, info in data.get('apps', {}).items():
    branches = info.get('branches', {})
    if branches:
        found = True
        print(f"  {app}:")
        for name, binfo in branches.items():
            print(f"    {name}\t{binfo['subdomain']}\tport:{binfo['port']}")
if not found:
    print("  No branches registered for any app.")
PYEOF
		fi
	fi
	return 0
}

cmd_branch_help() {
	echo "localdev branch — Subdomain routing for worktrees/branches"
	echo ""
	echo "Usage: localdev-helper.sh branch <app> <branch> [port]"
	echo "       localdev-helper.sh branch rm <app> <branch>"
	echo "       localdev-helper.sh branch list [app]"
	echo ""
	echo "Creates branch-specific subdomain routes:"
	echo "  localdev branch myapp feature-xyz       → feature-xyz.myapp.local"
	echo "  localdev branch myapp feature/login 3200 → feature-login.myapp.local:3200"
	echo ""
	echo "Branch names are sanitised for DNS: slashes → hyphens, lowercase, alphanumeric."
	echo ""
	echo "Performs:"
	echo "  1. Verify parent app is registered (must run 'add' first)"
	echo "  2. Sanitise branch name for DNS compatibility"
	echo "  3. Auto-assign port from $PORT_RANGE_START-$PORT_RANGE_END (or use specified)"
	echo "  4. Create Traefik conf.d/{app}--{branch}.yml route"
	echo "  5. Register branch in ports.json under parent app"
	echo ""
	echo "No new cert needed — wildcard cert from 'add' covers *.app.local subdomains."
	echo ""
	echo "Subcommands:"
	echo "  branch rm <app> <branch>   Remove branch route and registry entry"
	echo "  branch list [app]          List branches (all apps or specific app)"
	echo "  branch help                Show this help"
	return 0
}
