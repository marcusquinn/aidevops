#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# localdev - Local development environment manager
# Manages dnsmasq, Traefik conf.d, mkcert certs, and port registry
# for production-like .local domains with HTTPS on port 443.
#
# Coexists with LocalWP: dnsmasq wildcard DNS only resolves domains
# NOT already in /etc/hosts (LocalWP entries take precedence via
# macOS resolver order: /etc/hosts -> /etc/resolver/local -> upstream).

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
# Init Command — One-time system setup
# =============================================================================
# Configures: dnsmasq, /etc/resolver/local, Traefik conf.d migration
# Requires: sudo (for resolver and dnsmasq restart)
# Idempotent: safe to run multiple times

cmd_init() {
	print_info "localdev init — configuring local development environment"
	echo ""

	# Step 1: Check prerequisites
	check_init_prerequisites

	# Step 2: Configure dnsmasq
	configure_dnsmasq

	# Step 3: Create /etc/resolver/local
	configure_resolver

	# Step 4: Migrate Traefik to conf.d directory provider
	migrate_traefik_to_confd

	# Step 5: Restart Traefik container if running
	restart_traefik_if_running

	echo ""
	print_success "localdev init complete"
	print_info "Verify DNS: dig awardsapp.local @127.0.0.1"
	print_info "Verify Traefik: curl -sk https://awardsapp.local"
	return 0
}

