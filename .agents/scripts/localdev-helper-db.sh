#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# localdev-helper-db.sh -- Shared Postgres database management
# =============================================================================
# Manages a shared local-postgres container for development databases.
# Projects can still use their own docker-compose Postgres for version-specific
# testing — this provides a convenient shared instance for general use.
#
# Usage: source "${SCRIPT_DIR}/localdev-helper-db.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LOCALDEV_DB_LIB_LOADED:-}" ]] && return 0
_LOCALDEV_DB_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (caller may not set it)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Database Command — Shared Postgres management
# =============================================================================

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
