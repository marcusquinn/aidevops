#!/usr/bin/env bash
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
	print_info "Next: localdev-helper.sh add <appname> (registers app + /etc/hosts entry)"
	print_info "Verify dnsmasq (CLI only): dig testdomain.local @127.0.0.1"
	return 0
}

# Install mkcert if not present. Supports macOS (brew) and Linux (apt, dnf,
# pacman, apk). On Linux, the apt package name is "mkcert" (available in
# Ubuntu 20.04+ and Debian 11+). libnss3-tools is required on Debian/Ubuntu
# for mkcert to install the CA root into Firefox/Chrome trust stores.
# Falls back to downloading the upstream binary from dl.filippo.io for
# distributions without a supported package manager (x86_64, arm64, armv7l).
# After installation, runs `mkcert -install`
# to create and trust the local CA root.
# Returns: 0 if mkcert is available after this function, 1 if installation failed.
ensure_mkcert() {
	if command -v mkcert >/dev/null 2>&1; then
		return 0
	fi

	print_info "mkcert not found — attempting to install..."

	local installed=false

	if command -v brew >/dev/null 2>&1; then
		if brew install mkcert 2>/dev/null; then
			installed=true
		fi
	elif command -v apt-get >/dev/null 2>&1; then
		if sudo apt-get update -qq && sudo apt-get install -y -qq mkcert libnss3-tools 2>/dev/null; then
			installed=true
		fi
	elif command -v apt >/dev/null 2>&1; then
		if sudo apt update -qq && sudo apt install -y -qq mkcert libnss3-tools 2>/dev/null; then
			installed=true
		fi
	elif command -v dnf >/dev/null 2>&1; then
		if sudo dnf install -y mkcert 2>/dev/null; then
			installed=true
		fi
	elif command -v pacman >/dev/null 2>&1; then
		if sudo pacman -S --noconfirm mkcert 2>/dev/null; then
			installed=true
		fi
	elif command -v apk >/dev/null 2>&1; then
		if sudo apk add mkcert 2>/dev/null; then
			installed=true
		fi
	fi

	# Binary download fallback for distros without a supported package manager.
	# Supports x86_64 (amd64), aarch64/arm64, and armv7l architectures.
	if [[ "$installed" != "true" ]] && command -v curl >/dev/null 2>&1; then
		local raw_arch
		raw_arch=$(uname -m)
		local arch=""
		case "$raw_arch" in
		x86_64) arch="amd64" ;;
		aarch64 | arm64) arch="arm64" ;;
		armv7l) arch="armv7l" ;;
		*) arch="" ;;
		esac

		if [[ -n "$arch" ]]; then
			print_info "Attempting binary download fallback for linux/$arch..."
			local bin_dir="$HOME/.local/bin"
			mkdir -p "$bin_dir"
			local mkcert_url="https://dl.filippo.io/mkcert/latest?for=linux/$arch"
			if curl -fsSL "$mkcert_url" -o "$bin_dir/mkcert" 2>/dev/null && chmod +x "$bin_dir/mkcert"; then
				# Ensure ~/.local/bin is on PATH for this session
				export PATH="$bin_dir:$PATH"
				if command -v mkcert >/dev/null 2>&1; then
					installed=true
					print_success "mkcert installed via binary download to $bin_dir/mkcert"
				fi
			fi
		fi
	fi

	if [[ "$installed" != "true" ]] || ! command -v mkcert >/dev/null 2>&1; then
		print_error "Failed to install mkcert automatically"
		echo "  Manual install options:"
		echo "    macOS:         brew install mkcert"
		echo "    Ubuntu/Debian: sudo apt install mkcert libnss3-tools"
		echo "    Fedora:        sudo dnf install mkcert"
		echo "    Arch:          sudo pacman -S mkcert"
		echo "    Other:         https://github.com/FiloSottile/mkcert#installation"
		return 1
	fi

	print_success "mkcert installed"

	# Install the local CA into the system trust store (one-time setup).
	# This makes mkcert-generated certs trusted by browsers and curl.
	print_info "Installing mkcert local CA root (may require sudo)..."
	if mkcert -install 2>/dev/null; then
		print_success "mkcert CA root installed and trusted"
	else
		print_warning "mkcert -install failed — certs will generate but browsers may not trust them"
		echo "  Run manually: mkcert -install"
	fi

	return 0
}