# Check that required tools are installed
check_init_prerequisites() {
	local missing=()

	command -v docker >/dev/null 2>&1 || missing+=("docker")
	command -v mkcert >/dev/null 2>&1 || missing+=("mkcert")

	# dnsmasq: check brew installation
	local brew_prefix
	brew_prefix="$(detect_brew_prefix)"
	if [[ -z "$brew_prefix" ]] || [[ ! -f "$brew_prefix/etc/dnsmasq.conf" ]]; then
		if ! command -v dnsmasq >/dev/null 2>&1; then
			missing+=("dnsmasq")
		fi
	fi

	if [[ ${#missing[@]} -gt 0 ]]; then
		print_error "Missing required tools: ${missing[*]}"
		echo "  Install: brew install ${missing[*]}"
		exit 1
	fi

	print_success "Prerequisites OK: docker, mkcert, dnsmasq"
	return 0
}

# Configure dnsmasq with .local wildcard
configure_dnsmasq() {
	local brew_prefix
	brew_prefix="$(detect_brew_prefix)"
	local dnsmasq_conf=""

	# Find dnsmasq.conf
	if [[ -n "$brew_prefix" ]] && [[ -f "$brew_prefix/etc/dnsmasq.conf" ]]; then
		dnsmasq_conf="$brew_prefix/etc/dnsmasq.conf"
	elif [[ -f "/etc/dnsmasq.conf" ]]; then
		dnsmasq_conf="/etc/dnsmasq.conf"
	else
		print_error "Cannot find dnsmasq.conf"
		print_info "Expected at: $brew_prefix/etc/dnsmasq.conf or /etc/dnsmasq.conf"
		return 1
	fi

	print_info "Configuring dnsmasq: $dnsmasq_conf"

	# Check if already configured
	if grep -q 'address=/.local/127.0.0.1' "$dnsmasq_conf" 2>/dev/null; then
		print_info "dnsmasq already has address=/.local/127.0.0.1 — skipping"
	else
		# Append the wildcard rule
		echo "" | sudo tee -a "$dnsmasq_conf" >/dev/null
		echo "# localdev: resolve all .local domains to localhost" | sudo tee -a "$dnsmasq_conf" >/dev/null
		echo "address=/.local/127.0.0.1" | sudo tee -a "$dnsmasq_conf" >/dev/null
		print_success "Added address=/.local/127.0.0.1 to dnsmasq.conf"
	fi

	# Restart dnsmasq
	if [[ "$OSTYPE" == "darwin"* ]]; then
		sudo brew services restart dnsmasq 2>/dev/null || {
			# Fallback: direct launchctl
			sudo launchctl unload /Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist 2>/dev/null || true
			sudo launchctl load /Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist 2>/dev/null || true
		}
		print_success "dnsmasq restarted"
	elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
		sudo systemctl restart dnsmasq
		print_success "dnsmasq restarted"
	fi

	return 0
}

# Create /etc/resolver/local so macOS uses dnsmasq for .local domains
configure_resolver() {
	if [[ "$OSTYPE" != "darwin"* ]]; then
		print_info "Skipping /etc/resolver (not macOS)"
		return 0
	fi

	local resolver_file="/etc/resolver/local"

	if [[ -f "$resolver_file" ]]; then
		local current_content
		current_content="$(cat "$resolver_file")"
		if [[ "$current_content" == "nameserver 127.0.0.1" ]]; then
			print_info "/etc/resolver/local already configured — skipping"
			return 0
		fi
	fi

	sudo mkdir -p /etc/resolver
	echo "nameserver 127.0.0.1" | sudo tee "$resolver_file" >/dev/null
	print_success "Created /etc/resolver/local (nameserver 127.0.0.1)"

	# Note about coexistence with /etc/hosts
	print_info "DNS resolution order: /etc/hosts → /etc/resolver/local → upstream"
	print_info "LocalWP entries in /etc/hosts take precedence over dnsmasq"
	return 0
}

# =============================================================================
# Traefik conf.d Migration
# =============================================================================
# Migrates from single dynamic.yml to conf.d/ directory provider.
# Preserves existing routes (e.g., awardsapp) by splitting into per-app files.

migrate_traefik_to_confd() {
	print_info "Migrating Traefik to conf.d/ directory provider..."

	# Create directories
	mkdir -p "$CONFD_DIR"
	mkdir -p "$BACKUP_DIR"

	# Step 1: Migrate existing dynamic.yml content to conf.d/
	migrate_dynamic_yml

	# Step 2: Update traefik.yml to use directory provider
	update_traefik_static_config

	# Step 3: Update docker-compose.yml to mount conf.d/
	update_docker_compose

	print_success "Traefik migrated to conf.d/ directory provider"
	return 0
}

# Migrate existing dynamic.yml routes into conf.d/ files
migrate_dynamic_yml() {
	local dynamic_yml="$LOCALDEV_DIR/dynamic.yml"

	if [[ ! -f "$dynamic_yml" ]]; then
		print_info "No existing dynamic.yml — starting fresh"
		return 0
	fi

	# Backup original
	local backup_name
	backup_name="dynamic.yml.backup.$(date +%Y%m%d-%H%M%S)"
	cp "$dynamic_yml" "$BACKUP_DIR/$backup_name"
	print_info "Backed up dynamic.yml to $BACKUP_DIR/$backup_name"

	# Check if awardsapp route exists in dynamic.yml
	if grep -q 'awardsapp' "$dynamic_yml" 2>/dev/null; then
		# Extract and create awardsapp conf.d file
		if [[ ! -f "$CONFD_DIR/awardsapp.yml" ]]; then
			create_awardsapp_confd
			print_success "Migrated awardsapp route to conf.d/awardsapp.yml"
		else
			print_info "conf.d/awardsapp.yml already exists — skipping migration"
		fi
	fi

	return 0
}

# Create the awardsapp conf.d file from the known existing config
create_awardsapp_confd() {
	cat >"$CONFD_DIR/awardsapp.yml" <<'YAML'
http:
  routers:
    awardsapp:
      rule: "Host(`awardsapp.local`)"
      entryPoints:
        - websecure
      service: awardsapp
      tls: {}

  services:
    awardsapp:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:3100"
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
    - certFile: /certs/awardsapp.local+1.pem
      keyFile: /certs/awardsapp.local+1-key.pem
YAML
	return 0
}

# Update traefik.yml to use directory provider instead of single file
update_traefik_static_config() {
	if [[ ! -f "$TRAEFIK_STATIC" ]]; then
		print_info "Creating new traefik.yml with conf.d/ provider"
		write_traefik_static
		return 0
	fi

	# Check if already using directory provider
	if grep -q 'directory:' "$TRAEFIK_STATIC" 2>/dev/null; then
		print_info "traefik.yml already uses directory provider — skipping"
		return 0
	fi

	# Backup and rewrite
	local backup_name
	backup_name="traefik.yml.backup.$(date +%Y%m%d-%H%M%S)"
	cp "$TRAEFIK_STATIC" "$BACKUP_DIR/$backup_name"
	print_info "Backed up traefik.yml to $BACKUP_DIR/$backup_name"

	write_traefik_static
	print_success "Updated traefik.yml to use conf.d/ directory provider"
	return 0
}

# Write the traefik.yml static config
write_traefik_static() {
	cat >"$TRAEFIK_STATIC" <<'YAML'
api:
  dashboard: true
  insecure: true

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

providers:
  docker:
    exposedByDefault: false
  file:
    directory: /etc/traefik/conf.d
    watch: true
YAML
	return 0
}

# Update docker-compose.yml to mount conf.d/ directory
update_docker_compose() {
	if [[ ! -f "$DOCKER_COMPOSE" ]]; then
		print_info "Creating new docker-compose.yml"
		write_docker_compose
		return 0
	fi

	# Check if already mounting conf.d
	if grep -q 'conf.d' "$DOCKER_COMPOSE" 2>/dev/null; then
		print_info "docker-compose.yml already mounts conf.d/ — skipping"
		return 0
	fi

	# Backup and rewrite
	local backup_name
	backup_name="docker-compose.yml.backup.$(date +%Y%m%d-%H%M%S)"
	cp "$DOCKER_COMPOSE" "$BACKUP_DIR/$backup_name"
	print_info "Backed up docker-compose.yml to $BACKUP_DIR/$backup_name"

	write_docker_compose
	print_success "Updated docker-compose.yml with conf.d/ mount"
	return 0
}

# Write the docker-compose.yml
write_docker_compose() {
	cat >"$DOCKER_COMPOSE" <<'YAML'
services:
  traefik:
    image: traefik:v3.3
    container_name: local-traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./conf.d:/etc/traefik/conf.d:ro
      - ~/.local-ssl-certs:/certs:ro
    networks:
      - local-dev

networks:
  local-dev:
    external: true
YAML
	return 0
}

# Restart Traefik container if it's currently running
restart_traefik_if_running() {
	if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^local-traefik$'; then
		print_info "Restarting Traefik container to pick up new config..."
		docker compose -f "$DOCKER_COMPOSE" down 2>/dev/null || docker-compose -f "$DOCKER_COMPOSE" down 2>/dev/null || true
		docker compose -f "$DOCKER_COMPOSE" up -d 2>/dev/null || docker-compose -f "$DOCKER_COMPOSE" up -d 2>/dev/null || {
			print_warning "Could not restart Traefik. Run manually:"
			print_info "  cd $LOCALDEV_DIR && docker compose up -d"
		}
		print_success "Traefik restarted with conf.d/ provider"
	else
		print_info "Traefik not running. Start with:"
		print_info "  cd $LOCALDEV_DIR && docker compose up -d"
	fi
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
assign_port() {
	local port="$PORT_RANGE_START"
	while [[ "$port" -le "$PORT_RANGE_END" ]]; do
		if ! is_port_registered "$port" && ! is_port_in_use "$port"; then
			echo "$port"
			return 0
		fi
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

	return "$collision"
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

	mkdir -p "$CERTS_DIR"

	print_info "Generating mkcert wildcard cert for $wildcard and $domain..."

	# mkcert generates files named after the first domain arg
	# Output: {domain}+1.pem and {domain}+1-key.pem (wildcard is second arg)
	(cd "$CERTS_DIR" && mkcert "$domain" "$wildcard")

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
# /etc/hosts Fallback
# =============================================================================

# Add /etc/hosts entry for a domain (fallback when dnsmasq not configured)
add_hosts_entry() {
	local domain="$1"
	local marker="# localdev: $domain"

	# Check if already present
	if grep -q "$marker" /etc/hosts 2>/dev/null; then
		print_info "/etc/hosts entry for $domain already exists — skipping"
		return 0
	fi

	print_info "Adding /etc/hosts fallback entry for $domain..."
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

# =============================================================================
# Add Command
# =============================================================================

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

	# Step 5: Add /etc/hosts fallback if dnsmasq not configured
	if ! is_dnsmasq_configured; then
		print_info "dnsmasq not configured — adding /etc/hosts fallback entry"
		add_hosts_entry "$domain" || true
	else
		print_info "dnsmasq configured — skipping /etc/hosts fallback"
	fi

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
# Branch Command — Subdomain routing for worktrees/branches
# =============================================================================
# Creates branch-specific subdomain routes: feature-xyz.myapp.local
# Reuses the wildcard cert from `localdev add` (*.myapp.local)
# Port registry tracks branch->port mappings per project in ports.json

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
		# shellcheck disable=SC2086
		local files
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

cmd_branch() {
	local subcmd="${1:-}"
	local app="${2:-}"
	local branch_raw="${3:-}"
	local port_arg="${4:-}"

	# Handle subcommands: branch rm, branch list
	case "$subcmd" in
	rm | remove)
		cmd_branch_rm "$app" "$branch_raw"
		return $?
		;;
	list | ls)
		cmd_branch_list "$app"
		return $?
		;;
	help | -h | --help)
		cmd_branch_help
		return 0
		;;
	esac

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

	# Step 1: Verify parent app is registered
	if ! is_app_registered "$app"; then
		print_error "App '$app' is not registered. Register it first:"
		print_info "  localdev-helper.sh add $app"
		exit 1
	fi

	# Step 2: Check branch not already registered
	if is_branch_registered "$app" "$branch"; then
		local existing_port
		existing_port="$(get_branch_port "$app" "$branch")"
		print_error "Branch '$branch' is already registered for '$app' on port $existing_port"
		print_info "  Remove first: localdev-helper.sh branch rm $app $branch"
		exit 1
	fi

	# Step 3: Check subdomain collision with LocalWP
	if is_localwp_domain "$subdomain"; then
		print_error "Subdomain '$subdomain' is already used by LocalWP"
		exit 1
	fi

	# Step 4: Assign port
	local port
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
# List Command
# =============================================================================

cmd_list() {
	ensure_ports_file

	print_info "Registered localdev apps:"
	echo ""

	if command -v jq >/dev/null 2>&1; then
		local count
		count="$(jq '.apps | length' "$PORTS_FILE")"
		if [[ "$count" -eq 0 ]]; then
			print_info "  No apps registered. Use: localdev-helper.sh add <name>"
			return 0
		fi
		jq -r '.apps | to_entries[] | "  \(.key)\t\(.value.domain)\tport:\(.value.port)\tadded:\(.value.added)"' "$PORTS_FILE"
		# Show branches inline
		jq -r '.apps | to_entries[] | select(.value.branches // {} | length > 0) | .key as $app | .value.branches | to_entries[] | "    ↳ \(.key)\t\(.value.subdomain)\tport:\(.value.port)"' "$PORTS_FILE" 2>/dev/null || true
	else
		python3 - "$PORTS_FILE" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
apps = data.get('apps', {})
if not apps:
    print("  No apps registered.")
else:
    for name, info in apps.items():
        print(f"  {name}\t{info['domain']}\tport:{info['port']}\tadded:{info['added']}")
        for bname, binfo in info.get('branches', {}).items():
            print(f"    > {bname}\t{binfo['subdomain']}\tport:{binfo['port']}")
PYEOF
	fi

	echo ""
	# Also show LocalWP sites for context
	local localwp_count
	localwp_count="$(grep -c '#Local Site' /etc/hosts 2>/dev/null || echo "0")"
	if [[ "$localwp_count" -gt 0 ]]; then
		print_info "LocalWP sites (managed separately via /etc/hosts):"
		grep '#Local Site' /etc/hosts 2>/dev/null | awk '{print "  " $2}' | sort -u
	fi
	return 0
}

# =============================================================================
# Status Command
# =============================================================================

cmd_status() {
	print_info "localdev status"
	echo ""

	# dnsmasq
	echo "--- dnsmasq ---"
	local brew_prefix
	brew_prefix="$(detect_brew_prefix)"
	if [[ -n "$brew_prefix" ]] && [[ -f "$brew_prefix/etc/dnsmasq.conf" ]]; then
		if grep -q 'address=/.local/127.0.0.1' "$brew_prefix/etc/dnsmasq.conf" 2>/dev/null; then
			print_success "dnsmasq: .local wildcard configured"
		else
			print_warning "dnsmasq: .local wildcard NOT configured (run: localdev init)"
		fi
	else
		print_warning "dnsmasq: config not found"
	fi

	# Resolver
	echo ""
	echo "--- macOS resolver ---"
	if [[ -f "/etc/resolver/local" ]]; then
		print_success "/etc/resolver/local exists"
	else
		print_warning "/etc/resolver/local missing (run: localdev init)"
	fi

	# Traefik
	echo ""
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
	else
		print_warning "Traefik container: not running"
	fi

	# LocalWP coexistence
	echo ""
	echo "--- LocalWP coexistence ---"
	local localwp_count
	localwp_count="$(grep -c '#Local Site' /etc/hosts 2>/dev/null || echo "0")"
	if [[ "$localwp_count" -gt 0 ]]; then
		print_info "LocalWP entries in /etc/hosts: $localwp_count"
		grep '#Local Site' /etc/hosts 2>/dev/null | awk '{print "  " $2}' | sort -u
	else
		print_info "No LocalWP entries in /etc/hosts"
	fi

	return 0
}

# =============================================================================
# Database Command — Shared Postgres management
# =============================================================================
# Manages a shared local-postgres container for development databases.
# Projects can still use their own docker-compose Postgres for version-specific
# testing — this provides a convenient shared instance for general use.

# Default Postgres configuration
LOCALDEV_PG_CONTAINER="${LOCALDEV_PG_CONTAINER:-local-postgres}"
LOCALDEV_PG_IMAGE="${LOCALDEV_PG_IMAGE:-postgres:17-alpine}"
LOCALDEV_PG_PORT="${LOCALDEV_PG_PORT:-5432}"
LOCALDEV_PG_USER="${LOCALDEV_PG_USER:-postgres}"
LOCALDEV_PG_PASSWORD="${LOCALDEV_PG_PASSWORD:-localdev}"
LOCALDEV_PG_DATA="${LOCALDEV_PG_DATA:-$HOME/.local-dev-proxy/pgdata}"

# Check if the shared Postgres container exists (running or stopped)
pg_container_exists() {
	docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$LOCALDEV_PG_CONTAINER"
	return $?
}

# Check if the shared Postgres container is running
pg_container_running() {
	docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$LOCALDEV_PG_CONTAINER"
	return $?
}

# Wait for Postgres to accept connections (up to 30s)
pg_wait_ready() {
	local max_wait=30
	local waited=0
	while [[ "$waited" -lt "$max_wait" ]]; do
		if docker exec "$LOCALDEV_PG_CONTAINER" pg_isready -U "$LOCALDEV_PG_USER" >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
		waited=$((waited + 1))
	done
	return 1
}

# Execute a psql command inside the container
pg_exec() {
	docker exec "$LOCALDEV_PG_CONTAINER" psql -U "$LOCALDEV_PG_USER" "$@"
	return $?
}

# Start the shared Postgres container
cmd_db_start() {
	print_info "localdev db start — ensuring shared Postgres is running"
	echo ""

	# Check Docker is available
	if ! command -v docker >/dev/null 2>&1; then
		print_error "Docker is not installed or not in PATH"
		return 1
	fi

	if ! docker info >/dev/null 2>&1; then
		print_error "Docker daemon is not running"
		return 1
	fi

	# Already running?
	if pg_container_running; then
		print_success "Shared Postgres ($LOCALDEV_PG_CONTAINER) is already running"
		print_info "  Image:    $(docker inspect --format '{{.Config.Image}}' "$LOCALDEV_PG_CONTAINER" 2>/dev/null)"
		print_info "  Port:     $LOCALDEV_PG_PORT"
		print_info "  Data dir: $LOCALDEV_PG_DATA"
		return 0
	fi

	# Exists but stopped?
	if pg_container_exists; then
		print_info "Starting existing $LOCALDEV_PG_CONTAINER container..."
		docker start "$LOCALDEV_PG_CONTAINER" >/dev/null 2>&1 || {
			print_error "Failed to start $LOCALDEV_PG_CONTAINER"
			return 1
		}
	else
		# Create data directory
		mkdir -p "$LOCALDEV_PG_DATA"

		print_info "Creating $LOCALDEV_PG_CONTAINER container..."
		print_info "  Image: $LOCALDEV_PG_IMAGE"
		print_info "  Port:  $LOCALDEV_PG_PORT"
		print_info "  Data:  $LOCALDEV_PG_DATA"

		# Ensure local-dev network exists (shared with Traefik)
		docker network create local-dev 2>/dev/null || true

		docker run -d \
			--name "$LOCALDEV_PG_CONTAINER" \
			--restart unless-stopped \
			--network local-dev \
			-p "${LOCALDEV_PG_PORT}:5432" \
			-e "POSTGRES_USER=$LOCALDEV_PG_USER" \
			-e "POSTGRES_PASSWORD=$LOCALDEV_PG_PASSWORD" \
			-v "$LOCALDEV_PG_DATA:/var/lib/postgresql/data" \
			"$LOCALDEV_PG_IMAGE" >/dev/null 2>&1 || {
			print_error "Failed to create $LOCALDEV_PG_CONTAINER container"
			return 1
		}
	fi

	# Wait for readiness
	print_info "Waiting for Postgres to accept connections..."
	if pg_wait_ready; then
		print_success "Shared Postgres is ready"
		print_info "  Container: $LOCALDEV_PG_CONTAINER"
		print_info "  Port:      $LOCALDEV_PG_PORT"
		print_info "  User:      $LOCALDEV_PG_USER"
		print_info "  Data dir:  $LOCALDEV_PG_DATA"
	else
		print_error "Postgres did not become ready within 30 seconds"
		print_info "  Check logs: docker logs $LOCALDEV_PG_CONTAINER"
		return 1
	fi
	return 0
}

# Stop the shared Postgres container
cmd_db_stop() {
	print_info "localdev db stop — stopping shared Postgres"
	echo ""

	if ! pg_container_running; then
		print_info "Shared Postgres ($LOCALDEV_PG_CONTAINER) is not running"
		return 0
	fi

	docker stop "$LOCALDEV_PG_CONTAINER" >/dev/null 2>&1 || {
		print_error "Failed to stop $LOCALDEV_PG_CONTAINER"
		return 1
	}

	print_success "Shared Postgres stopped"
	return 0
}

# Create a database
cmd_db_create() {
	local dbname="${1:-}"

	if [[ -z "$dbname" ]]; then
		print_error "Usage: localdev-helper.sh db create <dbname>"
		print_info "  dbname: database name (e.g., myapp, myapp-feature-xyz)"
		return 1
	fi

	# Validate name: alphanumeric, hyphens, underscores
	if ! echo "$dbname" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$'; then
		print_error "Invalid database name '$dbname': must start with a letter, then letters/numbers/hyphens/underscores"
		return 1
	fi

	# Ensure Postgres is running
	if ! pg_container_running; then
		print_info "Shared Postgres not running — starting it first..."
		cmd_db_start || return 1
		echo ""
	fi

	# Convert hyphens to underscores for Postgres identifier compatibility
	local pg_dbname
	pg_dbname="$(echo "$dbname" | tr '-' '_')"

	if [[ "$pg_dbname" != "$dbname" ]]; then
		print_info "Converted database name: '$dbname' -> '$pg_dbname' (Postgres identifiers use underscores)"
	fi

	# Check if database already exists
	local exists
	exists="$(docker exec "$LOCALDEV_PG_CONTAINER" psql -U "$LOCALDEV_PG_USER" -tAc \
		"SELECT 1 FROM pg_database WHERE datname = '$pg_dbname'" 2>/dev/null)"

	if [[ "$exists" == "1" ]]; then
		print_warning "Database '$pg_dbname' already exists"
		print_info "  URL: $(cmd_db_url_string "$pg_dbname")"
		return 0
	fi

	# Create the database
	docker exec "$LOCALDEV_PG_CONTAINER" createdb -U "$LOCALDEV_PG_USER" "$pg_dbname" 2>/dev/null || {
		print_error "Failed to create database '$pg_dbname'"
		return 1
	}

	print_success "Created database: $pg_dbname"
	print_info "  URL: $(cmd_db_url_string "$pg_dbname")"
	return 0
}

# Generate connection string for a database (internal helper, no output formatting)
cmd_db_url_string() {
	local pg_dbname="${1:-}"
	echo "postgresql://${LOCALDEV_PG_USER}:${LOCALDEV_PG_PASSWORD}@localhost:${LOCALDEV_PG_PORT}/${pg_dbname}"
	return 0
}

# Output connection string for a database
cmd_db_url() {
	local dbname="${1:-}"

	if [[ -z "$dbname" ]]; then
		print_error "Usage: localdev-helper.sh db url <dbname>"
		return 1
	fi

	# Validate name (mirrors cmd_db_create)
	if ! echo "$dbname" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$'; then
		print_error "Invalid database name '$dbname': must start with a letter, then letters/numbers/hyphens/underscores"
		return 1
	fi

	# Convert hyphens to underscores
	local pg_dbname
	pg_dbname="$(echo "$dbname" | tr '-' '_')"

	# Verify database exists if Postgres is running
	if pg_container_running; then
		local exists
		exists="$(docker exec "$LOCALDEV_PG_CONTAINER" psql -U "$LOCALDEV_PG_USER" -tAc \
			"SELECT 1 FROM pg_database WHERE datname = '$pg_dbname'" 2>/dev/null)"

		if [[ "$exists" != "1" ]]; then
			print_error "Database '$pg_dbname' does not exist"
			print_info "  Create it: localdev-helper.sh db create $dbname"
			return 1
		fi
	else
		print_warning "Postgres is not running — URL may not be usable"
	fi

	cmd_db_url_string "$pg_dbname"
	return 0
}

# List all databases
cmd_db_list() {
	if ! pg_container_running; then
		print_error "Shared Postgres ($LOCALDEV_PG_CONTAINER) is not running"
		print_info "  Start it: localdev-helper.sh db start"
		return 1
	fi

	print_info "Databases in $LOCALDEV_PG_CONTAINER:"
	echo ""

	# List user databases (exclude template and postgres system dbs)
	local db_list
	db_list="$(docker exec "$LOCALDEV_PG_CONTAINER" psql -U "$LOCALDEV_PG_USER" -tAc \
		"SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres' ORDER BY datname" 2>/dev/null)"

	if [[ -z "$db_list" ]]; then
		print_info "  No user databases. Create one: localdev-helper.sh db create <name>"
	else
		while IFS= read -r db; do
			[[ -z "$db" ]] && continue
			echo "  $db"
			echo "    $(cmd_db_url_string "$db")"
		done <<<"$db_list"
	fi

	echo ""
	print_info "Container: $LOCALDEV_PG_CONTAINER ($LOCALDEV_PG_IMAGE)"
	print_info "Port: $LOCALDEV_PG_PORT"
	return 0
}

# Drop a database
cmd_db_drop() {
	local dbname="${1:-}"
	local force="${2:-}"

	if [[ -z "$dbname" ]]; then
		print_error "Usage: localdev-helper.sh db drop <dbname> [--force]"
		return 1
	fi

	# Validate name (mirrors cmd_db_create)
	if ! echo "$dbname" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$'; then
		print_error "Invalid database name '$dbname': must start with a letter, then letters/numbers/hyphens/underscores"
		return 1
	fi

	# Convert hyphens to underscores
	local pg_dbname
	pg_dbname="$(echo "$dbname" | tr '-' '_')"

	if ! pg_container_running; then
		print_error "Shared Postgres ($LOCALDEV_PG_CONTAINER) is not running"
		print_info "  Start it: localdev-helper.sh db start"
		return 1
	fi

	# Check database exists
	local exists
	exists="$(docker exec "$LOCALDEV_PG_CONTAINER" psql -U "$LOCALDEV_PG_USER" -tAc \
		"SELECT 1 FROM pg_database WHERE datname = '$pg_dbname'" 2>/dev/null)"

	if [[ "$exists" != "1" ]]; then
		print_warning "Database '$pg_dbname' does not exist"
		return 0
	fi

	# Safety check: require --force for non-interactive (headless) use
	if [[ "$force" != "--force" ]] && [[ "$force" != "-f" ]]; then
		print_warning "This will permanently delete database '$pg_dbname' and all its data"
		print_info "  Re-run with --force to confirm: localdev-helper.sh db drop $dbname --force"
		return 1
	fi

	# Terminate active connections before dropping
	docker exec "$LOCALDEV_PG_CONTAINER" psql -U "$LOCALDEV_PG_USER" -c \
		"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$pg_dbname' AND pid <> pg_backend_pid()" >/dev/null 2>&1 || true

	docker exec "$LOCALDEV_PG_CONTAINER" dropdb -U "$LOCALDEV_PG_USER" "$pg_dbname" || {
		print_error "Failed to drop database '$pg_dbname'"
		return 1
	}

	print_success "Dropped database: $pg_dbname"
	return 0
}

# Show db status
cmd_db_status() {
	print_info "localdev db status"
	echo ""

	echo "--- Shared Postgres ---"
	if pg_container_running; then
		local image
		image="$(docker inspect --format '{{.Config.Image}}' "$LOCALDEV_PG_CONTAINER" 2>/dev/null)"
		print_success "Container: $LOCALDEV_PG_CONTAINER (running)"
		print_info "  Image: $image"
		print_info "  Port:  $LOCALDEV_PG_PORT"
		print_info "  Data:  $LOCALDEV_PG_DATA"

		local db_count
		db_count="$(docker exec "$LOCALDEV_PG_CONTAINER" psql -U "$LOCALDEV_PG_USER" -tAc \
			"SELECT count(*) FROM pg_database WHERE datistemplate = false AND datname != 'postgres'" 2>/dev/null | tr -d ' ')"
		print_info "  Databases: ${db_count:-0}"
	elif pg_container_exists; then
		print_warning "Container: $LOCALDEV_PG_CONTAINER (stopped)"
		print_info "  Start with: localdev-helper.sh db start"
	else
		print_info "Container: $LOCALDEV_PG_CONTAINER (not created)"
		print_info "  Create with: localdev-helper.sh db start"
	fi
	return 0
}

# Database command dispatcher
cmd_db() {
	local subcmd="${1:-help}"
	shift 2>/dev/null || true

	case "$subcmd" in
	start)
		cmd_db_start
		;;
	stop)
		cmd_db_stop
		;;
	create)
		cmd_db_create "$@"
		;;
	url)
		cmd_db_url "$@"
		;;
	list | ls)
		cmd_db_list
		;;
	drop)
		cmd_db_drop "$@"
		;;
	status)
		cmd_db_status
		;;
	help | -h | --help)
		cmd_db_help
		;;
	*)
		print_error "$ERROR_UNKNOWN_COMMAND db $subcmd"
		cmd_db_help
		return 1
		;;
	esac
	return $?
}

