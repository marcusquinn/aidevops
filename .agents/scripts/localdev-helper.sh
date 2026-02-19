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
readonly PORTS_FILE="$LOCALDEV_DIR/ports.json"
readonly CERTS_DIR="$HOME/.local-ssl-certs"
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
	local backup_name="dynamic.yml.backup.$(date +%Y%m%d-%H%M%S)"
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
	local backup_name="traefik.yml.backup.$(date +%Y%m%d-%H%M%S)"
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
	local backup_name="docker-compose.yml.backup.$(date +%Y%m%d-%H%M%S)"
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
	echo "  status        Show current configuration status"
	echo "  help          Show this help message"
	echo ""
	echo "Init performs:"
	echo "  1. Configure dnsmasq with address=/.local/127.0.0.1"
	echo "  2. Create /etc/resolver/local (macOS)"
	echo "  3. Migrate Traefik from single dynamic.yml to conf.d/ directory"
	echo "  4. Preserve existing routes (e.g., awardsapp)"
	echo "  5. Restart Traefik if running"
	echo ""
	echo "Requires: docker, mkcert, dnsmasq (brew install dnsmasq)"
	echo "Requires: sudo (for /etc/resolver and dnsmasq restart)"
	echo ""
	echo "LocalWP coexistence:"
	echo "  Domains in /etc/hosts (#Local Site) take precedence over dnsmasq."
	echo "  dnsmasq only resolves domains NOT already in /etc/hosts."
	echo ""
	echo "Future commands (t1224.2+): add, rm, branch, db, list"
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