# Check that required tools are installed
check_init_prerequisites() {
	local missing=()

	command -v docker >/dev/null 2>&1 || missing+=("docker")

	# Try to auto-install mkcert if missing (GH#6415)
	if ! command -v mkcert >/dev/null 2>&1 && ! ensure_mkcert; then
		missing+=("mkcert")
	fi

	# dnsmasq: check brew installation or system-wide
	local brew_prefix
	brew_prefix="$(detect_brew_prefix)"
	if [[ -z "$brew_prefix" ]] || [[ ! -f "$brew_prefix/etc/dnsmasq.conf" ]]; then
		if ! command -v dnsmasq >/dev/null 2>&1; then
			missing+=("dnsmasq")
		fi
	fi

	if [[ ${#missing[@]} -gt 0 ]]; then
		print_error "Missing required tools: ${missing[*]}"
		echo "  Install:"
		echo "    macOS:         brew install ${missing[*]}"
		echo "    Ubuntu/Debian: sudo apt install ${missing[*]}"
		echo "    Fedora:        sudo dnf install ${missing[*]}"
		echo "    Arch:          sudo pacman -S ${missing[*]}"
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

	# Note about .local mDNS limitation
	print_info "Note: /etc/resolver/local enables dnsmasq for CLI tools (dig, curl)"
	print_info "Browsers require /etc/hosts entries for .local (mDNS intercepts resolver files)"
	print_info "The 'add' command handles /etc/hosts entries automatically"
	return 0
}

# =============================================================================
# Traefik conf.d Migration
# =============================================================================
# Migrates from single dynamic.yml to conf.d/ directory provider.
# Preserves existing routes (e.g., webapp) by splitting into per-app files.

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

	# Check if webapp route exists in dynamic.yml
	if grep -q 'webapp' "$dynamic_yml"; then
		# Extract and create webapp conf.d file
		if [[ ! -f "$CONFD_DIR/webapp.yml" ]]; then
			create_webapp_confd
			print_success "Migrated webapp route to conf.d/webapp.yml"
		else
			print_info "conf.d/webapp.yml already exists — skipping migration"
		fi
	fi

	return 0
}

# Create the webapp conf.d file from the known existing config
create_webapp_confd() {
	cat >"$CONFD_DIR/webapp.yml" <<'YAML'
http:
  routers:
    webapp:
      rule: "Host(`webapp.local`)"
      entryPoints:
        - websecure
      service: webapp
      tls: {}

  services:
    webapp:
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
    - certFile: /certs/webapp.local+1.pem
      keyFile: /certs/webapp.local+1-key.pem
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

	# Ensure mkcert is available (auto-install if missing, GH#6415)
	if ! command -v mkcert >/dev/null 2>&1 && ! ensure_mkcert; then
		print_error "mkcert is required to generate SSL certificates"
		return 1
	fi

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
# Run Command — Zero-config dev server wrapper
# =============================================================================
# Wraps a dev command (e.g., npm run dev) with automatic:
#   1. Project registration (if not already registered)
#   2. Port resolution (main or branch)
#   3. PORT/HOST env var injection
#   4. Signal passthrough (SIGINT/SIGTERM forwarded to child)
#
# Usage: localdev run [options] <command...>
#   Options:
#     --name <name>   Override inferred project name
#     --port <port>   Override auto-assigned port
#     --no-host       Don't set HOST=0.0.0.0
#
# Examples:
#   localdev run npm run dev
#   localdev run --name myapp pnpm dev
#   localdev run bun run dev

# Parse cmd_run options; sets name_override, port_override, set_host, cmd_args via caller's locals
_cmd_run_parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			name_override="${2:-}"
			if [[ -z "$name_override" ]]; then
				print_error "Usage: localdev run --name <name> <command...>"
				return 1
			fi
			shift 2
			;;
		--port)
			port_override="${2:-}"
			if [[ ! "$port_override" =~ ^[0-9]+$ ]]; then
				print_error "Invalid port: ${port_override:-<empty>} (must be numeric)"
				return 1
			fi
			shift 2
			;;
		--no-host)
			set_host=0
			shift
			;;
		--)
			shift
			cmd_args+=("$@")
			break
			;;
		-*)
			print_error "Unknown option: $1"
			print_info "Usage: localdev run [--name <name>] [--port <port>] [--no-host] <command...>"
			return 1
			;;
		*)
			cmd_args+=("$@")
			break
			;;
		esac
	done
	return 0
}

# Print cmd_run usage and return 1
_cmd_run_usage() {
	print_error "Usage: localdev run [options] <command...>"
	print_info ""
	print_info "Wraps a dev command with automatic project registration and port injection."
	print_info ""
	print_info "Examples:"
	print_info "  localdev run npm run dev"
	print_info "  localdev run --name myapp pnpm dev"
	print_info "  localdev run bun run dev"
	print_info ""
	print_info "Options:"
	print_info "  --name <name>   Override inferred project name"
	print_info "  --port <port>   Override auto-assigned port"
	print_info "  --no-host       Don't set HOST=0.0.0.0"
	return 1
}

# Resolve the project name for cmd_run; outputs name to stdout
_cmd_run_resolve_name() {
	local name_override="$1"
	local name=""
	if [[ -n "$name_override" ]]; then
		# Sanitise: lowercase, replace non-alphanumeric with hyphens, collapse, trim
		name="$(echo "$name_override" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
		if [[ -z "$name" ]]; then
			print_error "Invalid project name after sanitisation: $name_override"
			return 1
		fi
	else
		name="$(infer_project_name ".")" || {
			print_error "Cannot infer project name from current directory"
			print_info "  Use --name <name> to specify explicitly"
			return 1
		}
	fi
	echo "$name"
	return 0
}

