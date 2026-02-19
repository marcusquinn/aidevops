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

# Check if a port is already in use in the registry
is_port_registered() {
	local port="$1"
	local registry
	registry="$(read_ports_registry)"
	if command -v jq >/dev/null 2>&1; then
		local result
		result="$(echo "$registry" | jq -r --argjson p "$port" '[.apps[] | select(.port == $p)] | length')"
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

	# Step 1: Remove Traefik route file
	remove_traefik_route "$name"

	# Step 2: Remove mkcert cert files
	remove_cert "$name"

	# Step 3: Remove /etc/hosts entry (if present)
	remove_hosts_entry "$domain"

	# Step 4: Deregister from port registry
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
# Help
# =============================================================================

cmd_help() {
	echo "localdev — Local development environment manager"
	echo ""
	echo "Usage: localdev-helper.sh <command> [options]"
	echo ""
	echo "Commands:"
	echo "  init          One-time setup: dnsmasq, resolver, Traefik conf.d migration"
	echo "  add <name> [port]  Register app: cert + Traefik route + port registry"
	echo "  rm <name>     Remove app: reverses all add operations"
	echo "  list          List registered apps and LocalWP sites"
	echo "  status        Show current configuration status"
	echo "  help          Show this help message"
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