cmd_db_help() {
	echo "localdev db — Shared Postgres database management"
	echo ""
	echo "Usage: localdev-helper.sh db <command> [options]"
	echo ""
	echo "Commands:"
	echo "  start              Ensure shared local-postgres container is running"
	echo "  stop               Stop the shared Postgres container"
	echo "  create <dbname>    Create a database (e.g., myapp, myapp-feature-xyz)"
	echo "  drop <dbname> [--force|-f]  Drop a database (requires confirmation flag)"
	echo "  list               List all user databases with connection strings"
	echo "  url <dbname>       Output connection string for a database"
	echo "  status             Show container and database status"
	echo "  help               Show this help message"
	echo ""
	echo "Configuration (environment variables):"
	echo "  LOCALDEV_PG_IMAGE      Docker image (default: postgres:17-alpine)"
	echo "  LOCALDEV_PG_PORT       Host port (default: 5432)"
	echo "  LOCALDEV_PG_USER       Postgres user (default: postgres)"
	echo "  LOCALDEV_PG_PASSWORD   Postgres password (default: localdev)"
	echo "  LOCALDEV_PG_DATA       Data directory (default: ~/.local-dev-proxy/pgdata)"
	echo ""
	echo "Examples:"
	echo "  localdev db start                    # Start shared Postgres"
	echo "  localdev db create myapp             # Create database for project"
	echo "  localdev db create myapp-feature-xyz # Branch-isolated database"
	echo "  localdev db url myapp                # Get connection string"
	echo "  localdev db list                     # List all databases"
	echo "  localdev db drop myapp-feature-xyz --force  # Remove branch database"
	echo ""
	echo "Projects can still use their own docker-compose Postgres for"
	echo "version-specific testing. This shared instance is for convenience."
	echo ""
	echo "Container: $LOCALDEV_PG_CONTAINER"
	echo "Data dir:  $LOCALDEV_PG_DATA"
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
	echo "  init               One-time setup: dnsmasq, resolver, Traefik conf.d migration"
	echo "  add <name> [port]  Register app: cert + Traefik route + port registry"
	echo "  rm <name>          Remove app: reverses all add operations (incl. branches)"
	echo "  branch <app> <branch> [port]  Add branch subdomain route"
	echo "  branch rm <app> <branch>      Remove branch route"
	echo "  branch list [app]             List branch routes"
	echo "  db <command>       Shared Postgres management (start, create, list, drop, url)"
	echo "  list               List registered apps, branches, and LocalWP sites"
	echo "  status             Show current configuration status"
	echo "  help               Show this help message"
	echo ""
	echo "Add performs:"
	echo "  1. Collision detection (LocalWP, registry, port)"
	echo "  2. Auto-assign port from 3100-3999 (or use specified port)"
	echo "  3. Generate mkcert wildcard cert (*.name.local + name.local)"
	echo "  4. Create Traefik conf.d/{name}.yml route file"
	echo "  5. Add /etc/hosts fallback entry (if dnsmasq not configured)"
	echo "  6. Register in ~/.local-dev-proxy/ports.json"
	echo ""
	echo "Remove reverses all add operations."
	echo ""
	echo "Init performs:"
	echo "  1. Configure dnsmasq with address=/.local/127.0.0.1"
	echo "  2. Create /etc/resolver/local (macOS)"
	echo "  3. Migrate Traefik from single dynamic.yml to conf.d/ directory"
	echo "  4. Preserve existing routes (e.g., awardsapp)"
	echo "  5. Restart Traefik if running"
	echo ""
	echo "Requires: docker, mkcert, dnsmasq (brew install dnsmasq)"
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
