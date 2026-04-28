#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# localdev-helper-init.sh -- Init, dnsmasq, resolver, and Traefik migration
# =============================================================================
# One-time system setup functions: configures dnsmasq, /etc/resolver/local,
# and migrates Traefik from single dynamic.yml to conf.d/ directory provider.
#
# Usage: source "${SCRIPT_DIR}/localdev-helper-init.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - detect_brew_prefix() from localdev-helper.sh orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LOCALDEV_INIT_LIB_LOADED:-}" ]] && return 0
_LOCALDEV_INIT_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (caller may not set it)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

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