# Detect worktree/branch context; outputs "is_worktree branch_name is_feature_branch" (tab-separated)
_cmd_run_detect_worktree() {
	local is_worktree=0
	local branch_name=""
	local is_feature_branch=0
	if [[ -f ".git" ]]; then
		is_worktree=1
		branch_name="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
		if [[ -n "$branch_name" ]] && [[ "$branch_name" != "main" ]] && [[ "$branch_name" != "master" ]]; then
			is_feature_branch=1
		fi
	fi
	printf '%s\t%s\t%s\n' "$is_worktree" "$branch_name" "$is_feature_branch"
	return 0
}

# Resolve the port for cmd_run; outputs port to stdout
_cmd_run_resolve_port() {
	local name="$1"
	local port_override="$2"
	local is_feature_branch="$3"
	local branch_name="$4"

	local port=""
	if [[ -n "$port_override" ]]; then
		port="$port_override"
	elif [[ "$is_feature_branch" -eq 1 ]]; then
		local sanitised_branch
		sanitised_branch="$(sanitise_branch_name "$branch_name")"
		if is_branch_registered "$name" "$sanitised_branch"; then
			port="$(get_branch_port "$name" "$sanitised_branch")"
			print_info "Using branch port: $port (${sanitised_branch}.${name}.local)"
		else
			print_info "Creating branch route for $sanitised_branch..."
			cmd_branch "$name" "$branch_name"
			port="$(get_branch_port "$name" "$sanitised_branch")"
			if [[ -z "$port" ]]; then
				port="$(get_app_port "$name")"
				print_warning "Branch route creation failed — using main port: $port"
			else
				print_info "Using branch port: $port (${sanitised_branch}.${name}.local)"
			fi
		fi
	else
		port="$(get_app_port "$name")"
	fi

	if [[ -z "$port" ]]; then
		print_error "Cannot determine port for '$name'"
		return 1
	fi
	echo "$port"
	return 0
}

cmd_run() {
	local name_override=""
	local port_override=""
	local set_host=1
	local cmd_args=()

	# Step 0: Parse options
	_cmd_run_parse_args "$@" || return 1
	# Rebuild positional args from cmd_args (populated by _cmd_run_parse_args via caller scope)
	set -- "${cmd_args[@]+"${cmd_args[@]}"}"

	if [[ ${#cmd_args[@]} -eq 0 ]]; then
		_cmd_run_usage
		return 1
	fi

	# Step 1: Determine project name
	local name
	name="$(_cmd_run_resolve_name "$name_override")" || return 1

	# Step 2: Detect worktree/branch context
	local worktree_info is_worktree branch_name is_feature_branch
	worktree_info="$(_cmd_run_detect_worktree)"
	is_worktree="$(echo "$worktree_info" | cut -f1)"
	branch_name="$(echo "$worktree_info" | cut -f2)"
	is_feature_branch="$(echo "$worktree_info" | cut -f3)"

	# Step 3: Auto-register if not already registered
	if ! is_app_registered "$name"; then
		print_info "Project '$name' not registered — auto-registering..."
		echo ""

		if [[ -n "$port_override" ]]; then
			cmd_add "$name" "$port_override"
		else
			cmd_add "$name"
		fi

		local add_exit=$?
		if [[ "$add_exit" -ne 0 ]]; then
			print_error "Auto-registration failed for '$name'"
			return 1
		fi
		echo ""
	fi

	# Step 4: Resolve the correct port
	local port
	port="$(_cmd_run_resolve_port "$name" "$port_override" "$is_feature_branch" "$branch_name")" || return 1

	# Step 5: Build the environment and exec
	local domain="${name}.local"
	if [[ "$is_feature_branch" -eq 1 ]]; then
		local sanitised
		sanitised="$(sanitise_branch_name "$branch_name")"
		domain="${sanitised}.${name}.local"
	fi

	echo ""
	print_success "localdev run: $name"
	print_info "  URL:     https://$domain"
	print_info "  PORT:    $port"
	if [[ "$set_host" -eq 1 ]]; then
		print_info "  HOST:    0.0.0.0"
	fi
	print_info "  Command: ${cmd_args[*]}"
	echo ""

	# Export PORT and optionally HOST, then exec the command
	# exec replaces this process — signals go directly to the child
	export PORT="$port"
	if [[ "$set_host" -eq 1 ]]; then
		export HOST="0.0.0.0"
	fi

	exec "${cmd_args[@]}"
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
	hosts_count="$(grep -c '#Local Site' /etc/hosts 2>/dev/null || echo "0")"
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
